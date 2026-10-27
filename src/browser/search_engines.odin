package browser

// The search engines: a list the user edits (about:config, category Search), each with a name, an address where %s
// stands for the words searched, an optional keyword and an initial for its badge; one of them is the default
// (browser.search.engine names its id).
//
//   * Where it is used: words typed in the address bar that are not an address, the address bar's "Search with" row and
//     its row of engines ("This time, search with"), the context menu's "Search X for ...".
//   * Keywords: "@g cats" (or "g cats" for a keyword "g") typed in the address bar searches "cats" with the engine whose
//     keyword is the first word, whatever the default.
//   * Saved in the profile as search_engines.txt (a versioned text file, one engine per line), written when the list
//     changes. Without the file: the built-in engines. A profile of before the list keeps its choice: its
//     browser.search.engine already names a built-in id, and "custom" becomes an engine "Custom" made from the former
//     browser.search.custom_url (read from the profile's preferences, no longer registered), written at once.
//   * Built-in engines can be edited or removed like the others; "Restore the built-in engines" puts back the missing ones.

import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "wb:blocker"
import "wb:config"

Search_Engine :: struct {
	id:      string,   // stable (what browser.search.engine names); owned
	name:    string,   // owned
	keyword: string,   // "" = none; owned
	url:     string,   // with %s for the words (percent-encoded); owned
}

Search_Engines :: struct {
	list:   [dynamic]Search_Engine,
	serial: u64,    // bumped at every change (about:config's row, the address bar)
}

Builtin_Engine :: struct { id, name, keyword, url: string }

BUILTIN_ENGINES := [?]Builtin_Engine{
	{"duckduckgo", "DuckDuckGo", "@d", "https://duckduckgo.com/?q=%s"},
	{"bing", "Bing", "@b", "https://www.bing.com/search?q=%s"},
	{"google", "Google", "@g", "https://www.google.com/search?q=%s"},
	{"qwant", "Qwant", "@q", "https://www.qwant.com/?q=%s"},
	{"ecosia", "Ecosia", "@e", "https://www.ecosia.org/search?q=%s"},
	{"startpage", "Startpage", "@s", "https://www.startpage.com/do/search?query=%s"},
	{"wikipedia", "Wikipedia", "@w", "https://en.wikipedia.org/w/index.php?search=%s"},
}

// The engine of a list with nothing in it (the user cannot remove the last one; a hand-edited file could).
FALLBACK_ENGINE :: Search_Engine{id = "duckduckgo", name = "DuckDuckGo", keyword = "@d", url = "https://duckduckgo.com/?q=%s"}

SEARCH_ENGINES_MAGIC :: "wren-search-engines 1"
SEARCH_ENGINES_FILE :: "search_engines.txt"

engines_clear :: proc(se: ^Search_Engines) {
	for e in se.list { engine_free(e) }
	clear(&se.list)
	se.serial += 1
}

engines_destroy :: proc(se: ^Search_Engines) {
	for e in se.list { engine_free(e) }
	delete(se.list)
	se^ = {}
}

@(private = "file")
engine_free :: proc(e: Search_Engine) { delete(e.id); delete(e.name); delete(e.keyword); delete(e.url) }

@(private = "file")
engine_clone :: proc(id, name, keyword, url: string) -> Search_Engine {
	return {strings.clone(id), strings.clone(name), strings.clone(keyword), strings.clone(url)}
}

engines_builtin :: proc(se: ^Search_Engines) {
	engines_clear(se)
	for b in BUILTIN_ENGINES { append(&se.list, engine_clone(b.id, b.name, b.keyword, b.url)) }
}

// The built-in engines the list lacks (by id), put back at the end. How many.
engines_restore_builtins :: proc(se: ^Search_Engines) -> int {
	n := 0
	for b in BUILTIN_ENGINES {
		if engines_find(se, b.id) >= 0 { continue }
		kw := b.keyword
		if engines_keyword_owner(se, kw) >= 0 { kw = "" }   // (another engine took it meanwhile)
		append(&se.list, engine_clone(b.id, b.name, kw, b.url))
		n += 1
	}
	if n > 0 { se.serial += 1 }
	return n
}

