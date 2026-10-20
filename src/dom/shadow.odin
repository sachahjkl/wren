package dom

import "core:strings"
import "wb:base"

// Shadow trees (DOM Standard §4.2.2, §4.8 attachShadow, HTML slots).
//
// A shadow root is a Fragment node (`is_shadow`) whose `shadow` field is its host; the host's `shadow` field is its
// root. Like any root it has no parent: the node tree stays a forest of separate trees, as DOM says (a shadow tree's
// nodes are not the host's descendants, tree order and contains() stop at the root). What crosses the boundary is
// explicit: the shadow-including root and connectedness (pins.odin), the event path (events.odin), and the flat tree
// that styles and layout walk (flat_* below).
//
// Slots: the assigned nodes of each slot that has some are kept in `Document.assigned`, and each slottable knows its
// slot (`Node.slot`, `slot_pos`), so walking the flat tree costs what walking the node tree does. Assignment is
// recomputed for one shadow tree at a time ("assign slottables for a tree"), on exactly the triggers of the
// standard: a host's children inserted or removed, a `slot` attribute of a host's child, slots inserted, removed or
// renamed, attachShadow, HTMLSlotElement.assign(). A slot whose assigned nodes change is reported to the embedder
// (`Document.slot_changed`: slotchange) and journaled (`.Reslot`: its flat children changed).

Shadow_Mode :: enum u8 { Open, Closed }

Slot_Assignment :: enum u8 { Named, Manual }

Shadow_Init :: struct {
	mode:            Shadow_Mode,
	delegates_focus: bool,
	slot_assignment: Slot_Assignment,
	clonable:        bool,
	serializable:    bool,
	declarative:     bool,   // made by the HTML parser (<template shadowrootmode>)
}

Shadow_Info :: struct {
	using init:  Shadow_Init,
	available_to_internals: bool,   // ElementInternals.shadowRoot may return it
	slots:       [dynamic]base.Handle,   // the tree's slots in tree order (a cache, `slots_valid`)
	slots_valid: bool,
}

////////////////////////////////
// Hosts and roots

// The shadow root of host `h` (NIL_HANDLE when it has none).
shadow_root_of :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil || n.kind != .Element { return base.NIL_HANDLE }
	return n.shadow
}

is_shadow_root :: proc(d: ^Document, h: base.Handle) -> bool {
	n := get(d, h)
	return n != nil && n.is_shadow
}

// The host of shadow root `root` (NIL_HANDLE when it is not one).
host_of :: proc(d: ^Document, root: base.Handle) -> base.Handle {
	n := get(d, root)
	if n == nil || !n.is_shadow { return base.NIL_HANDLE }
	return n.shadow
}

shadow_info :: proc(d: ^Document, root: base.Handle) -> ^Shadow_Info {
	if info, ok := &d.shadow_roots[root]; ok { return info }
	return nil
}

// The shadow root `h` is in (the root of its tree when that is a shadow root), else NIL_HANDLE.
containing_shadow_root :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	if len(d.shadow_roots) == 0 { return base.NIL_HANDLE }
	r := tree_root(d, h)
	return is_shadow_root(d, r) ? r : base.NIL_HANDLE
}

// The root of `h`'s tree, then of its host's while that root is a shadow root (DOM "shadow-including root").
shadow_including_root :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	cur := tree_root(d, h)
	for {
		n := get(d, cur)
		if n == nil || !n.is_shadow || n.shadow == base.NIL_HANDLE { return cur }
		cur = tree_root(d, n.shadow)
	}
}

// Node.getRootNode({composed})
root_node :: proc(d: ^Document, h: base.Handle, composed: bool) -> base.Handle {
	return composed ? shadow_including_root(d, h) : tree_root(d, h)
}

// The parent of `h`, or the host when `h` is a shadow root (DOM "host-including" and "shadow-including" ancestry).
parent_or_host :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.parent == base.NIL_HANDLE && n.is_shadow { return n.shadow }
	return n.parent
}

// `a` is a shadow-including inclusive ancestor of `b` (equivalently host-including, for the trees of one document).
shadow_including_ancestor :: proc(d: ^Document, a, b: base.Handle) -> bool {
	for cur := b; cur != base.NIL_HANDLE; cur = parent_or_host(d, cur) {
		if cur == a { return true }
	}
	return false
}

host_including_ancestor :: proc(d: ^Document, a, b: base.Handle) -> bool { return shadow_including_ancestor(d, a, b) }

