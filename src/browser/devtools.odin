package browser

// The developer tools: a native view of the chrome (not a page), docked under the page, at its right or its left, or
// floating over it, with tabs (Console, Elements, Network, Application, Performance, Memory). F12 / Ctrl+Shift+I open and
// close it, Ctrl+Shift+J opens the Console, Ctrl+Shift+C picks an element of the page; "Inspect" in the page's context menu
// opens Elements on the element under the pointer. The tabs are in devtools_console.odin, devtools_elements.odin,
// devtools_network.odin, devtools_application.odin, devtools_performance.odin and devtools_memory.odin; the interface
// parts they share (icons, buttons, lists, the filter field) are in devtools_kit.odin and devtools_icons.odin.
//
// State and preferences: browser.devtools.* (visible, dock, tab, size, font size, density, and what each tab keeps: its
// filters, its columns, its panes). The panel takes room from the page (build_ui puts it next to the page's box, so
// page_rect shrinks and the layout follows); floating, it is a box over the page that is moved by its header and
// resized by its corner, and takes the pointer where it is (devtools_captures). Closed, it costs nothing: nothing is
// built, and the loader's observer keeps only what the Network tab needs for the tabs that have requests.
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

Dev_Dock :: enum u8 { Bottom, Right, Left, Floating }
Dev_Panel :: enum u8 { Console, Elements, Network, Application, Performance, Memory }

DEV_DOCK_NAMES := [Dev_Dock]string{.Bottom = "bottom", .Right = "right", .Left = "left", .Floating = "floating"}
DEV_PANEL_NAMES := [Dev_Panel]string{.Console = "console", .Elements = "elements", .Network = "network", .Application = "application", .Performance = "performance", .Memory = "memory"}
DEV_PANEL_TITLES := [Dev_Panel]string{.Console = "Console", .Elements = "Elements", .Network = "Network", .Application = "Application", .Performance = "Performance", .Memory = "Memory"}
DEV_PANEL_ICONS := [Dev_Panel]Dt_Icon{.Console = .Tab_Console, .Elements = .Tab_Elements, .Network = .Tab_Network, .Application = .Tab_Application, .Performance = .Tab_Performance, .Memory = .Tab_Memory}
DEV_DOCK_TITLES := [Dev_Dock]string{.Bottom = "Dock to bottom", .Right = "Dock to right", .Left = "Dock to left", .Floating = "Undock into a floating panel"}
// The commands (commands.odin) that dock the panel: their shortcuts are shown in the menus.
DEV_DOCK_COMMANDS := [Dev_Dock]string{.Bottom = "view.devtools_dock_bottom", .Right = "view.devtools_dock_right", .Left = "view.devtools_dock_left", .Floating = "view.devtools_dock_floating"}

// The first shortcut of a command, as a menu shows it ("" when it has none).
cmd_key :: proc(name: string) -> string {
	c := command(name)
	return c == nil ? "" : command_shortcut_text(c)
}

DEV_DOCK_ICONS := [Dev_Dock]Dt_Icon{.Bottom = .Dock_Bottom, .Right = .Dock_Right, .Left = .Dock_Left, .Floating = .Float}

DEVTOOLS_PREFS := [?]config.Def{
	{name = "browser.devtools.visible", kind = .Bool, default = {b = false},
		description = "Show the developer tools: a panel with the page's console, its document tree, its requests and its storage (F12, Ctrl+Shift+I)."},
	{name = "browser.devtools.dock", kind = .String, default = {s = "bottom"}, choices = {"bottom", "right", "left", "floating"},
		description = "Where the developer tools sit: under the page, at its right or its left, or in a panel over it that can be moved and resized."},
	{name = "browser.devtools.tab", kind = .String, default = {s = "console"}, choices = {"console", "elements", "network", "application", "performance", "memory"},
		description = "The tab of the developer tools that is shown."},
	{name = "browser.devtools.size", kind = .Float, default = {f = 300}, bounded = true, min = 100, max = 4000, unit = "px",
		description = "Height of the developer tools when they sit under the page, width when they sit at its side (CSS pixels)."},
	{name = "browser.devtools.font_size", kind = .Float, default = {f = 12}, bounded = true, min = 8, max = 24, unit = "px",
		description = "Size of the text of the developer tools (CSS pixels). Ctrl and the plus, minus or zero keys change it while the panel has the pointer."},
	{name = "browser.devtools.density", kind = .String, default = {s = "compact"}, choices = {"compact", "comfortable"},
		description = "How tightly the developer tools' rows and toolbars are spaced."},
}

