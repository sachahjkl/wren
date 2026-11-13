package browser

// System notifications in the shell (page/notification.odin keeps the page's side; gui_toolkit's platform.notify shows
// them):
//
//   * the permission is the origin's, asked by a small dialog over the page ("Allow" or "Block") and kept in the profile
//     (notifications.txt: one line per origin, "origin TAB granted" or "denied"); browser.notifications.enabled off
//     denies every origin and asks nothing;
//   * a Wren with no window (--headless: a test's, a tool's) shows none: nothing appears on the user's desktop;
//   * a notification is shown by the window of the page's tab (its events come back to that window): the page's
//     origin is its first line under the title. One with the tag of one shown before by the same origin replaces it;
//   * a click on it brings the window and the tab up, and tells the page; its end tells the page too;
//   * a download that ends while no window of Wren is the active one is told the same way (notification_download): a
//     click shows the file in its folder.
//
// For tests (wren ctl, no person to answer): browser.dialogs.test_answer answers the prompt: "cancel" blocks, any other
// non-empty value allows.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "toolkit:platform"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:i18n"
import "wb:page"

NOTIFICATION_PREFS := [?]config.Def{
	{name = "browser.notifications.enabled", kind = .Bool, default = {b = true},
		description = "Pages may ask to show system notifications (the Notifications API): a site asks once, after a click or a key press of yours, and the answer is kept for it. Off: every site is refused and nothing is asked."},
}

register_notification_prefs :: proc(p: ^config.Prefs) { config.register(p, NOTIFICATION_PREFS[:]) }

NOTIFICATIONS_FILE :: "notifications.txt"
@(private = "file") NOTIFICATIONS_HEADER :: "wren-notifications 1"

// A notification shown: which window showed it (its events come back there) and its id there.
@(private = "file")
Shown_Note :: struct {
	window: int,
	id:     platform.Notification_Id,
	key:    string,   // origin TAB tag ("" when it has no tag), owned
	download: u64,    // a download's end (notification_download): its id; 0: a page's
}

Notification_Shell :: struct {
	decided: map[string]bool,      // owned origins: granted (true) or denied (false)
	asks:    [dynamic]^page.Notification_Ask,
	shown:   map[u64]Shown_Note,   // by the page's id of it (window id << 32 | the toolkit's id)
}

notification_shell_init :: proc(app: ^App) {
	app.pages.notification_embedder = {user = app, permission = note_permission, ask = note_ask, show = note_show, close = note_close}
	notifications_load(app)
}

notification_shell_destroy :: proc(app: ^App) {
	s := &app.notes
	app.pages.notification_embedder = {}
	for r in s.asks { page.notification_ask_done(r, false) }
	delete(s.asks)
	for k in s.decided { delete(k) }
	delete(s.decided)
	for _, n in s.shown { delete(n.key) }
	delete(s.shown)
	s^ = {}
}

@(private = "file")
note_permission :: proc(user: rawptr, origin: string) -> i32 {
	app := (^App)(user)
	if !config.bool_of(&app.prefs, "browser.notifications.enabled") || !platform.notify_supported() { return 2 }
	granted, known := app.notes.decided[origin]
	if !known { return 0 }
	return granted ? 1 : 2
}

@(private = "file")
note_ask :: proc(user: rawptr, p: ^page.Page, req: ^page.Notification_Ask) {
	app := (^App)(user)
	switch config.string_of(&app.prefs, "browser.dialogs.test_answer") {
	case "": append(&app.notes.asks, req)
	case "cancel": note_decide(app, req, false)
	case: note_decide(app, req, true)
	}
	request_frames(app, 2)
}

// Keeps the answer for the origin and tells the page.
@(private = "file")
note_decide :: proc(app: ^App, req: ^page.Notification_Ask, granted: bool) {
	if _, known := app.notes.decided[req.origin]; !known { app.notes.decided[strings.clone(req.origin)] = granted } else { app.notes.decided[req.origin] = granted }
	notifications_save(app)
	page.notification_ask_done(req, granted)
}

@(private = "file")
note_show :: proc(user: rawptr, p: ^page.Page, title, body, tag: string, silent: bool) -> u64 {
	app := (^App)(user)
	if app.headless { return 0 }   // (a Wren with no window, a test's or a tool's: nothing on the user's desktop; the page sees "error")
	t := tab_of_page(app, p)
	if t == nil { return 0 }
	w, _ := window_of_tab(app, t)
	if w == nil || w.win == nil { return 0 }
	origin := page.page_origin(p)
	key := strings.concatenate({origin, "\t", tag})
	replace: platform.Notification_Id
	if tag != "" {
		for k, n in app.notes.shown {
			if n.key == key && n.window == w.id { replace = n.id; delete(n.key); delete_key(&app.notes.shown, k); break }
		}
	}
	text := body == "" ? origin : fmt.tprintf("%s\n%s", origin, body)
	id, ok := platform.notify(w.win, {title = title, body = text, silent = silent, replace = replace})
	if !ok || id == 0 { delete(key); return 0 }
	handle := u64(w.id) << 32 | u64(id)
	app.notes.shown[handle] = {window = w.id, id = id, key = key}
	return handle
}

