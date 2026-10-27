package browser

// The window's frame. By default the row of tabs is the window's title bar, as in Edge and Chrome: the Wren icon on the
// left (the window title in its tooltip, the system menu on a click), the tabs, the new-tab button, free space that
// drags the window, and the window buttons drawn by the browser (toolkit: ui.title_bar, ui.window_buttons; the platform
// answers the system's hit tests, so Snap Layouts, Aero Snap and double-click to maximize work). The window title stays
// set for the taskbar and Alt+Tab (hud.odin). browser.window.integrated_titlebar = false brings the title bar of Windows
// back, at once.
//
// Full screen (F11): no frame, no title bar, no tabs nor address bar; they slide down over the page while the pointer
// is at the top edge of the screen (browser.window.fullscreen_reveal), and go when it leaves them.

import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

WINDOW_PREFS := [?]config.Def{
	{name = "browser.window.integrated_titlebar", kind = .Bool, default = {b = true},
		description = "The row of tabs is the window's title bar, as in Edge and Chrome: the browser draws the minimize, maximize and close buttons and the free space next to the tabs drags the window. Off: the title bar of Windows above the tabs. Applies at once."},
	{name = "browser.window.min_drag_em", kind = .Float, default = {f = 3}, bounded = true, min = 0, max = 40, unit = "em",
		description = "Free space kept in the title bar between the tabs and the window buttons, to drag the window when there are many tabs (the tabs are cut off before it). With the tabs in a sidebar, the strip between the menu and the window buttons (it narrows in a narrow window before anything is hidden)."},
	{name = "browser.window.fullscreen_reveal", kind = .Bool, default = {b = true},
		description = "In full screen (F11), the tabs and the address bar slide down over the page while the pointer is at the top edge of the screen."},
	{name = "browser.window.fullscreen_reveal_px", kind = .Int, default = {i = 3}, bounded = true, min = 1, max = 200, unit = "px",
		description = "Height of the strip along the top of the screen that brings the tabs and the address bar back in full screen."},
	{name = "browser.window.fullscreen_hint", kind = .Bool, default = {b = true},
		description = "A notice \"Press Esc to exit full screen\" when a page puts an element (a video) in full screen."},
	{name = "browser.window.square_corners", kind = .Bool, default = {b = true},
		description = "Square corners on the window itself (Windows 11 rounds them, Windows 10 never does). On (the default): the corners are cut square, by DWM_WINDOW_CORNER_PREFERENCE. Off: the system's rounded corners. Applies at once."},
	{name = "browser.window.fixed_surface", kind = .Bool, default = {b = true}, restart = true,
		description = "Never resize the surface the window shows: a composition swap chain holds one surface (the monitor's size) and the window shows the top-left part of it, 1:1, clipped. A window being resized then cuts what was drawn instead of stretching it, and the newly shown strip stays the background until the next frame paints it. Needs a restart (the developer tools' own window takes it when it opens); falls back to the usual swap chain when the system cannot compose."},
}

register_window_prefs :: proc(p: ^config.Prefs) { config.register(p, WINDOW_PREFS[:]) }

// The size of the one surface a window shows (the size of its monitor) when browser.window.fixed_surface is on, else zero: the main window's
// composition swap chain (render.set_fixed_surface) and the developer tools' window's (render.surface_create) are made with it, so that both are
// resized the same way: cut, never stretched.
fixed_surface_size :: proc(app: ^App, hwnd: win.HWND) -> [2]int {
	if !config.bool_of(&app.prefs, "browser.window.fixed_surface") { return {} }
	mon := win.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST)
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if !win.GetMonitorInfoW(mon, &mi) { return {} }
	return {int(mi.rcMonitor.right - mi.rcMonitor.left), int(mi.rcMonitor.bottom - mi.rcMonitor.top)}
}

Window_Settings :: struct {
	integrated:  bool,
	min_drag_em: f32,
	reveal:      bool,
	reveal_px:   f32,
	fullscreen_hint: bool,
	square_corners: bool,
}

window_settings_from_prefs :: proc(p: ^config.Prefs) -> Window_Settings {
	return {
		integrated = config.bool_of(p, "browser.window.integrated_titlebar"),
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
	icon:         render.Texture,
	icon_px:      int,           // size of `icon` (0: none made yet)
	icon_failed:  int,           // a size the exe's icon could not be loaded at
	menu_win:     ^platform.Window,   // the system menu the icon asked for, opened once that window's frame is over (window_chrome_after_frame)
	menu_at:      [2]f32,
}

wchrome: Window_Chrome

window_chrome_init :: proc(app: ^App) {
	wchrome.cfg = window_settings_from_prefs(&app.prefs)
	platform.set_square_corners(app.win, wchrome.cfg.square_corners)
	wchrome.watch = config.watch(&app.prefs, "browser.window.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		wchrome.cfg = window_settings_from_prefs(p)
		platform.set_square_corners(app.win, wchrome.cfg.square_corners)
		request_frames(app, 2)
	}, app)
}

window_chrome_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, wchrome.watch)
	if wchrome.icon_px > 0 { render.destroy_texture(&app.r, wchrome.icon) }
	wchrome = {}
}

