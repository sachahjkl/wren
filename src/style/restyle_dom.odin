package style

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"

// Restyle after DOM mutations. Instead of computing every style again, the mutation journal of the document
// (dom.journal_since) says what changed since the styles were computed, and the invalidation index of the rules
// (invalidation.odin) says which elements that can affect:
//   * an inserted element: itself and its subtree; what its features reach beyond it (`h1 + p`); its parent's children
//     for positional pseudo-classes (`:nth-child`, `:last-child`...); the next sibling for `+`; the parent for :empty;
//     the anchors of :has() above it;
//   * a removed element: the parent's children (positions and sibling relations), :empty, :has() anchors;
//   * text: only :empty (and :has() over it): a text change alone restyles nothing;
//   * an attribute: the rules that test it (class tokens and ids compared old / new), `content: attr()`, inline style,
//     the attribute-driven pseudo-classes (:link, :lang, :disabled...).
// Elements are then restyled top-down in one walk that descends only where something is marked. An element whose
// style does not change keeps its record; one that changes gets a new record, a journal entry (journal.odin: Paint,
// Layout or Box), and its children are restyled when what they inherit changed (only those that inherit explicitly
// when only non-inherited values did). Large forced subtrees are shared out between the style threads.
//
// What cannot be scoped falls back to a full pass (the caller's): rules or sheets changed, the journal is incomplete,
// the root element or the root font size changes, more than `max_ratio` of the document is concerned, the dynamic
// state (:hover...) moves with the DOM, form controls whose state the forms model owns. Counters and quotes are walked
// again over the whole document when a change can reach them; records whose resolved text differs are replaced.

Restyle_Stats :: struct {
	marked:   int,      // elements restyled
	changed:  int,      // ... whose style changed
	parallel: bool,     // forced subtrees were shared out between threads
	rewalked: bool,     // counters and quotes were resolved again
	fallback: string,   // why the last restyle_dom could not be partial ("" when it was)
}

@(private = "file") M_SELF :: u8(1)
@(private = "file") M_SUB :: u8(2)
@(private = "file") M_CHILD :: u8(4)

@(private = "file")
Frame :: struct {
	h:      base.Handle,
	parent: ^Computed,
	bloom:  Bloom,
	force:  bool,   // restyle this element (its parent changed what it may take from it)
	sub:    bool,   // inside a subtree restyled whole
	ctx:    Elem_Ctx,   // the tree it is matched in (scope.odin)
}

// A changed element seen by a thread of a parallel restyle, applied on the calling thread afterwards.
@(private = "file")
Result :: struct {
	h:        base.Handle,
	old, new: ^Computed,
	level:    Change_Level,
	shown:    bool,
}

@(private = "file")
Walker :: struct {
	e:        ^Engine,
	s:        ^Styled,
	doc:      ^dom.Document,
	p:        ^Pass,
	arena:    ^virtual.Arena,   // where p allocates
	marks:    ^map[base.Handle]u8,
	// main thread: changes are applied at once; a task (parallel) records them in `results`
	task:     bool,
	results:  [dynamic]Result,
	defer_subtrees: bool,
	deferred: [dynamic]Frame,
	changed, marked: int,
	layout_changed: bool,
	rewalk:   bool,
	root_font: bool,
	motion:   bool,
}

@(private = "file")
fail :: proc(e: ^Engine, why: string) -> (bool, bool) {
	e.last_restyle.fallback = why
	return false, false
}

@(private)
connected :: proc(doc: ^dom.Document, h: base.Handle) -> bool {
	if dom.has_shadow_trees(doc) { return dom.is_connected(doc, h) }
	for cur := h; cur != base.NIL_HANDLE; {
		if cur == doc.root { return true }
		n := dom.get(doc, cur)
		if n == nil { return false }
		cur = n.parent
	}
	return false
}

@(private = "file")
is_element_node :: proc(doc: ^dom.Document, h: base.Handle) -> bool {
	n := dom.get(doc, h)
	return n != nil && n.kind == .Element
}

@(private = "file")
noninherited_set :: proc() -> Prop_Set {
	props_init()
	r: Prop_Set
	for p in Prop { if !is_inherited(p) { ps_add(&r, p) } }
	return r
}

////////////////////////////////
// Marking

@(private = "file")
Marker :: struct {
	e:     ^Engine,
	s:     ^Styled,
	doc:   ^dom.Document,
	ix:    ^Inv_Index,
	marks: map[base.Handle]u8,
	mc:    Match_Ctx,
	rewalk: bool,       // counters and quotes must be resolved again
	removed: [dynamic]base.Handle,   // removed elements still alive (their styles are dropped)
	removed_any: bool,
	fail:  string,
	// shadow trees: the pass that knows the trees' contexts (scope.odin), the invalidation index of each tree's rules,
	// and nodes that may have left the flat tree (their styles are dropped when they did)
	shadows: bool,
	p:     ^Pass,
	ixs:   map[base.Handle]^Inv_Index,
	left:  [dynamic]base.Handle,
	// Sibling walks already made in this pass. The marks are made on the DOM as it is now, so walking again from where
	// an earlier walk went through marks nothing new: 2 500 children appended to a list (or removed from it) cost one
	// walk of the children, not 2 500 (each over every child).
	walked:  map[Walk_Key]bool,   // positional walks from an element, forward or backward, per index
	emptied: map[Walk_Key]bool,   // children_removed per parent, per index
	keyed:   map[[2]u64]bool,      // (element, key set) subtrees scanned by mark_keyed
	flips:   map[Flip_Key]bool,    // has_flip answered in this pass
	exact:   bool,                 // the members of the exact anchors can be used
}

@(private = "file")
Walk_Key :: struct { h: base.Handle, ix: ^Inv_Index, dir: u8 }

@(private = "file")
mark :: proc(m: ^Marker, h: base.Handle, sub: bool, loc := #caller_location) {
	if !is_element_node(m.doc, h) { return }
	if sub && trace_restyle() && flat_parent_element(m.doc, h) == base.NIL_HANDLE { trace_roots[int(loc.line)] += 1 }
	bits := m.marks[h]
	nb := bits | (sub ? M_SUB : M_SELF)
	if nb == bits { return }
	m.marks[h] = nb
	if bits != 0 { return }   // its ancestors were flagged with it
	// the walk goes down the flat tree: so does the trail to the marked element
	if m.shadows {
		for p := flat_parent_element(m.doc, h); p != base.NIL_HANDLE; p = flat_parent_element(m.doc, p) {
			pb := m.marks[p]
			if pb & M_CHILD != 0 { break }
			m.marks[p] = pb | M_CHILD
		}
		return
	}
	for p := parent_element(&m.mc, h); p != base.NIL_HANDLE; p = parent_element(&m.mc, p) {
		pb := m.marks[p]
		if pb & M_CHILD != 0 { break }
		m.marks[p] = pb | M_CHILD
	}
}

// The invalidation index of the rules of the tree `h` is in.
@(private = "file")
ix_of :: proc(m: ^Marker, h: base.Handle) -> ^Inv_Index {
	if !m.shadows { return m.ix }
	ctx := node_ctx(m.p, h)
	if ctx.root == base.NIL_HANDLE { return m.ix }
	if ix, ok := m.ixs[ctx.root]; ok { return ix }
	ix := inv_index_of(m.e, ctx.set)
	if ix.give_up { m.fail = "selectors nested too deep" }
	m.ixs[ctx.root] = ix
	return ix
}

// Every index whose rules may test the features of element `h`: its tree's, its shadow tree's (:host rules) when it is
// a host, those of the trees of the slots it is assigned through (::slotted()).
@(private = "file")
ixs_for :: proc(m: ^Marker, h: base.Handle) -> []^Inv_Index {
	out := make([dynamic]^Inv_Index, 0, 2, context.temp_allocator)
	append(&out, ix_of(m, h))
	if !m.shadows { return out[:] }
	n := dom.get(m.doc, h)
	if n == nil { return out[:] }
	if n.kind == .Element && n.shadow != base.NIL_HANDLE { append(&out, inv_index_of(m.e, ctx_for_root(m.p, n.shadow).set)) }
	for s, hops := n.slot, 0; s != base.NIL_HANDLE && hops < 256; hops += 1 {
		append(&out, ix_of(m, s))
		sn := dom.get(m.doc, s)
		if sn == nil { break }
		s = sn.slot
	}
	return out[:]
}

// The indexes that see the position of `p`'s children: their tree's, and a host's shadow tree's (::slotted(:first-child)).
@(private = "file")
ixs_for_children :: proc(m: ^Marker, p, child: base.Handle) -> []^Inv_Index {
	out := make([dynamic]^Inv_Index, 0, 2, context.temp_allocator)
	append(&out, ix_of(m, child))
	if !m.shadows { return out[:] }
	if n := dom.get(m.doc, p); n != nil && n.kind == .Element && n.shadow != base.NIL_HANDLE {
		append(&out, inv_index_of(m.e, ctx_for_root(m.p, n.shadow).set))
	}
	return out[:]
}

@(private = "file")
next_element :: proc(m: ^Marker, h: base.Handle) -> base.Handle {
	n := dom.get(m.doc, h)
	if n == nil { return base.NIL_HANDLE }
	for cur := n.next; cur != base.NIL_HANDLE; cur = dom.get(m.doc, cur).next {
		if is_element_node(m.doc, cur) { return cur }
	}
	return base.NIL_HANDLE
}

