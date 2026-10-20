package forms

import "core:math"
import "core:strconv"
import "core:strings"

// Microsyntaxes of §2.3.4 (numbers) and §2.3.5 (dates and times), the number <-> string conversions of each input type
// and the step rules of §4.10.5.3.

// "Valid floating-point number": -?(digits | digits? . digits)([eE][+-]?digits)?
is_valid_float :: proc(s: string) -> bool {
	i := 0
	if i < len(s) && s[i] == '-' { i += 1 }
	digits := 0
	for i < len(s) && is_digit(s[i]) { i += 1; digits += 1 }
	if i < len(s) && s[i] == '.' {
		i += 1
		frac := 0
		for i < len(s) && is_digit(s[i]) { i += 1; frac += 1 }
		if frac == 0 { return false }
		digits += frac
	}
	if digits == 0 { return false }
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		if i < len(s) && (s[i] == '-' || s[i] == '+') { i += 1 }
		exp := 0
		for i < len(s) && is_digit(s[i]) { i += 1; exp += 1 }
		if exp == 0 { return false }
	}
	return i == len(s)
}

@(private)
is_digit :: #force_inline proc(c: u8) -> bool { return c >= '0' && c <= '9' }

// "Rules for parsing floating-point number values" restricted to valid input (what sanitization accepts).
parse_float :: proc(s: string) -> (f64, bool) {
	if !is_valid_float(s) { return 0, false }
	v, ok := strconv.parse_f64(s)
	if !ok || math.is_inf(v) || math.is_nan(v) { return 0, false }
	if v == 0 { v = 0 }   // -0 serializes as 0
	return v, true
}

// The rules for parsing floating-point number values (lenient: leading whitespace, trailing garbage), used for the
// min / max / step attributes.
parse_float_lenient :: proc(s: string) -> (f64, bool) {
	t := strings.trim_left(s, " \t\n\r\f")
	end := 0
	if end < len(t) && (t[end] == '-' || t[end] == '+') { end += 1 }
	start_digits := end
	for end < len(t) && is_digit(t[end]) { end += 1 }
	if end < len(t) && t[end] == '.' && end + 1 < len(t) && is_digit(t[end + 1]) {
		end += 1
		for end < len(t) && is_digit(t[end]) { end += 1 }
	}
	if end == start_digits { return 0, false }
	if end < len(t) && (t[end] == 'e' || t[end] == 'E') {
		k := end + 1
		if k < len(t) && (t[k] == '-' || t[k] == '+') { k += 1 }
		if k < len(t) && is_digit(t[k]) {
			for k < len(t) && is_digit(t[k]) { k += 1 }
			end = k
		}
	}
	v, ok := strconv.parse_f64(t[:end])
	if !ok || math.is_inf(v) || math.is_nan(v) { return 0, false }
	return v, true
}

// The "best representation of the number n as a floating-point number": shortest round-trip, like JavaScript.
format_float :: proc(v: f64, allocator := context.temp_allocator) -> string {
	if v == 0 || math.is_nan(v) || math.is_inf(v) { return strings.clone(v == 0 ? "0" : "NaN", allocator) }
	// shortest digits and exponent from the 'e' form ("+d.ddde-XX"), then Number::toString's layout rules
	buf: [64]u8
	s := strconv.write_float(buf[:], abs(v), 'e', -1, 64)
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') { s = s[1:] }
	e := strings.index_byte(s, 'e')
	if e < 0 { return strings.clone(s, allocator) }
	mant := s[:e]
	exp, _ := strconv.parse_int(s[e + 1:], 10)
	dbuf: [32]u8
	k := 0
	for c in transmute([]u8)mant { if c != '.' { dbuf[k] = c; k += 1 } }
	for k > 1 && dbuf[k - 1] == '0' { k -= 1 }
	digits := string(dbuf[:k])
	n := exp + 1
	sb := strings.builder_make(allocator)
	if v < 0 { strings.write_byte(&sb, '-') }
	switch {
	case k <= n && n <= 21:
		strings.write_string(&sb, digits)
		for _ in 0 ..< n - k { strings.write_byte(&sb, '0') }
	case 0 < n && n <= 21:
		strings.write_string(&sb, digits[:n]); strings.write_byte(&sb, '.'); strings.write_string(&sb, digits[n:])
	case -6 < n && n <= 0:
		strings.write_string(&sb, "0.")
		for _ in 0 ..< -n { strings.write_byte(&sb, '0') }
		strings.write_string(&sb, digits)
	case:
		strings.write_byte(&sb, digits[0])
		if k > 1 { strings.write_byte(&sb, '.'); strings.write_string(&sb, digits[1:]) }
		strings.write_byte(&sb, 'e')
		strings.write_byte(&sb, n - 1 < 0 ? '-' : '+')
		ebuf: [8]u8
		strings.write_string(&sb, strconv.write_int(ebuf[:], i64(abs(n - 1)), 10))
	}
	return strings.to_string(sb)
}

