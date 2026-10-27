package style

import "core:testing"
import "wb:dom"
import "wb:html"

@(private = "file")
color_of :: proc(e: ^Engine, doc: ^dom.Document, id: string) -> [4]f32 {
	st := compute_styles(e, doc, {})
	defer styled_destroy(st)
	c := style_of(st, dom.find_by_id(doc, id))
	return c != nil ? c.color : {}
}

// The rule list of a <style>'s sheet: an invalid rule of the text is left out of the texts as of the rules, inserted
// rules apply and keep their identity, the document's sync keeps the sheet while the element's text stays, and a new
// text makes a new sheet without them.
@(test)
cssom_element_sheet_rules :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<style id=s>#a { color: red } ]]bad{ color: blue } #b { color: blue }</style><p id=a>a</p><p id=b>b</p>`), 1 << 20)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	el := dom.find_by_id(doc, "s")
	sh := engine_style_element_sheet(e, doc, el, "about:test")
	testing.expect(t, sh != nil && sh == engine_sheet_of_owner(e, el))
	testing.expect_value(t, engine_sheet_rule_count(e, sh.id), 2)
	txt, _ := engine_sheet_rule_text(e, sh.id, 1)
	testing.expect_value(t, txt, "#b { color: blue }")
	first := engine_sheet_rule_id(e, sh.id, 0)

	testing.expect_value(t, engine_sheet_insert_rule(e, sh.id, "  #a { color: lime }  ", 2), Rule_Edit_Error.None)
	testing.expect_value(t, engine_sheet_insert_rule(e, sh.id, "#b { color: lime } #a {}", 0), Rule_Edit_Error.Syntax)
	testing.expect_value(t, engine_sheet_insert_rule(e, sh.id, "#a {}", 9), Rule_Edit_Error.Index)
	testing.expect_value(t, engine_sheet_insert_rule(e, sh.id, "@import url(x.css);", 0), Rule_Edit_Error.Import)
	testing.expect_value(t, color_of(e, doc, "a"), [4]f32{0, 1, 0, 1})
	testing.expect_value(t, engine_sheet_insert_rule(e, sh.id, "#b { color: lime }", 0), Rule_Edit_Error.None)
	testing.expect_value(t, engine_sheet_rule_id(e, sh.id, 1), first)
	testing.expect_value(t, engine_sheet_delete_rule(e, sh.id, 3), Rule_Edit_Error.None)
	testing.expect_value(t, color_of(e, doc, "a"), [4]f32{1, 0, 0, 1})
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{0, 0, 1, 1})   // the later #b rule of the text wins

	// a mutation elsewhere: the document's sync keeps the changed sheet
	dom.append_child(doc, dom.find_by_id(doc, "b"), dom.create_text(doc, "!"))
	sync_document_sheets(e, doc, "about:test")
	testing.expect(t, engine_find_sheet(e, sh.id) != nil)
	testing.expect_value(t, engine_sheet_rule_count(e, sh.id), 3)

	// a new text: a new sheet, the inserted rules gone with the old one
	old := sh.id
	dom.set_text_content(doc, el, "#a { color: blue }")
	sh2 := engine_style_element_sheet(e, doc, el, "about:test")
	testing.expect(t, sh2 != nil && sh2.id != old && engine_find_sheet(e, old) == nil)
	testing.expect_value(t, engine_sheet_rule_count(e, sh2.id), 1)
	testing.expect_value(t, color_of(e, doc, "a"), [4]f32{0, 0, 1, 1})
}
