package layout

import "core:sync"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:style"

// The refresh path: when only paint-only values changed since the last full layout (style.layout_equal: transforms,
// opacity, colors, backgrounds, shadows, radii... the usual animations and hover effects), the document unchanged or changed
// only in the style attributes of HTML elements (styles_only_mutations), the boxes, lines and display
// list stay; only what is derived from those values is updated:
//   * the computed-style pointers of boxes, inline items and display items (an animation overlay or a partial restyle
//     hands out new Computed records), and the inherited paint-only values copied into anonymous boxes;
//   * the matrix of every Transform space, the alpha of every opacity group, the radii of every clip;
//   * the scrollable overflow and the document extent, when a transform applies (transformed bounds count).
// Anything that would change the structure (a scroll container starting or stopping to scroll, a node without a style)
// makes the refresh give up; the caller then lays out as usual.

@(private)
can_refresh :: proc(l: ^Layout, input: Input) -> bool {
	if !l.valid || l.last_pass == .None || !input.settings.paint_refresh || l.anchor_stale { return false }
	st := input.styled
	return l.styled == rawptr(st) && l.layout_serial == st.layout_serial && l.canvas == st.canvas &&
		styles_only_mutations(l, input.doc) && l.viewport == input.viewport && l.scale == input.scale &&
		l.settings == input.settings^ && l.inc.images_gen == input.images_generation && l.inc.fonts_gen == input.fonts_generation
}

// The document changed since the last pass by nothing but the `style` attributes of HTML elements: those reach layout through the
// styles only, and the styles tell whether that was paint-only (layout_serial). A script that moves something by its inline
// transform at every frame (the licence card of about:wren, tilted by the pointer) then makes refresh passes, not layouts, and the
// compositor keeps what it retained.
@(private = "file")
styles_only_mutations :: proc(l: ^Layout, d: ^dom.Document) -> bool {
	if l.mutations == d.mutations { return true }
	if len(l.foreign_objects) > 0 { return false }   // (an attribute inside an inline <svg> with foreign objects: incremental.odin)
	changes, ok := dom.journal_since(d, l.mutations)
	if !ok { return false }
	for &e in changes {
		if e.kind != .Attribute || e.name != "style" || e.ns != dom.ATTR_NS_NONE { return false }
		if n := dom.get(d, e.node); n == nil || n.ns != .HTML { return false }
	}
	return true
}

// Inherited paint-only properties: what an anonymous box takes from its parent that can change without a layout.
@(private) anon_once: sync.Once
@(private) anon_list: [len(style.Prop)]style.Prop
@(private) anon_count: int

@(private)
anon_paint_props :: proc() -> []style.Prop {
	sync.once_do(&anon_once, proc() {
		// prop_tier first: it initializes the property tables is_inherited reads
		for p in style.Prop {
			if style.prop_tier(p) == .Paint && style.is_inherited(p) { anon_list[anon_count] = p; anon_count += 1 }
		}
	})
	return anon_list[:anon_count]
}

// After a full layout: what the refresh path needs to find quickly. `same_boxes`: no box or item was made or removed
// since the last call (loose_styles holds).
@(private)
note_refresh_inputs :: proc(l: ^Layout, same_boxes := false) {
	l.canvas_items = {NONE, NONE}
	root_el := l.boxes[0].first
	clear(&l.deco_items)
	for &it, i in l.items {
		#partial switch it.kind {
		case .Box:
			if it.box < 0 { continue }
			if it.box == root_el { l.canvas_items[0] = i32(i) }
			// a box's item carries its element (hit_node): only the body's item needs its box read
			if it.node != l.canvas_els[1] { continue }
			if b := &l.boxes[it.box]; b.node == l.canvas_els[1] && b.node != base.NIL_HANDLE && .Pseudo not_in b.flags { l.canvas_items[1] = i32(i) }
		case .Text:
			if it.deco != {} && it.deco_box > 0 { append(&l.deco_items, i32(i)) }
		}
	}
	if same_boxes { return }
	l.loose_styles = false
	for &it in l.inline_items {
		if it.node != base.NIL_HANDLE && box_index(l, it.node) == NONE { l.loose_styles = true; break }
	}
}

