package a11y

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:style"

// Incremental updates of a page's tree: after the first whole tree, an update holds only the nodes that changed, each
// written whole (for platform.a11y_diff_patch), found from what the engine already records for its own incremental work:
//   * the mutation journal of the document (dom.journal_since): nodes inserted, removed, text, attributes, slots;
//   * the layout journal of the styles (style.journal_since): elements whose box may have changed (display, visibility);
//   * the forms (a hash of each control's value, checkedness, selectedness and selection);
//   * the listeners of the document (Document.listener_changes: what a click acts on);
//   * the geometry (the layout's passes, the viewport, the scroll): bounds read again from the boxes;
//   * the title, the address and the focus.
// The last tree written is kept as records (Rec): per node its DOM node, role, children, where its bounds come from.
// A change is handled at the nearest node above it (a scope): that node is walked again, but the nodes below it that
// did not change are taken as they are (their records reused, nothing written); the nodes whose name, positions or
// references may depend on the change (ancestors named by their content, list items counted, table cells indexed,
// elements that point at an id, controls named by a label) are written again one by one. Anything the journals do not
// cover (a journal that forgot, max_nodes reached, a box that went away) makes a whole tree, and Live.verify compares a
// patch with a whole tree (accessibility.page.verify).

Rec_Kind :: enum u8 { Element, Text, Run, Root }

Rec :: struct {
	parent:  u64,           // the node it hangs under (0: the root's)
	el:      base.Handle,   // its DOM node (a text run: its field)
	kind:    Rec_Kind,
	role:    Role,
	own_box: bool,          // its bounds are its own box's (else: none for an element, pb_src's box for a text)
	fixed:   bool,          // ... a box fixed to the viewport (moves with the scroll)
	click:   bool,          // it offered Click (listeners may change it)
	graft:   bool,          // a frame element grafting its document's tree (View.frame_tree)
	pb_src:  base.Handle,   // the element whose box gave the bounds it inherited (NIL: none)
	bounds:  [4]f32,        // as written
	kids:    []u64,         // its children as written (owned)
	hash:    u64,           // of the node as written (Live.hashes)
}

@(private)
Ref_Set :: struct {
	target: base.Handle,    // what the id named when last looked at
	nodes:  [dynamic]u64,   // the nodes whose computation read it
}

Live :: struct {
	recs:     map[u64]Rec,
	refs:     map[string]Ref_Set,       // ids that aria-labelledby, -describedby, -controls... name (keys owned)
	labels:   map[base.Handle]string,   // <label for> elements seen, and their for (owned)
	controls: map[base.Handle]u64,      // form controls: a hash of their state as written
	hashes:   bool,                     // keep every node's hash (verify, tests)
	hashed:   bool,                     // ... the records have them (since the last whole tree)
	// what the tree was written from
	doc:          ^dom.Document,
	forms:        ^forms.Forms,
	style_serial: u64,
	mutations:    u64,
	forms_serial: u64,
	listeners:    u64,
	geometry:     u64,
	scroll:       f32,
	head:         u64,
	fixed_count:  int,
	iframes:      map[u64]bool,   // the frame elements' nodes (whether their document can be grafted changes by itself)
	valid:        bool,
	truncated:    bool,
	// a patch being made
	patching: bool,
	emitted:  map[u64]bool,
	force:    map[u64]bool,   // nodes walked again even with a record (true: everything below them too)
	pend:     [dynamic]u64,   // nodes to write again one by one
	lost:     [dynamic]u64,   // children some node no longer has
	// statistics
	full_builds, patches, written: int,
	fallback: string,         // why the last update was a whole tree ("" when it was a patch)
}

live_destroy :: proc(l: ^Live) {
	live_clear(l)
	delete(l.recs); delete(l.refs); delete(l.labels); delete(l.controls); delete(l.iframes)
	delete(l.emitted); delete(l.force); delete(l.pend); delete(l.lost)
	l^ = {}
}

