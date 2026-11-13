package browser

// Where the developer tools' panels are: the toolkit's dock (ui.Dock, the toolkit's docs/docking.md). The panels (Console,
// Elements, Network, Application, Performance, Memory) are in stacks of tabs the user drags out of their strip: onto the
// squares over a stack (into it, at a side of it), the edges of the panel, between two tabs, or anywhere else to float
// over the panel (moved by its strip, docked back by a double click); each stack's menu does the same from the keyboard.
// The splits are the toolkit's pane_split (resized, folded: the drawer of old is the Console's stack under the others).
// browser.devtools.layout keeps it, one line of the dock's text; a profile from before it has its drawer migrated
// (browser.devtools.drawer_tabs, drawer_tab, drawer). The Elements panel has a dock of its own: the tree and the views
// beside it (devtools_elements.odin).
//
// The buttons of the panel as a whole (the element picker; settings, where the panel goes, close) are at the ends of the
// top strips: the picker in the top left stack's, the others in the top right stack's (the close button last, after the
// stack's own fold and menu buttons), whose empty part moves the panel when it floats over the page. `panel` (browser.devtools.tab) is the panel shown last.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:config"

DEV_LAYOUT_PREF :: "browser.devtools.layout"
// All the panels in one stack, the Console shown: the panel as it came.
DEV_LAYOUT_DEFAULT :: "dock1 [*console,elements,network,application,performance,memory]"
// A drawer of old had this height when it had none of its own (CSS px).
DEV_OLD_DRAWER_PX :: 200

dev_panel_name :: proc(user: rawptr, id: u32) -> string { return id < u32(len(Dev_Panel)) ? DEV_PANEL_NAMES[Dev_Panel(id)] : "" }

dev_panel_of :: proc(user: rawptr, name: string) -> (u32, bool) {
	for n, x in DEV_PANEL_NAMES { if n == name { return u32(x), true } }
	return 0, false
}

// The layout of the preference (not when it is the dock's own: its save); `first`: the window's first read, where an old
// profile's drawer is migrated.
dev_layout_load :: proc(d: ^Devtools, p: ^config.Prefs, first: bool) {
	text := config.string_of(p, DEV_LAYOUT_PREF)
	if len(d.layout.nodes) > 0 && ui.dock_format(&d.layout, dev_panel_name, nil) == text { return }
	if first && config.is_default(p, config.ref_of(p, DEV_LAYOUT_PREF)) && dev_layout_migrate(d, p) { return }
	// (the text is every window's; the panels a window shows are its own: they stay on top of their stacks, its last one too)
	was := len(d.layout.nodes) > 0
	if !ui.dock_parse(&d.layout, text, dev_panel_of, nil) { ui.dock_parse(&d.layout, DEV_LAYOUT_DEFAULT, dev_panel_of, nil) }
	dev_layout_complete(d)
	if was {
		for x in Dev_Panel { if x in d.shown { ui.dock_activate(&d.layout, u32(x)) } }
		ui.dock_activate(&d.layout, u32(d.panel))
		d.layout.saved = d.layout.serial   // (not a change to save: two windows would write their own tabs over each other's)
	}
}

// A panel the text does not name (one added since it was saved) joins the Console's stack.
@(private = "file")
dev_layout_complete :: proc(d: ^Devtools) {
	for x in Dev_Panel { ui.dock_add(&d.layout, u32(x), ui.dock_with(&d.layout, u32(Dev_Panel.Console))) }
}

// A profile from before the dock: its drawer (the tabs moved under the others, the one it showed, its height and fold) is a
// stack under the others; the text is saved as browser.devtools.layout. False: it had none.
@(private = "file")
dev_layout_migrate :: proc(d: ^Devtools, p: ^config.Prefs) -> bool {
	tabs, ok := config.user_text(p, "browser.devtools.drawer_tabs")
	if !ok || strings.trim_space(tabs) == "" { return false }
	ui.dock_parse(&d.layout, DEV_LAYOUT_DEFAULT, dev_panel_of, nil)
	under := ui.DOCK_NONE
	for n in strings.split(tabs, ",", context.temp_allocator) {
		id, known := dev_panel_of(nil, strings.trim_space(n))
		if !known { continue }
		if under == ui.DOCK_NONE {
			if ui.dock_move(&d.layout, id, {place = .Edge_Bottom}) { under = ui.dock_leaf_of(&d.layout, id) }
		} else {
			ui.dock_move(&d.layout, id, {place = .Tab, node = under, index = -1})
		}
	}
	if under == ui.DOCK_NONE { return false }
	if shown, ok2 := config.user_text(p, "browser.devtools.drawer_tab"); ok2 {
		if id, known := dev_panel_of(nil, strings.trim_space(shown)); known && ui.dock_leaf_of(&d.layout, id) == under { ui.dock_activate(&d.layout, id) }
	}
	if split := d.layout.nodes[under].parent; split != ui.DOCK_NONE {
		pane, _ := ui.pane_parse(config.user_text(p, "browser.devtools.drawer") or_else "")
		h := pane.size[.Y] > 0 ? pane.size[.Y] : DEV_OLD_DRAWER_PX
		room := f32(config.float_of(p, "browser.devtools.size"))
		ui.dock_set_split(&d.layout, split, room > h ? 1 - h / room : d.layout.nodes[split].ratio, pane.collapsed)
	}
	dev_layout_complete(d)
	_ = config.set_from_string(p, DEV_LAYOUT_PREF, ui.dock_format(&d.layout, dev_panel_name, nil), .User)
	return true
}

