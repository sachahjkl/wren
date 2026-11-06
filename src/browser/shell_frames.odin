package browser

// Chrome frames while a page holds the interface thread.
//
// A page's work runs on the window's thread: its scripts (JavaScript and Wasm modules), events, timers and animation
// frames during the frame's "page phase" (loop tasks, page input, animation frames), then its style, layout and paint.
// A script that runs for 200 ms used to freeze the whole window for 200 ms: tabs, address bar, menus, scrolling and
// resizing. Now the chrome preempts the page: while a guest call runs in the page phase, the Wasm engine's tick (its epoch, a poll in the JavaScript engine: wasm/poll.odin)
// hands the thread to `shell_preempt` (wasm.set_preempt_hook), and once the page has held the
// thread longer than browser.shell.preempt_after_ms, a *chrome frame* is drawn there, between two instructions of the
// guest, at the frame rate:
//   * the chrome is built and drawn as usual, with the input that came meanwhile;
//   * the page area shows the page's last frame (a copy of its pixels kept on the GPU after each paint: Page_Snapshot),
//     anchored at the top left when the window is resized, never stretched; the canvas color fills what it does not
//     cover;
//   * the wheel over the page, the thumb of the document's scroll bar and the keys that scroll the document scroll it at
//     once (asynchronous scrolling, as Chromium's and Firefox's compositors do; the keys only when no key listener could
//     see them): the page is painted again from its last layout when nothing it was painted from has changed since
//     (shell_paint_layout: what comes into view is there), else that copy moves; the document takes the position before
//     the input that waited is given to the page (it was aimed at what the screen showed);
//   * a text selection's drag shows what it selects at once, from its press, and scrolls past the view's edge
//     (selection_shell.odin Sel_Preview); its press and moves wait for the page as any input does, and select when they get there;
//   * painted from that layout, the page's CSS animations of transform and opacity go on, a scroll container under the
//     wheel or the thumb of its bar scrolls, and the focused field's caret blinks (shell_shown.odin);
//   * the browser's shortcuts and the tab keys reach the chrome at once when no key listener could see them; the commands
//     that act on the chrome alone (the address bar, the next tab) are done there and then;
//   * input meant for the page (presses, keys while the page has the keyboard) waits, in order, for the next full
//     frame (`deferred`), and so do the moves and the release of a press the page had;
//   * what the chrome would do to pages (navigate, reload, close a tab, history, commands, a preference change) is
//     queued and done at the end of the page phase (`actions`), never under the running guest.
// Nothing of the page runs in a chrome frame: no task, timer, script, style, layout or paint, and a guest call refused
// (wasm.preempting). What the chrome reads of a page (title, status, counters) is read as it is, between two
// instructions of the guest: the same thread, nothing moves meanwhile.
//
// What it changes for pages (see "Interface hors page" in the notes): while a script runs, the document scrolls under
// the wheel without the page knowing until it is done (wheel listeners do not get that wheel; the container under the pointer
// does, at the page's turn),
// and the screen shows its last frame, not the changes the script made so far (as before: nothing was shown at all).
// What a script observes is the same: the events it is given come in the order they happened, and nothing it can read
// (the selection, the scroll offsets, the focus) changes under it.

import "base:runtime"
import "core:math"
import "core:time"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:forms"
import "wb:host"
import lay "wb:layout"
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
	{name = "browser.video.fast_path", kind = .String, default = {s = "auto"}, choices = {"auto", "off", "verify"},
		description = "While a page is busy (a long script), keep playing a video that fills its box by drawing its newest picture over the page's last frame, so the video does not freeze with the rest of the page. auto: on. off: the video freezes with the page. verify: a diagnostic mode that also records the normal path and reports in the console when the fast path would differ from it."},
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

SNAPSHOT_STUCK_MAX :: 16
// What the offsets of a zoom there and back miss their value by, at most.
@(private = "file") SNAPSHOT_ZOOM_ROUNDING_PX :: 0.5

// The last frame of a tab's page, kept on the GPU.
Page_Snapshot :: struct {
	tab:    u64,
	page:   ^page.Page,      // the document it shows
	image:  draw.Backdrop,   // kept texture; image.origin: the screen pixel of texel 0 when captured
	rect:   draw.Rect,       // page area when captured (screen)
	scroll: draw.Vec2,       // the document's scroll then (device px)
	selection: [2]lay.Text_Pos,   // what it shows selected: a selection that changes makes it old, with no task and no node changed
	lo, limit: draw.Vec2,    // the document's scroll range then
	bar:    bool,            // the document had a vertical scroll bar: not in the pixels (it would move with them), drawn again by shell_paint_page
	bar_track, bar_thumb: draw.Rect,       // its track and thumb (relative to the page area's corner)
	bar_x:  bool,            // likewise, the horizontal one
	bar_x_track, bar_x_thumb: draw.Rect,
	bar_corner: draw.Rect,   // between two classic bars (empty: none)
	bar_colors: Bar_Colors,
	stuck:  [SNAPSHOT_STUCK_MAX]draw.Rect,   // the fixed and sticky boxes (window pixels): they stay where they were drawn when the rest scrolls
	n_stuck: int,
	canvas: draw.Color,
	gen:    u64,             // render.targets_generation of the texture
	scale:  f32,             // page_scale then: a zoom changes it, and scroll is in its pixels
	used:   u64,             // chrome_frames.frame_no when last captured or shown (least recently used go first)
}

Shell_Action_Kind :: enum u8 { Command, Navigate, Reload, History, Entry, Close_Tab, Tear_Off, Prefs }

// Something the chrome asked of pages during a chrome frame, done at the end of the page phase, or what a build asked of the list of tabs,
// done before the next frame of its window (shell_after_build).
Shell_Action :: struct {
	kind:    Shell_Action_Kind,
	tab:     u64,
	text:    string,   // owned: command name, address
	delta:   int,      // history
	entry:   u64,      // history entry id
	flag:    bool,     // reload: bypass the cache; navigate: user activation
	record, restore: bool,
	cache:   fetch.Cache_Mode,
	origin:  Nav_Origin,       // navigate: who chose the address (nav_trust.odin), kept across the wait
	from:    ^page.Page,       // navigate: the document that asked; used only if a tab still shows it when the action runs
	at:      draw.Vec2,        // tear off: where the pointer was (client pixels)
	window:  int,              // done in a frame of this window (shell_after_build; 0: of any)
}