// Forgets the tree: the next update is a whole one.
live_reset :: proc(l: ^Live) { l.valid = false }

@(private)
live_clear :: proc(l: ^Live) {
	for _, r in l.recs { delete(r.kids) }
	clear(&l.recs)
	for k, s in l.refs { delete(k); delete(s.nodes) }
	clear(&l.refs)
	for _, f in l.labels { delete(f) }
	clear(&l.labels)
	clear(&l.controls)
	clear(&l.iframes)
	l.fixed_count = 0
}

// The tree of `v` into `out`: a whole tree (true: hand it to platform.a11y_diff) or the nodes changed since the last
// update (false: platform.a11y_diff_patch; it may hold no node, the focus may still have moved). `incremental` false
// always writes a whole tree.
live_update :: proc(l: ^Live, v: ^View, out: ^platform.A11y_Update, incremental := true) -> (whole: bool) {
	platform.a11y_update_clear(out)
	why := ""
	switch {
	case !incremental: why = "incremental updates are off"
	case !l.valid:     why = "no tree yet"
	case l.truncated:  why = "the document passes max_nodes"
	case l.doc != v.doc || l.forms != v.forms: why = "another document"
	case l.hashes && !l.hashed: why = "node hashes asked for"
	}
	if why == "" { why = live_patch(l, v, out) }
	if why == "" {
		l.fallback = ""
		l.patches += 1
		l.written = len(out.nodes)
		return false
	}
	platform.a11y_update_clear(out)
	live_clear(l)
	w := walk_make(v, out, l)
	build_walk(&w)
	l.truncated = w.truncated
	if v.forms != nil {
		for h in v.forms.controls { l.controls[h] = control_hash(v.forms, h) }
	}
	live_snapshot(l, v)
	l.valid = true
	l.hashed = l.hashes
	l.fallback = why
	l.full_builds += 1
	l.written = len(out.nodes)
	return true
}

// A whole tree of `v` compared with the records (Live.hashes must be on): "" when they agree, else what differs.
live_verify :: proc(l: ^Live, v: ^View) -> string {
	if !l.hashed || !l.valid { return "" }
	u: platform.A11y_Update
	defer platform.a11y_update_destroy(&u)
	build(v, &u)
	for i in 0 ..< len(u.nodes) {
		id := u.nodes[i].id
		r, ok := l.recs[id]
		if !ok { return fmt.tprintf("node %x (%v %s) missing", id, Role(u.nodes[i].role), node_tag(v.doc, base.Handle(id))) }
		if r.hash != platform.a11y_node_hash(&u, i) {
			return fmt.tprintf("node %x (%v %s) differs", id, Role(u.nodes[i].role), node_tag(v.doc, r.el))
		}
	}
	if len(u.nodes) != len(l.recs) {
		for id, r in l.recs {
			found := false
			for n in u.nodes { if n.id == id { found = true; break } }
			if !found { return fmt.tprintf("node %x (%v %s) is one too many", id, r.role, node_tag(v.doc, r.el)) }
		}
	}
	return ""
}

@(private)
node_tag :: proc(d: ^dom.Document, h: base.Handle) -> string {
	n := dom.get(d, h)
	if n == nil { return "gone" }
	if n.kind == .Text { return "#text" }
	return n.name
}

@(private)
live_snapshot :: proc(l: ^Live, v: ^View) {
	l.doc, l.forms = v.doc, v.forms
	l.mutations = v.doc.mutations
	l.style_serial = v.styled != nil ? v.styled.serial : 0
	l.forms_serial = v.forms != nil ? v.forms.serial : 0
	l.listeners = v.doc.listener_changes
	l.geometry = geometry_key(v)
	l.scroll = v.doc_scroll
	l.head = head_key(v)
}

@(private)
geometry_key :: proc(v: ^View) -> u64 {
	Key :: struct { layout: rawptr, passes: u64, valid: bool, viewport: [2]f32 }
	k := Key{layout = v.layout, viewport = v.viewport}
	if v.layout != nil {
		k.valid = v.layout.valid
		for n in v.layout.passes { k.passes += n }
	}
	return mix_bytes(0xcbf29ce484222325, mem.ptr_to_bytes(&k))
}

