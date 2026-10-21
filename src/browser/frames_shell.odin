package browser

// Nested documents in the shell (src/page/frames.odin makes them): each one is laid out at the size of its
// container's content box, painted there by the painter of replaced content (render.odin paint_content: the frame's
// display list drawn in place, under the container's clip, transform and opacity, like any replaced element: the
// compositor draws replaced items directly every frame, so a frame that changes repaints only itself on top of the
// parent's retained pictures), and receives the pointer events that land on it.
//
// A frame's document gets a stand-in Tab (Frame_View.tab): the shell's per-tab machinery (layout, images, web fonts,
// container queries, forms and selection input, scroll bars) works on it unchanged, while what belongs to a real tab
// (history, navigation, the address bar) never sees it: Tab.frame says it is a frame's.
//
//   page_prepare ── frames_prepare (after the parent's layout): every frame's styles and layout at its box's size,
//                   recursively; lazy frames learn their distance to the viewport
//   paint_content ── frames_paint_content: the frame's layout painted into its content box (recursively)
//   route_page_input ── frames_route_pointer: a pointer event over a frame goes to the deepest frame under it
//   frame ── frames_tick: animation frames, visibility, and whether a frame needs a new paint

import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:style"
import "wb:url"

Frame_View :: struct {
	tab:      Tab,          // the stand-in tab of the frame's document (tab.page is the document)
	host:     ^Tab,         // the real tab it is shown in (nil: not known yet)
	rect:     draw.Rect,    // its content box on screen, last painted (window px)
	size:     draw.Vec2,    // what it was laid out for (physical px)
	scale:    f32,
	ready:    bool,         // laid out for `size` (its first paint is not held back)
	painted:  u64,          // chrome frame number it was painted in (visible)
	transformed: bool,      // its container is under a transform: input is not routed (the rect is only its bounds)
}

@(private = "file")
frame_views: map[^page.Page]^Frame_View
@(private = "file")
frame_tab_ids: u64 = 1 << 40
@(private = "file")
paint_stack: [dynamic]^page.Page   // the documents being painted, innermost last
@(private = "file")
hover_frame: ^page.Page           // the frame document whose :hover is set
@(private = "file")
focus_frame: ^page.Page           // the frame document that got the last press (keyboard goes there)
@(private = "file")
press_frame: ^page.Page           // where the button went down (its release goes there too)

// Shell start-up: the page package tells us about each document a frame gets.
frames_shell_init :: proc(app: ^App) {
	page.frame_hooks = page.Frame_Hooks{user = app, attached = frames_attached}
}

frames_shell_destroy :: proc() {
	page.frame_hooks = {}
	delete(frame_views)
	frame_views = nil
	delete(paint_stack)
	paint_stack = nil
}

// The frame view of a frame's document (nil: a tab's document, or not a frame).
frame_view_of :: proc(p: ^page.Page) -> ^Frame_View {
	if p == nil { return nil }
	fv, _ := frame_views[p]
	return fv
}

@(private = "file")
frames_attached :: proc(user: rawptr, child: ^page.Page) {
	fv := new(Frame_View)
	frame_tab_ids += 1
	fv.tab.id = frame_tab_ids
	fv.tab.kind = .Web
	fv.tab.zoom = 1
	fv.tab.page = child
	fv.tab.frame = fv
	fv.tab.scope = child.scope
	fv.scale = 1
	frame_views[child] = fv
	base.on_close(child.scope, frame_view_closed, child)
	page.set_layout_embedder(child, {user = fv, update = frame_js_layout, viewport = frame_js_viewport, scroll_to = frame_js_scroll,
		repaint = proc(user: rawptr, p: ^page.Page) { the_app.frames_requested = max(the_app.frames_requested, 2) }})
	the_app.frames_requested = max(the_app.frames_requested, 2)
}

@(private = "file")
frame_view_closed :: proc(data: rawptr) {
	p := (^page.Page)(data)
	fv, ok := frame_views[p]
	if !ok { return }
	delete_key(&frame_views, p)
	if hover_frame == p { hover_frame = nil }
	if focus_frame == p { focus_frame = nil }
	if press_frame == p { press_frame = nil }
	page_fonts_drop(&page_render.fonts, &fv.tab)
	layout_destroy(&fv.tab.layout)
	smooth_destroy(&fv.tab.smooth)
	delete(fv.tab.fragment_seen)
	free(fv)
}

////////////////////////////////
// Layout

// The content box of a frame element in a laid out document: viewport coordinates of that document (its own scroll
// applied), in physical pixels. ok false: the element has no box (display: none...).
@(private = "file")
frame_box :: proc(l: ^Layout, el: base.Handle, viewport: draw.Vec2, scroll: f32) -> (r: lay.Box_Rects, ok: bool) {
	r, ok = lay.box_of(l, el, viewport, scroll)
	if !ok || !r.visible { return {}, false }
	return r, true
}

