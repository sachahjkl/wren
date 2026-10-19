package layout

import "core:slice"
import "wb:base"

// Display list in CSS 2.1 Appendix E order. Each stacking context paints: its own background and borders, child stacking
// contexts with negative z-index, in-flow block-level backgrounds, floats, inline content, positioned descendants with
// z-index auto / 0 and stacking contexts with z-index 0 (tree order), positive z-index stacking contexts, then outlines.
// Floats, inline-blocks and positioned boxes with z-index auto paint "as if" they created a stacking context, but their
// positioned descendants and real stacking contexts belong to the enclosing one.

@(private)
Z_Entry :: struct { box: i32, z: i32 }

@(private)
Paint_Ctx :: struct {
	c:        ^Ctx,
	outlines: ^[dynamic]i32,
	scrollers: ^[dynamic]i32,
}

@(private)
hit_node :: proc(c: ^Ctx, bi: i32) -> base.Handle {
	for cur := bi; cur != NONE; cur = c.l.boxes[cur].parent {
		b := &c.l.boxes[cur]
		if b.node != base.NIL_HANDLE && .Root not_in b.flags { return b.node }
	}
	return base.NIL_HANDLE
}

@(private)
push_item :: proc(c: ^Ctx, it: Display_Item) {
	if c.dl_out != nil { append(c.dl_out, it) } else { append(&c.l.items, it) }
}

@(private)
item_for_box :: proc(c: ^Ctx, kind: Item_Kind, bi: i32, r: Rect) -> Display_Item {
	b := &c.l.boxes[bi]
	it := Display_Item{kind = kind, box = bi, node = hit_node(c, bi), cs = b.cs, rect = r, space = b.space, clip = b.clip, group = b.group, fi = b.fi, item = NONE}
	if .No_Pointer not_in b.flags && .Hidden not_in b.flags { it.flags += {.Hit} }
	return it
}

// Background, shadows and borders of a box, plus the content area of replaced elements and controls.
@(private)
emit_box :: proc(p: ^Paint_Ctx, bi: i32) {
	c := p.c
	b := &c.l.boxes[bi]
	if .Root in b.flags { return }
	if b.kind == .Inline { return }
	if .Hidden in b.flags {
		if .Scroll in b.flags && b.scroll_space != NONE { append(p.scrollers, bi) }
		return
	}
	cs := b.cs
	paints := cs.background_color.a > 0 || cs.background_image.kind == .Gradient || len(cs.box_shadow) > 0 ||
		b.border[0] + b.border[1] + b.border[2] + b.border[3] > 0
	if b.node != base.NIL_HANDLE || paints {
		it := item_for_box(c, .Box, bi, border_rect(b))
		if bi == c.l.boxes[0].first || (b.node == c.body_el && c.st.canvas == cs.background_color) {
			// the root's (or body's) background is the canvas, painted by the shell behind everything
			if cs.background_color == c.st.canvas { it.flags += {.No_Background} }
		}
		push_item(c, it)
	}
	if b.kind == .Replaced {
		kind := .Control in b.flags ? Item_Kind.Control : Item_Kind.Replaced
		push_item(c, item_for_box(c, kind, bi, content_rect(b)))
	}
	if cs.outline_width > 0 { append(p.outlines, bi) }
	if b.scroll_space != NONE { append(p.scrollers, bi) }
}

@(private)
emit_marker :: proc(p: ^Paint_Ctx, bi: i32) {
	c := p.c
	b := &c.l.boxes[bi]
	if b.marker_w <= 0 || .Hidden in b.flags || b.fi < 0 { return }
	fi := &c.l.fonts[b.fi]
	base := b.abs + b.marker_pos
	it := item_for_box(c, .Marker, bi, Rect{{base.x, base.y - fi.ascent}, {base.x + b.marker_w, base.y + fi.descent}})
	it.text = b.marker
	it.baseline = base.y
	it.space, it.clip = b.content_space, b.content_clip
	push_item(c, it)
}

