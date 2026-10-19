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
