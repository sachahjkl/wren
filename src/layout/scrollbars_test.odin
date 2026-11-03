package layout

import "core:testing"
import "wb:dom"
import "wb:style"

// Classic scroll bars take room (scrollbars.odin): the page's from the viewport, a box's from its own border box; overlay
// bars take none.

@(private = "file") SB_W :: 800
@(private = "file") SB_H :: 600
@(private = "file") BOX_W :: 300
@(private = "file") BOX_BORDER :: 1
@(private = "file") TALL :: `<div style="height:2000px"></div>`

@(private = "file")
sb_load :: proc(src: string, overlay := false) -> ^Fixture {
	set := settings_default()
	set.scrollbar_overlay = overlay
	return fixture_load(src, SB_W, SB_H, {set = &set, band_h = FIXTURE_NARROW_BAND_H, journal = true, inc_verify = true})
}

// The document's styles again after a change, the style journal saying what changed (an incremental pass follows it).
@(private = "file")
restyle :: proc(f: ^Fixture) {
	old := f.st
	f.st = style.compute_styles(f.eng, f.doc, {})
	style.journal_diff(old, f.st)
	style.styled_destroy(old)
}

// The page's classic bar thickness at the fixture's scale (1).
@(private = "file")
bar :: proc(f: ^Fixture) -> f32 { return f.set.classic_width }

@(private = "file")
rects :: proc(f: ^Fixture, id: string) -> Box_Rects {
	r, _ := box_of(&f.l, dom.find_by_id(f.doc, id), f.vp, 0)
	return r
}

@(private = "file")
gutter :: proc(f: ^Fixture, id: string) -> [4]f32 { return f.l.boxes[box_index(&f.l, dom.find_by_id(f.doc, id))].gutter }

// A page taller than the window: its vertical bar takes its width from the initial containing block, a full-width
// footer ends at the bar, and the bar runs from the top to the bottom of the window at its right edge.
@(test)
page_bar_takes_room :: proc(t: ^testing.T) {
	f := sb_load(`<!doctype html><body style="margin:0">` + TALL + `<footer id=foot style="height:40px"></footer>`)
	defer fixture_unload(f)
	testing.expect_value(t, f.l.doc_bars, Vec2{bar(f), 0})
	testing.expect_value(t, rects(f, "foot").border.max.x, SB_W - bar(f))
	track, thumb, ok := doc_scrollbar(&f.l, f.vp, 0)
	testing.expect(t, ok && thumb != {}, "a bar with a thumb")
	testing.expect_value(t, track, Rect{{SB_W - bar(f), 0}, {SB_W, SB_H}})
	// its arrows at the ends, the thumb between them
	start, end, rail := classic_parts(track, true)
	testing.expect_value(t, start.max.y - start.min.y, bar(f))
	testing.expect_value(t, end.max.y, f32(SB_H))
	testing.expect(t, thumb.min.y >= rail.min.y && thumb.max.y <= rail.max.y, "the thumb on the rail")
	// the page scrolls by what it is taller than the window
	_, hi := doc_scroll_y_range(&f.l, f.vp.y)
	testing.expect_value(t, hi, f.l.height - SB_H)

	// a page that fits has none
	g := sb_load(`<!doctype html><body style="margin:0"><footer id=foot style="height:40px"></footer>`)
	defer fixture_unload(g)
	testing.expect_value(t, g.l.doc_bars, Vec2{})
	testing.expect_value(t, rects(g, "foot").border.max.x, SB_W)
	_, _, shown := doc_scrollbar(&g.l, g.vp, 0)
	testing.expect(t, !shown)
}

