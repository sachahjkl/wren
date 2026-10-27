package browser

// The developer tools in a window of their own. A native window is opened for the browser window whose developer tools they are
// (each browser window has its own: Window_Own.devtools.win); the renderer draws to it as a surface of its own device (toolkit
// render.surface_*), with a UI state of its own (toolkit ui.State), so that the panel is built and drawn as it is when docked, by
// the same code, and the browser window gives its room back to the page. Everything the panel reads (the tab's console, request
// log, document) is the shell's, unchanged: it shows the current tab of its browser window. Closing the window docks the panel
// again; closing the browser window closes it. The window is driven by the main loop (devtools_window_tick after each frame of
// its browser window, which is then the active one, and the window's own on_frame while Windows owns the loop for a resize).

import "core:fmt"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:host"

Dev_Window :: struct {
	win:    ^platform.Window,
	surf:   render.Surface,
	ui:     ui.State,
	title:  string,           // owned: what the window's title was set to
	busy:   bool,             // events came that have not been drawn
	size_seen: [2]int,        // the window's size at its last frame
	latency:   int,           // the most frames its swap chain may queue now (pacer_latency; 1 when it is made)
	owner:     int,           // the browser window whose developer tools these are (Browser_Window.id)
}

// Whether the active window's developer tools are in a window of their own (or about to be).
devtools_detached :: proc() -> bool { return dev().win != nil || dev().want_win }

// Opens the window and moves the panel into it.
devtools_detach :: proc(app: ^App) {
	d := dev()
	if d.win != nil || d.want_win { return }
	d.want_win = true   // made after the frame that asked: the toolkit's state must not change under a build
	request_frames(app, 2)
}

@(private = "file")
devtools_window_make :: proc(app: ^App) {
	d := dev()
	d.want_win = false
	if d.win != nil { return }
	owner := active_window(app)
	// made as the main window is (browser.window.fixed_surface): no GDI surface, a composition swap chain of the monitor's size shown
	// 1:1 and clipped, so that resizing it cuts the last frame instead of stretching it
	fixed := config.bool_of(&app.prefs, "browser.window.fixed_surface")
	// (on_frame's user is the browser window's id: the panel's window is closed before its browser window is freed, but an id
	// cannot dangle)
	w := platform.open_window("Wren Developer Tools", {1100, 760}, user = rawptr(uintptr(owner.id)), on_frame = proc(user: rawptr) { devtools_window_loop_frame(the_app, int(uintptr(user))) }, transparent = fixed)
	if w == nil { ui.toast(.Warn, "The window could not be opened"); return }
	if !app.headless {   // (a headless browser shows no window: the panel's is drawn all the same, for wren ctl)
		platform.show_window(w)
		win.SetWindowPos(w.hwnd, win.HWND_TOP, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE)   // above the browser window it came from
	}
	if w.size.x <= 0 || w.size.y <= 0 {
		// (the size comes with the first WM_SIZE, still to be handled)
		cr: win.RECT
		win.GetClientRect(w.hwnd, &cr)
		w.size = {max(int(cr.right - cr.left), 1), max(int(cr.bottom - cr.top), 1)}
	}
	// made where it lives, not returned by value (see render.surface_create: a Surface in a local is a compile-time trap)
	dw := new(Dev_Window)
	ok := render.surface_init(&app.r, &dw.surf, w.hwnd, w.size, transparent = fixed, fixed_size = fixed_surface_size(app, w.hwnd))   // (window_chrome.odin)
	if !ok {
		free(dw)
		platform.destroy_window(w)
		ui.toast(.Warn, "The window could not be drawn (this needs the Direct3D 11 renderer)")
		return
	}
	dw.win, dw.latency, dw.size_seen, dw.owner = w, 1, w.size, owner.id
	pal, pal_ok := ui.palette_named(app.cfg.ui_theme)
	platform.set_dark_title(w, pal_ok ? pal.dark : true)
	ui.init(&dw.ui, &app.fonts, &app.theme)
	dw.ui.icon_font = app.icons
	ui.use(active_window(app).ui)
	d.win = dw
	d.visible = true
	network_sync_observer()
	console_arm_all(app)
	request_frames(app, 4)
	dw.busy = true
}

