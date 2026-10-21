package browser

// What a date or time field shows when it is not being edited: its value in the user's own short format, as Chromium
// and Edge show it (they format with the operating system's locale, not the page's language): 2026-09-21 is
// "21/09/2026" for a French user, "9/21/2026" for an American one. The value itself (and what is typed while the field
// has focus) stays the HTML form (yyyy-mm-dd, hh:mm, yyyy-mm, yyyy-Www, yyyy-mm-ddThh:mm). Win32 does the formatting:
// GetDateFormatEx / GetTimeFormatEx with LOCALE_NAME_USER_DEFAULT.

import "core:strconv"
import "core:strings"
import "core:unicode/utf16"
import win "core:sys/windows"
import "wb:forms"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetDateFormatEx :: proc(locale: win.LPCWSTR, flags: win.DWORD, date: ^win.SYSTEMTIME, format: win.LPCWSTR, out: win.LPWSTR, out_len: i32, calendar: win.LPCWSTR) -> i32 ---
	GetTimeFormatEx :: proc(locale: win.LPCWSTR, flags: win.DWORD, time: ^win.SYSTEMTIME, format: win.LPCWSTR, out: win.LPWSTR, out_len: i32) -> i32 ---
}

@(private = "file") DATE_SHORTDATE :: 0x1
@(private = "file") DATE_YEARMONTH :: 0x8
@(private = "file") TIME_NOSECONDS :: 0x2

// The user's short form of `value` for an input of type `t` ("" when the value is not one of that type: the field then
// shows it as it is). Temp allocator.
date_field_display :: proc(t: forms.Input_Type, value: string) -> string {
	v := strings.trim_space(value)
	if v == "" { return "" }
	num :: proc(s: string) -> (int, bool) {
		if len(s) == 0 { return 0, false }
		for c in transmute([]u8)s { if c < '0' || c > '9' { return 0, false } }
		return strconv.parse_int(s, 10)
	}
	st: win.SYSTEMTIME
	date_part :: proc(st: ^win.SYSTEMTIME, s: string, with_day: bool) -> bool {
		parts := strings.split(s, "-", context.temp_allocator)
		if len(parts) != (with_day ? 3 : 2) { return false }
		y, ok1 := num(parts[0])
		m, ok2 := num(parts[1])
		if !ok1 || !ok2 || y < 1601 || y > 30827 || m < 1 || m > 12 { return false }   // (SYSTEMTIME's range)
		st.year, st.month, st.day = u16(y), u16(m), 1
		if with_day {
			d, ok3 := num(parts[2])
			if !ok3 || d < 1 || d > 31 { return false }
			st.day = u16(d)
		}
		return true
	}
	time_part :: proc(st: ^win.SYSTEMTIME, s: string) -> bool {
		hm := strings.split(s, ":", context.temp_allocator)
		if len(hm) < 2 || len(hm) > 3 { return false }
		h, ok1 := num(hm[0])
		m, ok2 := num(hm[1])
		if !ok1 || !ok2 || h > 23 || m > 59 { return false }
		st.hour, st.minute = u16(h), u16(m)
		if len(hm) == 3 {
			sec := hm[2]
			if i := strings.index_byte(sec, '.'); i >= 0 { sec = sec[:i] }
			sv, ok3 := num(sec)
			if !ok3 || sv > 59 { return false }
			st.second = u16(sv)
		}
		return true
	}
	#partial switch t {
	case .Date:
		if !date_part(&st, v, true) { return "" }
		return format_date(&st, DATE_SHORTDATE)
	case .Month:
		if !date_part(&st, v, false) { return "" }
		return format_date(&st, DATE_YEARMONTH)
	case .Time:
		if !time_part(&st, v) { return "" }
		return format_time(&st, st.second == 0 ? TIME_NOSECONDS : 0)
	case .Datetime_Local:
		i := strings.index_any(v, "T ")
		if i < 0 || !date_part(&st, v[:i], true) || !time_part(&st, v[i + 1:]) { return "" }
		d := format_date(&st, DATE_SHORTDATE)
		tm := format_time(&st, st.second == 0 ? TIME_NOSECONDS : 0)
		if d == "" || tm == "" { return "" }
		return strings.concatenate({d, " ", tm}, context.temp_allocator)
	}
	return ""   // (week: shown as it is, Windows has no week format)
}

@(private = "file")
format_date :: proc(st: ^win.SYSTEMTIME, flags: win.DWORD) -> string {
	buf: [128]u16
	n := GetDateFormatEx(nil, flags, st, nil, &buf[0], i32(len(buf)), nil)
	return utf16_string(buf[:max(n - 1, 0)])
}

@(private = "file")
format_time :: proc(st: ^win.SYSTEMTIME, flags: win.DWORD) -> string {
	buf: [128]u16
	n := GetTimeFormatEx(nil, flags, st, nil, &buf[0], i32(len(buf)))
	return utf16_string(buf[:max(n - 1, 0)])
}

@(private = "file")
utf16_string :: proc(w: []u16) -> string {
	out := make([]u8, len(w) * 3, context.temp_allocator)
	n := utf16.decode_to_utf8(out, w)
	return string(out[:n])
}
