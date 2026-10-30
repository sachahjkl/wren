package layout

import "core:math"
import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:style"

// table-layout: fixed with the column widths of the first row in border-box cells (Tailwind's preflight), a table as
// wide as its container through min-width: 100% (clockin.sacha.house's week table). Expected values measured in Edge.

@(private = "file")
tf_layout :: proc(src: string) -> (doc: ^dom.Document, eng: ^style.Engine, st: ^style.Styled, l: Layout) {
	doc = dom.document_create(nil)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(eng, doc, "about:test")
	st = style.compute_styles(eng, doc, {})
	set := settings_default()
	api := Text_Api{
		font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) },
		width = proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) },
		metrics = proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} },
	}
	run(&l, Input{doc = doc, styled = st, settings = &set, text = api, viewport = {1200, 800}, scale = 1, band_h = 256})
	return
}

// A fixed table with a width: its columns come from the first row, the automatic one takes what is left, and a cell whose
// text does not break never widens the table (GitHub's file list: a commit message with white-space: nowrap).
@(test)
table_fixed_width_ignores_content :: proc(t: ^testing.T) {
	doc, eng, st, l := tf_layout(`<!doctype html><style>*{box-sizing:border-box;margin:0;padding:0;border:0 solid}</style><body style="font:14px main"><div style="width:700px">
<table id=t style="table-layout:fixed;width:100%;border-spacing:0">
<thead><tr><th id=h0 style="width:40%"></th><th id=h1></th><th id=h2 style="width:136px"></th></tr></thead>
<tbody><tr><td id=a>x</td><td id=b><div id=m style="white-space:nowrap;overflow:hidden;max-width:100%">the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog</div></td><td id=c>y</td></tr></tbody></table></div></body>`)
	defer { destroy(&l); style.styled_destroy(st); style.engine_destroy(eng); dom.document_destroy(doc) }
	Want :: struct { id: string, x, w: f32 }
	for c in ([]Want{{"t", 0, 700}, {"h0", 0, 280}, {"h1", 280, 284}, {"h2", 564, 136}, {"a", 0, 280}, {"b", 280, 284}, {"c", 564, 136}, {"m", 280, 284}}) {
		r, ok := box_of(&l, dom.find_by_id(doc, c.id), {1200, 800}, 0)
		got := r.border
		testing.expectf(t, ok && math.abs(got.min.x - c.x) < 0.02 && math.abs(got.max.x - got.min.x - c.w) < 0.02, "%s: x %v w %v, want x %v w %v", c.id, got.min.x, got.max.x - got.min.x, c.x, c.w)
	}
}

@(test)
table_fixed_min_width_border_box :: proc(t: ^testing.T) {
	doc, eng, st, l := tf_layout(`<!doctype html><style>*{box-sizing:border-box;margin:0;padding:0;border:0 solid}</style><body style="font:14px main"><div style="width:958px">
<table id=t style="min-width:100%;table-layout:fixed;border-collapse:collapse;text-align:left">
<thead><tr><th id=h0 style="width:200px;padding:12px 16px;white-space:nowrap">Jour</th><th id=h1 style="width:128px;padding:12px 16px">Entree 1</th><th id=h2 style="width:128px;padding:12px 16px">Sortie 1</th><th id=h5 style="padding:12px 16px">Total</th></tr></thead>
<tbody><tr style="border-top:1px solid #ccc"><td id=d0 style="padding:12px 16px">sam. 17 oct.</td><td style="padding:12px 16px"><button style="padding:4px 8px">N/A</button></td><td style="padding:12px 16px">x</td><td id=d5 style="padding:12px 16px">-</td></tr></tbody></table></div></body>`)
	defer { destroy(&l); style.styled_destroy(st); style.engine_destroy(eng); dom.document_destroy(doc) }
	Want :: struct { id: string, x, w: f32 }
	for c in ([]Want{{"t", 0, 958}, {"h0", 0, 200}, {"h1", 200, 128}, {"h2", 328, 128}, {"h5", 456, 502}, {"d0", 0, 200}, {"d5", 456, 502}}) {
		r, ok := box_of(&l, dom.find_by_id(doc, c.id), {1200, 800}, 0)
		got := r.border
		testing.expectf(t, ok && math.abs(got.min.x - c.x) < 0.02 && math.abs(got.max.x - got.min.x - c.w) < 0.02, "%s: x %v w %v, want x %v w %v", c.id, got.min.x, got.max.x - got.min.x, c.x, c.w)
	}
}
