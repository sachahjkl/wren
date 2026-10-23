package page

// What the browser's developer tools read of a page, and the few things they change in it, without going through
// JavaScript: the computed style of an element (as getComputedStyle serializes it), the rules that match it, the
// listeners on it, its markup; the edits of the Elements tab (a style rule's declarations, the style attribute, the
// markup, moving, cloning and removing a node) and of the Application tab (the storage areas of the page).
// They run on the interface thread while the page is not running (the panel's own rule: it copies what it shows).

import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

@(private = "file")
computed_names := COMPUTED_PROPERTIES

// The properties getComputedStyle lists, in alphabetical order.
computed_property_names :: proc() -> []string { return computed_names[:] }

// The resolved value of property `name` of element `h` ("" when the element has no style or the property is not known).
// The strings live in the temporary allocator.
computed_property :: proc(p: ^Page, h: base.Handle, name: string) -> string {
	if p == nil || p.closed { return "" }
	st := js_dom_styled(p)
	if st == nil { return "" }
	cs := style.style_of(st, h)
	if cs == nil { return "" }
	return computed_value(cs, name, used_box(p, h))
}

////////////////////////////////
// Styles

// The style rules that match `h`, strongest first (`ua`: the browser's own included). Memory of the temporary allocator.
dev_matched_rules :: proc(p: ^Page, h: base.Handle, ua := false) -> []style.Dev_Rule {
	if p == nil || p.closed || p.engine == nil { return nil }
	return style.dev_matched_rules(p.engine, p.doc, p.style_state, h, ua)
}

// A rule's declarations replaced (an edit, a property switched off): the page restyles at its next frame.
dev_set_rule_decls :: proc(p: ^Page, sheet: ^style.Sheet, rule: ^css.Rule, decls: []style.Dev_Decl) {
	if p == nil || p.closed || p.engine == nil { return }
	style.dev_set_rule_decls(p.engine, sheet, rule, decls)
	p.style_stale = true
}

// The declarations of the style attribute of `h`.
dev_inline_decls :: proc(p: ^Page, h: base.Handle) -> []style.Dev_Decl {
	if p == nil || p.closed || p.engine == nil { return nil }
	text, ok := dom.get_attribute(p.doc, h, "style")
	if !ok { return nil }
	return style.dev_parse_inline(p.engine, text)
}

// The style attribute of `h` set to `text` (empty: removed).
dev_set_style_attribute :: proc(p: ^Page, h: base.Handle, text: string) {
	if p == nil || p.closed { return }
	if text == "" { dom.remove_attribute(p.doc, h, "style") } else { dom.set_attribute(p.doc, h, "style", text) }
}

////////////////////////////////
// Listeners

Dev_Listener :: struct {
	type:    string,
	capture, once, passive: bool,
	callback: u32,
	on_node: base.Handle,
}

// The listeners of the page's scripts on `h` (memory of the temporary allocator).
dev_listeners :: proc(p: ^Page, h: base.Handle) -> []Dev_Listener {
	if p == nil || p.closed { return nil }
	n := dom.get(p.doc, h)
	if n == nil { return nil }
	out := make([dynamic]Dev_Listener, 0, len(n.listeners), context.temp_allocator)
	for l in n.listeners {
		if l.removed { continue }
		append(&out, Dev_Listener{type = l.type, capture = l.capture, once = l.once, passive = l.passive, callback = l.callback, on_node = h})
	}
	return out[:]
}

////////////////////////////////
// Markup and tree edits

dev_outer_html :: proc(p: ^Page, h: base.Handle) -> string {
	if p == nil || p.closed { return "" }
	return serialize_html(p.doc, h, true)
}

dev_inner_html :: proc(p: ^Page, h: base.Handle) -> string {
	if p == nil || p.closed { return "" }
	return serialize_html(p.doc, h, false)
}

