package browser

// The row of tabs (the window's title bar when it is integrated: window_chrome.odin), as in Chrome and Edge:
//   * each tab: the site's icon (favicon.odin) or a loading indicator, its title cut with an ellipsis, a close button
//     (on every tab when they are wide enough, else on the current one and the one under the pointer);
//   * tabs share the strip's width between browser.tabs.min_width_em and max_width_em; past the minimum the row is the
//     toolkit's strip (ui.strip): it scrolls with arrow buttons on its faded edges and the wheel, never a scroll bar, and
//     brings the current tab into view when it changes (ui.strip_reveal);
//   * a press selects (Chrome selects on the press, so a drag starts from the current tab); a middle click closes; a
//     drag along the strip reorders, the other tabs sliding out of the way; right click: the tab's menu;
//   * "+" right after the last tab.
// The loading indicator turns only while the tab loads (spinner_wake: one timed wake per turn); nothing animates at
// rest, so an idle browser draws no frame.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import i18n "toolkit:i18n"

// A window's row (or sidebar) of tabs from frame to frame (Window_Own.strip).
Tab_Strip :: struct {
	follow_id:    u64,    // the current tab last seen (a new one is brought into view, and the tabs around it built)
	follow_n:     int,
	dragged:      u64,          // the tab dragged now (0: none): its box holds the press, which is the drag's (strip_dragged)
	drag_grab:    f32,          // where the pointer took it, from its leading edge (drag_probe_note)
	area_key:     ui.Key,       // the box holding the tabs (their keys derive from it): the row's strip view, the sidebar's list
}

// The id string of the box of tab `id`, "###tab_<id>", written in `buf` (the caller's: valid while it is). Made for every tab
// at every frame, so with no formatting and no allocation.
tab_box_id :: proc(buf: ^[32]u8, id: u64) -> string {
	return id_with_prefix(buf, "###tab_", id)
}

@(private = "file")
id_with_prefix :: proc(buf: ^[32]u8, prefix: string, id: u64) -> string {
	copy(buf[:], prefix)
	digits := strconv.write_uint(buf[len(prefix):], id, 10)
	return string(buf[:len(prefix) + len(digits)])
}

// The key of the box of tab `id` built under the box `parent`: a tab's press is held on it, and so is its drag (ui/reorder.odin).
tab_box_key :: proc(parent: ui.Key, id: u64) -> ui.Key {
	buf: [32]u8
	return ui.key_from_string(parent, tab_box_id(&buf, id))
}

// The tab whose box a press drags, in the strip, the sidebar's list or its pinned tabs (0: none); asked at the start of a build.
strip_dragged :: proc(wnd: ^Browser_Window) -> u64 {
	a := ui.active_key()
	if a == 0 || !ui.reorder_dragging(a) { return 0 }
	for t in wnd.tabs {
		if a == tab_box_key(wnd.own.strip.area_key, t.id) || (wnd.own.sidebar.pins_key != 0 && a == tab_box_key(wnd.own.sidebar.pins_key, t.id)) { return t.id }
	}
	return 0
}

// A tab dragged from the box `from` into the box `to` (into the pinned tabs, or out of them) is built under another parent: its press,
// and the drag with it, go on on its new box. Before that box is built.
tab_press_follows :: proc(wnd: ^Browser_Window, from, to: ui.Key) {
	a := ui.active_key()
	if a == 0 || from == 0 || to == 0 { return }
	for t in wnd.tabs {
		if a == tab_box_key(from, t.id) { _ = ui.press_hand(a, tab_box_key(to, t.id)); return }
	}
}

// The tab that has the keyboard, -1 when none (by key: works before the strip is built).
focused_tab_index :: proc(app: ^App) -> int {
	k := ui.focus_key()
	own := window_own(app)
	if k == 0 || own.strip.area_key == 0 { return -1 }
	for t, i in active_window(app).tabs {
		if tab_box_key(own.strip.area_key, t.id) == k { return i }
	}
	return -1
}

////////////////////////////////
// Geometry: the toolkit's list of items reordered by dragging (ui/reorder.odin), under the names the shell and its
// tests use (tab_strip_test.odin)

tab_width :: ui.reorder_item_size        // each tab's width: an equal share between the minimum and the maximum
strip_offset :: ui.reorder_offset        // the scroll, in range, following the current tab when it changes (the sidebar's tests)
drag_slot :: ui.reorder_slot             // the slot a dragged tab's middle is over
list_move :: ui.list_move
strip_visible_tabs :: ui.reorder_visible // which tabs show, two on either side: only those are built

////////////////////////////////
// Loading state

