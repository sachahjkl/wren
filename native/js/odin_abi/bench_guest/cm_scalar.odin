// The guest side of the comptime-scalar bridge (module "url_cm"): the same wire shape as the hand-written scalar
// baseline, timed to show the compiler-built trampoline matches the generated/hand-written one.
package bench_guest

import "../abi_guest"

foreign import _cm "url_cm"

@(default_calling_convention = "contextless")
foreign _cm {
	@(link_name = "size") _cm_size :: proc(params: abi_guest.URLSearchParams) -> i32 ---
	@(link_name = "get")  _cm_get :: proc(u: abi_guest.URL, component: abi_guest.URLComponent, buf: [^]u8, cap: u32) -> i32 ---
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
