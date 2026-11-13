package browser

// The tab sidebar's tabs (tab_sidebar.odin builds the column, its header and its width handle):
//   * the pinned tabs (tab_groups.odin), a grid of icons at the top, as many per line as the width holds (one in the narrow
//     column), in a box of their own that scrolls past browser.tabs.sidebar_pins_max share of the column;
//   * the other tabs, one row each, in a scroll box: a header row before the tabs of each group, a rail of the group's colour
//     beside its rows, a collapsed group's tabs left out (side_list_layout: one list of rows of two heights);
//   * only the rows in view, and a margin, are built (side_items_in: a binary search on the rows' places);
//   * a row dragged along the list moves its tab live; its middle over the tabs of a group puts it in the group, over a
//     header or a tab outside it takes it out (side_drop); dragged up to the pinned tabs it is pinned, a pinned tab dragged
//     down into the list is no longer pinned.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import lucide "toolkit:lucide"
import "wb:i18n"

////////////////////////////////
// Layout (pure: tab_sidebar_test.odin)

Side_Item_Kind :: enum u8 { Tab, Header }

Side_Item :: struct {
	kind:  Side_Item_Kind,
	index: int,   // the tab's index in the window's tabs; a header's: its group's in the window's groups
	y, h:  f32,   // in the list's content
	depth: int,   // a tab's in the tree (tab_tree.odin; 0: a root, or the tree is off)
}

// The rows of the list (the tabs that are not pinned, `rh` high, and a header `hh` high before each group's tabs); the
// tabs of a collapsed group are left out, and the descendants of a folded tab (tab_tree.odin) unless the current tab
// (`current`) is one of them. `tree` off: every tab at depth 0. Returns the content's height.
side_list_layout :: proc(tabs: []^Tab, groups: []Tab_Group, rh, hh: f32, out: ^[dynamic]Side_Item, current := -1, tree := false) -> (height: f32) {
	clear(out)
	y: f32
	prev: u64
	hidden := false
	depths := make([]int, len(tabs), context.temp_allocator)
	if tree { tree_depths(tabs, depths) }
	// the folded tabs that are ancestors of the current one fold nothing
	open_chain := make(map[u64]bool, 8, context.temp_allocator)
	if tree && current >= 0 && current < len(tabs) {
		for id := tabs[current].parent; id != 0; {
			open_chain[id] = true
			next: u64 = 0
			for u in tabs { if u.id == id { next = u.parent; break } }
			id = next
		}
	}
	fold_depth := -1   // the depth of the folded tab whose descendants are being skipped (-1: none)
	for t, i in tabs {
		if t.pinned { continue }
		if t.group != prev {
			prev, hidden = t.group, false
			fold_depth = -1
			if gi := group_index(groups, t.group); gi >= 0 {
				append(out, Side_Item{.Header, gi, y, hh, 0})
				y += hh
				hidden = groups[gi].collapsed
			}
		}
		if hidden { continue }
		if fold_depth >= 0 {
			if depths[i] > fold_depth { continue }
			fold_depth = -1
		}
		append(out, Side_Item{.Tab, i, y, rh, depths[i]})
		y += rh
		if tree && t.fold && !open_chain[t.id] && tree_has_children(tabs, i) { fold_depth = depths[i] }
	}
	return y
}

// The rows that overlap lo .. hi (content y): [first, last).
side_items_in :: proc(items: []Side_Item, lo, hi: f32) -> (first, last: int) {
	a, b := 0, len(items)
	for a < b {
		m := (a + b) / 2
		if items[m].y + items[m].h <= lo { a = m + 1 } else { b = m }
	}
	first = a
	a, b = first, len(items)
	for a < b {
		m := (a + b) / 2
		if items[m].y < hi { a = m + 1 } else { b = m }
	}
	return first, a
}

// The row at content y (the first or the last one beyond the ends; -1: no row).
side_item_at :: proc(items: []Side_Item, y: f32) -> int {
	if len(items) == 0 { return -1 }
	f, _ := side_items_in(items, y, y)
	return clamp(f, 0, len(items) - 1)
}

// The rows to build, as side_visible_rows says for rows of one height: what the view shows (`off`), where its scroll is
// heading (`target`, at most two views away) and `overscan` around.
side_visible_items :: proc(items: []Side_Item, off, target, view_h, overscan: f32) -> (first, last: int) {
	to := clamp(target, off - view_h * 2, off + view_h * 2)
	return side_items_in(items, min(off, to) - overscan, max(off, to) + view_h + overscan)
}

// Where a tab dragged in the list goes, from the middle of its row (`mid`, content y): the index it takes among the
// window's tabs and the group it is in there. `from`: its index now.
side_drop :: proc(items: []Side_Item, tabs: []^Tab, groups: []Tab_Group, from: int, mid: f32) -> (to: int, group: u64) {
	k := side_item_at(items, mid)
	if k < 0 { return from, tabs[from].group }
	it := items[k]
	switch it.kind {
	case .Tab:
		if it.index == from { return from, tabs[from].group }
		return it.index, tabs[it.index].group
	case .Header:
		// before the group, out of it
		first, _ := group_span(tabs, groups[it.index].id, tabs[from])
		if first < 0 { return from, 0 }
		return from < first ? first - 1 : first, 0
	}
	return from, tabs[from].group
}

