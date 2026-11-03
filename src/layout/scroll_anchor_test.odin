package layout

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:style"

// CSS Scroll Anchoring (scroll_anchor.odin): the anchor chosen, and how far it moves when content above it changes size.

@(private = "file") SA_SCROLLED :: 1010   // device px: 10 px into the second block
@(private = "file") SA_OTHER_SCALE :: 1.5
@(private = "file") SA_BODY :: `<body style="margin:0"><div id=top style="height:1000px"></div>` +
	`<div id=p style="height:2000px"><div id=abs style="position:absolute;top:1015px;height:5px"></div><div id=c style="height:10px;margin-top:20px"></div></div>`
@(private = "file") SA_PAGE :: `<!doctype html>` + SA_BODY

// The document restyled after a mutation, then laid out again (what the page does before a frame).
@(private = "file")
sa_relayout :: proc(f: ^Fixture) {
	old := f.st
	f.st = style.compute_styles(f.eng, f.doc, {})
	fixture_run(f)
	style.styled_destroy(old)
}

@(test)
scroll_anchor_follows_content_above :: proc(t: ^testing.T) {
	f := fixture_load(SA_PAGE)
	defer fixture_unload(f)
	c := dom.find_by_id(f.doc, "c")
	a := scroll_anchor_select(&f.l, f.st, 1, SA_SCROLLED, f.vp.y)
	// the block partly in view is looked into: its first child fully in view is the anchor, not the absolutely positioned one before it
	testing.expect_value(t, a.node, c)
	testing.expect_value(t, a.top, 1020)
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "top"), "style", "height:200px")
	sa_relayout(f)
	testing.expect_value(t, scroll_anchor_shift(&f.l, a), -800)
	// none at the top of the document, none for a pass at another scale (another monitor, a zoom)
	testing.expect_value(t, scroll_anchor_select(&f.l, f.st, 1, 0, f.vp.y).node, base.NIL_HANDLE)
	testing.expect_value(t, scroll_anchor_select(&f.l, f.st, SA_OTHER_SCALE, SA_SCROLLED, f.vp.y).node, base.NIL_HANDLE)
}

@(test)
scroll_anchor_none :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><html style="overflow-anchor:none">` + SA_BODY)
	defer fixture_unload(f)
	testing.expect_value(t, scroll_anchor_select(&f.l, f.st, 1, SA_SCROLLED, f.vp.y).node, base.NIL_HANDLE)
	// a box with overflow-anchor: none is passed over, with what is inside it
	g := fixture_load(`<!doctype html><body style="margin:0"><div style="height:1000px"></div><div id=p style="height:300px;overflow-anchor:none"><div style="height:10px;margin-top:20px"></div></div><div id=n style="height:2000px"></div>`)
	defer fixture_unload(g)
	testing.expect_value(t, scroll_anchor_select(&g.l, g.st, 1, SA_SCROLLED, g.vp.y).node, dom.find_by_id(g.doc, "n"))
}