register_devtools_prefs :: proc(p: ^config.Prefs) {
	config.register(p, DEVTOOLS_PREFS[:])
	console_register_prefs(p)
	network_register_prefs(p)
	elements_register_prefs(p)
}

Dev_Drag :: enum u8 { None, Size, Move, Corner }

Devtools :: struct {
	visible:   bool,
	window:    int,                // the window the docked panel is in (Browser_Window.id; 0: the next one that builds)
	dock:      Dev_Dock,
	panel:     Dev_Panel,
	size:      f32,                // logical px: the height (bottom) or the width (side)
	font_pt:   f32,
	density:   Dt_Density,
	float_pos: [2]f32,             // floating: from the window's top left, logical px
	float_size: [2]f32,
	float_set: bool,               // the floating panel has a place (else: made when first shown)
	drag:      Dev_Drag,
	drag_from: [2]f32,             // the size / place when the drag began
	panel_rect: draw.Rect,         // where the floating panel was drawn last frame
	rect:      draw.Rect,          // where the panel was drawn last frame, docked or not
	room:      draw.Vec2,          // its size in the frame being built (dev_width, dev_height); 0: not known before layout
	room_checks, room_wrong: int,  // frames whose room was compared with the layout's result, and those where it differed
	watch:     int,
	picking:   bool,               // the element picker (Ctrl+Shift+C) is on: the page shows the element under the pointer
	hover_tab: int,
	con:       Dev_Console,
	els:       Dev_Elements,
	net:       Dev_Network,
	app:       Dev_Application,
	perf:      Dev_Performance,
	mem:       Dev_Memory,
}

dev: Devtools

devtools_init :: proc(app: ^App) {
	devtools_apply_prefs(&app.prefs)
	if app.cfg.show_console && !dev.visible { dev.visible, dev.panel = true, .Console }   // browser.console.visible: the older way to ask for it
	dev.watch = config.watch(&app.prefs, "browser.devtools.", proc(user: rawptr, name: string, p: ^config.Prefs) { devtools_apply_prefs(p) }, app)
	app.loader.observer = {user = app, event = net_observe, block = net_blocked, throttle = net_link_for}   // devtools_net_model.odin, devtools_network.odin
}

devtools_destroy :: proc(app: ^App) {
	devtools_window_destroy(app)
	config.unwatch(&app.prefs, dev.watch)
	console_panel_destroy()
	elements_destroy()
	network_destroy()
	application_destroy()
	performance_destroy()
	memory_destroy()
	dev = {}
}

devtools_apply_prefs :: proc(p: ^config.Prefs) {
	dev.visible = config.bool_of(p, "browser.devtools.visible")
	dock, panel := config.string_of(p, "browser.devtools.dock"), config.string_of(p, "browser.devtools.tab")
	for name, d in DEV_DOCK_NAMES { if name == dock { dev.dock = d } }
	for name, d in DEV_PANEL_NAMES { if name == panel { dev.panel = d } }
	if dev.drag == .None { dev.size = f32(config.float_of(p, "browser.devtools.size")) }
	dev.font_pt = f32(config.float_of(p, "browser.devtools.font_size"))
	dev.density = config.string_of(p, "browser.devtools.density") == "comfortable" ? .Comfortable : .Compact
	console_apply_prefs(p)
	network_apply_prefs(p)
	if the_app != nil { console_arm_all(the_app) }   // (the pages describe their console arguments while the panel is open)
}

// What the panel's own state asks of the preferences (they are what is saved, and what about:config shows).
devtools_save :: proc(app: ^App) {
	set_pref_bool(app, "browser.devtools.visible", dev.visible)
	set_pref_string(app, "browser.devtools.dock", DEV_DOCK_NAMES[dev.dock])
	set_pref_string(app, "browser.devtools.tab", DEV_PANEL_NAMES[dev.panel])
	set_pref_string(app, "browser.devtools.size", fmt.tprintf("%d", int(dev.size)))
}

set_pref_string :: proc(app: ^App, name, value: string) {
	if config.value_string(&app.prefs, config.ref_of(&app.prefs, name)) == value { return }   // (a Float preference too: string_of asserts on one)
	if err := config.set_from_string(&app.prefs, name, value, .User); err != .None {
		ui.toast(.Warn, "%s: %s", name, config.set_error_text(err))
	}
}

