package e2e_scenarios

// The page's classic scroll bars (layout scrollbars.odin, smooth_scroll.odin): the bar takes its width from the page
// (clientWidth is innerWidth less it), a full-width dark footer ends where the bar begins, in the pixels too; its arrow
// buttons scroll a line, held they repeat; overlay bars (layout.scrollbar.overlay) take no room.

import "core:fmt"
import "core:strconv"
import "core:testing"
import "wb:e2e"

@(private = "file") PAGE :: `<!doctype html><style>body{margin:0} #tall{height:3000px} footer{height:40px;background:#000}</style><div id=tall></div><footer></footer>`
@(private = "file") SIZE :: [2]int{800, 600}
@(private = "file") WIDTH_PREF :: "layout.scrollbar.classic.width_px"
@(private = "file") LINE_PREF :: "browser.scroll.key_line_px"
@(private = "file") OVERLAY_PREF :: "layout.scrollbar.overlay"
// A row inside the footer once the page is at its end, above the bar's arrow button; how dark the footer is and how
// light the bar (any of its parts) at most and at least.
@(private = "file") FOOTER_ROW_UP :: 30
@(private = "file") DARK_MAX :: 40
@(private = "file") LIGHT_MIN :: 150
// Lines a held arrow scrolls at least.
@(private = "file") HELD_LINES :: 4
// The page's offset once two frames in a row leave it where it is.
@(private = "file") STILL :: "new Promise((ok) => { let y = -1; const f = () => { if (scrollY === y) ok(y); else { y = scrollY; requestAnimationFrame(f) } }; requestAnimationFrame(f) })"
// A page with a box of its own that scrolls: its bar answers like the document's.
@(private = "file") BOX_PAGE :: `<!doctype html><style>body{margin:0} #tall{height:3000px} #box{position:fixed;left:0;top:0;width:200px;height:200px;overflow:scroll} #in{height:2000px}</style><div id=box><div id=in></div></div><div id=tall></div>`
// How far down a bar a point of its thumb is, in widths of the bar; where the pointer goes to be on no bar; the box's side.
@(private = "file") THUMB_AT :: 1.5
@(private = "file") AWAY :: e2e.Point{400, 300}
@(private = "file") BOX_SIDE :: 200

@(private = "file")
pref_f64 :: proc(s: ^e2e.Session, name: string) -> f64 {
	v, _ := strconv.parse_f64(e2e.pref_get(s, name))
	return v
}

@(test)
classic_page_bar_takes_room_and_its_arrows_scroll :: proc(t: ^testing.T) {
	s := e2e.start(t, {pixels = true, size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	e2e.eval(s, fmt.tprintf("document.open(); document.write(%q); document.close(); 1", PAGE))
	bar := pref_f64(s, WIDTH_PREF)
	inner := e2e.eval_f64(s, "innerWidth")
	client := e2e.eval_f64(s, "document.documentElement.clientWidth")
	testing.expectf(t, inner - client == bar, "clientWidth is innerWidth less the bar: %v, %v", inner, client)
	height := e2e.eval_f64(s, "innerHeight")

	// at the end of the page: the footer's last column is dark, the bar's first one is not
	e2e.eval(s, "scrollTo(0, 1e6); 1")
	e2e.wait_js(s, "scrollY > 0")
	img := e2e.capture(s, {target = .Page})
	y := int(height) - FOOTER_ROW_UP
	footer, track := e2e.pixel(img, int(client) - 1, y), e2e.pixel(img, int(client + bar / 2), y)
	testing.expectf(t, footer[0] <= DARK_MAX && footer[1] <= DARK_MAX && footer[2] <= DARK_MAX, "the footer ends at the bar: %v", footer)
	testing.expectf(t, track[0] >= LIGHT_MIN && track[1] >= LIGHT_MIN && track[2] >= LIGHT_MIN, "the bar is past the footer: %v", track)

	// the down arrow, at the bottom of the bar: a line; held, more
	e2e.eval(s, "scrollTo(0, 0); 1")
	line := pref_f64(s, LINE_PREF)
	down := e2e.Point{inner - bar / 2, height - bar / 2}
	e2e.click_at(s, down)
	e2e.wait_js(s, fmt.tprintf("scrollY == %v", line))
	e2e.press(s, down)
	e2e.wait_js(s, fmt.tprintf("scrollY >= %v", line * HELD_LINES))
	e2e.release(s, down)
	// the up arrow, at its top, back a line from where the held one stopped
	held, _ := strconv.parse_f64(e2e.eval(s, STILL, await = true))
	e2e.click_at(s, {inner - bar / 2, bar / 2})
	e2e.wait_js(s, fmt.tprintf("scrollY == %v", held - line))

	// overlay bars take no room
	e2e.pref_set(s, OVERLAY_PREF, "true")
	e2e.wait_js(s, "document.documentElement.clientWidth == innerWidth")
}

@(private = "file")
shown :: proc(s: ^e2e.Session, at: e2e.Point) -> [4]u8 {
	e2e.wait_frames(s)
	return e2e.pixel(e2e.capture(s, {target = .Page}), int(at.x), int(at.y))
}

@(private = "file")
answers_the_pointer :: proc(t: ^testing.T, s: ^e2e.Session, at: e2e.Point, what: string) {
	e2e.hover(s, AWAY)
	rest := shown(s, at)
	e2e.hover(s, at)
	over := shown(s, at)
	testing.expectf(t, over != rest, "%s under the pointer: %v as at rest", what, over)
	e2e.press(s, at)
	held := shown(s, at)
	testing.expectf(t, held != over && held != rest, "%s held: %v, %v under the pointer, %v at rest", what, held, over, rest)
	e2e.release(s, at)
	e2e.hover(s, AWAY)
	testing.expect_value(t, shown(s, at), rest)
}

// A scroll bar answers the pointer: under it a part changes, held it changes more, and it comes back. The document's thumb and arrow
// buttons, and a box's thumb.
@(test)
a_scroll_bar_answers_the_pointer :: proc(t: ^testing.T) {
	s := e2e.start(t, {pixels = true, size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	e2e.eval(s, fmt.tprintf("document.open(); document.write(%q); document.close(); 1", BOX_PAGE))
	bar := pref_f64(s, WIDTH_PREF)
	inner := e2e.eval_f64(s, "innerWidth")
	height := e2e.eval_f64(s, "innerHeight")
	answers_the_pointer(t, s, {inner - bar / 2, bar * THUMB_AT}, "the thumb")
	// (a corner of the button, away from its triangle)
	answers_the_pointer(t, s, {inner - bar + 1, height - bar + 1}, "the down arrow's button")
	e2e.eval(s, "scrollTo(0, 0); 1")
	e2e.wait_js(s, "scrollY == 0")
	answers_the_pointer(t, s, {BOX_SIDE - bar / 2, bar * THUMB_AT}, "the thumb of a box")
}
