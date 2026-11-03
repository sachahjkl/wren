package e2e

// What a window says beyond e2e.odin: what the system hears from it, what each frame of a drag drew, what a screen reader is told.

import "toolkit:platform"
import "wb:browser"
import "wb:remote/api"

Drag_Sample :: api.Drag_Sample
Cursor_Shown :: api.Cursor_Shown
Surface :: api.Surface
Hit :: platform.Hit
A11y_Entry :: browser.A11y_Entry

// What a point of the window (window pixels) is to the system: what its window procedure answers WM_NCHITTEST from.
hit_test :: proc(s: ^Session, at: Point, loc := #caller_location) -> Hit {
	context = s.ctx
	enter(s, loc)
	return browser.control_hit_test(s.app, {f32(at.x), f32(at.y)})
}

// What each frame of a drag held drew, since the last call of `drag_samples_reset` (browser.frame.drag_probe=true).
drag_samples :: proc(s: ^Session) -> []Drag_Sample { return browser.control_drag_samples(s.test.temp_allocator) }
drag_samples_reset :: proc(s: ^Session) { browser.control_drag_samples_reset() }

// From now on the window makes what it tells a screen reader, whether or not one reads it.
a11y_capture :: proc(s: ^Session, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	browser.control_a11y_capture(s.app, true)
}

// What the window's last frame tells a screen reader: the chrome's nodes, its page's, its frames'.
a11y_tree :: proc(s: ^Session, loc := #caller_location) -> []A11y_Entry {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_a11y_tree(s.app, back)
}

// As if a screen reader had asked it of that node (`r`'s action and its data): done once its frames are.
a11y_act :: proc(s: ^Session, e: A11y_Entry, r: platform.A11y_Request, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_a11y_act(s.app, &c, e, r), "a11y_act", loc)
}