// The pinned tabs' grid: as many `cell` wide per line as `width` holds (one at least).
side_pin_cols :: proc(width, cell: f32) -> int { return max(1, int(math.floor(width / max(cell, 1)))) }

side_pin_slot :: proc(k, cols: int, cell: f32) -> [2]f32 { return {f32(k % cols) * cell, f32(k / cols) * cell} }

// The slot of a pinned tab whose top-left is at `p` (grid coordinates): the cell its middle is over, among `np`.
side_pin_slot_at :: proc(p: [2]f32, cols, np: int, cell: f32) -> int {
	if np <= 0 { return 0 }
	c := clamp(int(math.floor((p.x + cell * 0.5) / cell)), 0, cols - 1)
	r := max(int(math.floor((p.y + cell * 0.5) / cell)), 0)
	return clamp(r * cols + c, 0, np - 1)
}

////////////////////////////////
// Building

// The pinned tabs then the list.
sidebar_list :: proc(app: ^App, pos: Tabs_Position, open: f32, extent: f32, cc: ^Classic_Colors) {
	wnd := active_window(app)
	group_reveal_current(app, wnd)
	sidebar_pins(app, pos, open, extent, cc)

	own := &wnd.own
	em := ui.font_size()
	n := len(wnd.tabs)
	rh := ui.dense(math.round(em * app.favs.cfg.side_row_em))
	hh := math.round(rh * 0.8)

	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	area_flags := ui.Box_Flags{.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Clickable}
	if cc != nil && pos == .Left { area_flags += {.Scrollbar_Left} }   // (classic: the inner edge is the current tab's)
	area := ui.build_box(area_flags, "###tabs_area")
	tab_list_a11y(area, true)
	if ui.signal(area).right_clicked { bookmarks_bar_menu(app, ui.mouse_pos()) }   // the wheel; a right click where no tab is (bookmarks_bar.odin)
	own.strip.area_key = area.key
	tab_press_follows(wnd, own.sidebar.pins_key, area.key)   // (a pinned tab dragged down into the list: unpinned on the way)
	total := side_list_layout(wnd.tabs[:], wnd.groups[:], rh, hh, &own.sidebar.items, wnd.current, app.cfg.tabs_tree)
	if cc != nil {
		// classic: the feet of the current tab reach beyond its row, above the first and below the last: room for them inside the
		// clip, else they are cut and the tab's outline does not join the panel's edge line
		lead := tab_dims(side_tab_metrics(em, ui_scale_of(app), rh, rh)).ext
		for &it in own.sidebar.items { it.y += lead }
		total += lead * 2
	}
	items := own.sidebar.items[:]
	if app.active != nil { app.active.zone = {rect = area.rect, vertical = true, offset = area.view_off.y, pitch = rh, n = n, valid = true} }
	view_h := area.size.y > 0 ? area.size.y : f32(active_window(app).win.size.y)
	limit := max(total - view_h, 0)

	// a new current tab is scrolled into view (not while one is dragged: the list follows the pointer then)
	cur_id := wnd.tabs[wnd.current].id
	if cur_id != own.strip.follow_id || n != own.strip.follow_n || !own.sidebar.shown {
		for it in items {
			if it.kind != .Tab || it.index != wnd.current { continue }
			o := area.view_target.y
			if it.y < o { o = it.y }
			if it.y + it.h > o + view_h { o = it.y + it.h - view_h }
			area.view_target.y = o
			break
		}
	}
	own.strip.follow_id, own.strip.follow_n, own.sidebar.shown = cur_id, n, true
	area.view_target.y = clamp(area.view_target.y, 0, limit)

	inset := math.round(em * 0.35)
	bar_w := math.round(max(6, em * 0.5)) + inset   // what the scroll bar takes when the list overflows
	row_w := extent - inset * 2 - (limit > 0 ? bar_w - inset : 0) - 1
	row_x := inset
	if cc != nil {
		// classic: from the outer side (past the scroll bar, which is there) to the inner edge
		outer := limit > 0 ? bar_w : inset
		row_w = extent - outer
		row_x = pos == .Left ? outer : 0
	}
	tree := app.cfg.tabs_tree
	first, last := side_visible_items(items, area.view_off.y, area.view_target.y, view_h, rh * 2)
	dragged := -1
	for t, i in wnd.tabs {
		if !t.pinned && t.id == own.strip.dragged { dragged = i; break }
	}
	focused := focused_tab_index(app)
	// classic: the current tab is built after the others (its feet flare over its neighbours' rows)
	late := cc != nil && wnd.current != dragged ? wnd.current : -1
	row :: proc(app: ^App, it: Side_Item, rh, row_x, row_w, inset, open, total, limit: f32, area: ^ui.Box, cc: ^Classic_Colors, drag_y: ^f32) {
		// (tab_tree.odin: a child is indented by its depth, while the sidebar shows the titles)
		indent := it.depth > 0 && open >= 0.5 ? min(f32(it.depth) * tree_step(app), row_w * 0.5) : 0
		y, dragging := sidebar_row(app, it.index, it.y, rh, row_x + indent, row_w - indent, inset, open, area, limit, total, cc, indent)
		if dragging { drag_y^ = y }
	}

	drag_y: f32 = -1
	// a tab carried over this list (tab_drag.odin): the rows from its place on make room for it
	gap := app.active != nil && app.active.dropping ? app.active.drop.mark : -1
	moved :: proc(it: Side_Item, gap, rh: f32) -> Side_Item {
		it := it
		if gap >= 0 && it.y >= gap - 0.5 { it.y += rh }
		return it
	}
	if ui.parent(area) {
		ui.spacer(ui.px(gap >= 0 ? total + rh : total), exact = true)   // the content's height: the scroll range
		late_item, focus_item, drag_item := -1, -1, -1
		for it, k in items {
			if it.kind != .Tab { continue }
			if it.index == late { late_item = k }
			if it.index == focused { focus_item = k }
			if it.index == dragged { drag_item = k }
		}
		for k in first ..< last {
			it := moved(items[k], gap, rh)
			if it.kind == .Header {
				sidebar_group_row(app, it, row_x, row_w, inset, open, area, cc)
				continue
			}
			if it.index == dragged || it.index == late { continue }
			row(app, it, rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y)
		}
		if late_item >= first && late_item < last {
			row(app, moved(items[late_item], gap, rh), rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y)
		}
		// a row that has the keyboard stays built when it scrolls out of view
		if focus_item >= 0 && (focus_item < first || focus_item >= last) && focused != dragged {
			row(app, moved(items[focus_item], gap, rh), rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y)
		}
		if drag_item >= 0 {   // built last: it draws over the others and takes the clicks
			row(app, moved(items[drag_item], gap, rh), rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y)
		}
		if gap >= 0 { drop_ghost(app, area, true, gap - area.view_off.y, rh, row_x, row_w) }
		if tree && open >= 0.5 { tree_guides_build(app, items[:], first, last, gap, rh, row_x, row_w, open) }
	}
	// the dragged row's place moves its tab: in the list (and in or out of a group), or up to the pinned tabs
	if dragged >= 0 && drag_y >= 0 {
		t := wnd.tabs[dragged]
		pins := ui.prev_box("###pins")
		over_pins := ui.mouse_pos().y < area.rect.min.y - (pinned_count(wnd.tabs[:]) > 0 ? 0 : rh * 0.4)
		if over_pins && pins != nil && ui.mouse_pos().y >= pins.rect.min.y - hh * 2 {
			tab_set_pinned(app, t, true)
			own.sidebar.pin_grab = {rh * 0.5, rh * 0.5}
			own.strip.follow_id = t.id
		} else {
			to, g := side_drop(items, wnd.tabs[:], wnd.groups[:], dragged, drag_y + rh * 0.5)
			if to != dragged || g != t.group {
				t.group = g
				tree_detach(wnd.tabs[:], t)   // tab_tree.odin: moved by hand, out of its tree
				wnd.current = list_move(wnd.tabs[:], dragged, to, wnd.current)
				tabs_fix(app, wnd)
				own.strip.follow_id = wnd.tabs[wnd.current].id   // no jump of the scroll while dragging
				request_frames(app, 2)
			}
			// tab_tree.odin: the pointer right of where it was pressed, one level deeper per indent step (under the tab
			// before, or one of its ancestors); left, less deep
			if tree {
				i := -1
				for x, k in wnd.tabs { if x == t { i = k; break } }
				if own.sidebar.drag_tab != t.id {
					depths := make([]int, len(wnd.tabs), context.temp_allocator)
					tree_depths(wnd.tabs[:], depths)
					own.sidebar.drag_tab, own.sidebar.drag_depth = t.id, i >= 0 ? depths[i] : 0
				}
				if i >= 0 {
					want := max(own.sidebar.drag_depth + int(math.round(own.sidebar.drag_dx / max(tree_step(app), 1))), 0)
					if p := tree_parent_at_depth(wnd.tabs[:], i, want); p != t.parent {
						tree_detach(wnd.tabs[:], t)
						t.parent = p
						tabs_fix(app, wnd)
						request_frames(app, 2)
					}
				}
			}
		}
	} else {
		own.sidebar.drag_tab = 0
	}
	tabs_frame(app)
}

