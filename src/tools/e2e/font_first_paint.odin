package e2e_scenarios

// A web font in its block period holds its text, not the page (first_paint.odin): bbc.com painted at 1.1 s, when its fonts came, with a
// document ready at 0.3 s. The text is invisible meanwhile, so nothing contentful has been painted: first-contentful-paint comes with the font.
// document.fonts says the same to scripts: loading, then ready once the font has come.

import "core:testing"
import "wb:e2e"

@(private = "file") FONT_SIZE :: [2]int{800, 600}
@(private = "file") FONT_PAGE :: "/firstpaint/f/web-font.html"
@(private = "file") FONT_GATE :: "font"           // (web-font.html: what holds its font back, tools/testserver/gate.go)
@(private = "file") PAGE_COLOR :: [3]u8{0x11, 0x22, 0x33}   // (its body)
// The block period as long as it goes: the test, not a clock, ends the font's wait (at the 3 s of the default, a loaded machine
// painted the fallback font, and its first contentful paint, before the test looked).
@(private = "file") BLOCK_UNTIL_THE_GATE :: "style.webfonts.block_period_ms=60000"

@(test)
a_font_on_its_way_holds_its_text_and_not_the_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {pixels = true, size = FONT_SIZE, prefs = {BLOCK_UNTIL_THE_GATE}})
	e2e.navigate_begin(s, e2e.url(server, FONT_PAGE))
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		img := e2e.capture(s)
		c := (img.height / 2 * img.width + img.width / 2) * 4
		for want, i in PAGE_COLOR { if img.rgba[c + i] != want { return false } }
		return true
	}, "the page's background on screen")
	e2e.wait_js(s, "performance.getEntriesByName('first-paint').length == 1")
	testing.expect_value(t, e2e.eval(s, "performance.getEntriesByName('first-contentful-paint').length"), "0")   // (the server holds the font until the test says so)
	testing.expect_value(t, e2e.eval(s, "document.fonts.status"), "loading")
	e2e.eval(s, "document.fonts.ready.then(set => window.ready = set === document.fonts); 1")
	e2e.wait_frames(s)
	testing.expect_value(t, e2e.eval(s, "window.ready === undefined"), "true")
	e2e.open_gate(server, FONT_GATE)
	e2e.wait_js(s, "window.ready === true")
	testing.expect_value(t, e2e.eval(s, "document.fonts.status"), "loaded")
	e2e.wait_js(s, "performance.getEntriesByType('paint').length == 2")
	first := e2e.eval_f64(s, "performance.getEntriesByName('first-paint')[0].startTime")
	contentful := e2e.eval_f64(s, "performance.getEntriesByName('first-contentful-paint')[0].startTime")
	testing.expectf(t, contentful > first, "the text showed with its font: first paint at %v ms, contentful at %v ms", first, contentful)
}
