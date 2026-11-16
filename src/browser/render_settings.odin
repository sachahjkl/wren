package browser

import "toolkit:render"
import config "../../ext/gui_toolkit/src/config"

////////////////////////////////
// How the window's colors are mixed: the blend space of the renderer and the text's coverage correction are the toolkit's
// standard settings (appearance.text.blend_space, curve, gamma, contrast, coverage_exponent), applied by standard_watch; Wren's
// defaults of them are in settings.odin. One space for the whole window: the chrome and the page are drawn into the same target.
// Web content wants sRGB (CSS Color 4, Compositing 1: translucent colors, opacity, antialiasing, gradients and images mix on sRGB
// values in every browser); the toolkit's theme adapts its translucent colors to it (ui.apply_palette, ui.tuned). Text uses
// Skia's correction with Chromium's values on Windows (Skia built with SK_GAMMA_SRGB and SK_GAMMA_CONTRAST=1.0): the same weight
// in both spaces, and the weight Edge shows (measured on the same page: within 2 %). Wren's own settings here are the gradients'
// dither and the swap chain's slack.

@(private)
Render_Settings :: struct {
	space: render.Blend_Space,     // what a renderer made apart (a test's) starts with: the App's follows standard_watch
	text:  render.Text_Rendering,
	dither: bool,
	resize_slack: int,
}

RENDER_PREFS := [?]config.Def{
	{name = "render.gradients.dither", kind = .Bool, default = {b = true},
		description = "Add noise of one 8-bit level to CSS gradients so that slow color ramps show no bands (as Chromium's Skia does). Off: exact colors, possible banding."},
	{name = "render.swap_chain.resize_slack_px", kind = .Int, default = {i = render.DEFAULT_RESIZE_SLACK}, bounded = true, min = 0, max = 2048, value_kind = .Length,
		description = "Room the window's frame buffers keep to grow, per axis. Resizing the window within it only changes the region shown (no reallocation, which costs 1.5 to 3.5 ms a step); the buffers are reallocated once per this many pixels crossed, and made smaller when they hold more than twice the pixels shown. 0: buffers of the exact window size, reallocated at every step."},
}

register_render_prefs :: proc(p: ^config.Prefs) {
	config.register(p, RENDER_PREFS[:])
	config.register(p, COMPOSITOR_PREFS[:])
}

// (the blend space and the text's correction from the standard settings: a renderer that standard_watch does not reach, a
// test's, starts as the App's does)
@(private)
render_settings_from_prefs :: proc(p: ^config.Prefs) -> Render_Settings {
	curve := render.Text_Curve.Srgb
	switch config.string_of(p, "appearance.text.curve") {
	case "power": curve = .Power
	case "none": curve = .None
	}
	return Render_Settings{
		space = config.string_of(p, "appearance.text.blend_space") == "linear" ? .Linear : .Srgb,
		text = {
			curve = curve,
			gamma = f32(config.float_of(p, "appearance.text.gamma")),
			contrast = f32(config.float_of(p, "appearance.text.contrast")),
			coverage_exponent = f32(config.float_of(p, "appearance.text.coverage_exponent")),
		},
		dither = config.bool_of(p, "render.gradients.dither"),
		resize_slack = int(config.int_of(p, "render.swap_chain.resize_slack_px")),
	}
}

// Applies Wren's own preferences to the renderer, then follows them. The blend space and the text's correction are
// standard_watch's: a change of space keeps existing textures (decoded images) in the space they were stored in, converted when
// drawn; the theme follows at the next frame (ui.apply_palette).
@(private)
render_settings_init :: proc(app: ^App) {
	render_settings_apply(app, render_settings_from_prefs(&app.prefs))
	app.watches[.Render] = config.watch(&app.prefs, "render.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		a := (^App)(user)
		render_settings_apply(a, render_settings_from_prefs(p))
		request_frames(a, 2)
	}, app)
}

@(private)
render_settings_apply :: proc(app: ^App, s: Render_Settings) {
	app.render_settings = s
	app.gradient_dither = s.dither
	app.compositor_settings = compositor_settings_from_prefs(&app.prefs)
	render.set_resize_slack(&app.r, s.resize_slack)
}
