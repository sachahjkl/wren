package browser

import "core:testing"
import config "toolkit:config"
import "toolkit:platform"
import "wb:fetch"
import "wb:page"
import "wb:style"

// A write of a preference of the interface configures nothing of the network, cache, downloads, or touch subsystems (prefs_apply.odin).
@(test)
pref_writes_reach_their_subsystem_only :: proc(t: ^testing.T) {
	app := test_app(t)
	app_prefs_init(app)
	app_loop_init(app)
	app.page_settings = page.settings_from_prefs(&app.prefs)
	defer page.settings_destroy(&app.page_settings)
	defer fetch.profile_destroy(&app.profile)
	prefs_bind_runtime(app)

	zero: [Pref_Group]int
	testing.expect_value(t, app.prefs_apply_counts, zero)

	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.tabs.sidebar_width", "260", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, zero)

	testing.expect_value(t, config.set_from_string(&app.prefs, "appearance.theme", "Ember", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, zero)

	testing.expect_value(t, config.set_from_string(&app.prefs, "network.timeout.connect_ms", "9000", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, #partial [Pref_Group]int{.Net = 1})

	testing.expect_value(t, config.set_from_string(&app.prefs, "network.cache.memory.max_bytes", "67108864", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, #partial [Pref_Group]int{.Net = 1, .Http_Cache = 1})

	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.download.directory", "tmp-dl", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, #partial [Pref_Group]int{.Net = 1, .Http_Cache = 1, .Downloads = 1})
	testing.expect_value(t, app.dls.cfg.dir, "tmp-dl")

	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.touch.expose", "on", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, [Pref_Group]int{.Net = 1, .Http_Cache = 1, .Downloads = 1, .Touch = 1})
	testing.expect_value(t, app.tsh.cfg.expose, "on")

	testing.expect_value(t, app.page_settings.webcodecs.enabled, true)
	testing.expect_value(t, config.set_from_string(&app.prefs, "webcodecs.enabled", "false", .User), config.Set_Error.None)
	testing.expect_value(t, app.page_settings.webcodecs.enabled, false)
	testing.expect_value(t, app.prefs_apply_counts, [Pref_Group]int{.Net = 1, .Http_Cache = 1, .Downloads = 1, .Touch = 1})
}

// While a chrome frame runs under a page (shell_nested), engine preference changes defer instead of mutating live settings.
@(test)
pref_writes_defer_while_shell_nested :: proc(t: ^testing.T) {
	app := test_app(t)
	app_prefs_init(app)
	app_loop_init(app)
	defer page.settings_destroy(&app.page_settings)
	defer fetch.profile_destroy(&app.profile)
	defer shell_frames_destroy(app)
	prefs_bind_runtime(app)

	testing.expect_value(t, app.profile.jar.settings.enabled, true)
	app.chrome_frames.nested = true
	testing.expect_value(t, config.set_from_string(&app.prefs, "network.timeout.connect_ms", "8000", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&app.prefs, "cookies.enabled", "false", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.touch.expose", "off", .User), config.Set_Error.None)
	testing.expect_value(t, app.prefs_apply_counts, [Pref_Group]int{})
	testing.expect_value(t, app.profile.jar.settings.enabled, true)
	testing.expect(t, .Net in app.prefs_deferred && .Fetch in app.prefs_deferred && .Cookies in app.prefs_deferred && .Touch in app.prefs_deferred, "deferred groups must be recorded")
	testing.expect_value(t, len(app.chrome_frames.actions), 1)
	testing.expect_value(t, app.chrome_frames.actions[0].kind, Shell_Action_Kind.Prefs)

	app.chrome_frames.nested = false
	prefs_flush_deferred(app)
	testing.expect_value(t, app.prefs_deferred, Pref_Deferred_Set{})
	testing.expect_value(t, app.profile.jar.settings.enabled, false)
	testing.expect_value(t, app.prefs_apply_counts, #partial [Pref_Group]int{.Net = 1, .Touch = 1})
}

@(test)
finger_gestures_to_scrolling_and_zoom :: proc(t: ^testing.T) {
	test_app(t)
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
