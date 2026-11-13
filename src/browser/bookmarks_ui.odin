package browser

// What the user sees of the bookmarks (bookmarks.odin keeps them):
//   * the star at the end of the address bar: hollow for a page that is not a bookmark, filled for one. A click (or
//     Ctrl+D) makes the page a bookmark and opens the dialog that names it, moves it or removes it;
//   * about:bookmarks (Ctrl+Shift+O): the folders and bookmarks as a tree (a folder opens and closes with a click),
//     searchable (title and address, every folder); a click opens a bookmark in this tab, a middle click or Ctrl+click
//     in a new one; a row's menu (right click) opens, edits, moves (up, down, into a folder) or removes it, and opens
//     all the bookmarks of a folder. "Import" reads a bookmark file of any browser into them, "Export" writes them as
//     one (the Netscape format: bookmarks.odin);
//   * the palette lists them (prefix *).
// For tests (wren ctl, no person to answer): browser.dialogs.test_answer is the path the import and export dialogs choose.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import lucide "toolkit:lucide"
import "wb:config"
import "wb:host"
import "wb:i18n"

BOOKMARKS_URL :: "about:bookmarks"

is_bookmarks_address :: proc(a: string) -> bool { return a == BOOKMARKS_URL || strings.has_prefix(a, BOOKMARKS_URL + "#") }

Bookmarks_View :: struct {
	search:       ui.Line_Edit,
	search_key:   ui.Key,         // the search field's box, last frame (typing anywhere on the page goes to it: ui.type_to_field)
	focus_search: bool,
	list:         ui.Virtual_List,
	open:         map[u64]bool,   // the folders shown open
	bar:          Bookmarks_Bar_State,   // bookmarks_bar.odin
	menu_id:      u64,            // the bookmark whose row menu is open
	picking:      bool,           // an import or export dialog is open
	// the dialog that names a bookmark or a folder (edit_id 0 and edit_folder: a new folder)
	edit_open:    bool,
	edit_id:      u64,
	edit_folder:  bool,
	edit_parent:  u64,            // a new folder: where it goes (0: the top level)
	edit_title:   ui.Line_Edit,
	edit_url:     ui.Line_Edit,
	edit_focus:   bool,
}

bookmarks_ui_destroy :: proc(app: ^App) {
	v := &app.bview
	ui.line_edit_destroy(&v.search)
	ui.line_edit_destroy(&v.edit_title)
	ui.line_edit_destroy(&v.edit_url)
	ui.vlist_destroy(&v.list)
	delete(v.open)
	v^ = {}
}

show_bookmarks :: proc(app: ^App, t: ^Tab, address: string) {
	nav_show_view(app, t, .Bookmarks)
	layout_reset(&t.layout)
	console_reset(t)
	delete(t.url); t.url = strings.clone(address)
	delete(t.title); t.title = strings.clone(i18n.tr("Bookmarks"))
	set_status(t, BOOKMARKS_URL)
	app.bview.focus_search = true
}

// Ctrl+Shift+O, the menu: about:bookmarks in a new tab (or the tab already showing it).
open_bookmarks :: proc(app: ^App) {
	for x in tabs_all(app) {
		if x.kind == .Bookmarks { tab_reveal(app, x); return }
	}
	tab_open(app, BOOKMARKS_URL, origin = .User)
}

bookmark_open :: proc(app: ^App, t: ^Tab, address: string, new_tab: bool) {
	a := strings.clone(address, context.temp_allocator)
	if new_tab || t == nil { tab_open(app, a, origin = .User) } else { navigate(app, t, a, origin = .User) }
}

////////////////////////////////
// The star and the dialog

// The page of `t` can be a bookmark (a web page with an address that is not a script).
bookmarkable :: proc(t: ^Tab) -> bool { return t != nil && t.kind == .Web && bookmark_address_ok(t.url) && !strings.has_prefix(t.url, "about:") }

// The star's click and Ctrl+D: the page becomes a bookmark (if it is not one) and the dialog opens on it.
bookmark_star :: proc(app: ^App, t: ^Tab) {
	if !bookmarkable(t) { return }
	id, added := bookmark_page(app, t)
	if id == 0 { return }
	if added { announce(app, .Info, "Bookmark added") }
	bookmark_edit_open(app, id)
}

