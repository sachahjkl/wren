package browser

// Nested documents in the shell (src/page/frames.odin makes them): each one is laid out at the size of its
// container's content box, painted there by the painter of replaced content (render.odin paint_content: the frame's
// display list drawn in place, under the container's clip, transform and opacity, like any replaced element: the
// compositor draws replaced items directly every frame, so a frame that changes repaints only itself on top of the
// parent's retained pictures), and receives the pointer events that land on it.
//
// A frame's document is a page view (page_view.odin) whose stand-in Tab it owns: the shell's per-tab machinery works on
// it unchanged, while what belongs to a real tab (history, navigation, the address bar) never sees it: Tab.view says it
// is a view's.
//
//   page_prepare ── frames_prepare (after the parent's layout): every frame's styles and layout at its box's size,
//                   recursively; lazy frames learn their distance to the viewport
//   paint_content ── frames_paint_content: the frame's layout painted into its content box (recursively)
//   route_page_input ── frames_route_pointer: a pointer event over a frame goes to the deepest frame under it
//   frame ── frames_tick: animation frames, visibility, and whether a frame needs a new paint

import "core:math"
import "core:strings"
import "core:sync"
import "toolkit:draw"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"
import "wb:style"
import "wb:url"

// The ids of the frames' views (atomic: unique in the process, beside the tabs', which stay below FRAME_TAB_IDS_FROM).
FRAME_TAB_IDS_FROM :: 1 << 40
@(private = "file")
frame_tab_ids: u64 = FRAME_TAB_IDS_FROM

// A window's pointer and keyboard among the frames of its page (Window_Own.frames).
Frames_Input :: struct {
	hover: ^page.Page,   // the frame document whose :hover is set
}

// Shell start-up: the page package tells us about each document a frame gets.
frames_shell_init :: proc(app: ^App) {
	app.pages.frame_hooks = page.Frame_Hooks{user = app, attached = frames_attached}
}

frames_shell_destroy :: proc(app: ^App) {
	app.pages.frame_hooks = {}
	delete(app.frame_views)
	app.frame_views = nil
	delete(app.paint_stack)
	app.paint_stack = nil
}

// The view of a frame's document (nil: a tab's document, the popup's, or not a frame).
frame_view_of :: proc(p: ^page.Page) -> ^Page_View {
	if p == nil { return nil }
	fv, _ := the_app.frame_views[p]
	return fv
}

@(private = "file")
frames_attached :: proc(user: rawptr, child: ^page.Page) {
	fv := new(Page_View)
	fv.tab = tab_alloc_frame(sync.atomic_add(&frame_tab_ids, 1) + 1)
	fv.tab.page = child
	fv.tab.view = fv
	fv.tab.scope = child.scope
	fv.scale = 1
	the_app.frame_views[child] = fv
	base.on_close(child.scope, frame_view_closed, child)
	page_view_attach_js(fv, child)
	request_frames(the_app, 2)
}

@(private = "file")
frame_view_closed :: proc(data: rawptr) {
	p := (^page.Page)(data)
	fv, ok := the_app.frame_views[p]
	if !ok { return }
	delete_key(&the_app.frame_views, p)
	page_view_forget(the_app, p)
	page_fonts_drop(&the_app.page_render.fonts, fv.tab)
	layout_destroy(&fv.tab.layout)
	smooth_destroy(&fv.tab.smooth)
	free(fv.tab)
	free(fv)
}

// A view's document is gone: the windows' hover and keyboard let go of it.
page_view_forget :: proc(app: ^App, p: ^page.Page) {
	forget :: proc(own: ^Window_Own, p: ^page.Page) {
		if own.frames.hover == p { own.frames.hover = nil }
		keyboard_frame_closed(&own.keyboard, p)
	}
	if app == nil { return }
	for w in app.windows { forget(&w.own, p) }
	forget(&app.bare.own, p)
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
		fv.host = t.view != nil ? t.view.host : t
		r, ok := frame_box(&t.layout, n.element, viewport, t.scroll)
		if !ok {
			page.frames_set_distance(p, n.element, max(f32))
			page.set_page_visible(child, false)
			continue
		}
		// distance to the viewport (CSS px), for loading=lazy
		vr := lay.rect_shift(r.bounds, -doc_scroll_vec(t))
		dx := max(0, vr.min.x - viewport.x, -vr.max.x)
		dy := max(0, vr.min.y - viewport.y, -vr.max.y)
		page.frames_set_distance(p, n.element, max(dx, dy) / max(scale, 0.01))
		size := draw.Vec2{math.round(r.content.max.x - r.content.min.x), math.round(r.content.max.y - r.content.min.y)}
		fv.transformed = r.transformed
		sc, _ := dom.get_attribute(p.doc, n.element, "scrolling")
		fv.no_scroll = base.ascii_equal_fold(strings.trim_space(sc), "no")
		lay.set_doc_bars_off(&fv.tab.layout, fv.no_scroll)
		if fv.no_scroll {
			fv.tab.scroll = 0
			lay.set_doc_scroll_x(&fv.tab.layout, 0)
		}
		if size.x <= 0 || size.y <= 0 { fv.ready = false; continue }
		page_view_prepare(app, fv, size, scale)
	}
}