@(private)
head_key :: proc(v: ^View) -> u64 {
	h := mix_bytes(0xcbf29ce484222325, transmute([]u8)v.title)
	h = mix_bytes(h, transmute([]u8)v.url)
	g := [5]f32{v.viewport.x, v.viewport.y, v.origin.x, v.origin.y, v.doc_scroll}
	return mix_bytes(h, mem.ptr_to_bytes(&g))
}

@(private)
mix_bytes :: proc(h: u64, b: []u8) -> u64 {
	x := h
	for c in b { x = (x ~ u64(c)) * 0x100000001b3 }
	return x
}

// What a form control shows that the tree reads: its value, checkedness, selectedness and selection.
@(private)
control_hash :: proc(f: ^forms.Forms, h: base.Handle) -> u64 {
	n := dom.get(f.doc, h)
	if n == nil || n.kind != .Element { return 0 }
	x: u64 = 0xcbf29ce484222325
	switch n.name {
	case "input", "textarea", "select", "output":
		x = mix_bytes(x, transmute([]u8)forms.value(f, h))
	}
	b := [4]u8{}
	switch n.name {
	case "input":
		b[0] = forms.checked(f, h) ? 1 : 0
		b[1] = forms.indeterminate(f, h) ? 1 : 0
	case "option":
		b[2] = forms.option_selected(f, h) ? 1 : 0
	}
	if c := forms.control_peek(f, h); c != nil && (n.name == "input" || n.name == "textarea") {
		s := [3]int{c.sel_start, c.sel_end, int(c.sel_dir)}
		x = mix_bytes(x, mem.ptr_to_bytes(&s))
	}
	return mix_bytes(x, b[:])
}

////////////////////////////////
// Records (written by the walk, tree.odin)

// A node just written (u.nodes[index]) with its children: its record, and the children it no longer has.
@(private)
live_record :: proc(w: ^Walk, id: u64, r: Rec, kids: []u64, index: int) {
	l := w.live
	rec := r
	if r.kind == .Text && r.pb_src != base.NIL_HANDLE { _, _, rec.fixed = bounds_of(w, r.pb_src) }
	changed := true
	if old, ok := l.recs[id]; ok {
		rec.parent = old.parent
		changed = !slice.equal(old.kids, kids)
		if changed && l.patching {
			for k in old.kids { if !slice.contains(kids, k) { append(&l.lost, k) } }
		}
		if old.fixed { l.fixed_count -= 1 }
		delete(old.kids)
	}
	if rec.fixed { l.fixed_count += 1 }
	if r.role == .Iframe { l.iframes[id] = true }
	if len(kids) > 0 { rec.kids = slice.clone(kids) }
	if l.hashes && index >= 0 { rec.hash = platform.a11y_node_hash(w.u, index) }
	for k in kids { if kr, ok := &l.recs[k]; ok { kr.parent = id } }
	l.recs[id] = rec
	if !l.patching { if r.kind == .Element { refs_register(w, id, r.el) }; return }
	l.emitted[id] = true
	if r.kind == .Element { refs_register(w, id, r.el) }
	if changed && len(kids) > 0 {
		// what counts its siblings (list items "3 of 7") or its place (rows, cells) is written again
		for k in kids {
			if kr, ok := l.recs[k]; ok && positional(kr.role) { live_mark(l, k) }
		}
		#partial switch r.role { case .Table, .Grid, .Tree_Grid, .Row_Group, .Row: mark_table(l, id) }
	}
}

@(private)
positional :: proc(r: Role) -> bool {
	#partial switch r {
	case .List_Item, .List_Box_Option, .Tab, .Menu_Item, .Menu_Item_Check_Box, .Menu_Item_Radio, .Tree_Item: return true
	}
	return false
}

