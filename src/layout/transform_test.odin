package layout

import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Transforms in layout: stacking contexts and containing blocks, composed matrices, hit testing through inverses,
// box queries, transformed overflow, rounded clips, and the refresh path for paint-only changes.

@(private = "file")
Tx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	tl:  ^style.Timeline,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
tx_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
tx_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) }
@(private = "file")
tx_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
tx_load :: proc(src: string, vw: f32 = 800, vh: f32 = 600) -> ^Tx {
	f := new(Tx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.tl = style.timeline_make(f.eng)
	style.timeline_restyled(f.tl, f.doc, nil, f.st, 0)
	style.timeline_tick(f.tl, f.doc, f.st, 0)
	f.set = settings_default()
	f.vp = {vw, vh}
	tx_run(f)
	return f
}

@(private = "file")
tx_run :: proc(f: ^Tx) {
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = Text_Api{font = tx_font, width = tx_width, metrics = tx_metrics}, viewport = f.vp, scale = 1, band_h = 256})
}

@(private = "file")
tx_tick :: proc(f: ^Tx, ms: f64) {
	style.timeline_tick(f.tl, f.doc, f.st, ms)
	tx_run(f)
}

@(private = "file")
tx_state :: proc(f: ^Tx, st: style.State, ms: f64) {
	_, ok := style.restyle_state(f.eng, f.doc, f.st, st)
	if !ok {
		old := f.st
		f.st = style.compute_styles(f.eng, f.doc, st)
		style.timeline_restyled(f.tl, f.doc, old, f.st, ms)
		style.styled_destroy(old)
	} else {
		style.timeline_restyled_partial(f.tl, f.doc, f.st, ms)
	}
	tx_tick(f, ms)
}

