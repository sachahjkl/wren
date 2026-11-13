package browser

import "core:strings"
import "toolkit:font"
import "wb:config"
import "wb:host"
import "wb:style"

////////////////////////////////
// Text rendering and shaping (toolkit:font on DirectWrite): glyph bitmaps, the atlas, color glyphs, the system fallback
// and the shaped-word cache, plus the generic families the style settings do not map. The whole window shares one font
// state (chrome and pages).

// The text settings every program has are the toolkit's (prefs_page's Text set: appearance.text.*, standard_watch applies their
// changes). These are Wren's own: the text backend, its emoji engine, the families pages ask for by a generic name. Wren
// registers appearance.text.renderer before the toolkit's set, for its own default (Slug): the toolkit's is the atlas.
FONT_PREFS := [?]config.Def{
	{name = "appearance.text.renderer", kind = .String, default = {s = "slug"}, choices = {"atlas", "slug"},
		description = "How glyphs reach the screen. atlas: bitmaps rasterized by DirectWrite (hinted, cached per size and subpixel position). slug: the Slug algorithm (Eric Lengyel) draws each glyph from its outline curves on the GPU, with no bitmaps: sharp at any page zoom, rotation or transform, and exact subpixel positions. Color glyphs (emoji) always use the atlas."},
	{name = "text.backend", kind = .String, default = {s = "default"}, choices = {"default", "dwrite", "native"}, restart = true,
		description = "Who shapes text, finds line breaks and bidi levels and reads the fonts. native: Fontations, HarfRust and ICU4X (the same code on every platform; what Wren builds use). dwrite: DirectWrite (Windows). default: what the build chose (native, unless it was built with WREN_TEXT=dwrite, which has only DirectWrite). The system's fonts and their fallback always come from Windows."},
	{name = "text.emoji", kind = .String, default = {s = "builtin"}, choices = {"builtin", "system"},
		description = "Where emoji come from. builtin: Noto Color Emoji (COLR v1, SIL OFL), compiled into wren.exe and drawn by Wren's own COLR interpreter: the same emoji, sharp and vector, on every platform, replacing the system's emoji font even when a page names it. system: the emoji font of Windows (Segoe UI Emoji) drawn by Direct2D, as before."},
	{name = "text.emoji.raster_samples", kind = .Int, default = {i = 8}, bounded = true, min = 1, max = 64,
		description = "Built-in emoji: vertical samples per pixel row when a color glyph's shapes are drawn (horizontal coverage is exact). 8 matches Chrome's emoji to within a third of a percent; more is slower and not visibly better."},
	{name = "text.emoji.outline_cache", kind = .Int, default = {i = 8192}, bounded = true, min = 64, max = 1048576, unit = "KiB",
		description = "Built-in emoji: outlines of the emoji font's glyphs kept for drawing at other sizes (page zoom, device scale). Over this size they are all dropped and read again as needed."},
	{name = "font.family.emoji", kind = .String, default = {s = style.FONT_EMOJI}, description = "Font used for the generic family `emoji`."},
	{name = "font.family.math", kind = .String, default = {s = style.FONT_MATH}, description = "Font used for the generic family `math`."},
	{name = "font.family.fangsong", kind = .String, default = {s = "FangSong"}, description = "Font used for the generic family `fangsong`."},
}

register_font_prefs :: proc(p: ^config.Prefs) { config.register(p, FONT_PREFS[:]) }

font_settings_from_prefs :: proc(p: ^config.Prefs) -> font.Settings {
	s := font.DEFAULT_SETTINGS
	if config.ref_of(p, "appearance.text.rendering") == config.NO_REF { return s }   // not registered (tests)
	s.subpixel_steps = int(config.int_of(p, "appearance.text.subpixel_steps"))
	switch config.string_of(p, "appearance.text.rendering") {
	case "natural": s.rendering = .Natural
	case "gdi_classic": s.rendering = .Gdi_Classic
	case "aliased": s.rendering = .Aliased
	case: s.rendering = .Natural_Symmetric
	}
	switch config.string_of(p, "appearance.text.grid_fit") {
	case "enabled": s.grid_fit = .Enabled
	case "disabled": s.grid_fit = .Disabled
	case: s.grid_fit = .Default
	}
	switch config.string_of(p, "appearance.text.subpixel") {
	case "rgb": s.subpixel_text = .Rgb
	case "bgr": s.subpixel_text = .Bgr
	case: s.subpixel_text = .Off
	}
	s.color_glyphs = config.bool_of(p, "appearance.text.color_emoji")
	s.color_async = config.bool_of(p, "appearance.text.color_async")
	s.system_fallback = config.bool_of(p, "appearance.text.system_fallback")
	s.page_size = int(config.int_of(p, "appearance.text.page_size"))
	s.max_gray_pages = int(config.int_of(p, "appearance.text.atlas_pages"))
	s.max_color_pages = int(config.int_of(p, "appearance.text.color_pages"))
	s.word_cache = int(config.int_of(p, "appearance.text.word_cache"))
	s.text_renderer = config.string_of(p, "appearance.text.renderer") == "slug" ? .Slug : .Atlas
	s.slug_pages = int(config.int_of(p, "appearance.text.slug_pages"))
	s.slug_tolerance = f32(config.float_of(p, "appearance.text.slug_tolerance")) / 1000
	s.color_engine = config.string_of(p, "text.emoji") == "builtin" ? .Builtin : .System
	s.colr_samples = int(config.int_of(p, "text.emoji.raster_samples"))
	s.colr_cache_kb = int(config.int_of(p, "text.emoji.outline_cache"))
	switch config.string_of(p, "text.backend") {
	case "dwrite": s.backend = .Dwrite
	case "native": s.backend = .Native   // init falls back to the build's backend when it is not linked
	}
	return s
}

