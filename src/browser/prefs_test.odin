package browser

import "core:strings"
import "core:testing"
import "toolkit:font"
import "wb:config"
import "wb:fetch"
import "wb:net"

// Every preference the browser ships must be well formed: this is what keeps about:config trustworthy.

@(test)
every_definition_is_valid :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	testing.expect(t, len(p.entries) > 40, "the registry lists the whole browser")
	seen := make(map[string]bool, context.temp_allocator)
	for e in p.entries {
		d := e.def
		testing.expect(t, d.name != "" && strings.to_lower(d.name, context.temp_allocator) == d.name, d.name)
		testing.expect(t, strings.contains(d.name, "."), d.name)
		testing.expect(t, d.description != "", d.name)
		testing.expect(t, !seen[d.name], d.name)
		seen[d.name] = true

		// the default must be accepted by the preference's own validation
		text := config.default_string(&p, config.ref_of(&p, d.name))
		_, err := config.parse_value(d, text)
		testing.expect_value(t, err, config.Set_Error.None, loc = {procedure = d.name})
		if len(d.choices) > 0 {
			found := false
			for c in d.choices { if c == d.default.s { found = true } }
			testing.expect(t, found, d.name)
		}
		if d.bounded { testing.expect(t, d.min <= d.max, d.name) }
	}
}

// text.renderer picks Slug (atlas is the default); the tolerance is given in thousandths of an em.
@(test)
text_renderer_preference_reaches_the_font_settings :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	s := font_settings_from_prefs(&p)
	testing.expect_value(t, s.text_renderer, font.Text_Renderer.Slug)   // the default
	testing.expect_value(t, config.set_from_string(&p, "text.renderer", "atlas", .User), config.Set_Error.None)
	s = font_settings_from_prefs(&p)
	testing.expect_value(t, s.text_renderer, font.Text_Renderer.Atlas)
	testing.expect_value(t, config.set_from_string(&p, "text.renderer", "slug", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "text.slug.pages", "32", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "text.slug.tolerance", "1", .User), config.Set_Error.None)
	s = font_settings_from_prefs(&p)
	testing.expect_value(t, s.text_renderer, font.Text_Renderer.Slug)
	testing.expect_value(t, s.slug_pages, 32)
	testing.expect(t, abs(s.slug_tolerance - 0.001) < 1e-6)
	testing.expect(t, config.set_from_string(&p, "text.renderer", "bitmap", .User) != config.Set_Error.None)   // not a choice
}

// text.emoji picks the built-in emoji (the default) or the system's; the font is the one next to the executable unless a
// path is given.
@(test)
emoji_preferences_reach_the_font_settings :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	s := font_settings_from_prefs(&p)
	testing.expect_value(t, s.color_engine, font.Color_Engine.Builtin)
	testing.expect_value(t, s.colr_samples, 8)
	testing.expect_value(t, s.colr_cache_kb, 8192)
	path := emoji_font_path(&p)
	testing.expect(t, strings.has_suffix(path, "\\emoji\\NotoColorEmoji-COLRv1.ttf"), path)
	testing.expect_value(t, config.set_from_string(&p, "text.emoji.font", "D:\\fonts\\Twemoji.ttf", .User), config.Set_Error.None)
	testing.expect_value(t, emoji_font_path(&p), "D:\\fonts\\Twemoji.ttf")
	testing.expect_value(t, config.set_from_string(&p, "text.emoji", "system", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "text.emoji.raster_samples", "16", .User), config.Set_Error.None)
	s = font_settings_from_prefs(&p)
	testing.expect_value(t, s.color_engine, font.Color_Engine.System)
	testing.expect_value(t, s.colr_samples, 16)
	testing.expect_value(t, emoji_font_path(&p), "")   // system emoji: no font file
	testing.expect(t, config.set_from_string(&p, "text.emoji", "twemoji", .User) != config.Set_Error.None)   // not a choice
	testing.expect(t, config.set_from_string(&p, "text.emoji.raster_samples", "0", .User) != config.Set_Error.None)   // out of bounds
}

@(test)
settings_round_trip_through_the_registry :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)

	testing.expect_value(t, config.set_from_string(&p, "network.max_connections_per_host", "2", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "privacy.third_party_cookies", "allow", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.bad_ports.allowed", "22, 6000, x", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.queue.low_water_bytes", "2M", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "network.queue.high_water_bytes", "1M", .User), config.Set_Error.None)

	ns := net.settings_from_prefs(&p)
	defer net.settings_destroy(&ns)
	testing.expect_value(t, ns.max_per_host, 2)
	testing.expect_value(t, ns.low_water, 1 << 20)   // clamped: low water can never exceed high water

	fs := fetch.settings_from_prefs(&p)
	defer fetch.settings_destroy(&fs)
	testing.expect_value(t, fs.third_party_cookies, fetch.Third_Party_Cookies.Allow)
	testing.expect_value(t, len(fs.bad_ports_allowed), 2)   // the invalid entry is ignored

	bs := settings_from_prefs(&p)
	defer delete(bs.homepage)
	defer delete(bs.ui_theme)
	testing.expect_value(t, bs.homepage, "about:home")
}
