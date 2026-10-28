// web_cache.odin: the Cache API (CacheStorage, Cache) on the browser's storage (module caches,
// src/page/cache_store.odin). The browser's functions are synchronous; the promises, the Request and Response objects
// are made here. A put reads the response's body (arrayBuffer) and stores it once it is complete; add / addAll fetch
// first. Ported from native/js/runtime/web_cache.c: same wjr_* symbols and behaviour; the browser calls are declared
// in native/js/odin_abi/api_decl/caches.odin and made through jsb.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") none: abi.Nothing

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

// The ids of the entries of a cache matching a query, as a decimal list ("\n"-separated) copied out of the scratch
// buffer (libc heap: libc_free). url nil: every entry.
@(private = "file")
match_ids :: proc(name: string, url: Maybe(string), method: string, q: ^Query) -> (ids: Id_List, st: abi.Api_Error) {
	text: string
	st = jsb.host(&text, api_decl.Cache_matchIds, wj.wr_Cache_matchIds, name, url.? or_else "", method, query_headers(q),
		q.ignore_search, q.ignore_method, q.ignore_vary)
	if st != .None { return }
	p := wj.web_strndup(wj.raw_bytes(text), uint(len(text)))
	if p == nil { return {}, .Quota }
	return { p, string(p[:len(text)]) }, .None
}

// A copied list of decimal ids, walked with id_next.
@(private = "file")
Id_List :: struct { mem: [^]u8, rest: string }

@(private = "file")
id_next :: proc "contextless" (l: ^Id_List) -> (id: u64, ok: bool) {
	for len(l.rest) > 0 {
		cut := len(l.rest)
		for j in 0 ..< len(l.rest) { if l.rest[j] == '\n' { cut = j; break } }
		line := l.rest[:cut]
		l.rest = cut < len(l.rest) ? l.rest[cut + 1:] : ""
		if len(line) == 0 { continue }
		v: u64
		for c in transmute([]u8)line { v = v * 10 + u64(c - '0') }
		return v, true
	}
	return 0, false
}

@(private = "file")
id_free :: proc "contextless" (l: ^Id_List) { wj.libc_free(l.mem); l^ = {} }

// "Name: value" lines into a new Headers (guard none)
@(private = "file")
headers_of :: proc "contextless" (ctx: ^wj.Context, lines: string) -> wj.JSValue {
	h := web_headers_new(ctx, .None)
	web_headers_fill_lines(ctx, h, raw_data(lines), uint(len(lines)))
	return h
}

// The head of an entry, split: status, statusText, the response's URL, the request's method, the request's URL, the
// response's header lines.
@(private = "file")
Head :: enum { Status, Status_Text, Response_Url, Method, Url, Headers }

@(private = "file")
split_head :: proc "contextless" (text: string) -> (f: [Head]string) {
	rest := text
	for i in Head.Status ..< Head.Headers {
		cut := -1
		for j in 0 ..< len(rest) { if rest[j] == '\n' { cut = j; break } }
		if cut < 0 { f[i] = rest; rest = ""; return }
		f[i] = rest[:cut]
		rest = rest[cut + 1:]
	}
	f[.Headers] = rest
	return
}

@(private = "file")
atoi :: proc "contextless" (s: string) -> i32 {
	v: i32
	neg := false
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	if i < len(s) && (s[i] == '-' || s[i] == '+') { neg = s[i] == '-'; i += 1 }
	for ; i < len(s) && s[i] >= '0' && s[i] <= '9'; i += 1 { v = v * 10 + i32(s[i] - '0') }
	return neg ? -v : v
}

