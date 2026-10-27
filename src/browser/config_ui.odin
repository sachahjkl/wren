package browser

// about:config: every preference of the browser, built with the toolkit like the rest of the chrome.
//
// The page: a header (title, search, "modified only", the keyboard help behind a button), the categories on the left
// ("All" first; each with how many preferences it shows for the search and how many are modified), the preferences on
// the right. A preference is a row:
//
//   * its title (config.title_of: "Badge style" for blocker.badge.style), a dot when the user changed it, pills when the
//     command line or a policy sets it or when it takes effect at the next start;
//   * its dotted name in small (a click copies it), and the default beside it while the value differs from it;
//   * the first sentence of its description (config.summary_of); the rest and the facts (default, range, allowed values,
//     K / M / G, restart) are behind the row's details fold (the chevron, or Right / Left);
//   * the editor in a fixed column: a switch, a choice, a field with its unit; the reset button beside it.
//
// The desktop integration is a row of the Browser category (desktop_shell.odin fills it in).
//
// The list is virtualized (ui.vlist): only the rows in view are built, whatever the number of preferences. The rows
// themselves (which preferences, in which order, under which headers) and the category counts are worked out again only
// when the search, a filter, a folded group, an opened fold or the registry changes, not at every frame; wrapped text
// comes from the toolkit's cache.
//
// Keyboard: the categories and the list are one Tab stop each. In the list: Up / Down / Page Up / Page Down / Home / End
// move over the rows, typing jumps to a title, Enter edits the active preference (a switch flips; a choice or a text
// field takes the focus: Enter applies, Escape goes back to the list) or folds / unfolds a group, Right opens a
// preference's details or unfolds a group, Left closes the details, then goes to the group's header, then folds it,
// Ctrl+Left / Ctrl+Right fold / unfold every group, Delete resets the preference to its default. Ctrl+F (or Down /
// Enter back from the search field) moves between the search and the list.

import "core:fmt"
import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:config"
import "wb:i18n"

Row_State :: struct {
	field:   ui.Text_Field,
	synced:  string,     // the text the field was last synchronised with (owned)
	error:   string,     // owned, shown under the row after a rejected edit
	focused: bool,       // the editor had keyboard focus in the previous frame
	editor:  ui.Key,     // the editor's box (last frame), for keyboard activation
	want_focus: bool,    // give the editor the focus at the next build
	expanded: bool,      // the details are open
}

Config_Row_Kind :: enum u8 { Header, Pref, Desktop }

// A row of the list: a group header, a preference or the desktop integration.
Config_Row :: struct {
	kind:  Config_Row_Kind,
	ref:   config.Ref,   // Pref
	name:  string,       // the preference's name, or the group's (the registry's strings)
	group: string,
	count: int,          // Header: the preferences it holds for the current search and filter
}

// A category of the sidebar.
Config_Cat :: struct {
	name:     string,   // the registry's string
	total:    int,      // its preferences
	modified: int,      // of which not at their default
	shown:    int,      // of which the search and the "modified only" filter keep
}

// The name of the desktop integration's row (search, labels): it has no preference of its own.
CONFIG_DESKTOP_ROW :: "browser.desktop_integration"

Config_View :: struct {
	search:        ui.Text_Field,
	modified_only: bool,
	category:      string,              // the category shown ("" = all), owned
	show_keys:     bool,                // the keyboard help is shown
	narrow:        bool,                // too narrow for the sidebar: the categories are a choice in the header
	stacked:       bool,                // too narrow for the editor column: each editor goes under its text
	text_w:        f32,                 // the text column's width when capped (a wide window: the values stay near the titles); 0: what is left
	editor_w:      f32,                 // the editor column's width
	rows:          map[string]^Row_State,
	list:          ui.Virtual_List,
	cat_list:      ui.List_State,
	focus_search:  bool,
	focus_list:    bool,
	collapsed:     map[string]bool,     // folded groups (owned keys)
	serial:        u64,                 // bumped when something that changes a row's height changes (an error, a fold)
	// the rows, worked out again only when what they depend on changes (model_key)
	model:         [dynamic]Config_Row,
	ids:           [dynamic]u64,        // identities for the list's height cache: name, source, error, details
	labels:        [dynamic]string,     // the rows' titles (owned): what they show, type-ahead, screen readers
	selectable:    [dynamic]bool,
	cats:          [dynamic]Config_Cat,
	shown:         int,                 // preferences the search and filter keep, over all categories
	modified:      int,                 // preferences not at their default
	desktop_row:   int,                 // index of the desktop row in `model` (-1: none)
	model_query:   string,              // owned
	model_key:     [6]u64,              // prefs version, entries, serial, modified_only, category, desktop row
	model_valid:   bool,
	started:       bool,                // the view was built once (no active row before the user picks one)
}

