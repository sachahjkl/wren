package browser

// The tabs in a sidebar, at the left or at the right of the page (browser.tabs.position = left | right), as in Edge, Firefox
// and Vivaldi. Only a way to lay the tabs out: the tabs, their order, the current one, the menus and the shortcuts are the
// row of tabs' (tab_strip.odin); changing the position takes effect at once and `top` gives the row of tabs back as it was.
//
//   * The toolbar is the title bar (integrated): one row of the Wren icon, the navigation buttons, the address bar, the
//     shield, the menu and the window buttons, whose empty parts drag the window (sidebar_titlebar; a narrow window gives
//     the address bar its room by hiding the shield, then forward, then reload: titlebar_layout). With the system's title
//     bar, the toolbar is its own row under it. Below, a column of the sidebar and the page (build_ui); the window's own
//     resize bands are the system's frame, outside the client area, so the sidebar never covers them. Full screen shows
//     the row of tabs over the page as ever.
//   * Each tab is one row: icon (or the loading indicator), title cut with an ellipsis, a close button on the current tab and
//     under the pointer; the current tab is lit with an accent bar. A press selects, a middle click closes, right click: the
//     tab's menu, hover: a tip beside the row with the title and the address, a drag along Y reorders (the other rows slide
//     out of the way, the order is the strip's: the window's tabs).
//   * The list is a scroll box of the toolkit (wheel with the page's smooth curve, scroll bar, thumb drag) whose rows are
//     placed by their slot; only the rows in view, and a margin around it, are built, whatever the number of tabs.
//   * A header holds the collapse button (icons only, browser.tabs.sidebar_collapsed_width) and the new-tab button. The
//     inner edge is a handle that resizes the sidebar (browser.tabs.sidebar_width, written when the button goes up).
//   * Classic style (classic_on): the sidebar is the tab bar turned on its side, the current tab a classic tab with
//     upright sides that flows into the page's side, the others flat and engraved apart (chrome_style.odin, "The classic
//     sidebar"); the scroll bar is on the outer side.
//   * The new-tab button is the "+" glyph alone, lit under the pointer as the toolbar's buttons are, in either style.
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
		description = i18n.tr("Where the tabs are. top: the row of tabs along the top of the window (in the title bar when it is integrated). left or right: a sidebar with one tab per row, next to the page (with the classic style, browser.ui.chrome_style, the current tab is a panel that flows into the page's side). Applies at once.")},
	{name = "browser.tabs.sidebar_width", kind = .Int, default = {i = 240}, bounded = true, min = SIDEBAR_MIN_CSS, max = SIDEBAR_MAX_CSS, unit = "px",
		description = i18n.tr("Width of the tab sidebar (interface pixels, times the display scale). Drag its inner edge to change it. The sidebar never takes more than half of the window.")},
	{name = "browser.tabs.sidebar_collapsed", kind = .Bool, default = {b = false},
		description = i18n.tr("The tab sidebar shows only the icons of the tabs (the button at the top of the sidebar, or Ctrl+Shift+Comma, toggles it).")},
	{name = "browser.tabs.sidebar_collapsed_width", kind = .Int, default = {i = 48}, bounded = true, min = 32, max = 96, unit = "px",
		description = i18n.tr("Width of the tab sidebar when it shows only icons (interface pixels, times the display scale).")},
	{name = "browser.tabs.sidebar_row_em", kind = .Float, default = {f = 2.4}, bounded = true, min = 1.6, max = 5, unit = "em",
		description = i18n.tr("Height of a tab in the sidebar.")},
	{name = "browser.tabs.sidebar_address_min_em", kind = .Float, default = {f = 10}, bounded = true, min = 4, max = 40, unit = "em",
		description = i18n.tr("With the tabs in a sidebar and the integrated title bar, the address bar is in the title bar: its narrowest width there. Below it, in a narrow window, the shield, then the forward button, then the reload button make room.")},
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
	return favs.cfg.position != .Top && !platform.is_fullscreen(active_window(app).win)
}

