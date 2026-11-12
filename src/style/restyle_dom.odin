package style

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"

// The answers of the exact :has() anchors a marking may take at the least, whatever the size of the document.
FLIP_LIMIT_MIN :: 1024

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
	taken:    int,      // ... from what they matched before, without matching (matched.odin)
	changed:  int,      // ... whose style changed
	parallel: bool,     // forced subtrees were shared out between threads
	largest_task: int,  // ... the elements of the heaviest task
	keyed_steps: int,   // elements looked at for the keys of what a change reaches
	has_scans: int,     // :has() arguments looked for in subtrees
	has_steps: int,     // ... elements tried for them
	rewalked: bool,     // counters and quotes were resolved again
	fallback: string,   // why the last restyle_dom could not be partial ("" when it was)
	flips:    int,      // answers of the exact :has() anchors it took to mark what changed
	flip_steps: int,    // elements walked through to give them, and anchors gone through for attributes
	nth_of_steps: int,  // elements asked whether they match the S of :nth-child(... of S), or the type of :nth-of-type() (nth_of_changed)
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
	whole:  bool,   // ... that a mark says may match otherwise, not only one that inherits otherwise
	ctx:    Elem_Ctx,   // the tree it is matched in (scope.odin)
	depth:  i32,    // below the top of the walk (sibling_match.odin: a walk in tree order; the tops of a walk, and the
	                // breadth-first expansion of run_deferred, are at 0, where only siblings share)
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
	arena:    ^base.Arena,   // where p allocates
	marks:    []u8,   // by handle index (Marker.marks); nil: none
	// main thread: changes are applied at once; a task (parallel) records them in `results`
	task:     bool,
	results:  [dynamic]Result,
	defer_subtrees: bool,
	defer_forced: bool,   // frames forced by a parent that changed (not only subtrees restyled whole) go to the threads too
	defer_big: bool,      // an element that changed what a large subtree inherits: that subtree goes to the threads, restyled whole
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
	marks: []u8,                     // by handle index: M_SELF, M_SUB, M_CHILD
	marked: [dynamic]base.Handle,    // the elements that have marks
	key_maps: map[u32]^Key_Lookup,   // the sets of keys asked about in this pass
	attr_touched: map[base.Handle]struct{},   // elements that had an attribute changed in this batch: what they showed their siblings is not what they have now
	came:  map[base.Handle]struct{},   // elements put somewhere in this batch: each is restyled whole, wherever it stands now (edges_changed)
	lost:  map[base.Handle][dynamic]Lost_Place,   // parents an element left in this batch, and from where (edges_changed)
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
	keyed:   map[[2]u64]bool,      // (element, key set) subtrees to scan (mark_keyed)
	exact_lists: map[rawptr]^Has_Anchor,   // has_answer: the anchors it can answer for, by their arguments
	flips:   map[Flip_Key]bool,    // has_flip answered in this pass
	flip_limit: int,               // ... past this many of them, a full pass is shorter than the marking
	has_walked: map[Has_Walk_Key]int,   // has_invalidate: the closest hop each ancestor was reached at in this pass
	exact:   bool,                 // the members of the exact anchors can be used
	above:   map[^Has_Anchor][]u64,          // members_above
	flip_above: map[^Has_Anchor]^Flip_Above, // flip_above_of
	flip_steps: int,                         // Restyle_Stats.flip_steps
	of_walked: map[Of_Walk_Key]bool,         // nth_of_changed: its walks in this pass, per element (near the edge, per parent) and selector
	of_tested: int,                          // Restyle_Stats.nth_of_steps
}

@(private = "file")
Walk_Key :: struct { h: base.Handle, ix: ^Inv_Index, dir: u8 }

@(private = "file")
Of_Walk_Key :: struct { h: base.Handle, of: ^Nth_Of, edge: bool, typ: string }

// The nodes beside an element when it left its parent (the journal's).
@(private = "file")
Lost_Place :: struct { prev, next: base.Handle }

@(private = "file")
mark :: proc(m: ^Marker, h: base.Handle, sub: bool, loc := #caller_location) {
	if !is_element_node(m.doc, h) { return }
	if sub && trace_restyle() { trace_roots[fmt.aprintf("%d %s | %s", loc.line, trace_note, trace_cause)] += 1 }
	bits := mark_bits(m.marks, h)^
	nb := bits | (sub ? M_SUB : M_SELF)
	if nb == bits { return }
	mark_bits(m.marks, h)^ = nb
	if bits != 0 { return }   // its ancestors were flagged with it
	append(&m.marked, h)
	// the walk goes down the flat tree: so does the trail to the marked element
	for p := m.shadows ? flat_parent_element(m.doc, h) : parent_element(&m.mc, h); p != base.NIL_HANDLE; p = m.shadows ? flat_parent_element(m.doc, p) : parent_element(&m.mc, p) {
		pb := mark_bits(m.marks, p)
		if pb^ & M_CHILD != 0 { break }
		if pb^ == 0 { append(&m.marked, p) }
		pb^ |= M_CHILD
	}
}

@(private = "file")
mark_bits :: #force_inline proc(marks: []u8, h: base.Handle) -> ^u8 { return &marks[base.handle_index(h)] }

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
	apply_gap(m, next_element(m, h), prev_element(&m.mc, h), r)
}

// Marks what `r` reaches among siblings, read from a place in a list of them: `nx` the first element after it, `pv` the first before it.
@(private = "file")
apply_gap :: proc(m: ^Marker, nx, pv: base.Handle, r: Reach) {
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
		for x := nx; x != base.NIL_HANDLE; x = next_element(m, x) {
			k += 1
			if !r.all_next && k > r.next { break }
			sibs(m, x, r)
		}
	}
	if r.all_prev {
		for x := pv; x != base.NIL_HANDLE; x = prev_element(&m.mc, x) { sibs(m, x, r) }
	}
}

// What `k` reaches from element `x`, by the keys `x` carries.
@(private = "file")
apply_keyed :: proc(m: ^Marker, x: base.Handle, k: ^Keyed_Reach) {
	if reach_any(k.any) { apply(m, x, k.any) }
	n := dom.get(m.doc, x)
	if r, ok := k.by_tag[n.name]; ok { apply(m, x, r) }
	if len(k.by_id) > 0 {
		if id, has := attr(n, "id"); has { if r, ok := k.by_id[id]; ok { apply(m, x, r) } }
	}
	if len(k.by_class) == 0 { return }
	if cls, has := attr(n, "class"); has {
		rest := cls
		for c in token_next(&rest) { if r, ok := k.by_class[c]; ok { apply(m, x, r) } }
	}
}

// A set of keys as a scan of a subtree asks it: an element's own keys looked up, whatever the size of the set.
@(private = "file")
Key_Lookup :: struct {
	classes, ids, types: map[string]struct{},
	attrs: [dynamic]string,
}

@(private = "file")
key_lookup_of :: proc(m: ^Marker, set: u32) -> ^Key_Lookup {
	if l, ok := m.key_maps[set]; ok { return l }
	if m.key_maps == nil { m.key_maps = make(map[u32]^Key_Lookup, 8, context.temp_allocator) }
	a := context.temp_allocator
	l := new(Key_Lookup, a)
	l.classes, l.ids, l.types = make(map[string]struct{}, 16, a), make(map[string]struct{}, 4, a), make(map[string]struct{}, 4, a)
	l.attrs = make([dynamic]string, 0, 4, a)
	key_set_each(&m.e.key_sets, set, l, proc(user: rawptr, k: Subject_Key) {
		l := (^Key_Lookup)(user)
		switch k.kind {
		case .Class: l.classes[k.name] = {}
		case .Id: l.ids[k.name] = {}
		case .Type: l.types[k.name] = {}
		case .Attr: append(&l.attrs, k.name)
		}
	})
	m.key_maps[set] = l
	return l
}

// The descendants of `h` that carry one of the keys of set `set` are to be marked (their own marks only: what they pass on to
// their children, the walk finds out). Noted, for marks_keyed_scan.
@(private = "file")
mark_keyed :: proc(m: ^Marker, h: base.Handle, set: u32) {
	if m.keyed == nil { m.keyed = make(map[[2]u64]bool, 16, context.temp_allocator) }
	m.keyed[[2]u64{u64(h), u64(set)}] = true
}

// What mark_keyed noted, once all the mutations are read. A :has() anchor marks every ancestor with the same set, so a subtree inside
// another of the same set adds nothing, and the sets of one element take one walk: scanned as they came, they were 8 % of a restyle.
@(private = "file")
marks_keyed_scan :: proc(m: ^Marker) {
	if len(m.keyed) == 0 { return }
	roots := make(map[base.Handle][dynamic]u32, len(m.keyed), context.temp_allocator)
	outer: for pair in m.keyed {
		h, set := base.Handle(pair[0]), u32(pair[1])
		for a := parent_element(&m.mc, h); a != base.NIL_HANDLE; a = parent_element(&m.mc, a) {
			if ([2]u64{u64(a), u64(set)}) in m.keyed { continue outer }
		}
		if h not_in roots { roots[h] = make([dynamic]u32, 0, 2, context.temp_allocator) }
		append(&roots[h], set)
	}
	stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
	for h, sets in roots {
		keys := key_lookup_of(m, sets[0])
		if len(sets) > 1 {
			all := new_clone(Key_Lookup{classes = make(map[string]struct{}, 64, context.temp_allocator), ids = make(map[string]struct{}, 4, context.temp_allocator), types = make(map[string]struct{}, 4, context.temp_allocator), attrs = make([dynamic]string, 0, 4, context.temp_allocator)}, context.temp_allocator)
			for set in sets {
				one := key_lookup_of(m, set)
				for k in one.classes { all.classes[k] = {} }
				for k in one.ids { all.ids[k] = {} }
				for k in one.types { all.types[k] = {} }
				append(&all.attrs, ..one.attrs[:])
			}
			keys = all
		}
		clear(&stack)
		append(&stack, h)
		for len(stack) > 0 {
			x := pop(&stack)
			for ch := dom.flat_first_child(m.doc, x); ch != base.NIL_HANDLE; ch = dom.flat_next(m.doc, ch) {
				n := dom.get(m.doc, ch)
				if n == nil || n.kind != .Element { continue }
				m.e.last_restyle.keyed_steps += 1
				if carries_key(n, keys) { mark(m, ch, false) }
				append(&stack, ch)
			}
		}
	}
}