@(private = "file")
note_close :: proc(user: rawptr, handle: u64) {
	app := (^App)(user)
	n, ok := app.notes.shown[handle]
	if !ok { return }
	if w := window_by_id(app, n.window); w != nil && w.win != nil { platform.notify_close(w.win, n.id) }
}

// The window's events of its notifications (the frame's poll): a click brings the page up, the end is told.
notification_events :: proc(app: ^App, events: []platform.Event) {
	wnd := active_window(app)
	for e in events {
		#partial switch e.kind {
		case .Notification_Click, .Notification_Action, .Notification_Closed:
			handle := u64(wnd.id) << 32 | u64(e.notification.id)
			n, ok := app.notes.shown[handle]
			if !ok { continue }
			if e.kind == .Notification_Closed {
				delete(n.key)
				delete_key(&app.notes.shown, handle)
				if n.download == 0 { page.notification_event(handle, page.NOTIFICATION_GONE) }
				continue
			}
			if n.download != 0 {
				for d in app.dls.list { if d.id == n.download { download_reveal(d) } }
				continue
			}
			note_bring_up(app, page.notification_page(handle))
			page.notification_event(handle, page.NOTIFICATION_CLICK)
		}
	}
}

// A download saved while no window of Wren is the one the user is in (the toast says it otherwise): a notification of
// the front window, whose click shows the file in its folder.
notification_download :: proc(app: ^App, d: ^Download) {
	if app.headless { return }   // (nothing on the user's desktop for a Wren with no window)
	for w in app.windows { if w.win != nil && w.win.active { return } }
	w := window_front(app)
	if w == nil || w.win == nil || !platform.notify_supported() { return }
	id, ok := platform.notify(w.win, {title = i18n.tr("Download complete"), body = filepath.base(d.path)})
	if !ok || id == 0 { return }
	app.notes.shown[u64(w.id) << 32 | u64(id)] = {window = w.id, id = id, download = d.id}
}

// The tab of page `id` becomes the current one of its window, which comes up with the keyboard.
@(private = "file")
note_bring_up :: proc(app: ^App, id: u64) {
	p := page.page_by_id(id)
	if p == nil { return }
	t := tab_of_page(app, p)
	if t == nil { return }
	w, i := window_of_tab(app, t)
	if w == nil { return }
	w.current = i
	window_focus(app, w, raise = true)
	request_frames(app, 2)
}

// The prompt over the page (the first request waiting), each frame while one waits.
notification_shell_build :: proc(app: ^App) {
	if len(app.notes.asks) == 0 { return }
	req := app.notes.asks[0]
	em := ui.font_size()
	open := true
	answered, granted := false, false
	if ui.modal("note_permission", em * 30, &open) {
		if ui.dialog_header("note_header", i18n.tr("Notifications"), {icon = lucide.BELL, icon_font = app.lucide}) {}
		if ui.dialog_body("note_body") {
			ui.paragraph(strings.concatenate({fmt.tprintf(i18n.tr("%s wants to show notifications"), req.origin), "###note_what"}, ui.frame_allocator()))
		}
		if ui.dialog_buttons("note_buttons") {
			if ui.button_icon("###note_block", lucide.SHIELD, i18n.tr("Block"), intent = .Danger, width = ui.px(em * 8)).clicked { answered, granted = true, false }
			ui.spacer(ui.px(em * 0.6))
			if ui.button_icon("###note_allow", lucide.CHECK, i18n.tr("Allow"), intent = .Success, width = ui.px(em * 8)).clicked { answered, granted = true, true }
		}
	}
	if !open { answered, granted = true, false }   // Escape, a click outside: blocked
	if answered {
		ordered_remove(&app.notes.asks, 0)
		note_decide(app, req, granted)
		request_frames(app, 2)
	}
}

////////////////////////////////
// The profile's file

@(private = "file")
notifications_path :: proc(app: ^App) -> string {
	if app.profile_dir == "" { return "" }
	return strings.concatenate({app.profile_dir, "/", NOTIFICATIONS_FILE}, context.temp_allocator)
}

@(private = "file")
notifications_load :: proc(app: ^App) {
	path := notifications_path(app)
	if path == "" { return }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) == 0 || strings.trim_space(lines[0]) != NOTIFICATIONS_HEADER { return }
	for line in lines[1:] {
		origin, _, state := strings.partition(line, "\t")
		if origin == "" || (state != "granted" && state != "denied") { continue }
		if _, known := app.notes.decided[origin]; known { continue }
		app.notes.decided[strings.clone(origin)] = state == "granted"
	}
}

@(private = "file")
notifications_save :: proc(app: ^App) {
	path := notifications_path(app)
	if path == "" || !app.cfg.persist_profile { return }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, NOTIFICATIONS_HEADER)
	strings.write_byte(&b, '\n')
	for origin, granted in app.notes.decided { fmt.sbprintf(&b, "%s\t%s\n", origin, granted ? "granted" : "denied") }
	host.profile_write(&app.writer, path, strings.to_string(b))
}
