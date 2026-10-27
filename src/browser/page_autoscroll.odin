package browser

// Middle-click autoscroll of the page, as Chrome, Firefox and Edge do it on Windows: a press of the wheel on a
// scrollable part of the page drops an anchor, and how far the pointer is from it sets the scroll speed, the farther
// the faster, along an acceleration curve. A marker is drawn at the anchor and the cursor shows the direction.
//
// The mechanism is the toolkit's (ui.Autoscroll, ui/autoscroll.odin): a pure, frame-rate-independent curve and state
// machine. Here Wren drives one session per window against the page's scrollers (smooth_scroll.odin): the scroller
// under the pointer that can move takes the velocity each frame, chained to its parents and the document as the wheel
// is. It starts only when the page did not cancel the middle-button mousedown (like Chrome: a script that handles the
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

AUTOSCROLL_PREFS := [?]config.Def{
	{name = "browser.scroll.autoscroll.enabled", kind = .Bool, default = {b = true},
		description = "A press of the middle mouse button (the wheel) on the page starts autoscroll: moving the pointer away from where it was pressed scrolls, the farther the faster. Press again, Escape or a wheel notch ends it."},
	{name = "browser.scroll.autoscroll.max_speed", kind = .Float, default = {f = 2800}, bounded = true, min = 100, max = 20000, unit = "px/s",
		description = "The fastest autoscroll goes, in CSS pixels per second, reached when the pointer is 'full distance' past the dead zone."},
	{name = "browser.scroll.autoscroll.dead_zone", kind = .Float, default = {f = 12}, bounded = true, min = 0, max = 200, unit = "px",
		description = "No scrolling while the pointer is within this many pixels of the anchor (a still disc around it)."},
	{name = "browser.scroll.autoscroll.full_distance", kind = .Float, default = {f = 420}, bounded = true, min = 20, max = 4000, unit = "px",
		description = "How far past the dead zone the pointer must be for autoscroll to reach its top speed."},
	{name = "browser.scroll.autoscroll.curve", kind = .Float, default = {f = 2}, bounded = true, min = 0.2, max = 6,
		description = "Shape of the speed curve: 1 is linear, above 1 is gentle near the anchor and steep far out, below 1 the opposite."},
	{name = "browser.scroll.autoscroll.mode", kind = .String, default = {s = "both"}, choices = {"both", "hold", "toggle"},
		description = "both: a quick tap latches the mode on until the next click, and holding the button scrolls while it is down. hold: only while the button is held. toggle: a press latches it on until the next click."},
}

register_autoscroll_prefs :: proc(p: ^config.Prefs) { config.register(p, AUTOSCROLL_PREFS[:]) }

Autoscroll_Settings_B :: struct {
	enabled: bool,
	cfg:     ui.Autoscroll_Settings,
}

autoscroll_settings_from_prefs :: proc(p: ^config.Prefs) -> Autoscroll_Settings_B {
	mode := config.string_of(p, "browser.scroll.autoscroll.mode")
	cfg := ui.DEFAULT_AUTOSCROLL
	cfg.max_speed = f32(config.float_of(p, "browser.scroll.autoscroll.max_speed"))
	cfg.dead_zone = f32(config.float_of(p, "browser.scroll.autoscroll.dead_zone"))
	cfg.full_dist = f32(config.float_of(p, "browser.scroll.autoscroll.full_distance"))
	cfg.exponent  = f32(config.float_of(p, "browser.scroll.autoscroll.curve"))
	// "hold": no latching tap; "toggle": a press always latches (tap time unbounded); "both": the default tap test
	switch mode {
	case "hold":   cfg.toggle = false
	case "toggle": cfg.toggle = true; cfg.tap_ms = 1e9; cfg.tap_slop = 1e9
	case:          cfg.toggle = true
	}
	return {enabled = config.bool_of(p, "browser.scroll.autoscroll.enabled"), cfg = cfg}
}

autoscroll_cfg: Autoscroll_Settings_B
@(private = "file") autoscroll_watch: int

