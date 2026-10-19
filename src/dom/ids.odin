package dom

import "core:strings"
import "wb:base"

// The id index: elements by the value of their id attribute, for getElementById, fragment navigation and the like.
// Off until the first lookup, which builds it from every element of the document (in the tree or not); from then on
// set_attribute, remove_attribute and the destruction of nodes keep it exact. Insertions and removals cost nothing
// here: a lookup filters the candidates down to those in the document's tree and takes the first in tree order (an id
// is nearly always unique, so that is one ancestor walk).

Id_Bucket :: struct {
	one:  base.Handle,           // the first element given this id (NIL when only `more` has some)
	more: [dynamic]base.Handle,  // any other
}

Id_Index :: struct {
	on:    bool,
	by_id: map[string]Id_Bucket,   // keys owned
}

@(private)
ids_destroy :: proc(d: ^Document) {
	for k, &b in d.ids.by_id { delete(k); delete(b.more) }
	delete(d.ids.by_id)
	d.ids = {}
}

@(private)
ids_add :: proc(d: ^Document, h: base.Handle, id: string) {
	if id == "" { return }
	if b, ok := &d.ids.by_id[id]; ok {
		if b.one == base.NIL_HANDLE { b.one = h } else { append(&b.more, h) }
		return
	}
	d.ids.by_id[strings.clone(id)] = Id_Bucket{one = h}
}

@(private)
ids_remove :: proc(d: ^Document, h: base.Handle, id: string) {
	if id == "" { return }
	b, ok := &d.ids.by_id[id]
	if !ok { return }
	if b.one == h {
		b.one = base.NIL_HANDLE
	} else {
		for x, i in b.more { if x == h { unordered_remove(&b.more, i); break } }
	}
	if b.one == base.NIL_HANDLE && len(b.more) > 0 { b.one = pop(&b.more) }
	if b.one == base.NIL_HANDLE {
		key, v := delete_key(&d.ids.by_id, id)
		delete(key)
		delete(v.more)
	}
}

// An element's id changed (set_attribute / remove_attribute).
@(private)
ids_changed :: proc(d: ^Document, h: base.Handle, old: string, had_old: bool, value: string, has_value: bool) {
	if !d.ids.on { return }
	if had_old { ids_remove(d, h, old) }
	if has_value { ids_add(d, h, value) }
}

// An element is destroyed.
@(private)
ids_forget_node :: proc(d: ^Document, h: base.Handle, n: ^Node) {
	if !d.ids.on { return }
	for a in n.attrs { if a.name == "id" { ids_remove(d, h, a.value); return } }
}

@(private = "file")
ids_build :: proc(d: ^Document) {
	d.ids.on = true
	d.ids.by_id = make(map[string]Id_Bucket, 64)
	it: u32
	for h, n in base.pool_next(&d.nodes, &it) {
		if n.kind != .Element { continue }
		for a in n.attrs { if a.name == "id" { ids_add(d, h, a.value); break } }
	}
}

// The first element in tree order of the document's own tree whose id is `id`; NIL_HANDLE when none.
ids_lookup :: proc(d: ^Document, id: string) -> base.Handle {
	if id == "" { return base.NIL_HANDLE }
	if !d.ids.on { ids_build(d) }
	b, ok := d.ids.by_id[id]
	if !ok { return base.NIL_HANDLE }
	best := base.NIL_HANDLE
	consider :: proc(d: ^Document, best: ^base.Handle, h: base.Handle) {
		if h == base.NIL_HANDLE || tree_root(d, h) != d.root { return }
		if best^ == base.NIL_HANDLE || tree_order_compare(d, h, best^) < 0 { best^ = h }
	}
	consider(d, &best, b.one)
	for h in b.more { consider(d, &best, h) }
	return best
}

// Every element of the document's tree whose id is `id`, in tree order (temp memory).
ids_all :: proc(d: ^Document, id: string) -> []base.Handle {
	if id == "" { return nil }
	if !d.ids.on { ids_build(d) }
	b, ok := d.ids.by_id[id]
	if !ok { return nil }
	out := make([dynamic]base.Handle, 0, 1 + len(b.more), context.temp_allocator)
	if b.one != base.NIL_HANDLE && tree_root(d, b.one) == d.root { append(&out, b.one) }
	for h in b.more { if tree_root(d, h) == d.root { append(&out, h) } }
	if len(out) > 1 {
		// insertion sort in tree order: ids are nearly always unique
		for i in 1 ..< len(out) {
			for j := i; j > 0 && tree_order_compare(d, out[j], out[j - 1]) < 0; j -= 1 { out[j], out[j - 1] = out[j - 1], out[j] }
		}
	}
	return out[:]
}

// The first element in tree order of the subtree of `root` (itself excluded) whose id is `id` (a DocumentFragment's
// or a detached element's getElementById): a walk, the index only covers the document's tree well.
find_by_id_in :: proc(d: ^Document, root: base.Handle, id: string) -> base.Handle {
	if id == "" { return base.NIL_HANDLE }
	if root == d.root { return ids_lookup(d, id) }
	for cur := next_in_tree(d, root, root); cur != base.NIL_HANDLE; cur = next_in_tree(d, cur, root) {
		n := get(d, cur)
		if n.kind != .Element { continue }
		for a in n.attrs { if a.name == "id" { if a.value == id { return cur }; break } }
	}
	return base.NIL_HANDLE
}
