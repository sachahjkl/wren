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

// Node types of XML on the kinds above: a CDATASection is a Text (its data is text everywhere), a
// ProcessingInstruction a Comment whose `name` is its target (never rendered), an Element made for an XML document
// (its names and its attributes' names keep their case, tagName is not upper-cased), an XML document a Fragment with
// as_document (the page's own Document node when the page was XML), by its content type (application/xml, text/xml,
// application/xhtml+xml, image/svg+xml); the Created_* ones are those of DOMImplementation.createDocument (an
// XMLDocument object, whose content type follows its element's namespace).
Xml_Kind :: enum u8 { None, CDATA, Processing_Instruction, Element, Document, Document_Text_XML, Document_XHTML, Document_SVG, Created, Created_XHTML, Created_SVG }

// A document node (the page's, or a Fragment that stands for one) that is an XML document.
is_xml_document :: proc(n: ^Node) -> bool { return n != nil && (n.kind == .Fragment || n.kind == .Document) && n.xml >= .Document }

// An element made for an XML document: names as given (DOM: no ASCII lower-casing of HTML documents).
is_xml_element :: #force_inline proc(n: ^Node) -> bool { return n != nil && n.kind == .Element && n.xml == .Element }

// An attribute: `name` its qualified name (prefix:local when it has a namespace and a prefix), `ns` its namespace
// (attr_ns.odin). What the browser itself reads of an attribute (style, src, on*, id, slot...) is the one of no
// namespace: get_attribute.
Attr :: struct {
	name:  string,
	value: string,
	ns:    Attr_Ns,
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
	blank_url:   bool,       // such a document whose URL is about:blank (createHTMLDocument's, createDocument's, parseHTMLUnsafe's, the templates'; DOMParser's has its creator's)
	is_shadow:   bool,       // a Fragment that is a shadow root (shadow.odin)
	xml:         Xml_Kind,   // what XML adds to a kind (DOMParser's XML documents)
	name_static: bool,       // `name` is the program's own string, never freed (names.odin)
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
	// DOM "node document": the document of its own (an as_document Fragment) it was made for or inserted under, NIL for
	// the page's; what a detached tree's ownerDocument is (set_node_document)
	doc:         base.Handle,
}

Document :: struct {
	nodes:      base.Pool(Node),
	tag:        u32,               // in every handle of this document (base.pool_insert_tagged): names it to scripts of others
	root:       base.Handle,       // the Document node
	next_listener: Listener_Id,
	listener_changes: u64,         // bumped when a listener is added or removed (what a click acts on: accessibility)
	mutations:  u64,               // monotonic: renderers compare it to know when to re-layout
	journal:    Journal,           // what the mutations were, when some reader asked (journal.odin)
	implicit_anchors: map[base.Handle]base.Handle,   // showing popover -> its invoker: its implicit anchor (CSS Anchor Positioning; page/popover.odin)
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
	attr_namespaces: [dynamic]string,       // the namespace URIs of attributes past the fixed ones, each once (attr_ns.odin)
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
	// elements that were given an `elementtiming` attribute (Element Timing: the only ones its scan visits). Stale entries
	// (a node freed, the attribute removed) are dropped by the reader, and here when the list would grow.
	timed:         [dynamic]base.Handle,
	// the <meta> elements made in this document (the page's color scheme is looked for among them, not in every node:
	// style/color_scheme.odin). Stale entries (a node freed) are dropped by the reader, and here when the list would grow.
	metas:         [dynamic]base.Handle,
	// the <img> and <input> elements made in this document (page/images.odin looks for image elements among them, not
	// in the subtrees inserted). Stale entries as in `metas`.
	images:        [dynamic]base.Handle,
}

// The element name of `Document.metas`.
META_NAME :: "meta"
// The element names of `Document.images` (an <input> is an image element when its type says so: the reader checks).
IMG_NAME :: "img"
INPUT_NAME :: "input"

// Lists a new element in the document's list of the elements of its name, if it keeps one.
@(private)
named_add :: proc(d: ^Document, h: base.Handle, name: string) {
	switch name {
	case META_NAME: named_append(d, &d.metas, h, META_NAME, META_NAME)
	case IMG_NAME, INPUT_NAME: named_append(d, &d.images, h, IMG_NAME, INPUT_NAME)
	}
}

