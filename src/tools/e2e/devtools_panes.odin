package e2e_scenarios

// The panes of the developer tools (the toolkit's ui.pane_split), driven by the harness's input at the bars a screen reader is
// told of: the Elements tree's side pane (Styles...) dragged narrow, folded by a double click to a strip at the panel's edge,
// brought back by a click on the strip, the sizes kept by the profile after the browser starts again; the panel docked under
// the page dragged up to nearly the whole window; the drawer (the Console moved under the tab) resized and folded.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "toolkit:platform"
import "wb:e2e"

@(private = "file") PANES_SIZE :: [2]int{1280, 800}
@(private = "file") PANES_DPI :: 96
@(private = "file") PANES_PAGE :: `<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1 id=h>Nothing moves</h1>`
@(private = "file") SIDEBAR_NARROW :: 90         // the side pane's width the bar is dragged to (px): under the 20 % the panel kept before
@(private = "file") SIDEBAR_WITHIN :: 4          // px: the bar's own width, rounding
@(private = "file") STRIP_AT_MOST :: 30          // px: a folded pane's strip
@(private = "file") DOCK_TOP_Y :: 120            // where the panel's bar is dragged to: the panel takes nearly all the window
@(private = "file") DOCK_AT_LEAST :: 600         // its height then (px): more than the 70 % of the window it was held to
@(private = "file") DRAWER_DEFAULT :: 200        // the drawer's height at first (px: DEV_DRAWER_DEFAULT_PX)
@(private = "file") DRAWER_TALLER :: 50          // how far its bar is dragged up (px)

@(private = "file")
bar_named :: proc(s: ^e2e.Session, name: string, loc := #caller_location) -> e2e.A11y_Entry {
	e2e.wait_until(s, name, proc(s: ^e2e.Session, name: string) -> bool {
		for e in e2e.a11y_tree(s) { if e.role == .Splitter && e.name == name { return true } }
		return false
	}, fmt.tprintf("the bar %q", name), loc = loc)
	for e in e2e.a11y_tree(s, loc) { if e.role == .Splitter && e.name == name { return e } }
	return {}
}

@(private = "file")
middle :: proc(e: e2e.A11y_Entry) -> e2e.Point { return {(e.bounds[0] + e.bounds[2]) * 0.5, (e.bounds[1] + e.bounds[3]) * 0.5} }

// "width height folded place" (ui.pane_format) of a preference.
@(private = "file")
pane_pref :: proc(s: ^e2e.Session, name: string, loc := #caller_location) -> (w, h: f64, folded: bool) {
	f := strings.fields(e2e.pref_get(s, name, loc), context.temp_allocator)
	if len(f) != 4 { return }
	w, _ = strconv.parse_f64(f[0])
	h, _ = strconv.parse_f64(f[1])
	return w, h, f[2] == "1"
}

@(private = "file")
drag_bar :: proc(s: ^e2e.Session, from, to: e2e.Point, loc := #caller_location) {
	e2e.hover(s, from, .Window, loc = loc)
	e2e.press(s, from, .Window, loc = loc)
	e2e.hover(s, {(from.x + to.x) * 0.5, (from.y + to.y) * 0.5}, .Window, loc = loc)
	e2e.hover(s, to, .Window, loc = loc)
	e2e.release(s, to, .Window, loc = loc)
	e2e.wait_frames(s, 2, loc = loc)
}

