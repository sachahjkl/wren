package browser

// Touch screens, the shell's part (the page's events: page_input.odin route_device_pointer):
//   * what pages are told about the pointing devices (touch_devices_apply: navigator.maxTouchPoints, ontouchstart and
//     the Touch* constructors, the media features pointer / any-pointer / hover / any-hover), from the toolkit's
//     platform.input_devices and browser.touch.expose;
//   * a finger pans the page (the scroller under it, else the document) instead of selecting text, and a quick one
//     glides on (a fling, through smooth_scroll.odin); two fingers zoom the page as Ctrl+wheel does (zoom_step); a long
//     press opens the context menu (contextmenu first); a tap is a click (the compatibility mouse events, from the
//     shell: the system's own emulation of a finger is dropped, a pen keeps it). touch-action of the element touched and
//     its ancestors says which of those the browser may do; a cancelled touchstart or touchmove (before the pan began),
//     or touchend for the tap, leaves the gesture to the page.
// The gesture itself is the toolkit's (platform.Touch_Gesture, pure); what to scroll and how far is decided by pure
// procedures here (touch_scroll_delta, touch_blocked_along, touch_pinch_steps), tested in touch_shell_test.odin.

import "core:time"
import "toolkit:platform"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:js"
import "wb:page"
import "wb:style"

TOUCH_PREFS := [?]config.Def{
	{name = "browser.touch.pan_slop_px", kind = .Float, default = {f = 10}, bounded = true, min = 1, max = 200, unit = "px",
		description = "How far a finger moves (CSS pixels) before the touch is a pan that scrolls rather than a tap or a long press."},
	{name = "browser.touch.long_press_ms", kind = .Int, default = {i = 500}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "A finger held still this long opens the context menu (0: never)."},
	{name = "browser.touch.fling", kind = .Bool, default = {b = true},
		description = "A pan released while the finger still moves glides on, slowing down."},
	{name = "browser.touch.fling_friction", kind = .Float, default = {f = 4}, bounded = true, min = 0.5, max = 100, unit = "1/s",
		description = "How fast a fling slows down: its speed falls by e every 1/friction seconds (larger: a shorter glide)."},
	{name = "browser.touch.fling_min_speed", kind = .Float, default = {f = 150}, bounded = true, min = 0, max = 100_000, unit = "px/s",
		description = "Slower than this when the finger leaves, a pan just stops."},
	{name = "browser.touch.pinch_step", kind = .Float, default = {f = 1.15}, bounded = true, min = 1.01, max = 4,
		description = "How much two fingers must spread (or close) for the page to zoom one step, as one notch of Ctrl+wheel."},
}

register_touch_prefs :: proc(p: ^config.Prefs) { config.register(p, TOUCH_PREFS[:]) }

// The devices pages are told about (at start and when browser.touch.expose changes).
touch_devices_apply :: proc(app: ^App) {
	d := platform.input_devices()
	js.set_touch_points(d.touch_points)
	points, _ := js.touch_exposure(config.string_of(&app.prefs, "browser.touch.expose"), d.touch_points)
	shown := d
	shown.touch_points = points
	style.set_pointer_caps(pointer_caps_of(shown))
	prefs_apply_counts[.Touch] += 1
}

// The media features' view of a set of devices. Pure.
pointer_caps_of :: proc(d: platform.Input_Devices) -> style.Pointer_Caps {
	acc, hover := platform.primary_pointer(d)
	fine, coarse, any_hover := platform.any_pointer(d)
	return style.Pointer_Caps{fine = acc == .Fine, none = acc == .None, hover = hover, any_fine = fine, any_coarse = coarse, any_hover = any_hover}
}

// What the browser may not do with fingers on `h`: what the touch-action of it and of each ancestor forbids (CSS
// "the intersection of the allowed actions" along the way). Pure over the styles.
touch_blocked_along :: proc(p: ^page.Page, h: base.Handle) -> style.Touch_Blocked {
	out: style.Touch_Blocked
	if p == nil || p.doc == nil || p.styled == nil { return out }
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil { break }
		if n.kind == .Element { if cs := style.style_of(p.styled, cur); cs != nil { out += cs.touch_action } }
		cur = n.parent
	}
	return out
}

