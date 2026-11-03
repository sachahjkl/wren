package layout

import "core:testing"
import "wb:dom"

// The document's horizontal scroll: its range, what views do with it, its scroll bar.

@(private = "file")
VP_W :: 800
@(private = "file")
VP_H :: 600
@(private = "file")
WIDE :: 3000
@(private = "file")
THUMB_LENGTH_TOLERANCE :: 0.01

@(private = "file")
hx_load :: proc(src: string) -> ^Fixture { return fixture_load(src, VP_W, VP_H, {band_h = FIXTURE_NARROW_BAND_H, inc_verify = true}) }

@(private = "file")
hx_range :: proc(f: ^Fixture) -> [2]f32 {
	lo, hi := doc_scroll_x_range(&f.l, f.vp.x)
	return {lo, hi}
}

@(test)
doc_x_range_no_overflow :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0"><div style="height:3000px">a</div>`)
	defer fixture_unload(f)
	testing.expect_value(t, hx_range(f), [2]f32{0, 0})
	_, _, ok := doc_scrollbar_x(&f.l, f.vp)
	testing.expect(t, !ok, "no horizontal bar")
	track, _, vok := doc_scrollbar(&f.l, f.vp, 0)
	testing.expect(t, vok, "the vertical bar")
	// a classic bar: at the window's right edge, from top to bottom
	testing.expect_value(t, track, Rect{{VP_W - f.l.doc_bars.x, 0}, {VP_W, VP_H}})
}

@(test)
doc_x_range_overflow_right :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0"><div style="width:3000px;height:10px"></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, hx_range(f), [2]f32{0, WIDE - VP_W})
	// what goes left of an origin at the start cannot be reached
	g := hx_load(`<!doctype html><body style="margin:0"><div style="position:absolute;left:-500px;width:100px;height:10px"></div>`)
	defer fixture_unload(g)
	testing.expect_value(t, hx_range(g), [2]f32{0, 0})
}

@(test)
doc_x_range_rtl :: proc(t: ^testing.T) {
	for src in ([]string{
		`<!doctype html><html dir=rtl><body style="margin:0"><div style="width:3000px;height:10px"></div>`,
		`<!doctype html><body dir=rtl style="margin:0"><div style="width:3000px;height:10px"></div>`,
	}) {
		f := hx_load(src)
		defer fixture_unload(f)
		testing.expectf(t, hx_range(f) == [2]f32{VP_W - WIDE, 0}, "%s: %v", src, hx_range(f))
		// at the origin the bar's thumb is at the far end, as the document's end is what shows
		track, thumb, ok := doc_scrollbar_x(&f.l, f.vp)
		testing.expect(t, ok)
		_, _, rail := classic_parts(track, false)
		testing.expect_value(t, thumb.max.x, rail.max.x)
	}
	// what goes right of an origin at the end cannot be reached
	f := hx_load(`<!doctype html><html dir=rtl><body style="margin:0"><div style="position:absolute;left:2000px;width:100px;height:10px"></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, hx_range(f), [2]f32{0, 0})
}

@(test)
doc_x_range_forbidden :: proc(t: ^testing.T) {
	for src in ([]string{
		`<!doctype html><html style="overflow-x:hidden"><body style="margin:0"><div style="width:3000px;height:10px"></div>`,
		`<!doctype html><body style="margin:0;overflow-x:hidden"><div style="width:3000px;height:10px"></div>`,
		`<!doctype html><body style="margin:0;overflow-x:clip"><div style="width:3000px;height:10px"></div>`,
		`<!doctype html><html dir=rtl style="overflow-x:hidden"><body style="margin:0"><div style="width:3000px;height:10px"></div>`,
	}) {
		f := hx_load(src)
		defer fixture_unload(f)
		testing.expectf(t, hx_range(f) == [2]f32{0, 0}, "%s: %v", src, hx_range(f))
		_, _, ok := doc_scrollbar_x(&f.l, f.vp)
		testing.expectf(t, !ok, "%s: no bar", src)
	}
	// the other axis stays free
	f := hx_load(`<!doctype html><body style="margin:0;overflow-y:hidden"><div style="width:3000px;height:3000px"></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, hx_range(f), [2]f32{0, WIDE - VP_W})
	// the horizontal bar alone: the page is the window less its height
	testing.expect(t, f.l.doc_bars.x == 0 && f.l.doc_bars.y > 0, "a horizontal bar only")
	testing.expect_value(t, f.l.height, VP_H - f.l.doc_bars.y)
}

