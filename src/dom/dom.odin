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

// Doctype: `name` is the doctype's name, its public and system identifiers are the attributes "publicId" and
// "systemId" (absent = empty). Fragment: a DocumentFragment (never in the document's tree; inserting it moves its
// children).
Node_Kind :: enum u8 { Document, Element, Text, Comment, Doctype, Fragment }

// The namespace of an element (DOM §4.9). The HTML parser gives SVG and MathML elements theirs; createElementNS may
// give any: an Other namespace's URI (and any element's prefix) is kept in Document.ns_extra.
Namespace :: enum u8 { HTML, SVG, MathML, None, Other }

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
	ns:          Namespace,  // elements
	held:        bool,       // a detached tree its owner keeps (a template's contents): not freed when nothing pins it
	as_document: bool,       // a Fragment that stands for a document of its own (DOMImplementation.createHTMLDocument)
	is_shadow:   bool,       // a Fragment that is a shadow root (shadow.odin)
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
	pins:        u32,      // JavaScript wrappers referring to this node (pins.odin)
	pins_below:  u32,      // pins of this node and its whole subtree: a detached tree with none can be freed
	// shadow trees (shadow.odin): `shadow` is an element's shadow root, or a shadow root's host; `slot` the slot a
	// slottable (a host's child) is assigned to, at position `slot_pos` of that slot's assigned nodes (the fields sit
	// where they add the least to the node's size)
	slot_pos:    u32,
	shadow:      base.Handle,
	slot:        base.Handle,
}

Document :: struct {
	nodes:      base.Pool(Node),
	root:       base.Handle,       // the Document node
	next_listener: Listener_Id,
	listener_changes: u64,         // bumped when a listener is added or removed (what a click acts on: accessibility)
	mutations:  u64,               // monotonic: renderers compare it to know when to re-layout
	journal:    Journal,           // what the mutations were, when some reader asked (journal.odin)
	scope:      ^base.Scope,
	cleanup:    base.Cleanup_Id,
	mode:       Document_Mode,     // set by the HTML parser from the doctype (HTML §13.2.6.4.1)
	hooks:      Hooks,             // what the embedder does on insertions and attribute changes (hooks.odin)
	parser_inserting: int,         // > 0 while an HTML parser builds nodes into this document (fragments: innerHTML...)
	// finer change counters than `mutations`, for caches that depend on part of the document only (live collections):
	// tree_version moves on every insertion or removal of a node, attr_version on every attribute change
	tree_version: u64,
	attr_version: u64,
	ids:        Id_Index,          // elements by id, built on first use (ids.odin)
	ns_extra:   map[base.Handle]Ns_Extra,   // namespace URI of Other elements, prefixes (createElementNS)
	templates:  map[base.Handle]base.Handle,   // <template> element -> its contents (a Fragment), made on first need
	// called for each mutation as it happens (journal.odin): MutationObserver. Entries of one DOM operation (replace
	// all children, insert a fragment...) carry the same `batch`.
	observer:      Mutation_Hook,
	observer_user: rawptr,
	batch:         u32,
	next_batch:    u32,
	// shadow trees (shadow.odin): every shadow root with what attachShadow gave it, the assigned nodes of each slot
	// that has some, manual slot assignments (slottable -> slot), and who to tell when a slot's assignment changes
	shadow_roots:  map[base.Handle]Shadow_Info,
	assigned:      map[base.Handle][dynamic]base.Handle,
	manual_slot:   map[base.Handle]base.Handle,
	manual_nodes:  map[base.Handle][dynamic]base.Handle,   // slot -> its manually assigned nodes (HTMLSlotElement.assign)
	slot_changed:  proc(user: rawptr, d: ^Document, slot: base.Handle),
	slot_user:     rawptr,
	custom_states: map[base.Handle][dynamic]string,   // ElementInternals.states (shadow.odin)
	ce_custom:     map[base.Handle]bool,              // custom elements whose definition ran (:defined)
}

