package browser

// The toolbar's menu: a right click on the free space of the title bar, on the toolbar where no button is, on the row of
// tabs where no tab is, or on the bookmarks bar. It is the bookmarks bar's own menu (bookmarks_bar_menu: show or hide
// the bar, a new folder in it, the bookmarks) followed by the chrome's choices: where the tabs are, whether they are in
// the title bar, the address bar at full width, and the system's menu of the window.
//
// The free space of an integrated title bar is the system's: a right click there opened the system's menu. The toolkit
// gives that click to Wren instead (platform.set_caption_menu_app, set by window_chrome_frame), and the system's menu
// is the last item here (platform.show_system_menu, after the frame: window_chrome_after_frame).

import "toolkit:platform"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:i18n"

// Once per build: a right click on the free space of the title bar opens the toolbar's menu where it came. Called by
// the part of the chrome that every layout builds once: address_row, or sidebar_titlebar when the toolbar is the title bar.
toolbar_caption_menu :: proc(app: ^App) {
	if at, ok := ui.caption_right_clicked(); ok { bookmarks_bar_menu(app, at) }
}

// The chrome's choices, after the bookmarks bar's items (bookmarks_bar_menus).
toolbar_menu_items :: proc(app: ^App, t: ^Tab) {
	ui.menu_separator()
	menu_command(app, t, "view.tabs_position.top")
	menu_command(app, t, "view.tabs_position.left")
	menu_command(app, t, "view.tabs_position.right")
	menu_command(app, t, "view.tabs_in_title_bar")
	full := app.wchrome.cfg.address_sizing == .Full_Width
	if ui.menu_item(i18n.tr("Address bar at full width"), checked = full).clicked {
		set_pref_string(app, "browser.address_bar.sizing_mode", address_bar_sizing_name(full ? .Centered : .Full_Width))
	}
	w := active_window(app).win
	if platform.is_integrated_title(w) && !platform.is_fullscreen(w) && platform.system_menu_available(w) {
		ui.menu_separator()
		// (the system's menu of the window: restore, move, size, minimize, maximize, close; Wayland: the compositor's)
		if ui.menu_item(i18n.tr("Window menu"), icon = lucide.MENU).clicked { window_menu_ask(app, ui.mouse_pos()) }
	}
}
