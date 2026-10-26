package crashmodes

// Makes the process die in one of the ways a Wren has died, to see which leave a crash report (crashtrace): the report goes to the folder
// given as the second argument. Run by tools\crash_e2e.ps1.
//   crashmodes <mode> <dir>     modes: access, assert, bounds, overflow, overflow_thread, heap (a double free), failfast, exit

import "core:os"
import "core:sys/windows"
import "core:thread"
import "wb:tools/crashtrace"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	RaiseFailFastException :: proc(rec: rawptr, ctx: rawptr, flags: u32) ---
}

recurse :: proc(n: int) -> int {
	buf: [256]u8
	for i in 0 ..< len(buf) { buf[i] = u8(n + i) }
	return recurse(n + 1) + int(buf[n % 256])
}

// An index out of range in a procedure of a known name, kept out of line: what the crash of 26/10 was (an Odin bounds check,
// 0xC000008C). tools\crash_e2e.ps1 builds this tool as a release is built (no PDB, a map) and names the frame from the map.
index_out_of_range :: #force_no_inline proc(s: []int, i: int) -> int {
	return s[i]
}

die :: proc(mode: string) {
	switch mode {
	case "bounds":
		s := []int{1, 2, 3}
		_ = index_out_of_range(s, len(os.args) + 5)
	case "access":
		p: ^int
		p^ = 1
	case "assert":
		panic("a Wren assertion")
	case "overflow":
		_ = recurse(0)
	case "overflow_thread":
		t := thread.create_and_start(proc() { _ = recurse(0) })
		thread.join(t)
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

main :: proc() {
	if len(os.args) < 3 { os.exit(2) }
	crashtrace.set_report_dir(os.args[2], "crashmodes 1.0")
	crashtrace.begin_session()
	die(os.args[1])
}
