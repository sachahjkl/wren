package layout

import "core:slice"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:style"

// Incremental layout. Between two passes the box tree, the inline items, the lines and the layout caches of the boxes
// stay; a pass finds out what changed and does only the work that change invalidates, with the same result as a full
// pass (layout.incremental.verify checks it).
//
// What changed comes from:
//   * the mutation journal of the document (dom.journal_since): inserted / removed nodes, text, attributes;
//   * the layout journal of the styles (style.journal_since): per element, a change that keeps its box (Layout) or
//     may change it (Box);
//   * the viewport (the root is laid out again: what depends on the width or the height misses its cache);
//   * the natural sizes of replaced elements (Input.images_generation), the faces of fonts (Input.fonts_generation).
//
// Invalidation is per box: `Dirty` (the box itself must be laid out again) and `Child_Dirty` (something inside must),
// set on every ancestor. A clean box asked for a layout with the inputs it was last laid out with returns its cached
// result (block.odin, layout_contents); a block whose height does not change therefore stops the propagation: its
// parent places the following siblings where they were and they hit their caches. Intrinsic sizes are dropped along
// the same paths.
//
// A structural change (a node inserted or removed, a style that changes what boxes an element makes) rebuilds the
// content of the nearest ancestor box that can be rebuilt on its own: a block container, flex container, table part
// or atomic inline with an element (rebuild.odin). Its old descendants are marked Dead and left in the arrays; new
// boxes go at the end. Memory left behind that way is counted, and past layout.incremental.garbage_ratio the next pass
// is a full one, which starts afresh.
//
// After layout, finishing (coordinates, clips, spaces, overflow) and the display list are made again, unless the
// change stayed inside some lines of text whose boxes did not move: then only the items of those lines are replaced
// (splice.odin).

Inc_Flag :: enum u8 {
	Dirty,         // must be laid out again
	Child_Dirty,   // some box inside must
}
Inc_Flags :: bit_set[Inc_Flag; u8]

// Per box, what building it took that a partial rebuild needs again, and what a pass compares.
Box_Info :: struct {
	cb, fcb:     i32,              // containing blocks of the frame the box was placed with
	deco:        style.Decorations,
	deco_box:    i32,
	ordinal:     i32,              // list items: the number of the marker
	natural:     [2]f32,           // replaced: natural size used (device px)
	natural_has: [2]bool,
	natural_ok:  bool,
	items:       [2]i32,           // display items of its lines ([marker,] emit_lines), for splicing...
	items_gen:   u32,              // ... valid when this is Inc_State.dl_gen
	segs:        [2]i32,           // inline formatting contexts: their measured segments in Inc_State.segs
}

Inc_State :: struct {
	info:        [dynamic]Box_Info,
	doc:         rawptr,
	images_gen, fonts_gen: u64,
	lh_normal:   f32,
	quotes:      bool,              // generated quotes: their depth runs through the whole document
	dl_gen:      u32,               // display lists built (Box_Info.items_gen)
	doc_extent:  Rect,              // what the document's content covers (before the viewport is added), from finish
	// memory left behind by partial passes, and what was alive after the last full one
	live_boxes, live_items: int,
	dead_boxes, dead_items, dead_lines, dead_frags, dead_segs: int,
	segs:        [dynamic]Seg,     // measured segments of inline formatting contexts (inline.odin, Box_Info.segs)
	spare_lines: [dynamic]Line,    // compact_lines packs into these, then swaps them with the layout's
	spare_frags: [dynamic]Frag,
	arena_base:  uint,
	fonts_base:  int,
	// diagnostics
	verify_failures: int,
	verify_report:   string,        // heap: the first difference of the last failed verification
	last_rebuilt:    int,           // boxes rebuilt by the last incremental pass
	last_laid:       int,           // boxes laid out again (not taken from their cache)
	last_spliced:    bool,          // the display list was patched rather than built
	fallback:        string,        // why the last pass could not be incremental ("" when it was, or was not tried)
}

