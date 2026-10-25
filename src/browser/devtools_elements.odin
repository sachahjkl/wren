package browser

// The Elements tab: the document of the tab as a tree of colored markup (tag names, attributes, values, text, comments) with
// guides for the indentation, the node's closing tag, a one-line form for an element whose only child is a short text; the
// chosen node's details at its side (devtools_styles.odin: Styles, Computed, Layout, Event Listeners, Accessibility); a
// breadcrumb of its ancestors under the tree; a search (Ctrl+F: text, tag, attribute, selector, XPath); and the node's box
// drawn over the page (the hovered row's, else the chosen one's), or the element under the pointer while picking
// (Ctrl+Shift+C). "Inspect" in the page's context menu selects the element under the pointer.
//
// Edits: double click an attribute's name or value (or a text) to change it, F2 or the menu to edit a node as HTML,
// Delete removes it, the menu duplicates, copies (outer HTML, selector, XPath), adds an attribute or hides the element; a
// row can be dragged to another place in the tree. They go through page/devtools_api.odin; the page restyles at its next frame.
//
// The rows hold copies of what they show: they are made when the page is not running (a chrome frame made while a script
// holds the thread, shell_nested, shows the rows of the last full frame) and again when the document changed, a node was
// expanded or collapsed, or the page is another.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:page"

El_Kind :: enum u8 { Open, Close, Inline, Text, Comment, Doctype }

El_Span :: struct { name_a, name_b, val_a, val_b: int }   // an attribute in a row's label (value spans are of the text inside the quotes)

El_Row :: struct {
	h:          base.Handle,
	depth:      int,
	kind:       El_Kind,
	label:      string,      // owned: the markup shown
	tail:       string,      // owned: a folded element's "…</div>"
	attrs:      [dynamic]El_Span,
	expandable: bool,
	expanded:   bool,
	children:   int,
}

El_Edit_Kind :: enum u8 { None, Attr_Value, Attr_Name, Attr_New, Text, Html }

Dev_Elements :: struct {
	list:      Dt_List,
	ids:       [dynamic]u64,
	rows:      [dynamic]El_Row,
	expanded:  map[base.Handle]bool,
	page:      rawptr,         // the page the rows, the expansion and the selection are of
	mutations: u64,            // the document's, when the rows were made
	version:   u64,            // bumped by an expansion; rows_version: the one the rows were made for
	rows_version: u64,
	selected:  base.Handle,
	hover:     base.Handle,    // the row under the pointer this frame (the page shows its box)
	picked:    base.Handle,    // while picking: the element under the pointer in the page
	reveal:    bool,           // scroll the selected row into view at the next list
	// the editing of a row
	edit:      El_Edit_Kind,
	edit_h:    base.Handle,
	edit_attr: string,         // owned: the attribute being edited
	field:     ui.Text_Field,
	area:      ui.Text_Area,   // the markup of "edit as HTML"
	focus_edit: bool,
	edit_age:  int,
	// search
	search:    Dt_Filter,
	search_on: bool,
	found:     [dynamic]base.Handle,
	found_at:  int,
	found_key: u64,
	// drag and drop of rows
	drag_h:    base.Handle,
	drop_row:  int,
	drop_pos:  int,            // 0 before, 1 inside, 2 after
	// the ancestors of the selected node
	crumbs:    [dynamic]El_Crumb,
	// the right-hand pane
	side:      Dev_Styles,
	menu_row:  int,
	menu_span: El_Span,
	menu_has_span: bool,
}

El_Crumb :: struct { h: base.Handle, label: string }   // owned

elements_destroy :: proc() {
	e := &dev.els
	rows_free(e)
	delete(e.rows)
	delete(e.ids)
	delete(e.expanded)
	delete(e.edit_attr)
	ui.field_destroy(&e.field)
	ui.area_destroy(&e.area)
	dt_filter_destroy(&e.search)
	delete(e.found)
	for c in e.crumbs { delete(c.label) }
	delete(e.crumbs)
	styles_destroy(&e.side)
	dt_list_destroy(&e.list)
	e^ = {}
}

@(private = "file")
rows_free :: proc(e: ^Dev_Elements) {
	for &r in e.rows { delete(r.label); delete(r.tail); delete(r.attrs) }
	clear(&e.rows)
	clear(&e.ids)
}

// The page changed (a navigation): nothing of the old one is kept.
@(private = "file")
elements_reset :: proc(e: ^Dev_Elements, p: rawptr) {
	rows_free(e)
	clear(&e.expanded)
	styles_reset(&e.side)
	clear(&e.found)
	e.page, e.selected, e.hover, e.picked, e.mutations, e.rows_version, e.edit = p, base.NIL_HANDLE, base.NIL_HANDLE, base.NIL_HANDLE, 0, 0, .None
	e.version += 1
	dt_list_destroy(&e.list)
}

elements_reset_layout :: proc(app: ^App) {
	dev_set_pref(app, "browser.devtools.elements.split", "0.55")
	dev_set_pref(app, "browser.devtools.elements.side_tab", "styles")
}

////////////////////////////////
// The rows

VOID_ELEMENTS := [?]string{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

@(private = "file")
is_void :: proc(name: string) -> bool {
	for v in VOID_ELEMENTS { if v == name { return true } }
	return false
}

// "<a href="x" class="y">" with the places of the attributes in it.
@(private = "file")
open_tag :: proc(n: ^dom.Node, spans: ^[dynamic]El_Span) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<%s", n.name)
	for a in n.attrs {
		strings.write_byte(&b, ' ')
		sp := El_Span{name_a = strings.builder_len(b)}
		strings.write_string(&b, a.name)
		sp.name_b = strings.builder_len(b)
		if a.value != "" {
			strings.write_string(&b, "=\"")
			sp.val_a = strings.builder_len(b)
			strings.write_string(&b, a.value)
			sp.val_b = strings.builder_len(b)
			strings.write_byte(&b, '"')
		} else {
			sp.val_a, sp.val_b = -1, -1
		}
		if spans != nil { append(spans, sp) }
	}
	strings.write_byte(&b, '>')
	return strings.to_string(b)
}

// A node that makes a row: elements, comments, the doctype, text that is not only blanks.
@(private = "file")
shown :: proc(n: ^dom.Node) -> bool {
	#partial switch n.kind {
	case .Element, .Comment, .Doctype: return true
	case .Text: return strings.trim_space(n.text) != ""
	}
	return false
}

@(private = "file")
shown_children :: proc(d: ^dom.Document, n: ^dom.Node) -> (count: int, only: base.Handle) {
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(d, c)
		if cn == nil { break }
		if shown(cn) { count += 1; if count == 1 { only = c } }
		c = cn.next
	}
	return
}

@(private = "file")
add_row :: proc(e: ^Dev_Elements, r: El_Row) {
	append(&e.rows, r)
	append(&e.ids, u64(r.h) * 4 + u64(r.kind == .Close ? 1 : 0))
}

