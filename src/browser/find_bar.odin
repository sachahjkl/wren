package browser

// Find in page (Ctrl+F): a bar under the address row. Every match of the text typed is highlighted (the rendered text
// of the page, innerText rules: matches can span elements), the current one in another color and scrolled into view
// (through the scroll boxes it is in); Enter / F3 go to the next match, Shift+Enter / Shift+F3 to the previous one,
// the counter says "3/12"; Escape closes the bar and leaves the current match selected (as Chromium does).

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"

Find_Match :: struct { start, end: lay.Text_Pos }
Find_Span :: struct { lo, hi: int, match: int }   // a match's part in one text node

Find_State :: struct {
	open:       bool,
	focus:      bool,                    // give the field the focus at the next build
	field:      ui.Text_Field,
	query:      string,                  // what the matches are for (owned)
	page:       ^page.Page,
	mutations:  u64,
	styled:     u64,
	searched_ms: f64,
	case_sensitive: bool,
	matches:    [dynamic]Find_Match,
	spans:      map[base.Handle][dynamic]Find_Span,
	active:     int,
	truncated:  bool,
	reveal:     bool,                    // scroll the active match into view at the next paint
}

find: Find_State

find_destroy :: proc() {
	ui.field_destroy(&find.field)
	delete(find.query)
	delete(find.matches)
	for _, v in find.spans { delete(v) }
	delete(find.spans)
	find = {}
}

@(private = "file")
find_clear_matches :: proc() {
	clear(&find.matches)
	for _, v in find.spans { delete(v) }
	clear(&find.spans)
	find.active = -1
	find.truncated = false
}

find_open :: proc(app: ^App) {
	find.open, find.focus = true, true
	// the selection (when short and on one line) is what to look for
	if t := current_tab(app); t != nil && t.page != nil && page.selection_active(t.page) {
		s := strings.trim_space(page.selection_text(t.page))
		if s != "" && len(s) <= 200 && !strings.contains(s, "\n") { ui.field_set(&find.field, s) }
	}
	ui.field_select_all(&find.field)
}

find_close :: proc(app: ^App) {
	if !find.open { return }
	find.open = false
	t := current_tab(app)
	if t != nil && t.page != nil && t.page == find.page && find.active >= 0 && find.active < len(find.matches) {
		m := find.matches[find.active]
		page.selection_set(t.page, m.start, m.end)
	}
	find_clear_matches()
	delete(find.query)
	find.query = ""
	find.page = nil
	app.frames_requested = max(app.frames_requested, 2)
}

// Case folding with a map from each folded byte back to the byte of the text it comes from.
@(private = "file")
fold :: proc(s: string, exact: bool) -> (out: string, back: []i32) {
	if exact {
		b := make([]i32, len(s) + 1, context.temp_allocator)
		for i in 0 ..= len(s) { b[i] = i32(i) }
		return s, b
	}
	sb := strings.builder_make(0, len(s), context.temp_allocator)
	m := make([dynamic]i32, 0, len(s) + 1, context.temp_allocator)
	for r, i in s {
		buf, n := utf8.encode_rune(unicode.to_lower(r))
		strings.write_bytes(&sb, buf[:n])
		for _ in 0 ..< n { append(&m, i32(i)) }
	}
	append(&m, i32(len(s)))
	return strings.to_string(sb), m[:]
}

