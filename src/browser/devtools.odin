package browser

// The developer tools: a native view of the chrome (not a page), docked under the page, at its right, or floating over
// it, with three tabs (Console, Elements, Network). F12 / Ctrl+Shift+I open and close it, Ctrl+Shift+J opens the Console;
// "Inspect" in the page's context menu opens Elements on the element under the pointer. The tabs are in
// devtools_console.odin, devtools_elements.odin and devtools_network.odin.
//
// State and preferences: browser.devtools.visible / dock / tab / size. The panel takes room from the page (build_ui puts it
// next to the page's box, so page_rect shrinks and the layout follows); floating, it is a box over the page that is moved by its
// title and resized by its corner, and takes the pointer where it is (devtools_captures).
//
// The panel reads what the shell owns (the tab's console lines, its request log); what it shows of the page's document is
// copied while the page is not running (shell_nested: a chrome frame made while a script holds the thread reads nothing
// of the page).

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:page"

Dev_Dock :: enum u8 { Bottom, Right, Floating }
Dev_Panel :: enum u8 { Console, Elements, Network }

DEV_DOCK_NAMES := [Dev_Dock]string{.Bottom = "bottom", .Right = "right", .Floating = "floating"}
DEV_PANEL_NAMES := [Dev_Panel]string{.Console = "console", .Elements = "elements", .Network = "network"}
DEV_PANEL_TITLES := [Dev_Panel]string{.Console = "Console", .Elements = "Elements", .Network = "Network"}
DEV_DOCK_TITLES := [Dev_Dock]string{.Bottom = "Dock at the bottom", .Right = "Dock at the right", .Floating = "Undock into a floating panel"}

DEVTOOLS_PREFS := [?]config.Def{
	{name = "browser.devtools.visible", kind = .Bool, default = {b = false},
		description = "Show the developer tools: a panel with the page's console, its document tree and its requests (F12, Ctrl+Shift+I)."},
	{name = "browser.devtools.dock", kind = .String, default = {s = "bottom"}, choices = {"bottom", "right", "floating"},
		description = "Where the developer tools sit: under the page, at its right, or in a panel over it that can be moved and resized."},
	{name = "browser.devtools.tab", kind = .String, default = {s = "console"}, choices = {"console", "elements", "network"},
		description = "The tab of the developer tools that is shown."},
	{name = "browser.devtools.size", kind = .Float, default = {f = 300}, bounded = true, min = 100, max = 4000, unit = "px",
		description = "Height of the developer tools when they sit under the page, width when they sit at its right (CSS pixels)."},
}

register_devtools_prefs :: proc(p: ^config.Prefs) { config.register(p, DEVTOOLS_PREFS[:]) }

Dev_Drag :: enum u8 { None, Size, Move, Corner }

Devtools :: struct {
	visible:   bool,
	dock:      Dev_Dock,
	panel:     Dev_Panel,
	size:      f32,                // logical px: the height (bottom) or the width (right)
	float_pos: [2]f32,             // floating: from the window's top left, logical px
	float_size: [2]f32,
	float_set: bool,               // the floating panel has a place (else: made when first shown)
	drag:      Dev_Drag,
	drag_from: [2]f32,             // the size / place when the drag began
	panel_rect: draw.Rect,         // where the floating panel was drawn last frame
	watch:     int,
	con:       Dev_Console,
	els:       Dev_Elements,
}

dev: Devtools

devtools_init :: proc(app: ^App) {
	devtools_apply_prefs(&app.prefs)
	if app.cfg.show_console && !dev.visible { dev.visible, dev.panel = true, .Console }   // browser.console.visible: the older way to ask for it
	dev.watch = config.watch(&app.prefs, "browser.devtools.", proc(user: rawptr, name: string, p: ^config.Prefs) { devtools_apply_prefs(p) }, app)
	app.loader.observer = {user = app, event = net_observe}   // devtools_network.odin
}

devtools_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, dev.watch)
	console_panel_destroy()
	elements_destroy()
	net_destroy()
	dev = {}
}