// A window's tab sidebar from frame to frame (Window_Own.sidebar).
Tab_Sidebar :: struct {
	live_w:    f32,    // CSS px while the width handle is held (0: the preference's)
	grab_w:    f32,    // the width when the handle was pressed
	press_x:   f32,    // the pointer's x when it was pressed (window px)
	handle:    ui.Key, // the width handle's box
	resizing:  bool,
	shown:     bool,   // built last frame (else the current tab is scrolled into view when it appears)
}

////////////////////////////////
// Geometry (pure: tab_sidebar_test.odin)

// The width (CSS px) the held handle gives: the width at the press, moved by the pointer since (`pos`: the sidebar's side;
// a sidebar on the right grows toward the left).
sidebar_drag_width :: proc(grab_w, press_x, mouse_x, scale: f32, pos: Tabs_Position) -> f32 {
	dx := mouse_x - press_x
	if pos == .Right { dx = -dx }
	return clamp(math.round(grab_w + dx / max(scale, 0.01)), SIDEBAR_MIN_CSS, SIDEBAR_MAX_CSS)
}

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

////////////////////////////////
// The toolbar in the title bar
//
// With the tabs in a sidebar and an integrated title bar, the title bar would hold only the icon and the window buttons:
// the toolbar takes its place. One row, as high as the row of tabs is (the system's title bar at the least), of parts
// side by side; the parts' empty space (around the icon and the address bar, the strip before the window buttons) drags
// the window, what is clickable in them stays the browser's (ui: .Window_Caption, holes), and the window buttons are the
// system's for its hit tests (Snap Layouts).

Titlebar_Part :: enum u8 { Lead, Back, Forward, Reload, Gap_Before, Field, Chips, Gap_After, Shield, Menu, Drag, Buttons }

// Hidden in this order when the address bar would be narrower than its minimum.
TITLEBAR_HIDE_ORDER :: [?]Titlebar_Part{.Shield, .Forward, .Reload}

TITLEBAR_SLOT_IDS := [Titlebar_Part]string{
	.Lead = "###tb_lead", .Back = "###tb_back", .Forward = "###tb_forward", .Reload = "###tb_reload",
	.Gap_Before = "###tb_gap_before", .Field = "###tb_field", .Chips = "###tb_chips", .Gap_After = "###tb_gap_after",
	.Shield = "###tb_shield", .Menu = "###tb_menu", .Drag = "###tb_drag", .Buttons = "###tb_buttons",
}

Titlebar_Layout :: struct {
	shown: bit_set[Titlebar_Part],
	x, w:  [Titlebar_Part]f32,   // a hidden part: 0 wide, at the next one's place
}

// The row's parts in a window `win_w` wide (pure: tab_sidebar_test.odin). `want`: each part's width, the field's its
// minimum, the drag strip's the one it would like. The field takes what is left; when that is under its minimum, the
// drag strip gives up to `drag_min`, then the parts of TITLEBAR_HIDE_ORDER go one by one, then the field is narrower.
// The parts touch, in order, from 0 to `win_w` (while the window is wider than the parts that never go).
titlebar_layout :: proc(win_w: f32, want: [Titlebar_Part]f32, drag_min: f32) -> (l: Titlebar_Layout) {
	l.shown = ~bit_set[Titlebar_Part]{}
	l.w = want
	field_min := want[.Field]
	room := win_w
	for p in Titlebar_Part { if p != .Field { room -= want[p] } }
	if room < field_min && want[.Drag] > drag_min {
		give := min(field_min - room, want[.Drag] - drag_min)
		l.w[.Drag] -= give
		room += give
	}
	for p in TITLEBAR_HIDE_ORDER {
		if room >= field_min { break }
		if want[p] <= 0 { continue }
		l.shown -= {p}
		room += l.w[p]
		l.w[p] = 0
	}
	if room > field_min && l.w[.Drag] < want[.Drag] {   // (what a hidden part freed beyond the field's minimum)
		back := min(room - field_min, want[.Drag] - l.w[.Drag])
		l.w[.Drag] += back
		room -= back
	}
	l.w[.Field] = max(room, 0)
	x: f32
	for p in Titlebar_Part {
		l.x[p] = x
		x += l.w[p]
	}
	return
}

