package browser

import "core:testing"
import "toolkit:draw"
import "wb:config"

@(test)
tabs_position_names :: proc(t: ^testing.T) {
	for pos in Tabs_Position { testing.expect_value(t, tabs_position_of(TABS_POSITION_NAMES[pos]), pos) }
	testing.expect_value(t, tabs_position_of(""), Tabs_Position.Top)
	testing.expect_value(t, tabs_position_of("bottom"), Tabs_Position.Top)   // not a position: the row of tabs
}

// The preference takes the three positions and nothing else, at once; the widths are bounded.
@(test)
tabs_position_preferences :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	s := tab_settings_from_prefs(&p)
	testing.expect_value(t, s.position, Tabs_Position.Top)   // the default
	testing.expect_value(t, s.side_w, 240)
	testing.expect_value(t, s.side_collapsed_w, 48)
	testing.expect(t, !s.side_collapsed)
	for pos in Tabs_Position {
		testing.expect_value(t, config.set_from_string(&p, "browser.tabs.position", TABS_POSITION_NAMES[pos], .User), config.Set_Error.None)
		testing.expect_value(t, tab_settings_from_prefs(&p).position, pos)
	}
	testing.expect(t, config.set_from_string(&p, "browser.tabs.position", "bottom", .User) != config.Set_Error.None)
	testing.expect_value(t, tab_settings_from_prefs(&p).position, Tabs_Position.Right)   // a refused value changes nothing

	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_width", "50", .User) != config.Set_Error.None)
	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_width", "5000", .User) != config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.tabs.sidebar_width", "300", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.tabs.sidebar_collapsed", "true", .User), config.Set_Error.None)
	s = tab_settings_from_prefs(&p)
	testing.expect_value(t, s.side_w, 300)
	testing.expect(t, s.side_collapsed)
	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_collapsed_width", "10", .User) != config.Set_Error.None)
	testing.expect(t, config.set_from_string(&p, "browser.tabs.sidebar_row_em", "0.5", .User) != config.Set_Error.None)
}

// The sidebar is as wide as asked, between its minimum and half of the window; icons only: its own narrow width.
@(test)
sidebar_extents :: proc(t: ^testing.T) {
	testing.expect_value(t, sidebar_extent(1280, 240, 1, false, 48), 240)
	testing.expect_value(t, sidebar_extent(1280, 240, 1.5, false, 48), 360)    // times the display's scale
	testing.expect_value(t, sidebar_extent(1280, 40, 1, false, 48), 120)       // never narrower than the minimum
	testing.expect_value(t, sidebar_extent(1000, 600, 1, false, 48), 500)      // never more than half of the window
	testing.expect_value(t, sidebar_extent(200, 240, 1, false, 48), 120)       // a window narrower than twice the minimum: the minimum
	testing.expect_value(t, sidebar_extent(1280, 240, 1, true, 48), 48)
	testing.expect_value(t, sidebar_extent(1280, 240, 2, true, 48), 96)
	testing.expect_value(t, sidebar_extent(60, 240, 1, true, 48), 30)          // (the room of a tiny window comes first)
}

// The page and the sidebar share the body without overlapping, whatever the position: the sidebar's width and the page's
// make the window's width, and a page at the top has it all.
@(test)
page_and_sidebar_share_the_window :: proc(t: ^testing.T) {
	win := draw.Vec2{1280, 800}
	toolbar_h: f32 = 88   // the title bar and the address row above the body
	body := draw.Rect{{0, toolbar_h}, win}
	for pos in Tabs_Position {
		for extent in ([?]f32{0, 48, 240, 640, 5000}) {
			bar, page := sidebar_split(body, pos, extent)
			if pos == .Top {
				testing.expect_value(t, page, body)
				testing.expect_value(t, bar, draw.Rect{})
				continue
			}
			e := clamp(extent, 0, win.x)
			testing.expect_value(t, bar.max.x - bar.min.x, e)
			testing.expect_value(t, (bar.max.x - bar.min.x) + (page.max.x - page.min.x), win.x)
			testing.expect_value(t, bar.min.y, toolbar_h)
			testing.expect_value(t, page.min.y, toolbar_h)
			testing.expect_value(t, bar.max.y, win.y)
			testing.expect_value(t, page.max.y, win.y)
			// they touch and do not overlap: one ends where the other starts
			if pos == .Left {
				testing.expect_value(t, bar.min.x, 0)
				testing.expect_value(t, bar.max.x, page.min.x)
				testing.expect_value(t, page.max.x, win.x)
			} else {
				testing.expect_value(t, page.min.x, 0)
				testing.expect_value(t, page.max.x, bar.min.x)
				testing.expect_value(t, bar.max.x, win.x)
			}
		}
	}
}

