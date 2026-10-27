package browser

import "core:strings"
import "wb:config"

// Preferences of the interactions with the page and the chrome: selection, find in page, context menus, page zoom,
// search, closed tabs (about:config: browser.selection.*, browser.find.*, browser.contextmenu.*, browser.zoom.*,
// browser.search.*, browser.tabs.*).

Interaction_Settings :: struct {
	sel_bg, sel_fg, sel_inactive_bg: string,   // "" = the system's colors (owned)
	word_eats_space:      bool,
	drag_threshold_px:    f32,
	autoscroll_speed:     f32,
	autoscroll_max:       f32,
	find_bg, find_active_bg: string,           // owned
	find_case_sensitive:  bool,
	find_max_matches:     int,
	ctx_shift_forces:     bool,
	zoom_min, zoom_max:   f32,
	zoom_levels:          [dynamic]f32,
	search_engine:        string,              // owned
	search_custom:        string,              // owned
	closed_tabs_max:      int,
	source_colors:        bool,
}

INTERACTION_PREFS := [?]config.Def{
	{name = "browser.selection.background", kind = .String, default = {s = ""},
		description = "Background of selected text when the page has no ::selection style: a #rrggbb or #rrggbbaa color, empty for the system's highlight color (Windows: the accent color)."},
	{name = "browser.selection.foreground", kind = .String, default = {s = ""},
		description = "Color of selected text when the page has no ::selection style: #rrggbb, empty for the system's highlight text color, or 'keep' to leave the text's own color."},
	{name = "browser.selection.inactive_background", kind = .String, default = {s = ""},
		description = "Background of selected text while the window is not active: #rrggbb[aa], empty for a grey from the system's colors."},
	{name = "browser.selection.word_eats_space", kind = .Bool, default = {b = true},
		description = "A double click on a word also selects the spaces after it (the Windows convention)."},
	{name = "browser.selection.drag_threshold_px", kind = .Float, default = {f = 4}, bounded = true, min = 0, max = 64, unit = "px",
		description = "How far the pointer moves with the button held before a drag starts selecting (and a click on a link no longer follows it)."},
	{name = "browser.selection.autoscroll_speed", kind = .Float, default = {f = 12}, bounded = true, min = 0, max = 200, unit = "1/s",
		description = "Scrolling while a selection is dragged past the edge of the page (or of a scroll box): pixels per second per pixel of distance past the edge. 0 = no automatic scrolling."},
	{name = "browser.selection.autoscroll_max_px_s", kind = .Float, default = {f = 4000}, bounded = true, min = 10, max = 100_000, unit = "px/s",
		description = "Fastest automatic scrolling while a selection is dragged."},
	{name = "browser.find.highlight", kind = .String, default = {s = "#ffff0090"},
		description = "Background of the matches of find in page (#rrggbb[aa])."},
	{name = "browser.find.active_highlight", kind = .String, default = {s = "#ff9632ff"},
		description = "Background of the current match of find in page (#rrggbb[aa])."},
	{name = "browser.find.case_sensitive", kind = .Bool, default = {b = false},
		description = "Find in page matches letter case exactly."},
	{name = "browser.find.max_matches", kind = .Int, default = {i = 5000}, bounded = true, min = 1, max = 1_000_000,
		description = "Matches find in page counts and highlights at most (a very common word in a huge page stays fast)."},
	{name = "browser.contextmenu.shift_forces_native", kind = .Bool, default = {b = true},
		description = "Shift + right click opens the browser's context menu even when the page cancels the contextmenu event (as in Firefox)."},
	{name = "browser.zoom.levels", kind = .String, default = {s = "25,33,50,67,75,80,90,100,110,125,150,175,200,250,300,400,500"},
		description = "Page zoom steps of Ctrl+Plus / Ctrl+Minus, in percent, comma separated."},
	{name = "browser.zoom.min_percent", kind = .Float, default = {f = 25}, bounded = true, min = 10, max = 100, unit = "%",
		description = "Smallest page zoom (Ctrl+wheel goes down to it)."},
	{name = "browser.zoom.max_percent", kind = .Float, default = {f = 500}, bounded = true, min = 100, max = 1000, unit = "%",
		description = "Largest page zoom."},
	{name = "browser.search.engine", kind = .String, default = {s = "duckduckgo"}, choices = {"duckduckgo", "bing", "google", "qwant", "ecosia", "startpage", "custom"},
		description = "Search engine of the context menu's \"Search for\" and of addresses that are not URLs. custom: browser.search.custom_url."},
	{name = "browser.search.custom_url", kind = .String, default = {s = "https://duckduckgo.com/?q=%s"},
		description = "Search URL when browser.search.engine is custom: %s is replaced by the words searched (percent-encoded)."},
	{name = "browser.tabs.closed_max", kind = .Int, default = {i = 25}, bounded = true, min = 0, max = 1000, category = "tabs",
		description = "Closed tabs Ctrl+Shift+T can reopen (most recent first)."},
	{name = "browser.view_source.colors", kind = .Bool, default = {b = true},
		description = "view-source: pages color tags, attributes and comments."},
}

