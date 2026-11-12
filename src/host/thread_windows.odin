package host

import win "core:sys/windows"

Native_Thread :: struct {
	handle: win.HANDLE,
	id:     u32,
}

foreign import kernel32_thread "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_thread {
	SetThreadStackGuarantee :: proc(size: ^u32) -> win.BOOL ---
}

// Stack kept for the handlers of a stack overflow on each thread this package starts (SetThreadStackGuarantee: the
// guarantee is the calling thread's, and only the main thread asked for one, crashtrace's install). Without it the system
// dispatches the overflow on the one page left: the exception's record and context (larger where the processor has
// AVX-512 state to save), the dispatcher's own frame and the handler that hands the report to crashtrace's writer did not
// always fit, and the process ended with no report and no event (overflow_thread of src/tools/crashmodes, on a CI
// runner). Rust's runtime asks the same of each thread it starts, for the same reason.
@(private = "file")
OVERFLOW_HANDLER_STACK_BYTES :: 64 * 1024

@(private)
STACK_SIZE_PARAM_IS_A_RESERVATION :: 0x00010000
@(private)
THREAD_PRIORITY_ABOVE_NORMAL :: 1
@(private)
THREAD_PRIORITY_LOWEST :: -2

@(private)
native_thread_start :: proc(t: ^Thread, stack_bytes: int) -> bool {
	t.native.handle = win.CreateThread(nil, uint(stack_bytes), thread_entry, t, STACK_SIZE_PARAM_IS_A_RESERVATION | win.CREATE_SUSPENDED, &t.native.id)
	if t.native.handle == nil { return false }
	if t.name_len > 0 { win.SetThreadDescription(t.native.handle, win.utf8_to_wstring(thread_name(t), context.temp_allocator)) }   // what debuggers and Process Explorer show
	if t.priority == .Lowest { win.SetThreadPriority(t.native.handle, THREAD_PRIORITY_LOWEST) }   // (Below_Normal: see Thread_Priority)
	win.ResumeThread(t.native.handle)
	return true
}

// The calling thread's name, as debuggers and profilers show it (a thread this package started has its own already).
thread_name_self :: proc(name: string) { win.SetThreadDescription(win.GetCurrentThread(), win.utf8_to_wstring(name, context.temp_allocator)) }

// The calling thread is the interface's: above every background thread of the process.
thread_raise_interface :: proc() { win.SetThreadPriority(win.GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) }

@(private)
thread_entry :: proc "system" (arg: rawptr) -> win.DWORD {
	t := (^Thread)(arg)
	guarantee: u32 = OVERFLOW_HANDLER_STACK_BYTES
	SetThreadStackGuarantee(&guarantee)   // (a stack smaller than this refuses it: the thread runs anyway)
	context = t.ctx
	thread_run(t)
	return 0
}

@(private)
native_thread_boost :: proc(t: ^Thread) {
	if win.GetThreadPriority(t.native.handle) < 0 { win.SetThreadPriority(t.native.handle, i32(THREAD_PRIORITY_ABOVE_NORMAL)) }
}

@(private)
native_thread_wait :: proc(t: ^Thread) { win.WaitForSingleObject(t.native.handle, win.INFINITE) }

@(private)
native_thread_close :: proc(t: ^Thread) { win.CloseHandle(t.native.handle) }

@(private)
native_processor_count :: proc() -> int {
	info: win.SYSTEM_INFO
	win.GetSystemInfo(&info)
	return int(info.dwNumberOfProcessors)
}
