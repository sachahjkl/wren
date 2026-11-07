package style

import "core:strings"
import "core:sync"
import "wb:base"
import "wb:css"
import "wb:dom"

// An invalidation chain with more steps than this becomes "all the next": a set that large filters little.
INV_MAX_NEXT :: 64
// How deep :is() inside :is() is followed for the keys a compound requires.
COMPOUND_KEYS_DEPTH :: 4

// Invalidation sets (in the spirit of Blink's and Stylo's): for every feature a selector can test on an element (a class,
// an id, an attribute, a tag, a structural or attribute-driven pseudo-class), which elements a change of that feature
// on an element E can make start or stop matching some rule. Built once per rebuild of the rule index, read by the
// restyle after DOM mutations (restyle_dom.odin).
//
// A selector `.a .b > .c ~ .d` read from a compound to the subject says how far the effect reaches: from `.a` (followed
// by descendant combinators) to E's descendants; from `.c` (followed by a sibling combinator) to E's following
// siblings and their subtrees. Selectors inside :is(), :not(), :where() and `&` compose their reach with the outer
// one; inside :has() a feature reaches up, to the anchors (ancestors and earlier siblings), handled separately; inside
// :nth-child(... of S) it reaches the siblings, both ways.

// Which elements, relative to the element E where a feature changed, may change their matching.
Reach :: struct {
	self:     bool,   // E
	desc:     bool,   // E's descendants
	next:     int,    // E's next `next` element siblings
	all_next: bool,   // all of E's following element siblings
	all_prev: bool,   // all of E's preceding element siblings
	sib_desc: bool,   // the siblings above with their descendants
	set:      u32,    // desc and sib_desc: only the elements the key set (subject_keys) names can be affected (0: any)
}

@(private)
reach_any :: proc(r: Reach) -> bool { return r.self || r.desc || r.next > 0 || r.all_next || r.all_prev }

// What an element's place among its siblings reaches, by the key its compound requires of that element: `.x:first-child .y`
// and `.x + .y .z` are looked at for the elements that carry `.x` alone. One union for all the rules of a page gave the reach of
// its widest rule to every element of every list: on cnn.com a <div> added to <body> marked every child of <body> whole, through
// `:last-child` compounds and `.zone--t-dark + .flex-experiment :is(...)`, a third of the document for a banner.
Keyed_Reach :: struct {
	by_class, by_id, by_tag: map[string]Reach,
	any:  Reach,   // compounds that require no key
	used: bool,    // something reaches
}

@(private = "file")
keyed_free :: proc(k: ^Keyed_Reach) {
	for key in k.by_class { delete(key) }
	for key in k.by_id { delete(key) }
	for key in k.by_tag { delete(key) }
	delete(k.by_class); delete(k.by_id); delete(k.by_tag)
}

// :is(), :where(), `&` of a parent's list, :nth-child(... of S): the element is one of the alternatives.
@(private = "file")
simple_alternatives :: proc(s: ^css.Simple) -> bool {
	if s.list == nil || len(s.list^) == 0 { return false }
	if s.kind == .Nesting { return true }
	return s.kind == .Pseudo_Class && (s.pseudo == .Is || s.pseudo == .Where || s.pseudo == .Nth_Child || s.pseudo == .Nth_Last_Child)
}

// `comp` requires a key of the element: a class, an id, a type, or one in each alternative of an :is().
@(private = "file")
compound_keyed :: proc(comp: css.Compound, depth := 0) -> bool {
	if depth > COMPOUND_KEYS_DEPTH { return false }
	for &s in comp.simples {
		#partial switch s.kind {
		case .Class, .Id, .Type: return true
		}
		if simple_alternatives(&s) && list_keyed(s.list^, depth) { return true }
	}
	return false
}

@(private = "file")
list_keyed :: proc(list: css.Selector_List, depth: int) -> bool {
	for &c in list {
		if len(c.compounds) == 0 || !compound_keyed(c.compounds[len(c.compounds) - 1], depth + 1) { return false }
	}
	return true
}

@(private = "file")
keyed_add :: proc(ix: ^Inv_Index, k: ^Keyed_Reach, comp: css.Compound, r: Reach) {
	k.used = true
	if compound_keyed(comp) { keyed_put(ix, k, comp, r) } else { k.any = reach_union(ix.keys, k.any, r) }
}

// (`comp` is keyed: compound_keyed)
@(private = "file")
keyed_put :: proc(ix: ^Inv_Index, k: ^Keyed_Reach, comp: css.Compound, r: Reach) {
	best: ^css.Simple
	for &s in comp.simples {
		#partial switch s.kind {
		case .Id: best = &s
		case .Class: if best == nil || best.kind == .Type { best = &s }
		case .Type: if best == nil { best = &s }
		}
	}
	if best != nil {
		#partial switch best.kind {
		case .Id: merge(ix, &k.by_id, best.name, r)
		case .Class: merge(ix, &k.by_class, best.name, r)
		case .Type: merge(ix, &k.by_tag, best.name, r)
		}
		return
	}
	for &s in comp.simples {
		if !simple_alternatives(&s) || !list_keyed(s.list^, 0) { continue }
		for &c in s.list^ { keyed_put(ix, k, c.compounds[len(c.compounds) - 1], r) }
		return
	}
}

@(private)
reach_union :: proc(ks: ^Key_Sets, a, b: Reach) -> Reach {
	r := Reach{
		self = a.self || b.self, desc = a.desc || b.desc, next = max(a.next, b.next), all_next = a.all_next || b.all_next,
		all_prev = a.all_prev || b.all_prev, sib_desc = a.sib_desc || b.sib_desc,
	}
	sa, sb := a.desc || a.sib_desc, b.desc || b.sib_desc
	switch {
	case sa && sb: r.set = key_sets_union(ks, a.set, b.set)
	case sa: r.set = a.set
	case sb: r.set = b.set
	}
	return r
}

