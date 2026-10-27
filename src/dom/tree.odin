package dom

import "core:strings"
import "wb:base"

// Tree algorithms of the DOM Standard that read the tree (order, positions, equality) or copy it (cloning). Every walk
// is iterative: a hostile page can build very deep trees.

// The node after `cur` in tree order (preorder), staying inside the subtree of `root`; NIL_HANDLE at its end.
next_in_tree :: proc(d: ^Document, cur, root: base.Handle) -> base.Handle {
	n := get(d, cur)
	if n == nil { return base.NIL_HANDLE }
	if n.first_child != base.NIL_HANDLE { return n.first_child }
	return next_skipping_children(d, cur, root)
}

// The node after the subtree of `cur` in tree order, inside `root`.
next_skipping_children :: proc(d: ^Document, cur, root: base.Handle) -> base.Handle {
	for c := cur; c != base.NIL_HANDLE && c != root; {
		n := get(d, c)
		if n == nil { return base.NIL_HANDLE }
		if n.next != base.NIL_HANDLE { return n.next }
		c = n.parent
	}
	return base.NIL_HANDLE
}

// The node before `cur` in tree order, inside `root` (root itself included); NIL_HANDLE before it.
prev_in_tree :: proc(d: ^Document, cur, root: base.Handle) -> base.Handle {
	if cur == root { return base.NIL_HANDLE }
	n := get(d, cur)
	if n == nil { return base.NIL_HANDLE }
	if n.prev == base.NIL_HANDLE { return n.parent }
	c := n.prev
	for {
		cn := get(d, c)
		if cn == nil || cn.last_child == base.NIL_HANDLE { return c }
		c = cn.last_child
	}
}

// Position of `h` among its parent's children (0-based); 0 for a parentless node.
child_index :: proc(d: ^Document, h: base.Handle) -> int {
	i := 0
	n := get(d, h)
	if n == nil { return 0 }
	for c := n.prev; c != base.NIL_HANDLE; c = get(d, c).prev { i += 1 }
	return i
}

child_count :: proc(d: ^Document, h: base.Handle) -> int {
	n := get(d, h)
	if n == nil { return 0 }
	k := 0
	for c := n.first_child; c != base.NIL_HANDLE; c = get(d, c).next { k += 1 }
	return k
}

// The child at `index`, NIL_HANDLE past the end.
child_at :: proc(d: ^Document, h: base.Handle, index: int) -> base.Handle {
	n := get(d, h)
	if n == nil || index < 0 { return base.NIL_HANDLE }
	i := 0
	for c := n.first_child; c != base.NIL_HANDLE; c = get(d, c).next {
		if i == index { return c }
		i += 1
	}
	return base.NIL_HANDLE
}

// `a` is an inclusive ancestor of `b`.
contains :: proc(d: ^Document, a, b: base.Handle) -> bool { return is_ancestor_or_self(d, a, b) }

depth_of :: proc(d: ^Document, h: base.Handle) -> int {
	k := 0
	for n := get(d, h); n != nil && n.parent != base.NIL_HANDLE; n = get(d, n.parent) { k += 1 }
	return k
}

// Tree order of two nodes of one tree: -1 when `a` comes first, 0 for the same node, 1 otherwise. Nodes of different
// trees are ordered by their roots' handles (consistent, as DOM's "implementation-specific" order asks).
tree_order_compare :: proc(d: ^Document, a, b: base.Handle) -> int {
	if a == b { return 0 }
	da, db := depth_of(d, a), depth_of(d, b)
	x, y := a, b
	for da > db { x = get(d, x).parent; da -= 1 }
	for db > da { y = get(d, y).parent; db -= 1 }
	if x == y { return a == x ? -1 : 1 }   // one is the ancestor of the other: the ancestor comes first
	for {
		nx, ny := get(d, x), get(d, y)
		if nx.parent == ny.parent {
			if nx.parent == base.NIL_HANDLE { return u64(x) < u64(y) ? -1 : 1 }   // two trees
			// siblings: which comes first
			for c := nx.next; c != base.NIL_HANDLE; c = get(d, c).next { if c == y { return -1 } }
			return 1
		}
		x, y = nx.parent, ny.parent
	}
}

// Node.compareDocumentPosition(other) of `reference` (DOM §4.4, without attributes): the bits of the standard.
POSITION_DISCONNECTED :: 0x01
POSITION_PRECEDING :: 0x02
POSITION_FOLLOWING :: 0x04
POSITION_CONTAINS :: 0x08
POSITION_CONTAINED_BY :: 0x10
POSITION_IMPLEMENTATION_SPECIFIC :: 0x20

