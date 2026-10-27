package media

import "core:sync"
import "wb:base"

// An audio output with no device behind it: what the player gets on a machine that has none (a server, a CI runner, a remote
// session without sound, every endpoint disabled). It takes the decoded audio and lets it go by at the rate of the clock, as a
// device would play it, so the media clock follows the audio as usual and the video plays, in silence (as browsers do).

Null_Audio :: struct {
	out:      Audio_Output,
	mu:       sync.Mutex,
	capacity: int,      // frames the ring holds (half a second, like the device's)
	written:  i64,      // frames taken since the last flush
	played:   i64,      // of them, the frames the clock has gone through
	frac:     f64,      // the part of a frame the clock has gone through
	started:  bool,
	at:       i64,      // mono_ns of the last update
}

null_audio_open :: proc(rate: int) -> ^Audio_Output {
	n := new(Null_Audio, base.process_allocator())
	n.capacity = max(rate / 2, 4096)
	o := &n.out
	o.impl, o.rate = n, rate
	o.write, o.room, o.queued, o.position = null_audio_write, null_audio_room, null_audio_queued, null_audio_position
	o.start, o.stop, o.flush, o.set_gain, o.failed, o.destroy = null_audio_start, null_audio_stop, null_audio_flush, null_audio_set_gain, null_audio_failed, null_audio_destroy
	return o
}

// The clock goes on by the time since the last update, over what was written and not played yet (with the lock).
@(private = "file")
null_audio_advance :: proc(n: ^Null_Audio) {
	now := mono_ns()
	if n.started {
		due := f64(now - n.at) * f64(n.out.rate) / 1e9 + n.frac
		whole := i64(due)
		n.frac = due - f64(whole)
		if n.played + whole >= n.written { n.played, n.frac = n.written, 0 } else { n.played += whole }
	}
	n.at = now
}

@(private = "file")
null_audio_write :: proc(o: ^Audio_Output, samples: []f32) -> int {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	null_audio_advance(n)
	taken := min(len(samples) / 2, n.capacity - int(n.written - n.played))
	taken = max(taken, 0)
	n.written += i64(taken)
	return taken
}

@(private = "file")
null_audio_room :: proc(o: ^Audio_Output) -> int {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	null_audio_advance(n)
	return n.capacity - int(n.written - n.played)
}

@(private = "file")
null_audio_queued :: proc(o: ^Audio_Output) -> int {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	null_audio_advance(n)
	return int(n.written - n.played)
}

@(private = "file")
null_audio_position :: proc(o: ^Audio_Output) -> (frames: i64, at: i64) {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	null_audio_advance(n)
	return n.played, n.at
}

@(private = "file")
null_audio_start :: proc(o: ^Audio_Output) {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	null_audio_advance(n)
	n.started = true
}

@(private = "file")
null_audio_stop :: proc(o: ^Audio_Output) {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	null_audio_advance(n)
	n.started = false
}

@(private = "file")
null_audio_flush :: proc(o: ^Audio_Output) {
	n := (^Null_Audio)(o.impl)
	sync.mutex_lock(&n.mu)
	defer sync.mutex_unlock(&n.mu)
	n.written, n.played, n.frac, n.at = 0, 0, 0, mono_ns()
}

@(private = "file")
null_audio_set_gain :: proc(o: ^Audio_Output, gain: f32) {}

@(private = "file")
null_audio_failed :: proc(o: ^Audio_Output) -> bool { return false }

@(private = "file")
null_audio_destroy :: proc(o: ^Audio_Output) { free((^Null_Audio)(o.impl), base.process_allocator()) }
