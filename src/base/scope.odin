// Package base: ownership and lifetime primitives shared by every subsystem.
//
// The Scope tree (an arena plus a list of cleanups, with child scopes) and the generational Pool now live in the toolkit's
// platform-neutral `arena` package (toolkit:arena), a cross-application concern; base keeps the historic names
// (base.Scope, base.scope_make, base.Pool, base.Handle, ...) as aliases so the hundreds of callers do not change. See
// toolkit:arena for the whole picture.
//
// The browser is a tree of scopes:
//
//     process ── tab ── document ── (requests, timers, wasm instance, DOM pools, ...)
//
// so "close the tab" cancels every in-flight request and frees everything without any subsystem keeping a list of
// what belongs to whom. Scopes are main-thread objects: worker threads never touch them.
package base

@(require) import "base:runtime"
@(require) import "core:sync"
import "../../ext/gui_toolkit/arena"

Cleanup_Proc :: arena.Cleanup_Proc
Cleanup_Id :: arena.Cleanup_Id
Cleanup :: arena.Cleanup
Scope :: arena.Scope

on_close :: arena.on_close
forget_cleanup :: arena.forget_cleanup
rebind_cleanup :: arena.rebind_cleanup
run_cleanup :: arena.run_cleanup
scope_close :: arena.scope_close

when POISON_MEMORY {
	// A scope's memory is a Poison_Arena that goes last, after its children and its cleanups: the first cleanup registered is
	// the last to run. (arena.Scope keeps its own virtual arena: the toolkit knows nothing of this.)
	@(private) Scope_Arenas :: struct { lock: sync.Mutex, of: map[^Scope]^Arena }
	@(private) scope_arenas: Scope_Arenas

	scope_make :: proc(name: string, parent: ^Scope = nil) -> ^Scope {
		s := arena.scope_make(name, parent)
		on_close(s, scope_arena_close, s)
		context.allocator = HEAP
		a := new(Arena)
		_ = arena_init_growing(a)
		sync.guard(&scope_arenas.lock)
		scope_arenas.of[s] = a
		return s
	}

	scope_allocator :: proc(s: ^Scope) -> runtime.Allocator {
		sync.guard(&scope_arenas.lock)
		return arena_allocator(scope_arenas.of[s])
	}

	@(private)
	scope_arena_close :: proc(data: rawptr) {
		s := (^Scope)(data)
		context.allocator = HEAP
		sync.lock(&scope_arenas.lock)
		a := scope_arenas.of[s]
		delete_key(&scope_arenas.of, s)
		if len(scope_arenas.of) == 0 { delete(scope_arenas.of); scope_arenas.of = nil }
		sync.unlock(&scope_arenas.lock)
		arena_destroy(a)
		free(a)
	}
} else {
	scope_make :: arena.scope_make
	scope_allocator :: arena.scope_allocator
}
