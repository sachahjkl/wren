package host

// Native threads with an explicit stack size (core:thread always takes the default one). Used for threads that run guest
// code: the interpreter checks native stack overflow against the real bounds of the thread, so the size is a setting.
//
// The thread starts with the caller's context (its allocator must be thread-safe: the process heap or a locking tracker)
// and a temporary allocator of its own, destroyed when the procedure returns.

import "base:runtime"
import "core:sync"
import win "core:sys/windows"

Thread :: struct {
	handle: win.HANDLE,
	id:     u32,
	fn:     Task_Proc,
	data:   rawptr,
	ctx:    runtime.Context,
	done:   b32,   // atomic: the procedure has returned
}

@(private)
STACK_SIZE_PARAM_IS_A_RESERVATION :: 0x00010000

// Scheduling priority relative to the process. Background work below the UI thread keeps the window responsive when
// every core is busy.
Thread_Priority :: enum i32 { Lowest = -2, Below_Normal = -1, Normal = 0 }

// Starts `fn(data)` on a new thread with `stack_bytes` of reserved stack (0 = the executable's default). Nil on failure.
thread_start :: proc(fn: Task_Proc, data: rawptr, stack_bytes := 0, priority := Thread_Priority.Normal) -> ^Thread {
	t := new(Thread)
	t.fn, t.data = fn, data
	t.ctx = context
	t.handle = win.CreateThread(nil, uint(max(stack_bytes, 0)), thread_entry, t, STACK_SIZE_PARAM_IS_A_RESERVATION | win.CREATE_SUSPENDED, &t.id)
	if t.handle == nil { free(t); return nil }
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

// True once the thread's procedure has returned (joining it will not block for long).
thread_finished :: proc(t: ^Thread) -> bool { return t == nil || bool(sync.atomic_load(&t.done)) }

// Waits for the thread to end and frees it.
thread_join :: proc(t: ^Thread) {
	if t == nil { return }
	win.WaitForSingleObject(t.handle, win.INFINITE)
	win.CloseHandle(t.handle)
	free(t)
}