@(private = "file")
flatten :: proc(e: ^Dev_Elements, d: ^dom.Document, h: base.Handle, depth: int) {
	n := dom.get(d, h)
	if n == nil { return }
	if n.kind == .Document {
		for c := n.first_child; c != base.NIL_HANDLE; {
			cn := dom.get(d, c)
			if cn == nil { break }
			flatten(e, d, c, depth)
			c = cn.next
		}
		return
	}
	if !shown(n) { return }
	switch n.kind {
	case .Text:
		add_row(e, El_Row{h = h, depth = depth, kind = .Text, label = strings.clone(dev_line(strings.trim_space(n.text), 400))})
		return
	case .Comment:
		add_row(e, El_Row{h = h, depth = depth, kind = .Comment, label = strings.clone(dev_line(strings.concatenate({"<!-- ", strings.trim_space(n.text), " -->"}, context.temp_allocator), 400))})
		return
	case .Doctype:
		add_row(e, El_Row{h = h, depth = depth, kind = .Doctype, label = strings.clone(strings.concatenate({"<!doctype ", n.name, ">"}, context.temp_allocator))})
		return
	case .Document, .Fragment, .Element:
	}
	if n.kind != .Element { return }
	spans := make([dynamic]El_Span, context.temp_allocator)
	tag := open_tag(n, &spans)
	count, only := shown_children(d, n)
	row := El_Row{h = h, depth = depth, children = count}
	if is_void(n.name) {
		row.kind, row.label = .Open, strings.clone(dev_line(tag, 600))
		row.attrs = clone_spans(spans[:])
		add_row(e, row)
		return
	}
	close_tag := fmt.tprintf("</%s>", n.name)
	if count == 0 {
		row.kind, row.label = .Inline, strings.clone(dev_line(strings.concatenate({tag, close_tag}, context.temp_allocator), 600))
		row.attrs = clone_spans(spans[:])
		add_row(e, row)
		return
	}
	if count == 1 {
		cn := dom.get(d, only)
		if cn != nil && cn.kind == .Text {
			text := strings.trim_space(cn.text)
			if len(text) <= 90 && !strings.contains_rune(text, '\n') {
				row.kind, row.label = .Inline, strings.clone(dev_line(strings.concatenate({tag, text, close_tag}, context.temp_allocator), 700))
				row.attrs = clone_spans(spans[:])
				add_row(e, row)
				return
			}
		}
	}
	open := e.expanded[h]
	row.kind, row.label, row.expandable, row.expanded = .Open, strings.clone(dev_line(tag, 600)), true, open
	row.attrs = clone_spans(spans[:])
	if !open { row.tail = strings.clone(strings.concatenate({"\u2026", close_tag}, context.temp_allocator)) }
	add_row(e, row)
	if open && depth < 200 {
		for c := n.first_child; c != base.NIL_HANDLE; {
			cn := dom.get(d, c)
			if cn == nil { break }
			flatten(e, d, c, depth + 1)
			c = cn.next
		}
		add_row(e, El_Row{h = h, depth = depth, kind = .Close, label = strings.clone(close_tag)})
	}
}

@(private = "file")
clone_spans :: proc(s: []El_Span) -> [dynamic]El_Span {
	out := make([dynamic]El_Span, 0, len(s))
	append(&out, ..s)
	return out
}

// The rows for the page, made again when the document or the expansion changed.
@(private = "file")
elements_refresh :: proc(t: ^Tab, e: ^Dev_Elements) {
	p := t.page
	if p == nil || p.closed { return }
	if rawptr(p) != e.page {
		elements_reset(e, rawptr(p))
		// first look: the document element, the head and the body are open
		d := p.doc
		for c := dom.get(d, d.root).first_child; c != base.NIL_HANDLE; {
			cn := dom.get(d, c)
			if cn == nil { break }
			if cn.kind == .Element && cn.name == "html" {
				e.expanded[c] = true
				for g := cn.first_child; g != base.NIL_HANDLE; {
					gn := dom.get(d, g)
					if gn == nil { break }
					if gn.kind == .Element && (gn.name == "body" || gn.name == "head") { e.expanded[g] = true }
					g = gn.next
				}
			}
			c = cn.next
		}
	}
	if p.doc.mutations == e.mutations && e.rows_version == e.version && len(e.rows) > 0 { return }
	rows_free(e)
	flatten(e, p.doc, p.doc.root, 0)
	e.mutations, e.rows_version = p.doc.mutations, e.version
}

// Selects `h` and opens the way to it (the page's context menu, "Inspect", a click in the page while picking, a search).
elements_select :: proc(t: ^Tab, target: base.Handle) {
	h := target
	p := t.page
	if p == nil || p.closed { return }
	e := &dev.els
	if rawptr(p) != e.page { elements_refresh(t, e) }
	n := dom.get(p.doc, h)
	if n == nil { return }
	if n.kind != .Element && n.kind != .Text && n.kind != .Comment { h = n.parent }
	e.selected, e.reveal = h, true
	for cur := dom.get(p.doc, h).parent; cur != base.NIL_HANDLE; {
		cn := dom.get(p.doc, cur)
		if cn == nil { break }
		e.expanded[cur] = true
		cur = cn.parent
	}
	e.version += 1
}

@(private = "file")
row_index :: proc(e: ^Dev_Elements, h: base.Handle) -> int {
	for r, i in e.rows { if r.h == h && r.kind != .Close { return i } }
	return -1
}

@(private = "file")
toggle :: proc(e: ^Dev_Elements, h: base.Handle) {
	e.expanded[h] = !e.expanded[h]
	e.version += 1
}

// Everything under `h` open (or shut).
@(private = "file")
toggle_all :: proc(e: ^Dev_Elements, d: ^dom.Document, h: base.Handle, open: bool, budget: ^int) {
	n := dom.get(d, h)
	if n == nil || budget^ <= 0 { return }
	budget^ -= 1
	if n.kind == .Element { e.expanded[h] = open }
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(d, c)
		if cn == nil { break }
		toggle_all(e, d, c, open, budget)
		c = cn.next
	}
	e.version += 1
}

////////////////////////////////
// Drawing

@(private = "file")
El_Draw :: struct {
	row:      ^El_Row,
	label:    string,
	tail:     string,
	runs:     []Dt_Run,
	selected, hot, focused, found, drop_inside: bool,
	drop_line: int,             // -1 none, 0 line above, 1 line below
	kind:     El_Kind,
	depth:    int,
	chevron:  int,
	text_col: draw.Color,
	hidden:   bool,
	guides:   []bool,
}

@(private = "file")
EL_INDENT :: 14

@(private = "file")
el_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^El_Draw)(user)
	r := b.rect
	dt_row_back(dc, r, false, d.selected, d.hot, d.focused)
	if d.found && !d.selected { draw.rect(dc, r, with_alpha(draw.Color{0.95, 0.75, 0.2, 1}, 0.14)) }
	cy := (r.min.y + r.max.y) * 0.5
	ind := dt_px(EL_INDENT)
	x0 := r.min.x + dt_px(6)
	// the guides of the levels above
	for i in 0 ..< d.depth {
		gx := math.round(x0 + f32(i) * ind + ind * 0.5 + dt_px(3))
		draw.rect(dc, {{gx, r.min.y}, {gx + dtm.line, r.max.y}}, with_alpha(dtc.border, d.selected ? 0.9 : 0.45))
	}
	x := x0 + f32(d.depth) * ind
	if d.chevron >= 0 {
		dt_icon(dc, d.chevron == 1 ? .Caret_Down : .Caret_Right, {math.round(x + dt_px(4)), cy}, dtm.icon * 0.78, dtc.weak, dtm.sc)
	}
	x += dt_px(13)
	right := r.max.x - dt_px(6)
	switch d.kind {
	case .Open, .Inline, .Close:
		end := dt_runs(dc, dtm.mono, dtm.mono_fs, x, cy, d.runs, right)
		if d.tail != "" {
			dt_runs(dc, dtm.mono, dtm.mono_fs, end + dt_px(2), cy, syn_runs(d.tail, .HTML), right)
		}
		if d.hidden { dt_text_r(dc, dtm.ui_font, dtm.fs * 0.85, right, cy, dtc.faint, "hidden") }
	case .Text:
		dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, d.text_col, d.label, right - x)
	case .Comment:
		dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, syn_color(.Comment), d.label, right - x)
	case .Doctype:
		dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.weak, d.label, right - x)
	}
	// drag and drop
	if d.drop_inside { draw.rect(dc, r, with_alpha(dtc.accent, 0.22)); draw.rect(dc, r, with_alpha(dtc.accent, 0.8), 0, dtm.line) }
	if d.drop_line == 0 { draw.rect(dc, {{r.min.x, r.min.y}, {r.max.x, r.min.y + dtm.line * 2}}, dtc.accent) }
	if d.drop_line == 1 { draw.rect(dc, {{r.min.x, r.max.y - dtm.line * 2}, {r.max.x, r.max.y}}, dtc.accent) }
}

