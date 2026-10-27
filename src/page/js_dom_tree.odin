package page

// The DOM Standard's tree for JavaScript (api/js_dom_tree.widl): Node, the ParentNode / ChildNode mixins,
// CharacterData, the creation of nodes, and the mutation algorithms with their checks ("ensure pre-insertion
// validity", "replace a child", "replace all"), on the browser's DOM (package dom).
//
// Every DOM operation that changes the tree in several steps (inserting a fragment, replacing all children) runs as
// one journal batch (dom.batch_begin): a MutationObserver sees it as one record, as the standard queues it. Moving a
// node out of its old parent is an operation of its own (DOM "adopt"), done before the batch opens.
//
// One document per page: adopting is removing from the parent, importing is cloning.

import "core:strings"
import "core:unicode/utf8"
import "wb:base"
import "wb:dom"

////////////////////////////////
// Helpers shared by the js_dom_*.odin files

// The calling module's document, nil in a worker.
@(private)
jd_doc :: #force_inline proc(c: ^Call) -> ^dom.Document { return call_doc(c) }

@(private)
jd_node :: #force_inline proc(d: ^dom.Document, h: base.Handle) -> ^dom.Node { return d == nil ? nil : dom.get(d, h) }

// The document's element (the root element): the first element child of the document node.
@(private)
jd_document_element :: proc(d: ^dom.Document) -> base.Handle {
	r := dom.get(d, d.root)
	if r == nil { return base.NIL_HANDLE }
	for ch := r.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if dom.get(d, ch).kind == .Element { return ch }
	}
	return base.NIL_HANDLE
}

// The first child element of `h` named `name` (HTML namespace).
@(private)
jd_child_named :: proc(d: ^dom.Document, h: base.Handle, name: string) -> base.Handle {
	n := dom.get(d, h)
	if n == nil { return base.NIL_HANDLE }
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		cn := dom.get(d, ch)
		if cn.kind == .Element && cn.ns == .HTML && cn.name == name { return ch }
	}
	return base.NIL_HANDLE
}

// document.body: the first <body> or <frameset> child of the <html> document element.
@(private)
jd_body :: proc(d: ^dom.Document) -> base.Handle {
	de := jd_document_element(d)
	n := jd_node(d, de)
	if n == nil || n.name != "html" || n.ns != .HTML { return base.NIL_HANDLE }
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		cn := dom.get(d, ch)
		if cn.kind == .Element && cn.ns == .HTML && (cn.name == "body" || cn.name == "frameset") { return ch }
	}
	return base.NIL_HANDLE
}

@(private)
jd_head :: proc(d: ^dom.Document) -> base.Handle {
	de := jd_document_element(d)
	n := jd_node(d, de)
	if n == nil || n.name != "html" { return base.NIL_HANDLE }
	return jd_child_named(d, de, "head")
}

@(private)
jd_is_element :: #force_inline proc(d: ^dom.Document, h: base.Handle) -> bool {
	n := dom.get(d, h)
	return n != nil && n.kind == .Element
}

@(private)
jd_is_char_data :: #force_inline proc(n: ^dom.Node) -> bool { return n.kind == .Text || n.kind == .Comment }

// The byte index of UTF-16 offset `off` in UTF-8 `s` (clamped to the end; an offset inside a surrogate pair goes to the
// character's start: this DOM keeps text as UTF-8, where a lone surrogate cannot exist).
@(private)
utf8_index :: proc(s: string, off: int) -> int {
	n := 0
	i := 0
	for i < len(s) && n < off {
		b := s[i]
		step, units := 1, 1
		switch {
		case b < 0x80:
		case b < 0xE0: step = 2
		case b < 0xF0: step = 3
		case: step, units = 4, 2
		}
		if n + units > off { break }
		n += units
		i += step
	}
	return min(i, len(s))
}

@(private)
is_ascii_ws :: #force_inline proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r' }

// XML's Name production, as the DOM's "valid element / attribute name" checks it (DOM §1.4 since 2025: names may not
// contain ASCII whitespace, NUL, '/', '>' ; element names start with an ASCII letter or a non-ASCII character).
@(private)
valid_element_name :: proc(name: string) -> bool {
	if name == "" { return false }
	c := name[0]
	if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80) { return false }
	for i in 1 ..< len(name) {
		b := name[i]
		if is_ascii_ws(b) || b == 0 || b == '/' || b == '>' { return false }
	}
	return true
}

@(private)
valid_attribute_name :: proc(name: string) -> bool {
	if name == "" { return false }
	for i in 0 ..< len(name) {
		b := name[i]
		if is_ascii_ws(b) || b == 0 || b == '/' || b == '>' || b == '=' { return false }
	}
	return true
}

////////////////////////////////
// Node

Node_nodeName :: proc(c: ^Call, node: Api_Node) -> string {
	n := node.data
	switch n.kind {
	case .Element: return jd_qualified_name(c.page.doc, H(node.handle), true)
	case .Text: return n.xml == .CDATA ? "#cdata-section" : "#text"
	case .Comment: return n.xml == .Processing_Instruction ? n.name : "#comment"
	case .Document: return "#document"
	case .Doctype: return n.name
	case .Fragment: return n.as_document ? "#document" : "#document-fragment"
	}
	return ""
}

Node_baseURI :: proc(c: ^Call, node: Api_Node) -> string { return document_base_url(c.page) }

// The document's base URL: the first <base href> resolved against the document's URL, else the document's URL.
document_base_url :: proc(p: ^Page) -> string {
	d := p.doc
	head := jd_head(d)
	if head != base.NIL_HANDLE {
		for ch := dom.get(d, head).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			n := dom.get(d, ch)
			if n.kind != .Element || n.name != "base" { continue }
			if href, ok := dom.get_attribute(d, ch, "href"); ok {
				if r, rok := resolve_against(href, p.env.location.href); rok {
					out := strings.clone(r, context.temp_allocator)
					delete(r)
					return out
				}
			}
			break
		}
	}
	if fb := frame_fallback_base(p); fb != "" { return fb }   // about:blank / srcdoc in a frame: the parent's (frames.odin)
	return p.env.location.href
}

