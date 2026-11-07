#+build !windows
package browser

// The process queries the crash-recovery markers use, off Windows (crash_recovery_windows.odin has the Windows ones).
// Linux reads /proc: whether a pid runs (its directory exists) and when it began, converted to the same FILETIME scale
// (100 ns since 1601) the shared crash_report_find compares against a report's write time, so the marker format and the
// comparison stay identical to Windows. On a non-Linux POSIX system without /proc the start time is unknown (0), which
// marker_process_alive treats as "do not use the creation time to tell a reused pid apart" — it still reports liveness.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

@(private = "file") CLK_TCK :: 100   // Linux USER_HZ, as base/process_times_other.odin
@(private = "file") FILETIME_UNIX_EPOCH_100NS :: 116_444_736_000_000_000
@(private = "file") BTIME_KEY :: "btime "   // /proc/stat's line of the boot time
@(private = "file") NS_PER_S :: 1_000_000_000

current_pid :: proc() -> u32 {
	when ODIN_OS == .Linux {
		if data, err := os.read_entire_file("/proc/self/stat", context.temp_allocator); err == nil {
			s := string(data)
			if sp := strings.index_byte(s, ' '); sp > 0 {
				if n, ok := strconv.parse_int(s[:sp]); ok { return u32(n) }
			}
		}
	}
	return 0
}

process_created :: proc(pid: u32) -> (created: u64, alive: bool) {
	when ODIN_OS == .Linux {
		stat_path := fmt.tprintf("/proc/%d/stat", pid)
		data, err := os.read_entire_file(stat_path, context.temp_allocator)
		if err != nil { return 0, false }   // no such process
		alive = true
		s := string(data)
		close := strings.last_index_byte(s, ')')   // the comm field may hold spaces inside parentheses
		if close < 0 { return 0, true }
		fields := strings.fields(strings.trim_left_space(s[close + 1:]), context.temp_allocator)
		// after the comm, field 22 (1-based) is starttime in ticks since boot: index 19 here (state is index 0)
		if len(fields) <= 19 { return 0, true }
		start_ticks, ok := strconv.parse_i64(fields[19])
		if !ok { return 0, true }
		boot_unix_ns, bok := boot_time_unix_ns()
		if !bok { return 0, true }
		start_unix_ns := boot_unix_ns + start_ticks * NS_PER_S / CLK_TCK
		created = u64(start_unix_ns / 100 + FILETIME_UNIX_EPOCH_100NS)
		return created, true
	} else {
		// no /proc: liveness is unknown; report "not alive" so a stale marker is treated as an abnormal end (a crash),
		// which is the safe default (recovery offered) rather than silently ignoring a possibly crashed session.
		return 0, false
	}
}

// When the system started, ns since 1970: /proc/stat's btime, whole seconds and the same for every reading of a boot. (Not now less
// /proc/uptime: two readings of that differ by the time between them and uptime's hundredths, so a process's creation time
// read by another process never equalled the one its marker wrote, and a second start of a profile took the Wren running on it
// for a crash: it opened its tabs again and took over its files.)
@(private = "file")
boot_time_unix_ns :: proc() -> (i64, bool) {
	data, err := os.read_entire_file("/proc/stat", context.temp_allocator)
	if err != nil { return 0, false }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, BTIME_KEY) { continue }
		s, ok := strconv.parse_i64(strings.trim_space(line[len(BTIME_KEY):]))
		if !ok { return 0, false }
		return s * NS_PER_S, true
	}
	return 0, false
}
