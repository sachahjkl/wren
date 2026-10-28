// The implementations, with the shape the host side of each api_decl signature takes:
//   proc(ctx: ^Host, <api_decl arguments>) -> <api_decl result>
// i.e. api_decl's signature with a leading context. The bridge decodes the arguments, calls one of these, and
// serialises the result. A handle argument arrives as its distinct type (api_decl.URL ...); these resolve it against
// the host pools. A created handle is the caller's to release; URL_searchParams hands back a borrowed one.
package abi_url

import "../abi"
import "../abi_host"
import "../api_decl"
import "wb:base"
import "wb:url"
import "wb:wasm"

@(private) H :: base.Handle
@(private) url_h :: #force_inline proc(h: api_decl.URL) -> H { return H(h) }
@(private) params_h :: #force_inline proc(h: api_decl.URLSearchParams) -> H { return H(h) }
@(private) pat_h :: #force_inline proc(h: api_decl.URLPattern) -> H { return H(h) }

@(private) url_obj :: proc(h: api_decl.URL) -> ^Url_Object { return base.pool_get(&host.urls, url_h(h)) }
@(private) params_obj :: proc(h: api_decl.URLSearchParams) -> ^Params_Object { return base.pool_get(&host.params, params_h(h)) }
@(private) pattern_obj :: proc(h: api_decl.URLPattern) -> ^Pattern_Object { return base.pool_get(&host.patterns, pat_h(h)) }

@(private)
parse_base :: proc(base_url: Maybe(string)) -> (b: url.URL, has, ok: bool) {
	s, given := base_url.?
	if !given { return {}, false, true }
	b, ok = url.parse(s, nil, context.temp_allocator)
	return b, true, ok
}

////////////////////////////////
// URL

URL_parse :: proc(ctx: ^Host, input: string, base_url: Maybe(string)) -> (api_decl.URL, abi.Api_Error) {
	b, has, ok := parse_base(base_url)
	if !ok { return 0, .Type }
	u, uok := url.parse(input, has ? &b : nil)
	if !uok { return 0, .Type }
	h, _ := base.pool_insert(&host.urls, Url_Object{u = u})
	return api_decl.URL(h), .None
}

URL_canParse :: proc(ctx: ^Host, input: string, base_url: Maybe(string)) -> bool {
	b, has, ok := parse_base(base_url)
	if !ok { return false }
	_, uok := url.parse(input, has ? &b : nil, context.temp_allocator)
	return uok
}

URL_get :: proc(ctx: ^Host, u: api_decl.URL, component: api_decl.URLComponent) -> string {
	o := url_obj(u)
	if o == nil { return "" }
	return url.component(o.u, url.Component(component), context.temp_allocator)
}

URL_set :: proc(ctx: ^Host, u: api_decl.URL, component: api_decl.URLComponent, value: string) -> abi.Api_Error {
	o := url_obj(u)
	if o == nil { return .Invalid_Handle }
	if component == .Origin { return .Invalid_Argument }
	nu, res := url.set_component(o.u, url.Component(component), value)
	#partial switch res {
	case .Invalid, .Failed: return .Type
	case .Read_Only: return .Invalid_Argument
	}
	url.destroy(&o.u)
	o.u = nu
	return .None
}

URL_searchParams :: proc(ctx: ^Host, u: api_decl.URL) -> api_decl.URLSearchParams {
	o := url_obj(u)
	if o == nil { return 0 }
	if po := params_obj(o.params); po != nil && po.url == u { return o.params }
	sp := url.params_make()
	url.params_parse(&sp, o.u.query if o.u.has_query else "")
	h, _ := base.pool_insert(&host.params, Params_Object{sp = sp, url = u})
	o.params = api_decl.URLSearchParams(h)
	return o.params
}

////////////////////////////////
// URLSearchParams

@(private)
params_update :: proc(po: ^Params_Object) {
	if po.url == 0 { return }
	uo := url_obj(po.url)
	if uo == nil { po.url = 0; return }
	q := url.params_serialize(po.sp, context.temp_allocator)
	nu, res := url.set_component(uo.u, .Search, q)
	if res != .Ok { return }
	url.destroy(&uo.u)
	uo.u = nu
}

URLSearchParams_create :: proc(ctx: ^Host, init: string) -> (api_decl.URLSearchParams, abi.Api_Error) {
	s := init
	if len(s) > 0 && s[0] == '?' { s = s[1:] }
	sp := url.params_make()
	url.params_parse(&sp, s)
	h, _ := base.pool_insert(&host.params, Params_Object{sp = sp})
	return api_decl.URLSearchParams(h), .None
}