config_view_destroy :: proc(v: ^Config_View) {
	ui.field_destroy(&v.search)
	for k, r in v.rows { ui.field_destroy(&r.field); delete(r.synced); delete(r.error); free(r); delete(k) }
	delete(v.rows)
	ui.vlist_destroy(&v.list)
	ui.list_state_destroy(&v.cat_list)
	for k in v.collapsed { delete(k) }
	delete(v.collapsed)
	delete(v.model)
	delete(v.ids)
	for s in v.labels { delete(s) }
	delete(v.labels)
	delete(v.selectable)
	delete(v.cats)
	delete(v.model_query)
	delete(v.category)
}

@(private)
row_for :: proc(v: ^Config_View, name: string) -> ^Row_State {
	if r, ok := v.rows[name]; ok { return r }
	r := new(Row_State)
	v.rows[strings.clone(name)] = r
	return r
}

source_label :: proc(e: ^config.Entry) -> string {
	switch e.source {
	case .Default: return ""
	case .User: return i18n.tr("modified")
	case .Command_Line: return i18n.tr("command line")
	case .Policy: return i18n.tr("policy (locked)")
	}
	return ""
}

@(private = "file")
number_text :: proc(v: f64, kind: config.Kind) -> string {
	if kind == .Int { return fmt.tprintf("%d", i64(v)) }
	return fmt.tprintf("%g", v)
}

// The value as the details write it: a string's empty value reads "(empty)", a number carries its unit.
@(private = "file")
shown_value :: proc(d: config.Def, text: string) -> string {
	if d.kind == .String && text == "" { return i18n.tr("(empty)") }
	if (d.kind == .Int || d.kind == .Float) && d.unit != "" { return strings.concatenate({text, " ", d.unit}, context.temp_allocator) }
	return text
}

// The facts of the details: "Default 30000 ms  ·  0 to 3600000 ms  ·  takes effect at the next start".
@(private)
facts_line :: proc(prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry) -> string {
	d := e.def
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, fmt.tprintf(i18n.tr("Default %s"), shown_value(d, config.default_string(prefs, r))))
	unit := d.unit != "" ? strings.concatenate({" ", d.unit}, context.temp_allocator) : ""
	if d.bounded { append(&parts, fmt.tprintf(i18n.tr("%s to %s%s"), number_text(d.min, d.kind), number_text(d.max, d.kind), unit)) }
	if len(d.choices) > 0 { append(&parts, strings.concatenate({i18n.tr("one of "), strings.join(d.choices, ", ", context.temp_allocator)}, context.temp_allocator)) }
	if d.bytes { append(&parts, i18n.tr("K / M / G accepted")) }
	if d.restart { append(&parts, i18n.tr("takes effect at the next start")) }
	switch e.source {
	case .Command_Line: append(&parts, i18n.tr("set on the command line for this run"))
	case .Policy: append(&parts, i18n.tr("locked by a policy"))
	case .Default, .User:
	}
	return strings.join(parts[:], "  \u00b7  ", context.temp_allocator)
}

@(private = "file")
CFG_HASH_SEED :: u64(0xcbf29ce484222325)

@(private = "file")
cfg_hash :: proc(h: u64, s: string) -> u64 {
	h := h
	for c in transmute([]u8)s { h = (h ~ u64(c)) * 0x100000001b3 }
	return h
}

// The desktop integration as the search sees it.
@(private = "file")
desktop_search_def :: proc() -> config.Def {
	return {name = CONFIG_DESKTOP_ROW, category = "browser", kind = .Bool,   // title: "Desktop integration"
		description = "Integrate the browser with the desktop: Start menu, default apps, default browser, Windows, Setup."}
}

