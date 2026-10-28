// The guest bindings of the URL / URLSearchParams / URLPattern domain, over the generic serialised boundary. Each is
// thin typed glue: open a writer, serialise the arguments (the compiler picks the marshaller per type), transport by
// operation number, decode the result. No generator produced this; it is the guest half of the api_decl contract,
// the mirror of abi_url's host half. A later integration folds these into sdk/odin/web as the shipped SDK.
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

URL :: api_decl.URL
URLSearchParams :: api_decl.URLSearchParams
URLPattern :: api_decl.URLPattern
URLComponent :: api_decl.URLComponent
URLPatternComponent :: api_decl.URLPatternComponent
URLPatternInit :: api_decl.URLPatternInit

////////////////////////////////
// URL

URL_parse :: proc(input: string, base: Maybe(string) = nil) -> (URL, abi.Api_Error) {
	w := begin()
	arg(&w, input)
	arg_maybe(&w, base)
	r, st := transport(OP_URL_parse, w.pos)
	if st != .None { return 0, st }
	return ret_scalar(&r, URL), .None
}

URL_canParse :: proc(input: string, base: Maybe(string) = nil) -> bool {
	w := begin()
	arg(&w, input)
	arg_maybe(&w, base)
	r, st := transport(OP_URL_canParse, w.pos)
	if st != .None { return false }
	return ret_scalar(&r, bool)
}

URL_get :: proc(u: URL, component: URLComponent) -> string {
	w := begin()
	arg(&w, u)
	arg(&w, component)
	r, st := transport(OP_URL_get, w.pos)
	if st != .None { return "" }
	return ret_string(&r)
}

URL_set :: proc(u: URL, component: URLComponent, value: string) -> abi.Api_Error {
	w := begin()
	arg(&w, u)
	arg(&w, component)
	arg(&w, value)
	_, st := transport(OP_URL_set, w.pos)
	return st
}

URL_searchParams :: proc(u: URL) -> URLSearchParams {
	w := begin()
	arg(&w, u)
	r, st := transport(OP_URL_searchParams, w.pos)
	if st != .None { return 0 }
	return ret_scalar(&r, URLSearchParams)
}

////////////////////////////////
// URLSearchParams

URLSearchParams_create :: proc(init: string = "") -> (URLSearchParams, abi.Api_Error) {
	w := begin()
	arg(&w, init)
	r, st := transport(OP_URLSearchParams_create, w.pos)
	if st != .None { return 0, st }
	return ret_scalar(&r, URLSearchParams), .None
}

URLSearchParams_size :: proc(params: URLSearchParams) -> i32 {
	w := begin()
	arg(&w, params)
	r, st := transport(OP_URLSearchParams_size, w.pos)
	if st != .None { return 0 }
	return ret_scalar(&r, i32)
}

URLSearchParams_append :: proc(params: URLSearchParams, name, value: string) {
	w := begin()
	arg(&w, params)
	arg(&w, name)
	arg(&w, value)
	transport(OP_URLSearchParams_append, w.pos)
}

URLSearchParams_delete :: proc(params: URLSearchParams, name: string, value: Maybe(string) = nil) {
	w := begin()
	arg(&w, params)
	arg(&w, name)
	arg_maybe(&w, value)
	transport(OP_URLSearchParams_delete, w.pos)
}

URLSearchParams_get :: proc(params: URLSearchParams, name: string) -> (string, abi.Api_Error) {
	w := begin()
	arg(&w, params)
	arg(&w, name)
	r, st := transport(OP_URLSearchParams_get, w.pos)
	if st != .None { return "", st }
	return ret_string(&r), .None
}

URLSearchParams_has :: proc(params: URLSearchParams, name: string, value: Maybe(string) = nil) -> bool {
	w := begin()
	arg(&w, params)
	arg(&w, name)
	arg_maybe(&w, value)
	r, st := transport(OP_URLSearchParams_has, w.pos)
	if st != .None { return false }
	return ret_scalar(&r, bool)
}

URLSearchParams_set :: proc(params: URLSearchParams, name, value: string) {
	w := begin()
	arg(&w, params)
	arg(&w, name)
	arg(&w, value)
	transport(OP_URLSearchParams_set, w.pos)
}

URLSearchParams_sort :: proc(params: URLSearchParams) {
	w := begin()
	arg(&w, params)
	transport(OP_URLSearchParams_sort, w.pos)
}

URLSearchParams_toString :: proc(params: URLSearchParams) -> string {
	w := begin()
	arg(&w, params)
	r, st := transport(OP_URLSearchParams_toString, w.pos)
	if st != .None { return "" }
	return ret_string(&r)
}

////////////////////////////////
// URLPattern

// The dictionary is written field by field in declaration order, matching abi.decode_arg's walk on the host side.
URLPattern_create :: proc(init: URLPatternInit) -> (URLPattern, abi.Api_Error) {
	w := begin()
	arg(&w, init.protocol); arg(&w, init.has_protocol)
	arg(&w, init.username); arg(&w, init.has_username)
	arg(&w, init.password); arg(&w, init.has_password)
	arg(&w, init.hostname); arg(&w, init.has_hostname)
	arg(&w, init.port);     arg(&w, init.has_port)
	arg(&w, init.pathname); arg(&w, init.has_pathname)
	arg(&w, init.search);   arg(&w, init.has_search)
	arg(&w, init.hash);     arg(&w, init.has_hash)
	arg(&w, init.base);     arg(&w, init.has_base)
	arg(&w, init.ignore_case)
	r, st := transport(OP_URLPattern_create, w.pos)
	if st != .None { return 0, st }
	return ret_scalar(&r, URLPattern), .None
}

URLPattern_component :: proc(pattern: URLPattern, component: URLPatternComponent) -> string {
	w := begin()
	arg(&w, pattern)
	arg(&w, component)
	r, st := transport(OP_URLPattern_component, w.pos)
	if st != .None { return "" }
	return ret_string(&r)
}

URLPattern_hasRegExpGroups :: proc(pattern: URLPattern) -> bool {
	w := begin()
	arg(&w, pattern)
	r, st := transport(OP_URLPattern_hasRegExpGroups, w.pos)
	if st != .None { return false }
	return ret_scalar(&r, bool)
}

URLPattern_test :: proc(pattern: URLPattern, input: string, base: Maybe(string) = nil) -> bool {
	w := begin()
	arg(&w, pattern)
	arg(&w, input)
	arg_maybe(&w, base)
	r, st := transport(OP_URLPattern_test, w.pos)
	if st != .None { return false }
	return ret_scalar(&r, bool)
}
