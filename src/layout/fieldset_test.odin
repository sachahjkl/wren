package layout

import "core:math"
import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:style"

// <fieldset> / <legend> (HTML §15.3.13): the rendered legend on the top border, the content below it.

@(private = "file")
fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
fake_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
fake_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
with_layout :: proc(t: ^testing.T, src: string, check: proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document)) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	eng := style.engine_make(ss)
	style.settings_destroy(&ss)
	defer style.engine_destroy(eng)
	style.sync_document_sheets(eng, doc, "about:test")
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)
	set := settings_default()
	l: Layout
	defer destroy(&l)
	run(&l, Input{doc = doc, styled = st, settings = &set, text = Text_Api{font = fake_font, width = fake_width, metrics = fake_metrics}, viewport = {800, 600}, scale = 1, band_h = 256})
	check(t, &l, doc)
}

@(private = "file")
rect_of :: proc(l: ^Layout, doc: ^dom.Document, id: string) -> Rect {
	r, _ := box_of(l, dom.find_by_id(doc, id), {800, 600}, 0)
	return r.border
}

@(private = "file")
near :: proc(a, b: f32) -> bool { return math.abs(a - b) < 0.6 }

@(test)
legend_on_the_border :: proc(t: ^testing.T) {
	// line-height 20px: the legend is 20 px tall (+ 0 margins), the border 4 px
	with_layout(t, `<body style="margin:0;font-size:10px;line-height:20px">
		<fieldset id=f style="margin:0;border:4px solid;padding:5px 10px;width:300px"><legend id=g style="padding:0 6px;margin-left:8px">Navigation</legend><p id=p style="margin:0">content</p></fieldset>
		<fieldset id=c style="margin:0;border:4px solid;padding:5px 10px;width:300px"><legend id=cg style="margin:0 auto">Mid</legend>x</fieldset>
		<fieldset id=w style="margin:0;border:30px solid;padding:0;width:300px"><legend id=wg>Small</legend><span id=ws>x</span></fieldset>
		<fieldset id=n style="margin:0;border:4px solid;padding:5px 10px;width:300px"><legend id=fl style="float:left">floated</legend><legend id=second>second</legend>y</fieldset>
	</body>`, proc(t: ^testing.T, l: ^Layout, doc: ^dom.Document) {
		f, g, p := rect_of(l, doc, "f"), rect_of(l, doc, "g"), rect_of(l, doc, "p")
		// shrunk to fit: 10 characters of 5 px + 12 px of padding; after the border, the padding and its margin
		testing.expectf(t, near(g.max.x - g.min.x, 62), "legend width %v", g.max.x - g.min.x)
		testing.expectf(t, near(g.min.x, f.min.x + 4 + 10 + 8), "legend x %v (fieldset %v)", g.min.x, f.min.x)
		// taller than the border: at the top of the fieldset; the content starts below it, after the padding
		testing.expectf(t, near(g.min.y, f.min.y), "legend top %v, fieldset top %v", g.min.y, f.min.y)
		testing.expectf(t, near(p.min.y, f.min.y + 20 + 5), "content top %v", p.min.y - f.min.y)
		testing.expectf(t, near(f.max.y - f.min.y, 20 + 5 + 20 + 5 + 4), "fieldset height %v", f.max.y - f.min.y)
		shift, gap, ok := fieldset_border(l, box_index(l, dom.find_by_id(doc, "f")))
		testing.expect(t, ok && near(shift, 8) && near(gap[0], g.min.x) && near(gap[1], g.max.x), "the border runs through the legend's middle, cut behind it")
		// auto margins center it in the content box
		c, cg := rect_of(l, doc, "c"), rect_of(l, doc, "cg")
		mid := (c.min.x + c.max.x) * 0.5
		testing.expectf(t, near((cg.min.x + cg.max.x) * 0.5, mid), "centered legend %v in %v", cg, c)
		// a border taller than the legend: the legend is centered on it, the content after the border
		w, wg, ws := rect_of(l, doc, "w"), rect_of(l, doc, "wg"), rect_of(l, doc, "ws")
		testing.expectf(t, near(wg.min.y, w.min.y + 5), "legend centered on a 30 px border (%v)", wg.min.y - w.min.y)
		testing.expectf(t, ws.min.y >= w.min.y + 30, "content after the border (%v)", ws.min.y - w.min.y)
		_, _, wok := fieldset_border(l, box_index(l, dom.find_by_id(doc, "w")))
		testing.expect(t, wok)
		// a floated legend is not the rendered legend, nor is a second one
		testing.expect(t, fieldset_legend(l, box_index(l, dom.find_by_id(doc, "n"))) == box_index(l, dom.find_by_id(doc, "second")), "the first legend that is not floated")
	})
}
