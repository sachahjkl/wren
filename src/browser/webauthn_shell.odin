package browser

// Passkeys in the shell (page/bindings_webauthn.odin does the ceremonies): which window the system's WebAuthn dialog
// belongs to and whether the asking page is the one the user looks at (security.webauthn.require_focus), and, while a
// page waits for the dialog, a chip in the address bar saying so; clicking it cancels the request (the page gets
// NotAllowedError, as when the dialog is dismissed). A page's get asks the Vault first (passkey_choice.odin).

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
		// a page's get: the unlocked Vault's passkeys of its site are offered first (passkey_choice.odin)
		provider = proc(p: ^page.Page, rq: ^page.Webauthn_Provider_Request) -> bool {
			return the_app != nil && passkey_choice_offer(the_app, rq)
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
	passkey_choice_reset(app)
	if q := webauthn.pin_question(); q.number != 0 { webauthn.pin_answer(q.number, "", false) }   // (a ceremony that waits for a PIN stops waiting)
	if q := webauthn.choose_question(); q.number != 0 { webauthn.choose_answer(q.number, 0, false) }   // (and one that waits for an account)
	ui.line_edit_wipe(&app.key_pin.field)
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
		b := ui.button("webauthn_chip", label)
		what := create ? "create a passkey for" : "sign in with a passkey of"
		tip(b, fmt.tprintf("This page asked to %s %s. Windows shows its dialog; click here to cancel the request.", what, rp_id))
		if b.clicked { page.webauthn_cancel(t.page) }
	}
}


// The dialog of a security key's PIN (webauthn/pin.odin): open while a ceremony waits for it.
Key_Pin_Dialog :: struct {
	number: u64,             // the question it shows (0: none)
	field:  ui.Line_Edit,
	reveal: bool,
	focus:  bool,            // the field takes the focus in the next build (a question that opens)
	size:   ui.Vec2,
	touch_size: ui.Vec2,
	choose_number: u64,      // the account question it shows (0: none)
	choose_sel:    int,      // the row Up, Down and Enter act on
	choose_size:   ui.Vec2,
}

