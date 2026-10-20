package browser

import "core:testing"

// Tabs share the strip between their minimum and maximum width.
@(test)
tab_widths_share_the_strip :: proc(t: ^testing.T) {
	testing.expect_value(t, tab_width(1000, 2, 60, 240), 240)    // few tabs: the maximum
	testing.expect_value(t, tab_width(1000, 10, 60, 240), 100)   // an equal share
	testing.expect_value(t, tab_width(1000, 30, 60, 240), 60)    // many: the minimum (the strip scrolls)
	testing.expect_value(t, tab_width(1000, 0, 60, 240), 240)
	testing.expect_value(t, tab_width(100, 3, 300, 240), 240)   // a minimum above the maximum: the maximum
}

// The strip's scroll stays in range and shows the current tab when it changes, without moving otherwise.
@(test)
strip_scroll_follows_the_current_tab :: proc(t: ^testing.T) {
	// 30 tabs of 60 px in 600 px: up to 1200 px of scroll
	testing.expect_value(t, strip_offset(0, 30, 60, 600, 29, true), 1200)    // the last tab: scrolled to the end
	testing.expect_value(t, strip_offset(1200, 30, 60, 600, 0, true), 0)     // the first: back to the start
	testing.expect_value(t, strip_offset(300, 30, 60, 600, 7, true), 300)    // already visible: no move
	testing.expect_value(t, strip_offset(300, 30, 60, 600, 29, false), 300)  // not following: stays
	testing.expect_value(t, strip_offset(5000, 30, 60, 600, 0, false), 1200) // clamped
	testing.expect_value(t, strip_offset(80, 5, 60, 600, 4, true), 0)        // everything fits: no scroll
	testing.expect_value(t, strip_offset(0, 30, 60, 600, 12, true), 180)     // tab 12 (720..780) brought to the right edge
}

// A dragged tab belongs to the slot its middle is over.
@(test)
dragged_tab_slots :: proc(t: ^testing.T) {
	testing.expect_value(t, drag_slot(0, 100, 5), 0)
	testing.expect_value(t, drag_slot(49, 100, 5), 0)
	testing.expect_value(t, drag_slot(50, 100, 5), 1)
	testing.expect_value(t, drag_slot(-80, 100, 5), 0)
	testing.expect_value(t, drag_slot(900, 100, 5), 4)
	testing.expect_value(t, drag_slot(10, 0, 5), 0)
}

// Reordering keeps track of the current tab.
@(test)
tab_order_moves :: proc(t: ^testing.T) {
	l := [5]int{0, 1, 2, 3, 4}
	cur := list_move(l[:], 1, 3, 1)   // the current tab dragged right
	testing.expect_value(t, l, [5]int{0, 2, 3, 1, 4})
	testing.expect_value(t, cur, 3)
	cur = list_move(l[:], 4, 0, 1)    // another tab moves in front of the current one
	testing.expect_value(t, l, [5]int{4, 0, 2, 3, 1})
	testing.expect_value(t, cur, 2)
	cur = list_move(l[:], 0, 4, 3)    // a tab from before the current one goes after it
	testing.expect_value(t, l, [5]int{0, 2, 3, 1, 4})
	testing.expect_value(t, cur, 2)
	cur = list_move(l[:], 2, 2, 2)    // nowhere
	testing.expect_value(t, l, [5]int{0, 2, 3, 1, 4})
	testing.expect_value(t, cur, 2)
	cur = list_move(l[:], 7, 0, 2)    // out of range: nothing
	testing.expect_value(t, l, [5]int{0, 2, 3, 1, 4})
	testing.expect_value(t, cur, 2)
}