@(test)
doc_x_view :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0">
		<div id=a style="position:absolute;left:0;top:0;width:500px;height:100px"></div>
		<div id=b style="position:absolute;left:1000px;top:0;width:500px;height:100px"></div>
		<div id=fix style="position:fixed;left:10px;top:200px;width:50px;height:50px"></div>
		<div style="width:3000px;height:10px"></div>`)
	defer fixture_unload(f)
	a, b, fix := dom.find_by_id(f.doc, "a"), dom.find_by_id(f.doc, "b"), dom.find_by_id(f.doc, "fix")
	testing.expect_value(t, hit_test(&f.l, {100, 50}, f.vp, 0).node, a)

	set_doc_scroll_x(&f.l, 900)
	// a hit test after the scroll hits what shows there
	testing.expect_value(t, hit_test(&f.l, {100, 50}, f.vp, 0).node, b)
	// the fixed box stays
	testing.expect_value(t, hit_test(&f.l, {20, 210}, f.vp, 0).node, fix)
	v := view_make(&f.l, f.vp, 0, cull = false)
	bi := box_index(&f.l, b)
	testing.expect_value(t, item_x_of(&f.l, &v, bi), 100)
	fi := box_index(&f.l, fix)
	testing.expect_value(t, item_x_of(&f.l, &v, fi), 10)
	// box_of answers in document coordinates: a box does not move, a fixed box goes with the viewport
	r, ok := box_of(&f.l, b, f.vp, 0)
	testing.expect(t, ok && r.border.min.x == 1000)
	rf, fok := box_of(&f.l, fix, f.vp, 0)
	testing.expect(t, fok && rf.fixed && rf.border.min.x == 910)
	// culling on x: what is out of view is not visited
	vis := view_make(&f.l, f.vp, 0)
	seen_a, seen_b := false, false
	for idx in vis.visible {
		if f.l.items[idx].node == a { seen_a = true }
		if f.l.items[idx].node == b { seen_b = true }
	}
	testing.expect(t, !seen_a && seen_b, "the box scrolled out is culled, the one in view is not")
}

@(private = "file")
item_x_of :: proc(l: ^Layout, v: ^View, bi: i32) -> f32 { return l.boxes[bi].abs.x + v.offsets[l.boxes[bi].space].x }

// Views put the page on the device pixel grid, as paint does vertically: what a smooth scroll leaves between two pixels
// is kept (small steps add up) and not drawn.
@(test)
doc_x_snapped :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0"><div style="width:3000px;height:10px"></div>`)
	defer fixture_unload(f)
	set_doc_scroll_x(&f.l, 100.4)
	testing.expect_value(t, f.l.doc_scroll_x, 100.4)
	v := view_make(&f.l, f.vp, 0, cull = false)
	testing.expect_value(t, v.offsets[DOCUMENT_SPACE].x, -100)
	testing.expect_value(t, v.doc_scroll_x, 100)
	reset(&f.l)
	testing.expect_value(t, f.l.doc_scroll_x, 0)
}