// DOM "retarget A against B": A, or the host of A's root, repeated while A's root is a shadow root that is not a
// shadow-including inclusive ancestor of B.
retarget :: proc(d: ^Document, a, b: base.Handle) -> base.Handle {
	cur := a
	for {
		r := tree_root(d, cur)
		rn := get(d, r)
		if rn == nil || !rn.is_shadow || shadow_including_ancestor(d, r, b) { return cur }
		cur = rn.shadow
	}
}

// The elements that may host a shadow root (DOM attachShadow step 2): HTML elements of these names, or with a valid
// custom element name.
can_host_shadow :: proc(d: ^Document, h: base.Handle) -> bool {
	n := get(d, h)
	if n == nil || n.kind != .Element || n.ns != .HTML { return false }
	switch n.name {
	case "article", "aside", "blockquote", "body", "div", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "main",
	     "nav", "p", "section", "span":
		return true
	}
	return is_valid_custom_element_name(n.name)
}

// HTML "valid custom element name": a PotentialCustomElementName (starts with a-z, has a hyphen, no ASCII upper case,
// only PCENChars) that is none of the reserved names.
is_valid_custom_element_name :: proc(name: string) -> bool {
	if len(name) == 0 || name[0] < 'a' || name[0] > 'z' { return false }
	hyphen := false
	for r in name {
		switch {
		case r == '-': hyphen = true
		case r == '.' || r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z'):
		case r == 0xB7 || (r >= 0xC0 && r <= 0xD6) || (r >= 0xD8 && r <= 0xF6) || (r >= 0xF8 && r <= 0x37D) ||
		     (r >= 0x37F && r <= 0x1FFF) || (r >= 0x200C && r <= 0x200D) || (r >= 0x203F && r <= 0x2040) ||
		     (r >= 0x2070 && r <= 0x218F) || (r >= 0x2C00 && r <= 0x2FEF) || (r >= 0x3001 && r <= 0xD7FF) ||
		     (r >= 0xF900 && r <= 0xFDCF) || (r >= 0xFDF0 && r <= 0xFFFD) || (r >= 0x10000 && r <= 0xEFFFF):
		case: return false
		}
	}
	if !hyphen { return false }
	switch name {
	case "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri", "font-face-format",
	     "font-face-name", "missing-glyph":
		return false
	}
	return true
}

// DOM "attach a shadow root". A host whose root the parser declared, with the same mode, gets that root back emptied
// (a script upgrading server-rendered markup). Errors: Invalid_Handle, Not_Supported (not a valid host, or a host
// already). The embedder checks what DOM leaves to it (custom element definitions that disable shadow roots).
attach_shadow :: proc(d: ^Document, host: base.Handle, init: Shadow_Init) -> (base.Handle, Error) {
	n := get(d, host)
	if n == nil { return base.NIL_HANDLE, .Invalid_Handle }
	if !can_host_shadow(d, host) { return base.NIL_HANDLE, .Not_Supported }
	if n.shadow != base.NIL_HANDLE {
		root := n.shadow
		info := shadow_info(d, root)
		if info == nil || !info.declarative || info.mode != init.mode { return base.NIL_HANDLE, .Not_Supported }
		batch := batch_begin(d)
		defer batch_end(d, batch)
		for {
			r := get(d, root)
			if r == nil || r.first_child == base.NIL_HANDLE { break }
			c := r.first_child
			detach(d, c)
			destroy_unpinned(d, c)
		}
		if info = shadow_info(d, root); info != nil { info.declarative = false }
		return root, .None
	}
	root, rn := base.pool_insert(&d.nodes, Node{kind = .Fragment, is_shadow = true, shadow = host})
	_ = rn
	get(d, host).shadow = root
	d.shadow_roots[root] = Shadow_Info{init = init}
	touch(d)
	d.tree_version += 1
	journal_record(d, .Reslot, host, base.NIL_HANDLE)   // its children leave the flat tree
	assign_slottables_for_tree(d, root)
	return root, .None
}

////////////////////////////////
// Slots

@(private)
is_slot :: #force_inline proc(n: ^Node) -> bool { return n.kind == .Element && n.ns == .HTML && n.name == "slot" }

// A slot's name (its `name` attribute, "" when absent).
slot_name :: proc(n: ^Node) -> string {
	for a in n.attrs { if a.name == "name" { return a.value } }
	return ""
}