////////////////////////////////
// The panel

elements_panel :: proc(app: ^App, t: ^Tab) {
	e := &dev.els
	if t.page == nil || t.page.closed {
		dt_empty("###dt_el_none", .Tab_Elements, "No document", "Elements shows the markup of a web page. Open one in this tab.")
		return
	}
	// the document is read only while the page is not running
	if !shell_nested() { elements_refresh(t, e); styles_refresh(app, t, e) }
	e.hover = base.NIL_HANDLE
	elements_picker(app, t, e)

	room := dev.rect.max.x - dev.rect.min.x
	wide := room == 0 || room >= dt_px(700)
	split := f32(config_float(app, "browser.devtools.elements.split"))
	ui.next({width = ui.fill(), height = ui.fill()})
	if wide {
		if ui.row(.Start, {}, "###dt_el") { elements_body(app, t, e, wide, split, room) }
	} else {
		if ui.column(.Start, {}, "###dt_el") { elements_body(app, t, e, wide, split, room) }
	}
}

@(private = "file")
elements_body :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, wide: bool, split, room: f32) {
	if wide { ui.next({width = ui.pct(split), height = ui.fill()}) } else { ui.next({width = ui.fill(), height = ui.pct(0.5)}) }
	if ui.column(.Start, {.Clip}, "###dt_el_tree_box") { tree_view(app, t, e) }
	if wide {
		dx, _, dragging := dt_vsplit("###dt_el_vs")
		if dragging && room > 0 {
			nv := clamp(split + dx / room, 0.2, 0.8)
			set_pref_quiet(app, "browser.devtools.elements.split", nv)
			app.frames_requested = max(app.frames_requested, 2)
		}
	} else {
		dy, _, dragging := dt_hsplit("###dt_el_hs")
		_ = dy
		_ = dragging
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.column(.Start, {.Clip}, "###dt_el_side_box") { styles_panel(app, t, e) }
}

@(private = "file")
tree_view :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	if dt_bar("###dt_el_bar", dtm.bar - dt_px(4)) {
		dt_gap(3)
		if dt_btn("###dt_el_search", .Search, tooltip = "Find in the tree (text, tag, attribute, selector, XPath)", shortcut = "Ctrl+F", on = e.search_on).clicked { e.search_on = !e.search_on }
		dt_vsep("###dt_eb0")
		if dt_btn("###dt_el_expand", .Chevron_Down, tooltip = "Expand the selected node and all that is in it", enabled = e.selected != base.NIL_HANDLE).clicked {
			if t.page != nil { budget := 5000; toggle_all(e, t.page.doc, e.selected, true, &budget) }
		}
		if dt_btn("###dt_el_collapse", .Chevron_Right, tooltip = "Collapse the selected node and all that is in it", enabled = e.selected != base.NIL_HANDLE).clicked {
			if t.page != nil { budget := 5000; toggle_all(e, t.page.doc, e.selected, false, &budget) }
		}
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.custom("###dt_el_info", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			s := (^string)(user)^
			dt_text_r(dc, dtm.ui_font, dtm.fs * 0.92, b.rect.max.x - dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, s)
		}, new_clone(dt_frame_str(fmt.tprintf("%d rows", len(e.rows))), ui.frame_allocator()))
	}
	if e.search_on { search_bar(app, t, e) }

	n := len(e.rows)
	idx := row_index(e, e.selected)
	if e.reveal && idx >= 0 { e.list.reveal, e.list.sel = idx, idx; e.reveal = false }
	menu_key := ui.key_from_string(0, "###dt_el_menu")
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {}, "###dt_el_tree_col") {
		editing_html := e.edit == .Html
		if n == 0 {
			dt_empty("###dt_el_empty", .Tab_Elements, "The document is empty", "Nothing to show yet.")
		} else if rows, ok := dt_list("###dt_el_list", &e.list, n, dtm.row, nil, ui.fill(), editing_html ? ui.px(dtm.row * 6) : ui.fill()); ok {
			for k in rows.first ..< rows.last {
				r := &e.rows[k]
				if e.edit != .None && e.edit != .Html && e.edit_h == r.h && r.kind != .Close {
					edit_row(app, t, e, r, k)
					continue
				}
				d := ui.frame_new(El_Draw)
				d.row, d.kind, d.depth = r, r.kind, r.depth
				d.label = dt_frame_str(r.label)
				d.tail = r.tail
				d.chevron = r.expandable ? (r.expanded ? 1 : 0) : -1
				#partial switch r.kind {
				case .Open, .Inline, .Close: d.runs = syn_runs(d.label, .HTML)
				}
				d.text_col = dtc.text
				d.selected = e.selected == r.h && r.kind != .Close
				d.focused = e.list.focused
				d.drop_line = -1
				if e.drag_h != base.NIL_HANDLE && e.drop_row == k {
					switch e.drop_pos {
					case 0: d.drop_line = 0
					case 2: d.drop_line = 1
					case 1: d.drop_inside = true
					}
				}
				for f in e.found { if f == r.h && r.kind != .Close { d.found = true; break } }
				ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
				rb := ui.build_box({.Clickable}, fmt.tprintf("###elr%d_%d", u64(r.h), int(r.kind) == int(El_Kind.Close) ? 1 : 0))
				sig := ui.signal(rb)
				d.hot = sig.hovering
				rb.custom, rb.custom_user = el_paint, d
				if sig.hovering && r.kind != .Close { e.hover = r.h }
				row_input(app, t, e, r, k, sig, rb, menu_key)
			}
		}
		if editing_html { html_editor(app, t, e) }
	}
	tree_keys(app, t, e, n)
	elements_menu(app, t, e, menu_key)
	breadcrumb(app, t, e)
}

