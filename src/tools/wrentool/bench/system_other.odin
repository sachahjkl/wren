#+build !windows
package bench

// (what the system counts is read on Windows: on another system the columns stay at zero)
read_threads :: proc(pid: int) -> []Thread_Count { return nil }
thread_name :: proc(id: u64) -> string { return "" }
process_working_set :: proc(pid: int) -> int { return 0 }
qpc_now :: proc() -> i64 { return 0 }