devtools_apply_prefs :: proc(p: ^config.Prefs) {
	dev.visible = config.bool_of(p, "browser.devtools.visible")
	dock, panel := config.string_of(p, "browser.devtools.dock"), config.string_of(p, "browser.devtools.tab")
	for name, d in DEV_DOCK_NAMES { if name == dock { dev.dock = d } }
	for name, d in DEV_PANEL_NAMES { if name == panel { dev.panel = d } }
	if dev.drag == .None { dev.size = f32(config.float_of(p, "browser.devtools.size")) }
}

// What the panel's own state asks of the preferences (they are what is saved, and what about:config shows).
devtools_save :: proc(app: ^App) {
	set_pref_bool(app, "browser.devtools.visible", dev.visible)
	set_pref_string(app, "browser.devtools.dock", DEV_DOCK_NAMES[dev.dock])
	set_pref_string(app, "browser.devtools.tab", DEV_PANEL_NAMES[dev.panel])
	set_pref_string(app, "browser.devtools.size", fmt.tprintf("%d", int(dev.size)))
}

set_pref_string :: proc(app: ^App, name, value: string) {
	if config.string_of(&app.prefs, name) == value { return }
	if err := config.set_from_string(&app.prefs, name, value, .User); err != .None {
		ui.toast(.Warn, "%s: %s", name, config.set_error_text(err))
	}
}

devtools_toggle :: proc(app: ^App) {
	dev.visible = !dev.visible
	set_pref_bool(app, "browser.devtools.visible", dev.visible)
	app.frames_requested = max(app.frames_requested, 3)
}

devtools_open :: proc(app: ^App, panel: Dev_Panel) {
	changed := !dev.visible || dev.panel != panel
	dev.visible, dev.panel = true, panel
	if changed { devtools_save(app) }
	app.frames_requested = max(app.frames_requested, 3)
}

// The panel closes if it is open on `panel`, else opens on it (Ctrl+Shift+J).
devtools_toggle_panel :: proc(app: ^App, panel: Dev_Panel) {
	if dev.visible && dev.panel == panel { devtools_toggle(app) } else { devtools_open(app, panel) }
}

devtools_set_dock :: proc(app: ^App, dock: Dev_Dock) {
	dev.dock = dock
	dev.visible = true
	devtools_save(app)
	app.frames_requested = max(app.frames_requested, 3)
}

// Whether the panel is shown for `t` (a web page), and where.
devtools_dock :: proc(app: ^App, t: ^Tab) -> (Dev_Dock, bool) {
	if !dev.visible || t == nil || t.kind != .Web || platform.is_fullscreen(app.win) { return {}, false }
	return dev.dock, true
}

////////////////////////////////
// The panel

// The panel under the box `next` sized: a header (tabs, dock, close) and the tab's content.
devtools_panel :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	if ui.column(.Start, {.Draw_Background}, "###dt_panel") {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		devtools_header(app, t)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(.Start, {.Clip}, "###dt_body") {
			switch dev.panel {
			case .Console:  console_panel(app, t)
			case .Elements: elements_panel(app, t)
			case .Network:  network_panel(app, t)
			}
		}
	}
}

@(private = "file")
devtools_header :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	if ui.row(.Center, {}, "###dt_header") {
		sel := int(dev.panel)
		names: [len(Dev_Panel)]string
		for p in Dev_Panel { names[int(p)] = DEV_PANEL_TITLES[p] }
		ui.next({width = ui.children_sum(), height = ui.pct(1)})
		if ui.row(.Start, {}, "###dt_tabs") {
			if ui.tabs("###dt_tab", names[:], nil, &sel) {
				dev.panel = Dev_Panel(sel)
				devtools_save(app)
				app.frames_requested = max(app.frames_requested, 2)
			}
		}
		// a floating panel is moved by its header
		ui.next({width = ui.fill(), height = ui.pct(1)})
		hb := ui.build_box({.Clickable}, "###dt_grab")
		hs := ui.signal(hb)
		if dev.dock == .Floating { hb.cursor = .Move; devtools_float_drag(app, hs, .Move) }
		if ui.parent(hb) { ui.spacer(ui.fill()) }

		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
		dock_btn := ui.button("Dock###dt_dock")
		key := ui.key_from_string(dock_btn.box.parent.key, "###dt_dock_menu")
		if dock_btn.clicked { ui.ctx_menu_open_rect(key, dock_btn.box.rect, dock_btn.box.key) }
		if ui.ctx_menu(key) {
			for d in Dev_Dock {
				title := DEV_DOCK_TITLES[d]
				if ui.menu_item(title, checked = dev.dock == d).clicked { devtools_set_dock(app, d); ui.ctx_menu_close() }
			}
		}
		ui.spacer(ui.px(em * 0.3))
		cs := ui.dense(em * 1.8)
		ui.next({width = ui.px(cs), height = ui.px(cs), radius = em * CHROME_BUTTON_RADIUS})
		close := ui.icon_button("###dt_close", GLYPH_CLOSE)
		tip(close, "Close the developer tools (F12)")
		if close.clicked { devtools_toggle(app) }
		ui.spacer(ui.px(em * 0.4))
	}
}

