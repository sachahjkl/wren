// web_xhr.odin: XMLHttpRequest (XMLHttpRequest Standard) on the browser's fetch with a callback (module fetch:
// Fetch_startWithSignal), so CORS, cookies, CSP and the rest of the page's policy apply as for fetch(). Ported from
// native/js/runtime/web_xhr.c: same wjr_* symbols and export (wj_cb_xhr).
//
// The browser reports the response headers, then the end of the body (or a failure): the states follow (OPENED,
// HEADERS_RECEIVED, LOADING, DONE) with their readystatechange, progress, load / error / abort / timeout and loadend
// events, upload events when there is a body. The body is copied once into the engine when it is complete; responseText,
// response (text, json, arraybuffer, blob) are made from it on demand. A request in flight keeps its object alive.
// timeout uses a timeout signal of the browser; abort() releases the request (no callback comes after it).
// Synchronous requests: a worker's thread waits for them (Fetch_sync); a document's are not supported (send() throws a
// NetworkError, as for a network failure; the console says why). Not supported: responseType "document" (response is
// null), progress events while the body arrives (one before load).
//
// Every call into the browser is a declaration of api_decl/fetch.odin (and abort.odin) through jsb.host.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") none: abi.Nothing

@(private = "file") State :: enum i32 { Unsent, Opened, Headers_Received, Loading, Done }
@(private = "file") Response_Type :: enum i32 { Empty, Array_Buffer, Blob, Document, JSON, Text }
@(private = "file") RESPONSE_TYPES := [Response_Type]cstring{.Empty = "", .Array_Buffer = "arraybuffer", .Blob = "blob", .Document = "document", .JSON = "json", .Text = "text"}

@(private = "file")
Xhr :: struct {
	state:                State,
	rtype:                Response_Type,
	send_flag:            bool,
	sync:                 bool,
	upload_complete:      bool,
	upload_listener:      bool,
	with_credentials:     bool,
	failed:               bool,
	body_done:            bool,
	timeout:              u32,
	method:               wj.JSValue,
	url:                  wj.JSValue,
	headers:              wj.JSValue,
	upload:               wj.JSValue,
	mime_override:        wj.JSValue,
	fetch:                api_decl.Fetch,         // the request in flight
	signal:               api_decl.AbortSignal,   // its timeout signal (owned)
	pin:                  u32,
	slot:                 u32,
	status:               i32,
	status_text:          wj.JSValue,
	response_url:         wj.JSValue,
	response_headers:     wj.JSValue,
	body:                 [dynamic]u8,
	response:             wj.JSValue,             // the response of the current responseType, once made
	self:                 wj.JSValue,             // not counted
}
// The internal callbacks: slot -> the object (not counted; cleared when the wrapper dies). Slot 0 is never used.
@(private = "file") xhr_slots: [dynamic]^wj.Obj

@(private = "file")
xhr_slot :: proc(o: ^wj.Obj) -> u32 {
	for i in 1 ..< len(xhr_slots) {
		if xhr_slots[i] == nil { xhr_slots[i] = o; return u32(i) }
	}
	if len(xhr_slots) == 0 && append(&xhr_slots, nil) != 1 { return 0 }
	if append(&xhr_slots, o) != 1 { return 0 }
	return u32(len(xhr_slots) - 1)
}

// Cancels the request in flight and its timeout signal.
@(private = "file")
release_request :: proc(x: ^Xhr) {
	if x.fetch != 0 {
		jsb.host(&none, api_decl.Fetch_release, wj.wr_Fetch_release, x.fetch)
		x.fetch = 0
	}
	if x.signal != 0 {
		jsb.host(&none, api_decl.Object_release, wj.wr_Object_release, abi.Handle(x.signal))
		x.signal = 0
	}
}

@(private = "file")
xhr_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	x := (^Xhr)(p)
	rt := wj.web_rt()
	release_request(x)
	if x.slot != 0 && int(x.slot) < len(xhr_slots) { xhr_slots[x.slot] = nil }
	for v in ([?]wj.JSValue{x.method, x.url, x.headers, x.upload, x.mime_override, x.status_text, x.response_url, x.response_headers, x.response}) {
		wj.JS_FreeValueRT(rt, v)
	}
	delete(x.body)
	free(x)
}

@(private = "file")
xhr_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	x := (^Xhr)(p)
	for v in ([?]wj.JSValue{x.method, x.url, x.headers, x.upload, x.mime_override, x.status_text, x.response_url, x.response_headers, x.response}) {
		wj.wj_mark(rt, v, mark_func)
	}
}

