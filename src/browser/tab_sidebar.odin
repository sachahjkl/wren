package browser

// The tabs in a sidebar, at the left or at the right of the page (browser.tabs.position = left | right), as in Edge, Firefox
// and Vivaldi. Only a way to lay the tabs out: the tabs, their order, the current one, the menus and the shortcuts are the
// row of tabs' (tab_strip.odin); changing the position takes effect at once and `top` gives the row of tabs back as it was.
//
//   * Under the title bar (the integrated one keeps its drag area and its window buttons: sidebar_title_row) and the address
//     row, a column of the sidebar and the page (build_ui); the window's own resize bands are the system's frame, outside
//     the client area, so the sidebar never covers them. Full screen shows the row of tabs over the page as ever.
//   * Each tab is one row: icon (or the loading indicator), title cut with an ellipsis, a close button on the current tab and
//     under the pointer; the current tab is lit with an accent bar. A press selects, a middle click closes, right click: the
//     tab's menu, hover: a tip beside the row with the title and the address, a drag along Y reorders (the other rows slide
//     out of the way, the order is the strip's: app.tabs).
//   * The list is a scroll box of the toolkit (wheel with the page's smooth curve, scroll bar, thumb drag) whose rows are
//     placed by their slot; only the rows in view, and a margin around it, are built, whatever the number of tabs.
//   * A header holds the collapse button (icons only, browser.tabs.sidebar_collapsed_width) and the new-tab button. The
//     inner edge is a handle that resizes the sidebar (browser.tabs.sidebar_width, written when the button goes up).
//   * The classic style is a row of trapezoids: in a sidebar the modern look is used (classic_on).
// Nothing animates at rest: the rows slide only while tabs move and the loading indicator turns only while a tab loads.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"
import "wb:i18n"

SIDEBAR_MIN_CSS :: 120   // (browser.tabs.sidebar_width's bounds)
SIDEBAR_MAX_CSS :: 640

SIDEBAR_PREFS := [?]config.Def{
	{name = "browser.tabs.position", kind = .String, default = {s = "top"}, choices = {"top", "left", "right"},
		description = i18n.tr("Where the tabs are. top: the row of tabs along the top of the window (in the title bar when it is integrated). left or right: a sidebar with one tab per row, next to the page; the classic style, made of a row of trapezoids, then gives way to the modern one. Applies at once.")},
	{name = "browser.tabs.sidebar_width", kind = .Int, default = {i = 240}, bounded = true, min = SIDEBAR_MIN_CSS, max = SIDEBAR_MAX_CSS, unit = "px",
		description = i18n.tr("Width of the tab sidebar (interface pixels, times the display scale). Drag its inner edge to change it. The sidebar never takes more than half of the window.")},
	{name = "browser.tabs.sidebar_collapsed", kind = .Bool, default = {b = false},
		description = i18n.tr("The tab sidebar shows only the icons of the tabs (the button at the top of the sidebar, or Ctrl+Shift+Comma, toggles it).")},
	{name = "browser.tabs.sidebar_collapsed_width", kind = .Int, default = {i = 48}, bounded = true, min = 32, max = 96, unit = "px",
		description = i18n.tr("Width of the tab sidebar when it shows only icons (interface pixels, times the display scale).")},
	{name = "browser.tabs.sidebar_row_em", kind = .Float, default = {f = 2.4}, bounded = true, min = 1.6, max = 5, unit = "em",
		description = i18n.tr("Height of a tab in the sidebar.")},
}

Tabs_Position :: enum u8 { Top, Left, Right }

TABS_POSITION_NAMES := [Tabs_Position]string{.Top = "top", .Left = "left", .Right = "right"}

tabs_position_of :: proc(s: string) -> Tabs_Position {
	switch s {
	case "left": return .Left
	case "right": return .Right
	}
	return .Top
}

// The tabs are in a sidebar now (not in full screen: its bars bring the row of tabs over the page).
tabs_in_sidebar :: proc(app: ^App) -> bool {
	return favs.cfg.position != .Top && !platform.is_fullscreen(app.win)
}

Tab_Sidebar :: struct {
	live_w:    f32,    // CSS px while the width handle is held (0: the preference's)
	grab_w:    f32,    // the width when the handle was pressed
	resizing:  bool,
	shown:     bool,   // built last frame (else the current tab is scrolled into view when it appears)
}

sidebar: Tab_Sidebar

////////////////////////////////
// Geometry (pure: tab_sidebar_test.odin)

