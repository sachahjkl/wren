package layout

import "core:math"
import "wb:base"
import "wb:css"
import "wb:style"

// Classic scroll bars (layout.scrollbar.overlay off: Chrome and Edge on Windows and Linux). A bar takes its thickness from
// the box it scrolls, between the border and the padding (CSS Overflow 3 §3, the scrollbar gutter: Box.gutter); the
// page's from the viewport: the initial containing block is the window less the page's bars (Layout.doc_bars), while vw
// units and media queries still see the whole window. A bar has an arrow button at each end, as long as the bar is thick.
//   * overflow: scroll has its bar whether its content overflows or not; scrollbar-gutter: stable keeps the vertical
//     bar's room for overflow: hidden and auto too (both-edges: on both sides).
//   * overflow: auto, and the page, show a bar when their content overflows. That is known after a pass, and a bar
//     narrows what it holds, which may then fit: after each pass bars_settle compares what overflows with the bars the
//     pass had, and lays out again what changed (the boxes concerned; the page's content for its own bars). The first
//     comparison of a `run` may add or take away bars, the later ones only add (a bar that made its content fit stays, as
//     in Blink), at most BAR_PASSES_MAX of them: no oscillation.
// Overlay bars take no room: no gutter, no page bar.

// Passes a `run` may add for the bars that came or went.
@(private) BAR_PASSES_MAX :: 3
// How far (device px) content must go past its scroll port for a bar to show (and the box to scroll).
@(private) BAR_MIN_OVERFLOW :: 0.5
// scrollbar-width: thin, for overlay bars: this much of their width.
@(private) OVERLAY_THIN_FACTOR :: 0.5
// Fallback colors of classic bars (the preferences' defaults: Chrome on Windows, light scheme).
@(private) CLASSIC_THUMB :: css.Color{0.757, 0.757, 0.757, 1}
@(private) CLASSIC_TRACK :: css.Color{0.945, 0.945, 0.945, 1}
@(private) CLASSIC_ARROW :: css.Color{0.314, 0.314, 0.314, 1}
// A classic bar's thumb leaves this much of the bar's thickness on each side; its arrow is a triangle this much of it
// high and twice as wide (Chrome on Windows: a 15 px bar, a thumb 2 px in, an arrow 8 px wide and 4 px high).
@(private) CLASSIC_THUMB_INSET :: 0.135
@(private) CLASSIC_ARROW_HEIGHT :: 0.27

// The bars a box shows: X the horizontal one (it scrolls across), Y the vertical one.
Bar_Axis :: enum u8 { X, Y }
Bar_Axes :: bit_set[Bar_Axis; u8]

// Thickness (device px) of the bars of a box, or of the page (the root element's style): the room classic bars take
// (whole pixels), the width overlay bars are drawn with; 0: scrollbar-width: none.
bar_thickness :: proc(set: ^Settings, cs: ^style.Computed, scale: f32) -> f32 {
	sw := cs != nil ? cs.scrollbar_width : .Auto
	if sw == .None { return 0 }
	if set.scrollbar_overlay { return set.scrollbar_width * scale * (sw == .Thin ? OVERLAY_THIN_FACTOR : 1) }
	return math.round((sw == .Thin ? set.classic_thin : set.classic_width) * scale)
}

// Whether box `b` may get a gutter: classic bars, a block-level box that scrolls, or clips with a stable gutter (not the
// one whose overflow went to the viewport). The box models predicted on the layout threads leave these out (parallel.odin).
// A box in a vertical writing mode, or in the frame of one, has none: its bars are drawn over its content (the frames of
// writing modes turn borders and padding, not gutters, between logical and physical sides).
@(private)
may_gutter :: proc(l: ^Layout, b: ^Box) -> bool {
	// (a replaced element has no scroll bars of the page's: a <textarea> counts its own in its natural size)
	if l.settings.scrollbar_overlay || b.kind == .Inline || b.kind == .Replaced || .Propagated in b.flags || b.cs == nil { return false }
	if l.frames_on {
		if p := frame_parent(l, b); is_vert(b.wm) || (p != NONE && is_vert(l.boxes[p].wm)) { return false }
	}
	return .Scroll in b.flags || (.Clips in b.flags && b.cs.scrollbar_gutter != .Auto)
}

