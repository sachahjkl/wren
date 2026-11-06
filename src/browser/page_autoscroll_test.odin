package browser

import "core:testing"
import "toolkit:ui"

// The top is higher by more than half, and the speeds near the anchor are what they were: the curve goes on, it is not stretched.
@(test)
autoscroll_goes_faster_only_far_from_the_anchor :: proc(t: ^testing.T) {
	NEAR_WITHIN :: 0.03
	TOP_RATIO :: 1.55
	FAR_AWAY :: 2000
	before := ui.Autoscroll_Settings{dead_zone = 12, max_speed = 15000, full_dist = 300, doubling = 60}
	now := before
	now.max_speed, now.full_dist = AUTOSCROLL_TOP_SPEED, AUTOSCROLL_FULL_DISTANCE
	for off in ([]f32{30, 72, 160, 280}) {
		a, b := ui.autoscroll_axis_speed(off, before), ui.autoscroll_axis_speed(off, now)
		testing.expectf(t, abs(b - a) <= a * NEAR_WITHIN, "at %v px: %v, it was %v", off, b, a)
	}
	top, was := ui.autoscroll_axis_speed(FAR_AWAY, now), ui.autoscroll_axis_speed(FAR_AWAY, before)
	testing.expectf(t, abs(top / was - TOP_RATIO) < 0.001, "the top: %v, it was %v", top, was)
}