// The rows for the current search, filters and folded groups, and the category counts (only when one of them or the
// registry changed). `with_desktop`: the platform has a desktop integration (a row of the Browser category).
@(private)
config_model :: proc(v: ^Config_View, prefs: ^config.Prefs, query: string, with_desktop: bool) {
	key := [6]u64{prefs.version, u64(len(prefs.entries)), v.serial, u64(v.modified_only), cfg_hash(CFG_HASH_SEED, v.category), u64(with_desktop)}
	if v.model_valid && key == v.model_key && query == v.model_query { return }
	v.model_valid, v.model_key = true, key
	delete(v.model_query)
	v.model_query = strings.clone(query)
	clear(&v.model); clear(&v.ids); clear(&v.selectable); clear(&v.cats)
	for s in v.labels { delete(s) }
	clear(&v.labels)
	v.shown, v.modified, v.desktop_row = 0, 0, -1

	// by category, then name (a category is not always the name's first segment: "testing" gathers several)
	Item :: struct { cat, name: string, index: int }   // index -1: the desktop row
	items := make([dynamic]Item, 0, len(prefs.entries) + 1, context.temp_allocator)
	for e, i in prefs.entries { append(&items, Item{e.def.category, e.def.name, i}) }
	if with_desktop { append(&items, Item{"browser", "", -1}) }   // (first of its category)
	slice.sort_by(items[:], proc(a, b: Item) -> bool { return a.cat != b.cat ? a.cat < b.cat : a.name < b.name })

	// titles two preferences of a category share once their unit word is dropped: those keep it
	same := make(map[string]int, len(items), context.temp_allocator)
	for it in items {
		if it.index >= 0 { same[strings.concatenate({it.cat, "\x00", config.title_of(prefs.entries[it.index].def)}, context.temp_allocator)] += 1 }
	}

	filtering := query != "" || v.modified_only
	group := ""
	header := -1
	folded := false
	for it in items {
		if len(v.cats) == 0 || v.cats[len(v.cats) - 1].name != it.cat { append(&v.cats, Config_Cat{name = it.cat}) }
		c := &v.cats[len(v.cats) - 1]
		r := config.Ref(it.index)
		def: config.Def
		changed := false
		if it.index >= 0 {
			e := config.entry(prefs, r)
			def, changed = e.def, e.source != .Default
			c.total += 1
			if changed { c.modified += 1; v.modified += 1 }
			if v.modified_only && !changed { continue }
		} else {
			def = desktop_search_def()
			if v.modified_only { continue }
		}
		if !config.matches(def, query) { continue }
		if it.index >= 0 { c.shown += 1; v.shown += 1 }
		if v.category != "" && it.cat != v.category { continue }
		if v.category == "" && (header < 0 || it.cat != group) {
			group = it.cat
			folded = !filtering && v.collapsed[group]
			header = len(v.model)
			append(&v.model, Config_Row{kind = .Header, name = group, group = group})
			append(&v.ids, cfg_hash(CFG_HASH_SEED, "\x00group:") ~ cfg_hash(0x84222325cbf29ce4, group))
			append(&v.labels, config.category_title(group, context.allocator))
			append(&v.selectable, true)
		}
		if header >= 0 && it.index >= 0 { v.model[header].count += 1 }
		if folded { continue }
		if it.index < 0 {
			v.desktop_row = len(v.model)
			append(&v.model, Config_Row{kind = .Desktop, name = CONFIG_DESKTOP_ROW, group = it.cat})
			append(&v.ids, 0)   // config_page: from the row's note, at every frame
			append(&v.labels, config.title_of(def, context.allocator))
			append(&v.selectable, true)
			continue
		}
		append(&v.model, Config_Row{kind = .Pref, ref = r, name = it.name, group = it.cat})
		// what changes the row's height: its flags (source), an error shown under it, its details
		id := cfg_hash(CFG_HASH_SEED, it.name) ~ (u64(config.entry(prefs, r).source) << 56)
		if st, ok := v.rows[it.name]; ok {
			if st.error != "" { id = cfg_hash(id, st.error) }
			if st.expanded { id = cfg_hash(id, "\x00open") }
		}
		append(&v.ids, id)
		shared := same[strings.concatenate({it.cat, "\x00", config.title_of(def)}, context.temp_allocator)] > 1
		append(&v.labels, config.title_of(def, context.allocator, keep_unit = shared))
		append(&v.selectable, true)
	}
}

// Shows another category ("" = all): the list starts again from the top.
@(private)
config_set_category :: proc(v: ^Config_View, category: string) {
	if category == v.category { return }
	delete(v.category)
	v.category = strings.clone(category)
	ui.list_select(&v.list.list, -1)
	ui.vlist_scroll_to(&v.list, 0)
}

// Builds the page. `prefs` is the registry; changes go through `config.set_from_string` so every observer runs.
config_page :: proc(v: ^Config_View, prefs: ^config.Prefs) {
	with_desktop := desktop_available()
	query := strings.to_lower(strings.trim_space(ui.field_string(&v.search)), context.temp_allocator)
	if !v.started { v.started = true; v.list.sel = -1 }
	if query != v.model_query { ui.list_select(&v.list.list, -1); ui.vlist_scroll_to(&v.list, 0) }   // another search: from the top
	config_model(v, prefs, query, with_desktop)
	if v.desktop_row >= 0 {
		desktop_status_poll(the_app)
		note, _ := desktop_config_note()
		v.ids[v.desktop_row] = cfg_hash(CFG_HASH_SEED, "\x00desktop:") ~ cfg_hash(0x84222325cbf29ce4, note)
	}

	// the layout follows the page's width (last frame's: the same unless the window was resized)
	em := ui.font_size()
	page_w: f32 = 0
	if b := ui.prev_box("###config_page"); b != nil { page_w = b.size.x }
	v.narrow = page_w > 0 && page_w < em * SIDEBAR_FROM_EM
	list_w := page_w - (v.narrow ? 0 : em * SIDEBAR_EM)
	v.stacked = page_w > 0 && list_w < em * STACK_BELOW_EM
	v.editor_w = em * (v.narrow ? EDITOR_NARROW_EM : EDITOR_EM)
	text_room := list_w - em * (LEAD_EM + 1.0 + 2.4 + 0.6 + 1.2) - (v.stacked ? 0 : v.editor_w)
	v.text_w = page_w > 0 && text_room > em * TEXT_MAX_EM ? em * TEXT_MAX_EM : 0

	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		page := ui.build_box({.Draw_Background}, "###config_page")
		if ui.parent(page) {
			config_header(v)
			ui.hline(ui.fill())
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.row(.Start, {}, "###cfg_body") {
				if !v.narrow {
					config_sidebar(v)
					ui.next({width = ui.px(max(1, ui.scale())), height = ui.fill(), bg = ui.color("border")})
					ui.build_box({.Draw_Background}, "###cfg_split")
				}
				config_list(v, prefs)
			}
			config_list_keys(v, prefs)
		}
	}
}

