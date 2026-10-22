package page

// Compiling large scripts off the interface thread (javascript.compile.offthread_min_bytes): when an external classic
// script arrives and its bytecode is not cached, a compile thread (each with an engine instance of its own, made from
// the same pre-initialized image) compiles it and stores the bytecode in the shared cache (package js) while the page
// goes on with its other work (other downloads, the parser's reveal, painting). The script runs when its turn comes
// and its bytecode is there: js_run finds it in the cache and does not parse it again.
//
// The threads are shared by every page, made on first use (javascript.compile.offthread_threads), and stopped by
// compile_shutdown (js_shutdown). A job outlives its page if the page closes: the result is only cached.

import "core:sync"
import "core:time"
import "wb:host"
import "wb:js"
import "wb:wasm"

@(private)
Compile_Job :: struct {
	page_id: u64,
	download: ^Script_Fetch,  // UI thread only, valid while the page lives
	source:  []byte,          // owned
	url:     string,          // owned
	key:     js.Key,
	ui_loop: ^host.Loop,
	ms:      f64,             // compile time (diagnostics)
	ok:      bool,
}

@(private)
Compile_Service :: struct {
	mu:       sync.Mutex,
	sema:     sync.Sema,
	queue:    [dynamic]^Compile_Job,
	threads:  [dynamic]^host.Thread,
	stop:     bool,
	opt:      wasm.Options,
	stack:    int,
	jobs:     int,          // done since the start (stats)
	total_ms: f64,
}

@(private)
compiler: Compile_Service

// What the compile threads did (tests, measurements).
Compile_Stats :: struct { threads, jobs: int, total_ms: f64 }

compile_stats :: proc() -> Compile_Stats {
	sync.mutex_lock(&compiler.mu)
	defer sync.mutex_unlock(&compiler.mu)
	return Compile_Stats{threads = len(compiler.threads), jobs = compiler.jobs, total_ms = compiler.total_ms}
}

@(private)
compile_thread_count :: proc(p: ^Page) -> int {
	n := p.settings.js_load.compile_threads
	if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
	return n
}

// An external classic script arrived: compile it on another thread when it is large and not cached yet.
@(private)
compile_offthread :: proc(p: ^Page, f: ^Script_Fetch) {
	n := compile_thread_count(p)
	if n == 0 || p.worker != nil || len(f.bytes) < p.settings.js.offthread_min_bytes || !js.cacheable(len(f.bytes)) { return }
	if !js_enabled(p) { return }
	u := f.final_url != "" ? f.final_url : f.url
	key := js.key_of(js_version(), 0, u, f.bytes[:])
	if code := js.lookup(key, context.temp_allocator); code != nil { return }
	if !compile_service_start(p, n) { return }
	job := new(Compile_Job)
	job.page_id = page_id(p)
	job.download = f
	job.source = make([]byte, len(f.bytes))
	copy(job.source, f.bytes[:])
	job.url = clone_heap(u)
	job.key = key
	job.ui_loop = p.loop
	f.compiling = true
	sync.mutex_lock(&compiler.mu)
	append(&compiler.queue, job)
	sync.mutex_unlock(&compiler.mu)
	sync.sema_post(&compiler.sema)
}

@(private)
compile_service_start :: proc(p: ^Page, n: int) -> bool {
	sync.mutex_lock(&compiler.mu)
	defer sync.mutex_unlock(&compiler.mu)
	if compiler.stop { return false }
	if len(compiler.threads) >= n { return true }
	compiler.opt = p.settings.wasm
	compiler.stack = p.settings.workers.thread_stack_bytes
	for len(compiler.threads) < n {
		t := host.thread_start(compile_main, nil, compiler.stack, .Below_Normal, "wren-js-compile")
		if t == nil { break }
		append(&compiler.threads, t)
	}
	return len(compiler.threads) > 0
}

// Stops the compile threads (process end, after every page closed). Jobs not started are dropped.
compile_shutdown :: proc() {
	sync.mutex_lock(&compiler.mu)
	compiler.stop = true
	threads := compiler.threads
	compiler.threads = nil
	sync.mutex_unlock(&compiler.mu)
	for _ in threads { sync.sema_post(&compiler.sema) }
	for t in threads { host.thread_join(t) }
	delete(threads)
	sync.mutex_lock(&compiler.mu)
	for j in compiler.queue { compile_job_free(j) }
	delete(compiler.queue)
	compiler.queue = nil
	compiler.stop = false
	sync.mutex_unlock(&compiler.mu)
}

@(private)
compile_job_free :: proc(j: ^Compile_Job) {
	delete(j.source)
	delete(j.url)
	free(j)
}

// A compile thread: one engine instance, kept for the thread's life. Its "page" only carries the cache key of the
// compilation (Engine_storeBytecode); compiling calls no other import.
@(private)
compile_main :: proc(_: rawptr) {
	ctx_page := new(Page)
	ctx_page.js = new(Js_Realm)
	sync.mutex_lock(&compiler.mu)
	opt := compiler.opt
	sync.mutex_unlock(&compiler.mu)
	opt.soft_call_ms = 0
	opt.stop = nil
	inst, err := wasm.instance_create(js_engine_image(), ctx_page, nil, opt, "javascript compiler", nil)
	delete(err)
	if inst != nil { inst.lenient = true }
	ctx_page.js.inst = inst   // Engine_storeBytecode answers the realm's engine only
	for {
		sync.sema_wait(&compiler.sema)
		sync.mutex_lock(&compiler.mu)
		if compiler.stop { sync.mutex_unlock(&compiler.mu); break }
		if len(compiler.queue) == 0 { sync.mutex_unlock(&compiler.mu); continue }
		job := compiler.queue[0]
		ordered_remove(&compiler.queue, 0)
		sync.mutex_unlock(&compiler.mu)
		if inst != nil && !inst.dead {
			t0 := time.tick_now()
			ctx_page.js.pending_key = job.key
			ctx_page.js.has_pending_key = true
			job.ok = js.compile(inst, job.source, job.url) == .Ok
			ctx_page.js.has_pending_key = false
			job.ms = time.duration_milliseconds(time.tick_since(t0))
		}
		sync.mutex_lock(&compiler.mu)
		compiler.jobs += 1
		compiler.total_ms += job.ms
		// once stopping, the interface loop may be gone: the result stays in the cache only
		if compiler.stop { compile_job_free(job) } else { host.post(job.ui_loop, compile_done, job) }
		sync.mutex_unlock(&compiler.mu)
		free_all(context.temp_allocator)
	}
	if inst != nil { wasm.destroy(inst) }
	free(ctx_page.js)
	free(ctx_page)
}

// UI thread: the script may run now (its bytecode is cached, or it will be compiled there).
@(private)
compile_done :: proc(data: rawptr) {
	job := (^Compile_Job)(data)
	defer compile_job_free(job)
	p := page_by_id(job.page_id)
	if p == nil || p.closed || p.scripts == nil { return }
	for f in p.scripts.fetches {
		if f == job.download { f.compiling = false; scripts_pump(p); return }
	}
}

