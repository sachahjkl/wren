package browser

// Several windows in one process. A window is a native window, its swap chain, its toolkit state and a list of tabs; the pages,
// the renderer, the fonts, the network and the loop are the process's, so a tab moves from one window to another with its page
// (its scripts, its video, its forms, its history, its zoom) as it is: only the pointer to the tab moves.
//
// The shell was written for one window. What is a window's lives in its Browser_Window and is read there: its tabs, page
// area and frames (Window_Ctx: active_window(app).tabs, w.tabs, request_frames(app, n)), the chrome's state (Window_Own).
// Its native window and toolkit state too (active_window(app).win, .ui). A frame is made for one window at a
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

// A window's tabs, address field, page area and frames: only here, never copied into the App (active_window(app).tabs).
Window_Ctx :: struct {
	tabs:             [dynamic]^Tab,
	current:          int,            // the tab shown (an index in tabs)
	groups:           [dynamic]Tab_Group,   // tab_groups.odin: the groups its tabs are in (freed with the window)
	address:          ui.Text_Field,  // the address field
	focus_address:    bool,           // Ctrl+L: focus the address field in the next build
	page_rect:        draw.Rect,      // where the page was painted last frame (physical pixels)
	frames_requested: int,            // frames asked for (request_frames, window_request): the loop counts one off per frame
	presented:        bool,           // a frame went to the swap chain: from then on each frame waits for it to take the next
}

Browser_Window :: struct {
	id:      int,                 // unique for the process, never reused: `wren ctl --window`
	win:     ^platform.Window,
	surf:    render.Surface,      // the window's swap chain, when it is not the primary one
	primary: bool,                // its swap chain is the renderer's own (render.init)
	headless_shared: bool,        // a headless window with no Surface of its own: it renders into the primary offscreen target (window_activate resizes it to this window's size)
	ui:      ^ui.State,
	using ctx: Window_Ctx,
	pacer:   Pacer,               // its pacing (pacing.odin; the preferences and the timer are the process's: App.pacing)
	minimized: bool,              // seen minimized by the last pass: no frames until it comes back
	closing:   bool,              // its last tab was closed: it closes at the end of the pass
	closing_force: bool,          // ... with the tabs it still has (a remote call asked)
	zone:      Drop_Zone,         // where its tabs were laid out (tab_drag.odin)
	drop:      Drop_Slot,         // a tab is carried over its tabs (`dropping`): where it would go, and its mark (tab_drag.odin)
	dropping:  bool,
	title:   string,              // what its title was set to last (owned)
	opened:  time.Tick,
	own:     Window_Own,          // the chrome's state of this window, always here (not exchanged by window_activate)
}

// What the chrome keeps of one window from frame to frame. It lives in the window: the procedures that read it are given
// the window (or read window_own(app), the active window's, at the frame's entry points). No global of the chrome is a
// window's (tools\lint_globals.ps1: a new one fails); a window starts with this zeroed.
Window_Own :: struct {
	security_chip_width: f32,                 // chrome.odin: the security chip's width in the address bar (measured while building)
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
	address_key:         ui.Key,              // chrome.odin: the address field's key, set when it is built
	chip_segment:        Chip_Segment,        // chrome.odin: the security chip's segment of the address bar, as drawn
	chip_icon:           Chip_Icon,           // chrome.odin: the security chip's icon, as drawn
	ctx_menu:            Context_Menu_State,  // context_menu.odin: the context menu asked for, and the one open
	frames:              Frames_Input,        // frames_shell.odin: the frame hovered, focused, pressed
	nav_press:           Nav_Press,           // history_ui.odin: the back/forward button held down
	devices:             Device_Input,        // page_input.odin: the fingers and pens over the page
	autoscroll:          Page_Autoscroll,     // page_autoscroll.odin: the middle-click autoscroll session of the page
	page_prep:           Page_Prep,           // page_frame.odin: the page as prepared in the page phase, for its paint
	page_snapshot_wanted: bool,               // shell_frames.odin: the frame keeps the page's pixels for chrome frames
	a11y:                Page_A11y,           // a11y_page.odin: the accessibility trees of the page shown and its frames
	devtools:            Devtools,            // devtools.odin: the window's developer tools, docked or in a window of their own (dev())
	// what a command, a menu or the page asked of the next build (a popup opened from the chrome)
	page_info_request:     bool,              // chrome.odin: the security chip's page information
	main_menu_request:     bool,              // chrome.odin: the main menu (Alt+F / Alt+E)
	blocker_panel_request: bool,              // blocker_ui.odin: the content blocker's panel
}

