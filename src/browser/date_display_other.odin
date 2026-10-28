#+build !windows
package browser

// What a date or time field shows when it is not being edited. Windows formats with the user's locale
// (date_display_windows.odin: GetDateFormatEx / GetTimeFormatEx). Off Windows there is no system short-date locale to
// call without pulling in ICU, so the field shows a clear, locale-independent form derived from the HTML value itself:
// a day as "21 Sep 2026", a month as "Sep 2026", a time as "14:30" (24-hour, seconds only when the value has them).
// The value being edited stays the HTML form (yyyy-mm-dd, hh:mm, ...); this is only the resting display.

import "core:strconv"
import "core:strings"
import "wb:forms"

@(private = "file") MONTHS_ABBR := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

@(private = "file")
num :: proc(s: string) -> (int, bool) {
	if len(s) == 0 { return 0, false }
	for c in transmute([]u8)s { if c < '0' || c > '9' { return 0, false } }
	return strconv.parse_int(s, 10)
}

// The resting display of `value` for an input of type `t` ("" when the value is not one of that type: the field then
// shows it as it is). Temp allocator.
date_field_display :: proc(t: forms.Input_Type, value: string) -> string {
	v := strings.trim_space(value)
	if v == "" { return "" }
	#partial switch t {
	case .Date:
		if d, ok := format_date(v, true); ok { return d }
	case .Month:
		if d, ok := format_date(v, false); ok { return d }
	case .Time:
		if tm, ok := format_time(v); ok { return tm }
	case .Datetime_Local:
		i := strings.index_any(v, "T ")
		if i < 0 { return "" }
		d, ok1 := format_date(v[:i], true)
		tm, ok2 := format_time(v[i + 1:])
		if ok1 && ok2 { return strings.concatenate({d, " ", tm}, context.temp_allocator) }
	}
	return ""   // (week: shown as it is, as on Windows, which has no week format)
}

// "2026-09-21" -> "21 Sep 2026"; with_day = false formats a month value "2026-09" -> "Sep 2026".
@(private = "file")
format_date :: proc(s: string, with_day: bool) -> (string, bool) {
	parts := strings.split(s, "-", context.temp_allocator)
	if len(parts) != (with_day ? 3 : 2) { return "", false }
	y, ok1 := num(parts[0])
	m, ok2 := num(parts[1])
	if !ok1 || !ok2 || y < 1601 || y > 30827 || m < 1 || m > 12 { return "", false }   // same range Windows accepts (SYSTEMTIME)
	month := MONTHS_ABBR[m - 1]
	if !with_day {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, month); strings.write_byte(&b, ' '); strings.write_int(&b, y)
		return strings.to_string(b), true
	}
	d, ok3 := num(parts[2])
	if !ok3 || d < 1 || d > 31 { return "", false }
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, d); strings.write_byte(&b, ' ')
	strings.write_string(&b, month); strings.write_byte(&b, ' '); strings.write_int(&b, y)
	return strings.to_string(b), true
}

// "14:30" or "14:30:05" -> the same, validated (24-hour; the HTML form is already how it reads).
@(private = "file")
format_time :: proc(s: string) -> (string, bool) {
	hm := strings.split(s, ":", context.temp_allocator)
	if len(hm) < 2 || len(hm) > 3 { return "", false }
	h, ok1 := num(hm[0])
	m, ok2 := num(hm[1])
	if !ok1 || !ok2 || h > 23 || m > 59 { return "", false }
	b := strings.builder_make(context.temp_allocator)
	write2 :: proc(b: ^strings.Builder, n: int) { if n < 10 { strings.write_byte(b, '0') }; strings.write_int(b, n) }
	write2(&b, h); strings.write_byte(&b, ':'); write2(&b, m)
	if len(hm) == 3 {
		sec := hm[2]
		if i := strings.index_byte(sec, '.'); i >= 0 { sec = sec[:i] }
		sv, ok3 := num(sec)
		if !ok3 || sv > 59 { return "", false }
		strings.write_byte(&b, ':'); write2(&b, sv)
	}
	return strings.to_string(b), true
}
