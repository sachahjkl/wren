// web_url.odin: URL and URLSearchParams (URL Standard) on the browser's URL objects (module url). Ported from
// native/js/runtime/web_url.c; wjr_* symbols and behaviour identical.
//
// A URL wrapper owns its browser object; url.searchParams is the browser's linked URLSearchParams (changing either
// updates the other), owned by its own wrapper and kept by the URL's [SameObject] slot. Most URLSearchParams members
// are bound by the generator; the constructor's sequences and records, getAll, the iterators and the stringifier are
// here.
package odin_glue

import "../odin/wj"

foreign import m_url "url"

@(default_calling_convention = "c")
foreign m_url {
	@(link_name = "URL_parse")        wr_URL_parse        :: proc(input: [^]u8, input_len: u32, base: [^]u8, base_len: u32, ret: ^u64) -> i32 ---
	@(link_name = "URL_canParse")     wr_URL_canParse     :: proc(input: [^]u8, input_len: u32, base: [^]u8, base_len: u32) -> i32 ---
	@(link_name = "URL_get")          wr_URL_get          :: proc(url: u64, component: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URL_set")          wr_URL_set          :: proc(url: u64, component: i32, value: [^]u8, value_len: u32) -> i32 ---
	@(link_name = "URL_searchParams") wr_URL_searchParams :: proc(url: u64) -> u64 ---
	@(link_name = "URLSearchParams_create")   wr_URLSearchParams_create   :: proc(init: [^]u8, init_len: u32, ret: ^u64) -> i32 ---
	@(link_name = "URLSearchParams_append")   wr_URLSearchParams_append   :: proc(params: u64, name: [^]u8, name_len: u32, value: [^]u8, value_len: u32) ---
	@(link_name = "URLSearchParams_count")    wr_URLSearchParams_count    :: proc(params: u64, name: [^]u8, name_len: u32) -> i32 ---
	@(link_name = "URLSearchParams_getNth")   wr_URLSearchParams_getNth   :: proc(params: u64, name: [^]u8, name_len: u32, index: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URLSearchParams_toString") wr_URLSearchParams_toString :: proc(params: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URLSearchParams_nameAt")   wr_URLSearchParams_nameAt   :: proc(params: u64, index: i32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "URLSearchParams_valueAt")  wr_URLSearchParams_valueAt  :: proc(params: u64, index: i32, buf: [^]u8, cap: u32) -> i32 ---
}

WR_ABSENT :: u32(0xFFFF_FFFF)

URLC_HREF     :: i32(0)
URLC_PROTOCOL :: i32(1)
URLC_USERNAME :: i32(2)
URLC_PASSWORD :: i32(3)
URLC_HOST     :: i32(4)
URLC_HOSTNAME :: i32(5)
URLC_PORT     :: i32(6)
URLC_PATHNAME :: i32(7)
URLC_SEARCH   :: i32(8)
URLC_HASH     :: i32(9)
URLC_ORIGIN   :: i32(10)

@(private = "file") iface_url := i32(-2)
@(private = "file") iface_params := i32(-2)

@(private = "file")
url_iface :: proc "c" () -> i32 {
	if iface_url == -2 { iface_url = wj.iface("URL") }
	return iface_url
}
@(private = "file")
params_iface :: proc "c" () -> i32 {
	if iface_params == -2 { iface_params = wj.iface("URLSearchParams") }
	return iface_params
}

// ---- URL ----

@(private = "file")
url_args :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, input: ^wj.Str, base: ^wj.Str) -> bool {
	base^ = {}
	if !wj.web_to_usv(ctx, argv[0], input) { return false }
	b := wj.arg(argc, argv, 1)
	if !wj.is_undefined(b) && !wj.web_to_usv(ctx, b, base) { wj.wj_str_free(ctx, input); return false }
	return true
}

// 0 when the input is not a valid URL.
@(private = "file")
url_parse :: proc "c" (input: ^wj.Str, base: ^wj.Str, status: ^i32) -> u64 {
	h := u64(0)
	base_len := base.ptr != nil ? u32(base.len) : WR_ABSENT
	status^ = wr_URL_parse(input.ptr, u32(input.len), base.ptr, base_len, &h)
	return status^ < 0 ? 0 : h
}

@(export, link_name = "wjr_URL_constructor")
wjr_URL_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor URL requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL", 1, argc) }
	input, base: wj.Str
	if !url_args(ctx, argc, argv, &input, &base) { return wj.EXCEPTION }
	st: i32
	h := url_parse(&input, &base, &st)
	if h == 0 {
		e := wj.wj_throw_type(ctx, "Failed to construct 'URL': Invalid URL '%.*s'", i32(min(input.len, 200)), input.ptr)
		wj.wj_str_free(ctx, &input)
		wj.wj_str_free(ctx, &base)
		return e
	}
	wj.wj_str_free(ctx, &input)
	wj.wj_str_free(ctx, &base)
	return wj.wj_wrap_owned(ctx, h, url_iface(), new_target)
}

