package browser

import "core:math/rand"
import "core:testing"
import "toolkit:platform"
import "wb:config"

// The browser's side of the cadence model (pacing.odin): the budget, the preferences and their retirement, and the
// decisions of the toolkit's model (platform/pacing.odin, tested there with simulated screens) against those the browser
// made before it, preference by preference at their defaults.

@(test)
pacing_budget_follows_the_rate :: proc(t: ^testing.T) {
	for hz in ([?]f64{60, 120, 144, 180, 240}) {
		period := 1000 / platform.cadence_target_rate(hz, 0, 0)
		testing.expectf(t, abs(period - 1000 / hz) < 1e-9, "%v Hz: budget %v", hz, period)
		// simulated on a 180 Hz monitor: the budget is the simulated rate's
		testing.expectf(t, abs(1000 / platform.cadence_target_rate(180, hz, 0) - 1000 / hz) < 1e-9, "%v Hz simulated", hz)
	}
	period := f32(1000 / platform.cadence_target_rate(180, 0, 0))
	testing.expect(t, abs(period - 5.5556) < 1e-3, "180 Hz: 5.56 ms")
	// the status bar's budget: its own preference, else the frame period; thresholds in budgets
	s := Hud_Settings{warn_budgets = 1, bad_budgets = 2}
	b, w, bad := hud_thresholds(s, period)
	testing.expect(t, abs(b - 5.5556) < 1e-3 && abs(w - 5.5556) < 1e-3 && abs(bad - 11.111) < 1e-3, "thresholds in budgets")
	s.budget, s.bad = 10, 25
	b, w, bad = hud_thresholds(s, period)
	testing.expect(t, b == 10 && w == 10 && bad == 25, "explicit values win")
}

@(test)
pacing_target_rate_preference :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_target_hz("auto"), 0)
	testing.expect_value(t, parse_target_hz(" 144 "), 144)
	testing.expect_value(t, parse_target_hz("59.94Hz"), 59.94)
	testing.expect_value(t, parse_target_hz("5"), 10)               // clamped
	testing.expect_value(t, parse_target_hz("-3"), 0)
}

// The preferences the model replaced are read without error (a profile that set them keeps working) and change nothing; the
// ones that are real choices reach the model.
@(test)
retired_frame_preferences_are_ignored :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_frame_prefs(&p)
	before := pacer_settings_from_prefs(&p)
	for name in RETIRED_FRAME_PREFS {
		for d in FRAME_PREFS { testing.expectf(t, d.name != name, "%s is retired and registered", name) }
		testing.expect_value(t, config.set_from_string(&p, name, "0", .User), config.Set_Error.Unknown)   // kept, applied to nothing
	}
	testing.expect(t, pacer_settings_from_prefs(&p) == before, "nothing changes")
	testing.expect_value(t, config.set_from_string(&p, "browser.frame.variable_refresh", "off", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.frame.target_hz", "120", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.frame.max_hz", "100", .User), config.Set_Error.None)
	c := pacer_choices(pacer_settings_from_prefs(&p), true)
	testing.expect(t, c.variable == .Off && c.target_hz == 120 && c.max_hz == 100 && c.tearing)
	plan := platform.cadence_plan({hz = 60.001, max_hz = 180}, pacer_choices(before, false))
	testing.expect(t, plan.variable && plan.hz == 180 && plan.timed, "the defaults: a dynamic refresh screen at its top rate")
}

// What pacer_wait decided before the cadence model, with the retired preferences at their defaults (resize_immediate on,
// resize_hold_ms 120, input_immediate on, input_idle_periods 1.5): the reference the model must match.
@(private = "file")
Legacy :: struct { resize_ns, present_ns: i64, slots: platform.Frame_Slots }

