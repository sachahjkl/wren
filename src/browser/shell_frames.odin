package browser

// Chrome frames while a page holds the interface thread.
//
// A page's work runs on the window's thread: its scripts (JavaScript and Wasm modules), events, timers and animation
// frames during the frame's "page phase" (loop tasks, page input, animation frames), then its style, layout and paint.
// A script that runs for 200 ms used to freeze the whole window for 200 ms: tabs, address bar, menus, scrolling and
// resizing. Now the chrome preempts the page: while a guest call runs in the page phase, the Wasm engine's epoch
// callback hands the thread to `shell_preempt` (wasm.set_preempt_hook) at every tick, and once the page has held the
// thread longer than browser.shell.preempt_after_ms, a *chrome frame* is drawn there, between two instructions of the
// guest, at the frame rate:
//   * the chrome is built and drawn as usual, with the input that came meanwhile;
//   * the page area shows the page's last frame (a copy of its pixels kept on the GPU after each paint: Page_Snapshot),
//     anchored at the top left when the window is resized, never stretched; the canvas color fills what it does not
//     cover;
//   * the wheel over the page scrolls that copy at once (asynchronous scrolling of the document, as Chromium's and
//     Firefox's compositors do); the page takes the position when it is done;
//   * input meant for the page (presses, keys while the page has the keyboard) waits, in order, for the next full
//     frame (`deferred`);
//   * what the chrome would do to pages (navigate, reload, close a tab, history, commands, a preference change) is
//     queued and done at the end of the page phase (`actions`), never under the running guest.
// Nothing of the page runs in a chrome frame: no task, timer, script, style, layout or paint, and a guest call refused
// (wasm.preempting). What the chrome reads of a page (title, status, counters) is read as it is, between two
// instructions of the guest: the same thread, nothing moves meanwhile.
//
// What it changes for pages (see "Interface hors page" in the notes): while a script runs, the document scrolls under
// the wheel without the page knowing until it is done (scroll containers and wheel listeners do not get that wheel),
// and the screen shows its last frame, not the changes the script made so far (as before: nothing was shown at all).

import "base:runtime"
import "core:time"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:page"
import "wb:wasm"

SHELL_FRAME_PREFS := [?]config.Def{
	{name = "browser.shell.preempt", kind = .Bool, default = {b = true},
		description = "While a page keeps the interface thread busy (a long script), the browser still draws its interface at the frame rate: tabs, address bar, menus, scrolling and resizing answer at once, and the page shows its last frame until it is done. Off: the window waits for the page."},
	{name = "browser.shell.preempt_after_ms", kind = .Float, default = {f = 6}, bounded = true, min = 0, max = 1000, unit = "ms",
		description = "How long a page may keep the interface thread before the browser draws its interface in between (browser.shell.preempt)."},
	{name = "browser.shell.preempt_tick_ms", kind = .Int, default = {i = 2}, bounded = true, min = 1, max = 100, unit = "ms",
		description = "How often a running script is interrupted to see whether the interface needs a frame (only while some script runs). Smaller: interface frames closer to the display's rate during long scripts."},
	{name = "browser.shell.snapshot", kind = .Bool, default = {b = true},
		description = "Keep a copy of each tab's last page frame on the GPU (the page area's size, 4 bytes per pixel), shown while the page is busy and scrolled at once by the wheel. Off: a busy page shows its canvas color."},
	{name = "browser.shell.snapshot_tabs", kind = .Int, default = {i = 4}, bounded = true, min = 1, max = 64, unit = "tabs",
		description = "Tabs whose last page frame is kept (browser.shell.snapshot): the current one and the ones shown most recently."},
}

register_shell_frame_prefs :: proc(p: ^config.Prefs) { config.register(p, SHELL_FRAME_PREFS[:]) }

Shell_Frame_Settings :: struct {
	preempt:       bool,
	after_ms:      f64,
	tick_ms:       int,
	snapshot:      bool,
	snapshot_tabs: int,
}

