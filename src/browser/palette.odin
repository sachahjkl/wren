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
// Matching and ranking are the toolkit's palette's (ui.rank with ui.rank_palette, docs/commands.md of the toolkit): the
// title holds what is typed whole or in pieces that begin its words, then a command's other words and its group, then the
// same with a slip; a last text (a command's name, an address, a preference's description) finds a row when nothing
// else does. The usage memory raises a hit (rank's bonus). Results are worked out again only when what they depend on
// changes (the query, the tabs, the preferences, the commands' states): an open palette at rest costs a caret blink, a
// closed one nothing.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "toolkit:draw"
import lucide "toolkit:lucide"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:host"

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
// What was chosen, and when (pure parts: palette_test.odin)

PALETTE_USAGE_HEADER :: "wren-palette-usage 1"

Usage_Entry :: struct { count: int, last_ms: i64 }

Palette_Usage :: struct {
	entries: map[string]Usage_Entry,   // owned keys: "cmd:tab.new", "pref:appearance.theme"
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
	u := &app.cpal.usage
	if u.loaded { return }
	u.loaded = true
	if !app.cfg.persist_profile { return }
	// read by the blocking pool (the palette opens at once; the order of its first results may change when it comes)
	Usage_Read :: struct { app: ^App, path: string, data: []u8 }
	j := new(Usage_Read)
	j^ = {app = app, path = strings.clone(usage_path(app))}
	drop :: proc(data: rawptr) { j := (^Usage_Read)(data); delete(j.path); delete(j.data); free(j) }
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Usage_Read)(data)
		if bytes, err := os.read_entire_file(j.path, context.allocator); err == nil { j.data = bytes }
	}, proc(data: rawptr) {
		j := (^Usage_Read)(data)
		defer drop(j)
		if j.data == nil { return }
		_ = usage_parse(&j.app.cpal.usage, string(j.data), j.app.cpal.cfg.usage_max)
		request_frames(j.app, 2)
	}, j, drop)
}

// Written as soon as it changes (a few hundred bytes), by the blocking pool (profile_writes.odin).
@(private = "file")
usage_save :: proc(app: ^App) {
	if !app.cfg.persist_profile { return }
	host.profile_file_init(&app.cpal.usage_file, &app.writer, usage_path(app))
	host.profile_file_write(&app.cpal.usage_file, usage_serialize(&app.cpal.usage))
}

@(private = "file")
usage_note :: proc(app: ^App, key: string) {
	if !app.cpal.cfg.remember { return }
	usage_load(app)
	usage_record(&app.cpal.usage, key, now_unix_ms(), app.cpal.cfg.usage_max, app.cpal.cfg.half_life_days)
	usage_save(app)
}

@(private = "file")
usage_of :: proc(app: ^App, key: string, now_ms: i64) -> f64 {
	if !app.cpal.cfg.remember { return 0 }
	e, ok := app.cpal.usage.entries[key]
	return ok ? usage_weight(e, now_ms, app.cpal.cfg.half_life_days) : 0
}

////////////////////////////////
// Sources of pages (history, bookmarks...): plugged in by whoever has them

