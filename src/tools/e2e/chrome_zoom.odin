package e2e_scenarios

// The zoom of the browser's own interface (chrome_zoom.odin): Ctrl+wheel over the chrome and Ctrl+Plus, Minus, 0 while it has the keyboard zoom
// it, and leave the page's scale and width alone; Ctrl+wheel over the page zooms the page and leaves the interface alone.

import "core:testing"
import "wb:e2e"

@(private = "file") ZOOM_SIZE :: [2]int{1000, 600}
@(private = "file") ON_THE_TOOLBAR :: e2e.Point{300, 10}   // window pixels, near the top of the window
@(private = "file") ON_THE_PAGE :: e2e.Point{500, 400}
@(private = "file") ZOOM_IN :: -1.0                        // a notch of the wheel, upwards
@(private = "file") ZOOM_OUT :: 1.0

// The page's own measures: its scale, its width, and the height the chrome leaves it.
@(private = "file") Measures :: struct { dpr, width, height: f64 }

@(private = "file")
measures :: proc(s: ^e2e.Session, loc := #caller_location) -> Measures {
	return {e2e.eval_f64(s, "devicePixelRatio", loc), e2e.eval_f64(s, "innerWidth", loc), e2e.eval_f64(s, "innerHeight", loc)}
}

@(private = "file")
page_shorter :: proc(s: ^e2e.Session, m: Measures) -> bool { return measures(s).height < m.height }

@(private = "file")
page_height_back :: proc(s: ^e2e.Session, m: Measures) -> bool { return measures(s).height == m.height }

@(test)
chrome_zoom_end_to_end :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = ZOOM_SIZE, url = e2e.url(e2e.test_server(t), "/")})
	m0 := measures(s)

	e2e.key(s, "Ctrl+L")
	e2e.key(s, "Ctrl+Equal Ctrl+Equal Ctrl+Equal")
	e2e.wait_until(s, m0, page_shorter, "the keys to zoom the interface while it has the keyboard: the page gets less height")
	m1 := measures(s)
	testing.expectf(t, m1.dpr == m0.dpr && m1.width == m0.width, "the page keeps its scale and its width: %v, was %v", m1, m0)
	e2e.key(s, "Ctrl+0")
	e2e.wait_until(s, m0, page_height_back, "Ctrl+0 to bring the interface back")

	// the pointer on the toolbar
	e2e.scroll(s, ZOOM_IN, ON_THE_TOOLBAR, .Window, ctrl = true)
	e2e.wait_until(s, m0, page_shorter, "Ctrl+wheel over the interface to zoom it")
	m2 := measures(s)
	testing.expectf(t, m2.dpr == m0.dpr, "and it leaves the page's scale alone: %v, was %v", m2.dpr, m0.dpr)
	e2e.scroll(s, ZOOM_OUT, ON_THE_TOOLBAR, .Window, ctrl = true)
	e2e.wait_until(s, m0, page_height_back, "the wheel the other way to bring it back")

	// the pointer on the page
	e2e.scroll(s, ZOOM_IN, ON_THE_PAGE, .Window, ctrl = true)
	e2e.wait_until(s, m0, proc(s: ^e2e.Session, m: Measures) -> bool { return measures(s).dpr > m.dpr }, "Ctrl+wheel over the page to zoom the page")
}
