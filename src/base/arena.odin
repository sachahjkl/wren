package base

// The arenas of the browser. A normal build has core:mem/virtual's, unchanged (these are its names: nothing is added to
// the release path). A build with -define:WREN_POISON_MEMORY=true has Poison_Arena (poison.odin), the same calls.

@(require) import "core:mem/virtual"

when POISON_MEMORY {
	Arena :: Poison_Arena
	Arena_Temp :: Poison_Arena_Temp
	arena_init_growing :: poison_arena_init
	arena_allocator :: poison_arena_allocator
	arena_allocator_proc :: poison_arena_proc
	arena_free_all :: poison_arena_free_all
	arena_destroy :: poison_arena_destroy
	arena_temp_begin :: poison_arena_temp_begin
	arena_temp_end :: poison_arena_temp_end
	arena_temp_ignore :: poison_arena_temp_ignore
} else {
	Arena :: virtual.Arena
	Arena_Temp :: virtual.Arena_Temp
	arena_init_growing :: virtual.arena_init_growing
	arena_allocator :: virtual.arena_allocator
	arena_allocator_proc :: virtual.arena_allocator_proc
	arena_free_all :: virtual.arena_free_all
	arena_destroy :: virtual.arena_destroy
	arena_temp_begin :: virtual.arena_temp_begin
	arena_temp_end :: virtual.arena_temp_end
	arena_temp_ignore :: virtual.arena_temp_ignore
}

// Whether `a` is one reserved block (what recycling an arena keeps: a growing arena keeps its first block only), and the
// bytes it has committed.
arena_one_block :: proc(a: ^Arena) -> bool {
	when POISON_MEMORY { return true } else { return a.curr_block != nil && a.curr_block.prev == nil }
}

arena_committed :: proc(a: ^Arena) -> int {
	when POISON_MEMORY { return int(a.total_used) } else { return a.curr_block != nil ? int(a.curr_block.committed) : 0 }
}
