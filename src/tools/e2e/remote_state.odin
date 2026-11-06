package e2e_scenarios

// `reset` and the checkpoints of the channel: what they say they put back is back. A state is made in every place a reset reaches (two tabs, a zoomed page, cookies, local and session
// storage, a changed preference and a scale, a resized window, developer tools, a console line, a visit in the history, a wait nobody is going to end), then reset; everything must be as it
// was at the start, a page must see no cookie or storage, and what `keep` names must be left alone. Also run on the check build: remote_check.odin.

import "core:strings"
import "core:testing"
import "core:time"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") FIXTURE :: "/site/remote/fixture.htm"
@(private = "file") LAYOUT_PAGE :: "/site/remote/layout-sized.htm"
@(private = "file") LINE_PX :: "browser.scroll.key_line_px"
@(private = "file") SCALE :: "browser.ui.scale"
@(private = "file") SMALL_WINDOW := [2]int{640, 480}
@(private = "file") WAIT_NEVER_ANSWERED :: `{"id":7,"method":"Wren.wait","params":{"for":"selector","selector":"#never","timeout":20000}}`
@(private = "file") SAME_SCALE_WITHIN :: 0.001

// A failure this test asks for: the call's error, and why.
@(private = "file")
refused :: proc(s: ^api.Session, call: proc(s: ^api.Session) -> api.Error) -> (api.Error, string) {
	on_failure := s.on_failure
	s.on_failure = nil
	defer s.on_failure = on_failure
	e := call(s)
	return e, api.last_failure().message
}

@(private = "file")
dirty :: proc(s: ^api.Session, url, second: string) {
	api.navigate(s, url)
	api.eval(s, `document.cookie = "reset_cookie=1; path=/"; localStorage.setItem("reset_key", "kept?"); sessionStorage.setItem("reset_session", "kept?"); console.log("a line for the console"); "set"`)
	api.new_tab(s, second, wait = .Load)
	api.run_command(s, "page.zoom_in")
	api.pref_set(s, LINE_PX, "77")
	api.pref_set(s, SCALE, "1.25")
	api.set_window(s, {size = SMALL_WINDOW})
	api.open_devtools(s, "console")
}

// `p` a Wren at rest: the test of reset, on whichever program runs it.
reset_puts_back_all_it_names :: proc(t: ^testing.T, p: ^e2e.Wren_Process, server: ^e2e.Server) {
	s := p.s
	url, second := e2e.url(server, FIXTURE), e2e.url(server, LAYOUT_PAGE)
	w0, _ := api.window_bounds(s)
	line_px, _ := api.pref_get(s, LINE_PX)
	scale, _ := api.pref_get(s, SCALE)

	dirty(s, url, second)
	d, _ := api.stats(s)
	testing.expectf(t, d.tabs == 2 && d.cookies >= 1 && d.storage_sites >= 1 && d.history_visits >= 1 && d.devtools, "the state to put back is there: %d tabs, %d cookies, %d sites, %d visits, devtools %v", d.tabs, d.cookies, d.storage_sites, d.history_visits, d.devtools)

	// a client waiting for something that will not come: the reset ends its wait with an error
	waiter: api.Conn
	testing.expect(t, api.connect(&waiter, p.wren.name, e2e.PROCESS_WAIT_MS))
	defer api.disconnect(&waiter)
	testing.expect_value(t, api.write_line(&waiter, WAIT_NEVER_ANSWERED, api.CALL_WAIT_MS), api.Error.None)
	api.wait_until(s, proc(s: ^api.Session) -> bool { st, _ := api.stats(s); return st.pending_ops >= 1 }, "the wait to be registered")

	r, _ := api.reset(s)
	testing.expectf(t, r.closed_tabs == 2 && r.cookies >= 1 && r.sites >= 1 && r.prefs_restored >= 2 && r.window_restored, "it says what it removed: %v", r)
	line, e := api.read_line(&waiter, time.tick_add(time.tick_now(), api.CALL_WAIT_MS * time.Millisecond))
	testing.expectf(t, e == .None && strings.contains(line, `"id":7`) && strings.contains(line, "cancelled by a reset"), "a command another client was waiting on ends with an error: %v, %q", e, line)

	st, _ := api.stats(s)
	targets, _ := api.targets(s)
	testing.expectf(t, len(targets.tabs) == 1 && targets.tabs[0].url == "about:blank", "one blank tab: %v", targets.tabs)
	testing.expectf(t, st.cookies == 0 && st.storage_sites == 0 && st.cache_entries == 0 && st.history_visits == 0 && st.closed_tabs == 0, "nothing left in the numbers: %d %d %d %d %d", st.cookies, st.storage_sites, st.cache_entries, st.history_visits, st.closed_tabs)
	testing.expect(t, !st.devtools, "developer tools closed")
	got, _ := api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, line_px)
	got, _ = api.pref_get(s, SCALE)
	testing.expect_value(t, got, scale)
	w1, _ := api.window_bounds(s)
	testing.expectf(t, w1.width == w0.width && w1.height == w0.height, "the window is the size it had: %dx%d", w1.width, w1.height)
	testing.expectf(t, abs(w1.page_scale - w1.ui_scale) < SAME_SCALE_WITHIN && abs(w1.ui_scale - w0.ui_scale) < SAME_SCALE_WITHIN, "the page zoom is back: page %v, interface %v, was %v", w1.page_scale, w1.ui_scale, w0.ui_scale)
	lines, _ := api.console(s)
	testing.expect_value(t, len(lines), 0)
	net, _ := api.network(s)
	for q in net.requests { testing.expectf(t, !strings.contains(q.url, "fixture") && !strings.contains(q.url, "layout-sized"), "the network log holds nothing of the page before: %s", q.url) }
	// what a page sees: the same origin as before holds nothing
	api.navigate(s, url)
	seen, _ := api.eval(s, `JSON.stringify([document.cookie, localStorage.getItem("reset_key"), sessionStorage.getItem("reset_session")])`)
	testing.expect_value(t, seen, `["",null,null]`)

	// `keep` leaves the named parts alone
	dirty(s, url, second)
	r, _ = api.reset(s, keep = "prefs,window")
	w2, _ := api.window_bounds(s)
	got, _ = api.pref_get(s, LINE_PX)
	testing.expectf(t, got == "77" && w2.width == SMALL_WINDOW.x && r.closed_tabs == 2 && r.cookies >= 1, "keep prefs,window: they stay, tabs and data go: %s, %d, %v", got, w2.width, r)
	e2, why := refused(s, proc(s: ^api.Session) -> api.Error { _, e := api.reset(s, keep = "nonsense"); return e })
	testing.expectf(t, e2 != .None && strings.contains(why, "keep"), "keep nonsense is refused: %v, %q", e2, why)
	api.pref_reset_all(s)
	got, _ = api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, line_px)
	api.pref_set(s, LINE_PX, "61")
	api.pref_reset(s, LINE_PX)
	got, _ = api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, line_px)
	api.reset(s)
}