// A preference of any kind from its text (what a menu of the panel sets).
dev_set_pref :: proc(app: ^App, name: string, value: string) {
	if err := config.set_from_string(&app.prefs, name, value, .User); err != .None {
		ui.toast(.Warn, "%s: %s", name, config.set_error_text(err))
	}
}

dev_toggle_pref :: proc(app: ^App, name: string) {
	dev_set_pref(app, name, config.bool_of(&app.prefs, name) ? "false" : "true")
}

// Whether the panel belongs to the window being built (the docked one: the other windows show none).
devtools_here :: proc(app: ^App) -> bool { return dev.window == 0 || app.active == nil || dev.window == app.active.id }

// The docked panel is in the window that asked for it (and follows its tab when the tab moves to another window).
devtools_claim :: proc(app: ^App) { dev.window = app.active != nil ? app.active.id : 0 }

devtools_toggle :: proc(app: ^App) {
	dev.visible = !dev.visible
	if !dev.visible { dev.picking = false } else { devtools_claim(app) }
	set_pref_bool(app, "browser.devtools.visible", dev.visible)
	request_frames(app, 3)
}

devtools_open :: proc(app: ^App, panel: Dev_Panel) {
	changed := !dev.visible || dev.panel != panel
	if !dev.visible { devtools_claim(app) }
	dev.visible, dev.panel = true, panel
	if changed { devtools_save(app) }
	request_frames(app, 3)
}

// The panel closes if it is open on `panel`, else opens on it (Ctrl+Shift+J).
devtools_toggle_panel :: proc(app: ^App, panel: Dev_Panel) {
	if dev.visible && dev.panel == panel { devtools_toggle(app) } else { devtools_open(app, panel) }
}

devtools_set_dock :: proc(app: ^App, dock: Dev_Dock) {
	dev.dock = dock
	if !dev.visible { devtools_claim(app) }
	dev.visible = true
	devtools_save(app)
	request_frames(app, 3)
}

// Ctrl+Shift+C: opens the Elements tab and starts (or stops) picking an element in the page.
devtools_pick :: proc(app: ^App) {
	if !dev.visible || dev.panel != .Elements { devtools_open(app, .Elements) }
	dev.picking = !dev.picking
	request_frames(app, 3)
}

// Ctrl and + / - / 0: the text of the panel larger, smaller, as it was.
devtools_zoom :: proc(app: ^App, step: f32) {
	pt := step == 0 ? 12 : clamp(dev.font_pt + step, 8, 24)
	dev_set_pref(app, "browser.devtools.font_size", fmt.tprintf("%g", pt))
	request_frames(app, 2)
}

// Whether the panel is shown for `t` (a web page), and where.
devtools_dock :: proc(app: ^App, t: ^Tab) -> (Dev_Dock, bool) {
	if !dev.visible || t == nil || t.kind != .Web || platform.is_fullscreen(active_window(app).win) || devtools_detached() { return {}, false }
	if app.active != nil {
		if dev.window == 0 || window_by_id(app, dev.window) == nil { dev.window = app.active.id }
		if dev.window != app.active.id { return {}, false }
	}
	return dev.dock, true
}

////////////////////////////////
// The panel

// The panel's size in the frame being built. A box's own rect and size are those of the LAST frame's layout: a panel that
// sizes its columns, tabs and fields from them is one frame behind a splitter or a window being dragged (its content looks
// like the previous width, squeezed or stretched into the new box). The size the panel was asked for is known before
// layout: pixels as given, else `fill` (what the caller's room is: the window), else the last frame's.
dev_width :: proc() -> f32 { return dev.room.x > 0 ? dev.room.x : dev.rect.max.x - dev.rect.min.x }
dev_height :: proc() -> f32 { return dev.room.y > 0 ? dev.room.y : dev.rect.max.y - dev.rect.min.y }

dev_room_of :: proc(place: ui.Style_Mod, fill: draw.Vec2) -> draw.Vec2 {
	room := fill
	if w, ok := place.width.?; ok && w.kind == .Pixels { room.x = w.value }
	if h, ok := place.height.?; ok && h.kind == .Pixels { room.y = h.value }
	return room
}

