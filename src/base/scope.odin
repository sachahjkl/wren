// Package base: ownership and lifetime primitives shared by every subsystem.
//
// A Scope owns an arena plus a list of cleanups, and may have child scopes. Closing a scope closes its children
// (newest first), runs its cleanups (newest first), then releases the arena in one go. The browser is a tree:
//
//     process ── tab ── document ── (requests, timers, wasm instance, DOM pools, ...)
//
// so "close the tab" cancels every in-flight request and frees everything without any subsystem keeping a list of
// what belongs to whom. Scopes are main-thread objects: worker threads never touch them.
package base

import "core:mem"
import "core:mem/virtual"

Cleanup_Proc :: #type proc(data: rawptr)

Cleanup_Id :: distinct u64

Cleanup :: struct {
	id:   Cleanup_Id,
	fn:   Cleanup_Proc,
	data: rawptr,
}

Scope :: struct {
	name:     string,
	arena:    virtual.Arena,
	parent:   ^Scope,
	children: [dynamic]^Scope,
	cleanups: [dynamic]Cleanup,
	next_id:  Cleanup_Id,
	closing:  bool,
}

// `name` must outlive the scope (a literal in practice); it only serves diagnostics.
scope_make :: proc(name: string, parent: ^Scope = nil) -> ^Scope {
	s := new(Scope)
	s.name = name
	s.parent = parent
	s.next_id = 1
	_ = virtual.arena_init_growing(&s.arena)
	if parent != nil {
		assert(!parent.closing, "creating a child of a closing scope")
		append(&parent.children, s)
	}
	return s
}

// Memory that lives exactly as long as the scope. Not thread-safe.
scope_allocator :: proc(s: ^Scope) -> mem.Allocator {
	return virtual.arena_allocator(&s.arena)
}

// Registers `fn(data)` to run when the scope closes. Cleanups run in reverse registration order.
on_close :: proc(s: ^Scope, fn: Cleanup_Proc, data: rawptr) -> Cleanup_Id {
	assert(!s.closing, "registering a cleanup on a closing scope")
	id := s.next_id
	s.next_id += 1
	append(&s.cleanups, Cleanup{id, fn, data})
	return id
}

// Removes a cleanup without running it (the resource was released early). Returns false if it was not registered.
forget_cleanup :: proc(s: ^Scope, id: Cleanup_Id) -> bool {
	for i := len(s.cleanups) - 1; i >= 0; i -= 1 {
		if s.cleanups[i].id == id {
			ordered_remove(&s.cleanups, i)
			return true
		}
	}
	return false
}

// Hands cleanup `id`'s place in the order to `fn(data)`: a resource that replaces another (a page's new document)
// is released when the old one would have been, before what was registered before it and after what came since,
// which may hold pointers into it. Returns false if `id` was not registered.
rebind_cleanup :: proc(s: ^Scope, id: Cleanup_Id, fn: Cleanup_Proc, data: rawptr) -> bool {
	for &c in s.cleanups {
		if c.id == id {
			c.fn, c.data = fn, data
			return true
		}
	}
	return false
}

// Runs the cleanup now and unregisters it.
run_cleanup :: proc(s: ^Scope, id: Cleanup_Id) -> bool {
	for i := len(s.cleanups) - 1; i >= 0; i -= 1 {
		if s.cleanups[i].id == id {
			c := s.cleanups[i]
			ordered_remove(&s.cleanups, i)
			c.fn(c.data)
			return true
		}
	}
	return false
}

// Closes the scope and frees it. The pointer is dead afterwards.
scope_close :: proc(s: ^Scope) {
	if s == nil || s.closing { return }
	s.closing = true
	for len(s.children) > 0 {
		child := pop(&s.children)
		child.parent = nil   // already detached: do not search the parent's list again
		scope_close(child)
	}
	// A cleanup may register nothing new (asserted in on_close), but may forget others: re-read the length each turn.
	for len(s.cleanups) > 0 {
		c := pop(&s.cleanups)
		c.fn(c.data)
	}
	if s.parent != nil {
		for c, i in s.parent.children {
			if c == s { unordered_remove(&s.parent.children, i); break }
		}
	}
	delete(s.children)
	delete(s.cleanups)
	virtual.arena_destroy(&s.arena)
	free(s)
}