// One page a source offers. The strings need only last until `items` returns (the palette copies what it keeps).
Palette_Item :: struct {
	title:  string,
	detail: string,   // shown weak after the title (its address)
	key:    string,   // given back to `activate`
	glyph:  string,
	site:   string,   // an address whose site icon the row shows ("": its glyph)
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
palette_add_source :: proc(app: ^App, s: Palette_Source) {
	for &x in app.cpal.sources { if x.name == s.name { x = s; app.cpal.cache_valid = false; return } }
	append(&app.cpal.sources, s)
	app.cpal.cache_valid = false
}

palette_remove_source :: proc(app: ^App, name: string) {
	for x, i in app.cpal.sources { if x.name == name { ordered_remove(&app.cpal.sources, i); app.cpal.cache_valid = false; return } }
}

// The built-in source of pages: what the open tabs visited (each tab's session history).
@(private = "file")
tab_history_items :: proc(user: rawptr, app: ^App, out: ^[dynamic]Palette_Item) {
	seen := make(map[string]bool, 64, context.temp_allocator)
	for t in tabs_all(app) {
		for i := len(t.history) - 1; i >= 0; i -= 1 {
			u := t.history[i]
			if u == "" || u in seen { continue }
			seen[u] = true
			append(out, Palette_Item{title = default_tab_title(u), detail = u, key = u, site = u})
		}
	}
}

@(private = "file")
tab_history_activate :: proc(user: rawptr, app: ^App, key: string, new_tab: bool) {
	t := current_tab(app)
	if new_tab || t == nil { open_in_new_tab(app, key, origin = .User) } else { navigate(app, t, strings.clone(key, context.temp_allocator), origin = .User) }
}

@(private = "file")
tab_history_version :: proc(user: rawptr, app: ^App) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for t in tabs_all(app) { h = (h ~ t.id) * 0x100000001b3; h = (h ~ u64(len(t.history))) * 0x100000001b3; h = (h ~ u64(t.hist)) * 0x100000001b3 }
	return h
}

////////////////////////////////
// Results

Palette_Mode :: enum u8 { All, Commands, Tabs, Prefs, Source }

