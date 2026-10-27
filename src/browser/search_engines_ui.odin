package browser

// The search engines in about:config (category Search): a row of the list with every engine (its badge, name, keyword,
// address), the default one marked, and per engine: make it the default, edit, move up or down, remove. Under them:
// "Add a search engine" and "Restore the built-in engines". Editing (or adding) opens a form in place: name, keyword,
// address with %s; Enter or Save applies it (checked: engine_validate), Escape or Cancel leaves it. Every change is
// written to the profile at once (search_engines_changed). Also the engines' badges of the address bar.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:config"
import "wb:i18n"

SEARCH_ENGINE_PREF :: "browser.search.engine"
// The name of the search engines' row (search, labels): it has no preference of its own.
CONFIG_ENGINES_ROW :: "browser.search.engines"

Engines_Editor :: struct {
	edit:          int,             // the engine being edited, index + 1; -1: a new one; 0: none
	name, keyword, url: ui.Text_Field,
	error:         Engine_Error,
	want_focus:    bool,
}

engines_editor_destroy :: proc(ed: ^Engines_Editor) {
	ui.field_destroy(&ed.name); ui.field_destroy(&ed.keyword); ui.field_destroy(&ed.url)
	ed^ = {}
}

// The engines' row as the search of about:config sees it.
engines_search_def :: proc() -> config.Def {
	return {name = CONFIG_ENGINES_ROW, category = "search", kind = .String,   // title: "Engines"
		description = "The search engines of the address bar and of the context menu: name, address, keyword (\"@g cats\" searches cats with Google); add, edit, remove, choose the default."}
}

// The names and ids of the engines, for the default's choice.
engines_choices :: proc() -> (names, ids: []string) {
	names = make([]string, len(sengines.list), context.temp_allocator)
	ids = make([]string, len(sengines.list), context.temp_allocator)
	for e, i in sengines.list { names[i], ids[i] = e.name, e.id }
	return
}

// What changes the row's height: the list, the form and its error, the default.
engines_row_id :: proc(ed: ^Engines_Editor) -> u64 {
	h := u64(0x9e3779b97f4a7c15) ~ sengines.serial * 0x100000001b3
	h = (h ~ u64(ed.edit + 2)) * 0x100000001b3
	h = (h ~ u64(ed.error)) * 0x100000001b3
	h = (h ~ u64(search_default_index() + 2)) * 0x100000001b3
	return h
}

// Opens the form for engine `i` (-1: a new one).
engines_edit_start :: proc(ed: ^Engines_Editor, i: int) {
	ed.error = .None
	ed.want_focus = true
	if i >= 0 && i < len(sengines.list) {
		e := sengines.list[i]
		ed.edit = i + 1
		ui.field_set(&ed.name, e.name); ui.field_set(&ed.keyword, e.keyword); ui.field_set(&ed.url, e.url)
	} else {
		ed.edit = -1
		ui.field_set(&ed.name, ""); ui.field_set(&ed.keyword, ""); ui.field_set(&ed.url, "https://")
	}
}

// Save of the form: the engine changed or added, or the reason it is refused (the form stays).
engines_edit_apply :: proc(app: ^App, ed: ^Engines_Editor) -> bool {
	self := ed.edit > 0 ? ed.edit - 1 : -1
	name, kw, url := ui.field_string(&ed.name), ui.field_string(&ed.keyword), ui.field_string(&ed.url)
	ed.error = engine_validate(&sengines, self, name, kw, url)
	if ed.error != .None { return false }
	if self >= 0 { engines_update(&sengines, self, name, kw, url) } else { _ = engines_add(&sengines, name, kw, url) }
	ed.edit = 0
	search_engines_changed(app)
	return true
}

// A round badge with the engine's initial, in a colour of its own (from its name).
engine_badge :: proc(id: string, e: Search_Engine, size: f32, clickable := false, selected := false) -> ui.Signal {
	PALETTE := [?]draw.Color{
		{0.60, 0.12, 0.05, 1}, {0.03, 0.20, 0.55, 1}, {0.04, 0.32, 0.10, 1}, {0.25, 0.10, 0.50, 1},
		{0.50, 0.25, 0.01, 1}, {0.02, 0.28, 0.30, 1}, {0.50, 0.06, 0.20, 1}, {0.14, 0.16, 0.22, 1},
	}
	h := u32(2166136261)
	for c in transmute([]u8)e.name { h = (h ~ u32(c)) * 16777619 }
	flags: ui.Box_Flags = {.Draw_Background, .Draw_Text, .No_Text_Trunc}
	if clickable { flags += {.Clickable, .Draw_Hot_Effects} }
	if selected { flags += {.Draw_Border} }
	ui.next({width = ui.px(size), height = ui.px(size), radius = size * 0.5, font_size = math.round(size * 0.55), text_pad = 0,
		text_align = .Center, bg = PALETTE[h % len(PALETTE)], fg = draw.Color{1, 1, 1, 1},
		border = ui.color("accent"), cursor = clickable ? .Hand : .Arrow})
	return ui.signal(ui.build_box(flags, fmt.tprintf("%s%s", engine_initial(e), id)))
}

