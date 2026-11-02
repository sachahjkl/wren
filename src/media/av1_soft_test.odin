package media

import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"

SEEK_TEST_DECODER_THREADS :: 2       // half the processors of a CI runner
SEEK_TEST_SPINNERS_PER_CORE :: 2
SEEK_TEST_ROUNDS :: 16               // (without the fix: 3 runs of 4 stuck within 12 rounds, at the seek or on the way to the end)
SEEK_TEST_ROUND_LIMIT :: 30 * time.Second   // (a round of a 4 s clip, seeking near its end, takes a second or two)
SEEK_TEST_LOOK :: 5 * time.Millisecond
SEEK_TEST_PLAYED :: Time(300_000_000)
SEEK_TEST_TARGET :: Time(3_300_000_000)

// The built-in AV1 decoder plays the test clip: every coded frame comes out as a picture of the track's size, in
// presentation order, with planes the size its strides say; a flush (a seek) and a picture kept past the decoder's end
// are fine.
@(test)
av1_software_decoder_decodes_the_clip :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	c: Collected
	defer collected_free(&c)
	d0: Webm_Demuxer
	webm_init(&d0, collector(&c))
	testing.expect_value(t, webm_feed(&d0, data), Parse_Error.None)
	webm_destroy(&d0)
	if !testing.expect(t, len(c.tracks) >= 1 && c.tracks[0].codec == .AV1) { return }
	track := c.tracks[0]
	dec := av1_soft_create(track)
	if !testing.expect(t, dec != nil, "the decoder opens") { return }
	got := 0
	last := TIME_NONE
	kept: Video_Frame
	take :: proc(t: ^testing.T, dec: ^Video_Decoder, track: Track, got: ^int, last: ^Time, kept: ^Video_Frame) {
		for {
			f: Video_Frame
			if dec.pull(dec, &f) != .Frame { return }
			testing.expect(t, f.width == track.width && f.height == track.height && f.format == .I420, "a 320x180 8-bit picture")
			testing.expect(t, len(f.planes[0]) >= f.strides[0] * f.height && f.strides[0] >= f.width, "the luma plane")
			testing.expect(t, last^ == TIME_NONE || f.pts > last^, "presentation order")
			last^ = f.pts
			got^ += 1
			if got^ == 10 { kept^ = f } else { frame_release(&f) }
		}
	}
	for &s in c.samples[0] {
		for !dec.push(dec, &s) { take(t, dec, track, &got, &last, &kept) }
		take(t, dec, track, &got, &last, &kept)
	}
	dec.drain(dec)
	take(t, dec, track, &got, &last, &kept)
	testing.expect_value(t, got, len(c.samples[0]))
	dec.flush(dec)
	dec.destroy(dec)
	frame_release(&kept)   // after the decoder: the context closes with its last picture
}

// The CI's failure: on a machine short of processors, rav1d left its workers parked with a frame unfinished when it was asked for a
// picture twice between two coded frames, and the video thread waited for ever (a seek that never ended, a player that could not be
// destroyed). What a machine with few processors has, with threads that take them all; the player is the real one, and it must
// finish the seek and reach the end, every time.
@(test)
av1_software_player_seeks_and_ends_on_a_machine_short_of_processors :: proc(t: ^testing.T) {
	data := fixture("clip.webm")
	defer delete(data)
	if !testing.expect(t, len(data) > 0, "clip.webm missing") { return }
	c: Collected
	defer collected_free(&c)
	demuxer: Webm_Demuxer
	webm_init(&demuxer, collector(&c))
	testing.expect_value(t, webm_feed(&demuxer, data), Parse_Error.None)
	webm_destroy(&demuxer)
	video, audio := store_create(), store_create()
	for track, i in c.tracks {
		store := track.kind == .Video ? video : audio
		store_set_config(store, track.id, track)
		for sample in c.samples[i] {
			s := sample
			s.data = make([]u8, len(sample.data), base.process_allocator())
			copy(s.data, sample.data)
			store_append(store, s)
		}
	}
	set_software_preferred(true)
	set_software_threads(SEEK_TEST_DECODER_THREADS)
	apply_audio_backend_pref("null")
	defer {
		set_software_preferred(false)
		set_software_threads(0)
		apply_audio_backend_pref("")
	}
	stop: bool
	spinners := make([dynamic]^thread.Thread, context.temp_allocator)
	for _ in 0 ..< SEEK_TEST_SPINNERS_PER_CORE * os.get_processor_core_count() {
		append(&spinners, thread.create_and_start_with_data(&stop, proc(stop: rawptr) { for !sync.atomic_load((^bool)(stop)) {} }))
	}
	defer {
		sync.atomic_store(&stop, true)
		for s in spinners { thread.join(s); thread.destroy(s) }
	}
	for round in 0 ..< SEEK_TEST_ROUNDS {
		p := player_create(video, audio, PLAYER_SETTINGS_DEFAULT, nil, nil)
		player_set_source_ended(p, true)
		player_play(p)
		Stage :: enum { Playing, Seeking, To_The_End }
		stage := Stage.Playing
		start := time.tick_now()
		for {
			player_tick(p)
			player_present(p)
			if stage == .Playing && player_time(p) > SEEK_TEST_PLAYED {
				player_seek(p, SEEK_TEST_TARGET)
				player_play(p)
				stage = .Seeking
			}
			if stage == .Seeking && player_seek_done(p) { stage = .To_The_End }
			_, _, ended, err := player_state(p)
			testing.expect_value(t, err, Player_Error.None)
			if stage == .To_The_End && ended { break }
			if time.tick_since(start) > SEEK_TEST_ROUND_LIMIT {
				// (the player is left as it is: destroying it would wait for the stuck thread)
				testing.expectf(t, false, "round %d: stuck at %v: %s", round, stage, player_debug(p))
				return
			}
			time.sleep(SEEK_TEST_LOOK)
		}
		player_destroy(p)
	}
	store_destroy(video)
	store_destroy(audio)
}
