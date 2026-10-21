package browser

// The command palette (Ctrl+Shift+P, Ctrl+K, Menu > Command palette): a field over the top of the window and the
// results of what is typed in it, as in VS Code. It searches, fuzzily, every source at once or one of them by prefix:
//
//     (nothing)  commands, open tabs, and the pluggable sources that take part in a plain search (history...)
//     >          commands of the registry (commands.odin): the keyboard shortcuts and the main menu run the same ones
//     @          open tabs, then recently closed ones
//     :          preferences (about:config): a boolean one toggles at once, the others open about:config on it
//     /          pages: the pluggable sources with that prefix (palette_add_source), the history of the open tabs
//
// Up / Down (wrapping), Page Up / Page Down move; Enter runs, Ctrl+Enter opens in a new tab what opens a page; Escape,
// the shortcut again or a press outside close it, and the keyboard goes back to what had it. The commands the user
// runs are remembered (count and time, in palette_usage.txt of the profile): with nothing typed they come first, and
// they rank higher among matches.
//
// Matching is fzf's kind of scoring: every character of each word of the query, in order, with bonuses for the start
// of the text and of its words (and camelCase humps), runs of consecutive characters and the same case, and a cost for
// the gaps; the best alignment is found by dynamic programming (fuzzy_score). Results are worked out again only when
// what they depend on changes (the query, the tabs, the preferences, the commands' states): an open palette at rest
// costs a caret blink, a closed one nothing.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"

PALETTE_PREFS := [?]config.Def{
	{name = "browser.palette.ctrl_k", kind = .Bool, default = {b = true},
		description = "Ctrl+K opens the command palette too (Ctrl+Shift+P always does). A page that handles Ctrl+K itself and cancels the key keeps it."},
	{name = "browser.palette.width_em", kind = .Float, default = {f = 40}, bounded = true, min = 20, max = 160, unit = "em",
		description = "Width of the command palette, in multiples of the interface's font size (never wider than the window)."},
	{name = "browser.palette.rows", kind = .Int, default = {i = 12}, bounded = true, min = 3, max = 60, unit = "rows",
		description = "Results the command palette shows at once (the list scrolls past them)."},
	{name = "browser.palette.max_results", kind = .Int, default = {i = 300}, bounded = true, min = 10, max = 100_000, unit = "results",
		description = "Most results the command palette lists, best first."},
	{name = "browser.palette.show_disabled", kind = .Bool, default = {b = true},
		description = "List the commands that cannot run right now (Back without history...), greyed after the others. Off: they are left out."},
	{name = "browser.palette.remember", kind = .Bool, default = {b = true},
		description = "Remember which commands and preferences are chosen in the command palette, and how recently, to list them first (kept in palette_usage.txt of the profile when browser.profile.persist is on)."},
	{name = "browser.palette.usage_max_entries", kind = .Int, default = {i = 500}, bounded = true, min = 10, max = 100_000, unit = "entries",
		description = "Most choices the command palette remembers (the least used and oldest are forgotten first)."},
	{name = "browser.palette.usage_half_life_days", kind = .Float, default = {f = 14}, bounded = true, min = 0.1, max = 3650, unit = "days",
		description = "How fast a remembered choice counts less: its weight halves every this many days without being chosen again."},
	{name = "browser.palette.open_ms", kind = .Int, default = {i = 110}, bounded = true, min = 0, max = 1000, unit = "ms",
		description = "Duration of the command palette's opening (a short fade and slide; 0 = none, and none when Windows turns animations off)."},
	{name = "browser.palette.source_max_items", kind = .Int, default = {i = 5000}, bounded = true, min = 0, max = 1_000_000, unit = "items",
		description = "Most items the command palette takes from each source of pages (history...) for one search."},
}

register_palette_prefs :: proc(p: ^config.Prefs) { config.register(p, PALETTE_PREFS[:]) }

Palette_Settings :: struct {
	ctrl_k:          bool,
	width_em:        f32,
	rows:            int,
	max_results:     int,
	show_disabled:   bool,
	remember:        bool,
	usage_max:       int,
	half_life_days:  f64,
	open_ms:         f64,
	source_max:      int,
}

palette_settings_from_prefs :: proc(p: ^config.Prefs) -> Palette_Settings {
	return {
		ctrl_k = config.bool_of(p, "browser.palette.ctrl_k"),
		width_em = f32(config.float_of(p, "browser.palette.width_em")),
		rows = int(config.int_of(p, "browser.palette.rows")),
		max_results = int(config.int_of(p, "browser.palette.max_results")),
		show_disabled = config.bool_of(p, "browser.palette.show_disabled"),
		remember = config.bool_of(p, "browser.palette.remember"),
		usage_max = int(config.int_of(p, "browser.palette.usage_max_entries")),
		half_life_days = config.float_of(p, "browser.palette.usage_half_life_days"),
		open_ms = f64(config.int_of(p, "browser.palette.open_ms")),
		source_max = int(config.int_of(p, "browser.palette.source_max_items")),
	}
}

////////////////////////////////
// Fuzzy matching (pure: palette_test.odin)

FUZZY_MATCH            :: 16
FUZZY_GAP_START        :: -3
FUZZY_GAP_EXTENSION    :: -1
FUZZY_BONUS_START      :: 10   // start of the text
FUZZY_BONUS_BOUNDARY   :: 8    // start of a word
FUZZY_BONUS_CAMEL      :: 7    // a capital after a small letter, a digit after a letter
FUZZY_BONUS_CONSECUTIVE :: 5
FUZZY_FIRST_MULTIPLIER :: 2    // the query's first character counts its bonus twice
FUZZY_BONUS_CASE       :: 1    // same case as typed (only when the word typed has a capital: smart case)
FUZZY_MAX_TEXT         :: 512  // characters of a text that take part (the rest of a longer one is not searched)
FUZZY_MAX_WORD         :: 64

@(private = "file")
NEG :: min(i32) / 2

@(private = "file")
Char_Class :: enum u8 { Other, Lower, Upper, Letter, Digit }   // (Letter: without case)

@(private = "file")
char_class :: proc(r: rune) -> Char_Class {
	if r < 0x80 {
		switch r {
		case 'a' ..= 'z': return .Lower
		case 'A' ..= 'Z': return .Upper
		case '0' ..= '9': return .Digit
		}
		return .Other
	}
	switch {
	case unicode.is_upper(r): return .Upper
	case unicode.is_lower(r): return .Lower
	case unicode.is_letter(r): return .Letter
	case unicode.is_digit(r): return .Digit
	}
	return .Other
}

@(private = "file")
fold :: proc(r: rune) -> rune {
	if r < 0x80 { return r >= 'A' && r <= 'Z' ? r + 32 : r }
	return unicode.to_lower(r)
}

