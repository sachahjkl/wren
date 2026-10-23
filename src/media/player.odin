package media

// The player: decodes what the track stores hold and presents it on a clock.
//
//   store (video) --> video thread --> decoded pictures (queue) --> present() on the interface thread
//   store (audio) --> audio thread --> Audio_Output (ring, device thread) --> the audio clock
//
// The audio output is the master clock: the media time is where the audio device is, so sound and picture agree by
// construction, and when the audio starves the clock stops (the page sees `stalled`). Without audio, or when the
// output cannot be opened, the clock follows the system's. The interface thread calls tick() often (it starts and
// stops the clock, sees stalls and the end) and present() when it paints; everything else runs on the player's threads.
// Nothing here knows the DOM: `notify` (any thread) tells the owner that tick() has something new to look at.

import "wb:base"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

Player_Settings :: struct {
	video_queue:  int,    // decoded pictures kept ready
	audio_ahead:  Time,   // audio decoded ahead of the play position
	start_audio:  Time,   // audio queued before playback starts
	prefer_gpu:   bool,
	late_drop:    Time,   // pictures older than the clock by this much are dropped unseen
}

PLAYER_SETTINGS_DEFAULT :: Player_Settings{video_queue = 4, audio_ahead = 300_000_000, start_audio = 60_000_000, prefer_gpu = true, late_drop = 0}

Player_Error :: enum u8 { None, No_Video_Decoder, No_Audio_Decoder, Decode_Failed, Audio_Lost }

Player_Stats :: struct {
	decoded, dropped, presented: int,
	hardware: bool,
	decoder:  string,
	queued:   int,
	width, height: int,
}

Player :: struct {
	settings: Player_Settings,
	video, audio: ^Track_Store,
	notify:   proc(user: rawptr),
	user:     rawptr,
	notified: i32,

	mu:       sync.Mutex,
	cv:       sync.Cond,
	quit:     bool,
	// control (set by the owner)
	want_play: bool,
	rate:     f64,
	gain:     f32,
	muted:    bool,
	seek_gen: u32,                 // bumps with every seek
	seek_to:  Time,
	source_ended: bool,            // no more data will come into the stores
	// the clock
	started:  bool,                // the clock runs (playing, and enough is ready)
	clock_pos: Time,               // media time at clock_at (while not running: where it stands)
	clock_at:  i64,
	// video
	vthread:  ^thread.Thread,
	queue:    [dynamic]Video_Frame,
	cur:      Video_Frame,
	has_cur:  bool,
	need_cur: bool,                // the next picture replaces the one shown, whatever its time (a seek)
	v_done_gen: u32,               // the seek the video side finished
	v_starved: bool,
	v_eos:    bool,
	v_active: bool,                // there is a video track decoding
	vsize:    [2]int,
	stats:    Player_Stats,
	// audio
	athread:  ^thread.Thread,
	out:      ^Audio_Output,
	a_done_gen: u32,
	a_starved: bool,
	a_eos:    bool,
	a_active: bool,
	a_base:   Time,                // media time of the first frame of the ring after the last flush
	a_written: i64,                // frames written since the flush
	a_rate:   int,
	a_clock:  bool,                // the audio output is the clock
	// outcomes
	error:    Player_Error,
	stalled:  bool,
	ended:    bool,
	last_time: Time,
}

player_create :: proc(video, audio: ^Track_Store, settings: Player_Settings, notify: proc(user: rawptr), user: rawptr) -> ^Player {
	p := new(Player, base.process_allocator())
	p.settings = settings
	p.video, p.audio = video, audio
	p.notify, p.user = notify, user
	p.rate = 1
	p.gain = 1
	p.seek_gen = 1
	p.v_active = video != nil
	p.a_active = audio != nil
	p.need_cur = true
	p.clock_at = mono_ns()
	if video != nil { p.vthread = thread.create_and_start_with_data(rawptr(p), proc(d: rawptr) { video_thread((^Player)(d)) }, context) }
	if audio != nil { p.athread = thread.create_and_start_with_data(rawptr(p), proc(d: rawptr) { audio_thread((^Player)(d)) }, context) }
	return p
}

