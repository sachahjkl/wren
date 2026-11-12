package browser

// An extension's popup (docs/extensions.md, section 3.8): its page in a panel under its toolbar button, as Chrome shows
// it. The page is a tab of no window (as an offscreen document's), loaded by `navigate`, and shown through a page view
// (page_view.odin) in a toolkit popover. One popup at a time.
//
//   open ── ext_open_popup (a click on the button; a second click on it closes it)
//   size ── ext_popup_frame, in the page phase: laid out at its size, its content measured, the size for the next frame
//           (Popup_Fit: 25 x 25 .. 800 x 600 CSS px); the panel shows once a size held
//   input ── ext_popup_events, before the page's: the keys, and the pointer over it or held by a press in it, are its own
//   close ── Escape, a press outside it, window.close() (page_close_window), another tab shown, its extension
//            disabled, reloaded or removed: ext_popup_close discards its tab
//
// Its size: the panel starts at the smallest size; each layout measures the root element's and the body's boxes (their
// margins counted on both sides) and what overflows the viewport, at the size laid out. The width only grows by what
// overflows (a body of a fixed width), as Chromium's auto-resize takes the document's minimum width; the height follows
// the content. It is fitted again for a few frames after each change of the document, never more: a document whose
// height follows the viewport's cannot make it resize on every frame.

import "core:math"
import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:extensions"
import lay "wb:layout"
import "wb:page"

EXT_POPUP_MIN :: draw.Vec2{25, 25}     // CSS px (Chrome's)
EXT_POPUP_MAX :: draw.Vec2{800, 600}   // CSS px (Chrome's)
// How many frames the popup may change its size in after its document changed (each one lays it out again).
EXT_POPUP_FIT_FRAMES :: 6

Ext_Popup :: struct {
	id:     u64,          // (a draw of the interface finds the popup it was built for)
	ext:    string,       // owned: the extension's id
	view:   Page_View,    // view.tab: its tab, in no window; view.host: the window's tab it was opened over
	window: int,          // the id of the window it is shown in
	anchor: draw.Rect,    // its toolbar button, last built (a press there is the button's: it toggles the popup)
	fit:    Popup_Fit,
	keys:   ^page.Page,   // the document of the popup that has its keyboard: its own, or one of its frames'
}

// The popup's size as its content asks (ext_popup_frame).
Popup_Fit :: struct {
	css:       draw.Vec2,   // the size it is laid out at, CSS px
	shown:     bool,        // a size held once: the panel shows
	left:      int,         // frames it may still change its size in
	mutations: u64,         // the document's mutations it was last fitted for
}

popup_fit_make :: proc() -> Popup_Fit {
	return {css = EXT_POPUP_MIN, left = EXT_POPUP_FIT_FRAMES, mutations = max(u64)}
}

popup_clamp :: proc(content: draw.Vec2) -> draw.Vec2 {
	return {clamp(content.x, EXT_POPUP_MIN.x, EXT_POPUP_MAX.x), clamp(content.y, EXT_POPUP_MIN.y, EXT_POPUP_MAX.y)}
}

// One frame's fit: `content` is what the layout at `f.css` measured (CSS px), `mutations` the document's count. True
// when the size changed (the next frame lays it out at the new one).
popup_fit_step :: proc(f: ^Popup_Fit, content: draw.Vec2, mutations: u64) -> bool {
	if mutations != f.mutations {
		f.mutations = mutations
		f.left = EXT_POPUP_FIT_FRAMES
	}
	if f.left <= 0 { return false }
	f.left -= 1
	want := popup_clamp(content)
	if want == f.css {
		f.shown, f.left = true, 0
		return false
	}
	f.css = want
	if f.left == 0 { f.shown = true }   // (the bound: it shows at the size it got to)
	return true
}

// What an input event is to the open popup. `rect`: where it is shown (empty: not shown yet); `anchor`: its button;
// `captured`: a press in it holds the pointer.
Popup_Route :: enum u8 {
	Pass,         // not the popup's: the page and the interface have it
	Take,         // the popup's document has it
	Close,        // the popup closes, the event goes on (a press outside it acts where it lands)
	Close_Take,   // the popup closes, and that is all the event does (Escape)
}

