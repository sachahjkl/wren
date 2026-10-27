package browser

// A real, isolated render of an HTML response in the Network tab's Preview (not the reader view): the markup is parsed
// into a document of its own, styled by a fresh style engine (the browser's own user-agent sheet plus the document's
// <style> blocks), laid out at the pane's width, and painted by the same document painter the page uses. It is a
// sandbox: no script ever runs (the document is inert, parsed like the reader's is, and the engine is told scripting is
// off so @media (scripting: none) and <noscript> behave as they should), and no sub-resource is fetched (no network),
// so a <link> stylesheet, an <img> or a web font stays unresolved. The request's address is the base URL, so url() in
// the document's sheets resolves as on the page (nothing loads from it). The render belongs to the chosen request and
// is thrown away with it.
//
// Why a document of its own rather than a live page: a live page would start the event loop, run scripts, fetch, and
// need the frame gate and the image and font registries. The preview must be inert and cheap, and must not touch the
// page the developer tools inspect. The pieces reused (parse, style engine, layout, paint) are the same code the real
// page runs, so what the preview shows matches the browser.

import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:dom"
import "wb:html"
import "wb:style"

// Everything one HTML preview render owns. Built once per chosen request (preview_render_ensure) and kept while that
// request stays chosen, so scrolling and resizing it is cheap; freed by preview_render_free.
Preview_Render :: struct {
	doc:     ^dom.Document,
	engine:  ^style.Engine,
	layout:  Layout,
	built:   bool,
	size:    draw.Vec2,   // the viewport the layout was run for (physical px)
	scale:   f32,
	scroll:  f32,
	title:   string,      // owned: the document's <title>, for the bar
	nodes:   int,
	bytes:   int,         // what it was parsed from, to rebuild when the body grows
	err:     string,      // owned: why it could not be rendered
	scroll_key: ui.Key,
}

preview_render_free :: proc(pr: ^Preview_Render) {
	if pr.engine != nil { style.engine_destroy(pr.engine); pr.engine = nil }
	if pr.doc != nil { dom.document_destroy(pr.doc); pr.doc = nil }
	layout_destroy(&pr.layout)
	delete(pr.title); pr.title = ""
	delete(pr.err); pr.err = ""
	pr^ = {}
}

// Parses `body` into an inert document and builds its style engine (user-agent sheet, then the document's <style>
// blocks). The request's address is the base URL for the sheets, so url() in them resolves as it would on the page
// (nothing is fetched from it: the preview has no network). Does not lay out yet (that waits for the pane's width).
@(private = "file")
preview_render_make :: proc(app: ^App, pr: ^Preview_Render, body: []byte, base_url: string) {
	pr.doc = dom.document_create()
	res := html.parse_into(pr.doc, pr.doc.root, body, 50_000)
	pr.nodes = res.nodes
	pr.title = strings.clone(strings.trim_space(html.title(pr.doc)))
	// a fresh engine with the page's style settings, so the preview reads like the browser: the user-agent sheet is loaded
	// by engine_make; the document's own <style> sheets are added below (a <link> would need the network, which the preview
	// does without: sync_document_sheets returns them and we drop them). scripting is off: the document is inert.
	pr.engine = style.engine_make(app.page_settings.style)
	_ = style.sync_document_sheets(pr.engine, pr.doc, base_url)
	if pr.nodes <= 0 { pr.err = strings.clone("This response has no markup to render.") }
}

// Lays out the document for the pane at `size` (physical px) and `scale`, styling first with scripting off. Runs on the
// interface thread (no thread pool), as a chrome frame does.
@(private = "file")
preview_render_layout :: proc(app: ^App, pr: ^Preview_Render, size: draw.Vec2, scale: f32) {
	if pr.doc == nil || pr.engine == nil || size.x <= 0 || size.y <= 0 { return }
	if pr.built && pr.size == size && pr.scale == scale { return }
	env := style.media_env_from(&pr.engine.settings, f64(size.x / scale), f64(size.y / scale), f64(scale), style.os_appearance().dark)
	env.scripting = false   // the preview never runs scripts: @media (scripting: none) and <noscript> apply
	style.engine_set_environment(pr.engine, env)
	styled := style.compute_styles(pr.engine, pr.doc, style.State{})   // no forced or pointer state: a plain render
	// the image shell answers natural sizes from the current page; the preview's document is not one, so no page is current
	// while it is laid out: every image reads as "nothing known" (a placeholder box), which is right with nothing fetched.
	saved := images_shell_page_swap(nil)
	defer images_shell_page_swap(saved)
	layout_document(&pr.layout, pr.doc, styled, &app.measure, &app.page_settings.style, size, scale, app.cfg.layout_band_px)
	pr.size, pr.scale, pr.built = size, scale, true
}

