package browser

import "toolkit:font"
import "wb:config"
import "wb:host"

////////////////////////////////
// Text rendering and shaping (toolkit:font on DirectWrite): glyph bitmaps, the atlas, color glyphs, the system fallback
// and the shaped-word cache, plus the generic families the style settings do not map. The whole window shares one font
// state (chrome and pages).

FONT_PREFS := [?]config.Def{
	{name = "font.raster.subpixel_positions", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 4,
		description = "Horizontal positions of a glyph within a pixel that get their own bitmap (1: glyphs snap to whole pixels; 4: quarter pixels, as Chromium does with DirectWrite). More positions keep the spacing of the layout exactly, at the cost of more bitmaps in the atlas."},
	{name = "font.raster.mode", kind = .String, default = {s = "natural_symmetric"}, choices = {"natural_symmetric", "natural", "gdi_classic", "aliased"},
		description = "DirectWrite rendering mode of glyph bitmaps (grayscale antialiasing). natural_symmetric: smoothed horizontally and vertically (Chromium, Edge). natural: horizontal smoothing only. gdi_classic: GDI-like hinted shapes. aliased: no antialiasing."},
	{name = "font.raster.grid_fit", kind = .String, default = {s = "default"}, choices = {"default", "enabled", "disabled"},
		description = "Hinting of glyph outlines to the pixel grid: default (DirectWrite chooses by size), enabled, disabled."},
	{name = "font.color_glyphs", kind = .Bool, default = {b = true},
		description = "Draw color glyphs in color: emoji and color fonts in every format (COLR v0 layers, COLR v1 gradients and paint trees, sbix / CBDT / PNG bitmaps, OT-SVG), drawn by Direct2D. Off: their outline in the text color."},
	{name = "font.color_glyphs.async", kind = .Bool, default = {b = true},
		description = "Draw color glyphs on a thread of their own: a page shows its text at once and each emoji appears when it is drawn (a complex emoji takes a few milliseconds). Off: a frame waits for the color glyphs it shows."},
	{name = "font.fallback.system", kind = .Bool, default = {b = true},
		description = "Characters no font of the font-family list has (and no face of the page) come from the fonts Windows picks for them (DirectWrite's system fallback: symbols, CJK, emoji, Arabic...). Off: they show the missing-glyph box of the first font."},
	{name = "font.atlas.page_size", kind = .Int, default = {i = 2048}, bounded = true, min = 256, max = 8192, unit = "px", restart = true,
		description = "Side of a glyph atlas page (texture), in texels."},
	{name = "font.atlas.gray_pages", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 64,
		description = "Coverage pages of the glyph atlas kept before the least recently used one is cleared for new glyphs (a page a frame still draws from is never cleared: one more is made). Each page takes font.atlas.page_size² bytes of video memory and as much of main memory."},
	{name = "font.atlas.color_pages", kind = .Int, default = {i = 2}, bounded = true, min = 1, max = 64,
		description = "Color pages (emoji) of the glyph atlas kept before the least recently used one is reused; 4 bytes per texel."},
	{name = "font.shape_cache_words", kind = .Int, default = {i = 32768}, bounded = true, min = 0, max = 10_000_000,
		description = "Shaped words kept by the text cache (the layout measures the same words over and over, from several threads). 0: shape every word every time."},
	{name = "text.renderer", kind = .String, default = {s = "slug"}, choices = {"atlas", "slug"},
		description = "How glyphs reach the screen. atlas: bitmaps rasterized by DirectWrite (hinted, cached per size and subpixel position). slug: the Slug algorithm (Eric Lengyel) draws each glyph from its outline curves on the GPU, with no bitmaps: sharp at any page zoom, rotation or transform, and exact subpixel positions. Color glyphs (emoji) always use the atlas."},
	{name = "text.slug.pages", kind = .Int, default = {i = 128}, bounded = true, min = 1, max = 2048,
		description = "Glyph pages of the Slug renderer kept before the least recently used one is reused (a page a frame still draws from is never reused: one more is made). A page holds about a hundred Latin glyphs; each takes 48 KB of video memory (as much of main memory), up to 6 MB at the default."},
	{name = "text.slug.tolerance", kind = .Float, default = {f = 0.25}, bounded = true, min = 0.015, max = 16, unit = "1/1000 em",
		description = "Slug: the largest distance between a cubic outline (CFF / OpenType fonts) and the quadratic curves drawn instead, in thousandths of the em (0.25: a hundredth of a pixel at 40 px). TrueType outlines are quadratic already and are never approximated."},
	{name = "font.family.emoji", kind = .String, default = {s = "Segoe UI Emoji"}, description = "Font used for the generic family `emoji`."},
	{name = "font.family.math", kind = .String, default = {s = "Cambria Math"}, description = "Font used for the generic family `math`."},
	{name = "font.family.fangsong", kind = .String, default = {s = "FangSong"}, description = "Font used for the generic family `fangsong`."},
}

