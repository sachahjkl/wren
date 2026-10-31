package page

// Members of HTML elements that are tree operations (api/js_dom_html.widl): the table model's API (HTML §4.9: caption,
// tHead, tFoot, tBodies, insertRow / deleteRow, insertCell / deleteCell, the row and cell indexes), the "child text
// content" of <title> and <script> (title.text, script.text), and the methods of <dialog>.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"

@(private)
html_named :: #force_inline proc(n: ^dom.Node, name: string) -> bool {
	return n != nil && n.kind == .Element && n.ns == .HTML && n.name == name
}

@(private)
is_table_section :: proc(n: ^dom.Node) -> bool {
	return html_named(n, "thead") || html_named(n, "tbody") || html_named(n, "tfoot")
}

// The first child of `h` that is an HTML element `name`.
@(private)
first_child_named :: proc(d: ^dom.Document, h: base.Handle, name: string) -> base.Handle {
	for ch := dom.get(d, h).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if html_named(dom.get(d, ch), name) { return ch }
	}
	return base.NIL_HANDLE
}

// The table's rows collection (HTML §4.9.1): the rows of its thead children, then its tr children and the rows of its
// tbody children in tree order, then the rows of its tfoot children.
@(private)
table_rows :: proc(d: ^dom.Document, table: base.Handle) -> [dynamic]base.Handle {
	out := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	for pass in 0 ..< 3 {
		for ch := dom.get(d, table).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			cn := dom.get(d, ch)
			if pass == 1 && html_named(cn, "tr") { append(&out, ch); continue }
			want := pass == 0 ? html_named(cn, "thead") : pass == 2 ? html_named(cn, "tfoot") : html_named(cn, "tbody")
			if !want { continue }
			for r := cn.first_child; r != base.NIL_HANDLE; r = dom.get(d, r).next {
				if html_named(dom.get(d, r), "tr") { append(&out, r) }
			}
		}
	}
	return out
}

// The tr children of `h` (a section's rows), or its td / th children (a row's cells).
@(private)
children_named :: proc(d: ^dom.Document, h: base.Handle, cells: bool) -> [dynamic]base.Handle {
	out := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	for ch := dom.get(d, h).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		cn := dom.get(d, ch)
		if cells ? (html_named(cn, "td") || html_named(cn, "th")) : html_named(cn, "tr") { append(&out, ch) }
	}
	return out
}

@(private)
remove_node :: proc(d: ^dom.Document, h: base.Handle) {
	if h == base.NIL_HANDLE { return }
	dom.detach(d, h)
	dom.destroy_unpinned(d, h)
}

@(private)
index_of_handle :: proc(list: []base.Handle, h: base.Handle) -> i32 {
	for x, i in list { if x == h { return i32(i) } }
	return -1
}

// The first child that is neither a caption nor a colgroup: where a new thead goes.
@(private)
thead_position :: proc(d: ^dom.Document, table: base.Handle) -> base.Handle {
	for ch := dom.get(d, table).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		cn := dom.get(d, ch)
		if cn.kind == .Element && !html_named(cn, "caption") && !html_named(cn, "colgroup") { return ch }
	}
	return base.NIL_HANDLE
}

HTMLTableElement_caption :: proc(c: ^Call, table: Api_Element) -> u64 { return u64(first_child_named(c.page.doc, H(table.handle), "caption")) }
HTMLTableElement_tHead :: proc(c: ^Call, table: Api_Element) -> u64 { return u64(first_child_named(c.page.doc, H(table.handle), "thead")) }
HTMLTableElement_tFoot :: proc(c: ^Call, table: Api_Element) -> u64 { return u64(first_child_named(c.page.doc, H(table.handle), "tfoot")) }

HTMLTableElement_set_caption :: proc(c: ^Call, table: Api_Element, value: Api_Element) -> Api_Error {
	d := c.page.doc
	t := H(table.handle)
	if value.handle != 0 && !html_named(value.data, "caption") { return fail(c, .Type, "The value provided is not an HTMLTableCaptionElement.") }
	remove_node(d, first_child_named(d, t, "caption"))
	if value.handle == 0 { return .None }
	return pre_insert(c, t, H(value.handle), dom.get(d, t).first_child)
}

