package style

import "core:strings"
import "wb:config"
import "wb:css"

// Everything about styling that a user, a developer or an administrator may want to change (about:config, `style.*`,
// `font.*`, `ui.*`). The built-in stylesheet is generated from these values, so a different default color or font size is a
// preference, not a patch.

Color_Scheme :: enum u8 { Auto, Light, Dark }

Settings :: struct {
	max_nesting_depth:   int,
	max_rules_per_sheet: int,
	max_rules_total:     int,
	max_sheet_bytes:     int,
	max_import_depth:    int,
	max_imports:         int,       // @import sheets loaded for one document, all levels together
	counters_max_listed: int,       // counters(): innermost instances listed
	counters_max_ops:    int,       // counter names in one counter-reset / counter-increment / counter-set
	max_selector_compounds: int,
	max_var_depth:       int,       // var() substitution chain
	max_var_bytes:       int,       // text var() may substitute for one element
	restyle_waste_bytes: int,       // memory that partial restyles may leave behind before a full pass compacts it
	recycle_bytes:       int,       // largest style memory kept from one full pass for the next
	custom_max_layers:   int,       // layers of custom properties a lookup may walk (custom_props.odin)
	inline_cache_entries: int,      // compiled style attributes (and CSSOM declarations) kept per pass (inline_cache.odin)
	ua_stylesheet:       bool,
	author_stylesheets:  bool,      // false: pages are shown with the browser's styles only
	author_colors:       bool,      // false: the page's colors are ignored (high-contrast reading)
	author_fonts:        bool,      // false: font-family / font-size from pages are ignored
	user_stylesheet:     string,    // owned: path of a user CSS file ("" = none)
	color_scheme:        Color_Scheme,
	reduced_motion:      bool,
	internal_document:   bool,      // the document is one of the browser's own pages (set by the page from its address, not a preference): -wren-shader is accepted
	prefers_contrast:    bool,
	default_font_size:   f32,
	monospace_font_size: f32,
	minimum_font_size:   f32,
	colors:              [Scheme][System_Color]css.Color,   // system colors of each color scheme (color_scheme.odin)
	body_margin:         f32,
	// generic family -> concrete family names, used by the painter
	family_serif, family_sans_serif, family_monospace, family_cursive, family_fantasy, family_system_ui: string,  // owned
	default_generic:     string,    // owned: the generic family used when a page names none
	line_height_normal:  f32,       // multiple of font size for `line-height: normal`; 0: from the font (layout)
	// transitions and animations (timeline.odin)
	anim_mode:           Anim_Mode,
	anim_reduced_max_ms: f32,       // Reduce: longest duration of a transition or of one animation iteration
	anim_time_scale:     f32,       // document time runs this much faster (debugging aid)
	anim_max_running:    int,       // transitions + animations alive in one document; more are not started
	anim_max_events:     int,       // animation events queued per tick; the rest are dropped
	anim_color_space:    Anim_Color_Space,
	// web fonts (fontface.odin, page/fonts.odin)
	webfonts:            bool,
	webfont_max_bytes:   int,
	webfont_max_parallel: int,
	webfont_max_faces:   int,
	webfont_load_unused: bool,
	webfont_block_ms:    f64,       // font-display auto / block: text waits this long for its font
	webfont_short_block_ms: f64,    // fallback / optional
	webfont_swap_ms:     f64,       // fallback: a font later than this is not used
	webfont_cached_block_ms: f64,   // a font the HTTP cache holds fresh: waited for this long, whatever font-display
	webfont_invisible_text: bool,   // text waiting for its font in a block period is drawn invisible
	webfont_decoded_cache_bytes: int,
	render_block_ms:     f64,       // the first paint waits at most this long for render-blocking stylesheets
	// restyle after DOM mutations (restyle_dom.odin)
	inc_enabled:         bool,
	inc_max_ratio:       f32,       // part of the document's nodes past which a full pass is done instead
	inc_parallel_min:    int,       // elements restyled at least before forced subtrees go to the style threads
	inc_verify:          bool,      // diagnostic: compare with a full pass after every partial one
	inc_journal:         int,       // entries of the document's mutation journal
	background_clip_text: bool,     // the painter clips backgrounds to text: `background-clip: text` is accepted
	cq_max_rounds:       int,       // container queries: style + layout rounds per frame once container sizes change
	presentational_hints: bool,     // HTML's presentational attributes (align, bgcolor, width...) style elements (hints.odin)
	// not a preference: set by the page whose engine it is. Scripting is enabled for the document: <noscript> is not
	// rendered (HTML 15.3.1), its content having been parsed as text (page/js_load_write.odin)
	scripting:           bool,
	quirks_rules:        bool,      // documents in quirks mode get the rendering quirks of HTML §15 (hints.odin, layout)
}

