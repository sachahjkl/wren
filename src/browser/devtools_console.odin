package browser

// The Console tab: the tab's messages (t.console, with the Con_Meta beside them: devtools_console_log.odin), one per row,
// with a gutter (level icon, a bar and a tint for warnings and errors), the time (optional), the message, and the
// file:line its stack names at the right; messages repeated one after the other are one row with a count; what is inside
// console.group is indented and a group's header folds it; a stack, or a long message, unfolds under its first line.
// The toolbar has Clear, the levels (counts, and a menu), a filter (text, `-word` to exclude, regular expression, case),
// pause and the console's switches; the "run JavaScript" line at the bottom is console_eval.odin.
//
// The rows are made again only when something they depend on changed, and only for the lines that arrived when
// that was all (the list of 100 000 lines of a page that logs in a loop is one row appended at a time). The list is
// virtual: the rows it builds are the ones in view.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:page"

Con_Row_Flag :: enum u8 { Header, Stack, Multi, Expanded, Collapsed, Obj, Table }

Con_Row :: struct {
	idx:   int,        // line index in t.console of the first line this row stands for
	abs:   u64,
	count: int,        // equal lines in a row, one after the other
	lines: u16,        // lines of text shown
	depth: u8,
	kind:  Con_Kind,
	flags: bit_set[Con_Row_Flag; u8],
}

Dev_Console :: struct {
	list:      Dt_List,
	rows:      [dynamic]Con_Row,
	offs:      [dynamic]f32,           // the rows' tops when their heights differ
	filter:    Dt_Filter,
	// what `rows` was made for
	key_tab:   u64,
	key_added: u64,
	key_len:   int,
	key_ser:   u64,
	key_exp:   u64,
	key_fs:    f32,
	key_stop:  u64,
	built_abs: u64,                    // lines before this absolute number are in `rows`
	skip:      int,                    // inside a folded group: the depth that ends the fold (-1: none)
	expanded:  map[u64]bool,
	folded:    map[u64]bool,           // group headers folded by the user
	exp_ver:   u64,
	paused:    bool,
	stop:      u64,                    // paused: the lines from this absolute number on are not shown
	has_sel:   bool,
	sel_a, sel_b: u64,                 // the selected rows: from one to the other (absolute numbers), either order
	menu_abs:  u64,
	last_rows: int,
	// the evaluation line
	evaluating: bool,                  // lines added now are the result of what was typed
	pending_payload: string,           // owned: the structured description to attach to the next line
	eval:      Con_Eval,
	// the levels of the console of the tab (the preference is the default)
	menu_src:  Con_Source,
	menu_file: string,                // owned: the file of menu_src
	ctx:       string,                 // owned: the address of the nested document the console runs in ("" = the top document)
}

console_panel_destroy :: proc() {
	c := &dev.con
	dt_list_destroy(&c.list)
	delete(c.rows)
	delete(c.offs)
	dt_filter_destroy(&c.filter)
	delete(c.expanded)
	delete(c.folded)
	delete(c.pending_payload)
	delete(c.ctx)
	delete(c.menu_file)
	console_eval_destroy()
	c^ = {}
}

////////////////////////////////
// The rows

@(private = "file")
level_bit :: proc(k: Con_Kind) -> u32 {
	switch k {
	case .Debug: return 1
	case .Log, .Info: return 2
	case .Warn: return 4
	case .Error: return 8
	case .Input, .Result, .Marker: return 0b1111
	}
	return 2
}

// What a line is, from the lines after its first: a stack (every one is "at ...") or more text.
@(private = "file")
line_shape :: proc(text: string) -> (lines: int, stack: bool) {
	lines = 1
	nl := strings.index_byte(text, '\n')
	if nl < 0 { return }
	rest := text[nl + 1:]
	stack = true
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		ln := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end + 1:]
		lines += 1
		if !strings.has_prefix(strings.trim_left_space(ln), "at ") { stack = false }
		if lines >= 400 { break }
	}
	return
}

CON_LINES_SHOWN :: 12   // lines of a plain multi-line message shown before it is unfolded

@(private = "file")
con_row_lines :: proc(r: ^Con_Row, total: int, stack: bool, expanded: bool) -> u16 {
	if total <= 1 { return 1 }
	if expanded { return u16(min(total, 400)) }
	if stack { return 1 }
	return u16(min(total, CON_LINES_SHOWN))
}

// Whether line `i` passes the filters of the toolbar.
@(private = "file")
con_passes :: proc(c: ^Dev_Console, t: ^Tab, i: int, kind: Con_Kind, text: string) -> bool {
	if level_bit(kind) & con_prefs.levels == 0 { return false }
	if kind == .Marker { return true }
	if con_prefs.hide_network && kind == .Error && con_is_network(text) { return false }
	if con_prefs.context_only && kind != .Input && !con_in_context(c, text) { return false }
	if dt_filter_active(&c.filter) && !dt_filter_match(&c.filter, text) { return false }
	return true
}