Node_isConnected :: proc(c: ^Call, node: Api_Node) -> bool { return dom.is_connected(c.page.doc, H(node.handle)) }

// The document the contents of the page's <template>s belong to (HTML "appropriate template contents owner document"):
// one without browsing context or custom element registry, so what a library makes there with ownerDocument.createElement
// (Polymer's dom-repeat) is not constructed. It is a document node of its own, kept by the page.
Template_Doc :: struct {
	doc:    ^dom.Document,
	handle: base.Handle,
}

@(private)
template_owner_document :: proc(p: ^Page) -> base.Handle {
	d := p.doc
	if p.template_doc.doc == d && dom.get(d, p.template_doc.handle) != nil { return p.template_doc.handle }
	f := dom.create_fragment(d)
	n := dom.get(d, f)
	n.as_document, n.held = true, true
	p.template_doc = {d, f}
	return f
}

Node_ownerDocument :: proc(c: ^Call, node: Api_Node) -> u64 {
	if node.data.kind == .Document || node.data.as_document { return 0 }
	// a node of a document createHTMLDocument made, shadow trees included: that document; the contents of a template
	// (and what was made in them): the inert document of the templates
	d := c.page.doc
	if r := dom.shadow_including_root(d, H(node.handle)); r != d.root {
		if n := dom.get(d, r); n != nil {
			if n.as_document { return u64(r) }
			if n.kind == .Fragment && n.held { return u64(template_owner_document(c.page)) }
		}
	}
	return u64(d.root)
}

Node_parentElement :: proc(c: ^Call, node: Api_Node) -> u64 {
	p := node.data.parent
	return jd_is_element(c.page.doc, p) ? u64(p) : 0
}

Node_hasChildNodes :: proc(c: ^Call, node: Api_Node) -> bool { return node.data.first_child != base.NIL_HANDLE }

Node_nodeValue :: proc(c: ^Call, node: Api_Node) -> (string, Api_Error) {
	if jd_is_char_data(node.data) { return node.data.text, .None }
	return "", .Not_Found
}

Node_set_nodeValue :: proc(c: ^Call, node: Api_Node, value: string) -> Api_Error {
	if jd_is_char_data(node.data) { dom.set_data(c.page.doc, H(node.handle), value) }
	return .None
}

Node_textContent :: proc(c: ^Call, node: Api_Node) -> (string, Api_Error) {
	#partial switch node.data.kind {
	case .Document, .Doctype: return "", .Not_Found
	case .Fragment: if node.data.as_document { return "", .Not_Found }
	}
	return dom.text_content(c.page.doc, H(node.handle)), .None
}

Node_set_textContent :: proc(c: ^Call, node: Api_Node, value: string) -> Api_Error {
	#partial switch node.data.kind {
	case .Document, .Doctype: return .None
	}
	return dom_error(dom.set_text_content(c.page.doc, H(node.handle), value))
}

Node_normalize :: proc(c: ^Call, node: Api_Node) { dom.normalize(c.page.doc, H(node.handle)) }

Node_cloneNode :: proc(c: ^Call, node: Api_Node, deep: bool) -> (u64, Api_Error) {
	if node.data.kind == .Document { return 0, fail(c, .Not_Supported, "cloneNode: this browser has one document per page; the document cannot be cloned") }
	if node.data.is_shadow { return 0, fail(c, .Not_Supported, "A shadow root cannot be cloned.") }
	h := dom.clone_node(c.page.doc, H(node.handle), deep)
	scripts_cloned(c.page, H(node.handle), h)   // (js_load_fragment.odin)
	// a clone of a node of the document is in the document's realm: its custom elements are upgraded (HTML "create an
	// element": cloning enqueues an upgrade reaction); one of a template's contents stays inert
	if rn := dom.get(c.page.doc, dom.shadow_including_root(c.page.doc, H(node.handle))); rn == nil || !(rn.kind == .Fragment && rn.held) {
		custom_elements_cloned(c.page, h)
	}
	return u64(h), .None
}

Document_importNodeCopy :: proc(c: ^Call, node: Api_Node, deep: bool) -> (u64, Api_Error) {
	if node.data.kind == .Document { return 0, fail(c, .Not_Supported, "importNode: this browser has one document per page; the document cannot be imported") }
	if node.data.is_shadow { return 0, fail(c, .Not_Supported, "A shadow root cannot be imported.") }
	h := dom.clone_node(c.page.doc, H(node.handle), deep)
	scripts_cloned(c.page, H(node.handle), h)
	custom_elements_cloned(c.page, h)
	return u64(h), .None
}

Node_isEqualNode :: proc(c: ^Call, node: Api_Node, other: Api_Node) -> bool {
	if other.data == nil { return false }
	return dom.is_equal_node(c.page.doc, H(node.handle), H(other.handle))
}

Node_isSameNode :: proc(c: ^Call, node: Api_Node, other: Api_Node) -> bool { return node.handle == other.handle }

Node_compareDocumentPosition :: proc(c: ^Call, node: Api_Node, other: Api_Node) -> u32 {
	return u32(dom.compare_document_position(c.page.doc, H(node.handle), H(other.handle)))
}

Node_contains :: proc(c: ^Call, node: Api_Node, other: Api_Node) -> bool {
	if other.data == nil { return false }
	return dom.contains(c.page.doc, H(node.handle), H(other.handle))
}