// (Re)computes the matches when the text searched, the page or its content changed.
@(private = "file")
find_update :: proc(app: ^App, t: ^Tab) {
	if t == nil || t.page == nil || t.kind != .Web { find_clear_matches(); find.page = nil; return }
	p := t.page
	q := ui.field_string(&find.field)
	styled_serial := p.styled != nil ? p.styled.serial : 0
	same_query := q == find.query && find.case_sensitive == ix.find_case_sensitive
	if same_query && find.page == p && find.mutations == p.doc.mutations && find.styled == styled_serial { return }
	// content that keeps changing is searched again at most a few times a second
	now := ui.now_ms()
	if same_query && find.page == p && now - find.searched_ms < 250 { app.frames_requested = max(app.frames_requested, 1); return }
	keep := same_query && find.page == p ? find.active : -1
	find_clear_matches()
	delete(find.query)
	find.query = strings.clone(q)
	find.page, find.mutations, find.styled, find.searched_ms = p, p.doc.mutations, styled_serial, now
	find.case_sensitive = ix.find_case_sensitive
	if q == "" || p.styled == nil { return }
	body := p.body
	if dom.get(p.doc, body) == nil { body = p.doc.root }
	ft := lay.range_text(p.doc, p.styled, {body, 0}, {body, lay.child_count(p.doc, body)}, body)
	hay, back := fold(ft.text, find.case_sensitive)
	needle, _ := fold(q, find.case_sensitive)
	if needle == "" { return }
	from := 0
	for from <= len(hay) - len(needle) {
		i := strings.index(hay[from:], needle)
		if i < 0 { break }
		fa := from + i
		fb := fa + len(needle)
		a, b := int(back[fa]), int(back[fb])
		from = fb
		if len(find.matches) >= ix.find_max_matches { find.truncated = true; break }
		s, sok := lay.flat_to_pos(ft, a)
		e, eok := lay.flat_to_pos(ft, b, end = true)
		if !sok || !eok { continue }
		idx := len(find.matches)
		append(&find.matches, Find_Match{s, e})
		// its parts per text node, for the painter
		for r in ft.runs {
			if r.out >= b { break }
			if r.out + r.out_len <= a { continue }
			lo, hi := r.src, r.src + r.src_len
			if r.out_len == r.src_len {
				lo = r.src + max(a - r.out, 0)
				hi = r.src + min(b - r.out, r.out_len)
			}
			list, ok := &find.spans[r.node]
			if !ok { find.spans[r.node] = make([dynamic]Find_Span); list = &find.spans[r.node] }
			append(list, Find_Span{lo, hi, idx})
		}
	}
	if len(find.matches) == 0 { return }
	if keep >= 0 { find.active = min(keep, len(find.matches) - 1); return }
	// the first match at or below the top of the view
	find.active = 0
	for m, i in find.matches {
		n := dom.get(p.doc, m.start.node)
		if n == nil { continue }
		el := n.kind == .Text ? n.parent : m.start.node
		if r, ok := lay.box_of(&t.layout, el, draw.rect_size(app.page_rect), t.scroll); ok && r.border.max.y >= t.scroll { find.active = i; break }
	}
	find.reveal = true
}

find_step :: proc(app: ^App, dir: int) {
	n := len(find.matches)
	if n == 0 { return }
	find.active = ((find.active < 0 ? (dir > 0 ? -1 : 0) : find.active) + dir + n) % n
	find.reveal = true
	app.frames_requested = max(app.frames_requested, 2)
}

// The bar (built under the address row while open).
find_bar :: proc(app: ^App, t: ^Tab) {
	if !find.open { return }
	em := ui.font_size()
	find_update(app, t)
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###find_bar") {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
		if ui.tags("weak") { ui.label("Find in page###find_lbl") }
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.px(em * 22), height = ui.px(ui.dense(em * 2))})
		res := ui.line_edit("###find_field", &find.field, "Text to find")
		if find.focus {
			find.focus = false
			if b := ui.prev_box("###find_field"); b != nil { ui.set_focus(b.key) }
		}
		if res.focused {
			if ui.key_press(.Return, {.Shift}) || ui.key_press(.F3, {.Shift}) { find_step(app, -1) }
			if ui.key_press(.F3) { find_step(app, 1) }
		}
		if res.committed { find_step(app, 1) }
		ui.spacer(ui.px(em * 0.6))
		count := "No results"
		if ui.field_string(&find.field) == "" { count = "" } else if len(find.matches) > 0 {
			count = fmt.tprintf("%d/%d%s", find.active + 1, len(find.matches), find.truncated ? "+" : "")
		}
		ui.next({width = ui.px(em * 7), height = ui.px(ui.dense(em * 2))})
		if ui.tags(len(find.matches) == 0 && count != "" ? "bad" : "weak") { ui.label(fmt.tprintf("%s###find_count", count)) }
		if nav_button("###find_prev", "^", "Previous match (Shift+Enter)", len(find.matches) > 0) { find_step(app, -1) }
		if nav_button("###find_next", "v", "Next match (Enter)", len(find.matches) > 0) { find_step(app, 1) }
		ui.spacer(ui.fill())
		if nav_button("###find_close", GLYPH_CLOSE, "Close (Escape)", true) || res.cancelled { find_close(app) }
		ui.spacer(ui.px(em * 0.6))
	}
}

