// web_fetch.odin: the Fetch API (Fetch Standard): Headers, Request, Response, their Body mixin, and fetch(). Ported
// from native/js/runtime/web_fetch.c: same wjr_* / web_headers_* / web_* symbols and behaviour.
//
//   * Headers live in the engine (a list of lower-cased names and values, with the guard of the object that owns it:
//     forbidden request headers are dropped, immutable headers throw).
//   * A body is one of: nothing, bytes in the engine (constructed objects), the browser's response record (a network
//     response: read in one copy by arrayBuffer() / text()..., or chunk by chunk through `body`), or a ReadableStream.
//   * fetch() builds a Request (the same steps as new Request()), resolves blob: URLs of this realm itself, and hands
//     everything else to the browser (module fetch: Fetch_promise), which applies the page's policy (CORS, cookies,
//     referrer, CSP, mixed content). The promise is fulfilled with a Response when the headers arrive; a network error
//     rejects it with a TypeError, an abort with the signal's reason (also for body reads afterwards).
// Request.cache goes to the browser's HTTP cache. Not supported: integrity (not checked), keepalive (a request does not
// outlive its page), a referrer URL (only "" and the default), request bodies streamed while sent (a ReadableStream body
// is read whole first).
//
// Every host call goes through its declaration (api_decl/fetch.odin) and jsb; what is written here is behaviour.
package odin_glue

import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// ---- Headers ----

// web.h WEB_GUARD_*
Guard :: enum i32 { None, Request, Request_No_Cors, Response, Immutable }

@(private = "file")
Header :: struct {
	name, value: string,   // owned; the name lower-cased
}

@(private = "file")
Header_List :: struct {
	list:  [dynamic]Header,
	guard: Guard,
}

@(private = "file")
headers_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	h := (^Header_List)(p)
	for e in h.list { delete(e.name); delete(e.value) }
	delete(h.list)
	free(h)
}

@(private = "file")
headers_of :: proc "contextless" (v: wj.JSValue) -> ^Header_List {
	return (^Header_List)(wj.impl_of(wj.wj_unwrap(v, net_iface(.Headers))))
}

@(private = "file")
is_token_char :: proc "contextless" (c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

// An HTTP token (a header name, a method).
valid_token :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 { return false }
	for i in 0 ..< len(s) { if !is_token_char(s[i]) { return false } }
	return true
}

@(private = "file")
http_ws :: #force_inline proc "contextless" (c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// Leading / trailing HTTP whitespace removed.
http_trim :: proc "contextless" (s: string) -> string {
	a, b := 0, len(s)
	for a < b && http_ws(s[a]) { a += 1 }
	for b > a && http_ws(s[b - 1]) { b -= 1 }
	return s[a:b]
}

// A normalized header value: false when it holds NUL, CR or LF.
@(private = "file")
normalize_value :: proc "contextless" (s: string) -> (string, bool) {
	v := http_trim(s)
	for i in 0 ..< len(v) {
		if c := v[i]; c == 0 || c == '\r' || c == '\n' { return v, false }
	}
	return v, true
}

@(private = "file")
is_method_override :: proc "contextless" (name: string) -> bool {
	return wj.ascii_ieq(name, "x-http-method") || wj.ascii_ieq(name, "x-http-method-override") || wj.ascii_ieq(name, "x-method-override")
}

@(private = "file")
forbidden_method :: proc "contextless" (m: string) -> bool {
	return wj.ascii_ieq(m, "connect") || wj.ascii_ieq(m, "trace") || wj.ascii_ieq(m, "track")
}

// Fetch "forbidden request-header"
forbidden_request_header :: proc "contextless" (name, value: string) -> bool {
	@(static) names := [?]string{
		"accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
		"connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
		"referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via",
	}
	for n in names { if wj.ascii_ieq(name, n) { return true } }
	if len(name) >= 6 && wj.ascii_ieq(name[:6], "proxy-") { return true }
	if len(name) >= 4 && wj.ascii_ieq(name[:4], "sec-") { return true }
	if is_method_override(name) {
		// a method override naming a forbidden method
		rest := value
		for {
			comma := 0
			for comma < len(rest) && rest[comma] != ',' { comma += 1 }
			if forbidden_method(http_trim(rest[:comma])) { return true }
			if comma >= len(rest) { break }
			rest = rest[comma + 1:]
		}
	}
	return false
}

@(export, link_name = "web_forbidden_request_header")
web_forbidden_request_header :: proc "c" (name: [^]u8, n: uint, value: [^]u8, vn: uint) -> bool {
	return forbidden_request_header(bytes_view(name, n), bytes_view(value, vn))
}

@(private = "file")
bytes_view :: #force_inline proc "contextless" (p: [^]u8, n: uint) -> string {
	return p != nil ? string(p[:n]) : ""
}

// Fetch "no-CORS-safelisted request-header" (simplified to the names and the Content-Type check)
@(private = "file")
no_cors_safelisted :: proc "contextless" (name, value: string) -> bool {
	if len(value) > 128 { return false }
	if wj.ascii_ieq(name, "accept") || wj.ascii_ieq(name, "accept-language") || wj.ascii_ieq(name, "content-language") { return true }
	if wj.ascii_ieq(name, "content-type") {
		e := 0
		for e < len(value) && value[e] != ';' { e += 1 }
		for e > 0 && http_ws(value[e - 1]) { e -= 1 }
		essence := value[:e]
		return wj.ascii_ieq(essence, "application/x-www-form-urlencoded") || wj.ascii_ieq(essence, "multipart/form-data") || wj.ascii_ieq(essence, "text/plain")
	}
	return false
}

@(private = "file")
is_set_cookie :: proc "contextless" (name: string) -> bool {
	return wj.ascii_ieq(name, "set-cookie") || wj.ascii_ieq(name, "set-cookie2")
}

// A copy of `s` (heap allocator), lower-cased when `lower`.
clone_string :: proc(s: string, lower := false) -> (string, bool) {
	if len(s) == 0 { return "", true }
	b, err := make([]u8, len(s))
	if err != nil { return "", false }
	copy(b, s)
	if lower { for &c in b { if c >= 'A' && c <= 'Z' { c += 32 } } }
	return string(b), true
}

clone_bytes :: proc(p: []u8) -> ([]u8, bool) {
	if len(p) == 0 { return nil, true }
	b, err := make([]u8, len(p))
	if err != nil { return nil, false }
	copy(b, p)
	return b, true
}

@(private = "file")
headers_push :: proc(h: ^Header_List, name, value: string) -> bool {
	n, ok1 := clone_string(name, true)
	v, ok2 := clone_string(value)
	if !ok1 || !ok2 { delete(n); delete(v); return false }
	if _, err := append(&h.list, Header{n, v}); err != nil { delete(n); delete(v); return false }
	return true
}

@(private = "file")
headers_remove :: proc(h: ^Header_List, name: string) {
	w := 0
	for e in h.list {
		if wj.ascii_ieq(name, e.name) { delete(e.name); delete(e.value); continue }
		h.list[w] = e
		w += 1
	}
	resize(&h.list, w)
}

@(private = "file")
headers_contains :: proc "contextless" (h: ^Header_List, name: string) -> bool {
	for e in h.list { if wj.ascii_ieq(name, e.name) { return true } }
	return false
}