////////////////////////////////
// Where it goes in the window

// The room the panel takes (physical px): its size, but never more than 70 % of the window along its axis.
devtools_extent :: proc(app: ^App, vertical: bool) -> f32 {
	room := vertical ? f32(app.win.size.x) : f32(app.win.size.y)
	return clamp(dev.size * ui.scale(), 80, math.max(room * 0.7, 80))
}

// The list at its end, for `n` rows: its heights of the last frame, an average for the rows added since. (A list that
// follows its end does so while it was at the end when rows came, and stops when the user scrolls away from it.)
dev_scroll_end :: proc(l: ^ui.Virtual_List, n: int) {
	known := len(l.offsets) - 1
	total: f32
	if known >= 0 { total = l.offsets[known] }
	if n > known { total += f32(n - math.max(known, 0)) * l.est }
	view_h: f32
	if b := ui.box_from_key(l.key); b != nil { view_h = b.size.y }
	ui.vlist_scroll_to(l, math.max(total - view_h, 0))
}

// Whether the list's view is at its end (as of last frame's layout).
dev_at_end :: proc(l: ^ui.Virtual_List, em: f32) -> bool {
	b := ui.box_from_key(l.key)
	if b == nil || len(l.offsets) == 0 { return true }
	return b.view_off.y + b.size.y >= l.offsets[len(l.offsets) - 1] - em * 2
}

// A bar between the page and the panel: dragging it resizes the panel.
devtools_splitter :: proc(app: ^App, vertical: bool) {
	em := ui.font_size()
	thick := math.max(math.round(em * 0.3), 4)
	ui.next({width = vertical ? ui.px(thick) : ui.fill(), height = vertical ? ui.fill() : ui.px(thick), cursor = vertical ? .Resize_H : .Resize_V})
	b := ui.build_box({.Clickable}, "###dt_split")
	sig := ui.signal(b)
	line := ui.frame_new(draw.Color)
	line^ = ui.color("border")
	if sig.hovering || dev.drag == .Size { line.a = math.min(line.a + 0.4, 1) }
	b.custom, b.custom_user = devtools_split_draw, line
	if sig.pressed { dev.drag, dev.drag_from = .Size, {dev.size, 0} }
	if sig.dragging && dev.drag == .Size {
		delta := vertical ? sig.drag_delta.x : sig.drag_delta.y
		room := vertical ? f32(app.win.size.x) : f32(app.win.size.y)
		dev.size = clamp(dev.drag_from[0] - delta / ui.scale(), 80, math.max(room / ui.scale() - 160, 80))
		app.frames_requested = max(app.frames_requested, 2)
	}
	if !sig.dragging && dev.drag == .Size {
		dev.drag = .None
		set_pref_string(app, "browser.devtools.size", fmt.tprintf("%d", int(dev.size)))
	}
}

@(private = "file")
devtools_split_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^draw.Color)(user)^
	r := b.rect
	if r.max.x - r.min.x < r.max.y - r.min.y {
		x := (r.min.x + r.max.x) * 0.5
		draw.rect(dc, {{x - 0.5, r.min.y}, {x + 0.5, r.max.y}}, c)
	} else {
		y := (r.min.y + r.max.y) * 0.5
		draw.rect(dc, {{r.min.x, y - 0.5}, {r.max.x, y + 0.5}}, c)
	}
}

