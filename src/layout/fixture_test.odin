package layout

import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// What the layout tests share: a document parsed, styled and laid out without a window, with a fake font whose every
// character is 0.5 em wide (ascent 0.8 em, descent 0.2 em, x-height 0.5 em), so expected positions can be computed by hand.

FIXTURE_PARSE_MAX :: 2_000_000
FIXTURE_JOURNAL :: 1 << 16
FIXTURE_VP_W :: 800
FIXTURE_VP_H :: 600
FIXTURE_BAND_H :: 256
FIXTURE_NARROW_BAND_H :: 64   // a few lines each: what crosses bands is exercised

fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
fake_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
fake_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

FAKE_TEXT :: Text_Api{font = fake_font, width = fake_width, metrics = fake_metrics}

Fixture_Options :: struct {
	text:       Text_Api,     // nil font: FAKE_TEXT
	natural:    proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool),   // images' natural sizes, asked with the fixture
	set:        ^Settings,    // nil: the defaults
	band_h:     f32,          // 0: FIXTURE_BAND_H
	journal:    bool,         // the style journal, for incremental passes
	inc_verify: bool,         // each incremental pass checked against a full one (layout.incremental.verify)
	timeline:   bool,         // animations and transitions at time 0
}

Fixture :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	tl:  ^style.Timeline,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
	o:   Fixture_Options,
}

// Parsed and styled, not laid out.
fixture_init :: proc(f: ^Fixture, src: string, vw: f32 = FIXTURE_VP_W, vh: f32 = FIXTURE_VP_H, o := Fixture_Options{}) {
	f.o = o
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, FIXTURE_PARSE_MAX)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	if o.journal { style.engine_set_journal(f.eng, FIXTURE_JOURNAL) }
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	if o.timeline {
		f.tl = style.timeline_make(f.eng)
		style.timeline_restyled(f.tl, f.doc, nil, f.st, 0)
		style.timeline_tick(f.tl, f.doc, f.st, 0)
	}
	f.set = o.set != nil ? o.set^ : settings_default()
	if o.inc_verify { f.set.inc_verify = true }
	f.vp = {vw, vh}
}

fixture_run :: proc(f: ^Fixture) {
	text := f.o.text.font != nil ? f.o.text : FAKE_TEXT
	replaced := f.o.natural != nil ? Replaced_Api{user = f, intrinsic = f.o.natural} : Replaced_Api{}
	band_h := f.o.band_h > 0 ? f.o.band_h : FIXTURE_BAND_H
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = text, replaced = replaced, viewport = f.vp, scale = 1, band_h = band_h})
}

fixture_load :: proc(src: string, vw: f32 = FIXTURE_VP_W, vh: f32 = FIXTURE_VP_H, o := Fixture_Options{}) -> ^Fixture {
	f := new(Fixture)
	fixture_init(f, src, vw, vh, o)
	fixture_run(f)
	return f
}

fixture_destroy :: proc(f: ^Fixture) {
	destroy(&f.l)
	if f.tl != nil { style.timeline_destroy(f.tl, f.st) }
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

fixture_unload :: proc(f: ^Fixture) {
	fixture_destroy(f)
	free(f)
}
