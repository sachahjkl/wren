package layout

import "core:math"
import "wb:style"

// Block formatting (CSS 2.1 §9.4.1, §10.3.3, §10.6.3, §8.3.1 margin collapsing, §9.5 floats).
//
// Margin collapsing works with "struts": the margins that adjoin so far (largest positive, most negative). While a box's
// top margin still collapses with its first child's, the child's margins go into the strut of the box's parent; once
// some content closes it, the box's position is the strut's value. Empty boxes let margins collapse through them.

@(private)
Strut :: struct { pos, neg: f32 }

@(private)
strut_add :: proc(s: ^Strut, m: f32) {
	if m >= 0 { s.pos = max(s.pos, m) } else { s.neg = min(s.neg, m) }
}

@(private)
strut_value :: proc(s: Strut) -> f32 { return s.pos + s.neg }

@(private)
Float_Box :: struct { r: Rect, left: bool }

// The floats of one block formatting context, in its coordinates (origin: the root's content box).
@(private)
Bfc :: struct {
	floats:   [dynamic]Float_Box,
	last_top: f32,   // a float may not be placed above an earlier one (§9.5.1 rule 5)
	bottom:   f32,   // lowest float bottom so far
}

@(private)
Flow_Ctx :: struct {
	bfc:  ^Bfc,
	x, y: f32,       // BFC position of the container's content box (y before `open`)
	open: ^Strut,    // the container's top margin still collapses: its content starts at y + value(open^)
}

@(private)
content_top :: proc(fc: ^Flow_Ctx) -> f32 { return fc.y + (fc.open != nil ? strut_value(fc.open^) : 0) }

@(private)
bfc_make :: proc() -> Bfc { return Bfc{floats = make([dynamic]Float_Box, context.temp_allocator), last_top = -math.F32_MAX, bottom = -math.F32_MAX} }

// No float of the formatting context can reach the content of `b` laid out in flow at `fc`: none inside it, and those
// placed so far end above where its content can start (its content cannot rise above that: no negative margin inside).
// Its layout is then the same as with no float at all.
@(private)
floats_clear_of :: proc(fc: ^Flow_Ctx, b: ^Box) -> bool {
	if fc.bfc == nil || .Bfc_Floats in b.flags { return false }
	if len(fc.bfc.floats) == 0 { return true }
	if .Neg_Margins in b.flags { return false }
	top := fc.y + (fc.open != nil ? min(strut_value(fc.open^), 0) : 0)
	return fc.bfc.bottom <= top
}

// The space left between the floats intersecting [y0, y1) within [left, right].
@(private)
bfc_band :: proc(bfc: ^Bfc, y0, y1, left, right: f32) -> (l, r: f32) {
	l, r = left, right
	if bfc == nil { return }
	for &f in bfc.floats {
		if f.r.max.y <= y0 || f.r.min.y >= max(y1, y0 + 0.01) { continue }
		if f.left { l = max(l, f.r.max.x) } else { r = min(r, f.r.min.x) }
	}
	return
}

// The lowest float bottom below `y` among the floats intersecting y (where a narrowed band ends), or +inf.
@(private)
bfc_next_bottom :: proc(bfc: ^Bfc, y: f32) -> f32 {
	best: f32 = math.F32_MAX
	if bfc == nil { return best }
	for &f in bfc.floats {
		if f.r.max.y > y + 0.01 && f.r.min.y <= y + 0.01 { best = min(best, f.r.max.y) }
	}
	if best == math.F32_MAX {
		for &f in bfc.floats { if f.r.min.y > y { best = min(best, f.r.min.y) } }
	}
	return best
}

@(private)
bfc_clear_floor :: proc(bfc: ^Bfc, clear: style.Clear) -> f32 {
	floor: f32 = -math.F32_MAX
	if bfc == nil || clear == .None { return floor }
	for &f in bfc.floats {
		if (f.left && (clear == .Left || clear == .Both)) || (!f.left && (clear == .Right || clear == .Both)) { floor = max(floor, f.r.max.y) }
	}
	return floor
}

@(private)
bfc_bottom :: proc(bfc: ^Bfc) -> f32 {
	b: f32 = -math.F32_MAX
	for &f in bfc.floats { b = max(b, f.r.max.y) }
	return b
}

