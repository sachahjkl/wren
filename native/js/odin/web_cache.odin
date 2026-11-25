// web_cache.odin: the Cache API (CacheStorage, Cache) on the browser's storage (module caches,
// src/page/cache_store.odin, cache_api.odin). All Cache / CacheStorage host operations return host promises settled
// off the UI thread on cold index.wcs or body disk reads; match / matchAll / keys decode a packed host Buffer in one
// settlement callback. A put reads the response's body (arrayBuffer) and stores it once it is complete; add / addAll
// fetch first.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") Cache_Iface :: enum { Cache, CacheStorage, Request, Response }
@(private = "file") cache_iface_names := [Cache_Iface]cstring{ .Cache = "Cache", .CacheStorage = "CacheStorage", .Request = "Request", .Response = "Response" }
@(private = "file") cache_iface_cache := [Cache_Iface]i32{ .Cache = -2, .CacheStorage = -2, .Request = -2, .Response = -2 }

@(private = "file")
cache_iface :: proc "contextless" (i: Cache_Iface) -> i32 {
	if cache_iface_cache[i] == -2 { cache_iface_cache[i] = wj.iface(cache_iface_names[i]) }
	return cache_iface_cache[i]
}

// A Cache keeps its name.
@(private = "file")
Cache_Impl :: struct { name: wj.JSValue }

@(private = "file")
cache_free :: proc "c" (p: rawptr) {
	wj.JS_FreeValueRT(wj.web_rt(), (^Cache_Impl)(p).name)
	wj.libc_free(p)
}
@(private = "file")
cache_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Cache_Impl)(p).name, mark_func) }

@(private = "file")
global_ctor :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, wj.realm_global(), name) }

// The browser's error as a rejected promise.
@(private = "file")
reject_status :: proc "contextless" (ctx: ^wj.Context, st: abi.Api_Error, what: cstring) -> wj.JSValue {
	wj.wj_throw_status(ctx, i32(st), what)
	return wj.web_promise_reject_pending(ctx)
}

@(private = "file")
cache_reject_from_host :: proc "contextless" (ctx: ^wj.Context, host: u64, value: i64) -> wj.JSValue {
	text := wj.wj_host_promise_text(ctx, host)
	defer wj.JS_FreeValue(ctx, text)
	n: uint
	s := wj.to_cstring_len(ctx, &n, text)
	defer if s != nil { wj.free_cstring(ctx, s) }
	msg := s != nil ? string(([^]u8)(rawptr(s))[:n]) : ""
	return wj.web_error_value(ctx, i32(value), wj.raw_bytes(msg), uint(len(msg)))
}

// The options of a query (CacheQueryOptions) and the request's header lines (Vary).
@(private = "file")
Query :: struct {
	ignore_search, ignore_method, ignore_vary: bool,
	request_headers: wj.Web_Buf,
}

@(private = "file")
query_free :: proc "contextless" (q: ^Query) { wj.web_buf_free(&q.request_headers) }

@(private = "file")
query_headers :: #force_inline proc "contextless" (q: ^Query) -> string { return string(wj.web_buf_bytes(&q.request_headers)) }

// The header lines of a Request into q (nothing for a URL string)
@(private = "file")
request_headers :: proc "contextless" (v: wj.JSValue, q: ^Query) {
	if wj.wj_unwrap(v, cache_iface(.Request)) == nil { return }
	ctx := wj.realm_ctx()
	hv := wj.JS_GetPropertyStr(ctx, v, "headers")
	web_headers_serialize(hv, &q.request_headers)
	wj.JS_FreeValue(ctx, hv)
}

// RequestInfo -> the absolute URL and the method (wj_str_free both)
@(private = "file")
request_parts :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, url, method: ^wj.Str) -> bool {
	method^ = { ptr = wj.raw_bytes("GET"), len = 3, owned = false }
	if wj.wj_unwrap(v, cache_iface(.Request)) != nil {
		u := wj.JS_GetPropertyStr(ctx, v, "url")
		ok := wj.wj_to_str(ctx, u, url, 0, nil)
		wj.JS_FreeValue(ctx, u)
		if !ok { return false }
		m := wj.JS_GetPropertyStr(ctx, v, "method")
		ok = wj.wj_to_str(ctx, m, method, 0, nil)
		wj.JS_FreeValue(ctx, m)
		if !ok { wj.wj_str_free(ctx, url) }
		return ok
	}
	s: wj.Str
	if !wj.web_to_usv(ctx, v, &s) { return false }
	ok := web_resolve_url(ctx, s.ptr, s.len, url)
	wj.wj_str_free(ctx, &s)
	return ok
}