player_destroy :: proc(p: ^Player) {
	if p == nil { return }
	sync.mutex_lock(&p.mu)
	p.quit = true
	sync.cond_broadcast(&p.cv)
	sync.mutex_unlock(&p.mu)
	if p.vthread != nil { thread.join(p.vthread); thread.destroy(p.vthread) }
	if p.athread != nil { thread.join(p.athread); thread.destroy(p.athread) }
	if p.out != nil { p.out.stop(p.out); p.out.destroy(p.out) }
	for &f in p.queue { frame_release(&f) }
	delete(p.queue)
	if p.has_cur { frame_release(&p.cur) }
	free(p, base.process_allocator())
}

@(private)
poke :: proc(p: ^Player) {
	if p.notify != nil && sync.atomic_exchange(&p.notified, 1) == 0 { p.notify(p.user) }
}

// The owner looked at the player's state: the next change notifies again.
player_seen :: proc(p: ^Player) { sync.atomic_store(&p.notified, 0) }

// New data in a store, or the end of the data: the threads look again.
player_wake :: proc(p: ^Player) {
	sync.mutex_lock(&p.mu)
	sync.cond_broadcast(&p.cv)
	sync.mutex_unlock(&p.mu)
}

player_set_source_ended :: proc(p: ^Player, ended: bool) {
	sync.mutex_lock(&p.mu)
	p.source_ended = ended
	sync.cond_broadcast(&p.cv)
	sync.mutex_unlock(&p.mu)
}

////////////////////////////////
// Control (interface thread)

player_play :: proc(p: ^Player) {
	sync.mutex_lock(&p.mu)
	p.want_play = true
	p.ended = false
	sync.cond_broadcast(&p.cv)
	sync.mutex_unlock(&p.mu)
}

player_pause :: proc(p: ^Player) {
	sync.mutex_lock(&p.mu)
	p.want_play = false
	sync.mutex_unlock(&p.mu)
	player_tick(p)
}

player_set_volume :: proc(p: ^Player, volume: f32, muted: bool) {
	sync.mutex_lock(&p.mu)
	p.gain, p.muted = volume, muted
	out := p.out
	g := muted ? 0 : volume
	sync.mutex_unlock(&p.mu)
	if out != nil { out.set_gain(out, g * g) }   // (perceptual: the slider is a power curve)
}

// A new rate. The audio is resampled by it (the pitch follows: a time stretch is not done) and the clock runs by it.
player_set_rate :: proc(p: ^Player, rate: f64) {
	t := player_time(p)
	sync.mutex_lock(&p.mu)
	p.rate = clamp(rate, 0.0625, 16)
	sync.mutex_unlock(&p.mu)
	player_seek(p, t)
}

// Moves to `t`: the decoders start again from the keyframe before it and the pictures and audio before `t` are dropped.
player_seek :: proc(p: ^Player, t: Time) {
	sync.mutex_lock(&p.mu)
	p.seek_gen += 1
	p.seek_to = max(t, 0)
	p.clock_pos = p.seek_to
	p.clock_at = mono_ns()
	p.started = false
	p.need_cur = true
	p.ended = false
	p.stalled = false
	p.v_eos, p.a_eos = false, false
	out := p.out
	sync.cond_broadcast(&p.cv)
	sync.mutex_unlock(&p.mu)
	if out != nil { out.stop(out) }
}

// The seek the owner asked last has its first picture (and audio) ready.
player_seek_done :: proc(p: ^Player) -> bool {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	v := !p.v_active || p.v_done_gen == p.seek_gen || p.v_eos
	a := !p.a_active || p.a_done_gen == p.seek_gen || p.a_eos
	return v && a
}

////////////////////////////////
// The clock

// Where playback is, in media time.
player_time :: proc(p: ^Player) -> Time {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return clock_locked(p)
}

@(private)
clock_locked :: proc(p: ^Player) -> Time {
	if !p.started { return p.clock_pos }
	now := mono_ns()
	t: Time
	if p.a_clock && p.out != nil && p.a_rate > 0 {
		frames, at := p.out.position(p.out)
		played := Time(f64(frames) * 1e9 / f64(p.a_rate) * p.rate)
		t = p.a_base + played
		if at != 0 { t += Time(f64(max(now - at, 0)) * p.rate) }
		// never past what was written (an underrun stops the clock)
		written_end := p.a_base + Time(f64(p.a_written) * 1e9 / f64(p.a_rate) * p.rate)
		t = min(t, written_end)
	} else {
		t = p.clock_pos + Time(f64(now - p.clock_at) * p.rate)
	}
	t = max(t, p.last_time)   // (never back)
	p.last_time = t
	return t
}