// The fragments of one inline formatting context that belong to `owner` (NONE: not inside a positioned inline box).
@(private)
emit_lines :: proc(p: ^Paint_Ctx, ri: i32, owner: i32) {
	c := p.c
	r := &c.l.boxes[ri]
	if .Ifc not_in r.flags { return }
	for li in r.lines[0] ..< r.lines[1] {
		ln := c.l.lines[li]
		for fi in ln.frags[0] ..< ln.frags[1] {
			f := c.l.frags[fi]
			switch f.kind {
			case .Text, .Ellipsis:
				layer := f.box != NONE ? c.l.boxes[f.box].layer : NONE
				if layer != owner { continue }
				src := f.box != NONE ? f.box : ri
				sb := &c.l.boxes[src]
				base := sb.abs
				it := Display_Item{kind = .Text, box = src, rect = Rect{base + {f.x, f.y}, base + {f.x + f.w, f.y + f.h}}, text = f.text, fi = f.fi,
					baseline = base.y - (f.box != NONE ? 0 : 0) + f.baseline, extra = f.extra, space = sb.space, clip = sb.clip, group = sb.group, item = NONE}
				if f.box == NONE { it.space, it.clip = r.content_space, r.content_clip }
				if f.kind == .Text {
					item := &c.l.inline_items[f.item]
					if item.cs.visibility != .Visible { continue }
					it.cs, it.node, it.deco, it.deco_color, it.deco_box = item.cs, item.node, item.deco, item.deco_color, item.deco_box
					it.item = f.item
					if item.cs.pointer_events { it.flags += {.Hit} }
				} else {
					it.cs, it.node = r.cs, hit_node(c, ri)
					it.flags += {.Hit}
				}
				push_item(c, it)
			case .Box:
				ib := &c.l.boxes[f.box]
				if ib.layer != owner { continue }
				if .Hidden in ib.flags { continue }
				base := ib.abs
				it := item_for_box(c, .Inline_Box, f.box, Rect{base + {f.x, f.y}, base + {f.x + f.w, f.y + f.h}})
				if .Left_Edge in f.flags { it.flags += {.Left_Edge} }
				if .Right_Edge in f.flags { it.flags += {.Right_Edge} }
				push_item(c, it)
				if ib.cs.outline_width > 0 && .Left_Edge in f.flags { append(p.outlines, f.box) }
			case .Atomic:
				k := &c.l.boxes[f.box]
				enclosing := NONE
				if q := k.parent; q != NONE && c.l.boxes[q].kind == .Inline { enclosing = c.l.boxes[q].layer }
				if enclosing != owner { continue }
				if .Positioned in k.flags || .Stacking in k.flags { continue }
				paint_pseudo(p, f.box)
			}
		}
	}
}

@(private)
hoisted :: #force_inline proc(b: ^Box) -> bool { return .Positioned in b.flags || .Stacking in b.flags }

// Steps 3 to 5 of Appendix E for the subtree of `root` (excluding what other layers paint).
@(private)
paint_content :: proc(p: ^Paint_Ctx, root: i32) {
	c := p.c
	if c.dl_par && c.dl_out == nil && paint_content_shared(p, root) { return }
	stack := make([dynamic]i32, 0, 32, context.temp_allocator)
	push_children :: proc(c: ^Ctx, stack: ^[dynamic]i32, x: i32) {
		n := len(stack)
		for ch := c.l.boxes[x].first; ch != NONE; ch = c.l.boxes[ch].next { append(stack, ch) }
		for i, j := n, len(stack) - 1; i < j; i, j = i + 1, j - 1 { stack[i], stack[j] = stack[j], stack[i] }
	}
	// 3: block-level backgrounds and borders, in tree order
	push_children(c, &stack, root)
	for len(stack) > 0 {
		x := pop(&stack)
		b := &c.l.boxes[x]
		if hoisted(b) || .Float in b.flags || .Atomic in b.flags { continue }
		if b.kind != .Inline { emit_box(p, x) }
		push_children(c, &stack, x)
	}
	// 4: floats
	push_children(c, &stack, root)
	for len(stack) > 0 {
		x := pop(&stack)
		b := &c.l.boxes[x]
		if hoisted(b) || .Atomic in b.flags { continue }
		if .Float in b.flags { paint_pseudo(p, x); continue }
		push_children(c, &stack, x)
	}
	// 5: inline content (lines of every block container, list markers)
	rb := &c.l.boxes[root]
	if rb.kind == .Inline {
		emit_lines(p, rb.ifc_root, root)
	} else {
		emit_own_lines(p, root)
	}
	push_children(c, &stack, root)
	for len(stack) > 0 {
		x := pop(&stack)
		b := &c.l.boxes[x]
		if hoisted(b) || .Float in b.flags || .Atomic in b.flags { continue }
		emit_own_lines(p, x)
		push_children(c, &stack, x)
	}
}

