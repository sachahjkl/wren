package page

// URL and URLSearchParams as host objects (import module "url"), over package url (WHATWG parsing through Lexbor, the
// standard's setters with state overrides, the form-urlencoded parser and serializer).
//
// A URL's searchParams object is linked to it both ways, as in the standard: changing the URL's search re-parses the
// list; changing the list rewrites the URL's query. Either object may be released first; the link is then dropped.

import "wb:dom"
import "wb:url"
import "wb:wasm"

Url_Object :: struct {
	u:      url.URL,
	params: u64,     // its URLSearchParams object, 0 until asked for
}

Params_Object :: struct {
	sp:  url.Search_Params,
	url: u64,        // the URL it belongs to, 0 for a stand-alone one
}

url_vt := Object_VTable{
	name = "URL",
	destroy = proc(p: ^Page, data: rawptr) {
		o := (^Url_Object)(data)
		url.destroy(&o.u)
		free(o)
	},
}

params_vt := Object_VTable{
	name = "URLSearchParams",
	destroy = proc(p: ^Page, data: rawptr) {
		o := (^Params_Object)(data)
		url.params_destroy(&o.sp)
		free(o)
	},
}

@(private)
url_obj :: proc(p: ^Page, h: u64) -> ^Url_Object { return (^Url_Object)(object_data(p, h, &url_vt)) }
@(private)
params_obj :: proc(p: ^Page, h: u64) -> ^Params_Object { return (^Params_Object)(object_data(p, h, &params_vt)) }

// The URL's query changed: its search params follow.
@(private)
url_sync_params :: proc(p: ^Page, o: ^Url_Object, self: u64) {
	po := params_obj(p, o.params)
	if po == nil || po.url != self { o.params = 0; return }
	url.params_parse(&po.sp, o.u.query if o.u.has_query else "")
}

// URLSearchParams "update steps": the list changed, the URL's query follows (null when the list is empty).
@(private)
params_update :: proc(p: ^Page, po: ^Params_Object, self: u64) {
	if po.url == 0 { return }
	uo := url_obj(p, po.url)
	if uo == nil || uo.params != self { po.url = 0; return }
	q := url.params_serialize(po.sp, context.temp_allocator)
	nu, res := url.set_component(uo.u, .Search, q)
	if res != .Ok { return }
	url.destroy(&uo.u)
	uo.u = nu
}

////////////////////////////////
// URL

// new URL(input, base): has_base = 0 for no base. 0 = TypeError (invalid URL or base).
n_URL_parse :: proc "c" (env: wasm.Exec_Env, input: [^]u8, il: i32, base_s: [^]u8, bl: i32, has_base: i32) -> u64 {
	context = ctx()
	p := page_of(env)
	max_len := p.settings.web.url_max_length
	if int(il) > max_len || int(bl) > max_len { return 0 }
	bp: ^url.URL
	b: url.URL
	if has_base != 0 {
		ok: bool
		if b, ok = url.parse(str(base_s, bl), nil, context.temp_allocator); !ok { return 0 }
		bp = &b
	}
	u, ok := url.parse(str(input, il), bp)
	if !ok { return 0 }
	if len(u.href) > max_len { url.destroy(&u); return 0 }
	o := new(Url_Object)
	o.u = u
	return object_create(p, &url_vt, o, inst_of(env).index)
}

// URL.canParse(input, base)
n_URL_canParse :: proc "c" (env: wasm.Exec_Env, input: [^]u8, il: i32, base_s: [^]u8, bl: i32, has_base: i32) -> i32 {
	context = ctx()
	bp: ^url.URL
	b: url.URL
	if has_base != 0 {
		ok: bool
		if b, ok = url.parse(str(base_s, bl), nil, context.temp_allocator); !ok { return 0 }
		bp = &b
	}
	_, ok := url.parse(str(input, il), bp, context.temp_allocator)
	return ok ? 1 : 0
}

