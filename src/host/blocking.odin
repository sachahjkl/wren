package host

// A small pool of worker threads for blocking work (file reads, hashing, anything that must not run on the UI thread).
// `work` runs on a worker; `done` runs on the loop thread afterwards, with the same data pointer. The data must stay
// valid until `done` has run (heap or loop-owned), and is never touched by the submitter in between.

import "base:runtime"
import "core:sync"
import "core:thread"

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
	threads:  [dynamic]^thread.Thread,
	stopping: bool,
}

blocking_init :: proc(p: ^Blocking_Pool, loop: ^Loop, workers := 4) {
	p.loop = loop
	p.queue = make([dynamic]Blocking_Job, runtime.heap_allocator())
	p.threads = make([dynamic]^thread.Thread)
	for _ in 0 ..< workers {
		t := thread.create(blocking_worker)
		t.data = p
		t.init_context = context
		thread.start(t)
		append(&p.threads, t)
	}
}

// Waits for running jobs to finish; queued jobs that never started are dropped (their `done` is not called).
blocking_destroy :: proc(p: ^Blocking_Pool) {
	sync.mutex_lock(&p.mu)
	p.stopping = true
	clear(&p.queue)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
	for t in p.threads { thread.join(t); thread.destroy(t) }
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
blocking_worker :: proc(t: ^thread.Thread) {
	p := (^Blocking_Pool)(t.data)
	for {
		sync.mutex_lock(&p.mu)
		for len(p.queue) == 0 && !p.stopping { sync.cond_wait(&p.cond, &p.mu) }
		if p.stopping { sync.mutex_unlock(&p.mu); return }
		job := p.queue[0]
		ordered_remove(&p.queue, 0)
		sync.mutex_unlock(&p.mu)
		job.work(job.data)
		free_all(context.temp_allocator)   // this thread's own (see core:thread): nothing outlives a job
		post(p.loop, job.done, job.data)
	}
}
