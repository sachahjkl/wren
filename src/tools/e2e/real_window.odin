#+build windows
package e2e_scenarios

// The small core on a real window of the system, never shown, with its swap chain: what the headless scenarios do not go through. The browser runs in this process, so the
// window procedure is called as the system calls it, on this thread: WM_DPICHANGED and the rectangle it suggests, WM_NCHITTEST, WM_SETCURSOR; the system's z-order of windows
// for a drop; the swap chain frames are presented to. It needs a desktop session (test_all's own, wrentool desktop by hand).

import "core:fmt"
import "core:math"
import "core:strings"
import win "core:sys/windows"
import "core:testing"
import "wb:e2e"

foreign import user32 "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32 {
	GetIconInfo :: proc(icon: win.HICON, info: ^win.ICONINFO) -> win.BOOL ---
}

@(private = "file") REAL_SIZE :: [2]int{1000, 700}
@(private = "file") OTHER_MONITOR :: 1.5               // relative to where the window is
@(private = "file") ALSO_ABOVE :: 1.25                 // ... relative to that: both are above the page's threshold
@(private = "file") THRESHOLD_FROM_BASE :: 1.25        // the page's threshold, relative to where the window is
@(private = "file") SCROLLED_TOP :: 1200
@(private = "file") PARAGRAPHS :: 120
@(private = "file") SCALE_WITHIN :: 0.02
@(private = "file") SIZE_WITHIN :: 0.03                // of the proportion
@(private = "file") LATE_EVENTS_FRAMES :: 6            // a second change event would have come by then
@(private = "file") PAGE_COLOR_POINT :: 10             // px from the page's corner

@(private = "file")
dpi_page :: proc(threshold: f64) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<!doctype html><title>dpi</title><style>body{{margin:0}}</style>")
	for i in 1 ..= PARAGRAPHS { fmt.sbprintf(&b, "<p style='margin:0;height:40px;font:16px sans-serif'>paragraph %d</p>", i) }
	fmt.sbprintf(&b, "<script>window.changes=0;window.mq=matchMedia('(min-resolution: %.3fdppx)');mq.addEventListener('change',()=>window.changes++)</script>", threshold)
	return strings.to_string(b)
}

@(private = "file")
expect_never_shown :: proc(t: ^testing.T, s: ^e2e.Session, loc := #caller_location) {
	for w in e2e.windows(s, loc) {
		testing.expectf(t, w.hwnd != 0 && !w.headless, "window %d is a window of the system", w.id, loc = loc)
		testing.expectf(t, !bool(win.IsWindowVisible(win.HWND(uintptr(w.hwnd)))), "window %d was shown", w.id, loc = loc)
	}
}

@(private = "file")
client_size :: proc(h: win.HWND) -> [2]int {
	r: win.RECT
	win.GetClientRect(h, &r)
	return {int(r.right - r.left), int(r.bottom - r.top)}
}

// The window goes to a monitor of this scale, by the system's message; its page has followed, and what would follow late has had its frames.
@(private = "file")
to_scale :: proc(s: ^e2e.Session, scale: f64, loc := #caller_location) {
	e2e.set_window(s, {dpi = int(math.round(e2e.DPI_ONE * scale))}, loc)
	e2e.wait_js(s, fmt.tprintf("Math.abs(devicePixelRatio - %v) < %v", scale, SCALE_WITHIN), loc = loc)
	e2e.wait_frames(s, LATE_EVENTS_FRAMES, loc = loc)
}

// A caret's toggle on a swap chain: frames_at_rest.odin.
@(test)
real_window_caret_draws_its_own_pixels :: proc(t: ^testing.T) { caret_draws_its_own_pixels(t, hidden = true) }