// What one incremental pass tracks while it lays out.
@(private)
Inc_Pass :: struct {
	laid:     [dynamic]i32,          // boxes laid out again
	segs_ok:  bool,                  // measured segments of earlier passes hold (inline.odin)
	snapping: bool,                  // the display list may be spliced: record what boxes laid out again move
	snapped:  []bool,
	snap:     [dynamic]Snap,
	wide:     bool,                  // many paragraphs may be laid out again: some on the layout threads (parallel.odin)
}

@(private)
inc_reset :: proc(l: ^Layout) {
	clear(&l.inc.info)
	clear(&l.inc.segs)
	l.inc.quotes = false
	l.inc.dead_boxes, l.inc.dead_items, l.inc.dead_lines, l.inc.dead_frags, l.inc.dead_segs = 0, 0, 0, 0, 0
}

@(private)
inc_destroy :: proc(l: ^Layout) {
	delete(l.inc.info)
	delete(l.inc.segs)
	delete(l.inc.spare_lines)
	delete(l.inc.spare_frags)
	delete(l.inc.verify_report)
}

// After a full pass: the baseline the garbage of later partial passes is measured against.
@(private)
inc_note_full :: proc(l: ^Layout) {
	l.inc.live_boxes = len(l.boxes)
	l.inc.live_items = len(l.inline_items)
	l.inc.dead_boxes, l.inc.dead_items, l.inc.dead_lines, l.inc.dead_frags = 0, 0, 0, 0
	l.inc.arena_base = l.arena.total_used
	l.inc.fonts_base = len(l.fonts)
}

// A full pass with incremental layout on: the next pass needs the mutation journal of the document.
@(private)
inc_after_full :: proc(l: ^Layout, input: Input) {
	if !input.doc.journal.on { dom.journal_enable(input.doc, input.settings.inc_journal) }
	input.doc.journal.max = max(input.settings.inc_journal, 16)
}

@(private)
inc_note_layout :: proc(c: ^Ctx, bi: i32) {
	append(&c.inc.laid, bi)
	if c.inc.snapping { snap_children(c, bi) }
}

@(private)
too_much_garbage :: proc(l: ^Layout) -> bool {
	r := l.settings.inc_garbage_ratio
	s := &l.inc
	if f32(s.dead_boxes) > r * f32(max(s.live_boxes, 64)) { return true }
	if f32(s.dead_items) > r * f32(max(s.live_items, 64)) { return true }
	if f32(l.arena.total_used) > (1 + r) * f32(s.arena_base) + f32(1 << 20) { return true }
	if f32(len(l.fonts)) > (1 + r) * f32(s.fonts_base) + 64 { return true }
	return false
}

////////////////////////////////
// Invalidation

@(private)
mark_dirty :: proc(l: ^Layout, bi: i32) {
	b := &l.boxes[bi]
	b.inc += {.Dirty}
	b.intr_ok = false
	for p := b.parent; p != NONE; p = l.boxes[p].parent {
		pb := &l.boxes[p]
		pb.inc += {.Child_Dirty}
		pb.intr_ok = false
	}
}

// The anonymous boxes an element's box made around its content inherit from it: dirty with it.
@(private)
mark_anon_dirty :: proc(l: ^Layout, bi: i32) {
	for ch := l.boxes[bi].first; ch != NONE; ch = l.boxes[ch].next {
		if .Anonymous in l.boxes[ch].flags && .Dead not_in l.boxes[ch].flags {
			mark_dirty(l, ch)
			mark_anon_dirty(l, ch)
		}
	}
}

// `h` or one of its ancestors has display: none (its subtree makes no boxes).
@(private)
hidden_now :: proc(c: ^Ctx, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(c.d, cur)
		if n == nil { return true }
		if n.kind == .Element {
			if cs := style.style_of(c.st, cur); cs == nil || cs.display == .None { return true }
		}
		cur = up(c, cur)
	}
	return false
}

@(private)
live_box :: proc(l: ^Layout, h: base.Handle) -> i32 {
	bi := box_index(l, h)
	if bi == NONE || .Dead in l.boxes[bi].flags { return NONE }
	return bi
}

