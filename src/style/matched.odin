package style

import "core:sync"
import "wb:base"
import "wb:css"
import "wb:dom"

// What an element matched, kept. A selector reads the element, its ancestors, its siblings and what it holds; it never reads a computed
// style. So an element restyled only because what it inherits moved (custom properties written on <html>, a query container's size) matches
// what it matched: the cascade runs again on the same rules, without the matching, which is three quarters of an element's cost.
//
// The list is true by what keeps a record true, with no invalidation of its own:
//   * it is written where the matching is, for every element matched, whatever the record does after (compute_element): no pass can leave a
//     list older than its matching, and an element whose record stays equal gets its new list all the same;
//   * it is read for an element no mark names (Frame.whole, M_SELF): the marks are what says that a change of the document, of a state, of an
//     @media block, of the sheets may change what an element matches. Those passes all match what they mark, so they all keep the list;
//   * what a rule set is made of goes with the rules: the lists hold pointers to them, and engine_rebuild ends them all (Matched_Store.gen):
//     a Styled of another generation reads none and writes none. Rules that arrive or leave one by one go through the marks (restyle_arrivals);
//   * @container conditions, hints, the style attribute are no part of a list: they are read in the cascade, each time;
//   * shadow trees: none. Which tree's rules an element sees depends on the flat tree, and ::slotted(), ::part() and :host rules are
//     another tree's: a document with one has its lists dropped for the life of the Styled (matched_holds), and matching runs.
//
// A list is kept once however many elements have it (hash consing, by rule and selector): cards of a page, rows of a list.
// The store is the engine's and outlives a Styled: the next full pass finds the lists there.

// The store's first block, and what it may hold: past that no new list is kept (their elements match as before) until the next full pass starts over.
MATCHED_BLOCK :: 64 << 10
MATCHED_MAX_BYTES :: 16 << 20
// The table's first size in slots (a power of two); it doubles at SHARE_LOAD_NUM / SHARE_LOAD_DEN full, as the share table does.
MATCHED_MIN_SLOTS :: 1024

@(private)
Matched_Rule :: struct {
	rule:    ^Rule,
	complex: ^css.Complex,
}

// The entries of one element, list after list (Pass.lists), hints aside.
@(private)
Matched_List :: struct {
	counts: [Entry_List]u16,
	rules:  []Matched_Rule,
}

@(private = "file")
Matched_Slot :: struct {
	hash: u64,
	list: ^Matched_List,
}

@(private)
Matched_Store :: struct {
	mu:    sync.Mutex,   // (the style threads of a pass: a look-up in 50 us of work)
	arena: base.Arena,
	gen:   u64,          // 0: not made yet
	limit: int,          // what it may hold
	slots: []Matched_Slot,
	count: int,
}

@(private)
matched_destroy :: proc(st: ^Matched_Store) {
	if st.gen != 0 { base.arena_destroy(&st.arena) }
	st^ = {}
}

// The rules the lists point at are going, or the store is full: no list of before is read again.
@(private)
matched_reset :: proc(st: ^Matched_Store) {
	if st.gen == 0 { return }
	base.arena_free_all(&st.arena)
	st.slots, st.count = nil, 0
	st.gen += 1
}

// A full pass begins.
@(private)
matched_begin :: proc(e: ^Engine, s: ^Styled) {
	if !e.settings.inc_enabled { return }   // (no pass would read them)
	st := &e.matched
	if st.gen == 0 {
		_ = base.arena_init_growing(&st.arena, MATCHED_BLOCK)
		st.gen, st.limit = 1, MATCHED_MAX_BYTES
	}
	if int(st.arena.total_used) > st.limit { matched_reset(st) }
	s.matched_gen = st.gen
}

// Whether the lists of `s` are in force for a pass on `doc`.
@(private)
matched_holds :: proc(e: ^Engine, s: ^Styled, doc: ^dom.Document) -> bool {
	if dom.has_shadow_trees(doc) {
		sync.atomic_store(&s.matched_gen, 0)   // (those it had were not kept up while the trees stood)
		return false
	}
	gen := sync.atomic_load(&s.matched_gen)
	return gen != 0 && gen == e.matched.gen
}

// The memory of the lists of engine `e`.
matched_bytes :: proc(e: ^Engine) -> int { return e.matched.gen != 0 ? int(e.matched.arena.total_used) : 0 }

