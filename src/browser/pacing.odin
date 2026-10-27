package browser

// Frame pacing: the rate frames are made at while something moves, and the clock they show.
//
// The target rate is the refresh rate of the monitor the window is on (platform.display_info: the exact rate of the
// display path, e.g. 179.98 Hz, read again when the window changes monitor or the mode changes), or browser.frame.target_hz,
// capped by browser.frame.max_hz. Its period is the frame budget everything is measured against (status bar, title,
// profiler): 5.56 ms at 180 Hz.
//
// How frames are paced:
//   * Vsync (default): the swap chain's latency object (at most one frame queued) releases each frame at a vblank. A
//     target that divides the display's rate presents every n-th refresh (sync interval); any other lower target is
//     timed by the browser (a high-resolution waitable timer) and shown at the next vblank.
//   * Tearing (browser.frame.present_mode = tearing): frames are presented as soon as they are ready, which a variable
//     refresh display (G-Sync, FreeSync) shows at once; the browser times them at the target rate.
// While waiting the window still takes its keyboard and mouse input (platform.wait_handle), time-stamped as it arrives:
// the frame starts on the freshest input, and the time from an event to the vblank its frame showed at is measured
// (render.take_displayed: input latency and missed refreshes, in the status bar's panel).
//
// The frame's time (`pacer.frame_ms`, on the event loop clock) is the vblank the frame starts at, on the grid the swap
// chain's frame statistics give: requestAnimationFrame timestamps, the CSS animation clock and smooth scrolling all
// advance by whole refresh periods, whatever the jitter of the thread waking up.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

// PACING_DEBUG: every wait for the screen and every smooth scrolling step on stderr (build with -subsystem:console).
PACING_DEBUG :: #config(PACING_DEBUG, false)
_ :: fmt   // PACING_DEBUG only

FRAME_PREFS := [?]config.Def{
	{name = "browser.frame.target_hz", kind = .String, default = {s = "auto"},
		description = "Frames per second while something moves (nothing moves: no frames). auto = the refresh rate of the monitor the window is on (followed when the window moves to another monitor or the display mode changes). A number of hertz (10 to 1000) paces frames at that rate instead, e.g. to see how pages behave at 60 or 120 Hz on a faster monitor: a whole divisor of the monitor's rate shows every n-th refresh, another rate is timed by the browser. The frame budget (status bar, profiler) follows it."},
	{name = "browser.frame.variable_refresh", kind = .String, default = {s = "auto"}, choices = {"auto", "on", "off"},
		description = "A screen with a variable or dynamic refresh rate (G-Sync, FreeSync, Windows 11's dynamic refresh rate, which rests at 60 Hz and goes up to 180 Hz while something moves) reports the rate it rests at, not the one it shows frames at. auto: when the monitor offers modes above the rate it reports, frames aim for the highest (browser.frame.target_hz = auto) and are timed by the browser, never faster, whatever the input rate (a mouse at 1000 Hz makes a frame per period, not per move). on: the same for a screen that reports its top rate but varies it (G-Sync without a dynamic rate). off: the rate the system reports. Reported as `variableRefresh`, `hz`, `hzMax` and `hzNow` in `wren ctl stats`."},
	{name = "browser.frame.max_hz", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 1000, unit = "Hz",
		description = "Most frames per second whatever the monitor (0 = no limit), e.g. 60 to save power on a 180 Hz monitor."},
	{name = "browser.frame.present_mode", kind = .String, default = {s = "vsync"}, choices = {"vsync", "tearing"},
		description = "vsync: each frame waits for a refresh of the monitor (no tearing). tearing: frames are shown as soon as they are ready, for variable refresh monitors (G-Sync, FreeSync), which then refresh when a frame comes; the browser paces them at browser.frame.target_hz. Without the system's support for it, vsync."},
	{name = "browser.frame.wait_timeout_ms", kind = .Int, default = {i = 100}, bounded = true, min = 1, max = 2000, unit = "ms",
		description = "Longest wait for the screen to take the next frame (a monitor that stopped refreshing, a locked session)."},
	{name = "browser.frame.swap_buffers", kind = .Int, default = {i = 3}, bounded = true, min = 2, max = 4, restart = true,
		description = "Back buffers of the window's swap chain. 3 lets a frame be presented while the desktop compositor still holds the previous one (no wait in Present when frames come faster than the monitor refreshes: tearing mode, a variable refresh monitor); the time from input to screen does not grow (one frame in flight at most). 2 saves one window-sized buffer of GPU memory."},
	{name = "browser.frame.latency_probe", kind = .Bool, default = {b = false},
		description = "Measures the time from each input event to the refresh that showed it, stage by stage (wait for the frame, build and draw, Present, scan-out): p50 / p95 / max in the `latency` field of `wren ctl stats` (`stats --reset-latency` starts a new measure). The environment variable WREN_LATENCY=1 turns it on for one run. Off: nothing is recorded."},
	{name = "browser.frame.drag_probe", kind = .Bool, default = {b = false},
		description = "Records, for each frame made while a tab is dragged, the pointer it was built from, where the tab was drawn and the refresh that showed it: `dragSamples` in `wren ctl stats` (`stats --reset-frames` starts a new run). Off: nothing is recorded."},
}

