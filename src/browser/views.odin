package browser

// Wren's dialogs are gui_toolkit views (docs/views.md of the toolkit): each is registered once here, with its title, its
// icon and its sizes, and built by the toolkit at the end of its window's build, over the page. The program has one
// ui.Views (App.views), shared by every browser window's State (set_views): what the person chose for a view (its size,
// where it shows) is remembered in the profile (views.txt), not in a private one.
//
// A view that belongs to one browser window (a page's request, a key's question, the Vault's dialogs) has the window's
// id as its instance: it opens in the build of the window the person is in, and its answer is read in that window's
// build. Window_View keeps where it is open and what for (window_view_follow, window_view_ended).
//
// A view can go in a window of the system's own: Wren's backend of windows (views_external.odin) is the Views' one
// (ui.views_set_windows). The developer tools are a view too: a panel at the bottom of their viewport at
// first, an instance per browser window (devtools.odin).

import "core:fmt"
import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import i18n "toolkit:i18n"

VIEWS_FILE :: "views.txt"

// The ids of Wren's views.
FS_VIEW              :: "fs_permission"
NOTIFICATION_VIEW    :: "note_permission"
STORAGE_ACCESS_VIEW  :: "storage_access"
PASSKEY_CHOICE_VIEW  :: "passkey_choice"
KEY_PIN_VIEW         :: "key_pin"
KEY_CHOOSE_VIEW      :: "key_choose"
KEY_TOUCH_VIEW       :: "key_touch"
VAULT_DIALOG_VIEW    :: "vault_dialog"
VAULT_PIN_VIEW       :: "vault_pin"
VAULT_GENERATOR_VIEW :: "vault_generator"
QR_VIEW              :: "page_qr"
BOOKMARK_EDIT_VIEW   :: "bookmark_edit"
// (confirmations: ui.confirm_open registers them itself)
CONFIRM_VIEW         :: "wren_confirm"
VAULT_LOGOUT_VIEW    :: "vault_logout"
VAULT_INSECURE_VIEW  :: "vault_insecure"
DEVTOOLS_VIEW        :: "devtools"

// The answer of a page's permission prompt (files, notifications, storage access).
Permission_Answer :: enum u8 { Block, Allow }

// The program's Views: its memory in the profile (none for a profile that is not kept: a private Wren's), every view
// registered. Before the first window's State uses it (app_ui_init).
views_start :: proc(app: ^App) {
	path := ""
	if app.cfg.persist_profile && !app.private && app.profile_dir != "" {
		path = strings.concatenate({app.profile_dir, "/", VIEWS_FILE}, context.temp_allocator)
	}
	ui.views_init(&app.views, {path = path})
	ui.views_set_windows(&app.views, view_windows_backend(app))   // views_external.odin
	views_register(app)
}

// After the last build: which views were open is written, the memory flushed, the views' windows closed.
views_end :: proc(app: ^App) {
	ui.views_destroy(&app.views)
	delete(app.view_windows)
	app.view_windows = nil
}

// Every view of Wren, once.
views_register :: proc(app: ^App) {
	vs := &app.views
	f := app.lucide
	ui.view_register(vs, FS_VIEW, fs_view, {title = i18n.later("Files"), icon = lucide.FOLDER, icon_font = f, width_em = 30})
	ui.view_register(vs, NOTIFICATION_VIEW, notification_view, {title = i18n.later("Notifications"), icon = lucide.BELL, icon_font = f, width_em = 30})
	ui.view_register(vs, STORAGE_ACCESS_VIEW, storage_access_view, {title = i18n.later("Cookies and site data"), icon = lucide.COOKIE, icon_font = f, width_em = 32})
	ui.view_register(vs, PASSKEY_CHOICE_VIEW, passkey_choice_view, {title = i18n.later("Sign in with a passkey"), icon = lucide.KEY_ROUND, icon_font = f,
		width_em = 28, min_width_em = 20, min_height_em = 12, resizable = true})
	ui.view_register(vs, KEY_PIN_VIEW, key_pin_view, {title = i18n.later("Security key PIN"), icon = lucide.USB, icon_font = f,
		width_em = 26, min_width_em = 20, min_height_em = 11, resizable = true})
	ui.view_register(vs, KEY_CHOOSE_VIEW, key_choose_view, {title = i18n.later("Choose an account"), icon = lucide.USER, icon_font = f,
		width_em = 26, min_width_em = 20, min_height_em = 12, resizable = true})
	ui.view_register(vs, KEY_TOUCH_VIEW, key_touch_view, {title = i18n.later("Touch your security key"), icon = lucide.USB, icon_font = f,
		width_em = 26, min_width_em = 20, min_height_em = 8, resizable = true})
	// (its title and icon follow the Vault's state: view_title, view_icon in its build)
	ui.view_register(vs, VAULT_DIALOG_VIEW, vault_login_view, {title = i18n.later("Log in to the Vault"), icon = lucide.LOCK_KEYHOLE, icon_font = f,
		width_em = 32, min_width_em = 22, min_height_em = 12, resizable = true})
	ui.view_register(vs, VAULT_PIN_VIEW, vault_pin_view, {title = i18n.later("Set a PIN"), icon = lucide.KEYBOARD, icon_font = f,
		width_em = 26, min_width_em = 20, min_height_em = 10, resizable = true})
	ui.view_register(vs, VAULT_GENERATOR_VIEW, vault_generator_view, {title = i18n.later("Password generator"), icon = lucide.DICES, icon_font = f,
		width_em = 28, min_width_em = 22, min_height_em = 14, resizable = true})
	ui.view_register(vs, QR_VIEW, qr_view, {title = i18n.later("Scan to open this page"), icon = lucide.QR_CODE, icon_font = f, width_em = QR_SIDE_EM + 6})
	ui.view_register(vs, BOOKMARK_EDIT_VIEW, bookmark_edit_view, {title = i18n.later("Bookmark"), icon = lucide.BOOKMARK, icon_font = f, width_em = 28})
	// (its window's first size is the detached window's of old: 1100 by 760 at 15 px)
	ui.view_register(vs, DEVTOOLS_VIEW, devtools_view, {title = i18n.later("Developer tools"), icon = lucide.SQUARE_TERMINAL, icon_font = f,
		home = .Panel, home_place = {edge = .Bottom}, extent_em = DEVTOOLS_EXTENT_EM, width_em = 73, height_em = 50,
		min_width_em = 16, min_height_em = 6})
}