// CacheQueryOptions (and, for caches.match, its cacheName). False with an exception pending.
@(private = "file")
query_options :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, q: ^Query, cache_name: ^wj.JSValue) -> bool {
	q.ignore_search, q.ignore_method, q.ignore_vary = false, false, false
	if cache_name != nil { cache_name^ = wj.UNDEFINED }
	if !wj.web_dict_check(ctx, opt, "CacheQueryOptions") { return false }
	members := [3]struct { name: cstring, out: ^bool }{
		{ "ignoreSearch", &q.ignore_search }, { "ignoreMethod", &q.ignore_method }, { "ignoreVary", &q.ignore_vary },
	}
	for m in members {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, opt, m.name, &v) { return false }
		m.out^ = wj.JS_ToBool(ctx, v) != 0
		wj.JS_FreeValue(ctx, v)
	}
	if cache_name != nil && !wj.web_dict_get(ctx, opt, "cacheName", cache_name) { return false }
	return true
}

// "Name: value" lines into a new Headers (guard none)
@(private = "file")
headers_of :: proc "contextless" (ctx: ^wj.Context, lines: string) -> wj.JSValue {
	h := web_headers_new(ctx, .None)
	web_headers_fill_lines(ctx, h, raw_data(lines), uint(len(lines)))
	return h
}

// ---- Packed host Buffer reader (Cache_match / Cache_keys) ----

@(private = "file")
Pack_Reader :: struct {
	data: []u8,
	at:   int,
}

@(private = "file")
pack_u8 :: proc "contextless" (r: ^Pack_Reader) -> (u8, bool) {
	if len(r.data) - r.at < 1 { return 0, false }
	v := r.data[r.at]
	r.at += 1
	return v, true
}

@(private = "file")
pack_u32 :: proc "contextless" (r: ^Pack_Reader) -> (u32, bool) {
	if len(r.data) - r.at < 4 { return 0, false }
	v := u32(r.data[r.at]) | (u32(r.data[r.at + 1]) << 8) | (u32(r.data[r.at + 2]) << 16) | (u32(r.data[r.at + 3]) << 24)
	r.at += 4
	return v, true
}

@(private = "file")
pack_bytes :: proc "contextless" (r: ^Pack_Reader) -> ([]u8, bool) {
	n, ok := pack_u32(r)
	if !ok || int(n) > len(r.data) - r.at { return nil, false }
	out := r.data[r.at:r.at + int(n)]
	r.at += int(n)
	return out, true
}

@(private = "file")
pack_str :: proc "contextless" (r: ^Pack_Reader) -> (string, bool) {
	b, ok := pack_bytes(r)
	return string(b), ok
}

// Copies a host Buffer into libc heap memory and releases the host Buffer handle.
@(private = "file")
take_host_buffer :: proc "contextless" (buffer: u64) -> (mem: [^]u8, length: uint, ok: bool) {
	defer if buffer != 0 { wj.wr_Object_release(buffer) }
	n := buffer != 0 ? wj.wr_Buffer_length(buffer) : 0
	if n <= 0 { return nil, 0, true }
	p := ([^]u8)(wj.libc_malloc(uint(n)))
	if p == nil { return nil, 0, false }
	done: uint = 0
	for i64(done) < n {
		chunk := uint(n) - done
		if chunk > 0x40000000 { chunk = 0x40000000 }
		got := wj.wr_Buffer_read(buffer, i64(done), p[done:], u32(chunk))
		if got <= 0 { break }
		done += uint(got)
	}
	return p, done, true
}

