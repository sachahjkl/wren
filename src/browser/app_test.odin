package browser

import "core:testing"
import "wb:config"
import "wb:host"
import "wb:page"

// The App of a test with no App of its own: made, the thread's (the_app, its Pages bound), with a loop, freed with the test. What the code reaches
// without an App (the painting, the hooks) is this one.
test_app :: proc(t: ^testing.T) -> ^App {
	app := new(App)
	the_app = app
	page.bind(&app.pages)
	host.loop_init(&app.loop)   // (the timers the painting sets)
	// what the painting reads, at the preferences' defaults (app_start reads them from the profile's)
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	register_all_prefs(&prefs)
	app.compositor_settings = compositor_settings_from_prefs(&prefs)
	app.effects_settings = effects_settings_from_prefs(&prefs)
	app.fx_settings = fx_settings_from_prefs(&prefs)
	app.plane_settings = plane_settings_from_prefs(&prefs)
	app.gradient_dither = render_settings_from_prefs(&prefs).dither
	testing.cleanup(t, proc(p: rawptr) {
		app := (^App)(p)
		if the_app == app { the_app = nil }
		page.bind(nil)
		host.loop_destroy(&app.loop)
		free(app)
	}, app)
	return app
}
