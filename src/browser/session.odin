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
// a session file at all) restores nothing. Version 1 files (addresses only) are read too. After an abnormal end
// crash_recovery.odin writes the same format to recovery.txt, whatever browser.session.restore says.
//
//     wren-session 2
//     current 1
//     tab https://example.com/b
//     e	<id>	<parent>	<seq>	<created ms>	<visited ms>	<flags>	<scroll x>	<scroll y>	<zoom>	<url>	<title>	<icon>	<state>
//     tab about:config
//
// flags: 1 history.scrollRestoration manual, 2 the tab's current entry, 4 has a state.
//
// With several windows (version 3) each one starts with a line `window <left> <top> <width> <height> <state>` (its outer rectangle on
// the screen in pixels, state 0 normal, 1 maximized) followed by its own `current` and tabs; a file of one window is the version 2
// above, and a version 1 or 2 file is read as one window without a rectangle.

import "base:runtime"
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
SESSION_HEADER_V3 :: "wren-session 3"   // several windows: a `window` line before the tabs of each

SESSION_PREFS := [?]config.Def{
	{name = "browser.session.restore", kind = .Bool, default = {b = false},
		description = "At start-up, reopen the tabs that were open when the browser last closed (when no address is given on the command line), each with its history (back, forward, its history tree) and where it was left. Needs browser.profile.persist."},
	{name = "browser.session.max_tabs", kind = .Int, default = {i = 100}, bounded = true, min = 1, max = 10_000,
		description = "Most tabs a restored session reopens."},
	{name = "browser.session.max_windows", kind = .Int, default = {i = 32}, bounded = true, min = 1, max = 256,
		description = "Most windows a restored session reopens (their tabs count against browser.session.max_tabs)."},
	{name = "browser.session.max_url_bytes", kind = .Int, default = {i = 16 << 10}, bounded = true, min = 256, max = 2 << 20, bytes = true, unit = "bytes",
		description = "Longest address a session file may hold for a tab or an entry (longer ones, data: URLs for instance, are not saved)."},
	{name = "browser.session.max_state_bytes", kind = .Int, default = {i = 64 << 10}, bounded = true, min = 0, max = 16 << 20, bytes = true, unit = "bytes",
		description = "Largest history.state of an entry the session file keeps (a larger one is restored as null)."},
}

register_session_prefs :: proc(p: ^config.Prefs) { config.register(p, SESSION_PREFS[:]) }

@(private = "file") session_last: string   // what was written last (nothing is written when it did not change)

session_path :: proc(app: ^App) -> string { return strings.concatenate({app.profile_dir, "/session.txt"}, context.temp_allocator) }

// One window of a session file: where it was, and its tabs.
Session_Window :: struct {
	has_rect:  bool,
	rect:      [4]int,   // left, top, width, height: the outer rectangle on the screen, in pixels
	maximized: bool,
	tabs:      []Session_Tab,
	current:   int,
}

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
	return session_serialize_windows([]Session_Window{{tabs = tabs, current = current}}, max_url_bytes, max_state_bytes, allocator)
}

// The same for every window (a single window is written as the version 2 file always was).
session_serialize_windows :: proc(windows: []Session_Window, max_url_bytes, max_state_bytes: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	multi := len(windows) > 1
	strings.write_string(&sb, multi ? SESSION_HEADER_V3 : SESSION_HEADER)
	strings.write_byte(&sb, '\n')
	for w in windows {
		if multi {
			r := w.has_rect ? w.rect : {}
			fmt.sbprintf(&sb, "window %d %d %d %d %d\n", r[0], r[1], r[2], r[3], w.maximized ? 1 : 0)
		}
		session_write_tabs(&sb, w.tabs, w.current, max_url_bytes, max_state_bytes)
	}
	return strings.to_string(sb)
}

@(private = "file")
session_write_tabs :: proc(sb: ^strings.Builder, tabs: []Session_Tab, current: int, max_url_bytes, max_state_bytes: int) {
	kept := make([dynamic]int, context.temp_allocator)
	cur := 0
	for t, i in tabs {
		if !writable(t.url, max_url_bytes) { continue }
		if i == current { cur = len(kept) }
		append(&kept, i)
	}
	fmt.sbprintf(sb, "current %d\n", cur)
	for i in kept {
		t := tabs[i]
		strings.write_string(sb, "tab ")
		strings.write_string(sb, t.url)
		strings.write_byte(sb, '\n')
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
			fmt.sbprintf(sb, "e\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%.1f\t%.3f\t", e.id, parent, e.seq, e.created_ms, e.visited_ms, flags, e.scroll.x, e.scroll.y, e.zoom)
			field_escape(sb, e.url)
			strings.write_byte(sb, '\t')
			field_escape(sb, e.title)
			strings.write_byte(sb, '\t')
			field_escape(sb, e.icon)
			strings.write_byte(sb, '\t')
			if state { field_escape(sb, e.state) }
			strings.write_byte(sb, '\n')
		}
	}
}

