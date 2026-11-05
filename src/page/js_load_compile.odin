package page

// Compiling large scripts off the interface thread (javascript.compile.offthread_min_bytes): when an external classic
// script arrives and its bytecode is not cached, a compile thread (each with an engine instance of its own, made from
// the same pre-initialized image) compiles it and stores the bytecode in the shared cache (package js) while the page
// goes on with its other work (other downloads, the parser's reveal, painting). The script runs when its turn comes
// and its bytecode is there: js_run finds it in the cache and does not parse it again.
//
// A large inline script is known as soon as the document is parsed, long before its turn comes (cnn.com: two of 3 MB, 0.8 s of the
// window thread): it goes to a compile thread then (compile_inline_ahead), and at its turn js_run finds the bytecode, or waits for it.
//
// The threads are shared by every page, made on first use (javascript.compile.offthread_threads), and stopped by
// compile_shutdown (js_shutdown). A job outlives its page if the page closes: the result is only cached.

import "core:slice"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:js"
import "wb:wasm"

@(private)
Compile_Job :: struct {
	page_id: u64,
	download: ^Script_Fetch,  // UI thread only, valid while the page lives
	module:  string,          // owned: the key of the module entry this compiles (a module; download is nil then)
	source:  []byte,          // owned
	url:     string,          // owned
	key:     js.Key,
	ui_loop: ^host.Loop,
	ms:      f64,             // compile time (diagnostics)
	ok:      bool,
	inline:  bool,            // an inline script compiled ahead of its turn (Page_Scripts.ahead)
	finished: u32,            // (a futex) the compile thread is done with it: compile_ahead_wait
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
	failed:   int,          // ... of which the engine did not compile (a syntax error, or the engine stopped)
	total_ms: f64,
}


// What the compile threads did (tests, measurements).
Compile_Stats :: struct { threads, jobs, failed: int, total_ms: f64 }

compile_stats :: proc() -> Compile_Stats {
	sync.mutex_lock(&the_pages.compiler.mu)
	defer sync.mutex_unlock(&the_pages.compiler.mu)
	return Compile_Stats{threads = len(the_pages.compiler.threads), jobs = the_pages.compiler.jobs, failed = the_pages.compiler.failed, total_ms = the_pages.compiler.total_ms}
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
	sync.mutex_lock(&the_pages.compiler.mu)
	append(&the_pages.compiler.queue, job)
	sync.mutex_unlock(&the_pages.compiler.mu)
	sync.sema_post(&the_pages.compiler.sema)
}

// The document is parsed: an inline classic script, large and not cached yet, goes to a compile thread now.
@(private)
compile_inline_ahead :: proc(p: ^Page, el: base.Handle) {
	d := p.doc
	n := compile_thread_count(p)
	if _, has_src := dom.get_attribute(d, el, "src"); has_src || n == 0 || p.worker != nil { return }
	if kind, ok := script_kind_of(d, el); !ok || kind != .Classic { return }
	size := 0
	for c := dom.get(d, el).first_child; c != base.NIL_HANDLE; c = dom.get(d, c).next { if t := dom.get(d, c); t.kind == .Text { size += len(t.text) } }
	if size < p.settings.js.offthread_min_bytes || !js.cacheable(size) { return }
	source := script_text(d, el)
	u := p.env.location.href
	key := js.key_of(js_version(), 0, u, transmute([]byte)source)
	if code := js.lookup(key, context.temp_allocator); code != nil { return }
	if !compile_service_start(p, n) { return }
	job := new(Compile_Job)
	job.page_id = page_id(p)
	job.inline = true
	job.source = make([]byte, len(source))
	copy(job.source, source)
	job.url = clone_heap(u)
	job.key = key
	job.ui_loop = p.loop
	append(&p.scripts.ahead, job)
	sync.mutex_lock(&the_pages.compiler.mu)
	append(&the_pages.compiler.queue, job)
	sync.mutex_unlock(&the_pages.compiler.mu)
	sync.sema_post(&the_pages.compiler.sema)
}

// The script of `key` is about to run and its bytecode is not there. One compiled ahead: taken back if no thread took it (it is compiled
// here then), else awaited: what remains of its compilation, where compiling it here would take all of it.
@(private)
compile_ahead_wait :: proc(p: ^Page, key: js.Key) {
	if p.scripts == nil { return }
	for job, i in p.scripts.ahead {
		if job.key != key { continue }
		sync.mutex_lock(&the_pages.compiler.mu)
		queued := slice.linear_search(the_pages.compiler.queue[:], job) or_else -1
		if queued >= 0 { ordered_remove(&the_pages.compiler.queue, queued) }
		sync.mutex_unlock(&the_pages.compiler.mu)
		if queued >= 0 {
			ordered_remove(&p.scripts.ahead, i)
			compile_job_free(job)
			return
		}
		for sync.atomic_load(&job.finished) == 0 { sync.futex_wait((^sync.Futex)(&job.finished), 0) }
		return
	}
}

// A module arrived: compile it on another thread when it is large and not cached yet. True when a job took it: the
// entry waits (compiling) until compile_done, which then prepares it from the cache or compiles it there.
@(private)
compile_module_offthread :: proc(p: ^Page, e: ^Module_Entry) -> bool {
	n := compile_thread_count(p)
	if n == 0 || p.worker != nil || e.type != .JavaScript || len(e.source) < p.settings.js.offthread_min_bytes || !js.cacheable(len(e.source)) { return false }
	if !js_enabled(p) { return false }
	key := js.key_of(js_version(), transmute(i32)js.Eval_Flags{.Module}, e.key, e.source[:])
	if code := js.lookup(key, context.temp_allocator); code != nil { return false }
	if !compile_service_start(p, n) { return false }
	job := new(Compile_Job)
	job.page_id = page_id(p)
	job.module = clone_heap(e.key)
	job.source = make([]byte, len(e.source))
	copy(job.source, e.source[:])
	job.url = clone_heap(e.key)
	job.key = key
	job.ui_loop = p.loop
	e.compiling = true
	sync.mutex_lock(&the_pages.compiler.mu)
	append(&the_pages.compiler.queue, job)
	sync.mutex_unlock(&the_pages.compiler.mu)
	sync.sema_post(&the_pages.compiler.sema)
	return true
}

