package page

// What the browser's developer tools read of a page, and the few things they change in it, without going through
// JavaScript: the computed style of an element (as getComputedStyle serializes it), the rules that match it, the
// listeners on it, its markup; the edits of the Elements tab (a style rule's declarations, the style attribute, the
// markup, moving, cloning and removing a node) and of the Application tab (the storage areas of the page).
// They run on the interface thread while the page is not running (the panel's own rule: it copies what it shows).

import "core:fmt"
import "core:strings"
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
	return style.dev_matched_rules(p.engine, p.doc, effective_state(p), h, ua)
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

////////////////////////////////
// Console: the objects behind a message

// While the developer tools are open the pages' console calls describe their arguments (prelude/compat.js); 0: they do not.
// New realms are armed as they start (js_realm), the existing ones by dev_console_arm.
dev_console_max: int

// Turns the description of console arguments on (up to `max_bytes` per message) or off (0) in the page's realm, if it has one.
dev_console_arm :: proc(p: ^Page, max_bytes: int) {
	if p == nil || p.closed || p.js == nil || p.js.failed || p.worker != nil { return }
	src := fmt.tprintf("{{ const s = console[Symbol.for(\"wren.devtools\")]; if (s) {{ s.on = %v; s.max = %d; if (!s.on) s.refs.clear(); }} }}", max_bytes > 0, max(max_bytes, 1024))
	js_run(p, transmute([]byte)src, "devtools", 1)
}

// Asks the realm for the names an expression offers (they come back as a console line the shell recognizes).
dev_console_complete :: proc(p: ^Page, path: string) {
	if p == nil || p.closed || p.js == nil || p.js.failed || p.worker != nil { return }
	src := strings.concatenate({"{ const s = console[Symbol.for(\"wren.devtools\")]; if (s) s.complete(", js_quote(path), "); }"}, context.temp_allocator)
	js_run(p, transmute([]byte)src, "devtools", 1)
}
////////////////////////////////
// Forced element states

// What the developer tools force on one element: it matches :hover (and so do its ancestors, as with a real pointer), :active,
// :focus (and :focus-visible) or :visited whatever the pointer, the focus and the history say.
Forced_State :: struct {
	el:                            base.Handle,
	hover, active, focus, visited: bool,
}

// The state the styles are computed from: the shell's own (pointer, focus, fragment) with the forced states over it.
effective_state :: proc(p: ^Page) -> style.State {
	s := p.style_state
	f := p.forced
	if f.el == base.NIL_HANDLE || dom.get(p.doc, f.el) == nil { return s }
	if f.hover { s.hover = f.el }
	if f.active { s.active = f.el }
	if f.focus { s.focus, s.focus_visible = f.el, true }
	if f.visited { s.visited = f.el }
	return s
}

dev_forced :: proc(p: ^Page) -> Forced_State { return p == nil ? {} : p.forced }

// Forces (or stops forcing) the states of `el`; the element that had some loses them. Restyled by the next styles pass.
dev_force_state :: proc(p: ^Page, el: base.Handle, hover, active, focus, visited: bool) {
	if p == nil || p.closed { return }
	p.forced = {}
	if hover || active || focus || visited { p.forced = Forced_State{el = el, hover = hover, active = active, focus = focus, visited = visited} }
}

// The objects of console messages (kept by the realm under the id their description carries): stored under a global name
// (temp1, temp2...) and shown, or sent back as JSON text (a line the shell takes for the clipboard).
dev_console_store :: proc(p: ^Page, ref: int) { dev_console_call(p, fmt.tprintf("s.store(%d)", ref)) }
dev_console_copy :: proc(p: ^Page, ref: int) { dev_console_call(p, fmt.tprintf("s.copy(%d)", ref)) }

@(private)
dev_console_call :: proc(p: ^Page, call: string) {
	if p == nil || p.closed || p.js == nil || p.js.failed || p.worker != nil { return }
	src := strings.concatenate({"{ const s = console[Symbol.for(\"wren.devtools\")]; if (s) ", call, "; }"}, context.temp_allocator)
	js_run(p, transmute([]byte)src, "devtools", 1)
}

// A node of the document stored under a global name (temp1...): found again by its position among the children from the
// document. False when it is not in the document's own tree (a shadow tree, a detached node).
dev_store_node :: proc(p: ^Page, h: base.Handle) -> bool {
	if p == nil || p.closed || p.doc == nil { return false }
	path := make([dynamic]int, context.temp_allocator)
	for cur := h; cur != p.doc.root; {
		n := dom.get(p.doc, cur)
		if n == nil || n.parent == base.NIL_HANDLE { return false }
		i := 0
		for s := n.prev; s != base.NIL_HANDLE; { sn := dom.get(p.doc, s); if sn == nil { break }; i += 1; s = sn.prev }
		inject_at(&path, 0, i)
		cur = n.parent
	}
	b := strings.builder_make(context.temp_allocator)
	for v, i in path { fmt.sbprintf(&b, "%s%d", i > 0 ? "," : "", v) }
	dev_console_call(p, fmt.tprintf("s.storeNode([%s])", strings.to_string(b)))
	return true
}

// The nested documents of a page, outermost first (the contexts of the console's selector): their address and their page.
Dev_Frame :: struct { href: string, page: ^Page, depth: int }

dev_frames :: proc(p: ^Page) -> []Dev_Frame {
	out := make([dynamic]Dev_Frame, context.temp_allocator)
	dev_frames_walk(p, 1, &out)
	return out[:]
}

@(private)
dev_frames_walk :: proc(p: ^Page, depth: int, out: ^[dynamic]Dev_Frame) {
	if p == nil || p.closed || p.frames == nil || len(out) >= 64 || depth > 6 { return }
	for n in p.frames.children {
		if n == nil || n.page == nil || n.page.closed { continue }
		append(out, Dev_Frame{href = n.page.env.location.href, page = n.page, depth = depth})
		dev_frames_walk(n.page, depth + 1, out)
	}
}

// A script of the developer tools run in the page's realm (a request replayed as the page would make it).
dev_run_script :: proc(p: ^Page, source: string) -> bool {
	if p == nil || p.closed || p.js == nil || p.js.failed || p.worker != nil { return false }
	return js_run(p, transmute([]byte)source, "devtools", 1) == .Ok
}
