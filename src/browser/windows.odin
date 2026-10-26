package browser

// Several windows in one process. A window is a native window, its swap chain, its toolkit state and a list of tabs; the pages,
// the renderer, the fonts, the network and the loop are the process's, so a tab moves from one window to another with its page
// (its scripts, its video, its forms, its history, its zoom) as it is: only the pointer to the tab moves.
//
// The shell was written for one window, and still reads `app.win`, `app.tabs`, `app.current`, `app.page_rect`... : those fields
// are the *active* window's. `window_activate` puts the active window's share of the App (and of a few globals of the chrome that
// belong to a window: window_local) aside in its Browser_Window and takes the other's in. A frame is made for one window at a
// time, with that window active; what runs outside a frame (tasks of the loop, remote calls, menus) acts on the front window (the
// last one used), or finds a tab's own window (window_of_tab).
//
// The renderer draws to one swap chain at a time: the first window's is the renderer's own (`primary`), the others are
// render.Surface values that surface_use swaps in for the length of their frame.
//
// What the loop does with several windows (windows_pass):
//   * nothing is drawn for a window that has no cause (input, an animation, a frame it asked for, a repaint, its page changing):
//     the loop sleeps when none has one;
//   * a minimized window does not draw (its pages are hidden);
//   * the tasks of the loop (timers, network, posted calls) run once per pass, in the first frame, and what they ask of the
//     frames goes to every window that shows (windows_spill);
//   * a closed window closes its tabs; the last one ends the browser.

import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:page"

// What the App holds for the active window and a window keeps aside while another is active.
Window_Ctx :: struct {
	tabs:             [dynamic]^Tab,
	current:          int,
	address:          ui.Text_Field,
	focus_address:    bool,
	page_rect:        draw.Rect,
	frames_requested: int,
	presented:        bool,
}

Browser_Window :: struct {
	id:      int,                 // unique for the process, never reused: `wren ctl --window`
	win:     ^platform.Window,
	surf:    render.Surface,      // the window's swap chain, when it is not the primary one
	primary: bool,                // its swap chain is the renderer's own (render.init)
	ui:      ^ui.State,
	ctx:     Window_Ctx,          // valid while the window is not active
	pacer:   Pacer,               // ... and its pacing (the preferences and the timer stay the process's)
	locals:  [dynamic][]byte,     // ... and its copy of each window_local global
	minimized: bool,              // seen minimized by the last pass: no frames until it comes back
	closing:   bool,              // its last tab was closed: it closes at the end of the pass
	closing_force: bool,          // ... with the tabs it still has (a remote call asked)
	zone:      Drop_Zone,         // where its tabs were laid out (tab_drag.odin)
	drop_hint: int,               // a tab is carried over its tab bar: the place it would take, plus one (0: none)
	title:   string,              // what its title was set to last (owned)
	opened:  time.Tick,
	own:     Window_Own,          // the chrome's state of this window, always here (not exchanged by window_activate)
}

// What the chrome keeps of one window from frame to frame. It lives in the window: the procedures that read it are given
// the window (or read window_own(app), the active window's, at the frame's entry points). It replaces the globals that
// window_activate exchanged (window_local, below), one group at a time: tools\globals_allowed.txt lists those left.
Window_Own :: struct {
	security_chip_width: f32,                 // chrome.odin: the security chip's width at the last layout
	status_left_width:   f32,                 // status_bar.odin: the left part's width in the frame before
	fullscreen:          Window_Fullscreen,   // fullscreen_shell.odin: a page's element full screen
	full:                Window_Full,         // window_chrome.odin: the bars shown over the page in the window's full screen
	cursor:              Page_Cursor_View,    // page_cursor.odin: the window's cursors made from page images, what it shows
	urlbar:              Urlbar_View,         // urlbar.odin: the address bar's suggestions
	selection:           Selection_Shell,     // selection_shell.odin: the text selection gesture in the page shown
	strip:               Tab_Strip,           // tab_strip.odin: the tabs' scroll, the tab dragged, the tabs' box
	sidebar:             Tab_Sidebar,         // tab_sidebar.odin: the sidebar's width handle, whether it was shown
	find:                Find_State,          // find_bar.odin: the find bar, its text and its matches
	forms:               Forms_View,          // forms_shell.odin: the form controls as painted, the keyboard in the page, the drop-down
}

