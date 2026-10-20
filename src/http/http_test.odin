package http

import "core:testing"

@(test)
mime_parsing :: proc(t: ^testing.T) {
	m, ok := parse_mime(`  Text/HTML ; Charset="utf-8" ; x=y;z=`, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, mime_essence(m), "text/html")
	cs, _ := mime_param(m, "charset")
	testing.expect_value(t, cs, "utf-8")
	_, has := mime_param(m, "z")
	testing.expect(t, !has, "empty parameter values are dropped")

	m, ok = parse_mime(`application/wasm`, context.temp_allocator)
	testing.expect(t, ok && is_wasm_mime(m))

	m, ok = parse_mime(`text/plain; charset="a\"b;c"; charset=other`, context.temp_allocator)
	testing.expect(t, ok)
	cs, _ = mime_param(m, "charset")
	testing.expect_value(t, cs, `a"b;c`)   // quoted-string unescaped, first duplicate wins

	bads := []string{"", "text", "/plain", "text/", "te xt/plain", "text/pl ain", "text/plain,"}
	for bad in bads {
		_, ok = parse_mime(bad, context.temp_allocator)
		testing.expect(t, !ok, bad)
	}
}

@(test)
mime_extraction_from_headers :: proc(t: ^testing.T) {
	h := parse_header_block("HTTP/1.1 200 OK\r\nContent-Type: text/html;charset=shift_jis\r\nContent-Type: text/html\r\nX: y\r\n", context.temp_allocator)
	m, ok := extract_mime(h, context.temp_allocator)
	testing.expect(t, ok)
	cs, has := mime_param(m, "charset")
	testing.expect(t, has)
	testing.expect_value(t, cs, "shift_jis")   // carried across values of the same essence

	h2 := parse_header_block("Content-Type: text/html;charset=a\r\nContent-Type: text/plain\r\n", context.temp_allocator)
	m, ok = extract_mime(h2, context.temp_allocator)
	_, has = mime_param(m, "charset")
	testing.expect(t, ok && !has && m.subtype == "plain", "a different essence resets the charset")

	h3 := parse_header_block("Content-Type: */*\r\n", context.temp_allocator)
	_, ok = extract_mime(h3, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
header_block_parsing :: proc(t: ^testing.T) {
	h := parse_header_block("HTTP/2 200\r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\nX-Folded: one\r\n  two\r\nBad Line\r\nEmpty:\r\nCache-Control:  no-store \r\n", context.temp_allocator)
	cookies := get_all(h, "SET-COOKIE")
	testing.expect_value(t, len(cookies), 2)
	v, _ := get_header(h, "x-folded")
	testing.expect_value(t, v, "one two")
	v, _ = get_header(h, "cache-control")
	testing.expect_value(t, v, "no-store")
	found: bool
	v, found = get_header(h, "empty")
	testing.expect(t, found && v == "")
	_, found = get_header(h, "bad line")
	testing.expect(t, !found)
}

@(test)
forbidden_and_safelisted :: proc(t: ^testing.T) {
	testing.expect(t, is_forbidden_request_header("Cookie"))
	testing.expect(t, is_forbidden_request_header("sec-fetch-mode"))
	testing.expect(t, is_forbidden_request_header("Proxy-Authorization"))
	testing.expect(t, !is_forbidden_request_header("X-Custom"))
	testing.expect(t, is_forbidden_request_header("X-HTTP-Method-Override", "GET, trace"), "a method override naming a forbidden method")
	testing.expect(t, !is_forbidden_request_header("X-HTTP-Method-Override", "PATCH"))
	testing.expect(t, is_forbidden_method("trace"))
	testing.expect(t, !is_forbidden_method("PATCH"))
	testing.expect_value(t, normalize_method("get", context.temp_allocator), "GET")
	testing.expect_value(t, normalize_method("patch", context.temp_allocator), "patch")   // PATCH is not normalised

	testing.expect(t, is_cors_safelisted_request_header("Accept", "*/*"))
	testing.expect(t, !is_cors_safelisted_request_header("Accept", "a\"b"))
	testing.expect(t, is_cors_safelisted_request_header("Content-Type", "text/plain; charset=utf-8"))
	testing.expect(t, !is_cors_safelisted_request_header("Content-Type", "application/json"))
	testing.expect(t, is_cors_safelisted_request_header("Range", "bytes=0-99"))
	testing.expect(t, !is_cors_safelisted_request_header("Range", "bytes=0-1,5-9"))
	testing.expect(t, !is_cors_safelisted_request_header("X-Custom", "1"))

	h := headers_make(context.temp_allocator)
	append_header(&h, "X-B", "1")
	append_header(&h, "Accept", "*/*")
	append_header(&h, "x-a", "2")
	append_header(&h, "X-B", "3")
	u := unsafe_request_header_names(h)
	testing.expect_value(t, len(u), 2)
	testing.expect_value(t, u[0], "x-a")   // sorted, lower-cased, deduplicated
	testing.expect_value(t, u[1], "x-b")
}

@(test)
header_validity :: proc(t: ^testing.T) {
	testing.expect(t, is_token("X-Custom_1"))
	testing.expect(t, !is_token("bad name"))
	testing.expect(t, !is_token(""))
	testing.expect(t, is_valid_header_value("a b"))
	testing.expect(t, !is_valid_header_value(" lead"))
	testing.expect(t, !is_valid_header_value("a\r\nInjected: 1"))
	testing.expect(t, !is_valid_header_value("a\x00b"))
}