@(private = "file")
tx_unload :: proc(f: ^Tx) {
	destroy(&f.l)
	style.timeline_destroy(f.tl, f.st)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
el :: proc(f: ^Tx, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

@(private = "file")
bx :: proc(f: ^Tx, id: string) -> ^Box {
	bi := box_index(&f.l, el(f, id))
	return bi == NONE ? nil : &f.l.boxes[bi]
}

@(private = "file")
hit :: proc(f: ^Tx, x, y: f32) -> base.Handle { return hit_test(&f.l, {x, y}, f.vp, 0).node }

@(private = "file")
close :: proc(a, b: Vec2, eps: f32 = 0.05) -> bool { return math.abs(a.x - b.x) <= eps && math.abs(a.y - b.y) <= eps }

@(test)
transform_stacking_and_containing_block :: proc(t: ^testing.T) {
	f := tx_load(`<body style="margin:0">
<div id=t style="transform:translate(10px,0);margin-top:50px;height:100px">
  <div id=a style="position:absolute;left:5px;top:5px;width:10px;height:10px"></div>
  <div id=x style="position:fixed;left:0;top:0;width:10px;height:10px"></div>
</div>
<div id=y style="position:fixed;left:0;top:0;width:10px;height:10px"></div>
</body>`)
	defer tx_unload(f)
	tb, ab, xb, yb := bx(f, "t"), bx(f, "a"), bx(f, "x"), bx(f, "y")
	testing.expect(t, tb != nil && ab != nil && xb != nil && yb != nil)
	testing.expect(t, .Transformed in tb.flags && .Stacking in tb.flags, "a transform makes a stacking context")
	ti := box_index(&f.l, el(f, "t"))
	testing.expect(t, ab.cb == ti, "the transformed box contains its absolutely positioned descendants")
	testing.expect(t, xb.cb == ti && .Fixed not_in xb.flags, "... and its fixed ones, which no longer stick to the viewport")
	testing.expect(t, .Fixed in yb.flags && yb.cb == 0, "a fixed box outside stays fixed")
	ra, _ := box_of(&f.l, el(f, "a"), f.vp, 0)
	testing.expectf(t, close(ra.border.min, {5, 55}), "absolute box laid out in the transformed box: %v", ra.border.min)
	testing.expectf(t, ra.transformed && close(ra.bounds.min, {15, 55}), "and drawn with its transform: %v", ra.bounds.min)
	rx, _ := box_of(&f.l, el(f, "x"), f.vp, 0)
	testing.expectf(t, close(rx.bounds.min, {10, 50}), "fixed box inside the transformed box: %v", rx.bounds.min)
	ry, _ := box_of(&f.l, el(f, "y"), f.vp, 300)
	testing.expectf(t, ry.fixed && !ry.transformed, "fixed box outside: %v", ry)
	testing.expect(t, hit(f, 22, 62) == el(f, "a"), "hit through the translation")
	testing.expect(t, hit(f, 12, 62) != el(f, "a"), "the untransformed place is not it")
	testing.expect(t, hit(f, 12, 52) == el(f, "x"), "the fixed box moved with its transformed containing block")
}

@(test)
transform_nested_matrices :: proc(t: ^testing.T) {
	// outer: 100x100 at (0,0), rotate(90deg) around its center (50% 50%): (x, y) -> (100 - y, x)
	// inner: 20x20 at (0,0), translate(50%) = 10px, around its own top-left corner
	f := tx_load(`<body style="margin:0">
<div id=o style="width:100px;height:100px;transform:rotate(90deg);transform-origin:50% 50%">
  <div id=i style="width:20px;height:20px;transform:translateX(50%);transform-origin:0 0"></div>
</div></body>`)
	defer tx_unload(f)
	r, ok := box_of(&f.l, el(f, "i"), f.vp, 0)
	testing.expect(t, ok && r.transformed)
	testing.expectf(t, close(r.quad[0], {100, 10}), "inner top-left: %v", r.quad[0])
	testing.expectf(t, close(r.quad[2], {80, 30}), "inner bottom-right: %v", r.quad[2])
	testing.expect(t, hit(f, 90, 20) == el(f, "i"), "the inner box where it shows")
	testing.expect(t, hit(f, 5, 5) != el(f, "i") , "not where it is laid out")
	// scrolled document: the matrices follow
	r2, _ := box_of(&f.l, el(f, "i"), f.vp, 0)
	testing.expect(t, close(r2.quad[0], r.quad[0]))
}

@(test)
transform_hit_rotated_45 :: proc(t: ^testing.T) {
	f := tx_load(`<body style="margin:0"><div id=r style="position:absolute;left:100px;top:100px;width:100px;height:100px;transform:rotate(45deg);background:red"></div></body>`)
	defer tx_unload(f)
	r := el(f, "r")
	testing.expect(t, hit(f, 150, 150) == r, "center")
	testing.expect(t, hit(f, 105, 105) != r, "inside the bounding box and the untransformed square, outside the diamond")
	testing.expect(t, hit(f, 150, 85) == r, "outside the untransformed square, inside the diamond")
	testing.expect(t, hit(f, 215, 150) == r, "near the right vertex")
	testing.expect(t, hit(f, 222, 150) != r, "past the right vertex")
	b, ok := box_of(&f.l, r, f.vp, 0)
	testing.expect(t, ok && b.transformed)
	d := f32(50 * math.SQRT_TWO)
	testing.expectf(t, close(b.bounds.min, {150 - d, 150 - d}, 0.1) && close(b.bounds.max, {150 + d, 150 + d}, 0.1), "bounds %v", b.bounds)
	testing.expectf(t, close(b.border.min, {100, 100}), "local rect stays the layout rect: %v", b.border)
	p := box_point_to_local(b, {150, 150 - d + 1})   // just below the top vertex
	// the top vertex is the top-left corner turned 45 degrees clockwise
	testing.expectf(t, close(p, {100.7, 100.7}, 0.2) && rect_contains(b.border, p), "point to local %v", p)
}

@(test)
transform_overflow_and_rounded_clip :: proc(t: ^testing.T) {
	f := tx_load(`<body style="margin:0">
<div id=sc style="overflow:auto;width:100px;height:100px"><div style="width:50px;height:50px;transform:translateY(200px)"></div></div>
<div id=rc style="overflow:hidden;width:100px;height:100px;border-radius:50px"><div id=fill style="width:100px;height:100px"></div></div>
</body>`)
	defer tx_unload(f)
	m, ok := scroll_max(&f.l, el(f, "sc"))
	testing.expectf(t, ok && math.abs(m.y - 150) < 0.5, "transformed overflow scrolls: %v %v", ok, m)
	testing.expect(t, hit(f, 50, 150) == el(f, "fill"), "inside the rounded clip")
	testing.expect(t, hit(f, 3, 103) != el(f, "fill"), "the corner is clipped away")
	cb := bx(f, "rc")
	testing.expect(t, cb != nil && f.l.clips[cb.content_clip].radii[0] == 50, "clip radii")
}

@(test)
transform_wheel_on_rotated_scroller :: proc(t: ^testing.T) {
	f := tx_load(`<body style="margin:0"><div id=rs style="position:absolute;left:200px;top:0;width:100px;height:100px;overflow:auto;transform:rotate(90deg)">
<div style="height:400px"></div><div id=end style="height:10px"></div></div></body>`)
	defer tx_unload(f)
	// rotated around its center (250, 50): the box still covers 200..300 x 0..100
	testing.expect(t, scroll_wheel(&f.l, {250, 50}, {0, 40}, f.vp, 0), "the wheel over the rotated scroller scrolls it")
	off, _ := scroll_of(&f.l, el(f, "rs"))
	testing.expectf(t, math.abs(off.y - 40) < 0.01, "scrolled by 40: %v", off)
	testing.expect(t, !scroll_wheel(&f.l, {150, 50}, {0, 40}, f.vp, 0), "nothing scrollable elsewhere")
}

@(test)
transform_refresh_path :: proc(t: ^testing.T) {
	f := tx_load(`<style>
@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }
@keyframes grow { from { width: 10px } to { width: 110px } }
#s { animation: spin 1s linear infinite; width: 50px; height: 50px }
#h:hover { background-color: red; outline-color: blue }
#w:hover { width: 300px }
#u { text-decoration: underline; color: red } #u:hover { color: blue }
</style><body style="margin:0"><div id=s></div><div id=h style="height:10px">h</div><div id=w style="height:10px"></div><div id=g></div><p><span id=u>link</span></p></body>`)
	defer tx_unload(f)
	full := f.l.passes[.Full]
	tx_tick(f, 250)
	testing.expectf(t, f.l.last_pass == .Refresh && f.l.passes[.Full] == full, "a transform animation does not lay out: %v", f.l.last_pass)
	sb := bx(f, "s")
	sp := &f.l.spaces[sb.space]
	testing.expect(t, sp.kind == .Transform && math.abs(sp.mat[0]) < 0.01 && math.abs(sp.mat[1] - 1) < 0.01, "quarter turn after 250 ms")
	testing.expect(t, sb.cs == style.style_of(f.st, el(f, "s")), "boxes see the animated style")
	r, _ := box_of(&f.l, el(f, "s"), f.vp, 0)
	testing.expect(t, close(r.quad[0], {50, 0}), "the box turned")
	tx_tick(f, 500)
	testing.expect(t, f.l.last_pass == .Refresh)

	// hover with paint-only effects: refreshed; with a size change: laid out
	tx_state(f, style.State{hover = el(f, "h")}, 600)
	testing.expectf(t, f.l.last_pass == .Refresh, "paint-only hover refreshes: %v", f.l.last_pass)
	testing.expect(t, bx(f, "h").cs.background_color.r > 0.9, "the new background is seen")
	found := false
	for &it in f.l.items { if it.node == el(f, "h") && it.kind == .Box { found = it.cs.background_color.r > 0.9 } }
	testing.expect(t, found, "display items see it too")
	tx_state(f, style.State{hover = el(f, "u")}, 650)
	testing.expectf(t, f.l.last_pass == .Refresh, "a color change of underlined text refreshes: %v", f.l.last_pass)
	blue := false
	for &it in f.l.items { if it.kind == .Text && it.node == el(f, "u") { blue = it.deco_color.b > 0.9 && it.cs.color.b > 0.9 } }
	testing.expect(t, blue, "text and underline take the new color")
	full = f.l.passes[.Full]
	tx_state(f, style.State{hover = el(f, "w")}, 700)
	testing.expect(t, f.l.last_pass == .Full && f.l.passes[.Full] == full + 1, "a hover that changes a size lays out")
	testing.expect(t, math.abs(bx(f, "w").size.x - 300) < 0.01)

	// a layout-tier animation lays out at every change
	_ = dom.set_attribute(f.doc, el(f, "g"), "style", "animation: grow 1s linear")
	old := f.st
	f.st = style.compute_styles(f.eng, f.doc, {})
	style.timeline_restyled(f.tl, f.doc, old, f.st, 800)
	style.styled_destroy(old)
	tx_tick(f, 800)
	tx_tick(f, 900)
	testing.expect(t, f.l.last_pass == .Full, "a width animation lays out")

	// the preference turns the refresh path off
	f.set.paint_refresh = false
	tx_tick(f, 950)
	f.set.paint_refresh = true
	testing.expect(t, f.l.last_pass == .Full)
}