compare_document_position :: proc(d: ^Document, reference, other: base.Handle) -> u16 {
	if reference == other { return 0 }
	if tree_root(d, reference) != tree_root(d, other) {
		return POSITION_DISCONNECTED | POSITION_IMPLEMENTATION_SPECIFIC | (u64(other) < u64(reference) ? POSITION_PRECEDING : POSITION_FOLLOWING)
	}
	if is_ancestor_or_self(d, other, reference) { return POSITION_CONTAINS | POSITION_PRECEDING }
	if is_ancestor_or_self(d, reference, other) { return POSITION_CONTAINED_BY | POSITION_FOLLOWING }
	return tree_order_compare(d, other, reference) < 0 ? POSITION_PRECEDING : POSITION_FOLLOWING
}

// A copy of a node (and of its subtree when `deep`): kind, names, namespace, attributes, data; not its listeners. The
// copy is detached (owned by whoever made it). One walk with an explicit stack copies the subtree, the contents of
// templates and the clonable shadow trees met on the way (nested templates or hosts made by a script must not
// recurse on the native stack).
clone_node :: proc(d: ^Document, h: base.Handle, deep: bool) -> base.Handle {
	if get(d, h) == nil { return base.NIL_HANDLE }
	work := make([dynamic]Clone_Work, context.temp_allocator)
	roots := make([dynamic]base.Handle, context.temp_allocator)   // shadow roots made: slots assigned at the end
	root := clone_one(d, h, &work, &roots)
	if deep { append(&work, Clone_Work{h, root}) }
	for len(work) > 0 {
		top := pop(&work)
		n := get(d, top.src)
		for c := n.first_child; c != base.NIL_HANDLE; c = get(d, c).next {
			cc := clone_one(d, c, &work, &roots)
			raw_append(d, top.dst, cc)
			if get(d, c).first_child != base.NIL_HANDLE { append(&work, Clone_Work{c, cc}) }
		}
	}
	// copied shadow roots and hosts got their children after their shadow roots: assign them now
	for r in roots {
		if ri := shadow_info(d, r); ri != nil { ri.slots_valid = false }
		assign_slottables_for_tree(d, r)
	}
	if deep && len(d.shadow_roots) > 0 {
		for cur := root; cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, root) {
			if s := get(d, cur).shadow; s != base.NIL_HANDLE && get(d, cur).kind == .Element { assign_slottables_for_tree(d, s) }
		}
	}
	return root
}

// Children of `src` to copy under `dst`.
@(private = "file")
Clone_Work :: struct { src, dst: base.Handle }

@(private = "file")
clone_one :: proc(d: ^Document, h: base.Handle, work: ^[dynamic]Clone_Work, roots: ^[dynamic]base.Handle) -> base.Handle {
	n := get(d, h)
	c := Node{kind = n.kind, ns = n.ns, xml = n.xml, name = heap_str(n.name), text = heap_str(n.text)}
	if len(n.attrs) > 0 {
		c.attrs = make([dynamic]Attr, 0, len(n.attrs))
		for a in n.attrs { append(&c.attrs, Attr{heap_str(a.name), heap_str(a.value)}) }
	}
	nh, _ := base.pool_insert(&d.nodes, c)
	if c.kind == .Element {
		if x, ok := d.ns_extra[h]; ok { d.ns_extra[nh] = Ns_Extra{uri = heap_str(x.uri), prefix = heap_str(x.prefix)} }
		if d.ids.on { for a in c.attrs { if a.name == "id" { ids_add(d, nh, a.value); break } } }
		// HTML's cloning steps of <template>: its contents are copied too
		if content, ok := d.templates[h]; ok && get(d, content) != nil && get(d, content).first_child != base.NIL_HANDLE {
			dup := create_fragment(d)
			get(d, dup).held = true
			d.templates[nh] = dup
			append(work, Clone_Work{content, dup})
		}
		// DOM "clone a node": a clonable shadow root is copied with its host, whatever `deep` says
		if src := get(d, h).shadow; src != base.NIL_HANDLE {
			if info := shadow_info(d, src); info != nil && info.clonable {
				init := info.init
				if root, err := attach_shadow(d, nh, init); err == .None {
					append(work, Clone_Work{src, root})
					append(roots, root)
				}
			}
		}
	}
	return nh
}
// Appends `child` (fresh, detached, unpinned) under a detached parent without journaling: building a copy that nobody
// observes yet.
@(private = "file")
raw_append :: proc(d: ^Document, parent, child: base.Handle) {
	p, c := get(d, parent), get(d, child)
	c.parent = parent
	c.prev = p.last_child
	if p.last_child != base.NIL_HANDLE { get(d, p.last_child).next = child } else { p.first_child = child }
	p.last_child = child
}

