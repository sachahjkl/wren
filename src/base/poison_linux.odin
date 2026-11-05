package base

// The heap's free and realloc of the whole program (poison.odin): an executable's own symbols come before glibc's, for the
// Rust library, the C libraries and libc itself; glibc's are still there under __libc_*.

@(require) import "base:intrinsics"

when POISON_MEMORY {

foreign import libc "system:c"
@(private, default_calling_convention = "c")
foreign libc {
	__libc_free :: proc(p: rawptr) ---
	__libc_malloc :: proc(size: uint) -> rawptr ---
	malloc_usable_size :: proc(p: rawptr) -> uint ---
}

@(private)
heap_release :: proc "contextless" (heap, p: rawptr) { __libc_free(p) }

@(private, export, link_name = "free")
poison_free :: proc "c" (p: rawptr) {
	if p == nil { return }
	if poison_pointer(p) { poison_fail("double free", p, 0) }   // (the runtime read the block's start in the header of a freed block)
	quarantine_put(nil, p, int(malloc_usable_size(p)))
}

@(private, export, link_name = "realloc")
poison_realloc :: proc "c" (p: rawptr, size: uint) -> rawptr {
	if p == nil { return __libc_malloc(size) }
	if size == 0 { poison_free(p); return nil }
	if poison_in_quarantine(p) { poison_fail("a resize of a freed block", p, int(size)) }
	moved := __libc_malloc(size)
	if moved == nil { return nil }
	intrinsics.mem_copy_non_overlapping(moved, p, min(malloc_usable_size(p), size))
	poison_free(p)
	return moved
}

} // when POISON_MEMORY