// Marks what `r` reaches from element `h`. A whole subtree (desc, sib_desc) is restyled whole, unless the reach names its
// subject's keys (Reach.set): then only the elements of it that carry one are marked (`.a .b`: the `.b` under `.a`), which
// is all a rule can change; the rest is looked at, not restyled.
@(private = "file")
apply :: proc(m: ^Marker, h: base.Handle, r: Reach, loc := #caller_location) {
	if r.desc {
		if r.set != 0 && !m.shadows {
			if r.self { mark(m, h, false) }
			mark_keyed(m, h, r.set)
		} else {
			mark(m, h, true, loc)
		}
	} else if r.self {
		mark(m, h, false)
	}
	sibs :: proc(m: ^Marker, x: base.Handle, r: Reach) {
		if r.sib_desc && r.set != 0 && !m.shadows {
			mark(m, x, false)
			mark_keyed(m, x, r.set)
		} else {
			mark(m, x, r.sib_desc)
		}
	}
	if r.next > 0 || r.all_next {
		k := 0
		for x := next_element(m, h); x != base.NIL_HANDLE; x = next_element(m, x) {
			k += 1
			if !r.all_next && k > r.next { break }
			sibs(m, x, r)
		}
	}
	if r.all_prev {
		for x := prev_element(&m.mc, h); x != base.NIL_HANDLE; x = prev_element(&m.mc, x) { sibs(m, x, r) }
	}
}

// Marks the descendants of `h` that carry one of the keys of set `set` (their own marks only: what they pass on to their
// children, the walk finds out). The scan is made once per element and set in a pass.
@(private = "file")
mark_keyed :: proc(m: ^Marker, h: base.Handle, set: u32) {
	if m.keyed == nil { m.keyed = make(map[[2]u64]bool, 16, context.temp_allocator) }
	done := [2]u64{u64(h), u64(set)}
	if done in m.keyed { return }
	m.keyed[done] = true
	keys := key_set_keys(set)
	if len(keys) == 0 { mark(m, h, true); return }
	stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
	append(&stack, h)
	for len(stack) > 0 {
		x := pop(&stack)
		for ch := dom.flat_first_child(m.doc, x); ch != base.NIL_HANDLE; ch = dom.flat_next(m.doc, ch) {
			n := dom.get(m.doc, ch)
			if n == nil || n.kind != .Element { continue }
			if carries_key(n, keys) { mark(m, ch, false) }
			append(&stack, ch)
		}
	}
}

@(private = "file")
carries_key :: proc(n: ^dom.Node, keys: []Subject_Key) -> bool {
	for k in keys {
		switch k.kind {
		case .Type: if strings.equal_fold(n.name, k.name) { return true }
		case .Id: if v, ok := attr(n, "id"); ok && strings.equal_fold(v, k.name) { return true }
		case .Class:
			if v, ok := attr(n, "class"); ok {
				rest := v
				for len(rest) > 0 {
					for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
					end := 0
					for end < len(rest) && !is_space(rest[end]) { end += 1 }
					if end > 0 && strings.equal_fold(rest[:end], k.name) { return true }
					rest = rest[end:]
				}
			}
		}
	}
	return false
}
@(private = "file")
each_class :: proc(v: string, out: ^map[string]bool) {
	rest := v
	for len(rest) > 0 {
		for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
		end := 0
		for end < len(rest) && !is_space(rest[end]) { end += 1 }
		if end > 0 { out[rest[:end]] = true }
		rest = rest[end:]
	}
}

// Could `el` match `comp` with its :has() taken as true (an anchor whose :has() may have changed)?
@(private = "file")
anchor_could_match :: proc(mc: ^Match_Ctx, el: base.Handle, comp: css.Compound) -> bool {
	n := dom.get(mc.doc, el)
	if n == nil || n.kind != .Element { return false }
	saved := mc.ignore_state
	mc.ignore_state = true
	defer mc.ignore_state = saved
	for s in comp.simples {
		if s.kind == .Pseudo_Class && s.pseudo == .Has { continue }
		if s.kind == .Pseudo_Class && (s.pseudo == .Not || s.pseudo == .Is || s.pseudo == .Where) && s.list != nil && list_has_has(s.list^) { continue }
		if !matches_simple(mc, el, n, s) { return false }
	}
	return true
}

@(private = "file")
list_has_has :: proc(list: css.Selector_List, depth := 0) -> bool {
	if depth > 16 { return true }
	for &c in list {
		for comp in c.compounds {
			for s in comp.simples {
				if s.kind == .Pseudo_Class && s.pseudo == .Has { return true }
				if s.list != nil && list_has_has(s.list^, depth + 1) { return true }
			}
		}
	}
	return false
}

// :has() anchors whose argument may have changed because something at or under `x` did: x's ancestors (and, when
// :has() arguments use sibling combinators, the earlier siblings of x and of its ancestors). x itself when `self`.
@(private = "file")
has_invalidate :: proc(m: ^Marker, x: base.Handle, self: bool, feat := Has_Change{}) {
	ix := ix_of(m, x)
	if !ix.uses_has || len(ix.has_anchors) == 0 { return }
	feat := feat
	// the masks are of the document's watch, which only the index of the document's own rules sets up (watch_sync)
	if feat.kind == .Tree && (ix.watched != m.doc || ix.watched_gen != m.doc.journal.watch.gen) { feat.known = false }
	test :: proc(m: ^Marker, ix: ^Inv_Index, a: base.Handle, feat: Has_Change, hop: int) {
		for &ha in ix.has_anchors {
			if ha.hops >= 0 && hop > ha.hops { continue }   // (`:has(> .a)`: only the parent of the changed element)
			// a feature that changed on an element: only the anchors whose :has() tests it can be affected (a bare
			// `:not(:has(.a))` is every element's candidate: without this every class change restyled the document)
			if !has_tests(ha.feat, feat) { continue }
			if anchor_could_match(&m.mc, a, ha.compound) {
				if m.exact && ha.exact && ha.members != nil && !has_flip(m, &ha, a) { continue }
				apply(m, a, ha.reach)
			}
		}
	}
	any := false
	for &ha in ix.has_anchors { if has_tests(ha.feat, feat) { any = true; break } }
	if !any { return }
	if self { test(m, ix, x, feat, 0) }
	// the farthest level any anchor reaches: the walk up stops there
	top := 0
	for &ha in ix.has_anchors {
		if ha.hops < 0 { top = -1; break }
		top = max(top, ha.hops)
	}
	hop := 0
	for cur := x; cur != base.NIL_HANDLE; cur = parent_element(&m.mc, cur) {
		if top >= 0 && hop > top { break }
		if cur != x { test(m, ix, cur, feat, hop) }
		if ix.has_sibling {
			for ps := prev_element(&m.mc, cur); ps != base.NIL_HANDLE; ps = prev_element(&m.mc, ps) { test(m, ix, ps, feat, hop) }
		}
		hop += 1
	}
}

// What changed on an element under an anchor: a class, an id or an attribute (kind None: a change of the tree itself,
// or of anything: every anchor is concerned).
@(private = "file")
Has_Change :: struct {
	kind:  enum u8 { None, Class, Id, Attr, Tree },   // Tree: elements came or went (mask: which watched features they held; known: it was looked at)
	name:  string,
	mask:  u64,
	known: bool,
}

@(private = "file")
has_tests :: proc(f: Has_Feat, c: Has_Change) -> bool {
	switch c.kind {
	case .None: return true
	case .Tree: return !c.known || f.unkeyed || f.mask & c.mask & ~dom.WATCH_KNOWN != 0
	case .Class: return c.name in f.classes
	case .Id: return c.name in f.ids
	case .Attr: return c.name in f.attrs
	}
	return true
}

@(private = "file")
empty_changed :: proc(m: ^Marker, p: base.Handle) {
	for ix in ixs_for(m, p) {
		if reach_any(ix.empty) { apply(m, p, ix.empty) }
		if ix.has_empty { has_invalidate(m, p, false) }
	}
}

// An element was inserted under `p`, at `at`.
@(private = "file")
children_inserted :: proc(m: ^Marker, p, at: base.Handle) {
	for ix in ixs_for_children(m, p, at) {
		// a walk that reaches an element an earlier walk went through stops: the rest is the earlier one's (Marker.walked)
		if reach_any(ix.pos_fwd) {
			for x := at; x != base.NIL_HANDLE; x = next_element(m, x) {
				if walk_seen(m, x, ix, 0) { break }
				apply(m, x, ix.pos_fwd)
			}
		}
		if reach_any(ix.pos_bwd) {
			for x := at; x != base.NIL_HANDLE; x = prev_element(&m.mc, x) {
				if walk_seen(m, x, ix, 1) { break }
				apply(m, x, ix.pos_bwd)
			}
		}
		if ix.sib_any && reach_any(ix.sib_rel) {
			if nx := next_element(m, at); nx != base.NIL_HANDLE { apply(m, nx, ix.sib_rel) }
		}
	}
	if is_element_node(m.doc, p) { empty_changed(m, p) }
	has_invalidate(m, at, false, Has_Change{kind = .Tree, mask = dom.subtree_watch(m.doc, at), known = m.doc.journal.watch.on})
}