// After a document's layout: each of its frames laid out at its content box's size (recursively). `t` is the tab (or
// a frame's stand-in tab) of `p`, laid out for `viewport`.
frames_prepare :: proc(app: ^App, t: ^Tab, viewport: draw.Vec2, scale: f32) {
	p := t.page
	if p == nil || p.frames == nil || !t.layout.valid { return }
	for n in page.frames_children(p) {
		child := n.page
		fv := frame_view_of(child)
		if fv == nil { continue }
		fv.host = t.frame != nil ? t.frame.host : t
		r, ok := frame_box(&t.layout, n.element, viewport, t.scroll)
		if !ok {
			page.frames_set_distance(p, n.element, max(f32))
			page.set_page_visible(child, false)
			continue
		}
		// distance to the viewport (CSS px), for loading=lazy
		vr := lay.Rect{r.bounds.min - {0, t.scroll}, r.bounds.max - {0, t.scroll}}
		dx := max(0, vr.min.x - viewport.x, -vr.max.x)
		dy := max(0, vr.min.y - viewport.y, -vr.max.y)
		page.frames_set_distance(p, n.element, max(dx, dy) / max(scale, 0.01))
		size := draw.Vec2{math.round(r.content.max.x - r.content.min.x), math.round(r.content.max.y - r.content.min.y)}
		fv.transformed = r.transformed
		if size.x <= 0 || size.y <= 0 { fv.ready = false; continue }
		frame_prepare(app, fv, size, scale)
	}
}

// Styles and layout of a frame's document at `size` (physical px), then of its own frames.
frame_prepare :: proc(app: ^App, fv: ^Frame_View, size: draw.Vec2, scale: f32) {
	t := &fv.tab
	p := t.page
	if p == nil || p.closed { return }
	fv.size, fv.scale = size, scale
	ls := &page_render.settings
	page.set_layout_journal(p, ls.incremental ? ls.inc_journal : 0)
	page.set_frame_time(p, pacer.frame_ms)
	defer page.set_frame_time(p, 0, unpin = true)
	styled := page.styles(p, size.x / scale, size.y / scale, f64(scale))
	if !p.render.painted {
		if state, _ := page.first_paint_state(p); state != .Ready { fv.ready = false; return }
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
	t.scroll = clamp(t.scroll, 0, max(0, t.layout.height - size.y))
	fv.ready = true
	frames_prepare(app, t, size, scale)
}

// Geometry for the frame document's scripts (page.Layout_Embedder): its own layout, brought up to date.
@(private = "file")
frame_js_layout :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	fv := (^Frame_View)(user)
	if fv.tab.page != p || fv.size.x <= 0 || fv.size.y <= 0 { return nil }
	frame_prepare(the_app, fv, fv.size, fv.scale)
	the_app.frames_requested = max(the_app.frames_requested, 2)
	return &fv.tab.layout
}

@(private = "file")
frame_js_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	fv := (^Frame_View)(user)
	s := f64(fv.scale > 0 ? fv.scale : 1)
	return page.Viewport{width = f64(fv.size.x) / s, height = f64(fv.size.y) / s, scale = s, scroll_y = f64(fv.tab.scroll) / s}
}

@(private = "file")
frame_js_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	fv := (^Frame_View)(user)
	if fv.tab.page != p { return }
	limit := max(0, f64(fv.tab.layout.height) - f64(fv.size.y))
	fv.tab.scroll = f32(clamp(y * f64(fv.scale), 0, limit))
	the_app.frames_requested = max(the_app.frames_requested, 2)
}

////////////////////////////////
// Painting

// The document whose layout is being painted (page_paint sets the tab's; frames push theirs).
frames_paint_begin :: proc(p: ^page.Page) {
	clear(&paint_stack)
	append(&paint_stack, p)
}

