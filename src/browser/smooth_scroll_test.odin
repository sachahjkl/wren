package browser

import "core:testing"

// The smooth scrolling curve (smooth_scroll.odin): ends exactly on the target, never goes past it nor past the ends
// of the scroller, notches add up without a stop, the speed carries over.

@(private = "file")
CURVES := [?]Scroll_Curve{.Impulse, .Ease_Out}

@(test)
smooth_curve_shape :: proc(t: ^testing.T) {
	for c in CURVES {
		for k in ([?]f64{0.5, 2, 5, 12, 30}) {
			p0, _ := curve_eval(c, k, 0)
			p1, d1 := curve_eval(c, k, 1)
			testing.expectf(t, abs(p0) < 1e-12 && abs(p1 - 1) < 1e-12, "%v k=%v: ends %v %v", c, k, p0, p1)
			testing.expectf(t, d1 >= 0 && d1 < 0.25 * curve_start_slope(c, k) + 1e-9, "%v k=%v: slows down to the end (%v)", c, k, d1)
			prev := 0.0
			for i in 1 ..= 1000 {
				p, d := curve_eval(c, k, f64(i) / 1000)
				testing.expectf(t, p >= prev - 1e-12 && p <= 1 + 1e-12 && d >= -1e-12, "%v k=%v: monotone, within 0..1", c, k)
				prev = p
			}
		}
	}
}

// One scroller at 180 Hz: `notches` wheel notches of `step` px, `gap_ms` apart, within 0..limit, as smooth_scroll_to
// does it. Returns the positions of every frame and the end.
@(private = "file")
simulate :: proc(c: Scroll_Curve, start, step, limit: f64, notches: int, gap_ms, dur: f64, frames: int) -> (positions: [dynamic]f64, to: f64) {
	period := 1000.0 / 180
	a: Axis_Anim
	pos := start
	positions = make([dynamic]f64, context.temp_allocator)
	next_notch := 0.0
	given := 0
	for f in 0 ..< frames {
		now := f64(f) * period
		for given < notches && now >= next_notch {
			// what smooth_scroll_to does: the end moves on from where it was going, clamped to the range
			base := a.active ? a.to : pos
			target := clamp(base + step, 0, limit)
			p, v := pos, 0.0
			s := now
			if a.active {
				sp, sv, done := axis_sample(&a, now)
				if !done { p, v = sp, sv }
			} else { s = now - period }
			if target != base { axis_retarget(&a, p, v, target, s, dur, c, 5) }
			given += 1
			next_notch += gap_ms
		}
		if a.active {
			p, _, done := axis_sample(&a, now)
			pos = clamp(p, 0, limit)
			if done { a.active = false }
		}
		append(&positions, pos)
	}
	return positions, a.to
}

@(test)
smooth_single_notch_lands_exactly :: proc(t: ^testing.T) {
	for c in CURVES {
		positions, _ := simulate(c, 100, 48, 10_000, 1, 0, 180, 120)
		last := positions[len(positions) - 1]
		testing.expectf(t, last == 148, "%v: lands on 148 exactly (%v)", c, last)
		for p in positions { testing.expectf(t, p >= 100 && p <= 148, "%v: no overshoot (%v)", c, p) }
		// it moves on the first frame (no frame of latency) and keeps moving every frame until it lands
		testing.expectf(t, positions[0] > 100, "%v: the first frame moves", c)
		frames_moving := 0
		for i in 1 ..< len(positions) { if positions[i] != positions[i - 1] { frames_moving += 1 } }
		testing.expectf(t, frames_moving >= 25, "%v: drawn over many frames at 180 Hz (%d)", c, frames_moving)
	}
}

@(test)
smooth_notches_add_up_without_stopping :: proc(t: ^testing.T) {
	for c in CURVES {
		// 10 notches 30 ms apart (a fast spin): the end is the sum, the motion never stops nor goes back on the way
		positions, to := simulate(c, 0, 48, 100_000, 10, 30, 180, 400)
		testing.expectf(t, to == 480, "%v: 10 notches add up to 480 (%v)", c, to)
		testing.expectf(t, positions[len(positions) - 1] == 480, "%v: lands on 480", c)
		landed := false
		for i in 1 ..< len(positions) {
			d := positions[i] - positions[i - 1]
			testing.expectf(t, d >= 0, "%v: never back (frame %d: %v)", c, i, d)
			if positions[i] == 480 { landed = true }
			// while notches keep coming it keeps moving
			if f64(i) * 1000 / 180 < 300 { testing.expectf(t, d > 0, "%v: moving at frame %d", c, i) }
		}
		testing.expect(t, landed)
	}
}

@(test)
smooth_stays_within_the_range :: proc(t: ^testing.T) {
	for c in CURVES {
		// toward the end: notches past it pile up on the limit, not beyond
		positions, to := simulate(c, 900, 48, 1000, 8, 20, 180, 300)
		testing.expectf(t, to == 1000, "%v: the end is the limit (%v)", c, to)
		for p in positions { testing.expectf(t, p <= 1000, "%v: never past the end (%v)", c, p) }
		testing.expect(t, positions[len(positions) - 1] == 1000)
		// toward the top
		up, to_up := simulate(c, 60, -48, 1000, 5, 20, 180, 300)
		testing.expectf(t, to_up == 0, "%v: the start is 0 (%v)", c, to_up)
		for p in up { testing.expectf(t, p >= 0, "%v: never before the start", c) }
		testing.expect(t, up[len(up) - 1] == 0)
	}
}

// A notch arriving while the scroller glides fast keeps its speed (no brake), and the curve stays within its ends.
@(test)
smooth_speed_carries_over :: proc(t: ^testing.T) {
	for c in CURVES {
		a: Axis_Anim
		axis_retarget(&a, 0, 0, 1000, 0, 180, c, 5)
		p, v, _ := axis_sample(&a, 20)
		axis_retarget(&a, p, v, 1048, 20, 180, c, 5)
		p2, v2, _ := axis_sample(&a, 20)
		testing.expectf(t, abs(p2 - p) < 1e-9, "%v: continuous position", c)
		testing.expectf(t, v2 >= v * 0.999, "%v: no brake (%v -> %v)", c, v, v2)
		for ms := 20.0; ms <= 400; ms += 1 {
			q, _, _ := axis_sample(&a, ms)
			testing.expectf(t, q <= 1048 + 1e-9, "%v: never past the end", c)
		}
		end, _, done := axis_sample(&a, 1000)
		testing.expect(t, done && end == 1048)
	}
	// reversing: back at once, from where it is, without going past the new end
	a: Axis_Anim
	axis_retarget(&a, 0, 0, 480, 0, 180, .Impulse, 5)
	p, v, _ := axis_sample(&a, 30)
	axis_retarget(&a, p, v, p - 48, 30, 180, .Impulse, 5)
	for ms := 30.0; ms <= 300; ms += 1 {
		q, _, _ := axis_sample(&a, ms)
		testing.expect(t, q <= p + 1e-9 && q >= p - 48 - 1e-9)
	}
}

@(test)
smooth_wheel_precision :: proc(t: ^testing.T) {
	testing.expect(t, !wheel_is_precise({0, 1}))
	testing.expect(t, !wheel_is_precise({0, -3}))
	testing.expect(t, wheel_is_precise({0, 40.0 / 120}))   // a high-resolution wheel's third of a notch
	testing.expect(t, wheel_is_precise({0.2, 0}))          // a touchpad
}