// Whether a sibling walk in direction `dir` already went through `x` in this pass; notes that one does now.
@(private = "file")
walk_seen :: proc(m: ^Marker, x: base.Handle, ix: ^Inv_Index, dir: u8) -> bool {
	key := Walk_Key{x, ix, dir}
	if key in m.walked { return true }
	m.walked[key] = true
	return false
}

// An element left `p` (where among the children is not known any more).
@(private = "file")
children_removed :: proc(m: ^Marker, p: base.Handle, mask: u64, mask_gen: u32) {
	pn := dom.get(m.doc, p)
	first := pn.first_child
	for first != base.NIL_HANDLE && !is_element_node(m.doc, first) { first = dom.get(m.doc, first).next }
	if first != base.NIL_HANDLE {
		for ix in ixs_for_children(m, p, first) {
			// the same parent again: the same walk of the same children (Marker.emptied)
			key := Walk_Key{p, ix, 2}
			if key in m.emptied { continue }
			m.emptied[key] = true
			pos := reach_union(ix.pos_fwd, ix.pos_bwd)
			if reach_any(pos) || ix.sib_any {
				every := reach_union(pos, ix.sib_rel)
				every.self = true
				for ch := pn.first_child; ch != base.NIL_HANDLE; ch = dom.get(m.doc, ch).next {
					if !is_element_node(m.doc, ch) { continue }
					apply(m, ch, every)
					if ix.sib_any { mark(m, ch, every.desc || every.sib_desc) }
				}
				pn = dom.get(m.doc, p)
			}
		}
	}
	if is_element_node(m.doc, p) { empty_changed(m, p) }
	if ix := ix_of(m, first != base.NIL_HANDLE ? first : p); ix.uses_has {
		if is_element_node(m.doc, p) { has_invalidate(m, p, true, Has_Change{kind = .Tree, mask = mask, known = mask & dom.WATCH_KNOWN != 0 && mask_gen == m.doc.journal.watch.gen}) }
		if key := (Walk_Key{p, ix, 3}); ix.has_sibling && key not_in m.emptied {
			m.emptied[key] = true
			pn = dom.get(m.doc, p)
			for ch := pn.first_child; ch != base.NIL_HANDLE; ch = dom.get(m.doc, ch).next {
				if is_element_node(m.doc, ch) { has_invalidate(m, ch, true, Has_Change{kind = .Tree, mask = mask, known = mask & dom.WATCH_KNOWN != 0 && mask_gen == m.doc.journal.watch.gen}) }
			}
		}
	}
}

// What an inserted element's own features reach beyond its subtree (which is restyled whole anyway).
@(private = "file")
inserted_features :: proc(m: ^Marker, h: base.Handle, n: ^dom.Node) {
	for ix in ixs_for(m, h) { inserted_features_of(m, ix, h, n) }
}

@(private = "file")
inserted_features_of :: proc(m: ^Marker, ix: ^Inv_Index, h: base.Handle, n: ^dom.Node) {
	r := ix.keyless
	if t, ok := ix.by_tag[n.name]; ok { r = reach_union(r, t) }
	for a in n.attrs {
		if x, ok := ix.by_attr[a.name]; ok { r = reach_union(r, x) }
		switch a.name {
		case "id": if x, ok := ix.by_id[a.value]; ok { r = reach_union(r, x) }
		case "class":
			cls := make(map[string]bool, 8, context.temp_allocator)
			each_class(a.value, &cls)
			for c in cls { if x, ok := ix.by_class[c]; ok { r = reach_union(r, x) } }
		}
	}
	r.self, r.desc = false, false
	if reach_any(r) { apply(m, h, r) }
}


@(private = "file")
FORM_RELATED :: [?]string{"form", "input", "select", "option", "optgroup", "textarea", "button", "fieldset", "datalist", "output", "label", "legend"}

// Attributes the forms model may read to answer :checked, :disabled, :valid... (and its fallbacks).
@(private = "file")
is_form_attr :: proc(name: string) -> bool {
	switch name {
	case "checked", "selected", "disabled", "readonly", "required", "type", "value", "min", "max", "step", "pattern",
	     "minlength", "maxlength", "multiple", "placeholder", "name", "form", "novalidate", "contenteditable", "open", "size":
		return true
	}
	return false
}

// Whether the rules (the document's, or a shadow tree's) ask the forms model questions about groups of controls, with a
// forms model to answer them.
@(private = "file")
control_groups_used :: proc(e: ^Engine, ix: ^Inv_Index, s: ^Styled) -> bool {
	if s.state.controls.query == nil { return false }
	if ix.uses_control_groups { return true }
	if dom_has_shadows(e) {
		for _, rs in e.shadow.of_root { if inv_index_of(e, rs).uses_control_groups { return true } }
	}
	return false
}

@(private = "file")
dom_has_shadows :: proc(e: ^Engine) -> bool { return len(e.shadow.of_root) > 0 }

