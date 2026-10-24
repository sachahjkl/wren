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
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "toolkit:platform"
import "toolkit:render"
import "wb:config"

// PACING_DEBUG: every wait for the screen and every smooth scrolling step on stderr (build with -subsystem:console).
PACING_DEBUG :: #config(PACING_DEBUG, false)
_ :: fmt   // PACING_DEBUG only

FRAME_PREFS := [?]config.Def{
	{name = "browser.frame.target_hz", kind = .String, default = {s = "auto"},
		description = "Frames per second while something moves (nothing moves: no frames). auto = the refresh rate of the monitor the window is on (followed when the window moves to another monitor or the display mode changes). A number of hertz (10 to 1000) paces frames at that rate instead, e.g. to see how pages behave at 60 or 120 Hz on a faster monitor: a whole divisor of the monitor's rate shows every n-th refresh, another rate is timed by the browser. The frame budget (status bar, profiler) follows it."},
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
	{name = "browser.frame.video_at_vblank", kind = .Bool, default = {b = true},
		description = "The picture of a playing video is the one that is due when the screen shows the frame (the next refresh), not the one due at the instant the frame was made: on a 60 Hz screen a 60 fps video is then exactly one picture per refresh whatever the jitter of the thread's wake-ups, and a 30 fps one two refreshes each. Off: the picture due now."},
	{name = "browser.frame.resize_immediate", kind = .Bool, default = {b = true},
		description = "While the window is resized, a frame made at the new size is drawn and shown at once, without waiting for the screen's next refresh nor for the swap chain's slot: the desktop composer would otherwise show the previous frame, drawn for the old size, stretched over the new one until this one reaches the screen. Off: frames keep their pacing during a resize."},
}

register_frame_prefs :: proc(p: ^config.Prefs) { config.register(p, FRAME_PREFS[:]) }

Pacer_Settings :: struct {
	target_hz:  f64,                   // 0 = the display's
	max_hz:     f64,                   // 0 = none
	mode:       render.Present_Mode,
	timeout_ms: int,
	vblank_clock: bool,
	resize_immediate: bool,
	input_immediate: bool,
	video_at_vblank: bool,
}