@(private = "file")
xhr_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Xhr {
	return (^Xhr)(wj.this_impl(ctx, this_val, ifc("XMLHttpRequest")))
}

@(export, link_name = "wjr_XMLHttpRequest_constructor")
wjr_XMLHttpRequest_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor XMLHttpRequest requires 'new'") }
	obj := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("XMLHttpRequest"), new_target)
	if wj.is_exception(obj) { return obj }
	x := new(Xhr)
	if x == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	x.method, x.url, x.headers, x.upload, x.mime_override = wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	x.response_headers, x.response = wj.UNDEFINED, wj.UNDEFINED
	x.status_text = wj.new_string(ctx, "")
	x.response_url = wj.new_string(ctx, "")
	x.self = obj
	wj.web_set_impl(obj, x, xhr_free, xhr_mark)
	x.upload = wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), ifc("XMLHttpRequestUpload"), wj.UNDEFINED)
	if wj.is_exception(x.upload) { x.upload = wj.UNDEFINED; wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// ---- events ----

@(private = "file")
fire_progress :: proc(ctx: ^wj.Context, target: wj.JSValue, type: cstring, loaded, total: f64, computable: bool) {
	ev := wj.web_event_new(ctx, ifc("ProgressEvent"), type, false, false)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_extra_set(ctx, ev, "lengthComputable", wj.new_bool(computable))
	wj.web_extra_set(ctx, ev, "loaded", wj.new_float64(ctx, loaded))
	wj.web_extra_set(ctx, ev, "total", wj.new_float64(ctx, total))
	wj.web_event_fire(ctx, target, ev)
	wj.JS_FreeValue(ctx, ev)
}

@(private = "file")
set_state :: proc(ctx: ^wj.Context, x: ^Xhr, state: State) {
	x.state = state
	wj.web_fire_simple(ctx, x.self, "readystatechange")
}

@(private = "file")
reset_response :: proc(ctx: ^wj.Context, x: ^Xhr) {
	x.status = 0
	x.failed = false
	wj.JS_FreeValue(ctx, x.status_text); x.status_text = wj.new_string(ctx, "")
	wj.JS_FreeValue(ctx, x.response_url); x.response_url = wj.new_string(ctx, "")
	wj.JS_FreeValue(ctx, x.response_headers); x.response_headers = wj.UNDEFINED
	wj.JS_FreeValue(ctx, x.response); x.response = wj.UNDEFINED
	clear(&x.body)
	x.body_done = false
}

@(private = "file")
unpin :: proc(ctx: ^wj.Context, x: ^Xhr) {
	if x.pin != 0 { p := x.pin; x.pin = 0; wj.web_unpin(ctx, p) }
}

// XHR "request error steps": event is "error", "abort" or "timeout".
@(private = "file")
request_error :: proc(ctx: ^wj.Context, x: ^Xhr, event: cstring) {
	x.state = .Done
	x.send_flag = false
	reset_response(ctx, x)
	x.failed = true
	wj.web_fire_simple(ctx, x.self, "readystatechange")
	if !x.upload_complete {
		x.upload_complete = true
		if x.upload_listener {
			fire_progress(ctx, x.upload, event, 0, 0, false)
			fire_progress(ctx, x.upload, "loadend", 0, 0, false)
		}
	}
	fire_progress(ctx, x.self, event, 0, 0, false)
	fire_progress(ctx, x.self, "loadend", 0, 0, false)
}

// The response record's status, URL and headers (an opaque response shows none of them).
@(private = "file")
take_head :: proc(ctx: ^wj.Context, x: ^Xhr, f: api_decl.Fetch) {
	type: api_decl.ResponseType
	jsb.host(&type, api_decl.Fetch_type, wj.wr_Fetch_type, f)
	opaque := type == .Opaque || type == .Opaque_Redirect
	x.status = 0
	if !opaque { jsb.host(&x.status, api_decl.Fetch_status, wj.wr_Fetch_status, f) }
	wj.JS_FreeValue(ctx, x.status_text)
	x.status_text = wj.new_string(ctx, opaque ? "" : web_status_text(x.status))
	url: string
	jsb.host(&url, api_decl.Fetch_url, wj.wr_Fetch_url, f)
	wj.JS_FreeValue(ctx, x.response_url)
	x.response_url = wj.new_string_len(ctx, url)
	wj.JS_FreeValue(ctx, x.response_headers)
	x.response_headers = web_headers_new(ctx, .Immutable)
	if !opaque {
		lines: string
		jsb.host(&lines, api_decl.Fetch_headers, wj.wr_Fetch_headers, f)
		if len(lines) > 0 { web_headers_fill_lines(ctx, x.response_headers, raw_data(lines), uint(len(lines))) }
	}
}

// The whole body of the record, in one copy.
@(private = "file")
take_body :: proc(x: ^Xhr, f: api_decl.Fetch) {
	n: u64
	jsb.host(&n, api_decl.Fetch_bodyLength, wj.wr_Fetch_bodyLength, f)
	clear(&x.body)
	// a length past the address space (the size is 32 bits here) is out of memory, not a truncated buffer
	if n < u64(max(u32)) {
		resize(&x.body, int(n))
		filled := 0
		for filled < len(x.body) {
			chunk := min(len(x.body) - filled, 0x4000_0000)
			got: i32
			jsb.host(&got, api_decl.Fetch_readBody, wj.wr_Fetch_readBody, f, u64(filled), x.body[filled:][:chunk])
			if got <= 0 { break }
			filled += int(got)
		}
		resize(&x.body, filled)
	}
	x.body_done = true
}

// The browser calls back: headers (1), the whole body (2), or a failure (3).
@(export, link_name = "wj_cb_xhr")
wj_cb_xhr :: proc "c" (user: i32, fetch: u64, state: i32) {
	context = wj.heap_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || int(user) >= len(xhr_slots) || xhr_slots[user] == nil { return }
	x := (^Xhr)(xhr_slots[user].impl)
	f := api_decl.Fetch(fetch)
	if x == nil || x.fetch != f || !x.send_flag { return }
	self := wj.JS_DupValue(ctx, x.self)   // kept through the events
	defer wj.JS_FreeValue(ctx, self)
	#partial switch api_decl.FetchState(state) {
	case .Response:
		// upload done, headers received
		if !x.upload_complete {
			x.upload_complete = true
			if x.upload_listener {
				fire_progress(ctx, x.upload, "progress", 0, 0, false)
				fire_progress(ctx, x.upload, "load", 0, 0, false)
				fire_progress(ctx, x.upload, "loadend", 0, 0, false)
			}
			if x.fetch != f { return }
		}
		take_head(ctx, x, f)
		set_state(ctx, x, .Headers_Received)
	case .Done:
		if x.state == .Headers_Received { set_state(ctx, x, .Loading) }
		if x.fetch != f { return }
		take_body(x, f)
		computable := false
		if wj.is_object(x.response_headers) {
			length: uint
			if cl := web_headers_get(x.response_headers, "content-length", &length); cl != nil {
				computable = true
				wj.libc_free(cl)
			}
		}
		release_request(x)
		loaded := f64(len(x.body))
		total := computable ? loaded : 0
		fire_progress(ctx, x.self, "progress", loaded, total, computable)
		x.state = .Done
		x.send_flag = false
		wj.web_fire_simple(ctx, x.self, "readystatechange")
		fire_progress(ctx, x.self, "load", loaded, total, computable)
		fire_progress(ctx, x.self, "loadend", loaded, total, computable)
		unpin(ctx, x)
	case .Failed:
		// our timeout signal aborted it: timeout; anything else: a network error
		timed_out := false
		if x.signal != 0 { jsb.host(&timed_out, api_decl.AbortSignal_aborted, wj.wr_AbortSignal_aborted, x.signal) }
		release_request(x)
		request_error(ctx, x, timed_out ? "timeout" : "error")
		unpin(ctx, x)
	}
}

