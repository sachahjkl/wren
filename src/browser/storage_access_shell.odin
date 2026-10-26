package browser

// The prompt of the Storage Access API (page/storage_access.odin keeps the page's side): a frame of another site asks
// for its own cookies and storage while the person is on the tab's site; a small dialog over the page, "Allow" or
// "Block", one request at a time. browser.dialogs.test_answer answers for tests ("cancel": Block, anything else: Allow).

import "core:fmt"
import "toolkit:ui"
import "wb:config"
import "wb:i18n"
import "wb:page"

@(private = "file")
sa_queue: [dynamic]^page.Storage_Access_Ask

storage_access_shell_init :: proc(app: ^App) {
	page.storage_access_embedder = {ask = storage_access_shell_ask, user = app}
}

storage_access_shell_destroy :: proc(app: ^App) {
	page.storage_access_embedder = {}
	for r in sa_queue { page.storage_access_done(r, false) }
	delete(sa_queue)
	sa_queue = nil
}

@(private = "file")
storage_access_shell_ask :: proc(user: rawptr, p: ^page.Page, req: ^page.Storage_Access_Ask) {
	app := (^App)(user)
	switch config.string_of(&app.prefs, "browser.dialogs.test_answer") {
	case "": append(&sa_queue, req)
	case "cancel": page.storage_access_done(req, false)
	case: page.storage_access_done(req, true)
	}
	app.frames_requested = max(app.frames_requested, 2)
}

// The prompt over the page (the first request waiting), each frame while one waits.
storage_access_shell_build :: proc(app: ^App) {
	if len(sa_queue) == 0 { return }
	req := sa_queue[0]
	em := ui.font_size()
	open := true
	answered, granted := false, false
	if ui.modal("storage_access", em * 32, &open) {
		ui.spacer(ui.px(em * 0.8))
		ui.label(fmt.tprintf(i18n.tr("%s wants to use its cookies and site data while you are on %s"), req.site, req.top))
		ui.label(i18n.tr("Sign-in, payment and comment widgets may need it; it also lets the site recognise you across sites."))
		ui.spacer(ui.px(em * 0.8))
		if ui.row() {
			if action_button(i18n.tr("Allow"), "sa_allow", em * 8) { answered, granted = true, true }
			ui.spacer(ui.px(em * 0.6))
			if action_button(i18n.tr("Block"), "sa_block", em * 8) { answered, granted = true, false }
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if !open { answered, granted = true, false }   // Escape, a click outside: blocked
	if answered {
		ordered_remove(&sa_queue, 0)
		page.storage_access_done(req, granted)
		app.frames_requested = max(app.frames_requested, 2)
	}
}