// Starts and stops the clock, notices stalls and the end. Cheap; the owner calls it whenever it looks (every frame it
// paints, and when `notify` says something happened). Returns whether the owner should look at the state again soon.
player_tick :: proc(p: ^Player) {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	now := mono_ns()
	video_ready := !p.v_active || p.v_eos || len(p.queue) > 0 || p.has_cur && !p.need_cur
	audio_ready := !p.a_active || p.a_eos || (p.out != nil && p.a_written * 1_000_000_000 >= i64(p.settings.start_audio) * i64(max(p.a_rate, 1)))
	seek_ok := (!p.v_active || p.v_done_gen == p.seek_gen || p.v_eos) && (!p.a_active || p.a_done_gen == p.seek_gen || p.a_eos)
	if p.want_play && !p.started {
		if video_ready && audio_ready && seek_ok && p.error == .None && (!p.stalled || len(p.queue) > 0) {
			p.started = true
			p.stalled = false
			p.clock_at = now
			p.last_time = 0
			if p.a_active && p.out != nil && p.a_rate > 0 {
				p.a_clock = true
				p.out.start(p.out)
			} else {
				p.a_clock = false
			}
			p.last_time = p.clock_pos
			poke(p)
		}
	} else if !p.want_play && p.started {
		t := clock_locked(p)
		p.started = false
		p.clock_pos, p.clock_at = t, now
		if p.out != nil { p.out.stop(p.out) }
		poke(p)
	}
	if !p.started { return }
	// stalls: the audio ran dry, or the picture for the clock is not there and cannot be decoded
	starving := (p.a_active && p.a_clock && p.a_starved && p.a_written > 0 && p.out != nil && p.out.queued(p.out) <= 0) ||
		(!p.a_clock && p.v_active && p.v_starved && len(p.queue) == 0)
	if starving && !p.stalled {
		// a clock without audio is frozen where it stands
		if !p.a_clock {
			p.clock_pos = clock_locked(p)
			p.started = false
		}
		p.stalled = true
		poke(p)
	} else if !starving && p.stalled {
		p.stalled = false
		poke(p)
	}
	// the end: every stream drained, nothing left to show
	if (!p.v_active || (p.v_eos && len(p.queue) == 0)) && (!p.a_active || (p.a_eos && p.out != nil && p.out.queued(p.out) <= 0) || (p.a_eos && p.out == nil)) && (p.v_active || p.a_active) && !p.ended {
		p.ended = true
		p.clock_pos = clock_locked(p)
		p.started = false
		p.want_play = false
		if p.out != nil { p.out.stop(p.out) }
		poke(p)
	}
}

////////////////////////////////
// Presentation (interface thread)

// The picture to show, or nil when nothing is decoded yet. `changed` is whether it differs from what the last call
// returned. The frame belongs to the player (valid until the next call). `ahead` is how long until the screen shows
// what the caller is about to draw (the next vblank): the picture chosen is the one that is due then, not the one due
// now, so that the choice does not depend on the jitter of the instant the frame happened to run (a 60 fps picture on a
// 60 Hz screen is one picture per refresh, whatever the thread's wake-up time).
player_present :: proc(p: ^Player, ahead: i64 = 0) -> (frame: ^Video_Frame, changed: bool) {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	t := clock_locked(p)
	if p.started && ahead > 0 { t += Time(f64(ahead) * p.rate) }
	took := false
	// pictures that are late by more than the next one is early: skipped
	for len(p.queue) >= 2 && p.queue[1].pts <= t - p.settings.late_drop {
		if p.has_cur || took { p.stats.dropped += 1 }
		frame_release(&p.queue[0])
		ordered_remove(&p.queue, 0)
		// the one dropped was never shown
		took = true
	}
	if len(p.queue) > 0 && (p.need_cur || !p.has_cur || p.queue[0].pts <= t) {
		if p.has_cur { frame_release(&p.cur) }
		p.cur = p.queue[0]
		ordered_remove(&p.queue, 0)
		p.has_cur, p.need_cur, changed = true, false, true
		p.stats.presented += 1
		sync.cond_broadcast(&p.cv)   // room in the queue
		p.vsize = {p.cur.width, p.cur.height}
	}
	if p.has_cur { frame = &p.cur }
	return
}