// Opens the dialog on the bookmark `id`.
bookmark_edit_open :: proc(app: ^App, id: u64) {
	i := bookmark_index(app.bms.items[:], id)
	if i < 0 { return }
	b := app.bms.items[i]
	v := &app.bview
	v.edit_open, v.edit_id, v.edit_folder, v.edit_focus = true, id, b.folder, true
	ui.line_edit_set(&v.edit_title, b.title)
	ui.line_edit_set(&v.edit_url, b.url)
	request_frames(app, 2)
}

// Opens the dialog for a new folder in `parent` (0: the top level).
bookmark_folder_new :: proc(app: ^App, parent: u64 = 0) {
	v := &app.bview
	v.edit_open, v.edit_id, v.edit_folder, v.edit_focus, v.edit_parent = true, 0, true, true, parent
	ui.line_edit_set(&v.edit_title, i18n.tr("New folder"))
	ui.line_edit_clear(&v.edit_url)
	request_frames(app, 2)
}

// A filled or hollow star, drawn (filled: the page is a bookmark).
@(private = "file")
Star_Look :: struct { color: draw.Color, filled: bool }

@(private = "file")
star_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	look := (^Star_Look)(user)
	c := draw.rect_center(b.rect)
	r := min(b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y) * 0.3
	pts: [11]draw.Vec2
	for k in 0 ..< 10 {
		a := -math.PI * 0.5 + f32(k) * math.PI / 5
		rr := k % 2 == 0 ? r : r * 0.45
		pts[k] = {c.x + rr * math.cos(a), c.y + rr * math.sin(a) + r * 0.08}
	}
	pts[10] = pts[0]
	if look.filled {
		// (a star is seen whole from its centre: a fan of triangles fills it)
		for k in 0 ..< 10 { draw.triangle(dc, {c.x, c.y + r * 0.08}, pts[k], pts[k + 1], look.color) }
	}
	draw.polyline(dc, pts[:], max(math.round(1.4 * ui.scale()), 1), look.color)
}

// The star at the end of the address bar.
bookmark_star_chip :: proc(app: ^App, t: ^Tab) {
	if !bookmarkable(t) { return }
	em := ui.font_size()
	on := bookmark_of_url(app.bms.items[:], t.url) >= 0
	s := math.round(ui.dense(em * 1.8))
	ui.spacer(ui.px(em * 0.2))
	ui.next({width = ui.px(s), height = ui.px(s), radius = em * CHROME_BUTTON_RADIUS})
	if ui.tags("ghost_button") {
		b := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, "###bookmark_star")
		look := ui.frame_new(Star_Look)
		look^ = {color = on ? ui.color("accent") : ui.color("text"), filled = on}
		b.custom, b.custom_user = star_draw, look
		ui.a11y_set(b, {role = .Button, name = on ? i18n.tr("Edit this bookmark") : i18n.tr("Bookmark this page"), toggled = on ? platform.A11y_Toggled.True : platform.A11y_Toggled.False})
		sig := ui.signal(b)
		tip(sig, on ? i18n.tr("Edit this bookmark (Ctrl+D)") : i18n.tr("Bookmark this page (Ctrl+D)"))
		if sig.clicked { bookmark_star(app, t) }
	}
}