// What every frame of the sidebar does for every tab: its title and icon follow its document (throttled per tab), the
// loading indicators turn. (The icons of the tabs out of view stay in the cache: favicon_evict.)
@(private = "file")
tabs_frame :: proc(app: ^App) {
	wnd := active_window(app)
	tab_sound_frame(app)   // tab_sound.odin
	any_turning := false
	icon_px := tab_icon_px(app)
	for t in wnd.tabs {
		tab_refresh(app, t, icon_px)
		any_turning ||= tab_busy(t) && spinner_turning(app, t)
		// (an icon not drawn this frame is still in use: favicon_evict keeps what the tabs show)
	}
	if any_turning { spinner_wake(app) }
}

// The pinned tabs: a grid of icons above the list.
@(private = "file")
sidebar_pins :: proc(app: ^App, pos: Tabs_Position, open, extent: f32, cc: ^Classic_Colors) {
	wnd := active_window(app)
	own := &wnd.own
	em := ui.font_size()
	dpi := ui_scale_of(app)
	np := pinned_count(wnd.tabs[:])
	cell := ui.dense(math.round(em * app.favs.cfg.side_row_em))
	inset := math.round(em * 0.35)
	cols := side_pin_cols(extent - inset * 2, cell)
	rows := (np + cols - 1) / cols
	content := f32(rows) * cell
	body_h := f32(wnd.win.size.y)
	h := np > 0 ? min(content, math.round(body_h * app.favs.cfg.side_pins_max)) + inset : 0
	ui.next({width = ui.fill(), height = ui.px(h), axis = .Y})
	box := ui.build_box(np > 0 ? {.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Draw_Side_Bottom} : {}, "###pins")
	own.sidebar.pins_key = box.key
	if np == 0 { return }
	_ = ui.signal(box)
	ui.a11y_set(box, {name = i18n.tr("Pinned tabs")})
	margin := math.round((extent - f32(cols) * cell) * 0.5)
	tab_press_follows(wnd, own.strip.area_key, box.key)   // (a row of the list dragged up here: pinned on the way)
	dragged := -1
	for k in 0 ..< np { if ui.reorder_dragging(tab_box_key(box.key, wnd.tabs[k].id)) { dragged = k } }
	cur := wnd.tabs[wnd.current]
	if ui.parent(box) {
		ui.spacer(ui.px(content), exact = true)
		order := make([dynamic]int, 0, np, context.temp_allocator)
		for k in 0 ..< np { if k != dragged { append(&order, k) } }
		if dragged >= 0 { append(&order, dragged) }   // (drawn over the others)
		for k in order {
			t := wnd.tabs[k]
			on := t == cur
			slot := side_pin_slot(k, cols, cell)
			p: [2]f32
			kx, ky := ui.key_from_string(box.key, fmt.tprintf("px%d", t.id)), ui.key_from_string(box.key, fmt.tprintf("py%d", t.id))
			if k == dragged {
				p = ui.mouse_pos() - box.rect.min + {0, box.view_off.y} - own.sidebar.pin_grab - {margin, 0}
				_, _ = ui.anim(kx, p.x, 30, p.x), ui.anim(ky, p.y, 30, p.y)
			} else {
				p = {math.round(ui.anim(kx, slot.x, 30, slot.x)), math.round(ui.anim(ky, slot.y, 30, slot.y))}
			}
			gap := math.round(em * 0.15)
			id_buf: [32]u8
			id := tab_box_id(&id_buf, t.id)
			if !on { ui.push_tags("weak") }
			ui.next({fixed_x = margin + p.x + gap, fixed_y = p.y + gap, width = ui.px(cell - gap * 2), height = ui.px(cell - gap * 2), axis = .X, cross = .Center, radius = em * 0.45})
			ui.push_tags("tab")
			b := ui.build_box({.Clickable, .Focusable, .Middle_Click, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
			ui.pop_tags()
			look := ui.frame_new(Side_Look)
			look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, CHROME_ANIM_SELECT_RATE)
			look.accent = ui.color("accent")
			look.left = pos == .Left
			look.pin = true
			side_look_machined(app, look, b)
			b.custom, b.custom_user = side_row_draw, look
			b.cursor = .Arrow
			tab_a11y(b, t, k, len(wnd.tabs), on)
			if ui.parent(b) {
				isz := f32(tab_icon_px(app))
				ui.spacer(ui.fill())
				ui.next({width = ui.px(isz), height = ui.pct(1)})
				ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
				ui.spacer(ui.fill())
				side := cell - gap * 2
				tab_speaker_badge(tab_speaker(app, t), {math.round((side - isz) * 0.5 + isz * 0.45), math.round((side - isz) * 0.5 + isz * 0.45)}, math.round(isz * 0.8), "###speaker_badge")
			}
			if !on { ui.pop_tags() }
			sig := ui.signal(b)
			if (sig.pressed || sig.clicked) && !on { tab_select(app, k) }
			if sig.right_clicked { tab_context_menu(app, k, ui.mouse_pos()) }
			if sig.middle_clicked && app.favs.cfg.middle_close { shell_after_build(app, {kind = .Close_Tab, tab = t.id, flag = true}); return }
			if own.strip.dragged == 0 { sidebar_tip(sig, t) }
			if sig.pressed { own.sidebar.pin_grab = ui.mouse_pos() - b.rect.min + {gap, gap} }
			if sig.dragging && app.favs.cfg.drag_reorder {
				// (held at its middle: carried down into the list, the row follows the pointer from there)
				ui.reorder_begin(b.key, max(abs(sig.drag_delta.x), abs(sig.drag_delta.y)), app.favs.cfg.drag_threshold * dpi, cell * 0.5, 0)
			}
			// (also a tab of the list dragged up here: pinned on the way, its press was handed to this box: tab_press_follows)
			if ui.reorder_dragging(b.key) {
				request_frames(app, 2)
				if ui.mouse_pos().y > box.rect.max.y + cell * 0.5 {
					// down into the list: no longer pinned (the list carries on with the drag, the row under the pointer)
					tab_set_pinned(app, t, false)
					own.strip.follow_id = t.id
					return
				}
				to := side_pin_slot_at(p, cols, np, cell)
				if to != k {
					wnd.current = list_move(wnd.tabs[:], k, to, wnd.current)
					recovery_touch(app)
				}
			}
		}
	}
}

@(private = "file")
Side_Look :: struct {
	selected: f32,   // 0..1, animated
	accent:   draw.Color,
	left:     bool,
	pin:      bool,  // a pinned tab's square: the wash only
	machined: bool,  // the machined style: the current row a bevelled part (its bar on the outer edge as ever)
	face:     draw.Color,
	hot_t:    f32,   // machined: 0..1, the pointer over it (animated)
}

// The machined style's part of a row's look (chrome_style.odin).
@(private = "file")
side_look_machined :: proc(app: ^App, l: ^Side_Look, b: ^ui.Box) {
	if !machined_on(app) { return }
	l.machined, l.face = true, ui.color("button background")
	l.hot_t = ui.anim(ui.key_from_string(b.key, "mhot"), b.hot_t > 0.5 ? 1 : 0, CHROME_ANIM_HOVER_RATE)
}

// One tab's row at `slot` (content y), animated when tabs move; a dragged row follows the pointer. Returns where it is
// (content y) and whether it is the one dragged.
@(private = "file")
sidebar_row :: proc(app: ^App, i: int, slot, rh, row_x, row_w, inset: f32, open: f32, area: ^ui.Box, limit, total: f32, cc: ^Classic_Colors, indent: f32 = 0) -> (y: f32, dragging: bool) {
	wnd := active_window(app)
	own := &wnd.own
	t := wnd.tabs[i]
	n := len(wnd.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == wnd.current
	id_buf: [32]u8
	id := tab_box_id(&id_buf, t.id)
	// (list coordinates: the scroll box places the rows; the release slides from where the pointer left it)
	y, dragging = ui.reorder_item_pos(tab_box_key(area.key, t.id), slot, ui.mouse_pos().y - area.rect.min.y + area.view_off.y, 0, max(total - rh, 0))
	prev := ui.prev_box(id)
	inside := prev != nil && ui.box_contains(prev, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos())

	// a group's tabs: a rail of its colour on the outer side
	if gi := group_index(wnd.groups[:], t.group); gi >= 0 {
		th := max(math.round(2.5 * dpi), 2)
		// (the list's edge, not the row's: a child of the tree is indented, its group's rail is not)
		rx := app.favs.cfg.position == .Left ? math.round((row_x - indent) * 0.5 - th * 0.5) : math.round(row_x + row_w + (inset - th) * 0.5)
		ui.next({fixed_x = rx, fixed_y = y, width = ui.px(th), height = ui.px(rh), bg = group_color(wnd.groups[gi].color)})
		ui.build_box({.Draw_Background}, fmt.tprintf("###rail_%d", t.id))
	}

	if !on { ui.push_tags("weak") }
	defer if !on { ui.pop_tags() }
	ui.next({fixed_x = row_x, fixed_y = y, width = ui.px(row_w), height = ui.px(rh), axis = .X, cross = .Center, radius = em * 0.45})
	ui.push_tags("tab")
	b: ^ui.Box
	if cc != nil {
		// classic (chrome_style.odin): not clipped, the current tab's feet flare past its row
		b = ui.build_box({.Clickable, .Focusable, .Middle_Click, .Hot_Within}, id)
		pos := app.favs.cfg.position
		look := ui.frame_new(Classic_Side_Tab)
		look^ = {c = cc, pos = pos, m = side_tab_metrics(em, dpi, rh, row_w), dragging = dragging, inset = math.round(em * 0.6), gap = math.round(em * 0.3)}
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, CHROME_ANIM_SELECT_RATE)
		look.hover = ui.anim(ui.key_from_string(b.key, "hov"), (inside || dragging) && !on ? 1 : 0, CHROME_ANIM_HOVER_RATE)
		// an engraved line under it, between two tabs that are neither current nor under the pointer
		if open > 0 && !on && !inside && !dragging && i + 1 < n && i + 1 != wnd.current && !wnd.tabs[i + 1].pinned {
			next_buf: [32]u8
			nb := ui.prev_box(tab_box_id(&next_buf, wnd.tabs[i + 1].id))
			look.rule = !(nb != nil && ui.box_contains(nb, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos()))
		}
		b.custom, b.custom_user = classic_side_tab_draw, look
	} else {
		b = ui.build_box({.Clickable, .Focusable, .Middle_Click, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
		look := ui.frame_new(Side_Look)
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, CHROME_ANIM_SELECT_RATE)
		look.accent = ui.color("accent")
		look.left = app.favs.cfg.position == .Left
		side_look_machined(app, look, b)
		b.custom, b.custom_user = side_row_draw, look
	}
	ui.pop_tags()
	b.cursor = .Arrow
	tab_a11y(b, t, i, n, on)

	closed := false
	if ui.parent(b) {
		isz := f32(tab_icon_px(app))
		// (one layout whatever `open` is: the icon slides from the middle of the narrow row to its place, the title and the
		// close button fade in behind it, clipped by the row while it widens)
		ix := side_icon_x(row_w - window_own(app).sidebar.past_closed, isz, math.round(em * 0.65), open)
		ui.spacer(ui.px(ix))
		// tab_tree.odin: a tab with children shows, in its icon's place, a chevron that folds them away: while the pointer
		// is on the row, and always while they are folded (the icons stay in line by depth)
		if open >= 0.5 && app.cfg.tabs_tree && tree_has_children(wnd.tabs[:], i) && (inside || t.fold) {
			s := math.round(max(isz, em * 1.2))
			ui.next({width = ui.px(isz), height = ui.pct(1), axis = .X, cross = .Center})
			ui.push_parent(ui.build_box({}, "###twisty_slot"))
			ui.spacer(ui.px(math.round((isz - s) * 0.5)))
			ui.next({width = ui.px(s), height = ui.px(s), font = app.lucide, font_size = math.round(em * 0.95), text_pad = 0, radius = s * 0.5})
			tw := ui.build_box({.Clickable, .Draw_Text, .Draw_Hot_Effects, .No_Text_Trunc}, fmt.aprintf("%s###twisty", t.fold ? lucide.CHEVRON_RIGHT : lucide.CHEVRON_DOWN, allocator = ui.frame_allocator()))
			tw.text_align = .Center
			ui.a11y_set(tw, {role = .Button, name = t.fold ? i18n.tr("Show the tabs it opened") : i18n.tr("Fold the tabs it opened"), expanded = !t.fold})
			ui.pop_parent()
			tsig := ui.signal(tw)
			if tsig.clicked { tab_tree_toggle(app, t) }
			tip(tsig, t.fold ? i18n.tr("Show the tabs it opened") : i18n.tr("Fold the tabs it opened"))
		} else {
			ui.next({width = ui.px(isz), height = ui.pct(1)})
			ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
		}
		speaker := tab_speaker(app, t)
		// the narrow column: the speaker over the icon's corner (the tab's menu mutes it); open: a button of its own
		if open < 0.5 { tab_speaker_badge(speaker, {ix + isz * 0.45, math.round((rh - isz) * 0.5 + isz * 0.45)}, math.round(isz * 0.8), "###speaker_badge") }
		if open > 0 {
			ui.spacer(ui.px(math.round(em * 0.5)))
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center, transparency = 1 - side_title_alpha(open)})
			ui.push_parent(ui.build_box({}, "###titles"))
			defer ui.pop_parent()
			title := t.title
			if strings.contains(title, "###") { title, _ = strings.replace_all(title, "###", "# # #", context.temp_allocator) }
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.a11y({ignore = true})   // (the tab's name)
			ui.build_box({.Draw_Text}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
			if speaker != .None && open >= 0.5 {
				if ui.tab_stops(false) { _ = tab_speaker_button(app, t, speaker, math.round(em * 1.45), "###speaker") }
			}
			if on || inside {
				cs := math.round(em * 1.45)
				if ui.tab_stops(false) {
					ui.next({width = ui.px(cs), height = ui.px(cs), radius = cs * 0.5})
					cb: ^ui.Box
					if ui.tags("icon_button") {
						cb = ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, "###close")
						cross := ui.frame_new(draw.Color)
						cross^ = ui.color("text")
						cb.custom, cb.custom_user = close_cross_draw, cross
					}
					c := ui.signal(cb)
					tip(c, i18n.tr("Close tab (Ctrl+W)"))
					if c.clicked { closed = true }
				}
			}
			ui.spacer(ui.px(math.round(em * 0.35)))
		}
	}
	if closed { shell_after_build(app, {kind = .Close_Tab, tab = t.id, flag = true}); return }
	sig := ui.signal(b)
	if (sig.pressed || sig.clicked) && !on { tab_select(app, i) }   // the press selects; Enter / Space too
	if sig.right_clicked { tab_context_menu(app, i, ui.mouse_pos()) }
	if sig.middle_clicked && app.favs.cfg.middle_close { shell_after_build(app, {kind = .Close_Tab, tab = t.id, flag = true}); return }
	if own.strip.dragged == 0 { sidebar_tip(sig, t) }

	// drag to reorder, along Y (straight out sideways starts a drag too: it may leave the bar)
	if sig.dragging && app.favs.cfg.drag_reorder && (n > 1 || app.favs.cfg.drag_detach) {
		ui.reorder_begin(b.key, ui.reorder_moved(sig.drag_delta, .Y, app.favs.cfg.drag_detach), app.favs.cfg.drag_threshold * dpi,
			ui.mouse_pos().y - sig.drag_delta.y - area.rect.min.y + area.view_off.y, slot)
	}
	if ui.reorder_dragging(b.key) {
		dragging = true
		own.sidebar.drag_dx = sig.drag_delta.x   // (tab_tree.odin: sideways, deeper or less deep)
		// the list follows the pointer to its ends: a row held past the edge scrolls it
		area.view_target.y = ui.reorder_edge_scroll(y, rh, area.view_off.y, area.size.y, limit, area.view_target.y)
		request_frames(app, 2)
		// far enough beside the list: the tab leaves for a window of its own (tab_drag.odin)
		if app.favs.cfg.drag_detach && detach_wanted(area.rect, ui.mouse_pos(), true, app.favs.cfg.detach_distance_em * em) {
			dragging = false   // (its box goes, and the press with it)
			shell_after_build(app, {kind = .Tear_Off, tab = t.id, at = ui.mouse_pos()})
		}
	}
	return
}