@(private = "file")
config_header :: proc(v: ^Config_View) {
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.6))
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center, {}, "###cfg_head") {
		ui.spacer(ui.px(em * 1.0))
		if !v.narrow {   // (narrow: the tab says it)
			ui.next({width = ui.text_size(0), height = ui.pct(1), font_size = em * 1.25, text_pad = 0})
			ui.label(i18n.tr("Configuration###cfg_title"))
			ui.spacer(ui.px(em * 1.2))
		} else {
			// no room for the sidebar: its categories as a choice
			items := make([]string, len(v.cats) + 1, context.temp_allocator)
			items[0] = fmt.tprintf(i18n.tr("All (%d)"), v.shown)
			sel := 0
			for c, i in v.cats {
				items[i + 1] = fmt.tprintf("%s (%d)", config.category_title(c.name), c.shown)
				if c.name == v.category { sel = i + 1 }
			}
			ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 2))})
			ui.a11y({name = i18n.tr("Category")})
			if ui.dropdown("###cfg_cat_choice", items, &sel) { config_set_category(v, sel == 0 ? "" : v.cats[sel - 1].name) }
			ui.spacer(ui.px(em * 0.6))
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		ui.a11y({name = i18n.tr("Search the preferences"), shortcut = "Ctrl+F"})
		sres := ui.line_edit("###cfg_search", &v.search, v.narrow ? i18n.tr("Search (Ctrl+F)") : i18n.tr("Search by title, name or description (Ctrl+F)"))
		if v.focus_search { v.focus_search = false; ui.set_focus(sres.box.key); ui.field_select_all(&v.search) }
		if sres.focused && (ui.key_press(.Down) || sres.committed) { v.focus_list = true }
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.px(em * 3.8 + ui.text_width(ui.top_style().font, em, i18n.tr("Modified only"))), height = ui.px(ui.dense(em * 2))})
		ui.checkbox("###cfg_modified", i18n.tr("Modified only"), &v.modified_only)
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
		if ui.tags(v.show_keys ? "selected" : "ghost_button") {
			keys := ui.button(i18n.tr("Shortcuts###cfg_keys"))
			tip(keys, i18n.tr("Show the keyboard shortcuts of this page"))
			if keys.clicked { v.show_keys = !v.show_keys }
		}
		ui.spacer(ui.px(em * 1.0))
	}
	if v.show_keys {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Start, {}, "###cfg_help_row") {
			ui.spacer(ui.px(em * 1.0))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), text_pad = 0, font_size = em * 0.9})
				ui.paragraph(i18n.tr("Up / Down, Page Up / Down: move  \u00b7  Enter: edit, fold  \u00b7  Right / Left: details, fold (Ctrl: every group)  \u00b7  Escape: back to the list  \u00b7  Delete: reset  \u00b7  letters: jump to a title  \u00b7  Ctrl+F: search###cfg_help"))
			}
			ui.spacer(ui.px(em * 1.0))
		}
		ui.spacer(ui.px(em * 0.3))
	}
	ui.spacer(ui.px(em * 0.5))
}

// The categories: "All", then each one, with its count for the search (and the modified ones in the accent's colour).
@(private = "file")
config_sidebar :: proc(v: ^Config_View) {
	em := ui.font_size()
	// the active row is the category shown (a click or the keys move it, and that shows it)
	want := 0
	for c, i in v.cats { if c.name == v.category { want = i + 1 } }
	if !v.cat_list.focused || v.cat_list.sel < 0 { v.cat_list.sel = want }
	ui.next({width = ui.px(em * SIDEBAR_EM), height = ui.fill()})
	ui.a11y({name = i18n.tr("Categories")})
	if ui.list("###cfg_cats", &v.cat_list) {
		ui.spacer(ui.px(em * 0.4))
		cat_item(v, 0, i18n.tr("All"), v.shown, v.modified, false)
		for c, i in v.cats { cat_item(v, i + 1, config.category_title(c.name), c.shown, c.modified, c.shown == 0) }
		ui.spacer(ui.px(em * 0.4))
	}
	if v.cat_list.changed && v.cat_list.sel >= 0 {
		config_set_category(v, v.cat_list.sel == 0 ? "" : v.cats[v.cat_list.sel - 1].name)
	}
	// to the list at once: the keys that follow in this frame are the list's
	if v.cat_list.activated || (v.cat_list.focused && ui.key_press(.Right)) {
		ui.set_focus(v.list.key)
		if v.list.sel < 0 { ui.list_select(&v.list.list, 0) }
	}
}