Shell_Frames :: struct {
	cfg:        Shell_Frame_Settings,
	watch:      int,
	phase:      Shell_Phase,
	phase_start: time.Tick,
	nested:     bool,            // a chrome frame is being made (under a guest call, a style pass, a layout pass)
	page_locked: bool,           // the current tab's layout runs on the page thread (page_thread.odin): not even read
	styling:    bool,            // a style pass's threads run (its wait lends the thread to chrome frames): the page's animations are not sampled
	last_present: time.Tick,
	outer:      [dynamic]platform.Event,   // the full frame's own input (copied: chrome frames poll again)
	outer_taken: bool,           // a chrome frame used it (its page part went to `deferred`)
	outer_busy_input: bool,      // phase Page: the full frame's input has presses or keys the chrome has not seen yet
	deferred:   [dynamic]platform.Event,   // input for the page (or held back), for the next full frame, in order
	actions:    [dynamic]Shell_Action,
	pending_scroll: draw.Vec2,   // scroll taken by chrome frames for the current tab's document (the wheel, the bar's thumb, the keys; device px)
	pending_tab: u64,
	boxes:      [dynamic]Box_Scroll,   // the containers of that tab's document chrome frames scrolled (the wheel, a bar's thumb: shell_shown.odin)
	page_keyboard: bool,         // chrome frames: whether the page has the keyboard (followed through presses)
	snaps:      [dynamic]Page_Snapshot,
	frame_no:   u64,
	frames:     u64,             // chrome frames made (statistics)
	skipped:    u64,             // preemptions that found the screen not ready for a frame
}


shell_frames_init :: proc(app: ^App) {
	app.chrome_frames.cfg = shell_frame_settings_from_prefs(&app.prefs)
	app.chrome_frames.watch = config.watch(&app.prefs, "browser.shell.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		the_app.chrome_frames.cfg = shell_frame_settings_from_prefs(p)
		shell_install_hook((^App)(user))
	}, app)
	shell_install_hook(app)
}

@(private = "file")
shell_install_hook :: proc(app: ^App) {
	if app.chrome_frames.cfg.preempt {
		wasm.set_preempt_hook(shell_preempt, app, app.chrome_frames.cfg.tick_ms)
		host.set_parallel_wait_hook(shell_preempt_styling, app, i64(app.chrome_frames.cfg.tick_ms) * 500_000)   // (twice per tick)
	} else {
		wasm.set_preempt_hook(nil, nil)
		host.set_parallel_wait_hook(nil, nil, 0)
	}
	if !app.chrome_frames.cfg.snapshot { shell_snapshots_clear(app) }
}

shell_frames_destroy :: proc(app: ^App) {
	wasm.set_preempt_hook(nil, nil)
	host.set_parallel_wait_hook(nil, nil, 0)
	config.unwatch(&app.prefs, app.chrome_frames.watch)
	shell_snapshots_clear(app)
	for a in app.chrome_frames.actions { delete(a.text) }
	delete(app.chrome_frames.actions); delete(app.chrome_frames.deferred); delete(app.chrome_frames.boxes); delete(app.chrome_frames.outer); delete(app.chrome_frames.snaps)
	app.chrome_frames = {}
}

// True inside a chrome frame: what would act on a page is to be queued (shell_defer_*), not done.
shell_nested :: proc() -> bool { return the_app.chrome_frames.nested }

////////////////////////////////
// The full frame's side

// After the frame polled its input: the input held back by chrome frames comes first; the page phase begins.
shell_frame_begin :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	// (a copy: a chrome frame polls again, which overwrites the window's list)
	all := make([dynamic]platform.Event, 0, len(app.chrome_frames.deferred) + len(events), context.temp_allocator)
	append(&all, ..app.chrome_frames.deferred[:])
	append(&all, ..events)
	clear(&app.chrome_frames.deferred)
	evs := all[:]
	shell_keep_outer(evs)
	app.chrome_frames.outer_busy_input = false
	app.chrome_frames.phase = .Loop
	app.chrome_frames.phase_start = time.tick_now()
	app.chrome_frames.frame_no += 1
	return evs
}

// The loop's tasks run while the frame waits for its slot (pacing.odin pacer_slot_wait), before it polls: a page phase of
// their own, where a long script is preempted as in the frame's (chrome frames take the input that came meanwhile).
shell_wait_tasks :: proc(app: ^App) -> int {
	app.chrome_frames.phase = .Loop
	app.chrome_frames.phase_start = time.tick_now()
	defer app.chrome_frames.phase = .None
	return frame_tasks(app)   // main.odin
}

// A copy of the full frame's input for chrome frames (they poll again: the window's own list is overwritten).
@(private = "file")
shell_keep_outer :: proc(events: []platform.Event) {
	clear(&the_app.chrome_frames.outer)
	append(&the_app.chrome_frames.outer, ..events)
	the_app.chrome_frames.outer_taken = false
}

// After the loop's tasks: the input left for page routing and the chrome (a chrome frame may have taken it: then
// only its page part, in `deferred`, is left, and the chrome already saw the rest).
shell_after_loop :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	out := events
	if app.chrome_frames.outer_taken {
		evs := make([]platform.Event, len(app.chrome_frames.deferred), context.temp_allocator)
		copy(evs, app.chrome_frames.deferred[:])
		clear(&app.chrome_frames.deferred)
		out = evs
	}
	app.chrome_frames.phase = .Input
	app.chrome_frames.outer_busy_input = false
	shell_take_scroll(app)
	for ev in out {
		#partial switch ev.kind {
		case .Mouse_Press, .Mouse_Release, .Key_Press, .Key_Release, .Text: app.chrome_frames.outer_busy_input = true
		}
	}
	return out
}

// After the page's input was routed: what is left is the chrome's (its build's), which chrome frames may take now.
shell_after_input :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	shell_keep_outer(events)
	app.chrome_frames.phase = .Anim
	return events
}

// The page phase is over (before the chrome is built): the scroll taken by chrome frames and the actions they queued.
// Returns the input left for the build (none when a chrome frame built with it).
shell_page_phase_end :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	out := events
	if app.chrome_frames.phase == .Anim && app.chrome_frames.outer_taken { out = nil }
	app.chrome_frames.phase = .None
	clear(&app.chrome_frames.outer)
	shell_take_scroll(app)
	shell_actions_run(app)
	return out
}

