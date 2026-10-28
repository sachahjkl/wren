// web_url.odin: URL and URLSearchParams (URL Standard) on the browser's URL objects (module url). wjr_* symbols and
// behaviour identical to native/js/runtime/web_url.c.
//
// Bound through the generic boundary: every call into the host names its declaration in the shared api_decl
// (native/js/odin_abi/api_decl/url.odin) and the generated import that carries it (wj.wr_*); package jsb converts the
// JS values by the declaration's types and lowers them onto the import's wire, checked at compile time. A member that
// only carries a call across (the component getters, toString, canParse) is one line naming the two. What is written
// here is behaviour: the [SameObject] searchParams, the constructor's sequences and records, getAll, the iterators,
// the messages of a failed parse.
//
// A URL wrapper owns its browser object; url.searchParams is the browser's linked URLSearchParams (changing either
// updates the other), owned by its own wrapper and kept by the URL's [SameObject] slot.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

URL             :: api_decl.URL
URLSearchParams :: api_decl.URLSearchParams
URLComponent    :: api_decl.URLComponent

@(private = "file") none: abi.Nothing

// ---- URL ----

// The input and the optional base of new URL() / URL.parse() as USVStrings.
@(private = "file")
url_args :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, input: ^wj.Str, base: ^wj.Str) -> bool {
	base^ = {}
	if !wj.web_to_usv(ctx, argv[0], input) { return false }
	b := wj.arg(argc, argv, 1)
	if !wj.is_undefined(b) && !wj.web_to_usv(ctx, b, base) { wj.wj_str_free(ctx, input); return false }
	return true
}

@(private = "file")
str_of :: #force_inline proc "contextless" (s: wj.Str) -> string { return string(s.ptr[:s.len]) }

// The URL the arguments parse to, 0 when they do not.
@(private = "file")
url_parse :: proc(input: wj.Str, base: wj.Str) -> URL {
	u: URL
	b: Maybe(string) = base.ptr != nil ? str_of(base) : nil
	if jsb.host(&u, api_decl.URL_parse, wj.wr_URL_parse, str_of(input), b) != .None { return 0 }
	return u
}

@(export, link_name = "wjr_URL_constructor")
wjr_URL_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor URL requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL", 1, argc) }
	input, base: wj.Str
	if !url_args(ctx, argc, argv, &input, &base) { return wj.EXCEPTION }
	u := url_parse(input, base)
	if u == 0 {
		e := wj.wj_throw_type(ctx, "Failed to construct 'URL': Invalid URL '%.*s'", i32(min(input.len, 200)), input.ptr)
		wj.wj_str_free(ctx, &input)
		wj.wj_str_free(ctx, &base)
		return e
	}
	wj.wj_str_free(ctx, &input)
	wj.wj_str_free(ctx, &base)
	return wj.wj_wrap_owned(ctx, u64(u), jsb.iface_of(URL), new_target)
}

@(export, link_name = "wjr_URL_static_parse")
wjr_URL_static_parse :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if argc < 1 { return wj.wj_throw_arity(ctx, "URL.parse", 1, argc) }
	input, base: wj.Str
	if !url_args(ctx, argc, argv, &input, &base) { return wj.EXCEPTION }
	u := url_parse(input, base)
	wj.wj_str_free(ctx, &input)
	wj.wj_str_free(ctx, &base)
	if u == 0 { return wj.NULL }
	return wj.wj_wrap_owned(ctx, u64(u), jsb.iface_of(URL), wj.UNDEFINED)
}

@(export, link_name = "wjr_URL_static_canParse")
wjr_URL_static_canParse :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.function(ctx, argc, argv, api_decl.URL_canParse, wj.wr_URL_canParse, "URL.canParse", .USV)
}

// A component setter. href reports the invalid input; the other components only fail on a released URL.
@(private = "file")
component_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, component: URLComponent, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	u, ok := jsb.this(ctx, this_val, URL)
	if !ok { return wj.EXCEPTION }
	s: wj.Str
	if !wj.web_to_usv(ctx, v, &s) { return wj.EXCEPTION }
	if st := jsb.host(&none, api_decl.URL_set, wj.wr_URL_set, u, component, str_of(s)); st != .None {
		e: wj.JSValue
		if component == .Href {
			e = wj.wj_throw_type(ctx, "Failed to set the 'href' property on 'URL': Invalid URL '%.*s'", i32(min(s.len, 200)), s.ptr)
		} else {
			e = wj.wj_throw_status(ctx, i32(st), "URL")
		}
		wj.wj_str_free(ctx, &s)
		return e
	}
	wj.wj_str_free(ctx, &s)
	return wj.UNDEFINED
}

