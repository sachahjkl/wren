package browser

// Passkeys in the shell (page/bindings_webauthn.odin does the ceremonies): which window the system's WebAuthn dialog
// belongs to and whether the asking page is the one the user looks at (security.webauthn.require_focus), and, while a
// page waits for the dialog, a chip in the address bar saying so; clicking it cancels the request (the page gets
// NotAllowedError, as when the dialog is dismissed).

import "core:fmt"
import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import "wb:host"
import "wb:i18n"
import "wb:page"
import "wb:webauthn"

webauthn_shell_init :: proc(app: ^App) {
	app.pages.webauthn_embedder = {
		window = proc(p: ^page.Page) -> (hwnd: rawptr, focused: bool) {
			app := the_app
			if app == nil || active_window(app).win == nil { return nil, true }
			t := current_tab(app)
			shown := t != nil && t.page == p && t.kind == .Web
			// the native window handle the system WebAuthn dialog belongs to (Windows' webauthn.dll; 0 on Linux, where
			// libfido2 needs none — window_native_handle, remote_window_<os>.odin)
			return rawptr(uintptr(window_native_handle(active_window(app).win))), shown && (active_window(app).win.focused || active_window(app).win.active)
		},
		// the chip appears or goes: the next frame draws it (an idle window draws nothing otherwise)
		changed = proc(p: ^page.Page) {
			if the_app != nil { request_frames(the_app, 2) }
		},
	}
	// a security key's PIN is asked on the ceremony's thread: the loop wakes, the next frame shows the question
	webauthn.pin_wake = proc "contextless" () {
		context = base.process_context()
		if the_app != nil { host.post(&the_app.loop, proc(_: rawptr) { if the_app != nil { request_frames(the_app, 2) } }, nil) }
	}
}

webauthn_shell_destroy :: proc(app: ^App) {
	app.pages.webauthn_embedder = {}
	if q := webauthn.pin_question(); q.number != 0 { webauthn.pin_answer(q.number, "", false) }   // (a ceremony that waits for a PIN stops waiting)
	secret_wipe(&app.key_pin.field)
	page.webauthn_shutdown(app.page_settings.authn.cancel_grace_ms)   // cancels what still waits and joins its threads, before the loop goes
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


// The dialog of a security key's PIN (webauthn/pin.odin): open while a ceremony waits for it.
Key_Pin_Dialog :: struct {
	number: u64,             // the question it shows (0: none)
	field:  ui.Text_Field,
	reveal: bool,
	focus:  bool,            // the field takes the focus in the next build (a question that opens)
	size:   ui.Vec2,
	body:   ui.Key,          // the box of what it says (dialog_preferred)
}

webauthn_pin_build :: proc(app: ^App) {
	d := &app.key_pin
	q := webauthn.pin_question()
	if q.number != d.number {
		// (a new question, or the old one over: what was typed for another goes)
		secret_wipe(&d.field)
		d.number, d.reveal, d.focus = q.number, false, true
	}
	if q.number == 0 { return }
	em := ui.font_size()
	open := true
	submit, cancel := false, false
	if ui.modal_sized("key_pin", dialog_preferred(d.body, em * 26, em * 15), &d.size, &open, {em * 20, em * 11}) {
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###kp_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###kp_margins") {
				d.body = ui.parent_box().key
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###kp_col") {
					ui.spacer(ui.px(em * 0.9))
					dialog_line(i18n.tr("Security key PIN"), "kp_title")
					ui.spacer(ui.px(em * 0.5))
					dialog_line(fmt.tprintf(i18n.tr("%s asks for your security key. Type its PIN, then touch the key."), q.rp_id), "kp_hint", weak = true)
					if q.wrong || (q.retries >= 0 && q.retries <= 3) {
						ui.spacer(ui.px(em * 0.3))
						words := q.wrong ? fmt.tprintf(i18n.tr("Wrong PIN. %d tries left before the key blocks."), q.retries) : fmt.tprintf(i18n.tr("%d tries left before the key blocks."), q.retries)
						if q.retries < 0 { words = i18n.tr("Wrong PIN.") }
						dialog_line(words, "kp_wrong")
					}
					ui.spacer(ui.px(em * 0.8))
					box := dialog_field("###kp_field", &d.field, i18n.tr("PIN"), true, &submit, &cancel, &d.reveal)
					if d.focus && box != nil { d.focus = false; ui.set_focus(box.key) }
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###kp_buttons") {
			ui.spacer(ui.fill())
			if icon_action_button(app, lucide.X, i18n.tr("Cancel"), "kp_cancel", ui.px(em * 8)) { cancel = true }
			ui.spacer(ui.px(em * 0.5))
			if icon_action_button(app, lucide.CHECK, i18n.tr("OK"), "kp_ok", ui.px(em * 8)) { submit = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if submit && strings.trim_space(ui.field_string(&d.field)) != "" {
		webauthn.pin_answer(d.number, ui.field_string(&d.field), true)
		secret_wipe(&d.field)
	} else if cancel || !open {
		webauthn.pin_answer(d.number, "", false)
		secret_wipe(&d.field)
	}
}