// The document and its containers take the scroll chrome frames showed: before the page's input that waited (it was aimed at
// what they showed) and at the end of the page phase. (A container's scroll event comes with the page's next frame, as for
// any scroll: page/scroll_events.odin.)
@(private = "file")
shell_take_scroll :: proc(app: ^App) {
	if app.chrome_frames.pending_scroll == {} && len(app.chrome_frames.boxes) == 0 { return }
	for t in tabs_all(app) {
		if t.id != app.chrome_frames.pending_tab || t.kind != .Web || t.page == nil { continue }
		for b in app.chrome_frames.boxes { lay.set_scroll(&t.layout, b.node, b.to) }
		if app.chrome_frames.pending_scroll == {} { continue }
		size := draw.rect_size(active_window(app).page_rect)
		lo, hi := lay.doc_scroll_x_range(&t.layout, size.x)
		to := [2]f32{t.layout.doc_scroll_x, t.scroll} + app.chrome_frames.pending_scroll
		lo_y, hi_y := lay.doc_scroll_y_range(&t.layout, size.y)
		scroll_document_to(app, t, {clamp(to.x, lo, hi), clamp(to.y, lo_y, hi_y)}, false)
	}
	app.chrome_frames.pending_scroll = {}
	clear(&app.chrome_frames.boxes)
	request_frames(app, 2)
}

// After a present (any frame).
shell_presented :: proc() { the_app.chrome_frames.last_present = time.tick_now() }

// Before the full frame draws: a chrome frame used the screen's slot; wait for the next one as a frame does (a document's
// first paint waits for none: pacing.odin pacer_slot_wait).
shell_before_draw :: proc(app: ^App) {
	wnd := active_window(app)
	if wnd.presented && !wnd.pacer.slot_held && !wnd.pacer.first_paint {
		if platform.wait_handle(wnd.win, render.frame_waitable(&app.r), app.pacing.cfg.timeout_ms) { wnd.pacer.slot_held = true }
	}
}

////////////////////////////////
// Preemption

// The Wasm engine's hook (a guest call of this thread is between two instructions), the style passes' (a parallel
// pass waits for its threads: host.set_parallel_wait_hook) and the page thread's (a layout pass runs there).
shell_preempt :: proc(user: rawptr) {
	app := (^App)(user)
	wnd := active_window(app)
	if !app.chrome_frames.cfg.preempt || app.chrome_frames.phase == .None || app.chrome_frames.nested || !wnd.presented || platform.is_closed(wnd.win) { return }
	now := time.tick_now()
	if time.duration_milliseconds(time.tick_diff(app.chrome_frames.phase_start, now)) < app.chrome_frames.cfg.after_ms { return }
	// one chrome frame per refresh: a little early, the wait for the screen's slot below does the rest (a resize step
	// has no such rate: the chrome must show at the new size before the composer stretches the last frame)
	since := time.duration_milliseconds(time.tick_diff(app.chrome_frames.last_present, now))
	if !pacer_resize_step(app) && since < wnd.pacer.period_ms * 0.75 { return }
	// and only when the chrome has something new to show: input (or a message: a resize, a repaint), an animation of its
	// own, a wake it asked for (a caret's blink), or the page's animations the compositor runs and its caret's blink
	// (shell_shown.odin). Otherwise the page keeps the thread: no cost to a busy page nobody touches.
	unseen := (app.chrome_frames.phase == .Loop || app.chrome_frames.phase == .Anim) && !app.chrome_frames.outer_taken && len(app.chrome_frames.outer) > 0   // the frame's own input, not drawn yet
	if !unseen && !shell_input_pending() && !busy_input_pending(app) && !ui.needs_frame(wnd.ui) && !(ui.wake_ms(wnd.ui) > 0 && since >= f64(ui.wake_ms(wnd.ui))) && !shell_page_moves(app) && !selection_preview_scrolls(app) { return }
	shell_chrome_frame(app)
}

// The style passes' hook: the pool's threads write styles meanwhile, which a chrome frame then does not read for the page's
// animations (shell_shown.odin).
@(private = "file")
shell_preempt_styling :: proc(user: rawptr) {
	app := (^App)(user)
	app.chrome_frames.styling = true
	defer app.chrome_frames.styling = false
	shell_preempt(user)
}

// The current tab's page shows something new by itself in a chrome frame: an animation the compositor runs, a caret's toggle.
@(private = "file")
shell_page_moves :: proc(app: ^App) -> bool {
	t := current_tab(app)
	if t == nil || t.kind != .Web || !shell_layout_paintable(app, t) { return false }
	_, moving := shell_shown_wanted(app, t)
	return moving
}

// Messages wait in the thread's queue (input, posted or sent messages, a repaint), without taking them.
// shell_input_pending / shell_user_input_pending are in shell_frames_<os>.odin: on Windows they read the thread's
// message queue (GetQueueStatus / PeekMessageW), which matters inside the system's modal loops (live resize, a menu);
// off Windows the toolkit's event loop drives frames and there is no such modal pump, so they answer false.

// The window asked for a frame (WM_PAINT inside a loop of the system: live resize, a menu). Normally a full frame. But the loop may have begun
// inside a chrome frame (the mouse went down on the window's border while one was being made: its poll pumps the messages), that is
// under a script or a layout pass of the page: a full frame there would run the page's world a second time, re-entrantly (the page
// thread owns the layout; the script is between two instructions). Then the frame made is a chrome frame, which is what can be made
// there, at the size the window has now.
window_frame :: proc(app: ^App) {
	if !app.chrome_frames.nested {
		app.pass_first = true   // (the system's loop holds the thread: this frame also runs the process's tasks)
		frame(app)
		devtools_window_tick(app)   // the panel's own window is drawn from here too: the system's loop holds the thread, and the main loop's call does not run
		return
	}
	pacer_inner_frame(app)   // (pacing.odin: a new size makes it a resize step)
	shell_chrome_frame(app)
}

