package browser

import "core:testing"

@(private = "file")
tree_tabs :: proc(n: int) -> []^Tab {
	// (values only: the tree procedures read ids and levels, none of the browser's state)
	backing := make([]Tab, n, context.temp_allocator)
	out := make([]^Tab, n, context.temp_allocator)
	for i in 0 ..< n {
		out[i] = &backing[i]
		out[i].id = u64(i + 1)
	}
	return out
}

@(private = "file")
ids_of :: proc(tabs: []^Tab) -> []u64 {
	out := make([]u64, len(tabs), context.temp_allocator)
	for t, i in tabs { out[i] = t.id }
	return out
}

// A tab opened from another goes after that one's last descendant, one level deeper; its own child deeper still.
@(test)
tree_adopt_places_children_after_the_subtree :: proc(t: ^testing.T) {
	tabs := tree_tabs(5)   // 1 2 3 4 5
	at, cur := tree_adopt(tabs, 4, tabs[0], 0)   // 5 under 1
	testing.expect_value(t, at, 1)
	testing.expect_value(t, cur, 0)
	at, cur = tree_adopt(tabs, 4, tabs[0], cur)   // 4 under 1: after 5
	testing.expect_value(t, at, 2)
	at, _ = tree_adopt(tabs, 4, tabs[1], cur)   // 3 under 5
	testing.expect_value(t, at, 2)
	got := ids_of(tabs)
	want := []u64{1, 5, 3, 4, 2}
	for id, i in want { testing.expectf(t, got[i] == id, "order %v, want %v", got, want) }
	depths := make([]int, len(tabs), context.temp_allocator)
	tree_depths(tabs, depths)
	want_depths := []int{0, 1, 2, 1, 0}
	for d, i in want_depths { testing.expectf(t, depths[i] == d, "depths %v, want %v", depths, want_depths) }
	testing.expect_value(t, subtree_end(tabs, 0), 4)
	testing.expect(t, tree_has_children(tabs, 0) && tree_has_children(tabs, 1) && !tree_has_children(tabs, 2))
}

// Closing a parent, or moving it by hand, gives its children its own parent: they move up a level in place.
@(test)
tree_forget_and_detach_lift_the_children :: proc(t: ^testing.T) {
	tabs := tree_tabs(4)   // 1 > 2 > 3, 4 under 1
	tabs[1].parent, tabs[2].parent, tabs[3].parent = 1, 2, 1
	tree_forget(tabs, tabs[1])
	testing.expect_value(t, tabs[2].parent, u64(1))
	tree_detach(tabs, tabs[0])
	testing.expect_value(t, tabs[0].parent, u64(0))
	testing.expect_value(t, tabs[2].parent, u64(0))
	testing.expect_value(t, tabs[3].parent, u64(0))
}

// What the order no longer allows is undone: a parent that is not an ancestor of the tab before, in another group,
// or a pinned one.
@(test)
tree_repair_keeps_only_what_the_order_says :: proc(t: ^testing.T) {
	tabs := tree_tabs(6)
	tabs[1].parent = 1            // fine: under 1
	tabs[2].parent = 1            // fine: a sibling of 2
	tabs[3].parent = 2            // 2 is not before it on the path (3 came between, at the same level as 2): a root
	tabs[4].parent = 4            // fine: under 4
	tabs[4].group = 9             // ... but in another group than 4: a root
	tabs[5].parent = 1            // 1 is no longer on the path: a root
	tabs[0].pinned = true         // a pinned tab is in no tree, nor are its would-be children
	tree_repair(tabs)
	want := []u64{0, 0, 0, 0, 0, 0}
	for p, i in want { testing.expectf(t, tabs[i].parent == p, "tab %d: parent %d, want %d", i + 1, tabs[i].parent, p) }

	tabs2 := tree_tabs(4)
	tabs2[1].parent, tabs2[2].parent, tabs2[3].parent = 1, 2, 1
	tree_repair(tabs2)
	want2 := []u64{0, 1, 2, 1}
	for p, i in want2 { testing.expectf(t, tabs2[i].parent == p, "tab %d: parent %d, want %d", i + 1, tabs2[i].parent, p) }
}

