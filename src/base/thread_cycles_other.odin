#+build !windows
package base

// (no such counter here: `wrentool replay` is a measure of Windows builds)
thread_cycles :: proc "contextless" () -> u64 { return 0 }