// The content box of a frame element: its document, painted there. False when `node` is not a frame with a document
// ready to paint (the default painter leaves the box empty).
frames_paint_content :: proc(app: ^App, dc: ^draw.Context, d: ^dom.Document, node: base.Handle, content: draw.Rect, container: ^style.Computed) -> bool {
	if len(paint_stack) == 0 { return false }
	parent := paint_stack[len(paint_stack) - 1]
	if parent == nil || parent.doc != d || parent.frames == nil { return false }
	n := page.frame_of_element(parent, node)
	if n == nil || n.page == nil { return false }
	fv := frame_view_of(n.page)
	if fv == nil { return false }
	size := draw.Vec2{math.round(content.max.x - content.min.x), math.round(content.max.y - content.min.y)}
	if size.x <= 0 || size.y <= 0 { return true }
	if !fv.ready || fv.size != size { frame_prepare(app, fv, size, page_scale(app)) }
	if !fv.ready { return true }
	fv.rect = content
	fv.painted = chrome_frames.frame_no
	t := &fv.tab
	if !t.layout.valid { return true }
	// a frame's canvas is transparent (Chromium): a background the document gives itself fills it, and so does its
	// canvas color when its color scheme is not its container's (CSS Color Adjust §2.3: dark text of a light document
	// stays readable in a dark page)
	if st := t.page.styled; st != nil {
		mismatch := container != nil && container.used_scheme != st.root_scheme
		if mismatch || canvas_source_box(&t.layout) != lay.NONE { draw.rect(dc, content, to_draw(st.canvas)) }
	}
	append(&paint_stack, t.page)
	saved := images_shell_page_swap(t.page)
	draw.push_clip(dc, content)
	paint(&t.layout, dc, t.page.doc, content.min, size, t.scroll, content)
	draw.pop_clip(dc)
	images_shell_page_swap(saved)
	pop(&paint_stack)
	return true
}

////////////////////////////////
// Input

// The deepest frame under `pos` (window px) in the document of `t`, and its stand-in tab; nil when none.
frame_under :: proc(app: ^App, t: ^Tab, pos: draw.Vec2, rect: draw.Rect) -> ^Frame_View {
	if t == nil || t.page == nil || t.page.frames == nil || !t.layout.valid || !draw.rect_contains(rect, pos) { return nil }
	h := hit_test(&t.layout, pos - rect.min, draw.rect_size(rect), t.scroll)
	if h == base.NIL_HANDLE { return nil }
	n := page.frame_of_element(t.page, h)
	if n == nil || n.page == nil { return nil }
	fv := frame_view_of(n.page)
	if fv == nil || !fv.ready || fv.painted + 2 < chrome_frames.frame_no || fv.transformed || !draw.rect_contains(fv.rect, pos) { return nil }
	if inner := frame_under(app, &fv.tab, pos, fv.rect); inner != nil { return inner }
	return fv
}

// A pointer event of the page area over a frame: handled as the page's own input on the frame's stand-in tab, with
// the page area moved to the frame's content box. True when it was a frame's.
frames_route_pointer :: proc(app: ^App, t: ^Tab, ev: platform.Event, index: int) -> bool {
	#partial switch ev.kind {
	case .Mouse_Move, .Mouse_Press, .Mouse_Release, .Scroll:
	case: return false
	}
	fv := frame_under(app, t, ev.pos, app.page_rect)
	// hover leaves a frame the pointer left
	if ev.kind == .Mouse_Move {
		now: ^page.Page = fv != nil ? fv.tab.page : nil
		if hover_frame != nil && hover_frame != now {
			if hv := frame_view_of(hover_frame); hv != nil {
				st := hover_frame.style_state
				st.hover = base.NIL_HANDLE
				page.set_style_state(hover_frame, st)
			}
		}
		hover_frame = now
	}
	// a release goes where the press went (the click is the press target's), a frame or the tab's document
	if ev.kind == .Mouse_Release {
		pf := press_frame
		press_frame = nil
		fv = frame_view_of(pf)
		if pf != nil && fv == nil { return true }   // that frame is gone
	}
	if ev.kind == .Mouse_Press {
		focus_frame = fv != nil ? fv.tab.page : nil
		press_frame = focus_frame
	}
	if fv == nil { return false }
	saved := app.page_rect
	app.page_rect = fv.rect
	defer app.page_rect = saved
	used := frame_pointer_event(app, fv, ev, index)
	if ev.kind == .Mouse_Move {
		hovered := hit_test(&fv.tab.layout, ev.pos - fv.rect.min, draw.rect_size(fv.rect), fv.tab.scroll)
		st := fv.tab.page.style_state
		if st.hover != hovered {
			st.hover = hovered
			page.set_style_state(fv.tab.page, st)
		}
	}
	return used
}

