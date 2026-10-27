package layout

import "core:math"

// Absolutely positioned boxes (CSS 2.1 §10.3.7, §10.6.4; fixed: the viewport is the containing block). They are laid
// out when their containing block's size is known: at the end of its layout, or, for an inline containing block, at the
// end of the inline formatting context that holds its fragments.

// Offset of `from`'s border-box origin from `to`'s, along the boxes positions are relative to.
@(private)
offset_between :: proc(c: ^Ctx, from, to: i32) -> (Vec2, bool) {
	off: Vec2
	cur := from
	for steps := 0; steps < 1 << 20 && cur != NONE; steps += 1 {
		if cur == to { return off, true }
		b := &c.l.boxes[cur]
		if b.kind != .Inline { off += b.pos }
		cur = b.pos_ref
	}
	return off, false
}

layout_abs_list :: proc(c: ^Ctx, cbi: i32) {
	cb := &c.l.boxes[cbi]
	ref := cbi
	cbr: Rect
	switch {
	case .Root in cb.flags:
		cbr = Rect{{0, 0}, c.vp}
	case cb.kind == .Inline:
		ref = cb.ifc_root
		cbr = Rect{cb.pos + {cb.border[3], cb.border[0]}, cb.pos + cb.size - {cb.border[1], cb.border[2]}}
	case:
		cbr = Rect{{cb.border[3], cb.border[0]}, cb.size - {cb.border[1], cb.border[2]}}
	}
	for a := cb.abs_first; a != NONE; a = c.l.boxes[a].abs_next {
		cbr2 := cbr
		if .Fixed in c.l.boxes[a].flags { cbr2 = Rect{{0, 0}, c.vp} }
		layout_abs(c, a, ref, cbr2)
	}
}

@(private)
layout_abs :: proc(c: ^Ctx, ai, ref: i32, cbr: Rect) {
	cbw := max(cbr.max.x - cbr.min.x, 0)
	cbh := max(cbr.max.y - cbr.min.y, 0)
	resolve_box_model(c, &c.l.boxes[ai], cbw)
	k := &c.l.boxes[ai]
	cs := k.cs
	sp := cbr.min
	if k.static_ref != NONE {
		if off, ok := offset_between(c, k.static_ref, ref); ok { sp = off + k.static_pos }
	}
	il, il_ok := definite(c, cs.inset[.Left], cbw)
	ir, ir_ok := definite(c, cs.inset[.Right], cbw)
	it, it_ok := definite(c, cs.inset[.Top], cbh)
	ib, ib_ok := definite(c, cs.inset[.Bottom], cbh)
	rtl := is_rtl(c.l.boxes[k.parent].cs)
	mL := k.auto_l ? 0 : k.margin[3]
	mR := k.auto_r ? 0 : k.margin[1]
	mT := k.auto_t ? 0 : k.margin[0]
	mB := k.auto_b ? 0 : k.margin[2]

	// horizontal (§10.3.7)
	spec_w, has_w := to_border_w(c, k, cs.width, cbw)
	if k.kind == .Replaced { spec_w, has_w = replaced_size(c, ai, cbw, cbh).x, true }
	k = &c.l.boxes[ai]
	if !has_w {
		#partial switch cs.width.kind {
		case .Min_Content: spec_w, has_w = intrinsic(c, ai)[0], true
		case .Max_Content: spec_w, has_w = intrinsic(c, ai)[1], true
		case .Fit_Content:
			// CSS Sizing 3: shrink-to-fit in the space the insets leave; a size, so auto margins centre it (a popover)
			spec_w, has_w = shrink_to_fit(c, ai, cbw - (il_ok ? il : 0) - (ir_ok ? ir : 0) - mL - mR), true
		}
		k = &c.l.boxes[ai]
	}
	if k.kind == .Table { spec_w, has_w = table_width(c, ai, cbw, cbw - mL - mR - (il_ok ? il : 0) - (ir_ok ? ir : 0)), true; k = &c.l.boxes[ai] }
	static_left := sp.x - cbr.min.x
	w, left: f32
	if has_w {
		w = k.kind == .Replaced || k.kind == .Table ? spec_w : clamp_w(c, k, spec_w, cbw)
		switch {
		case il_ok && ir_ok:
			free := cbw - il - ir - w - mL - mR
			if k.auto_l && k.auto_r {
				if free >= 0 { mL, mR = free * 0.5, free * 0.5 } else if rtl { mL = free } else { mR = free }
			} else if k.auto_l { mL = free } else if k.auto_r { mR = free }
			left = il
			if rtl && !k.auto_l && !k.auto_r { left = cbw - ir - w - mL - mR }
		case il_ok: left = il
		case ir_ok: left = cbw - ir - w - mL - mR
		case: left = static_left
		}
	} else {
		switch {
		case il_ok && ir_ok:
			w = clamp_w(c, k, cbw - il - ir - mL - mR, cbw)
			left = il
		case il_ok:
			w = clamp_w(c, k, shrink_to_fit(c, ai, cbw - il - mL - mR), cbw)
			left = il
		case ir_ok:
			w = clamp_w(c, k, shrink_to_fit(c, ai, cbw - ir - mL - mR), cbw)
			left = cbw - ir - w - mL - mR
		case:
			left = static_left
			w = clamp_w(c, k, shrink_to_fit(c, ai, cbw - left - mL - mR), cbw)
		}
	}
	k = &c.l.boxes[ai]
	k.margin[3], k.margin[1] = mL, mR

	// vertical (§10.6.4)
	res := layout_contents(c, ai, w, cbh, -1, nil)
	k = &c.l.boxes[ai]
	h := res.h
	_, has_h := to_border_h(c, k, cs.height, cbh)
	has_h = has_h || k.kind == .Replaced || cs.aspect_ratio > 0
	// an intrinsic height keyword is the content's height: the insets do not stretch it (auto margins centre it)
	#partial switch cs.height.kind { case .Min_Content, .Max_Content, .Fit_Content: has_h = true }
	static_top := sp.y - cbr.min.y
	top: f32
	if has_h {
		switch {
		case it_ok && ib_ok:
			free := cbh - it - ib - h - mT - mB
			if k.auto_t && k.auto_b { mT, mB = free * 0.5, free * 0.5 } else if k.auto_t { mT = free } else if k.auto_b { mB = free }
			top = it
		case it_ok: top = it
		case ib_ok: top = cbh - ib - h - mT - mB
		case: top = static_top
		}
	} else {
		switch {
		case it_ok && ib_ok:
			nh := clamp_h(c, k, cbh - it - ib - mT - mB, cbh)
			if math.abs(nh - h) > 0.01 { set_height(c, ai, w, cbh, nh); h = nh }
			top = it
		case it_ok: top = it
		case ib_ok: top = cbh - ib - h - mT - mB
		case: top = static_top
		}
	}
	k = &c.l.boxes[ai]
	k.margin[0], k.margin[2] = mT, mB
	k.pos = cbr.min + {left + mL, top + mT + k.pre_h}
}
