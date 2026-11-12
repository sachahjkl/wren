package browser

import "core:testing"

// A short bookmark (48 px) dragged right over a long one (160 px), at 16 px to the em (hysteresis 3.2 px), from 8 px, 2 px
// apart: it takes the long one's place once its right edge is half into it (pos 256), long before its middle passes the
// long one's middle (pos 277, the rule of before); once moved, it does not come back until it goes as far back the other way.
@(test)
bookmarks_bar_drag_threshold :: proc(t: ^testing.T) {
	before := []f32{160, 48, 160}
	testing.expect_value(t, bar_drag_slot(255, 8, 16, before, 1), 1)
	testing.expect_value(t, bar_drag_slot(256, 8, 16, before, 1), 2)
	after := []f32{160, 160, 48}
	testing.expect_value(t, bar_drag_slot(250, 8, 16, after, 2), 2)   // (no swap back on the next pixel)
	testing.expect_value(t, bar_drag_slot(247, 8, 16, after, 2), 2)
	testing.expect_value(t, bar_drag_slot(246, 8, 16, after, 2), 1)
	// to the left: half into the long one on its left
	testing.expect_value(t, bar_drag_slot(85, 8, 16, before, 1), 1)
	testing.expect_value(t, bar_drag_slot(84, 8, 16, before, 1), 0)
}
