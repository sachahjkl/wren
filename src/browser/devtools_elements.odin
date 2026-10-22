package browser

// The Elements tab: the document of the tab as a tree (expand / collapse with the arrow, a double click or Left / Right),
// the selected node's attributes and computed style next to it, and the node's box drawn over the page (the hovered row's,
// else the selected one's; devtools_overlay). "Inspect" in the page's context menu selects the element under the pointer.
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

El_Row :: struct {
	h:          base.Handle,
	depth:      int,
	label:      string,   // owned
	expandable: bool,
	expanded:   bool,
	kind:       dom.Node_Kind,
}

Dev_Elements :: struct {
	list:      ui.Virtual_List,
	ids:       [dynamic]u64,
	rows:      [dynamic]El_Row,
	expanded:  map[base.Handle]bool,
	page:      rawptr,         // the page the rows, the expansion and the selection are of
	mutations: u64,            // the document's, when the rows were made
	version:   u64,            // bumped by an expansion; rows_version: the one the rows were made for
	rows_version: u64,
	selected:  base.Handle,
	hover:     base.Handle,    // the row under the pointer this frame (the page shows its box)
	reveal:    bool,           // scroll the selected row into view at the next list
	// the details of the selected node
	det_h:     base.Handle,
	det_page:  rawptr,
	det_mut:   u64,
	det_title: string,         // owned
	attrs:     [dynamic][2]string,   // owned
	styles:    [dynamic][2]string,   // owned
}

elements_destroy :: proc() {
	e := &dev.els
	rows_free(e)
	delete(e.rows)
	delete(e.ids)
	delete(e.expanded)
	details_free(e)
	delete(e.attrs)
	delete(e.styles)
	ui.vlist_destroy(&e.list)
	e^ = {}
}

@(private = "file")
rows_free :: proc(e: ^Dev_Elements) {
	for r in e.rows { delete(r.label) }
	clear(&e.rows)
	clear(&e.ids)
}

@(private = "file")
details_free :: proc(e: ^Dev_Elements) {
	delete(e.det_title)
	e.det_title = ""
	for a in e.attrs { delete(a[0]); delete(a[1]) }
	clear(&e.attrs)
	for s in e.styles { delete(s[0]); delete(s[1]) }
	clear(&e.styles)
	e.det_h = base.NIL_HANDLE
}

// The page changed (a navigation): nothing of the old one is kept.
@(private = "file")
elements_reset :: proc(e: ^Dev_Elements, p: rawptr) {
	rows_free(e)
	clear(&e.expanded)
	details_free(e)
	e.page, e.selected, e.hover, e.mutations, e.rows_version = p, base.NIL_HANDLE, base.NIL_HANDLE, 0, 0
	e.version += 1
	ui.vlist_scroll_to(&e.list, 0)
}

@(private = "file")
row_label :: proc(d: ^dom.Document, h: base.Handle, n: ^dom.Node) -> string {
	switch n.kind {
	case .Element:
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "<%s", n.name)
		for a in n.attrs {
			if a.value == "" { fmt.sbprintf(&b, " %s", a.name) } else { fmt.sbprintf(&b, " %s=\"%s\"", a.name, a.value) }
		}
		strings.write_byte(&b, '>')
		return dev_line(strings.to_string(b), 220)
	case .Text:    return dev_line(strings.trim_space(n.text), 160)
	case .Comment: return dev_line(strings.concatenate({"<!-- ", strings.trim_space(n.text), " -->"}, context.temp_allocator), 160)
	case .Doctype: return dev_line(strings.concatenate({"<!doctype ", n.name, ">"}, context.temp_allocator), 120)
	case .Document, .Fragment: return ""
	}
	return ""
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
has_shown_child :: proc(d: ^dom.Document, n: ^dom.Node) -> bool {
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(d, c)
		if cn == nil { break }
		if shown(cn) { return true }
		c = cn.next
	}
	return false
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
	exp := n.kind == .Element && has_shown_child(d, n)
	open := exp && e.expanded[h]
	append(&e.rows, El_Row{h = h, depth = depth, label = strings.clone(row_label(d, h, n)), expandable = exp, expanded = open, kind = n.kind})
	append(&e.ids, u64(h))
	if open && depth < 200 {
		for c := n.first_child; c != base.NIL_HANDLE; {
			cn := dom.get(d, c)
			if cn == nil { break }
			flatten(e, d, c, depth + 1)
			c = cn.next
		}
	}
}