// The panel under the box `next` sized: a header (tabs, dock, close) and the tab's content. `fill`: the room a side that is
// not in pixels takes (the window's size where the panel fills it; 0 where it is not known before layout).
devtools_panel :: proc(app: ^App, t: ^Tab, floating := false, place := ui.Style_Mod{}, fill := draw.Vec2{}) {
	dt_begin(app)
	// the check behind dev_width: what the last frame took for the panel's width is the width its layout gave the box (the
	// box as it is now, before this build, is that layout's); counted for the tests (stats: devtoolsRoomWrong)
	if pb := ui.box_from_key(ui.key_from_string(ui.parent_box().key, "###dt_panel")); pb != nil && dev.room.x > 0 && pb.rect.max.x > pb.rect.min.x {
		dev.room_checks += 1
		if abs((pb.rect.max.x - pb.rect.min.x) - dev.room.x) > 1.5 { dev.room_wrong += 1 }
	}
	dev.room = dev_room_of(place, fill)
	ui.set_menu_item_height(dev.density == .Comfortable ? 2.1 : 1.85)   // dense menus for the panel's own (toolkit 0.19)
	defer ui.set_menu_item_height(0)
	if ui.style({font_size = dtm.fs, text_pad = dt_px(4)}) {
		flags := ui.Box_Flags{.Draw_Background}
		if floating { flags += {.Draw_Border, .Draw_Shadow} }
		mod := place
		mod.axis, mod.radius = .Y, 0
		if floating { mod.border = dtc.border }
		ui.next(mod)
		panel := ui.build_box(flags, "###dt_panel")
		dev.rect = panel.rect
		if ui.parent(panel) {
			devtools_header(app, t, floating)
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			body := ui.build_box({.Clip}, "###dt_body")
			if ui.parent(body) {
				switch dev.panel {
				case .Console:     console_panel(app, t)
				case .Elements:    elements_panel(app, t)
				case .Network:     network_panel(app, t)
				case .Application: application_panel(app, t)
				case .Performance: performance_panel(app, t)
				case .Memory:      memory_panel(app, t)
				}
			}
		}
		net_media_frame_end()   // a media that was not previewed this frame is closed
	}
}

// The text size of the panel by Ctrl+wheel and Ctrl +, -, 0 while the pointer is over it: these events are the panel's
// (the chrome's shortcuts would zoom the page, the toolkit's lists would scroll). Called by main.odin's frame with the
// events of the frame; returns the others.
devtools_events :: proc(app: ^App, events: []platform.Event, in_window := false) -> []platform.Event {
	if !dev.visible && net_media_active() { net_media_release() }
	if devtools_detached() != in_window { return events }   // (the panel's rectangle is of the window it is in)
	if !in_window && !devtools_here(app) { return events }
	if !dev.visible || dev.rect.max.x <= dev.rect.min.x || ui.ctx_menu_any_open() { return events }
	taken := false
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		take := false
		#partial switch e.kind {
		case .Scroll:
			if .Ctrl in e.mods && draw.rect_contains(dev.rect, e.pos) {
				take = true
				if e.delta.y != 0 { devtools_zoom(app, e.delta.y < 0 ? 1 : -1) }
			}
		case .Key_Press:
			if (e.mods == {.Ctrl} || e.mods == {.Ctrl, .Shift}) && draw.rect_contains(dev.rect, ui.mouse_pos()) {
				#partial switch e.key {
				case .Equal, .Num_Add: take = true; devtools_zoom(app, 1)
				case .Minus, .Num_Subtract: take = true; devtools_zoom(app, -1)
				case .N0: take = true; devtools_zoom(app, 0)
				}
			}
		}
		if take { taken = true } else { append(&out, e) }
	}
	return taken ? out[:] : events
}

Dev_Tab_Info :: struct {
	badges: [2]string,
	tones:  [2]draw.Color,
	count:  int,
}

@(private = "file")
Tab_Draw :: struct {
	icon:  Dt_Icon,
	label: string,
	on, hot, down: bool,
	t:     f32,          // the underline's growth (0..1)
	badges: [2]string,
	tones:  [2]draw.Color,
	badge_w: [2]f32,
	label_w: f32,
	warn:   bool,         // a dot on the icon: the tab is held to a network speed
}

@(private = "file")
tab_width :: proc(label: string, icon_w: f32, badges: [2]string) -> (w, lw: f32, bw: [2]f32) {
	lw = dt_w(dtm.ui_font, dtm.fs, label)
	w = dt_px(8) + icon_w + dt_px(5) + lw + dt_px(8)
	for b, i in badges {
		if b == "" { continue }
		bw[i] = max(dt_w(dtm.ui_font, dtm.fs * 0.82, b) + dt_px(8), dtm.fs * 1.12)
		w += bw[i] + dt_px(4)
	}
	return
}