// How long until the picture after the current one is due (0: now or nothing is waiting).
player_next_due :: proc(p: ^Player, ahead: i64 = 0) -> (in_ns: i64, ok: bool) {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	if !p.started || len(p.queue) == 0 { return 0, false }
	t := clock_locked(p)
	if ahead > 0 { t += Time(f64(ahead) * p.rate) }
	d := p.queue[0].pts - t
	return max(i64(f64(d) / p.rate), 0), true
}

player_stats :: proc(p: ^Player) -> Player_Stats {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	s := p.stats
	s.queued = len(p.queue)
	s.width, s.height = p.vsize[0], p.vsize[1]
	return s
}

// What the player is doing, for the profile report.
player_debug :: proc(p: ^Player) -> string {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	queued := 0
	if p.out != nil { queued = p.out.queued(p.out) }
	return fmt.tprintf("started %v want_play %v queue %d cur %v need_cur %v v_starved %v v_eos %v a_starved %v a_written %d ring %d a_rate %d a_clock %v seek_gen %d v_done %d a_done %d err %v", p.started, p.want_play, len(p.queue), p.has_cur, p.need_cur, p.v_starved, p.v_eos, p.a_starved, p.a_written, queued, p.a_rate, p.a_clock, p.seek_gen, p.v_done_gen, p.a_done_gen, p.error)
}

player_state :: proc(p: ^Player) -> (playing, stalled, ended: bool, err: Player_Error) {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.started, p.stalled, p.ended, p.error
}

// True when something is decoded and waiting beyond what is shown (the owner should paint when it is due).
player_has_picture :: proc(p: ^Player) -> bool {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	return p.has_cur || len(p.queue) > 0
}

@(private)
set_error :: proc(p: ^Player, e: Player_Error) {
	sync.mutex_lock(&p.mu)
	if p.error == .None { p.error = e }
	sync.mutex_unlock(&p.mu)
	poke(p)
}

////////////////////////////////
// The video thread

@(private)
tracks_equal :: proc(a, b: Track) -> bool {
	return a.codec == b.codec && a.width == b.width && a.height == b.height && string(a.config) == string(b.config) && a.rotation == b.rotation
}