// A slottable's name: an element's `slot` attribute, "" otherwise.
slottable_name :: proc(n: ^Node) -> string {
	if n.kind != .Element { return "" }
	for a in n.attrs { if a.name == "slot" { return a.value } }
	return ""
}

// The slots of shadow tree `root`, in tree order.
shadow_slots :: proc(d: ^Document, root: base.Handle) -> []base.Handle {
	info := shadow_info(d, root)
	if info == nil { return nil }
	if !info.slots_valid {
		clear(&info.slots)
		for cur := next_in_tree(d, root, root); cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, root) {
			if is_slot(get(d, cur)) { append(&info.slots, cur) }
		}
		info.slots_valid = true
	}
	return info.slots[:]
}

// The assigned nodes of `slot` (empty when none), as kept: valid until the next mutation.
assigned_nodes_raw :: proc(d: ^Document, slot: base.Handle) -> []base.Handle {
	if l, ok := d.assigned[slot]; ok { return l[:] }
	return nil
}

// HTMLSlotElement.assignedNodes({flatten}) (HTML "find flattened slottables" when flatten): with flatten, a slot
// among them (or among a slot's fallback children when it has no assigned nodes) is replaced by its own.
assigned_nodes :: proc(d: ^Document, slot: base.Handle, flatten: bool, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	if !flatten {
		append(&out, ..assigned_nodes_raw(d, slot))
		return out[:]
	}
	if containing_shadow_root(d, slot) == base.NIL_HANDLE { return out[:] }
	flatten_into :: proc(d: ^Document, slot: base.Handle, out: ^[dynamic]base.Handle, depth: int) {
		if depth > 1024 { return }
		list := assigned_nodes_raw(d, slot)
		if len(list) == 0 {
			// fallback: the slot's own slottable children
			n := get(d, slot)
			for c := n.first_child; c != base.NIL_HANDLE; c = get(d, c).next {
				cn := get(d, c)
				if cn.kind != .Element && cn.kind != .Text { continue }
				if is_slot(cn) && containing_shadow_root(d, c) != base.NIL_HANDLE { flatten_into(d, c, out, depth + 1) } else { append(out, c) }
			}
			return
		}
		for c in list {
			cn := get(d, c)
			if is_slot(cn) && containing_shadow_root(d, c) != base.NIL_HANDLE { flatten_into(d, c, out, depth + 1) } else { append(out, c) }
		}
	}
	flatten_into(d, slot, &out, 0)
	return out[:]
}

// The slot `h` is assigned to (NIL_HANDLE when none). Whether a script may see it (closed roots) is the caller's call.
assigned_slot :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	return n.slot
}

// HTMLSlotElement.assign(...nodes): the slot's manually assigned nodes become `nodes` (duplicates dropped, each one
// leaving the slot it was manually assigned to), then the tree is assigned again.
slot_assign :: proc(d: ^Document, slot: base.Handle, nodes: []base.Handle) -> Error {
	sn := get(d, slot)
	if sn == nil || !is_slot(sn) { return .Invalid_Handle }
	affected := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	if old, ok := d.manual_nodes[slot]; ok {
		for x in old { if d.manual_slot[x] == slot { delete_key(&d.manual_slot, x) } }
		delete(old)
		delete_key(&d.manual_nodes, slot)
	}
	list := make([dynamic]base.Handle)
	for x in nodes {
		if get(d, x) == nil { continue }
		dup := false
		for y in list { if y == x { dup = true; break } }
		if dup { continue }
		if prev, had := d.manual_slot[x]; had && prev != slot {
			if pl, ok := &d.manual_nodes[prev]; ok {
				for y, i in pl^ { if y == x { ordered_remove(pl, i); break } }
			}
			if r := containing_shadow_root(d, prev); r != base.NIL_HANDLE { append(&affected, r) }
		}
		d.manual_slot[x] = slot
		append(&list, x)
	}
	d.manual_nodes[slot] = list
	if r := containing_shadow_root(d, slot); r != base.NIL_HANDLE { append(&affected, r) }
	for r, i in affected {
		seen := false
		for q in affected[:i] { if q == r { seen = true; break } }
		if !seen { assign_slottables_for_tree(d, r) }
	}
	return .None
}

