package browser

// Session restore (browser.session.restore, off by default: a browser that reopens yesterday's pages is a choice the
// user makes, and runs that share a profile, such as tests, then start clean). Every tab is written to session.txt in
// the profile with the other profile files (autosave, and at exit): its address, and its whole history tree (each
// entry with its parent, address, title, icon, visit order and times, history.state, scroll restoration mode and the
// scroll position and zoom it was left with), and which tab is current. They are opened again at the next start when
// no address is given on the command line: the current tab loads its current entry (where it was left), the others
// when first shown, as in Chrome. Back, forward and the tab's tree work as before the restart.
//
// The file is plain text, versioned, written to a temporary file then moved over the old one (a crash in between leaves
// the old one). Fields are tab-separated and escaped (field_escape). Reading is forgiving: unknown lines are skipped, a
// line too long or a URL that does not parse is dropped, the tab count is capped, and a file without the header (or not
// a session file at all) restores nothing. Version 1 files (addresses only) are read too.
//
//     wren-session 2
//     current 1
//     tab https://example.com/b
//     e	<id>	<parent>	<seq>	<created ms>	<visited ms>	<flags>	<scroll x>	<scroll y>	<zoom>	<url>	<title>	<icon>	<state>
//     tab about:config
//
// flags: 1 history.scrollRestoration manual, 2 the tab's current entry, 4 has a state.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "wb:config"
import "wb:page"
import "wb:url"

SESSION_HEADER :: "wren-session 2"
SESSION_HEADER_V1 :: "wren-session 1"

SESSION_PREFS := [?]config.Def{
	{name = "browser.session.restore", kind = .Bool, default = {b = false},
		description = "At start-up, reopen the tabs that were open when the browser last closed (when no address is given on the command line), each with its history (back, forward, its history tree) and where it was left. Needs browser.profile.persist."},
	{name = "browser.session.max_tabs", kind = .Int, default = {i = 100}, bounded = true, min = 1, max = 10_000,
		description = "Most tabs a restored session reopens."},
	{name = "browser.session.max_url_bytes", kind = .Int, default = {i = 16 << 10}, bounded = true, min = 256, max = 2 << 20, bytes = true, unit = "bytes",
		description = "Longest address a session file may hold for a tab or an entry (longer ones, data: URLs for instance, are not saved)."},
	{name = "browser.session.max_state_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 0, max = 16 << 20, bytes = true, unit = "bytes",
		description = "Largest history.state of an entry the session file keeps (a larger one is restored as null)."},
}

register_session_prefs :: proc(p: ^config.Prefs) { config.register(p, SESSION_PREFS[:]) }

@(private = "file") session_last: string   // what was written last (nothing is written when it did not change)

session_path :: proc(app: ^App) -> string { return strings.concatenate({app.profile_dir, "/session.txt"}, context.temp_allocator) }

// One tab of a session file.
Session_Tab :: struct {
	url:     string,
	entries: []page.Saved_Entry,   // parents first
	current: u64,                  // id of the current entry (0: the last one)
}

@(private = "file")
writable :: proc(s: string, max_bytes: int) -> bool { return s != "" && len(s) <= max_bytes && !strings.contains_any(s, "\r\n\x00") }