Fuzzy_Word :: struct {
	q, low: []rune,   // as typed, lower case
	smart:  bool,     // it has a capital: the case counts
}

// A query read once for every text it is matched against: its space-separated words.
Fuzzy_Query :: struct { words: []Fuzzy_Word }

fuzzy_query_make :: proc(text: string, allocator := context.temp_allocator) -> Fuzzy_Query {
	fields := strings.fields(text, context.temp_allocator)
	words := make([]Fuzzy_Word, len(fields), allocator)
	for f, wi in fields {
		n := min(strings.rune_count(f), FUZZY_MAX_WORD)
		w := Fuzzy_Word{q = make([]rune, n, allocator), low = make([]rune, n, allocator)}
		i := 0
		for r in f {
			if i >= n { break }
			w.q[i], w.low[i] = r, fold(r)
			if unicode.is_upper(r) { w.smart = true }
			i += 1
		}
		words[wi] = w
	}
	return {words}
}

// Buffers of the matcher, kept from one text to the next (a search goes through thousands).
Fuzzy_Scratch :: struct {
	hr, low:   [dynamic]rune,
	off:       [dynamic]int,
	bonus:     [dynamic]i32,
	rows:      [dynamic]i32,   // two rows of scores and two of run bonuses
	from:      [dynamic]i16,   // where the previous query character was (-1: none), per query character and position
	part:      [dynamic]ui.Fuzzy_Range,
}

fuzzy_scratch_destroy :: proc(s: ^Fuzzy_Scratch) {
	delete(s.hr); delete(s.low); delete(s.off); delete(s.bonus); delete(s.rows); delete(s.from); delete(s.part)
	s^ = {}
}

// Is `w` a subsequence of `hay` at all (case-insensitively)? The cheap test that rejects most texts.
@(private = "file")
fuzzy_subsequence :: proc(w: ^Fuzzy_Word, hay: string) -> bool #no_bounds_check {
	i := 0
	n := len(w.low)
	if n == 0 { return true }
	for b := 0; b < len(hay); {
		c := hay[b]
		r: rune
		if c < 0x80 { r = c >= 'A' && c <= 'Z' ? rune(c) + 32 : rune(c); b += 1 } else {
			rr, size := utf8.decode_rune_in_string(hay[b:])
			r = fold(rr)
			b += size
		}
		if r == w.low[i] { i += 1; if i == n { return true } }
	}
	return false
}

// `low` (lower case) occurs in `hay`, case aside.
contains_fold :: proc(hay: string, low: []rune) -> bool {
	if len(low) == 0 { return true }
	next_rune :: proc(s: string, b: int) -> (rune, int) {
		c := s[b]
		if c < 0x80 { return fold(rune(c)), 1 }
		r, n := utf8.decode_rune_in_string(s[b:])
		return fold(r), n
	}
	for start := 0; start < len(hay); {
		r0, n0 := next_rune(hay, start)
		if r0 == low[0] {
			b := start + n0
			k := 1
			for k < len(low) && b < len(hay) {
				r, n := next_rune(hay, b)
				if r != low[k] { break }
				b += n
				k += 1
			}
			if k == len(low) { return true }
		}
		start += n0
	}
	return false
}

// Score of `fq` in `hay`: every word must match, their best alignments' scores add up; the matched characters' byte
// ranges (sorted, merged) are appended to `out`. An empty query matches with score 0.
fuzzy_match :: proc(fq: ^Fuzzy_Query, hay: string, s: ^Fuzzy_Scratch, out: ^[dynamic]ui.Fuzzy_Range) -> (score: int, ok: bool) #no_bounds_check {
	if len(fq.words) == 0 { return 0, true }
	for &w in fq.words { if !fuzzy_subsequence(&w, hay) { return 0, false } }
	// the text, once: characters, their lower case, byte offsets, and the bonus of a match at each
	cap_runes := min(len(hay), FUZZY_MAX_TEXT)   // (a byte at least per character)
	resize(&s.hr, cap_runes); resize(&s.low, cap_runes); resize(&s.bonus, cap_runes); resize(&s.off, cap_runes + 1)
	m := 0
	end_byte := len(hay)
	prev := Char_Class.Other
	for b := 0; b < len(hay); {
		if m >= FUZZY_MAX_TEXT { end_byte = b; break }
		r := rune(hay[b])
		size := 1
		if r >= 0x80 { r, size = utf8.decode_rune_in_string(hay[b:]) }
		cur := char_class(r)
		bonus: i32
		switch {
		case cur == .Other:
		case m == 0: bonus = FUZZY_BONUS_START
		case prev == .Other: bonus = FUZZY_BONUS_BOUNDARY
		case cur == .Upper && prev == .Lower: bonus = FUZZY_BONUS_CAMEL
		case cur == .Digit && prev != .Digit: bonus = FUZZY_BONUS_CAMEL
		}
		s.hr[m], s.low[m], s.off[m], s.bonus[m] = r, fold(r), b, bonus
		prev = cur
		m += 1
		b += size
	}
	s.off[m] = end_byte
	clear(&s.part)
	for &w in fq.words {
		ws, wok := fuzzy_word(&w, m, s)
		if !wok { return 0, false }
		score += ws
	}
	// several words: their ranges sorted and merged
	if len(fq.words) > 1 { slice.sort_by(s.part[:], proc(a, b: ui.Fuzzy_Range) -> bool { return a[0] < b[0] }) }
	first := len(out)
	for r in s.part {
		if len(out) > first && r[0] <= out[len(out) - 1][1] { out[len(out) - 1][1] = max(out[len(out) - 1][1], r[1]) } else { append(out, r) }
	}
	return score, true
}

