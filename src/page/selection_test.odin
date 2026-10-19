package page

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import lay "wb:layout"

@(private = "file")
sel_page :: proc(src: string) -> ^Page {
	p := new(Page)
	p.doc = dom.document_create(nil)
	html.parse_into(p.doc, p.doc.root, transmute([]byte)src, 1_000_000)
	p.body = dom.find_first_by_tag(p.doc, "body")
	p.doc_el = dom.find_first_by_tag(p.doc, "html")
	return p
}

@(private = "file")
sel_free :: proc(p: ^Page) {
	dom.document_destroy(p.doc)
	free(p)
}

@(private = "file")
text_in :: proc(p: ^Page, id: string) -> base.Handle {
	el := dom.find_by_id(p.doc, id)
	return dom.get(p.doc, el).first_child
}

@(test)
selection_follows_the_dom :: proc(t: ^testing.T) {
	p := sel_page(`<body><p id=a>hello world</p><p id=b>second</p></body>`)
	defer sel_free(p)
	a, b := text_in(p, "a"), text_in(p, "b")

	testing.expect(t, page_sel_set(p, {b, 3}, {a, 2}), "a backward selection")
	s, e, ok := selection_range(p)
	testing.expect(t, ok && s == lay.Text_Pos{a, 2} && e == lay.Text_Pos{b, 3}, "the range is in document order")
	testing.expect(t, selection_active(p), "not collapsed")
	testing.expect(t, !selection_set(p, {a, 99}, {a, 1}), "an offset past the end is refused")

	// the text shrinks: offsets are clamped
	dom.set_text_content(p.doc, b, "se")
	s, e, ok = selection_range(p)
	testing.expect(t, ok && e == lay.Text_Pos{b, 2}, "clamped to the new length")
	testing.expect(t, p.selection.pending, "a selectionchange is queued")

	// a boundary's node leaves the document: the selection is cleared
	dom.remove_child(p.doc, p.body, dom.find_by_id(p.doc, "b"))
	_, _, ok = selection_range(p)
	testing.expect(t, !ok, "cleared")

	// select all: the body's children
	testing.expect(t, selection_select_all(p), "select all")
	s, e, ok = selection_range(p)
	testing.expect(t, ok && s.node == p.body && s.offset == 0 && e.offset == lay.child_count(p.doc, p.body), "the body's contents")
	selection_clear(p)
	testing.expect(t, !selection_active(p), "cleared")
}

@(private = "file")
page_sel_set :: proc(p: ^Page, anchor, focus: lay.Text_Pos) -> bool { return selection_set(p, anchor, focus) }