@(private = "file")
legend_in :: proc(doc: ^dom.Document, h: base.Handle) -> bool {
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	append(&stack, h)
	for len(stack) > 0 {
		x := pop(&stack)
		n := dom.get(doc, x)
		if n == nil || n.kind != .Element { continue }
		if n.name == "legend" { return true }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	return false
}


// Controls that make a group across the tree: a radio button (its group is the buttons of its name under the same form owner)
// and a control owned through a form attribute (it belongs to a form elsewhere). What their coming or going changes cannot
// be found from the node alone: a full pass.
@(private = "file")
group_control :: proc(doc: ^dom.Document, h: base.Handle, n: ^dom.Node) -> bool {
	if n.name == "input" {
		if v, ok := dom.get_attribute(doc, h, "type"); ok && strings.equal_fold(strings.trim_space(v), "radio") { return true }
	}
	_, owned := dom.get_attribute(doc, h, "form")
	return owned
}

@(private = "file")
is_listed_control :: proc(name: string) -> bool {
	switch name {
	case "input", "select", "textarea", "button", "output", "fieldset", "option", "optgroup", "form": return true
	}
	return false
}

// Rules ask the forms model about groups of controls (:checked, :default, :valid...). A control that comes or goes changes,
// besides itself, what depends on all the controls of its form (the form's and its fieldsets' :valid / :invalid, which
// button is the default one) and on all the options of its select: those are restyled with what they hold (mark_form_ancestors).
// False: a radio button or a control owned through a form attribute is in `root` (group_control): the caller does a full pass.
@(private = "file")
scope_controls :: proc(m: ^Marker, root, parent: base.Handle) -> bool {
	doc := m.doc
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	append(&stack, root)
	listed := false
	for len(stack) > 0 {
		x := pop(&stack)
		n := dom.get(doc, x)
		if n == nil || n.kind != .Element { continue }
		if is_listed_control(n.name) {
			listed = true
			if group_control(doc, x, n) { return false }
		}
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	if listed { mark_form_ancestors(m, parent) }
	return true
}

// The form, fieldsets and select that hold `h` (or are it), restyled with what they hold.
@(private = "file")
mark_form_ancestors :: proc(m: ^Marker, h: base.Handle) {
	for p := h; p != base.NIL_HANDLE; {
		n := dom.get(m.doc, p)
		if n == nil { return }
		if n.kind == .Element && (n.name == "form" || n.name == "fieldset" || n.name == "select") { mark(m, p, true) }
		p = n.parent
	}
}

// Whether the document has a control that makes a group across the tree (group_control), looked for once per full pass.
@(private = "file")
groups_in_document :: proc(s: ^Styled, doc: ^dom.Document) -> bool {
	if s.forms_scan == 0 {
		s.forms_scan = 1
		stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
		append(&stack, doc.root)
		for len(stack) > 0 && s.forms_scan == 1 {
			x := pop(&stack)
			n := dom.get(doc, x)
			if n == nil { continue }
			if n.kind == .Element && is_listed_control(n.name) && group_control(doc, x, n) { s.forms_scan = 2; break }
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			if n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }
		}
	}
	return s.forms_scan == 2
}
// Some element of the subtree of `h` (styles as last computed) changes or shows counters or quotes.
@(private = "file")
subtree_feeds :: proc(s: ^Styled, doc: ^dom.Document, h: base.Handle) -> bool {
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	append(&stack, h)
	for len(stack) > 0 {
		x := pop(&stack)
		n := dom.get(doc, x)
		if n == nil || n.kind != .Element { continue }
		if c := base_style_of(s, x); c != nil && box_feeds_counters(c) { return true }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	return false
}

@(private = "file")
content_reads_attr :: proc(c: ^Computed, name: string) -> bool {
	if c == nil { return false }
	for pc in ([3]^Computed{c, c.before, c.after}) {
		if pc == nil { continue }
		for part in pc.content.parts { if part.kind == .Attr && part.text == name { return true } }
	}
	return false
}

@(private = "file")
Attr_Change :: struct { h: base.Handle, name: string, old: string, had_old: bool }

@(private = "file")
attribute_changed :: proc(m: ^Marker, ch: Attr_Change) {
	n := dom.get(m.doc, ch.h)
	h := ch.h
	if ch.name == STATE_ATTRIBUTE {
		// custom states (:state()): no value to compare, the rules that test them say what they reach
		for ix in ixs_for(m, h) {
			if r, ok := ix.by_attr[ch.name]; ok { apply(m, h, r) }
			if ch.name in ix.has_attrs { has_invalidate(m, h, false, Has_Change{kind = .Attr, name = ch.name}) }
		}
		return
	}
	cur, has_cur := attr(n, ch.name)
	if has_cur == ch.had_old && cur == ch.old { return }
	if (n.name == "style" || n.name == "link") && (!m.shadows || dom.containing_shadow_root(m.doc, h) == base.NIL_HANDLE) {
		m.fail = "stylesheet element changed"
		return
	}
	switch ch.name {
	case "part", "exportparts":
		// ::part() rules of outer trees: the element (or, through exportparts, parts deeper in its shadow tree)
		if m.shadows { mark(m, h, true) }
	}
	for ix in ixs_for(m, h) {
		attribute_changed_in(m, ix, ch, n, cur, has_cur)
		if m.fail != "" { return }
	}
	if content_reads_attr(base_style_of(m.s, h), ch.name) { mark(m, h, false) }
}

@(private = "file")
attribute_changed_in :: proc(m: ^Marker, ix: ^Inv_Index, ch: Attr_Change, n: ^dom.Node, cur: string, has_cur: bool) {
	h := ch.h
	switch ch.name {
	case "class":
		a := make(map[string]bool, 8, context.temp_allocator)
		b := make(map[string]bool, 8, context.temp_allocator)
		if ch.had_old { each_class(ch.old, &a) }
		if has_cur { each_class(cur, &b) }
		for c in a {
			if c in b { continue }
			if r, ok := ix.by_class[c]; ok { apply(m, h, r) }
			if c in ix.has_classes { has_invalidate(m, h, false, Has_Change{kind = .Class, name = c}) }
		}
		for c in b {
			if c in a { continue }
			if r, ok := ix.by_class[c]; ok { apply(m, h, r) }
			if c in ix.has_classes { has_invalidate(m, h, false, Has_Change{kind = .Class, name = c}) }
		}
	case "id":
		for v in ([2]string{ch.had_old ? ch.old : "", has_cur ? cur : ""}) {
			if v == "" { continue }
			if r, ok := ix.by_id[v]; ok { apply(m, h, r) }
			if v in ix.has_ids { has_invalidate(m, h, false, Has_Change{kind = .Id, name = v}) }
		}
	case "style":
		mark(m, h, false)
	case "start", "reversed", "value":
		if m.s.counters_used { m.rewalk = true }
	case "lang", "xml:lang":
		if m.s.counters_used { m.rewalk = true }   // quotes follow the language
	}
	if r, ok := ix.by_attr[ch.name]; ok { apply(m, h, r) }
	if ch.name in ix.has_attrs { has_invalidate(m, h, false, Has_Change{kind = .Attr, name = ch.name}) }
	if hint, subtree := hint_attribute(n.name, ch.name); hint || subtree { mark(m, h, subtree) }
	if ix.uses_controls && is_form_attr(ch.name) {
		for f in FORM_RELATED {
			if n.name != f { continue }
			// the forms model answers from groups and forms (radio groups, form validity, default button): another
			// control's state may follow (only questions of the element itself: its subtree below)
			if control_groups_used(m.e, ix, m.s) {
				// only a radio button (its group), a control owned through a form attribute, or a change of what makes it one,
				// reaches controls we cannot find; the rest reaches the form, fieldsets and select that hold it (scope_controls)
				if ch.name == "name" || ch.name == "form" || ch.name == "type" || group_control(m.doc, h, n) {
					if trace_restyle() { fmt.eprintfln("form control attribute changed: <%s %s>", n.name, ch.name) }
					m.fail = "form control attribute changed"; return
				}
				mark_form_ancestors(m, h)
			}
			apply(m, h, ix.controls)
			break
		}
	}
}

// Marks what the mutations since `s` reach. A non-empty m.fail: the change cannot be scoped.
@(private = "file")
mark_mutations :: proc(m: ^Marker, entries: []dom.Journal_Entry) {
	doc := m.doc
	ix := m.ix
	s := m.s
	// `controls`: rules ask the forms model something one control's neighbours decide (control_groups_used); with only
	// element-local questions (:disabled, :required...) a control's insertion or removal restyles its own subtree, and a
	// <legend> (the first one of a disabled fieldset enables what it holds) its parent's
	controls := control_groups_used(m.e, ix, s)
	local_controls := !controls && s.state.controls.query != nil
	in_shadow :: proc(m: ^Marker, h: base.Handle) -> bool { return m.shadows && dom.containing_shadow_root(m.doc, h) != base.NIL_HANDLE }
	structure := false
	attrs := make(map[string]Attr_Change, 16, context.temp_allocator)
	attr_order := make([dynamic]string, 0, 16, context.temp_allocator)
	for &en in entries {
		if m.fail != "" { return }
		switch en.kind {
		case .Insert:
			n := dom.get(doc, en.node)
			if n == nil { continue }   // destroyed since: nothing of it remains
			if en.parent == doc.root { m.fail = "document element changed"; return }
			if n.kind != .Element {
				if is_element_node(doc, en.parent) && connected(doc, en.parent) { empty_changed(m, en.parent) }
				continue
			}
			if !connected(doc, en.node) { continue }   // removed again since (that removal is in the journal)
			structure = true
			if controls && !scope_controls(m, en.node, n.parent) { m.fail = "form controls inserted"; return }
			if local_controls && legend_in(doc, en.node) { mark(m, n.parent, true) }
			if (n.name == "style" || n.name == "link") && !in_shadow(m, en.node) { m.fail = "stylesheet element inserted"; return }
			// moved here from elsewhere: counter values change on both sides (new elements: see settle)
			if s.counters_used && !m.rewalk && subtree_feeds(s, doc, en.node) { m.rewalk = true }
			mark(m, en.node, true)
			inserted_features(m, en.node, n)
			children_inserted(m, n.parent, en.node)
			if m.shadows { append(&m.left, en.node) }   // inserted where the flat tree does not show it: no style
		case .Remove:
			if en.parent == doc.root { m.fail = "document element changed"; return }
			n := dom.get(doc, en.node)
			was_element := n != nil ? n.kind == .Element : style_of(s, en.node) != nil
			p_ok := (is_element_node(doc, en.parent) || dom.is_shadow_root(doc, en.parent)) && connected(doc, en.parent)
			if !was_element {
				if p_ok { empty_changed(m, en.parent) }
				continue
			}
			structure = true
			m.removed_any = true
			if n == nil {
				if s.counters_used { m.rewalk = true }
				if controls {
					// what it held is gone: it may have been a control of a form or radio group still there. Only a
					// document with radio buttons or controls owned through a form attribute cares (scanned once per full
					// pass; inserting some forces one); the form, fieldsets and select around it are restyled
					if groups_in_document(s, doc) { m.fail = "element removed from a document with form controls"; return }
					if p_ok { mark_form_ancestors(m, en.parent) }
				} else if local_controls && p_ok {
					// (gone, so unknown: it may have been a fieldset's first legend)
					if pn := dom.get(doc, en.parent); pn != nil && pn.kind == .Element && pn.name == "fieldset" { mark(m, en.parent, true) }
				}
			} else {
				if !connected(doc, en.node) { append(&m.removed, en.node) } else if m.shadows { append(&m.left, en.node) }
				if s.counters_used && !m.rewalk && subtree_feeds(s, doc, en.node) { m.rewalk = true }
				if controls && p_ok && !scope_controls(m, en.node, en.parent) { m.fail = "form controls removed"; return }
				if local_controls && p_ok && legend_in(doc, en.node) { mark(m, en.parent, true) }
			}
			if p_ok { children_removed(m, en.parent, en.watch, en.watch_gen) }
		case .Text:
			n := dom.get(doc, en.node)
			p := n != nil ? n.parent : en.parent
			if !is_element_node(doc, p) || !connected(doc, p) { continue }
			if pn := dom.get(doc, p); pn.name == "style" && !in_shadow(m, p) { m.fail = "stylesheet text changed"; return }
			empty_changed(m, p)
		case .Attribute:
			if !is_element_node(doc, en.node) { continue }
			// the first entry of an attribute has its value when the styles were computed
			key := fmt.tprintf("%x:%s", u64(en.node), en.name)
			if key in attrs { continue }
			attrs[key] = Attr_Change{h = en.node, name = en.name, old = en.old, had_old = en.had_old}
			append(&attr_order, key)
		case .Reslot:
			if !connected(doc, en.node) { continue }
			structure = true
			if en.parent == base.NIL_HANDLE {
				mark(m, en.node, true)   // a slot's (or a new host's) flat children: their inheritance, ::slotted()
				// a slot's :has-slotted changed: what follows it may match through `+` / `~`
				if sn := dom.get(doc, en.node); sn != nil && sn.kind == .Element && sn.name == "slot" && in_shadow(m, en.node) {
					for sib := sn.next; sib != base.NIL_HANDLE; sib = dom.get(doc, sib).next {
						if is_element_node(doc, sib) { mark(m, sib, true) }
					}
				}
			} else {
				append(&m.left, en.node)
			}
		}
	}
	// An attribute set on an element that was put into the document in this same batch (createElement, setAttribute, appendChild: how
	// every component is built) is restyled with it: what its insertion reaches is read from the features it has now. Not so for one that
	// was taken out and put back (its old place saw the features it had then).
	fresh: map[base.Handle]struct{}
	for &en in entries {
		if en.kind == .Insert { if fresh == nil { fresh = make(map[base.Handle]struct{}, 16, context.temp_allocator) }; fresh[en.node] = {} }
	}
	for &en in entries { if en.kind == .Remove && fresh != nil { delete_key(&fresh, en.node) } }
	for k in attr_order {
		if m.fail != "" { return }
		ch := attrs[k]
		if !connected(doc, ch.h) { continue }
		if fresh != nil && in_fresh_insert(doc, &fresh, ch.h) { continue }
		attribute_changed(m, ch)
	}
	// the dynamic state moves with the tree: hovered, active or focused elements inserted or removed
	if structure && (m.e.state_deps != {} || (m.shadows && m.e.shadow.state_deps != {})) {
		for h in ([3]base.Handle{s.state.hover, s.state.active, s.state.focus}) {
			if h == base.NIL_HANDLE { continue }
			if dom.get(doc, h) == nil { m.fail = "state element removed"; return }
			for &en in entries {
				if (en.kind == .Insert || en.kind == .Remove || en.kind == .Reslot) && dom.get(doc, en.node) != nil && dom.shadow_including_ancestor(doc, en.node, h) {
					m.fail = "state element moved"
					return
				}
			}
		}
	}
}

@(private = "file")
trace_roots: map[int]int   // (WREN_RESTYLE_TRACE) the lines of restyle_dom.odin that marked the root element's whole subtree, and how often

// WREN_RESTYLE_TRACE=1: what made a restyle too big to scope, on standard error (for the measuring tools): the mutations, and the
// elements whose whole subtree was marked, the biggest first.
@(private = "file")
trace_restyle :: proc() -> bool {
	@(static) known, on: bool
	if !known { known = true; on = os.get_env("WREN_RESTYLE_TRACE", context.temp_allocator) != "" }
	return on
}

@(private = "file")
trace_marks :: proc(m: ^Marker, work: int, entries: []dom.Journal_Entry) {
	Row :: struct { h: base.Handle, size: int }
	rows := make([dynamic]Row, 0, 16, context.temp_allocator)
	for h, bits in m.marks {
		if bits & M_SUB == 0 { continue }
		size := 0
		stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
		append(&stack, h)
		for len(stack) > 0 {
			x := pop(&stack)
			size += 1
			for ch := dom.flat_first_child(m.doc, x); ch != base.NIL_HANDLE; ch = dom.flat_next(m.doc, ch) { if is_element_node(m.doc, ch) { append(&stack, ch) } }
		}
		append(&rows, Row{h, size})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.size > b.size })
	fmt.eprintfln("restyle too big: %d elements to restyle of %d, %d mutations, %d subtrees marked whole, %d shadow roots", work, m.doc.nodes.count, len(entries), len(rows), len(m.doc.shadow_roots))
	tally := make(map[string]int, 16, context.temp_allocator)
	for en in entries {
		n := dom.get(m.doc, en.node)
		tally[fmt.tprintf("%v of <%s> %s", en.kind, n != nil ? n.name : "(gone)", en.name)] += 1
	}
	for k, v in trace_roots { fmt.eprintfln("    root subtree marked by restyle_dom.odin:%d x %d", k, v) }
	clear(&trace_roots)
	fmt.eprintfln("    mutations: %s", len(tally) > 12 ? "(many kinds)" : "")
	for k, v in tally { fmt.eprintfln("      %d x %s", v, k) }
	for r, i in rows {
		if i >= 6 { break }
		n := dom.get(m.doc, r.h)
		cls, _ := dom.get_attribute(m.doc, r.h, "class")
		id, _ := dom.get_attribute(m.doc, r.h, "id")
		fmt.eprintfln("    %d elements under <%s id=%q class=%q>", r.size, n.name, id, cls[:min(len(cls), 60)])
	}
}
// Elements marked, counting whole subtrees (the work a restyle will do at least).
@(private = "file")
estimate :: proc(m: ^Marker) -> int {
	n := 0
	for h, bits in m.marks {
		if bits & (M_SELF | M_SUB) == 0 { continue }
		covered := false
		for p := flat_parent_element(m.doc, h); p != base.NIL_HANDLE; p = flat_parent_element(m.doc, p) {
			if m.marks[p] & M_SUB != 0 { covered = true; break }
		}
		if covered { continue }
		if bits & M_SUB == 0 { n += 1; continue }
		stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
		append(&stack, h)
		for len(stack) > 0 {
			x := pop(&stack)
			n += 1
			for ch := dom.flat_first_child(m.doc, x); ch != base.NIL_HANDLE; ch = dom.flat_next(m.doc, ch) {
				if is_element_node(m.doc, ch) { append(&stack, ch) }
			}
		}
	}
	return n
}

////////////////////////////////
// Restyling

// The new style `c` of `h` against the one in force: kept when equal (the old record stays), else it replaces it.
// Returns the cascaded style now in force and whether it changed.
@(private = "file")
settle :: proc(w: ^Walker, h: base.Handle, c: ^Computed) -> (cur: ^Computed, changed: bool, old_base: ^Computed) {
	s := w.s
	idx := int(base.handle_index(h))
	old := idx < len(s.by_node) ? s.by_node[idx] : nil
	if old != nil && old.node != h { old = nil }
	old_base = old
	if old != nil && len(s.overlaid) > 0 { if b, ok := s.overlaid[h]; ok { old_base = b } }
	if !counters_carry_over(s, w.doc, h, old_base, c, w.p.alloc) { w.rewalk = true }
	if (old_base == nil || !s.counters_used) && box_feeds_counters(c) { w.rewalk = true }
	if old_base != nil && computed_equal(old_base, c) && !container_changed(old_base, c) { return old_base, false, old_base }
	level := max(layout_level(old, c), Change_Level.Paint)
	if level >= .Layout { w.layout_changed = true }
	shown := old_base != nil && old_base.display == .None && c.display != .None
	if has_transitions(c) || has_animations(c) { w.motion = true }
	w.changed += 1
	if w.task {
		append(&w.results, Result{h = h, old = old, new = c, level = level, shown = shown})
		s.by_node[idx] = c   // this slot is written by this thread only; the rest is applied afterwards
		return c, true, old_base
	}
	for len(s.by_node) <= idx { append(&s.by_node, nil) }
	if s.track_changes { append(&s.changes, Style_Change{node = h, old = old, new = c}) }
	journal_add(s, h, level)
	delete_key(&s.overlaid, h)
	s.by_node[idx] = c
	if shown { append(&s.shown, h) }
	return c, true, old_base
}

// Computes the style of one element and settles it. A style equal to the one in force is dropped with all it
// allocated (nothing else points into that memory): restyles that change nothing leave nothing behind.
@(private = "file")
restyle_one :: proc(w: ^Walker, f: ^Frame, n: ^dom.Node) -> (cur: ^Computed, changed: bool, old_base: ^Computed) {
	w.marked += 1
	tmp := virtual.arena_temp_begin(w.arena)
	c := compute_element(w.p, f.h, n, f.parent, &f.bloom, f.ctx)
	cur, changed, old_base = settle(w, f.h, c)
	if changed { virtual.arena_temp_ignore(tmp) } else { virtual.arena_temp_end(tmp) }
	return
}

@(private = "file")
walk :: proc(w: ^Walker, start: []Frame) {
	doc := w.doc
	s := w.s
	noninh := noninherited_set()
	stack := make([dynamic]Frame, 0, 64, context.temp_allocator)
	for i := len(start) - 1; i >= 0; i -= 1 { append(&stack, start[i]) }
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		bits := w.marks^[f.h] if w.marks != nil else 0
		sub := f.sub || bits & M_SUB != 0
		cur := base_style_of(s, f.h)
		inh_changed, other_changed := false, false
		if f.force || sub || bits & M_SELF != 0 {
			// (never the root element: the root font size and line height are checked below, on this thread)
			if w.defer_subtrees && sub && !f.sub && f.parent != nil {
				append(&w.deferred, Frame{h = f.h, parent = f.parent, bloom = f.bloom, force = true, sub = true, ctx = f.ctx})
				continue
			}
			nc, changed, old := restyle_one(w, &f, n)
			if changed {
				if old == nil || !inherited_equal(old, nc) || container_changed(old, nc) { inh_changed = true } else { other_changed = true }
				if f.parent == nil && (nc.font_size != s.root_font_size || used_line_height(nc, s.line_height_normal) != s.root_line_height) { w.root_font = true }
			}
			cur = nc
		}
		if !sub && !inh_changed && !other_changed && bits & M_CHILD == 0 { continue }
		if cur == nil { continue }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		for ch := dom.flat_last_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_prev(doc, ch) {
			cn := dom.get(doc, ch)
			if cn.kind != .Element { continue }
			cb := w.marks^[ch] if w.marks != nil else 0
			force := sub || inh_changed
			if !force && other_changed {
				// only non-inherited values changed: what takes them explicitly (`inherit`) follows
				co := base_style_of(s, ch)
				force = co == nil || !ps_empty(ps_intersect(co.inherits, noninh))
			}
			if force || cb != 0 { append(&stack, Frame{h = ch, parent = cur, bloom = child_bloom, force = force, sub = sub, ctx = child_ctx(w.p, f.h, f.ctx, ch)}) }
		}
	}
}