popup_route :: proc(ev: platform.Event, rect, anchor: draw.Rect, captured: bool) -> Popup_Route {
	shown := rect.max.x > rect.min.x && rect.max.y > rect.min.y
	inside := shown && draw.rect_contains(rect, ev.pos)
	#partial switch ev.kind {
	case .Key_Press:
		if ev.key == .Escape { return .Close_Take }
		return .Take
	case .Key_Release, .Text:
		return .Take   // (the popup has the keyboard while it is open, as Chrome's has the focus)
	case .Mouse_Press:
		if inside { return .Take }
		if draw.rect_contains(anchor, ev.pos) { return .Pass }   // (its button: the click toggles it)
		return .Close
	case .Mouse_Move:
		return inside || captured ? .Take : .Pass
	case .Mouse_Release:
		return captured ? .Take : .Pass   // (a release goes where its press went)
	case .Scroll:
		return inside ? .Take : .Pass
	}
	return .Pass
}

@(private = "file")
popup_physical :: proc(css: draw.Vec2, scale: f32) -> draw.Vec2 {
	return {math.round(css.x * scale), math.round(css.y * scale)}
}

// The popup's view (nil: none is open).
ext_popup_view :: proc(app: ^App) -> ^Page_View {
	if app.ext.popup == nil { return nil }
	return &app.ext.popup.view
}

////////////////////////////////
// Opening and closing

// Opens the extension's popup under its button. A click on the button of the popup that is open closes it.
ext_open_popup :: proc(app: ^App, e: ^extensions.Extension, popup: string) {
	if e.image == nil { return }
	if cur := app.ext.popup; cur != nil {
		same := cur.ext == e.id
		ext_popup_close(app)
		if same { return }
	}
	host := current_tab(app)
	if host == nil { return }
	ep := new(Ext_Popup)
	app.ext.popup_serial += 1
	ep.id = app.ext.popup_serial
	ep.ext = strings.clone(e.id)
	ep.window = active_window(app).id
	ep.fit = popup_fit_make()
	// a tab of no window: made in the window's list (tab_new appends there), then taken out of it at once
	t := tab_new(app)
	list := window_tabs(app, active_window(app))
	if len(list) > 0 && list[len(list) - 1] == t { pop(list) }
	ep.view = Page_View{tab = t, host = host, scale = display_scale_of(app)}
	t.view = &ep.view
	t.top.script_opened = true   // (window.close() of an extension's popup closes it, as in Chrome: page_close_window)
	app.ext.popup = ep
	if !navigate(app, t, extensions.image_url(e.image, popup), origin = .User) {
		ext_popup_close(app)
		return
	}
	request_frames(app, 2)
}

// Closes the popup: its tab goes, and its page scope with it.
ext_popup_close :: proc(app: ^App) {
	ep := app.ext.popup
	if ep == nil { return }
	app.ext.popup = nil
	t := ep.view.tab
	if t.page != nil { page_view_forget(app, t.page) }
	tab_discard(app, t)   // (t.view is still set while it goes: ext_tab_closed reports no tabs.onRemoved for it)
	delete(ep.ext)
	free(ep)
	request_frames(app, 2)
}

// The popup of extension `id` closes (it is disabled, reloaded or removed).
ext_popup_close_of :: proc(app: ^App, id: string) {
	if ep := app.ext.popup; ep != nil && ep.ext == id { ext_popup_close(app) }
}

// window.close() of tab `t` (page_close_window): true when it is the popup's, which closes.
ext_popup_closes :: proc(app: ^App, t: ^Tab) -> bool {
	ep := app.ext.popup
	if ep == nil || ep.view.tab != t { return false }
	ext_popup_close(app)
	return true
}