HTMLTableElement_set_tHead :: proc(c: ^Call, table: Api_Element, value: Api_Element) -> Api_Error {
	d := c.page.doc
	t := H(table.handle)
	if value.handle != 0 && !html_named(value.data, "thead") { return fail(c, .Hierarchy, "The value provided is not a thead element.") }
	remove_node(d, first_child_named(d, t, "thead"))
	if value.handle == 0 { return .None }
	return pre_insert(c, t, H(value.handle), thead_position(d, t))
}

HTMLTableElement_set_tFoot :: proc(c: ^Call, table: Api_Element, value: Api_Element) -> Api_Error {
	d := c.page.doc
	t := H(table.handle)
	if value.handle != 0 && !html_named(value.data, "tfoot") { return fail(c, .Hierarchy, "The value provided is not a tfoot element.") }
	remove_node(d, first_child_named(d, t, "tfoot"))
	if value.handle == 0 { return .None }
	return pre_insert(c, t, H(value.handle), base.NIL_HANDLE)
}

HTMLTableElement_createCaption :: proc(c: ^Call, table: Api_Element) -> u64 {
	d := c.page.doc
	t := H(table.handle)
	if h := first_child_named(d, t, "caption"); h != base.NIL_HANDLE { return u64(h) }
	h := dom.create_element(d, "caption")
	insert_node(d, t, h, dom.get(d, t).first_child)
	return u64(h)
}

HTMLTableElement_createTHead :: proc(c: ^Call, table: Api_Element) -> u64 {
	d := c.page.doc
	t := H(table.handle)
	if h := first_child_named(d, t, "thead"); h != base.NIL_HANDLE { return u64(h) }
	h := dom.create_element(d, "thead")
	insert_node(d, t, h, thead_position(d, t))
	return u64(h)
}

HTMLTableElement_createTFoot :: proc(c: ^Call, table: Api_Element) -> u64 {
	d := c.page.doc
	t := H(table.handle)
	if h := first_child_named(d, t, "tfoot"); h != base.NIL_HANDLE { return u64(h) }
	h := dom.create_element(d, "tfoot")
	insert_node(d, t, h, base.NIL_HANDLE)
	return u64(h)
}

HTMLTableElement_deleteCaption :: proc(c: ^Call, table: Api_Element) { remove_node(c.page.doc, first_child_named(c.page.doc, H(table.handle), "caption")) }
HTMLTableElement_deleteTHead :: proc(c: ^Call, table: Api_Element) { remove_node(c.page.doc, first_child_named(c.page.doc, H(table.handle), "thead")) }
HTMLTableElement_deleteTFoot :: proc(c: ^Call, table: Api_Element) { remove_node(c.page.doc, first_child_named(c.page.doc, H(table.handle), "tfoot")) }

// createTBody(): a new tbody after the last tbody child (or at the end).
HTMLTableElement_createTBody :: proc(c: ^Call, table: Api_Element) -> u64 {
	d := c.page.doc
	t := H(table.handle)
	last := base.NIL_HANDLE
	for ch := dom.get(d, t).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if html_named(dom.get(d, ch), "tbody") { last = ch }
	}
	h := dom.create_element(d, "tbody")
	insert_node(d, t, h, last != base.NIL_HANDLE ? dom.get(d, last).next : base.NIL_HANDLE)
	return u64(h)
}

