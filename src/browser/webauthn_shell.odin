package browser

// Passkeys in the shell (page/bindings_webauthn.odin does the ceremonies): which window the system's WebAuthn dialog
// belongs to and whether the asking page is the one the user looks at (security.webauthn.require_focus), and, while a
// page waits for the dialog, a chip in the address bar saying so; clicking it cancels the request (the page gets
// NotAllowedError, as when the dialog is dismissed).

import "core:fmt"
import "toolkit:ui"
import "wb:page"

webauthn_shell_init :: proc(app: ^App) {
	page.webauthn_embedder = {
		window = proc(p: ^page.Page) -> (hwnd: rawptr, focused: bool) {
			app := the_app
			if app == nil || app.win == nil { return nil, true }
			t := current_tab(app)
			shown := t != nil && t.page == p && t.kind == .Web
			return rawptr(app.win.hwnd), shown && (app.win.focused || app.win.active)
		},
		// the chip appears or goes: the next frame draws it (an idle window draws nothing otherwise)
		changed = proc(p: ^page.Page) {
			if the_app != nil { the_app.frames_requested = max(the_app.frames_requested, 2) }
		},
	}
}

webauthn_shell_destroy :: proc() {
	page.webauthn_embedder = {}
	page.webauthn_shutdown()   // cancels what is still waiting and joins its threads, before the loop goes
}

// The address bar's chip while the current page waits for a passkey dialog.
webauthn_chip :: proc(app: ^App, t: ^Tab) {
	if t == nil || t.page == nil { return }
	pending, create, rp_id := page.webauthn_pending(t.page)
	if !pending { return }
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 1.8)), radius = em * CHROME_BUTTON_RADIUS})
	if ui.tags("ghost_button") {
		label := create ? "Creating a passkey" : "Passkey"
		b := ui.button(fmt.aprintf("%s###webauthn_chip", label, allocator = ui.frame_allocator()))
		what := create ? "create a passkey for" : "sign in with a passkey of"
		tip(b, fmt.tprintf("This page asked to %s %s. Windows shows its dialog; click here to cancel the request.", what, rp_id))
		if b.clicked { page.webauthn_cancel(t.page) }
	}
}
