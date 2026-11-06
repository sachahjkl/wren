package e2e_scenarios

// The navigation of a tab (tab_navigation.odin, first_paint.odin): a navigation that ends with no document gives the old page back, whole; a held page goes in the page
// phase of a frame, never in its draw; each window has its wake.

import "core:fmt"
import "core:testing"
import "wb:base"
import "wb:browser"
import "wb:e2e"
import "wb:page"

@(private = "file") NAV_SIZE :: [2]int{1000, 700}
@(private = "file") OLD_PAGE :: "/site/history/other.html"
@(private = "file") NEXT_PAGE :: "/site/history/next.html"
@(private = "file") NO_ANSWER :: "/firstpaint/f/next.html?delay=60000"   // (the server's longest wait: this test goes first, and the request with it)
@(private = "file") NO_ANSWER_SHEET :: "/firstpaint/f/slow.css?delay=60000"
@(private = "file") SLOW_SHEET_PAGE :: "/site/firstpaint-slow.html"     // arrives at once, its stylesheet does not
@(private = "file") HOLD_LIMIT_SHORT :: "browser.paint_holding.timeout_ms=1"
// (the content blocker's pass after a load moves the document's mutation count: the frame would not be exact, and no frame means no hold)
@(private = "file") NO_BLOCKER :: "blocker.enabled=false"

@(private = "file")
tab :: proc(s: ^e2e.Session) -> ^browser.Tab { return browser.current_tab(s.app) }

@(private = "file")
held :: proc(s: ^e2e.Session) -> bool { return tab(s).hold.state != .None }

// The tab's page is `url`'s, on screen, and it runs: the mark a script left, a click reaches it.
@(private = "file")
expect_page_back :: proc(t: ^testing.T, s: ^e2e.Session, url: string, entries: string, loc := #caller_location) {
	testing.expect(t, tab(s).page != nil, "the tab has its page again", loc = loc)
	if tab(s).page == nil { return }
	testing.expect_value(t, e2e.location(s, loc = loc), url, loc = loc)
	testing.expect_value(t, e2e.eval(s, "String(window.mark)", loc = loc), "here", loc = loc)
	testing.expect_value(t, e2e.eval(s, "String(history.length)", loc = loc), entries, loc = loc)
	testing.expect(t, !browser.tab_loading(tab(s)), "the tab is no longer loading", loc = loc)
	e2e.click(s, "h1", loc = loc)
	e2e.wait_js(s, "window.clicks == 1", loc = loc)
}

// `url` is on screen, marked, and counts its clicks.
@(private = "file")
marked_page :: proc(s: ^e2e.Session, url: string) -> (entries: string) {
	e2e.navigate(s, url)
	e2e.eval(s, `window.mark = "here"; addEventListener("click", () => window.clicks = (window.clicks || 0) + 1); 1`)
	e2e.wait_frames(s, 2)
	return e2e.eval(s, "String(history.length)")
}

@(test)
stop_before_the_answer_gives_the_old_page_back :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER}})
	url := e2e.url(server, OLD_PAGE)
	entries := marked_page(s, url)
	e2e.navigate_begin(s, e2e.url(server, NO_ANSWER))
	e2e.wait_frames(s, 2)
	testing.expect(t, held(s), "the old frame is held")
	e2e.run_command(s, "nav.stop")
	e2e.wait_frames(s, 2)
	testing.expect(t, !held(s), "nothing is held any more")
	expect_page_back(t, s, url, entries)
}

// A back that does not arrive: the history stands where it did.
@(test)
stop_of_a_traversal_stays_on_the_entry :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER, "history.bfcache.enabled=false"}})
	e2e.navigate(s, e2e.url(server, fmt.tprintf("/firstpaint/second-hangs?key=%s", e2e.unique())))
	url := e2e.url(server, OLD_PAGE)
	entries := marked_page(s, url)
	e2e.eval(s, "history.back(); 1")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return tab(s).page == nil }, "the traversal to leave")
	e2e.run_command(s, "nav.stop")
	e2e.wait_frames(s, 2)
	expect_page_back(t, s, url, entries)
	testing.expect_value(t, tab(s).session.index, 2)   // (about:blank, the page that hangs, this one)
}

// `unload` once per document, however many navigations leave it: a download leaves it (when a navigation starts, tab_navigation.odin) and gives it back.
@(test)
a_document_unloads_once :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	dir := e2e.temp_folder(t, "downloads")
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER, "browser.download.button=never", "browser.download.ask=false", fmt.tprintf("browser.download.directory=%s", dir)}})
	url := e2e.url(server, OLD_PAGE)
	entries := marked_page(s, url)
	e2e.eval(s, `localStorage.unloads = 0; addEventListener("unload", () => localStorage.unloads = Number(localStorage.unloads) + 1); 1`)
	e2e.navigate_begin(s, e2e.url(server, "/download/attachment?bytes=16&name=a.txt"))
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(e2e.downloads(s)) >= 1 }, "the navigation to become a download")
	e2e.wait_frames(s, 2)
	expect_page_back(t, s, url, entries)
	testing.expect_value(t, e2e.eval(s, "localStorage.unloads"), "1")
	e2e.navigate(s, e2e.url(server, NEXT_PAGE))
	testing.expect_value(t, e2e.eval(s, "localStorage.unloads"), "1")
}