// The state of the window being framed (the active one); an App with no window (a test's) has one of its own.
window_own :: proc(app: ^App) -> ^Window_Own {
	return app.active != nil ? &app.active.own : &app.bare_own
}

// What a window's own state holds is freed (the window closes, or the browser ends: every window's, the front one's last).
window_own_destroy :: proc(own: ^Window_Own) {
	page_cursor_view_destroy(&own.cursor)
	urlbar_view_destroy(&own.urlbar)
	find_destroy(&own.find)
	forms_shell_destroy(&own.forms)
}

////////////////////////////////
// Globals that belong to a window

// A global of the chrome that holds the state of one window (the tab strip's scroll, the find bar, the keyboard focus of the page):
// registered once, it is exchanged by window_activate, so each window has its own and the code keeps using the global. A new window
// starts with the value the global had when it was registered. `destroy` frees what the value owns (called with the window's
// value in place, when the window closes).
Window_Local :: struct {
	ptr:      rawptr,
	size:     int,
	pristine: []byte,
	destroy:  proc(),
}

@(private = "file") window_locals: [dynamic]Window_Local

window_local :: proc(p: ^$T, destroy: proc() = nil) {
	l := Window_Local{ptr = p, size = size_of(T), destroy = destroy}
	l.pristine = make([]byte, l.size)
	mem.copy(raw_data(l.pristine), p, l.size)
	append(&window_locals, l)
}

// The globals of the chrome that are one window's (called once the shell is set up: a new window starts with their values then).
windows_register_locals :: proc() {
}

windows_locals_destroy :: proc() {
	for l in window_locals { delete(l.pristine) }
	delete(window_locals)
	window_locals = nil
}

// The active window's values go into its record; `w`'s come back (a window that never had any starts from the pristine ones).
@(private = "file")
locals_swap :: proc(from, to: ^Browser_Window) {
	if from != nil {
		for len(from.locals) < len(window_locals) { append(&from.locals, nil) }
		for l, i in window_locals {
			if from.locals[i] == nil { from.locals[i] = make([]byte, l.size) }
			mem.copy(raw_data(from.locals[i]), l.ptr, l.size)
		}
	}
	if to != nil {
		for l, i in window_locals {
			if i < len(to.locals) && to.locals[i] != nil {
				mem.copy(l.ptr, raw_data(to.locals[i]), l.size)
			} else {
				mem.copy(l.ptr, raw_data(l.pristine), l.size)
			}
		}
	}
}

////////////////////////////////
// The active window

@(private = "file")
ctx_store :: proc(app: ^App, c: ^Window_Ctx) {
	c.tabs, c.current, c.address, c.focus_address = app.tabs, app.current, app.address, app.focus_address
	c.page_rect, c.frames_requested, c.presented = app.page_rect, app.frames_requested, app.presented
}

@(private = "file")
ctx_load :: proc(app: ^App, c: ^Window_Ctx) {
	app.tabs, app.current, app.address, app.focus_address = c.tabs, c.current, c.address, c.focus_address
	app.page_rect, app.frames_requested, app.presented = c.page_rect, c.frames_requested, c.presented
}

// Pacing is the window's (its monitor's rate, its swap chain's queue, its resize steps); the preferences and the timer are not.
@(private = "file")
pacer_adopt :: proc(w: ^Browser_Window) {
	shared := pacer
	pacer = w.pacer
	pacer.cfg, pacer.watch, pacer.timer = shared.cfg, shared.watch, shared.timer
	if pacer.latency == 0 { pacer.latency = 1 }   // (what a swap chain is made with)
}

