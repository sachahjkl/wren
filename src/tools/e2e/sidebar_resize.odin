package e2e_scenarios

// The tab sidebar's width handle, dragged with an injected pointer:
//   * every frame of the drag draws the sidebar's edge where the pointer is in that frame (the same distance from it in all of them: no frame shows the width
//     of the frame before);
//   * every frame paints the page at the width of its area (never an image of another width);
//   * the page's innerWidth follows the handle after each step, and the width is written to browser.tabs.sidebar_width when the button goes up, not before.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SIDEBAR_SIZE :: [2]int{1400, 800}
@(private = "file") SIDEBAR_DPI :: 144
@(private = "file") SIDEBAR_SCALE :: f64(SIDEBAR_DPI) / e2e.DPI_ONE
@(private = "file") WIDTH_AT_REST :: 240               // CSS px: the preference's default (one given on the command line would be above the user's)
@(private = "file") GRAB_INSIDE :: 2                   // px from the edge: on the handle
@(private = "file") GRAB_Y :: 500
@(private = "file") STEPS :: [?]f64{30, 75, 120, 200, 90, -60}   // window px from the press
@(private = "file") LAST_STEP :: -60
@(private = "file") SAME_DISTANCE_WITHIN :: 1          // px: the edge is on whole pixels
@(private = "file") SAME_WIDTH_WITHIN :: 1             // px
@(private = "file") INNER_WIDTH_WITHIN :: 1.5          // CSS px: a rounding each way

// Media queries on the width (the page is restyled when the handle crosses them), text that wraps differently at every width.
@(private = "file")
sidebar_page :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<!doctype html><meta charset=utf-8><title>mq</title><style>body{margin:0}p{font:16px sans-serif}@media (max-width:700px){p{font-size:20px;color:#a00}}@media (max-width:600px){p{font-size:24px}}</style><body>`)
	for _ in 0 ..< PARAGRAPHS { strings.write_string(&b, "<p>Some text that wraps differently at every width of the page, again and again.</p>") }
	return strings.to_string(b)
}
@(private = "file") PARAGRAPHS :: 40

@(test)
sidebar_edge_follows_the_pointer :: proc(t: ^testing.T) {
	url := e2e.file_page(e2e.temp_folder(t), "mq.html", sidebar_page())
	s := e2e.start(t, {size = SIDEBAR_SIZE, dpi = SIDEBAR_DPI, url = url, prefs = {"browser.tabs.position=left", "browser.frame.drag_probe=true"}})
	e2e.wait_chrome_still(s)
	inner0 := e2e.eval_f64(s, "innerWidth")
	grab := e2e.Point{math.round(f64(WIDTH_AT_REST) * SIDEBAR_SCALE) - GRAB_INSIDE, GRAB_Y}
	e2e.hover(s, grab, .Window)
	e2e.drag_samples_reset(s)
	e2e.press(s, grab, .Window)

	steps := STEPS
	for dx in steps {
		e2e.hover(s, {grab.x + dx, grab.y}, .Window)
		inner := e2e.eval_f64(s, "innerWidth")
		testing.expectf(t, math.abs(inner0 - inner - math.round(dx / SIDEBAR_SCALE)) <= INNER_WIDTH_WITHIN, "innerWidth follows the handle: %v for a step of %v px from %v", inner, dx, inner0)
	}
	testing.expect_value(t, e2e.pref_get(s, "browser.tabs.sidebar_width"), fmt.tprintf("%d", WIDTH_AT_REST))   // untouched while the handle is held
	samples := e2e.drag_samples(s)
	e2e.release(s, {grab.x + LAST_STEP, grab.y}, .Window)

	testing.expectf(t, len(samples) >= len(steps), "each step of the drag was a frame: %d samples for %d steps (browser.frame.drag_probe)", len(samples), len(steps))
	if len(samples) > 0 {
		lo, hi := max(f64), min(f64)
		for x in samples {
			lo, hi = min(lo, x.edge - x.pointer), max(hi, x.edge - x.pointer)
			if x.page_width > 0 { testing.expectf(t, math.abs(x.page_width - x.area_width) < SAME_WIDTH_WITHIN, "a frame painted the page at another width than its area: page %v, area %v", x.page_width, x.area_width) }
		}
		testing.expectf(t, hi - lo <= SAME_DISTANCE_WITHIN, "the edge lagged the pointer in some frames: edge - pointer from %v to %v px", lo, hi)
	}
	want := WIDTH_AT_REST + int(math.round(f64(LAST_STEP) / SIDEBAR_SCALE))
	e2e.wait_until(s, want, proc(s: ^e2e.Session, want: int) -> bool { return e2e.pref_get(s, "browser.tabs.sidebar_width") == fmt.tprintf("%d", want) }, "the width to be written when the button goes up")
}
