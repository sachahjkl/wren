package host

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"

@(private = "file")
Counter :: struct { n: int, order: [dynamic]int }

@(private = "file")
bump :: proc(data: rawptr) { c := (^Counter)(data); c.n += 1 }

@(private = "file")
Tagged :: struct { c: ^Counter, tag: int }

@(private = "file")
record :: proc(data: rawptr) { t := (^Tagged)(data); append(&t.c.order, t.tag) }

@(test)
timers_fire_in_deadline_order :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	c: Counter
	defer delete(c.order)
	a, b, d := Tagged{&c, 1}, Tagged{&c, 2}, Tagged{&c, 3}
	set_timer(&l, 30, 0, record, &d)
	set_timer(&l, 10, 0, record, &a)
	set_timer(&l, 20, 0, record, &b)
	for len(c.order) < 3 { loop_wait(&l, 200) }
	testing.expect_value(t, len(c.order), 3)
	testing.expect_value(t, c.order[0], 1)
	testing.expect_value(t, c.order[1], 2)
	testing.expect_value(t, c.order[2], 3)
	testing.expect_value(t, next_timeout_ms(&l), -1)
}

@(test)
cleared_and_scoped_timers_never_fire :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	c: Counter
	h := set_timer(&l, 5, 0, bump, &c)
	testing.expect(t, clear_timer(&l, h))
	testing.expect(t, !clear_timer(&l, h))
	scope := base.scope_make("doc")
	set_timer(&l, 5, 0, bump, &c, scope)
	set_timer(&l, 5, 10, bump, &c, scope)
	base.scope_close(scope)
	time.sleep(30 * time.Millisecond)
	run_ready(&l)
	testing.expect_value(t, c.n, 0)
	testing.expect_value(t, l.timers.count, 0)
}

@(test)
interval_does_not_replay_a_burst :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	c: Counter
	h := set_timer(&l, 5, 5, bump, &c)
	time.sleep(60 * time.Millisecond)   // the loop was stalled for ~12 periods
	run_ready(&l)
	testing.expect_value(t, c.n, 1)
	clear_timer(&l, h)
}

@(test)
timer_scheduling_timer_with_zero_delay_does_not_spin :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	State :: struct { l: ^Loop, n: int }
	s := State{&l, 0}
	// one run_ready may only run the timers due when it starts
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
	for finished < len(jobs) { loop_wait(&l, 50) }
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
	deadline := time.tick_now()
	for c.n < THREADS * PER {
		loop_wait(&l, 50)
		if time.duration_seconds(time.tick_since(deadline)) > 10 { break }
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	run_ready(&l)
	testing.expect_value(t, c.n, THREADS * PER)
}
