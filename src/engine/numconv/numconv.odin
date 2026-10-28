package numconv

// Public surface of the numeric conversion package: the ECMAScript number <-> string operations that
// Number.prototype, the Number() coercion, parseInt and parseFloat need, built on the exact dtoa/atod
// core. Everything here is allocation-free: the string producers write into a caller buffer and return
// the length; the parsers read a string and return an f64. This is what lets the whole package build
// for freestanding_wasm32 with no allocator.
//
// Buffer sizing: a caller that does not want to compute a bound can use a [MAX_STR_LEN]u8 on the stack.
// A tighter bound for a specific call is dtoa_max_len(...) + 1.

// A buffer of this size is always enough for any dtoa output (sign + up to ~1100 digits for a frac
// format in radix 2, the dot and a NUL). JS_DTOA_MAX_DIGITS plus the integer part worst case.
MAX_STR_LEN :: 1280

// --- float64 -> string ---

// The ECMAScript Number::toString(x) (ToString applied to a Number) in base 10: the shortest decimal
// that round-trips, with automatic exponential form. Identical to QuickJS's default float stringify.
// Writes into buf (>= needed; use a [MAX_STR_LEN]u8 to be safe) and returns the written length.
f64_to_shortest :: proc(buf: []u8, d: f64) -> int {
	return dtoa(raw_data(buf), d, 10, 0, .Free, .Auto)
}

// Number.prototype.toString(radix): free format, auto exponent in base 10, exponent disabled for other
// bases (matching js_number_toString). radix must be 2..36.
f64_to_radix :: proc(buf: []u8, d: f64, radix: int) -> int {
	exp_mode: Exp_Mode = radix == 10 ? .Auto : .Disabled
	return dtoa(raw_data(buf), d, radix, 0, .Free, exp_mode)
}

// Number.prototype.toFixed(f): fractional format with f digits after the dot, except |d| >= 1e21 which
// falls back to the free format (matching js_number_toFixed). f in 0..100.
f64_to_fixed :: proc(buf: []u8, d: f64, f: int) -> int {
	if abs(d) >= 1e21 {
		return dtoa(raw_data(buf), d, 10, f, .Free, .Auto)
	}
	return dtoa(raw_data(buf), d, 10, f, .Frac, .Auto)
}

// Number.prototype.toExponential(f): exactly f digits after the dot in exponential form. f in 0..100.
// When f is omitted (pass omit=true) QuickJS uses the free format with exponent enabled.
f64_to_exponential :: proc(buf: []u8, d: f64, f: int, omit := false) -> int {
	if omit {
		return dtoa(raw_data(buf), d, 10, 0, .Free, .Enabled)
	}
	return dtoa(raw_data(buf), d, 10, f + 1, .Fixed, .Enabled)
}

// Number.prototype.toPrecision(p): p significant digits, auto exponent. p in 1..100.
f64_to_precision :: proc(buf: []u8, d: f64, p: int) -> int {
	return dtoa(raw_data(buf), d, 10, p, .Fixed, .Auto)
}

// --- string -> float64 (parse) ---

// ECMAScript WhiteSpace + LineTerminator, over a UTF-8 string. Returns the byte count to skip.
// Matches QuickJS skip_spaces (lre_is_space): the ASCII controls, space, NBSP, BOM, the Unicode
// Space_Separator category and the line / paragraph separators.
@(private)
skip_spaces :: proc(s: string) -> int {
	b := transmute([]u8)s
	i := 0
	for i < len(b) {
		c := b[i]
		if c < 0x80 {
			if (c >= 0x09 && c <= 0x0d) || c == 0x20 {
				i += 1
				continue
			}
			break
		}
		r, w := decode_rune(b[i:])
		if !is_unicode_space(r) {
			break
		}
		i += w
	}
	return i
}