@(private = "file")
row_input :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, r: ^El_Row, k: int, sig: ui.Signal, rb: ^ui.Box, menu_key: ui.Key) {
	x := sig.mouse.x - dt_px(6) - f32(r.depth) * dt_px(EL_INDENT)
	if sig.pressed && r.kind != .Close {
		e.selected = r.h
		e.list.sel = k
		ui.set_focus(e.list.key)
		if r.expandable && x >= -dt_px(2) && x < dt_px(13) { toggle(e, r.h) }
	}
	if sig.double_clicked && r.kind != .Close { begin_edit_at(app, t, e, r, sig.mouse.x, k) }
	if sig.right_clicked {
		e.selected = r.h
		e.list.sel = k
		e.menu_row = k
		e.menu_has_span = false
		if sp, ok := attr_at(r, sig.mouse.x - dt_px(6) - f32(r.depth) * dt_px(EL_INDENT) - dt_px(13)); ok { e.menu_span, e.menu_has_span = sp, true }
		ui.ctx_menu_open(menu_key, ui.mouse_pos())
	}
	// dragging a node to another place
	if sig.dragging && r.kind != .Close && r.kind != .Doctype && (math.abs(sig.drag_delta.y) > dt_px(5)) {
		e.drag_h = r.h
		lb := ui.box_from_key(e.list.key)
		if lb != nil {
			mp := ui.mouse_pos()
			idx := int((mp.y - lb.rect.min.y + lb.view_off.y) / dtm.row)
			idx = clamp(idx, 0, len(e.rows) - 1)
			e.drop_row = idx
			rel := (mp.y - lb.rect.min.y + lb.view_off.y) - f32(idx) * dtm.row
			e.drop_pos = rel < dtm.row * 0.28 ? 0 : (rel > dtm.row * 0.72 ? 2 : 1)
			if e.rows[idx].kind == .Close { e.drop_pos = 0 }
			app.frames_requested = max(app.frames_requested, 2)
		}
	}
	if !sig.dragging && e.drag_h == r.h {
		finish_drag(app, t, e)
	}
}

@(private = "file")
finish_drag :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	h := e.drag_h
	e.drag_h = base.NIL_HANDLE
	if t.page == nil || e.drop_row < 0 || e.drop_row >= len(e.rows) { return }
	target := e.rows[e.drop_row]
	if target.h == h { return }
	parent, before := base.NIL_HANDLE, base.NIL_HANDLE
	d := t.page.doc
	tn := dom.get(d, target.h)
	if tn == nil { return }
	switch {
	case target.kind == .Close: parent = target.h   // before the closing tag: the last child
	case e.drop_pos == 1 && tn.kind == .Element: parent = target.h; before = base.NIL_HANDLE
	case e.drop_pos == 2: parent, before = tn.parent, tn.next
	case: parent, before = tn.parent, target.h
	}
	if parent == base.NIL_HANDLE { return }
	// not into itself
	for cur := parent; cur != base.NIL_HANDLE; { if cur == h { return }; cn := dom.get(d, cur); if cn == nil { break }; cur = cn.parent }
	if why := page.dev_move_node(t.page, h, parent, before); why != "" { ui.toast(.Warn, "Elements: %s", why) } else { e.expanded[parent] = true; e.version += 1; e.selected = h; app.frames_requested = max(app.frames_requested, 3) }
}

// The attribute under x (pixels from the start of the label).
@(private = "file")
attr_at :: proc(r: ^El_Row, x: f32) -> (El_Span, bool) {
	if r.kind != .Open && r.kind != .Inline { return {}, false }
	for sp in r.attrs {
		a := dt_w(dtm.mono, dtm.mono_fs, r.label[:sp.name_a])
		end := sp.val_b >= 0 ? sp.val_b + 1 : sp.name_b
		b := dt_w(dtm.mono, dtm.mono_fs, r.label[:min(end, len(r.label))])
		if x >= a && x <= b { return sp, true }
	}
	return {}, false
}

////////////////////////////////
// Editing

@(private = "file")
begin_edit_at :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, r: ^El_Row, mouse_x: f32, k: int) {
	if t.page == nil { return }
	x := mouse_x - dt_px(6) - f32(r.depth) * dt_px(EL_INDENT) - dt_px(13)
	switch r.kind {
	case .Text, .Comment:
		n := dom.get(t.page.doc, r.h)
		if n == nil { return }
		e.edit, e.edit_h = .Text, r.h
		ui.field_set(&e.field, strings.trim_space(n.text))
	case .Open, .Inline:
		if sp, ok := attr_at(r, x); ok {
			delete(e.edit_attr)
			name := r.label[sp.name_a:sp.name_b]
			e.edit_attr = strings.clone(name)
			// a click on the name edits the name, on the value (or the rest) edits the value
			on_name := x < dt_w(dtm.mono, dtm.mono_fs, r.label[:sp.name_b])
			e.edit, e.edit_h = on_name || sp.val_a < 0 ? .Attr_Name : .Attr_Value, r.h
			if e.edit == .Attr_Name { ui.field_set(&e.field, name) } else { ui.field_set(&e.field, r.label[sp.val_a:sp.val_b]) }
		} else {
			begin_html_edit(app, t, e, r.h)
			return
		}
	case .Close, .Doctype: return
	}
	e.focus_edit = true
	_ = k
}

@(private = "file")
begin_html_edit :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, h: base.Handle) {
	if t.page == nil { return }
	e.edit, e.edit_h = .Html, h
	ui.area_set(&e.area, page.dev_outer_html(t.page, h))
	e.focus_edit = true
}

@(private = "file")
begin_add_attr :: proc(e: ^Dev_Elements, h: base.Handle) {
	e.edit, e.edit_h = .Attr_New, h
	ui.field_clear(&e.field)
	e.focus_edit = true
	e.expanded[h] = e.expanded[h]
}

// The row being edited: a field of the row's own, in the place of its text.
@(private = "file")
edit_row :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, r: ^El_Row, k: int) {
	ui.next({width = ui.fill(), height = ui.px(dtm.row), axis = .X, cross = .Center})
	if ui.row(.Center, {}, fmt.tprintf("###ele%d", u64(r.h))) {
		ui.spacer(ui.px(dt_px(6) + f32(r.depth) * dt_px(EL_INDENT) + dt_px(13)))
		ui.next({width = ui.fill(), height = ui.pct(1), radius = dtm.radius, font = dtm.mono, font_size = dtm.mono_fs, text_pad = dt_px(4)})
		res := ui.line_edit("###dt_el_field", &e.field, e.edit == .Attr_New ? "name=\"value\"" : "")
		if e.focus_edit { if res.box != nil { ui.set_focus(res.box.key) }; e.focus_edit = false }
		if res.committed { commit_edit(app, t, e) }
		if res.cancelled { e.edit = .None }
		if !res.focused && !e.focus_edit && res.box != nil && ui.focus_key() != res.box.key && !res.pressed && e.edit != .None && e.edit_age > 2 { commit_edit(app, t, e) }
		e.edit_age += 1
	}
}

@(private = "file")
commit_edit :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	defer { e.edit = .None; e.edit_age = 0; e.version += 1; app.frames_requested = max(app.frames_requested, 3) }
	if t.page == nil { return }
	text := ui.field_string(&e.field)
	switch e.edit {
	case .Attr_Value: page.dev_set_attribute(t.page, e.edit_h, e.edit_attr, text)
	case .Attr_Name:
		n := dom.get(t.page.doc, e.edit_h)
		if n == nil || text == "" || text == e.edit_attr { return }
		val, _ := dom.get_attribute(t.page.doc, e.edit_h, e.edit_attr)
		page.dev_remove_attribute(t.page, e.edit_h, e.edit_attr)
		page.dev_set_attribute(t.page, e.edit_h, text, val)
	case .Attr_New:
		s := strings.trim_space(text)
		if s == "" { return }
		eq := strings.index_byte(s, '=')
		name, val := s, ""
		if eq >= 0 { name, val = strings.trim_space(s[:eq]), strings.trim(strings.trim_space(s[eq + 1:]), "\"'") }
		if name != "" { page.dev_set_attribute(t.page, e.edit_h, name, val) }
	case .Text: page.dev_set_text(t.page, e.edit_h, text)
	case .Html, .None:
	}
}

