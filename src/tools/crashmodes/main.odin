package crashmodes

// Makes the process die in one of the ways a Wren has died, to see which leave a crash report (crashtrace): the report goes to the folder
// given as the second argument. Run by src\tools\e2e\crash_reports.odin and the @(test) of src/tools/wrentool/deps/symbols_test.odin (Windows), wrentool crash-e2e (Linux).
//   crashmodes <mode> <dir>     modes: access, assert, bounds, overflow, overflow_thread, heap (a double free), failfast, clean, exit, freed_read, arena_read, double_free, freed_write, freed_number

import "base:intrinsics"
import "core:os"
import "core:thread"
import "wb:base"
import "wb:tools/crashtrace"

Record :: struct { value: ^int }

recurse :: proc(n: int) -> int {
	buf: [256]u8
	for i in 0 ..< len(buf) { buf[i] = u8(n + i) }
	return recurse(n + 1) + int(buf[n % 256])
}

// An index out of range in a procedure of a known name, kept out of line: what the crash of 26/10 was (an Odin bounds check,
// 0xC000008C). symbols_test.odin (wrentool) builds this tool as a release is built (no PDB, a map) and names the frame from the map.
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
	// (a build with -define:WREN_POISON_MEMORY=true: test_all's crashmodes_poison)
	case "freed_read":
		// a record holding a pointer, freed: what a stale ^Computed of a paint reads
		kept := new(Record)
		kept.value = new(int)
		value := kept.value
		free(kept)
		free(value)
		_ = intrinsics.volatile_load(kept.value)
	case "arena_read":
		// the same in an arena emptied by a new pass
		arena: base.Arena
		_ = base.arena_init_growing(&arena)
		kept := new(Record, base.arena_allocator(&arena))
		kept.value = new(int, base.arena_allocator(&arena))
		base.arena_free_all(&arena)
		_ = intrinsics.volatile_load(kept.value)
	case "freed_number":
		// a plain number of a freed block: a fault with WREN_POISON_PAGES only
		p := new(int)
		free(p)
		_ = intrinsics.volatile_load(p)
	case "double_free":
		p := new(int)
		free(p)
		free(p)
	case "freed_write":
		p := new(int)
		free(p)
		intrinsics.volatile_store(p, 1)
		base.mem_report("crashmodes")
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