// Reach of `outer` (from an element X to the final subject) applied to every element `inner` reaches from E (X).
@(private)
reach_compose :: proc(inner, outer: Reach) -> Reach {
	out: Reach
	if inner.self { out = outer }
	if inner.desc { out.desc = true }   // descendants, their descendants and their siblings: all inside E's subtree
	sibs := inner.next > 0 || inner.all_next || inner.all_prev
	if sibs {
		if outer.self || outer.desc || outer.sib_desc {
			out.next = max(out.next, inner.next)
			out.all_next ||= inner.all_next
			out.all_prev ||= inner.all_prev
			if outer.desc || outer.sib_desc { out.sib_desc = true }
		}
		if outer.next > 0 || outer.all_next || outer.all_prev {
			out.next = max(out.next, inner.next + outer.next)
			out.all_next ||= inner.all_next || outer.all_next
			out.all_prev ||= inner.all_prev || outer.all_prev
			if outer.all_prev { out.all_next = true }   // a preceding sibling of a following one may be anywhere
			if outer.sib_desc { out.sib_desc = true }
		}
	}
	if inner.sib_desc { out.sib_desc = true }
	if out.next > INV_MAX_NEXT { out.next, out.all_next = 0, true }
	if out.desc || out.sib_desc { out.set = outer.set }   // (whatever it reaches, the subject is the outer selector's)
	return out
}

// From compound k of `c` to its subject.
@(private)
reach_from :: proc(c: ^css.Complex, k: int) -> Reach {
	last := len(c.compounds) - 1
	if k >= last { return Reach{self = true} }
	r: Reach
	for j in k ..< last {
		switch c.combinators[j] {
		case .Descendant, .Child:
			if r.next > 0 || r.all_next { r.sib_desc = true } else { r.desc = true }
		case .Next_Sibling:
			if !r.desc && !r.sib_desc { r.next += 1 }
		case .Subsequent_Sibling:
			if !r.desc && !r.sib_desc { r.all_next = true }
		}
	}
	if r.next > INV_MAX_NEXT { r.next, r.all_next = 0, true }
	return r
}

// A compound with :has(): the anchor it tests, and how far a change of the anchor's matching reaches.
@(private)
Has_Anchor :: struct {
	compound: css.Compound,
	around:   css.Compound,   // `.a:not(:has(.b))`: the compound around the :not(), :is() or :where() that holds this one: the same element, which must match it too
	list:     rawptr,   // the argument of its :has(), as matches_has is asked it
	reach:    Reach,
	feat:     Has_Feat,
	hops:     int,   // how many levels above a changed element the anchor can be (-1: any: the argument has a descendant combinator)
	// :has(<compound>) or :has(> <compound>) of tags, ids, classes and attributes only: whether the anchor matches is whether some
	// element under it (a child) matches the compound, so the elements that do are kept (members) and a change of the tree or of
	// attributes restyles the anchor's subtree only if the answer flipped (restyle_dom.odin has_flip), not at every insertion of
	// an element that holds the feature (YouTube: :has(yt-icon-shape) ..., restyled the whole page about as often as it changed)
	// A chain (:has([role] .x), :has(.a > .b:not([hidden])): compounds joined by descendant and child combinators) keeps the elements
	// that match its last compound; the others must be tested against the chain (match_chain) and a change of an attribute the chain
	// reads on an ancestor of a member may flip the answer without a member coming or going (Has_Members.dirty).
	exact:      bool,
	child_only: bool,
	chain:      bool,
	cx:         ^css.Complex,
	arg:        css.Compound,    // the last compound
	last_mask:  u64,             // its keys in the document's Watch
	// A chain of two compounds (`:has([role]:not([aria-hidden]) .x)`): the keys the first one requires, in the Watch. A member removed
	// from a subtree that held none of them, and with no element above that matches the first compound, was not part of an answer that
	// was true (restyle_dom.odin members_prepare). 0: not such a chain, or no key to test.
	first_mask: u64,
	members:    ^Has_Members,
}

Has_Members :: struct {
	set:     map[base.Handle]struct{},   // the elements that match the argument, as of the last pass (those gone or detached are dropped when met)
	added:   [dynamic]base.Handle,       // this batch of mutations: members that came (inserted subtrees, attributes that now match)
	removed: [dynamic]base.Handle,       // this batch: the parents members may have left (a removed subtree that held the features, an attribute that stopped matching)
	dirty:   bool,                       // this batch: an attribute the chain reads changed on an ancestor of a member: any answer may have flipped
	// Two-compound chains (first_mask != 0): the members that had an element matching the first compound above them as of the end of the
	// previous batch (an over-approximation of "the answer was true because of this member"). A member that leaves (removed, moved,
	// no longer matching) and was not in it cannot have flipped an answer from true to false: `:has([role]:not([aria-hidden]) .x)`
	// on YouTube has members that come and go without ever being under a [role], and each departure restyled the whole page.
	held:         map[base.Handle]struct{},
	lost_held:    bool,                  // this batch: a member that was in `held` left
	head_touched: bool,                  // this batch: an attribute the first compound reads changed somewhere (held is taken again once the batch is done)
}

// Does `p` or one of its ancestors match the first compound of the two-compound chain of `ha`? (A parent already destroyed: unknown, yes.)
@(private)
chain_head_above :: proc(mc: ^Match_Ctx, doc: ^dom.Document, ha: ^Has_Anchor, p: base.Handle) -> bool {
	for cur := p; cur != base.NIL_HANDLE; {
		n := dom.get(doc, cur)
		if n == nil { return true }
		if n.kind == .Element && matches_compound(mc, cur, ha.cx.compounds[0]) { return true }
		cur = n.parent
	}
	return false
}

