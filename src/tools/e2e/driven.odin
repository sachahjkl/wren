package e2e_scenarios

// What a program can do to a page and read of it, through the procedures the remote methods use: load, script, input, the logs, captures from the
// render target, a window off the screen or minimized, tabs, a tab moved between windows with its page as it is. (The channel itself: remote_channel.odin.)

import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") FIXTURE :: "/site/remote/fixture.htm"
@(private = "file") WINDOW_W :: 1000
@(private = "file") WINDOW_H :: 700
@(private = "file") BOX_W :: 200
@(private = "file") BOX_H :: 100
@(private = "file") FAR_AWAY :: -30000
@(private = "file") HALF :: 0.5
@(private = "file") LINE_PX :: "browser.scroll.key_line_px"
// A place of the box in a capture of it; how far from its middle the page is still white.
@(private = "file") INSIDE_THE_BOX :: 10
@(private = "file") OUTSIDE_THE_BOX := [2]int{300, 150}
// How far a colour may be from what is asked of it (a capture is the render's own, with no scale in between).
@(private = "file") TOLERANCE :: 8
@(private = "file") RED := e2e.Color{255, 0, 0, 255}
@(private = "file") WHITE := e2e.Color{255, 255, 255, 255}

near :: proc(a, b: e2e.Color, tolerance := TOLERANCE) -> bool {
	for i in 0 ..< 3 { if abs(int(a[i]) - int(b[i])) > tolerance { return false } }
	return true
}

// The middle of an element, in window pixels.
@(private = "file")
middle_in_window :: proc(s: ^e2e.Session, selector: string, loc := #caller_location) -> (x, y: int) {
	r := e2e.eval(s, strings.concatenate({`(function(){var r=document.querySelector("`, selector, `").getBoundingClientRect();return (r.x+r.width/2)+","+(r.y+r.height/2)})()`}, context.temp_allocator), loc = loc)
	a, _, b := strings.partition(r, ",")
	px, _ := strconv.parse_f64(a)
	py, _ := strconv.parse_f64(b)
	page := e2e.window_bounds(s, loc).page_rect
	return int(page.x + px), int(page.y + py)
}

@(test)
script_input_and_the_logs :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = {WINDOW_W, WINDOW_H}, dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), FIXTURE)})
	b := e2e.window_bounds(s)
	testing.expectf(t, b.width == WINDOW_W && b.height == WINDOW_H, "the client area is the size asked for: %dx%d", b.width, b.height)
	testing.expect_value(t, e2e.eval(s, "document.title"), "Remote fixture")
	testing.expect_value(t, e2e.eval(s, "[1,2,{a:3}]"), `[1,2,{"a":3}]`)
	thrown := e2e.eval_result(s, `throw new Error("boom")`).thrown
	testing.expectf(t, strings.contains(thrown, "boom"), "a script's exception comes back: %q", thrown)
	testing.expect_value(t, e2e.eval(s, "new Promise(r => setTimeout(() => r(42), 80))", await = true), "42")
	testing.expect_value(t, e2e.eval(s, `document.getElementById("box").getBoundingClientRect().width + "x" + document.getElementById("box").getBoundingClientRect().height`), "200x100")

	e2e.click(s, "#go")
	testing.expect_value(t, e2e.eval(s, "window.clicks"), "1")
	gx, gy := middle_in_window(s, "#go")
	e2e.click_at(s, {f64(gx), f64(gy)}, .Window)
	testing.expect_value(t, e2e.eval(s, "window.clicks"), "2")
	e2e.click(s, "#name")
	e2e.type_text(s, "Wren")
	e2e.key(s, "Shift+A")
	testing.expect_value(t, e2e.eval(s, `document.getElementById("name").value`), "WrenA")
	// a button below the fold of a fixed box that scrolls (a consent banner): that box is scrolled first, the page cannot bring it in
	e2e.eval(s, `document.getElementById("banner").hidden = false`)
	e2e.click(s, "#accept")
	testing.expect_value(t, e2e.eval(s, `document.getElementById("banner").hidden`), "true")

	lines := e2e.console(s)
	ready, warned := false, false
	for l in lines {
		if strings.contains(l.text, "fixture ready") { ready = true }
		if l.level == "warn" && strings.contains(l.text, "a warning") { warned = true }
	}
	testing.expect(t, ready && warned, "the console's lines, with their levels")
}