engines_missing_builtins :: proc(se: ^Search_Engines) -> int {
	n := 0
	for b in BUILTIN_ENGINES { if engines_find(se, b.id) < 0 { n += 1 } }
	return n
}

engines_find :: proc(se: ^Search_Engines, id: string) -> int {
	for e, i in se.list { if e.id == id { return i } }
	return -1
}

// The engine whose keyword is `kw` (letter case aside), -1: none.
engines_keyword_owner :: proc(se: ^Search_Engines, kw: string) -> int {
	if kw == "" { return -1 }
	for e, i in se.list { if e.keyword != "" && strings.equal_fold(e.keyword, kw) { return i } }
	return -1
}

// Index of the default engine: the one `id` names, else the first. -1 only for an empty list.
engines_default :: proc(se: ^Search_Engines, id: string) -> int {
	if i := engines_find(se, id); i >= 0 { return i }
	return len(se.list) > 0 ? 0 : -1
}

engine_at :: proc(se: ^Search_Engines, i: int) -> Search_Engine {
	return i >= 0 && i < len(se.list) ? se.list[i] : FALLBACK_ENGINE
}

// The address that searches `words` with engine `e` (temp). An address without %s gets the words at its end.
engine_url :: proc(e: Search_Engine, words: string) -> string {
	q := percent_encode_query(words)
	if !strings.contains(e.url, "%s") { return strings.concatenate({e.url, q}, context.temp_allocator) }
	out, _ := strings.replace_all(e.url, "%s", q, context.temp_allocator)
	return out
}

// The letter of the engine's badge: the first letter of its name, in capitals.
engine_initial :: proc(e: Search_Engine) -> string {
	for r, i in e.name {
		if r == ' ' || r == '@' { continue }
		return strings.to_upper(e.name[i:][:utf8.rune_size(r)], context.temp_allocator)
	}
	return "?"
}

// "@g cats": the engine of keyword "@g" and the words "cats". ok = false: the first word is no keyword, or nothing
// follows it.
engines_keyword :: proc(se: ^Search_Engines, text: string) -> (engine: int, words: string, ok: bool) {
	s := strings.trim_space(text)
	sp := strings.index_any(s, " \t")
	if sp <= 0 { return -1, "", false }
	i := engines_keyword_owner(se, s[:sp])
	rest := strings.trim_space(s[sp:])
	if i < 0 || rest == "" { return -1, "", false }
	return i, rest, true
}

////////////////////////////////
// Editing

Engine_Error :: enum u8 { None, No_Name, Bad_Url, No_Placeholder, Keyword_Space, Keyword_Taken, Name_Taken }

engine_error_text :: proc(e: Engine_Error) -> string {
	switch e {
	case .None:           return ""
	case .No_Name:        return "The engine needs a name."
	case .Bad_Url:        return "The address must start with https:// or http://."
	case .No_Placeholder: return "The address needs %s where the words searched go (https://example.com/search?q=%s)."
	case .Keyword_Space:  return "A keyword is one word, without spaces."
	case .Keyword_Taken:  return "Another engine has this keyword."
	case .Name_Taken:     return "Another engine has this name."
	}
	return ""
}

// What is wrong with an engine as typed; `self`: the index of the engine being edited (-1: a new one).
engine_validate :: proc(se: ^Search_Engines, self: int, name, keyword, url: string) -> Engine_Error {
	n, k, u := strings.trim_space(name), strings.trim_space(keyword), strings.trim_space(url)
	if n == "" { return .No_Name }
	lu := strings.to_lower(u, context.temp_allocator)
	if (!strings.has_prefix(lu, "https://") && !strings.has_prefix(lu, "http://")) || len(u) <= len("https://") { return .Bad_Url }
	if !strings.contains(u, "%s") { return .No_Placeholder }
	if strings.contains_any(k, " \t") { return .Keyword_Space }
	if o := engines_keyword_owner(se, k); o >= 0 && o != self { return .Keyword_Taken }
	for e, i in se.list { if i != self && strings.equal_fold(e.name, n) { return .Name_Taken } }
	return .None
}

