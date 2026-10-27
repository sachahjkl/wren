package page

// What an embedder (the content blocker) hooks into a page, and the few services it needs from it. Nothing here costs
// anything while no hook is installed.

import "wb:base"
import "wb:css"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:style"

Embedder_Hooks :: struct {
	user:          rawptr,
	// The page's JavaScript realm was just created, before any script of the page ran.
	realm_started: proc(user: rawptr, p: ^Page),
	// A parsed document replaced the page's blank one: its elements exist, nothing was styled or painted yet.
	adopted:       proc(user: rawptr, p: ^Page),
	// Before each computation of the page's styles (cheap to return from: it is called every time).
	before_styles: proc(user: rawptr, p: ^Page),
	// A script element is about to be read (parser-inserted or not, before its text, src or type are looked at): the blocker may rewrite the
	// text of an inline script natively before it runs, and settle the DOM changes made so far.
	before_script: proc(user: rawptr, p: ^Page, script: base.Handle),
	// The parser has finished: readyState is interactive.
	parsed:        proc(user: rawptr, p: ^Page),
	// A new window / tab is about to open from page `p` for `url` (absolute): `user_gesture` is whether the opening is
	// backed by a recent click or key press in `p` (HTML transient activation). The blocker returns true to stop it
	// (a `$popup` filter): the opening is dropped, no tab is created. nil = popups are never stopped here.
	popup_check:   proc(user: rawptr, p: ^Page, url: string, user_gesture: bool) -> bool,
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

// What the blocker does to a page natively, in place of the JavaScript it would otherwise run in the page's realm: the same effect
// as the page's own `element.click()`, `document.cookie = ...`, `localStorage.setItem(...)`, without a realm.

// A click on the element, as `HTMLElement.click()` does it.
click_element :: proc(p: ^Page, el: base.Handle) -> bool { return forms.synthetic_click(page_forms(p), el) }

// A cookie as `document.cookie = text` stores it (the document's URL, not HttpOnly). False when the document cannot have cookies.
store_cookie :: proc(p: ^Page, text: string) -> bool {
	cc, ok := cookie_context(p)
	if !ok { return false }
	r := cookies.store(&p.loader.profile.jar, text, cc)
	return r == .Stored || r == .Replaced || r == .Deleted
}

// localStorage / sessionStorage as the page's own `setItem` / `removeItem` write them (the quota and the origin are checked).
storage_write :: proc(p: ^Page, session: bool, key, value: string) -> bool {
	return storage_set_item(p, session ? .Session : .Local, key, value) == 0
}

storage_delete :: proc(p: ^Page, session: bool, key: string) -> bool {
	return storage_remove_item(p, session ? .Session : .Local, key) == 0
}

// The cookies the document can read (document.cookie), as "name=value; name=value".
document_cookies :: proc(p: ^Page) -> string {
	cc, ok := cookie_context(p)
	if !ok { return "" }
	return cookies.header_for(&p.loader.profile.jar, cc, context.temp_allocator)
}

_ :: fetch