package browser

// The prompt of the Storage Access API (page/storage_access.odin keeps the page's side): a frame of another site asks
// for its own cookies and storage while the person is on the tab's site; a small dialog over the page, "Allow" or
// "Block", one request at a time. browser.dialogs.test_answer answers for tests ("cancel": Block, anything else: Allow).

import "core:fmt"
import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import config "toolkit:config"
import i18n "toolkit:i18n"
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

// Each frame of each window: the answer to the first request waiting goes to its frame, then the prompt shows the next
// one.
storage_access_shell_build :: proc(app: ^App) {
	if code, key, ok := window_view_ended(app, &app.sa_view, STORAGE_ACCESS_VIEW); ok && len(app.sa_queue) > 0 && key == u64(uintptr(app.sa_queue[0])) {
		req := app.sa_queue[0]
		ordered_remove(&app.sa_queue, 0)
		// (Escape, the close cross, a click outside: blocked)
		page.storage_access_done(req, code == int(Permission_Answer.Allow))
		request_frames(app, 2)
	}
	head: ^page.Storage_Access_Ask = len(app.sa_queue) > 0 ? app.sa_queue[0] : nil
	window_view_follow(app, &app.sa_view, STORAGE_ACCESS_VIEW, head, u64(uintptr(head)))
}

// The prompt over the page (views.odin): "Allow" or "Block".
storage_access_view :: proc(v: ^ui.View, req: ^page.Storage_Access_Ask) {
	em := ui.font_size()
	if ui.dialog_body("sa_body") {
		ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s wants to use its cookies and site data while you are on %s"), req.site, req.top), "###sa_what"}, ui.frame_allocator()))
		ui.spacer(ui.px(em * 0.4))
		if ui.tags("weak") { ui.paragraph(strings.concatenate({i18n.tr("Sign-in, payment and comment widgets may need it; it also lets the site recognise you across sites."), "###sa_why"}, ui.frame_allocator())) }
	}
	if ui.dialog_buttons("sa_buttons") {
		if ui.button("###sa_block", i18n.tr("Block"), lucide.SHIELD, {intent = .Danger, width = ui.px(em * 8)}).clicked { ui.view_end(v, int(Permission_Answer.Block)) }
		if ui.button("###sa_allow", i18n.tr("Allow"), lucide.CHECK, {intent = .Success, width = ui.px(em * 8)}).clicked { ui.view_end(v, int(Permission_Answer.Allow)) }
	}
}
