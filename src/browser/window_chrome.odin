package browser

// The window's frame. By default the row of tabs is the window's title bar, as in Edge and Chrome: the Wren icon on the
// left (the window title in its tooltip, the system menu on a click), the tabs, the new-tab button, free space that
// drags the window, and the window buttons drawn by the browser (toolkit: ui.title_bar, ui.window_buttons; the platform
// answers the system's hit tests, so Snap Layouts, Aero Snap and double-click to maximize work). The window title stays
// set for the taskbar and Alt+Tab (hud.odin). The standard window.system_title brings the title bar of the system back, at
// once. A right click on the free space opens the toolbar's menu (toolbar_menu.odin), whose last item is the
// system menu; the free space is never less than browser.window.min_drag_em, in every layout of the tabs.
//
// Full screen (F11): no frame, no title bar, no tabs nor address bar; they slide down over the page while the pointer
// is at the top edge of the screen (browser.window.fullscreen_reveal), and go when it leaves them.

import "toolkit:draw"
import "toolkit:platform"
import prefs_page "toolkit:prefs_page"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

WINDOW_PREFS := [?]config.Def{
	{name = "browser.window.min_drag_em", kind = .Float, default = {f = 3}, bounded = true, min = 0, max = 40, unit = "em",
		description = "Free space kept in the title bar between the tabs and the window buttons, to drag the window when there are many tabs (the tabs are cut off before it). With the tabs in a sidebar, the strip between the menu and the window buttons (in a narrow window, the buttons of the toolbar are hidden before it narrows). A right click on the free space of the title bar opens the toolbar's menu."},
	{name = "browser.window.fullscreen_reveal", kind = .Bool, default = {b = true},
		description = "In full screen (F11), the tabs and the address bar slide down over the page while the pointer is at the top edge of the screen."},
	{name = "browser.window.fullscreen_reveal_px", kind = .Int, default = {i = 3}, bounded = true, min = 1, max = 200, unit = "px",
		description = "Height of the strip along the top of the screen that brings the tabs and the address bar back in full screen."},
	{name = "browser.window.fullscreen_hint", kind = .Bool, default = {b = true},
		description = "A notice \"Press Esc to exit full screen\" when a page puts an element (a video) in full screen."},
	{name = "browser.window.square_corners", kind = .Bool, default = {b = true},
		description = "Square corners on the window itself (Windows 11 rounds them, Windows 10 never does). On (the default): the corners are cut square, by DWM_WINDOW_CORNER_PREFERENCE. Off: the system's rounded corners. Applies at once."},
	{name = "browser.address_bar.sizing_mode", kind = .String, default = {s = "centered"}, choices = {"centered", "full_width"},
		description = "How wide the address bar is. centered (the default): at most 48 em wide, in the middle of the window, and narrower in a narrow window; with the integrated title bar, the space on either side of it drags the window. full_width: the whole width the toolbar leaves it. Applies at once."},
	{name = "browser.window.fixed_surface", kind = .Bool, default = {b = true}, restart = true,
		description = "Never resize the surface the window shows: a composition swap chain holds one surface (the monitor's size) and the window shows the top-left part of it, 1:1, clipped. A window being resized then cuts what was drawn instead of stretching it, and the newly shown strip stays the background until the next frame paints it. Needs a restart (the developer tools' own window takes it when it opens); falls back to the usual swap chain when the system cannot compose."},
}

// browser.address_bar.sizing_mode, as the chrome reads it (the pref's choices are its names in snake case).
Address_Bar_Sizing :: enum u8 { Centered, Full_Width }

address_bar_sizing_name :: proc(m: Address_Bar_Sizing) -> string {
	switch m {
	case .Centered:   return "centered"
	case .Full_Width: return "full_width"
	}
	return "centered"
}

address_bar_sizing_of :: proc(name: string) -> Address_Bar_Sizing {
	for m in Address_Bar_Sizing { if address_bar_sizing_name(m) == name { return m } }
	return .Centered
}

register_window_prefs :: proc(p: ^config.Prefs) { config.register(p, WINDOW_PREFS[:]) }

// The size of the one surface a window shows (the size of its monitor) when browser.window.fixed_surface is on, else zero: the main window's
// composition swap chain (render.set_fixed_surface) and the developer tools' window's (render.surface_create) are made with it, so that both are
// resized the same way: cut, never stretched. The monitor size comes from the toolkit (platform.monitor_size), so this is neutral across systems.
fixed_surface_size :: proc(app: ^App, w: ^platform.Window) -> [2]int {
	if !config.bool_of(&app.prefs, "browser.window.fixed_surface") { return {} }
	return platform.monitor_size(w)
}