// A browser window's State builds the program's views.
views_attach :: proc(app: ^App, s: ^ui.State) {
	ui.set_views(s, &app.views)
	debug_panel_attach(app, s)   // debug_panel.odin: Wren's panel in the toolkit's debug window
}

////////////////////////////////
// A view of one browser window

// Where a view of one window is open, and what for. `key` names the thing it shows (a request, a question's number;
// 0: none): another key closes it and opens it again, so a view never shows one request with another's answer.
Window_View :: struct {
	window: int,   // the browser window it is open in (0: none)
	key:    u64,
}

// The instance of a view of window `id`.
window_view_instance :: proc(id: int) -> string { return fmt.tprintf("%d", id) }

// In each window's build, before the program acts on what the view shows: its answer, taken in the window it is open
// in, with the key it was open for. Once.
window_view_ended :: proc(app: ^App, wv: ^Window_View, id: string) -> (code: int, key: u64, ok: bool) {
	w := active_window(app)
	if wv.window == 0 || wv.window != w.id { return }
	code, ok = ui.view_ended(&app.views, id, window_view_instance(w.id))
	if ok {
		key = wv.key
		wv^ = {}
	}
	return
}

// The same for a confirmation (ui.confirm_open): .None until it is answered.
window_confirm_answer :: proc(app: ^App, wv: ^Window_View, id: string) -> ui.Confirm_Answer {
	w := active_window(app)
	if wv.window == 0 || wv.window != w.id { return .None }
	a := ui.confirm_answer(id, window_view_instance(w.id))
	if a != .None { wv^ = {} }
	return a
}

// In each window's build, after the program acted: the view is open for `key` (0: closed), with `data`.
window_view_follow :: proc(app: ^App, wv: ^Window_View, id: string, data: ^$T, key: u64) {
	if instance, now := window_view_due(app, wv, id, key); now { ui.view_open(&app.views, id, data, instance) }
}

// The same for a confirmation: `o` is given when it opens (its strings can be temporary).
window_confirm_follow :: proc(app: ^App, wv: ^Window_View, id: string, o: ui.Confirm_Options, key: u64) {
	if instance, now := window_view_due(app, wv, id, key); now { ui.confirm_open(id, o, instance) }
}

// What window_view_follow does but the opening: the view of another key, or of a window that went, is closed or
// forgotten; true when it is to open now, in the active window (the one the person is in), with this instance.
@(private = "file")
window_view_due :: proc(app: ^App, wv: ^Window_View, id: string, key: u64) -> (instance: string, now: bool) {
	vs := &app.views
	w := active_window(app)
	if wv.window != 0 {
		there := window_view_instance(wv.window)
		switch {
		case wv.window != w.id && window_by_id(app, wv.window) == nil:
			// (its window closed, and the view with it: it opens again in the window the person is in)
			wv^ = {}
		case wv.key != key:
			ui.view_close(vs, id, there)
			wv^ = {}
		case wv.window == w.id && !ui.view_is_open(vs, id, there):
			// (closed by the program elsewhere: opened again while it is wanted)
			wv^ = {}
		case:
			return
		}
	}
	if key == 0 || !window_is_front(app) || w.id == 0 { return }
	wv^ = {window = w.id, key = key}
	return window_view_instance(w.id), true
}
