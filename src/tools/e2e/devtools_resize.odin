#+build windows
package e2e_scenarios

// The developer tools while they are resized.
//   * Docked: the panel has the size the preference gives it (the page area shrinks by the same amount), at the bottom and at the side. (The panel once ignored its size: it
//     shared the room half and half with the page, whatever the splitter did.)
//   * A window being resized is never shown stretched. The system's compositor shows the swap chain's buffers as they are, in a window that clips them, and it would stretch
//     buffers whose size follows the window until the next frame. So what is read is the surface itself: browser.window.fixed_surface makes buffers that keep one size, whatever
//     the window's, for the browser's window and for the panel's own; without the preference they follow. What the screen then shows is the compositor's, and is not read here.

import "core:fmt"
import win "core:sys/windows"
import "core:testing"
import "wb:e2e"

@(private = "file") PANEL_WINDOW :: [2]int{1280, 800}
@(private = "file") PANEL_DPI :: 168
@(private = "file") RIGHT_SIZES :: [?]int{220, 365, 160}      // CSS px of the panel: within its limits (at least 100, at most 70 % of the window)
@(private = "file") BOTTOM_SIZES :: [?]int{135, 210, 115}
@(private = "file") FIRST_SIZE :: 150
@(private = "file") SIZE_WITHIN :: 4                          // CSS px: the splitter, a rounding
@(private = "file") RESIZE_STEPS :: [?][2]int{{1100, 760}, {900, 600}, {1270, 800}, {760, 480}, {1000, 700}}   // all within the monitor's size
@(private = "file") AT_REST :: [2]int{1000, 700}
@(private = "file") HEADER_STRIP :: e2e.Rect{0, 0, 260, 44}   // the window's top left: the tab, the panel's header: what a scaled surface would move
@(private = "file") SAME_WITHIN :: 8                          // a channel's difference
@(private = "file") STRIP_DIFFERS_AT_MOST :: 40               // pixels

// One start for a side: the panel at each size, the page has what it leaves.
@(private = "file")
docked_sizes :: proc(t: ^testing.T, dock, property: string, sizes: []int, loc := #caller_location) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", `<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0">`)
	s := e2e.start(t, {size = PANEL_WINDOW, dpi = PANEL_DPI, url = page, prefs = {"browser.devtools.visible=true", "browser.devtools.tab=console", fmt.tprintf("browser.devtools.dock=%s", dock)}}, loc)
	e2e.pref_set(s, "browser.devtools.size", fmt.tprintf("%d", FIRST_SIZE), loc)
	e2e.wait_chrome_still(s, loc = loc)
	whole := e2e.eval_f64(s, fmt.tprintf("window.%s", property), loc = loc) + FIRST_SIZE
	for size in sizes {
		e2e.pref_set(s, "browser.devtools.size", fmt.tprintf("%d", size), loc)
		// (the state itself: a panel that keeps another size ends the test here, saying which)
		e2e.wait_js(s, fmt.tprintf("Math.abs(window.%s - %v) <= %d", property, whole - f64(size), SIZE_WITHIN), loc = loc)
	}
	e2e.stop(s)
}

@(test)
docked_panel_has_its_size_at_the_side :: proc(t: ^testing.T) {
	sizes := RIGHT_SIZES
	docked_sizes(t, "right", "innerWidth", sizes[:])
}

@(test)
docked_panel_has_its_size_at_the_bottom :: proc(t: ^testing.T) {
	sizes := BOTTOM_SIZES
	docked_sizes(t, "bottom", "innerHeight", sizes[:])
}

@(private = "file")
expect_same_buffers :: proc(t: ^testing.T, s: ^e2e.Surface, want: [2]int, what: string, loc := #caller_location) {
	testing.expectf(t, s.fixed, "%s: a fixed surface", what, loc = loc)
	testing.expectf(t, s.buffers == want && s.source == want, "%s: its buffers keep their size while it resizes: %v, the region shown %v, for %v", what, s.buffers, s.source, want, loc = loc)
}

@(test)
a_window_resized_keeps_its_surface :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", `<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1>Nothing moves</h1><p>A static page.</p>`)
	s := e2e.start(t, {size = AT_REST, hidden = true, url = page, prefs = {"browser.devtools.visible=true", "browser.devtools.tab=console"}})
	e2e.wait_chrome_still(s)
	s0 := e2e.stats(s).surface
	testing.expectf(t, s0.buffers.x >= AT_REST.x && s0.buffers.y >= AT_REST.y, "the buffers hold the window: %v", s0.buffers)
	rest := e2e.capture(s, {target = .Rect, rect = HEADER_STRIP, has_settle = true})
	steps := RESIZE_STEPS
	for size in steps {
		e2e.set_window(s, {size = size})
		e2e.wait_until(s, size, proc(s: ^e2e.Session, want: [2]int) -> bool { return e2e.stats(s).surface.size == want }, fmt.tprintf("the window to take the size %v", size))
		now := e2e.stats(s).surface
		expect_same_buffers(t, &now, s0.buffers, "the browser's window")
		e2e.wait_chrome_still(s)
		strip := e2e.capture(s, {target = .Rect, rect = HEADER_STRIP, has_settle = true})
		differ, _, _ := e2e.diff_pictures(rest.rgba, strip.rgba, rest.width, rest.height, SAME_WITHIN)
		testing.expectf(t, differ <= STRIP_DIFFERS_AT_MOST, "at %v, the top left of the window is drawn as at rest, 1:1: %d pixels differ", size, differ)
	}
}

@(test)
the_panel_window_resized_keeps_its_surface :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = AT_REST, hidden = true})
	e2e.open_devtools(s, "console", "window")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).panel_surface.buffers.x > 0 }, "the developer tools' own window")
	panel := win.HWND(uintptr(e2e.windows(s)[0].devtools.hwnd))
	testing.expect(t, panel != nil && !bool(win.IsWindowVisible(panel)), "the panel's window exists and is not shown")
	s0 := e2e.stats(s).panel_surface
	steps := RESIZE_STEPS
	for size in steps {
		win.SetWindowPos(panel, nil, 0, 0, i32(size.x), i32(size.y), win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
		r: win.RECT
		win.GetClientRect(panel, &r)
		client := [2]int{int(r.right - r.left), int(r.bottom - r.top)}
		e2e.wait_until(s, client, proc(s: ^e2e.Session, want: [2]int) -> bool { return e2e.stats(s).panel_surface.size == want }, fmt.tprintf("the panel's surface to take the size %v", client))
		now := e2e.stats(s).panel_surface
		expect_same_buffers(t, &now, s0.buffers, "the panel's window")
	}
}

// What the check above tells apart: without the preference the buffers follow the window (and the compositor stretches them until the next frame).
@(test)
without_a_fixed_surface_the_buffers_follow :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = AT_REST, hidden = true, prefs = {"browser.window.fixed_surface=false"}})
	e2e.wait_chrome_still(s)
	s0 := e2e.stats(s).surface
	testing.expect(t, !s0.fixed, "no fixed surface")
	smaller := RESIZE_STEPS[1]
	e2e.set_window(s, {size = smaller})
	e2e.wait_until(s, smaller, proc(s: ^e2e.Session, want: [2]int) -> bool { return e2e.stats(s).surface.size == want }, "the window to take the size")
	now := e2e.stats(s).surface
	testing.expectf(t, now.buffers != s0.buffers || now.source == smaller, "what is shown follows the window: buffers %v -> %v, the region shown %v", s0.buffers, now.buffers, now.source)
}