@(private)
video_thread :: proc(p: ^Player) {
	name_current_thread("wren-video-decode")
	com_thread_init_any()
	dec: ^Video_Decoder
	cur_track: Track
	have_track := false
	defer {
		if dec != nil { dec.destroy(dec) }
		if have_track { track_destroy(&cur_track) }
	}
	gen: u32 = max(u32)       // the seek generation being served
	cursor: Time = 0           // decode time of the next sample to take
	held: Video_Frame          // while seeking: the latest picture before the target
	has_held := false
	dropping := false          // decoding up to the seek target
	target: Time
	input: Coded
	has_input := false         // a frame taken from the store the decoder refused for now
	drained := false
	defer {
		if has_held { frame_release(&held) }
		if has_input { coded_release(&input) }
	}
	for {
		sync.mutex_lock(&p.mu)
		for !p.quit && gen == p.seek_gen && len(p.queue) >= p.settings.video_queue {
			sync.cond_wait(&p.cv, &p.mu)
		}
		if p.quit { sync.mutex_unlock(&p.mu); return }
		new_seek := gen != p.seek_gen
		seek_gen, seek_to := p.seek_gen, p.seek_to
		ended := p.source_ended
		sync.mutex_unlock(&p.mu)

		if new_seek {
			gen, target = seek_gen, seek_to
			if dec != nil { dec.flush(dec) }
			if has_held { frame_release(&held); has_held = false }
			if has_input { coded_release(&input); has_input = false }
			sync.mutex_lock(&p.mu)
			for &f in p.queue { frame_release(&f) }
			clear(&p.queue)
			p.v_eos, p.v_starved = false, false
			sync.mutex_unlock(&p.mu)
			k, ok := store_keyframe_for(p.video, target)
			cursor = ok ? k : 0
			dropping = true
			drained = false
		}

		// the next coded frame
		if !has_input && !drained {
			c, ok := store_get_from(p.video, cursor)
			if ok {
				input, has_input = c, true
				cursor = c.dts + 1
			} else if ended {
				if dec != nil { dec.drain(dec) }
				drained = true
			} else {
				sync.mutex_lock(&p.mu)
				if !p.v_starved { p.v_starved = true }
				// wait for the store to change (a new frame), the end of the source or a seek
				if !p.quit && gen == p.seek_gen && !p.source_ended { sync.cond_wait_with_timeout(&p.cv, &p.mu, 20 * time.Millisecond) }
				sync.mutex_unlock(&p.mu)
				poke(p)
				continue
			}
		}
		sync.mutex_lock(&p.mu)
		p.v_starved = false
		sync.mutex_unlock(&p.mu)

		// a new description of the track: another decoder
		if has_input {
			t, tok := store_track(p.video, input.config)
			if tok {
				if !have_track || !tracks_equal(cur_track, t) || dec == nil {
					if dec != nil { dec.destroy(dec); dec = nil }
					if have_track { track_destroy(&cur_track) }
					cur_track, have_track = t, true
					dec = backend_video_decoder(cur_track, p.settings.prefer_gpu)
					if dec == nil { set_error(p, .No_Video_Decoder); return }
					sync.mutex_lock(&p.mu)
					p.stats.hardware, p.stats.decoder = dec.hardware, dec.name
					sync.mutex_unlock(&p.mu)
					// a decoder starts at a keyframe: this frame is one, or the stream is broken
				} else {
					track_destroy(&t)
				}
			}
		}
		if dec == nil { time.sleep(5 * time.Millisecond); continue }

		if has_input {
			s := coded_sample(input)
			if dec.push(dec, &s) {
				coded_release(&input)
				has_input = false
			}
		}
		// pictures out
		for {
			f: Video_Frame
			res := dec.pull(dec, &f)
			if res == .Format_Changed { continue }
			if res == .Error { set_error(p, .Decode_Failed); return }
			if res == .Need_Input { break }
			sync.mutex_lock(&p.mu)
			p.stats.decoded += 1
			if gen != p.seek_gen { sync.mutex_unlock(&p.mu); frame_release(&f); break }
			if dropping && f.pts < target {
				// before the target: only the latest of them may be shown (the picture at the target)
				sync.mutex_unlock(&p.mu)
				if has_held { frame_release(&held) }
				held, has_held = f, true
				continue
			}
			if dropping {
				dropping = false
				if has_held {
					append(&p.queue, held)
					has_held = false
				}
				p.v_done_gen = gen
			}
			if f.pts < 0 {
				sync.mutex_unlock(&p.mu)
				frame_release(&f)
				continue
			}
			append(&p.queue, f)
			p.v_done_gen = gen
			sync.mutex_unlock(&p.mu)
			poke(p)
			// room? (a full queue waits at the top)
			sync.mutex_lock(&p.mu)
			full := len(p.queue) >= p.settings.video_queue
			sync.mutex_unlock(&p.mu)
			if full { break }
		}
		if drained && !has_input {
			// the decoder gave all it had: the end of the video (a held picture is the last one)
			sync.mutex_lock(&p.mu)
			if has_held { append(&p.queue, held); has_held = false }
			if dropping { dropping = false }
			p.v_done_gen = gen
			p.v_eos = true
			sync.cond_broadcast(&p.cv)
			sync.mutex_unlock(&p.mu)
			poke(p)
			// wait for a seek or the end of the player
			sync.mutex_lock(&p.mu)
			for !p.quit && gen == p.seek_gen { sync.cond_wait(&p.cv, &p.mu) }
			sync.mutex_unlock(&p.mu)
		}
	}
}

////////////////////////////////
// The audio thread