// The table around node `id` (or itself) and its rows and cells: written again (their counts and indices).
@(private)
mark_table :: proc(l: ^Live, id: u64) {
	t := id
	for t != 0 {
		r, ok := l.recs[t]
		if !ok { return }
		#partial switch r.role { case .Table, .Grid, .Tree_Grid: mark_table_subtree(l, t); return }
		t = r.parent
	}
}

@(private)
mark_table_subtree :: proc(l: ^Live, id: u64) {
	r, ok := l.recs[id]
	if !ok { return }
	#partial switch r.role {
	case .Table, .Grid, .Tree_Grid, .Row, .Cell, .Grid_Cell, .Column_Header, .Row_Header: live_mark(l, id)
	}
	for k in r.kids { mark_table_subtree(l, k) }
}

@(private)
REF_ATTRS :: [?]string{"aria-labelledby", "aria-describedby", "aria-controls", "aria-details", "aria-flowto", "aria-owns", "aria-activedescendant", "aria-errormessage"}

// The ids element `el` (node `id`) reads.
@(private)
refs_register :: proc(w: ^Walk, id: u64, el: base.Handle) {
	l := w.live
	n := dom.get(w.v.doc, el)
	if n == nil { return }
	for a in n.attrs {
		known := false
		for name in REF_ATTRS { if a.name == name { known = true; break } }
		if !known { continue }
		for tok in strings.fields(a.value, context.temp_allocator) {
			set, ok := &l.refs[tok]
			if !ok {
				l.refs[strings.clone(tok)] = Ref_Set{target = dom.find_by_id(w.v.doc, tok)}
				set = &l.refs[tok]
			}
			if !slice.contains(set.nodes[:], id) { append(&set.nodes, id) }
		}
	}
}

// An element met by the walk: the <label for> it is (their controls are named by them).
@(private)
live_saw_element :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node) {
	if n.name != "label" { return }
	l := w.live
	f, has := dom.get_attribute(w.v.doc, h, "for")
	old, had := l.labels[h]
	if has && had && old == f { return }
	if had {
		mark_label_target(l, w.v.doc, old)
		delete(old)
		delete_key(&l.labels, h)
	}
	if has {
		l.labels[h] = strings.clone(f)
		mark_label_target(l, w.v.doc, f)
	}
}

@(private)
mark_label_target :: proc(l: ^Live, d: ^dom.Document, for_id: string) {
	if !l.patching || for_id == "" { return }
	if t := dom.find_by_id(d, for_id); t != base.NIL_HANDLE { live_mark(l, u64(t)) }
}

@(private)
live_mark :: proc(l: ^Live, id: u64) {
	if l.patching { append(&l.pend, id) }
}

////////////////////////////////
// A patch

// The DOM parent of `h`, through a shadow root to its host.
@(private)
up :: proc(d: ^dom.Document, h: base.Handle) -> base.Handle {
	n := dom.get(d, h)
	if n == nil { return base.NIL_HANDLE }
	if n.is_shadow { return n.shadow }
	return n.parent
}

// The nearest node at or above DOM node `h` (an element's, or the root's); 0: `h` is not in the document.
@(private)
nearest :: proc(l: ^Live, d: ^dom.Document, h: base.Handle) -> u64 {
	for cur := h; cur != base.NIL_HANDLE; cur = up(d, cur) {
		if cur == d.root { return u64(d.root) }
		if r, ok := l.recs[u64(cur)]; ok && (r.kind == .Element || r.kind == .Root) { return u64(cur) }
	}
	return 0
}

// The nodes above a change, which may read it: written again (names from content, live regions), with the nodes that
// point at an id above it and the controls of a label above it.
@(private)
touch_up :: proc(l: ^Live, d: ^dom.Document, h: base.Handle) {
	for cur := h; cur != base.NIL_HANDLE; cur = up(d, cur) {
		if u64(cur) in l.recs { live_mark(l, u64(cur)) }
		if cur == d.root { return }
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { continue }
		if id, ok := dom.get_attribute(d, cur, "id"); ok && id != "" {
			if set, sok := l.refs[id]; sok { for x in set.nodes { live_mark(l, x) } }
		}
		if n.name == "label" {
			if f, ok := dom.get_attribute(d, cur, "for"); ok { mark_label_target(l, d, f) }
		}
	}
}