////////////////////////////////
// Dates (proleptic Gregorian, days since 1970-01-01)

days_from_civil :: proc(y, m, d: i64) -> i64 {
	yy := m <= 2 ? y - 1 : y
	era := (yy >= 0 ? yy : yy - 399) / 400
	yoe := yy - era * 400
	mp := m > 2 ? m - 3 : m + 9
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

civil_from_days :: proc(z0: i64) -> (y, m, d: i64) {
	z := z0 + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y = yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = doy - (153 * mp + 2) / 5 + 1
	m = mp < 10 ? mp + 3 : mp - 9
	if m <= 2 { y += 1 }
	return
}

is_leap :: proc(y: i64) -> bool { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

days_in_month :: proc(y, m: i64) -> i64 {
	switch m {
	case 2: return is_leap(y) ? 29 : 28
	case 4, 6, 9, 11: return 30
	}
	return 31
}

// ISO weekday, Monday = 1.
weekday :: proc(days: i64) -> i64 {
	r := (days + 3) %% 7
	return r + 1
}

weeks_in_year :: proc(y: i64) -> i64 {
	jan1 := weekday(days_from_civil(y, 1, 1))
	if jan1 == 4 || (jan1 == 3 && is_leap(y)) { return 53 }
	return 52
}

@(private)
week1_monday :: proc(y: i64) -> i64 {
	jan4 := days_from_civil(y, 1, 4)
	return jan4 - (weekday(jan4) - 1)
}

MS_PER_DAY :: 86_400_000

// Reads exactly `n` digits at s[i:].
@(private)
digits :: proc(s: string, i: ^int, n: int) -> (v: i64, ok: bool) {
	if i^ + n > len(s) { return 0, false }
	for k in 0 ..< n {
		c := s[i^ + k]
		if !is_digit(c) { return 0, false }
		v = v * 10 + i64(c - '0')
	}
	i^ += n
	return v, true
}

// A year: four or more digits, greater than zero.
@(private)
parse_year :: proc(s: string, i: ^int) -> (i64, bool) {
	start := i^
	y: i64
	for i^ < len(s) && is_digit(s[i^]) {
		if i^ - start > 9 { return 0, false }   // keeps the arithmetic far from overflow (and from silly dates)
		y = y * 10 + i64(s[i^] - '0')
		i^ += 1
	}
	// up to 275760, the last year of the ECMAScript time range: beyond, weeks and local date-times overflowed i64 ms
	if i^ - start < 4 || y <= 0 || y > 275760 { return 0, false }
	return y, true
}

@(private)
expect :: proc(s: string, i: ^int, c: u8) -> bool {
	if i^ < len(s) && s[i^] == c { i^ += 1; return true }
	return false
}

@(private)
parse_date_component :: proc(s: string, i: ^int) -> (y, m, d: i64, ok: bool) {
	y = parse_year(s, i) or_return
	expect(s, i, '-') or_return
	m = digits(s, i, 2) or_return
	if m < 1 || m > 12 { return }
	expect(s, i, '-') or_return
	d = digits(s, i, 2) or_return
	if d < 1 || d > days_in_month(y, m) { return }
	ok = true
	return
}

// Time of day in milliseconds: HH:MM[:SS[.f{1,3}]]
@(private)
parse_time_component :: proc(s: string, i: ^int) -> (ms: i64, ok: bool) {
	h := digits(s, i, 2) or_return
	if h > 23 { return }
	expect(s, i, ':') or_return
	m := digits(s, i, 2) or_return
	if m > 59 { return }
	sec, frac: i64
	if expect(s, i, ':') {
		sec = digits(s, i, 2) or_return
		if sec > 59 { return }
		if expect(s, i, '.') {
			n := 0
			for i^ < len(s) && is_digit(s[i^]) {
				if n >= 3 { return }
				frac = frac * 10 + i64(s[i^] - '0')
				n += 1
				i^ += 1
			}
			if n == 0 { return }
			for _ in n ..< 3 { frac *= 10 }
		}
	}
	return ((h * 60 + m) * 60 + sec) * 1000 + frac, true
}

parse_date :: proc(s: string) -> (days: i64, ok: bool) {
	i := 0
	y, m, d := parse_date_component(s, &i) or_return
	if i != len(s) { return 0, false }
	return days_from_civil(y, m, d), true
}

// Months since 1970-01.
parse_month :: proc(s: string) -> (months: i64, ok: bool) {
	i := 0
	y := parse_year(s, &i) or_return
	expect(s, &i, '-') or_return
	m := digits(s, &i, 2) or_return
	if m < 1 || m > 12 || i != len(s) { return 0, false }
	return (y - 1970) * 12 + m - 1, true
}

// Milliseconds since the epoch of the Monday the week starts on.
parse_week :: proc(s: string) -> (ms: i64, ok: bool) {
	i := 0
	y := parse_year(s, &i) or_return
	expect(s, &i, '-') or_return
	expect(s, &i, 'W') or_return
	w := digits(s, &i, 2) or_return
	if w < 1 || w > weeks_in_year(y) || i != len(s) { return 0, false }
	return (week1_monday(y) + (w - 1) * 7) * MS_PER_DAY, true
}

parse_time :: proc(s: string) -> (ms: i64, ok: bool) {
	i := 0
	ms = parse_time_component(s, &i) or_return
	if i != len(s) { return 0, false }
	return ms, true
}

// Local date and time: date, 'T' or ' ', time. Milliseconds since the epoch, the local time read as UTC.
parse_datetime_local :: proc(s: string) -> (ms: i64, ok: bool) {
	i := 0
	y, m, d := parse_date_component(s, &i) or_return
	if !expect(s, &i, 'T') && !expect(s, &i, ' ') { return 0, false }
	t := parse_time_component(s, &i) or_return
	if i != len(s) { return 0, false }
	return days_from_civil(y, m, d) * MS_PER_DAY + t, true
}

@(private)
write_padded :: proc(sb: ^strings.Builder, v: i64, width: int) {
	buf: [24]u8
	s := strconv.write_int(buf[:], v, 10)
	for _ in len(s) ..< width { strings.write_byte(sb, '0') }
	strings.write_string(sb, s)
}

format_date :: proc(days: i64, allocator := context.temp_allocator) -> string {
	y, m, d := civil_from_days(days)
	sb := strings.builder_make(allocator)
	write_padded(&sb, y, 4); strings.write_byte(&sb, '-'); write_padded(&sb, m, 2); strings.write_byte(&sb, '-'); write_padded(&sb, d, 2)
	return strings.to_string(sb)
}

format_month :: proc(months: i64, allocator := context.temp_allocator) -> string {
	y := 1970 + floor_div(months, 12)
	m := months - floor_div(months, 12) * 12 + 1
	sb := strings.builder_make(allocator)
	write_padded(&sb, y, 4); strings.write_byte(&sb, '-'); write_padded(&sb, m, 2)
	return strings.to_string(sb)
}

format_week :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	days := floor_div(ms, MS_PER_DAY)
	thursday := days - (weekday(days) - 1) + 3
	y, _, _ := civil_from_days(thursday)
	w := (thursday - week1_monday(y)) / 7 + 1
	sb := strings.builder_make(allocator)
	write_padded(&sb, y, 4); strings.write_string(&sb, "-W"); write_padded(&sb, w, 2)
	return strings.to_string(sb)
}

// Shortest valid time string: seconds and fraction only when non-zero.
format_time :: proc(ms0: i64, allocator := context.temp_allocator) -> string {
	ms := ms0 %% MS_PER_DAY
	h := ms / 3_600_000
	mi := (ms / 60_000) % 60
	s := (ms / 1000) % 60
	frac := ms % 1000
	sb := strings.builder_make(allocator)
	write_padded(&sb, h, 2); strings.write_byte(&sb, ':'); write_padded(&sb, mi, 2)
	if s != 0 || frac != 0 {
		strings.write_byte(&sb, ':'); write_padded(&sb, s, 2)
		if frac != 0 {
			strings.write_byte(&sb, '.')
			digits_buf: [3]u8
			digits_buf[0] = u8('0' + frac / 100); digits_buf[1] = u8('0' + (frac / 10) % 10); digits_buf[2] = u8('0' + frac % 10)
			n := 3
			for n > 1 && digits_buf[n - 1] == '0' { n -= 1 }
			strings.write_string(&sb, string(digits_buf[:n]))
		}
	}
	return strings.to_string(sb)
}

format_datetime_local :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	days := floor_div(ms, MS_PER_DAY)
	return strings.concatenate({format_date(days), "T", format_time(ms - days * MS_PER_DAY)}, allocator)
}