// The features the :has() argument of one anchor tests: a change of any other feature of an element under the anchor
// cannot change whether the anchor matches.
Has_Feat :: struct {
	classes, ids, attrs, types: map[string]bool,
	mask:     u64,    // their bits of the document's dom.Watch (watch_sync): a subtree that holds none of them cannot make the anchor match
	unkeyed:  bool,   // the argument also asks something a key does not name (*, :not(), :nth-child(), a sibling combinator): any element may change it
	sibling:  bool,   // the argument has a sibling combinator: the anchor may stand before what changed, or before one of its ancestors (the others are read up the ancestors alone)
	empty:    bool,   // the argument reads :empty: a change of text under the anchor may change it
}

Inv_Index :: struct {
	rebuilds:   u64,                // the engine rebuild this was made for
	keys:       ^Key_Sets,          // the engine's: what the sets of its reaches are numbers in
	watched:    ^dom.Document,      // the document whose Watch has the features of the anchors (watch_sync), and its generation
	watched_gen: u32,
	ready:      bool,
	by_class:   map[string]Reach,
	by_id:      map[string]Reach,
	by_attr:    map[string]Reach,   // attribute name (lower case): attribute selectors and pseudo-classes that read it
	by_tag:     map[string]Reach,   // for inserted elements: what their tag makes them match beyond themselves
	keyless:    Reach,              // compounds with no class, id, attribute or tag: any element may match them; what they reach among siblings
	pos_fwd:    Keyed_Reach,        // :nth-child(), :first-of-type... (index from the start): applied from each sibling
	edge_first: Keyed_Reach,        // :first-child, :only-child: only what stands first among the siblings can see a change (edges_changed)
	edge_last:  Keyed_Reach,        // :last-child, :only-child
	pos_bwd:    Keyed_Reach,        // :nth-last-child(), :last-of-type... (index from the end)
	empty:      Reach,              // :empty (and :placeholder-shown of a textarea): applied from the parent
	sib_rel:    Keyed_Reach,        // the element right of a sibling combinator: applied from the next sibling of an insertion or a removal
	controls:   Reach,              // pseudo-classes answered by the forms model: applied from any element whose attributes change
	uses_controls: bool,
	// ... some of them answer for one control from others (its radio group, its form's controls): :checked,
	// :indeterminate, :default, :valid / :invalid / :user-valid / :user-invalid (a form or fieldset matches from its
	// controls). Without these, a control inserted, removed or changed restyles only itself and its subtree.
	uses_control_groups: bool,
	uses_has:   bool,
	has_anchors: [dynamic]Has_Anchor,
	members_tested: int,            // the last walk for the anchors' members: how many times an element was tested against an argument
	collect:    ^Has_Feat,          // while an anchor's :has() argument is analyzed: where its features are noted too
	around:     css.Compound,       // while the list of a :not(), :is() or :where() is analyzed: the compound that holds it (Has_Anchor.around)
	has_classes, has_ids, has_attrs: map[string]bool,   // features tested inside :has()
	has_sibling: bool,              // :has() arguments reach siblings (anchors include earlier siblings)
	has_empty:  bool,               // :empty or :placeholder-shown inside :has()
	give_up:    bool,               // selectors nested too deep to analyse: every DOM change restyles everything
}

@(private)
inv_free :: proc(ix: ^Inv_Index) {
	for k in ix.by_class { delete(k) }
	for k in ix.by_id { delete(k) }
	for k in ix.by_attr { delete(k) }
	for k in ix.by_tag { delete(k) }
	for k in ix.has_classes { delete(k) }
	for k in ix.has_ids { delete(k) }
	for k in ix.has_attrs { delete(k) }
	delete(ix.by_class); delete(ix.by_id); delete(ix.by_attr); delete(ix.by_tag)
	keyed_free(&ix.pos_fwd); keyed_free(&ix.pos_bwd); keyed_free(&ix.edge_first); keyed_free(&ix.edge_last); keyed_free(&ix.sib_rel)
	delete(ix.has_classes); delete(ix.has_ids); delete(ix.has_attrs)
	for &ha in ix.has_anchors {
		for k in ha.feat.classes { delete(k) }
		for k in ha.feat.ids { delete(k) }
		for k in ha.feat.attrs { delete(k) }
		for k in ha.feat.types { delete(k) }
		if ha.members != nil { delete(ha.members.set); delete(ha.members.added); delete(ha.members.removed); delete(ha.members.held); free(ha.members) }
		delete(ha.feat.classes); delete(ha.feat.ids); delete(ha.feat.attrs); delete(ha.feat.types)
	}
	delete(ix.has_anchors)
	ix^ = {}
}

@(private = "file")
merge :: proc(ix: ^Inv_Index, m: ^map[string]Reach, key: string, r: Reach) {
	if old, ok := m[key]; ok { m[key] = reach_union(ix.keys, old, r); return }
	m[strings.clone(key)] = r
}

@(private = "file")
flag :: proc(m: ^map[string]bool, key: string) {
	if key not_in m { m[strings.clone(key)] = true }
}

@(private = "file")
MAX_DEPTH :: 16

// The pseudo-attribute a change of an element's custom states (ElementInternals.states, :state()) is journaled as
// (dom.custom_state_changed).
STATE_ATTRIBUTE :: dom.CUSTOM_STATE_ATTRIBUTE

// The invalidation index of the engine's current rules, built when the rules changed since the last call.
inv_index :: proc(e: ^Engine) -> ^Inv_Index { return inv_index_of(e, &e.rules) }