@(private)
refresh :: proc(l: ^Layout, input: Input) -> bool {
	t0 := time.tick_now()
	st := input.styled
	// (anon_style of the initial values: of this pass's)
	if len(l.boxes) > 0 && .Root in l.boxes[0].flags && l.boxes[0].cs != nil { l.boxes[0].cs.inherited_group = st.initial.inherited_group }
	// (what a journaled attempt that gave up re-pointed already counts as replaced: `replaced` goes on from it)
	touched := make([dynamic]i32, 0, 16, context.temp_allocator)
	ok, replaced := refresh_journaled(l, st, &touched)
	if !ok {
		if !refresh_all_boxes(l, st, &replaced) { return false }
		// every text belongs to an element with a box, and no box got a new record: the inline items are up to date
		if (replaced || l.loose_styles) && !refresh_all_items(l, st) { return false }
	}
	if !replaced && !l.loose_styles { return refresh_rest(l, input, t0) }
	l.restyled += 1
	// each display item from its box or inline item, not from the record it had: alike elements shared that record, and
	// only some of them have another one now (a hover on one link of a nav). From the journal: only the items of the
	// boxes it touched, not every item of the page at each frame
	if ok { remap_box_items(l, touched[:]) } else { remap_display_items(l) }
	return refresh_rest(l, input, t0)
}

// The new records of anonymous boxes made by one refresh, by the parent record they copy from (anon_style's key).
@(private = "file")
Fresh_Anon :: map[Anon_Key]^style.Computed

// An anonymous box takes again what it copies from its parent's style: the inherited paint-only values. anon_style
// shares one record among the anonymous boxes of parents with the same record: written in place while the parent keeps
// its record (an overlay rewritten in place: every sharer's parent has it), a new one when `parent_moved` (the parent
// points at another record now, the other sharers' parents may not). true: the box got a new record.
@(private = "file")
refresh_anon :: proc(l: ^Layout, x: i32, anon: []style.Prop, parent_moved: bool, fresh: ^Fresh_Anon) -> bool {
	b := &l.boxes[x]
	if b.parent == NONE || b.cs == nil { return false }
	pc := l.boxes[b.parent].cs
	if parent_moved {
		key := Anon_Key{pc, b.cs.display}
		if s, ok := fresh[key]; ok { b.cs = s; return true }
		s := new(style.Computed, base.arena_allocator(&l.arena))
		s^ = b.cs^   // (layout values equal under the new parent's record: a refresh needs style.layout_equal)
		b.cs = s
		fresh[key] = s
	}
	// its inherited group is the parent's (anon_style): the one of a restyled parent, the old one being in an arena that may be gone
	b.cs.inherited_group = pc.inherited_group
	b.cs.custom = pc.custom   // (its custom properties too: paint-only values may be all that changed, with them; and that table goes with the old record)
	for p in anon { style.copy_prop(b.cs, pc, p) }
	anon_current_color(b.cs)
	return parent_moved
}

// Every box re-pointed at its element's record. `replaced`: some box got another record. false: some element lost its style.
@(private = "file")
refresh_all_boxes :: proc(l: ^Layout, st: ^style.Styled, replaced: ^bool) -> bool {
	anon := anon_paint_props()
	fresh := make(Fresh_Anon, 16, context.temp_allocator)
	moved := make([]bool, len(l.boxes), context.temp_allocator)   // the box points at another record than before
	// boxes in index order: a parent comes before its children (anonymous boxes copy from their parent)
	for &b, i in l.boxes {
		if .Dead in b.flags || .Root in b.flags { continue }
		if b.node == base.NIL_HANDLE {
			if b.parent != NONE { moved[i] = refresh_anon(l, i32(i), anon, moved[b.parent], &fresh) }
			continue
		}
		el := style.style_of(st, b.node)
		if el == nil { return false }
		nc := el
		if .Pseudo in b.flags { nc = pseudo_style(el, b.pseudo) }
		if nc == nil { return false }
		// (its own record, made again in place: the same pointer, which no other box's anonymous children share)
		if .Foreign in b.flags { foreign_restyle(l, i32(i), nc); continue }
		if nc == b.cs { continue }   // an animation overlay is rewritten in place: same record, new values
		b.cs = nc
		moved[i] = true
		replaced^ = true
	}
	return true
}