HTMLTableElement_insertRow :: proc(c: ^Call, table: Api_Element, index: i32) -> (u64, Api_Error) {
	d := c.page.doc
	t := H(table.handle)
	rows := table_rows(d, t)
	if index < -1 || int(index) > len(rows) { return 0, fail(c, .Index_Size, "The index provided is outside the table's rows.") }
	row := dom.create_element(d, "tr")
	switch {
	case len(rows) == 0:
		last_body := base.NIL_HANDLE
		for ch := dom.get(d, t).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			if html_named(dom.get(d, ch), "tbody") { last_body = ch }
		}
		if last_body == base.NIL_HANDLE {
			body := dom.create_element(d, "tbody")
			dom.append_child(d, body, row)
			insert_node(d, t, body, base.NIL_HANDLE)
		} else {
			insert_node(d, last_body, row, base.NIL_HANDLE)
		}
	case index == -1 || int(index) == len(rows):
		insert_node(d, dom.get(d, rows[len(rows) - 1]).parent, row, base.NIL_HANDLE)
	case:
		ref := rows[index]
		insert_node(d, dom.get(d, ref).parent, row, ref)
	}
	return u64(row), .None
}

HTMLTableElement_deleteRow :: proc(c: ^Call, table: Api_Element, index: i32) -> Api_Error {
	d := c.page.doc
	rows := table_rows(d, H(table.handle))
	if index < -1 || int(index) >= len(rows) {
		if index == -1 { return .None }
		return fail(c, .Index_Size, "The index provided is outside the table's rows.")
	}
	remove_node(d, index == -1 ? rows[len(rows) - 1] : rows[index])
	return .None
}

// section.insertRow(index) / row.insertCell(index): the new element before the index-th, or at the end.
@(private)
insert_child_at :: proc(c: ^Call, parent: base.Handle, index: i32, cells: bool) -> (u64, Api_Error) {
	d := c.page.doc
	list := children_named(d, parent, cells)
	if index < -1 || int(index) > len(list) { return 0, fail(c, .Index_Size, "The index provided is out of range.") }
	h := dom.create_element(d, cells ? "td" : "tr")
	insert_node(d, parent, h, index == -1 || int(index) == len(list) ? base.NIL_HANDLE : list[index])
	return u64(h), .None
}

@(private)
delete_child_at :: proc(c: ^Call, parent: base.Handle, index: i32, cells: bool) -> Api_Error {
	d := c.page.doc
	list := children_named(d, parent, cells)
	if index < -1 || int(index) >= len(list) {
		if index == -1 { return .None }
		return fail(c, .Index_Size, "The index provided is out of range.")
	}
	remove_node(d, index == -1 ? list[len(list) - 1] : list[index])
	return .None
}

HTMLTableSectionElement_insertRow :: proc(c: ^Call, section: Api_Element, index: i32) -> (u64, Api_Error) { return insert_child_at(c, H(section.handle), index, false) }
HTMLTableSectionElement_deleteRow :: proc(c: ^Call, section: Api_Element, index: i32) -> Api_Error { return delete_child_at(c, H(section.handle), index, false) }
HTMLTableRowElement_insertCell :: proc(c: ^Call, row: Api_Element, index: i32) -> (u64, Api_Error) { return insert_child_at(c, H(row.handle), index, true) }
HTMLTableRowElement_deleteCell :: proc(c: ^Call, row: Api_Element, index: i32) -> Api_Error { return delete_child_at(c, H(row.handle), index, true) }

// row.rowIndex: its index in its table's rows, -1 outside a table.
HTMLTableRowElement_rowIndex :: proc(c: ^Call, row: Api_Element) -> i32 {
	d := c.page.doc
	parent := row.data.parent
	pn := jd_node(d, parent)
	if html_named(pn, "table") { rows := table_rows(d, parent); return index_of_handle(rows[:], H(row.handle)) }
	if is_table_section(pn) {
		if gp := pn.parent; html_named(jd_node(d, gp), "table") { rows := table_rows(d, gp); return index_of_handle(rows[:], H(row.handle)) }
	}
	return -1
}

// row.sectionRowIndex: its index in its parent's rows (a table's or a section's), else -1.
HTMLTableRowElement_sectionRowIndex :: proc(c: ^Call, row: Api_Element) -> i32 {
	d := c.page.doc
	parent := row.data.parent
	pn := jd_node(d, parent)
	if html_named(pn, "table") { rows := table_rows(d, parent); return index_of_handle(rows[:], H(row.handle)) }
	if is_table_section(pn) { rows := children_named(d, parent, false); return index_of_handle(rows[:], H(row.handle)) }
	return -1
}