// The text of a session (pure: session_test.odin). Tabs and entries whose address cannot be written are left out
// (an entry's children then hang from its parent); `current` follows the tab it pointed at.
session_serialize_tabs :: proc(tabs: []Session_Tab, current: int, max_url_bytes, max_state_bytes: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, SESSION_HEADER)
	strings.write_byte(&sb, '\n')
	kept := make([dynamic]int, context.temp_allocator)
	cur := 0
	for t, i in tabs {
		if !writable(t.url, max_url_bytes) { continue }
		if i == current { cur = len(kept) }
		append(&kept, i)
	}
	fmt.sbprintf(&sb, "current %d\n", cur)
	for i in kept {
		t := tabs[i]
		strings.write_string(&sb, "tab ")
		strings.write_string(&sb, t.url)
		strings.write_byte(&sb, '\n')
		dropped := make(map[u64]u64, 8, context.temp_allocator)   // id -> its parent, for entries not written
		for e in t.entries {
			parent := e.parent
			for parent != 0 { if p, gone := dropped[parent]; gone { parent = p } else { break } }
			if len(e.url) > max_url_bytes || e.url == "" { dropped[e.id] = parent; continue }
			flags := 0
			if e.scroll_manual { flags |= 1 }
			if e.id == t.current { flags |= 2 }
			state := e.has_state && len(e.state) <= max_state_bytes
			if state { flags |= 4 }
			fmt.sbprintf(&sb, "e\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%.1f\t%.3f\t", e.id, parent, e.seq, e.created_ms, e.visited_ms, flags, e.scroll.x, e.scroll.y, e.zoom)
			field_escape(&sb, e.url)
			strings.write_byte(&sb, '\t')
			field_escape(&sb, e.title)
			strings.write_byte(&sb, '\t')
			field_escape(&sb, e.icon)
			strings.write_byte(&sb, '\t')
			if state { field_escape(&sb, e.state) }
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

// The tabs of a session file (pure). `ok` false when it is not one.
session_parse_tabs :: proc(text: string, max_tabs, max_url_bytes: int, allocator := context.temp_allocator) -> (tabs: []Session_Tab, current: int, ok: bool) {
	out := make([dynamic]Session_Tab, allocator)
	entries := make([dynamic]page.Saved_Entry, allocator)
	rest := text
	first := true
	skipping := false   // the tab being read was dropped: its entries too
	flush :: proc(out: ^[dynamic]Session_Tab, entries: ^[dynamic]page.Saved_Entry, allocator := context.temp_allocator) {
		if len(out) == 0 { return }
		out[len(out) - 1].entries = entries[:]
		entries^ = make([dynamic]page.Saved_Entry, allocator)
	}
	for line_raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(line_raw, "\r")
		if first {
			first = false
			h := strings.trim_space(line)
			if h != SESSION_HEADER && h != SESSION_HEADER_V1 { return nil, 0, false }
			continue
		}
		switch {
		case strings.has_prefix(line, "current "):
			if n, nok := strconv.parse_int(strings.trim_space(line[len("current "):])); nok && n >= 0 { current = n }
		case strings.has_prefix(line, "tab "):
			u := strings.trim_space(line[len("tab "):])
			skipping = true
			if u == "" || len(u) > max_url_bytes || len(out) >= max_tabs { continue }
			if _, pok := url.parse_absolute(u, context.temp_allocator); !pok { continue }
			flush(&out, &entries, allocator)
			append(&out, Session_Tab{url = strings.clone(u, allocator)})
			skipping = false
		case strings.has_prefix(line, "e\t"):
			if skipping || len(out) == 0 { continue }
			f := strings.split(line[2:], "\t", context.temp_allocator)
			if len(f) < 13 { continue }
			e: page.Saved_Entry
			id, k1 := strconv.parse_u64(f[0])
			parent, k2 := strconv.parse_u64(f[1])
			seq, k3 := strconv.parse_u64(f[2])
			created, k4 := strconv.parse_i64(f[3])
			visited, k5 := strconv.parse_i64(f[4])
			flags, k6 := strconv.parse_int(f[5])
			sx, k7 := strconv.parse_f32(f[6])
			sy, k8 := strconv.parse_f32(f[7])
			zoom, k9 := strconv.parse_f32(f[8])
			if !(k1 && k2 && k3 && k4 && k5 && k6 && k7 && k8 && k9) || id == 0 { continue }
			u := field_unescape(f[9], context.temp_allocator)
			if len(u) > max_url_bytes { continue }
			if _, pok := url.parse_absolute(u, context.temp_allocator); !pok { continue }
			e = {id = id, parent = parent, seq = seq, created_ms = created, visited_ms = visited, scroll_manual = flags & 1 != 0,
				scroll = {max(sx, 0), max(sy, 0)}, zoom = clamp(zoom, 0, 100), url = strings.clone(u, allocator),
				title = field_unescape(f[10], allocator), icon = field_unescape(f[11], allocator)}
			if flags & 4 != 0 { e.state, e.has_state = field_unescape(f[12], allocator), true }
			append(&entries, e)
			if flags & 2 != 0 { out[len(out) - 1].current = id }
		}
	}
	if first { return nil, 0, false }
	flush(&out, &entries, allocator)
	current = len(out) == 0 ? 0 : clamp(current, 0, len(out) - 1)
	return out[:], current, true
}

// Addresses only (the first version's view).
session_serialize :: proc(urls: []string, current: int, max_url_bytes: int, allocator := context.temp_allocator) -> string {
	tabs := make([]Session_Tab, len(urls), context.temp_allocator)
	for u, i in urls { tabs[i].url = u }
	return session_serialize_tabs(tabs, current, max_url_bytes, 0, allocator)
}

session_parse :: proc(text: string, max_tabs, max_url_bytes: int, allocator := context.temp_allocator) -> (urls: []string, current: int, ok: bool) {
	tabs, cur, pok := session_parse_tabs(text, max_tabs, max_url_bytes, allocator)
	if !pok { return nil, 0, false }
	out := make([]string, len(tabs), allocator)
	for t, i in tabs { out[i] = t.url }
	return out, cur, true
}

// The saved form of a tab's tree.
session_tab_of :: proc(t: ^Tab) -> Session_Tab {
	st := Session_Tab{url = t.url == "" && t.kind == .Web ? HOME_URL : t.url}
	flat := page.session_flatten(&t.session)
	entries := make([]page.Saved_Entry, len(flat), context.temp_allocator)
	for e, i in flat {
		pid: u64 = 0
		if e.parent != nil && e.parent != t.session.root { pid = e.parent.id }
		entries[i] = {id = e.id, parent = pid, url = e.url, title = e.title, icon = e.icon, state = e.state, has_state = e.has_state,
			created_ms = e.created_ms, visited_ms = e.visited_ms, seq = e.seq, scroll_manual = e.scroll_manual,
			scroll = e.persisted.saved ? e.persisted.scroll : {}, zoom = e.persisted.saved ? e.persisted.zoom : 0}
	}
	st.entries = entries
	if cur := page.session_current(&t.session); cur != nil { st.current = cur.id }
	return st
}

// Writes the session when it changed (profile_save: autosave and exit).
session_save :: proc(app: ^App) {
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.restore") { return }
	tabs := make([]Session_Tab, len(app.tabs), context.temp_allocator)
	for t, i in app.tabs {
		entry_capture_current(app, t)   // where each tab is now
		tabs[i] = session_tab_of(t)
	}
	text := session_serialize_tabs(tabs, app.current, int(config.int_of(&app.prefs, "browser.session.max_url_bytes")), int(config.int_of(&app.prefs, "browser.session.max_state_bytes")))
	if text == session_last { return }
	path := session_path(app)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)text) != nil { return }
	if !win.MoveFileExW(win.utf8_to_wstring(tmp, context.temp_allocator), win.utf8_to_wstring(path, context.temp_allocator), win.MOVEFILE_REPLACE_EXISTING) { return }
	delete(session_last)
	session_last = strings.clone(text)
}