// Adds the row for line `i` (merging it into the last row when it repeats it).
@(private = "file")
con_add :: proc(c: ^Dev_Console, t: ^Tab, i: int, next_depth: int) {
	line := t.console[i]
	meta := i < len(t.conlog.meta) ? t.conlog.meta[i] : Con_Meta{}
	_, text := con_split(line)
	depth, body := con_depth(text)
	abs := con_abs(t, i)
	// inside a folded group: nothing until a line at the group's depth or less
	if c.skip >= 0 {
		if depth > c.skip { return }
		c.skip = -1
	}
	if !con_passes(c, t, i, meta.kind, text) {
		return
	}
	total, stack := line_shape(body)
	header := next_depth > depth
	payload := meta.payload
	if con_prefs.group_similar && len(c.rows) > 0 && !header && total == 1 {
		last := &c.rows[len(c.rows) - 1]
		if last.idx < len(t.console) && last.depth == u8(depth) && last.kind == meta.kind && .Header not_in last.flags && last.lines == 1 && t.console[last.idx] == line && meta.kind != .Input && meta.kind != .Marker {
			last.count += 1
			return
		}
	}
	r := Con_Row{idx = i, abs = abs, count = 1, depth = u8(min(depth, 12)), kind = meta.kind}
	if header { r.flags += {.Header} }
	if stack && total > 1 { r.flags += {.Stack} }
	if total > 1 { r.flags += {.Multi} }
	if c.expanded[abs] { r.flags += {.Expanded} }
	r.lines = con_row_lines(&r, total, stack, c.expanded[abs])
	if payload != "" {
		// an object behind the message: it unfolds into a tree; a table is drawn whole
		r.flags -= {.Stack, .Multi}
		r.lines = 1
		if payload_is_table(payload) {
			r.flags += {.Table}
			if root, pok := con_payload_parse(payload); pok { if tb, tok := con_payload_table(root); tok { r.lines = u16(1 + len(tb.rows)) } }
		} else if payload_unfoldable(payload) {
			r.flags += {.Obj}
			if c.expanded[abs] { if root, pok := con_payload_parse(payload); pok { r.lines = u16(1 + len(con_payload_tree(root))) } }
		}
	}
	if header && c.folded[abs] { r.flags += {.Collapsed}; c.skip = depth }
	append(&c.rows, r)
}

// The depth of the line after `i` (to tell a group's header: the next line is deeper).
@(private = "file")
con_next_depth :: proc(t: ^Tab, i: int) -> int {
	if i + 1 >= len(t.console) { return 0 }
	_, text := con_split(t.console[i + 1])
	d, _ := con_depth(text)
	return d
}

@(private = "file")
con_refresh :: proc(t: ^Tab, c: ^Dev_Console) {
	ser := dt_filter_prepare(&c.filter)
	ser = ser * 31 + u64(con_prefs.levels) * 7 + (con_prefs.hide_network ? 3 : 0) + (con_prefs.group_similar ? 5 : 0)
	if con_prefs.context_only { ser = ser * 131 + 17; for ch in transmute([]u8)c.ctx { ser = ser * 31 + u64(ch) } }
	stop := c.paused ? c.stop : 0
	same := c.key_tab == t.id && c.key_ser == ser && c.key_exp == c.exp_ver && c.key_fs == dtm.row && c.key_stop == stop
	first_abs := con_abs(t, 0)
	if same && c.key_added == t.console_added && c.key_len == len(t.console) { return }
	// only lines were added, and none of what the rows hold went: the new ones are appended
	incremental := same && c.key_added < t.console_added && c.built_abs >= first_abs && c.built_abs <= t.console_added
	if !incremental {
		clear(&c.rows)
		c.built_abs = first_abs
		c.skip = -1
	}
	c.key_tab, c.key_added, c.key_len, c.key_ser, c.key_exp, c.key_fs, c.key_stop = t.id, t.console_added, len(t.console), ser, c.exp_ver, dtm.row, stop
	start := int(c.built_abs - first_abs)
	// a header is known by the line after it: the last line waits until the next arrives
	end := len(t.console)
	for i in start ..< end {
		abs := con_abs(t, i)
		if c.paused && abs >= c.stop { end = i; break }
		con_add(c, t, i, con_next_depth(t, i))
	}
	c.built_abs = con_abs(t, 0) + u64(end)
	// heights: all one line, or each its own
	multi := false
	for &r in c.rows { if r.lines > 1 { multi = true; break } }
	if multi {
		resize(&c.offs, len(c.rows) + 1)
		y: f32
		for &r, k in c.rows {
			c.offs[k] = y
			y += con_row_height(&r)
		}
		c.offs[len(c.rows)] = y
	} else {
		clear(&c.offs)
	}
}

@(private = "file")
con_line_h :: proc() -> f32 { return math.round(dtm.mono_fs * 1.4) }

@(private = "file")
con_row_height :: proc(r: ^Con_Row) -> f32 {
	if r.lines <= 1 { return dtm.row }
	return dtm.row + f32(r.lines - 1) * con_line_h() + dt_px(2)
}

@(private = "file")
con_selected :: proc(c: ^Dev_Console, abs: u64) -> bool {
	if !c.has_sel { return false }
	lo, hi := min(c.sel_a, c.sel_b), max(c.sel_a, c.sel_b)
	return abs >= lo && abs <= hi
}

// The text of the rows shown, or of the selected ones, one message per line.
@(private = "file")
con_text :: proc(t: ^Tab, c: ^Dev_Console, only_selected: bool, with_time: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for &r in c.rows {
		if only_selected && !con_selected(c, r.abs) { continue }
		if n > 0 { strings.write_byte(&b, '\n') }
		if with_time && r.idx < len(t.conlog.meta) { strings.write_string(&b, con_time_text(t.conlog.meta[r.idx].at_ms)); strings.write_byte(&b, ' ') }
		_, text := con_split(t.console[r.idx])
		_, body := con_depth(text)
		strings.write_string(&b, body)
		if r.count > 1 { fmt.sbprintf(&b, " (x%d)", r.count) }
		n += 1
	}
	return strings.to_string(b)
}

