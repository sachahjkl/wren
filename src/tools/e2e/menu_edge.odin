package e2e_scenarios

// The main menu that reaches the window's edge: where it is drawn, the window answers the system's hit test (WM_NCHITTEST) with "client", not a resize band:
// the band's diagonal cursor showed over the menu, and the pointer's moves never reached it, so the lit row stayed where the pointer had been. Beside the
// menu, the band is still there. The window procedure's own answer on a real window: real_window.odin.

import "core:testing"
import "wb:e2e"

@(private = "file") MENU_EDGE_SIZE :: [2]int{1280, 500}   // lower than the menu, which starts at the window's top
@(private = "file") IN_THE_TOP_BAND :: 2                  // px
@(private = "file") FROM_THE_RIGHT_END :: 4               // px: the band's corner
@(private = "file") FROM_THE_RIGHT_IN_THE_MENU :: 100     // px: under the menu, away from the corner

@(test)
open_menu_over_the_resize_band :: proc(t: ^testing.T) {
	// the tabs in a sidebar: the menu button is in the integrated title bar, near the window's right end
	s := e2e.start(t, {size = MENU_EDGE_SIZE, prefs = {"browser.tabs.position=left"}})
	e2e.wait_chrome_still(s)
	w := f64(MENU_EDGE_SIZE.x)
	corner := e2e.Point{w - FROM_THE_RIGHT_END, IN_THE_TOP_BAND}
	band := e2e.Point{w - FROM_THE_RIGHT_IN_THE_MENU, IN_THE_TOP_BAND}
	beside := e2e.Point{w / 2, IN_THE_TOP_BAND}

	testing.expect_value(t, e2e.hit_test(s, beside), e2e.Hit.Top)          // no menu: the top band resizes
	testing.expect_value(t, e2e.hit_test(s, band), e2e.Hit.Top)
	testing.expect_value(t, e2e.hit_test(s, corner), e2e.Hit.Top_Right)    // its right end is the corner

	e2e.run_command(s, "browser.main_menu")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).menu_open }, "the menu to open")
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.hit_test(s, corner), e2e.Hit.Client)       // the open menu over the band and its corner is the browser's
	testing.expect_value(t, e2e.hit_test(s, band), e2e.Hit.Client)
	testing.expect_value(t, e2e.hit_test(s, beside), e2e.Hit.Top)          // beside the menu the band still resizes
}
