// The guest stubs of the boundary's conformance functions (api_decl/abitest.odin), op numbers after the URL domain's.
package abi_guest

import "../abi"
import "../api_decl"

OP_Abi_Mix8  :: 18
OP_Abi_Sum   :: 19
OP_Abi_Split :: 20
OP_Abi_Opt   :: 21
OP_Abi_Find  :: 22
OP_Abi_Make  :: 23
OP_Abi_Echo  :: 24

Abi_Mix8 :: proc(a: i32, b: i64, c: f64, d: bool, e: URLComponent, f: string, g: Maybe(string), h: URL) -> (s: i64) {
	w := begin(); arg(&w, a); arg(&w, b); arg(&w, c); arg(&w, d); arg(&w, e); arg(&w, f); arg(&w, g); arg(&w, h)
	finish(OP_Abi_Mix8, &w, api_decl.Abi_Mix8, &s)
	return
}

Abi_Sum :: proc(xs: []i64) -> (s: i64) {
	w := begin(); arg(&w, xs)
	finish(OP_Abi_Sum, &w, api_decl.Abi_Sum, &s)
	return
}

Abi_Split :: proc(s: string) -> (parts: []string) {
	w := begin(); arg(&w, s)
	finish(OP_Abi_Split, &w, api_decl.Abi_Split, &parts)
	return
}

Abi_Opt :: proc(x: Maybe(i32)) -> (r: i32) {
	w := begin(); arg(&w, x)
	finish(OP_Abi_Opt, &w, api_decl.Abi_Opt, &r)
	return
}

Abi_Find :: proc(name: string) -> (r: Maybe(string)) {
	w := begin(); arg(&w, name)
	finish(OP_Abi_Find, &w, api_decl.Abi_Find, &r)
	return
}

Abi_Make :: proc(href: string) -> (u: abi.Owned(URL), err: abi.Api_Error) {
	w := begin(); arg(&w, href)
	err = finish(OP_Abi_Make, &w, api_decl.Abi_Make, &u)
	return
}

Abi_Echo :: proc(d: api_decl.Abi_Dict) -> (out: api_decl.Abi_Dict, err: abi.Api_Error) {
	w := begin(); arg(&w, d)
	err = finish(OP_Abi_Echo, &w, api_decl.Abi_Echo, &out)
	return
}

// Each stub's signature against its declaration, at compile time (a stub cannot name its own type in its body).
@(private)
stubs_match_abitest :: proc() {
	abi.must_match(api_decl.Abi_Mix8, type_of(Abi_Mix8))
	abi.must_match(api_decl.Abi_Sum, type_of(Abi_Sum))
	abi.must_match(api_decl.Abi_Split, type_of(Abi_Split))
	abi.must_match(api_decl.Abi_Opt, type_of(Abi_Opt))
	abi.must_match(api_decl.Abi_Find, type_of(Abi_Find))
	abi.must_match(api_decl.Abi_Make, type_of(Abi_Make))
	abi.must_match(api_decl.Abi_Echo, type_of(Abi_Echo))
}
