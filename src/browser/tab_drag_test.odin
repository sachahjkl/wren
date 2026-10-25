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
