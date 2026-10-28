// The guest side of the comptime-scalar bridge (module "url_cm"): the raw wr_*-style imports the host serves with
// abi_host.register_scalar, one per declaration. The same calls are made through the serialised stubs, and
// check_shapes compares the two answers for every shape (the serialised answers are themselves checked against the
// expected values in native/js/odin_abi/check).
package bench_guest

import "../abi"
import "../abi_guest"

foreign import _cm "url_cm"

@(default_calling_convention = "contextless")
foreign _cm {
	@(link_name = "size") _cm_size :: proc(params: abi_guest.URLSearchParams) -> i32 ---
	@(link_name = "get")  _cm_get :: proc(u: abi_guest.URL, component: abi_guest.URLComponent, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "has")  _cm_has :: proc(params: abi_guest.URLSearchParams, name: [^]u8, name_len: u32, value: [^]u8, value_len: u32) -> i32 ---
	@(link_name = "mix8") _cm_mix8 :: proc(a: i32, b: i64, c: f64, d: i32, e: i32, f: [^]u8, f_len: u32, g: [^]u8, g_len: u32, h: u64) -> i64 ---
	@(link_name = "sum")  _cm_sum :: proc(xs: [^]i64, count: u32) -> i64 ---
	@(link_name = "opt")  _cm_opt :: proc(present: i32, x: i32) -> i32 ---
	@(link_name = "find") _cm_find :: proc(name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "make") _cm_make :: proc(href: [^]u8, href_len: u32, ret: ^u64) -> i32 ---
}

@(export)
cm_calls_size :: proc "contextless" (n: i32) -> i32 {
	s: i32
	for _ in 0 ..< n { s += _cm_size(the_params) }
	return s
}

@(export)
cm_calls_get :: proc "contextless" (n: i32) -> i32 {
	s: i32
	for _ in 0 ..< n {
		nlen := _cm_get(the_url, .Pathname, raw_data(scalar_buf[:]), u32(len(scalar_buf)))
		s += nlen
	}
	return s
}

NAME : string : "b"
VALUE : string : "2"

@(export)
cm_calls_has :: proc "contextless" (n: i32) -> i32 {
	s: i32
	for _ in 0 ..< n { s += _cm_has(the_params, raw_data(NAME), u32(len(NAME)), raw_data(VALUE), u32(len(VALUE))) }
	return s
}

@(export)
calls_has :: proc "contextless" (n: i32) -> i32 {
	context = ctx
	s: i32
	for _ in 0 ..< n { s += abi_guest.URLSearchParams_has(the_params, NAME, VALUE) ? 1 : 0 }
	return s
}

MIX_F : string : "héllo"
MIX_G : string : "opt"

@(export)
cm_calls_mix8 :: proc "contextless" (n: i32) -> i32 {
	s: i64
	for _ in 0 ..< n { s ~= _cm_mix8(-7, 1 << 40, 2.5, 1, i32(abi_guest.URLComponent.Pathname), raw_data(MIX_F), u32(len(MIX_F)), raw_data(MIX_G), u32(len(MIX_G)), u64(the_url)) }
	return i32(s)
}

@(export)
calls_mix8 :: proc "contextless" (n: i32) -> i32 {
	context = ctx
	s: i64
	for _ in 0 ..< n { s ~= abi_guest.Abi_Mix8(-7, 1 << 40, 2.5, true, .Pathname, MIX_F, MIX_G, the_url) }
	return i32(s)
}

// Every shape through both paths: 0 when they agree, else a bit per disagreeing shape.
@(export)
check_shapes :: proc "contextless" () -> i32 {
	context = ctx
	bad: i32
	// eight arguments of every scalar and span shape, then with the optional absent and an empty string
	if _cm_mix8(-7, 1 << 40, 2.5, 1, i32(abi_guest.URLComponent.Pathname), raw_data(MIX_F), u32(len(MIX_F)), raw_data(MIX_G), u32(len(MIX_G)), u64(the_url)) !=
	   abi_guest.Abi_Mix8(-7, 1 << 40, 2.5, true, .Pathname, MIX_F, MIX_G, the_url) { bad |= 1 }
	if _cm_mix8(1, 2, 3, 0, 0, nil, 0, nil, abi.ABSENT, u64(the_url)) != abi_guest.Abi_Mix8(1, 2, 3, false, .Href, "", nil, the_url) { bad |= 2 }
	// a slice argument
	xs := [4]i64{1, 2, 3, 1 << 33}
	if _cm_sum(&xs[0], 4) != abi_guest.Abi_Sum(xs[:]) || _cm_sum(&xs[0], 4) != 6 + (1 << 33) { bad |= 4 }
	// an optional scalar, present and absent
	if _cm_opt(1, 21) != 42 || _cm_opt(0, 0) != -1 || abi_guest.Abi_Opt(21) != 42 { bad |= 8 }
	// an optional string result, present (the length) and absent (Not_Found)
	if _cm_find(raw_data(string("present")), 7, raw_data(scalar_buf[:]), u32(len(scalar_buf))) != 8 || string(scalar_buf[:8]) != "found it" { bad |= 16 }
	if _cm_find(raw_data(string("absent")), 6, raw_data(scalar_buf[:]), u32(len(scalar_buf))) != i32(abi.Api_Error.Not_Found) { bad |= 32 }
	// an owned handle through the result address, and the error of a (value, error) result
	h: u64
	if _cm_make(raw_data(string("https://owned.example/p")), 23, &h) != 0 || h == 0 { bad |= 64 }
	if _cm_make(raw_data(string("nope")), 4, &h) != i32(abi.Api_Error.Type) { bad |= 128 }
	// strings and an optional string argument
	if _cm_has(the_params, raw_data(NAME), 1, raw_data(VALUE), 1) != 1 || _cm_has(the_params, raw_data(NAME), 1, nil, abi.ABSENT) != 1 ||
	   _cm_has(the_params, raw_data(NAME), 1, raw_data(string("9")), 1) != 0 { bad |= 256 }
	return bad
}