@(private)
is_rtl :: proc(cs: ^style.Computed) -> bool { return cs.direction == .Rtl }

// Shrink-to-fit width (§10.3.5): min(max(min-content, available), max-content), as a border-box width.
@(private)
shrink_to_fit :: proc(c: ^Ctx, bi: i32, avail: f32) -> f32 {
	in2 := intrinsic(c, bi)
	return min(max(in2[0], avail), in2[1])
}

// Border-box width of a block-level box in normal flow and its used horizontal margins (§10.3.3, §10.3.4).
@(private)
block_width :: proc(c: ^Ctx, bi: i32, cb_w, avail: f32) {
	b := &c.l.boxes[bi]
	cs := b.cs
	w: f32
	if b.kind == .Replaced {
		sz := replaced_size(c, bi, cb_w, -1)
		b = &c.l.boxes[bi]
		w = sz.x
	} else if b.kind == .Table {
		w = table_width(c, bi, cb_w, avail - (b.auto_l ? 0 : b.margin[3]) - (b.auto_r ? 0 : b.margin[1]))
		b = &c.l.boxes[bi]
	} else if spec, ok := to_border_w(c, b, cs.width, cb_w); ok {
		w = clamp_w(c, b, spec, cb_w)
	} else {
		#partial switch cs.width.kind {
		case .Min_Content: w = intrinsic(c, bi)[0]
		case .Max_Content: w = intrinsic(c, bi)[1]
		case .Fit_Content: w = shrink_to_fit(c, bi, avail - (b.auto_l ? 0 : b.margin[3]) - (b.auto_r ? 0 : b.margin[1]))
		case:
			ml := b.auto_l ? 0 : b.margin[3]
			mr := b.auto_r ? 0 : b.margin[1]
			w = avail - ml - mr
			if .Block_In_Inline not_in b.flags && (.Bfc not_in b.flags || b.kind == .Flex || b.kind == .Block) {
				// a block fills its line: auto margins are 0
				b = &c.l.boxes[bi]
				w = clamp_w(c, b, w, cb_w)
				if b.auto_l { b.margin[3] = 0 }
				if b.auto_r { b.margin[1] = 0 }
				if w >= avail - ml - mr - 0.001 { b.size.x = w; return }
			}
		}
		b = &c.l.boxes[bi]
		w = clamp_w(c, b, w, cb_w)
	}
	b = &c.l.boxes[bi]
	b.size.x = w
	// auto margins share what is left (§10.3.3); over-constrained: the end margin gives way
	free := avail - w - (b.auto_l ? 0 : b.margin[3]) - (b.auto_r ? 0 : b.margin[1])
	rtl := c.l.boxes[b.parent].cs != nil && is_rtl(c.l.boxes[b.parent].cs)
	if b.auto_l && b.auto_r {
		if free < 0 {
			if rtl { b.margin[3], b.margin[1] = free, 0 } else { b.margin[3], b.margin[1] = 0, free }
		} else {
			b.margin[3], b.margin[1] = free * 0.5, free * 0.5
		}
	} else if b.auto_l {
		b.margin[3] = free
	} else if b.auto_r {
		b.margin[1] = free
	} else if rtl {
		b.margin[3] = avail - w - b.margin[1]
	} else {
		b.margin[1] = avail - w - b.margin[3]
	}
}

@(private)
Result :: struct {
	h:       f32,     // border-box height
	end:     Strut,   // margins adjoining the bottom of the content that collapse with the box's own bottom margin
	through: bool,    // nothing closed the margins: the box's top and bottom margins collapse together
}

@(private)
collapses_top :: proc(b: ^Box) -> bool {
	return b.kind == .Block && .Bfc not_in b.flags && b.border[0] == 0 && b.padding[0] == 0 && .Block_In_Inline not_in b.flags
}

@(private)
collapses_bottom :: proc(c: ^Ctx, b: ^Box) -> bool {
	return b.kind == .Block && .Bfc not_in b.flags && b.border[2] == 0 && b.padding[2] == 0 && b.cs.height.kind == .Auto &&
		(b.cs.min_height.kind == .Auto || px_of(c, b.cs.min_height, -1) <= 0)
}