// The best alignment of one word in the prepared text (dynamic programming, like fzf's): its score, its characters'
// ranges appended to s.part.
@(private = "file")
fuzzy_word :: proc(w: ^Fuzzy_Word, m: int, s: ^Fuzzy_Scratch) -> (score: int, ok: bool) #no_bounds_check {
	n := len(w.q)
	if n == 0 { return 0, true }
	if m < n { return 0, false }
	resize(&s.rows, 4 * m)
	resize(&s.from, n * m)
	prev_h, cur_h := s.rows[0:m], s.rows[m:2 * m]
	prev_c, cur_c := s.rows[2 * m:3 * m], s.rows[3 * m:4 * m]
	// nothing matches before the first occurrence of the first character or after the last one of the last
	lo, hi := 0, m - 1
	for lo < m && s.low[lo] != w.low[0] { lo += 1 }
	for hi >= 0 && s.low[hi] != w.low[n - 1] { hi -= 1 }
	if lo >= m || hi < 0 || lo + n - 1 > hi { return 0, false }
	for j in 0 ..< m { prev_h[j], cur_h[j] = NEG, NEG }
	for i in 0 ..< n {
		for j in lo ..< lo + i { cur_h[j] = NEG }   // (left of this row's cells: two rows ago's values)
		best_gap: i32 = NEG
		best_k: i32 = -1
		qc, ql := w.q[i], w.low[i]
		case_letter := w.smart && unicode.is_letter(qc)
		for j in lo + i ..= hi {
			if i > 0 && j >= 2 {
				// best predecessor at least one character back, gaps charged
				ext := best_gap == NEG ? NEG : best_gap + FUZZY_GAP_EXTENSION
				cand := prev_h[j - 2]
				if cand != NEG { cand += FUZZY_GAP_START }
				if cand != NEG && cand >= ext { best_gap, best_k = cand, i32(j - 2) } else { best_gap = ext }
			}
			cur_h[j] = NEG
			s.from[i * m + j] = -1
			if s.low[j] != ql { continue }
			bj := s.bonus[j]
			case_bonus: i32 = case_letter && qc == s.hr[j] ? FUZZY_BONUS_CASE : 0
			if i == 0 {
				cur_h[j] = FUZZY_MATCH + bj * FUZZY_FIRST_MULTIPLIER + case_bonus
				cur_c[j] = bj
				continue
			}
			s1, s2: i32 = NEG, NEG
			c1: i32
			if j >= 1 && prev_h[j - 1] != NEG {
				c1 = max(prev_c[j - 1], FUZZY_BONUS_CONSECUTIVE, bj)
				s1 = prev_h[j - 1] + FUZZY_MATCH + c1 + case_bonus
			}
			if best_gap != NEG { s2 = best_gap + FUZZY_MATCH + bj + case_bonus }
			if s1 == NEG && s2 == NEG { continue }
			if s1 >= s2 {
				cur_h[j], cur_c[j], s.from[i * m + j] = s1, c1, i16(j - 1)
			} else {
				cur_h[j], cur_c[j], s.from[i * m + j] = s2, bj, i16(best_k)
			}
		}
		prev_h, cur_h = cur_h, prev_h
		prev_c, cur_c = cur_c, prev_c
	}
	best: i32 = NEG
	end := -1
	for j in lo + n - 1 ..= hi { if prev_h[j] > best { best, end = prev_h[j], j } }
	if end < 0 { return 0, false }
	// back to the matched characters (last to first), as byte ranges with runs merged
	start := len(s.part)
	j := end
	for i := n - 1; i >= 0 && j >= 0; i -= 1 {
		a, b := s.off[j], s.off[j + 1]
		if len(s.part) > start && s.part[len(s.part) - 1][0] == b { s.part[len(s.part) - 1][0] = a } else { append(&s.part, ui.Fuzzy_Range{a, b}) }
		j = int(s.from[i * m + j])
	}
	slice.reverse(s.part[start:])
	return int(best), true
}

// fuzzy_match for one query and one text (the ranges allocated with `allocator`).
fuzzy_score :: proc(query, hay: string, allocator := context.temp_allocator) -> (score: int, ranges: []ui.Fuzzy_Range, ok: bool) {
	fq := fuzzy_query_make(query)
	if len(fq.words) == 0 { return 0, nil, true }
	s: Fuzzy_Scratch
	defer fuzzy_scratch_destroy(&s)
	out := make([dynamic]ui.Fuzzy_Range, allocator)
	score, ok = fuzzy_match(&fq, hay, &s, &out)
	if !ok { delete(out); return 0, nil, false }
	return score, out[:], true
}

////////////////////////////////
// What was chosen, and when (pure parts: palette_test.odin)

PALETTE_USAGE_HEADER :: "wren-palette-usage 1"

Usage_Entry :: struct { count: int, last_ms: i64 }

Palette_Usage :: struct {
	entries: map[string]Usage_Entry,   // owned keys: "cmd:tab.new", "pref:browser.ui.theme"
	loaded:  bool,
	version: u64,
}

usage_destroy :: proc(u: ^Palette_Usage) {
	for k in u.entries { delete(k) }
	delete(u.entries)
	u^ = {}
}

// Weight of an entry: its count, halved every `half_life_days` since it was last chosen.
usage_weight :: proc(e: Usage_Entry, now_ms: i64, half_life_days: f64) -> f64 {
	if e.count <= 0 { return 0 }
	age_days := max(f64(now_ms - e.last_ms), 0) / 86_400_000
	return f64(e.count) * math.pow(0.5, age_days / max(half_life_days, 1e-3))
}

usage_record :: proc(u: ^Palette_Usage, key: string, now_ms: i64, max_entries: int, half_life_days: f64) {
	if e, ok := &u.entries[key]; ok {
		e.count += 1
		e.last_ms = now_ms
	} else {
		u.entries[strings.clone(key)] = {1, now_ms}
	}
	// over the limit: the lightest go (the one just chosen is never the lightest... unless all weigh the same: then the
	// oldest goes first)
	for len(u.entries) > max(max_entries, 1) {
		victim := ""
		vw := max(f64)
		vt := max(i64)
		for k, e in u.entries {
			if k == key { continue }
			w := usage_weight(e, now_ms, half_life_days)
			if w < vw || (w == vw && e.last_ms < vt) { victim, vw, vt = k, w, e.last_ms }
		}
		if victim == "" { break }
		k, _ := delete_key(&u.entries, victim)
		delete(k)
	}
	u.version += 1
}

usage_serialize :: proc(u: ^Palette_Usage, allocator := context.temp_allocator) -> string {
	keys := make([dynamic]string, 0, len(u.entries), context.temp_allocator)
	for k in u.entries { append(&keys, k) }
	slice.sort(keys[:])   // a stable file: written only when it changes
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, PALETTE_USAGE_HEADER)
	strings.write_byte(&sb, '\n')
	for k in keys {
		e := u.entries[k]
		fmt.sbprintf(&sb, "%d\t%d\t%s\n", e.count, e.last_ms, k)
	}
	return strings.to_string(sb)
}

// Reads a usage file into `u` (forgiving: malformed lines are skipped; not a usage file: nothing). False when it is not one.
usage_parse :: proc(u: ^Palette_Usage, text: string, max_entries: int) -> bool {
	rest := text
	first := true
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if first {
			first = false
			if strings.trim_space(line) != PALETTE_USAGE_HEADER { return false }
			continue
		}
		if len(u.entries) >= max_entries { break }
		parts := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(parts) != 3 || parts[2] == "" || strings.contains_any(parts[2], "\x00") { continue }
		count, cok := strconv.parse_int(parts[0])
		last, lok := strconv.parse_i64(parts[1])
		if !cok || !lok || count <= 0 { continue }
		if parts[2] in u.entries { continue }
		u.entries[strings.clone(parts[2])] = {count, last}
	}
	return !first
}