// ---- request ----

// An HTTP token (a method or a header name).
@(private = "file")
valid_token :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 { return false }
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		switch c {
		case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~': ok = true
		}
		if !ok { return false }
	}
	return true
}

@(export, link_name = "wjr_XMLHttpRequest_open")
wjr_XMLHttpRequest_open :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "XMLHttpRequest.open", 2, argc) }
	m, u: wj.Str
	if !wj.web_to_bytestring(ctx, argv[0], &m) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &m)
	method := str_view(m)
	if !valid_token(method) { return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'open' on 'XMLHttpRequest': Invalid method.") }
	if ascii_ieq(method, "connect") || ascii_ieq(method, "trace") || ascii_ieq(method, "track") {
		return wj.wj_throw_dom(ctx, "SecurityError", "Failed to execute 'open' on 'XMLHttpRequest': the method is forbidden.")
	}
	if !wj.web_to_usv(ctx, argv[1], &u) { return wj.EXCEPTION }
	abs: wj.Str
	if !web_resolve_url(ctx, u.ptr, u.len, &abs) {
		wj.drop_exception(ctx)
		wj.wj_str_free(ctx, &u)
		return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'open' on 'XMLHttpRequest': Invalid URL")
	}
	wj.wj_str_free(ctx, &u)
	defer wj.libc_free(rawptr(abs.ptr))
	async := argc < 3 || wj.JS_ToBool(ctx, argv[2]) != 0
	if !async && wj.is_window() && (x.timeout != 0 || x.rtype != .Empty) {
		return wj.wj_throw_dom(ctx, "InvalidAccessError", "Failed to execute 'open' on 'XMLHttpRequest': Synchronous requests from a document must not set a timeout or a responseType.")
	}
	// terminate the ongoing request
	release_request(x)
	unpin(ctx, x)
	wj.JS_FreeValue(ctx, x.method)
	x.method = wj.UNDEFINED
	for norm in ([?]cstring{"DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"}) {
		if ascii_ieq(method, string(norm)) { x.method = wj.new_string(ctx, norm); break }
	}
	if wj.is_undefined(x.method) { x.method = wj.new_string_len(ctx, method) }
	wj.JS_FreeValue(ctx, x.url)
	x.url = wj.new_string_len(ctx, str_view(abs))
	wj.JS_FreeValue(ctx, x.headers)
	x.headers = web_headers_new(ctx, .None)
	x.sync = !async
	x.send_flag = false
	x.upload_listener = false
	reset_response(ctx, x)
	if x.state != .Opened { set_state(ctx, x, .Opened) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_XMLHttpRequest_setRequestHeader")
wjr_XMLHttpRequest_setRequestHeader :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "XMLHttpRequest.setRequestHeader", 2, argc) }
	if x.state != .Opened || x.send_flag {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': The object's state must be OPENED.")
	}
	n, v: wj.Str
	if !wj.web_to_bytestring(ctx, argv[0], &n) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &n)
	if !wj.web_to_bytestring(ctx, argv[1], &v) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &v)
	// the value without its leading and trailing whitespace
	value := str_view(v)
	is_space :: proc "contextless" (c: u8) -> bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' }
	for len(value) > 0 && is_space(value[0]) { value = value[1:] }
	for len(value) > 0 && is_space(value[len(value) - 1]) { value = value[:len(value) - 1] }
	bad_value := false
	for c in transmute([]u8)value { if c == 0 || c == '\r' || c == '\n' { bad_value = true; break } }
	switch {
	case !valid_token(str_view(n)):
		return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': Invalid header name.")
	case bad_value:
		return wj.wj_throw_dom(ctx, "SyntaxError", "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': Invalid header value.")
	case !web_forbidden_request_header(n.ptr, n.len, raw_data(value), uint(len(value))):
		// a forbidden request-header is ignored
		web_headers_append_raw(x.headers, n.ptr, n.len, raw_data(value), uint(len(value)))
	}
	return wj.UNDEFINED
}

