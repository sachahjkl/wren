package base

// Small text helpers the packages share: numbers as text, the fields of the profile's text files, escaping for HTML and XML.

import "base:intrinsics"
import "core:fmt"
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

write_escaped :: proc(b: ^strings.Builder, s: string, also: Escapes = {}) {
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