// Height a box would use from its `height` property, as a border-box height; ok = false: auto (content-based).
@(private)
specified_height :: proc(c: ^Ctx, b: ^Box, cb_h: f32) -> (f32, bool) {
	return to_border_h(c, b, b.cs.height, cb_h)
}

// Lays out the content of box `bi` at border-box width `w` (already stored in size.x), and returns its height.
//   cb_h:     height of the containing block (percentages of `height`), < 0: indefinite
//   forced_h: >= 0 imposes the border-box height (flex, tables)
//   fc:       for a block container taking part in its parent's block formatting context: where its content box sits in
//             that context (nil: the box is a formatting context root or is laid out on its own)
//
// The result is cached in the box for the same inputs (`w`, `cb_h`, `forced_h`), across passes too: a later pass that
// left the box and its content untouched (`Box.inc` empty) takes it as is. A box laid out in its parent's flow is cached
// only when no float of that block formatting context can reach it (none placed yet, none inside it): its content is
// then independent of where it sits; the margins it adds to a strut it shares with its parent (collapsing through its
// top) are recorded apart and merged, which is the same as adding them in place (a strut is a max / min).
@(private)
layout_contents :: proc(c: ^Ctx, bi: i32, w, cb_h, forced_h: f32, fc_in: ^Flow_Ctx) -> Result {
	b := &c.l.boxes[bi]
	b.size.x = w
	fc := fc_in
	independent := fc == nil
	key := [3]f32{w, cb_h, forced_h}
	flow_ok := !independent && floats_clear_of(fc, b)
	if b.cache_ok && b.inc == {} && b.cache_in == key {
		if independent && !b.cache_flow {
			b.size.y = b.cache_h
			return Result{h = b.cache_h}
		}
		if flow_ok && b.cache_flow {
			b.size.y = b.cache_h
			if fc.open != nil { strut_merge(fc.open, b.cache_contrib) }
			return Result{h = b.cache_h, end = b.cache_end, through = b.cache_through}
		}
	}
	if c.inc != nil { inc_note_layout(c, bi) }
	b.inc = {}
	b.cache_ok = false
	outer_open: ^Strut
	contrib: Strut
	own_fc: Flow_Ctx
	if flow_ok && fc.open != nil {
		outer_open = fc.open
		own_fc = fc^
		own_fc.open = &contrib
		fc = &own_fc
	}
	if !stack_ok(c) { b.size = {w, 0}; return Result{h = pb_h(b)} }
	cs := b.cs
	spec_h, has_h := specified_height(c, b, cb_h)
	if forced_h >= 0 { spec_h, has_h = forced_h, true }
	if !has_h && cs.aspect_ratio > 0 && b.kind != .Replaced && b.kind != .Inline {
		spec_h, has_h = (w - pb_w(b)) / cs.aspect_ratio + pb_h(b), true
	}
	if has_h && forced_h < 0 { spec_h = clamp_h(c, b, spec_h, cb_h) }
	cw := max(w - pb_w(b), 0)
	ch_def := has_h ? max(spec_h - pb_h(b), 0) : -1
	if .Root in b.flags { ch_def = c.vp.y }

	res: Result
	content_h: f32
	switch b.kind {
	case .Block, .Cell, .Caption:
		own: Bfc
		cfc: Flow_Ctx
		if independent || .Bfc in b.flags {
			own = bfc_make()
			cfc = Flow_Ctx{bfc = &own}
		} else {
			cfc = fc^
		}
		ct := collapses_top(b) && !independent && .Bfc not_in b.flags
		cbm := collapses_bottom(c, b) && !independent && .Bfc not_in b.flags
		if !ct { cfc.open = nil }
		through := false
		if .Ifc in b.flags {
			h, empty := layout_ifc(c, bi, cw, &cfc)
			content_h = h
			through = empty
		} else {
			h, end, thr := flow_blocks(c, bi, cw, ch_def, &cfc, ct, cbm)
			content_h = h
			res.end = end
			through = thr
		}
		b = &c.l.boxes[bi]
		if independent || .Bfc in b.flags {
			// a formatting context root grows to contain its floats (§10.6.7)
			if len(own.floats) > 0 { content_h = max(content_h, bfc_bottom(&own)) }
		}
		res.through = through && ct && cbm && !has_h
		if .Ifc not_in b.flags { block_baselines(c, bi) }
	case .Flex:
		content_h = layout_flex(c, bi, cw, ch_def, cb_h)
	case .Grid:
		content_h = layout_grid(c, bi, cw, ch_def, cb_h)
	case .Table:
		content_h = layout_table(c, bi, w, cb_h, forced_h)
	case .Replaced:
		sz := replaced_size(c, bi, -1, cb_h)
		b = &c.l.boxes[bi]
		content_h = sz.y - pb_h(b)
		if !has_h { spec_h, has_h = sz.y, true }
	case .Row_Group, .Row, .Inline:
		content_h = 0
	}
	b = &c.l.boxes[bi]
	h := has_h ? spec_h : clamp_h(c, b, content_h + pb_h(b), cb_h)
	if b.kind == .Table { h = content_h }
	if .Root in b.flags { h = max(h, c.vp.y) }
	b.size = {w, h}
	if .List_Item in b.flags && b.marker_w != 0 { place_marker(c, bi) }
	if b.abs_first != NONE { if b.kind == .Grid { grid_abs(c, bi) } else { layout_abs_list(c, bi) } }
	if .Ifc in b.flags { layout_inline_abs(c, bi) }
	b = &c.l.boxes[bi]
	res.h = h
	if outer_open != nil { strut_merge(outer_open, contrib) }
	if independent || flow_ok {
		b.cache_ok = true
		b.cache_flow = !independent
		b.cache_in = key
		b.cache_h = h
		b.cache_end, b.cache_through, b.cache_contrib = res.end, res.through, contrib
	}
	return res
}

