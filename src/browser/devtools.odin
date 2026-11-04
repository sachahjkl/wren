package browser

// The developer tools: a native view of the chrome (not a page), docked under the page, at its right or its left, or
// floating over it, with panels (Console, Elements, Network, Application, Performance, Memory) in the toolkit's dock
// (ui.Dock, docs/docking.md of the toolkit): stacks of tabs the user drags to split, join, float and dock back, every target
// also in a stack's menu; browser.devtools.layout keeps it (devtools_layout.odin). F12 / Ctrl+Shift+I open and
// close it, Ctrl+Shift+J opens the Console, Ctrl+Shift+C picks an element of the page; "Inspect" in the page's context menu
// opens Elements on the element under the pointer. With the keyboard in them, Ctrl+F finds in the panel (devtools_take_keys)
// and Escape shows the Console under the panel and hides it again (devtools_drawer_toggle). The tabs are in
// devtools_console.odin, devtools_elements.odin, devtools_network.odin, devtools_application.odin, devtools_performance.odin
// and devtools_memory.odin; the interface parts they share (icons, buttons, lists, the filter field) are in devtools_kit.odin and devtools_icons.odin.
//
// State and preferences: browser.devtools.* (visible, dock, tab, size, layout, font size, density, and what each panel keeps:
// its filters, its columns, its panes). The panel takes room from the page (build_ui puts it next to the page's box, so
// page_rect shrinks and the layout follows); floating, it is a box over the page that is moved by its top strip and
// resized by its corner, and takes the pointer where it is (devtools_captures). Closed, it costs nothing: nothing is
// built, and the loader's observer keeps only what the Network tab needs for the tabs that have requests.
//
// The panel reads what the shell owns (the tab's console lines, its request log); what it shows of the page's document is
// copied while the page is not running (shell_nested: a chrome frame made while a script holds the thread reads nothing
// of the page).

import "core:fmt"
import "core:math"
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

// The room of the docked panel (CSS px): from a header and a row to all the window but a strip of the page.
DEV_DOCK_MIN_PX :: 40
DEV_PAGE_MIN_PX :: 40
// The floating panel's smallest size, and what of it stays in the window when it is moved (CSS px).
DEV_FLOAT_MIN :: [2]f32{160, 80}
DEV_FLOAT_KEEP :: [2]f32{120, 60}

// The first shortcut of a command, as a menu shows it ("" when it has none).
cmd_key :: proc(app: ^App, name: string) -> string {
	c := command(app, name)
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
	{name = "browser.devtools.size", kind = .Float, default = {f = 300}, bounded = true, min = DEV_DOCK_MIN_PX, max = 4000, unit = "px",
		description = "Height of the developer tools when they sit under the page, width when they sit at its side (CSS pixels)."},
	{name = "browser.devtools.layout", kind = .String, default = {s = DEV_LAYOUT_DEFAULT},
		description = "Where the developer tools' panels are: their stacks of tabs (* before the one shown), the splits between them (x: side by side, y: one above the other, the first's share, f: the second folded) and the floating ones (@x,y,width,height), as one line. Drag a tab to change it; its stack's menu does it from the keyboard."},
	{name = "browser.devtools.font_size", kind = .Float, default = {f = 12}, bounded = true, min = 8, max = 24, unit = "px",
		description = "Size of the text of the developer tools (CSS pixels). Ctrl and the plus, minus or zero keys change it while the panel has the pointer."},
	{name = "browser.devtools.density", kind = .String, default = {s = "compact"}, choices = {"compact", "comfortable"},
		description = "How tightly the developer tools' rows and toolbars are spaced."},
	// The detached window's outer rectangle on the screen, remembered between sessions like the browser window's (session.odin).
	// A width or height of 0 means "not saved yet": the window opens at its default size and the system places it. The rectangle
	// is in physical screen pixels (platform.Placement), fitted to a monitor that is there when it is restored (set_placement).
	{name = "browser.devtools.window.x", kind = .Int, default = {i = 0}, bounded = true, min = -1_000_000, max = 1_000_000, unit = "px",
		description = "Left edge of the detached developer tools window on the screen, in physical pixels (remembered between sessions)."},
	{name = "browser.devtools.window.y", kind = .Int, default = {i = 0}, bounded = true, min = -1_000_000, max = 1_000_000, unit = "px",
		description = "Top edge of the detached developer tools window on the screen, in physical pixels (remembered between sessions)."},
	{name = "browser.devtools.window.width", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 100_000, unit = "px",
		description = "Width of the detached developer tools window, in physical pixels (0: open at the default size)."},
	{name = "browser.devtools.window.height", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 100_000, unit = "px",
		description = "Height of the detached developer tools window, in physical pixels (0: open at the default size)."},
	{name = "browser.devtools.window.maximized", kind = .Bool, default = {b = false},
		description = "Whether the detached developer tools window was maximized when it last closed (restored maximized)."},
}

