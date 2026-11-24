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
import i18n "toolkit:i18n"
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
	// a security key's PIN, touch or account prompt opens on the ceremony's thread: wake the UI loop with the
	// process-safe App pointer (thread-local the_app is nil on worker threads)
	webauthn.pin_wake_set(proc "contextless" (user: rawptr) {
		context = base.process_context()
		app := (^App)(user)
		if app == nil { return }
		host.post(&app.loop, proc(data: rawptr) {
			app := (^App)(data)
			if app != nil && the_app == app { request_frames(app, 2) }
		}, app)
	}, app)
}

webauthn_shell_destroy :: proc(app: ^App) {
	app.pages.webauthn_embedder = {}
	passkey_choice_reset(app)
	webauthn.pin_dismiss()   // (a ceremony that waits for a PIN or account stops waiting)
	ui.line_edit_wipe(&app.key_pin.field)
	page.webauthn_shutdown(app.page_settings.authn.cancel_grace_ms)   // cancels what still waits and joins its threads, before the loop goes
	webauthn.pin_wake_set(nil, nil)
}

// The address bar's chip while the current page waits for a passkey dialog.
webauthn_chip :: proc(app: ^App, t: ^Tab) {
	if t == nil || t.page == nil { return }
	pending, create, rp_id := page.webauthn_pending(t.page)
	if !pending { return }
	em := ui.font_size()
	ui.space(ui.TOOL_GAP)
	ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 1.8)), radius = em * CHROME_BUTTON_RADIUS})
	if ui.tags("ghost_button") {
		label := create ? "Creating a passkey" : "Passkey"
		b := ui.button("webauthn_chip", label)
		what := create ? "create a passkey for" : "sign in with a passkey of"
		tip(b, fmt.tprintf("This page asked to %s %s. Follow the passkey prompt, or click here to cancel the request.", what, rp_id))
		if b.clicked { page.webauthn_cancel(t.page) }
	}
}


// The views of a security key's questions (webauthn/pin.odin): its PIN, the account to sign in with, the wait for its
// touch. Each is open while a ceremony waits for it, one at a time: the account is chosen after the key's touch, the
// touch waits after the PIN.
Key_Pin_Dialog :: struct {
	number: u64,             // the PIN question it shows (0: none)
	field:  ui.Line_Edit,
	reveal: bool,
	focus:  bool,            // the field takes the focus in the next build (a question that opens)
	pin_view:      Window_View,
	choose_number: u64,      // the account question it shows (0: none)
	choose_sel:    int,      // the row Up, Down and Enter act on
	choose_view:   Window_View,
	touch_view:    Window_View,
	touch_cancelled: u64,    // the wait the person gave up: its view stays closed until its ceremony ends it
}

// Each frame of each window: the answers to the key's questions, then the view of the question open.
webauthn_pin_build :: proc(app: ^App) {
	// (the Vault's passkeys or the platform: asked before a platform ceremony starts, so never with its PIN or touch)
	passkey_choice_build(app)
	d := &app.key_pin
	if code, number, ok := window_view_ended(app, &d.pin_view, KEY_PIN_VIEW); ok {
		// (OK with a PIN typed; anything else refuses: Cancel, Escape, the close cross)
		if code != ui.VIEW_CANCELLED && strings.trim_space(ui.line_edit_string(&d.field)) != "" {
			webauthn.pin_answer(number, ui.line_edit_string(&d.field), true)
		} else {
			webauthn.pin_answer(number, "", false)
		}
		ui.line_edit_wipe(&d.field)
	}
	if code, number, ok := window_view_ended(app, &d.choose_view, KEY_CHOOSE_VIEW); ok {
		if code >= 0 { webauthn.choose_answer(number, code, true) } else { webauthn.choose_answer(number, 0, false) }
	}
	if _, number, ok := window_view_ended(app, &d.touch_view, KEY_TOUCH_VIEW); ok {
		webauthn.touch_cancel(number)
		d.touch_cancelled = number
	}
	q := webauthn.pin_question()
	defer webauthn.pin_question_destroy(&q)
	if q.number != d.number {
		// (a new question, or the old one over: what was typed for another goes)
		ui.line_edit_wipe(&d.field)
		d.number, d.reveal, d.focus = q.number, false, true
	}
	cq := webauthn.choose_question()
	defer webauthn.choose_question_destroy(&cq)
	if cq.number != d.choose_number { d.choose_number, d.choose_sel = cq.number, 0 }
	tq := webauthn.touch_question()
	defer webauthn.touch_question_destroy(&tq)
	pin_key := q.number
	choose_key := pin_key == 0 ? cq.number : 0
	touch_key: u64 = pin_key == 0 && choose_key == 0 && tq.number != d.touch_cancelled ? tq.number : 0
	window_view_follow(app, &d.pin_view, KEY_PIN_VIEW, app, pin_key)
	window_view_follow(app, &d.choose_view, KEY_CHOOSE_VIEW, app, choose_key)
	window_view_follow(app, &d.touch_view, KEY_TOUCH_VIEW, app, touch_key)
}

