package browser

// Wren's backend of the views' windows (ui.View_Windows: the toolkit's src/md/features/views.md, section 4.1). A view
// the person puts in a window of its own (the developer tools "in a window") gets a platform window, a render surface on
// the renderer's device and a ui.State of its own, made as a browser window's are. Wren has its own loop and its own
// windows, so it does not use gt:host's backend; this file is what that backend is for a host.Host program.
//
// Each view's window belongs to the browser window whose State owns the view (View_Window_Ask.owner_state). Its frames
// come after each frame of that browser window (view_windows_after, from windows_pass and window_frame), with that
// browser window still active: a view's build reads its owner's state (dev(), current_tab) as it does as a panel of
// the browser window. Everything runs on the interface thread; the only system calls are those Wren's own windows make
// (open, show, present), never in a build: ui.views_windows_step calls `open`, `show`, `hide` and `close` between frames.

import "core:slice"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import config "../../ext/gui_toolkit/src/config"

// A view's window: its State (the toolkit builds the view in it: ui.views_window_build), its platform window, its
// swap chain, and the browser window it belongs to.
View_Window :: struct {
	state:     ui.State,
	win:       ^platform.Window,
	surf:      render.Surface,
	has_surf:  bool,      // a swap chain of its own (a headless Wren's draws into the one offscreen target)
	owner:     int,       // the Browser_Window.id whose State owns the view (ids are never reused: it cannot dangle)
	shown:     bool,      // the toolkit's step showed it: from now on its frames draw (before, its layouts are unseen)
	busy:      bool,      // events came that have not been built, or its State asked for another frame
	closing:   bool,      // the system asked it to close: the view went back home, the next step closes it
	size_seen: [2]int,    // the window's size at its last drawn frame
	latency:   int,       // the most frames its swap chain may queue now (pacer_latency)
}

// The backend given to the program's Views (views_start).
view_windows_backend :: proc(app: ^App) -> ui.View_Windows {
	return {open = view_window_open, show = view_window_show, hide = view_window_hide, close = view_window_close, user = app}
}

// The browser window whose State is `s` (nil: none of them).
@(private = "file")
browser_window_of_state :: proc(app: ^App, s: ^ui.State) -> ^Browser_Window {
	if s == nil { return nil }
	for w in app.windows { if w.ui == s { return w } }
	return nil
}

// The view's window whose State is `s` (nil: none).
view_window_of_state :: proc(app: ^App, s: ^ui.State) -> ^View_Window {
	if s == nil { return nil }
	for vw in app.view_windows { if &vw.state == s { return vw } }
	return nil
}

@(private = "file")
view_window_open :: proc(user: rawptr, ask: ui.View_Window_Ask) -> (state: ^ui.State, win: ^platform.Window, handle: rawptr) {
	app := (^App)(user)
	owner := browser_window_of_state(app, ask.owner_state)
	if owner == nil { return }
	vw := new(View_Window)
	// (made as a browser window is: browser.window.fixed_surface, the program's decorations or the system's as its owner's)
	fixed := config.bool_of(&app.prefs, "browser.window.fixed_surface")
	// (its user is the record itself: the platform window goes before the record, so no call comes after it is freed)
	on_frame := proc(user: rawptr) { view_window_loop_frame(the_app, (^View_Window)(user)) }
	w: ^platform.Window
	if app.headless {
		// (no window of the system: drawn all the same, into the one offscreen target, for wren ctl)
		sc := display_scale_of(app)
		w = platform.open_window_offscreen(ask.title, {int(f32(ask.size.x) * sc + 0.5), int(f32(ask.size.y) * sc + 0.5)}, dpi_scale = sc, user = vw, on_frame = on_frame)
		if w == nil { free(vw); return }
		if at, ok := ask.at.?; ok { platform.move_window(w, at.x, at.y) }
	} else {
		w = platform.open_window(ask.title, ask.size, user = vw, on_frame = on_frame, transparent = fixed, integrated_title = ask.integrated_title)
		if w == nil { free(vw); return }
		platform.set_square_corners(w, app.wchrome.cfg.square_corners)
		if at, ok := ask.at.?; ok { platform.move_window(w, at.x, at.y) }
		if w.size.x <= 0 || w.size.y <= 0 { native_size_now(w) }   // (the size comes with the first size event, still to be handled)
		// (in place, never through a local: see window_open)
		if !render.surface_init(&app.r, &vw.surf, platform.native_surface_handles(w), w.size, transparent = fixed, fixed_size = fixed_surface_size(app, w)) {
			platform.destroy_window(w)
			free(vw)
			return
		}
		vw.has_surf = true
	}
	vw.win, vw.owner, vw.latency, vw.size_seen, vw.busy = w, owner.id, 1, w.size, true
	ui.init(&vw.state, &app.fonts, &app.theme)
	chrome_a11y_init(&vw.state)   // (the caption buttons' names are each State's)
	vw.state.icon_font = app.lucide
	vw.state.menu_icon_font = app.lucide
	vw.state.mono_font = owner.ui.mono_font
	// (ui.init selected it: the State in use stays the owner's)
	ui.use(owner.ui)
	append(&app.view_windows, vw)
	return &vw.state, w, vw
}

