package wpt

import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:style"
import "wb:tools/headless"
import "wb:tools/wpt/reftest"

// Most folders run without layout (what the tests read of geometry is 0 there, and their expectations say so). The folders
// of LAYOUT_FOLDERS test geometry: their pages get a layout of a viewport of WPT's size, with fixed text metrics: Ahem as it
// is (every glyph 1 em wide, a line 1 em high), any other font half an em wide. The reference tests of REFTEST_FOLDERS
// are rendered under the same layout, with the natural sizes of images besides (reftest_run.odin); those of every other
// folder are not run.
@(private)
LAYOUT_FOLDERS :: [?]string{"/dom/events/scrolling/", "/css/css-anchor-position/", "/css/css-multicol/", "/css/css-writing-modes/", "/css/cssom/", "/html/semantics/interactive-elements/the-dialog-element/", "/navigation-api/scroll-behavior/"}
@(private)
REFTEST_FOLDERS :: [?]string{"css/css-multicol", "css/css-writing-modes"}
@(private)
LAYOUT_VIEW_W :: 800
@(private)
LAYOUT_VIEW_H :: 600
@(private)
LAYOUT_BAND_H :: 256
// An iframe's size without CSS (HTML's 300 x 150), a frame's viewport until its container is laid out.
@(private)
FRAME_VIEW_W :: 300
@(private)
FRAME_VIEW_H :: 150
@(private)
AHEM_FONT :: reftest.AHEM_FONT
@(private)
OTHER_FONT :: reftest.OTHER_FONT
@(private)
ASCENT_EM :: reftest.ASCENT_EM
@(private)
DESCENT_EM :: reftest.DESCENT_EM
// A broken image without dimensions is as large as its icon, this much more around it and after it (as src/browser).
@(private)
BROKEN_ICON_MARGIN :: 4
@(private)
BROKEN_TEXT_MARGIN :: 8
@(private)
ALT_LINE_FACTOR :: 1.25

@(private)
Layout_Host :: struct {
	l:      lay.Layout,
	set:    lay.Settings,
	scroll: [2]f64,
	view:   [2]int,       // the viewport
	images: bool,         // reference tests: natural sizes of images count
	page:   ^page.Page,
	framed: bool,         // a frame's document: its viewport is its container's content box (host_frame_attached)
}

@(private)
wants_layout :: proc(path: string) -> bool {
	for f in LAYOUT_FOLDERS { if strings.has_prefix(path, f) { return true } }
	return false
}

// Whether the reference tests of a suite folder run.
@(private)
wants_reftests :: proc(folder: string) -> bool {
	for f in REFTEST_FOLDERS { if f == folder { return true } }
	for f in opts.reftest_folders { if f == folder { return true } }
	return false
}

@(private)
host_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font {
	return len(families) > 0 && strings.equal_fold(families[0], "Ahem") ? AHEM_FONT : OTHER_FONT
}

@(private)
host_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 {
	n := 0
	for r in text { if !reftest.is_invisible_format(r) { n += 1 } }
	return reftest.font_advance(f, size) * f32(n)
}

@(private)
host_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics {
	m := lay.Font_Metrics{ascent = ASCENT_EM * size, descent = DESCENT_EM * size, x_height = size * reftest.OTHER_ADVANCE_EM}
	if f == AHEM_FONT { m.line_height = size }
	return m
}

// The natural size of a replaced element, as the shell gives it (shell_intrinsic in src/browser/images_shell.odin).
@(private)
host_intrinsic :: proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool) {
	p := (^Layout_Host)(user).page
	if p == nil { return 0, 0, false }
	d := p.doc
	n := dom.get(d, node)
	if n != nil && n.name == "svg" { return page.inline_svg_intrinsic(p, node) }
	if n != nil && n.name == "video" { return page.media_intrinsic(p, node) }
	attr :: proc(d: ^dom.Document, h: base.Handle, name: string) -> bool {
		v, ok := dom.get_attribute(d, h, name)
		if !ok { return false }
		t := strings.trim_space(v)
		end := 0
		for end < len(t) && ((t[end] >= '0' && t[end] <= '9') || t[end] == '.') { end += 1 }
		if end == 0 || (end < len(t) && t[end] == '%') { return false }
		number, nok := strconv.parse_f32(t[:end])
		return nok && number >= 0
	}
	v := page.image_view(p, node)
	if v.state == .Ready {
		if v.ratio_only { return 0, 0, false }
		return v.natural[0], v.natural[1], true
	}
	if v.state != .Broken || attr(d, node, "width") || attr(d, node, "height") { return 0, 0, false }
	alt, has_alt := dom.get_attribute(d, node, "alt")
	if has_alt && alt == "" { return 0, 0, true }
	icon := f32(p.settings.images.broken_icon_px)
	if !has_alt { return icon + BROKEN_ICON_MARGIN, icon + BROKEN_ICON_MARGIN, true }
	cs: ^style.Computed
	if i := int(base.handle_index(node)); p.styled != nil && i < len(p.styled.by_node) { cs = p.styled.by_node[i] }
	if cs == nil { return icon + BROKEN_ICON_MARGIN, icon + BROKEN_ICON_MARGIN, true }
	return icon + BROKEN_TEXT_MARGIN + host_width(nil, OTHER_FONT, cs.font_size, alt), max(icon + BROKEN_ICON_MARGIN, cs.font_size * ALT_LINE_FACTOR), true
}