// The invalidation index of a rule set: the document's (rebuilt with the engine's rules) or a shadow tree's (made once
// per compiled set). The rules of a shadow tree that reach out of it are read as what they affect inside the tree
// whose elements' features they test: `:host(.a) .b` and `:host(.a)` from the host (its features are the host's, its
// reach the host and its flat subtree); `slot.x::slotted(.y)` as `slot.x > .y` (the slot's features reach its flat
// children, the slotted element's reach itself); `x-a.on::part(p)` as `x-a.on *` (the host's features reach its
// shadow tree).
inv_index_of :: proc(e: ^Engine, rs: ^Rule_Set) -> ^Inv_Index {
	ix := &rs.inv
	gen := rs == &e.rules ? e.rebuilds : rs.gen
	if ix.ready && ix.rebuilds == gen { return ix }
	inv_free(ix)
	ix.rebuilds = gen
	ix.ready = true
	ix.keys = &e.key_sets
	ix.has_anchors = make([dynamic]Has_Anchor)
	inv_visit_index(ix, &rs.index)
	inv_visit(ix, rs.host_entries)
	for &ent in rs.slotted_entries {
		analyze_complex(ix, ent.complex, Reach{desc = true}, false, 0)
		if ent.complex.slotted != nil { analyze_compound(ix, ent.complex.slotted^, Reach{self = true}) }
	}
	for &ent in rs.part_entries { analyze_complex(ix, ent.complex, Reach{desc = true}, false, 0) }
	return ix
}

@(private = "file")
inv_visit :: proc(ix: ^Inv_Index, list: [dynamic]Entry) {
	for &ent in list { analyze_complex(ix, ent.complex, Reach{self = true, set = subject_keys(ix.keys, ent.complex)}, false, 0) }
}

@(private = "file")
inv_visit_index :: proc(ix: ^Inv_Index, index: ^Index) {
	for _, l in index.by_id { inv_visit(ix, l) }
	for _, l in index.by_class { inv_visit(ix, l) }
	for _, l in index.by_tag { inv_visit(ix, l) }
	for _, l in index.by_attr { inv_visit(ix, l) }
	for _, l in index.by_attr_name { inv_visit(ix, l) }
	inv_visit(ix, index.root)
	inv_visit(ix, index.universal)
	inv_visit(ix, index.backdrop)
}

// The document's rules grew by the entries of `fresh` (sheet_arrival.odin): what they reach joins what the index holds, which is a
// union of what each entry reaches. New :has() anchors have their elements found again.
@(private)
inv_extend :: proc(e: ^Engine, fresh: ^Index) {
	ix := &e.rules.inv
	if !ix.ready || ix.rebuilds + 1 != e.rebuilds { return }   // (not made, or not for the rules before these: it is made when asked for)
	ix.rebuilds = e.rebuilds
	anchors := len(ix.has_anchors)
	inv_visit_index(ix, fresh)
	if len(ix.has_anchors) > anchors { ix.watched = nil }
}

// watch_prepare, when the rules' :has() anchors are not those the document's Watch has.
watch_refresh :: proc(e: ^Engine, doc: ^dom.Document) {
	if ix := &e.rules.inv; ix.ready && ix.rebuilds == e.rebuilds && ix.watched == doc { return }
	watch_prepare(e, doc)
}

@(private = "file")
analyze_compound :: proc(ix: ^Inv_Index, comp: css.Compound, total: Reach) {
	keyed := false
	for &s in comp.simples { if analyze_simple(ix, &s, comp, total, false, 0) { keyed = true } }
	if !keyed && !compound_keyed(comp) { keyless_add(ix, total) }
}

// An element that comes or goes is restyled itself with what it holds: of a compound any element may match, what is kept is what it reaches
// among its siblings (the subjects of .a * next to it would leave no set for those of :not(.b) ~ .c .d).
@(private = "file")
keyless_add :: proc(ix: ^Inv_Index, r: Reach) {
	r := r
	r.self, r.desc = false, false
	if !r.sib_desc { r.set = 0 }
	if reach_any(r) { ix.keyless = reach_union(ix.keys, ix.keyless, r) }
}

@(private = "file")
analyze_list :: proc(ix: ^Inv_Index, list: ^css.Selector_List, outer: Reach, in_has: bool, depth: int) {
	if list == nil { return }
	if depth > MAX_DEPTH { ix.give_up = true; return }
	for &c in list^ { analyze_complex(ix, &c, outer, in_has, depth + 1) }
}

@(private = "file")
analyze_complex :: proc(ix: ^Inv_Index, c: ^css.Complex, outer: Reach, in_has: bool, depth: int) {
	if depth > MAX_DEPTH { ix.give_up = true; return }
	// (`:not(.a :has(.b))`: the anchor is an element above the one the compound around it matches)
	around := ix.around
	defer ix.around = around
	if len(c.compounds) > 1 { ix.around = {} }
	if in_has {
		if c.relative && (c.leading == .Next_Sibling || c.leading == .Subsequent_Sibling) { has_reads_siblings(ix) }
		for cb in c.combinators { if cb == .Next_Sibling || cb == .Subsequent_Sibling { has_reads_siblings(ix) } }
	}
	for j in 0 ..< len(c.combinators) {
		if !in_has && (c.combinators[j] == .Next_Sibling || c.combinators[j] == .Subsequent_Sibling) {
			keyed_add(ix, &ix.sib_rel, c.compounds[j + 1], reach_compose(reach_from(c, j + 1), outer))
		}
	}
	for k in 0 ..< len(c.compounds) {
		total := reach_compose(reach_from(c, k), outer)
		comp := c.compounds[k]
		keyed := false
		for &s in comp.simples {
			if analyze_simple(ix, &s, comp, total, in_has, depth) { keyed = true }
		}
		if !keyed && !in_has && !compound_keyed(comp) { keyless_add(ix, total) }
		if !keyed && in_has && ix.collect != nil && !compound_keyed(comp) { ix.collect.unkeyed = true }
	}
}