@(private = "file")
Par_Task :: struct {
	w:      Walker,
	frames: []Frame,
	arena:  ^virtual.Arena,
}

@(private = "file")
Par_Tasks :: struct {
	tasks: []Par_Task,
}

// Forced subtrees deferred by the walk, shared out between the threads of `pool`. Their tops are expanded breadth
// first on this thread until there are enough to go round.
@(private = "file")
run_deferred :: proc(w: ^Walker, pool: ^host.Thread_Pool) {
	if len(w.deferred) == 0 { return }
	doc := w.doc
	s := w.s
	threads := host.thread_pool_size(pool)
	frontier := w.deferred
	w.defer_subtrees = false
	for depth := 0; len(frontier) > 0 && len(frontier) < threads * 8 && depth < 16; depth += 1 {
		next := make([dynamic]Frame, 0, len(frontier) * 4, context.temp_allocator)
		for &f in frontier {
			n := dom.get(doc, f.h)
			if n == nil || n.kind != .Element { continue }
			nc, _, _ := restyle_one(w, &f, n)
			child_bloom := f.bloom
			bloom_add_element(&child_bloom, n)
			for ch := dom.flat_first_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
				if is_element_node(doc, ch) { append(&next, Frame{h = ch, parent = nc, bloom = child_bloom, force = true, sub = true, ctx = child_ctx(w.p, f.h, f.ctx, ch)}) }
			}
		}
		frontier = next
	}
	if len(frontier) == 0 { return }
	// every slot a thread may write exists beforehand: the array does not move while they run
	if len(s.by_node) < int(doc.nodes.used) { resize(&s.by_node, int(doc.nodes.used)) }
	count := min(len(frontier), threads * 4)
	job := Par_Tasks{tasks = make([]Par_Task, count, context.temp_allocator)}
	for i in 0 ..< count {
		t := &job.tasks[i]
		t.frames = frontier[i * len(frontier) / count:(i + 1) * len(frontier) / count]
		t.w = Walker{e = w.e, s = s, doc = doc, task = true}
	}
	host.parallel_for(pool, count, proc(data: rawptr, i: int) {
		job := (^Par_Tasks)(data)
		t := &job.tasks[i]
		t.arena = new(virtual.Arena)
		_ = virtual.arena_init_growing(t.arena)
		t.w.p = pass_make(t.w.e, t.w.s, t.w.doc, t.w.s.state)
		t.w.p.alloc = virtual.arena_allocator(t.arena)
		t.w.arena = t.arena
		t.w.results = make([dynamic]Result)
		walk(&t.w, t.frames)
	}, &job)
	w.e.last_restyle.parallel = true
	for &t in job.tasks {
		append(&s.thread_arenas, t.arena)
		s.partial_bytes += int(t.arena.total_used)
		pass_destroy(t.w.p)
		for r in t.w.results {
			if s.track_changes { append(&s.changes, Style_Change{node = r.h, old = r.old, new = r.new}) }
			journal_add(s, r.h, r.level)
			delete_key(&s.overlaid, r.h)
			if r.shown { append(&s.shown, r.h) }
		}
		delete(t.w.results)
		w.marked += t.w.marked
		w.changed += t.w.changed
		w.layout_changed ||= t.w.layout_changed
		w.rewalk ||= t.w.rewalk
		w.root_font ||= t.w.root_font
		w.motion ||= t.w.motion
	}
}

