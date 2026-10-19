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
		if .Scroll in b.flags { b.overflow = padding_rect(b) }
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
		m, hm := IDENTITY, false
		if b.clip_owner != cp && has[cp] { m, hm = inner[cp], true }
		if .Transformed in b.flags {
			t := box_matrix(l, b)
			m = hm ? mat_mul(m, t) : t
			hm = true
		}
		inner[x], has[x] = m, hm
		add(l, b.clip_owner, hm ? mat_bounds(m, border_rect(b)) : border_rect(b), in_fixed[x], &doc)
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
					add(l, owner, lhm ? mat_bounds(lm, r) : r, in_fixed[x], &doc)
				}
			}
		}
	}
	return doc
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

@(private)
finish :: proc(c: ^Ctx) {
	l := c.l
	order := preorder(l)

	// coordinates
	for x in order {
		b := &l.boxes[x]
		if .Relative in b.flags { b.rel = relative_offset(c, b) } else { b.rel = {} }
		if b.pos_ref == NONE { b.abs = b.pos; continue }
		ref := &l.boxes[b.pos_ref]
		if b.kind == .Inline {
			// inline boxes: `abs` is the origin of their fragments (their IFC root, moved by relative offsets)
			b.abs = ref.abs + b.rel
			if p := b.parent; p != NONE && l.boxes[p].kind == .Inline { b.abs += l.boxes[p].abs - ref.abs }
			continue
		}
		b.abs = ref.abs + b.pos + b.rel
		if .Abs not_in b.flags {
			if p := b.parent; p != NONE && l.boxes[p].kind == .Inline { b.abs += l.boxes[p].abs - l.boxes[l.boxes[p].ifc_root].abs }
		}
	}

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
	l.height = c.l.doc_scroll_y ? max(doc.max.y, c.vp.y) : c.vp.y
	l.doc_width = max(doc.max.x, c.vp.x)

	// spaces, clips, groups
	clear(&l.spaces); clear(&l.clips); clear(&l.groups)
	append(&l.spaces, Space{kind = .Document, parent = NONE, box = 0, frame = NONE, clip = NONE, xform = NONE})
	append(&l.spaces, Space{kind = .Fixed, parent = NONE, box = 0, frame = NONE, clip = NONE, xform = NONE})
	nan := math.nan_f32()
	isolate := isolated_contexts(l)
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
		}
		tp := &l.boxes[b.parent]
		b.group = tp.group
		fx := isolate[x] ? Group_Effects{.Isolate} : {}
		if .Effects in b.flags { fx += box_effects(b.cs) }
		if fx != {} {
			append(&l.groups, Group{parent = b.group, box = x, alpha = max(b.cs.opacity, 0), effects = fx})
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
			append(&l.spaces, Space{kind = .Sticky, parent = b.space, box = x, frame = frame, clip = b.clip, xform = l.spaces[b.space].xform, port = border_rect(b), limit = lim, inset = ins})
			b = &l.boxes[x]
			b.space = i32(len(l.spaces) - 1)
		}
		if .Transformed in b.flags {
			si := i32(len(l.spaces))
			append(&l.spaces, Space{kind = .Transform, parent = b.space, box = x, frame = NONE, clip = b.clip, xform = si, mat = box_matrix(l, b)})
			b = &l.boxes[x]
			b.space = si
		}
		b.content_space, b.content_clip = b.space, b.clip
		if .Clips in b.flags && .Propagated not_in b.flags && b.kind != .Inline {
			append(&l.clips, Clip{parent = b.clip, space = b.space, box = x, rect = padding_rect(b), radii = clip_radii(l, b)})
			b.content_clip = i32(len(l.clips) - 1)
		}
		b.scroll_space = NONE
		if .Scroll in b.flags && .Propagated not_in b.flags && b.kind != .Inline {
			port := padding_rect(b)
			ms := Vec2{max(b.overflow.max.x - port.max.x, 0), max(b.overflow.max.y - port.max.y, 0)}
			if b.cs.overflow_x != .Scroll && b.cs.overflow_x != .Auto { ms.x = 0 }
			if b.cs.overflow_y != .Scroll && b.cs.overflow_y != .Auto { ms.y = 0 }
			if ms.x > 0.5 || ms.y > 0.5 {
				append(&l.spaces, Space{kind = .Scroll, parent = b.space, box = x, frame = NONE, clip = b.content_clip, xform = l.spaces[b.space].xform, port = port, max_scroll = ms})
				b.content_space = i32(len(l.spaces) - 1)
				b.scroll_space = b.content_space
				if off, ok := l.scroll[b.node]; ok { l.scroll[b.node] = {clamp(off.x, 0, ms.x), clamp(off.y, 0, ms.y)} }
			}
		}
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
