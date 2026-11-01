package e2e_scenarios

// The chrome's state of a window lives in the window (windows.odin Window_Own): a page's element full screen in one window while a second
// window exists (each has its own), left with Escape, the scroll given back; the tab moved between the windows. Then the developer tools
// of each window (devtools.odin: Window_Own.devtools): opened in one window only, one docked and one in a window of its own, going with the
// tab they show to a new window, closed with their window. The caret blinks in the window the user is in only. The process answers and
// leaves no crash report; the dev build panics on a frame that moves where it may not (the frame gate).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") WINDOW_STATE_PAGE :: `<!doctype html><body style="margin:0"><div style="height:3000px"><button id=b style="position:fixed;left:20px;top:20px;width:120px;height:40px">full</button><div id=v style="position:absolute;left:0;top:200px;width:300px;height:150px;background:#08f"></div></div><script>b.onclick=()=>v.requestFullscreen().then(()=>document.title="fs on",()=>document.title="fs refused");document.onfullscreenchange=()=>{if(!document.fullscreenElement)document.title="fs off"}</script>`
@(private = "file") WINDOW_STATE_SIZE :: [2]int{1000, 700}
@(private = "file") WINDOW_STATE_DPI :: 96
@(private = "file") SCROLLED_TO :: 120
@(private = "file") FS_STATE :: `document.title + "|" + (document.fullscreenElement ? document.fullscreenElement.id : "none")`
// How many times the caret of the front window turns on or off while the one behind is watched: enough for it to have shown, had it been going to (two blink periods).
@(private = "file") CARET_TURNS :: 4
@(private = "file") CARET_BLINK_PREF :: "forms.caret.blink_ms=40"   // (what blinks does not wait for the system's half second)

// A window's own window list entry; the test ends if it has gone.
@(private = "file")
win :: proc(t: ^testing.T, s: ^e2e.Session, id: int, loc := #caller_location) -> e2e.Window {
	w, ok := e2e.window_with_id(e2e.windows(s), id)
	if !ok { testing.fail_now(t, fmt.tprintf("no window %d", id), loc) }
	return w
}

// The front window's caret blinks and the one behind shows none and keeps no timer: looked at until the front one has turned CARET_TURNS times.
@(private = "file")
Caret_Watch :: struct {
	front, back: int,
	turns:       int,
	last:        bool,
	back_shown, back_timer, front_stopped: int,
}

@(private = "file")
caret_blinks_only_in_front :: proc(t: ^testing.T, s: ^e2e.Session, front, back: int) {
	{
		e2e.in_window(s, front)
		e2e.bring_to_front(s)
	}
	// the window behind stops its timer on one of its own frames, the window in front starts its own on one of its
	e2e.wait_until(s, back, proc(s: ^e2e.Session, back: int) -> bool {
		e2e.in_window(s, back)
		st := e2e.stats(s)
		return !st.caret_blinking && !st.caret_shown
	}, "the window behind to stop its caret")
	e2e.wait_until(s, front, proc(s: ^e2e.Session, front: int) -> bool {
		e2e.in_window(s, front)
		st := e2e.stats(s)
		return st.caret_blinking && st.front_window
	}, "the window in front to start its caret")
	w := Caret_Watch{front = front, back = back}
	e2e.wait_until(s, &w, proc(s: ^e2e.Session, w: ^Caret_Watch) -> bool {
		f, b: e2e.Stats
		{ e2e.in_window(s, w.front); f = e2e.stats(s) }
		{ e2e.in_window(s, w.back); b = e2e.stats(s) }
		if !f.caret_blinking || !f.front_window { w.front_stopped += 1 }
		if b.caret_shown { w.back_shown += 1 }
		if b.caret_blinking { w.back_timer += 1 }
		if f.caret_shown != w.last { w.turns += 1; w.last = f.caret_shown }
		return w.turns >= CARET_TURNS
	}, "the caret of the window in front to blink")
	testing.expectf(t, w.front_stopped == 0 && w.back_shown == 0 && w.back_timer == 0, "window %d in front: its field's caret blinks, window %d shows none and keeps no timer: front stopped %d, back shown %d, back timer %d", front, back, w.front_stopped, w.back_shown, w.back_timer)
}

