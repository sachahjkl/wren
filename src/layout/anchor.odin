package layout

import "core:slice"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

// CSS Anchor Positioning 1: the boxes that use anchors.
//
// Such a box waits (layout_abs_list leaves it out, and sets Layout.anchor_uses): the box of its anchor is known only when
// the whole document is laid out, and its size or position cannot change anything else (an absolutely positioned box takes
// no room). anchored_pass, at the end of a block layout, full or incremental, goes over all of them in tree order: what they
// depend on (anchors, containing blocks) may have moved whichever boxes were laid out again, and only there. Each one:
//   * its style, then the options of position-try-fallbacks one by one (a copy of the style with the rule and tactics of
//     the option applied), with anchor() and anchor-size() replaced by lengths; position-area and anchor-center make the
//     rectangle it is laid out in (its inset-modified containing block) smaller;
//   * laid out by layout_abs with that copy as its style, for the time of the call: a box keeps pointing at its element's
//     record, so incremental passes find it as they expect;
//   * an option that does not overflow stays until it no longer fits: the choice of the last frame (Layout.anchor_last, which
//     survives full passes; anchored_commit), not what layouts a script forces in between found.
//
// Scrolling. Offsets are not part of layout: a box follows the scroll containers around its default anchor through a space
// of its own (Space_Kind.Anchored), whose offset is what they add to the offset of its containing block: no layout on
// scroll. Only when what was chosen depends on scrolling (fallbacks, position-visibility) does a change of offset ask for
// a pass (Layout.anchor_stale).
//
// Writing modes: everything here is physical (anchored_pass comes after frames_to_physical); the flow-relative keywords take the
// axis they mean for the containing block's mode, or the box's.

// Overflow below this (device px) is rounding: the option fits.
ANCHOR_FIT_EPSILON :: f32(0.01)
// Anchored boxes shifted by the scrolling of a chain of anchors: bound on that chain.
ANCHOR_CHAIN_MAX :: 64
// Boxes of one name looked at for one reference: thousands of unacceptable ones cost no more than this per reference.
ANCHOR_LOOKUP_MAX_TRIES :: 1024

Anchor_Key :: struct { node: base.Handle, pseudo: u8 }

// What the option was chosen for: when the box's style changes, the choice starts again.
Anchor_Last :: struct { option: i32, sig: u64 }

// One box anchored_pass laid out.
Anchored :: struct {
	box:     i32,
	anchor:  i32,             // its default anchor (NONE: none)
	follow:  [2]bool,         // the axes in which it follows the scrolling of its default anchor
	shift:   Vec2,            // what that scrolling was, for the pass (device px)
	hidden:  bool,            // position-visibility: painted by nothing
	rect:    Rect,            // the rectangle it was laid out in (relative to `ref`'s origin, as its pos)
	ref:     i32,
	sizes:   [4]style.Length, // resolved min-width, min-height, max-width, max-height (what getComputedStyle answers)
	aligned: [2]bool,         // it was aligned in the rectangle in these axes (position-area, anchor-center, self-alignment)...
	declared: [4]f32,         // ... its insets are then these (CSS px: top, right, bottom, left), not what the alignment left
	auto_inset: [4]bool,      // top, right, bottom, left are auto in what was chosen
}

@(private)
anchor_reset :: proc(l: ^Layout) {
	l.anchor_uses, l.anchor_scroll, l.anchor_stale = false, false, false
	clear(&l.anchored)
	clear(&l.anchor_chosen)
	clear(&l.anchor_grid_areas)
}

// The page's scroll offset (device px), for a box whose choice depends on it.
note_doc_scroll :: proc(l: ^Layout, doc_scroll: f32) {
	if doc_scroll == l.anchor_doc_scroll { return }
	l.anchor_doc_scroll = doc_scroll
	if l.anchor_scroll { l.anchor_stale = true }
}

@(private = "file")
A :: struct {
	c:     ^Ctx,
	l:     ^Layout,
	pos:   []i32,                  // box -> place in tree order (-1: not in the tree)
	names: map[string][dynamic]i32,   // anchor name -> boxes, in tree order
	entry: []i32,                  // box -> its index in l.anchored (NONE)
}

// A style being tried for box `q`.
@(private = "file")
Prep :: struct {
	cs:      ^style.Computed,    // the copy, lengths resolved
	anchor:  i32,                // default anchor
	imcb:    Rect,               // what it is laid out in
	inner:   Rect,               // imcb less its insets
	moves:   [2][2]bool,         // per axis, the start and end edges of `inner` come from the anchor (they follow its scrolling)
	mid:     Vec2,               // anchor-center: the middle of the anchor
	cb:      Rect,               // the containing block
	ref:     i32,
	align:   [2]Align_Mode,
	follow:  [2]bool,
	invalid: bool,               // some anchor() or anchor-size() has nothing to answer and no fallback
	area:    bool,               // position-area is in force
}

@(private = "file")
Align_Mode :: enum u8 { None, Start, Center, End, Anchor }

// Where a length is used: the side of an inset, or just an axis.
@(private = "file")
Len_Use :: struct { side: style.Side, inset: bool, axis_x: bool }

@(private = "file")
containing_or_parent :: #force_inline proc(l: ^Layout, x: i32) -> i32 {
	b := &l.boxes[x]
	if .Root in b.flags { return NONE }
	// (the containing block of a spanner is its multi-column container, whatever is between them: CSS Multicol 1 §6)
	if .Spanner in b.fx { return flow_container(l, x) }
	return containing_parent(l, x)
}

@(private = "file")
tree_root_of :: proc(c: ^Ctx, h: base.Handle) -> base.Handle {
	cur := h
	for {
		n := dom.get(c.d, cur)
		if n == nil { return base.NIL_HANDLE }
		if n.is_shadow || n.parent == base.NIL_HANDLE { return cur }
		cur = n.parent
	}
}

