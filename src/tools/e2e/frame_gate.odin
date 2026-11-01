#+build windows
package e2e_scenarios

// The frame gate (windows.odin, the toolkit's platform/frame_gate.odin: every frame of the thread through one state machine; a frame asked for where none may begin is
// deferred, never nested) on a real window, with no violation of the machine (a test build panics on one, and on a full frame under a chrome frame: page_world_check):
//   * a page's drag taken out of the window and back: the system's loop pumps the thread's messages and the window repaints between its steps; those paints are deferred;
//   * the page's context menu: a menu of the chrome, frames go on while it is open;
//   * a long script: the chrome preempts it, chrome frames inside the full frame's page phase. In one of their polls a loop of the system begins (a press on the window's border
//     does that: commit 7854835c), and paints: at a new size, there, a paint is a chrome frame and never a full one, which would run the page's world a second time under its
//     own script; and when the frame has gone on to its build, it is deferred. What holds the script is the state: it runs until the window has its new size.

import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "core:testing"
import "core:thread"
import "toolkit:platform"
import "wb:e2e"

@(private = "file") GATE_SIZE :: [2]int{1000, 700}
@(private = "file") RESIZED_SIZE :: [2]int{900, 620}
@(private = "file") RESIZED_AGAIN :: [2]int{860, 600}
@(private = "file") DRAG_STEPS :: 8
@(private = "file") DND_FROM :: e2e.Point{50, 30}
@(private = "file") DND_TO :: e2e.Point{100, 150}
@(private = "file") DND_OUT_1 :: e2e.Point{-300, 30}
@(private = "file") DND_OUT_2 :: e2e.Point{-300, 200}
@(private = "file") MENU_AT :: e2e.Point{200, 300}
@(private = "file") FRAMES_WHILE_OPEN :: 3
@(private = "file") SCRIPT_LIMIT_MS :: 30_000        // only ends a failing run: the script ends when the window has its new size
@(private = "file") POST_EVERY_MS :: 1               // the queue of a thread that a script holds has something in it: what makes a chrome frame poll
@(private = "file") WM_IN_THE_POLL :: win.WM_APP + 1

@(test)
frame_gate_drag_and_menu :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = GATE_SIZE, hidden = true, dpi = e2e.DPI_ONE, url = e2e.file_url(fmt.tprintf("%s/examples/dnd/dnd.html", e2e.repo_root()))})
	show_unseen(hwnd_of(s))   // (a repaint needs a window that is shown)
	e2e.wait_frames(s)

	// the system's drag of the page's drag: out of the window and back onto the zone
	before := e2e.stats(s)
	e2e.eval(s, "log.length = 0; 'ok'")
	e2e.drag(s, DND_FROM, DND_TO, {via = {DND_OUT_1, DND_OUT_2}, steps = DRAG_STEPS})
	e2e.wait_js(s, "log.join(' | ').includes('dragend@src')")
	testing.expect_value(t, e2e.eval(s, "String(log.join(' | ').indexOf('drop@zone') >= 0 && log.join(' | ').indexOf('drop@zone') < log.join(' | ').indexOf('dragend@src'))"), "true")   // drop before dragend
	after := e2e.stats(s)
	testing.expectf(t, after.frame_gate.deferred > before.frame_gate.deferred, "the repaints asked for during the drag's loop were deferred, not made inside the frame that runs it: %d -> %d", before.frame_gate.deferred, after.frame_gate.deferred)

	// the page's context menu: a menu of the chrome, frames go on while it is open
	e2e.click_at(s, MENU_AT, button = .Right)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).menu_open }, "a right click on the page to open the context menu")
	open := e2e.stats(s)
	e2e.wait_frames(s, FRAMES_WHILE_OPEN)
	testing.expectf(t, e2e.stats(s).frames_drawn > open.frames_drawn, "frames are drawn while it is open")
	e2e.key(s, "Escape")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return !e2e.stats(s).menu_open }, "Escape to close it")
	end := e2e.stats(s)
	testing.expectf(t, end.frame_gate.violations == 0, "no violation of the gate: %s", end.frame_gate.last_violation)
}

// What the window procedure's stand-in saw in the poll of a chrome frame. Its message comes on the browser's own stack, in the system's calling convention, in the
// middle of a script: it can only leave what the test looks at afterwards.
@(private = "file")
In_The_Poll :: struct {
	s:          ^e2e.Session,
	window:     win.HWND,
	procedure:  win.WNDPROC,        // the toolkit's
	stop:       bool,               // the poster stops
	reached:    bool,
	at_poll:    Gate_Numbers,
	after_loop: Gate_Numbers,       // the paint of the loop of the system, from the poll
	after_next: Gate_Numbers,       // ... and of its next step
	after_deferred: Gate_Numbers,   // the paint when the frame has gone on to its build
}

@(private = "file")
Gate_Numbers :: struct { begun, nested, deferred, paints, chrome_frames, full_frames: int }

@(private = "file")
numbers :: proc(s: ^e2e.Session) -> Gate_Numbers {
	st := e2e.stats(s)
	return {st.frame_gate.begun, st.frame_gate.nested, st.frame_gate.deferred, st.paint_frames, st.chrome_frames, st.full_frames}
}