@(private)
strut_merge :: proc(s: ^Strut, o: Strut) {
	s.pos = max(s.pos, o.pos)
	s.neg = min(s.neg, o.neg)
}

// In-flow block-level children of a block container. Returns the content height, the trailing strut when the bottom
// margin collapses with the last child's, and whether every child let margins through.
@(private)
flow_blocks :: proc(c: ^Ctx, bi: i32, cw, ch_def: f32, fc: ^Flow_Ctx, collapse_top, collapse_bottom: bool) -> (h: f32, end: Strut, through: bool) {
	b := &c.l.boxes[bi]
	// a fieldset's rendered legend sits on its top border; the content starts below it
	if .Fieldset in b.flags {
		if lg := fieldset_legend(c.l, bi); lg != NONE {
			legend_h := place_legend(c, bi, lg, cw)
			h, end, through = flow_children(c, bi, cw, ch_def, fc, collapse_top, collapse_bottom, legend_h, lg)
			return h + legend_h, end, through
		}
	}
	return flow_children(c, bi, cw, ch_def, fc, collapse_top, collapse_bottom, 0, NONE)
}

// flow_blocks with the children's content starting `shift` below the content box top, child `skip` (a rendered legend,
// laid out apart) left out.
@(private)
flow_children :: proc(c: ^Ctx, bi: i32, cw, ch_def: f32, fc: ^Flow_Ctx, collapse_top, collapse_bottom: bool, shift: f32, skip: i32) -> (h: f32, end: Strut, through: bool) {
	b := &c.l.boxes[bi]
	cx, cy := content_x(b), content_y(b) + shift
	y: f32 = 0
	local: Strut
	open := collapse_top && fc.open != nil
	through = true
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next { prefetch_fields(c.l.boxes[ch].cs, LAYOUT_FIELDS) }
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
		k := &c.l.boxes[ch]
		strut := open ? fc.open : &local
		if ch == skip { continue }
		if .Abs in k.flags {
			k.static_ref = bi
			k.static_pos = {cx, cy + y + (open ? 0 : strut_value(local))}
			continue
		}
		if k.kind == .Inline { continue }
		ctop := content_top(fc)
		if .Float in k.flags {
			place_float(c, ch, bi, cw, fc, ctop + y + (open ? 0 : strut_value(local)))
			continue
		}
		if !pre_model(c, ch, k) { resolve_box_model(c, k, cw) }
		k = &c.l.boxes[ch]
		mt := k.margin[0]
		if k.auto_t { mt = 0; k.margin[0] = 0 }
		if k.auto_b { k.margin[2] = 0 }

		// clearance (§9.5.2): the border edge goes below the floats it clears; margins above no longer collapse with it
		probe := strut^
		strut_add(&probe, mt)
		hyp := (open ? fc.y : ctop + y) + strut_value(probe)
		floor := bfc_clear_floor(fc.bfc, k.cs.clear)
		cleared := floor > hyp
		ky: f32   // border-box top, relative to the content top
		child_fc: Flow_Ctx
		k_ct := collapses_top(k) && !cleared
		if cleared {
			if open { open = false }
			ctop = content_top(fc)
			ky = floor - ctop
			local = {}
		} else {
			strut_add(strut, mt)
		}

		avoid := .Bfc in k.flags && fc.bfc != nil && len(fc.bfc.floats) > 0
		ml0, mr0 := k.auto_l ? 0 : k.margin[3], k.auto_r ? 0 : k.margin[1]
		block_width(c, ch, cw, cw)
		k = &c.l.boxes[ch]
		w := k.size.x
		res: Result
		if .Bfc in k.flags {
			// a formatting context root does not overlap floats (§9.5): find a band wide enough, lower if needed
			top_bfc := cleared ? ctop + ky : (open ? fc.y + strut_value(fc.open^) : ctop + y + strut_value(local))
			x_off: f32 = 0
			if avoid {
				t := top_bfc
				for tries := 0; tries <= len(fc.bfc.floats) + 1; tries += 1 {
					l, r := bfc_band(fc.bfc, t, t + 1, fc.x, fc.x + cw)
					if r - l < cw - 0.01 {
						block_width(c, ch, cw, r - l)
						k = &c.l.boxes[ch]
						w = k.size.x
					}
					res = layout_contents(c, ch, w, ch_def, -1, nil)
					k = &c.l.boxes[ch]
					l2, r2 := bfc_band(fc.bfc, t, t + res.h + k.pre_h + mg_h(k), fc.x, fc.x + cw)
					if w + ml0 + mr0 <= r2 - l2 + 0.01 || (l2 == fc.x && r2 == fc.x + cw) {
						x_off = l2 - fc.x
						break
					}
					nb := bfc_next_bottom(fc.bfc, t)
					if nb == math.F32_MAX { break }
					t = nb
				}
				if t > top_bfc + 0.01 {
					if open { open = false }
					ctop = content_top(fc)
					ky = t - ctop
					cleared = true
					local = {}
				}
			} else {
				res = layout_contents(c, ch, w, ch_def, -1, nil)
			}
			k = &c.l.boxes[ch]
			k.pos.x = cx + x_off + k.margin[3]
		} else {
			if k_ct {
				child_fc = Flow_Ctx{bfc = fc.bfc, x = fc.x + k.margin[3] + content_x(k), y = open ? fc.y : ctop + y, open = strut}
			} else {
				base := cleared ? ctop + ky : (open ? fc.y + strut_value(fc.open^) : ctop + y + strut_value(local))
				child_fc = Flow_Ctx{bfc = fc.bfc, x = fc.x + k.margin[3] + content_x(k), y = base + content_y(k)}
			}
			res = layout_contents(c, ch, w, ch_def, -1, &child_fc)
			k = &c.l.boxes[ch]
			k.pos.x = cx + k.margin[3]
		}
		if !cleared {
			ky = open ? 0 : y + strut_value(local)
		}
		k.pos.y = cy + ky + k.pre_h
		if res.through && !cleared {
			strut_add(strut, k.margin[2])
			continue
		}
		open = false
		through = false
		y = ky + k.pre_h + res.h
		local = collapses_bottom(c, k) ? res.end : Strut{}
		strut_add(&local, k.margin[2])
	}
	if through && open { return 0, {}, true }
	if collapse_bottom && !through { return y, local, false }
	return max(y + strut_value(local), 0), {}, false
}

