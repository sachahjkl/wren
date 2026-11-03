package style

import "wb:base"
import "wb:css"
import "wb:dom"

// Matching shared between siblings and cousins. Two element siblings with the same tag and the same attributes (ids,
// classes and every other attribute, in the same order) look up the same entries of the index, pass the same ancestor
// filter (they have the same ancestors), and any part of a selector matched against an ancestor gives both the same
// answer. What can still tell them apart is what a selector asks of the element itself beyond its tag and attributes:
// its position among its siblings (:nth-child, :first-child, a sibling combinator to its left), its state (:hover,
// :focus, form controls, :defined, custom states), its content (:empty, :has()), its identity (:scope). An entry whose
// subject asks any of that is `own` (Entry.own): it is matched again for each element; every other entry the first
// sibling matched, the next ones match too, in the same order.
//
// Cousins: two elements whose parents are alike in that way (the same tag and attributes, under alike parents, up to a
// common ancestor) differ besides only by what a selector asks the same way of their ancestors, or of the ancestors'
// siblings (Entry.above): those entries are matched again too.
//
// So the walk keeps, for each depth below where it started, a family: the children of one parent, or of parents alike
// (of one class). For each kind of element the family had (up to SIB_FAMILY_KINDS), the first one, matched in full,
// with what its matching visited (the entries it matched, and those a sibling or a cousin must try again, with its
// answer). The next element of the family with the same tag and attributes takes those, trying again only what it
// must, and is of that one's class. The lists it gets are those a full match gives, in the same order: the share table
// (share.odin) then finds the style the first one got. It is not a cache: it holds what this pass matched for elements
// before, is dropped when the walk meets another family at that depth, never outlives the pass and is never
// invalidated (the document and the rules do not change during a pass). Documents with shadow trees match without it
// (the flat tree's siblings may come from different trees).

// Kinds of elements a family keeps (a list item's span and b, a section's h3 and p...): past them, a new family.
SIB_FAMILY_KINDS :: 8

// What an element's matching visited of one entry: an entry it matched, or one a sibling or a cousin tries again.
@(private)
Sib_Hit :: struct {
	ent:     ^Entry,
	slot:    Entry_List,   // which of Pass.lists
	matched: bool,
}

// An element of a family matched in full: its node, its parent, its hits (Sib_Match.hits[hits[0]:hits[1]]), its class.
@(private)
Sib_Kind :: struct {
	node:   ^dom.Node,
	parent: base.Handle,
	hits:   [2]int,
	class:  u32,
}

// The family at one depth: the parent of its first element, the class of its elements' parents (0 at the start of
// the walk: the family is the children of `parent`), its kinds (Sib_Match.kinds[kinds[0]:kinds[1]]), where their
// hits start, and the class of the element last met at that depth (its children's parent class).
@(private)
Sib_Level :: struct {
	parent:       base.Handle,
	parent_class: u32,
	kinds:        [2]int,
	hits:         int,
	class:        u32,
}

@(private)
Sib_Match :: struct {
	levels:  [dynamic]Sib_Level,   // by depth below the start of the walk
	kinds:   [dynamic]Sib_Kind,    // the levels' kinds, one level after the other
	hits:    [dynamic]Sib_Hit,     // the kinds' hits, one after the other
	classes: u32,                  // classes made so far (0: none)
}

@(private)
sib_match_destroy :: proc(m: ^Sib_Match) {
	delete(m.levels)
	delete(m.kinds)
	delete(m.hits)
	m^ = {}
}

// Fills p.lists for `h` (as collect_entries does), from an element of its family when it can. `depth`: below where the
// walk started; < 0: no sharing.
@(private)
match_element :: proc(p: ^Pass, h: base.Handle, n: ^dom.Node, ancestors: ^Bloom, ctx: Elem_Ctx, depth: int) {
	m := &p.sib
	if depth < 0 || depth > len(m.levels) || dom.has_shadow_trees(p.mc.doc) {
		collect_entries(p, h, n, ancestors, ctx, nil)
		return
	}
	// (the ::backdrop entries are tried for an element of the top layer alone: it neither takes a family's matching nor
	// gives its own)
	if in_top_layer(p, h) {
		collect_entries(p, h, n, ancestors, ctx, nil)
		sib_pass_by(p, n, depth)
		return
	}
	lv := sib_family(m, n, depth)
	if lv != nil {
		for &k in m.kinds[lv.kinds[0]:lv.kinds[1]] {
			if !same_match_inputs(k.node, n) { continue }
			// (the levels below stay: this element's children are cousins of those met there)
			cousin := k.parent != n.parent
			for &l in p.lists { clear(&l) }
			p.own_depth = ctx.depth
			for hit in m.hits[k.hits[0]:k.hits[1]] {
				again := hit.ent.own || (cousin && hit.ent.above)
				if again ? !matches_complex(&p.mc, h, hit.ent.complex) : !hit.matched { continue }
				x := hit.ent^
				x.ctx = p.own_depth
				append(&p.lists[hit.slot], x)
			}
			lv.class = k.class
			return
		}
	}
	if lv == nil || lv.kinds[1] - lv.kinds[0] >= SIB_FAMILY_KINDS { lv = sib_family_new(m, n, depth) }
	// a new kind in the family (what was below it goes): matched in full
	sib_truncate(m, depth)
	start := len(m.hits)
	collect_entries(p, h, n, ancestors, ctx, &m.hits)
	m.classes += 1
	append(&m.kinds, Sib_Kind{node = n, parent = n.parent, hits = {start, len(m.hits)}, class = m.classes})
	lv.kinds[1] += 1
	lv.class = m.classes
}

