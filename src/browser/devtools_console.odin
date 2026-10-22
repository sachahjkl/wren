package browser

// The Console tab: the tab's messages (t.console, filled by tab_log) one per row, colored by level; a toolbar with Clear,
// Pause, the level filter and a text filter; rows that are selected (a click, Shift+click for a range, Ctrl+A) and copied (Ctrl+C,
// the context menu); the "run JavaScript" line at the bottom (console_eval.odin). The list follows the end while it is at the end.
//
// A line of t.console is "error: ...", "warn: ..." or the message as it is (tab_log); the rows keep that order. Pause
// freezes the list at the lines it had; they go on arriving in t.console.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"

Con_Level :: enum u8 { Log, Warn, Error }

Dev_Console :: struct {
	list:     ui.Virtual_List,
	ids:      [dynamic]u64,        // the rows' identities: the absolute number of their line
	rows:     [dynamic]int,        // their index in t.console
	key_tab:  u64,                 // what `rows` was made for
	key_added: u64,
	key_len:  int,
	key_mask: u32,
	key_query: string,             // owned
	key_stop: u64,
	mask:     u32,                 // levels shown, bit per Con_Level (chips)
	mask_set: bool,
	search:   ui.Text_Field,
	paused:   bool,
	stop:     u64,                 // paused: the lines from this absolute number on are not shown
	has_sel:  bool,
	sel_a, sel_b: u64,             // the selected rows: from one to the other (absolute numbers), either order
	menu_row: u64,
	stay:     bool,               // the user scrolled away from the end: the list does not follow it
	last_rows: int,
}

console_panel_destroy :: proc() {
	c := &dev.con
	ui.vlist_destroy(&c.list)
	delete(c.ids)
	delete(c.rows)
	delete(c.key_query)
	ui.field_destroy(&c.search)
	c^ = {}
}

// "error: x" -> (.Error, "x").
con_split :: proc(line: string) -> (Con_Level, string) {
	if strings.has_prefix(line, "error: ") { return .Error, line[7:] }
	if strings.has_prefix(line, "warn: ") { return .Warn, line[6:] }
	return .Log, line
}

// The absolute number of line `i` of t.console: it never changes while the line lives, whatever was dropped before it.
con_abs :: proc(t: ^Tab, i: int) -> u64 { return t.console_added - u64(len(t.console)) + u64(i) }

@(private = "file")
con_color :: proc(l: Con_Level) -> Maybe(draw.Color) {
	switch l {
	case .Error: return draw.Color{0.97, 0.45, 0.42, 1}
	case .Warn:  return draw.Color{0.96, 0.76, 0.32, 1}
	case .Log:   return nil
	}
	return nil
}

@(private = "file")
con_selected :: proc(c: ^Dev_Console, id: u64) -> bool {
	if !c.has_sel { return false }
	lo, hi := math.min(c.sel_a, c.sel_b), math.max(c.sel_a, c.sel_b)
	return id >= lo && id <= hi
}

// The text of the lines shown, or of the selected ones, one per line.
@(private = "file")
con_text :: proc(t: ^Tab, c: ^Dev_Console, only_selected: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for idx, k in c.rows {
		if only_selected && !con_selected(c, c.ids[k]) { continue }
		if n > 0 { strings.write_byte(&b, '\n') }
		strings.write_string(&b, t.console[idx])
		n += 1
	}
	return strings.to_string(b)
}

@(private = "file")
con_selected_count :: proc(c: ^Dev_Console) -> int {
	n := 0
	for id in c.ids { if con_selected(c, id) { n += 1 } }
	return n
}

// The rows for the tab, the levels and the text: made again only when one of them changed.
@(private = "file")
con_refresh :: proc(t: ^Tab, c: ^Dev_Console) {
	query := strings.trim_space(ui.field_string(&c.search))
	if c.key_tab == t.id && c.key_added == t.console_added && c.key_len == len(t.console) && c.key_mask == c.mask && c.key_query == query && c.key_stop == (c.paused ? c.stop : 0) { return }
	c.key_tab, c.key_added, c.key_len, c.key_mask, c.key_stop = t.id, t.console_added, len(t.console), c.mask, c.paused ? c.stop : 0
	delete(c.key_query)
	c.key_query = strings.clone(query)
	clear(&c.rows)
	clear(&c.ids)
	q := strings.to_lower(query, context.temp_allocator)
	for line, i in t.console {
		id := con_abs(t, i)
		if c.paused && id >= c.stop { break }
		level, text := con_split(line)
		if c.mask & (1 << u32(level)) == 0 { continue }
		if q != "" && !strings.contains(strings.to_lower(text, context.temp_allocator), q) { continue }
		append(&c.rows, i)
		append(&c.ids, id)
	}
}

// A line for a label: one line, cut at `max_runes`, with nothing in it the toolkit reads as an id ("###").
dev_line :: proc(s: string, max_runes := 500) -> string {
	out := s
	if strings.contains(out, "###") { out, _ = strings.replace_all(out, "###", "#\u200b##", context.temp_allocator) }
	if strings.contains_any(out, "\r\n\t") {
		out, _ = strings.replace_all(out, "\r\n", " \u00b6 ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\n", " \u00b6 ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\r", " ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\t", "  ", context.temp_allocator)
	}
	n := 0
	for _, i in out {
		if n == max_runes { return strings.concatenate({out[:i], "\u2026"}, context.temp_allocator) }
		n += 1
	}
	return out
}