@(private = "file")
tab_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tab_Draw)(user)
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	if d.down { draw.rect(dc, {{r.min.x, r.min.y + dt_px(3)}, {r.max.x, r.max.y - dt_px(3)}}, dtc.press, dtm.radius) } else if d.hot && !d.on {
		draw.rect(dc, {{r.min.x, r.min.y + dt_px(3)}, {r.max.x, r.max.y - dt_px(3)}}, dtc.hover, dtm.radius)
	}
	col := d.on ? dtc.text : (d.hot ? dtc.text : dtc.weak)
	x := r.min.x + dt_px(8)
	dt_icon(dc, d.icon, {math.round(x + dtm.icon * 0.5), cy}, dtm.icon, d.on ? dtc.accent : col, dtm.sc)
	if d.warn { rr := dt_px(3); draw.rect(dc, {{x + dtm.icon - rr, cy - dtm.icon * 0.5 - rr * 0.3}, {x + dtm.icon + rr, cy - dtm.icon * 0.5 + rr * 1.7}}, draw.Color{0.93, 0.62, 0.10, 1}, rr) }
	x += dtm.icon + dt_px(5)
	x += dt_text(dc, dtm.ui_font, dtm.fs, x, cy, col, d.label) + dt_px(4)
	for bt, i in d.badges {
		if bt == "" { continue }
		w := d.badge_w[i]
		bh := dtm.fs * 1.12
		draw.rect(dc, {{x, cy - bh * 0.5}, {x + w, cy + bh * 0.5}}, d.tones[i], bh * 0.5)
		tw := dt_w(dtm.ui_font, dtm.fs * 0.82, bt)
		dt_text(dc, dtm.ui_font, dtm.fs * 0.82, x + (w - tw) * 0.5, cy, draw.Color{1, 1, 1, 1}, bt)
		x += w + dt_px(4)
	}
	if d.t > 0.01 {
		w := (r.max.x - r.min.x - dt_px(6)) * d.t
		cx := (r.min.x + r.max.x) * 0.5
		th := dt_px(2)
		draw.rect(dc, {{cx - w * 0.5, r.max.y - th}, {cx + w * 0.5, r.max.y}}, dtc.accent, 0)
	}
}

// The numbers the tabs show next to their names.
@(private = "file")
tab_info :: proc(t: ^Tab, p: Dev_Panel) -> (badges: [2]string, tones: [2]draw.Color) {
	if t == nil { return }
	#partial switch p {
	case .Console:
		e, w := console_counts(t)
		if e > 0 { badges[0], tones[0] = dt_frame_str(fmt.tprintf("%d", e)), dtc.bad }
		if w > 0 { badges[1], tones[1] = dt_frame_str(fmt.tprintf("%d", w)), draw.Color{0.80, 0.55, 0.05, 1} }
	case .Network:
		n := len(t.net.entries)
		if n > 0 {
			errs := 0
			for &e in t.net.entries { if e.failed || e.status >= 400 { errs += 1 } }
			badges[0], tones[0] = dt_frame_str(fmt.tprintf("%d", n)), with_alpha(dtc.weak, 0.55)
			if errs > 0 { badges[1], tones[1] = dt_frame_str(fmt.tprintf("%d", errs)), dtc.bad }
		}
	}
	return
}

