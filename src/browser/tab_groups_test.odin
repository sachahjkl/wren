package browser

import "core:testing"

@(private = "file")
make_tabs :: proc(spec: []struct { pinned: bool, group: u64 }) -> []^Tab {
	tabs := make([]^Tab, len(spec), context.temp_allocator)
	for s, i in spec {
		t := new(Tab, context.temp_allocator)
		t.id, t.pinned, t.group = u64(i + 1), s.pinned, s.group
		tabs[i] = t
	}
	return tabs
}

@(private = "file")
ids_of :: proc(tabs: []^Tab) -> []u64 {
	out := make([]u64, len(tabs), context.temp_allocator)
	for t, i in tabs { out[i] = t.id }
	return out
}

@(private = "file")
same :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a { if x != b[i] { return false } }
	return true
}

// The order rule: pinned tabs first, a group's tabs together where its first tab is, the rest as it was; the current tab
// is followed; a pinned tab is in no group.
@(test)
tabs_keep_pins_first_and_groups_together :: proc(t: ^testing.T) {
	tabs := make_tabs({{false, 0}, {true, 0}, {false, 7}, {false, 0}, {false, 7}, {true, 3}})
	testing.expect(t, !tabs_in_order(tabs))
	cur := tabs_normalize(tabs, 4)   // (tab 5)
	testing.expect(t, same(ids_of(tabs), {2, 6, 1, 3, 5, 4}))
	testing.expect_value(t, cur, 4)
	testing.expect_value(t, tabs[1].group, 0)   // pinned: no group
	testing.expect(t, tabs_in_order(tabs))
	testing.expect_value(t, tabs_normalize(tabs, 2), 2)   // in order: nothing moves
	testing.expect(t, same(ids_of(tabs), {2, 6, 1, 3, 5, 4}))
	testing.expect_value(t, pinned_count(tabs), 2)
	f, l := group_span(tabs, 7)
	testing.expect_value(t, f, 3)
	testing.expect_value(t, l, 4)
}

// A group with no tab left goes (its name too: no leak under the test's tracking allocator); a tab of a group the window
// does not have is in none.
@(test)
groups_without_tabs_go :: proc(t: ^testing.T) {
	groups: [dynamic]Tab_Group
	defer tab_groups_destroy(&groups)
	append(&groups, Tab_Group{id = 1, name = clone_for_test("kept"), color = .Blue}, Tab_Group{id = 2, name = clone_for_test("gone")})
	tabs := make_tabs({{false, 1}, {false, 9}})
	tab_groups_prune(tabs, &groups)
	testing.expect_value(t, len(groups), 1)
	testing.expect_value(t, groups[0].id, 1)
	testing.expect_value(t, tabs[1].group, 0)
	testing.expect_value(t, group_next_color(groups[:]), Group_Color.Red)   // (blue is taken: the next one)
}

@(private = "file")
clone_for_test :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}

// The rows of the sidebar's list: a header before each group's tabs, a collapsed group's tabs left out, pinned tabs not in
// the list; the rows found by place, and only those in a range.
@(test)
sidebar_list_rows_with_groups :: proc(t: ^testing.T) {
	tabs := make_tabs({{true, 0}, {false, 0}, {false, 5}, {false, 5}, {false, 6}, {false, 0}})
	groups := []Tab_Group{{id = 5, color = .Blue}, {id = 6, color = .Red, collapsed = true}}
	items: [dynamic]Side_Item
	defer delete(items)
	h := side_list_layout(tabs, groups, 40, 30, &items)
	// tab 1 | header 5 | tab 2 | tab 3 | header 6 (collapsed: tab 4 hidden) | tab 5
	testing.expect_value(t, len(items), 6)
	testing.expect_value(t, h, 40 + 30 + 40 + 40 + 30 + 40)
	testing.expect_value(t, items[0], Side_Item{.Tab, 1, 0, 40})
	testing.expect_value(t, items[1], Side_Item{.Header, 0, 40, 30})
	testing.expect_value(t, items[4], Side_Item{.Header, 1, 150, 30})
	testing.expect_value(t, items[5], Side_Item{.Tab, 5, 180, 40})
	testing.expect_value(t, side_item_at(items[:], 0), 0)
	testing.expect_value(t, side_item_at(items[:], 45), 1)
	testing.expect_value(t, side_item_at(items[:], 160), 4)
	testing.expect_value(t, side_item_at(items[:], 5000), 5)
	testing.expect_value(t, side_item_at(items[:], -50), 0)
	f, l := side_items_in(items[:], 60, 155)
	testing.expect_value(t, f, 1)
	testing.expect_value(t, l, 5)
	f, l = side_items_in(items[:], 220, 300)   // past the end
	testing.expect_value(t, f, 6)
	testing.expect_value(t, l, 6)
}