// The dialog, each frame while it is open.
bookmarks_dialog_build :: proc(app: ^App) {
	v := &app.bview
	if !v.edit_open { return }
	i := bookmark_index(app.bms.items[:], v.edit_id)
	if v.edit_id != 0 && i < 0 { v.edit_open = false; return }   // (removed meanwhile)
	em := ui.font_size()
	open := true
	save, remove, cancel := false, false, false
	title := v.edit_folder ? (v.edit_id == 0 ? i18n.tr("New folder") : i18n.tr("Folder")) : i18n.tr("Bookmark")
	if ui.modal("bookmark_edit", &open, {width_em = 28}) {
		if ui.dialog_header("bm_edit_heading", title, {icon = v.edit_folder ? lucide.FOLDER : lucide.BOOKMARK, icon_font = app.lucide}) {}
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Start, {}, "###bm_edit_margins") {
			ui.spacer(ui.px(em * 1.0))
			ui.next({width = ui.fill(), height = ui.children_sum()})
			if ui.column(.Start, {}, "###bm_edit_col") {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
				tr := ui.line_edit("###bm_edit_title", &v.edit_title, {placeholder = i18n.tr("Name")})
				if v.edit_focus && tr.box != nil { v.edit_focus = false; ui.set_focus(tr.box.key); ui.line_edit_select_all(&v.edit_title) }
				if tr.committed { save = true }
				if tr.cancelled { cancel = true }
				if !v.edit_folder {
					ui.spacer(ui.px(em * 0.5))
					ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
					ur := ui.line_edit("###bm_edit_url", &v.edit_url, {placeholder = i18n.tr("Address")})
					if ur.committed { save = true }
					if ur.cancelled { cancel = true }
				}
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.row(.Center, {}, "###bm_edit_buttons") {
					if v.edit_id != 0 && ui.button("bm_edit_remove", i18n.tr("Remove"), lucide.TRASH_2, {intent = .Danger, width = ui.px(em * 7)}).clicked { remove = true }
					ui.spacer(ui.fill())
					if ui.button("bm_edit_cancel", i18n.tr("Cancel"), lucide.X, {intent = .Cancel, width = ui.px(em * 7)}).clicked { cancel = true }
					ui.spacer(ui.px(em * 0.5))
					if ui.button("bm_edit_save", i18n.tr("Save"), lucide.SAVE, {intent = .Success, width = ui.px(em * 7)}).clicked { save = true }
				}
				ui.spacer(ui.px(em * 0.8))
			}
			ui.spacer(ui.px(em * 1.0))
		}
	}
	switch {
	case remove:
		bookmark_remove_asked(app, v.edit_id)   // confirm_shell.odin: a folder that holds something is asked about
	case save:
		name := strings.trim_space(ui.line_edit_string(&v.edit_title))
		addr := strings.trim_space(ui.line_edit_string(&v.edit_url))
		if !v.edit_folder && !bookmark_address_ok(addr) { announce(app, .Warn, "That address cannot be a bookmark"); return }
		if v.edit_id == 0 {
			_ = bookmark_add(&app.bms.items, &app.bms.next_id, v.edit_parent, name != "" ? name : i18n.tr("New folder"), "", true, now_ms())
		} else {
			b := &app.bms.items[i]
			if name == "" { name = b.folder ? b.title : addr }
			if b.title != name { delete(b.title); b.title = strings.clone(name) }
			if !b.folder && b.url != addr { delete(b.url); b.url = strings.clone(addr) }
		}
		bookmarks_changed(app)
	}
	if !open || save || remove || cancel { v.edit_open = false; request_frames(app, 2) }
}

////////////////////////////////
// about:bookmarks

@(private = "file")
Bm_Row :: struct { index, depth: int }

// The rows shown: the tree with its open folders, or, while searching, every bookmark that matches.
@(private = "file")
bookmark_rows :: proc(app: ^App, query: string) -> []Bm_Row {
	items := app.bms.items[:]
	out := make([dynamic]Bm_Row, 0, len(items), context.temp_allocator)
	if query != "" {
		q := strings.to_lower(query, context.temp_allocator)
		for b, i in items {
			if b.folder { continue }
			if strings.contains(strings.to_lower(b.title, context.temp_allocator), q) || strings.contains(strings.to_lower(b.url, context.temp_allocator), q) {
				append(&out, Bm_Row{i, 0})
			}
		}
		return out[:]
	}
	add :: proc(app: ^App, out: ^[dynamic]Bm_Row, parent: u64, depth: int) {
		for b, i in app.bms.items {
			if b.parent != parent { continue }
			append(out, Bm_Row{i, depth})
			if b.folder && app.bview.open[b.id] { add(app, out, b.id, depth + 1) }
		}
	}
	add(app, &out, 0, 0)
	return out[:]
}

