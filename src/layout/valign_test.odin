package layout

import "core:math"
import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:style"

// Vertical metrics as Chromium uses them, with faces of known metrics at a device scale of 1.75 (175 %): ascent,
// descent and line gap rounded one by one (line-height: normal is their sum), the top half-leading floored, middle /
// text-top / text-bottom with the leading, sub / super, fallback faces in line-height: normal, the line height quirk,
// flex containers sized by min-height, buttons and table cells centering their content, form control baselines and
// whole-pixel border spacing. The expected values were measured in Edge (tools\compare_edge.ps1, getBoundingClientRect
// of the same pages) with Arial, whose metrics the "main" face copies: ascent 1854, descent 434, line gap 67, x-height
// 1062 of 2048 units.

@(private = "file")
Vx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file") MAIN :: Font(1)
@(private = "file") TALL :: Font(2)   // what the fallback of a non-ASCII character comes from (Segoe UI's metrics)

@(private = "file")
vx_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font {
	for f in families { if f == "tall" || f == "Tall" { return TALL } }
	return MAIN
}

@(private = "file")
vx_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }

@(private = "file")
face_metrics :: proc(f: Font, size: f32) -> Font_Metrics {
	if f == TALL {
		m := Font_Metrics{ascent = size * 2210 / 2048, descent = size * 514 / 2048, x_height = size * 1118 / 2048}
		m.line_height = math.round(m.ascent + m.descent)
		return m
	}
	m := Font_Metrics{ascent = size * 1854 / 2048, descent = size * 434 / 2048, line_gap = size * 67 / 2048, x_height = size * 1062 / 2048}
	m.line_height = math.round(m.ascent + m.descent + m.line_gap)
	return m
}

@(private = "file")
vx_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return face_metrics(f, size) }

// Text with a character past U+00FF falls back to the tall face.
@(private = "file")
vx_fallback :: proc(user: rawptr, f: Font, size: f32, text: string, out: []Font_Metrics) -> int {
	if f == TALL || len(out) == 0 { return 0 }
	for r in text {
		if r > 0xFF { out[0] = face_metrics(TALL, size); return 1 }
	}
	return 0
}

@(private = "file")
vx_api :: Text_Api{font = vx_font, width = vx_width, metrics = vx_metrics, fallback_metrics = vx_fallback}

@(private = "file")
vx_load :: proc(src: string, round := true) -> ^Vx {
	f := new(Vx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = settings_default()
	f.set.round_metrics = round
	f.vp = {1400, 1000}
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = vx_api, viewport = f.vp, scale = 1.75, band_h = 256})
	return f
}