// Whether document `p` is the popup's or one of its frames'.
@(private = "file")
ext_popup_owns :: proc(ep: ^Ext_Popup, p: ^page.Page) -> bool {
	top := ep.view.tab.page
	if p == nil || top == nil { return false }
	if p == top { return true }
	return frame_view_of(p) != nil && page.page_top(p) == top   // (a frame's view first: `p` is alive)
}

////////////////////////////////
// Each frame

// The page phase of the popup's window: its animation frames, its layout at its size, its size for the next frame.
ext_popup_frame :: proc(app: ^App) {
	ep := app.ext.popup
	if ep == nil || active_window(app).id != ep.window { return }
	// another tab shown in its window: it closes (Chrome's goes with the focus)
	if current_tab(app) != ep.view.host { ext_popup_close(app); return }
	pv := &ep.view
	t := pv.tab
	if t.page == nil || t.page.closed { return }
	frame_ms := pacer_of(app).frame_ms
	nav_arrived(app, t)
	page.set_page_visible(t.page, true)
	page.run_animation_frames(t.page, frame_ms)
	if app.ext.popup != ep { return }
	p := t.page
	if p == nil || p.closed { return }
	if page.wants_animation_frame(p) || page.animations_active(p) { request_frames(app, 2) }
	if frames_tick(app, t, frame_ms) { request_frames(app, 2) }
	scale := display_scale_of(app)
	size := popup_physical(ep.fit.css, scale)
	page_view_prepare(app, pv, size, scale)
	if !pv.ready { return }
	nav_painted(app, t)
	if hold_ended(app, t) { hold_step(app, t, .Over) }
	if popup_fit_step(&ep.fit, ext_popup_content(t, size, scale), p.doc.mutations) { request_frames(app, 2) }
}

// The size the popup's content asks for at a layout of `size` (physical px): CSS px.
@(private = "file")
ext_popup_content :: proc(t: ^Tab, size: draw.Vec2, scale: f32) -> draw.Vec2 {
	l := &t.layout
	p := t.page
	content: draw.Vec2
	if l.doc_width > size.x { content.x = l.doc_width }   // what overflows across
	if l.height > size.y { content.y = l.height }
	for el in ([2]base.Handle{p.doc_el, p.body}) {
		if el == base.NIL_HANDLE { continue }
		r, ok := lay.box_of(l, el, size, 0)
		if !ok { continue }
		// (document coordinates: the margin before it counts after it too)
		content.x = max(content.x, r.bounds.max.x + max(r.bounds.min.x, 0))
		content.y = max(content.y, r.bounds.max.y + max(r.bounds.min.y, 0))
	}
	return content / max(scale, 0.01)
}

////////////////////////////////
// The panel

@(private = "file")
Ext_Popup_Draw :: struct {
	app: ^App,
	id:  u64,
}

// The panel under the button of the popup's extension (ext_button, which gives its rectangle).
ext_popup_build :: proc(app: ^App, anchor: draw.Rect) {
	ep := app.ext.popup
	if ep == nil || active_window(app).id != ep.window { return }
	ep.anchor = anchor
	if !ep.fit.shown || !ep.view.ready { return }
	size := popup_physical(ep.fit.css, ep.view.scale)
	if ui.popover("###ext_popup", anchor, size.x, .Below, true) {
		d := ui.frame_new(Ext_Popup_Draw)
		d.app, d.id = app, ep.id
		ui.next({width = ui.px(size.x), height = ui.px(size.y)})
		b := ui.custom("###ext_popup_page", ext_popup_draw, d, {})
		// (the last layout's place: what input is routed to before the draw sets it again)
		if b.rect.max.x > b.rect.min.x { ep.view.rect = b.rect }
	}
}

@(private = "file")
ext_popup_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Ext_Popup_Draw)(user)
	app := d.app
	ep := app.ext.popup
	if ep == nil || ep.id != d.id { return }
	pv := &ep.view
	t := pv.tab
	r := b.rect
	pv.rect = r
	if t.page == nil { return }
	// (a popup's canvas is opaque, as a window's)
	canvas := draw.WHITE
	if st := t.page.styled; st != nil { canvas = to_draw(st.canvas) }
	draw.rect(dc, r, canvas)
	// (a chrome frame is made while a script runs: the layout of the popup may be what that script is changing)
	if shell_nested() { return }
	if !pv.ready || layout_behind(&t.layout, t.page.doc) { page_view_prepare(app, pv, pv.size, pv.scale) }
	if !pv.ready { return }
	page_view_paint(app, dc, pv, r)
}

