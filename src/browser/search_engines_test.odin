package browser

import "core:os"
import "core:strings"
import "core:testing"
import "wb:config"

// The search engines (search_engines.odin): the list, the addresses, the keywords, the editing rules, the profile's
// file and the migration of a profile of before the list.

@(test)
search_engine_urls :: proc(t: ^testing.T) {
	testing.expect_value(t, engine_url({url = "https://s.test/?q=%s&x=1"}, "caf\u00e9 & tea"), "https://s.test/?q=caf%C3%A9+%26+tea&x=1")
	testing.expect_value(t, engine_url({url = "https://s.test/find/"}, "a b"), "https://s.test/find/a+b")   // no %s: at the end
	testing.expect_value(t, engine_url({url = "https://s.test/?a=%s&b=%s"}, "x"), "https://s.test/?a=x&b=x")
	testing.expect_value(t, engine_initial({name = "duckDuckGo"}), "D")
	testing.expect_value(t, engine_initial({name = "  \u00e9cole"}), "\u00c9")
	testing.expect_value(t, engine_initial({name = ""}), "?")
}

@(test)
search_engines_builtin_and_default :: proc(t: ^testing.T) {
	se: Search_Engines
	defer engines_destroy(&se)
	testing.expect_value(t, engines_default(&se, "google"), -1)
	testing.expect_value(t, engine_at(&se, -1).id, "duckduckgo")   // an empty list still searches
	engines_builtin(&se)
	testing.expect_value(t, len(se.list), len(BUILTIN_ENGINES))
	testing.expect_value(t, se.list[engines_default(&se, "google")].name, "Google")
	testing.expect_value(t, engines_default(&se, "gone"), 0)   // an id the list lacks: its first engine
	testing.expect_value(t, engines_missing_builtins(&se), 0)
	engines_remove(&se, engines_find(&se, "bing"))
	engines_remove(&se, engines_find(&se, "qwant"))
	testing.expect_value(t, engines_missing_builtins(&se), 2)
	testing.expect_value(t, engines_restore_builtins(&se), 2)
	testing.expect(t, engines_find(&se, "bing") >= 0 && engines_find(&se, "qwant") >= 0)
	testing.expect_value(t, engines_restore_builtins(&se), 0)
}

@(test)
search_engine_keywords :: proc(t: ^testing.T) {
	se: Search_Engines
	defer engines_destroy(&se)
	engines_builtin(&se)
	g := engines_find(&se, "google")
	i, words, ok := engines_keyword(&se, "  @G   cats and dogs ")
	testing.expect(t, ok && i == g && words == "cats and dogs", "a keyword, letter case aside")
	_, _, ok = engines_keyword(&se, "@g")
	testing.expect(t, !ok, "a keyword alone searches nothing")
	_, _, ok = engines_keyword(&se, "@zz cats")
	testing.expect(t, !ok, "no engine has that keyword")
	_, _, ok = engines_keyword(&se, "cats @g")
	testing.expect(t, !ok, "only the first word")

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
}

@(test)
search_engine_editing :: proc(t: ^testing.T) {
	se: Search_Engines
	defer engines_destroy(&se)
	engines_builtin(&se)
	testing.expect_value(t, engine_validate(&se, -1, "", "", "https://a.test/?q=%s"), Engine_Error.No_Name)
	testing.expect_value(t, engine_validate(&se, -1, "A", "", "ftp://a.test/%s"), Engine_Error.Bad_Url)
	testing.expect_value(t, engine_validate(&se, -1, "A", "", "https://"), Engine_Error.Bad_Url)
	testing.expect_value(t, engine_validate(&se, -1, "A", "", "https://a.test/?q="), Engine_Error.No_Placeholder)
	testing.expect_value(t, engine_validate(&se, -1, "A", "a b", "https://a.test/?q=%s"), Engine_Error.Keyword_Space)
	testing.expect_value(t, engine_validate(&se, -1, "A", "@G", "https://a.test/?q=%s"), Engine_Error.Keyword_Taken)
	testing.expect_value(t, engine_validate(&se, -1, "google", "", "https://a.test/?q=%s"), Engine_Error.Name_Taken)
	testing.expect_value(t, engine_validate(&se, -1, "A", "@a", "HTTPS://a.test/?q=%s"), Engine_Error.None)
	g := engines_find(&se, "google")
	testing.expect_value(t, engine_validate(&se, g, "Google", "@g", "https://www.google.fr/search?q=%s"), Engine_Error.None)   // itself

	// ids: from the name, unique; an edit keeps it
	a := engines_add(&se, "  My Wiki! ", " @m ", " https://w.test/?s=%s ")
	testing.expect_value(t, se.list[a].id, "my-wiki")
	testing.expect_value(t, se.list[a].name, "My Wiki!")
	testing.expect_value(t, se.list[a].keyword, "@m")
	b := engines_add(&se, "My wiki?", "", "https://w2.test/?s=%s")
	testing.expect_value(t, se.list[b].id, "my-wiki-2")
	c := engines_add(&se, "\u00e9\u00e9", "", "https://w3.test/?s=%s")
	testing.expect_value(t, se.list[c].id, "engine")
	serial := se.serial
	engines_update(&se, g, "Google FR", "@gf", "https://www.google.fr/search?q=%s")
	testing.expect_value(t, se.list[g].id, "google")
	testing.expect_value(t, se.list[g].name, "Google FR")
	testing.expect(t, se.serial != serial, "a change bumps the serial")
	// order
	engines_move(&se, 0, -1)   // (already first: nothing)
	testing.expect_value(t, se.list[0].id, "duckduckgo")
	engines_move(&se, 0, 1)
	testing.expect_value(t, se.list[1].id, "duckduckgo")
	engines_move(&se, len(se.list) - 1, 1)   // (already last)
}

