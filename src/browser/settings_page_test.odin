package browser

import "core:testing"
import "wb:config"

// Every preference about:settings lists is registered and on one page only; the pages are each other's. The categories of
// the registry stay about:config's: a page lists its preferences by name.
@(test)
settings_pages_name_registered_preferences :: proc(t: ^testing.T) {
	test_app(t)
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	pages := make(map[string]bool, context.temp_allocator)
	named := make(map[string]string, context.temp_allocator)
	for pg in SETTINGS_PAGES {
		testing.expect(t, !pages[pg.category], pg.category)
		pages[pg.category] = true
		for name in pg.names {
			_, ok := p.index[name]
			testing.expectf(t, ok, "about:settings lists %s, which is not registered", name)
			if other, twice := named[name]; twice { testing.expectf(t, false, "%s is on %q and %q", name, other, pg.category) }
			named[name] = pg.category
		}
	}
}

// Wren's look and its old habits are the standard settings' defaults (settings.odin STANDARD_DEFAULTS and its values), and the
// browser's own settings that said the same are gone: one setting per concept.
@(test)
standard_settings_have_wren_defaults :: proc(t: ^testing.T) {
	test_app(t)
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	testing.expect_value(t, config.string_of(&p, "appearance.theme"), "Silver")
	testing.expect_value(t, config.string_of(&p, "appearance.finish"), "flat")
	testing.expect_value(t, config.float_of(&p, "appearance.font_size"), 15)
	testing.expect_value(t, config.bool_of(&p, "window.system_title"), false)
	testing.expect_value(t, config.bool_of(&p, "update.auto"), false)
	testing.expect_value(t, config.string_of(&p, "update.base_url"), UPDATE_DOWNLOAD_BASE)
	testing.expect_value(t, config.bool_of(&p, "scrolling.autohide_scrollbars"), true)
	testing.expect_value(t, config.float_of(&p, "scrolling.autoscroll.max_speed"), AUTOSCROLL_TOP_SPEED)
	testing.expect_value(t, config.float_of(&p, "scrolling.autoscroll.full_dist"), AUTOSCROLL_FULL_DISTANCE)
	testing.expect_value(t, config.bool_of(&p, "rendering.partial_redraw"), true)
	testing.expect_value(t, config.string_of(&p, "rendering.filter_precision"), "unorm8")
	for gone in ([]string{"browser.ui.theme", "browser.ui.theme_mode", "browser.ui.font_size", "browser.ui.zoom", "browser.ui.animations",
		"browser.ui.scrollbar_autohide", "browser.ui.machined_glow", "browser.ui.partial_redraw", "browser.window.integrated_titlebar",
		"browser.update.check_daily", "browser.update.base_url", "browser.scroll.autoscroll.enabled", "browser.scroll.smooth.enabled",
		"browser.frame.present_mode", "paint.effects.blur_full_resolution_px", "paint.effects.filter_precision"}) {
		testing.expectf(t, gone not_in p.index, "%s says what a standard setting says", gone)
	}
}