// The row: a caption `h` high, one box per shown part (`part` builds what is in it), each as wide as `l` says; the field
// fills what the others leave and the chips (zoom, passkey) are as wide as they are (`l` had last frame's width).
titlebar_row_build :: proc(l: Titlebar_Layout, h: f32, part: proc(p: Titlebar_Part, user: rawptr), user: rawptr) -> ^ui.Box {
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	bar := ui.build_box({.Window_Caption}, "###tabstrip")
	if ui.parent(bar) {
		for p in Titlebar_Part {
			if p not_in l.shown { continue }
			w := ui.px(l.w[p])
			#partial switch p {
			case .Field: w = ui.fill()
			case .Chips: w = ui.children_sum()
			}
			ui.next({width = w, height = ui.pct(1), axis = .X, cross = .Center})
			if ui.parent(ui.build_box({}, TITLEBAR_SLOT_IDS[p])) { part(p, user) }
		}
	}
	return bar
}

// The width of the parts of the row (physical px), and what the drag strip may shrink to.
titlebar_wants :: proc(app: ^App, chips_w: f32) -> (want: [Titlebar_Part]f32, drag_min: f32) {
	em := ui.font_size()
	dpi := ui_scale_of(app)
	nav := em * 2.1   // (nav_button)
	want = {
		.Lead = math.round(10 * dpi) + math.round(16 * dpi) + math.round(6 * dpi),   // (as in the row of tabs)
		.Back = nav, .Forward = nav, .Reload = nav,
		.Gap_Before = em * 0.4,
		.Field = favs.cfg.side_address_min_em * em,
		.Chips = chips_w,
		.Gap_After = em * 0.4,
		.Shield = bl.started ? em * 2.3 + em * 0.2 : 0,   // (blocker_button, and the gap before the menu)
		.Menu = em * 2.3,
		.Drag = max(wchrome.cfg.min_drag_em * em, em * 0.5),
		.Buttons = 3 * math.round(ui.CAPTION_BUTTON_WIDTH * dpi),
	}
	return want, em * 0.5
}

@(private = "file")
Titlebar_Build :: struct { app: ^App, t: ^Tab }

// The title bar of a window whose tabs are in a sidebar (integrated title bar): the icon and the toolbar.
sidebar_titlebar :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	dpi := ui_scale_of(app)
	h := max(ui.dense(em * 2.6), math.round(32 * dpi))   // (tab_strip's)
	// the chips' width is last frame's (they appear with a zoom or a passkey dialog; the field absorbs the difference)
	chips_w: f32
	if bar := ui.prev_box("###tabstrip"); bar != nil {
		if c := ui.box_from_key(ui.key_from_string(bar.key, TITLEBAR_SLOT_IDS[.Chips])); c != nil { chips_w = c.rect.max.x - c.rect.min.x }
	}
	want, drag_min := titlebar_wants(app, chips_w)
	l := titlebar_layout(f32(active_window(app).win.size.x), want, drag_min)
	tb := ui.frame_new(Titlebar_Build)
	tb^ = {app, t}
	bar := titlebar_row_build(l, h, proc(p: Titlebar_Part, user: rawptr) {
		d := (^Titlebar_Build)(user)
		app, t := d.app, d.t
		dpi := ui_scale_of(app)
		switch p {
		case .Lead:
			ui.spacer(ui.px(math.round(10 * dpi)))
			app_icon(app, math.round(16 * dpi))
			ui.spacer(ui.px(math.round(6 * dpi)))
		case .Back: nav_back_button(app, t)
		case .Forward: nav_forward_button(app, t)
		case .Reload: nav_reload_button(app, t)
		case .Field: address_bar(app, t)
		case .Chips: address_chips(app, t)
		case .Shield:
			if bl.started {
				blocker_button(app, t)
				ui.spacer(ui.px(ui.font_size() * 0.2))
			}
		case .Menu: main_menu_button(app, t)
		case .Buttons: _, _ = ui.window_buttons()
		case .Gap_Before, .Gap_After, .Drag:   // (the window's)
		}
	}, tb)
	if classic_on() { bar.custom, bar.custom_user = titlebar_toolbar_draw, classic_colors_frame(app) }
}

