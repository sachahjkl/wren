package layout

import "core:math"
import "wb:base"
import "wb:style"

// After layout: final coordinates (relative positioning included), the box each one is clipped by, scrollable overflow,
// and the spaces / clips / opacity groups items are drawn under.

@(private)
preorder :: proc(l: ^Layout) -> []i32 {
	out := make([dynamic]i32, 0, len(l.boxes), context.temp_allocator)
	stack := make([dynamic]i32, 0, 256, context.temp_allocator)
	append(&stack, 0)
	for len(stack) > 0 {
		x := pop(&stack)
		append(&out, x)
		b := &l.boxes[x]
		// children in reverse so the first is visited first
		n := len(stack)
		for ch := b.first; ch != NONE; ch = l.boxes[ch].next { append(&stack, ch) }
		for i, j := n, len(stack) - 1; i < j; i, j = i + 1, j - 1 { stack[i], stack[j] = stack[j], stack[i] }
	}
	return out[:]
}

// The box a box is contained in for clipping and scrolling: its containing block for absolutely positioned boxes.
@(private)
containing_parent :: proc(b: ^Box) -> i32 {
	if .Abs in b.flags { return b.cb }
	return b.parent
}

// Boxes inside a position: fixed box (they move with the viewport and do not extend the document).
@(private)
fixed_boxes :: proc(l: ^Layout, order: []i32) -> []bool {
	in_fixed := make([]bool, len(l.boxes), context.temp_allocator)
	for x in order {
		b := &l.boxes[x]
		if .Root in b.flags { continue }
		in_fixed[x] = .Fixed in b.flags || in_fixed[containing_parent(b)]
	}
	return in_fixed
}

// The border box `r` of an in-flow child with its margins on the sides where the axes of its scroll container end: on the left of
// right-to-left lines and of vertical-rl, at the top of upward lines. In the block axis the used margin; in the inline axis as
// specified: the used one gives way when the block is over-constrained.
@(private = "file")
with_end_margins :: proc(l: ^Layout, b: ^Box, r, port: Rect, owner: ^style.Computed) -> Rect {
	out := r
	wm, rtl := owner.writing_mode, is_rtl(owner)
	if is_vert(wm) {
		if style.axis_start_hi(wm, rtl, true) { out.min.x -= max(b.margin[3], 0) } else { out.max.x += max(b.margin[1], 0) }
		base := (port.max.y - port.min.y) / l.scale
		if style.axis_start_hi(wm, rtl, false) {
			out.min.y -= max(style.resolve(b.cs.margin[.Top], base) * l.scale, 0)
		} else {
			out.max.y += max(style.resolve(b.cs.margin[.Bottom], base) * l.scale, 0)
		}
		return out
	}
	base := (port.max.x - port.min.x) / l.scale
	if rtl {
		out.min.x -= max(style.resolve(b.cs.margin[.Left], base) * l.scale, 0)
	} else {
		out.max.x += max(style.resolve(b.cs.margin[.Right], base) * l.scale, 0)
	}
	out.max.y += max(b.margin[2], 0)
	return out
}

