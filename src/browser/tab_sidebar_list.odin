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
import "wb:i18n"

////////////////////////////////
// Layout (pure: tab_sidebar_test.odin)

Side_Item_Kind :: enum u8 { Tab, Header }

Side_Item :: struct {
	kind:  Side_Item_Kind,
	index: int,   // the tab's index in the window's tabs; a header's: its group's in the window's groups
	y, h:  f32,   // in the list's content
}

// The rows of the list (the tabs that are not pinned, `rh` high, and a header `hh` high before each group's tabs); the
// tabs of a collapsed group are left out. Returns the content's height.
side_list_layout :: proc(tabs: []^Tab, groups: []Tab_Group, rh, hh: f32, out: ^[dynamic]Side_Item) -> (height: f32) {
	clear(out)
	y: f32
	prev: u64
	hidden := false
	for t, i in tabs {
		if t.pinned { continue }
		if t.group != prev {
			prev, hidden = t.group, false
			if gi := group_index(groups, t.group); gi >= 0 {
				append(out, Side_Item{.Header, gi, y, hh})
				y += hh
				hidden = groups[gi].collapsed
			}
		}
		if hidden { continue }
		append(out, Side_Item{.Tab, i, y, rh})
		y += rh
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

// The pinned tabs then the list. Returns true when a tab closed (the build stops: the tab list changed under it).
sidebar_list :: proc(app: ^App, pos: Tabs_Position, open: f32, extent: f32, cc: ^Classic_Colors) -> (closed: bool) {
	wnd := active_window(app)
	group_reveal_current(app, wnd)
	if sidebar_pins(app, pos, open, extent, cc) { return true }

	own := &wnd.own
	em := ui.font_size()
	n := len(wnd.tabs)
	rh := ui.dense(math.round(em * favs.cfg.side_row_em))
	hh := math.round(rh * 0.8)

	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	area_flags := ui.Box_Flags{.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}
	if cc != nil && pos == .Left { area_flags += {.Scrollbar_Left} }   // (classic: the inner edge is the current tab's)
	area := ui.build_box(area_flags, "###tabs_area")
	tab_list_a11y(area, true)
	_ = ui.signal(area)   // the wheel
	own.strip.area_key = area.key
	total := side_list_layout(wnd.tabs[:], wnd.groups[:], rh, hh, &own.sidebar.items)
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
	first, last := side_visible_items(items, area.view_off.y, area.view_target.y, view_h, rh * 2)
	dragged := -1
	for t, i in wnd.tabs {
		if !t.pinned && ui.reorder_dragging(&own.strip.drag, t.id) { dragged = i; break }
	}
	focused := focused_tab_index(app)
	// classic: the current tab is built after the others (its feet flare over its neighbours' rows)
	late := cc != nil && wnd.current != dragged ? wnd.current : -1
	row :: proc(app: ^App, it: Side_Item, rh, row_x, row_w, inset, open, total, limit: f32, area: ^ui.Box, cc: ^Classic_Colors, drag_y: ^f32) -> bool {
		y, dragging, closed := sidebar_row(app, it.index, it.y, rh, row_x, row_w, inset, open, area, limit, total, cc)
		if dragging { drag_y^ = y }
		return closed
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
			if row(app, it, rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y) { return true }
		}
		if late_item >= first && late_item < last {
			if row(app, moved(items[late_item], gap, rh), rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y) { return true }
		}
		// a row that has the keyboard stays built when it scrolls out of view
		if focus_item >= 0 && (focus_item < first || focus_item >= last) && focused != dragged {
			if row(app, moved(items[focus_item], gap, rh), rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y) { return true }
		}
		if drag_item >= 0 {   // built last: it draws over the others and takes the clicks
			if row(app, moved(items[drag_item], gap, rh), rh, row_x, row_w, inset, open, total, limit, area, cc, &drag_y) { return true }
		}
		if gap >= 0 { drop_ghost(app, area, true, gap - area.view_off.y, rh, row_x, row_w) }
	}
	// the dragged row's place moves its tab: in the list (and in or out of a group), or up to the pinned tabs
	if dragged >= 0 && drag_y >= 0 && own.strip.drag.active {
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
				wnd.current = list_move(wnd.tabs[:], dragged, to, wnd.current)
				tabs_fix(app, wnd)
				own.strip.follow_id = wnd.tabs[wnd.current].id   // no jump of the scroll while dragging
				request_frames(app, 2)
			}
		}
	}
	tabs_frame(app, first, last, items)
	return false
}