@(private = "file")
now_unix_ms :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1e6 }

@(private = "file")
usage_path :: proc(app: ^App) -> string { return strings.concatenate({app.profile_dir, "/palette_usage.txt"}, context.temp_allocator) }

@(private = "file")
usage_load :: proc(app: ^App) {
	u := &cpal.usage
	if u.loaded { return }
	u.loaded = true
	if !app.cfg.persist_profile { return }
	data, err := os.read_entire_file(usage_path(app), context.temp_allocator)
	if err != nil { return }
	_ = usage_parse(u, string(data), cpal.cfg.usage_max)
}

// Written as soon as it changes (a few hundred bytes), to a temporary file then moved over the old one.
@(private = "file")
usage_save :: proc(app: ^App) {
	if !app.cfg.persist_profile { return }
	path := usage_path(app)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)usage_serialize(&cpal.usage)) != nil { return }
	win.MoveFileExW(win.utf8_to_wstring(tmp, context.temp_allocator), win.utf8_to_wstring(path, context.temp_allocator), win.MOVEFILE_REPLACE_EXISTING)
}

@(private = "file")
usage_note :: proc(app: ^App, key: string) {
	if !cpal.cfg.remember { return }
	usage_load(app)
	usage_record(&cpal.usage, key, now_unix_ms(), cpal.cfg.usage_max, cpal.cfg.half_life_days)
	usage_save(app)
}

@(private = "file")
usage_of :: proc(key: string, now_ms: i64) -> f64 {
	if !cpal.cfg.remember { return 0 }
	e, ok := cpal.usage.entries[key]
	return ok ? usage_weight(e, now_ms, cpal.cfg.half_life_days) : 0
}

////////////////////////////////
// Sources of pages (history, bookmarks...): plugged in by whoever has them

// One page a source offers. The strings need only last until `items` returns (the palette copies what it keeps).
Palette_Item :: struct {
	title:  string,
	detail: string,   // shown weak after the title (its address)
	key:    string,   // given back to `activate`
	glyph:  string,
}

Palette_Source :: struct {
	name:       string,   // the rows' category ("History", "Bookmarks"); unique
	prefix:     u8,       // the query prefix that searches it alone ('/' for pages; 0: none)
	in_default: bool,     // it takes part in a search without prefix (once something is typed)
	items:      proc(user: rawptr, app: ^App, out: ^[dynamic]Palette_Item),
	activate:   proc(user: rawptr, app: ^App, key: string, new_tab: bool),
	version:    proc(user: rawptr, app: ^App) -> u64,   // changes when its items do (nil: they are read for every search)
	user:       rawptr,
}

// Adds (or replaces, by name) a source. The name must outlive the palette (a literal).
palette_add_source :: proc(s: Palette_Source) {
	for &x in cpal.sources { if x.name == s.name { x = s; cpal.cache_valid = false; return } }
	append(&cpal.sources, s)
	cpal.cache_valid = false
}

palette_remove_source :: proc(name: string) {
	for x, i in cpal.sources { if x.name == name { ordered_remove(&cpal.sources, i); cpal.cache_valid = false; return } }
}

// The built-in source of pages: what the open tabs visited (each tab's session history).
@(private = "file")
tab_history_items :: proc(user: rawptr, app: ^App, out: ^[dynamic]Palette_Item) {
	seen := make(map[string]bool, 64, context.temp_allocator)
	for t in app.tabs {
		for i := len(t.history) - 1; i >= 0; i -= 1 {
			u := t.history[i]
			if u == "" || u in seen { continue }
			seen[u] = true
			append(out, Palette_Item{title = default_tab_title(u), detail = u, key = u})
		}
	}
}

@(private = "file")
tab_history_activate :: proc(user: rawptr, app: ^App, key: string, new_tab: bool) {
	t := current_tab(app)
	if new_tab || t == nil { open_in_new_tab(app, key) } else { navigate(app, t, strings.clone(key, context.temp_allocator)) }
}

@(private = "file")
tab_history_version :: proc(user: rawptr, app: ^App) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for t in app.tabs { h = (h ~ t.id) * 0x100000001b3; h = (h ~ u64(len(t.history))) * 0x100000001b3; h = (h ~ u64(t.hist)) * 0x100000001b3 }
	return h
}

////////////////////////////////
// Results

Palette_Mode :: enum u8 { All, Commands, Tabs, Prefs, Source }

// What the query asks for: its prefix's mode (Source: `prefix`, the character) and the words after it.
palette_parse_query :: proc(text: string) -> (mode: Palette_Mode, prefix: u8, query: string) {
	s := strings.trim_left_space(text)
	if len(s) == 0 { return .All, 0, "" }
	switch s[0] {
	case '>': return .Commands, 0, strings.trim_space(s[1:])
	case '@': return .Tabs, 0, strings.trim_space(s[1:])
	case ':': return .Prefs, 0, strings.trim_space(s[1:])
	case '/', '#', '!', '*', '%', '&', '$', '~', '^':
		for src in cpal.sources { if src.prefix == s[0] { return .Source, s[0], strings.trim_space(s[1:]) } }
	}
	return .All, 0, strings.trim_space(s)
}

Palette_Kind :: enum u8 { Command, Tab, Closed_Tab, Pref, Source }

Palette_Row :: struct {
	kind:     Palette_Kind,
	index:    int,            // command index, source index, closed tab index
	tab_id:   u64,
	ref:      config.Ref,
	key:      string,         // a source item's key, a closed tab's address
	title:    string,
	detail:   string,
	category: string,
	glyph:    string,
	score:    int,
	usage:    f64,
	order:    int,
	disabled: bool,
	ranges:   []ui.Fuzzy_Range,
	range_lo, range_hi: int,  // (while collecting: its ranges in cpal.pool)
}

Palette_State :: struct {
	open:          bool,
	field:         ui.Text_Field,
	opened:        time.Tick,
	focus_pending: bool,
	saved_focus:   ui.Key,
	sel, first:    int,
	scroll_acc:    f32,
	rows:          [dynamic]Palette_Row,
	arena:         virtual.Arena,   // the rows' strings and ranges
	arena_ready:   bool,
	pool:          [dynamic]ui.Fuzzy_Range,   // the candidates' highlighted ranges, while collecting
	scratch:       Fuzzy_Scratch,
	cache_text:    string,          // owned: the query the rows are for
	cache_key:     u64,
	cache_valid:   bool,
	last_mouse:    [2]f32,
	cfg:           Palette_Settings,
	cfg_version:   u64,
	cfg_ready:     bool,
	usage:         Palette_Usage,
	sources:       [dynamic]Palette_Source,
	sources_ready: bool,
}

cpal: Palette_State

palette_open :: proc() -> bool { return cpal.open }