// A frame of the chrome alone, made while the page holds the thread.
@(private = "file")
shell_chrome_frame :: proc(app: ^App) {
	wnd := active_window(app)
	// a Light frame of the gate (windows.odin): in a full frame's page phase, or in a chrome frame's poll
	gate := platform.frame_gate()
	gate_token, admitted := platform.frame_gate_begin(gate, .Light)
	if !admitted { return }
	defer platform.frame_gate_end(gate, gate_token)
	// the screen's slot: a frame only when the swap chain can take one now (the guest is not kept waiting for it). A
	// resize step skips it: its frame is presented at once, whatever the screen is doing
	if !wnd.pacer.slot_held && !pacer_resize_step(app) {
		// a slot only when the swap chain can take a frame now (pacing_timer_<os>.odin: the frame-latency object polled
		// without blocking on Windows; always true on the Linux FIFO path, which blocks at present instead)
		if !frame_slot_ready(render.frame_waitable(&app.r)) { app.chrome_frames.skipped += 1; return }
		wnd.pacer.slot_held = true
	}
	was_nested := app.chrome_frames.nested   // (a modal loop of the system may have begun inside a chrome frame: window_frame)
	app.chrome_frames.nested = true
	defer app.chrome_frames.nested = was_nested
	refused := wasm.refuse_calls(true)   // nothing of a page runs here (a guest call would be refused, not run)
	defer wasm.refuse_calls(refused)
	app.chrome_frames.frames += 1
	// the full frame's temporary allocations live on under us; the profiler's clock is the full frame's
	tmp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(tmp)
	saved_clock := app.phase_clock
	app.phase_clock.on = false
	defer app.phase_clock = saved_clock
	saved_probe := latency_probe_save()
	defer latency_probe_restore(saved_probe)

	busy_input_step(app)   // busy_input.odin: a test's input for this frame
	// (the gate's Polling: the poll may begin a loop of the system, whose frames are chrome frames: window_frame)
	polled := platform.poll_events(wnd.win, false)   // (nil inside the system's resize loop: nothing new to read)
	platform.frame_gate_stage(gate, .Building)
	chrome := shell_split_input(app, polled)
	selection_preview_frame(app)   // a drag past the view's edge scrolls (selection_shell.odin)
	pacer_begin_frame(app, chrome)
	render.resize(&app.r, wnd.win.size)
	size := draw.Vec2{f32(wnd.win.size.x), f32(wnd.win.size.y)}
	base_style := chrome_frame_style(app)
	window_chrome_frame(app)
	chrome_ui_apply(app, wnd.ui)
	ui.begin_build(wnd.ui, {
		window_size = size, events = chrome, dt = wnd.pacer.dt, animations = os_animations_enabled(app),
		dpi_scale = ui_scale_of(app), base = base_style, clipboard_get = clip_get, clipboard_set = clip_set,
		disable_zoom = true, window = wnd.win, frame_ms = wnd.pacer.frame_ms, inactive = !window_is_front(app),
	})
	build_ui(app)
	ui.end_build()
	// the chrome's cursor over the chrome; over the page, the page's as the last full frame set it (page_cursor.odin
	// hit-tests the layout, which is not read here)
	pos := ui.mouse_pos()
	if !draw.rect_contains(wnd.page_rect, pos) || ui.hot_key() != 0 || ui.active_key() != 0 || ui.ctx_menu_any_open() {
		platform.set_cursor(wnd.win, ui.cursor(wnd.ui))
	}
	platform.frame_gate_stage(gate, .Drawing)
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(wnd.ui, &app.dc)
	draw.end_frame(&app.dc)
	platform.frame_gate_stage(gate, .Presenting)
	remote_capture_arm(app)   // remote_shell.odin: a capture of this window
	busy_input_arm(app)
	render.frame_end(&app.r, !pacer_at_once(app))   // a resize step, the frames right after it, or an input frame are shown at once
	frame_log_presented(app, pacer_at_once(app))
	pacer_end_frame(app)
	latency_probe_presented(app, 1)
	// the full frame draws again after the page phase: whatever the chrome frames showed is drawn then too
	request_frames(app, 2)
}

// The input of a chrome frame: what is the chrome's goes to its build; what is the page's waits (`deferred`). The
// full frame's own input is older: in the Loop phase it is taken whole (its page part waits too); in the Anim phase
// what is left of it after the page's routing is the chrome's, as the full frame's build would have had it. In the
// Input phase it is being routed: while it still holds presses or keys, newer presses and keys wait as well (they must
// not overtake them).
@(private = "file")
shell_split_input :: proc(app: ^App, polled: []platform.Event) -> []platform.Event {
	chrome := make([dynamic]platform.Event, 0, len(polled) + len(app.chrome_frames.outer), context.temp_allocator)
	app.chrome_frames.page_keyboard = page_has_keyboard(app)
	if !app.chrome_frames.outer_taken {
		#partial switch app.chrome_frames.phase {
		case .Loop:
			app.chrome_frames.outer_taken = true
			for ev in app.chrome_frames.outer { shell_route(app, ev, &chrome, false) }
		case .Anim:
			app.chrome_frames.outer_taken = true
			append(&chrome, ..app.chrome_frames.outer[:])
		}
	}
	hold := app.chrome_frames.phase == .Input && app.chrome_frames.outer_busy_input
	for ev in polled { shell_route(app, ev, &chrome, hold) }
	return chrome[:]
}

@(private = "file")
shell_route :: proc(app: ^App, ev: platform.Event, chrome: ^[dynamic]platform.Event, hold_buttons_and_keys: bool) {
	wnd := active_window(app)
	t := current_tab(app)
	page_shown := t != nil && t.kind == .Web
	over_page := page_shown && draw.rect_contains(wnd.page_rect, ev.pos) && !ui.ctx_menu_any_open() && !hud_captures(app, ev.pos)
	g := gesture_of(app)
	if page_shown && !hold_buttons_and_keys && shell_bar_event(app, t, ev, over_page) {
		if ev.kind != .Mouse_Move { g.held -= {ev.button} }
		if ev.kind == .Mouse_Move { append(chrome, ev) }   // (the chrome's hover)
		return
	}
	#partial switch ev.kind {
	case .Mouse_Move:
		append(chrome, ev)   // hover of the chrome (and its own pointer capture)
		// the page's hover, later; and the drag of a press that went to the page, wherever the pointer goes, as full frames give it
		dragging := .Left in g.held && .Left in ev.buttons
		if over_page || (page_shown && dragging) { append(&app.chrome_frames.deferred, ev) }
		if page_shown && dragging { selection_preview_move(app, t, ev.pos) }   // a text selection's drag: what it will select, shown now (selection_shell.odin)
	case .Mouse_Press:
		if hold_buttons_and_keys { append(&app.chrome_frames.deferred, ev); return }
		if over_page { g.held += {ev.button} } else { g.held -= {ev.button} }
		if over_page {
			app.chrome_frames.page_keyboard = true
			if !shell_deferred_buttons_or_keys(app) { selection_preview_press(app, t, ev) }   // a text selection's press: its gesture, shown now (selection_shell.odin)
			append(&app.chrome_frames.deferred, ev)
		} else {
			app.chrome_frames.page_keyboard = false
			append(chrome, ev)
		}
	case .Mouse_Release:
		if hold_buttons_and_keys || ev.button in g.held {
			g.held -= {ev.button}
			append(&app.chrome_frames.deferred, ev)
			return
		}
		append(chrome, ev)
	case .Scroll:
		if over_page && .Ctrl not_in ev.mods && t.page != nil {
			d := wheel_axes(ev) * wheel_step(app, (wnd.page_rect.max - wnd.page_rect.min) / max(page_scale(app), 0.01)) * page_scale(app)
			// a container under the pointer takes it (shell_shown.odin), shown at once when it can be, else at the page's turn
			if taken, wait := shell_wheel_box(app, t, ev.pos - wnd.page_rect.min, d); taken {
				if wait { append(&app.chrome_frames.deferred, ev) }
				return
			}
			shell_async_scroll(app, t, d)
			return
		}
		if over_page { append(&app.chrome_frames.deferred, ev); return }   // zoom: the page's layout
		append(chrome, ev)
	case .Key_Press, .Key_Release, .Text:
		if hold_buttons_and_keys || app.chrome_frames.page_keyboard {
			if !hold_buttons_and_keys && page_shown && shell_page_key(app, t, ev, chrome) { return }
			append(&app.chrome_frames.deferred, ev)
			return
		}
		append(chrome, ev)
	case:
		append(chrome, ev)
	}
}