shell_frame_settings_from_prefs :: proc(p: ^config.Prefs) -> Shell_Frame_Settings {
	return {
		preempt = config.bool_of(p, "browser.shell.preempt"),
		after_ms = config.float_of(p, "browser.shell.preempt_after_ms"),
		tick_ms = int(config.int_of(p, "browser.shell.preempt_tick_ms")),
		snapshot = config.bool_of(p, "browser.shell.snapshot"),
		snapshot_tabs = int(config.int_of(p, "browser.shell.snapshot_tabs")),
	}
}

// Where the frame is: page work may be preempted only in the page phase.
Shell_Phase :: enum u8 {
	None,   // waiting, polling, building, drawing: no chrome frame
	Loop,   // tasks and timers of the loop: the frame's own input is not used yet (chrome frames take it)
	Input,  // page input: the frame's input is being routed (chrome frames leave it, and hold newer presses and keys)
	Anim,   // animation frames, styles, layout: the frame's input left for the chrome (chrome frames take it)
}

// The last frame of a tab's page, kept on the GPU.
Page_Snapshot :: struct {
	tab:    u64,
	image:  draw.Backdrop,   // kept texture; image.origin: the screen pixel of texel 0 when captured
	rect:   draw.Rect,       // page area when captured (screen)
	scroll: f32,             // the document's scroll then (device px)
	limit:  f32,             // the document's scroll range then
	canvas: draw.Color,
	gen:    u64,             // render.targets_generation of the texture
	used:   u64,             // chrome_frames.frame_no when last captured or shown (least recently used go first)
}

Shell_Action_Kind :: enum u8 { Command, Navigate, Reload, History, Entry, Close_Tab, Prefs }

// Something the chrome asked of pages during a chrome frame, done at the end of the page phase.
Shell_Action :: struct {
	kind:    Shell_Action_Kind,
	tab:     u64,
	text:    string,   // owned: command name, address
	delta:   int,      // history
	entry:   u64,      // history entry id
	flag:    bool,     // reload: bypass the cache; navigate: user activation
	record, restore: bool,
	cache:   fetch.Cache_Mode,
}

Shell_Frames :: struct {
	cfg:        Shell_Frame_Settings,
	watch:      int,
	phase:      Shell_Phase,
	phase_start: time.Tick,
	nested:     bool,            // a chrome frame is being made (under a guest call, a style pass, a layout pass)
	page_locked: bool,           // the current tab's layout runs on the page thread (page_thread.odin): not even read
	last_present: time.Tick,
	outer:      [dynamic]platform.Event,   // the full frame's own input (copied: chrome frames poll again)
	outer_taken: bool,           // a chrome frame used it (its page part went to `deferred`)
	outer_busy_input: bool,      // phase Page: the full frame's input has presses or keys the chrome has not seen yet
	deferred:   [dynamic]platform.Event,   // input for the page (or held back), for the next full frame, in order
	actions:    [dynamic]Shell_Action,
	pending_scroll: f32,         // wheel taken by chrome frames for the current tab's document (device px)
	pending_tab: u64,
	press_to_page: [8]bool,      // per mouse button: its press went to the page (its release follows)
	page_keyboard: bool,         // chrome frames: whether the page has the keyboard (followed through presses)
	snaps:      [dynamic]Page_Snapshot,
	frame_no:   u64,
	frames:     u64,             // chrome frames made (statistics)
	skipped:    u64,             // preemptions that found the screen not ready for a frame
}

chrome_frames: Shell_Frames

shell_frames_init :: proc(app: ^App) {
	chrome_frames.cfg = shell_frame_settings_from_prefs(&app.prefs)
	chrome_frames.watch = config.watch(&app.prefs, "browser.shell.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		chrome_frames.cfg = shell_frame_settings_from_prefs(p)
		shell_install_hook((^App)(user))
	}, app)
	shell_install_hook(app)
}

