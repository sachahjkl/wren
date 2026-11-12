package base

// Small text helpers the packages share: numbers as text, ASCII case, the fields of the profile's text files, escaping for HTML and XML.

import "base:intrinsics"
import "core:fmt"
import "core:simd"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// The decimal text of `n` (a negative one with its '-').
itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf: [len("-9223372036854775808")]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}

// The value of a hexadecimal digit (a byte or a rune), or -1.
hex_value :: proc(c: $T) -> int where intrinsics.type_is_integer(T) {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}

// `key` (an origin, a storage key) as a file name of the profile: every byte outside [a-z0-9.-] as _XX.
write_file_stem :: proc(b: ^strings.Builder, key: string) {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(key) {
		c := key[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' {
			strings.write_byte(b, c)
		} else {
			strings.write_byte(b, '_'); strings.write_byte(b, HEX[c >> 4]); strings.write_byte(b, HEX[c & 15])
		}
	}
}

////////////////////////////////
// ASCII case: the web platform's "ASCII lowercase", "ASCII uppercase" and "ASCII case-insensitive" (HTML names and
// keywords, CSS identifiers, MIME types, header names, URL schemes, encoding labels). Only A-Z and a-z change: the Kelvin
// sign U+212A and the long s U+017F stay what they are, where strings.to_lower, to_upper and equal_fold fold by Unicode
// ("K" is 'k' to them). Those are for user text (the address bar's search, text-transform): the lint of test_all
// (src\tools\test_all\lint_unicode_case.odin) fails on a use that tools/unicode_case_allowed.txt does not list.

ascii_lower_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c }
ascii_upper_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c }

// `s` in ASCII lowercase: `s` itself when it has no uppercase ASCII letter (the usual case: no allocation), else a copy.
ascii_lower :: proc(s: string, allocator := context.temp_allocator) -> string {
	i := 0
	for i < len(s) && !(s[i] >= 'A' && s[i] <= 'Z') { i += 1 }
	if i == len(s) { return s }
	return ascii_lower_clone(s, allocator)
}

// `s` in ASCII lowercase, always a copy (one to keep, and free).
ascii_lower_clone :: proc(s: string, allocator := context.allocator) -> string {
	out := make([]u8, len(s), allocator)
	for c, k in transmute([]u8)s { out[k] = ascii_lower_byte(c) }
	return string(out)
}

// `s` in ASCII uppercase, a copy.
ascii_upper :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	for c, k in transmute([]u8)s { out[k] = ascii_upper_byte(c) }
	return string(out)
}

ascii_equal_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] && ascii_lower_byte(a[i]) != ascii_lower_byte(b[i]) { return false }
	}
	return true
}

ascii_has_prefix_fold :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && ascii_equal_fold(s[:len(prefix)], prefix)
}

ascii_has_suffix_fold :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && ascii_equal_fold(s[len(s) - len(suffix):], suffix)
}

// The first index of `needle` in `hay` compared ASCII case-insensitively, or -1.
ascii_index_fold :: proc "contextless" (hay, needle: string) -> int {
	if len(needle) > len(hay) { return -1 }
	for i in 0 ..= len(hay) - len(needle) {
		if ascii_equal_fold(hay[i:][:len(needle)], needle) { return i }
	}
	return -1
}

ascii_contains_fold :: proc "contextless" (hay, needle: string) -> bool { return ascii_index_fold(hay, needle) >= 0 }

////////////////////////////////
// JSON

// A JSON string literal of `s`: invalid UTF-8 becomes U+FFFD (the text must stay valid JSON whatever a page gave), and
// U+2028 and U+2029 are escaped (it is a JavaScript string literal too).
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	rest := s
	for len(rest) > 0 {
		r, n := utf8.decode_rune_in_string(rest)
		if r == utf8.RUNE_ERROR && n <= 1 {
			strings.write_string(b, "�")
			rest = rest[max(n, 1):]
			continue
		}
		rest = rest[n:]
		switch r {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case 0 ..< 0x20, 0x2028, 0x2029: fmt.sbprintf(b, "\\u%04x", int(r))
		case: strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

json_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_json_string(&b, s)
	return strings.to_string(b)
}

////////////////////////////////
// Fields of a line of a profile file (history.txt, session.txt, search engines, service workers): backslash, tab, line
// breaks and NUL escaped

field_escape :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\': strings.write_string(sb, "\\\\")
		case '\t': strings.write_string(sb, "\\t")
		case '\n': strings.write_string(sb, "\\n")
		case '\r': strings.write_string(sb, "\\r")
		case 0:    strings.write_string(sb, "\\0")
		case: strings.write_byte(sb, s[i])
		}
	}
}

