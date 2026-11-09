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
