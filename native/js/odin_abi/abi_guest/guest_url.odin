// The guest bindings of the URL / URLSearchParams / URLPattern domain, over the generic serialised boundary. Each is
// the same three steps: write the arguments (`arg`, one marshaller per type, chosen by the compiler), `finish` by
// operation number (the results decoded by the declaration's types), and abi.must_match, which fails the build if the
// stub's signature drifts from api_decl. A later integration folds these into sdk/odin/web as the shipped SDK.
package abi_guest

import "../abi"
import "../api_decl"

// Operation numbers, in api_decl / abi_url.build_registry order.
OP_URL_parse :: 0
OP_URL_canParse :: 1
OP_URL_get :: 2
OP_URL_set :: 3
OP_URL_searchParams :: 4
OP_URLSearchParams_create :: 5
OP_URLSearchParams_size :: 6
OP_URLSearchParams_append :: 7
OP_URLSearchParams_delete :: 8
OP_URLSearchParams_get :: 9
OP_URLSearchParams_has :: 10
OP_URLSearchParams_set :: 11
OP_URLSearchParams_sort :: 12
OP_URLSearchParams_toString :: 13
OP_URLPattern_create :: 14
OP_URLPattern_component :: 15
OP_URLPattern_hasRegExpGroups :: 16
OP_URLPattern_test :: 17
// (18 ..< 25: the conformance functions, guest_abitest.odin)
OP_URLSearchParams_count :: 25
OP_URLSearchParams_getNth :: 26
OP_URLSearchParams_nameAt :: 27
OP_URLSearchParams_valueAt :: 28

URL :: api_decl.URL
URLSearchParams :: api_decl.URLSearchParams
URLPattern :: api_decl.URLPattern
URLComponent :: api_decl.URLComponent
URLPatternComponent :: api_decl.URLPatternComponent
URLPatternInit :: api_decl.URLPatternInit

@(private) none: abi.Nothing

////////////////////////////////
// URL

URL_parse :: proc(input: string, base: Maybe(string)) -> (u: URL, err: abi.Api_Error) {
	w := begin(); arg(&w, input); arg(&w, base)
	err = finish(OP_URL_parse, &w, api_decl.URL_parse, &u)
	return
}

URL_canParse :: proc(input: string, base: Maybe(string)) -> (ok: bool) {
	w := begin(); arg(&w, input); arg(&w, base)
	finish(OP_URL_canParse, &w, api_decl.URL_canParse, &ok)
	return
}

URL_get :: proc(u: URL, component: URLComponent) -> (s: string, err: abi.Api_Error) {
	w := begin(); arg(&w, u); arg(&w, component)
	err = finish(OP_URL_get, &w, api_decl.URL_get, &s)
	return
}

URL_set :: proc(u: URL, component: URLComponent, value: string) -> abi.Api_Error {
	w := begin(); arg(&w, u); arg(&w, component); arg(&w, value)
	return finish(OP_URL_set, &w, api_decl.URL_set, &none)
}

URL_searchParams :: proc(u: URL) -> (p: URLSearchParams) {
	w := begin(); arg(&w, u)
	finish(OP_URL_searchParams, &w, api_decl.URL_searchParams, &p)
	return
}

////////////////////////////////
// URLSearchParams

URLSearchParams_create :: proc(init: string) -> (p: URLSearchParams, err: abi.Api_Error) {
	w := begin(); arg(&w, init)
	err = finish(OP_URLSearchParams_create, &w, api_decl.URLSearchParams_create, &p)
	return
}

URLSearchParams_size :: proc(params: URLSearchParams) -> (n: i32) {
	w := begin(); arg(&w, params)
	finish(OP_URLSearchParams_size, &w, api_decl.URLSearchParams_size, &n)
	return
}

URLSearchParams_append :: proc(params: URLSearchParams, name: string, value: string) {
	w := begin(); arg(&w, params); arg(&w, name); arg(&w, value)
	finish(OP_URLSearchParams_append, &w, api_decl.URLSearchParams_append, &none)
}

URLSearchParams_delete :: proc(params: URLSearchParams, name: string, value: Maybe(string)) {
	w := begin(); arg(&w, params); arg(&w, name); arg(&w, value)
	finish(OP_URLSearchParams_delete, &w, api_decl.URLSearchParams_delete, &none)
}

URLSearchParams_get :: proc(params: URLSearchParams, name: string) -> (s: string, err: abi.Api_Error) {
	w := begin(); arg(&w, params); arg(&w, name)
	err = finish(OP_URLSearchParams_get, &w, api_decl.URLSearchParams_get, &s)
	return
}

URLSearchParams_has :: proc(params: URLSearchParams, name: string, value: Maybe(string)) -> (ok: bool) {
	w := begin(); arg(&w, params); arg(&w, name); arg(&w, value)
	finish(OP_URLSearchParams_has, &w, api_decl.URLSearchParams_has, &ok)
	return
}

URLSearchParams_set :: proc(params: URLSearchParams, name: string, value: string) {
	w := begin(); arg(&w, params); arg(&w, name); arg(&w, value)
	finish(OP_URLSearchParams_set, &w, api_decl.URLSearchParams_set, &none)
}