@(private = "file")
shell_install_hook :: proc(app: ^App) {
	if chrome_frames.cfg.preempt {
		wasm.set_preempt_hook(shell_preempt, app, chrome_frames.cfg.tick_ms)
		host.set_parallel_wait_hook(shell_preempt, app, i64(chrome_frames.cfg.tick_ms) * 500_000)   // (twice per tick)
	} else {
		wasm.set_preempt_hook(nil, nil)
		host.set_parallel_wait_hook(nil, nil, 0)
	}
	if !chrome_frames.cfg.snapshot { shell_snapshots_clear(app) }
}

shell_frames_destroy :: proc(app: ^App) {
	wasm.set_preempt_hook(nil, nil)
	host.set_parallel_wait_hook(nil, nil, 0)
	config.unwatch(&app.prefs, chrome_frames.watch)
	shell_snapshots_clear(app)
	for a in chrome_frames.actions { delete(a.text) }
	delete(chrome_frames.actions); delete(chrome_frames.deferred); delete(chrome_frames.outer); delete(chrome_frames.snaps)
	chrome_frames = {}
}

// True inside a chrome frame: what would act on a page is to be queued (shell_defer_*), not done.
shell_nested :: proc() -> bool { return chrome_frames.nested }

////////////////////////////////
// The full frame's side

// After the frame polled its input: the input held back by chrome frames comes first; the page phase begins.
shell_frame_begin :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	// (a copy: a chrome frame polls again, which overwrites the window's list)
	all := make([dynamic]platform.Event, 0, len(chrome_frames.deferred) + len(events), context.temp_allocator)
	append(&all, ..chrome_frames.deferred[:])
	append(&all, ..events)
	clear(&chrome_frames.deferred)
	evs := all[:]
	shell_keep_outer(evs)
	chrome_frames.outer_busy_input = false
	chrome_frames.phase = .Loop
	chrome_frames.phase_start = time.tick_now()
	chrome_frames.frame_no += 1
	return evs
}

// A copy of the full frame's input for chrome frames (they poll again: the window's own list is overwritten).
@(private = "file")
shell_keep_outer :: proc(events: []platform.Event) {
	clear(&chrome_frames.outer)
	append(&chrome_frames.outer, ..events)
	chrome_frames.outer_taken = false
}

// After the loop's tasks: the input left for page routing and the chrome (a chrome frame may have taken it: then
// only its page part, in `deferred`, is left, and the chrome already saw the rest).
shell_after_loop :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	out := events
	if chrome_frames.outer_taken {
		evs := make([]platform.Event, len(chrome_frames.deferred), context.temp_allocator)
		copy(evs, chrome_frames.deferred[:])
		clear(&chrome_frames.deferred)
		out = evs
	}
	chrome_frames.phase = .Input
	chrome_frames.outer_busy_input = false
	for ev in out {
		#partial switch ev.kind {
		case .Mouse_Press, .Mouse_Release, .Key_Press, .Key_Release, .Text: chrome_frames.outer_busy_input = true
		}
	}
	return out
}

// After the page's input was routed: what is left is the chrome's (its build's), which chrome frames may take now.
shell_after_input :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	shell_keep_outer(events)
	chrome_frames.phase = .Anim
	return events
}

