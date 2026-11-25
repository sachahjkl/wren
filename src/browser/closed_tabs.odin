package browser

// Browser bridge for the closed tabs/windows/sessions store (src/profile/closed_tabs.odin):
// captures and restores tabs, windows, and previous sessions using session.odin.

import "core:fmt"
import "core:os"
import "core:strings"
import i18n "toolkit:i18n"
import "wb:profile"

CLOSED_HEADER :: profile.CLOSED_HEADER

register_closed_prefs :: profile.register_closed_prefs

Closed_Kind :: profile.Closed_Kind
Closed_Item :: profile.Closed_Item
Closed_Tabs :: profile.Closed_Tabs

closed_serialize :: profile.closed_serialize
closed_parse :: profile.closed_parse
closed_cap :: profile.closed_cap

closed_path :: proc(app: ^App) -> string { return profile.closed_path(app.profile_dir) }

// The session of the run before goes on the list, without the tabs this start already reopened (browser.tabs.restore_pinned).
@(private = "file")
closed_take_session :: proc(app: ^App) {
	data, err := os.read_entire_file(session_path(app), context.temp_allocator)
	if err != nil { return }
	windows, ok := session_windows_of(app, string(data))
	if !ok { return }
	windows = session_kept(windows, drop_pinned = app.session_cfg.restore_pinned)
	tabs, worth := 0, false
	for w in windows {
		tabs += len(w.tabs)
		for st in w.tabs { worth ||= !session_tab_blank(st) }
	}
	if !worth { return }
	text := session_text_of(app, windows, rects = true)
	c := &app.closed
	if n := len(c.items); n > 0 && c.items[n - 1].text == text { return }   // (it went on the list in a run that ended before writing session.txt)
	front := windows[0].tabs[windows[0].current]
	profile.closed_append(c, {kind = .Session, at_ms = now_ms(), tabs = tabs, address = strings.clone(front.url), title = strings.clone(session_tab_title(front)), text = strings.clone(text)},
		app.ix.closed_tabs_max, app.session_cfg.closed_sessions_max)
}

// closed.txt, and the session of the run before: at the first use of the list. (A profile's files are read before they are replaced.)
closed_load :: proc(app: ^App) {
	if profile.closed_load_file(&app.closed, profile_store_host(app), app.ix.closed_tabs_max, app.session_cfg.closed_sessions_max) {
		closed_take_session(app)
	}
}

// The list as it is (the most recent last).
closed_items :: proc(app: ^App) -> []Closed_Item {
	closed_load(app)
	return app.closed.items[:]
}

// Writes closed.txt when it changed (session_save), on the blocking pool.
closed_save :: proc(app: ^App) {
	profile.closed_save(&app.closed, profile_store_host(app), app.session_cfg.max_url_bytes)
}

// A tab closing (tab_close_in), before it leaves `w`'s strip: a tab that shows nothing is not worth reopening.
closed_tab_push :: proc(app: ^App, w: ^Browser_Window, t: ^Tab, index: int) {
	if app.ix.closed_tabs_max <= 0 { return }
	closed_load(app)
	entry_capture_current(app, t)
	st := session_tab_of(t)
	if session_tab_blank(st) { return }
	groups: []Session_Group
	if gi := group_index(w.groups[:], t.group); gi >= 0 { groups = session_groups_of(w.groups[gi:gi + 1]) }
	text := session_text_of(app, {{tabs = {st}, groups = groups}})
	profile.closed_append(&app.closed, {kind = .Tab, at_ms = now_ms(), index = index, tabs = 1, address = strings.clone(st.url), title = strings.clone(t.title), text = strings.clone(text)},
		app.ix.closed_tabs_max, app.session_cfg.closed_sessions_max)
}