@(private = "file")
devtools_header :: proc(app: ^App, t: ^Tab, floating: bool) {
	if dt_bar("###dt_header", dtm.tab) {
		// a floating panel is moved by its header: this box takes the press under the buttons
		dt_gap(2)
		pick := dt_btn("###dt_pick", .Inspect, tooltip = "Select an element in the page to inspect it", shortcut = cmd_key("view.devtools_pick"), on = dev.picking)
		if pick.clicked { devtools_pick(app) }
		dt_vsep("###dt_hs0")
		dt_gap(2)

		// the tabs that fit, then a chevron for the others
		right_w := dtm.btn * 3 + dt_px(8) * 4 + dtm.line
		avail := dev_width() > 0 ? dev_width() - right_w - dtm.btn - dt_px(10) - dtm.line : 1e9
		hidden: [len(Dev_Panel)]bool
		used: f32
		count := 0
		for p in Dev_Panel {
			bs, tones := tab_info(t, p)
			w, lw, bw := tab_width(DEV_PANEL_TITLES[p], dtm.icon, bs)
			if (used + w > avail && count > 0 && p != dev.panel) {
				hidden[p] = true
				continue
			}
			used += w
			count += 1
			on := dev.panel == p
			key := ui.key_from_string(ui.parent_box().key, fmt.tprintf("###dt_tab_%d", int(p)))
			grow := ui.anim(ui.key_from_string(key, "t"), on ? 1 : 0, 34)
			ui.next({width = ui.px(math.round(w)), height = ui.pct(1), cursor = .Arrow})
			tb := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###dt_tab_%d", int(p)))
			sig := ui.signal(tb)
			d := ui.frame_new(Tab_Draw)
			d.icon, d.label, d.on, d.hot, d.down, d.t = DEV_PANEL_ICONS[p], DEV_PANEL_TITLES[p], on, sig.hovering, sig.dragging && sig.hovering, grow
			d.badges, d.tones, d.badge_w, d.label_w = bs, tones, bw, lw
			d.warn = p == .Network && net_profile_active(net_profile_of(t))
			tb.custom, tb.custom_user = tab_paint, d
			ui.a11y_set(tb, {role = .Tab, name = DEV_PANEL_TITLES[p], selected = on, position = int(p) + 1, set_size = len(Dev_Panel)})
			if sig.clicked && !on {
				dev.panel = p
				if p != .Elements { dev.picking = false }
				devtools_save(app)
				request_frames(app, 2)
			}
			dt_tip(sig, DEV_PANEL_TITLES[p])
		}
		any_hidden := false
		for h in hidden { if h { any_hidden = true } }
		if any_hidden {
			key := ui.key_from_u64(ui.key_from_string(ui.parent_box().key, "###dt_more"), 0xd0d0)
			sig := dt_btn("###dt_more", .Chevron_Right, tooltip = "More tabs", on = ui.ctx_menu_is_open(key))
			if sig.clicked {
				if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else { ui.ctx_menu_open_rect(key, sig.box.rect, sig.box.key) }
			}
			if ui.ctx_menu(key) {
				for p in Dev_Panel {
					if !hidden[p] { continue }
					if ui.menu_item(fmt.tprintf("%s###dt_more_%d", DEV_PANEL_TITLES[p], int(p)), icon = "", checked = dev.panel == p).clicked {
						dev.panel = p
						devtools_save(app)
					}
				}
			}
		}

		// what is left of the header: a floating panel is moved by it
		ui.next({width = ui.fill(), height = ui.pct(1)})
		grab := ui.build_box({.Clickable}, "###dt_grab")
		gs := ui.signal(grab)
		if dev.dock == .Floating { grab.cursor = .Move; devtools_float_drag(app, gs, .Move) }

		// settings, dock, close
		skey := dt_menu_btn("###dt_settings", .Kebab, tooltip = "Customize and control the developer tools", caret = false)
		if ui.ctx_menu(skey, dt_px(230)) { devtools_settings_menu(app, t) }
		dkey := dt_menu_btn("###dt_dock", DEV_DOCK_ICONS[dev.dock], tooltip = "Dock side", caret = false)
		if ui.ctx_menu(dkey, dt_px(240)) {
			for d in Dev_Dock {
				if ui.menu_item(fmt.tprintf("%s###dt_dock_%d", DEV_DOCK_TITLES[d], int(d)), cmd_key(DEV_DOCK_COMMANDS[d]), checked = dev.dock == d && !devtools_detached(), icon = "").clicked { if devtools_detached() { devtools_attach(app) }; devtools_set_dock(app, d) }
			}
			ui.menu_separator()
			if devtools_detached() {
				if ui.menu_item("Dock back into the browser window###dt_dock_win", cmd_key("view.devtools_detach")).clicked { devtools_attach(app) }
			} else {
				if ui.menu_item("Open in a separate window###dt_dock_win", cmd_key("view.devtools_detach")).clicked { devtools_detach(app) }
			}
		}
		dt_gap(2)
		dt_vsep("###dt_hs1")
		dt_gap(2)
		if dt_btn("###dt_close", .Close, tooltip = "Close the developer tools", shortcut = "F12").clicked { devtools_toggle(app) }
		dt_gap(2)
	}
	_ = floating
}

