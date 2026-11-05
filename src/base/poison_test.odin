package base

// Freed memory made loud (run with -define:WREN_POISON_MEMORY=true; test_all has a step). What ends the process (a double
// free, a write to freed memory, a read through a poisoned pointer) is in src\tools\e2e\crash_reports.odin.

@(require) import "base:runtime"
@(require) import "core:mem"
import "core:testing"

@(private = "file") POISON_TEST_BYTES :: 256
@(private = "file") POISON_TEST_POOL_VALUE :: 7

@(private = "file")
all_poison :: proc(p: rawptr, size: int) -> bool {
	for b in ([^]u8)(p)[:size] { if b != POISON_BYTE { return false } }
	return true
}

@(test)
a_freed_block_is_filled_and_stays_out_of_the_heap :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	a := runtime.heap_allocator()
	b, _ := mem.alloc_bytes(POISON_TEST_BYTES, allocator = a)
	p := raw_data(b)
	mem.free(p, a)
	testing.expect(t, all_poison(p, POISON_TEST_BYTES))
	next, _ := mem.alloc_bytes(POISON_TEST_BYTES, allocator = a)
	testing.expect(t, raw_data(next) != p, "the address is not handed out again at once")
	mem.free(raw_data(next), a)
}

@(test)
a_block_that_grows_moves_and_its_old_place_is_poison :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	list := make([dynamic]u8, POISON_TEST_BYTES, POISON_TEST_BYTES, runtime.heap_allocator())
	defer delete(list)
	old := raw_data(list)
	append(&list, 1)
	testing.expect(t, raw_data(list) != old)
	testing.expect(t, all_poison(old, POISON_TEST_BYTES))
}

@(test)
an_emptied_arena_says_so_and_moves_on :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	arena: Arena
	_ = arena_init_growing(&arena)
	defer arena_destroy(&arena)
	a := arena_allocator(&arena)
	first := new([POISON_TEST_BYTES]u8, a)
	arena_free_all(&arena)
	testing.expect(t, all_poison(first, POISON_TEST_BYTES))
	testing.expect_value(t, arena.total_used, 0)
	second := new([POISON_TEST_BYTES]u8, a)
	testing.expect(t, second != first, "the next pass has other addresses")
	testing.expect_value(t, second[0], 0)
}

@(test)
an_arena_temp_rolled_back_is_poison :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	arena: Arena
	_ = arena_init_growing(&arena)
	defer arena_destroy(&arena)
	a := arena_allocator(&arena)
	kept := new(int, a)
	kept^ = 1
	mark := arena_temp_begin(&arena)
	gone := new([POISON_TEST_BYTES]u8, a)
	arena_temp_end(mark)
	testing.expect(t, all_poison(gone, POISON_TEST_BYTES))
	testing.expect_value(t, kept^, 1)
}

@(test)
a_closed_scope_is_poison_and_its_cleanups_ran_first :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	Seen :: struct { block: ^[POISON_TEST_BYTES]u8, intact: bool }
	seen: Seen
	s := scope_make("poison test")
	child := scope_make("poison test child", s)
	seen.block = new([POISON_TEST_BYTES]u8, scope_allocator(s))
	_ = child
	on_close(s, proc(data: rawptr) { x := (^Seen)(data); x.intact = !all_poison(x.block, POISON_TEST_BYTES) }, &seen)
	scope_close(s)
	testing.expect(t, seen.intact, "a cleanup reads its scope's memory")
	testing.expect(t, all_poison(seen.block, POISON_TEST_BYTES))
}

@(test)
free_all_of_the_temporary_allocator_is_poison :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	context = process_context()
	b := new([POISON_TEST_BYTES]u8, context.temp_allocator)
	free_all(context.temp_allocator)
	testing.expect(t, all_poison(b, POISON_TEST_BYTES))
}

@(test)
a_removed_pool_slot_is_poison :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	pool: Pool(int)
	defer pool_destroy(&pool)
	h, p := pool_insert(&pool, POISON_TEST_POOL_VALUE)
	value, ok := pool_remove(&pool, h)
	testing.expect(t, ok && value == POISON_TEST_POOL_VALUE)
	testing.expect(t, all_poison(p, size_of(int)))
	testing.expect(t, pool_get(&pool, h) == nil)
}

when ODIN_OS == .Windows {
	foreign import libc "system:libucrt.lib"
} else {
	foreign import libc "system:c"
}
@(private = "file", default_calling_convention = "c")
foreign libc {
	malloc :: proc(size: uint) -> rawptr ---
	free :: proc(p: rawptr) ---
}

@(test)
what_the_c_runtime_frees_is_poison :: proc(t: ^testing.T) {
	when !POISON_MEMORY { return }
	p := malloc(POISON_TEST_BYTES)
	free(p)
	testing.expect(t, all_poison(p, POISON_TEST_BYTES))
}