Ns_Extra :: struct {
	uri:    string,   // owned; Other only
	prefix: string,   // owned; "" = none
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
	Not_Supported     = -6,   // attachShadow on an element that cannot be a host, or is one already
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

// `next` (made without a scope) takes the place of `old` in its scope; `old` keeps no scope (free it with document_destroy
// once nothing uses it). `next` is released when
// `old` would have been: before what the scope held before the old document, after what came since and may point
// into the document (attaching it afterwards freed it first, and the page's DOM state for scripts wrote into it).
document_take_place :: proc(old, next: ^Document) {
	assert(next.scope == nil, "document already has a scope")
	assert(old.scope != nil, "the document it replaces has no scope: use document_attach")
	if old.scope != nil && base.rebind_cleanup(old.scope, old.cleanup, scope_closed, next) {
		next.scope, next.cleanup = old.scope, old.cleanup
		old.scope = nil
	} else if old.scope != nil {
		document_attach(next, old.scope)
		base.forget_cleanup(old.scope, old.cleanup)
		old.scope = nil
	}
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
	hooks_free(d)
	ids_destroy(d)
	for _, x in d.ns_extra { delete(x.uri); delete(x.prefix) }
	delete(d.ns_extra)
	delete(d.templates)
	shadow_free_all(d)
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

// An element of namespace `ns`. Names are kept lower case whatever the namespace (as the parser does): the style
// engine and the selectors compare lower-case names; the bindings give SVG names their case back.
create_element_ns :: proc(d: ^Document, tag: string, ns: Namespace, uri := "", prefix := "") -> base.Handle {
	h := create_element(d, tag)
	n := get(d, h)
	n.ns = ns
	if (ns == .Other && uri != "") || prefix != "" {
		d.ns_extra[h] = Ns_Extra{uri = ns == .Other ? heap_str(uri) : "", prefix = heap_str(prefix)}
	}
	return h
}

create_doctype :: proc(d: ^Document, name, public_id, system_id: string) -> base.Handle {
	h, n := base.pool_insert(&d.nodes, Node{kind = .Doctype, name = heap_str(name)})
	if public_id != "" { append(&n.attrs, Attr{heap_str("publicId"), heap_str(public_id)}) }
	if system_id != "" { append(&n.attrs, Attr{heap_str("systemId"), heap_str(system_id)}) }
	return h
}

create_fragment :: proc(d: ^Document) -> base.Handle {
	h, _ := base.pool_insert(&d.nodes, Node{kind = .Fragment})
	return h
}

// The contents of a <template> element (HTML §4.12.3): a DocumentFragment, made empty on first need.
template_content :: proc(d: ^Document, template: base.Handle) -> base.Handle {
	if c, ok := d.templates[template]; ok && get(d, c) != nil { return c }
	c := create_fragment(d)
	get(d, c).held = true
	d.templates[template] = c
	return c
}

////////////////////////////////
// Tree

can_have_children :: proc(n: ^Node) -> bool { return n.kind == .Element || n.kind == .Document || n.kind == .Fragment }

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
	if n.pins_below > 0 { pins_adjust(d, n.parent, -i64(n.pins_below)) }
	p := get(d, n.parent)
	if n.prev != base.NIL_HANDLE { get(d, n.prev).next = n.next } else { p.first_child = n.next }
	if n.next != base.NIL_HANDLE { get(d, n.next).prev = n.prev } else { p.last_child = n.prev }
	old_parent, old_prev, old_next := n.parent, n.prev, n.next
	watch: u64   // what leaves the document with it (a node kept in a detached tree is not looked at: the style engine does not see it)
	if d.journal.on && d.journal.watch.on && n.kind == .Element && is_connected(d, old_parent) { watch = subtree_watch(d, h) }
	n.parent, n.prev, n.next = base.NIL_HANDLE, base.NIL_HANDLE, base.NIL_HANDLE
	touch(d)
	d.tree_version += 1
	journal_record(d, .Remove, h, old_parent, prev = old_prev, next = old_next, watch = watch)
	if len(d.shadow_roots) > 0 { shadow_removed(d, h, old_parent) }
	if d.hooks.removed != nil { d.hooks.removed(d.hooks.user, d) }
}

// Inserts `child` before `ref` (NIL_HANDLE = at the end), moving it if it is already in a tree.
insert_before :: proc(d: ^Document, parent, child, ref: base.Handle) -> Error {
	p, c := get(d, parent), get(d, child)
	if p == nil || c == nil { return .Invalid_Handle }
	if !can_have_children(p) || c.kind == .Document || c.kind == .Fragment { return .Hierarchy }
	// a childless node can only be its own ancestor: skip the O(depth) walk (building deep trees stays linear)
	if child == parent || (c.first_child != base.NIL_HANDLE && is_ancestor_or_self(d, child, parent)) { return .Hierarchy }
	// a host may not go into its own shadow tree (DOM "host-including inclusive ancestor")
	if len(d.shadow_roots) > 0 && (c.first_child != base.NIL_HANDLE || c.shadow != base.NIL_HANDLE) && host_including_ancestor(d, child, parent) { return .Hierarchy }
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
	if c.pins_below > 0 { pins_adjust(d, parent, i64(c.pins_below)) }
	touch(d)
	d.tree_version += 1
	journal_record(d, .Insert, child, parent, prev = c.prev, next = c.next)
	if len(d.shadow_roots) > 0 { shadow_inserted(d, child, parent) }
	notify_inserted(d, child)   // last: it may run scripts (hooks.odin)
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
	if n.parent != base.NIL_HANDLE || h == d.root || n.is_shadow { return .Attached }
	destroy_unpinned(d, h)
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
		if n.kind == .Element {
			ids_forget_node(d, cur, n)
			if x, had := d.ns_extra[cur]; had { delete(x.uri); delete(x.prefix); delete_key(&d.ns_extra, cur) }
			// a template's contents go with it, unless a script holds some of them (they are then a tree of their own)
			if content, had := d.templates[cur]; had {
				delete_key(&d.templates, cur)
				if c := get(d, content); c != nil {
					c.held = false
					if c.pins_below == 0 { append(&stack, content) }
				}
			}
			// its shadow tree goes with it (its pins count in the host's: nothing in it is pinned)
			if n.shadow != base.NIL_HANDLE { append(&stack, n.shadow); n.shadow = base.NIL_HANDLE }
		}
		if len(d.shadow_roots) > 0 || len(d.assigned) > 0 || len(d.manual_slot) > 0 || len(d.custom_states) > 0 || len(d.ce_custom) > 0 { shadow_forget_node(d, cur, n) }
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
	lname := name
	for i in 0 ..< len(name) {
		if name[i] >= 'A' && name[i] <= 'Z' { lname = strings.to_lower(name, context.temp_allocator); break }
	}
	for &a in n.attrs {
		if a.name == lname {
			old := a.value
			a.value = heap_str(value)
			touch(d)
			d.attr_version += 1
			if lname == "id" { ids_changed(d, h, old, true, value, true) }
			journal_record(d, .Attribute, h, base.NIL_HANDLE, lname, old, true)
			delete(old)
			if len(d.shadow_roots) > 0 { shadow_attribute(d, h, lname) }
			notify_attribute(d, h, lname)
			return .None
		}
	}
	append(&n.attrs, Attr{heap_str(lname), heap_str(value)})
	touch(d)
	d.attr_version += 1
	if lname == "id" { ids_changed(d, h, "", false, value, true) }
	journal_record(d, .Attribute, h, base.NIL_HANDLE, lname, "", false)
	if len(d.shadow_roots) > 0 { shadow_attribute(d, h, lname) }
	notify_attribute(d, h, lname)
	return .None
}

// `name` in lower case: itself when it has no upper-case ASCII letter (the common case: no allocation), else a copy
// in the temp allocator.
lower_name :: proc(name: string) -> string {
	for i in 0 ..< len(name) {
		if name[i] >= 'A' && name[i] <= 'Z' { return strings.to_lower(name, context.temp_allocator) }
	}
	return name
}

get_attribute :: proc(d: ^Document, h: base.Handle, name: string) -> (value: string, ok: bool) {
	n := get(d, h)
	if n == nil || n.kind != .Element { return "", false }
	// names are stored in lower case: compare folding the query's ASCII letters, without allocating (a hot path of
	// scripts: getAttribute, reflected IDL attributes)
	outer: for a in n.attrs {
		if len(a.name) != len(name) { continue }
		for i in 0 ..< len(name) {
			c := name[i]
			if c >= 'A' && c <= 'Z' { c += 32 }
			if c != a.name[i] { continue outer }
		}
		return a.value, true
	}
	return "", false
}

remove_attribute :: proc(d: ^Document, h: base.Handle, name: string) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.kind != .Element { return .None }
	lname := name
	for i in 0 ..< len(name) {
		if name[i] >= 'A' && name[i] <= 'Z' { lname = strings.to_lower(name, context.temp_allocator); break }
	}
	for a, i in n.attrs {
		if a.name == lname {
			old_name, old := a.name, a.value
			ordered_remove(&n.attrs, i)
			touch(d)
			d.attr_version += 1
			if lname == "id" { ids_changed(d, h, old, true, "", false) }
			journal_record(d, .Attribute, h, base.NIL_HANDLE, lname, old, true)
			delete(old_name); delete(old)
			if len(d.shadow_roots) > 0 { shadow_attribute(d, h, lname) }
			notify_attribute(d, h, lname)
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
		set_data(d, h, text)
	case .Element, .Document, .Fragment:
		batch := batch_begin(d)
		defer batch_end(d, batch)
		for n.first_child != base.NIL_HANDLE {
			c := n.first_child
			detach(d, c)
			destroy_unpinned(d, c)
			n = get(d, h)
		}
		if text != "" {
			t := create_text(d, text)
			append_child(d, h, t)
		}
		touch(d)
	case .Doctype:
	}
	return .None
}

// Replaces the data of a Text or Comment node (CharacterData "replace data" with the whole range): the journal keeps
// the old data for MutationObserver's characterDataOldValue.
set_data :: proc(d: ^Document, h: base.Handle, data: string) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.kind != .Text && n.kind != .Comment { return .Invalid_Argument }
	old := n.text
	n.text = heap_str(data)
	touch(d)
	journal_record(d, .Text, h, n.parent, old = old, had_old = true)
	delete(old)
	return .None
}

// Starts a group of mutations that are one DOM operation (their journal entries carry the same batch). Nested calls
// join the outer group. Returns what batch_end needs.
batch_begin :: proc(d: ^Document) -> u32 {
	if d.batch != 0 { return 0 }
	d.next_batch += 1
	if d.next_batch == 0 { d.next_batch = 1 }
	d.batch = d.next_batch
	return d.batch
}

batch_end :: proc(d: ^Document, token: u32) {
	if token != 0 && d.batch == token { d.batch = 0 }
}

// Concatenated text of the subtree (iterative, document order).
text_content :: proc(d: ^Document, h: base.Handle, allocator := context.temp_allocator) -> string {
	n := get(d, h)
	if n == nil || n.kind == .Doctype { return "" }
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

// The first element of the document's tree (in tree order) whose id is `id` (the id index, ids.odin).
find_by_id :: proc(d: ^Document, id: string) -> base.Handle { return ids_lookup(d, id) }

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