// A page that may not be kept runs on behind its frame while the next one loads, and the session is the next one's by then: the address it asks for must not land in that entry.
@(test)
a_page_left_writes_in_no_entry_of_the_next :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER}})
	unkept_page(s, e2e.url(server, OLD_PAGE))
	e2e.eval(s, `setInterval(() => { try { history.replaceState(null, "", "?moved") } catch (e) {} console.log("tried") }, 1); 1`)
	e2e.eval(s, `history.replaceState(null, "", "?before"); 1`)
	next := e2e.url(server, NO_ANSWER)
	e2e.navigate_begin(s, next)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		for l in e2e.console(s) { if l.text == "tried" { return true } }
		return false
	}, "the held page's timer")
	testing.expect_value(t, page.session_current(&tab(s).session).url, next)
}

// Held, cached, back: the document has its history again.
@(test)
a_page_back_from_the_cache_has_its_history :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER}})
	e2e.navigate(s, e2e.url(server, OLD_PAGE))
	e2e.wait_frames(s, 2)
	e2e.navigate(s, e2e.url(server, NEXT_PAGE))
	e2e.wait_frames(s, 2)
	e2e.go_back(s)
	testing.expect_value(t, e2e.stats(s).bfcache.restores, 1)
	testing.expect_value(t, e2e.eval(s, `history.replaceState(null, "", "?again"); location.search`), "?again")
}

// A built-in page's navigation is a navigation: what reads the time it started does not get the last one's.
@(test)
a_built_in_page_starts_its_own_clock :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER}})
	e2e.navigate(s, e2e.url(server, OLD_PAGE))
	web := tab(s).nav_state.started
	e2e.wait_frames(s, 2)
	e2e.navigate(s, "about:home")
	testing.expect(t, tab(s).nav_state.started > web, "the clock is this navigation's")
}

// Where a scope's end was seen.
@(private = "file")
Close_Seen :: struct {
	app:    ^browser.App,
	closed: bool,
	phase:  browser.Shell_Phase,
}

@(private = "file")
watch_held_page :: proc(s: ^e2e.Session, seen: ^Close_Seen) {
	seen.app = s.app
	base.on_close(tab(s).hold.nav, proc(data: rawptr) {
		c := (^Close_Seen)(data)
		c.closed, c.phase = true, c.app.chrome_frames.phase
	}, seen)
}

// (the unload listener: a page that may not be kept closes when its hold ends, in the scope watched)
@(private = "file")
unkept_page :: proc(s: ^e2e.Session, url: string) {
	e2e.navigate(s, url)
	e2e.eval(s, `addEventListener("unload", () => {}); 1`)
	e2e.wait_frames(s, 2)
}

@(private = "file")
expect_closed_in_the_page_phase :: proc(t: ^testing.T, s: ^e2e.Session, seen: ^Close_Seen, loc := #caller_location) {
	e2e.wait_until(s, seen, proc(s: ^e2e.Session, c: ^Close_Seen) -> bool { return c.closed }, "the held page to close", loc = loc)
	testing.expect_value(t, seen.phase, browser.Shell_Phase.Anim, loc = loc)
}

@(test)
a_tab_in_the_back_lets_go_of_its_held_page_in_the_page_phase :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER}})
	unkept_page(s, e2e.url(server, OLD_PAGE))
	e2e.navigate_begin(s, e2e.url(server, NO_ANSWER))
	e2e.wait_until(s, held, "the hold")
	seen: Close_Seen
	watch_held_page(s, &seen)
	e2e.new_tab(s, "about:blank")
	expect_closed_in_the_page_phase(t, s, &seen)
}

@(test)
a_hold_times_out_in_the_page_phase :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER, HOLD_LIMIT_SHORT}})
	unkept_page(s, e2e.url(server, OLD_PAGE))
	e2e.navigate_begin(s, e2e.url(server, SLOW_SHEET_PAGE))
	e2e.wait_until(s, held, "the hold")
	seen: Close_Seen
	watch_held_page(s, &seen)
	expect_closed_in_the_page_phase(t, s, &seen)
}

// (a state, not an end that comes late: every frame of a tab loading asks for the next, loading_bar, so the wake of a window the other's took was never missed)
@(test)
a_window_s_first_paint_wake_stands_beside_the_other_s :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = NAV_SIZE, prefs = {NO_BLOCKER, "style.render_blocking.timeout_ms=120000"}})
	page := e2e.file_page(e2e.temp_folder(t), "blocked.html", fmt.tprintf(`<!doctype html><link rel="stylesheet" href="%s"><p>Blocked.`, e2e.url(server, NO_ANSWER_SHEET)))
	e2e.navigate_begin(s, page)
	a := e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	b := wins[0].id != a ? wins[0].id : wins[1].id
	{
		e2e.in_window(s, b)
		e2e.navigate_begin(s, page)
	}
	ids := [2]int{a, b}
	e2e.wait_until(s, ids, proc(s: ^e2e.Session, ids: [2]int) -> bool {
		for id in ids { if browser.window_by_id(s.app, id).own.first_paint_timer == base.NIL_HANDLE { return false } }
		return true
	}, "a wake in both windows")
}