// WM_DPICHANGED through the window procedure, with the rectangle the system suggests: the scale, the real window's size, the swap chain's picture, the page and its media query.
@(test)
real_window_changes_monitor :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = REAL_SIZE, hidden = true})
	h := hwnd_of(s)
	base := e2e.window_bounds(s).dpi_scale
	testing.expect(t, base > 0 && !e2e.window_bounds(s).headless, "a real window, with its monitor's scale")
	e2e.navigate(s, e2e.file_page(e2e.temp_folder(t), "dpi.html", dpi_page(base * THRESHOLD_FROM_BASE)))
	expect_never_shown(t, s)
	e2e.eval(s, fmt.tprintf("scrollTo(0, %d); 'ok'", SCROLLED_TOP))
	e2e.wait_js(s, fmt.tprintf("Math.round(scrollY) == %d", SCROLLED_TOP))
	size0 := client_size(h)
	width0 := e2e.eval_f64(s, "innerWidth")

	// the threshold crossed: one change event
	to_scale(s, base * OTHER_MONITOR)
	b := e2e.window_bounds(s)
	testing.expectf(t, math.abs(b.dpi_scale / base - OTHER_MONITOR) < SCALE_WITHIN && math.abs(b.ui_scale - b.dpi_scale) < SCALE_WITHIN && math.abs(b.page_scale - b.dpi_scale) < SCALE_WITHIN, "the new scale, its chrome and its page: dpi %v, ui %v, page %v", b.dpi_scale, b.ui_scale, b.page_scale)
	size1 := client_size(h)
	testing.expectf(t, math.abs(f64(size1.x) / f64(size0.x) - OTHER_MONITOR) < SIZE_WITHIN && math.abs(f64(size1.y) / f64(size0.y) - OTHER_MONITOR) < SIZE_WITHIN, "the window has the rectangle the system suggests: %v -> %v", size0, size1)
	testing.expect_value(t, [2]int{b.width, b.height}, size1)   // the browser took the size the system gave
	testing.expect_value(t, e2e.eval_f64(s, "Math.round(scrollY)"), f64(SCROLLED_TOP))   // no jump
	width1 := e2e.eval_f64(s, "innerWidth")
	testing.expectf(t, math.abs(width1 - width0) <= width0 * SIZE_WITHIN, "the viewport keeps its CSS width: %v -> %v", width0, width1)
	testing.expect_value(t, e2e.eval(s, "String(changes)"), "1")
	testing.expect_value(t, e2e.eval(s, "String(mq.matches)"), "true")

	// the picture of the swap chain has the new size
	shot := e2e.capture(s)
	testing.expect_value(t, [2]int{shot.width, shot.height}, size1)

	// another monitor still above the threshold: both match, no event; back below it: one
	to_scale(s, base * OTHER_MONITOR * ALSO_ABOVE)
	testing.expect_value(t, e2e.eval(s, "String(changes)"), "1")
	to_scale(s, base)
	testing.expect_value(t, e2e.eval(s, "String(changes)"), "2")
	testing.expect_value(t, e2e.stats(s).frame_gate.violations, 0)
	expect_never_shown(t, s)
}

// A tab dropped where two windows overlap goes to the one the system says is on top, whichever that is. (The system moves a window never shown under another, not to the top.)
@(test)
real_window_drop_on_the_topmost :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	page :: proc(dir, title: string) -> string { return e2e.file_page(dir, fmt.tprintf("%s.html", title), fmt.tprintf("<!doctype html><meta charset=utf-8><title>%s</title><body>%s", title, title)) }
	s := e2e.start(t, {size = REAL_SIZE, hidden = true, url = page(dir, "Source"), prefs = {"appearance.animations=off"}})
	a := e2e.windows(s)[0].id
	for title in ([]string{"Carried", "Again"}) {
		s.tab = e2e.new_tab(s, page(dir, title))
		e2e.wait_load(s)
		s.tab = 0
	}
	new_window :: proc(s: ^e2e.Session, known: []int) -> int {
		e2e.run_command(s, "window.new")
		outer: for w in e2e.windows(s) {
			for k in known { if k == w.id { continue outer } }
			return w.id
		}
		return 0
	}
	b := new_window(s, {a})
	c := new_window(s, {a, b})
	// the two at the same place, beside the source
	at := [2]int{REAL_SIZE.x + OVERLAP_GAP, 0}
	{ e2e.in_window(s, b); e2e.navigate(s, page(dir, "Under")); e2e.set_window(s, {size = REAL_SIZE, pos = at}) }
	{ e2e.in_window(s, c); e2e.navigate(s, page(dir, "Over")); e2e.set_window(s, {size = REAL_SIZE, pos = at}) }
	expect_never_shown(t, s)

	over_window :: proc(s: ^e2e.Session, window: int, title: string) -> e2e.Rect {
		e2e.in_window(s, window)
		e2e.wait_chrome_still(s)
		x := e2e.tab_titled(s, title)
		return x.rect
	}
	window_of :: proc(s: ^e2e.Session, id: int) -> e2e.Window { w, _ := e2e.window_with_id(e2e.windows(s), id); return w }
	drop_over :: proc(t: ^testing.T, s: ^e2e.Session, a, top, under: int, title, under_tab: string, loc := #caller_location) {
		win.SetWindowPos(win.HWND(uintptr(window_of(s, under).hwnd)), win.HWND(uintptr(window_of(s, top).hwnd)), 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
		tab_rect := over_window(s, top, under_tab)
		from_rect := over_window(s, a, title)
		fw, tw := window_of(s, a), window_of(s, top)
		from := e2e.center(from_rect)
		over := e2e.Point{f64(tw.client_left) + tab_rect.x + tab_rect.w / 2 - f64(fw.client_left), f64(tw.client_top) + tab_rect.y + tab_rect.h / 2 - f64(fw.client_top)}
		{
			e2e.in_window(s, a)
			e2e.drag(s, from, over, {via = {{from.x, from.y + FAR_BELOW}}, steps = DROP_MOVES, space = .Window, hold = true}, loc = loc)
		}
		{
			e2e.in_window(s, top)
			e2e.wait_until(s, top, proc(s: ^e2e.Session, top: int) -> bool { w, _ := e2e.window_with_id(e2e.windows(s), top); return w.dropping }, "the mark in the topmost window", loc = loc)
		}
		testing.expectf(t, !window_of(s, under).dropping, "the window under the topmost one shows no mark", loc = loc)
		{
			e2e.in_window(s, a)
			e2e.drag(s, over, over, {steps = 1, space = .Window, resume = true}, loc = loc)
		}
		e2e.wait_until(s, title, proc(s: ^e2e.Session, title: string) -> bool {
			for x in e2e.targets(s).tabs { if x.title == title { for w in e2e.windows(s) { if w.id == x.window { return !w.dropping && len(e2e.windows(s)) == WINDOWS_AT_REST } } } }
			return false
		}, "the drop", loc = loc)
		testing.expectf(t, e2e.tab_titled(s, title, loc).window == top, "%s went to the window on top, %d", title, top, loc = loc)
	}
	// c was made last, and is raised; then b is raised above it
	drop_over(t, s, a, c, b, "Carried", "Over")
	drop_over(t, s, a, b, c, "Again", "Under")
	expect_never_shown(t, s)
}
@(private = "file") OVERLAP_GAP :: 100         // px between the source and the two others
@(private = "file") FAR_BELOW :: 300           // px: the tab leaves its row
@(private = "file") DROP_MOVES :: 8
@(private = "file") WINDOWS_AT_REST :: 3