@(test)
search_engines_file_round_trip :: proc(t: ^testing.T) {
	se: Search_Engines
	defer engines_destroy(&se)
	engines_builtin(&se)
	engines_remove(&se, engines_find(&se, "bing"))
	_ = engines_add(&se, "Tab\there", "@t", "https://t.test/?q=%s&a=\\b")
	path := "build/search_engines_test.txt"
	defer os.remove(path)
	testing.expect(t, engines_save_file(&se, path))
	back: Search_Engines
	defer engines_destroy(&back)
	testing.expect(t, engines_load_file(&back, path))
	testing.expect_value(t, len(back.list), len(se.list))
	for e, i in se.list { testing.expect(t, back.list[i] == e, e.id) }
	testing.expect_value(t, engines_find(&back, "bing"), -1)

	// not such a file, another version: the list stays
	testing.expect(t, !engines_parse(&back, "wren-search-engines 2\nx\tX\t\thttps://x.test/%s\n"))
	testing.expect(t, !engines_parse(&back, ""))
	testing.expect_value(t, len(back.list), len(se.list))
	// a byte-order mark, comments, CRLF, malformed lines and a second id are skipped
	testing.expect(t, engines_parse(&back, "\xEF\xBB\xBFwren-search-engines 1\r\n# c\r\na\tA\t@a\thttps://a.test/%s\r\nbad line\r\n\tNo id\t\thttps://n.test/%s\r\na\tAgain\t\thttps://b.test/%s\r\nb\tB\t\thttps://b.test/%s\r\n"))
	testing.expect_value(t, len(back.list), 2)
	testing.expect_value(t, back.list[0].name, "A")
	testing.expect_value(t, back.list[1].id, "b")
	testing.expect(t, !engines_load_file(&back, "build/no_such_engines_file.txt"))
}

// A profile of before the list: its choice stays the default, its custom address becomes an engine.
@(test)
search_engines_migration :: proc(t: ^testing.T) {
	se: Search_Engines
	defer engines_destroy(&se)
	testing.expect(t, !engines_migrate(&se, "google", "", false), "a built-in choice: nothing of its own to write")
	testing.expect_value(t, se.list[engines_default(&se, "google")].id, "google")
	testing.expect(t, engines_migrate(&se, "custom", "https://c.test/?q=%s", true))
	i := engines_default(&se, "custom")
	testing.expect_value(t, se.list[i].id, "custom")
	testing.expect_value(t, se.list[i].url, "https://c.test/?q=%s")
	testing.expect_value(t, len(se.list), len(BUILTIN_ENGINES) + 1)
	testing.expect(t, engines_migrate(&se, "custom", "", false))
	testing.expect_value(t, se.list[engines_default(&se, "custom")].url, FALLBACK_ENGINE.url)   // its former default

	// read from the profile's preferences: the custom address is no longer registered, the engine is
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	config.set_from_string(&p, "browser.search.engine", "custom", .User)
	config.set_from_string(&p, "browser.search.custom_url", "https://old.test/s?k=%s", .User)
	register_interaction_prefs(&p)
	testing.expect_value(t, config.string_of(&p, "browser.search.engine"), "custom")
	url, has := config.user_text(&p, "browser.search.custom_url")
	testing.expect(t, engines_migrate(&se, config.string_of(&p, "browser.search.engine"), url, has))
	target, _ := address_target_in(&se, config.string_of(&p, "browser.search.engine"), "old words")
	testing.expect_value(t, target, "https://old.test/s?k=old+words")
	testing.expect(t, strings.has_prefix(engines_serialize(&se), SEARCH_ENGINES_MAGIC))
}