register_interaction_prefs :: proc(p: ^config.Prefs) { config.register(p, INTERACTION_PREFS[:]) }

interaction_settings_from_prefs :: proc(p: ^config.Prefs) -> Interaction_Settings {
	s := Interaction_Settings{
		sel_bg = strings.clone(config.string_of(p, "browser.selection.background")),
		sel_fg = strings.clone(config.string_of(p, "browser.selection.foreground")),
		sel_inactive_bg = strings.clone(config.string_of(p, "browser.selection.inactive_background")),
		word_eats_space = config.bool_of(p, "browser.selection.word_eats_space"),
		drag_threshold_px = f32(config.float_of(p, "browser.selection.drag_threshold_px")),
		autoscroll_speed = f32(config.float_of(p, "browser.selection.autoscroll_speed")),
		autoscroll_max = f32(config.float_of(p, "browser.selection.autoscroll_max_px_s")),
		find_bg = strings.clone(config.string_of(p, "browser.find.highlight")),
		find_active_bg = strings.clone(config.string_of(p, "browser.find.active_highlight")),
		find_case_sensitive = config.bool_of(p, "browser.find.case_sensitive"),
		find_max_matches = int(config.int_of(p, "browser.find.max_matches")),
		ctx_shift_forces = config.bool_of(p, "browser.contextmenu.shift_forces_native"),
		zoom_min = f32(config.float_of(p, "browser.zoom.min_percent")) / 100,
		zoom_max = f32(config.float_of(p, "browser.zoom.max_percent")) / 100,
		search_engine = strings.clone(config.string_of(p, "browser.search.engine")),
		search_custom = strings.clone(config.string_of(p, "browser.search.custom_url")),
		closed_tabs_max = int(config.int_of(p, "browser.tabs.closed_max")),
		source_colors = config.bool_of(p, "browser.view_source.colors"),
	}
	rest := config.string_of(p, "browser.zoom.levels")
	for part in strings.split_iterator(&rest, ",") {
		v := parse_percent(strings.trim_space(part))
		if v > 0 { append(&s.zoom_levels, clamp(v / 100, s.zoom_min, s.zoom_max)) }
	}
	if len(s.zoom_levels) == 0 { append(&s.zoom_levels, 1) }
	// sorted, without duplicates
	for i in 1 ..< len(s.zoom_levels) {
		x := s.zoom_levels[i]
		j := i - 1
		for j >= 0 && s.zoom_levels[j] > x { s.zoom_levels[j + 1] = s.zoom_levels[j]; j -= 1 }
		s.zoom_levels[j + 1] = x
	}
	return s
}

interaction_settings_destroy :: proc(s: ^Interaction_Settings) {
	delete(s.sel_bg); delete(s.sel_fg); delete(s.sel_inactive_bg)
	delete(s.find_bg); delete(s.find_active_bg)
	delete(s.search_engine); delete(s.search_custom)
	delete(s.zoom_levels)
	s^ = {}
}

@(private = "file")
parse_percent :: proc(s: string) -> f32 {
	v: f32
	frac: f32 = 0
	seen := false
	for c in transmute([]u8)s {
		switch {
		case c >= '0' && c <= '9':
			seen = true
			if frac > 0 { v += f32(c - '0') * frac; frac *= 0.1 } else { v = v * 10 + f32(c - '0') }
		case c == '.' && frac == 0: frac = 0.1
		case c == '%':
		case: return 0
		}
	}
	return seen ? v : 0
}

// The URL that searches for `words` with the configured engine.
search_url :: proc(s: ^Interaction_Settings, words: string) -> string {
	q := percent_encode_query(words)
	template: string
	switch s.search_engine {
	case "bing": template = "https://www.bing.com/search?q=%s"
	case "google": template = "https://www.google.com/search?q=%s"
	case "qwant": template = "https://www.qwant.com/?q=%s"
	case "ecosia": template = "https://www.ecosia.org/search?q=%s"
	case "startpage": template = "https://www.startpage.com/do/search?query=%s"
	case "custom": template = s.search_custom
	case: template = "https://duckduckgo.com/?q=%s"
	}
	if !strings.contains(template, "%s") { return strings.concatenate({template, q}, context.temp_allocator) }
	out, _ := strings.replace_all(template, "%s", q, context.temp_allocator)
	return out
}

search_engine_name :: proc(s: ^Interaction_Settings) -> string {
	switch s.search_engine {
	case "bing": return "Bing"
	case "google": return "Google"
	case "qwant": return "Qwant"
	case "ecosia": return "Ecosia"
	case "startpage": return "Startpage"
	case "custom": return "the web"
	}
	return "DuckDuckGo"
}

@(private = "file")
percent_encode_query :: proc(s: string) -> string {
	HEX := "0123456789ABCDEF"
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&sb, c)
		case c == ' ': strings.write_byte(&sb, '+')
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 15])
		}
	}
	return strings.to_string(sb)
}