// A block container's list marker and the lines of its inline formatting context (those not painted by a positioned
// inline box): contiguous, their range remembered for splicing (splice.odin).
@(private)
emit_own_lines :: proc(p: ^Paint_Ctx, x: i32) {
	c := p.c
	b := &c.l.boxes[x]
	out := c.dl_out != nil ? c.dl_out : &c.l.items
	start := i32(len(out))
	if .List_Item in b.flags { emit_marker(p, x) }
	if .Ifc in c.l.boxes[x].flags {
		emit_lines(p, x, NONE)
		inf := &c.l.inc.info[x]
		inf.items, inf.items_gen = {start, i32(len(out))}, c.l.inc.dl_gen
		if c.dl_fix != nil { append(c.dl_fix, x) }
	}
}

// A float, an inline-block or a positioned box with z-index auto: painted atomically, like a stacking context.
@(private)
paint_pseudo :: proc(p: ^Paint_Ctx, bi: i32) {
	if !stack_ok(p.c) { return }
	emit_box(p, bi)
	paint_content(p, bi)
}

@(private)
z_less :: proc(a, b: Z_Entry) -> bool { return a.z < b.z }

@(private)
paint_stacking :: proc(p: ^Paint_Ctx, bi: i32) {
	c := p.c
	if !stack_ok(c) { return }
	outlines := make([dynamic]i32, 0, 0, context.temp_allocator)
	scrollers := make([dynamic]i32, 0, 0, context.temp_allocator)
	sub := Paint_Ctx{c = c, outlines = &outlines, scrollers = &scrollers}
	emit_box(&sub, bi)

	// layers of this context
	neg := make([dynamic]Z_Entry, 0, 0, context.temp_allocator)
	zero := make([dynamic]i32, 0, 0, context.temp_allocator)
	pos := make([dynamic]Z_Entry, 0, 0, context.temp_allocator)
	stack := make([dynamic]i32, 0, 32, context.temp_allocator)
	for ch := c.l.boxes[bi].first; ch != NONE; ch = c.l.boxes[ch].next { append(&stack, ch) }
	slice.reverse(stack[:])
	for len(stack) > 0 {
		x := pop(&stack)
		b := &c.l.boxes[x]
		if .Stacking in b.flags {
			z := b.cs.z_auto ? 0 : b.cs.z_index
			if z < 0 { append(&neg, Z_Entry{x, z}) } else if z == 0 { append(&zero, x) } else { append(&pos, Z_Entry{x, z}) }
			continue
		}
		if .Positioned in b.flags { append(&zero, x) }
		n := len(stack)
		for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next { append(&stack, ch) }
		slice.reverse(stack[n:])
	}
	slice.stable_sort_by(neg[:], z_less)
	slice.stable_sort_by(pos[:], z_less)

	for e in neg { paint_stacking(&sub, e.box) }
	paint_content(&sub, bi)
	for x in zero {
		if .Stacking in c.l.boxes[x].flags { paint_stacking(&sub, x) } else { paint_pseudo(&sub, x) }
	}
	for e in pos { paint_stacking(&sub, e.box) }

	for x in scrollers { emit_scrollbars(c, x) }
	for x in outlines {
		b := &c.l.boxes[x]
		r := border_rect(b)
		it := item_for_box(c, .Outline, x, r)
		it.flags -= {.Hit}
		push_item(c, it)
	}
}

@(private)
emit_scrollbars :: proc(c: ^Ctx, bi: i32) {
	b := &c.l.boxes[bi]
	if b.scroll_space == NONE { return }
	sp := &c.l.spaces[b.scroll_space]
	w := c.set.scrollbar_width * c.scale
	m := c.set.scrollbar_margin * c.scale
	port := sp.port
	if sp.max_scroll.y > 0 {
		it := item_for_box(c, .Scrollbar, bi, Rect{{port.max.x - w - m, port.min.y + m}, {port.max.x - m, port.max.y - m - (sp.max_scroll.x > 0 ? w + m : 0)}})
		it.flags = {.Vertical}
		push_item(c, it)
	}
	if sp.max_scroll.x > 0 {
		it := item_for_box(c, .Scrollbar, bi, Rect{{port.min.x + m, port.max.y - w - m}, {port.max.x - m - (sp.max_scroll.y > 0 ? w + m : 0), port.max.y - m}})
		it.flags = {}
		push_item(c, it)
	}
}

@(private)
build_display_list :: proc(c: ^Ctx) {
	clear(&c.l.items)
	c.l.inc.dl_gen += 1
	c.dl_par = par_threads(c.l.settings.threads) > 0 && len(c.l.boxes) >= max(c.l.settings.threads_min_display_boxes, 1)
	defer c.dl_par = false
	p := Paint_Ctx{c = c}
	paint_stacking(&p, 0)
}
