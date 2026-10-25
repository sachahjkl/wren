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
	{name = "browser.frame.vblank_clock", kind = .Bool, default = {b = true},
		description = "The time each frame shows (requestAnimationFrame timestamps, CSS animations, smooth scrolling) is the vblank it starts at, so motion advances by whole refresh periods. Off: the time the frame starts computing."},
	{name = "browser.frame.input_immediate", kind = .Bool, default = {b = true},
		description = "A frame woken by input (a click, a wheel notch, a key) is drawn and shown at once, without waiting for the swap chain's slot nor for a refresh: the interface answers within the next composition instead of one or two refreshes later. Off: frames keep their pacing. On a display without variable refresh, the frame may tear."},
	{name = "browser.frame.input_idle_periods", kind = .Float, default = {f = 1.5}, bounded = true, min = 0, max = 100, unit = "refreshes",
		description = "With input_immediate, only the frame that starts an answer to input is shown at once: one made after no frame was presented for this many refresh periods (the interface was at rest). While frames follow one another (a drag, a wheel, a pointer sweeping the window: input every millisecond) each waits for the screen's slot and is shown at the next refresh, one per refresh: the motion advances evenly. 0: every frame woken by input is shown at once (hundreds a second during a drag, which pile up in the swap chain and are shown a refresh each: the picture advances in jumps)."},
	{name = "browser.frame.latency_probe", kind = .Bool, default = {b = false},
		description = "Measures the time from each input event to the refresh that showed it, stage by stage (wait for the frame, build and draw, Present, scan-out): p50 / p95 / max in the `latency` field of `wren ctl stats` (`stats --reset-latency` starts a new measure). The environment variable WREN_LATENCY=1 turns it on for one run. Off: nothing is recorded."},
	{name = "browser.frame.drag_probe", kind = .Bool, default = {b = false},
		description = "Records, for each frame made while a tab is dragged, the pointer it was built from, where the tab was drawn and the refresh that showed it: `dragSamples` in `wren ctl stats` (`stats --reset-frames` starts a new run). Off: nothing is recorded."},
	{name = "browser.frame.video_at_vblank", kind = .Bool, default = {b = true},
		description = "The picture of a playing video is the one that is due when the screen shows the frame (the next refresh), not the one due at the instant the frame was made: on a 60 Hz screen a 60 fps video is then exactly one picture per refresh whatever the jitter of the thread's wake-ups, and a 30 fps one two refreshes each. Off: the picture due now."},
	{name = "browser.frame.resize_immediate", kind = .Bool, default = {b = true},
		description = "While the window is resized, or the splitter or the floating panel of the developer tools is dragged, a frame made at the new size is drawn and shown at once, without waiting for the screen's next refresh nor for the swap chain's slot: the desktop composer would otherwise show the previous frame, drawn for the old size, stretched over the new one until this one reaches the screen. Off: frames keep their pacing during a resize."},
	{name = "browser.frame.resize_hold_ms", kind = .Int, default = {i = 120}, bounded = true, min = 0, max = 2000, unit = "ms",
		description = "After a size change, the frames that follow within this time (the frame that settles the last step, one made for a timer or a message between two steps) are shown at once as the resize step is, with no wait for the screen's refresh in Present. A program that resizes the window itself, such as AltSnap (Alt + right button), calls the window's thread at every step and waits for it: a frame blocked in Present for a refresh made every step wait that long. 0: only the frame that sees the new size."},
	{name = "browser.frame.resize_skip_echoes", kind = .Bool, default = {b = true},
		description = "Within browser.frame.resize_hold_ms of a size change, a frame with nothing new to show (no input, no task run, nothing of the page or of the interface waiting for a frame, the page laid out at its size) is not made: one picture per step of the resize instead of three (the step, then the frames still asked for after it). Off: every frame asked for is drawn and presented."},
}

register_frame_prefs :: proc(p: ^config.Prefs) { config.register(p, FRAME_PREFS[:]) }