// Restyles what the DOM mutations since `s` was computed can affect, in place. ok = false: the change cannot be
// scoped (e.last_restyle.fallback says why) and nothing was changed; the caller does a full pass. `changed`: some
// computed style differs (s.serial changed then).
restyle_dom :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, pool: ^host.Thread_Pool = nil) -> (changed: bool, ok: bool) {
	e.last_restyle = {}
	shadows := dom.has_shadow_trees(doc)
	if e.dirty { return fail(e, "rules changed") }
	if s.mutations == doc.mutations && !e.shadow.dirty && len(e.shadow.changed) == 0 { return false, true }
	if !e.settings.inc_enabled { return fail(e, "disabled") }
	// the rule sets of shadow trees whose sheets changed: their hosts are restyled with their flat subtrees
	if e.shadow.dirty { scopes_resolve(e, doc) }
	if shadows { _ = shadow_set_of(e, base.NIL_HANDLE) }
	entries, jok := dom.journal_since(doc, s.mutations)
	if !jok { return fail(e, "mutation journal incomplete") }
	if meta_scheme_changed(doc, s, entries) { return fail(e, "page color scheme changed") }   // the root's color-scheme, then everything
	if int(s.arena.total_used) - int(s.base_used) + s.partial_bytes > e.settings.restyle_waste_bytes { return fail(e, "memory left by partial restyles") }
	ix := inv_index(e)
	if ix.give_up { return fail(e, "selectors nested too deep") }
	exact := false   // the members of the exact :has() anchors are of the document before these mutations (watch_sync was made by a pass that came before)
	if !shadows && ix.uses_has { exact = !watch_sync(ix, doc) }

	m := Marker{e = e, s = s, doc = doc, ix = ix, shadows = shadows}
	m.marks = make(map[base.Handle]u8, 64, context.temp_allocator)
	m.removed = make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	m.walked = make(map[Walk_Key]bool, 16, context.temp_allocator)
	m.emptied = make(map[Walk_Key]bool, 4, context.temp_allocator)
	m.flips = make(map[Flip_Key]bool, 16, context.temp_allocator)
	match_ctx_init(&m.mc, doc, s.state, context.temp_allocator)
	w := Walker{e = e, s = s, doc = doc, marks = &m.marks}
	w.p = pass_make(e, s, doc, s.state)
	w.arena = &s.arena
	defer pass_destroy(w.p)
	if shadows {
		m.p = w.p
		m.ixs = make(map[base.Handle]^Inv_Index, 8, context.temp_allocator)
		m.left = make([dynamic]base.Handle, 0, 4, context.temp_allocator)
		for root in e.shadow.changed {
			if host := dom.host_of(doc, root); host != base.NIL_HANDLE && connected(doc, host) { mark(&m, host, true) }
		}
	}
	clear(&e.shadow.changed)
	m.exact = exact
	members_prepare(&m, entries)
	mark_mutations(&m, entries)
	if m.fail != "" { return fail(e, m.fail) }
	work := estimate(&m)
	if f64(work) > f64(e.settings.inc_max_ratio) * f64(max(doc.nodes.count, 1)) {
		if trace_restyle() { trace_marks(&m, work, entries) }
		return fail(e, "too much changed")
	}

	// from here on the styles change
	for h in m.removed {
		// a full pass would not have them: drop their records (and their animations, see timeline_restyled_dom)
		stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
		append(&stack, h)
		for len(stack) > 0 {
			x := pop(&stack)
			n := dom.get(doc, x)
			if n == nil || n.kind != .Element { continue }
			idx := int(base.handle_index(x))
			if idx < len(s.by_node) && s.by_node[idx] != nil && s.by_node[idx].node == x {
				s.by_node[idx] = nil
				delete_key(&s.overlaid, x)
			}
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			if n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }
		}
	}
	if m.removed_any { s.removed_any = true }

	w.defer_subtrees = pool != nil && host.thread_pool_size(pool) > 1 && work >= e.settings.inc_parallel_min
	if len(m.marks) > 0 {
		start := make([dynamic]Frame, 0, 4, context.temp_allocator)
		root := dom.get(doc, doc.root)
		for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
			if m.marks[ch] != 0 { append(&start, Frame{h = ch}) }
		}
		walk(&w, start[:])
		run_deferred(&w, pool)
		delete(w.deferred)
	}
	// nodes that left the flat tree (unassigned, hidden fallback, inserted where no slot takes them): a full pass would
	// not style them
	for h in m.left {
		if dom.get(doc, h) == nil || dom.in_flat_tree(doc, h) { continue }
		stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
		append(&stack, h)
		for len(stack) > 0 {
			x := pop(&stack)
			n := dom.get(doc, x)
			if n == nil { continue }
			if n.kind == .Element {
				idx := int(base.handle_index(x))
				if idx < len(s.by_node) && s.by_node[idx] != nil && s.by_node[idx].node == x {
					s.by_node[idx] = nil
					delete_key(&s.overlaid, x)
					w.changed += 1
					w.layout_changed = true
					s.removed_any = true
				}
				if n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }
			}
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
		}
	}
	if w.root_font { s.root_font_size = 0 }   // see below: the caller's full pass sets it again
	rewalked := false
	if m.rewalk || w.rewalk {
		if counters_refresh(s, doc, e.settings.counters_max_listed) { w.changed += 1; w.layout_changed = true }
		rewalked = true
	}
	if w.motion { sync.atomic_store(&s.motion, true) }
	s.mutations = doc.mutations
	e.last_restyle.marked = w.marked
	e.last_restyle.changed = w.changed
	e.last_restyle.rewalked = rewalked
	if w.root_font {
		// rem lengths everywhere follow the root's font size: only a full pass gets them right; what was done is
		// harmless (records replaced as a full pass would), and the caller now does one
		s.mutations = 0
		e.last_restyle.fallback = "root font size changed"
		return w.changed > 0, false
	}
	if w.changed > 0 {
		styled_serial += 1
		s.serial = styled_serial
		if w.layout_changed { s.layout_serial = s.serial }
		journal_stamp(s)
		update_canvas(s, doc)
	}
	return w.changed > 0, true
}