// The row of about:config.
engines_row :: proc(v: ^Config_View, index: int) {
	em := ui.font_size()
	app := the_app
	ed := &v.engines
	row := ui.list_row(&v.list.list, index, v.labels[index])
	ui.push_parent(row.box)
	defer ui.pop_parent()
	ui.spacer(ui.px(em * 1.6))   // (LEAD_EM: the titles line up)
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.column() {
		ui.spacer(ui.px(em * 0.55))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
		if ui.row(.Center) {
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###t_engines", i18n.tr("Search engines")))
		}
		if ui.tags("weak") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(i18n.tr("Words typed in the address bar that are not an address go to the default engine; a keyword first (\"@g cats\") picks another, and so does Ctrl+Up / Down in the suggestions. The context menu searches selected text with the default.###engines_help"))
		}
		ui.spacer(ui.px(em * 0.4))
		ui.tab_stops(index == v.list.sel)
		def := search_default_index()
		action, target := 0, -1   // 1 default, 2 edit, 3 up, 4 down, 5 remove
		for e, i in sengines.list {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
			if ui.row(.Center, {}, fmt.tprintf("###eng_%d", i)) {
				engine_badge(fmt.tprintf("###eb_%d", i), e, math.round(em * 1.5))
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.px(em * 9), height = ui.pct(1), text_pad = 0, flags = {.Clip}})
				ui.label(fmt.tprintf("%s###en_%d", e.name, i))
				if ui.tags("weak") {
					ui.next({width = ui.px(em * 4), height = ui.pct(1), text_pad = 0, font = ui.mono_font(), font_size = em * 0.88, flags = {.Clip}})
					ui.label(fmt.tprintf("%s###ek_%d", e.keyword != "" ? e.keyword : "\u2014", i))
					ui.spacer(ui.px(em * 0.4))
					ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.88, flags = {.Clip}})
					ui.label(fmt.tprintf("%s###eu_%d", e.url, i))
				}
				ui.spacer(ui.px(em * 0.5))
				// the default: a pill; the others: a button to make it so (as wide, so the buttons line up)
				ui.next({width = ui.px(em * 8), height = ui.px(ui.dense(em * 1.8))})
				if i == def {
					if ui.tags("selected") {
						ui.next({width = ui.px(em * 8), height = ui.px(ui.dense(em * 1.5)), font_size = em * 0.85, radius = em * 0.75, text_align = .Center})
						ui.build_box({.Draw_Text, .Draw_Background, .No_Text_Trunc}, fmt.tprintf("%s###ed_%d", i18n.tr("Default"), i))
					}
				} else if ui.tags("ghost_button") {
					s := ui.button(fmt.tprintf("%s###ed_%d", i18n.tr("Make default"), i))
					if s.clicked { action, target = 1, i }
				}
				ui.spacer(ui.px(em * 0.3))
				btn :: proc(id, glyph, tooltip: string, enabled := true) -> bool {
					em := ui.font_size()
					ui.next({width = ui.px(em * 1.9), height = ui.px(ui.dense(em * 1.9)), radius = em * CHROME_BUTTON_RADIUS})
					clicked := false
					if ui.disabled(!enabled) {
						s := ui.icon_button(id, glyph)
						tip(s, tooltip)
						clicked = s.clicked && enabled
					}
					return clicked
				}
				ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
				if ui.tags("ghost_button") { if ui.button(fmt.tprintf("%s###ee_%d", i18n.tr("Edit"), i)).clicked { action, target = 2, i } }
				if btn(fmt.tprintf("###eup_%d", i), ui.ICON_UP, i18n.tr("Move up"), i > 0) { action, target = 3, i }
				if btn(fmt.tprintf("###edn_%d", i), ui.ICON_DOWN, i18n.tr("Move down"), i + 1 < len(sengines.list)) { action, target = 4, i }
				if btn(fmt.tprintf("###erm_%d", i), GLYPH_CLOSE, i18n.tr("Remove"), len(sengines.list) > 1) { action, target = 5, i }
				ui.spacer(ui.px(em * 0.6))
			}
			if ed.edit == i + 1 { engines_form(app, ed) }
		}
		if ed.edit < 0 { engines_form(app, ed) }
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
		if ui.row(.Center, {}, "###eng_actions") {
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.9))})
			if ui.button(i18n.tr("Add a search engine###eng_add")).clicked { engines_edit_start(ed, -1) }
			ui.spacer(ui.px(em * 0.6))
			missing := engines_missing_builtins(&sengines)
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.9))})
			if ui.disabled(missing == 0) {
				label := missing > 0 ? fmt.tprintf(i18n.tr("Restore the built-in engines (%d)###eng_restore"), missing) : i18n.tr("Restore the built-in engines###eng_restore")
				if ui.button(label).clicked && missing > 0 { engines_restore_builtins(&sengines); search_engines_changed(app) }
			}
		}
		ui.spacer(ui.px(em * 0.55))
		switch action {
		case 1: search_set_default(app, target)
		case 2: engines_edit_start(ed, target)
		case 3, 4: engines_move(&sengines, target, action == 3 ? -1 : 1); if ed.edit > 0 { ed.edit = 0 }; search_engines_changed(app)
		case 5:
			if ed.edit > 0 { ed.edit = 0 }
			engines_remove(&sengines, target)
			search_engines_changed(app)
		}
	}
	ui.spacer(ui.px(em * 1.0))
}

