package e2e_scenarios

// Middle-click autoscroll of the page (page_autoscroll.odin, ui/autoscroll.odin): a tall page from the test server, a middle press and a
// pointer moved down scroll it, the speed grows with the distance, Escape stops it, and a middle click on a link opens a new tab. Correctness
// only: no timing is asserted.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:testing"
import "wb:e2e"

@(private = "file") AUTOSCROLL_PAGE :: "/site/autoscroll.html"
@(private = "file") AUTOSCROLL_SIZE :: [2]int{900, 700}
@(private = "file") AUTOSCROLL_PREF :: "browser.scroll.autoscroll.enabled=true"
@(private = "file") LEAST_SCROLL_RANGE :: 1000.0   // how tall the page is, beyond its window
@(private = "file") AT_THE_TOP :: 1.0
// Page points: the press, low on the page; the pointer held far below it, near the edge, just past the dead zone.
@(private = "file") ANCHOR :: e2e.Point{450, 400}
@(private = "file") FAR_BELOW :: e2e.Point{450, 650}
@(private = "file") NEAR_THE_EDGE :: e2e.Point{450, 690}
@(private = "file") PAST_THE_DEAD_ZONE :: e2e.Point{450, 420}
@(private = "file") MOVED_AT_LEAST :: 2.0          // px: it scrolled
@(private = "file") FASTER_BY_AT_LEAST :: 1.0      // px over SPEED_FRAMES
@(private = "file") SPEED_FRAMES :: 10
@(private = "file") STOPPED_WITHIN :: 2.0          // px: it no longer scrolls
@(private = "file") ESCAPE_FRAMES :: 3
@(private = "file") WATCHED_FRAMES :: 10           // how long a pointer far away is given to scroll a page it should not

// A page that scrolls both ways, a panel on it that scrolls down only: the press below the panel, then in it.
@(private = "file") AUTOSCROLL_2D_PAGE :: "/site/autoscroll-2d.html"
@(private = "file") ON_THE_PAGE :: e2e.Point{300, 500}
@(private = "file") RIGHT_OF_THE_PAGE_ANCHOR :: e2e.Point{600, 500}
@(private = "file") IN_THE_PANEL :: e2e.Point{300, 200}
@(private = "file") BELOW_THE_PANEL_ANCHOR :: e2e.Point{300, 300}   // slow: the panel is far from its end when looked at
@(private = "file") RIGHT_OF_THE_PANEL_ANCHOR :: e2e.Point{600, 200}
@(private = "file") UNMOVED_WITHIN :: 1.0          // px: an axis the pointer did not ask for

