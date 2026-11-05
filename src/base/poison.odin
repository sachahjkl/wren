package base

// Freed memory made loud: -define:WREN_POISON_MEMORY=true (`build.bat check`, the end-to-end tools). Off, nothing of this
// is compiled.
//
// The C heap's free and realloc are taken over for the whole program: on Windows in the executable's import table
// (poison_windows.odin: every HeapFree and HeapReAlloc of the Odin runtime, of the Rust library and of the C libraries
// linked in; the system's DLLs keep their own), on Linux by the symbols themselves (poison_linux.odin). So:
//   - a freed block is filled with POISON_BYTE and stays out of the heap for a while (the quarantine): what still reads it
//     finds the pattern, not the next owner's data. A pointer read from it is not canonical: the read through it faults
//     at once. (Windows reports such a fault as "reading 0xFFFFFFFFFFFFFFFF": any non-canonical address does.)
//   - a block that grows always moves, so a pointer into a dynamic array kept across an append sees poison;
//   - a second free of a block in quarantine, a free of what the heap does not know, a write to a block in quarantine (seen
//     when it leaves) end the process with a crash report: its stack is the free's.
// WREN_POISON_PAGES=1 (poison_windows.odin): every block on pages of its own, gone when it is freed.
// The arenas ride on it: Poison_Arena takes its chunks from the heap, so emptying or closing one (a reset, a scope closed,
// free_all of a temporary allocator) sends its memory through the quarantine, instead of handing the same addresses out
// again. base.Scope (scope.odin), process_context's temporary allocator and base.Pool's slots go the same way.
//
// What it does not see: the system's DLLs, Lexbor's own pools (lexbor_mraw), the toolkit's arenas (ext\gui_toolkit: ui,
// font, dbus use core:mem/virtual directly), a context not made by process_context, Wasm linear memories.

@(require) import "base:intrinsics"
@(require) import "base:runtime"
@(require) import "core:fmt"
@(require) import "core:debug/trace"
@(require) import "core:mem"
@(require) import "core:strings"
@(require) import "core:sync"

POISON_MEMORY :: #config(WREN_POISON_MEMORY, false)

POISON_BYTE :: u8(0xDD)
@(private) POISON_WORD :: u64(0xDDDD_DDDD_DDDD_DDDD)
@(private) POISON_LOW_BITS :: 32
// How much freed memory waits, in bytes and in blocks (FIFO). The blocks are a power of two, the table of addresses twice that.
@(private) QUARANTINE_BYTES :: 1 << 30
@(private) QUARANTINE_BLOCKS :: 1 << 20
@(private) QUARANTINE_TABLE :: 2 * QUARANTINE_BLOCKS
// How many blocks one free may release when it pushes others out.
@(private) QUARANTINE_EVICT_MAX :: 64
// What a failure shows of what was written to a freed block.
@(private) POISON_SHOWN_BYTES :: 32
// Fibonacci hashing of an address, its low bits (alignment) dropped.
@(private) TABLE_HASH :: u64(0x9E37_79B9_7F4A_7C15)
@(private) TABLE_ALIGN_BITS :: 4
@(private) TABLE_HASH_BITS :: 40
// A chunk of a Poison_Arena: small, so that what an arena held goes as soon as it is emptied.
@(private) ARENA_CHUNK_BYTES :: 64 * mem.Kilobyte
@(private) ARENA_ALIGN_MIN :: 16

when POISON_MEMORY {

@(private) Quarantined :: struct { heap, ptr: rawptr, size: int, freed_by: Stack }

@(private) Quarantine :: struct {
	lock:         sync.Mutex,
	ring:         [QUARANTINE_BLOCKS]Quarantined,   // (the stack of each free: WREN_MEMTRACK_STACK=1)
	head, count:  int,
	bytes:        int,
	table:        [QUARANTINE_TABLE]rawptr,   // the addresses in the ring: open addressing, deletion by backward shift
}

@(private) quarantine: Quarantine

@(private)
table_slot :: #force_inline proc "contextless" (p: rawptr) -> int {
	return int((u64(uintptr(p)) >> TABLE_ALIGN_BITS) * TABLE_HASH >> TABLE_HASH_BITS) & (QUARANTINE_TABLE - 1)
}

// False when `p` is there already.
@(private)
table_add :: proc "contextless" (q: ^Quarantine, p: rawptr) -> bool {
	i := table_slot(p)
	for q.table[i] != nil {
		if q.table[i] == p { return false }
		i = (i + 1) & (QUARANTINE_TABLE - 1)
	}
	q.table[i] = p
	return true
}