// The anchor-scope around `x` that has `name`: the box, or NONE.
@(private = "file")
scope_of :: proc(l: ^Layout, x: i32, name: string) -> i32 {
	for p := x; p != NONE; p = l.boxes[p].parent {
		s := &l.boxes[p].cs.anchor_scope
		if s.all || slice.contains(s.names, name) { return p }
	}
	return NONE
}

@(private = "file")
inside :: proc(l: ^Layout, x, ancestor: i32) -> bool {
	for p := x; p != NONE; p = l.boxes[p].parent { if p == ancestor { return true } }
	return false
}

// §target: may `a` be the anchor of `q`? It is laid out before it, and in scope. (Boxes with no box are not anchors: they
// have no box; what skipped contents hold is not laid out here either.)
@(private = "file")
acceptable :: proc(ac: ^A, a, q: i32, name: string) -> bool {
	l := ac.l
	if a == q || inside(l, a, q) { return false }
	if s := scope_of(l, a, name); s != NONE && !inside(l, q, s) { return false }
	if ac.c.flat && tree_root_of(ac.c, l.boxes[a].node) != tree_root_of(ac.c, l.boxes[q].node) { return false }
	// the containing blocks of q, up from q
	chain := make([dynamic]i32, 0, 16, context.temp_allocator)
	for x := q; x != NONE; x = containing_or_parent(l, x) { append(&chain, x) }
	// a containing block of q is not an anchor for it: it is not finished when q is laid out
	if slice.contains(chain[1:], a) { return false }
	// a, up to where it meets that chain: under q's containing block, an in-flow box is laid out before q wherever it is, an
	// absolutely positioned one if it comes first; outside of it, only what comes first
	last := a
	for x := containing_or_parent(l, a); x != NONE; x = containing_or_parent(l, x) {
		if i, found := slice.linear_search(chain[:], x); found {
			if i == 0 { return false }
			if i == 1 && .Abs not_in l.boxes[last].flags { return true }
			return ac.pos[last] < ac.pos[chain[i - 1]]
		}
		last = x
	}
	return true
}

// The anchor called `name` for `q`: the last acceptable one in tree order.
@(private = "file")
named_anchor :: proc(ac: ^A, q: i32, name: string) -> i32 {
	list, ok := ac.names[name]
	if !ok { return NONE }
	tries := 0
	#reverse for a in list {
		if acceptable(ac, a, q, name) { return a }
		tries += 1
		if tries >= ANCHOR_LOOKUP_MAX_TRIES { break }
	}
	return NONE
}

// The anchor HTML gives an element (§implicit): the invoker of a popover, the element its `anchor` attribute names; the
// originating element of a pseudo-element.
@(private = "file")
implicit_anchor :: proc(ac: ^A, q: i32) -> i32 {
	l := ac.l
	b := &l.boxes[q]
	if .Pseudo in b.flags { return box_index(l, b.node) }
	if inv, ok := ac.c.d.implicit_anchors[b.node]; ok {
		if bi := box_index(l, inv); bi != NONE { return bi }
	}
	if v, ok := dom.get_attribute(ac.c.d, b.node, "anchor"); ok && v != "" {
		if bi := box_index(l, dom.find_by_id(ac.c.d, v)); bi != NONE { return bi }
	}
	return NONE
}

@(private = "file")
default_anchor :: proc(ac: ^A, q: i32, cs: ^style.Computed, depth := 0) -> i32 {
	switch cs.position_anchor.kind {
	case .None: return NONE
	case .Name: return named_anchor(ac, q, cs.position_anchor.name)
	case .Auto: return implicit_anchor(ac, q)
	case .Normal: return cs.position_area.a != .None ? implicit_anchor(ac, q) : NONE
	case .Match_Parent:
		p := ac.l.boxes[q].parent
		if p == NONE || depth >= ANCHOR_CHAIN_MAX { return NONE }
		pcs := ac.l.boxes[p].cs
		return default_anchor(ac, q, pcs, depth + 1)
	}
	return NONE
}

@(private = "file")
scroll_box_of :: proc(l: ^Layout, x: i32) -> i32 {
	for p := containing_or_parent(l, x); p != NONE; p = containing_or_parent(l, p) {
		if .Scroll in l.boxes[p].flags && .Propagated not_in l.boxes[p].flags && l.boxes[p].kind != .Inline { return p }
		if .Fixed in l.boxes[p].flags { return p }
	}
	return NONE
}

// What scrolling adds to where box `x` is drawn, as far as this pass can know.
@(private = "file")
scrolled :: proc(ac: ^A, x: i32) -> Vec2 {
	l := ac.l
	off: Vec2
	cur := x
	for steps := 0; steps < OFFSET_WALK_MAX_STEPS && cur != NONE; steps += 1 {
		b := &l.boxes[cur]
		if ei := ac.entry[cur]; ei != NONE { off += l.anchored[ei].shift }
		if .Fixed in b.flags { return off }
		if .Root in b.flags { break }
		if cur != x && .Scroll in b.flags && .Propagated not_in b.flags && b.kind != .Inline {
			off -= l.scroll[b.node]
		}
		cur = containing_or_parent(l, cur)
	}
	off -= Vec2{doc_scroll_x_snapped(l), l.anchor_doc_scroll}
	return off
}

// Can scrolling move `a` against `q`?
@(private = "file")
scroll_apart :: proc(l: ^Layout, a, q: i32) -> bool {
	return scroll_box_of(l, a) != scroll_box_of(l, q) || (.Fixed in l.boxes[a].flags) != (.Fixed in l.boxes[q].flags)
}

// The direction of the containing block of box `q`: the viewport has the principal one (CSS Writing Modes 4 §8).
@(private = "file")
cb_is_rtl :: proc(c: ^Ctx, q: i32) -> bool {
	cb := &c.l.boxes[c.l.cold[q].cb]
	if .Root in cb.flags { return principal_rtl(c) }
	return cb.cs != nil && is_rtl(cb.cs)
}

