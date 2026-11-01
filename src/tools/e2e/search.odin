package e2e_scenarios

// The search engines (search_engines.odin), against the test server (the engines' addresses point at it: nothing leaves the machine).

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SEARCH_PAGE :: "/site/about.html"
@(private = "file") ENGINES_FILE :: "search_engines.txt"

// A profile of before the list (browser.search.engine = custom, browser.search.custom_url) keeps its choice: words typed in the address
// bar go to its address, and search_engines.txt is written with an engine "Custom".
@(test)
search_former_custom_address :: proc(t: ^testing.T) {
	page := e2e.url(e2e.test_server(t), SEARCH_PAGE)
	profile := e2e.temp_profile(t)
	e2e.write_text(fmt.tprintf("%s/prefs.txt", profile), fmt.tprintf("wbprefs 1\nbrowser.search.engine\tcustom\nbrowser.search.custom_url\t%s?custom=%%s\n", page))
	s := e2e.start(t, {profile = profile})
	testing.expect_value(t, e2e.address_bar(s, "hello world"), fmt.tprintf("%s?custom=hello+world", page))
	text := e2e.read_text(fmt.tprintf("%s/%s", profile, ENGINES_FILE))
	testing.expectf(t, strings.has_prefix(text, "wren-search-engines 1") && strings.contains(text, fmt.tprintf("custom\tCustom\t\t%s?custom=%%s", page)), "the list is written with the former address as an engine, got %q", text)
	testing.expect(t, strings.contains(e2e.pref_get(s, "browser.search.engine"), "custom"), "browser.search.engine still names it")
}

// A browser whose profile has two engines: "one" (keyword @one), "two" (keyword t), and "two" for the default.
@(private = "file")
with_two_engines :: proc(t: ^testing.T, page: string, loc := #caller_location) -> (s: ^e2e.Session, profile: string) {
	profile = e2e.temp_profile(t)
	e2e.write_text(fmt.tprintf("%s/%s", profile, ENGINES_FILE), fmt.tprintf("wren-search-engines 1\none\tOne\t@one\t%s?one=%%s\ntwo\tTwo\tt\t%s?two=%%s\n", page, page))
	s = e2e.start(t, {profile = profile}, loc)
	e2e.pref_set(s, "browser.search.engine", "two")
	return
}

// The list of the profile: words go to the default, a keyword first to its engine, an id the list lacks to its first engine; Ctrl+Down in
// the suggestions picks the next engine for this time.
@(test)
search_list_of_the_profile :: proc(t: ^testing.T) {
	page := e2e.url(e2e.test_server(t), SEARCH_PAGE)
	s, _ := with_two_engines(t, page)
	testing.expect_value(t, e2e.address_bar(s, "a b"), fmt.tprintf("%s?two=a+b", page))
	testing.expect_value(t, e2e.address_bar(s, "@one x y"), fmt.tprintf("%s?one=x+y", page))
	testing.expect_value(t, e2e.address_bar(s, "t cats"), fmt.tprintf("%s?two=cats", page))
	testing.expect_value(t, e2e.address_bar(s, "pick me", {"Ctrl+Down"}), fmt.tprintf("%s?one=pick+me", page))
	e2e.address_bar_open(s)
	e2e.type_text(s, "see the engines")
	e2e.shot(s, "01 address bar suggestions.png")
	e2e.key(s, "Escape")
	e2e.key(s, "Escape")
	e2e.pref_set(s, "browser.search.engine", "gone")
	testing.expect_value(t, e2e.address_bar(s, "q"), fmt.tprintf("%s?one=q", page))
}

// about:config, category Search: Enter on the engines' row opens the form, typed name, keyword and address, Enter adds the engine
// (written to the profile at once), and its keyword works.
@(test)
search_engine_added_in_about_config :: proc(t: ^testing.T) {
	page := e2e.url(e2e.test_server(t), SEARCH_PAGE)
	s, profile := with_two_engines(t, page)
	e2e.pref_set(s, "browser.search.engine", "one")
	e2e.navigate(s, "about:config")
	e2e.key(s, "Ctrl+F")
	e2e.type_text(s, "search engines")
	e2e.key(s, "Down")
	e2e.key(s, "Down")
	e2e.shot(s, "02 about config search.png")
	e2e.key(s, "Enter")
	e2e.type_text(s, "Three")
	e2e.key(s, "Tab")
	e2e.type_text(s, "@3")
	e2e.key(s, "Tab")
	e2e.key(s, "Ctrl+A")
	e2e.type_text(s, fmt.tprintf("%s?three=%%s", page))
	e2e.shot(s, "03 about config adding.png")
	e2e.key(s, "Enter")
	e2e.shot(s, "04 about config added.png")
	text := e2e.read_text(fmt.tprintf("%s/%s", profile, ENGINES_FILE))
	testing.expectf(t, strings.contains(text, fmt.tprintf("three\tThree\t@3\t%s?three=%%s", page)), "the engine added in about:config is written to the profile, got %q", text)
	testing.expect_value(t, e2e.address_bar(s, "@3 ok"), fmt.tprintf("%s?three=ok", page))
}
