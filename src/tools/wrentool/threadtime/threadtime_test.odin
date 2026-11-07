package threadtime

import "core:testing"

// A load: the navigation at 100, the paint at 200, the load event at 300; a task of a third party holds a script of a
// first party, a frame's phases hold a wait, and the thread is free from 320 on.
TRACE :: `0.000	0.000	7	Origin	https://a.test	Background	0	1	false
0.000	0.000	7	Origin	https://ads.test	Background	0	2	false
100.000	0.000	7	Mark	navigate
200.000	0.000	7	Mark	first-contentful-paint
300.000	0.000	7	Mark	load
120.000	40.000	7	Task	bindings_timers.odin:131	Background	1	2	true
130.000	10.000	7	Work		Arrival	1	1	false
150.000	5.000	9	Task	elsewhere:1	Background	1	2	true
170.000	100.000	7	Phase	frame
170.000	60.000	7	Phase	wait
230.000	20.000	7	Phase	layout
300.000	20.000	7	Task	client.odin:5	Arrival	1	1	false
2000.000	10.000	7	Task	client.odin:5	Arrival	1	1	false
`

@(test)
threadtime_counts_each_instant_once_for_the_innermost_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	l := load_read(TRACE)
	testing.expect_value(t, l.navigate, 100)
	testing.expect_value(t, l.contentful, 200)
	testing.expect_value(t, l.load_event, 300)
	r := report_of(l)
	third := Owner{CLASS_BACKGROUND, "https://ads.test", true}
	first := Owner{CLASS_ARRIVAL, "https://a.test", false}
	frame := Owner{CLASS_INPUT, BROWSER_ORIGIN, false}
	testing.expect_value(t, r.by_owner[third].contentful, 30)   // its 40 less the script inside it; another thread's task is not here
	testing.expect_value(t, r.by_owner[first].contentful, 10)
	testing.expect_value(t, r.by_owner[frame].contentful, 0)    // the frame's wait is no work, and its layout comes after the paint
	testing.expect_value(t, r.by_owner[frame].settled, 40)      // layout, and the rest of the frame after it
	testing.expect_value(t, r.by_owner[first].settled, 30)
	testing.expect_value(t, r.busy.contentful, 40)
	testing.expect_value(t, r.by_task[Key{third, "bindings_timers.odin:131"}].settled, 30)
}

@(test)
threadtime_settles_at_the_first_quiet_window_after_the_load :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, load_read(TRACE).settled, 320)   // (10 ms of work come far later: a timer, not a thread at work)
	// busy every 100 ms for 60 ms past the load, then free: the windows with their share of work do not count
	busy := Load{load_event = 0, segments = {{start = 0, end = 60}, {start = 100, end = 160}, {start = 200, end = 260}, {start = 300, end = 360}, {start = 400, end = 460}, {start = 500, end = 560}, {start = 1200, end = 1201}}}
	testing.expect_value(t, settled_at(busy), 560)
	// a trace that ends with the thread at work has not settled
	never := Load{load_event = 0, segments = {{start = 0, end = 300}, {start = 300, end = 600}}}
	testing.expect_value(t, settled_at(never), -1)
}

// The frame of TRACE: its layout is the frame's own, its wait no work but counted apart; one frame begun, after the paint.
@(test)
threadtime_splits_a_frame_by_its_phases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r := report_of(load_read(TRACE))
	testing.expect_value(t, r.by_phase["layout"].settled, 20)
	testing.expect_value(t, r.by_phase["frame"].settled, 20)       // (the frame's rest, after its layout, up to the task at 300 that is not its own)
	testing.expect_value(t, r.by_phase[PHASE_WAIT].settled, 60)
	testing.expect_value(t, r.by_phase[PHASE_WAIT].contentful, 30)
	testing.expect_value(t, r.busy.settled, 100)                  // (the wait is not busy: 30 + 10 of the first task, 40 of the frame, 20 of the last)
	testing.expect_value(t, r.frames.settled, 1)
	testing.expect_value(t, r.frames.contentful, 1)               // (begun at 170, before the paint at 200)
}