// DOM "locate a namespace prefix" / "locate a namespace", for the element a node stands for.
@(private)
lookup_element_of :: proc(d: ^dom.Document, h: base.Handle) -> base.Handle {
	n := dom.get(d, h)
	if n == nil { return base.NIL_HANDLE }
	#partial switch n.kind {
	case .Element: return h
	case .Document: return jd_document_element(d)
	case .Doctype, .Fragment: return base.NIL_HANDLE
	}
	return jd_is_element(d, n.parent) ? n.parent : base.NIL_HANDLE
}

@(private)
locate_namespace :: proc(d: ^dom.Document, h: base.Handle, prefix: string) -> (string, bool) {
	if prefix == "xml" { return dom.NS_XML, true }
	if prefix == "xmlns" { return dom.NS_XMLNS, true }
	for el := lookup_element_of(d, h); el != base.NIL_HANDLE; {
		uri := dom.ns_uri(d, el)
		if uri != "" && dom.ns_prefix(d, el) == prefix { return uri, true }
		attr := prefix == "" ? "xmlns" : strings.concatenate({"xmlns:", prefix}, context.temp_allocator)
		if v, ok := dom.get_attribute(d, el, attr); ok { return v, v != "" }
		n := dom.get(d, el)
		el = jd_is_element(d, n.parent) ? n.parent : base.NIL_HANDLE
	}
	return "", false
}

Node_lookupPrefix :: proc(c: ^Call, node: Api_Node, namespace: Maybe(string)) -> (string, Api_Error) {
	ns, has := namespace.?
	if !has || ns == "" { return "", .Not_Found }
	d := c.page.doc
	for el := lookup_element_of(d, H(node.handle)); el != base.NIL_HANDLE; {
		if dom.ns_uri(d, el) == ns && dom.ns_prefix(d, el) != "" { return dom.ns_prefix(d, el), .None }
		for a in dom.get(d, el).attrs {
			if strings.has_prefix(a.name, "xmlns:") && a.value == ns { return a.name[6:], .None }
		}
		n := dom.get(d, el)
		el = jd_is_element(d, n.parent) ? n.parent : base.NIL_HANDLE
	}
	return "", .Not_Found
}

Node_lookupNamespaceURI :: proc(c: ^Call, node: Api_Node, prefix: Maybe(string)) -> (string, Api_Error) {
	p, _ := prefix.?
	uri, ok := locate_namespace(c.page.doc, H(node.handle), p)
	if !ok || uri == "" { return "", .Not_Found }
	return uri, .None
}

Node_isDefaultNamespace :: proc(c: ^Call, node: Api_Node, namespace: Maybe(string)) -> bool {
	ns, _ := namespace.?
	uri, _ := locate_namespace(c.page.doc, H(node.handle), "")
	return uri == ns
}

Node_rootNode :: proc(c: ^Call, node: Api_Node) -> u64 { return u64(dom.tree_root(c.page.doc, H(node.handle))) }

Node_length :: proc(c: ^Call, node: Api_Node) -> u32 { return u32(node_length(c.page.doc, H(node.handle))) }

// DOM "length" of a node: UTF-16 code units of character data, else the number of children (doctype: 0).
node_length :: proc(d: ^dom.Document, h: base.Handle) -> int {
	n := dom.get(d, h)
	if n == nil { return 0 }
	#partial switch n.kind {
	case .Text, .Comment: return utf16_length(n.text)
	case .Doctype: return 0
	}
	return dom.child_count(d, h)
}

Node_pinAll :: proc(c: ^Call, nodes: []u64) {
	d := jd_doc(c)
	if d == nil { return }
	for h in nodes { dom.pin(d, H(h)) }
}

Node_unpinAll :: proc(c: ^Call, nodes: []u64) {
	d := jd_doc(c)
	if d == nil { return }
	for h in nodes { dom.unpin(d, H(h)) }
}

////////////////////////////////
// The mutation algorithms (DOM §4.2.3)

@(private)
is_parent_kind :: #force_inline proc(n: ^dom.Node) -> bool { return n.kind == .Document || n.kind == .Fragment || n.kind == .Element }

// Whether some child of `parent` is an element (other than `except`).
@(private)
has_element_child :: proc(d: ^dom.Document, parent: base.Handle, except := base.NIL_HANDLE) -> bool {
	for ch := dom.get(d, parent).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if ch != except && dom.get(d, ch).kind == .Element { return true }
	}
	return false
}

@(private)
has_doctype_child :: proc(d: ^dom.Document, parent: base.Handle, except := base.NIL_HANDLE) -> bool {
	for ch := dom.get(d, parent).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if ch != except && dom.get(d, ch).kind == .Doctype { return true }
	}
	return false
}

@(private)
doctype_following :: proc(d: ^dom.Document, child: base.Handle) -> bool {
	for s := dom.get(d, child).next; s != base.NIL_HANDLE; s = dom.get(d, s).next {
		if dom.get(d, s).kind == .Doctype { return true }
	}
	return false
}

@(private)
element_preceding :: proc(d: ^dom.Document, child: base.Handle) -> bool {
	for s := dom.get(d, child).prev; s != base.NIL_HANDLE; s = dom.get(d, s).prev {
		if dom.get(d, s).kind == .Element { return true }
	}
	return false
}

