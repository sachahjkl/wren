package host

import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
Dialog_Probe :: struct { worker, done_on, done, discarded: int }

// A dialog runs on a thread of its own and is answered on the loop's; one answered while the browser ends is discarded,
// not answered.
@(test)
dialogs_answer_on_the_loop_or_are_discarded :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	d: Dialogs
	dialogs_init(&d, &l)
	work :: proc(data: rawptr) { (^Dialog_Probe)(data).worker = int(sync.current_thread_id()) }
	done :: proc(data: rawptr) { p := (^Dialog_Probe)(data); p.done += 1; p.done_on = int(sync.current_thread_id()) }
	discard :: proc(data: rawptr) { (^Dialog_Probe)(data).discarded += 1 }

	a: Dialog_Probe
	testing.expect(t, run_dialog(&d, work, done, &a, discard))
	testing.expect_value(t, dialogs_open(&d), 1)
	for a.done == 0 { loop_wait(&l) }   // (its answer is a post: the wait ends)
	testing.expect(t, a.worker != int(sync.current_thread_id()), "the dialog ran on a thread of its own")
	testing.expect_value(t, a.done_on, int(sync.current_thread_id()))
	testing.expect_value(t, dialogs_open(&d), 0)

	// answered, its `done` not run yet: the browser ends
	b: Dialog_Probe
	testing.expect(t, run_dialog(&d, work, done, &b, discard))
	r := d.running[0]
	start := time.tick_now()
	for sync.atomic_load(&r.state) != DIALOG_ANSWERED && time.tick_since(start) < 30 * time.Second { time.sleep(time.Millisecond) }
	testing.expect_value(t, sync.atomic_load(&r.state), DIALOG_ANSWERED)
	dialogs_destroy(&d)
	testing.expect_value(t, b.done, 0)
	testing.expect_value(t, b.discarded, 1)
	loop_drain(&l)
	testing.expect_value(t, b.done, 0)
}
