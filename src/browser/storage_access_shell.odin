package browser

// The prompt of the Storage Access API (page/storage_access.odin keeps the page's side): a frame of another site asks
// for its own cookies and storage while the person is on the tab's site; a small dialog over the page, "Allow" or
// "Block", one request at a time. browser.dialogs.test_answer answers for tests ("cancel": Block, anything else: Allow).

import "core:fmt"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:config"
import "wb:i18n"
import "wb:page"


storage_access_shell_init :: proc(app: ^App) {
	app.pages.storage_access_embedder = {ask = storage_access_shell_ask, user = app}
}

storage_access_shell_destroy :: proc(app: ^App) {
	app.pages.storage_access_embedder = {}
	for r in app.sa_queue { page.storage_access_done(r, false) }
	delete(app.sa_queue)
	app.sa_queue = nil
}

@(private = "file")
storage_access_shell_ask :: proc(user: rawptr, p: ^page.Page, req: ^page.Storage_Access_Ask) {
	app := (^App)(user)
	switch config.string_of(&app.prefs, "browser.dialogs.test_answer") {
	case "": append(&app.sa_queue, req)
	case "cancel": page.storage_access_done(req, false)
	case: page.storage_access_done(req, true)
	}
	request_frames(app, 2)
}

// The prompt over the page (the first request waiting), each frame while one waits.
storage_access_shell_build :: proc(app: ^App) {
	if len(app.sa_queue) == 0 { return }
	req := app.sa_queue[0]
	em := ui.font_size()
	open := true
	answered, granted := false, false
	if ui.modal("storage_access", em * 32, &open) {
		ui.dialog_header("sa_header", i18n.tr("Cookies and site data"), lucide.COOKIE, app.lucide)
		if ui.dialog_body("sa_body") {
			dialog_line(fmt.tprintf(i18n.tr("%s wants to use its cookies and site data while you are on %s"), req.site, req.top), "sa_what")
			ui.spacer(ui.px(em * 0.4))
			dialog_line(i18n.tr("Sign-in, payment and comment widgets may need it; it also lets the site recognise you across sites."), "sa_why", weak = true)
		}
		if ui.dialog_buttons("sa_buttons") {
			if icon_action_button(app, lucide.SHIELD, i18n.tr("Block"), "sa_block", ui.px(em * 8), intent = .Danger) { answered, granted = true, false }
			ui.spacer(ui.px(em * 0.6))
			if icon_action_button(app, lucide.CHECK, i18n.tr("Allow"), "sa_allow", ui.px(em * 8), intent = .Success) { answered, granted = true, true }
		}
	}
	if !open { answered, granted = true, false }   // Escape, a click outside: blocked
	if answered {
		ordered_remove(&app.sa_queue, 0)
		page.storage_access_done(req, granted)
		request_frames(app, 2)
	}
}
