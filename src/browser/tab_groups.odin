package browser

// Pinned tabs and tab groups, as in Chrome, Edge and Firefox.
//
//   * A pinned tab is at the start of its window's tabs; the sidebar shows the pinned tabs as a grid of icons above the
//     list (tab_sidebar.odin), the row of tabs shows their icon alone. A pinned tab is in no group.
//   * A group is a window's: an id (unique in the window), a name (may be empty), one of nine colours and whether it is
//     collapsed. Its tabs are next to each other; the sidebar shows a header row before them (click: collapse or expand,
//     right click: rename, colour, ungroup, close the group) and a rail of its colour beside them; collapsed, its tabs are
//     hidden (the current tab is never in a collapsed group: the group opens when one of its tabs becomes current).
//   * Dragging a tab in the sidebar between the tabs of a group puts it in the group, dragging it out of them takes it out;
//     dragging a tab to the pinned tabs pins it, a pinned tab dragged to the list is no longer pinned.
//   * Both are saved with the session (session.odin: `pin`, `group <id>` after a tab, `tgroup` lines for a window's groups)
//     and the crash recovery. The pinned tabs come back at the next start even when the session is not restored
//     (browser.tabs.restore_pinned: pinned.txt in the profile).
//
// The order rule (pinned first, a group's tabs together) is kept by tabs_normalize after anything that moves tabs or
// changes what they are in; groups left without tabs go (tab_groups_prune).

import "core:fmt"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:config"
import "wb:i18n"

TAB_GROUP_PREFS := [?]config.Def{
	{name = "browser.tabs.restore_pinned", kind = .Bool, default = {b = true},
		description = i18n.tr("Reopen the pinned tabs at start-up even when the session is not restored (browser.session.restore off). Needs browser.profile.persist.")},
	{name = "browser.tabs.group_name_max", kind = .Int, default = {i = 64}, bounded = true, min = 1, max = 1024, unit = "characters",
		description = i18n.tr("Longest name a tab group may have.")},
}

Group_Color :: enum u8 { Grey, Blue, Red, Yellow, Green, Pink, Purple, Cyan, Orange }

GROUP_COLOR_NAMES := [Group_Color]string{
	.Grey = "grey", .Blue = "blue", .Red = "red", .Yellow = "yellow", .Green = "green", .Pink = "pink", .Purple = "purple",
	.Cyan = "cyan", .Orange = "orange",
}

// (mid tones that read on a dark and on a light sidebar)
GROUP_COLOR_HEX := [Group_Color]u32{
	.Grey = 0x8a8f98ff, .Blue = 0x4f8ff7ff, .Red = 0xe2534aff, .Yellow = 0xe0b02eff, .Green = 0x3fae6aff, .Pink = 0xe8609fff,
	.Purple = 0x9c6ef0ff, .Cyan = 0x2fb3c4ff, .Orange = 0xef8a3cff,
}

group_color_of :: proc(name: string) -> (c: Group_Color, ok: bool) {
	for n, k in GROUP_COLOR_NAMES { if n == name { return k, true } }
	return .Grey, false
}

group_color :: proc(c: Group_Color) -> draw.Color { return draw.hex(GROUP_COLOR_HEX[c]) }

Tab_Group :: struct {
	id:        u64,           // unique in its window, never 0
	name:      string,        // owned; "" shows as no name
	color:     Group_Color,
	collapsed: bool,
}

tab_groups_destroy :: proc(groups: ^[dynamic]Tab_Group) {
	for g in groups { delete(g.name) }
	delete(groups^)
	groups^ = nil
}

group_index :: proc(groups: []Tab_Group, id: u64) -> int {
	if id == 0 { return -1 }
	for g, i in groups { if g.id == id { return i } }
	return -1
}

////////////////////////////////
// The order (pure: tab_groups_test.odin)