// An element at `depth` that the walk passes without matching it (a partial restyle): its children are a family of
// their own, whose parent is like no other.
@(private)
sib_pass_by :: proc(p: ^Pass, n: ^dom.Node, depth: int) {
	m := &p.sib
	if depth < 0 || depth > len(m.levels) { return }
	lv := sib_family(m, n, depth)
	if lv == nil { lv = sib_family_new(m, n, depth) }
	sib_truncate(m, depth)
	m.classes += 1
	lv.class = m.classes
}

// The family of `n` at `depth`, if the walk has it there: the children of n's parent, or of a parent alike to theirs.
@(private = "file")
sib_family :: proc(m: ^Sib_Match, n: ^dom.Node, depth: int) -> ^Sib_Level {
	if depth >= len(m.levels) { return nil }
	lv := &m.levels[depth]
	if depth > 0 ? lv.parent_class != m.levels[depth - 1].class : lv.parent != n.parent { return nil }
	return lv
}

// A family at `depth` for `n`, empty, instead of what the walk had there and below.
@(private = "file")
sib_family_new :: proc(m: ^Sib_Match, n: ^dom.Node, depth: int) -> ^Sib_Level {
	resize(&m.levels, depth)
	kinds, hits, parent_class := 0, 0, u32(0)
	if depth > 0 {
		up := &m.levels[depth - 1]
		kinds, hits, parent_class = up.kinds[1], sib_hits_end(m, up), up.class
	}
	resize(&m.kinds, kinds)
	resize(&m.hits, hits)
	append(&m.levels, Sib_Level{parent = n.parent, parent_class = parent_class, kinds = {kinds, kinds}, hits = hits})
	return &m.levels[depth]
}

// Drops the levels below `depth`, their kinds and hits.
@(private = "file")
sib_truncate :: proc(m: ^Sib_Match, depth: int) {
	resize(&m.levels, depth + 1)
	lv := &m.levels[depth]
	resize(&m.kinds, lv.kinds[1])
	resize(&m.hits, sib_hits_end(m, lv))
}

@(private = "file")
sib_hits_end :: proc(m: ^Sib_Match, lv: ^Sib_Level) -> int {
	return lv.kinds[1] > lv.kinds[0] ? m.kinds[lv.kinds[1] - 1].hits[1] : lv.hits
}

// The same tag and the same attributes: everything matching reads of an element, besides what `own` entries ask.
@(private)
same_match_inputs :: proc(a, b: ^dom.Node) -> bool {
	if a.name != b.name || a.ns != b.ns || a.xml != b.xml || len(a.attrs) != len(b.attrs) { return false }
	for x, i in a.attrs {
		y := b.attrs[i]
		if x.name != y.name || x.value != y.value { return false }
	}
	return true
}

// What a selector asks beyond tags, attributes and the tree's shape: `own`, of its subject (its compound asks it, or a
// sibling combinator leads from the subject to an element before it); `above`, the same of an ancestor of the subject
// or of a sibling of one (cousins differ there, siblings do not).
@(private)
selector_deps :: proc(c: ^css.Complex, depth := 0) -> (own, above: bool) {
	if c.relative || len(c.compounds) == 0 { return true, true }
	last := len(c.compounds) - 1
	for comb, i in c.combinators {
		if comb == .Child || comb == .Descendant { continue }
		if i == last - 1 { own = true } else { above = true }
	}
	for comp, k in c.compounds {
		o, a := compound_deps(comp, depth)
		if k == last { own ||= o; above ||= a } else { above ||= o || a }
	}
	return
}

@(private = "file")
list_deps :: proc(list: ^css.Selector_List, depth: int) -> (own, above: bool) {
	if list == nil { return false, false }
	if depth >= BLOOM_MAX_LIST_DEPTH { return true, true }
	for &c in list^ {
		o, a := selector_deps(&c, depth + 1)
		own ||= o
		above ||= a
	}
	return
}

@(private = "file")
compound_deps :: proc(comp: css.Compound, depth: int) -> (own, above: bool) {
	for s in comp.simples {
		#partial switch s.kind {
		case .Nesting:
			if s.list == nil { own = true; continue }   // (alone: :scope, the element itself)
			o, a := list_deps(s.list, depth)
			own ||= o
			above ||= a
		case .Pseudo_Class:
			switch s.pseudo {
			// what the element's tag, attributes and ancestors decide, or nothing
			case .None, .Root, .Target, .Required, .Optional, .Lang, .Dir, .Open, .Autofill, .Never,
			     .Before, .After, .First_Line, .First_Letter, .Selection, .Placeholder, .Marker, .Backdrop, .Slotted, .Part, .Other_Element:
			case .Not, .Is, .Where:
				o, a := list_deps(s.list, depth)
				own ||= o
				above ||= a
			// its position, state, content or identity
			case .Scope, .Empty, .First_Child, .Last_Child, .Only_Child, .First_Of_Type, .Last_Of_Type, .Only_Of_Type,
			     .Nth_Child, .Nth_Last_Child, .Nth_Of_Type, .Nth_Last_Of_Type, .Has, .Hover, .Active, .Focus, .Focus_Visible,
			     .Focus_Within, .Host, .Host_Context, .State, .Has_Slotted, .Link, .Any_Link, .Visited, .Fullscreen, .Checked,
			     .Disabled, .Enabled, .Read_Write, .Read_Only, .Valid, .Invalid, .User_Valid, .User_Invalid, .In_Range,
			     .Out_Of_Range, .Indeterminate, .Default, .Modal, .Modal_Active, .Popover_Open, .Placeholder_Shown, .Defined:
				own = true
			}
		}
	}
	return
}
