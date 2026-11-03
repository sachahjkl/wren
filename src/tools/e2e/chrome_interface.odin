package e2e_scenarios

// The interface as a whole with no browser around it (chrome_world.odin): its own zoom, the developer tools docked at their size, the main menu over the window's edge, the themes, a row's menu over the downloads drop-down.

import "core:fmt"
import "core:strings"
import "core:testing"
import session "toolkit:testkit/session"
import "toolkit:platform"
import "toolkit:ui"
import "wb:browser"
import "wb:config"

@(private = "file") ZOOM_SIZE :: [2]int{1000, 600}
@(private = "file") ZOOM_PREF :: "browser.ui.zoom"
@(private = "file") KEY_STEP :: 0.1                                  // what Ctrl+Plus adds (chrome_zoom.odin)
@(private = "file") ZOOM_WITHIN :: 0.001
@(private = "file") ON_THE_TOOLBAR :: [2]f32{300, 10}                // window pixels, near the top of the window
@(private = "file") ON_THE_PAGE :: [2]f32{500, 400}
@(private = "file") WHEEL_UP :: [2]f32{0, -1}

@(private = "file")
zoom_of :: proc(w: ^Chrome_World) -> f64 { return config.float_of(&w.app.prefs, ZOOM_PREF) }

@(private = "file")
page_height :: proc(w: ^Chrome_World) -> f32 { return w.wnd.page_rect.max.y - w.wnd.page_rect.min.y }

@(test)
chrome_zoom_follows_the_keyboard_and_the_pointer :: proc(t: ^testing.T) {
	w := chrome_start(t, {size = ZOOM_SIZE})
	chrome_still(w)
	h0 := page_height(w)
	testing.expect(t, h0 > 0, "the chrome leaves the page an area")

	session.key(w.s, .Equal, {.Ctrl})
	testing.expect_value(t, zoom_of(w), 1)   // nothing of the interface has the keyboard: the key is the page's

	session.click(w.s, "address")
	session.key(w.s, .Equal, {.Ctrl}, repeat = 3)
	chrome_still(w)
	testing.expectf(t, abs(zoom_of(w) - (1 + 3 * KEY_STEP)) < ZOOM_WITHIN, "the keys zoom the interface while it has the keyboard: %v", zoom_of(w))
	testing.expectf(t, page_height(w) < h0, "and it leaves the page less height: %v, was %v", page_height(w), h0)
	session.key(w.s, .N0, {.Ctrl})
	chrome_still(w)
	testing.expect_value(t, zoom_of(w), 1)
	testing.expect_value(t, page_height(w), h0)

	session.wheel(w.s, ON_THE_TOOLBAR, WHEEL_UP, {.Ctrl})
	chrome_still(w)
	testing.expectf(t, zoom_of(w) > 1, "Ctrl+wheel over the toolbar zooms it: %v", zoom_of(w))
	session.wheel(w.s, ON_THE_TOOLBAR, -WHEEL_UP, {.Ctrl})
	chrome_still(w)
	testing.expect_value(t, zoom_of(w), 1)

	session.wheel(w.s, ON_THE_PAGE, WHEEL_UP, {.Ctrl})
	chrome_still(w)
	testing.expect_value(t, zoom_of(w), 1)   // over the page: the page's
}

// Docked, the developer tools' panel has the size the preference gives it, and the page's area shrinks by the same amount, at the side and at the bottom. (The panel once ignored its size:
// it shared the room half and half with the page, whatever the splitter did.)
@(private = "file")
docked_panel_sizes :: proc(t: ^testing.T, dock: string, sizes: []int, along: int, loc := #caller_location) {
	FIRST_SIZE :: 150
	SIZE_PREF :: "browser.devtools.size"
	SCALE :: f32(168.0 / 96)
	SIZE_WITHIN :: 4 * SCALE      // the splitter, a rounding
	w := chrome_start(t, {size = {1280, 800}, scale = SCALE, prefs = {"browser.devtools.visible=true", "browser.devtools.tab=console", fmt.tprintf("browser.devtools.dock=%s", dock), fmt.tprintf("%s=%d", SIZE_PREF, FIRST_SIZE)}}, loc)
	chrome_still(w, loc)
	room :: proc(w: ^Chrome_World, along: int) -> f32 { return w.wnd.page_rect.max[along] - w.wnd.page_rect.min[along] }
	whole := room(w, along) + FIRST_SIZE * SCALE
	for size in sizes {
		chrome_pref(w, SIZE_PREF, fmt.tprintf("%d", size), loc)
		chrome_still(w, loc)
		want := whole - f32(size) * SCALE
		testing.expectf(t, abs(room(w, along) - want) <= SIZE_WITHIN, "a panel of %d: the page has %v, not %v", size, room(w, along), want, loc = loc)
	}
}

@(test)
chrome_docked_panel_has_its_size_at_the_side :: proc(t: ^testing.T) { docked_panel_sizes(t, "right", {220, 365, 160}, 0) }

@(test)
chrome_docked_panel_has_its_size_at_the_bottom :: proc(t: ^testing.T) { docked_panel_sizes(t, "bottom", {135, 210, 115}, 1) }

