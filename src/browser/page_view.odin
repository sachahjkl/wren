package browser

// A page view: a document shown in a rectangle that is not a window's page area. The frames of a document
// (frames_shell.odin) and an extension's popup (ext_popup.odin) are page views; a side panel would be one too.
//
// A view has a tab (Page_View.tab): the shell's per-tab machinery (layout, images, web fonts, container queries, forms
// and selection input, scroll bars) works on it unchanged, and Tab.view tells the code that concerns a window's tab
// (history in the strip, the address bar, the developer tools' targets) that it is none. A frame's tab is a stand-in
// that the frame's view owns; the popup's tab is a tab of no window, loaded by `navigate`.
//
//   page_view_prepare: its styles and layout at a size, then its own frames
//   page_view_paint: its layout painted into a rectangle
//   page_views_route_pointer, page_view_route_keys: the pointer and the keyboard, with the page area moved to the view
//   page_view_attach_js: the geometry its scripts read (page.Layout_Embedder)

import "toolkit:draw"
import "toolkit:platform"
import "wb:base"
import lay "wb:layout"
import "wb:page"

Page_View :: struct {
	tab:      ^Tab,         // its tab (tab.page is the document; tab.view points back here)
	host:     ^Tab,         // the window's tab it is shown over or in (nil: not known yet)
	rect:     draw.Rect,    // where it was put last (window px): painted there, input routed there
	size:     draw.Vec2,    // what it was laid out for (physical px)
	scale:    f32,
	ready:    bool,         // laid out for `size` (its first paint is not held back)
	painted:  u64,          // chrome frame number it was painted in (visible)
	transformed: bool,      // a frame's container is under a transform: input is not routed (the rect is only its bounds)
	no_scroll: bool,        // a frame's container says scrolling="no": no scroll bar, the document does not scroll
}

////////////////////////////////
// Layout

// Styles and layout of the view's document at `size` (physical px), then of its own frames.
page_view_prepare :: proc(app: ^App, pv: ^Page_View, size: draw.Vec2, scale: f32) {
	t := pv.tab
	p := t.page
	if p == nil || p.closed { pv.ready = false; return }
	pv.size, pv.scale = size, scale
	ls := &app.page_render.settings
	page.set_layout_journal(p, ls.incremental ? ls.inc_journal : 0)
	page.set_frame_time(p, pacer_of(app).frame_ms)
	defer page.set_frame_time(p, 0, unpin = true)
	styled := page.styles(p, size.x / scale, size.y / scale, f64(scale))
	if !p.render.painted {
		if state, _ := page.first_paint_state(p); state != .Ready { pv.ready = false; return }
	}
	saved := images_shell_page_swap(nil)
	images_shell_page_swap(saved)
	defer images_shell_page_swap(saved)
	adopt_web_fonts(t)
	images_before_layout(t)
	fonts_gen := u64(t.web_fonts)
	if layout_stale(&t.layout, p.doc, styled, size, scale, t.image_sizes, fonts_gen) {
		layout_document(&t.layout, p.doc, styled, &app.measure, &app.page_settings.style, size, scale, app.cfg.layout_band_px, t.image_sizes, fonts_gen)
	}
	styled = settle_container_queries(app, t, styled, size, scale, fonts_gen)
	images_after_layout(t, size, scale)
	if !p.render.painted { page.first_paint_done(p) }
	if !p.render.contentful && layout_contentful(&t.layout) { page.first_contentful_done(p) }
	lo_y, hi_y := lay.doc_scroll_y_range(&t.layout, size.y)
	t.scroll = clamp(t.scroll, lo_y, hi_y)
	doc_scroll_x_set(t, t.layout.doc_scroll_x, size.x)
	pv.ready = true
	// Performance Timeline entries that depend on the real paint (timeline_lcp.odin): the largest contentful element and
	// the element-timing entries from the layout just settled, and the layout shifts against the previous frame.
	vp := page_view_viewport(pv)
	page.timeline_present(p, &t.layout, vp)
	page.timeline_layout_shift_check(p, &t.layout, vp)
	frames_prepare(app, t, size, scale)
}

// The viewport the view's scripts see (CSS px).
page_view_viewport :: proc(pv: ^Page_View) -> page.Viewport {
	s := f64(pv.scale > 0 ? pv.scale : 1)
	return page.Viewport{width = f64(pv.size.x) / s, height = f64(pv.size.y) / s, scale = s, scroll_x = f64(doc_scroll_vec(pv.tab).x) / s, scroll_y = f64(pv.tab.scroll) / s}
}

