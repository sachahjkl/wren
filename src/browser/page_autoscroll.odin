package browser

// Middle-click autoscroll of the page, as Chrome, Firefox and Edge do it on Windows: a press of the wheel on a
// scrollable part of the page drops an anchor, and how far the pointer is from it sets the scroll speed, the farther
// the faster, along an acceleration curve. A marker is drawn at the anchor and the cursor shows the direction.
//
// The mechanism is the toolkit's (ui.Autoscroll, ui/autoscroll.odin): a pure, frame-rate-independent curve and state
// machine. Here Wren drives one session per window against the page's scrollers (smooth_scroll.odin): the scroller
// under the pointer that can move takes the velocity each frame, chained to its parents and the document axis by axis,
// and the session offers the axes any of them can move. It starts only when the page did not cancel the middle-button mousedown (like Chrome: a script that handles the
// auxiliary button keeps it), never on a link (that opens a new tab) nor while a drag, a selection, a context menu or a
// text field is active. about: pages drawn by the toolkit get their own autoscroll from the toolkit; the history tree
// keeps its own middle-button panning (history_tree.odin runs before this).

import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:forms"
import "wb:page"

// Wren's top speed, reached far from the anchor: the two go together, so that the curve near the anchor is the same whatever
// the top (the defaults Wren gives the standard scrolling.autoscroll.max_speed and full_dist: settings.odin).
AUTOSCROLL_TOP_SPEED :: 23250
AUTOSCROLL_FULL_DISTANCE :: 335

// The page's autoscroll is the interface's: the standard scrolling.autoscroll.* (gui_toolkit docs/settings.md), which
// standard_watch gives every window's toolkit state, so that about: pages, the chrome's lists and the developer tools
// scroll with the middle button as the page does.
Autoscroll_Settings_B :: struct {
	enabled: bool,
	cfg:     ui.Autoscroll_Settings,
}

autoscroll_settings_from_prefs :: proc(p: ^config.Prefs) -> Autoscroll_Settings_B {
	return {
		enabled = config.bool_of(p, "scrolling.autoscroll.enabled"),
		cfg = {
			toggle = config.bool_of(p, "scrolling.autoscroll.toggle"),
			dead_zone = f32(config.float_of(p, "scrolling.autoscroll.dead_zone")),
			max_speed = f32(config.float_of(p, "scrolling.autoscroll.max_speed")),
			full_dist = f32(config.float_of(p, "scrolling.autoscroll.full_dist")),
			doubling = f32(config.float_of(p, "scrolling.autoscroll.doubling")),
			tap_ms = f32(config.int_of(p, "scrolling.autoscroll.tap")),
			tap_slop = f32(config.float_of(p, "scrolling.autoscroll.tap_slop")),
		},
	}
}

autoscroll_init :: proc(app: ^App) {
	app.autoscroll_cfg = autoscroll_settings_from_prefs(&app.prefs)
	app.watches[.Autoscroll] = config.watch(&app.prefs, "scrolling.autoscroll.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		(^App)(user).autoscroll_cfg = autoscroll_settings_from_prefs(p)
	}, app)
}

autoscroll_shutdown :: proc(app: ^App) { config.unwatch(&app.prefs, app.watches[.Autoscroll]) }

// The page autoscroll session of one window: the toolkit state, the scroller it drives, and the anchor in window
// pixels (for the marker). `applied` guards against another scroll stealing the scroller (as smooth_tick does).
Page_Autoscroll :: struct {
	auto:    ui.Autoscroll,
	node:    base.Handle,
	is_doc:  bool,          // the scroller is the document (NIL handle); kept apart from a real NIL node
	anchor:  draw.Vec2,     // window pixels
}

// A middle-button press on the page: tries to start a session. `allowed` is false when the page cancelled the mousedown
// (then nothing starts, like Chrome). `pressed` is the hit element. Returns true when a session started (the press must
// not do anything else). Never starts over a link (that opens a new tab), nor while a text field, selection or menu is
// busy.
autoscroll_page_press :: proc(app: ^App, t: ^Tab, ev: platform.Event, pressed: base.Handle, allowed: bool) -> bool {
	if !app.autoscroll_cfg.enabled || !allowed || t.page == nil || !t.layout.valid { return false }
	wnd := active_window(app)
	if !draw.rect_contains(wnd.page_rect, ev.pos) { return false }
	if ui.menu_any_open() { return false }
	// a link opens a new tab instead (handled by the release path); do not autoscroll over it
	if _, ok := anchor_href(t.page.doc, pressed); ok { return false }
	// not while the pointer is in a text field or over a scroll bar (scrollbar_press ran first and returned)
	if p := t.page; p.formctl != nil {
		f := page.page_forms(p)
		for cur := pressed; cur != base.NIL_HANDLE; cur = forms.parent_element(f, cur) {
			if forms.is_text_field(f, cur) { return false }
		}
	}
	// the scroller under the pointer that can move, and the axes it offers (chained to the document)
	p := ev.pos - wnd.page_rect.min
	node, can_x, can_y, is_doc, found := scroller_axes_under(app, t, p)
	if !found { return false }
	axes: ui.Autoscroll_Axes = .Y
	switch {
	case can_x && can_y: axes = .Both
	case can_x:          axes = .X
	case:                axes = .Y
	}
	ps := &gesture_take(app, t, .Autoscroll, .Middle).autoscroll
	ps.node = node
	ps.is_doc = is_doc
	ps.anchor = ev.pos
	ui.autoscroll_begin(&ps.auto, ev.pos, axes, held = true, now_ms = frame_now_ms())
	request_frames(app, 2)
	return true
}