@(export, link_name = "wjr_URL_static_parse")
wjr_URL_static_parse :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL.parse", 1, argc) }
	input, base: wj.Str
	if !url_args(ctx, argc, argv, &input, &base) { return wj.EXCEPTION }
	st: i32
	h := url_parse(&input, &base, &st)
	wj.wj_str_free(ctx, &input)
	wj.wj_str_free(ctx, &base)
	if h == 0 { return wj.NULL }
	return wj.wj_wrap_owned(ctx, h, url_iface(), wj.UNDEFINED)
}

@(export, link_name = "wjr_URL_static_canParse")
wjr_URL_static_canParse :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL.canParse", 1, argc) }
	input, base: wj.Str
	if !url_args(ctx, argc, argv, &input, &base) { return wj.EXCEPTION }
	base_len := base.ptr != nil ? u32(base.len) : WR_ABSENT
	ok := wr_URL_canParse(input.ptr, u32(input.len), base.ptr, base_len)
	wj.wj_str_free(ctx, &input)
	wj.wj_str_free(ctx, &base)
	return wj.new_bool(ok != 0)
}

// `this` as a URL with a live handle, else TypeError.
@(private = "file")
url_handle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> (u64, bool) {
	o := wj.wj_this(ctx, this_val, url_iface())
	if o == nil { return 0, false }
	h := wj.handle_of(o)
	if h == 0 { wj.wj_throw_type(ctx, "Illegal invocation"); return 0, false }
	return h, true
}

@(private = "file") Comp_Op :: struct { handle: u64, component: i32 }
@(private = "file")
fill_url_get :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^Comp_Op)(user)
	return wr_URL_get(op.handle, op.component, buf, cap)
}

@(private = "file")
url_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: i32) -> wj.JSValue {
	h, ok := url_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	op := Comp_Op{ h, component }
	n := wj.fetch_string(fill_url_get, &op)
	if n < 0 { return wj.wj_throw_status(ctx, n, "URL") }
	return wj.new_string_len(ctx, wj.scratch_bytes(n))
}

@(private = "file")
url_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: i32, v: wj.JSValue) -> wj.JSValue {
	h, ok := url_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	s: wj.Str
	if !wj.web_to_usv(ctx, v, &s) { return wj.EXCEPTION }
	st := wr_URL_set(h, component, s.ptr, u32(s.len))
	if st < 0 {
		e: wj.JSValue
		if component == URLC_HREF {
			e = wj.wj_throw_type(ctx, "Failed to set the 'href' property on 'URL': Invalid URL '%.*s'", i32(min(s.len, 200)), s.ptr)
		} else {
			e = wj.wj_throw_status(ctx, st, "URL")
		}
		wj.wj_str_free(ctx, &s)
		return e
	}
	wj.wj_str_free(ctx, &s)
	return wj.UNDEFINED
}

// The ten component accessors (the C URL_COMPONENT macro). Each pair is one getter and one setter.
@(export, link_name = "wjr_URL_get_href")     wjr_URL_get_href     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_HREF) }
@(export, link_name = "wjr_URL_set_href")     wjr_URL_set_href     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_HREF, v) }
@(export, link_name = "wjr_URL_get_protocol") wjr_URL_get_protocol :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_PROTOCOL) }
@(export, link_name = "wjr_URL_set_protocol") wjr_URL_set_protocol :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_PROTOCOL, v) }
@(export, link_name = "wjr_URL_get_username") wjr_URL_get_username :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_USERNAME) }
@(export, link_name = "wjr_URL_set_username") wjr_URL_set_username :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_USERNAME, v) }
@(export, link_name = "wjr_URL_get_password") wjr_URL_get_password :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_PASSWORD) }
@(export, link_name = "wjr_URL_set_password") wjr_URL_set_password :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_PASSWORD, v) }
@(export, link_name = "wjr_URL_get_host")     wjr_URL_get_host     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_HOST) }
@(export, link_name = "wjr_URL_set_host")     wjr_URL_set_host     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_HOST, v) }
@(export, link_name = "wjr_URL_get_hostname") wjr_URL_get_hostname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_HOSTNAME) }
@(export, link_name = "wjr_URL_set_hostname") wjr_URL_set_hostname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_HOSTNAME, v) }
@(export, link_name = "wjr_URL_get_port")     wjr_URL_get_port     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_PORT) }
@(export, link_name = "wjr_URL_set_port")     wjr_URL_set_port     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_PORT, v) }
@(export, link_name = "wjr_URL_get_pathname") wjr_URL_get_pathname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_PATHNAME) }
@(export, link_name = "wjr_URL_set_pathname") wjr_URL_set_pathname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_PATHNAME, v) }
@(export, link_name = "wjr_URL_get_search")   wjr_URL_get_search   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_SEARCH) }
@(export, link_name = "wjr_URL_set_search")   wjr_URL_set_search   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_SEARCH, v) }
@(export, link_name = "wjr_URL_get_hash")     wjr_URL_get_hash     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_HASH) }
@(export, link_name = "wjr_URL_set_hash")     wjr_URL_set_hash     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return url_set(ctx, t, URLC_HASH, v) }

