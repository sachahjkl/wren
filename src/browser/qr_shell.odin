package browser

// The QR code of the page's address (command page.qr_code: the main menu, the page's menu, the palette): a small dialog
// over the page with gui_toolkit's ui.qr_code, the address under it, a button that copies it. A phone's camera opens
// the page from it.

import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:i18n"

QR_SIDE_EM :: 16   // the code's side

// Shows the dialog for `url` (copied).
qr_open :: proc(app: ^App, url: string) {
	delete(app.qr_url)
	app.qr_url = strings.clone(url)
	request_frames(app, 2)
}

// The dialog, each frame while it is open.
qr_build :: proc(app: ^App) {
	if app.qr_url == "" { return }
	em := ui.font_size()
	open := true
	close := false
	if ui.modal("page_qr", &open, {width_em = QR_SIDE_EM + 6}) {
		if ui.dialog_header("page_qr_header", i18n.tr("Scan to open this page"), {icon = lucide.QR_CODE, icon_font = app.lucide}) {}
		// everything centred across the dialog: the code, its words, its buttons
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.column(.Center, {}, "###page_qr_col") {
			ui.spacer(ui.px(em * 0.8))
			ui.qr_code("###page_qr_code", app.qr_url, em * QR_SIDE_EM)
			ui.spacer(ui.px(em * 0.6))
			ui.push_tags("weak")
			ui.label(app.qr_url)
			ui.pop_tags()
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.children_sum(), height = ui.children_sum()})
			if ui.row(.Center, {}, "###page_qr_buttons") {
				if ui.button("qr_copy", i18n.tr("Copy the address"), lucide.COPY, {intent = .Primary, width = ui.px(em * 10)}).clicked { clip_set(app.qr_url); announce(app, .Info, "Address copied") }
				ui.spacer(ui.px(em * 0.6))
				if ui.button("qr_close", i18n.tr("Close"), lucide.X, {width = ui.px(em * 6)}).clicked { close = true }
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
	if !open || close {
		delete(app.qr_url)
		app.qr_url = ""
		request_frames(app, 2)
	}
}
