// m4_alloc.odin: an Odin allocator over the C library's heap (wasi-libc malloc / free, the heap the C glue used), so a
// domain written in Odin can use dynamic arrays, maps and string builders (the glue is built with
// -default-to-nil-allocator: the default context allocates nothing). Every block it returns is a plain libc block:
// memory built with it (a serialised message, a JSON text) can be handed to C code that frees it with free(), and
// memory the C allocated with malloc can be released through it. Larger alignments (Odin's maps ask for a cache line)
// go through aligned_alloc, whose blocks free() releases too.
package wj

import "base:runtime"

// malloc's own alignment on wasm32 (two words)
@(private = "file") MALLOC_ALIGN :: 8

libc_allocator :: #force_inline proc "contextless" () -> runtime.Allocator {
	return runtime.Allocator{procedure = libc_allocator_proc, data = nil}
}

@(private = "file")
raw_alloc :: proc "contextless" (size, alignment: int, zero: bool) -> rawptr {
	n := uint(max(size, 1))
	if alignment <= MALLOC_ALIGN { return zero ? libc_calloc(1, n) : libc_malloc(n) }
	a := uint(alignment)
	p := libc_aligned_alloc(a, (n + a - 1) / a * a)   // C11: the size is a multiple of the alignment
	if p != nil && zero { memset(p, 0, n) }
	return p
}

libc_allocator_proc :: proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr,
	old_size: int, location := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		p := raw_alloc(size, alignment, mode == .Alloc)
		if p == nil { return nil, .Out_Of_Memory }
		return ([^]byte)(p)[:size], nil
	case .Free:
		libc_free(old_memory)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			p := raw_alloc(size, alignment, mode == .Resize)
			if p == nil { return nil, .Out_Of_Memory }
			return ([^]byte)(p)[:size], nil
		}
		if size == 0 { libc_free(old_memory); return nil, nil }
		p: rawptr
		if alignment <= MALLOC_ALIGN {
			p = libc_realloc(old_memory, uint(size))
			if p == nil { return nil, .Out_Of_Memory }
		} else {
			// realloc keeps malloc's alignment only: a new aligned block and a copy
			p = raw_alloc(size, alignment, false)
			if p == nil { return nil, .Out_Of_Memory }
			memcpy(p, old_memory, uint(min(old_size, size)))
			libc_free(old_memory)
		}
		if mode == .Resize && size > old_size { memset(rawptr(uintptr(p) + uintptr(old_size)), 0, uint(size - old_size)) }
		return ([^]byte)(p)[:size], nil
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil { set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features} }
		return nil, nil
	}
	return nil, nil
}

// The context an Odin-convention domain procedure runs in: the freestanding default with the libc heap as allocator
// (the temporary allocator is not used by the glue).
heap_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = libc_allocator()
	return c
}