URLSearchParams_sort :: proc(params: URLSearchParams) {
	w := begin(); arg(&w, params)
	finish(OP_URLSearchParams_sort, &w, api_decl.URLSearchParams_sort, &none)
}

URLSearchParams_toString :: proc(params: URLSearchParams) -> (s: string, err: abi.Api_Error) {
	w := begin(); arg(&w, params)
	err = finish(OP_URLSearchParams_toString, &w, api_decl.URLSearchParams_toString, &s)
	return
}

URLSearchParams_count :: proc(params: URLSearchParams, name: string) -> (n: i32) {
	w := begin(); arg(&w, params); arg(&w, name)
	finish(OP_URLSearchParams_count, &w, api_decl.URLSearchParams_count, &n)
	return
}

URLSearchParams_getNth :: proc(params: URLSearchParams, name: string, index: i32) -> (s: string, err: abi.Api_Error) {
	w := begin(); arg(&w, params); arg(&w, name); arg(&w, index)
	err = finish(OP_URLSearchParams_getNth, &w, api_decl.URLSearchParams_getNth, &s)
	return
}

URLSearchParams_nameAt :: proc(params: URLSearchParams, index: i32) -> (s: string, err: abi.Api_Error) {
	w := begin(); arg(&w, params); arg(&w, index)
	err = finish(OP_URLSearchParams_nameAt, &w, api_decl.URLSearchParams_nameAt, &s)
	return
}

URLSearchParams_valueAt :: proc(params: URLSearchParams, index: i32) -> (s: string, err: abi.Api_Error) {
	w := begin(); arg(&w, params); arg(&w, index)
	err = finish(OP_URLSearchParams_valueAt, &w, api_decl.URLSearchParams_valueAt, &s)
	return
}

////////////////////////////////
// URLPattern

// The dictionary is one argument: abi.encode_ret walks its fields (the host decodes them the same way).
URLPattern_create :: proc(init: URLPatternInit) -> (p: URLPattern, err: abi.Api_Error) {
	w := begin(); arg(&w, init)
	err = finish(OP_URLPattern_create, &w, api_decl.URLPattern_create, &p)
	return
}

URLPattern_component :: proc(pattern: URLPattern, component: URLPatternComponent) -> (s: string) {
	w := begin(); arg(&w, pattern); arg(&w, component)
	finish(OP_URLPattern_component, &w, api_decl.URLPattern_component, &s)
	return
}

URLPattern_hasRegExpGroups :: proc(pattern: URLPattern) -> (ok: bool) {
	w := begin(); arg(&w, pattern)
	finish(OP_URLPattern_hasRegExpGroups, &w, api_decl.URLPattern_hasRegExpGroups, &ok)
	return
}

URLPattern_test :: proc(pattern: URLPattern, input: string, base: Maybe(string)) -> (ok: bool) {
	w := begin(); arg(&w, pattern); arg(&w, input); arg(&w, base)
	finish(OP_URLPattern_test, &w, api_decl.URLPattern_test, &ok)
	return
}

// Each stub's signature against its declaration, at compile time (a stub cannot name its own type in its body).
@(private)
stubs_match_url :: proc() {
	abi.must_match(api_decl.URL_parse, type_of(URL_parse))
	abi.must_match(api_decl.URL_canParse, type_of(URL_canParse))
	abi.must_match(api_decl.URL_get, type_of(URL_get))
	abi.must_match(api_decl.URL_set, type_of(URL_set))
	abi.must_match(api_decl.URL_searchParams, type_of(URL_searchParams))
	abi.must_match(api_decl.URLSearchParams_create, type_of(URLSearchParams_create))
	abi.must_match(api_decl.URLSearchParams_size, type_of(URLSearchParams_size))
	abi.must_match(api_decl.URLSearchParams_append, type_of(URLSearchParams_append))
	abi.must_match(api_decl.URLSearchParams_delete, type_of(URLSearchParams_delete))
	abi.must_match(api_decl.URLSearchParams_get, type_of(URLSearchParams_get))
	abi.must_match(api_decl.URLSearchParams_has, type_of(URLSearchParams_has))
	abi.must_match(api_decl.URLSearchParams_set, type_of(URLSearchParams_set))
	abi.must_match(api_decl.URLSearchParams_sort, type_of(URLSearchParams_sort))
	abi.must_match(api_decl.URLSearchParams_toString, type_of(URLSearchParams_toString))
	abi.must_match(api_decl.URLSearchParams_count, type_of(URLSearchParams_count))
	abi.must_match(api_decl.URLSearchParams_getNth, type_of(URLSearchParams_getNth))
	abi.must_match(api_decl.URLSearchParams_nameAt, type_of(URLSearchParams_nameAt))
	abi.must_match(api_decl.URLSearchParams_valueAt, type_of(URLSearchParams_valueAt))
	abi.must_match(api_decl.URLPattern_create, type_of(URLPattern_create))
	abi.must_match(api_decl.URLPattern_component, type_of(URLPattern_component))
	abi.must_match(api_decl.URLPattern_hasRegExpGroups, type_of(URLPattern_hasRegExpGroups))
	abi.must_match(api_decl.URLPattern_test, type_of(URLPattern_test))
}