// The room of box `b`'s bars (top, right, bottom, left, device px): from its overflow and scrollbar-gutter, and for
// overflow: auto the bars the last pass found it needs (Layout.bars).
@(private)
gutter_of :: proc(c: ^Ctx, b: ^Box) -> (g: [4]f32) {
	if !may_gutter(c.l, b) { return }
	cs := b.cs
	w := bar_thickness(c.set, cs, c.scale)
	if w <= 0 { return }
	shown := c.l.bars[b.node]
	// scrollbar-gutter applies to the boxes that may scroll (overflow hidden, scroll, auto), not to clip
	stable := cs.scrollbar_gutter != .Auto && cs.overflow_y != .Clip && cs.overflow_y != .Visible
	if cs.overflow_y == .Scroll || (cs.overflow_y == .Auto && .Y in shown) || stable { g[1] = w }
	if stable && cs.scrollbar_gutter == .Stable_Both_Edges { g[3] = w }
	if cs.overflow_x == .Scroll || (cs.overflow_x == .Auto && .X in shown) { g[2] = w }
	return
}

// The root element's style (the page's bars follow its scrollbar-width and scrollbar-gutter), nil: none laid out.
@(private)
root_style :: proc(l: ^Layout) -> ^style.Computed {
	if len(l.boxes) == 0 { return nil }
	r := l.boxes[0].first
	return r != NONE ? l.boxes[r].cs : nil
}

// The page's bars for the extent the last pass found: x the vertical bar's width, y the horizontal bar's height.
@(private)
doc_bars_wanted :: proc(l: ^Layout) -> (bars: Vec2) {
	if l.settings.scrollbar_overlay || !l.settings.document_scrollbar || l.doc_bars_off { return }
	cs := root_style(l)
	w := bar_thickness(&l.settings, cs, l.scale)
	// (a viewport too small for a bar's two arrows has none, as in Blink: a tiny frame)
	if w <= 0 || min(l.viewport.x, l.viewport.y) < 2 * w { return }
	stable := cs != nil && cs.scrollbar_gutter != .Auto
	if stable || (l.doc_scroll_y && (l.doc_overflow.y == .Scroll || l.height - l.doc_min_y > l.icb.y + BAR_MIN_OVERFLOW)) { bars.x = w }
	if l.doc_scrollable_x && (l.doc_overflow.x == .Scroll || l.doc_width - l.doc_min_x > l.icb.x + BAR_MIN_OVERFLOW) { bars.y = w }
	return
}

// After a pass: the bars the page and its overflow: auto boxes need for what it found. true: some came or went, and the
// pass must be done again (Layout.doc_bars changed, or the boxes are in Layout.bar_dirty). `may_remove`: the first
// comparison of a run (the later ones only add bars).
@(private)
bars_settle :: proc(l: ^Layout, may_remove: bool) -> bool {
	if !l.valid { return false }
	clear(&l.bar_dirty)
	doc := doc_bars_wanted(l)
	if !may_remove { doc = {max(doc.x, l.doc_bars.x), max(doc.y, l.doc_bars.y)} }
	changed := doc != l.doc_bars
	l.doc_bars = doc
	if l.settings.scrollbar_overlay {
		clear(&l.bars)
		return changed
	}
	for &b, bi in l.boxes {
		if .Scroll not_in b.flags || .Dead in b.flags || !may_gutter(l, &b) { continue }
		if b.cs.overflow_x != .Auto && b.cs.overflow_y != .Auto { continue }
		had := l.bars[b.node]
		need: Bar_Axes
		// (a box of no width or height without its bars shows none, as in Blink: they would only make it grow)
		empty := b.size.x - b.gutter[1] - b.gutter[3] <= 0 || b.size.y - b.gutter[0] - b.gutter[2] <= 0
		if !empty && bar_thickness(&l.settings, b.cs, l.scale) > 0 {
			mn, ms := scroll_limits(&b, l.fin[bi].overflow, padding_rect(&b))
			if b.cs.overflow_x == .Auto && (ms.x > BAR_MIN_OVERFLOW || mn.x < -BAR_MIN_OVERFLOW) { need += {.X} }
			if b.cs.overflow_y == .Auto && (ms.y > BAR_MIN_OVERFLOW || mn.y < -BAR_MIN_OVERFLOW) { need += {.Y} }
		}
		if !may_remove { need += had }
		if need == had { continue }
		if need == {} { delete_key(&l.bars, b.node) } else { l.bars[b.node] = need }
		append(&l.bar_dirty, i32(bi))
		changed = true
	}
	// those of elements that no longer have a box are forgotten
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for node in l.bars { if live_box(l, node) == NONE { append(&gone, node) } }
	for node in gone { delete_key(&l.bars, node) }
	return changed
}