@(private = "file")
html_editor :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	ui.next({width = ui.fill(), height = ui.px(dtm.row * 6), axis = .Y, bg = dtc.bar, border = dtc.border})
	box := ui.build_box({.Draw_Background, .Draw_Side_Top}, "###dt_el_html")
	if ui.parent(box) {
		if dt_bar("###dt_el_hbar", dtm.bar - dt_px(6), rule = false) {
			dt_gap(6)
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.custom("###dt_el_hlab", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x, (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, "Edit as HTML  (Ctrl+Enter applies, Esc cancels)")
			}, nil)
			if dt_btn("###dt_el_happly", .Check, "Apply", tooltip = "Replace the element with this markup", shortcut = "Ctrl+Enter", accent = true).clicked { apply_html(app, t, e) }
			if dt_btn("###dt_el_hcancel", .Close, tooltip = "Cancel", shortcut = "Esc").clicked { e.edit = .None }
			dt_gap(3)
		}
		ui.next({width = ui.fill(), height = ui.fill(), radius = 0, font = dtm.mono, font_size = dtm.mono_fs})
		res := ui.text_edit("###dt_el_harea", &e.area)
		if e.focus_edit && res.box != nil { ui.set_focus(res.box.key); e.focus_edit = false }
		if res.focused && ui.key_press(.Return, {.Ctrl}) { apply_html(app, t, e) }
		if res.focused && ui.key_press(.Escape) { e.edit = .None }
	}
}

@(private = "file")
apply_html :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	if t.page == nil { e.edit = .None; return }
	if why := page.dev_set_outer_html(t.page, e.edit_h, ui.area_string(&e.area)); why != "" { ui.toast(.Warn, "Elements: %s", why); return }
	e.edit = .None
	e.version += 1
	app.frames_requested = max(app.frames_requested, 3)
}

////////////////////////////////
// Keys

@(private = "file")
tree_keys :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, n: int) {
	if ui.key_press(.F, {.Ctrl}) && dev.panel == .Elements { e.search_on = true }
	if !e.list.focused || n == 0 || e.edit != .None { return }
	old := e.list.sel
	if dt_list_keys(&e.list, n, max(int(e.list.view / dtm.row) - 1, 1)) {
		for i := e.list.sel; i >= 0 && i < n; i += e.list.sel >= old ? 1 : -1 {
			if e.rows[i].kind != .Close { e.selected = e.rows[i].h; e.list.sel = i; break }
			if i == 0 || i == n - 1 { break }
		}
	}
	if e.list.sel < 0 || e.list.sel >= n { return }
	r := &e.rows[e.list.sel]
	if ui.key_press(.Right) && r.expandable && !r.expanded { toggle(e, r.h) } else if ui.key_press(.Right) && r.expandable && r.expanded && e.list.sel + 1 < n { e.list.sel += 1; e.selected = e.rows[e.list.sel].h; e.list.reveal = e.list.sel }
	if ui.key_press(.Left) {
		if r.expandable && r.expanded { toggle(e, r.h) } else if r.depth > 0 {
			for j := e.list.sel - 1; j >= 0; j -= 1 {
				if e.rows[j].depth < r.depth && e.rows[j].kind != .Close { e.selected = e.rows[j].h; e.reveal = true; break }
			}
		}
	}
	if ui.key_press(.Return) { toggle_or_edit(app, t, e, r) }
	if ui.key_press(.F2) { begin_html_edit(app, t, e, r.h) }
	if ui.key_press(.Delete) || ui.key_press(.Backspace) { delete_node(app, t, e, r.h) }
	if ui.key_press(.C, {.Ctrl}) && t.page != nil { clip_set(page.dev_outer_html(t.page, r.h)) }
	if ui.key_press(.H) && t.page != nil { toggle_hidden(app, t, e, r.h) }
	if ui.key_press(.D, {.Ctrl}) { duplicate_node(app, t, e, r.h) }
}

@(private = "file")
toggle_or_edit :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, r: ^El_Row) {
	if r.expandable { toggle(e, r.h); return }
	if r.kind == .Text || r.kind == .Comment { begin_edit_at(app, t, e, r, 0, 0) } else if r.kind == .Open || r.kind == .Inline { begin_html_edit(app, t, e, r.h) }
}

@(private = "file")
delete_node :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, h: base.Handle) {
	if t.page == nil { return }
	if page.dev_remove_node(t.page, h) { e.selected = base.NIL_HANDLE; e.version += 1; app.frames_requested = max(app.frames_requested, 3) }
}

@(private = "file")
duplicate_node :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, h: base.Handle) {
	if t.page == nil { return }
	if c := page.dev_duplicate_node(t.page, h); c != base.NIL_HANDLE { e.selected = c; e.reveal = true; e.version += 1; app.frames_requested = max(app.frames_requested, 3) }
}

// `visibility: hidden` through the style attribute, as the browsers' "Hide element".
@(private = "file")
toggle_hidden :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, h: base.Handle) {
	if t.page == nil { return }
	decls := page.dev_inline_decls(t.page, h)
	b := strings.builder_make(context.temp_allocator)
	had := false
	for d in decls {
		if d.name == "visibility" && d.value == "hidden" { had = true; continue }
		fmt.sbprintf(&b, "%s: %s%s; ", d.name, d.value, d.important ? " !important" : "")
	}
	if !had { strings.write_string(&b, "visibility: hidden !important; ") }
	page.dev_set_style_attribute(t.page, h, strings.trim_space(strings.to_string(b)))
	e.version += 1
	app.frames_requested = max(app.frames_requested, 3)
}

////////////////////////////////
// Menu

@(private = "file")
elements_menu :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, key: ui.Key) {
	if ui.ctx_menu(key, dt_px(270)) { elements_menu_items(app, t, e) }
}