// Where a chrome frame shows the tab's document: its offsets and the wheel taken meanwhile.
shell_shown_scroll :: proc(t: ^Tab) -> draw.Vec2 {
	if the_app.chrome_frames.pending_tab == t.id { return doc_scroll_vec(t) + the_app.chrome_frames.pending_scroll }
	return doc_scroll_vec(t)
}

// What chrome frames scroll belongs to one tab: another one's is dropped (it is shown no more).
shell_pending_for :: proc(app: ^App, t: ^Tab) {
	if app.chrome_frames.pending_tab == t.id { return }
	app.chrome_frames.pending_scroll, app.chrome_frames.pending_tab = {}, t.id
	clear(&app.chrome_frames.boxes)
}

// The wheel over a busy page: its last frame moves at once; the document takes the position when the page has its turn
// (shell_take_scroll).
@(private = "file")
shell_async_scroll :: proc(app: ^App, t: ^Tab, d: draw.Vec2) { shell_async_scroll_to(app, t, shell_shown_scroll(t) + d) }

// The document of a busy page shown at `to` (clamped to its range), and scrolled there when the page has its turn.
shell_async_scroll_to :: proc(app: ^App, t: ^Tab, to: draw.Vec2) {
	shell_pending_for(app, t)
	lo, limit: draw.Vec2
	if !app.chrome_frames.page_locked {   // (page thread: not read)
		size := draw.rect_size(active_window(app).page_rect)
		lo.x, limit.x = lay.doc_scroll_x_range(&t.layout, size.x)
		lo.y, limit.y = lay.doc_scroll_y_range(&t.layout, size.y)
	}
	if s := shell_snapshot_of(t.id); s != nil { lo, limit = {min(lo.x, s.lo.x), min(lo.y, s.lo.y)}, {max(limit.x, s.limit.x), max(limit.y, s.limit.y)} }
	from := draw.Vec2{t.layout.doc_scroll_x, t.scroll}
	app.chrome_frames.pending_scroll = draw.Vec2{clamp(to.x, lo.x, limit.x), clamp(to.y, lo.y, limit.y)} - from
}

// The document's scroll bars of a busy page, on its last frame: the press on a thumb, the drag's moves and its release are
// the shell's, as in a full frame (the gesture's owner is Thumb in either: a drag begun in one kind of frame goes on in the
// other), and the document is shown where the thumb puts it, as under the wheel. A container's thumb
// likewise while the page can be painted from its last layout (shell_shown.odin: the bar is found there, the container shown
// at its new offset), else it waits. A press waits for the page while presses or keys it has not had yet wait (it must not
// overtake them), and so does one on a container's track or arrows.
@(private = "file")
shell_bar_event :: proc(app: ^App, t: ^Tab, ev: platform.Event, over_page: bool) -> bool {
	g := gesture_of(app)
	p := ev.pos - active_window(app).page_rect.min
	#partial switch ev.kind {
	case .Mouse_Press:
		snap := shell_snapshot_of(t.id)
		if ev.button != .Left || !over_page || !gesture_free(g) || snap == nil || snap.page != t.page || shell_deferred_buttons_or_keys(app) { return false }
		shown := shell_shown_scroll(t)
		for vertical in ([2]bool{true, false}) {
			if !(vertical ? snap.bar : snap.bar_x) { continue }
			ax := vertical ? 1 : 0
			track := vertical ? snap.bar_track : snap.bar_x_track
			at := snap.limit[ax] > snap.lo[ax] ? clamp((shown[ax] - snap.lo[ax]) / (snap.limit[ax] - snap.lo[ax]), 0, 1) : 0
			thumb := thumb_along(track, vertical ? snap.bar_thumb : snap.bar_x_thumb, vertical, at)
			if !draw.rect_contains(thumb, p) { continue }
			rail := bar_rail(track, vertical)
			gesture_take(app, t, .Thumb, .Left).thumb = Scrollbar_Drag{node = base.NIL_HANDLE, vertical = vertical, grab = p[ax] - thumb.min[ax],
				track_min = rail.min[ax], travel = (rail.max[ax] - rail.min[ax]) - (thumb.max[ax] - thumb.min[ax]), lo = snap.lo[ax], limit = snap.limit[ax]}
			bar_over_set(app, {&t.layout, base.NIL_HANDLE, vertical, {.Thumb, true}})
			return true
		}
		return shell_box_bar_press(app, t, p)   // a container's thumb, shown from the layout (shell_shown.odin)
	case .Mouse_Move:
		// (a container's drag goes on while its page can be painted from its layout; else its moves wait for the page)
		if !shell_holds_thumb(app, g, t) { return false }
		dr := g.thumb
		ax := dr.vertical ? 1 : 0
		f := dr.travel > 0 ? clamp((p[ax] - dr.grab - dr.track_min) / dr.travel, 0, 1) : 0
		if dr.node != base.NIL_HANDLE {
			to := shell_box_shown(app, t, dr.node)
			to[ax] = dr.lo + f * (dr.limit - dr.lo)
			shell_box_scroll_to(app, t, dr.node, to)
			return true
		}
		to := shell_shown_scroll(t)
		to[ax] = dr.lo + f * (dr.limit - dr.lo)
		shell_async_scroll_to(app, t, to)
		return true
	case .Mouse_Release:
		if ev.button != .Left || !shell_holds_thumb(app, g, t) { return false }
		bar_let_go(app, t, ev, over_page)
		return true
	}
	return false
}

// The thumb held is `t`'s, and a chrome frame can follow it: a container's while its page can be painted from its layout.
@(private = "file")
shell_holds_thumb :: proc(app: ^App, g: ^Pointer_Gesture, t: ^Tab) -> bool {
	return g.owner == .Thumb && g.tab == t && t.page == g.top && (g.thumb.node == base.NIL_HANDLE || shell_layout_paintable(app, t))
}