@(private = "file")
decode_response :: proc "contextless" (ctx: ^wj.Context, r: ^Pack_Reader) -> wj.JSValue {
	st_u, ok1 := pack_u32(r)
	status_text, ok2 := pack_str(r)
	response_url, ok3 := pack_str(r)
	headers, ok4 := pack_str(r)
	has_body, ok5 := pack_u8(r)
	body_bytes, ok6 := pack_bytes(r)
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 { return wj.UNDEFINED }

	status := i32(st_u)
	opaque := status == 0   // (the only response stored with this status: Response's constructor refuses it)
	null_body := opaque
	switch status { case 101, 103, 204, 205, 304: null_body = true }
	if status < 200 || status > 599 { status = 200 }
	body := wj.NULL
	if !null_body && has_body != 0 {
		body = wj.JS_NewArrayBufferCopy(ctx, raw_data(body_bytes), uint(len(body_bytes)))
	}
	init := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, init, "status", wj.new_int32(status))
	wj.JS_SetPropertyStr(ctx, init, "statusText", wj.new_string_len(ctx, status_text))
	wj.JS_SetPropertyStr(ctx, init, "headers", headers_of(ctx, headers))
	ctor := global_ctor(ctx, "Response")
	args := [2]wj.JSValue{ body, init }
	resp := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
	wj.JS_FreeValue(ctx, ctor)
	wj.JS_FreeValue(ctx, body)
	wj.JS_FreeValue(ctx, init)
	if opaque {
		if !wj.is_exception(resp) { web_response_make_opaque(ctx, resp, raw_data(response_url), uint(len(response_url))) }
		return resp
	}
	// the response keeps the URL it had ("" for a Response a script constructed, as stored)
	if !wj.is_exception(resp) && len(response_url) > 0 {
		web_response_set_url(ctx, resp, raw_data(response_url), uint(len(response_url)))
	}
	return resp
}

@(private = "file")
decode_request :: proc "contextless" (ctx: ^wj.Context, r: ^Pack_Reader) -> wj.JSValue {
	url, ok1 := pack_str(r)
	req_headers, ok2 := pack_str(r)
	if !ok1 || !ok2 { return wj.UNDEFINED }
	url_v := wj.new_string_len(ctx, url)
	init := wj.JS_NewObject(ctx)
	if len(req_headers) > 0 {
		wj.JS_SetPropertyStr(ctx, init, "headers", headers_of(ctx, req_headers))
	}
	ctor := global_ctor(ctx, "Request")
	args := [2]wj.JSValue{ url_v, init }
	req := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
	wj.JS_FreeValue(ctx, ctor)
	wj.JS_FreeValue(ctx, url_v)
	wj.JS_FreeValue(ctx, init)
	return req
}

// data: bool (true for matchAll, false for match)
@(private = "file")
settle_match :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if state != 1 { reject^ = true; return cache_reject_from_host(ctx, host, value) }
	multiple := wj.JS_ToBool(ctx, data) != 0
	if value == 0 {
		if !multiple { return wj.UNDEFINED }
		arr := wj.JS_NewArray(ctx)
		wj.web_freeze(ctx, arr)
		return arr
	}
	mem, n, ok := take_host_buffer(u64(value))
	if !ok { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(mem)
	r := Pack_Reader{data = mem != nil ? mem[:n] : nil}
	count, cok := pack_u32(&r)
	if !cok || count == 0 {
		if !multiple { return wj.UNDEFINED }
		arr := wj.JS_NewArray(ctx)
		wj.web_freeze(ctx, arr)
		return arr
	}
	if !multiple {
		return decode_response(ctx, &r)
	}
	arr := wj.JS_NewArray(ctx)
	for i in u32(0) ..< count {
		v := decode_response(ctx, &r)
		if wj.is_exception(v) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) } else { wj.JS_SetPropertyUint32(ctx, arr, i, v) }
	}
	wj.web_freeze(ctx, arr)
	return arr
}