// The tab is loading: its document, its modules, or what delays its load event (stylesheets, images, fonts, scripts);
// not after Escape stopped it.
tab_busy :: proc(t: ^Tab) -> bool {
	if t == nil || t.kind != .Web { return false }
	if t.load != nil && t.load.stopped { return false }
	if tab_loading(t) { return true }   // first_paint.odin: no paint yet
	if t.load != nil {
		if t.load.task != base.NIL_HANDLE { return true }
		for s in t.load.slots { if s.state == .Pending { return true } }
	}
	if p := t.page; p != nil && t.load != nil && p.scripts != nil && p.scripts.phase != .Not_Started && p.scripts.phase != .Complete { return true }
	return false
}

// The loading indicator still turns (browser.tabs.spinner_max_s after the navigation started, it stands still).
spinner_turning :: proc(app: ^App, t: ^Tab) -> bool {
	if app.favs.cfg.spinner_max_ms <= 0 { return true }
	return shell_elapsed_ms(t.nav_state.started) < app.favs.cfg.spinner_max_ms
}

////////////////////////////////
// Building

// The row of tabs. It is built whole: what changes the list of tabs waits for the next frame (shell_after_build).
tab_strip :: proc(app: ^App, integrated: bool) {
	wnd := active_window(app)
	own := &wnd.own
	em := ui.font_size()
	dpi := ui_scale_of(app)
	h := ui.dense(em * 2.6)
	if integrated { h = max(h, math.round(32 * dpi)) }   // never lower than the system's title bar
	own.strip.dragged = strip_dragged(active_window(app))
	favicon_frame(app)

	classic := classic_on(app)
	cg: Classic_Geom
	cc: ^Classic_Colors
	if classic {
		cg = classic_geom(em, dpi, h, app.chrome_cfg.slope_deg)
		cc = classic_colors_frame(app)
	}

	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	bar := ui.build_box(integrated ? {.Window_Caption} : {}, "###tabstrip")
	if classic { bar.custom, bar.custom_user = strip_bar_draw, cc }
	if !classic && !machined_on(app) {
		fill := ui.frame_new(draw.Color)
		fill^ = modern_strip_colors().strip
		bar.custom, bar.custom_user = modern_strip_draw, fill
	}
	if ui.parent(bar) {
		lead: f32
		if integrated {
			ui.spacer(ui.px(math.round(10 * dpi)))
			app_icon(app, math.round(16 * dpi))
			ui.spacer(ui.px(math.round(6 * dpi)))
			lead = math.round(32 * dpi)
		} else {
			lead = math.round(em * 0.4)
			ui.spacer(ui.px(lead))
		}
		// the tabs take what is left once the new-tab button, the window buttons and a free strip to drag the window
		// are counted
		new_w := math.round(em * 2.4)
		buttons := integrated ? 3 * math.round(ui.CAPTION_BUTTON_WIDTH * dpi) : 0
		// classic: each tab is `overlap` wider than its pitch (it covers the next one's left foot) and the strip keeps the
		// room of the feet's flare at both ends
		extra := classic ? cg.d.ext * 2 : 0
		// classic: the new-tab button is placed as a tab is, its left foot under the last tab's right one (`plus_pull`), not after a gap
		plus_w := new_w + extra * 0.5
		plus_pull: f32
		if classic { _, _, _, plus_pull = classic_plus_metrics(&cg, em, dpi, plus_w) }
		plus_room := classic ? plus_w - plus_pull : new_w + em * 0.3
		fixed := lead + plus_room + buttons + (integrated ? app.wchrome.cfg.min_drag_em * em : em * 0.4) + extra
		avail := max(f32(active_window(app).win.size.x) - fixed, em * 4)
		n := len(wnd.tabs)
		// (rounded down: tabs that share the room exactly must not overflow it by a pixel, which would show the strip's arrows)
		w := math.floor(tab_width(avail - cg.overlap, n, app.favs.cfg.min_w_em * em, app.favs.cfg.max_w_em * em))
		run := f32(n) * w + cg.overlap   // the tabs' length, flares apart
		if classic && run > avail + 0.5 {
			// the tabs scroll: the new-tab button stands clear of the strip's end arrow instead of reaching back under the
			// last tab (decided from these sizes, not the last layout: the strip's width depends on it)
			avail = max(avail - plus_pull, em * 4)
			plus_pull = 0
		}
		// a width of its own: the strip never takes the free part of the bar that drags the window
		strip_w := min(run, avail) + extra
		add: ui.Signal
		move_from, move_to := -1, -1
		// The tabs stand clear of the window's top edge: flush with it, they left no room to grab the window above them.
		// Modern: they sit on the row's bottom, the current one joined to the toolbar under it (a column: the room above,
		// then the strip). Machined: its pills, centred in a lower strip. Classic keeps the whole height, which its feet's
		// geometry is drawn from.
		switch {
		case classic:
			ui.next({width = ui.px(strip_w), height = ui.pct(1)})
			if ui.strip("###tabs_strip") { strip_tabs(app, ui.parent_box(), strip_w, w, cg.overlap + extra, &move_from, &move_to, &cg, cc) }
		case machined_on(app):
			ui.next({width = ui.px(strip_w), height = ui.px(h - math.round(em * 0.9))})
			if ui.strip("###tabs_strip") { strip_tabs(app, ui.parent_box(), strip_w, w, cg.overlap + extra, &move_from, &move_to, &cg, cc) }
		case:
			ui.next({width = ui.px(strip_w), height = ui.pct(1), axis = .Y})
			if ui.parent(ui.build_box({}, "###tabs_column")) {
				ui.spacer(ui.px(math.round(em * TAB_TOP_ROOM_EM)))
				ui.next({width = ui.px(strip_w), height = ui.fill()})
				if ui.strip("###tabs_strip") { strip_tabs(app, ui.parent_box(), strip_w, w, cg.overlap + extra, &move_from, &move_to, &cg, cc) }
			}
		}
		if move_from >= 0 {
			// pinned tabs stay among themselves; a tab takes the group of the one whose place it takes (tab_groups.odin)
			np := pinned_count(wnd.tabs[:])
			mt := wnd.tabs[move_from]
			move_to = mt.pinned ? clamp(move_to, 0, np - 1) : clamp(move_to, np, len(wnd.tabs) - 1)
			if move_to != move_from {
				if !mt.pinned { mt.group = wnd.tabs[move_to].group }
				tree_detach(wnd.tabs[:], mt)   // tab_tree.odin: moved by hand, out of its tree
				wnd.current = list_move(wnd.tabs[:], move_from, move_to, wnd.current)
				tabs_fix(app, wnd)
				own.strip.follow_id = wnd.tabs[wnd.current].id   // no jump of the scroll while dragging
				request_frames(app, 2)
			}
		}
		tab_sound_frame(app)   // tab_sound.odin
		any_turning := false
		icon_px := tab_icon_px(app)
		for t in wnd.tabs {
			tab_refresh(app, t, icon_px)
			any_turning ||= tab_busy(t) && spinner_turning(app, t)
			// (an icon not drawn this frame is still in use: favicon_evict keeps what the tabs show)
		}
		if any_turning { spinner_wake(app) }

		// "+" right after the strip: after the last tab while they fit, at the strip's end when they scroll
		if classic {
			// placed as a tab is, its left foot reaching back under the last tab's right one (`plus_pull`): its room holds
			// what is right of the strip, the button starts before it
			ui.next({width = ui.px(plus_w - plus_pull), height = ui.pct(1)})
			room := ui.build_box({}, "###newtab_room")
			if ui.parent(room) { add = classic_new_tab_button(app, &cg, cc, h, plus_w, -plus_pull) }
		} else {
			ui.spacer(ui.px(em * 0.3))
			ui.next({width = ui.px(new_w), height = ui.px(ui.dense(em * 2.2)), radius = em * CHROME_BUTTON_RADIUS})
			add = ui.button("###newtab", icon = lucide.PLUS)
		}
		tip(add, i18n.tr("New tab (Ctrl+T)"))
		if add.clicked { tab_open_new(app) }
		ui.spacer(ui.fill())   // drags the window
		if integrated { _, _ = ui.window_buttons() }
	}
}