@(export, link_name = "wjr_URL_get_origin")
wjr_URL_get_origin :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return url_get(ctx, t, URLC_ORIGIN) }

@(export, link_name = "wjr_URL_toJSON")
wjr_URL_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return url_get(ctx, this_val, URLC_HREF)
}

@(export, link_name = "wjr_URL_get_searchParams")
wjr_URL_get_searchParams :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	h, ok := url_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	ph := wr_URL_searchParams(h)
	if ph == 0 { return wj.wj_throw_type(ctx, "the URL is gone") }
	// the same object for the URL's life: the [SameObject] slot keeps this wrapper
	cached := wj.wj_cached(ctx, ph)
	if !wj.is_undefined(cached) { return wj.JS_DupValue(ctx, cached) }
	return wj.wj_wrap_owned(ctx, ph, params_iface(), wj.UNDEFINED)
}

// ---- URLSearchParams ----

@(private = "file")
params_append :: proc "c" (ctx: ^wj.Context, h: u64, name: wj.JSValue, value: wj.JSValue) -> bool {
	n, v: wj.Str
	if !wj.web_to_usv(ctx, name, &n) { return false }
	if !wj.web_to_usv(ctx, value, &v) { wj.wj_str_free(ctx, &n); return false }
	wr_URLSearchParams_append(h, n.ptr, u32(n.len), v.ptr, u32(v.len))
	wj.wj_str_free(ctx, &n)
	wj.wj_str_free(ctx, &v)
	return true
}

// each item of a sequence initializer is a sequence of exactly two strings
@(private = "file") Pair_Collect :: struct { v0, v1: wj.JSValue, count: i32 }

@(private = "file")
pair_collect :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	p := (^Pair_Collect)(opaque)
	if p.count == 0 { p.v0 = wj.JS_DupValue(ctx, item) } else if p.count == 1 { p.v1 = wj.JS_DupValue(ctx, item) }
	p.count += 1
	return true
}

@(private = "file")
params_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	h := (^u64)(opaque)^
	if !wj.is_object(item) { wj.wj_throw_type(ctx, "Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence."); return false }
	pair := Pair_Collect{ wj.UNDEFINED, wj.UNDEFINED, 0 }
	if !wj.web_for_of(ctx, item, pair_collect, &pair) { wj.JS_FreeValue(ctx, pair.v0); wj.JS_FreeValue(ctx, pair.v1); return false }
	ok: bool
	if pair.count != 2 {
		wj.wj_throw_type(ctx, "Failed to construct 'URLSearchParams': Sequence initializer must only contain pair elements")
		ok = false
	} else {
		ok = params_append(ctx, h, pair.v0, pair.v1)
	}
	wj.JS_FreeValue(ctx, pair.v0)
	wj.JS_FreeValue(ctx, pair.v1)
	return ok
}

@(private = "file")
params_record :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	return params_append(ctx, (^u64)(opaque)^, key, value)
}

@(export, link_name = "wjr_URLSearchParams_constructor")
wjr_URLSearchParams_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor URLSearchParams requires 'new'") }
	init := wj.arg(argc, argv, 0)
	h := u64(0)
	st: i32
	if wj.is_object(init) {
		st = wr_URLSearchParams_create(nil, 0, &h)
		if st < 0 { return wj.wj_throw_status(ctx, st, "URLSearchParams") }
		obj := wj.wj_wrap_owned(ctx, h, params_iface(), new_target)
		if wj.is_exception(obj) { return obj }
		it := wj.web_is_iterable(ctx, init)
		ok := it < 0 ? false : it != 0 ? wj.web_for_of(ctx, init, params_item, &h) : wj.web_for_record(ctx, init, params_record, &h)
		if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
		return obj
	}
	s: wj.Str
	if wj.is_undefined(init) {
		s = {}
	} else if !wj.web_to_usv(ctx, init, &s) {
		return wj.EXCEPTION
	}
	s_ptr := s.ptr != nil ? s.ptr : wj.empty_ptr()
	st = wr_URLSearchParams_create(s_ptr, u32(s.len), &h)
	wj.wj_str_free(ctx, &s)
	if st < 0 { return wj.wj_throw_status(ctx, st, "URLSearchParams") }
	return wj.wj_wrap_owned(ctx, h, params_iface(), new_target)
}