// The component accessors: a getter is the declaration URL_get with its component; a setter is component_set.
@(private = "file")
get :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, component: URLComponent) -> wj.JSValue {
	return jsb.getter(ctx, t, api_decl.URL_get, wj.wr_URL_get, component, "URL")
}
@(export, link_name = "wjr_URL_get_href")     wjr_URL_get_href     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Href) }
@(export, link_name = "wjr_URL_set_href")     wjr_URL_set_href     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Href, v) }
@(export, link_name = "wjr_URL_get_protocol") wjr_URL_get_protocol :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Protocol) }
@(export, link_name = "wjr_URL_set_protocol") wjr_URL_set_protocol :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Protocol, v) }
@(export, link_name = "wjr_URL_get_username") wjr_URL_get_username :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Username) }
@(export, link_name = "wjr_URL_set_username") wjr_URL_set_username :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Username, v) }
@(export, link_name = "wjr_URL_get_password") wjr_URL_get_password :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Password) }
@(export, link_name = "wjr_URL_set_password") wjr_URL_set_password :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Password, v) }
@(export, link_name = "wjr_URL_get_host")     wjr_URL_get_host     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Host) }
@(export, link_name = "wjr_URL_set_host")     wjr_URL_set_host     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Host, v) }
@(export, link_name = "wjr_URL_get_hostname") wjr_URL_get_hostname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Hostname) }
@(export, link_name = "wjr_URL_set_hostname") wjr_URL_set_hostname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Hostname, v) }
@(export, link_name = "wjr_URL_get_port")     wjr_URL_get_port     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Port) }
@(export, link_name = "wjr_URL_set_port")     wjr_URL_set_port     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Port, v) }
@(export, link_name = "wjr_URL_get_pathname") wjr_URL_get_pathname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Pathname) }
@(export, link_name = "wjr_URL_set_pathname") wjr_URL_set_pathname :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Pathname, v) }
@(export, link_name = "wjr_URL_get_search")   wjr_URL_get_search   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Search) }
@(export, link_name = "wjr_URL_set_search")   wjr_URL_set_search   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Search, v) }
@(export, link_name = "wjr_URL_get_hash")     wjr_URL_get_hash     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Hash) }
@(export, link_name = "wjr_URL_set_hash")     wjr_URL_set_hash     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return component_set(ctx, t, .Hash, v) }
@(export, link_name = "wjr_URL_get_origin")   wjr_URL_get_origin   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return get(ctx, t, .Origin) }

@(export, link_name = "wjr_URL_toJSON")
wjr_URL_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return get(ctx, this_val, .Href) }

@(export, link_name = "wjr_URL_get_searchParams")
wjr_URL_get_searchParams :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	u, ok := jsb.this(ctx, this_val, URL)
	if !ok { return wj.EXCEPTION }
	p: URLSearchParams
	jsb.host(&p, api_decl.URL_searchParams, wj.wr_URL_searchParams, u)
	if p == 0 { return wj.wj_throw_type(ctx, "the URL is gone") }
	// the same object for the URL's life: the [SameObject] slot keeps this wrapper
	cached := wj.wj_cached(ctx, u64(p))
	if !wj.is_undefined(cached) { return wj.JS_DupValue(ctx, cached) }
	return wj.wj_wrap_owned(ctx, u64(p), jsb.iface_of(URLSearchParams), wj.UNDEFINED)
}

// ---- URLSearchParams ----

@(private = "file")
params_append :: proc "c" (ctx: ^wj.Context, p: URLSearchParams, name: wj.JSValue, value: wj.JSValue) -> bool {
	context = jsb.glue_context()
	n, v: wj.Str
	if !wj.web_to_usv(ctx, name, &n) { return false }
	if !wj.web_to_usv(ctx, value, &v) { wj.wj_str_free(ctx, &n); return false }
	jsb.host(&none, api_decl.URLSearchParams_append, wj.wr_URLSearchParams_append, p, str_of(n), str_of(v))
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
	p := (^URLSearchParams)(opaque)^
	if !wj.is_object(item) { wj.wj_throw_type(ctx, "Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence."); return false }
	pair := Pair_Collect{ wj.UNDEFINED, wj.UNDEFINED, 0 }
	if !wj.web_for_of(ctx, item, pair_collect, &pair) { wj.JS_FreeValue(ctx, pair.v0); wj.JS_FreeValue(ctx, pair.v1); return false }
	ok: bool
	if pair.count != 2 {
		wj.wj_throw_type(ctx, "Failed to construct 'URLSearchParams': Sequence initializer must only contain pair elements")
		ok = false
	} else {
		ok = params_append(ctx, p, pair.v0, pair.v1)
	}
	wj.JS_FreeValue(ctx, pair.v0)
	wj.JS_FreeValue(ctx, pair.v1)
	return ok
}