bookmarks_page :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	v := &app.bview
	menu_key := "###bm_row_menu"
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###bookmarks_page")
		if ui.parent(root) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
				ui.label(fmt.tprintf("%s###bm_title", i18n.tr("Bookmarks")))
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.px(em * 22), height = ui.px(ui.dense(em * 2))})
				if builtin_page_types(app) { _ = ui.type_to_field(v.search_key) }   // (just start typing to search)
				res := ui.line_edit("###bm_search", &v.search, {placeholder = i18n.tr("Search bookmarks")})
				if res.box != nil { v.search_key = res.box.key }
				if v.focus_search && res.box != nil { v.focus_search = false; ui.set_focus(res.box.key); ui.line_edit_select_all(&v.search) }
				if res.focused && ui.key_press(.Down) { ui.set_focus(v.list.key); if v.list.sel < 0 { ui.list_select(&v.list.list, 0) } }
				ui.spacer(ui.px(em * 0.6))
				if ui.button("bm_new_folder", i18n.tr("New folder"), lucide.FOLDER_PLUS, {intent = .Primary, width = ui.px(em * 7.5)}).clicked { bookmark_folder_new(app) }
				ui.spacer(ui.px(em * 0.4))
				ib := ui.button("bm_import", i18n.tr("Import…"), lucide.FOLDER_INPUT, {width = ui.px(em * 6.5)}).clicked
				if ib { bookmarks_import_pick(app) }
				ui.spacer(ui.px(em * 0.4))
				if ui.button("bm_export", i18n.tr("Export…"), lucide.FOLDER_OUTPUT, {width = ui.px(em * 6.5)}).clicked { bookmarks_export_pick(app) }
				ui.spacer(ui.fill())
				if ui.tags("weak") {
					n := 0
					for b in app.bms.items { if !b.folder { n += 1 } }
					ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 2))})
					ui.label(fmt.tprintf(n == 1 ? "%d bookmark###bm_count" : "%d bookmarks###bm_count", n))
				}
				ui.spacer(ui.px(em * 0.8))
			}
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.fill()})
			bookmarks_list(app, t, menu_key)
		}
	}
	if i := bookmark_index(app.bms.items[:], v.menu_id); i >= 0 {
		if ui.menu(menu_key) { bookmark_menu_items(app, t, i) }
	}
}

@(private = "file")
bookmarks_list :: proc(app: ^App, t: ^Tab, menu_key: string) {
	em := ui.font_size()
	v := &app.bview
	query := strings.trim_space(ui.line_edit_string(&v.search))
	rows := bookmark_rows(app, query)
	ids := make([]u64, len(rows), context.temp_allocator)
	labels := make([]string, len(rows), context.temp_allocator)
	for r, k in rows {
		b := app.bms.items[r.index]
		ids[k] = b.id ~ (u64(r.depth) << 56)
		labels[k] = b.title
	}
	open_at := -1
	new_tab := false
	if vr, ok := ui.vlist("###bm_list", &v.list, ids, labels); ok {
		for k in vr.first ..< vr.last {
			r := rows[k]
			b := app.bms.items[r.index]
			ui.next({height = ui.px(ui.dense(em * 2.2)), cursor = .Hand})
			row := ui.list_row(&v.list.list, k, labels[k])
			if ui.parent(row.box) {
				ui.spacer(ui.px(em * (0.6 + 1.4 * f32(r.depth))))
				ui.next({width = ui.px(em * 1.2), height = ui.pct(1), font = app.lucide, font_size = em * 0.9, text_pad = 0})
				if ui.tags("weak") { ui.label(fmt.tprintf("%s###bmc_%d", b.folder ? (v.open[b.id] ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT) : "", b.id)) }
				if tex, has := favicon_of_url(app, b.url); has && !b.folder {
					favicon_box(tex, fmt.tprintf("###bmi_%d", b.id), em * 1.6)
				} else {
					ui.next({width = ui.px(em * 1.6), height = ui.pct(1), font = app.lucide, font_size = em * 1.05, text_pad = 0})
					ui.label(fmt.tprintf("%s###bmi_%d", b.folder ? lucide.FOLDER : lucide.GLOBE, b.id))
				}
				ui.spacer(ui.px(em * 0.3))
				ui.next({width = b.folder ? ui.fill() : ui.pct(0.4), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###bmn_%d", safe_label(b.title, 120), b.id))
				if !b.folder {
					ui.spacer(ui.px(em * 0.8))
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.pct(1)})
						ui.label(fmt.tprintf("%s###bmu_%d", safe_label(b.url, 160), b.id))
					}
				}
				ui.spacer(ui.px(em * 0.5))
			}
			if row.clicked {
				if b.folder { v.open[b.id] = !v.open[b.id]; request_frames(app, 2) } else { open_at, new_tab = r.index, .Ctrl in row.mods }
			}
			if row.middle_clicked && !b.folder { open_at, new_tab = r.index, true }
			if row.right_clicked { v.menu_id = b.id; ui.menu_open(menu_key, ui.mouse_pos(), search = true) }   // (typing finds an item, a folder of Move to)
		}
		if len(rows) == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
			if ui.tags("weak") {
				if ui.style({text_align = .Center}) {
					ui.label(query != "" ? i18n.tr("No bookmark matches.###bm_none") : i18n.tr("No bookmark yet. The star of the address bar (Ctrl+D) keeps a page here; Import reads those of another browser.###bm_none"))
				}
			}
		}
	}
	// Enter on the active row
	if v.list.activated && v.list.sel >= 0 && v.list.sel < len(rows) {
		b := app.bms.items[rows[v.list.sel].index]
		if b.folder { v.open[b.id] = !v.open[b.id] } else { open_at = rows[v.list.sel].index }
	}
	if v.list.focused && ui.key_press(.Delete) && v.list.sel >= 0 && v.list.sel < len(rows) {
		bookmark_remove_asked(app, app.bms.items[rows[v.list.sel].index].id)
		return
	}
	if open_at >= 0 { bookmark_open(app, t, app.bms.items[open_at].url, new_tab) }
}