// What every frame of the sidebar does for every tab: its title and icon follow its document (throttled per tab), the
// loading indicators turn, the icons of the tabs out of view stay in the cache.
@(private = "file")
tabs_frame :: proc(app: ^App, first, last: int, items: []Side_Item) {
	wnd := active_window(app)
	shown_lo, shown_hi := len(wnd.tabs), -1
	if first < last {
		for k in first ..< last { if items[k].kind == .Tab { shown_lo = min(shown_lo, items[k].index); shown_hi = max(shown_hi, items[k].index) } }
	}
	np := pinned_count(wnd.tabs[:])
	tab_sound_frame(app)   // tab_sound.odin
	any_turning := false
	for t, i in wnd.tabs {
		tab_refresh(app, t, tab_icon_px(app))
		any_turning ||= tab_busy(t) && spinner_turning(t)
		// (an icon not drawn this frame is still in use: the cache keeps what its tabs show)
		if i >= np && (i < shown_lo || i > shown_hi) && t.icon.url != "" { _, _ = favicon_texture(t.icon.url) }
	}
	if any_turning { spinner_wake(app) }
}

// The pinned tabs: a grid of icons above the list. Returns true when a tab closed.
@(private = "file")
sidebar_pins :: proc(app: ^App, pos: Tabs_Position, open, extent: f32, cc: ^Classic_Colors) -> (closed: bool) {
	wnd := active_window(app)
	own := &wnd.own
	em := ui.font_size()
	dpi := ui_scale_of(app)
	np := pinned_count(wnd.tabs[:])
	cell := ui.dense(math.round(em * favs.cfg.side_row_em))
	inset := math.round(em * 0.35)
	cols := side_pin_cols(extent - inset * 2, cell)
	rows := (np + cols - 1) / cols
	content := f32(rows) * cell
	body_h := f32(wnd.win.size.y)
	h := np > 0 ? min(content, math.round(body_h * favs.cfg.side_pins_max)) + inset : 0
	ui.next({width = ui.fill(), height = ui.px(h), axis = .Y})
	box := ui.build_box(np > 0 ? {.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y, .Draw_Side_Bottom} : {}, "###pins")
	own.sidebar.pins_key = box.key
	if np == 0 { return false }
	_ = ui.signal(box)
	ui.a11y_set(box, {name = i18n.tr("Pinned tabs")})
	margin := math.round((extent - f32(cols) * cell) * 0.5)
	dragged := -1
	for k in 0 ..< np { if ui.reorder_dragging(&own.strip.drag, wnd.tabs[k].id) { dragged = k } }
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
			id := fmt.tprintf("###tab_%d", t.id)
			if !on { ui.push_tags("weak") }
			ui.next({fixed_x = margin + p.x + gap, fixed_y = p.y + gap, width = ui.px(cell - gap * 2), height = ui.px(cell - gap * 2), axis = .X, cross = .Center, radius = em * 0.45})
			ui.push_tags("tab")
			b := ui.build_box({.Clickable, .Focusable, .Middle_Click, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
			ui.pop_tags()
			look := ui.frame_new(Side_Look)
			look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
			look.accent = ui.color("accent")
			look.left = pos == .Left
			look.pin = true
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
			if sig.middle_clicked && favs.cfg.middle_close { tab_close(app, k); return true }
			if !own.strip.drag.active { sidebar_tip(sig, t) }
			if sig.pressed { own.sidebar.pin_grab = ui.mouse_pos() - b.rect.min + {gap, gap} }
			if sig.dragging && favs.cfg.drag_reorder {
				ui.reorder_begin(&own.strip.drag, t.id, max(abs(sig.drag_delta.x), abs(sig.drag_delta.y)), favs.cfg.drag_threshold * dpi, 0, 0)
			}
			// (also a tab of the list dragged up here: pinned on the way, it was pressed as a row of the list)
			if ui.reorder_dragging(&own.strip.drag, t.id) {
				request_frames(app, 2)
				if ui.mouse_pos().y > box.rect.max.y + cell * 0.5 {
					// down into the list: no longer pinned (the list carries on with the drag, the row under the pointer)
					tab_set_pinned(app, t, false)
					own.strip.drag.grab = cell * 0.5
					own.strip.follow_id = t.id
					return false
				}
				to := side_pin_slot_at(p, cols, np, cell)
				if to != k {
					wnd.current = list_move(wnd.tabs[:], k, to, wnd.current)
					recovery_touch(app)
				}
			}
		}
	}
	return false
}

@(private = "file")
Side_Look :: struct {
	selected: f32,   // 0..1, animated
	accent:   draw.Color,
	left:     bool,
	pin:      bool,  // a pinned tab's square: the wash only
}