// `this` as a URLSearchParams with a live handle, else TypeError.
@(private = "file")
params_handle :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> (u64, bool) {
	o := wj.wj_this(ctx, this_val, params_iface())
	if o == nil { return 0, false }
	h := wj.handle_of(o)
	if h == 0 { wj.wj_throw_type(ctx, "Illegal invocation"); return 0, false }
	return h, true
}

@(private = "file") GetNth_Op :: struct { handle: u64, name: wj.Str, index: i32 }
@(private = "file")
fill_get_nth :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^GetNth_Op)(user)
	return wr_URLSearchParams_getNth(op.handle, op.name.ptr, u32(op.name.len), op.index, buf, cap)
}

@(export, link_name = "wjr_URLSearchParams_getAll")
wjr_URLSearchParams_getAll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := params_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "URLSearchParams.getAll", 1, argc) }
	name: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &name) { return wj.EXCEPTION }
	count := wr_URLSearchParams_count(h, name.ptr, u32(name.len))
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< count {
		op := GetNth_Op{ h, name, i }
		n := wj.fetch_string(fill_get_nth, &op)
		if n < 0 { break }
		wj.array_set(ctx, arr, u32(i), wj.new_string_len(ctx, wj.scratch_bytes(n)))
	}
	wj.wj_str_free(ctx, &name)
	return arr
}

@(private = "file") Params_Op :: struct { handle: u64 }
@(private = "file")
fill_params_tostring :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	return wr_URLSearchParams_toString((^Params_Op)(user).handle, buf, cap)
}

@(export, link_name = "wjr_URLSearchParams_toString")
wjr_URLSearchParams_toString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h, ok := params_handle(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	op := Params_Op{ h }
	n := wj.fetch_string(fill_params_tostring, &op)
	if n < 0 { return wj.wj_throw_status(ctx, n, "URLSearchParams.toString") }
	return wj.new_string_len(ctx, wj.scratch_bytes(n))
}

@(private = "file") At_Op :: struct { handle: u64, index: i32 }
@(private = "file")
fill_name_at :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^At_Op)(user); return wr_URLSearchParams_nameAt(op.handle, op.index, buf, cap)
}
@(private = "file")
fill_value_at :: proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 {
	op := (^At_Op)(user); return wr_URLSearchParams_valueAt(op.handle, op.index, buf, cap)
}

// The pair iterator's "at" callback (web_iterator_new / web_for_each). 0 past the end.
@(private = "file")
params_at :: proc "c" (ctx: ^wj.Context, owner: wj.JSValue, index: u32, key: ^wj.JSValue, value: ^wj.JSValue) -> i32 {
	h := wj.obj_handle(owner)
	if h == 0 { return 0 }
	op := At_Op{ h, i32(index) }
	n := wj.fetch_string(fill_name_at, &op)
	if n < 0 { return 0 }
	key^ = wj.new_string_len(ctx, wj.scratch_bytes(n))
	n = wj.fetch_string(fill_value_at, &op)
	value^ = wj.new_string_len(ctx, wj.scratch_bytes(n))
	return 1
}

@(private = "file")
params_iter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, kind: i32) -> wj.JSValue {
	if _, ok := params_handle(ctx, this_val); !ok { return wj.EXCEPTION }
	return wj.web_iterator_new(ctx, wj.ITERABLE_URLSEARCHPARAMS, this_val, kind, params_at)
}

@(export, link_name = "wjr_URLSearchParams_entries")
wjr_URLSearchParams_entries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return params_iter(ctx, this_val, wj.ITER_ENTRIES) }
@(export, link_name = "wjr_URLSearchParams_keys")
wjr_URLSearchParams_keys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return params_iter(ctx, this_val, wj.ITER_KEYS) }
@(export, link_name = "wjr_URLSearchParams_values")
wjr_URLSearchParams_values :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return params_iter(ctx, this_val, wj.ITER_VALUES) }

@(export, link_name = "wjr_URLSearchParams_forEach")
wjr_URLSearchParams_forEach :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if _, ok := params_handle(ctx, this_val); !ok { return wj.EXCEPTION }
	return wj.web_for_each(ctx, this_val, argc, argv, params_at)
}