// The border box of an anchor, where it shows: through its columns when it is in a multi-column flow.
@(private = "file")
anchor_rect :: proc(l: ^Layout, x, q: i32) -> Rect {
	r := border_rect(&l.boxes[x])
	if .In_Flow in l.boxes[x].fx {
		mc := flow_container(l, x)
		// (a box in the same flow is positioned in it: as if the columns were one)
		if mc != NONE && !(.In_Flow in l.boxes[q].fx && flow_container(l, q) == mc) { return flow_bounds(l, mc, r) }
	}
	return r
}

// The value of anchor(): as an inset of the side it is in, in CSS px.
@(private = "file")
anchor_position :: proc(ac: ^A, q: i32, p: ^Prep, n: ^css.Calc, use: Len_Use) -> (f32, bool) {
	l := ac.l
	if !use.inset { return 0, false }
	target := n.anchor.name != "" ? named_anchor(ac, q, n.anchor.name) : p.anchor
	if target == NONE { return 0, false }
	r := anchor_rect(l, target, q)
	refabs := l.boxes[p.ref].abs
	axis := use.axis_x ? 0 : 1
	lo, hi := r.min[axis] - refabs[axis], r.max[axis] - refabs[axis]
	start_side := use.side == .Left || use.side == .Top
	// (where this axis starts follows the writing modes of the containing block and of the box)
	rtl := style.axis_start_hi(l.boxes[l.cold[q].cb].wm, cb_is_rtl(ac.c, q), use.axis_x)
	self_rtl := style.axis_start_hi(l.boxes[q].wm, is_rtl(p.cs), use.axis_x)
	at: f32
	#partial switch n.anchor.side {
	case .Left: if !use.axis_x { return 0, false }; at = lo
	case .Right: if !use.axis_x { return 0, false }; at = hi
	case .Top: if use.axis_x { return 0, false }; at = lo
	case .Bottom: if use.axis_x { return 0, false }; at = hi
	case .Inside: at = start_side ? lo : hi
	case .Outside: at = start_side ? hi : lo
	case .Start: at = rtl ? hi : lo
	case .End: at = rtl ? lo : hi
	case .Self_Start: at = self_rtl ? hi : lo
	case .Self_End: at = self_rtl ? lo : hi
	case .Center: at = (lo + hi) / 2
	case .Percent:
		t := f32(css.eval_calc(n.b, css.Length_Context{percent_base = 1}))
		at = rtl ? hi - t * (hi - lo) : lo + t * (hi - lo)
	case: return 0, false
	}
	// the reference follows the anchor's scrolling when it is the default anchor, or scrolls with it
	if p.anchor != NONE && (target == p.anchor || scroll_box_of(l, target) == scroll_box_of(l, p.anchor)) { p.follow[axis] = true }
	v := start_side ? at - p.imcb.min[axis] : p.imcb.max[axis] - at
	return v / ac.c.scale, true
}

@(private = "file")
anchor_dimension :: proc(ac: ^A, q: i32, p: ^Prep, n: ^css.Calc, use: Len_Use) -> (f32, bool) {
	l := ac.l
	target := n.anchor.name != "" ? named_anchor(ac, q, n.anchor.name) : p.anchor
	if target == NONE { return 0, false }
	r := anchor_rect(l, target, q)
	x := use.axis_x
	cbv, selfv := is_vert(l.boxes[l.cold[q].cb].wm), is_vert(l.boxes[q].wm)
	#partial switch n.anchor.side {
	case .Width: x = true
	case .Height: x = false
	case .Inline: x = !cbv
	case .Block: x = cbv
	case .Self_Inline: x = !selfv
	case .Self_Block: x = selfv
	}
	return (x ? r.max.x - r.min.x : r.max.y - r.min.y) / ac.c.scale, true
}

// A copy of the tree with anchor() and anchor-size() replaced by their values or fallbacks. nil: one has neither.
@(private = "file")
tree_resolve :: proc(ac: ^A, q: i32, p: ^Prep, n: ^css.Calc, use: Len_Use) -> ^css.Calc {
	if n == nil { return nil }
	if n.op == .Anchor || n.op == .Anchor_Size {
		v: f32
		ok: bool
		if n.op == .Anchor { v, ok = anchor_position(ac, q, p, n, use) } else { v, ok = anchor_dimension(ac, q, p, n, use) }
		if !ok {
			if n.a != nil { return tree_resolve(ac, q, p, n.a, use) }
			p.invalid = true
			return nil
		}
		leaf := new(css.Calc, context.temp_allocator)
		leaf^ = css.Calc{op = .Dimension, num = f64(v), unit = .Px}
		return leaf
	}
	out := new(css.Calc, context.temp_allocator)
	out^ = n^
	if n.a != nil { out.a = tree_resolve(ac, q, p, n.a, use); if out.a == nil { return nil } }
	if n.b != nil { out.b = tree_resolve(ac, q, p, n.b, use); if out.b == nil { return nil } }
	if n.c != nil { out.c = tree_resolve(ac, q, p, n.c, use); if out.c == nil { return nil } }
	return out
}

@(private = "file")
length_resolve :: proc(ac: ^A, q: i32, p: ^Prep, l: style.Length, use: Len_Use, unset: style.Length) -> style.Length {
	if l.kind != .Anchor { return l }
	if l.calc == nil { return unset }
	tree := tree_resolve(ac, q, p, l.calc, use)
	if tree == nil { return unset }
	if tree.op == .Dimension && tree.unit == .Percent { return style.Length{kind = .Percent, v = f32(tree.num)} }
	return style.Length{kind = .Calc, calc = tree}
}

