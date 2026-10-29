package jsrt

// The allocator of one front-end compile. Small blocks (up to RECYCLE_MAX_BYTES) come from a dynamic arena and
// go back to a free list by size (a multiple of 16) when they are freed or when a dynamic array outgrows them;
// the next allocation of that size takes them. Larger blocks come from the host heap, each one linked into a
// list so that a block nobody freed is returned when the compile ends (`compile_alloc_release`): a large table
// that dies in the middle of the compile (the per-function passes work on buffers as long as the function's
// bytecode) is given back at once and the heap reuses it for the next one, where an arena would keep every one of
// them until the end. Everything else is released with the arena.
//
// A block is told apart by the size the caller frees it with (Odin's `delete` passes the size it allocated), so
// that size must be the one asked for: over RECYCLE_MAX_BYTES it is a heap block, under it an arena block.

import "base:intrinsics"
import "base:runtime"
import "core:mem"

RECYCLE_MAX_BYTES :: 2048
RECYCLE_CLASSES :: RECYCLE_MAX_BYTES / 16 + 1
LARGE_HEADER :: 32

Recycled_Block :: struct {
	next: ^Recycled_Block,
}

// in front of the bytes of a large block (LARGE_HEADER bytes before the block)
Large_Block :: struct {
	next, prev: ^Large_Block,
	base:       rawptr, // what the host heap gave
}

Compile_Alloc :: struct {
	inner:      mem.Allocator, // the arena
	heap:       mem.Allocator, // for blocks over RECYCLE_MAX_BYTES; no procedure: they come from the arena
	large:      ^Large_Block,
	free:       [RECYCLE_CLASSES]^Recycled_Block,
	bytes:      int, // bytes taken from the arena (not counting the reuse of recycled blocks)
	recycled:   int, // bytes handed out again from the free lists
	large_live: int, // bytes of the large blocks in use now
	peak:       int, // the most `bytes + large_live` at any time: what the compile asked of the host
}

compile_alloc_init :: proc(c: ^Compile_Alloc, arena: ^mem.Dynamic_Arena, heap: mem.Allocator) {
	c.inner = mem.dynamic_arena_allocator(arena)
	c.heap = heap
}

compile_alloc :: proc(c: ^Compile_Alloc) -> mem.Allocator {
	return mem.Allocator{procedure = compile_alloc_proc, data = c}
}

// Gives back the large blocks still allocated (the arena is destroyed by its owner).
compile_alloc_release :: proc(c: ^Compile_Alloc) {
	for b := c.large; b != nil; {
		next := b.next
		c.heap.procedure(c.heap.data, .Free, 0, 0, b.base, 0, {})
		b = next
	}
	c.large = nil
	c.large_live = 0
}

@(private = "file")
note_peak :: #force_inline proc(c: ^Compile_Alloc) {
	if c.bytes + c.large_live > c.peak {c.peak = c.bytes + c.large_live}
}

@(private = "file")
small_alloc :: proc(c: ^Compile_Alloc, size, alignment: int, zero: bool, loc: runtime.Source_Code_Location) -> (rawptr, mem.Allocator_Error) {
	n := (size + 15) &~ 15
	mode := zero ? mem.Allocator_Mode.Alloc : mem.Allocator_Mode.Alloc_Non_Zeroed
	if alignment <= 16 {
		cls := n >> 4
		if b := c.free[cls]; b != nil {
			c.free[cls] = b.next
			c.recycled += n
			if zero {intrinsics.mem_zero(b, n)}
			return b, nil
		}
	}
	c.bytes += n
	note_peak(c)
	bs, err := c.inner.procedure(c.inner.data, mode, n, max(alignment, 16), nil, 0, loc)
	return raw_data(bs), err
}

@(private = "file")
large_alloc :: proc(c: ^Compile_Alloc, mode: mem.Allocator_Mode, size, alignment: int, loc: runtime.Source_Code_Location) -> ([]byte, mem.Allocator_Error) {
	al := max(alignment, 16)
	bs, err := c.heap.procedure(c.heap.data, mode, size + LARGE_HEADER + al, 16, nil, 0, loc)
	base := raw_data(bs)
	if base == nil {return nil, err}
	p := (uintptr(base) + LARGE_HEADER + uintptr(al) - 1) &~ (uintptr(al) - 1)
	b := cast(^Large_Block)(p - LARGE_HEADER)
	b.base = base
	b.prev = nil
	b.next = c.large
	if c.large != nil {c.large.prev = b}
	c.large = b
	c.large_live += size
	note_peak(c)
	return ([^]byte)(p)[:size], nil
}