// The tabs in the strip's view (`view`), which scrolls them: positions are along the content, the view's offset is
// the toolkit's. `view_w`: the strip's width (this build's: the view's own is the last layout's); `w`: a tab's pitch; `tail`: what the last tab takes past its pitch (classic: its overlap and the feet's
// flare at both ends).
//
// Each tab is two boxes. Its slot is in the layout: an empty box, its pitch long, which gives the strip its length and
// is a choice of the strip (its arrows step slot by slot, ui.strip_reveal shows the current tab's slot). The tab itself
// floats over its slot (fixed_x): it slides when the tabs are reordered and follows the pointer when dragged, and it is
// built in the order of drawing (the dragged one last), which the layout's order could not give.
@(private = "file")
strip_tabs :: proc(app: ^App, view: ^ui.Box, view_w, w, tail: f32, move_from, move_to: ^int, cg: ^Classic_Geom, cc: ^Classic_Colors) {
	wnd := active_window(app)
	own := &wnd.own
	n := len(wnd.tabs)
	classic := cc != nil
	tab_list_a11y(view, false)
	own.strip.area_key = view.key
	if classic { view.custom, view.custom_user = tabs_shown_draw, nil }
	off := view.view_off.x
	if app.active != nil { app.active.zone = {rect = view.rect, offset = off, pitch = w, n = n, valid = true} }
	cur_id := wnd.tabs[wnd.current].id
	follow := cur_id != own.strip.follow_id || n != own.strip.follow_n
	own.strip.follow_id, own.strip.follow_n = cur_id, n

	// Only the tabs in view and two on either side are built (with 1000 tabs a frame built them all: 11 ms of CPU, 30 at
	// the 95th percentile), and those that must be: the current one, the one dragged, the one that has the keyboard. In
	// view: between the offset and where a glide of the wheel heads; and around a new current tab, which the strip
	// brings into view after this layout.
	vw := max(view_w, w)
	first, _ := strip_visible_tabs(min(off, view.view_target.x), vw, w, n, 2)
	_, last := strip_visible_tabs(max(off, view.view_target.x), vw, w, n, 2)
	page := int(vw / max(w, 1)) + 2

	// the slots: one each for a page more on either side, so that an arrow's step finds the next tab; the others, far
	// away, are runs of empty room (a choice as long as a run would make the strip's step skip it)
	room: f32
	id_buf: [32]u8
	for t, i in wnd.tabs {
		pitch := i == n - 1 ? w + tail : w
		if !(i >= first - page && i < last + page) && !index_near(i, wnd.current, page) { room += pitch; continue }
		if room > 0 { ui.spacer(ui.px(room)); room = 0 }
		ui.next({width = ui.px(pitch), height = ui.pct(1)})
		ui.a11y({ignore = true})   // (the tab is what a screen reader reads)
		slot := ui.build_box({.Clickable}, id_with_prefix(&id_buf, "###slot_", t.id))   // (by the tab's id: reordering is no new choice to reveal)
		if i == wnd.current { ui.strip_reveal(slot) }
		if ui.signal(slot).right_clicked { bookmarks_bar_menu(app, ui.mouse_pos()) }   // (where no tab is, between two that slide: bookmarks_bar.odin)
	}
	if room > 0 { ui.spacer(ui.px(room)) }

	// the dragged tab is built last: it draws over the others (classic: the current one just before it, as it is the one
	// in front of the others, and the clicks go to what is drawn on top)
	dragged := -1
	for t, i in wnd.tabs {
		if t.id == own.strip.dragged { dragged = i; break }
	}
	focused := focused_tab_index(app)
	built :: proc(i, first, last, current, dragged, focused, page: int, follow: bool) -> bool {
		return (i >= first && i < last) || i == current || i == dragged || i == focused || (follow && index_near(i, current, page))
	}
	if classic {
		order := make([dynamic]int, 0, n, context.temp_allocator)
		tab_stack_order(n, wnd.current, dragged, &order)
		for i in order {
			if !built(i, first, last, wnd.current, dragged, focused, page, follow) { continue }
			tab_box(app, i, w, view, move_from, move_to, cg, cc)
		}
	} else {
		for _, i in wnd.tabs {
			if i == dragged || !built(i, first, last, wnd.current, dragged, focused, page, follow) { continue }
			tab_box(app, i, w, view, move_from, move_to, cg, cc)
		}
		if dragged >= 0 { tab_box(app, dragged, w, view, move_from, move_to, cg, cc) }
	}
	if app.active != nil && app.active.dropping { drop_ghost(app, view, false, app.active.drop.mark, w, 0, 0) }   // a tab carried over this bar (tab_drag.odin)
}