// The tabs keep the rule already: pinned ones first, each group's tabs next to each other.
tabs_in_order :: proc(tabs: []^Tab) -> bool {
	pins_done := false
	last_group: u64
	for t, i in tabs {
		if t.pinned {
			if pins_done || t.group != 0 { return false }
			continue
		}
		pins_done = true
		if t.group != 0 && t.group != last_group {
			for u in tabs[:i] { if !u.pinned && u.group == t.group { return false } }   // (seen before, then left)
		}
		last_group = t.group
	}
	return true
}

// Brings the tabs back to the rule, moving as little as it takes: the pinned tabs first, in their order; then the others
// in their order, where a group's tabs gather at its first tab. Returns the place of the tab at `current`.
tabs_normalize :: proc(tabs: []^Tab, current: int) -> int {
	for t in tabs { if t.pinned { t.group = 0 } }
	if tabs_in_order(tabs) { return current }
	cur: ^Tab = current >= 0 && current < len(tabs) ? tabs[current] : nil
	out := make([dynamic]^Tab, 0, len(tabs), context.temp_allocator)
	for t in tabs { if t.pinned { append(&out, t) } }
	placed := make(map[u64]bool, 8, context.temp_allocator)
	for t, i in tabs {
		if t.pinned { continue }
		if t.group == 0 { append(&out, t); continue }
		if t.group in placed { continue }
		placed[t.group] = true
		for u in tabs[i:] { if !u.pinned && u.group == t.group { append(&out, u) } }
	}
	copy(tabs, out[:])
	for t, i in tabs { if t == cur { return i } }
	return current
}

// The groups without a tab go; a tab whose group is not one of the window's is in none.
tab_groups_prune :: proc(tabs: []^Tab, groups: ^[dynamic]Tab_Group) {
	for t in tabs { if t.group != 0 && group_index(groups[:], t.group) < 0 { t.group = 0 } }
	for i := len(groups) - 1; i >= 0; i -= 1 {
		used := false
		for t in tabs { if t.group == groups[i].id { used = true; break } }
		if !used {
			delete(groups[i].name)
			ordered_remove(groups, i)
		}
	}
}

// The first and last index of the tabs of group `id` (-1, -1: none), the tab `skip` left out.
group_span :: proc(tabs: []^Tab, id: u64, skip: ^Tab = nil) -> (first, last: int) {
	first, last = -1, -1
	for t, i in tabs {
		if t == skip || t.group != id || id == 0 { continue }
		if first < 0 { first = i }
		last = i
	}
	return
}

pinned_count :: proc(tabs: []^Tab) -> (n: int) {
	for t in tabs { if t.pinned { n += 1 } else { break } }
	return
}

// The colour a new group takes: the first of those the window's groups use least.
group_next_color :: proc(groups: []Tab_Group) -> Group_Color {
	count: [Group_Color]int
	for g in groups { count[g.color] += 1 }
	best := Group_Color.Blue
	for c in ([?]Group_Color{.Blue, .Red, .Yellow, .Green, .Pink, .Purple, .Cyan, .Orange, .Grey}) {
		if count[c] < count[best] { best = c }
	}
	return best
}

////////////////////////////////
// Changes (in the window `w`, active or not)

// After anything that moved tabs or changed what they are in: the rule, the groups, the current tab not hidden, a frame.
tabs_fix :: proc(app: ^App, w: ^Browser_Window) {
	tabs := window_tabs(app, w)
	cur := window_current(app, w)
	cur^ = tabs_normalize(tabs[:], cur^)
	tab_groups_prune(tabs[:], &w.groups)
	group_reveal_current(app, w)
	window_request(app, w, 2)
	recovery_touch(app)
}

// The current tab is never hidden in a collapsed group: its group opens.
group_reveal_current :: proc(app: ^App, w: ^Browser_Window) {
	t := window_current_tab(app, w)
	if t == nil || t.group == 0 { return }
	if gi := group_index(w.groups[:], t.group); gi >= 0 && w.groups[gi].collapsed {
		w.groups[gi].collapsed = false
		window_request(app, w, 2)
	}
}