// Makes `w` the window the App's per-window fields and the renderer are about.
window_activate :: proc(app: ^App, w: ^Browser_Window) {
	if app.active == w { return }
	if app.active != nil { window_deactivate(app) }
	if w == nil { return }
	ctx_load(app, &w.ctx)
	w.ctx = {}
	locals_swap(nil, w)
	pacer_adopt(w)
	app.win, app.ui_state = w.win, w.ui
	app.active = w
	ui.use(w.ui)
	if !w.primary { render.surface_use(&app.r, &w.surf) }
}

// Back to no window: the renderer has its own swap chain again and the window has its fields.
window_deactivate :: proc(app: ^App) {
	w := app.active
	if w == nil { return }
	if !w.primary { render.surface_use(&app.r, &w.surf) }
	ctx_store(app, &w.ctx)
	locals_swap(w, nil)
	w.pacer = pacer
	app.tabs, app.address = nil, {}
	app.active = nil
}

// The window the process acts on when no window is the subject: the last one that was used.
window_front :: proc(app: ^App) -> ^Browser_Window {
	if app.front != nil { return app.front }
	return len(app.windows) > 0 ? app.windows[0] : nil
}

// Makes `w` the window the user is in (it comes to the front of the others on screen too when `raise`).
window_focus :: proc(app: ^App, w: ^Browser_Window, raise := false) {
	app.front = w
	if raise && !app.headless && w != nil && w.win != nil && !platform.is_minimized(w.win) { win.SetForegroundWindow(w.win.hwnd) }
}

window_by_id :: proc(app: ^App, id: int) -> ^Browser_Window {
	for w in app.windows { if w.id == id { return w } }
	return nil
}

// A window's tabs and its current one, whether it is active (the App holds them) or not.
window_tabs :: proc(app: ^App, w: ^Browser_Window) -> ^[dynamic]^Tab { return w == app.active ? &app.tabs : &w.ctx.tabs }
window_current :: proc(app: ^App, w: ^Browser_Window) -> ^int { return w == app.active ? &app.current : &w.ctx.current }
window_address :: proc(app: ^App, w: ^Browser_Window) -> ^ui.Text_Field { return w == app.active ? &app.address : &w.ctx.address }

window_current_tab :: proc(app: ^App, w: ^Browser_Window) -> ^Tab {
	tabs := window_tabs(app, w)
	cur := window_current(app, w)^
	return cur >= 0 && cur < len(tabs) ? tabs[cur] : nil
}

// Asks for frames of one window, active or not.
window_request :: proc(app: ^App, w: ^Browser_Window, n: int) {
	f := w == app.active ? &app.frames_requested : &w.ctx.frames_requested
	f^ = max(f^, n)
}

// The window that holds the tab, and its place there.
window_of_tab :: proc(app: ^App, t: ^Tab) -> (^Browser_Window, int) {
	for w in app.windows {
		for x, i in window_tabs(app, w)^ { if x == t { return w, i } }
	}
	return nil, -1
}

// Every tab of every window (the front window's first), valid until the list changes.
tabs_all :: proc(app: ^App) -> []^Tab {
	out := make([dynamic]^Tab, 0, len(app.tabs) + 8, context.temp_allocator)
	if len(app.windows) == 0 { append(&out, ..app.tabs[:]); return out[:] }   // (a bare App, as the tests make)
	front := window_front(app)
	if front != nil { append(&out, ..window_tabs(app, front)[:]) }
	for w in app.windows { if w != front { append(&out, ..window_tabs(app, w)[:]) } }
	return out[:]
}

// (tab_by_id, bfcache.odin: a tab by its identifier, whatever its window.)

// Shows the tab: it becomes the current one of its window, and the window comes to the front.
tab_reveal :: proc(app: ^App, t: ^Tab) {
	w, i := window_of_tab(app, t)
	if w == nil { return }
	if w == app.active {
		tab_select(app, i)
	} else {
		cur := window_current(app, w)
		if cur^ != i {
			cur^ = i
			ui.field_set(window_address(app, w), t.url)
			recovery_touch(app)
		}
		window_request(app, w, 2)
	}
	window_focus(app, w, true)
}