// `:nth-child(1)` and `:nth-last-child(1)`: :first-child and :last-child by another name.
@(private = "file")
nth_of_the_edge :: proc(s: ^css.Simple) -> bool {
	return (s.pseudo == .Nth_Child || s.pseudo == .Nth_Last_Child) && s.list == nil && s.nth_a == 0 && s.nth_b == 1
}

// Records what a change of `s` reaches. Returns whether `s` is a key feature (class, id, attribute, tag).
@(private = "file")
analyze_simple :: proc(ix: ^Inv_Index, s: ^css.Simple, comp: css.Compound, total: Reach, in_has: bool, depth: int) -> bool {
	attr_dep :: proc(ix: ^Inv_Index, name: string, r: Reach, in_has: bool) {
		if in_has { flag(&ix.has_attrs, name); if ix.collect != nil { flag(&ix.collect.attrs, name) } } else { merge(ix, &ix.by_attr, name, r) }
	}
	subtree := reach_compose(Reach{self = true, desc = true}, total)   // read on an ancestor too (lang, dir, fieldset)
	switch s.kind {
	case .Type:
		if !in_has { merge(ix, &ix.by_tag, s.name, total) } else if ix.collect != nil { flag(&ix.collect.types, s.name) }
		return true
	case .Universal:
	case .Id:
		if in_has { flag(&ix.has_ids, s.name); if ix.collect != nil { flag(&ix.collect.ids, s.name) } } else { merge(ix, &ix.by_id, s.name, total) }
		return true
	case .Class:
		if in_has { flag(&ix.has_classes, s.name); if ix.collect != nil { flag(&ix.collect.classes, s.name) } } else { merge(ix, &ix.by_class, s.name, total) }
		return true
	case .Attribute:
		attr_dep(ix, s.name, total, in_has)
		return true
	case .Nesting:
		analyze_list(ix, s.list, total, in_has, depth)
	case .Pseudo_Class:
		#partial switch s.pseudo {
		case .First_Child:
			if !in_has { keyed_add(ix, &ix.edge_first, comp, total) }
		case .Last_Child:
			if !in_has { keyed_add(ix, &ix.edge_last, comp, total) }
		case .Only_Child:
			if !in_has {
				keyed_add(ix, &ix.edge_first, comp, total)
				keyed_add(ix, &ix.edge_last, comp, total)
			}
		case .Nth_Child, .First_Of_Type, .Nth_Of_Type:
			if !in_has { keyed_add(ix, nth_of_the_edge(s) ? &ix.edge_first : &ix.pos_fwd, comp, total) }
			if s.list != nil { analyze_list(ix, s.list, reach_compose(Reach{self = true, all_next = true, all_prev = true}, total), in_has, depth) }
		case .Nth_Last_Child, .Last_Of_Type, .Nth_Last_Of_Type:
			if !in_has { keyed_add(ix, nth_of_the_edge(s) ? &ix.edge_last : &ix.pos_bwd, comp, total) }
			if s.list != nil { analyze_list(ix, s.list, reach_compose(Reach{self = true, all_next = true, all_prev = true}, total), in_has, depth) }
		case .Only_Of_Type:
			if !in_has {
				keyed_add(ix, &ix.pos_fwd, comp, total)
				keyed_add(ix, &ix.pos_bwd, comp, total)
			}
		case .Empty:
			if in_has { has_reads_empty(ix) } else { ix.empty = reach_union(ix.keys, ix.empty, total) }
		case .Not, .Is, .Where:
			saved := ix.around
			if len(saved.simples) == 0 { ix.around = comp }
			analyze_list(ix, s.list, total, in_has, depth)
			ix.around = saved
		case .Has:
			ix.uses_has = true
			if !in_has {
				feat: Has_Feat
				saved := ix.collect
				ix.collect = &feat
				analyze_list(ix, s.list, total, true, depth)
				ix.collect = saved
				ha := Has_Anchor{compound = comp, around = ix.around, reach = total, feat = feat, hops = has_hops(s.list), list = s.list != nil ? raw_data(s.list^) : nil}
				if s.list != nil && len(s.list^) == 1 && !feat.unkeyed {
					c := &s.list^[0]
					if len(c.compounds) > 0 && (c.leading == .Descendant || c.leading == .Child) && c.pseudo_element == .None && c.slotted == nil {
						last := c.compounds[len(c.compounds) - 1]
						ok := len(last.simples) > 0 && plain_compound(last, false)
						for k in 0 ..< len(c.compounds) - 1 { if !plain_compound(c.compounds[k], true) { ok = false } }
						for cb in c.combinators { if cb != .Descendant && cb != .Child { ok = false } }
						if ok { ha.exact, ha.child_only, ha.chain, ha.cx, ha.arg = true, c.leading == .Child && len(c.compounds) == 1, len(c.compounds) > 1, c, last }
					}
				}
				append(&ix.has_anchors, ha)
			} else {
				analyze_list(ix, s.list, total, true, depth)
			}
		case .Host: analyze_list(ix, s.list, total, in_has, depth)
		case .Host_Context: analyze_list(ix, s.list, subtree, in_has, depth)
		case .State, .Defined: attr_dep(ix, STATE_ATTRIBUTE, total, in_has)
		case .Link, .Any_Link: attr_dep(ix, "href", total, in_has)
		case .Open: attr_dep(ix, "open", total, in_has)
		case .Target: attr_dep(ix, "id", total, in_has)
		case .Lang:
			attr_dep(ix, "lang", subtree, in_has)
			attr_dep(ix, "xml:lang", subtree, in_has)
		case .Dir: attr_dep(ix, "dir", subtree, in_has)
		case .Modal, .Modal_Active:
			// (showing or closing a modal dialog asks for a restyle: page/dialog_modal.odin)
			ix.uses_controls = true
			ix.controls = reach_union(ix.keys, ix.controls, subtree)
		case .Popover_Open:
			// showing or hiding a popover asks for a restyle (page/popover.odin); the attribute decides whether it is one
			attr_dep(ix, "popover", total, in_has)
			ix.uses_controls = true
			ix.controls = reach_union(ix.keys, ix.controls, subtree)
		case .Required, .Optional: attr_dep(ix, "required", total, in_has)
		case .Placeholder_Shown:
			attr_dep(ix, "placeholder", total, in_has)
			attr_dep(ix, "value", total, in_has)
			attr_dep(ix, "type", total, in_has)
			if in_has { has_reads_empty(ix) } else { ix.empty = reach_union(ix.keys, ix.empty, total) }
			ix.uses_controls = true
			ix.controls = reach_union(ix.keys, ix.controls, subtree)
		case .Checked, .Disabled, .Enabled, .Read_Only, .Read_Write, .Valid, .Invalid, .User_Valid, .User_Invalid,
		     .In_Range, .Out_Of_Range, .Indeterminate, .Default, .Autofill:
			// the forms model answers these from the whole control (and its form); attributes are the fallback
			ix.uses_controls = true
			#partial switch s.pseudo {
			case .Checked, .Indeterminate, .Default, .Valid, .Invalid, .User_Valid, .User_Invalid: ix.uses_control_groups = true
			}
			ix.controls = reach_union(ix.keys, ix.controls, subtree)
			for name in ([?]string{"checked", "selected", "type", "disabled", "readonly", "contenteditable", "required"}) {
				attr_dep(ix, name, subtree, in_has)
			}
		}
	}
	return false
}