@(private)
table_remove :: proc "contextless" (q: ^Quarantine, p: rawptr) {
	i := table_slot(p)
	for q.table[i] != p {
		if q.table[i] == nil { return }
		i = (i + 1) & (QUARANTINE_TABLE - 1)
	}
	j := i
	for {
		j = (j + 1) & (QUARANTINE_TABLE - 1)
		if q.table[j] == nil { break }
		k := table_slot(q.table[j])
		if (j - k) & (QUARANTINE_TABLE - 1) >= (j - i) & (QUARANTINE_TABLE - 1) {
			q.table[i] = q.table[j]
			i = j
		}
	}
	q.table[i] = nil
}

// Whether `p` waits in quarantine.
poison_in_quarantine :: proc "contextless" (p: rawptr) -> bool {
	q := &quarantine
	sync.mutex_lock(&q.lock)
	defer sync.mutex_unlock(&q.lock)
	i := table_slot(p)
	for q.table[i] != nil {
		if q.table[i] == p { return true }
		i = (i + 1) & (QUARANTINE_TABLE - 1)
	}
	return false
}

// A block of `size` bytes at `ptr` is freed: filled, kept, and what has waited longest goes back to the heap.
@(private)
quarantine_put :: proc "contextless" (heap, ptr: rawptr, size: int) {
	poison_fill(ptr, size)
	stack: Stack = ---
	stacks := want_stacks()
	if stacks {
		context = runtime.default_context()   // memcheck: inside the free of any thread, the tracker's own
		stack = {}
		_ = trace.capture_fill(stack[:], 1)
	}
	out: [QUARANTINE_EVICT_MAX]Quarantined = ---
	n := 0
	q := &quarantine
	sync.mutex_lock(&q.lock)
	if !table_add(q, ptr) {
		sync.mutex_unlock(&q.lock)
		poison_fail("double free", ptr, size)
	}
	if q.count == QUARANTINE_BLOCKS { quarantine_pop(q, &out[n]); n += 1 }
	e := &q.ring[(q.head + q.count) & (QUARANTINE_BLOCKS - 1)]
	e.heap, e.ptr, e.size = heap, ptr, size
	if stacks { e.freed_by = stack }
	q.count += 1
	q.bytes += size
	for q.bytes > QUARANTINE_BYTES && n < QUARANTINE_EVICT_MAX { quarantine_pop(q, &out[n]); n += 1 }
	sync.mutex_unlock(&q.lock)
	for &b in out[:n] {
		quarantined_check(&b)
		heap_release(b.heap, b.ptr)
	}
}

// What waits in quarantine has not been written to (a block is otherwise looked at when it leaves): the end of a run.
poison_check :: proc "contextless" () {
	q := &quarantine
	sync.mutex_lock(&q.lock)
	n := q.count
	head := q.head
	sync.mutex_unlock(&q.lock)
	for i in 0 ..< n { quarantined_check(&q.ring[(head + i) & (QUARANTINE_BLOCKS - 1)]) }
}

// The block is still the pattern; else the process ends, saying what is in it and who freed it.
@(private)
quarantined_check :: proc "contextless" (b: ^Quarantined) {
	at := poison_written(b.ptr, b.size)
	if at < 0 { return }
	context = runtime.default_context()   // memcheck: inside the free of any thread, the tracker's own
	fmt.eprintfln("memory: at offset %d of a freed block: %2x", at, ([^]u8)(b.ptr)[at:min(at + POISON_SHOWN_BYTES, b.size)])
	if want_stacks() {
		text := strings.builder_make(HEAP)
		write_stack(&text, b.freed_by)
		fmt.eprintfln("memory: freed by:\n%s", strings.to_string(text))
	}
	poison_fail("a write to freed memory", rawptr(uintptr(b.ptr) + uintptr(at)), b.size)
}

@(private)
quarantine_pop :: proc "contextless" (q: ^Quarantine, out: ^Quarantined) {
	out^ = q.ring[q.head]
	q.head = (q.head + 1) & (QUARANTINE_BLOCKS - 1)
	q.count -= 1
	q.bytes -= out.size
	table_remove(q, out.ptr)
}

@(private)
poison_fill :: #force_inline proc "contextless" (p: rawptr, size: int) {
	mem.set(p, POISON_BYTE, size)
}

@(private)
poison_pointer :: #force_inline proc "contextless" (p: rawptr) -> bool { return u64(uintptr(p)) >> POISON_LOW_BITS == POISON_WORD >> POISON_LOW_BITS }

// The offset of the first byte of the block that is not the pattern, or -1.
@(private)
poison_written :: proc "contextless" (p: rawptr, size: int) -> int {
	words := ([^]u64)(p)   // (the heap's blocks are aligned)
	n := size / size_of(u64)
	for i in 0 ..< n {
		if words[i] != POISON_WORD { return i * size_of(u64) }
	}
	bytes := ([^]u8)(p)
	for i in n * size_of(u64) ..< size {
		if bytes[i] != POISON_BYTE { return i }
	}
	return -1
}

