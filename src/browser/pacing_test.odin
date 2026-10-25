package browser

import "core:math"
import "core:testing"

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
a_resize_step_is_a_new_window_size_or_a_panel_dragged :: proc(t: ^testing.T) {
	testing.expect(t, resize_step(true, false, true, true), "the window changed size")
	testing.expect(t, resize_step(false, true, true, true), "a panel is being dragged: shown at once as a resize is")
	testing.expect(t, !resize_step(false, false, true, true), "nothing moves the size: paced as any frame")
	testing.expect(t, !resize_step(true, true, false, true), "never before the first frame is on screen")
	testing.expect(t, !resize_step(true, true, true, false), "browser.frame.resize_immediate off: neither")
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