@(private = "file")
elements_menu_items :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	if e.menu_row < 0 || e.menu_row >= len(e.rows) || t.page == nil { ui.ctx_menu_close(); return }
	r := e.rows[e.menu_row]
	h := r.h
	is_el := r.kind == .Open || r.kind == .Inline
	if ui.menu_item("Add attribute###dt_em_add", "", enabled = is_el).clicked { begin_add_attr(e, h) }
	if ui.menu_item(e.menu_has_span ? "Edit attribute###dt_em_attr" : "Edit text###dt_em_text", "", enabled = is_el || r.kind == .Text || r.kind == .Comment).clicked {
		if e.menu_has_span {
			sp := e.menu_span
			delete(e.edit_attr)
			e.edit_attr = strings.clone(r.label[sp.name_a:sp.name_b])
			e.edit, e.edit_h = sp.val_a >= 0 ? .Attr_Value : .Attr_Name, h
			ui.field_set(&e.field, sp.val_a >= 0 ? r.label[sp.val_a:sp.val_b] : e.edit_attr)
			e.focus_edit = true
		} else if r.kind == .Text || r.kind == .Comment { begin_edit_at(app, t, e, &r, 0, 0) }
	}
	if ui.menu_item("Edit as HTML###dt_em_html", "F2", enabled = is_el).clicked { begin_html_edit(app, t, e, h) }
	ui.menu_separator()
	if ui.menu_item("Duplicate element###dt_em_dup", "Ctrl+D", enabled = is_el).clicked { duplicate_node(app, t, e, h) }
	if ui.menu_item("Delete element###dt_em_del", "Del", enabled = r.kind != .Close && r.kind != .Doctype).clicked { delete_node(app, t, e, h) }
	if ui.menu_item("Hide element###dt_em_hide", "H", enabled = is_el).clicked { toggle_hidden(app, t, e, h) }
	ui.menu_separator()
	if ui.menu_submenu("Copy###dt_em_copy") {
		if ui.menu_item("Copy outerHTML###dt_em_c_outer", "Ctrl+C").clicked { clip_set(page.dev_outer_html(t.page, h)) }
		if ui.menu_item("Copy innerHTML###dt_em_c_inner", enabled = is_el).clicked { clip_set(page.dev_inner_html(t.page, h)) }
		if ui.menu_item("Copy element###dt_em_c_el").clicked { clip_set(page.dev_outer_html(t.page, h)) }
		ui.menu_separator()
		if ui.menu_item("Copy selector###dt_em_c_sel", enabled = is_el).clicked { clip_set(css_selector_of(t.page, h)) }
		if ui.menu_item("Copy JS path###dt_em_c_js", enabled = is_el).clicked { clip_set(fmt.tprintf("document.querySelector('%s')", css_selector_of(t.page, h))) }
		if ui.menu_item("Copy XPath###dt_em_c_xp", enabled = is_el).clicked { clip_set(xpath_of(t.page, h, false)) }
		if ui.menu_item("Copy full XPath###dt_em_c_fxp", enabled = is_el).clicked { clip_set(xpath_of(t.page, h, true)) }
	}
	if ui.menu_submenu("Force state###dt_em_state") {
		f := page.dev_forced(t.page)
		if f.el != h { f = {} }
		toggle :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, h: base.Handle, f: page.Forced_State, which: int) {
			g := f
			switch which {
			case 0: g.active = !g.active
			case 1: g.hover = !g.hover
			case 2: g.focus = !g.focus
			case 3: g.visited = !g.visited
			}
			page.dev_force_state(t.page, h, g.hover, g.active, g.focus, g.visited)
			e.version += 1
			app.frames_requested = max(app.frames_requested, 3)
		}
		if ui.menu_item(":active###dt_em_s_a", checked = f.active, enabled = is_el, keep_open = true).clicked { toggle(app, t, e, h, f, 0) }
		if ui.menu_item(":hover###dt_em_s_h", checked = f.hover, enabled = is_el, keep_open = true).clicked { toggle(app, t, e, h, f, 1) }
		if ui.menu_item(":focus###dt_em_s_f", checked = f.focus, enabled = is_el, keep_open = true).clicked { toggle(app, t, e, h, f, 2) }
		if ui.menu_item(":visited###dt_em_s_v", checked = f.visited, enabled = is_el, keep_open = true).clicked { toggle(app, t, e, h, f, 3) }
		ui.menu_separator()
		if ui.menu_item("Clear forced states###dt_em_s_clear", enabled = page.dev_forced(t.page).el != base.NIL_HANDLE).clicked {
			page.dev_force_state(t.page, base.NIL_HANDLE, false, false, false, false)
			e.version += 1
			app.frames_requested = max(app.frames_requested, 3)
		}
	}
	ui.menu_separator()
	if ui.menu_item("Expand all underneath###dt_em_exp", enabled = r.expandable).clicked { budget := 5000; toggle_all(e, t.page.doc, h, true, &budget) }
	if ui.menu_item("Collapse all underneath###dt_em_col", enabled = r.expandable).clicked { budget := 5000; toggle_all(e, t.page.doc, h, false, &budget) }
	if ui.menu_item("Scroll into view###dt_em_scroll", enabled = is_el).clicked { scroll_into_view(app, t, h) }
	if ui.menu_item("Store as global variable###dt_em_store", enabled = r.kind != .Close && r.kind != .Doctype).clicked {
		dev.con.evaluating = true
		if page.dev_store_node(t.page, h) { ui.toast(.Info, "Stored as a global variable: see the Console") } else { ui.toast(.Warn, "This node is not in the document's own tree (a shadow tree or a detached node)") }
		dev.con.evaluating = false
	}
	if sp := e.menu_span; e.menu_has_span && sp.val_a >= 0 {
		val := r.label[sp.val_a:sp.val_b]
		name := r.label[sp.name_a:sp.name_b]
		if name == "href" || name == "src" || name == "srcset" || name == "action" {
			ui.menu_separator()
			if ui.menu_item("Open in a new tab###dt_em_open").clicked { open_in_new_tab(app, strings.clone(val, context.temp_allocator), inspected_page(app)) }
		}
	}
}

@(private = "file")
scroll_into_view :: proc(app: ^App, t: ^Tab, h: base.Handle) {
	if t.page == nil || !t.layout.valid { return }
	view := draw.rect_size(app.page_rect)
	if r, ok := lay.box_of(&t.layout, h, view, 0); ok { t.scroll = max(r.border.min.y - view.y * 0.15, 0); app.frames_requested = max(app.frames_requested, 3) }
}

// A CSS selector that finds `h` among its siblings and above: #id when there is one, else tag.class:nth-of-type chains.
css_selector_of :: proc(p: ^page.Page, h: base.Handle) -> string {
	d := p.doc
	parts := make([dynamic]string, context.temp_allocator)
	cur := h
	for cur != base.NIL_HANDLE {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { break }
		if id, ok := dom.get_attribute(d, cur, "id"); ok && id != "" && !strings.contains_any(id, " .:#[]") {
			append(&parts, fmt.tprintf("#%s", id))
			break
		}
		part := n.name
		if cls, ok := dom.get_attribute(d, cur, "class"); ok && strings.trim_space(cls) != "" {
			for c in strings.fields(cls, context.temp_allocator) { if !strings.contains_any(c, ":[]/.") { part = fmt.tprintf("%s.%s", part, c) } }
		}
		// the position among siblings of the same tag
		if n.parent != base.NIL_HANDLE {
			pn := dom.get(d, n.parent)
			same, idx := 0, 0
			for s := pn.first_child; s != base.NIL_HANDLE; {
				sn := dom.get(d, s)
				if sn == nil { break }
				if sn.kind == .Element && sn.name == n.name { same += 1; if s == cur { idx = same } }
				s = sn.next
			}
			if same > 1 { part = fmt.tprintf("%s:nth-of-type(%d)", part, idx) }
		}
		append(&parts, part)
		cur = n.parent
		if pn := dom.get(d, cur); pn != nil && pn.kind != .Element { break }
	}
	b := strings.builder_make(context.temp_allocator)
	for i := len(parts) - 1; i >= 0; i -= 1 {
		strings.write_string(&b, parts[i])
		if i > 0 { strings.write_string(&b, " > ") }
	}
	return strings.to_string(b)
}

xpath_of :: proc(p: ^page.Page, h: base.Handle, full: bool) -> string {
	d := p.doc
	parts := make([dynamic]string, context.temp_allocator)
	cur := h
	for cur != base.NIL_HANDLE {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { break }
		if !full {
			if id, ok := dom.get_attribute(d, cur, "id"); ok && id != "" {
				append(&parts, fmt.tprintf("*[@id=\"%s\"]", id))
				b := strings.builder_make(context.temp_allocator)
				strings.write_string(&b, "//")
				for i := len(parts) - 1; i >= 0; i -= 1 { strings.write_string(&b, parts[i]); if i > 0 { strings.write_byte(&b, '/') } }
				return strings.to_string(b)
			}
		}
		idx, same := 0, 0
		if n.parent != base.NIL_HANDLE {
			pn := dom.get(d, n.parent)
			for s := pn.first_child; s != base.NIL_HANDLE; {
				sn := dom.get(d, s)
				if sn == nil { break }
				if sn.kind == .Element && sn.name == n.name { same += 1; if s == cur { idx = same } }
				s = sn.next
			}
		}
		append(&parts, same > 1 || full ? fmt.tprintf("%s[%d]", n.name, max(idx, 1)) : n.name)
		cur = n.parent
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '/')
	for i := len(parts) - 1; i >= 0; i -= 1 { strings.write_byte(&b, '/'); strings.write_string(&b, parts[i]) }
	return strings.to_string(b)
}

