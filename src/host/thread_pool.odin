package host

// Fork-join over a fixed set of threads: `parallel_for` runs fn(data, i) for every i in [0, count) on the pool's threads
// and on the calling thread, and returns when all are done. For work the caller needs back now (a style pass inside a
// frame), unlike Blocking_Pool whose results come back later through the loop. Items are taken one by one from a shared
// counter, so uneven items balance themselves. One `parallel_for` at a time per pool; the procedure must only touch
// what its item owns.

import "core:sync"
import "core:time"
import "wb:base"

Parallel_Proc :: #type proc(data: rawptr, index: int)

// The round's state, `Thread_Pool.round` (a futex the helpers sleep on): even, a round's number, its fields written
// (0: none yet); odd, parallel_for is writing the next round's fields. A helper reads the fields of an even round and
// takes them only if the round is still the same afterwards (a sequence lock: the caller never waits for a reader).
@(private) ROUND_STEP :: 2

Thread_Pool :: struct {
	threads:    [dynamic]^Thread,
	round:      sync.Futex,   // atomic: see ROUND_STEP; parallel_for moves it, the helpers wait on it
	stopping:   b32,          // atomic: thread_pool_destroy, before it moves `round` a last time
	fn:         Parallel_Proc,   // the round's, written while `round` is odd
	data:       rawptr,
	count:      int,
	next:       u64,          // atomic: round << 32 | next item to take (see pool_take)
	remaining:  int,          // atomic: items not finished
	done:       sync.Sema,
}

// `threads` helpers besides the caller (0 = everything runs on the caller).
//
// The helpers start from the process's context, never the caller's: they outlive it and run the items of whoever calls
// parallel_for, and what an item allocates on them (a style thread's pass and arena) goes through their context's
// allocator, from several threads at once. A test's allocator (a rollback stack per test, not thread-safe) shared that
// way corrupted the style tests' memory now and then (a rule pointer holding a node handle, a bounds trap on a pool
// thread). The pool itself is in the process's memory too (thread_pool_destroy frees it there).
thread_pool_make :: proc(threads: int, stack_bytes := 0) -> ^Thread_Pool {
	context = base.process_context()
	p := new(Thread_Pool)
	for _ in 0 ..< max(threads, 0) {
		t := thread_start(pool_thread, p, stack_bytes, name = "wren-pool")
		if t == nil { break }
		append(&p.threads, t)
	}
	return p
}

thread_pool_destroy :: proc(p: ^Thread_Pool) {
	if p == nil { return }
	context = base.process_context()   // (where thread_pool_make allocated)
	sync.atomic_store(&p.stopping, true)
	sync.atomic_add(&p.round, ROUND_STEP)
	sync.futex_broadcast(&p.round)
	for t in p.threads { thread_join(t) }
	delete(p.threads)
	free(p)
}

thread_pool_size :: proc(p: ^Thread_Pool) -> int { return p == nil ? 1 : len(p.threads) + 1 }

parallel_for :: proc(p: ^Thread_Pool, count: int, fn: Parallel_Proc, data: rawptr) {
	if count <= 0 { return }
	if p == nil || len(p.threads) == 0 || count == 1 {
		for i in 0 ..< count { fn(data, i) }
		return
	}
	// (the caller only moves `round`: one parallel_for at a time per pool)
	sync.atomic_add(&p.round, ROUND_STEP / 2)   // odd: being written
	p.fn, p.data, p.count = fn, data, count
	gen := u64(sync.atomic_load(&p.round)) + ROUND_STEP / 2
	sync.atomic_store(&p.remaining, count)
	sync.atomic_store(&p.next, (gen & 0xffff_ffff) << 32)
	sync.atomic_store(&p.round, sync.Futex(gen))   // even: written
	sync.futex_broadcast(&p.round)
	if wait_hook.fn != nil {
		pool_take(p, gen, fn, data, count, hooked = true)
		for !sync.sema_wait_with_timeout(&p.done, time.Duration(max(wait_hook.every_ns, 100_000))) { wait_hook.fn(wait_hook.user) }
		return
	}
	pool_take(p, gen, fn, data, count)
	sync.sema_wait(&p.done)   // posted exactly once per round, by whoever finishes the last item (maybe us)
}

// The calling thread lent to other work during a parallel_for: between the items it takes, and while it waits for the
// pool's threads to finish theirs, `fn` is called at most every `every_ns` (the browser draws its interface there while
// a long style pass runs on the pool). `fn` must not touch what the items do. Only for parallel_for called on the
// thread that set it (each thread its own: several Apps run in one process); nil removes it.
Wait_Hook :: struct {
	fn:       proc(user: rawptr),
	user:     rawptr,
	every_ns: i64,
}

@(private, thread_local)
wait_hook: Wait_Hook

set_parallel_wait_hook :: proc(fn: proc(user: rawptr), user: rawptr, every_ns: i64) {
	wait_hook = Wait_Hook{fn = fn, user = user, every_ns = every_ns}
}

// Items are claimed with a compare-and-swap on a counter tagged with the round's generation: a helper still leaving
// the previous round (its last claim failed, or it has not looked yet) cannot take an item of the next one with the
// previous round's procedure, nor claim one twice by adding to a counter that was reset under it.
@(private)
pool_take :: proc(p: ^Thread_Pool, gen: u64, fn: Parallel_Proc, data: rawptr, count: int, hooked := false) {
	tag := (gen & 0xffff_ffff) << 32
	last := hooked ? time.tick_now() : {}
	for {
		if hooked && time.tick_since(last) >= time.Duration(wait_hook.every_ns) {
			wait_hook.fn(wait_hook.user)
			last = time.tick_now()
		}
		v := sync.atomic_load(&p.next)
		if v &~ 0xffff_ffff != tag { return }   // another round now
		i := int(v & 0xffff_ffff)
		if i >= count { return }
		if _, ok := sync.atomic_compare_exchange_weak(&p.next, v, v + 1); !ok { continue }
		fn(data, i)
		if sync.atomic_sub(&p.remaining, 1) == 1 { sync.sema_post(&p.done) }
	}
}

@(private)
pool_thread :: proc(data: rawptr) {
	p := (^Thread_Pool)(data)
	seen: sync.Futex
	for {
		round := sync.atomic_load(&p.round)
		if sync.atomic_load(&p.stopping) { return }
		if round == seen || round % ROUND_STEP != 0 { sync.futex_wait(&p.round, u32(round)); continue }
		fn, user, count := p.fn, p.data, p.count
		sync.atomic_thread_fence(.Acquire)   // (the reads above stay above the check below)
		if sync.atomic_load(&p.round) != round { continue }   // the next round was being written meanwhile
		seen = round
		pool_take(p, u64(round), fn, user, count)
		free_all(context.temp_allocator)
	}
}