////////////////////////////////
// Painting

// The document whose layout is being painted (page_paint sets the tab's; frames push theirs).
frames_paint_begin :: proc(p: ^page.Page) {
	clear(&the_app.paint_stack)
	append(&the_app.paint_stack, p)
}

// Empties the paint stack: for a paint that has no live page under it (an inert document rendered on its own, such as the
// Network tab's HTML preview: with nothing on the stack, frames_paint_content leaves every replaced box to the default
// painter). frames_paint_begin would push a page; this pushes none.
frames_paint_reset :: proc() { clear(&the_app.paint_stack) }

// The content box of a frame element: its document, painted there. False when `node` is not a frame with a document
// ready to paint (the default painter leaves the box empty).
frames_paint_content :: proc(app: ^App, dc: ^draw.Context, d: ^dom.Document, node: base.Handle, content: draw.Rect, container: ^style.Computed) -> bool {
	if len(app.paint_stack) == 0 { return false }
	parent := app.paint_stack[len(app.paint_stack) - 1]
	if parent == nil || parent.doc != d || parent.frames == nil { return false }
	n := page.frame_of_element(parent, node)
	if n == nil || n.page == nil { return false }
	fv := frame_view_of(n.page)
	if fv == nil { return false }
	size := draw.Vec2{math.round(content.max.x - content.min.x), math.round(content.max.y - content.min.y)}
	if size.x <= 0 || size.y <= 0 { return true }
	if !fv.ready || fv.size != size || layout_behind(&fv.tab.layout, n.page.doc) { page_view_prepare(app, fv, size, paint_scale_of(app, parent)) }
	if !fv.ready { return true }
	t := fv.tab
	if !t.layout.valid { return true }
	// a frame's canvas is transparent (Chromium): a background the document gives itself fills it, and so does its
	// canvas color when its color scheme is not its container's (CSS Color Adjust §2.3: dark text of a light document
	// stays readable in a dark page)
	if st := t.page.styled; st != nil {
		mismatch := container != nil && container.used_scheme != st.root_scheme
		if mismatch || canvas_source_box(&t.layout) != lay.NONE { draw.rect(dc, content, to_draw(st.canvas)) }
	}
	page_view_paint(app, dc, fv, content)
	return true
}

// The scale document `p` is painted at: its view's (a frame's, the popup's), else the current tab's.
@(private = "file")
paint_scale_of :: proc(app: ^App, p: ^page.Page) -> f32 {
	if pv := frame_view_of(p); pv != nil && pv.scale > 0 { return pv.scale }
	if pv := ext_popup_view(app); pv != nil && pv.tab.page == p && pv.scale > 0 { return pv.scale }
	return page_scale(app)
}

////////////////////////////////
// Input

// The deepest frame under `pos` (window px) in the document of `t`, and its stand-in tab; nil when none. The target
// comes from the frame's geometry in the page (its content box, with the page scroll, zoom, clips and CSS transforms
// applied), not from the paint state: a frame that was not painted in the last chrome frame (off screen, throttled, or
// simply not repainted this frame) still takes a click that lands on it. A frame with no box (display:none, laid out
// away) is already dropped by frame_box; a destroyed frame has no view.
frame_under :: proc(app: ^App, t: ^Tab, pos: draw.Vec2, rect: draw.Rect) -> ^Page_View {
	if t == nil || t.page == nil || t.page.frames == nil || !t.layout.valid || !draw.rect_contains(rect, pos) { return nil }
	h := hit_test(&t.layout, pos - rect.min, draw.rect_size(rect), t.scroll)
	if h == base.NIL_HANDLE { return nil }
	n := page.frame_of_element(t.page, h)
	if n == nil || n.page == nil { return nil }
	fv := frame_view_of(n.page)
	if fv == nil || !fv.ready { return nil }
	// the frame's content box, in the parent's document coordinates, from the layout hit_test already read
	r, ok := frame_box(&t.layout, n.element, draw.rect_size(rect), t.scroll)
	if !ok { return nil }
	// a box under a transform: its on-screen quad is not axis-aligned; input is not routed (as before), and `rect`
	// would only be its bounds
	if r.transformed || fv.transformed { return nil }
	// document coordinates -> window px: the page scroll is taken off and the page area's origin added (box_of's rects
	// are document coordinates for every box; see blocker_picker.odin, context_menu.odin)
	shift := rect.min - doc_scroll_vec(t)
	screen := draw.Rect{{r.content.min.x + shift.x, r.content.min.y + shift.y}, {r.content.max.x + shift.x, r.content.max.y + shift.y}}
	if !draw.rect_contains(screen, pos) { return nil }
	// routing uses this box as the frame's page area: keep it current even when the frame was not painted this frame
	fv.rect = screen
	if inner := frame_under(app, fv.tab, pos, screen); inner != nil { return inner }
	return fv
}