Pacer_Settings :: struct {
	target_hz:  f64,                   // 0 = the display's
	max_hz:     f64,                   // 0 = none
	mode:       render.Present_Mode,
	timeout_ms: int,
	vblank_clock: bool,
	resize_immediate: bool,
	resize_hold_ms: int,
	resize_skip_echoes: bool,
	input_immediate: bool,
	video_at_vblank: bool,
	latency_probe: bool,
	drag_probe: bool,
	input_idle_periods: f64,
	variable:   Variable_Refresh,
}

Variable_Refresh :: enum u8 { Auto, On, Off }

pacer_settings_from_prefs :: proc(p: ^config.Prefs) -> Pacer_Settings {
	s := Pacer_Settings{
		max_hz = config.float_of(p, "browser.frame.max_hz"),
		mode = config.string_of(p, "browser.frame.present_mode") == "tearing" ? .Tearing : .Vsync,
		timeout_ms = int(config.int_of(p, "browser.frame.wait_timeout_ms")),
		vblank_clock = config.bool_of(p, "browser.frame.vblank_clock"),
		resize_immediate = config.bool_of(p, "browser.frame.resize_immediate"),
		resize_hold_ms = int(config.int_of(p, "browser.frame.resize_hold_ms")),
		resize_skip_echoes = config.bool_of(p, "browser.frame.resize_skip_echoes"),
		input_immediate = config.bool_of(p, "browser.frame.input_immediate"),
		video_at_vblank = config.bool_of(p, "browser.frame.video_at_vblank"),
		drag_probe = config.bool_of(p, "browser.frame.drag_probe"),
		input_idle_periods = config.float_of(p, "browser.frame.input_idle_periods"),
		latency_probe = config.bool_of(p, "browser.frame.latency_probe") || os.get_env("WREN_LATENCY", context.temp_allocator) == "1",
	}
	s.target_hz = parse_target_hz(config.string_of(p, "browser.frame.target_hz"))
	switch config.string_of(p, "browser.frame.variable_refresh") {
	case "on":  s.variable = .On
	case "off": s.variable = .Off
	}
	return s
}

// Whether the screen is taken for one that shows frames above the rate it reports (browser.frame.variable_refresh).
variable_plan :: proc(mode: Variable_Refresh, hz, max_hz: f64) -> bool {
	switch mode {
	case .On:   return hz > 0
	case .Off:  return false
	case .Auto: return platform.refresh_is_variable(hz, max_hz)
	}
	return false
}

// "auto" (or anything that is no rate) = 0; a number of hertz, clamped to 10 .. 1000.
parse_target_hz :: proc(s: string) -> f64 {
	v := strings.trim_space(s)
	v = strings.trim_suffix(strings.trim_suffix(v, "Hz"), "hz")
	f, ok := strconv.parse_f64(strings.trim_space(v))
	if !ok || math.is_nan(f) || f <= 0 { return 0 }
	return clamp(f, 10, 1000)
}

// The rate frames aim for: the target (0: the display's, or its top rate when it is variable: `top_hz`), under the ceiling
// (0: none).
target_rate :: proc(display_hz, target_hz, max_hz: f64, top_hz: f64 = 0) -> f64 {
	hz := target_hz > 0 ? target_hz : (top_hz > display_hz ? top_hz : display_hz)
	if hz <= 0 { hz = 60 }
	if max_hz > 0 { hz = min(hz, max_hz) }
	return hz
}

// How a rate is reached on a display: vsync refreshes per frame, and whether the browser times the frames itself
// (`timed`). A rate within 1 % of display / n (n = 1..4) is every n-th refresh; any other one is timed, and so is
// everything in tearing mode and on a variable refresh screen (its rate now says nothing about the rate frames are shown at).
// A rate above the display's cannot be shown with vsync: every refresh.
pacing_plan :: proc(display_hz, hz: f64, tearing: bool, variable := false) -> (interval: int, timed: bool) {
	if tearing || variable { return 1, true }
	if display_hz <= 0 || hz >= display_hz * 0.99 { return 1, false }
	for n in 1 ..= 4 {
		if abs(display_hz / f64(n) - hz) <= hz * 0.01 { return n, false }
	}
	return 1, true
}