@(private = "file")
settle_keys :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if state != 1 { reject^ = true; return cache_reject_from_host(ctx, host, value) }
	arr := wj.JS_NewArray(ctx)
	if value != 0 {
		mem, n, ok := take_host_buffer(u64(value))
		if !ok { wj.JS_FreeValue(ctx, arr); return wj.JS_ThrowOutOfMemory(ctx) }
		defer wj.libc_free(mem)
		r := Pack_Reader{data = mem != nil ? mem[:n] : nil}
		if count, cok := pack_u32(&r); cok {
			for i in u32(0) ..< count {
				v := decode_request(ctx, &r)
				if wj.is_exception(v) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) } else { wj.JS_SetPropertyUint32(ctx, arr, i, v) }
			}
		}
	}
	wj.web_freeze(ctx, arr)
	return arr
}

@(private = "file")
cache_this :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> ^Cache_Impl { return (^Cache_Impl)(wj.this_impl(ctx, v, cache_iface(.Cache))) }

@(private = "file")
cache_new :: proc "contextless" (ctx: ^wj.Context, name: wj.JSValue) -> wj.JSValue {
	c := (^Cache_Impl)(wj.libc_calloc(1, size_of(Cache_Impl)))
	if c == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	c.name = wj.JS_DupValue(ctx, name)
	obj := wj.wj_new_object(ctx, cache_iface(.Cache), nil, nil)
	if wj.is_exception(obj) { cache_free(c); return obj }
	wj.web_set_impl(obj, c, cache_free, cache_mark)
	return obj
}

// match / matchAll / keys / delete of one cache
@(private = "file")
Cache_Op :: enum { Match, Match_All, Keys, Delete }

@(private = "file")
cache_query :: proc(ctx: ^wj.Context, name_v: wj.JSValue, op: Cache_Op, request: wj.JSValue, opt: wj.JSValue) -> wj.JSValue {
	q: Query
	defer query_free(&q)
	if !query_options(ctx, opt, &q, nil) { return wj.web_promise_reject_pending(ctx) }
	name_s: wj.Str
	if !wj.wj_to_str(ctx, name_v, &name_s, 0, nil) { return wj.web_promise_reject_pending(ctx) }
	defer wj.wj_str_free(ctx, &name_s)
	name := string(wj.str_slice(name_s))
	url_s, method_s: wj.Str
	method_s = { ptr = wj.raw_bytes("GET"), len = 3 }
	has_req := !wj.is_undefined(request)
	if has_req {
		if !request_parts(ctx, request, &url_s, &method_s) { return wj.web_promise_reject_pending(ctx) }
		request_headers(request, &q)
	}
	defer if has_req { wj.wj_str_free(ctx, &url_s); wj.wj_str_free(ctx, &method_s) }
	url, method := has_req ? string(wj.str_slice(url_s)) : "", string(wj.str_slice(method_s))
	hp: abi.Handle
	switch op {
	case .Delete:
		st := jsb.host(&hp, api_decl.Cache_deleteEntries, wj.wr_Cache_deleteEntries, name, url, method, query_headers(&q),
			q.ignore_search, q.ignore_method, q.ignore_vary)
		if st != .None { return reject_status(ctx, st, "Cache.delete") }
		return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_BOOL, nil, wj.UNDEFINED)
	case .Match, .Match_All:
		multiple := op == .Match_All
		st := jsb.host(&hp, api_decl.Cache_match, wj.wr_Cache_match, name, false, url, method, query_headers(&q),
			q.ignore_search, q.ignore_method, q.ignore_vary, multiple)
		if st != .None { return reject_status(ctx, st, "Cache.match") }
		return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_NUMBER, settle_match, wj.new_bool(multiple))
	case .Keys:
		st := jsb.host(&hp, api_decl.Cache_keys, wj.wr_Cache_keys, name, url, method, query_headers(&q),
			q.ignore_search, q.ignore_method, q.ignore_vary)
		if st != .None { return reject_status(ctx, st, "Cache.keys") }
		return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_NUMBER, settle_keys, wj.UNDEFINED)
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Cache_match")
wjr_Cache_match :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "Cache.match", 1, argc); return wj.web_promise_reject_pending(ctx) }
	return cache_query(ctx, c.name, .Match, argv[0], wj.arg(argc, argv, 1))
}

@(export, link_name = "wjr_Cache_matchAll")
wjr_Cache_matchAll :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	return cache_query(ctx, c.name, .Match_All, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
}