// How position-area aligns the box in the tracks it chose (§position-area: `normal` self-alignment).
@(private = "file")
area_align :: proc(tr: [2]i8) -> Align_Mode {
	switch {
	case tr[0] == 1 && tr[1] == 1: return .Center
	case tr[1] == 2 && tr[0] > 0: return .Start
	case tr[0] == 0 && tr[1] < 2: return .End
	}
	return .Center
}

@(private = "file")
explicit_align :: proc(a: style.Content_Align, rtl: bool) -> Align_Mode {
	#partial switch a {
	case .Start, .Flex_Start: return rtl ? .End : .Start
	case .End, .Flex_End: return rtl ? .Start : .End
	case .Center, .Anchor_Center: return .Center
	}
	return .None
}

// The style of box `q` for option `opt` (-1: its own), ready for layout_abs.
@(private = "file")
prepare :: proc(ac: ^A, q: i32, base: ^style.Computed, opt: i32, ref: i32, cb: Rect) -> Prep {
	l := ac.l
	v := new(style.Computed, context.temp_allocator)
	v^ = base^
	tactics: []style.Try_Tactic
	if opt >= 0 {
		o := &base.position_try_fallbacks[opt]
		if o.rule != nil { style.try_style_apply(v, o.rule^) }
		if o.area.a != .None { v.position_area = o.area }
		tactics = o.tactics[:o.n_tactics]
		// (named by flow: physical ones for the containing block's writing mode)
		list := make([dynamic]style.Try_Tactic, 0, 6, context.temp_allocator)
		for t in tactics {
			buf: [3]style.Try_Tactic
			n := style.try_tactics_physical(t, l.boxes[l.cold[q].cb].wm, &buf)
			for k in 0 ..< n { append(&list, buf[k]) }
		}
		// (self-alignment values are named by flow or side already: they move by the tactics as written)
		named: style.Computed
		named.justify_self, named.align_self = v.justify_self, v.align_self
		for t in tactics { style.try_tactic_alignment(&named, t) }
		tactics = list[:]
		for t in tactics { style.try_tactic_apply(v, t, context.temp_allocator) }
		v.justify_self, v.align_self = named.justify_self, named.align_self
	}
	p := Prep{cs = v, ref = ref, cb = cb, imcb = cb}
	p.anchor = default_anchor(ac, q, v)
	cb_rtl := cb_is_rtl(ac.c, q)
	self_rtl := is_rtl(v)
	cb_wm := l.boxes[l.cold[q].cb].wm
	// the axes justify-self and align-self mean, and where they start
	x_self, y_self := v.justify_self, v.align_self
	if is_vert(cb_wm) { x_self, y_self = v.align_self, v.justify_self }
	x_hi, y_hi := style.axis_start_hi(cb_wm, cb_rtl, true), style.axis_start_hi(cb_wm, cb_rtl, false)

	// position-area: the rectangle of the grid the anchor makes in the containing block
	refabs := l.boxes[ref].abs
	box_h := style.Length{kind = .Fit_Content}
	centered_track: [2]bool   // position-area in an axis takes all three tracks, and `normal`: as anchor-center
	if v.position_area.a != .None && p.anchor != NONE {
		p.area = true
		x, y := style.area_tracks_flow(v.position_area, cb_wm, cb_rtl, l.boxes[q].wm, self_rtl)
		for t in tactics {
			switch t {
			case .Flip_Block, .Flip_Y: y = {2 - y[1], 2 - y[0]}
			case .Flip_Inline, .Flip_X: x = {2 - x[1], 2 - x[0]}
			case .Flip_Start: x, y = y, x
			}
		}
		r := anchor_rect(l, p.anchor, q)
		for axis in 0 ..< 2 {
			tr := axis == 0 ? x : y
			lo, hi := r.min[axis] - refabs[axis], r.max[axis] - refabs[axis]
			// (an anchor outside of the containing block pushes the outer lines away)
			lines := [4]f32{min(cb.min[axis], lo), lo, hi, max(cb.max[axis], hi)}
			p.imcb.min[axis], p.imcb.max[axis] = lines[tr[0]], lines[tr[1] + 1]
			if p.imcb.max[axis] < p.imcb.min[axis] { p.imcb.max[axis] = p.imcb.min[axis] }
			p.align[axis] = area_align(tr)
			p.follow[axis] = true
			p.moves[axis] = {tr[0] > 0, tr[1] < 2}
			centered_track[axis] = tr[0] == 0 && tr[1] == 2
		}
		// insets left auto are the edges of that rectangle; explicit alignment wins over the one the tracks give
		for s in style.Side { if v.inset[s].kind == .Auto { v.inset[s] = style.px(0) } }
		if a := explicit_align(x_self, x_hi); a != .None { p.align[0] = a; centered_track[0] = false } else if x_self == .Stretch { p.align[0] = .None; centered_track[0] = false }
		if a := explicit_align(y_self, y_hi); a != .None { p.align[1] = a; centered_track[1] = false } else if y_self == .Stretch { p.align[1] = .None; centered_track[1] = false }
		if x_self == .Anchor_Center { centered_track[0] = true }
		if y_self == .Anchor_Center { centered_track[1] = true }
		if p.align[0] != .None && v.width.kind == .Auto { v.width = box_h }
		if p.align[1] != .None && v.height.kind == .Auto { v.height = box_h }
	}

	// anchor-center: the middle of the anchor, as far as the rectangle allows (the box is sized in all of it)
	if p.anchor != NONE {
		r := anchor_rect(l, p.anchor, q)
		if centered_track[0] || x_self == .Anchor_Center {
			p.align[0] = .Anchor
			p.follow[0] = true
			p.mid[0] = (r.min.x + r.max.x) / 2 - refabs.x
			if v.inset[.Left].kind == .Auto { v.inset[.Left] = style.px(0) }
			if v.inset[.Right].kind == .Auto { v.inset[.Right] = style.px(0) }
			if v.margin[.Left].kind == .Auto { v.margin[.Left] = style.px(0) }
			if v.margin[.Right].kind == .Auto { v.margin[.Right] = style.px(0) }
			if v.width.kind == .Auto { v.width = box_h }
		}
		if centered_track[1] || y_self == .Anchor_Center {
			p.align[1] = .Anchor
			p.follow[1] = true
			p.mid[1] = (r.min.y + r.max.y) / 2 - refabs.y
			if v.inset[.Top].kind == .Auto { v.inset[.Top] = style.px(0) }
			if v.inset[.Bottom].kind == .Auto { v.inset[.Bottom] = style.px(0) }
			if v.margin[.Top].kind == .Auto { v.margin[.Top] = style.px(0) }
			if v.margin[.Bottom].kind == .Auto { v.margin[.Bottom] = style.px(0) }
			if v.height.kind == .Auto { v.height = box_h }
		}
	}
	if !p.area {
		// other self-alignment: within the insets, when both are given
		if p.align[0] == .None && v.inset[.Left].kind != .Auto && v.inset[.Right].kind != .Auto {
			if p.align[0] = explicit_align(x_self, x_hi); p.align[0] != .None && v.width.kind == .Auto { v.width = box_h }
		}
		if p.align[1] == .None && v.inset[.Top].kind != .Auto && v.inset[.Bottom].kind != .Auto {
			if p.align[1] = explicit_align(y_self, y_hi); p.align[1] != .None && v.height.kind == .Auto { v.height = box_h }
		}
	}

	if v.inset[.Left].kind == .Anchor { p.moves[0][0] = true }
	if v.inset[.Right].kind == .Anchor { p.moves[0][1] = true }
	if v.inset[.Top].kind == .Anchor { p.moves[1][0] = true }
	if v.inset[.Bottom].kind == .Anchor { p.moves[1][1] = true }

	// the lengths
	AUTO := style.Length{kind = .Auto}
	NO_MAX := style.Length{kind = .None}
	for s in style.Side {
		x := s == .Left || s == .Right
		v.inset[s] = length_resolve(ac, q, &p, v.inset[s], Len_Use{side = s, inset = true, axis_x = x}, AUTO)
		v.margin[s] = length_resolve(ac, q, &p, v.margin[s], Len_Use{axis_x = x}, style.px(0))
	}
	ux, uy := Len_Use{axis_x = true}, Len_Use{axis_x = false}
	v.width, v.min_width, v.max_width = length_resolve(ac, q, &p, v.width, ux, AUTO), length_resolve(ac, q, &p, v.min_width, ux, AUTO), length_resolve(ac, q, &p, v.max_width, ux, NO_MAX)
	v.height, v.min_height, v.max_height = length_resolve(ac, q, &p, v.height, uy, AUTO), length_resolve(ac, q, &p, v.min_height, uy, AUTO), length_resolve(ac, q, &p, v.max_height, uy, NO_MAX)

	// what the insets leave of the rectangle
	c := ac.c
	w, h := max(p.imcb.max.x - p.imcb.min.x, 0), max(p.imcb.max.y - p.imcb.min.y, 0)
	p.inner = p.imcb
	if d, ok := definite(c, v.inset[.Left], w); ok { p.inner.min.x += d }
	if d, ok := definite(c, v.inset[.Right], w); ok { p.inner.max.x -= d }
	if d, ok := definite(c, v.inset[.Top], h); ok { p.inner.min.y += d }
	if d, ok := definite(c, v.inset[.Bottom], h); ok { p.inner.max.y -= d }
	return p
}

