package jsdate

// Date-to-string formatting, ported from QuickJS get_date_string. Produces the exact byte output of
// toUTCString, toString, toISOString and the toLocale* default forms, writing into a caller buffer
// and returning the length. No snprintf: the fixed-width integer fields are written by small helpers,
// which keeps the package free of libc and buildable for freestanding_wasm32.
//
// A [64]u8 buffer is always enough (toString is the longest at ~35 bytes; a 7-digit year adds a few).

// Output format selector (matches the `fmt` magic in QuickJS).
Format :: enum {
	UTC     = 0, // "Tue, 02 Jan 2018 23:04:46 GMT"
	ToString = 1, // "Wed Jan 03 2018 00:05:22 GMT+0100"  (no "(CET)" tail; QuickJS omits it too)
	ISO     = 2, // "2018-01-02T23:02:56.927Z"
	Locale  = 3, // "1/2/2018, 11:40:40 PM"
}

// Which part(s) to emit.
Part :: enum {
	Date = 1,
	Time = 2,
	All  = 3,
}

// Write the formatted date into buf (>= 64 bytes). Returns the length, or -1 when the time value is
// NaN and the format is ISO (the caller throws a RangeError); for the other formats a NaN value makes
// the caller emit "Invalid Date" before calling here, so this is only called with valid fields.
format_date :: proc(buf: []u8, fields: Fields, fmt: Format, part: Part) -> int {
	y := int(fields[0])
	mon := int(fields[1])
	d := int(fields[2])
	h := int(fields[3])
	m := int(fields[4])
	s := int(fields[5])
	ms := int(fields[6])
	wd := int(fields[7])
	tz := int(fields[8])

	q := 0
	w :: proc(buf: []u8, q: ^int, s: string) {
		for c in transmute([]u8)s {
			buf[q^] = c
			q^ += 1
		}
	}
	// write n as a zero-padded decimal of exactly `width` digits
	pad :: proc(buf: []u8, q: ^int, n_in, width: int) {
		n := n_in
		start := q^
		for _ in 0 ..< width {
			buf[q^] = '0'
			q^ += 1
		}
		i := q^ - 1
		if n == 0 {
			return
		}
		for n > 0 && i >= start {
			buf[i] = u8(n % 10) + '0'
			n /= 10
			i -= 1
		}
	}
	// write n with no padding
	num :: proc(buf: []u8, q: ^int, n_in: int) {
		n := n_in
		if n == 0 {
			buf[q^] = '0'
			q^ += 1
			return
		}
		tmp: [12]u8
		k := 0
		for n > 0 {
			tmp[k] = u8(n % 10) + '0'
			n /= 10
			k += 1
		}
		for j := k - 1; j >= 0; j -= 1 {
			buf[q^] = tmp[j]
			q^ += 1
		}
	}
	abbrev :: proc(buf: []u8, q: ^int, table: string, idx: int) {
		for k in 0 ..< 3 {
			buf[q^] = table[idx * 3 + k]
			q^ += 1
		}
	}
	// signed year with a leading sign for negatives, min 4 digits (plus sign)
	year_field :: proc(buf: []u8, q: ^int, y: int) {
		yy := y
		if yy < 0 {
			buf[q^] = '-'
			q^ += 1
			yy = -yy
		}
		// min width 4
		width := 4
		d := yy
		n := 1
		for d >= 10 { d /= 10; n += 1 }
		if n > width { width = n }
		pad(buf, q, yy, width)
	}

	if int(part) & 1 != 0 { // date part
		switch fmt {
		case .UTC:
			abbrev(buf, &q, day_names, wd)
			w(buf, &q, ", ")
			pad(buf, &q, d, 2)
			buf[q] = ' ';q += 1
			abbrev(buf, &q, month_names, mon)
			buf[q] = ' ';q += 1
			year_field(buf, &q, y)
			buf[q] = ' ';q += 1
		case .ToString:
			abbrev(buf, &q, day_names, wd)
			buf[q] = ' ';q += 1
			abbrev(buf, &q, month_names, mon)
			buf[q] = ' ';q += 1
			pad(buf, &q, d, 2)
			buf[q] = ' ';q += 1
			year_field(buf, &q, y)
			if part == .All {
				buf[q] = ' ';q += 1
			}
		case .ISO:
			if y >= 0 && y <= 9999 {
				pad(buf, &q, y, 4)
			} else {
				if y < 0 {
					buf[q] = '-';q += 1
					pad(buf, &q, -y, 6)
				} else {
					buf[q] = '+';q += 1
					pad(buf, &q, y, 6)
				}
			}
			buf[q] = '-';q += 1
			pad(buf, &q, mon + 1, 2)
			buf[q] = '-';q += 1
			pad(buf, &q, d, 2)
			buf[q] = 'T';q += 1
		case .Locale:
			num(buf, &q, mon + 1)
			buf[q] = '/';q += 1
			num(buf, &q, d)
			buf[q] = '/';q += 1
			year_field(buf, &q, y)
			if part == .All {
				buf[q] = ',';q += 1
				buf[q] = ' ';q += 1
			}
		}
	}

	if int(part) & 2 != 0 { // time part
		switch fmt {
		case .UTC:
			pad(buf, &q, h, 2); buf[q] = ':';q += 1
			pad(buf, &q, m, 2); buf[q] = ':';q += 1
			pad(buf, &q, s, 2)
			w(buf, &q, " GMT")
		case .ToString:
			pad(buf, &q, h, 2); buf[q] = ':';q += 1
			pad(buf, &q, m, 2); buf[q] = ':';q += 1
			pad(buf, &q, s, 2)
			w(buf, &q, " GMT")
			t := tz
			if t < 0 {
				buf[q] = '-';q += 1
				t = -t
			} else {
				buf[q] = '+';q += 1
			}
			pad(buf, &q, t / 60, 2)
			pad(buf, &q, t % 60, 2)
		case .ISO:
			pad(buf, &q, h, 2); buf[q] = ':';q += 1
			pad(buf, &q, m, 2); buf[q] = ':';q += 1
			pad(buf, &q, s, 2); buf[q] = '.';q += 1
			pad(buf, &q, ms, 3)
			buf[q] = 'Z';q += 1
		case .Locale:
			hr := (h + 11) % 12 + 1
			pad(buf, &q, hr, 2); buf[q] = ':';q += 1
			pad(buf, &q, m, 2); buf[q] = ':';q += 1
			pad(buf, &q, s, 2)
			buf[q] = ' ';q += 1
			buf[q] = h < 12 ? 'A' : 'P';q += 1
			buf[q] = 'M';q += 1
		}
	}
	return q
}
