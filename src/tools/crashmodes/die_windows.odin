package crashmodes

import "core:sys/windows"
import "wb:tools/crashtrace"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	RaiseFailFastException :: proc(rec: rawptr, ctx: rawptr, flags: u32) ---
}

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
		crashtrace.end_session()
	case "exit":
		windows.ExitProcess(9)
	}
}
