package wpt

import "core:strings"
import "wb:base"
import lay "wb:layout"
import "wb:page"
import "wb:tools/headless"

// Most folders run without layout (what the tests read of geometry is 0 there, and their expectations say so). The folders
// of LAYOUT_FOLDERS test geometry: their pages get a layout of a viewport of WPT's size, with fixed text metrics: Ahem as it
// is (every glyph 1 em wide, a line 1 em high), any other font half an em wide.
@(private)
LAYOUT_FOLDERS :: [?]string{"/css/css-anchor-position/"}
@(private)
LAYOUT_VIEW_W :: 800
@(private)
LAYOUT_VIEW_H :: 600
@(private)
LAYOUT_BAND_H :: 256
@(private)
AHEM_FONT :: lay.Font(2)
@(private)
OTHER_FONT :: lay.Font(1)
@(private)
OTHER_ADVANCE_EM :: 0.5
@(private)
ASCENT_EM :: 0.8
@(private)
DESCENT_EM :: 0.2

@(private)
Layout_Host :: struct {
	l:      lay.Layout,
	set:    lay.Settings,
	scroll: [2]f64,
}

@(private)
wants_layout :: proc(path: string) -> bool {
	for f in LAYOUT_FOLDERS { if strings.has_prefix(path, f) { return true } }
	return false
}

@(private)
host_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font {
	return len(families) > 0 && strings.equal_fold(families[0], "Ahem") ? AHEM_FONT : OTHER_FONT
}

@(private)
host_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 {
	em: f32 = f == AHEM_FONT ? 1 : OTHER_ADVANCE_EM
	return em * size * f32(strings.rune_count(text))
}

@(private)
host_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics {
	m := lay.Font_Metrics{ascent = ASCENT_EM * size, descent = DESCENT_EM * size, x_height = size * OTHER_ADVANCE_EM}
	if f == AHEM_FONT { m.line_height = size }
	return m
}

@(private)
host_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	h := (^Layout_Host)(user)
	st := page.styles(p, LAYOUT_VIEW_W, LAYOUT_VIEW_H, 1)
	lay.note_doc_scroll(&h.l, f32(h.scroll[1]))
	lay.run(&h.l, lay.Input{doc = p.doc, styled = st, settings = &h.set, text = {font = host_font, width = host_width, metrics = host_metrics},
		viewport = {LAYOUT_VIEW_W, LAYOUT_VIEW_H}, scale = 1, band_h = LAYOUT_BAND_H})
	return &h.l
}

@(private)
host_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	h := (^Layout_Host)(user)
	return page.Viewport{width = LAYOUT_VIEW_W, height = LAYOUT_VIEW_H, scale = 1, scroll_x = h.scroll[0], scroll_y = h.scroll[1]}
}

@(private)
host_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	h := (^Layout_Host)(user)
	lo, hi := lay.doc_scroll_x_range(&h.l, LAYOUT_VIEW_W)
	h.scroll = {clamp(x, f64(lo), f64(hi)), clamp(y, 0, max(f64(h.l.height) - LAYOUT_VIEW_H, 0))}
	lay.set_doc_scroll_x(&h.l, f32(h.scroll[0]))
}

// A document of a test that reads geometry was adopted: it is laid out from now on, as its scripts ask.
@(private)
host_attach :: proc(d: ^headless.Doc) {
	h := (^Child_State)(d.user).layout
	if h == nil || d.page == nil { return }
	page.set_layout_embedder(d.page, {user = h, update = host_update, viewport = host_viewport, scroll_to = host_scroll})
}

@(private)
host_make :: proc() -> ^Layout_Host {
	h := new(Layout_Host)
	h.set = lay.settings_default()
	return h
}

@(private)
host_destroy :: proc(h: ^Layout_Host) {
	if h == nil { return }
	lay.destroy(&h.l)
	free(h)
}

_ :: base.NIL_HANDLE
