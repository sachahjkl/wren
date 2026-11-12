package browser

import "core:strings"
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

@(test)
history_addresses_recorded :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, history_address("https://user:pw@a.example/x?q#f", true, 1024), "https://a.example/x?q#f")
	testing.expect_value(t, history_address("http://a.example/", true, 1024), "http://a.example/")
	testing.expect_value(t, history_address("file:///C:/x.html", true, 1024), "file:///C:/x.html")
	testing.expect_value(t, history_address("file:///C:/x.html", false, 1024), "")
	for a in ([]string{"about:config", "about:history", "data:text/html,x", "javascript:alert(1)", "view-source:https://a/", "blob:https://a/1", "not a url", ""}) {
		testing.expect_value(t, history_address(a, true, 1024), "")
	}
	testing.expect_value(t, history_address(strings.concatenate({"https://a/", strings.repeat("x", 100, context.temp_allocator)}, context.temp_allocator), true, 50), "")
}

@(test)
history_file_round_trip :: proc(t: ^testing.T) {
	test_app(t)
	visits := [dynamic]Visit{}
	defer visits_destroy(&visits)
	append(&visits, Visit{id = 1, at_ms = 1000, url = strings.clone("https://a/"), title = strings.clone("A\ttab\nline \\ end")})
	append(&visits, Visit{id = 2, at_ms = 2000, url = strings.clone("https://b/"), title = strings.clone("")})
	append(&visits, Visit{id = 5, at_ms = 3000, url = strings.clone("https://c/"), title = strings.clone("C")})
	text := history_serialize(visits[:])
	got, next, lines, ok := history_parse(text, 100, 0, 1024)
	defer visits_destroy(&got)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, next, 5)
	testing.expect_value(t, lines, 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0].title, "A\ttab\nline \\ end")
		testing.expect_value(t, got[2].url, "https://c/")
	}
	// retention and size
	old, _, _, _ := history_parse(text, 100, 1500, 1024)
	testing.expect_value(t, len(old), 2)
	visits_destroy(&old)
	few, _, _, _ := history_parse(text, 1, 0, 1024)
	testing.expect(t, len(few) == 1 && few[0].id == 5)
	visits_destroy(&few)
	// damaged files, and another version's
	bad, _, _, bok := history_parse("garbage\nv\t1\t1\thttps://a/\tA\n", 100, 0, 1024)
	testing.expect(t, !bok)
	visits_destroy(&bad)
	v1, _, _, v1ok := history_parse("wren-history 1\nv\t1\t1\thttps://a/\tA\n", 100, 0, 1024)
	testing.expect(t, !v1ok)
	visits_destroy(&v1)
	part, _, _, pok := history_parse("wren-history 2\nv\tx\t1\thttps://a/\tA\nv\t3\t5\tnot a url\tB\nv\t4\t6\thttps://ok/\n\nzzz\n", 100, 0, 1024)
	testing.expect(t, pok && len(part) == 1 && part[0].url == "https://ok/" && part[0].title == "")
	visits_destroy(&part)
}

// The file is a log: visits and title lines appended to a compacted file read back as the history they describe.
@(test)
history_log_lines :: proc(t: ^testing.T) {
	test_app(t)
	visits := [dynamic]Visit{}
	defer visits_destroy(&visits)
	append(&visits, Visit{id = 1, at_ms = 1000, url = strings.clone("https://a/"), title = strings.clone("A")})
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, history_serialize(visits[:]))
	history_write_visit(&sb, Visit{id = 2, at_ms = 2000, url = "https://b/", title = ""})
	history_write_title(&sb, 2, "B\tnew", "https://b/icon.png")
	history_write_title(&sb, 9, "unknown", "")   // (a visit the limits removed: skipped)
	history_write_visit(&sb, Visit{id = 3, at_ms = 1500, url = "https://c/", title = "C"})   // (a clock set back)
	history_write_visit(&sb, Visit{id = 2, at_ms = 9000, url = "https://dup/", title = ""})  // (an id given twice: the first stays)
	got, next, lines, ok := history_parse(strings.to_string(sb), 100, 0, 1024)
	defer visits_destroy(&got)
	testing.expect(t, ok)
	testing.expect_value(t, lines, 6)
	testing.expect_value(t, next, 3)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect(t, got[0].id == 1 && got[1].id == 3 && got[2].id == 2)   // time order
		testing.expect_value(t, got[2].title, "B\tnew")
		testing.expect_value(t, got[2].icon, "https://b/icon.png")
		testing.expect_value(t, got[2].url, "https://b/")
	}
}