// A Response for an entry (undefined when it is gone).
@(private = "file")
entry_response :: proc(ctx: ^wj.Context, name: string, id: u64) -> wj.JSValue {
	text: string
	if jsb.host(&text, api_decl.Cache_entryHead, wj.wr_Cache_entryHead, name, id) != .None { return wj.UNDEFINED }
	head_mem := wj.web_strndup(wj.raw_bytes(text), uint(len(text)))
	if head_mem == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(head_mem)
	f := split_head(string(head_mem[:len(text)]))
	status := atoi(f[.Status])
	null_body := false
	switch status { case 101, 103, 204, 205, 304: null_body = true }
	if status < 200 || status > 599 { status = 200 }
	body := wj.NULL
	if !null_body {
		bytes: []u8
		if jsb.host(&bytes, api_decl.Cache_entryBody, wj.wr_Cache_entryBody, name, id) == .None {
			body = wj.JS_NewArrayBufferCopy(ctx, raw_data(bytes), uint(len(bytes)))
		}
	}
	init := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, init, "status", wj.new_int32(status))
	wj.JS_SetPropertyStr(ctx, init, "statusText", wj.new_string_len(ctx, f[.Status_Text]))
	wj.JS_SetPropertyStr(ctx, init, "headers", headers_of(ctx, f[.Headers]))
	ctor := global_ctor(ctx, "Response")
	args := [2]wj.JSValue{ body, init }
	r := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
	wj.JS_FreeValue(ctx, ctor)
	wj.JS_FreeValue(ctx, body)
	wj.JS_FreeValue(ctx, init)
	// the response keeps the URL it had ("" for a Response a script constructed, as stored)
	if !wj.is_exception(r) && len(f[.Response_Url]) > 0 {
		web_response_set_url(ctx, r, raw_data(f[.Response_Url]), uint(len(f[.Response_Url])))
	}
	return r
}

// A Request for an entry's request (undefined when it is gone), with the stored request's headers (those Vary was
// matched against).
@(private = "file")
entry_request :: proc(ctx: ^wj.Context, name: string, id: u64) -> wj.JSValue {
	text: string
	if jsb.host(&text, api_decl.Cache_entryHead, wj.wr_Cache_entryHead, name, id) != .None { return wj.UNDEFINED }
	f := split_head(text)
	url := wj.new_string_len(ctx, f[.Url][:min(len(f[.Url]), index_of(f[.Url], '\n'))])
	init := wj.JS_NewObject(ctx)
	lines: string
	if jsb.host(&lines, api_decl.Cache_entryRequestHeaders, wj.wr_Cache_entryRequestHeaders, name, id) == .None && len(lines) > 0 {
		wj.JS_SetPropertyStr(ctx, init, "headers", headers_of(ctx, lines))
	}
	ctor := global_ctor(ctx, "Request")
	args := [2]wj.JSValue{ url, init }
	r := wj.JS_CallConstructor(ctx, ctor, 2, &args[0])
	wj.JS_FreeValue(ctx, ctor)
	wj.JS_FreeValue(ctx, url)
	wj.JS_FreeValue(ctx, init)
	return r
}

@(private = "file")
index_of :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) { if s[i] == c { return i } }
	return len(s)
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
	url, method := string(wj.str_slice(url_s)), string(wj.str_slice(method_s))
	if op == .Delete {
		removed: bool
		st := jsb.host(&removed, api_decl.Cache_deleteEntries, wj.wr_Cache_deleteEntries, name, url, method, query_headers(&q),
			q.ignore_search, q.ignore_method, q.ignore_vary)
		return st != .None ? reject_status(ctx, st, "Cache.delete") : wj.web_promise_take(ctx, wj.new_bool(removed))
	}
	ids, st := match_ids(name, has_req ? url : nil, method, &q)
	if st != .None { return reject_status(ctx, st, "Cache.match") }
	defer id_free(&ids)
	if op == .Match {
		v := wj.UNDEFINED
		if id, ok := id_next(&ids); ok { v = entry_response(ctx, name, id) }
		return wj.is_exception(v) ? wj.web_promise_reject_pending(ctx) : wj.web_promise_take(ctx, v)
	}
	arr := wj.JS_NewArray(ctx)
	i: u32
	for id in id_next(&ids) {
		v := op == .Keys ? entry_request(ctx, name, id) : entry_response(ctx, name, id)
		if wj.is_exception(v) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) } else { wj.JS_SetPropertyUint32(ctx, arr, i, v) }
		i += 1
	}
	wj.web_freeze(ctx, arr)
	return wj.web_promise_take(ctx, arr)
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
	uv := wj.JS_GetPropertyStr(ctx, resp, "url")
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
	st := jsb.host(&none, api_decl.Cache_putEntry, wj.wr_Cache_putEntry, string(wj.str_slice(name)), string(wj.str_slice(url)),
		rh != nil ? string(([^]u8)(rawptr(rh))[:rhl]) : "", status, string(wj.str_slice(st_text)), string(wj.str_slice(rurl)),
		string(wj.web_buf_bytes(&lines)), bytes != nil ? bytes[:n] : nil)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "Cache.put") }
	return wj.UNDEFINED
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

