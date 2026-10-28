package jsdate

// Date.parse, ported from QuickJS js_Date_parse: the strict ECMAScript ISO 8601 form first, then the
// legacy "other" format of old browsers (toString / toUTCString and many loose variants). The byte
// buffer is read with a sentinel (0 past the end), matching the C's NUL-terminated scan; a character
// above 255 is folded to '-' (for U+2212) or 'x' by the caller before parse (QuickJS does the same).
// Returns the time value in ms (NaN when nothing parses). The local-time offset, when needed, comes
// from the same host callback as the rest of the package.

// Parse a Date string. The input should already be ASCII-folded (see note above); callers that hold a
// UTF-8 string can use parse (below), which does the fold.
parse_bytes :: proc(sp: []u8) -> f64 {
	fields: [9]int
	is_local: bool
	if date_parse_isostring(sp, &fields, &is_local) || date_parse_otherstring(sp, &fields, &is_local) {
		field_max := [6]int{0, 11, 31, 24, 59, 59}
		valid := true
		for i in 1 ..< 6 {
			if fields[i] > field_max[i] {
				valid = false
			}
		}
		if fields[3] == 24 && (fields[4] | fields[5] | fields[6]) != 0 {
			valid = false
		}
		if valid {
			f: Fields
			for i in 0 ..< 7 {
				f[i] = f64(fields[i])
			}
			d := set_date_fields(f, is_local) - f64(fields[8]) * 60000
			return d
		}
	}
	return nan()
}

// Parse a UTF-8 Date string: fold non-ASCII (U+2212 -> '-', anything else > 255 -> 'x'), cap at 127
// bytes like QuickJS, and parse. A tiny decode is enough; we only distinguish U+2212 from the rest.
parse :: proc(str: string) -> f64 {
	src := transmute([]u8)str
	buf: [128]u8
	i := 0
	j := 0
	for i < len(src) && j < len(buf) - 1 {
		c := src[i]
		if c < 0x80 {
			buf[j] = c
			j += 1
			i += 1
		} else {
			r, w := decode_rune(src[i:])
			i += w
			if r == 0x2212 {
				buf[j] = '-'
			} else if r > 255 {
				buf[j] = 'x'
			} else {
				buf[j] = u8(r)
			}
			j += 1
		}
	}
	buf[j] = 0
	return parse_bytes(buf[:j + 1])
}

@(private)
decode_rune :: proc(b: []u8) -> (r: rune, size: int) {
	if len(b) == 0 { return 0xFFFD, 0 }
	c := b[0]
	if c < 0x80 { return rune(c), 1 }
	if c < 0xC0 { return 0xFFFD, 1 }
	if c < 0xE0 {
		if len(b) < 2 { return 0xFFFD, 1 }
		return rune(u32(c & 0x1F) << 6 | u32(b[1] & 0x3F)), 2
	}
	if c < 0xF0 {
		if len(b) < 3 { return 0xFFFD, 1 }
		return rune(u32(c & 0x0F) << 12 | u32(b[1] & 0x3F) << 6 | u32(b[2] & 0x3F)), 3
	}
	if c < 0xF8 {
		if len(b) < 4 { return 0xFFFD, 1 }
		return rune(u32(c & 0x07) << 18 | u32(b[1] & 0x3F) << 12 | u32(b[2] & 0x3F) << 6 | u32(b[3] & 0x3F)), 4
	}
	return 0xFFFD, 1
}

// sentinel byte read: 0 past the end of the buffer.
@(private)
at :: #force_inline proc(sp: []u8, p: int) -> int {
	if p < 0 || p >= len(sp) {
		return 0
	}
	return int(sp[p])
}

@(private)
to_upper :: #force_inline proc(c: int) -> int {
	if c >= 'a' && c <= 'z' {
		return c - 'a' + 'A'
	}
	return c
}

@(private)
skip_char :: proc(sp: []u8, pp: ^int, c: int) -> bool {
	if at(sp, pp^) == c {
		pp^ += 1
		return true
	}
	return false
}

@(private)
skip_spaces :: proc(sp: []u8, pp: ^int) -> int {
	for at(sp, pp^) == ' ' {
		pp^ += 1
	}
	return at(sp, pp^)
}

@(private)
skip_separators :: proc(sp: []u8, pp: ^int) -> int {
	for {
		c := at(sp, pp^)
		if c == '-' || c == '/' || c == '.' || c == ',' {
			pp^ += 1
		} else {
			return c
		}
	}
}

@(private)
skip_until :: proc(sp: []u8, pp: ^int, stoplist: string) -> int {
	for {
		c := at(sp, pp^)
		found := c == 0 // NUL is always a stop (strchr matches the terminator in the C)
		for sc in transmute([]u8)stoplist {
			if int(sc) == c {
				found = true
				break
			}
		}
		if found {
			return c
		}
		pp^ += 1
	}
}

