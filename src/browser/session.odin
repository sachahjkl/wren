package browser

// Session restore (browser.session.restore, off by default: a browser that reopens yesterday's pages is a choice the
// user makes, and runs that share a profile, such as tests, then start clean). The address of every tab and which one
// is current are written to session.txt in the profile with the other profile files (autosave, and at exit), and opened
// again at the next start when no address is given on the command line.
//
// The file is plain text, versioned, written to a temporary file then moved over the old one (a crash in between leaves
// the old one). Reading is forgiving: unknown lines are skipped, a line too long or a URL that does not parse is
// dropped, the tab count is capped, and a file without the header (or not a session file at all) restores nothing.
//
//     wren-session 1
//     current 2
//     tab https://example.com/
//     tab about:config

import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "wb:config"
import "wb:url"

SESSION_HEADER :: "wren-session 1"

SESSION_PREFS := [?]config.Def{
	{name = "browser.session.restore", kind = .Bool, default = {b = false},
		description = "At start-up, reopen the tabs that were open when the browser last closed (when no address is given on the command line). Needs browser.profile.persist."},
	{name = "browser.session.max_tabs", kind = .Int, default = {i = 100}, bounded = true, min = 1, max = 10_000,
		description = "Most tabs a restored session reopens."},
	{name = "browser.session.max_url_bytes", kind = .Int, default = {i = 16 << 10}, bounded = true, min = 256, max = 2 << 20, bytes = true, unit = "bytes",
		description = "Longest address a session file may hold for a tab (longer ones, data: URLs for instance, are not saved)."},
}

register_session_prefs :: proc(p: ^config.Prefs) { config.register(p, SESSION_PREFS[:]) }

@(private = "file") session_last: string   // what was written last (nothing is written when it did not change)

session_path :: proc(app: ^App) -> string { return strings.concatenate({app.profile_dir, "/session.txt"}, context.temp_allocator) }

// The text of a session (pure: session_test.odin). Addresses that cannot be written on one line, or are too long, are
// left out; `current` follows the tab it pointed at.
session_serialize :: proc(urls: []string, current: int, max_url_bytes: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, SESSION_HEADER)
	strings.write_byte(&sb, '\n')
	kept := make([dynamic]string, context.temp_allocator)
	cur := 0
	for u, i in urls {
		if u == "" || len(u) > max_url_bytes || strings.contains_any(u, "\r\n\x00") { continue }
		if i == current { cur = len(kept) }
		append(&kept, u)
	}
	strings.write_string(&sb, "current ")
	strings.write_int(&sb, cur)
	strings.write_byte(&sb, '\n')
	for u in kept {
		strings.write_string(&sb, "tab ")
		strings.write_string(&sb, u)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// The tabs of a session file (pure). `ok` false when it is not one.
session_parse :: proc(text: string, max_tabs, max_url_bytes: int, allocator := context.temp_allocator) -> (urls: []string, current: int, ok: bool) {
	out := make([dynamic]string, allocator)
	rest := text
	first := true
	for line_raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(line_raw, "\r")
		if first {
			first = false
			if strings.trim_space(line) != SESSION_HEADER { return nil, 0, false }
			continue
		}
		switch {
		case strings.has_prefix(line, "current "):
			if n, nok := strconv.parse_int(strings.trim_space(line[len("current "):])); nok && n >= 0 { current = n }
		case strings.has_prefix(line, "tab "):
			u := strings.trim_space(line[len("tab "):])
			if u == "" || len(u) > max_url_bytes || len(out) >= max_tabs { continue }
			if _, pok := url.parse_absolute(u, context.temp_allocator); !pok { continue }
			append(&out, strings.clone(u, allocator))
		}
	}
	if first { return nil, 0, false }
	current = len(out) == 0 ? 0 : clamp(current, 0, len(out) - 1)
	return out[:], current, true
}

// Writes the session when it changed (profile_save: autosave and exit).
session_save :: proc(app: ^App) {
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.restore") { return }
	urls := make([]string, len(app.tabs), context.temp_allocator)
	for t, i in app.tabs { urls[i] = t.url == "" && t.kind == .Web ? HOME_URL : t.url }
	text := session_serialize(urls, app.current, int(config.int_of(&app.prefs, "browser.session.max_url_bytes")))
	if text == session_last { return }
	path := session_path(app)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)text) != nil { return }
	if !win.MoveFileExW(win.utf8_to_wstring(tmp, context.temp_allocator), win.utf8_to_wstring(path, context.temp_allocator), win.MOVEFILE_REPLACE_EXISTING) { return }
	delete(session_last)
	session_last = strings.clone(text)
}

// The tabs to open at start-up (none when restoring is off, there is no file, or it is not a session file).
session_load :: proc(app: ^App) -> (urls: []string, current: int) {
	if !app.cfg.persist_profile || !config.bool_of(&app.prefs, "browser.session.restore") { return nil, 0 }
	data, err := os.read_entire_file(session_path(app), context.temp_allocator)
	if err != nil { return nil, 0 }
	u, c, ok := session_parse(string(data), int(config.int_of(&app.prefs, "browser.session.max_tabs")), int(config.int_of(&app.prefs, "browser.session.max_url_bytes")))
	if !ok { return nil, 0 }
	return u, c
}

// Opens the saved session at start-up: one tab per address, only the current one loading now (the others load when
// first shown, as in Chrome). False when there is nothing to restore.
session_restore :: proc(app: ^App) -> bool {
	urls, current := session_load(app)
	if len(urls) == 0 { return false }
	for u in urls {
		t := tab_new(app)
		delete(t.url); t.url = strings.clone(u)
		delete(t.title); t.title = default_tab_title(u, context.allocator)
		t.lazy = true
		history_push(t, u)
	}
	app.current = current
	session_lazy_load(app)
	return true
}

// The current tab, if restored and not loaded yet, loads now.
session_lazy_load :: proc(app: ^App) {
	t := current_tab(app)
	if t == nil || !t.lazy { return }
	t.lazy = false
	navigate(app, t, strings.clone(t.url, context.temp_allocator), record = false)
}

session_destroy :: proc() {
	delete(session_last)
	session_last = ""
}
