package base

// Generational handles. A Handle is what crosses the host/guest boundary (the DOM, requests, timers...): it can
// never dangle. Removing an object bumps the slot's generation, so any copy of the old handle fails to resolve
// instead of silently reaching whatever reused the slot.
//
//     bits 63..32  generation (never 0)
//     bits 31..0   slot index
//
// Handle 0 is always invalid, which makes a zeroed struct field or an uninitialized wasm global safe.
Handle :: distinct u64

NIL_HANDLE :: Handle(0)

handle_index :: #force_inline proc "contextless" (h: Handle) -> u32 { return u32(u64(h)) }
handle_gen   :: #force_inline proc "contextless" (h: Handle) -> u32 { return u32(u64(h) >> 32) }
handle_make  :: #force_inline proc "contextless" (index, gen: u32) -> Handle { return Handle(u64(gen) << 32 | u64(index)) }

POOL_CHUNK_SHIFT :: 10
POOL_CHUNK_SIZE  :: 1 << POOL_CHUNK_SHIFT
POOL_CHUNK_MASK  :: POOL_CHUNK_SIZE - 1

Slot :: struct($T: typeid) {
	value:     T,
	gen:       u32,    // 0 until first use; live slots have gen >= 1
	live:      bool,
	next_free: u32,    // index + 1 of the next free slot, 0 = end of list (only meaningful when not live)
}

// Objects live in fixed-size chunks that never move: a `^T` returned by `pool_get` stays valid until that object
// is removed, however much the pool grows. Insert and remove are O(1); there is no per-object allocation.
Pool :: struct($T: typeid) {
	chunks:    [dynamic]^[POOL_CHUNK_SIZE]Slot(T),
	free_head: u32,    // index + 1
	used:      u32,    // slots ever handed out (high-water mark)
	count:     int,    // live objects
}

pool_insert :: proc(p: ^Pool($T), value: T) -> (h: Handle, ptr: ^T) {
	index: u32
	if p.free_head != 0 {
		index = p.free_head - 1
	} else {
		index = p.used
		if int(index >> POOL_CHUNK_SHIFT) == len(p.chunks) {
			append(&p.chunks, new([POOL_CHUNK_SIZE]Slot(T)))
		}
		p.used += 1
	}
	slot := &p.chunks[index >> POOL_CHUNK_SHIFT][index & POOL_CHUNK_MASK]
	if p.free_head != 0 { p.free_head = slot.next_free }
	slot.gen += 1
	if slot.gen == 0 { slot.gen = 1 }   // wrapped: 0 stays reserved
	slot.live = true
	slot.value = value
	slot.next_free = 0
	p.count += 1
	return handle_make(index, slot.gen), &slot.value
}

@(private)
pool_slot :: proc(p: ^Pool($T), h: Handle) -> ^Slot(T) {
	index := handle_index(h)
	if index >= p.used { return nil }
	slot := &p.chunks[index >> POOL_CHUNK_SHIFT][index & POOL_CHUNK_MASK]
	if !slot.live || slot.gen != handle_gen(h) { return nil }
	return slot
}

// nil when the handle is invalid, stale or was never issued.
pool_get :: proc(p: ^Pool($T), h: Handle) -> ^T {
	if slot := pool_slot(p, h); slot != nil { return &slot.value }
	return nil
}

pool_valid :: proc(p: ^Pool($T), h: Handle) -> bool { return pool_slot(p, h) != nil }

// Returns the removed value so the caller can release what it owns.
pool_remove :: proc(p: ^Pool($T), h: Handle) -> (value: T, ok: bool) {
	slot := pool_slot(p, h)
	if slot == nil { return {}, false }
	value = slot.value
	slot.value = {}
	slot.live = false
	slot.next_free = p.free_head
	p.free_head = handle_index(h) + 1
	p.count -= 1
	return value, true
}

// Handle of the live object at `index` (for iteration), or NIL_HANDLE.
pool_handle_at :: proc(p: ^Pool($T), index: u32) -> Handle {
	if index >= p.used { return NIL_HANDLE }
	slot := &p.chunks[index >> POOL_CHUNK_SHIFT][index & POOL_CHUNK_MASK]
	if !slot.live { return NIL_HANDLE }
	return handle_make(index, slot.gen)
}

// Iterates live objects: `it := 0; for h, v in pool_next(&p, &it) { ... }`. Removing the current object is allowed.
pool_next :: proc(p: ^Pool($T), it: ^u32) -> (h: Handle, value: ^T, ok: bool) {
	for it^ < p.used {
		index := it^
		it^ += 1
		slot := &p.chunks[index >> POOL_CHUNK_SHIFT][index & POOL_CHUNK_MASK]
		if slot.live { return handle_make(index, slot.gen), &slot.value, true }
	}
	return NIL_HANDLE, nil, false
}

pool_destroy :: proc(p: ^Pool($T)) {
	for c in p.chunks { free(c) }
	delete(p.chunks)
	p^ = {}
}