@(private = "file")
con_row_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	draw.rect(dc, b.rect, (^draw.Color)(user)^)
}

console_panel :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	c := &dev.con
	if !c.mask_set { c.mask, c.mask_set = 0b111, true }

	// toolbar
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1))})
	if ui.row(.Center, {}, "###dt_con_bar") {
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
		if ui.button("Clear###dt_con_clear").clicked { console_clear(app, t) }
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(em * 0.8), height = ui.px(ui.dense(em * 1.8))})
		if ui.button(fmt.tprintf("%s###dt_con_pause", c.paused ? "Resume" : "Pause")).clicked {
			c.paused = !c.paused
			c.stop = t.console_added
		}
		ui.spacer(ui.px(em * 0.6))
		labels := [?]string{"Log", "Warn", "Error"}
		ui.next({width = ui.children_sum(), height = ui.px(ui.dense(em * 1.8))})
		ui.chips("###dt_con_levels", labels[:], &c.mask)
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
		ui.line_edit("###dt_con_filter", &c.search, "Filter")
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("weak") {
			ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
			ui.label(fmt.tprintf("%d / %d###dt_con_count", len(c.rows), len(t.console)))
		}
		ui.spacer(ui.px(em * 0.4))
	}

	con_refresh(t, c)
	n := len(c.rows)

	// follow the end while the view was there
	grew := n > c.last_rows
	if grew && !c.stay { dev_scroll_end(&c.list, n) }
	c.last_rows = n

	ui.next({width = ui.fill(), height = ui.fill()})
	menu_key := ui.key_from_string(0, "###dt_con_menu")
	if rows, ok := ui.vlist("###dt_con_list", &c.list, c.ids[:]); ok {
		for k in rows.first ..< rows.last {
			idx := c.rows[k]
			id := c.ids[k]
			level, text := con_split(t.console[idx])
			ui.next({height = ui.px(ui.dense(em * 1.6))})
			row := ui.list_row(&c.list.list, k, "")
			if con_selected(c, id) {
				col := ui.frame_new(draw.Color)
				col^ = ui.color("selection")
				row.box.custom, row.box.custom_user = con_row_draw, col
			}
			if ui.parent(row.box) {
				ui.spacer(ui.px(em * 0.6))
				fg := con_color(level)
				ui.next({width = ui.fill(), height = ui.pct(1), fg = fg})
				ui.label(fmt.aprintf("%s###cl%d", dev_line(text), id, allocator = ui.frame_allocator()))
			}
			if row.pressed {
				if .Shift in row.mods && c.has_sel { c.sel_b = id } else { c.has_sel, c.sel_a, c.sel_b = true, id, id }
			}
			if row.right_clicked {
				if !con_selected(c, id) { c.has_sel, c.sel_a, c.sel_b = true, id, id }
				c.menu_row = id
				ui.ctx_menu_open(menu_key, ui.mouse_pos())
			}
		}
		if n == 0 {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3))})
			if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(len(t.console) == 0 ? "No messages.###dt_con_none" : "Nothing matches the filters.###dt_con_none") } }
		}
	}

	if !grew { c.stay = !dev_at_end(&c.list, em) }   // a frame with no new row: where the view is says whether it follows

	// keys of the list
	if c.list.focused {
		if ui.key_press(.C, {.Ctrl}) && c.has_sel { clip_set(con_text(t, c, true)) }
		if ui.key_press(.A, {.Ctrl}) && n > 0 { c.has_sel, c.sel_a, c.sel_b = true, c.ids[0], c.ids[n - 1] }
		if ui.key_press(.Escape) { c.has_sel = false }
	}

	if ui.ctx_menu(menu_key) {
		sel := con_selected_count(c)
		if ui.menu_item(sel > 1 ? fmt.tprintf("Copy %d messages###dt_con_copy", sel) : "Copy message###dt_con_copy", "Ctrl+C", icon = GLYPH_COPY, enabled = sel > 0).clicked {
			clip_set(con_text(t, c, true))
			ui.ctx_menu_close()
		}
		if ui.menu_item("Copy all messages shown###dt_con_copy_all", enabled = n > 0).clicked { clip_set(con_text(t, c, false)); ui.ctx_menu_close() }
		if ui.menu_item("Select all", "Ctrl+A", enabled = n > 0).clicked { c.has_sel, c.sel_a, c.sel_b = true, c.ids[0], c.ids[n - 1]; ui.ctx_menu_close() }
		ui.menu_separator()
		if ui.menu_item("Clear console###dt_con_clear_menu").clicked { console_clear(app, t); ui.ctx_menu_close() }
	}

	if t.page != nil { console_eval_row(app, t, em) }   // "run JavaScript" (console_eval.odin)
}

console_clear :: proc(app: ^App, t: ^Tab) {
	for l in t.console { delete(l) }
	clear(&t.console)
	dev.con.has_sel = false
	dev.con.stop = t.console_added
	app.frames_requested = max(app.frames_requested, 2)
}