// A group's header: its colour, its name (or how many tabs it has), and whether it is collapsed. A click collapses or
// expands it, a double click renames it, right click: its menu.
@(private = "file")
sidebar_group_row :: proc(app: ^App, it: Side_Item, row_x, row_w, inset, open: f32, area: ^ui.Box, cc: ^Classic_Colors) {
	wnd := active_window(app)
	own := &wnd.own
	g := wnd.groups[it.index]
	em := ui.font_size()
	id := fmt.tprintf("###grp_%d", g.id)
	y := math.round(ui.anim(ui.key_from_string(area.key, fmt.tprintf("g%d", g.id)), it.y, 30, it.y))
	label := group_label(g, wnd.tabs[:])
	ui.next({fixed_x = row_x, fixed_y = y, width = ui.px(row_w), height = ui.px(it.h), axis = .X, cross = .Center, radius = em * 0.45})
	b := ui.build_box({.Clickable, .Focusable, .Middle_Click, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
	ui.a11y_set(b, {name = label, expanded = !g.collapsed})
	renaming := own.sidebar.renaming == g.id && open >= 1
	if ui.parent(b) {
		isz := f32(tab_icon_px(app))
		ui.spacer(ui.px(side_icon_x(row_w - window_own(app).sidebar.past_closed, isz, math.round(em * 0.65), open)))
		chip := ui.frame_new(Group_Chip)
		chip^ = {color = group_color(g.color), collapsed = g.collapsed, text = ui.color("text")}
		ui.next({width = ui.px(isz), height = ui.pct(1)})
		ui.custom("###chip", group_chip_draw, chip)
		if open > 0 {
			ui.spacer(ui.px(math.round(em * 0.5)))
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center, transparency = 1 - side_title_alpha(open)})
			ui.push_parent(ui.build_box({}, "###titles"))
			defer ui.pop_parent()
			if renaming {
				ui.next({width = ui.fill(), height = ui.px(math.round(it.h * 0.85))})
				res := ui.line_edit("###grp_name", &own.sidebar.rename_field, i18n.tr("Group name"))
				if own.sidebar.renaming != 0 && !own.sidebar.rename_focused {
					ui.set_focus(res.box.key)
					ui.field_select_all(&own.sidebar.rename_field)
				}
				switch {
				case res.committed, own.sidebar.rename_focused && !res.focused:
					group_rename(app, wnd, g.id, ui.field_string(&own.sidebar.rename_field))
					own.sidebar.renaming, own.sidebar.rename_focused = 0, false
				case res.cancelled:
					own.sidebar.renaming, own.sidebar.rename_focused = 0, false
				case res.focused:
					own.sidebar.rename_focused = true
				}
			} else {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.a11y({ignore = true})
				ui.build_box({.Draw_Text}, fmt.aprintf("%s###gname", label, allocator = ui.frame_allocator()))
				if g.collapsed && g.name != "" {
					n := 0
					for t in wnd.tabs { if t.group == g.id { n += 1 } }
					ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
					if ui.tags("weak") { ui.build_box({.Draw_Text}, fmt.aprintf("%d###gcount", n, allocator = ui.frame_allocator())) }
				}
			}
			ui.spacer(ui.px(math.round(em * 0.35)))
		}
	}
	if renaming { return }
	sig := ui.signal(b)
	if sig.double_clicked { group_rename_begin(app, g.id); return }
	if sig.clicked { group_set_collapsed(app, wnd, g.id, !g.collapsed) }
	if sig.right_clicked { group_context_menu(app, g.id, ui.mouse_pos()) }
	tip(sig, g.collapsed ? fmt.tprintf(i18n.tr("%s: expand the group"), label) : fmt.tprintf(i18n.tr("%s: collapse the group"), label))
}