@(private = "file")
has_reads_siblings :: proc(ix: ^Inv_Index) {
	ix.has_sibling = true
	if ix.collect != nil { ix.collect.unkeyed, ix.collect.sibling = true, true }
}

@(private = "file")
has_reads_empty :: proc(ix: ^Inv_Index) {
	ix.has_empty = true
	if ix.collect != nil { ix.collect.empty = true }
}

// How far above the element that changed an anchor of this :has() argument can be: the number of child combinators the
// longest relative selector has (`:has(> .a)` 1, `:has(> .a > .b)` 2, `:has(+ .a)` 0: a sibling is not a level), -1 when
// any of them has a descendant combinator or a nested selector list (:is, :not...) whose own combinators are not read here.
@(private = "file")
has_hops :: proc(list: ^css.Selector_List) -> int {
	if list == nil { return -1 }
	most := 0
	for &c in list^ {
		n := 0
		if c.relative && c.leading == .Descendant { return -1 }
		if c.relative && c.leading == .Child { n += 1 }
		for cb in c.combinators {
			switch cb {
			case .Descendant: return -1
			case .Child: n += 1
			case .Next_Sibling, .Subsequent_Sibling:
			}
		}
		for comp in c.compounds {
			for sp in comp.simples { if sp.list != nil || sp.kind == .Nesting { return -1 } }
		}
		most = max(most, n)
	}
	return most
}
////////////////////////////////
// Subject keys

// An element that can be a rule's subject has the subject compound's class, id or type: a change that reaches a whole
// subtree (`.a .b`: .a changed) only needs the elements of it that carry the subject's key looked at, not every one
// restyled. A key set is such keys (class, id, attribute or type names), the Reach holds its number; unions of
// reaches union their sets. An engine's, freed with it (found again, so a rebuild of the same rules adds nothing): process-wide
// they were bounded by the names of every sheet of every site seen, tens of MB after a few dozen sites; a lock because the
// restyle of a page may run beside its own style threads.
Subject_Key_Kind :: enum u8 { Class, Id, Type, Attr }
Subject_Key :: struct { kind: Subject_Key_Kind, name: string }

// The first block of an engine's sets: most pages name a few hundred keys, an iframe of an advert a handful.
@(private = "file") KEY_SETS_BLOCK :: 64 << 10

// A set of keys: one key, or the union of two sets, kept as such: an index is built for each sheet that comes, and most of its reaches are
// never asked what they hold (made list by list and sorted, their unions were 13 % of cnn.com's style passes).
@(private)
Key_Set :: struct {
	key:         Subject_Key,
	left, right: u32,   // 0: one key
}

@(private)
Key_Sets :: struct {
	mu:    sync.Mutex,
	arena: base.Arena,
	ready: bool,
	sets:  [dynamic]Key_Set,         // set n is sets[n - 1]
	single: [Subject_Key_Kind]map[string]u32,   // the one-key sets by name
	unions: map[u64]u32,             // the union of two sets (key_sets_union): each sheet that comes builds the index again, from the same pairs
}

@(private = "file")
key_sets_init :: proc(ks: ^Key_Sets) {
	if ks.ready { return }
	_ = base.arena_init_growing(&ks.arena, KEY_SETS_BLOCK)
	a := base.arena_allocator(&ks.arena)
	ks.sets = make([dynamic]Key_Set, a)
	for &m in ks.single { m = make(map[string]u32, 64, a) }
	ks.unions = make(map[u64]u32, 64, a)
	ks.ready = true
}

@(private)
key_sets_destroy :: proc(ks: ^Key_Sets) {
	if ks.ready { base.arena_destroy(&ks.arena) }
	ks^ = {}
}

@(private)
key_sets_union :: proc(ks: ^Key_Sets, x, y: u32) -> u32 {
	if x == 0 || y == 0 { return 0 }   // (one of them is unrestricted)
	if x == y { return x }
	sync.mutex_lock(&ks.mu)
	defer sync.mutex_unlock(&ks.mu)
	pair := u64(min(x, y)) << 32 | u64(max(x, y))
	if n, ok := ks.unions[pair]; ok { return n }
	append(&ks.sets, Key_Set{left = x, right = y})
	n := u32(len(ks.sets))
	ks.unions[pair] = n
	return n
}