// Physical width of the sidebar: icons only, or the width asked for, never below SIDEBAR_MIN_CSS nor above half of the window.
sidebar_extent :: proc(win_w, width_css, scale: f32, collapsed: bool, collapsed_css: f32) -> f32 {
	if collapsed { return math.round(min(collapsed_css * scale, win_w * 0.5)) }
	lo := SIDEBAR_MIN_CSS * scale
	return math.round(clamp(width_css * scale, lo, max(win_w * 0.5, lo)))
}

// What the window's body (below the title bar and the address row) gives the sidebar and the page: they share its width,
// the sidebar at the side `pos` says.
sidebar_split :: proc(body: draw.Rect, pos: Tabs_Position, extent: f32) -> (bar, page: draw.Rect) {
	w := body.max.x - body.min.x
	e := clamp(extent, 0, w)
	switch pos {
	case .Left:
		bar = {body.min, {body.min.x + e, body.max.y}}
		page = {{body.min.x + e, body.min.y}, body.max}
	case .Right:
		bar = {{body.max.x - e, body.min.y}, body.max}
		page = {body.min, {body.max.x - e, body.max.y}}
	case .Top:
		page = body
	}
	return
}

// The rows to build: those within `overscan` of what the view shows now (`off`, px of content above it) and of where its
// scroll is heading (`target`, followed within two views: a long glide builds only what it passes), `rh` high each.
side_visible_rows :: proc(off, target, view_h, rh: f32, n: int, overscan: f32) -> (first, last: int) {
	if n <= 0 || rh <= 0 { return 0, 0 }
	to := clamp(target, off - view_h * 2, off + view_h * 2)
	lo := min(off, to) - overscan
	hi := max(off, to) + view_h + overscan
	first = clamp(int(math.floor(lo / rh)), 0, n - 1)
	last = clamp(int(math.ceil(hi / rh)), first + 1, n)
	return
}

////////////////////////////////
// Building

// The title bar's row when the tabs are in a sidebar and the title bar is the window's own (integrated): the Wren icon,
// the free space that drags the window and the window buttons. Nothing otherwise (the system's title bar is above).
sidebar_title_row :: proc(app: ^App, integrated: bool) {
	if !integrated { return }
	em := ui.font_size()
	dpi := ui_scale_of(app)
	h := max(ui.dense(em * 2.6), math.round(32 * dpi))
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	bar := ui.build_box({.Window_Caption}, "###tabstrip")
	if ui.parent(bar) {
		ui.spacer(ui.px(math.round(10 * dpi)))
		app_icon(app, math.round(16 * dpi))
		ui.spacer(ui.fill())
		_, _ = ui.window_buttons()
	}
}

// The sidebar: header, list of tabs and, over its inner edge, the width handle. Returns true when a tab closed (the build
// stops: the tab list changed under it).
tab_sidebar :: proc(app: ^App, pos: Tabs_Position) -> (closed: bool) {
	dpi := ui_scale_of(app)
	collapsed := favs.cfg.side_collapsed
	width_css := sidebar.live_w > 0 ? sidebar.live_w : favs.cfg.side_w
	extent := sidebar_extent(f32(app.win.size.x), width_css, dpi, collapsed, favs.cfg.side_collapsed_w)
	if ui.active_key() == 0 { strip.drag_id, strip.drag_active = 0, false }   // the button went up (wherever)
	favicon_frame()

	ui.next({width = ui.px(extent), height = ui.fill(), axis = .Y})
	bar := ui.build_box({pos == .Left ? .Draw_Side_Right : .Draw_Side_Left}, "###sidebar")
	if ui.parent(bar) {
		sidebar_header(app, pos, collapsed)
		if sidebar_list(app, collapsed, extent) { return true }
	}
	if !collapsed { sidebar_handle(app, pos, bar, extent, dpi) }
	return false
}

@(private = "file")
Side_Toggle :: struct {
	color:     draw.Color,
	left:      bool,
	collapsed: bool,
}

// A window with a panel along one side: the panel is filled while the sidebar shows only icons.
@(private = "file")
side_toggle_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Side_Toggle)(user)
	c := draw.rect_center(b.rect)
	h := (b.rect.max.y - b.rect.min.y) * 0.42
	w := h * 1.3
	th := max(math.round(1.25 * ui.scale()), 1)
	frame := draw.Rect{{c.x - w * 0.5, c.y - h * 0.5}, {c.x + w * 0.5, c.y + h * 0.5}}
	draw.rect(dc, frame, d.color, h * 0.18, th)
	panel_w := w * 0.34
	px0 := d.left ? frame.min.x : frame.max.x - panel_w
	col := d.color
	col.a *= d.collapsed ? 0.9 : 0.45
	draw.rect(dc, {{px0, frame.min.y}, {px0 + panel_w, frame.max.y}}, col, h * 0.18)
}