// What the query asks for: its prefix's mode (Source: `prefix`, the character) and the words after it.
palette_parse_query :: proc(app: ^App, text: string) -> (mode: Palette_Mode, prefix: u8, query: string) {
	s := strings.trim_left_space(text)
	if len(s) == 0 { return .All, 0, "" }
	switch s[0] {
	case '>': return .Commands, 0, strings.trim_space(s[1:])
	case '@': return .Tabs, 0, strings.trim_space(s[1:])
	case ':': return .Prefs, 0, strings.trim_space(s[1:])
	case '/', '#', '!', '*', '%', '&', '$', '~', '^':
		for src in app.cpal.sources { if src.prefix == s[0] { return .Source, s[0], strings.trim_space(s[1:]) } }
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
	site:     string,         // a source item's address whose site icon shows
	tags:     []string,       // other words that find it (a command's; while collecting)
	last:     string,         // a text that finds it when nothing else does (while collecting)
	usage:    f64,
	disabled: bool,
	ranges:   []ui.Fuzzy_Range,
}

Palette_State :: struct {
	open:          bool,
	window:        int,             // the window it is open in (Browser_Window.id)
	field:         ui.Text_Field,
	opened:        time.Tick,
	focus_pending: bool,
	saved_focus:   ui.Key,
	sel, first:    int,
	scroll_acc:    f32,
	rows:          [dynamic]Palette_Row,
	arena:         base.Arena,   // the rows' strings and ranges
	arena_ready:   bool,
	search:        ui.Fuzzy_Cache,   // the query and the candidates' texts folded, from one search to the next (ui.rank)
	cache_text:    string,          // owned: the query the rows are for
	cache_key:     u64,
	cache_valid:   bool,
	last_mouse:    [2]f32,
	cfg:           Palette_Settings,
	cfg_version:   u64,
	cfg_ready:     bool,
	usage:         Palette_Usage,
	usage_file:    host.Profile_File,    // palette_usage.txt (profile_writes.odin)
	sources:       [dynamic]Palette_Source,
	sources_ready: bool,
}


// (The palette belongs to the window it was opened in: the others show nothing of it.)
palette_open :: proc(app: ^App) -> bool { return app.cpal.open && app.active != nil && app.cpal.window == app.active.id }

palette_destroy :: proc(app: ^App) {
	ui.field_destroy(&app.cpal.field)
	delete(app.cpal.rows)
	ui.fuzzy_cache_destroy(&app.cpal.search)
	if app.cpal.arena_ready { base.arena_destroy(&app.cpal.arena) }
	delete(app.cpal.cache_text)
	usage_destroy(&app.cpal.usage)
	host.profile_file_destroy(&app.cpal.usage_file)   // (written by profile_files_flush, before the loop ended)
	delete(app.cpal.sources)
	app.cpal = {}
	commands_destroy(&app.cmds)
}

@(private = "file")
palette_ready :: proc(app: ^App) {
	if !app.cpal.cfg_ready || app.cpal.cfg_version != app.prefs.version {
		app.cpal.cfg = palette_settings_from_prefs(&app.prefs)
		app.cpal.cfg_version, app.cpal.cfg_ready = app.prefs.version, true
	}
	if !app.cpal.arena_ready { _ = base.arena_init_growing(&app.cpal.arena); app.cpal.arena_ready = true }
	if !app.cpal.sources_ready {
		app.cpal.sources_ready = true
		palette_add_source(app, {name = "Visited", prefix = '/', in_default = true, items = tab_history_items, activate = tab_history_activate, version = tab_history_version})
		palette_add_source(app, bookmarks_palette_source())   // bookmarks_ui.odin
		palette_add_source(app, vault_palette_source())   // vault_fill.odin: "$" searches the Vault (nothing while it is locked or off)
	}
}

palette_toggle :: proc(app: ^App) {
	if app.cpal.open { palette_close(app) } else { palette_show(app) }
}

// Opens the palette (with `text` typed, a prefix for instance).
palette_show :: proc(app: ^App, text := "") {
	palette_ready(app)
	usage_load(app)
	ui.ctx_menu_close()
	app.cpal.open = true
	app.cpal.window = app.active != nil ? app.active.id : 0
	ui.field_set(&app.cpal.field, text)
	app.cpal.sel, app.cpal.first, app.cpal.scroll_acc = 0, 0, 0
	app.cpal.cache_valid = false
	app.cpal.saved_focus = ui.focus_key()
	app.cpal.focus_pending = true
	app.cpal.opened = time.tick_now()
	app.cpal.last_mouse = ui.mouse_pos()
	request_frames(app, 3)
}

// Closes it; the keyboard goes back to what had it (when that is still there).
palette_close :: proc(app: ^App) {
	if !app.cpal.open { return }
	app.cpal.open = false
	k := app.cpal.saved_focus
	ui.set_focus(k != 0 && ui.box_from_key(k) != nil ? k : 0)
	clear(&app.cpal.rows)
	app.cpal.cache_valid = false
	request_frames(app, 2)
}

// While it is open the palette takes every press and wheel turn: the page under it gets none (hud_captures).
palette_captures :: proc(app: ^App, pos: draw.Vec2) -> bool { return palette_open(app) }

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
	h = mix(h, u64(active_window(app).current))
	h = mix(h, app.cpal.usage.version)
	h = mix(h, u64(len(closed_items(app))))
	for t in tabs_all(app) { h = mix(h, t.id); h = fnv(h, t.title); h = fnv(h, t.url) }
	t := current_tab(app)
	for &c, i in commands(app) { if command_enabled(app, t, &c) { h = mix(h, u64(i) + 1) } }
	for s in app.cpal.sources { h = fnv(h, s.name); if s.version != nil { h = mix(h, s.version(s.user, app)) } else { h = mix(h, u64(ui.now_ms())) } }
	return h
}