@(private)
matched_of :: proc(s: ^Styled, h: base.Handle) -> ^Matched_List {
	i := int(base.handle_index(h))
	if i >= len(s.matched) || s.nodes[i] != h || s.by_node[i] == nil { return nil }
	return s.matched[i]
}

// What p.lists holds is what `h` matches now.
@(private)
matched_keep :: proc(p: ^Pass, h: base.Handle) {
	if !p.matched_on { return }
	s := p.s
	i := int(base.handle_index(h))
	if i >= len(s.matched) { styled_size(s, i + 1) }
	s.matched[i] = matched_intern(&p.e.matched, &p.lists)
}

// p.lists from what `h` matched last; false: nothing kept, the caller matches.
@(private)
matched_take :: proc(p: ^Pass, h: base.Handle, ctx: Elem_Ctx) -> bool {
	if !p.matched_on { return false }
	l := matched_of(p.s, h)
	if l == nil { return false }
	p.own_depth = ctx.depth
	at := 0
	for &list, k in p.lists {
		clear(&list)
		n := int(l.counts[k])
		for r in l.rules[at:at + n] { append(&list, Entry{rule = r.rule, complex = r.complex, ctx = p.own_depth}) }
		at += n
	}
	p.matched_taken += 1
	return true
}

// The one list equal to `lists`; nil past what a list or the store may hold.
@(private = "file")
matched_intern :: proc(st: ^Matched_Store, lists: ^[Entry_List][dynamic]Entry) -> ^Matched_List {
	hash := SHARE_HASH_SEED
	total := 0
	for &l in lists {
		hash = (hash ~ u64(len(l))) * SHARE_HASH_PRIME
		total += len(l)
		if len(l) > int(max(u16)) { return nil }
		for &ent in l {
			hash = (hash ~ u64(uintptr(rawptr(ent.rule)))) * SHARE_HASH_PRIME
			hash = (hash ~ u64(uintptr(rawptr(ent.complex)))) * SHARE_HASH_PRIME
		}
	}
	sync.mutex_lock(&st.mu)
	defer sync.mutex_unlock(&st.mu)
	if (st.count + 1) * SHARE_LOAD_DEN > len(st.slots) * SHARE_LOAD_NUM { matched_grow(st) }
	mask := len(st.slots) - 1
	i := int(hash) & mask
	for ; st.slots[i].list != nil; i = (i + 1) & mask {
		if st.slots[i].hash == hash && matched_equal(st.slots[i].list, lists) { return st.slots[i].list }
	}
	if int(st.arena.total_used) >= st.limit { return nil }
	a := base.arena_allocator(&st.arena)
	l := new(Matched_List, a)
	l.rules = make([]Matched_Rule, total, a)
	at := 0
	for &list, k in lists {
		l.counts[k] = u16(len(list))
		for &ent in list {
			l.rules[at] = {ent.rule, ent.complex}
			at += 1
		}
	}
	st.slots[i] = {hash, l}
	st.count += 1
	return l
}

@(private = "file")
matched_equal :: proc(l: ^Matched_List, lists: ^[Entry_List][dynamic]Entry) -> bool {
	at := 0
	for &list, k in lists {
		if int(l.counts[k]) != len(list) { return false }
		for &ent in list {
			if l.rules[at].rule != ent.rule || l.rules[at].complex != ent.complex { return false }
			at += 1
		}
	}
	return true
}

@(private = "file")
matched_grow :: proc(st: ^Matched_Store) {
	old := st.slots
	st.slots = make([]Matched_Slot, max(MATCHED_MIN_SLOTS, 2 * len(old)), base.arena_allocator(&st.arena))
	mask := len(st.slots) - 1
	for sl in old {
		if sl.list == nil { continue }
		i := int(sl.hash) & mask
		for st.slots[i].list != nil { i = (i + 1) & mask }
		st.slots[i] = sl
	}
}

// The same rules for each pseudo-element, in any order and any number of times (class="a a" looks `.a` up twice). For verify_styles.
@(private)
matched_same :: proc(a, b: ^Matched_List) -> bool {
	holds :: proc(x, y: ^Matched_List) -> bool {
		from := 0
		for k in Entry_List {
			y_from := 0
			for j in Entry_List { if j < k { y_from += int(y.counts[j]) } }
			outer: for r in x.rules[from:from + int(x.counts[k])] {
				for o in y.rules[y_from:y_from + int(y.counts[k])] { if o == r { continue outer } }
				return false
			}
			from += int(x.counts[k])
		}
		return true
	}
	return a == b || (holds(a, b) && holds(b, a))
}