@(private = "file")
devtools_settings_menu :: proc(app: ^App, t: ^Tab) {
	if ui.menu_submenu("Text size###dt_m_size") {
		for pt in ([?]f32{10, 11, 12, 13, 14, 16, 18}) {
			if ui.menu_item(fmt.tprintf("%g px###dt_m_pt%g", pt, pt), checked = dev.font_pt == pt).clicked { dev_set_pref(app, "browser.devtools.font_size", fmt.tprintf("%g", pt)) }
		}
		ui.menu_separator()
		if ui.menu_item("Larger###dt_m_big", "Ctrl +").clicked { devtools_zoom(app, 1) }
		if ui.menu_item("Smaller###dt_m_small", "Ctrl \u2212").clicked { devtools_zoom(app, -1) }
		if ui.menu_item("Reset###dt_m_reset", "Ctrl 0").clicked { devtools_zoom(app, 0) }
	}
	if ui.menu_submenu("Density###dt_m_density") {
		if ui.menu_item("Compact###dt_m_dc", checked = dev.density == .Compact).clicked { dev_set_pref(app, "browser.devtools.density", "compact") }
		if ui.menu_item("Comfortable###dt_m_dm", checked = dev.density == .Comfortable).clicked { dev_set_pref(app, "browser.devtools.density", "comfortable") }
	}
	if ui.menu_submenu("Theme###dt_m_theme") {
		ui.menu_heading("The panel follows the browser's theme")
		for np, i in ui.NAMED_PALETTES {
			if ui.menu_item(fmt.tprintf("%s###dt_m_th%d", np.name, i), checked = strings.equal_fold(app.cfg.ui_theme, np.name)).clicked { dev_set_pref(app, "browser.ui.theme", np.name) }
		}
	}
	ui.menu_separator()
	#partial switch dev.panel {
	case .Console: console_settings_items(app, t)
	case .Network: network_settings_items(app, t)
	}
	ui.menu_separator()
	if ui.menu_item("Select an element in the page###dt_m_pick", cmd_key("view.devtools_pick")).clicked { devtools_pick(app) }
	if ui.menu_item("Open the command palette###dt_m_palette", "Ctrl+Shift+P").clicked { palette_toggle(app) }
	if ui.menu_item("Reset the layout of the panels###dt_m_layout").clicked { devtools_reset_layout(app) }
	if ui.menu_item("Open about:config for the developer tools###dt_m_cfg").clicked { open_in_new_tab(app, "about:config?q=browser.devtools", origin = .User) }
	if ui.menu_item("Close the developer tools###dt_m_close", "F12").clicked { devtools_toggle(app) }
}

// Sizes, columns and panes as they came.
devtools_reset_layout :: proc(app: ^App) {
	dev_set_pref(app, "browser.devtools.size", "300")
	dev_set_pref(app, "browser.devtools.font_size", "12")
	dev_set_pref(app, "browser.devtools.density", "compact")
	network_reset_layout(app)
	elements_reset_layout(app)
	request_frames(app, 2)
}

////////////////////////////////
// Where it goes in the window

// The room the panel takes (physical px): its size, but never more than 70 % of the window along its axis.
devtools_extent :: proc(app: ^App, vertical: bool) -> f32 {
	room := vertical ? f32(active_window(app).win.size.x) : f32(active_window(app).win.size.y)
	return clamp(dev.size * ui.scale(), 80, math.max(room * 0.7, 80))
}