// What a change of the children of `h` (an element or the document) rebuilds: the content of the nearest box that
// can be rebuilt, or a replaced element laid out again (its natural size may follow its content: a <select>). false:
// only a full pass will do.
@(private)
add_target :: proc(c: ^Ctx, h: base.Handle, roots, dirty: ^[dynamic]i32) -> bool {
	l := c.l
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(c.d, cur)
		if n == nil { return true }   // destroyed: its removal is in the journal too
		switch n.kind {
		case .Document: return false
		case .Text, .Comment, .Doctype, .Fragment:
		case .Element:
			if bi := live_box(l, cur); bi != NONE {
				b := &l.boxes[bi]
				if b.kind == .Replaced { append(dirty, bi); return true }
				if b.kind != .Inline && .Root not_in b.flags && .Pseudo not_in b.flags { append(roots, bi); return true }
			} else if cs := style.style_of(c.st, cur); cs != nil && cs.display == .None {
				return true   // inside display: none: nothing to lay out
			}
		}
		cur = up(c, cur)
	}
	return true   // detached: nothing rendered
}

@(private)
parent_of :: proc(c: ^Ctx, h: base.Handle) -> base.Handle { return up(c, h) }

// Attributes read when building boxes (a change rebuilds the element's box), and those read for the natural size of a
// replaced element (it is laid out again). Others reach layout through the styles only.
@(private)
attr_kind :: proc(name: string) -> enum u8 { None, Build, Natural } {
	switch name {
	case "colspan", "rowspan", "type", "start", "reversed", "value": return .Build
	case "width", "height", "cols", "rows", "size", "multiple", "label", "src": return .Natural
	}
	return .None
}

////////////////////////////////
// The pass

@(private)
bail :: proc(l: ^Layout, why: string) -> bool {
	l.inc.fallback = why
	return false
}

