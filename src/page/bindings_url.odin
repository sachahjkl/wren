package page

// URL and URLSearchParams as host objects (import module "url"), over package url (WHATWG parsing through Lexbor, the
// standard's setters with state overrides, the form-urlencoded parser and serializer).
//
// A URL's searchParams object is linked to it both ways, as in the standard: changing the URL's search re-parses the
// list; changing the list rewrites the URL's query. Either object may be released first; the link is then dropped.

import "wb:url"

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

@(private)
parse_base :: proc(base: Maybe(string)) -> (b: url.URL, has, ok: bool) {
	s, given := base.?
	if !given { return {}, false, true }
	b, ok = url.parse(s, nil, context.temp_allocator)
	return b, true, ok
}

// new URL(input, base)
URL_parse :: proc(c: ^Call, input: string, base: Maybe(string)) -> (u64, Api_Error) {
	p := c.page
	max_len := p.settings.web.url_max_length
	if len(input) > max_len || len(base.? or_else "") > max_len { return 0, fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	b, has, ok := parse_base(base)
	if !ok { return 0, fail(c, .Type, "TypeError: invalid base URL") }
	u, uok := url.parse(input, has ? &b : nil)
	if !uok { return 0, fail(c, .Type, "TypeError: invalid URL") }
	if len(u.href) > max_len { url.destroy(&u); return 0, fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	o := new(Url_Object)
	o.u = u
	return object_create(p, &url_vt, o, c.owner), .None
}

// URL.canParse(input, base)
URL_canParse :: proc(c: ^Call, input: string, base: Maybe(string)) -> bool {
	b, has, ok := parse_base(base)
	if !ok { return false }
	_, uok := url.parse(input, has ? &b : nil, context.temp_allocator)
	return uok
}

URL_get :: proc(c: ^Call, u: Api_URL, component: Api_URLComponent) -> string {
	return url.component(u.data.u, url.Component(component), context.temp_allocator)
}

// Only href can fail; values the standard ignores leave the URL unchanged.
URL_set :: proc(c: ^Call, u: Api_URL, component: Api_URLComponent, value: string) -> Api_Error {
	p := c.page
	o := u.data
	if component == .Origin { return fail(c, .Invalid_Argument, "origin is read-only") }
	if len(value) > p.settings.web.url_max_length { return fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	nu, res := url.set_component(o.u, url.Component(component), value)
	switch res {
	case .Ok:
	case .Invalid, .Failed: return fail(c, .Type, "TypeError: invalid URL")
	case .Read_Only: return .Invalid_Argument
	}
	if len(nu.href) > p.settings.web.url_max_length { url.destroy(&nu); return fail(c, .Type, "TypeError: the URL is too long (url.max_length)") }
	url.destroy(&o.u)
	o.u = nu
	if component == .Href || component == .Search { url_sync_params(p, o, u.handle) }
	return .None
}

// url.searchParams: the same object every time (while it is not released).
URL_searchParams :: proc(c: ^Call, u: Api_URL) -> u64 {
	p := c.page
	o := u.data
	if po := params_obj(p, o.params); po != nil && po.url == u.handle { return o.params }
	po := new(Params_Object)
	po.sp = url.params_make()
	po.url = u.handle
	url.params_parse(&po.sp, o.u.query if o.u.has_query else "")
	o.params = object_create(p, &params_vt, po, c.owner)
	return o.params
}

////////////////////////////////
// URLSearchParams

// new URLSearchParams(init): a query string, with or without the leading "?".
URLSearchParams_create :: proc(c: ^Call, init: string) -> (u64, Api_Error) {
	p := c.page
	if len(init) > p.settings.web.url_max_length { return 0, fail(c, .Type, "TypeError: too long (url.max_length)") }
	s := init
	if len(s) > 0 && s[0] == '?' { s = s[1:] }
	po := new(Params_Object)
	po.sp = url.params_make()
	url.params_parse(&po.sp, s)
	return object_create(p, &params_vt, po, c.owner), .None
}

URLSearchParams_size :: proc(c: ^Call, params: Api_URLSearchParams) -> i32 { return i32(len(params.data.sp.list)) }

URLSearchParams_append :: proc(c: ^Call, params: Api_URLSearchParams, name, value: string) {
	url.params_append(&params.data.sp, name, value)
	params_update(c.page, params.data, params.handle)
}

URLSearchParams_delete :: proc(c: ^Call, params: Api_URLSearchParams, name: string, value: Maybe(string)) {
	v, has := value.?
	url.params_delete(&params.data.sp, name, v, has)
	params_update(c.page, params.data, params.handle)
}

URLSearchParams_get :: proc(c: ^Call, params: Api_URLSearchParams, name: string) -> (string, Api_Error) {
	v, ok := url.params_get(params.data.sp, name)
	if !ok { return "", .Not_Found }
	return v, .None
}

URLSearchParams_count :: proc(c: ^Call, params: Api_URLSearchParams, name: string) -> i32 { return i32(url.params_count(params.data.sp, name)) }

URLSearchParams_getNth :: proc(c: ^Call, params: Api_URLSearchParams, name: string, index: i32) -> (string, Api_Error) {
	v, ok := url.params_get_nth(params.data.sp, name, int(index))
	if !ok { return "", .Not_Found }
	return v, .None
}

URLSearchParams_has :: proc(c: ^Call, params: Api_URLSearchParams, name: string, value: Maybe(string)) -> bool {
	v, has := value.?
	return url.params_has(params.data.sp, name, v, has)
}

URLSearchParams_set :: proc(c: ^Call, params: Api_URLSearchParams, name, value: string) {
	url.params_set(&params.data.sp, name, value)
	params_update(c.page, params.data, params.handle)
}

URLSearchParams_sort :: proc(c: ^Call, params: Api_URLSearchParams) {
	url.params_sort(&params.data.sp)
	params_update(c.page, params.data, params.handle)
}

URLSearchParams_toString :: proc(c: ^Call, params: Api_URLSearchParams) -> string {
	return url.params_serialize(params.data.sp, context.temp_allocator)
}

// Iteration: the name / value of the pair at `index` (Not_Found past the end).
URLSearchParams_nameAt :: proc(c: ^Call, params: Api_URLSearchParams, index: i32) -> (string, Api_Error) {
	l := params.data.sp.list
	if index < 0 || int(index) >= len(l) { return "", .Not_Found }
	return l[index].name, .None
}

URLSearchParams_valueAt :: proc(c: ^Call, params: Api_URLSearchParams, index: i32) -> (string, Api_Error) {
	l := params.data.sp.list
	if index < 0 || int(index) >= len(l) { return "", .Not_Found }
	return l[index].value, .None
}