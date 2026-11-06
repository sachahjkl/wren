package e2e_scenarios

// A web font in its block period holds its text, not the page (first_paint.odin): bbc.com painted at 1.1 s, when its fonts came, with a
// document ready at 0.3 s. The text is invisible meanwhile, so nothing contentful has been painted: first-contentful-paint comes with the font.

import "core:testing"
import "wb:e2e"

@(private = "file") FONT_SIZE :: [2]int{800, 600}
@(private = "file") FONT_PAGE :: "/firstpaint/f/web-font.html"
@(private = "file") FONT_MS :: 1500                  // (web-font.html: what the server holds its font back)
@(private = "file") PAGE_COLOR :: [3]u8{0x11, 0x22, 0x33}   // (its body)

@(test)
a_font_on_its_way_holds_its_text_and_not_the_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = FONT_SIZE})
	e2e.navigate_begin(s, e2e.url(server, FONT_PAGE))
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		img := e2e.capture(s)
		c := (img.height / 2 * img.width + img.width / 2) * 4
		for want, i in PAGE_COLOR { if img.rgba[c + i] != want { return false } }
		return true
	}, "the page's background on screen")
	e2e.wait_js(s, "performance.getEntriesByType('paint').length == 2")
	first := e2e.eval_f64(s, "performance.getEntriesByName('first-paint')[0].startTime")
	contentful := e2e.eval_f64(s, "performance.getEntriesByName('first-contentful-paint')[0].startTime")
	testing.expectf(t, contentful - first > FONT_MS / 2, "the text showed with its font: first paint at %v ms, contentful at %v ms", first, contentful)
}