// The owner Autoscroll's events (route_page_input): a wheel notch, Escape or the pointer leaving the window end the session; the release of the
// middle button ends hold mode, a tap latches; any press ends a latched session, and that press is swallowed (it only ends autoscroll, as the
// browsers do). True when the event was the session's.
autoscroll_page_event :: proc(app: ^App, ev: platform.Event, index: int) -> bool {
	took := autoscroll_event(app, ev)
	if took && ev.kind == .Key_Press { consume(app, index) }
	return took
}

// What an event does to the session, in a full frame or a chrome frame (shell_frames.odin).
autoscroll_event :: proc(app: ^App, ev: platform.Event) -> bool {
	g := gesture_of(app)
	#partial switch ev.kind {
	case .Key_Press:
		if ev.key != .Escape { return false }
		gesture_cancel(app)
		return true
	case .Mouse_Leave, .Scroll:
		gesture_cancel(app)
	case .Mouse_Press:
		if !ui.autoscroll_click(&g.autoscroll.auto) { return false }
		gesture_end(g)
		return true
	case .Mouse_Release:
		if ev.button != .Middle || !(g.autoscroll.auto.phase == .Holding) { return false }
		if !ui.autoscroll_release(&g.autoscroll.auto, app.autoscroll_cfg.cfg, frame_now_ms()) { gesture_end(g) }
		request_frames(app, 2)
		return true
	}
	return false
}

// Every frame before smooth_tick: feeds the pointer, and scrolls the node by the velocity integrated against the
// frame's dt (CSS px per second -> device px this frame). True while a session is live (the loop keeps drawing).
// How far a frame moves the page: CSS px/s over the time the frame really took, in device px (smooth_scroll's; +y toward the end).
// The time of a frame, not the screen's period: a page that scrolls at 60 frames on a 180 Hz screen would go at a third of its speed.
autoscroll_frame_delta :: proc(vel: draw.Vec2, seconds: f32, scale: f32) -> draw.Vec2 { return vel * seconds * scale }

autoscroll_tick :: proc(app: ^App, t: ^Tab) -> bool {
	g := gesture_of(app)
	if g.owner != .Autoscroll { return false }
	ps := &g.autoscroll
	wnd := active_window(app)
	// (the pointer leaving the window is a Mouse_Leave, which ends the session; mouse_valid is not polled here, as the chrome's
	// toolkit state may briefly report it false right after an injected press)
	if !t.layout.valid { gesture_cancel(app); return false }
	pos := wnd.ui.mouse   // the window's toolkit state tracks the pointer in window pixels (same events as the page)
	ui.autoscroll_point(&ps.auto, pos)
	vel := ui.autoscroll_velocity(&ps.auto, app.autoscroll_cfg.cfg)   // CSS px / s
	scale := max(page_scale(app), 0.01)
	if vel != {} {
		node := ps.is_doc ? base.NIL_HANDLE : ps.node
		// Instant: the curve here is the smoothing; what the scroller has no room for goes to those around it
		scroll_chain_by(app, t, node, autoscroll_frame_delta(vel, frame_seconds(app), scale))
	}
	request_frames(app, 2)
	return true
}

// The session moves the page: a chrome frame is wanted though no input comes.
autoscroll_moves :: proc(app: ^App) -> bool {
	g := gesture_of(app)
	return g.owner == .Autoscroll && ui.autoscroll_velocity(&g.autoscroll.auto, app.autoscroll_cfg.cfg) != {}
}

// A chrome frame, under a page that keeps the thread: the session goes on, as the wheel does, on what the frame shows; the
// document and the containers take the position at the page's turn (shell_take_scroll).
autoscroll_chrome_frame :: proc(app: ^App) {
	g := gesture_of(app)
	t := current_tab(app)
	if g.owner != .Autoscroll || t == nil || t != g.tab || t.page != g.top { return }
	ps := &g.autoscroll
	ui.autoscroll_point(&ps.auto, active_window(app).ui.mouse)
	vel := ui.autoscroll_velocity(&ps.auto, app.autoscroll_cfg.cfg)
	if vel == {} { return }
	shell_chain_by(app, t, ps.is_doc ? base.NIL_HANDLE : ps.node, autoscroll_frame_delta(vel, frame_seconds(app), max(page_scale(app), 0.01)))
}

// The cursor the session asks for (over the page area); .Arrow when none is active.
autoscroll_page_cursor :: proc(app: ^App) -> (platform.Cursor, bool) {
	g := gesture_of(app)
	if g.owner != .Autoscroll { return .Arrow, false }
	return ui.autoscroll_cursor(&g.autoscroll.auto, app.autoscroll_cfg.cfg), true
}

// Draws the anchor marker over everything (window pixels). Called after the UI tree and the page are composed.
autoscroll_paint :: proc(app: ^App, dc: ^draw.Context) {
	g := gesture_of(app)
	if g.owner != .Autoscroll { return }
	ps := &g.autoscroll
	st := active_window(app).ui
	plate := ui.color_from_tags(st, 0, "background")
	ink := ui.color_from_tags(st, 0, "text")
	ui.autoscroll_draw_marker(dc, ps.anchor, ps.auto.axes, ui.scale_of(st), plate, ink)
}