// The page phase is over (before the chrome is built): the scroll taken by chrome frames and the actions they queued.
// Returns the input left for the build (none when a chrome frame built with it).
shell_page_phase_end :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	out := events
	if chrome_frames.phase == .Anim && chrome_frames.outer_taken { out = nil }
	chrome_frames.phase = .None
	clear(&chrome_frames.outer)
	if chrome_frames.pending_scroll != 0 {
		for t in app.tabs {
			if t.id != chrome_frames.pending_tab || t.kind != .Web || t.page == nil { continue }
			scroll_document_to(app, t, clamp(t.scroll + chrome_frames.pending_scroll, 0, max(t.layout.height - draw.rect_size(app.page_rect).y, 0)), false)
		}
		chrome_frames.pending_scroll = 0
		app.frames_requested = max(app.frames_requested, 2)
	}
	if len(chrome_frames.actions) > 0 {
		todo := make([]Shell_Action, len(chrome_frames.actions), context.temp_allocator)
		copy(todo, chrome_frames.actions[:])
		clear(&chrome_frames.actions)
		for a in todo { shell_run_action(app, a); delete(a.text) }
		app.frames_requested = max(app.frames_requested, 3)
	}
	return out
}

// After a present (any frame).
shell_presented :: proc() { chrome_frames.last_present = time.tick_now() }

// Before the full frame draws: a chrome frame used the screen's slot; wait for the next one as a frame does.
shell_before_draw :: proc(app: ^App) {
	if app.presented && !pacer.slot_held {
		if platform.wait_handle(app.win, render.frame_waitable(&app.r), pacer.cfg.timeout_ms) { pacer.slot_held = true }
	}
}

////////////////////////////////
// Preemption

// The Wasm engine's hook (a guest call of this thread is between two instructions), the style passes' (a parallel
// pass waits for its threads: host.set_parallel_wait_hook) and the page thread's (a layout pass runs there).
shell_preempt :: proc(user: rawptr) {
	app := (^App)(user)
	if !chrome_frames.cfg.preempt || chrome_frames.phase == .None || chrome_frames.nested || !app.presented || platform.is_closed(app.win) { return }
	now := time.tick_now()
	if time.duration_milliseconds(time.tick_diff(chrome_frames.phase_start, now)) < chrome_frames.cfg.after_ms { return }
	// one chrome frame per refresh: a little early, the wait for the screen's slot below does the rest (a resize step
	// has no such rate: the chrome must show at the new size before the composer stretches the last frame)
	since := time.duration_milliseconds(time.tick_diff(chrome_frames.last_present, now))
	if !pacer.resizing && since < pacer.period_ms * 0.75 { return }
	// and only when the chrome has something new to show: input (or a message: a resize, a repaint), an animation of its
	// own, a wake it asked for (a caret's blink). Otherwise the page keeps the thread: no cost to a busy page nobody
	// touches.
	unseen := (chrome_frames.phase == .Loop || chrome_frames.phase == .Anim) && !chrome_frames.outer_taken && len(chrome_frames.outer) > 0   // the frame's own input, not drawn yet
	if !unseen && !shell_input_pending() && !ui.needs_frame(&app.ui_state) && !(ui.wake_ms(&app.ui_state) > 0 && since >= f64(ui.wake_ms(&app.ui_state))) { return }
	shell_chrome_frame(app)
}

// Messages wait in the thread's queue (input, posted or sent messages, a repaint), without taking them.
@(private = "file")
shell_input_pending :: proc() -> bool {
	QS_KEY :: 0x0001; QS_MOUSEMOVE :: 0x0002; QS_MOUSEBUTTON :: 0x0004; QS_POSTMESSAGE :: 0x0008
	QS_PAINT :: 0x0020; QS_SENDMESSAGE :: 0x0040
	status := GetQueueStatus(QS_KEY | QS_MOUSEMOVE | QS_MOUSEBUTTON | QS_POSTMESSAGE | QS_PAINT | QS_SENDMESSAGE)
	return status >> 16 != 0   // (the high word: kinds of messages now in the queue)
}

foreign import user32_shell "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_shell {
	GetQueueStatus :: proc(flags: u32) -> u32 ---
}

