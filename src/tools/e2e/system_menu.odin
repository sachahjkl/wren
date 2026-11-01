#+build windows
package e2e_scenarios

// The system menu of the Wren icon (integrated title bar, window_chrome.odin): a click opens it, its loop runs, and the frames it makes come through the
// frame gate. It used to be opened during the build: its loop (TrackPopupMenu) painted the window from WM_PAINT, that frame was built inside the one being
// built, and the outer build went on with an empty parent stack (the crash of the 2026-10-26 experimental build). Now the menu opens after the frame
// (windows.odin). TrackPopupMenu is the system's own loop: a window that exists and is never shown, the click through Wren's own input, the menu's end
// a message posted to it, nothing of the machine's mouse or keyboard. A desktop of its own (test_all's, or tools\test_desktop.ps1): the menu is a real window.

import "core:fmt"
import win "core:sys/windows"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") ROUNDS :: 3
@(private = "file") WINDOW := [2]int{1000, 700}
// The icon, at a scale of 1: 16 px at x 10..26, in the middle of a title bar of 32 px or more, in both places of the tabs.
@(private = "file") ICON := api.Point{18, 17}
@(private = "file") CLASS_BUFFER :: 64
// What the click's answer may take: it comes when the menu has closed.
@(private = "file") CLICK_ANSWER_MS :: 30_000
// What a frame made from WM_PAINT may take.
@(private = "file") PAINT_ANSWER_MS :: 30_000
// The lParam of a key that goes down once.
@(private = "file") KEY_DOWN_ONCE :: 1
@(private = "file") SMTO_NORMAL :: 0

// A visible menu of this process (nil: none).
@(private = "file")
menu_of :: proc(pid: int) -> win.HWND {
	Find :: struct { pid: win.DWORD, menu: win.HWND }
	f := Find{pid = win.DWORD(pid)}
	win.EnumWindows(proc "system" (h: win.HWND, l: win.LPARAM) -> win.BOOL {
		f := (^Find)(rawptr(uintptr(l)))
		owner: win.DWORD
		win.GetWindowThreadProcessId(h, &owner)
		if owner != f.pid || !win.IsWindowVisible(h) { return true }
		class: [CLASS_BUFFER]u16
		n := win.GetClassNameW(h, &class[0], CLASS_BUFFER)
		want := []u16{'#', '3', '2', '7', '6', '8'}   // (the class of a menu)
		if int(n) != len(want) { return true }
		for c, i in want { if class[i] != c { return true } }
		f.menu = h
		return false
	}, win.LPARAM(uintptr(&f)))
	return f.menu
}

// One position of the tabs: `rounds` clicks, each a menu, its loop, its end.
@(private = "file")
rounds_with_the_tabs :: proc(t: ^testing.T, position: string) {
	profile := e2e.temp_profile(t)
	p := e2e.launch(t, {hidden = true, dpi = e2e.DPI_ONE, profile = profile, prefs = {"browser.window.integrated_titlebar=true", fmt.tprintf("browser.tabs.position=%s", position)}})
	api.set_window(p.s, {size = WINDOW})
	who, _ := api.ping(p.s)
	api.wait_frames(p.s)
	list, _ := api.windows(p.s)
	hwnd := win.HWND(uintptr(list[0].hwnd))
	for round in 1 ..= ROUNDS {
		before, _ := api.stats(p.s)
		// (the answer needs frames the menu's loop makes, or its end: another connection, that this one does not wait for)
		clicker: api.Conn
		testing.expect(t, api.connect(&clicker, p.wren.name, api.START_WAIT_MS))
		defer api.disconnect(&clicker)
		testing.expect_value(t, api.write_line(&clicker, fmt.tprintf(`{{"id":1,"method":"Wren.click","params":{{"button":"left","count":1,"x":%v,"y":%v,"space":"window"}}}}`, ICON.x, ICON.y), CLICK_ANSWER_MS), api.Error.None)
		e2e.wait_for(t, who.pid, proc(pid: int) -> bool { return menu_of(pid) != nil }, fmt.tprintf("the system menu, %s, round %d", position, round))
		// a frame made inside the menu's loop, from the window's own message: answered when it is done, what the crash was
		painted: win.DWORD_PTR
		testing.expect(t, win.SendMessageTimeoutW(hwnd, win.WM_PAINT, 0, 0, SMTO_NORMAL, PAINT_ANSWER_MS, &painted) != 0, "the window paints inside the menu's loop")
		win.PostMessageW(hwnd, win.WM_KEYDOWN, win.WPARAM(win.VK_ESCAPE), KEY_DOWN_ONCE)
		e2e.wait_for(t, who.pid, proc(pid: int) -> bool { return menu_of(pid) == nil }, fmt.tprintf("the menu to close, %s, round %d", position, round))
		// and the process goes on: this answer comes from its own loop, and says what the menu's did
		after, _ := api.stats(p.s)
		testing.expectf(t, after.modal_loops > before.modal_loops, "%s, round %d: the menu's loop was the system's, in this process: %d, then %d", position, round, before.modal_loops, after.modal_loops)
		testing.expectf(t, after.frame_gate.violations == 0, "%s, round %d: no frame where none may begin: %s", position, round, after.frame_gate.last_violation)
		testing.expectf(t, after.paint_frames > before.paint_frames, "%s, round %d: a frame was made in it: %d, then %d", position, round, before.paint_frames, after.paint_frames)
		testing.expect_value(t, len(e2e.files_with_prefix(fmt.tprintf("%s/crashes", profile), "crash ")), 0)
	}
	testing.expect_value(t, e2e.quit(p), 0)
}

@(test)
the_system_menu_with_the_tabs_on_top :: proc(t: ^testing.T) { rounds_with_the_tabs(t, "top") }

@(test)
the_system_menu_with_the_tabs_in_a_sidebar :: proc(t: ^testing.T) { rounds_with_the_tabs(t, "left") }
