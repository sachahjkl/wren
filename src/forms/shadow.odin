package forms

import "wb:base"
import "wb:dom"

// Focus with shadow trees (HTML §6.6.3, §6.6.5): delegatesFocus and the sequential navigation order of focus
// navigation scopes.
//
// A shadow host whose root delegates focus is not a focusable area itself: focusing it (focus(), a click, a label)
// focuses its focus delegate, the first focusable area of its shadow tree (an autofocus one first), unless the focus is
// in that tree already.
//
// Tab order: the document, every shadow root and every slot is a focus navigation scope. The elements of a scope are
// ordered by tabindex (positive values first, then 0 in tree order); a host stands at its place for itself (when it is
// focusable) followed by its shadow tree's order, a slot for the order of what is slotted in it. A scope owner with a
// negative tabindex takes its whole scope out of the order.

// Whether `h` is a host whose shadow root delegates focus.
delegates_focus :: proc(f: ^Forms, h: base.Handle) -> bool {
	root := dom.shadow_root_of(f.doc, h)
	if root == base.NIL_HANDLE { return false }
	info := dom.shadow_info(f.doc, root)
	return info != nil && info.delegates_focus
}

// HTML "focus delegate" of a host that delegates focus: the first focusable area of its shadow tree (in the flat
// order the user would tab through: nested hosts that delegate are followed), an `autofocus` one first. NIL: none.
focus_delegate :: proc(f: ^Forms, host: base.Handle, depth := 0) -> base.Handle {
	root := dom.shadow_root_of(f.doc, host)
	if root == base.NIL_HANDLE || depth > 64 { return base.NIL_HANDLE }
	first := base.NIL_HANDLE
	for cur := dom.next_in_tree(f.doc, root, root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(f.doc, cur, root) {
		n := element(f, cur)
		if n == nil { continue }
		cand := base.NIL_HANDLE
		if delegates_focus(f, cur) {
			cand = focus_delegate(f, cur, depth + 1)
		} else if is_focusable_area(f, cur) {
			cand = cur
		}
		if cand == base.NIL_HANDLE { continue }
		if has_attr(n, "autofocus") { return cand }
		if first == base.NIL_HANDLE { first = cand }
	}
	return first
}

// The tab order of a document with shadow trees (see the top of the file).
@(private)
tab_order_scoped :: proc(f: ^Forms, visible: proc(user: rawptr, h: base.Handle) -> bool, user: rawptr, out: ^[dynamic]base.Handle) {
	Item :: struct { h: base.Handle, ti: int, order: int }
	d := f.doc
	// the members of a scope: the elements of a tree (not entering hosts' shadow trees or slots' assigned nodes, which
	// are scopes of their own), or a slot's flattened assigned elements
	members :: proc(f: ^Forms, owner: base.Handle, is_slot: bool) -> [dynamic]base.Handle {
		d := f.doc
		list := make([dynamic]base.Handle, context.temp_allocator)
		if is_slot {
			for x in dom.assigned_nodes(d, owner, true) {
				if element(f, x) != nil { append(&list, x) }
			}
			// an element slotted here is a member with its own subtree (which is in its tree, not the slot's)
			out := make([dynamic]base.Handle, context.temp_allocator)
			for x in list {
				append(&out, x)
				collect_tree(f, x, &out)
			}
			return out
		}
		root := owner
		if n := dom.get(d, owner); n != nil && n.kind == .Element { root = dom.shadow_root_of(d, owner) }
		collect_tree(f, root, &list)
		return list
	}
	expand :: proc(f: ^Forms, owner: base.Handle, is_slot: bool, visible: proc(user: rawptr, h: base.Handle) -> bool, user: rawptr, out: ^[dynamic]base.Handle, depth: int) {
		if depth > 256 { return }
		d := f.doc
		items := make([dynamic]Item, context.temp_allocator)
		for h, i in members(f, owner, is_slot) {
			n := element(f, h)
			if n == nil { continue }
			ti, has := tabindex(n)
			if !has { ti = 0 }
			if ti < 0 { continue }
			host := n.shadow != base.NIL_HANDLE
			slot := n.ns == .HTML && n.name == "slot" && dom.containing_shadow_root(d, h) != base.NIL_HANDLE
			focusable := is_focusable_area(f, h) && (visible == nil || visible(user, h))
			if !focusable && !host && !slot { continue }
			append(&items, Item{h, ti, i})
		}
		for i in 1 ..< len(items) {
			x := items[i]
			j := i - 1
			less :: proc(a, b: Item) -> bool {
				ka := a.ti > 0 ? a.ti : max(int)
				kb := b.ti > 0 ? b.ti : max(int)
				if ka != kb { return ka < kb }
				return a.order < b.order
			}
			for j >= 0 && less(x, items[j]) { items[j + 1] = items[j]; j -= 1 }
			items[j + 1] = x
		}
		for it in items {
			n := element(f, it.h)
			if is_focusable_area(f, it.h) && (visible == nil || visible(user, it.h)) { append(out, it.h) }
			if n.shadow != base.NIL_HANDLE {
				expand(f, it.h, false, visible, user, out, depth + 1)
			} else if n.ns == .HTML && n.name == "slot" && dom.containing_shadow_root(d, it.h) != base.NIL_HANDLE {
				expand(f, it.h, true, visible, user, out, depth + 1)
			}
		}
	}
	expand(f, d.root, false, visible, user, out, 0)
}

// The elements under `root` in tree order, not entering slots (inside a shadow tree, whose assigned nodes are
// another scope) beyond the slot itself.
@(private = "file")
collect_tree :: proc(f: ^Forms, root: base.Handle, out: ^[dynamic]base.Handle) {
	d := f.doc
	for cur := dom.next_in_tree(d, root, root); cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n.kind == .Element { append(out, cur) }
		// a slot's own children are its fallback: in the tree's scope only when nothing is assigned
		if n.kind == .Element && n.ns == .HTML && n.name == "slot" && len(dom.assigned_nodes_raw(d, cur)) > 0 {
			cur = dom.next_skipping_children(d, cur, root)
			continue
		}
		cur = dom.next_in_tree(d, cur, root)
	}
}

// A focusable area itself (a host that delegates focus is not one: it hands the focus over).
@(private)
is_focusable_area :: proc(f: ^Forms, h: base.Handle) -> bool {
	if delegates_focus(f, h) { return false }
	return is_focusable_element(f, h)
}
