package dom

// Pins: how JavaScript keeps nodes alive. A script's object for a node (its wrapper) pins the node; a pinned node is
// never destroyed, in or out of the tree. Each node also counts the pins of its whole subtree (`pins_below`), kept
// exact by insertion and removal, so "can this detached tree go?" is one read of its root. A detached tree is freed when
// its last pin goes (`unpin`), or at once when it is removed and has none (`destroy_unpinned`).
//
// A shadow root belongs to its host: its pins count in the host's (and above), so a host is never freed while
// something of its shadow tree is pinned, and the shadow tree goes with its host.
//
// Nodes nobody pins keep the older rule: attached, owned by the document; detached, owned by whoever detached them
// (a Wasm module releases them with `release`).

import "wb:base"

// Adds `delta` to pins_below of `h` and all its host-including ancestors. Returns the last one (`h`'s shadow-including
// root).
pins_adjust :: proc(d: ^Document, h: base.Handle, delta: i64) -> (root: base.Handle) {
	for cur := h; cur != base.NIL_HANDLE; {
		n := get(d, cur)
		if n == nil { return }
		n.pins_below = u32(i64(n.pins_below) + delta)
		root = cur
		cur = n.parent
		if cur == base.NIL_HANDLE && n.is_shadow { cur = n.shadow }
	}
	return
}

pin :: proc(d: ^Document, h: base.Handle) -> bool {
	n := get(d, h)
	if n == nil { return false }
	n.pins += 1
	pins_adjust(d, h, 1)
	return true
}

// Drops a pin. When this leaves a detached tree with no pin at all, the tree is destroyed and its root returned (for
// the caller's bookkeeping); NIL_HANDLE otherwise.
unpin :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	n := get(d, h)
	if n == nil || n.pins == 0 { return base.NIL_HANDLE }
	n.pins -= 1
	root := pins_adjust(d, h, -1)
	if root == d.root { return base.NIL_HANDLE }
	r := get(d, root)
	if r == nil || r.pins_below > 0 || r.held { return base.NIL_HANDLE }
	destroy_subtree(d, root)
	return root
}

// The topmost ancestor of `h` (itself when detached and parentless; the document node when connected). A node of a
// shadow tree has its shadow root as root (DOM "root"); see shadow_including_root.
tree_root :: proc(d: ^Document, h: base.Handle) -> base.Handle {
	cur := h
	for {
		n := get(d, cur)
		if n == nil || n.parent == base.NIL_HANDLE { return cur }
		cur = n.parent
	}
}

// Destroys a detached subtree unless something in it is pinned (it then stays, detached, until its last pin goes).
destroy_unpinned :: proc(d: ^Document, h: base.Handle) {
	n := get(d, h)
	if n == nil || n.pins_below > 0 || n.held || n.is_shadow { return }
	destroy_subtree(d, h)
}

// Whether a node is in the document's tree or in a shadow tree whose host is (DOM "connected": its shadow-including
// root is the document).
is_connected :: proc(d: ^Document, h: base.Handle) -> bool { return shadow_including_root(d, h) == d.root }
