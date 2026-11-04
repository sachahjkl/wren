#+build windows
package browser

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "toolkit:platform"
import "wb:host"

@(private = "file") SLOT_MS :: 200          // the slot the frame waits for
@(private = "file") POST_AFTER_MS :: 20     // another thread posts this long into the wait
@(private = "file") TIMER_AFTER_MS :: 40    // a timer of the loop due this long into the wait

@(private = "file")
Slot_Probe :: struct {
	loop:     ^host.Loop,
	posted:   i64,   // ticks (ns) the task and the timer ran at, 0: not yet
	timed:    i64,
	poster:   ^thread.Thread,
}

// The frame's wait for its slot (pacing.odin pacer_slot_wait) runs the loop's tasks as they come: a post from another thread
// during the wait and a timer of the loop due before the slot both run before the slot, and the wait still ends at its slot.
@(test)
the_loop_tasks_run_while_a_frame_waits_for_its_slot :: proc(t: ^testing.T) {
	app := test_app(t)
	app.loop.wake, app.loop.wake_user = wake_window, app
	w := platform.open_window_offscreen("slot", {64, 64})
	defer platform.destroy_window(w)
	app.bare.win = w
	app.wake_target = w
	app.pacing.timer = pacer_timer_create()
	defer pacer_timer_destroy(app.pacing.timer)

	probe := Slot_Probe{loop = &app.loop}
	host.set_timer(&app.loop, TIMER_AFTER_MS, 0, proc(data: rawptr) { (^Slot_Probe)(data).timed = time.tick_now()._nsec }, &probe)
	probe.poster = thread.create_and_start_with_data(&probe, proc(data: rawptr) {
		p := (^Slot_Probe)(data)
		time.sleep(POST_AFTER_MS * time.Millisecond)
		host.post(p.loop, proc(data: rawptr) { (^Slot_Probe)(data).posted = time.tick_now()._nsec }, p)
	})
	defer thread.destroy(probe.poster)

	app.pass_first = true
	until := time.tick_now()._nsec + SLOT_MS * NS_PER_MS
	pacer_slot_wait(app, until)
	ended := time.tick_now()._nsec
	thread.join(probe.poster)

	testing.expectf(t, probe.posted != 0 && probe.posted < until, "the task posted during the wait ran before the slot: %d ns before it", until - probe.posted)
	testing.expectf(t, probe.timed != 0 && probe.timed < until, "the timer due during the wait ran before the slot: %d ns before it", until - probe.timed)
	testing.expect_value(t, app.bare.pacer.ran, 2)
	testing.expect(t, !app.bare.pacer.first_paint)   // (no tab: no first paint ends the wait)
	testing.expectf(t, ended >= until, "the wait went on to its slot: it ended %d ns early", until - ended)
	testing.expect(t, !sync.atomic_load(&app.pacing.waiting))
}
