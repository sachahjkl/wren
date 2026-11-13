package crashmodes

import "base:intrinsics"
import "core:sync"
import "core:sys/windows"
import "core:thread"
import crash "../../../ext/gui_toolkit/src/crash"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	RaiseFailFastException :: proc(rec: rawptr, ctx: rawptr, flags: u32) ---
	SetErrorMode :: proc(mode: u32) -> u32 ---
	QueueUserWorkItem :: proc(function: proc "system" (context_data: rawptr) -> u32, context_data: rawptr, flags: u32) -> windows.BOOL ---
	CreateTimerQueueTimer :: proc(timer: ^windows.HANDLE, queue: windows.HANDLE, callback: proc "system" (parameter: rawptr, fired: b8), parameter: rawptr, due, period, flags: u32) -> windows.BOOL ---
}

@(private = "file") SEM_NOGPFAULTERRORBOX :: 0x0002

// No Windows Error Reporting for what dies here: what is looked at is our report, written by then, and the system holds the process frozen for as long as WerFault.exe takes. On a machine with
// every core busy that was 25 to 50 s, five at a time, against the minute of a test that waits for their end.
@(init)
no_system_report :: proc "contextless" () { SetErrorMode(SEM_NOGPFAULTERRORBOX) }

die_system :: proc(mode: string) {
	switch mode {
	case "heap":
		// the heap's own check: a block freed twice (what a data race on a freed allocation looks like)
		heap := windows.GetProcessHeap()
		p := windows.HeapAlloc(heap, 0, 64)
		windows.HeapFree(heap, 0, p)
		windows.HeapFree(heap, 0, p)
		q := windows.HeapAlloc(heap, 0, 64)
		(^[64]u8)(q)^ = {}
		for i in 0 ..< 100000 { x := windows.HeapAlloc(heap, 0, 48); (^[48]u8)(x)^ = {}; if i % 3 == 0 { windows.HeapFree(heap, 0, x) } }
	case "failfast":
		RaiseFailFastException(nil, nil, 0)
	case "clean":
		// the next start finds (or not) the previous session: give its report thread the time to write
		windows.Sleep(3000)
		crash.end_session()
	case "exit":
		windows.ExitProcess(9)
	case "terminate":
		windows.TerminateProcess(windows.GetCurrentProcess(), 9)
	case "two_threads":
		// the threads of a pass reading the same freed block, a moment apart: the report of the first is written while the others fault
		for _ in 0 ..< FAULTING_THREADS { thread.create_and_start(proc() { for !sync.atomic_load(&go_on) { intrinsics.cpu_relax() }; fault() }) }
		sync.atomic_store(&go_on, true)
		windows.Sleep(WAIT_FOR_THE_END_MS)
	case "pool":
		QueueUserWorkItem(proc "system" (_: rawptr) -> u32 { fault(); return 0 }, nil, 0)
		windows.Sleep(WAIT_FOR_THE_END_MS)
	case "timer":
		timer: windows.HANDLE
		CreateTimerQueueTimer(&timer, nil, proc "system" (_: rawptr, _: b8) { fault() }, nil, 0, 0, 0)
		windows.Sleep(WAIT_FOR_THE_END_MS)
	case "window_procedure":
		// a window of no desktop (HWND_MESSAGE): the fault has the kernel's call into the window on its stack
		window := windows.CreateWindowExW(0, windows.L("STATIC"), nil, 0, 0, 0, 0, 0, HWND_MESSAGE, nil, nil, nil)
		windows.SetWindowLongPtrW(window, windows.GWLP_WNDPROC, transmute(windows.LONG_PTR)(proc "system" (_: windows.HWND, _: u32, _: windows.WPARAM, _: windows.LPARAM) -> windows.LRESULT { fault(); return 0 }))
		windows.SendMessageW(window, windows.WM_USER, 0, 0)
	case "wild_stack":
		// a jump to nowhere on a stack written over, frame pointer gone: what a return through a damaged stack looks like. The system needs a stack it can write on to run a handler at all
		// (with none the thread just ends), so this one is memory, full of nonsense; the walk of the report must not fall on it.
		t := thread.create_and_start(proc() { for !sync.atomic_load(&go_on) { intrinsics.cpu_relax() } })   // (out of the kernel: a wait would finish before the context counts; a moment, the fault ends it)
		h := t.win32_thread
		windows.Sleep(THREAD_ASLEEP_MS)
		windows.SuspendThread(h)
		c: windows.CONTEXT
		c.ContextFlags = CONTEXT_FULL
		windows.GetThreadContext(h, &c)
		damaged := ([^]u64)(windows.VirtualAlloc(nil, DAMAGED_STACK_BYTES, windows.MEM_COMMIT | windows.MEM_RESERVE, windows.PAGE_READWRITE))
		for i in 0 ..< DAMAGED_STACK_BYTES / size_of(u64) { damaged[i] = NOWHERE }
		c.Rip, c.Rsp, c.Rbp = NOWHERE, u64(uintptr(damaged)) + DAMAGED_STACK_BYTES / 2, NOWHERE
		windows.SetThreadContext(h, &c)
		windows.ResumeThread(h)
		windows.Sleep(WAIT_FOR_THE_END_MS)
	}
}

@(private = "file") FAULTING_THREADS :: 4
@(private = "file") WAIT_FOR_THE_END_MS :: 60_000
@(private = "file") THREAD_ASLEEP_MS :: 100
@(private = "file") NOWHERE :: 0x2000010
@(private = "file") DAMAGED_STACK_BYTES :: 1 << 20
@(private = "file") CONTEXT_FULL :: 0x0010000B
@(private = "file") HWND_MESSAGE :: windows.HWND(~uintptr(2))   // (HWND)-3
@(private = "file") go_on: bool

@(private = "file")
fault :: proc "contextless" () { intrinsics.volatile_store((^int)(nil), 1) }