// The page grows past the window and shrinks back: the bar comes and goes with it, partial passes as full ones.
@(test)
page_bar_follows_the_content :: proc(t: ^testing.T) {
	f := sb_load(`<!doctype html><body style="margin:0"><div id=grow style="height:100px"></div><div id=w></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, f.l.doc_bars.x, 0)
	grow := dom.find_by_id(f.doc, "grow")
	for step in ([]struct { style: string, bar: bool }{{"height:2000px", true}, {"height:100px", false}}) {
		dom.set_attribute(f.doc, grow, "style", step.style)
		restyle(f)
		fixture_run(f)
		testing.expectf(t, (f.l.doc_bars.x > 0) == step.bar, "%s: bars %v", step.style, f.l.doc_bars)
		testing.expect_value(t, rects(f, "w").border.max.x, SB_W - f.l.doc_bars.x)
		testing.expect_value(t, f.l.inc.verify_failures, 0)
	}
}

// overflow: scroll on the page: its bar shows with nothing to scroll (no thumb); scrollbar-width: none and overlay bars take no room.
@(test)
page_bar_scroll_none_overlay :: proc(t: ^testing.T) {
	f := sb_load(`<!doctype html><html style="overflow-y:scroll"><body style="margin:0"><div id=w></div>`)
	defer fixture_unload(f)
	testing.expect_value(t, f.l.doc_bars.x, bar(f))
	_, thumb, ok := doc_scrollbar(&f.l, f.vp, 0)
	testing.expect(t, ok && thumb == {}, "a bar without a thumb")
	testing.expect_value(t, rects(f, "w").border.max.x, SB_W - bar(f))

	n := sb_load(`<!doctype html><html style="scrollbar-width:none"><body style="margin:0"><div id=w></div>` + TALL)
	defer fixture_unload(n)
	testing.expect_value(t, n.l.doc_bars, Vec2{})
	testing.expect_value(t, rects(n, "w").border.max.x, SB_W)
	_, hi := doc_scroll_y_range(&n.l, n.vp.y)
	testing.expect(t, hi > 0, "it still scrolls")
	// a viewport too small for a bar's arrows (a tiny frame): none
	tiny_w, tiny_h := f.set.classic_width, f.set.classic_width   // (less than two arrows long either way)
	tiny := fixture_load(`<!doctype html><body style="margin:0">` + TALL, tiny_w, tiny_h, {set = &f.set})
	defer fixture_unload(tiny)
	testing.expect_value(t, tiny.l.doc_bars, Vec2{})
	// a frame of scrolling="no" (the embedder says): none
	set_doc_bars_off(&f.l, true)
	fixture_run(f)
	testing.expect_value(t, f.l.doc_bars, Vec2{})
	testing.expect_value(t, rects(f, "w").border.max.x, SB_W)

	o := sb_load(`<!doctype html><body style="margin:0"><div id=w></div>` + TALL, overlay = true)
	defer fixture_unload(o)
	testing.expect_value(t, o.l.doc_bars, Vec2{})
	testing.expect_value(t, rects(o, "w").border.max.x, SB_W)
	track, _, shown := doc_scrollbar(&o.l, o.vp, 0)
	testing.expect(t, shown && track.max.x < SB_W, "an overlay bar over the page, short of its edge")
}

// A box that scrolls: its bars take their room inside its border box (a specified width keeps its border box), its
// client width is less the bar; with both, the corner is theirs. Overlay bars take none.
@(test)
box_bars_take_room :: proc(t: ^testing.T) {
	src := `<!doctype html><style>div.b{width:300px;height:100px;border:1px solid} .in{height:400px;width:100%}</style><body style="margin:0">
<div class=b id=both style="overflow:scroll"><div class=in id=in1></div></div>
<div class=b id=auto style="overflow:auto"><div class=in id=in2></div></div>
<div class=b id=fits style="overflow:auto"><div id=in3 style="height:10px"></div></div>
<div class=b id=thin style="overflow-y:scroll;scrollbar-width:thin"></div>
<div class=b id=none style="overflow:auto;scrollbar-width:none"><div class=in id=in4></div></div>`
	f := sb_load(src)
	defer fixture_unload(f)
	w := bar(f)
	both := rects(f, "both")
	testing.expect_value(t, both.border.max.x - both.border.min.x, BOX_W + 2 * BOX_BORDER)
	testing.expect_value(t, both.padding.max.x - both.padding.min.x, BOX_W - w)   // clientWidth
	testing.expect_value(t, gutter(f, "both"), [4]f32{0, w, w, 0})
	testing.expect_value(t, rects(f, "in1").border.max.x - rects(f, "in1").border.min.x, BOX_W - w)
	// overflow: auto: a bar for the axis that overflows only
	testing.expect_value(t, gutter(f, "auto"), [4]f32{0, w, 0, 0})
	testing.expect_value(t, rects(f, "in2").border.max.x - rects(f, "in2").border.min.x, BOX_W - w)
	testing.expect_value(t, gutter(f, "fits"), [4]f32{})
	testing.expect_value(t, gutter(f, "thin"), [4]f32{0, f.set.classic_thin, 0, 0})
	testing.expect_value(t, gutter(f, "none"), [4]f32{})
	// the bars as display items: in the gutter, the vertical one of `both` stopping at the corner
	bi := box_index(&f.l, dom.find_by_id(f.doc, "both"))
	pad := padding_rect(&f.l.boxes[bi])
	found := 0
	for &it in f.l.items {
		if it.kind != .Scrollbar || it.box != bi { continue }
		found += 1
		want := .Vertical in it.flags ? Rect{{pad.max.x, pad.min.y}, {pad.max.x + w, pad.max.y}} : Rect{{pad.min.x, pad.max.y}, {pad.max.x, pad.max.y + w}}
		testing.expect_value(t, it.rect, want)
	}
	testing.expect_value(t, found, 2)

	o := sb_load(src, overlay = true)
	defer fixture_unload(o)
	testing.expect_value(t, gutter(o, "both"), [4]f32{})
	ob := rects(o, "both")
	testing.expect_value(t, ob.padding.max.x - ob.padding.min.x, BOX_W)
}

// scrollbar-gutter: stable keeps the vertical bar's room before there is anything to scroll (overflow auto and hidden,
// not visible); both-edges on both sides.
@(test)
box_scrollbar_gutter :: proc(t: ^testing.T) {
	f := sb_load(`<!doctype html><style>body>div{width:300px;height:100px}</style><body style="margin:0">
<div id=st style="overflow:auto;scrollbar-gutter:stable"></div>
<div id=hid style="overflow:hidden;scrollbar-gutter:stable"></div>
<div id=both style="overflow:auto;scrollbar-gutter:stable both-edges"><div id=in style="height:10px"></div></div>
<div id=vis style="scrollbar-gutter:stable"></div>`)
	defer fixture_unload(f)
	w := bar(f)
	testing.expect_value(t, gutter(f, "st"), [4]f32{0, w, 0, 0})
	testing.expect_value(t, gutter(f, "hid"), [4]f32{0, w, 0, 0})
	testing.expect_value(t, gutter(f, "both"), [4]f32{0, w, 0, w})
	testing.expect_value(t, rects(f, "in").border.min.x, w)
	testing.expect_value(t, rects(f, "in").border.max.x, BOX_W - w)
	testing.expect_value(t, gutter(f, "vis"), [4]f32{})
	// a stable gutter shows no bar while there is nothing to scroll
	for &it in f.l.items { testing.expect(t, it.kind != .Scrollbar, "no bar drawn") }
}

// A bar that makes its content fit (content that narrows with it and gets shorter: an aspect ratio): it stays, after a
// bounded number of passes, and the next run keeps it.
@(test)
box_bar_without_oscillation :: proc(t: ^testing.T) {
	f := sb_load(`<!doctype html><body style="margin:0">
<div id=sc style="overflow:auto;width:200px;height:200px"><div id=sq style="width:100%;aspect-ratio:1/1;margin-bottom:5px"></div></div>`)
	defer fixture_unload(f)
	passes :: proc(l: ^Layout) -> u64 { return l.passes[.Full] + l.passes[.Incremental] }
	testing.expect_value(t, gutter(f, "sc")[1], bar(f))
	for _ in 0 ..< 2 {
		before := passes(&f.l)
		f.l.valid = false
		fixture_run(f)
		testing.expect(t, passes(&f.l) - before <= 1 + BAR_PASSES_MAX, "bounded passes")
		testing.expect_value(t, gutter(f, "sc")[1], bar(f))
		testing.expect_value(t, f.l.inc.verify_failures, 0)
	}
}