// append with Fetch's checks: 1 appended, 0 ignored by the guard, -1 TypeError pending
@(private = "file")
headers_append_checked :: proc(ctx: ^wj.Context, h: ^Header_List, name, value_in: string) -> int {
	value, ok := normalize_value(value_in)
	if !ok { wj.JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'Headers': Invalid value"); return -1 }
	if !valid_token(name) { wj.JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'Headers': Invalid name"); return -1 }
	switch h.guard {
	case .Immutable:
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'Headers': Headers are immutable")
		return -1
	case .Request:
		if forbidden_request_header(name, value) { return 0 }
	case .Request_No_Cors:
		// the combined value must stay safelisted
		old := 0
		for e in h.list { if wj.ascii_ieq(name, e.name) { old += len(e.value) + 2 } }
		if old + len(value) > 128 || !no_cors_safelisted(name, value) { return 0 }
	case .Response:
		if is_set_cookie(name) { return 0 }
	case .None:
	}
	if !headers_push(h, name, value) { wj.JS_ThrowOutOfMemory(ctx); return -1 }
	return 1
}

@(export, link_name = "web_headers_new")
web_headers_new :: proc "c" (ctx: ^wj.Context, guard: Guard) -> wj.JSValue {
	context = wj.heap_context()
	h := new(Header_List)
	if h == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	h.guard = guard
	obj := wj.wj_new_object(ctx, net_iface(.Headers), nil, nil)
	if wj.is_exception(obj) { free(h); return obj }
	wj.web_set_impl(obj, h, headers_free, nil)
	return obj
}

@(export, link_name = "web_headers_append_raw")
web_headers_append_raw :: proc "c" (headers: wj.JSValue, name: [^]u8, nlen: uint, value: [^]u8, vlen: uint) -> bool {
	context = wj.heap_context()
	h := headers_of(headers)
	return h != nil && headers_push(h, bytes_view(name, nlen), bytes_view(value, vlen))
}

@(export, link_name = "web_headers_append_checked")
web_headers_append_checked :: proc "c" (ctx: ^wj.Context, headers: wj.JSValue, name: [^]u8, nlen: uint, value: [^]u8, vlen: uint) -> bool {
	context = wj.heap_context()
	h := headers_of(headers)
	if h == nil { wj.JS_ThrowTypeError(ctx, "not a Headers object"); return false }
	return headers_append_checked(ctx, h, bytes_view(name, nlen), bytes_view(value, vlen)) >= 0
}

// "Name: value" lines (CR LF or LF) appended as they are (a response's headers).
@(private = "file")
headers_fill_lines :: proc(h: ^Header_List, text: string) {
	rest := text
	for len(rest) > 0 {
		e := 0
		for e < len(rest) && rest[e] != '\n' { e += 1 }
		line := rest[:e]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		for c, k in transmute([]u8)line {
			if c != ':' { continue }
			if k > 0 {
				v, _ := normalize_value(line[k + 1:])
				headers_push(h, line[:k], v)
			}
			break
		}
		rest = e < len(rest) ? rest[e + 1:] : ""
	}
}

@(export, link_name = "web_headers_fill_lines")
web_headers_fill_lines :: proc "c" (ctx: ^wj.Context, headers: wj.JSValue, text: [^]u8, n: uint) {
	context = wj.heap_context()
	if h := headers_of(headers); h != nil { headers_fill_lines(h, bytes_view(text, n)) }
}

// The list as "name: value\r\n" lines.
@(private = "file")
headers_serialize :: proc(h: ^Header_List, out: ^[dynamic]u8) {
	if h == nil { return }
	for e in h.list {
		append(out, e.name)
		append(out, ": ")
		append(out, e.value)
		append(out, "\r\n")
	}
}

@(export, link_name = "web_headers_serialize")
web_headers_serialize :: proc "c" (headers: wj.JSValue, out: ^wj.Web_Buf) {
	h := headers_of(headers)
	if h == nil { return }
	for e in h.list {
		wj.web_buf_put(out, raw_data(e.name), uint(len(e.name)))
		wj.web_buf_put(out, raw_data(string(": ")), 2)
		wj.web_buf_put(out, raw_data(e.value), uint(len(e.value)))
		wj.web_buf_put(out, raw_data(string("\r\n")), 2)
	}
}

// The combined value (", " between values) into `out`: false when no header has the name.
@(private = "file")
headers_combined :: proc(h: ^Header_List, name: string, out: ^[dynamic]u8) -> bool {
	found := false
	for e in h.list {
		if !wj.ascii_ieq(name, e.name) { continue }
		if found { append(out, ", ") }
		append(out, e.value)
		found = true
	}
	return found
}

// The combined value of a Headers object's `name` (heap allocator; the caller deletes it), false when absent.
header_value :: proc(headers: wj.JSValue, name: string) -> (string, bool) {
	h := headers_of(headers)
	if h == nil { return "", false }
	b: [dynamic]u8
	if !headers_combined(h, name, &b) { delete(b); return "", false }
	return string(b[:]), true
}

// The combined value, NUL-terminated on the C heap (the C that calls this frees it with free()), nil when absent.
@(export, link_name = "web_headers_get")
web_headers_get :: proc "c" (headers: wj.JSValue, name: cstring, length: ^uint) -> [^]u8 {
	context = wj.heap_context()
	v, ok := header_value(headers, string(name))
	if !ok { return nil }
	defer delete(v)
	if length != nil { length^ = uint(len(v)) }
	return wj.heap_strndup(v)
}

@(export, link_name = "web_headers_has")
web_headers_has :: proc "c" (headers: wj.JSValue, name: cstring) -> bool {
	h := headers_of(headers)
	return h != nil && headers_contains(h, string(name))
}

// Fetch "sort and combine": the names in order, the values of one name combined, each Set-Cookie on its own.
@(private = "file")
Pair :: struct {
	name:  string,         // borrowed from the list
	value: [dynamic]u8,
}

@(private = "file")
sort_and_combine :: proc(h: ^Header_List) -> [dynamic]Pair {
	pairs: [dynamic]Pair
	if h == nil || len(h.list) == 0 { return pairs }
	order := make([]int, len(h.list))
	defer delete(order)
	// a stable insertion sort by name (the lists are short)
	for i in 0 ..< len(order) {
		order[i] = i
		for j := i; j > 0 && h.list[order[j]].name < h.list[order[j - 1]].name; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	for i := 0; i < len(order); {
		name := h.list[order[i]].name
		p := Pair{name = name}
		if name == "set-cookie" {
			append(&p.value, h.list[order[i]].value)
			append(&pairs, p)
			i += 1
			continue
		}
		j := i
		for ; j < len(order) && h.list[order[j]].name == name; j += 1 {
			if j > i { append(&p.value, ", ") }
			append(&p.value, h.list[order[j]].value)
		}
		append(&pairs, p)
		i = j
	}
	return pairs
}

@(private = "file")
pairs_delete :: proc(pairs: ^[dynamic]Pair) {
	for p in pairs { delete(p.value) }
	delete(pairs^)
}

@(export, link_name = "web_headers_sorted")
web_headers_sorted :: proc "c" (ctx: ^wj.Context, headers: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	arr := wj.JS_NewArray(ctx)
	pairs := sort_and_combine(headers_of(headers))
	defer pairs_delete(&pairs)
	for p, k in pairs {
		pair := wj.JS_NewArray(ctx)
		wj.array_set(ctx, pair, 0, wj.new_string_len(ctx, p.name))
		wj.array_set(ctx, pair, 1, wj.new_string_len(ctx, p.value[:]))
		wj.array_set(ctx, arr, u32(k), pair)
	}
	return arr
}

// fill from a HeadersInit: a sequence of pairs, a record, or another Headers
@(private = "file")
hfill_append :: proc(ctx: ^wj.Context, h: ^Header_List, name_v, value_v: wj.JSValue) -> bool {
	n, v: wj.Str
	if !wj.web_to_bytestring(ctx, name_v, &n) { return false }
	defer wj.wj_str_free(ctx, &n)
	if !wj.web_to_bytestring(ctx, value_v, &v) { return false }
	defer wj.wj_str_free(ctx, &v)
	return headers_append_checked(ctx, h, wj.str_view(n), wj.str_view(v)) >= 0
}

@(private = "file")
Pair_Collect :: struct {
	items: [2]wj.JSValue,
	n:     int,
}

@(private = "file")
pair_collect :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	pc := (^Pair_Collect)(opaque)
	if pc.n < 2 { pc.items[pc.n] = wj.JS_DupValue(ctx, item) }
	pc.n += 1
	return true
}

@(private = "file")
hfill_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	context = wj.heap_context()
	if !wj.is_object(item) {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Headers': The provided value cannot be converted to a sequence.")
		return false
	}
	pc := Pair_Collect{items = {wj.UNDEFINED, wj.UNDEFINED}}
	defer wj.free_values(ctx, pc.items[0], pc.items[1])
	if !wj.web_for_of(ctx, item, pair_collect, &pc) { return false }
	if pc.n != 2 { wj.JS_ThrowTypeError(ctx, "Failed to construct 'Headers': Invalid value"); return false }
	return hfill_append(ctx, (^Header_List)(opaque), pc.items[0], pc.items[1])
}

@(private = "file")
hfill_record :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	context = wj.heap_context()
	return hfill_append(ctx, (^Header_List)(opaque), key, value)
}

@(private = "file")
headers_fill :: proc(ctx: ^wj.Context, h: ^Header_List, init: wj.JSValue) -> bool {
	if wj.is_undefined(init) { return true }
	if !wj.is_object(init) {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Headers': The provided value is not of type '(record<ByteString, ByteString> or sequence<sequence<ByteString>>)'.")
		return false
	}
	if src := headers_of(init); src != nil {
		// a Headers: its list as is (iteration would combine the values)
		for i := 0; i < len(src.list); i += 1 {
			e := src.list[i]
			if headers_append_checked(ctx, h, e.name, e.value) < 0 { return false }
		}
		return true
	}
	it := wj.web_is_iterable(ctx, init)
	if it < 0 { return false }
	return it != 0 ? wj.web_for_of(ctx, init, hfill_item, h) : wj.web_for_record(ctx, init, hfill_record, h)
}

// A copy of a list into a new Headers object with the same guard.
@(private = "file")
headers_copy :: proc(ctx: ^wj.Context, src: ^Header_List, guard: Guard) -> wj.JSValue {
	obj := web_headers_new(ctx, guard)
	if wj.is_exception(obj) || src == nil { return obj }
	dst := headers_of(obj)
	for e in src.list { headers_push(dst, e.name, e.value) }
	return obj
}

@(export, link_name = "wjr_Headers_constructor")
wjr_Headers_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor Headers requires 'new'") }
	h := new(Header_List)
	if h == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	obj := wj.wj_new_object_for(ctx, net_iface(.Headers), new_target, nil, nil)
	if wj.is_exception(obj) { free(h); return obj }
	wj.web_set_impl(obj, h, headers_free, nil)
	if !headers_fill(ctx, h, wj.arg(argc, argv, 0)) { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

@(private = "file")
headers_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Header_List {
	return (^Header_List)(wj.web_this_impl(ctx, this_val, net_iface(.Headers)))
}

@(export, link_name = "wjr_Headers_append")
wjr_Headers_append :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	h := headers_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Headers.append", 2, argc) }
	return hfill_append(ctx, h, argv[0], argv[1]) ? wj.UNDEFINED : wj.EXCEPTION
}

// The name argument of a Headers member, a valid header name: ok false with a TypeError pending.
@(private = "file")
name_arg :: proc(ctx: ^wj.Context, v: wj.JSValue, member: cstring, n: ^wj.Str) -> bool {
	if !wj.web_to_bytestring(ctx, v, n) { return false }
	if !valid_token(wj.str_view(n^)) {
		wj.wj_str_free(ctx, n)
		wj.JS_ThrowTypeError(ctx, "Failed to execute '%s' on 'Headers': Invalid name", member)
		return false
	}
	return true
}

@(export, link_name = "wjr_Headers_delete")
wjr_Headers_delete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	h := headers_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Headers.delete", 1, argc) }
	ns: wj.Str
	if !name_arg(ctx, argv[0], "delete", &ns) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	n := wj.str_view(ns)
	switch h.guard {
	case .Immutable:
		return wj.wj_throw_type(ctx, "Failed to execute 'delete' on 'Headers': Headers are immutable")
	case .Request:
		if forbidden_request_header(n, "") { return wj.UNDEFINED }
	case .Request_No_Cors:
		if !no_cors_safelisted(n, "text/plain") && !wj.ascii_ieq(n, "content-type") { return wj.UNDEFINED }
	case .Response:
		if is_set_cookie(n) { return wj.UNDEFINED }
	case .None:
	}
	headers_remove(h, n)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Headers_get")
wjr_Headers_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	h := headers_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Headers.get", 1, argc) }
	ns: wj.Str
	if !name_arg(ctx, argv[0], "get", &ns) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	b: [dynamic]u8
	defer delete(b)
	if !headers_combined(h, wj.str_view(ns), &b) { return wj.NULL }
	return wj.new_string_len(ctx, b[:])
}

@(export, link_name = "wjr_Headers_getSetCookie")
wjr_Headers_getSetCookie :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := headers_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	arr := wj.JS_NewArray(ctx)
	k: u32
	for e in h.list {
		if e.name == "set-cookie" { wj.array_set(ctx, arr, k, wj.new_string_len(ctx, e.value)); k += 1 }
	}
	return arr
}

@(export, link_name = "wjr_Headers_has")
wjr_Headers_has :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	h := headers_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Headers.has", 1, argc) }
	ns: wj.Str
	if !name_arg(ctx, argv[0], "has", &ns) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	return wj.new_bool(headers_contains(h, wj.str_view(ns)))
}

