package e2e_scenarios

// The CSS Custom Highlight API as it is painted (examples/site/highlight.html, src/browser/selection_shell.odin): the background and the color of ::highlight(name)
// over a range, what follows a change of the registry, of a highlight and of a range, and the order of priorities. A script's view of it: examples/jsdom/highlight.html.

import "core:fmt"
import "core:testing"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{800, 400}
@(private = "file") YELLOW :: [3]u8{0xff, 0xff, 0x00}
@(private = "file") GREEN :: [3]u8{0x00, 0xff, 0x00}
@(private = "file") BLUE :: [3]u8{0x00, 0x00, 0xff}
@(private = "file") CHANNEL_WITHIN :: 24
@(private = "file") PAINTED_LEAST :: 2000     // pixels of a background over a word, at least
@(private = "file") GLYPHS_LEAST :: 300       // pixels of its color in the glyphs
@(private = "file") FIRST_LINE :: e2e.Rect{0, 0, 400, 60}
@(private = "file") SECOND_LINE :: e2e.Rect{0, 60, 400, 60}

@(private = "file")
count :: proc(img: e2e.Image, r: e2e.Rect, rgb: [3]u8) -> int {
	n := 0
	for y in int(r.y) ..< int(r.y + r.h) {
		for x in int(r.x) ..< int(r.x + r.w) {
			c := e2e.pixel(img, x, y)
			if abs(int(c[0]) - int(rgb[0])) <= CHANNEL_WITHIN && abs(int(c[1]) - int(rgb[1])) <= CHANNEL_WITHIN && abs(int(c[2]) - int(rgb[2])) <= CHANNEL_WITHIN { n += 1 }
		}
	}
	return n
}

// The picture once the script has run and its frame is drawn.
@(private = "file")
after :: proc(s: ^e2e.Session, script: string) -> e2e.Image {
	e2e.eval(s, fmt.tprintf("%s; 1", script))
	e2e.wait_idle(s)
	e2e.wait_frames(s)
	return e2e.capture(s, {target = .Page})
}

@(test)
a_highlight_is_painted_and_follows_its_ranges :: proc(t: ^testing.T) {
	s := e2e.start(t, {pixels = true, size = SIZE, dpi = e2e.DPI_ONE, url = e2e.file_url(fmt.tprintf("%s/examples/site/highlight.html", e2e.repo_root()))})
	defer e2e.stop(s)
	e2e.wait_idle(s)
	e2e.wait_frames(s)
	img := e2e.capture(s, {target = .Page})
	testing.expect(t, count(img, FIRST_LINE, YELLOW) >= PAINTED_LEAST, "the background of ::highlight(word) is under the range")
	testing.expect(t, count(img, FIRST_LINE, BLUE) >= GLYPHS_LEAST, "and its color is on the glyphs")
	testing.expect(t, count(img, SECOND_LINE, YELLOW) == 0, "nothing elsewhere")

	img = after(s, "word.setStart(second, 0); word.setEnd(second, 5)")
	testing.expect(t, count(img, FIRST_LINE, YELLOW) == 0, "a range that moves leaves its old place")
	testing.expect(t, count(img, SECOND_LINE, YELLOW) >= PAINTED_LEAST, "and shows at the new one")

	img = after(s, "under.clear()")
	testing.expect(t, count(img, SECOND_LINE, YELLOW) == 0, "a highlight emptied shows nothing")

	img = after(s, "under.add(word)")
	testing.expect(t, count(img, SECOND_LINE, YELLOW) >= PAINTED_LEAST, "a range added shows")

	img = after(s, "CSS.highlights.delete('word')")
	testing.expect(t, count(img, SECOND_LINE, YELLOW) == 0, "a highlight out of the registry shows nothing")

	// the same range in two highlights: the higher priority over the other, registered first or not
	img = after(s, "low.priority = 1; high.priority = 0; CSS.highlights.set('word', low); CSS.highlights.set('over', high)")
	testing.expect(t, count(img, SECOND_LINE, YELLOW) >= PAINTED_LEAST && count(img, SECOND_LINE, GREEN) == 0, "the higher priority is painted last")
	img = after(s, "high.priority = 2")
	testing.expect(t, count(img, SECOND_LINE, GREEN) >= PAINTED_LEAST && count(img, SECOND_LINE, YELLOW) == 0, "and that follows the priority")
	testing.expect(t, count(img, SECOND_LINE, BLUE) >= GLYPHS_LEAST, "a highlight with no color leaves the text the one under it gave")

	// (a point over the word, and one under the text: Range.getClientRects gives the element boxes of the text of a range, so a point past the word on its line still counts)
	e2e.expect_eval(s, "CSS.highlights.highlightsFromPoint(10, 90).map(r => r.highlight === high ? 'high' : 'low').join()", "high,low", "highlightsFromPoint: the highest priority first")
	e2e.expect_eval(s, "CSS.highlights.highlightsFromPoint(10, 300).length", "0", "and nothing where no range is")
}
