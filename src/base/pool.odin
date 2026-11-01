package base

// Generational handles now live in the toolkit's `arena` package (toolkit:arena); base keeps the historic names as
// aliases so callers do not change. See toolkit:arena for the whole picture (a Handle can never dangle: removing an
// object bumps the slot's generation, so an old copy fails to resolve instead of reaching whatever reused the slot).

import "base:intrinsics"
import "../../ext/gui_toolkit/arena"

Handle :: arena.Handle
NIL_HANDLE :: arena.NIL_HANDLE

handle_index :: arena.handle_index
handle_gen :: arena.handle_gen
handle_make :: arena.handle_make

POOL_CHUNK_SHIFT :: arena.POOL_CHUNK_SHIFT
POOL_CHUNK_SIZE :: arena.POOL_CHUNK_SIZE
POOL_CHUNK_MASK :: arena.POOL_CHUNK_MASK

Slot :: arena.Slot
Pool :: arena.Pool

pool_insert :: arena.pool_insert
pool_get :: arena.pool_get
pool_valid :: arena.pool_valid
pool_remove :: arena.pool_remove
pool_handle_at :: arena.pool_handle_at
pool_next :: arena.pool_next
pool_destroy :: arena.pool_destroy

////////////////////////////////
// Tagged pools: handles that say which document they belong to
//
// A DOM node and a page's host object are handed to scripts of other same-origin documents (src/page/frames_access.odin),
// so a handle has to name its document. The generation word is split:
//
//     bit  63      OBJECT_TAG of the page's host objects (never part of a pool's generation)
//     bits 62..48  tag: unique per document (HANDLE_TAG_BITS)
//     bits 47..32  generation of the slot (HANDLE_GEN_BITS)
//     bits 31..0   slot index
//
// The tag sits in the slot's generation, so `pool_get` compares it with no extra work: a handle of another document
// fails to resolve instead of reaching the node that happens to be at its index. A generation of 16 bits would wrap on
// a slot reused 65536 times, and an old handle would then resolve: such a slot is retired instead of reused.

HANDLE_TAG_BITS :: 15
HANDLE_GEN_BITS :: 16
HANDLE_TAG_MASK :: u32(1 << HANDLE_TAG_BITS - 1)
HANDLE_GEN_MASK :: u32(1 << HANDLE_GEN_BITS - 1)
HANDLE_TAG_SHIFT :: 32 + HANDLE_GEN_BITS

// The tag of a handle (0: an untagged one, or not a handle at all).
handle_tag :: #force_inline proc "contextless" (h: u64) -> u32 { return u32(h >> HANDLE_TAG_SHIFT) & HANDLE_TAG_MASK }

@(private = "file")
next_tag: u32

// A tag for a new document (any thread: documents are parsed off the interface thread). It comes round after 32767
// documents: a handle kept that long could only name a live document of the same tree, same origin, same slot and same
// generation (the checks of frames_access.odin still apply).
tag_new :: proc "contextless" () -> u32 {
	for {
		t := intrinsics.atomic_add(&next_tag, 1) & HANDLE_TAG_MASK
		if t != 0 { return t }
	}
}

pool_insert_tagged :: proc(p: ^Pool($T), tag: u32, value: T) -> (h: Handle, ptr: ^T) {
	h, ptr = arena.pool_insert(p, value)
	index := handle_index(h)
	slot := &p.chunks[index >> POOL_CHUNK_SHIFT][index & POOL_CHUNK_MASK]
	if slot.gen >> HANDLE_GEN_BITS != tag {   // a fresh slot; a reused one keeps the tag of its pool
		slot.gen = tag << HANDLE_GEN_BITS | (slot.gen & HANDLE_GEN_MASK)
		h = handle_make(index, slot.gen)
	}
	return h, ptr
}

pool_remove_tagged :: proc(p: ^Pool($T), h: Handle) -> (value: T, ok: bool) {
	value, ok = arena.pool_remove(p, h)
	if ok && handle_gen(h) & HANDLE_GEN_MASK == HANDLE_GEN_MASK {
		// its last generation: taken back out of the free list (never reused: pool_insert would carry into the tag)
		index := handle_index(h)
		p.free_head = p.chunks[index >> POOL_CHUNK_SHIFT][index & POOL_CHUNK_MASK].next_free
	}
	return
}
