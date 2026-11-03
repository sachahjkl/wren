package base

// Small text helpers the packages share: numbers as text, escaping for HTML and XML.

import "core:strconv"
import "core:strings"

// The decimal text of `n` (a negative one with its '-').
itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf: [len("-9223372036854775808")]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
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