// The page shows no bars, whatever it holds (a frame of scrolling="no"); a change lays it out again.
set_doc_bars_off :: proc(l: ^Layout, off: bool) {
	if l.doc_bars_off == off { return }
	l.doc_bars_off = off
	l.valid = false
}

// The page's scroll port: the viewport less its bars.
doc_port :: #force_inline proc(l: ^Layout, viewport: Vec2) -> Vec2 { return {max(viewport.x - l.doc_bars.x, 0), max(viewport.y - l.doc_bars.y, 0)} }

// The parts of a classic bar whose track is `bar` (the whole bar, viewport or layout coordinates): its arrow buttons at
// the start and at the end, each a square of its thickness, and the rail between them, where the thumb runs. A bar too
// short for both arrows is all rail.
classic_parts :: proc(bar: Rect, vertical: bool) -> (start, end, rail: Rect) {
	ax := vertical ? 1 : 0
	a := bar.max[1 - ax] - bar.min[1 - ax]
	if bar.max[ax] - bar.min[ax] < 2 * a { return {}, {}, bar }
	start, end, rail = bar, bar, bar
	start.max[ax] = bar.min[ax] + a
	end.min[ax] = bar.max[ax] - a
	rail.min[ax], rail.max[ax] = start.max[ax], end.min[ax]
	return
}

// The arrow of a classic bar's button: a triangle pointing toward the start of the bar (up, left) or, `to_end`, its end.
classic_arrow :: proc(button: Rect, vertical, to_end: bool) -> [3]Vec2 {
	ax := vertical ? 1 : 0
	mid := (button.min + button.max) * 0.5
	h := math.round((button.max[1 - ax] - button.min[1 - ax]) * CLASSIC_ARROW_HEIGHT)
	d: f32 = to_end ? 1 : -1
	tip, left, right := mid, mid, mid
	tip[ax] += d * h * 0.5
	left[ax] -= d * h * 0.5
	right[ax] = left[ax]
	left[1 - ax] -= h
	right[1 - ax] += h
	return {tip, left, right}
}

// The thumb of a bar along `rail`: `port` of `port + range` is in view, `t` (0..1) how far it is scrolled.
@(private)
bar_thumb :: proc(l: ^Layout, rail: Rect, vertical: bool, port, range, t: f32) -> Rect {
	ax := vertical ? 1 : 0
	length := rail.max[ax] - rail.min[ax]
	th := min(max(length * port / max(port + range, 1), l.settings.scrollbar_min_thumb * l.scale), length)
	r := rail
	r.min[ax] = rail.min[ax] + (length - th) * clamp(t, 0, 1)
	r.max[ax] = r.min[ax] + th
	if !l.settings.scrollbar_overlay {
		inset := math.round((rail.max[1 - ax] - rail.min[1 - ax]) * CLASSIC_THUMB_INSET)
		r.min[1 - ax] += inset
		r.max[1 - ax] -= inset
	}
	return r
}