// DOM "assign slottables for a tree" for shadow tree `root`: the assigned nodes of each of its slots, compared with
// what they were; a slot whose list changed is signalled and journaled.
assign_slottables_for_tree :: proc(d: ^Document, root: base.Handle) {
	info := shadow_info(d, root)
	if info == nil { return }
	host := info_host(d, root)
	old_slots := make([dynamic]base.Handle, 0, len(info.slots), context.temp_allocator)
	if info.slots_valid { append(&old_slots, ..info.slots[:]) } else { for s, _ in d.assigned { if containing_root_was(d, s, root) { append(&old_slots, s) } } }
	slots := shadow_slots(d, root)
	info = shadow_info(d, root)
	// the new assigned nodes of each slot
	fresh := make(map[base.Handle][dynamic]base.Handle, len(slots), context.temp_allocator)
	hn := get(d, host)
	if hn != nil && len(slots) > 0 {
		if info.slot_assignment == .Named {
			for c := hn.first_child; c != base.NIL_HANDLE; c = get(d, c).next {
				cn := get(d, c)
				if cn.kind != .Element && cn.kind != .Text { continue }
				name := slottable_name(cn)
				for s in slots {
					if slot_name(get(d, s)) != name { continue }
					l := fresh[s]
					if l == nil { l = make([dynamic]base.Handle, context.temp_allocator) }
					append(&l, c)
					fresh[s] = l
					break
				}
			}
		} else {
			for s in slots {
				ml, ok := d.manual_nodes[s]
				if !ok { continue }
				for x in ml {
					xn := get(d, x)
					if xn == nil || xn.parent != host { continue }
					l := fresh[s]
					if l == nil { l = make([dynamic]base.Handle, context.temp_allocator) }
					append(&l, x)
					fresh[s] = l
				}
			}
		}
	}
	// compare and apply: slots that were (old list) and slots that are
	apply_slot :: proc(d: ^Document, s: base.Handle, now: []base.Handle) {
		old := assigned_nodes_raw(d, s)
		same := len(old) == len(now)
		if same { for x, i in old { if x != now[i] { same = false; break } } }
		if same { return }
		for x in old { if xn := get(d, x); xn != nil && xn.slot == s { xn.slot = base.NIL_HANDLE; xn.slot_pos = 0 } }
		if l, ok := d.assigned[s]; ok { delete(l); delete_key(&d.assigned, s) }
		if len(now) > 0 {
			l := make([dynamic]base.Handle, 0, len(now))
			for x, i in now {
				append(&l, x)
				xn := get(d, x)
				xn.slot, xn.slot_pos = s, u32(i)
			}
			d.assigned[s] = l
		}
		touch(d)
		d.tree_version += 1
		journal_record(d, .Reslot, s, base.NIL_HANDLE)
		if d.slot_changed != nil { d.slot_changed(d.slot_user, d, s) }
	}
	for s in old_slots {
		in_new := false
		for t in slots { if t == s { in_new = true; break } }
		if !in_new && get(d, s) != nil { apply_slot(d, s, nil) }
	}
	for s in slots {
		l := fresh[s]
		apply_slot(d, s, l[:])
	}
}

@(private = "file")
info_host :: proc(d: ^Document, root: base.Handle) -> base.Handle {
	n := get(d, root)
	return n != nil ? n.shadow : base.NIL_HANDLE
}

// Without a valid slot cache: whether slot `s` with assigned nodes belongs to the host of `root` (its assigned nodes
// are that host's children).
@(private = "file")
containing_root_was :: proc(d: ^Document, s: base.Handle, root: base.Handle) -> bool {
	l := assigned_nodes_raw(d, s)
	if len(l) == 0 { return false }
	xn := get(d, l[0])
	return xn != nil && xn.parent == info_host(d, root)
}

@(private = "file")
subtree_has_slot :: proc(d: ^Document, h: base.Handle) -> bool {
	if is_slot(get(d, h)) { return true }
	for cur := next_in_tree(d, h, h); cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, h) {
		if is_slot(get(d, cur)) { return true }
	}
	return false
}

// After `child` was inserted under `parent` (DOM "insert" steps for slots).
@(private)
shadow_inserted :: proc(d: ^Document, child, parent: base.Handle) {
	pn := get(d, parent)
	if pn == nil { return }
	if pn.kind == .Element && pn.shadow != base.NIL_HANDLE { assign_slottables_for_tree(d, pn.shadow) }
	root := tree_root(d, parent)
	if !is_shadow_root(d, root) { return }
	if subtree_has_slot(d, child) {
		if info := shadow_info(d, root); info != nil { info.slots_valid = false }
		assign_slottables_for_tree(d, root)
	}
	if pn = get(d, parent); pn != nil && is_slot(pn) && len(assigned_nodes_raw(d, parent)) == 0 && d.slot_changed != nil {
		d.slot_changed(d.slot_user, d, parent)   // its fallback content changed
	}
}