@(private = "file")
con_selected_count :: proc(c: ^Dev_Console) -> int {
	n := 0
	for &r in c.rows { if con_selected(c, r.abs) { n += 1 } }
	return n
}

////////////////////////////////
// Drawing a row

@(private = "file")
Con_Draw :: struct {
	first:   string,              // the first line, without its group indentation
	extra:   []string,            // the other lines shown
	kind:    Con_Kind,
	count:   int,
	time:    string,
	src:     string,              // "file:line", right aligned
	src_hot: bool,
	depth:   int,
	chevron: int,                 // -1: none, 0: folded, 1: unfolded
	selected, hot, focused, odd: bool,
	stack:   bool,
	line_h:  f32,
	more:    int,                 // lines not shown
	runs:    []Dt_Run,            // the message as its page described it (objects, colors): drawn in place of the text
	tree:    []Obj_Line,          // an unfolded object
	table:   Con_Table,
	is_table: bool,
	level_icon: Dt_Icon,
	text_col, icon_col, tint, bar: draw.Color,
}

@(private = "file")
con_row_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Con_Draw)(user)
	r := b.rect
	dt_row_back(dc, r, false, d.selected, d.hot, d.focused, d.tint)
	line := draw.Color{dtc.border_soft.r, dtc.border_soft.g, dtc.border_soft.b, dtc.border_soft.a * 0.8}
	draw.rect(dc, {{r.min.x, r.max.y - dtm.line}, {r.max.x, r.max.y}}, line)
	if d.bar.a > 0 && !d.selected { draw.rect(dc, {r.min, {r.min.x + dtm.line * 2, r.max.y}}, d.bar) }
	top := r.min.y + dtm.row * 0.5
	x := r.min.x + dt_px(8)
	// group guides
	for i in 0 ..< d.depth {
		gx := math.round(x + f32(i) * dt_px(14) + dt_px(6))
		draw.rect(dc, {{gx, r.min.y}, {gx + dtm.line, r.max.y}}, with_alpha(dtc.border, 0.7))
	}
	x += f32(d.depth) * dt_px(14)
	// the fold / unfold chevron
	if d.chevron >= 0 {
		dt_icon(dc, d.chevron == 1 ? .Caret_Down : .Caret_Right, {math.round(x + dt_px(5)), top}, dtm.icon * 0.78, dtc.weak, dtm.sc)
	}
	x += dt_px(13)
	// the level
	if d.level_icon != .None {
		dt_icon(dc, d.level_icon, {math.round(x + dt_px(6)), top}, dtm.icon * 0.92, d.icon_col, dtm.sc)
		if d.level_icon == .Error { dt_icon(dc, .Close, {math.round(x + dt_px(6)), top}, dtm.icon * 0.58, draw.Color{1, 1, 1, 1}, dtm.sc) }
		if d.level_icon == .Warn {
			draw.rect(dc, {{math.round(x + dt_px(6) - dtm.line * 0.5), top - dt_px(3.2)}, {math.round(x + dt_px(6) + dtm.line * 0.5 + dtm.line * 0.4), top + dt_px(1.2)}}, draw.Color{1, 1, 1, 1})
			draw.rect(dc, {{math.round(x + dt_px(6) - dtm.line * 0.5), top + dt_px(2.4)}, {math.round(x + dt_px(6) + dtm.line * 0.5 + dtm.line * 0.4), top + dt_px(3.8)}}, draw.Color{1, 1, 1, 1})
		}
	}
	x += dt_px(17)
	// the right side first: the source
	right := r.max.x - dt_px(8)
	srcw: f32
	if d.src != "" {
		srcw = dt_w(dtm.mono, dtm.mono_fs, d.src)
		col := d.src_hot ? dtc.accent : dtc.weak
		dt_text(dc, dtm.mono, dtm.mono_fs, right - srcw, top, col, d.src)
		if d.src_hot { draw.rect(dc, {{right - srcw, top + dtm.mono_fs * 0.62}, {right, top + dtm.mono_fs * 0.62 + dtm.line}}, col) }
		right -= srcw + dt_px(12)
	}
	// the count of a repeated message
	if d.count > 1 {
		s := fmt.tprintf("%d", d.count)
		w := max(dt_w(dtm.ui_font, dtm.fs * 0.84, s) + dt_px(8), dtm.fs * 1.15)
		h := dtm.fs * 1.15
		draw.rect(dc, {{x, top - h * 0.5}, {x + w, top + h * 0.5}}, with_alpha(dtc.accent, 0.85), h * 0.5)
		dt_text(dc, dtm.ui_font, dtm.fs * 0.84, x + (w - dt_w(dtm.ui_font, dtm.fs * 0.84, s)) * 0.5, top, dtc.accent_text, s)
		x += w + dt_px(6)
	}
	if d.time != "" {
		x += dt_text(dc, dtm.mono, dtm.mono_fs * 0.9, x, top, dtc.faint, d.time) + dt_px(8)
	}
	// the text
	if d.kind == .Marker {
		w := dt_w(dtm.mono, dtm.mono_fs, d.first)
		cx := (r.min.x + r.max.x) * 0.5
		draw.rect(dc, {{r.min.x + dt_px(8), top}, {cx - w * 0.5 - dt_px(8), top + dtm.line}}, dtc.border)
		draw.rect(dc, {{cx + w * 0.5 + dt_px(8), top}, {r.max.x - dt_px(8), top + dtm.line}}, dtc.border)
		dt_text(dc, dtm.mono, dtm.mono_fs, cx - w * 0.5, top, dtc.weak, d.first)
		return
	}
	avail := right - x
	if len(d.runs) > 0 { dt_runs(dc, dtm.mono, dtm.mono_fs, x, top, d.runs, x + avail) } else if !d.is_table { dt_text(dc, dtm.mono, dtm.mono_fs, x, top, d.text_col, d.first, avail) }
	if d.is_table { con_table_paint(dc, d, x, r.min.y + d.line_h * 0.2 + dtm.row * 0.5, right) }
	if len(d.tree) > 0 {
		y := r.min.y + dtm.row * 0.5
		for ln in d.tree {
			y += d.line_h
			dt_runs(dc, dtm.mono, dtm.mono_fs, x + dt_px(14) + f32(ln.depth) * dt_px(14), y, ln.runs, right)
		}
	}
	if len(d.extra) > 0 {
		y := r.min.y + dtm.row * 0.5
		for ln in d.extra {
			y += d.line_h
			stack := d.stack || strings.has_prefix(strings.trim_left_space(ln), "at ")
			if stack {
				col := dtc.weak
				runs: [4]Dt_Run
				n := 0
				t := strings.trim_left_space(ln)
				open := strings.last_index_byte(t, '(')
				if open >= 0 && strings.has_suffix(t, ")") {
					runs[0] = {t[:open], col}
					runs[1] = {t[open:], with_alpha(dtc.accent, 0.9)}
					n = 2
				} else {
					runs[0] = {t, col}
					n = 1
				}
				dt_runs(dc, dtm.mono, dtm.mono_fs, x + dt_px(14), y, runs[:n], right)
			} else {
				dt_text(dc, dtm.mono, dtm.mono_fs, x, y, d.text_col, ln, avail)
			}
		}
		if d.more > 0 {
			y += d.line_h
			dt_text(dc, dtm.mono, dtm.mono_fs, x, y, dtc.weak, fmt.tprintf("\u2026 %d more lines (click to show them)", d.more))
		}
	}
}

