#+build !windows
package base

// CPU and wall time of the running process and its thread count (process_times_windows.odin has the Windows reader and
// the doc). On Linux it is a cheap read of /proc; on other POSIX systems /proc is absent, so the fields it cannot fill
// stay zero (CPU time falls back to the thread clock) and the thread count is -1. Zero / -1 means "the system did not say".

import "core:os"
import "core:strconv"
import "core:strings"

Process_Times :: struct {
	user_ms, kernel_ms: f64,
	uptime_ms:          f64,
}

// The kernel's clock-tick rate for /proc times. Linux fixes it at 100 (USER_HZ) on every current configuration; this is
// what glibc's sysconf(_SC_CLK_TCK) returns there. Kept as a constant so no libc call is needed.
@(private = "file") CLK_TCK :: 100

process_times :: proc() -> (t: Process_Times) {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/stat", context.temp_allocator)
		if err != nil { return }
		s := string(data)
		// the fields after the comm name, which may itself hold spaces inside its parentheses: skip to the last ')'
		close := strings.last_index_byte(s, ')')
		if close < 0 { return }
		rest := strings.trim_left_space(s[close + 1:])
		fields := strings.fields(rest, context.temp_allocator)
		// rest starts at field 3 (state); utime is field 14, stime 15, starttime 22 (1-based), i.e. indices 11, 12, 19 here
		tick_ms :: proc(v: string) -> f64 {
			n, ok := strconv.parse_i64(v)
			if !ok { return 0 }
			return f64(n) * 1000 / CLK_TCK
		}
		if len(fields) > 12 {
			t.user_ms = tick_ms(fields[11])
			t.kernel_ms = tick_ms(fields[12])
		}
		if len(fields) > 19 {
			if start_ticks, ok := strconv.parse_i64(fields[19]); ok {
				// starttime is ticks since boot; uptime of the boot is /proc/uptime's first number (seconds)
				if up, uerr := os.read_entire_file("/proc/uptime", context.temp_allocator); uerr == nil {
					utext := string(up)
					if sp := strings.index_byte(utext, ' '); sp > 0 { utext = utext[:sp] }
					if boot_s, perr := strconv.parse_f64(strings.trim_space(utext)); perr {
						t.uptime_ms = max(boot_s * 1000 - f64(start_ticks) * 1000 / CLK_TCK, 0)
					}
				}
			}
		}
	}
	// no /proc (a non-Linux POSIX system): the fields stay zero; the caller reads that as "the system did not say".
	return
}

// Threads of this process: the Threads: line of /proc/self/status on Linux, else -1 (the system does not say here).
process_threads :: proc() -> int {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
		if err != nil { return -1 }
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "Threads:") {
				if n, ok := strconv.parse_int(strings.trim_space(line[len("Threads:"):])); ok { return n }
			}
		}
	}
	return -1
}