////////////////////////////////
// Counters and quotes again

// Resolves counters and quotes over the whole document, as a full pass does, and replaces the records whose resolved
// text (marker, generated content) differs. Returns whether any did.
@(private)
counters_refresh :: proc(s: ^Styled, doc: ^dom.Document, max_listed: int) -> bool {
	Saved :: struct { marker: string, items: [3][]Content_Item }
	save :: proc(c: ^Computed) -> (sv: Saved) {
		sv.marker = c.marker_text
		sv.items[0] = c.content.items
		if c.before != nil { sv.items[1] = c.before.content.items }
		if c.after != nil { sv.items[2] = c.after.content.items }
		return
	}
	// what a fresh record has before counters are resolved (resolve_static leaves some of them untouched)
	blank :: proc(c: ^Computed, after: bool) {
		if !after {
			c.marker_text = ""
			c.content.items = nil
			if c.before != nil { c.before.content.items = nil }
		}
		if c.after != nil { c.after.content.items = nil }
	}
	restore :: proc(c: ^Computed, sv: Saved) {
		c.marker_text = sv.marker
		c.content.items = sv.items[0]
		if c.before != nil { c.before.content.items = sv.items[1] }
		if c.after != nil { c.after.content.items = sv.items[2] }
	}
	items_equal :: proc(a, b: []Content_Item) -> bool {
		if len(a) != len(b) { return false }
		for i in 0 ..< len(a) { if a[i].kind != b[i].kind || a[i].text != b[i].text { return false } }
		return true
	}
	clone_items :: proc(x: []Content_Item, alloc: runtime.Allocator) -> []Content_Item {
		out := make([]Content_Item, len(x), alloc)
		for it, i in x { out[i] = it; out[i].text = strings.clone(it.text, alloc) }
		return out
	}
	// the record of `h` with the resolved values `now` (a copy when they differ from what it has)
	apply_values :: proc(s: ^Styled, h: base.Handle, c: ^Computed, sv, now: Saved) -> bool {
		same := sv.marker == now.marker
		for k in 0 ..< 3 { if !items_equal(sv.items[k], now.items[k]) { same = false } }
		if same { return false }
		a := s.alloc
		nc := new(Computed, a)
		nc^ = c^
		nc.marker_text = strings.clone(now.marker, a)
		nc.content.items = clone_items(now.items[0], a)
		if c.before != nil { nb := new(Computed, a); nb^ = c.before^; nb.content.items = clone_items(now.items[1], a); nc.before = nb }
		if c.after != nil { na := new(Computed, a); na^ = c.after^; na.content.items = clone_items(now.items[2], a); nc.after = na }
		idx := int(base.handle_index(h))
		old := s.by_node[idx]
		if s.track_changes { append(&s.changes, Style_Change{node = h, old = old, new = nc}) }
		journal_add(s, h, .Box)
		delete_key(&s.overlaid, h)
		s.by_node[idx] = nc
		return true
	}
	counters := counter_state_make(max_listed)
	changed := false
	F :: struct { h: base.Handle, hidden: bool, exit: bool }
	stack := make([dynamic]F, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for ch := root.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, F{h = ch}) }
	tmp := context.temp_allocator
	for len(stack) > 0 {
		f := pop(&stack)
		c := base_style_of(s, f.h)
		if f.exit {
			if c == nil || f.hidden { counters_exit(&counters, doc, f.h, c, f.hidden, tmp); continue }
			sv := save(c)
			blank(c, true)
			counters_exit(&counters, doc, f.h, c, f.hidden, tmp)
			now := save(c)
			restore(c, sv)
			// only ::after is resolved here
			now.marker, now.items[0], now.items[1] = sv.marker, sv.items[0], sv.items[1]
			if apply_values(s, f.h, c, sv, now) { changed = true }
			continue
		}
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element || c == nil { continue }
		hidden := f.hidden || c.display == .None
		sv := save(c)
		blank(c, false)
		counters_enter(&counters, doc, f.h, n, c, hidden, tmp)
		now := save(c)
		restore(c, sv)
		if !hidden { now.items[2] = sv.items[2] }   // ::after waits for the exit (a hidden box resolves it at once)
		if apply_values(s, f.h, c, sv, now) { changed = true }
		append(&stack, F{h = f.h, hidden = hidden, exit = true})
		for ch := dom.flat_last_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_prev(doc, ch) { append(&stack, F{h = ch, hidden = hidden}) }
	}
	s.counters_used = counters.used
	return changed
}

////////////////////////////////
// Stylesheets touched by mutations

// Whether the mutations since `s` may have changed the document's stylesheets (a <style> or <link> inserted, removed
// or edited): the caller reads them again (sync_document_sheets) before restyling. `owners`: elements the caller
// loads sheets for (pending <link>s).
dom_touches_sheets :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, owners: []base.Handle) -> bool {
	entries, ok := dom.journal_since(doc, s.mutations)
	if !ok { return true }
	is_sheet_el :: proc(n: ^dom.Node) -> bool { return n != nil && n.kind == .Element && (n.name == "style" || n.name == "link") }
	removal := false
	for &en in entries {
		switch en.kind {
		case .Insert:
			n := dom.get(doc, en.node)
			if n == nil { continue }
			if is_sheet_el(n) || is_sheet_el(dom.get(doc, en.parent)) { return true }
			if n.kind == .Element && n.first_child != base.NIL_HANDLE {
				stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
				append(&stack, en.node)
				for len(stack) > 0 {
					x := pop(&stack)
					xn := dom.get(doc, x)
					if xn == nil || xn.kind != .Element { continue }
					if is_sheet_el(xn) { return true }
					for ch := xn.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
				}
			}
		case .Remove:
			if is_sheet_el(dom.get(doc, en.parent)) { return true }
			removal = true
		case .Text:
			n := dom.get(doc, en.node)
			p := n != nil ? n.parent : en.parent
			if is_sheet_el(dom.get(doc, p)) { return true }
		case .Attribute:
			if is_sheet_el(dom.get(doc, en.node)) { return true }
		case .Reslot:
		}
	}
	if removal {
		// (constructed sheets have no owner: they come and go with adoptedStyleSheets)
		for sh in e.sheets { if sh.origin == .Author && !sh.constructed && !connected(doc, sh.owner) { return true } }
		for o in owners { if !connected(doc, o) { return true } }
	}
	return false
}

////////////////////////////////
// Verification (style.incremental.verify)

// Computes every style again from scratch and compares it with `s` (cascaded values). Returns a description of the
// first difference ("" when there is none). A diagnostic: as costly as a full pass.
verify_styles :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, allocator := context.allocator) -> string {
	full := compute_styles(e, doc, s.state)
	defer styled_destroy(full)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n == nil { continue }
		if n.kind == .Element && n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }   // shadow trees too
		if n.kind == .Element {
			a, b := base_style_of(s, h), style_of(full, h)
			if !computed_equal(a, b) {
				what := "fields"
				if a == nil || b == nil {
					what = a == nil ? "no style" : "a style it should not have"
				} else {
					for p in Prop { if !prop_equal(a, b, p) { what = prop_name(p); break } }
					if what == "fields" {
						switch {
						case !computed_equal(a.before, b.before): what = "::before"
						case !computed_equal(a.after, b.after):
							what = "::after"
							if a.after != nil && b.after != nil && len(a.after.content.items) > 0 && len(b.after.content.items) > 0 {
								what = fmt.tprintf("::after %q, expected %q", a.after.content.items[0].text, b.after.content.items[0].text)
							}
						case a.marker_text != b.marker_text: what = fmt.tprintf("marker %q, expected %q", a.marker_text, b.marker_text)
						case:
							// a field no property owns: name it from the struct's type info
							st := runtime.type_info_base(type_info_of(Computed)).variant.(runtime.Type_Info_Struct)
							for f, i in computed_fields {
								pa, pb := rawptr(uintptr(a) + f.offset), rawptr(uintptr(b) + f.offset)
								same := f.plain ? mem.compare_ptrs(pa, pb, f.size) == 0 : deep_equal(pa, pb, f.ti)
								if same { continue }
								what = fmt.tprintf("field %s", st.names[i])
								if st.names[i] == "custom" { what = fmt.tprintf("custom properties %s", custom_diff(a.custom, b.custom)) }
								break
							}
						}
					}
				}
				id, _ := attr(n, "id")
				cls, _ := attr(n, "class")
				where_ := ""
				if r := dom.containing_shadow_root(doc, h); r != base.NIL_HANDLE {
					hn := dom.get(doc, dom.get(doc, r).shadow)
					where_ = fmt.tprintf(" in the shadow tree of <%s>", hn != nil ? hn.name : "?")
				}
				return fmt.aprintf("<%s id=%q class=%q> (node %v)%s: %s differs", n.name, id, cls, h, where_, what, allocator = allocator)
			}
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, ch) }
	}
	if s.canvas != full.canvas { return strings.clone("the canvas color differs", allocator) }
	if s.root_font_size != full.root_font_size { return strings.clone("the root font size differs", allocator) }
	if s.root_line_height != full.root_line_height { return strings.clone("the root line height differs", allocator) }
	return ""
}