// Appends `h` to `list`; a full list first drops its entries that are no longer an element of either name (freed).
@(private = "file")
named_append :: proc(d: ^Document, list: ^[dynamic]base.Handle, h: base.Handle, a, b: string) {
	if len(list) == cap(list) {
		kept := 0
		for m in list {
			if n := get(d, m); n != nil && (n.name == a || n.name == b) { list[kept] = m; kept += 1 }
		}
		resize(list, kept)
	}
	append(list, h)
}

// The attribute Element Timing looks for (page/timeline_lcp.odin).
TIMED_ATTRIBUTE :: "elementtiming"

// Lists `h` among the elements with an `elementtiming` attribute.
@(private)
timed_add :: proc(d: ^Document, h: base.Handle) {
	if len(d.timed) == cap(d.timed) {
		kept := 0
		for t in d.timed {
			if _, has := get_attribute(d, t, TIMED_ATTRIBUTE); has { d.timed[kept] = t; kept += 1 }
		}
		resize(&d.timed, kept)
	}
	append(&d.timed, h)
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

document_create :: proc(scope: ^base.Scope = nil, tag: u32 = 0) -> ^Document {
	d := new(Document)
	d.tag = tag != 0 ? tag : base.tag_new()
	d.scope = scope
	d.next_listener = 1
	h, n := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Document})
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
	delete(d.implicit_anchors)
	hooks_free(d)
	ids_destroy(d)
	for _, x in d.ns_extra { delete(x.uri); delete(x.prefix) }
	delete(d.ns_extra)
	for uri in d.attr_namespaces { delete(uri) }
	delete(d.attr_namespaces)
	delete(d.templates)
	delete(d.timed)
	delete(d.metas)
	delete(d.images)
	shadow_free_all(d)
	free(d)
}

@(private)
free_node_data :: proc(n: ^Node) {
	if !n.name_static { delete(n.name) }
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

// The name in ASCII lower case (DOM createElement, the HTML parser: other letters keep their case): one of
// STATIC_NAMES is the program's string, any other a copy.
create_element :: proc(d: ^Document, tag: string) -> base.Handle {
	lower :: proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c }
	if len(tag) <= NAME_STATIC_MAX {
		buf: [NAME_STATIC_MAX]u8
		for i in 0 ..< len(tag) { buf[i] = lower(tag[i]) }
		if s := static_name(string(buf[:len(tag)])); s != "" {
			h, _ := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Element, name = s, name_static = true})
			named_add(d, h, s)
			return h
		}
	}
	name := make([]u8, len(tag))
	for i in 0 ..< len(tag) { name[i] = lower(tag[i]) }
	h, _ := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Element, name = string(name)})
	return h
}

create_text :: proc(d: ^Document, text: string) -> base.Handle {
	h, _ := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Text, text = heap_str(text)})
	return h
}

create_comment :: proc(d: ^Document, text: string) -> base.Handle {
	h, _ := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Comment, text = heap_str(text)})
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
	h, n := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Doctype, name = heap_str(name)})
	if public_id != "" { append(&n.attrs, Attr{name = heap_str("publicId"), value = heap_str(public_id)}) }
	if system_id != "" { append(&n.attrs, Attr{name = heap_str("systemId"), value = heap_str(system_id)}) }
	return h
}

create_fragment :: proc(d: ^Document) -> base.Handle {
	h, _ := base.pool_insert_tagged(&d.nodes, d.tag, Node{kind = .Fragment})
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
	if d.hooks.removed != nil { d.hooks.removed(d.hooks.user, d, h, old_parent) }
}

// DOM "adopt": `h` and its shadow-including descendants get `doc` as node document (a document of its own, NIL: the
// page's).
set_node_document :: proc(d: ^Document, h, doc: base.Handle) {
	shadows := make([dynamic]base.Handle, context.temp_allocator)   // shadow trees still to walk (rare: nothing allocated without)
	for top := h; top != base.NIL_HANDLE; top = len(shadows) > 0 ? pop(&shadows) : base.NIL_HANDLE {
		for cur := top; cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, top) {
			n := get(d, cur)
			n.doc = doc
			if n.kind == .Element && n.shadow != base.NIL_HANDLE { append(&shadows, n.shadow) }
		}
	}
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
	if to := p.as_document ? parent : p.doc; c.doc != to { set_node_document(d, child, to) }   // DOM "adopt"
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

