package host

// A small pool of worker threads for blocking work (file reads, hashing, anything that must not run on the UI thread).
// `work` runs on a worker; `done` runs on the loop thread afterwards, with the same data pointer. The data must stay
// valid until `done` has run (heap or loop-owned), and is never touched by the submitter in between.

import "core:sync"
import "wb:base"

Blocking_Job :: struct {
	work: Task_Proc,
	done: Task_Proc,
	data: rawptr,
}

Blocking_Pool :: struct {
	loop:     ^Loop,
	mu:       sync.Mutex,
	cond:     sync.Cond,
	queue:    [dynamic]Blocking_Job,
	threads:  [dynamic]^Thread,
	stopping: bool,
}

blocking_init :: proc(p: ^Blocking_Pool, loop: ^Loop, workers := 4) {
	p.loop = loop
	p.queue = make([dynamic]Blocking_Job, base.process_allocator())
	p.threads = make([dynamic]^Thread)
	// (thread_start: the caller's context, and a temporary allocator of the worker's own, destroyed when it ends)
	for _ in 0 ..< workers {
		if t := thread_start(blocking_worker, p); t != nil { append(&p.threads, t) }
	}
}

// Waits for running jobs to finish; queued jobs that never started are dropped (their `done` is not called).
blocking_destroy :: proc(p: ^Blocking_Pool) {
	sync.mutex_lock(&p.mu)
	p.stopping = true
	clear(&p.queue)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
	for t in p.threads { thread_join(t) }
	delete(p.threads)
	delete(p.queue)
}

// Loop thread (or any thread).
run_blocking :: proc(p: ^Blocking_Pool, work, done: Task_Proc, data: rawptr) {
	sync.mutex_lock(&p.mu)
	append(&p.queue, Blocking_Job{work, done, data})
	sync.cond_signal(&p.cond)
	sync.mutex_unlock(&p.mu)
}

@(private)
blocking_worker :: proc(data: rawptr) {
	p := (^Blocking_Pool)(data)
	for {
		sync.mutex_lock(&p.mu)
		for len(p.queue) == 0 && !p.stopping { sync.cond_wait(&p.cond, &p.mu) }
		if p.stopping { sync.mutex_unlock(&p.mu); return }
		job := p.queue[0]
		ordered_remove(&p.queue, 0)
		sync.mutex_unlock(&p.mu)
		job.work(job.data)
		free_all(context.temp_allocator)   // this thread's own (thread_start): nothing outlives a job
		post(p.loop, job.done, job.data)
	}
}