@(private)
run_incremental :: proc(l: ^Layout, input: Input) -> bool {
	l.inc.fallback = ""
	set := input.settings
	st := input.styled
	if !set.incremental || !l.valid || l.last_pass == .None || l.settings != set^ || l.scale != input.scale ||
	   l.inc.doc != rawptr(input.doc) || l.inc.lh_normal != st.line_height_normal || len(l.boxes) == 0 {
		return bail(l, "settings, scale or document changed")
	}
	if too_much_garbage(l) { return bail(l, "memory left by partial passes") }
	dom_changes, dom_ok := dom.journal_since(input.doc, l.mutations)
	if !dom_ok { return bail(l, "mutation journal incomplete") }
	// the same style records as last time, changed since only as the style journal says: only those are re-pointed
	same_pass := l.styled == rawptr(st) && l.styled_pass == st.pass_id
	style_changes: []style.Journal_Entry
	if st.serial != l.serial {
		ok: bool
		style_changes, ok = style.journal_since(st, l.serial)
		if !ok { return bail(l, "style journal incomplete") }
	}
	t0 := time.tick_now()
	marker: u8
	c := ctx_make(l, input, &marker)
	pass := Inc_Pass{laid = make([dynamic]i32, 0, 64, context.temp_allocator)}
	c.inc = &pass
	root_el, body_el := canvas_elements(input.doc)
	if root_el != l.canvas_els[0] || body_el != l.canvas_els[1] { return bail(l, "root element or body replaced") }
	c.root_el, c.body_el = root_el, body_el

	// what to rebuild, what to lay out again
	roots := make([dynamic]i32, 0, 16, context.temp_allocator)
	dirty := make([dynamic]i32, 0, 16, context.temp_allocator)
	styled_dirty := make([dynamic]i32, 0, 16, context.temp_allocator)
	// elements whose own box may come, go or change: done one by one when possible (rebuild.odin), else their
	// containers are rebuilt whole (`parents`)
	touched := make(map[base.Handle]bool, 16, context.temp_allocator)
	parents := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	containers := make([dynamic]base.Handle, 0, 16, context.temp_allocator)   // elements whose content changed
	for &e in dom_changes {
		switch e.kind {
		case .Insert, .Remove:
			n := dom.get(input.doc, e.node)
			// text, or an element removed that had no box of its own: their container's content. Such an element may
			// still have made inline content (a <br>, a <wbr>, the children of display: contents), which only its
			// container's items hold; a plan would see no box before and none after, and change nothing.
			if (n != nil && n.kind != .Element) || ((n == nil || e.kind == .Remove) && live_box(l, e.node) == NONE) {
				append(&containers, e.parent)
				continue
			}
			touched[e.node] = true
			append(&parents, e.parent)
		case .Text:
			if e.parent != base.NIL_HANDLE { append(&containers, e.parent) }
		case .Reslot:
			// the flat children of a slot or a new host changed; or a node left its place under a slot or a host
			append(&containers, e.parent != base.NIL_HANDLE ? e.parent : e.node)
		case .Attribute:
			switch attr_kind(e.name) {
			case .None:
			case .Build:
				// the numbering of a list follows its own attributes: its content; the others: the element's box
				target := e.name == "start" || e.name == "reversed" ? e.node : parent_of(&c, e.node)
				if target != base.NIL_HANDLE && !add_target(&c, target, &roots, &dirty) { return bail(l, "document changed at its root") }
			case .Natural:
				// the element's own replaced box, or the replaced element it is inside (an option of a <select>)
				if !add_target(&c, e.node, &roots, &dirty) { return bail(l, "document changed at its root") }
			}
		}
	}
	layout_changes := 0   // style entries that are not paint-only
	for &e in style_changes {
		if e.level < .Layout { continue }   // a new record with the same layout values: re-pointed below
		layout_changes += 1
		bi := live_box(l, e.node)
		if bi == NONE && hidden_now(&c, e.node) { continue }   // had no box, has none
		if e.level == .Layout && bi != NONE {
			append(&styled_dirty, bi)
			continue
		}
		p := parent_of(&c, e.node)
		if p == base.NIL_HANDLE { continue }
		touched[e.node] = true
		append(&parents, p)
	}
	// content changes inside an element whose box is made again anyway are part of that
	for h in containers {
		if len(touched) > 0 && touched_ancestor(&c, h, touched) != base.NIL_HANDLE { continue }
		if !add_target(&c, h, &roots, &dirty) { return bail(l, "document changed at its root") }
	}
	plans := make([dynamic]Child_Plan, 0, len(touched), context.temp_allocator)
	if len(touched) > 0 {
		list := make([dynamic]base.Handle, 0, len(touched), context.temp_allocator)
		for h in touched {
			// inside another element made again, and its box (if any) inside that one's: part of it (an inherited change
			// reaches every descendant)
			if p := parent_of(&c, h); p != base.NIL_HANDLE {
				if a := touched_ancestor(&c, p, touched); a != base.NIL_HANDLE {
					old, ab := live_box(l, h), live_box(l, a)
					if old == NONE || (ab != NONE && box_inside(l, old, ab)) { continue }
				}
			}
			append(&list, h)
		}
		if !plan_children(&c, list[:], &plans) {
			// whole containers: where the boxes were, where they go
			for h in list {
				if old := live_box(l, h); old != NONE {
					p := l.boxes[old].parent
					for p != NONE && l.boxes[p].node == base.NIL_HANDLE { p = l.boxes[p].parent }
					if p != NONE && !add_target(&c, l.boxes[p].node, &roots, &dirty) { return bail(l, "document changed at its root") }
				}
			}
			for p in parents {
				if !add_target(&c, p, &roots, &dirty) { return bail(l, "document changed at its root") }
			}
			clear(&plans)
		}
	}
	roots = prune_roots(l, roots)
	if (len(roots) > 0 || len(plans) > 0) && l.inc.quotes { return bail(l, "generated quotes") }
	rebuilt := 0
	for r in roots { rebuilt += subtree_size(l, r) }
	for &pl in plans { rebuilt += pl.old != NONE ? subtree_size(l, pl.old) : 1 }
	if f32(rebuilt + len(dirty) + len(styled_dirty)) > set.inc_max_ratio * f32(len(l.boxes) - l.inc.dead_boxes) { return bail(l, "too much changed") }

	// the display list can be spliced only when nothing but the content of some inline contexts changed
	vp_changed := l.viewport != input.viewport
	images_changed := input.images_generation != l.inc.images_gen
	fonts_changed := input.fonts_generation != l.inc.fonts_gen
	pass.segs_ok = layout_changes == 0 && !fonts_changed
	cand: map[i32]Splice_Root
	if set.inc_splice && len(plans) == 0 && layout_changes == 0 && len(dirty) == 0 && !vp_changed &&
	   !images_changed && !fonts_changed {
		cand = splice_candidates(l, st, roots[:])
		pass.snapping = len(cand) == len(roots)
	}

	// from here on the layout changes: a failure falls back to a full pass, which starts from nothing
	l.last_pass = .Incremental
	start_items := len(l.inline_items)
	start_boxes := len(l.boxes)
	// boxes made again go at the end and dead ones stay: the arrays are no longer in tree order (finish walks the tree)
	if len(roots) > 0 || len(plans) > 0 { l.tree_order = false; l.tree_gen += 1 }
	for r in roots { kill_contents(&c, r) }
	drop_planned(&c, plans[:])
	// before the styles are re-read: anonymous children follow them
	for bi in styled_dirty { if .Dead not_in l.boxes[bi].flags { mark_dirty(l, bi) } }
	if !same_pass || !remap_journaled(&c, style_changes) {
		if !remap_styles(&c) { return bail(l, "an element lost its style") }
	}
	is_root := make(map[i32]bool, len(roots), context.temp_allocator)
	for r in roots {
		is_root[r] = true
		rebuild_contents(&c, r)
		mark_dirty(l, r)
	}
	place_children(&c, plans[:], is_root)
	if len(roots) > 0 || len(plans) > 0 {
		group_items(&c, start_items)
		l.doc_scroll_y = true
		propagate_overflow(&c)
		mark_bfc_floats(&c, i32(start_boxes))   // a rebuilt root's ancestors keep theirs: at worst they cache less
	}
	for bi in styled_dirty {
		if .Dead in l.boxes[bi].flags { continue }
		mark_anon_dirty(l, bi)
		mark_box_flow_flags(l, bi)   // a margin may have become negative
	}
	for bi in dirty { if .Dead not_in l.boxes[bi].flags { mark_dirty(l, bi) } }
	if vp_changed { mark_dirty(l, 0) }
	if images_changed { check_natural_sizes(&c) }
	if fonts_changed { check_fonts(&c) }
	if pass.snapping {
		pass.snapped = make([]bool, len(l.boxes), context.temp_allocator)
		pass.snap = make([dynamic]Snap, 0, 256, context.temp_allocator)
	}
	l.inc.live_boxes += len(l.boxes) - start_boxes
	l.inc.live_items += len(l.inline_items) - start_items
	l.inc.last_rebuilt = len(l.boxes) - start_boxes

	// widths that change everywhere (the viewport's, a font), or many boxes made again or restyled: the paragraphs that
	// will be laid out again are, ahead, on the layout threads
	pass.wide = (vp_changed && l.viewport.x != input.viewport.x) || fonts_changed ||
		l.inc.last_rebuilt + len(dirty) + len(styled_dirty) >= set.threads_min_contexts
	note_inputs(l, input)
	l.passes[.Incremental] += 1
	t1 := time.tick_now()
	pre_run(&c, layout_root)
	l.inc.last_laid = len(pass.laid)
	t2 := time.tick_now()
	t3, t4: time.Tick
	l.inc.last_spliced = false
	if pass.snapping && try_splice(&c, roots[:], cand, input) {
		l.inc.last_spliced = true
		t3 = time.tick_now()
		t4 = t3
	} else {
		finish(&c)
		t3 = time.tick_now()
		build_display_list(&c)
		note_refresh_inputs(l, same_boxes = len(roots) == 0 && len(plans) == 0)
		t4 = time.tick_now()
		build_bands(l, max(input.band_h, 16) * input.scale)
	}
	compact_lines(l)
	t5 := time.tick_now()
	l.stats = {ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4), ms(t4, t5)}
	if set.inc_verify { verify_against_full(l, input) }
	return true
}