// The menu of a row (choosing an item closes it).
bookmark_menu_items :: proc(app: ^App, t: ^Tab, i: int) {
	b := app.bms.items[i]
	if b.folder {
		n := 0
		for x in app.bms.items { if x.parent == b.id && !x.folder { n += 1 } }
		if ui.menu_item(fmt.tprintf("%s###bmm_all", i18n.tr("Open all in new tabs")), disabled = !(n > 0), icon = lucide.FOLDER).clicked {
			urls := make([dynamic]string, 0, n, context.temp_allocator)
			for x in app.bms.items { if x.parent == b.id && !x.folder { append(&urls, strings.clone(x.url, context.temp_allocator)) } }
			for u in urls { tab_open(app, u, origin = .User) }
			return
		}
		if ui.menu_item(i18n.tr("Rename…"), icon = lucide.PENCIL).clicked { bookmark_edit_open(app, b.id); return }
	} else {
		if ui.menu_item(i18n.tr("Open"), icon = lucide.EXTERNAL_LINK).clicked { bookmark_open(app, t, b.url, false); return }
		if ui.menu_item(i18n.tr("Open in new tab"), icon = lucide.EXTERNAL_LINK).clicked { bookmark_open(app, t, b.url, true); return }
		if ui.menu_item(i18n.tr("Copy address"), icon = lucide.COPY).clicked { clip_set(b.url); return }
		if ui.menu_item(i18n.tr("Edit…"), icon = lucide.PENCIL).clicked { bookmark_edit_open(app, b.id); return }
	}
	ui.menu_separator()
	if ui.menu_item(i18n.tr("Move up"), icon = lucide.ARROW_UP).clicked { if bookmark_shift(&app.bms.items, b.id, -1) { bookmarks_changed(app) }; return }
	if ui.menu_item(i18n.tr("Move down"), icon = lucide.ARROW_DOWN).clicked { if bookmark_shift(&app.bms.items, b.id, 1) { bookmarks_changed(app) }; return }
	if ui.menu_submenu(fmt.tprintf("%s###bmm_move", i18n.tr("Move to")), icon = lucide.FOLDER) {
		if ui.menu_item(fmt.tprintf("%s###bmm_top", i18n.tr("Top level")), disabled = b.parent == 0, icon = lucide.FOLDER).clicked {
			if bookmark_move_into(&app.bms.items, b.id, 0) { bookmarks_changed(app) }
			ui.menu_close()
			return
		}
		for f in app.bms.items {
			if !f.folder || f.id == b.parent || bookmark_within(app.bms.items[:], f.id, b.id) { continue }
			if ui.menu_item(fmt.tprintf("%s###bmm_to_%d", safe_label(f.title, 60), f.id), icon = lucide.FOLDER).clicked {
				if bookmark_move_into(&app.bms.items, b.id, f.id) { bookmarks_changed(app) }
				ui.menu_close()
				return
			}
		}
	}
	ui.menu_separator()
	if ui.menu_item(b.folder ? i18n.tr("Remove the folder and its bookmarks\u2026") : i18n.tr("Remove"), icon = lucide.TRASH_2).clicked {
		bookmark_remove_asked(app, b.id)   // confirm_shell.odin: a folder that holds something is asked about
	}
}

////////////////////////////////
// Import and export

@(private = "file")
File_Job :: struct {
	app:    ^App,
	export: bool,
	test:   string,                  // browser.dialogs.test_answer when set
	owner:  ^platform.Window,
	text:   string,                  // export: what is written; import: what was read
	path:   string,
	ok:     bool,
	status: platform.Dialog_Status,
}

@(private = "file") HTML_FILTERS := []platform.File_Filter{{name = "Bookmarks (HTML)", patterns = {"*.html", "*.htm"}}}

// Import: a bookmark file chosen in the system's dialog, read on the blocking pool, merged into the bookmarks.
bookmarks_import_pick :: proc(app: ^App) { bookmarks_file_job(app, false) }