@(private)
compile_service_start :: proc(p: ^Page, n: int) -> bool {
	sync.mutex_lock(&the_pages.compiler.mu)
	defer sync.mutex_unlock(&the_pages.compiler.mu)
	if the_pages.compiler.stop { return false }
	if len(the_pages.compiler.threads) >= n { return true }
	the_pages.compiler.opt = p.settings.wasm
	the_pages.compiler.stack = p.settings.workers.thread_stack_bytes
	for len(the_pages.compiler.threads) < n {
		t := host.thread_start(compile_main, the_pages, the_pages.compiler.stack, .Below_Normal, "wren-js-compile")
		if t == nil { break }
		append(&the_pages.compiler.threads, t)
	}
	return len(the_pages.compiler.threads) > 0
}

// Stops the compile threads (process end, after every page closed). Jobs not started are dropped.
compile_shutdown :: proc() {
	sync.mutex_lock(&the_pages.compiler.mu)
	the_pages.compiler.stop = true
	threads := the_pages.compiler.threads
	the_pages.compiler.threads = nil
	sync.mutex_unlock(&the_pages.compiler.mu)
	for _ in threads { sync.sema_post(&the_pages.compiler.sema) }
	for t in threads { host.thread_join(t) }
	delete(threads)
	sync.mutex_lock(&the_pages.compiler.mu)
	for j in the_pages.compiler.queue { compile_job_free(j) }
	delete(the_pages.compiler.queue)
	the_pages.compiler.queue = nil
	the_pages.compiler.stop = false
	sync.mutex_unlock(&the_pages.compiler.mu)
}

@(private)
compile_job_free :: proc(j: ^Compile_Job) {
	delete(j.source)
	delete(j.url)
	delete(j.module)
	free(j)
}

// A compile thread: one engine instance, kept for the thread's life. Its "page" only carries the cache key of the
// compilation (Engine_storeBytecode); compiling calls no other import.
@(private)
compile_main :: proc(data: rawptr) {
	bind((^Pages)(data))   // (the service of the App that started this thread)
	ctx_page := new(Page)
	ctx_page.js = new(Js_Realm)
	sync.mutex_lock(&the_pages.compiler.mu)
	opt := the_pages.compiler.opt
	sync.mutex_unlock(&the_pages.compiler.mu)
	opt.soft_call_ms = 0
	opt.stop = nil
	// No deadline: compiling runs none of the page's code, it ends with the source, and nothing waits on this thread. With
	// wasm.max_call_ms (1 s by default) a large bundle trapped here, the thread's engine was dead for good, and the interface
	// thread compiled the bundle and every later one itself, inside the task the slow script limit measures.
	opt.max_call_ms = -1
	js_read_ahead_wait()
	inst, err := wasm.instance_create(js_engine_image(), ctx_page, nil, opt, "javascript compiler", nil, js_image_digest())
	delete(err)
	if inst != nil { inst.lenient = true }
	ctx_page.js.inst = inst   // Engine_storeBytecode answers the realm's engine only
	for {
		sync.sema_wait(&the_pages.compiler.sema)
		sync.mutex_lock(&the_pages.compiler.mu)
		if the_pages.compiler.stop { sync.mutex_unlock(&the_pages.compiler.mu); break }
		if len(the_pages.compiler.queue) == 0 { sync.mutex_unlock(&the_pages.compiler.mu); continue }
		job := the_pages.compiler.queue[0]
		ordered_remove(&the_pages.compiler.queue, 0)
		sync.mutex_unlock(&the_pages.compiler.mu)
		if inst != nil && !inst.dead {
			t0 := time.tick_now()
			at := base.span_now()
			ctx_page.js.pending_key = job.key
			ctx_page.js.has_pending_key = true
			job.ok = js.compile(inst, job.source, job.url, flags = job.module != "" ? {.Module} : {}) == .Ok
			ctx_page.js.has_pending_key = false
			job.ms = time.duration_milliseconds(time.tick_since(t0))
			base.span_add(.Off_Thread, at, job.url, copy_label = true)
		}
		sync.atomic_store(&job.finished, 1)
		sync.futex_broadcast((^sync.Futex)(&job.finished))
		sync.mutex_lock(&the_pages.compiler.mu)
		the_pages.compiler.jobs += 1
		if !job.ok { the_pages.compiler.failed += 1 }
		the_pages.compiler.total_ms += job.ms
		// once stopping, the interface loop may be gone: the result stays in the cache only
		if the_pages.compiler.stop { compile_job_free(job) } else { host.post(job.ui_loop, compile_done, job) }
		sync.mutex_unlock(&the_pages.compiler.mu)
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
	if job.inline {
		if i, found := slice.linear_search(p.scripts.ahead[:], job); found { ordered_remove(&p.scripts.ahead, i) }
		return
	}
	if job.module != "" {
		if p.scripts.modules == nil { return }
		if e := p.scripts.modules.entries[job.module]; e != nil && e.compiling {
			e.compiling = false
			module_prepare(p, e)
			modules_check(p)
		}
		return
	}
	for f in p.scripts.fetches {
		if f == job.download { f.compiling = false; f.span_compiled = base.span_now(); scripts_pump(p); return }
	}
}

