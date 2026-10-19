package js

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
	@(private) FileTimeToSystemTime :: proc(ft: ^win.FILETIME, st: ^win.SYSTEMTIME) -> win.BOOL ---
	@(private) SystemTimeToTzSpecificLocalTimeEx :: proc(tz: rawptr, utc: ^win.SYSTEMTIME, local: ^win.SYSTEMTIME) -> win.BOOL ---
	@(private) SystemTimeToFileTime :: proc(st: ^win.SYSTEMTIME, ft: ^win.FILETIME) -> win.BOOL ---
}

// Minutes to add to local time at `time_ms` (ms since the Unix epoch) to get UTC: Date.prototype.getTimezoneOffset, with
// the daylight saving rules of the system's time zone for that date (dynamic time zone rules included).
timezone_offset :: proc "contextless" (time_ms: f64) -> i32 {
	EPOCH_DIFF_100NS :: 116444736000000000   // 1601-01-01 to 1970-01-01
	if time_ms != time_ms || time_ms > 8.64e15 || time_ms < -8.64e15 { return 0 }
	t := i64(time_ms) * 10_000 + EPOCH_DIFF_100NS
	if t < 0 { t = EPOCH_DIFF_100NS }   // before 1601: the rules of 1970 are as good as any
	ft := win.FILETIME{dwLowDateTime = u32(t), dwHighDateTime = u32(t >> 32)}
	utc, local: win.SYSTEMTIME
	if !FileTimeToSystemTime(&ft, &utc) { return 0 }
	if !SystemTimeToTzSpecificLocalTimeEx(nil, &utc, &local) { return 0 }
	lft: win.FILETIME
	if !SystemTimeToFileTime(&local, &lft) { return 0 }
	l := i64(lft.dwHighDateTime) << 32 | i64(lft.dwLowDateTime)
	return i32((t - l) / 600_000_000)
}
