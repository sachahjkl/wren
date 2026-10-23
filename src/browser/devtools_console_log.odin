package browser

// What the Console tab keeps of a tab's messages: the lines themselves are the tab's (t.console, filled by tab_log, one
// string each with its level as a prefix: "error: ", "warn: ", "> " for what the user typed), and beside them one
// Con_Meta per line (when it came, what it is, its optional structured payload), counts per kind for the tab strip's badges,
// and the helpers that read a line: its level and text, its group depth, the source (file:line) its stack names.
//
// Lines are dropped from the front in batches (a few at once when the limit browser.console.max_lines is passed), so a
// page that logs thousands of lines a second costs one memory move per batch, not one per line.

import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import "wb:config"
import "wb:page"

Con_Kind :: enum u8 { Log, Info, Warn, Error, Debug, Input, Result, Marker }

Con_Meta :: struct {
	at_ms:   i64,        // the local time of day of the message, in ms
	kind:    Con_Kind,
	payload: string,     // owned: the structured description of the arguments (JSON), "" when there is none
}

Con_Log :: struct {
	meta:   [dynamic]Con_Meta,
	counts: [Con_Kind]int,    // of the lines in t.console now
}

console_register_prefs :: proc(p: ^config.Prefs) {
	config.register(p, CONSOLE_PREFS[:])
}

CONSOLE_PREFS := [?]config.Def{
	{name = "browser.devtools.console.levels", kind = .Int, default = {i = 0b1111}, bounded = true, min = 0, max = 15,
		description = "The levels of console messages shown: a sum of 1 (verbose), 2 (info), 4 (warnings), 8 (errors)."},
	{name = "browser.devtools.console.timestamps", kind = .Bool, default = {b = false},
		description = "Show the time of each message of the console."},
	{name = "browser.devtools.console.preserve", kind = .Bool, default = {b = false},
		description = "Keep the console's messages when the page navigates (a line marks the navigation)."},
	{name = "browser.devtools.console.group_similar", kind = .Bool, default = {b = true},
		description = "Show a message repeated one after the other once, with its count."},
	{name = "browser.devtools.console.hide_network", kind = .Bool, default = {b = false},
		description = "Hide the console messages about requests that failed or were blocked."},
	{name = "browser.devtools.console.autocomplete", kind = .Bool, default = {b = true},
		description = "Suggest completions while typing in the console's evaluation line (Tab accepts)."},
	{name = "browser.devtools.console.eager_eval", kind = .Bool, default = {b = true},
		description = "Show the result of the expression being typed in the console without running anything that changes the page."},
	{name = "browser.devtools.console.max_payload_kb", kind = .Int, default = {i = 256}, bounded = true, min = 8, max = 65536, unit = "kB",
		description = "The most a console message may keep of the objects it was given (their structure, for the tree under the message); messages with more keep their text only."},
}

con_levels_default :: 0b1111

Con_Prefs :: struct {
	levels:        u32,
	timestamps:    bool,
	preserve:      bool,
	group_similar: bool,
	hide_network:  bool,
	autocomplete:  bool,
	eager_eval:    bool,
	max_payload:   int,
}

con_prefs: Con_Prefs

console_apply_prefs :: proc(p: ^config.Prefs) {
	con_prefs = {
		levels = u32(config.int_of(p, "browser.devtools.console.levels")),
		timestamps = config.bool_of(p, "browser.devtools.console.timestamps"),
		preserve = config.bool_of(p, "browser.devtools.console.preserve"),
		group_similar = config.bool_of(p, "browser.devtools.console.group_similar"),
		hide_network = config.bool_of(p, "browser.devtools.console.hide_network"),
		autocomplete = config.bool_of(p, "browser.devtools.console.autocomplete"),
		eager_eval = config.bool_of(p, "browser.devtools.console.eager_eval"),
		max_payload = int(config.int_of(p, "browser.devtools.console.max_payload_kb")) * 1024,
	}
}

