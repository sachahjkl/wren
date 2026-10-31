package style

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:css"
import "wb:dom"

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

@(private)
reach_union :: proc(a, b: Reach) -> Reach {
	r := Reach{
		self = a.self || b.self, desc = a.desc || b.desc, next = max(a.next, b.next), all_next = a.all_next || b.all_next,
		all_prev = a.all_prev || b.all_prev, sib_desc = a.sib_desc || b.sib_desc,
	}
	sa, sb := a.desc || a.sib_desc, b.desc || b.sib_desc
	switch {
	case sa && sb: r.set = key_sets_union(a.set, b.set)
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
	if out.next > 64 { out.next, out.all_next = 0, true }
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
	if r.next > 64 { r.next, r.all_next = 0, true }
	return r
}

// A compound with :has(): the anchor it tests, and how far a change of the anchor's matching reaches.
@(private)
Has_Anchor :: struct {
	compound: css.Compound,
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
}

Inv_Index :: struct {
	rebuilds:   u64,                // the engine rebuild this was made for
	watched:    ^dom.Document,      // the document whose Watch has the features of the anchors (watch_sync), and its generation
	watched_gen: u32,
	ready:      bool,
	by_class:   map[string]Reach,
	by_id:      map[string]Reach,
	by_attr:    map[string]Reach,   // attribute name (lower case): attribute selectors and pseudo-classes that read it
	by_tag:     map[string]Reach,   // for inserted elements: what their tag makes them match beyond themselves
	keyless:    Reach,              // compounds with no class, id, attribute or tag: any element may match them
	pos_fwd:    Reach,              // :first-child, :nth-child()... (index from the start): applied from each sibling
	pos_bwd:    Reach,              // :last-child, :nth-last-child()... (index from the end)
	empty:      Reach,              // :empty (and :placeholder-shown of a textarea): applied from the parent
	sib_rel:    Reach,              // the element right of a sibling combinator: applied from the next sibling of an insertion
	sib_any:    bool,               // some sibling combinator exists
	controls:   Reach,              // pseudo-classes answered by the forms model: applied from any element whose attributes change
	uses_controls: bool,
	// ... some of them answer for one control from others (its radio group, its form's controls): :checked,
	// :indeterminate, :default, :valid / :invalid / :user-valid / :user-invalid (a form or fieldset matches from its
	// controls). Without these, a control inserted, removed or changed restyles only itself and its subtree.
	uses_control_groups: bool,
	uses_has:   bool,
	has_anchors: [dynamic]Has_Anchor,
	collect:    ^Has_Feat,          // while an anchor's :has() argument is analyzed: where its features are noted too
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
merge :: proc(m: ^map[string]Reach, key: string, r: Reach) {
	if old, ok := m[key]; ok { m[key] = reach_union(old, r); return }
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
	ix.has_anchors = make([dynamic]Has_Anchor)
	visit :: proc(ix: ^Inv_Index, list: [dynamic]Entry) {
		for &ent in list { analyze_complex(ix, ent.complex, Reach{self = true, set = subject_keys(ent.complex)}, false, 0) }
	}
	for _, l in rs.index.by_id { visit(ix, l) }
	for _, l in rs.index.by_class { visit(ix, l) }
	for _, l in rs.index.by_tag { visit(ix, l) }
	for _, l in rs.index.by_attr { visit(ix, l) }
	visit(ix, rs.index.universal)
	visit(ix, rs.host_entries)
	for &ent in rs.slotted_entries {
		analyze_complex(ix, ent.complex, Reach{desc = true}, false, 0)
		if ent.complex.slotted != nil { analyze_compound(ix, ent.complex.slotted^, Reach{self = true}) }
	}
	for &ent in rs.part_entries { analyze_complex(ix, ent.complex, Reach{desc = true}, false, 0) }
	return ix
}

@(private = "file")
analyze_compound :: proc(ix: ^Inv_Index, comp: css.Compound, total: Reach) {
	keyed := false
	for &s in comp.simples { if analyze_simple(ix, &s, comp, total, false, 0) { keyed = true } }
	if !keyed { ix.keyless = reach_union(ix.keyless, total) }
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
	if in_has {
		if c.relative && (c.leading == .Next_Sibling || c.leading == .Subsequent_Sibling) { ix.has_sibling = true; if ix.collect != nil { ix.collect.unkeyed = true } }
		for cb in c.combinators { if cb == .Next_Sibling || cb == .Subsequent_Sibling { ix.has_sibling = true; if ix.collect != nil { ix.collect.unkeyed = true } } }
	}
	for j in 0 ..< len(c.combinators) {
		if c.combinators[j] == .Next_Sibling || c.combinators[j] == .Subsequent_Sibling {
			ix.sib_any = true
			if !in_has { ix.sib_rel = reach_union(ix.sib_rel, reach_compose(reach_from(c, j + 1), outer)) }
		}
	}
	for k in 0 ..< len(c.compounds) {
		total := reach_compose(reach_from(c, k), outer)
		comp := c.compounds[k]
		keyed := false
		for &s in comp.simples {
			if analyze_simple(ix, &s, comp, total, in_has, depth) { keyed = true }
		}
		if !keyed && !in_has { ix.keyless = reach_union(ix.keyless, total) }
		if !keyed && in_has && ix.collect != nil { ix.collect.unkeyed = true }
	}
}

// Records what a change of `s` reaches. Returns whether `s` is a key feature (class, id, attribute, tag).
@(private = "file")
analyze_simple :: proc(ix: ^Inv_Index, s: ^css.Simple, comp: css.Compound, total: Reach, in_has: bool, depth: int) -> bool {
	attr_dep :: proc(ix: ^Inv_Index, name: string, r: Reach, in_has: bool) {
		if in_has { flag(&ix.has_attrs, name); if ix.collect != nil { flag(&ix.collect.attrs, name) } } else { merge(&ix.by_attr, name, r) }
	}
	subtree := reach_compose(Reach{self = true, desc = true}, total)   // read on an ancestor too (lang, dir, fieldset)
	switch s.kind {
	case .Type:
		if !in_has { merge(&ix.by_tag, s.name, total) } else if ix.collect != nil { flag(&ix.collect.types, s.name) }
		return true
	case .Universal:
	case .Id:
		if in_has { flag(&ix.has_ids, s.name); if ix.collect != nil { flag(&ix.collect.ids, s.name) } } else { merge(&ix.by_id, s.name, total) }
		return true
	case .Class:
		if in_has { flag(&ix.has_classes, s.name); if ix.collect != nil { flag(&ix.collect.classes, s.name) } } else { merge(&ix.by_class, s.name, total) }
		return true
	case .Attribute:
		attr_dep(ix, s.name, total, in_has)
		return true
	case .Nesting:
		analyze_list(ix, s.list, total, in_has, depth)
	case .Pseudo_Class:
		#partial switch s.pseudo {
		case .First_Child, .Nth_Child, .First_Of_Type, .Nth_Of_Type:
			if !in_has { ix.pos_fwd = reach_union(ix.pos_fwd, total) }
			if s.list != nil { analyze_list(ix, s.list, reach_compose(Reach{self = true, all_next = true, all_prev = true}, total), in_has, depth) }
		case .Last_Child, .Nth_Last_Child, .Last_Of_Type, .Nth_Last_Of_Type:
			if !in_has { ix.pos_bwd = reach_union(ix.pos_bwd, total) }
			if s.list != nil { analyze_list(ix, s.list, reach_compose(Reach{self = true, all_next = true, all_prev = true}, total), in_has, depth) }
		case .Only_Child, .Only_Of_Type:
			if !in_has {
				ix.pos_fwd = reach_union(ix.pos_fwd, total)
				ix.pos_bwd = reach_union(ix.pos_bwd, total)
			}
		case .Empty:
			if in_has { ix.has_empty = true } else { ix.empty = reach_union(ix.empty, total) }
		case .Not, .Is, .Where:
			analyze_list(ix, s.list, total, in_has, depth)
		case .Has:
			ix.uses_has = true
			if !in_has {
				feat: Has_Feat
				saved := ix.collect
				ix.collect = &feat
				analyze_list(ix, s.list, total, true, depth)
				ix.collect = saved
				ha := Has_Anchor{compound = comp, reach = total, feat = feat, hops = has_hops(s.list)}
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
			ix.controls = reach_union(ix.controls, subtree)
		case .Popover_Open:
			// showing or hiding a popover asks for a restyle (page/popover.odin); the attribute decides whether it is one
			attr_dep(ix, "popover", total, in_has)
			ix.uses_controls = true
			ix.controls = reach_union(ix.controls, subtree)
		case .Required, .Optional: attr_dep(ix, "required", total, in_has)
		case .Placeholder_Shown:
			attr_dep(ix, "placeholder", total, in_has)
			attr_dep(ix, "value", total, in_has)
			attr_dep(ix, "type", total, in_has)
			if in_has { ix.has_empty = true } else { ix.empty = reach_union(ix.empty, total) }
			ix.uses_controls = true
			ix.controls = reach_union(ix.controls, subtree)
		case .Checked, .Disabled, .Enabled, .Read_Only, .Read_Write, .Valid, .Invalid, .User_Valid, .User_Invalid,
		     .In_Range, .Out_Of_Range, .Indeterminate, .Default, .Autofill:
			// the forms model answers these from the whole control (and its form); attributes are the fallback
			ix.uses_controls = true
			#partial switch s.pseudo {
			case .Checked, .Indeterminate, .Default, .Valid, .Invalid, .User_Valid, .User_Invalid: ix.uses_control_groups = true
			}
			ix.controls = reach_union(ix.controls, subtree)
			for name in ([?]string{"checked", "selected", "type", "disabled", "readonly", "contenteditable", "required"}) {
				attr_dep(ix, name, subtree, in_has)
			}
		}
	}
	return false
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
// restyled. A key set is an interned list of such keys (class, id or type names), the Reach holds its number; unions of
// reaches union their sets. Process-wide and never freed (bounded by the names the sheets use; interned, so a rebuild
// of the same rules adds nothing); a lock because pages' engines run on their own threads.
Subject_Key_Kind :: enum u8 { Class, Id, Type }
Subject_Key :: struct { kind: Subject_Key_Kind, name: string }

@(private = "file")
Key_Sets :: struct {
	mu:    sync.Mutex,
	arena: virtual.Arena,
	ready: bool,
	sets:  [dynamic][]Subject_Key,   // set n is sets[n - 1]
	index: map[string]u32,           // canonical text -> number
	single: [Subject_Key_Kind]map[string]u32,   // the one-key sets by name (the rules' subjects: found without building their text)
}

@(private = "file")
key_sets: Key_Sets

@(private = "file")
key_sets_init :: proc() {
	if key_sets.ready { return }
	_ = virtual.arena_init_growing(&key_sets.arena)
	a := virtual.arena_allocator(&key_sets.arena)
	key_sets.sets = make([dynamic][]Subject_Key, a)
	key_sets.index = make(map[string]u32, 64, a)
	for &m in key_sets.single { m = make(map[string]u32, 64, a) }
	key_sets.ready = true
}

@(private = "file")
key_text :: proc(keys: []Subject_Key, a: runtime.Allocator) -> string {
	sb := strings.builder_make(a)
	for k in keys { strings.write_byte(&sb, u8(k.kind) + '0'); strings.write_string(&sb, k.name); strings.write_byte(&sb, 0) }
	return strings.to_string(sb)
}

// The number of the (sorted, distinct) key list, made when new.
@(private = "file")
key_sets_intern :: proc(keys: []Subject_Key) -> u32 {
	key_sets_init()
	text := key_text(keys, context.temp_allocator)
	if n, ok := key_sets.index[text]; ok { return n }
	a := virtual.arena_allocator(&key_sets.arena)
	own := make([]Subject_Key, len(keys), a)
	for k, i in keys { own[i] = Subject_Key{k.kind, strings.clone(k.name, a)} }
	append(&key_sets.sets, own)
	n := u32(len(key_sets.sets))
	key_sets.index[strings.clone(text, a)] = n
	return n
}

@(private)
key_sets_union :: proc(x, y: u32) -> u32 {
	if x == 0 || y == 0 { return 0 }   // (one of them is unrestricted)
	if x == y { return x }
	sync.mutex_lock(&key_sets.mu)
	defer sync.mutex_unlock(&key_sets.mu)
	a, b := key_sets.sets[x - 1], key_sets.sets[y - 1]
	all := make([dynamic]Subject_Key, 0, len(a) + len(b), context.temp_allocator)
	for k in a { append(&all, k) }
	for k in b {
		dup := false
		for e in all { if e.kind == k.kind && e.name == k.name { dup = true; break } }
		if !dup { append(&all, k) }
	}
	slice.sort_by(all[:], proc(p, q: Subject_Key) -> bool { return p.kind != q.kind ? p.kind < q.kind : p.name < q.name })
	if len(all) > 64 { return 0 }   // (a set that large filters little)
	return key_sets_intern(all[:])
}

// The keys of a set (valid for the process' life).
@(private)
key_set_keys :: proc(n: u32) -> []Subject_Key {
	sync.mutex_lock(&key_sets.mu)
	defer sync.mutex_unlock(&key_sets.mu)
	if n == 0 || int(n) > len(key_sets.sets) { return nil }
	return key_sets.sets[n - 1]
}

@(private = "file")
key_rank :: proc(k: Subject_Key_Kind) -> int {
	switch k {
	case .Id: return 0
	case .Class: return 1
	case .Type: return 2
	}
	return 3
}

// The key set of a selector's subject: one required class, id or type of its last compound (an id, else a class, else a
// type). 0 when there is none (`*`, only attributes or pseudo-classes).
@(private)
subject_keys :: proc(c: ^css.Complex) -> u32 {
	if len(c.compounds) == 0 { return 0 }
	comp := c.compounds[len(c.compounds) - 1]
	best: Subject_Key
	have := false
	for s in comp.simples {
		k: Subject_Key
		switch s.kind {
		case .Id: k = {.Id, s.name}
		case .Class: k = {.Class, s.name}
		case .Type: k = {.Type, s.name}
		case .Universal, .Attribute, .Pseudo_Class, .Nesting: continue
		}
		// the rarest first: an id, then a class, then a tag
		if !have || key_rank(k.kind) < key_rank(best.kind) { best, have = k, true }
	}
	if !have { return 0 }
	sync.mutex_lock(&key_sets.mu)
	defer sync.mutex_unlock(&key_sets.mu)
	key_sets_init()
	if n, ok := key_sets.single[best.kind][best.name]; ok { return n }
	n := key_sets_intern([]Subject_Key{best})
	key_sets.single[best.kind][strings.clone(best.name, virtual.arena_allocator(&key_sets.arena))] = n
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
			for k in ha.feat.attrs { m |= dom.watch_bit(doc, .Attr, strings.to_lower(k, context.temp_allocator)) }
			for k in ha.feat.types { m |= dom.watch_bit(doc, .Tag, strings.to_lower(k, context.temp_allocator)) }
			ha.feat.mask = m
			if ha.exact {
				lm: u64
				for sp in ha.arg.simples {
					#partial switch sp.kind {
					case .Type: lm |= dom.watch_bit(doc, .Tag, strings.to_lower(sp.name, context.temp_allocator))
					case .Id: lm |= dom.watch_bit(doc, .Id, sp.name)
					case .Class: lm |= dom.watch_bit(doc, .Class, sp.name)
					case .Attribute: lm |= dom.watch_bit(doc, .Attr, strings.to_lower(sp.name, context.temp_allocator))
					}
				}
				ha.last_mask = lm
				ha.first_mask = 0
				if ha.chain && ha.cx != nil && len(ha.cx.compounds) == 2 {
					fm: u64
					for sp in ha.cx.compounds[0].simples {
						#partial switch sp.kind {
						case .Type: fm |= dom.watch_bit(doc, .Tag, strings.to_lower(sp.name, context.temp_allocator))
						case .Id: fm |= dom.watch_bit(doc, .Id, sp.name)
						case .Class: fm |= dom.watch_bit(doc, .Class, sp.name)
						case .Attribute: fm |= dom.watch_bit(doc, .Attr, strings.to_lower(sp.name, context.temp_allocator))
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

// The members of the exact anchors: one walk of the document.
@(private = "file")
members_scan :: proc(ix: ^Inv_Index, doc: ^dom.Document) {
	any := false
	for &ha in ix.has_anchors {
		if !ha.exact { continue }
		if ha.members == nil { ha.members = new(Has_Members) }
		clear(&ha.members.set); clear(&ha.members.added); clear(&ha.members.removed); clear(&ha.members.held)
		ha.members.dirty, ha.members.lost_held, ha.members.head_touched = false, false, false
		any = true
	}
	if !any { return }
	mc: Match_Ctx
	match_ctx_init(&mc, doc, State{}, context.temp_allocator)
	stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	append(&stack, doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n == nil { continue }
		if n.kind == .Element {
			for &ha in ix.has_anchors { if ha.exact && matches_compound(&mc, h, ha.arg) { ha.members.set[h] = {} } }
		}
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