@(private = "file")
con_level_icon :: proc(k: Con_Kind) -> (Dt_Icon, draw.Color) {
	#partial switch k {
	case .Error: return .Error, dtc.bad
	case .Warn:  return .Warn, draw.Color{0.86, 0.60, 0.05, 1}
	case .Result: return .Result, dtc.weak
	case .Input:  return .Prompt, dtc.accent
	case .Debug: return .Verbose, dtc.faint
	}
	return .None, dtc.weak
}

////////////////////////////////
// The panel

console_panel :: proc(app: ^App, t: ^Tab) {
	c := &dev.con
	console_toolbar(app, t, c)
	con_refresh(t, c)
	n := len(c.rows)
	c.last_rows = n

	menu_key := ui.key_from_string(0, "###dt_con_menu")
	list_h := ui.Size{.Percent, 1, 0}
	offs: []f32 = len(c.offs) == n + 1 && n > 0 ? c.offs[:] : nil
	if n == 0 {
		hidden := len(t.console) > 0
		dt_empty("###dt_con_empty", hidden ? .Filter : .Tab_Console, hidden ? "Every message is hidden by the filters" : "No messages in this page's console",
			hidden ? "Change the levels or clear the filter to see them." : "console.log() and the errors of the page appear here. Type an expression below to run it.")
	} else if rows, ok := dt_list("###dt_con_list", &c.list, n, dtm.row, offs, ui.fill(), list_h, follow = !c.paused); ok {
		line_h := con_line_h()
		for k in rows.first ..< rows.last {
			r := &c.rows[k]
			line := t.console[r.idx]
			_, text := con_split(line)
			_, body := con_depth(text)
			meta := r.idx < len(t.conlog.meta) ? t.conlog.meta[r.idx] : Con_Meta{}
			h := con_row_height(r)
			d := ui.frame_new(Con_Draw)
			d.kind, d.count, d.depth, d.stack, d.line_h = r.kind, r.count, int(r.depth), .Stack in r.flags, line_h
			// the lines
			first := body
			if nl := strings.index_byte(body, '\n'); nl >= 0 { first = body[:nl] }
			d.first = strings.trim_right(first, "\r")
			if (r.lines > 1 || .Multi in r.flags) && meta.payload == "" {
				all := strings.split_lines(body, context.temp_allocator)
				if .Stack in r.flags && .Expanded not_in r.flags {
					// a folded stack shows its first line only
				} else {
					shown := min(int(r.lines), len(all))
					d.extra = all[1:shown]
					if len(all) > shown && .Expanded not_in r.flags { d.more = len(all) - shown }
				}
			}
			level_k := r.kind
			switch level_k {
			case .Error: d.text_col, d.tint, d.bar = dtc.bad, dtc.bad_bg, dtc.bad
			case .Warn:  d.text_col, d.tint, d.bar = draw.Color{0.80, 0.55, 0.05, 1}, dtc.warn_bg, draw.Color{0.86, 0.60, 0.05, 1}
			case .Debug: d.text_col = dtc.faint
			case .Log, .Info, .Input, .Result, .Marker: d.text_col = dtc.text
			}
			if !dtc.dark && level_k == .Error { d.text_col = draw.mix(dtc.bad, draw.Color{0.35, 0, 0, 1}, 0.25) }
			d.level_icon, d.icon_col = con_level_icon(r.kind)
			if r.kind == .Input {
				// what was typed: a prompt in the gutter, the text in the colors of the language
				d.first = strings.trim_prefix(d.first, "> ")
				d.runs = syn_runs(d.first, .JS)
			}
			d.chevron = -1
			if .Header in r.flags { d.chevron = .Collapsed in r.flags ? 0 : 1 }
			if .Stack in r.flags || (.Multi in r.flags && (int(r.lines) < line_total(body) || .Expanded in r.flags)) { d.chevron = .Expanded in r.flags ? 1 : 0 }
			if .Obj in r.flags { d.chevron = .Expanded in r.flags ? 1 : 0 }
			if con_prefs.timestamps && r.kind != .Marker { d.time = dt_frame_str(con_time_text(meta.at_ms)) }
			src := con_source(body)
			if meta.payload != "" {
				if root, pok := con_payload_parse(meta.payload); pok {
					d.runs = con_payload_runs(root, 700)
					if .Expanded in r.flags && .Obj in r.flags { d.tree = con_payload_tree(root) }
					if .Table in r.flags { if tb, tok := con_payload_table(root); tok { d.table, d.is_table = tb, true } }
					if w := con_payload_source(root); w != "" { if s := con_parse_location(w); s.line > 0 { src = s } }
				}
			}
			if src.line > 0 { d.src = dt_frame_str(fmt.tprintf("%s:%d", src.file, src.line)) }
			id := fmt.tprintf("###cr%d", r.abs)
			ui.next({width = ui.fill(), height = ui.px(h), cursor = .Arrow})
			rb := ui.build_box({.Clickable}, id)
			sig := ui.signal(rb)
			d.selected, d.hot, d.focused = con_selected(c, r.abs), sig.hovering, c.list.focused
			// the source under the pointer
			if d.src != "" && sig.hovering {
				sw := dt_w(dtm.mono, dtm.mono_fs, d.src)
				if sig.mouse.y < dtm.row && sig.mouse.x >= (rb.rect.max.x - rb.rect.min.x) - sw - dt_px(10) { d.src_hot = true; rb.cursor = .Hand }
			}
			rb.custom, rb.custom_user = con_row_paint, d
			if sig.pressed {
				x := sig.mouse.x - dt_px(8) - f32(r.depth) * dt_px(14)
				if d.src_hot && src.line > 0 {
					console_open_source(app, t, src)
				} else if d.chevron >= 0 && x >= -dt_px(2) && x < dt_px(14) {
					console_toggle(c, r)
				} else if .Shift in sig.mods && c.has_sel { c.sel_b = r.abs } else { c.has_sel, c.sel_a, c.sel_b = true, r.abs, r.abs }
				c.list.sel = k
				ui.set_focus(c.list.key)
			}
			if sig.double_clicked && d.chevron >= 0 { console_toggle(c, r) }
			if sig.right_clicked {
				if !con_selected(c, r.abs) { c.has_sel, c.sel_a, c.sel_b = true, r.abs, r.abs }
				c.menu_abs = r.abs
				delete(c.menu_file)
				c.menu_src = src
				c.menu_file = strings.clone(src.file)   // (the row's own is of the frame's temporary memory)
				c.menu_src.file = c.menu_file
				ui.ctx_menu_open(menu_key, ui.mouse_pos())
			}
		}
	}
	console_keys(app, t, c, n)
	console_row_menu(app, t, c, menu_key)
	console_eval_row(app, t, dtm.row)   // "run JavaScript" (console_eval.odin)
}