// Noto Color Emoji, compiled into the executable (build.bat fetches it into build\emoji first): nothing to ship next to
// wren.exe. The bytes stay in the image, mapped by Windows only as the emoji font reads them. A build without the file
// (a tool compiling this package before wrentool fetch emoji) has none, and emoji come from the system.
@(private = "file") EMOJI_FILE :: "../../build/emoji/NotoColorEmoji-COLRv1.ttf"
when #exists(EMOJI_FILE) {
	@(private = "file") emoji_builtin := #load(EMOJI_FILE)
} else {
	@(private = "file") emoji_builtin: []byte
}

// What text.emoji = builtin draws from: the font file appearance.text.emoji_font names, else EMOJI_BUILTIN (the compiled-in font);
// "" when emoji come from the system.
EMOJI_BUILTIN :: "<built-in>"
emoji_font_path :: proc(p: ^config.Prefs, allocator := context.temp_allocator) -> string {
	if config.ref_of(p, "text.emoji") == config.NO_REF || config.string_of(p, "text.emoji") != "builtin" { return "" }
	if config.ref_of(p, "appearance.text.emoji_font") != config.NO_REF {
		if own := strings.trim_space(config.string_of(p, "appearance.text.emoji_font")); own != "" { return strings.clone(own, allocator) }
	}
	return len(emoji_builtin) > 0 ? EMOJI_BUILTIN : ""
}

// Hands the emoji font to the font state, or takes it away. Returns true when what the font state draws emoji from changed.
@(private)
emoji_source_apply :: proc(app: ^App) -> bool {
	want := emoji_font_path(&app.prefs)
	if want != "" && want != EMOJI_BUILTIN && !is_file(want) { want = "" }   // missing: the system's emoji font, as with text.emoji = system
	if want == app.emoji_applied { return false }
	if app.emoji_applied != EMOJI_BUILTIN { delete(app.emoji_applied) }
	switch want {
	case "":
		app.emoji_applied = ""
		font.set_emoji_source(&app.fonts)
	case EMOJI_BUILTIN:
		app.emoji_applied = EMOJI_BUILTIN
		font.set_emoji_source(&app.fonts, data = emoji_builtin)
	case:
		app.emoji_applied = strings.clone(want)
		font.set_emoji_source(&app.fonts, app.emoji_applied)
	}
	return true
}


// Follows the preferences: glyph bitmaps are made again with new rendering settings, layouts again when what text
// measures may change (the system fallback), the generic families are resolved again.
font_settings_init :: proc(app: ^App) {
	font_generics_apply(app)
	emoji_source_apply(app)   // the face loads when the first emoji needs it, not now
	// color glyphs drawn on their thread: a frame shows them (host.post wakes the loop from any thread)
	font.set_color_ready_callback(&app.fonts, proc(user: rawptr) {
		a := (^App)(user)
		host.post(&a.loop, proc(data: rawptr) { app := (^App)(data); request_frames(app, 2) }, a, .Input)
	}, app)
	app.font_watch = config.watch(&app.prefs, "font.", font_prefs_changed, app)
	app.text_watch = config.watch(&app.prefs, "text.", font_prefs_changed, app)
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
	emoji_changed := emoji_source_apply(a) || s.color_engine != old.color_engine
	if s.system_fallback != old.system_fallback || emoji_changed {
		font.clear_word_cache(&a.fonts)
		for t in active_window(a).tabs { t.layout.valid = false }
	}
	font_generics_apply(a)
	request_frames(a, 2)
}

@(private)
font_generics_apply :: proc(app: ^App) {
	if config.ref_of(&app.prefs, "font.family.emoji") == config.NO_REF { return }
	page_fonts_set_generics(&app.page_render.fonts, config.string_of(&app.prefs, "font.family.emoji"),
		config.string_of(&app.prefs, "font.family.math"), config.string_of(&app.prefs, "font.family.fangsong"))
}