////////////////////////////////
// Search

@(private = "file")
search_bar :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	if dt_bar("###dt_el_sbar", dtm.bar - dt_px(4)) {
		dt_gap(3)
		res := dt_search("###dt_el_sfield", &e.search, "Find by string, selector or XPath", 0, false)
		ser := dt_filter_serial(&e.search)
		if ser != e.found_key || res.changed { run_search(t, e); e.found_key = ser }
		if res.committed && ui.key_press(.Return, {.Shift}) { step_search(app, t, e, -1) } else if res.committed { step_search(app, t, e, 1) }
		if res.cancelled { e.search_on = false; clear(&e.found) }
		count := len(e.found)
		ui.next({width = ui.px(dt_px(70)), height = ui.pct(1)})
		ui.custom("###dt_el_scount", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			s := (^string)(user)^
			dt_text_r(dc, dtm.ui_font, dtm.fs * 0.92, b.rect.max.x - dt_px(4), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, s)
		}, new_clone(dt_frame_str(count == 0 ? (dt_filter_active(&e.search) ? "0 results" : "") : fmt.tprintf("%d / %d", e.found_at + 1, count)), ui.frame_allocator()))
		if dt_btn("###dt_el_sprev", .Chevron_Up, tooltip = "Previous result", shortcut = "Shift+Enter", enabled = count > 0).clicked { step_search(app, t, e, -1) }
		if dt_btn("###dt_el_snext", .Chevron_Down, tooltip = "Next result", shortcut = "Enter", enabled = count > 0).clicked { step_search(app, t, e, 1) }
		if dt_btn("###dt_el_sclose", .Close, tooltip = "Close the search", shortcut = "Esc").clicked { e.search_on = false; clear(&e.found) }
	}
}

// Every node whose tag, an attribute (name or value) or text holds the query, or that a selector or an XPath of tags finds.
@(private = "file")
run_search :: proc(t: ^Tab, e: ^Dev_Elements) {
	clear(&e.found)
	e.found_at = 0
	q := dt_filter_text(&e.search)
	if q == "" || t.page == nil { return }
	d := t.page.doc
	lq := strings.to_lower(q, context.temp_allocator)
	sel := strings.has_prefix(q, "//")
	path := sel ? strings.split(strings.trim_prefix(q, "//"), "/", context.temp_allocator) : nil
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, d.root)
	budget := 400000
	for len(stack) > 0 && budget > 0 && len(e.found) < 5000 {
		h := pop(&stack)
		budget -= 1
		n := dom.get(d, h)
		if n == nil { continue }
		hit := false
		switch n.kind {
		case .Element:
			if sel {
				hit = len(path) > 0 && n.name == path[len(path) - 1]
			} else {
				if dt_contains_fold(n.name, lq) { hit = true }
				for a in n.attrs { if dt_contains_fold(a.name, lq) || dt_contains_fold(a.value, lq) { hit = true; break } }
			}
		case .Text, .Comment:
			hit = !sel && dt_contains_fold(n.text, lq)
		case .Document, .Fragment, .Doctype:
		}
		if hit { append(&e.found, h) }
		// children pushed in reverse so that the results come in document order
		last := base.NIL_HANDLE
		for c := n.first_child; c != base.NIL_HANDLE; { last = c; cn := dom.get(d, c); if cn == nil { break }; c = cn.next }
		for c := last; c != base.NIL_HANDLE; { append(&stack, c); cn := dom.get(d, c); if cn == nil { break }; c = cn.prev }
	}
	if len(e.found) > 0 { elements_select(t, e.found[0]) }
}

@(private = "file")
step_search :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements, dir: int) {
	if len(e.found) == 0 { return }
	e.found_at = (e.found_at + dir) %% len(e.found)
	elements_select(t, e.found[e.found_at])
	app.frames_requested = max(app.frames_requested, 2)
}

////////////////////////////////
// The breadcrumb

@(private = "file")
Crumb_Draw :: struct { label: string, current, hot: bool, first: bool }

@(private = "file")
breadcrumb :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2)), axis = .X, cross = .Center, bg = dtc.bar, border = dtc.border})
	bar := ui.build_box({.Draw_Background, .Draw_Side_Top, .Clip}, "###dt_el_crumbs")
	ui.push_parent(bar)
	defer ui.pop_parent()
	avail := (bar.size.x > 0 ? bar.size.x : f32(600)) - dt_px(16)
	// from the selected node outward while it fits
	total: f32
	first := len(e.crumbs)
	for i := len(e.crumbs) - 1; i >= 0; i -= 1 {
		w := dt_w(dtm.mono, dtm.mono_fs * 0.95, e.crumbs[i].label) + dt_px(16)
		if total + w > avail && i < len(e.crumbs) - 1 { break }
		total += w
		first = i
	}
	if first > 0 {
		ui.next({width = ui.px(dt_px(18)), height = ui.pct(1)})
		ui.custom("###dt_cr_more", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) { dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(6), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, "\u2026") }, nil)
	}
	for i in first ..< len(e.crumbs) {
		c := e.crumbs[i]
		w := dt_w(dtm.mono, dtm.mono_fs * 0.95, c.label) + dt_px(16)
		ui.next({width = ui.px(math.round(w)), height = ui.pct(1), cursor = .Arrow})
		cb := ui.build_box({.Clickable}, fmt.tprintf("###dt_cr%d", i))
		sig := ui.signal(cb)
		cd := ui.frame_new(Crumb_Draw)
		cd.label, cd.current, cd.hot, cd.first = dt_frame_str(c.label), c.h == e.selected, sig.hovering, i == first
		cb.custom, cb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			d := (^Crumb_Draw)(user)
			r := b.rect
			cy := (r.min.y + r.max.y) * 0.5
			if d.current { draw.rect(dc, {{r.min.x + dt_px(2), r.min.y + dt_px(3)}, {r.max.x - dt_px(2), r.max.y - dt_px(3)}}, dtc.accent_bg, dtm.radius) } else if d.hot { draw.rect(dc, {{r.min.x + dt_px(2), r.min.y + dt_px(3)}, {r.max.x - dt_px(2), r.max.y - dt_px(3)}}, dtc.hover, dtm.radius) }
			dt_text(dc, dtm.mono, dtm.mono_fs * 0.95, r.min.x + dt_px(8), cy, d.current ? dtc.text : dtc.weak, d.label)
			if !d.first { dt_icon(dc, .Chevron_Right, {r.min.x, cy}, dtm.icon * 0.6, dtc.faint, dtm.sc) }
		}, cd
		if sig.hovering { e.hover = c.h }
		if sig.clicked { elements_select(t, c.h) }
	}
}