@(export, link_name = "wjr_Cache_keys")
wjr_Cache_keys :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	return cache_query(ctx, c.name, .Keys, wj.arg(argc, argv, 0), wj.arg(argc, argv, 1))
}

@(export, link_name = "wjr_Cache_delete")
wjr_Cache_delete :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "Cache.delete", 1, argc); return wj.web_promise_reject_pending(ctx) }
	return cache_query(ctx, c.name, .Delete, argv[0], wj.arg(argc, argv, 1))
}

// put: once the body is read; the reaction carries [cacheName, url, response, request header lines]
@(private = "file")
Put_Data :: enum { Name, Url, Response, Request_Headers }

@(private = "file")
put_body_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	bytes: [^]u8
	n: uint
	if argc < 1 || !wj.wj_to_buffer_source(ctx, argv[0], &bytes, &n, 0, "Cache.put") { return wj.EXCEPTION }
	name, url, st_text, rurl: wj.Str
	if !wj.wj_to_str(ctx, data[Put_Data.Name], &name, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	if !wj.wj_to_str(ctx, data[Put_Data.Url], &url, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &url)
	resp := data[Put_Data.Response]
	sv := wj.JS_GetPropertyStr(ctx, resp, "status")
	status := i32(200)
	wj.JS_ToInt32(ctx, &status, sv)
	wj.JS_FreeValue(ctx, sv)
	tv := wj.JS_GetPropertyStr(ctx, resp, "statusText")
	wj.wj_to_str(ctx, tv, &st_text, 0, nil)
	wj.JS_FreeValue(ctx, tv)
	defer wj.wj_str_free(ctx, &st_text)
	// (an opaque response's `url` is "": the entry keeps the address it came from, never shown to scripts)
	internal, opaque, _ := web_response_opaque(resp)
	uv := opaque ? wj.JS_DupValue(ctx, internal) : wj.JS_GetPropertyStr(ctx, resp, "url")
	wj.wj_to_str(ctx, uv, &rurl, 0, nil)
	wj.JS_FreeValue(ctx, uv)
	defer wj.wj_str_free(ctx, &rurl)
	hv := wj.JS_GetPropertyStr(ctx, resp, "headers")
	lines: wj.Web_Buf
	web_headers_serialize(hv, &lines)
	wj.JS_FreeValue(ctx, hv)
	defer wj.web_buf_free(&lines)
	rhl: uint
	rh := wj.to_cstring_len(ctx, &rhl, data[Put_Data.Request_Headers])
	defer if rh != nil { wj.free_cstring(ctx, rh) }
	hp: abi.Handle
	st := jsb.host(&hp, api_decl.Cache_putEntry, wj.wr_Cache_putEntry, string(wj.str_slice(name)), string(wj.str_slice(url)),
		rh != nil ? string(([^]u8)(rawptr(rh))[:rhl]) : "", status, string(wj.str_slice(st_text)), string(wj.str_slice(rurl)),
		string(wj.web_buf_bytes(&lines)), bytes != nil ? bytes[:n] : nil)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "Cache.put") }
	return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_UNDEFINED, nil, wj.UNDEFINED)
}