// Index `i` is within `k` of index `at`.
@(private = "file")
index_near :: proc(i, at, k: int) -> bool { return i >= at - k && i <= at + k }

// The part of the strip's view where the tabs show in full, past the arrows and the fades that the strip set after the
// layout (classic: the current tab meets the toolbar only there, Cur_Gap). Drawn before the tabs.
@(private = "file")
tabs_shown_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	the_app.cur_gap.has_view = true
	the_app.cur_gap.view_x0 = b.rect.min.x + b.edge_hold[0] + b.edge_fade[0]
	the_app.cur_gap.view_x1 = b.rect.max.x - b.edge_hold[2] - b.edge_fade[2]
}

// Where the tabs of the strip's view are not under its arrows (the last layout's): a tab is lit by the pointer only there.
@(private = "file")
strip_clear_rect :: proc(view: ^ui.Box) -> draw.Rect {
	r := view.rect
	r.min.x += view.edge_hold[0]
	r.max.x -= view.edge_hold[2]
	return r
}

@(private = "file")
// The room above the modern tabs, where the window is grabbed (em).
TAB_TOP_ROOM_EM :: 0.5
// How far the row of modern tabs goes from the toolbar's colour: darker on a light theme, lighter on a dark one.
@(private = "file") STRIP_STEP :: 0.075
// How far a hovered tab goes from the row toward the toolbar's colour.
@(private = "file") TAB_HOVER_STEP :: 0.5

// The modern tabs' colours, Chrome's way: the current tab is the toolbar's colour and joins it; the row behind the
// others is a step away from it (an accent underline before read as a stray line).
Modern_Strip :: struct {
	strip, face: draw.Color,   // the row; the current tab (the toolbar's, the window's background)
}

