package browser

// about:config: every preference of the browser, searchable (name and description), grouped by its first name segment,
// editable, built with the toolkit like the rest of the chrome. Each row shows the name, the description (wrapped), the
// default, the bounds, the unit, "restart required" and where the value comes from (modified, command line, policy).
//
// Keyboard: the list is one Tab stop: Up / Down / Page Up / Page Down / Home / End move over the preferences, typing
// jumps to a name, Enter edits the active one (a check box toggles; a choice or a text field takes the focus: Enter
// applies, Escape goes back to the list), Delete resets it to its default. Ctrl+F (or Tab from the list backwards)
// reaches the search field.

import "core:fmt"
import "core:strings"
import "toolkit:ui"
import "wb:config"

Row_State :: struct {
	field:   ui.Text_Field,
	synced:  string,     // the text the field was last synchronised with (owned)
	error:   string,     // owned, shown under the row after a rejected edit
	focused: bool,       // the editor had keyboard focus in the previous frame
	editor:  ui.Key,     // the editor's box (last frame), for keyboard activation
	want_focus: bool,    // give the editor the focus at the next build
}

Config_View :: struct {
	search:        ui.Text_Field,
	modified_only: bool,
	rows:          map[string]^Row_State,
	list:          ui.List_State,
	names:         [dynamic]string,   // the rows of the last build, in order ("" = a group header); not owned
	focus_search:  bool,
	focus_list:    bool,
}

config_view_destroy :: proc(v: ^Config_View) {
	ui.field_destroy(&v.search)
	for k, r in v.rows { ui.field_destroy(&r.field); delete(r.synced); delete(r.error); free(r); delete(k) }
	delete(v.rows)
	ui.list_state_destroy(&v.list)
	delete(v.names)
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
	case .User: return "modified"
	case .Command_Line: return "command line"
	case .Policy: return "policy (locked)"
	}
	return ""
}

@(private = "file")
number_text :: proc(v: f64, kind: config.Kind) -> string {
	if kind == .Int { return fmt.tprintf("%d", i64(v)) }
	return fmt.tprintf("%g", v)
}

// "default 30000 ms · 0 to 3600000 ms · restart required"
@(private = "file")
facts_line :: proc(prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry) -> string {
	d := e.def
	parts := make([dynamic]string, context.temp_allocator)
	unit := d.unit != "" ? strings.concatenate({" ", d.unit}, context.temp_allocator) : ""
	def := config.default_string(prefs, r)
	if d.kind == .String && def == "" { def = "(empty)" }
	append(&parts, fmt.tprintf("default %s%s", def, d.kind == .Int || d.kind == .Float ? unit : ""))
	if d.bounded { append(&parts, fmt.tprintf("%s to %s%s", number_text(d.min, d.kind), number_text(d.max, d.kind), unit)) }
	if len(d.choices) > 0 { append(&parts, strings.concatenate({"one of ", strings.join(d.choices, ", ", context.temp_allocator)}, context.temp_allocator)) }
	if d.bytes { append(&parts, "K / M / G accepted") }
	if d.restart { append(&parts, "restart required") }
	return strings.join(parts[:], "  \u00b7  ", context.temp_allocator)
}

// Builds the page. `prefs` is the registry; changes go through `config.set_from_string` so every observer runs.
config_page :: proc(v: ^Config_View, prefs: ^config.Prefs) {
	em := ui.font_size()
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		page := ui.build_box({.Draw_Background}, "###config_page")
		if ui.parent(page) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
				ui.label("Configuration")
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
				sres := ui.line_edit("###cfg_search", &v.search, "Search by name or description (Ctrl+F)")
				if v.focus_search { v.focus_search = false; ui.set_focus(sres.box.key); ui.field_select_all(&v.search) }
				if sres.focused && (ui.key_press(.Down) || sres.committed) { v.focus_list = true }
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 2))})
				ui.checkbox("###cfg_modified", "Modified only", &v.modified_only)
				ui.spacer(ui.px(em * 0.8))
			}
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.label("Arrows, Page Up / Down: move   Enter: edit   Escape: back to the list   Delete: reset to the default   letters: jump to a name###cfg_help")
				}
			}
			ui.spacer(ui.px(em * 0.3))

			query := strings.to_lower(strings.trim_space(ui.field_string(&v.search)), context.temp_allocator)
			grouped := query == "" && !v.modified_only
			clear(&v.names)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.list("###cfg_list", &v.list) {
				if v.focus_list { v.focus_list = false; ui.set_focus(v.list.key); if v.list.sel < 0 { ui.list_select(&v.list, 0) } }
				shown := 0
				group := ""
				for name in config.sorted_names(prefs) {
					r := config.ref_of(prefs, name)
					e := config.entry(prefs, r)
					if v.modified_only && e.source == .Default { continue }
					if query != "" {
						hay := strings.to_lower(strings.concatenate({name, " ", e.def.description}, context.temp_allocator), context.temp_allocator)
						if !strings.contains(hay, query) { continue }
					}
					if grouped && e.def.category != group {
						group = e.def.category
						group_header(v, len(v.names), group)
						append(&v.names, "")
					}
					config_row(v, prefs, r, e, len(v.names))
					append(&v.names, name)
					shown += 1
				}
				if shown == 0 {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
					if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("No preference matches.") } }
				}
			}
			when DEBUG_INPUT {
				if v.list.changed { debug_log(fmt.tprintf("cfg list sel %d of %d (%q) focused %v typed %q", v.list.sel, v.list.count, v.list.sel >= 0 && v.list.sel < len(v.names) ? v.names[v.list.sel] : "", v.list.focused, string(v.list.typed[:v.list.typed_len]))) }
			}
			config_list_keys(v, prefs)
		}
	}
}

