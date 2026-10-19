// Package dom: the document tree the page scripts manipulate.
//
// Ownership model (this is what keeps long-lived tabs from leaking):
//   * Every node is a slot in the document's generational Pool. Scripts only ever hold Handles; a handle to a
//     destroyed node resolves to nothing.
//   * A node attached to the tree is owned by the document.
//   * A node created by a script and not attached (or removed again) is owned by the script until it is attached or
//     `release`d. Releasing destroys the whole detached subtree.
//   * Closing the document (its Scope) destroys everything.
// Strings are UTF-8 and owned by the node (heap); nothing aliases script memory.
package dom

import "core:strings"
import "wb:base"

Node_Kind :: enum u8 { Document, Element, Text, Comment }

Attr :: struct {
	name:  string,
	value: string,
}

Listener_Id :: distinct u32

Listener :: struct {
	id:       Listener_Id,
	type:     string,
	callback: u32,    // function-table index in the owning instance
	user:     u32,    // opaque value handed back to the callback
	owner:    u32,    // which instance of the page registered it (a page can run several modules)
	capture:  bool,
	once:     bool,
	passive:  bool,
	removed:  bool,   // tombstone while a dispatch is walking the list
}

Node :: struct {
	kind:        Node_Kind,
	parent:      base.Handle,
	first_child: base.Handle,
	last_child:  base.Handle,
	prev:        base.Handle,
	next:        base.Handle,
	name:        string,   // element tag (lower case), empty otherwise
	text:        string,   // Text / Comment data
	attrs:       [dynamic]Attr,
	listeners:   [dynamic]Listener,
	generation_of_layout: u32,   // bumped on any change that needs re-layout (see `dirty`)
}

Document :: struct {
	nodes:      base.Pool(Node),
	root:       base.Handle,       // the Document node
	next_listener: Listener_Id,
	mutations:  u64,               // monotonic: renderers compare it to know when to re-layout
	journal:    Journal,           // what the mutations were, when some reader asked (journal.odin)
	scope:      ^base.Scope,
	cleanup:    base.Cleanup_Id,
	mode:       Document_Mode,     // set by the HTML parser from the doctype (HTML §13.2.6.4.1)
}

// The document's compatibility mode (DOM §4.5): what the rendering's quirks follow.
Document_Mode :: enum u8 { No_Quirks, Quirks, Limited_Quirks }

Error :: enum i32 {
	None              = 0,
	Invalid_Handle    = -1,
	Hierarchy         = -2,   // would create a cycle, or the parent cannot have children
	Not_Found         = -3,   // reference child is not a child of the parent
	Invalid_Argument  = -4,
	Attached          = -5,   // release of a node that is still in the tree
}

@(private)
heap_str :: proc(s: string) -> string { return strings.clone(s) }

document_create :: proc(scope: ^base.Scope = nil) -> ^Document {
	d := new(Document)
	d.scope = scope
	d.next_listener = 1
	h, n := base.pool_insert(&d.nodes, Node{kind = .Document})
	_ = n
	d.root = h
	if scope != nil { d.cleanup = base.on_close(scope, scope_closed, d) }
	return d
}

// Gives a document made without a scope (e.g. parsed on another thread: a document is plain heap memory, owned by
// whichever thread holds it) to `scope`, which frees it when it closes.
document_attach :: proc(d: ^Document, scope: ^base.Scope) {
	assert(d.scope == nil, "document already has a scope")
	d.scope = scope
	d.cleanup = base.on_close(scope, scope_closed, d)
}

document_destroy :: proc(d: ^Document) {
	if d.scope != nil { base.forget_cleanup(d.scope, d.cleanup) }
	free_document(d)
}

@(private)
scope_closed :: proc(data: rawptr) { free_document((^Document)(data)) }

@(private)
free_document :: proc(d: ^Document) {
	it: u32
	for _, n in base.pool_next(&d.nodes, &it) { free_node_data(n) }
	base.pool_destroy(&d.nodes)
	journal_free(d)
	free(d)
}

@(private)
free_node_data :: proc(n: ^Node) {
	delete(n.name)
	delete(n.text)
	for a in n.attrs { delete(a.name); delete(a.value) }
	delete(n.attrs)
	for l in n.listeners { delete(l.type) }
	delete(n.listeners)
}

