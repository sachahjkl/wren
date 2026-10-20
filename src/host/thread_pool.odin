package host

// Fork-join over a fixed set of threads: `parallel_for` runs fn(data, i) for every i in [0, count) on the pool's threads
// and on the calling thread, and returns when all are done. For work the caller needs back now (a style pass inside a
// frame), unlike Blocking_Pool whose results come back later through the loop. Items are taken one by one from a shared
// counter, so uneven items balance themselves. One `parallel_for` at a time per pool; the procedure must only touch
// what its item owns.

import "core:sync"

Parallel_Proc :: #type proc(data: rawptr, index: int)

Thread_Pool :: struct {
	threads:    [dynamic]^Thread,
	mu:         sync.Mutex,
	cond:       sync.Cond,
	generation: u64,          // bumped for each parallel_for: wakes the threads
	active:     int,          // helpers between taking a generation and leaving pool_take (under mu)
	idle:       sync.Cond,    // signalled when active drops to 0
	stopping:   bool,
	fn:         Parallel_Proc,
	data:       rawptr,
	count:      int,
	next:       u64,          // atomic: generation << 32 | next item to take (see pool_take)
	remaining:  int,          // atomic: items not finished
	done:       sync.Sema,
}

// `threads` helpers besides the caller (0 = everything runs on the caller).
thread_pool_make :: proc(threads: int, stack_bytes := 0) -> ^Thread_Pool {
	p := new(Thread_Pool)
	for _ in 0 ..< max(threads, 0) {
		t := thread_start(pool_thread, p, stack_bytes)
		if t == nil { break }
		append(&p.threads, t)
	}
	return p
}

thread_pool_destroy :: proc(p: ^Thread_Pool) {
	if p == nil { return }
	sync.mutex_lock(&p.mu)
	p.stopping = true
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
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
	sync.mutex_lock(&p.mu)
	// a helper may still be leaving the previous round (it took the last index past its count): the counters are reset
	// only once none is, or it could take an index of this round before the reset and run that item twice
	for p.active > 0 { sync.cond_wait(&p.idle, &p.mu) }
	p.fn, p.data, p.count = fn, data, count
	p.generation += 1
	gen := p.generation
	sync.atomic_store(&p.remaining, count)
	sync.atomic_store(&p.next, (gen & 0xffff_ffff) << 32)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
	pool_take(p, gen, fn, data, count)
	sync.sema_wait(&p.done)   // posted exactly once per round, by whoever finishes the last item (maybe us)
}

// Items are claimed with a compare-and-swap on a counter tagged with the round's generation: a helper still leaving
// the previous round (its last claim failed, or it has not looked yet) cannot take an item of the next one with the
// previous round's procedure, nor claim one twice by adding to a counter that was reset under it.
@(private)
pool_take :: proc(p: ^Thread_Pool, gen: u64, fn: Parallel_Proc, data: rawptr, count: int) {
	tag := (gen & 0xffff_ffff) << 32
	for {
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
	seen: u64
	for {
		sync.mutex_lock(&p.mu)
		for p.generation == seen && !p.stopping { sync.cond_wait(&p.cond, &p.mu) }
		if p.stopping { sync.mutex_unlock(&p.mu); return }
		seen = p.generation
		fn, user, count := p.fn, p.data, p.count
		sync.mutex_unlock(&p.mu)
		pool_take(p, seen, fn, user, count)
		free_all(context.temp_allocator)
	}
}