// The rows for `text` (in app.cpal.rows, best first). Pure apart from the registry, the usage memory and the sources.
// The candidates keep the strings they come with (the frame's); only the rows kept are copied, into the palette's arena.
palette_collect :: proc(app: ^App, text: string) {
	palette_ready(app)
	base.arena_free_all(&app.cpal.arena)
	clear(&app.cpal.rows)
	mode, prefix, q := palette_parse_query(app, text)
	now := now_unix_ms()
	t := current_tab(app)
	cands := make([dynamic]Palette_Row, context.temp_allocator)

	if mode == .All || mode == .Commands {
		for &c, i in commands(app) {
			if c.hidden { continue }
			enabled := command_enabled(app, t, &c)
			if !enabled && !app.cpal.cfg.show_disabled { continue }
			append(&cands, Palette_Row{kind = .Command, index = i, title = c.label, category = c.group, glyph = c.icon, tags = c.tags, last = c.name,
				usage = usage_of(app, strings.concatenate({"cmd:", c.name}, context.temp_allocator), now), disabled = !enabled})
		}
	}
	if mode == .All || mode == .Tabs {
		for tab in tabs_all(app) {
			append(&cands, Palette_Row{kind = .Tab, tab_id = tab.id, title = tab.title, detail = tab.url, category = "Tab", last = tab.url})
		}
	}
	if mode == .Tabs || (mode == .All && q != "") {
		closed := closed_items(app)
		for i := len(closed) - 1; i >= 0; i -= 1 {
			u := closed[i].address
			append(&cands, Palette_Row{kind = .Closed_Tab, index = i, key = u, title = closed_item_label(closed[i]), detail = u, category = "Closed tab", last = u})
		}
	}
	if mode == .Prefs {
		for name in config.sorted_names(&app.prefs) {
			r := config.ref_of(&app.prefs, name)
			e := config.entry(&app.prefs, r)
			append(&cands, Palette_Row{kind = .Pref, ref = r, title = name, category = "Setting", last = e.def.description,
				usage = usage_of(app, strings.concatenate({"pref:", name}, context.temp_allocator), now), disabled = e.source == .Policy})
		}
	}
	if mode == .Source || (mode == .All && q != "") {
		for src, si in app.cpal.sources {
			if mode == .Source ? src.prefix != prefix : !src.in_default { continue }
			if src.items == nil { continue }
			items := make([dynamic]Palette_Item, context.temp_allocator)
			src.items(src.user, app, &items)
			for it, n in items {
				if n >= app.cpal.cfg.source_max { break }
				append(&cands, Palette_Row{kind = .Source, index = si, key = it.key, title = it.title, detail = it.detail,
					category = src.name, glyph = it.glyph, site = it.site, last = it.detail})
			}
		}
	}

	typed := q != ""
	hits := ui.rank(q, cands[:], palette_rank_entry, &typed, bonus = palette_rank_bonus, cache = &app.cpal.search)
	// what can run before what cannot, each in the rank's order
	order := make([dynamic]ui.Rank_Hit, 0, len(hits), context.temp_allocator)
	for h in hits { if !cands[h.index].disabled { append(&order, h) } }
	for h in hits { if cands[h.index].disabled { append(&order, h) } }
	// what is kept outlives the frame
	a := base.arena_allocator(&app.cpal.arena)
	for h in order[:min(len(order), app.cpal.cfg.max_results)] {
		r := cands[h.index]
		r.title = strings.clone(r.title, a)
		r.detail = strings.clone(r.detail, a)
		r.key = strings.clone(r.key, a)
		r.glyph = strings.clone(r.glyph, a)
		r.site = strings.clone(r.site, a)
		r.tags, r.last = nil, ""
		if len(h.ranges) > 0 {
			r.ranges = make([]ui.Fuzzy_Range, len(h.ranges), a)
			copy(r.ranges, h.ranges)
		}
		append(&app.cpal.rows, r)
	}
}

// A candidate as ui.rank reads it: a command is found by its group too, the other rows by their title and last text.
@(private = "file")
palette_rank_entry :: proc(r: ^Palette_Row, _: rawptr) -> ui.Rank_Entry {
	return {label = r.title, group = r.kind == .Command ? r.category : "", tags = r.tags, last = r.last}
}

// What use adds to a hit (`user`: ^bool, something is typed): nothing typed, the usage orders the rows (the registry's or
// the tabs' order between equals); typed, it raises a match a little (bounded: a good match still beats a frequent poor
// one), and the pages of a source come after commands and tabs that match as well.
@(private = "file")
palette_rank_bonus :: proc(r: ^Palette_Row, user: rawptr) -> f64 {
	if !(^bool)(user)^ { return r.usage }
	behind: f64 = r.kind == .Source ? PALETTE_SOURCE_BEHIND : 0
	return min(r.usage * PALETTE_USAGE_WEIGHT, PALETTE_USAGE_MOST) - behind
}

