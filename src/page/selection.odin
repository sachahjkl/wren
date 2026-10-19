package page

import "wb:base"
import "wb:dom"
import lay "wb:layout"

// The document's selection (Selection API, one range): an anchor and a focus, each a DOM boundary point (text node +
// byte offset, or element + child index). The shell changes it from the pointer and the keyboard; scripts will through
// the bindings. It follows the DOM: after mutations the boundaries are checked (`selection_validate`): offsets past
// the end of a shortened text are clamped, a boundary whose node left the document clears the selection.
// `selectionchange` is fired at the document once per batch of changes (`selection_flush`, called by the shell each
// frame), as the spec queues it.
//
// For the bindings (Web IDL, to be generated): Document.getSelection() / Window.getSelection() -> a Selection object
// whose members map onto these procedures:
//   anchorNode / anchorOffset / focusNode / focusOffset   selection_get (offsets: lay.utf16_offset for text nodes)
//   isCollapsed / rangeCount / type                       selection_is_collapsed, Page_Selection.has
//   getRangeAt(0) (startContainer...)                     selection_range
//   collapse(node, offset) / setPosition                  selection_collapse
//   extend(node, offset)                                  selection_extend
//   setBaseAndExtent(a, ao, f, fo)                        selection_set
//   selectAllChildren(node)                               selection_select_contents
//   removeAllRanges() / empty()                           selection_clear
//   toString()                                            selection_text
//   Document "selectionchange", Node "selectstart"        fired here / by the shell
// Offsets given by scripts are UTF-16 code units: convert with lay.utf8_offset before calling.

Page_Selection :: struct {
	anchor, focus: lay.Text_Pos,
	has:       bool,     // a range exists (it may be collapsed)
	mutations: u64,      // doc.mutations the boundaries were last checked against
	pending:   bool,     // selectionchange to fire
	serial:    u64,      // changes on every change (the painter repaints)
}

selection_get :: proc(p: ^Page) -> ^Page_Selection {
	selection_validate(p)
	return &p.selection
}

// The range in document order. ok = false: no selection.
selection_range :: proc(p: ^Page) -> (start, end: lay.Text_Pos, ok: bool) {
	s := selection_get(p)
	if !s.has { return }
	if lay.pos_compare(p.doc, s.anchor, s.focus) <= 0 { return s.anchor, s.focus, true }
	return s.focus, s.anchor, true
}

selection_is_collapsed :: proc(p: ^Page) -> bool {
	s := selection_get(p)
	return !s.has || (s.anchor == s.focus)
}

// Something is selected (a range that is not collapsed).
selection_active :: proc(p: ^Page) -> bool { return !selection_is_collapsed(p) }

@(private)
selection_changed :: proc(p: ^Page) {
	p.selection.pending = true
	p.selection.serial += 1
	p.selection.mutations = p.doc.mutations
}

@(private)
pos_valid :: proc(p: ^Page, pos: lay.Text_Pos) -> bool {
	n := dom.get(p.doc, pos.node)
	if n == nil || !lay.in_document(p.doc, pos.node) { return false }
	if pos.offset < 0 || pos.offset > lay.node_length(p.doc, pos.node) { return false }
	if n.kind == .Text && pos.offset < len(n.text) && n.text[pos.offset] & 0xC0 == 0x80 { return false }
	return true
}

selection_set :: proc(p: ^Page, anchor, focus: lay.Text_Pos) -> bool {
	if !pos_valid(p, anchor) || !pos_valid(p, focus) { return false }
	s := &p.selection
	if s.has && s.anchor == anchor && s.focus == focus { return true }
	s.anchor, s.focus, s.has = anchor, focus, true
	selection_changed(p)
	return true
}

selection_collapse :: proc(p: ^Page, pos: lay.Text_Pos) -> bool { return selection_set(p, pos, pos) }

// Moves the focus, the anchor stays (a collapsed selection at `pos` when there was none).
selection_extend :: proc(p: ^Page, focus: lay.Text_Pos) -> bool {
	s := selection_get(p)
	if !s.has { return selection_collapse(p, focus) }
	return selection_set(p, s.anchor, focus)
}

selection_clear :: proc(p: ^Page) {
	s := &p.selection
	if !s.has { return }
	s.has = false
	s.anchor, s.focus = {}, {}
	selection_changed(p)
}

// All the children of `h` (selectAllChildren).
selection_select_contents :: proc(p: ^Page, h: base.Handle) -> bool {
	if dom.get(p.doc, h) == nil { return false }
	return selection_set(p, {h, 0}, {h, lay.node_length(p.doc, h)})
}

// Select all: the body's contents (the document element's without a body).
selection_select_all :: proc(p: ^Page) -> bool {
	target := p.body
	if dom.get(p.doc, target) == nil || !lay.in_document(p.doc, target) { target = p.doc_el }
	if dom.get(p.doc, target) == nil { return false }
	return selection_select_contents(p, target)
}

// The selection after DOM mutations: offsets clamped into shortened texts (and back onto a character boundary),
// cleared when a boundary's node is no longer in the document.
selection_validate :: proc(p: ^Page) {
	s := &p.selection
	if !s.has || s.mutations == p.doc.mutations { return }
	s.mutations = p.doc.mutations
	fix :: proc(p: ^Page, pos: ^lay.Text_Pos) -> (ok, moved: bool) {
		n := dom.get(p.doc, pos.node)
		if n == nil || !lay.in_document(p.doc, pos.node) { return false, false }
		limit := lay.node_length(p.doc, pos.node)
		o := clamp(pos.offset, 0, limit)
		if n.kind == .Text { for o > 0 && o < len(n.text) && n.text[o] & 0xC0 == 0x80 { o -= 1 } }
		moved = o != pos.offset
		pos.offset = o
		return true, moved
	}
	aok, am := fix(p, &s.anchor)
	fok, fm := fix(p, &s.focus)
	if !aok || !fok { selection_clear(p); return }
	if am || fm { s.pending = true; s.serial += 1 }
}

// The selected text, serialized as innerText would (empty without a selection).
selection_text :: proc(p: ^Page, allocator := context.temp_allocator) -> string {
	a, b, ok := selection_range(p)
	if !ok || a == b { return "" }
	return lay.range_text(p.doc, p.styled, a, b, allocator = allocator, selectable_only = true).text
}

// The selected nodes as markup (for the clipboard's HTML flavour).
selection_html :: proc(p: ^Page, allocator := context.temp_allocator) -> string {
	a, b, ok := selection_range(p)
	if !ok || a == b { return "" }
	return lay.range_html(p.doc, a, b, allocator)
}

// Fires the queued selectionchange at the document (once for any number of changes since the last call).
selection_flush :: proc(p: ^Page) {
	selection_validate(p)
	if !p.selection.pending { return }
	p.selection.pending = false
	dispatch_event(p, p.doc.root, dom.Event{type = "selectionchange"})
}