// A frame of the chrome alone, made while the page holds the thread.
@(private = "file")
shell_chrome_frame :: proc(app: ^App) {
	// the screen's slot: a frame only when the swap chain can take one now (the guest is not kept waiting for it). A
	// resize step skips it: its frame is presented at once, whatever the screen is doing
	if !pacer.slot_held && !pacer.resizing {
		if win.WaitForSingleObject(win.HANDLE(render.frame_waitable(&app.r)), 0) != win.WAIT_OBJECT_0 { chrome_frames.skipped += 1; return }
		pacer.slot_held = true
	}
	chrome_frames.nested = true
	defer chrome_frames.nested = false
	refused := wasm.refuse_calls(true)   // nothing of a page runs here (a guest call would be refused, not run)
	defer wasm.refuse_calls(refused)
	chrome_frames.frames += 1
	// the full frame's temporary allocations live on under us; the profiler's clock is the full frame's
	tmp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(tmp)
	saved_clock := phase_clock
	phase_clock.on = false
	defer phase_clock = saved_clock
	saved_probe := latency_probe_save()
	defer latency_probe_restore(saved_probe)

	polled := platform.poll_events(app.win, false)   // (nil inside the system's resize loop: nothing new to read)
	chrome := shell_split_input(app, polled)
	pacer_begin_frame(app, chrome)
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	base_style := chrome_frame_style(app)
	window_chrome_frame(app)
	ui.begin_build(&app.ui_state, {
		window_size = size, events = chrome, dt = pacer.dt, animations = os_animations_enabled(app),
		dpi_scale = ui_scale_of(app), base = base_style, clipboard_get = clip_get, clipboard_set = clip_set,
		disable_zoom = true, window = app.win, frame_ms = pacer.frame_ms,
	})
	build_ui(app)
	ui.end_build()
	// the chrome's cursor over the chrome; over the page, the page's as the last full frame set it (page_cursor.odin
	// hit-tests the layout, which is not read here)
	pos := ui.mouse_pos()
	if !draw.rect_contains(app.page_rect, pos) || ui.hot_key() != 0 || ui.active_key() != 0 || ui.ctx_menu_any_open() {
		platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	}
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, !pacer.resizing)   // a resize step is shown at once (pacer.resizing, pacing.odin)
	pacer_end_frame(app)
	latency_probe_presented(app, 1)
	// the full frame draws again after the page phase: whatever the chrome frames showed is drawn then too
	app.frames_requested = max(app.frames_requested, 2)
}

// The input of a chrome frame: what is the chrome's goes to its build; what is the page's waits (`deferred`). The
// full frame's own input is older: in the Loop phase it is taken whole (its page part waits too); in the Anim phase
// what is left of it after the page's routing is the chrome's, as the full frame's build would have had it. In the
// Input phase it is being routed: while it still holds presses or keys, newer presses and keys wait as well (they must
// not overtake them).
@(private = "file")
shell_split_input :: proc(app: ^App, polled: []platform.Event) -> []platform.Event {
	chrome := make([dynamic]platform.Event, 0, len(polled) + len(chrome_frames.outer), context.temp_allocator)
	chrome_frames.page_keyboard = page_has_keyboard(app)
	if !chrome_frames.outer_taken {
		#partial switch chrome_frames.phase {
		case .Loop:
			chrome_frames.outer_taken = true
			for ev in chrome_frames.outer { shell_route(app, ev, &chrome, false) }
		case .Anim:
			chrome_frames.outer_taken = true
			append(&chrome, ..chrome_frames.outer[:])
		}
	}
	hold := chrome_frames.phase == .Input && chrome_frames.outer_busy_input
	for ev in polled { shell_route(app, ev, &chrome, hold) }
	return chrome[:]
}