// Save, change everything, restore.
checkpoints_restore_what_they_saved :: proc(t: ^testing.T, p: ^e2e.Wren_Process, server: ^e2e.Server) {
	s := p.s
	url := e2e.url(server, FIXTURE)
	api.navigate(s, url)
	api.eval(s, `document.cookie = "cp_session=A; path=/"; document.cookie = "cp_long=B; path=/; max-age=3600"; localStorage.setItem("cp_key", "one"); "set"`)
	api.new_tab(s, e2e.url(server, LAYOUT_PAGE), wait = .Load)
	api.pref_set(s, LINE_PX, "51")
	api.run_command(s, "page.zoom_in")
	saved, _ := api.checkpoint_save(s, "one")
	testing.expectf(t, saved.tabs == 2 && saved.cookies == 2 && saved.storage_origins == 1, "it says what it holds: %v", saved)
	list, _ := api.checkpoint_list(s)
	listed := false
	for c in list { if c.name == "one" { listed = true } }
	testing.expect(t, listed, "it is listed")

	api.reset(s)
	api.navigate(s, url)
	api.eval(s, `document.cookie = "cp_session=changed; path=/"; document.cookie = "cp_other=C; path=/"; localStorage.setItem("cp_key", "two"); localStorage.setItem("cp_new", "n"); "set"`)
	api.pref_set(s, LINE_PX, "90")

	api.checkpoint_restore(s, "one")
	targets, _ := api.targets(s)
	testing.expect_value(t, len(targets.tabs), 2)
	if len(targets.tabs) == 2 {
		testing.expectf(t, strings.contains(targets.tabs[0].url, "fixture.htm") && strings.contains(targets.tabs[1].url, "layout-sized.htm") && targets.tabs[1].active, "the tabs have their addresses, the current one is the second: %v", targets.tabs)
	}
	got, _ := api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, "51")
	s.tab = targets.tabs[0].id
	seen, _ := api.eval(s, `[document.cookie, localStorage.getItem("cp_key"), localStorage.getItem("cp_new")].join("|")`)
	s.tab = 0
	testing.expectf(t, strings.contains(seen, "cp_session=A") && strings.contains(seen, "cp_long=B") && !strings.contains(seen, "cp_other") && !strings.contains(seen, "changed") && strings.has_suffix(seen, "|one|"), "the cookies (the session one too) and the localStorage are the saved ones: %q", seen)
	d, _ := api.window_bounds(s)
	testing.expectf(t, d.page_scale > d.ui_scale, "the zoom of the tab: page %v, interface %v", d.page_scale, d.ui_scale)

	api.checkpoint_delete(s, "one")
	e, why := refused(s, proc(s: ^api.Session) -> api.Error { _, e := api.checkpoint_restore(s, "one"); return e })
	testing.expectf(t, e != .None && strings.contains(why, "no checkpoint"), "deleted, it is gone: %v, %q", e, why)
	e, why = refused(s, proc(s: ^api.Session) -> api.Error { _, e := api.checkpoint_save(s, "bad name"); return e })
	testing.expectf(t, e != .None, "names are plain: %v, %q", e, why)
	api.reset(s)
}

@(test)
reset_of_a_driven_wren :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	p := e2e.launch(t)
	reset_puts_back_all_it_names(t, p, server)
	testing.expect_value(t, e2e.quit(p), 0)
}

@(test)
checkpoints_of_a_driven_wren :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	p := e2e.launch(t)
	checkpoints_restore_what_they_saved(t, p, server)
	testing.expect_value(t, e2e.quit(p), 0)
}