@(export, link_name = "wjr_Headers_set")
wjr_Headers_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	h := headers_this(ctx, this_val)
	if h == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "Headers.set", 2, argc) }
	ns, vs: wj.Str
	if !wj.web_to_bytestring(ctx, argv[0], &ns) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &ns)
	if !wj.web_to_bytestring(ctx, argv[1], &vs) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &vs)
	n := wj.str_view(ns)
	v, ok := normalize_value(wj.str_view(vs))
	if !ok { return wj.wj_throw_type(ctx, "Failed to execute 'set' on 'Headers': Invalid value") }
	if !valid_token(n) { return wj.wj_throw_type(ctx, "Failed to execute 'set' on 'Headers': Invalid name") }
	switch h.guard {
	case .Immutable:
		return wj.wj_throw_type(ctx, "Failed to execute 'set' on 'Headers': Headers are immutable")
	case .Request:
		if forbidden_request_header(n, v) { return wj.UNDEFINED }
	case .Request_No_Cors:
		if !no_cors_safelisted(n, v) { return wj.UNDEFINED }
	case .Response:
		if is_set_cookie(n) { return wj.UNDEFINED }
	case .None:
	}
	// the first one takes the value, the others go
	done := false
	w := 0
	for e in h.list {
		entry := e
		if wj.ascii_ieq(n, e.name) {
			if done { delete(e.name); delete(e.value); continue }
			if nv, cloned := clone_string(v); cloned { delete(e.value); entry.value = nv }
			done = true
		}
		h.list[w] = entry
		w += 1
	}
	resize(&h.list, w)
	if !done && !headers_push(h, n, v) { return wj.JS_ThrowOutOfMemory(ctx) }
	return wj.UNDEFINED
}

@(private = "file")
headers_at :: proc "c" (ctx: ^wj.Context, owner: wj.JSValue, index: u32, key: ^wj.JSValue, value: ^wj.JSValue) -> i32 {
	context = wj.heap_context()
	pairs := sort_and_combine(headers_of(owner))
	defer pairs_delete(&pairs)
	if int(index) >= len(pairs) { return 0 }
	key^ = wj.new_string_len(ctx, pairs[index].name)
	value^ = wj.new_string_len(ctx, pairs[index].value[:])
	return 1
}

@(private = "file")
headers_iter :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, kind: i32) -> wj.JSValue {
	if headers_this(ctx, this_val) == nil { return wj.EXCEPTION }
	return wj.web_iterator_new(ctx, wj.ITERABLE_HEADERS, this_val, kind, headers_at)
}

@(export, link_name = "wjr_Headers_entries")
wjr_Headers_entries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return headers_iter(ctx, this_val, wj.ITER_ENTRIES) }
@(export, link_name = "wjr_Headers_keys")
wjr_Headers_keys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return headers_iter(ctx, this_val, wj.ITER_KEYS) }
@(export, link_name = "wjr_Headers_values")
wjr_Headers_values :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return headers_iter(ctx, this_val, wj.ITER_VALUES) }

@(export, link_name = "wjr_Headers_forEach")
wjr_Headers_forEach :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if headers_this(ctx, this_val) == nil { return wj.EXCEPTION }
	return wj.web_for_each(ctx, this_val, argc, argv, headers_at)
}

// ---- statuses, URLs ----

status_text :: proc "contextless" (status: i32) -> cstring {
	switch status {
	case 100: return "Continue"
	case 101: return "Switching Protocols"
	case 103: return "Early Hints"
	case 200: return "OK"
	case 201: return "Created"
	case 202: return "Accepted"
	case 203: return "Non-Authoritative Information"
	case 204: return "No Content"
	case 205: return "Reset Content"
	case 206: return "Partial Content"
	case 207: return "Multi-Status"
	case 300: return "Multiple Choices"
	case 301: return "Moved Permanently"
	case 302: return "Found"
	case 303: return "See Other"
	case 304: return "Not Modified"
	case 307: return "Temporary Redirect"
	case 308: return "Permanent Redirect"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 402: return "Payment Required"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 406: return "Not Acceptable"
	case 407: return "Proxy Authentication Required"
	case 408: return "Request Timeout"
	case 409: return "Conflict"
	case 410: return "Gone"
	case 411: return "Length Required"
	case 412: return "Precondition Failed"
	case 413: return "Payload Too Large"
	case 414: return "URI Too Long"
	case 415: return "Unsupported Media Type"
	case 416: return "Range Not Satisfiable"
	case 417: return "Expectation Failed"
	case 418: return "I'm a teapot"
	case 421: return "Misdirected Request"
	case 422: return "Unprocessable Entity"
	case 425: return "Too Early"
	case 426: return "Upgrade Required"
	case 428: return "Precondition Required"
	case 429: return "Too Many Requests"
	case 431: return "Request Header Fields Too Large"
	case 451: return "Unavailable For Legal Reasons"
	case 500: return "Internal Server Error"
	case 501: return "Not Implemented"
	case 502: return "Bad Gateway"
	case 503: return "Service Unavailable"
	case 504: return "Gateway Timeout"
	case 505: return "HTTP Version Not Supported"
	case 511: return "Network Authentication Required"
	}
	return ""
}

@(export, link_name = "web_status_text")
web_status_text :: proc "c" (status: i32) -> cstring { return status_text(status) }

@(private = "file")
throw_bad_url :: proc "contextless" (ctx: ^wj.Context, s: string) {
	wj.JS_ThrowTypeError(ctx, "Failed to parse URL from %.*s", i32(min(len(s), 200)), wj.raw_bytes(s))
}

// `s` resolved against the document's base URL (a worker's: its script's URL), NUL-terminated on the C heap (free it
// with wj.libc_free(raw_data(abs))). ok false with a TypeError pending.
resolve_url :: proc(ctx: ^wj.Context, s: string) -> (abs: string, ok: bool) {
	r: string
	if wj.is_window() {
		if jsb.host(&r, api_decl.Document_resolveURL, wj.wr_Document_resolveURL, s) != .None { throw_bad_url(ctx, s); return }
	} else {
		loc: string
		if jsb.host(&loc, api_decl.WorkerGlobalScope_location, wj.wr_WorkerGlobalScope_location) != .None {
			wj.JS_ThrowTypeError(ctx, "Invalid URL")
			return
		}
		// (the scratch buffer is reused by the next call: the base is copied)
		base, cloned := clone_string(loc)
		if !cloned { wj.JS_ThrowOutOfMemory(ctx); return }
		u: api_decl.URL
		st := jsb.host(&u, api_decl.URL_parse, wj.wr_URL_parse, s, Maybe(string)(base))
		delete(base)
		if st != .None { throw_bad_url(ctx, s); return }
		st = jsb.host(&r, api_decl.URL_get, wj.wr_URL_get, u, api_decl.URLComponent.Href)
		wj.wr_Object_release(u64(u))
		if st != .None { throw_bad_url(ctx, s); return }
	}
	p := wj.heap_strndup(r)
	if p == nil { wj.JS_ThrowOutOfMemory(ctx); return }
	return string(p[:len(r)]), true
}

resolved_free :: proc "contextless" (abs: string) { wj.libc_free(raw_data(abs)) }

@(export, link_name = "web_resolve_url")
web_resolve_url :: proc "c" (ctx: ^wj.Context, s: [^]u8, n: uint, out: ^wj.Str) -> bool {
	context = wj.heap_context()
	out^ = {}
	abs, ok := resolve_url(ctx, bytes_view(s, n))
	if !ok { return false }
	// malloc'ed: the caller frees it with free()
	out^ = {raw_data(abs), uint(len(abs)), false}
	return true
}

// user:password@ in a URL
@(private = "file")
url_has_credentials :: proc "contextless" (u: string) -> bool {
	for i := 0; i + 2 < len(u); i += 1 {
		if u[i] != ':' || u[i + 1] != '/' || u[i + 2] != '/' { continue }
		for c in transmute([]u8)u[i + 3:] {
			switch c {
			case '/', '?', '#': return false
			case '@':           return true
			}
		}
		return false
	}
	return false
}

// ---- bodies ----

// Fetch "extract a body": the bytes and their Content-Type (both owned; "" for none), or a ReadableStream (counted).
Extracted_Body :: struct {
	bytes:  []u8,
	type:   string,
	stream: wj.JSValue,
}

extracted_delete :: proc(ctx: ^wj.Context, e: ^Extracted_Body) {
	delete(e.bytes)
	delete(e.type)
	wj.JS_FreeValue(ctx, e.stream)
	e^ = {stream = wj.UNDEFINED}
}

extract_body :: proc(ctx: ^wj.Context, v: wj.JSValue, what: cstring) -> (e: Extracted_Body, ok: bool) {
	e.stream = wj.UNDEFINED
	if bytes, is_blob := blob_slice(v); is_blob {
		cb, copied := clone_bytes(bytes)
		if !copied { wj.JS_ThrowOutOfMemory(ctx); return }
		e.bytes = cb
		t := web_blob_type(ctx, v)
		defer wj.JS_FreeValue(ctx, t)
		if ts, c, good := wj.to_string_view(ctx, t); good {
			e.type, _ = clone_string(ts)
			wj.free_cstring(ctx, c)
		}
		return e, true
	}
	if wj.wj_is_buffer_source(v) {
		p: [^]u8
		n: uint
		if !wj.wj_to_buffer_source(ctx, v, &p, &n, 0, what) { return }
		cb, copied := clone_bytes(p[:n] if p != nil else nil)
		if !copied { wj.JS_ThrowOutOfMemory(ctx); return }
		e.bytes = cb
		return e, true
	}
	if web_formdata_is(v) {
		boundary: [96]u8
		buf := api_decl.Buffer(web_formdata_encode(ctx, v, &boundary[0], len(boundary)))
		if buf == 0 { return }
		defer wj.wr_Object_release(u64(buf))
		n: i64
		jsb.host(&n, api_decl.Buffer_length, wj.wr_Buffer_length, buf)
		b, err := make([]u8, int(max(n, 0)))
		if err != nil { wj.JS_ThrowOutOfMemory(ctx); return }
		got: i32
		if len(b) > 0 { jsb.host(&got, api_decl.Buffer_read, wj.wr_Buffer_read, buf, i64(0), b) }
		e.bytes = b[:max(got, 0)]
		ct: [dynamic]u8
		append(&ct, "multipart/form-data; boundary=")
		append(&ct, string(cstring(&boundary[0])))
		e.type = string(ct[:])
		return e, true
	}
	if wj.wj_unwrap(v, net_iface(.URLSearchParams)) != nil {
		s := wj.JS_ToString(ctx, v)
		if wj.is_exception(s) { return }
		defer wj.JS_FreeValue(ctx, s)
		text, c, good := wj.to_string_view(ctx, s)
		if !good { return }
		defer wj.free_cstring(ctx, c)
		b, copied := clone_bytes(transmute([]u8)text)
		if !copied { wj.JS_ThrowOutOfMemory(ctx); return }
		e.bytes = b
		e.type, _ = clone_string("application/x-www-form-urlencoded;charset=UTF-8")
		return e, true
	}
	if web_stream_is(v) {
		if web_stream_locked(v) || web_stream_disturbed(v) {
			wj.JS_ThrowTypeError(ctx, "%s: the body stream is locked or disturbed", what)
			return
		}
		e.stream = wj.JS_DupValue(ctx, v)
		return e, true
	}
	s: wj.Str
	if !wj.web_to_usv(ctx, v, &s) { return }
	defer wj.wj_str_free(ctx, &s)
	b, copied := clone_bytes(wj.str_slice(s))
	if !copied { wj.JS_ThrowOutOfMemory(ctx); return }
	e.bytes = b
	e.type, _ = clone_string("text/plain;charset=UTF-8")
	return e, true
}