register_devtools_prefs :: proc(p: ^config.Prefs) {
	config.register(p, DEVTOOLS_PREFS[:])
	console_register_prefs(p)
	network_register_prefs(p)
	elements_register_prefs(p)
}

Dev_Drag :: enum u8 { None, Size, Move, Corner }

// The developer tools of one browser window (Window_Own.devtools): docked in it or in a window of their own (`win`), they show
// that window's current tab, go with a tab they show that moves to another window (tab_move), and close with their window.
Devtools :: struct {
	visible:   bool,
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
	win:       ^Dev_Window,        // detached: their own window (devtools_window.odin)
	want_win:  bool,               // ... asked for, made after the frame that asked
	picking:   bool,               // the element picker (Ctrl+Shift+C) is on: the page shows the element under the pointer
	find:      Dev_Panel,          // Ctrl+F asked this panel to find (`find_asked`): its search field takes the keyboard (dt_find_here)
	find_asked: bool,
	hover_tab: int,
	layout:    ui.Dock,            // where the panels are (browser.devtools.layout); `panel`: the one shown last
	shown:     bit_set[Dev_Panel], // the panels the last frame showed
	frame_tab: ^Tab,               // the tab the panel is built for this frame (what its tabs' numbers are of)
	con:       Dev_Console,
	els:       Dev_Elements,
	net:       Dev_Network,
	app:       Dev_Application,
	perf:      Dev_Performance,
	mem:       Dev_Memory,
}

// The developer tools of the window being framed (the front one between frames): every procedure of the panel reads these.
dev :: proc() -> ^Devtools {
	if the_app == nil { return &dev_none }
	return &active_window(the_app).own.devtools
}

// (an App's that is not the_app: a unit test's)
@(private = "file") dev_none: Devtools

devtools_init :: proc(app: ^App) {
	devtools_view_init(app, dev(), true)
	if app.cfg.show_console && !dev().visible { dev().visible, dev().panel = true, .Console }   // browser.console.visible: the older way to ask for it
	app.watches[.Devtools] = config.watch(&app.prefs, "browser.devtools.", proc(user: rawptr, name: string, p: ^config.Prefs) { devtools_pref_changed((^App)(user), name, p) }, app)
	network_apply_prefs(app, &app.prefs)
	console_apply_prefs(&app.prefs)
	console_arm_all(app)
	app.loader.observer = {user = app, event = net_observe, block = net_blocked, throttle = net_link_for}   // devtools_net_model.odin, devtools_network.odin
}

// The developer tools of a window that opens: where they sit, their tab, their size and text from the preferences; shown only in
// the first window (`shown`: the preference browser.devtools.visible), closed in the others until asked for there.
devtools_view_init :: proc(app: ^App, d: ^Devtools, shown: bool) {
	p := &app.prefs
	d.visible = shown && config.bool_of(p, "browser.devtools.visible")
	view_from_prefs(d, p, "")
}

