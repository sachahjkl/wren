package e2e_scenarios

// CSS Scroll Anchoring in the browser (wb:layout scroll_anchor.odin, the shell's page_layout): a tall page scrolled down, then a block
// inserted above what shows: the next frame keeps the view on the same content; at the top of the page nothing moves; with
// overflow-anchor: none on the root, the content moves instead.

import "core:testing"
import "wb:e2e"

@(private = "file") ANCHORING_PAGE :: "/site/autoscroll.html"
@(private = "file") ANCHORING_SIZE :: [2]int{900, 700}
// A block of 300 px put above the view, without a script reading the layout: the frame that follows lays the page out.
@(private = "file") INSERT_ABOVE :: `{ const d = document.createElement("div"); d.style.height = "300px"; document.body.prepend(d); } 1`
@(private = "file") LAID_OUT_FRAMES :: 2

@(test)
scroll_anchoring_keeps_the_view :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = ANCHORING_SIZE, url = e2e.url(server, ANCHORING_PAGE)})
	e2e.wait_load(s)
	e2e.eval(s, INSERT_ABOVE)
	e2e.wait_frames(s, LAID_OUT_FRAMES)
	e2e.expect_eval(s, "String(scrollY)", "0", "at the top of the page a block inserted above does not scroll it")

	e2e.eval(s, "scrollTo(0, 600); 1")
	e2e.wait_frames(s, LAID_OUT_FRAMES)
	e2e.eval(s, INSERT_ABOVE)
	e2e.wait_frames(s, LAID_OUT_FRAMES)
	e2e.expect_eval(s, "String(scrollY)", "900", "scrolled down, a block of 300 px inserted above the view scrolls the page by as much: what showed stays")

	e2e.eval(s, `document.documentElement.style.overflowAnchor = "none"; 1`)
	e2e.eval(s, INSERT_ABOVE)
	e2e.wait_frames(s, LAID_OUT_FRAMES)
	e2e.expect_eval(s, "String(scrollY)", "900", "with overflow-anchor: none on the root the page keeps its offset")
}