// The tabs of a session file (pure), of every window one after the other (`current` is the first window's). `ok` false when it is
// not one. `max_entries` (when above 0) caps the entries read for a tab: a file that was not written by this program can hold millions.
session_parse_tabs :: proc(text: string, max_tabs, max_url_bytes: int, allocator := context.temp_allocator, max_entries := 0) -> (tabs: []Session_Tab, current: int, ok: bool) {
	windows, wok := session_parse_windows(text, max_tabs, max_url_bytes, allocator, max_entries)
	if !wok { return nil, 0, false }
	all := make([dynamic]Session_Tab, allocator)
	for w, i in windows {
		if i == 0 { current = w.current }
		append(&all, ..w.tabs)
	}
	return all[:], current, true
}

// The windows of a session file (pure): a file of version 1 or 2 is one window without a rectangle. `max_tabs` counts the tabs of all of
// them; `max_windows` caps the windows (0: no cap).
session_parse_windows :: proc(text: string, max_tabs, max_url_bytes: int, allocator := context.temp_allocator, max_entries := 0, max_windows := 0) -> (windows: []Session_Window, ok: bool) {
	wins := make([dynamic]Session_Window, allocator)
	out := make([dynamic]Session_Tab, allocator)
	entries := make([dynamic]page.Saved_Entry, allocator)
	total := 0
	rest := text
	first := true
	skipping := false   // the tab being read was dropped: its entries too
	drop_window := false   // the window being read is over the cap: all of it is dropped
	flush :: proc(out: ^[dynamic]Session_Tab, entries: ^[dynamic]page.Saved_Entry, allocator := context.temp_allocator) {
		if len(out) == 0 { return }
		out[len(out) - 1].entries = entries[:]
		entries^ = make([dynamic]page.Saved_Entry, allocator)
	}
	// the tabs read so far belong to the last window (the first one is there from the first line that needs it)
	close_window :: proc(wins: ^[dynamic]Session_Window, out: ^[dynamic]Session_Tab, entries: ^[dynamic]page.Saved_Entry, allocator: runtime.Allocator) {
		flush(out, entries, allocator)
		if len(wins) == 0 { return }
		w := &wins[len(wins) - 1]
		w.tabs = out[:]
		w.current = len(out) == 0 ? 0 : clamp(w.current, 0, len(out) - 1)
		out^ = make([dynamic]Session_Tab, allocator)
	}
	need_window :: proc(wins: ^[dynamic]Session_Window) { if len(wins) == 0 { append(wins, Session_Window{}) } }
	for line_raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(line_raw, "\r")
		if first {
			first = false
			h := strings.trim_space(line)
			if h != SESSION_HEADER && h != SESSION_HEADER_V1 && h != SESSION_HEADER_V3 { return nil, false }
			continue
		}
		switch {
		case strings.has_prefix(line, "window "):
			close_window(&wins, &out, &entries, allocator)
			skipping = true   // (until a tab line of this window)
			drop_window = max_windows > 0 && len(wins) >= max_windows
			if drop_window { continue }
			w := Session_Window{}
			f := strings.fields(line[len("window "):], context.temp_allocator)
			if len(f) >= 5 {
				v: [5]int
				good := true
				for k in 0 ..< 5 {
					n, nok := strconv.parse_int(f[k])
					v[k], good = n, good && nok
				}
				if good && v[2] > 0 && v[3] > 0 { w.has_rect, w.rect, w.maximized = true, {v[0], v[1], v[2], v[3]}, v[4] == 1 }
			}
			append(&wins, w)
			skipping = false
		case strings.has_prefix(line, "current "):
			if drop_window { continue }
			need_window(&wins)
			if n, nok := strconv.parse_int(strings.trim_space(line[len("current "):])); nok && n >= 0 { wins[len(wins) - 1].current = n }
		case strings.has_prefix(line, "tab "):
			if drop_window { continue }
			need_window(&wins)
			u := strings.trim_space(line[len("tab "):])
			skipping = true
			if u == "" || len(u) > max_url_bytes || total >= max_tabs { continue }
			if _, pok := url.parse_absolute(u, context.temp_allocator); !pok { continue }
			flush(&out, &entries, allocator)
			append(&out, Session_Tab{url = strings.clone(u, allocator)})
			total += 1
			skipping = false
		case strings.has_prefix(line, "e\t"):
			if skipping || len(out) == 0 || (max_entries > 0 && len(entries) >= max_entries) { continue }
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
	if first { return nil, false }
	close_window(&wins, &out, &entries, allocator)
	return wins[:], true
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

// The text of the session as the tabs are now (temporary allocator): where each tab was left is captured first.
session_text :: proc(app: ^App) -> string {
	if len(app.windows) > 0 {
		windows := make([]Session_Window, len(app.windows), context.temp_allocator)
		for w, wi in app.windows {
			list := window_tabs(app, w)^
			tabs := make([]Session_Tab, len(list), context.temp_allocator)
			for t, i in list {
				entry_capture_current(app, t)
				tabs[i] = session_tab_of(t)
			}
			rect, maximized := window_placement(w)
			windows[wi] = {has_rect = true, rect = rect, maximized = maximized, tabs = tabs, current = window_current(app, w)^}
		}
		return session_serialize_windows(windows, int(config.int_of(&app.prefs, "browser.session.max_url_bytes")), int(config.int_of(&app.prefs, "browser.session.max_state_bytes")))
	}
	tabs := make([]Session_Tab, len(app.tabs), context.temp_allocator)
	for t, i in app.tabs {
		entry_capture_current(app, t)
		tabs[i] = session_tab_of(t)
	}
	return session_serialize_tabs(tabs, app.current, int(config.int_of(&app.prefs, "browser.session.max_url_bytes")), int(config.int_of(&app.prefs, "browser.session.max_state_bytes")))
}

// Writes the session when it changed (profile_save: autosave and exit).
session_save :: proc(app: ^App) {
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.restore") { return }
	text := session_text(app)
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
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.restore") { return false }
	data, err := os.read_entire_file(session_path(app), context.temp_allocator)
	if err != nil { return false }
	text := string(data)
	windows, ok := session_parse_windows(text, int(config.int_of(&app.prefs, "browser.session.max_tabs")), int(config.int_of(&app.prefs, "browser.session.max_url_bytes")), max_windows = int(config.int_of(&app.prefs, "browser.session.max_windows")))
	if !ok { return false }
	return session_open_windows(app, windows, text)
}

@(private = "file") rest_text: string   // the text of a session whose other windows open once the renderer exists

// Opens the first window of a session in the window there is (its rectangle, its tabs); the others wait for
// session_open_other_windows (a window needs the renderer, which starts later). false: nothing to open.
session_open_windows :: proc(app: ^App, windows: []Session_Window, text: string) -> bool {
	if len(windows) == 0 || (len(windows) == 1 && len(windows[0].tabs) == 0) { return false }
	first := windows[0]
	if len(first.tabs) > 0 { session_open_tabs(app, first.tabs, first.current) } else { tab_open(app) }
	if first.has_rect && app.active != nil { window_placement_set(app.active, first.rect, first.maximized) }
	if len(windows) > 1 {
		delete(rest_text)
		rest_text = strings.clone(text)
	}
	return true
}

// The windows after the first one of the session that was just opened (main.odin, once the renderer and the first window are up).
session_open_other_windows :: proc(app: ^App) {
	if rest_text == "" { return }
	text := rest_text
	defer { delete(text); rest_text = "" }
	windows, ok := session_parse_windows(text, int(config.int_of(&app.prefs, "browser.session.max_tabs")), int(config.int_of(&app.prefs, "browser.session.max_url_bytes")), max_windows = int(config.int_of(&app.prefs, "browser.session.max_windows")))
	if !ok || len(windows) < 2 { return }
	for w in windows[1:] {
		size := w.has_rect ? [2]int{w.rect[2], w.rect[3]} : [2]int{1280, 800}
		nw := window_open(app, size, show = false)
		if nw == nil { continue }
		if w.has_rect { window_placement_set(nw, w.rect, w.maximized) }
		prev := app.active
		window_activate(app, nw)
		if len(w.tabs) > 0 { session_open_tabs(app, w.tabs, w.current) } else { tab_open(app) }
		window_activate(app, prev)
		if !app.headless { window_show(nw) }
	}
}

// Adds a tab for each saved one after the tabs there are (crash_recovery.odin uses it for a snapshot too); `current` is
// the index, among `tabs`, of the one to show. Returns the index of the first tab added.
session_open_tabs :: proc(app: ^App, tabs: []Session_Tab, current: int) -> (first: int) {
	first = len(app.tabs)
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
	app.current = first + clamp(current, 0, max(len(tabs) - 1, 0))
	session_lazy_load(app)
	return
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