@(private = "file")
legacy_decide :: proc(l: ^Legacy, in_: platform.Cadence_Inputs) -> (at_once, wait_swap_chain: bool, latency: int, wait: i64) {
	resizing := in_.resized && in_.presented
	held := !resizing && in_.presented && l.resize_ns != 0 && in_.now_ns - l.resize_ns < 120 * 1_000_000
	if in_.resized { l.resize_ns = in_.now_ns }
	// (the model measures the rest in whole nanoseconds of its slots' period: the browser's float period differs by less than
	// a nanosecond, which only a wake on that nanosecond could tell)
	input_frame := in_.input && in_.presented && (in_.idled || f64(in_.now_ns - l.present_ns) > f64(l.slots.period_ns) * 1.5)
	at_once = resizing || held || input_frame
	latency = at_once ? 2 : 1
	wait, _ = platform.frame_slot_wait(&l.slots, in_.now_ns, in_.idled, resizing || input_frame)
	if resizing { return at_once, false, latency, 0 }
	wait_swap_chain = in_.presented && !in_.slot_held && !input_frame
	return
}

@(test)
the_cadence_model_decides_as_the_browser_did :: proc(t: ^testing.T) {
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	for plan in ([?]platform.Cadence_Plan{platform.cadence_plan({hz = 60.001, max_hz = 180}, {}), platform.cadence_plan({hz = 60, max_hz = 60}, {}), platform.cadence_plan({hz = 180, max_hz = 180}, {tearing = true})}) {
		c := platform.Cadence{slots = plan.slots}
		l := Legacy{slots = plan.slots}
		now := i64(1_000_000_000)
		presented := false
		seen: [platform.Cadence_State]bool
		for i in 0 ..< 20_000 {
			// a wake 0.1 to 30 ms after the last one, with any mix of what can happen
			now += i64(rand.int_max(30_000)) * 1000 + 100_000
			in_ := platform.Cadence_Inputs{
				now_ns = now, idled = rand.int_max(6) == 0, input = rand.int_max(2) == 0, presented = presented,
				resized = rand.int_max(8) == 0, dragging = rand.int_max(3) == 0, slot_held = rand.int_max(4) == 0,
			}
			at_once, swap, latency, wait := legacy_decide(&l, in_)
			d := platform.frame_decision(&c, in_)
			seen[d.state] = true
			if d.present_at_once != at_once || d.wait_swap_chain != swap || d.latency != latency || d.wait_ns != wait {
				testing.expectf(t, false, "frame %d %v: model %v, browser at_once %v swap %v latency %d wait %d", i, in_, d, at_once, swap, latency, wait)
				return
			}
			testing.expect_value(t, platform.cadence_at_once(&c), at_once)
			// most frames are presented (a few wakes make none)
			if rand.int_max(10) != 0 {
				now += i64(rand.int_max(3_000)) * 1000
				presented = true
				platform.cadence_presented(&c, now)
				l.present_ns = now
			}
		}
		for s in platform.Cadence_State { testing.expectf(t, seen[s], "%v never decided", s) }
	}
}

@(test)
a_displayed_frame_gives_its_drag_sample_the_refresh_it_was_shown_at :: proc(t: ^testing.T) {
	app := new(App)   // (no window: the pacing is the bare window's)
	defer free(app)
	defer drag_probe_reset()
	drag_probe_reset()
	for i in 0 ..< 3 { drag_probe.ring[i] = {} }
	app.pacing.cfg.drag_probe = true
	for read in ([?]i64{1000, 2000, 3000}) {
		pacer_of(app).read_tick = read
		drag_probe_note(app, 10, 12)
	}
	drag_probe_displayed(app, {read = {_nsec = 2000}, shown = {_nsec = 9000}})
	drag_probe_displayed(app, {read = {_nsec = 7777}, shown = {_nsec = 1}})   // a chrome frame of no drag: nothing matches
	testing.expect_value(t, drag_probe.ring[0].shown, 0)
	testing.expect_value(t, drag_probe.ring[1].shown, 9000)
	testing.expect_value(t, drag_probe.ring[2].shown, 0)
	app.pacing.cfg.drag_probe = false
	drag_probe_note(app, 1, 1)
	testing.expect_value(t, drag_probe.n, 3)   // off: nothing recorded
}
