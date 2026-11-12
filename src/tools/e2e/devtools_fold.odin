package e2e_scenarios

// The Elements panel's side stack (Styles, Computed, ...) folded by the button of its strip, to the strip the toolkit draws in
// its place: in the theme's colours (a dark theme: the strip was transparent, and opaque white under the pointer), its
// tooltip the size of its text and inside the window (it was as large as the window: the chrome is built under a style that
// fills), and a click on the strip brings the stack back. Driven at the boxes a screen reader is told of.

import "core:fmt"
import "core:strings"
import "core:testing"
import "toolkit:platform"
import "wb:e2e"

@(private = "file") FOLD_SIZE :: [2]int{1280, 800}
@(private = "file") FOLD_PAGE :: `<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1>Nothing moves</h1>`
@(private = "file") DARK_MAX :: 0x50              // no channel of the dark theme's strip (hovered or not) above this
@(private = "file") TIP_MAX_SHARE :: 0.4          // a tooltip of one name: less than this share of the window each way
@(private = "file") FOLDED :: "f("                // a folded split in the layout's text

@(private = "file")
fold_entry :: proc(s: ^e2e.Session, role: platform.A11y_Role, name: string, loc := #caller_location) -> e2e.A11y_Entry {
	Want :: struct { role: platform.A11y_Role, name: string }
	w := Want{role, name}
	e2e.wait_until(s, w, proc(s: ^e2e.Session, w: Want) -> bool {
		for e in e2e.a11y_tree(s) { if e.role == w.role && strings.has_prefix(e.name, w.name) { return true } }
		return false
	}, fmt.tprintf("a %v named %q", role, name), loc = loc)
	for e in e2e.a11y_tree(s, loc) { if e.role == w.role && strings.has_prefix(e.name, w.name) { return e } }
	return {}
}

@(private = "file")
fold_middle :: proc(e: e2e.A11y_Entry) -> e2e.Point { return {(e.bounds[0] + e.bounds[2]) * 0.5, (e.bounds[1] + e.bounds[3]) * 0.5} }

@(private = "file")
dark_at :: proc(s: ^e2e.Session, at: e2e.Point) -> (e2e.Color, bool) {
	c := e2e.pixel(e2e.capture(s), int(at.x), int(at.y))
	return c, c.r <= DARK_MAX && c.g <= DARK_MAX && c.b <= DARK_MAX
}

@(test)
devtools_side_stack_folds_to_a_themed_strip :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", FOLD_PAGE)
	s := e2e.start(t, {pixels = true, size = FOLD_SIZE, dpi = e2e.DPI_ONE, url = page,
		prefs = {"browser.devtools.visible=true", "browser.devtools.tab=elements", "browser.devtools.dock=right", "browser.ui.theme=midnight"}})
	e2e.a11y_capture(s)
	e2e.wait_chrome_still(s)

	// the button at the end of the Styles stack's strip folds it
	e2e.click_at(s, fold_middle(fold_entry(s, .Button, "Hide Styles")), .Window)
	e2e.wait_frames(s, 2)
	testing.expectf(t, strings.contains(e2e.pref_get(s, "browser.devtools.elements.layout"), FOLDED), "folded: %s", e2e.pref_get(s, "browser.devtools.elements.layout"))

	// the strip: dark at rest and under the pointer (a quarter down it: no chevron there)
	strip := fold_entry(s, .Splitter, "DOM tree | Styles")
	quarter := e2e.Point{fold_middle(strip).x, strip.bounds[1] + (strip.bounds[3] - strip.bounds[1]) * 0.25}
	c, ok := dark_at(s, quarter)
	testing.expectf(t, ok, "the strip is dark like the panel: %v", c)
	e2e.hover(s, fold_middle(strip), .Window)
	e2e.wait_frames(s, 2)
	c, ok = dark_at(s, quarter)
	testing.expectf(t, ok, "under the pointer too: %v", c)

	// its tooltip: the size of its text, inside the window
	_ = fold_entry(s, .Tooltip, "")
	e2e.wait_at_rest(s)   // (where the browser leaves it: no frame is asked for here)
	tip := fold_entry(s, .Tooltip, "")
	w, h := tip.bounds[2] - tip.bounds[0], tip.bounds[3] - tip.bounds[1]
	testing.expectf(t, w > 0 && w < f64(FOLD_SIZE.x) * TIP_MAX_SHARE && h > 0 && h < f64(FOLD_SIZE.y) * TIP_MAX_SHARE, "the tooltip is %v x %v", w, h)
	testing.expectf(t, tip.bounds[0] >= 0 && tip.bounds[1] >= 0 && tip.bounds[2] <= f64(FOLD_SIZE.x) && tip.bounds[3] <= f64(FOLD_SIZE.y), "inside the window: %v", tip.bounds)

	// a click on the strip brings the stack back
	e2e.click_at(s, fold_middle(strip), .Window)
	e2e.wait_frames(s, 2)
	testing.expectf(t, !strings.contains(e2e.pref_get(s, "browser.devtools.elements.layout"), FOLDED), "back: %s", e2e.pref_get(s, "browser.devtools.elements.layout"))
	_ = fold_entry(s, .Tab_Panel, "Styles")
}
