package base

// What the system says of the process's memory, for the measuring tools and tests. The reader now lives in the toolkit's
// testkit package (toolkit:testkit, process_<os>.odin), which also reports open handles and (on Windows) GDI / USER
// objects; base keeps this narrow struct and name as an alias so its callers do not change.
//   resident  in physical memory now (Windows: the working set; Linux: VmRSS)
//   private   the process's own memory (Windows: the private commit charge; Linux: RssAnon + VmSwap)
// Zero when the system cannot say.

import tk "../../ext/gui_toolkit/testkit"

Process_Memory :: struct {
	resident: i64,
	private:  i64,
}

process_memory :: proc() -> Process_Memory {
	s := tk.process_state()
	return {resident = s.resident, private = s.private}
}

// The system's counters for this process (the measuring tools and the memory-check driver): the memory above, plus the
// open kernel handles and, on Windows, the GDI and USER objects. Zero for a field the system cannot report (handles are
// the /proc/self/fd entries on Linux; GDI / USER are Windows-only).
Process_Counters :: struct {
	resident, private:        i64,
	handles, gdi, user:       i64,
}

process_counters :: proc() -> Process_Counters {
	s := tk.process_state()
	return {resident = s.resident, private = s.private, handles = s.handles, gdi = s.gdi_objects, user = s.user_objects}
}

// Where the private bytes are, as the system sees them: what the process heaps hold against what they have committed, and
// the private committed pages outside the heaps by kind (read-write / executable). Windows only for now (zero elsewhere).
Memory_Split :: struct {
	heap_allocated, heap_committed: i64,
	vm_rw, vm_exec:                 i64,
}

memory_split :: proc() -> Memory_Split {
	m := tk.memory_split()
	return {heap_allocated = m.heap_allocated, heap_committed = m.heap_committed, vm_rw = m.vm_rw, vm_exec = m.vm_exec}
}