@(private = "file")
shell_route :: proc(app: ^App, ev: platform.Event, chrome: ^[dynamic]platform.Event, hold_buttons_and_keys: bool) {
	t := current_tab(app)
	page_shown := t != nil && t.kind == .Web
	over_page := page_shown && draw.rect_contains(app.page_rect, ev.pos) && !ui.ctx_menu_any_open() && !hud_captures(ev.pos)
	button := int(ev.button) % len(chrome_frames.press_to_page)
	#partial switch ev.kind {
	case .Mouse_Move:
		append(chrome, ev)   // hover of the chrome (and its own pointer capture)
		if over_page { append(&chrome_frames.deferred, ev) }   // the page's hover, later
	case .Mouse_Press:
		if hold_buttons_and_keys { append(&chrome_frames.deferred, ev); return }
		chrome_frames.press_to_page[button] = over_page
		if over_page {
			chrome_frames.page_keyboard = true
			append(&chrome_frames.deferred, ev)
		} else {
			chrome_frames.page_keyboard = false
			append(chrome, ev)
		}
	case .Mouse_Release:
		if hold_buttons_and_keys || chrome_frames.press_to_page[button] {
			chrome_frames.press_to_page[button] = false
			append(&chrome_frames.deferred, ev)
			return
		}
		append(chrome, ev)
	case .Scroll:
		if over_page && .Ctrl not_in ev.mods && t.page != nil {
			shell_async_scroll(app, t, ev.delta.y * wheel_step(app, (app.page_rect.max - app.page_rect.min) / max(page_scale(app), 0.01)).y * page_scale(app))
			return
		}
		if over_page { append(&chrome_frames.deferred, ev); return }   // zoom: the page's layout
		append(chrome, ev)
	case .Key_Press, .Key_Release, .Text:
		if hold_buttons_and_keys || chrome_frames.page_keyboard { append(&chrome_frames.deferred, ev); return }
		append(chrome, ev)
	case:
		append(chrome, ev)
	}
}

// The wheel over a busy page: its last frame moves at once; the document takes the position after the page phase.
@(private = "file")
shell_async_scroll :: proc(app: ^App, t: ^Tab, dy: f32) {
	if chrome_frames.pending_tab != t.id { chrome_frames.pending_scroll, chrome_frames.pending_tab = 0, t.id }
	limit: f32
	if !chrome_frames.page_locked { limit = max(t.layout.height - draw.rect_size(app.page_rect).y, 0) }   // (page thread: not read)
	if s := shell_snapshot_of(t.id); s != nil { limit = max(limit, s.limit) }
	to := clamp(t.scroll + chrome_frames.pending_scroll + dy, 0, limit)
	chrome_frames.pending_scroll = to - t.scroll
}

////////////////////////////////
// Deferred actions

// Inside a chrome frame, queues what the chrome asks of pages; true when queued (the caller does nothing now).
shell_defer :: proc(a: Shell_Action) -> bool {
	if !chrome_frames.nested { return false }
	append(&chrome_frames.actions, a)
	return true
}

@(private = "file")
shell_tab_by_id :: proc(app: ^App, id: u64) -> (^Tab, int) {
	for t, i in app.tabs { if t.id == id { return t, i } }
	return nil, -1
}

@(private = "file")
shell_run_action :: proc(app: ^App, a: Shell_Action) {
	if a.kind == .Prefs { apply_prefs(app); return }
	t, i := shell_tab_by_id(app, a.tab)
	if t == nil && a.kind != .Command { return }   // closed meanwhile
	switch a.kind {
	case .Command:
		if c := command(a.text); c != nil { command_run(app, t != nil ? t : current_tab(app), c) }
	case .Navigate:
		navigate(app, t, a.text, user_activation = a.flag, record = a.record, restore = a.restore, cache = a.cache)
	case .Reload:
		reload(app, t, a.flag)
	case .History:
		go_history(app, t, a.delta)
	case .Entry:
		if e := page.session_find(&t.session, a.entry); e != nil { go_entry(app, t, e) }
	case .Close_Tab:
		tab_close(app, i)
	case .Prefs:
	}
}

////////////////////////////////
// Snapshots of pages

@(private = "file")
shell_snapshot_of :: proc(tab: u64) -> ^Page_Snapshot {
	for &s in chrome_frames.snaps { if s.tab == tab { return &s } }
	return nil
}