@(private)
Patch :: struct {
	l:      ^Live,
	v:      ^View,
	d:      ^dom.Document,
	w:      Walk,
	scopes: [dynamic]u64,
	written: map[u64]bool,   // nodes written again one by one (a scope at one of them comes too late)
}

@(private)
add_scope :: proc(p: ^Patch, id: u64) {
	if id != 0 { append(&p.scopes, id); p.l.force[id] = p.l.force[id] or_else false }
}

// A structural change under DOM node `parent`: the nearest node above is walked again, `forced` with it.
@(private)
structural :: proc(p: ^Patch, parent: base.Handle, forced := base.NIL_HANDLE, deep := false) {
	s := nearest(p.l, p.d, parent)
	if s == 0 { return }
	add_scope(p, s)
	if forced != base.NIL_HANDLE { p.l.force[u64(forced)] = deep || (p.l.force[u64(forced)] or_else false) }
}

// Whether element `h`'s record still says what it is (present, same role).
@(private)
same_role :: proc(v: ^View, h: base.Handle, n: ^dom.Node, r: Rec) -> bool {
	if n == nil || n.kind != .Element || skipped_tag(n.name) { return false }
	gone, invisible := hidden_self(&v.src, h, n)
	return !gone && element_role(&v.src, h, n, invisible) == r.role
}