// The response of a finished request record: status, URL, headers, the whole body (wj_cb_xhr does the same in steps).
@(private = "file")
take_response :: proc(ctx: ^wj.Context, x: ^Xhr, f: api_decl.Fetch) {
	take_head(ctx, x, f)
	take_body(x, f)
}

// The body of a request: its bytes, or absent for none.
@(private = "file")
body_of :: proc(e: ^wj.Extracted, has_body: bool) -> Maybe(string) {
	if !has_body { return nil }
	return string(e.data != nil ? e.data[:e.len] : wj.empty_ptr()[:0])
}

// send() of a synchronous request (XHR "send" step 12): a worker's thread waits for it (Fetch_sync); a document's
// cannot (its thread is the page's: the console says so and it fails as a network error would). Only the final
// readystatechange, load and loadend fire; a failure throws instead.
@(private = "file")
send_sync :: proc(ctx: ^wj.Context, x: ^Xhr, method: string, has_body: bool, e: ^wj.Extracted) -> wj.JSValue {
	c, url := to_text(ctx, x.url)
	if c == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, c)
	hb: wj.Web_Buf
	defer wj.web_buf_free(&hb)
	web_headers_serialize(x.headers, &hb)
	f: api_decl.Fetch
	st := jsb.host(&f, api_decl.Fetch_sync, wj.wr_Fetch_sync, url, method, string(wj.web_buf_bytes(&hb)), body_of(e, has_body),
		api_decl.FetchMode.Cors, x.with_credentials ? api_decl.Credentials.Include : api_decl.Credentials.Same_Origin,
		api_decl.RedirectMode.Follow, api_decl.ReferrerPolicy.Default, false, api_decl.RequestCache.Default, x.timeout)
	if st != .None || f == 0 {
		x.state = .Done
		x.send_flag = false
		reset_response(ctx, x)
		x.failed = true
		if st == .Not_Supported {
			warn := "XMLHttpRequest: a document's synchronous requests are not supported by this browser (a worker's are)"
			wj.wj_console_text(i32(wj.wr_ConsoleLevel.Warn), raw_data(warn), uint(len(warn)))
			return wj.wj_throw_dom(ctx, "NetworkError", "Failed to execute 'send' on 'XMLHttpRequest': synchronous requests of a document are not supported")
		}
		return wj.wj_throw_dom(ctx, st == .Timeout ? "TimeoutError" : "NetworkError", "Failed to execute 'send' on 'XMLHttpRequest': the request failed.")
	}
	take_response(ctx, x, f)
	jsb.host(&none, api_decl.Fetch_release, wj.wr_Fetch_release, f)
	x.upload_complete = true
	x.state = .Done
	x.send_flag = false
	wj.web_fire_simple(ctx, x.self, "readystatechange")
	loaded := f64(len(x.body))
	fire_progress(ctx, x.self, "load", loaded, loaded, true)
	fire_progress(ctx, x.self, "loadend", loaded, loaded, true)
	return wj.UNDEFINED
}