// The C side's form (web_navigator.c): data and type on the C heap.
@(export, link_name = "web_extract_body")
web_extract_body :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, out: ^wj.Extracted, what: cstring) -> bool {
	context = wj.heap_context()
	out^ = {stream = wj.UNDEFINED}
	e, ok := extract_body(ctx, v, what)
	if !ok { return false }
	defer extracted_delete(ctx, &e)
	out.data = ([^]u8)(wj.libc_malloc(uint(max(len(e.bytes), 1))))
	if out.data == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	copy(out.data[:len(e.bytes)], e.bytes)
	out.len = uint(len(e.bytes))
	if len(e.type) > 0 { out.type = wj.cstr(wj.heap_strndup(e.type)) }
	out.stream, e.stream = e.stream, wj.UNDEFINED
	return true
}

@(export, link_name = "web_extracted_free")
web_extracted_free :: proc "c" (ctx: ^wj.Context, e: ^wj.Extracted) {
	wj.libc_free(e.data)
	wj.libc_free(rawptr(e.type))
	wj.JS_FreeValue(ctx, e.stream)
	e^ = {stream = wj.UNDEFINED}
}

@(private = "file")
Read :: enum i32 { Array_Buffer, Bytes, Text, JSON, Blob, Form_Data }

// What a body holds (nil: no body).
@(private = "file")
Body_Bytes :: struct {
	data: []u8,    // owned
	used: bool,    // consumed without a stream
}
@(private = "file")
Body_Host :: struct {
	record: api_decl.Fetch,   // the browser's response record (owned by the Response: Fetch_Response.record)
	used:   bool,
}
@(private = "file")
Body_Stream :: struct {
	stream: wj.JSValue,
}
@(private = "file")
Body :: union {
	Body_Bytes,
	Body_Host,
	Body_Stream,
}

@(private = "file")
body_free :: proc(rt: ^wj.Runtime, b: ^Body) {
	switch &k in b^ {
	case Body_Bytes:  delete(k.data)
	case Body_Stream: wj.JS_FreeValueRT(rt, k.stream)
	case Body_Host:
	}
	b^ = nil
}

@(private = "file")
body_mark :: proc "contextless" (rt: rawptr, b: ^Body, mf: rawptr) {
	if s, ok := b^.(Body_Stream); ok { wj.wj_mark(rt, s.stream, mf) }
}

@(private = "file")
body_unusable :: proc "contextless" (b: ^Body) -> bool {
	switch k in b^ {
	case Body_Stream: return web_stream_locked(k.stream) || web_stream_disturbed(k.stream)
	case Body_Bytes:  return k.used
	case Body_Host:   return k.used
	}
	return false
}

// A body from an extracted one (taking its bytes or stream).
@(private = "file")
body_take :: proc(e: ^Extracted_Body) -> Body {
	if !wj.is_undefined(e.stream) {
		b := Body_Stream{e.stream}
		e.stream = wj.UNDEFINED
		return b
	}
	b := Body_Bytes{data = e.bytes}
	e.bytes = nil
	return b
}

@(private = "file")
Mode :: enum u8 { Cors, Same_Origin, No_Cors, Navigate }
@(private = "file")
Response_Type :: enum u8 { Basic, Cors, Default, Error, Opaque, Opaque_Redirect }

@(private = "file", rodata) mode_names := [Mode]string{.Cors = "cors", .Same_Origin = "same-origin", .No_Cors = "no-cors", .Navigate = "navigate"}
@(private = "file", rodata) response_type_names := [Response_Type]string{
	.Basic = "basic", .Cors = "cors", .Default = "default", .Error = "error", .Opaque = "opaque", .Opaque_Redirect = "opaqueredirect",
}
@(private = "file", rodata) credentials_names := [api_decl.Credentials]string{.Same_Origin = "same-origin", .Omit = "omit", .Include = "include"}
@(private = "file", rodata) cache_names := [api_decl.RequestCache]string{
	.Default = "default", .No_Store = "no-store", .Reload = "reload", .No_Cache = "no-cache", .Force_Cache = "force-cache",
	.Only_If_Cached = "only-if-cached",
}
@(private = "file", rodata) redirect_names := [api_decl.RedirectMode]string{.Follow = "follow", .Error = "error", .Manual = "manual"}
// "" then the browser's ReferrerPolicy order
@(private = "file", rodata) policy_names := [api_decl.ReferrerPolicy]string{
	.Default = "", .No_Referrer = "no-referrer", .No_Referrer_When_Downgrade = "no-referrer-when-downgrade",
	.Same_Origin = "same-origin", .Origin = "origin", .Strict_Origin = "strict-origin",
	.Origin_When_Cross_Origin = "origin-when-cross-origin", .Strict_Origin_When_Cross_Origin = "strict-origin-when-cross-origin",
	.Unsafe_Url = "unsafe-url",
}
// Fetch RequestDestination ("" for what script makes, set for a FetchEvent's request)
@(private = "file", rodata) destination_names := [?]string{
	"", "audio", "audioworklet", "document", "embed", "font", "frame", "iframe", "image", "json", "manifest", "object",
	"paintworklet", "report", "script", "serviceworker", "sharedworker", "style", "text", "track", "video", "worker", "xslt",
}

@(private = "file")
Fetch_Request :: struct {
	url, method, headers, signal, referrer, integrity: wj.JSValue,
	body:            Body,
	mode:            Mode,
	credentials:     api_decl.Credentials,
	cache:           api_decl.RequestCache,
	redirect:        api_decl.RedirectMode,
	referrer_policy: api_decl.ReferrerPolicy,
	destination:     u8,   // index in destination_names
	keepalive:       bool,
}

@(private = "file")
Fetch_Response :: struct {
	status:                              i32,
	status_text, headers, url, signal:   wj.JSValue,
	type:                                Response_Type,
	redirected:                          bool,
	body:                                Body,
	record:                              api_decl.Fetch,   // the browser's record behind a network response (released with the object)
}

@(private = "file")
request_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	r := (^Fetch_Request)(p)
	rt := wj.web_rt()
	for v in ([]wj.JSValue{r.url, r.method, r.headers, r.signal, r.referrer, r.integrity}) { wj.JS_FreeValueRT(rt, v) }
	body_free(rt, &r.body)
	free(r)
}

@(private = "file")
request_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) {
	r := (^Fetch_Request)(p)
	for v in ([]wj.JSValue{r.url, r.method, r.headers, r.signal, r.referrer, r.integrity}) { wj.wj_mark(rt, v, mf) }
	body_mark(rt, &r.body, mf)
}

@(private = "file")
response_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	r := (^Fetch_Response)(p)
	rt := wj.web_rt()
	for v in ([]wj.JSValue{r.status_text, r.headers, r.url, r.signal}) { wj.JS_FreeValueRT(rt, v) }
	body_free(rt, &r.body)
	if r.record != 0 { jsb.host(&none_fetch, api_decl.Fetch_release, wj.wr_Fetch_release, r.record) }
	free(r)
}

@(private = "file") none_fetch: struct {}

@(private = "file")
response_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) {
	r := (^Fetch_Response)(p)
	for v in ([]wj.JSValue{r.status_text, r.headers, r.url, r.signal}) { wj.wj_mark(rt, v, mf) }
	body_mark(rt, &r.body, mf)
}

@(private = "file")
request_of :: proc "contextless" (v: wj.JSValue) -> ^Fetch_Request {
	return (^Fetch_Request)(wj.impl_of(wj.wj_unwrap(v, net_iface(.Request))))
}
@(private = "file")
response_of :: proc "contextless" (v: wj.JSValue) -> ^Fetch_Response {
	return (^Fetch_Response)(wj.impl_of(wj.wj_unwrap(v, net_iface(.Response))))
}

// The body of `this` (a Request or a Response) and the values a read needs.
@(private = "file")
body_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (b: ^Body, headers, signal: wj.JSValue) {
	if rq := request_of(this_val); rq != nil { return &rq.body, rq.headers, rq.signal }
	if rs := response_of(this_val); rs != nil { return &rs.body, rs.headers, rs.signal }
	wj.JS_ThrowTypeError(ctx, "Illegal invocation")
	return nil, wj.UNDEFINED, wj.UNDEFINED
}

// Converts the bytes of a body for a read (Fetch "consume body").
@(private = "file")
body_convert :: proc(ctx: ^wj.Context, what: Read, p: []u8, headers: wj.JSValue) -> wj.JSValue {
	data := len(p) > 0 ? raw_data(p) : wj.empty_ptr()
	switch what {
	case .Array_Buffer: return wj.JS_NewArrayBufferCopy(ctx, data, uint(len(p)))
	case .Bytes:        return wj.JS_NewUint8ArrayCopy(ctx, data, uint(len(p)))
	case .Text:         return wj.web_utf8_string(ctx, data, uint(len(p)), true)
	case .JSON:
		s := wj.web_utf8_string(ctx, data, uint(len(p)), true)
		if wj.is_exception(s) { return s }
		t, c, ok := wj.to_string_view(ctx, s)
		wj.JS_FreeValue(ctx, s)
		if !ok { return wj.EXCEPTION }
		defer wj.free_cstring(ctx, c)
		return wj.JS_ParseJSON(ctx, wj.raw_bytes(t), uint(len(t)), "<json>")
	case .Blob, .Form_Data:
		ct, _ := header_value(headers, "content-type")
		defer delete(ct)
		cts := wj.heap_strndup(ct)
		defer wj.libc_free(cts)
		if what == .Blob { return web_blob_new(ctx, data, uint(len(p)), wj.cstr(cts), uint(len(ct))) }
		return web_formdata_parse(ctx, data, uint(len(p)), wj.cstr(cts), uint(len(ct)))
	}
	return wj.UNDEFINED
}

// The rejection reason of a failed read or fetch: the signal's reason once it aborted, else a TypeError with the
// browser's message.
@(private = "file")
failure_reason :: proc "contextless" (ctx: ^wj.Context, host: u64, signal: wj.JSValue) -> wj.JSValue {
	if web_signal_aborted(signal) { return web_signal_reason(ctx, signal) }
	t := wj.wj_host_promise_text(ctx, host)
	m := wj.to_cstring(ctx, t)
	e := wj.web_type_error(ctx, m != nil && (^u8)(m)^ != 0 ? m : "Failed to fetch")
	if m != nil { wj.free_cstring(ctx, m) }
	wj.JS_FreeValue(ctx, t)
	return e
}