// A bar between the page and the panel: dragging it resizes the panel (the toolkit's splitter; the panel is after the bar
// unless it is docked on the left). Not a Tab stop: the page's and the panel's focus order stay as they were.
devtools_splitter :: proc(app: ^App, vertical: bool) {
	room := vertical ? f32(active_window(app).win.size.x) : f32(active_window(app).win.size.y)
	r := ui.splitter("###dt_split", vertical ? .X : .Y, &dev.size, 80, math.max(room / ui.scale() - 160, 80),
		{after = dev.dock != .Left, thickness = dt_px(5), no_keyboard = true})
	if r.dragging {
		dev.drag = .Size
		request_frames(app, 2)
	}
	if !r.dragging && dev.drag == .Size {
		dev.drag = .None
		set_pref_string(app, "browser.devtools.size", fmt.tprintf("%d", int(dev.size)))
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
		win := [2]f32{f32(active_window(app).win.size.x), f32(active_window(app).win.size.y)} / sc
		if what == .Move {
			dev.float_pos = {clamp(dev.drag_from[0] + d.x, 0, math.max(win.x - 120, 0)), clamp(dev.drag_from[1] + d.y, 0, math.max(win.y - 60, 0))}
		} else {
			dev.float_size = {clamp(dev.drag_from[0] + d.x, 260, math.max(win.x - dev.float_pos[0], 260)), clamp(dev.drag_from[1] + d.y, 160, math.max(win.y - dev.float_pos[1], 160))}
		}
		request_frames(app, 2)
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
	win := [2]f32{f32(active_window(app).win.size.x), f32(active_window(app).win.size.y)} / sc
	if !dev.float_set {
		dev.float_size = {math.max(win.x * 0.55, 360), math.max(win.y * 0.5, 240)}
		dev.float_pos = {win.x - dev.float_size[0] - 24, win.y - dev.float_size[1] - 40}
		dev.float_set = true
	}
	dev.float_size = {clamp(dev.float_size[0], 260, math.max(win.x, 260)), clamp(dev.float_size[1], 160, math.max(win.y, 160))}
	dev.float_pos = {clamp(dev.float_pos[0], 0, math.max(win.x - dev.float_size[0], 0)), clamp(dev.float_pos[1], 0, math.max(win.y - dev.float_size[1], 0))}
	devtools_panel(app, t, true, {width = ui.px(dev.float_size[0] * sc), height = ui.px(dev.float_size[1] * sc), fixed_x = dev.float_pos[0] * sc, fixed_y = dev.float_pos[1] * sc})
	if b := ui.box_from_key(ui.key_from_string(ui.parent_box().key, "###dt_panel")); b != nil {
		dev.panel_rect = b.rect
		// the corner: a grip that resizes
		g := math.round(ui.font_size() * 1.1)
		ui.next({width = ui.px(g), height = ui.px(g), fixed_x = b.rect.max.x - b.rect.min.x - g, fixed_y = b.rect.max.y - b.rect.min.y - g, cursor = .Resize_NWSE})
		gb := ui.build_box({.Clickable}, "###dt_corner")
		gs := ui.signal(gb)
		d := ui.frame_new(Dt_Btn_Draw)
		d.hot = gs.hovering || dev.drag == .Corner
		gb.custom, gb.custom_user = corner_grip_draw, d
		devtools_float_drag(app, gs, .Corner)
	}
}

@(private = "file")
corner_grip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dt_Btn_Draw)(user)
	r := b.rect
	s := max(math.round(ui.scale()), 1)
	col := d.hot ? dtc.accent : dtc.faint
	for i in 0 ..< 3 {
		for j in 0 ..= i {
			x := r.max.x - 2 * s - f32(j) * 3 * s
			y := r.max.y - 2 * s - f32(i - j) * 3 * s
			draw.rect(dc, {{x - s, y - s}, {x, y}}, col)
		}
	}
}

// The floating panel takes the pointer where it is: the page under it gets nothing.
devtools_captures :: proc(pos: draw.Vec2) -> bool {
	return dev.visible && !devtools_detached() && devtools_here(the_app) && dev.dock == .Floating && draw.rect_contains(dev.panel_rect, pos)
}

////////////////////////////////
// What the page draws for the panel

// The box of the element the Elements tab hovers or has selected, over the page (Chromium's colors: content blue, padding
// green, border yellow). Called by page_draw for a page that is painted now.
devtools_overlay :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, area: draw.Rect) {
	if !dev.visible || dev.panel != .Elements || t == nil || t.page == nil || t.kind != .Web || !devtools_here(app) { return }
	h := dev.els.hover != base.NIL_HANDLE ? dev.els.hover : dev.els.selected
	if dev.picking { h = dev.els.picked }
	if h == base.NIL_HANDLE { return }
	elements_overlay(app, t, dc, area, h)
}

// "Inspect" of the page's context menu: the panel shows the element.
devtools_inspect :: proc(app: ^App, t: ^Tab, h: base.Handle) {
	if t == nil || t.page == nil { return }
	devtools_open(app, .Elements)
	elements_select(t, h)
}

// A preference of the registry, read where the panel needs it.
config_string :: proc(app: ^App, name: string) -> string { return config.string_of(&app.prefs, name) }
config_int :: proc(app: ^App, name: string) -> i64 { return config.int_of(&app.prefs, name) }
config_float :: proc(app: ^App, name: string) -> f64 { return config.float_of(&app.prefs, name) }

// A float preference set while a drag goes on (no toast on a refused value).
set_pref_quiet :: proc(app: ^App, name: string, v: f32) {
	_ = config.set_from_string(&app.prefs, name, fmt.tprintf("%.3f", v), .User)
}

_ :: page
_ :: strings