// Aligns a box layout_abs placed in its rectangle. Under position-area, a box too large for it stays in the containing block.
@(private = "file")
align_box :: proc(ac: ^A, q: i32, p: ^Prep) {
	c := ac.c
	k := &c.l.boxes[q]
	shift := shift_of(ac, q, p)
	for axis in 0 ..< 2 {
		mode := p.align[axis]
		if mode == .None { continue }
		auto_s := axis == 0 ? k.auto_l : k.auto_t
		auto_e := axis == 0 ? k.auto_r : k.auto_b
		if auto_s || auto_e { continue }
		ms := axis == 0 ? k.margin[3] : k.margin[0]
		me := axis == 0 ? k.margin[1] : k.margin[2]
		size := k.size[axis] + ms + me
		lo, hi := p.inner.min[axis], p.inner.max[axis]
		free := hi - lo - size
		start: f32
		switch mode {
		case .None, .Start: start = lo
		case .Center: start = lo + free / 2
		case .End: start = hi - size
		case .Anchor:
			start = p.mid[axis] - size / 2
			if start + size > hi { start = hi - size }
			if start < lo { start = lo }
		}
		if free < 0 && p.area {
			// (where the containing block is once the box is scrolled with its anchor: a fixed popover on a scrolled page)
			cb_lo, cb_hi := p.cb.min[axis] - shift[axis], p.cb.max[axis] - shift[axis]
			if start + size > cb_hi { start = cb_hi - size }
			if start < cb_lo { start = cb_lo }
		}
		pre := axis == 1 ? k.pre_h : 0
		k.pos[axis] = start + ms + pre
	}
}

// Lays box `q` out with the prepared style. Its record stays the element's.
@(private = "file")
try_layout :: proc(ac: ^A, q: i32, base: ^style.Computed, p: ^Prep) {
	c := ac.c
	k := &c.l.boxes[q]
	k.cs = p.cs
	// (the style is not the one the box's cached result was made with; nothing above it needs to know)
	k.inc += {.Dirty}
	k.intr_ok = false
	layout_abs(c, q, p.ref, p.imcb)
	align_box(ac, q, p)
	c.l.boxes[q].cs = base
}

