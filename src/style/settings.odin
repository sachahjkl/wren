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
	max_selector_compounds: int,
	max_var_depth:       int,       // var() substitution chain
	max_var_bytes:       int,       // size of one substituted value
	restyle_waste_bytes: int,       // memory that partial restyles may leave behind before a full pass compacts it
	ua_stylesheet:       bool,
	author_stylesheets:  bool,      // false: pages are shown with the browser's styles only
	author_colors:       bool,      // false: the page's colors are ignored (high-contrast reading)
	author_fonts:        bool,      // false: font-family / font-size from pages are ignored
	user_stylesheet:     string,    // owned: path of a user CSS file ("" = none)
	color_scheme:        Color_Scheme,
	reduced_motion:      bool,
	prefers_contrast:    bool,
	default_font_size:   f32,
	monospace_font_size: f32,
	minimum_font_size:   f32,
	text_color:          css.Color,
	background_color:    css.Color,
	link_color:          css.Color,
	visited_color:       css.Color,
	active_link_color:   css.Color,
	body_margin:         f32,
	// generic family -> concrete family names, used by the painter
	family_serif, family_sans_serif, family_monospace, family_cursive, family_fantasy, family_system_ui: string,  // owned
	default_generic:     string,    // owned: the generic family used when a page names none
	line_height_normal:  f32,       // multiple of font size for `line-height: normal`
}

PREFS := [?]config.Def{
	{name = "style.max_nesting_depth", kind = .Int, default = {i = 256}, bounded = true, min = 8, max = 100_000,
		description = "Deepest nesting of blocks and functions in a stylesheet; deeper ones are skipped (stack protection)."},
	{name = "style.max_rules_per_sheet", kind = .Int, default = {i = 200_000}, bounded = true, min = 100, max = 100_000_000,
		description = "Most rules read from one stylesheet; the rest is ignored."},
	{name = "style.max_rules_total", kind = .Int, default = {i = 1_000_000}, bounded = true, min = 100, max = 1_000_000_000,
		description = "Most style rules active in one document, all sheets together."},
	{name = "style.max_sheet_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest stylesheet that is parsed; a bigger one is ignored."},
	{name = "style.max_import_depth", kind = .Int, default = {i = 8}, bounded = true, min = 0, max = 64,
		description = "How deep @import may chain. 0 disables @import."},
	{name = "style.max_selector_compounds", kind = .Int, default = {i = 32}, bounded = true, min = 2, max = 1000,
		description = "Longest complex selector (compound selectors joined by combinators); longer ones are dropped. Matching is recursive and bounded by this."},
	{name = "style.max_var_depth", kind = .Int, default = {i = 32}, bounded = true, min = 1, max = 1000,
		description = "How many var() references may chain before the value is invalid."},
	{name = "style.max_var_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 64, max = 1 << 28, bytes = true, unit = "bytes",
		description = "Largest value var() may expand to (stops exponential blow-up from nested custom properties)."},
	{name = "style.restyle_waste_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1 << 20, max = 1 << 36, bytes = true, unit = "bytes",
		description = "Partial restyles (hover, focus) allocate new computed styles; once this much has piled up the next restyle is a full pass that frees it."},
	{name = "style.ua_stylesheet.enabled", kind = .Bool, default = {b = true}, description = "Use the browser's default styles (headings, lists, links...). Without them pages are unstyled."},
	{name = "style.author_stylesheets.enabled", kind = .Bool, default = {b = true}, description = "Apply the styles that pages bring. Off: every page is shown with browser styles only."},
	{name = "style.author_colors.enabled", kind = .Bool, default = {b = true}, description = "Let pages set colors. Off: color and background properties from pages are ignored."},
	{name = "style.author_fonts.enabled", kind = .Bool, default = {b = true}, description = "Let pages set fonts. Off: font-family and font-size from pages are ignored."},
	{name = "style.user_stylesheet", kind = .String, default = {s = ""}, description = "Path of a CSS file applied to every page with user priority (empty = none)."},
	{name = "style.color_scheme", kind = .String, default = {s = "auto"}, choices = {"auto", "light", "dark"},
		description = "prefers-color-scheme reported to pages and used by light-dark(). auto follows the operating system."},
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
	{name = "font.line_height.normal", kind = .Float, default = {f = 1.2}, bounded = true, min = 1, max = 3, description = "What `line-height: normal` means, as a multiple of the font size."},
	{name = "page.color.text", kind = .String, default = {s = "#000000"}, description = "Default text color of pages (CSS color)."},
	{name = "page.color.background", kind = .String, default = {s = "#ffffff"}, description = "Default background color of pages (CSS color)."},
	{name = "page.color.link", kind = .String, default = {s = "#0000ee"}, description = "Color of links."},
	{name = "page.color.visited", kind = .String, default = {s = "#551a8b"}, description = "Color of visited links."},
	{name = "page.color.active_link", kind = .String, default = {s = "#ee0000"}, description = "Color of a link being pressed."},
	{name = "page.body_margin", kind = .Float, default = {f = 8}, bounded = true, min = 0, max = 200, unit = "px", description = "Margin around the body of a page."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

@(private)
color_pref :: proc(p: ^config.Prefs, name: string, fallback: css.Color) -> css.Color {
	text := config.string_of(p, name)
	arena := context.temp_allocator
	toks := css.tokenize(text, arena)
	vals := make([dynamic]css.Value, arena)
	for t in toks { append(&vals, css.Value{kind = .Token, tok = t}) }
	if cv, ok := css.parse_color(vals[:], nil); ok && cv.kind == .Rgba { return cv.rgba }
	return fallback
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.max_nesting_depth = int(config.int_of(p, "style.max_nesting_depth"))
	s.max_rules_per_sheet = int(config.int_of(p, "style.max_rules_per_sheet"))
	s.max_rules_total = int(config.int_of(p, "style.max_rules_total"))
	s.max_sheet_bytes = int(config.int_of(p, "style.max_sheet_bytes"))
	s.max_import_depth = int(config.int_of(p, "style.max_import_depth"))
	s.max_selector_compounds = int(config.int_of(p, "style.max_selector_compounds"))
	s.max_var_depth = int(config.int_of(p, "style.max_var_depth"))
	s.max_var_bytes = int(config.int_of(p, "style.max_var_bytes"))
	s.restyle_waste_bytes = int(config.int_of(p, "style.restyle_waste_bytes"))
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
	s.text_color = color_pref(p, "page.color.text", {0, 0, 0, 1})
	s.background_color = color_pref(p, "page.color.background", {1, 1, 1, 1})
	s.link_color = color_pref(p, "page.color.link", {0, 0, 0.93, 1})
	s.visited_color = color_pref(p, "page.color.visited", {0.33, 0.1, 0.55, 1})
	s.active_link_color = color_pref(p, "page.color.active_link", {0.93, 0, 0, 1})
	s.body_margin = f32(config.float_of(p, "page.body_margin"))
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
	case "serif": return s.family_serif
	case "sans-serif": return s.family_sans_serif
	case "monospace": return s.family_monospace
	case "cursive": return s.family_cursive
	case "fantasy": return s.family_fantasy
	case "system-ui", "ui-sans-serif", "-apple-system", "ui-serif", "ui-rounded", "ui-monospace": return s.family_system_ui
	}
	return ""
}