@(private = "file")
Pr_Draw :: struct { pr: ^Preview_Render, doc: ^dom.Document, layout: ^Layout, scroll: f32 }

@(private = "file")
pr_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Pr_Draw)(user)
	r := b.rect
	l := d.layout
	// the canvas colour of the document fills the pane first (CSS: the root or body background becomes the viewport's),
	// then the display list is painted clipped to the pane with its scroll offset, exactly as the page is painted.
	st := l.styled != nil ? (^style.Styled)(l.styled) : nil
	bg := st != nil ? to_draw(st.canvas) : dtc.bg
	draw.rect(dc, r, bg.a > 0 ? bg : dtc.bg)
	if !l.valid { return }
	size := draw.Vec2{r.max.x - r.min.x, r.max.y - r.min.y}
	draw.push_clip(dc, r)
	// the inert preview has no frames pages: an empty paint stack makes frames_paint_content return false, so replaced
	// boxes fall to the default painter (an empty rectangle for an unresolved <img>, since nothing is fetched). The image
	// shell reads natural sizes and textures from the current page; the preview's document is none, so no page is current.
	clear(&paint_stack)
	saved := images_shell_page_swap(nil)
	paint(l, dc, d.doc, r.min, size, d.scroll, r, doc_scrollbar = true)
	images_shell_page_swap(saved)
	draw.pop_clip(dc)
}

// Makes (or refreshes) the render of `e` for the preview pane. Rebuilds when the chosen request or its byte count changed.
@(private = "file")
preview_render_ensure :: proc(app: ^App, pr: ^Preview_Render, e: ^Net_Entry) {
	if pr.doc != nil && pr.bytes == len(e.body) { return }
	preview_render_free(pr)
	pr.bytes = len(e.body)
	if len(e.body) == 0 { return }
	preview_render_make(app, pr, e.body[:], e.url)
}

// The Rendered view of an HTML response: the isolated document laid out at the pane's width and painted like a page,
// scrolled by the wheel. Called from preview_html when the Rendered chip is on.
preview_html_rendered :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	pr := &d.pv.render
	preview_render_ensure(app, pr, e)
	if pr.err != "" { dt_empty("###dt_phr_err", .File_Doc, "No render", pr.err); return }
	if pr.doc == nil { dt_empty("###dt_phr_none", .File_Doc, "Nothing to render", "An HTML body appears here once the request is done."); return }
	// a scroll region of its own: the page's display list is clipped to it and scrolled by pr.scroll
	ui.next({width = ui.fill(), height = ui.fill()})
	box := ui.build_box({.Clip, .Clickable, .Scroll_Self, .Focusable}, "###dt_phr_view")
	pr.scroll_key = box.key
	sig := ui.signal(box)
	size := draw.Vec2{box.size.x, box.size.y}
	scale := dtm.sc
	if size.x > 0 && size.y > 0 {
		preview_render_layout(app, pr, size, scale)
		// the wheel scrolls it; the scroll is clamped to the document's height (what layout found) minus the pane
		if sig.scrolled.y != 0 {
			pr.scroll -= sig.scrolled.y
			request_frames(app, 2)
		}
		limit := max(pr.layout.height - size.y, 0)
		pr.scroll = clamp(pr.scroll, 0, limit)
	}
	pd := ui.frame_new(Pr_Draw)
	pd.pr, pd.doc, pd.layout, pd.scroll = pr, pr.doc, &pr.layout, pr.scroll
	box.custom, box.custom_user = pr_paint, pd
}