@(private = "file")
group_header :: proc(v: ^Config_View, index: int, group: string) {
	em := ui.font_size()
	ui.next({height = ui.px(ui.dense(em * 2.2))})
	row := ui.list_row(&v.list, index, group, selectable = false)
	if ui.parent(row.box) {
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			if ui.style({font_size = em * 0.95}) {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###grp_%s", strings.to_upper(group, context.temp_allocator), group))
			}
		}
	}
}

// What the keyboard does on the active row (after the list took the moves).
@(private = "file")
config_list_keys :: proc(v: ^Config_View, prefs: ^config.Prefs) {
	sel := v.list.sel
	if sel < 0 || sel >= len(v.names) || v.names[sel] == "" { return }
	name := v.names[sel]
	r := config.ref_of(prefs, name)
	e := config.entry(prefs, r)
	st := row_for(v, name)
	locked := e.locked || e.source == .Command_Line
	if v.list.activated && !locked {
		if e.def.kind == .Bool {
			config_apply(prefs, st, name, e.value.b ? "false" : "true")
		} else {
			st.want_focus = true
		}
	}
	if v.list.focused && !locked && e.source == .User && (ui.key_press(.Delete) || ui.key_press(.Backspace)) { config_reset(prefs, st, name) }
	if v.list.focused && ui.key_press(.F, {.Ctrl}) { v.focus_search = true }
}

@(private = "file")
config_apply :: proc(prefs: ^config.Prefs, st: ^Row_State, name, text: string) {
	err := config.set_from_string(prefs, name, text, .User)
	delete(st.error)
	st.error = err == .None ? "" : strings.clone(config.set_error_text(err))
}

@(private = "file")
config_reset :: proc(prefs: ^config.Prefs, st: ^Row_State, name: string) {
	config.reset(prefs, name)
	delete(st.synced); st.synced = ""
	delete(st.error); st.error = ""
}

@(private)
config_row :: proc(v: ^Config_View, prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry, index: int) {
	em := ui.font_size()
	name := e.def.name
	st := row_for(v, name)
	locked := e.locked || e.source == .Command_Line
	id := fmt.tprintf("###cfg_%s", name)

	row := ui.list_row(&v.list, index, name)
	ui.push_parent(row.box)
	defer ui.pop_parent()
	ui.spacer(ui.px(em * 0.8))
	// name, flags, description, facts
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.column() {
		ui.spacer(ui.px(em * 0.45))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
		if ui.row(.Center) {
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###n_%s", name, name))
			flag :: proc(text, tag, id: string) {
				em := ui.font_size()
				ui.spacer(ui.px(em * 0.5))
				if ui.tags(tag) {
					ui.next({width = ui.text_size(em * 0.3), height = ui.px(ui.dense(em * 1.3)), font_size = em * 0.82, radius = em * 0.65})
					ui.build_box({.Draw_Text, .Draw_Border, .No_Text_Trunc}, fmt.tprintf("%s###%s", text, id))
				}
			}
			if lbl := source_label(e); lbl != "" { flag(lbl, e.source == .User ? "accent" : "warn", fmt.tprintf("src_%s", name)) }
			if e.def.restart { flag("restart required", "weak", fmt.tprintf("rst_%s", name)) }
		}
		if ui.tags("weak") {
			if e.def.description != "" {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###d_%s", e.def.description, name))
			}
			if ui.style({font_size = em * 0.88}) {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###f_%s", facts_line(prefs, r, e), name))
			}
		}
		if st.error != "" {
			if ui.tags("bad") {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###err_%s", st.error, name))
			}
		}
		ui.spacer(ui.px(em * 0.45))
	}
	ui.spacer(ui.px(em * 0.8))

	// editor and reset (Tab stops of the active row only: the list is one Tab stop)
	ui.next({width = ui.px(em * 20), height = ui.children_sum()})
	ui.tab_stops(index == v.list.sel)   // (deferred: popped at the end of the row)
	if ui.column() {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.disabled(locked) {
			if ui.row(.Center) {
				switch e.def.kind {
				case .Bool:
					val := e.value.b
					ui.next({width = ui.px(em * 8), height = ui.px(ui.dense(em * 2))})
					sig := ui.checkbox(fmt.tprintf("%s###b", id), val ? "true" : "false", &val)
					st.editor = sig.box.key
					if sig.clicked { config_apply(prefs, st, name, val ? "true" : "false") }
				case .String:
					if len(e.def.choices) > 0 {
						sel := 0
						for c, i in e.def.choices { if c == e.value.s { sel = i } }
						ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
						dd_id := fmt.tprintf("%s###dd", id)
						if b := ui.prev_box(dd_id); b != nil { st.editor = b.key }
						if ui.dropdown(dd_id, e.def.choices, &sel) { config_apply(prefs, st, name, e.def.choices[sel]); v.focus_list = st.focused }
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
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					res := ui.line_edit(fmt.tprintf("%s###e", id), &st.field, "")
					st.editor = res.box.key
					if st.want_focus { st.want_focus = false; ui.set_focus(res.box.key); ui.field_select_all(&st.field) }
					st.focused = res.focused
					if res.committed { config_apply(prefs, st, name, ui.field_string(&st.field)); delete(st.synced); st.synced = ""; v.focus_list = true }
					if res.cancelled { delete(st.synced); st.synced = ""; delete(st.error); st.error = ""; v.focus_list = true }
				}
			}
		}
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
		if ui.row(.Center) {
			ui.spacer(ui.fill())
			if e.source == .User && !locked {
				ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
				if ui.tags("ghost_button") {
					if ui.button(fmt.tprintf("Reset to default###r_%s", name)).clicked { config_reset(prefs, st, name) }
				}
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	ui.spacer(ui.px(em * 0.8))
}