// Scrollable overflow (CSS Overflow 3 §2.2) of every scroll container, and the extent of the document: the border boxes
// and text of what they contain, through the transforms between each box and its scroll container (bounding boxes of
// the transformed rects). Returns the document extent.
@(private)
compute_overflow :: proc(l: ^Layout, order: []i32, in_fixed: []bool, vp: Vec2) -> Rect {
	n := len(l.boxes)
	// inner[x]: maps x's content (and, when x is transformed, its own border box) to its clip owner's coordinates
	inner := make([]Matrix, n, context.temp_allocator)
	has := make([]bool, n, context.temp_allocator)
	for x in order {
		b := &l.boxes[x]
		// an inline box never becomes a scroll container (finish and refresh_overflow only build a scroll space for
		// kind != .Inline, and no box is ever its clip owner): its overflow is never read. Forcing it empty here (not
		// padding_rect) matches what the incremental paths produce (they never recompute it), so a spliced layout and
		// a full one agree on it (verify.odin). A box reused across a display change keeps no stale value either.
		if .Scroll in b.flags { b.overflow = b.kind == .Inline ? Rect{} : padding_rect(b) }
	}
	doc := Rect{{0, 0}, vp}
	add :: proc(l: ^Layout, owner: i32, r: Rect, fixed: bool, doc: ^Rect) {
		if rect_empty(r) { return }
		if owner == NONE {
			if !fixed { doc^ = rect_union(doc^, r) }
			return
		}
		o := &l.boxes[owner]
		if .Scroll in o.flags { o.overflow = rect_union(o.overflow, r) }
	}
	for x in order {
		b := &l.boxes[x]
		if .Root in b.flags { continue }
		cp := containing_parent(b)
		// inside the flow of a multi-column container: seen where its columns show, from outside of it
		mc := NONE
		if .In_Flow in b.fx && (b.clip_owner == NONE || .In_Flow not_in l.boxes[b.clip_owner].fx) { mc = flow_container(l, x) }
		m, hm := IDENTITY, false
		if b.clip_owner != cp && has[cp] { m, hm = inner[cp], true }
		if .Transformed in b.flags {
			t := box_matrix(l, b)
			m = hm ? mat_mul(m, t) : t
			hm = true
		}
		inner[x], has[x] = m, hm
		box_r := border_rect(b)
		// the end margins of the in-flow children of a scroll container are scrollable too (CSS Overflow 3 §2.2)
		if b.clip_owner == b.parent && b.clip_owner != NONE && .Scroll in l.boxes[b.clip_owner].flags && b.flags & {.Abs, .Float} == {} && b.kind != .Inline && b.cs != nil {
			owner := &l.boxes[b.clip_owner]
			box_r = with_end_margins(l, b, box_r, padding_rect(owner), owner.cs)
		}
		if mc != NONE { box_r = flow_bounds(l, mc, box_r) }
		add(l, b.clip_owner, hm ? mat_bounds(m, box_r) : box_r, in_fixed[x], &doc)
		if .Ifc in b.flags && b.lines[1] > b.lines[0] {
			clips := .Clips in b.flags && .Propagated not_in b.flags
			owner := clips ? x : b.clip_owner
			lm, lhm := m, hm && !clips
			for li in b.lines[0] ..< b.lines[1] {
				ln := &l.lines[li]
				for fi in ln.frags[0] ..< ln.frags[1] {
					f := &l.frags[fi]
					if f.kind != .Text && f.kind != .Ellipsis { continue }
					base := f.box != NONE ? l.boxes[f.box].abs : b.abs
					r := Rect{base + {f.x, f.y}, base + {f.x + f.w, f.y + f.h}}
					if mc != NONE && !clips { r = flow_bounds(l, mc, r) }
					add(l, owner, lhm ? mat_bounds(lm, r) : r, in_fixed[x], &doc)
				}
			}
		}
	}
	return doc
}

// Where the document's horizontal scroll has its origin: at the end of the line when true, so that what overflows goes to the
// left of 0 and is reached with negative offsets, and what lies right of the viewport's edge is not reachable (CSS Overflow 3
// §2.2: the unreachable side). The principal writing mode: the body's values, else the root element's (CSS Writing Modes 4 §8).
@(private)
doc_scroll_origin_end :: proc(c: ^Ctx) -> bool {
	cs := style.style_of(c.st, c.l.canvas_els[1])
	if cs == nil { cs = style.style_of(c.st, c.l.canvas_els[0]) }
	if cs == nil { return false }
	// the x axis: lines go right to left in these writing modes; else, in horizontal text, by the direction
	if cs.writing_mode == .Vertical_Rl || cs.writing_mode == .Sideways_Rl { return true }
	return !is_vert(cs.writing_mode) && is_rtl(cs)
}

