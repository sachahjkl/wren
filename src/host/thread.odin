package host

// Native threads with an explicit stack size (core:thread always takes the default one). Used for threads that run guest
// code: Wasmtime runs it on the thread's own stack (wasm.wasmtime.max_stack_bytes must fit in it), so the size is a setting.
//
// The thread starts with the caller's context (its allocator must be thread-safe: the process heap or a locking tracker)
// and a temporary allocator of its own, destroyed when the procedure returns.

import "base:runtime"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "wb:base"

Thread :: struct {
	handle: win.HANDLE,
	id:     u32,
	fn:     Task_Proc,
	data:   rawptr,
	ctx:    runtime.Context,
	done:   b32,   // atomic: the procedure has returned
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

@(private)
STACK_SIZE_PARAM_IS_A_RESERVATION :: 0x00010000
@(private)
THREAD_PRIORITY_ABOVE_NORMAL :: 1

// Scheduling priority relative to the process. Background work below the UI thread keeps the window responsive when
// every core is busy.
Thread_Priority :: enum i32 { Lowest = -2, Below_Normal = -1, Normal = 0 }

// Starts `fn(data)` on a new thread with `stack_bytes` of reserved stack (0 = the executable's default). Nil on failure.
thread_start :: proc(fn: Task_Proc, data: rawptr, stack_bytes := 0, priority := Thread_Priority.Normal, name := "") -> ^Thread {
	t := new(Thread)
	t.fn, t.data = fn, data
	t.ctx = context
	t.handle = win.CreateThread(nil, uint(max(stack_bytes, 0)), thread_entry, t, STACK_SIZE_PARAM_IS_A_RESERVATION | win.CREATE_SUSPENDED, &t.id)
	if t.handle == nil { free(t); return nil }
	t.name_len = min(len(name), len(t.name))
	copy(t.name[:t.name_len], name[:t.name_len])
	if name != "" { win.SetThreadDescription(t.handle, win.utf8_to_wstring(name, context.temp_allocator)) }   // what debuggers and Process Explorer show
	sync.mutex_lock(&live_mu)
	if live == nil { live = make([dynamic]^Thread, base.process_allocator()) }
	append(&live, t)
	sync.mutex_unlock(&live_mu)
	if priority != .Normal { win.SetThreadPriority(t.handle, i32(priority)) }
	win.ResumeThread(t.handle)
	return t
}

@(private)
thread_entry :: proc "system" (arg: rawptr) -> win.DWORD {
	t := (^Thread)(arg)
	context = t.ctx
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
	return 0
}

// Logical processors available to the process.
processor_count :: proc() -> int {
	info: win.SYSTEM_INFO
	win.GetSystemInfo(&info)
	return max(int(info.dwNumberOfProcessors), 1)
}

// True once the thread's procedure has returned (joining it will not block for long).
thread_finished :: proc(t: ^Thread) -> bool { return t == nil || bool(sync.atomic_load(&t.done)) }

// Waits for the thread to end and frees it.
thread_join :: proc(t: ^Thread) {
	if t == nil { return }
	shutdown_joining(thread_name(t) == "" ? "(unnamed)" : thread_name(t))
	// What the caller waits for runs at least as urgently as the caller: a background thread (below normal) starves while every
	// core is busy (Windows lifts a starved thread for two time slices every few seconds), so joining the disk cache's writer
	// took ten seconds on a loaded machine. The caller sleeps meanwhile: the boost takes nothing from it.
	if !thread_finished(t) && win.GetThreadPriority(t.handle) < 0 { win.SetThreadPriority(t.handle, i32(THREAD_PRIORITY_ABOVE_NORMAL)) }
	win.WaitForSingleObject(t.handle, win.INFINITE)
	shutdown_joining("")
	sync.mutex_lock(&live_mu)
	for l, i in live { if l == t { unordered_remove(&live, i); break } }
	if len(live) == 0 { delete(live); live = nil }   // (nothing kept while no thread lives: the leak check of the tools)
	sync.mutex_unlock(&live_mu)
	win.CloseHandle(t.handle)
	free(t)
}