// One tab's row at `slot` (content y), animated when tabs move; a dragged row follows the pointer. Returns where it is
// (content y) and whether it is the one dragged; `closed` when the tab closed.
@(private = "file")
sidebar_row :: proc(app: ^App, i: int, slot, rh, row_x, row_w, inset: f32, open: f32, area: ^ui.Box, limit, total: f32, cc: ^Classic_Colors) -> (y: f32, dragging: bool, closed: bool) {
	wnd := active_window(app)
	own := &wnd.own
	t := wnd.tabs[i]
	n := len(wnd.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == wnd.current
	id := fmt.tprintf("###tab_%d", t.id)
	akey := ui.key_from_string(area.key, fmt.tprintf("y%d", t.id))
	// (list coordinates: the scroll box places the rows; the release slides from where the pointer left it)
	y, dragging = ui.reorder_item_pos(&own.strip.drag, akey, t.id, slot, ui.mouse_pos().y - area.rect.min.y + area.view_off.y, 0, max(total - rh, 0))
	prev := ui.prev_box(id)
	inside := prev != nil && ui.box_contains(prev, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos())

	// a group's tabs: a rail of its colour on the outer side
	if gi := group_index(wnd.groups[:], t.group); gi >= 0 {
		th := max(math.round(2.5 * dpi), 2)
		rx := favs.cfg.position == .Left ? math.round(row_x * 0.5 - th * 0.5) : math.round(row_x + row_w + (inset - th) * 0.5)
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
		pos := favs.cfg.position
		look := ui.frame_new(Classic_Side_Tab)
		look^ = {c = cc, pos = pos, m = side_tab_metrics(em, dpi, rh, row_w), dragging = dragging, inset = math.round(em * 0.6), gap = math.round(em * 0.3)}
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
		look.hover = ui.anim(ui.key_from_string(b.key, "hov"), (inside || dragging) && !on ? 1 : 0, 40)
		// an engraved line under it, between two tabs that are neither current nor under the pointer
		if open > 0 && !on && !inside && !dragging && i + 1 < n && i + 1 != wnd.current && !wnd.tabs[i + 1].pinned {
			nb := ui.prev_box(fmt.tprintf("###tab_%d", wnd.tabs[i + 1].id))
			look.rule = !(nb != nil && ui.box_contains(nb, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos()))
		}
		b.custom, b.custom_user = classic_side_tab_draw, look
	} else {
		b = ui.build_box({.Clickable, .Focusable, .Middle_Click, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
		look := ui.frame_new(Side_Look)
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
		look.accent = ui.color("accent")
		look.left = favs.cfg.position == .Left
		b.custom, b.custom_user = side_row_draw, look
	}
	ui.pop_tags()
	b.cursor = .Arrow
	tab_a11y(b, t, i, n, on)

	if ui.parent(b) {
		isz := f32(tab_icon_px(app))
		// (one layout whatever `open` is: the icon slides from the middle of the narrow row to its place, the title and the
		// close button fade in behind it, clipped by the row while it widens)
		ix := side_icon_x(row_w, isz, math.round(em * 0.65), open)
		ui.spacer(ui.px(ix))
		ui.next({width = ui.px(isz), height = ui.pct(1)})
		ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
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
	if closed { tab_close(app, i); return }
	sig := ui.signal(b)
	if (sig.pressed || sig.clicked) && !on { tab_select(app, i) }   // the press selects; Enter / Space too
	if sig.right_clicked { tab_context_menu(app, i, ui.mouse_pos()) }
	if sig.middle_clicked && favs.cfg.middle_close { tab_close(app, i); closed = true; return }
	if !own.strip.drag.active { sidebar_tip(sig, t) }

	// drag to reorder, along Y (straight out sideways starts a drag too: it may leave the bar)
	if sig.dragging && favs.cfg.drag_reorder && (n > 1 || favs.cfg.drag_detach) {
		ui.reorder_begin(&own.strip.drag, t.id, ui.reorder_moved(sig.drag_delta, .Y, favs.cfg.drag_detach), favs.cfg.drag_threshold * dpi,
			ui.mouse_pos().y - sig.drag_delta.y - area.rect.min.y + area.view_off.y, slot)
	}
	if ui.reorder_dragging(&own.strip.drag, t.id) {
		dragging = true
		// the list follows the pointer to its ends: a row held past the edge scrolls it
		area.view_target.y = ui.reorder_edge_scroll(y, rh, area.view_off.y, area.size.y, limit, area.view_target.y)
		request_frames(app, 2)
		// far enough beside the list: the tab leaves for a window of its own (tab_drag.odin)
		if favs.cfg.drag_detach && detach_wanted(area.rect, ui.mouse_pos(), true, favs.cfg.detach_distance_em * em) {
			own.strip.drag.active = false
			dragging = false
			if tab_drag_begin(app, t, ui.mouse_pos()) && len(wnd.tabs) != n { closed = true; return }
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
		ui.spacer(ui.px(side_icon_x(row_w, isz, math.round(em * 0.65), open)))
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
	if favs.cfg.position != .Top && favs.cfg.side_collapsed { set_pref_bool(app, "browser.tabs.sidebar_collapsed", false) }
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
	if !ui.hovered_for(sig, 0.45) { return }
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
	wash := l.accent
	wash.a *= 0.16 * l.selected
	draw.rect(dc, r, wash, b.radius)
	if l.pin { return }
	th := max(math.round(2.5 * ui.scale()), 2)
	h := (r.max.y - r.min.y) * 0.5 * l.selected
	cy := (r.min.y + r.max.y) * 0.5
	x0 := l.left ? r.min.x : r.max.x - th
	draw.rect(dc, {{x0, cy - h * 0.5}, {x0 + th, cy + h * 0.5}}, l.accent, th * 0.5)
}