@(private = "file")
vx_unload :: proc(f: ^Vx) {
	destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
vx_rect :: proc(f: ^Vx, id: string) -> Rect {
	r, ok := box_of(&f.l, dom.find_by_id(f.doc, id), f.vp, 0)
	if !ok { return Rect{{-1, -1}, {-1, -1}} }
	return r.border
}

// Top and bottom of element `id` from the top of `case_id` (device px).
@(private = "file")
expect_y :: proc(t: ^testing.T, f: ^Vx, case_id, id: string, top, bottom: f32, loc := #caller_location) {
	c := vx_rect(f, case_id)
	r := vx_rect(f, id)
	ok := math.abs(r.min.y - c.min.y - top) < 0.01 && math.abs(r.max.y - c.min.y - bottom) < 0.01
	testing.expectf(t, ok, "%s: %v..%v, want %v..%v", id, r.min.y - c.min.y, r.max.y - c.min.y, top, bottom, loc = loc)
}

@(test)
line_metrics_rounded :: proc(t: ^testing.T) {
	f := vx_load(`<!doctype html><body style="margin:0;font:16px main">
<div id=a><span id=a_s>Hxg</span><i id=a_b style="display:inline-block"></i></div>
<div id=b style="font-size:32px"><span id=b_s>Hxg</span><i id=b_b style="display:inline-block"></i></div>
<div id=c style="line-height:33px"><span id=c_s>Hxg</span><i id=c_b style="display:inline-block"></i></div>
<div id=d style="line-height:1.5;font-size:13px"><span id=d_s>Hxg</span><i id=d_b style="display:inline-block"></i></div>
<div id=e>x<span id=e_s style="font-size:12px">yg</span><i id=e_b style="display:inline-block"></i></div>
</body>`)
	defer vx_unload(f)
	// 28 px: ascent 25.35 -> 25, descent 5.93 -> 6, gap 0.92 -> 1: a 32 px line, the odd pixel below
	expect_y(t, f, "a", "a", 0, 32)
	expect_y(t, f, "a", "a_s", 0, 31)
	expect_y(t, f, "a", "a_b", 25, 25)
	// 56 px: 51 + 12 + 2 = 65 (the exact sum, 64.4, would round to 64); 1 of the 2 px of leading above
	expect_y(t, f, "b", "b", 0, 65)
	expect_y(t, f, "b", "b_b", 52, 52)
	// 33 px = 57.75 device px around 31 px of text: 26.75 of leading, floor(13.375) = 13 above
	expect_y(t, f, "c", "c", 0, 57.75)
	expect_y(t, f, "c", "c_b", 13 + 25, 13 + 25)
	// 13 px at 1.5: 22.75 px, line 34.125 around 21 + 5: floor(4.0625) = 4 above
	expect_y(t, f, "d", "d", 0, 34.125)
	expect_y(t, f, "d", "d_b", 4 + 21, 4 + 21)
	// a 12 px span (19 + 4, gap 1: 24) on the 16 px line: its baseline is the line's
	expect_y(t, f, "e", "e_s", 25 - 19, 25 + 4)
}

@(test)
line_metrics_exact_without_rounding :: proc(t: ^testing.T) {
	f := vx_load(`<!doctype html><body style="margin:0;font:32px main"><div id=a>Hxg<i id=a_b style="display:inline-block"></i></div></body>`, round = false)
	defer vx_unload(f)
	asc, desc, gap := f32(56) * 1854 / 2048, f32(56) * 434 / 2048, f32(56) * 67 / 2048
	lh := math.round(asc + desc + gap)
	expect_y(t, f, "a", "a", 0, lh)
	expect_y(t, f, "a", "a_b", (lh - asc - desc) * 0.5 + asc, (lh - asc - desc) * 0.5 + asc)
}

@(test)
vertical_align_with_leading :: proc(t: ^testing.T) {
	f := vx_load(`<!doctype html><body style="margin:0;font:16px main">
<div id=m>x<span id=m_s style="font-size:12px;vertical-align:middle">yg</span></div>
<div id=tt>x<span id=tt_s style="font-size:12px;vertical-align:text-top">yg</span></div>
<div id=tb>x<span id=tb_s style="font-size:12px;vertical-align:text-bottom">yg</span></div>
<div id=sb>x<span id=sb_s style="font-size:12px;vertical-align:sub">yg</span></div>
<div id=sp>x<span id=sp_s style="font-size:12px;vertical-align:super">yg</span><i id=sp_b style="display:inline-block"></i></div>
<div id=em>x<span id=em_s style="display:inline-block;width:10px;height:10px;vertical-align:middle"></span></div>
</body>`)
	defer vx_unload(f)
	// the span: 19 + 4, line gap 1 (0 above, 1 below); the parent's x-height 14.52
	xh := f32(28) * 1062 / 2048
	// middle: the leading-inclusive box (19 above, 5 below) centered at x-height / 2 above the baseline
	shift := -xh * 0.5 + (19 - 5) * 0.5
	expect_y(t, f, "m", "m_s", 25 + shift - 19, 25 + shift + 4)
	// text-top: the box's top (with its leading) at the parent's ascent; text-bottom: its bottom at the descent
	expect_y(t, f, "tt", "tt_s", 0, 23)
	expect_y(t, f, "tb", "tb_s", 25 + 6 - 5 - 19, 25 + 6 - 5 + 4)
	// sub: a fifth of the parent's 28 px + 1 = 6.6 lower; super: a third + 1 = 10.33 higher (the line grows)
	expect_y(t, f, "sb", "sb_s", 25 + 6.6 - 19, 25 + 6.6 + 4)
	sup := f32(28) / 3 + 1
	expect_y(t, f, "sp", "sp_s", 0, 23)
	expect_y(t, f, "sp", "sp_b", 19 + sup, 19 + sup)
	// an inline-block (17.5 px) centered at baseline - x-height / 2
	mid := 25 - xh * 0.5
	expect_y(t, f, "em", "em_s", mid - 8.75, mid + 8.75)
}

@(test)
fallback_faces_in_normal_line_height :: proc(t: ^testing.T) {
	f := vx_load(`<!doctype html><body style="margin:0;font:16px main">
<div id=a>Text &#x263A; face<i id=a_b style="display:inline-block"></i></div>
<div id=b style="line-height:1.5">Text &#x263A; face<i id=b_b style="display:inline-block"></i></div>
<div id=c>ASCII only<i id=c_b style="display:inline-block"></i></div>
</body>`)
	defer vx_unload(f)
	// the tall face at 28 px: 30 + 7, no gap: it raises the line (30 above the baseline) and holds 7 below
	expect_y(t, f, "a", "a", 0, 37)
	expect_y(t, f, "a", "a_b", 30, 30)
	// a numeric line-height: the first face only
	expect_y(t, f, "b", "b", 0, 42)
	expect_y(t, f, "c", "c", 0, 32)
}

@(test)
line_height_quirk :: proc(t: ^testing.T) {
	src :: `<body style="margin:0;font:16px main">
<div id=a><img id=a_i style="width:20px;height:20px"></div>
<div id=b style="line-height:40px"><span><img id=b_i style="width:20px;height:20px"></span></div>
<div id=c>text<img id=c_i style="width:20px;height:20px"></div>
<div id=d><span id=d_s style="line-height:12px">in a span</span></div>
<div id=e><br></div>
</body>`
	q := vx_load(src)
	defer vx_unload(q)
	// quirks mode: no strut without text in the root inline box; an inline box only counts through its text
	expect_y(t, q, "a", "a", 0, 35)
	expect_y(t, q, "b", "b", 0, 35)
	expect_y(t, q, "c", "c", 0, 35 + 7)
	expect_y(t, q, "d", "d", 0, 21)
	expect_y(t, q, "e", "e", 0, 32)
	s := vx_load(`<!doctype html>` + src)
	defer vx_unload(s)
	expect_y(t, s, "a", "a", 0, 35 + 7)
	expect_y(t, s, "b", "b", 0, 70)
	limited := vx_load(`<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">` + src)
	defer vx_unload(limited)
	expect_y(t, limited, "a", "a", 0, 35)
}

@(test)
flex_min_height_centers :: proc(t: ^testing.T) {
	f := vx_load(`<!doctype html><body style="margin:0;font:16px main">
<div id=a style="display:flex;align-items:center;min-height:32px"><span id=a_s>min</span></div>
<div id=b style="display:flex;flex-wrap:wrap;align-items:center;align-content:center;min-height:40px"><span id=b_s>wrap</span></div>
<div id=c style="display:flex;flex-direction:column;justify-content:center;min-height:40px"><span id=c_s>col</span></div>
<div id=d style="display:flex;flex-direction:column;min-height:40px"><span id=d_s style="flex:1">grow</span></div>
<div id=e style="display:flex;align-items:center;max-height:10px"><span id=e_s>max</span></div>
</body>`)
	defer vx_unload(f)
	expect_y(t, f, "a", "a", 0, 56)
	expect_y(t, f, "a", "a_s", 12, 44)
	expect_y(t, f, "b", "b_s", 19, 51)
	expect_y(t, f, "c", "c_s", 19, 51)
	expect_y(t, f, "d", "d_s", 0, 70)
	// max-height: the line is 17.5 px, the item overflows it centered
	expect_y(t, f, "e", "e", 0, 17.5)
	expect_y(t, f, "e", "e_s", (17.5 - 32) * 0.5, (17.5 - 32) * 0.5 + 32)
}

@(test)
buttons_cells_controls :: proc(t: ^testing.T) {
	f := vx_load(`<!doctype html><body style="margin:0;font:16px main">
<div id=a>x<button id=a_s style="height:40px;font:16px main;padding:0;border:0">Go</button><i id=a_b style="display:inline-block"></i></div>
<div id=b><table style="border-collapse:collapse"><tr><td id=b_d style="height:40px;padding:0"><span id=b_s>cell</span></td></tr></table></div>
<div id=c>x<input id=c_s value=abc style="font:16px main;padding:0;border:0;height:40px"><i id=c_b style="display:inline-block"></i></div>
<div id=d>x<input type=checkbox id=d_s><i id=d_b style="display:inline-block"></i></div>
<div id=e><table id=e_t><tr><td id=e_d style="padding:0">x</td></tr></table></div>
</body>`)
	defer vx_unload(f)
	// the button's 32 px line centered in 70: 19 above; its baseline 19 + 25 is the line's
	expect_y(t, f, "a", "a_b", 19 + 25, 19 + 25)
	// the cell's content (a 32 px line) centered in its specified 70; the span is the 31 px of text in it
	expect_y(t, f, "b_d", "b_s", 19, 50)
	// a text field: its line of text centered in the content box, the baseline on the line's
	expect_y(t, f, "c", "c_b", 19 + 25, 19 + 25)
	// a check box sits on its bottom border edge (13 px + its 3 px top margin above the baseline)
	cb := vx_rect(f, "d_s")
	bl := vx_rect(f, "d_b")
	testing.expectf(t, math.abs(cb.max.y - bl.min.y) < 0.01, "checkbox bottom %v on the baseline %v", cb.max.y, bl.min.y)
	// border-spacing: the UA's 2 px is 3 device px at 175 %, not 3.5
	tbl, cell := vx_rect(f, "e_t"), vx_rect(f, "e_d")
	testing.expectf(t, math.abs(cell.min.y - tbl.min.y - 3) < 0.01, "border spacing %v", cell.min.y - tbl.min.y)
}
