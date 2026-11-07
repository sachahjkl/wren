package browser

// The tab's side of the DOM's geometry for scripts (page.Layout_Embedder): offsetWidth, getBoundingClientRect,
// getComputedStyle, scrollTo... read the tab's own styles and layout, brought up to date by the same steps a frame
// takes (page.styles, then layout_document when stale: incremental, only what changed). Reading in a loop costs
// nothing more once they are up to date (the page checks first, js_dom_layout.odin).

import "core:fmt"
import "core:time"
import draw "toolkit:draw"
import "wb:base"
import lay "wb:layout"
import "wb:page"
import "wb:style"

// Called when a document is attached to its tab (attach_page).
attach_js_layout :: proc(app: ^App, t: ^Tab, p: ^page.Page) {
	page.set_layout_embedder(p, {user = t, update = js_layout_update, viewport = js_layout_viewport, scroll_to = js_layout_scroll, repaint = js_layout_repaint})
}

// The page area (physical pixels) a tab's document is laid out for: the one painted last. Before any (a document
// opened with the window, its scripts running before the first frame) the window's client area stands for it: a
// viewport of 0 x 0 made pages pick their phone layout (DuckDuckGo); the resize steps tell them when the real area
// is known (page/scroll_events.odin).
@(private = "file")
page_area :: proc(app: ^App) -> draw.Vec2 {
	wnd := active_window(app)
	r := draw.rect_size(wnd.page_rect)
	if (r.x <= 0 || r.y <= 0) && wnd.win != nil { return {f32(wnd.win.size.x), f32(wnd.win.size.y)} }
	return r
}

@(private = "file")
js_layout_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	app := the_app
	t := (^Tab)(user)
	if t.page != p { return nil }
	size := page_area(app)
	if size.x <= 0 || size.y <= 0 { return nil }
	scale := page_scale(app)
	ls := &app.page_render.settings
	page.set_layout_journal(p, ls.incremental ? ls.inc_journal : 0)
	t_read := time.tick_now()
	// (spans, WREN_SPANS: a reading's style pass and layout, apart from what read them; inside a task they are the task's)
	read_styles := base.span_now()
	styled := page.styles(p, size.x / scale, size.y / scale, f64(scale))
	base.span_add(.Phase, read_styles, fmt.tprintf("read_styles:%s:%s", app.rendering == t ? page.dbg_step : "task", page.dbg_kind), copy_label = true) // TMPDBG
	style_took := time.tick_since(t_read)
	// natural sizes of images, canvases, videos and inline SVG come from the page being laid out. A layout asked for by a
	// script before any frame of this page made it the shell's page (the first read of a layout in a page just navigated to)
	// read the page of the previous frame: another document, or one already freed.
	prev := images_shell_page_swap(p)
	defer images_shell_page_swap(prev)
	fonts_gen := u64(t.web_fonts)
	// (the sizes this pass reads are the page's now: noted with the generation of the tab's last frame, the next frame would
	// lay out again what the first read of a new page just laid out)
	t.image_sizes = page.images_sizes_generation(p)
	if layout_stale(&t.layout, p.doc, styled, size, scale, t.image_sizes, fonts_gen) {
		read_layout := base.span_now()
		l0 := &t.layout; dbg_why := !l0.valid ? "invalid" : l0.mutations != p.doc.mutations ? "mutations" : l0.serial != styled.serial ? (l0.layout_serial == styled.layout_serial ? "serial-paint" : "serial") : l0.viewport != size ? "viewport" : l0.inc.images_gen != t.image_sizes ? "images" : l0.inc.fonts_gen != fonts_gen ? "fonts" : l0.anchor_stale ? "anchor" : "?" // TMPDBG
		page_layout(app, t, styled, size, scale, fonts_gen)   // page_thread.odin: a long one on the page thread, the chrome drawing meanwhile
		base.span_add(.Phase, read_layout, fmt.tprintf("read_layout:%s:%v:%s:%s:steps %.1f %.1f %.1f %.1f %.1f laid %d", app.rendering == t ? page.dbg_step : "task", t.layout.last_pass, dbg_why, t.layout.inc.fallback, t.layout.stats[0], t.layout.stats[1], t.layout.stats[2], t.layout.stats[3], t.layout.stats[4], t.layout.inc.last_laid), copy_label = true) // TMPDBG
		prof_layout(&t.layout)
		layout_trace("read", &t.layout, time.duration_milliseconds(style_took), time.duration_milliseconds(time.tick_since(t_read) - style_took))
	}
	// what the script changed is to be painted: by a frame to come, unless this one is the tab's rendering update (its callbacks, its page
	// phase), which paints it. (Asked from there, each frame asked for the next: an animation ticking under a forced reading never rested.)
	if app.rendering != t { request_frames(app, 2) }
	return &t.layout
}

// (WREN_RESTYLE_TRACE) one line per layout pass, as a script's reading (`read`) or a frame (`frame`) asked for it.
layout_trace :: proc(who: string, l: ^lay.Layout, style_ms, layout_ms: f64) {
	if !style.trace_restyle() { return }
	@(static) failures: int
	if l.inc.verify_failures != failures { failures = l.inc.verify_failures; fmt.eprintfln("layout.incremental.verify: %s", l.inc.verify_report) }
	fmt.eprintfln("layout pass: %s %v style %.1f layout %.1f ms, steps %.1f %.1f %.1f %.1f %.1f, %d boxes, rebuilt %d, laid %d, verify failures %d: %s", who, l.last_pass, style_ms, layout_ms,
		l.stats[0], l.stats[1], l.stats[2], l.stats[3], l.stats[4], len(l.boxes), l.inc.last_rebuilt, l.inc.last_laid, l.inc.verify_failures, l.inc.fallback)
}

@(private = "file")
js_layout_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	app := the_app
	t := (^Tab)(user)
	scale := f64(page_scale(app))
	if scale <= 0 { scale = 1 }
	size := page_area(app)
	return page.Viewport{width = f64(size.x) / scale, height = f64(size.y) / scale, scale = scale, scroll_x = f64(doc_scroll_vec(t).x) / scale, scroll_y = f64(t.scroll) / scale}
}

@(private = "file")
js_layout_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	app := the_app
	t := (^Tab)(user)
	if t.page != p { return }
	scale := f64(page_scale(app))
	size := page_area(app)
	lo, hi := lay.doc_scroll_x_range(&t.layout, size.x)
	lo_y, hi_y := lay.doc_scroll_y_range(&t.layout, size.y)
	scroll_document_to(app, t, {clamp(f32(x * scale), lo, hi), clamp(f32(y * scale), lo_y, hi_y)}, smooth)
	request_frames(app, 2)
}

@(private = "file")
js_layout_repaint :: proc(user: rawptr, p: ^page.Page) { request_frames(the_app, 2) }