// The tab's address, shown in the address field of the window where the tab is the current one (nowhere else: a tab in the
// background shows it when it is selected).
address_set :: proc(app: ^App, t: ^Tab, text: string) {
	w, i := window_of_tab(app, t)
	if w == nil || window_current(app, w)^ != i { return }
	ui.field_set(window_address(app, w), text)
}

// What the tasks of the loop (and anything else made outside a frame) asked of the active window's frames, for the others too: the
// task does not say which window it is about.
windows_spill :: proc(app: ^App, n: int) {
	for w in app.windows {
		if w == app.active || w.minimized { continue }
		w.ctx.frames_requested = max(w.ctx.frames_requested, n)
	}
}

// The window's own wake-up for the loop: the message that ends the wait is posted to any window that still exists.
@(private = "file") wake_target: uintptr

wake_window :: proc(user: rawptr) {
	h := sync.atomic_load(&wake_target)
	if h != 0 { win.PostMessageW(win.HWND(h), win.WM_NULL, 0, 0) }
}

@(private = "file")
wake_retarget :: proc(app: ^App) {
	h: uintptr
	if front := window_front(app); front != nil && front.win != nil && front.win.hwnd != nil { h = uintptr(front.win.hwnd) }
	sync.atomic_store(&wake_target, h)
}

////////////////////////////////
// Opening and closing windows

@(private = "file") window_ids: int

// The first window, opened by main before the renderer: its swap chain is the renderer's own.
window_adopt_primary :: proc(app: ^App, w: ^platform.Window) -> ^Browser_Window {
	bw := new(Browser_Window)
	window_ids += 1
	bw.id, bw.win, bw.primary, bw.ui = window_ids, w, true, new(ui.State)
	bw.opened = time.tick_now()
	append(&app.windows, bw)
	w.user = bw
	app.front = bw
	window_activate(app, bw)
	wake_retarget(app)
	return bw
}

// Every frame of the thread goes through the toolkit's frame gate (platform/frame_gate.odin: one state machine, Idle ->
// Polling -> Work -> Building -> Drawing -> Presenting). The browser's frames and their stages:
//   * a full frame (main.odin frame, kind Full): Polling is its wait and poll, Work its page phase (loop tasks, page input,
//     animation frames, styles and layout: shell_page_phase_end closes it), then the build, the drawing and the present;
//   * a chrome frame (shell_frames.odin, kind Light): the chrome alone while a page holds the thread, made in a full
//     frame's page phase (preemption) or in a chrome frame's poll; no Work;
//   * a frame of the developer tools' window (devtools_window.odin, kind Light: none of the page's work).
// A frame asked for from the window procedure (window_on_frame: WM_PAINT inside a loop of the system) is made only where
// the gate admits it. A loop entered from a frame's poll (a press on the window's border, Alt+Space) makes its frames
// there: they come before anything of the frame that polls. A loop entered during the build or the drawing
// (TrackPopupMenu, a modal dialog: they pump the thread's messages) would build the interface inside the one being built
// (the crash of 2026-10-26: ui.spacer after app_icon, the system menu opened from the build): those frames are deferred,
// the window repaints at the next pass. A move the machine does not have panics in the builds with -debug
// (frame_gate_init), and is counted otherwise (wren ctl stats: frameGate).
frame_gate_init :: proc() {
	platform.frame_gate().strict = ODIN_DEBUG
}

// The kind of frame window_frame makes for a window's WM_PAINT now: inside a chrome frame, a chrome frame.
window_frame_kind :: proc() -> platform.Frame_Kind { return chrome_frames.nested ? .Light : .Full }

