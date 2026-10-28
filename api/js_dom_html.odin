// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=34 partial
/// Members of HTML elements that are tree operations (src/page/js_dom_html.odin): the table model's API, the child
/// text content of <title> and <script>, the methods of <dialog>.
package api_js_dom_html

/// table.caption: its first caption child.
//@wb fn
HTMLTableElement_caption :: proc(table: Element) -> Element

/// table.caption = value: the first caption child removed, the value (if any) inserted first. Type for another element.
//@wb fn raises optional=value
HTMLTableElement_set_caption :: proc(table: Element, value: Element)

/// table.createCaption(): the first caption child, or a new one inserted first.
//@wb fn
HTMLTableElement_createCaption :: proc(table: Element) -> Element

/// table.deleteCaption()
//@wb fn
HTMLTableElement_deleteCaption :: proc(table: Element)

/// table.tHead: its first thead child.
//@wb fn
HTMLTableElement_tHead :: proc(table: Element) -> Element

/// table.tHead = value: Hierarchy for an element that is not a thead.
//@wb fn raises optional=value
HTMLTableElement_set_tHead :: proc(table: Element, value: Element)

/// table.createTHead(): inserted before the first child that is neither a caption nor a colgroup.
//@wb fn
HTMLTableElement_createTHead :: proc(table: Element) -> Element

/// table.deleteTHead()
//@wb fn
HTMLTableElement_deleteTHead :: proc(table: Element)

/// table.tFoot: its first tfoot child.
//@wb fn
HTMLTableElement_tFoot :: proc(table: Element) -> Element

/// table.tFoot = value: Hierarchy for an element that is not a tfoot.
//@wb fn raises optional=value
HTMLTableElement_set_tFoot :: proc(table: Element, value: Element)

/// table.createTFoot(): appended.
//@wb fn
HTMLTableElement_createTFoot :: proc(table: Element) -> Element

/// table.deleteTFoot()
//@wb fn
HTMLTableElement_deleteTFoot :: proc(table: Element)

/// table.createTBody(): after the last tbody child.
//@wb fn
HTMLTableElement_createTBody :: proc(table: Element) -> Element

/// table.insertRow(index): Index_Size outside -1 ..= rows.length.
//@wb fn raises
HTMLTableElement_insertRow :: proc(table: Element, index: i32) -> Element

/// table.deleteRow(index): Index_Size outside -1 ..< rows.length.
//@wb fn raises
HTMLTableElement_deleteRow :: proc(table: Element, index: i32)

/// section.insertRow(index)
//@wb fn raises
HTMLTableSectionElement_insertRow :: proc(section: Element, index: i32) -> Element

/// section.deleteRow(index)
//@wb fn raises
HTMLTableSectionElement_deleteRow :: proc(section: Element, index: i32)

/// row.insertCell(index): a new td.
//@wb fn raises
HTMLTableRowElement_insertCell :: proc(row: Element, index: i32) -> Element

/// row.deleteCell(index)
//@wb fn raises
HTMLTableRowElement_deleteCell :: proc(row: Element, index: i32)

/// row.rowIndex (-1 outside a table)
//@wb fn
HTMLTableRowElement_rowIndex :: proc(row: Element) -> i32

/// row.sectionRowIndex
//@wb fn
HTMLTableRowElement_sectionRowIndex :: proc(row: Element) -> i32

/// cell.cellIndex
//@wb fn
HTMLTableCellElement_cellIndex :: proc(cell: Element) -> i32

/// title.text: its child text content.
//@wb fn
HTMLTitleElement_text :: proc(element: Element) -> string

/// title.text = value
//@wb fn raises
HTMLTitleElement_set_text :: proc(element: Element, value: string)

/// script.text: its child text content.
//@wb fn
HTMLScriptElement_text :: proc(element: Element) -> string

/// script.text = value
//@wb fn raises
HTMLScriptElement_set_text :: proc(element: Element, value: string)

/// input.list: the datalist of the id its `list` attribute gives.
//@wb fn
HTMLInputElement_list :: proc(input: Element) -> Element

/// dialog.show()
//@wb fn raises
HTMLDialogElement_show :: proc(dialog: Element)

/// dialog.showModal(): Invalid_State when it is not connected (no top layer: the dialog stays where it is).
//@wb fn raises
HTMLDialogElement_showModal :: proc(dialog: Element)

/// dialog.close(result)
//@wb fn optional=result
HTMLDialogElement_close :: proc(dialog: Element, result: string)

/// dialog.requestClose(result): "cancel" fired first.
//@wb fn optional=result
HTMLDialogElement_requestClose :: proc(dialog: Element, result: string)

