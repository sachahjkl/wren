package e2e

// Input while a page keeps the browser's thread (browser/busy_input.odin): steps taken one per chrome frame, in order, from the
// next long script on. A page that holds its thread until innerWidth changes (examples/site/busy_probe.html hold()) lets go at the
// `busy_resize` step; the steps before it, and the pictures of the `busy_capture` ones, all happen under it.

import "wb:browser"

Busy_Step :: browser.Busy_Step

busy_move :: proc(s: ^Session, at: Point, space := Space.Page) -> Busy_Step {
	context = s.ctx
	return {kind = .Event, ev = {kind = .Mouse_Move, pos = browser.control_point(s.app, at, space)}}
}

busy_press :: proc(s: ^Session, at: Point, space := Space.Page, button := Button.Left) -> Busy_Step {
	context = s.ctx
	return {kind = .Event, ev = {kind = .Mouse_Press, pos = browser.control_point(s.app, at, space), button = browser.control_button(button)}}
}

busy_release :: proc(s: ^Session, at: Point, space := Space.Page, button := Button.Left) -> Busy_Step {
	context = s.ctx
	return {kind = .Event, ev = {kind = .Mouse_Release, pos = browser.control_point(s.app, at, space), button = browser.control_button(button)}}
}

// The wheel at a point: `notches` positive goes down.
busy_wheel :: proc(s: ^Session, notches: f64, at: Point, space := Space.Page) -> Busy_Step {
	context = s.ctx
	return {kind = .Event, ev = {kind = .Scroll, pos = browser.control_point(s.app, at, space), delta = {0, f32(notches)}}}
}

// A key ("PageDown", "Ctrl+Tab") going down, or up: two steps for a press.
busy_key :: proc(s: ^Session, combo: string, down: bool, loc := #caller_location) -> Busy_Step {
	context = s.ctx
	key, mods, ok := browser.parse_combo(combo)
	if !ok { failed(s, combo, loc) }
	return {kind = .Event, ev = {kind = down ? .Key_Press : .Key_Release, key = key, mods = mods}}
}

busy_capture :: proc() -> Busy_Step { return {kind = .Capture} }

// Chrome frames until `ms` have passed (what moves by the clock under the task moves meanwhile).
busy_wait :: proc(ms: f64) -> Busy_Step { return {kind = .Wait, ms = ms} }

// From the next chrome frame on, until the steps run out, the page's animations are shown `ms` after its last frame (the time its
// timeline last moved to, page.animations_wall_ms): a clock the test sets, with no wait and whatever the machine's speed.
busy_clock :: proc(ms: f64) -> Busy_Step { return {kind = .Clock, ms = ms} }

busy_resize :: proc(size: [2]int) -> Busy_Step { return {kind = .Resize, size = size} }

// The steps go to the chrome frames to come; returns at once (a barrier, wait_js on what the page sets once it let go, runs them).
while_busy :: proc(s: ^Session, steps: []Busy_Step, loc := #caller_location) {
	for st in steps { if st.kind == .Capture { need_pixels(s, "busy_capture", loc); break } }
	context = s.ctx
	enter(s, loc)
	browser.control_busy_input(s.app, steps)
}

// Steps not taken yet.
busy_left :: proc(s: ^Session, loc := #caller_location) -> int {
	context = s.ctx
	enter(s, loc)
	return browser.control_busy_left(s.app)
}

// The pictures of the capture steps taken so far, in order (the window as each of those chrome frames drew it: window pixels).
busy_shots :: proc(s: ^Session, loc := #caller_location) -> []Image {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	shots := browser.control_busy_shots(s.app)
	defer { for sh in shots { delete(sh.rgba) }; delete(shots) }
	out := make([]Image, len(shots), back)
	for sh, i in shots {
		rgba := make([]u8, len(sh.rgba), back)
		copy(rgba, sh.rgba)
		out[i] = {rgba, sh.size.x, sh.size.y}
	}
	return out
}