@(private = "file")
scroll_y :: proc(s: ^e2e.Session, loc := #caller_location) -> f64 { return e2e.eval_f64(s, "window.scrollY", loc) }

// How far the same frames move the page, from the top, inside one call: the number of frames between two calls is no measure.
@(private = "file")
frames_moved :: proc(s: ^e2e.Session, loc := #caller_location) -> f64 {
	script := fmt.tprintf("new Promise((ok) => {{ window.scrollTo(0, 0); let n = 0, y0 = 0; const step = () => {{ if (n === 1) y0 = window.scrollY; if (n++ === %d) ok(window.scrollY - y0); else requestAnimationFrame(step); }}; requestAnimationFrame(step); }})", SPEED_FRAMES)
	f, _ := strconv.parse_f64(e2e.eval(s, script, await = true, loc = loc))
	return f
}

@(test)
autoscroll_end_to_end :: proc(t: ^testing.T) {
	url := e2e.url(e2e.test_server(t), AUTOSCROLL_PAGE)
	s := e2e.start(t, {size = AUTOSCROLL_SIZE, prefs = {AUTOSCROLL_PREF}, url = url})
	range := e2e.eval_f64(s, "document.documentElement.scrollHeight - window.innerHeight")
	testing.expectf(t, range > LEAST_SCROLL_RANGE, "the page is tall enough to scroll: %v", range)
	y0 := scroll_y(s)
	testing.expectf(t, y0 < AT_THE_TOP, "it starts at the top: %v", y0)

	// a middle press low on the page, the pointer held far below the anchor: it scrolls down
	e2e.press(s, ANCHOR, button = .Middle)
	e2e.hover(s, FAR_BELOW)
	e2e.wait_js(s, fmt.tprintf("window.scrollY > %v", y0 + MOVED_AT_LEAST))

	// farther from the anchor scrolls faster: the same frames move more
	e2e.hover(s, NEAR_THE_EDGE)
	fast := frames_moved(s)
	e2e.hover(s, PAST_THE_DEAD_ZONE)
	slow := frames_moved(s)
	testing.expectf(t, fast > slow + FASTER_BY_AT_LEAST, "the speed grows with the distance: fast %v, slow %v", fast, slow)

	// Escape ends the session
	e2e.key(s, "Escape")
	e2e.wait_frames(s, ESCAPE_FRAMES)
	stopped := scroll_y(s)
	e2e.hover(s, NEAR_THE_EDGE)
	e2e.wait_frames(s, WATCHED_FRAMES)
	after := scroll_y(s)
	testing.expectf(t, math.abs(after - stopped) < STOPPED_WITHIN, "Escape stops autoscroll: %v -> %v", stopped, after)
	e2e.release(s, NEAR_THE_EDGE, button = .Middle)

	// a middle click on a link opens a new tab (autoscroll never starts over a link): a real press and release, the mouse's path
	e2e.eval(s, "window.scrollTo(0, 0); 'ok'")
	e2e.wait_js(s, "window.scrollY == 0")
	link := e2e.Point{
		e2e.eval_f64(s, `(() => { const r = document.getElementById("lnk").getBoundingClientRect(); return Math.round(r.left + r.width / 2) })()`),
		e2e.eval_f64(s, `(() => { const r = document.getElementById("lnk").getBoundingClientRect(); return Math.round(r.top + r.height / 2) })()`),
	}
	before := len(e2e.targets(s).tabs)
	e2e.press(s, link, button = .Middle)
	e2e.release(s, link, button = .Middle)
	e2e.wait_until(s, before, proc(s: ^e2e.Session, before: int) -> bool { return len(e2e.targets(s).tabs) > before }, "a middle click on a link to open a new tab")
}

// Both axes: the pointer to the right of the anchor scrolls sideways, on the page and in a panel that scrolls down only
// (its page takes the sideways part, as Chrome chains it).
@(test)
autoscroll_both_axes :: proc(t: ^testing.T) {
	url := e2e.url(e2e.test_server(t), AUTOSCROLL_2D_PAGE)
	s := e2e.start(t, {size = AUTOSCROLL_SIZE, prefs = {AUTOSCROLL_PREF}, url = url})

	// on the page: right scrolls it sideways, not down
	e2e.press(s, ON_THE_PAGE, button = .Middle)
	e2e.hover(s, RIGHT_OF_THE_PAGE_ANCHOR)
	e2e.wait_js(s, fmt.tprintf("window.scrollX > %v", MOVED_AT_LEAST))
	testing.expectf(t, scroll_y(s) < UNMOVED_WITHIN, "the page scrolled sideways only: scrollY %v", scroll_y(s))
	e2e.key(s, "Escape")
	e2e.release(s, RIGHT_OF_THE_PAGE_ANCHOR, button = .Middle)
	e2e.eval(s, "window.scrollTo(0, 0); 'ok'")
	e2e.wait_js(s, "window.scrollX == 0 && window.scrollY == 0")

	// in the panel: down scrolls the panel and not the page, right scrolls the page
	e2e.press(s, IN_THE_PANEL, button = .Middle)
	e2e.hover(s, BELOW_THE_PANEL_ANCHOR)
	e2e.wait_js(s, fmt.tprintf("document.getElementById('panel').scrollTop > %v", MOVED_AT_LEAST))
	testing.expectf(t, scroll_y(s) < UNMOVED_WITHIN, "the panel took the downward scroll: page scrollY %v", scroll_y(s))
	e2e.hover(s, RIGHT_OF_THE_PANEL_ANCHOR)
	e2e.wait_js(s, fmt.tprintf("window.scrollX > %v", MOVED_AT_LEAST))
	e2e.key(s, "Escape")
	e2e.release(s, RIGHT_OF_THE_PANEL_ANCHOR, button = .Middle)
}