@(private)
audio_thread :: proc(p: ^Player) {
	name_current_thread("wren-audio-decode")
	com_thread_init_any()
	dec: ^Audio_Decoder
	cur_track: Track
	have_track := false
	defer {
		if dec != nil { dec.destroy(dec) }
		if have_track { track_destroy(&cur_track) }
	}
	gen: u32 = max(u32)
	cursor: Time = 0
	target: Time
	trimming := false         // dropping audio before the seek target
	input: Coded
	has_input := false
	drained := false
	expect: Time              // media time of the next frame to write (contiguity)
	have_expect := false
	defer if has_input { coded_release(&input) }
	stereo: [dynamic]f32
	defer delete(stereo)
	for {
		sync.mutex_lock(&p.mu)
		if p.quit { sync.mutex_unlock(&p.mu); return }
		new_seek := gen != p.seek_gen
		seek_gen, seek_to := p.seek_gen, p.seek_to
		ended := p.source_ended
		rate := p.rate
		sync.mutex_unlock(&p.mu)

		if new_seek {
			gen, target = seek_gen, seek_to
			if dec != nil { dec.flush(dec) }
			if has_input { coded_release(&input); has_input = false }
			if p.out != nil { p.out.stop(p.out); p.out.flush(p.out) }
			sync.mutex_lock(&p.mu)
			p.a_written, p.a_base = 0, target
			p.a_eos, p.a_starved = false, false
			sync.mutex_unlock(&p.mu)
			// audio frames are all keyframes: start at the one that covers the target
			cursor = audio_start_dts(p.audio, target - Time(100_000_000))   // (a frame or two before: the decoders' overlap, Opus' pre-roll)
			trimming = true
			drained = false
			have_expect = false
		}

		// wait for room in the ring: what is queued must not exceed audio_ahead
		if p.out != nil {
			queued_ns := Time(i64(p.out.queued(p.out)) * NS_PER_S / i64(max(p.a_rate, 1)))
			if queued_ns > p.settings.audio_ahead {
				sync.mutex_lock(&p.mu)
				if gen == p.seek_gen && !p.quit { sync.cond_wait_with_timeout(&p.cv, &p.mu, 10 * time.Millisecond) }
				sync.mutex_unlock(&p.mu)
				continue
			}
		}

		if !has_input && !drained {
			c, ok := store_get_from(p.audio, cursor)
			if ok {
				input, has_input = c, true
				cursor = c.dts + 1
			} else if ended {
				if dec != nil { dec.drain(dec) }
				drained = true
			} else {
				sync.mutex_lock(&p.mu)
				p.a_starved = true
				sync.cond_wait_with_timeout(&p.cv, &p.mu, 10 * time.Millisecond)
				sync.mutex_unlock(&p.mu)
				continue
			}
		}
		sync.mutex_lock(&p.mu)
		p.a_starved = false
		sync.mutex_unlock(&p.mu)

		if has_input {
			t, tok := store_track(p.audio, input.config)
			if tok {
				if !have_track || !tracks_equal_audio(cur_track, t) || dec == nil {
					if dec != nil { dec.destroy(dec); dec = nil }
					if have_track { track_destroy(&cur_track) }
					cur_track, have_track = t, true
					dec = backend_audio_decoder(cur_track)
					if dec == nil { set_error(p, .No_Audio_Decoder); return }
				} else {
					track_destroy(&t)
				}
			}
		}
		if dec == nil { time.sleep(5 * time.Millisecond); continue }

		if has_input {
			s := coded_sample(input)
			if dec.push(dec, &s) {
				coded_release(&input)
				has_input = false
			}
		}
		for {
			b: Audio_Block
			res := dec.pull(dec, &b)
			if res == .Format_Changed { continue }
			if res == .Error { set_error(p, .Decode_Failed); return }
			if res == .Need_Input { break }
			ok := audio_write_block(p, &b, &stereo, &trimming, target, &expect, &have_expect, rate, gen)
			audio_block_destroy(&b)
			if !ok { break }
		}
		if drained && !has_input {
			sync.mutex_lock(&p.mu)
			p.a_eos = true
			p.a_done_gen = gen
			sync.mutex_unlock(&p.mu)
			poke(p)
			sync.mutex_lock(&p.mu)
			for !p.quit && gen == p.seek_gen { sync.cond_wait(&p.cv, &p.mu) }
			sync.mutex_unlock(&p.mu)
		}
	}
}

@(private)
tracks_equal_audio :: proc(a, b: Track) -> bool {
	return a.codec == b.codec && a.channels == b.channels && a.sample_rate == b.sample_rate && string(a.config) == string(b.config)
}

// The decode time of the first audio frame to take for a seek to `target`: the one that covers it (or the first).
@(private)
audio_start_dts :: proc(s: ^Track_Store, target: Time) -> Time {
	dts, ok := store_keyframe_for(s, target)
	return ok ? dts : 0
}

