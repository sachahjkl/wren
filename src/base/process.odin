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