@(private = "file")
cat_item :: proc(v: ^Config_View, i: int, title: string, shown, modified: int, empty: bool) {
	em := ui.font_size()
	ui.next({height = ui.px(ui.dense(em * 2)), radius = em * 0.35})
	row := ui.list_row(&v.cat_list, i, title)
	if ui.parent(row.box) {
		ui.spacer(ui.px(em * 0.8))
		label := fmt.tprintf("%s###cn_%d", title, i)
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
		if empty { if ui.tags("weak") { ui.label(label) } } else { ui.label(label) }
		if modified > 0 {
			modified_badge(fmt.tprintf("%d###cm_%d", modified, i))
			tip(row, fmt.tprintf(i18n.tr(modified, "%d not at its default", "%d not at their default"), modified))
			ui.spacer(ui.px(em * 0.4))
		}
		if ui.tags("weak") {
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0, font_size = em * 0.85})
			ui.label(fmt.tprintf("%d###cc_%d", shown, i))
		}
		ui.spacer(ui.px(em * 1.3))   // (clear of the scroll bar)
	}
}

// A count of modified preferences: the accent's tint behind the accent's colour, like the rows' dot.
@(private = "file")
modified_badge :: proc(text: string) {
	em := ui.font_size()
	accent := ui.color("accent")
	ui.next({width = ui.text_size(em * 0.3), height = ui.px(ui.dense(em * 1.25)), font_size = em * 0.78, radius = em * 0.62,
		fg = accent, bg = ui.tuned(draw.Color{accent.r, accent.g, accent.b, 0.20})})
	ui.build_box({.Draw_Text, .Draw_Background, .No_Text_Trunc}, text)
}

@(private = "file")
config_list :: proc(v: ^Config_View, prefs: ^config.Prefs) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.a11y({name = i18n.tr("Preferences")})
	if rows, ok := ui.vlist("###cfg_list", &v.list, v.ids[:], v.labels[:], v.selectable[:]); ok {
		if v.focus_list { v.focus_list = false; ui.set_focus(v.list.key); if v.list.sel < 0 { ui.list_select(&v.list.list, 0) } }
		for i in rows.first ..< rows.last {
			row := v.model[i]
			switch row.kind {
			case .Header:  group_header(v, i, row)
			case .Pref:    config_row(v, prefs, row.ref, config.entry(prefs, row.ref), i)
			case .Desktop: desktop_row(v, i)
			}
		}
		if len(v.model) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") {
				if ui.style({text_align = .Center}) {
					text := v.modified_only && v.model_query == "" ? i18n.tr("No preference is modified.###cfg_none") : i18n.tr("No preference matches.###cfg_none")
					if v.category != "" && v.shown > 0 {
						text = fmt.tprintf(i18n.tr("Nothing in %s; %d in the other categories.###cfg_none"), config.category_title(v.category), v.shown)
					}
					ui.label(text)
				}
			}
			if v.category != "" && v.shown > 0 {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
				if ui.row(.Center) {
					ui.spacer(ui.fill())
					ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.9))})
					if ui.button(i18n.tr("Show all categories###cfg_all")).clicked { config_set_category(v, "") }
					ui.spacer(ui.fill())
				}
			}
		}
	}
	when DEBUG_INPUT {
		if v.list.changed { debug_log(fmt.tprintf("cfg list sel %d of %d focused %v typed %q", v.list.sel, v.list.count, v.list.focused, string(v.list.typed[:v.list.typed_len]))) }
	}
}

@(private)
toggle_group :: proc(v: ^Config_View, group: string, fold: bool) {
	if fold == v.collapsed[group] { return }
	if fold {
		v.collapsed[strings.clone(group)] = true
	} else if k, ok := delete_key(&v.collapsed, group); ok {
		delete(k)
	}
	v.model_valid = false
}

@(private)
toggle_details :: proc(v: ^Config_View, name: string, open: bool) {
	st := row_for(v, name)
	if st.expanded == open { return }
	st.expanded = open
	v.serial += 1
}

@(private = "file")
group_header :: proc(v: ^Config_View, index: int, r: Config_Row) {
	em := ui.font_size()
	folded := v.collapsed[r.group] && v.model_query == "" && !v.modified_only
	ui.next({height = ui.px(ui.dense(em * 2.4))})
	row := ui.list_row(&v.list.list, index, v.labels[index])
	if ui.parent(row.box) {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("weak") { ui.icon(folded ? GLYPH_FORWARD : ui.ICON_DOWN, em * 1.4) }
		ui.spacer(ui.px(em * 0.2))
		ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0, font_size = em * 1.08})
		ui.label(fmt.tprintf("%s###grp_%s", v.labels[index], r.group))
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.85})
			ui.label(fmt.tprintf("%d###grpn_%s", r.count, r.group))
		}
	}
	if row.clicked { toggle_group(v, r.group, !folded) }
}