modern_strip_colors :: proc() -> Modern_Strip {
	face := ui.color("background")
	face.a = 1
	toward := ui.current_state().theme.dark ? draw.Color{1, 1, 1, 1} : draw.Color{0, 0, 0, 1}
	return {strip = draw.mix(face, toward, STRIP_STEP), face = face}
}

@(private = "file")
modern_strip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	draw.rect(dc, b.rect, (^draw.Color)(user)^)
}

Tab_Look :: struct {
	selected:  f32,          // 0..1, animated
	accent:    draw.Color,
	divider:   draw.Color,
	hover:     draw.Color,
	strip:     draw.Color,   // modern: the row behind the tabs
	face:      draw.Color,   // modern: the current tab's (the toolbar's); machined: its face
	hover_t:   f32,          // modern: 0..1, the pointer over it (animated)
	hot:       bool,
	divide:    bool,         // a divider on its right (between two tabs that are neither selected nor hovered)
	group:     draw.Color,   // its group's colour, a line along its top (a = 0: in no group)
	machined:  bool,         // the machined style: the current tab a bevelled part, grooves between tabs
	hot_t:     f32,          // machined: 0..1, the pointer over it (animated)
}

// One tab. Positions are the slot's, animated when tabs move; a dragged tab follows the pointer.
@(private = "file")
tab_box :: proc(app: ^App, i: int, w: f32, area: ^ui.Box, move_from, move_to: ^int, cg: ^Classic_Geom, cc: ^Classic_Colors) {
	wnd := active_window(app)
	own := &wnd.own
	classic := cc != nil
	t := wnd.tabs[i]
	n := len(wnd.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == wnd.current
	id_buf: [32]u8
	id := tab_box_id(&id_buf, t.id)
	// (positions along the strip's content: the view's layout moves them by its offset)
	off := area.view_off.x
	slot := f32(i) * w
	if app.active != nil && app.active.dropping && i >= app.active.drop.index { slot += w }   // room for the tab carried over this bar (tab_drag.odin)
	// (the release slides from where the pointer left it)
	x, dragging := ui.reorder_item_pos(tab_box_key(own.strip.area_key, t.id), slot, ui.mouse_pos().x - area.rect.min.x + off, 0, f32(n - 1) * w)
	if dragging { drag_probe_note(app, ui.mouse_pos().x, x - off + area.rect.min.x + own.strip.drag_grab) }
	prev := ui.prev_box(id)
	inside := prev != nil && ui.box_contains(prev, ui.mouse_pos()) && draw.rect_contains(strip_clear_rect(area), ui.mouse_pos())

	if !on { ui.push_tags("weak") }
	defer if !on { ui.pop_tags() }
	b: ^ui.Box
	paint: ^Classic_Tab
	if classic {
		// the box holds the whole trapezoid and the flare of its feet; its hit shape is the trapezoid (slant)
		m := cg.m
		m.w = w + cg.overlap
		d := tab_dims(m)
		ui.next({fixed_x = x, fixed_y = cg.margin, width = ui.px(d.box_w), height = ui.px(cg.h), axis = .X, cross = .Center})
		ui.push_tags("tab")
		b = ui.build_box({.Clickable, .Focusable, .Middle_Click, .Hot_Within}, id)
		ui.pop_tags()
		b.slant = tab_slant(d)
		paint = ui.frame_new(Classic_Tab)
		paint.m, paint.c, paint.box, paint.dragging = m, cc, b, dragging
		paint.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, CHROME_ANIM_SELECT_RATE)
		paint.hover = ui.anim(ui.key_from_string(b.key, "hov"), inside && !on ? 1 : 0, CHROME_ANIM_HOVER_RATE)
		idle_top, idle_bot := ui.srgb_step(cc.idle_top, cc.hot_top, paint.hover), ui.srgb_step(cc.idle_bot, cc.hot_bot, paint.hover)
		paint.top = ui.srgb_step(idle_top, cc.lit_top, paint.selected)
		paint.bot = ui.srgb_step(idle_bot, cc.lit_mid, paint.selected)
		b.custom, b.custom_user = classic_tab_draw, paint
	} else {
		ui.next({fixed_x = x, fixed_y = 0, width = ui.px(w), height = ui.pct(1), axis = .X, cross = .Center, radius = em * 0.45})
		// lit under the pointer, also while it is on the tab's close button (machined: by the toolkit's hot effects; the
		// other finishes: tab_look_draw's own patch, which the toolkit's fill would cover)
		ui.push_tags("tab")
		flags := ui.Box_Flags{.Clickable, .Focusable, .Middle_Click, .Hot_Within, .Clip}
		if machined_on(app) { flags += {.Draw_Hot_Effects} }
		b = ui.build_box(flags, id)
		ui.pop_tags()
		look := ui.frame_new(Tab_Look)
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, CHROME_ANIM_SELECT_RATE)
		look.accent = ui.color("accent")
		look.divider = ui.color("border")
		look.hot = inside
		next_on := i + 1 == wnd.current
		look.divide = !on && !next_on && !inside && i + 1 < n && !dragging
		if gi := group_index(wnd.groups[:], t.group); gi >= 0 { look.group = group_color(wnd.groups[gi].color) }
		if machined_on(app) {
			look.machined, look.face = true, ui.color("button background")
			look.hot_t = ui.anim(ui.key_from_string(b.key, "mhot"), inside ? 1 : 0, CHROME_ANIM_HOVER_RATE)
		} else {
			mc := modern_strip_colors()
			look.strip, look.face = mc.strip, mc.face
			look.hover_t = ui.anim(ui.key_from_string(b.key, "hov"), inside && !on ? 1 : 0, CHROME_ANIM_HOVER_RATE)
		}
		b.custom, b.custom_user = tab_look_draw, look
	}
	b.cursor = .Arrow
	tab_a11y(b, t, i, n, on)
	closed := false
	if ui.parent(b) {
		// classic: the content stays clear of the sloped sides (half the lean is at the middle of the tab's height)
		side: f32
		if classic {
			// (the current tab, drawn on top, covers the left foot and the slope of the tab on its right by `overlap`: the icon starts clear
			// of it, as the end of the title stops before the next tab's slope, below)
			d := tab_dims(paint.m)
			side = d.ext + max(cg.overlap - d.run * 0.5, d.run * 0.5)
		}
		pad := classic ? side + math.round(em * 0.35) : math.round(em * 0.65)
		isz := f32(tab_icon_px(app))
		if t.pinned { pad = max(math.round((w - isz) * 0.5), pad) }   // a pinned tab: its icon alone, in the middle (tab_groups.odin)
		ui.spacer(ui.px(pad))
		ui.next({width = ui.px(isz), height = ui.pct(1)})
		ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
		speaker := tab_speaker(app, t)
		if t.pinned { tab_speaker_badge(speaker, {pad + isz * 0.45, math.round((b.size.y - isz) * 0.5 + isz * 0.45)}, math.round(isz * 0.8), "###speaker_badge") }
		ui.spacer(ui.px(math.round(em * 0.5)))
		title := t.pinned ? "" : t.title
		if strings.contains(title, "###") { title, _ = strings.replace_all(title, "###", "# # #", context.temp_allocator) }
		if classic {
			// the title is cut by its box (clip) and fades out into the tab's gradient instead of ending in dots
			ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
			tb := ui.build_box({.Clip}, "###titlebox")
			if ui.parent(tb) {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.a11y({ignore = true})   // (the tab's name)
				lb := ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
				fade := ui.frame_new(Title_Fade)
				fade^ = {tab = paint, width = em * 1.7}
				lb.custom, lb.custom_user = title_fade_draw, fade
			}
		} else {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.a11y({ignore = true})   // (the tab's name)
			ui.build_box({.Draw_Text}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
		}
		if speaker != .None && !t.pinned {
			if ui.tab_stops(false) { _ = tab_speaker_button(app, t, speaker, math.round(em * 1.45), "###speaker") }
		}
		show_close := !t.pinned && (on || inside || w >= app.favs.cfg.close_min_em * em)
		if show_close {
			cs := math.round(em * 1.45)
			if ui.tab_stops(false) {
				// a thin cross (the icon font's is a heavy one), round hover like Chrome's
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
		// (classic: the next tab covers this one's right foot: the content stops before its slope)
		ui.spacer(ui.px(classic ? tab_dims(paint.m).ext + max(cg.overlap - tab_dims(paint.m).run * 0.5, tab_dims(paint.m).run * 0.5) + math.round(em * 0.2) : math.round(em * 0.35)))
	}
	if closed { shell_after_build(app, {kind = .Close_Tab, tab = t.id, flag = true}); return }
	sig := ui.signal(b)
	if (sig.pressed || sig.clicked) && !on { tab_select(app, i) }   // the press selects; Enter / Space too
	if sig.right_clicked { tab_context_menu(app, i, ui.mouse_pos()) }
	if sig.middle_clicked && app.favs.cfg.middle_close { shell_after_build(app, {kind = .Close_Tab, tab = t.id, flag = true}); return }
	if !(classic && own.strip.dragged != 0) { tip(sig, t.title) }   // (classic: the title's tip does not cover the tab being dragged)
	// drag to reorder (straight down starts a drag too: it may leave the bar)
	if sig.dragging && app.favs.cfg.drag_reorder && (n > 1 || app.favs.cfg.drag_detach) {
		press := ui.mouse_pos().x - sig.drag_delta.x - area.rect.min.x + off
		if ui.reorder_begin(b.key, ui.reorder_moved(sig.drag_delta, .X, app.favs.cfg.drag_detach), app.favs.cfg.drag_threshold * dpi, press, slot) {
			own.strip.drag_grab = press - slot
		}
		if ui.reorder_dragging(b.key) {
			to := drag_slot(x, w, n)
			if to != i { move_from^, move_to^ = i, to }
			// held past an edge of the strip, the tab scrolls it that way
			area.view_target.x = ui.reorder_edge_scroll(x, w, off, area.size.x, ui.view_limit(area, .X), area.view_target.x)
			request_frames(app, 2)
			// far enough below (or above) the row: the tab leaves for a window of its own (tab_drag.odin)
			if app.favs.cfg.drag_detach && detach_wanted(area.rect, ui.mouse_pos(), false, app.favs.cfg.detach_distance_em * em) {
				shell_after_build(app, {kind = .Tear_Off, tab = t.id, at = ui.mouse_pos()})   // (its box goes, and the press with it)
			}
		}
	}
}

close_cross_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	col := (^draw.Color)(user)^
	c := draw.rect_center(b.rect)
	arm := (b.rect.max.x - b.rect.min.x) * 0.22
	th := max(math.round(1.25 * ui.scale()), 1)
	for angle in ([2]f32{math.PI / 4, -math.PI / 4}) {
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(angle), c))
		draw.rect(dc, {{c.x - arm, c.y - th * 0.5}, {c.x + arm, c.y + th * 0.5}}, col, th * 0.5)
		draw.pop_transform(dc)
	}
}