// Likewise for the document's vertical scroll: at the bottom when lines run upwards.
@(private)
doc_scroll_origin_bottom :: proc(c: ^Ctx) -> bool {
	cs := style.style_of(c.st, c.l.canvas_els[1])
	if cs == nil { cs = style.style_of(c.st, c.l.canvas_els[0]) }
	if cs == nil { return false }
	return style.axis_start_hi(cs.writing_mode, is_rtl(cs), false)
}

// How far a scroll container scrolls either way. Offsets run from its scroll origin (CSS Overflow 3 §2.2): where the axis starts at
// the high end (lines right to left, right-to-left text in horizontal lines, vertical text upwards), they go negative, and
// overflow on the other side of the origin cannot be reached.
@(private)
scroll_limits :: proc(b: ^Box, port: Rect) -> (lo, hi: Vec2) {
	hi = {max(b.overflow.max.x - port.max.x, 0), max(b.overflow.max.y - port.max.y, 0)}
	rtl := is_rtl(b.cs)
	wm := b.cs.writing_mode
	if style.axis_start_hi(wm, rtl, true) {
		lo.x, hi.x = min(b.overflow.min.x - port.min.x, 0), 0
	}
	if style.axis_start_hi(wm, rtl, false) {
		lo.y, hi.y = min(b.overflow.min.y - port.min.y, 0), 0
	}
	if b.cs.overflow_x != .Scroll && b.cs.overflow_x != .Auto { lo.x, hi.x = 0, 0 }
	if b.cs.overflow_y != .Scroll && b.cs.overflow_y != .Auto { lo.y, hi.y = 0, 0 }
	return
}

// The vertical scroll range the document's extent gives.
@(private)
note_doc_extent_y :: proc(l: ^Layout, doc: Rect, vp: Vec2) {
	l.height, l.doc_min_y = vp.y, 0
	if !l.doc_scroll_y { return }
	if l.doc_origin_bottom { l.doc_min_y = min(doc.min.y, 0) } else { l.height = max(doc.max.y, vp.y) }
}

// The horizontal scroll range the document's extent gives.
@(private)
note_doc_extent_x :: proc(l: ^Layout, doc: Rect, vp: Vec2) {
	l.doc_width, l.doc_min_x = vp.x, 0
	if !l.doc_scrollable_x { return }
	if l.doc_origin_end { l.doc_min_x = min(doc.min.x, 0) } else { l.doc_width = max(doc.max.x, vp.x) }
}

@(private)
padding_rect :: proc(b: ^Box) -> Rect {
	return Rect{b.abs + {b.border[3], b.border[0]}, b.abs + b.size - {b.border[1], b.border[2]}}
}

@(private)
border_rect :: proc(b: ^Box) -> Rect {
	if b.kind == .Inline { return Rect{b.abs + b.pos, b.abs + b.pos + b.size} }
	return Rect{b.abs, b.abs + b.size}
}

@(private)
content_rect :: proc(b: ^Box) -> Rect {
	return Rect{b.abs + {content_x(b), content_y(b)}, b.abs + b.size - {b.border[1] + b.padding[1], b.border[2] + b.padding[2]}}
}

// Relative offsets (CSS 2.1 §9.4.3): percentages of the containing block, a percentage of an auto height is ignored.
@(private)
relative_offset :: proc(c: ^Ctx, b: ^Box) -> Vec2 {
	cs := b.cs
	p := b.parent
	if p != NONE && c.l.boxes[p].kind == .Inline { p = c.l.boxes[p].ifc_root }
	cbw, cbh: f32 = 0, -1
	if p != NONE {
		pb := &c.l.boxes[p]
		cbw = max(pb.size.x - pb_w(pb), 0)
		if pb.cs.height.kind == .Px || .Root in pb.flags { cbh = max(pb.size.y - pb_h(pb), 0) }
	}
	off: Vec2
	if v, ok := definite(c, cs.inset[.Left], cbw); ok {
		off.x = v
		if is_rtl(cs) { if r, rok := definite(c, cs.inset[.Right], cbw); rok { off.x = -r } }
	} else if v2, ok2 := definite(c, cs.inset[.Right], cbw); ok2 { off.x = -v2 }
	if v, ok := definite(c, cs.inset[.Top], cbh); ok { off.y = v } else if v2, ok2 := definite(c, cs.inset[.Bottom], cbh); ok2 { off.y = -v2 }
	return off
}

