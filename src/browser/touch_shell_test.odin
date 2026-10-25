package browser

import "core:testing"
import "toolkit:platform"
import "wb:style"

// A write of a preference of the interface configures nothing of the network again (prefs_apply.odin).
@(test)
pref_writes_reach_their_subsystem_only :: proc(t: ^testing.T) {
	testing.expect_value(t, pref_groups_of("browser.tabs.sidebar_width"), Pref_Groups{})
	testing.expect_value(t, pref_groups_of("browser.ui.theme"), Pref_Groups{})
	testing.expect_value(t, pref_groups_of("network.timeout.connect_ms"), Pref_Groups{.Net})
	testing.expect_value(t, pref_groups_of("network.cache.memory.max_bytes"), Pref_Groups{.Http_Cache})
	testing.expect_value(t, pref_groups_of("browser.download.directory"), Pref_Groups{.Downloads})
	testing.expect_value(t, pref_groups_of("browser.touch.expose"), Pref_Groups{.Touch})
	testing.expect_value(t, pref_groups_of(""), PREF_GROUPS_ALL)
	testing.expect_value(t, pref_groups_of("browser.appearance"), Pref_Groups{})
}

@(test)
finger_gestures_to_scrolling_and_zoom :: proc(t: ^testing.T) {
	// the content follows the finger: a finger going up scrolls down
	testing.expect_value(t, touch_scroll_delta({3, -40}, true, true), [2]f32{-3, 40})
	testing.expect_value(t, touch_scroll_delta({3, -40}, false, true), [2]f32{0, 40})
	// the axes a gesture may use, from its first scroll and touch-action
	NONE :: style.Touch_Blocked{.Pan_Left, .Pan_Right, .Pan_Up, .Pan_Down, .Pinch_Zoom, .Double_Tap}
	x, y := touch_pan_axes({-3, 40}, {})
	testing.expect(t, x && y, "auto: both")
	x, y = touch_pan_axes({-3, 40}, {.Pan_Left, .Pan_Right})   // pan-y
	testing.expect(t, !x && y)
	x, y = touch_pan_axes({0, 40}, NONE)
	testing.expect(t, !x && !y, "none")
	// pan-left: a gesture that starts by scrolling left goes on along x, one that starts by scrolling right does not
	PAN_LEFT :: style.Touch_Blocked{.Pan_Right, .Pan_Up, .Pan_Down, .Pinch_Zoom, .Double_Tap}
	x, y = touch_pan_axes({-5, 0}, PAN_LEFT)
	testing.expect(t, x && !y, "pan-left, starting left")
	x, y = touch_pan_axes({5, 0}, PAN_LEFT)
	testing.expect(t, !x && !y, "pan-left, starting right")
	// pan-down pan-right: up and left refused
	DR :: style.Touch_Blocked{.Pan_Left, .Pan_Up, .Pinch_Zoom, .Double_Tap}
	x, y = touch_pan_axes({4, 6}, DR)
	testing.expect(t, x && y)
	x, y = touch_pan_axes({4, -6}, DR)
	testing.expect(t, x && !y)
	// a pinch zooms one step each time the fingers spread by the step
	acc: f32 = 1
	testing.expect_value(t, touch_pinch_steps(&acc, 1.1, 1.15), 0)
	testing.expect_value(t, touch_pinch_steps(&acc, 1.1, 1.15), 1)
	testing.expect_value(t, touch_pinch_steps(&acc, 1 / 1.4, 1.15), -2)
	// the media features of the devices
	c := pointer_caps_of({mouse = true})
	testing.expect(t, c.fine && c.hover && !c.any_coarse && !c.none)
	c = pointer_caps_of({mouse = true, touch_points = 10})
	testing.expect(t, c.fine && c.hover && c.any_coarse && c.any_fine)
	c = pointer_caps_of({touch_points = 5})
	testing.expect(t, !c.fine && !c.hover && c.any_coarse && !c.any_hover)
	c = pointer_caps_of({})
	testing.expect(t, c.none)
	// a finger's mouse emulation is dropped, a pen's is kept
	testing.expect(t, touch_drop_emulated(platform.Event{kind = .Mouse_Press, emulated = true, pointer = {kind = .Touch}}))
	testing.expect(t, !touch_drop_emulated(platform.Event{kind = .Mouse_Press, emulated = true, pointer = {kind = .Pen}}))
	testing.expect(t, !touch_drop_emulated(platform.Event{kind = .Mouse_Press}))
}
