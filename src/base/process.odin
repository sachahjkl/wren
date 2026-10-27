package base

// What the system says of the process's memory, for the measuring tools and tests (process_<os>.odin):
//   resident  in physical memory now (Windows: the working set; Linux: VmRSS)
//   private   the process's own memory (Windows: the private commit charge; Linux: anonymous resident memory plus what
//             of it is swapped out, RssAnon + VmSwap: no file or shared mapping)
// Zero when the system cannot say.
Process_Memory :: struct {
	resident: i64,
	private:  i64,
}

process_memory :: proc() -> Process_Memory { return native_process_memory() }