@(test)
captures_are_the_renders_own_wherever_the_window_is :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = {WINDOW_W, WINDOW_H}, dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), FIXTURE)})
	cx, cy := middle_in_window(s, "#box")
	window := e2e.capture(s)
	testing.expectf(t, window.width == WINDOW_W && window.height == WINDOW_H, "a capture has the window's size: %dx%d", window.width, window.height)
	testing.expectf(t, near(e2e.pixel(window, cx, cy), RED), "inside the red box: %v", e2e.pixel(window, cx, cy))
	// (not at the bottom of the page area: at some scales the fixture is wider than the viewport, and the horizontal scroll bar is there)
	testing.expectf(t, near(e2e.pixel(window, cx + OUTSIDE_THE_BOX.x, cy + OUTSIDE_THE_BOX.y), WHITE), "outside the box: %v", e2e.pixel(window, cx + OUTSIDE_THE_BOX.x, cy + OUTSIDE_THE_BOX.y))

	box := e2e.capture(s, {target = .Selector, selector = "#box"})
	testing.expectf(t, box.width == BOX_W && box.height == BOX_H && near(e2e.pixel(box, INSIDE_THE_BOX, INSIDE_THE_BOX), RED), "a capture of an element is that element: %dx%d", box.width, box.height)
	half := e2e.capture(s, {scale = HALF})
	testing.expectf(t, half.width == WINDOW_W / 2 && half.height == WINDOW_H / 2, "a scaled capture: %dx%d", half.width, half.height)
	count, _, _ := e2e.diff_pictures(window.rgba, window.rgba, window.width, window.height, 0)
	testing.expect_value(t, count, 0)

	// window covered, hidden, moved far off the screen: the capture does not care
	e2e.set_window(s, {pos = [2]int{FAR_AWAY, FAR_AWAY}})
	off := e2e.capture(s)
	testing.expectf(t, near(e2e.pixel(off, cx, cy), RED), "with the window off the screen: %v", e2e.pixel(off, cx, cy))
	e2e.set_window(s, {state = "minimized"})
	minimized := e2e.capture(s)
	testing.expectf(t, minimized.width > 0 && minimized.height > 0, "of a minimized window: %dx%d", minimized.width, minimized.height)
	e2e.set_window(s, {state = "normal"})
}

@(test)
tabs_prefs_and_a_tab_moved_between_windows_keeps_its_page :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = e2e.url(e2e.test_server(t), FIXTURE)})
	fixture := e2e.targets(s).tabs[0]
	blank := e2e.new_tab(s, "about:blank")
	testing.expect_value(t, len(e2e.targets(s).tabs), 2)
	testing.expect_value(t, e2e.stats(s).tabs, 2)
	e2e.pref_set(s, LINE_PX, "50")
	testing.expect_value(t, e2e.pref_get(s, LINE_PX), "50")
	e2e.close_tab(s, blank)

	e2e.activate_tab(s, fixture.id)
	s.tab = fixture.id
	e2e.eval(s, `window.counter = 0; setInterval(() => window.counter++, 10); window.origin0 = performance.timeOrigin; document.getElementById("name").value = "kept"; 1`)
	e2e.wait_js(s, "window.counter > 3")
	before := e2e.eval_f64(s, "window.counter")
	e2e.new_tab(s, "about:blank", background = true)   // (the first window stays, with a tab of its own, when this one goes)
	moved := e2e.move_tab_to_new_window(s, fixture.id)
	testing.expect(t, moved != fixture.window, "a tab moves to a new window")
	testing.expect_value(t, len(e2e.windows(s)), 2)
	here: e2e.Tab
	for tab in e2e.targets(s).tabs { if tab.id == fixture.id { here = tab } }
	testing.expect(t, here.window == moved && here.active, "the tab is in the new window and is its current one")
	e2e.wait_js(s, "window.counter > 10")
	testing.expect_value(t, e2e.eval(s, "window.origin0 === performance.timeOrigin"), "true")
	testing.expect(t, e2e.eval_f64(s, "window.counter") > before, "the counter went on")
	testing.expect_value(t, e2e.eval(s, `document.getElementById("name").value`), "kept")

	e2e.move_tab(s, fixture.id, fixture.window)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(e2e.windows(s)) == 1 }, "the empty window to close")
	testing.expect_value(t, e2e.eval(s, `window.origin0 === performance.timeOrigin && document.getElementById("name").value === "kept"`), "true")
}