// parse a numeric field (max_digits == 0 -> no maximum)
@(private)
get_digits :: proc(sp: []u8, pp: ^int, pval: ^int, min_digits, max_digits: int) -> bool {
	v := 0
	p := pp^
	p_start := p
	for {
		c := at(sp, p)
		if c < '0' || c > '9' {
			break
		}
		if v >= 100000000 {
			return false
		}
		v = v * 10 + c - '0'
		p += 1
		if p - p_start == max_digits {
			break
		}
	}
	if p - p_start < min_digits {
		return false
	}
	pval^ = v
	pp^ = p
	return true
}

@(private)
get_milliseconds :: proc(sp: []u8, pp: ^int, pval: ^int) -> bool {
	mul := 100
	ms := 0
	p := pp^
	c := at(sp, p)
	if c == '.' || c == ',' {
		p += 1
		p_start := p
		for {
			c = at(sp, p)
			if c < '0' || c > '9' {
				break
			}
			ms += (c - '0') * mul
			mul /= 10
			p += 1
			if p - p_start == 9 {
				break
			}
		}
		if p > p_start {
			pval^ = ms
			pp^ = p
		}
	}
	return true
}

@(private)
get_tzoffset :: proc(sp: []u8, pp: ^int, tzp: ^int, strict: bool) -> bool {
	tz := 0
	mm := 0
	p := pp^
	sgn := at(sp, p)
	p += 1
	if sgn == '+' || sgn == '-' {
		hh := 0
		n := p
		if !get_digits(sp, &p, &hh, 1, 0) {
			return false
		}
		nd := p - n
		if strict && nd != 2 && nd != 4 {
			return false
		}
		for nd > 4 {
			nd -= 2
			hh /= 100
		}
		if nd > 2 {
			mm = hh % 100
			hh = hh / 100
		} else {
			mm = 0
			if skip_char(sp, &p, ':') {
				if !get_digits(sp, &p, &mm, 2, 2) {
					return false
				}
			}
		}
		if hh > 23 || mm > 59 {
			return false
		}
		tz = hh * 60 + mm
		if sgn != '+' {
			tz = -tz
		}
	} else if sgn != 'Z' {
		return false
	}
	pp^ = p
	tzp^ = tz
	return true
}

@(private)
string_match :: proc(sp: []u8, pp: ^int, s: string) -> bool {
	p := pp^
	for sc in transmute([]u8)s {
		if to_upper(at(sp, p)) != to_upper(int(sc)) {
			return false
		}
		p += 1
	}
	pp^ = p
	return true
}

@(private)
find_abbrev :: proc(sp: []u8, p: int, list: string, count: int) -> int {
	for n in 0 ..< count {
		i := 0
		for {
			if to_upper(at(sp, p + i)) != to_upper(int(list[n * 3 + i])) {
				break
			}
			if i == 2 {
				return n
			}
			i += 1
		}
	}
	return -1
}

@(private)
get_month :: proc(sp: []u8, pp: ^int, pval: ^int) -> bool {
	n := find_abbrev(sp, pp^, month_names, 12)
	if n < 0 {
		return false
	}
	pval^ = n + 1
	pp^ += 3
	return true
}

// strict ISO 8601 (ECMAScript Date Time String Format)
@(private)
date_parse_isostring :: proc(sp: []u8, fields: ^[9]int, is_local: ^bool) -> bool {
	p := 0
	for i in 0 ..< 9 {
		fields[i] = i == 2 ? 1 : 0
	}
	is_local^ = false

	sgn := at(sp, p)
	if sgn == '-' || sgn == '+' {
		p += 1
		if !get_digits(sp, &p, &fields[0], 6, 6) {
			return false
		}
		if sgn == '-' {
			if fields[0] == 0 {
				return false // reject -000000
			}
			fields[0] = -fields[0]
		}
	} else {
		if !get_digits(sp, &p, &fields[0], 4, 4) {
			return false
		}
	}
	if skip_char(sp, &p, '-') {
		if !get_digits(sp, &p, &fields[1], 2, 2) {
			return false
		}
		if fields[1] < 1 {
			return false
		}
		fields[1] -= 1
		if skip_char(sp, &p, '-') {
			if !get_digits(sp, &p, &fields[2], 2, 2) {
				return false
			}
			if fields[2] < 1 {
				return false
			}
		}
	}
	if skip_char(sp, &p, 'T') {
		is_local^ = true
		if !get_digits(sp, &p, &fields[3], 2, 2) || !skip_char(sp, &p, ':') || !get_digits(sp, &p, &fields[4], 2, 2) {
			fields[3] = 100 // reject unconditionally
			return true
		}
		if skip_char(sp, &p, ':') {
			if !get_digits(sp, &p, &fields[5], 2, 2) {
				return false
			}
			get_milliseconds(sp, &p, &fields[6])
		}
	}
	if at(sp, p) != 0 {
		is_local^ = false
		if !get_tzoffset(sp, &p, &fields[8], true) {
			return false
		}
	}
	return at(sp, p) == 0
}

@(private)
Tzabbr :: struct {
	name:   string,
	offset: int,
}

