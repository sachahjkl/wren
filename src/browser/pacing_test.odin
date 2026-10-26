package browser

import "core:math"
import "core:testing"
import "toolkit:platform"

// The frame budget, the plan for a rate on a display, and the frame clock at simulated rates (pacing.odin).

@(test)
pacing_budget_follows_the_rate :: proc(t: ^testing.T) {
	for hz in ([?]f64{60, 120, 144, 180, 240}) {
		period := 1000 / target_rate(hz, 0, 0)
		testing.expectf(t, abs(period - 1000 / hz) < 1e-9, "%v Hz: budget %v", hz, period)
		// simulated on a 180 Hz monitor: the budget is the simulated rate's
		testing.expectf(t, abs(1000 / target_rate(180, hz, 0) - 1000 / hz) < 1e-9, "%v Hz simulated", hz)
	}
	period := f32(1000 / target_rate(180, 0, 0))
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
pacing_target_rate :: proc(t: ^testing.T) {
	testing.expect_value(t, target_rate(180, 0, 0), 180)
	testing.expect_value(t, target_rate(179.98, 0, 0), 179.98)
	testing.expect_value(t, target_rate(180, 60, 0), 60)
	testing.expect_value(t, target_rate(180, 0, 120), 120)          // ceiling
	testing.expect_value(t, target_rate(60, 240, 0), 240)           // above the display: the budget follows, frames cannot
	testing.expect_value(t, target_rate(0, 0, 0), 60)
	testing.expect_value(t, parse_target_hz("auto"), 0)
	testing.expect_value(t, parse_target_hz(" 144 "), 144)
	testing.expect_value(t, parse_target_hz("59.94Hz"), 59.94)
	testing.expect_value(t, parse_target_hz("5"), 10)               // clamped
	testing.expect_value(t, parse_target_hz("-3"), 0)
}

@(test)
a_resize_step_is_a_new_window_size :: proc(t: ^testing.T) {
	testing.expect(t, resize_step(true, true, true), "the window changed size")
	testing.expect(t, !resize_step(false, true, true), "nothing moves the window's size (a panel dragged inside it): paced as any frame")
	testing.expect(t, !resize_step(true, false, true), "never before the first frame is on screen")
	testing.expect(t, !resize_step(true, true, false), "browser.frame.resize_immediate off")
}

// A panel dragged inside the window at a 1 kHz pointer makes one frame per slot, as a tab dragged does: the slot grid is
// what paces a variable refresh screen, and a resize step would skip it (a frame a millisecond).
@(test)
a_panel_dragged_at_1khz_makes_one_frame_per_slot :: proc(t: ^testing.T) {
	ms :: 1_000_000
	slots := platform.Frame_Slots{period_ns = 5_555_555, strict = true}   // 180 Hz, variable refresh
	frames := 0
	// a pointer move every millisecond for 100 ms: each wakes a frame, which waits for its slot, then takes 0.5 ms
	for now := i64(0); now < 100 * ms; {
		immediate := resize_step(false, true, true)   // the window keeps its size
		wait, _ := platform.frame_slot_wait(&slots, now, frames == 0, immediate || frames == 0)
		frames += 1
		now += wait + ms / 2
		now = (now + ms - 1) / ms * ms   // the next move
	}
	testing.expectf(t, frames >= 17 && frames <= 19, "100 ms at 180 Hz: 18 frames, not 100 (%d)", frames)
}

@(test)
only_the_frame_that_starts_an_answer_to_input_is_shown_at_once :: proc(t: ^testing.T) {
	period :: 5.55   // 180 Hz
	ms :: 1_000_000
	testing.expect(t, input_starts_answer(true, 1 * ms, period, 1.5), "the loop idled: a click, a key")
	testing.expect(t, input_starts_answer(false, 20 * ms, period, 1.5), "nothing presented for 3.6 periods")
	testing.expect(t, !input_starts_answer(false, 1 * ms, period, 1.5), "a frame a millisecond ago: a drag goes on, the frame waits for its slot")
	testing.expect(t, !input_starts_answer(false, 8 * ms, period, 1.5), "1.4 periods ago: still one run of frames")
	testing.expect(t, input_starts_answer(false, 1 * ms, period, 0), "0: every frame woken by input, as before")
}

@(test)
a_displayed_frame_gives_its_drag_sample_the_refresh_it_was_shown_at :: proc(t: ^testing.T) {
	saved_cfg, saved_read := pacer.cfg, pacer.read_tick
	defer { drag_probe_reset(); pacer.cfg, pacer.read_tick = saved_cfg, saved_read }
	drag_probe_reset()
	for i in 0 ..< 3 { drag_probe.ring[i] = {} }
	pacer.cfg.drag_probe = true
	for read in ([?]i64{1000, 2000, 3000}) {
		pacer.read_tick = read
		drag_probe_note(10, 12)
	}
	drag_probe_displayed({read = {_nsec = 2000}, shown = {_nsec = 9000}})
	drag_probe_displayed({read = {_nsec = 7777}, shown = {_nsec = 1}})   // a chrome frame of no drag: nothing matches
	testing.expect_value(t, drag_probe.ring[0].shown, 0)
	testing.expect_value(t, drag_probe.ring[1].shown, 9000)
	testing.expect_value(t, drag_probe.ring[2].shown, 0)
	pacer.cfg.drag_probe = false
	drag_probe_note(1, 1)
	testing.expect_value(t, drag_probe.n, 3)   // off: nothing recorded
}

// Frames started in `span_ms` by a loop woken by input every millisecond (a mouse at 1 kHz) on a screen whose swap chain
// releases its latency object at once, each costing `cost_ms`, scheduled by the plan's slots as pacer_wait does. Also the
// shortest distance between two frames after the first two.
@(private = "file")
simulate_frames :: proc(plan: Frame_Plan, span_ms: int, cost_ms: f64) -> (frames: int, shortest_ms: f64) {
	ms :: 1_000_000
	slots := plan.slots
	now := i64(5_000) * ms
	end := now + i64(span_ms) * ms
	last: i64
	shortest_ms = 1e9
	for now < end {
		wait, _ := platform.frame_slot_wait(&slots, now, frames == 0, false)
		now += wait
		if now >= end { break }
		if frames >= 2 { shortest_ms = min(shortest_ms, f64(now - last) / 1e6) }
		last = now
		frames += 1
		now += i64(cost_ms * 1e6)
		now = (now / ms + 1) * ms   // the next move of the mouse
	}
	return
}

@(test)
a_dynamic_refresh_screen_is_planned_at_its_top_rate_and_timed :: proc(t: ^testing.T) {
	d := platform.Display_Info{hz = 60.001, max_hz = 180}   // Windows 11's dynamic refresh rate: rests at 60, reports 60
	p := frame_plan(d, Pacer_Settings{}, false)
	testing.expect(t, p.variable)
	testing.expect_value(t, p.hz, 180)
	testing.expect(t, p.timed, "the browser times the frames")
	testing.expect_value(t, p.interval, 1)
	testing.expect(t, p.slots.strict, "its cap is the period itself")
	testing.expect_value(t, p.slots.period_ns, i64(5_555_555))
	testing.expect(t, abs(p.period_ms - 5.5556) < 1e-3, "the budget follows")

	p = frame_plan(d, Pacer_Settings{variable = .Off}, false)
	testing.expect(t, !p.variable && !p.timed)
	testing.expect_value(t, p.hz, 60.001)

	p = frame_plan(d, Pacer_Settings{target_hz = 120}, false)
	testing.expect_value(t, p.hz, 120)   // an explicit rate wins
	p = frame_plan(d, Pacer_Settings{max_hz = 100}, false)
	testing.expect_value(t, p.hz, 100)   // so does the ceiling
	testing.expect(t, p.timed)

	p = frame_plan({hz = 179.98, max_hz = 180}, Pacer_Settings{}, false)
	testing.expect(t, !p.variable && !p.timed, "a screen at its top rate is a plain one")
	testing.expect(t, !p.slots.strict, "its refresh paces the frames: the cap is only a net")

	p = frame_plan({hz = 179.98, max_hz = 179.98}, Pacer_Settings{variable = .On}, false)
	testing.expect(t, p.variable && p.timed, "variable_refresh = on: a screen that reports its top rate but varies it")
}

@(test)
frames_under_a_1_khz_mouse_stay_within_the_target_rate_on_a_variable_screen :: proc(t: ^testing.T) {
	plan := frame_plan({hz = 60.001, max_hz = 180}, Pacer_Settings{}, false)
	n, shortest := simulate_frames(plan, 1000, 1.3)
	testing.expectf(t, n <= 181 && n >= 170, "%d frames in a second at 180 Hz", n)
	testing.expectf(t, shortest >= 5.5, "no two frames closer than a period (%v ms)", shortest)
	// a frame that costs more than a period is not made up for
	n, _ = simulate_frames(plan, 1000, 7)
	testing.expectf(t, n <= 181 && n >= 100, "%d frames of 7 ms", n)
}

@(test)
frames_under_a_1_khz_mouse_stay_near_the_screens_rate_when_nothing_paces_the_swap_chain :: proc(t: ^testing.T) {
	// variable_refresh = off on a screen that varies: the system says 60, the swap chain does not pace the app
	plan := frame_plan({hz = 60, max_hz = 180}, Pacer_Settings{variable = .Off}, false)
	n, _ := simulate_frames(plan, 1000, 1.3)
	testing.expectf(t, n <= 67, "%d frames in a second at 60 Hz (the loose cap proves itself useless and tightens)", n)
	// and the plan without any cap is what a loop with input did: a frame per move
	plan.slots.period_ns = 0
	n, _ = simulate_frames(plan, 1000, 1.3)
	testing.expectf(t, n > 400, "%d frames without a cap", n)
}

@(test)
variable_refresh_modes :: proc(t: ^testing.T) {
	testing.expect(t, variable_plan(.Auto, 60, 180))
	testing.expect(t, !variable_plan(.Auto, 180, 180))
	testing.expect(t, variable_plan(.On, 180, 180))
	testing.expect(t, !variable_plan(.On, 0, 0), "no rate known")
	testing.expect(t, !variable_plan(.Off, 60, 180))
	testing.expect_value(t, target_rate(60, 0, 0, 180), 180)
	testing.expect_value(t, target_rate(60, 0, 0, 0), 60)
	testing.expect_value(t, target_rate(240, 0, 0, 180), 240)   // a top rate below the display's is no reason to slow down
	i, timed := pacing_plan(60, 180, false, true)
	testing.expect(t, i == 1 && timed)
}

@(test)
frames_just_after_a_size_change_are_part_of_the_burst :: proc(t: ^testing.T) {
	ms :: 1_000_000
	testing.expect(t, resize_burst(100 * ms, 90 * ms, 120), "10 ms after a step")
	testing.expect(t, resize_burst(209 * ms, 90 * ms, 120), "just inside the hold")
	testing.expect(t, !resize_burst(210 * ms, 90 * ms, 120), "the hold is over")
	testing.expect(t, !resize_burst(100 * ms, 0, 120), "no size change seen yet")
	testing.expect(t, !resize_burst(100 * ms, 90 * ms, 0), "browser.frame.resize_hold_ms = 0: only the step itself")
}

@(test)
resize_echoes_are_not_presented :: proc(t: ^testing.T) {
	testing.expect(t, resize_echo(true, false, true, 0, 0, false), "after a step, nothing new: skipped")
	testing.expect(t, !resize_echo(true, true, true, 0, 0, false), "the step itself is made")
	testing.expect(t, !resize_echo(true, false, true, 1, 0, false), "input came: made")
	testing.expect(t, !resize_echo(true, false, true, 0, 2, false), "a task ran: made")
	testing.expect(t, !resize_echo(true, false, true, 0, 0, true), "the page or the interface wants a frame: made")
	testing.expect(t, !resize_echo(false, false, true, 0, 0, false), "outside a resize: frames as asked")
	testing.expect(t, !resize_echo(true, false, false, 0, 0, false), "browser.frame.resize_skip_echoes off")
}

@(test)
pacing_plan_on_a_display :: proc(t: ^testing.T) {
	Case :: struct { display, hz: f64, tearing: bool, interval: int, timed: bool }
	cases := [?]Case{
		{180, 180, false, 1, false},
		{180, 90, false, 2, false},
		{180, 60, false, 3, false},
		{180, 45, false, 4, false},
		{180, 144, false, 1, true},     // no whole divisor: timed, shown at the next vblank
		{180, 120, false, 1, true},
		{180, 240, false, 1, false},    // faster than the display: every refresh
		{143.856, 144, false, 1, false},
		{59.94, 60, false, 1, false},
		{180, 180, true, 1, true},      // tearing: the browser times every frame
	}
	for c in cases {
		i, timed := pacing_plan(c.display, c.hz, c.tearing)
		testing.expectf(t, i == c.interval && timed == c.timed, "%v Hz on %v Hz (tearing %v): interval %d timed %v", c.hz, c.display, c.tearing, i, timed)
	}
}

// Frames that wake up anywhere within a refresh get the time of its vblank: animation frame timestamps and the CSS
// clock advance by whole periods at every simulated rate, whatever the jitter.
@(test)
pacing_frame_clock_on_the_vblank_grid :: proc(t: ^testing.T) {
	for hz in ([?]f64{60, 120, 144, 180, 240}) {
		period := 1000 / hz
		last := 1234.5   // a vblank the swap chain reported
		prev := 0.0
		seed: u32 = 7
		for frame in 0 ..< 500 {
			// woken 0.05 .. 0.9 of a period after the vblank of this frame
			seed = seed * 1664525 + 1013904223
			jitter := 0.05 + 0.85 * f64(seed >> 8) / f64(1 << 24)
			vblank := last + f64(frame + 10) * period
			ts := vblank_at_or_before(vblank + jitter * period, last, period)
			testing.expectf(t, abs(ts - vblank) < 1e-6, "%v Hz frame %d: %v, vblank %v", hz, frame, ts, vblank)
			if frame > 0 { testing.expectf(t, abs((ts - prev) - period) < 1e-6, "%v Hz: step %v", hz, ts - prev) }
			prev = ts
		}
	}
	// every 3rd refresh (60 on 180 Hz): steps of 3 periods
	period := 1000.0 / 180
	prev := vblank_at_or_before(100 + 0.3 * period, 100, period)
	for k in 1 ..< 50 {
		ts := vblank_at_or_before(100 + f64(3 * k) * period + 0.4 * period, 100, period)
		testing.expect(t, abs(ts - prev - 3 * period) < 1e-6)
		prev = ts
	}
	testing.expect_value(t, vblank_at_or_before(42, 0, 0), 42)   // no grid: the time itself
	testing.expect(t, !math.is_nan(vblank_at_or_before(5, 10, period)), "a vblank after now (an old grid) goes back")
}