// The axes a gesture may scroll, from the scroll its first move asks for (`first`: the content follows the finger, so
// a finger going right scrolls left) and touch-action: pan-left lets a gesture that starts by scrolling left go on along
// x (in both directions, as the standard says: the direction only decides whether it may start), pan-x either way. An
// axis the first move does not use goes when either of its directions is allowed. Pure.
touch_pan_axes :: proc(first: [2]f32, blocked: style.Touch_Blocked) -> (x, y: bool) {
	axis :: proc(v: f32, back, fwd: style.Touch_Gesture, blocked: style.Touch_Blocked) -> bool {
		switch {
		case v < 0: return back not_in blocked
		case v > 0: return fwd not_in blocked
		}
		return back not_in blocked || fwd not_in blocked
	}
	return axis(first.x, .Pan_Left, .Pan_Right, blocked), axis(first.y, .Pan_Up, .Pan_Down, blocked)
}

// How a finger's pan scrolls: the content follows the finger (the scroll moves the other way), on the axes the gesture
// may use (touch_pan_axes). Pure.
touch_scroll_delta :: proc(pan: [2]f32, x_ok, y_ok: bool) -> [2]f32 {
	d := -pan
	if !x_ok { d.x = 0 }
	if !y_ok { d.y = 0 }
	return d
}

// Zoom steps out of a pinch: the spread since the last step accumulates in `acc`; each time it passes `step` (or
// 1/step) a step is taken (+1 bigger, -1 smaller) and it starts again. Pure.
touch_pinch_steps :: proc(acc: ^f32, scale, step: f32) -> int {
	acc^ *= scale
	n := 0
	for acc^ >= step { acc^ /= step; n += 1 }
	for acc^ <= 1 / step { acc^ *= step; n -= 1 }
	return n
}

@(private = "file")
Touch_Shell :: struct {
	g:         platform.Touch_Gesture,
	tab:       ^Tab,
	page:      ^page.Page,
	blocked:   style.Touch_Blocked,
	x_ok, y_ok: bool,      // the axes this gesture may scroll (decided by its first move: touch_pan_axes)
	cancelled: bool,       // a touch event of this gesture was cancelled: the page has it
	panned:    bool,
	pinch:     f32,
	last:      [2]f32,     // the first finger (window px)
	scroller:  base.Handle,
	hit:       base.Handle,
}

@(private = "file")
tsh: Touch_Shell

@(private = "file")
now_ms :: proc() -> f64 { return f64(time.tick_now()._nsec) / 1e6 }

// A finger's event (route_device_pointer, after its pointer and touch events): `allowed` = its touch event was not
// cancelled. True when the shell took it for a gesture.
touch_pointer :: proc(app: ^App, t: ^Tab, ev: platform.Event, hit: base.Handle, allowed: bool) {
	if ev.pointer.kind != .Touch || t.page == nil { return }
	p := t.page
	scale := max(page_scale(app), 0.01)
	if !platform.touch_gesture_active(&tsh.g) && ev.kind == .Pointer_Down {
		s := platform.TOUCH_GESTURE_DEFAULTS
		s.slop = f32(config.float_of(&app.prefs, "browser.touch.pan_slop_px")) * scale
		s.long_press_ms = f64(config.int_of(&app.prefs, "browser.touch.long_press_ms"))
		s.fling_min_speed = f32(config.float_of(&app.prefs, "browser.touch.fling_min_speed")) * scale
		platform.touch_gesture_init(&tsh.g, s)
		tsh.tab, tsh.page, tsh.cancelled, tsh.panned, tsh.pinch, tsh.hit = t, p, false, false, 1, hit
		tsh.blocked = touch_blocked_along(p, hit)
		tsh.scroller = base.NIL_HANDLE
	}
	if tsh.page != p { return }
	// touchstart, and touchmove until the pan began, may keep the gesture for the page
	if !allowed && (ev.kind == .Pointer_Down || (ev.kind == .Pointer_Move && !tsh.panned)) { tsh.cancelled = true }
	if !allowed && ev.kind == .Pointer_Up { tsh.cancelled = true }
	ms := now_ms()
	ge: platform.Touch_Gesture_Event
	#partial switch ev.kind {
	case .Pointer_Down: ge = platform.touch_gesture_down(&tsh.g, ev.pointer.id, ev.pos, ms)
	case .Pointer_Move: ge = platform.touch_gesture_move(&tsh.g, ev.pointer.id, ev.pos, ms)
	case .Pointer_Up: ge = platform.touch_gesture_up(&tsh.g, ev.pointer.id, ev.pos, ms)
	case .Pointer_Cancel: ge = platform.touch_gesture_cancel(&tsh.g)
	}
	touch_apply(app, t, ge)
	if platform.touch_gesture_active(&tsh.g) { app.frames_requested = max(app.frames_requested, 2) }
}