// A new id from a name: lower case letters, digits and "-", unique in the list.
@(private = "file")
engine_new_id :: proc(se: ^Search_Engines, name: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)strings.to_lower(name, context.temp_allocator) {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'): strings.write_byte(&sb, c)
		case strings.builder_len(sb) > 0 && sb.buf[len(sb.buf) - 1] != '-': strings.write_byte(&sb, '-')
		}
	}
	base := strings.trim(strings.to_string(sb), "-")
	if base == "" { base = "engine" }
	id := base
	for n := 2; engines_find(se, id) >= 0; n += 1 {
		id = strings.concatenate({base, "-", itoa_tmp(n)}, context.temp_allocator)
	}
	return id
}

@(private = "file")
itoa_tmp :: proc(n: int) -> string {
	buf: [24]u8
	i := len(buf)
	v := n
	for { i -= 1; buf[i] = u8('0' + v % 10); v /= 10; if v == 0 { break } }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// Adds an engine (checked with engine_validate first); returns its index.
engines_add :: proc(se: ^Search_Engines, name, keyword, url: string) -> int {
	n := strings.trim_space(name)
	append(&se.list, engine_clone(engine_new_id(se, n), n, strings.trim_space(keyword), strings.trim_space(url)))
	se.serial += 1
	return len(se.list) - 1
}

// Changes engine `i` (its id stays: the default stays the default).
engines_update :: proc(se: ^Search_Engines, i: int, name, keyword, url: string) {
	if i < 0 || i >= len(se.list) { return }
	e := &se.list[i]
	n := engine_clone(e.id, strings.trim_space(name), strings.trim_space(keyword), strings.trim_space(url))
	engine_free(e^)
	e^ = n
	se.serial += 1
}

engines_remove :: proc(se: ^Search_Engines, i: int) {
	if i < 0 || i >= len(se.list) { return }
	engine_free(se.list[i])
	ordered_remove(&se.list, i)
	se.serial += 1
}

// Moves engine `i` one place up (-1) or down (+1): the order of the lists that show them.
engines_move :: proc(se: ^Search_Engines, i, dir: int) {
	j := i + dir
	if i < 0 || i >= len(se.list) || j < 0 || j >= len(se.list) { return }
	se.list[i], se.list[j] = se.list[j], se.list[i]
	se.serial += 1
}

////////////////////////////////
// The profile's file

@(private = "file")
field_escape :: proc(sb: ^strings.Builder, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '\\': strings.write_string(sb, "\\\\")
		case '\t': strings.write_string(sb, "\\t")
		case '\n': strings.write_string(sb, "\\n")
		case '\r': strings.write_string(sb, "\\r")
		case: strings.write_byte(sb, c)
		}
	}
}

@(private = "file")
field_unescape :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\\') { return s }
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 't': strings.write_byte(&sb, '\t')
			case 'n': strings.write_byte(&sb, '\n')
			case 'r': strings.write_byte(&sb, '\r')
			case: strings.write_byte(&sb, s[i])
			}
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// The file's text: the magic line, then "id <TAB> name <TAB> keyword <TAB> address" per engine, in order (temp).
engines_serialize :: proc(se: ^Search_Engines) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, SEARCH_ENGINES_MAGIC)
	strings.write_string(&sb, "\n# id\tname\tkeyword\taddress (%s: the words searched)\n")
	for e in se.list {
		field_escape(&sb, e.id); strings.write_byte(&sb, '\t')
		field_escape(&sb, e.name); strings.write_byte(&sb, '\t')
		field_escape(&sb, e.keyword); strings.write_byte(&sb, '\t')
		field_escape(&sb, e.url); strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// Reads a file's text into `se` (replacing its list). False, and `se` untouched, when it is not such a file (another
// version, another file); malformed lines and a second engine with an id already seen are skipped.
engines_parse :: proc(se: ^Search_Engines, text: string) -> bool {
	rest := text
	first := true
	parsed := make([dynamic]Search_Engine, context.temp_allocator)
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if first {
			first = false
			if strings.trim_space(strings.trim_prefix(line, "\xEF\xBB\xBF")) != SEARCH_ENGINES_MAGIC { return false }
			continue
		}
		if strings.trim_space(line) == "" || line[0] == '#' { continue }
		parts := strings.split(line, "\t", context.temp_allocator)
		if len(parts) != 4 { continue }
		id, name := strings.trim_space(field_unescape(parts[0])), strings.trim_space(field_unescape(parts[1]))
		kw, url := strings.trim_space(field_unescape(parts[2])), strings.trim_space(field_unescape(parts[3]))
		if id == "" || name == "" || url == "" { continue }
		dup := false
		for p in parsed { if p.id == id { dup = true; break } }
		if dup { continue }
		append(&parsed, Search_Engine{id, name, kw, url})
	}
	if first { return false }
	engines_clear(se)
	for p in parsed { append(&se.list, engine_clone(p.id, p.name, p.keyword, p.url)) }
	return true
}

