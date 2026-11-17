package browser

// The QR code of the page's address (command page.qr_code: the main menu, the page's menu, the palette): a small dialog
// over the page with gui_toolkit's ui.qr_code, the address under it, a button that copies it. A phone's camera opens
// the page from it.

import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import i18n "toolkit:i18n"

QR_SIDE_EM :: 16   // the code's side

// Shows the dialog for `url` (copied).
qr_open :: proc(app: ^App, url: string) {
	delete(app.qr_url)
	app.qr_url = strings.clone(url)
	request_frames(app, 2)
}

// Each frame of each window: the dialog closed forgets its address; it is open while there is one (a new address
// opens it again).
qr_build :: proc(app: ^App) {
	if _, _, ok := window_view_ended(app, &app.qr_view, QR_VIEW); ok {
		delete(app.qr_url)
		app.qr_url = ""
		request_frames(app, 2)
	}
	key: u64 = app.qr_url != "" ? u64(uintptr(raw_data(app.qr_url))) : 0
	window_view_follow(app, &app.qr_view, QR_VIEW, app, key)
}

// The code, its address and its buttons (views.odin).
qr_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	// everything centred across the dialog: the code, its words, its buttons
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.column(.Center, {}, "###page_qr_col") {
		ui.spacer(ui.px(em * 0.8))
		ui.qr_code("###page_qr_code", app.qr_url, em * QR_SIDE_EM)
		ui.space(ui.LINE_GAP)
		ui.push_tags("weak")
		ui.label(app.qr_url)
		ui.pop_tags()
		ui.space(ui.ITEM_GAP)
		ui.next({width = ui.children_sum(), height = ui.children_sum()})
		if ui.row(.Center, {}, "###page_qr_buttons") {
			if ui.button("qr_copy", i18n.tr("Copy the address"), lucide.COPY, {intent = .Primary, width = ui.px(em * 10)}).clicked { clip_set(app.qr_url); announce(app, .Info, "Address copied") }
			ui.space(ui.CONTROL_GAP)
			if ui.button("qr_close", i18n.tr("Close"), lucide.X, {width = ui.px(em * 6)}).clicked { ui.view_end(v, 0) }
		}
		ui.spacer(ui.px(em * 0.8))
	}
}