Window_Settings :: struct {
	integrated:  bool,
	min_drag_em: f32,
	reveal:      bool,
	reveal_px:   f32,
	fullscreen_hint: bool,
	square_corners: bool,
	address_sizing: Address_Bar_Sizing,   // browser.address_bar.sizing_mode
}

window_settings_from_prefs :: proc(p: ^config.Prefs) -> Window_Settings {
	return {
		address_sizing = address_bar_sizing_of(config.string_of(p, "browser.address_bar.sizing_mode")),
		integrated = !config.bool_of(p, prefs_page.SYSTEM_TITLE_PREF),
		min_drag_em = f32(config.float_of(p, "browser.window.min_drag_em")),
		reveal = config.bool_of(p, "browser.window.fullscreen_reveal"),
		reveal_px = f32(config.int_of(p, "browser.window.fullscreen_reveal_px")),
		fullscreen_hint = config.bool_of(p, "browser.window.fullscreen_hint"),
		square_corners = config.bool_of(p, "browser.window.square_corners"),
	}
}

// What of the frame a window has of its own (Window_Own.full).
Window_Full :: struct {
	revealed:     bool,          // full screen: the bars are shown over the page
	overlay:      draw.Rect,     // where they were last frame
}

Window_Chrome :: struct {
	cfg:          Window_Settings,
	watch:        int,
	watch_bar:    int,           // browser.address_bar.* (Window_Settings has them too)
	watch_title:  int,           // the standard window.* (window.system_title)
	icon:         render.Texture,
	icon_px:      int,           // size of `icon` (0: none made yet)
	icon_failed:  int,           // a size the exe's icon could not be loaded at
	menu_win:     ^platform.Window,   // the system menu the icon asked for, opened once that window's frame is over (window_chrome_after_frame)
	menu_at:      [2]f32,
}


window_chrome_init :: proc(app: ^App) {
	app.wchrome.cfg = window_settings_from_prefs(&app.prefs)
	platform.set_square_corners(active_window(app).win, app.wchrome.cfg.square_corners)
	window_changed :: proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		app.wchrome.cfg = window_settings_from_prefs(p)
		platform.set_square_corners(active_window(app).win, app.wchrome.cfg.square_corners)
		request_frames(app, 2)
	}
	app.wchrome.watch = config.watch(&app.prefs, "browser.window.", window_changed, app)
	app.wchrome.watch_title = config.watch(&app.prefs, "window.", window_changed, app)
	app.wchrome.watch_bar = config.watch(&app.prefs, "browser.address_bar.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		app.wchrome.cfg = window_settings_from_prefs(p)
		request_frames(app, 2)
	}, app)
}

window_chrome_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, app.wchrome.watch)
	config.unwatch(&app.prefs, app.wchrome.watch_bar)
	config.unwatch(&app.prefs, app.wchrome.watch_title)
	if app.wchrome.icon_px > 0 { render.destroy_texture(&app.r, app.wchrome.icon) }
	app.wchrome = {}
}

// Before the frame's build: the title bar the preference asks for.
window_chrome_frame :: proc(app: ^App) {
	wnd := active_window(app)
	if !platform.is_fullscreen(wnd.win) && platform.is_integrated_title(wnd.win) != app.wchrome.cfg.integrated {
		platform.set_integrated_title(wnd.win, app.wchrome.cfg.integrated)
		render.resize(&app.r, wnd.win.size)
	}
	// a right click on the free space of the title bar opens the toolbar's menu (toolbar_menu.odin), not the system's;
	// the system's is an item of it. (A flag of the window: set on each, every frame, wherever the window was made.)
	platform.set_caption_menu_app(wnd.win, true)
}

toggle_fullscreen :: proc(app: ^App) {
	wnd := active_window(app)
	if fullscreen_shell_leave(app) { return }   // F11 in a page's full screen (a video): back to the page, window as it was
	on := !platform.is_fullscreen(wnd.win)
	platform.set_fullscreen(wnd.win, on)
	window_own(app).full.revealed = false
	render.resize(&app.r, wnd.win.size)
	request_frames(app, 3)
}

@(private = "file")
Icon_Draw :: struct { tex: render.Texture, ok: bool }

