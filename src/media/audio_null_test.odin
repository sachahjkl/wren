#+build windows
package media

import "core:testing"
import "core:time"
import "wb:base"

@(test)
the_silent_output_plays_what_it_is_given_at_the_pace_of_the_clock :: proc(t: ^testing.T) {
	RATE :: 48000
	o := null_audio_open(RATE)
	defer o.destroy(o)
	frames := make([]f32, 4800 * 2, context.temp_allocator)   // 100 ms
	testing.expect_value(t, o.write(o, frames), 4800)
	f, _ := o.position(o)
	testing.expect_value(t, f, i64(0))   // not started: nothing is played
	o.start(o)
	time.sleep(40 * time.Millisecond)
	f, _ = o.position(o)
	testing.expectf(t, f > 1000, "40 ms into 100 ms of audio: %d frames played (it plays, 21 ms at least went by)", f)
	// not all of it yet: a window of time (a loaded machine oversleeps), so a performance test
	if !base.perf_skip("audio_null: 40 ms into 100 ms of audio is not all played yet") {
		testing.expectf(t, f < 4800, "40 ms into 100 ms of audio: %d frames played (not all)", f)
	}
	time.sleep(150 * time.Millisecond)
	f, _ = o.position(o)
	testing.expect_value(t, f, i64(4800))   // what was written, no more: silence the device plays does not count
	testing.expect_value(t, o.queued(o), 0)
	o.stop(o)
	o.flush(o)
	f, _ = o.position(o)
	testing.expect_value(t, f, i64(0))
	testing.expectf(t, o.room(o) >= RATE / 2, "the ring is empty after a flush: room %d", o.room(o))
}

@(test)
the_silent_output_takes_no_more_than_its_ring_holds :: proc(t: ^testing.T) {
	o := null_audio_open(48000)
	defer o.destroy(o)
	frames := make([]f32, 100000 * 2, context.temp_allocator)
	n := o.write(o, frames)
	testing.expect_value(t, n, 24000)   // half a second
	testing.expect_value(t, o.write(o, frames), 0)
	testing.expect(t, !o.failed(o), "no device to lose")
}