@(private)
live_patch :: proc(l: ^Live, v: ^View, out: ^platform.A11y_Update) -> string {
	d := v.doc
	entries, ok := dom.journal_since(d, l.mutations)
	if !ok { return "mutation journal incomplete" }
	st := v.styled
	style_entries: []style.Journal_Entry
	if st != nil && st.serial != l.style_serial {
		if style.ps_has(st.animated, .Visibility) || style.ps_has(st.animated, .Display) { return "visibility or display animated" }
		se, sok := style.journal_since(st, l.style_serial)
		if !sok { return "style journal incomplete" }
		style_entries = se
	}
	geometry := geometry_key(v)
	head := head_key(v)
	forms_changed := v.forms != nil && v.forms.serial != l.forms_serial
	listeners_changed := d.listener_changes != l.listeners
	// frame elements whose document became ready to graft, or stopped being
	frames_changed := make([dynamic]u64, 0, 4, context.temp_allocator)
	if len(l.iframes) > 0 {
		stale := make([dynamic]u64, 0, 4, context.temp_allocator)
		for id in l.iframes {
			r, rok := l.recs[id]
			if !rok || r.role != .Iframe { append(&stale, id); continue }
			now := false
			if v.frame_tree != nil { _, now = v.frame_tree(v.frame_user, r.el) }
			if now != r.graft { append(&frames_changed, id) }
		}
		for id in stale { delete_key(&l.iframes, id) }
	}
	out.root = u64(d.root)
	defer if out.root != 0 { out.focus = focus_of(l, v) }
	if len(entries) == 0 && len(style_entries) == 0 && geometry == l.geometry && v.doc_scroll == l.scroll && head == l.head && !forms_changed && !listeners_changed && len(frames_changed) == 0 {
		live_snapshot(l, v)
		return ""
	}

	l.patching = true
	defer l.patching = false
	clear(&l.emitted); clear(&l.force); clear(&l.pend); clear(&l.lost)
	p := Patch{l = l, v = v, d = d, w = walk_make(v, out, l)}
	p.scopes = make([dynamic]u64, 0, 16, context.temp_allocator)
	p.written = make(map[u64]bool, 16, context.temp_allocator)
	p.w.reuse = true
	tree_changed := false
	for id in frames_changed { add_scope(&p, id) }

	for &e in entries {
		switch e.kind {
		case .Insert:
			tree_changed = true
			touch_up(l, d, e.parent)
			if n := dom.get(d, e.node); n != nil && inert_node(n) { continue }
			structural(&p, e.parent, e.node, deep = true)
		case .Remove:
			tree_changed = true
			touch_up(l, d, e.parent)
			structural(&p, e.parent)
		case .Text:
			if e.parent == base.NIL_HANDLE { continue }
			touch_up(l, d, e.parent)
			structural(&p, e.parent, e.node)
		case .Reslot:
			tree_changed = true
			at := e.parent != base.NIL_HANDLE ? e.parent : e.node
			touch_up(l, d, at)
			structural(&p, at, at)
		case .Attribute:
			switch e.name {
			case "class", "style": continue   // (what they change comes through the style journal)
			case "id", "for": tree_changed = true
			case "colspan", "rowspan": mark_table(l, nearest(l, d, e.node))
			}
			touch_up(l, d, e.node)
			n := dom.get(d, e.node)
			if n == nil { continue }
			if r, rok := l.recs[u64(e.node)]; rok && r.kind == .Element && same_role(v, e.node, n, r) {
				add_scope(&p, u64(e.node))
				l.force[u64(e.node)] = true
			} else {
				structural(&p, up(d, e.node), e.node, deep = true)
			}
		}
	}
	for &e in style_entries {
		if e.level < .Box { continue }   // (bounds: the geometry below)
		n := dom.get(d, e.node)
		if n == nil || n.kind != .Element { continue }
		touch_up(l, d, up(d, e.node))
		if r, rok := l.recs[u64(e.node)]; rok && r.kind == .Element && same_role(v, e.node, n, r) { continue }
		structural(&p, up(d, e.node), e.node)
	}
	if tree_changed { refs_check(l, d); labels_check(l, d) }
	if forms_changed {
		keys := make([dynamic]base.Handle, 0, len(v.forms.controls), context.temp_allocator)
		for h in v.forms.controls { append(&keys, h) }
		for h in keys {
			hv := control_hash(v.forms, h)
			if old, had := l.controls[h]; had && old == hv { continue }
			l.controls[h] = hv
			touch_up(l, d, h)
		}
		for h in l.controls { if dom.get(d, h) == nil { append(&keys, h) } }
		for h in keys { if dom.get(d, h) == nil { delete_key(&l.controls, h) } }
	}
	if listeners_changed {
		for id, r in l.recs {
			if r.kind != .Element { continue }
			n := dom.get(d, r.el)
			if n == nil { continue }
			if (clickable(&v.src, r.el, n, r.role) && !is_disabled(&v.src, r.el, n)) != r.click { live_mark(l, id) }
		}
	}
	// geometry: bounds read again (only the boxes fixed to the viewport when only the scroll moved)
	if geometry != l.geometry || (v.doc_scroll != l.scroll && l.fixed_count > 0) {
		only_fixed := geometry == l.geometry
		for id, r in l.recs {
			if only_fixed && !r.fixed { continue }
			src := base.NIL_HANDLE
			switch r.kind {
			case .Element, .Run: if r.own_box { src = r.el }
			case .Text:          src = r.pb_src
			case .Root:
			}
			if src == base.NIL_HANDLE { continue }
			b, bok, fixed := bounds_of(&p.w, src)
			if !bok || b != r.bounds || fixed != r.fixed { live_mark(l, r.kind == .Run ? u64(r.el) : id) }
		}
	}
	if head != l.head { live_mark(l, u64(d.root)) }

	for round := 0; ; round += 1 {
		if round > 8 { return "the patch did not settle" }
		if why := run_scopes(&p); why != "" { return why }
		seen := make(map[u64]bool, len(l.pend), context.temp_allocator)
		pend := slice.clone(l.pend[:], context.temp_allocator)
		clear(&l.pend)
		for id in pend {
			if seen[id] { continue }
			seen[id] = true
			if why := write_again(&p, id); why != "" { return why }
			if l.emitted[id] { p.written[id] = true }
		}
		if len(p.scopes) == 0 && len(l.pend) == 0 { break }
	}
	// the nodes no parent has any more, and everything below them
	for len(l.lost) > 0 {
		id := pop(&l.lost)
		r, rok := l.recs[id]
		if !rok || id_kept(l, id, r) { continue }
		append(&l.lost, ..r.kids)
		if r.fixed { l.fixed_count -= 1 }
		delete(r.kids)
		delete_key(&l.recs, id)
	}
	if v.max_nodes > 0 && len(l.recs) > v.max_nodes { return "the document passes max_nodes" }
	live_snapshot(l, v)
	return ""
}

