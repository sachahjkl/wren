package browser

import "core:testing"
import "wb:config"

// The App of a test with no App of its own: made by the browser's own stages (app_make.odin) up to its loop, the thread's (the_app,
// its Pages bound), freed with the test. What the code reaches without an App (the painting, the hooks) is this one.
test_app :: proc(t: ^testing.T) -> ^App {
	app := app_make()
	app_loop_init(app)   // (the timers the painting sets)
	// what the painting reads, at the preferences' defaults (app_start reads them from the profile's)
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	register_all_prefs(&prefs)
	app.compositor_settings = compositor_settings_from_prefs(&prefs)
	app.effects_settings = effects_settings_from_prefs(&prefs)
	app.fx_settings = fx_settings_from_prefs(&prefs)
	app.plane_settings = plane_settings_from_prefs(&prefs)
	app.gradient_dither = render_settings_from_prefs(&prefs).dither
	testing.cleanup(t, proc(p: rawptr) { app_free((^App)(p)) }, app)
	return app
}
