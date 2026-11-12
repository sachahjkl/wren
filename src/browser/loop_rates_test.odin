package browser

import "core:testing"

// A frame among many wakes that drew nothing (a loop woken every few milliseconds) is still in what a client reads: a
// frame at rest can be told apart, with who asked for it.
@(test)
a_frame_among_wakes_is_kept :: proc(t: ^testing.T) {
	r: Loop_Rates
	for i in 0 ..< 3 * LOOP_REASONS_KEPT { loop_rates_barren(&r, #location(), f64(i)) }
	loop_rates_frame(&r, {.Page}, #location(), 1000)
	for i in 0 ..< 3 * LOOP_REASONS_KEPT { loop_rates_barren(&r, #location(), 1001 + f64(i)) }
	st := loop_rates_stats(&r)
	frames := 0
	for e, k in st.reasons {
		if e.causes != "wake, no frame" { frames += 1; testing.expect_value(t, e.at_ms, 1000) }
		if k > 0 { testing.expectf(t, st.reasons[k - 1].at_ms <= e.at_ms, "in time: %v then %v", st.reasons[k - 1].at_ms, e.at_ms) }
	}
	testing.expect_value(t, frames, 1)
	testing.expect_value(t, len(st.reasons), LOOP_REASONS_KEPT + 1)
}
