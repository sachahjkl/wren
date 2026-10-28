package jsrt

// The allocator of one front-end compile: a dynamic arena that gives a block back to its size class when a
// dynamic array outgrows it. The compiler never frees (it ports QuickJS's one-pass compiler, where the
// per-function tables are growable arrays); on an arena every doubling of an array leaves the old block behind
// for the whole compile, which for a large script was a third of the arena. Blocks up to RECYCLE_MAX_BYTES go
// back to a free list by size (a multiple of 16) and the next allocation of that size takes them. Everything
// is released at once with the arena.

import "base:intrinsics"
import "base:runtime"
import "core:mem"

RECYCLE_MAX_BYTES :: 2048
RECYCLE_CLASSES :: RECYCLE_MAX_BYTES / 16 + 1

Recycled_Block :: struct {
	next: ^Recycled_Block,
}

Compile_Alloc :: struct {
	inner:    mem.Allocator, // the arena
	free:     [RECYCLE_CLASSES]^Recycled_Block,
	bytes:    int, // bytes taken from the arena (not counting the reuse of recycled blocks)
	recycled: int, // bytes handed out again from the free lists
}

compile_alloc_init :: proc(c: ^Compile_Alloc, arena: ^mem.Dynamic_Arena) {
	c.inner = mem.dynamic_arena_allocator(arena)
}

compile_alloc :: proc(c: ^Compile_Alloc) -> mem.Allocator {
	return mem.Allocator{procedure = compile_alloc_proc, data = c}
}

@(private = "file")
fresh :: proc(c: ^Compile_Alloc, n: int, zero: bool, loc: runtime.Source_Code_Location) -> (rawptr, mem.Allocator_Error) {
	cls := n >> 4
	if cls < RECYCLE_CLASSES {
		if b := c.free[cls]; b != nil {
			c.free[cls] = b.next
			c.recycled += n
			if zero {intrinsics.mem_zero(b, n)}
			return b, nil
		}
	}
	c.bytes += n
	mode := zero ? mem.Allocator_Mode.Alloc : mem.Allocator_Mode.Alloc_Non_Zeroed
	bs, err := c.inner.procedure(c.inner.data, mode, n, 16, nil, 0, loc)
	return raw_data(bs), err
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
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size <= 0 {return nil, nil}
		if size > RECYCLE_MAX_BYTES || alignment > 16 {
			c.bytes += size
			return c.inner.procedure(c.inner.data, mode, size, alignment, nil, 0, loc)
		}
		n := (size + 15) &~ 15
		p, err := fresh(c, n, mode == .Alloc, loc)
		if p == nil {return nil, err}
		return ([^]byte)(p)[:size], nil
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return compile_alloc_proc(allocator_data, mode == .Resize ? .Alloc : .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		}
		if size == 0 {return nil, nil}
		if old_size > RECYCLE_MAX_BYTES || alignment > 16 {
			// not one of ours to recycle: a new block, the old one stays in the arena
			if size <= RECYCLE_MAX_BYTES && alignment <= 16 {
				p, err := compile_alloc_proc(allocator_data, mode == .Resize ? .Alloc : .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
				if p == nil {return nil, err}
				intrinsics.mem_copy_non_overlapping(raw_data(p), old_memory, min(old_size, size))
				return p, nil
			}
			c.bytes += max(size - old_size, 0)
			return c.inner.procedure(c.inner.data, mode, size, alignment, old_memory, old_size, loc)
		}
		old_n := (old_size + 15) &~ 15
		if size <= old_n {
			// the block has the room (a shrink keeps its class: it is not given back)
			if mode == .Resize && size > old_size {intrinsics.mem_zero(rawptr(uintptr(old_memory) + uintptr(old_size)), size - old_size)}
			return ([^]byte)(old_memory)[:size], nil
		}
		p, err := compile_alloc_proc(allocator_data, mode == .Resize ? .Alloc : .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if p == nil {return nil, err}
		intrinsics.mem_copy_non_overlapping(raw_data(p), old_memory, old_size)
		if old_n > 0 {
			b := cast(^Recycled_Block)old_memory
			b.next = c.free[old_n >> 4]
			c.free[old_n >> 4] = b
		}
		return p, nil
	case .Free, .Free_All:
		return nil, nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}}
		return nil, nil
	}
	return c.inner.procedure(c.inner.data, mode, size, alignment, old_memory, old_size, loc)
}
