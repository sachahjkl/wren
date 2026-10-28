package api_decl

import "../abi"

// The boundary's own conformance declarations: one function per shape the bridges carry, so that every shape crosses
// both paths for real (native/js/odin_abi/check: serialised, in process; native/js/odin_abi/bench: scalar, over
// Wasmtime). Not a web API; the host implementations are in abi_url/abitest.odin.

// Eight arguments of every scalar and span shape: returns a checksum of all of them.
Abi_Mix8 :: #type proc(a: i32, b: i64, c: f64, d: bool, e: URLComponent, f: string, g: Maybe(string), h: URL) -> i64
// A slice argument (a sum) and a slice result (a split on ',').
Abi_Sum :: #type proc(xs: []i64) -> i64
Abi_Split :: #type proc(s: string) -> []string
// An optional scalar argument, an optional string result (absent = the name was not found).
Abi_Opt :: #type proc(x: Maybe(i32)) -> i32
Abi_Find :: #type proc(name: string) -> Maybe(string)
// An owned handle result: the caller releases it.
Abi_Make :: #type proc(href: string) -> (abi.Owned(URL), abi.Api_Error)
// A dictionary with strings, an optional, a slice: in and back out.
Abi_Dict :: struct {
	name:  string,
	count: i32,
	ratio: f64,
	flag:  bool,
	tag:   Maybe(string),
	ids:   []i32,
	kind:  URLComponent,
}
Abi_Echo :: #type proc(d: Abi_Dict) -> (Abi_Dict, abi.Api_Error)
