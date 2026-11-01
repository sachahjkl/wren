package e2e_scenarios

// Two windows at different scales: a window that "moves" to a monitor of another DPI changes its scale at once and alone: its chrome, its page
// (devicePixelRatio, resolution media queries, the layout), its size in proportion; the document stays where it was scrolled to (no jump); the other
// window keeps its own scale; a tab moved between the two takes the scale of the window it goes to, at the same place of its document. Headless, the
// change is the emulated one (platform.set_offscreen_dpi): the system's WM_DPICHANGED and the rectangle it suggests are not gone through.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") DPI_SIZE :: [2]int{1000, 700}
@(private = "file") PARAGRAPHS :: 120
@(private = "file") SCROLLED_TOP :: 1600
@(private = "file") MOVED_TAB_SCROLLED_TOP :: 2000
@(private = "file") HEADLESS_SCALE :: 1.0          // a window with no monitor
@(private = "file") OTHER_MONITOR :: 1.5           // relative to where it is
@(private = "file") SCALE_WITHIN :: 0.02
@(private = "file") SIZE_WITHIN :: 0.03            // of the proportion
@(private = "file") CSS_WIDTH_WITHIN :: 0.01       // of the page's CSS width
@(private = "file") LATE_EVENTS_FRAMES :: 6        // a second change event would have come by then
@(private = "file") MEDIA_QUERY_MATCHES :: "rgb(0, 128, 0)"

// A tall page whose paragraphs say where they are, a media query on the resolution, and the count of its changes.
@(private = "file")
dpi_page :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<!doctype html><title>dpi</title><style>body{margin:0} #m{position:fixed;right:10px;top:10px;width:60px;height:30px;background:red} @media (min-resolution: 1.4dppx){#m{background:green}}</style><div id=m></div>")
	for i in 1 ..= PARAGRAPHS { fmt.sbprintf(&b, "<p id=p%d style='margin:0;height:40px;font:16px sans-serif'>paragraph %d</p>", i, i) }
	strings.write_string(&b, "<script>window.changes=0;window.mq=matchMedia('(min-resolution: 1.4dppx)');mq.addEventListener('change',()=>window.changes++)</script>")
	return strings.to_string(b)
}

@(private = "file")
near :: proc(a, b, within: f64) -> bool { return math.abs(a - b) <= within }

@(private = "file")
scroll_to :: proc(s: ^e2e.Session, top: int) {
	e2e.eval(s, fmt.tprintf("scrollTo(0, %d); 'ok'", top))
	e2e.wait_js(s, fmt.tprintf("Math.round(scrollY) == %d", top))
}

@(private = "file") round_scroll :: proc(s: ^e2e.Session) -> f64 { return e2e.eval_f64(s, "Math.round(scrollY)") }

// The window goes to a monitor of this scale; its page has followed, and what would follow late has had its frames.
@(private = "file")
to_scale :: proc(s: ^e2e.Session, scale: f64) {
	e2e.set_window(s, {dpi = int(math.round(e2e.DPI_ONE * scale))})
	e2e.wait_js(s, fmt.tprintf("Math.abs(devicePixelRatio - %v) < %v", scale, SCALE_WITHIN))
	e2e.wait_frames(s, LATE_EVENTS_FRAMES)
}