// The geometry for the scripts of the view's document `p` (page.Layout_Embedder): its own layout, brought up to date.
page_view_attach_js :: proc(pv: ^Page_View, p: ^page.Page) {
	page.set_layout_embedder(p, {user = pv, update = page_view_js_layout, viewport = page_view_js_viewport, scroll_to = page_view_js_scroll,
		repaint = proc(user: rawptr, p: ^page.Page) { request_frames(the_app, 2) }})
}

@(private = "file")
page_view_js_layout :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	pv := (^Page_View)(user)
	if pv.tab.page != p || pv.size.x <= 0 || pv.size.y <= 0 { return nil }
	page_view_prepare(the_app, pv, pv.size, pv.scale)
	request_frames(the_app, 2)
	return &pv.tab.layout
}

@(private = "file")
page_view_js_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	return page_view_viewport((^Page_View)(user))
}

@(private = "file")
page_view_js_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	pv := (^Page_View)(user)
	if pv.tab.page != p { return }
	lo_y, hi_y := lay.doc_scroll_y_range(&pv.tab.layout, pv.size.y)
	pv.tab.scroll = f32(clamp(y * f64(pv.scale), f64(lo_y), f64(hi_y)))
	doc_scroll_x_set(pv.tab, f32(x * f64(pv.scale)), pv.size.x)
	request_frames(the_app, 2)
}

////////////////////////////////
// Painting

// The view's layout painted into `content` (window px), at the size it was laid out for, clipped to `content`. The
// caller fills what is under it (a frame's canvas is transparent, a popup's is not).
page_view_paint :: proc(app: ^App, dc: ^draw.Context, pv: ^Page_View, content: draw.Rect) {
	t := pv.tab
	if t.page == nil || !t.layout.valid { return }
	pv.rect = content
	pv.painted = app.chrome_frames.frame_no
	append(&app.paint_stack, t.page)
	saved := images_shell_page_swap(t.page)
	parent_highlights := app.spaint   // (its own selection and highlights)
	selection_paint_begin(app, t)
	draw.push_clip(dc, content)
	paint(&t.layout, dc, t.page.doc, content.min, pv.size, t.scroll, content, doc_scrollbar = !pv.no_scroll)
	draw.pop_clip(dc)
	app.spaint = parent_highlights
	images_shell_page_swap(saved)
	pop(&app.paint_stack)
}

////////////////////////////////
// Input

// The view of document `p` among the views input can reach: `root` (a view that is no frame: the popup), else a frame's.
@(private = "file")
page_view_find :: proc(p: ^page.Page, root: ^Page_View) -> ^Page_View {
	if p == nil { return nil }
	if root != nil && root.tab.page == p { return root }
	return frame_view_of(p)
}

// A pointer event over a view: handled as the page's own input on the view's tab, with the page area moved to the
// view's rectangle. `t` is the window's tab whose gesture it is; `doc` the tab whose document lies under the pointer in
// `rect` (`t` itself, or the popup's); the deepest frame of `doc` under the pointer takes the event, else `root` when
// it is given (the event is then in `rect`). True when a view took it.
page_views_route_pointer :: proc(app: ^App, t, doc: ^Tab, rect: draw.Rect, root: ^Page_View, ev: platform.Event, index: int) -> bool {
	wnd := active_window(app)
	#partial switch ev.kind {
	case .Mouse_Move, .Mouse_Press, .Mouse_Release, .Scroll:
	case: return false
	}
	fi := &window_own(app).frames
	g := gesture_of(app)
	fv := frame_under(app, doc, ev.pos, rect)
	if fv == nil && root != nil && draw.rect_contains(rect, ev.pos) {
		root.rect = rect
		fv = root
	}
	// hover leaves a view the pointer left
	if ev.kind == .Mouse_Move {
		now: ^page.Page = fv != nil ? fv.tab.page : nil
		if fi.hover != nil && fi.hover != now {
			if hv := page_view_find(fi.hover, root); hv != nil {
				st := fi.hover.style_state
				st.hover = base.NIL_HANDLE
				page.set_style_state(fi.hover, st)
			}
		}
		fi.hover = now
	}
	// a release goes where the press went (the click is the press target's), a view or the tab's document
	ended: Ended_Press
	if ev.kind == .Mouse_Release {
		if g.owner != .Frame { return false }
		fv = page_view_find(g.frame, root)
		ended = gesture_release(app, ev)
	}
	if ev.kind == .Mouse_Press {
		if fv != nil {
			keyboard_move(app, .Frame, fv.tab.page)
			if gesture_free(g) {
				gesture_press(app, t, fv.tab.page, .Frame, ev)
				g.frame = fv.tab.page
			}
		}
	}
	// the document a button was pressed in keeps the moves while it is held, wherever the pointer goes (an implicit capture:
	// a drag started in a frame goes on over the page around it)
	captured := false
	if ev.kind == .Mouse_Move && g.owner == .Frame {
		if pv := page_view_find(g.frame, root); pv != nil && pv != fv { fv, captured = pv, true }
	}
	if fv == nil { return false }
	saved := wnd.page_rect
	wnd.page_rect = fv.rect
	defer wnd.page_rect = saved
	used := page_view_pointer_event(app, fv, ev, index, ended)
	if ev.kind == .Mouse_Move && fv.tab.page != nil {
		hovered := draw.rect_contains(fv.rect, ev.pos) ? hit_test(&fv.tab.layout, ev.pos - fv.rect.min, draw.rect_size(fv.rect), fv.tab.scroll) : base.NIL_HANDLE
		if captured || draw.rect_contains(fv.rect, ev.pos) { hovered = hit_or_root(fv.tab, hovered) }   // (the root element when no box is there, or outside it while its button is held)
		st := fv.tab.page.style_state
		was := st.hover
		if st.hover != hovered {
			st.hover = hovered
			page.set_style_state(fv.tab.page, st)
		}
		// mousemove / pointermove and the boundary events, for the view's scripts (page_pointer.odin): what a drag in a frame follows
		page_pointer_events(app, fv.tab, was, hovered, ev.pos, dom_buttons(ev.buttons), ev.emulated)
	}
	return used
}