webauthn_pin_build :: proc(app: ^App) {
	// (the Vault's passkeys or the platform: asked before a platform ceremony starts, so never with its PIN or touch)
	passkey_choice_build(app)
	d := &app.key_pin
	q := webauthn.pin_question()
	if q.number != d.number {
		// (a new question, or the old one over: what was typed for another goes)
		ui.line_edit_wipe(&d.field)
		d.number, d.reveal, d.focus = q.number, false, true
	}
	if q.number == 0 {
		// (one question at a time: the account is chosen after the key's touch, the touch waits after the PIN)
		if !webauthn_choose_build(app) { webauthn_touch_build(app) }
		return
	}
	em := ui.font_size()
	open := true
	submit, cancel := false, false
	if ui.modal("key_pin", &open, {width_em = 26, min_width_em = 20, min_height_em = 11, size = &d.size}) {
		if ui.dialog_header("kp_title", i18n.tr("Security key PIN"), {icon = lucide.USB, icon_font = app.lucide}) {}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###kp_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###kp_margins") {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###kp_col") {
					ui.spacer(ui.px(em * 0.9))
					if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s asks for your security key. Type its PIN, then touch the key when it blinks."), q.rp_id), "###kp_hint"}, ui.frame_allocator())) }
					if q.wrong || (q.retries >= 0 && q.retries <= 3) {
						ui.spacer(ui.px(em * 0.3))
						words := q.wrong ? fmt.tprintf(i18n.tr("Wrong PIN. %d tries left before the key blocks."), q.retries) : fmt.tprintf(i18n.tr("%d tries left before the key blocks."), q.retries)
						if q.retries < 0 { words = i18n.tr("Wrong PIN.") }
						ui.paragraph(strings.concatenate({words, "###kp_wrong"}, ui.frame_allocator()))
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
			if ui.button("###kp_cancel", i18n.tr("Cancel"), lucide.X, {intent = .Cancel, width = ui.px(em * 8)}).clicked { cancel = true }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("###kp_ok", i18n.tr("OK"), lucide.CHECK, {intent = .Success, width = ui.px(em * 8)}).clicked { submit = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if submit && strings.trim_space(ui.line_edit_string(&d.field)) != "" {
		webauthn.pin_answer(d.number, ui.line_edit_string(&d.field), true)
		ui.line_edit_wipe(&d.field)
	} else if cancel || !open {
		webauthn.pin_answer(d.number, "", false)
		ui.line_edit_wipe(&d.field)
	}
}

// The account to sign in with, when the key holds several passkeys of the site (webauthn/pin.odin's choose question):
// one row per account, a click or Enter chooses, Up and Down move, Cancel refuses (the page gets NotAllowedError).
// false: no such question is open.
@(private = "file")
webauthn_choose_build :: proc(app: ^App) -> bool {
	d := &app.key_pin
	q := webauthn.choose_question()
	if q.number != d.choose_number { d.choose_number, d.choose_sel = q.number, 0 }
	if q.number == 0 { return false }
	n := len(q.accounts)
	d.choose_sel = clamp(d.choose_sel, 0, max(n - 1, 0))
	em := ui.font_size()
	open := true
	cancel := false
	chosen := -1
	if ui.modal("key_choose", &open, {width_em = 26, min_width_em = 20, min_height_em = 12, size = &d.choose_size}) {
		if ui.key_press(.Down) { d.choose_sel = min(d.choose_sel + 1, n - 1) }
		if ui.key_press(.Up) { d.choose_sel = max(d.choose_sel - 1, 0) }
		if ui.key_press(.Return) { chosen = d.choose_sel }
		if ui.dialog_header("kc_title", i18n.tr("Choose an account"), {icon = lucide.USER, icon_font = app.lucide}) {}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###kc_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###kc_margins") {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###kc_col") {
					ui.spacer(ui.px(em * 0.9))
					if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("Your security key holds several passkeys of %s. Choose the one to sign in with."), q.rp_id), "###kc_hint"}, ui.frame_allocator())) }
					ui.spacer(ui.px(em * 0.8))
					for a, i in q.accounts {
						title, detail := a.display_name, a.name
						if title == "" { title, detail = a.name, "" }
						if title == "" { title = i18n.tr("Account without a name") }
						if ui.choice_row(fmt.tprintf("kc_row_%d", i), i, &d.choose_sel, title, detail, lucide.USER, app.lucide) { chosen = i }
					}
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###kc_buttons") {
			ui.spacer(ui.fill())
			if ui.button("###kc_cancel", i18n.tr("Cancel"), lucide.X, {intent = .Cancel, width = ui.px(em * 8)}).clicked { cancel = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if chosen >= 0 && chosen < n {
		webauthn.choose_answer(q.number, chosen, true)
	} else if cancel || !open {
		webauthn.choose_answer(q.number, 0, false)
	}
	return true
}

// While the key waits for the person's touch (after its PIN, or at once): what to do, and a Cancel that stops the
// ceremony.
@(private = "file")
webauthn_touch_build :: proc(app: ^App) {
	d := &app.key_pin
	q := webauthn.touch_question()
	if q.number == 0 { return }
	em := ui.font_size()
	open := true
	cancel := false
	if ui.modal("key_touch", &open, {width_em = 26, min_width_em = 20, min_height_em = 8, size = &d.touch_size}) {
		if ui.dialog_header("kt_title", i18n.tr("Touch your security key"), {icon = lucide.USB, icon_font = app.lucide}) {}
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###kt_scroll") {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###kt_margins") {
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.column(.Start, {}, "###kt_col") {
					ui.spacer(ui.px(em * 0.9))
					// (the spinner says that the key waits; the title is the header's)
					ui.next({width = ui.fill(), height = ui.children_sum()})
					if ui.row(.Center, {}, "###kt_head") {
						ui.spinner("###vd_spinner", em * 1.3)
						ui.spacer(ui.px(em * 0.5))
						if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s asks for your security key. Touch its button or its gold disc now: it blinks while it waits."), q.rp_id), "###kt_hint"}, ui.frame_allocator())) }
					}
					ui.spacer(ui.px(em * 0.4))
				}
				ui.spacer(ui.px(em * 1.0))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###kt_buttons") {
			ui.spacer(ui.fill())
			if ui.button("###kt_cancel", i18n.tr("Cancel"), lucide.X, {intent = .Cancel, width = ui.px(em * 8)}).clicked { cancel = true }
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if cancel || !open { webauthn.touch_cancel(q.number) }
}