// The list of a profile without the file: the built-in engines, and the former custom address as an engine "Custom"
// when the profile used it (browser.search.engine = custom). True when that made an engine of its own (to be written).
engines_migrate :: proc(se: ^Search_Engines, legacy_engine: string, legacy_custom_url: string, has_custom_url: bool) -> bool {
	engines_builtin(se)
	if legacy_engine != "custom" { return false }
	url := has_custom_url && strings.trim_space(legacy_custom_url) != "" ? strings.trim_space(legacy_custom_url) : FALLBACK_ENGINE.url
	append(&se.list, engine_clone("custom", "Custom", "", url))
	se.serial += 1
	return true
}

engines_load_file :: proc(se: ^Search_Engines, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return false }
	return engines_parse(se, string(data))
}

engines_save_file :: proc(se: ^Search_Engines, path: string) -> bool {
	return blocker.write_file_atomic(path, transmute([]byte)engines_serialize(se))
}

////////////////////////////////
// The browser's list

sengines: Search_Engines

@(private = "file")
engines_path :: proc(app: ^App) -> string {
	if !app.cfg.persist_profile || app.profile_dir == "" { return "" }
	return strings.concatenate({app.profile_dir, "/", SEARCH_ENGINES_FILE}, context.temp_allocator)
}

// Start-up (interaction_init): the profile's list, or the built-in engines and what a former profile chose.
search_engines_init :: proc(app: ^App) {
	path := engines_path(app)
	if path != "" && engines_load_file(&sengines, path) { return }
	custom, has_custom := config.user_text(&app.prefs, "browser.search.custom_url")
	migrated := engines_migrate(&sengines, config.string_of(&app.prefs, "browser.search.engine"), custom, has_custom)
	// (a file that is there but not read, another version's, is left alone until the user changes the list)
	if migrated && path != "" && !os.exists(path) { search_engines_save(app) }
}

search_engines_destroy :: proc() { engines_destroy(&sengines) }

// After a change of the list: written to the profile; a default that is gone gives way to the first engine.
search_engines_changed :: proc(app: ^App) {
	search_engines_save(app)
	if len(sengines.list) > 0 && engines_find(&sengines, ix.search_engine) < 0 {
		_ = config.set_from_string(&app.prefs, "browser.search.engine", sengines.list[0].id, .User)
	}
	request_frames(app, 2)
}

search_engines_save :: proc(app: ^App) {
	if path := engines_path(app); path != "" { _ = engines_save_file(&sengines, path) }
}

search_set_default :: proc(app: ^App, i: int) {
	if i < 0 || i >= len(sengines.list) { return }
	_ = config.set_from_string(&app.prefs, "browser.search.engine", sengines.list[i].id, .User)
}

// Index of the default engine of the browser's list.
search_default_index :: proc() -> int { return engines_default(&sengines, ix.search_engine) }

// The address that searches `words`: with engine `engine` (an index of the list), or the default one (-1).
search_url :: proc(words: string, engine := -1) -> string {
	return engine_url(engine_at(&sengines, engine >= 0 ? engine : search_default_index()), words)
}

search_engine_name :: proc(engine := -1) -> string {
	return engine_at(&sengines, engine >= 0 ? engine : search_default_index()).name
}

@(private = "file")
percent_encode_query :: proc(s: string) -> string {
	HEX := "0123456789ABCDEF"
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&sb, c)
		case c == ' ': strings.write_byte(&sb, '+')
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 15])
		}
	}
	return strings.to_string(sb)
}
