// Package http: the vocabulary of the Fetch Standard that is not tied to any transport: header lists, header-name
// and value validity, forbidden and CORS-safelisted names, methods, MIME types.
package http

import "base:runtime"
import "core:strings"

Header :: struct {
	name:  string,   // as received / given (case preserved), owned
	value: string,   // owned
}

// An ordered list of headers. Names compare case-insensitively; duplicates are kept (Set-Cookie needs that).
Headers :: struct {
	list:      [dynamic]Header,
	allocator: runtime.Allocator,
}


headers_make :: proc(allocator := context.allocator) -> Headers {
	return Headers{list = make([dynamic]Header, allocator), allocator = allocator}
}

headers_destroy :: proc(h: ^Headers) {
	for e in h.list { delete(e.name, h.allocator); delete(e.value, h.allocator) }
	delete(h.list)
	h^ = {}
}

headers_clone :: proc(h: Headers, allocator := context.allocator) -> Headers {
	r := headers_make(allocator)
	for e in h.list { append_header(&r, e.name, e.value) }
	return r
}

append_header :: proc(h: ^Headers, name, value: string) {
	append(&h.list, Header{strings.clone(name, h.allocator), strings.clone(value, h.allocator)})
}

// Replaces every header called `name` by a single one.
set_header :: proc(h: ^Headers, name, value: string) {
	delete_header(h, name)
	append_header(h, name, value)
}

delete_header :: proc(h: ^Headers, name: string) {
	for i := len(h.list) - 1; i >= 0; i -= 1 {
		if strings.equal_fold(h.list[i].name, name) {
			delete(h.list[i].name, h.allocator); delete(h.list[i].value, h.allocator)
			ordered_remove(&h.list, i)
		}
	}
}

has_header :: proc(h: Headers, name: string) -> bool {
	for e in h.list { if strings.equal_fold(e.name, name) { return true } }
	return false
}

// "get": the values of all headers called `name` joined with ", " (Set-Cookie must use `get_all`).
get_header :: proc(h: Headers, name: string, allocator := context.temp_allocator) -> (value: string, found: bool) {
	sb := strings.builder_make(allocator)
	n := 0
	for e in h.list {
		if !strings.equal_fold(e.name, name) { continue }
		if n > 0 { strings.write_string(&sb, ", ") }
		strings.write_string(&sb, e.value)
		n += 1
	}
	return strings.to_string(sb), n > 0
}

get_all :: proc(h: Headers, name: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for e in h.list { if strings.equal_fold(e.name, name) { append(&out, e.value) } }
	return out[:]
}

// Parses a raw header block ("HTTP/1.1 200 OK\r\nName: value\r\n..."). The status line and malformed lines are skipped;
// obsolete line folding is joined into the previous value.
parse_header_block :: proc(raw: string, allocator := context.allocator) -> Headers {
	h := headers_make(allocator)
	text := raw
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first && strings.has_prefix(line, "HTTP/") { first = false; continue }
		first = false
		if line == "" { continue }
		if (line[0] == ' ' || line[0] == '\t') && len(h.list) > 0 {
			last := &h.list[len(h.list) - 1]
			joined := strings.concatenate({last.value, " ", strings.trim_space(line)}, h.allocator)
			delete(last.value, h.allocator)
			last.value = joined
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 { continue }
		name := line[:colon]
		if !is_token(name) { continue }
		append_header(&h, name, trim_http_whitespace(line[colon + 1:]))
	}
	return h
}

////////////////////////////////
// Validity

trim_http_whitespace :: proc(s: string) -> string {
	return strings.trim(s, "\t\n\r ")
}

is_token_char :: proc(c: u8) -> bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9': return true
	}
	return strings.contains_rune("!#$%&'*+-.^_`|~", rune(c))
}

is_token :: proc(s: string) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s { if !is_token_char(c) { return false } }
	return true
}

// A header value: no NUL, CR or LF, no leading/trailing whitespace.
is_valid_header_value :: proc(s: string) -> bool {
	if s == "" { return true }
	if s[0] == ' ' || s[0] == '\t' || s[len(s) - 1] == ' ' || s[len(s) - 1] == '\t' { return false }
	for c in transmute([]u8)s { if c == 0 || c == '\r' || c == '\n' { return false } }
	return true
}

normalize_method :: proc(m: string, allocator := context.allocator) -> string {
	switch {
	case strings.equal_fold(m, "delete"), strings.equal_fold(m, "get"), strings.equal_fold(m, "head"),
	     strings.equal_fold(m, "options"), strings.equal_fold(m, "post"), strings.equal_fold(m, "put"):
		return strings.to_upper(m, allocator)
	}
	return strings.clone(m, allocator)
}

