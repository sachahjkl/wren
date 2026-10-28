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

import "../../ext/gui_toolkit/arena"

Cleanup_Proc :: arena.Cleanup_Proc
Cleanup_Id :: arena.Cleanup_Id
Cleanup :: arena.Cleanup
Scope :: arena.Scope

scope_make :: arena.scope_make
scope_allocator :: arena.scope_allocator
on_close :: arena.on_close
forget_cleanup :: arena.forget_cleanup
rebind_cleanup :: arena.rebind_cleanup
run_cleanup :: arena.run_cleanup
scope_close :: arena.scope_close