// A minimal UTF-8 decoder: enough for whitespace detection (we only need the code point, and malformed
// input yields U+FFFD, which is not a space, so it stops the scan). Avoids a core dependency so the
// package stays buildable on freestanding_wasm32.
@(private = "file")
decode_rune :: proc(b: []u8) -> (r: rune, size: int) {
	if len(b) == 0 {
		return 0xFFFD, 0
	}
	c := b[0]
	if c < 0x80 {
		return rune(c), 1
	} else if c < 0xC0 {
		return 0xFFFD, 1
	} else if c < 0xE0 {
		if len(b) < 2 || b[1] & 0xC0 != 0x80 {
			return 0xFFFD, 1
		}
		return rune(u32(c & 0x1F) << 6 | u32(b[1] & 0x3F)), 2
	} else if c < 0xF0 {
		if len(b) < 3 || b[1] & 0xC0 != 0x80 || b[2] & 0xC0 != 0x80 {
			return 0xFFFD, 1
		}
		return rune(u32(c & 0x0F) << 12 | u32(b[1] & 0x3F) << 6 | u32(b[2] & 0x3F)), 3
	} else if c < 0xF8 {
		if len(b) < 4 || b[1] & 0xC0 != 0x80 || b[2] & 0xC0 != 0x80 || b[3] & 0xC0 != 0x80 {
			return 0xFFFD, 1
		}
		return rune(u32(c & 0x07) << 18 | u32(b[1] & 0x3F) << 12 | u32(b[2] & 0x3F) << 6 | u32(b[3] & 0x3F)), 4
	}
	return 0xFFFD, 1
}

@(private = "file")
is_unicode_space :: proc(r: rune) -> bool {
	switch r {
	case 0x09 ..= 0x0D, 0x20, 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return false
}

// Number(str): ToNumber on a string. Leading and trailing whitespace are ignored; an all-whitespace
// (or empty) string is 0; anything the number grammar does not consume to the end is NaN. Accepts the
// 0x / 0o / 0b prefixes, like QuickJS (ATOD_ACCEPT_BIN_OCT).
parse_number :: proc(str: string) -> f64 {
	start := skip_spaces(str)
	s := str[start:]
	if len(s) == 0 {
		return 0
	}
	v, consumed, ok := atod(s, 0, {.Accept_Bin_Oct})
	if !ok {
		return nan()
	}
	// The rest must be only whitespace.
	rest := s[consumed:]
	if skip_spaces(rest) != len(rest) {
		return nan()
	}
	return v
}

// parseFloat(str): skip leading whitespace, parse the longest decimal prefix (float grammar, base 10,
// no 0x prefix), ignore trailing junk. Returns NaN when nothing parses.
parse_float :: proc(str: string) -> f64 {
	start := skip_spaces(str)
	s := str[start:]
	v, _, ok := atod(s, 10, {})
	if !ok {
		return nan()
	}
	return v
}

// parseInt(str, radix): skip whitespace, optional sign, optional 0x prefix (when radix is 0 or 16),
// integer only, base 2..36 (0 means auto: 16 after 0x, else 10), trailing junk ignored. radix outside
// {0} ∪ [2,36] yields NaN (the caller is expected to have range-checked, but we guard anyway).
parse_int :: proc(str: string, radix: int = 0) -> f64 {
	if radix != 0 && (radix < 2 || radix > 36) {
		return nan()
	}
	start := skip_spaces(str)
	s := str[start:]
	// ATOD_INT_ONLY | ATOD_ACCEPT_PREFIX_AFTER_SIGN: the 0x prefix is accepted even after a sign.
	// Our atod already handles the prefix after the sign, so Int_Only is all we need.
	v, _, ok := atod(s, radix, {.Int_Only})
	if !ok {
		return nan()
	}
	return v
}

@(private = "file")
nan :: #force_inline proc() -> f64 {
	return transmute(f64)u64(0x7ff8_0000_0000_0000)
}

// --- small integer fast paths (ToString on an integer-tagged Number) ---

// ToString of an i32 in base 10 (JS_TAG_INT path). buf >= 11 bytes.
i32_to_string :: proc(buf: []u8, n: i32) -> int {
	return i32toa(raw_data(buf), n)
}

// ToString of an integer in a radix 2..36 (Number.prototype.toString integer fast path). buf >= 65.
i64_to_string_radix :: proc(buf: []u8, n: i64, radix: int) -> int {
	return i64toa_radix(raw_data(buf), n, radix)
}