// What the keyboard does on the active row (after the list took the moves).
@(private = "file")
config_list_keys :: proc(v: ^Config_View, prefs: ^config.Prefs) {
	if (v.list.focused || v.cat_list.focused) && ui.key_press(.F, {.Ctrl}) { v.focus_search = true }
	if v.list.focused {
		if ui.key_press(.Left, {.Ctrl}) { for r in v.model { if r.kind == .Header { toggle_group(v, r.group, true) } } }
		if ui.key_press(.Right, {.Ctrl}) {
			for k in v.collapsed { delete(k) }
			clear(&v.collapsed)
			v.model_valid = false
		}
	}
	sel := v.list.sel
	if sel < 0 || sel >= len(v.model) { return }
	row := v.model[sel]
	switch row.kind {
	case .Header:
		folded := v.collapsed[row.group]
		if v.list.activated { toggle_group(v, row.group, !folded) }
		if v.list.focused && ui.key_press(.Left) { toggle_group(v, row.group, true) }
		if v.list.focused && ui.key_press(.Right) { toggle_group(v, row.group, false) }
		return
	case .Desktop:
		if v.list.activated && !desktop_config_busy() { desktop_toggle(the_app) }
		if v.list.focused && ui.key_press(.Left) { config_to_header(v, sel) }
		return
	case .Pref:
	}
	name := row.name
	st := row_for(v, name)
	if v.list.focused && ui.key_press(.Right) { toggle_details(v, name, true) }
	if v.list.focused && ui.key_press(.Left) {
		if st.expanded { toggle_details(v, name, false) } else { config_to_header(v, sel) }
		return
	}
	e := config.entry(prefs, row.ref)
	locked := e.locked || e.source == .Command_Line
	if v.list.activated && !locked {
		if e.def.kind == .Bool {
			config_apply(v, prefs, st, name, e.value.b ? "false" : "true")
		} else {
			st.want_focus = true
		}
	}
	if v.list.focused && !locked && e.source == .User && (ui.key_press(.Delete) || ui.key_press(.Backspace)) { config_reset(v, prefs, st, name) }
}

// To the header of the group of row `sel` (none when a single category is shown).
@(private = "file")
config_to_header :: proc(v: ^Config_View, sel: int) {
	for i := sel; i >= 0; i -= 1 { if v.model[i].kind == .Header { ui.list_select(&v.list.list, i); return } }
}

@(private)
config_apply :: proc(v: ^Config_View, prefs: ^config.Prefs, st: ^Row_State, name, text: string) {
	err := config.set_from_string(prefs, name, text, .User)
	had := st.error != ""
	delete(st.error)
	// what is allowed, beside why it was refused ("out of range: 100 to 1000000")
	msg := config.set_error_text(err)
	if r := config.ref_of(prefs, name); r != config.NO_REF {
		d := config.entry(prefs, r).def
		unit := d.unit != "" ? strings.concatenate({" ", d.unit}, context.temp_allocator) : ""
		#partial switch err {
		case .Out_Of_Range: if d.bounded { msg = fmt.tprintf("%s: %s to %s%s", msg, number_text(d.min, d.kind), number_text(d.max, d.kind), unit) }
		case .Not_A_Choice: msg = fmt.tprintf("%s: %s", msg, strings.join(d.choices, ", ", context.temp_allocator))
		}
	}
	st.error = err == .None ? "" : strings.clone(msg)
	if had || st.error != "" { v.serial += 1 }
}

@(private)
config_reset :: proc(v: ^Config_View, prefs: ^config.Prefs, st: ^Row_State, name: string) {
	config.reset(prefs, name)
	delete(st.synced); st.synced = ""
	if st.error != "" { v.serial += 1 }
	delete(st.error); st.error = ""
}

// The dot of a modified preference.
@(private = "file")
dot_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^draw.Color)(user)^
	r := b.rect
	d := min(r.max.x - r.min.x, r.max.y - r.min.y)
	m := draw.rect_center(r)
	draw.rect(dc, {{m.x - d * 0.5, m.y - d * 0.5}, {m.x + d * 0.5, m.y + d * 0.5}}, c, d * 0.5)
}

@(private = "file")
pill :: proc(text, tag, id: string) {
	em := ui.font_size()
	ui.spacer(ui.px(em * 0.5))
	if ui.tags(tag) {
		ui.next({width = ui.text_size(em * 0.35), height = ui.px(ui.dense(em * 1.25)), font_size = em * 0.78, radius = em * 0.62})
		ui.build_box({.Draw_Text, .Draw_Border, .No_Text_Trunc}, fmt.tprintf("%s###%s", text, id))
	}
}