// A pointer event of the page area over a frame: handled as the page's own input on the frame's view
// (page_view.odin). True when it was a frame's.
frames_route_pointer :: proc(app: ^App, t: ^Tab, ev: platform.Event, index: int) -> bool {
	return page_views_route_pointer(app, t, t, active_window(app).page_rect, nil, ev, index)
}

// The link (<a href>, <area href>) a click target is in.
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
	fv := frames_focused(app)
	if fv == nil { return false }
	return page_view_route_keys(app, fv, ev, index)
}

// The frame document that has the keyboard (the last press went into it), its stand-in tab; nil: the tab's document.
frames_focused :: proc(app: ^App) -> ^Page_View {
	if keyboard_owner(app) != .Frame { return nil }
	fv := frame_view_of(keyboard_of(app).frame)
	if fv == nil || (fv.host != nil && fv.host != current_tab(app)) { return nil }   // (its tab went: keyboard_document comes after the input of this frame)
	return fv
}

// A link followed in a frame's document (its default action): the frame navigates, or the navigable the link's target
// names (`_top` / `_parent` / a frame name; `_blank` opens a tab).
frames_follow_link :: proc(app: ^App, fv: ^Page_View, el: base.Handle, href: string) {
	p := fv.tab.page
	resolved, ok := url.parse(href, &p.env.location, context.temp_allocator)
	if !ok { return }
	if page.follow_fragment_link(p, resolved) { return }
	if page.follow_javascript_url(p, resolved) { return }
	target, _ := dom.get_attribute(p.doc, el, "target")
	if base.ascii_equal_fold(strings.trim_space(target), "_blank") {
		tab_open(app, resolved.href, p)
		return
	}
	n := page.frames_find_target(p, strings.trim_space(target))
	if n == nil { n = page.page_navigable(p) }
	if why := page.frames_navigate_from(p, n, resolved.href, false); why != "" { tab_log(fv.host, .Warn, why) }
}

// A link of a tab's document whose target names one of its frames (or a frame's frame): that frame navigates. False
// for any other target (the tab's own navigation, _blank...).
frames_link_target :: proc(app: ^App, t: ^Tab, clicked: base.Handle, href: string) -> bool {
	p := t.page
	if p == nil || p.frames == nil { return false }
	a, _, ok := frame_anchor(p.doc, clicked)
	if !ok { return false }
	target, _ := dom.get_attribute(p.doc, a, "target")
	target = strings.trim_space(target)
	if target == "" || target[0] == '_' { return false }
	n := page.frames_find_target(p, target)
	if n == nil || n.parent == nil { return false }
	if why := page.frames_navigate_from(p, n, href, false); why != "" { tab_log(t, .Warn, why) }
	return true
}

// A link of a tab's document whose target is _blank, or a name no navigable has: a new window, as window.open makes it
// (page/auxiliary.odin: its rel, the sandbox and the popup filters decide; page_open_window makes the tab). False for
// any other target (the tab itself, _top, _parent, a frame: frames_link_target).
link_opens_window :: proc(p: ^page.Page, clicked: base.Handle, href: string) -> bool {
	a, _, ok := frame_anchor(p.doc, clicked)
	if !ok { return false }
	target, _ := dom.get_attribute(p.doc, a, "target")
	target = strings.trim_space(target)
	if target == "" || base.ascii_equal_fold(target, "_self") { return false }
	rel, _ := dom.get_attribute(p.doc, a, "rel")
	feat := page.link_open_features(rel, target)
	if page.frames_find_target(p, target, feat.noopener) != nil { return false }
	page.auxiliary_open(p, href, target, feat)
	return true
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
		// form submissions of the frame's document (forms_shell.odin takes those that concern frames)
		if c.formctl != nil && c.formctl.embedder.navigate == nil {
			page.set_forms_embedder(c, page.Forms_Embedder{
				user = app, navigate = shell_navigate_submission, pick_files = shell_pick_files, pick_color = shell_pick_color,
				submitting = vault_form_sent,   // vault_save.odin
				changed = proc(user: rawptr, p: ^page.Page) { request_frames((^App)(user), 2) },
			})
		}
		shown := fv.painted + 2 >= app.chrome_frames.frame_no
		page.set_page_visible(c, shown)
		if !shown { continue }
		page.run_animation_frames(c, frame_ms)
		page.canvas_frame(c)   // (WebGL: what was drawn is shown; the elements the document freed go)
		if page.wants_animation_frame(c) || page.animations_active(c) { want = true }
		if fv.tab.layout.mutations != c.doc.mutations { want = true }
		if frames_tick_doc(app, c, frame_ms) { want = true }
	}
	return want
}