@(private = "file")
sidebar_header :: proc(app: ^App, pos: Tabs_Position, collapsed: bool) {
	em := ui.font_size()
	bw := math.round(em * 2.4)
	bh := ui.dense(em * 2.2)
	inset := math.round(em * 0.35)

	toggle := proc(app: ^App, pos: Tabs_Position, collapsed: bool, bw, bh, em: f32) {
		ui.next({width = ui.px(bw), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
		tb: ^ui.Box
		if ui.tags("icon_button") {
			tb = ui.build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects}, "###side_toggle")
			d := ui.frame_new(Side_Toggle)
			d^ = {color = ui.color("text"), left = pos == .Left, collapsed = collapsed}
			tb.custom, tb.custom_user = side_toggle_draw, d
		}
		sig := ui.signal(tb)
		tip(sig, collapsed ? i18n.tr("Show the tab titles (Ctrl+Shift+Comma)") : i18n.tr("Show only the tab icons (Ctrl+Shift+Comma)"))
		if sig.clicked { set_pref_bool(app, "browser.tabs.sidebar_collapsed", !collapsed) }
	}
	add := proc(app: ^App, bw, em: f32) {
		ui.next({width = ui.px(bw), height = ui.px(ui.dense(em * 2.2)), radius = em * CHROME_BUTTON_RADIUS})
		sig := ui.icon_button("###newtab", GLYPH_ADD)
		tip(sig, i18n.tr("New tab (Ctrl+T)"))
		if sig.clicked { tab_open_new(app) }
	}

	if collapsed {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, cross = .Center})
		hdr := ui.build_box({}, "###side_head")
		if ui.parent(hdr) {
			ui.spacer(ui.px(inset))
			toggle(app, pos, collapsed, bw, bh, em)
			ui.spacer(ui.px(inset))
			add(app, bw, em)
			ui.spacer(ui.px(inset))
		}
		return
	}
	ui.next({width = ui.fill(), height = ui.px(bh + inset * 2), axis = .X, cross = .Center})
	hdr := ui.build_box({}, "###side_head")
	if ui.parent(hdr) {
		ui.spacer(ui.px(inset * 2))
		toggle(app, pos, collapsed, bw, bh, em)
		ui.spacer(ui.fill())
		add(app, bw, em)
		ui.spacer(ui.px(inset * 2))
	}
}

// The list of tabs: a vertical scroll box, `rh` high per tab, whose rows are floating boxes placed by slot. Returns true
// when a tab closed.
@(private = "file")
sidebar_list :: proc(app: ^App, collapsed: bool, extent: f32) -> (closed: bool) {
	em := ui.font_size()
	n := len(app.tabs)
	rh := ui.dense(math.round(em * favs.cfg.side_row_em))

	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	area := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, "###tabs_area")
	_ = ui.signal(area)   // the wheel
	strip.area_key = area.key
	if app.active != nil { app.active.zone = {rect = area.rect, vertical = true, offset = area.view_off.y, pitch = rh, n = n, valid = true} }
	view_h := area.size.y > 0 ? area.size.y : f32(app.win.size.y)
	limit := max(f32(n) * rh - view_h, 0)

	// a new current tab is scrolled into view (not while one is dragged: the list follows the pointer then)
	cur_id := app.tabs[app.current].id
	if cur_id != strip.follow_id || n != strip.follow_n || !sidebar.shown {
		area.view_target.y = strip_offset(area.view_target.y, n, rh, view_h, app.current, true)
	}
	strip.follow_id, strip.follow_n, sidebar.shown = cur_id, n, true
	area.view_target.y = clamp(area.view_target.y, 0, limit)

	inset := math.round(em * 0.35)
	bar_w := math.round(max(6, em * 0.5)) + inset   // what the scroll bar takes when the list overflows
	row_w := extent - inset * 2 - (limit > 0 ? bar_w - inset : 0) - 1
	first, last := side_visible_rows(area.view_off.y, area.view_target.y, view_h, rh, n, rh * 2)
	dragged := -1
	for t, i in app.tabs {
		if strip.drag_active && t.id == strip.drag_id { dragged = i; break }
	}
	focused := focused_tab_index(app)

	move_from, move_to := -1, -1
	if ui.parent(area) {
		ui.spacer(ui.px(f32(n) * rh), exact = true)   // the content's height: the scroll range
		for i in first ..< last {
			if i == dragged { continue }
			if sidebar_row(app, i, rh, row_w, inset, collapsed, area, limit, &move_from, &move_to) { return true }
		}
		// a row that has the keyboard stays built when it scrolls out of view
		if focused >= 0 && (focused < first || focused >= last) && focused != dragged {
			if sidebar_row(app, focused, rh, row_w, inset, collapsed, area, limit, &move_from, &move_to) { return true }
		}
		if dragged >= 0 {   // built last: it draws over the others and takes the clicks
			if sidebar_row(app, dragged, rh, row_w, inset, collapsed, area, limit, &move_from, &move_to) { return true }
		}
		if app.active != nil && app.active.drop_hint > 0 { drop_hint_mark(area, true, f32(app.active.drop_hint - 1) * rh - area.view_off.y) }   // a tab carried over this list
	}
	if move_from >= 0 {
		app.current = list_move(app.tabs[:], move_from, move_to, app.current)
		strip.follow_id = app.tabs[app.current].id   // no jump of the scroll while dragging
		app.frames_requested = max(app.frames_requested, 2)
		recovery_touch(app)
	}
	any_turning := false
	for t, i in app.tabs {
		tab_refresh(app, t, tab_icon_px(app))
		any_turning ||= tab_busy(t) && spinner_turning(t)
		// (an icon not drawn this frame is still in use: the cache keeps what its tabs show)
		if (i < first || i >= last) && t.icon.url != "" { _, _ = favicon_texture(t.icon.url) }
	}
	if any_turning { spinner_wake(app) }
	return false
}

