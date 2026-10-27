package host

import "core:container/priority_queue"
import "core:sync"
import "core:testing"
import "core:thread"
import "wb:base"

@(private = "file")
Counter :: struct { n: int, order: [dynamic]int }

@(private = "file")
bump :: proc(data: rawptr) { c := (^Counter)(data); c.n += 1 }

@(private = "file")
Tagged :: struct { c: ^Counter, tag: int }

@(private = "file")
record :: proc(data: rawptr) { t := (^Tagged)(data); append(&t.c.order, t.tag) }

// The loop's clock is the test's: time moves only when the test says so.
@(private = "file")
advance :: proc(clock: ^i64, ms: f64) { sync.atomic_add(clock, i64(ms * 1e6)) }

@(test)
timers_fire_in_deadline_order :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	clock: i64
	l.manual_ns = &clock
	c: Counter
	defer delete(c.order)
	a, b, d := Tagged{&c, 1}, Tagged{&c, 2}, Tagged{&c, 3}
	set_timer(&l, 30, 0, record, &d)
	set_timer(&l, 10, 0, record, &a)
	set_timer(&l, 20, 0, record, &b)
	testing.expect_value(t, next_timeout_ms(&l), 10)
	advance(&clock, 9.5)
	testing.expect_value(t, run_ready(&l), 0)
	testing.expect_value(t, next_timeout_ms(&l), 1)   // rounded up: never woken before the deadline
	advance(&clock, 0.5)
	testing.expect_value(t, run_ready(&l), 1)
	advance(&clock, 100)   // the other two are overdue: they run in deadline order, not in creation order
	testing.expect_value(t, run_ready(&l), 2)
	testing.expect_value(t, len(c.order), 3)
	testing.expect_value(t, c.order[0], 1)
	testing.expect_value(t, c.order[1], 2)
	testing.expect_value(t, c.order[2], 3)
	testing.expect_value(t, next_timeout_ms(&l), -1)
	// the same deadline: creation order (HTML: timers with the same timeout run in the order they were set)
	clear(&c.order)
	tags: [16]Tagged
	for i in 0 ..< len(tags) { tags[i] = Tagged{&c, i}; set_timer(&l, 4, 0, record, &tags[i]) }
	advance(&clock, 4)
	testing.expect_value(t, run_ready(&l), len(tags))
	for i in 0 ..< len(tags) { testing.expect_value(t, c.order[i], i) }
}

@(test)
cleared_and_scoped_timers_never_fire :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	clock: i64
	l.manual_ns = &clock
	c: Counter
	h := set_timer(&l, 5, 0, bump, &c)
	testing.expect(t, clear_timer(&l, h))
	testing.expect(t, !clear_timer(&l, h))
	scope := base.scope_make("doc")
	set_timer(&l, 5, 0, bump, &c, scope)
	set_timer(&l, 5, 10, bump, &c, scope)
	base.scope_close(scope)
	advance(&clock, 30)
	run_ready(&l)
	testing.expect_value(t, c.n, 0)
	testing.expect_value(t, l.timers.count, 0)
	testing.expect_value(t, next_timeout_ms(&l), -1)   // the stale queue entries are dropped
}

@(test)
interval_does_not_replay_a_burst :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	clock: i64
	l.manual_ns = &clock
	c: Counter
	h := set_timer(&l, 5, 5, bump, &c)
	advance(&clock, 60)   // the loop was stalled for 12 periods
	run_ready(&l)
	testing.expect_value(t, c.n, 1)
	run_ready(&l)
	testing.expect_value(t, c.n, 1)   // the next tick is counted from now
	testing.expect(t, next_timeout_ms(&l) > 0, "the next tick is in the future")
	advance(&clock, 5)
	run_ready(&l)
	testing.expect_value(t, c.n, 2)
	clear_timer(&l, h)
}

@(test)
timer_scheduling_timer_with_zero_delay_does_not_spin :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	clock: i64
	l.manual_ns = &clock
	State :: struct { l: ^Loop, n: int, clock: ^i64 }
	s := State{&l, 0, &clock}
	// one run_ready may only run the timers due when it starts, even when the clock does not move in between
	step :: proc(data: rawptr) {
		s := (^State)(data)
		s.n += 1
		set_timer(s.l, 0, 0, step, s)
	}
	set_timer(&l, 0, 0, step, &s)
	run_ready(&l)
	testing.expect_value(t, s.n, 1)
	run_ready(&l)
	testing.expect_value(t, s.n, 2)
}

@(test)
blocking_jobs_run_off_thread_and_complete_on_loop :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	pool: Blocking_Pool
	blocking_init(&pool, &l, 3)
	defer blocking_destroy(&pool)

	Job :: struct { worker_thread, done_thread: int, value: int, finished: ^int }
	finished := 0
	jobs: [50]Job
	main_id := sync_current_thread_id()
	for &j, i in jobs {
		j.value = i
		j.finished = &finished
		run_blocking(&pool, proc(data: rawptr) {
			j := (^Job)(data)
			j.worker_thread = sync_current_thread_id()
			j.value *= 2
		}, proc(data: rawptr) {
			j := (^Job)(data)
			j.done_thread = sync_current_thread_id()
			j.finished^ += 1
		}, &j)
	}
	for finished < len(jobs) { loop_wait(&l) }   // each completion is a post: the wait always ends
	for j, i in jobs {
		testing.expect_value(t, j.value, i * 2)
		testing.expect(t, j.worker_thread != main_id, "work ran on a worker")
		testing.expect_value(t, j.done_thread, main_id)   // completion on the loop thread
	}
}