field_escaped :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(0, len(s), allocator)
	field_escape(&sb, s)
	return strings.to_string(sb)
}

field_unescape :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '\\') < 0 { return strings.clone(s, allocator) }
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 >= len(s) { strings.write_byte(&sb, s[i]); continue }
		i += 1
		switch s[i] {
		case 't': strings.write_byte(&sb, '\t')
		case 'n': strings.write_byte(&sb, '\n')
		case 'r': strings.write_byte(&sb, '\r')
		case '0': strings.write_byte(&sb, 0)
		case: strings.write_byte(&sb, s[i])
		}
	}
	return strings.to_string(sb)
}

////////////////////////////////
// HTML and XML

// Text written into HTML or XML: & < > always as references, and what `also` adds. Byte by byte (UTF-8 is copied as it
// is), the runs between references in one write.

Escape :: enum u8 {
	Quote,   // " as &quot; (a double-quoted attribute value)
	Apos,    // ' as &#39; (a single-quoted one)
	Nbsp,    // U+00A0 as &nbsp; (the HTML serialization of a text node or an attribute)
}
Escapes :: bit_set[Escape; u8]

// Blocks of 16 bytes with none of the bytes to escape are skipped by one test (core:simd); a block with one goes byte by
// byte. A byte `also` does not ask for is compared as '&' instead, so the test is the same whatever `also` is.
write_escaped :: proc(b: ^strings.Builder, s: string, also: Escapes = {}) {
	amp: V16 = u8('&')
	lt: V16 = u8('<')
	gt: V16 = u8('>')
	q := u8('"') if .Quote in also else u8('&')
	a := u8('\'') if .Apos in also else u8('&')
	nb := u8(0xC2) if .Nbsp in also else u8('&')
	quote: V16 = q
	apos: V16 = a
	nbsp: V16 = nb
	p := raw_data(s)
	n := len(s)
	start := 0
	i := 0
	for i < n {
		if i + 16 <= n {
			v := intrinsics.unaligned_load((^V16)(&p[i]))
			hit := simd.lanes_eq(v, amp) | simd.lanes_eq(v, lt) | simd.lanes_eq(v, gt) | simd.lanes_eq(v, quote) | simd.lanes_eq(v, apos) | simd.lanes_eq(v, nbsp)
			if simd.reduce_or(hit) == 0 {
				i += 16
				continue
			}
		}
		// this block byte by byte (a no-break space may end one byte past it)
		stop := min(i + 16, n)
		for i < stop {
			rep := ""
			width := 1
			switch p[i] {
			case '&': rep = "&amp;"
			case '<': rep = "&lt;"
			case '>': rep = "&gt;"
			case '"': if .Quote in also { rep = "&quot;" }
			case '\'': if .Apos in also { rep = "&#39;" }
			case 0xC2: if .Nbsp in also && i + 1 < n && p[i + 1] == 0xA0 { rep, width = "&nbsp;", 2 }
			}
			if rep == "" {
				i += 1
				continue
			}
			strings.write_string(b, s[start:i])
			strings.write_string(b, rep)
			i += width
			start = i
		}
	}
	strings.write_string(b, s[start:])
}

@(private = "file") V16 :: #simd[16]u8

// write_escaped byte by byte: the reference utf8_scan_test.odin compares it with.
@(private)
write_escaped_scalar :: proc(b: ^strings.Builder, s: string, also: Escapes = {}) {
	start := 0
	for i := 0; i < len(s); i += 1 {
		rep := ""
		width := 1
		switch s[i] {
		case '&': rep = "&amp;"
		case '<': rep = "&lt;"
		case '>': rep = "&gt;"
		case '"': if .Quote in also { rep = "&quot;" }
		case '\'': if .Apos in also { rep = "&#39;" }
		case 0xC2: if .Nbsp in also && i + 1 < len(s) && s[i + 1] == 0xA0 { rep, width = "&nbsp;", 2 }
		}
		if rep == "" { continue }
		strings.write_string(b, s[start:i])
		strings.write_string(b, rep)
		i += width - 1
		start = i + 1
	}
	strings.write_string(b, s[start:])
}

escaped :: proc(s: string, also: Escapes = {}, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	write_escaped(&b, s, also)
	return strings.to_string(b)
}
