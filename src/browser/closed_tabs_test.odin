package browser

// Pure closed-tabs store tests live in src/profile/closed_tabs_test.odin.
// These tests cover the browser session helpers that closed_tabs.odin calls.

import "core:testing"

@(test)
session_kept_drops_what_comes_back_by_itself :: proc(t: ^testing.T) {
	windows := []Session_Window{
		{tabs = {{url = "pinned", pinned = true}, {url = "a"}, {url = "b"}}, current = 2},
		{tabs = {{url = "only pinned", pinned = true}}},
		{},
	}
	kept := session_kept(windows, drop_pinned = true)
	testing.expect_value(t, len(kept), 1)
	if len(kept) == 1 {
		testing.expect_value(t, len(kept[0].tabs), 2)
		testing.expect_value(t, kept[0].tabs[kept[0].current].url, "b")
	}
	testing.expect_value(t, len(session_kept(windows)), 2)
}

@(test)
session_tab_blank_is_a_tab_with_nothing_to_show :: proc(t: ^testing.T) {
	testing.expect(t, session_tab_blank({url = HOME_URL}))
	testing.expect(t, session_tab_blank({url = "about:blank"}))
	testing.expect(t, !session_tab_blank({url = "https://a/"}))
}
