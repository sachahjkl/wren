package host

// Native threads with an explicit stack size (core:thread always takes the default one). Used for threads that run guest
// code: Wasmtime runs it on the thread's own stack (wasm.wasmtime.max_stack_bytes must fit in it), so the size is a setting.
//
// The thread starts with the caller's context (its allocator must be thread-safe: the process heap or a locking tracker)
// and a temporary allocator of its own, destroyed when the procedure returns. The system's side is in thread_<os>.odin.

import "base:runtime"
import "core:strings"
import "core:sync"
import "wb:base"

Thread :: struct {
	native: Native_Thread,
	fn:     Task_Proc,
	data:   rawptr,
	ctx:    runtime.Context,
	done:   b32,   // atomic: the procedure has returned
	priority: Thread_Priority,
	name:   [48]u8,
	name_len: int,
}

// Every thread started and not joined yet (shutdown.odin lists the ones still running when the teardown waits).
@(private)
live_mu: sync.Mutex
@(private)
live: [dynamic]^Thread

thread_name :: proc(t: ^Thread) -> string { return string(t.name[:t.name_len]) }

// The names of the threads whose procedure has not returned.
threads_running :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	sync.mutex_lock(&live_mu)
	for t in live {
		n := thread_name(t)
		if !sync.atomic_load(&t.done) && !strings.has_prefix(n, "wren-shutdown") { append(&out, strings.clone(n == "" ? "(unnamed)" : n, allocator)) }
	}
	sync.mutex_unlock(&live_mu)
	return out[:]
}

// Scheduling priority relative to the process. Background work below the UI thread keeps the window responsive when
// every core is busy.
Thread_Priority :: enum i32 { Lowest = -2, Below_Normal = -1, Normal = 0 }

// Starts `fn(data)` on a new thread with `stack_bytes` of reserved stack (0 = the executable's default). Nil on failure.
thread_start :: proc(fn: Task_Proc, data: rawptr, stack_bytes := 0, priority := Thread_Priority.Normal, name := "") -> ^Thread {
	t := new(Thread)
	t.fn, t.data = fn, data
	t.ctx = context
	t.priority = priority
	t.name_len = min(len(name), len(t.name))
	copy(t.name[:t.name_len], name[:t.name_len])
	// listed before it runs: the system may run it to its end before the creating call returns
	sync.mutex_lock(&live_mu)
	if live == nil { live = make([dynamic]^Thread, base.process_allocator()) }
	append(&live, t)
	sync.mutex_unlock(&live_mu)
	if !native_thread_start(t, max(stack_bytes, 0)) {
		forget_thread(t)
		free(t)
		return nil
	}
	return t
}

// The body every native entry point runs, on the new thread, once `context` is the creator's.
@(private)
thread_run :: proc(t: ^Thread) {
	when !ODIN_DEFAULT_TO_NIL_ALLOCATOR {
		// the creator's temporary allocator is thread-local state of the creator: never share it
		context.temp_allocator = runtime.Allocator{runtime.default_temp_allocator_proc, &runtime.global_default_temp_allocator_data}
	}
	t.fn(t.data)
	when !ODIN_DEFAULT_TO_NIL_ALLOCATOR {
		runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	}
	runtime.run_thread_local_cleaners()
	sync.atomic_store(&t.done, true)
}

@(private)
forget_thread :: proc(t: ^Thread) {
	sync.mutex_lock(&live_mu)
	for l, i in live { if l == t { unordered_remove(&live, i); break } }
	if len(live) == 0 { delete(live); live = nil }   // (nothing kept while no thread lives: the leak check of the tools)
	sync.mutex_unlock(&live_mu)
}

// Logical processors available to the process.
processor_count :: proc() -> int { return max(native_processor_count(), 1) }

// True once the thread's procedure has returned (joining it will not block for long).
thread_finished :: proc(t: ^Thread) -> bool { return t == nil || bool(sync.atomic_load(&t.done)) }

// Waits for the thread to end and frees it.
thread_join :: proc(t: ^Thread) {
	if t == nil { return }
	shutdown_joining(thread_name(t) == "" ? "(unnamed)" : thread_name(t))
	// What the caller waits for runs at least as urgently as the caller: a background thread (below normal) starves while every
	// core is busy (Windows lifts a starved thread for two time slices every few seconds), so joining the disk cache's writer
	// took ten seconds on a loaded machine. The caller sleeps meanwhile: the boost takes nothing from it.
	if !thread_finished(t) && t.priority != .Normal { native_thread_boost(t) }
	native_thread_wait(t)
	shutdown_joining("")
	forget_thread(t)
	native_thread_close(t)
	free(t)
}