// Every node is freed after its children, in one walk by the tree's own links (a hostile page can build a very deep
// tree: nothing recurses); the trees that go with it (a template's contents, a shadow tree) are walked after, from a
// list only they need.
@(private)
destroy_subtree :: proc(d: ^Document, h: base.Handle) {
	more: [dynamic]base.Handle   // (context.temp_allocator, made by the first one found)
	for top := h; top != base.NIL_HANDLE; top = len(more) > 0 ? pop(&more) : base.NIL_HANDLE {
		cur := top
		for {
			n := get(d, cur)
			if n == nil { break }
			if n.first_child != base.NIL_HANDLE { cur = n.first_child; continue }
			next, parent := n.next, n.parent
			destroy_node(d, cur, n, &more)
			if cur == top { break }
			if next != base.NIL_HANDLE {
				cur = next
			} else {
				cur = parent
				get(d, parent).first_child = base.NIL_HANDLE   // its children are gone: it is next
			}
		}
	}
}

@(private = "file")
destroy_node :: proc(d: ^Document, h: base.Handle, n: ^Node, more: ^[dynamic]base.Handle) {
	if n.kind == .Element {
		ids_forget_node(d, h, n)
		if len(d.ns_extra) > 0 {
			if x, had := d.ns_extra[h]; had { delete(x.uri); delete(x.prefix); delete_key(&d.ns_extra, h) }
		}
		// a template's contents go with it, unless a script holds some of them (they are then a tree of their own)
		if len(d.templates) > 0 {
			if content, had := d.templates[h]; had {
				delete_key(&d.templates, h)
				if c := get(d, content); c != nil {
					c.held = false
					if c.pins_below == 0 { more_push(more, content) }
				}
			}
		}
		// its shadow tree goes with it (its pins count in the host's: nothing in it is pinned)
		if n.shadow != base.NIL_HANDLE { more_push(more, n.shadow); n.shadow = base.NIL_HANDLE }
	}
	if len(d.shadow_roots) > 0 || len(d.assigned) > 0 || len(d.manual_slot) > 0 || len(d.custom_states) > 0 || len(d.ce_custom) > 0 { shadow_forget_node(d, h, n) }
	free_node_data(n)
	base.pool_remove_tagged(&d.nodes, h)
}

@(private = "file")
more_push :: proc(more: ^[dynamic]base.Handle, h: base.Handle) {
	if more.allocator.procedure == nil { more^ = make([dynamic]base.Handle, context.temp_allocator) }
	append(more, h)
}

////////////////////////////////
// Attributes and text

// DOM setAttribute: the first attribute whose qualified name is `name`, whatever its namespace, takes the value; else
// one of no namespace is added. `name` is stored in ASCII lower case on an HTML or SVG element of an HTML document
// (lowers_attribute_names), as given otherwise or when `exact` (the DOM lower-cases nothing there).
set_attribute :: proc(d: ^Document, h: base.Handle, name, value: string, exact := false) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.kind != .Element || name == "" { return .Invalid_Argument }
	lname := name
	if !exact && lowers_attribute_names(n) { lname = lower_name(name) }
	for a, i in n.attrs {
		if a.name == lname { attribute_write(d, h, i, a.ns == ATTR_NS_NONE ? lname : attr_local(a), value); return .None }
	}
	attribute_add(d, h, Attr{heap_str(lname), heap_str(value), ATTR_NS_NONE}, lname)
	return .None
}