// cache.put(request, response) (also the second half of add / addAll): checks, then the body read and stored
@(private = "file")
put_one :: proc "contextless" (ctx: ^wj.Context, name: wj.JSValue, request: wj.JSValue, response: wj.JSValue) -> wj.JSValue {
	if wj.wj_unwrap(response, cache_iface(.Response)) == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'put' on 'Cache': parameter 2 is not of type 'Response'.")
		return wj.web_promise_reject_pending(ctx)
	}
	url, method: wj.Str
	if !request_parts(ctx, request, &url, &method) { return wj.web_promise_reject_pending(ctx) }
	u, m := string(wj.str_slice(url)), string(wj.str_slice(method))
	get := m == "GET"
	http := (len(u) > 7 && u[:7] == "http://") || (len(u) > 8 && u[:8] == "https://")
	url_v := wj.new_string_len(ctx, u)
	wj.wj_str_free(ctx, &url)
	wj.wj_str_free(ctx, &method)
	if !get || !http {
		wj.JS_FreeValue(ctx, url_v)
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'put' on 'Cache': Request method '%s' is unsupported", get ? cstring("scheme") : cstring("non-GET"))
		return wj.web_promise_reject_pending(ctx)
	}
	sv := wj.JS_GetPropertyStr(ctx, response, "status")
	status: i32
	wj.JS_ToInt32(ctx, &status, sv)
	wj.JS_FreeValue(ctx, sv)
	used := wj.JS_GetPropertyStr(ctx, response, "bodyUsed")
	body_used := wj.JS_ToBool(ctx, used) != 0
	wj.JS_FreeValue(ctx, used)
	if status == 206 || body_used {
		wj.JS_FreeValue(ctx, url_v)
		wj.JS_ThrowTypeError(ctx, status == 206 ? "Failed to execute 'put' on 'Cache': Partial response (status code 206) is unsupported" : "Failed to execute 'put' on 'Cache': Response body is already used")
		return wj.web_promise_reject_pending(ctx)
	}
	ab_fn := wj.JS_GetPropertyStr(ctx, response, "arrayBuffer")
	body := wj.JS_Call(ctx, ab_fn, response, 0, nil)
	wj.JS_FreeValue(ctx, ab_fn)
	if wj.is_exception(body) { wj.JS_FreeValue(ctx, url_v); return wj.web_promise_reject_pending(ctx) }
	q: Query
	request_headers(request, &q)
	rh_v := wj.new_string_len(ctx, query_headers(&q))
	query_free(&q)
	data := [Put_Data]wj.JSValue{ .Name = name, .Url = url_v, .Response = response, .Request_Headers = rh_v }
	r := wj.web_then(ctx, body, rawptr(put_body_read), nil, i32(len(data)), &data[.Name])
	wj.JS_FreeValue(ctx, body)
	wj.JS_FreeValue(ctx, url_v)
	wj.JS_FreeValue(ctx, rh_v)
	return r
}

@(export, link_name = "wjr_Cache_put")
wjr_Cache_put :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 2 { wj.wj_throw_arity(ctx, "Cache.put", 2, argc); return wj.web_promise_reject_pending(ctx) }
	return put_one(ctx, c.name, argv[0], argv[1])
}

// add / addAll once every fetch answered (the responses in argv[0]); the reaction carries [cacheName, requests]
@(private = "file")
add_fetched :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	responses := wj.arg(argc, argv, 0)
	n: i64
	wj.JS_GetLength(ctx, responses, &n)
	puts := wj.JS_NewArray(ctx)
	for i in 0 ..< n {
		resp := wj.JS_GetPropertyInt64(ctx, responses, i)
		ok := wj.JS_GetPropertyStr(ctx, resp, "ok")
		good := wj.JS_ToBool(ctx, ok) != 0
		wj.JS_FreeValue(ctx, ok)
		if !good {
			wj.JS_FreeValue(ctx, resp)
			wj.JS_FreeValue(ctx, puts)
			return wj.JS_ThrowTypeError(ctx, "Failed to execute 'addAll' on 'Cache': Request failed")
		}
		req := wj.JS_GetPropertyInt64(ctx, data[1], i)
		wj.JS_SetPropertyInt64(ctx, puts, i, put_one(ctx, data[0], req, resp))
		wj.JS_FreeValue(ctx, req)
		wj.JS_FreeValue(ctx, resp)
	}
	r := promise_all(ctx, puts)
	wj.JS_FreeValue(ctx, puts)
	return r
}

// Promise.all(list) of the realm
@(private = "file")
promise_all :: proc "contextless" (ctx: ^wj.Context, list: wj.JSValue) -> wj.JSValue {
	list := list
	promise := global_ctor(ctx, "Promise")
	all := wj.JS_GetPropertyStr(ctx, promise, "all")
	r := wj.JS_Call(ctx, all, promise, 1, &list)
	wj.JS_FreeValue(ctx, all)
	wj.JS_FreeValue(ctx, promise)
	return r
}

