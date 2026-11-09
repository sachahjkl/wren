package browser

// Tabs as a tree (browser.tabs.tree), as Tree Style Tab and Sidebery show them:
//
//   * a tab a page opens (a link opened in a new tab, window.open, a link to a new window) is a child of the page's tab,
//     placed after that tab's last descendant; a tab the user opens (Ctrl+T, the + button, a duplicate) is a root;
//   * the order says the tree: a tab's descendants follow it, deeper than it. Tab.parent names the parent's id; what
//     breaks the order (a tab moved by hand, a group's rule, a pinned tab) makes the tab a root (tree_repair);
//   * the sidebar shows each tab indented by its depth, and a triangle on a tab with children that folds them away
//     (Tab.fold; never over the current tab: a folded ancestor of it shows its descendants);
//   * closing a tab, or moving it by hand, gives its children its own parent (they move up a level, in place);
//   * the row of tabs along the top shows them in the same order, flat;
//   * saved with the session: `parent <n>` after a tab, the index of its parent among the window's tabs written.
//
// The procedures on a window's tabs are pure: tab_tree_test.odin.

import "wb:config"

TAB_TREE_PREFS := [?]config.Def{
	{name = "browser.tabs.tree", kind = .Bool, default = {b = true}, category = "tabs",
		description = "Tabs as a tree in the sidebar: a tab a page opens (a link in a new tab, window.open) is a child of the page's tab, shown under it, indented, and a tab with children can fold them away. Off: every new tab is at the end of the list, and the list is flat."},
}

register_tab_tree_prefs :: proc(p: ^config.Prefs) { config.register(p, TAB_TREE_PREFS[:]) }

// The index of the tab whose id is `id` (-1: none).
@(private = "file")
tab_index_of :: proc(tabs: []^Tab, id: u64) -> int {
	if id == 0 { return -1 }
	for t, i in tabs { if t.id == id { return i } }
	return -1
}

// Every tab's parent made true to the order: its parent is the tab before it or one of that tab's ancestors, of the
// same group, and neither is pinned. Any other is a root.
tree_repair :: proc(tabs: []^Tab) {
	path := make([dynamic]^Tab, 0, 8, context.temp_allocator)   // the root .. the tab before
	for t in tabs {
		if t.pinned { t.parent = 0; clear(&path); continue }
		if t.parent != 0 {
			for len(path) > 0 && path[len(path) - 1].id != t.parent { pop(&path) }
			if len(path) == 0 || path[len(path) - 1].group != t.group { t.parent = 0 }
		}
		if t.parent == 0 { clear(&path) }
		append(&path, t)
	}
}

// The depth of each tab (0: a root), the order being repaired (tree_repair).
tree_depths :: proc(tabs: []^Tab, out: []int) {
	path := make([dynamic]u64, 0, 8, context.temp_allocator)
	for t, i in tabs {
		if t.parent == 0 { clear(&path) } else { for len(path) > 0 && path[len(path) - 1] != t.parent { pop(&path) } }
		out[i] = len(path)
		append(&path, t.id)
	}
}

// One past the last descendant of the tab at `i`.
subtree_end :: proc(tabs: []^Tab, i: int) -> int {
	depths := make([]int, len(tabs), context.temp_allocator)
	tree_depths(tabs, depths)
	j := i + 1
	for j < len(tabs) && depths[j] > depths[i] { j += 1 }
	return j
}

// Whether the tab at `i` has children (its next tab is one).
tree_has_children :: proc(tabs: []^Tab, i: int) -> bool { return i + 1 < len(tabs) && tabs[i + 1].parent == tabs[i].id }

// The tab at `child` becomes a child of `parent` (in the same list): it moves after the parent's last descendant and
// takes its group. Returns where it is now; `current` follows the tab it named.
tree_adopt :: proc(tabs: []^Tab, child: int, parent: ^Tab, current: int) -> (at, cur: int) {
	pi := tab_index_of(tabs, parent.id)
	if pi < 0 || pi == child || parent.pinned || tabs[child].pinned { return child, current }
	t := tabs[child]
	t.parent, t.group = parent.id, parent.group
	end := subtree_end(tabs, pi)
	to := child < end ? end - 1 : end   // (taken out first: the places after it move down by one)
	cur = list_move(tabs, child, to, current)
	return to, cur
}

// The tab is taken out of the tree where it is: its children get its parent (they move up a level) and it becomes a root.
tree_detach :: proc(tabs: []^Tab, t: ^Tab) {
	for u in tabs { if u.parent == t.id { u.parent = t.parent } }
	t.parent = 0
}

// Before a tab goes: its children get its parent.
tree_forget :: proc(tabs: []^Tab, t: ^Tab) {
	for u in tabs { if u.parent == t.id { u.parent = t.parent } }
}

// A tab a page opened: under the page's tab when the tree is on (`opener`: the page's tab, nil: none).
tab_tree_opened :: proc(app: ^App, t: ^Tab, opener: ^Tab) {
	if opener == nil || opener == t || !config.bool_of(&app.prefs, "browser.tabs.tree") { return }
	w, _ := window_of_tab(app, t)
	ow, _ := window_of_tab(app, opener)
	if w == nil || w != ow { return }
	tabs := window_tabs(app, w)
	cur := window_current(app, w)
	i := -1
	for x, k in tabs { if x == t { i = k } }
	if i < 0 { return }
	_, cur^ = tree_adopt(tabs[:], i, opener, cur^)
	tabs_fix(app, w)
}

// Whether `t` has children in its window's tree (the tree on).
tab_tree_has_children :: proc(app: ^App, t: ^Tab) -> bool {
	if !config.bool_of(&app.prefs, "browser.tabs.tree") { return false }
	w, _ := window_of_tab(app, t)
	if w == nil { return false }
	tabs := window_tabs(app, w)
	for x, i in tabs { if x == t { return tree_has_children(tabs[:], i) } }
	return false
}

// Folds or unfolds the children of `t`.
tab_tree_toggle :: proc(app: ^App, t: ^Tab) {
	t.fold = !t.fold
	request_frames(app, 2)
	recovery_touch(app)
}
TREE_INDENT_EM :: 1.1   // a child row's indent per level, in ems (tab_sidebar_list.odin)
