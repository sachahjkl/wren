package browser

import "core:testing"
import "wb:config"

// Every preference about:settings lists is registered, under its page's category, and the pages are each other's.
@(test)
settings_pages_name_registered_preferences :: proc(t: ^testing.T) {
	test_app(t)
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	seen := make(map[string]bool, context.temp_allocator)
	for pg in SETTINGS_PAGES {
		testing.expect(t, !seen[pg.category], pg.category)
		seen[pg.category] = true
		for name in pg.names {
			i, ok := p.index[name]
			testing.expectf(t, ok, "about:settings lists %s, which is not registered", name)
			if ok { testing.expectf(t, p.entries[i].def.category == pg.category, "%s is in %q, not %q", name, p.entries[i].def.category, pg.category) }
		}
	}
}
