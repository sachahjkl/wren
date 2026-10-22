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

import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

WINDOW_PREFS := [?]config.Def{
	{name = "browser.window.integrated_titlebar", kind = .Bool, default = {b = true},
		description = "The row of tabs is the window's title bar, as in Edge and Chrome: the browser draws the minimize, maximize and close buttons and the free space next to the tabs drags the window. Off: the title bar of Windows above the tabs. Applies at once."},
	{name = "browser.window.min_drag_em", kind = .Float, default = {f = 3}, bounded = true, min = 0, max = 40, unit = "em",
		description = "Free space kept in the title bar between the tabs and the window buttons, to drag the window when there are many tabs (the tabs are cut off before it)."},
	{name = "browser.window.fullscreen_reveal", kind = .Bool, default = {b = true},
		description = "In full screen (F11), the tabs and the address bar slide down over the page while the pointer is at the top edge of the screen."},
	{name = "browser.window.fullscreen_reveal_px", kind = .Int, default = {i = 3}, bounded = true, min = 1, max = 200, unit = "px",
		description = "Height of the strip along the top of the screen that brings the tabs and the address bar back in full screen."},
	{name = "browser.window.square_corners", kind = .Bool, default = {b = true},
		description = "Square corners on the window itself (Windows 11 rounds them, Windows 10 never does). On (the default): the corners are cut square, by DWM_WINDOW_CORNER_PREFERENCE. Off: the system's rounded corners. Applies at once."},
	{name = "browser.window.fixed_surface", kind = .Bool, default = {b = true}, restart = true,
		description = "Never resize the surface the window shows: a composition swap chain holds one surface (the monitor's size) and the window shows the top-left part of it, 1:1, clipped. A window being resized then cuts what was drawn instead of stretching it, and the newly shown strip stays the background until the next frame paints it. Needs a restart; falls back to the usual swap chain when the system cannot compose."},
}

register_window_prefs :: proc(p: ^config.Prefs) { config.register(p, WINDOW_PREFS[:]) }

Window_Settings :: struct {
	integrated:  bool,
	min_drag_em: f32,
	reveal:      bool,
	reveal_px:   f32,
	square_corners: bool,
}

window_settings_from_prefs :: proc(p: ^config.Prefs) -> Window_Settings {
	return {
		integrated = config.bool_of(p, "browser.window.integrated_titlebar"),
		min_drag_em = f32(config.float_of(p, "browser.window.min_drag_em")),
		reveal = config.bool_of(p, "browser.window.fullscreen_reveal"),
		reveal_px = f32(config.int_of(p, "browser.window.fullscreen_reveal_px")),
		square_corners = config.bool_of(p, "browser.window.square_corners"),
	}
}

Window_Chrome :: struct {
	cfg:          Window_Settings,
	watch:        int,
	revealed:     bool,          // full screen: the bars are shown over the page
	overlay:      draw.Rect,     // where they were last frame
	icon:         render.Texture,
	icon_px:      int,           // size of `icon` (0: none made yet)
	icon_failed:  int,           // a size the exe's icon could not be loaded at
}

wchrome: Window_Chrome

window_chrome_init :: proc(app: ^App) {
	wchrome.cfg = window_settings_from_prefs(&app.prefs)
	platform.set_square_corners(app.win, wchrome.cfg.square_corners)
	wchrome.watch = config.watch(&app.prefs, "browser.window.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		wchrome.cfg = window_settings_from_prefs(p)
		platform.set_square_corners(app.win, wchrome.cfg.square_corners)
		app.frames_requested = max(app.frames_requested, 2)
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
	ui.set_scroll_settings(&app.ui_state, {curve = curve, impulse = f32(sc.impulse), duration_ms = dur})
}

toggle_fullscreen :: proc(app: ^App) {
	on := !platform.is_fullscreen(app.win)
	platform.set_fullscreen(app.win, on)
	wchrome.revealed = false
	render.resize(&app.r, app.win.size)
	app.frames_requested = max(app.frames_requested, 3)
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
	if sig.clicked || sig.right_clicked { platform.show_system_menu(app.win, {b.rect.min.x, b.rect.max.y}) }
}

// Full screen: the bars over the top of the page while revealed. Built after the page so they draw over it.
fullscreen_bars :: proc(app: ^App, t: ^Tab) {
	if !platform.is_fullscreen(app.win) { wchrome.revealed = false; return }
	if !wchrome.cfg.reveal { wchrome.revealed = false; return }
	m := ui.mouse_pos()
	if !wchrome.revealed {
		wchrome.revealed = m.y >= 0 && m.y < wchrome.cfg.reveal_px && m.x >= 0 && m.x < f32(app.win.size.x)
	} else {
		// they stay while the pointer is over them, a menu of theirs is open or the address bar has the keyboard
		over := m.y < wchrome.overlay.max.y + ui.font_size()
		wchrome.revealed = over || ui.ctx_menu_any_open() || (ui.focus_key() != 0 && ui.focus_key() == address_key)
	}
	if !wchrome.revealed { wchrome.overlay = {}; return }
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(f32(app.win.size.x)), height = ui.children_sum(), axis = .Y})
	col := ui.build_box({.Draw_Background, .Draw_Side_Bottom}, "###fullscreen_bars")
	if ui.parent(col) {
		if tab_strip(app, false) { return }
		em := ui.font_size()
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
		if ui.row(.Center) { address_row(app, t) }
	}
	// (the rect is last layout's: one more frame when it moved, so that the capture follows)
	if col.rect != wchrome.overlay { app.frames_requested = max(app.frames_requested, 2) }
	wchrome.overlay = col.rect
}

// The full screen bars take the clicks and the wheel over them (the page under them does not get them).
fullscreen_bars_capture :: proc(pos: draw.Vec2) -> bool {
	return wchrome.revealed && draw.rect_contains(wchrome.overlay, pos)
}