// The sidebar's rows: indented by depth; a folded tab hides its descendants, except where the current tab is.
@(test)
tree_rows_fold_except_toward_the_current_tab :: proc(t: ^testing.T) {
	tabs := tree_tabs(5)   // 1 > 2 > 3, 1 > 4, 5
	tabs[1].parent, tabs[2].parent, tabs[3].parent = 1, 2, 1
	items := make([dynamic]Side_Item, context.temp_allocator)
	_ = side_list_layout(tabs, nil, 40, 30, &items, 0, true)
	testing.expect_value(t, len(items), 5)
	testing.expect_value(t, items[2].depth, 2)
	tabs[0].fold = true
	_ = side_list_layout(tabs, nil, 40, 30, &items, 0, true)
	testing.expect_value(t, len(items), 2)   // 1 and 5
	testing.expect_value(t, items[1].index, 4)
	_ = side_list_layout(tabs, nil, 40, 30, &items, 2, true)   // the current tab is 3, under the folded 1: 1 shows its tree
	testing.expect_value(t, len(items), 5)
	_ = side_list_layout(tabs, nil, 40, 30, &items, 0, false)   // the tree off: flat
	testing.expect_value(t, len(items), 5)
	testing.expect_value(t, items[2].depth, 0)
}

// The session keeps the tree: a parent by its place among the tabs written.
@(test)
tree_survives_the_session :: proc(t: ^testing.T) {
	tabs := []Session_Tab{{url = "https://a.example/"}, {url = "https://b.example/", parent = 1, fold = true}, {url = "https://c.example/", parent = 2}}
	text := session_serialize_windows({{tabs = tabs, current = 0}}, 4096, 4096)
	back, _, ok := session_parse_tabs(text, 100, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, len(back), 3)
	testing.expect_value(t, back[0].parent, 0)
	testing.expect_value(t, back[1].parent, 1)
	testing.expect_value(t, back[1].fold, true)
	testing.expect_value(t, back[2].parent, 2)
}

// The guide lines: a child followed by a sibling continues its parent's line (├), the last one ends it (└); a deeper
// row is crossed by the lines of the levels that go on below it; a group's header ends every line.
@(test)
tree_guides_follow_the_siblings :: proc(t: ^testing.T) {
	//  0 Parent / 1 Child one / 2 Grandchild / 1 Child two / -1 header / 1 (a child after a header: nothing goes on)
	depths := []int{0, 1, 2, 1, -1, 1}
	g := make([]Tree_Guide, len(depths), context.temp_allocator)
	tree_guides(depths, g)
	testing.expect_value(t, g[1], Tree_Guide{rails = 0, last = false})
	testing.expect_value(t, g[2], Tree_Guide{rails = 1, last = true})   // level 0 goes on to Child two
	testing.expect_value(t, g[3], Tree_Guide{rails = 0, last = true})
	testing.expect_value(t, g[4], Tree_Guide{})
	testing.expect_value(t, g[5], Tree_Guide{rails = 0, last = true})
}

// Dragged sideways: the depth asked for, clamped to one more than the tab before's, gives the parent.
@(test)
tree_parent_at_depth_follows_the_tab_before :: proc(t: ^testing.T) {
	tabs := tree_tabs(4)   // 1 > 2 > 3, and 4 (a root) after them
	tabs[1].parent, tabs[2].parent = 1, 2
	testing.expect_value(t, tree_parent_at_depth(tabs, 3, 0), u64(0))
	testing.expect_value(t, tree_parent_at_depth(tabs, 3, 1), u64(1))   // a child of 1, after 3
	testing.expect_value(t, tree_parent_at_depth(tabs, 3, 2), u64(2))
	testing.expect_value(t, tree_parent_at_depth(tabs, 3, 3), u64(3))
	testing.expect_value(t, tree_parent_at_depth(tabs, 3, 9), u64(3))   // (no deeper than under the tab before)
	testing.expect_value(t, tree_parent_at_depth(tabs, 0, 2), u64(0))   // nothing before: a root
	tabs[3].group = 7
	testing.expect_value(t, tree_parent_at_depth(tabs, 3, 1), u64(0))   // another group than the tab before's
}