// The nearest ancestor-or-self of `h` in `touched` (NIL: none).
@(private)
touched_ancestor :: proc(c: ^Ctx, h: base.Handle, touched: map[base.Handle]bool) -> base.Handle {
	for cur := h; cur != base.NIL_HANDLE; {
		if cur in touched { return cur }
		if dom.get(c.d, cur) == nil { return base.NIL_HANDLE }
		cur = up(c, cur)
	}
	return base.NIL_HANDLE
}

@(private)
box_inside :: proc(l: ^Layout, x, ancestor: i32) -> bool {
	for p := x; p != NONE; p = l.boxes[p].parent { if p == ancestor { return true } }
	return false
}

// Rebuild roots, without those inside another one (its rebuild makes them again).
@(private)
prune_roots :: proc(l: ^Layout, roots: [dynamic]i32) -> [dynamic]i32 {
	if len(roots) <= 1 { return roots }
	is_root := make(map[i32]bool, len(roots), context.temp_allocator)
	for r in roots { is_root[r] = true }
	taken := make(map[i32]bool, len(roots), context.temp_allocator)
	out := make([dynamic]i32, 0, len(roots), context.temp_allocator)
	for r in roots {
		if taken[r] { continue }
		covered := false
		for p := l.boxes[r].parent; p != NONE; p = l.boxes[p].parent {
			if is_root[p] { covered = true; break }
		}
		if covered { continue }
		taken[r] = true
		append(&out, r)
	}
	return out
}