// A frame from the window procedure can be made now (the frame gate).
window_frame_allowed :: proc(app: ^App, bw: ^Browser_Window) -> bool {
	if ui.building() { return false }   // (a build of any window: the developer tools' own too)
	g := platform.frame_gate()
	kind := window_frame_kind()
	if !platform.frame_admits(g.stage, g.kind, kind) { return false }
	return kind == .Full || app.active == bw   // (a chrome frame is the current window's: shell_frames.odin)
}

window_on_frame :: proc(user: rawptr) {
	bw := (^Browser_Window)(user)
	app := the_app
	if app == nil || bw.win == nil { return }
	if !window_frame_allowed(app, bw) { platform.frame_gate_defer(platform.frame_gate()); bw.win.paint_requested = true; return }
	// the window whose frame polled (or the pass's) is the App's again afterwards: its frame goes on with its own tabs
	prev := app.active
	window_activate(app, bw)
	window_frame(app)   // shell_frames.odin
	if prev != nil && prev != bw && slice.contains(app.windows[:], prev) { window_activate(app, prev) }
}

// Shows the window (maximized when a restored session left it so: platform.set_placement).
window_show :: proc(w: ^Browser_Window) { platform.show_window(w.win) }

// The outer rectangle of a window and whether it is maximized: what a session saves.
window_placement :: proc(w: ^Browser_Window) -> (rect: [4]int, maximized: bool) {
	p := platform.get_placement(w.win)
	return p.rect, p.maximized
}

// Puts a window where a session had it (not shown yet).
window_placement_set :: proc(w: ^Browser_Window, rect: [4]int, maximized: bool) { platform.set_placement(w.win, {rect, maximized}) }
// A new window, empty (the caller puts a tab in it). `size` is in logical pixels; `at` is where its top left goes on the screen
// (physical pixels), else the system centres it. nil when the system could not make the window or its swap chain.
window_open :: proc(app: ^App, size: [2]int, at: Maybe([2]int) = nil, show := true) -> ^Browser_Window {
	fixed := config.bool_of(&app.prefs, "browser.window.fixed_surface")
	nw := platform.open_window(APP_NAME, size, on_frame = window_on_frame, transparent = fixed, integrated_title = wchrome.cfg.integrated)
	if nw == nil { return nil }
	platform.set_square_corners(nw, wchrome.cfg.square_corners)
	dnd_window_attach(nw)   // dnd_shell.odin
	app_commands_attach(nw.hwnd)   // app_commands.odin
	if p, ok := at.?; ok { platform.move_window(nw, p.x, p.y) }
	if nw.size.x <= 0 || nw.size.y <= 0 {
		cr: win.RECT
		win.GetClientRect(nw.hwnd, &cr)
		nw.size = {max(int(cr.right - cr.left), 1), max(int(cr.bottom - cr.top), 1)}
	}
	// straight into the window's record, never through a local: a render.Surface is kilobytes (its present ring), and a local of
	// it is split by LLVM into thousands of scalars whose debug fragments kept `build.bat` (-o:speed -debug) codegen going for an hour
	bw := new(Browser_Window)
	ok := render.surface_init(&app.r, &bw.surf, nw.hwnd, nw.size, transparent = fixed, fixed_size = fixed_surface_size(app, nw.hwnd))   // (in place: see render.surface_create)
	if !ok {
		free(bw)
		platform.destroy_window(nw)
		return nil
	}
	window_ids += 1
	bw.id, bw.win, bw.ui = window_ids, nw, new(ui.State)
	bw.opened = time.tick_now()
	nw.user = bw
	ui.init(bw.ui, &app.fonts, &app.theme)
	bw.ui.icon_font = app.icons
	bw.ui.mono_font = app.ui_state.mono_font
	ui.use(app.ui_state)
	bw.ctx.frames_requested = 4
	append(&app.windows, bw)
	if show && !app.headless { window_show(bw) }
	return bw
}