@(private = "file")
carries_key :: proc(n: ^dom.Node, keys: ^Key_Lookup) -> bool {
	if n.name in keys.types { return true }
	for a in n.attrs {
		for k in keys.attrs { if base.ascii_equal_fold(a.name, k) { return true } }
		switch a.name {
		case "id": if a.value in keys.ids { return true }
		case "class":
			rest := a.value
			for c in token_next(&rest) { if c in keys.classes { return true } }
		}
	}
	return false
}
@(private = "file")
each_class :: proc(v: string, out: ^map[string]bool) {
	rest := v
	for c in token_next(&rest) { out[c] = true }
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
// :has() arguments use sibling combinators, the earlier siblings of x and of its ancestors, for those arguments alone: one
// `:has(+ .x)` in a sheet tried every anchor of the page on every sibling, and on cnn.com a <script> added to <head> restyled all of
// <head>, 5 000 answers a mutation). x itself when `self`. `beside`: x alone, for the anchors that read siblings. `from_hop`:
// how far below x the change is (a child that left: 1, not one of x's own siblings' concern).
@(private = "file")
has_invalidate :: proc(m: ^Marker, x: base.Handle, self: bool, feat := Has_Change{}, beside := false, from_hop := 0) {
	ix := ix_of(m, x)
	if !ix.uses_has || len(ix.has_anchors) == 0 { return }
	feat := feat
	// the masks are of the document's watch, which only the index of the document's own rules sets up (watch_sync)
	if feat.kind == .Tree && (ix.watched != m.doc || ix.watched_gen != m.doc.journal.watch.gen) { feat.known = false }
	// a feature that changed on an element: only the anchors whose :has() tests it can be affected (a bare
	// `:not(:has(.a))` is every element's candidate: without this every class change restyled the document). Decided once here,
	// not for each ancestor and sibling: on a deep page that lookup was the hottest part of a restyle.
	stack, stack_beside: [32]^Has_Anchor
	wide := len(ix.has_anchors) > len(stack)
	concerned := wide ? make([]^Has_Anchor, len(ix.has_anchors), context.temp_allocator) : stack[:]
	readers := wide ? make([]^Has_Anchor, len(ix.has_anchors), context.temp_allocator) : stack_beside[:]   // those of them that read siblings
	n, n_readers := 0, 0
	// the farthest level any of them reaches: the walk up stops there
	top := 0
	for &ha in ix.has_anchors {
		if !has_tests(ha.feat, feat) || (beside && !ha.feat.sibling) { continue }
		concerned[n] = &ha
		n += 1
		if ha.feat.sibling { readers[n_readers] = &ha; n_readers += 1 }
		if ha.hops < 0 { top = -1 } else if top >= 0 { top = max(top, ha.hops) }
	}
	if n == 0 { return }
	concerned, readers = concerned[:n], readers[:n_readers]
	test :: proc(m: ^Marker, anchors: []^Has_Anchor, a: base.Handle, hop: int) {
		for hap in anchors {
			ha := hap
			if ha.hops >= 0 && hop > ha.hops { continue }   // (`:has(> .a)`: only the parent of the changed element)
			if anchor_could_match(&m.mc, a, ha.compound) && anchor_could_match(&m.mc, a, ha.around) {
				trace_why = "not exact, or no members"
				if m.exact && ha.exact && ha.members != nil && !has_flip(m, ha, a) { continue }
				if trace_restyle() { trace_note = fmt.tprintf(":has() anchor why=%s m.exact=%v members=%v exact=%v chain=%v unkeyed=%v hops=%d classes=%s attrs=%s ids=%s types=%s", trace_why, m.exact, ha.members != nil, ha.exact, ha.chain, ha.feat.unkeyed, ha.hops, trace_keys(ha.feat.classes), trace_keys(ha.feat.attrs), trace_keys(ha.feat.ids), trace_keys(ha.feat.types)) }
				apply(m, a, ha.reach)
				trace_note = ""
			}
		}
	}
	if self { test(m, concerned, x, from_hop) }
	if beside { return }
	hop := from_hop
	for cur := x; cur != base.NIL_HANDLE; cur = parent_element(&m.mc, cur) {
		if top >= 0 && hop > top { break }
		if cur != x {
			// the elements inserted under one parent walk up the same ancestors: from one reached before at a hop no farther than this one,
			// everything above was tested with at least as many anchors (test skips only by being too far)
			key := Has_Walk_Key{ix, cur, feat}
			if before, seen := m.has_walked[key]; seen && before <= hop { break }
			m.has_walked[key] = hop
			test(m, concerned, cur, hop)
		}
		if n_readers > 0 {
			for ps := prev_element(&m.mc, cur); ps != base.NIL_HANDLE; ps = prev_element(&m.mc, ps) { test(m, readers, ps, hop) }
		}
		hop += 1
	}
}

// What changed on an element under an anchor: a class, an id or an attribute (kind None: a change of the tree itself,
// or of anything: every anchor is concerned).
@(private = "file")
Has_Change :: struct {
	kind:  enum u8 { None, Class, Id, Attr, Tree, Empty },   // Tree: elements came or went (mask: which watched features they held; known: it was looked at); Empty: an element's text came or went
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
	case .Empty: return f.empty
	}
	return true
}

@(private = "file")
empty_changed :: proc(m: ^Marker, p: base.Handle) {
	for ix in ixs_for(m, p) {
		if reach_any(ix.empty) { apply(m, p, ix.empty) }
		if ix.has_empty { has_invalidate(m, p, false, Has_Change{kind = .Empty}) }
	}
}