@(private)
subtree_size :: proc(l: ^Layout, bi: i32) -> int {
	n := 0
	stack := make([dynamic]i32, 0, 32, context.temp_allocator)
	append(&stack, bi)
	for len(stack) > 0 {
		x := pop(&stack)
		n += 1
		for ch := l.boxes[x].first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
	}
	return n
}

// Every live box and inline item takes the style the element now has (a restyle hands out new records). Anonymous
// boxes copy their parent's inherited values: made again when the parent's style changed. false: some element lost
// its style (the journals missed something): the caller does a full pass.
@(private)
remap_styles :: proc(c: ^Ctx) -> bool {
	l := c.l
	st := c.st
	changed := make([]bool, len(l.boxes), context.temp_allocator)
	for i in 0 ..< len(l.boxes) {
		b := &l.boxes[i]
		if .Dead in b.flags { continue }
		old := b.cs
		if .Root in b.flags {
			b.cs = anon_style(c, st.initial, .Block)
		} else if b.node == base.NIL_HANDLE {
			if b.parent == NONE { continue }
			p := &l.boxes[b.parent]
			if changed[b.parent] || .Dirty in p.inc {
				ncs := anon_style(c, p.cs, b.cs.display)
				if b.kind == .Table { ncs.border_spacing = p.cs.border_spacing }
				b.cs = ncs
			}
		} else {
			el := style.style_of(st, b.node)
			if el == nil { return false }
			nc := el
			if .Pseudo in b.flags { nc = .Pseudo_After in b.flags ? el.after : el.before }
			if nc == nil { return false }
			b.cs = nc
		}
		changed[i] = b.cs != old
	}
	for &it in l.inline_items {
		if it.cs == nil { continue }
		switch it.src {
		case .Initial: it.cs = st.initial
		case .Element, .Before, .After:
			el := style.style_of(st, it.node)
			if el == nil { return false }
			nc := el
			if it.src == .Before { nc = el.before } else if it.src == .After { nc = el.after }
			if nc == nil { return false }
			it.cs = nc
		}
	}
	return true
}