// DOM "ensure pre-insertion validity" (replacing = false) and the checks of "replace a child" (replacing = true, `child`
// the node replaced). Records the message of the failure in the call.
@(private)
check_insert :: proc(c: ^Call, parent, node, child: base.Handle, replacing: bool) -> Api_Error {
	d := c.page.doc
	p, n := dom.get(d, parent), dom.get(d, node)
	if p == nil || n == nil { return fail(c, .Invalid_Handle, "the node is gone") }
	if !is_parent_kind(p) { return fail(c, .Hierarchy, "This node type does not support this method (the parent cannot have children).") }
	// a node without children is an ancestor of nothing: inserting new nodes stays O(1) at any depth
	if node == parent || (n.first_child != base.NIL_HANDLE && dom.is_ancestor_or_self(d, node, parent)) { return fail(c, .Hierarchy, "The new child element contains the parent.") }
	if child != base.NIL_HANDLE {
		ch := dom.get(d, child)
		if ch == nil || ch.parent != parent {
			return fail(c, .Not_Found, replacing ? "The node to be replaced is not a child of this node." : "The node before which the new node is to be inserted is not a child of this node.")
		}
	}
	#partial switch n.kind {
	case .Document: return fail(c, .Hierarchy, "Nodes of type '#document' may not be inserted inside nodes of type '#document-fragment' or elsewhere.")
	}
	if n.kind == .Text && p.kind == .Document { return fail(c, .Hierarchy, "Nodes of type '#text' may not be inserted inside nodes of type '#document'.") }
	if n.kind == .Doctype && p.kind != .Document { return fail(c, .Hierarchy, "A doctype may only be a child of the document.") }
	if p.kind != .Document { return .None }
	except := replacing ? child : base.NIL_HANDLE
	#partial switch n.kind {
	case .Fragment:
		elements := 0
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			k := dom.get(d, ch).kind
			if k == .Element { elements += 1 }
			if k == .Text { return fail(c, .Hierarchy, "Nodes of type '#text' may not be inserted inside nodes of type '#document'.") }
		}
		if elements > 1 { return fail(c, .Hierarchy, "The document may have only one element child.") }
		if elements == 1 {
			if has_element_child(d, parent, except) { return fail(c, .Hierarchy, "Only one element on document allowed.") }
			if child != base.NIL_HANDLE && ((!replacing && dom.get(d, child).kind == .Doctype) || doctype_following(d, child)) {
				return fail(c, .Hierarchy, "The element would come before the doctype.")
			}
		}
	case .Element:
		if has_element_child(d, parent, except) { return fail(c, .Hierarchy, "Only one element on document allowed.") }
		if child != base.NIL_HANDLE && ((!replacing && dom.get(d, child).kind == .Doctype) || doctype_following(d, child)) {
			return fail(c, .Hierarchy, "The element would come before the doctype.")
		}
	case .Doctype:
		if has_doctype_child(d, parent, except) { return fail(c, .Hierarchy, "The document has a doctype already.") }
		if child != base.NIL_HANDLE && element_preceding(d, child) { return fail(c, .Hierarchy, "The doctype would come after the document element.") }
		if child == base.NIL_HANDLE && has_element_child(d, parent) { return fail(c, .Hierarchy, "The doctype would come after the document element.") }
	}
	return .None
}

// DOM "insert": `node` (or a fragment's children) before `child` (NIL: at the end) of `parent`, the checks done. One
// journal batch; a node in another tree leaves it first (an operation of its own).
@(private)
insert_node :: proc(d: ^dom.Document, parent, node, child: base.Handle) {
	n := dom.get(d, node)
	if n.kind != .Fragment && n.parent != base.NIL_HANDLE && n.parent != parent {
		dom.detach(d, node)
	} else if n.kind != .Fragment && n.parent == parent && node != child {
		dom.detach(d, node)   // moved within its parent: removed, then inserted (two records, as DOM queues them)
	}
	batch := dom.batch_begin(d)
	defer dom.batch_end(d, batch)
	if n.kind == .Fragment {
		for {
			f := dom.get(d, node)
			first := f.first_child
			if first == base.NIL_HANDLE { break }
			dom.detach(d, first)
			dom.insert_before(d, parent, first, child)
		}
		return
	}
	dom.insert_before(d, parent, node, child)
}

// DOM "pre-insert".
@(private)
pre_insert :: proc(c: ^Call, parent, node, child: base.Handle) -> Api_Error {
	if err := check_insert(c, parent, node, child, false); err != .None { return err }
	d := c.page.doc
	ref := child
	if ref == node { ref = dom.get(d, node).next }
	insert_node(d, parent, node, ref)
	return .None
}

// DOM "replace a child".
@(private)
replace_child :: proc(c: ^Call, parent, node, child: base.Handle) -> Api_Error {
	if err := check_insert(c, parent, node, child, true); err != .None { return err }
	if node == child { return .None }
	d := c.page.doc
	ref := dom.get(d, child).next
	if ref == node { ref = dom.get(d, node).next }
	n := dom.get(d, node)
	if n.kind != .Fragment && n.parent != base.NIL_HANDLE { dom.detach(d, node) }   // adopt: an operation of its own
	batch := dom.batch_begin(d)
	defer dom.batch_end(d, batch)
	dom.detach(d, child)
	insert_node(d, parent, node, ref)
	dom.destroy_unpinned(d, child)
	return .None
}

// DOM "replace all" with `node` (NIL: none): one batch.
@(private)
replace_all :: proc(d: ^dom.Document, parent, node: base.Handle) {
	if node != base.NIL_HANDLE {
		if n := dom.get(d, node); n.kind != .Fragment && n.parent != base.NIL_HANDLE { dom.detach(d, node) }
	}
	batch := dom.batch_begin(d)
	defer dom.batch_end(d, batch)
	for {
		p := dom.get(d, parent)
		first := p.first_child
		if first == base.NIL_HANDLE { break }
		dom.detach(d, first)
		dom.destroy_unpinned(d, first)
	}
	if node != base.NIL_HANDLE { insert_node(d, parent, node, base.NIL_HANDLE) }
}

Node_preInsert :: proc(c: ^Call, parent: Api_Node, node: Api_Node, child: Api_Node) -> Api_Error {
	return pre_insert(c, H(parent.handle), H(node.handle), H(child.handle))
}

Node_replaceChildChecked :: proc(c: ^Call, parent: Api_Node, node: Api_Node, child: Api_Node) -> Api_Error {
	return replace_child(c, H(parent.handle), H(node.handle), H(child.handle))
}

