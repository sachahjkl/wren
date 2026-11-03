package e2e_scenarios

// History in the browser (history_restore.odin): examples/site/history/long.html is scrolled, its box too and its form filled, then left for
// next.html; Alt+Left, through Wren's own input, comes back and everything is where it was. With the back/forward cache, then without (the entry
// loads again and its state is restored, once the late part of the page has come). The time of each traversal is logged. And back and forward
// in a frame of examples/site/history/framed.html.

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

// The joint session history (page/history_joint.odin): a link followed in a frame is an entry of the tab, back (Alt+Left) takes the frame
// back and leaves the page where it is, forward takes it on again.
@(private = "file") FRAMED_PAGE :: "/site/history/framed.html"
@(private = "file") FRAME_FIRST :: `frames[0].location.pathname.endsWith("frame_a.html") && (window.before = history.length) > 0`
@(private = "file") FRAME_SECOND :: `frames[0].location.pathname.endsWith("frame_b.html") && history.length === before + 1`
@(private = "file") FRAME_BACK :: `frames[0].location.pathname.endsWith("frame_a.html") && history.length === before + 1`

@(test)
back_in_a_frame :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = HISTORY_SIZE, url = e2e.url(server, FRAMED_PAGE)})
	e2e.wait_load(s)
	e2e.wait_js(s, FRAME_FIRST)
	e2e.eval(s, `frames[0].document.getElementById("next").click(); 1`)
	e2e.wait_js(s, FRAME_SECOND)
	e2e.expect_eval(s, "String(history.length - before)", "1", "the link followed in the frame is an entry of the tab")

	e2e.key(s, "Alt+Left")
	e2e.wait_js(s, FRAME_BACK)
	e2e.expect_eval(s, `String(location.pathname.endsWith("framed.html"))`, "true", "back takes the frame back, the page stays")
	testing.expect(t, at_address(s, FRAMED_PAGE), "the address is still the page's")

	e2e.key(s, "Alt+Right")
	e2e.wait_js(s, FRAME_SECOND)
	e2e.expect_eval(s, `frames[0].document.title`, "frame b", "forward takes the frame on again")
}

// Without the back/forward cache: the frame's link followed, the page left for another, back loads the page again and its frame shows its
// second page (its entry at that position, not its src); the line keeps its length; back again takes the frame to its first page, the page staying.
@(private = "file") FRAME_SECOND_AGAIN :: `document.readyState === "complete" && frames.length === 1 && frames[0].location.pathname.endsWith("frame_b.html") && frames[0].document.readyState === "complete"`

@(test)
back_to_a_page_loaded_again_shows_its_frames_entries :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = HISTORY_SIZE, prefs = {"history.bfcache.enabled=false"}, url = e2e.url(server, FRAMED_PAGE)})
	e2e.wait_load(s)
	e2e.wait_js(s, FRAME_FIRST)
	start := e2e.eval(s, "String(history.length)")
	e2e.eval(s, `frames[0].document.getElementById("next").click(); 1`)
	e2e.wait_js(s, FRAME_SECOND)
	e2e.eval(s, `location.href = "next.html"; 1`)
	e2e.wait_until(s, string(NEXT_PAGE), at_address, "the next page")
	e2e.wait_load(s)

	e2e.key(s, "Alt+Left")
	e2e.wait_until(s, string(FRAMED_PAGE), at_address, "the framed page again")
	e2e.wait_js(s, FRAME_SECOND_AGAIN)
	e2e.expect_eval(s, strings.concatenate({"String(history.length - ", start, ")"}, context.temp_allocator), "2", "loaded again (no cache), the frame on its second page, the line as long (the frame's step and the next page)")

	e2e.key(s, "Alt+Left")
	e2e.wait_js(s, `frames[0].location.pathname.endsWith("frame_a.html")`)
	e2e.expect_eval(s, `String(location.pathname.endsWith("framed.html"))`, "true", "back again takes the frame to its first page, the page stays")
}

@(test)
back_from_the_back_forward_cache :: proc(t: ^testing.T) {
	back_restores(t, nil, "true", "back from the back/forward cache (pageshow persisted)")
}

@(test)
back_loads_the_page_again :: proc(t: ^testing.T) {
	back_restores(t, {"history.bfcache.enabled=false"}, "false", "back loads the page again")
}