// The window being framed (the active one); an App with no window (a test's) has one of its own, never shown.
active_window :: proc(app: ^App) -> ^Browser_Window {
	return app.active != nil ? app.active : &app.bare
}

// The chrome's state of the active window.
window_own :: proc(app: ^App) -> ^Window_Own { return &active_window(app).own }

// What a window's own state holds is freed (the window closes, or the browser ends: every window's, the front one's last). The
// window is the active one (its developer tools are read as dev()).
window_own_destroy :: proc(app: ^App, own: ^Window_Own) {
	assert(own == window_own(app))
	devtools_view_destroy(app)   // devtools.odin: their window closes with this one
	page_cursor_view_destroy(&own.cursor)
	urlbar_view_destroy(&own.urlbar)
	find_destroy(&own.find)
	forms_shell_destroy(&own.forms)
	context_menu_state_destroy(&own.ctx_menu)
	device_input_destroy(&own.devices)
	page_a11y_destroy(&own.a11y)
	sidebar_destroy(&own.sidebar)
}

////////////////////////////////
// The active window

// Makes `w` the window the frame, the toolkit's state and the renderer are about.
window_activate :: proc(app: ^App, w: ^Browser_Window) {
	if app.active == w { return }
	if app.active != nil { window_deactivate(app) }
	if w == nil { return }
	if w.pacer.latency == 0 { w.pacer.latency = 1 }   // (what a swap chain is made with)
	app.active = w
	ui.use(w.ui)
	if w.headless_shared {
		// no Surface: the one offscreen target serves every headless window; size it to this one before its frame
		render.resize(&app.r, w.win.size)
	} else if !w.primary {
		render.surface_use(&app.r, &w.surf)
	}
}

// Back to no window: the renderer has its own swap chain again.
window_deactivate :: proc(app: ^App) {
	w := app.active
	if w == nil { return }
	if !w.primary && !w.headless_shared { render.surface_use(&app.r, &w.surf) }
	app.active = nil
}

// The window the process acts on when no window is the subject: the last one that was used.
window_front :: proc(app: ^App) -> ^Browser_Window {
	if app.front != nil { return app.front }
	return len(app.windows) > 0 ? app.windows[0] : nil
}

// Makes `w` the window the user is in (it comes to the front of the others on screen too when `raise`).
window_focus :: proc(app: ^App, w: ^Browser_Window, raise := false) {
	window_set_front(app, w)
	if raise && !app.headless && w != nil && w.win != nil && !platform.is_minimized(w.win) { win.SetForegroundWindow(w.win.hwnd) }
}

// The window the user is in becomes `w`: the one that was and `w` draw again (the caret of a focused field shows only in the front
// window: forms_shell.odin).
window_set_front :: proc(app: ^App, w: ^Browser_Window) {
	if app.front == w { return }
	if app.front != nil && slice.contains(app.windows[:], app.front) { window_request(app, app.front, 2) }
	app.front = w
	if w != nil { window_request(app, w, 2) }
}

// Whether the active window is the one the user is in (always, with one window).
window_is_front :: proc(app: ^App) -> bool {
	return len(app.windows) <= 1 || app.active == window_front(app)
}

window_by_id :: proc(app: ^App, id: int) -> ^Browser_Window {
	for w in app.windows { if w.id == id { return w } }
	return nil
}

// A window's tabs, its current one, its address field (active or not: they are only in the window).
window_tabs :: proc(app: ^App, w: ^Browser_Window) -> ^[dynamic]^Tab { return &w.tabs }
window_current :: proc(app: ^App, w: ^Browser_Window) -> ^int { return &w.current }
window_address :: proc(app: ^App, w: ^Browser_Window) -> ^ui.Text_Field { return &w.address }

window_current_tab :: proc(app: ^App, w: ^Browser_Window) -> ^Tab {
	tabs := window_tabs(app, w)
	cur := window_current(app, w)^
	return cur >= 0 && cur < len(tabs) ? tabs[cur] : nil
}

// Asks for frames of one window, active or not.
window_request :: proc(app: ^App, w: ^Browser_Window, n: int) {
	w.frames_requested = max(w.frames_requested, n)
}

// Asks for frames of the active window (the frame being made, or the front one between frames).
request_frames :: proc(app: ^App, n := 2) { window_request(app, active_window(app), n) }

// The window that holds the tab, and its place there.
window_of_tab :: proc(app: ^App, t: ^Tab) -> (^Browser_Window, int) {
	for w in app.windows {
		for x, i in window_tabs(app, w)^ { if x == t { return w, i } }
	}
	return nil, -1
}

