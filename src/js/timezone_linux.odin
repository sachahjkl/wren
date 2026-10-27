package js

import "core:os"
import "core:strings"
import "core:sys/posix"

@(private) tz_name_cache: [64]u8
@(private) tz_name_len: int
@(private) tz_name_done: bool

// The IANA name of the system's time zone ("Europe/Paris"): TZ when it names a zone (":Europe/Paris" too), otherwise
// where /etc/localtime points under a zoneinfo directory, otherwise /etc/timezone (Debian's); "UTC" when none says.
// Computed once per process.
timezone_name :: proc() -> string {
	if tz_name_done { return string(tz_name_cache[:tz_name_len]) }
	tz_name_done = true
	set :: proc(raw: string) -> bool {
		name := strings.trim_space(raw)
		if name == "" || len(name) >= len(tz_name_cache) { return false }
		for c in transmute([]u8)name {
			if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '/' || c == '_' || c == '-' || c == '+') { return false }
		}
		copy(tz_name_cache[:], name)
		tz_name_len = len(name)
		return true
	}
	if tz := os.get_env("TZ", context.temp_allocator); tz != "" {
		tz = strings.trim_prefix(tz, ":")
		if i := strings.index(tz, "zoneinfo/"); i >= 0 { tz = tz[i + len("zoneinfo/"):] }
		// a zone name, not a POSIX rule ("CET-1CEST,M3.5.0,M10.5.0/3": the clock still follows it, the name is unknown)
		if strings.contains_rune(tz, '/') || tz == "UTC" { if set(tz) { return string(tz_name_cache[:tz_name_len]) } }
	}
	buf: [512]u8
	if n := posix.readlink("/etc/localtime", &buf[0], len(buf) - 1); n > 0 {
		target := string(buf[:n])
		if i := strings.index(target, "zoneinfo/"); i >= 0 && set(target[i + len("zoneinfo/"):]) { return string(tz_name_cache[:tz_name_len]) }
	}
	if data, err := os.read_entire_file("/etc/timezone", context.temp_allocator); err == nil && set(string(data)) {
		return string(tz_name_cache[:tz_name_len])
	}
	set("UTC")
	return string(tz_name_cache[:tz_name_len])
}

// Minutes to add to local time at `time_ms` (ms since the Unix epoch) to get UTC: Date.prototype.getTimezoneOffset, with
// the daylight saving rules of the system's time zone for that date (the C library's: TZ, then /etc/localtime).
timezone_offset :: proc "contextless" (time_ms: f64) -> i32 {
	if time_ms != time_ms || time_ms > 8.64e15 || time_ms < -8.64e15 { return 0 }
	secs := posix.time_t(i64(time_ms) / 1000)
	if time_ms < 0 && i64(time_ms) % 1000 != 0 { secs -= 1 }   // floor: the second the instant is in
	local: posix.tm
	if posix.localtime_r(&secs, &local) == nil { return 0 }
	return i32(-local.tm_gmtoff / 60)
}