autoscroll_init :: proc(app: ^App) {
	autoscroll_cfg = autoscroll_settings_from_prefs(&app.prefs)
	autoscroll_watch = config.watch(&app.prefs, "browser.scroll.autoscroll.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		autoscroll_cfg = autoscroll_settings_from_prefs(p)
		autoscroll_toolkit_sync_all((^App)(user))
	}, app)
	autoscroll_toolkit_sync_all(app)
}

// Applies the enabled flag and the curve to one toolkit state, so its scroll regions (about: pages, the chrome's own
// lists, the developer tools) autoscroll with the same settings as the page (ui/autoscroll_region.odin).
autoscroll_toolkit_setup :: proc(st: ^ui.State) {
	if st == nil { return }
	ui.set_autoscroll_enabled(st, autoscroll_cfg.enabled)
	ui.set_autoscroll_settings(st, autoscroll_cfg.cfg)
}

// Re-applies the settings to every window's toolkit state and its detached developer tools (a pref changed, or startup).
autoscroll_toolkit_sync_all :: proc(app: ^App) {
	for w in app.windows {
		autoscroll_toolkit_setup(w.ui)
		if dw := w.own.devtools.win; dw != nil { autoscroll_toolkit_setup(&dw.ui) }
	}
	autoscroll_toolkit_setup(app.bare.ui)
}

autoscroll_shutdown :: proc(app: ^App) { config.unwatch(&app.prefs, autoscroll_watch) }

// The page autoscroll session of one window: the toolkit state, the scroller it drives, and the anchor in window
// pixels (for the marker). `applied` guards against another scroll stealing the scroller (as smooth_tick does).
Page_Autoscroll :: struct {
	auto:    ui.Autoscroll,
	node:    base.Handle,
	is_doc:  bool,          // the scroller is the document (NIL handle); kept apart from a real NIL node
	anchor:  draw.Vec2,     // window pixels
	tab:     rawptr,        // the tab the session scrolls; a different one ends it
}

autoscroll_running_page :: proc(app: ^App) -> bool { return window_own(app).autoscroll.auto.active }

// A middle-button press on the page: tries to start a session. `allowed` is false when the page cancelled the mousedown
// (then nothing starts, like Chrome). `pressed` is the hit element. Returns true when a session started (the press must
// not do anything else). Never starts over a link (that opens a new tab), nor while a text field, selection or menu is
// busy.
autoscroll_page_press :: proc(app: ^App, t: ^Tab, ev: platform.Event, pressed: base.Handle, allowed: bool) -> bool {
	if !autoscroll_cfg.enabled || !allowed || t.page == nil || !t.layout.valid { return false }
	wnd := active_window(app)
	if !draw.rect_contains(wnd.page_rect, ev.pos) { return false }
	if ui.ctx_menu_any_open() { return false }
	// a link opens a new tab instead (handled by the release path); do not autoscroll over it
	if _, ok := anchor_href(t.page.doc, pressed); ok { return false }
	// not while the pointer is in a text field or over a scroll bar (scrollbar_event ran first and returned)
	if p := t.page; p.formctl != nil {
		f := page.page_forms(p)
		for cur := pressed; cur != base.NIL_HANDLE; cur = forms.parent_element(f, cur) {
			if forms.is_text_field(f, cur) { return false }
		}
	}
	// the scroller under the pointer that can move, and the axes it offers (chained to the document)
	ps := &wnd.own.autoscroll
	p := ev.pos - wnd.page_rect.min
	node, can_x, can_y, is_doc, found := scroller_axes_under(app, t, p)
	if !found { return false }
	axes: ui.Autoscroll_Axes = .Y
	switch {
	case can_x && can_y: axes = .Both
	case can_x:          axes = .X
	case:                axes = .Y
	}
	ps.node = node
	ps.is_doc = is_doc
	ps.tab = t.page
	ps.anchor = ev.pos
	ui.autoscroll_begin(&ps.auto, ev.pos, axes, held = true, now_ms = frame_now_ms())
	request_frames(app, 2)
	return true
}

