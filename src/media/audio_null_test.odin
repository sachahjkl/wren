#+build windows
package media

import "core:testing"
import "core:time"

@(private = "file") PART_PLAYED :: 40 * time.Millisecond    // into 100 ms of audio: some of it is played, not all
@(private = "file") ALL_PLAYED :: 150 * time.Millisecond    // from there: all of it is

@(test)
the_silent_output_plays_what_it_is_given_at_the_pace_of_the_clock :: proc(t: ^testing.T) {
	RATE :: 48000
	PART_FRAMES :: i64(RATE) * i64(PART_PLAYED) / i64(time.Second)
	o := null_audio_open(RATE)
	defer o.destroy(o)
	clock: i64
	(^Null_Audio)(o.impl).test_clock = &clock
	frames := make([]f32, 4800 * 2, context.temp_allocator)   // 100 ms
	testing.expect_value(t, o.write(o, frames), 4800)
	f, _ := o.position(o)
	testing.expect_value(t, f, i64(0))   // not started: nothing is played
	o.start(o)
	f, _ = o.position(o)   // (the clock starts going for it at its first look after start)
	clock += i64(PART_PLAYED)
	f, _ = o.position(o)
	testing.expect_value(t, f, PART_FRAMES)
	clock += i64(ALL_PLAYED)
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