// Closes the window and the tabs it still has (their pages end with them: this is not a move). The last window is not closed
// here: the loop ends and the browser's own shutdown closes it.
window_close :: proc(app: ^App, w: ^Browser_Window) {
	if w == nil || len(app.windows) <= 1 { return }
	was_front := app.front == w
	// its own globals die with it: with its values in place
	window_activate(app, w)
	for len(app.tabs) > 0 {
		t := pop(&app.tabs)
		tab_discard(app, t)
	}
	for l, i in window_locals {
		if l.destroy != nil { l.destroy() }
		_ = i
	}
	window_own_destroy(&w.own)
	window_deactivate(app)
	for b in w.locals { delete(b) }
	delete(w.locals)
	delete(w.ctx.tabs)
	ui.field_destroy(&w.ctx.address)
	// the swap chain: another window's becomes the renderer's own when it is the primary one that goes
	idx := -1
	for x, i in app.windows { if x == w { idx = i } }
	ordered_remove(&app.windows, idx)
	if w.primary {
		heir := app.windows[0]
		render.surface_use(&app.r, &heir.surf)      // the renderer has the heir's chain; the heir's record has the primary's
		render.surface_destroy(&app.r, &heir.surf)  // ... which is released: the heir is the primary now
		heir.primary = true
	} else {
		render.surface_destroy(&app.r, &w.surf)
	}
	ui.destroy(w.ui)
	free(w.ui)
	delete(w.title)
	dnd_window_detach(w.win)
	window_chrome_forget(w.win)
	platform.destroy_window(w.win)
	free(w)
	if was_front || app.front == w { app.front = nil }
	wake_retarget(app)
	app.frames_requested = max(app.frames_requested, 2)
}

////////////////////////////////
// The loop

// Whether the window has something to draw: input waiting for it, frames it asked for, an animation or a wake of its toolkit, a
// repaint the system asked for. (The page's own changes are seen by the frame, once the tasks have run.)
@(private = "file")
window_has_cause :: proc(app: ^App, w: ^Browser_Window) -> bool {
	if w.minimized || len(window_tabs(app, w)) == 0 { return false }
	events_waiting := len(w.win.events) > w.win.returned || len(w.win.injected) > 0
	paint := platform.take_paint_request(w.win)
	return app.frames_requested != 0 || ui.needs_frame(app.ui_state) || ui.wake_due(app.ui_state) || paint || events_waiting
}


@(private = "file") pass_order: [dynamic]^Browser_Window
@(private = "file") pass_causes: [dynamic]bool

// One pass of the loop: sleep when no window has a cause, then one frame for each window (the front one first, which runs the
// tasks of the loop). false: the last window was closed.
windows_pass :: proc(app: ^App) -> bool {
	front := window_front(app)
	// (not the temporary allocator: a frame frees it at its end, and the next window's frame is made after)
	clear(&pass_order); clear(&pass_causes)
	if front != nil { append(&pass_order, front) }
	for w in app.windows { if w != front { append(&pass_order, w) } }
	for _ in pass_order { append(&pass_causes, false) }
	order, causes := pass_order[:], pass_causes[:]
	any_cause := devtools_window_busy()
	wake := 0
	for w, i in order {
		window_activate(app, w)
		w.minimized = len(app.windows) > 1 && platform.is_minimized(w.win)
		causes[i] = window_has_cause(app, w)
		any_cause ||= causes[i]
		if ms := ui.wake_in_ms(app.ui_state); ms > 0 && !w.minimized && (wake == 0 || ms < wake) { wake = ms }
	}
	idled := false
	if !any_cause {
		timeout := devtools_window_timeout(wake)
		if t := host.next_timeout_ms(&app.loop); t >= 0 && (timeout <= 0 || t < timeout) { timeout = max(t, 1) }
		prof_begin(.Idle)
		platform.wait_event(order[0].win, memcheck_wake(memory_trim_wake(timeout)))
		prof_end(.Idle)
		idled = true
	}
	app.pass_first = true
	for w, i in order {
		if w.minimized {
			window_activate(app, w)
			platform.poll_events(w.win, false)
			for tab in app.tabs { if tab.page != nil { page.set_page_visible(tab.page, false) } }
			continue
		}
		window_activate(app, w)
		frame(app, idled || !causes[i])
		if front != nil && w == front { devtools_window_tick(app) }
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}
	app.pass_first = false
	if app.quitting { return false }
	// a closed window closes; the last one ends the loop
	for w in app.windows {
		if platform.is_closed(w.win) {
			if len(app.windows) == 1 { return false }
			window_close(app, w)
			break
		}
		if w.closing && (w.closing_force || len(window_tabs(app, w)) == 0) {
			if len(app.windows) == 1 {   // (its twin closed in the same pass: the browser keeps one, with a new tab)
				w.closing, w.closing_force = false, false
				window_activate(app, w)
				if len(app.tabs) == 0 { tab_open_new(app) }
			} else {
				window_close(app, w)
			}
			break
		}
	}
	window_activate(app, window_front(app))
	wake_retarget(app)
	return true
}