// The key's PIN (views.odin): OK ends it with the PIN typed, in its field.
key_pin_view :: proc(v: ^ui.View, app: ^App) {
	d := &app.key_pin
	q := webauthn.pin_question()
	defer webauthn.pin_question_destroy(&q)
	if q.number == 0 { return }   // (over: webauthn_pin_build closes it)
	em := ui.font_size()
	submit, cancel := false, false
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###kp_scroll") {
		if ui.dialog_body("kp_body") {
			if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s asks for your security key. Type its PIN, then touch the key when it blinks."), q.rp_id), "###kp_hint"}, ui.frame_allocator())) }
			if q.wrong || (q.retries >= 0 && q.retries <= 3) {
				ui.space(ui.LINE_GAP)
				words := q.wrong ? fmt.tprintf(i18n.tr("Wrong PIN. %d tries left before the key blocks."), q.retries) : fmt.tprintf(i18n.tr("%d tries left before the key blocks."), q.retries)
				if q.retries < 0 { words = i18n.tr("Wrong PIN.") }
				ui.paragraph(strings.concatenate({words, "###kp_wrong"}, ui.frame_allocator()))
			}
			ui.space(ui.LINE_GAP)
			// (Enter answers, Escape cancels; a secret: the eye, no edit menu)
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
			r := ui.line_edit("###kp_field", &d.field, {placeholder = i18n.tr("PIN"), kind = .Secret, reveal = &d.reveal, own_menu = true})
			submit, cancel = r.committed, r.cancelled
			if d.focus && r.box != nil { d.focus = false; ui.set_focus(r.box.key) }
		}
	}
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Center, {}, "###kp_buttons") {
		ui.spacer(ui.fill())
		if ui.button("###kp_cancel", i18n.tr("Cancel"), lucide.X, {width = ui.px(em * 8)}).clicked { cancel = true }
		ui.space(ui.CONTROL_GAP)
		if ui.button("###kp_ok", i18n.tr("OK"), lucide.CHECK, {intent = .Success, width = ui.px(em * 8)}).clicked { submit = true }
		ui.space(ui.CARD_PAD)
	}
	ui.space(ui.CARD_PAD)
	switch {
	case submit && strings.trim_space(ui.line_edit_string(&d.field)) != "": ui.view_end(v, 0)
	case cancel: ui.view_end(v, ui.VIEW_CANCELLED)
	}
}

// The account to sign in with, when the key holds several passkeys of the site (webauthn/pin.odin's choose question):
// one row per account, a click or Enter chooses (the answer is its index), Up and Down move, Cancel refuses (the page
// gets NotAllowedError).
key_choose_view :: proc(v: ^ui.View, app: ^App) {
	d := &app.key_pin
	q := webauthn.choose_question()
	defer webauthn.choose_question_destroy(&q)
	if q.number == 0 { return }   // (over: webauthn_pin_build closes it)
	n := len(q.accounts)
	d.choose_sel = clamp(d.choose_sel, 0, max(n - 1, 0))
	em := ui.font_size()
	cancel := false
	chosen := -1
	if ui.key_press(.Down) { d.choose_sel = min(d.choose_sel + 1, n - 1) }
	if ui.key_press(.Up) { d.choose_sel = max(d.choose_sel - 1, 0) }
	if ui.key_press(.Return) { chosen = d.choose_sel }
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###kc_scroll") {
		if ui.dialog_body("kc_body") {
			if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("Your security key holds several passkeys of %s. Choose the one to sign in with."), q.rp_id), "###kc_hint"}, ui.frame_allocator())) }
			ui.space(ui.LINE_GAP)
			for a, i in q.accounts {
				title, detail := a.display_name, a.name
				if title == "" { title, detail = a.name, "" }
				if title == "" { title = i18n.tr("Account without a name") }
				if ui.choice_row(fmt.tprintf("kc_row_%d", i), i, &d.choose_sel, title, detail, lucide.USER, app.lucide) { chosen = i }
			}
		}
	}
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Center, {}, "###kc_buttons") {
		ui.spacer(ui.fill())
		if ui.button("###kc_cancel", i18n.tr("Cancel"), lucide.X, {width = ui.px(em * 8)}).clicked { cancel = true }
		ui.space(ui.CARD_PAD)
	}
	ui.space(ui.CARD_PAD)
	switch {
	case chosen >= 0 && chosen < n: ui.view_end(v, chosen)
	case cancel: ui.view_end(v, ui.VIEW_CANCELLED)
	}
}

// While the key waits for the person's touch (after its PIN, or at once): what to do, and a Cancel that stops the
// ceremony.
key_touch_view :: proc(v: ^ui.View, app: ^App) {
	q := webauthn.touch_question()
	defer webauthn.touch_question_destroy(&q)
	if q.number == 0 { return }   // (over: webauthn_pin_build closes it)
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###kt_scroll") {
		if ui.dialog_body("kt_body") {
			// (the spinner says that the key waits; the title is the header's)
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Center, {}, "###kt_head") {
				ui.spinner("###vd_spinner", em * 1.3)
				ui.space(ui.ICON_GAP)
				if ui.tags("weak") { ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s asks for your security key. Touch its button or its gold disc now: it blinks while it waits."), q.rp_id), "###kt_hint"}, ui.frame_allocator())) }
			}
		}
	}
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Center, {}, "###kt_buttons") {
		ui.spacer(ui.fill())
		if ui.button("###kt_cancel", i18n.tr("Cancel"), lucide.X, {width = ui.px(em * 8)}).clicked { ui.view_end(v, ui.VIEW_CANCELLED) }
		ui.space(ui.CARD_PAD)
	}
	ui.space(ui.CARD_PAD)
}
