package browser

// The tab's side of the DOM's geometry for scripts (page.Layout_Embedder): offsetWidth, getBoundingClientRect,
// getComputedStyle, scrollTo... read the tab's own styles and layout, brought up to date by the same steps a frame
// takes (page.styles, then layout_document when stale: incremental, only what changed). Reading in a loop costs
// nothing more once they are up to date (the page checks first, js_dom_layout.odin).

import "core:math"
import draw "toolkit:draw"
import lay "wb:layout"
import "wb:page"

// Called when a document is attached to its tab (attach_page).
attach_js_layout :: proc(app: ^App, t: ^Tab, p: ^page.Page) {
	page.set_layout_embedder(p, {user = t, update = js_layout_update, viewport = js_layout_viewport, scroll_to = js_layout_scroll, repaint = js_layout_repaint})
}

// The page area (physical pixels) a tab's document is laid out for: the one painted last.
@(private = "file")
page_area :: proc(app: ^App) -> draw.Vec2 { return draw.rect_size(app.page_rect) }

@(private = "file")
js_layout_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	app := the_app
	t := (^Tab)(user)
	if t.page != p { return nil }
	size := page_area(app)
	if size.x <= 0 || size.y <= 0 { return nil }
	scale := page_scale(app)
	ls := &page_render.settings
	page.set_layout_journal(p, ls.incremental ? ls.inc_journal : 0)
	styled := page.styles(p, size.x / scale, size.y / scale, f64(scale))
	// natural sizes of images, canvases, videos and inline SVG come from the page being laid out. A layout asked for by a
	// script before any frame of this page made it the shell's page (the first read of a layout in a page just navigated to)
	// read the page of the previous frame: another document, or one already freed.
	prev := images_shell_page_swap(p)
	defer images_shell_page_swap(prev)
	fonts_gen := u64(t.web_fonts)
	if layout_stale(&t.layout, p.doc, styled, size, scale, t.image_sizes, fonts_gen) {
		page_layout(app, t, styled, size, scale, fonts_gen)   // page_thread.odin: a long one on the page thread, the chrome drawing meanwhile
	}
	app.frames_requested = max(app.frames_requested, 2)   // what the script changed is to be painted
	return &t.layout
}

@(private = "file")
js_layout_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	app := the_app
	t := (^Tab)(user)
	scale := f64(page_scale(app))
	if scale <= 0 { scale = 1 }
	size := page_area(app)
	return page.Viewport{width = f64(size.x) / scale, height = f64(size.y) / scale, scale = scale, scroll_y = f64(t.scroll) / scale}
}

@(private = "file")
js_layout_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	app := the_app
	t := (^Tab)(user)
	if t.page != p { return }
	scale := f64(page_scale(app))
	size := page_area(app)
	limit := math.max(0, f64(t.layout.height) - f64(size.y))
	scroll_document_to(app, t, f32(clamp(y * scale, 0, limit)), smooth)
	app.frames_requested = max(app.frames_requested, 2)
}

@(private = "file")
js_layout_repaint :: proc(user: rawptr, p: ^page.Page) { the_app.frames_requested = max(the_app.frames_requested, 2) }