// A request answered here: a blob: URL of this realm.
@(private = "file")
answer_blob :: proc(ctx: ^wj.Context, x: ^Xhr, blob: wj.JSValue) {
	bytes: [^]u8
	n: uint
	web_blob_bytes(blob, &bytes, &n)
	x.status = 200
	wj.JS_FreeValue(ctx, x.status_text); x.status_text = wj.new_string(ctx, "OK")
	wj.JS_FreeValue(ctx, x.response_url); x.response_url = wj.JS_DupValue(ctx, x.url)
	x.response_headers = web_headers_new(ctx, .Immutable)
	t := web_blob_type(ctx, blob)
	if c, text := to_text(ctx, t); c != nil {
		web_headers_append_raw(x.response_headers, wj.raw_bytes("content-type"), 12, raw_data(text), uint(len(text)))
		wj.JS_FreeCString(ctx, c)
	}
	wj.JS_FreeValue(ctx, t)
	clear(&x.body)
	append(&x.body, ..bytes[:n])
	x.body_done = true
	wj.JS_FreeValue(ctx, blob)
	set_state(ctx, x, .Headers_Received)
	if x.send_flag { set_state(ctx, x, .Loading) }
	if x.send_flag {
		size := f64(n)
		fire_progress(ctx, x.self, "progress", size, size, true)
		x.state = .Done
		x.send_flag = false
		wj.web_fire_simple(ctx, x.self, "readystatechange")
		fire_progress(ctx, x.self, "load", size, size, true)
		fire_progress(ctx, x.self, "loadend", size, size, true)
	}
}

