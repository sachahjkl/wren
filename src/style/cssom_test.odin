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
	r := engine_sheet_rule(e, sh.id, 1)
	testing.expect(t, r != nil && r.selector_text == "#b")
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

// selectorText = x on a sheet's rule: the rule selects what x does, serialized; an invalid selector changes nothing.
@(test)
cssom_rule_selector_set :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<style id=s>#a { color: red }</style><p id=a>a</p><p id=b>b</p>`), 1 << 20)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	sh := engine_style_element_sheet(e, doc, dom.find_by_id(doc, "s"), "about:test")
	id := engine_sheet_rule_id(e, sh.id, 0)
	testing.expect_value(t, engine_sheet_set_selector(e, sh.id, id, "P#b , q"), 0)
	testing.expect_value(t, engine_sheet_rule(e, sh.id, 0).selector_text, "P#b, q")
	testing.expect_value(t, color_of(e, doc, "a"), [4]f32{0, 0, 0, 1})
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{1, 0, 0, 1})
	testing.expect_value(t, engine_sheet_set_selector(e, sh.id, id, "p..b"), -1)
	testing.expect_value(t, engine_sheet_set_selector(e, sh.id, id + 1, "p"), -1)
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{1, 0, 0, 1})
	// its style written (CSSStyleRule.style): the rule's declarations are those now
	testing.expect_value(t, engine_sheet_set_declarations(e, sh.id, id, "color: blue;"), 0)
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{0, 0, 1, 1})
}

// The rules inside rules (CSSGroupingRule): numbered when listed, inserted into and deleted from a @media and a style
// rule (CSS Nesting: & against the parent, declarations alone a nested declarations rule), what cannot be there refused,
// and every change reaching the cascade; an outer selector set takes its nested rules along.
@(test)
cssom_nested_rule_edits :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<style id=s>@media all { #a { color: red } } .x { color: red; & p { color: red } }</style><p id=a>a</p><div class=x><p id=b>b</p></div><div class=y><p id=c>c</p></div>`), 1 << 20)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	sh := engine_style_element_sheet(e, doc, dom.find_by_id(doc, "s"), "about:test")
	media, style_rule := engine_sheet_rule_id(e, sh.id, 0), engine_sheet_rule_id(e, sh.id, 1)
	testing.expect_value(t, engine_rule_child_count(e, sh.id, media), 1)

	// a @media's list
	top, err := engine_rule_insert(e, sh.id, media, "#a { color: lime }", 1)
	testing.expect_value(t, err, Rule_Edit_Error.None)
	testing.expect_value(t, top, 0)
	testing.expect_value(t, color_of(e, doc, "a"), [4]f32{0, 1, 0, 1})
	_, err = engine_rule_insert(e, sh.id, media, "#a {}", 3)
	testing.expect_value(t, err, Rule_Edit_Error.Index)
	_, err = engine_rule_insert(e, sh.id, media, "@import url(x.css);", 0)
	testing.expect_value(t, err, Rule_Edit_Error.Hierarchy)
	_, err = engine_rule_delete(e, sh.id, media, 1)
	testing.expect_value(t, err, Rule_Edit_Error.None)
	testing.expect_value(t, color_of(e, doc, "a"), [4]f32{1, 0, 0, 1})

	// a style rule's: & against .x, declarations alone, a @font-face refused
	nested := engine_rule_child_id(e, sh.id, style_rule, 0)
	testing.expect(t, nested != 0)
	_, err = engine_rule_insert(e, sh.id, style_rule, "& > p { color: lime }", 1)
	testing.expect_value(t, err, Rule_Edit_Error.None)
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{0, 1, 0, 1})
	_, err = engine_rule_insert(e, sh.id, style_rule, "color: blue;", 0)
	testing.expect_value(t, err, Rule_Edit_Error.None)
	testing.expect_value(t, engine_rule_child_count(e, sh.id, style_rule), 3)
	_, err = engine_rule_insert(e, sh.id, style_rule, "@font-face { font-family: f }", 0)
	testing.expect_value(t, err, Rule_Edit_Error.Hierarchy)
	_, err = engine_rule_insert(e, sh.id, style_rule, "nonsense: 1;", 0)
	testing.expect_value(t, err, Rule_Edit_Error.Syntax)

	// the nested rule keeps its number, its style and its selector written; the outer selector set moves it along
	testing.expect_value(t, engine_rule_child_id(e, sh.id, style_rule, 1), nested)
	testing.expect_value(t, engine_sheet_set_declarations(e, sh.id, nested, "color: blue;"), 1)
	_, err = engine_rule_delete(e, sh.id, style_rule, 2)
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{0, 0, 1, 1})
	testing.expect_value(t, engine_sheet_set_selector(e, sh.id, style_rule, ".y"), 1)
	testing.expect_value(t, color_of(e, doc, "b"), [4]f32{0, 0, 0, 1})
	testing.expect_value(t, color_of(e, doc, "c"), [4]f32{0, 0, 1, 1})
}
