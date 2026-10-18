package browser

// about:config: every preference of the browser, searchable and editable, built with the toolkit like the rest of the chrome.

import "core:fmt"
import "core:strings"
import "toolkit:ui"
import "wb:config"

Row_State :: struct {
	field:  ui.Text_Field,
	synced: string,   // the text the field was last synchronised with (owned)
	error:  string,   // owned, shown under the row after a rejected edit
	focused: bool,    // the field had keyboard focus in the previous frame
}

Config_View :: struct {
	search:        ui.Text_Field,
	modified_only: bool,
	rows:          map[string]^Row_State,
}

config_view_destroy :: proc(v: ^Config_View) {
	ui.field_destroy(&v.search)
	for k, r in v.rows { ui.field_destroy(&r.field); delete(r.synced); delete(r.error); free(r); delete(k) }
	delete(v.rows)
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
				ui.line_edit("###cfg_search", &v.search, "Search by name or description")
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 2))})
				ui.checkbox("###cfg_modified", "Modified only", &v.modified_only)
				ui.spacer(ui.px(em * 0.8))
			}
			ui.spacer(ui.px(em * 0.4))

			query := strings.to_lower(strings.trim_space(ui.field_string(&v.search)), context.temp_allocator)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###cfg_list") {
				shown := 0
				for name in config.sorted_names(prefs) {
					r := config.ref_of(prefs, name)
					e := config.entry(prefs, r)
					if v.modified_only && e.source == .Default { continue }
					if query != "" {
						hay := strings.to_lower(strings.concatenate({name, " ", e.def.description}, context.temp_allocator), context.temp_allocator)
						if !strings.contains(hay, query) { continue }
					}
					config_row(v, prefs, r, e)
					shown += 1
				}
				if shown == 0 {
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
					if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("No preference matches.") } }
				}
			}
		}
	}
}

@(private)
config_row :: proc(v: ^Config_View, prefs: ^config.Prefs, r: config.Ref, e: ^config.Entry) {
	em := ui.font_size()
	name := e.def.name
	st := row_for(v, name)
	locked := e.locked || e.source == .Command_Line
	id := fmt.tprintf("###cfg_%s", name)

	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3.0))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.8))
		// name + description
		ui.next({width = ui.px(em * 30), height = ui.px(ui.dense(em * 3.0))})
		if ui.column() {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
			label := fmt.tprintf("%s%s###n_%s", name, e.source != .Default ? "  *" : "", name)
			sig := ui.label(label)
			if ui.hovered_for(sig, 0.5) {
				if ui.tooltip() {
					ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 2))})
					ui.label(fmt.tprintf("%s###tt_%s", e.def.description, name))
				}
			}
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.3))})
				note := e.def.restart ? fmt.tprintf("%s%srestart required###d_%s", e.def.unit, e.def.unit != "" ? "  " : "", name) : fmt.tprintf("%s###d_%s", e.def.unit, name)
				ui.label(note)
			}
		}
		ui.spacer(ui.px(em * 0.6))

		// editor
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.disabled(locked) {
			if ui.row(.Center) {
				apply :: proc(prefs: ^config.Prefs, st: ^Row_State, name, text: string) {
					err := config.set_from_string(prefs, name, text, .User)
					delete(st.error)
					st.error = err == .None ? "" : strings.clone(config.set_error_text(err))
				}
				switch e.def.kind {
				case .Bool:
					val := e.value.b
					ui.next({width = ui.px(em * 3), height = ui.px(ui.dense(em * 2))})
					if ui.checkbox(fmt.tprintf("%s###b", id), "", &val).clicked { apply(prefs, st, name, val ? "true" : "false") }
				case .String:
					if len(e.def.choices) > 0 {
						sel := 0
						for c, i in e.def.choices { if c == e.value.s { sel = i } }
						ui.next({width = ui.px(em * 20), height = ui.px(ui.dense(em * 2))})
						if ui.dropdown(fmt.tprintf("%s###dd", id), e.def.choices, &sel) { apply(prefs, st, name, e.def.choices[sel]) }
						break
					}
					fallthrough
				case .Int, .Float:
					current := config.value_string(prefs, r)
					// keep the field in step with the registry unless the user is typing in it
					if st.synced != current && !st.focused { ui.field_set(&st.field, current); delete(st.synced); st.synced = strings.clone(current) }
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					res := ui.line_edit(fmt.tprintf("%s###e", id), &st.field, "")
					st.focused = res.focused
					if res.committed { apply(prefs, st, name, ui.field_string(&st.field)); delete(st.synced); st.synced = "" }
					if res.cancelled { delete(st.synced); st.synced = ""; delete(st.error); st.error = "" }
				}
			}
		}
		ui.spacer(ui.px(em * 0.6))

		// source and reset
		ui.next({width = ui.px(em * 9), height = ui.px(ui.dense(em * 2))})
		if ui.tags("weak") { ui.label(fmt.tprintf("%s###s_%s", source_label(e), name)) }
		ui.next({width = ui.px(em * 5), height = ui.px(ui.dense(em * 2))})
		if e.source == .User {
			if ui.button(fmt.tprintf("reset###r_%s", name)).clicked {
				config.reset(prefs, name)
				delete(st.synced); st.synced = ""
				delete(st.error); st.error = ""
			}
		} else { ui.spacer(ui.px(em * 5)) }
		ui.spacer(ui.px(em * 0.8))
	}
	if st.error != "" {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.4))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.8))
			ui.label(fmt.tprintf("%s: %s###err_%s", name, st.error, name))
		}
	}
}