@(test)
window_state_end_to_end :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	// (a page of a file: a typed data: address is not a document that may ask for full screen here)
	page := e2e.file_page(dir, "page.html", WINDOW_STATE_PAGE)
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {size = WINDOW_STATE_SIZE, dpi = WINDOW_STATE_DPI, profile = profile, url = page, prefs = {CARET_BLINK_PREF}})
	e2e.eval(s, fmt.tprintf("scrollTo(0, %d); 'ok'", SCROLLED_TO))
	e2e.click(s, "#b")
	// (the change's events wait for the page laid out at the new size)
	e2e.wait_js(s, `document.title != ""`)
	testing.expect_value(t, e2e.eval(s, FS_STATE), "fs on|v")   // a click asks the element's full screen: granted

	// a second window, then back: the first window's full screen is still its own
	first := e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	testing.expect_value(t, len(wins), 2)   // a second window opens (window.new)
	second := wins[0].id != first ? wins[0].id : wins[1].id
	{
		e2e.in_window(s, first)
		testing.expect_value(t, e2e.eval(s, FS_STATE), "fs on|v")   // the first window's page is still in full screen
		e2e.key(s, "Escape")
		e2e.wait_js(s, fmt.tprintf(`document.title == "fs off" && Math.round(scrollY) == %d`, SCROLLED_TO))
		testing.expect_value(t, e2e.eval(s, fmt.tprintf(`document.title + "|" + (document.fullscreenElement ? "still" : "none") + "|" + Math.round(scrollY)`)), fmt.tprintf("fs off|none|%d", SCROLLED_TO))   // Escape in that window leaves it, and the scroll comes back
	}

	// the developer tools: each window has its own, docked or in a window of their own; they go with the tab they show to another window, and close with their window
	{ e2e.in_window(s, second); e2e.navigate(s, page) }
	{ e2e.in_window(s, first); e2e.open_devtools(s, "console") }
	testing.expect(t, win(t, s, first).devtools.visible && !win(t, s, second).devtools.visible, "the developer tools open in the window that asked for them, not in the other")
	{ e2e.in_window(s, second); e2e.open_devtools(s, "network", "window") }
	dt1, dt2 := win(t, s, first).devtools, win(t, s, second).devtools
	testing.expect(t, dt2.visible && dt2.detached && dt2.has_window && dt2.panel == "network" && dt1.visible && !dt1.detached && dt1.panel == "console", "the second window's developer tools go to a window of their own on Network; the first window's stay docked on Console")
	testing.expect_value(t, e2e.stats(s).devtools_windows, 1)   // their window exists

	// a tab of the first window with its developer tools on it goes to a window of its own: they go with it
	tid: int
	{
		e2e.in_window(s, first)
		tid = e2e.new_tab(s, page)
		e2e.wait_load(s)
	}
	third := e2e.move_tab_to_new_window(s, tid)
	{ e2e.in_window(s, third); e2e.wait_frames(s) }
	testing.expect(t, win(t, s, third).devtools.visible && win(t, s, third).devtools.panel == "console" && !win(t, s, first).devtools.visible, "the developer tools go with the tab they showed to its new window; the window it left has none open")

	// the second window closes (its last tab): its developer tools' window closes with it
	e2e.close_tab(s, win(t, s, second).current_tab)
	{ e2e.in_window(s, first); e2e.wait_frames(s) }
	_, still := e2e.window_with_id(e2e.windows(s), second)
	testing.expect(t, !still, "the second window is gone")
	testing.expect_value(t, e2e.stats(s).devtools_windows, 0)   // closing a window closes its developer tools' window
	{
		e2e.in_window(s, third)
		testing.expect(t, e2e.stats(s).devtools, "the stats of a window name its own developer tools")
	}

	// the caret of a focused field of a page blinks only in the window the user is in, on a timer of that window
	for id in ([]int{first, third}) {
		e2e.in_window(s, id)
		e2e.eval(s, "document.body.insertAdjacentHTML('beforeend','<input id=fld style=position:fixed;left:200px;top:20px>'); fld.focus(); 'ok'")
	}
	caret_blinks_only_in_front(t, s, third, first)
	caret_blinks_only_in_front(t, s, first, third)

	files, _ := os.read_all_directory_by_path(fmt.tprintf("%s/crashes", profile), context.temp_allocator)
	for f in files { testing.expectf(t, !strings.has_prefix(f.name, "crash "), "no crash report: %s", f.name) }
	testing.expect_value(t, e2e.stats(s).frame_gate.violations, 0)   // no violation of the frame gate
}