// cell.cellIndex: its index in its row's cells, else -1.
HTMLTableCellElement_cellIndex :: proc(c: ^Call, cell: Api_Element) -> i32 {
	d := c.page.doc
	parent := cell.data.parent
	if !html_named(jd_node(d, parent), "tr") { return -1 }
	cells := children_named(d, parent, true)
	return index_of_handle(cells[:], H(cell.handle))
}

////////////////////////////////
// Child text content

// The concatenation of the data of the element's Text children.
@(private)
child_text_content :: proc(d: ^dom.Document, h: base.Handle) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch := dom.get(d, h).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if n := dom.get(d, ch); n.kind == .Text { strings.write_string(&b, n.text) }
	}
	return strings.to_string(b)
}

HTMLTitleElement_text :: proc(c: ^Call, element: Api_Element) -> string { return child_text_content(c.page.doc, H(element.handle)) }
HTMLTitleElement_set_text :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return dom_error(dom.set_text_content(c.page.doc, H(element.handle), value)) }
HTMLScriptElement_text :: proc(c: ^Call, element: Api_Element) -> string { return child_text_content(c.page.doc, H(element.handle)) }
HTMLScriptElement_set_text :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error { return dom_error(dom.set_text_content(c.page.doc, H(element.handle), value)) }

// input.list: the datalist its `list` attribute names (the element of that id in its tree), else null.
HTMLInputElement_list :: proc(c: ^Call, input: Api_Element) -> u64 {
	d := c.page.doc
	id, ok := attr_of(input.data, "list")
	if !ok || id == "" { return 0 }
	h := dom.find_by_id_in(d, dom.tree_root(d, H(input.handle)), id)
	return html_named(jd_node(d, h), "datalist") ? u64(h) : 0
}

////////////////////////////////
// <dialog>

// show(): open, not modal. showModal(): dialog_modal.odin.
HTMLDialogElement_show :: proc(c: ^Call, dialog: Api_Element) -> Api_Error {
	if _, open := attr_of(dialog.data, "open"); open { return .None }
	err := dom_error(dom.set_attribute(c.page.doc, H(dialog.handle), "open", ""))
	forms.changed(page_forms(c.page), H(dialog.handle))
	if err == .None && !dialog_opening_modal { dialog_shown(c.page, H(dialog.handle)) }
	return err
}

HTMLDialogElement_showModal :: proc(c: ^Call, dialog: Api_Element) -> Api_Error {
	if dialog_is_modal(c.page, H(dialog.handle)) { return .None }
	if _, open := attr_of(dialog.data, "open"); open { return fail(c, .Invalid_State, "The dialog is already open.") }
	if !dom.is_connected(c.page.doc, H(dialog.handle)) { return fail(c, .Invalid_State, "The dialog is not connected.") }
	if popover_showing(c.page, H(dialog.handle)) { return fail(c, .Invalid_State, "The dialog is a showing popover.") }
	dialog_opening_modal = true
	err := HTMLDialogElement_show(c, dialog)
	dialog_opening_modal = false
	if err != .None { return err }
	dialog_modal_shown(c.page, H(dialog.handle))
	return .None
}

// close(result): `open` removed, returnValue set, "close" fired (package forms).
HTMLDialogElement_close :: proc(c: ^Call, dialog: Api_Element, result: Maybe(string)) {
	r, has := result.?
	forms.close_dialog(page_forms(c.page), H(dialog.handle), r, has)
	forms_repaint(c.page)
}

// requestClose(result): a cancelable "cancel" first; closed unless a listener cancels it.
HTMLDialogElement_requestClose :: proc(c: ^Call, dialog: Api_Element, result: Maybe(string)) {
	if _, open := attr_of(dialog.data, "open"); !open { return }
	if !dispatch_event(c.page, H(dialog.handle), dom.Event{type = "cancel", cancelable = true}) { return }
	if dom.get(c.page.doc, H(dialog.handle)) == nil { return }
	HTMLDialogElement_close(c, dialog, result)
}