// The vblank a frame starting at `now` belongs to: the latest one of the grid (`last` + k periods) not after `now`.
// Without a grid (period 0), `now`.
vblank_at_or_before :: proc(now, last, period: f64) -> f64 {
	if period <= 0 { return now }
	k := math.floor((now - last) / period)
	return last + k * period
}

Pacer :: struct {
	cfg:        Pacer_Settings,
	watch:      int,
	display:    platform.Display_Info,
	hz:         f64,          // the rate aimed for
	period_ms:  f64,          // 1000 / hz: the frame budget
	interval:   int,          // vsync refreshes per frame
	timed:      bool,         // frames are timed by the browser (pacing_plan)
	tearing:    bool,         // presenting with tearing (asked for and supported)
	timer:      win.HANDLE,   // the timing of timed frames (high resolution waitable timer)
	variable:   bool,         // the screen shows frames above the rate it reports (variable_plan): the target is its top rate
	slots:      platform.Frame_Slots,   // the cap on the cadence: no frame starts before its slot (toolkit platform/frame_slots.odin)
	slot_ns:    i64,          // the slot this frame was timed for (0: none)
	live_hz:    f64,          // the compositor's measured refresh rate during the last run of frames (display_live_hz; 0: none yet)
	live_ns:    i64,          // tick of the last such measure
	frame_ms:   f64,          // this frame's time, on the event loop clock (ms)
	prev_ms:    f64,
	dt:         f32,          // seconds since the previous frame's time (UI animations)
	continuous: bool,         // this frame follows the previous one without idling
	waited_ms:  f64,          // time spent waiting for the screen (or the timer) at the start of this frame
	missed_timeouts: int,     // waits that ran into wait_timeout_ms
	slot_held:  bool,         // the latency object was waited for and no frame was presented since (pacer_wait)
	size:       [2]int,       // the window's size at the last frame (another one: the window is being resized)
	resizing:   bool,         // this frame follows a size change: drawn and shown at once (pacer_wait)
	resize_ns:  i64,          // tick of the last size change seen (0: none yet)
	resize_held: bool,        // this frame comes within browser.frame.resize_hold_ms of one: shown at once, paced as any frame (resize_burst)
	echoes_skipped: int,      // frames of a resize burst not made (resize_echo_frame)
	resize_causes: [Resize_Frame_Cause]int,                  // why the frames of a resize burst were made
	resize_event_kinds: [platform.Event_Kind]int,            // the events of those made for events
	input_frame: bool,        // this frame was woken by input: shown at once (browser.frame.input_immediate)
	latency:    int,          // frames the swap chain may queue (1, or 2 during a resize or an input frame)
	read_tick:  i64,          // tick this frame had read its input (the key of its Displayed_Frame)
	present_ns: i64,          // tick of the last present (pacer_end_frame)
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
		app.frames_requested = max(app.frames_requested, 2)
	}, app)
	pacer_update(app)
}

pacer_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, pacer.watch)
	if pacer.timer != nil { win.CloseHandle(pacer.timer) }
	pacer = {}
}

// The monitor's rate and the preferences, turned into a plan: once per frame (cheap unless something changed).
pacer_update :: proc(app: ^App) {
	// the page's idle periods leave room for a frame of this length (timers.frame_budget_ms = 0); apply_prefs makes the
	// settings again from the preferences
	defer app.page_settings.web.frame_period_ms = pacer.period_ms
	d := platform.display_info(app.win)
	if d.serial == pacer.display.serial && pacer.hz > 0 { return }
	pacer.display = d
	pacer.tearing = pacer.cfg.mode == .Tearing && render.tearing_supported(&app.r)
	plan := frame_plan(d, pacer.cfg, pacer.tearing)
	pacer.variable, pacer.hz, pacer.period_ms, pacer.interval, pacer.timed, pacer.slots = plan.variable, plan.hz, plan.period_ms, plan.interval, plan.timed, plan.slots
	render.set_present_mode(&app.r, pacer.tearing ? .Tearing : .Vsync)
	render.set_sync_interval(&app.r, pacer.interval)
	// missed refreshes of timed frames (a variable screen has no fixed refresh to miss)
	render.set_expected_refreshes(&app.r, pacer.timed && !pacer.tearing && !pacer.variable && pacer.hz > 0 ? d.hz / pacer.hz : 0)
	pacer.slot_ns = 0
}

