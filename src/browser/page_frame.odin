package browser

// A page's frame in two steps:
//   * page_prepare: styles, layout, container queries, the first paint's decision, where the view is (restored entry,
//     fragment); run in the frame's page phase (page_update, before the chrome is built), where chrome frames can be
//     made while it runs (shell_frames.odin), for the page area of the last frame;
//   * page_paint: the display list painted into the page area, in the UI tree's draw.
// When the page area changed size since (the window is being resized, a bar of the chrome opened), page_paint prepares
// again for the new size first, in place.

import "core:fmt"
import "toolkit:draw"
import "wb:config"
import "wb:css"
import "wb:page"

Page_Prep_State :: enum u8 { None, Hold, Ready }

// What page_prepare made, for page_paint (the window's: Window_Own.page_prep).
Page_Prep :: struct {
	frame:  u64,          // chrome_frames.frame_no it was made in
	tab:    ^Tab,
	page:   ^page.Page,
	size:   draw.Vec2,
	scale:  f32,
	state:  Page_Prep_State,   // Hold: the first paint waits (render-blocking resources, nothing contentful yet)
	canvas: css.Color,
}

// The page phase: the current tab's page prepared for the page area of the last frame.
page_update :: proc(app: ^App) {
	t := current_tab(app)
	if t == nil || t.kind != .Web || t.page == nil { return }
	size := draw.rect_size(active_window(app).page_rect)
	if size.x <= 0 || size.y <= 0 { return }
	page_prepare(app, t, size)
}

page_prepare :: proc(app: ^App, t: ^Tab, size: draw.Vec2) {
	page_world_check("page_prepare: a chrome frame, or the page thread has the layout")
	page_prep := &window_own(app).page_prep
	page_prep^ = Page_Prep{frame = chrome_frames.frame_no, tab = t, page = t.page, size = size, scale = page_scale(app), state = .None, canvas = expected_canvas(app)}
	hold_commit(t)
	scale := page_prep.scale
	// an incremental layout reads what the style passes changed (layout.incremental.*)
	ls := &page_render.settings
	page.set_layout_journal(t.page, ls.incremental ? ls.inc_journal : 0)
	// CSS animations and transitions sample the frame's time (pacing.odin), the live clock again between frames
	page.set_frame_time(t.page, pacer.frame_ms)
	pinned := t.page
	defer page.set_frame_time(pinned, 0, unpin = true)
	prof_begin(.Styles)
	styled := page.styles(t.page, size.x / scale, size.y / scale, f64(scale))
	prof_end(.Styles)
	hud_styles(t.page, styled)
	page_prep.canvas = styled.canvas
	first := !t.page.render.painted
	if first {
		// render-blocking stylesheets and fonts first (page/render_blocking.odin): meanwhile the old frame, or the canvas
		if state, _ := page.first_paint_state(t.page); state != .Ready {
			page_prep.state = .Hold
			first_paint_wake(app, t)
			return
		}
	}
	adopt_web_fonts(t)
	images_before_layout(t)
	fonts_gen := u64(t.web_fonts)
	if layout_stale(&t.layout, t.page.doc, styled, size, scale, t.image_sizes, fonts_gen) {
		prof_begin(.Layout)
		failures := t.layout.inc.verify_failures
		page_layout(app, t, styled, size, scale, fonts_gen)   // page_thread.odin: a long one on the page thread
		prof_end(.Layout)
		prof_layout(&t.layout)
		if t.layout.inc.verify_failures != failures {
			tab_log(t, .Warn, fmt.tprintf("layout.incremental.verify: incremental layout differs from a full one: %s", t.layout.inc.verify_report))
		}
	}
	styled = settle_container_queries(app, t, styled, size, scale, fonts_gen)
	page_prep.canvas = styled.canvas
	images_after_layout(t, size, scale)
	if first {
		// the first useful paint: something to see, or nothing left to wait for once the hold is over
		if t.hold.active && !layout_contentful(&t.layout) && hold_wait_ms(t) > 0 {
			page_prep.state = .Hold
			first_paint_wake(app, t)
			return
		}
		page.first_paint_done(t.page)
		hold_release(t)
		prof_first_paint(t)
	}
	restore_tick(app, t, size)   // history_restore.odin: an entry shown again comes back where it was
	scroll_to_fragment(t, size)
	t.scroll = clamp(t.scroll, 0, max(0, t.layout.height - size.y))
	frames_prepare(app, t, size, scale)   // its frames at their boxes' sizes (frames_shell.odin)
	page_prep.state = .Ready
}

// The page of the current tab painted into `rect` (the page area), prepared first if the page phase did not do it
// for this size.
page_paint :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect) {
	page_world_check("page_paint: a chrome frame, or the page thread has the layout")
	size := draw.rect_size(rect)
	p := &window_own(app).page_prep
	paint_size := size
	if p.frame != chrome_frames.frame_no || p.tab != t || p.page != t.page || p.size != size || p.scale != page_scale(app) {
		if p.frame == chrome_frames.frame_no && p.tab == t && p.page == t.page && p.scale == page_scale(app) && p.state == .Ready && pacer_resizing() && page_layout_is_long(app, t) && config.bool_of(&app.prefs, "browser.shell.resize_anchored") {
			// only the size changed since the page phase, the window is being resized, and this page's layout is long:
			// what was laid out is painted at its size, anchored at the top left, never stretched; the next frame lays
			// it out at the new size (on the page thread, the chrome drawing meanwhile). Not while a panel inside the
			// window is dragged (the tab sidebar's edge, the developer tools' splitter): the page beside it is laid out
			// at the width the pointer gives it in the frame that draws the panel there, never shown at another one.
			paint_size = p.size
			request_frames(app, 2)
		} else {
			page_prepare(app, t, size)
		}
	}
	switch p.state {
	case .None:
		draw.rect(dc, rect, to_draw(p.canvas))
		return
	case .Hold:
		hold_paint(app, t, dc, rect, p.canvas)
		return
	case .Ready:
	}
	draw.rect(dc, rect, to_draw(p.canvas))
	draw.push_clip(dc, rect)
	prof_begin(.Paint_Items)
	images_paint_begin_frame(app)
	selection_paint_begin(app, t)
	frames_paint_begin(t.page)   // frames paint their documents in their boxes (frames_shell.odin)
	paint(&t.layout, dc, t.page.doc, rect.min, paint_size, t.scroll, rect)
	forms_paint_overlays(app, dc, rect)
	images_after_paint(app)
	shell_capture(app, t, dc, rect, to_draw(p.canvas))   // shell_frames.odin: shown while the page is busy
	prof_end(.Paint_Items)
	draw.pop_clip(dc)
	timing_painted(t)
	load_measure_painted(t)   // blocker_measure.odin
}