// 1000 tabs in groups: the rows built are those in view whatever the scroll, found by a binary search.
@(test)
sidebar_builds_only_the_visible_rows_with_groups :: proc(t: ^testing.T) {
	spec := make([]struct { pinned: bool, group: u64 }, 1000, context.temp_allocator)
	for &s, i in spec { s.group = u64(i / 10 % 2 == 0 ? i / 20 + 1 : 0) }
	tabs := make_tabs(spec)
	groups := make([]Tab_Group, 50, context.temp_allocator)
	for &g, i in groups { g.id = u64(i + 1) }
	items: [dynamic]Side_Item
	defer delete(items)
	_ = side_list_layout(tabs, groups, 40, 30, &items)
	testing.expect_value(t, len(items), 1050)
	f, l := side_visible_items(items[:], 20000, 20000, 400, 80)
	testing.expect(t, l - f <= 400 / 30 + 8 && l - f >= 400 / 40)
	testing.expect(t, items[f].y + items[f].h > 20000 - 80 && items[f].y <= 20000 - 80 + 40)
}

// A dragged tab's new place and group, from the middle of its row: over a tab of a group it joins it, over a tab outside
// it leaves it, over a group's header it goes before the group, out of it.
@(test)
sidebar_drop_into_and_out_of_groups :: proc(t: ^testing.T) {
	tabs := make_tabs({{false, 0}, {false, 5}, {false, 5}, {false, 0}})
	groups := []Tab_Group{{id = 5}}
	items: [dynamic]Side_Item
	defer delete(items)
	_ = side_list_layout(tabs, groups, 40, 30, &items)
	// rows: tab0 0..40 | header 40..70 | tab1 70..110 | tab2 110..150 | tab3 150..190
	to, g := side_drop(items[:], tabs, groups, 0, 20)      // over itself: nothing changes
	testing.expect_value(t, to, 0); testing.expect_value(t, g, 0)
	to, g = side_drop(items[:], tabs, groups, 0, 90)       // down over the group's first tab: joins
	testing.expect_value(t, to, 1); testing.expect_value(t, g, 5)
	to, g = side_drop(items[:], tabs, groups, 0, 50)       // over the header from above: stays before it
	testing.expect_value(t, to, 0); testing.expect_value(t, g, 0)
	to, g = side_drop(items[:], tabs, groups, 3, 50)       // over the header from below: before the group
	testing.expect_value(t, to, 1); testing.expect_value(t, g, 0)
	to, g = side_drop(items[:], tabs, groups, 2, 170)      // the group's last tab down over the next one: leaves
	testing.expect_value(t, to, 3); testing.expect_value(t, g, 0)
	to, g = side_drop(items[:], tabs, groups, 1, 50)       // a group's tab up over its own header: out, before it
	testing.expect_value(t, to, 1); testing.expect_value(t, g, 0)
}

// The pinned tabs' grid: as many per line as the width holds, the slot under a dragged one's middle.
@(test)
sidebar_pins_grid :: proc(t: ^testing.T) {
	testing.expect_value(t, side_pin_cols(230, 40), 5)
	testing.expect_value(t, side_pin_cols(30, 40), 1)
	testing.expect_value(t, side_pin_slot(7, 5, 40), [2]f32{80, 40})
	testing.expect_value(t, side_pin_slot_at({80, 40}, 5, 9, 40), 7)
	testing.expect_value(t, side_pin_slot_at({61, 0}, 5, 9, 40), 2)    // its middle past the line between 1 and 2
	testing.expect_value(t, side_pin_slot_at({900, 900}, 5, 9, 40), 8) // beyond: the last
	testing.expect_value(t, side_pin_slot_at({-30, -30}, 5, 9, 40), 0)
}

// Pinned tabs and groups go through a session file and come back; an older reader's lines are kept as they were.
@(test)
session_keeps_pins_and_groups :: proc(t: ^testing.T) {
	tabs := []Session_Tab{
		{url = "https://a.test/", pinned = true},
		{url = "https://b.test/", group = 4},
		{url = "https://c.test/", group = 4},
		{url = "https://d.test/"},
	}
	groups := []Session_Group{{id = 4, name = "Work\tand\nplay", color = .Green, collapsed = true}}
	text := session_serialize_windows([]Session_Window{{tabs = tabs, current = 2, groups = groups}}, 4096, 4096)
	ws, ok := session_parse_windows(text, 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(ws), 1)
	w := ws[0]
	testing.expect_value(t, len(w.tabs), 4)
	testing.expect_value(t, w.current, 2)
	testing.expect(t, w.tabs[0].pinned && !w.tabs[1].pinned)
	testing.expect_value(t, w.tabs[1].group, 4)
	testing.expect_value(t, w.tabs[2].group, 4)
	testing.expect_value(t, w.tabs[3].group, 0)
	testing.expect_value(t, len(w.groups), 1)
	testing.expect_value(t, w.groups[0].name, "Work\tand\nplay")
	testing.expect_value(t, w.groups[0].color, Group_Color.Green)
	testing.expect(t, w.groups[0].collapsed)
	// (a colour this version does not know is grey; a group line without its fields is skipped)
	odd := "wren-session 2\ncurrent 0\ntgroup\t3\tmauve\t0\tX\ntgroup\t9\ntab https://e.test/\ngroup 3\n"
	ws, ok = session_parse_windows(odd, 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(ws[0].groups), 1)
	testing.expect_value(t, ws[0].groups[0].color, Group_Color.Grey)
	testing.expect_value(t, ws[0].tabs[0].group, 3)
}