// Whether the root reaches node `id` through the children as recorded now.
@(private)
reachable :: proc(l: ^Live, id: u64) -> bool {
	cur := id
	for _ in 0 ..< 4096 {
		r, ok := l.recs[cur]
		if !ok { return false }
		if r.kind == .Root { return true }
		pr, pok := l.recs[r.parent]
		if !pok || !slice.contains(pr.kids, cur) { return false }
		cur = r.parent
	}
	return false
}

// A node some parent lost is kept when its parent (now) still lists it: it moved.
@(private)
id_kept :: proc(l: ^Live, id: u64, r: Rec) -> bool {
	pr, ok := l.recs[r.parent]
	return ok && slice.contains(pr.kids, id)
}

// Nodes that never make a node of their own and take no place: comments, skipped elements.
@(private)
inert_node :: proc(n: ^dom.Node) -> bool {
	#partial switch n.kind {
	case .Element: return skipped_tag(n.name)
	case .Text:    return false
	}
	return true
}

@(private)
refs_check :: proc(l: ^Live, d: ^dom.Document) {
	empty := make([dynamic]string, context.temp_allocator)
	for key, &set in l.refs {
		if t := dom.find_by_id(d, key); t != set.target {
			set.target = t
			for x in set.nodes { live_mark(l, x) }
		}
		// (nodes gone or written again since are dropped; a node still reading the id registers again)
		k := 0
		for x in set.nodes { if x in l.recs { set.nodes[k] = x; k += 1 } }
		resize(&set.nodes, k)
		if k == 0 { append(&empty, key) }
	}
	for key in empty {
		s := l.refs[key]
		delete(s.nodes)
		k, _ := delete_key(&l.refs, key)
		delete(k)
	}
}

@(private)
labels_check :: proc(l: ^Live, d: ^dom.Document) {
	gone := make([dynamic]base.Handle, context.temp_allocator)
	for h, f in l.labels {
		now, has := dom.get_attribute(d, h, "for")
		if dom.get(d, h) == nil || !connected(d, h) || !has || now != f {
			mark_label_target(l, d, f)
			append(&gone, h)
		}
	}
	for h in gone {
		delete(l.labels[h])
		delete_key(&l.labels, h)
		// (one still in the document is met again by a walk, or here: its new target named)
		if dom.get(d, h) != nil && connected(d, h) {
			if f, ok := dom.get_attribute(d, h, "for"); ok { mark_label_target(l, d, f); l.labels[h] = strings.clone(f) }
		}
	}
}

@(private)
connected :: proc(d: ^dom.Document, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; cur = up(d, cur) { if cur == d.root { return true } }
	return false
}

@(private)
rec_depth :: proc(l: ^Live, id: u64) -> int {
	n := 0
	for cur := id; cur != 0 && n < 4096; n += 1 {
		r, ok := l.recs[cur]
		if !ok { break }
		cur = r.parent
	}
	return n
}