// After `h` left `old_parent` (DOM "remove" steps for slots).
@(private)
shadow_removed :: proc(d: ^Document, h, old_parent: base.Handle) {
	pn := get(d, old_parent)
	if pn == nil { return }
	if pn.kind == .Element && pn.shadow != base.NIL_HANDLE { assign_slottables_for_tree(d, pn.shadow) }
	root := tree_root(d, old_parent)
	if !is_shadow_root(d, root) { return }
	if subtree_has_slot(d, h) {
		if info := shadow_info(d, root); info != nil {
			// the removed slots lose their assigned nodes: they are in the cached list, not in the new one
			if !info.slots_valid { _ = shadow_slots(d, root) }
			keep := make([dynamic]base.Handle, 0, len(info.slots), context.temp_allocator)
			append(&keep, ..info.slots[:])
			info.slots_valid = false
			fresh := shadow_slots(d, root)
			for s in keep {
				gone := true
				for t in fresh { if t == s { gone = false; break } }
				if gone && len(assigned_nodes_raw(d, s)) > 0 {
					for x in assigned_nodes_raw(d, s) { if xn := get(d, x); xn != nil && xn.slot == s { xn.slot = base.NIL_HANDLE } }
					l := d.assigned[s]
					delete(l)
					delete_key(&d.assigned, s)
					touch(d)
					journal_record(d, .Reslot, s, base.NIL_HANDLE)
					if d.slot_changed != nil { d.slot_changed(d.slot_user, d, s) }
				}
			}
		}
		assign_slottables_for_tree(d, root)
	}
	if pn = get(d, old_parent); pn != nil && is_slot(pn) && len(assigned_nodes_raw(d, old_parent)) == 0 && d.slot_changed != nil {
		d.slot_changed(d.slot_user, d, old_parent)
	}
}

// After attribute `name` of `h` changed.
@(private)
shadow_attribute :: proc(d: ^Document, h: base.Handle, name: string) {
	n := get(d, h)
	if n == nil { return }
	switch name {
	case "slot":
		if pn := get(d, n.parent); pn != nil && pn.kind == .Element && pn.shadow != base.NIL_HANDLE {
			if info := shadow_info(d, pn.shadow); info != nil && info.slot_assignment == .Named { assign_slottables_for_tree(d, pn.shadow) }
		}
	case "name":
		if is_slot(n) {
			if r := containing_shadow_root(d, h); r != base.NIL_HANDLE { assign_slottables_for_tree(d, r) }
		}
	}
}

// Node `h` is being destroyed.
@(private)
shadow_forget_node :: proc(d: ^Document, h: base.Handle, n: ^Node) {
	if n.is_shadow {
		if info, ok := d.shadow_roots[h]; ok { delete(info.slots); delete_key(&d.shadow_roots, h) }
	}
	if l, ok := d.assigned[h]; ok { delete(l); delete_key(&d.assigned, h) }
	if l, ok := d.manual_nodes[h]; ok { delete(l); delete_key(&d.manual_nodes, h) }
	if _, ok := d.manual_slot[h]; ok { delete_key(&d.manual_slot, h) }
}

@(private)
shadow_free_all :: proc(d: ^Document) {
	for _, info in d.shadow_roots { delete(info.slots) }
	delete(d.shadow_roots)
	for _, l in d.assigned { delete(l) }
	delete(d.assigned)
	for _, l in d.manual_nodes { delete(l) }
	delete(d.manual_nodes)
	delete(d.manual_slot)
}

////////////////////////////////
// The flat tree (CSS Scoping §2.2): what styles and layout walk. A host's children there are its shadow root's
// children; a slot's are its assigned nodes when it has some, else its own children; a host's children that no slot
// takes, and the fallback children of a slot that has assigned nodes, are not in it. Without shadow trees it is the
// node tree, at the cost of one test per step.

has_shadow_trees :: #force_inline proc(d: ^Document) -> bool { return len(d.shadow_roots) > 0 }