@(private = "file")
Side_Look :: struct {
	selected: f32,   // 0..1, animated
	accent:   draw.Color,
	left:     bool,
}

// One tab's row. Its place is its slot's, animated when tabs move; a dragged row follows the pointer.
@(private = "file")
sidebar_row :: proc(app: ^App, i: int, rh, row_w, inset: f32, collapsed: bool, area: ^ui.Box, limit: f32, move_from, move_to: ^int) -> (closed: bool) {
	t := app.tabs[i]
	n := len(app.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == app.current
	id := fmt.tprintf("###tab_%d", t.id)
	slot := f32(i) * rh
	dragging := strip.drag_active && strip.drag_id == t.id
	akey := ui.key_from_string(area.key, fmt.tprintf("y%d", t.id))
	y: f32
	if dragging {
		y = clamp(ui.mouse_pos().y - area.rect.min.y + area.view_off.y - strip.drag_grab, 0, f32(n - 1) * rh)
		_ = ui.anim(akey, y, 30, y)   // the release slides from here
	} else {
		y = math.round(ui.anim(akey, slot, 30, slot))
	}
	prev := ui.prev_box(id)
	inside := prev != nil && ui.box_contains(prev, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos())

	if !on { ui.push_tags("weak") }
	defer if !on { ui.pop_tags() }
	ui.next({fixed_x = inset, fixed_y = y, width = ui.px(row_w), height = ui.px(rh), axis = .X, cross = .Center, radius = em * 0.45})
	ui.push_tags("tab")
	b := ui.build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
	ui.pop_tags()
	look := ui.frame_new(Side_Look)
	look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
	look.accent = ui.color("accent")
	look.left = favs.cfg.position == .Left
	b.custom, b.custom_user = side_row_draw, look
	b.cursor = .Arrow

	if ui.parent(b) {
		isz := f32(tab_icon_px(app))
		if collapsed {
			ui.spacer(ui.fill())
			ui.next({width = ui.px(isz), height = ui.pct(1)})
			ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
			ui.spacer(ui.fill())
		} else {
			ui.spacer(ui.px(math.round(em * 0.65)))
			ui.next({width = ui.px(isz), height = ui.pct(1)})
			ui.custom("###icon", tab_icon_draw, tab_icon_of(app, t, isz))
			ui.spacer(ui.px(math.round(em * 0.5)))
			title := t.title
			if strings.contains(title, "###") { title, _ = strings.replace_all(title, "###", "# # #", context.temp_allocator) }
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.build_box({.Draw_Text}, fmt.aprintf("%s###title", title, allocator = ui.frame_allocator()))
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
	if closed { tab_close(app, i); return true }
	sig := ui.signal(b)
	if (sig.pressed || sig.clicked) && !on { tab_select(app, i) }   // the press selects; Enter / Space too
	if sig.right_clicked { tab_context_menu(app, i, ui.mouse_pos()) }
	if sig.middle_clicked && favs.cfg.middle_close { tab_close(app, i); return true }
	if !strip.drag_active { sidebar_tip(sig, t) }

	// drag to reorder, along Y
	if sig.dragging && favs.cfg.drag_reorder && (n > 1 || favs.cfg.drag_detach) {
		if !strip.drag_active && abs(sig.drag_delta.y) > favs.cfg.drag_threshold * dpi {
			strip.drag_active, strip.drag_id = true, t.id
			press_y := ui.mouse_pos().y - sig.drag_delta.y
			strip.drag_grab = press_y - area.rect.min.y + area.view_off.y - slot   // where the pointer holds the row
		}
		if strip.drag_active && strip.drag_id == t.id {
			to := drag_slot(y, rh, n)
			if to != i { move_from^, move_to^ = i, to }
			// the list follows the pointer to its ends: a row held past the edge scrolls it
			view_h := area.size.y
			if y < area.view_off.y {
				area.view_target.y = clamp(y, 0, limit)
			} else if y + rh > area.view_off.y + view_h {
				area.view_target.y = clamp(y + rh - view_h, 0, limit)
			}
			app.frames_requested = max(app.frames_requested, 2)
			// far enough beside the list: the tab leaves for a window of its own (tab_drag.odin)
			if favs.cfg.drag_detach && detach_wanted(area.rect, ui.mouse_pos(), true, favs.cfg.detach_distance_em * em) {
				strip.drag_active = false
				if tab_drag_begin(app, t, ui.mouse_pos()) && len(app.tabs) != n { return true }
			}
		}
	}
	return false
}

// A tip beside the row: the title and, under it, the address.
@(private = "file")
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

// The current row: an accent wash and a bar on its outer edge, growing in.
@(private = "file")
side_row_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	l := (^Side_Look)(user)
	if l.selected < 0.01 { return }
	r := b.rect
	wash := l.accent
	wash.a *= 0.16 * l.selected
	draw.rect(dc, r, wash, b.radius)
	th := max(math.round(2.5 * ui.scale()), 2)
	h := (r.max.y - r.min.y) * 0.5 * l.selected
	cy := (r.min.y + r.max.y) * 0.5
	x0 := l.left ? r.min.x : r.max.x - th
	draw.rect(dc, {{x0, cy - h * 0.5}, {x0 + th, cy + h * 0.5}}, l.accent, th * 0.5)
}

// The inner edge: a strip over the sidebar's edge toward the page that resizes it. The width is kept while the button is
// held and written to the preference when it goes up.
@(private = "file")
sidebar_handle :: proc(app: ^App, pos: Tabs_Position, bar: ^ui.Box, extent, dpi: f32) {
	grab := math.round(5 * dpi)
	ui.push_parent(bar)
	defer ui.pop_parent()
	ui.next({fixed_x = pos == .Left ? extent - grab : 0, fixed_y = 0, width = ui.px(grab), height = ui.pct(1), cursor = .Resize_H})
	hb := ui.build_box({.Clickable}, "###side_handle")
	sig := ui.signal(hb)
	if sig.pressed {
		sidebar.resizing = true
		sidebar.grab_w = sidebar.live_w > 0 ? sidebar.live_w : favs.cfg.side_w
	}
	if sig.dragging && sidebar.resizing {
		dx := pos == .Left ? sig.drag_delta.x : -sig.drag_delta.x
		sidebar.live_w = clamp(math.round(sidebar.grab_w + dx / dpi), SIDEBAR_MIN_CSS, SIDEBAR_MAX_CSS)
		app.frames_requested = max(app.frames_requested, 2)
	}
	if !sig.dragging && sidebar.resizing {
		sidebar.resizing = false
		if sidebar.live_w > 0 {
			set_pref_string(app, "browser.tabs.sidebar_width", fmt.tprintf("%d", int(sidebar.live_w)))
			sidebar.live_w = 0
		}
	}
	if sig.hovering || sidebar.resizing {
		col := ui.frame_new(draw.Color)
		col^ = ui.color("accent")
		hb.custom, hb.custom_user = side_handle_draw, col
	}
}

@(private = "file")
side_handle_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	col := (^draw.Color)(user)^
	th := max(math.round(2 * ui.scale()), 2)
	x := math.round((b.rect.min.x + b.rect.max.x) * 0.5)
	col.a *= 0.8
	draw.rect(dc, {{x - th * 0.5, b.rect.min.y}, {x + th * 0.5, b.rect.max.y}}, col)
}

////////////////////////////////
// Commands (commands.odin)

// Moves the tabs to `pos`.
tabs_set_position :: proc(app: ^App, pos: Tabs_Position) {
	set_pref_string(app, "browser.tabs.position", TABS_POSITION_NAMES[pos])
}

tabs_toggle_collapsed :: proc(app: ^App) {
	set_pref_bool(app, "browser.tabs.sidebar_collapsed", !favs.cfg.side_collapsed)
}