@(private = "file")
view_from_prefs :: proc(d: ^Devtools, p: ^config.Prefs, name: string) {
	if name == "" || name == "browser.devtools.dock" {
		dock := config.string_of(p, "browser.devtools.dock")
		for n, x in DEV_DOCK_NAMES { if n == dock { d.dock = x } }
	}
	if name == "" || name == "browser.devtools.tab" {
		panel := config.string_of(p, "browser.devtools.tab")
		for n, x in DEV_PANEL_NAMES { if n == panel { d.panel = x } }
	}
	if (name == "" || name == "browser.devtools.size") && d.drag == .None { d.size = f32(config.float_of(p, "browser.devtools.size")) }
	d.font_pt = f32(config.float_of(p, "browser.devtools.font_size"))
	d.density = config.string_of(p, "browser.devtools.density") == "comfortable" ? .Comfortable : .Compact
	// the layouts: every window's (the panels' places); the tab shown is of the window it was chosen in
	if name == "" || name == "-" || name == "browser.devtools.layout" { dev_layout_load(d, p, name == "") }
	if name == "" || name == "-" || name == "browser.devtools.elements.layout" { elements_layout_load(&d.els, p, name == "") }
	if name == "" || name == "browser.devtools.tab" { ui.dock_activate(&d.layout, u32(d.panel)) }
}

// Whether the developer tools `d` show `p`: its tab on top of its stack, the stack not folded away.
dev_shows :: proc(d: ^Devtools, p: Dev_Panel) -> bool {
	return d.visible && ui.dock_shown(&d.layout, u32(p))
}

// A preference of the developer tools changed (about:config, a menu of a panel, devtools_save). Where they sit, their tab, their
// size and whether they are shown are of the window the user is in (the one that saved them); the text size, the density and
// what the tabs keep are every window's.
devtools_pref_changed :: proc(app: ^App, name: string, p: ^config.Prefs) {
	if name == "browser.devtools.visible" {
		d := dev()
		d.visible = config.bool_of(p, name)
		if !d.visible { d.picking = false }
	}
	view_from_prefs(dev(), p, name)
	for w in app.windows { if w != app.active { view_from_prefs(&w.own.devtools, p, "-") } }
	console_apply_prefs(p)
	network_apply_prefs(app, p)
	console_arm_all(app)   // (the pages describe their console arguments while a panel is open)
	for w in app.windows { window_request(app, w, 2) }
}

// The developer tools of the active window give up what they hold (their window closes, or the browser ends).
devtools_view_destroy :: proc(app: ^App) {
	devtools_window_destroy(app)
	console_panel_destroy()
	elements_destroy()
	ui.dock_destroy(&dev().layout)
	network_destroy(app)
	application_destroy()
	performance_destroy()
	memory_destroy(app)
	dev()^ = {}
	network_sync_observer(app)
	console_arm_all(app)
}

// The end of the browser: the front window's developer tools (the others' went with windows_shutdown_begin), then what the process
// keeps for them.
devtools_destroy :: proc(app: ^App) {
	devtools_view_destroy(app)
	config.unwatch(&app.prefs, app.watches[.Devtools])
	net_media_release(app)
	net_profiles_destroy()
	delete(app.net_prefs.profile)
	app.net_prefs.profile = ""
	net_destroy_owner(app)
}

// Whether any window shows its developer tools (the loader's observer keeps bodies, the pages describe their console lines).
devtools_any_visible :: proc(app: ^App) -> bool {
	if app == nil { return dev_none.visible }
	if len(app.windows) == 0 { return app.bare.own.devtools.visible }
	for w in app.windows { if w.own.devtools.visible { return true } }
	return false
}

// Whether any window's developer tools are open on `panel`.
devtools_any_showing :: proc(app: ^App, panel: Dev_Panel) -> bool {
	if app == nil { return dev_shows(&dev_none, panel) }
	if len(app.windows) == 0 { return dev_shows(&app.bare.own.devtools, panel) }
	for w in app.windows { if dev_shows(&w.own.devtools, panel) { return true } }
	return false
}

// The developer tools of the window that holds `t` (nil: no window holds it).
devtools_of_tab :: proc(app: ^App, t: ^Tab) -> (^Devtools, ^Browser_Window) {
	if app == nil { return &dev_none, nil }
	if len(app.windows) == 0 { return &app.bare.own.devtools, &app.bare }
	w, _ := window_of_tab(app, t)
	if w == nil { return nil, nil }
	return &w.own.devtools, w
}