get :: proc(d: ^Document, h: base.Handle) -> ^Node { return base.pool_get(&d.nodes, h) }

touch :: proc(d: ^Document) { d.mutations += 1 }

////////////////////////////////
// Creation

create_element :: proc(d: ^Document, tag: string) -> base.Handle {
	name := strings.to_lower(tag)
	h, _ := base.pool_insert(&d.nodes, Node{kind = .Element, name = name})
	return h
}

create_text :: proc(d: ^Document, text: string) -> base.Handle {
	h, _ := base.pool_insert(&d.nodes, Node{kind = .Text, text = heap_str(text)})
	return h
}

create_comment :: proc(d: ^Document, text: string) -> base.Handle {
	h, _ := base.pool_insert(&d.nodes, Node{kind = .Comment, text = heap_str(text)})
	return h
}

////////////////////////////////
// Tree

can_have_children :: proc(n: ^Node) -> bool { return n.kind == .Element || n.kind == .Document }

is_ancestor_or_self :: proc(d: ^Document, maybe_ancestor, node: base.Handle) -> bool {
	for cur := node; cur != base.NIL_HANDLE; {
		if cur == maybe_ancestor { return true }
		n := get(d, cur)
		if n == nil { return false }
		cur = n.parent
	}
	return false
}

detach :: proc(d: ^Document, h: base.Handle) {
	n := get(d, h)
	if n == nil || n.parent == base.NIL_HANDLE { return }
	p := get(d, n.parent)
	if n.prev != base.NIL_HANDLE { get(d, n.prev).next = n.next } else { p.first_child = n.next }
	if n.next != base.NIL_HANDLE { get(d, n.next).prev = n.prev } else { p.last_child = n.prev }
	old_parent := n.parent
	n.parent, n.prev, n.next = base.NIL_HANDLE, base.NIL_HANDLE, base.NIL_HANDLE
	touch(d)
	journal_record(d, .Remove, h, old_parent)
}

// Inserts `child` before `ref` (NIL_HANDLE = at the end), moving it if it is already in a tree.
insert_before :: proc(d: ^Document, parent, child, ref: base.Handle) -> Error {
	p, c := get(d, parent), get(d, child)
	if p == nil || c == nil { return .Invalid_Handle }
	if !can_have_children(p) || c.kind == .Document { return .Hierarchy }
	// a childless node can only be its own ancestor: skip the O(depth) walk (building deep trees stays linear)
	if child == parent || (c.first_child != base.NIL_HANDLE && is_ancestor_or_self(d, child, parent)) { return .Hierarchy }
	if ref != base.NIL_HANDLE {
		r := get(d, ref)
		if r == nil { return .Invalid_Handle }
		if r.parent != parent { return .Not_Found }
		if ref == child { return .None }   // already in place
	}
	detach(d, child)
	c = get(d, child)
	p = get(d, parent)
	c.parent = parent
	if ref == base.NIL_HANDLE {
		c.prev = p.last_child
		if p.last_child != base.NIL_HANDLE { get(d, p.last_child).next = child } else { p.first_child = child }
		p.last_child = child
	} else {
		r := get(d, ref)
		c.next = ref
		c.prev = r.prev
		if r.prev != base.NIL_HANDLE { get(d, r.prev).next = child } else { p.first_child = child }
		r.prev = child
	}
	touch(d)
	journal_record(d, .Insert, child, parent)
	return .None
}

append_child :: proc(d: ^Document, parent, child: base.Handle) -> Error {
	return insert_before(d, parent, child, base.NIL_HANDLE)
}

remove_child :: proc(d: ^Document, parent, child: base.Handle) -> Error {
	c := get(d, child)
	if get(d, parent) == nil || c == nil { return .Invalid_Handle }
	if c.parent != parent { return .Not_Found }
	detach(d, child)
	return .None
}

// Destroys a detached subtree. Every handle into it becomes invalid.
release :: proc(d: ^Document, h: base.Handle) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.parent != base.NIL_HANDLE || h == d.root { return .Attached }
	destroy_subtree(d, h)
	return .None
}