// Preferences of the pacing that the cadence model (toolkit platform/pacing.odin) replaced: what they chose is the model's
// own behaviour now (their defaults). A profile that still sets them is read without error: config keeps a value of a name
// nobody registers and applies it to nothing.
RETIRED_FRAME_PREFS :: [?]string{
	"browser.frame.vblank_clock",        // the frame's time is always its vblank (or its slot on a timed cadence)
	"browser.frame.input_immediate",     // the frame that starts an answer to input is always shown at once (Input_Answer)
	"browser.frame.input_idle_periods",  // platform.CADENCE_INPUT_REST_PERIODS (1.5)
	"browser.frame.video_at_vblank",     // a video's picture is always the one due when the frame is shown
	"browser.frame.resize_immediate",    // a resize step is always shown at once (Resize_Step)
	"browser.frame.resize_hold_ms",      // platform.CADENCE_RESIZE_HOLD_NS (120 ms, Resize_Burst)
	"browser.frame.resize_skip_echoes",  // a burst's frame with nothing new is never made (platform.cadence_echo)
}

register_frame_prefs :: proc(p: ^config.Prefs) { config.register(p, FRAME_PREFS[:]) }

Pacer_Settings :: struct {
	target_hz:  f64,                   // 0 = the display's
	max_hz:     f64,                   // 0 = none
	mode:       render.Present_Mode,
	timeout_ms: int,
	latency_probe: bool,
	drag_probe: bool,
	variable:   platform.Variable_Refresh,
}

pacer_settings_from_prefs :: proc(p: ^config.Prefs) -> Pacer_Settings {
	s := Pacer_Settings{
		max_hz = config.float_of(p, "browser.frame.max_hz"),
		mode = config.string_of(p, "browser.frame.present_mode") == "tearing" ? .Tearing : .Vsync,
		timeout_ms = int(config.int_of(p, "browser.frame.wait_timeout_ms")),
		drag_probe = config.bool_of(p, "browser.frame.drag_probe"),
		latency_probe = config.bool_of(p, "browser.frame.latency_probe") || os.get_env("WREN_LATENCY", context.temp_allocator) == "1",
	}
	s.target_hz = parse_target_hz(config.string_of(p, "browser.frame.target_hz"))
	switch config.string_of(p, "browser.frame.variable_refresh") {
	case "on":  s.variable = .On
	case "off": s.variable = .Off
	}
	return s
}

// "auto" (or anything that is no rate) = 0; a number of hertz, clamped to 10 .. 1000.
parse_target_hz :: proc(s: string) -> f64 {
	v := strings.trim_space(s)
	v = strings.trim_suffix(strings.trim_suffix(v, "Hz"), "hz")
	f, ok := strconv.parse_f64(strings.trim_space(v))
	if !ok || math.is_nan(f) || f <= 0 { return 0 }
	return clamp(f, 10, 1000)
}