// For the painter: the matches of the page being painted (nil when the bar is closed or matches are for another page).
find_paint_state :: proc(t: ^Tab) -> ^Find_State {
	if !find.open || find.page != t.page || len(find.matches) == 0 { return nil }
	if find.reveal { find.reveal = false; find_reveal(t) }
	return &find
}

find_paint_item :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, idx: int, r: draw.Rect) {
	d := find.page.doc
	node, lo, hi, ok := lay.item_source(l, d, idx)
	if !ok { return }
	spans, has := find.spans[node]
	if !has { return }
	bg, _ := parse_pref_color(ix.find_bg)
	act, _ := parse_pref_color(ix.find_active_bg)
	api := page_text_api(&page_render.fonts, &the_app.measure, &the_app.page_settings.style)
	for s in spans {
		if s.hi <= lo || s.lo >= hi { continue }
		a, b, rok := lay.item_range(l, d, idx, {node, s.lo}, {node, s.hi})
		if !rok { continue }
		// through the shaped clusters: in a right-to-left item the match runs from its end's caret to its start's
		ca, cb := lay.item_caret_x(l, it, a, api), lay.item_caret_x(l, it, b, api)
		x0, x1 := min(ca, cb), max(ca, cb)
		draw.rect(dc, {{r.min.x + x0, r.min.y}, {r.min.x + x1, r.max.y}}, s.match == find.active ? act : bg, 2 * the_app.ui_state.scale)
	}
}

// Scrolls the active match into view: the scroll boxes it is in, then the page.
@(private = "file")
find_reveal :: proc(t: ^Tab) {
	if find.active < 0 || find.active >= len(find.matches) { return }
	m := find.matches[find.active]
	l := &t.layout
	n := dom.get(t.page.doc, m.start.node)
	if n == nil || n.kind != .Text { return }
	items := lay.items_of_text(l, t.page.doc, m.start.node, m.start.offset, m.start.offset + 1)
	if len(items) == 0 { return }
	it := &l.items[items[0]]
	view := draw.rect_size(the_app.page_rect)
	margin := view.y * 0.25
	rect := it.rect
	for s := it.space; s != lay.NONE; s = l.spaces[s].parent {
		sp := &l.spaces[s]
		#partial switch sp.kind {
		case .Scroll:
			node := l.boxes[sp.box].node
			cur, _ := lay.scroll_of(l, node)
			want := cur
			ph := sp.port.max.y - sp.port.min.y
			pw := sp.port.max.x - sp.port.min.x
			if rect.min.y < sp.port.min.y + want.y || rect.max.y > sp.port.max.y + want.y { want.y = rect.min.y - sp.port.min.y - ph * 0.3 }
			if rect.min.x < sp.port.min.x + want.x || rect.max.x > sp.port.max.x + want.x { want.x = rect.min.x - sp.port.min.x - pw * 0.3 }
			got, _ := lay.set_scroll(l, node, want)
			rect = {rect.min - got, rect.max - got}
		case .Document:
			if rect.min.y < t.scroll || rect.max.y > t.scroll + view.y { t.scroll = max(rect.min.y - margin, 0) }
			the_app.frames_requested = max(the_app.frames_requested, 2)
			return
		case .Fixed:
			return
		}
	}
}

_ :: time