// A key meant for the busy page that its turn would not give it anything to run for: no key listener anywhere (keydown,
// keyup, keypress) and nothing of the user's waiting for it before. Then what the key does is done now, as that turn would do
// it: the browser's shortcuts go to the chrome (forms_shell.odin browser_shortcut, and the tab keys, which no default action
// of the page takes), the keys that scroll the document scroll its last frame (keyscroll.odin; not when a form control has
// the focus or a scroll container would take the key). True when done; anything else waits for the page.
@(private = "file")
shell_page_key :: proc(app: ^App, t: ^Tab, ev: platform.Event, chrome: ^[dynamic]platform.Event) -> bool {
	p := t.page
	if p == nil || ev.kind == .Text || shell_deferred_buttons_or_keys(app) { return false }
	if page.page_listens(p, "keydown") || page.page_listens(p, "keyup") || page.page_listens(p, "keypress") { return false }
	ctrl := .Ctrl in ev.mods
	modifier := ev.key == .Ctrl || ev.key == .Shift || ev.key == .Alt   // (held for a shortcut: nothing of the page's either)
	if modifier || browser_shortcut(ev) || (ctrl && .Alt not_in ev.mods && (ev.key == .Tab || ev.key == .Page_Up || ev.key == .Page_Down)) {
		append(chrome, ev)
		return true
	}
	k := key_scroll_of(ev)
	if k == .None || !key_scroll_vertical(k) || !shell_layout_paintable(app, t) { return false }
	focus := base.NIL_HANDLE
	if p.formctl != nil && p.formctl.model != nil {
		f := p.formctl.model
		focus = f.focus
		if focus != base.NIL_HANDLE && (forms.kind(f, focus) != .None || forms.is_text_field(f, focus)) { return false }
	}
	if _, _, taken := key_scroll_container(app, t, focus != base.NIL_HANDLE ? focus : t.scroll_target, k); taken { return false }
	if ev.kind == .Key_Press { shell_async_scroll_to(app, t, key_scroll_document(app, t, k, shell_shown_scroll(t))) }
	return true
}

// Presses, releases or keys wait for the page.
@(private = "file")
shell_deferred_buttons_or_keys :: proc(app: ^App) -> bool {
	for ev in app.chrome_frames.deferred {
		#partial switch ev.kind {
		case .Mouse_Press, .Mouse_Release, .Key_Press, .Key_Release, .Text: return true
		}
	}
	return false
}

////////////////////////////////
// Deferred actions

// What the build of the tabs asks of their list: done before the next frame of the window, whatever kind of frame is being built. A build is never cut short by a
// list that changed under it: the frame it would leave has the window's colour where the toolbar, the page and the status bar were, and that frame is presented.
shell_after_build :: proc(app: ^App, a: Shell_Action) {
	a := a
	a.window = app.active.id
	append(&app.chrome_frames.actions, a)
	request_frames(app, 2)
}

// What waits is done (never under a guest: at the start of a frame and at the end of its page phase), but what another window asked, which waits for that window's frame.
shell_actions_run :: proc(app: ^App) {
	if len(app.chrome_frames.actions) == 0 { return }
	todo := make([]Shell_Action, len(app.chrome_frames.actions), context.temp_allocator)
	copy(todo, app.chrome_frames.actions[:])
	clear(&app.chrome_frames.actions)
	ran := false
	for a in todo {
		if a.window != 0 && a.window != app.active.id && window_by_id(app, a.window) != nil {
			append(&app.chrome_frames.actions, a)
			continue
		}
		shell_run_action(app, a)
		delete(a.text)
		ran = true
	}
	if ran { request_frames(app, 3) }
}

// Inside a chrome frame, queues what the chrome asks of pages; true when queued (the caller does nothing now).
shell_defer :: proc(a: Shell_Action) -> bool {
	if !the_app.chrome_frames.nested { return false }
	append(&the_app.chrome_frames.actions, a)
	return true
}

@(private = "file")
shell_tab_by_id :: proc(app: ^App, id: u64) -> (^Tab, int) {
	return tab_by_id(app, id), -1
}

@(private = "file")
shell_run_action :: proc(app: ^App, a: Shell_Action) {
	if a.kind == .Prefs { apply_prefs(app); return }
	t, _ := shell_tab_by_id(app, a.tab)
	if t == nil && a.kind != .Command { return }   // closed meanwhile
	switch a.kind {
	case .Command:
		if c := command(app, a.text); c != nil { command_run(app, t != nil ? t : current_tab(app), c) }
	case .Navigate:
		from: ^page.Page   // (the page may be gone by now: it is passed only if a tab still has it)
		for tab in tabs_all(app) { if a.from != nil && tab.page == a.from { from = a.from; break } }
		navigate(app, t, a.text, from, user_activation = a.flag, record = a.record, restore = a.restore, cache = a.cache, origin = a.origin)
	case .Reload:
		reload(app, t, a.flag)
	case .History:
		go_history(app, t, a.delta)
	case .Entry:
		if e := page.session_find(&t.session, a.entry); e != nil { go_entry(app, t, e) }
	case .Close_Tab:
		tab_close_tab(app, t)
	case .Tear_Off:
		tab_drag_begin(app, t, a.at)
	case .Prefs:
	}
}

////////////////////////////////
// Snapshots of pages

shell_snapshot_of :: proc(tab: u64) -> ^Page_Snapshot {
	for &s in the_app.chrome_frames.snaps { if s.tab == tab { return &s } }
	return nil
}

