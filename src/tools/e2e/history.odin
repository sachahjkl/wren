package e2e_scenarios

// History in the browser (history_restore.odin): examples/site/history/long.html is scrolled, its box too and its form filled, then left for
// next.html; Alt+Left, through Wren's own input, comes back and everything is where it was. With the back/forward cache, then without (the entry
// loads again and its state is restored, once the late part of the page has come). The time of each traversal is logged.

import "core:log"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") HISTORY_SIZE :: [2]int{1280, 800}
@(private = "file") LONG_PAGE :: "/site/history/long.html"
@(private = "file") NEXT_PAGE :: "next.html"
// The page's first part and its late one, in rows (long.html): the document is tall enough for its position only with the second.
@(private = "file") ALL_ROWS :: `document.querySelectorAll("#rows .row").length >= 170`
@(private = "file") SCROLL_AND_FILL :: `who.value = "typed"; agree.checked = true; box.scrollTop = 300; scrollTo(0, 2500); window.lastShow = undefined; 1`
@(private = "file") SCROLLED :: `Math.round(scrollY) === 2500 && box.scrollTop === 300`
@(private = "file") TIMED_LINE :: "history: entry shown in"
// How many frames take a scroll set by a script to what the tab keeps of it.
@(private = "file") SCROLL_KEPT_FRAMES :: 2

@(private = "file")
at_address :: proc(s: ^e2e.Session, part: string) -> bool { return strings.contains(e2e.location(s), part) }

@(private = "file")
timed_line :: proc(s: ^e2e.Session) -> string {
	for l in e2e.console(s) { if strings.contains(l.text, TIMED_LINE) { return l.text } }
	return ""
}

@(private = "file")
back_restores :: proc(t: ^testing.T, prefs: []string, persisted: string, how: string) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = HISTORY_SIZE, prefs = prefs, url = e2e.url(server, LONG_PAGE)})
	e2e.wait_js(s, ALL_ROWS)
	e2e.eval(s, SCROLL_AND_FILL)
	e2e.wait_js(s, SCROLLED)
	e2e.wait_frames(s, SCROLL_KEPT_FRAMES)
	e2e.eval(s, `location.href = "next.html"; 1`)
	e2e.wait_until(s, string(NEXT_PAGE), at_address, "the next page")
	e2e.wait_load(s)
	e2e.expect_eval(s, "document.title", "next", "the page scrolled, filled its form and went on to the next page")

	e2e.key(s, "Alt+Left")
	e2e.wait_until(s, string(LONG_PAGE), at_address, "the long page again")
	e2e.wait_load(s)
	e2e.wait_js(s, "window.lastShow !== undefined")
	e2e.wait_js(s, ALL_ROWS)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return !e2e.stats(s).history_restoring }, "what the entry showed to be back")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return timed_line(s) != "" }, "the traversal's time")
	log.info(timed_line(s))

	e2e.expect_eval(s, "String(window.lastShow)", persisted, how)
	e2e.expect_eval(s, "String(Math.round(scrollY))", "2500", "the document is where it was left (2500 px), after its late content")
	e2e.expect_eval(s, "String(box.scrollTop)", "300", "the scroll container too (300 px)")
	e2e.expect_eval(s, `who.value + " " + agree.checked`, "typed true", "the form came back filled")
}

@(test)
back_from_the_back_forward_cache :: proc(t: ^testing.T) {
	back_restores(t, nil, "true", "back from the back/forward cache (pageshow persisted)")
}

@(test)
back_loads_the_page_again :: proc(t: ^testing.T) {
	back_restores(t, {"history.bfcache.enabled=false"}, "false", "back loads the page again")
}
