package browser

// The extension popup's pure parts (ext_popup.odin): its size from its content, and what each input event is to it.

import "core:testing"
import "toolkit:draw"
import "toolkit:platform"

@(test)
ext_popup_clamps_its_size :: proc(t: ^testing.T) {
	testing.expect_value(t, popup_clamp({0, 0}), EXT_POPUP_MIN)
	testing.expect_value(t, popup_clamp({312, 140}), draw.Vec2{312, 140})
	testing.expect_value(t, popup_clamp({5000, 5000}), EXT_POPUP_MAX)
	testing.expect_value(t, popup_clamp({10, 900}), draw.Vec2{25, 600})
}

@(test)
ext_popup_fits_its_content_then_shows :: proc(t: ^testing.T) {
	f := popup_fit_make()
	testing.expect(t, !f.shown, "it does not show before a layout measured it")
	// the first layout, at the smallest size, finds a body of 312 px; the next one, at that width, its height
	testing.expect(t, popup_fit_step(&f, {312, 400}, 7))
	testing.expect_value(t, f.css, draw.Vec2{312, 400})
	testing.expect(t, !f.shown, "a size that just changed is not shown")
	testing.expect(t, popup_fit_step(&f, {312, 140}, 7))
	testing.expect(t, !popup_fit_step(&f, {312, 140}, 7), "the same size: it holds")
	testing.expect(t, f.shown)
	// nothing changed in the document: no more fitting, whatever the layout says
	testing.expect(t, !popup_fit_step(&f, {500, 500}, 7))
	testing.expect_value(t, f.css, draw.Vec2{312, 140})
	// the document changed: it fits again, still shown
	testing.expect(t, popup_fit_step(&f, {312, 200}, 8))
	testing.expect(t, f.shown)
	testing.expect_value(t, f.css, draw.Vec2{312, 200})
}

// The test that breaks a size fitted to its own layout: a document whose height follows the viewport's (100vh + 1 px)
// asks for more at every size. It stops after EXT_POPUP_FIT_FRAMES frames and shows.
@(test)
ext_popup_fit_is_bounded :: proc(t: ^testing.T) {
	f := popup_fit_make()
	resized := 0
	for _ in 0 ..< 100 {
		if popup_fit_step(&f, {300, f.css.y + 1}, 3) { resized += 1 }
	}
	testing.expect_value(t, resized, EXT_POPUP_FIT_FRAMES)
	testing.expect(t, f.shown)
}

@(test)
ext_popup_routes_input :: proc(t: ^testing.T) {
	rect := draw.Rect{{100, 50}, {400, 300}}
	anchor := draw.Rect{{380, 10}, {410, 40}}
	ev :: proc(kind: platform.Event_Kind, pos: [2]f32, key := platform.Key.None) -> platform.Event { return {kind = kind, pos = pos, key = key} }

	// the keyboard is the popup's; Escape closes it and goes nowhere else
	testing.expect_value(t, popup_route(ev(.Key_Press, {0, 0}, .A), rect, anchor, false), Popup_Route.Take)
	testing.expect_value(t, popup_route(ev(.Text, {0, 0}), rect, anchor, false), Popup_Route.Take)
	testing.expect_value(t, popup_route(ev(.Key_Press, {0, 0}, .Escape), rect, anchor, false), Popup_Route.Close_Take)
	// a press in it is its own; on its button, the button's (it toggles); anywhere else it closes it and acts there
	testing.expect_value(t, popup_route(ev(.Mouse_Press, {200, 100}), rect, anchor, false), Popup_Route.Take)
	testing.expect_value(t, popup_route(ev(.Mouse_Press, {395, 20}), rect, anchor, false), Popup_Route.Pass)
	testing.expect_value(t, popup_route(ev(.Mouse_Press, {600, 500}), rect, anchor, false), Popup_Route.Close)
	// moves: over it, or anywhere while a press in it holds the pointer; a release: where its press went
	testing.expect_value(t, popup_route(ev(.Mouse_Move, {600, 500}), rect, anchor, false), Popup_Route.Pass)
	testing.expect_value(t, popup_route(ev(.Mouse_Move, {600, 500}), rect, anchor, true), Popup_Route.Take)
	testing.expect_value(t, popup_route(ev(.Mouse_Release, {600, 500}), rect, anchor, true), Popup_Route.Take)
	testing.expect_value(t, popup_route(ev(.Mouse_Release, {200, 100}), rect, anchor, false), Popup_Route.Pass)   // (its press was elsewhere)
	testing.expect_value(t, popup_route(ev(.Scroll, {200, 100}), rect, anchor, false), Popup_Route.Take)
	testing.expect_value(t, popup_route(ev(.Scroll, {600, 500}), rect, anchor, false), Popup_Route.Pass)
	// not shown yet (no rectangle): a press anywhere but its button closes it
	testing.expect_value(t, popup_route(ev(.Mouse_Press, {200, 100}), {}, anchor, false), Popup_Route.Close)
}