// The element `h` replaced by the nodes of `markup`; "" when it worked, else why not.
dev_set_outer_html :: proc(p: ^Page, h: base.Handle, markup: string) -> string {
	if p == nil || p.closed { return "the page is gone" }
	n := dom.get(p.doc, h)
	if n == nil || n.parent == base.NIL_HANDLE { return "this node has no parent" }
	c := Call{page = p}
	pn := dom.get(p.doc, n.parent)
	if pn.kind == .Document { return "the document element cannot be replaced" }
	ctx := n.parent
	if pn.kind == .Fragment { ctx = base.NIL_HANDLE }
	frag, err := parse_fragment_for(&c, ctx, markup)
	if err != .None { return "the markup could not be parsed" }
	err = replace_child(&c, n.parent, frag, h)
	dom.destroy_unpinned(p.doc, frag)
	return err == .None ? "" : "the node cannot be replaced there"
}

// The text of a text node or comment set.
dev_set_text :: proc(p: ^Page, h: base.Handle, text: string) {
	if p == nil || p.closed { return }
	dom.set_text_content(p.doc, h, text)
}

dev_set_attribute :: proc(p: ^Page, h: base.Handle, name, value: string) -> bool {
	if p == nil || p.closed { return false }
	return dom.set_attribute(p.doc, h, name, value) == .None
}

dev_remove_attribute :: proc(p: ^Page, h: base.Handle, name: string) {
	if p == nil || p.closed { return }
	dom.remove_attribute(p.doc, h, name)
}

// The node taken out of the tree.
dev_remove_node :: proc(p: ^Page, h: base.Handle) -> bool {
	if p == nil || p.closed { return false }
	n := dom.get(p.doc, h)
	if n == nil || n.parent == base.NIL_HANDLE { return false }
	dom.detach(p.doc, h)
	dom.destroy_unpinned(p.doc, h)
	return true
}

// A deep copy of the node right after it; its handle (NIL when it could not).
dev_duplicate_node :: proc(p: ^Page, h: base.Handle) -> base.Handle {
	if p == nil || p.closed { return base.NIL_HANDLE }
	n := dom.get(p.doc, h)
	if n == nil || n.parent == base.NIL_HANDLE || n.kind == .Document { return base.NIL_HANDLE }
	copy := dom.clone_node(p.doc, h, true)
	if copy == base.NIL_HANDLE { return base.NIL_HANDLE }
	insert_node(p.doc, n.parent, copy, n.next)
	return copy
}

// `h` moved under `parent`, before `before` (NIL: last): a drag and drop in the tree.
dev_move_node :: proc(p: ^Page, h, parent, before: base.Handle) -> string {
	if p == nil || p.closed { return "the page is gone" }
	c := Call{page = p}
	if before == h { return "" }
	err := pre_insert(&c, parent, h, before)
	return err == .None ? "" : "the node cannot go there"
}

////////////////////////////////
// Storage

Dev_Storage_Item :: struct { key, value: string }

// The items of localStorage or sessionStorage (memory of the temporary allocator); ok false when the page may not use it.
dev_storage_items :: proc(p: ^Page, session: bool) -> (items: []Dev_Storage_Item, ok: bool) {
	if p == nil || p.closed { return nil, false }
	a, err := storage_area_of(p, session ? .Session : .Local)
	if a == nil || err != 0 { return nil, false }
	out := make([]Dev_Storage_Item, len(a.items), context.temp_allocator)
	for it, i in a.items { out[i] = {it.key, it.value} }
	return out, true
}

dev_storage_set :: proc(p: ^Page, session: bool, key, value: string) -> bool { return storage_set_item(p, session ? .Session : .Local, key, value) == 0 }
dev_storage_remove :: proc(p: ^Page, session: bool, key: string) { _ = storage_remove_item(p, session ? .Session : .Local, key) }
dev_storage_clear :: proc(p: ^Page, session: bool) { _ = storage_clear(p, session ? .Session : .Local) }