// The rows for the page, made again when the document or the expansion changed.
@(private = "file")
elements_refresh :: proc(t: ^Tab, e: ^Dev_Elements) {
	p := t.page
	if p == nil || p.closed { return }
	if rawptr(p) != e.page {
		elements_reset(e, rawptr(p))
		// first look: the document element and the body are open
		d := p.doc
		for c := dom.get(d, d.root).first_child; c != base.NIL_HANDLE; {
			cn := dom.get(d, c)
			if cn == nil { break }
			if cn.kind == .Element && cn.name == "html" {
				e.expanded[c] = true
				for g := cn.first_child; g != base.NIL_HANDLE; {
					gn := dom.get(d, g)
					if gn == nil { break }
					if gn.kind == .Element && gn.name == "body" { e.expanded[g] = true }
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

// The details of the selected node, made again when the node or the document changed.
@(private = "file")
details_refresh :: proc(t: ^Tab, e: ^Dev_Elements) {
	p := t.page
	if p == nil || p.closed || e.selected == base.NIL_HANDLE { details_free(e); return }
	if e.det_h == e.selected && e.det_page == rawptr(p) && e.det_mut == p.doc.mutations { return }
	details_free(e)
	e.det_h, e.det_page, e.det_mut = e.selected, rawptr(p), p.doc.mutations
	n := dom.get(p.doc, e.selected)
	if n == nil { return }
	e.det_title = strings.clone(row_label(p.doc, e.selected, n))
	if n.kind == .Element {
		for a in n.attrs { append(&e.attrs, [2]string{strings.clone(a.name), strings.clone(a.value)}) }
		for name in page.computed_property_names() {
			v := page.computed_property(p, e.selected, name)
			if v != "" { append(&e.styles, [2]string{strings.clone(name), strings.clone(v)}) }
		}
	} else {
		append(&e.attrs, [2]string{"text", strings.clone(n.text)})
	}
}

// Selects `h` and opens the way to it (the page's context menu, "Inspect").
elements_select :: proc(t: ^Tab, target: base.Handle) {
	h := target
	p := t.page
	if p == nil || p.closed { return }
	e := &dev.els
	if rawptr(p) != e.page { elements_refresh(t, e) }
	n := dom.get(p.doc, h)
	if n == nil { return }
	if n.kind != .Element && n.kind != .Text { h = n.parent }   // (a comment, the document...)
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
	for r, i in e.rows { if r.h == h { return i } }
	return -1
}

@(private = "file")
toggle :: proc(e: ^Dev_Elements, h: base.Handle) {
	e.expanded[h] = !e.expanded[h]
	e.version += 1
}

elements_panel :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	e := &dev.els
	if t.page == nil || t.page.closed {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3))})
		if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("No document.###dt_el_none") } }
		return
	}
	// the document is read only while the page is not running
	if !shell_nested() { elements_refresh(t, e); details_refresh(t, e) }
	e.hover = base.NIL_HANDLE

	wide := ui.parent_box().size.x == 0 || ui.parent_box().size.x >= em * 46
	ui.next({width = ui.fill(), height = ui.fill()})
	container := wide ? elements_row() : elements_column()
	_ = container
}

// The tree and the details side by side, or one above the other in a narrow panel.
@(private = "file")
elements_row :: proc() -> bool {
	if ui.row(.Start, {}, "###dt_el") {
		ui.next({width = ui.pct(0.58), height = ui.fill()})
		if ui.column(.Start, {.Clip}, "###dt_el_tree_box") { tree_view() }
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(.Start, {.Clip}, "###dt_el_det_box") { details_view() }
	}
	return true
}

@(private = "file")
elements_column :: proc() -> bool {
	if ui.column(.Start, {}, "###dt_el") {
		ui.next({width = ui.fill(), height = ui.pct(0.55)})
		if ui.column(.Start, {.Clip}, "###dt_el_tree_box") { tree_view() }
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column(.Start, {.Clip}, "###dt_el_det_box") { details_view() }
	}
	return true
}

@(private = "file")
Arrow_Draw :: struct { open: bool, color: draw.Color }

// A chevron: pointing right when the node is closed, down when it is open.
@(private = "file")
arrow_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	a := (^Arrow_Draw)(user)
	c := draw.rect_center(b.rect)
	s := (b.rect.max.x - b.rect.min.x) * 0.2
	th := math.max(math.round(1.4 * ui.scale()), 1)
	pts := [3]draw.Vec2{{-s * 0.6, -s}, {s * 0.5, 0}, {-s * 0.6, s}}
	if a.open { for &p in pts { p = {-p.y, p.x * 0.9 + s * 0.2} } }
	for i in 0 ..< 2 {
		p, q := c + pts[i], c + pts[i + 1]
		m := (p + q) * 0.5
		d := q - p
		length := math.sqrt(d.x * d.x + d.y * d.y)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.atan2(d.y, d.x)), m))
		draw.rect(dc, {{m.x - length * 0.5 - th * 0.5, m.y - th * 0.5}, {m.x + length * 0.5 + th * 0.5, m.y + th * 0.5}}, a.color, th * 0.5)
		draw.pop_transform(dc)
	}
}