@(private = "file") PALETTE_USAGE_WEIGHT :: 6
@(private = "file") PALETTE_USAGE_MOST :: 30
@(private = "file") PALETTE_SOURCE_BEHIND :: 4

@(private = "file")
row_usable :: proc(app: ^App, i: int) -> bool { return i >= 0 && i < len(app.cpal.rows) && !app.cpal.rows[i].disabled }

// The next usable row from `from` by `dir` (±1 wraps; a page stops at the ends).
@(private = "file")
palette_step :: proc(app: ^App, dir: int, page := false) {
	n := len(app.cpal.rows)
	if n == 0 { return }
	if !page {
		i := app.cpal.sel
		for _ in 0 ..< n {
			i = (i + dir + n) %% n
			if row_usable(app, i) { app.cpal.sel = i; return }
		}
		return
	}
	target := clamp(app.cpal.sel + dir, 0, n - 1)
	for i := target; i >= 0 && i < n; i += dir > 0 ? 1 : -1 { if row_usable(app, i) { app.cpal.sel = i; return } }
	for i := target; i >= 0 && i < n; i -= dir > 0 ? 1 : -1 { if row_usable(app, i) { app.cpal.sel = i; return } }
}

@(private = "file")
first_usable :: proc(app: ^App) -> int {
	for i in 0 ..< len(app.cpal.rows) { if row_usable(app, i) { return i } }
	return 0
}