// What the monitor and the preferences make of the frames' cadence.
Frame_Plan :: struct {
	variable:  bool,
	hz:        f64,
	period_ms: f64,
	interval:  int,
	timed:     bool,
	slots:     platform.Frame_Slots,
}

frame_plan :: proc(d: platform.Display_Info, cfg: Pacer_Settings, tearing: bool) -> (p: Frame_Plan) {
	p.variable = variable_plan(cfg.variable, d.hz, d.max_hz)
	p.hz = target_rate(d.hz, cfg.target_hz, cfg.max_hz, p.variable ? d.max_hz : 0)
	p.period_ms = 1000 / p.hz
	p.interval, p.timed = pacing_plan(d.hz, p.hz, tearing, p.variable)
	// The cap: the period itself where the browser is what paces the frames (timed: a rate the screen does not divide, tearing,
	// a variable screen); a loose safety net where the screen's refresh does (platform.Frame_Slots)
	p.slots = {period_ns = i64(p.period_ms * 1e6), strict = p.timed}
	return
}

// Whether a frame is a resize step (drawn and shown at once): the window changed size, or a panel is being dragged to a new
// size under the pointer; never before the first frame is on screen, and not when the preference is off.
resize_step :: proc(window_resized, panel_dragged, presented, enabled: bool) -> bool {
	return (window_resized || panel_dragged) && presented && enabled
}

// Whether `now_ns` is within `hold_ms` after the last size change (`last_ns`, 0: none): the frames of a resize that are
// not made for a new size (the one that settles the last step, a wake between two steps of a program that resizes the
// window from outside) are shown like its steps, or the one blocked in Present for a refresh stalls the next step.
resize_burst :: proc(now_ns, last_ns: i64, hold_ms: int) -> bool {
	return hold_ms > 0 && last_ns != 0 && now_ns - last_ns < i64(hold_ms) * 1_000_000
}

// Whether a frame woken by input starts an answer to it (shown at once) rather than continues one (waits for the slot like any
// frame): the loop idled before it, or nothing was presented for `periods` refresh periods (0: every frame does).
input_starts_answer :: proc(idled: bool, since_present_ns: i64, period_ms, periods: f64) -> bool {
	return idled || periods <= 0 || f64(since_present_ns) > period_ms * periods * 1e6
}

// A frame of the burst after a resize step that would only show the step's picture again: nothing came (events, tasks),
// nothing waits for a frame (the page, the interface, a scroll animation) and the page is laid out at its area's size.
// Pure: frame() skips it (resize_echo_frame) instead of presenting a copy at once.
resize_echo :: proc(held, resizing, enabled: bool, events, ran: int, wants: bool) -> bool {
	return enabled && held && !resizing && events == 0 && ran == 0 && !wants
}

Resize_Frame_Cause :: enum u8 { Step, Events, Tasks, Page, Ui_Animation, Ui_Timer, Scrolling, Layout_Size }