// "error: x" -> (.Error, "x").
con_split :: proc(line: string) -> (Con_Level, string) {
	if strings.has_prefix(line, "error: ") { return .Error, line[7:] }
	if strings.has_prefix(line, "warn: ") { return .Warn, line[6:] }
	return .Log, line
}

Con_Level :: enum u8 { Log, Warn, Error }

// The absolute number of line `i` of t.console: it never changes while the line lives, whatever was dropped before it.
con_abs :: proc(t: ^Tab, i: int) -> u64 { return t.console_added - u64(len(t.console)) + u64(i) }

// Keeps the tab's console within browser.console.max_lines, dropping from the front in batches.
@(private = "file")
con_trim :: proc(t: ^Tab) {
	limit := max(the_app.cfg.console_max_lines, 1)
	slack := max(limit / 8, 16)
	if len(t.console) <= limit + slack { return }
	drop := len(t.console) - limit
	for l in t.console[:drop] { delete(l) }
	remove_range(&t.console, 0, drop)
	con_sync_meta(t)
}

// The meta of a tab follows its lines: whatever was dropped (here, or by code that clears t.console) goes from the front.
con_sync_meta :: proc(t: ^Tab) {
	m := &t.conlog
	for len(m.meta) > len(t.console) {
		first := m.meta[0]
		m.counts[first.kind] = max(m.counts[first.kind] - 1, 0)
		delete(first.payload)
		ordered_remove(&m.meta, 0)
	}
	if len(t.console) == 0 { m.counts = {} }
}

// Called by tab_log for every line: the line, then what the panel keeps beside it.
console_append :: proc(t: ^Tab, level: page.Log_Level, message: string) {
	// the page's console describes its arguments (prelude/compat.js) in a line of its own that is not a message: the next line takes it
	if len(message) > 3 && message[0] == 1 {
		switch {
		case strings.has_prefix(message, "\x01dt:"):
			delete(dev.con.pending_payload)
			dev.con.pending_payload = len(message) - 4 <= max(con_prefs.max_payload, 1024) ? strings.clone(message[4:]) : ""
			return
		case strings.has_prefix(message, "\x01dtc:"):
			console_complete_reply(message[5:])
			return
		}
	}
	prefix := ""
	kind := Con_Kind.Log
	switch level {
	case .Log:
	case .Warn:  prefix, kind = "warn: ", .Warn
	case .Error: prefix, kind = "error: ", .Error
	}
	append(&t.console, fmt.aprintf("%s%s", prefix, message))
	t.console_added += 1
	if kind == .Log {
		if strings.has_prefix(message, "> ") { kind = .Input } else if dev.con.evaluating { kind = .Result }
	}
	con_sync_meta(t)   // (lines dropped behind our back)
	m := &t.conlog
	for len(m.meta) < len(t.console) - 1 { append(&m.meta, Con_Meta{kind = .Log}); m.counts[.Log] += 1 }
	payload := ""
	if dev.con.pending_payload != "" { payload, dev.con.pending_payload = dev.con.pending_payload, "" }
	if payload != "" && kind == .Log {
		switch payload_level(payload) {
		case "info": kind = .Info
		case "debug": kind = .Debug
		case "result": kind = .Result
		}
	}
	append(&m.meta, Con_Meta{at_ms = local_time_ms(), kind = kind, payload = payload})
	m.counts[kind] += 1
	con_trim(t)
	if dev.visible && dev.panel == .Console { the_app.frames_requested = max(the_app.frames_requested, 2) }
}

// A page's navigation (or a built-in page loading): the console starts over unless it is kept, with a line saying so.
console_reset :: proc(t: ^Tab) {
	if con_prefs.preserve && len(t.console) > 0 {
		console_append(t, .Log, "Navigated")
		t.conlog.meta[len(t.conlog.meta) - 1].kind = .Marker
		t.conlog.counts[.Log] -= 1
		t.conlog.counts[.Marker] += 1
		return
	}
	for l in t.console { delete(l) }
	clear(&t.console)
	con_sync_meta(t)
}