// Starts editing a group's name in its header (the sidebar opens to its titles if it shows only icons).
group_rename_begin :: proc(app: ^App, id: u64) {
	wnd := active_window(app)
	gi := group_index(wnd.groups[:], id)
	if gi < 0 { return }
	s := &wnd.own.sidebar
	s.renaming, s.rename_focused = id, false
	ui.field_set(&s.rename_field, wnd.groups[gi].name)
	if app.favs.cfg.position != .Top && app.favs.cfg.side_collapsed { set_pref_bool(app, "browser.tabs.sidebar_collapsed", false) }
	request_frames(app, 2)
}

@(private = "file")
Group_Chip :: struct {
	color, text: draw.Color,
	collapsed:   bool,
}

// A group's mark: a disc of its colour, a ring when collapsed.
@(private = "file")
group_chip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Group_Chip)(user)
	c := draw.rect_center(b.rect)
	s := (b.rect.max.x - b.rect.min.x) * 0.7
	r := draw.Rect{{c.x - s * 0.5, c.y - s * 0.5}, {c.x + s * 0.5, c.y + s * 0.5}}
	if d.collapsed {
		draw.rect(dc, r, d.color, s * 0.5, max(math.round(2 * ui.scale()), 2))
	} else {
		draw.rect(dc, r, d.color, s * 0.5)
	}
}