// After the page was painted (page_draw, in its clip): its pixels are kept for chrome frames, when the frame found them
// worth keeping (Window_Own.page_snapshot_wanted).
shell_capture :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect, canvas: draw.Color) {
	if !app.chrome_frames.cfg.snapshot || !app.chrome_frames.cfg.preempt || !window_own(app).page_snapshot_wanted { return }
	bd := draw.backdrop_capture(dc, rect, nil)
	if bd.image.tex == 0 { return }
	if !render.keep_target(dc.renderer, bd.image.tex) { render.release_target(dc.renderer, bd.image.tex); return }
	bd.kept = true
	gen := render.targets_generation(dc.renderer)
	s := shell_snapshot_of(t.id)
	if s == nil {
		shell_snapshots_trim(app, max(app.chrome_frames.cfg.snapshot_tabs - 1, 0))
		append(&app.chrome_frames.snaps, Page_Snapshot{tab = t.id})
		s = &app.chrome_frames.snaps[len(app.chrome_frames.snaps) - 1]
	} else if s.image.image.tex != 0 && s.gen == gen {
		render.unkeep_target(dc.renderer, s.image.image.tex)
	}
	s.image, s.rect, s.scroll, s.canvas, s.gen, s.used, s.page, s.scale = bd, rect, doc_scroll_vec(t), canvas, gen, app.chrome_frames.frame_no, t.page, page_scale(app)
	s.selection[0], s.selection[1], _ = page.selection_range(t.page)
	s.lo.x, s.limit.x = lay.doc_scroll_x_range(&t.layout, draw.rect_size(rect).x)
	s.lo.y, s.limit.y = lay.doc_scroll_y_range(&t.layout, draw.rect_size(rect).y)
	// (more than fit: the last one takes the rest, as their union)
	s.n_stuck = 0
	for r in composite_stuck() {
		if s.n_stuck < SNAPSHOT_STUCK_MAX {
			s.stuck[s.n_stuck] = r
			s.n_stuck += 1
		} else {
			last := &s.stuck[SNAPSHOT_STUCK_MAX - 1]
			last^ = {{min(last.min.x, r.min.x), min(last.min.y, r.min.y)}, {max(last.max.x, r.max.x), max(last.max.y, r.max.y)}}
		}
	}
	size := draw.rect_size(rect)
	track, thumb, ok := lay.doc_scrollbar(&t.layout, size, math.round(t.scroll))
	track_x, thumb_x, ok_x := lay.doc_scrollbar_x(&t.layout, size)
	corner, _ := lay.doc_scroll_corner(&t.layout, size)
	s.bar, s.bar_x = ok, ok_x
	s.bar_track, s.bar_thumb = draw.Rect{track.min, track.max}, draw.Rect{thumb.min, thumb.max}
	s.bar_x_track, s.bar_x_thumb = draw.Rect{track_x.min, track_x.max}, draw.Rect{thumb_x.min, thumb_x.max}
	s.bar_corner = draw.Rect{corner.min, corner.max}
	if ok || ok_x { s.bar_colors = doc_scrollbar_colors(&t.layout) }
}

// Where a bar's thumb runs: its track, less the arrow buttons of a classic bar.
@(private = "file")
bar_rail :: proc(track: draw.Rect, vertical: bool) -> draw.Rect {
	if the_app.page_render.settings.scrollbar_overlay { return track }
	_, _, r := lay.classic_parts(lay.Rect{track.min, track.max}, vertical)
	return draw.Rect{r.min, r.max}
}

// A captured thumb moved along its bar to `t` (0..1) of its travel.
@(private = "file")
thumb_along :: proc(track, thumb: draw.Rect, vertical: bool, t: f32) -> draw.Rect {
	if thumb.max == thumb.min { return thumb }
	ax := vertical ? 1 : 0
	rail := bar_rail(track, vertical)
	length := thumb.max[ax] - thumb.min[ax]
	moved := thumb
	moved.min[ax] = rail.min[ax] + (rail.max[ax] - rail.min[ax] - length) * t
	moved.max[ax] = moved.min[ax] + length
	return moved
}

// Where the tab's document is shown, in the pixels of its last frame: a zoom keeps the same part of the document at the top while its offsets scale (zoom.odin zoom_set), and
// the frame, at its own scale, stays where it is until the new layout is painted. (Taken as a scroll, the offsets' change moved it out of the page area, by a screen and more
// far down a long document, and the canvas filled what it left.)
@(private = "file")
shell_kept_scroll :: proc(app: ^App, t: ^Tab, s: ^Page_Snapshot) -> draw.Vec2 {
	scroll := shell_shown_scroll(t)
	now := page_scale(app)
	if s.scale == now { return scroll }
	scroll *= s.scale / now
	near := abs(scroll.x - s.scroll.x) < SNAPSHOT_ZOOM_ROUNDING_PX && abs(scroll.y - s.scroll.y) < SNAPSHOT_ZOOM_ROUNDING_PX
	return near ? s.scroll : scroll
}

// Draws a tab's last page frame in the page area, moved by the wheel taken meanwhile and anchored at the top left.
// False when there is none (the caller shows something else).
shell_paint_page :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect) -> bool {
	s := shell_snapshot_of(t.id)
	if s == nil || s.image.image.tex == 0 || s.gen != render.targets_generation(dc.renderer) { return false }
	if s.page != t.page {
		// another document since: its last frame stays only as long as the full frames hold it (first_paint.odin: hold_paint)
		h := &t.hold
		if !h.active || h.page != s.page || (h.committed && shell_elapsed_ms(h.commit) >= app.scheme_ui.timeout_ms) { return false }
	}
	s.used = app.chrome_frames.frame_no
	draw.rect(dc, rect, s.canvas)
	scroll := shell_kept_scroll(app, t, s)
	img := s.image
	shift := (rect.min - s.rect.min) - (scroll - s.scroll)
	img.image.origin += shift
	covered := draw.rect_intersect(rect, draw.Rect{img.image.origin, img.image.origin + draw.Vec2{f32(img.image.size.x), f32(img.image.size.y)}})
	if covered.max.x <= covered.min.x || covered.max.y <= covered.min.y { return true }
	draw.push_clip(dc, rect)
	draw.backdrop_draw(dc, img, covered, {})
	if scroll != s.scroll && s.n_stuck > 0 {
		// a fixed header or a sticky box does not scroll with the page: it stays where the last frame drew it (the wheel moves what is under it)
		still := s.image
		still.image.origin += rect.min - s.rect.min
		// the picture carried them with the page: where they now sit is a ghost of them, cleared (the next full frame paints what
		// was under them) before they are drawn where they belong
		for i in 0 ..< s.n_stuck {
			g := draw.rect_intersect(draw.rect_shift(s.stuck[i], rect.min - s.rect.min - (scroll - s.scroll)), rect)
			if g.max.x <= g.min.x || g.max.y <= g.min.y { continue }
			draw.rect(dc, g, s.canvas)
		}
		for i in 0 ..< s.n_stuck {
			r := draw.rect_intersect(draw.rect_shift(s.stuck[i], rect.min - s.rect.min), rect)
			if r.max.x <= r.min.x || r.max.y <= r.min.y { continue }
			draw.push_clip(dc, r)
			draw.backdrop_draw(dc, still, r, {})
			draw.pop_clip(dc)
		}
	}
	bars := &t.layout
	if s.bar {
		t := s.limit.y > s.lo.y ? clamp((scroll.y - s.lo.y) / (s.limit.y - s.lo.y), 0, 1) : 0
		paint_bar(dc, draw.rect_shift(s.bar_track, rect.min), draw.rect_shift(thumb_along(s.bar_track, s.bar_thumb, true, t), rect.min), true, s.bar_colors, bar_look(bars, base.NIL_HANDLE, true))
	}
	if s.bar_x {
		t := s.limit.x > s.lo.x ? clamp((scroll.x - s.lo.x) / (s.limit.x - s.lo.x), 0, 1) : 0
		paint_bar(dc, draw.rect_shift(s.bar_x_track, rect.min), draw.rect_shift(thumb_along(s.bar_x_track, s.bar_x_thumb, false, t), rect.min), false, s.bar_colors, bar_look(bars, base.NIL_HANDLE, false))
	}
	if s.bar_corner.max != s.bar_corner.min { draw.rect(dc, draw.rect_shift(s.bar_corner, rect.min), to_draw(s.bar_colors.track)) }
	draw.pop_clip(dc)
	return true
}