// remap_styles for partial restyles of the same style pass: only the elements of the style journal got new records.
// Their boxes, generated boxes, the anonymous boxes inside those and their inline items are re-pointed. false: an
// element with a new record has items but no box of its own (display: contents...): the caller re-points everything.
@(private)
remap_journaled :: proc(c: ^Ctx, changes: []style.Journal_Entry) -> bool {
	l := c.l
	st := c.st
	if len(changes) == 0 { return true }
	done := make(map[base.Handle]bool, len(changes), context.temp_allocator)
	ifcs := make([dynamic]i32, 0, 4, context.temp_allocator)
	// the anonymous boxes inside `x` copy its inherited values: made again from its new style
	anon_below :: proc(c: ^Ctx, x: i32, ifcs: ^[dynamic]i32) {
		l := c.l
		for ch := l.boxes[x].first; ch != NONE; ch = l.boxes[ch].next {
			k := &l.boxes[ch]
			if .Dead in k.flags || .Anonymous not_in k.flags || k.cs == nil { continue }
			p := &l.boxes[x]
			ncs := anon_style(c, p.cs, k.cs.display)
			if k.kind == .Table { ncs.border_spacing = p.cs.border_spacing }
			l.boxes[ch].cs = ncs
			if .Ifc in l.boxes[ch].flags { append(ifcs, ch) }
			anon_below(c, ch, ifcs)
		}
	}
	for &e in changes {
		h := e.node
		if h in done { continue }
		done[h] = true
		bi := live_box(l, h)
		el := style.style_of(st, h)
		if bi == NONE {
			if el == nil || hidden_now(c, h) { continue }   // no box: nothing points at its record
			return false
		}
		if el == nil { return false }
		clear(&ifcs)
		b := &l.boxes[bi]
		b.cs = el
		if b.ifc_root != NONE { append(&ifcs, b.ifc_root) }
		if .Ifc in b.flags { append(&ifcs, bi) }
		anon_below(c, bi, &ifcs)
		for ch := l.boxes[bi].first; ch != NONE; ch = l.boxes[ch].next {
			k := &l.boxes[ch]
			if .Dead in k.flags || .Pseudo not_in k.flags || k.node != h { continue }
			nc := .Pseudo_After in k.flags ? el.after : el.before
			if nc == nil { return false }
			k.cs = nc
			if .Ifc in k.flags { append(&ifcs, ch) }
			anon_below(c, ch, &ifcs)
		}
		for r in ifcs {
			rb := &l.boxes[r]
			for i in rb.items[0] ..< rb.items[1] {
				it := &l.inline_items[i]
				if it.cs == nil || it.node != h { continue }
				switch it.src {
				case .Initial: it.cs = st.initial
				case .Element: it.cs = el
				case .Before, .After:
					nc := it.src == .Before ? el.before : el.after
					if nc == nil { return false }
					it.cs = nc
				}
			}
		}
	}
	return true
}

// Natural sizes that changed since they were used (an image decoded): those replaced boxes are laid out again.
@(private)
check_natural_sizes :: proc(c: ^Ctx) {
	l := c.l
	for i in 0 ..< i32(len(l.boxes)) {
		b := &l.boxes[i]
		if b.kind != .Replaced || .Dead in b.flags { continue }
		inf := l.inc.info[i]
		w, h, hw, hh := natural_size_of(c, i)
		if !inf.natural_ok || inf.natural != {w, h} || inf.natural_has != {hw, hh} { mark_dirty(l, i) }
	}
}

// Faces that changed (a web font arrived): every font is resolved again; the boxes and texts using one that changed
// are laid out again.
@(private)
check_fonts :: proc(c: ^Ctx) {
	l := c.l
	changed := make([]bool, len(l.fonts), context.temp_allocator)
	any := false
	for &f, i in l.fonts {
		old := f
		font_resolve(c, &f)
		if old.font != f.font || old.ascent != f.ascent || old.descent != f.descent || old.x_height != f.x_height || old.space != f.space {
			changed[i] = true
			any = true
		}
	}
	if !any { return }
	for i in 0 ..< i32(len(l.boxes)) {
		b := &l.boxes[i]
		if .Dead in b.flags { continue }
		if b.fi >= 0 && int(b.fi) < len(changed) && changed[b.fi] { mark_dirty(l, i) }
	}
	for &it in l.inline_items {
		if it.cs == nil || it.kind != .Text { continue }
		if int(it.fi) < len(changed) && changed[it.fi] && .Dead not_in l.boxes[it.ifc].flags { mark_dirty(l, it.ifc) }
	}
}

// The segments (words, spaces, inline box edges, with their widths) of inline formatting context `bi` measured by an
// earlier pass, when they still hold: the context was not rebuilt, and nothing that measures changed in this pass (no
// style change for layout, no new font face). Empty range: measure.
@(private)
cached_segs :: proc(c: ^Ctx, bi: i32) -> [2]i32 {
	if c.inc == nil || !c.inc.segs_ok { return {} }
	return c.l.inc.info[bi].segs
}

@(private)
keep_segs :: proc(c: ^Ctx, bi: i32, segs: []Seg) {
	if c.pre != nil && c.pre.streaming {
		// the layout threads read the kept segments meanwhile: Inc_State.segs grows once they are done
		append(&c.pre.pending_segs, Pending_Segs{bi, slice.clone(segs, context.temp_allocator)})
		return
	}
	s := &c.l.inc
	inf := &s.info[bi]
	s.dead_segs += int(inf.segs[1] - inf.segs[0])
	n := i32(len(s.segs))
	append(&s.segs, ..segs)
	inf.segs = {n, n + i32(len(segs))}
}