// The browser's side of the cadence model (toolkit platform/pacing.odin, docs/pacing.md): the model decides, from the screen,
// the preferences and what happened since the last frame, when a frame starts, whether it waits for the screen and how it
// is shown; pacer_wait and pacer_begin_frame execute that decision (a high-resolution timer, the swap chain's latency
// object, the frame's time) and pacer_end_frame tells the model about the present.
Pacer :: struct {
	cfg:        Pacer_Settings,
	watch:      int,
	display:    platform.Display_Info,
	hz:         f64,          // the rate aimed for
	period_ms:  f64,          // 1000 / hz: the frame budget
	interval:   int,          // vsync refreshes per frame
	timed:      bool,         // frames are timed by the browser (platform.cadence_sync)
	tearing:    bool,         // presenting with tearing (asked for and supported)
	timer:      win.HANDLE,   // the timing of timed frames (high resolution waitable timer)
	variable:   bool,         // the screen shows frames above the rate it reports: the target is its top rate
	cadence:    platform.Cadence,          // the model's memory: its clock (slots), the last frame's state
	decision:   platform.Frame_Decision,   // this frame's (pacer_wait)
	using clock: platform.Frame_Clock,     // this frame's time (frame_ms, on the event loop clock), the previous one's, dt
	live_hz:    f64,          // the highest rate the compositor reported during the current run of frames (display_live_hz; 0: none)
	live_ns:    i64,          // tick of the last such measure
	continuous: bool,         // this frame follows the previous one without idling
	waited_ms:  f64,          // time spent waiting for the screen (or the timer) at the start of this frame
	missed_timeouts: int,     // waits that ran into wait_timeout_ms
	slot_held:  bool,         // the latency object was waited for and no frame was presented since (pacer_wait)
	size:       [2]int,       // the window's size at the last frame (another one: the window is being resized)
	echoes_skipped: int,      // frames of a resize burst not made (resize_echo_frame)
	resize_causes: [Resize_Frame_Cause]int,                  // why the frames of a resize burst were made
	resize_event_kinds: [platform.Event_Kind]int,            // the events of those made for events
	latency:    int,          // frames the swap chain may queue (the decision's: 1, or 2 for a frame shown at once)
	read_tick:  i64,          // tick this frame had read its input (the key of its Displayed_Frame)
}

pacer: Pacer

pacer_init :: proc(app: ^App) {
	pacer.cfg = pacer_settings_from_prefs(&app.prefs)
	render.set_latency_probe(&app.r, pacer.cfg.latency_probe)
	CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
	pacer.timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if pacer.timer == nil { pacer.timer = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS) }   // before Windows 10 1803
	pacer.watch = config.watch(&app.prefs, "browser.frame.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		pacer.cfg = pacer_settings_from_prefs(p)
		render.set_latency_probe(&app.r, pacer.cfg.latency_probe)
		pacer.display.serial = 0   // plan again
		request_frames(app, 2)
	}, app)
	pacer_update(app)
}

pacer_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, pacer.watch)
	if pacer.timer != nil { win.CloseHandle(pacer.timer) }
	pacer = {}
}

// The model's choices from the preferences (`tearing`: asked for and supported).
pacer_choices :: proc(cfg: Pacer_Settings, tearing: bool) -> platform.Cadence_Choices {
	return {target_hz = cfg.target_hz, max_hz = cfg.max_hz, variable = cfg.variable, tearing = tearing}
}

// The monitor's rate and the preferences, turned into a plan: once per frame (cheap unless something changed).
pacer_update :: proc(app: ^App) {
	// the page's idle periods leave room for a frame of this length (timers.frame_budget_ms = 0); apply_prefs makes the
	// settings again from the preferences
	defer app.page_settings.web.frame_period_ms = pacer.period_ms
	d := platform.display_info(active_window(app).win)
	if d.serial == pacer.display.serial && pacer.hz > 0 { return }
	pacer.display = d
	pacer.tearing = pacer.cfg.mode == .Tearing && render.tearing_supported(&app.r)
	plan := platform.cadence_plan(d, pacer_choices(pacer.cfg, pacer.tearing))
	pacer.variable, pacer.hz, pacer.period_ms, pacer.interval, pacer.timed = plan.variable, plan.hz, plan.period_ms, plan.interval, plan.timed
	pacer.cadence.slots = plan.slots
	render.set_present_mode(&app.r, pacer.tearing ? .Tearing : .Vsync)
	render.set_sync_interval(&app.r, pacer.interval)
	// missed refreshes of timed frames (a variable screen has no fixed refresh to miss)
	render.set_expected_refreshes(&app.r, pacer.timed && !pacer.tearing && !pacer.variable && pacer.hz > 0 ? d.hz / pacer.hz : 0)
	pacer.decision.slot_ns = 0
}

Resize_Frame_Cause :: enum u8 { Step, Events, Tasks, Page, Ui_Animation, Ui_Timer, Scrolling, Layout_Size }