// Every tab of every window (the front window's first), valid until the list changes.
tabs_all :: proc(app: ^App) -> []^Tab {
	out := make([dynamic]^Tab, 0, len(active_window(app).tabs) + 8, context.temp_allocator)
	if len(app.windows) == 0 { append(&out, ..app.bare.tabs[:]); return out[:] }   // (a bare App, as the tests make)
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
		w.frames_requested = max(w.frames_requested, n)
	}
}

// The window's own wake-up for the loop: platform.wake posts to a real window that still exists, or signals the
// auto-reset event / eventfd an offscreen (headless) window waits on (it has no message queue). Both forms are
// thread-safe, so the loop is woken from any thread (host.post from a worker). `wake_target` is the front window the
// loop waits on now, read atomically as a pointer (retarget runs on the UI thread; the window outlives the target).
@(private = "file") wake_target: rawptr

wake_window :: proc(user: rawptr) {
	if w := (^platform.Window)(sync.atomic_load(&wake_target)); w != nil { platform.wake(w) }
}

@(private = "file")
wake_retarget :: proc(app: ^App) {
	w: rawptr
	if front := window_front(app); front != nil && front.win != nil { w = front.win }
	sync.atomic_store(&wake_target, w)
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
	bw := new(Browser_Window)
	nw: ^platform.Window
	if app.headless {
		// a headless second window: no HWND, and no per-window render Surface (the renderer is offscreen, one target for all;
		// the active window's size is applied before its frame, see window_activate). The capture is one window at a time.
		sc := ui_scale_of(app)
		nw = platform.open_window_offscreen(APP_NAME, {int(f32(size.x) * sc + 0.5), int(f32(size.y) * sc + 0.5)}, dpi_scale = sc, on_frame = window_on_frame)
		if nw == nil { free(bw); return nil }
		if p, ok := at.?; ok { platform.move_window(nw, p.x, p.y) }
		bw.headless_shared = true   // renders into the primary offscreen target (no Surface of its own)
	} else {
		nw = platform.open_window(APP_NAME, size, on_frame = window_on_frame, transparent = fixed, integrated_title = wchrome.cfg.integrated)
		if nw == nil { free(bw); return nil }
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
		ok := render.surface_init(&app.r, &bw.surf, nw.hwnd, nw.size, transparent = fixed, fixed_size = fixed_surface_size(app, nw.hwnd))   // (in place: see render.surface_create)
		if !ok {
			free(bw)
			platform.destroy_window(nw)
			return nil
		}
	}
	window_ids += 1
	bw.id, bw.win, bw.ui = window_ids, nw, new(ui.State)
	bw.opened = time.tick_now()
	nw.user = bw
	ui.init(bw.ui, &app.fonts, &app.theme)
	bw.ui.icon_font = app.icons
	bw.ui.mono_font = active_window(app).ui.mono_font
	autoscroll_toolkit_setup(bw.ui)   // page_autoscroll.odin: middle-click autoscroll for this window's toolkit regions
	ui.use(active_window(app).ui)
	bw.frames_requested = 4
	devtools_view_init(app, &bw.own.devtools, false)   // devtools.odin: closed until asked for in this window (or a tab brings its own)
	append(&app.windows, bw)
	if show && !app.headless { window_show(bw) }
	return bw
}

