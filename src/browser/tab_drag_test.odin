package browser

import "core:testing"
import "toolkit:draw"

@(private = "file")
row_zone :: proc(n: int, offset: f32 = 0) -> Drop_Zone {
	return {rect = {{100, 0}, {500, 36}}, pitch = 100, n = n, offset = offset, valid = true}
}

@(test)
drop_index_is_the_gap_nearest_the_pointer :: proc(t: ^testing.T) {
	z := row_zone(3)
	at, inside := drop_index(z, {120, 10})   // in the first tab's left half: before it
	testing.expect(t, inside)
	testing.expect_value(t, at, 0)
	at, _ = drop_index(z, {180, 10})   // in its right half: after it
	testing.expect_value(t, at, 1)
	at, _ = drop_index(z, {400, 10})   // beyond the last tab: at the end
	testing.expect_value(t, at, 3)
}

@(test)
drop_index_follows_the_scroll_and_the_axis :: proc(t: ^testing.T) {
	z := row_zone(10, 250)   // scrolled by two tabs and a half
	at, _ := drop_index(z, {100, 5})
	testing.expect_value(t, at, 3)   // 250 / 100 + 0.5 = 3
	v := Drop_Zone{rect = {{0, 40}, {200, 440}}, vertical = true, pitch = 40, n = 4, valid = true}
	at, _ = drop_index(v, {50, 100})   // (100 - 40) / 40 + 0.5 = 2
	testing.expect_value(t, at, 2)
}

@(test)
drop_outside_the_tabs_is_no_drop :: proc(t: ^testing.T) {
	z := row_zone(3)
	_, inside := drop_index(z, {120, 80})   // under the row
	testing.expect(t, !inside)
	_, inside = drop_index(z, {50, 10})   // left of it
	testing.expect(t, !inside)
	z.valid = false   // a window that has not laid its tabs out (full screen, hidden bar)
	_, inside = drop_index(z, {120, 10})
	testing.expect(t, !inside)
	z = row_zone(3)
	z.pitch = 0
	_, inside = drop_index(z, {120, 10})
	testing.expect(t, !inside)
}

@(test)
pick_drop_finds_the_window_under_the_pointer :: proc(t: ^testing.T) {
	origins := []draw.Vec2{{0, 0}, {1000, 0}, {1000, 500}}
	zones := []Drop_Zone{row_zone(2), row_zone(2), row_zone(5)}
	w, at, ok := pick_drop(origins, zones, -1, {1180, 10})   // window 1's row: its first tab's right half
	testing.expect(t, ok)
	testing.expect_value(t, w, 1)
	testing.expect_value(t, at, 1)
	w, _, ok = pick_drop(origins, zones, -1, {1300, 510})
	testing.expect_value(t, w, 2)
	// the window being carried is skipped, even when the pointer is over its own bar
	_, _, ok = pick_drop(origins, zones, 1, {1180, 10})
	testing.expect(t, !ok)
	// nowhere
	_, _, ok = pick_drop(origins, zones, 0, {5000, 5000})
	testing.expect(t, !ok)
	// a window above (first in the list) that covers the pointer away from its own tabs hides the tabs of the one below
	covers := []draw.Rect{{{1000, 0}, {1600, 400}}, {{1000, 0}, {1600, 400}}, {}}
	zones2 := []Drop_Zone{row_zone(2), row_zone(2), row_zone(5)}
	origins2 := []draw.Vec2{{1000, -100}, {1000, 0}, {0, 0}}   // window 0's row is 100 px higher than window 1's
	_, _, ok = pick_drop(origins2, zones2, -1, {1180, 10}, covers)
	testing.expect(t, !ok, "covered: no drop on the window below")
	w, _, ok = pick_drop(origins2, zones2, -1, {1180, 10})
	testing.expect(t, ok && w == 1, "(without what they cover: the first one whose tabs are there)")
}