// frame() (main.odin): whether this frame is an echo of a resize step (platform.cadence_echo); it is then not made (frames
// asked for are forgotten): one picture per step of a resize instead of three.
resize_echo_frame :: proc(app: ^App, events: []platform.Event, ran: int, page_wants: bool) -> bool {
	wnd := active_window(app)
	// (a repaint the system asks for after a step is not a reason: the step's frame was drawn at the new size and the swap
	// chain keeps it on screen)
	cause := Resize_Frame_Cause.Page
	switch {
	case ui.needs_frame(wnd.ui): cause = .Ui_Animation
	case ui.wake_due(wnd.ui): cause = .Ui_Timer
	}
	wants := page_wants || cause != .Page
	// a step is a frame at a size not drawn yet (the window's size against the renderer's: pacer_wait only sees a size
	// that came before its wait, and calls the frame after the one that drew it a step too)
	step := wnd.win.size != app.r.size
	if t := current_tab(app); t != nil && t.page != nil {
		if len(t.smooth.anims) > 0 { wants = true; cause = .Scrolling }
		if pp := &window_own(app).page_prep; pp.tab == t && pp.size != draw.rect_size(wnd.page_rect) { wants = true; cause = .Layout_Size }   // laid out at another size: the next frame settles it
	}
	if !platform.cadence_echo(&pacer.cadence, step, len(events), ran, wants) {
		// why a frame of a resize was made (wren ctl stats: resizeFrameCauses)
		if platform.cadence_resizing(&pacer.cadence) {
			c := &pacer.resize_causes
			switch {
			case step: c[.Step] += 1
			case len(events) > 0: c[.Events] += 1; for e in events { c_ev := &pacer.resize_event_kinds[e.kind]; c_ev^ += 1 }
			case ran > 0: c[.Tasks] += 1
			case page_wants: c[.Page] += 1
			case: c[cause] += 1
			}
		}
		return false
	}
	wnd.frames_requested = 0
	platform.take_paint_request(wnd.win)
	pacer.echoes_skipped += 1
	return true
}

// Present without waiting for a refresh: the resize step, a frame of the burst after it, the frame that answers input.
pacer_at_once :: proc() -> bool { return platform.cadence_at_once(&pacer.cadence) }

// The frame is a step of a resize: made at once, whatever the screen and the cadence (chrome frames too).
pacer_resize_step :: proc() -> bool { return pacer.cadence.state == .Resize_Step }

// The frame belongs to a resize (its step or its burst).
pacer_resizing :: proc() -> bool { return platform.cadence_resizing(&pacer.cadence) }

// The frame budget in ms: what one frame may take at the target rate.
frame_budget_ms :: proc() -> f32 { return pacer.period_ms > 0 ? f32(pacer.period_ms) : 1000.0 / 60 }

// The most frames the swap chain in use may queue: two for a frame shown at once (see pacer_wait), else one. `latency` is
// the window's own memory of it (the swap chain in use is the renderer's current one: the main window's, or a surface made
// current by devtools_window.odin).
pacer_latency :: proc(app: ^App, latency: ^int, two: bool) {
	want := two ? 2 : 1
	if want != latency^ {
		render.set_max_frame_latency(&app.r, want)
		latency^ = want
	}
}

