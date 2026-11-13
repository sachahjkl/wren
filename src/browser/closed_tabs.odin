package browser

// What was closed, most recent last: a tab, a window, or the session of the run before when this start did not reopen it.
// Ctrl+Shift+T takes them back one at a time, each with what it had: a tab its whole history tree, its place in the strip, its
// group and where it was left, a window its tabs and its rectangle, a session all its windows.
//
// Every item is the text of a session file (session.odin), so an item opens the way a restored session does. The list lives in
// closed.txt in the profile, a line `item <kind> <closed ms> <index> <tabs> <address> <title>` before the session text of each:
//
//     wren-closed 1
//     item	0	1793000000000	2	1	https://example.com/	Example
//     wren-session 2
//     current 0
//     tab https://example.com/
//     e	...
//
// It is read at its first use, not at start-up, and session.txt with it: the session of the run before goes on the list then
// (closed_load), before the first autosave replaces that file. Reading is forgiving as for a session file; an item whose session
// cannot be read opens its address.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:host"
import "wb:i18n"

CLOSED_HEADER :: "wren-closed 1"
@(private = "file") CLOSED_ITEM_TAG :: "item\t"
@(private = "file") CLOSED_ITEM_FIELDS :: 7

CLOSED_PREFS := [?]config.Def{
	{name = "browser.tabs.closed_sessions_max", kind = .Int, default = {i = 3}, bounded = true, min = 0, max = 100,
		description = "Earlier sessions kept among what Ctrl+Shift+T can reopen (they count in browser.tabs.closed_max)."},
}

register_closed_prefs :: proc(p: ^config.Prefs) { config.register(p, CLOSED_PREFS[:]) }

Closed_Kind :: enum u8 { Tab, Window, Session }

Closed_Item :: struct {
	kind:    Closed_Kind,
	at_ms:   i64,      // when it was closed
	index:   int,      // a tab: its place in the strip
	tabs:    int,      // how many it opens
	address: string,   // owned: of the tab, or of the front one
	title:   string,   // owned: the same
	text:    string,   // owned: a session file
}

Closed_Tabs :: struct {
	items:         [dynamic]Closed_Item,
	loaded:        bool,
	dirty:         bool,   // closed.txt is behind the list
	session_waits: bool,   // this start did not reopen session.txt: it is the session of the run before
	file:          host.Profile_File,   // closed.txt (profile_writes.odin)
}

closed_path :: proc(app: ^App) -> string { return strings.concatenate({app.profile_dir, "/closed.txt"}, context.temp_allocator) }

@(private = "file")
closed_item_destroy :: proc(item: Closed_Item) {
	delete(item.address)
	delete(item.title)
	delete(item.text)
}

// (pure: closed_tabs_test.odin)
closed_serialize :: proc(items: []Closed_Item, max_url_bytes: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, CLOSED_HEADER)
	strings.write_byte(&sb, '\n')
	for it in items {
		if len(it.address) > max_url_bytes { continue }
		fmt.sbprintf(&sb, "%s%d\t%d\t%d\t%d\t", CLOSED_ITEM_TAG, int(it.kind), it.at_ms, it.index, it.tabs)
		base.field_escape(&sb, it.address)
		strings.write_byte(&sb, '\t')
		base.field_escape(&sb, it.title)
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, it.text)
		if !strings.has_suffix(it.text, "\n") { strings.write_byte(&sb, '\n') }
	}
	return strings.to_string(sb)
}

// The items of a closed.txt (strings owned, the most recent last); a file that is not one has none, a damaged item is left out.
closed_parse :: proc(text: string) -> [dynamic]Closed_Item {
	items: [dynamic]Closed_Item
	rest := text
	head, ok := strings.split_lines_iterator(&rest)
	if !ok || strings.trim_right(head, "\r") != CLOSED_HEADER { return items }
	for strings.has_prefix(rest, CLOSED_ITEM_TAG) {
		next := strings.index(rest, "\n" + CLOSED_ITEM_TAG)
		chunk := next < 0 ? rest : rest[:next + 1]
		rest = next < 0 ? "" : rest[next + 1:]
		end := strings.index_byte(chunk, '\n')
		if end < 0 { continue }
		f := strings.split(strings.trim_right(chunk[:end], "\r"), "\t", context.temp_allocator)
		if len(f) != CLOSED_ITEM_FIELDS { continue }
		kind, k_ok := strconv.parse_int(f[1])
		at_ms, a_ok := strconv.parse_i64(f[2])
		index, i_ok := strconv.parse_int(f[3])
		tabs, t_ok := strconv.parse_int(f[4])
		if !k_ok || !a_ok || !i_ok || !t_ok || kind < 0 || kind > int(max(Closed_Kind)) { continue }
		append(&items, Closed_Item{kind = Closed_Kind(kind), at_ms = at_ms, index = index, tabs = tabs, address = base.field_unescape(f[5]),
			title = base.field_unescape(f[6]), text = strings.clone(chunk[end + 1:])})
	}
	return items
}

