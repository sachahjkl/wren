// The host implementations of api_decl/abitest.odin (the boundary's own conformance functions). Each computes
// something from every argument, so a mis-decoded argument changes the answer the checks compare.
package abi_url

import "core:strings"
import "../abi"
import "../api_decl"
import "wb:base"
import "wb:url"

Abi_Mix8 :: proc(ctx: ^Host, a: i32, b: i64, c: f64, d: bool, e: api_decl.URLComponent, f: string, g: Maybe(string), h: api_decl.URL) -> i64 {
	return abi_mix8_expected(a, b, c, d, e, f, g, h)
}

// The checksum Abi_Mix8 returns, shared with the callers that verify it.
abi_mix8_expected :: proc "contextless" (a: i32, b: i64, c: f64, d: bool, e: api_decl.URLComponent, f: string, g: Maybe(string), h: api_decl.URL) -> i64 {
	s := i64(a) * 3 + b * 5 + i64(c * 1000) + (d ? 7 : 11) + i64(e) * 13
	for ch in transmute([]u8)f { s = s * 31 + i64(ch) }
	if gv, ok := g.?; ok { s += 17 * i64(len(gv)) + 1 } else { s -= 19 }
	return s ~ i64(h)
}

Abi_Sum :: proc(ctx: ^Host, xs: []i64) -> i64 {
	s: i64
	for x in xs { s += x }
	return s
}

Abi_Split :: proc(ctx: ^Host, s: string) -> []string {
	return strings.split(s, ",", context.temp_allocator)
}

Abi_Opt :: proc(ctx: ^Host, x: Maybe(i32)) -> i32 {
	v, ok := x.?
	return ok ? v * 2 : -1
}

Abi_Find :: proc(ctx: ^Host, name: string) -> Maybe(string) {
	if name == "present" { return "found it" }
	return nil
}

Abi_Make :: proc(ctx: ^Host, href: string) -> (abi.Owned(api_decl.URL), abi.Api_Error) {
	u, ok := url.parse(href)
	if !ok { return {}, .Type }
	h, _ := base.pool_insert(&host.urls, Url_Object{u = u})
	return {handle = api_decl.URL(h)}, .None
}

Abi_Echo :: proc(ctx: ^Host, d: api_decl.Abi_Dict) -> (api_decl.Abi_Dict, abi.Api_Error) {
	if d.count < 0 { return {}, .Range }
	out := d
	out.name = strings.concatenate({d.name, "!"}, context.temp_allocator)
	out.count = d.count + 1
	out.ratio = d.ratio * 2
	out.flag = !d.flag
	ids := make([]i32, len(d.ids) + 1, context.temp_allocator)
	copy(ids, d.ids)
	ids[len(d.ids)] = i32(len(d.ids))
	out.ids = ids
	return out, .None
}