// Calls `each` with every key of a set.
@(private)
key_set_each :: proc(ks: ^Key_Sets, n: u32, user: rawptr, each: proc(user: rawptr, k: Subject_Key)) {
	sync.mutex_lock(&ks.mu)
	defer sync.mutex_unlock(&ks.mu)
	if n == 0 || int(n) > len(ks.sets) { return }
	seen := make([]bool, len(ks.sets) + 1, context.temp_allocator)   // (the unions share their parts)
	stack := make([dynamic]u32, 0, 64, context.temp_allocator)
	append(&stack, n)
	for len(stack) > 0 {
		x := pop(&stack)
		if seen[x] { continue }
		seen[x] = true
		s := ks.sets[x - 1]
		if s.left == 0 { each(user, s.key); continue }
		append(&stack, s.left, s.right)
	}
}

@(private = "file")
key_rank :: proc(k: Subject_Key_Kind) -> int {
	switch k {
	case .Id: return 0
	case .Class: return 1
	case .Attr: return 2
	case .Type: return 3
	}
	return 4
}

// The key set of a selector's subject: one required class, id, attribute or type of its last compound (an id, else a class, else an
// attribute, else a type), or for a compound of none of them the keys of the alternatives of an :is() (`.a :is(h2, h3)`). 0 when
// there is none (`*`, only other pseudo-classes).
@(private)
subject_keys :: proc(ks: ^Key_Sets, c: ^css.Complex, depth := 0) -> u32 {
	if len(c.compounds) == 0 { return 0 }
	comp := c.compounds[len(c.compounds) - 1]
	best: Subject_Key
	have := false
	for s in comp.simples {
		k: Subject_Key
		#partial switch s.kind {
		case .Id: k = {.Id, s.name}
		case .Class: k = {.Class, s.name}
		case .Type: k = {.Type, s.name}
		case .Attribute: k = {.Attr, s.name}
		case: continue
		}
		// the rarest first: an id, then a class, then an attribute, then a tag
		if !have || key_rank(k.kind) < key_rank(best.kind) { best, have = k, true }
	}
	if !have {
		if depth > COMPOUND_KEYS_DEPTH { return 0 }
		for &s in comp.simples {
			if !simple_alternatives(&s) { continue }
			set := subject_keys(ks, &s.list^[0], depth + 1)
			for &alt in s.list^[1:] { set = key_sets_union(ks, set, subject_keys(ks, &alt, depth + 1)) }
			if set != 0 { return set }
		}
		return 0
	}
	sync.mutex_lock(&ks.mu)
	defer sync.mutex_unlock(&ks.mu)
	key_sets_init(ks)
	if n, ok := ks.single[best.kind][best.name]; ok { return n }
	name := strings.clone(best.name, base.arena_allocator(&ks.arena))
	append(&ks.sets, Key_Set{key = {best.kind, name}})
	n := u32(len(ks.sets))
	ks.single[best.kind][name] = n
	return n
}

// Gives `doc` the features the :has() anchors of `ix` ask about (dom.Watch: what its journal says about removed subtrees), each
// anchor its mask of them, and each exact anchor its members (the elements that match its argument now). Once per index and
// document (true then: the members are of the document as it is now, not as it was when the mutations of the restyle that asks began:
// they cannot say what flipped); `force` (after a full pass, which took the changes since the last restyle without telling the members) the members again.
watch_sync :: proc(ix: ^Inv_Index, doc: ^dom.Document, force := false) -> (fresh: bool) {
	fresh = !(ix.watched == doc && ix.watched_gen == doc.journal.watch.gen)
	if !fresh && !force { return }
	if fresh {
		dom.watch_reset(doc)
		for &ha in ix.has_anchors {
			m: u64
			for k in ha.feat.classes { m |= dom.watch_bit(doc, .Class, k) }
			for k in ha.feat.ids { m |= dom.watch_bit(doc, .Id, k) }
			for k in ha.feat.attrs { m |= dom.watch_bit(doc, .Attr, base.ascii_lower(k)) }
			for k in ha.feat.types { m |= dom.watch_bit(doc, .Tag, base.ascii_lower(k)) }
			ha.feat.mask = m
			if ha.exact {
				lm: u64
				for sp in ha.arg.simples {
					#partial switch sp.kind {
					case .Type: lm |= dom.watch_bit(doc, .Tag, base.ascii_lower(sp.name))
					case .Id: lm |= dom.watch_bit(doc, .Id, sp.name)
					case .Class: lm |= dom.watch_bit(doc, .Class, sp.name)
					case .Attribute: lm |= dom.watch_bit(doc, .Attr, base.ascii_lower(sp.name))
					}
				}
				ha.last_mask = lm
				ha.first_mask = 0
				if ha.chain && ha.cx != nil && len(ha.cx.compounds) == 2 {
					fm: u64
					for sp in ha.cx.compounds[0].simples {
						#partial switch sp.kind {
						case .Type: fm |= dom.watch_bit(doc, .Tag, base.ascii_lower(sp.name))
						case .Id: fm |= dom.watch_bit(doc, .Id, sp.name)
						case .Class: fm |= dom.watch_bit(doc, .Class, sp.name)
						case .Attribute: fm |= dom.watch_bit(doc, .Attr, base.ascii_lower(sp.name))
						}
					}
					ha.first_mask = fm
				}
			}
		}
		ix.watched, ix.watched_gen = doc, doc.journal.watch.gen
	}
	members_scan(ix, doc)
	return
}

// The exact anchors by what the last compound of their argument requires, as the rule index keeps rules by their subject: an
// element is tested against the anchors of its own class tokens, id, attributes and tag, not against all of them.
@(private)
Members_Index :: struct {
	by_class, by_id, by_attr, by_tag: map[string][dynamic]^Has_Anchor,
	any: [dynamic]^Has_Anchor,   // no key: every element
}