// The ancestors of the selected node, from the document element down.
@(private = "file")
crumbs_make :: proc(p: ^page.Page, e: ^Dev_Elements) {
	for c in e.crumbs { delete(c.label) }
	clear(&e.crumbs)
	chain := make([dynamic]base.Handle, context.temp_allocator)
	for cur := e.selected; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil || n.kind == .Document { break }
		append(&chain, cur)
		cur = n.parent
	}
	for i := len(chain) - 1; i >= 0; i -= 1 {
		n := dom.get(p.doc, chain[i])
		label: string
		if n.kind == .Element {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, n.name)
			if id, ok := dom.get_attribute(p.doc, chain[i], "id"); ok && id != "" { fmt.sbprintf(&b, "#%s", dev_line(id, 24)) }
			if cls, ok := dom.get_attribute(p.doc, chain[i], "class"); ok {
				k := 0
				for c in strings.fields(cls, context.temp_allocator) { if k >= 2 { strings.write_string(&b, "\u2026"); break }; fmt.sbprintf(&b, ".%s", dev_line(c, 20)); k += 1 }
			}
			label = strings.to_string(b)
		} else { label = n.kind == .Text ? "#text" : "#comment" }
		append(&e.crumbs, El_Crumb{h = chain[i], label = strings.clone(label)})
	}
}

////////////////////////////////
// The picker and the overlay

// While picking (Ctrl+Shift+C): the element under the pointer in the page is shown, a click selects it.
@(private = "file")
elements_picker :: proc(app: ^App, t: ^Tab, e: ^Dev_Elements) {
	e.picked = base.NIL_HANDLE
	if !dev.picking { return }
	mp := ui.mouse_pos()
	if !draw.rect_contains(app.page_rect, mp) || !t.layout.valid { return }
	h := hit_test(&t.layout, mp - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll)
	if h == base.NIL_HANDLE { return }
	e.picked = h
	app.frames_requested = max(app.frames_requested, 2)
}

// Called by route_page_input for each event of the frame while picking: the click picks, nothing reaches the page.
devtools_pick_event :: proc(app: ^App, t: ^Tab, kind: int, pos: draw.Vec2, pressed: bool) -> bool {
	if !dev.picking || !dev.visible || t == nil || t.page == nil { return false }
	if !draw.rect_contains(app.page_rect, pos) { return false }
	if pressed {
		h := dev.els.picked
		if h == base.NIL_HANDLE && t.layout.valid { h = hit_test(&t.layout, pos - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll) }
		if h != base.NIL_HANDLE { elements_select(t, h) }
		dev.picking = false
		app.frames_requested = max(app.frames_requested, 3)
	}
	return true
}

// The box of `h` over the page (devtools_overlay): content blue, padding green, border yellow, margin orange, as Chromium's,
// with a label of its tag, classes and size.
elements_overlay :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, area: draw.Rect, target: base.Handle) {
	h := target
	p := t.page
	if p == nil || p.closed || !t.layout.valid { return }
	n := dom.get(p.doc, h)
	if n == nil { return }
	if n.kind != .Element { h = n.parent }
	r, ok := lay.box_of(&t.layout, h, draw.rect_size(area), t.scroll)
	if !ok || !r.visible { return }
	shift := draw.Vec2{area.min.x, area.min.y - (r.fixed ? 0 : t.scroll)}
	at :: proc(q: lay.Rect, s: draw.Vec2) -> draw.Rect { return {q.min + s, q.max + s} }
	draw.push_clip(dc, area)
	defer draw.pop_clip(dc)
	if r.transformed {
		draw.rect(dc, at(r.bounds, shift), draw.Color{0.25, 0.55, 0.95, 0.30})
	} else {
		// the margin box, from the computed margins
		m := [4]f32{px_of(p, h, "margin-top"), px_of(p, h, "margin-right"), px_of(p, h, "margin-bottom"), px_of(p, h, "margin-left")}
		sc := t.zoom > 0 ? t.zoom : 1
		bx := r.border
		mb := lay.Rect{{bx.min.x - m[3] * sc, bx.min.y - m[0] * sc}, {bx.max.x + m[1] * sc, bx.max.y + m[2] * sc}}
		draw.rect(dc, at(mb, shift), draw.Color{0.97, 0.62, 0.30, 0.26})
		draw.rect(dc, at(r.border, shift), draw.Color{0.98, 0.80, 0.30, 0.30})
		draw.rect(dc, at(r.padding, shift), draw.Color{0.45, 0.72, 0.32, 0.30})
		draw.rect(dc, at(r.content, shift), draw.Color{0.30, 0.55, 0.95, 0.32})
	}
	b := at(r.bounds, shift)
	draw.rect(dc, b, draw.Color{0.30, 0.55, 0.95, 0.95}, 0, 1)
	// the label: tag#id.class  width x height
	label := css_label(p, h)
	size := fmt.tprintf("%d \u00d7 %d", int(math.round((r.border.max.x - r.border.min.x) / (max(t.zoom, 0.01) * ui.scale()))), int(math.round((r.border.max.y - r.border.min.y) / (max(t.zoom, 0.01) * ui.scale()))))
	text := fmt.tprintf("%s   %s", label, size)
	fs := dtm.fs > 0 ? dtm.fs : 12 * ui.scale()
	f := dtm.ui_font != 0 ? dtm.ui_font : app.ui_font
	w := dt_w(f, fs, text) + 14
	hh := fs * 1.7
	x := clamp(b.min.x, area.min.x, max(area.max.x - w, area.min.x))
	y := b.min.y - hh - 3
	if y < area.min.y { y = min(b.max.y + 3, area.max.y - hh) }
	draw.rect(dc, {{x, y}, {x + w, y + hh}}, draw.Color{0.12, 0.14, 0.20, 0.95}, 4)
	draw.rect(dc, {{x, y}, {x + w, y + hh}}, draw.Color{0.30, 0.55, 0.95, 0.9}, 4, 1)
	draw.text(dc, f, fs, {x + 7, math.round(y + hh * 0.5 + fs * 0.34)}, draw.Color{0.93, 0.95, 1, 1}, text)
}

@(private = "file")
px_of :: proc(p: ^page.Page, h: base.Handle, name: string) -> f32 {
	v := page.computed_property(p, h, name)
	f: f32
	neg := false
	i := 0
	if i < len(v) && v[i] == '-' { neg = true; i += 1 }
	div: f32 = 0
	for i < len(v) {
		c := v[i]
		if c == '.' { div = 1 } else if c >= '0' && c <= '9' {
			if div > 0 { div *= 10; f += f32(c - '0') / div } else { f = f * 10 + f32(c - '0') }
		} else { break }
		i += 1
	}
	return neg ? -f : f
}

// "div#hero.card.big" for the label of the overlay.
@(private = "file")
css_label :: proc(p: ^page.Page, h: base.Handle) -> string {
	n := dom.get(p.doc, h)
	if n == nil { return "" }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, n.name)
	if id, ok := dom.get_attribute(p.doc, h, "id"); ok && id != "" { fmt.sbprintf(&b, "#%s", dev_line(id, 30)) }
	if cls, ok := dom.get_attribute(p.doc, h, "class"); ok { for c in strings.fields(cls, context.temp_allocator) { fmt.sbprintf(&b, ".%s", dev_line(c, 24)) } }
	return strings.to_string(b)
}

// Whether the Elements tab wants the tree's rows made again for the current selection (called by styles_refresh).
elements_crumbs_for :: proc(p: ^page.Page, e: ^Dev_Elements) { crumbs_make(p, e) }