is_forbidden_method :: proc(m: string) -> bool {
	return strings.equal_fold(m, "connect") || strings.equal_fold(m, "trace") || strings.equal_fold(m, "track")
}

is_safelisted_method :: proc(m: string) -> bool { return m == "GET" || m == "HEAD" || m == "POST" }

// Methods that carry no side effects (cookie SameSite=Lax decisions).
is_safe_method :: proc(m: string) -> bool { return m == "GET" || m == "HEAD" || m == "OPTIONS" || m == "TRACE" }

// Headers a script must not set: the browser owns them. With `value`: also the method-override headers naming a forbidden
// method (X-HTTP-Method-Override: TRACE), which some servers obey as the method (Fetch Standard).
is_forbidden_request_header :: proc(name: string, value := "") -> bool {
	if strings.equal_fold(name, "x-http-method") || strings.equal_fold(name, "x-http-method-override") || strings.equal_fold(name, "x-method-override") {
		for m in strings.split(value, ",", context.temp_allocator) { if is_forbidden_method(strings.trim(m, " \t")) { return true } }
	}
	switch {
	case len(name) >= 6 && strings.equal_fold(name[:6], "proxy-"), len(name) >= 4 && strings.equal_fold(name[:4], "sec-"): return true
	}
	names := [?]string{
		"accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
		"connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
		"referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via",
	}
	for n in names { if strings.equal_fold(name, n) { return true } }
	return false
}

is_forbidden_response_header :: proc(name: string) -> bool {
	return strings.equal_fold(name, "set-cookie") || strings.equal_fold(name, "set-cookie2")
}

// CORS-safelisted request header (name, value): the ones that never trigger a preflight.
is_cors_safelisted_request_header :: proc(name, value: string) -> bool {
	if len(value) > 128 { return false }
	switch {
	case strings.equal_fold(name, "accept"):
		return !has_unsafe_byte(value)
	case strings.equal_fold(name, "accept-language"), strings.equal_fold(name, "content-language"):
		for c in transmute([]u8)value {
			ok := (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == ' ' || c == '*' || c == ',' || c == '-' || c == '.' || c == ';' || c == '=' 
			if !ok { return false }
		}
		return true
	case strings.equal_fold(name, "content-type"):
		if has_unsafe_byte(value) { return false }
		m, ok := parse_mime(value, context.temp_allocator)
		if !ok { return false }
		e := mime_essence(m)
		return e == "application/x-www-form-urlencoded" || e == "multipart/form-data" || e == "text/plain"
	case strings.equal_fold(name, "range"):
		// "bytes=" followed by a single start-end range, per the Fetch spec
		if !strings.has_prefix(value, "bytes=") { return false }
		r := value[6:]
		dash := strings.index_byte(r, '-')
		if dash <= 0 { return false }
		for c in transmute([]u8)r[:dash] { if c < '0' || c > '9' { return false } }
		for c in transmute([]u8)r[dash + 1:] { if c < '0' || c > '9' { return false } }
		return true
	}
	return false
}

@(private)
has_unsafe_byte :: proc(v: string) -> bool {
	for c in transmute([]u8)v {
		if (c < 0x20 && c != 0x09) || c == 0x22 || c == 0x28 || c == 0x29 || c == 0x3A || c == 0x3C || c == 0x3E || c == 0x3F ||
		   c == 0x40 || c == 0x5B || c == 0x5C || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x7F { return true }
	}
	return false
}

is_cors_safelisted_response_header :: proc(name: string) -> bool {
	names := [?]string{"cache-control", "content-language", "content-length", "content-type", "expires", "last-modified", "pragma"}
	for n in names { if strings.equal_fold(name, n) { return true } }
	return false
}

// Request headers that make a cross-origin request need a preflight: everything not safelisted, plus names listed for
// the unsafe set (returns them lower-cased, sorted, deduplicated, comma separated).
unsafe_request_header_names :: proc(h: Headers, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for e in h.list {
		if is_cors_safelisted_request_header(e.name, e.value) { continue }
		lname := strings.to_lower(e.name, allocator)
		dup := false
		for o in out { if o == lname { dup = true; break } }
		if !dup { append(&out, lname) }
	}
	// byte-lexicographic order, as the specification requires
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && out[j - 1] > out[j] { out[j - 1], out[j] = out[j], out[j - 1]; j -= 1 }
	}
	return out[:]
}