// Lines and fragments of contexts laid out again stay behind in the arrays: packed when they are the larger part.
// Likewise the kept segments.
@(private)
compact_lines :: proc(l: ^Layout) {
	s := &l.inc
	if s.dead_segs * 2 > len(s.segs) && s.dead_segs > 1024 {
		segs := make([dynamic]Seg, 0, len(s.segs) - s.dead_segs, context.temp_allocator)
		for &inf, i in s.info {
			if .Dead in l.boxes[i].flags || inf.segs[1] <= inf.segs[0] { inf.segs = {}; continue }
			n := i32(len(segs))
			append(&segs, ..s.segs[inf.segs[0]:inf.segs[1]])
			inf.segs = {n, i32(len(segs))}
		}
		clear(&s.segs); append(&s.segs, ..segs[:])
		s.dead_segs = 0
	}
	// a resize lays every paragraph out again: as many lines die as live at each pass. Packing then waits until the dead
	// ones are `inc_line_garbage` times the live ones, and goes to spare arrays that swap with the layout's (one copy)
	r := f32(l.settings.inc_line_garbage)
	if f32(s.dead_frags) <= r * f32(len(l.frags) - s.dead_frags) && f32(s.dead_lines) <= r * f32(len(l.lines) - s.dead_lines) { return }
	lines := &s.spare_lines
	frags := &s.spare_frags
	clear(lines); clear(frags)
	// room for the passes until the next packing: no growth (a copy of everything) in between
	room :: proc(live: int, r: f32) -> int { return int(f32(live) * (1 + r)) + live / 8 + 64 }
	reserve(lines, room(len(l.lines) - s.dead_lines, r))
	reserve(frags, room(len(l.frags) - s.dead_frags, r))
	for &b in l.boxes {
		if .Dead in b.flags || b.lines[1] <= b.lines[0] { continue }
		l0 := i32(len(lines))
		// a context's fragments are contiguous: one copy, the lines shifted by as much
		fa, fb := l.lines[b.lines[0]].frags[0], l.lines[b.lines[1] - 1].frags[1]
		d := i32(len(frags)) - fa
		append(frags, ..l.frags[fa:fb])
		for li in b.lines[0] ..< b.lines[1] {
			ln := l.lines[li]
			ln.frags += d
			append(lines, ln)
		}
		b.lines = {l0, i32(len(lines))}
	}
	l.lines, s.spare_lines = s.spare_lines, l.lines
	l.frags, s.spare_frags = s.spare_frags, l.frags
	s.dead_lines, s.dead_frags = 0, 0
}

// Floats that take part in the block formatting context of their ancestors: those ancestors (up to the formatting
// context root, excluded) cannot cache their layout in flow (block.odin). Likewise boxes with a negative vertical
// margin: content inside their ancestors may rise above where those start, next to floats placed before.
@(private)
mark_bfc_floats :: proc(c: ^Ctx, from: i32) {
	for i in from ..< i32(len(c.l.boxes)) { mark_box_flow_flags(c.l, i) }
}

@(private)
mark_box_flow_flags :: proc(l: ^Layout, i: i32) {
	negative :: proc(m: style.Length) -> bool {
		#partial switch m.kind {
		case .Px, .Percent: return m.v < 0
		case .Calc: return true
		}
		return false
	}
	b := &l.boxes[i]
	if .Dead in b.flags { return }
	flags: Box_Flags
	if .Float in b.flags { flags += {.Bfc_Floats} }
	if b.cs != nil && (negative(b.cs.margin[.Top]) || negative(b.cs.margin[.Bottom])) { flags += {.Neg_Margins} }
	if flags == {} { return }
	for p := b.parent; p != NONE; p = l.boxes[p].parent {
		pb := &l.boxes[p]
		if .Bfc in pb.flags || flags <= pb.flags { break }   // the rest of the chain is marked already
		pb.flags += flags
	}
}