// Export: every bookmark, written to a file chosen in the system's dialog.
bookmarks_export_pick :: proc(app: ^App) { bookmarks_file_job(app, true) }

@(private = "file")
bookmarks_file_job :: proc(app: ^App, export: bool) {
	if app.bview.picking { return }
	app.bview.picking = true
	j := new(File_Job)
	j.app, j.export = app, export
	j.owner = active_window(app).win
	j.test = strings.clone(config.string_of(&app.prefs, "browser.dialogs.test_answer"))
	if export { j.text = strings.clone(bookmarks_serialize(app.bms.items[:], app.bms.toolbar)) }
	// (a thread of its own, host.run_dialog: the dialog holds it until the user answers)
	started := host.run_dialog(&app.dialogs, proc(data: rawptr) {
		j := (^File_Job)(data)
		path: string
		switch {
		case j.test == "cancel":
			j.status = .Cancelled
		case j.test != "":
			path, j.status = strings.clone(j.test), .Chosen
		case:
			d := platform.File_Dialog{owner = j.owner, filters = HTML_FILTERS, all_files = true, start_known = .Documents, remember_id = "bookmarks"}
			res: platform.Dialog_Result
			if j.export {
				d.title, d.suggested_name, d.default_ext, d.overwrite_prompt = "Export bookmarks", "bookmarks.html", "html", true
				res = platform.save_file_dialog(d)
			} else {
				d.title = "Import bookmarks"
				res = platform.open_file_dialog(d)
			}
			j.status = res.status
			if res.status == .Chosen && len(res.paths) > 0 { path = strings.clone(res.paths[0]) }
			platform.dialog_result_destroy(&res)
		}
		j.path = path
		if j.status != .Chosen || path == "" { return }
		if j.export {
			j.ok = os.write_entire_file(path, transmute([]byte)j.text) == nil
		} else {
			data, err := os.read_entire_file(path, context.allocator)
			j.ok = err == nil
			if j.ok { j.text = string(data) }
		}
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		j := (^File_Job)(data)
		app := j.app
		defer { delete(j.test); delete(j.text); delete(j.path); free(j) }
		app.bview.picking = false
		request_frames(app, 2)
		if j.status != .Chosen { return }
		if !j.ok { announce(app, .Bad, fmt.tprintf(j.export ? "The bookmarks could not be written to %s" : "%s could not be read", j.path)); return }
		if j.export {
			announce(app, .Info, "Bookmarks exported", j.path)
			return
		}
		added, ok := bookmarks_import(&app.bms.items, &app.bms.next_id, j.text, 0, now_ms(), &app.bms.toolbar)
		if !ok { announce(app, .Bad, fmt.tprintf("%s is not a bookmark file", j.path)); return }
		if added > 0 { bookmarks_changed(app) }
		announce(app, .Info, fmt.tprintf(added == 1 ? "%d bookmark imported" : "%d bookmarks imported", added))
	}, j, proc(data: rawptr) {   // (the browser ended before the answer was read)
		j := (^File_Job)(data)
		delete(j.test); delete(j.text); delete(j.path); free(j)
	})
	if !started {
		app.bview.picking = false
		announce(app, .Bad, "The file dialog could not be opened")
		delete(j.test); delete(j.text); free(j)
	}
}

////////////////////////////////
// The palette

@(private = "file")
palette_bookmark_items :: proc(user: rawptr, app: ^App, out: ^[dynamic]Palette_Item) {
	for b in app.bms.items { if !b.folder { append(out, Palette_Item{title = b.title, detail = b.url, key = b.url, site = b.url}) } }
}

@(private = "file")
palette_bookmark_activate :: proc(user: rawptr, app: ^App, key: string, new_tab: bool) {
	bookmark_open(app, current_tab(app), key, new_tab)
}

bookmarks_palette_source :: proc() -> Palette_Source {
	return {name = "Bookmarks", prefix = '*', in_default = true, items = palette_bookmark_items, activate = palette_bookmark_activate,
		version = proc(user: rawptr, app: ^App) -> u64 { return app.bms.serial }}
}

// Whether what is typed on a built-in page can go to its search field: no menu, dialog or palette takes it.
builtin_page_types :: proc(app: ^App) -> bool {
	return !ui.menu_any_open() && !app.bview.edit_open && !app.cpal.open && !setup_is_open(app) && app.qr_url == ""
}