@(private = "file")
line_total :: proc(body: string) -> int {
	n := 1
	for ch in transmute([]u8)body { if ch == '\n' { n += 1 } }
	return n
}

@(private = "file")
console_toggle :: proc(c: ^Dev_Console, r: ^Con_Row) {
	if .Header in r.flags {
		c.folded[r.abs] = !c.folded[r.abs]
	} else {
		c.expanded[r.abs] = !c.expanded[r.abs]
	}
	c.exp_ver += 1
}

@(private = "file")
console_open_source :: proc(app: ^App, t: ^Tab, src: Con_Source) {
	if src.url == "" { return }
	open_in_new_tab(app, strings.concatenate({VIEW_SOURCE, src.url}, context.temp_allocator), inspected_page(app))
}

@(private = "file")
console_keys :: proc(app: ^App, t: ^Tab, c: ^Dev_Console, n: int) {
	if !c.list.focused || n == 0 { return }
	if ui.key_press(.C, {.Ctrl}) && c.has_sel { clip_set(con_text(t, c, true, con_prefs.timestamps)) }
	if ui.key_press(.A, {.Ctrl}) { c.has_sel, c.sel_a, c.sel_b = true, c.rows[0].abs, c.rows[n - 1].abs }
	if ui.key_press(.Escape) { c.has_sel = false }
	if dt_list_keys(&c.list, n, max(int(c.list.view / dtm.row) - 1, 1)) {
		ab := c.rows[clamp(c.list.sel, 0, n - 1)].abs
		c.has_sel, c.sel_a, c.sel_b = true, ab, ab
	}
	if c.list.sel >= 0 && c.list.sel < n {
		r := &c.rows[c.list.sel]
		if ui.key_press(.Return) { console_toggle(c, r) }
		if ui.key_press(.Right) && (.Stack in r.flags || .Header in r.flags) && .Expanded not_in r.flags && .Collapsed in r.flags { console_toggle(c, r) }
	}
}

