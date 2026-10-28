// A wasm32 guest for the generic-ABI benchmark: it calls the serialised boundary (abi_guest, the exact bindings that
// would ship) in tight loops, so the host runner (../bench) can time 1 M calls over a real Wasmtime instance and
// compare the cost against the current wr_* scalar ABI (the wasmbench numbers). Built with:
//   odin build native/js/odin_abi/bench_guest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator \
//     -collection:wb=src -out:build/abi_bench.wasm -o:size
package bench_guest

import "base:runtime"
import "../abi_guest"

// A small bump allocator over a static arena, so the guest's bindings (which grow a result buffer with the context
// allocator) have somewhere to allocate without a libc. Enough for the benchmark's steady state.
arena_buf: [1 << 20]u8
arena_off: int

bump :: proc(size, align: int) -> []u8 {
	off := (arena_off + align - 1) & ~(align - 1)
	if off + size > len(arena_buf) { off = 0 }   // the benchmark reuses results; wrap rather than fail
	arena_off = off + size
	return arena_buf[off:off + size]
}

bump_alloc :: proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return bump(size, alignment), nil
	case .Resize, .Resize_Non_Zeroed:
		b := bump(size, alignment)
		if old_memory != nil && old_size > 0 { runtime.mem_copy(raw_data(b), old_memory, min(size, old_size)) }
		return b, nil
	case .Free, .Free_All:
		return nil, nil
	case .Query_Features:
		return nil, nil
	}
	return nil, nil
}

set_context :: proc "contextless" () {
	context = runtime.default_context()
	context.allocator = runtime.Allocator{procedure = bump_alloc, data = nil}
	context.temp_allocator = context.allocator
	ctx = context
}

ctx: runtime.Context

@(export)
setup :: proc "contextless" () {
	set_context()
}

// A handle kept across calls so the loops are pure boundary cost, not construction.
the_url: abi_guest.URL
the_params: abi_guest.URLSearchParams

@(export)
prepare :: proc "contextless" () -> i32 {
	context = ctx
	u, err := abi_guest.URL_parse("https://example.com/the/path?a=1&b=2&c=3")
	if err != .None { return -1 }
	the_url = u
	the_params = abi_guest.URL_searchParams(u)
	return i32(the_params)
}

// 1 M calls of a scalar-result getter (handle -> i32): the cheapest serialised shape.
@(export)
calls_size :: proc "contextless" (n: i32) -> i32 {
	context = ctx
	s: i32
	for _ in 0 ..< n { s += abi_guest.URLSearchParams_size(the_params) }
	return s
}

// 1 M calls of a string-result getter (handle + enum -> string): a serialised call that returns bytes.
@(export)
calls_get :: proc "contextless" (n: i32) -> i32 {
	context = ctx
	s: i32
	for _ in 0 ..< n {
		str := abi_guest.URL_get(the_url, .Pathname)
		s += i32(len(str))
	}
	return s
}