// data: [this (Request or Response), what]
@(private = "file")
on_host_body :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = wj.heap_context()
	owner := wj.JS_GetPropertyUint32(ctx, data, 0)
	defer wj.JS_FreeValue(ctx, owner)
	wv := wj.JS_GetPropertyUint32(ctx, data, 1)
	what: i32
	wj.JS_ToInt32(ctx, &what, wv)
	wj.JS_FreeValue(ctx, wv)
	b, headers, signal := body_this(ctx, owner)
	if b == nil { wj.drop_exception(ctx) }
	if state != 1 {
		reject^ = true
		return failure_reason(ctx, host, signal)
	}
	buf := api_decl.Buffer(value)
	defer if buf != 0 { wj.wr_Object_release(u64(buf)) }
	switch Read(what) {
	case .Array_Buffer: return wj.wj_arraybuffer_from_host(ctx, u64(buf))
	case .Bytes:        return wj.wj_uint8array_from_host(ctx, u64(buf))
	case .Text, .JSON, .Blob, .Form_Data:
	}
	// one copy into the engine, converted from there
	n: i64
	if buf != 0 { jsb.host(&n, api_decl.Buffer_length, wj.wr_Buffer_length, buf) }
	p, err := make([]u8, int(max(n, 0)))
	if err != nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer delete(p)
	got: i32
	if len(p) > 0 { jsb.host(&got, api_decl.Buffer_read, wj.wr_Buffer_read, buf, i64(0), p) }
	return body_convert(ctx, Read(what), p[:max(got, 0)], headers)   // EXCEPTION rejects with the pending exception
}

// data: [this, what]: the bytes of a stream body read whole
@(private = "file")
on_stream_body :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	b, headers, _ := body_this(ctx, data[0])
	if b == nil { return wj.EXCEPTION }
	what: i32
	wj.JS_ToInt32(ctx, &what, data[1])
	p: [^]u8
	n: uint
	chunk := wj.arg(argc, argv, 0)
	if !wj.wj_to_buffer_source(ctx, chunk, &p, &n, 0, "body") { return wj.EXCEPTION }
	if Read(what) == .Array_Buffer { return wj.JS_DupValue(ctx, chunk) }
	return body_convert(ctx, Read(what), p[:n] if p != nil else nil, headers)
}

@(private = "file")
body_read :: proc(ctx: ^wj.Context, this_val: wj.JSValue, what: Read) -> wj.JSValue {
	b, headers, signal := body_this(ctx, this_val)
	if b == nil { return wj.web_promise_reject_pending(ctx) }
	if body_unusable(b) { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Body has already been consumed.")) }
	switch &k in b^ {
	case nil, Body_Bytes:
		bytes: []u8
		if bb, ok := &k.(Body_Bytes); ok {
			bytes = bb.data
			bb.data = nil
			bb.used = true
		}
		defer delete(bytes)
		v := body_convert(ctx, what, bytes, headers)
		if wj.is_exception(v) { return wj.web_promise_reject_pending(ctx) }
		return wj.web_promise_take(ctx, v)
	case Body_Host:
		if web_signal_aborted(signal) { return wj.web_promise_rejected(ctx, web_signal_reason(ctx, signal)) }
		k.used = true
		data := wj.JS_NewArray(ctx)
		defer wj.JS_FreeValue(ctx, data)
		wj.array_set(ctx, data, 0, wj.JS_DupValue(ctx, this_val))
		wj.array_set(ctx, data, 1, wj.new_int32(i32(what)))
		pr: api_decl.Promise
		jsb.host(&pr, api_decl.Response_arrayBuffer, wj.wr_Response_arrayBuffer, k.record)
		return wj.wj_promise_from_host(ctx, u64(pr), wj.HOST_UNDEFINED, on_host_body, data)
	case Body_Stream:
		all := web_stream_read_all(ctx, k.stream)
		defer wj.JS_FreeValue(ctx, all)
		return then_with(ctx, all, on_stream_body, nil, this_val, wj.new_int32(i32(what)))
	}
	return wj.web_promise_resolved(ctx, wj.UNDEFINED)
}

@(export, link_name = "wjr_Body_arrayBuffer")
wjr_Body_arrayBuffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = wj.heap_context(); return body_read(ctx, this_val, .Array_Buffer) }
@(export, link_name = "wjr_Body_bytes")
wjr_Body_bytes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = wj.heap_context(); return body_read(ctx, this_val, .Bytes) }
@(export, link_name = "wjr_Body_text")
wjr_Body_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = wj.heap_context(); return body_read(ctx, this_val, .Text) }
@(export, link_name = "wjr_Body_json")
wjr_Body_json :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = wj.heap_context(); return body_read(ctx, this_val, .JSON) }
@(export, link_name = "wjr_Body_blob")
wjr_Body_blob :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = wj.heap_context(); return body_read(ctx, this_val, .Blob) }
@(export, link_name = "wjr_Body_formData")
wjr_Body_formData :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = wj.heap_context(); return body_read(ctx, this_val, .Form_Data) }

// textStream(): the body's text as a stream (one chunk once the whole body is decoded)
@(private = "file")
on_text_ok :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	text := wj.arg(argc, argv, 0)
	n: i64
	if wj.is_string(text) && wj.JS_GetLength(ctx, text, &n) == 0 && n > 0 { web_stream_push(ctx, data[0], text) }
	web_stream_end(ctx, data[0])
	return wj.UNDEFINED
}

@(private = "file")
on_text_err :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	web_stream_fail(ctx, data[0], wj.arg(argc, argv, 0))
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Body_textStream")
wjr_Body_textStream :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	b, _, _ := body_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	if body_unusable(b) { return wj.wj_throw_type(ctx, "Body has already been consumed.") }
	s := web_stream_pending(ctx)
	if wj.is_exception(s) { return s }
	p := body_read(ctx, this_val, .Text)
	then_drop(ctx, p, on_text_ok, on_text_err, s)
	wj.JS_FreeValue(ctx, p)
	return s
}

// The body as a stream (made on first use: reading it is consuming the body).
@(private = "file")
body_stream :: proc(ctx: ^wj.Context, owner: wj.JSValue, b: ^Body, signal: wj.JSValue) -> wj.JSValue {
	s: wj.JSValue
	switch k in b^ {
	case nil:         return wj.NULL
	case Body_Stream: return wj.JS_DupValue(ctx, k.stream)
	case Body_Bytes:
		s = web_stream_from_bytes(ctx, raw_data(k.data), k.used ? 0 : uint(len(k.data)))
		if wj.is_exception(s) { return s }
		delete(k.data)
	case Body_Host:
		if k.used {
			s = web_stream_from_bytes(ctx, nil, 0)
		} else {
			hs: api_decl.Stream
			if st := jsb.host(&hs, api_decl.Response_body, wj.wr_Response_body, k.record); st != .None {
				return wj.wj_throw_status(ctx, i32(st), "Response.body")
			}
			s = web_stream_from_host(ctx, u64(hs), signal, owner)
		}
		if wj.is_exception(s) { return s }
	}
	b^ = Body_Stream{wj.JS_DupValue(ctx, s)}
	return s
}

@(export, link_name = "wjr_Body_get_body")
wjr_Body_get_body :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	b, _, signal := body_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	return body_stream(ctx, this_val, b, signal)
}

@(export, link_name = "wjr_Body_get_bodyUsed")
wjr_Body_get_bodyUsed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	b, _, _ := body_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	switch k in b^ {
	case Body_Stream: return wj.new_bool(web_stream_disturbed(k.stream))
	case Body_Bytes:  return wj.new_bool(k.used)
	case Body_Host:   return wj.new_bool(k.used)
	}
	return wj.FALSE
}

// Clone the body into `to` (Fetch "clone a body": a tee of its stream; bytes are copied).
@(private = "file")
body_clone :: proc(ctx: ^wj.Context, owner: wj.JSValue, from: ^Body, to: ^Body, signal: wj.JSValue) -> bool {
	to^ = nil
	if body_unusable(from) { wj.JS_ThrowTypeError(ctx, "Failed to execute 'clone': Response body is already used"); return false }
	switch k in from^ {
	case nil: return true
	case Body_Bytes:
		d, ok := clone_bytes(k.data)
		if !ok { wj.JS_ThrowOutOfMemory(ctx); return false }
		to^ = Body_Bytes{data = d}
		return true
	case Body_Host, Body_Stream:
	}
	s := body_stream(ctx, owner, from, signal)
	if wj.is_exception(s) { return false }
	wj.JS_FreeValue(ctx, s)
	fs := &from^.(Body_Stream)
	both := web_stream_tee(ctx, fs.stream, true)
	if wj.is_exception(both) { return false }
	wj.JS_FreeValue(ctx, fs.stream)
	fs.stream = wj.JS_GetPropertyUint32(ctx, both, 0)
	to^ = Body_Stream{wj.JS_GetPropertyUint32(ctx, both, 1)}
	wj.JS_FreeValue(ctx, both)
	return true
}

// ---- Request ----

// The index of the JS string `v` in `names`: -1 with a TypeError pending when it is none of them.
@(private = "file")
enum_index :: proc(ctx: ^wj.Context, v: wj.JSValue, names: []string, what: cstring) -> int {
	s, c, ok := wj.to_string_view(ctx, v)
	if !ok { return -1 }
	defer wj.free_cstring(ctx, c)
	for n, i in names { if s == n { return i } }
	wj.JS_ThrowTypeError(ctx, "The provided value '%s' is not a valid enum value of type %s.", c, what)
	return -1
}

// An init member that is an enum (its names in an enumerated array): false with an exception, `out` unchanged when
// absent.
@(private = "file")
init_enum :: proc(ctx: ^wj.Context, init: wj.JSValue, name: cstring, names: ^[$E]string, what: cstring, out: ^E) -> bool {
	v: wj.JSValue
	if !wj.web_dict_get(ctx, init, name, &v) { return false }
	if wj.is_undefined(v) { return true }
	i := enum_index(ctx, v, ([^]string)(names)[:len(names^)], what)
	wj.JS_FreeValue(ctx, v)
	if i < 0 { return false }
	out^ = E(i)
	return true
}

// A new signal of its own (a new AbortController's).
@(private = "file")
new_signal :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	ac := web_controller_construct(ctx, wj.UNDEFINED, net_iface(.AbortController), net_iface(.AbortSignal))
	if wj.is_exception(ac) { return ac }
	s := wjr_AbortController_get_signal(ctx, ac)
	wj.JS_FreeValue(ctx, ac)
	return s
}

// Fetch: the request's signal follows the given one (a dependent signal).
@(private = "file")
signal_following :: proc "contextless" (ctx: ^wj.Context, signal: wj.JSValue) -> wj.JSValue {
	list := wj.JS_NewArray(ctx)
	wj.array_set(ctx, list, 0, wj.JS_DupValue(ctx, signal))
	r := web_signal_any(ctx, list, net_iface(.AbortSignal), "AbortSignal.any")
	wj.JS_FreeValue(ctx, list)
	return r
}

