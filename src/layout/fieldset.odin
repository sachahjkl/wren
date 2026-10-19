package layout

import "wb:dom"

// <fieldset> and its rendered legend (HTML §15.3.13). The rendered legend is the fieldset's first <legend> child,
// when it is neither floated nor absolutely positioned. It is laid out on the fieldset's block-start border: shrunk to
// fit, at the inline start of the content box (after its own margins; auto margins center it or push it to the end),
// its margin box centered on the border. A legend taller than the border moves the border down to its middle and the
// content below it. The painter (fieldset_border) draws the border interrupted behind the legend's border box.
// A fieldset establishes a block formatting context.

@(private)
fieldset_flags :: proc(c: ^Ctx, bi: i32, n: ^dom.Node, parent: i32) {
	b := &c.l.boxes[bi]
	if n == nil || n.kind != .Element { return }
	if n.name == "fieldset" && b.kind == .Block {
		b.flags += {.Fieldset, .Bfc}
		return
	}
	if n.name != "legend" || parent == NONE || .Fieldset not_in c.l.boxes[parent].flags { return }
	if b.flags & {.Float, .Abs, .Atomic, .Block_In_Inline} != {} || b.kind == .Inline { return }
	if c.l.boxes[parent].node != n.parent { return }
	// a candidate: the first one among the fieldset's children is the rendered legend (fieldset_legend)
	b.flags += {.Legend}
}

// The rendered legend of a fieldset box (its first legend child that is neither floated nor absolutely positioned),
// NONE when it has none.
fieldset_legend :: proc(l: ^Layout, bi: i32) -> i32 {
	if bi < 0 || int(bi) >= len(l.boxes) || .Fieldset not_in l.boxes[bi].flags { return NONE }
	for ch := l.boxes[bi].first; ch != NONE; ch = l.boxes[ch].next {
		if .Legend in l.boxes[ch].flags { return ch }
	}
	return NONE
}

// Where a fieldset's block-start border is drawn (from its border box top, device px) and the inline range of its
// legend's border box (layout coordinates) the border is interrupted behind. ok = false: no rendered legend.
fieldset_border :: proc(l: ^Layout, bi: i32) -> (shift: f32, gap: [2]f32, ok: bool) {
	lg := fieldset_legend(l, bi)
	if lg == NONE { return }
	f, k := &l.boxes[bi], &l.boxes[lg]
	tall := k.size.y + k.margin[0] + k.margin[2]
	shift = max((tall - f.border[0]) * 0.5, 0)
	return shift, {k.abs.x, k.abs.x + k.size.x}, true
}

// Lays out the rendered legend of fieldset `bi` (content width `cw`) and returns how far the fieldset's content moves
// down for it.
@(private)
place_legend :: proc(c: ^Ctx, bi, lg: i32, cw: f32) -> f32 {
	k := &c.l.boxes[lg]
	if !pre_model(c, lg, k) { resolve_box_model(c, k, cw) }
	k = &c.l.boxes[lg]
	auto_l, auto_r := k.auto_l, k.auto_r
	if k.auto_l { k.margin[3] = 0 }
	if k.auto_r { k.margin[1] = 0 }
	if k.auto_t { k.margin[0] = 0 }
	if k.auto_b { k.margin[2] = 0 }
	w: f32
	if spec, ok := to_border_w(c, k, k.cs.width, cw); ok {
		w = clamp_w(c, k, spec, cw)
	} else {
		w = clamp_w(c, k, shrink_to_fit(c, lg, cw - mg_w(k)), cw)
	}
	res := layout_contents(c, lg, w, -1, -1, nil)
	k = &c.l.boxes[lg]
	f := &c.l.boxes[bi]
	free := cw - w - mg_w(k)
	x := k.margin[3]
	switch {
	case auto_l && auto_r: x += max(free, 0) * 0.5
	case auto_l: x += max(free, 0)
	case is_rtl(f.cs) && !auto_r: x += max(free, 0)
	}
	tall := res.h + mg_h(k)
	bt := f.border[0]
	top := tall > bt ? f32(0) : (bt - tall) * 0.5
	k.pos = {content_x(f) + x, top + k.margin[0]}
	return max(tall - bt, 0)
}
