package browser

// The developer tools: a native view of the chrome (not a page), the toolkit's view "devtools" (views.odin), an instance
// per browser window: a panel at the bottom of the window at first, moved by the person to another edge, floated over the
// page or put in a window of its own (views_external.odin) as every view is; the toolkit remembers where. Inside, the panels
// (Console, Elements, Network, Application, Performance, Memory) are in the toolkit's dock
// (ui.Dock, docs/docking.md of the toolkit): stacks of tabs the user drags to split, join, float and dock back, every target
// also in a stack's menu; browser.devtools.layout keeps it (devtools_layout.odin). F12 / Ctrl+Shift+I open and
// close it, Ctrl+Shift+J opens the Console, Ctrl+Shift+C picks an element of the page; "Inspect" in the page's context menu
// opens Elements on the element under the pointer. With the keyboard in them, Ctrl+F finds in the panel (devtools_take_keys)
// and Escape shows the Console under the panel and hides it again (devtools_drawer_toggle). The tabs are in
// devtools_console.odin, devtools_elements.odin, devtools_network.odin, devtools_application.odin, devtools_performance.odin
// and devtools_memory.odin; the interface parts they share (icons, buttons, lists, the filter field) are in devtools_kit.odin and devtools_icons.odin.
//
// State and preferences: browser.devtools.* (visible, tab, layout, font size, density, and what each panel keeps: its
// filters, its columns, its panes). `visible` is the program's: each window's build makes the view follow it
// (devtools_view_follow), and the person closing the view sets it false. Docked, the view takes room from the page (the
// frame of views lays the page out beside it, so page_rect shrinks and the layout follows). Closed, it costs nothing:
// nothing is built, and the loader's observer keeps only what the Network tab needs for the tabs that have requests.
//
// The panel reads what the shell owns (the tab's console lines, its request log); what it shows of the page's document is
// copied while the page is not running (shell_nested: a chrome frame made while a script holds the thread reads nothing
// of the page).

import "core:fmt"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import prefs_page "toolkit:prefs_page"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import config "toolkit:config"
import "wb:host"
import i18n "toolkit:i18n"
import "wb:page"

// Where the developer tools are: the view's presentation and, docked, its edge of the window (dev_dock_of). The view's
// memory is the toolkit's; this is what the menus, the commands and wren ctl say of it.
Dev_Dock :: enum u8 { Bottom, Right, Left, Top, Floating, Window }
Dev_Panel :: enum u8 { Console, Elements, Network, Application, Performance, Memory }

DEV_DOCK_NAMES := [Dev_Dock]string{.Bottom = "bottom", .Right = "right", .Left = "left", .Top = "top", .Floating = "floating", .Window = "window"}
DEV_PANEL_NAMES := [Dev_Panel]string{.Console = "console", .Elements = "elements", .Network = "network", .Application = "application", .Performance = "performance", .Memory = "memory"}
DEV_PANEL_TITLES := [Dev_Panel]string{.Console = "Console", .Elements = "Elements", .Network = "Network", .Application = "Application", .Performance = "Performance", .Memory = "Memory"}
DEV_PANEL_ICONS := [Dev_Panel]Dt_Icon{.Console = .Tab_Console, .Elements = .Tab_Elements, .Network = .Tab_Network, .Application = .Tab_Application, .Performance = .Tab_Performance, .Memory = .Tab_Memory}
DEV_DOCK_TITLES := [Dev_Dock]string{.Bottom = "Dock to bottom", .Right = "Dock to right", .Left = "Dock to left", .Top = "Dock to top", .Floating = "Undock into a floating panel", .Window = "Open in a separate window"}
// The commands (commands.odin) that move the view: their shortcuts are shown in the menus ("": none).
DEV_DOCK_COMMANDS := [Dev_Dock]string{.Bottom = "view.devtools_dock_bottom", .Right = "view.devtools_dock_right", .Left = "view.devtools_dock_left", .Top = "", .Floating = "view.devtools_dock_floating", .Window = "view.devtools_detach"}
// The places the panel's own menu offers (the toolkit's menu and palette offer every one).
DEV_DOCK_MENU :: [?]Dev_Dock{.Bottom, .Right, .Left, .Floating, .Window}
DEV_DOCK_EDGES :: [Dev_Dock]ui.View_Edge{.Bottom = .Bottom, .Right = .Right, .Left = .Left, .Top = .Top, .Floating = .Bottom, .Window = .Bottom}

