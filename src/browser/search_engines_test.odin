package browser

// Pure search engine store tests live in src/profile/search_engines_test.odin.
// These tests cover the browser address-bar and preference-registration integration.

import "core:strings"
import "core:testing"
import config "toolkit:config"

@(test)
search_engine_address_bar_integration :: proc(t: ^testing.T) {
	test_app(t)
	se: Search_Engines
	defer engines_destroy(&se)
	engines_builtin(&se)
	g := engines_find(&se, "google")

	// the address bar: a keyword first, words with the default, addresses stay addresses
	target, s := address_target_in(&se, "bing", "@g cats")
	testing.expect_value(t, target, "https://www.google.com/search?q=cats")
	hit, is := s.?
	testing.expect(t, is && hit.engine == g && hit.words == "cats")
	target, s = address_target_in(&se, "bing", "two words")
	testing.expect_value(t, target, "https://www.bing.com/search?q=two+words")
	testing.expect(t, s != nil)
	target, s = address_target_in(&se, "bing", "example.com")
	testing.expect_value(t, target, "example.com")
	testing.expect(t, s == nil)
	target, _ = address_target_in(&se, "bing", "@w example.com")   // a keyword wins over an address
	testing.expect_value(t, target, "https://en.wikipedia.org/w/index.php?search=example.com")
	// a keyword without "@"
	k := engines_add(&se, "Kagi", "k", "https://kagi.com/search?q=%s")
	target, s = address_target_in(&se, "bing", "k rust odin")
	testing.expect_value(t, target, "https://kagi.com/search?q=rust+odin")
	hit, _ = s.?
	testing.expect_value(t, hit.engine, k)

	// read from the profile's preferences: the custom address is no longer registered, the engine is
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	config.set_from_string(&p, "browser.search.engine", "custom", .User)
	config.set_from_string(&p, "browser.search.custom_url", "https://old.test/s?k=%s", .User)
	register_interaction_prefs(&p)
	testing.expect_value(t, config.string_of(&p, "browser.search.engine"), "custom")
	url, has := config.user_text(&p, "browser.search.custom_url")
	testing.expect(t, engines_migrate(&se, config.string_of(&p, "browser.search.engine"), url, has))
	target, _ = address_target_in(&se, config.string_of(&p, "browser.search.engine"), "old words")
	testing.expect_value(t, target, "https://old.test/s?k=old+words")
	testing.expect(t, strings.has_prefix(engines_serialize(&se), SEARCH_ENGINES_MAGIC))
}