pacer_settings_from_prefs :: proc(p: ^config.Prefs) -> Pacer_Settings {
	s := Pacer_Settings{
		max_hz = config.float_of(p, "browser.frame.max_hz"),
		mode = config.string_of(p, "browser.frame.present_mode") == "tearing" ? .Tearing : .Vsync,
		timeout_ms = int(config.int_of(p, "browser.frame.wait_timeout_ms")),
		vblank_clock = config.bool_of(p, "browser.frame.vblank_clock"),
		resize_immediate = config.bool_of(p, "browser.frame.resize_immediate"),
		input_immediate = config.bool_of(p, "browser.frame.input_immediate"),
		video_at_vblank = config.bool_of(p, "browser.frame.video_at_vblank"),
	}
	s.target_hz = parse_target_hz(config.string_of(p, "browser.frame.target_hz"))
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

// The rate frames aim for: the target (0: the display's), under the ceiling (0: none).
target_rate :: proc(display_hz, target_hz, max_hz: f64) -> f64 {
	hz := target_hz > 0 ? target_hz : display_hz
	if hz <= 0 { hz = 60 }
	if max_hz > 0 { hz = min(hz, max_hz) }
	return hz
}

// How a rate is reached on a display: vsync refreshes per frame, and whether the browser times the frames itself
// (`timed`). A rate within 1 % of display / n (n = 1..4) is every n-th refresh; any other one is timed, and so is
// everything in tearing mode. A rate above the display's cannot be shown with vsync: every refresh.
pacing_plan :: proc(display_hz, hz: f64, tearing: bool) -> (interval: int, timed: bool) {
	if tearing { return 1, true }
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
	next_ns:    i64,          // tick of the next timed frame
	frame_ms:   f64,          // this frame's time, on the event loop clock (ms)
	prev_ms:    f64,
	dt:         f32,          // seconds since the previous frame's time (UI animations)
	continuous: bool,         // this frame follows the previous one without idling
	waited_ms:  f64,          // time spent waiting for the screen (or the timer) at the start of this frame
	missed_timeouts: int,     // waits that ran into wait_timeout_ms
	slot_held:  bool,         // the latency object was waited for and no frame was presented since (pacer_wait)
	size:       [2]int,       // the window's size at the last frame (another one: the window is being resized)
	resizing:   bool,         // this frame follows a size change: drawn and shown at once (pacer_wait)
	input_frame: bool,        // this frame was woken by input: shown at once (browser.frame.input_immediate)
	latency:    int,          // frames the swap chain may queue (1, or 2 during a resize or an input frame)
}

pacer: Pacer

pacer_init :: proc(app: ^App) {
	pacer.cfg = pacer_settings_from_prefs(&app.prefs)
	CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
	pacer.timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if pacer.timer == nil { pacer.timer = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS) }   // before Windows 10 1803
	pacer.watch = config.watch(&app.prefs, "browser.frame.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		pacer.cfg = pacer_settings_from_prefs(p)
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
	pacer.hz = target_rate(d.hz, pacer.cfg.target_hz, pacer.cfg.max_hz)
	pacer.period_ms = 1000 / pacer.hz
	pacer.interval, pacer.timed = pacing_plan(d.hz, pacer.hz, pacer.tearing)
	render.set_present_mode(&app.r, pacer.tearing ? .Tearing : .Vsync)
	render.set_sync_interval(&app.r, pacer.interval)
	render.set_expected_refreshes(&app.r, pacer.timed && !pacer.tearing && pacer.hz > 0 ? d.hz / pacer.hz : 0)   // missed refreshes of timed frames
	pacer.next_ns = 0
}

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
	pacer.resizing = resized && app.presented && pacer.cfg.resize_immediate
	input := shell_user_input_pending()
	pacer.input_frame = input && app.presented && pacer.cfg.input_immediate
	// During a resize step or an input frame, two frames may queue: a present is not made to wait behind the previous
	// one when frames come faster than the screen (the answer shows sooner). 1 the rest of the time.
	pacer_latency(app, &pacer.latency, pacer.resizing || pacer.input_frame)
	if pacer.resizing { return }
	// input waiting in the queue: the frame is made for it now, not at the next slot of the target rate (the pointer's
	// hover state follows the hand, not a refresh later)
	if pacer.timed && pacer.timer != nil && !input {
		now := time.tick_now()._nsec
		period := i64(pacer.period_ms * 1e6)
		// a run starts now; a frame later than a whole period does not try to catch up
		if idled || pacer.next_ns == 0 || now - pacer.next_ns > period { pacer.next_ns = now }
		if wait := pacer.next_ns - now; wait > 200_000 {
			due := win.LARGE_INTEGER(-(wait / 100))   // relative, in 100 ns units
			if win.SetWaitableTimerEx(pacer.timer, &due, 0, nil, nil, nil, 0) {
				platform.wait_handle(app.win, rawptr(pacer.timer), int(wait / 1_000_000) + 50)
			}
		}
		pacer.next_ns += period
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
	if pacer.cfg.vblank_clock && !pacer.tearing {
		if last, per, ok := render.vblank_grid(&app.r); ok { t = vblank_at_or_before(now_ms, loop_ms(app, last), per / 1e6) }
	} else if pacer.timed && pacer.next_ns != 0 {
		t = min(loop_ms(app, time.Tick{_nsec = pacer.next_ns - i64(pacer.period_ms * 1e6)}), now_ms)   // the slot this frame was timed for
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
	render.set_frame_continuous(&app.r, pacer.continuous)
}

// After the present: frames that reached the screen since the last one go to the status bar's statistics.
pacer_end_frame :: proc(app: ^App) {
	pacer.slot_held = false   // the present used it
	shell_presented()
	for d in render.take_displayed(&app.r) { hud_displayed(d) }
}

// A tick of core:time on the event loop clock (ms since the loop started), the clock pages see.
loop_ms :: proc(app: ^App, t: time.Tick) -> f64 { return f64(t._nsec - app.loop.origin._nsec) / 1e6 }