@(private = "file")
sync_current_thread_id :: proc() -> int { return int(sync.current_thread_id()) }

@(test)
posts_from_many_threads_are_all_delivered_and_wakes_coalesce :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	c: Counter
	Work :: struct { l: ^Loop, c: ^Counter }
	w := Work{&l, &c}
	THREADS :: 8
	PER :: 2000
	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		threads[i] = thread.create_and_start_with_data(&w, proc(data: rawptr) {
			w := (^Work)(data)
			for _ in 0 ..< PER { post(w.l, bump, w.c) }
		})
	}
	// every post that finds no wake pending issues one: a wait never misses the last posts
	for c.n < THREADS * PER { loop_wait(&l) }
	for th in threads { thread.join(th); thread.destroy(th) }
	run_ready(&l)
	testing.expect_value(t, c.n, THREADS * PER)
	testing.expect_value(t, next_timeout_ms(&l), -1)   // no wake left pending
}

// Many due timers that take time: one turn stops at the time slice, the rest run at the next turns (none is lost).
@(test)
timer_slice_bounds_a_turn :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	clock: i64
	l.manual_ns = &clock
	l.timer_slice_ns = 2_000_000
	Slow :: struct { n: int, clock: ^i64 }
	slow :: proc(data: rawptr) {   // each callback "takes" 0.5 ms of the loop's clock
		s := (^Slow)(data)
		s.n += 1
		advance(s.clock, 0.5)
	}
	s := Slow{clock = &clock}
	for _ in 0 ..< 100 { set_timer(&l, 0, 0, slow, &s) }
	testing.expect_value(t, run_ready(&l), 4)   // 4 x 0.5 ms fill the 2 ms slice
	testing.expect_value(t, next_timeout_ms(&l), 0)   // the rest are due now: the turn signalled the next one
	turns := 1
	for s.n < 100 && turns < 1000 { run_ready(&l); turns += 1 }
	testing.expect_value(t, s.n, 100)
	testing.expect_value(t, turns, 25)
	// a slow callback still runs alone in its turn: the slice is checked between callbacks
	l.timer_slice_ns = 100_000
	s.n = 0
	for _ in 0 ..< 3 { set_timer(&l, 0, 0, slow, &s) }
	testing.expect_value(t, run_ready(&l), 1)
	// slice 0: every due timer in one turn
	l.timer_slice_ns = 0
	s.n = 0
	for _ in 0 ..< 20 { set_timer(&l, 0, 0, slow, &s) }
	testing.expect_value(t, run_ready(&l), 22)   // with the 2 left from above
}
// Delays that do not fit (NaN, infinities, 1e300 ms) mean "never", not "now"; clearing long timers in a loop does not
// pile up entries in the queue.
@(test)
timer_delays_saturate_and_cleared_timers_go :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	c: Counter
	nan := transmute(f64)u64(0x7FF8_0000_0000_0001)
	inf := transmute(f64)u64(0x7FF0_0000_0000_0000)
	for d in ([]f64{1e300, inf}) { set_timer(&l, d, 0, bump, &c) }
	set_timer(&l, 0, 1e300, bump, &c)   // an interval of 1e300 ms: once now, then never
	set_timer(&l, nan, 0, bump, &c)     // NaN: at once
	run_ready(&l)
	testing.expect_value(t, c.n, 2)
	testing.expect(t, next_timeout_ms(&l) > 1_000_000, "the others are far away")
	for _ in 0 ..< 100_000 {
		h := set_timer(&l, 1e9, 0, bump, &c)
		clear_timer(&l, h)
	}
	testing.expectf(t, priority_queue.len(l.queue) < 200, "%d queue entries", priority_queue.len(l.queue))
	run_ready(&l)
	testing.expect_value(t, c.n, 2)
}

@(private = "file")
count_discarded :: proc(data: rawptr) { (^Counter)(data).n += 1 }

// The tasks nobody will run: the ones of one function are handed to the discarder, the others stay for the loop.
@(test)
posted_tasks_that_will_not_run_are_discarded :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	ran, discarded: Counter
	post(&l, bump, &ran)
	post(&l, record, &Tagged{&ran, 7})
	post(&l, bump, &ran)
	post(&l, bump, &ran)
	discard_posted(&l, bump, count_discarded)
	// (the discarder counted into the data of each task: the same counter here)
	testing.expect_value(t, ran.n, 3)
	testing.expect_value(t, run_ready(&l), 1)   // the one task of the other function is still there
	testing.expect_value(t, len(ran.order), 1)
	testing.expect_value(t, ran.n, 3)           // and the discarded ones never ran as tasks
	_ = discarded
	delete(ran.order)
}