// A tab carried over a row of tabs: pinned ones first, then two groups (1: tabs 2-3, 2: tab 5) and tabs in none.
@(test)
drop_slot_in_a_row_follows_pins_and_groups :: proc(t: ^testing.T) {
	ts: [7]Tab
	ts[0].pinned, ts[1].pinned = true, true
	ts[2].group, ts[3].group, ts[5].group = 1, 1, 2
	tabs: [7]^Tab
	for _, i in ts { tabs[i] = &ts[i] }
	s := drop_slot_row(tabs[:], 100, 30, false)   // over the first pinned tab: after the pinned ones
	testing.expect(t, s.index == 2 && s.group == 0 && !s.pinned && s.mark == 200, "a tab that is not pinned goes after the pinned ones, the mark there")
	s = drop_slot_row(tabs[:], 100, 330, false)   // between the two tabs of group 1
	testing.expect(t, s.index == 3 && s.group == 1 && s.mark == 300, "between two tabs of a group it joins it")
	s = drop_slot_row(tabs[:], 100, 420, false)   // after group 1, before a tab in none
	testing.expect(t, s.index == 4 && s.group == 0, "at a group's edge it stays out")
	s = drop_slot_row(tabs[:], 100, 640, false)   // after group 2's only tab
	testing.expect(t, s.index == 6 && s.group == 0, "after a group's last tab: out of it")
	s = drop_slot_row(tabs[:], 100, 5000, false)
	testing.expect(t, s.index == 7 && s.mark == 700, "beyond the last tab: at the end")
	s = drop_slot_row(tabs[:], 100, 640, true)   // a pinned tab carried over the others
	testing.expect(t, s.index == 2 && s.pinned && s.group == 0 && s.mark == 200, "a pinned tab goes at the end of the pinned ones")
}

// A tab carried over the sidebar's list: rows of tabs and a header before each group, a collapsed group's tabs left out.
@(test)
drop_slot_in_the_list_follows_headers_and_groups :: proc(t: ^testing.T) {
	ts: [6]Tab
	ts[0].pinned = true
	ts[2].group, ts[3].group, ts[5].group = 7, 7, 8
	tabs: [6]^Tab
	for _, i in ts { tabs[i] = &ts[i] }
	groups := []Tab_Group{{id = 7}, {id = 8, collapsed = true}}
	items: [dynamic]Side_Item
	defer delete(items)
	total := side_list_layout(tabs[:], groups, 40, 30, &items)
	// rows: tab 1 (0-40), header 7 (40-70), tab 2 (70-110), tab 3 (110-150), tab 4 (150-190), header 8 (190-220), collapsed
	testing.expect_value(t, total, f32(220))
	s := drop_slot_list(items[:], tabs[:], groups, 10)
	testing.expect(t, s.index == 1 && s.group == 0 && s.mark == 0 && !s.pinned, "the upper half of the first row: before it (after the pinned tab)")
	s = drop_slot_list(items[:], tabs[:], groups, 50)
	testing.expect(t, s.index == 2 && s.group == 0 && s.mark == 40, "a header's upper half: before its group, out of it")
	s = drop_slot_list(items[:], tabs[:], groups, 65)
	testing.expect(t, s.index == 2 && s.group == 7 && s.mark == 70, "its lower half: the start of the group, in it")
	s = drop_slot_list(items[:], tabs[:], groups, 140)
	testing.expect(t, s.index == 4 && s.group == 7 && s.mark == 150, "the lower half of a group's last tab: at its end, in it")
	s = drop_slot_list(items[:], tabs[:], groups, 160)
	testing.expect(t, s.index == 4 && s.group == 0 && s.mark == 150, "the upper half of the next tab, in no group: the same place, out of it")
	s = drop_slot_list(items[:], tabs[:], groups, 215)
	testing.expect(t, s.index == 6 && s.group == 0 && s.mark == 220, "a collapsed group's header, lower half: after the group, out of it")
	s = drop_slot_list(items[:], tabs[:], groups, 1000)
	testing.expect(t, s.index == 6 && s.mark == 220, "below the last row: at the end")
}

@(test)
a_tab_leaves_the_bar_only_far_enough :: proc(t: ^testing.T) {
	row := draw.Rect{{100, 0}, {500, 36}}
	testing.expect(t, !detach_wanted(row, {300, 50}, false, 40))   // below the row, but not by 40
	testing.expect(t, detach_wanted(row, {300, 80}, false, 40))
	testing.expect(t, detach_wanted(row, {300, -50}, false, 40))   // above it (a window at the top of the screen)
	testing.expect(t, !detach_wanted(row, {900, 10}, false, 40))   // along the row is the reorder's
	side := draw.Rect{{0, 40}, {240, 600}}
	testing.expect(t, !detach_wanted(side, {200, 900}, true, 40))   // along the sidebar is the reorder's
	testing.expect(t, detach_wanted(side, {300, 100}, true, 40))
	testing.expect(t, detach_wanted(side, {-60, 100}, true, 40))
}
