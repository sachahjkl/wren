package e2e_scenarios

// The docked developer tools while their splitter is dragged: the first frame drawn at a new width must be the one that is drawn at that width
// once the layout has settled (no frame laid out for the width of the frame before: a header, a filter field or columns squeezed or stretched into
// the new box). After each step of the drag, a frame later, a capture of the panel; a few frames later another: they must be the same picture.
// For each panel (Network, Console, Elements) and each dock side. No timing.

import "core:fmt"
import "core:math"
import "core:testing"
import "wb:e2e"

// A page that does nothing by itself (its panels must not change under the comparison).
@(private = "file") STILL_PAGE :: `<!doctype html><meta charset=utf-8><title>static</title><body style="margin:0;background:#fff"><h1>Nothing moves</h1>`
@(private = "file") SPLIT_SIZE :: [2]int{1280, 800}
@(private = "file") SPLIT_DPI :: 96
@(private = "file") FIRST_PANEL_WIDTH :: 300
@(private = "file") BAR_OFFSET :: 3             // the middle of the bar (5 px wide) from the panel's edge
// The widths of the panel in turn: wider, much wider, narrower, narrow.
@(private = "file") PANEL_WIDTHS :: [?]int{380, 520, 440, 330, 260, 410}
// What is compared: the panel without the bar and the page's notices, its header and its first rows.
@(private = "file") CLIP_TOP :: 84
@(private = "file") CLIP_HEIGHT :: 90
@(private = "file") CLIP_LESS_WIDTH :: 14
@(private = "file") CLIP_LEFT_DOCK_X :: 4
@(private = "file") CLIP_RIGHT_DOCK_X :: 10     // from the panel's edge
@(private = "file") FIRST_FRAME :: 1
@(private = "file") SETTLED_AFTER :: 6
@(private = "file") SAME_WITHIN :: 6            // a channel's difference, rounding of a resampled glyph
@(private = "file") PAGE_WIDTH_WITHIN :: 8.0    // the bar, and the pixels the pointer's grab takes

// One start of the browser with this panel at this side, the splitter dragged through the widths.
@(private = "file")
drag_splitter :: proc(s: ^e2e.Session, t: ^testing.T, panel, dock: string, loc := #caller_location) {
	right := dock == "right"
	width, height := SPLIT_SIZE.x, SPLIT_SIZE.y
	y := f64(height / 2)
	bar_at :: proc(right: bool, window_width, panel_width: int) -> f64 { return f64(right ? window_width - panel_width - BAR_OFFSET : panel_width + BAR_OFFSET) }
	e2e.wait_chrome_still(s, loc = loc)
	start := e2e.Point{bar_at(right, width, FIRST_PANEL_WIDTH), y}
	e2e.hover(s, start, .Window, loc = loc)
	e2e.press(s, start, .Window, loc = loc)
	last := start
	widths := PANEL_WIDTHS
	for w in widths {
		last = {bar_at(right, width, w), y}
		e2e.hover(s, last, .Window, loc = loc)
		e2e.wait_frames(s, FIRST_FRAME, loc = loc)
		page_width := e2e.window_bounds(s, loc).page_rect.w
		testing.expectf(t, math.abs(page_width - f64(width - w)) <= PAGE_WIDTH_WITHIN, "%s, panel at the %s: the drag moved the splitter: a panel of %d px leaves the page %v px of %d", panel, dock, w, page_width, width, loc = loc)
		clip := e2e.Rect{f64(right ? width - w + CLIP_RIGHT_DOCK_X : CLIP_LEFT_DOCK_X), CLIP_TOP, f64(w - CLIP_LESS_WIDTH), CLIP_HEIGHT}
		shot := e2e.Shot_Options{target = .Rect, rect = clip, has_settle = true}
		first := e2e.capture(s, shot, loc)
		e2e.wait_frames(s, SETTLED_AFTER, loc = loc)
		settled := e2e.capture(s, shot, loc)
		differ := first.width * first.height
		if first.width == settled.width && first.height == settled.height {
			differ, _, _ = e2e.diff_pictures(first.rgba, settled.rgba, first.width, first.height, SAME_WITHIN)
		}
		testing.expectf(t, differ == 0, "%s, panel at the %s: the first frame at %d px differs from the settled one in %d pixels", panel, dock, w, differ, loc = loc)
		if differ != 0 { e2e.shot(s, fmt.tprintf("%s %s %d settled.png", panel, dock, w), shot, loc) }
	}
	e2e.release(s, last, .Window, loc = loc)
	// what the panel took for its own width was the width its layout gave it, at every frame
	st := e2e.stats(s, loc)
	testing.expectf(t, st.devtools_room_checks > 0 && st.devtools_room_wrong == 0, "%s, panel at the %s: its width as asked differed from its layout's in %d of %d frames", panel, dock, st.devtools_room_wrong, st.devtools_room_checks, loc = loc)
}

@(private = "file")
split_both_sides :: proc(t: ^testing.T, panel: string, loc := #caller_location) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", STILL_PAGE)
	options := e2e.Options{size = SPLIT_SIZE, dpi = SPLIT_DPI, url = page, prefs = {"browser.devtools.visible=true", fmt.tprintf("browser.devtools.tab=%s", panel), "browser.devtools.dock=right"}}
	s := e2e.start(t, options, loc)
	drag_splitter(s, t, panel, "right", loc)
	options.prefs = {"browser.devtools.visible=true", fmt.tprintf("browser.devtools.tab=%s", panel), "browser.devtools.dock=left"}
	s = e2e.restart(s, options, loc)
	drag_splitter(s, t, panel, "left", loc)
}

@(test)
devtools_split_network :: proc(t: ^testing.T) { split_both_sides(t, "network") }

@(test)
devtools_split_console :: proc(t: ^testing.T) { split_both_sides(t, "console") }

@(test)
devtools_split_elements :: proc(t: ^testing.T) { split_both_sides(t, "elements") }

// Docked at the bottom beside the tabs' sidebar (either side): the panel is laid out at the page column's width, not at the
// window's (it was, and its right end, with its counters and its buttons, was cut off by the width of the sidebar).
@(test)
devtools_bottom_beside_the_tabs_sidebar :: proc(t: ^testing.T) {
	page := e2e.file_page(e2e.temp_folder(t), "static.html", STILL_PAGE)
	s: ^e2e.Session
	for side in ([]string{"left", "right"}) {
		options := e2e.Options{size = SPLIT_SIZE, dpi = SPLIT_DPI, url = page, prefs = {"browser.devtools.visible=true", "browser.devtools.tab=console", "browser.devtools.dock=bottom", fmt.tprintf("browser.tabs.position=%s", side)}}
		s = s == nil ? e2e.start(t, options) : e2e.restart(s, options)
		e2e.wait_chrome_still(s)
		st := e2e.stats(s)
		testing.expectf(t, st.devtools_room_checks > 0 && st.devtools_room_wrong == 0, "tabs on the %s: the panel's width as asked differed from its layout's in %d of %d frames", side, st.devtools_room_wrong, st.devtools_room_checks)
	}
}