@(private = "file")
add_requests :: proc "contextless" (ctx: ^wj.Context, name: wj.JSValue, list: wj.JSValue) -> wj.JSValue {
	n: i64
	if wj.JS_GetLength(ctx, list, &n) < 0 { return wj.web_promise_reject_pending(ctx) }
	fetch := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "fetch")
	fetches := wj.JS_NewArray(ctx)
	for i in 0 ..< n {
		req := wj.JS_GetPropertyInt64(ctx, list, i)
		wj.JS_SetPropertyInt64(ctx, fetches, i, wj.JS_Call(ctx, fetch, wj.UNDEFINED, 1, &req))
		wj.JS_FreeValue(ctx, req)
	}
	wj.JS_FreeValue(ctx, fetch)
	p := promise_all(ctx, fetches)
	wj.JS_FreeValue(ctx, fetches)
	if wj.is_exception(p) { return wj.web_promise_reject_pending(ctx) }
	data := [2]wj.JSValue{ name, list }
	r := wj.web_then(ctx, p, rawptr(add_fetched), nil, 2, &data[0])
	wj.JS_FreeValue(ctx, p)
	return r
}

@(export, link_name = "wjr_Cache_add")
wjr_Cache_add :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "Cache.add", 1, argc); return wj.web_promise_reject_pending(ctx) }
	list := wj.JS_NewArray(ctx)
	wj.JS_SetPropertyUint32(ctx, list, 0, wj.JS_DupValue(ctx, argv[0]))
	r := add_requests(ctx, c.name, list)
	wj.JS_FreeValue(ctx, list)
	return r
}

@(export, link_name = "wjr_Cache_addAll")
wjr_Cache_addAll :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	c := cache_this(ctx, t)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 || !wj.is_object(argv[0]) {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'addAll' on 'Cache': The provided value cannot be converted to a sequence.")
		return wj.web_promise_reject_pending(ctx)
	}
	return add_requests(ctx, c.name, argv[0])
}

// ---- CacheStorage ----

@(private = "file")
make_storage :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, cache_iface(.CacheStorage), nil, nil) }

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_caches")
wjr_WindowOrWorkerGlobalScope_get_caches :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_CACHES, make_storage)
}

// `this` is the CacheStorage and argv[0] the cache's name (wj_str_free it). False with an exception pending.
@(private = "file")
storage_name_arg :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, what: cstring, out: ^wj.Str) -> bool {
	if wj.wj_this(ctx, t, cache_iface(.CacheStorage)) == nil { return false }
	if argc < 1 { wj.wj_throw_arity(ctx, what, 1, argc); return false }
	return wj.wj_to_str(ctx, argv[0], out, 0, nil)
}

@(private = "file")
settle_open :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if state != 1 { reject^ = true; return cache_reject_from_host(ctx, host, value) }
	return cache_new(ctx, data)
}

@(export, link_name = "wjr_CacheStorage_open")
wjr_CacheStorage_open :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	name: wj.Str
	if !storage_name_arg(ctx, t, argc, argv, "CacheStorage.open", &name) { return wj.web_promise_reject_pending(ctx) }
	hp: abi.Handle
	st := jsb.host(&hp, api_decl.CacheStorage_openName, wj.wr_CacheStorage_openName, string(wj.str_slice(name)))
	nv := wj.new_string_len(ctx, wj.str_slice(name))
	wj.wj_str_free(ctx, &name)
	if st != .None { wj.JS_FreeValue(ctx, nv); return reject_status(ctx, st, "CacheStorage.open") }
	pr := wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_UNDEFINED, settle_open, nv)
	wj.JS_FreeValue(ctx, nv)
	return pr
}

@(export, link_name = "wjr_CacheStorage_has")
wjr_CacheStorage_has :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	name: wj.Str
	if !storage_name_arg(ctx, t, argc, argv, "CacheStorage.has", &name) { return wj.web_promise_reject_pending(ctx) }
	hp: abi.Handle
	st := jsb.host(&hp, api_decl.CacheStorage_hasName, wj.wr_CacheStorage_hasName, string(wj.str_slice(name)))
	wj.wj_str_free(ctx, &name)
	if st != .None { return reject_status(ctx, st, "CacheStorage.has") }
	return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_BOOL, nil, wj.UNDEFINED)
}