@(private)
host_ratio :: proc(user: rawptr, node: base.Handle) -> f32 {
	p := (^Layout_Host)(user).page
	if p == nil { return 0 }
	if n := dom.get(p.doc, node); n != nil && n.name == "svg" { return page.inline_svg_ratio(p, node) }
	v := page.image_view(p, node)
	return v.state == .Ready && v.ratio_only ? v.ratio : 0
}

@(private)
host_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	h := (^Layout_Host)(user)
	vw, vh := f32(h.view[0]), f32(h.view[1])
	st := page.styles(p, vw, vh, 1)
	lay.note_doc_scroll(&h.l, f32(h.scroll[1]))
	input := lay.Input{doc = p.doc, styled = st, settings = &h.set, text = {font = host_font, width = host_width, metrics = host_metrics, bidi = host_bidi},
		viewport = {vw, vh}, scale = 1, band_h = LAYOUT_BAND_H}
	if h.images {
		input.replaced = lay.Replaced_Api{user = h, intrinsic = host_intrinsic, ratio = host_ratio}
		input.images_generation = page.images_sizes_generation(p)
	}
	// CSS Scroll Anchoring, as the shell does it (src/browser/page_thread.odin page_layout)
	anchor := lay.scroll_anchor_select(&h.l, st, 1, f32(h.scroll[1]), vh)
	lay.run(&h.l, input)
	if shift := lay.scroll_anchor_shift(&h.l, anchor); shift != 0 {
		lo, hi := lay.doc_scroll_y_range(&h.l, vh)
		h.scroll[1] = clamp(h.scroll[1] + f64(shift), f64(lo), f64(hi))
	}
	return &h.l
}

@(private)
host_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	h := (^Layout_Host)(user)
	if h.framed { frame_view_size(h, p) }
	return page.Viewport{width = f64(h.view[0]), height = f64(h.view[1]), scale = 1, scroll_x = h.scroll[0], scroll_y = h.scroll[1]}
}

// A frame's viewport: the content box of its container in its parent's layout, as the shell lays it out (frames_prepare);
// what it was when the container has none (display: none, or a parent without a layout).
@(private)
frame_view_size :: proc(h: ^Layout_Host, p: ^page.Page) {
	nav := p.frames != nil ? p.frames.nav : nil
	if nav == nil || nav.parent == nil { return }
	l, vp := page.js_layout_now(nav.parent)
	if l == nil || !l.valid { return }
	s := f32(vp.scale)
	r, ok := lay.box_of(l, nav.element, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s)
	if !ok || !r.visible { return }
	size := (r.content.max - r.content.min) / s
	if size.x > 0 && size.y > 0 { h.view = {int(size.x), int(size.y)} }
}

// A document a frame of a test with a layout gets (page.Frame_Hooks.attached, child_main): laid out too, until it closes.
@(private)
host_frame_attached :: proc(user: rawptr, child: ^page.Page) {
	h := host_make(view = {FRAME_VIEW_W, FRAME_VIEW_H})
	h.page = child
	h.framed = true
	base.on_close(child.scope, proc(data: rawptr) { host_destroy((^Layout_Host)(data)) }, h)
	page.set_layout_embedder(child, {user = h, update = host_update, viewport = host_viewport, scroll_to = host_scroll})
}

@(private)
host_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	h := (^Layout_Host)(user)
	lo, hi := lay.doc_scroll_x_range(&h.l, f32(h.view[0]))
	lo_y, hi_y := lay.doc_scroll_y_range(&h.l, f32(h.view[1]))
	h.scroll = {clamp(x, f64(lo), f64(hi)), clamp(y, f64(lo_y), f64(hi_y))}
	lay.set_doc_scroll_x(&h.l, f32(h.scroll[0]))
}

// A document of a test that reads geometry was adopted: it is laid out from now on, as its scripts ask.
@(private)
host_attach :: proc(d: ^headless.Doc) {
	h := (^Child_State)(d.user).layout
	if h == nil || d.page == nil { return }
	h.page = d.page
	page.set_layout_embedder(d.page, {user = h, update = host_update, viewport = host_viewport, scroll_to = host_scroll})
}

// `images`: natural sizes of images count (reference tests); `view`: the viewport, 0: WPT's default.
@(private)
host_make :: proc(images := false, view := [2]int{}) -> ^Layout_Host {
	h := new(Layout_Host)
	h.set = lay.settings_default()
	h.images = images
	h.view = view != {} ? view : [2]int{LAYOUT_VIEW_W, LAYOUT_VIEW_H}
	return h
}

@(private)
host_destroy :: proc(h: ^Layout_Host) {
	if h == nil { return }
	lay.destroy(&h.l)
	free(h)
}