@(test)
devtools_sidebar_narrow_fold_restore :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", PANES_PAGE)
	options := e2e.Options{size = PANES_SIZE, dpi = PANES_DPI, url = page, profile = e2e.temp_profile(t),
		prefs = {"browser.devtools.visible=true", "browser.devtools.tab=elements", "browser.devtools.dock=bottom"}}
	s := e2e.start(t, options)
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)
	right := f64(PANES_SIZE.x)

	// dragged to a narrow side pane: it follows (the panel held it to a fifth of its width before)
	bar := bar_named(s, "Elements sidebar")
	drag_bar(s, middle(bar), {right - SIDEBAR_NARROW, middle(bar).y})
	w, _, folded := pane_pref(s, "browser.devtools.elements.sidebar")
	testing.expectf(t, math.abs(w - SIDEBAR_NARROW) <= SIDEBAR_WITHIN && !folded, "the side pane is %v px wide (dragged to %d), folded %v", w, SIDEBAR_NARROW, folded)
	bar = bar_named(s, "Elements sidebar")
	testing.expectf(t, math.abs((right - bar.bounds[2]) - SIDEBAR_NARROW) <= SIDEBAR_WITHIN, "its bar is %v px from the edge", right - bar.bounds[2])

	// a double click on its bar folds it: a strip at the panel's edge
	e2e.click_at(s, middle(bar), .Window, count = 2)
	e2e.wait_frames(s, 2)
	_, _, folded = pane_pref(s, "browser.devtools.elements.sidebar")
	testing.expect(t, folded, "a double click folds the side pane")
	strip := bar_named(s, "Elements sidebar")
	testing.expectf(t, strip.bounds[2] >= right - 1 && strip.bounds[2] - strip.bounds[0] <= STRIP_AT_MOST, "folded, a strip at the edge: %v", strip.bounds)

	// a click on the strip brings it back at its width
	e2e.forget_clicks(s)
	e2e.click_at(s, middle(strip), .Window)
	e2e.wait_frames(s, 2)
	w, _, folded = pane_pref(s, "browser.devtools.elements.sidebar")
	testing.expectf(t, !folded && math.abs(w - SIDEBAR_NARROW) <= SIDEBAR_WITHIN, "the strip brings it back at %d px: %v, folded %v", SIDEBAR_NARROW, w, folded)

	// with the keyboard: the bar has the focus from the click; Enter folds it again
	bar = bar_named(s, "Elements sidebar")
	e2e.click_at(s, middle(bar), .Window)
	e2e.key(s, "Enter")
	e2e.wait_frames(s, 2)
	_, _, folded = pane_pref(s, "browser.devtools.elements.sidebar")
	testing.expect(t, folded, "Enter on the bar folds the side pane")
	e2e.key(s, "Enter")
	e2e.wait_frames(s, 2)

	// the profile keeps it: the browser started again shows it as it was left
	s = e2e.restart(s, options)
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)
	bar = bar_named(s, "Elements sidebar")
	w, _, folded = pane_pref(s, "browser.devtools.elements.sidebar")
	testing.expectf(t, !folded && math.abs(w - SIDEBAR_NARROW) <= SIDEBAR_WITHIN, "after a restart, the side pane is %v px wide, folded %v", w, folded)
	testing.expectf(t, math.abs((right - bar.bounds[2]) - SIDEBAR_NARROW) <= SIDEBAR_WITHIN, "after a restart, its bar is %v px from the edge", right - bar.bounds[2])
}

@(test)
devtools_dock_and_drawer_resize :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", PANES_PAGE)
	s := e2e.start(t, {size = PANES_SIZE, dpi = PANES_DPI, url = page,
		prefs = {"browser.devtools.visible=true", "browser.devtools.tab=elements", "browser.devtools.dock=bottom", "browser.devtools.drawer_tabs=console"}})
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)

	// the panel under the page: dragged up, it takes nearly the whole window
	dock := bar_named(s, "Developer tools")
	drag_bar(s, middle(dock), {middle(dock).x, DOCK_TOP_Y})
	size, _ := strconv.parse_f64(e2e.pref_get(s, "browser.devtools.size"))
	testing.expectf(t, size >= DOCK_AT_LEAST, "the panel is %v px tall: more than %d of the window's %d", size, DOCK_AT_LEAST, PANES_SIZE.y)
	page_h := e2e.window_bounds(s).page_rect.h
	testing.expectf(t, page_h > 0 && page_h < f64(PANES_SIZE.y - DOCK_AT_LEAST), "the page keeps a strip: %v px", page_h)

	// the drawer (the Console under the Elements tab): its bar resizes it, a double click folds it
	drawer := bar_named(s, "Drawer")
	drag_bar(s, middle(drawer), {middle(drawer).x, middle(drawer).y - DRAWER_TALLER})
	_, h, folded := pane_pref(s, "browser.devtools.drawer")
	testing.expectf(t, math.abs(h - (DRAWER_DEFAULT + DRAWER_TALLER)) <= SIDEBAR_WITHIN && !folded, "the drawer is %v px tall (%d dragged %d px up)", h, DRAWER_DEFAULT, DRAWER_TALLER)
	drawer = bar_named(s, "Drawer")
	e2e.click_at(s, middle(drawer), .Window, count = 2)
	e2e.wait_frames(s, 2)
	_, _, folded = pane_pref(s, "browser.devtools.drawer")
	testing.expect(t, folded, "a double click folds the drawer")
	_ = platform.A11y_Role.Splitter
}