@(export, link_name = "wjr_CacheStorage_delete")
wjr_CacheStorage_delete :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	name: wj.Str
	if !storage_name_arg(ctx, t, argc, argv, "CacheStorage.delete", &name) { return wj.web_promise_reject_pending(ctx) }
	hp: abi.Handle
	st := jsb.host(&hp, api_decl.CacheStorage_deleteName, wj.wr_CacheStorage_deleteName, string(wj.str_slice(name)))
	wj.wj_str_free(ctx, &name)
	if st != .None { return reject_status(ctx, st, "CacheStorage.delete") }
	return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_BOOL, nil, wj.UNDEFINED)
}

// the names as an array (the lines of `text`)
@(private = "file")
names_array :: proc "contextless" (ctx: ^wj.Context, text: string) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	if len(text) == 0 { return arr }
	k: u32
	start := 0
	for i in 0 ..= len(text) {
		if i == len(text) || text[i] == '\n' {
			wj.JS_SetPropertyUint32(ctx, arr, k, wj.new_string_len(ctx, text[start:i]))
			k += 1
			start = i + 1
		}
	}
	return arr
}

@(private = "file")
settle_names :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if state != 1 { reject^ = true; return cache_reject_from_host(ctx, host, value) }
	text := wj.wj_host_promise_text(ctx, host)
	defer wj.JS_FreeValue(ctx, text)
	n: uint
	s := wj.to_cstring_len(ctx, &n, text)
	defer if s != nil { wj.free_cstring(ctx, s) }
	return names_array(ctx, s != nil ? string(([^]u8)(rawptr(s))[:n]) : "")
}

@(export, link_name = "wjr_CacheStorage_keys")
wjr_CacheStorage_keys :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, cache_iface(.CacheStorage)) == nil { return wj.web_promise_reject_pending(ctx) }
	hp: abi.Handle
	if st := jsb.host(&hp, api_decl.CacheStorage_names, wj.wr_CacheStorage_names); st != .None { return reject_status(ctx, st, "CacheStorage.keys") }
	return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_TEXT, settle_names, wj.UNDEFINED)
}

// caches.match(request, {cacheName}): the first match in the named cache, else in every cache in creation order
@(export, link_name = "wjr_CacheStorage_match")
wjr_CacheStorage_match :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, cache_iface(.CacheStorage)) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "CacheStorage.match", 1, argc); return wj.web_promise_reject_pending(ctx) }
	q: Query
	defer query_free(&q)
	cache_name: wj.JSValue
	if !query_options(ctx, wj.arg(argc, argv, 1), &q, &cache_name) { return wj.web_promise_reject_pending(ctx) }
	url, method: wj.Str
	if !request_parts(ctx, argv[0], &url, &method) { wj.JS_FreeValue(ctx, cache_name); return wj.web_promise_reject_pending(ctx) }
	defer { wj.wj_str_free(ctx, &url); wj.wj_str_free(ctx, &method) }
	request_headers(argv[0], &q)
	all_caches := wj.is_undefined(cache_name)
	cn_s: wj.Str
	if !all_caches {
		if !wj.wj_to_str(ctx, cache_name, &cn_s, 0, nil) {
			wj.JS_FreeValue(ctx, cache_name)
			return wj.web_promise_reject_pending(ctx)
		}
	}
	wj.JS_FreeValue(ctx, cache_name)
	defer if !all_caches { wj.wj_str_free(ctx, &cn_s) }
	hp: abi.Handle
	st := jsb.host(&hp, api_decl.Cache_match, wj.wr_Cache_match,
		all_caches ? "" : string(wj.str_slice(cn_s)), all_caches,
		string(wj.str_slice(url)), string(wj.str_slice(method)), query_headers(&q),
		q.ignore_search, q.ignore_method, q.ignore_vary, false)
	if st != .None { return reject_status(ctx, st, "CacheStorage.match") }
	return wj.wj_promise_from_host(ctx, u64(hp), wj.HOST_NUMBER, settle_match, wj.FALSE)
}

// crossOriginIsolated: HTML's capability, from the document's headers (apply_isolation_headers in src/page/page.odin)
@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_crossOriginIsolated")
wjr_WindowOrWorkerGlobalScope_get_crossOriginIsolated :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wr_WebAssembly_crossOriginIsolated() != 0 ? wj.TRUE : wj.FALSE
}
