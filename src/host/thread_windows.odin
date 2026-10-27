package host

import win "core:sys/windows"

Native_Thread :: struct {
	handle: win.HANDLE,
	id:     u32,
}

@(private)
STACK_SIZE_PARAM_IS_A_RESERVATION :: 0x00010000
@(private)
THREAD_PRIORITY_ABOVE_NORMAL :: 1

@(private)
native_thread_start :: proc(t: ^Thread, stack_bytes: int) -> bool {
	t.native.handle = win.CreateThread(nil, uint(stack_bytes), thread_entry, t, STACK_SIZE_PARAM_IS_A_RESERVATION | win.CREATE_SUSPENDED, &t.native.id)
	if t.native.handle == nil { return false }
	if t.name_len > 0 { win.SetThreadDescription(t.native.handle, win.utf8_to_wstring(thread_name(t), context.temp_allocator)) }   // what debuggers and Process Explorer show
	if t.priority != .Normal { win.SetThreadPriority(t.native.handle, i32(t.priority)) }
	win.ResumeThread(t.native.handle)
	return true
}

@(private)
thread_entry :: proc "system" (arg: rawptr) -> win.DWORD {
	t := (^Thread)(arg)
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
