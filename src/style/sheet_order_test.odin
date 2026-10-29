package style

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

// The parser's reveal keeps the sheets of the links it has detached for a while. They are rebuilt in that state
// (their owners are nowhere, so they stay in the order they arrived); once the owners are back, the sheets are ordered
// by the document again: the later link wins.
@(test)
sheet_order_after_detached_owners :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<link id=l1 rel=stylesheet href=a.css><link id=l2 rel=stylesheet href=b.css><p id=a>a</p>`), 1 << 20)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	l1, l2 := dom.find_by_id(doc, "l1"), dom.find_by_id(doc, "l2")
	// the second link's sheet arrives first
	engine_add_sheet(e, "#a { color: blue }", l2, "", "about:test", true)
	engine_add_sheet(e, "#a { color: red }", l1, "", "about:test", true)

	p1, p2 := dom.get(doc, l1).parent, dom.get(doc, l2).parent
	dom.detach(doc, l1)
	dom.detach(doc, l2)
	sync_document_sheets(e, doc, "about:test", keep_missing = proc(user: rawptr, owner: base.Handle) -> bool { return true })
	testing.expect_value(t, len(e.sheets), 3)
	st := compute_styles(e, doc, {})
	styled_destroy(st)

	dom.insert_before(doc, p1, l1, dom.get(doc, p1).first_child)
	dom.insert_before(doc, p2, l2, dom.get(doc, l1).next)
	sync_document_sheets(e, doc, "about:test", keep_missing = proc(user: rawptr, owner: base.Handle) -> bool { return true })
	testing.expect(t, e.dirty)
	st = compute_styles(e, doc, {})
	defer styled_destroy(st)
	c := style_of(st, dom.find_by_id(doc, "a"))
	testing.expect(t, c != nil && c.color == [4]f32{0, 0, 1, 1})   // l2 comes after l1: blue
}