// A window's developer tools by its id (what a timer of a panel keeps: the window may have closed). The bare window's is id 0.
devtools_of_window_id :: proc(app: ^App, id: int) -> (^Browser_Window, ^Devtools) {
	if app == nil { return nil, nil }
	if len(app.windows) == 0 {
		if id != 0 { return nil, nil }
		return &app.bare, &app.bare.own.devtools
	}
	w := window_by_id(app, id)
	if w == nil { return nil, nil }
	return w, &w.own.devtools
}

// Frames for the windows whose developer tools show `panel` for `t` (its window's current tab), or for any tab when t is nil.
devtools_request_showing :: proc(app: ^App, t: ^Tab, panel: Dev_Panel) {
	if app == nil { return }
	for w in app.windows {
		d := &w.own.devtools
		if !dev_shows(d, panel) { continue }
		if t != nil && window_current_tab(app, w) != t { continue }
		window_request(app, w, 2)
	}
}

// What the panel's own state asks of the preferences (they are what is saved, and what about:config shows).
devtools_save :: proc(app: ^App) {
	set_pref_bool(app, "browser.devtools.visible", dev().visible)
	set_pref_string(app, "browser.devtools.dock", DEV_DOCK_NAMES[dev().dock])
	set_pref_string(app, "browser.devtools.tab", DEV_PANEL_NAMES[dev().panel])
	set_pref_string(app, "browser.devtools.size", fmt.tprintf("%d", int(dev().size)))
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

devtools_toggle :: proc(app: ^App) {
	dev().visible = !dev().visible
	if !dev().visible { dev().picking = false }
	set_pref_bool(app, "browser.devtools.visible", dev().visible)
	network_sync_observer(app)
	console_arm_all(app)
	request_frames(app, 3)
}

// The panel shown (in its stack, the folds that hid it open; put back with the one shown last when it is not in the layout).
devtools_open :: proc(app: ^App, panel: Dev_Panel) {
	d := dev()
	changed := !d.visible || !ui.dock_shown(&d.layout, u32(panel))
	if !ui.dock_has(&d.layout, u32(panel)) { ui.dock_add(&d.layout, u32(panel), ui.dock_with(&d.layout, u32(d.panel))) }
	ui.dock_activate(&d.layout, u32(panel))
	d.visible, d.panel = true, panel
	if changed { devtools_save(app); devtools_save_layout(app) }
	network_sync_observer(app)
	console_arm_all(app)
	request_frames(app, 3)
}

// The panels that find from Ctrl+F: their search or filter field takes the keyboard.
DEV_FIND_PANELS :: bit_set[Dev_Panel]{.Console, .Elements, .Network, .Application}

// The panel the keyboard is in: the one shown in the stack that has the focus (or, nothing focused, the one shown last while
// the pointer is over the developer tools). ok false: the keyboard is elsewhere.
devtools_keyboard_panel :: proc() -> (Dev_Panel, bool) {
	d := dev()
	if !d.visible { return {}, false }
	if leaf, _ := ui.dock_focus_leaf(&d.layout); leaf != ui.DOCK_NONE {
		if a := d.layout.nodes[leaf].active; a < u32(len(Dev_Panel)) { return Dev_Panel(a), true }
	}
	if ui.focus_key() == 0 && draw.rect_contains(d.rect, ui.mouse_pos()) { return d.panel, true }
	return {}, false
}

// The keys the developer tools take before the chrome's shortcuts (Ctrl+F is the page's find, F3 its next match) while they
// have the keyboard: Ctrl+F finds in the panel the keyboard is in, F3 / Shift+F3 go to the Elements search's next and
// previous match. Called by chrome_shortcuts, and by the panel itself (a window of its own has no chrome's shortcuts).
devtools_take_keys :: proc(app: ^App) -> bool {
	d := dev()
	p, mine := devtools_keyboard_panel()
	if !mine { return false }
	switch {
	case p in DEV_FIND_PANELS && ui.key_press(.F, {.Ctrl}): d.find, d.find_asked = p, true
	case p == .Elements && d.els.search_on && ui.key_press(.F3): d.els.find_step = 1
	case p == .Elements && d.els.search_on && ui.key_press(.F3, {.Shift}): d.els.find_step = -1
	case: return false
	}
	request_frames(app, 2)
	return true
}

// The panel closes if it shows `panel`, else opens on it (Ctrl+Shift+J).
devtools_toggle_panel :: proc(app: ^App, panel: Dev_Panel) {
	if dev_shows(dev(), panel) { devtools_toggle(app) } else { devtools_open(app, panel) }
}


devtools_set_dock :: proc(app: ^App, dock: Dev_Dock) {
	dev().dock = dock
	dev().visible = true
	devtools_save(app)
	network_sync_observer(app)
	console_arm_all(app)
	request_frames(app, 3)
}

// Ctrl+Shift+C: opens the Elements tab and starts (or stops) picking an element in the page.
devtools_pick :: proc(app: ^App) {
	if !dev_shows(dev(), .Elements) { devtools_open(app, .Elements) }
	dev().picking = !dev().picking
	request_frames(app, 3)
}

// Ctrl and + / - / 0: the text of the panel larger, smaller, as it was.
devtools_zoom :: proc(app: ^App, step: f32) {
	pt := step == 0 ? 12 : clamp(dev().font_pt + step, 8, 24)
	dev_set_pref(app, "browser.devtools.font_size", fmt.tprintf("%g", pt))
	request_frames(app, 2)
}

// Whether the panel is shown for `t` (a web page), and where.
devtools_dock :: proc(app: ^App, t: ^Tab) -> (Dev_Dock, bool) {
	if !dev().visible || t == nil || t.kind != .Web || platform.is_fullscreen(active_window(app).win) || devtools_detached() { return {}, false }
	return dev().dock, true
}

////////////////////////////////
// The panel

// The panel's size in the frame being built. A box's own rect and size are those of the LAST frame's layout: a panel that
// sizes its columns, tabs and fields from them is one frame behind a splitter or a window being dragged (its content looks
// like the previous width, squeezed or stretched into the new box). The size the panel was asked for is known before
// layout: pixels as given, else `fill` (what the caller's room is: the window), else the last frame's.
dev_width :: proc() -> f32 { return dev().room.x > 0 ? dev().room.x : dev().rect.max.x - dev().rect.min.x }
dev_height :: proc() -> f32 { return dev().room.y > 0 ? dev().room.y : dev().rect.max.y - dev().rect.min.y }

dev_room_of :: proc(place: ui.Style_Mod, fill: draw.Vec2) -> draw.Vec2 {
	room := fill
	if w, ok := place.width.?; ok && w.kind == .Pixels { room.x = w.value }
	if h, ok := place.height.?; ok && h.kind == .Pixels { room.y = h.value }
	return room
}

// The panel under the box `next` sized: the dock of its panels (devtools_layout.odin), the buttons of the panel as a whole at
// the ends of its top strips. `fill`: the room a side that is not in pixels takes (the window's size where the panel fills it;
// 0 where it is not known before layout).
devtools_panel :: proc(app: ^App, t: ^Tab, floating := false, place := ui.Style_Mod{}, fill := draw.Vec2{}) {
	dt_begin(app)
	// the check behind dev_width: what the last frame took for the panel's width is the width its layout gave the box (the
	// box as it is now, before this build, is that layout's); counted for the tests (stats: devtoolsRoomWrong)
	if pb := ui.box_from_key(ui.key_from_string(ui.parent_box().key, "###dt_panel")); pb != nil && dev().room.x > 0 && pb.rect.max.x > pb.rect.min.x {
		dev().room_checks += 1
		if abs((pb.rect.max.x - pb.rect.min.x) - dev().room.x) > 1.5 { dev().room_wrong += 1 }
	}
	dev().room = dev_room_of(place, fill)
	ui.set_menu_item_height(dev().density == .Comfortable ? 2.1 : 1.85)   // dense menus for the panel's own (toolkit 0.19)
	defer ui.set_menu_item_height(0)
	if ui.style({font_size = app.dtm.fs, text_pad = dt_px(4)}) {
		flags := ui.Box_Flags{.Draw_Background}
		if floating { flags += {.Draw_Border, .Draw_Shadow} }
		mod := place
		mod.axis, mod.radius = .Y, 0
		if floating { mod.border = app.dtc.border }
		ui.next(mod)
		panel := ui.build_box(flags, "###dt_panel")
		dev().rect = panel.rect
		if ui.parent(panel) {
			devtools_take_keys(app)
			dev_dock(app, t)
			dev().find_asked = false   // (Ctrl+F is for the panel's field of this build)
			// Escape that nothing of theirs took: the Console under the panel shown, or away again (Chrome's drawer; in the Console's own
			// stack when it is not the drawer, nothing)
			if p, mine := devtools_keyboard_panel(); mine && (p != .Console || devtools_drawer_split(dev()) != ui.DOCK_NONE) && ui.key_press(.Escape) { devtools_drawer_toggle(app) }
		}
		net_media_frame_end(app)   // a media that was not previewed this frame is closed
	}
}

// The text size of the panel by Ctrl+wheel and Ctrl +, -, 0 while the pointer is over it: these events are the panel's
// (the chrome's shortcuts would zoom the page, the toolkit's lists would scroll). Called by main.odin's frame with the
// events of the frame; returns the others.
devtools_events :: proc(app: ^App, events: []platform.Event, in_window := false) -> []platform.Event {
	if !dev().visible && net_media_active(app) && app.net_media.owner == dev() { net_media_release(app) }
	if devtools_detached() != in_window { return events }   // (the panel's rectangle is of the window it is in)
	if !dev().visible || dev().rect.max.x <= dev().rect.min.x || ui.ctx_menu_any_open() { return events }
	taken := false
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		take := false
		#partial switch e.kind {
		case .Scroll:
			if .Ctrl in e.mods && draw.rect_contains(dev().rect, e.pos) {
				take = true
				if e.delta.y != 0 { devtools_zoom(app, e.delta.y < 0 ? 1 : -1) }
			}
		case .Key_Press:
			if (e.mods == {.Ctrl} || e.mods == {.Ctrl, .Shift}) && draw.rect_contains(dev().rect, ui.mouse_pos()) {
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

devtools_settings_menu :: proc(app: ^App, t: ^Tab) {
	if ui.menu_submenu("Text size###dt_m_size") {
		for pt in ([?]f32{10, 11, 12, 13, 14, 16, 18}) {
			if ui.menu_item(fmt.tprintf("%g px###dt_m_pt%g", pt, pt), checked = dev().font_pt == pt).clicked { dev_set_pref(app, "browser.devtools.font_size", fmt.tprintf("%g", pt)) }
		}
		ui.menu_separator()
		if ui.menu_item("Larger###dt_m_big", "Ctrl +").clicked { devtools_zoom(app, 1) }
		if ui.menu_item("Smaller###dt_m_small", "Ctrl \u2212").clicked { devtools_zoom(app, -1) }
		if ui.menu_item("Reset###dt_m_reset", "Ctrl 0").clicked { devtools_zoom(app, 0) }
	}
	if ui.menu_submenu("Density###dt_m_density") {
		if ui.menu_item("Compact###dt_m_dc", checked = dev().density == .Compact).clicked { dev_set_pref(app, "browser.devtools.density", "compact") }
		if ui.menu_item("Comfortable###dt_m_dm", checked = dev().density == .Comfortable).clicked { dev_set_pref(app, "browser.devtools.density", "comfortable") }
	}
	if ui.menu_submenu("Theme###dt_m_theme") {
		ui.menu_heading("The panel follows the browser's theme")
		for np, i in ui.NAMED_PALETTES {
			if ui.menu_item(fmt.tprintf("%s###dt_m_th%d", np.name, i), checked = base.ascii_equal_fold(app.cfg.ui_theme, np.name)).clicked { dev_set_pref(app, "browser.ui.theme", np.name) }
		}
	}
	ui.menu_separator()
	#partial switch dev().panel {
	case .Console: console_settings_items(app, t)
	case .Network: network_settings_items(app, t)
	}
	ui.menu_separator()
	if ui.menu_item("Select an element in the page###dt_m_pick", cmd_key(app, "view.devtools_pick")).clicked { devtools_pick(app) }
	if ui.menu_item("Open the command palette###dt_m_palette", "Ctrl+Shift+P").clicked { palette_toggle(app) }
	// the drawer: the Console in a stack of its own under the others (Escape shows and hides it)
	if devtools_drawer_split(dev()) == ui.DOCK_NONE {
		if ui.menu_item("Show the Console under the other panels###dt_m_con_drawer", "Esc").clicked { devtools_drawer_toggle(app) }
	}
	if ui.menu_item("Reset the layout of the panels###dt_m_layout").clicked { devtools_reset_layout(app) }
	if ui.menu_item("Open about:config for the developer tools###dt_m_cfg").clicked { open_in_new_tab(app, "about:config?q=browser.devtools", origin = .User) }
	if ui.menu_item("Close the developer tools###dt_m_close", "F12").clicked { devtools_toggle(app) }
}

// Sizes, columns and panes as they came.
devtools_reset_layout :: proc(app: ^App) {
	dev_set_pref(app, "browser.devtools.size", "300")
	dev_set_pref(app, "browser.devtools.layout", DEV_LAYOUT_DEFAULT)
	dev_set_pref(app, "browser.devtools.font_size", "12")
	dev_set_pref(app, "browser.devtools.density", "compact")
	network_reset_layout(app)
	elements_reset_layout(app)
	request_frames(app, 2)
}

////////////////////////////////
// Where it goes in the window

// The docked panel as a pane of the toolkit (CSS px): from a header and a row (DEV_DOCK_MIN_PX) to all the room but a strip
// of the page (DEV_PAGE_MIN_PX). The room is what the box it is built in had at the last layout (the window's at first).
@(private = "file")
dev_dock_opts :: proc(app: ^App, vertical: bool) -> ui.Pane_Options {
	pb := ui.parent_box().rect
	room := vertical ? pb.max.x - pb.min.x : pb.max.y - pb.min.y
	if room <= 0 { room = vertical ? f32(active_window(app).win.size.x) : f32(active_window(app).win.size.y) }
	return {side = dev().dock == .Left ? .Before : .After, total = room / ui.scale(), min_size = DEV_DOCK_MIN_PX, min_other = DEV_PAGE_MIN_PX,
		thickness = dt_px(5), no_keyboard = true, title = "Developer tools"}
}

// The room the panel takes (physical px): its size, in the limits of dev_dock_opts.
devtools_extent :: proc(app: ^App, vertical: bool) -> f32 {
	axis: ui.Axis = vertical ? .X : .Y
	p: ui.Pane
	p.size[axis] = dev().size
	return math.round(ui.pane_extent(&p, axis, dev_dock_opts(app, vertical)) * ui.scale())
}

// A bar between the page and the panel: dragging it resizes the panel (the toolkit's pane; the panel is after the bar
// unless it is docked on the left). Not a Tab stop: the page's and the panel's focus order stay as they were.
devtools_splitter :: proc(app: ^App, vertical: bool) {
	axis: ui.Axis = vertical ? .X : .Y
	p: ui.Pane
	p.size[axis] = dev().size
	r := ui.pane_split("###dt_split", axis, &p, dev_dock_opts(app, vertical))
	if r.changed { dev().size = p.size[axis] }
	if r.dragging {
		dev().drag = .Size
		request_frames(app, 2)
	}
	if !r.dragging && dev().drag == .Size {
		dev().drag = .None
		set_pref_string(app, "browser.devtools.size", fmt.tprintf("%d", int(dev().size)))
	}
}

// Moving (the header) or resizing (the corner) of the floating panel.
devtools_float_drag :: proc(app: ^App, sig: ui.Signal, what: Dev_Drag) {
	sc := ui.scale()
	if sig.pressed {
		dev().drag = what
		dev().drag_from = what == .Move ? dev().float_pos : dev().float_size
	}
	if sig.dragging && dev().drag == what {
		d := sig.drag_delta / sc
		win := [2]f32{f32(active_window(app).win.size.x), f32(active_window(app).win.size.y)} / sc
		if what == .Move {
			dev().float_pos = {clamp(dev().drag_from[0] + d.x, 0, math.max(win.x - DEV_FLOAT_KEEP.x, 0)), clamp(dev().drag_from[1] + d.y, 0, math.max(win.y - DEV_FLOAT_KEEP.y, 0))}
		} else {
			dev().float_size = {clamp(dev().drag_from[0] + d.x, DEV_FLOAT_MIN.x, math.max(win.x - dev().float_pos[0], DEV_FLOAT_MIN.x)), clamp(dev().drag_from[1] + d.y, DEV_FLOAT_MIN.y, math.max(win.y - dev().float_pos[1], DEV_FLOAT_MIN.y))}
		}
		request_frames(app, 2)
	}
	if !sig.dragging && dev().drag == what { dev().drag = .None }
}

// The floating panel, built last under the window's box so it is over the page. It has a place after the first time it is
// shown: its lower right quarter of the window.
devtools_floating :: proc(app: ^App, t: ^Tab) {
	dock, on := devtools_dock(app, t)
	if !on || dock != .Floating {
		dev().panel_rect = {}
		return
	}
	sc := ui.scale()
	win := [2]f32{f32(active_window(app).win.size.x), f32(active_window(app).win.size.y)} / sc
	if !dev().float_set {
		dev().float_size = {math.max(win.x * 0.55, 360), math.max(win.y * 0.5, 240)}
		dev().float_pos = {win.x - dev().float_size[0] - 24, win.y - dev().float_size[1] - 40}
		dev().float_set = true
	}
	dev().float_size = {clamp(dev().float_size[0], DEV_FLOAT_MIN.x, math.max(win.x, DEV_FLOAT_MIN.x)), clamp(dev().float_size[1], DEV_FLOAT_MIN.y, math.max(win.y, DEV_FLOAT_MIN.y))}
	dev().float_pos = {clamp(dev().float_pos[0], 0, math.max(win.x - dev().float_size[0], 0)), clamp(dev().float_pos[1], 0, math.max(win.y - dev().float_size[1], 0))}
	devtools_panel(app, t, true, {width = ui.px(dev().float_size[0] * sc), height = ui.px(dev().float_size[1] * sc), fixed_x = dev().float_pos[0] * sc, fixed_y = dev().float_pos[1] * sc})
	if b := ui.box_from_key(ui.key_from_string(ui.parent_box().key, "###dt_panel")); b != nil {
		dev().panel_rect = b.rect
		// the corner: a grip that resizes
		g := math.round(ui.font_size() * 1.1)
		ui.next({width = ui.px(g), height = ui.px(g), fixed_x = b.rect.max.x - b.rect.min.x - g, fixed_y = b.rect.max.y - b.rect.min.y - g, cursor = .Resize_NWSE})
		gb := ui.build_box({.Clickable}, "###dt_corner")
		gs := ui.signal(gb)
		d := ui.frame_new(Dt_Btn_Draw)
		d.hot = gs.hovering || dev().drag == .Corner
		gb.custom, gb.custom_user = corner_grip_draw, d
		devtools_float_drag(app, gs, .Corner)
	}
}

@(private = "file")
corner_grip_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dt_Btn_Draw)(user)
	r := b.rect
	s := max(math.round(ui.scale()), 1)
	col := d.hot ? the_app.dtc.accent : the_app.dtc.faint
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
	return dev().visible && !devtools_detached() && dev().dock == .Floating && draw.rect_contains(dev().panel_rect, pos)
}

////////////////////////////////
// What the page draws for the panel

// The box of the element the Elements tab hovers or has selected, over the page (Chromium's colors: content blue, padding
// green, border yellow). Called by page_draw for a page that is painted now.
devtools_overlay :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, area: draw.Rect) {
	if !dev_shows(dev(), .Elements) || t == nil || t.page == nil || t.kind != .Web { return }
	h := dev().els.hover != base.NIL_HANDLE ? dev().els.hover : dev().els.selected
	if dev().picking { h = dev().els.picked }
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