palette_destroy :: proc() {
	ui.field_destroy(&cpal.field)
	delete(cpal.rows)
	delete(cpal.pool)
	fuzzy_scratch_destroy(&cpal.scratch)
	if cpal.arena_ready { virtual.arena_destroy(&cpal.arena) }
	delete(cpal.cache_text)
	usage_destroy(&cpal.usage)
	delete(cpal.sources)
	cpal = {}
	commands_destroy(&cmds)
}

@(private = "file")
palette_ready :: proc(app: ^App) {
	if !cpal.cfg_ready || cpal.cfg_version != app.prefs.version {
		cpal.cfg = palette_settings_from_prefs(&app.prefs)
		cpal.cfg_version, cpal.cfg_ready = app.prefs.version, true
	}
	if !cpal.arena_ready { _ = virtual.arena_init_growing(&cpal.arena); cpal.arena_ready = true }
	if !cpal.sources_ready {
		cpal.sources_ready = true
		palette_add_source({name = "Visited", prefix = '/', in_default = true, items = tab_history_items, activate = tab_history_activate, version = tab_history_version})
	}
}

palette_toggle :: proc(app: ^App) {
	if cpal.open { palette_close(app) } else { palette_show(app) }
}

// Opens the palette (with `text` typed, a prefix for instance).
palette_show :: proc(app: ^App, text := "") {
	palette_ready(app)
	usage_load(app)
	ui.ctx_menu_close()
	cpal.open = true
	ui.field_set(&cpal.field, text)
	cpal.sel, cpal.first, cpal.scroll_acc = 0, 0, 0
	cpal.cache_valid = false
	cpal.saved_focus = ui.focus_key()
	cpal.focus_pending = true
	cpal.opened = time.tick_now()
	cpal.last_mouse = ui.mouse_pos()
	app.frames_requested = max(app.frames_requested, 3)
}

// Closes it; the keyboard goes back to what had it (when that is still there).
palette_close :: proc(app: ^App) {
	if !cpal.open { return }
	cpal.open = false
	k := cpal.saved_focus
	ui.set_focus(k != 0 && ui.box_from_key(k) != nil ? k : 0)
	clear(&cpal.rows)
	cpal.cache_valid = false
	app.frames_requested = max(app.frames_requested, 2)
}

// While it is open the palette takes every press and wheel turn: the page under it gets none (hud_captures).
palette_captures :: proc(pos: draw.Vec2) -> bool { return cpal.open }

@(private = "file")
fnv :: proc(h: u64, s: string) -> u64 {
	h := h
	for c in transmute([]u8)s { h = (h ~ u64(c)) * 0x100000001b3 }
	return h
}

@(private = "file")
mix :: proc(h, v: u64) -> u64 { return (h ~ v) * 0x100000001b3 }

// What the rows depend on besides the query: when it is the same, last frame's rows are still right.
@(private = "file")
results_key :: proc(app: ^App) -> u64 {
	h: u64 = 0xcbf29ce484222325
	h = mix(h, app.prefs.version)
	h = mix(h, u64(app.current))
	h = mix(h, cpal.usage.version)
	h = mix(h, u64(len(closed_tabs)))
	for t in app.tabs { h = mix(h, t.id); h = fnv(h, t.title); h = fnv(h, t.url) }
	t := current_tab(app)
	for &c, i in commands() { if command_enabled(app, t, &c) { h = mix(h, u64(i) + 1) } }
	for s in cpal.sources { h = fnv(h, s.name); if s.version != nil { h = mix(h, s.version(s.user, app)) } else { h = mix(h, u64(ui.now_ms())) } }
	return h
}

