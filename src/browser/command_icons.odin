package browser

// The Lucide icon of each command (its menus' rows, the palette's): by the command's stable name, or the prefix of a family of
// generated ones (view.theme.<slug>). One table: a new command gets its icon here, its menus and the palette show it.

import lucide "toolkit:lucide"

@(private = "file")
COMMAND_ICONS :: [?][2]string{
	{"tab.new", lucide.PLUS}, {"tab.reopen_closed", lucide.ROTATE_CCW}, {"tab.close", lucide.X},
	{"tab.close_others", lucide.X}, {"tab.duplicate", lucide.COPY}, {"tab.next", lucide.ARROW_RIGHT},
	{"tab.previous", lucide.ARROW_LEFT}, {"tab.move_right", lucide.CHEVRON_RIGHT}, {"tab.move_left", lucide.CHEVRON_LEFT},
	{"tab.move_to_new_window", lucide.APP_WINDOW}, {"tab.restore_crashed", lucide.ARCHIVE_RESTORE}, {"tab.pin", lucide.PIN},
	{"tab.mute", lucide.VOLUME_X}, {"tab.fold", lucide.LIST_TREE}, {"tab.group_new", lucide.LAYERS_2},
	{"tab.group_leave", lucide.SEND_TO_BACK}, {"tab.group_collapse", lucide.CHEVRON_UP}, {"tab.group_rename", lucide.PENCIL},
	{"tab.group_color.", lucide.PALETTE},
	{"window.new_private", lucide.HAT_GLASSES}, {"window.new", lucide.APP_WINDOW},
	{"nav.back", lucide.ARROW_LEFT}, {"nav.forward", lucide.ARROW_RIGHT}, {"nav.reload_bypass_cache", lucide.REFRESH_CW},
	{"nav.reload", lucide.REFRESH_CW}, {"nav.stop", lucide.X}, {"nav.home", lucide.HOME},
	{"nav.focus_address", lucide.TEXT_CURSOR_INPUT}, {"nav.focus_toggle", lucide.ARROW_UP_DOWN},
	{"view.chrome_zoom_in", lucide.ZOOM_IN}, {"view.chrome_zoom_out", lucide.ZOOM_OUT}, {"view.chrome_zoom_reset", lucide.SEARCH},
	{"page.zoom_in", lucide.ZOOM_IN}, {"page.zoom_out", lucide.ZOOM_OUT}, {"page.zoom_reset", lucide.SEARCH},
	{"page.find", lucide.SEARCH}, {"page.save", lucide.SAVE}, {"page.view_source", lucide.FILE_CODE},
	{"page.print", lucide.FILE_TEXT}, {"page.copy_address", lucide.LINK}, {"page.qr_code", lucide.QR_CODE},
	{"page.info", lucide.INFO}, {"page.javascript_site", lucide.CODE},
	{"view.status_bar", lucide.PANEL_BOTTOM}, {"view.smooth_scrolling", lucide.ARROW_UP_DOWN},
	{"view.autoscroll", lucide.ARROW_UP_DOWN}, {"view.frame_statistics", lucide.GAUGE}, {"view.title_statistics", lucide.GAUGE},
	{"view.frame_cap.", lucide.GAUGE}, {"view.console", lucide.SQUARE_TERMINAL},
	{"view.devtools_elements", lucide.CODE}, {"view.devtools_network", lucide.NETWORK},
	{"view.devtools_dock_bottom", lucide.PANEL_BOTTOM}, {"view.devtools_dock_right", lucide.PANEL_RIGHT},
	{"view.devtools_dock_left", lucide.PANEL_LEFT}, {"view.devtools_dock_floating", lucide.APP_WINDOW},
	{"view.devtools_detach", lucide.EXTERNAL_LINK}, {"view.devtools_application", lucide.DATABASE},
	{"view.devtools_performance", lucide.GAUGE}, {"view.devtools_memory", lucide.MICROCHIP},
	{"view.devtools_pick", lucide.TEXT_CURSOR_INPUT}, {"view.devtools_larger", lucide.ZOOM_IN},
	{"view.devtools_smaller", lucide.ZOOM_OUT}, {"view.devtools_reset_layout", lucide.LAYOUT_GRID},
	{"view.devtools_clear_console", lucide.TRASH_2}, {"view.devtools_clear_network", lucide.TRASH_2},
	{"view.devtools_speed.", lucide.NETWORK}, {"view.devtools", lucide.WRENCH},
	{"view.full_screen", lucide.MONITOR}, {"view.tabs_in_title_bar", lucide.APP_WINDOW},
	{"view.tabs_position.", lucide.COLUMNS_2}, {"view.tabs_sidebar_collapse", lucide.PANEL_LEFT},
	{"view.theme_mode.", lucide.SUN_MOON}, {"view.theme.", lucide.PALETTE}, {"view.chrome_style.", lucide.SLIDERS_HORIZONTAL}, {"view.finish.", lucide.BRUSH},
	{"view.bookmarks_bar", lucide.BOOKMARK},
	{"browser.command_palette", lucide.COMMAND}, {"browser.main_menu", lucide.MENU}, {"browser.history_tree", lucide.GIT_FORK},
	{"browser.history", lucide.HISTORY}, {"browser.downloads_folder", lucide.FOLDER_OPEN}, {"browser.downloads", lucide.DOWNLOAD},
	{"browser.settings", lucide.SETTINGS}, {"browser.setup", lucide.PACKAGE}, {"browser.check_updates", lucide.REFRESH_CW},
	{"browser.install_update", lucide.HARD_DRIVE_DOWNLOAD}, {"browser.desktop_integration", lucide.MONITOR},
	{"browser.default_apps", lucide.SETTINGS}, {"browser.demos", lucide.PLAY}, {"browser.about_pages", lucide.BOOK_OPEN},
	{"browser.about_licenses", lucide.SCROLL_TEXT}, {"browser.about_cache", lucide.HARD_DRIVE}, {"browser.about_sites", lucide.COOKIE},
	{"browser.about", lucide.INFO}, {"browser.clear_cache", lucide.TRASH_2}, {"browser.javascript", lucide.CODE},
	{"browser.profile_folder", lucide.FOLDER}, {"browser.session_restore", lucide.ARCHIVE_RESTORE},
	{"browser.bookmarks", lucide.BOOKMARK}, {"bookmark.page", lucide.STAR}, {"bookmarks.import", lucide.FOLDER_INPUT},
	{"bookmarks.export", lucide.FOLDER_OUTPUT},
	{"blocker.picker", lucide.TEXT_CURSOR_INPUT}, {"blocker.dashboard", lucide.LAYOUT_GRID}, {"blocker.journal", lucide.LIST},
	{"blocker.filters", lucide.FILTER}, {"blocker.update", lucide.REFRESH_CW}, {"blocker.", lucide.SHIELD},
	{"vault.fill", lucide.TEXT_CURSOR_INPUT}, {"vault.search", lucide.SEARCH}, {"vault.unlock", lucide.LOCK},
	{"vault.lock", lucide.LOCK}, {"vault.sync", lucide.REFRESH_CW}, {"vault.", lucide.LOCK},
}

// The icon of the command `name`: its own entry, else the longest prefix that ends with "." ("" when none). The table lists a
// name before a shorter one it starts with (view.devtools_* before view.devtools).
command_icon :: proc(name: string) -> string {
	for e in COMMAND_ICONS {
		key := e[0]
		if key == name { return e[1] }
		if len(key) > 0 && key[len(key) - 1] == '.' && len(name) > len(key) && name[:len(key)] == key { return e[1] }
	}
	return ""
}
