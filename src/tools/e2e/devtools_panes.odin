package e2e_scenarios

// The developer tools' panels docked by the toolkit's dock (devtools_layout.odin), driven by the harness's input at the boxes a
// screen reader is told of (their tabs, tab lists, tab panels and separators): the Styles tab dragged onto the square under
// the middle of the DOM tree's stack (it splits it: Styles below the tree), the Console dragged out of its strip onto no square
// (it floats over the panel), docked back by a double click on its strip, the layouts kept by the profile after the browser
// starts again; the panel docked under the page dragged up to nearly the whole window; the Console's stack under the others
// (the drawer of old) resized and folded by its separator.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "toolkit:platform"
import "wb:e2e"

@(private = "file") PANES_SIZE :: [2]int{1280, 800}
@(private = "file") PANES_DPI :: 96
@(private = "file") PANES_PAGE :: `<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1 id=h>Nothing moves</h1>`
// The square under the middle of a stack: its middle this far below the stack's (px): the toolkit's DOCK_MARKER_EM and
// DOCK_MARKER_GAP_EM at the panel's text (2.35 em; any text from 9 to 20 px puts this point on the square).
@(private = "file") MARKER_BELOW :: 28
// A tab dropped this far into the Elements panel's body (px from its top left) is on no square: it floats there.
@(private = "file") FLOAT_AT :: [2]f64{120, 60}
// The empty part of a floating panel's strip: this far left of its end (its menu button is before it).
@(private = "file") GRAB_FROM_END :: 40
@(private = "file") DOCK_TOP_Y :: 120            // where the panel's bar is dragged to: the panel takes nearly all the window
@(private = "file") DOCK_AT_LEAST :: 600         // its height then (px): more than the 70 % of the window it was held to
@(private = "file") DRAWER_TALLER :: 50          // how far the Console stack's separator is dragged up (px)
@(private = "file") WITHIN :: 4                  // px: a separator's own width, rounding
@(private = "file") DRAWER_LAYOUT :: "dock1 y0.700([*elements,network,application,performance,memory] [*console])"

@(private = "file")
entry :: proc(s: ^e2e.Session, role: platform.A11y_Role, name: string, prefix := false, loc := #caller_location) -> e2e.A11y_Entry {
	Want :: struct { role: platform.A11y_Role, name: string, prefix: bool }
	w := Want{role, name, prefix}
	match :: proc(e: e2e.A11y_Entry, w: Want) -> bool { return e.role == w.role && (w.prefix ? strings.has_prefix(e.name, w.name) : e.name == w.name) }
	e2e.wait_until(s, w, proc(s: ^e2e.Session, w: Want) -> bool {
		for e in e2e.a11y_tree(s) { if match(e, w) { return true } }
		return false
	}, fmt.tprintf("a %v named %q", role, name), loc = loc)
	for e in e2e.a11y_tree(s, loc) { if match(e, w) { return e } }
	return {}
}

@(private = "file")
middle :: proc(e: e2e.A11y_Entry) -> e2e.Point { return {(e.bounds[0] + e.bounds[2]) * 0.5, (e.bounds[1] + e.bounds[3]) * 0.5} }

@(private = "file")
drag :: proc(s: ^e2e.Session, from, to: e2e.Point, loc := #caller_location) {
	e2e.hover(s, from, .Window, loc = loc)
	e2e.press(s, from, .Window, loc = loc)
	e2e.hover(s, {(from.x + to.x) * 0.5, (from.y + to.y) * 0.5}, .Window, loc = loc)
	e2e.hover(s, to, .Window, loc = loc)
	e2e.release(s, to, .Window, loc = loc)
	e2e.wait_frames(s, 2, loc = loc)
}