@(private)
destroy_subtree :: proc(d: ^Document, h: base.Handle) {
	// iterative: a hostile page can build a very deep tree and must not overflow the native stack
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, h)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := get(d, cur)
		if n == nil { continue }
		for c := n.first_child; c != base.NIL_HANDLE; {
			next := get(d, c).next
			append(&stack, c)
			c = next
		}
		free_node_data(n)
		base.pool_remove(&d.nodes, cur)
	}
}

////////////////////////////////
// Attributes and text

set_attribute :: proc(d: ^Document, h: base.Handle, name, value: string) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.kind != .Element || name == "" { return .Invalid_Argument }
	lname := strings.to_lower(name, context.temp_allocator)
	for &a in n.attrs {
		if a.name == lname {
			old := a.value
			a.value = heap_str(value)
			touch(d)
			journal_record(d, .Attribute, h, base.NIL_HANDLE, lname, old, true)
			delete(old)
			return .None
		}
	}
	append(&n.attrs, Attr{heap_str(lname), heap_str(value)})
	touch(d)
	journal_record(d, .Attribute, h, base.NIL_HANDLE, lname, "", false)
	return .None
}

get_attribute :: proc(d: ^Document, h: base.Handle, name: string) -> (value: string, ok: bool) {
	n := get(d, h)
	if n == nil || n.kind != .Element { return "", false }
	lname := strings.to_lower(name, context.temp_allocator)
	for a in n.attrs { if a.name == lname { return a.value, true } }
	return "", false
}

remove_attribute :: proc(d: ^Document, h: base.Handle, name: string) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	lname := strings.to_lower(name, context.temp_allocator)
	for a, i in n.attrs {
		if a.name == lname {
			old_name, old := a.name, a.value
			ordered_remove(&n.attrs, i)
			touch(d)
			journal_record(d, .Attribute, h, base.NIL_HANDLE, lname, old, true)
			delete(old_name); delete(old)
			return .None
		}
	}
	return .None
}

// Replaces all children by one text node (or none for ""), like Node.textContent = ...
set_text_content :: proc(d: ^Document, h: base.Handle, text: string) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	switch n.kind {
	case .Text, .Comment:
		delete(n.text)
		n.text = heap_str(text)
		touch(d)
		journal_record(d, .Text, h, n.parent)
	case .Element, .Document:
		for n.first_child != base.NIL_HANDLE {
			c := n.first_child
			detach(d, c)
			destroy_subtree(d, c)
			n = get(d, h)
		}
		if text != "" {
			t := create_text(d, text)
			append_child(d, h, t)
		}
		touch(d)
	}
	return .None
}

// Concatenated text of the subtree (iterative, document order).
text_content :: proc(d: ^Document, h: base.Handle, allocator := context.temp_allocator) -> string {
	n := get(d, h)
	if n == nil { return "" }
	if n.kind == .Text || n.kind == .Comment { return strings.clone(n.text, allocator) }
	sb := strings.builder_make(allocator)
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, h)
	for len(stack) > 0 {
		cur := pop(&stack)
		c := get(d, cur)
		if c == nil { continue }
		if c.kind == .Text { strings.write_string(&sb, c.text) }
		// push children in reverse so the first child is popped first
		for ch := c.last_child; ch != base.NIL_HANDLE; ch = get(d, ch).prev { append(&stack, ch) }
	}
	return strings.to_string(sb)
}

find_by_id :: proc(d: ^Document, id: string) -> base.Handle {
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, d.root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := get(d, cur)
		if n == nil { continue }
		if n.kind == .Element {
			if v, ok := get_attribute(d, cur, "id"); ok && v == id { return cur }
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = get(d, ch).prev { append(&stack, ch) }
	}
	return base.NIL_HANDLE
}

find_first_by_tag :: proc(d: ^Document, tag: string) -> base.Handle {
	ltag := strings.to_lower(tag, context.temp_allocator)
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, d.root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := get(d, cur)
		if n == nil { continue }
		if n.kind == .Element && n.name == ltag { return cur }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = get(d, ch).prev { append(&stack, ch) }
	}
	return base.NIL_HANDLE
}