// Getter of a component (url.Component numbering: 0 href ... 9 hash, 10 origin).
n_URL_get :: proc "c" (env: wasm.Exec_Env, h: u64, component: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	o := url_obj(page_of(env), h)
	if o == nil { return i32(dom.Error.Invalid_Handle) }
	if component < 0 || component > i32(url.Component.Origin) { return i32(dom.Error.Invalid_Argument) }
	return out_string(url.component(o.u, url.Component(component), context.temp_allocator), buf, cap)
}

// Setter of a component. Only href can fail (WEB_ERR_TYPE); other values the standard ignores leave the URL unchanged.
n_URL_set :: proc "c" (env: wasm.Exec_Env, h: u64, component: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	o := url_obj(p, h)
	if o == nil { return i32(dom.Error.Invalid_Handle) }
	if component < 0 || component >= i32(url.Component.Origin) { return i32(dom.Error.Invalid_Argument) }
	if int(vl) > p.settings.web.url_max_length { return WEB_ERR_TYPE }
	nu, res := url.set_component(o.u, url.Component(component), str(value, vl))
	switch res {
	case .Ok:
	case .Invalid: return WEB_ERR_TYPE
	case .Read_Only: return i32(dom.Error.Invalid_Argument)
	case .Failed: return WEB_ERR_TYPE
	}
	if len(nu.href) > p.settings.web.url_max_length { url.destroy(&nu); return WEB_ERR_TYPE }
	url.destroy(&o.u)
	o.u = nu
	c := url.Component(component)
	if c == .Href || c == .Search { url_sync_params(p, o, h) }
	return 0
}

// url.searchParams: the same object every time (while it is not released).
n_URL_searchParams :: proc "c" (env: wasm.Exec_Env, h: u64) -> u64 {
	context = ctx()
	p := page_of(env)
	o := url_obj(p, h)
	if o == nil { return 0 }
	if po := params_obj(p, o.params); po != nil && po.url == h { return o.params }
	po := new(Params_Object)
	po.sp = url.params_make()
	po.url = h
	url.params_parse(&po.sp, o.u.query if o.u.has_query else "")
	o.params = object_create(p, &params_vt, po, inst_of(env).index)
	return o.params
}

////////////////////////////////
// URLSearchParams

// new URLSearchParams(init): a query string, with or without the leading "?".
n_URLSearchParams_create :: proc "c" (env: wasm.Exec_Env, init: [^]u8, n: i32) -> u64 {
	context = ctx()
	p := page_of(env)
	if int(n) > p.settings.web.url_max_length { return 0 }
	s := str(init, n)
	if len(s) > 0 && s[0] == '?' { s = s[1:] }
	po := new(Params_Object)
	po.sp = url.params_make()
	url.params_parse(&po.sp, s)
	return object_create(p, &params_vt, po, inst_of(env).index)
}

@(private)
params_of :: proc "contextless" (env: wasm.Exec_Env, h: u64) -> (^Page, ^Params_Object) {
	context = ctx()
	p := page_of(env)
	return p, params_obj(p, h)
}

n_URLSearchParams_size :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	return i32(len(po.sp.list))
}

n_URLSearchParams_append :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	p, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	url.params_append(&po.sp, utf8_scrub(str(name, nl), context.temp_allocator), utf8_scrub(str(value, vl), context.temp_allocator))
	params_update(p, po, h)
	return 0
}

// delete(name) when has_value is 0, delete(name, value) otherwise.
n_URLSearchParams_delete :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32, has_value: i32) -> i32 {
	context = ctx()
	p, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	url.params_delete(&po.sp, str(name, nl), str(value, vl), has_value != 0)
	params_update(p, po, h)
	return 0
}

// get(name): length needed, Not_Found when absent (null).
n_URLSearchParams_get :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	v, ok := url.params_get(po.sp, str(name, nl))
	if !ok { return i32(dom.Error.Not_Found) }
	return out_string(v, buf, cap)
}

