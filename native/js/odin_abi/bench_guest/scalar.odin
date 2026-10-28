// The guest side of the scalar baseline: the current wr_* ABI shape, one import per function with the arguments as
// separate Wasm scalars, a string result into a (ptr,cap) buffer. This is what sdk/odin/web generates today; it is
// written here by hand only to time it next to the serialised path on the same machine.
package bench_guest

import "../abi_guest"

foreign import _scalar "url_scalar"

@(default_calling_convention = "contextless")
foreign _scalar {
	@(link_name = "size") _scalar_size :: proc(params: abi_guest.URLSearchParams) -> i32 ---
	@(link_name = "get")  _scalar_get :: proc(u: abi_guest.URL, component: abi_guest.URLComponent, buf: [^]u8, cap: u32) -> i32 ---
}

scalar_buf: [256]u8

@(export)
scalar_calls_size :: proc "contextless" (n: i32) -> i32 {
	s: i32
	for _ in 0 ..< n { s += _scalar_size(the_params) }
	return s
}

@(export)
scalar_calls_get :: proc "contextless" (n: i32) -> i32 {
	s: i32
	for _ in 0 ..< n {
		nlen := _scalar_get(the_url, .Pathname, raw_data(scalar_buf[:]), u32(len(scalar_buf)))
		s += nlen
	}
	return s
}