@(private = "file")
tab_look_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Tab_Look)(user)
	r := b.rect
	if l.machined {
		// the current tab a bevelled part (rising under the pointer), a groove between two others
		if l.divide {
			inset := (r.max.y - r.min.y) * 0.28
			ui.machined_groove(dc, {r.max.x, r.min.y + inset}, {r.max.x, r.max.y - inset}, vertical = true)
		}
		if l.selected > 0.01 {
			pad := max(math.round(2 * ui.scale()), 1)
			face := l.face
			face.a *= l.selected
			ui.machined_bevel(dc, draw.rect_pad(r, -pad), b.radius, face, l.hot_t, 0)
		}
		if l.group.a > 0 {
			gh := max(math.round(2 * ui.scale()), 2)
			draw.rect(dc, {{r.min.x + b.radius * 0.5, r.min.y + gh}, {r.max.x - b.radius * 0.5, r.min.y + gh * 2}}, l.group, gh * 0.5)
		}
		return
	}
	// Chrome's shape: the current tab rises from the toolbar (its colour, round top corners, square at the bottom, with a
	// concave curve on each side of its foot); a hovered one is a softer patch; a thin line parts two others. The foot's
	// curves are drawn inside the box (it clips): the shape is inset by its radius on each side.
	rad := b.radius
	if l.divide {
		lw := max(math.round(ui.scale()), 1)
		inset := (r.max.y - r.min.y) * 0.28
		draw.rect(dc, {{r.max.x - lw, r.min.y + inset}, {r.max.x, r.max.y - inset}}, l.divider)
	}
	if l.hover_t > 0.01 {
		patch := draw.mix(l.strip, l.face, TAB_HOVER_STEP)
		patch.a *= l.hover_t
		gap := max(math.round(3 * ui.scale()), 2)
		draw.rect(dc, {{r.min.x + rad, r.min.y}, {r.max.x - rad, r.max.y - gap}}, patch, rad)
	}
	if l.selected > 0.01 {
		face := l.face
		face.a *= l.selected
		body := draw.Rect{{r.min.x + rad, r.min.y}, {r.max.x - rad, r.max.y}}
		draw.rect_corners(dc, body, {face, face, face, face}, {rad, 0, rad, 0})
		// the foot: a square of the tab's colour on each side, its outer corner carved by a circle of the row's colour
		for side in ([2]f32{-1, 1}) {
			x := side < 0 ? body.min.x : body.max.x
			foot := side < 0 ? draw.Rect{{x - rad, r.max.y - rad}, {x, r.max.y}} : draw.Rect{{x, r.max.y - rad}, {x + rad, r.max.y}}
			draw.rect(dc, foot, face)
			c := draw.Vec2{x + side * rad, r.max.y - rad}
			cut := l.strip
			cut.a = l.selected
			draw.rect(dc, {c - rad, c + rad}, cut, rad)
		}
	}
	if l.group.a > 0 {
		gh := max(math.round(2 * ui.scale()), 2)
		draw.rect(dc, {{r.min.x + rad * 1.5, r.min.y + gh}, {r.max.x - rad * 1.5, r.min.y + gh * 2}}, l.group, gh * 0.5)
	}
}