// DOM setAttributeNS once validated: the attribute of namespace `ns` and the local name of `qualified` takes the value,
// keeping its own prefix (setAttributeNode's takes `qualified`'s: `replace_prefix`), else `qualified` is added.
set_attribute_ns :: proc(d: ^Document, h: base.Handle, ns: Attr_Ns, qualified, value: string, replace_prefix := false) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.kind != .Element || qualified == "" { return .Invalid_Argument }
	local := attr_local_of(ns, qualified)
	if i := attribute_index_ns(n, ns, local); i >= 0 {
		if a := &n.attrs[i]; replace_prefix && a.name != qualified { delete(a.name); a.name = heap_str(qualified) }
		attribute_write(d, h, i, local, value)
		return .None
	}
	attribute_add(d, h, Attr{heap_str(qualified), heap_str(value), ns}, local)
	return .None
}

// The change of the value of attribute `i` of element `h`; `name` names it to the hooks (the caller's string: a hook may
// remove the attribute). What the browser does on a change (ids, slots, the hooks: style, src, on*) is for an attribute
// of no namespace only; the journal (mutation observers, restyles) sees them all.
@(private = "file")
attribute_write :: proc(d: ^Document, h: base.Handle, i: int, name, value: string) {
	a := &get(d, h).attrs[i]
	plain := a.ns == ATTR_NS_NONE
	old := a.value
	if old == value {
		// the same value (a script that writes it again at every scroll event): observers and callbacks still see the write,
		// as the DOM says, but the document did not change: no new version, so no restyle and no layout
		journal_record(d, .Attribute, h, base.NIL_HANDLE, name, old, true, ns = a.ns)
		if plain { notify_attribute(d, h, name) }
		return
	}
	a.value = heap_str(value)
	touch(d)
	d.attr_version += 1
	if plain && name == "id" { ids_changed(d, h, old, true, value, true) }
	journal_record(d, .Attribute, h, base.NIL_HANDLE, name, old, true, ns = a.ns)
	delete(old)
	if !plain { return }
	if len(d.shadow_roots) > 0 { shadow_attribute(d, h, name) }
	notify_attribute(d, h, name)
}

// A new attribute `a` of element `h`, named `name` to the hooks (its local name).
@(private = "file")
attribute_add :: proc(d: ^Document, h: base.Handle, a: Attr, name: string) {
	append(&get(d, h).attrs, a)
	touch(d)
	d.attr_version += 1
	plain := a.ns == ATTR_NS_NONE
	if plain && name == "id" { ids_changed(d, h, "", false, a.value, true) }
	if plain && name == TIMED_ATTRIBUTE { timed_add(d, h) }
	journal_record(d, .Attribute, h, base.NIL_HANDLE, name, "", false, ns = a.ns)
	if !plain { return }
	if len(d.shadow_roots) > 0 { shadow_attribute(d, h, name) }
	notify_attribute(d, h, name)
}

// `name` in ASCII lower case (as element names are kept, create_element): itself when it has no upper-case ASCII
// letter (the common case: no allocation), else a copy in the temp allocator.
lower_name :: proc(name: string) -> string {
	for i in 0 ..< len(name) {
		if name[i] < 'A' || name[i] > 'Z' { continue }
		b := make([]u8, len(name), context.temp_allocator)
		for j in 0 ..< len(name) { c := name[j]; b[j] = c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c }
		return string(b)
	}
	return name
}

// The value of the attribute of no namespace named `name`: what the browser reads (style, src, on*...).
get_attribute :: proc(d: ^Document, h: base.Handle, name: string) -> (value: string, ok: bool) {
	n := get(d, h)
	if n == nil || n.kind != .Element { return "", false }
	// an element of an XML document: names as given; the browser's own readers ask in lower case (an SVG viewBox),
	// so ASCII case is ignored on both sides after an exact match (scripts: get_attribute_exact)
	if n.xml == .Element {
		for a in n.attrs { if a.ns == ATTR_NS_NONE && a.name == name { return a.value, true } }
		for a in n.attrs { if a.ns == ATTR_NS_NONE && strings.equal_fold(a.name, name) { return a.value, true } }
		return "", false
	}
	// names are stored in lower case: compare folding the query's ASCII letters, without allocating (a hot path of
	// scripts: reflected IDL attributes)
	outer: for a in n.attrs {
		if len(a.name) != len(name) || a.ns != ATTR_NS_NONE { continue }
		for i in 0 ..< len(name) {
			c := name[i]
			if c >= 'A' && c <= 'Z' { c += 32 }
			if c != a.name[i] { continue outer }
		}
		return a.value, true
	}
	return "", false
}