// Auto: Reduce when prefers-reduced-motion is reported, else Normal. Reduce: transitions and iterations are cut to
// `anim_reduced_max_ms` and infinite animations run once; Off: no transition or animation runs (end values apply at once,
// no events).
Anim_Mode :: enum u8 { Auto, Normal, Reduce, Off }
Anim_Color_Space :: enum u8 { Srgb, Oklab }

// The mode in force for these settings.
anim_mode_effective :: proc(s: ^Settings) -> Anim_Mode {
	if s.anim_mode == .Auto { return s.reduced_motion ? .Reduce : .Normal }
	return s.anim_mode
}

PREFS := [?]config.Def{
	{name = "style.max_nesting_depth", kind = .Int, default = {i = 256}, bounded = true, min = 8, max = 4096,
		description = "Deepest nesting of blocks and functions in a stylesheet; deeper ones are skipped (stack protection: parsing, var() and calc() recurse once per level, so the bound stays far below what a thread stack holds)."},
	{name = "style.max_rules_per_sheet", kind = .Int, default = {i = 200_000}, bounded = true, min = 100, max = 100_000_000,
		description = "Most rules read from one stylesheet; the rest is ignored."},
	{name = "style.max_rules_total", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 100, max = 1_000_000_000,
		description = "Most style rules active in one document, all its sheets together (each shadow tree with its own sheets counts on its own)."},
	{name = "style.max_sheet_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest stylesheet that is parsed; a bigger one is ignored."},
	{name = "style.max_import_depth", kind = .Int, default = {i = 8}, bounded = true, min = 0, max = 64,
		description = "How deep @import may chain. 0 disables @import."},
	{name = "style.counters.max_listed", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 1_000_000, unit = "levels",
		description = "counters() lists at most this many nested instances of a counter, the innermost ones (on a deeply nested page each level listed every level above it: text growing with the square of the depth)."},
	{name = "style.counters.max_ops", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 1_000_000, unit = "counters",
		description = "Most counter names one counter-reset, counter-increment or counter-set declaration may list; a longer list is invalid."},
	{name = "style.max_imports", kind = .Int, default = {i = 256}, bounded = true, min = 0, max = 100_000, unit = "sheets",
		description = "Most stylesheets loaded through @import for one document, all levels together (a sheet importing itself ten times, eight levels deep, asked for 10^8 loads). A sheet that imports one of the sheets importing it is ignored."},
	{name = "style.max_selector_compounds", kind = .Int, default = {i = 32}, bounded = true, min = 2, max = 1000,
		description = "Longest complex selector (compound selectors joined by combinators); longer ones are dropped. Selectors inside :is(), :not(), :where() and :has() are not counted."},
	{name = "style.max_var_depth", kind = .Int, default = {i = 32}, bounded = true, min = 1, max = 1000,
		description = "How many var() references may chain before the value is invalid."},
	{name = "style.max_var_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 64, max = 1 << 28, bytes = true, unit = "bytes",
		description = "Most text var() may substitute while one element is styled, all its custom properties and declarations together; past it the declaration is invalid at computed-value time (stops exponential blow-up from nested custom properties, and bounds the memory one element costs)."},
	{name = "style.restyle_waste_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1 << 20, max = 1 << 36, bytes = true, unit = "bytes",
		description = "Partial restyles (hover, focus) allocate new computed styles; once this much has piled up the next restyle is a full pass that frees it."},
	{name = "style.recycle_bytes", kind = .Int, default = {i = 128 << 20}, bounded = true, min = 0, max = 1 << 34, bytes = true, unit = "bytes",
		description = "Memory of a full style pass kept, already mapped, for the next pass of the same page (faster restyles, at the cost of holding it). 0 = always give it back."},
	{name = "style.custom_properties.max_layers", kind = .Int, default = {i = 8}, bounded = true, min = 0, max = 1024, unit = "layers",
		description = "An element that sets custom properties (--x) keeps only its own over the ones it inherits; past this many such layers under it, it gets a copy of all of them instead. Fewer: faster var() lookups, more memory on pages that set variables on many elements. 0 = always a copy."},
	{name = "style.inline_cache.entries", kind = .Int, default = {i = 8192}, bounded = true, min = 0, max = 1 << 24, unit = "style attributes",
		description = "Compiled style attributes kept by text until the next full restyle, so that restyling an element (or many elements with the same style attribute) does not parse it again, and a value a script sets through element.style is compiled once. The same number of single declarations is kept for scripts. 0 = parse at every restyle."},
	{name = "style.ua_stylesheet.enabled", kind = .Bool, default = {b = true}, description = "Use the browser's default styles (headings, lists, links...). Without them pages are unstyled."},
	{name = "style.author_stylesheets.enabled", kind = .Bool, default = {b = true}, description = "Apply the styles that pages bring. Off: every page is shown with browser styles only."},
	{name = "style.author_colors.enabled", kind = .Bool, default = {b = true}, description = "Let pages set colors. Off: color and background properties from pages are ignored."},
	{name = "style.author_fonts.enabled", kind = .Bool, default = {b = true}, description = "Let pages set fonts. Off: font-family and font-size from pages are ignored."},
	{name = "style.user_stylesheet", kind = .String, default = {s = ""}, description = "Path of a CSS file applied to every page with user priority (empty = none)."},
	{name = "style.color_scheme", kind = .String, default = {s = "auto"}, choices = {"auto", "light", "dark"},
		description = "The color scheme the user prefers: reported to pages (prefers-color-scheme) and used by pages and elements that support both (color-scheme: light dark). auto follows the Windows apps theme (Settings > Personalization > Colors), live."},
	{name = "style.prefers_reduced_motion", kind = .Bool, default = {b = false}, description = "Report prefers-reduced-motion: reduce to pages."},
	{name = "style.prefers_more_contrast", kind = .Bool, default = {b = false}, description = "Report prefers-contrast: more to pages."},
	{name = "font.size.default", kind = .Float, default = {f = 16}, bounded = true, min = 6, max = 96, unit = "px", description = "Default font size (CSS `medium`)."},
	{name = "font.size.monospace", kind = .Float, default = {f = 13}, bounded = true, min = 6, max = 96, unit = "px", description = "Default size of monospace text (pre, code, kbd, samp)."},
	{name = "font.size.minimum", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 48, unit = "px", description = "Text is never smaller than this. 0 = no minimum."},
	{name = "font.family.default_generic", kind = .String, default = {s = "serif"}, choices = {"serif", "sans-serif", "monospace"},
		description = "Generic family of text whose page names no font."},
	{name = "font.family.serif", kind = .String, default = {s = "Times New Roman"}, description = "Font used for the generic family `serif`."},
	{name = "font.family.sans_serif", kind = .String, default = {s = "Arial"}, description = "Font used for the generic family `sans-serif`."},
	{name = "font.family.monospace", kind = .String, default = {s = "Consolas"}, description = "Font used for the generic family `monospace`."},
	{name = "font.family.cursive", kind = .String, default = {s = "Comic Sans MS"}, description = "Font used for the generic family `cursive`."},
	{name = "font.family.fantasy", kind = .String, default = {s = "Impact"}, description = "Font used for the generic family `fantasy`."},
	{name = "font.family.system_ui", kind = .String, default = {s = "Segoe UI"}, description = "Font used for `system-ui`."},
	{name = "font.line_height.normal", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 3,
		description = "What `line-height: normal` means, as a multiple of the font size. 0: from the font, its ascent + descent + line gap, as other browsers do (Arial: about 1.15, Verdana 1.22); the lh unit then takes 1.2."},
	{name = "page.body_margin", kind = .Float, default = {f = 8}, bounded = true, min = 0, max = 200, unit = "px", description = "Margin around the body of a page."},
	{name = "style.animations.mode", kind = .String, default = {s = "auto"}, choices = {"auto", "normal", "reduce", "off"},
		description = "CSS transitions and animations. auto: like reduce when style.prefers_reduced_motion is on, else normal. reduce: durations are cut to style.animations.reduced_max_duration_ms and infinite animations run once. off: nothing moves, end values apply at once."},
	{name = "style.animations.reduced_max_duration_ms", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "In reduce mode: the longest a transition, a delay or one animation iteration may last. 0 jumps straight to the end values (transitions then do not start; animations still report start and end)."},
	{name = "style.animations.time_scale", kind = .Float, default = {f = 1}, bounded = true, min = 0.01, max = 100,
		description = "Speed of the document clock that drives transitions and animations (0.1 = ten times slower). A debugging aid."},
	{name = "style.animations.max_running", kind = .Int, default = {i = 20_000}, bounded = true, min = 1, max = 10_000_000,
		description = "Most transitions and animations alive at once in one document; past it new ones do not start (their end values apply)."},
	{name = "style.animations.max_events_per_tick", kind = .Int, default = {i = 10_000}, bounded = true, min = 10, max = 10_000_000,
		description = "Most transition and animation events (transitionend, animationiteration...) queued in one step of the clock; the rest are dropped."},
	{name = "style.animations.color_space", kind = .String, default = {s = "srgb"}, choices = {"srgb", "oklab"},
		description = "Space colors are interpolated in by transitions and animations (premultiplied by alpha). srgb matches other browsers for ordinary colors; oklab gives perceptually even blends."},
	{name = "style.webfonts.enabled", kind = .Bool, default = {b = true}, description = "Download the fonts pages declare with @font-face. Off: pages use installed fonts only."},
	{name = "style.webfonts.max_bytes", kind = .Int, default = {i = 32 << 20}, bounded = true, min = 64 << 10, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest font file (and largest decompressed font) accepted from a page."},
	{name = "style.webfonts.max_parallel", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 64,
		description = "Font downloads one page runs at the same time; the others wait in a queue."},
	{name = "style.webfonts.max_faces", kind = .Int, default = {i = 256}, bounded = true, min = 1, max = 100_000,
		description = "Most @font-face rules one page may load fonts for."},
	{name = "style.webfonts.load_unused", kind = .Bool, default = {b = false},
		description = "Download every @font-face of a page, even those no element uses (off: only families some element asks for)."},
	{name = "style.webfonts.block_period_ms", kind = .Float, default = {f = 3000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "font-display: auto and block: how long the first paint of a page waits for a web font its text uses (CSS Fonts 4: about 3 s). Later, the fallback font shows and the web font replaces it when it arrives."},
	{name = "style.webfonts.short_block_period_ms", kind = .Float, default = {f = 100}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "font-display: fallback and optional: how long the first paint waits for the font (CSS Fonts 4: about 100 ms). optional: a font not there by then is not used by this page."},
	{name = "style.webfonts.swap_period_ms", kind = .Float, default = {f = 3000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "font-display: fallback: a font that arrives later than this after its download started is not used (CSS Fonts 4: about 3 s)."},
	{name = "style.webfonts.cached_block_period_ms", kind = .Float, default = {f = 500}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "A web font the HTTP cache holds fresh (a page seen before) is waited for this long whatever its font-display, swap included, so that the page never shows its fallback font for the few milliseconds the cache takes (as Chromium's cache-aware font display). 0: font-display alone decides."},
	{name = "style.webfonts.invisible_text", kind = .Bool, default = {b = true},
		description = "font-display: auto, block (and fallback, optional for their short block period): once the page is shown, text whose web font is still loading is laid out with the fallback font but drawn invisible until the font arrives or the block period ends (CSS Fonts 4 §4.9). Off: the fallback font shows at once."},
	{name = "style.webfonts.decoded_cache_bytes", kind = .Int, default = {i = 32 << 20}, bounded = true, min = 0, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Web fonts kept decoded (WOFF / WOFF2 unpacked) in memory, by URL and content, for every page and tab: a page that comes back does not decode them again. 0: no cache."},
	{name = "style.render_blocking.timeout_ms", kind = .Float, default = {f = 8000}, bounded = true, min = 0, max = 120_000, unit = "ms",
		description = "The first paint of a page waits for the stylesheets of the document (<link rel=stylesheet>, <style> with @import, media matching, or blocking=\"render\") so that it is not shown unstyled; past this delay it is painted with what has arrived. 0 = never wait."},
	{name = "style.incremental.enabled", kind = .Bool, default = {b = true},
		description = "After DOM changes, restyle only the elements the changes can affect (found from the selectors of the page). Off: every change restyles the whole document (same result)."},
	{name = "style.incremental.max_ratio", kind = .Float, default = {f = 0.3}, bounded = true, min = 0, max = 1,
		description = "Part of the document's nodes a DOM change may restyle partially; past it the whole document is restyled (on the style threads)."},
	{name = "style.incremental.parallel_min", kind = .Int, default = {i = 2048}, bounded = true, min = 1, max = 1 << 40, unit = "elements",
		description = "A partial restyle of at least this many elements shares the subtrees it restyles whole between the style threads; smaller ones stay on the page's thread."},
	{name = "style.incremental.verify", kind = .Bool, default = {b = false},
		description = "Diagnostic: after every partial restyle, compute all styles again and report the first difference in the console. As slow as a full restyle."},
	{name = "style.incremental.journal_entries", kind = .Int, default = {i = 65536}, bounded = true, min = 256, max = 16 << 20,
		description = "Mutations of a document remembered between two restyles; more at once make the next restyle a full one."},
	{name = "style.background_clip_text.enabled", kind = .Bool, default = {b = true},
		description = "Accept `background-clip: text` (gradient or image text: the backgrounds are painted through the glyphs of the element and of its descendants). When off, the value is invalid, so pages that test @supports (background-clip: text) keep their plain-text fallback."},
	{name = "style.container_queries.max_rounds", kind = .Int, default = {i = 3}, bounded = true, min = 0, max = 16,
		description = "Container queries (@container, cq units) depend on sizes only layout knows: after a layout that changes the size of a query container, styles and layout are computed again, at most this many times per frame (the rest waits for the next frame). 0 = sizes are never fed back: queries stay unknown and cq units use the viewport."},
	{name = "style.presentational_hints.enabled", kind = .Bool, default = {b = true},
		description = "Honor HTML's presentational attributes (align, valign, bgcolor, width / height, cellpadding, cellspacing, border, <font>, hspace...) as the HTML Standard's rendering section maps them to CSS: author styles of the lowest priority, which any stylesheet of the page overrides. Off: those attributes do nothing (old pages lose their layout). Follows style.author_stylesheets.enabled."},
	{name = "style.quirks_mode.enabled", kind = .Bool, default = {b = true},
		description = "Documents without a standard doctype (quirks mode) get the rendering quirks of the HTML Standard and other browsers: tables do not inherit font sizes, forms have a bottom margin, the body fills the window, percentage heights look past auto-height ancestors. Off: they are laid out as standard documents."},
}

register_prefs :: proc(p: ^config.Prefs) {
	config.register(p, PREFS[:])
	config.register(p, color_pref_defs())
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.max_nesting_depth = int(config.int_of(p, "style.max_nesting_depth"))
	s.max_rules_per_sheet = int(config.int_of(p, "style.max_rules_per_sheet"))
	s.max_rules_total = int(config.int_of(p, "style.max_rules_total"))
	s.max_sheet_bytes = int(config.int_of(p, "style.max_sheet_bytes"))
	s.max_import_depth = int(config.int_of(p, "style.max_import_depth"))
	s.max_imports = int(config.int_of(p, "style.max_imports"))
	s.counters_max_listed = int(config.int_of(p, "style.counters.max_listed"))
	s.counters_max_ops = int(config.int_of(p, "style.counters.max_ops"))
	s.max_selector_compounds = int(config.int_of(p, "style.max_selector_compounds"))
	s.max_var_depth = int(config.int_of(p, "style.max_var_depth"))
	s.max_var_bytes = int(config.int_of(p, "style.max_var_bytes"))
	s.restyle_waste_bytes = int(config.int_of(p, "style.restyle_waste_bytes"))
	s.recycle_bytes = int(config.int_of(p, "style.recycle_bytes"))
	s.custom_max_layers = int(config.int_of(p, "style.custom_properties.max_layers"))
	s.inline_cache_entries = int(config.int_of(p, "style.inline_cache.entries"))
	s.ua_stylesheet = config.bool_of(p, "style.ua_stylesheet.enabled")
	s.author_stylesheets = config.bool_of(p, "style.author_stylesheets.enabled")
	s.author_colors = config.bool_of(p, "style.author_colors.enabled")
	s.author_fonts = config.bool_of(p, "style.author_fonts.enabled")
	s.user_stylesheet = strings.clone(config.string_of(p, "style.user_stylesheet"))
	switch config.string_of(p, "style.color_scheme") {
	case "light": s.color_scheme = .Light
	case "dark":  s.color_scheme = .Dark
	case:         s.color_scheme = .Auto
	}
	s.reduced_motion = config.bool_of(p, "style.prefers_reduced_motion")
	s.prefers_contrast = config.bool_of(p, "style.prefers_more_contrast")
	s.default_font_size = f32(config.float_of(p, "font.size.default"))
	s.monospace_font_size = f32(config.float_of(p, "font.size.monospace"))
	s.minimum_font_size = f32(config.float_of(p, "font.size.minimum"))
	s.default_generic = strings.clone(config.string_of(p, "font.family.default_generic"))
	s.family_serif = strings.clone(config.string_of(p, "font.family.serif"))
	s.family_sans_serif = strings.clone(config.string_of(p, "font.family.sans_serif"))
	s.family_monospace = strings.clone(config.string_of(p, "font.family.monospace"))
	s.family_cursive = strings.clone(config.string_of(p, "font.family.cursive"))
	s.family_fantasy = strings.clone(config.string_of(p, "font.family.fantasy"))
	s.family_system_ui = strings.clone(config.string_of(p, "font.family.system_ui"))
	s.line_height_normal = f32(config.float_of(p, "font.line_height.normal"))
	colors_from_prefs(p, &s)
	s.body_margin = f32(config.float_of(p, "page.body_margin"))
	switch config.string_of(p, "style.animations.mode") {
	case "normal": s.anim_mode = .Normal
	case "reduce": s.anim_mode = .Reduce
	case "off": s.anim_mode = .Off
	case: s.anim_mode = .Auto
	}
	s.anim_reduced_max_ms = f32(config.float_of(p, "style.animations.reduced_max_duration_ms"))
	s.anim_time_scale = f32(config.float_of(p, "style.animations.time_scale"))
	s.anim_max_running = int(config.int_of(p, "style.animations.max_running"))
	s.anim_max_events = int(config.int_of(p, "style.animations.max_events_per_tick"))
	s.anim_color_space = config.string_of(p, "style.animations.color_space") == "oklab" ? .Oklab : .Srgb
	s.webfonts = config.bool_of(p, "style.webfonts.enabled")
	s.webfont_max_bytes = int(config.int_of(p, "style.webfonts.max_bytes"))
	s.webfont_max_parallel = int(config.int_of(p, "style.webfonts.max_parallel"))
	s.webfont_max_faces = int(config.int_of(p, "style.webfonts.max_faces"))
	s.webfont_load_unused = config.bool_of(p, "style.webfonts.load_unused")
	s.webfont_block_ms = config.float_of(p, "style.webfonts.block_period_ms")
	s.webfont_short_block_ms = config.float_of(p, "style.webfonts.short_block_period_ms")
	s.webfont_swap_ms = config.float_of(p, "style.webfonts.swap_period_ms")
	s.webfont_cached_block_ms = config.float_of(p, "style.webfonts.cached_block_period_ms")
	s.webfont_invisible_text = config.bool_of(p, "style.webfonts.invisible_text")
	s.webfont_decoded_cache_bytes = int(config.int_of(p, "style.webfonts.decoded_cache_bytes"))
	s.render_block_ms = config.float_of(p, "style.render_blocking.timeout_ms")
	s.inc_enabled = config.bool_of(p, "style.incremental.enabled")
	s.inc_max_ratio = f32(config.float_of(p, "style.incremental.max_ratio"))
	s.inc_parallel_min = int(config.int_of(p, "style.incremental.parallel_min"))
	s.inc_verify = config.bool_of(p, "style.incremental.verify")
	s.inc_journal = int(config.int_of(p, "style.incremental.journal_entries"))
	s.background_clip_text = config.bool_of(p, "style.background_clip_text.enabled")
	s.presentational_hints = config.bool_of(p, "style.presentational_hints.enabled")
	s.quirks_rules = config.bool_of(p, "style.quirks_mode.enabled")
	s.cq_max_rounds = int(config.int_of(p, "style.container_queries.max_rounds"))
	return s
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.user_stylesheet)
	delete(s.default_generic)
	delete(s.family_serif); delete(s.family_sans_serif); delete(s.family_monospace)
	delete(s.family_cursive); delete(s.family_fantasy); delete(s.family_system_ui)
	s^ = {}
}

parse_options :: proc(s: ^Settings) -> css.Parse_Options {
	return css.Parse_Options{max_nesting_depth = s.max_nesting_depth, max_rules = s.max_rules_per_sheet}
}

// The family name a generic keyword stands for.
generic_family :: proc(s: ^Settings, generic: string) -> string {
	switch generic {
	case "serif", "ui-serif": return s.family_serif
	case "sans-serif": return s.family_sans_serif
	case "monospace", "ui-monospace": return s.family_monospace
	case "cursive": return s.family_cursive
	case "fantasy": return s.family_fantasy
	case "system-ui", "ui-sans-serif", "-apple-system", "ui-rounded": return s.family_system_ui
	}
	return ""
}