// The JS string `v` is one of `lits`.
@(private = "file")
js_string_in :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, lits: ..string) -> bool {
	s, c, ok := wj.to_string_view(ctx, v)
	if !ok { wj.drop_exception(ctx); return false }
	defer wj.free_cstring(ctx, c)
	for l in lits { if s == l { return true } }
	return false
}

// A method normalized (DELETE, GET, HEAD, OPTIONS, POST, PUT upper-cased), as a JS string.
normalized_method :: proc "contextless" (ctx: ^wj.Context, m: string) -> wj.JSValue {
	@(static) norm := [?]string{"DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"}
	for n in norm { if wj.ascii_ieq(m, n) { return wj.new_string_len(ctx, n) } }
	return wj.new_string_len(ctx, m)
}

// new Request(input, init): the impl filled (Fetch "Request constructor"); false with an exception pending.
@(private = "file")
request_build :: proc(ctx: ^wj.Context, r: ^Fetch_Request, input: wj.JSValue, init: wj.JSValue) -> bool {
	r.url, r.method, r.headers, r.signal, r.referrer, r.integrity = wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	r.body = nil
	r.mode = .Cors
	r.credentials = .Same_Origin
	r.destination = 0
	src := request_of(input)
	if !wj.web_dict_check(ctx, init, "Request") { return false }
	if src != nil {
		r.url = wj.JS_DupValue(ctx, src.url)
		r.method = wj.JS_DupValue(ctx, src.method)
		r.referrer = wj.JS_DupValue(ctx, src.referrer)
		r.integrity = wj.JS_DupValue(ctx, src.integrity)
		r.mode, r.credentials, r.cache, r.redirect = src.mode, src.credentials, src.cache, src.redirect
		r.referrer_policy, r.keepalive, r.destination = src.referrer_policy, src.keepalive, src.destination
		if r.mode == .Navigate { r.mode = .Same_Origin }
	} else {
		s: wj.Str
		if !wj.web_to_usv(ctx, input, &s) { return false }
		abs, ok := resolve_url(ctx, wj.str_view(s))
		wj.wj_str_free(ctx, &s)
		if !ok { return false }
		defer resolved_free(abs)
		if url_has_credentials(abs) {
			wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': Request cannot be constructed from a URL that includes credentials: %.*s", i32(min(len(abs), 200)), raw_data(abs))
			return false
		}
		r.url = wj.new_string_len(ctx, abs)
		r.method = js_str(ctx, "GET")
		r.referrer = js_str(ctx, "about:client")
		r.integrity = js_str(ctx, "")
	}
	v: wj.JSValue
	// window: only null
	if !wj.web_dict_get(ctx, init, "window", &v) { return false }
	if !wj.is_nullish(v) {
		wj.JS_FreeValue(ctx, v)
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': 'window' can only be null")
		return false
	}
	if !wj.web_dict_get(ctx, init, "referrer", &v) { return false }
	if !wj.is_undefined(v) {
		s: wj.Str
		ok := wj.web_to_usv(ctx, v, &s)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		defer wj.wj_str_free(ctx, &s)
		wj.JS_FreeValue(ctx, r.referrer)
		r.referrer = wj.UNDEFINED
		if s.len == 0 {
			r.referrer = js_str(ctx, "")
		} else {
			abs, resolved := resolve_url(ctx, wj.str_view(s))
			if !resolved { return false }
			r.referrer = wj.new_string_len(ctx, abs)
			resolved_free(abs)
		}
	}
	if !init_enum(ctx, init, "referrerPolicy", &policy_names, "ReferrerPolicy", &r.referrer_policy) { return false }
	mode := r.mode
	if !init_enum(ctx, init, "mode", &mode_names, "RequestMode", &mode) { return false }
	if mode == .Navigate {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': Cannot construct a Request with a RequestInit whose mode member is set as 'navigate'.")
		return false
	}
	r.mode = mode
	if !init_enum(ctx, init, "credentials", &credentials_names, "RequestCredentials", &r.credentials) { return false }
	if !init_enum(ctx, init, "cache", &cache_names, "RequestCache", &r.cache) { return false }
	if r.cache == .Only_If_Cached && r.mode != .Same_Origin {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': 'only-if-cached' can be set only with 'same-origin' mode")
		return false
	}
	if !init_enum(ctx, init, "redirect", &redirect_names, "RequestRedirect", &r.redirect) { return false }
	if !wj.web_dict_get(ctx, init, "integrity", &v) { return false }
	if !wj.is_undefined(v) {
		wj.JS_FreeValue(ctx, r.integrity)
		r.integrity = wj.JS_ToString(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(r.integrity) { r.integrity = wj.UNDEFINED; return false }
	}
	if !wj.web_dict_get(ctx, init, "keepalive", &v) { return false }
	if !wj.is_undefined(v) { r.keepalive = wj.to_bool(ctx, v); wj.JS_FreeValue(ctx, v) }
	if !wj.web_dict_get(ctx, init, "method", &v) { return false }
	if !wj.is_undefined(v) {
		ms: wj.Str
		ok := wj.web_to_bytestring(ctx, v, &ms)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		defer wj.wj_str_free(ctx, &ms)
		m := wj.str_view(ms)
		if !valid_token(m) {
			wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': '%.*s' is not a valid HTTP method.", i32(min(len(m), 64)), wj.raw_bytes(m))
			return false
		}
		if forbidden_method(m) {
			wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': '%.*s' HTTP method is unsupported.", i32(len(m)), wj.raw_bytes(m))
			return false
		}
		wj.JS_FreeValue(ctx, r.method)
		r.method = normalized_method(ctx, m)
	}
	// the signal: init's, else the input request's; the request's own follows it
	if !wj.web_dict_get(ctx, init, "signal", &v) { return false }
	given := wj.UNDEFINED
	if !wj.is_nullish(v) {
		if wj.wj_unwrap(v, net_iface(.AbortSignal)) == nil {
			wj.JS_FreeValue(ctx, v)
			wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': member signal is not of type AbortSignal.")
			return false
		}
		given = v
	} else {
		wj.JS_FreeValue(ctx, v)
		if src != nil && wj.is_object(src.signal) { given = wj.JS_DupValue(ctx, src.signal) }
	}
	r.signal = wj.is_object(given) ? signal_following(ctx, given) : new_signal(ctx)
	wj.JS_FreeValue(ctx, given)
	if wj.is_exception(r.signal) { r.signal = wj.UNDEFINED; return false }
	// headers
	r.headers = web_headers_new(ctx, r.mode == .No_Cors ? .Request_No_Cors : .Request)
	if wj.is_exception(r.headers) { r.headers = wj.UNDEFINED; return false }
	if r.mode == .No_Cors && !js_string_in(ctx, r.method, "GET", "HEAD", "POST") {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': '%s' is unsupported in no-cors mode.", cstring("method"))
		return false
	}
	hinit: wj.JSValue
	if !wj.web_dict_get(ctx, init, "headers", &hinit) { return false }
	ok := true
	if !wj.is_undefined(hinit) { ok = headers_fill(ctx, headers_of(r.headers), hinit) }
	else if src != nil { ok = headers_fill(ctx, headers_of(r.headers), src.headers) }
	wj.JS_FreeValue(ctx, hinit)
	if !ok { return false }
	// body
	binit: wj.JSValue
	if !wj.web_dict_get(ctx, init, "body", &binit) { return false }
	defer wj.JS_FreeValue(ctx, binit)
	has_body := !wj.is_nullish(binit)
	src_body := src != nil && src.body != nil
	if (has_body || src_body) && js_string_in(ctx, r.method, "GET", "HEAD") && (has_body || wj.is_undefined(binit)) {
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': Request with GET/HEAD method cannot have body.")
		return false
	}
	if has_body {
		e, extracted := extract_body(ctx, binit, "Request")
		if !extracted { return false }
		defer extracted_delete(ctx, &e)
		if !wj.is_undefined(e.stream) {
			duplex: wj.JSValue
			if !wj.web_dict_get(ctx, init, "duplex", &duplex) { return false }
			half := wj.is_string(duplex)
			wj.JS_FreeValue(ctx, duplex)
			if !half {
				wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': The duplex member must be specified for a request with a streaming body")
				return false
			}
		}
		r.body = body_take(&e)
		if len(e.type) > 0 && !headers_contains(headers_of(r.headers), "content-type") {
			headers_push(headers_of(r.headers), "content-type", e.type)
		}
	} else if src_body {
		// the input's body moves to the new request
		if body_unusable(&src.body) {
			wj.JS_ThrowTypeError(ctx, "Failed to construct 'Request': Cannot construct a Request with a Request object that has already been used.")
			return false
		}
		r.body = src.body
		src.body = Body_Bytes{used = true}
	}
	return true
}

@(private = "file")
request_object :: proc(ctx: ^wj.Context, new_target: wj.JSValue, r: ^Fetch_Request) -> wj.JSValue {
	obj := wj.wj_new_object_for(ctx, net_iface(.Request), new_target, nil, nil)
	if wj.is_exception(obj) { request_free(r); return obj }
	wj.web_set_impl(obj, r, request_free, request_mark)
	return obj
}

@(export, link_name = "wjr_Request_constructor")
wjr_Request_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor Request requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Request", 1, argc) }
	r := new(Fetch_Request)
	if r == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	if !request_build(ctx, r, argv[0], wj.arg(argc, argv, 1)) { request_free(r); return wj.EXCEPTION }
	return request_object(ctx, new_target, r)
}

@(private = "file")
request_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Fetch_Request {
	return (^Fetch_Request)(wj.web_this_impl(ctx, this_val, net_iface(.Request)))
}

@(private = "file")
request_value :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, $field: string) -> wj.JSValue {
	r := request_this(ctx, this_val)
	return r != nil ? wj.JS_DupValue(ctx, field_of(r, field)) : wj.EXCEPTION
}

@(private = "file")
field_of :: #force_inline proc "contextless" (r: ^Fetch_Request, $field: string) -> wj.JSValue {
	when field == "url"            { return r.url }
	else when field == "method"    { return r.method }
	else when field == "headers"   { return r.headers }
	else when field == "signal"    { return r.signal }
	else when field == "integrity" { return r.integrity }
	else                           { return r.referrer }
}

@(export, link_name = "wjr_Request_get_url")
wjr_Request_get_url :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return request_value(ctx, this_val, "url") }
@(export, link_name = "wjr_Request_get_method")
wjr_Request_get_method :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return request_value(ctx, this_val, "method") }
@(export, link_name = "wjr_Request_get_headers")
wjr_Request_get_headers :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return request_value(ctx, this_val, "headers") }
@(export, link_name = "wjr_Request_get_signal")
wjr_Request_get_signal :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return request_value(ctx, this_val, "signal") }
@(export, link_name = "wjr_Request_get_integrity")
wjr_Request_get_integrity :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return request_value(ctx, this_val, "integrity") }
@(export, link_name = "wjr_Request_get_referrer")
wjr_Request_get_referrer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return request_value(ctx, this_val, "referrer") }