// The first custom property whose value differs between `a` (found) and `b` (expected), for verify_styles.
@(private = "file")
custom_diff :: proc(a, b: ^Custom_Props) -> string {
	if a == nil || b == nil { return fmt.tprintf("(a set %v, expected %v)", a != nil, b != nil) }
	for k, v in a.values {
		if w, ok := b.values[k]; !ok || w != v { return fmt.tprintf("%s: %q, expected %q", k, v, ok ? w : "(none)") }
	}
	for k, w in b.values {
		if _, ok := a.values[k]; !ok { return fmt.tprintf("%s: missing, expected %q", k, w) }
	}
	return "(same values)"
}

// Whether what the children of an element see of its query containers differs (it became one, stopped being one, was
// renamed, resized, shown or hidden, or an ancestor did): their styles then change without any rule or inherited value of
// theirs changing.
@(private = "file")
container_changed :: proc(old, nc: ^Computed) -> bool {
	a, b := old.containers, nc.containers
	for a != nil || b != nil {
		if a == nil || b == nil { return true }
		if a != b {
			if a.node != b.node || a.type != b.type || a.size != b.size || len(a.names) != len(b.names) { return true }
			for n, i in a.names { if n != b.names[i] { return true } }
		}
		a, b = a.parent, b.parent
	}
	return false
}

////////////////////////////////
// Exact :has() anchors: members, and whether an anchor's answer flipped

@(private = "file")
Flip_Key :: struct { ha: rawptr, a: base.Handle }

// An attribute named `name` changed: could it change whether an element matches the argument of `ha`?
@(private = "file")
arg_reads_attr :: proc(ha: ^Has_Anchor, name: string) -> bool {
	for sp in ha.arg.simples {
		switch sp.kind {
		case .Id: if name == "id" { return true }
		case .Class: if name == "class" { return true }
		case .Attribute: if strings.equal_fold(sp.name, name) { return true }
		case .Type, .Universal, .Pseudo_Class, .Nesting:
		}
	}
	return false
}

// Before the mutations are looked at: for each exact anchor the members that came (inserted subtrees that hold what its argument
// names, attributes that now match) and the parents members may have left (removed subtrees that held it, attributes that stopped
// matching): what has_flip needs. The members that stayed are in the set; those gone are dropped when met.
@(private = "file")
members_prepare :: proc(m: ^Marker, entries: []dom.Journal_Entry) {
	ix := m.ix
	if m.shadows || !ix.uses_has || !m.exact { return }
	any := false
	for &ha in ix.has_anchors {
		if ha.exact && ha.members != nil { any = true; clear(&ha.members.added); clear(&ha.members.removed) }
	}
	if !any { return }
	doc := m.doc
	known_mask :: proc(ha: ^Has_Anchor) -> u64 { return ha.last_mask & ~dom.WATCH_KNOWN }
	for &en in entries {
		switch en.kind {
		case .Insert:
			n := dom.get(doc, en.node)
			if n == nil || n.kind != .Element || !connected(doc, en.node) { continue }
			w := dom.subtree_watch(doc, en.node)
			for &ha in ix.has_anchors {
				if !ha.exact || ha.members == nil { continue }
				if w & known_mask(&ha) != known_mask(&ha) { continue }   // a key of its argument is not in the subtree
				stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
				append(&stack, en.node)
				for len(stack) > 0 {
					x := pop(&stack)
					xn := dom.get(doc, x)
					if xn == nil || xn.kind != .Element { continue }
					// (also one the set already had: it was taken out of the tree and put back, maybe somewhere else)
					if matches_compound(&m.mc, x, ha.arg) {
						ha.members.set[x] = {}
						append(&ha.members.added, x)
					}
					for ch := xn.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
				}
			}
		case .Remove:
			known := en.watch & dom.WATCH_KNOWN != 0 && en.watch_gen == doc.journal.watch.gen
			for &ha in ix.has_anchors {
				if !ha.exact || ha.members == nil { continue }
				if known && en.watch & known_mask(&ha) != known_mask(&ha) { continue }
				append(&ha.members.removed, en.parent)
			}
		case .Attribute:
			n := dom.get(doc, en.node)
			if n == nil || n.kind != .Element { continue }
			for &ha in ix.has_anchors {
				if !ha.exact || ha.members == nil { continue }
				// an attribute the chain reads, on an element that has members below it: any answer may have flipped
				if ha.chain && !ha.members.dirty && chain_reads_attr(&ha, en.name) {
					for x in ha.members.set { if x != en.node && is_below(doc, x, en.node) { ha.members.dirty = true; break } }
				}
				if !arg_reads_attr(&ha, en.name) { continue }
				was := en.node in ha.members.set
				now := connected(doc, en.node) && matches_compound(&m.mc, en.node, ha.arg)
				if now && !was {
					ha.members.set[en.node] = {}
					append(&ha.members.added, en.node)
				} else if !now && was {
					delete_key(&ha.members.set, en.node)
					append(&ha.members.removed, n.parent)
				}
			}
		case .Text, .Reslot:
		}
	}
}

// Did the answer of `:has(arg)` of the anchor `a` change with the mutations of this pass? A member that was there and is there
// still under `a` (a child of it for :has(> arg)) settles it: true before and after. Else it is true now if some member that came is
// under `a`, and was true before if some member left from under it (a parent it left is `a` or below it; one already gone leaves the
// question open: a flip is assumed).
@(private = "file")
has_flip :: proc(m: ^Marker, ha: ^Has_Anchor, a: base.Handle) -> bool {
	if ha.members.dirty { return true }
	key := Flip_Key{ha, a}
	if r, ok := m.flips[key]; ok { return r }
	r := has_flip_scan(m, ha, a)
	m.flips[key] = r
	return r
}

@(private = "file")
has_flip_scan :: proc(m: ^Marker, ha: ^Has_Anchor, a: base.Handle) -> bool {
	doc := m.doc
	mem := ha.members
	valid :: proc(m: ^Marker, x: base.Handle) -> bool { return dom.get(m.doc, x) != nil && connected(m.doc, x) }
	// x is under a (a child of it when child_only)
	under :: proc(m: ^Marker, ha: ^Has_Anchor, a, x: base.Handle) -> bool {
		xn := dom.get(m.doc, x)
		if xn == nil { return false }
		if ha.child_only { return xn.parent == a }
		for cur := xn.parent; cur != base.NIL_HANDLE; {
			if cur == a { return true }
			cn := dom.get(m.doc, cur)
			if cn == nil { return false }
			cur = cn.parent
		}
		return false
	}
	is_added :: proc(mem: ^Has_Members, x: base.Handle) -> bool {
		for y in mem.added { if y == x { return true } }
		return false
	}
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	stayed := false
	for x in mem.set {
		if dom.get(doc, x) == nil { append(&gone, x); continue }
		if is_added(mem, x) { continue }
		if !valid(m, x) { continue }
		if under(m, ha, a, x) && chain_holds(m, ha, a, x) { stayed = true; break }
	}
	for x in gone { delete_key(&mem.set, x) }
	if stayed { return false }
	now := false
	for x in mem.added { if valid(m, x) && under(m, ha, a, x) && chain_holds(m, ha, a, x) { now = true; break } }
	before := false
	for p in mem.removed {
		if p == a { before = true; break }
		pn := dom.get(doc, p)
		if pn == nil { before = true; break }   // not known where it was
		if ha.child_only { continue }
		for cur := pn.parent; cur != base.NIL_HANDLE; {
			if cur == a { before = true; break }
			cn := dom.get(doc, cur)
			if cn == nil { break }
			cur = cn.parent
		}
		if before { break }
	}
	return now != before
}

// Could a change of attribute `name` change what the chain of `ha` matches (an element's class, id or attribute it tests)?
@(private = "file")
chain_reads_attr :: proc(ha: ^Has_Anchor, name: string) -> bool {
	if name == "class" { return len(ha.feat.classes) > 0 }
	if name == "id" { return len(ha.feat.ids) > 0 }
	for k in ha.feat.attrs { if strings.equal_fold(k, name) { return true } }
	return false
}

// Is `x` below `top` in the tree (strictly)?
@(private = "file")
is_below :: proc(doc: ^dom.Document, x, top: base.Handle) -> bool {
	xn := dom.get(doc, x)
	if xn == nil { return false }
	for cur := xn.parent; cur != base.NIL_HANDLE; {
		if cur == top { return true }
		cn := dom.get(doc, cur)
		if cn == nil { return false }
		cur = cn.parent
	}
	return false
}

// For a chain: does member `x` (under the anchor `a`) satisfy the whole of the relative selector? A single compound: it does.
@(private = "file")
chain_holds :: proc(m: ^Marker, ha: ^Has_Anchor, a, x: base.Handle) -> bool {
	if !ha.chain { return true }
	return match_chain(&m.mc, x, ha.cx, len(ha.cx.compounds) - 1, a, 0)
}

// Is `h` or an ancestor of it among the elements inserted (and not moved) in this batch?
@(private = "file")
in_fresh_insert :: proc(doc: ^dom.Document, fresh: ^map[base.Handle]struct{}, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		if cur in fresh { return true }
		n := dom.get(doc, cur)
		if n == nil { return false }
		cur = n.parent
	}
	return false
}