@(private = "file")
large_free :: proc(c: ^Compile_Alloc, p: rawptr, size: int) {
	b := cast(^Large_Block)(uintptr(p) - LARGE_HEADER)
	if b.prev != nil {b.prev.next = b.next} else {c.large = b.next}
	if b.next != nil {b.next.prev = b.prev}
	c.large_live -= size
	c.heap.procedure(c.heap.data, .Free, 0, 0, b.base, 0, {})
}

compile_alloc_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	c := cast(^Compile_Alloc)allocator_data
	has_heap := c.heap.procedure != nil
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size <= 0 {return nil, nil}
		if size > RECYCLE_MAX_BYTES {
			if has_heap {return large_alloc(c, mode, size, alignment, loc)}
			c.bytes += size
			note_peak(c)
			return c.inner.procedure(c.inner.data, mode, size, alignment, nil, 0, loc)
		}
		p, err := small_alloc(c, size, alignment, mode == .Alloc, loc)
		if p == nil {return nil, err}
		return ([^]byte)(p)[:size], nil
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return compile_alloc_proc(allocator_data, mode == .Resize ? .Alloc : .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		}
		if size == 0 {
			compile_alloc_proc(allocator_data, .Free, 0, 0, old_memory, old_size, loc)
			return nil, nil
		}
		if old_size > RECYCLE_MAX_BYTES && !has_heap {
			// (no heap: the arena resizes its own blocks)
			c.bytes += max(size - old_size, 0)
			note_peak(c)
			return c.inner.procedure(c.inner.data, mode, size, alignment, old_memory, old_size, loc)
		}
		if old_size > RECYCLE_MAX_BYTES && size > RECYCLE_MAX_BYTES && alignment <= 16 {
			// a large block stays large: the host heap resizes it, in place when it can
			ob := cast(^Large_Block)(uintptr(old_memory) - LARGE_HEADER)
			if uintptr(ob.base) + LARGE_HEADER == uintptr(old_memory) {
				if ob.prev != nil {ob.prev.next = ob.next} else {c.large = ob.next}
				if ob.next != nil {ob.next.prev = ob.prev}
				bs, err := c.heap.procedure(c.heap.data, .Resize_Non_Zeroed, size + LARGE_HEADER + 16, 16, ob.base, old_size + LARGE_HEADER + 16, loc)
				base := raw_data(bs)
				if base == nil {
					// (the old block is still ours)
					ob.prev = nil
					ob.next = c.large
					if c.large != nil {c.large.prev = ob}
					c.large = ob
					return nil, err
				}
				p := (uintptr(base) + LARGE_HEADER + 15) &~ 15
				if p != uintptr(base) + LARGE_HEADER {
					intrinsics.mem_copy(rawptr(p), rawptr(uintptr(base) + LARGE_HEADER), min(old_size, size))
				}
				b := cast(^Large_Block)(p - LARGE_HEADER)
				b.base = base
				b.prev = nil
				b.next = c.large
				if c.large != nil {c.large.prev = b}
				c.large = b
				if mode == .Resize && size > old_size {intrinsics.mem_zero(rawptr(p + uintptr(old_size)), size - old_size)}
				c.large_live += size - old_size
				note_peak(c)
				return ([^]byte)(p)[:size], nil
			}
		}
		if old_size <= RECYCLE_MAX_BYTES && alignment <= 16 && size <= ((old_size + 15) &~ 15) {
			// the block has the room (a shrink keeps its class: it is not given back)
			if mode == .Resize && size > old_size {intrinsics.mem_zero(rawptr(uintptr(old_memory) + uintptr(old_size)), size - old_size)}
			return ([^]byte)(old_memory)[:size], nil
		}
		p, err := compile_alloc_proc(allocator_data, mode == .Resize ? .Alloc : .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if p == nil {return nil, err}
		intrinsics.mem_copy_non_overlapping(raw_data(p), old_memory, min(old_size, size))
		compile_alloc_proc(allocator_data, .Free, 0, 0, old_memory, old_size, loc)
		return p, nil
	case .Free:
		if old_memory == nil || old_size <= 0 {return nil, nil}
		if old_size > RECYCLE_MAX_BYTES {
			if has_heap {large_free(c, old_memory, old_size)}
			return nil, nil
		}
		old_n := (old_size + 15) &~ 15
		b := cast(^Recycled_Block)old_memory
		b.next = c.free[old_n >> 4]
		c.free[old_n >> 4] = b
		return nil, nil
	case .Free_All:
		return nil, nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}}
		return nil, nil
	}
	return c.inner.procedure(c.inner.data, mode, size, alignment, old_memory, old_size, loc)
}