// Runs row `i`. `new_tab`: what opens a page opens it in a new tab.
palette_execute :: proc(app: ^App, i: int, new_tab: bool) {
	if !row_usable(app, i) { return }
	r := app.cpal.rows[i]
	t := current_tab(app)
	switch r.kind {
	case .Command:
		c := &commands(app)[r.index]
		if !command_enabled(app, t, c) { return }
		key := strings.concatenate({"cmd:", c.name}, context.temp_allocator)
		palette_close(app)
		usage_note(app, key)
		if new_tab && c.url != "" { open_in_new_tab(app, c.url, origin = .User) } else { command_run(app, current_tab(app), c) }
	case .Tab:
		palette_close(app)
		if x := tab_by_id(app, r.tab_id); x != nil { tab_reveal(app, x) }
	case .Closed_Tab:
		address := strings.clone(r.key, context.temp_allocator)
		palette_close(app)
		reopen_closed_address(app, address)
	case .Pref:
		e := config.entry(&app.prefs, r.ref)
		name := strings.clone(e.def.name, context.temp_allocator)
		usage_note(app, strings.concatenate({"pref:", name}, context.temp_allocator))
		if e.def.kind == .Bool && !new_tab {
			// toggled in place: the palette stays, showing the new value
			set_pref_bool(app, name, !e.value.b)
			app.cpal.cache_valid = false
			return
		}
		palette_close(app)
		dest := t
		if new_tab || dest == nil { dest = tab_open(app, "about:config", origin = .User) } else { navigate(app, dest, "about:config", origin = .User) }
		ui.field_set(&app.config_view.search, name)
		app.config_view.focus_list = true
	case .Source:
		if r.index < 0 || r.index >= len(app.cpal.sources) { return }
		src := app.cpal.sources[r.index]
		key := strings.clone(r.key, context.temp_allocator)
		palette_close(app)
		if src.activate != nil { src.activate(src.user, app, key, new_tab) }
	}
	request_frames(app, 2)
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
	wnd := active_window(app)
	if !palette_open(app) { return }
	palette_ready(app)
	em := ui.font_size()
	win_w, win_h := f32(wnd.win.size.x), f32(wnd.win.size.y)
	ctrl := platform.Modifiers{.Ctrl}

	// its own command's keys close it; Tab stays in it
	if c := command(app, "browser.command_palette"); c != nil && command_pressed(app, c) { palette_close(app); return }
	for ui.key_press(.Tab) || ui.key_press(.Tab, {.Shift}) {}

	// opening: a short fade and slide down (none when Windows turns animations off)
	k: f32 = 1
	if app.cpal.cfg.open_ms > 0 && os_animations_enabled(app) {
		k = f32(clamp(time.duration_milliseconds(time.tick_since(app.cpal.opened)) / app.cpal.cfg.open_ms, 0, 1))
		if k < 1 { request_frames(app, 2) }
	}
	ease := 1 - (1 - k) * (1 - k) * (1 - k)

	// a press anywhere else closes it (the scrim is invisible: the chrome stays as it is)
	ui.next({fixed_x = 0, fixed_y = 0, fixed_w = win_w, fixed_h = win_h, bg = draw.Color{}})
	scrim := ui.build_box({.Clickable}, "###palette_scrim")
	scrim.cursor = .Arrow
	if s := ui.signal(scrim); s.pressed || s.right_clicked || s.middle_clicked { palette_close(app); return }

	w := math.round(min(app.cpal.cfg.width_em * em, win_w - em * 2))
	x := math.round((win_w - w) * 0.5)
	// over the address row, as VS Code's over its title bar
	y := em * 0.5
	if b := ui.box_from_key(address_key(app)); b != nil && !platform.is_fullscreen(wnd.win) { y = b.rect.min.y - em * 0.15 }
	y = math.round(y - (1 - ease) * em * 0.6)
	rh := ui.dense(em * 2.1)
	pad := math.round(em * 0.4)
	mouse_moved := ui.mouse_pos() != app.cpal.last_mouse
	app.cpal.last_mouse = ui.mouse_pos()

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
				res = ui.line_edit("###palette_field", &app.cpal.field, PALETTE_PLACEHOLDER)
				ui.spacer(ui.px(pad))
			}
			if app.cpal.focus_pending && res.box != nil { app.cpal.focus_pending = false; ui.set_focus(res.box.key) }
			if res.cancelled { palette_close(app); return }

			// the rows, again only when something they depend on changed
			text := ui.field_string(&app.cpal.field)
			key := results_key(app)
			if !app.cpal.cache_valid || key != app.cpal.cache_key || text != app.cpal.cache_text {
				query_changed := text != app.cpal.cache_text || !app.cpal.cache_valid
				palette_collect(app, text)
				app.cpal.cache_key, app.cpal.cache_valid = key, true
				if query_changed {
					delete(app.cpal.cache_text)
					app.cpal.cache_text = strings.clone(text)
					app.cpal.sel, app.cpal.first = first_usable(app), 0
				}
			}
			n := len(app.cpal.rows)
			app.cpal.sel = clamp(app.cpal.sel, 0, max(n - 1, 0))
			if row_usable(app, app.cpal.sel) == false && n > 0 { app.cpal.sel = first_usable(app) }
			vis := min(max(app.cpal.cfg.rows, 1), n)

			// keyboard
			if ui.key_press(.Down) { palette_step(app, +1) }
			if ui.key_press(.Up) { palette_step(app, -1) }
			if ui.key_press(.Page_Down) { palette_step(app, max(vis - 1, 1), page = true) }
			if ui.key_press(.Page_Up) { palette_step(app, -max(vis - 1, 1), page = true) }
			run, run_new := res.committed, ui.key_press(.Return, ctrl)

			ui.spacer(ui.px(pad * 0.75))
			ui.hline(ui.px(w))
			ui.spacer(ui.px(pad * 0.5))

			// the list: the visible rows only, scrolled by the wheel and to keep the selected one in view
			ui.next({width = ui.px(w), height = ui.px(f32(max(vis, 1)) * rh), axis = .Y})
			list := ui.build_box({.Scroll_Self, .Clip}, "###palette_list")
			if s := ui.signal(list); s.scrolled.y != 0 {
				app.cpal.scroll_acc += s.scrolled.y * 3
				step := int(app.cpal.scroll_acc)
				app.cpal.scroll_acc -= f32(step)
				app.cpal.first += step
				mouse_moved = false   // the rows move under the pointer: that is no choice
			} else {
				// keep the selection in view (a wheel turn scrolls freely)
				if app.cpal.sel < app.cpal.first { app.cpal.first = app.cpal.sel }
				if app.cpal.sel >= app.cpal.first + vis { app.cpal.first = app.cpal.sel - vis + 1 }
			}
			app.cpal.first = clamp(app.cpal.first, 0, max(n - vis, 0))
			thumb := ui.frame_new(Thumb_Draw)
			thumb^ = {app.cpal.first, vis, n, ui.color("border")}
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
				for i in app.cpal.first ..< min(app.cpal.first + vis, n) {
					r := &app.cpal.rows[i]
					cols[0] = max(cols[0], ui.text_width(font, em, r.category))
					if r.kind == .Command { cols[1] = max(cols[1], ui.text_width(font, em, ui.command_shortcut(commands(app)[r.index].spec))) }
				}
				cols = {math.ceil(cols[0]) + 2, math.ceil(cols[1]) + 2}
				for i in app.cpal.first ..< min(app.cpal.first + vis, n) {
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
			if run_new { palette_execute(app, app.cpal.sel, true); return }
			if run { palette_execute(app, app.cpal.sel, false); return }
		}
	}
}