Node_preRemove :: proc(c: ^Call, parent: Api_Node, child: Api_Node) -> Api_Error {
	if child.data.parent != H(parent.handle) { return fail(c, .Not_Found, "The node to be removed is not a child of this node.") }
	d := c.page.doc
	dom.detach(d, H(child.handle))
	dom.destroy_unpinned(d, H(child.handle))
	return .None
}

ChildNode_remove :: proc(c: ^Call, node: Api_Node) {
	if node.data.parent == base.NIL_HANDLE { return }
	d := c.page.doc
	dom.detach(d, H(node.handle))
	dom.destroy_unpinned(d, H(node.handle))
}

// The (Node or DOMString) arguments of the ParentNode / ChildNode methods (packed by the engine), as nodes: strings
// become new Text nodes.
@(private)
unpack_items :: proc(d: ^dom.Document, items: []u8) -> (out: [dynamic]base.Handle, ok: bool) {
	out = make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	i := 0
	for i < len(items) {
		kind := items[i]
		i += 1
		switch kind {
		case 0:
			if i + 8 > len(items) { return out, false }
			h: u64
			for k in 0 ..< 8 { h |= u64(items[i + k]) << (8 * uint(k)) }
			i += 8
			if dom.get(d, H(h)) == nil { return out, false }
			append(&out, H(h))
		case 1:
			if i + 4 > len(items) { return out, false }
			n := int(u32(items[i]) | u32(items[i + 1]) << 8 | u32(items[i + 2]) << 16 | u32(items[i + 3]) << 24)
			i += 4
			if n > len(items) - i || !utf8.valid_string(string(items[i:i + n])) { return out, false }
			append(&out, dom.create_text(d, string(items[i:i + n])))
			i += n
		case:
			return out, false
		}
	}
	return out, true
}

// DOM "convert nodes into a node": one node as is, several in a new fragment (each appended to it: a pre-insert of its
// own). NIL for none.
@(private)
convert_nodes :: proc(c: ^Call, nodes: []base.Handle) -> (base.Handle, Api_Error) {
	d := c.page.doc
	if len(nodes) == 0 { return base.NIL_HANDLE, .None }
	if len(nodes) == 1 { return nodes[0], .None }
	frag := dom.create_fragment(d)
	for n in nodes {
		if err := pre_insert(c, frag, n, base.NIL_HANDLE); err != .None {
			dom.destroy_unpinned(d, frag)
			return base.NIL_HANDLE, err
		}
	}
	return frag, .None
}

// The nodes made for an operation that failed: those nobody holds go.
@(private)
discard_unused :: proc(d: ^dom.Document, node: base.Handle) {
	if n := dom.get(d, node); n != nil && n.parent == base.NIL_HANDLE { dom.destroy_unpinned(d, node) }
}

Node_insertItems :: proc(c: ^Call, node: Api_Node, mode: i32, items: []u8) -> Api_Error {
	d := c.page.doc
	this := H(node.handle)
	nodes, ok := unpack_items(d, items)
	if !ok { return fail(c, .Type, "invalid argument list") }
	in_nodes :: proc(nodes: []base.Handle, h: base.Handle) -> bool {
		for x in nodes { if x == h { return true } }
		return false
	}
	switch mode {
	case 0, 1, 2:   // prepend, append, replaceChildren
		if !is_parent_kind(node.data) && len(nodes) > 0 { return fail(c, .Hierarchy, "This node cannot have children.") }
		one, err := convert_nodes(c, nodes[:])
		if err != .None { return err }
		if one == base.NIL_HANDLE {
			if mode == 2 { replace_all(d, this, base.NIL_HANDLE) }
			return .None
		}
		switch mode {
		case 0: err = pre_insert(c, this, one, dom.get(d, this).first_child)
		case 1: err = pre_insert(c, this, one, base.NIL_HANDLE)
		case 2:
			err = check_insert(c, this, one, base.NIL_HANDLE, false)
			if err == .None { replace_all(d, this, one) }
		}
		if err != .None { discard_unused(d, one); return err }
		if dom.get(d, one) != nil && dom.get(d, one).kind == .Fragment { dom.destroy_unpinned(d, one) }
	case 3, 4, 5:   // before, after, replaceWith
		parent := node.data.parent
		if parent == base.NIL_HANDLE {
			for n in nodes { discard_unused(d, n) }
			return .None
		}
		viable := base.NIL_HANDLE
		if mode == 3 {
			prev := node.data.prev
			for prev != base.NIL_HANDLE && in_nodes(nodes[:], prev) { prev = dom.get(d, prev).prev }
			viable = prev
		} else {
			next := node.data.next
			for next != base.NIL_HANDLE && in_nodes(nodes[:], next) { next = dom.get(d, next).next }
			viable = next
		}
		one, err := convert_nodes(c, nodes[:])
		if err != .None { return err }
		if mode == 3 {
			viable = viable != base.NIL_HANDLE ? dom.get(d, viable).next : dom.get(d, parent).first_child
		}
		if one == base.NIL_HANDLE {
			if mode == 5 && dom.get(d, this).parent == parent { dom.detach(d, this) }
			return .None
		}
		if mode == 5 && dom.get(d, this).parent == parent {
			err = replace_child(c, parent, one, this)
		} else {
			err = pre_insert(c, parent, one, viable)
		}
		if err != .None { discard_unused(d, one); return err }
		if dom.get(d, one) != nil && dom.get(d, one).kind == .Fragment { dom.destroy_unpinned(d, one) }
	case:
		return fail(c, .Invalid_Argument, "unknown insertion mode")
	}
	return .None
}

////////////////////////////////
// ParentNode, ChildNode, NonElementParentNode