@(private = "file")
view_window_show :: proc(user: rawptr, handle: rawptr) {
	app := (^App)(user)
	vw := (^View_Window)(handle)
	vw.shown, vw.busy = true, true
	if windows_shown(app) {
		platform.show_window(vw.win)
		platform.raise_window(vw.win)
	}
}

// (its owner hid: off the screen, its State kept)
@(private = "file")
view_window_hide :: proc(user: rawptr, handle: rawptr) {
	app := (^App)(user)
	vw := (^View_Window)(handle)
	vw.shown = false
	if windows_shown(app) { platform.hide_window(vw.win) }
}

// (called by the toolkit's step, or when the owner's State goes: never from inside this window's frame)
@(private = "file")
view_window_close :: proc(user: rawptr, handle: rawptr) {
	app := (^App)(user)
	vw := (^View_Window)(handle)
	for x, i in app.view_windows {
		if x == vw { ordered_remove(&app.view_windows, i); break }
	}
	ui.destroy(&vw.state)
	if vw.has_surf { render.surface_destroy(&app.r, &vw.surf) }
	platform.destroy_window(vw.win)
	free(vw)
	if a := app.active; a != nil && a.ui != nil { ui.use(a.ui) }
}

// Whether a view's window has something to build now on its own: input, an animation or a wake of its State, a repaint.
@(private = "file")
view_window_busy :: proc(vw: ^View_Window) -> bool {
	return vw.busy || len(vw.win.events) > 0 || vw.win.paint_requested || ui.view_window_due(&vw.state)
}

// Whether any view's window has something to build (the loop does not sleep).
view_windows_busy :: proc(app: ^App) -> bool {
	for vw in app.view_windows { if view_window_busy(vw) { return true } }
	return false
}

// The wait of the main loop (ms, 0 = none) shortened by what the views' windows' States ask for (a caret, a tooltip).
view_windows_timeout :: proc(app: ^App, timeout: int) -> int {
	timeout := timeout
	for vw in app.view_windows {
		t := ui.wake_in_ms(&vw.state)
		if t > 0 && (timeout <= 0 || t < timeout) { timeout = t }
	}
	return timeout
}

// After a frame of browser window `bw` (active, outside any build), and after a pass that made none for it: the
// toolkit's step of the windows of the views it owns (open, show, move, close), then a frame of each of them. When
// `bw` built (`owner_built`), each builds too, whatever woke `bw` may be what they show (views.md 4.1, decision 10),
// unless that build came only from the pointer moving over `bw`; else each builds when it is due on its own.
view_windows_after :: proc(app: ^App, bw: ^Browser_Window, owner_built: bool) {
	if ui.building() || bw == nil || bw.ui == nil { return }
	ui.views_windows_step(bw.ui)
	ui.use(bw.ui)
	quiet := !owner_built || ui.pointer_only_build(bw.ui)
	// (a frame may open or close another: the list is read again each time)
	for i := 0; i < len(app.view_windows); i += 1 {
		vw := app.view_windows[i]
		if vw.owner != bw.id { continue }
		if quiet && !view_window_busy(vw) { continue }
		view_window_frame(app, bw, vw)
	}
}

