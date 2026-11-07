package host

import "core:testing"
import "core:thread"
import "wb:base"

@(private = "file")
Work_Seen :: struct {
	l:    ^Loop,
	seen: [dynamic]base.Work,
}

@(private = "file")
see_work :: proc(data: rawptr) {
	s := (^Work_Seen)(data)
	append(&s.seen, s.l.work)
}

@(test)
work_passes_from_a_task_to_what_it_makes :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	clock: Virtual_Clock
	clock_virtual(&l, &clock)
	s := Work_Seen{l = &l}
	defer delete(s.seen)
	ads := origin_number(&l, "https://ads.test")
	testing.expect_value(t, origin_number(&l, "https://other.test"), ads + 1)
	testing.expect_value(t, origin_number(&l, "https://ads.test"), ads)
	owner := base.Work{page = 3, origin = ads, class = .Arrival, third_party = true}
	post_work(&l, proc(data: rawptr) {
		s := (^Work_Seen)(data)
		see_work(s)
		set_timer(s.l, 0, 0, see_work, s)   // what a task makes works for the same owner, in the class it says
		post(s.l, see_work, s, .Input)
		// inside the task, a script of the page's own origin: what it makes is its, the task goes on after it
		scope := work_enter(s.l, base.Work{page = 3, origin = 9, class = .Arrival})
		set_timer(s.l, 0, 0, see_work, s)
		work_leave(s.l, scope)
		see_work(s)
	}, &s, owner)
	run_ready(&l)
	testing.expect_value(t, l.work, base.Work{})   // nothing of it stays after the task
	run_ready(&l)
	run_ready(&l)
	testing.expect_value(t, len(s.seen), 5)
	testing.expect_value(t, s.seen[0], owner)
	testing.expect_value(t, s.seen[1], owner)
	testing.expect_value(t, s.seen[2], base.Work{page = 3, origin = ads, class = .Input, third_party = true})
	testing.expect_value(t, s.seen[3], base.Work{page = 3, origin = ads, class = .Background, third_party = true})
	testing.expect_value(t, s.seen[4], base.Work{page = 3, origin = 9, class = .Background})
}

@(test)
a_post_from_another_thread_inherits_nothing :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	s := Work_Seen{l = &l}
	defer delete(s.seen)
	// the loop's thread is known and at work for a page while another thread posts
	post_work(&l, proc(data: rawptr) {
		th := thread.create_and_start_with_data(data, proc(d: rawptr) {
			s := (^Work_Seen)(d)
			post(s.l, see_work, s, .Arrival)
		})
		thread.join(th)
		thread.destroy(th)
	}, &s, base.Work{page = 4, origin = 2, third_party = true})
	run_ready(&l)
	run_ready(&l)
	testing.expect_value(t, len(s.seen), 1)
	testing.expect_value(t, s.seen[0], base.Work{class = .Arrival})
}