// The window procedure's answer to WM_NCHITTEST is the typed one's (control_hit_test: chrome_interface.odin), on a window with the system's frame.
@(test)
real_window_answers_the_hit_test :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = {1280, 500}, hidden = true, prefs = {"browser.tabs.position=left"}})
	h := hwnd_of(s)
	show_unseen(h)
	e2e.wait_chrome_still(s)
	HIT_CLIENT :: 1
	HIT_TOP :: 12
	HIT_TOP_RIGHT :: 14
	w := f64(client_size(h).x)
	answer :: proc(h: win.HWND, at: e2e.Point) -> int { return int(win.SendMessageW(h, win.WM_NCHITTEST, 0, screen_lparam(to_screen(h, at)))) }
	IN_THE_BAND :: 2
	FROM_THE_END :: 4
	testing.expect_value(t, answer(h, {w / 2, IN_THE_BAND}), HIT_TOP)
	testing.expect_value(t, answer(h, {w - FROM_THE_END, IN_THE_BAND}), HIT_TOP_RIGHT)
	testing.expect_value(t, e2e.hit_test(s, {w / 2, IN_THE_BAND}), e2e.Hit.Top)
	testing.expect_value(t, e2e.hit_test(s, {w - FROM_THE_END, IN_THE_BAND}), e2e.Hit.Top_Right)
	e2e.run_command(s, "browser.main_menu")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).menu_open }, "the menu to open")
	e2e.wait_chrome_still(s)
	testing.expect_value(t, answer(h, {w - FROM_THE_END, IN_THE_BAND}), HIT_CLIENT)   // the open menu is the browser's
	testing.expect_value(t, answer(h, {w / 2, IN_THE_BAND}), HIT_TOP)                 // beside it, the band
}