// The rows for `text` (in cpal.rows, best first). Pure apart from the registry, the usage memory and the sources.
// The candidates keep the strings they come with (the frame's); only the rows kept are copied, into the palette's arena.
palette_collect :: proc(app: ^App, text: string) {
	palette_ready(app)
	virtual.arena_free_all(&cpal.arena)
	clear(&cpal.rows)
	clear(&cpal.pool)
	mode, prefix, q := palette_parse_query(text)
	fq := fuzzy_query_make(q)
	now := now_unix_ms()
	t := current_tab(app)
	order := 0
	push :: proc(row: Palette_Row, order: ^int) {
		r := row
		r.order = order^
		order^ += 1
		append(&cpal.rows, r)
	}
	// match on the title (highlighted), else on the other words it is known by, for less
	match :: proc(fq: ^Fuzzy_Query, title, other: string) -> (score: int, lo, hi: int, ok: bool) {
		if len(fq.words) == 0 { return 0, 0, 0, true }
		lo = len(cpal.pool)
		score, ok = fuzzy_match(fq, title, &cpal.scratch, &cpal.pool)
		if ok || other == "" { return score, lo, len(cpal.pool), ok }
		// (strictly: each word typed as it is written there, else a long description matches almost anything)
		for &w in fq.words { if !contains_fold(other, w.low) { return 0, 0, 0, false } }
		s, ook := fuzzy_match(fq, other, &cpal.scratch, &cpal.pool)
		resize(&cpal.pool, lo)   // (nothing of it is highlighted)
		return s / 2, lo, lo, ook
	}

	if mode == .All || mode == .Commands {
		for &c, i in commands() {
			if c.hidden { continue }
			enabled := command_enabled(app, t, &c)
			if !enabled && !cpal.cfg.show_disabled { continue }
			s, lo, hi, ok := match(&fq, c.title, strings.concatenate({c.category, " ", c.keywords, " ", c.name}, context.temp_allocator))
			if !ok { continue }
			push({kind = .Command, index = i, title = c.title, category = c.category, glyph = c.glyph, score = s, range_lo = lo, range_hi = hi,
				usage = usage_of(strings.concatenate({"cmd:", c.name}, context.temp_allocator), now), disabled = !enabled}, &order)
		}
	}
	if mode == .All || mode == .Tabs {
		for tab in app.tabs {
			s, lo, hi, ok := match(&fq, tab.title, tab.url)
			if !ok { continue }
			push({kind = .Tab, tab_id = tab.id, title = tab.title, detail = tab.url, category = "Tab", score = s, range_lo = lo, range_hi = hi}, &order)
		}
	}
	if mode == .Tabs || (mode == .All && q != "") {
		for i := len(closed_tabs) - 1; i >= 0; i -= 1 {
			u := closed_tabs[i]
			title := default_tab_title(u)
			s, lo, hi, ok := match(&fq, title, u)
			if !ok { continue }
			push({kind = .Closed_Tab, index = i, key = u, title = title, detail = u, category = "Closed tab", score = s, range_lo = lo, range_hi = hi}, &order)
		}
	}
	if mode == .Prefs {
		for name in config.sorted_names(&app.prefs) {
			r := config.ref_of(&app.prefs, name)
			e := config.entry(&app.prefs, r)
			s, lo, hi, ok := match(&fq, name, e.def.description)
			if !ok { continue }
			push({kind = .Pref, ref = r, title = name, category = "Setting", score = s, range_lo = lo, range_hi = hi,
				usage = usage_of(strings.concatenate({"pref:", name}, context.temp_allocator), now), disabled = e.locked}, &order)
		}
	}
	if mode == .Source || (mode == .All && q != "") {
		for src, si in cpal.sources {
			if mode == .Source ? src.prefix != prefix : !src.in_default { continue }
			if src.items == nil { continue }
			items := make([dynamic]Palette_Item, context.temp_allocator)
			src.items(src.user, app, &items)
			for it, n in items {
				if n >= cpal.cfg.source_max { break }
				s, lo, hi, ok := match(&fq, it.title, it.detail)
				if !ok { continue }
				push({kind = .Source, index = si, key = it.key, title = it.title, detail = it.detail,
					category = src.name, glyph = it.glyph, score = s - 4, range_lo = lo, range_hi = hi}, &order)   // (pages after commands and tabs that match as well)
			}
		}
	}

	// ranked on small keys (thousands of candidates from a source of pages: the rows are moved once, the kept ones)
	Rank :: struct { disabled: bool, score: int, usage: f64, title_len, order, index: int }
	ranks := make([]Rank, len(cpal.rows), context.temp_allocator)
	for &r, i in cpal.rows {
		// the score, raised a little by use (bounded: a good match still beats a frequent poor one)
		if q != "" { r.score += int(min(r.usage * 6, 30)) }
		ranks[i] = {r.disabled, r.score, r.usage, len(r.title), r.order, i}
	}
	if q != "" {
		slice.sort_by(ranks, proc(x, y: Rank) -> bool {
			if x.disabled != y.disabled { return !x.disabled }
			if x.score != y.score { return x.score > y.score }
			if x.title_len != y.title_len { return x.title_len < y.title_len }
			return x.order < y.order
		})
	} else {
		// nothing typed: what was used, most first, then the registry's (or the tabs') order
		slice.sort_by(ranks, proc(x, y: Rank) -> bool {
			if x.disabled != y.disabled { return !x.disabled }
			if x.usage != y.usage { return x.usage > y.usage }
			return x.order < y.order
		})
	}
	kept := min(len(ranks), cpal.cfg.max_results)
	sorted := make([]Palette_Row, kept, context.temp_allocator)
	for k in 0 ..< kept { sorted[k] = cpal.rows[ranks[k].index] }
	clear(&cpal.rows)
	append(&cpal.rows, ..sorted)
	// what is kept outlives the frame
	a := virtual.arena_allocator(&cpal.arena)
	for &r in cpal.rows {
		r.title = strings.clone(r.title, a)
		r.detail = strings.clone(r.detail, a)
		r.key = strings.clone(r.key, a)
		r.glyph = strings.clone(r.glyph, a)
		if r.range_hi > r.range_lo {
			r.ranges = make([]ui.Fuzzy_Range, r.range_hi - r.range_lo, a)
			copy(r.ranges, cpal.pool[r.range_lo:r.range_hi])
		}
	}
}

@(private = "file")
row_usable :: proc(i: int) -> bool { return i >= 0 && i < len(cpal.rows) && !cpal.rows[i].disabled }

// The next usable row from `from` by `dir` (±1 wraps; a page stops at the ends).
@(private = "file")
palette_step :: proc(dir: int, page := false) {
	n := len(cpal.rows)
	if n == 0 { return }
	if !page {
		i := cpal.sel
		for _ in 0 ..< n {
			i = (i + dir + n) %% n
			if row_usable(i) { cpal.sel = i; return }
		}
		return
	}
	target := clamp(cpal.sel + dir, 0, n - 1)
	for i := target; i >= 0 && i < n; i += dir > 0 ? 1 : -1 { if row_usable(i) { cpal.sel = i; return } }
	for i := target; i >= 0 && i < n; i -= dir > 0 ? 1 : -1 { if row_usable(i) { cpal.sel = i; return } }
}

@(private = "file")
first_usable :: proc() -> int {
	for i in 0 ..< len(cpal.rows) { if row_usable(i) { return i } }
	return 0
}

// Runs row `i`. `new_tab`: what opens a page opens it in a new tab.
palette_execute :: proc(app: ^App, i: int, new_tab: bool) {
	if !row_usable(i) { return }
	r := cpal.rows[i]
	t := current_tab(app)
	switch r.kind {
	case .Command:
		c := &commands()[r.index]
		if !command_enabled(app, t, c) { return }
		key := strings.concatenate({"cmd:", c.name}, context.temp_allocator)
		palette_close(app)
		usage_note(app, key)
		if new_tab && c.url != "" { open_in_new_tab(app, c.url) } else { command_run(app, current_tab(app), c) }
	case .Tab:
		palette_close(app)
		for x, k in app.tabs { if x.id == r.tab_id { tab_select(app, k); break } }
	case .Closed_Tab:
		address := strings.clone(r.key, context.temp_allocator)
		palette_close(app)
		for k := len(closed_tabs) - 1; k >= 0; k -= 1 {
			if closed_tabs[k] == address { delete(closed_tabs[k]); ordered_remove(&closed_tabs, k); break }
		}
		open_in_new_tab(app, address)
	case .Pref:
		e := config.entry(&app.prefs, r.ref)
		name := strings.clone(e.def.name, context.temp_allocator)
		usage_note(app, strings.concatenate({"pref:", name}, context.temp_allocator))
		if e.def.kind == .Bool && !new_tab {
			// toggled in place: the palette stays, showing the new value
			set_pref_bool(app, name, !e.value.b)
			cpal.cache_valid = false
			return
		}
		palette_close(app)
		dest := t
		if new_tab || dest == nil { dest = tab_open(app, "about:config") } else { navigate(app, dest, "about:config") }
		ui.field_set(&app.config_view.search, name)
		app.config_view.focus_list = true
	case .Source:
		if r.index < 0 || r.index >= len(cpal.sources) { return }
		src := cpal.sources[r.index]
		key := strings.clone(r.key, context.temp_allocator)
		palette_close(app)
		if src.activate != nil { src.activate(src.user, app, key, new_tab) }
	}
	app.frames_requested = max(app.frames_requested, 2)
}

////////////////////////////////
// Building

PALETTE_PLACEHOLDER :: "Search commands, tabs and pages   (> commands  @ tabs  : settings  / pages)"

@(private = "file")
Thumb_Draw :: struct { first, visible, total: int, color: draw.Color }

