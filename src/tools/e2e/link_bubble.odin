package e2e_scenarios

// Where a link goes is shown over the page, in a small box at its bottom left corner, not in the status bar (status_bar.odin
// link_bubble): the page under it keeps its hover, and the box moves to the other corner when the pointer is where it would be.

import "core:testing"
import "toolkit:draw"
import "wb:e2e"

@(private = "file") LINK_HREF :: "https://example.org/a/long/path"
@(private = "file") LINK_PAGE :: `<!doctype html><style>body{margin:0} a{display:block;width:200px;height:40px} #low{position:absolute;left:0;bottom:0;width:100%;height:60px}</style><a id=up href="` + LINK_HREF + `">up</a><a id=low href="` + LINK_HREF + `">low</a>`
@(private = "file") ON_LINK :: e2e.Point{50, 20}
@(private = "file") OFF_LINKS :: e2e.Point{400, 200}
@(private = "file") PAGE_WHITE :: e2e.Color{255, 255, 255, 255}

// The box of the bubble this frame: the box whose text is the link's address, built by the last build.
@(private = "file")
bubble :: proc(s: ^e2e.Session) -> (r: draw.Rect, ok: bool) {
	context = s.ctx
	w := s.app.active
	for _, b in w.ui.boxes {
		if b.last_build + 1 >= w.ui.build_index && b.text == LINK_HREF { return b.rect, true }
	}
	return
}

@(test)
where_a_link_goes_is_shown_over_the_page :: proc(t: ^testing.T) {
	s := e2e.start(t, {pixels = true, url = "about:blank"})
	e2e.eval(s, "document.open(); document.write(" + "`" + LINK_PAGE + "`" + "); document.close(); 1")
	e2e.wait_frames(s)
	_, shown := bubble(s)
	testing.expect(t, !shown, "no link under the pointer: no box")

	e2e.hover(s, ON_LINK)
	e2e.wait_frames(s)
	r, ok := bubble(s)
	testing.expect(t, ok, "the box of the link under the pointer")
	area := s.app.active.page_rect
	testing.expectf(t, ok && r.min.x == area.min.x && r.max.y == area.max.y, "at the page's bottom left corner: %v in %v", r, area)
	// drawn: its own background beside the text, and in the corner it sits in, no page showing through (that corner is square)
	img := e2e.capture(s)
	mid := int((r.min.y + r.max.y) * 0.5)
	testing.expectf(t, e2e.pixel(img, int(r.min.x) + 2, mid) != PAGE_WHITE, "its background: %v", e2e.pixel(img, int(r.min.x) + 2, mid))
	testing.expectf(t, e2e.pixel(img, int(r.min.x), int(r.max.y) - 1) != PAGE_WHITE, "its corner on the page's is square: %v", e2e.pixel(img, int(r.min.x), int(r.max.y) - 1))
	testing.expect_value(t, e2e.eval(s, "document.querySelector('a:hover') ? document.querySelector('a:hover').id : ''"), "up")

	// the pointer over that corner: the box goes to the other one, and the link there keeps its hover
	e2e.hover(s, {10, f64(area.max.y - area.min.y) - 10})
	e2e.wait_frames(s)
	r, ok = bubble(s)
	testing.expectf(t, ok && r.max.x == area.max.x && r.max.y == area.max.y, "at the bottom right corner: %v in %v", r, area)
	testing.expect_value(t, e2e.eval(s, "document.querySelector('a:hover') ? document.querySelector('a:hover').id : ''"), "low")

	e2e.hover(s, OFF_LINKS)
	e2e.wait_frames(s)
	_, shown = bubble(s)
	testing.expect(t, !shown, "off the links: gone")
}
