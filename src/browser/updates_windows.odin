package browser

import prefs_page "toolkit:prefs_page"
import wren_update "wb:update"

// Wren's Windows release is a program the updater can replace (update-windows-x64.json in each release).
UPDATES_SELF :: true

// After the first window's interface exists (the installed copy's manifest is written on a task of its State). Nothing is
// asked before updates_frame finds the copy installed and update.auto on, or before Check now.
updates_start :: proc(app: ^App) {
	if IS_DEV_BUILD || APP_VERSION_LABEL != "" { return }
	prefs_page.updates_start(&app.updates, {
		product = wren_update.PRODUCT, repository = UPDATE_REPOSITORY, version = APP_VERSION,
		prefs = &app.prefs, install = app.install.prefs != nil ? &app.install : nil, state = active_window(app).ui,
		news = updates_news, user = app,
	})
}