// The sidebar: header, list of tabs and, over its inner edge, the width handle. Returns true when a tab closed (the build
// stops: the tab list changed under it).
tab_sidebar :: proc(app: ^App, pos: Tabs_Position) -> (closed: bool) {
	own := window_own(app)
	dpi := ui_scale_of(app)
	collapsed := favs.cfg.side_collapsed
	// the held handle's width from this frame's pointer, before anything is built: the sidebar and the page are laid out at
	// the width the pointer asks for now, not at the one of the frame before (the handle's signal comes after them)
	if own.sidebar.resizing && own.sidebar.handle != 0 && ui.active_key() == own.sidebar.handle {
		own.sidebar.live_w = sidebar_drag_width(own.sidebar.grab_w, own.sidebar.press_x, ui.mouse_pos().x, dpi, pos)
	}
	width_css := own.sidebar.live_w > 0 ? own.sidebar.live_w : favs.cfg.side_w
	extent := sidebar_extent(f32(active_window(app).win.size.x), width_css, dpi, collapsed, favs.cfg.side_collapsed_w)
	ui.reorder_frame(&own.strip.drag)   // the button went up (wherever): no drag
	favicon_frame()

	// classic (chrome_style.odin): the panel is the tab bar, its current tab flows into the page; the toolbar's line along
	// its top is whole (no tab of the top row interrupts it)
	cc: ^Classic_Colors
	if classic_on() {
		cc = classic_colors_frame(app)
		cur_gap.valid = false
	}
	ui.next({width = ui.px(extent), height = ui.fill(), axis = .Y})
	bar := ui.build_box(cc != nil ? {} : {pos == .Left ? .Draw_Side_Right : .Draw_Side_Left}, "###sidebar")
	if cc != nil {
		panel := ui.frame_new(Classic_Side_Panel)
		panel^ = {c = cc, pos = pos}
		bar.custom, bar.custom_user = classic_side_panel_draw, panel
	}
	if ui.parent(bar) {
		sidebar_header(app, pos, collapsed)
		if sidebar_list(app, pos, collapsed, extent, cc) { return true }
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
		ui.a11y_set(tb, {name = i18n.tr("Tab titles"), expanded = !collapsed})   // (the sidebar's titles, shown or not)
		if sig.clicked { set_pref_bool(app, "browser.tabs.sidebar_collapsed", !collapsed) }
	}
	// the glyph alone, lit under the pointer as the toolbar's buttons (the toggle's size), in either style
	add := proc(app: ^App, bw, bh, em: f32) {
		ui.next({width = ui.px(bw), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
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
			add(app, bw, bh, em)
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
		add(app, bw, bh, em)
		ui.spacer(ui.px(inset * 2))
	}
}

// The list of tabs: a vertical scroll box, `rh` high per tab, whose rows are floating boxes placed by slot. Returns true
// when a tab closed.
@(private = "file")
sidebar_list :: proc(app: ^App, pos: Tabs_Position, collapsed: bool, extent: f32, cc: ^Classic_Colors) -> (closed: bool) {
	wnd := active_window(app)
	own := &wnd.own
	em := ui.font_size()
	n := len(wnd.tabs)
	rh := ui.dense(math.round(em * favs.cfg.side_row_em))

	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	area_flags := ui.Box_Flags{.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}
	if cc != nil && pos == .Left { area_flags += {.Scrollbar_Left} }   // (classic: the inner edge is the current tab's)
	area := ui.build_box(area_flags, "###tabs_area")
	tab_list_a11y(area, true)
	_ = ui.signal(area)   // the wheel
	own.strip.area_key = area.key
	if app.active != nil { app.active.zone = {rect = area.rect, vertical = true, offset = area.view_off.y, pitch = rh, n = n, valid = true} }
	view_h := area.size.y > 0 ? area.size.y : f32(active_window(app).win.size.y)
	limit := max(f32(n) * rh - view_h, 0)

	// a new current tab is scrolled into view (not while one is dragged: the list follows the pointer then)
	cur_id := wnd.tabs[wnd.current].id
	if cur_id != own.strip.follow_id || n != own.strip.follow_n || !own.sidebar.shown {
		area.view_target.y = strip_offset(area.view_target.y, n, rh, view_h, wnd.current, true)
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
	first, last := side_visible_rows(area.view_off.y, area.view_target.y, view_h, rh, n, rh * 2)
	dragged := -1
	for t, i in wnd.tabs {
		if ui.reorder_dragging(&own.strip.drag, t.id) { dragged = i; break }
	}
	focused := focused_tab_index(app)
	// classic: the current tab is built after the others (its feet flare over its neighbours' rows)
	late := cc != nil && wnd.current != dragged ? wnd.current : -1

	move_from, move_to := -1, -1
	if ui.parent(area) {
		ui.spacer(ui.px(f32(n) * rh), exact = true)   // the content's height: the scroll range
		for i in first ..< last {
			if i == dragged || i == late { continue }
			if sidebar_row(app, i, rh, row_x, row_w, inset, collapsed, area, limit, cc, &move_from, &move_to) { return true }
		}
		if late >= first && late < last {
			if sidebar_row(app, late, rh, row_x, row_w, inset, collapsed, area, limit, cc, &move_from, &move_to) { return true }
		}
		// a row that has the keyboard stays built when it scrolls out of view
		if focused >= 0 && (focused < first || focused >= last) && focused != dragged {
			if sidebar_row(app, focused, rh, row_x, row_w, inset, collapsed, area, limit, cc, &move_from, &move_to) { return true }
		}
		if dragged >= 0 {   // built last: it draws over the others and takes the clicks
			if sidebar_row(app, dragged, rh, row_x, row_w, inset, collapsed, area, limit, cc, &move_from, &move_to) { return true }
		}
		if app.active != nil && app.active.drop_hint > 0 { drop_hint_mark(area, true, f32(app.active.drop_hint - 1) * rh - area.view_off.y) }   // a tab carried over this list
	}
	if move_from >= 0 {
		wnd.current = list_move(wnd.tabs[:], move_from, move_to, wnd.current)
		own.strip.follow_id = wnd.tabs[wnd.current].id   // no jump of the scroll while dragging
		request_frames(app, 2)
		recovery_touch(app)
	}
	any_turning := false
	for t, i in wnd.tabs {
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
sidebar_row :: proc(app: ^App, i: int, rh, row_x, row_w, inset: f32, collapsed: bool, area: ^ui.Box, limit: f32, cc: ^Classic_Colors, move_from, move_to: ^int) -> (closed: bool) {
	wnd := active_window(app)
	own := &wnd.own
	t := wnd.tabs[i]
	n := len(wnd.tabs)
	em := ui.font_size()
	dpi := ui_scale_of(app)
	on := i == wnd.current
	id := fmt.tprintf("###tab_%d", t.id)
	slot := f32(i) * rh
	akey := ui.key_from_string(area.key, fmt.tprintf("y%d", t.id))
	// (list coordinates: the scroll box places the rows; the release slides from where the pointer left it)
	y, dragging := ui.reorder_item_pos(&own.strip.drag, akey, t.id, slot, ui.mouse_pos().y - area.rect.min.y + area.view_off.y, 0, f32(n - 1) * rh)
	prev := ui.prev_box(id)
	inside := prev != nil && ui.box_contains(prev, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos())

	if !on { ui.push_tags("weak") }
	defer if !on { ui.pop_tags() }
	ui.next({fixed_x = row_x, fixed_y = y, width = ui.px(row_w), height = ui.px(rh), axis = .X, cross = .Center, radius = em * 0.45})
	ui.push_tags("tab")
	b: ^ui.Box
	if cc != nil {
		// classic (chrome_style.odin): not clipped, the current tab's feet flare past its row
		b = ui.build_box({.Clickable, .Focusable, .Hot_Within}, id)
		pos := favs.cfg.position
		look := ui.frame_new(Classic_Side_Tab)
		look^ = {c = cc, pos = pos, m = side_tab_metrics(em, dpi, rh, row_w), dragging = dragging, inset = math.round(em * 0.6), gap = math.round(em * 0.3)}
		look.selected = ui.anim(ui.key_from_string(b.key, "sel"), on ? 1 : 0, 34)
		look.hover = ui.anim(ui.key_from_string(b.key, "hov"), (inside || dragging) && !on ? 1 : 0, 40)
		// an engraved line under it, between two tabs that are neither current nor under the pointer
		if !collapsed && !on && !inside && !dragging && i + 1 < n && i + 1 != wnd.current {
			nb := ui.prev_box(fmt.tprintf("###tab_%d", wnd.tabs[i + 1].id))
			look.rule = !(nb != nil && ui.box_contains(nb, ui.mouse_pos()) && draw.rect_contains(area.rect, ui.mouse_pos()))
		}
		b.custom, b.custom_user = classic_side_tab_draw, look
	} else {
		b = ui.build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Hot_Within, .Clip}, id)
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
			ui.a11y({ignore = true})   // (the tab's name)
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
	if !own.strip.drag.active { sidebar_tip(sig, t) }

	// drag to reorder, along Y (straight out sideways starts a drag too: it may leave the bar)
	if sig.dragging && favs.cfg.drag_reorder && (n > 1 || favs.cfg.drag_detach) {
		ui.reorder_begin(&own.strip.drag, t.id, ui.reorder_moved(sig.drag_delta, .Y, favs.cfg.drag_detach), favs.cfg.drag_threshold * dpi,
			ui.mouse_pos().y - sig.drag_delta.y - area.rect.min.y + area.view_off.y, slot)
		if ui.reorder_dragging(&own.strip.drag, t.id) {
			to := drag_slot(y, rh, n)
			if to != i { move_from^, move_to^ = i, to }
			// the list follows the pointer to its ends: a row held past the edge scrolls it
			area.view_target.y = ui.reorder_edge_scroll(y, rh, area.view_off.y, area.size.y, limit, area.view_target.y)
			request_frames(app, 2)
			// far enough beside the list: the tab leaves for a window of its own (tab_drag.odin)
			if favs.cfg.drag_detach && detach_wanted(area.rect, ui.mouse_pos(), true, favs.cfg.detach_distance_em * em) {
				own.strip.drag.active = false
				if tab_drag_begin(app, t, ui.mouse_pos()) && len(wnd.tabs) != n { return true }
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
	own := window_own(app)
	grab := math.round(5 * dpi)
	ui.push_parent(bar)
	defer ui.pop_parent()
	ui.next({fixed_x = pos == .Left ? extent - grab : 0, fixed_y = 0, width = ui.px(grab), height = ui.pct(1), cursor = .Resize_H})
	hb := ui.build_box({.Clickable}, "###side_handle")
	ui.a11y_set(hb, {role = .Splitter, name = i18n.tr("Sidebar width"), orientation = .Y,
		numeric = f64(own.sidebar.live_w > 0 ? own.sidebar.live_w : favs.cfg.side_w), min = f64(SIDEBAR_MIN_CSS), max = f64(SIDEBAR_MAX_CSS)})
	own.sidebar.handle = hb.key
	sig := ui.signal(hb)
	if sig.pressed {
		own.sidebar.resizing = true
		own.sidebar.grab_w = own.sidebar.live_w > 0 ? own.sidebar.live_w : favs.cfg.side_w
		own.sidebar.press_x = ui.mouse_pos().x - sig.drag_delta.x
	}
	if sig.dragging && own.sidebar.resizing {
		w := sidebar_drag_width(own.sidebar.grab_w, own.sidebar.press_x, ui.mouse_pos().x, dpi, pos)
		if w != own.sidebar.live_w {
			// (the press frame: the pointer moved since it was built)
			own.sidebar.live_w = w
			request_frames(app, 1)
		}
		// the edge this frame draws, against the pointer it was built from (browser.frame.drag_probe)
		drag_probe_note(ui.mouse_pos().x, pos == .Left ? bar.rect.min.x + extent : bar.rect.max.x - extent)
	}
	if !sig.dragging && own.sidebar.resizing {
		own.sidebar.resizing = false
		if own.sidebar.live_w > 0 {
			set_pref_string(app, "browser.tabs.sidebar_width", fmt.tprintf("%d", int(own.sidebar.live_w)))
			own.sidebar.live_w = 0
		}
	}
	if sig.hovering || own.sidebar.resizing {
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