@(private = "file") in_poll: In_The_Poll

// The window's procedure while the test runs: all goes to the toolkit's but the one message, which acts where it comes.
@(private = "file")
stand_in :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	if msg != WM_IN_THE_POLL { return win.CallWindowProcW(in_poll.procedure, hwnd, msg, wparam, lparam) }
	context = in_poll.s.test
	g := platform.frame_gate()
	if in_poll.reached || g.stage != .Polling || g.kind != .Light { return 0 }   // (the polls of full frames come by too)
	in_poll.reached = true
	in_poll.at_poll = numbers(in_poll.s)
	call :: proc(msg: win.UINT) { win.CallWindowProcW(in_poll.procedure, in_poll.window, msg, 0, 0) }

	// a loop of the system begins here, resizes the window, and paints it
	call(win.WM_ENTERMENULOOP)
	win.SetWindowPos(in_poll.window, nil, 0, 0, i32(RESIZED_SIZE.x), i32(RESIZED_SIZE.y), win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	call(win.WM_PAINT)
	in_poll.after_loop = numbers(in_poll.s)

	// its next step: what the first chrome frame left is still "under a chrome frame", or this one would be asked of the full frame
	win.SetWindowPos(in_poll.window, nil, 0, 0, i32(RESIZED_AGAIN.x), i32(RESIZED_AGAIN.y), win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	call(win.WM_PAINT)
	in_poll.after_next = numbers(in_poll.s)

	// the same paint at a moment where no frame may begin: the frame has gone on to its build (a loop of the system begun from a build: a menu)
	platform.frame_gate_stage(g, .Building)
	call(win.WM_PAINT)
	g.stage = .Polling
	in_poll.after_deferred = numbers(in_poll.s)

	call(win.WM_EXITMENULOOP)
	return 0
}

@(test)
a_paint_of_the_system_under_a_chrome_frame :: proc(t: ^testing.T) {
	PAGE := fmt.tprintf(`<!doctype html><title>held</title><script>
window.hold = () => setTimeout(() => {{
	const w = innerWidth, begun = performance.now();
	while (innerWidth == w && performance.now() - begun < %d) {{}}
	window.released = innerWidth != w;
	window.ran = true;
}}, 0);
</script>`, SCRIPT_LIMIT_MS)
	s := e2e.start(t, {size = GATE_SIZE, hidden = true, prefs = {"browser.shell.preempt_after_ms=0"}})
	e2e.navigate(s, e2e.file_page(e2e.temp_folder(t), "held.html", PAGE))
	h := hwnd_of(s)
	show_unseen(h)
	e2e.wait_frames(s)
	in_poll = {s = s, window = h}
	in_poll.procedure = win.WNDPROC(rawptr(uintptr(win.GetWindowLongPtrW(h, win.GWLP_WNDPROC))))
	win.SetWindowLongPtrW(h, win.GWLP_WNDPROC, int(uintptr(rawptr(stand_in))))
	defer win.SetWindowLongPtrW(h, win.GWLP_WNDPROC, int(uintptr(rawptr(in_poll.procedure))))
	poster := thread.create_and_start_with_data(rawptr(uintptr(h)), proc(data: rawptr) {
		for !sync.atomic_load(&in_poll.stop) {
			win.PostMessageW(win.HWND(data), WM_IN_THE_POLL, 0, 0)
			win.Sleep(POST_EVERY_MS)
		}
	})
	before := numbers(s)

	e2e.eval(s, "hold(); 'ok'")
	e2e.wait_js(s, "window.ran === true")
	sync.atomic_store(&in_poll.stop, true)
	thread.join(poster)
	thread.destroy(poster)

	testing.expect_value(t, e2e.eval(s, "String(window.released)"), "true")   // the script was held until the window had its new size
	testing.expect(t, in_poll.reached, "a chrome frame polled under the script")
	testing.expectf(t, in_poll.at_poll.nested > before.nested && in_poll.at_poll.chrome_frames > before.chrome_frames, "the chrome frame is inside the full frame: %v, then %v", before, in_poll.at_poll)
	a, b, n, c := in_poll.at_poll, in_poll.after_loop, in_poll.after_next, in_poll.after_deferred
	testing.expectf(t, b.paints == a.paints + 1 && b.chrome_frames == a.chrome_frames + 1 && b.nested == a.nested + 1, "the paint of the loop is a chrome frame: %v, then %v", a, b)
	testing.expectf(t, n.paints == b.paints + 1 && n.chrome_frames == b.chrome_frames + 1 && n.nested == b.nested + 1, "the paint of its next step is one too: %v, then %v", b, n)
	testing.expect_value(t, n.full_frames, a.full_frames)                     // never a full frame under the script
	testing.expectf(t, c.deferred == n.deferred + 1 && c.begun == n.begun && c.paints == n.paints, "where no frame may begin it is deferred, not nested: %v, then %v", n, c)
	testing.expect_value(t, c.full_frames, a.full_frames)
	st := e2e.stats(s)
	testing.expectf(t, st.frame_gate.violations == 0, "no violation of the gate: %s", st.frame_gate.last_violation)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).full_frames > in_poll.at_poll.full_frames }, "the full frame to go on after the script")
}