ParentNode_firstElementChild :: proc(c: ^Call, node: Api_Node) -> u64 {
	d := c.page.doc
	for ch := node.data.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if dom.get(d, ch).kind == .Element { return u64(ch) }
	}
	return 0
}

ParentNode_lastElementChild :: proc(c: ^Call, node: Api_Node) -> u64 {
	d := c.page.doc
	for ch := node.data.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev {
		if dom.get(d, ch).kind == .Element { return u64(ch) }
	}
	return 0
}

ParentNode_childElementCount :: proc(c: ^Call, node: Api_Node) -> u32 {
	d := c.page.doc
	k: u32
	for ch := node.data.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if dom.get(d, ch).kind == .Element { k += 1 }
	}
	return k
}

NonDocumentTypeChildNode_previousElementSibling :: proc(c: ^Call, node: Api_Node) -> u64 {
	d := c.page.doc
	for s := node.data.prev; s != base.NIL_HANDLE; s = dom.get(d, s).prev {
		if dom.get(d, s).kind == .Element { return u64(s) }
	}
	return 0
}

NonDocumentTypeChildNode_nextElementSibling :: proc(c: ^Call, node: Api_Node) -> u64 {
	d := c.page.doc
	for s := node.data.next; s != base.NIL_HANDLE; s = dom.get(d, s).next {
		if dom.get(d, s).kind == .Element { return u64(s) }
	}
	return 0
}

NonElementParentNode_getElementById :: proc(c: ^Call, node: Api_Node, id: string) -> u64 {
	return u64(dom.find_by_id_in(c.page.doc, H(node.handle), id))
}

////////////////////////////////
// CharacterData, Text, DocumentType

CharacterData_data :: proc(c: ^Call, node: Api_Node) -> string { return jd_is_char_data(node.data) ? node.data.text : "" }

CharacterData_set_data :: proc(c: ^Call, node: Api_Node, value: string) {
	if jd_is_char_data(node.data) { dom.set_data(c.page.doc, H(node.handle), value) }
}

CharacterData_length :: proc(c: ^Call, node: Api_Node) -> u32 { return jd_is_char_data(node.data) ? u32(utf16_length(node.data.text)) : 0 }

// DOM "replace data": UTF-16 offsets; Index_Size past the length.
@(private)
replace_data :: proc(c: ^Call, h: base.Handle, offset, count: u32, data: string) -> Api_Error {
	d := c.page.doc
	n := dom.get(d, h)
	if n == nil || !jd_is_char_data(n) { return .None }
	length := utf16_length(n.text)
	if int(offset) > length { return fail(c, .Index_Size, "The offset is greater than the node's length.") }
	end16 := min(int(offset) + int(count), length)
	a := utf8_index(n.text, int(offset))
	b := utf8_index(n.text, end16)
	out := strings.concatenate({n.text[:a], data, n.text[b:]}, context.temp_allocator)
	dom.set_data(d, h, out)
	return .None
}

CharacterData_substringData :: proc(c: ^Call, node: Api_Node, offset: u32, count: u32) -> (string, Api_Error) {
	if !jd_is_char_data(node.data) { return "", .None }
	t := node.data.text
	length := utf16_length(t)
	if int(offset) > length { return "", fail(c, .Index_Size, "The offset is greater than the node's length.") }
	a := utf8_index(t, int(offset))
	b := utf8_index(t, min(int(offset) + int(count), length))
	return t[a:b], .None
}

CharacterData_appendData :: proc(c: ^Call, node: Api_Node, data: string) {
	if !jd_is_char_data(node.data) { return }
	dom.set_data(c.page.doc, H(node.handle), strings.concatenate({node.data.text, data}, context.temp_allocator))
}

CharacterData_insertData :: proc(c: ^Call, node: Api_Node, offset: u32, data: string) -> Api_Error {
	return replace_data(c, H(node.handle), offset, 0, data)
}

CharacterData_deleteData :: proc(c: ^Call, node: Api_Node, offset: u32, count: u32) -> Api_Error {
	return replace_data(c, H(node.handle), offset, count, "")
}

CharacterData_replaceData :: proc(c: ^Call, node: Api_Node, offset: u32, count: u32, data: string) -> Api_Error {
	return replace_data(c, H(node.handle), offset, count, data)
}

Text_splitText :: proc(c: ^Call, node: Api_Node, offset: u32) -> (u64, Api_Error) {
	d := c.page.doc
	h := H(node.handle)
	if node.data.kind != .Text { return 0, fail(c, .Invalid_Handle, "splitText: not a Text node") }
	t := node.data.text
	if int(offset) > utf16_length(t) { return 0, fail(c, .Index_Size, "The offset is greater than the Text node's length.") }
	at := utf8_index(t, int(offset))
	tail := strings.clone(t[at:], context.temp_allocator)
	head := strings.clone(t[:at], context.temp_allocator)
	nt := dom.create_text(d, tail)
	if parent := node.data.parent; parent != base.NIL_HANDLE {
		dom.insert_before(d, parent, nt, dom.get(d, h).next)
	}
	dom.set_data(d, h, head)
	return u64(nt), .None
}

Text_wholeText :: proc(c: ^Call, node: Api_Node) -> string {
	d := c.page.doc
	h := H(node.handle)
	first := h
	for p := dom.get(d, first).prev; p != base.NIL_HANDLE && dom.get(d, p).kind == .Text; p = dom.get(d, p).prev { first = p }
	b := strings.builder_make(context.temp_allocator)
	for s := first; s != base.NIL_HANDLE && dom.get(d, s).kind == .Text; s = dom.get(d, s).next { strings.write_string(&b, dom.get(d, s).text) }
	return strings.to_string(b)
}

@(private)
doctype_field :: proc(n: ^dom.Node, name: string) -> string {
	if n.kind != .Doctype { return "" }
	for a in n.attrs { if a.name == name { return a.value } }
	return ""
}