////////////////////////////////
// Input

// The window's input, before the page's (frame): what is the popup's goes to its document and is taken out; a press
// outside it and Escape close it.
ext_popup_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	ep := app.ext.popup
	if ep == nil || len(events) == 0 || active_window(app).id != ep.window { return events }
	// (the forms' marks of used events index the list the page gets: what the popup's document marks is not in it)
	fv := forms_view(app)
	marks := slice.clone(fv.consumed[:], context.temp_allocator)
	defer {
		clear(&fv.consumed)
		append(&fv.consumed, ..marks)
	}
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for ev, index in events {
		ep = app.ext.popup
		if ep == nil { append(&out, ev); continue }
		g := gesture_of(app)
		captured := g.owner == .Frame && ext_popup_owns(ep, g.frame)
		rect := ep.fit.shown ? ep.view.rect : draw.Rect{}
		route := popup_route(ev, rect, ep.anchor, captured)
		// (a press the page holds keeps its moves over the popup: a selection dragged across it goes on)
		if ev.kind == .Mouse_Move && !captured && !gesture_free(g) { route = .Pass }
		switch route {
		case .Pass:
			if ev.kind == .Mouse_Move { ext_popup_hover_leave(app, ep) }
			append(&out, ev)
		case .Close:
			ext_popup_close(app)
			append(&out, ev)
		case .Close_Take:
			ext_popup_close(app)
		case .Take:
			ext_popup_input(app, ep, ev, index)
		}
	}
	return out[:]
}

// The pointer left the popup: its :hover goes.
@(private = "file")
ext_popup_hover_leave :: proc(app: ^App, ep: ^Ext_Popup) {
	fi := &window_own(app).frames
	if fi.hover == nil || !ext_popup_owns(ep, fi.hover) { return }
	st := fi.hover.style_state
	st.hover = base.NIL_HANDLE
	page.set_style_state(fi.hover, st)
	fi.hover = nil
}

// The view of the popup's document that has its keyboard.
@(private = "file")
ext_popup_keys :: proc(ep: ^Ext_Popup) -> ^Page_View {
	if p := ep.keys; p != nil && p != ep.view.tab.page {
		if fv := frame_view_of(p); fv != nil && fv.tab.page != nil && page.page_top(fv.tab.page) == ep.view.tab.page { return fv }
	}
	return &ep.view
}

// One event for the popup's document. The window's keyboard is lent to it for the event and given back: the popup's
// presses move its own keyboard (Ext_Popup.keys), not the window's, so the page has it again as it was once the popup
// closes.
@(private = "file")
ext_popup_input :: proc(app: ^App, ep: ^Ext_Popup, ev: platform.Event, index: int) {
	pv := &ep.view
	if pv.tab.page == nil || pv.host == nil { return }
	k := keyboard_of(app)
	keyboard_follow(app)
	was_owner, was_doc := k.owner, k.frame
	keys := ext_popup_keys(ep)
	k.owner, k.frame = .Frame, keys.tab.page
	defer {
		if app.ext.popup == ep && k.owner == .Frame && k.frame != nil { ep.keys = k.frame }
		k.owner, k.frame = was_owner, was_doc
	}
	#partial switch ev.kind {
	case .Key_Press, .Key_Release, .Text:
		page_view_route_keys(app, keys, ev, index)
	case .Mouse_Move, .Mouse_Press, .Mouse_Release, .Scroll:
		gesture_note(app, ev, true)
		if ev.lost { gesture_spent_event(gesture_of(app), ev); return }
		page_views_route_pointer(app, pv.host, pv.tab, pv.rect, pv, ev, index)
	}
}