// Only the rows in view and a margin around it are built; a long glide builds what the view shows and a little around.
@(test)
sidebar_builds_only_the_visible_rows :: proc(t: ^testing.T) {
	// 1000 tabs of 40 px in a 400 px view
	f, l := side_visible_rows(0, 0, 400, 40, 1000, 80)
	testing.expect_value(t, f, 0)
	testing.expect_value(t, l, 12)    // 0..400 and two rows below
	f, l = side_visible_rows(4000, 4000, 400, 40, 1000, 80)
	testing.expect_value(t, f, 98)    // 4000 - 80
	testing.expect_value(t, l, 112)   // 4400 + 80
	f, l = side_visible_rows(4000, 4200, 400, 40, 1000, 80)   // heading down by a few rows: they are built already
	testing.expect_value(t, f, 98)
	testing.expect_value(t, l, 117)
	f, l = side_visible_rows(0, 30000, 400, 40, 1000, 80)     // a jump far away: not what is on the way
	testing.expect_value(t, l, 12 + 20)                       // (target held to two views from the offset)
	f, l = side_visible_rows(39700, 39700, 400, 40, 1000, 80) // the end
	testing.expect_value(t, l, 1000)
	testing.expect(t, f > 0 && f < l)
	f, l = side_visible_rows(0, 0, 400, 40, 3, 80)            // few tabs: all of them
	testing.expect_value(t, f, 0)
	testing.expect_value(t, l, 3)
	f, l = side_visible_rows(0, 0, 400, 40, 0, 80)
	testing.expect_value(t, l, 0)
	testing.expect_value(t, f, 0)
}

// The geometry of the row of tabs, along Y: the row a dragged tab goes to, and the scroll that keeps the current tab in view.
@(test)
sidebar_rows_reorder_along_y :: proc(t: ^testing.T) {
	rh: f32 = 40
	// a row dragged by its top edge (content coordinates) belongs to the slot its middle is over
	testing.expect_value(t, drag_slot(0, rh, 8), 0)
	testing.expect_value(t, drag_slot(19, rh, 8), 0)
	testing.expect_value(t, drag_slot(20, rh, 8), 1)
	testing.expect_value(t, drag_slot(140, rh, 8), 4)
	testing.expect_value(t, drag_slot(-300, rh, 8), 0)     // held above the list: the first
	testing.expect_value(t, drag_slot(9000, rh, 8), 7)     // below it: the last
	// 30 tabs in a 400 px view scroll up to 800 px; the current tab is brought into view
	testing.expect_value(t, strip_offset(0, 30, rh, 400, 29, true), 800)
	testing.expect_value(t, strip_offset(800, 30, rh, 400, 0, true), 0)
	testing.expect_value(t, strip_offset(100, 30, rh, 400, 5, true), 100)    // in view already
	testing.expect_value(t, strip_offset(0, 5, rh, 400, 4, true), 0)         // everything fits
	// the order is the strip's: moving a row moves the tab, and the current tab goes along
	l := [5]int{0, 1, 2, 3, 4}
	cur := list_move(l[:], 0, drag_slot(3 * rh, rh, 5), 0)
	testing.expect_value(t, l, [5]int{1, 2, 3, 0, 4})
	testing.expect_value(t, cur, 3)
}