// The page's pointer handling, on a view's document (route_page_input's, without what concerns a window's tab: history,
// zoom, the context menu). False for a wheel the view cannot use: it scrolls what is around it (scroll chaining).
@(private = "file")
page_view_pointer_event :: proc(app: ^App, fv: ^Page_View, ev: platform.Event, index: int, ended: Ended_Press) -> bool {
	t := fv.tab
	if forms_route_event(app, t, ev, index) { return true }
	if t.page == nil { return true }
	rect := active_window(app).page_rect
	size := draw.rect_size(rect)
	#partial switch ev.kind {
	case .Scroll:
		if .Ctrl in ev.mods { return false }   // zoom is the tab's
		d := wheel_axes(ev) * wheel_step(app) * fv.scale
		if page_wheel(&t.layout, ev.pos - rect.min, d, size, t.scroll) {
			request_frames(app, 2)
			return true
		}
		lo_y, hi_y := lay.doc_scroll_y_range(&t.layout, size.y)
		next := clamp(t.scroll + d.y, lo_y, hi_y)
		lo, hi := lay.doc_scroll_x_range(&t.layout, size.x)
		next_x := clamp(t.layout.doc_scroll_x + d.x, lo, hi)
		if next == t.scroll && next_x == t.layout.doc_scroll_x { return false }
		t.scroll = next
		lay.set_doc_scroll_x(&t.layout, next_x)
		request_frames(app, 2)
	case .Mouse_Press:
		local := ev.pos - rect.min + doc_scroll_vec(t)
		pressed := hit_test(&t.layout, ev.pos - rect.min, size, t.scroll)
		t.scroll_target = pressed
		forms_pointer_down(app, t, ev, pressed, local)
		if t.page == nil { return true }
		if ev.button == .Left && gesture_of(app).owner == .Frame { page_set_active(t.page, pressed) }
	case .Mouse_Release:
		local := ev.pos - rect.min + doc_scroll_vec(t)
		released := draw.rect_contains(rect, ev.pos) ? hit_test(&t.layout, ev.pos - rect.min, size, t.scroll) : base.NIL_HANDLE
		target, clicked := forms_pointer_up(app, t, ev, released, local, ended)
		if !clicked || t.page == nil { return true }
		not_prevented := forms_click(app, t, target, ev, local)
		if t.page == nil || !not_prevented || ev.button != .Left { return true }
		if a, href, ok := frame_anchor(t.page.doc, target); ok { frames_follow_link(app, fv, a, href) }
	}
	request_frames(app, 2)
	return true
}

// A key or text event for the view's document, the page area moved to the view's rectangle. True when it was a key or
// text event (the view's, used or not).
page_view_route_keys :: proc(app: ^App, fv: ^Page_View, ev: platform.Event, index: int) -> bool {
	#partial switch ev.kind {
	case .Key_Press, .Key_Release, .Text:
	case: return false
	}
	wnd := active_window(app)
	saved := wnd.page_rect
	wnd.page_rect = fv.rect
	defer wnd.page_rect = saved
	forms_route_event(app, fv.tab, ev, index)
	return true
}