// Closes the window and the tabs it still has (their pages end with them: this is not a move). The last window is not closed
// here: the loop ends and the browser's own shutdown closes it.
window_close :: proc(app: ^App, w: ^Browser_Window) {
	if w == nil || len(app.windows) <= 1 { return }
	was_front := app.front == w
	// its tabs go with it (made active: what a tab's end reads is its window's), then what it owns
	window_activate(app, w)
	for len(w.tabs) > 0 {
		t := pop(&w.tabs)
		tab_discard(app, t)
	}
	window_own_destroy(app, &w.own)
	window_deactivate(app)
	delete(w.tabs)
	tab_groups_destroy(&w.groups)
	ui.field_destroy(&w.address)
	// the swap chain: another window's becomes the renderer's own when it is the primary one that goes
	idx := -1
	for x, i in app.windows { if x == w { idx = i } }
	ordered_remove(&app.windows, idx)
	if w.primary {
		heir := app.windows[0]
		if heir.headless_shared {
			// headless: no surfaces, one offscreen target. The heir simply becomes the primary and keeps rendering into it.
			heir.headless_shared, heir.primary = false, true
		} else {
			render.surface_use(&app.r, &heir.surf)      // the renderer has the heir's chain; the heir's record has the primary's
			render.surface_destroy(&app.r, &heir.surf)  // ... which is released: the heir is the primary now
			heir.primary = true
		}
	} else if !w.headless_shared {
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
	request_frames(app, 2)
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
	return w.frames_requested != 0 || ui.needs_frame(w.ui) || ui.wake_due(w.ui) || paint || events_waiting
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
	any_cause := devtools_windows_busy(app)
	wake := 0
	for w, i in order {
		window_activate(app, w)
		w.minimized = len(app.windows) > 1 && platform.is_minimized(w.win)
		causes[i] = window_has_cause(app, w)
		any_cause ||= causes[i]
		if ms := ui.wake_in_ms(w.ui); ms > 0 && !w.minimized && (wake == 0 || ms < wake) { wake = ms }
	}
	idled := false
	if !any_cause {
		timeout := devtools_windows_timeout(app, wake)
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
			for tab in w.tabs { if tab.page != nil { page.set_page_visible(tab.page, false) } }
			devtools_window_tick(app)   // (its developer tools' window, when it has one, is not minimized with it)
			continue
		}
		window_activate(app, w)
		frame(app, idled || !causes[i])
		window_activate(app, w)
		devtools_window_tick(app)   // devtools_window.odin: this window's developer tools' window
		if w.frames_requested > 0 { w.frames_requested -= 1 }
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
				if len(w.tabs) == 0 { tab_open_new(app) }
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
// `slot` (a tab dropped on another window's tabs: tab_drag.odin): the group it joins there and whether it is pinned (else it
// is in no group, pinned or not as it was). false: nothing was done (the tab or the window is unknown).
tab_move :: proc(app: ^App, t: ^Tab, dest: ^Browser_Window, at := -1, devtools_follow := true, slot: Maybe(Drop_Slot) = nil) -> bool {
	src, si := window_of_tab(app, t)
	if src == nil || dest == nil { return false }
	st, dt := window_tabs(app, src), window_tabs(app, dest)
	sc := window_current(app, src)
	if src == dest {
		to := at < 0 ? len(st) - 1 : min(at, len(st) - 1)
		sc^ = list_move(st[:], si, to, sc^)
		tabs_fix(app, src)   // tab_groups.odin: pinned first, groups together
		return true
	}
	showing := sc^ == si
	t.group = 0   // (a group is its window's)
	if s, ok := slot.?; ok { t.group, t.pinned = s.pinned ? 0 : s.group, s.pinned }
	sc^ = tab_list_take(st, sc^, si)
	dc := window_current(app, dest)
	dc^, _ = tab_list_put(dt, dc^, at, t, true)
	if len(st) > 0 { ui.field_set(window_address(app, src), st[sc^].url) } else { src.closing = true }
	ui.field_set(window_address(app, dest), t.url)
	if devtools_follow && showing { devtools_follow_tab(app, src, dest) }   // devtools.odin
	if len(st) > 0 { tabs_fix(app, src) }
	tabs_fix(app, dest)
	window_request(app, src, 3)
	window_request(app, dest, 3)
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

// The loop ended: the windows other than the front one give up what they own (the front window's is freed by the browser's
// own steps, which read it as the active window's: urlbar_destroy, page_cursor_shutdown, forms_shell_destroy...).
windows_shutdown_begin :: proc(app: ^App) {
	front := window_front(app)
	for w in app.windows {
		if w == front { continue }
		window_activate(app, w)
		window_own_destroy(app, &w.own)
	}
	window_activate(app, front)
	sync.atomic_store(&wake_target, nil)
}

// Every tab was freed: the lists forget them.
windows_forget_tabs :: proc(app: ^App) {
	clear(&app.bare.tabs)
	for w in app.windows { clear(&w.tabs) }   // (the lists are freed with the windows: windows_destroy)
}

// The toolkit states of every window, and their address fields.
windows_destroy_ui :: proc(app: ^App) {
	for w in app.windows {
		ui.field_destroy(&w.address)
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
		delete(w.title)
		delete(w.tabs)
		tab_groups_destroy(&w.groups)
		free(w.ui)
		platform.destroy_window(w.win)
		free(w)
	}
	delete(app.windows)
	tab_groups_destroy(&app.bare.groups)
	delete(pass_order); delete(pass_causes)
	pass_order, pass_causes = nil, nil
	app.windows = nil
	app.active, app.front = nil, nil
}
