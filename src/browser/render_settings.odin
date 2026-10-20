package browser

import "toolkit:render"
import "wb:config"

////////////////////////////////
// How the window's colors are mixed (render.*): the blend space of the renderer and the text's coverage correction.
// One space for the whole window: the chrome and the page are drawn into the same target. Web content wants sRGB
// (CSS Color 4, Compositing 1: translucent colors, opacity, antialiasing, gradients and images mix on sRGB values in
// every browser); the toolkit's theme adapts its translucent colors to it (ui.apply_palette, ui.tuned). Text uses
// Skia's correction with Chromium's values on Windows (Skia built with SK_GAMMA_SRGB and SK_GAMMA_CONTRAST=1.0): the
// same weight in both spaces, and the weight Edge shows (measured on the same page: within 2 %).

@(private)
Render_Settings :: struct {
	space: render.Blend_Space,
	text:  render.Text_Rendering,
	dither: bool,
	resize_slack: int,
}

RENDER_PREFS := [?]config.Def{
	{name = "render.blend_space", kind = .String, default = {s = "srgb"}, choices = {"srgb", "linear"},
		description = "Where colors are mixed (translucent colors, opacity, antialiased edges, gradients, image filtering). srgb: on sRGB values, as every web browser does (50 % black over white is 128). linear: in linear light, physically correct but lighter than the web expects (188)."},
	{name = "render.text.curve", kind = .String, default = {s = "srgb"}, choices = {"srgb", "power", "none"},
		description = "Text coverage correction (Skia's): how the edges of glyphs are blended. srgb: as in linear light, Chromium's choice on Windows and macOS. power: in a space of exponent render.text.gamma over sRGB values (Chromium on Linux: 1.2). none: coverage blended as it is in the blend space (no correction, render.text.contrast ignored)."},
	{name = "render.text.gamma", kind = .Float, default = {f = 1.2}, bounded = true, min = 0.25, max = 4,
		description = "Exponent of the text correction when render.text.curve is power."},
	{name = "render.text.contrast", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 1,
		description = "Text contrast enhancement (Skia's): thickens dark text on light backgrounds, fading out for light text on dark ones. Chromium on Windows: 1.0 (0.5 before Chrome 132)."},
	{name = "render.text.coverage_exponent", kind = .Float, default = {f = 1}, bounded = true, min = 0.25, max = 4,
		description = "Glyph coverage is raised to this power before the correction: below 1 thickens all text, above 1 thins it."},
	{name = "render.gradients.dither", kind = .Bool, default = {b = true},
		description = "Add noise of one 8-bit level to CSS gradients so that slow color ramps show no bands (as Chromium's Skia does). Off: exact colors, possible banding."},
	{name = "render.swap_chain.resize_slack_px", kind = .Int, default = {i = render.DEFAULT_RESIZE_SLACK}, bounded = true, min = 0, max = 2048, unit = "px",
		description = "Room the window's frame buffers keep to grow, per axis. Resizing the window within it only changes the region shown (no reallocation, which costs 1.5 to 3.5 ms a step); the buffers are reallocated once per this many pixels crossed, and made smaller when they hold more than twice the pixels shown. 0: buffers of the exact window size, reallocated at every step."},
}

@(private) render_settings: Render_Settings
@(private) render_watch: int

register_render_prefs :: proc(p: ^config.Prefs) {
	config.register(p, RENDER_PREFS[:])
	config.register(p, COMPOSITOR_PREFS[:])
}

@(private)
render_settings_from_prefs :: proc(p: ^config.Prefs) -> Render_Settings {
	curve := render.Text_Curve.Srgb
	switch config.string_of(p, "render.text.curve") {
	case "power": curve = .Power
	case "none": curve = .None
	}
	return Render_Settings{
		space = config.string_of(p, "render.blend_space") == "linear" ? .Linear : .Srgb,
		text = {
			curve = curve,
			gamma = f32(config.float_of(p, "render.text.gamma")),
			contrast = f32(config.float_of(p, "render.text.contrast")),
			coverage_exponent = f32(config.float_of(p, "render.text.coverage_exponent")),
		},
		dither = config.bool_of(p, "render.gradients.dither"),
		resize_slack = int(config.int_of(p, "render.swap_chain.resize_slack_px")),
	}
}

// Applies the preferences to the renderer, then follows them. Existing textures (decoded images) keep the space they
// were stored in and are converted when drawn; the theme follows at the next frame (ui.apply_palette).
@(private)
render_settings_init :: proc(app: ^App) {
	render_settings_apply(app, render_settings_from_prefs(&app.prefs))
	render_watch = config.watch(&app.prefs, "render.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		a := (^App)(user)
		render_settings_apply(a, render_settings_from_prefs(p))
		a.frames_requested = max(a.frames_requested, 2)
	}, app)
}

@(private)
render_settings_apply :: proc(app: ^App, s: Render_Settings) {
	render_settings = s
	gradient_dither = s.dither
	compositor_settings = compositor_settings_from_prefs(&app.prefs)
	render.set_blend_space(&app.r, s.space)
	render.set_text_rendering(&app.r, s.text)
	render.set_resize_slack(&app.r, s.resize_slack)
}