////////////////////////////////
// The menus

@(private = "file")
console_row_menu :: proc(app: ^App, t: ^Tab, c: ^Dev_Console, key: ui.Key) {
	if ui.ctx_menu(key, dt_px(260)) { console_row_menu_items(app, t, c) }
}

@(private = "file")
console_row_menu_items :: proc(app: ^App, t: ^Tab, c: ^Dev_Console) {
	sel := con_selected_count(c)
	n := len(c.rows)
	if ui.menu_item(sel > 1 ? fmt.tprintf("Copy %d messages###dt_con_copy", sel) : "Copy message###dt_con_copy", "Ctrl+C", icon = GLYPH_COPY, enabled = sel > 0).clicked {
		clip_set(con_text(t, c, true, con_prefs.timestamps))
	}
	if ui.menu_item("Copy stack trace###dt_con_copy_stack", enabled = c.menu_src.line > 0 || row_has_stack(t, c)).clicked { clip_set(row_stack_text(t, c)) }
	ref, rpage := row_object(t, c)
	if ui.menu_item("Copy object###dt_con_copy_obj", enabled = ref > 0 && rpage != nil).clicked { page.dev_console_copy(rpage, ref); request_frames(app, 3) }
	if ui.menu_item("Copy all messages shown###dt_con_copy_all", enabled = n > 0).clicked { clip_set(con_text(t, c, false, con_prefs.timestamps)) }
	ui.menu_separator()
	if ui.menu_item("Store as global variable###dt_con_store", enabled = ref > 0 && rpage != nil).clicked {
		dev.con.evaluating = true
		page.dev_console_store(rpage, ref)
		dev.con.evaluating = false
		request_frames(app, 3)
	}
	if ui.menu_item("Select all###dt_con_all", "Ctrl+A", enabled = n > 0).clicked { c.has_sel, c.sel_a, c.sel_b = true, c.rows[0].abs, c.rows[n - 1].abs }
	ui.menu_separator()
	row_text := row_message(t, c)
	if ui.menu_item("Filter on this text###dt_con_filter_text", enabled = row_text != "").clicked {
		ui.field_set(&c.filter.field, row_text)
		c.list.sel = 0
	}
	if ui.menu_item(fmt.tprintf("Hide messages like this###dt_con_hide_like"), enabled = row_text != "").clicked {
		cur := dt_filter_text(&c.filter)
		next := strings.concatenate({cur, cur == "" ? "" : " ", "-", first_word(row_text)}, context.temp_allocator)
		ui.field_set(&c.filter.field, next)
	}
	if ui.menu_item(c.menu_src.line > 0 ? fmt.tprintf("Open %s:%d in a new tab###dt_con_src", c.menu_src.file, c.menu_src.line) : "Open the source###dt_con_src", enabled = c.menu_src.line > 0).clicked {
		console_open_source(app, t, c.menu_src)
	}
	ui.menu_separator()
	if ui.menu_item("Clear console###dt_con_clear_menu", icon = "").clicked { console_clear(app, t) }
}

// The object a row's message was about: the id its description carries (the realm keeps the arguments under it) and the page
// whose realm that is (the tab's, or the nested document the message came from).
@(private = "file")
row_object :: proc(t: ^Tab, c: ^Dev_Console) -> (ref: int, p: ^page.Page) {
	for &r in c.rows {
		if r.abs != c.menu_abs { continue }
		if r.idx >= len(t.conlog.meta) { return 0, nil }
		ref = con_payload_ref(t.conlog.meta[r.idx].payload)
		_, text := con_split(t.console[r.idx])
		_, body := con_depth(text)
		return ref, console_page_of(t, body)
	}
	return 0, nil
}

@(private = "file")
first_word :: proc(s: string) -> string {
	it := s
	for w in strings.fields_iterator(&it) { if len(w) >= 3 { return w } }
	return strings.trim_space(s)
}

@(private = "file")
row_message :: proc(t: ^Tab, c: ^Dev_Console) -> string {
	for &r in c.rows {
		if r.abs != c.menu_abs { continue }
		_, text := con_split(t.console[r.idx])
		_, body := con_depth(text)
		if nl := strings.index_byte(body, '\n'); nl >= 0 { body = body[:nl] }
		return strings.clone(body, context.temp_allocator)
	}
	return ""
}

@(private = "file")
row_has_stack :: proc(t: ^Tab, c: ^Dev_Console) -> bool {
	for &r in c.rows { if r.abs == c.menu_abs { return .Stack in r.flags } }
	return false
}

@(private = "file")
row_stack_text :: proc(t: ^Tab, c: ^Dev_Console) -> string {
	for &r in c.rows {
		if r.abs != c.menu_abs { continue }
		_, text := con_split(t.console[r.idx])
		_, body := con_depth(text)
		return strings.clone(body, context.temp_allocator)
	}
	return ""
}

@(private = "file")
con_ctx_changed :: proc(app: ^App, c: ^Dev_Console) {
	c.key_ser = 0   // the rows are made again (Selected context only)
	request_frames(app, 3)
}

// Whether a line is of the selected context: a nested document's lines start with "[frame <address>] ".
@(private = "file")
con_in_context :: proc(c: ^Dev_Console, text: string) -> bool {
	_, body := con_depth(text)
	if !strings.has_prefix(body, "[frame ") { return c.ctx == "" }
	if c.ctx == "" { return false }
	return strings.has_prefix(body[7:], c.ctx) && strings.has_prefix(body[7 + len(c.ctx):], "] ")
}