@(export, link_name = "wjr_CacheStorage_open")
wjr_CacheStorage_open :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	name: wj.Str
	if !storage_name_arg(ctx, t, argc, argv, "CacheStorage.open", &name) { return wj.web_promise_reject_pending(ctx) }
	st := jsb.host(&none, api_decl.CacheStorage_openName, wj.wr_CacheStorage_openName, string(wj.str_slice(name)))
	nv := wj.new_string_len(ctx, wj.str_slice(name))
	wj.wj_str_free(ctx, &name)
	if st != .None { wj.JS_FreeValue(ctx, nv); return reject_status(ctx, st, "CacheStorage.open") }
	c := cache_new(ctx, nv)
	wj.JS_FreeValue(ctx, nv)
	return wj.is_exception(c) ? wj.web_promise_reject_pending(ctx) : wj.web_promise_take(ctx, c)
}

@(export, link_name = "wjr_CacheStorage_has")
wjr_CacheStorage_has :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	name: wj.Str
	if !storage_name_arg(ctx, t, argc, argv, "CacheStorage.has", &name) { return wj.web_promise_reject_pending(ctx) }
	r: bool
	st := jsb.host(&r, api_decl.CacheStorage_hasName, wj.wr_CacheStorage_hasName, string(wj.str_slice(name)))
	wj.wj_str_free(ctx, &name)
	return st != .None ? reject_status(ctx, st, "CacheStorage.has") : wj.web_promise_take(ctx, wj.new_bool(r))
}

@(export, link_name = "wjr_CacheStorage_delete")
wjr_CacheStorage_delete :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	name: wj.Str
	if !storage_name_arg(ctx, t, argc, argv, "CacheStorage.delete", &name) { return wj.web_promise_reject_pending(ctx) }
	r: bool
	st := jsb.host(&r, api_decl.CacheStorage_deleteName, wj.wr_CacheStorage_deleteName, string(wj.str_slice(name)))
	wj.wj_str_free(ctx, &name)
	return st != .None ? reject_status(ctx, st, "CacheStorage.delete") : wj.web_promise_take(ctx, wj.new_bool(r))
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

@(export, link_name = "wjr_CacheStorage_keys")
wjr_CacheStorage_keys :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, t, cache_iface(.CacheStorage)) == nil { return wj.web_promise_reject_pending(ctx) }
	text: string
	if st := jsb.host(&text, api_decl.CacheStorage_names, wj.wr_CacheStorage_names); st != .None { return reject_status(ctx, st, "CacheStorage.keys") }
	return wj.web_promise_take(ctx, names_array(ctx, text))
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
	names: wj.JSValue
	if !wj.is_undefined(cache_name) {
		names = wj.JS_NewArray(ctx)
		wj.JS_SetPropertyUint32(ctx, names, 0, wj.JS_ToString(ctx, cache_name))
	} else {
		text: string
		if st := jsb.host(&text, api_decl.CacheStorage_names, wj.wr_CacheStorage_names); st != .None {
			wj.JS_FreeValue(ctx, cache_name)
			return reject_status(ctx, st, "CacheStorage.match")
		}
		names = names_array(ctx, text)
	}
	wj.JS_FreeValue(ctx, cache_name)
	found := wj.UNDEFINED
	count: i64
	wj.JS_GetLength(ctx, names, &count)
	for i: i64 = 0; i < count && wj.is_undefined(found); i += 1 {
		nv := wj.JS_GetPropertyInt64(ctx, names, i)
		name: wj.Str
		if wj.wj_to_str(ctx, nv, &name, 0, nil) {
			n := string(wj.str_slice(name))
			ids, st := match_ids(n, string(wj.str_slice(url)), string(wj.str_slice(method)), &q)
			if st == .None {
				if id, ok := id_next(&ids); ok { found = entry_response(ctx, n, id) }
				id_free(&ids)
			}
			wj.wj_str_free(ctx, &name)
		}
		wj.JS_FreeValue(ctx, nv)
	}
	wj.JS_FreeValue(ctx, names)
	if wj.is_exception(found) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, found)
}

// crossOriginIsolated: every realm runs in an engine instance of its own, so memory is never shared between agents
// (a SharedArrayBuffer cannot go to another realm): never isolated
@(export, link_name = "wjr_WindowOrWorkerGlobalScope_get_crossOriginIsolated")
wjr_WindowOrWorkerGlobalScope_get_crossOriginIsolated :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.FALSE
}