@(private = "file")
params_record :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	return params_append(ctx, (^URLSearchParams)(opaque)^, key, value)
}

@(export, link_name = "wjr_URLSearchParams_constructor")
wjr_URLSearchParams_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor URLSearchParams requires 'new'") }
	init := wj.arg(argc, argv, 0)
	p: URLSearchParams
	if wj.is_object(init) {
		if st := jsb.host(&p, api_decl.URLSearchParams_create, wj.wr_URLSearchParams_create, ""); st != .None {
			return wj.wj_throw_status(ctx, i32(st), "URLSearchParams")
		}
		obj := wj.wj_wrap_owned(ctx, u64(p), jsb.iface_of(URLSearchParams), new_target)
		if wj.is_exception(obj) { return obj }
		it := wj.web_is_iterable(ctx, init)
		ok := it < 0 ? false : it != 0 ? wj.web_for_of(ctx, init, params_item, &p) : wj.web_for_record(ctx, init, params_record, &p)
		if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
		return obj
	}
	s: wj.Str
	if !wj.is_undefined(init) && !wj.web_to_usv(ctx, init, &s) { return wj.EXCEPTION }
	st := jsb.host(&p, api_decl.URLSearchParams_create, wj.wr_URLSearchParams_create, s.ptr != nil ? str_of(s) : "")
	wj.wj_str_free(ctx, &s)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "URLSearchParams") }
	return wj.wj_wrap_owned(ctx, u64(p), jsb.iface_of(URLSearchParams), new_target)
}

@(export, link_name = "wjr_URLSearchParams_getAll")
wjr_URLSearchParams_getAll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	p, ok := jsb.this(ctx, this_val, URLSearchParams)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "URLSearchParams.getAll", 1, argc) }
	name: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &name) { return wj.EXCEPTION }
	count: i32
	jsb.host(&count, api_decl.URLSearchParams_count, wj.wr_URLSearchParams_count, p, str_of(name))
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< count {
		s: string
		if jsb.host(&s, api_decl.URLSearchParams_getNth, wj.wr_URLSearchParams_getNth, p, str_of(name), i) != .None { break }
		wj.array_set(ctx, arr, u32(i), wj.new_string_len(ctx, s))
	}
	wj.wj_str_free(ctx, &name)
	return arr
}

@(export, link_name = "wjr_URLSearchParams_toString")
wjr_URLSearchParams_toString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, this_val, argc, argv, api_decl.URLSearchParams_toString, wj.wr_URLSearchParams_toString, "URLSearchParams.toString")
}

// The pair iterator's "at" callback (web_iterator_new / web_for_each). 0 past the end.
@(private = "file")
params_at :: proc "c" (ctx: ^wj.Context, owner: wj.JSValue, index: u32, key: ^wj.JSValue, value: ^wj.JSValue) -> i32 {
	context = jsb.glue_context()
	p := URLSearchParams(wj.obj_handle(owner))
	if p == 0 { return 0 }
	s: string
	if jsb.host(&s, api_decl.URLSearchParams_nameAt, wj.wr_URLSearchParams_nameAt, p, i32(index)) != .None { return 0 }
	key^ = wj.new_string_len(ctx, s)
	s = ""
	jsb.host(&s, api_decl.URLSearchParams_valueAt, wj.wr_URLSearchParams_valueAt, p, i32(index))
	value^ = wj.new_string_len(ctx, s)
	return 1
}

@(private = "file")
params_iter :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, kind: i32) -> wj.JSValue {
	if _, ok := jsb.this(ctx, this_val, URLSearchParams); !ok { return wj.EXCEPTION }
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
	if _, ok := jsb.this(ctx, this_val, URLSearchParams); !ok { return wj.EXCEPTION }
	return wj.web_for_each(ctx, this_val, argc, argv, params_at)
}
