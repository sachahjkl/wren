package host

import "core:log"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:base"

@(private = "file") WAIT_HOOK_ITEM_TIME :: 2 * time.Millisecond   // what an item of parallel_for_wait_hook takes, in a performance run
@(private = "file") WAIT_HOOK_EVERY_NS :: 200_000

@(private = "file")
Probe :: struct { depth: int, temp_ok: bool }

@(private = "file")
recurse :: proc(n: int) -> int {
	buf: [1024]u8   // 1 KiB of stack per level
	buf[n % len(buf)] = u8(n)
	if n == 0 { return int(buf[0]) }
	return recurse(n - 1) + int(buf[n % len(buf)]) - int(u8(n))
}

@(test)
thread_with_its_own_stack_and_temp_allocator :: proc(t: ^testing.T) {
	pr: Probe
	th := thread_start(proc(data: rawptr) {
		p := (^Probe)(data)
		p.depth = recurse(3000)   // ~3 MiB of stack: more than the default thread stack
		s := make([]u8, 1 << 20, context.temp_allocator)
		p.temp_ok = len(s) == 1 << 20
	}, &pr, 8 << 20, .Below_Normal)
	testing.expect(t, th != nil)
	thread_join(th)
	testing.expect_value(t, pr.depth, 0)
	testing.expect(t, pr.temp_ok, "the thread has a temporary allocator of its own")
}

@(private = "file")
Flood :: struct { l: ^Loop, received: int }

@(test)
posts_from_many_threads_all_arrive :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	f := Flood{l = &l}
	THREADS :: 8
	EACH :: 2000
	threads: [THREADS]^Thread
	for i in 0 ..< THREADS {
		threads[i] = thread_start(proc(data: rawptr) {
			fl := (^Flood)(data)
			for _ in 0 ..< EACH { post(fl.l, proc(d: rawptr) { (^Flood)(d).received += 1 }, fl) }
		}, &f)
	}
	for f.received < THREADS * EACH { loop_wait(&l, 100) }
	for th in threads { thread_join(th) }
	testing.expect_value(t, f.received, THREADS * EACH)
}

@(private = "file")
Round :: struct { hits: []int }

// Rounds back to back, with few items each: a helper leaving one round while the next starts must neither run an item
// of the new round with the old round's procedure nor claim an item twice (every item runs exactly once per round).
@(test)
thread_pool_rounds_back_to_back :: proc(t: ^testing.T) {
	pool := thread_pool_make(7)
	defer thread_pool_destroy(pool)
	hits := make([]int, 16)
	defer delete(hits)
	other := make([]int, 16)
	defer delete(other)
	bad := 0
	for r in 0 ..< 20_000 {
		n := 1 + r % 16
		a, b := Round{hits[:n]}, Round{other[:n]}
		which := r % 2 == 0 ? &a : &b
		parallel_for(pool, n, r % 2 == 0 ? proc(data: rawptr, i: int) {
			_ = sync_add((^Round)(data).hits, i)
		} : proc(data: rawptr, i: int) {
			_ = sync_add((^Round)(data).hits, i)
		}, which)
		for i in 0 ..< n {
			if which.hits[i] != 1 { bad += 1 }
			which.hits[i] = 0
		}
	}
	testing.expect_value(t, bad, 0)
}

@(private = "file")
sync_add :: proc(s: []int, i: int) -> int { return sync.atomic_add(&s[i], 1) }

Round64 :: struct { hits: [64]i32 }

// Rounds back to back with different counts: every item of every round runs exactly once (a helper still leaving a
// round must not take an index of the next one before its counters are reset).
@(test)
parallel_for_rounds_back_to_back :: proc(t: ^testing.T) {
	pool := thread_pool_make(4)
	defer thread_pool_destroy(pool)
	for round in 0 ..< 3000 {
		r: Round64
		count := 1 + (round * 7) % len(r.hits)
		parallel_for(pool, count, proc(data: rawptr, i: int) { sync.atomic_add(&(^Round64)(data).hits[i], 1) }, &r)
		for i in 0 ..< len(r.hits) {
			want := i32(i < count ? 1 : 0)
			if r.hits[i] != want { testing.expectf(t, false, "round %d item %d ran %d times (count %d)", round, i, r.hits[i], count); return }
		}
	}
}

// The calling thread is lent to its wait hook during a parallel_for (thread_pool.odin): every item still runs exactly
// once, and the hook runs while the pool's threads work.
@(test)
parallel_for_wait_hook :: proc(t: ^testing.T) {
	pool := thread_pool_make(2)
	defer thread_pool_destroy(pool)
	Job :: struct { done: [64]int, hooks, helpers: int, caller: int, measuring: bool }
	job := Job{caller = sync.current_thread_id(), measuring = base.perf_enabled()}
	set_parallel_wait_hook(proc(user: rawptr) { sync.atomic_add(&(^Job)(user).hooks, 1) }, &job, WAIT_HOOK_EVERY_NS)
	defer set_parallel_wait_hook(nil, nil, 0)
	parallel_for(pool, len(job.done), proc(data: rawptr, i: int) {
		j := (^Job)(data)
		sync.atomic_add(&j.done[i], 1)
		// (a performance run looks at how often the hook runs in real time: there an item truly takes that time)
		if j.measuring { time.sleep(WAIT_HOOK_ITEM_TIME); return }
		// The barrier: an item of a helper ends once the hook has run, which only the calling thread does; an item of the
		// calling thread once a helper is inside one, so that it cannot take them all before anyone waits.
		if sync.current_thread_id() == j.caller {
			base.await(j, proc(j: ^Job) -> bool { return sync.atomic_load(&j.helpers) > 0 })
		} else {
			sync.atomic_add(&j.helpers, 1)
			base.await(j, proc(j: ^Job) -> bool { return sync.atomic_load(&j.hooks) > 0 })
		}
	}, &job)
	for d, i in job.done { testing.expectf(t, d == 1, "item %d ran %d times", i, d) }
	testing.expectf(t, job.hooks >= 1, "the hook ran while the items did (%d times)", job.hooks)
	// how often it ran in the ~40 ms the items took depends on the scheduler: a performance test
	if !base.perf_skip("parallel_for_wait_hook: the hook runs at least 5 times in the items' ~40 ms") {
		testing.expectf(t, job.hooks >= 5, "the hook ran every 0.2 ms while the items did (%d times)", job.hooks)
	}
}
// What a round of parallel_for costs when its items cost nothing: the hand-over to the pool's threads and back. Numbers
// for docs/performance.md, not a check.
@(test)
parallel_for_round_cost :: proc(t: ^testing.T) {
	ROUND_BENCH_THREADS :: 4
	ROUND_BENCH_ROUNDS :: 20_000
	if base.perf_skip("parallel_for: the cost of a round of empty items") { return }
	pool := thread_pool_make(ROUND_BENCH_THREADS)
	defer thread_pool_destroy(pool)
	hits: [ROUND_BENCH_THREADS + 1]int
	t0 := time.tick_now()
	for _ in 0 ..< ROUND_BENCH_ROUNDS {
		parallel_for(pool, len(hits), proc(data: rawptr, i: int) { sync.atomic_add(&(^[ROUND_BENCH_THREADS + 1]int)(data)[i], 1) }, &hits)
	}
	us := time.duration_microseconds(time.tick_since(t0)) / ROUND_BENCH_ROUNDS
	testing.expect_value(t, hits[0], ROUND_BENCH_ROUNDS)
	log.infof("parallel_for: %.2f us a round of %d empty items on %d threads", us, len(hits), ROUND_BENCH_THREADS)
}
