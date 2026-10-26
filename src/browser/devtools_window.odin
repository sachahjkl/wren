package browser

// The developer tools in a window of their own. A second native window is opened; the renderer draws to it as a second
// surface of its own device (toolkit render.surface_*), with a UI state of its own (toolkit ui.State), so that the panel is
// built and drawn as it is when docked, by the same code, and the main window gives its room back to the page. Everything
// the panel reads (the tab's console, request log, document) is the shell's, unchanged. Closing the window docks the panel
// again. The window is driven by the main loop (devtools_window_tick after each frame, and the window's own on_frame while
// Windows owns the loop for a resize).

import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

Dev_Window :: struct {
	win:    ^platform.Window,
	surf:   render.Surface,
	ui:     ui.State,
	title:  string,           // owned: what the window's title was set to
	busy:   bool,             // events came that have not been drawn
	size_seen: [2]int,        // the window's size at its last frame
	latency:   int,           // the most frames its swap chain may queue now (pacer_latency; 1 when it is made)
}

@(private = "file") dev_win: ^Dev_Window
@(private = "file") dev_want: bool

devtools_detached :: proc() -> bool { return dev_win != nil || dev_want }

// Opens the window and moves the panel into it.
devtools_detach :: proc(app: ^App) {
	if dev_win != nil || dev_want { return }
	dev_want = true   // made after the frame that asked: the toolkit's state must not change under a build
	app.frames_requested = max(app.frames_requested, 2)
}

@(private = "file")
devtools_window_make :: proc(app: ^App) {
	dev_want = false
	if dev_win != nil { return }
	// made as the main window is (browser.window.fixed_surface): no GDI surface, a composition swap chain of the monitor's size shown
	// 1:1 and clipped, so that resizing it cuts the last frame instead of stretching it
	fixed := config.bool_of(&app.prefs, "browser.window.fixed_surface")
	w := platform.open_window("Wren Developer Tools", {1100, 760}, user = app, on_frame = proc(user: rawptr) { devtools_window_loop_frame((^App)(user)) }, transparent = fixed)
	if w == nil { ui.toast(.Warn, "The window could not be opened"); return }
	platform.show_window(w)
	win.SetWindowPos(w.hwnd, win.HWND_TOP, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE)   // above the browser window it came from
	if w.size.x <= 0 || w.size.y <= 0 {
		// (the size comes with the first WM_SIZE, still to be handled)
		cr: win.RECT
		win.GetClientRect(w.hwnd, &cr)
		w.size = {max(int(cr.right - cr.left), 1), max(int(cr.bottom - cr.top), 1)}
	}
	surf, ok := render.surface_create(&app.r, w.hwnd, w.size, transparent = fixed, fixed_size = fixed_surface_size(app, w.hwnd))   // (window_chrome.odin)
	if !ok {
		platform.destroy_window(w)
		ui.toast(.Warn, "The window could not be drawn (this needs the Direct3D 11 renderer)")
		return
	}
	dw := new(Dev_Window)
	dw.win, dw.surf, dw.latency, dw.size_seen = w, surf, 1, w.size
	pal, pal_ok := ui.palette_named(app.cfg.ui_theme)
	platform.set_dark_title(w, pal_ok ? pal.dark : true)
	ui.init(&dw.ui, &app.fonts, &app.theme)
	dw.ui.icon_font = app.icons
	ui.use(app.ui_state)
	dev_win = dw
	dev.visible = true
	platform.show_window(w)
	app.frames_requested = max(app.frames_requested, 4)
	dw.busy = true
}

// Closes the window; the panel is docked again.
devtools_attach :: proc(app: ^App) {
	dev_want = false
	dw := dev_win
	if dw == nil { return }
	dev_win = nil
	ui.destroy(&dw.ui)
	ui.use(app.ui_state)
	render.surface_destroy(&app.r, &dw.surf)
	platform.destroy_window(dw.win)
	delete(dw.title)
	free(dw)
	app.frames_requested = max(app.frames_requested, 4)
}

devtools_window_destroy :: proc(app: ^App) { devtools_attach(app) }

// Whether the window has something to draw now (input, an animation of the toolkit).
devtools_window_busy :: proc() -> bool {
	dw := dev_win
	if dw == nil { return false }
	return dw.busy || len(dw.win.events) > 0 || ui.needs_frame(&dw.ui) || dw.win.paint_requested
}

// The wait of the main loop (ms, 0 = none) shortened by what the window's toolkit asks for (a caret, a tooltip delay).
devtools_window_timeout :: proc(timeout: int) -> int {
	dw := dev_win
	if dw == nil { return timeout }
	t := ui.wake_ms(&dw.ui)
	if t > 0 && (timeout <= 0 || t < timeout) { return t }
	return timeout
}

// After each frame of the main window: the panel's window, when it has input, or the shell asked for frames.
devtools_window_tick :: proc(app: ^App) {
	if dev_want { devtools_window_make(app) }
	if dev_win == nil { return }
	if app.frames_requested > 0 || devtools_window_busy() { devtools_window_frame(app) }
}

// The window's own on_frame, called while Windows owns the loop for it (a resize by its edges, a move, its menu): the main window
// goes on as well, so the page, its timers and its loads do not stop while the panel's window is dragged. Not from a chrome frame:
// nothing of the page may run there (shell_frames.odin).
devtools_window_loop_frame :: proc(app: ^App) {
	// (not inside a frame's page phase, build or drawing: windows.odin, Frame_Stage)
	if frame_stage == .Busy || ui.building() { if dev_win != nil { dev_win.win.paint_requested = true }; return }
	devtools_window_frame(app)
	if chrome_frames.nested || platform.is_closed(app.win) { return }
	app.pass_first = true
	frame(app, true)   // (idled: it returns at once when there is nothing to draw nor to run)
	if app.frames_requested > 0 { app.frames_requested -= 1 }
}

devtools_window_frame :: proc(app: ^App) {
	dw := dev_win
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
	evs := devtools_events(app, events[:], true)
	ui.begin_build(&dw.ui, {
		window_size = size, events = evs, dt = pacer.dt, animations = os_animations_enabled(app),
		dpi_scale = ui_scale_of(app), base = base_style, clipboard_get = clip_get, clipboard_set = clip_set,
		disable_zoom = true, window = w, frame_ms = pacer.frame_ms,
	})
	devtools_panel(app, t, false, {width = ui.fill(), height = ui.fill()}, fill = size)
	ui.end_build()
	if ui.needs_frame(&dw.ui) { dw.busy = true }
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&dw.ui, &app.dc)
	draw.end_frame(&app.dc)
	// a step of a resize is shown at once, as the main window's is (pacing.odin): waiting for the screen would hold the thread, and
	// the main window with it, for a refresh at every step
	resizing := w.size != dw.size_seen && pacer.cfg.resize_immediate && app.presented   // (browser.frame.resize_immediate)
	dw.size_seen = w.size
	pacer_latency(app, &dw.latency, resizing)   // (pacing.odin: two frames may queue during a resize step, as for the main window)
	present_start := qpc()
	render.frame_end(&app.r, !resizing)
	prof_window_frame(frame_start, present_start)   // prof.odin: the window's frames of a profile run
	ui.use(app.ui_state)
}