@(private)
js_tzabbr := [?]Tzabbr {
	{"GMT", 0}, {"UTC", 0}, {"UT", 0}, {"Z", 0},
	{"EDT", -4 * 60}, {"EST", -5 * 60}, {"CDT", -5 * 60}, {"CST", -6 * 60},
	{"MDT", -6 * 60}, {"MST", -7 * 60}, {"PDT", -7 * 60}, {"PST", -8 * 60},
	{"WET", 0}, {"WEST", 1 * 60}, {"CET", 1 * 60}, {"CEST", 2 * 60},
	{"EET", 2 * 60}, {"EEST", 3 * 60},
}

@(private)
get_tzabbr :: proc(sp: []u8, pp: ^int, offset: ^int) -> bool {
	for a in js_tzabbr {
		if string_match(sp, pp, a.name) {
			offset^ = a.offset
			return true
		}
	}
	return false
}

// legacy "other" format: toString, toUTCString and many loose variants
@(private)
date_parse_otherstring :: proc(sp: []u8, fields: ^[9]int, is_local: ^bool) -> bool {
	p := 0
	num: [3]int
	has_year := false
	has_mon := false
	has_time := false
	num_index := 0

	fields[0] = 2001
	fields[1] = 1
	fields[2] = 1
	for i in 3 ..< 9 {
		fields[i] = 0
	}
	is_local^ = true

	for skip_spaces(sp, &p) != 0 {
		p_start := p
		c := at(sp, p)
		if c == '+' || c == '-' {
			if has_time && get_tzoffset(sp, &p, &fields[8], false) {
				is_local^ = false
			} else {
				p += 1
				val := 0
				if get_digits(sp, &p, &val, 1, 0) {
					if c == '-' {
						if val == 0 {
							return false
						}
						val = -val
					}
					fields[0] = val
					has_year = true
				}
			}
		} else {
			val := 0
			if get_digits(sp, &p, &val, 1, 0) {
				if skip_char(sp, &p, ':') {
					fields[3] = val
					if !get_digits(sp, &p, &fields[4], 1, 2) {
						return false
					}
					if skip_char(sp, &p, ':') {
						if !get_digits(sp, &p, &fields[5], 1, 2) {
							return false
						}
						get_milliseconds(sp, &p, &fields[6])
					} else if at(sp, p) != 0 && at(sp, p) != ' ' {
						return false
					}
					has_time = true
				} else {
					if p - p_start > 2 {
						fields[0] = val
						has_year = true
					} else if val < 1 || val > 31 {
						fields[0] = val + (val < 100 ? 1900 : 0) + (val < 50 ? 100 : 0)
						has_year = true
					} else {
						if num_index == 3 {
							return false
						}
						num[num_index] = val
						num_index += 1
					}
				}
			} else if get_month(sp, &p, &fields[1]) {
				has_mon = true
				skip_until(sp, &p, "0123456789 -/(")
			} else if has_time && string_match(sp, &p, "PM") {
				if fields[3] != 12 {
					fields[3] += 12
				}
				continue
			} else if has_time && string_match(sp, &p, "AM") {
				if fields[3] > 12 {
					return false
				}
				if fields[3] == 12 {
					fields[3] -= 12
				}
				continue
			} else if get_tzabbr(sp, &p, &fields[8]) {
				is_local^ = false
				continue
			} else if c == '(' {
				level := 0
				for {
					c = at(sp, p)
					if c == 0 {
						break
					}
					p += 1
					level += c == '(' ? 1 : 0
					level -= c == ')' ? 1 : 0
					if level == 0 {
						break
					}
				}
				if level > 0 {
					return false
				}
			} else if c == ')' {
				return false
			} else {
				if (has_year ? 1 : 0) + (has_mon ? 1 : 0) + (has_time ? 1 : 0) + num_index != 0 {
					return false
				}
				skip_until(sp, &p, " -/(")
			}
		}
		skip_separators(sp, &p)
	}
	if num_index + (has_year ? 1 : 0) + (has_mon ? 1 : 0) > 3 {
		return false
	}

	switch num_index {
	case 0:
		if !has_year {
			return false
		}
	case 1:
		if has_mon {
			fields[2] = num[0]
		} else {
			fields[1] = num[0]
		}
	case 2:
		if has_year {
			fields[1] = num[0]
			fields[2] = num[1]
		} else if has_mon {
			fields[0] = num[1] + (num[1] < 100 ? 1900 : 0) + (num[1] < 50 ? 100 : 0)
			fields[2] = num[0]
		} else {
			fields[1] = num[0]
			fields[2] = num[1]
		}
	case 3:
		fields[0] = num[2] + (num[2] < 100 ? 1900 : 0) + (num[2] < 50 ? 100 : 0)
		fields[1] = num[0]
		fields[2] = num[1]
	case:
		return false
	}
	if fields[1] < 1 || fields[2] < 1 {
		return false
	}
	fields[1] -= 1
	return true
}