// A tip beside the row: the title and, under it, the address.
sidebar_tip :: proc(sig: ui.Signal, t: ^Tab) {
	if !ui.hovered_for(sig) { return }
	if ui.tooltip_beside() {
		em := ui.font_size()
		ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 1.7))})
		ui.label(fmt.aprintf("%s###tip", t.title, allocator = ui.frame_allocator()))
		if t.url != "" && t.url != t.title {
			ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 1.5))})
			if ui.tags("weak") { ui.label(fmt.aprintf("%s###tip_url", t.url, allocator = ui.frame_allocator())) }
		}
	}
}

// The current row: an accent wash and a bar on its outer edge, growing in (a pinned tab: the wash).
@(private = "file")
side_row_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Side_Look)(user)
	if l.selected < 0.01 { return }
	r := b.rect
	if l.machined {
		face := l.face
		face.a *= l.selected
		ui.machined_bevel(dc, r, b.radius, face, l.hot_t, 0)
	} else {
		wash := l.accent
		wash.a *= 0.16 * l.selected
		draw.rect(dc, r, wash, b.radius)
	}
	if l.pin { return }
	th := max(math.round(2.5 * ui.scale()), 2)
	h := (r.max.y - r.min.y) * 0.5 * l.selected
	cy := (r.min.y + r.max.y) * 0.5
	x0 := l.left ? r.min.x : r.max.x - th
	draw.rect(dc, {{x0, cy - h * 0.5}, {x0 + th, cy + h * 0.5}}, l.accent, th * 0.5)
}