@(export, link_name = "wjr_XMLHttpRequest_send")
wjr_XMLHttpRequest_send :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if x.state != .Opened || x.send_flag {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'send' on 'XMLHttpRequest': The object's state must be OPENED.")
	}
	mc, method := to_text(ctx, x.method)
	if mc == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, mc)
	get_head := method == "GET" || method == "HEAD"
	bodyv := wj.arg(argc, argv, 0)
	e := wj.Extracted{stream = wj.UNDEFINED}
	defer web_extracted_free(ctx, &e)
	has_body := !get_head && !wj.is_undefined(bodyv) && !wj.is_null(bodyv)
	if has_body {
		if wj.wj_unwrap(bodyv, ifc("Document")) != nil {
			// a Document body: its markup is the dom part's (serialized as a string here)
			s := wj.JS_ToString(ctx, bodyv)
			if wj.is_exception(s) { return s }
			ok := web_extract_body(ctx, s, &e, "XMLHttpRequest.send")
			wj.JS_FreeValue(ctx, s)
			if !ok { return wj.EXCEPTION }
		} else if web_stream_is(bodyv) || !web_extract_body(ctx, bodyv, &e, "XMLHttpRequest.send") {
			if !wj.JS_HasException(ctx) {
				wj.JS_ThrowTypeError(ctx, "Failed to execute 'send' on 'XMLHttpRequest': a ReadableStream body is not supported")
			}
			return wj.EXCEPTION
		}
		if e.type != nil && !web_headers_has(x.headers, "content-type") {
			web_headers_append_raw(x.headers, wj.raw_bytes("Content-Type"), 12, ([^]u8)(rawptr(e.type)), wj.strlen(e.type))
		}
	}
	if x.sync { return send_sync(ctx, x, method, has_body, &e) }
	x.upload_complete = !has_body
	x.send_flag = true
	// listeners on upload when send() is called: upload events are fired
	uo := wj.obj_of(x.upload)
	x.upload_listener = uo != nil && uo.listeners != nil
	fire_progress(ctx, x.self, "loadstart", 0, 0, false)
	if x.upload_listener && !x.upload_complete { fire_progress(ctx, x.upload, "loadstart", 0, f64(e.len), true) }
	if x.state != .Opened || !x.send_flag { return wj.UNDEFINED }
	uc, url := to_text(ctx, x.url)
	defer if uc != nil { wj.JS_FreeCString(ctx, uc) }
	// blob: URLs of this realm are answered here
	blob := uc != nil ? web_blob_url_lookup(ctx, raw_data(url), uint(len(url))) : wj.UNDEFINED
	if !wj.is_undefined(blob) {
		answer_blob(ctx, x, blob)
		return wj.UNDEFINED
	}
	if len(url) >= 5 && url[:5] == "blob:" {
		request_error(ctx, x, "error")
		return wj.UNDEFINED
	}
	hb: wj.Web_Buf
	defer wj.web_buf_free(&hb)
	web_headers_serialize(x.headers, &hb)
	if x.timeout > 0 {
		sig: api_decl.AbortSignal
		if jsb.host(&sig, api_decl.AbortSignal_timeout, wj.wr_AbortSignal_timeout, f64(x.timeout)) == .None { x.signal = sig }
	}
	if x.slot == 0 { x.slot = xhr_slot(wj.obj_of(x.self)) }
	f: api_decl.Fetch
	st := jsb.host(&f, api_decl.Fetch_startWithSignal, wj.wr_Fetch_startWithSignal, url, wj.table_index(rawptr(wj_cb_xhr)), i32(x.slot), method,
		string(wj.web_buf_bytes(&hb)), body_of(&e, has_body), api_decl.Buffer(0), x.signal, api_decl.FetchMode.Cors,
		x.with_credentials ? api_decl.Credentials.Include : api_decl.Credentials.Same_Origin, api_decl.RedirectMode.Follow,
		api_decl.ReferrerPolicy.Default, false, api_decl.RequestCache.Default)
	if st != .None || f == 0 {
		request_error(ctx, x, "error")
		return wj.UNDEFINED
	}
	x.fetch = f
	if x.pin == 0 { x.pin = wj.web_pin(ctx, x.self) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_XMLHttpRequest_abort")
wjr_XMLHttpRequest_abort :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	release_request(x)
	if (x.state == .Opened && x.send_flag) || x.state == .Headers_Received || x.state == .Loading { request_error(ctx, x, "abort") }
	if x.state == .Done {
		x.state = .Unsent
		reset_response(ctx, x)
		x.failed = true
	}
	unpin(ctx, x)
	return wj.UNDEFINED
}

// ---- attributes ----

@(export, link_name = "wjr_XMLHttpRequest_get_readyState")
wjr_XMLHttpRequest_get_readyState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.new_int32(i32(x.state)) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_status")
wjr_XMLHttpRequest_get_status :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.new_int32(x.failed ? 0 : x.status) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_statusText")
wjr_XMLHttpRequest_get_statusText :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.JS_DupValue(ctx, x.status_text) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_responseURL")
wjr_XMLHttpRequest_get_responseURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.JS_DupValue(ctx, x.response_url) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_upload")
wjr_XMLHttpRequest_get_upload :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.JS_DupValue(ctx, x.upload) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_withCredentials")
wjr_XMLHttpRequest_get_withCredentials :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.new_bool(x.with_credentials) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_timeout")
wjr_XMLHttpRequest_get_timeout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.new_uint32(ctx, x.timeout) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_responseType")
wjr_XMLHttpRequest_get_responseType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	return x != nil ? wj.new_string(ctx, RESPONSE_TYPES[x.rtype]) : wj.EXCEPTION
}
@(export, link_name = "wjr_XMLHttpRequest_get_responseXML")
wjr_XMLHttpRequest_get_responseXML :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return xhr_this(ctx, this_val) != nil ? wj.NULL : wj.EXCEPTION
}

@(export, link_name = "wjr_XMLHttpRequest_set_withCredentials")
wjr_XMLHttpRequest_set_withCredentials :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if (x.state != .Unsent && x.state != .Opened) || x.send_flag {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to set 'withCredentials' on 'XMLHttpRequest': The value may only be set if the object's state is UNSENT or OPENED.")
	}
	x.with_credentials = wj.JS_ToBool(ctx, v) != 0
	return wj.UNDEFINED
}

@(export, link_name = "wjr_XMLHttpRequest_set_timeout")
wjr_XMLHttpRequest_set_timeout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	t: u32
	if !wj.wj_to_uint32(ctx, v, &t, 32, 0) { return wj.EXCEPTION }
	if x.sync && wj.is_window() {
		return wj.wj_throw_dom(ctx, "InvalidAccessError", "Failed to set 'timeout' on 'XMLHttpRequest': Timeouts cannot be set for synchronous requests made from a document.")
	}
	x.timeout = t
	return wj.UNDEFINED
}