// An enumerated attribute of a Request: the name of its value.
@(private = "file")
request_name :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, pick: proc "contextless" (r: ^Fetch_Request) -> string) -> wj.JSValue {
	r := request_this(ctx, this_val)
	return r != nil ? wj.new_string_len(ctx, pick(r)) : wj.EXCEPTION
}

@(export, link_name = "wjr_Request_get_destination")
wjr_Request_get_destination :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return destination_names[r.destination] })
}
@(export, link_name = "wjr_Request_get_referrerPolicy")
wjr_Request_get_referrerPolicy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return policy_names[r.referrer_policy] })
}
@(export, link_name = "wjr_Request_get_mode")
wjr_Request_get_mode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return mode_names[r.mode] })
}
@(export, link_name = "wjr_Request_get_credentials")
wjr_Request_get_credentials :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return credentials_names[r.credentials] })
}
@(export, link_name = "wjr_Request_get_cache")
wjr_Request_get_cache :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return cache_names[r.cache] })
}
@(export, link_name = "wjr_Request_get_redirect")
wjr_Request_get_redirect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return redirect_names[r.redirect] })
}
@(export, link_name = "wjr_Request_get_duplex")
wjr_Request_get_duplex :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_name(ctx, this_val, proc "contextless" (r: ^Fetch_Request) -> string { return "half" })
}
@(export, link_name = "wjr_Request_get_keepalive")
wjr_Request_get_keepalive :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := request_this(ctx, this_val)
	return r != nil ? wj.new_bool(r.keepalive) : wj.EXCEPTION
}
@(export, link_name = "wjr_Request_get_isReloadNavigation")
wjr_Request_get_isReloadNavigation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_this(ctx, this_val) != nil ? wj.FALSE : wj.EXCEPTION
}
@(export, link_name = "wjr_Request_get_isHistoryNavigation")
wjr_Request_get_isHistoryNavigation :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return request_this(ctx, this_val) != nil ? wj.FALSE : wj.EXCEPTION
}

@(export, link_name = "wjr_Request_clone")
wjr_Request_clone :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	src := request_this(ctx, this_val)
	if src == nil { return wj.EXCEPTION }
	if body_unusable(&src.body) { return wj.wj_throw_type(ctx, "Failed to execute 'clone' on 'Request': Request body is already used") }
	r := new(Fetch_Request)
	if r == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	r^ = src^
	r.body = nil
	r.url = wj.JS_DupValue(ctx, src.url)
	r.method = wj.JS_DupValue(ctx, src.method)
	r.referrer = wj.JS_DupValue(ctx, src.referrer)
	r.integrity = wj.JS_DupValue(ctx, src.integrity)
	sh := headers_of(src.headers)
	r.signal = signal_following(ctx, src.signal)
	r.headers = headers_copy(ctx, sh, sh != nil ? sh.guard : .Request)
	if wj.is_exception(r.signal) || wj.is_exception(r.headers) {
		if wj.is_exception(r.signal) { r.signal = wj.UNDEFINED }
		if wj.is_exception(r.headers) { r.headers = wj.UNDEFINED }
		request_free(r)
		return wj.EXCEPTION
	}
	if !body_clone(ctx, this_val, &src.body, &r.body, src.signal) { request_free(r); return wj.EXCEPTION }
	return request_object(ctx, wj.UNDEFINED, r)
}

// ---- Response ----

@(private = "file")
response_new_impl :: proc(ctx: ^wj.Context) -> ^Fetch_Response {
	r := new(Fetch_Response)
	if r == nil { wj.JS_ThrowOutOfMemory(ctx); return nil }
	r^ = {
		status      = 200,
		status_text = js_str(ctx, ""),
		headers     = wj.UNDEFINED,
		url         = js_str(ctx, ""),
		signal      = wj.UNDEFINED,
		type        = .Default,
	}
	return r
}

@(private = "file")
response_object :: proc(ctx: ^wj.Context, new_target: wj.JSValue, r: ^Fetch_Response) -> wj.JSValue {
	obj := wj.wj_new_object_for(ctx, net_iface(.Response), new_target, nil, nil)
	if wj.is_exception(obj) { response_free(r); return obj }
	wj.web_set_impl(obj, r, response_free, response_mark)
	return obj
}

@(private = "file")
null_body_status :: proc "contextless" (s: i32) -> bool { return s == 101 || s == 103 || s == 204 || s == 205 || s == 304 }
@(private = "file")
redirect_status :: proc "contextless" (s: u32) -> bool { return s == 301 || s == 302 || s == 303 || s == 307 || s == 308 }

// Fetch "initialize a response" (status, statusText, headers) and its body
@(private = "file")
response_init :: proc(ctx: ^wj.Context, r: ^Fetch_Response, init: wj.JSValue, body: ^Extracted_Body) -> bool {
	if !wj.web_dict_check(ctx, init, "Response") { return false }
	v: wj.JSValue
	if !wj.web_dict_get(ctx, init, "status", &v) { return false }
	if !wj.is_undefined(v) {
		st: u32
		ok := wj.wj_to_uint32(ctx, v, &st, 16, 0)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		r.status = i32(st)
	}
	if r.status < 200 || r.status > 599 {
		wj.JS_ThrowRangeError(ctx, "Failed to construct 'Response': The status provided (%d) is outside the range [200, 599].", r.status)
		return false
	}
	if !wj.web_dict_get(ctx, init, "statusText", &v) { return false }
	if !wj.is_undefined(v) {
		ts: wj.Str
		ok := wj.web_to_bytestring(ctx, v, &ts)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		defer wj.wj_str_free(ctx, &ts)
		// reason-phrase: HTAB, SP, VCHAR, obs-text
		for c in wj.str_slice(ts) {
			if !(c == '\t' || c == ' ' || (c >= 0x21 && c <= 0x7E) || c >= 0x80) {
				wj.JS_ThrowTypeError(ctx, "Failed to construct 'Response': Invalid statusText")
				return false
			}
		}
		wj.JS_FreeValue(ctx, r.status_text)
		r.status_text = wj.new_string_len(ctx, wj.str_slice(ts))
	}
	r.headers = web_headers_new(ctx, .Response)
	if wj.is_exception(r.headers) { r.headers = wj.UNDEFINED; return false }
	if !wj.web_dict_get(ctx, init, "headers", &v) { return false }
	ok := headers_fill(ctx, headers_of(r.headers), v)
	wj.JS_FreeValue(ctx, v)
	if !ok { return false }
	if body != nil {
		if null_body_status(r.status) {
			wj.JS_ThrowTypeError(ctx, "Failed to construct 'Response': Response with null body status cannot have body")
			return false
		}
		r.body = body_take(body)
		if len(body.type) > 0 && !headers_contains(headers_of(r.headers), "content-type") {
			headers_push(headers_of(r.headers), "content-type", body.type)
		}
	}
	return true
}

@(export, link_name = "wjr_Response_constructor")
wjr_Response_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor Response requires 'new'") }
	b := wj.arg(argc, argv, 0)
	e := Extracted_Body{stream = wj.UNDEFINED}
	has_body := !wj.is_nullish(b)
	if has_body {
		ok: bool
		e, ok = extract_body(ctx, b, "Response")
		if !ok { return wj.EXCEPTION }
	}
	defer extracted_delete(ctx, &e)
	r := response_new_impl(ctx)
	if r == nil { return wj.EXCEPTION }
	if !response_init(ctx, r, wj.arg(argc, argv, 1), has_body ? &e : nil) { response_free(r); return wj.EXCEPTION }
	return response_object(ctx, new_target, r)
}

@(export, link_name = "wjr_Response_static_error")
wjr_Response_static_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := response_new_impl(ctx)
	if r == nil { return wj.EXCEPTION }
	r.status = 0
	r.type = .Error
	r.headers = web_headers_new(ctx, .Immutable)
	return response_object(ctx, wj.UNDEFINED, r)
}

@(export, link_name = "wjr_Response_static_redirect")
wjr_Response_static_redirect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "Response.redirect", 1, argc) }
	s: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &s) { return wj.EXCEPTION }
	abs, ok := resolve_url(ctx, wj.str_view(s))
	wj.wj_str_free(ctx, &s)
	if !ok { return wj.EXCEPTION }
	defer resolved_free(abs)
	status := u32(302)
	if argc > 1 && !wj.is_undefined(argv[1]) && !wj.wj_to_uint32(ctx, argv[1], &status, 16, 0) { return wj.EXCEPTION }
	if !redirect_status(status) { return wj.JS_ThrowRangeError(ctx, "Failed to execute 'redirect' on 'Response': Invalid status code") }
	r := response_new_impl(ctx)
	if r == nil { return wj.EXCEPTION }
	r.status = i32(status)
	r.headers = web_headers_new(ctx, .Immutable)
	if h := headers_of(r.headers); h != nil { headers_push(h, "location", abs) }
	return response_object(ctx, wj.UNDEFINED, r)
}

@(export, link_name = "wjr_Response_static_json")
wjr_Response_static_json :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "Response.json", 1, argc) }
	s := wj.JS_JSONStringify(ctx, argv[0], wj.UNDEFINED, wj.UNDEFINED)
	if wj.is_exception(s) { return s }
	if wj.is_undefined(s) { return wj.wj_throw_type(ctx, "Failed to execute 'json' on 'Response': The data is not JSON serializable") }
	text, c, ok := wj.to_string_view(ctx, s)
	wj.JS_FreeValue(ctx, s)
	if !ok { return wj.EXCEPTION }
	e := Extracted_Body{stream = wj.UNDEFINED}
	e.bytes, _ = clone_bytes(transmute([]u8)text)
	e.type, _ = clone_string("application/json")
	wj.free_cstring(ctx, c)
	defer extracted_delete(ctx, &e)
	r := response_new_impl(ctx)
	if r == nil { return wj.EXCEPTION }
	if !response_init(ctx, r, wj.arg(argc, argv, 1), &e) { response_free(r); return wj.EXCEPTION }
	return response_object(ctx, wj.UNDEFINED, r)
}

@(private = "file")
response_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Fetch_Response {
	return (^Fetch_Response)(wj.web_this_impl(ctx, this_val, net_iface(.Response)))
}

@(export, link_name = "wjr_Response_get_type")
wjr_Response_get_type :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.new_string_len(ctx, response_type_names[r.type]) : wj.EXCEPTION
}
@(export, link_name = "wjr_Response_get_url")
wjr_Response_get_url :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.JS_DupValue(ctx, r.url) : wj.EXCEPTION
}
@(export, link_name = "wjr_Response_get_redirected")
wjr_Response_get_redirected :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.new_bool(r.redirected) : wj.EXCEPTION
}
@(export, link_name = "wjr_Response_get_status")
wjr_Response_get_status :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.new_int32(r.status) : wj.EXCEPTION
}
@(export, link_name = "wjr_Response_get_ok")
wjr_Response_get_ok :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.new_bool(r.status >= 200 && r.status <= 299) : wj.EXCEPTION
}
@(export, link_name = "wjr_Response_get_statusText")
wjr_Response_get_statusText :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.JS_DupValue(ctx, r.status_text) : wj.EXCEPTION
}
@(export, link_name = "wjr_Response_get_headers")
wjr_Response_get_headers :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := response_this(ctx, this_val)
	return r != nil ? wj.JS_DupValue(ctx, r.headers) : wj.EXCEPTION
}