// A tab taken out of its window for good: its page and everything the shell keeps for it go, and it can be reopened (closed tabs).
tab_discard :: proc(app: ^App, t: ^Tab) {
	closed_tabs_push(t.url)
	key := strings.clone(tab_key(t), context.temp_allocator)
	tab_free(app, t)
	page.storage_drop_session(&app.storage, key)
}

////////////////////////////////
// Moving a tab between windows: the Tab (its page, its history, its zoom, its scripts and video) is the same; only the pointer
// goes from one list to the other.

// Takes the tab at `index` out of a window's list; returns the window's new current index (the tab that took its place, else the
// last one; 0 when the list is empty).
tab_list_take :: proc(tabs: ^[dynamic]^Tab, current, index: int) -> int {
	if index < 0 || index >= len(tabs) { return current }
	ordered_remove(tabs, index)
	switch {
	case len(tabs) == 0: return 0
	case index < current: return current - 1
	case index == current: return min(index, len(tabs) - 1)
	}
	return current
}

// Puts `t` in a list at `at` (clamped; negative: the end). The new current index and the place it took: the tab is the current
// one when `select`, else the one that was current stays so.
tab_list_put :: proc(tabs: ^[dynamic]^Tab, current, at: int, t: ^Tab, select: bool) -> (new_current, place: int) {
	place = at < 0 ? len(tabs) : min(at, len(tabs))
	inject_at(tabs, place, t)
	if select || len(tabs) == 1 { return place, place }
	return place <= current ? current + 1 : current, place
}

// Moves `t` to window `dest` at `at` (negative: the end), where it becomes the current tab. In its own window: to that place.
// The window that loses its last tab closes (at the end of the pass). The developer tools follow the tab they were showing.
// false: nothing was done (the tab or the window is unknown).
tab_move :: proc(app: ^App, t: ^Tab, dest: ^Browser_Window, at := -1, devtools_follow := true) -> bool {
	src, si := window_of_tab(app, t)
	if src == nil || dest == nil { return false }
	st, dt := window_tabs(app, src), window_tabs(app, dest)
	sc := window_current(app, src)
	if src == dest {
		to := at < 0 ? len(st) - 1 : min(at, len(st) - 1)
		sc^ = list_move(st[:], si, to, sc^)
		window_request(app, src, 2)
		recovery_touch(app)
		return true
	}
	showing := sc^ == si
	sc^ = tab_list_take(st, sc^, si)
	dc := window_current(app, dest)
	dc^, _ = tab_list_put(dt, dc^, at, t, true)
	if len(st) > 0 { ui.field_set(window_address(app, src), st[sc^].url) } else { src.closing = true }
	ui.field_set(window_address(app, dest), t.url)
	if devtools_follow && showing && dev.visible && dev.window == src.id { dev.window = dest.id }
	window_request(app, src, 3)
	window_request(app, dest, 3)
	recovery_touch(app)
	return true
}