@(private = "file")
thumb_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Thumb_Draw)(user)
	if d.total <= d.visible { return }
	r := b.rect
	h := r.max.y - r.min.y
	w := max(math.round(3 * ui.scale()), 2)
	th := max(h * f32(d.visible) / f32(d.total), w * 4)
	y := r.min.y + (h - th) * f32(d.first) / f32(max(d.total - d.visible, 1))
	x := r.max.x - w - max(math.round(2 * ui.scale()), 1)
	draw.rect(dc, {{x, y}, {x + w, y + th}}, d.color, w * 0.5)
}

// The id text of a label: what is shown, kept clear of the toolkit's "###" (the rest of the id).
@(private = "file")
label_id :: proc(text, suffix: string) -> string {
	s := text
	if strings.contains(s, "###") { s, _ = strings.replace_all(s, "###", "# # #", context.temp_allocator) }
	return fmt.aprintf("%s###%s", s, suffix, allocator = ui.frame_allocator())
}

// Builds the palette over the window (after the chrome, the page and the menus). Nothing when it is closed.
palette_build :: proc(app: ^App) {
	if !cpal.open { return }
	palette_ready(app)
	em := ui.font_size()
	win_w, win_h := f32(app.win.size.x), f32(app.win.size.y)
	ctrl, cs := platform.Modifiers{.Ctrl}, platform.Modifiers{.Ctrl, .Shift}

	// its own shortcut closes it; Tab stays in it
	if ui.key_press(.P, cs) || (cpal.cfg.ctrl_k && ui.key_press(.K, ctrl)) { palette_close(app); return }
	for ui.key_press(.Tab) || ui.key_press(.Tab, {.Shift}) {}

	// opening: a short fade and slide down (none when Windows turns animations off)
	k: f32 = 1
	if cpal.cfg.open_ms > 0 && os_animations_enabled(app) {
		k = f32(clamp(time.duration_milliseconds(time.tick_since(cpal.opened)) / cpal.cfg.open_ms, 0, 1))
		if k < 1 { app.frames_requested = max(app.frames_requested, 2) }
	}
	ease := 1 - (1 - k) * (1 - k) * (1 - k)

	// a press anywhere else closes it (the scrim is invisible: the chrome stays as it is)
	ui.next({fixed_x = 0, fixed_y = 0, fixed_w = win_w, fixed_h = win_h, bg = draw.Color{}})
	scrim := ui.build_box({.Clickable}, "###palette_scrim")
	scrim.cursor = .Arrow
	if s := ui.signal(scrim); s.pressed || s.right_clicked || s.middle_clicked { palette_close(app); return }

	w := math.round(min(cpal.cfg.width_em * em, win_w - em * 2))
	x := math.round((win_w - w) * 0.5)
	// over the address row, as VS Code's over its title bar
	y := em * 0.5
	if b := ui.box_from_key(address_key); b != nil && !platform.is_fullscreen(app.win) { y = b.rect.min.y - em * 0.15 }
	y = math.round(y - (1 - ease) * em * 0.6)
	rh := ui.dense(em * 2.1)
	pad := math.round(em * 0.4)
	mouse_moved := ui.mouse_pos() != cpal.last_mouse
	cpal.last_mouse = ui.mouse_pos()

	if ui.tags("floating") {
		ui.next({fixed_x = x, fixed_y = y, width = ui.px(w), height = ui.children_sum(), axis = .Y, radius = em * 0.5, transparency = 1 - ease})
		panel := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, "###palette")
		panel.cursor = .Arrow
		_ = ui.signal(panel)
		if ui.parent(panel) {
			ui.spacer(ui.px(pad))
			res: ui.Edit_Result
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.2))})
			if ui.row(.Center) {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.fill(), height = ui.pct(1), radius = em * CHROME_BUTTON_RADIUS})
				res = ui.line_edit("###palette_field", &cpal.field, PALETTE_PLACEHOLDER)
				ui.spacer(ui.px(pad))
			}
			if cpal.focus_pending && res.box != nil { cpal.focus_pending = false; ui.set_focus(res.box.key) }
			if res.cancelled { palette_close(app); return }

			// the rows, again only when something they depend on changed
			text := ui.field_string(&cpal.field)
			key := results_key(app)
			if !cpal.cache_valid || key != cpal.cache_key || text != cpal.cache_text {
				query_changed := text != cpal.cache_text || !cpal.cache_valid
				palette_collect(app, text)
				cpal.cache_key, cpal.cache_valid = key, true
				if query_changed {
					delete(cpal.cache_text)
					cpal.cache_text = strings.clone(text)
					cpal.sel, cpal.first = first_usable(), 0
				}
			}
			n := len(cpal.rows)
			cpal.sel = clamp(cpal.sel, 0, max(n - 1, 0))
			if row_usable(cpal.sel) == false && n > 0 { cpal.sel = first_usable() }
			vis := min(max(cpal.cfg.rows, 1), n)

			// keyboard
			if ui.key_press(.Down) { palette_step(+1) }
			if ui.key_press(.Up) { palette_step(-1) }
			if ui.key_press(.Page_Down) { palette_step(max(vis - 1, 1), page = true) }
			if ui.key_press(.Page_Up) { palette_step(-max(vis - 1, 1), page = true) }
			run, run_new := res.committed, ui.key_press(.Return, ctrl)

			ui.spacer(ui.px(pad * 0.75))
			ui.hline(ui.px(w))
			ui.spacer(ui.px(pad * 0.5))

			// the list: the visible rows only, scrolled by the wheel and to keep the selected one in view
			ui.next({width = ui.px(w), height = ui.px(f32(max(vis, 1)) * rh), axis = .Y})
			list := ui.build_box({.Scroll_Self, .Clip}, "###palette_list")
			if s := ui.signal(list); s.scrolled.y != 0 {
				cpal.scroll_acc += s.scrolled.y * 3
				step := int(cpal.scroll_acc)
				cpal.scroll_acc -= f32(step)
				cpal.first += step
				mouse_moved = false   // the rows move under the pointer: that is no choice
			} else {
				// keep the selection in view (a wheel turn scrolls freely)
				if cpal.sel < cpal.first { cpal.first = cpal.sel }
				if cpal.sel >= cpal.first + vis { cpal.first = cpal.sel - vis + 1 }
			}
			cpal.first = clamp(cpal.first, 0, max(n - vis, 0))
			thumb := ui.frame_new(Thumb_Draw)
			thumb^ = {cpal.first, vis, n, ui.color("border")}
			list.custom, list.custom_user = thumb_draw, thumb
			clicked, clicked_new := -1, false
			if ui.parent(list) {
				if n == 0 {
					ui.next({width = ui.px(w), height = ui.px(rh)})
					if ui.row(.Center) {
						ui.spacer(ui.px(pad + em * 0.6))
						if ui.tags("weak") { ui.next({width = ui.fill(), height = ui.pct(1)}); ui.label("No results###palette_none") }
					}
				}
				t := current_tab(app)
				// the category and shortcut columns: as wide as their widest visible entry, so they line up
				cols: [2]f32
				font := ui.top_style().font
				for i in cpal.first ..< min(cpal.first + vis, n) {
					r := &cpal.rows[i]
					cols[0] = max(cols[0], ui.text_width(font, em, r.category))
					if r.kind == .Command { cols[1] = max(cols[1], ui.text_width(font, em, command_shortcut_text(&commands()[r.index]))) }
				}
				cols = {math.ceil(cols[0]) + 2, math.ceil(cols[1]) + 2}
				for i in cpal.first ..< min(cpal.first + vis, n) {
					if c, nc := palette_row(app, t, i, w, rh, pad, cols, mouse_moved); c { clicked, clicked_new = i, nc }
				}
			}

			// the keys of the footer
			ui.spacer(ui.px(pad * 0.5))
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.7))})
			if ui.row(.Center) {
				ui.spacer(ui.px(pad + em * 0.4))
				if ui.tags("weak") {
					if ui.style({font_size = math.round(em * 0.86)}) {
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
						// nothing typed: what the prefixes search (the field's placeholder is not shown while it has the caret)
						ui.label(text == "" ? "Type to search, or start with   >  commands    @  tabs    :  settings    /  pages###palette_keys" : "Enter: run   Ctrl+Enter: in a new tab   Up / Down: move   Esc: close###palette_keys")
						ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
						ui.label(fmt.aprintf("%d result%s###palette_count", n, n == 1 ? "" : "s", allocator = ui.frame_allocator()))
					}
				}
				ui.spacer(ui.px(pad + em * 0.4))
			}
			ui.spacer(ui.px(pad * 0.5))

			if clicked >= 0 { palette_execute(app, clicked, clicked_new); return }
			if run_new { palette_execute(app, cpal.sel, true); return }
			if run { palette_execute(app, cpal.sel, false); return }
		}
	}
}