// The window's own on_frame, called while the system owns the loop for it (a resize by its edges, a move, its menu):
// its browser window goes on too, so the page, its timers and its loads do not stop while the view's window is dragged.
@(private = "file")
view_window_loop_frame :: proc(app: ^App, vw: ^View_Window) {
	if app == nil || !slice.contains(app.view_windows[:], vw) { return }
	bw := window_by_id(app, vw.owner)
	if bw == nil { return }
	// (not inside a frame's page phase, build or drawing: the frame gate of windows.odin. The view's input may run
	// the page's scripts: not in the page phase either)
	g := platform.frame_gate()
	if g.stage == .Work || !platform.frame_admits(g.stage, g.kind, .Light) || ui.building() {
		platform.frame_gate_defer(g)
		vw.win.paint_requested = true
		return
	}
	prev := app.active
	window_activate(app, bw)
	defer if prev != nil && prev != bw && slice.contains(app.windows[:], prev) { window_activate(app, prev) }
	if !app.chrome_frames.nested && !platform.is_closed(bw.win) {
		app.pass_first = true
		frame(app, true)   // (idled: it returns at once when there is nothing to draw nor to run)
		if bw.frames_requested > 0 { bw.frames_requested -= 1 }
		window_activate(app, bw)
	}
	vw.busy = true   // (the system asked this window for a picture: it builds whatever its owner did)
	view_windows_after(app, bw, false)
}

// A frame of a view's window, its owner `bw` active. Hidden (before the toolkit's step shows it), its layouts are
// built and nothing is drawn: a picture on a surface with no role yet is a protocol error on Wayland.
@(private = "file")
view_window_frame :: proc(app: ^App, bw: ^Browser_Window, vw: ^View_Window) {
	w := vw.win
	events := make([dynamic]platform.Event, 0, len(w.events), context.temp_allocator)
	for e in w.events { append(&events, e) }
	clear(&w.events)
	asked_close := platform.is_closed(w)
	for e in events { if e.kind == .Close { asked_close = true } }
	if asked_close {
		// (the system's close re-attaches the view; the toolkit closes the window at the next step of its owner)
		if !vw.closing {
			vw.closing = true
			ui.view_window_close_asked(&vw.state)
			window_request(app, bw, 2)
		}
		vw.busy = false
		return
	}
	vw.busy = false
	w.paint_requested = false
	if w.size.x <= 0 || w.size.y <= 0 || platform.is_minimized(w) { return }
	// a Light frame of the gate (windows.odin): after its owner's frame, or from its own window's loop of the system
	gate := platform.frame_gate()
	gate_token, admitted := platform.frame_gate_begin(gate, .Light)
	if !admitted { w.paint_requested = true; return }
	defer platform.frame_gate_end(gate, gate_token)
	draws := vw.shown
	frame_start := qpc()
	if draws && vw.has_surf { render.surface_use(&app.r, &vw.surf) }
	defer if draws && vw.has_surf { render.surface_use(&app.r, &vw.surf) }
	if draws { render.resize(&app.r, w.size) }
	size := draw.Vec2{f32(w.size.x), f32(w.size.y)}
	platform.frame_gate_stage(gate, .Building)
	ui.use(&vw.state)   // (the pointer devtools_events reads is this window's)
	evs := devtools_events(app, events[:], &vw.state)   // devtools.odin: their text size, where they are built
	ui.begin_build(&vw.state, {
		window_size = size, events = evs, dt = pacer_of(app).dt, animations = os_animations_enabled(app),
		dpi_scale = display_scale_of(app, w), base = chrome_frame_style(app), clipboard_set = ui.window_clipboard_set,
		disable_zoom = true, window = w, frame_ms = pacer_of(app).frame_ms,
		inactive = !w.active,
	})
	ui.views_window_build()
	ui.end_build()
	if ui.needs_frame(&vw.state) { vw.busy = true }
	platform.set_cursor(w, ui.cursor(&vw.state))
	// (a change made in it is seen by its owner's next build: views.md 2.3, rule 2)
	if len(evs) > 0 { window_request(app, bw, 2) }
	if draws {
		platform.frame_gate_stage(gate, .Drawing)
		draw.begin_frame(&app.dc, size)
		render.frame_begin(&app.r, {0, 0, 0, 1})
		ui.draw_tree(&vw.state, &app.dc)
		draw.end_frame(&app.dc)
		// a step of a resize is shown at once, as the browser window's is (pacing.odin): waiting for the screen would hold
		// the thread, and the browser window with it, for a refresh at every step; so is a drag inside it on a variable
		// refresh screen (its frames are paced by its browser window's)
		resizing := w.size != vw.size_seen && bw.presented
		vw.size_seen = w.size
		at_once := resizing || (ui.active_key() != 0 && pacer_of(app).cadence.variable)
		pacer_latency(app, &vw.latency, at_once)
		present_start := qpc()
		platform.frame_gate_stage(gate, .Presenting)
		render.frame_end(&app.r, !at_once)
		prof_window_frame(frame_start, present_start)   // prof.odin: the window's frames of a profile run
	}
	ui.use(bw.ui)
}