// After the page was painted (page_draw, in its clip): its pixels are kept for chrome frames.
shell_capture :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect, canvas: draw.Color) {
	if !chrome_frames.cfg.snapshot || !chrome_frames.cfg.preempt { return }
	bd := draw.backdrop_capture(dc, rect, nil)
	if bd.image.tex == 0 { return }
	if !render.keep_target(dc.renderer, bd.image.tex) { render.release_target(dc.renderer, bd.image.tex); return }
	bd.kept = true
	gen := render.targets_generation(dc.renderer)
	s := shell_snapshot_of(t.id)
	if s == nil {
		shell_snapshots_trim(app, max(chrome_frames.cfg.snapshot_tabs - 1, 0))
		append(&chrome_frames.snaps, Page_Snapshot{tab = t.id})
		s = &chrome_frames.snaps[len(chrome_frames.snaps) - 1]
	} else if s.image.image.tex != 0 && s.gen == gen {
		render.unkeep_target(dc.renderer, s.image.image.tex)
	}
	s.image, s.rect, s.scroll, s.canvas, s.gen, s.used = bd, rect, t.scroll, canvas, gen, chrome_frames.frame_no
	s.limit = max(t.layout.height - draw.rect_size(rect).y, 0)
}

// Draws a tab's last page frame in the page area, moved by the wheel taken meanwhile and anchored at the top left.
// False when there is none (the caller shows something else).
shell_paint_page :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect) -> bool {
	s := shell_snapshot_of(t.id)
	if s == nil || s.image.image.tex == 0 || s.gen != render.targets_generation(dc.renderer) { return false }
	s.used = chrome_frames.frame_no
	draw.rect(dc, rect, s.canvas)
	scroll := t.scroll + (chrome_frames.pending_tab == t.id ? chrome_frames.pending_scroll : 0)
	img := s.image
	shift := (rect.min - s.rect.min) - draw.Vec2{0, scroll - s.scroll}
	img.image.origin += shift
	covered := draw.rect_intersect(rect, draw.Rect{img.image.origin, img.image.origin + draw.Vec2{f32(img.image.size.x), f32(img.image.size.y)}})
	if covered.max.x <= covered.min.x || covered.max.y <= covered.min.y { return true }
	draw.push_clip(dc, rect)
	draw.backdrop_draw(dc, img, covered, {})
	draw.pop_clip(dc)
	return true
}

// Keeps at most `keep` snapshots (the current tab's and the most recently used).
@(private = "file")
shell_snapshots_trim :: proc(app: ^App, keep: int) {
	cur := current_tab(app)
	for len(chrome_frames.snaps) > keep {
		worst := -1
		for s, i in chrome_frames.snaps {
			if cur != nil && s.tab == cur.id { continue }
			if worst < 0 || s.used < chrome_frames.snaps[worst].used { worst = i }
		}
		if worst < 0 { break }
		shell_snapshot_drop(app, worst)
	}
}

@(private = "file")
shell_snapshot_drop :: proc(app: ^App, i: int) {
	s := chrome_frames.snaps[i]
	if s.image.image.tex != 0 && s.gen == render.targets_generation(&app.r) { render.unkeep_target(&app.r, s.image.image.tex) }
	unordered_remove(&chrome_frames.snaps, i)
}

@(private = "file")
shell_snapshots_clear :: proc(app: ^App) {
	for len(chrome_frames.snaps) > 0 { shell_snapshot_drop(app, len(chrome_frames.snaps) - 1) }
}

// Once per full frame: the snapshots of closed tabs go.
shell_snapshots_frame :: proc(app: ^App) {
	for i := len(chrome_frames.snaps) - 1; i >= 0; i -= 1 {
		if t, _ := shell_tab_by_id(app, chrome_frames.snaps[i].tab); t == nil { shell_snapshot_drop(app, i) }
	}
}