// A level of the tree in the sidebar (tab_tree.odin): from a row's start to its icon's middle, where its children's line
// goes down, and the elbow from there to the child's row (its edge: the line never enters a row).
tree_step :: proc(app: ^App) -> f32 {
	em := ui.font_size()
	return math.round(em * 0.65) + math.round(f32(tab_icon_px(app)) * 0.5) + math.round(em * TREE_ELBOW_EM)
}

// The guide lines of the tree (tab_tree.odin): in the indent left of the rows first ..< last, from each parent's icon down
// to its children's rows, with a rounded elbow to each. `gap`: where a tab carried over the list makes room (-1: none).
@(private = "file")
tree_guides_build :: proc(app: ^App, items: []Side_Item, first, last: int, gap, rh, row_x, row_w, open: f32) {
	depths := make([]int, len(items), context.temp_allocator)
	any := false
	for it, k in items {
		depths[k] = it.kind == .Tab ? it.depth : -1
		any ||= it.depth > 0
	}
	if !any { return }
	guides := make([]Tree_Guide, len(items), context.temp_allocator)
	tree_guides(depths, guides)
	em := ui.font_size()
	step := tree_step(app)
	text := ui.color("text")
	dpi := ui_scale_of(app)
	for k in first ..< last {
		it := items[k]
		if it.kind != .Tab || it.depth <= 0 { continue }
		w := f32(it.depth) * step
		if w > row_w * 0.5 { continue }   // (the indent is capped there: the lines would not meet the rows)
		y := it.y
		if gap >= 0 && y >= gap - 0.5 { y += rh }
		look := ui.frame_new(Tree_Guide_Look)
		look^ = {guide = guides[k], depth = it.depth, step = step, axis = math.round(em * 0.65) + math.round(f32(tab_icon_px(app)) * 0.5),
			color = {text.r, text.g, text.b, text.a * 0.42 * clamp((open - 0.5) * 2, 0, 1)}, thick = max(math.round(1.5 * dpi), 1),
			radius = math.round(em * 0.4), gap = max(math.round(em * 0.12), 1)}
		ui.next({fixed_x = row_x, fixed_y = y, width = ui.px(w), height = ui.px(rh)})
		b := ui.build_box({}, fmt.tprintf("###tree_guide_%d", it.index))
		b.custom, b.custom_user = tree_guide_draw, look
	}
}

