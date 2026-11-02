package style

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

// Identical styles shared (share.odin): elements with the same inputs get one record; an element that differs in one
// input of its style, or in something of its own the style depends on, gets its own. And the inherited properties
// (types.odin Inherited_Group): shared with the parent until an element sets one.

// What a test page may hold.
@(private = "file")
PARSE_MAX_BYTES :: 1 << 20

@(private = "file")
Fx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
}

@(private = "file")
load :: proc(src: string) -> Fx {
	f: Fx
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, PARSE_MAX_BYTES)
	s := settings_default()
	f.eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	return f
}

@(private = "file")
restyle :: proc(f: ^Fx, state: State = {}) {
	styled_destroy(f.st)
	f.st = compute_styles(f.eng, f.doc, state)
}

@(private = "file")
unload :: proc(f: ^Fx) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
at :: proc(f: ^Fx, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

@(private = "file")
el :: proc(f: ^Fx, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

@(test)
share_same_inputs_one_record :: proc(t: ^testing.T) {
	f := load(`<style>li { color: rgb(0, 0, 255) } span { font-weight: 700 }</style>
		<ul><li id=a><span id=sa>x</span></li><li id=b><span id=sb>y</span></li><li id=c class=other><span id=sc>z</span></li></ul>`)
	defer unload(&f)
	testing.expect(t, at(&f, "a") != nil && at(&f, "a") == at(&f, "b"), "two list items with the same inputs: one record")
	testing.expect(t, at(&f, "sa") == at(&f, "sb"), "their children too (the same parent record)")
	testing.expect(t, at(&f, "a").marker_text == "• ", "the shared record's marker is resolved")
	// a class no rule names matches nothing more: the same inputs still
	testing.expect(t, at(&f, "c") == at(&f, "a"), "a class that matches no rule changes nothing")
}

@(test)
share_inline_style_apart :: proc(t: ^testing.T) {
	f := load(`<p id=a style="color: rgb(255, 0, 0)">1</p><p id=b style="color: rgb(0, 0, 255)">2</p><p id=c style="color: rgb(255, 0, 0)">3</p>`)
	defer unload(&f)
	a, b, c := at(&f, "a"), at(&f, "b"), at(&f, "c")
	testing.expect(t, a != b, "different style attributes: two records")
	testing.expect(t, a.color.r == 1 && b.color.b == 1, "each with its own color")
	testing.expect(t, a == c, "the same style attribute: one record")
}

@(test)
share_attr_content_apart :: proc(t: ^testing.T) {
	f := load(`<style>p::before { content: attr(data-x) }</style><p id=a data-x="one">1</p><p id=b data-x="two">2</p>`)
	defer unload(&f)
	a, b := at(&f, "a"), at(&f, "b")
	testing.expect(t, a != b, "attr() in generated content: each element its own record")
	ok := a.before != nil && b.before != nil && len(a.before.content.items) == 1 && len(b.before.content.items) == 1
	testing.expect(t, ok && a.before.content.items[0].text == "one" && b.before.content.items[0].text == "two", "each with its own attribute's text")
}

@(test)
share_lang_apart :: proc(t: ^testing.T) {
	f := load(`<html lang=en><body><p id=a lang=fr>1</p><p id=b lang=de>2</p><p id=c>3</p><p id=d lang=en>4</p></body></html>`)
	defer unload(&f)
	a, b, c, d := at(&f, "a"), at(&f, "b"), at(&f, "c"), at(&f, "d")
	testing.expect(t, a != b && a.content_language == "fr" && b.content_language == "de", "two languages: two records")
	testing.expect(t, c.content_language == "en" && c == d, "the parent's language, inherited or written again: one record")
}

@(test)
share_hover_apart :: proc(t: ^testing.T) {
	f := load(`<style>p:hover { color: rgb(255, 0, 0) }</style><p id=a>1</p><p id=b>2</p><p id=c>3</p>`)
	defer unload(&f)
	restyle(&f, State{hover = el(&f, "a")})
	a, b, c := at(&f, "a"), at(&f, "b"), at(&f, "c")
	testing.expect(t, a != b && a.color.r == 1 && b.color.r != 1, "the hovered element: its own record")
	testing.expect(t, b == c, "the others share one")
}

@(test)
share_container_apart :: proc(t: ^testing.T) {
	f := load(`<style>.q { container-type: inline-size } p { width: 50cqw } @container (min-width: 300px) { p { color: rgb(255, 0, 0) } }</style>
		<div class=q id=wide><p id=a>1</p><p id=a2>2</p></div><div class=q id=narrow><p id=b>3</p></div>`)
	defer unload(&f)
	f.eng.container_sizes[el(&f, "wide")] = {400, 0}
	f.eng.container_sizes[el(&f, "narrow")] = {100, 0}
	restyle(&f)
	a, a2, b := at(&f, "a"), at(&f, "a2"), at(&f, "b")
	testing.expect(t, at(&f, "wide") != at(&f, "narrow"), "query containers: each its own record")
	testing.expect(t, a != b && a.color.r == 1 && b.color.r != 1, "children of containers of two sizes: two records, the query holds in one")
	testing.expect(t, a.width.kind == .Px && a.width.v == 200 && b.width.v == 50, "cq units of each container")
	testing.expect(t, a == a2, "children of the same container share")
}

@(test)
share_counter_markers_apart :: proc(t: ^testing.T) {
	f := load(`<ol><li id=a>1</li><li id=b>2</li></ol>`)
	defer unload(&f)
	a, b := at(&f, "a"), at(&f, "b")
	testing.expect(t, a != b && a.marker_text == "1. " && b.marker_text == "2. ", "numbered markers: each item its own record")
}

@(test)
share_inherited_group :: proc(t: ^testing.T) {
	f := load(`<style>div { color: rgb(0, 0, 255); padding-left: 3px } .big { font-size: 30px } .same { color: rgb(0, 0, 255) }</style>
		<div id=p><p id=plain>1</p><p id=big class=big>2</p><p id=same class=same>3</p><p id=lang lang=fr>4</p></div>`)
	defer unload(&f)
	p, plain, big, same, lang := at(&f, "p"), at(&f, "plain"), at(&f, "big"), at(&f, "same"), at(&f, "lang")
	testing.expect(t, plain.inherited_group == p.inherited_group, "no inherited property set: the parent's group")
	testing.expect(t, big.inherited_group != p.inherited_group && big.font_size == 30, "font-size set: a group of its own")
	testing.expect(t, p.font_size != 30 && p.color.b == 1 && plain.color.b == 1, "the parent's values stay")
	testing.expect(t, same.color.b == 1, "an inherited property set to the parent's value")
	testing.expect(t, lang.inherited_group != p.inherited_group && lang.content_language == "fr" && p.content_language == "", "another language: a group of its own")
	testing.expect(t, p.inherited_group != f.st.initial.inherited_group && f.st.initial.color.b != 1, "the initial values stay")
}