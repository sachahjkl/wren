// Package api_decl: the shared declarations of the web API, imported by the host (Odin, native) AND by the engine
// guest (Odin, wasm32: `when ODIN_ARCH == .wasm32`). One source of truth for the boundary: the handle kinds (distinct
// types, so a URL cannot be passed where a URLSearchParams is wanted), the enumerations, the dictionaries (structs
// with default values), and the procedure signatures (arguments, result, `raises`). The host binds an implementation
// to each name and the guest calls it; because both read these same declarations, a shape mismatch is a compile
// error. No code is generated from this package for the boundary; only the documentation / conformance tool reads it
// with core:odin/parser.
//
// This slice declares the URL, URLSearchParams and URLPattern domain (the WHATWG URL Standard and the URL Pattern
// Standard), migrated from api/url.widl. A later migration adds the other domains next to it.
package api_decl

import "../abi"

// Handles. Each is a distinct abi.Handle so the compiler keeps the kinds apart; on the wire each is a u64.
URL :: distinct abi.Handle
URLSearchParams :: distinct abi.Handle
URLPattern :: distinct abi.Handle

// A component of a URL (also used by Location).
URLComponent :: enum i32 {
	Href, Protocol, Username, Password, Host, Hostname, Port, Pathname, Search, Hash, Origin,
}

// A component of a URLPattern (the eight pattern components, in the spec's order).
URLPatternComponent :: enum i32 {
	Protocol, Username, Password, Hostname, Port, Pathname, Search, Hash,
}

// A URLPatternInit dictionary: the eight optional component strings plus an optional base, and the ignoreCase option.
// A dictionary is a struct with default values; an absent member is the zero value, told apart by its `has_*` flag
// (the WebIDL distinction between "property absent" and "property present and empty"). The serialised path carries a
// dictionary field by field, so a long WebIDL argument list (URLPattern's) becomes one struct argument here.
URLPatternInit :: struct {
	protocol:     string,
	has_protocol: bool,
	username:     string,
	has_username: bool,
	password:     string,
	has_password: bool,
	hostname:     string,
	has_hostname: bool,
	port:         string,
	has_port:     bool,
	pathname:     string,
	has_pathname: bool,
	search:       string,
	has_search:   bool,
	hash:         string,
	has_hash:     bool,
	base:         string,
	has_base:     bool,
	ignore_case:  bool,
}

// The procedure signatures. Each is a proc type the host implements and the guest calls. `raises` is expressed by an
// Api_Error as the last return value. Ownership of a created handle is the caller's (released with Object_release),
// as today; a signature that hands back a borrowed handle (URL_searchParams: the same object every call) is noted.
//
// The signatures carry no context parameter here: the host binds an implementation of shape
//   proc(ctx: ^Call, <these arguments>) -> <this result>
// and the guest a stub of shape
//   proc(<these arguments>) -> <this result>
// The abi bridge adds / drops the context; these declarations are the arguments-and-result contract both share.

// new URL(input, base): Type on an invalid or too-long URL.
URL_parse :: #type proc(input: string, base: Maybe(string)) -> (URL, abi.Api_Error)
// URL.canParse(input, base)
URL_canParse :: #type proc(input: string, base: Maybe(string)) -> bool
// A getter: url.href, url.protocol... (Invalid_Handle for a released URL)
URL_get :: #type proc(url: URL, component: URLComponent) -> (string, abi.Api_Error)
// A setter. Only href can fail (Type); Origin is read-only (Invalid_Argument).
URL_set :: #type proc(url: URL, component: URLComponent, value: string) -> abi.Api_Error
// url.searchParams: the same object every time (a borrowed handle, released with its URL).
URL_searchParams :: #type proc(url: URL) -> URLSearchParams

// new URLSearchParams(init): Type when too long.
URLSearchParams_create :: #type proc(init: string) -> (URLSearchParams, abi.Api_Error)
// params.size
URLSearchParams_size :: #type proc(params: URLSearchParams) -> i32
// params.append(name, value)
URLSearchParams_append :: #type proc(params: URLSearchParams, name: string, value: string)
// params.delete(name, value?)
URLSearchParams_delete :: #type proc(params: URLSearchParams, name: string, value: Maybe(string))
// params.get(name): Not_Found when absent.
URLSearchParams_get :: #type proc(params: URLSearchParams, name: string) -> (string, abi.Api_Error)
// params.has(name, value?)
URLSearchParams_has :: #type proc(params: URLSearchParams, name: string, value: Maybe(string)) -> bool
// params.set(name, value)
URLSearchParams_set :: #type proc(params: URLSearchParams, name: string, value: string)
// params.sort()
URLSearchParams_sort :: #type proc(params: URLSearchParams)
// params.toString() (Invalid_Handle for a released object)
URLSearchParams_toString :: #type proc(params: URLSearchParams) -> (string, abi.Api_Error)
// params.getAll(name).length
URLSearchParams_count :: #type proc(params: URLSearchParams, name: string) -> i32
// params.getAll(name)[index]: Not_Found past the end.
URLSearchParams_getNth :: #type proc(params: URLSearchParams, name: string, index: i32) -> (string, abi.Api_Error)
// The name / the value of the pair at `index` (iteration): Not_Found past the end.
URLSearchParams_nameAt :: #type proc(params: URLSearchParams, index: i32) -> (string, abi.Api_Error)
URLSearchParams_valueAt :: #type proc(params: URLSearchParams, index: i32) -> (string, abi.Api_Error)

// new URLPattern(init, {ignoreCase}): the whole dictionary as one argument. Type on a malformed pattern.
URLPattern_create :: #type proc(init: URLPatternInit) -> (URLPattern, abi.Api_Error)
// A component's normalized pattern string (the getters protocol, username, ...).
URLPattern_component :: #type proc(pattern: URLPattern, component: URLPatternComponent) -> string
// pattern.hasRegExpGroups
URLPattern_hasRegExpGroups :: #type proc(pattern: URLPattern) -> bool
// test(): run against a URL string resolved against base. Returns true when it matched.
URLPattern_test :: #type proc(pattern: URLPattern, input: string, base: Maybe(string)) -> bool