// Before the frame's build: the title bar the preference asks for, smooth scrolling of the toolkit's lists like the page's.
window_chrome_frame :: proc(app: ^App) {
	if !platform.is_fullscreen(app.win) && platform.is_integrated_title(app.win) != wchrome.cfg.integrated {
		platform.set_integrated_title(app.win, wchrome.cfg.integrated)
		render.resize(&app.r, app.win.size)
	}
	// about:config and the other lists of the chrome scroll along the page's curve (smooth_scroll.odin)
	sc := smooth_cfg
	curve: ui.Scroll_Curve = sc.curve == .Ease_Out ? .Ease_Out : .Impulse
	dur := f32(sc.wheel_ms)
	if !sc.enabled || (sc.reduced_motion && (app.page_settings.style.reduced_motion || !os_animations_enabled(app))) { dur = 0 }
	ui.set_scroll_settings(app.ui_state, {curve = curve, impulse = f32(sc.impulse), duration_ms = dur})
}

toggle_fullscreen :: proc(app: ^App) {
	if fullscreen_shell_leave(app) { return }   // F11 in a page's full screen (a video): back to the page, window as it was
	on := !platform.is_fullscreen(app.win)
	platform.set_fullscreen(app.win, on)
	window_own(app).full.revealed = false
	render.resize(&app.r, app.win.size)
	request_frames(app, 3)
}

@(private = "file")
Icon_Draw :: struct { tex: render.Texture, ok: bool }

// The exe's icon: the window title (version, build, statistics) in its tooltip; a click opens the system menu.
app_icon :: proc(app: ^App, size: f32) {
	px := int(size)
	if px != wchrome.icon_px && px != wchrome.icon_failed {
		if wchrome.icon_px > 0 { render.destroy_texture(&app.r, wchrome.icon); wchrome.icon_px = 0 }
		if pixels, ok := platform.app_icon_rgba(px, context.temp_allocator); ok {
			wchrome.icon = render.create_texture_rgba(&app.r, px, px, mips = false)
			render.update_texture_rgba(&app.r, wchrome.icon, 0, 0, px, px, pixels)
			wchrome.icon_px = px
		} else {
			wchrome.icon_failed = px
		}
	}
	d := ui.frame_new(Icon_Draw)
	d^ = {wchrome.icon, wchrome.icon_px == px}
	ui.next({width = ui.px(size), height = ui.px(size)})
	b := ui.custom("###app_icon", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Icon_Draw)(user)
		if d.ok { draw.image(dc, d.tex, b.rect) }
	}, d, {.Clickable})
	b.cursor = .Arrow
	sig := ui.signal(b)
	if hud.title_text != "" { tip(sig, hud.title_text) }
	if sig.clicked || sig.right_clicked { wchrome.menu_win, wchrome.menu_at = app.win, {b.rect.min.x, b.rect.max.y} }
}

// At the end of a frame: the system menu the icon asked for. Not from the build: the menu's loop paints the window
// (window_on_frame), and a frame made inside the build broke the one being built (windows.odin: the frame gate).
window_chrome_after_frame :: proc(app: ^App) {
	w := wchrome.menu_win
	if w == nil || w != app.win { return }
	wchrome.menu_win = nil
	if !platform.is_closed(w) { platform.show_system_menu(w, wchrome.menu_at) }
}

// A window that closes: a menu it asked for is not opened.
window_chrome_forget :: proc(w: ^platform.Window) {
	if wchrome.menu_win == w { wchrome.menu_win = nil }
}

// Full screen: the bars over the top of the page while revealed. Built after the page so they draw over it.
fullscreen_bars :: proc(app: ^App, t: ^Tab) {
	fw := &window_own(app).full
	if !platform.is_fullscreen(app.win) { fw.revealed = false; return }
	if !wchrome.cfg.reveal || fullscreen_shell_active(app.active) { fw.revealed = false; return }   // (a page's own full screen keeps the whole window)
	m := ui.mouse_pos()
	if !fw.revealed {
		fw.revealed = m.y >= 0 && m.y < wchrome.cfg.reveal_px && m.x >= 0 && m.x < f32(app.win.size.x)
	} else {
		// they stay while the pointer is over them, a menu of theirs is open or the address bar has the keyboard
		over := m.y < fw.overlay.max.y + ui.font_size()
		fw.revealed = over || ui.ctx_menu_any_open() || (ui.focus_key() != 0 && ui.focus_key() == address_key(app))
	}
	if !fw.revealed { fw.overlay = {}; return }
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(app.win.size.x)), height = ui.children_sum(), axis = .Y})
	col := ui.build_box({.Draw_Background, .Draw_Side_Bottom}, "###fullscreen_bars")
	if ui.parent(col) {
		if tab_strip(app, false) { return }
		toolbar_row(app, t)   // chrome_style.odin
	}
	// (the rect is last layout's: one more frame when it moved, so that the capture follows)
	if col.rect != fw.overlay { request_frames(app, 2) }
	fw.overlay = col.rect
}

// The full screen bars take the clicks and the wheel over them (the page under them does not get them).
fullscreen_bars_capture :: proc(app: ^App, pos: draw.Vec2) -> bool {
	fw := &window_own(app).full
	return fw.revealed && draw.rect_contains(fw.overlay, pos)
}