// Closes the active window's developer tools' window; the panel is docked again.
devtools_attach :: proc(app: ^App) {
	d := dev()
	d.want_win = false
	dw := d.win
	if dw == nil { return }
	d.win = nil
	ui.destroy(&dw.ui)
	ui.use(active_window(app).ui)
	render.surface_destroy(&app.r, &dw.surf)
	platform.destroy_window(dw.win)
	delete(dw.title)
	free(dw)
	request_frames(app, 4)
}

devtools_window_destroy :: proc(app: ^App) { devtools_attach(app) }

// The tab the developer tools of `src` were showing moved to `dest` (tab_move): they go with it, docked or in their window, when
// `dest` has none open (`dest`'s, closed, take their place in `src`). When `dest` shows its own, each window keeps its own: those
// of `dest` show the tab that came.
devtools_follow_tab :: proc(app: ^App, src, dest: ^Browser_Window) {
	a, b := &src.own.devtools, &dest.own.devtools
	if src == dest || !a.visible || b.visible { return }
	// a panel's timer names its window: stopped, the panel sets it again when it is built
	for d in ([2]^Devtools{a, b}) {
		if d.net.tick != base.NIL_HANDLE { host.clear_timer(&app.loop, d.net.tick); d.net.tick = base.NIL_HANDLE }
		if d.mem.tick != base.NIL_HANDLE { host.clear_timer(&app.loop, d.mem.tick); d.mem.tick = base.NIL_HANDLE }
	}
	a^, b^ = b^, a^
	for d, i in ([2]^Devtools{a, b}) {
		if d.win == nil { continue }
		owner := i == 0 ? src.id : dest.id
		d.win.owner = owner
		d.win.win.user = rawptr(uintptr(owner))
	}
	if net_media.owner == a { net_media.owner = b } else if net_media.owner == b { net_media.owner = a }
	window_request(app, src, 3)
	window_request(app, dest, 3)
}

// Whether a developer tools' window has something to draw now (input, an animation of the toolkit).
@(private = "file")
dev_window_busy :: proc(dw: ^Dev_Window) -> bool {
	if dw == nil { return false }
	return dw.busy || len(dw.win.events) > 0 || ui.needs_frame(&dw.ui) || dw.win.paint_requested
}

// Whether any browser window's developer tools have a window of their own with something to draw, or one to make.
devtools_windows_busy :: proc(app: ^App) -> bool {
	for w in app.windows {
		d := &w.own.devtools
		if d.want_win || dev_window_busy(d.win) { return true }
	}
	return false
}

// The wait of the main loop (ms, 0 = none) shortened by what the developer tools' windows' toolkits ask for (a caret, a tooltip
// delay).
devtools_windows_timeout :: proc(app: ^App, timeout: int) -> int {
	timeout := timeout
	for w in app.windows {
		dw := w.own.devtools.win
		if dw == nil { continue }
		t := ui.wake_ms(&dw.ui)
		if t > 0 && (timeout <= 0 || t < timeout) { timeout = t }
	}
	return timeout
}

// After each frame of a browser window (the active one): its developer tools' window, when it has input, or the shell asked for
// frames.
devtools_window_tick :: proc(app: ^App) {
	d := dev()
	if d.want_win { devtools_window_make(app) }
	if d.win == nil { return }
	if active_window(app).frames_requested > 0 || dev_window_busy(d.win) { devtools_window_frame(app) }
}

