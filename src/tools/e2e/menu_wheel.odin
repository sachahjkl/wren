package e2e_scenarios

// A wheel over an open menu is the menu's (hud_captures, the toolkit's menu_at): the main menu, as tall as a window lower than it and scrolled, scrolls under the wheel, and the page
// under it stays where it is, down and across. Closed, the same wheel at the same point scrolls the page. (The page scrolled with the menu: route_page_input gave it every wheel in
// its area.)

import "core:fmt"
import "core:testing"
import "toolkit:draw"
import "toolkit:ui"
import "wb:browser"
import "wb:e2e"

@(private = "file") PAGE :: `<!doctype html><style>body{margin:0} #big{width:4000px;height:4000px}</style><div id=big></div>`
@(private = "file") SIZE :: [2]int{1280, 500}   // lower than the main menu
@(private = "file") NOTCHES :: 3

@(test)
menu_takes_the_wheel_over_the_page :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	e2e.eval(s, fmt.tprintf("document.open(); document.write(%q); document.close(); 1", PAGE))
	e2e.run_command(s, "browser.main_menu")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).menu_open }, "the menu to open")
	e2e.wait_chrome_still(s)
	wnd := browser.active_window(s.app)
	ui.use(wnd.ui)
	menu, _, ok := ui.menu_rect(0)
	testing.expect(t, ok, "the menu is laid out")
	first, _ := ui.menu_item_rect(0, 0)
	mid := (menu.min + menu.max) / 2
	testing.expectf(t, draw.rect_contains(wnd.page_rect, mid), "the menu is over the page: %v, %v", menu, wnd.page_rect)
	at := e2e.Point{f64(mid.x), f64(mid.y)}

	e2e.scroll(s, NOTCHES, at, .Window)
	e2e.scroll(s, 0, at, .Window, across = NOTCHES)
	e2e.wait_at_rest(s)
	ui.use(wnd.ui)
	moved, _ := ui.menu_item_rect(0, 0)
	testing.expectf(t, moved.min.y < first.min.y, "the wheel scrolls the menu: %v -> %v", first.min.y, moved.min.y)
	testing.expect_value(t, e2e.eval(s, "scrollY + ',' + scrollX"), "0,0")

	e2e.key(s, "Escape")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return !e2e.stats(s).menu_open }, "the menu to close")
	e2e.scroll(s, NOTCHES, at, .Window)
	e2e.scroll(s, 0, at, .Window, across = NOTCHES)
	e2e.wait_js(s, "scrollY > 0 && scrollX > 0")
}