@(private = "file")
tree_view :: proc() {
	em := ui.font_size()
	e := &dev.els
	idx := row_index(e, e.selected)
	if e.reveal && idx >= 0 { ui.list_select(&e.list.list, idx); e.reveal = false }
	e.list.sel = idx
	if rows, ok := ui.vlist("###dt_el_list", &e.list, e.ids[:]); ok {
		for k in rows.first ..< rows.last {
			r := &e.rows[k]
			ui.next({height = ui.px(ui.dense(em * 1.6))})
			row := ui.list_row(&e.list.list, k, "")
			if ui.hot_within(row.box.key) { e.hover = r.h }
			if ui.parent(row.box) {
				ui.spacer(ui.px(em * (0.5 + 1.1 * f32(math.min(r.depth, 40)))))
				ui.next({width = ui.px(em * 1.2), height = ui.pct(1), cursor = r.expandable ? .Hand : .Arrow})
				ab := ui.build_box({.Clickable}, fmt.aprintf("###ela%d", u64(r.h), allocator = ui.frame_allocator()))
				if r.expandable {
					arrow := ui.frame_new(Arrow_Draw)
					arrow^ = {open = r.expanded, color = ui.color("text")}
					arrow.color.a = 0.7
					ab.custom, ab.custom_user = arrow_draw, arrow
				}
				if ui.signal(ab).clicked && r.expandable { toggle(e, r.h) }
				weak := r.kind == .Text || r.kind == .Comment || r.kind == .Doctype
				ui.next({width = ui.fill(), height = ui.pct(1)})
				if weak { if ui.tags("weak") { ui.label(fmt.aprintf("%s###elr%d", r.label, u64(r.h), allocator = ui.frame_allocator())) } } else {
					ui.label(fmt.aprintf("%s###elr%d", r.label, u64(r.h), allocator = ui.frame_allocator()))
				}
			}
			if row.double_clicked && r.expandable { toggle(e, r.h) }
		}
	}
	if e.list.changed && e.list.sel >= 0 && e.list.sel < len(e.rows) { e.selected = e.rows[e.list.sel].h }
	// Right opens, Left closes (or goes to the parent), as in every tree
	if e.list.focused && e.list.sel >= 0 && e.list.sel < len(e.rows) {
		r := e.rows[e.list.sel]
		if ui.key_press(.Right) && r.expandable && !r.expanded { toggle(e, r.h) }
		if ui.key_press(.Left) {
			if r.expandable && r.expanded { toggle(e, r.h) } else if r.depth > 0 {
				for j := e.list.sel - 1; j >= 0; j -= 1 {
					if e.rows[j].depth < r.depth { e.selected = e.rows[j].h; e.reveal = true; break }
				}
			}
		}
	}
}

@(private = "file")
details_view :: proc() {
	em := ui.font_size()
	e := &dev.els
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
	if ui.row(.Center, {}, "###dt_el_title") {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.label(e.det_title != "" ? fmt.aprintf("%s###dt_el_t", e.det_title, allocator = ui.frame_allocator()) : "Select a node###dt_el_t")
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###dt_el_det") {
		if len(e.attrs) > 0 { detail_heading("Attributes", "a") }
		for a, i in e.attrs { detail_row(a[0], a[1], "a", i) }
		if len(e.styles) > 0 { detail_heading("Computed style", "s") }
		for s, i in e.styles { detail_row(s[0], s[1], "s", i) }
	}
}

@(private = "file")
detail_heading :: proc(title, id: string) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7))})
	if ui.row(.Center, {}, fmt.tprintf("###dt_dh_%s", id)) {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.aprintf("%s###dt_dht_%s", title, id, allocator = ui.frame_allocator()))
		}
	}
}

@(private = "file")
detail_row :: proc(name, value, id: string, i: int) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
	if ui.row(.Center, {}, fmt.tprintf("###dt_dr_%s%d", id, i)) {
		ui.spacer(ui.px(em * 1.0))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * 13), height = ui.pct(1)})
			ui.label(fmt.aprintf("%s###dt_dn_%s%d", dev_line(name, 40), id, i, allocator = ui.frame_allocator()))
		}
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.label(fmt.aprintf("%s###dt_dv_%s%d", dev_line(value, 300), id, i, allocator = ui.frame_allocator()))
	}
}

// The box of `h` over the page (devtools_overlay): content blue, padding green, border yellow, as Chromium's.
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
	if r.transformed {
		draw.rect(dc, at(r.bounds, shift), draw.Color{0.25, 0.55, 0.95, 0.30})
	} else {
		draw.rect(dc, at(r.border, shift), draw.Color{0.98, 0.80, 0.30, 0.38})
		draw.rect(dc, at(r.padding, shift), draw.Color{0.45, 0.72, 0.32, 0.38})
		draw.rect(dc, at(r.content, shift), draw.Color{0.30, 0.55, 0.95, 0.40})
	}
	draw.rect(dc, at(r.bounds, shift), draw.Color{0.30, 0.55, 0.95, 0.9}, 0, 1)
	draw.pop_clip(dc)
}