// The page whose realm a message came from: the nested document its prefix names, else the tab's.
console_page_of :: proc(t: ^Tab, body: string) -> ^page.Page {
	if t.page == nil { return nil }
	if !strings.has_prefix(body, "[frame ") { return t.page }
	for f in page.dev_frames(t.page) {
		if strings.has_prefix(body[7:], f.href) && strings.has_prefix(body[7 + len(f.href):], "] ") { return f.page }
	}
	return nil
}

// The page the evaluation line runs in: the selected nested document, else the tab's.
console_target :: proc(t: ^Tab) -> ^page.Page {
	if t.page == nil || dev.con.ctx == "" { return t.page }
	for f in page.dev_frames(t.page) { if f.href == dev.con.ctx { return f.page } }
	return t.page
}

// The switches of the console, in the panel's menu and in the console's own.
console_settings_items :: proc(app: ^App, t: ^Tab) {
	ui.menu_heading("Console")
	if ui.menu_item("Preserve log###dt_cs_preserve", checked = con_prefs.preserve, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.preserve") }
	if ui.menu_item("Show timestamps###dt_cs_time", checked = con_prefs.timestamps, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.timestamps") }
	if ui.menu_item("Group similar messages###dt_cs_group", checked = con_prefs.group_similar, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.group_similar") }
	if ui.menu_item("Hide network messages###dt_cs_net", checked = con_prefs.hide_network, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.hide_network") }
	if ui.menu_item("Autocomplete from history###dt_cs_auto", checked = con_prefs.autocomplete, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.autocomplete") }
	if ui.menu_item("Evaluate as you type###dt_cs_eager", checked = con_prefs.eager_eval, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.eager_eval") }
	if ui.menu_item("Selected context only###dt_cs_ctx", checked = con_prefs.context_only, keep_open = true).clicked { dev_toggle_pref(app, "browser.devtools.console.context_only") }
}

@(private = "file")
console_toolbar :: proc(app: ^App, t: ^Tab, c: ^Dev_Console) {
	if dt_bar("###dt_con_bar") {
		dt_gap(3)
		if dt_btn("###dt_con_clear", .Clear, tooltip = "Clear the console", shortcut = "Ctrl+L", enabled = len(t.console) > 0).clicked { console_clear(app, t) }
		dt_vsep("###dt_cb0")
		// the context the expressions run in
		frames := t.page != nil ? page.dev_frames(t.page) : nil
		cur := -1
		for f, i in frames { if f.href == c.ctx { cur = i } }
		if cur < 0 && c.ctx != "" { delete(c.ctx); c.ctx = "" }   // the frame is gone: the top document again
		ckey := dt_menu_btn("###dt_con_ctx", .None, cur < 0 ? "top" : dev_line(frames[cur].href, 32), tooltip = "JavaScript context: where the expressions run", on = cur >= 0)
		if ui.ctx_menu(ckey, dt_px(320)) {
			ui.menu_heading("JavaScript context")
			if ui.menu_item("top###dt_ctx_top", checked = c.ctx == "").clicked { delete(c.ctx); c.ctx = ""; con_ctx_changed(app, c) }
			for f, i in frames {
				if ui.menu_item(fmt.tprintf("%s%s###dt_ctx_%d", strings.repeat("  ", f.depth, context.temp_allocator), dev_line(f.href, 60), i), checked = c.ctx == f.href).clicked {
					delete(c.ctx); c.ctx = strings.clone(f.href); con_ctx_changed(app, c)
				}
			}
			if len(frames) == 0 { ui.menu_item("This page has no nested documents###dt_ctx_note", enabled = false) }
		}
		dt_gap(3)
		// the filter
		ui.next({width = ui.fill(), height = ui.px(dtm.bar), axis = .X, cross = .Center})
		if ui.row(.Center, {}, "###dt_con_fw") {
			dt_search("###dt_con_filter", &c.filter, "Filter  (-word excludes)")
		}
		// counts, one chip per level
		errors, warns := console_counts(t)
		infos := t.conlog.counts[.Log] + t.conlog.counts[.Info]
		level_chip(app, "###dt_lv_e", .Error, errors, 8, dtc.bad, "Errors")
		level_chip(app, "###dt_lv_w", .Warn, warns, 4, draw.Color{0.86, 0.60, 0.05, 1}, "Warnings")
		level_chip(app, "###dt_lv_i", .Info, infos, 2, dtc.accent, "Info")
		level_chip(app, "###dt_lv_v", .Verbose, t.conlog.counts[.Debug], 1, dtc.faint, "Verbose")
		// the levels menu
		lkey := dt_menu_btn("###dt_con_levels", .None, levels_label(), tooltip = "Log levels")
		if ui.ctx_menu(lkey, dt_px(220)) {
			ui.menu_heading("Levels")
			for lv in ([?]struct{ bit: u32, name: string, kind: Con_Kind }{{1, "Verbose", .Debug}, {2, "Info", .Log}, {4, "Warnings", .Warn}, {8, "Errors", .Error}}) {
				n := lv.kind == .Log ? t.conlog.counts[.Log] + t.conlog.counts[.Info] : t.conlog.counts[lv.kind]
				if ui.menu_item(fmt.tprintf("%s  (%d)###dt_lvm_%d", lv.name, n, lv.bit), checked = con_prefs.levels & lv.bit != 0, keep_open = true).clicked {
					set_levels(app, con_prefs.levels ~ lv.bit)
				}
			}
			ui.menu_separator()
			if ui.menu_item("Default levels###dt_lvm_def", enabled = con_prefs.levels != 0b1110).clicked { set_levels(app, 0b1110) }
			if ui.menu_item("All levels###dt_lvm_all", enabled = con_prefs.levels != 0b1111).clicked { set_levels(app, 0b1111) }
		}
		dt_vsep("###dt_cb1")
		pk := dt_btn("###dt_con_pause", c.paused ? .Play : .Pause, tooltip = c.paused ? "Resume: show the messages that came" : "Pause: stop adding messages to the list", on = c.paused)
		if pk.clicked { c.paused = !c.paused; c.stop = t.console_added }
		skey := dt_menu_btn("###dt_con_gear", .Gear, tooltip = "Console settings", caret = false)
		if ui.ctx_menu(skey, dt_px(230)) { console_settings_items(app, t) }
		dt_gap(3)
	}
}

@(private = "file")
levels_label :: proc() -> string {
	switch con_prefs.levels {
	case 0b1110: return "Default levels"
	case 0b1111: return "All levels"
	case 0:      return "No levels"
	}
	n := 0
	for b in 0 ..< 4 { if con_prefs.levels & (1 << u32(b)) != 0 { n += 1 } }
	return fmt.tprintf("Custom levels (%d)", n)
}

@(private = "file")
set_levels :: proc(app: ^App, mask: u32) {
	dev_set_pref(app, "browser.devtools.console.levels", fmt.tprintf("%d", mask))
}

// A level's icon with its count: a click shows or hides the level.
@(private = "file")
level_chip :: proc(app: ^App, id: string, icon: Dt_Icon, count: int, bit: u32, col: draw.Color, name: string) {
	on := con_prefs.levels & bit != 0
	tone := on ? col : with_alpha(col, 0.35)
	label := fmt.tprintf("%d", count)
	d := dt_btn(id, icon, label, fmt.tprintf("%s: %d (click to %s)", name, count, on ? "hide" : "show"), tone = tone)
	if d.clicked { set_levels(app, con_prefs.levels ~ bit) }
}

console_clear :: proc(app: ^App, t: ^Tab) {
	for l in t.console { delete(l) }
	clear(&t.console)
	con_sync_meta(t)
	dev.con.has_sel = false
	dev.con.stop = t.console_added
	clear(&dev.con.expanded)
	clear(&dev.con.folded)
	request_frames(app, 2)
}

// console.table: the columns sized to what they hold, a rule under the header.
@(private = "file")
con_table_paint :: proc(dc: ^draw.Context, d: ^Con_Draw, x, y0, right: f32) {
	t := d.table
	ncols := len(t.cols) + 1 + (t.has_values ? 1 : 0)
	names := make([]string, ncols, context.temp_allocator)
	names[0] = "(index)"
	k := 1
	if t.has_values { names[k] = "Value"; k += 1 }
	for c in t.cols { names[k] = c; k += 1 }
	widths := make([]f32, ncols, context.temp_allocator)
	for n, i in names { widths[i] = dt_w(dtm.mono, dtm.mono_fs, n) }
	for row in t.rows { for cell, i in row { if i < ncols { widths[i] = max(widths[i], dt_w(dtm.mono, dtm.mono_fs, cell)) } } }
	for &w in widths { w = min(w, dt_px(240)) + dt_px(18) }
	cx := x
	for n, i in names {
		dt_text(dc, dtm.mono, dtm.mono_fs, cx + dt_px(6), y0, dtc.weak, n, widths[i] - dt_px(10))
		draw.rect(dc, {{cx + widths[i] - dtm.line, y0 - d.line_h * 0.5}, {cx + widths[i], y0 + d.line_h * (f32(len(t.rows)) + 0.5)}}, with_alpha(dtc.border, 0.7))
		cx += widths[i]
		if cx > right { break }
	}
	draw.rect(dc, {{x, y0 + d.line_h * 0.5}, {min(cx, right), y0 + d.line_h * 0.5 + dtm.line}}, with_alpha(dtc.border, 0.9))
	for row, ri in t.rows {
		cx = x
		y := y0 + d.line_h * f32(ri + 1)
		for cell, i in row {
			if i >= ncols { break }
			dt_text(dc, dtm.mono, dtm.mono_fs, cx + dt_px(6), y, i == 0 ? dtc.weak : dtc.text, cell, widths[i] - dt_px(10))
			cx += widths[i]
			if cx > right { break }
		}
	}
}

// What the page's realm said an expression offers (a JSON array of names): the evaluation line's completions use it.
console_complete_reply :: proc(json_text: string) {
	e := &dev.con.eval
	for s in e.dyn { delete(s) }
	clear(&e.dyn)
	v, err := json.parse(transmute([]byte)json_text, spec = .JSON, allocator = context.temp_allocator)
	if err != nil { return }
	arr, ok := v.(json.Array)
	if !ok { return }
	for it in arr { if s, sok := it.(json.String); sok { append(&e.dyn, strings.clone(string(s))) } }
}

// Tells every tab's realm whether to describe its console arguments: on while the panel is open.
console_arm_all :: proc(app: ^App) {
	want := dev.visible && con_prefs.max_payload > 0 ? con_prefs.max_payload : 0
	if want == page.dev_console_max { return }
	page.dev_console_max = want
	for t in tabs_all(app) { if t.page != nil { page.dev_console_arm(t.page, want) } }
}