// The end of the process: one line on the standard error (test_all and wrentool sweep read it), the crash report's stack.
@(private)
poison_fail :: proc "contextless" (what: string, ptr: rawptr, size: int) -> ! {
	context = runtime.default_context()   // memcheck: inside the free of any thread, the tracker's own
	fmt.eprintfln("memory: fatal: %s: %p (block of %d bytes)", what, ptr, size)
	intrinsics.trap()
}

////////////////////////////////
// The arena

@(private) Poison_Chunk :: struct { data: []byte, used: int }

// An arena of heap chunks. Emptied, they go through the quarantine; the next allocation has another address.
Poison_Arena :: struct {
	lock:       sync.Mutex,
	chunks:     [dynamic]Poison_Chunk,   // on the heap directly, as a virtual arena's blocks: no tracker sees them
	total_used: uint,
}

Poison_Arena_Temp :: struct { arena: ^Poison_Arena, chunk, used: int, total: uint }

poison_arena_init :: proc(a: ^Poison_Arena, reserved: uint = 0, loc := #caller_location) -> runtime.Allocator_Error {
	a^ = {}
	return nil
}

poison_arena_allocator :: proc(a: ^Poison_Arena) -> runtime.Allocator { return {poison_arena_proc, a} }

poison_arena_free_all :: proc(a: ^Poison_Arena, loc := #caller_location) {
	sync.guard(&a.lock)
	arena_release_from(a, 0)
	a.total_used = 0
}

poison_arena_destroy :: proc(a: ^Poison_Arena, loc := #caller_location) {
	poison_arena_free_all(a, loc)
	delete(a.chunks)
	a.chunks = nil
}

poison_arena_temp_begin :: proc(a: ^Poison_Arena, loc := #caller_location) -> Poison_Arena_Temp {
	sync.guard(&a.lock)
	n := len(a.chunks)
	return {a, n - 1, n > 0 ? a.chunks[n - 1].used : 0, a.total_used}
}

poison_arena_temp_end :: proc(t: Poison_Arena_Temp, loc := #caller_location) {
	a := t.arena
	sync.guard(&a.lock)
	arena_release_from(a, t.chunk + 1)
	if t.chunk >= 0 {
		c := &a.chunks[t.chunk]
		poison_fill(raw_data(c.data[t.used:]), c.used - t.used)
		c.used = t.used
	}
	a.total_used = t.total
}

poison_arena_temp_ignore :: proc(t: Poison_Arena_Temp, loc := #caller_location) {}

@(private)
arena_release_from :: proc(a: ^Poison_Arena, first: int) {
	if first >= len(a.chunks) { return }
	for c in a.chunks[first:] { _, _ = HEAP.procedure(nil, .Free, 0, 0, raw_data(c.data), len(c.data)) }
	resize(&a.chunks, first)
}

@(private)
arena_take :: proc(a: ^Poison_Arena, size, alignment: int, zero: bool) -> ([]byte, runtime.Allocator_Error) {
	align := max(alignment, ARENA_ALIGN_MIN)
	if n := len(a.chunks); n > 0 {
		c := &a.chunks[n - 1]
		start := int(uintptr(raw_data(c.data)))
		at := mem.align_forward_int(start + c.used, align) - start
		if at + size <= len(c.data) {
			c.used = at + size
			a.total_used += uint(size)
			b := c.data[at:][:size]
			if zero { mem.zero_slice(b) }
			return b, nil
		}
	}
	a.chunks.allocator = HEAP
	data, err := HEAP.procedure(nil, .Alloc_Non_Zeroed, max(ARENA_CHUNK_BYTES, size + align), align, nil, 0)
	if err != nil { return nil, err }
	append(&a.chunks, Poison_Chunk{data = data})
	return arena_take(a, size, alignment, zero)
}

poison_arena_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	a := (^Poison_Arena)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		sync.guard(&a.lock)
		return arena_take(a, size, alignment, mode == .Alloc)
	case .Free:
		return nil, nil
	case .Free_All:
		poison_arena_free_all(a, loc)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		if old_memory != nil && size <= old_size {
			poison_fill(rawptr(uintptr(old_memory) + uintptr(size)), old_size - size)
			return ([^]byte)(old_memory)[:size], nil
		}
		sync.guard(&a.lock)
		b, err := arena_take(a, size, alignment, mode == .Resize)
		if err == nil && old_memory != nil {
			mem.copy_non_overlapping(raw_data(b), old_memory, old_size)
			poison_fill(old_memory, old_size)   // it moved: whoever kept the old address is told
		}
		return b, err
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil { set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features} }
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

// The temporary allocator of a thread: what process_context hands out.
@(private, thread_local) temp_arena: Poison_Arena

@(private)
poison_temp_allocator :: #force_inline proc "contextless" () -> runtime.Allocator { return {poison_arena_proc, &temp_arena} }

@(private, init)
poison_temp_cleaner :: proc "contextless" () {
	runtime.add_thread_local_cleaner(proc() { poison_arena_destroy(&temp_arena) })
}

} // when POISON_MEMORY