// A decoded block into the output: mono / surround mixed down, resampled by the rate, the part before the seek target
// dropped, gaps filled with silence. false: stop pulling (a seek came in, or the device is gone).
@(private)
audio_write_block :: proc(p: ^Player, b: ^Audio_Block, stereo: ^[dynamic]f32, trimming: ^bool, target: Time, expect: ^Time, have_expect: ^bool, rate: f64, gen: u32) -> bool {
	// the device is opened at the stream's rate, the first time and when the rate changes
	if p.out == nil || p.a_rate != b.rate {
		if p.out != nil { p.out.stop(p.out); p.out.destroy(p.out); p.out = nil }
		out := backend_audio_output(b.rate)
		if out == nil { set_error(p, .Audio_Lost); sync.mutex_lock(&p.mu); p.a_active = false; sync.mutex_unlock(&p.mu); return false }
		sync.mutex_lock(&p.mu)
		p.out, p.a_rate = out, b.rate
		g := p.muted ? 0 : p.gain
		sync.mutex_unlock(&p.mu)
		out.set_gain(out, g * g)
		have_expect^ = false
	}
	if p.out.failed(p.out) { set_error(p, .Audio_Lost); return false }
	frames := b.frames
	resize(stereo, frames * 2)
	downmix_to_stereo(b.samples, b.channels, frames, stereo[:])
	pts := b.pts
	// before the target: dropped (a seek into the middle of a frame)
	if trimming^ {
		end := pts + Time(i64(frames) * NS_PER_S / i64(b.rate))
		if end <= target { return true }
		if pts < target {
			skip := int(i64(target - pts) * i64(b.rate) / NS_PER_S)
			skip = min(skip, frames)
			remove_range(stereo, 0, skip * 2)
			frames -= skip
			pts += Time(i64(skip) * NS_PER_S / i64(b.rate))
		}
		trimming^ = false
		sync.mutex_lock(&p.mu)
		if gen == p.seek_gen { p.a_base = pts }
		sync.mutex_unlock(&p.mu)
	}
	if frames <= 0 { return true }
	// contiguity: a gap in the stream is silence, an overlap drops the repeated start
	if have_expect^ {
		gap := pts - expect^
		tol := Time(NS_PER_S / i64(b.rate) * 2)
		if gap > tol && gap < 2 * Time(NS_PER_S) {
			n := int(i64(gap) * i64(b.rate) / NS_PER_S)
			silence := make([]f32, n * 2, context.temp_allocator)
			audio_push(p, silence, gen)
		} else if gap < -tol {
			drop := min(int(i64(-gap) * i64(b.rate) / NS_PER_S), frames)
			remove_range(stereo, 0, drop * 2)
			frames -= drop
		}
	}
	if frames <= 0 { return true }
	expect^ = pts + Time(i64(frames) * NS_PER_S / i64(b.rate))
	have_expect^ = true
	data := stereo[:frames * 2]
	if rate != 1 { data = resample_rate(data, rate) }
	return audio_push(p, data, gen)
}

// Writes interleaved stereo into the ring, waiting for room. false: a seek or the end of the player came first.
@(private)
audio_push :: proc(p: ^Player, samples: []f32, gen: u32) -> bool {
	rest := samples
	for len(rest) > 0 {
		sync.mutex_lock(&p.mu)
		cancelled := p.quit || gen != p.seek_gen
		sync.mutex_unlock(&p.mu)
		if cancelled { return false }
		n := p.out.write(p.out, rest)
		if n > 0 {
			sync.mutex_lock(&p.mu)
			p.a_written += i64(n)
			sync.mutex_unlock(&p.mu)
			rest = rest[n * 2:]
			continue
		}
		sync.mutex_lock(&p.mu)
		sync.cond_wait_with_timeout(&p.cv, &p.mu, 5 * time.Millisecond)
		sync.mutex_unlock(&p.mu)
	}
	sync.mutex_lock(&p.mu)
	p.a_done_gen = gen
	sync.mutex_unlock(&p.mu)
	poke(p)
	return true
}

// Playing faster or slower by resampling (linear): the pitch follows the rate.
@(private)
resample_rate :: proc(in_samples: []f32, rate: f64) -> []f32 {
	frames := len(in_samples) / 2
	n := int(f64(frames) / rate)
	out := make([]f32, n * 2, context.temp_allocator)
	for i in 0 ..< n {
		x := f64(i) * rate
		i0 := min(int(x), frames - 1)
		i1 := min(i0 + 1, frames - 1)
		fr := f32(x - f64(i0))
		out[i * 2] = in_samples[i0 * 2] * (1 - fr) + in_samples[i1 * 2] * fr
		out[i * 2 + 1] = in_samples[i0 * 2 + 1] * (1 - fr) + in_samples[i1 * 2 + 1] * fr
	}
	return out
}