// The value of the attribute of namespace `ns` and local name `local` (an SVG <use>'s xlink:href).
get_attribute_ns :: proc(d: ^Document, h: base.Handle, ns: Attr_Ns, local: string) -> (value: string, ok: bool) {
	n := get(d, h)
	if n == nil || n.kind != .Element { return "", false }
	if i := attribute_index_ns(n, ns, local); i >= 0 { return n.attrs[i].value, true }
	return "", false
}

// Whether the attribute names given to an element are stored in ASCII lower case: an HTML element's of an HTML document
// (DOM), an SVG element's too (the browser's form for them, that the bindings give their case back).
lowers_attribute_names :: #force_inline proc(n: ^Node) -> bool { return n.xml != .Element && (n.ns == .HTML || n.ns == .SVG) }

// DOM "get an attribute by name" for scripts: the first attribute of that qualified name, whatever its namespace; the
// name in lower case on an HTML element of an HTML document, exactly as given on one of an XML document
// (is_xml_element) or of another namespace, as given then in lower case on an SVG one (the browser's form of its names).
// The attribute's index, -1 when none.
attribute_index :: proc(n: ^Node, name: string) -> int {
	if n == nil || n.kind != .Element { return -1 }
	if n.ns != .HTML || n.xml == .Element {
		for a, i in n.attrs { if a.name == name { return i } }
	}
	if lowers_attribute_names(n) {
		lname := lower_name(name)
		for a, i in n.attrs { if a.name == lname { return i } }
	}
	return -1
}

// DOM "get an attribute by namespace and local name": the index of the attribute of namespace `ns` whose local name is
// `local`, -1 when none.
attribute_index_ns :: proc(n: ^Node, ns: Attr_Ns, local: string) -> int {
	if n == nil || n.kind != .Element { return -1 }
	for a, i in n.attrs { if a.ns == ns && attr_local(a) == local { return i } }
	return -1
}

// getAttribute, hasAttribute (attribute_index).
get_attribute_exact :: proc(d: ^Document, h: base.Handle, name: string) -> (value: string, ok: bool) {
	n := get(d, h)
	if i := attribute_index(n, name); i >= 0 { return n.attrs[i].value, true }
	return "", false
}

// DOM removeAttribute: the first attribute of that qualified name, whatever its namespace (attribute_index's names);
// `exact`: `name` is the stored name itself, not lower-cased first.
remove_attribute :: proc(d: ^Document, h: base.Handle, name: string, exact := false) -> Error {
	n := get(d, h)
	if n == nil { return .Invalid_Handle }
	if n.kind != .Element { return .None }
	lname := name
	if !exact && lowers_attribute_names(n) { lname = lower_name(name) }
	for a, i in n.attrs {
		if a.name == lname { attribute_remove(d, h, i, a.ns == ATTR_NS_NONE ? lname : attr_local(a)); return .None }
	}
	return .None
}

// DOM removeAttributeNS.
remove_attribute_ns :: proc(d: ^Document, h: base.Handle, ns: Attr_Ns, local: string) {
	if i := attribute_index_ns(get(d, h), ns, local); i >= 0 { attribute_remove(d, h, i, local) }
}

// Removes attribute `i` of element `h`, named `name` to the hooks (the caller's string; attribute_write says which see it).
@(private = "file")
attribute_remove :: proc(d: ^Document, h: base.Handle, i: int, name: string) {
	n := get(d, h)
	a := n.attrs[i]
	ordered_remove(&n.attrs, i)
	touch(d)
	d.attr_version += 1
	plain := a.ns == ATTR_NS_NONE
	if plain && name == "id" { ids_changed(d, h, a.value, true, "", false) }
	journal_record(d, .Attribute, h, base.NIL_HANDLE, name, a.value, true, ns = a.ns)
	delete(a.name); delete(a.value)
	if !plain { return }
	if len(d.shadow_roots) > 0 { shadow_attribute(d, h, name) }
	notify_attribute(d, h, name)
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