DocumentType_name :: proc(c: ^Call, node: Api_Node) -> string { return node.data.kind == .Doctype ? node.data.name : "" }
DocumentType_publicId :: proc(c: ^Call, node: Api_Node) -> string { return doctype_field(node.data, "publicId") }
DocumentType_systemId :: proc(c: ^Call, node: Api_Node) -> string { return doctype_field(node.data, "systemId") }

////////////////////////////////
// Document

@(private)
no_document :: proc(c: ^Call) -> Api_Error { return fail(c, .Invalid_Handle, "no document in a worker") }

Document_createElementChecked :: proc(c: ^Call, local_name: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	if !valid_element_name(local_name) { return 0, fail(c, .Invalid_Character, "The tag name provided is not a valid name.") }
	h: base.Handle
	if root := dom.get(d, d.root); dom.is_xml_document(root) {
		// a page loaded as XML: its elements keep their names' case (application/xhtml+xml: in the HTML namespace)
		h = xml_create_element(d, root.xml == .Document_XHTML ? dom.NS_HTML : "", "", local_name)
	} else {
		h = dom.create_element(d, local_name)
	}
	custom_elements_created(c.page, h)   // a defined name: constructed before createElement returns
	return u64(h), .None
}

Document_createElementInert :: proc(c: ^Call, local_name: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	if !valid_element_name(local_name) { return 0, fail(c, .Invalid_Character, "The tag name provided is not a valid name.") }
	return u64(dom.create_element(d, local_name)), .None
}

// DOM "validate and extract": namespace, prefix and local name of a qualified name.
@(private)
validate_and_extract :: proc(c: ^Call, namespace: Maybe(string), qualified: string, element: bool) -> (ns: string, prefix: string, local: string, err: Api_Error) {
	ns, _ = namespace.?
	local = qualified
	if colon := strings.index_byte(qualified, ':'); colon >= 0 {
		prefix, local = qualified[:colon], qualified[colon + 1:]
		if prefix == "" || local == "" || strings.index_byte(local, ':') >= 0 { err = fail(c, .Invalid_Character, "The qualified name provided is not a valid name."); return }
	}
	if !(element ? valid_element_name(local) : valid_attribute_name(local)) || (prefix != "" && !valid_attribute_name(prefix)) {
		err = fail(c, .Invalid_Character, "The qualified name provided is not a valid name.")
		return
	}
	if prefix != "" && ns == "" { err = fail(c, .Namespace, "A prefix is given without a namespace."); return }
	if prefix == "xml" && ns != dom.NS_XML { err = fail(c, .Namespace, "The 'xml' prefix is reserved for the XML namespace."); return }
	if (qualified == "xmlns" || prefix == "xmlns") && ns != dom.NS_XMLNS { err = fail(c, .Namespace, "'xmlns' is reserved for the XMLNS namespace."); return }
	if ns == dom.NS_XMLNS && qualified != "xmlns" && prefix != "xmlns" { err = fail(c, .Namespace, "The XMLNS namespace is only for 'xmlns' names."); return }
	return
}

Document_createElementNSChecked :: proc(c: ^Call, namespace: Maybe(string), qualified_name: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	ns, prefix, local, err := validate_and_extract(c, namespace, qualified_name, true)
	if err != .None { return 0, err }
	if dom.is_xml_document(dom.get(d, d.root)) { return u64(xml_create_element(d, ns, prefix, local)), .None }
	return u64(dom.create_element_ns(d, local, dom.namespace_of(ns), ns, prefix)), .None
}

Document_createDocumentFragment :: proc(c: ^Call) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	return u64(dom.create_fragment(d)), .None
}

Document_createComment :: proc(c: ^Call, data: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	return u64(dom.create_comment(d, data)), .None
}

Document_createCDATASection :: proc(c: ^Call, data: string) -> (u64, Api_Error) {
	return 0, fail(c, .Not_Supported, "This operation is not supported for HTML documents.")
}

Document_adoptNode :: proc(c: ^Call, node: Api_Node) -> (u64, Api_Error) {
	if node.data.kind == .Document { return 0, fail(c, .Not_Supported, "The node provided is a document, which may not be adopted.") }
	if node.data.is_shadow { return 0, fail(c, .Hierarchy, "The node provided is a shadow root, which may not be adopted.") }
	if node.data.parent != base.NIL_HANDLE { dom.detach(c.page.doc, H(node.handle)) }
	return node.handle, .None
}

Document_documentURI :: proc(c: ^Call) -> string { return c.page.env.location.href }

Document_compatMode :: proc(c: ^Call) -> string {
	d := jd_doc(c)
	return d != nil && d.mode == .Quirks ? "BackCompat" : "CSS1Compat"
}

// The document's encoding (WHATWG name); the page decodes every document to UTF-8 (html.decode_document) and keeps
// the label it decoded from when it knows it.
Document_characterSet :: proc(c: ^Call) -> string { return document_encoding(c.page) }
Document_charset :: proc(c: ^Call) -> string { return document_encoding(c.page) }
Document_inputEncoding :: proc(c: ^Call) -> string { return document_encoding(c.page) }

@(private)
document_encoding :: proc(p: ^Page) -> string { return "UTF-8" }

Document_contentType :: proc(c: ^Call) -> string {
	if d := jd_doc(c); d != nil && dom.get(d, d.root).xml == .Document_XHTML { return "application/xhtml+xml" }
	return "text/html"
}

Document_doctype :: proc(c: ^Call) -> u64 {
	d := jd_doc(c)
	if d == nil { return 0 }
	for ch := dom.get(d, d.root).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if dom.get(d, ch).kind == .Doctype { return u64(ch) }
	}
	return 0
}