// Every inline item re-pointed at its element's record. false: some element lost its style.
@(private = "file")
refresh_all_items :: proc(l: ^Layout, st: ^style.Styled) -> bool {
	for &it in l.inline_items {
		if it.cs == nil { continue }
		if it.node == base.NIL_HANDLE { continue }   // the initial style: the same record for the whole pass
		// the element's record now: also for text whose owner generates no box (display: contents), and for items of an
		// unchanged element's ::before / ::after (their record is the pseudo-element's, not the element's)
		el := style.style_of(st, it.node)
		nc := el
		if el != nil {
			#partial switch it.src {
			case .Before: nc = el.before
			case .After: nc = el.after
			}
		}
		if nc == nil { return false }
		it.cs = nc
	}
	return true
}

// refresh_all_boxes and refresh_all_items for the elements of the style journal only: the styles are of the same pass
// as the layout, changed since only as its journal says (a hover, an animation tick: a few elements, not the document).
// Their boxes, generated boxes, the anonymous boxes inside those and their inline items are re-pointed; `touched` gets
// the boxes whose display items have a record to re-point (Display_Item.box). ok = false: the
// journal does not tell enough (another style pass, forgotten entries, text whose element has no box, foreign objects,
// whose style also follows the SVG around them): the caller re-points everything, which gives the same result.
@(private = "file")
refresh_journaled :: proc(l: ^Layout, st: ^style.Styled, touched: ^[dynamic]i32) -> (ok, replaced: bool) {
	if l.styled_pass != st.pass_id || l.loose_styles || len(l.foreign_objects) > 0 { return false, false }
	changes: []style.Journal_Entry
	if st.serial != l.serial {
		have: bool
		changes, have = style.journal_since(st, l.serial)
		if !have { return false, false }
	}
	if len(changes) == 0 { return true, false }
	anon := anon_paint_props()
	done := make(map[base.Handle]bool, len(changes), context.temp_allocator)
	ifcs := make([dynamic]i32, 0, 8, context.temp_allocator)
	stack := make([dynamic]i32, 0, 8, context.temp_allocator)
	fresh := make(Fresh_Anon, 8, context.temp_allocator)
	// the anonymous boxes inside `x`, parents first: their inherited values again; their contexts hold its text. `moved`:
	// `x` points at another record than before, and so does each of them then (refresh_anon), whose items get re-pointed
	anon_below :: proc(l: ^Layout, x: i32, moved: bool, anon: []style.Prop, fresh: ^Fresh_Anon, stack, ifcs, touched: ^[dynamic]i32) {
		clear(stack)
		append(stack, x)
		for len(stack) > 0 {
			p := pop(stack)
			for ch := l.boxes[p].first; ch != NONE; ch = l.boxes[ch].next {
				k := &l.boxes[ch]
				if .Dead in k.flags || .Anonymous not_in k.flags { continue }
				if refresh_anon(l, ch, anon, moved, fresh) { append(touched, ch) }
				if .Ifc in k.flags { append(ifcs, ch) }
				append(stack, ch)
			}
		}
	}
	for &e in changes {
		h := e.node
		if h in done { continue }
		done[h] = true
		bi := live_box(l, h)
		// no box: nothing points at its record (every text belongs to an element with a box: loose_styles)
		if bi == NONE { continue }
		el := style.style_of(st, h)
		if el == nil || el.backdrop != nil { return false, replaced }   // (a ::backdrop box is beside its own, not inside)
		clear(&ifcs)
		b := &l.boxes[bi]
		moved := b.cs != el
		if moved { b.cs = el; replaced = true; append(touched, bi) }
		if b.ifc_root != NONE { append(&ifcs, b.ifc_root) }
		if .Ifc in b.flags { append(&ifcs, bi) }
		anon_below(l, bi, moved, anon, &fresh, &stack, &ifcs, touched)
		// its generated boxes: children of its box, or of the anonymous blocks wrapping its inline content
		pseudos := make([dynamic]i32, 0, 8, context.temp_allocator)
		append(&pseudos, bi)
		for len(pseudos) > 0 {
			x := pop(&pseudos)
			for ch := l.boxes[x].first; ch != NONE; ch = l.boxes[ch].next {
				k := &l.boxes[ch]
				if .Dead in k.flags { continue }
				if .Anonymous in k.flags { append(&pseudos, ch); continue }
				if .Pseudo not_in k.flags || k.node != h { continue }
				nc := pseudo_style(el, k.pseudo)
				if nc == nil { return false, replaced }
				pmoved := k.cs != nc
				if pmoved { k.cs = nc; replaced = true; append(touched, ch) }
				if .Ifc in k.flags { append(&ifcs, ch) }
				anon_below(l, ch, pmoved, anon, &fresh, &stack, &ifcs, touched)
			}
		}
		for r in ifcs {
			rb := &l.boxes[r]
			for i in rb.items[0] ..< rb.items[1] {
				it := &l.inline_items[i]
				if it.cs == nil || it.node != h { continue }
				nc := el
				#partial switch it.src {
				case .Before: nc = el.before
				case .After: nc = el.after
				}
				if nc == nil { return false, replaced }
				if it.cs != nc {
					it.cs = nc
					replaced = true
					// (its text's items have the box of its enclosing inline box, else of its context: emit_lines)
					append(touched, it.box != NONE ? it.box : it.ifc)
				}
			}
		}
	}
	return true, replaced
}