// An element was inserted under `p`, at `at`.
@(private = "file")
children_inserted :: proc(m: ^Marker, p, at: base.Handle) {
	for ix in ixs_for_children(m, p, at) {
		// a walk that reaches an element an earlier walk went through stops: the rest is the earlier one's (Marker.walked)
		position_changed(m, ix, at, at)
		edges_changed(m, ix, p)
		nth_of_changed(m, ix, p, at, at, at, dom.get(m.doc, at).name)
		if nx := next_element(m, at); nx != base.NIL_HANDLE && ix.sib_rel.used { apply_keyed(m, nx, &ix.sib_rel) }
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

// The elements from `nx` on and from `pv` back have another index among their siblings than they had.
@(private = "file")
position_changed :: proc(m: ^Marker, ix: ^Inv_Index, nx, pv: base.Handle) {
	if ix.pos_fwd.used {
		for x := nx; x != base.NIL_HANDLE; x = next_element(m, x) {
			if walk_seen(m, x, ix, 0) { break }
			apply_keyed(m, x, &ix.pos_fwd)
		}
	}
	if ix.pos_bwd.used {
		for x := pv; x != base.NIL_HANDLE; x = prev_element(&m.mc, x) {
			if walk_seen(m, x, ix, 1) { break }
			apply_keyed(m, x, &ix.pos_bwd)
		}
	}
}

// Elements came to `p`, or left it: what stands first or last among its children, by the document as it is now. An element is first now, or it
// was first before this batch and is still there: then all that stands before it came in this batch (nothing else can get ahead of it), so it
// is the first of the children that did not come. One that stands first with nothing come before it, in a list nothing left, stood there before.
// On cnn.com :last-child and the like read from every sibling of a <script> added to <body>
// restyled 2 500 elements a load, to no effect.
@(private = "file")
edges_changed :: proc(m: ^Marker, ix: ^Inv_Index, p: base.Handle) {
	key := Walk_Key{p, ix, 4}
	if key in m.emptied { return }
	m.emptied[key] = true
	if ix.edge_first.used { along(m, p, &ix.edge_first, ix.edge_first_depth, false) }
	if ix.edge_last.used { along(m, p, &ix.edge_last, ix.edge_last_depth, true) }
}

// `depth` elements in from the edge of `p`'s children, those that came aside (the zone): what stands past them was past that place before. In
// the zone, what stands before the first element that came, and before the place of the first that left, kept its index: what follows is restyled.
// (:nth-child(3): an element whose index was or is 3 has at most two before it that did not come.) Read as one, a removal anywhere restyled
// the first three children of <body> with what they hold, and an element appended to a list of two the two before it. With `of`, only what
// matches its S has an index and is counted (what left is taken as one of them: it is not there to be asked), and `flipped`, an element
// whose attributes may have changed whether it matches S, moved what stands past it, itself included, as one that came or left there.
// (`typ`: the type an `of` of a type counts.)
@(private = "file")
along :: proc(m: ^Marker, p: base.Handle, k: ^Keyed_Reach, depth: int, back: bool, of: ^Nth_Of = nil, flipped := base.NIL_HANDLE, typ := "") {
	next :: proc(m: ^Marker, x: base.Handle, back: bool) -> base.Handle { return back ? prev_element(&m.mc, x) : next_element(m, x) }
	pn := dom.get(m.doc, p)
	from, _ := element_from(m, p, back ? pn.last_child : pn.first_child, back)
	zone := make([dynamic]base.Handle, 0, 8, context.temp_allocator)
	counted := make([dynamic]bool, 0, 8, context.temp_allocator)   // ... has an index (with `of`, matches S)
	moved := -1   // the first element of the zone whose index may differ
	for x, kept := from, 0; x != base.NIL_HANDLE; x = next(m, x, back) {
		c := of == nil || of_matches(m, of, x, typ)
		append(&zone, x)
		append(&counted, c)
		came := x in m.came || x == flipped
		if moved < 0 && (x == flipped || (c && came)) { moved = len(zone) - 1 }
		if !c || came { continue }
		kept += 1
		if kept == max(depth, 1) { break }
	}
	// the element that stood next to a removed one on the edge's side: what follows it in the zone moved (none, gone, moved itself: all of it)
	for at in m.lost[p] {
		beside, known := element_from(m, p, back ? at.next : at.prev, !back)
		from_here := 0
		if known && beside != base.NIL_HANDLE && beside not_in m.came {
			i, found := slice.linear_search(zone[:], beside)
			if !found { continue }   // past the zone
			from_here = i + 1
		}
		if moved < 0 || from_here < moved { moved = from_here }
	}
	if moved < 0 { return }
	for x, i in zone[moved:] {
		if x == flipped { apply(m, x, of.total) } else if counted[moved + i] { apply_keyed(m, x, k) }
	}
}

// Whether `x` matches the S of `of`, or is of type `typ` (in a document with shadow trees, which tree's rules it sees is the pass's: taken as yes).
@(private = "file")
of_matches :: proc(m: ^Marker, of: ^Nth_Of, x: base.Handle, typ: string) -> bool {
	m.of_tested += 1
	if m.shadows { return true }
	if of.list == nil { return dom.get(m.doc, x).name == typ }
	return matches_list(&m.mc, x, of.list^)
}

// Element `x`, of type `typ`, came under `p` (`nx` = `pv` = `x`), or left it from between `nx` and `pv`: the indexes among the siblings that
// match S of :nth-child(... of S), or are of that type. An element that does not match S has no such index, and moves none: what comes or
// goes that does not match S (S reads the element alone: one that left is asked as it was) reaches nothing through it; one that matches it
// moves the indexes past its place, of what matches S. Near the edge (:nth-last-child(1 of S), :first-of-type), the zone of `along`, counted
// in what matches S; else from the place on. (On cnn.com `:only-of-type`, `[class]:nth-of-type(2)` and `:nth-last-child(1 of [class*=...])`,
// of no key, restyled every sibling the walk from an element added went over: 1 800 elements a load, to no effect.) With shadow trees, from
// the place on, every sibling.
@(private = "file")
nth_of_changed :: proc(m: ^Marker, ix: ^Inv_Index, p, x, nx, pv: base.Handle, typ: string) {
	for &of in ix.nth_of {
		if of.list != nil && !of_matches(m, &of, x, typ) { continue }
		if of.depth > 0 && !m.shadows {
			key := Of_Walk_Key{p, &of, true, of.list == nil ? typ : ""}
			if key in m.of_walked { continue }
			m.of_walked[key] = true
			along(m, p, &of.reach, of.depth, of.back, &of, typ = typ)
			continue
		}
		of_walk(m, &of, of.back ? pv : nx, typ)
	}
}

// From `from` on, away from the edge `of` counts from: what matches its S. A walk stops where an earlier one of this pass went through.
@(private = "file")
of_walk :: proc(m: ^Marker, of: ^Nth_Of, from: base.Handle, typ: string) {
	for x := from; x != base.NIL_HANDLE; x = of.back ? prev_element(&m.mc, x) : next_element(m, x) {
		key := Of_Walk_Key{x, of, false, of.list == nil ? typ : ""}
		if key in m.of_walked { break }
		m.of_walked[key] = true
		if of_matches(m, of, x, typ) { apply_keyed(m, x, &of.reach) }
	}
}

// An attribute of `h` changed: of the :nth-child(... of S) whose S reads it, `h` may match S now and not before, or the other way, which
// moves the indexes past it as an element that came or left there. `h` itself is restyled: its index may have come or gone.
@(private = "file")
nth_of_attribute :: proc(m: ^Marker, ix: ^Inv_Index, h: base.Handle, ch: Attr_Change) {
	n := dom.get(m.doc, h)
	for &of in ix.nth_of {
		if ch.name not_in of.reads { continue }
		if !m.shadows && of_matches(m, &of, h, "") == matched_before(m, of.list^, h, n, ch) { continue }   // (a class among others: the answer holds)
		if of.depth > 0 && !m.shadows {
			along(m, n.parent, &of.reach, of.depth, of.back, &of, h)
			continue
		}
		apply(m, h, of.total)
		of_walk(m, &of, of.back ? prev_element(&m.mc, h) : next_element(m, h), "")
	}
}

// Whether `h` matched `list`, a list of Nth_Of (local_reads), with the attribute `ch` names as it was before the change.
@(private = "file")
matched_before :: proc(m: ^Marker, list: css.Selector_List, h: base.Handle, n: ^dom.Node, ch: Attr_Change) -> bool {
	compound: for &c in list {
		for &s in c.compounds[0].simples {
			ok: bool
			switch {
			case s.kind == .Class && ch.name == "class": ok = ch.had_old && class_listed(ch.old, s.name)
			case s.kind == .Id && ch.name == "id": ok = ch.had_old && ch.old == s.name
			case s.kind == .Attribute && s.name == ch.name: ok = attr_value_matches(ch.had_old, ch.old, s)
			case s.kind == .Pseudo_Class && s.pseudo == .Not: ok = !matched_before(m, s.list^, h, n, ch)
			case s.kind == .Pseudo_Class: ok = matched_before(m, s.list^, h, n, ch)   // (:is(), :where())
			case: ok = matches_simple(&m.mc, h, n, s)
			}
			if !ok { continue compound }
		}
		return true
	}
	return false
}

// The first element, going by `next` (or back), from the node `from` that stood beside a removed one, still under `p`. `ok` false: `from`
// left too: the place is not known any more.
@(private = "file")
element_from :: proc(m: ^Marker, p, from: base.Handle, back: bool) -> (x: base.Handle, ok: bool) {
	for cur := from; cur != base.NIL_HANDLE; {
		n := dom.get(m.doc, cur)
		if n == nil || n.parent != p { return base.NIL_HANDLE, false }
		if n.kind == .Element { return cur, true }
		cur = back ? n.prev : n.next
	}
	return base.NIL_HANDLE, true
}

// An element left `en.parent`, from between `en.prev` and `en.next`. `gone`: the element as it was, nil when that is not known (destroyed
// since, or an attribute of it changed in this batch): what it showed its siblings is then looked for from all of them.
@(private = "file")
children_removed :: proc(m: ^Marker, en: ^dom.Journal_Entry, gone: ^dom.Node) {
	p := en.parent
	pn := dom.get(m.doc, p)
	first := pn.first_child
	for first != base.NIL_HANDLE && !is_element_node(m.doc, first) { first = dom.get(m.doc, first).next }
	if first != base.NIL_HANDLE {
		nx, nx_ok := element_from(m, p, en.next, false)
		pv, pv_ok := element_from(m, p, en.prev, true)
		for ix in ixs_for_children(m, p, first) {
			edges_changed(m, ix, p)
			if gone == nil || !nx_ok || !pv_ok {
				children_all_changed(m, ix, p)
				continue
			}
			position_changed(m, ix, nx, pv)
			nth_of_changed(m, ix, p, en.node, nx, pv, gone.name)
			if nx != base.NIL_HANDLE && ix.sib_rel.used { apply_keyed(m, nx, &ix.sib_rel) }
			for r in feature_reaches(ix, gone) { apply_gap(m, nx, pv, r) }
		}
	}
	if is_element_node(m.doc, p) { empty_changed(m, p) }
	mask, mask_gen := en.watch, en.watch_gen
	if ix := ix_of(m, first != base.NIL_HANDLE ? first : p); ix.uses_has {
		if is_element_node(m.doc, p) { has_invalidate(m, p, true, Has_Change{kind = .Tree, mask = mask, known = mask & dom.WATCH_KNOWN != 0 && mask_gen == m.doc.journal.watch.gen}, from_hop = 1) }
		if key := (Walk_Key{p, ix, 3}); ix.has_sibling && key not_in m.emptied {
			m.emptied[key] = true
			pn = dom.get(m.doc, p)
			for ch := pn.first_child; ch != base.NIL_HANDLE; ch = dom.get(m.doc, ch).next {
				if is_element_node(m.doc, ch) { has_invalidate(m, ch, true, Has_Change{kind = .Tree, mask = mask, known = mask & dom.WATCH_KNOWN != 0 && mask_gen == m.doc.journal.watch.gen}, beside = true) }
			}
		}
	}
}

// Anything may have changed among the children of `p`: each is looked at for what reads its place or its siblings. The same parent again:
// the same walk of the same children (Marker.emptied).
@(private = "file")
children_all_changed :: proc(m: ^Marker, ix: ^Inv_Index, p: base.Handle) {
	key := Walk_Key{p, ix, 2}
	if key in m.emptied { return }
	m.emptied[key] = true
	for ch := dom.get(m.doc, p).first_child; ch != base.NIL_HANDLE; ch = dom.get(m.doc, ch).next {
		if !is_element_node(m.doc, ch) { continue }
		apply_keyed(m, ch, &ix.pos_fwd)
		apply_keyed(m, ch, &ix.pos_bwd)
		apply_keyed(m, ch, &ix.sib_rel)
		for &of in ix.nth_of { apply_keyed(m, ch, &of.reach) }
	}
}

// What the features of `n` reach among its siblings, one reach for each: a union would be as wide as the widest.
@(private = "file")
feature_reaches :: proc(ix: ^Inv_Index, n: ^dom.Node) -> []Reach {
	out := make([dynamic]Reach, 0, 8, context.temp_allocator)
	add :: proc(out: ^[dynamic]Reach, r: Reach) {
		r := r
		r.self, r.desc = false, false
		if reach_any(r) { append(out, r) }
	}
	add(&out, ix.keyless)
	if t, ok := ix.by_tag[n.name]; ok { add(&out, t) }
	for a in n.attrs {
		if x, ok := ix.by_attr[a.name]; ok { add(&out, x) }
		switch a.name {
		case "id": if x, ok := ix.by_id[a.value]; ok { add(&out, x) }
		case "class":
			cls := make(map[string]bool, 8, context.temp_allocator)
			each_class(a.value, &cls)
			for c in cls { if x, ok := ix.by_class[c]; ok { add(&out, x) } }
		}
	}
	return out[:]
}

// What an inserted element's own features reach beyond its subtree (which is restyled whole anyway).
@(private = "file")
inserted_features :: proc(m: ^Marker, h: base.Handle, n: ^dom.Node) {
	for ix in ixs_for(m, h) { inserted_features_of(m, ix, h, n) }
}

@(private = "file")
inserted_features_of :: proc(m: ^Marker, ix: ^Inv_Index, h: base.Handle, n: ^dom.Node) {
	for r in feature_reaches(ix, n) { apply(m, h, r) }
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
		if v, ok := dom.get_attribute(doc, h, "type"); ok && base.ascii_equal_fold(strings.trim_space(v), "radio") { return true }
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
			// (a host's shadow root. A shadow root's `shadow` is its host: following it never ended, and the stack took all the memory)
			if n.shadow != base.NIL_HANDLE && !n.is_shadow { append(&stack, n.shadow) }
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
	// (a class rewritten with the same tokens passed under `[class*=...]`: 224 elements of cnn.com)
	if tests := ix.attr_tests[ch.name]; len(tests) > ATTR_TESTS_MAX {
		if r, ok := ix.by_attr[ch.name]; ok { apply(m, h, r) }
	} else {
		if r, ok := ix.attr_other[ch.name]; ok { apply(m, h, r) }
		for &x in tests {
			if attr_value_matches(ch.had_old, ch.old, x.simple^) != attr_value_matches(has_cur, cur, x.simple^) { apply(m, h, x.reach) }
		}
	}
	if ch.name in ix.has_attrs { has_invalidate(m, h, false, Has_Change{kind = .Attr, name = ch.name}) }
	nth_of_attribute(m, ix, h, ch)
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

// What the attributes the forms model falls back on stand for in the arguments of :has(): a change of the state of a control is read
// as one of them.
@(private = "file")
CONTROL_STATE_ATTRIBUTES :: [?]string{"checked", "selected", "type", "disabled", "readonly", "contenteditable", "required", "value", "placeholder"}

// The pseudo-classes of control `h` may have changed: what the rules that ask the forms model reach from it, as for an attribute of
// a form control (attribute_changed_in). A script writing a value in a field made a full pass of the document, whatever the rules said.
@(private = "file")
control_changed :: proc(m: ^Marker, h: base.Handle) {
	n := dom.get(m.doc, h)
	if n == nil || n.kind != .Element || !connected(m.doc, h) { return }
	for ix in ixs_for(m, h) {
		if !ix.uses_controls { continue }
		if control_groups_used(m.e, ix, m.s) {
			if group_control(m.doc, h, n) { m.fail = "a control of a group changed"; return }
			mark_form_ancestors(m, h)
		}
		apply(m, h, ix.controls)
		for name in CONTROL_STATE_ATTRIBUTES {
			if name in ix.has_attrs { has_invalidate(m, h, false, Has_Change{kind = .Attr, name = name}) }
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
	m.attr_touched = make(map[base.Handle]struct{}, 16, context.temp_allocator)
	m.came = make(map[base.Handle]struct{}, 16, context.temp_allocator)
	m.lost = make(map[base.Handle][dynamic]Lost_Place, 16, context.temp_allocator)
	for &en in entries {
		#partial switch en.kind {
		case .Attribute: m.attr_touched[en.node] = {}
		case .Insert: m.came[en.node] = {}
		case .Remove:
			if en.parent not_in m.lost { m.lost[en.parent] = make([dynamic]Lost_Place, 0, 2, context.temp_allocator) }
			append(&m.lost[en.parent], Lost_Place{en.prev, en.next})
		}
	}
	attrs := make(map[string]Attr_Change, 16, context.temp_allocator)
	attr_order := make([dynamic]string, 0, 16, context.temp_allocator)
	for &en in entries {
		if m.fail != "" { return }
		if trace_restyle() { nn := dom.get(doc, en.node); pp := dom.get(doc, en.parent); trace_cause = fmt.aprintf("%v <%s>.%s in <%s>", en.kind, nn != nil ? nn.name : "gone", en.name, pp != nil ? pp.name : "-") }
		// (cnn.com: 8 000 elements the parser attached under 80 :has() anchors, 114 000 answers, 8.7 s, to find that a full pass of 0.2 s was due)
		if len(m.flips) > m.flip_limit {
			m.fail = "too much changed"
			return
		}
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
			// (a <link> changes nothing until its sheet comes; a <style> has one once the sheets were read: dom_touches_sheets)
			if n.name == "style" && engine_sheet_of_owner(m.e, en.node) == nil && !in_shadow(m, en.node) { m.fail = "stylesheet element inserted"; return }
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
			if p_ok { children_removed(m, &en, en.node in m.attr_touched ? nil : n) }
		case .Text:
			n := dom.get(doc, en.node)
			p := n != nil ? n.parent : en.parent
			if !is_element_node(doc, p) || !connected(doc, p) { continue }
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
		if trace_restyle() { nn := dom.get(doc, ch.h); cc, _ := attr(nn, ch.name); trace_cause = fmt.aprintf("attr %s of <%s> %q -> %q", ch.name, nn.name, ch.old[:min(len(ch.old), 50)], cc[:min(len(cc), 50)]) }
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
trace_roots: map[string]int   // (WREN_RESTYLE_TRACE) the lines of restyle_dom.odin that marked the root element's whole subtree (with the :has() anchor, when it was one), and how often
@(private = "file")
trace_note: string            // (WREN_RESTYLE_TRACE) the :has() anchor being applied
@(private = "file")
trace_cause: string           // (WREN_RESTYLE_TRACE) the mutation being marked
@(private = "file")
trace_why: string             // (WREN_RESTYLE_TRACE) why has_flip answered that the answer of an anchor flipped

// WREN_RESTYLE_TRACE=1: what made a restyle too big to scope, on standard error (for the measuring tools): the mutations, and the
// elements whose whole subtree was marked, the biggest first.
trace_restyle :: proc() -> bool {
	@(static) known, on: bool
	if !known { known = true; on = os.get_env("WREN_RESTYLE_TRACE", context.temp_allocator) != "" }
	return on
}

@(private = "file")
trace_keys :: proc(set: map[string]bool) -> string {
	keys := make([dynamic]string, 0, len(set), context.temp_allocator)
	for k in set { append(&keys, k) }
	slice.sort(keys[:])
	return len(keys) > 6 ? fmt.tprintf("%v+%d", keys[:6], len(keys) - 6) : fmt.tprintf("%v", keys[:])
}

@(private = "file")
trace_marks :: proc(m: ^Marker, work: int, entries: []dom.Journal_Entry) {
	Row :: struct { h: base.Handle, size: int }
	rows := make([dynamic]Row, 0, 16, context.temp_allocator)
	for h in m.marked {
		if mark_bits(m.marks, h)^ & M_SUB == 0 { continue }
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
	for k, v in trace_roots { fmt.eprintfln("    root subtree marked by restyle_dom.odin:%s x %d", k, v) }
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
// The elements of the inserted subtrees of `entries` that are in the document are more than `limit`. Each is marked
// whole (mark_mutations), so `estimate` finds at least as many: the answer is the one the marking would give. (The
// tree, not the flat tree: documents without shadow trees.) The inserted nodes are bits by handle index, set for live
// handles only (the index of a node that went may be another node's now); a second set keeps a node inserted twice from
// being counted twice. One walk up from each: it stops at an inserted ancestor (counted with it) or finds the document.
@(private = "file")
inserted_exceed :: proc(doc: ^dom.Document, entries: []dom.Journal_Entry, limit: f64) -> bool {
	words := (int(doc.nodes.used) + 63) / 64
	fresh, done: []u64
	for &en in entries {
		if en.kind != .Insert || dom.get(doc, en.node) == nil { continue }
		if fresh == nil {
			bits := make([]u64, 2 * words, context.temp_allocator)
			fresh, done = bits[:words], bits[words:]
		}
		bit_set_at(fresh, en.node)
	}
	if fresh == nil { return false }
	n := 0
	stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
	for &en in entries {
		h := en.node
		if en.kind != .Insert || !is_element_node(doc, h) || bit_at(done, h) { continue }
		bit_set_at(done, h)
		top := h   // inside another inserted subtree (counted with it): none; else the top of its tree
		for p := dom.get(doc, h).parent; p != base.NIL_HANDLE; {
			pn := dom.get(doc, p)
			if pn == nil || bit_at(fresh, p) { top = base.NIL_HANDLE; break }
			top = p
			p = pn.parent
		}
		if top != doc.root { continue }
		append(&stack, h)
		for len(stack) > 0 {
			x := pop(&stack)
			n += 1
			if f64(n) > limit { return true }
			for ch := dom.get(doc, x).first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { if is_element_node(doc, ch) { append(&stack, ch) } }
		}
	}
	return false
}

@(private = "file")
bit_at :: #force_inline proc(bits: []u64, h: base.Handle) -> bool {
	i := base.handle_index(h)
	return bits[i >> 6] & (u64(1) << (i & 63)) != 0
}

@(private = "file")
bit_set_at :: #force_inline proc(bits: []u64, h: base.Handle) {
	i := base.handle_index(h)
	bits[i >> 6] |= u64(1) << (i & 63)
}

// Elements marked, counting whole subtrees (the work a restyle will do at least): the walk's own way down the marks, stopped past `limit`.
@(private = "file")
estimate :: proc(m: ^Marker, limit: f64) -> int {
	n := 0
	F :: struct { h: base.Handle, sub: bool }
	stack := make([dynamic]F, 0, 64, context.temp_allocator)
	for ch := dom.get(m.doc, m.doc.root).first_child; ch != base.NIL_HANDLE; ch = dom.get(m.doc, ch).next {
		if is_element_node(m.doc, ch) { append(&stack, F{ch, false}) }
	}
	for len(stack) > 0 && f64(n) <= limit {
		f := pop(&stack)
		bits := mark_bits(m.marks, f.h)^
		sub := f.sub || bits & M_SUB != 0
		if sub || bits & M_SELF != 0 { n += 1 }
		if !sub && bits & M_CHILD == 0 { continue }
		for ch := dom.flat_first_child(m.doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_next(m.doc, ch) {
			if is_element_node(m.doc, ch) && (sub || mark_bits(m.marks, ch)^ != 0) { append(&stack, F{ch, sub}) }
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
	old := style_of(s, h)
	old_base = old
	if old != nil && len(s.overlaid) > 0 { if b, ok := s.overlaid[h]; ok { old_base = b } }
	if !counters_carry_over(s, w.doc, h, old_base, c, w.p.alloc, w.task) { w.rewalk = true }
	if (old_base == nil || !s.counters_used) && box_feeds_counters(c) { w.rewalk = true }
	if old_base != nil && computed_equal(old_base, c) && !container_changed(old_base, c) { return old_base, false, old_base }
	level := max(layout_level(old, c), Change_Level.Paint)
	if level >= .Layout { w.layout_changed = true }
	shown := old_base != nil && old_base.display == .None && c.display != .None
	// (the only list of a page may be what comes out of display: none: no walk ever gave its markers. A style thread cannot look at what others write)
	if shown && !s.counters_used && (w.task || subtree_feeds(s, w.doc, h)) { w.rewalk = true }
	if has_transitions(c) || has_animations(c) { w.motion = true }
	w.changed += 1
	if w.task {
		append(&w.results, Result{h = h, old = old, new = c, level = level, shown = shown})
		styled_put(s, h, c)   // this slot is written by this thread only (the arrays sized beforehand); the rest is applied afterwards
		return c, true, old_base
	}
	if s.track_changes { append(&s.changes, Style_Change{node = h, old = old, new = c}) }
	journal_add(s, h, level)
	delete_key(&s.overlaid, h)
	styled_put(s, h, c)
	if shown { append(&s.shown, h) }
	return c, true, old_base
}

// Computes the style of one element and settles it. A style equal to the one in force is dropped with all it
// allocated (the share table, if it took it, gets the equal record in force instead): restyles that change nothing
// leave nothing behind, but for what the inline cache kept of a new style attribute: it outlives the element's pass.
@(private = "file")
restyle_one :: proc(w: ^Walker, f: ^Frame, n: ^dom.Node, unmarked: bool) -> (cur: ^Computed, changed: bool, old_base: ^Computed) {
	w.marked += 1
	tmp := base.arena_temp_begin(w.arena)
	made := w.p.share.count
	kept := w.s.inline_rules_made
	c, _ := compute_element(w.p, f.h, n, f.parent, &f.bloom, f.ctx, int(f.depth), unmarked)
	cur, changed, old_base = settle(w, f.h, c)
	if changed || w.s.inline_rules_made != kept { base.arena_temp_ignore(tmp); return }
	if w.p.share.count != made { share_replace_last(&w.p.share, cur) }
	base.arena_temp_end(tmp)
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
		bits := w.marks != nil ? mark_bits(w.marks, f.h)^ : 0
		sub := f.sub || bits & M_SUB != 0
		whole := f.whole || bits & M_SUB != 0
		cur := base_style_of(s, f.h)
		inh_changed, other_changed := false, false
		if f.force || sub || bits & M_SELF != 0 {
			// (never the root element: the root font size and line height are checked below, on this thread)
			if w.defer_subtrees && sub && !f.sub && f.parent != nil {
				append(&w.deferred, Frame{h = f.h, parent = f.parent, bloom = f.bloom, force = true, sub = true, whole = whole, ctx = f.ctx})
				continue
			}
			// marked, or forced by its parent's change: restyled whatever happens, and its parent's style is final (the walk
			// of its own children, and of the marks below, is a thread's)
			if w.defer_forced && !f.sub && !sub && f.parent != nil {
				append(&w.deferred, Frame{h = f.h, parent = f.parent, bloom = f.bloom, force = true, ctx = f.ctx})
				continue
			}
			nc, changed, old := restyle_one(w, &f, n, !whole && bits & M_SELF == 0)
			if changed {
				if old == nil || !inherited_equal(old, nc) || container_changed(old, nc) { inh_changed = true } else { other_changed = true }
				if f.parent == nil && (nc.font_size != s.root_font_size || used_line_height(nc, s.line_height_normal) != s.root_line_height) { w.root_font = true }
			}
			cur = nc
			if inh_changed && !sub && w.defer_big && subtree_over(doc, f.h, w.e.settings.inc_parallel_min) {
				child_bloom := f.bloom
				bloom_add_element(&child_bloom, n)
				for ch := dom.flat_first_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
					if is_element_node(doc, ch) { append(&w.deferred, Frame{h = ch, parent = cur, bloom = child_bloom, force = true, sub = true, ctx = child_ctx(w.p, f.h, f.ctx, ch)}) }
				}
				continue
			}
		} else {
			sib_pass_by(w.p, n, int(f.depth))
		}
		if !sub && !inh_changed && !other_changed && bits & M_CHILD == 0 { continue }
		if cur == nil { continue }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		for ch := dom.flat_last_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_prev(doc, ch) {
			cn := dom.get(doc, ch)
			if cn.kind != .Element { continue }
			cb := w.marks != nil ? mark_bits(w.marks, ch)^ : 0
			force := sub || inh_changed
			if !force && other_changed {
				// only non-inherited values changed: what takes them explicitly (`inherit`) follows
				co := base_style_of(s, ch)
				force = co == nil || !ps_empty(ps_intersect(co.inherits, noninh))
			}
			if force || cb != 0 { append(&stack, Frame{h = ch, parent = cur, bloom = child_bloom, force = force, sub = sub, whole = whole, ctx = child_ctx(w.p, f.h, f.ctx, ch), depth = f.depth + 1}) }
		}
	}
}

// More than `limit` elements under `h`.
@(private = "file")
subtree_over :: proc(doc: ^dom.Document, h: base.Handle, limit: int) -> bool {
	n := 0
	stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	append(&stack, h)
	for len(stack) > 0 {
		x := pop(&stack)
		for ch := dom.flat_first_child(doc, x); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
			if !is_element_node(doc, ch) { continue }
			n += 1
			if n > limit { return true }
			append(&stack, ch)
		}
	}
	return false
}

@(private = "file")
Par_Task :: struct {
	w:      Walker,
	frames: []Frame,
	arena:  ^base.Arena,
}

@(private = "file")
Par_Tasks :: struct {
	tasks: []Par_Task,
}

// Forced subtrees deferred by the walk, shared out between the threads of `pool`. The subtrees too big to be one task are
// opened on this thread: a page is rarely a balanced tree, and on cnn.com all that is under `<body>` went to one thread (4 300
// elements, 190 ms), the frontier having enough frames beside it to look shared out.
@(private = "file")
run_deferred :: proc(w: ^Walker, pool: ^host.Thread_Pool) {
	if len(w.deferred) == 0 { return }
	doc := w.doc
	s := w.s
	threads := host.thread_pool_size(pool)
	w.defer_subtrees, w.defer_forced, w.defer_big = false, false, false
	// subtrees restyled whole are opened until none is too big for a task; frames that only have to be restyled (marked, or
	// forced) go as they are, their walk below them being the thread's
	frontier := make([dynamic]Frame, 0, len(w.deferred), context.temp_allocator)
	alone := make([dynamic]Frame, 0, 8, context.temp_allocator)
	for f in w.deferred { if f.sub { append(&frontier, f) } else { append(&alone, f) } }
	sizes := flat_sizes(doc)
	weight_of :: proc(sizes: []i32, f: Frame) -> int { return f.sub ? max(int(sizes[base.handle_index(f.h)]), 1) : 1 }
	total := len(alone)
	for f in frontier { total += weight_of(sizes, f) }
	limit := max(total / (threads * 8), STYLE_SPLIT_MIN_ELEMENTS)
	for round := 0; len(frontier) > 0 && round < STYLE_SPLIT_MAX_ROUNDS; round += 1 {
		next := make([dynamic]Frame, 0, len(frontier) * 2, context.temp_allocator)
		opened := false
		for &f in frontier {
			if weight_of(sizes, f) <= limit { append(&next, f); continue }
			n := dom.get(doc, f.h)
			if n == nil || n.kind != .Element { continue }
			opened = true
			nc, _, _ := restyle_one(w, &f, n, !f.whole && (w.marks == nil || mark_bits(w.marks, f.h)^ & (M_SELF | M_SUB) == 0))
			child_bloom := f.bloom
			bloom_add_element(&child_bloom, n)
			for ch := dom.flat_first_child(doc, f.h); ch != base.NIL_HANDLE; ch = dom.flat_next(doc, ch) {
				if is_element_node(doc, ch) { append(&next, Frame{h = ch, parent = nc, bloom = child_bloom, force = true, sub = true, whole = f.whole || (w.marks != nil && mark_bits(w.marks, f.h)^ & M_SUB != 0), ctx = child_ctx(w.p, f.h, f.ctx, ch)}) }
			}
		}
		frontier = next
		if !opened { break }
	}
	append(&frontier, ..alone[:])
	if len(frontier) == 0 { return }
	// every slot a thread may write exists beforehand: the array does not move while they run
	styled_size(s, int(doc.nodes.used))
	if s.state.controls.settle != nil { s.state.controls.settle(s.state.controls.user) }   // (their queries only read, as in a full pass)
	weights := make([]int, len(frontier), context.temp_allocator)
	for f, i in frontier { weights[i] = weight_of(sizes, f) }
	ranges := ranges_by_weight(weights, threads)
	count := len(ranges)
	job := Par_Tasks{tasks = make([]Par_Task, count, context.temp_allocator)}
	for i in 0 ..< count {
		t := &job.tasks[i]
		t.frames = frontier[ranges[i][0]:ranges[i][1]]
		task_weight := 0
		for x in weights[ranges[i][0]:ranges[i][1]] { task_weight += x }
		w.e.last_restyle.largest_task = max(w.e.last_restyle.largest_task, task_weight)
		t.w = Walker{e = w.e, s = s, doc = doc, task = true, marks = w.marks}   // (the marks are only read meanwhile)
		t.arena = thread_arena_take(w.e)
	}
	host.parallel_for(pool, count, proc(data: rawptr, i: int) {
		job := (^Par_Tasks)(data)
		t := &job.tasks[i]
		thread_arena_begin(t.arena)
		t.w.p = pass_make(t.w.e, t.w.s, t.w.doc, t.w.s.state)
		t.w.p.alloc = style_arena_allocator(t.arena)
		t.w.arena = t.arena
		t.w.results = make([dynamic]Result)
		walk(&t.w, t.frames)
	}, &job)
	w.e.last_restyle.parallel = true
	for &t in job.tasks {
		append(&s.thread_arenas, t.arena)
		s.partial_bytes += int(t.arena.total_used)
		w.p.matched_taken += t.w.p.matched_taken
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
	if s.mutations == doc.mutations && !e.shadow.dirty && len(e.shadow.changed) == 0 && len(e.controls_changed) == 0 { return false, true }
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
	// what was inserted alone is more than a partial restyle may take: a full pass, without the marking that would find it
	// out (on a page that rebuilds a list of 2 500 items every frame, the marking cost twice the full pass)
	limit := f64(e.settings.inc_max_ratio) * f64(max(doc.nodes.count, 1))
	if !shadows && !trace_restyle() && inserted_exceed(doc, entries, limit) { return fail(e, "too much changed") }
	if f64(len(entries)) > limit { return fail(e, "too much changed") }   // (whatever they are: the elements alone were not, among the parser's text nodes)
	exact := false   // the members of the exact :has() anchors are of the document before these mutations (watch_sync was made by a pass that came before)
	if !shadows && ix.uses_has { exact = !watch_sync(ix, doc) }

	class_bits_begin(e, doc, s.mutations, entries)
	defer e.class_bits_live = false
	m := Marker{e = e, s = s, doc = doc, ix = ix, shadows = shadows}
	m.marks = make([]u8, int(doc.nodes.used), context.temp_allocator)
	m.marked = make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	m.removed = make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	m.walked = make(map[Walk_Key]bool, 16, context.temp_allocator)
	m.emptied = make(map[Walk_Key]bool, 4, context.temp_allocator)
	m.of_walked = make(map[Of_Walk_Key]bool, 4, context.temp_allocator)
	m.flips = make(map[Flip_Key]bool, 16, context.temp_allocator)
	m.has_walked = make(map[Has_Walk_Key]int, 16, context.temp_allocator)
	match_ctx_init(&m.mc, doc, s.state, context.temp_allocator)
	m.mc.max_steps = e.settings.match_max_steps
	m.mc.class_bits = e.class_bits[:]
	w := Walker{e = e, s = s, doc = doc, marks = m.marks}
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
	m.flip_limit = max(int(limit), FLIP_LIMIT_MIN)
	members_prepare(&m, entries)
	mark_mutations(&m, entries)
	for h in e.controls_changed {
		if m.fail != "" { break }
		control_changed(&m, h)
	}
	if m.fail == "" { marks_keyed_scan(&m) }
	e.last_restyle.flips = len(m.flips)
	e.last_restyle.flip_steps = m.flip_steps
	e.last_restyle.nth_of_steps = m.of_tested
	if m.fail != "" { return fail(e, m.fail) }
	work := estimate(&m, limit)
	if f64(work) > limit {
		if trace_restyle() { trace_marks(&m, work, entries) }
		return fail(e, "too much changed")
	}

	members_commit(&m)
	if !shadows && ix.uses_has && ix.watched == doc && ix.watched_gen == doc.journal.watch.gen {
		w.p.mc.has_known, w.p.mc.has_known_user = has_answer, &m
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
			if styled_drop(s, x) { delete_key(&s.overlaid, x) }
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			if n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }
		}
	}
	if m.removed_any { s.removed_any = true }

	w.defer_big = pool != nil && host.thread_pool_size(pool) > 1
	w.defer_subtrees = w.defer_big && work >= e.settings.inc_parallel_min
	w.defer_forced = w.defer_subtrees   // (marked one by one, a third of a document on this thread cost more than a full pass on all of them)
	if len(m.marked) > 0 {
		start := make([dynamic]Frame, 0, 4, context.temp_allocator)
		root := dom.get(doc, doc.root)
		for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
			if mark_bits(m.marks, ch)^ != 0 { append(&start, Frame{h = ch}) }
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
				if styled_drop(s, x) {
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
	clear(&e.controls_changed)
	e.last_restyle.has_scans = w.p.mc.has_scans
	e.last_restyle.has_steps = w.p.mc.has_steps
	e.last_restyle.marked = w.marked
	e.last_restyle.taken = w.p.matched_taken
	e.last_restyle.changed = w.changed
	e.last_restyle.rewalked = rewalked
	if w.root_font {
		// rem lengths everywhere follow the root's font size: only a full pass gets them right; what was done is
		// harmless (records replaced as a full pass would), and the caller now does one
		s.mutations = 0
		e.last_restyle.fallback = "root font size changed"
		styled_superseded(s)
		return w.changed > 0, false
	}
	if w.changed > 0 {
		s.serial = styled_next_serial()
		if w.layout_changed { s.layout_serial = s.serial }
		journal_stamp(s)
		update_canvas(s, doc)
	}
	return w.changed > 0, true
}

// A partial pass replaced records and hands over to a full one, which compares its records with these: what it replaced would
// be in no journal, and a layout that read the serial before it would hear of nothing (the root's font, once on npr.org). The serial
// moves: that reader is older than what the full pass's journal is complete for.
// (The transitions hear of it from `changes`: timeline_restyled.)
@(private)
styled_superseded :: proc(s: ^Styled) {
	s.serial = styled_next_serial()
}

// Restyles `roots` in place: elements whose own rules changed and that no rule change reaches below (the elements that a flipped
// @media block matches, media_gate.odin). Each is computed again; its children only where what it inherits changed (or where
// they take a changed value explicitly), as after a DOM change. `p`: a pass of `s` (it is not destroyed here). ok = false: it
// cannot be scoped (the root font size changed) and the caller makes a full pass; `changed`: some computed style differs.
restyle_roots :: proc(e: ^Engine, doc: ^dom.Document, s: ^Styled, p: ^Pass, roots: []base.Handle, pool: ^host.Thread_Pool = nil) -> (changed: bool, ok: bool) {
	marks := make([]u8, int(doc.nodes.used), context.temp_allocator)
	for h in roots {
		mark_bits(marks, h)^ |= M_SELF
		for a := flat_parent_element(doc, h); a != base.NIL_HANDLE; a = flat_parent_element(doc, a) {
			b := mark_bits(marks, a)
			if b^ & M_CHILD != 0 { break }
			b^ |= M_CHILD
		}
	}
	w := Walker{e = e, s = s, doc = doc, p = p, arena = &s.arena, marks = marks}
	w.defer_big = pool != nil && host.thread_pool_size(pool) > 1
	w.defer_forced = w.defer_big && len(roots) >= e.settings.media_parallel_min
	w.defer_subtrees = w.defer_forced
	start := make([dynamic]Frame, 0, 4, context.temp_allocator)
	top := dom.get(doc, doc.root)
	for ch := top.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
		if mark_bits(marks, ch)^ != 0 { append(&start, Frame{h = ch}) }
	}
	walk(&w, start[:])
	run_deferred(&w, pool)
	delete(w.deferred)
	e.last_restyle.marked, e.last_restyle.changed = w.marked, w.changed
	e.last_restyle.taken = p.matched_taken
	if w.root_font {
		e.last_restyle.fallback = "root font size changed"
		styled_superseded(s)
		return w.changed > 0, false
	}
	if w.rewalk {
		if counters_refresh(s, doc, e.settings.counters_max_listed) { w.changed += 1; w.layout_changed = true }
		e.last_restyle.rewalked = true
	}
	if w.motion { sync.atomic_store(&s.motion, true) }
	e.last_restyle.changed = w.changed
	if w.changed > 0 {
		s.serial = styled_next_serial()
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
	// the record of `h` with the resolved values `now` (a copy when they differ from what it has)
	apply_values :: proc(s: ^Styled, h: base.Handle, c: ^Computed, sv, now: Saved) -> bool {
		same := sv.marker == now.marker
		for k in 0 ..< 3 { if !content_items_equal(sv.items[k], now.items[k]) { same = false } }
		if same { return false }
		a := s.alloc
		nc := new(Computed, a)
		nc^ = c^
		nc.marker_text = strings.clone(now.marker, a)
		nc.content.items = clone_items(now.items[0], a)
		if c.before != nil { nb := new(Computed, a); nb^ = c.before^; nb.content.items = clone_items(now.items[1], a); nc.before = nb }
		if c.after != nil { na := new(Computed, a); na^ = c.after^; na.content.items = clone_items(now.items[2], a); nc.after = na }
		old := s.by_node[int(base.handle_index(h))]
		if s.track_changes { append(&s.changes, Style_Change{node = h, old = old, new = nc}) }
		journal_add(s, h, .Box)
		delete_key(&s.overlaid, h)
		styled_put(s, h, nc)
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
		// (constructed sheets have no owner: they come and go with adoptedStyleSheets; nor do a FontFace's or an
		// extension's, which no removal takes away)
		for sh in e.sheets { if sh.origin == .Author && !sh.constructed && sh.owner != base.NIL_HANDLE && !connected(doc, sh.owner) { return true } }
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
							for f in computed_fields {
								pa, pb := rawptr(group_base(a, f.group) + f.offset), rawptr(group_base(b, f.group) + f.offset)
								same := f.plain ? mem.compare_ptrs(pa, pb, f.size) == 0 : deep_equal(pa, pb, f.ti)
								if same { continue }
								what = fmt.tprintf("field %s", f.name)
								if f.name == "custom" { what = fmt.tprintf("custom properties %s", custom_diff(a.custom, b.custom)) }
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
			// (a list is true or it is nil: a store that went full keeps none, and the two passes may stand either side of it)
			if sync.atomic_load(&s.matched_gen) == full.matched_gen {
				x, y := matched_of(s, h), matched_of(full, h)
				if x != nil && y != nil && !matched_same(x, y) {
					id, _ := attr(n, "id")
					cls, _ := attr(n, "class")
					return fmt.aprintf("<%s id=%q class=%q> (node %v): its list of matched rules differs: %d rules, expected %d", n.name, id, cls, h, len(x.rules), len(y.rules), allocator = allocator)
				}
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
	fa, fb := custom_flatten(a, context.temp_allocator), custom_flatten(b, context.temp_allocator)
	for k, v in fa {
		if w, ok := fb[k]; !ok || w != v { return fmt.tprintf("%s: %q, expected %q", k, v, ok ? w : "(none)") }
	}
	for k, w in fb {
		if _, ok := fa[k]; !ok { return fmt.tprintf("%s: missing, expected %q", k, w) }
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

@(private = "file")
Has_Walk_Key :: struct { ix: rawptr, at: base.Handle, change: Has_Change }

// An attribute named `name` changed: could it change whether an element matches the argument of `ha`?
@(private = "file")
arg_reads_attr :: proc(ha: ^Has_Anchor, name: string) -> bool {
	for sp in ha.arg.simples {
		switch sp.kind {
		case .Id: if name == "id" { return true }
		case .Class: if name == "class" { return true }
		case .Attribute: if base.ascii_equal_fold(sp.name, name) { return true }
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
		if ha.exact && ha.members != nil {
			any = true
			clear(&ha.members.added); clear(&ha.members.removed)
			ha.members.head_touched, ha.members.lost_held, ha.members.dirty = false, false, false   // (dirty is of this batch: left set, every later batch assumed a flip)
			if ha.first_mask != 0 {
				for &en in entries { if en.kind == .Attribute && compound_reads_attr(ha.cx.compounds[0], en.name) { ha.members.head_touched = true; break } }
			}
		}
	}
	if !any { return }
	doc := m.doc
	known_mask :: proc(ha: ^Has_Anchor) -> u64 { return ha.last_mask & ~dom.WATCH_KNOWN }
	keys: Members_Index
	ix.members_tested = 0
	for &en in entries {
		switch en.kind {
		case .Insert:
			n := dom.get(doc, en.node)
			if n == nil || n.kind != .Element || !connected(doc, en.node) { continue }
			if keys.by_class == nil { keys, _ = members_index_make(ix) }
			// one walk of what came, each element against the anchors of its own keys: anchor by anchor, a subtree of 500 elements
			// under a hundred anchors was as many answers, and a tenth of what a restyle cost on cnn.com
			Candidates :: struct { m: ^Marker, watched: u64 }
			c := Candidates{m, dom.subtree_watch(doc, en.node)}
			stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
			append(&stack, en.node)
			for len(stack) > 0 {
				x := pop(&stack)
				xn := dom.get(doc, x)
				if xn == nil || xn.kind != .Element { continue }
				members_candidates(&keys, x, xn, &c, proc(user: rawptr, x: base.Handle, list: []^Has_Anchor) {
					c := (^Candidates)(user)
					c.m.ix.members_tested += len(list)
					for ha in list {
						mask := ha.last_mask & ~dom.WATCH_KNOWN
						if c.watched & mask != mask { continue }   // a key of its argument is not in the subtree
						// (also one the set already had: it was taken out of the tree and put back, maybe somewhere else)
						if matches_compound(&c.m.mc, x, ha.arg) {
							ha.members.set[x] = {}
							append(&ha.members.added, x)
							if ha.first_mask != 0 { member_held(c.m, ha, x, true) }
						}
					}
				})
				for ch := xn.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
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
			if n == nil || n.kind != .Element || !has_reads_attr(ix, en.name) { continue }
			in_tree := connected(doc, en.node)
			for &ha in ix.has_anchors {
				m.flip_steps += 1
				if !ha.exact || ha.members == nil { continue }
				// an attribute the chain reads, on an element that has members below it: any answer may have flipped
				if ha.chain && !ha.members.dirty && chain_reads_change(&ha, &en, n) {
					ha.members.dirty = bit_at(members_above(m, &ha), en.node)
					if ha.members.dirty && trace_restyle() { trace_roots[fmt.aprintf("dirty by [%s] of <%s> %s -> %s", en.name, n.name, en.had_old ? en.old : "(none)", dom.get_attribute(doc, en.node, en.name) or_else "(none)")] += 1 }
				}
				if !arg_reads_attr(&ha, en.name) { continue }
				was := en.node in ha.members.set
				now := in_tree && matches_compound(&m.mc, en.node, ha.arg)
				if now && !was {
					ha.members.set[en.node] = {}
					append(&ha.members.added, en.node)
					if ha.first_mask != 0 { member_held(m, &ha, en.node, true) }
				} else if !now && was {
					delete_key(&ha.members.set, en.node)
					append(&ha.members.removed, n.parent)
					if en.node in ha.members.held { ha.members.lost_held = true; delete_key(&ha.members.held, en.node) }
				}
			}
		case .Text, .Reslot:
		}
	}
	// members taken out of the tree (removed with a subtree, destroyed): did one of them have a [role]-like head above it?
	for &ha in ix.has_anchors {
		if !ha.exact || ha.members == nil || ha.first_mask == 0 || len(ha.members.removed) == 0 { continue }
		gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
		for x in ha.members.held {
			if dom.get(doc, x) == nil || !connected(doc, x) { append(&gone, x) }
		}
		for x in gone { ha.members.lost_held = true; delete_key(&ha.members.held, x) }
	}
}

// Some :has() argument reads the attribute `name`: the journal of a page is mostly attributes none of them does.
@(private = "file")
has_reads_attr :: proc(ix: ^Inv_Index, name: string) -> bool {
	switch name {
	case "class": return len(ix.has_classes) > 0
	case "id": return len(ix.has_ids) > 0
	}
	return name in ix.has_attrs
}

// Whether member `x` of a two-compound chain has an element above it that matches the first compound, as of the document now (`moved`:
// x was in the set already, put back somewhere: where it was counts as lost).
@(private = "file")
member_held :: proc(m: ^Marker, ha: ^Has_Anchor, x: base.Handle, moved: bool) {
	mem := ha.members
	if moved && x in mem.held { mem.lost_held = true }
	if chain_head_above(&m.mc, m.doc, ha, dom.get(m.doc, x).parent) { mem.held[x] = {} } else { delete_key(&mem.held, x) }
}

// Once the mutations are marked: the members' standing under the first compound, taken again if an attribute it reads changed (an
// ancestor may have gained or lost it without any member coming or going).
@(private = "file")
members_commit :: proc(m: ^Marker) {
	ix := m.ix
	if m.shadows || !ix.uses_has || !m.exact { return }
	for &ha in ix.has_anchors {
		if !ha.exact || ha.members == nil || ha.first_mask == 0 || !(ha.members.head_touched || ha.members.dirty) { continue }
		clear(&ha.members.held)
		for x in ha.members.set {
			if dom.get(m.doc, x) != nil && connected(m.doc, x) { member_held(m, &ha, x, false) }
		}
	}
}

// Did the answer of `:has(arg)` of the anchor `a` change with the mutations of this pass? A member that was there and is there
// still under `a` (a child of it for :has(> arg)) settles it: true before and after. Else it is true now if some member that came is
// under `a`, and was true before if some member left from under it (a parent it left is `a` or below it; one already gone leaves the
// question open: a flip is assumed).
@(private = "file")
has_flip :: proc(m: ^Marker, ha: ^Has_Anchor, a: base.Handle) -> bool {
	trace_why = "none (not exact, or no members)"
	if ha.members.dirty { trace_why = "dirty"; return true }
	key := Flip_Key{ha, a}
	if r, ok := m.flips[key]; ok { return r }
	r := has_flip_scan(m, ha, a)
	m.flips[key] = r
	return r
}

// What has_flip asks of the members of an anchor for each element it is asked of, as bits by handle index, made once a batch: which
// elements have a member that stayed under them, one that came, a place one left. An answer for each ancestor of each change, each a
// walk of every member up to the root, was 0.5 to 1 s of cnn.com's partial passes.
@(private = "file")
Flip_Above :: struct {
	stayed, came, left: []u64,   // (child_only: of the parents alone)
	unknown_left: bool,          // a member left a place that is gone: not known where it was
	added: map[base.Handle]struct{},   // Has_Members.added
}

// Sets the bit of each element from `from` up (of `from` alone: `only`). Bits are set on the way to the root alone: an element not in the document says nothing.
@(private = "file")
bits_up :: proc(m: ^Marker, bits: []u64, from: base.Handle, only := false) {
	doc := m.doc
	stop := base.NIL_HANDLE
	for cur := from; cur != doc.root && cur != base.NIL_HANDLE; {
		m.flip_steps += 1
		n := dom.get(doc, cur)
		if n == nil { return }
		if bit_at(bits, cur) { stop = cur; break }
		cur = n.parent
		if cur == base.NIL_HANDLE { return }
	}
	if only { if from != stop && from != base.NIL_HANDLE { bit_set_at(bits, from) }; return }
	for cur := from; cur != stop && cur != base.NIL_HANDLE && cur != doc.root; cur = dom.get(doc, cur).parent { bit_set_at(bits, cur) }
}

// `:has(.a)` of an element being restyled, from the members of the anchor (Match_Ctx.has_known): they are those of the document as it
// is now, and which elements have one under them is a bit, found once a batch. A walk of the subtree for each list, for a rule with no
// other compound that every element is tried on, was a tenth of what a restyle cost on cnn.com.
@(private = "file")
has_answer :: proc(user: rawptr, anchor: base.Handle, list: css.Selector_List) -> (answer: bool, known: bool) {
	m := (^Marker)(user)
	if m.exact_lists == nil {
		m.exact_lists = make(map[rawptr]^Has_Anchor, len(m.ix.has_anchors), context.temp_allocator)
		for &ha in m.ix.has_anchors {
			if ha.exact && ha.members != nil { m.exact_lists[ha.list] = &ha }
		}
	}
	ha := m.exact_lists[raw_data(list)] or_return
	under := bit_at(members_above(m, ha), anchor)
	return under, !under || (!ha.chain && !ha.child_only)   // (a chain, or `:has(> .a)`, with a member somewhere below: only the walk says)
}

// The elements with a member of the anchor under them, as of this batch's start and what came since (Has_Members.dirty).
@(private = "file")
members_above :: proc(m: ^Marker, ha: ^Has_Anchor) -> []u64 {
	if bits, ok := m.above[ha]; ok { return bits }
	if m.above == nil { m.above = make(map[^Has_Anchor][]u64, 8, context.temp_allocator) }
	bits := make([]u64, (int(m.doc.nodes.used) + 63) / 64, context.temp_allocator)
	for x in ha.members.set {
		if n := dom.get(m.doc, x); n != nil { bits_up(m, bits, n.parent) }
	}
	m.above[ha] = bits
	return bits
}

@(private = "file")
flip_above_of :: proc(m: ^Marker, ha: ^Has_Anchor) -> ^Flip_Above {
	if f, ok := m.flip_above[ha]; ok { return f }
	if m.flip_above == nil { m.flip_above = make(map[^Has_Anchor]^Flip_Above, 8, context.temp_allocator) }
	doc := m.doc
	mem := ha.members
	words := (int(doc.nodes.used) + 63) / 64
	f := new(Flip_Above, context.temp_allocator)
	bits := make([]u64, 3 * words, context.temp_allocator)
	f.stayed, f.came, f.left = bits[:words], bits[words:2 * words], bits[2 * words:]
	f.added = make(map[base.Handle]struct{}, len(mem.added), context.temp_allocator)
	for x in mem.added {
		f.added[x] = {}
		if n := dom.get(doc, x); n != nil { bits_up(m, f.came, n.parent, ha.child_only) }
	}
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for x in mem.set {
		n := dom.get(doc, x)
		if n == nil { append(&gone, x); continue }
		if x not_in f.added { bits_up(m, f.stayed, n.parent, ha.child_only) }
	}
	for x in gone { delete_key(&mem.set, x) }
	for p in mem.removed {
		if dom.get(doc, p) == nil { f.unknown_left = true; continue }
		if ha.child_only { bit_set_at(f.left, p) } else {
			// (where the member left from may have left the document too: its ancestors are what it can tell)
			for cur := p; cur != base.NIL_HANDLE && !bit_at(f.left, cur); {
				m.flip_steps += 1
				bit_set_at(f.left, cur)
				cn := dom.get(doc, cur)
				if cn == nil { break }
				cur = cn.parent
			}
		}
	}
	m.flip_above[ha] = f
	return f
}

@(private = "file")
has_flip_scan :: proc(m: ^Marker, ha: ^Has_Anchor, a: base.Handle) -> bool {
	doc := m.doc
	mem := ha.members
	f := flip_above_of(m, ha)
	valid :: proc(m: ^Marker, x: base.Handle) -> bool { return dom.get(m.doc, x) != nil && connected(m.doc, x) }
	// x is under a (a child of it when child_only)
	under :: proc(m: ^Marker, ha: ^Has_Anchor, a, x: base.Handle) -> bool {
		xn := dom.get(m.doc, x)
		if xn == nil { return false }
		if ha.child_only { return xn.parent == a }
		return is_below(m.doc, x, a)
	}
	stayed := false
	if bit_at(f.stayed, a) {
		stayed = !ha.chain
		if ha.chain {
			for x in mem.set {
				if dom.get(doc, x) == nil || x in f.added || !valid(m, x) { continue }
				if under(m, ha, a, x) && chain_holds(m, ha, a, x) { stayed = true; break }
			}
		}
	}
	if stayed { return false }
	now := bit_at(f.came, a)
	if now && ha.chain {
		now = false
		for x in mem.added { if valid(m, x) && under(m, ha, a, x) && chain_holds(m, ha, a, x) { now = true; break } }
	}
	if now { trace_why = "a member came" }
	// (a two-compound chain: only a member that was under a head can have made the answer true, see Has_Members.held)
	before := (ha.first_mask == 0 || mem.lost_held) && (f.unknown_left || bit_at(f.left, a))
	if before { trace_why = "a member left" }
	return now != before
}

// Could the attribute change `en` on the element `n` ABOVE a member change what the chain of `ha` matches? A class attribute says which
// classes came and went: one rewritten with the same tokens (cnn.com, `layout  cnn` to `layout cnn` on <body>), or with others the chain
// does not name, changes nothing there.
@(private = "file")
chain_reads_change :: proc(ha: ^Has_Anchor, en: ^dom.Journal_Entry, n: ^dom.Node) -> bool {
	if !chain_reads_attr(ha, en.name) { return false }
	if en.name != "class" { return true }
	before := make(map[string]bool, 8, context.temp_allocator)
	now := make(map[string]bool, 8, context.temp_allocator)
	if en.had_old { each_class(en.old, &before) }
	if v, has := attr(n, "class"); has { each_class(v, &now) }
	for c in before { if c not_in now && chain_reads_class(ha, c) { return true } }
	for c in now { if c not_in before && chain_reads_class(ha, c) { return true } }
	return false
}

@(private = "file")
chain_reads_class :: proc(ha: ^Has_Anchor, class: string) -> bool {
	for comp in ha.cx.compounds[:len(ha.cx.compounds) - 1] { if compound_names_class(comp, class) { return true } }
	return false
}

@(private = "file")
compound_names_class :: proc(comp: css.Compound, class: string) -> bool {
	for sp in comp.simples {
		if sp.kind == .Class && sp.name == class { return true }
		if sp.list != nil { for &cx in sp.list^ { for c in cx.compounds { if compound_names_class(c, class) { return true } } } }
	}
	return false
}

// Could a change of attribute `name` on an element ABOVE a member change what the chain of `ha` matches? Only the compounds before
// the last one match ancestors of the member (the last is the member itself, whose attributes keep the members up to date): a
// class on the member (YouTube: `.ytwChannelBlocksViewModelHost` in `:has([role]:not([aria-hidden]) .ytwChannelBlocksViewModelHost)`)
// is not read on an ancestor, so a class change there restyled the whole document for nothing.
@(private = "file")
chain_reads_attr :: proc(ha: ^Has_Anchor, name: string) -> bool {
	if ha.cx == nil { return false }
	for comp in ha.cx.compounds[:len(ha.cx.compounds) - 1] { if compound_reads_attr(comp, name) { return true } }
	return false
}

@(private = "file")
compound_reads_attr :: proc(comp: css.Compound, name: string) -> bool {
	for sp in comp.simples {
		switch sp.kind {
		case .Id: if name == "id" { return true }
		case .Class: if name == "class" { return true }
		case .Attribute: if base.ascii_equal_fold(sp.name, name) { return true }
		case .Pseudo_Class:
			if sp.list != nil { for &cx in sp.list^ { for c in cx.compounds { if compound_reads_attr(c, name) { return true } } } }
		case .Type, .Universal, .Nesting:
		}
	}
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
	return chain_matches(&m.mc, x, ha.cx, a, false)
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