// When the whole file is written again, and how far the limits cut at once.
@(test)
history_compaction_and_trim_rules :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect(t, !history_needs_compaction(0, 0))
	testing.expect(t, !history_needs_compaction(HISTORY_COMPACT_SLACK, 0))
	testing.expect(t, history_needs_compaction(HISTORY_COMPACT_SLACK + 1, 0))
	testing.expect(t, !history_needs_compaction(2000 * HISTORY_COMPACT_RATIO + HISTORY_COMPACT_SLACK, 2000))
	testing.expect(t, history_needs_compaction(2000 * HISTORY_COMPACT_RATIO + HISTORY_COMPACT_SLACK + 1, 2000))
	// under both limits: nothing
	_, trim := history_trim_target(1000, 5_000_000, 1000, 0)
	testing.expect(t, !trim)
	// one past the count: a slice goes at once, so the next visits cost no move
	keep, trim2 := history_trim_target(1001, 5_000_000, 1000, 0)
	testing.expect(t, trim2 && keep == 1000 - 1000 / HISTORY_TRIM_SLACK_DIV)
	keep, trim2 = history_trim_target(11, 0, 10, 0)
	testing.expect(t, trim2 && keep == 9)   // (at least one)
	// past the retention: only once the oldest is an hour past it
	_, trim = history_trim_target(5, 10_000_000 - HISTORY_TRIM_AGE_SLACK_MS + 1, 1000, 10_000_000)
	testing.expect(t, !trim)
	keep, trim2 = history_trim_target(5, 10_000_000 - HISTORY_TRIM_AGE_SLACK_MS - 1, 1000, 10_000_000)
	testing.expect(t, trim2 && keep == 1000)
}

// A search makes each visit's lower-case text once; a new title makes it again.
@(test)
history_search_keeps_lower_case :: proc(t: ^testing.T) {
	test_app(t)
	visits := [dynamic]Visit{}
	defer visits_destroy(&visits)
	append(&visits, Visit{id = 1, at_ms = 1, url = strings.clone("https://Example.org/"), title = strings.clone("Ünïcode Title")})
	testing.expect_value(t, visits[0].low, "")
	testing.expect_value(t, len(history_search(visits[:], "example")), 1)
	testing.expect(t, visits[0].low != "")
	testing.expect_value(t, len(history_search(visits[:], "ÜNÏCODE")), 1)
	testing.expect_value(t, len(history_search(visits[:], "missing")), 0)
}

@(test)
history_search_and_delete :: proc(t: ^testing.T) {
	test_app(t)
	visits := [dynamic]Visit{}
	defer visits_destroy(&visits)
	for i in 0 ..< 6 {
		append(&visits, Visit{id = u64(i + 1), at_ms = i64(i) * 1000, url = strings.clone(i % 2 == 0 ? "https://even.example/" : "https://odd.example/"), title = strings.clone(i == 3 ? "Special Title" : "")})
	}
	all := history_search(visits[:], "")
	testing.expect(t, len(all) == 6 && all[0] == 5)   // newest first
	testing.expect_value(t, len(history_search(visits[:], "EVEN")), 3)
	s := history_search(visits[:], "special")
	testing.expect(t, len(s) == 1 && s[0] == 3)
	ids := []u64{1, 2}
	testing.expect_value(t, history_delete(&visits, ids), 2)
	testing.expect_value(t, history_delete(&visits, nil, 3000, 5000), 2)   // [3000, 5000): ids 4 and 5
	testing.expect_value(t, len(visits), 2)
	testing.expect(t, visits[0].id == 3 && visits[1].id == 6)
	testing.expect(t, history_trim(&visits, 1, 0) && len(visits) == 1 && visits[0].id == 6)
	testing.expect(t, history_trim(&visits, 10, 10_000) && len(visits) == 0)   // older than the retention
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