// The exe's icon: the window title (version, build, statistics) in its tooltip; a click opens the system menu.
app_icon :: proc(app: ^App, size: f32) {
	px := int(size)
	if px != app.wchrome.icon_px && px != app.wchrome.icon_failed {
		if app.wchrome.icon_px > 0 { render.destroy_texture(&app.r, app.wchrome.icon); app.wchrome.icon_px = 0 }
		if pixels, ok := platform.app_icon_rgba(px, context.temp_allocator); ok {
			app.wchrome.icon = render.create_texture_rgba(&app.r, px, px, mips = false)
			render.update_texture_rgba(&app.r, app.wchrome.icon, 0, 0, px, px, pixels)
			app.wchrome.icon_px = px
		} else {
			app.wchrome.icon_failed = px
		}
	}
	d := ui.frame_new(Icon_Draw)
	d^ = {app.wchrome.icon, app.wchrome.icon_px == px}
	ui.next({width = ui.px(size), height = ui.px(size)})
	b := ui.custom("###app_icon", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Icon_Draw)(user)
		if d.ok { draw.image(dc, d.tex, b.rect) }
	}, d, {.Clickable})
	b.cursor = .Arrow
	sig := ui.signal(b)
	if active_window(app).title != "" { tip(sig, active_window(app).title) }
	if sig.clicked || sig.right_clicked { window_menu_ask(app, {b.rect.min.x, b.rect.max.y}) }
}

// The system menu of the active window at `pos`, opened after this frame (window_chrome_after_frame).
window_menu_ask :: proc(app: ^App, pos: [2]f32) {
	app.wchrome.menu_win, app.wchrome.menu_at = active_window(app).win, pos
}

// At the end of a frame: the system menu the icon asked for. Not from the build: the menu's loop paints the window
// (window_on_frame), and a frame made inside the build broke the one being built (windows.odin: the frame gate).
window_chrome_after_frame :: proc(app: ^App) {
	w := app.wchrome.menu_win
	if w == nil || w != active_window(app).win { return }
	app.wchrome.menu_win = nil
	if !platform.is_closed(w) { platform.show_system_menu(w, app.wchrome.menu_at) }
}

// A window that closes: a menu it asked for is not opened.
window_chrome_forget :: proc(app: ^App, w: ^platform.Window) {
	if app.wchrome.menu_win == w { app.wchrome.menu_win = nil }
}

// Full screen: the bars over the top of the page while revealed. Built after the page so they draw over it.
fullscreen_bars :: proc(app: ^App, t: ^Tab) {
	wnd := active_window(app)
	fw := &window_own(app).full
	if !platform.is_fullscreen(wnd.win) { fw.revealed = false; return }
	if !app.wchrome.cfg.reveal || fullscreen_shell_active(app.active) { fw.revealed = false; return }   // (a page's own full screen keeps the whole window)
	m := ui.mouse_pos()
	asked := window_own(app).asked & BAR_REQUESTS != {}   // what a command asks of them comes now, not at the pointer's next visit
	if !fw.revealed {
		fw.revealed = asked || (m.y >= 0 && m.y < app.wchrome.cfg.reveal_px && m.x >= 0 && m.x < f32(wnd.win.size.x))
	} else {
		// they stay while the pointer is over them, a menu of theirs is open or the address bar has the keyboard
		over := m.y < fw.overlay.max.y + ui.font_size()
		fw.revealed = asked || over || ui.ctx_menu_any_open() || (ui.focus_key() != 0 && ui.focus_key() == address_key(app))
	}
	if !fw.revealed { fw.overlay = {}; return }
	placed := fw.overlay != {}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(wnd.win.size.x)), height = ui.children_sum(), axis = .Y})
	col := ui.build_box({.Draw_Background, .Draw_Side_Bottom}, "###fullscreen_bars")
	if ui.parent(col) {
		tab_strip(app, false)
		toolbar_row(app, t)   // chrome_style.odin
	}
	if placed { window_own(app).asked -= BAR_REQUESTS }   // (built with a place, and nothing there took it: it would hold the bars for ever)
	// (the rect is last layout's: one more frame when it moved, so that the capture follows)
	if asked || col.rect != fw.overlay { request_frames(app, 2) }
	fw.overlay = col.rect
}

// The full screen bars take the clicks and the wheel over them (the page under them does not get them).
fullscreen_bars_capture :: proc(app: ^App, pos: draw.Vec2) -> bool {
	fw := &window_own(app).full
	return fw.revealed && draw.rect_contains(fw.overlay, pos)
}