@(private)
floor_div :: proc(a, b: i64) -> i64 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) { q -= 1 }
	return q
}

// Dates beyond these are refused by every conversion (ECMAScript's time value range: ±8.64e15 ms).
MAX_TIME_MS :: 8.64e15

////////////////////////////////
// Per type: value string <-> number (valueAsNumber), step defaults

// The number a value string means for this type (ms, months, or the number itself).
number_from_string :: proc(t: Input_Type, s: string) -> (f64, bool) {
	#partial switch t {
	case .Number, .Range: return parse_float(s)
	case .Date:
		d, ok := parse_date(s)
		if !ok || f64(d) * MS_PER_DAY > MAX_TIME_MS { return 0, false }
		return f64(d) * MS_PER_DAY, true
	case .Month:
		m, ok := parse_month(s)
		return f64(m), ok
	case .Week:
		w, ok := parse_week(s)
		if !ok || abs(f64(w)) > MAX_TIME_MS { return 0, false }
		return f64(w), true
	case .Time:
		t2, ok := parse_time(s)
		return f64(t2), ok
	case .Datetime_Local:
		v, ok := parse_datetime_local(s)
		if !ok || abs(f64(v)) > MAX_TIME_MS { return 0, false }
		return f64(v), true
	}
	return 0, false
}