tab_set_pinned :: proc(app: ^App, t: ^Tab, on: bool) {
	w, i := window_of_tab(app, t)
	if w == nil || t.pinned == on { return }
	tabs := window_tabs(app, w)
	others := pinned_count(tabs[:]) - (t.pinned ? 1 : 0)
	t.pinned, t.group = on, 0
	cur := window_current(app, w)
	cur^ = list_move(tabs[:], i, clamp(others, 0, len(tabs) - 1), cur^)   // (the end of the pinned tabs, or the start of the others)
	tabs_fix(app, w)
}

// A new group of the tab alone, named `name`; returns its id.
tab_group_new :: proc(app: ^App, t: ^Tab, name := "") -> u64 {
	w, _ := window_of_tab(app, t)
	if w == nil { return 0 }
	if t.pinned { tab_set_pinned(app, t, false) }
	id: u64 = 1
	for g in w.groups { id = max(id, g.id + 1) }
	append(&w.groups, Tab_Group{id = id, name = group_name_clone(app, name), color = group_next_color(w.groups[:])})
	tab_group_add(app, t, id)
	return id
}

// The tab joins group `id` of its window, after the group's last tab.
tab_group_add :: proc(app: ^App, t: ^Tab, id: u64) {
	w, i := window_of_tab(app, t)
	if w == nil || group_index(w.groups[:], id) < 0 { return }
	tabs := window_tabs(app, w)
	if t.pinned { t.pinned = false }
	_, last := group_span(tabs[:], id, t)
	t.group = id
	cur := window_current(app, w)
	if last >= 0 { cur^ = list_move(tabs[:], i, i < last ? last : last + 1, cur^) }
	tabs_fix(app, w)
}

// The tab leaves its group, to the place after the group's tabs.
tab_group_leave :: proc(app: ^App, t: ^Tab) {
	w, i := window_of_tab(app, t)
	if w == nil || t.group == 0 { return }
	tabs := window_tabs(app, w)
	_, last := group_span(tabs[:], t.group, t)
	t.group = 0
	cur := window_current(app, w)
	if last > i { cur^ = list_move(tabs[:], i, last, cur^) }
	tabs_fix(app, w)
}

// Collapses or expands a group. Collapsing the group of the current tab selects the nearest tab outside it (none: it stays open).
group_set_collapsed :: proc(app: ^App, w: ^Browser_Window, id: u64, on: bool) {
	gi := group_index(w.groups[:], id)
	if gi < 0 || w.groups[gi].collapsed == on { return }
	if on {
		tabs := window_tabs(app, w)
		cur := window_current(app, w)
		if cur^ < len(tabs) && tabs[cur^].group == id {
			first, last := group_span(tabs[:], id)
			other := last + 1 < len(tabs) ? last + 1 : first - 1
			if other < 0 { return }
			window_select(app, w, other)
		}
	}
	w.groups[gi].collapsed = on
	window_request(app, w, 2)
	recovery_touch(app)
}

group_rename :: proc(app: ^App, w: ^Browser_Window, id: u64, name: string) {
	gi := group_index(w.groups[:], id)
	if gi < 0 { return }
	delete(w.groups[gi].name)
	w.groups[gi].name = group_name_clone(app, name)
	window_request(app, w, 2)
	recovery_touch(app)
}

group_set_color :: proc(app: ^App, w: ^Browser_Window, id: u64, c: Group_Color) {
	gi := group_index(w.groups[:], id)
	if gi < 0 { return }
	w.groups[gi].color = c
	window_request(app, w, 2)
	recovery_touch(app)
}

// Its tabs stay where they are, in no group.
group_ungroup :: proc(app: ^App, w: ^Browser_Window, id: u64) {
	for t in window_tabs(app, w) { if t.group == id { t.group = 0 } }
	tabs_fix(app, w)
}

// Closes the group's tabs (the window closes with them when they were all it had, as closing them one by one does).
group_close :: proc(app: ^App, w: ^Browser_Window, id: u64) {
	tabs := window_tabs(app, w)
	for i := len(tabs) - 1; i >= 0; i -= 1 {
		if i < len(tabs) && tabs[i].group == id { tab_close_in(app, w, i) }
	}
	if !w.closing { tabs_fix(app, w) }
}