devtools_save_layout :: proc(app: ^App) { set_pref_string(app, DEV_LAYOUT_PREF, ui.dock_format(&dev().layout, dev_panel_name, nil)) }

// The Console's stack when it is the drawer: alone, docked, the second side of a split one above the other (its split, which
// folds it). DOCK_NONE: it is not.
devtools_drawer_split :: proc(d: ^Devtools) -> i32 {
	dk := &d.layout
	con := ui.dock_leaf_of(dk, u32(Dev_Panel.Console))
	if con == ui.DOCK_NONE || ui.dock_is_floating(dk, con) || ui.dock_tab_count(dk, con) != 1 { return ui.DOCK_NONE }
	split := ui.dock_fold_split(dk, con)
	if split == ui.DOCK_NONE || dk.nodes[split].axis != .Y || dk.nodes[split].b != con { return ui.DOCK_NONE }
	return split
}

// Escape in the developer tools (devtools_panel), and "Show the Console under the other panels": the Console in a stack of its
// own under the others, Chrome's drawer, or that stack folded away and opened again.
devtools_drawer_toggle :: proc(app: ^App) {
	d := dev()
	dk := &d.layout
	split := devtools_drawer_split(d)
	if split == ui.DOCK_NONE {
		ui.dock_move(dk, u32(Dev_Panel.Console), {place = .Edge_Bottom})
		devtools_open(app, .Console)
	} else {
		fold := !dk.nodes[split].fold
		ui.dock_set_split(dk, split, dk.nodes[split].ratio, fold)
		if !fold { ui.dock_activate(dk, u32(Dev_Panel.Console)) }
	}
	devtools_save_layout(app)
	network_sync_observer(app)
	console_arm_all(app)
	request_frames(app, 3)
}

// Ctrl+Tab / Ctrl+Shift+Tab with the keyboard focus in the developer tools: the next or previous panel of the stack it is in
// (the Elements panel's own dock first), before the chrome's shortcuts take them for the browser's tabs.
devtools_take_ctrl_tab :: proc(app: ^App) -> bool {
	d := dev()
	if !d.visible || devtools_detached() { return false }
	if ui.dock_take_ctrl_tab(&d.els.layout) || ui.dock_take_ctrl_tab(&d.layout) {
		request_frames(app, 2)
		return true
	}
	return false
}

// The dock of the panels, in the panel's room.
dev_dock :: proc(app: ^App, t: ^Tab) {
	d := dev()
	room := d.room
	d.frame_tab = t
	ui.dock_begin(&d.layout, "###dt_dock", {
		title = proc(user: rawptr, id: u32) -> string { return DEV_PANEL_TITLES[Dev_Panel(id)] },
		tab = dev_tab_face,
		closable = proc(user: rawptr, id: u32) -> bool { return false },   // (a panel goes elsewhere, not away)
		strip_begin = dev_strip_begin, strip_end = dev_strip_end, strip_last = dev_strip_last, strip_space = dev_strip_space,
		on_save = proc(user: rawptr, dk: ^ui.Dock) { devtools_save_layout((^App)(user)) },
		user = app, size = room, tab_height = app.dtm.tab, handle = dt_px(5),
	})
	for p in Dev_Panel {
		// (`if dock_panel {}`: its content in the block, built in the panel's box; the box is let go at the block's end)
		if ui.dock_panel(&d.layout, u32(p)) {
			d.room = ui.dock_panel_size(&d.layout, u32(p))   // (what the panel's widths are made from: dev_width)
			dev_panel_body(app, t, p)
		}
	}
	d.room = room
	r := ui.dock_end(&d.layout)
	// the panel shown last: the one that came on top this frame
	now: bit_set[Dev_Panel]
	for p in Dev_Panel { if ui.dock_shown(&d.layout, u32(p)) { now += {p} } }
	if fresh := now - d.shown; fresh != {} && d.panel not_in fresh {
		for p in Dev_Panel { if p in fresh { d.panel = p } }
		if d.panel != .Elements { d.picking = false }
		_ = config.set_from_string(&app.prefs, "browser.devtools.tab", DEV_PANEL_NAMES[d.panel], .User)   // (quiet: one the command line set stays over it)
	}
	if now != d.shown {
		d.shown = now
		network_sync_observer(app)
		console_arm_all(app)
		request_frames(app, 2)
	}
	if r.changed { request_frames(app, 2) }
}

