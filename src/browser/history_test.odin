package browser

// Pure global history store tests live in src/profile/global_history_test.odin.
// These tests cover browser scroll restoration, session history trees, and tree layout.

import "core:testing"
import "wb:page"

// A scroller waits for enough room, unless the time is up: then it goes as far as it can.
@(test)
restore_waits_for_height :: proc(t: ^testing.T) {
	test_app(t)
	pos, done := restore_step(1200, 300, false)
	testing.expect(t, !done)
	pos, done = restore_step(1200, 1199.7, false)
	testing.expect(t, done && pos == 1200)
	pos, done = restore_step(1200, 300, true)
	testing.expect(t, done && pos == 300)
	pos, done = restore_step(0, 0, false)
	testing.expect(t, done && pos == 0)
	start := i64(1)
	testing.expect(t, !restore_expired(start, start, 0, false, 10_000, 1000))
	testing.expect(t, restore_expired(start, start, 0, false, 0, 1000))   // max_wait 0: at once
	testing.expect(t, restore_expired(start, start, start, true, 10_000, 0))   // loaded, no grace
	testing.expect(t, !restore_expired(start, start, start, true, 10_000, 5000))
}

// Each tab's tree survives a restart: entries, parents, the current one, scroll positions, states.
@(test)
session_trees_round_trip :: proc(t: ^testing.T) {
	test_app(t)
	sh: page.Session_History
	defer page.session_destroy(&sh)
	page.session_push(&sh, "https://a/1", 0)
	page.session_push(&sh, "https://a/2", 0, "st\tate", true, dedupe = false)
	page.session_go(&sh, -1)
	page.session_push(&sh, "https://a/3", 0)   // a branch from 1
	e3 := page.session_current(&sh)
	e3.persisted.saved, e3.persisted.scroll, e3.persisted.zoom = true, {0, 640}, 1.25
	e3.scroll_manual = true
	page.session_set_title(&sh, "Three")
	tab := Tab{url = "https://a/3", session = sh}
	st := session_tab_of(&tab)
	text := session_serialize_tabs([]Session_Tab{st, {url = "about:config"}}, 0, 1024, 1024)
	tabs, cur, ok := session_parse_tabs(text, 10, 1024)
	testing.expect(t, ok && cur == 0 && len(tabs) == 2)
	if len(tabs) != 2 { return }
	testing.expect_value(t, len(tabs[0].entries), 3)
	testing.expect_value(t, len(tabs[1].entries), 0)
	back: page.Session_History
	defer page.session_destroy(&back)
	page.session_load(&back, tabs[0].entries, tabs[0].current, 50, 100)
	c := page.session_current(&back)
	testing.expect(t, c != nil && c.url == "https://a/3" && c.title == "Three" && c.scroll_manual)
	testing.expect(t, c != nil && c.persisted.saved && c.persisted.scroll.y == 640 && c.persisted.zoom == 1.25)
	testing.expect_value(t, back.count, 3)
	testing.expect_value(t, page.session_length(&back), 2)   // 1 then 3: 2 is a branch
	two := page.session_find(&back, 2)
	testing.expect(t, two != nil && two.has_state && two.state == "st\tate" && two.parent != nil && two.parent.url == "https://a/1")
	// the first version's files still open
	urls, _, ok1 := session_parse("wren-session 1\ncurrent 0\ntab https://old/\n", 10, 1024)
	testing.expect(t, ok1 && len(urls) == 1 && urls[0] == "https://old/")
}

@(test)
tree_layout_rows :: proc(t: ^testing.T) {
	test_app(t)
	sh: page.Session_History
	defer page.session_destroy(&sh)
	page.session_push(&sh, "a", 0)
	page.session_push(&sh, "b", 0)
	page.session_push(&sh, "c", 0)
	page.session_go(&sh, -1)
	page.session_push(&sh, "d", 0)   // branch from b
	page.session_go(&sh, -2)
	page.session_push(&sh, "e", 0)   // branch from a
	places, rows, cols := tree_place(&sh)
	testing.expect_value(t, len(places), 5)
	testing.expect_value(t, rows, 3)
	testing.expect_value(t, cols, 3)
	at :: proc(places: []Tree_Place, u: string) -> Tree_Place {
		for p in places { if p.entry.url == u { return p } }
		return {}
	}
	testing.expect(t, at(places, "a").row == 0 && at(places, "b").row == 0 && at(places, "c").row == 0 && at(places, "c").col == 2)
	testing.expect(t, at(places, "d").row == 1 && at(places, "d").col == 2)
	testing.expect(t, at(places, "e").row == 2 && at(places, "e").col == 1)
}