// The tabs to open at start-up (none when restoring is off, there is no file, or it is not a session file).
session_load :: proc(app: ^App) -> (tabs: []Session_Tab, current: int) {
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.restore") { return nil, 0 }
	data, err := os.read_entire_file(session_path(app), context.temp_allocator)
	if err != nil { return nil, 0 }
	t, c, ok := session_parse_tabs(string(data), int(config.int_of(&app.prefs, "browser.session.max_tabs")), int(config.int_of(&app.prefs, "browser.session.max_url_bytes")))
	if !ok { return nil, 0 }
	return t, c
}

// Opens the saved session at start-up: one tab per saved tab, with its history tree, only the current one loading now
// (the others load when first shown, as in Chrome). False when there is nothing to restore.
session_restore :: proc(app: ^App) -> bool {
	tabs, current := session_load(app)
	if len(tabs) == 0 { return false }
	w := &app.page_settings.web
	for st in tabs {
		t := tab_new(app)
		delete(t.url); t.url = strings.clone(st.url)
		delete(t.title); t.title = default_tab_title(st.url, context.allocator)
		t.lazy = true
		if len(st.entries) > 0 {
			page.session_load(&t.session, st.entries, st.current, w.history_max_entries, w.history_max_nodes)
			sync_history(t)
			if cur := page.session_current(&t.session); cur != nil {
				delete(t.url); t.url = strings.clone(cur.url)
				if cur.title != "" { delete(t.title); t.title = strings.clone(cur.title) }
			}
		}
		if page.session_current(&t.session) == nil { history_push(t, st.url) }
	}
	app.current = current
	session_lazy_load(app)
	return true
}

// The current tab, if restored and not loaded yet, loads now: its current entry, where it was left.
session_lazy_load :: proc(app: ^App) {
	t := current_tab(app)
	if t == nil || !t.lazy { return }
	t.lazy = false
	navigate(app, t, strings.clone(t.url, context.temp_allocator), record = false, restore = true, origin = .Replay)
}

session_destroy :: proc() {
	delete(session_last)
	session_last = ""
}