@(private = "file")
members_index_add :: proc(x: ^Members_Index, ha: ^Has_Anchor) {
	put :: proc(m: ^map[string][dynamic]^Has_Anchor, key: string, ha: ^Has_Anchor) {
		if key not_in m { m[key] = make([dynamic]^Has_Anchor, context.temp_allocator) }
		append(&m[key], ha)
	}
	// (the rarest kind of key the compound has)
	best: ^css.Simple
	for &sp in ha.arg.simples {
		#partial switch sp.kind {
		case .Id: best = &sp
		case .Class: if best == nil || best.kind != .Id { best = &sp }
		case .Attribute: if best == nil || best.kind == .Type { best = &sp }
		case .Type: if best == nil { best = &sp }
		}
	}
	if best == nil { append(&x.any, ha); return }
	#partial switch best.kind {
	case .Id:        put(&x.by_id, best.name, ha)
	case .Class:     put(&x.by_class, best.name, ha)
	case .Attribute: put(&x.by_attr, best.name, ha)
	case .Type:      put(&x.by_tag, best.name, ha)
	}
}

// The exact anchors that have their members kept, by the keys of their arguments. In the temporary allocator.
@(private)
members_index_make :: proc(ix: ^Inv_Index) -> (keys: Members_Index, any: bool) {
	keys.by_class = make(map[string][dynamic]^Has_Anchor, allocator = context.temp_allocator)
	keys.by_id = make(map[string][dynamic]^Has_Anchor, allocator = context.temp_allocator)
	keys.by_attr = make(map[string][dynamic]^Has_Anchor, allocator = context.temp_allocator)
	keys.by_tag = make(map[string][dynamic]^Has_Anchor, allocator = context.temp_allocator)
	keys.any = make([dynamic]^Has_Anchor, context.temp_allocator)
	for &ha in ix.has_anchors {
		if !ha.exact || ha.members == nil { continue }
		members_index_add(&keys, &ha)
		any = true
	}
	return
}

// Hands `test` the anchors element `h` is a candidate of, list by list.
@(private)
members_candidates :: proc(keys: ^Members_Index, h: base.Handle, n: ^dom.Node, user: rawptr, test: proc(user: rawptr, h: base.Handle, list: []^Has_Anchor)) {
	if len(keys.any) > 0 { test(user, h, keys.any[:]) }
	if l, found := keys.by_tag[n.name]; found { test(user, h, l[:]) }
	for a in n.attrs {
		if l, found := keys.by_attr[a.name]; found { test(user, h, l[:]) }
		switch a.name {
		case "id": if l, found := keys.by_id[a.value]; found { test(user, h, l[:]) }
		case "class":
			rest := a.value
			for len(rest) > 0 {
				for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
				end := 0
				for end < len(rest) && !is_space(rest[end]) { end += 1 }
				if end > 0 { if l, found := keys.by_class[rest[:end]]; found { test(user, h, l[:]) } }
				rest = rest[end:]
			}
		}
	}
}

// The members of the exact anchors: one walk of the document.
@(private = "file")
members_scan :: proc(ix: ^Inv_Index, doc: ^dom.Document) {
	for &ha in ix.has_anchors {
		if !ha.exact { continue }
		if ha.members == nil { ha.members = new(Has_Members) }
		clear(&ha.members.set); clear(&ha.members.added); clear(&ha.members.removed); clear(&ha.members.held)
		ha.members.dirty, ha.members.lost_held, ha.members.head_touched = false, false, false
	}
	keys, any := members_index_make(ix)
	if !any { return }
	mc: Match_Ctx
	match_ctx_init(&mc, doc, State{}, context.temp_allocator)
	ix.members_tested = 0
	Scan :: struct { ix: ^Inv_Index, mc: ^Match_Ctx }
	scan := Scan{ix, &mc}
	test :: proc(user: rawptr, h: base.Handle, list: []^Has_Anchor) {
		s := (^Scan)(user)
		s.ix.members_tested += len(list)
		for ha in list { if matches_compound(s.mc, h, ha.arg) { ha.members.set[h] = {} } }
	}
	stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	append(&stack, doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n == nil { continue }
		if n.kind == .Element { members_candidates(&keys, h, n, &scan, test) }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	for &ha in ix.has_anchors {
		if !ha.exact || ha.first_mask == 0 { continue }
		for x in ha.members.set { if chain_head_above(&mc, doc, &ha, dom.get(doc, x).parent) { ha.members.held[x] = {} } }
	}
}

// After a full pass: the watch is made then, so that the removals that follow say what they held, and the members are taken
// again. Documents with shadow trees are not watched (their anchors are in the indexes of the trees).
watch_prepare :: proc(e: ^Engine, doc: ^dom.Document) {
	if len(e.shadow.of_root) > 0 || dom.has_shadow_trees(doc) || !doc.journal.on { return }
	ix := inv_index(e)
	if ix.give_up || !ix.uses_has { return }
	_ = watch_sync(ix, doc, true)
}

// A compound of tags, ids, classes and attributes, and (unless `last`) :not() / :is() / :where() of such: what it matches depends on
// the element alone and on the attributes the index lists for the :has(), nothing else (no positions, no state, no :has()).
@(private = "file")
plain_compound :: proc(comp: css.Compound, allow_logical: bool) -> bool {
	for sp in comp.simples {
		#partial switch sp.kind {
		case .Type, .Id, .Class, .Attribute, .Universal:
		case .Pseudo_Class:
			if !allow_logical || sp.list == nil { return false }
			#partial switch sp.pseudo {
			case .Not, .Is, .Where:
				for &cx in sp.list^ {
					if len(cx.combinators) > 0 || len(cx.compounds) != 1 || !plain_compound(cx.compounds[0], true) { return false }
				}
			case: return false
			}
		case: return false
		}
	}
	return true
}

