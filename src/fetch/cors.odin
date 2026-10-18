package fetch

import "core:strconv"
import "core:strings"
import "wb:http"
import "wb:url"

// The response-side checks of the CORS protocol (Fetch Standard §3.2.5 "CORS check").
//
// `origin` is the request's origin (an opaque origin serialises to "null"). `credentials_include` is whether the
// request's credentials mode is "include".
cors_check :: proc(origin: url.Origin, credentials_include: bool, h: http.Headers) -> (ok: bool, reason: string) {
	values := http.get_all(h, "access-control-allow-origin")
	if len(values) == 0 { return false, "no Access-Control-Allow-Origin header" }
	if len(values) > 1 { return false, "multiple Access-Control-Allow-Origin headers" }
	v := values[0]
	if v == "*" && !credentials_include { return true, "" }
	serialized := url.origin_serialize(origin, context.temp_allocator)
	if v != serialized {
		if v == "*" { return false, "wildcard Access-Control-Allow-Origin is not allowed with credentials" }
		return false, "Access-Control-Allow-Origin does not match the request origin"
	}
	if credentials_include {
		c := http.get_all(h, "access-control-allow-credentials")
		if len(c) != 1 || c[0] != "true" { return false, "credentials mode is include but Access-Control-Allow-Credentials is not true" }
	}
	return true, ""
}

// A comma separated header list into trimmed, non-empty tokens.
split_header_list :: proc(value: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for part in strings.split(value, ",", allocator) {
		t := http.trim_http_whitespace(part)
		if t != "" { append(&out, t) }
	}
	return out[:]
}

Preflight_Verdict :: struct {
	ok:        bool,
	reason:    string,
	methods:   []string,
	headers:   []string,   // lower-cased
	max_age_s: int,
}

// Validates the answer to an OPTIONS preflight for (method, unsafe header names).
check_preflight_response :: proc(origin: url.Origin, credentials_include: bool, status: int, h: http.Headers, method: string, unsafe_headers: []string) -> Preflight_Verdict {
	v: Preflight_Verdict
	if ok, why := cors_check(origin, credentials_include, h); !ok { v.reason = why; return v }
	if status < 200 || status > 299 { v.reason = "preflight response is not ok"; return v }

	methods: []string
	if raw, found := http.get_header(h, "access-control-allow-methods"); found { methods = split_header_list(raw) }
	hdrs := make([dynamic]string, context.temp_allocator)
	if raw, found := http.get_header(h, "access-control-allow-headers"); found {
		for t in split_header_list(raw) { append(&hdrs, strings.to_lower(t, context.temp_allocator)) }
	}
	v.methods, v.headers = methods, hdrs[:]

	method_ok := http.is_safelisted_method(method)
	for m in methods {
		if m == method { method_ok = true }
		if m == "*" && !credentials_include { method_ok = true }
	}
	if !method_ok { v.reason = "method is not allowed by Access-Control-Allow-Methods"; return v }

	for name in unsafe_headers {
		found := false
		for a in hdrs {
			if a == name { found = true; break }
			// "*" covers everything except Authorization, and only without credentials
			if a == "*" && !credentials_include && name != "authorization" { found = true; break }
		}
		if !found { v.reason = "header is not allowed by Access-Control-Allow-Headers"; return v }
	}

	v.max_age_s = DEFAULT_PREFLIGHT_AGE_S
	if raw, found := http.get_header(h, "access-control-max-age"); found {
		if n, ok := strconv.parse_int(strings.trim_space(raw), 10); ok { v.max_age_s = max(n, 0) }
	}
	v.ok = true
	return v
}

// The CORS-filtered header list a cross-origin response exposes to script.
filter_cors_response_headers :: proc(h: http.Headers, credentials_include: bool, allocator := context.allocator) -> http.Headers {
	out := http.headers_make(allocator)
	exposed := make([dynamic]string, context.temp_allocator)
	if raw, found := http.get_header(h, "access-control-expose-headers"); found {
		for t in split_header_list(raw) { append(&exposed, strings.to_lower(t, context.temp_allocator)) }
	}
	star := false
	for e in exposed { if e == "*" { star = true } }
	for e in h.list {
		if http.is_forbidden_response_header(e.name) { continue }
		visible := http.is_cors_safelisted_response_header(e.name)
		lname := strings.to_lower(e.name, context.temp_allocator)
		for x in exposed { if x == lname { visible = true } }
		if star && !credentials_include { visible = true }
		if visible { http.append_header(&out, e.name, e.value) }
	}
	return out
}

// The same-origin ("basic") filtered list: everything but Set-Cookie / Set-Cookie2.
filter_basic_response_headers :: proc(h: http.Headers, allocator := context.allocator) -> http.Headers {
	out := http.headers_make(allocator)
	for e in h.list { if !http.is_forbidden_response_header(e.name) { http.append_header(&out, e.name, e.value) } }
	return out
}