@(test)
window_dpi_end_to_end :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "dpi.html", dpi_page())
	s := e2e.start(t, {size = DPI_SIZE, url = page})
	first := e2e.windows(s)[0].id
	base := e2e.window_bounds(s).dpi_scale
	testing.expect_value(t, base, HEADLESS_SCALE)   // the first window has its monitor's scale
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	second := wins[0].id != first ? wins[0].id : wins[1].id
	{ e2e.in_window(s, second); e2e.navigate(s, page); scroll_to(s, SCROLLED_TOP) }

	before_width: f64
	size0: e2e.Window
	{
		e2e.in_window(s, first)
		scroll_to(s, SCROLLED_TOP)
		before_width = e2e.eval_f64(s, "innerWidth")
		size0, _ = e2e.window_with_id(e2e.windows(s), first)
		e2e.shot(s, "04 window 1 before (100 %).png")

		// window 1 goes to a monitor of 150 %
		to_scale(s, base * OTHER_MONITOR)
		b1 := e2e.window_bounds(s)
		testing.expectf(t, near(b1.dpi_scale / base, OTHER_MONITOR, SCALE_WITHIN) && near(b1.ui_scale, b1.dpi_scale, SCALE_WITHIN) && near(b1.page_scale, b1.dpi_scale, SCALE_WITHIN), "the window that changed monitor has the new scale, its chrome and its page: dpi %v, ui %v, page %v", b1.dpi_scale, b1.ui_scale, b1.page_scale)
		size1, _ := e2e.window_with_id(e2e.windows(s), first)
		testing.expectf(t, near(f64(size1.width) / f64(size0.width), OTHER_MONITOR, SIZE_WITHIN) && near(f64(size1.height) / f64(size0.height), OTHER_MONITOR, SIZE_WITHIN), "its size follows in proportion: %dx%d -> %dx%d", size0.width, size0.height, size1.width, size1.height)
		testing.expect_value(t, round_scroll(s), f64(SCROLLED_TOP))   // the document stays where it was scrolled to (no jump)
		dpr := e2e.eval_f64(s, "devicePixelRatio")
		testing.expectf(t, near(dpr, base * OTHER_MONITOR, SCALE_WITHIN), "devicePixelRatio follows: %v", dpr)
		w := e2e.eval_f64(s, "innerWidth")
		testing.expectf(t, near(w, before_width, before_width * CSS_WIDTH_WITHIN), "the viewport keeps its CSS width (the window grew with the scale): %v -> %v", before_width, w)
		testing.expect_value(t, e2e.eval(s, "String(changes)"), "1")   // the resolution media query's change event came once
		testing.expect_value(t, e2e.eval(s, "getComputedStyle(m).backgroundColor"), MEDIA_QUERY_MATCHES)   // and it matches
		e2e.shot(s, "05 window 1 after (150 %).png")
	}
	{
		e2e.in_window(s, second)
		b2 := e2e.window_bounds(s)
		testing.expectf(t, near(b2.dpi_scale, base, SCALE_WITHIN) && near(b2.ui_scale, base, SCALE_WITHIN) && near(b2.page_scale, base, SCALE_WITHIN), "the other window keeps its own: dpi %v, ui %v, page %v", b2.dpi_scale, b2.ui_scale, b2.page_scale)
		testing.expect_value(t, round_scroll(s), f64(SCROLLED_TOP))   // the other window's page is as it was
		testing.expect_value(t, e2e.eval_f64(s, "devicePixelRatio"), base)
		e2e.shot(s, "06 window 2 stayed at 100 %.png")
	}

	// a tab goes from the window at 150 % to the one at 100 %: it takes that window's scale, at the same place of its document
	{
		e2e.in_window(s, first)
		s.tab = e2e.new_tab(s, page)
		e2e.wait_load(s)
		scroll_to(s, MOVED_TAB_SCROLLED_TOP)
	}
	e2e.move_tab(s, s.tab, second)
	{
		e2e.in_window(s, second)
		e2e.wait_js(s, fmt.tprintf("Math.abs(devicePixelRatio - %v) < %v", base, SCALE_WITHIN))
		testing.expect_value(t, round_scroll(s), f64(MOVED_TAB_SCROLLED_TOP))   // a tab moved to the window at the other scale takes its scale, at the same place
	}
	s.tab = 0

	// back to where it was
	{
		e2e.in_window(s, first)
		to_scale(s, base)
		testing.expectf(t, near(e2e.window_bounds(s).dpi_scale, base, SCALE_WITHIN), "back on the first monitor: its scale")
		testing.expect_value(t, round_scroll(s), f64(SCROLLED_TOP))              // the same place
		testing.expect_value(t, e2e.eval(s, "String(changes)"), "2")             // the media query's change event again
	}
	testing.expect_value(t, e2e.stats(s).frame_gate.violations, 0)   // no violation of the frame gate
}