register_font_prefs :: proc(p: ^config.Prefs) { config.register(p, FONT_PREFS[:]) }

font_settings_from_prefs :: proc(p: ^config.Prefs) -> font.Settings {
	s := font.DEFAULT_SETTINGS
	if config.ref_of(p, "font.raster.mode") == config.NO_REF { return s }   // not registered (tests)
	s.subpixel_steps = int(config.int_of(p, "font.raster.subpixel_positions"))
	switch config.string_of(p, "font.raster.mode") {
	case "natural": s.rendering = .Natural
	case "gdi_classic": s.rendering = .Gdi_Classic
	case "aliased": s.rendering = .Aliased
	case: s.rendering = .Natural_Symmetric
	}
	switch config.string_of(p, "font.raster.grid_fit") {
	case "enabled": s.grid_fit = .Enabled
	case "disabled": s.grid_fit = .Disabled
	case: s.grid_fit = .Default
	}
	s.color_glyphs = config.bool_of(p, "font.color_glyphs")
	s.color_async = config.bool_of(p, "font.color_glyphs.async")
	s.system_fallback = config.bool_of(p, "font.fallback.system")
	s.page_size = int(config.int_of(p, "font.atlas.page_size"))
	s.max_gray_pages = int(config.int_of(p, "font.atlas.gray_pages"))
	s.max_color_pages = int(config.int_of(p, "font.atlas.color_pages"))
	s.word_cache = int(config.int_of(p, "font.shape_cache_words"))
	s.text_renderer = config.string_of(p, "text.renderer") == "slug" ? .Slug : .Atlas
	s.slug_pages = int(config.int_of(p, "text.slug.pages"))
	s.slug_tolerance = f32(config.float_of(p, "text.slug.tolerance")) / 1000
	return s
}

@(private) font_watch, text_watch: int

// Follows the preferences: glyph bitmaps are made again with new rendering settings, layouts again when what text
// measures may change (the system fallback), the generic families are resolved again.
font_settings_init :: proc(app: ^App) {
	font_generics_apply(app)
	// color glyphs drawn on their thread: a frame shows them (host.post wakes the loop from any thread)
	font.set_color_ready_callback(&app.fonts, proc(user: rawptr) {
		a := (^App)(user)
		host.post(&a.loop, proc(data: rawptr) { app := (^App)(data); app.frames_requested = max(app.frames_requested, 2) }, a)
	}, app)
	font_watch = config.watch(&app.prefs, "font.", font_prefs_changed, app)
	text_watch = config.watch(&app.prefs, "text.", font_prefs_changed, app)
}

@(private)
font_prefs_changed :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	a := (^App)(user)
	old := a.fonts.settings
	s := font_settings_from_prefs(p)
	font.set_settings(&a.fonts, s)
	if s.subpixel_steps != old.subpixel_steps || s.rendering != old.rendering || s.grid_fit != old.grid_fit || s.color_glyphs != old.color_glyphs {
		font.clear_atlas(&a.fonts)
	}
	if s.system_fallback != old.system_fallback {
		font.clear_word_cache(&a.fonts)
		for t in a.tabs { t.layout.valid = false }
	}
	font_generics_apply(a)
	a.frames_requested = max(a.frames_requested, 2)
}

@(private)
font_generics_apply :: proc(app: ^App) {
	if config.ref_of(&app.prefs, "font.family.emoji") == config.NO_REF { return }
	page_fonts_set_generics(&page_render.fonts, config.string_of(&app.prefs, "font.family.emoji"),
		config.string_of(&app.prefs, "font.family.math"), config.string_of(&app.prefs, "font.family.fangsong"))
}