// At the start of a frame: the model's decision (platform.frame_decision), executed: the wait for the frame's slot (a
// high-resolution timer), then for the swap chain to take a frame, taking input meanwhile. `idled`: the loop slept before
// this frame (nothing moved): it starts a new run of frames.
pacer_wait :: proc(app: ^App, idled: bool) {
	wnd := active_window(app)
	t0 := time.tick_now()
	defer pacer.waited_ms = time.duration_milliseconds(time.tick_since(t0))
	pacer.continuous = !idled
	resized := wnd.win.size != pacer.size
	pacer.size = wnd.win.size
	d := platform.frame_decision(&pacer.cadence, {
		now_ns = time.tick_now()._nsec, idled = idled,
		// (the user's input, not other threads' wake-ups: shell_user_input_pending)
		input = shell_user_input_pending(), presented = wnd.presented, resized = resized,
		// a splitter, the sidebar's handle, a tab: paced one frame per slot, never as a resize step
		dragging = ui.active_key() != 0 || tab_dragging(),
		slot_held = pacer.slot_held,
	})
	pacer.decision = d
	pacer_latency(app, &pacer.latency, d.latency == 2)
	if d.wait_ns > 0 && pacer.timer != nil {
		due := win.LARGE_INTEGER(-(d.wait_ns / 100))   // relative, in 100 ns units
		if win.SetWaitableTimerEx(pacer.timer, &due, 0, nil, nil, nil, 0) {
			platform.wait_handle(wnd.win, rawptr(pacer.timer), int(d.wait_ns / 1_000_000) + 50)
		}
	}
	// The latency object is a semaphore released once per frame the screen takes: a wake that ends without a frame
	// (frame's early return) keeps the slot it took, or the next frame would wait for a present that never came, until
	// the timeout (100 ms of input latency after any wake of no consequence).
	if d.wait_swap_chain {   // (the timer's wait above takes messages)
		ok := platform.wait_handle(wnd.win, render.frame_waitable(&app.r), pacer.cfg.timeout_ms)
		if ok { pacer.slot_held = true } else { pacer.missed_timeouts += 1 }
		when PACING_DEBUG { fmt.eprintln("wait", ok, idled, time.duration_milliseconds(time.tick_since(t0)), wnd.frames_requested) }
	}
}

// A frame made inside another one's work or a loop of the system (shell_frames.odin window_frame): only a new size changes
// its state (platform.cadence_inner_frame).
pacer_inner_frame :: proc(app: ^App) {
	wnd := active_window(app)
	resized := wnd.win.size != pacer.size
	pacer.size = wnd.win.size
	platform.cadence_inner_frame(&pacer.cadence, resized, wnd.presented)
}

// After the frame's events are read: its time, its dt, and what the renderer should credit it with.
pacer_begin_frame :: proc(app: ^App, events: []platform.Event) {
	now_ms := loop_ms(app, time.tick_now())
	// the vblank the frame starts at, on the swap chain's grid; a variable refresh screen (or tearing) has no grid of vblanks
	// to land on: the frames' own slots are the clock
	grid_last, grid_period: f64
	has_slot := false
	if !pacer.tearing && !pacer.variable {
		if last, per, ok := render.vblank_grid(&app.r); ok { grid_last, grid_period = loop_ms(app, last), per / 1e6 }
	} else {
		has_slot = pacer.timed && pacer.decision.slot_ns != 0
	}
	platform.frame_clock_advance(&pacer.clock, now_ms, pacer.period_ms, grid_last, grid_period, loop_ms(app, time.Tick{_nsec = pacer.decision.slot_ns}), has_slot)
	latency_probe_polled(len(events))   // shell_latency.odin (profile build)
	// the earliest input of the frame: its latency is measured to the vblank the frame shows at
	first: time.Tick
	for ev in events {
		if ev.stamp._nsec != 0 && (first._nsec == 0 || ev.stamp._nsec < first._nsec) { first = ev.stamp }
	}
	if first._nsec != 0 { render.set_frame_input(&app.r, first) }
	read := time.tick_now()
	pacer.read_tick = read._nsec
	render.set_frame_read(&app.r, read)
	drag_probe_count_moves(events)
	render.set_frame_continuous(&app.r, pacer.continuous)
}

// After the present: frames that reached the screen since the last one go to the status bar's statistics.
pacer_end_frame :: proc(app: ^App) {
	pacer.slot_held = false   // the present used it
	shell_presented()
	now := time.tick_now()._nsec
	platform.cadence_presented(&pacer.cadence, now)
	// the compositor's rate during a run of frames (a dynamic refresh rate goes up while something moves): the highest one seen,
	// read every 100 ms of the run and started afresh after a rest (primary monitor only: platform.display_live_hz)
	if !pacer.continuous { pacer.live_hz = 0 }
	if now - pacer.live_ns >= 100_000_000 {
		if hz, ok := platform.display_live_hz(active_window(app).win); ok { pacer.live_hz = max(pacer.live_hz, hz) }
		pacer.live_ns = now
	}
	drag_probe_presented()
	for d in render.take_displayed(&app.r) { hud_displayed(d); drag_probe_displayed(d) }
}

// A tick of core:time on the event loop clock (ms since the loop started), the clock pages see.
loop_ms :: proc(app: ^App, t: time.Tick) -> f64 { return f64(t._nsec - app.loop.origin._nsec) / 1e6 }
