package page

import "wb:base"

// query_all's default limit: in effect every match, the bound is against a runaway document.
QUERY_ALL_DEFAULT_LIMIT :: 1 << 20

// Selector queries for the shell (the remote control channel: waiting for an element, clicking or capturing it): the
// document's own selector engine, with no script engine involved (a Wasm-only page has none).

// The first element of the document that `selector` matches. `valid` is false when the selector does not parse.
query_first :: proc(p: ^Page, selector: string) -> (h: base.Handle, valid: bool) {
	if p == nil || p.doc == nil { return base.NIL_HANDLE, false }
	list, ok := selector_list(p, selector)
	if !ok { return base.NIL_HANDLE, false }
	r := select_in(p, p.doc.root, list, true)
	return len(r) > 0 ? r[0] : base.NIL_HANDLE, true
}

// Every match, in tree order, at most `limit` of them (temporary memory).
query_all :: proc(p: ^Page, selector: string, limit := QUERY_ALL_DEFAULT_LIMIT) -> (hs: []base.Handle, valid: bool) {
	if p == nil || p.doc == nil { return nil, false }
	list, ok := selector_list(p, selector)
	if !ok { return nil, false }
	r := select_in(p, p.doc.root, list, false)
	return r[:min(len(r), limit)], true
}