// The main menu that reaches the window's edge: where it is drawn, the window answers the system's hit test (WM_NCHITTEST) with "client", not a resize band: the band's diagonal cursor
// showed over the menu, and the pointer's moves never reached it, so the lit row stayed where the pointer had been. Beside the menu, the band is still there. (The window procedure's
// own answer on a real window: real_window.odin.)
@(test)
chrome_open_menu_over_the_resize_band :: proc(t: ^testing.T) {
	// the tabs in a sidebar: the menu button is in the integrated title bar, near the window's right end
	SIZE :: [2]int{1280, 500}     // lower than the menu, which starts at the window's top
	IN_THE_TOP_BAND :: 2          // px
	FROM_THE_RIGHT_END :: 4       // px: the band's corner
	FROM_THE_RIGHT_IN_THE_MENU :: 100
	w := chrome_start(t, {size = SIZE, prefs = {"browser.tabs.position=left"}})
	chrome_still(w)
	width := f32(SIZE.x)
	corner := [2]f32{width - FROM_THE_RIGHT_END, IN_THE_TOP_BAND}
	band := [2]f32{width - FROM_THE_RIGHT_IN_THE_MENU, IN_THE_TOP_BAND}
	beside := [2]f32{width / 2, IN_THE_TOP_BAND}
	hit :: proc(w: ^Chrome_World, at: [2]f32) -> platform.Hit { return browser.control_hit_test(w.app, at) }

	testing.expect_value(t, hit(w, beside), platform.Hit.Top)          // no menu: the top band resizes
	testing.expect_value(t, hit(w, band), platform.Hit.Top)
	testing.expect_value(t, hit(w, corner), platform.Hit.Top_Right)    // its right end is the corner

	chrome_command(w, "browser.main_menu")
	session.frames(w.s, 2)
	testing.expect(t, ui.ctx_menu_any_open(), "the menu is open")
	chrome_still(w)
	testing.expect_value(t, hit(w, corner), platform.Hit.Client)       // the open menu over the band and its corner is the browser's
	testing.expect_value(t, hit(w, band), platform.Hit.Client)
	testing.expect_value(t, hit(w, beside), platform.Hit.Top)          // beside the menu the band still resizes
}

// Every theme of the interface paints the window from its own palette: in a real frame, on the offscreen renderer.
@(test)
chrome_themes_paint_from_their_palettes :: proc(t: ^testing.T) {
	THEMES := []string{"Midnight", "Daylight", "Graphite"}
	BRIGHT :: 128 * 3   // the sum of a pixel's channels: above it, a light theme's
	w := chrome_start(t, {pixels = true})
	seen := make(map[[3]u8]string, len(THEMES), context.temp_allocator)
	for name in THEMES {
		pal, known := ui.palette_named(name)
		testing.expectf(t, known, "a theme of the interface: %s", name)
		delete(w.app.cfg.ui_theme)
		w.app.cfg.ui_theme = strings.clone(name)   // (what a change of browser.ui.theme does)
		session.frames(w.s, THEME_SETTLES)
		img := session.capture(w.s)
		c := session.pixel(img, img.width / 2, img.height - STATUS_BAR_INSIDE)
		colour := [3]u8{c.r, c.g, c.b}
		other, twice := seen[colour]
		testing.expectf(t, !twice, "%s draws as %s does: %v", name, other, colour)
		seen[colour] = name
		testing.expectf(t, (int(c.r) + int(c.g) + int(c.b) > BRIGHT) != pal.dark, "%s, its window's colour: %v", name, colour)
	}
}
@(private = "file") THEME_SETTLES :: 30      // frames: a palette's colours cross-fade
@(private = "file") STATUS_BAR_INSIDE :: 6   // px from the bottom: in the status bar, away from its text

@(private = "file") ROW_ID :: 1
@(private = "file") ROW_URL :: "https://files.test/report.pdf"
@(private = "file") ROW_NAME :: "report.pdf"
@(private = "file") ROW_BOX :: "dlr_1"   // the row of ROW_ID (dl_row)

// The toolbar's downloads drop-down: a right click on a row opens the row's menu over the drop-down, which stays open behind it (the menu once
// replaced the drop-down: a right click closed it). A press beside the row's menu, still on the drop-down, closes only the menu; Escape too.
@(test)
chrome_downloads_row_menu_over_the_panel :: proc(t: ^testing.T) {
	w := chrome_start(t)
	// a download of this session that failed: the button shows, its row has a menu
	d := new(browser.Download)
	d^ = {app = w.app, id = ROW_ID, url = strings.clone(ROW_URL), name = strings.clone(ROW_NAME), state = .Failed}
	append(&w.app.dls.list, d)
	testing.cleanup(t, proc(p: rawptr) { browser.downloads_shutdown((^browser.App)(p)) }, w.app)   // (before chrome_end)
	session.frames(w.s, 2)

	session.click(w.s, "downloads_icon")
	chrome_still(w)
	testing.expect_value(t, ui.menu_depth(), 1)
	row := session.get(w.s, ROW_BOX)
	session.click_at(w.s, session.center(row), .Right)
	chrome_still(w)
	testing.expect_value(t, ui.menu_depth(), 2)
	testing.expect(t, session.find_text(w.s, "Remove from the list") != nil, "the row's menu shows its items")

	// a press on the drop-down's title, beside the row's menu: the menu closes, the drop-down stays
	session.click_at(w.s, session.center(session.get(w.s, "dlp_title")))
	chrome_still(w)
	testing.expect_value(t, ui.menu_depth(), 1)

	// Escape closes the row's menu only
	session.click_at(w.s, session.center(row), .Right)
	chrome_still(w)
	testing.expect_value(t, ui.menu_depth(), 2)
	session.key(w.s, .Escape)
	chrome_still(w)
	testing.expect_value(t, ui.menu_depth(), 1)

	// an item does what it says and closes both
	session.click_at(w.s, session.center(row), .Right)
	chrome_still(w)
	session.click_text(w.s, "Remove from the list")
	chrome_still(w)
	testing.expect_value(t, len(w.app.dls.list), 0)
	testing.expect(t, !ui.ctx_menu_any_open(), "choosing closes the menu and the drop-down")
}