// The box, margins included, stays inside its rectangle, and, scrolled, inside its containing block.
@(private = "file")
fits :: proc(ac: ^A, q: i32, p: ^Prep, shift: Vec2) -> bool {
	k := &ac.l.boxes[q]
	r := Rect{k.pos - {k.margin[3], k.margin[0] + k.pre_h}, k.pos + k.size + {k.margin[1], k.margin[2]}}
	e := ANCHOR_FIT_EPSILON
	for axis in 0 ..< 2 {
		// scrolled, the box moves with its anchor, and so do the edges that come from the anchor; the others stay
		lo, hi := p.inner.min[axis], p.inner.max[axis]
		if !p.moves[axis][0] { lo -= shift[axis] }
		if !p.moves[axis][1] { hi -= shift[axis] }
		if r.min[axis] < lo - e || r.max[axis] > hi + e { return false }
	}
	return true
}

// What the scrolling around the default anchor does to the box, in the axes it follows.
@(private = "file")
shift_of :: proc(ac: ^A, q: i32, p: ^Prep) -> Vec2 {
	if p.anchor == NONE { return {} }
	s := scrolled(ac, p.anchor) - scrolled(ac, q)
	if !p.follow[0] { s.x = 0 }
	if !p.follow[1] { s.y = 0 }
	return s
}

// The anchor is clipped by a scroll container (or clip) between it and what contains the box, or hidden itself.
@(private = "file")
anchor_clipped :: proc(ac: ^A, a, q: i32) -> bool {
	l := ac.l
	if l.boxes[a].cs.visibility != .Visible { return true }
	in_q := make([dynamic]i32, 0, 16, context.temp_allocator)
	for x := containing_or_parent(l, q); x != NONE; x = containing_or_parent(l, x) { append(&in_q, x) }
	r := border_rect(&l.boxes[a])
	for x := a; x != NONE; x = containing_or_parent(l, x) {
		if ei := ac.entry[x]; ei != NONE && l.anchored[ei].hidden { return true }
		if x != a {
			if slice.contains(in_q[:], x) { break }
			b := &l.boxes[x]
			if .Clips in b.flags && .Propagated not_in b.flags && b.kind != .Inline {
				r = rect_shift(r, -l.scroll[b.node])
				r = rect_intersect(r, padding_rect(b))
				if r.max.x <= r.min.x && r.max.y <= r.min.y { return true }
				if r.max.x < r.min.x || r.max.y < r.min.y { return true }
			}
		}
	}
	return false
}

// A number for what the choice among the options depends on in the style.
@(private = "file")
style_sig :: proc(cs: ^style.Computed) -> u64 {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, v: u64) { h^ = (h^ ~ v) * 0x100000001b3 }
	tree :: proc(h: ^u64, n: ^css.Calc) {
		if n == nil { mix(h, 0xff); return }
		mix(h, u64(n.op)); mix(h, u64(n.unit)); mix(h, transmute(u64)n.num)
		if n.anchor != nil {
			mix(h, u64(n.anchor.side))
			for i in 0 ..< len(n.anchor.name) { mix(h, u64(n.anchor.name[i])) }
		}
		tree(h, n.a); tree(h, n.b); tree(h, n.c)
	}
	length :: proc(h: ^u64, l: style.Length) {
		mix(h, u64(l.kind)); mix(h, u64(transmute(u32)l.v)); tree(h, l.calc)
	}
	for s in style.Side { length(&h, cs.inset[s]); length(&h, cs.margin[s]) }
	length(&h, cs.width); length(&h, cs.height); length(&h, cs.min_width); length(&h, cs.min_height); length(&h, cs.max_width); length(&h, cs.max_height)
	mix(&h, u64(cs.align_self)); mix(&h, u64(cs.justify_self)); mix(&h, u64(cs.position_try_order))
	mix(&h, u64(cs.position_area.a)); mix(&h, u64(cs.position_area.b))
	for &o in cs.position_try_fallbacks {
		for i in 0 ..< len(o.name) { mix(&h, u64(o.name[i])) }
		for i in 0 ..< int(o.n_tactics) { mix(&h, u64(o.tactics[i])) }
		mix(&h, u64(o.area.a)); mix(&h, u64(o.area.b))
		if o.rule != nil {
			for s in style.Side { length(&h, o.rule.inset[s]); length(&h, o.rule.margin[s]) }
			length(&h, o.rule.width); length(&h, o.rule.height)
		}
	}
	return h
}

// The record the element has now (a box between passes may point at an older one only after a refresh: same layout values).
@(private = "file")
record_of :: proc(c: ^Ctx, b: ^Box) -> ^style.Computed {
	el := style.style_of(c.st, b.node)
	if el == nil { return b.cs }
	if .Pseudo in b.flags {
		nc := pseudo_style(el, b.pseudo)
		return nc != nil ? nc : b.cs
	}
	return el
}

