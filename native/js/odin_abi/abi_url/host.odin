// Package abi_url: a self-contained host implementation of the URL / URLSearchParams / URLPattern domain, bound to
// the generic boundary (package abi_host) from the shared declarations (package api_decl). It proves the ABI end to
// end without entangling `package page`: it keeps its own handle pools and uses the real WHATWG implementation
// (`wb:url`), so a test can drive a guest module against it over a live Wasmtime instance.
//
// When the engine moves to Odin, these implementations fold back into `package page` (reusing its object pool, its
// settings and its lookups); the declarations and the bridge stay the same. Here they are standalone to keep the
// prototype a separate trunk that does not touch the main build.
package abi_url

import "base:runtime"
import "../abi"
import "../abi_host"
import "../api_decl"
import "wb:base"
import "wb:url"
import "wb:wasm"

// The host context of one call. In `package page` this is the ^Call; here it is a pointer to the domain state, which
// is all the implementations need.
Host :: struct {
	urls:     base.Pool(Url_Object),
	params:   base.Pool(Params_Object),
	patterns: base.Pool(Pattern_Object),
	last_error: abi.Api_Error,   // the exception a raising call recorded (read back like web.Exception_code)
}

Url_Object :: struct {
	u:      url.URL,
	params: api_decl.URLSearchParams,   // its search-params object, 0 until asked for
}

Params_Object :: struct {
	sp:  url.Search_Params,
	url: api_decl.URL,   // the URL it belongs to, 0 for a stand-alone one
}

Pattern_Object :: struct {
	pat: url.Url_Pattern,
}

// One global instance for the prototype. (In the browser there is one host object graph per page; here one process-
// wide host is enough to drive the benchmark and the round-trip test.)
host: Host

host_destroy :: proc() {
	it: u32
	for _, o in base.pool_next(&host.urls, &it) { url.destroy(&o.u) }
	it = 0
	for _, o in base.pool_next(&host.params, &it) { url.params_destroy(&o.sp) }
	it = 0
	for _, o in base.pool_next(&host.patterns, &it) { url.pattern_destroy(&o.pat) }
	base.pool_destroy(&host.urls)
	base.pool_destroy(&host.params)
	base.pool_destroy(&host.patterns)
}

////////////////////////////////
// The host configuration the bridge calls back into.

begin :: proc "contextless" (inst: ^wasm.Instance) -> ^Host { return &host }
end :: proc(ctx: ^Host) {}
raise :: proc(ctx: ^Host, inst: ^wasm.Instance, code: abi.Api_Error) { ctx.last_error = code }

// A string argument is checked for UTF-8 before it reaches an implementation (a Type error otherwise). wasm's helper
// takes a string; this is the same over a byte span.
valid_utf8_bytes :: proc "contextless" (s: []u8) -> bool {
	context = wasm.default_context()
	return wasm.valid_utf8(string(s))
}

config :: proc() -> abi_host.Host_Config(^Host) {
	return abi_host.Host_Config(^Host){
		module = "url_abi",
		begin  = begin,
		end    = end,
		utf8   = valid_utf8_bytes,
		raise  = raise,
	}
}

// Build the registry: bind each declaration to its implementation. The operation numbers are assigned in this order
// and must match the guest's (api_decl is the shared order; the guest's stubs pass the same indices). `register`
// returns the registry and the single `host_call` import for wasm.register.
Registry :: abi_host.Registry(^Host)

build_registry :: proc() -> (reg: Registry) {
	reg = abi_host.registry_make(config())
	abi_host.bind(&reg, "URL_parse", api_decl.URL_parse, URL_parse)
	abi_host.bind(&reg, "URL_canParse", api_decl.URL_canParse, URL_canParse)
	abi_host.bind(&reg, "URL_get", api_decl.URL_get, URL_get)
	abi_host.bind(&reg, "URL_set", api_decl.URL_set, URL_set)
	abi_host.bind(&reg, "URL_searchParams", api_decl.URL_searchParams, URL_searchParams)
	abi_host.bind(&reg, "URLSearchParams_create", api_decl.URLSearchParams_create, URLSearchParams_create)
	abi_host.bind(&reg, "URLSearchParams_size", api_decl.URLSearchParams_size, URLSearchParams_size)
	abi_host.bind(&reg, "URLSearchParams_append", api_decl.URLSearchParams_append, URLSearchParams_append)
	abi_host.bind(&reg, "URLSearchParams_delete", api_decl.URLSearchParams_delete, URLSearchParams_delete)
	abi_host.bind(&reg, "URLSearchParams_get", api_decl.URLSearchParams_get, URLSearchParams_get)
	abi_host.bind(&reg, "URLSearchParams_has", api_decl.URLSearchParams_has, URLSearchParams_has)
	abi_host.bind(&reg, "URLSearchParams_set", api_decl.URLSearchParams_set, URLSearchParams_set)
	abi_host.bind(&reg, "URLSearchParams_sort", api_decl.URLSearchParams_sort, URLSearchParams_sort)
	abi_host.bind(&reg, "URLSearchParams_toString", api_decl.URLSearchParams_toString, URLSearchParams_toString)
	abi_host.bind_manual(&reg, "URLPattern_create", URLPattern_create_manual)   // a dictionary argument: the escape hatch
	abi_host.bind(&reg, "URLPattern_component", api_decl.URLPattern_component, URLPattern_component)
	abi_host.bind(&reg, "URLPattern_hasRegExpGroups", api_decl.URLPattern_hasRegExpGroups, URLPattern_hasRegExpGroups)
	abi_host.bind(&reg, "URLPattern_test", api_decl.URLPattern_test, URLPattern_test)
	return
}

_ :: runtime