// What a page's frame was painted from besides its layout (page_paint). While none of it has moved, a chrome frame may paint
// the page again from that layout: the same pixels, but for what the shell changed meanwhile.
Paint_Source :: struct {
	page:      ^page.Page,
	mutations: u64,    // the document's (the layout painted was made from it)
	pixels:    u64,    // its images' and canvases' pixels
	forms:     u64,    // what its form controls show
	rules:     bool,   // its style rules changed since its styles were computed
}

paint_source :: proc(t: ^Tab) -> Paint_Source {
	p := t.page
	a := page.page_activity(p)
	s := Paint_Source{page = p, mutations = a.mutations, pixels = a.pixels, rules = a.rules}
	if p.formctl != nil && p.formctl.model != nil { s.forms = p.formctl.model.serial }
	return s
}

// The current tab's page can be painted from the layout of its last frame in a chrome frame: that layout is not on the page
// thread, was painted at this size, and nothing it was painted from has changed since (the script holding the thread changed
// nothing yet that shows); the page has no frames (their documents are laid out as they are painted).
shell_layout_paintable :: proc(app: ^App, t: ^Tab) -> bool {
	if app.chrome_frames.page_locked || t.page == nil || !t.layout.valid { return false }
	own := window_own(app)
	prep := &own.page_prep
	if prep.tab != t || prep.page != t.page || prep.state != .Ready || prep.size != draw.rect_size(active_window(app).page_rect) || prep.scale != page_scale(app) { return false }
	if t.page.frames != nil && len(t.page.frames.children) > 0 { return false }
	return own.page_painted == paint_source(t)
}

// The page painted again from the layout of its last frame, in place of its pixels (shell_layout_paintable), for what the shell
// changed meanwhile: the document scrolled by the wheel or a scroll bar's thumb (what was not in view comes into view, fixed
// and sticky boxes stay where they belong), a drag's selection (selection_shell.odin Sel_Preview), the animations the
// compositor runs, the containers scrolled, the caret's blink (shell_shown.odin). Nothing of the page runs: the painter reads
// the layout, the document, the styles and the compositor's pictures (it may record some again).
shell_paint_layout :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, rect: draw.Rect) {
	size := draw.rect_size(rect)
	scroll := shell_shown_scroll(t)
	draw.rect(dc, rect, to_draw(window_own(app).page_prep.canvas))
	draw.push_clip(dc, rect)
	selection_paint_begin(app, t)
	shell_shown_caret(app, t)
	sh := shell_shown_set(app, t, painting = true)
	paint(shell_shown_layout(app, t, &sh, size), dc, t.page.doc, rect.min, size, scroll.y, rect, doc_scrollbar = false)
	shell_shown_put(&sh)
	paint_doc_scrollbar(&t.layout, dc, rect.min, size, scroll.y)
	draw.pop_clip(dc)
}

// A chrome frame paints the page from its layout when the shell changed what it shows (it scrolled the document vertically, a
// drag selects, shell_shown_wanted) and it can (shell_layout_paintable); else its kept pixels. (A sideways scroll is the
// layout's own offset: kept pixels for it.)
shell_layout_wanted :: proc(app: ^App, t: ^Tab) -> bool {
	scrolled := app.chrome_frames.pending_tab == t.id && app.chrome_frames.pending_scroll != {}
	if scrolled && app.chrome_frames.pending_scroll.x != 0 { return false }
	if !shell_layout_paintable(app, t) { return false }
	shown, _ := shell_shown_wanted(app, t)
	return scrolled || selection_preview_shown(app, t) || shown
}

// Keeps at most `keep` snapshots (the current tab's and the most recently used).
@(private = "file")
shell_snapshots_trim :: proc(app: ^App, keep: int) {
	cur := current_tab(app)
	for len(app.chrome_frames.snaps) > keep {
		worst := -1
		for s, i in app.chrome_frames.snaps {
			if cur != nil && s.tab == cur.id { continue }
			if worst < 0 || s.used < app.chrome_frames.snaps[worst].used { worst = i }
		}
		if worst < 0 { break }
		shell_snapshot_drop(app, worst)
	}
}

@(private = "file")
shell_snapshot_drop :: proc(app: ^App, i: int) {
	s := app.chrome_frames.snaps[i]
	if s.image.image.tex != 0 && s.gen == render.targets_generation(&app.r) { render.unkeep_target(&app.r, s.image.image.tex) }
	unordered_remove(&app.chrome_frames.snaps, i)
}

@(private = "file")
shell_snapshots_clear :: proc(app: ^App) {
	for len(app.chrome_frames.snaps) > 0 { shell_snapshot_drop(app, len(app.chrome_frames.snaps) - 1) }
}

// The layer targets go, for the memory they hold (memory_trim.odin), but the picture of the tab on screen: the first chrome frame after an idle moment
// is what it is kept for, and without it a Ctrl+wheel or a long script showed the page's background for a frame.
shell_release_targets :: proc(app: ^App) {
	t := current_tab(app)
	s := t != nil ? shell_snapshot_of(t.id) : nil
	kept := s != nil && s.image.image.tex != 0 && s.gen == render.targets_generation(&app.r)
	render.release_targets(&app.r, kept ? s.image.image.tex : 0)
	if kept { s.gen = render.targets_generation(&app.r) }
}

// Once per full frame: the snapshots of closed tabs go.
shell_snapshots_frame :: proc(app: ^App) {
	for i := len(app.chrome_frames.snaps) - 1; i >= 0; i -= 1 {
		if t, _ := shell_tab_by_id(app, app.chrome_frames.snaps[i].tab); t == nil { shell_snapshot_drop(app, i) }
	}
}