URLSearchParams_size :: proc(ctx: ^Host, params: api_decl.URLSearchParams) -> i32 {
	o := params_obj(params)
	return o != nil ? i32(len(o.sp.list)) : 0
}

URLSearchParams_append :: proc(ctx: ^Host, params: api_decl.URLSearchParams, name: string, value: string) {
	o := params_obj(params)
	if o == nil { return }
	url.params_append(&o.sp, name, value)
	params_update(o)
}

URLSearchParams_delete :: proc(ctx: ^Host, params: api_decl.URLSearchParams, name: string, value: Maybe(string)) {
	o := params_obj(params)
	if o == nil { return }
	v, has := value.?
	url.params_delete(&o.sp, name, v, has)
	params_update(o)
}

URLSearchParams_get :: proc(ctx: ^Host, params: api_decl.URLSearchParams, name: string) -> (string, abi.Api_Error) {
	o := params_obj(params)
	if o == nil { return "", .Invalid_Handle }
	v, ok := url.params_get(o.sp, name)
	if !ok { return "", .Not_Found }
	return v, .None
}

URLSearchParams_has :: proc(ctx: ^Host, params: api_decl.URLSearchParams, name: string, value: Maybe(string)) -> bool {
	o := params_obj(params)
	if o == nil { return false }
	v, has := value.?
	return url.params_has(o.sp, name, v, has)
}

URLSearchParams_set :: proc(ctx: ^Host, params: api_decl.URLSearchParams, name: string, value: string) {
	o := params_obj(params)
	if o == nil { return }
	url.params_set(&o.sp, name, value)
	params_update(o)
}

URLSearchParams_sort :: proc(ctx: ^Host, params: api_decl.URLSearchParams) {
	o := params_obj(params)
	if o == nil { return }
	url.params_sort(&o.sp)
	params_update(o)
}

URLSearchParams_toString :: proc(ctx: ^Host, params: api_decl.URLSearchParams) -> string {
	o := params_obj(params)
	if o == nil { return "" }
	return url.params_serialize(o.sp, context.temp_allocator)
}

////////////////////////////////
// URLPattern

@(private)
pattern_component :: proc(c: api_decl.URLPatternComponent) -> url.Pattern_Component {
	return url.Pattern_Component(c)
}

// A dictionary argument: the manual escape hatch (abi_host.bind_manual). The nineteen fields of URLPatternInit are
// read from the wire in declaration order — the order the guest wrote them (guest_url.odin) — then the pattern is
// built and its handle written back. Constructors are off the hot path, so a hand-written codec here keeps the
// generic marshaller free of struct walking. The field read is still the shared wire helper (abi.read_*), so a drift
// in the field list shows up as a wrong-looking pattern in the domain's conformance test.
URLPattern_create_manual :: proc(cfg: ^abi_host.Host_Config(^Host), inst: ^wasm.Instance, r: ^abi.Reader, w: ^abi.Writer) -> abi.Api_Error {
	rd :: proc(r: ^abi.Reader, v: proc "contextless" (s: []u8) -> bool) -> (s: string, present: bool, bad: bool) {
		span, _ := abi.read_span(r)
		present = abi.read_scalar(r, u8) != 0
		if present && v != nil && !v(span) { return "", true, true }
		return string(span), present, false
	}
	init: url.Pattern_Init
	bad: bool
	s: string; present: bool; b: bool
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.protocol = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.username = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.password = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.hostname = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.port = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.pathname = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.search = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.hash = s }
	s, present, b = rd(r, cfg.utf8); bad |= b; if present { init.base_url = s }
	ignore_case := abi.read_scalar(r, u8) != 0
	if bad || !r.ok { return .Type }
	pat, ok := url.pattern_create(init, ignore_case)
	if !ok { return .Type }
	h, _ := base.pool_insert(&host.patterns, Pattern_Object{pat = pat})
	abi.write_scalar(w, u64(h))
	return .None
}

URLPattern_component :: proc(ctx: ^Host, pattern: api_decl.URLPattern, component: api_decl.URLPatternComponent) -> string {
	o := pattern_obj(pattern)
	if o == nil { return "" }
	return url.pattern_component_string(&o.pat, pattern_component(component))
}

URLPattern_hasRegExpGroups :: proc(ctx: ^Host, pattern: api_decl.URLPattern) -> bool {
	o := pattern_obj(pattern)
	if o == nil { return false }
	return url.pattern_has_regexp_groups(&o.pat)
}

URLPattern_test :: proc(ctx: ^Host, pattern: api_decl.URLPattern, input: string, base_url: Maybe(string)) -> bool {
	o := pattern_obj(pattern)
	if o == nil { return false }
	_, matched := url.pattern_match_url(&o.pat, input, base_url)
	return matched
}
