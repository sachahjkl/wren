package style

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
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
}

// The features the :has() argument of one anchor tests: a change of any other feature of an element under the anchor
// cannot change whether the anchor matches.
Has_Feat :: struct {
	classes, ids, attrs: map[string]bool,
}

Inv_Index :: struct {
	rebuilds:   u64,                // the engine rebuild this was made for
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
		delete(ha.feat.classes); delete(ha.feat.ids); delete(ha.feat.attrs)
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
		if c.relative && (c.leading == .Next_Sibling || c.leading == .Subsequent_Sibling) { ix.has_sibling = true }
		for cb in c.combinators { if cb == .Next_Sibling || cb == .Subsequent_Sibling { ix.has_sibling = true } }
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
		if !in_has { merge(&ix.by_tag, s.name, total) }
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
				append(&ix.has_anchors, Has_Anchor{compound = comp, reach = total, feat = feat, hops = has_hops(s.list)})
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
	return key_sets_intern([]Subject_Key{best})
}