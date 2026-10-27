package crashmodes

// Makes the process die in one of the ways a Wren has died, to see which leave a crash report (crashtrace): the report goes to the folder
// given as the second argument. Run by tools\crash_e2e.ps1 (Windows) and tools/crash_e2e.sh (Linux).
//   crashmodes <mode> <dir>     modes: access, assert, bounds, overflow, overflow_thread, heap (a double free), failfast, clean, exit

import "base:intrinsics"
import "core:os"
import "core:thread"
import "wb:tools/crashtrace"

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
		// (volatile: a plain store through nil is undefined behaviour, which an optimized build may drop)
		intrinsics.volatile_store((^int)(nil), 1)
	case "assert":
		panic("a Wren assertion")
	case "overflow":
		_ = recurse(0)
	case "overflow_thread":
		t := thread.create_and_start(proc() { _ = recurse(0) })
		thread.join(t)
	case:
		die_system(mode)   // heap, failfast, clean, exit: the system's ways (die_<os>.odin)
	}
}

main :: proc() {
	if len(os.args) < 3 { os.exit(2) }
	crashtrace.set_report_dir(os.args[2], "crashmodes 1.0")
	crashtrace.begin_session()
	die(os.args[1])
}