@(private = "file")
pref_has :: proc(s: ^e2e.Session, name, part: string, loc := #caller_location) -> bool { return strings.contains(e2e.pref_get(s, name, loc), part) }

@(test)
devtools_panels_docked_by_dragging_their_tabs :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", PANES_PAGE)
	options := e2e.Options{size = PANES_SIZE, dpi = PANES_DPI, url = page, profile = e2e.temp_profile(t),
		prefs = {"browser.devtools.visible=true", "browser.devtools.tab=elements", "browser.devtools.dock=bottom"}}
	s := e2e.start(t, options)
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)

	// the Styles tab onto the square under the middle of the tree's stack: Styles below the tree
	strip := entry(s, .Tab_List, "DOM tree")
	tree := entry(s, .Tab_Panel, "DOM tree")
	stack := e2e.Point{(strip.bounds[0] + tree.bounds[2]) * 0.5, (strip.bounds[1] + tree.bounds[3]) * 0.5}
	drag(s, middle(entry(s, .Tab, "Styles")), {stack.x, stack.y + MARKER_BELOW})
	layout := e2e.pref_get(s, "browser.devtools.elements.layout")
	testing.expectf(t, strings.contains(layout, "y0.500([*tree] [*styles])"), "Styles is below the tree: %s", layout)
	styles := entry(s, .Tab_Panel, "Styles")
	tree = entry(s, .Tab_Panel, "DOM tree")
	testing.expectf(t, styles.bounds[1] >= tree.bounds[3] && styles.bounds[0] == tree.bounds[0], "Styles %v is under the tree %v", styles.bounds, tree.bounds)

	// the Console out of its strip, onto no square: it floats over the panel
	body := entry(s, .Tab_Panel, "Elements")
	drag(s, middle(entry(s, .Tab, "Console")), {body.bounds[0] + FLOAT_AT.x, body.bounds[1] + FLOAT_AT.y})
	main := e2e.pref_get(s, "browser.devtools.layout")
	testing.expectf(t, strings.contains(main, "@") && strings.contains(main, " [*console]"), "the Console floats: %s", main)
	float := entry(s, .Tab_List, "Console")
	testing.expectf(t, float.bounds[0] >= body.bounds[0] && float.bounds[1] >= body.bounds[1], "over the panel: %v", float.bounds)

	// a double click on its strip: back into the stack it came from
	e2e.forget_clicks(s)
	e2e.click_at(s, {float.bounds[2] - GRAB_FROM_END, (float.bounds[1] + float.bounds[3]) * 0.5}, .Window, count = 2)
	e2e.wait_frames(s, 2)
	main = e2e.pref_get(s, "browser.devtools.layout")
	testing.expectf(t, !strings.contains(main, "@") && strings.contains(main, "console") && strings.contains(main, "elements"), "the Console is docked back: %s", main)
	testing.expectf(t, strings.count(main, "[") == 1, "in the stack it came from: %s", main)

	// the profile keeps both layouts
	s = e2e.restart(s, options)
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.pref_get(s, "browser.devtools.layout"), main)
	testing.expect_value(t, e2e.pref_get(s, "browser.devtools.elements.layout"), layout)
	styles = entry(s, .Tab_Panel, "Styles")
	tree = entry(s, .Tab_Panel, "DOM tree")
	testing.expectf(t, styles.bounds[1] >= tree.bounds[3], "after a restart, Styles %v is still under the tree %v", styles.bounds, tree.bounds)
}

@(test)
devtools_dock_and_drawer_resize :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", PANES_PAGE)
	s := e2e.start(t, {size = PANES_SIZE, dpi = PANES_DPI, url = page,
		prefs = {"browser.devtools.visible=true", "browser.devtools.tab=elements", "browser.devtools.dock=bottom"}})
	e2e.pref_set(s, "browser.devtools.layout", DRAWER_LAYOUT)   // (the user's, as a drag sets it: one of the command line would stay over it)
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)

	// the panel under the page: dragged up, it takes nearly the whole window
	bar := entry(s, .Splitter, "Developer tools")
	drag(s, middle(bar), {middle(bar).x, DOCK_TOP_Y})
	size, _ := strconv.parse_f64(e2e.pref_get(s, "browser.devtools.size"))
	testing.expectf(t, size >= DOCK_AT_LEAST, "the panel is %v px tall: more than %d of the window's %d", size, DOCK_AT_LEAST, PANES_SIZE.y)
	page_h := e2e.window_bounds(s).page_rect.h
	testing.expectf(t, page_h > 0 && page_h < f64(PANES_SIZE.y - DOCK_AT_LEAST), "the page keeps a strip: %v px", page_h)

	// the Console's stack under the others: its separator resizes it, a double click folds it
	console := entry(s, .Tab_Panel, "Console")
	h0 := console.bounds[3] - console.bounds[1]
	sep := entry(s, .Splitter, "Elements, Network, Application, Performance, Memory | Console")
	drag(s, middle(sep), {middle(sep).x, middle(sep).y - DRAWER_TALLER})
	console = entry(s, .Tab_Panel, "Console")
	h1 := console.bounds[3] - console.bounds[1]
	testing.expectf(t, abs(h1 - (h0 + DRAWER_TALLER)) <= WITHIN, "the Console's stack is %v px tall (%v dragged %d px up)", h1, h0, DRAWER_TALLER)
	testing.expect(t, !pref_has(s, "browser.devtools.layout", "f("), "open")
	sep = entry(s, .Splitter, "Elements, Network, Application, Performance, Memory | Console")
	e2e.click_at(s, middle(sep), .Window, count = 2)
	e2e.wait_frames(s, 2)
	testing.expectf(t, pref_has(s, "browser.devtools.layout", "f("), "a double click folds the Console's stack: %s", e2e.pref_get(s, "browser.devtools.layout"))
}