// The view's first height at the bottom, or width at a side (ems): 300 px at 15 px, the panel's size of old.
DEVTOOLS_EXTENT_EM :: 20

// The first shortcut of a command, as a menu shows it ("" when it has none).
cmd_key :: proc(app: ^App, name: string) -> string {
	c := command(app, name)
	return c == nil ? "" : ui.command_shortcut(c.spec)
}

DEV_DOCK_ICONS := [Dev_Dock]Dt_Icon{.Bottom = .Dock_Bottom, .Right = .Dock_Right, .Left = .Dock_Left, .Top = .Dock_Bottom, .Floating = .Float, .Window = .Detach}

DEVTOOLS_PREFS := [?]config.Def{
	{name = "browser.devtools.visible", kind = .Bool, default = {b = false},
		description = "Show the developer tools: a panel with the page's console, its document tree, its requests and its storage (F12, Ctrl+Shift+I)."},
	{name = "browser.devtools.tab", kind = .String, default = {s = "console"}, choices = {"console", "elements", "network", "application", "performance", "memory"},
		description = "The tab of the developer tools that is shown."},
	{name = "browser.devtools.layout", kind = .String, default = {s = DEV_LAYOUT_DEFAULT},
		description = "Where the developer tools' panels are: their stacks of tabs (* before the one shown), the splits between them (x: side by side, y: one above the other, the first's share, f: the second folded) and the floating ones (@x,y,width,height), as one line. Drag a tab to change it; its stack's menu does it from the keyboard."},
	{name = "browser.devtools.font_size", kind = .Float, default = {f = 12}, bounded = true, min = 8, max = 24, value_kind = .Length,
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

// The developer tools of one browser window (Window_Own.devtools): the view "devtools" whose instance is that window's
// (views.odin), wherever the person put it; they show that window's current tab, go with a tab they show that moves to
// another window (tab_move), and close with their window.
Devtools :: struct {
	visible:   bool,               // the view is wanted open (devtools_view_follow)
	dock:      Dev_Dock,           // where the view was built last (dev_dock_of), or was asked to go
	brought:   bool,               // a tab brought them from another window: the view opens at `dock` (devtools_view_follow)
	panel:     Dev_Panel,
	font_pt:   f32,
	density:   Dt_Density,
	rect:      draw.Rect,          // where the panel was drawn last frame, in the State it was built in
	built_in:  ^ui.State,          // ... that State: the browser window's, or its view window's (only compared, never read)
	room:      draw.Vec2,          // its size in the frame being built (dev_width, dev_height); 0: not known before layout
	room_checks, room_wrong: int,  // frames whose room was compared with the layout's result, and those where it differed
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

// The developer tools of a window that opens: their tab and text from the preferences (where they sit is the view's memory);
// shown only in the first window (`shown`: the preference browser.devtools.visible), closed in the others until asked for there.
devtools_view_init :: proc(app: ^App, d: ^Devtools, shown: bool) {
	p := &app.prefs
	d.visible = shown && config.bool_of(p, "browser.devtools.visible")
	view_from_prefs(d, p, "")
}

@(private = "file")
view_from_prefs :: proc(d: ^Devtools, p: ^config.Prefs, name: string) {
	if name == "" || name == "browser.devtools.tab" {
		panel := config.string_of(p, "browser.devtools.tab")
		for n, x in DEV_PANEL_NAMES { if n == panel { d.panel = x } }
	}
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

// A preference of the developer tools changed (about:config, a menu of a panel, devtools_save). Their tab and whether they are
// shown are of the window the user is in (the one that saved them); the text size, the density and what the tabs keep are
// every window's.
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

// The developer tools of the active window give up what they hold (their window closes, or the browser ends). Their view
// goes with the window's State (ui.destroy: a view whose owner went ends, its window of its own with it).
devtools_view_destroy :: proc(app: ^App) {
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
	set_pref_string(app, "browser.devtools.tab", DEV_PANEL_NAMES[dev().panel])
}

set_pref_string :: proc(app: ^App, name, value: string) {
	if config.value_string(&app.prefs, config.ref_of(&app.prefs, name)) == value { return }   // (a Float preference too: string_of asserts on one)
	if err := config.set_from_string(&app.prefs, name, value, .User); err != .None {
		announce(app, .Warn, fmt.tprintf("%s: %s", name, config.set_error_text(err)))
	}
}

// A preference of any kind from its text (what a menu of the panel sets).
dev_set_pref :: proc(app: ^App, name: string, value: string) {
	if err := config.set_from_string(&app.prefs, name, value, .User); err != .None {
		announce(app, .Warn, fmt.tprintf("%s: %s", name, config.set_error_text(err)))
	}
}

dev_toggle_pref :: proc(app: ^App, name: string) {
	dev_set_pref(app, name, config.bool_of(&app.prefs, name) ? "false" : "true")
}

devtools_toggle :: proc(app: ^App) { devtools_set_visible(app, !dev().visible) }

// The active window's developer tools wanted open or closed: its next build opens or closes the view (devtools_view_follow).
devtools_set_visible :: proc(app: ^App, on: bool) {
	d := dev()
	d.visible = on
	if !on { d.picking = false }
	set_pref_bool(app, "browser.devtools.visible", on)
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
	// (the keyboard of another window than the one they are built in is not theirs: their rect is that State's)
	if !d.visible || d.built_in != ui.current_state() { return {}, false }
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


////////////////////////////////
// The view

// The view's instance of the active window's developer tools.
@(private = "file")
devtools_instance :: proc(app: ^App) -> string { return window_view_instance(active_window(app).id) }

// The active window's developer tools go to `dock` (opened there when they were closed): a presentation of the view, which
// the toolkit remembers.
devtools_set_dock :: proc(app: ^App, dock: Dev_Dock) {
	w := active_window(app)
	vs := &app.views
	inst := devtools_instance(app)
	if !dev().visible { devtools_set_visible(app, true) }
	// (opened now, not at the next build: it moves at once; outside a build, its owner is named)
	if !ui.view_is_open(vs, DEVTOOLS_VIEW, inst) { ui.view_open(vs, DEVTOOLS_VIEW, w, inst, w.ui) }
	devtools_present(vs, inst, dock)
	dev().dock = dock
	request_frames(app, 3)
}

@(private = "file")
devtools_present :: proc(vs: ^ui.Views, inst: string, dock: Dev_Dock) {
	switch dock {
	case .Bottom, .Right, .Left, .Top:
		edges := DEV_DOCK_EDGES
		ui.view_present(vs, DEVTOOLS_VIEW, .Panel, {edge = edges[dock]}, inst)
	case .Floating: ui.view_present(vs, DEVTOOLS_VIEW, .Internal, {}, inst)
	case .Window: ui.view_present(vs, DEVTOOLS_VIEW, .External, {}, inst)
	}
}

// Back to their home: a panel at the bottom of the window.
devtools_reattach :: proc(app: ^App) {
	ui.view_reattach(&app.views, DEVTOOLS_VIEW, devtools_instance(app))
	dev().dock = .Bottom
	request_frames(app, 3)
}

// Where a presentation of the view puts the developer tools.
dev_dock_of :: proc(p: ui.View_Presentation, place: ui.View_Place) -> Dev_Dock {
	switch p {
	case .Panel:
		#partial switch place.edge {
		case .Right: return .Right
		case .Left:  return .Left
		case .Top:   return .Top
		}
		return .Bottom
	case .Dialog, .Internal: return .Floating
	case .External: return .Window
	}
	return .Bottom
}

// In each build of a browser window, before its frame of views (build_ui): the view follows `visible` (a command, a
// preference, a tab that brought its developer tools from another window), and `visible` follows the person closing the
// view (its stack's close, Ctrl+W in it, its window's Close view).
devtools_view_follow :: proc(app: ^App) {
	w := active_window(app)
	d := &w.own.devtools
	vs := &app.views
	inst := window_view_instance(w.id)
	if _, ended := ui.view_ended(vs, DEVTOOLS_VIEW, inst); ended && d.visible { devtools_set_visible(app, false) }
	open := ui.view_is_open(vs, DEVTOOLS_VIEW, inst)
	if d.visible && !open {
		ui.view_open(vs, DEVTOOLS_VIEW, w, inst)
		// (brought by a tab: where they were in the other window. Otherwise the toolkit opens the view where the person
		// last had it)
		if d.brought { devtools_present(vs, inst, d.dock) }
		d.brought = false
	} else if !d.visible && open {
		ui.view_close(vs, DEVTOOLS_VIEW, inst)
	}
}

// The view's build: the developer tools of `bw`, which is the active window here, as a panel of it (its build) or in a
// window of its own (whose frames come after bw's, with bw active: views_external.odin).
devtools_view :: proc(v: ^ui.View, bw: ^Browser_Window) {
	app := the_app
	if app == nil || active_window(app) != bw { return }
	d := &bw.own.devtools
	d.dock = dev_dock_of(v.presentation, v.place)
	t := current_tab(app)
	if v.presentation == .External { ui.view_title(v, devtools_window_title(app, bw)) }
	if t == nil || t.kind != .Web {
		// (a page of the browser's own has no document of the page's to show)
		if ui.dialog_body("dt_none") {
			if ui.tags("weak") { ui.paragraph(strings.concatenate({i18n.tr("The developer tools show a web page."), "###dt_none_text"}, ui.frame_allocator())) }
		}
		return
	}
	devtools_panel(app, t, {width = ui.fill(), height = ui.fill()}, fill = ui.view_room(v))
}

// The title of the developer tools' window of `bw`: its current tab's.
devtools_window_title :: proc(app: ^App, bw: ^Browser_Window) -> string {
	return fmt.tprintf(i18n.tr("%s - Wren Developer Tools"), window_label(app, bw))
}

// The tab the developer tools of `src` were showing moved to `dest` (tab_move): they go with it when `dest` has none open
// (`dest`'s, closed, take their place in `src`). When `dest` shows its own, each window keeps its own: those of `dest`
// show the tab that came. Each window's next build makes its view follow (devtools_view_follow): it closes in `src` and
// opens in `dest`, where the person last put the developer tools.
devtools_follow_tab :: proc(app: ^App, src, dest: ^Browser_Window) {
	a, b := &src.own.devtools, &dest.own.devtools
	if src == dest || !a.visible || b.visible { return }
	// a panel's timer names its window: stopped, the panel sets it again when it is built
	for d in ([2]^Devtools{a, b}) {
		if d.net.tick != base.NIL_HANDLE { host.clear_timer(&app.loop, d.net.tick); d.net.tick = base.NIL_HANDLE }
		if d.mem.tick != base.NIL_HANDLE { host.clear_timer(&app.loop, d.mem.tick); d.mem.tick = base.NIL_HANDLE }
	}
	a^, b^ = b^, a^
	b.brought = true
	if app.net_media.owner == a { app.net_media.owner = b } else if app.net_media.owner == b { app.net_media.owner = a }
	window_request(app, src, 3)
	window_request(app, dest, 3)
}

// The window of its own of `bw`'s developer tools (nil: they are in none).
devtools_view_window :: proc(app: ^App, bw: ^Browser_Window) -> ^View_Window {
	return view_window_of_state(app, ui.view_window_state(&app.views, DEVTOOLS_VIEW, window_view_instance(bw.id)))
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
devtools_panel :: proc(app: ^App, t: ^Tab, place := ui.Style_Mod{}, fill := draw.Vec2{}) {
	dt_begin(app)
	dev().built_in = ui.current_state()
	// the check behind dev_width: what the last frame took for the panel's width is the width its layout gave the box (the
	// box as it is now, before this build, is that layout's); counted for the tests (stats: devtoolsRoomWrong)
	if pb := ui.box_from_key(ui.key_from_string(ui.parent_box().key, "###dt_panel")); pb != nil && dev().room.x > 0 && pb.rect.max.x > pb.rect.min.x {
		dev().room_checks += 1
		if abs((pb.rect.max.x - pb.rect.min.x) - dev().room.x) > 1.5 { dev().room_wrong += 1 }
	}
	dev().room = dev_room_of(place, fill)
	// dense menus for the panel's own: the feel's item height for this build only (no set_feel: the platform's part stays)
	st := ui.current_state()
	menu_em := st.feel.menu_item_em
	st.feel.menu_item_em = dev().density == .Comfortable ? 2.1 : 1.85
	defer st.feel.menu_item_em = menu_em
	if ui.style({font_size = app.dtm.fs, text_pad = dt_px(4)}) {
		mod := place
		mod.axis, mod.radius = .Y, 0
		ui.next(mod)
		// (.Fits_Width: its width is the dock zone's share; with its content's least, the tab strip and the tool bars
		// would push the page aside, whatever size the person gave the panel)
		panel := ui.build_box({.Draw_Background, .Fits_Width}, "###dt_panel")
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
// (the chrome's shortcuts would zoom the page, the toolkit's lists would scroll). Called with the events of a frame of the
// State `s` (a browser window's, main.odin's frame; a view's window's, views_external.odin), before its build; returns the others.
devtools_events :: proc(app: ^App, events: []platform.Event, s: ^ui.State) -> []platform.Event {
	if !dev().visible && net_media_active(app) && app.net_media.owner == dev() { net_media_release(app) }
	if dev().built_in != s { return events }   // (the panel's rectangle is of the State it was built in)
	if !dev().visible || dev().rect.max.x <= dev().rect.min.x || ui.menu_any_open() { return events }
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
	if ui.menu_submenu("Text size###dt_m_size", icon = lucide.TYPE) {
		for pt in ([?]f32{10, 11, 12, 13, 14, 16, 18}) {
			if ui.menu_item(fmt.tprintf("%g px###dt_m_pt%g", pt, pt), checked = dev().font_pt == pt).clicked { dev_set_pref(app, "browser.devtools.font_size", fmt.tprintf("%g", pt)) }
		}
		ui.menu_separator()
		if ui.menu_item("Larger###dt_m_big", "Ctrl +", icon = lucide.ZOOM_IN).clicked { devtools_zoom(app, 1) }
		if ui.menu_item("Smaller###dt_m_small", "Ctrl \u2212", icon = lucide.ZOOM_OUT).clicked { devtools_zoom(app, -1) }
		if ui.menu_item("Reset###dt_m_reset", "Ctrl 0", icon = lucide.ROTATE_CCW).clicked { devtools_zoom(app, 0) }
	}
	if ui.menu_submenu("Density###dt_m_density", icon = lucide.ROWS_2) {
		if ui.menu_item("Compact###dt_m_dc", checked = dev().density == .Compact).clicked { dev_set_pref(app, "browser.devtools.density", "compact") }
		if ui.menu_item("Comfortable###dt_m_dm", checked = dev().density == .Comfortable).clicked { dev_set_pref(app, "browser.devtools.density", "comfortable") }
	}
	if ui.menu_submenu("Theme###dt_m_theme", icon = lucide.PALETTE) {
		ui.menu_heading("The panel follows the browser's theme")
		for th, i in app.themes_file.all {
			if ui.menu_item(fmt.tprintf("%s###dt_m_th%d", th.name, i), checked = base.ascii_equal_fold(app.cfg.look.theme, th.name)).clicked { dev_set_pref(app, prefs_page.THEME_PREF, th.name) }
		}
	}
	ui.menu_separator()
	#partial switch dev().panel {
	case .Console: console_settings_items(app, t)
	case .Network: network_settings_items(app, t)
	}
	ui.menu_separator()
	if ui.menu_item("Select an element in the page###dt_m_pick", cmd_key(app, "view.devtools_pick"), icon = lucide.TEXT_CURSOR_INPUT).clicked { devtools_pick(app) }
	pc := ui.palette_command()   // (the toolkit's: its keys and its icon)
	if ui.menu_item("Open the command palette###dt_m_palette", ui.command_shortcut(pc), icon = pc.icon).clicked { palette_toggle(app) }
	// the drawer: the Console in a stack of its own under the others (Escape shows and hides it)
	if devtools_drawer_split(dev()) == ui.DOCK_NONE {
		if ui.menu_item("Show the Console under the other panels###dt_m_con_drawer", "Esc", icon = lucide.EYE).clicked { devtools_drawer_toggle(app) }
	}
	if ui.menu_item("Reset the layout of the panels###dt_m_layout", icon = lucide.ROTATE_CCW).clicked { devtools_reset_layout(app) }
	if ui.menu_item("Open about:config for the developer tools###dt_m_cfg", icon = lucide.SETTINGS).clicked { open_in_new_tab(app, "about:config?q=browser.devtools", origin = .User) }
	if ui.menu_item("Close the developer tools###dt_m_close", "F12", icon = lucide.X).clicked { devtools_toggle(app) }
}

// Where they are, sizes, columns and panes as they came.
devtools_reset_layout :: proc(app: ^App) {
	if dev().visible { devtools_reattach(app) }
	dev_set_pref(app, "browser.devtools.layout", DEV_LAYOUT_DEFAULT)
	dev_set_pref(app, "browser.devtools.font_size", "12")
	dev_set_pref(app, "browser.devtools.density", "compact")
	network_reset_layout(app)
	elements_reset_layout(app)
	request_frames(app, 2)
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
	_ = config.set_float(&app.prefs, name, f64(v))
}

_ :: page
