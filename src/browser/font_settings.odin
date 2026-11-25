package browser

import "core:strings"
import "toolkit:font"
import config "toolkit:config"
import "wb:host"
import "wb:style"

////////////////////////////////
// Text rendering and shaping (toolkit:font on DirectWrite): glyph bitmaps, the atlas, color glyphs, the system fallback
// and the shaped-word cache, plus the generic families the style settings do not map. The whole window shares one font
// state (chrome and pages).

// The text settings are the toolkit's (prefs_page's Text set: appearance.text.*), applied to the font state by standard_watch,
// at the start and at each change; Wren's own defaults of them are in settings.odin (register_all_prefs: Slug). The text backend is
// the build's (WREN_TEXT), and the emoji are the compiled-in font's unless appearance.text.emoji_font names another. Wren's own
// settings here are about web content: the families pages ask for by a generic name.
FONT_PREFS := [?]config.Def{
	{name = "font.family.emoji", kind = .String, default = {s = style.FONT_EMOJI}, description = "Font used for the generic family `emoji`."},
	{name = "font.family.math", kind = .String, default = {s = style.FONT_MATH}, description = "Font used for the generic family `math`."},
	{name = "font.family.fangsong", kind = .String, default = {s = "FangSong"}, description = "Font used for the generic family `fangsong`."},
}

register_font_prefs :: proc(p: ^config.Prefs) { config.register(p, FONT_PREFS[:]) }

Font_Generics_Settings :: struct {
	generics_loaded:  bool,
	web_faces_loaded: bool,
	emoji:            string,   // owned
	math:             string,   // owned
	fangsong:         string,   // owned
	web_faces_kept:   int,
}

font_generics_settings_from_prefs :: proc(p: ^config.Prefs) -> Font_Generics_Settings {
	s := Font_Generics_Settings{web_faces_kept = 64}
	if config.ref_of(p, "font.family.emoji") != config.NO_REF {
		s.generics_loaded = true
		s.emoji = strings.clone(config.string_of(p, "font.family.emoji"))
		s.math = strings.clone(config.string_of(p, "font.family.math"))
		s.fangsong = strings.clone(config.string_of(p, "font.family.fangsong"))
	}
	if config.ref_of(p, "font.web_faces.kept") != config.NO_REF {
		s.web_faces_loaded = true
		s.web_faces_kept = int(config.int_of(p, "font.web_faces.kept"))
	}
	return s
}

font_generics_settings_destroy :: proc(s: ^Font_Generics_Settings) {
	delete(s.emoji)
	delete(s.math)
	delete(s.fangsong)
	s^ = {}
}

// The font state's settings at its start: the toolkit's defaults, the page size of the atlas (appearance.text.page_size, which
// font.init alone reads: standard_watch leaves it to the program) and the emoji engine of the emoji font (emoji_source_apply).
// Every other text setting reaches the font state through standard_watch, once the first window's interface exists.
font_settings_start :: proc(p: ^config.Prefs) -> font.Settings {
	s := font.DEFAULT_SETTINGS
	if config.ref_of(p, "appearance.text.page_size") != config.NO_REF { s.page_size = int(config.int_of(p, "appearance.text.page_size")) }
	s.color_engine = emoji_font_path(p) != "" ? .Builtin : .System
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

// What Wren's COLR interpreter draws emoji from: the font file appearance.text.emoji_font names, else EMOJI_BUILTIN (the
// compiled-in font); "" when there is neither, and emoji come from the system's font.
EMOJI_BUILTIN :: "<built-in>"

@(private = "file")
font_emoji_settings_from_prefs :: proc(p: ^config.Prefs, allocator := context.temp_allocator) -> string {
	if config.ref_of(p, "appearance.text.emoji_font") != config.NO_REF {
		if own := strings.trim_space(config.string_of(p, "appearance.text.emoji_font")); own != "" { return strings.clone(own, allocator) }
	}
	return len(emoji_builtin) > 0 ? EMOJI_BUILTIN : ""
}

emoji_font_path :: proc(p: ^config.Prefs, allocator := context.temp_allocator) -> string {
	return font_emoji_settings_from_prefs(p, allocator)
}

// Hands the emoji font to the font state, with the engine that draws it: Wren's COLR interpreter for a font of its own, the
// system's (Direct2D on Windows) when there is none. At the start only: appearance.text.emoji_font takes effect at the next
// one (Def.restart).
@(private)
emoji_source_apply :: proc(app: ^App) {
	want := emoji_font_path(&app.prefs)
	if want != "" && want != EMOJI_BUILTIN && !is_file(want) { want = "" }   // missing: the system's emoji font
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
	engine := want != "" ? font.Color_Engine.Builtin : .System
	if app.fonts.settings.color_engine != engine {
		s := app.fonts.settings
		s.color_engine = engine
		font.set_settings(&app.fonts, s)
	}
}

// The generic families are resolved again when their preferences change; the emoji font is handed to the font state.
font_settings_init :: proc(app: ^App) {
	font_generics_apply(app)
	emoji_source_apply(app)   // the face loads when the first emoji needs it, not now
	// color glyphs drawn on their thread: a frame shows them (host.post wakes the loop from any thread)
	font.set_color_ready_callback(&app.fonts, proc(user: rawptr) {
		a := (^App)(user)
		host.post(&a.loop, proc(data: rawptr) { app := (^App)(data); request_frames(app, 2) }, a, .Input)
	}, app)
	config.watch(&app.prefs, "font.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		a := (^App)(user)
		font_generics_apply(a)
		request_frames(a, 2)
	}, app)
}

@(private)
font_generics_apply :: proc(app: ^App) {
	if !app.font_cfg.generics_loaded { return }
	page_fonts_set_generics(&app.page_render.fonts, app.font_cfg.emoji, app.font_cfg.math, app.font_cfg.fangsong)
}