string_from_number :: proc(t: Input_Type, v: f64, allocator := context.temp_allocator) -> (string, bool) {
	if math.is_nan(v) || math.is_inf(v) { return "", false }
	#partial switch t {
	case .Number, .Range: return format_float(v, allocator), true
	case .Date:
		if abs(v) > MAX_TIME_MS { return "", false }
		days := floor_div(i64(math.floor(v)), MS_PER_DAY)
		if civil_year(days) < 1 { return "", false }
		return format_date(days, allocator), true
	case .Month:
		if !(abs(v) <= 1e12) { return "", false }
		m := i64(math.floor(v))
		if 1970 + floor_div(m, 12) < 1 { return "", false }   // (truncating division let year 0 through: "0000-12")
		return format_month(m, allocator), true
	case .Week:
		if abs(v) > MAX_TIME_MS { return "", false }
		return format_week(i64(math.floor(v)), allocator), true
	case .Time:
		return format_time(i64(math.floor(v)), allocator), true
	case .Datetime_Local:
		if abs(v) > MAX_TIME_MS { return "", false }
		ms := i64(math.floor(v))
		if civil_year(floor_div(ms, MS_PER_DAY)) < 1 { return "", false }
		return format_datetime_local(ms, allocator), true
	}
	return "", false
}

@(private)
civil_year :: proc(days: i64) -> i64 {
	y, _, _ := civil_from_days(days)
	return y
}

// valueAsDate applies to date, month, week, time, datetime-local is not included (§4.10.5.4).
as_date_applies :: proc(t: Input_Type) -> bool { return t == .Date || t == .Month || t == .Week || t == .Time }

// The Date (ms since epoch) for valueAsDate.
date_from_string :: proc(t: Input_Type, s: string) -> (f64, bool) {
	#partial switch t {
	case .Month:
		m, ok := parse_month(s)
		if !ok { return 0, false }
		y := 1970 + floor_div(m, 12)
		mo := m - floor_div(m, 12) * 12 + 1
		return f64(days_from_civil(y, mo, 1)) * MS_PER_DAY, true
	case .Date, .Week, .Time: return number_from_string(t, s)
	}
	return 0, false
}

string_from_date :: proc(t: Input_Type, ms: f64, allocator := context.temp_allocator) -> (string, bool) {
	if t == .Month {
		if math.is_nan(ms) { return "", false }
		days := floor_div(i64(math.floor(ms)), MS_PER_DAY)
		y, m, _ := civil_from_days(days)
		return string_from_number(.Month, f64((y - 1970) * 12 + m - 1), allocator)
	}
	return string_from_number(t, ms, allocator)
}

Step_Info :: struct {
	default_step: f64,
	scale:        f64,     // step scale factor
	default_base: f64,
}

step_info :: proc(t: Input_Type) -> Step_Info {
	#partial switch t {
	case .Date: return {1, MS_PER_DAY, 0}
	case .Month: return {1, 1, 0}
	case .Week: return {1, 7 * MS_PER_DAY, -259_200_000}
	case .Time, .Datetime_Local: return {60, 1000, 0}
	case .Number, .Range: return {1, 1, 0}
	}
	return {1, 1, 0}
}