@(private = "file")
refresh_rest :: proc(l: ^Layout, input: Input, t0: time.Tick) -> bool {
	if !refresh_paint_values(l, input) { return false }
	l.serial = input.styled.serial
	l.mutations = input.doc.mutations
	l.last_pass = .Refresh
	l.passes[.Refresh] += 1
	ms := f32(time.duration_milliseconds(time.tick_since(t0)))
	l.stats = {0, ms, 0, 0, 0}
	return true
}

// What the display list derives from paint-only values, read again from the styles of the boxes. false: a scroll
// container would start or stop scrolling (a full finishing pass is needed).
@(private)
refresh_paint_values :: proc(l: ^Layout, input: Input) -> bool {
	st := input.styled
	// the root's or body's background is the canvas: painted by the shell, not by their item
	for ii in l.canvas_items {
		if ii < 0 { continue }
		it := &l.items[ii]
		if l.boxes[it.box].cs.background_color == st.canvas { it.flags += {.No_Background} } else { it.flags -= {.No_Background} }
	}
	for &g in l.groups { g.alpha = max(l.boxes[g.box].cs.opacity, 0) }
	groups_reach(l)
	transforms := false   // some transform moved: the scrollable overflow follows
	for &sp in l.spaces {
		if sp.kind != .Transform { continue }
		m := box_matrix(l, &l.boxes[sp.box])
		if m != sp.mat { sp.mat = m; transforms = true }
		if sp.proj {
			// a plane: its 4x4 and the perspective it sits in (animations move both without a layout)
			m4 := box_matrix4(l, &l.boxes[sp.box])
			if m4 != sp.mat4 { sp.mat4 = m4; transforms = true }
			if sp.persp_from != NONE {
				pm := perspective_of(l, &l.boxes[l.spaces[sp.persp_from].box])
				if pm != sp.persp { sp.persp = pm; transforms = true }
			}
			sp.back_hidden = l.boxes[sp.box].cs.backface_visibility == .Hidden
			sp.preserve = used_preserve_3d(l.boxes[sp.box].cs)
		}
	}
	for &cl in l.clips { if cl.box != NONE { cl.radii = clip_radii(l, &l.boxes[cl.box]) } }   // (NONE: a column's)
	if transforms && !refresh_overflow(l, l.icb) { return false }
	return true
}

// Scrollable overflow again (the transformed bounds moved). false: some container would start or stop scrolling.
@(private)
refresh_overflow :: proc(l: ^Layout, vp: Vec2) -> bool {
	order := preorder(l)
	doc := compute_overflow(l, order, fixed_boxes(l, order), vp)
	l.inc.doc_extent = doc
	for &b, bi in l.boxes {
		if .Scroll not_in b.flags || .Propagated in b.flags || b.kind == .Inline || .Dead in b.flags { continue }
		port := padding_rect(&b)
		bf := &l.fin[bi]
		mn, ms := scroll_limits(&b, bf.overflow, port)
		scrolls := ms.x > BAR_MIN_OVERFLOW || ms.y > BAR_MIN_OVERFLOW || mn.x < -BAR_MIN_OVERFLOW || mn.y < -BAR_MIN_OVERFLOW
		if scrolls != (bf.scroll_space != NONE) { return false }
		if !scrolls { continue }
		l.spaces[bf.scroll_space].max_scroll = ms
		l.spaces[bf.scroll_space].min_scroll = mn
		if off, ok := l.scroll[b.node]; ok { l.scroll[b.node] = {clamp(off.x, mn.x, ms.x), clamp(off.y, mn.y, ms.y)} }
	}
	note_doc_extent_y(l, doc, vp)
	note_doc_extent_x(l, doc, vp)
	return true
}