// What the system is given for what the page asked: the very cursor of the system, one drawn at the system's size, none, the image with its hotspot. No pointer moves: the
// message the system sends when it wants the cursor, and what the thread then has set.
@(test)
real_window_gives_the_system_its_cursor :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = {1400, 1000}, hidden = true, url = e2e.url(server, "/site/cursors.html")})
	h := hwnd_of(s)
	e2e.wait_chrome_still(s)
	HIT_CLIENT :: 1
	shown :: proc(s: ^e2e.Session, h: win.HWND, id: string, loc := #caller_location) -> win.HCURSOR {
		x := e2e.eval_f64(s, fmt.tprintf(`(e => {{ e.scrollIntoView({{block: "center"}}); return e.getBoundingClientRect().left + 8; }})(document.getElementById(%q))`, id), loc = loc)
		e2e.wait_frames(s, loc = loc)
		y := e2e.eval_f64(s, fmt.tprintf(`(r => r.top + r.height / 2)(document.getElementById(%q).getBoundingClientRect())`, id), loc = loc)
		e2e.hover(s, {x, y}, loc = loc)
		e2e.wait_idle(s, loc = loc)
		e2e.wait_frames(s, loc = loc)
		win.SendMessageW(h, win.WM_SETCURSOR, win.WPARAM(uintptr(h)), win.LPARAM(HIT_CLIENT | win.WM_MOUSEMOVE << 16))
		return win.GetCursor()
	}
	bitmap_size :: proc(c: win.HCURSOR) -> (size, hot: [2]int) {
		ii: win.ICONINFO
		if !GetIconInfo(win.HICON(c), &ii) { return }
		defer { if ii.hbmMask != nil { win.DeleteObject(win.HGDIOBJ(ii.hbmMask)) }; if ii.hbmColor != nil { win.DeleteObject(win.HGDIOBJ(ii.hbmColor)) } }
		bm: win.BITMAP
		win.GetObjectW(win.HANDLE(ii.hbmColor != nil ? ii.hbmColor : ii.hbmMask), size_of(bm), &bm)
		return {int(bm.bmWidth), int(ii.hbmColor != nil ? bm.bmHeight : bm.bmHeight / 2)}, {int(ii.xHotspot), int(ii.yHotspot)}
	}
	testing.expect_value(t, shown(s, h, "k-pointer"), win.LoadCursorA(nil, win.IDC_HAND))
	testing.expect_value(t, shown(s, h, "k-text"), win.LoadCursorA(nil, win.IDC_IBEAM))
	testing.expect_value(t, shown(s, h, "k-not-allowed"), win.LoadCursorA(nil, win.IDC_NO))
	testing.expect_value(t, shown(s, h, "k-none"), win.HCURSOR(nil))
	system_px := int(win.GetSystemMetricsForDpi(win.SM_CXCURSOR, win.GetDpiForWindow(h)))
	size, _ := bitmap_size(shown(s, h, "k-grab"))
	testing.expect_value(t, size, [2]int{system_px, system_px})   // drawn, at the system's size
	scale := e2e.window_bounds(s).page_scale
	px := int(math.round(IMAGE_CSS_PX * scale))
	image, hot := bitmap_size(shown(s, h, "png"))
	testing.expect_value(t, image, [2]int{px, px})
	testing.expectf(t, math.abs(f64(hot.x) - IMAGE_HOTSPOT * scale) <= HOTSPOT_WITHIN && math.abs(f64(hot.y) - IMAGE_HOTSPOT * scale) <= HOTSPOT_WITHIN, "the image's hotspot at its center: %v", hot)
}
@(private = "file") IMAGE_CSS_PX :: 32
@(private = "file") IMAGE_HOTSPOT :: 16
@(private = "file") HOTSPOT_WITHIN :: 1

// The swap chain: frames are presented to it, a capture reads its picture, and a real resize reaches both.
@(test)
real_window_presents_to_its_swap_chain :: proc(t: ^testing.T) {
	PAGE :: `<!doctype html><title>red</title><body style="margin:0;background:rgb(10,10,200)">`
	s := e2e.start(t, {size = REAL_SIZE, hidden = true})
	e2e.navigate(s, e2e.file_page(e2e.temp_folder(t), "red.html", PAGE))
	h := hwnd_of(s)
	before := e2e.stats(s)
	testing.expect(t, before.surface.buffers.x > 0, "a swap chain")
	// (something to show: a frame that changes nothing presents nothing, and a page that had settled by here was seen as frames not presented)
	e2e.eval(s, `document.body.style.background = "rgb(200,10,10)"; "ok"`)
	e2e.wait_frames(s, PRESENT_FRAMES)
	after := e2e.stats(s)
	testing.expectf(t, after.frames_presented > before.frames_presented, "frames are presented: %d -> %d", before.frames_presented, after.frames_presented)
	shot := e2e.capture(s, {target = .Page})
	c := e2e.pixel(shot, PAGE_COLOR_POINT, PAGE_COLOR_POINT)
	testing.expectf(t, c.r == 200 && c.g == 10 && c.b == 10, "the picture of the swap chain is the page's: %v", c)
	smaller := [2]int{REAL_SIZE.x - RESIZE_BY, REAL_SIZE.y - RESIZE_BY}
	e2e.set_window(s, {size = smaller})
	e2e.wait_until(s, smaller, proc(s: ^e2e.Session, want: [2]int) -> bool { return e2e.stats(s).surface.size == want }, "the surface to take the new size")
	testing.expect_value(t, client_size(h), smaller)
	window := e2e.capture(s)
	testing.expect_value(t, [2]int{window.width, window.height}, smaller)
	expect_never_shown(t, s)
}
@(private = "file") PRESENT_FRAMES :: 4
@(private = "file") RESIZE_BY :: 120