@(export, link_name = "wjr_XMLHttpRequest_set_responseType")
wjr_XMLHttpRequest_set_responseType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	c, text := to_text(ctx, v)
	if c == nil { return wj.EXCEPTION }
	defer wj.JS_FreeCString(ctx, c)
	t: Response_Type
	found := false
	for name, which in RESPONSE_TYPES {
		if text == string(name) { t = which; found = true; break }
	}
	if !found { return wj.UNDEFINED }   // not an XMLHttpRequestResponseType: ignored (Web IDL enum attribute)
	if t == .Document && !wj.is_window() { return wj.UNDEFINED }
	if x.state == .Loading || x.state == .Done {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to set 'responseType' on 'XMLHttpRequest': The response type cannot be set if the object's state is LOADING or DONE.")
	}
	if x.sync && wj.is_window() {
		return wj.wj_throw_dom(ctx, "InvalidAccessError", "Failed to set 'responseType' on 'XMLHttpRequest': The response type cannot be changed for synchronous requests made from a document.")
	}
	x.rtype = t
	return wj.UNDEFINED
}

@(export, link_name = "wjr_XMLHttpRequest_overrideMimeType")
wjr_XMLHttpRequest_overrideMimeType :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "XMLHttpRequest.overrideMimeType", 1, argc) }
	if x.state == .Loading || x.state == .Done {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'overrideMimeType' on 'XMLHttpRequest': MimeType cannot be overridden when the state is LOADING or DONE.")
	}
	wj.JS_FreeValue(ctx, x.mime_override)
	x.mime_override = wj.JS_ToString(ctx, argv[0])
	if wj.is_exception(x.mime_override) { x.mime_override = wj.UNDEFINED; return wj.EXCEPTION }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_XMLHttpRequest_getResponseHeader")
wjr_XMLHttpRequest_getResponseHeader :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "XMLHttpRequest.getResponseHeader", 1, argc) }
	if x.failed || x.state < .Headers_Received || wj.is_undefined(x.response_headers) { return wj.NULL }
	n: wj.Str
	if !wj.web_to_bytestring(ctx, argv[0], &n) { return wj.EXCEPTION }
	name := wj.web_strndup(n.ptr, n.len)
	wj.wj_str_free(ctx, &n)
	if name == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(name)
	length: uint
	v := web_headers_get(x.response_headers, wj.cstr(name), &length)
	if v == nil { return wj.NULL }
	defer wj.libc_free(v)
	return wj.new_string_len(ctx, v[:length])
}

@(export, link_name = "wjr_XMLHttpRequest_getAllResponseHeaders")
wjr_XMLHttpRequest_getAllResponseHeaders :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if x.failed || x.state < .Headers_Received || wj.is_undefined(x.response_headers) { return wj.new_string(ctx, "") }
	sorted := web_headers_sorted(ctx, x.response_headers)
	if wj.is_exception(sorted) { return sorted }
	defer wj.JS_FreeValue(ctx, sorted)
	text: [dynamic]u8
	defer delete(text)
	n: i64
	wj.JS_GetLength(ctx, sorted, &n)
	for i in 0 ..< n {
		pair := wj.JS_GetPropertyUint32(ctx, sorted, u32(i))
		k, v := wj.JS_GetPropertyUint32(ctx, pair, 0), wj.JS_GetPropertyUint32(ctx, pair, 1)
		kc, ks := to_text(ctx, k)
		vc, vs := to_text(ctx, v)
		if kc != nil && vc != nil {
			append(&text, ..transmute([]u8)ks)
			append(&text, ": ")
			append(&text, ..transmute([]u8)vs)
			append(&text, "\r\n")
		}
		if kc != nil { wj.JS_FreeCString(ctx, kc) }
		if vc != nil { wj.JS_FreeCString(ctx, vc) }
		wj.free_values(ctx, k, v, pair)
	}
	return wj.new_string_len(ctx, text[:])
}

// ---- response ----