// First and last baselines of a block container whose children are blocks: those of its first / last in-flow child
// that has line boxes (CSS 2.1 §10.8.1, CSS Align §9).
@(private)
block_baselines :: proc(c: ^Ctx, bi: i32) {
	b := &c.l.boxes[bi]
	b.baseline, b.last_baseline = -1, -1
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
		k := &c.l.boxes[ch]
		if .Abs in k.flags || .Float in k.flags || k.kind == .Inline { continue }
		if k.baseline >= 0 {
			if b.baseline < 0 { b.baseline = k.pos.y + k.baseline }
		}
		if k.last_baseline >= 0 { b.last_baseline = k.pos.y + k.last_baseline } else if k.baseline >= 0 { b.last_baseline = k.pos.y + k.baseline }
	}
}

// Places a float (§9.5.1) whose top may not be above `min_y` (BFC coordinates). Its position is stored relative to the
// container `ci`'s border box.
@(private)
place_float :: proc(c: ^Ctx, fi, ci: i32, cw: f32, fc: ^Flow_Ctx, min_y: f32) {
	resolve_box_model(c, &c.l.boxes[fi], cw)
	k := &c.l.boxes[fi]
	if k.auto_l { k.margin[3] = 0 }
	if k.auto_r { k.margin[1] = 0 }
	if k.auto_t { k.margin[0] = 0 }
	if k.auto_b { k.margin[2] = 0 }
	w: f32
	if k.kind == .Replaced {
		w = replaced_size(c, fi, cw, -1).x
	} else if k.kind == .Table {
		w = table_width(c, fi, cw, cw - mg_w(k))
	} else if spec, ok := to_border_w(c, k, k.cs.width, cw); ok {
		w = clamp_w(c, k, spec, cw)
	} else {
		w = clamp_w(c, k, shrink_to_fit(c, fi, cw - mg_w(k)), cw)
	}
	res := layout_contents(c, fi, w, -1, -1, nil)
	k = &c.l.boxes[fi]
	mw, mh := w + mg_w(k), res.h + k.pre_h + mg_h(k)
	left := k.cs.float == .Left
	y := max(min_y, fc.bfc.last_top)
	y = max(y, bfc_clear_floor(fc.bfc, k.cs.clear))
	x: f32
	for tries := 0; tries <= len(fc.bfc.floats) + 1; tries += 1 {
		l, r := bfc_band(fc.bfc, y, y + mh, fc.x, fc.x + cw)
		if r - l >= mw - 0.01 || (l <= fc.x + 0.01 && r >= fc.x + cw - 0.01) {
			x = left ? l : r - mw
			break
		}
		nb := bfc_next_bottom(fc.bfc, y)
		if nb == math.F32_MAX { x = left ? l : r - mw; break }
		y = nb
	}
	append(&fc.bfc.floats, Float_Box{Rect{{x, y}, {x + mw, y + mh}}, left})
	fc.bfc.last_top = y
	fc.bfc.bottom = max(fc.bfc.bottom, y + mh)
	cb := &c.l.boxes[ci]
	ctop := content_top(fc)
	k.pos = {x - fc.x + content_x(cb) + k.margin[3], y - ctop + content_y(cb) + k.margin[0] + k.pre_h}
}