// The sidebar's width, the page width from which it shows, and the list width under which editors go under their text.
@(private = "file")
SIDEBAR_EM :: 13.0
@(private = "file")
SIDEBAR_FROM_EM :: 50.0
@(private = "file")
STACK_BELOW_EM :: 40.0
// The width of the editor column (the value and the reset button).
@(private = "file")
EDITOR_EM :: 17.0
@(private = "file")
EDITOR_NARROW_EM :: 13.0
// The widest the text column gets (about 75 characters a line).
@(private = "file")
TEXT_MAX_EM :: 40.0
// The room left of the title: the modified dot's column.
@(private = "file")
LEAD_EM :: 1.6

@(private)
config_row :: proc(v: ^Config_View, prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry, index: int) {
	em := ui.font_size()
	name := e.def.name
	st := row_for(v, name)
	title := v.labels[index]
	summary, more := config.summary_of(e.def.description)

	row := ui.list_row(&v.list.list, index, title)
	ui.push_parent(row.box)
	defer ui.pop_parent()
	// the modified dot, in its own column so the titles line up
	ui.next({width = ui.px(em * LEAD_EM), height = ui.children_sum()})
	if ui.column(.Center) {
		ui.spacer(ui.px(em * 0.55 + ui.dense(em * 1.6) * 0.5 - em * 0.22))
		if e.source != .Default {
			c := ui.frame_new(draw.Color)
			if e.source == .User { c^ = ui.color("accent") } else if ui.tags("warn") { c^ = ui.color("text") }
			ui.next({width = ui.px(em * 0.44), height = ui.px(em * 0.44)})
			ui.custom(fmt.tprintf("###dot_%s", name), dot_draw, c)
		}
	}
	ui.next({width = v.text_w > 0 ? ui.px(v.text_w) : ui.fill(), height = ui.children_sum()})
	if ui.column() {
		ui.spacer(ui.px(em * 0.55))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
		if ui.row(.Center) {
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###t_%s", title, name))
			switch e.source {
			case .Command_Line, .Policy: pill(source_label(e), "warn", fmt.tprintf("src_%s", name))
			case .Default, .User:
			}
			if e.def.restart { pill(i18n.tr("restart"), "weak", fmt.tprintf("rst_%s", name)) }
		}
		// the dotted name (a click copies it), and the default while the value is another
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.35))})
		if ui.row(.Center) {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0, font_size = em * 0.84, font = ui.mono_font()})
				kb := ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###k_%s", name, name))
				kb.cursor = .Hand
				ks := ui.signal(kb)
				tip(ks, i18n.tr("Copy the name"))
				if ks.clicked { clip_set(name); ui.toast(.Info, i18n.tr("Copied %s"), name) }
				if e.source != .Default {
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.84})
					ui.label(fmt.tprintf("   \u00b7   %s###kd_%s", fmt.tprintf(i18n.tr("default %s"), shown_value(e.def, config.default_string(prefs, r))), name))
				}
			}
		}
		if ui.tags("weak") {
			if summary != "" {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###d_%s", summary, name))
			}
			if st.expanded {
				ui.spacer(ui.px(em * 0.3))
				if more != "" {
					ui.next({width = ui.fill(), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###m_%s", more, name))
					ui.spacer(ui.px(em * 0.25))
				}
				ui.next({width = ui.fill(), text_pad = 0, font_size = em * 0.88})
				ui.paragraph(fmt.tprintf("%s###f_%s", facts_line(prefs, r, e), name))
			}
		}
		if v.stacked {
			// a narrow list: the editor under the text
			ui.spacer(ui.px(em * 0.35))
			ui.tab_stops(index == v.list.sel)
			config_editor(v, prefs, r, e, st, title)
		}
		if st.error != "" {
			if ui.tags("bad") {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###err_%s", st.error, name))
			}
		}
		ui.spacer(ui.px(em * 0.55))
	}
	ui.spacer(ui.px(em * 1.0))

	// the editor column (Tab stops of the active row only: the list is one Tab stop)
	ui.tab_stops(index == v.list.sel)   // (deferred: popped at the end of the row)
	if !v.stacked {
		ui.next({width = ui.px(v.editor_w), height = ui.children_sum()})
		if ui.column() {
			ui.spacer(ui.px(em * 0.5))
			config_editor(v, prefs, r, e, st, title)
			ui.spacer(ui.px(em * 0.5))
		}
	}
	// the details fold
	ui.next({width = ui.px(em * 2.4), height = ui.children_sum()})
	if ui.column(.Center) {
		ui.spacer(ui.px(em * 0.55))
		ui.next({width = ui.px(em * 1.9), height = ui.px(ui.dense(em * 1.9)), radius = em * CHROME_BUTTON_RADIUS})
		ds := ui.icon_button(fmt.tprintf("###x_%s", name), st.expanded ? ui.ICON_UP : ui.ICON_DOWN)
		tip(ds, st.expanded ? i18n.tr("Hide the details (Left)") : i18n.tr("Show the details (Right)"))
		if ds.clicked { toggle_details(v, name, !st.expanded) }
	}
	ui.spacer(ui.px(em * 0.6))
}