// A window closing (window_close), with its tabs still in it: they come back together.
closed_window_push :: proc(app: ^App, w: ^Browser_Window) {
	if app.ix.closed_tabs_max <= 0 { return }
	closed_load(app)
	sw := session_window_of(app, w)
	worth := false
	for st in sw.tabs { worth ||= !session_tab_blank(st) }
	if !worth { return }
	front := sw.tabs[sw.current]
	text := session_text_of(app, {sw}, rects = true)
	profile.closed_append(&app.closed, {kind = .Window, at_ms = now_ms(), tabs = len(sw.tabs), address = strings.clone(front.url), title = strings.clone(session_tab_title(front)), text = strings.clone(text)},
		app.ix.closed_tabs_max, app.session_cfg.closed_sessions_max)
}

// Opens an item. false: nothing of it could be read.
@(private = "file")
closed_item_open :: proc(app: ^App, item: Closed_Item) -> bool {
	windows, ok := session_windows_of(app, item.text)
	if ok { windows = session_kept(windows) }
	if !ok || len(windows) == 0 {
		if item.address == "" { return false }
		open_in_new_tab(app, item.address, origin = .Replay)
		return true
	}
	first := windows[0]
	switch item.kind {
	case .Tab:
		session_open_tabs(app, first.tabs, first.current, first.groups, join_groups = true, at = item.index)
	case .Window:
		session_open_later(app, item.text, from = 0)
	case .Session:
		// its first window comes here, in the place of the start page a new run shows; the others in windows of their own
		wnd := active_window(app)
		lone := len(wnd.tabs) == 1 && session_tab_blank(session_tab_of(wnd.tabs[0])) ? wnd.tabs[0] : nil
		session_open_tabs(app, first.tabs, first.current, first.groups)
		for t, i in wnd.tabs { if t == lone { tab_close(app, i); break } }
		if len(windows) > 1 { session_open_later(app, item.text, from = 1) }
	}
	return true
}

// Ctrl+Shift+T: the last thing closed comes back.
reopen_closed_tab :: proc(app: ^App) {
	if app.rest_text != "" { return }   // (windows are still to open: session_open_other_windows)
	closed_load(app)
	for {
		item, ok := profile.closed_pop(&app.closed)
		if !ok { break }
		defer profile.closed_item_destroy(item)
		if closed_item_open(app, item) { break }
	}
}

// The one the palette chose, the most recent of that address.
reopen_closed_address :: proc(app: ^App, address: string) {
	if app.rest_text != "" { return }
	closed_load(app)
	item, ok := profile.closed_take_address(&app.closed, address)
	if !ok { return }
	defer profile.closed_item_destroy(item)
	closed_item_open(app, item)
}

// What the palette calls it (temporary allocator).
closed_item_label :: proc(item: Closed_Item) -> string {
	title := item.title != "" ? item.title : default_tab_title(item.address, context.temp_allocator)
	switch item.kind {
	case .Tab:     return title
	case .Window:  return fmt.tprintf("Window: %s (%d tabs)", title, item.tabs)
	case .Session: return fmt.tprintf("Previous session (%d tabs)", item.tabs)
	}
	return title
}

// What the menus call the command: what it would bring back.
closed_reopen_title :: proc(app: ^App) -> string {
	items := closed_items(app)
	if len(items) > 0 {
		switch items[len(items) - 1].kind {
		case .Tab:
		case .Window:  return i18n.tr("Reopen closed window")
		case .Session: return i18n.tr("Restore previous session")
		}
	}
	return i18n.tr("Reopen closed tab")
}

// What was closed between two times goes with the history of those times (global_history_remove_range).
closed_forget_range :: proc(app: ^App, from_ms, to_ms: i64) {
	closed_load(app)
	profile.closed_forget_range(&app.closed, from_ms, to_ms)
}

// The list emptied, and closed.txt at the next save (a reset of the browser's state).
closed_tabs_clear :: proc(app: ^App) {
	profile.closed_tabs_clear(&app.closed)
}

closed_tabs_destroy :: proc(app: ^App) {
	profile.closed_tabs_destroy(&app.closed)
}