////////////////////////////////
// The icon of a tab

@(private = "file")
Icon_Kind :: enum u8 { Globe, App, File, Gear, Favicon, Spinner, Waiting }

@(private = "file")
Tab_Icon_Draw :: struct {
	kind:   Icon_Kind,
	tex:    render.Texture,
	color:  draw.Color,
	phase:  f32,           // spinner: turns (0..1)
	size:   f32,
}

tab_icon_of :: proc(app: ^App, t: ^Tab, size: f32) -> ^Tab_Icon_Draw {
	d := ui.frame_new(Tab_Icon_Draw)
	d.size = size
	d.color = ui.color("text")
	if tab_busy(t) {
		// the response has not come: a slower, muted turn (Chrome's "waiting"); then the accent one
		waiting := t.page == nil
		d.kind = waiting ? .Waiting : .Spinner
		if !waiting { d.color = ui.color("accent") }
		ms := shell_elapsed_ms(t.nav_state.started)
		period: f64 = waiting ? 1600 : 900
		d.phase = spinner_turning(app, t) ? f32(math.mod(ms, period) / period) : 0
		return d
	}
	switch {
	case t.kind == .Config || t.kind == .Settings || t.kind == .Blocker || t.kind == .Downloads || t.kind == .Bookmarks: d.kind = .Gear
	case t.load != nil && t.load.failed != .None: d.kind = .Globe   // an error page is not the browser's own page
	case t.page != nil && t.page.env.location.scheme == "about": d.kind = app.wchrome.icon_px > 0 ? .App : .Globe; d.tex = app.wchrome.icon
	case t.page != nil && t.page.env.location.scheme == "file": d.kind = .File
	case t.icon.url != "":
		if tex, ok := favicon_texture(app, t.icon.url); ok { d.kind, d.tex = .Favicon, tex }
	}
	return d
}