// The form of an engine being edited or added.
@(private = "file")
engines_form :: proc(app: ^App, ed: ^Engines_Editor) {
	em := ui.font_size()
	ui.push_tags("card")
	ui.next({width = ui.fill(), height = ui.children_sum(), radius = em * 0.4})
	form := ui.column(.Start, {.Draw_Background, .Draw_Border}, "###eng_form")
	ui.pop_tags()
	if form {
		ui.spacer(ui.px(em * 0.5))
		committed, cancelled := false, false
		field :: proc(id, label, placeholder: string, f: ^ui.Text_Field, w: ui.Size, focus: bool) -> ui.Edit_Result {
			em := ui.font_size()
			if ui.tags("weak") {
				ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0})
				ui.label(label)
			}
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = w, height = ui.px(ui.dense(em * 2))})
			ui.a11y({name = strings.split_n(label, "###", 2, context.temp_allocator)[0]})
			res := ui.line_edit(id, f, placeholder)
			if focus { ui.set_focus(res.box.key); ui.field_select_all(f) }
			return res
		}
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center, {}, "###eng_f1") {
			ui.spacer(ui.px(em * 0.6))
			r1 := field("###ef_name", i18n.tr("Name###efl_name"), i18n.tr("Example"), &ed.name, ui.px(em * 12), ed.want_focus)
			ui.spacer(ui.px(em * 1.0))
			r2 := field("###ef_kw", i18n.tr("Keyword###efl_kw"), "@x", &ed.keyword, ui.px(em * 6), false)
			ui.spacer(ui.px(em * 0.6))
			committed = r1.committed || r2.committed
			cancelled = r1.cancelled || r2.cancelled
		}
		ed.want_focus = false
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center, {}, "###eng_f2") {
			ui.spacer(ui.px(em * 0.6))
			r3 := field("###ef_url", i18n.tr("Address###efl_url"), "https://example.com/search?q=%s", &ed.url, ui.fill(), false)
			ui.spacer(ui.px(em * 0.6))
			committed ||= r3.committed
			cancelled ||= r3.cancelled
		}
		if ed.error != .None {
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.row(.Start, {}, "###eng_ferr") {
				ui.spacer(ui.px(em * 0.6))
				if ui.tags("bad") {
					ui.next({width = ui.fill(), text_pad = 0})
					ui.paragraph(fmt.tprintf("%s###ef_err", i18n.tr(engine_error_text(ed.error))))
				}
			}
		}
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center, {}, "###eng_f3") {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.9))})
			if ui.tags("accent_button") { if ui.button(ed.edit < 0 ? i18n.tr("Add###ef_save") : i18n.tr("Save###ef_save")).clicked { committed = true } }
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.9))})
			if ui.button(i18n.tr("Cancel###ef_cancel")).clicked { cancelled = true }
		}
		ui.spacer(ui.px(em * 0.5))
		if cancelled { ed.edit, ed.error = 0, .None }
		else if committed { _ = engines_edit_apply(app, ed) }
	}
}

// The address bar's "This time, search with": a badge per engine, the one the search rows use marked; the engine
// clicked (-1: none).
urlbar_engine_row :: proc(uv: ^Urlbar_View, w, h, pad: f32) -> int {
	em := ui.font_size()
	picked := -1
	cur, _ := urlbar_search_of(uv)
	ui.next({width = ui.px(w), height = ui.px(h), axis = .X, cross = .Center, flags = {.Clip}})
	if ui.row(.Center, {}, "###ub_engines") {
		ui.spacer(ui.px(pad + em * 0.5))
		if ui.tags("weak") {
			ui.next({width = ui.text_size(0), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
			ui.label(i18n.tr("This time, search with:###ub_sw"))
		}
		ui.spacer(ui.px(em * 0.6))
		for e, i in sengines.list {
			s := engine_badge(fmt.tprintf("###ube_%d", i), e, math.round(em * 1.5), clickable = true, selected = i == cur)
			tip(s, e.keyword != "" ? fmt.tprintf("%s  (%s)", e.name, e.keyword) : e.name)
			if s.clicked { picked = i }
			ui.spacer(ui.px(em * 0.35))
		}
	}
	return picked
}