group_name_clone :: proc(app: ^App, name: string) -> string {
	s := strings.trim_space(name)
	max_chars := int(config.int_of(&app.prefs, "browser.tabs.group_name_max"))
	n, cut := 0, len(s)
	for _, b in s {
		if n == max_chars { cut = b; break }
		n += 1
	}
	return strings.clone(s[:cut])
}

// What a group is called where it has no name.
group_label :: proc(g: Tab_Group, tabs: []^Tab) -> string {
	if g.name != "" { return g.name }
	n := 0
	for t in tabs { if t.group == g.id { n += 1 } }
	return fmt.tprintf(i18n.tr("%d tabs"), n)
}

// The current tab of window `w` becomes the one at `i` (w active or not).
window_select :: proc(app: ^App, w: ^Browser_Window, i: int) {
	if w == app.active { tab_select(app, i); return }
	tabs := window_tabs(app, w)
	if i < 0 || i >= len(tabs) { return }
	window_current(app, w)^ = i
	ui.field_set(window_address(app, w), tabs[i].url)
	window_request(app, w, 2)
}

////////////////////////////////
// Menus (context_menu.odin)

// The pin and group items of a tab's menu.
tab_menu_group_items :: proc(app: ^App, t: ^Tab) {
	w, _ := window_of_tab(app, t)
	if w == nil { return }
	if ui.menu_item(t.pinned ? i18n.tr("Unpin tab") : i18n.tr("Pin tab")).clicked { tab_set_pinned(app, t, !t.pinned); ui.ctx_menu_close(); return }
	if ui.menu_item(i18n.tr("Add tab to a new group")).clicked { _ = tab_group_new(app, t); ui.ctx_menu_close(); return }
	others := 0
	for g in w.groups { if g.id != t.group { others += 1 } }
	if others > 0 {
		if ui.menu_submenu(fmt.tprintf("%s###add_to_group_sub", i18n.tr("Add tab to group"))) {
			for g in w.groups {
				if g.id == t.group { continue }
				if ui.menu_item(fmt.tprintf("%s###grp_%d", group_label(g, window_tabs(app, w)[:]), g.id)).clicked { tab_group_add(app, t, g.id); ui.ctx_menu_close(); return }
			}
		}
	}
	if t.group != 0 && ui.menu_item(i18n.tr("Remove from group")).clicked { tab_group_leave(app, t); ui.ctx_menu_close(); return }
}

// A group header's menu: rename, colour, a new tab in it, ungroup, close.
group_menu_items :: proc(app: ^App, id: u64) {
	w := active_window(app)
	gi := group_index(w.groups[:], id)
	if gi < 0 { ui.ctx_menu_close(); return }
	g := w.groups[gi]
	if ui.menu_item(i18n.tr("Rename group")).clicked { group_rename_begin(app, id); ui.ctx_menu_close(); return }
	if ui.menu_item(g.collapsed ? i18n.tr("Expand group") : i18n.tr("Collapse group")).clicked { group_set_collapsed(app, w, id, !g.collapsed) }
	if ui.menu_submenu(fmt.tprintf("%s###group_color_sub", i18n.tr("Colour"))) {
		for c in Group_Color {
			if ui.menu_item(fmt.tprintf("%s###gc_%s", i18n.tr(GROUP_COLOR_NAMES[c]), GROUP_COLOR_NAMES[c]), checked = g.color == c).clicked { group_set_color(app, w, id, c) }
		}
	}
	ui.menu_separator()
	if ui.menu_item(i18n.tr("New tab in group")).clicked {
		nt := tab_open_new(app)
		tab_group_add(app, nt, id)
		ui.ctx_menu_close()
		return
	}
	if ui.menu_item(i18n.tr("Ungroup")).clicked { group_ungroup(app, w, id); ui.ctx_menu_close(); return }
	if ui.menu_item(i18n.tr("Close group")).clicked { group_close(app, w, id); ui.ctx_menu_close(); return }
}
