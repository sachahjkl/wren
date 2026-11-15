package browser

import "core:testing"

// Tabs share the strip between their minimum and maximum width.
@(test)
tab_widths_share_the_strip :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, tab_width(1000, 2, 60, 240), 240)    // few tabs: the maximum
	testing.expect_value(t, tab_width(1000, 10, 60, 240), 100)   // an equal share
	testing.expect_value(t, tab_width(1000, 30, 60, 240), 60)    // many: the minimum (the strip scrolls)
	testing.expect_value(t, tab_width(1000, 0, 60, 240), 240)
	testing.expect_value(t, tab_width(100, 3, 300, 240), 240)   // a minimum above the maximum: the maximum
}

// A dragged tab belongs to the slot its middle is over.
@(test)
dragged_tab_slots :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, drag_slot(0, 100, 5), 0)
	testing.expect_value(t, drag_slot(49, 100, 5), 0)
	testing.expect_value(t, drag_slot(50, 100, 5), 1)
	testing.expect_value(t, drag_slot(-80, 100, 5), 0)
	testing.expect_value(t, drag_slot(900, 100, 5), 4)
	testing.expect_value(t, drag_slot(10, 0, 5), 0)
}

// The browser keys of keyboards (WM_APPCOMMAND).
@(test)
browser_keys :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, browser_command_of_appcommand(1), Browser_Command.Back)
	testing.expect_value(t, browser_command_of_appcommand(2), Browser_Command.Forward)
	testing.expect_value(t, browser_command_of_appcommand(3), Browser_Command.Refresh)
	testing.expect_value(t, browser_command_of_appcommand(4), Browser_Command.Stop)
	testing.expect_value(t, browser_command_of_appcommand(7), Browser_Command.Home)
	testing.expect_value(t, browser_command_of_appcommand(8), Browser_Command.None)   // volume mute: not the browser's
}

// Reordering keeps track of the current tab.
@(test)
tab_order_moves :: proc(t: ^testing.T) {
	test_app(t)
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