dev_panel_body :: proc(app: ^App, t: ^Tab, p: Dev_Panel) {
	switch p {
	case .Console:     console_panel(app, t)
	case .Elements:    elements_panel(app, t)
	case .Network:     network_panel(app, t)
	case .Application: application_panel(app, t)
	case .Performance: performance_panel(app, t)
	case .Memory:      memory_panel(app, t)
	}
}

////////////////////////////////
// The tabs: an icon, the title, the numbers of the Console and the Network

@(private = "file")
Tab_Face :: struct {
	icon:    Dt_Icon,
	label:   string,
	on, hot: bool,
	badges:  [2]string,
	tones:   [2]draw.Color,
	badge_w: [2]f32,
	warn:    bool,         // a dot on the icon: the tab is held to a network speed
}

@(private = "file")
tab_width :: proc(label: string, icon_w: f32, badges: [2]string) -> (w: f32, bw: [2]f32) {
	w = dt_px(8) + icon_w + dt_px(5) + dt_w(the_app.dtm.ui_font, the_app.dtm.fs, label) + dt_px(8)
	for b, i in badges {
		if b == "" { continue }
		bw[i] = max(dt_w(the_app.dtm.ui_font, the_app.dtm.fs * 0.82, b) + dt_px(8), the_app.dtm.fs * 1.12)
		w += bw[i] + dt_px(4)
	}
	return
}

// The numbers a tab shows next to its name.
@(private = "file")
tab_info :: proc(t: ^Tab, p: Dev_Panel) -> (badges: [2]string, tones: [2]draw.Color) {
	if t == nil { return }
	#partial switch p {
	case .Console:
		e, w := console_counts(t)
		if e > 0 { badges[0], tones[0] = dt_frame_str(fmt.tprintf("%d", e)), the_app.dtc.bad }
		if w > 0 { badges[1], tones[1] = dt_frame_str(fmt.tprintf("%d", w)), ui.hue(.Yellow) }
	case .Network:
		n := len(t.net.entries)
		if n > 0 {
			errs := 0
			for &e in t.net.entries { if e.failed || e.status >= 400 { errs += 1 } }
			badges[0], tones[0] = dt_frame_str(fmt.tprintf("%d", n)), with_alpha(the_app.dtc.weak, 0.55)
			if errs > 0 { badges[1], tones[1] = dt_frame_str(fmt.tprintf("%d", errs)), the_app.dtc.bad }
		}
	}
	return
}

// What a tab of the dock shows (its hover and the line under the shown one are the dock's).
@(private = "file")
dev_tab_face :: proc(user: rawptr, tab: ui.Dock_Tab) {
	app := (^App)(user)
	p := Dev_Panel(tab.panel)
	bs, tones := tab_info(dev().frame_tab, p)
	w, bw := tab_width(DEV_PANEL_TITLES[p], app.dtm.icon, bs)
	ui.next({width = ui.px(math.round(w)), height = ui.pct(1)})
	b := ui.build_box({}, "###dt_tab_face")
	f := ui.frame_new(Tab_Face)
	f.icon, f.label, f.on, f.hot = DEV_PANEL_ICONS[p], DEV_PANEL_TITLES[p], tab.active, tab.hot
	f.badges, f.tones, f.badge_w = bs, tones, bw
	f.warn = p == .Network && net_profile_active(net_profile_of(app, dev().frame_tab))
	b.custom, b.custom_user = tab_face_paint, f
}

@(private = "file")
tab_face_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tab_Face)(user)
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	col := d.on || d.hot ? the_app.dtc.text : the_app.dtc.weak
	x := r.min.x + dt_px(8)
	dt_icon(dc, d.icon, {math.round(x + the_app.dtm.icon * 0.5), cy}, the_app.dtm.icon, d.on ? the_app.dtc.accent : col, the_app.dtm.sc)
	if d.warn { rr := dt_px(3); draw.rect(dc, {{x + the_app.dtm.icon - rr, cy - the_app.dtm.icon * 0.5 - rr * 0.3}, {x + the_app.dtm.icon + rr, cy - the_app.dtm.icon * 0.5 + rr * 1.7}}, draw.Color{0.93, 0.62, 0.10, 1}, rr) }
	x += the_app.dtm.icon + dt_px(5)
	x += dt_text(dc, the_app.dtm.ui_font, the_app.dtm.fs, x, cy, col, d.label) + dt_px(4)
	for bt, i in d.badges {
		if bt == "" { continue }
		w := d.badge_w[i]
		bh := the_app.dtm.fs * 1.12
		draw.rect(dc, {{x, cy - bh * 0.5}, {x + w, cy + bh * 0.5}}, d.tones[i], bh * 0.5)
		tw := dt_w(the_app.dtm.ui_font, the_app.dtm.fs * 0.82, bt)
		dt_text(dc, the_app.dtm.ui_font, the_app.dtm.fs * 0.82, x + (w - tw) * 0.5, cy, draw.Color{1, 1, 1, 1}, bt)
		x += w + dt_px(4)
	}
}