@(private = "file")
lay_anchored :: proc(ac: ^A, q: i32) {
	c, l := ac.c, ac.l
	b := &l.boxes[q]
	base := record_of(c, b)
	b.cs = base
	ref: i32
	cb: Rect
	if .Fixed in b.flags {
		ref, cb = l.cold[q].cb, Rect{{0, 0}, c.vp}
	} else {
		ref, cb = abs_containing_rect(c, l.cold[q].cb)
		if area, ok := l.anchor_grid_areas[q]; ok { cb = area }
	}
	key := anchored_key(b)
	sig := style_sig(base)

	// the options to try, in the order of position-try-order
	opts := make([dynamic]i32, 0, 8, context.temp_allocator)
	append(&opts, -1)
	for &o, i in base.position_try_fallbacks {
		if i >= style.TRY_OPTIONS_MAX { break }
		if !o.missing { append(&opts, i32(i)) }
	}
	preps := make([]Prep, len(opts), context.temp_allocator)
	for o, i in opts { preps[i] = prepare(ac, q, base, o, ref, cb) }
	if base.position_try_order != .Normal && len(opts) > 1 {
		Order :: struct { i: int, size: f32 }
		list := make([]Order, len(opts), context.temp_allocator)
		cbv := is_vert(l.boxes[l.cold[q].cb].wm)
		x := base.position_try_order == .Most_Width || (base.position_try_order == .Most_Inline_Size && !cbv) || (base.position_try_order == .Most_Block_Size && cbv)
		for &p, i in preps {
			list[i] = Order{i, x ? p.inner.max.x - p.inner.min.x : p.inner.max.y - p.inner.min.y}
		}
		slice.stable_sort_by(list, proc(a, b: Order) -> bool { return a.size > b.size })
		sorted_opts := make([dynamic]i32, 0, len(opts), context.temp_allocator)
		sorted_preps := make([]Prep, len(opts), context.temp_allocator)
		for e, i in list { append(&sorted_opts, opts[e.i]); sorted_preps[i] = preps[e.i] }
		opts, preps = sorted_opts, sorted_preps
	}

	chosen := 0
	laid := -1
	fit := false
	last, had_last := l.anchor_last[key]
	if had_last && last.sig != sig { had_last = false }
	// what was chosen before stays while it fits
	if had_last {
		for o, i in opts {
			if o != last.option { continue }
			try_layout(ac, q, base, &preps[i])
			laid = i
			if fits(ac, q, &preps[i], shift_of(ac, q, &preps[i])) { chosen, fit = i, true }
			break
		}
	}
	if !fit {
		for _, i in opts {
			if laid != i || len(opts) > 1 { try_layout(ac, q, base, &preps[i]); laid = i }
			if fits(ac, q, &preps[i], shift_of(ac, q, &preps[i])) { chosen, fit = i, true; break }
		}
	}
	if !fit && had_last {
		// none fits: the one chosen before, or the first
		for o, i in opts { if o == last.option { chosen = i; break } }
	}
	if laid != chosen { try_layout(ac, q, base, &preps[chosen]) }
	p := &preps[chosen]
	if fit { l.anchor_chosen[key] = Anchor_Last{option = opts[chosen], sig = sig} } else { delete_key(&l.anchor_chosen, key) }

	shift := shift_of(ac, q, p)
	e := Anchored{box = q, anchor = p.anchor, follow = p.follow, shift = shift, rect = p.imcb, ref = ref}
	e.sizes = {p.cs.min_width, p.cs.min_height, p.cs.max_width, p.cs.max_height}
	// (what the box was aligned in answers for its insets, in the axes it was aligned in)
	e.aligned = {p.align[0] != .None, p.align[1] != .None}
	w, h := max(p.imcb.max.x - p.imcb.min.x, 0), max(p.imcb.max.y - p.imcb.min.y, 0)
	sides := [4]style.Side{.Top, .Right, .Bottom, .Left}
	for s, i in sides {
		v, ok := definite(c, p.cs.inset[s], s == .Left || s == .Right ? w : h)
		e.declared[i] = ok ? v / c.scale : 0
	}
	sides2 := [4]style.Side{.Top, .Right, .Bottom, .Left}
	for s, i in sides2 { e.auto_inset[i] = p.cs.inset[s].kind == .Auto }
	for &s, i in e.sizes {
		if s.kind == .Calc {
			base_size := i % 2 == 0 ? p.imcb.max.x - p.imcb.min.x : p.imcb.max.y - p.imcb.min.y
			s = style.px(px_of(c, s, base_size) / c.scale)
		}
	}
	vis := base.position_visibility
	e.hidden = (.No_Overflow in vis && !fit) || (.Anchor_Valid in vis && p.invalid) ||
		(.Anchor_Visible in vis && p.anchor != NONE && anchor_clipped(ac, p.anchor, q))
	if len(opts) > 1 || p.area || (vis & {.No_Overflow, .Anchor_Visible}) != {} {
		if p.anchor != NONE && scroll_apart(l, p.anchor, q) { l.anchor_scroll = true }
	}
	ac.entry[q] = i32(len(l.anchored))
	append(&l.anchored, e)
}

// Lays out the boxes that wait for their anchors. Everything else is laid out; `abs` is brought up to date for what they read.
@(private)
anchored_pass :: proc(c: ^Ctx) {
	l := c.l
	plain := c.plain
	c.plain = nil   // (found from the elements' records: what is laid out here has other values)
	defer c.plain = plain
	clear(&l.anchored)
	clear(&l.anchor_chosen)
	l.anchor_scroll, l.anchor_stale = false, false
	order := preorder(l)
	if l.frames_on {
		for x in order { place_box(c, x) }
		flows_finish(l, order)
	}
	ac := A{c = c, l = l, pos = make([]i32, len(l.boxes), context.temp_allocator), entry = make([]i32, len(l.boxes), context.temp_allocator)}
	ac.names = make(map[string][dynamic]i32, 16, context.temp_allocator)
	for i in 0 ..< len(l.boxes) { ac.pos[i], ac.entry[i] = -1, NONE }
	for x, i in order {
		ac.pos[x] = i32(i)
		place_box(c, x)
		for name in l.boxes[x].cs.anchor_name {
			list := ac.names[name]
			if list == nil { list = make([dynamic]i32, 0, 4, context.temp_allocator) }
			append(&list, x)
			ac.names[name] = list
		}
	}
	for x, i in order {
		b := &l.boxes[x]
		if .Abs not_in b.flags || .Dead in b.flags || !style.anchored_style(b.cs) { continue }
		lay_anchored(&ac, x)
		if l.frames_on { frames_anchored_to_physical(c, x) }
		// its content moved with it (its own abs, then what is inside)
		place_box(c, x)
		for j := i + 1; j < len(order) && inside(l, order[j], x); j += 1 { place_box(c, order[j]) }
	}
}

