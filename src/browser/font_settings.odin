package browser

import "core:strings"
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
	{name = "text.backend", kind = .String, default = {s = "default"}, choices = {"default", "dwrite", "native"}, restart = true,
		description = "Who shapes text, finds line breaks and bidi levels and reads the fonts. native: Fontations, HarfRust and ICU4X (the same code on every platform; what Wren builds use). dwrite: DirectWrite (Windows). default: what the build chose (native, unless it was built with WREN_TEXT=dwrite, which has only DirectWrite). The system's fonts and their fallback always come from Windows."},
	{name = "text.slug.pages", kind = .Int, default = {i = 128}, bounded = true, min = 1, max = 2048,
		description = "Glyph pages of the Slug renderer kept before the least recently used one is reused (a page a frame still draws from is never reused: one more is made). A page holds about a hundred Latin glyphs; each takes 48 KB of video memory (as much of main memory), up to 6 MB at the default."},
	{name = "text.slug.tolerance", kind = .Float, default = {f = 0.25}, bounded = true, min = 0.015, max = 16, unit = "1/1000 em",
		description = "Slug: the largest distance between a cubic outline (CFF / OpenType fonts) and the quadratic curves drawn instead, in thousandths of the em (0.25: a hundredth of a pixel at 40 px). TrueType outlines are quadratic already and are never approximated."},
	{name = "text.emoji", kind = .String, default = {s = "builtin"}, choices = {"builtin", "system"},
		description = "Where emoji come from. builtin: Noto Color Emoji (COLR v1, SIL OFL), compiled into wren.exe and drawn by Wren's own COLR interpreter: the same emoji, sharp and vector, on every platform, replacing the system's emoji font even when a page names it. system: the emoji font of Windows (Segoe UI Emoji) drawn by Direct2D, as before."},
	{name = "text.emoji.font", kind = .String, default = {s = ""},
		description = "Path of the emoji font used by text.emoji = builtin: a font file with COLR v0 / v1 color glyphs (a Noto Color Emoji build, Twemoji COLR...). Empty: the Noto Color Emoji compiled into wren.exe. When the file is missing, emoji come from the system's fonts."},
	{name = "text.emoji.raster_samples", kind = .Int, default = {i = 8}, bounded = true, min = 1, max = 64,
		description = "Built-in emoji: vertical samples per pixel row when a color glyph's shapes are drawn (horizontal coverage is exact). 8 matches Chrome's emoji to within a third of a percent; more is slower and not visibly better."},
	{name = "text.emoji.outline_cache", kind = .Int, default = {i = 8192}, bounded = true, min = 64, max = 1048576, unit = "KiB",
		description = "Built-in emoji: outlines of the emoji font's glyphs kept for drawing at other sizes (page zoom, device scale). Over this size they are all dropped and read again as needed."},
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
// (a tool compiling this package before fetch_emoji.ps1) has none, and emoji come from the system.
@(private = "file") EMOJI_FILE :: "../../build/emoji/NotoColorEmoji-COLRv1.ttf"
when #exists(EMOJI_FILE) {
	@(private = "file") emoji_builtin := #load(EMOJI_FILE)
} else {
	@(private = "file") emoji_builtin: []byte
}

// What text.emoji = builtin draws from: the font file text.emoji.font names, else EMOJI_BUILTIN (the compiled-in font);
// "" when emoji come from the system.
EMOJI_BUILTIN :: "<built-in>"
emoji_font_path :: proc(p: ^config.Prefs, allocator := context.temp_allocator) -> string {
	if config.ref_of(p, "text.emoji") == config.NO_REF || config.string_of(p, "text.emoji") != "builtin" { return "" }
	if own := strings.trim_space(config.string_of(p, "text.emoji.font")); own != "" { return strings.clone(own, allocator) }
	return len(emoji_builtin) > 0 ? EMOJI_BUILTIN : ""
}

@(private) emoji_applied: string   // what the font state has: a path (heap), EMOJI_BUILTIN, or "" for none

// Hands the emoji font to the font state, or takes it away. Returns true when what the font state draws emoji from changed.
@(private)
emoji_source_apply :: proc(app: ^App) -> bool {
	want := emoji_font_path(&app.prefs)
	if want != "" && want != EMOJI_BUILTIN && !is_file(want) { want = "" }   // missing: the system's emoji font, as with text.emoji = system
	if want == emoji_applied { return false }
	if emoji_applied != EMOJI_BUILTIN { delete(emoji_applied) }
	switch want {
	case "":
		emoji_applied = ""
		font.set_emoji_source(&app.fonts)
	case EMOJI_BUILTIN:
		emoji_applied = EMOJI_BUILTIN
		font.set_emoji_source(&app.fonts, data = emoji_builtin)
	case:
		emoji_applied = strings.clone(want)
		font.set_emoji_source(&app.fonts, emoji_applied)
	}
	return true
}

@(private) font_watch, text_watch: int

// Follows the preferences: glyph bitmaps are made again with new rendering settings, layouts again when what text
// measures may change (the system fallback), the generic families are resolved again.
font_settings_init :: proc(app: ^App) {
	font_generics_apply(app)
	emoji_source_apply(app)   // the face loads when the first emoji needs it, not now
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
	emoji_changed := emoji_source_apply(a) || s.color_engine != old.color_engine
	if s.system_fallback != old.system_fallback || emoji_changed {
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