// The first <title> of the document (in tree order), HTML namespace.
@(private)
title_element :: proc(d: ^dom.Document) -> base.Handle {
	for cur := dom.next_in_tree(d, d.root, d.root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, d.root) {
		n := dom.get(d, cur)
		if n.kind == .Element && n.name == "title" && n.ns != .SVG { return cur }
	}
	return base.NIL_HANDLE
}

// ASCII whitespace stripped and collapsed (HTML "strip and collapse ASCII whitespace").
@(private)
collapse_ws :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	pending := false
	for i in 0 ..< len(s) {
		if is_ascii_ws(s[i]) { pending = strings.builder_len(b) > 0; continue }
		if pending { strings.write_byte(&b, ' '); pending = false }
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

Document_title :: proc(c: ^Call) -> string {
	d := jd_doc(c)
	if d == nil { return "" }
	t := title_element(d)
	if t == base.NIL_HANDLE { return "" }
	b := strings.builder_make(context.temp_allocator)
	for ch := dom.get(d, t).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if n := dom.get(d, ch); n.kind == .Text { strings.write_string(&b, n.text) }
	}
	return collapse_ws(strings.to_string(b))
}

Document_set_title :: proc(c: ^Call, value: string) {
	d := jd_doc(c)
	if d == nil { return }
	t := title_element(d)
	if t == base.NIL_HANDLE {
		head := jd_head(d)
		if head == base.NIL_HANDLE { return }
		t = dom.create_element(d, "title")
		dom.append_child(d, head, t)
	}
	dom.set_text_content(d, t, value)
}

Document_dir :: proc(c: ^Call) -> string {
	d := jd_doc(c)
	if d == nil { return "" }
	v, _ := dom.get_attribute(d, jd_document_element(d), "dir")
	return enumerated_dir(v)
}

Document_set_dir :: proc(c: ^Call, value: string) {
	d := jd_doc(c)
	if d == nil { return }
	if de := jd_document_element(d); de != base.NIL_HANDLE { dom.set_attribute(d, de, "dir", value) }
}

// The `dir` attribute as its IDL attribute reflects it: "ltr", "rtl", "auto" (any case), else "".
@(private)
enumerated_dir :: proc(v: string) -> string {
	switch {
	case strings.equal_fold(v, "ltr"): return "ltr"
	case strings.equal_fold(v, "rtl"): return "rtl"
	case strings.equal_fold(v, "auto"): return "auto"
	}
	return ""
}

Document_hasFocus :: proc(c: ^Call) -> bool { return c.page.web != nil && c.page.web.visible }

// The page is not told the URL of the document it was navigated from (the navigation's referrer stays with the
// loader): "" as for a document typed in the address bar.
Document_referrer :: proc(c: ^Call) -> string { return "" }

Document_lastModified :: proc(c: ^Call) -> string { return document_last_modified(c.page) }

Document_domain :: proc(c: ^Call) -> string {
	if c.page.env.origin.opaque { return "" }
	return c.page.env.location.host
}

Document_scrollingElement :: proc(c: ^Call) -> u64 {
	d := jd_doc(c)
	if d == nil { return 0 }
	if d.mode == .Quirks {
		b := jd_body(d)
		return u64(b)
	}
	return u64(jd_document_element(d))
}

DOMImplementation_createHTMLDocument :: proc(c: ^Call, title: Maybe(string)) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	f := dom.create_fragment(d)
	dom.get(d, f).as_document = true
	dom.append_child(d, f, dom.create_doctype(d, "html", "", ""))
	html := dom.create_element(d, "html")
	head := dom.create_element(d, "head")
	dom.append_child(d, f, html)
	dom.append_child(d, html, head)
	if t, ok := title.?; ok {
		te := dom.create_element(d, "title")
		dom.append_child(d, head, te)
		if t != "" { dom.append_child(d, te, dom.create_text(d, t)) }
	}
	dom.append_child(d, html, dom.create_element(d, "body"))
	return u64(f), .None
}

DOMImplementation_createDocumentType :: proc(c: ^Call, name: string, public_id: string, system_id: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	if !valid_element_name(name) { return 0, fail(c, .Invalid_Character, "The qualified name provided is not a valid name.") }
	return u64(dom.create_doctype(d, name, public_id, system_id)), .None
}

// The document element (0), head (1), body (2) or doctype (3) under a document node (the page's own, or one of
// createHTMLDocument).
Document_partOf :: proc(c: ^Call, document: Api_Node, which: i32) -> u64 {
	d := c.page.doc
	de := base.NIL_HANDLE
	for ch := document.data.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		k := dom.get(d, ch).kind
		if which == 3 && k == .Doctype { return u64(ch) }
		if k == .Element && de == base.NIL_HANDLE { de = ch }
	}
	switch which {
	case 0: return u64(de)
	case 1, 2:
		n := jd_node(d, de)
		if n == nil || n.name != "html" || n.ns != .HTML { return 0 }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			cn := dom.get(d, ch)
			if cn.kind != .Element || cn.ns != .HTML { continue }
			if which == 1 && cn.name == "head" { return u64(ch) }
			if which == 2 && (cn.name == "body" || cn.name == "frameset") { return u64(ch) }
		}
	}
	return 0
}

Document_set_body :: proc(c: ^Call, body: Api_Element) -> Api_Error {
	d := jd_doc(c)
	if d == nil { return no_document(c) }
	if body.data == nil || body.data.ns != .HTML || (body.data.name != "body" && body.data.name != "frameset") {
		return fail(c, .Hierarchy, "The new body element is not a <body> or <frameset>.")
	}
	old := jd_body(d)
	if old == H(body.handle) { return .None }
	if old != base.NIL_HANDLE { return replace_child(c, dom.get(d, old).parent, H(body.handle), old) }
	de := jd_document_element(d)
	if de == base.NIL_HANDLE { return fail(c, .Hierarchy, "The document has no document element.") }
	return pre_insert(c, de, H(body.handle), base.NIL_HANDLE)
}