// One result row. True when it was clicked (`new_tab`: with Ctrl).
@(private = "file")
palette_row :: proc(app: ^App, t: ^Tab, i: int, w, rh, pad: f32, cols: [2]f32, mouse_moved: bool) -> (clicked, new_tab: bool) {
	r := &app.cpal.rows[i]
	em := ui.font_size()
	selected := i == app.cpal.sel
	checked := false
	shortcut := ""
	state := ""
	glyph := r.glyph
	ident: u64
	switch r.kind {
	case .Command:
		c := &commands(app)[r.index]
		if c.checked != nil { checked = c.checked(app, t, c) }
		shortcut = ui.command_shortcut(c.spec)
		ident = u64(r.index)
	case .Tab:
		ident = r.tab_id
		if x := tab_by_id(app, r.tab_id); x != nil && x == current_tab(app) { state = "current" }
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
		if e.source != .Default { state = strings.concatenate({state, (e.source == .Policy) ? "  (locked)" : "  (modified)"}, context.temp_allocator) }
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
				// (a page's site icon, its globe until it comes; a closed tab's key is its address)
				site := r.kind == .Closed_Tab ? r.key : r.site
				site_tex, site_ok := favicon_of_url(app, site)
				if site != "" && !site_ok && glyph == "" { glyph = lucide.GLOBE }
				switch {
				case site_ok:
					favicon_box(site_tex, "###pal_site", isz)
				case r.kind == .Tab:
					tab: ^Tab
					tab = tab_by_id(app, r.tab_id)
					ui.next({width = ui.px(isz), height = ui.pct(1)})
					if tab != nil { ui.custom("###ticon", tab_icon_draw, tab_icon_of(app, tab, f32(tab_icon_px(app)))) } else { ui.build_box({}, "###ticon") }
				case checked:
					if ui.tags("weak") { ui.icon(lucide.CHECK, isz) }
				case glyph != "":
					// (a command's icon is Lucide's, as in its menus: command_icons.odin)
					if ui.tags("weak") {
						ui.next({width = ui.px(isz), height = ui.pct(1), font = app.lucide, text_align = .Center})
						ui.build_box({.Draw_Text, .No_Text_Trunc}, strings.concatenate({glyph, "###pal_glyph"}, ui.frame_allocator()))
					}
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
	if sig.hovering && mouse_moved && !r.disabled { app.cpal.sel = i }
	if sig.clicked && !r.disabled { return true, .Ctrl in sig.mods }
	return false, false
}