// Moving (the header) or resizing (the corner) of the floating panel.
@(private = "file")
devtools_float_drag :: proc(app: ^App, sig: ui.Signal, what: Dev_Drag) {
	sc := ui.scale()
	if sig.pressed {
		dev.drag = what
		dev.drag_from = what == .Move ? dev.float_pos : dev.float_size
	}
	if sig.dragging && dev.drag == what {
		d := sig.drag_delta / sc
		win := [2]f32{f32(app.win.size.x), f32(app.win.size.y)} / sc
		if what == .Move {
			dev.float_pos = {clamp(dev.drag_from[0] + d.x, 0, math.max(win.x - 120, 0)), clamp(dev.drag_from[1] + d.y, 0, math.max(win.y - 60, 0))}
		} else {
			dev.float_size = {clamp(dev.drag_from[0] + d.x, 260, math.max(win.x - dev.float_pos[0], 260)), clamp(dev.drag_from[1] + d.y, 160, math.max(win.y - dev.float_pos[1], 160))}
		}
		app.frames_requested = max(app.frames_requested, 2)
	}
	if !sig.dragging && dev.drag == what { dev.drag = .None }
}

// The floating panel, built last under the window's box so it is over the page. It has a place after the first time it is
// shown: its lower right quarter of the window.
devtools_floating :: proc(app: ^App, t: ^Tab) {
	dock, on := devtools_dock(app, t)
	if !on || dock != .Floating {
		dev.panel_rect = {}
		return
	}
	sc := ui.scale()
	win := [2]f32{f32(app.win.size.x), f32(app.win.size.y)} / sc
	if !dev.float_set {
		dev.float_size = {math.max(win.x * 0.55, 360), math.max(win.y * 0.5, 240)}
		dev.float_pos = {win.x - dev.float_size[0] - 24, win.y - dev.float_size[1] - 40}
		dev.float_set = true
	}
	dev.float_size = {clamp(dev.float_size[0], 260, math.max(win.x, 260)), clamp(dev.float_size[1], 160, math.max(win.y, 160))}
	dev.float_pos = {clamp(dev.float_pos[0], 0, math.max(win.x - dev.float_size[0], 0)), clamp(dev.float_pos[1], 0, math.max(win.y - dev.float_size[1], 0))}
	ui.next({width = ui.px(dev.float_size[0] * sc), height = ui.px(dev.float_size[1] * sc), fixed_x = dev.float_pos[0] * sc, fixed_y = dev.float_pos[1] * sc, border = ui.color("border")})
	devtools_panel(app, t)
	if b := ui.box_from_key(ui.key_from_string(ui.parent_box().key, "###dt_panel")); b != nil {
		dev.panel_rect = b.rect
		// the corner: a grip that resizes
		g := math.round(ui.font_size() * 1.1)
		ui.next({width = ui.px(g), height = ui.px(g), fixed_x = b.rect.max.x - b.rect.min.x - g, fixed_y = b.rect.max.y - b.rect.min.y - g, cursor = .Resize_NWSE})
		gb := ui.build_box({.Clickable}, "###dt_corner")
		devtools_float_drag(app, ui.signal(gb), .Corner)
	}
}

// The floating panel takes the pointer where it is: the page under it gets nothing.
devtools_captures :: proc(pos: draw.Vec2) -> bool {
	return dev.visible && dev.dock == .Floating && draw.rect_contains(dev.panel_rect, pos)
}

////////////////////////////////
// What the page draws for the panel

// The box of the element the Elements tab hovers or has selected, over the page (Chromium's colors: content blue, padding
// green, border yellow). Called by page_draw for a page that is painted now.
devtools_overlay :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, area: draw.Rect) {
	if !dev.visible || dev.panel != .Elements || t == nil || t.page == nil || t.kind != .Web { return }
	h := dev.els.hover != base.NIL_HANDLE ? dev.els.hover : dev.els.selected
	if h == base.NIL_HANDLE { return }
	elements_overlay(app, t, dc, area, h)
}

// "Inspect" of the page's context menu: the panel shows the element.
devtools_inspect :: proc(app: ^App, t: ^Tab, h: base.Handle) {
	if t == nil || t.page == nil { return }
	devtools_open(app, .Elements)
	elements_select(t, h)
}

_ :: page
_ :: strings