// The value's editor (a switch, a choice, a field and its unit) and the reset button, on one line as wide as the
// parent gives.
@(private = "file")
config_editor :: proc(v: ^Config_View, prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry, st: ^Row_State, title: string) {
	em := ui.font_size()
	name := e.def.name
	locked := e.locked || e.source == .Command_Line
	id := fmt.tprintf("###cfg_%s", name)
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
	if ui.row(.Center) {
		if ui.disabled(locked) {
			ui.a11y({name = title})
			switch e.def.kind {
			case .Bool:
				val := e.value.b
				ui.next({width = ui.px(em * 3.4), height = ui.px(ui.dense(em * 2))})
				sig := ui.toggle(fmt.tprintf("%s###b", id), "", &val)
				st.editor = sig.box.key
				if sig.clicked { config_apply(v, prefs, st, name, val ? "true" : "false") }
				ui.spacer(ui.fill())
			case .String:
				if len(e.def.choices) > 0 {
					sel := 0
					for c, i in e.def.choices { if c == e.value.s { sel = i } }
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					dd_id := fmt.tprintf("%s###dd", id)
					if b := ui.prev_box(dd_id); b != nil { st.editor = b.key }
					if ui.dropdown(dd_id, e.def.choices, &sel) { config_apply(v, prefs, st, name, e.def.choices[sel]); v.focus_list = st.focused }
					if st.want_focus && st.editor != 0 { st.want_focus = false; ui.set_focus(st.editor) }
					st.focused = ui.focus_key() == st.editor && st.editor != 0
					if st.focused && ui.key_press(.Escape) { v.focus_list = true }
					break
				}
				fallthrough
			case .Int, .Float:
				current := config.value_string(prefs, r)
				// keep the field in step with the registry unless the user is typing in it
				if st.synced != current && !st.focused { ui.field_set(&st.field, current); delete(st.synced); st.synced = strings.clone(current) }
				number := e.def.kind != .String
				ui.next({width = number ? ui.px(em * 9) : ui.fill(), height = ui.px(ui.dense(em * 2))})
				res := ui.line_edit(fmt.tprintf("%s###e", id), &st.field, "")
				st.editor = res.box.key
				if st.want_focus { st.want_focus = false; ui.set_focus(res.box.key); ui.field_select_all(&st.field) }
				st.focused = res.focused
				if res.committed { config_apply(v, prefs, st, name, ui.field_string(&st.field)); delete(st.synced); st.synced = ""; v.focus_list = true }
				if res.cancelled { delete(st.synced); st.synced = ""; if st.error != "" { v.serial += 1 }; delete(st.error); st.error = ""; v.focus_list = true }
				if number {
					ui.spacer(ui.px(em * 0.5))
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
						ui.label(fmt.tprintf("%s###u_%s", e.def.unit, name))
					}
				}
			}
		}
		// reset: its room is kept when hidden, so the editors line up
		ui.spacer(ui.px(em * 0.3))
		if e.source == .User && !locked {
			ui.next({width = ui.px(em * 2), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
			rs := ui.icon_button(fmt.tprintf("###r_%s", name), GLYPH_RELOAD)
			tip(rs, i18n.tr("Reset to the default (Delete)"))
			if rs.clicked { config_reset(v, prefs, st, name) }
		} else {
			ui.spacer(ui.px(em * 2))
		}
	}
}

// The desktop integration's row: its title, what it touches, its state and buttons; the switch in the editor column.
@(private = "file")
desktop_row :: proc(v: ^Config_View, index: int) {
	em := ui.font_size()
	app := the_app
	row := ui.list_row(&v.list.list, index, v.labels[index])
	ui.push_parent(row.box)
	defer ui.pop_parent()
	ui.spacer(ui.px(em * LEAD_EM))
	ui.next({width = v.text_w > 0 ? ui.px(v.text_w) : ui.fill(), height = ui.children_sum()})
	if ui.column() {
		ui.spacer(ui.px(em * 0.55))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
		if ui.row(.Center) {
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###t_desktop", v.labels[index]))
			if v.stacked {
				ui.spacer(ui.fill())
				if ui.tab_stops(index == v.list.sel) { desktop_config_switch(app) }
			}
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.35))})
		if ui.row(.Center) {
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.84})
				ui.label(fmt.tprintf("%s###k_desktop", desktop_config_targets()))
			}
		}
		note, tone := desktop_config_note()
		if ui.tags(tone) {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(fmt.aprintf("%s###desktop_note", note, allocator = ui.frame_allocator()))
		}
		ui.spacer(ui.px(em * 0.3))
		ui.tab_stops(index == v.list.sel)
		desktop_config_buttons(app)
		ui.spacer(ui.px(em * 0.55))
	}
	ui.spacer(ui.px(em * 1.0))
	if v.stacked { return }
	ui.next({width = ui.px(v.editor_w), height = ui.children_sum()})
	ui.tab_stops(index == v.list.sel)
	if ui.column() {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
		if ui.row(.Center) { desktop_config_switch(app) }
	}
}