@(test)
doc_x_sticky :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0"><div style="width:3000px;height:100px">
		<div id=s style="position:sticky;left:20px;width:50px;height:50px;margin-left:100px"></div></div>`)
	defer fixture_unload(f)
	s := dom.find_by_id(f.doc, "s")
	set_doc_scroll_x(&f.l, 1000)
	r, ok := box_of(&f.l, s, f.vp, 0)
	testing.expect(t, ok)
	testing.expect_value(t, r.border.min.x, 1020)   // left: 20px of what the viewport shows
	set_doc_scroll_x(&f.l, 10)
	r, ok = box_of(&f.l, s, f.vp, 0)
	testing.expect_value(t, r.border.min.x, 100)    // where it is: nothing to stick to yet
}

@(test)
doc_x_transform_rects :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0"><div style="width:3000px;height:10px"></div>
		<div id=m style="position:absolute;left:1000px;top:100px;width:100px;height:100px;transform:translateX(50px)"></div>`)
	defer fixture_unload(f)
	m := dom.find_by_id(f.doc, "m")
	before, _ := box_of(&f.l, m, f.vp, 0)
	set_doc_scroll_x(&f.l, 700)
	after, ok := box_of(&f.l, m, f.vp, 0)
	testing.expect(t, ok && after.transformed)
	testing.expect_value(t, after.bounds, before.bounds)   // document coordinates: the scroll is not in them
	testing.expect_value(t, hit_test(&f.l, {1050 - 700 + 10, 150}, f.vp, 0).node, m)
}

@(test)
doc_x_bars_share_the_corner :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><body style="margin:0"><div style="width:3000px;height:3000px"></div>`)
	defer fixture_unload(f)
	vt, _, vok := doc_scrollbar(&f.l, f.vp, 0)
	ht, ht0, hok := doc_scrollbar_x(&f.l, f.vp)
	testing.expect(t, vok && hok)
	testing.expect(t, vt.max.y <= ht.min.y, "the vertical bar stops above the horizontal one")
	testing.expect(t, ht.max.x <= vt.min.x, "the horizontal bar stops left of the vertical one")
	_, _, rail := classic_parts(ht, false)
	testing.expect_value(t, ht0.min.x, rail.min.x)
	// the thumb follows the offset, to the end of its rail (between the arrows) at the range's end
	set_doc_scroll_x(&f.l, WIDE - VP_W + f.l.doc_bars.x)
	_, ht1, _ := doc_scrollbar_x(&f.l, f.vp)
	testing.expect_value(t, ht1.max.x, rail.max.x)
	testing.expect(t, abs((ht1.max.x - ht1.min.x) - (ht0.max.x - ht0.min.x)) < THUMB_LENGTH_TOLERANCE, "the thumb keeps its length")
	// scrollbar-width: none has neither
	g := hx_load(`<!doctype html><html style="scrollbar-width:none"><body style="margin:0"><div style="width:3000px;height:3000px"></div>`)
	defer fixture_unload(g)
	_, _, hok2 := doc_scrollbar_x(&g.l, g.vp)
	testing.expect(t, !hok2)
}

// A fixed box anchored in the page follows its anchor across as well (anchored_shift), and a pass is due when what it
// chose depends on the scroll.
@(test)
doc_x_anchor :: proc(t: ^testing.T) {
	f := hx_load(`<!doctype html><style>
		body { margin: 0 }
		#a { anchor-name: --a; position: absolute; left: 1000px; top: 50px; width: 30px; height: 30px }
		#q { position: fixed; position-anchor: --a; position-visibility: always; left: anchor(right); top: anchor(top); width: 10px; height: 10px }
		#w { width: 3000px; height: 10px }
	</style><div id=a></div><div id=w></div><div id=q></div>`)
	defer fixture_unload(f)
	q := box_index(&f.l, dom.find_by_id(f.doc, "q"))
	v0 := view_make(&f.l, f.vp, 0, cull = false)
	x0 := item_x_of(&f.l, &v0, q)
	set_doc_scroll_x(&f.l, 300)
	v1 := view_make(&f.l, f.vp, 0, cull = false)
	testing.expect_value(t, item_x_of(&f.l, &v1, q), x0 - 300)
	f.l.anchor_scroll = true
	f.l.anchor_stale = false
	set_doc_scroll_x(&f.l, 300)
	testing.expect(t, !f.l.anchor_stale, "the same offset: no pass")
	set_doc_scroll_x(&f.l, 400)
	testing.expect(t, f.l.anchor_stale, "another offset: a pass")
}