// frame() (main.odin): whether this frame is such an echo; it is then not made (frames asked for are forgotten).
resize_echo_frame :: proc(app: ^App, events: []platform.Event, ran: int, page_wants: bool) -> bool {
	// (a repaint the system asks for after a step is not a reason: the step's frame was drawn at the new size and the swap
	// chain keeps it on screen)
	cause := Resize_Frame_Cause.Page
	switch {
	case ui.needs_frame(app.ui_state): cause = .Ui_Animation
	case ui.wake_due(app.ui_state): cause = .Ui_Timer
	}
	wants := page_wants || cause != .Page
	// a step is a frame at a size not drawn yet (the window's size against the renderer's: pacer_wait only sees a size
	// that came before its wait, and calls the frame after the one that drew it a step too)
	step := app.win.size != app.r.size
	if t := current_tab(app); t != nil && t.page != nil {
		if len(t.smooth.anims) > 0 { wants = true; cause = .Scrolling }
		if page_prep.tab == t && page_prep.size != draw.rect_size(app.page_rect) { wants = true; cause = .Layout_Size }   // laid out at another size: the next frame settles it
	}
	held := pacer.resize_held || pacer.resizing
	if !resize_echo(held, step, pacer.cfg.resize_skip_echoes, len(events), ran, wants) {
		// why a frame of a resize was made (wren ctl stats: resizeFrameCauses)
		if held && pacer.cfg.resize_skip_echoes {
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
	app.frames_requested = 0
	platform.take_paint_request(app.win)
	pacer.echoes_skipped += 1
	return true
}

// Present and the swap chain's latency for a frame: the resize step, a frame of the burst after it, an input frame.
pacer_at_once :: proc() -> bool { return pacer.resizing || pacer.resize_held || pacer.input_frame }

// The frame budget in ms: what one frame may take at the target rate.
frame_budget_ms :: proc() -> f32 { return pacer.period_ms > 0 ? f32(pacer.period_ms) : 1000.0 / 60 }

// The most frames the swap chain in use may queue: two for a step of a resize or an input frame (see pacer_wait), else one.
// `latency` is the window's own memory of it (the swap chain in use is the renderer's current one: the main window's, or
// a surface made current by devtools_window.odin).
pacer_latency :: proc(app: ^App, latency: ^int, two: bool) {
	want := two ? 2 : 1
	if want != latency^ {
		render.set_max_frame_latency(&app.r, want)
		latency^ = want
	}
}

// At the start of a frame: wait for its time (a timed rate), then for the swap chain to take a frame, taking input
// meanwhile. `idled`: the loop slept before this frame (nothing moved): it starts a new run of frames.
pacer_wait :: proc(app: ^App, idled: bool) {
	t0 := time.tick_now()
	defer pacer.waited_ms = time.duration_milliseconds(time.tick_since(t0))
	pacer.continuous = !idled
	// The window changed size since the last frame: this frame is a resize step. It is drawn and shown at once, without
	// the timer nor the wait for the swap chain's slot (below): the desktop composer would otherwise show the previous
	// frame, drawn for the old size, stretched over the new one until this frame reaches the screen
	// (browser.frame.resize_immediate).
	resized := app.win.size != pacer.size
	pacer.size = app.win.size
	// (so is a drag of the developer tools' splitter or of their floating panel: the window keeps its size and the panel and the
	// page are resized under the hand, which has to follow it at the same rate as the window's edge does)
	dragged := devtools_dragging()
	pacer.resizing = resize_step(resized, dragged, app.presented, pacer.cfg.resize_immediate)
	tick := time.tick_now()._nsec
	pacer.resize_held = !pacer.resizing && app.presented && pacer.cfg.resize_immediate && resize_burst(tick, pacer.resize_ns, pacer.cfg.resize_hold_ms)
	if resized || dragged { pacer.resize_ns = tick }
	input := shell_user_input_pending()
	// Only the frame that starts an answer to input is shown at once: while frames follow one another (a drag, the wheel,
	// a pointer sweeping the page: input every millisecond) every frame waits for the screen's slot, one per refresh.
	// Shown at once, each of the hundreds of frames a second was presented over the one before and the swap chain's
	// three buffers filled with frames a millisecond apart that the screen then showed one per refresh: the picture
	// advanced a millisecond for three refreshes, then jumped (see tools\drag_fluidity.ps1).
	pacer.input_frame = input && app.presented && pacer.cfg.input_immediate && input_starts_answer(idled, tick - pacer.present_ns, pacer.period_ms, pacer.cfg.input_idle_periods)
	// During a resize step or an input frame, two frames may queue: a present is not made to wait behind the previous
	// one when frames come faster than the screen (the answer shows sooner). 1 the rest of the time.
	pacer_latency(app, &pacer.latency, pacer_at_once())
	// The slot of this frame (platform.Frame_Slots): no frame starts before it, input or not. Only the frame that starts an
	// answer to input (a click after a rest) and a step of a resize are made at once: the pointer's hover state follows the hand,
	// not a refresh later. The frames of a drag (input every millisecond) wait for their slot, taking the input that comes
	// meanwhile: one frame per period shows all of it, whatever the screen does with the swap chain's latency object (a variable
	// refresh display releases it at once: nothing else paced the browser, and a mouse at 1 kHz made 1000 frames a second).
	wait, slot := platform.frame_slot_wait(&pacer.slots, tick, idled, pacer.resizing || pacer.input_frame)
	pacer.slot_ns = slot
	if pacer.resizing { return }
	if wait > 0 && pacer.timer != nil {
		due := win.LARGE_INTEGER(-(wait / 100))   // relative, in 100 ns units
		if win.SetWaitableTimerEx(pacer.timer, &due, 0, nil, nil, nil, 0) {
			platform.wait_handle(app.win, rawptr(pacer.timer), int(wait / 1_000_000) + 50)
		}
	}
	// nothing is queued before the first present: the latency object of a swap chain not yet shown is not signaled,
	// waiting would only run into the timeout
	// The latency object is a semaphore released once per frame the screen takes: a wake that ends without a frame
	// (frame's early return) keeps the slot it took, or the next frame would wait for a present that never came, until
	// the timeout (100 ms of input latency after any wake of no consequence).
	if app.presented && !pacer.slot_held && !pacer.input_frame {
		ok := platform.wait_handle(app.win, render.frame_waitable(&app.r), pacer.cfg.timeout_ms)
		if ok { pacer.slot_held = true } else { pacer.missed_timeouts += 1 }
		when PACING_DEBUG { fmt.eprintln("wait", ok, idled, time.duration_milliseconds(time.tick_since(t0)), app.frames_requested) }
	}
}

// After the frame's events are read: its time, its dt, and what the renderer should credit it with.
pacer_begin_frame :: proc(app: ^App, events: []platform.Event) {
	now_ms := loop_ms(app, time.tick_now())
	t := now_ms
	// (a variable refresh screen has no grid of vblanks to land on: the frames' own slots are the clock)
	if pacer.cfg.vblank_clock && !pacer.tearing && !pacer.variable {
		if last, per, ok := render.vblank_grid(&app.r); ok { t = vblank_at_or_before(now_ms, loop_ms(app, last), per / 1e6) }
	} else if pacer.timed && pacer.slot_ns != 0 {
		t = min(loop_ms(app, time.Tick{_nsec = pacer.slot_ns}), now_ms)   // the slot this frame was timed for
	}
	if t <= pacer.prev_ms { t = min(now_ms, pacer.prev_ms + pacer.period_ms) }   // never backwards
	if t <= pacer.prev_ms { t = pacer.prev_ms }
	pacer.dt = pacer.prev_ms > 0 ? f32((t - pacer.prev_ms) / 1000) : f32(pacer.period_ms / 1000)
	if pacer.dt <= 0 { pacer.dt = f32(pacer.period_ms / 1000) }
	pacer.dt = clamp(pacer.dt, 0.0005, 0.1)
	pacer.prev_ms, pacer.frame_ms = t, t
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
	pacer.present_ns = time.tick_now()._nsec
	// the compositor's real rate during a run of frames (a dynamic refresh rate goes up while something moves): measured every
	// half second of it, started afresh after a rest
	if !pacer.continuous {
		platform.display_live_reset(app.win)
		_, _ = platform.display_live_hz(app.win)   // the baseline of this run
		pacer.live_ns = pacer.present_ns
	} else if pacer.present_ns - pacer.live_ns >= 500_000_000 {
		if hz, ok := platform.display_live_hz(app.win); ok { pacer.live_hz = hz }
		pacer.live_ns = pacer.present_ns
	}
	drag_probe_presented()
	for d in render.take_displayed(&app.r) { hud_displayed(d); drag_probe_displayed(d) }
}

// A tick of core:time on the event loop clock (ms since the loop started), the clock pages see.
loop_ms :: proc(app: ^App, t: time.Tick) -> f64 { return f64(t._nsec - app.loop.origin._nsec) / 1e6 }
