package style

import "core:testing"
import "wb:dom"

// Values the flex and grid layouts depend on: the flex shorthand with a unitless zero basis, min-width: auto kept as
// auto, tab-size in spaces, the canvas taking the body's background, the initial justify-self.

@(test)
layout_values :: proc(t: ^testing.T) {
	f := fixture_load(`<html><body style="background:rgb(0,128,0)">
<div id=f1 style="flex:1 1 0"></div><div id=f2 style="flex:2 0 0"></div><div id=f3 style="flex:0 1 0px"></div>
<div id=m0></div><div id=m1 style="min-width:0;min-height:auto"></div>
<pre id=t0></pre><pre id=t4 style="tab-size:4"></pre><pre id=tp style="tab-size:20px"></pre>
<div id=j style="justify-items:legacy"></div></body></html>`)
	defer fixture_unload(f)
	at :: proc(f: ^Fixture, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

	f1 := at(f, "f1")
	testing.expect(t, f1.flex_grow == 1 && f1.flex_shrink == 1 && f1.flex_basis.kind == .Px && f1.flex_basis.v == 0, "flex: 1 1 0")
	f2 := at(f, "f2")
	testing.expect(t, f2.flex_grow == 2 && f2.flex_shrink == 0 && f2.flex_basis.kind == .Px, "flex: 2 0 0")
	f3 := at(f, "f3")
	testing.expect(t, f3.flex_grow == 0 && f3.flex_shrink == 1 && f3.flex_basis.kind == .Px, "flex: 0 1 0px")

	testing.expect(t, at(f, "m0").min_width.kind == .Auto && at(f, "m0").min_height.kind == .Auto, "min-width / min-height initial: auto")
	m1 := at(f, "m1")
	testing.expect(t, m1.min_width.kind == .Px && m1.min_width.v == 0 && m1.min_height.kind == .Auto, "min-width: 0 is not auto")

	t0, t4, tp := at(f, "t0"), at(f, "t4"), at(f, "tp")
	testing.expect(t, t0.tab_spaces && t0.tab_size == 8, "tab-size initial: 8 spaces")
	testing.expect(t, t4.tab_spaces && t4.tab_size == 4, "tab-size: 4 spaces")
	testing.expect(t, !tp.tab_spaces && tp.tab_size == 20, "tab-size: 20px")

	testing.expect(t, at(f, "f1").justify_self == .Auto, "justify-self initial: auto")
	testing.expect(t, at(f, "j").justify_items == .Normal, "justify-items: legacy behaves as normal")

	// the root has no background: the body's propagates to the canvas
	testing.expect(t, f.st.canvas.g > 0.49 && f.st.canvas.g < 0.51 && f.st.canvas.r == 0, "canvas from the body background")
}

@(test)
canvas_default :: proc(t: ^testing.T) {
	f := fixture_load(`<html><body></body></html>`)
	defer fixture_unload(f)
	testing.expect(t, f.st.canvas == f.st.canvas_default, "no background anywhere: the preference")
	g := fixture_load(`<html style="background:blue"><body style="background:red"></body></html>`)
	defer fixture_unload(g)
	testing.expect(t, g.st.canvas.b > 0.99 && g.st.canvas.r == 0, "the root's background wins over the body's")
}