// The font size that fits a glyph whose ink is `ink` at size `s` into an `s` square (the size itself when it fits).
icon_glyph_fit :: proc(s: f32, ink: [2]f32) -> f32 {
	big := max(ink.x, ink.y)
	return big > s ? s * s / big : s
}

tab_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tab_Icon_Draw)(user)
	app := the_app
	c := draw.rect_center(b.rect)
	s := d.size
	r := draw.Rect{{math.round(c.x - s * 0.5), math.round(c.y - s * 0.5)}, {}}
	r.max = r.min + {s, s}
	switch d.kind {
	case .Favicon, .App:
		draw.image(dc, d.tex, r)
	case .File, .Gear:
		// the glyph's ink centred in the icon's square and no larger than it (the icon font's document is taller than its em:
		// at the size of the square it overflowed the row) (the pen is on the baseline: chrome.odin chip_icon_draw)
		glyph := d.kind == .File ? lucide.FILE : lucide.SETTINGS
		size := icon_glyph_fit(s, font.glyph(&app.fonts, app.lucide, s, icon_rune(glyph)).size)
		g := font.glyph(&app.fonts, app.lucide, size, icon_rune(glyph))
		w := g.size.x > 0 ? g.size.x : g.advance
		pen := draw.Vec2{math.round(c.x - w * 0.5 - g.offset.x), math.round(c.y - (g.offset.y + g.size.y * 0.5))}
		draw.text(dc, app.lucide, size, pen, d.color, glyph)
	case .Globe:
		// a neutral globe: a ring, the equator and a meridian
		lw := max(s * 0.09, 1)
		col := d.color
		col.a *= 0.75
		draw.rect(dc, draw.rect_pad(r, -s * 0.06), col, s * 0.5, lw)
		draw.rect(dc, {{r.min.x + s * 0.1, c.y - lw * 0.5}, {r.max.x - s * 0.1, c.y + lw * 0.5}}, col)
		draw.rect(dc, {{c.x - s * 0.2, r.min.y + s * 0.06}, {c.x + s * 0.2, r.max.y - s * 0.06}}, col, s * 0.2, lw)
	case .Spinner, .Waiting:
		// an arc of three quarters turning; drawn as overlapping dots (no arc primitive)
		th := max(s * 0.13, 1.5)
		rad := s * 0.5 - th * 0.5 - s * 0.04
		start := f64(d.phase) * math.TAU
		if d.kind == .Waiting { start = -start }   // the waiting turn goes the other way, as in Chrome
		steps := max(int(rad * 4.7 * 0.75 / max(th * 0.35, 0.5)), 12)
		for k in 0 ..= steps {
			a := start + f64(k) / f64(steps) * math.TAU * 0.75
			p := c + {f32(math.cos(a)) * rad, f32(math.sin(a)) * rad}
			draw.rect(dc, {p - th * 0.5, p + th * 0.5}, d.color, th * 0.5)
		}
	}
}