// Node.isEqualNode (DOM §4.4): same kind, names, namespace, attributes (in any order), data, and equal children.
is_equal_node :: proc(d: ^Document, a, b: base.Handle) -> bool {
	Pair :: struct { x, y: base.Handle }
	stack := make([dynamic]Pair, context.temp_allocator)
	append(&stack, Pair{a, b})
	for len(stack) > 0 {
		top := pop(&stack)
		x, y := get(d, top.x), get(d, top.y)
		if x == nil || y == nil { return x == y }
		if x.kind != y.kind || x.ns != y.ns || x.name != y.name || x.text != y.text || len(x.attrs) != len(y.attrs) { return false }
		if x.kind == .Element {
			px, py := ns_prefix(d, top.x), ns_prefix(d, top.y)
			if px != py || ns_uri(d, top.x) != ns_uri(d, top.y) { return false }
		}
		for ax in x.attrs {
			found := false
			for ay in y.attrs { if ay.name == ax.name { found = ay.value == ax.value; break } }
			if !found { return false }
		}
		cx, cy := x.first_child, y.first_child
		for cx != base.NIL_HANDLE && cy != base.NIL_HANDLE {
			append(&stack, Pair{cx, cy})
			cx, cy = get(d, cx).next, get(d, cy).next
		}
		if cx != cy { return false }   // different numbers of children
	}
	return true
}

// The prefix of an element ("" = none).
ns_prefix :: proc(d: ^Document, h: base.Handle) -> string {
	if x, ok := d.ns_extra[h]; ok { return x.prefix }
	return ""
}

NS_HTML :: "http://www.w3.org/1999/xhtml"
NS_SVG :: "http://www.w3.org/2000/svg"
NS_MATHML :: "http://www.w3.org/1998/Math/MathML"
NS_XML :: "http://www.w3.org/XML/1998/namespace"
NS_XMLNS :: "http://www.w3.org/2000/xmlns/"
NS_XLINK :: "http://www.w3.org/1999/xlink"

// The namespace URI of an element ("" = null).
ns_uri :: proc(d: ^Document, h: base.Handle) -> string {
	n := get(d, h)
	if n == nil || n.kind != .Element { return "" }
	switch n.ns {
	case .HTML: return NS_HTML
	case .SVG: return NS_SVG
	case .MathML: return NS_MATHML
	case .None: return ""
	case .Other: if x, ok := d.ns_extra[h]; ok { return x.uri }
	}
	return ""
}

// The namespace of a URI ("" = none).
namespace_of :: proc(uri: string) -> Namespace {
	switch uri {
	case "": return .None
	case NS_HTML: return .HTML
	case NS_SVG: return .SVG
	case NS_MATHML: return .MathML
	}
	return .Other
}

// Node.normalize (DOM §4.4): no empty Text node, no adjacent Text nodes, in the whole subtree.
normalize :: proc(d: ^Document, h: base.Handle) {
	batch := batch_begin(d)
	defer batch_end(d, batch)
	texts := make([dynamic]base.Handle, context.temp_allocator)
	for cur := next_in_tree(d, h, h); cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, h) {
		if get(d, cur).kind == .Text { append(&texts, cur) }
	}
	for t in texts {
		n := get(d, t)
		if n == nil || n.parent == base.NIL_HANDLE { continue }   // merged into a previous one already
		if len(n.text) == 0 { detach(d, t); destroy_unpinned(d, t); continue }
		// the data of the contiguous Text siblings after it joins it, they leave
		if nx := n.next; nx != base.NIL_HANDLE && get(d, nx).kind == .Text {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, n.text)
			for s := nx; s != base.NIL_HANDLE && get(d, s).kind == .Text; s = get(d, s).next { strings.write_string(&b, get(d, s).text) }
			set_data(d, t, strings.to_string(b))
			for {
				s := get(d, t).next
				if s == base.NIL_HANDLE || get(d, s).kind != .Text { break }
				detach(d, s)
				destroy_unpinned(d, s)
			}
		}
	}
}