// For getComputedStyle (CSSOM "resolved value" of top, right, bottom, left): the insets of a positioned box, CSS px, top
// right bottom left. A side that is not auto is its value against the containing block (percentages of its height for
// top and bottom, of its width for left and right); an auto side is where the margin box is in it (absolute, fixed), the
// opposite side negated or 0 (relative), or stays auto (sticky). ok = false for a box that is not positioned, an inline
// one, or one in an inline containing block: their computed values answer.
positioned_insets :: proc(l: ^Layout, bi: i32, scale: f32) -> (insets: [4]f32, auto_inset: [4]bool, ok: bool) {
	b := &l.boxes[bi]
	cs := b.cs
	if cs == nil || b.kind == .Inline || cs.position == .Static { return }
	abs := .Abs in b.flags
	owner := abs ? b.cb : b.parent
	if !abs && owner != NONE && l.boxes[owner].kind == .Inline { owner = l.boxes[owner].ifc_root }
	if owner == NONE || l.boxes[owner].kind == .Inline { return }
	if .Sticky in b.flags {
		// a sticky box's percentages are of its scroll container's content box, when it has one
		for a := b.parent; a != NONE; a = l.boxes[a].parent {
			if .Clips in l.boxes[a].flags && l.boxes[a].kind != .Inline { owner = a; break }
		}
	}
	cb := abs ? padding_rect(&l.boxes[owner]) : content_rect(&l.boxes[owner])
	cb = Rect{cb.min / scale, cb.max / scale}
	basis := [4]f32{cb.max.y - cb.min.y, cb.max.x - cb.min.x, cb.max.y - cb.min.y, cb.max.x - cb.min.x}
	for s in 0 ..< 4 {
		// (an anchor() the box could not resolve is auto: one it resolved is the anchored box's, anchored_used)
		v := cs.inset[style.Side(s)]
		if v.kind == .Auto || v.kind == .Anchor { auto_inset[s] = true } else { insets[s] = style.resolve(v, basis[s]) }
	}
	switch {
	case abs:
		box := border_rect(b)
		m := Rect{(box.min - {b.margin[3], b.margin[0]}) / scale, (box.max + {b.margin[1], b.margin[2]}) / scale}
		at := [4]f32{m.min.y - cb.min.y, cb.max.x - m.max.x, cb.max.y - m.max.y, m.min.x - cb.min.x}
		for s in 0 ..< 4 { if auto_inset[s] { insets[s] = at[s] } }
		auto_inset = {}
	case cs.position == .Relative:
		declared := insets
		for s in 0 ..< 4 {
			if !auto_inset[s] { continue }
			opposite := (s + 2) % 4
			insets[s] = auto_inset[opposite] ? 0 : -declared[opposite]
		}
		auto_inset = {}
	}
	return insets, auto_inset, true
}