flat_first_child :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.kind == .Element {
		if n.shadow != base.NIL_HANDLE { return get(d, n.shadow).first_child }
		if len(d.assigned) > 0 && len(n.name) == 4 && n.name == "slot" {
			if l, ok := d.assigned[h]; ok && len(l) > 0 { return l[0] }
		}
	}
	return n.first_child
}

flat_last_child :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.kind == .Element {
		if n.shadow != base.NIL_HANDLE { return get(d, n.shadow).last_child }
		if len(d.assigned) > 0 && len(n.name) == 4 && n.name == "slot" {
			if l, ok := d.assigned[h]; ok && len(l) > 0 { return l[len(l) - 1] }
		}
	}
	return n.last_child
}

flat_next :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.slot != base.NIL_HANDLE {
		l := d.assigned[n.slot]
		i := int(n.slot_pos) + 1
		return i < len(l) ? l[i] : base.NIL_HANDLE
	}
	return n.next
}

flat_prev :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.slot != base.NIL_HANDLE {
		if n.slot_pos == 0 { return base.NIL_HANDLE }
		l := d.assigned[n.slot]
		return l[n.slot_pos - 1]
	}
	return n.prev
}

// The parent of `h` in the flat tree; NIL_HANDLE for a root and for a node that is not in the flat tree.
flat_parent :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.slot != base.NIL_HANDLE { return n.slot }
	p := get(d, n.parent)
	if p == nil { return base.NIL_HANDLE }
	if p.is_shadow { return p.shadow }
	if p.kind == .Element {
		if p.shadow != base.NIL_HANDLE { return base.NIL_HANDLE }   // a host's child no slot takes
		if len(d.assigned) > 0 && len(p.name) == 4 && p.name == "slot" {
			if l, ok := d.assigned[n.parent]; ok && len(l) > 0 { return base.NIL_HANDLE }   // fallback not used
		}
	}
	return n.parent
}

// Whether `h` is rendered as part of the document's flat tree (its flat ancestors reach the document).
in_flat_tree :: proc(d: ^Document, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; cur = flat_parent(d, cur) {
		if cur == d.root { return true }
	}
	return false
}

// `a` is a flat-tree inclusive ancestor of `b` (:hover, :focus-within).
flat_ancestor_or_self :: proc(d: ^Document, a, b: base.Handle) -> bool {
	if len(d.shadow_roots) == 0 { return is_ancestor_or_self(d, a, b) }
	for cur := b; cur != base.NIL_HANDLE; cur = flat_parent(d, cur) {
		if cur == a { return true }
	}
	return false
}

// The node after `cur` in shadow-including tree order (an element, then its shadow tree, then its children), inside
// the shadow-including subtree of `root`.
next_shadow_including :: proc(d: ^Document, cur, root: base.Handle) -> base.Handle {
	n := get(d, cur)
	if n == nil { return base.NIL_HANDLE }
	if n.kind == .Element && n.shadow != base.NIL_HANDLE { return n.shadow }
	if n.first_child != base.NIL_HANDLE { return n.first_child }
	for c := cur; c != base.NIL_HANDLE && c != root; {
		cn := get(d, c)
		if cn == nil { return base.NIL_HANDLE }
		if cn.is_shadow && cn.parent == base.NIL_HANDLE {
			// the shadow tree is done: the host's own children come next
			host := cn.shadow
			if hn := get(d, host); hn != nil && hn.first_child != base.NIL_HANDLE { return hn.first_child }
			c = host
			continue
		}
		if cn.next != base.NIL_HANDLE { return cn.next }
		c = cn.parent
	}
	return base.NIL_HANDLE
}

// The id of an element of tree `root` (a shadow root): ShadowRoot.getElementById.
find_by_id_in_shadow :: proc(d: ^Document, root: base.Handle, id: string) -> base.Handle {
	if id == "" { return base.NIL_HANDLE }
	for cur := next_in_tree(d, root, root); cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, root) {
		n := get(d, cur)
		if n.kind != .Element { continue }
		for a in n.attrs { if a.name == "id" { if a.value == id { return cur }; break } }
	}
	return base.NIL_HANDLE
}

// The `part` names of an element (its `part` attribute's tokens), in temp memory.
part_names :: proc(n: ^Node) -> []string {
	for a in n.attrs {
		if a.name != "part" { continue }
		return strings.fields(a.value, context.temp_allocator)
	}
	return nil
}