// getAll(name), one value at a time: how many there are...
n_URLSearchParams_count :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	return i32(url.params_count(po.sp, str(name, nl)))
}

// ...and the n-th one.
n_URLSearchParams_getNth :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, n: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	v, ok := url.params_get_nth(po.sp, str(name, nl), int(n))
	if !ok { return i32(dom.Error.Not_Found) }
	return out_string(v, buf, cap)
}

n_URLSearchParams_has :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32, has_value: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	return url.params_has(po.sp, str(name, nl), str(value, vl), has_value != 0) ? 1 : 0
}

n_URLSearchParams_set :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	p, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	url.params_set(&po.sp, utf8_scrub(str(name, nl), context.temp_allocator), utf8_scrub(str(value, vl), context.temp_allocator))
	params_update(p, po, h)
	return 0
}

n_URLSearchParams_sort :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	p, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	url.params_sort(&po.sp)
	params_update(p, po, h)
	return 0
}

n_URLSearchParams_toString :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(url.params_serialize(po.sp, context.temp_allocator), buf, cap)
}

// Iteration: the name / value of the pair at `index` (Not_Found past the end).
n_URLSearchParams_nameAt :: proc "c" (env: wasm.Exec_Env, h: u64, index: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	if index < 0 || int(index) >= len(po.sp.list) { return i32(dom.Error.Not_Found) }
	return out_string(po.sp.list[index].name, buf, cap)
}

n_URLSearchParams_valueAt :: proc "c" (env: wasm.Exec_Env, h: u64, index: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	_, po := params_of(env, h)
	if po == nil { return i32(dom.Error.Invalid_Handle) }
	if index < 0 || int(index) >= len(po.sp.list) { return i32(dom.Error.Not_Found) }
	return out_string(po.sp.list[index].value, buf, cap)
}

url_symbols := [?]wasm.Native_Symbol{
	{"URL_parse", rawptr(n_URL_parse), "(*~*~i)I", nil},
	{"URL_canParse", rawptr(n_URL_canParse), "(*~*~i)i", nil},
	{"URL_get", rawptr(n_URL_get), "(Ii*~)i", nil},
	{"URL_set", rawptr(n_URL_set), "(Ii*~)i", nil},
	{"URL_searchParams", rawptr(n_URL_searchParams), "(I)I", nil},
	{"URLSearchParams_create", rawptr(n_URLSearchParams_create), "(*~)I", nil},
	{"URLSearchParams_size", rawptr(n_URLSearchParams_size), "(I)i", nil},
	{"URLSearchParams_append", rawptr(n_URLSearchParams_append), "(I*~*~)i", nil},
	{"URLSearchParams_delete", rawptr(n_URLSearchParams_delete), "(I*~*~i)i", nil},
	{"URLSearchParams_get", rawptr(n_URLSearchParams_get), "(I*~*~)i", nil},
	{"URLSearchParams_count", rawptr(n_URLSearchParams_count), "(I*~)i", nil},
	{"URLSearchParams_getNth", rawptr(n_URLSearchParams_getNth), "(I*~i*~)i", nil},
	{"URLSearchParams_has", rawptr(n_URLSearchParams_has), "(I*~*~i)i", nil},
	{"URLSearchParams_set", rawptr(n_URLSearchParams_set), "(I*~*~)i", nil},
	{"URLSearchParams_sort", rawptr(n_URLSearchParams_sort), "(I)i", nil},
	{"URLSearchParams_toString", rawptr(n_URLSearchParams_toString), "(I*~)i", nil},
	{"URLSearchParams_nameAt", rawptr(n_URLSearchParams_nameAt), "(Ii*~)i", nil},
	{"URLSearchParams_valueAt", rawptr(n_URLSearchParams_valueAt), "(Ii*~)i", nil},
}