// The charset of the response's MIME type (the overridden one or Content-Type's), "" when it has none.
@(private = "file")
response_charset :: proc(ctx: ^wj.Context, x: ^Xhr) -> string {
	ct: string
	if !wj.is_undefined(x.mime_override) {
		c, s := to_text(ctx, x.mime_override)
		if c != nil { defer wj.JS_FreeCString(ctx, c); ct = clone_string(s) }
	} else if !wj.is_undefined(x.response_headers) {
		n: uint
		if v := web_headers_get(x.response_headers, "content-type", &n); v != nil {
			defer wj.libc_free(v)
			ct = clone_string(string(v[:n]))
		}
	}
	if ct == "" { return "" }
	defer delete(ct, wj.libc_allocator())
	for i in 0 ..= len(ct) - 8 {
		if !ascii_ieq(ct[i:i + 8], "charset=") { continue }
		s := i + 8
		e := s
		if s < len(ct) && ct[s] == '"' {
			s += 1
			e = s
			for e < len(ct) && ct[e] != '"' { e += 1 }
		} else {
			for e < len(ct) && ct[e] != ';' && ct[e] != ' ' { e += 1 }
		}
		return clone_string(ct[s:e])
	}
	return ""
}

// A copy on the libc heap ("" for an empty string).
@(private = "file")
clone_string :: proc(s: string) -> string {
	if len(s) == 0 { return "" }
	b := make([]u8, len(s), wj.libc_allocator())
	copy(b, s)
	return string(b)
}

// The body decoded as text: the charset of the response when one is given, else UTF-8.
@(private = "file")
response_text :: proc(ctx: ^wj.Context, x: ^Xhr) -> wj.JSValue {
	cs := response_charset(ctx, x)
	defer if cs != "" { delete(cs, wj.libc_allocator()) }
	if cs == "" || ascii_ieq(cs, "utf-8") || ascii_ieq(cs, "utf8") {
		return wj.web_utf8_string(ctx, len(x.body) > 0 ? raw_data(x.body) : wj.empty_ptr(), uint(len(x.body)), true)
	}
	return decode_text(ctx, cs, x.body[:])
}

@(export, link_name = "wjr_XMLHttpRequest_get_responseText")
wjr_XMLHttpRequest_get_responseText :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if x.rtype != .Empty && x.rtype != .Text {
		return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to read the 'responseText' property from 'XMLHttpRequest': The value is only accessible if the object's 'responseType' is '' or 'text'.")
	}
	if (x.state != .Loading && x.state != .Done) || x.failed || !x.body_done { return wj.new_string(ctx, "") }
	if wj.is_undefined(x.response) {
		x.response = response_text(ctx, x)
		if wj.is_exception(x.response) { x.response = wj.UNDEFINED; return wj.EXCEPTION }
	}
	return wj.JS_DupValue(ctx, x.response)
}

@(export, link_name = "wjr_XMLHttpRequest_get_response")
wjr_XMLHttpRequest_get_response :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	x := xhr_this(ctx, this_val)
	if x == nil { return wj.EXCEPTION }
	if x.rtype == .Empty || x.rtype == .Text { return wjr_XMLHttpRequest_get_responseText(ctx, this_val) }
	if x.state != .Done || x.failed || !x.body_done { return wj.NULL }
	if !wj.is_undefined(x.response) { return wj.JS_DupValue(ctx, x.response) }
	r := wj.NULL
	#partial switch x.rtype {
	case .Array_Buffer:
		r = wj.JS_NewArrayBufferCopy(ctx, raw_data(x.body), uint(len(x.body)))
	case .Blob:
		ct: string
		if !wj.is_undefined(x.mime_override) {
			if c, s := to_text(ctx, x.mime_override); c != nil { ct = clone_string(s); wj.JS_FreeCString(ctx, c) }
		} else {
			n: uint
			if v := web_headers_get(x.response_headers, "content-type", &n); v != nil { ct = clone_string(string(v[:n])); wj.libc_free(v) }
		}
		defer if ct != "" { delete(ct, wj.libc_allocator()) }
		label := make([]u8, len(ct) + 1, wj.libc_allocator())
		defer delete(label, wj.libc_allocator())
		copy(label, ct)
		r = web_blob_new(ctx, raw_data(x.body), uint(len(x.body)), cstring(raw_data(label)), uint(len(ct)))
	case .JSON:
		s := wj.web_utf8_string(ctx, len(x.body) > 0 ? raw_data(x.body) : wj.empty_ptr(), uint(len(x.body)), true)
		c: cstring
		t: string
		if !wj.is_exception(s) { c, t = to_text(ctx, s) }
		wj.JS_FreeValue(ctx, s)
		if c != nil {
			r = wj.JS_ParseJSON(ctx, raw_data(t), uint(len(t)), "<json>")
			wj.JS_FreeCString(ctx, c)
		} else {
			r = wj.EXCEPTION
		}
		if wj.is_exception(r) { wj.drop_exception(ctx); r = wj.NULL }
	}
	if wj.is_exception(r) { return r }
	x.response = wj.JS_DupValue(ctx, r)
	return r
}