// Per box, what anchored_pass found (nil: nothing anchored).
@(private)
anchored_by_box :: proc(l: ^Layout) -> []^Anchored {
	if len(l.anchored) == 0 { return nil }
	t := make([]^Anchored, len(l.boxes), context.temp_allocator)
	for &e in l.anchored { t[e.box] = &e }
	return t
}

// The space of an anchored box whose default anchor can scroll away from it.
@(private)
anchored_space :: proc(l: ^Layout, x: i32, t: []^Anchored) {
	e := t[x]
	if e == nil || e.anchor == NONE || (!e.follow[0] && !e.follow[1]) { return }
	b := &l.boxes[x]
	// in the flow of a multi-column container: with an anchor that scrolls with it there is nothing to follow, and the box is
	// content of the flow as any other, cut by its columns; else it hangs from the column it starts in (flow_fix_box)
	if l.spaces[b.space].kind == .Flow {
		if !scroll_apart(l, e.anchor, x) { return }
		sp := l.spaces[b.space]
		at := &l.flow_frags[sp.flow[0]]
		for fi in sp.flow[0] ..< sp.flow[1] {
			fr := &l.flow_frags[fi]
			if frag_overlaps(fr, Rect{b.abs, b.abs}) { at = fr; break }
		}
		b.space = at.space
		b.clip = l.clips[at.clip].parent
	}
	pb := &l.spaces[b.space]
	append(&l.spaces, Space{kind = .Anchored, parent = b.space, box = x, frame = NONE, clip = b.clip, xform = pb.xform, plane = pb.plane, persp_from = NONE, ctx = NONE, dest = NONE, anchor = e.anchor, follow = e.follow})
	b.space = i32(len(l.spaces) - 1)
}

// What the scroll containers around a box's anchor add to the box's place, against those around the box.
@(private)
anchored_shift :: proc(l: ^Layout, sp: ^Space, viewport: Vec2, doc_scroll: f32, depth := 0) -> Vec2 {
	if depth >= ANCHOR_CHAIN_MAX { return {} }
	walk :: proc(l: ^Layout, s: i32, viewport: Vec2, doc_scroll: f32, depth: int) -> Vec2 {
		off: Vec2
		for i := s; i != NONE; i = l.spaces[i].parent {
			q := &l.spaces[i]
			switch q.kind {
			case .Document: off -= Vec2{doc_scroll_x_snapped(l), doc_scroll}
			case .Fixed, .Transform, .Flow:
			case .Column: off += q.shift
			case .Scroll: off -= scroll_offset_of(l, q)
			case .Sticky: off += sticky_offset(l, q, viewport, doc_scroll)
			case .Anchored: off += anchored_shift(l, q, viewport, doc_scroll, depth + 1)
			}
		}
		return off
	}
	a := l.boxes[sp.anchor].space
	d := walk(l, a, viewport, doc_scroll, depth) - walk(l, sp.parent, viewport, doc_scroll, depth)
	if !sp.follow[0] { d.x = 0 }
	if !sp.follow[1] { d.y = 0 }
	return d
}

// A box position-visibility hides makes no display item, nor does anything inside it.
@(private)
anchored_drop_hidden :: proc(l: ^Layout) {
	any := false
	for &e in l.anchored { if e.hidden { any = true; break } }
	if !any { return }
	gone := make([]bool, len(l.boxes), context.temp_allocator)
	stack := make([dynamic]i32, 0, 32, context.temp_allocator)
	for &e in l.anchored {
		if !e.hidden { continue }
		append(&stack, e.box)
		for len(stack) > 0 {
			x := pop(&stack)
			gone[x] = true
			for ch := l.boxes[x].first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
		}
	}
	n := 0
	for i in 0 ..< len(l.items) {
		if bi := l.items[i].box; bi >= 0 && gone[bi] { continue }
		if n != i { l.items[n] = l.items[i] }
		n += 1
	}
	resize(&l.items, n)
}

// For getComputedStyle: the used insets of an anchored box (CSS px: top, right, bottom, left), and the bounds it was laid
// out with (min-width, min-height, max-width, max-height).
anchored_used :: proc(l: ^Layout, bi: i32, scale: f32) -> (insets: [4]f32, auto_inset: [4]bool, sizes: [4]style.Length, ok: bool) {
	for &e in l.anchored {
		if e.box != bi { continue }
		k := &l.boxes[bi]
		top := k.pos.y - k.pre_h - k.margin[0]
		left := k.pos.x - k.margin[3]
		insets = {(top - e.rect.min.y) / scale, (e.rect.max.x - (k.pos.x + k.size.x + k.margin[1])) / scale,
			(e.rect.max.y - (k.pos.y + k.size.y + k.margin[2])) / scale, (left - e.rect.min.x) / scale}
		if e.aligned[0] { insets[1], insets[3] = e.declared[1], e.declared[3] }
		if e.aligned[1] { insets[0], insets[2] = e.declared[0], e.declared[2] }
		return insets, e.auto_inset, e.sizes, true
	}
	return {}, {}, {}, false
}

// The options now in force are what later layouts keep while they fit. Called once per frame, after layout (§last-successful:
// layouts a script forces in between record nothing). A box that is gone starts afresh.
anchored_commit :: proc(l: ^Layout) {
	if !l.anchor_uses && len(l.anchor_last) == 0 { return }
	live := make(map[Anchor_Key]bool, len(l.anchored), context.temp_allocator)
	for &e in l.anchored { live[anchored_key(&l.boxes[e.box])] = true }
	gone := make([dynamic]Anchor_Key, 0, 4, context.temp_allocator)
	for k in l.anchor_last { if k not_in live { append(&gone, k) } }
	for k in gone { delete_key(&l.anchor_last, k) }
	for k, v in l.anchor_chosen { l.anchor_last[k] = v }
}

@(private = "file")
anchored_key :: proc(b: ^Box) -> Anchor_Key {
	k := Anchor_Key{node = b.node}
	k.pseudo = pseudo_key(b)
	return k
}