// A request made by the engine for one that came from elsewhere (a service worker's FetchEvent.request): its mode
// (0 cors, 1 same-origin, 2 no-cors, 3 navigate: "navigate" cannot be given to the constructor).
@(export, link_name = "web_request_set_mode")
web_request_set_mode :: proc "c" (req: wj.JSValue, mode: i32) {
	if r := request_of(req); r != nil && mode >= 0 && mode <= i32(Mode.Navigate) { r.mode = Mode(mode) }
}

// ... and its destination (a RequestDestination value; an unknown one leaves "").
@(export, link_name = "web_request_set_destination")
web_request_set_destination :: proc "c" (req: wj.JSValue, name: cstring) {
	r := request_of(req)
	if r == nil || name == nil { return }
	for d, i in destination_names {
		if d == string(name) { r.destination = u8(i); return }
	}
}

// A response made by the engine for one that came from elsewhere (the Cache API's entries): its URL, as the stored
// response had it.
@(export, link_name = "web_response_set_url")
web_response_set_url :: proc "c" (ctx: ^wj.Context, resp: wj.JSValue, url: [^]u8, n: uint) {
	r := response_of(resp)
	if r == nil { return }
	wj.JS_FreeValue(ctx, r.url)
	r.url = wj.new_string_len(ctx, url, n)
}

@(export, link_name = "wjr_Response_clone")
wjr_Response_clone :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	src := response_this(ctx, this_val)
	if src == nil { return wj.EXCEPTION }
	r := response_new_impl(ctx)
	if r == nil { return wj.EXCEPTION }
	r.status = src.status
	r.type = src.type
	r.redirected = src.redirected
	wj.JS_FreeValue(ctx, r.status_text)
	r.status_text = wj.JS_DupValue(ctx, src.status_text)
	wj.JS_FreeValue(ctx, r.url)
	r.url = wj.JS_DupValue(ctx, src.url)
	r.signal = wj.JS_DupValue(ctx, src.signal)
	sh := headers_of(src.headers)
	r.headers = headers_copy(ctx, sh, sh != nil ? sh.guard : .Response)
	if !body_clone(ctx, this_val, &src.body, &r.body, src.signal) { response_free(r); return wj.EXCEPTION }
	return response_object(ctx, wj.UNDEFINED, r)
}

// A Response for the browser's record of a network response (owned from here on).
@(private = "file")
response_from_host :: proc(ctx: ^wj.Context, record: api_decl.Fetch, signal: wj.JSValue) -> wj.JSValue {
	r := response_new_impl(ctx)
	if r == nil { jsb.host(&none_fetch, api_decl.Fetch_release, wj.wr_Fetch_release, record); return wj.EXCEPTION }
	r.record = record
	t: api_decl.ResponseType
	jsb.host(&t, api_decl.Fetch_type, wj.wr_Fetch_type, record)
	#partial switch t {
	case .Cors:            r.type = .Cors
	case .Opaque:          r.type = .Opaque
	case .Opaque_Redirect: r.type = .Opaque_Redirect
	case:                  r.type = .Basic
	}
	opaque := r.type == .Opaque || r.type == .Opaque_Redirect
	r.status = 0
	if !opaque { jsb.host(&r.status, api_decl.Fetch_status, wj.wr_Fetch_status, record) }
	jsb.host(&r.redirected, api_decl.Fetch_redirected, wj.wr_Fetch_redirected, record)
	r.signal = wj.JS_DupValue(ctx, signal)
	wj.JS_FreeValue(ctx, r.status_text)
	r.status_text = wj.new_string(ctx, opaque ? "" : status_text(r.status))
	r.headers = web_headers_new(ctx, .Immutable)
	if wj.is_exception(r.headers) { r.headers = wj.UNDEFINED; response_free(r); return wj.EXCEPTION }
	if !opaque {
		text: string
		jsb.host(&text, api_decl.Fetch_headers, wj.wr_Fetch_headers, record)
		if len(text) > 0 { headers_fill_lines(headers_of(r.headers), text) }
		url: string
		jsb.host(&url, api_decl.Fetch_url, wj.wr_Fetch_url, record)
		wj.JS_FreeValue(ctx, r.url)
		r.url = wj.new_string_len(ctx, url)
		r.body = Body_Host{record = record}
	}
	return response_object(ctx, wj.UNDEFINED, r)
}

// ---- fetch() ----

// data: the request's signal
@(private = "file")
on_fetch_settled :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = wj.heap_context()
	record := api_decl.Fetch(value)
	if state == 1 {
		if !web_signal_aborted(data) { return response_from_host(ctx, record, data) }
		// aborted while the fulfilment was queued
		jsb.host(&none_fetch, api_decl.Fetch_release, wj.wr_Fetch_release, record)
	}
	reject^ = true
	return failure_reason(ctx, host, data)
}

// blob: URLs of this realm: a Response made here (GET only)
@(private = "file")
fetch_blob_url :: proc(ctx: ^wj.Context, r: ^Fetch_Request, blob: wj.JSValue) -> wj.JSValue {
	if !js_string_in(ctx, r.method, "GET") || wj.is_undefined(blob) {
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to fetch"))
	}
	bytes, _ := blob_slice(blob)
	res := response_new_impl(ctx)
	if res == nil { return wj.web_promise_reject_pending(ctx) }
	res.type = .Basic
	wj.JS_FreeValue(ctx, res.status_text)
	res.status_text = js_str(ctx, "OK")
	wj.JS_FreeValue(ctx, res.url)
	res.url = wj.JS_DupValue(ctx, r.url)
	res.signal = wj.JS_DupValue(ctx, r.signal)
	res.headers = web_headers_new(ctx, .Immutable)
	if h := headers_of(res.headers); h != nil {
		t := web_blob_type(ctx, blob)
		if ts, c, ok := wj.to_string_view(ctx, t); ok { headers_push(h, "content-type", ts); wj.free_cstring(ctx, c) }
		wj.JS_FreeValue(ctx, t)
		digits: [24]u8
		n := len(bytes)
		k := len(digits)
		for {
			k -= 1
			digits[k] = u8('0' + n % 10)
			n /= 10
			if n == 0 { break }
		}
		headers_push(h, "content-length", string(digits[k:]))
	}
	data, _ := clone_bytes(bytes)
	res.body = Body_Bytes{data = data}
	obj := response_object(ctx, wj.UNDEFINED, res)
	if wj.is_exception(obj) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, obj)
}

// A span for a wire argument: an empty one keeps a valid pointer, as the C passed "".
@(private = "file")
span :: #force_inline proc "contextless" (b: []u8) -> string {
	return len(b) > 0 ? string(b) : string(wj.empty_ptr()[:0])
}

// RequestMode as the browser takes it (navigate goes as cors).
@(private = "file")
fetch_mode :: proc "contextless" (m: Mode) -> api_decl.FetchMode {
	#partial switch m {
	case .Same_Origin: return .Same_Origin
	case .No_Cors:     return .No_Cors
	}
	return .Cors
}

@(private = "file")
fetch_start :: proc(ctx: ^wj.Context, r: ^Fetch_Request, body: Maybe([]u8)) -> wj.JSValue {
	u, uc, uok := wj.to_string_view(ctx, r.url)
	if !uok { return wj.web_promise_reject_pending(ctx) }
	defer wj.free_cstring(ctx, uc)
	m, mc, mok := wj.to_string_view(ctx, r.method)
	if !mok { return wj.web_promise_reject_pending(ctx) }
	defer wj.free_cstring(ctx, mc)
	hb: [dynamic]u8
	defer delete(hb)
	headers_serialize(headers_of(r.headers), &hb)
	no_referrer := js_string_in(ctx, r.referrer, "")
	b: Maybe(string)
	if bytes, has := body.?; has { b = span(bytes) }
	pr: api_decl.Promise
	st := jsb.host12(&pr, api_decl.Fetch_promise, wj.wr_Fetch_promise, u, m, span(hb[:]), b, api_decl.Buffer(0),
		api_decl.AbortSignal(web_signal_handle(r.signal)), fetch_mode(r.mode), r.credentials, r.redirect, r.referrer_policy,
		no_referrer, r.cache)
	if st != .None { wj.wj_throw_status(ctx, i32(st), "fetch"); return wj.web_promise_reject_pending(ctx) }
	return wj.wj_promise_from_host(ctx, u64(pr), wj.HOST_UNDEFINED, on_fetch_settled, r.signal)
}

// a stream body read whole, then the request: data = [request object]
@(private = "file")
on_fetch_body :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := request_of(data[0])
	if r == nil { return wj.wj_throw_type(ctx, "the request is gone") }
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, 0), &p, &n, 0, "fetch") { return wj.EXCEPTION }
	return fetch_start(ctx, r, p[:n] if p != nil else []u8{})
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_fetch")
wjr_WindowOrWorkerGlobalScope_fetch :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if argc < 1 { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'fetch': 1 argument required, but only 0 present.")) }
	r := new(Fetch_Request)
	if r == nil { return wj.web_promise_reject_pending(ctx) }
	if !request_build(ctx, r, argv[0], wj.arg(argc, argv, 1)) { request_free(r); return wj.web_promise_reject_pending(ctx) }
	req := request_object(ctx, wj.UNDEFINED, r)
	if wj.is_exception(req) { return wj.web_promise_reject_pending(ctx) }
	defer wj.JS_FreeValue(ctx, req)
	if web_signal_aborted(r.signal) { return wj.web_promise_rejected(ctx, web_signal_reason(ctx, r.signal)) }
	u, uc, uok := wj.to_string_view(ctx, r.url)
	if uok && len(u) >= 5 && u[:5] == "blob:" {
		blob := web_blob_url_lookup(ctx, raw_data(u), uint(len(u)))
		wj.free_cstring(ctx, uc)
		defer wj.JS_FreeValue(ctx, blob)
		return fetch_blob_url(ctx, r, blob)
	}
	if uok { wj.free_cstring(ctx, uc) } else { wj.drop_exception(ctx) }
	switch k in r.body {
	case Body_Stream:
		all := web_stream_read_all(ctx, k.stream)
		defer wj.JS_FreeValue(ctx, all)
		return then_with(ctx, all, on_fetch_body, nil, req)
	case Body_Bytes:
		return fetch_start(ctx, r, k.data != nil ? k.data : []u8{})
	case Body_Host:
	}
	return fetch_start(ctx, r, nil)
}