// No more than the most recent `max_items`, of which `max_sessions` sessions.
closed_cap :: proc(items: ^[dynamic]Closed_Item, max_items, max_sessions: int) {
	// the sessions older than the newest `max_sessions` go: counted from the end, the kept ones moved down in one pass
	sessions := 0
	for it in items { if it.kind == .Session { sessions += 1 } }
	drop := max(sessions - max(max_sessions, 0), 0)
	if drop > 0 {
		k := 0
		for it in items {
			if it.kind == .Session && drop > 0 { closed_item_destroy(it); drop -= 1; continue }
			items[k] = it
			k += 1
		}
		resize(items, k)
	}
	if n := len(items) - max(max_items, 0); n > 0 {
		for it in items[:n] { closed_item_destroy(it) }
		remove_range(items, 0, n)
	}
}

@(private = "file")
closed_append :: proc(app: ^App, item: Closed_Item) {
	c := &app.closed
	append(&c.items, item)
	closed_cap(&c.items, app.ix.closed_tabs_max, int(config.int_of(&app.prefs, "browser.tabs.closed_sessions_max")))
	c.dirty = true
}

// The session of the run before goes on the list, without the tabs this start already reopened (browser.tabs.restore_pinned).
@(private = "file")
closed_take_session :: proc(app: ^App) {
	data, err := os.read_entire_file(session_path(app), context.temp_allocator)
	if err != nil { return }
	windows, ok := session_windows_of(app, string(data))
	if !ok { return }
	windows = session_kept(windows, drop_pinned = config.bool_of(&app.prefs, "browser.tabs.restore_pinned"))
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
	closed_append(app, {kind = .Session, at_ms = now_ms(), tabs = tabs, address = strings.clone(front.url), title = strings.clone(session_tab_title(front)), text = strings.clone(text)})
}

// closed.txt, and the session of the run before: at the first use of the list. (A profile's files are read before they are replaced.)
closed_load :: proc(app: ^App) {
	c := &app.closed
	if c.loaded { return }
	c.loaded = true
	if !app.cfg.persist_profile || app.ix.closed_tabs_max <= 0 { return }
	if data, err := os.read_entire_file(closed_path(app), context.temp_allocator); err == nil {
		c.items = closed_parse(string(data))
		closed_cap(&c.items, app.ix.closed_tabs_max, int(config.int_of(&app.prefs, "browser.tabs.closed_sessions_max")))
	}
	if c.session_waits { closed_take_session(app) }
	c.session_waits = false
}

// The list as it is (the most recent last).
closed_items :: proc(app: ^App) -> []Closed_Item {
	closed_load(app)
	return app.closed.items[:]
}

// Writes closed.txt when it changed (session_save), on the blocking pool (profile_writes.odin: a failed write is made again).
closed_save :: proc(app: ^App) {
	c := &app.closed
	if !c.dirty { return }
	host.profile_file_init(&c.file, &app.writer, closed_path(app))
	host.profile_file_write(&c.file, closed_serialize(c.items[:], int(config.int_of(&app.prefs, "browser.session.max_url_bytes"))))
	c.dirty = false
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
	closed_append(app, {kind = .Tab, at_ms = now_ms(), index = index, tabs = 1, address = strings.clone(st.url), title = strings.clone(t.title), text = strings.clone(text)})
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
	closed_append(app, {kind = .Window, at_ms = now_ms(), tabs = len(sw.tabs), address = strings.clone(front.url), title = strings.clone(session_tab_title(front)), text = strings.clone(text)})
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
	c := &app.closed
	closed_load(app)
	for len(c.items) > 0 {
		item := pop(&c.items)
		defer closed_item_destroy(item)
		c.dirty = true
		if closed_item_open(app, item) { break }
	}
}

// The one the palette chose, the most recent of that address.
reopen_closed_address :: proc(app: ^App, address: string) {
	if app.rest_text != "" { return }
	c := &app.closed
	closed_load(app)
	for i := len(c.items) - 1; i >= 0; i -= 1 {
		if c.items[i].address != address { continue }
		item := c.items[i]
		ordered_remove(&c.items, i)
		defer closed_item_destroy(item)
		c.dirty = true
		closed_item_open(app, item)
		return
	}
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
	c := &app.closed
	closed_load(app)
	for i := len(c.items) - 1; i >= 0; i -= 1 {
		if c.items[i].at_ms < from_ms || c.items[i].at_ms > to_ms { continue }
		closed_item_destroy(c.items[i])
		ordered_remove(&c.items, i)
		c.dirty = true
	}
}

// The list emptied, and closed.txt at the next save (a reset of the browser's state).
closed_tabs_clear :: proc(app: ^App) {
	c := &app.closed
	for item in c.items { closed_item_destroy(item) }
	clear(&c.items)
	c.loaded, c.dirty, c.session_waits = true, true, false
}

closed_tabs_destroy :: proc(app: ^App) {
	c := &app.closed
	for item in c.items { closed_item_destroy(item) }
	delete(c.items)
	host.profile_file_destroy(&c.file)   // (written by profile_files_flush, before the loop ended)
	c^ = {}
}
