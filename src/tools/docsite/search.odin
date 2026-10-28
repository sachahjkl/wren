// The full-text search index: a compact JSON array the client loads once. Each entry is a page with its URL, title,
// section and the plain text of its body (markup stripped by the Markdown renderer). The client scores a query
// against these fields; no server, no external request. The body text is truncated so the index stays small — long
// pages (the canvas API is thousands of lines) do not need every word to be findable, only a representative start.
package docsite

import "core:strings"

Search_Doc :: struct {
	url:     string,
	title:   string,
	section: string,
	text:    string,
}

// A hard cap on the indexed body of one page, in bytes, so the whole index stays a small download.
MAX_BODY :: 1400

build_search_index :: proc(docs: []Search_Doc) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for d, i in docs {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_byte(&b, '{')
		json_field(&b, "u", d.url, true)
		json_field(&b, "t", d.title, false)
		json_field(&b, "s", d.section, false)
		json_field(&b, "b", truncate_bytes(d.text, MAX_BODY), false)
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

json_field :: proc(b: ^strings.Builder, key, value: string, first: bool) {
	if !first { strings.write_byte(b, ',') }
	strings.write_byte(b, '"')
	strings.write_string(b, key)
	strings.write_string(b, "\":")
	json_string(b, value)
}

json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r':
		case '\t': strings.write_byte(b, ' ')
		case:
			if c < 0x20 { continue }
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// Truncate to at most n bytes without splitting a UTF-8 sequence, ending on a word boundary when possible.
truncate_bytes :: proc(s: string, n: int) -> string {
	if len(s) <= n { return s }
	cut := n
	for cut > 0 && (s[cut] & 0xC0) == 0x80 { cut -= 1 } // back off into a lead byte
	// prefer to end at the last space before the cut
	if sp := strings.last_index_byte(s[:cut], ' '); sp > n - 40 { cut = sp }
	return s[:cut]
}