@(private = "file")
Tree_Guide_Look :: struct {
	guide:                            Tree_Guide,
	depth:                            int,
	step, axis, thick, radius, gap:   f32,   // axis: from a level's start to its line
	color:                            draw.Color,
}

// Draws only inside its box, which is the row's indent: nothing reaches into a row.
@(private = "file")
tree_guide_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Tree_Guide_Look)(user)
	top, bottom := b.rect.min.y, b.rect.max.y
	mid := math.round((top + bottom) * 0.5)
	left := b.rect.min.x
	level_x :: proc(l: ^Tree_Guide_Look, left: f32, k: int) -> f32 { return math.round(left + f32(k) * l.step + l.axis - l.thick * 0.5) }
	for k in 0 ..< l.depth - 1 {
		if l.guide.rails & (1 << u64(k)) == 0 { continue }
		x := level_x(l, left, k)
		draw.rect(dc, {{x, top}, {x + l.thick, bottom}}, l.color)
	}
	// the elbow: down the parent's line, a quarter circle, along to the row's edge; the line goes on when a sibling follows
	x := level_x(l, left, l.depth - 1)
	end := b.rect.max.x - l.gap
	r := min(l.radius, end - x - l.thick)
	if !l.guide.last { draw.rect(dc, {{x, top}, {x + l.thick, bottom}}, l.color) } else { draw.rect(dc, {{x, top}, {x + l.thick, mid - r}}, l.color) }
	cx := x + l.thick * 0.5
	if r > 0 {
		pts: [9]draw.Vec2
		for s in 0 ..< len(pts) {
			a := f32(s) / f32(len(pts) - 1) * math.PI * 0.5
			pts[s] = {cx + r - r * math.cos(a), mid - r + r * math.sin(a)}
		}
		draw.polyline(dc, pts[:], l.thick, l.color)
	}
	draw.rect(dc, {{cx + max(r, 0), mid - l.thick * 0.5}, {end, mid + l.thick * 0.5}}, l.color)
}