////////////////////////////////
// List markers

@(private)
first_baseline_in :: proc(c: ^Ctx, bi: i32) -> (f32, bool) {
	off: f32 = 0
	cur := bi
	for steps := 0; steps < 4096 && cur != NONE; steps += 1 {
		b := &c.l.boxes[cur]
		if .Ifc in b.flags && b.lines[1] > b.lines[0] {
			ln := &c.l.lines[b.lines[0]]
			return off + ln.y + ln.baseline, true
		}
		next := NONE
		for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
			k := &c.l.boxes[ch]
			if .Abs in k.flags || .Float in k.flags || k.kind == .Inline { continue }
			next = ch
			break
		}
		if next == NONE { break }
		off += c.l.boxes[next].pos.y
		cur = next
	}
	return 0, false
}

@(private)
place_marker :: proc(c: ^Ctx, bi: i32) {
	b := &c.l.boxes[bi]
	fi := &c.l.fonts[b.fi]
	mw: f32
	if b.marker == "" {
		mw = fi.size * 0.35
	} else {
		mw = measure(c, b.fi, b.marker)
	}
	b = &c.l.boxes[bi]
	gap := c.set.marker_gap * fi.size
	base, ok := first_baseline_in(c, bi)
	if !ok { base = content_y(b) + (fi.line_h - (fi.ascent + fi.descent)) * 0.5 + fi.ascent }
	b.marker_w = mw
	if is_rtl(b.cs) {
		b.marker_pos = {b.size.x - b.border[1] - b.padding[1] + gap, base}
	} else {
		b.marker_pos = {content_x(b) - gap - mw, base}
	}
}