// The final coordinates of box `x`; those of the box it is positioned against are known.
@(private)
place_box :: #force_inline proc(c: ^Ctx, x: i32) {
	l := c.l
	b := &l.boxes[x]
	if .Relative in b.flags { b.rel = relative_offset(c, b) } else { b.rel = {} }
	if b.pos_ref == NONE { b.abs = b.pos; return }
	ref := &l.boxes[b.pos_ref]
	if b.kind == .Inline {
		// inline boxes: `abs` is the origin of their fragments (their IFC root, moved by relative offsets)
		b.abs = ref.abs + b.rel
		if p := b.parent; p != NONE && l.boxes[p].kind == .Inline { b.abs += l.boxes[p].abs - ref.abs }
		return
	}
	b.abs = ref.abs + b.pos + b.rel
	if .Abs not_in b.flags {
		if p := b.parent; p != NONE && l.boxes[p].kind == .Inline { b.abs += l.boxes[p].abs - l.boxes[l.boxes[p].ifc_root].abs }
	}
}

@(private)
finish :: proc(c: ^Ctx) {
	l := c.l
	order: []i32
	if l.tree_order {
		// a full pass made its boxes in tree order, and no partial rebuild since moved any: no walk needed
		order = make([]i32, len(l.boxes), context.temp_allocator)
		for i in 0 ..< len(order) { order[i] = i32(i) }
	} else {
		order = preorder(l)
	}

	// coordinates
	for x in order { place_box(c, x) }
	if l.frames_on { flows_finish(l, order) }

	// clip owners, scrollable overflow, document extent
	for x in order {
		b := &l.boxes[x]
		if .Root in b.flags { b.clip_owner = NONE; continue }
		cp := containing_parent(b)
		pb := &l.boxes[cp]
		b.clip_owner = (.Clips in pb.flags && .Propagated not_in pb.flags && pb.kind != .Inline) ? cp : pb.clip_owner
	}
	in_fixed := fixed_boxes(l, order)
	doc := compute_overflow(l, order, in_fixed, c.vp)
	l.inc.doc_extent = doc
	l.doc_origin_end, l.doc_origin_bottom = doc_scroll_origin_end(c), doc_scroll_origin_bottom(c)
	note_doc_extent_y(l, doc, c.vp)
	note_doc_extent_x(l, doc, c.vp)

	// spaces, clips, groups
	clear(&l.spaces); clear(&l.clips); clear(&l.groups)
	append(&l.spaces, Space{kind = .Document, parent = NONE, box = 0, frame = NONE, clip = NONE, xform = NONE, plane = NONE, persp_from = NONE, ctx = NONE, dest = NONE})
	append(&l.spaces, Space{kind = .Fixed, parent = NONE, box = 0, frame = NONE, clip = NONE, xform = NONE, plane = NONE, persp_from = NONE, ctx = NONE, dest = NONE})
	nan := math.nan_f32()
	isolate := isolated_contexts(l)
	anchored := anchored_by_box(l)
	for x in order {
		b := &l.boxes[x]
		if .Root in b.flags {
			b.space, b.clip, b.content_space, b.content_clip, b.group = DOCUMENT_SPACE, NONE, DOCUMENT_SPACE, NONE, NONE
			continue
		}
		cp := containing_parent(b)
		pb := &l.boxes[cp]
		if .Fixed in b.flags {
			b.space, b.clip = FIXED_SPACE, NONE
		} else {
			b.space, b.clip = pb.content_space, pb.content_clip
			if l.frames_on { flow_fix_box(l, x) }
		}
		if anchored != nil { anchored_space(l, x, anchored) }
		tp := &l.boxes[b.parent]
		b.group = tp.group
		fx := isolate[x] ? Group_Effects{.Isolate} : {}
		if .Effects in b.flags { fx += box_effects(b.cs) }
		if .Plane in b.flags { fx += {.Plane} }
		if fx != {} {
			append(&l.groups, Group{parent = b.group, box = x, alpha = max(b.cs.opacity, 0), effects = fx, space = NONE, dest = b.group})
			b.group = i32(len(l.groups) - 1)
		}
		if .Sticky in b.flags && b.kind != .Inline {
			frame := b.space
			for frame > FIXED_SPACE && l.spaces[frame].kind != .Scroll { frame = l.spaces[frame].parent }
			port_size := c.vp
			if frame > FIXED_SPACE { port_size = l.spaces[frame].port.max - l.spaces[frame].port.min }
			lim := Rect{{-math.F32_MAX, -math.F32_MAX}, {math.F32_MAX, math.F32_MAX}}
			if q := b.parent; q != NONE {
				qb := &l.boxes[q]
				if qb.kind == .Inline { qb = &l.boxes[qb.ifc_root] }
				lim = content_rect(qb)
			}
			ins: [4]f32
			sides := [4]style.Side{.Top, .Right, .Bottom, .Left}
			for s, i in sides {
				base := (i == 0 || i == 2) ? port_size.y : port_size.x
				v, ok := definite(c, b.cs.inset[s], base)
				ins[i] = ok ? v : nan
			}
			append(&l.spaces, Space{kind = .Sticky, parent = b.space, box = x, frame = frame, clip = b.clip, xform = l.spaces[b.space].xform, plane = l.spaces[b.space].plane, persp_from = NONE, ctx = NONE, dest = NONE, port = border_rect(b), limit = lim, inset = ins})
			b = &l.boxes[x]
			b.space = i32(len(l.spaces) - 1)
		}
		if .Transformed in b.flags {
			si := i32(len(l.spaces))
			sp := Space{kind = .Transform, parent = b.space, box = x, frame = NONE, clip = b.clip, xform = si, mat = box_matrix(l, b), plane = l.spaces[b.space].plane, persp_from = NONE, ctx = NONE, dest = NONE}
			if .Plane in b.flags { plane_space(l, &sp, si, b) }
			append(&l.spaces, sp)
			b = &l.boxes[x]
			b.space = si
			if .Plane in b.flags && b.group != NONE && .Plane in l.groups[b.group].effects { plane_group(l, b.group, si) }
		}
		b.content_space, b.content_clip = b.space, b.clip
		if .Clips in b.flags && .Propagated not_in b.flags && b.kind != .Inline {
			append(&l.clips, Clip{parent = b.clip, space = b.space, box = x, rect = padding_rect(b), radii = clip_radii(l, b)})
			b.content_clip = i32(len(l.clips) - 1)
		}
		b.scroll_space = NONE
		if .Scroll in b.flags && .Propagated not_in b.flags && b.kind != .Inline {
			port := padding_rect(b)
			mn, ms := scroll_limits(b, port)
			if ms.x > 0.5 || ms.y > 0.5 || mn.x < -0.5 || mn.y < -0.5 {
				append(&l.spaces, Space{kind = .Scroll, parent = b.space, box = x, frame = NONE, clip = b.content_clip, xform = l.spaces[b.space].xform, plane = l.spaces[b.space].plane, persp_from = NONE, ctx = NONE, dest = NONE, port = port, max_scroll = ms, min_scroll = mn})
				b.content_space = i32(len(l.spaces) - 1)
				b.scroll_space = b.content_space
				if off, ok := l.scroll[b.node]; ok { l.scroll[b.node] = {clamp(off.x, mn.x, ms.x), clamp(off.y, mn.y, ms.y)} }
			}
		}
		if .Multicol in b.fx { flow_spaces(l, x); b = &l.boxes[x] }
		// fragments of positioned inline boxes are painted with them, not with their line
		if b.kind == .Inline {
			if .Positioned in b.flags || .Stacking in b.flags { b.layer = x } else if tp.kind == .Inline { b.layer = tp.layer } else { b.layer = NONE }
		}
	}
	groups_reach(l)
	// offsets of containers that no longer scroll are forgotten
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for node in l.scroll {
		i := int(base.handle_index(node))
		keep := false
		if i < len(l.node_box) {
			if bi := l.node_box[i]; bi != NONE && l.boxes[bi].node == node && l.boxes[bi].scroll_space != NONE { keep = true }
		}
		if !keep { append(&gone, node) }
	}
	for node in gone { delete_key(&l.scroll, node) }
}
