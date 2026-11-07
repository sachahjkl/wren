#+build !windows
package bench

// (what the system counts is read on Windows: on another system the columns stay at zero)
read_threads :: proc(pid: int) -> []Thread_Count { return nil }
thread_name :: proc(id: u64) -> string { return "" }
process_working_set :: proc(pid: int) -> int { return 0 }
qpc_now :: proc() -> i64 { return 0 }

Thread_Reader :: distinct rawptr
thread_reader :: proc(id: int) -> Thread_Reader { return nil }
thread_reader_ok :: proc(r: Thread_Reader) -> bool { return false }
thread_reader_close :: proc(r: Thread_Reader) {}
thread_read :: proc(r: Thread_Reader) -> u64 { return 0 }
machine_times :: proc() -> (busy, total: i64) { return 0, 1 }
