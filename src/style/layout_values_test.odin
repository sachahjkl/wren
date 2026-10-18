package style

import "core:testing"
import "wb:dom"
import "wb:html"

// Values the flex and grid layouts depend on: the flex shorthand with a unitless zero basis, min-width: auto kept as
// auto, tab-size in spaces, the canvas taking the body's background, the initial justify-self.

@(private = "file")
styled_doc :: proc(src: string) -> (^dom.Document, ^Engine, ^Styled) {
	doc := dom.document_create(nil)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	eng := engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(eng, doc, "about:test")
	return doc, eng, compute_styles(eng, doc, {})
}

@(test)
layout_values :: proc(t: ^testing.T) {
	doc, eng, st := styled_doc(`<html><body style="background:rgb(0,128,0)">
<div id=f1 style="flex:1 1 0"></div><div id=f2 style="flex:2 0 0"></div><div id=f3 style="flex:0 1 0px"></div>
<div id=m0></div><div id=m1 style="min-width:0;min-height:auto"></div>
<pre id=t0></pre><pre id=t4 style="tab-size:4"></pre><pre id=tp style="tab-size:20px"></pre>
<div id=j style="justify-items:legacy"></div></body></html>`)
	defer { styled_destroy(st); engine_destroy(eng); dom.document_destroy(doc) }
	at :: proc(doc: ^dom.Document, st: ^Styled, id: string) -> ^Computed { return style_of(st, dom.find_by_id(doc, id)) }

	f1 := at(doc, st, "f1")
	testing.expect(t, f1.flex_grow == 1 && f1.flex_shrink == 1 && f1.flex_basis.kind == .Px && f1.flex_basis.v == 0, "flex: 1 1 0")
	f2 := at(doc, st, "f2")
	testing.expect(t, f2.flex_grow == 2 && f2.flex_shrink == 0 && f2.flex_basis.kind == .Px, "flex: 2 0 0")
	f3 := at(doc, st, "f3")
	testing.expect(t, f3.flex_grow == 0 && f3.flex_shrink == 1 && f3.flex_basis.kind == .Px, "flex: 0 1 0px")

	testing.expect(t, at(doc, st, "m0").min_width.kind == .Auto && at(doc, st, "m0").min_height.kind == .Auto, "min-width / min-height initial: auto")
	m1 := at(doc, st, "m1")
	testing.expect(t, m1.min_width.kind == .Px && m1.min_width.v == 0 && m1.min_height.kind == .Auto, "min-width: 0 is not auto")

	t0, t4, tp := at(doc, st, "t0"), at(doc, st, "t4"), at(doc, st, "tp")
	testing.expect(t, t0.tab_spaces && t0.tab_size == 8, "tab-size initial: 8 spaces")
	testing.expect(t, t4.tab_spaces && t4.tab_size == 4, "tab-size: 4 spaces")
	testing.expect(t, !tp.tab_spaces && tp.tab_size == 20, "tab-size: 20px")

	testing.expect(t, at(doc, st, "f1").justify_self == .Auto, "justify-self initial: auto")
	testing.expect(t, at(doc, st, "j").justify_items == .Normal, "justify-items: legacy behaves as normal")

	// the root has no background: the body's propagates to the canvas
	testing.expect(t, st.canvas.g > 0.49 && st.canvas.g < 0.51 && st.canvas.r == 0, "canvas from the body background")
}

@(test)
canvas_default :: proc(t: ^testing.T) {
	doc, eng, st := styled_doc(`<html><body></body></html>`)
	defer { styled_destroy(st); engine_destroy(eng); dom.document_destroy(doc) }
	testing.expect(t, st.canvas == st.canvas_default, "no background anywhere: the preference")
	doc2, eng2, st2 := styled_doc(`<html style="background:blue"><body style="background:red"></body></html>`)
	defer { styled_destroy(st2); engine_destroy(eng2); dom.document_destroy(doc2) }
	testing.expect(t, st2.canvas.b > 0.99 && st2.canvas.r == 0, "the root's background wins over the body's")
}