// One result row. True when it was clicked (`new_tab`: with Ctrl).
@(private = "file")
palette_row :: proc(app: ^App, t: ^Tab, i: int, w, rh, pad: f32, cols: [2]f32, mouse_moved: bool) -> (clicked, new_tab: bool) {
	r := &cpal.rows[i]
	em := ui.font_size()
	selected := i == cpal.sel
	checked := false
	shortcut := ""
	state := ""
	glyph := r.glyph
	ident: u64
	switch r.kind {
	case .Command:
		c := &commands()[r.index]
		if c.checked != nil { checked = c.checked(app, t, c) }
		shortcut = command_shortcut_text(c)
		ident = u64(r.index)
	case .Tab:
		ident = r.tab_id
		for x, k in app.tabs { if x.id == r.tab_id && k == app.current { state = "current" } }
	case .Closed_Tab:
		ident = u64(r.index)
	case .Pref:
		e := config.entry(&app.prefs, r.ref)
		v := config.value_string(&app.prefs, r.ref)
		if e.def.kind == .Bool { checked = e.value.b; state = e.value.b ? "on" : "off" } else { state = v == "" ? "(empty)" : v }
		if strings.rune_count(state) > 24 {
			cut, n := 0, 0
			for _, b in state { if n == 23 { cut = b; break }; n += 1 }
			state = strings.concatenate({state[:cut], "…"}, context.temp_allocator)
		}
		if e.source != .Default { state = strings.concatenate({state, e.locked ? "  (locked)" : "  (modified)"}, context.temp_allocator) }
		ident = u64(r.ref)
	case .Source:
		ident = fnv(u64(r.index), r.key)
	}
	id := fmt.tprintf("###pr_%d_%x", int(r.kind), ident)

	ui.next({width = ui.px(w), height = ui.px(rh), axis = .X, cross = .Center})
	outer := ui.build_box({}, fmt.tprintf("###prow_%d_%x", int(r.kind), ident))
	sig: ui.Signal
	if ui.parent(outer) {
		ui.spacer(ui.px(pad))
		if ui.disabled(r.disabled) {
			ui.push_tags("menu_item")
			if selected { ui.push_tags("selected") }
			mod := ui.Style_Mod{width = ui.fill(), height = ui.pct(1), radius = em * CHROME_BUTTON_RADIUS, axis = .X, cross = .Center}
			if !selected { mod.border = draw.Color{} }   // (a border all the time: the same layout selected or not)
			ui.next(mod)
			item := ui.build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, id)
			if selected { ui.pop_tags() }
			sig = ui.signal(item)
			if ui.parent(item) {
				ui.spacer(ui.px(em * 0.45))
				isz := em * 1.5
				switch {
				case r.kind == .Tab:
					tab: ^Tab
					for x in app.tabs { if x.id == r.tab_id { tab = x } }
					ui.next({width = ui.px(isz), height = ui.pct(1)})
					if tab != nil { ui.custom("###ticon", tab_icon_draw, tab_icon_of(app, tab, f32(tab_icon_px(app)))) } else { ui.build_box({}, "###ticon") }
				case checked:
					if ui.tags("weak") { ui.icon(ui.ICON_CHECK, isz) }
				case glyph != "":
					if ui.tags("weak") { ui.icon(glyph, isz) }
				case:
					ui.spacer(ui.px(isz))
				}
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label_fuzzy(label_id(r.title, "t"), r.ranges)
				if ui.tags("weak") {
					font := ui.top_style().font
					if r.detail != "" && r.detail != r.title {
						dw := min(ui.text_width(font, em, r.detail) + em * 0.8, w * 0.38)
						ui.next({width = ui.px(dw), height = ui.pct(1), text_pad = em * 0.4})
						ui.label(label_id(r.detail, "d"))
					}
					if state != "" {
						ui.next({width = ui.text_size(em * 0.2), height = ui.pct(1)})
						ui.label(label_id(state, "s"))
					}
					ui.spacer(ui.px(em * 0.6))
					ui.next({width = ui.px(cols[0]), height = ui.pct(1), text_pad = 0, text_align = .Right})
					ui.label(label_id(r.category, "c"))
					if cols[1] > 2 {
						ui.spacer(ui.px(em * 1.2))
						ui.next({width = ui.px(cols[1]), height = ui.pct(1), text_pad = 0, text_align = .Right})
						ui.label(label_id(shortcut, "k"))
					}
				}
				ui.spacer(ui.px(em * 0.6))
			}
			ui.pop_tags()
		}
		ui.spacer(ui.px(pad))
	}
	if sig.hovering && mouse_moved && !r.disabled { cpal.sel = i }
	if sig.clicked && !r.disabled { return true, .Ctrl in sig.mods }
	return false, false
}