// Walks the scopes again, the ones nearer the root first (a walk may reach the scopes below it).
@(private)
run_scopes :: proc(p: ^Patch) -> string {
	l := p.l
	for len(p.scopes) > 0 {
		scopes := slice.clone(p.scopes[:], context.temp_allocator)
		clear(&p.scopes)
		Item :: struct { id: u64, depth: int }
		items := make([]Item, len(scopes), context.temp_allocator)
		for s, i in scopes { items[i] = {s, rec_depth(l, s)} }
		slice.sort_by(items, proc(a, b: Item) -> bool { return a.depth < b.depth })
		for it in items {
			if p.written[it.id] { return "a node changed after it was written" }
			if l.emitted[it.id] { continue }
			if why := walk_scope(p, it.id); why != "" { return why }
		}
	}
	return ""
}

@(private)
walk_scope :: proc(p: ^Patch, id: u64) -> string {
	l, d, w := p.l, p.d, &p.w
	r, ok := l.recs[id]
	if !ok { return "" }   // (gone with a scope above it)
	mark := len(w.kids)
	if r.kind == .Root {
		rn := dom.get(d, d.root)
		for c := rn.first_child; c != base.NIL_HANDLE; {
			cn := dom.get(d, c)
			if cn == nil { break }
			walk(w, c, cn, {}, base.NIL_HANDLE)
			c = cn.next
		}
		kids := slice.clone(w.kids[mark:], context.temp_allocator)
		resize(&w.kids, mark)
		emit_root(w, kids)
		return ""
	}
	if r.kind != .Element { return "" }
	n := dom.get(d, r.el)
	if !same_role(p.v, r.el, n, r) {
		// no longer the same node: its parent's children change
		structural(p, up(d, r.el), r.el)
		return ""
	}
	pb: [4]f32
	if r.pb_src != base.NIL_HANDLE {
		b, bok, _ := bounds_of(w, r.pb_src)
		if !bok && w.has_lview { return "a box went away" }
		pb = b
	}
	l.force[id] = l.force[id] or_else false
	walk(w, r.el, n, pb, r.pb_src)
	got := w.kids[mark:]
	same := len(got) == 1 && got[0] == id
	resize(&w.kids, mark)
	if !same { return "a node changed while walked again" }
	return ""
}

// Node `id` written again with the children it has.
@(private)
write_again :: proc(p: ^Patch, id: u64) -> string {
	l, d, w := p.l, p.d, &p.w
	if l.emitted[id] { return "" }
	r, ok := l.recs[id]
	if !ok { return "" }
	// (a node of a subtree taken away, not deleted yet)
	if !reachable(l, id) { return "" }
	kids := slice.clone(r.kids, context.temp_allocator)
	switch r.kind {
	case .Root:
		emit_root(w, kids)
	case .Run:
		return write_again(p, u64(r.el))
	case .Text:
		n := dom.get(d, r.el)
		pb: [4]f32
		if r.pb_src != base.NIL_HANDLE {
			b, bok, _ := bounds_of(w, r.pb_src)
			if !bok && w.has_lview { return "a box went away" }
			pb = b
		}
		if n == nil || n.kind != .Text || !emit_text(w, r.el, n, pb, r.pb_src) {
			structural(p, up(d, r.el), r.el)
		}
	case .Element:
		n := dom.get(d, r.el)
		if !same_role(p.v, r.el, n, r) {
			structural(p, up(d, r.el), r.el)
			return ""
		}
		b: [4]f32
		if r.own_box {
			bok: bool
			b, bok, _ = bounds_of(w, r.el)
			if !bok { return "a box went away" }
		}
		emit_element(w, r.el, n, r.role, kids, b, r.own_box, r.pb_src)
	}
	return ""
}

// The node the focus is on: the focused element's, or the nearest above it.
@(private)
focus_of :: proc(l: ^Live, v: ^View) -> u64 {
	d := v.doc
	if v.focus == base.NIL_HANDLE { return u64(d.root) }
	for cur := v.focus; cur != base.NIL_HANDLE; cur = up(d, cur) {
		if r, ok := l.recs[u64(cur)]; ok && r.kind == .Element { return u64(cur) }
	}
	return u64(d.root)
}