// The window's own on_frame, called while Windows owns the loop for it (a resize by its edges, a move, its menu): its browser
// window goes on as well, so the page, its timers and its loads do not stop while the panel's window is dragged. Not from a chrome
// frame: nothing of the page may run there (shell_frames.odin).
devtools_window_loop_frame :: proc(app: ^App, owner: int) {
	if app == nil { return }
	bw, d := devtools_of_window_id(app, owner)
	if bw == nil || d.win == nil { return }
	// (not inside a frame's page phase, build or drawing: windows.odin, the frame gate. Its frame is a Light one, but not in the
	// page phase either: the panel's input (the console) may run the page's scripts)
	g := platform.frame_gate()
	if g.stage == .Work || !platform.frame_admits(g.stage, g.kind, .Light) || ui.building() {
		platform.frame_gate_defer(g)
		d.win.win.paint_requested = true
		return
	}
	// its browser window is the active one for the length of these frames, then the one that was is again (window_on_frame)
	prev := app.active
	window_activate(app, bw)
	defer if prev != nil && prev != bw && slice.contains(app.windows[:], prev) { window_activate(app, prev) }
	devtools_window_frame(app)
	if chrome_frames.nested || platform.is_closed(bw.win) { return }
	app.pass_first = true
	frame(app, true)   // (idled: it returns at once when there is nothing to draw nor to run)
	if bw.frames_requested > 0 { bw.frames_requested -= 1 }
}

// A frame of the active browser window's developer tools' window.
devtools_window_frame :: proc(app: ^App) {
	dw := dev().win
	if dw == nil { return }
	w := dw.win
	events := make([dynamic]platform.Event, 0, len(w.events), context.temp_allocator)
	for e in w.events { append(&events, e) }
	clear(&w.events)
	for e in events { if e.kind == .Close { devtools_attach(app); return } }
	if platform.is_closed(w) { devtools_attach(app); return }
	dw.busy = false
	if w.size.x <= 0 || w.size.y <= 0 || platform.is_minimized(w) { return }
	t := current_tab(app)
	if t == nil || t.kind != .Web { return }
	// a Light frame of the gate (windows.odin): after the main window's frame, or from its own window's loop of the system
	gate := platform.frame_gate()
	gate_token, admitted := platform.frame_gate_begin(gate, .Light)
	if !admitted { w.paint_requested = true; return }
	defer platform.frame_gate_end(gate, gate_token)
	title := t.title != "" ? t.title : t.url
	if title != dw.title {
		delete(dw.title)
		dw.title = strings.clone(title)
		platform.set_title(w, fmt.tprintf("%s - Wren Developer Tools", title))
	}

	frame_start := qpc()
	size := draw.Vec2{f32(w.size.x), f32(w.size.y)}
	render.surface_use(&app.r, &dw.surf)
	defer render.surface_use(&app.r, &dw.surf)
	render.resize(&app.r, w.size)
	base_style := chrome_frame_style(app)
	platform.frame_gate_stage(gate, .Building)
	evs := devtools_events(app, events[:], true)
	ui.begin_build(&dw.ui, {
		window_size = size, events = evs, dt = pacer_of(app).dt, animations = os_animations_enabled(app),
		dpi_scale = ui_scale_of(app, w), base = base_style, clipboard_get = clip_get, clipboard_set = clip_set,
		disable_zoom = true, window = w, frame_ms = pacer_of(app).frame_ms,
	})
	devtools_panel(app, t, false, {width = ui.fill(), height = ui.fill()}, fill = size)
	ui.end_build()
	if ui.needs_frame(&dw.ui) { dw.busy = true }
	platform.frame_gate_stage(gate, .Drawing)
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&dw.ui, &app.dc)
	draw.end_frame(&app.dc)
	// a step of a resize is shown at once, as the main window's is (pacing.odin): waiting for the screen would hold the thread, and
	// the main window with it, for a refresh at every step
	resizing := w.size != dw.size_seen && active_window(app).presented   // (a Resize_Step of the cadence model: platform/pacing.odin)
	dw.size_seen = w.size
	pacer_latency(app, &dw.latency, resizing)   // (pacing.odin: two frames may queue during a resize step, as for the main window)
	present_start := qpc()
	platform.frame_gate_stage(gate, .Presenting)
	render.frame_end(&app.r, !resizing)
	prof_window_frame(frame_start, present_start)   // prof.odin: the window's frames of a profile run
	ui.use(active_window(app).ui)
}