// Moves `t` to a window of its own, near `at` (the top left of the window, in screen pixels; else beside the one it comes from).
// nil when it is alone in its window (it already has one) or the system could not make the window.
tab_detach :: proc(app: ^App, t: ^Tab, at: Maybe([2]int) = nil, focus := true) -> ^Browser_Window {
	src, _ := window_of_tab(app, t)
	if src == nil || len(window_tabs(app, src)) < 2 { return nil }
	return tab_to_new_window(app, t, src, at, true, focus)
}

// A new window with a home tab (Ctrl+N).
window_new :: proc(app: ^App) -> ^Browser_Window {
	src := app.active != nil ? app.active : window_front(app)
	if src == nil { return nil }
	was := window_current(app, src)^
	t := tab_open(app)   // (in the active window, then taken from it: the window it left shows what it showed)
	nw := tab_to_new_window(app, t, src, nil, false, true)
	window_current(app, src)^ = clamp(was, 0, max(len(window_tabs(app, src)) - 1, 0))
	if cur := window_current_tab(app, src); cur != nil { ui.field_set(window_address(app, src), cur.url) }
	if nw != nil { nw.ctx.focus_address = true }
	return nw
}

@(private = "file")
tab_to_new_window :: proc(app: ^App, t: ^Tab, src: ^Browser_Window, at: Maybe([2]int), devtools_follow, focus: bool) -> ^Browser_Window {
	scale := max(src.win.dpi_scale, 0.5)
	size := [2]int{int(f32(src.win.size.x) / scale), int(f32(src.win.size.y) / scale)}
	pos := at
	if _, ok := pos.?; !ok {
		r := platform.outer_rect(src.win)
		off := int(40 * scale)
		pos = [2]int{r[0] + off, r[1] + off}
	}
	nw := window_open(app, size, pos)
	if nw == nil { return nil }
	tab_move(app, t, nw, devtools_follow = devtools_follow)
	if focus { window_focus(app, nw, true) }
	return nw
}
// What the menus call a window: the title of its current tab.
window_label :: proc(app: ^App, w: ^Browser_Window) -> string {
	t := window_current_tab(app, w)
	if t == nil { return "(empty)" }
	return t.title != "" ? t.title : t.url
}

////////////////////////////////
// Shutdown (main.odin, in the order the browser's own steps run)

// The loop ended: the windows other than the front one give up what they own through their window_local globals (the front
// window's are freed by the browser's own steps, with the values that are in the globals).
windows_shutdown_begin :: proc(app: ^App) {
	front := window_front(app)
	for w in app.windows {
		if w == front { continue }
		window_activate(app, w)
		for l in window_locals { if l.destroy != nil { l.destroy() } }
		window_own_destroy(&w.own)
	}
	window_activate(app, front)
	sync.atomic_store(&wake_target, 0)
}

// Every tab was freed: the lists forget them.
windows_forget_tabs :: proc(app: ^App) {
	clear(&app.tabs)
	for w in app.windows {
		if w == app.active { continue }
		delete(w.ctx.tabs)
		w.ctx.tabs = nil
	}
}

// The toolkit states of every window (the active one's address field was freed by its own step).
windows_destroy_ui :: proc(app: ^App) {
	for w in app.windows {
		if w != app.active { ui.field_destroy(&w.ctx.address) }
		ui.destroy(w.ui)
	}
}

// The swap chains of the windows that are not the renderer's own.
windows_destroy_surfaces :: proc(app: ^App) {
	window_deactivate(app)
	for w in app.windows { if !w.primary { render.surface_destroy(&app.r, &w.surf) } }
}

windows_destroy :: proc(app: ^App) {
	for w in app.windows {
		for b in w.locals { delete(b) }
		delete(w.locals)
		delete(w.title)
		delete(w.ctx.tabs)   // (the active window's list went to it when windows_destroy_surfaces deactivated it)
		free(w.ui)
		platform.destroy_window(w.win)
		free(w)
	}
	delete(app.windows)
	delete(pass_order); delete(pass_causes)
	pass_order, pass_causes = nil, nil
	app.windows = nil
	app.active, app.front, app.win, app.ui_state = nil, nil, nil, nil
	windows_locals_destroy()
}