// The release of the middle button: a tap latches toggle mode on, otherwise hold mode ends. `wheel` ends the session
// (handled in the wheel case). Returns true when the event was the session's.
autoscroll_page_release :: proc(app: ^App, ev: platform.Event) -> bool {
	ps := &window_own(app).autoscroll
	if !ps.auto.active || ev.button != .Middle || !ps.auto.held { return false }
	if !ui.autoscroll_release(&ps.auto, autoscroll_cfg.cfg, frame_now_ms()) { autoscroll_end(app) }
	request_frames(app, 2)
	return true
}

// Any other press ends a latched session, and that press is swallowed (it only ends autoscroll, as the browsers do).
autoscroll_page_click :: proc(app: ^App) -> bool {
	ps := &window_own(app).autoscroll
	if ui.autoscroll_click(&ps.auto) { autoscroll_end(app); return true }
	return false
}

// A wheel notch, Escape, lost capture or a window move ends the session.
autoscroll_page_cancel :: proc(app: ^App) {
	ps := &window_own(app).autoscroll
	if ps.auto.active { autoscroll_end(app) }
}

@(private = "file")
autoscroll_end :: proc(app: ^App) {
	ps := &window_own(app).autoscroll
	ui.autoscroll_cancel(&ps.auto)
	ps.node = base.NIL_HANDLE
	ps.is_doc = false
	ps.tab = nil
}

// Every frame before smooth_tick: feeds the pointer, and scrolls the node by the velocity integrated against the
// frame's dt (CSS px per second -> device px this frame). True while a session is live (the loop keeps drawing).
autoscroll_tick :: proc(app: ^App, t: ^Tab) -> bool {
	ps := &window_own(app).autoscroll
	if !ps.auto.active { return false }
	wnd := active_window(app)
	// the page went away, or its tab changed: end it (the pointer leaving the window is a Mouse_Leave,
	// which route_page_input turns into autoscroll_page_cancel; mouse_valid is not polled here, as the chrome's
	// toolkit state may briefly report it false right after an injected press)
	if t == nil || t.page == nil || rawptr(t.page) != ps.tab || !t.layout.valid {
		autoscroll_end(app); return false
	}
	pos := wnd.ui.mouse   // the window's toolkit state tracks the pointer in window pixels (same events as the page)
	ui.autoscroll_point(&ps.auto, pos)
	vel := ui.autoscroll_velocity(&ps.auto, autoscroll_cfg.cfg)   // CSS px / s
	scale := max(page_scale(app), 0.01)
	dt := pacer_of(app).period_ms / 1000.0
	if vel != {} {
		node := ps.is_doc ? base.NIL_HANDLE : ps.node
		// CSS px/s -> device px this frame; smooth_scroll takes device px (+y toward the end)
		delta := draw.Vec2{f32(f64(vel.x) * dt) * scale, f32(f64(vel.y) * dt) * scale}
		smooth_scroll_by(app, t, node, delta, 0)   // instant: the curve here is the smoothing
	}
	request_frames(app, 2)
	return true
}

// The cursor the session asks for (over the page area); .Arrow when none is active.
autoscroll_page_cursor :: proc(app: ^App) -> (platform.Cursor, bool) {
	ps := &window_own(app).autoscroll
	if !ps.auto.active { return .Arrow, false }
	return ui.autoscroll_cursor(&ps.auto, autoscroll_cfg.cfg), true
}

// Draws the anchor marker over everything (window pixels). Called after the UI tree and the page are composed.
autoscroll_paint :: proc(app: ^App, dc: ^draw.Context) {
	ps := &window_own(app).autoscroll
	if !ps.auto.active { return }
	st := active_window(app).ui
	plate := ui.color_from_tags(st, 0, "background")
	ink := ui.color_from_tags(st, 0, "text")
	ui.autoscroll_draw_marker(dc, ps.anchor, ps.auto.axes, ui.scale_of(st), plate, ink)
}