// Every frame (dnd_events): a finger held still becomes a long press.
touch_frame :: proc(app: ^App) {
	if !platform.touch_gesture_active(&tsh.g) || tsh.tab == nil { return }
	t := tsh.tab
	if t != current_tab(app) || t.page != tsh.page { platform.touch_gesture_cancel(&tsh.g); return }
	touch_apply(app, t, platform.touch_gesture_tick(&tsh.g, now_ms()))
	app.frames_requested = max(app.frames_requested, 2)
}

@(private = "file")
touch_apply :: proc(app: ^App, t: ^Tab, ge: platform.Touch_Gesture_Event) {
	if ge.kind == .None || t.page == nil { return }
	p := t.page
	switch ge.kind {
	case .None:
	case .Pan, .Pinch:
		tsh.panned = true
		if tsh.cancelled { return }
		if ge.kind == .Pinch && .Pinch_Zoom not_in tsh.blocked {
			if n := touch_pinch_steps(&tsh.pinch, ge.scale, f32(config.float_of(&app.prefs, "browser.touch.pinch_step"))); n != 0 {
				for _ in 0 ..< abs(n) { zoom_step(app, t, n > 0 ? 1 : -1) }
			}
		}
		if ge.first { tsh.x_ok, tsh.y_ok = touch_pan_axes(-ge.pan, tsh.blocked) }
		d := touch_scroll_delta(ge.pan, tsh.x_ok, tsh.y_ok)
		if d != {} { tsh.scroller = touch_scroll(app, t, ge.pos - app.page_rect.min, d) }
	case .Fling:
		if tsh.cancelled || !config.bool_of(&app.prefs, "browser.touch.fling") { return }
		dist, ms := platform.touch_fling(ge.velocity, f32(config.float_of(&app.prefs, "browser.touch.fling_friction")))
		d := touch_scroll_delta(dist, tsh.x_ok, tsh.y_ok)
		if d != {} && ms > 0 { smooth_scroll_by(app, t, tsh.scroller, d, ms) }
	case .Tap:
		if tsh.cancelled { return }
		// the compatibility mouse events of a tap, through the window's queue as the mouse's (marked emulated: no
		// second set of pointer events)
		for kind in ([]platform.Event_Kind{.Mouse_Move, .Mouse_Press, .Mouse_Release}) {
			b := kind == .Mouse_Press ? platform.Mouse_Buttons{.Left} : platform.Mouse_Buttons{}
			platform.inject_event(app.win, platform.Event{kind = kind, pos = ge.pos, button = .Left, buttons = b, emulated = true})
		}
		app.frames_requested = max(app.frames_requested, 3)
	case .Long_Press:
		if tsh.cancelled { return }
		local := ge.pos - app.page_rect.min + {0, t.scroll}
		page_context_press(app, t, ge.pos)
		if t.page == p { page_context_menu(app, t, tsh.hit, ge.pos, local, false) }
	case .End:
	}
}

// The system's mouse emulation of a finger: dropped (the shell makes the tap's own; a pan must not select text).
touch_drop_emulated :: proc(ev: platform.Event) -> bool {
	#partial switch ev.kind {
	case .Mouse_Move, .Mouse_Press, .Mouse_Release: return ev.emulated && ev.pointer.kind == .Touch
	}
	return false
}
