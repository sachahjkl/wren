package page

// What an embedder (the content blocker) hooks into a page, and the few services it needs from it. Nothing here costs
// anything while no hook is installed.

import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

Embedder_Hooks :: struct {
	user:          rawptr,
	// The page's JavaScript realm was just created, before any script of the page ran.
	realm_started: proc(user: rawptr, p: ^Page),
	// A parsed document replaced the page's blank one: its elements exist, nothing was styled or painted yet.
	adopted:       proc(user: rawptr, p: ^Page),
	// Before each computation of the page's styles (cheap to return from: it is called every time).
	before_styles: proc(user: rawptr, p: ^Page),
	// Frames and images whose request the blocker stopped are hidden instead of showing an error or a broken image.
	collapse_blocked: bool,
}

embedder: Embedder_Hooks

// The elements of the page's document that match a selector list, in tree order. ok = false for an invalid selector.
select_all :: proc(p: ^Page, selector: string, root := base.NIL_HANDLE) -> (out: []base.Handle, ok: bool) {
	list, good := selector_list(p, selector)
	if !good { return nil, false }
	r := root == base.NIL_HANDLE ? p.doc.root : root
	found := select_in(p, r, list, false)
	return found[:], true
}

// Does the element match the selector list?
element_matches :: proc(p: ^Page, el: base.Handle, selector: string) -> bool {
	list, good := selector_list(p, selector)
	if !good { return false }
	m := script_match_ctx(p, el, el)
	return style.matches_list(&m, el, list)
}

selector_valid :: proc(p: ^Page, selector: string) -> bool {
	_, ok := selector_list(p, selector)
	return ok
}

_ :: css
_ :: dom