console_log_destroy :: proc(t: ^Tab) {
	for m in t.conlog.meta { delete(m.payload) }
	delete(t.conlog.meta)
	t.conlog = {}
}

// (errors, warnings) of the tab's console, for the badges.
console_counts :: proc(t: ^Tab) -> (errors, warnings: int) {
	return t.conlog.counts[.Error], t.conlog.counts[.Warn]
}

// The group depth of a line: the toolkit's console indents what is inside console.group by two spaces per level.
con_depth :: proc(text: string) -> (depth: int, rest: string) {
	i := 0
	for i + 1 < len(text) && text[i] == ' ' && text[i + 1] == ' ' && depth < 12 { i += 2; depth += 1 }
	return depth, text[i:]
}

// Where a message came from: the first frame of its stack, "at f (url:line:col)" or "at url:line:col". `file` is the last
// part of the URL, `line` 0 when there is none.
Con_Source :: struct { url, file: string, line, col: int }

con_source :: proc(text: string) -> (src: Con_Source) {
	nl := strings.index_byte(text, '\n')
	if nl < 0 { return }
	rest := text[nl + 1:]
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		ln := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end + 1:]
		ln = strings.trim_space(ln)
		if !strings.has_prefix(ln, "at ") { continue }
		loc := ln[3:]
		if open := strings.last_index_byte(loc, '('); open >= 0 && strings.has_suffix(loc, ")") { loc = loc[open + 1:len(loc) - 1] }
		return con_parse_location(loc)
	}
	return
}

// "http://x/a.js:12:34" -> url, "a.js", 12, 34.
con_parse_location :: proc(loc: string) -> (src: Con_Source) {
	s := loc
	nums: [2]int
	got := 0
	for got < 2 {
		i := strings.last_index_byte(s, ':')
		if i < 0 { break }
		v, ok := parse_uint(s[i + 1:])
		if !ok { break }
		nums[got] = v
		got += 1
		s = s[:i]
	}
	if got == 0 || s == "" { return }
	src.url = s
	src.line, src.col = nums[got - 1], got == 2 ? nums[0] : 0
	if got == 1 { src.col = 0 }
	name := s
	if q := strings.index_byte(name, '?'); q >= 0 { name = name[:q] }
	if i := strings.last_index_byte(name, '/'); i >= 0 && i + 1 < len(name) { name = name[i + 1:] }
	src.file = name
	return
}

@(private = "file")
parse_uint :: proc(s: string) -> (int, bool) {
	if s == "" || len(s) > 9 { return 0, false }
	v := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' { return 0, false }
		v = v * 10 + int(c - '0')
	}
	return v, true
}

// "09:41:07.123" from a time of day in ms.
con_time_text :: proc(at_ms: i64) -> string {
	s := at_ms / 1000
	return fmt.tprintf("%02d:%02d:%02d.%03d", s / 3600 %% 24, s / 60 %% 60, s %% 60, at_ms %% 1000)
}

// The local time of day in ms.
@(private = "file")
local_time_ms :: proc() -> i64 {
	ft: win.FILETIME
	utc, st: win.SYSTEMTIME
	win.GetSystemTimeAsFileTime(&ft)
	win.FileTimeToSystemTime(&ft, &utc)
	win.SystemTimeToTzSpecificLocalTime(nil, &utc, &st)
	return ((i64(st.hour) * 60 + i64(st.minute)) * 60 + i64(st.second)) * 1000 + i64(st.milliseconds)
}

// Whether a message is about a request that failed (what "hide network" hides).
con_is_network :: proc(text: string) -> bool {
	return strings.has_prefix(text, "Failed to load") || strings.contains(text, "blocked by CORS policy") || strings.contains(text, "net::ERR") ||
		strings.has_prefix(text, "module ") || strings.contains(text, "blocked insecure request") || strings.has_prefix(text, "fetch failed")
}