// The page's pointer handling, on a frame's document (route_page_input's, without what concerns the tab: history,
// zoom, the context menu). False for a wheel the frame cannot use: it scrolls the parent (scroll chaining).
@(private = "file")
frame_pointer_event :: proc(app: ^App, fv: ^Frame_View, ev: platform.Event, index: int) -> bool {
	t := &fv.tab
	if forms_route_event(app, t, ev, index) { return true }
	if t.page == nil { return true }
	rect := app.page_rect
	size := draw.rect_size(rect)
	#partial switch ev.kind {
	case .Scroll:
		if .Ctrl in ev.mods { return false }   // zoom is the tab's
		d := ev.delta * app.cfg.scroll_step * page_scale(app)
		if page_wheel(&t.layout, ev.pos - rect.min, d, size, t.scroll) {
			app.frames_requested = max(app.frames_requested, 2)
			return true
		}
		next := clamp(t.scroll + d.y, 0, max(0, t.layout.height - size.y))
		if next == t.scroll { return false }
		t.scroll = next
		app.frames_requested = max(app.frames_requested, 2)
	case .Mouse_Press:
		local := ev.pos - rect.min + {0, t.scroll}
		pressed := hit_test(&t.layout, ev.pos - rect.min, size, t.scroll)
		t.scroll_target = pressed
		forms_pointer_down(app, t, ev, pressed, local)
		if t.page == nil { return true }
		if ev.button == .Left { page_set_active(t.page, pressed) }
	case .Mouse_Release:
		if ev.button == .Left { page_set_active(t.page, base.NIL_HANDLE) }
		local := ev.pos - rect.min + {0, t.scroll}
		released := draw.rect_contains(rect, ev.pos) ? hit_test(&t.layout, ev.pos - rect.min, size, t.scroll) : base.NIL_HANDLE
		target, clicked := forms_pointer_up(app, t, ev, released, local)
		if !clicked || t.page == nil { return true }
		not_prevented := forms_click(app, t, target, ev, local)
		if t.page == nil || !not_prevented || ev.button != .Left { return true }
		if a, href, ok := frame_anchor(t.page.doc, target); ok { frames_follow_link(app, fv, a, href) }
	}
	app.frames_requested = max(app.frames_requested, 2)
	return true
}

// The link (<a href>, <area href>) a click target is in.
@(private = "file")
frame_anchor :: proc(d: ^dom.Document, h: base.Handle) -> (el: base.Handle, href: string, ok: bool) {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element && (n.name == "a" || n.name == "area") {
			if v, has := dom.get_attribute(d, cur, "href"); has { return cur, v, true }
		}
		cur = n.parent
	}
	return
}

// Keyboard and text events while a frame has the keyboard (the last press was in it): its document's. True when the
// event was a key or text event the frame took.
frames_route_keys :: proc(app: ^App, ev: platform.Event, index: int) -> bool {
	#partial switch ev.kind {
	case .Key_Press, .Key_Release, .Text:
	case: return false
	}
	fv := frames_focused()
	if fv == nil { return false }
	saved := app.page_rect
	app.page_rect = fv.rect
	defer app.page_rect = saved
	forms_route_event(app, &fv.tab, ev, index)
	return true
}

// The frame document that has the keyboard (the last press went into it), its stand-in tab; nil: the tab's document.
frames_focused :: proc() -> ^Frame_View {
	if focus_frame == nil { return nil }
	return frame_view_of(focus_frame)
}

// A link followed in a frame's document (its default action): the frame navigates, or the navigable the link's target
// names (`_top` / `_parent` / a frame name; `_blank` opens a tab).
frames_follow_link :: proc(app: ^App, fv: ^Frame_View, el: base.Handle, href: string) {
	p := fv.tab.page
	resolved, ok := url.parse(href, &p.env.location, context.temp_allocator)
	if !ok { return }
	if page.follow_fragment_link(p, resolved) { return }
	if page.follow_javascript_url(p, resolved) { return }
	target, _ := dom.get_attribute(p.doc, el, "target")
	if strings.equal_fold(strings.trim_space(target), "_blank") {
		tab_open(app, resolved.href)
		return
	}
	n := page.frames_find_target(p, strings.trim_space(target))
	if n == nil { n = page.page_navigable(p) }
	if why := page.frames_navigate_from(p, n, resolved.href, false); why != "" { tab_log(fv.host, .Warn, why) }
}

////////////////////////////////
// Per frame

// Animation frames and visibility of the frames shown in the current tab; true when one of them wants a new frame
// (an animation frame callback, a CSS animation, a changed document).
frames_tick :: proc(app: ^App, t: ^Tab, frame_ms: f64) -> bool {
	if t == nil || t.page == nil || t.page.frames == nil { return false }
	return frames_tick_doc(app, t.page, frame_ms)
}

@(private = "file")
frames_tick_doc :: proc(app: ^App, p: ^page.Page, frame_ms: f64) -> bool {
	want := false
	for n in page.frames_children(p) {
		c := n.page
		fv := frame_view_of(c)
		if fv == nil { continue }
		shown := fv.painted + 2 >= chrome_frames.frame_no
		page.set_page_visible(c, shown)
		if !shown { continue }
		page.run_animation_frames(c, frame_ms)
		if page.wants_animation_frame(c) || page.animations_active(c) { want = true }
		if fv.tab.layout.mutations != c.doc.mutations { want = true }
		if frames_tick_doc(app, c, frame_ms) { want = true }
	}
	return want
}