////////////////////////////////
// The panel's own buttons, at the ends of the top strips

// The stack of the main tree at the top left (`right`: the top right) of the panel; when every panel floats, the topmost's.
@(private = "file")
dev_corner_leaf :: proc(dk: ^ui.Dock, right: bool) -> i32 {
	best := ui.DOCK_NONE
	for l in ui.dock_leaves(dk, dk.main) {
		r := dk.nodes[l].rect
		if !ui.dock_node_visible(dk, l) || ui.dock_tab_count(dk, l) == 0 || r.min.y > 0 { continue }
		if best == ui.DOCK_NONE || (right ? r.max.x > dk.nodes[best].rect.max.x : r.min.x < dk.nodes[best].rect.min.x) { best = l }
	}
	if best == ui.DOCK_NONE && len(dk.floats) > 0 { best = ui.dock_leaves(dk, dk.floats[len(dk.floats) - 1])[0] }
	return best
}

@(private = "file")
dev_strip_begin :: proc(user: rawptr, dk: ^ui.Dock, leaf: i32) {
	if leaf != dev_corner_leaf(dk, false) { return }
	app := (^App)(user)
	dt_gap(2)
	pick := dt_btn("###dt_pick", .Inspect, tooltip = "Select an element in the page to inspect it", shortcut = cmd_key(app, "view.devtools_pick"), on = dev().picking)
	if pick.clicked { devtools_pick(app) }
	dt_vsep("###dt_hs0")
	dt_gap(2)
}

@(private = "file")
dev_strip_end :: proc(user: rawptr, dk: ^ui.Dock, leaf: i32) {
	if leaf != dev_corner_leaf(dk, true) { return }
	app := (^App)(user)
	skey := dt_menu_btn("###dt_settings", .Kebab, tooltip = "Customize and control the developer tools", caret = false)
	if ui.menu(skey, dt_px(230)) { devtools_settings_menu(app, dev().frame_tab) }
	dkey := dt_menu_btn("###dt_dock", DEV_DOCK_ICONS[dev().dock], tooltip = "Dock side", caret = false)
	if ui.menu(dkey, dt_px(240)) {
		for d in Dev_Dock {
			if ui.menu_item(fmt.tprintf("%s###dt_dock_%d", DEV_DOCK_TITLES[d], int(d)), cmd_key(app, DEV_DOCK_COMMANDS[d]), checked = dev().dock == d && !devtools_detached(), icon = "").clicked { if devtools_detached() { devtools_attach(app) }; devtools_set_dock(app, d) }
		}
		ui.menu_separator()
		if devtools_detached() {
			if ui.menu_item("Dock back into the browser window###dt_dock_win", cmd_key(app, "view.devtools_detach"), icon = lucide.PANEL_BOTTOM).clicked { devtools_attach(app) }
		} else {
			if ui.menu_item("Open in a separate window###dt_dock_win", cmd_key(app, "view.devtools_detach"), icon = lucide.APP_WINDOW).clicked { devtools_detach(app) }
		}
	}
	dt_gap(2)
}

// The close button: after the dock's fold and menu buttons, the strip's last control.
@(private = "file")
dev_strip_last :: proc(user: rawptr, dk: ^ui.Dock, leaf: i32) {
	if leaf != dev_corner_leaf(dk, true) { return }
	app := (^App)(user)
	dt_gap(2)
	dt_vsep("###dt_hs1")
	dt_gap(2)
	if dt_btn("###dt_close", .Close, tooltip = "Close the developer tools", shortcut = "F12").clicked { devtools_toggle(app) }
	dt_gap(2)
}

// A floating panel over the page is moved by the empty part of its top right strip.
@(private = "file")
dev_strip_space :: proc(user: rawptr, dk: ^ui.Dock, leaf: i32, b: ^ui.Box) {
	if dev().dock != .Floating || devtools_detached() || leaf != dev_corner_leaf(dk, true) { return }
	b.flags += {.Clickable}
	b.cursor = .Move
	devtools_float_drag((^App)(user), ui.signal(b), .Move)
}
