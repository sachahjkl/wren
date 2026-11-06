package e2e_scenarios

// A page held on screen through a navigation goes on running (first_paint.odin): its scripts make style passes that no layout
// follows, and the frames painted meanwhile read the display list of an earlier pass. With freed memory poisoned (the tests'
// build), a record of a pass that went ends the process here: what the crash in background_has_url was (imdb.com, while a
// link loaded; an access violation "reading 0xFFFFFFFFFFFFFFFF").

import "core:fmt"
import "core:testing"
import "wb:e2e"

@(private = "file") HELD_SIZE :: [2]int{1000, 700}
@(private = "file") HELD_PAGE :: "/site/firstpaint/held-styles.html"
@(private = "file") NEXT_PAGE_GATE :: "next"   // (the server answers once the test opens these: gate.go)
@(private = "file") SHEET_GATE :: "sheet"
@(private = "file") HELD_FRAMES :: 30
@(private = "file") PASSES_LEAST :: 3   // the held page's script ran this many turns meanwhile, at least

@(test)
a_held_frame_stands_through_the_style_passes_of_its_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	prefs := []string{"blocker.enabled=false"}   // (its pass after a load moves the document's mutation count: the frame is no longer exact)
	s := e2e.start(t, {size = HELD_SIZE, prefs = prefs})
	e2e.navigate(s, e2e.url(server, HELD_PAGE))
	e2e.eval(s, fmt.tprintf("slowSheet('/firstpaint/f/slow.css?gate=%s'); 1", SHEET_GATE))
	e2e.wait_frames(s, 4)
	before := e2e.eval_f64(s, "window.passes")
	e2e.navigate_begin(s, e2e.url(server, fmt.tprintf("/firstpaint/f/next.html?gate=%s", NEXT_PAGE_GATE)))
	e2e.wait_frames(s, HELD_FRAMES / 2)
	e2e.open_gate(server, SHEET_GATE)   // (the sheet comes while the page is held: over the loopback in far less than these frames)
	e2e.wait_frames(s, HELD_FRAMES)
	e2e.open_gate(server, NEXT_PAGE_GATE)
	e2e.wait_load(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), "The next page")
	testing.expectf(t, before >= PASSES_LEAST, "the page's script ran: %v turns", before)
}
