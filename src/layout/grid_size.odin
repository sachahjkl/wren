package layout

import "core:math"
import "core:slice"
import "wb:style"

// The grid track sizing algorithm (CSS Grid 1 §11, with the Level 2 corrections): initialize base sizes and growth
// limits, resolve intrinsic track sizes (items of span 1, then spanning items by increasing span, then items crossing
// flexible tracks; each through the space distribution of §11.5.1), maximize, expand flexible tracks ("find the size of
// an fr", definite and indefinite cases, min / max sizes of the container) and stretch auto tracks.
//
// Contributions are outer sizes. Columns use the items' min-content / max-content widths (intrinsic.odin); rows use the
// item heights at their final column widths (block sizes have a single content size). The minimum contribution follows
// the automatic minimum size (§6.6): the content-based minimum for an item with visible overflow spanning an `auto`
// minimum, never more than the area allows when every spanned track has a fixed maximum.

GRID_INF :: math.F32_MAX

@(private)
Grid_Constraint :: enum u8 { None, Min, Max }   // sizing the container under a min-content / max-content constraint

@(private)
Grid_Phase :: enum u8 { Intrinsic_Min, Content_Min, Max_Content_Min, Intrinsic_Max, Max_Content_Max }

@(private)
grid_min_of :: proc(c: ^Ctx, b: style.Track_Breadth, base: f32) -> (Grid_Min, f32) {
	switch b.kind {
	case .Auto, .Fr: return .Auto, 0
	case .Min_Content: return .Min_Content, 0
	case .Max_Content: return .Max_Content, 0
	case .Length: if v, ok := definite(c, b.len, base); ok { return .Fixed, max(v, 0) }
	}
	return .Auto, 0   // a percentage of an indefinite size behaves as auto
}

@(private)
grid_max_of :: proc(c: ^Ctx, b: style.Track_Breadth, base: f32) -> (Grid_Max, f32) {
	switch b.kind {
	case .Auto: return .Auto, 0
	case .Fr: return .Flex, max(b.fr, 0)
	case .Min_Content: return .Min_Content, 0
	case .Max_Content: return .Max_Content, 0
	case .Length: if v, ok := definite(c, b.len, base); ok { return .Fixed, max(v, 0) }
	}
	return .Auto, 0
}

// §11.4: sizing functions resolved against `base` (the content size of the axis, < 0: indefinite), base sizes and
// growth limits initialized.
@(private)
grid_init_tracks :: proc(c: ^Ctx, ax: ^Grid_Axis, base: f32) {
	for &t, i in ax.tracks {
		collapsed := t.collapsed
		t = Grid_Tr{collapsed = collapsed}
		if collapsed { t.min_k, t.max_k = .Fixed, .Fixed; continue }
		fn := grid_fn(ax, i32(i))
		if fn == nil {
			t.min_k, t.max_k = .Auto, .Auto
		} else {
			switch fn.kind {
			case .Breadth, .Minmax, .Repeat:
				t.min_k, t.min_v = grid_min_of(c, fn.min, base)
				t.max_k, t.max_v = grid_max_of(c, fn.max, base)
			case .Fit_Content:
				t.min_k = .Auto
				if v, ok := definite(c, fn.max.len, base); ok { t.max_k, t.max_v = .Fit, max(v, 0) } else { t.max_k = .Max_Content }
			}
		}
		t.base = t.min_k == .Fixed ? t.min_v : 0
		#partial switch t.max_k {
		case .Fixed: t.limit = t.max_v
		case .Flex: t.limit = t.base
		case: t.limit = GRID_INF
		}
		if t.limit < t.base { t.limit = t.base }
	}
}

////////////////////////////////
// Contributions

// Does the automatic minimum size of the item apply in this axis (§6.6)? Not for scroll containers, only when it spans
// an `auto` minimum, and not when it spans several tracks one of which is flexible.
@(private)
grid_auto_min_applies :: proc(c: ^Ctx, g: ^Grid, it: ^Grid_Item, axis: int) -> bool {
	cs := c.l.boxes[it.box].cs
	scroller :: proc(o: style.Overflow) -> bool { return o == .Hidden || o == .Scroll || o == .Auto }
	if scroller(cs.overflow_x) || scroller(cs.overflow_y) { return false }
	tr := g.ax[axis].tracks
	a, e := it.area[axis][0], it.area[axis][1]
	has_auto, has_flex := false, false
	for t in a ..< e {
		if tr[t].min_k == .Auto { has_auto = true }
		if tr[t].max_k == .Flex { has_flex = true }
	}
	return has_auto && !(e - a > 1 && has_flex)
}

// When every spanned track has a fixed maximum, a content-based minimum may not exceed the area they make.
@(private)
grid_fixed_clamp :: proc(g: ^Grid, it: ^Grid_Item, axis: int, v, margins: f32) -> f32 {
	ax := &g.ax[axis]
	a, e := it.area[axis][0], it.area[axis][1]
	sum: f32
	for t in a ..< e {
		if ax.tracks[t].max_k != .Fixed { return v }
		sum += ax.tracks[t].max_v
	}
	return min(v, sum + ax.gap * f32(e - a - 1) - margins)
}

// Border-box minimum width of an item: its min-width, or the automatic minimum.
@(private)
grid_minimum_w :: proc(c: ^Ctx, g: ^Grid, it: ^Grid_Item, margins: f32) -> f32 {
	k := &c.l.boxes[it.box]
	cs := k.cs
	pb := intrinsic_pb(c, k)
	if cs.min_width.kind != .Auto {
		#partial switch cs.min_width.kind {
		case .Px:
			v := cs.min_width.v * c.scale
			return cs.box_sizing == .Border_Box ? max(v, pb) : v + pb
		case .Min_Content, .Fit_Content: return intrinsic(c, it.box)[0]
		case .Max_Content: return intrinsic(c, it.box)[1]
		}
		return pb
	}
	if !grid_auto_min_applies(c, g, it, 0) { return pb }
	// the specified size suggestion (a fixed width) or the content size suggestion
	v := (cs.width.kind == .Px || k.kind == .Replaced) ? intrinsic(c, it.box)[0] : intrinsic_content_min(c, it.box)
	k = &c.l.boxes[it.box]
	if cs.max_width.kind == .Px {
		mx := cs.max_width.v * c.scale
		v = min(v, cs.box_sizing == .Border_Box ? max(mx, pb) : mx + pb)
	}
	return max(grid_fixed_clamp(g, it, 0, v, margins), pb)
}

// Border-box minimum height of an item (its outer part above the border box, table captions, included).
@(private)
grid_minimum_h :: proc(c: ^Ctx, g: ^Grid, it: ^Grid_Item, margins: f32) -> f32 {
	k := &c.l.boxes[it.box]
	cs := k.cs
	pb := pb_h(k)
	if cs.min_height.kind != .Auto {
		if v, ok := to_border_h(c, k, cs.min_height, -1); ok { return v + k.pre_h }
		return pb + k.pre_h
	}
	if !grid_auto_min_applies(c, g, it, 1) { return pb + k.pre_h }
	v: f32
	if spec, ok := to_border_h(c, k, cs.height, -1); ok { v = spec + k.pre_h } else { v = grid_item_height(c, g, it) }
	k = &c.l.boxes[it.box]
	if cs.max_height.kind != .None {
		if mx, ok := to_border_h(c, k, cs.max_height, -1); ok { v = min(v, mx + k.pre_h) }
	}
	return max(grid_fixed_clamp(g, it, 1, v, margins), pb + k.pre_h)
}

// An item's contribution to an axis: kind 0 min-content, 1 max-content, 2 minimum. Outer sizes, cached per sizing.
@(private)
grid_contrib :: proc(c: ^Ctx, g: ^Grid, it: ^Grid_Item, axis, kind: int) -> f32 {
	if it.contrib[axis][kind] >= 0 { return it.contrib[axis][kind] }
	v: f32
	if it.proxy {
		v = grid_contrib(c, it.src, &it.src.items[it.src_i], axis, kind) + it.extra[axis]
	} else if axis == 0 {
		m := intrinsic_margins(c, it.box)
		if kind < 2 { v = intrinsic(c, it.box)[kind] + m } else { v = grid_minimum_w(c, g, it, m) + m }
	} else {
		m := it.m[0] + it.m[2]
		if kind < 2 { v = grid_item_height(c, g, it) + m } else { v = grid_minimum_h(c, g, it, m) + m }
		v += it.shim
	}
	it.contrib[axis][kind] = v
	return v
}

// The limited min-content contribution: the min-content contribution capped by fixed maximums of the spanned tracks
// (fit-content() limits included), never below the minimum contribution.
@(private)
grid_limited_min :: proc(c: ^Ctx, g: ^Grid, it: ^Grid_Item, axis: int) -> f32 {
	v := grid_contrib(c, g, it, axis, 0)
	ax := &g.ax[axis]
	a, e := it.area[axis][0], it.area[axis][1]
	sum: f32
	capped := true
	for t in a ..< e {
		x := &ax.tracks[t]
		if x.max_k != .Fixed && x.max_k != .Fit { capped = false; break }
		sum += x.max_v
	}
	if capped { v = min(v, sum + ax.gap * f32(e - a - 1)) }
	return max(v, grid_contrib(c, g, it, axis, 2))
}

////////////////////////////////
// Space distribution (§11.5.1)

@(private)
grid_affected :: proc(x: ^Grid_Tr, ph: Grid_Phase, cons: Grid_Constraint, flex_only: bool) -> bool {
	if x.collapsed || (flex_only && x.max_k != .Flex) { return false }
	switch ph {
	case .Intrinsic_Min: return x.min_k != .Fixed
	case .Content_Min: return x.min_k == .Min_Content || x.min_k == .Max_Content
	case .Max_Content_Min: return x.min_k == .Max_Content || (x.min_k == .Auto && cons == .Max)
	case .Intrinsic_Max: return x.max_k == .Auto || x.max_k == .Min_Content || x.max_k == .Max_Content || x.max_k == .Fit
	case .Max_Content_Max: return x.max_k == .Auto || x.max_k == .Max_Content || x.max_k == .Fit
	}
	return false
}

// Tracks that take what is left once every affected track reached its limit. A fit-content() track counts as
// max-content until it reaches its limit.
@(private)
grid_beyond :: proc(x: ^Grid_Tr, ph: Grid_Phase) -> bool {
	fit_open := x.max_k == .Fit && x.base + x.inc < x.max_v
	#partial switch ph {
	case .Intrinsic_Min, .Content_Min:
		return x.max_k == .Auto || x.max_k == .Min_Content || x.max_k == .Max_Content || fit_open
	case .Max_Content_Min:
		return x.max_k == .Auto || x.max_k == .Max_Content || fit_open
	}
	return true
}

// How much more an affected size may grow while distributing up to limits.
@(private)
grid_cap :: proc(x: ^Grid_Tr, is_limit: bool) -> f32 {
	if !is_limit {
		lim := x.limit
		if x.max_k == .Fit { lim = min(lim, max(x.max_v, x.base)) }
		if lim == GRID_INF { return GRID_INF }
		return max(lim - x.base - x.inc, 0)
	}
	cur := x.limit == GRID_INF ? x.base : x.limit
	lim: f32
	switch {
	case x.limit != GRID_INF && !x.inf_grow: lim = x.limit
	case x.max_k == .Fit: lim = x.max_v
	case: return GRID_INF
	}
	return max(lim - cur - x.inc, 0)
}

// Shares `space` among the tracks of `tr` selected by `aff` (up to their limits) or `beyond` (without limit), equally or
// in proportion to their flex factors. Returns what could not be given.
@(private)
grid_spread :: proc(tr: []Grid_Tr, space: f32, is_limit, by_flex, up_to: bool) -> f32 {
	for &x in tr { x.frozen = !(up_to ? x.aff : x.beyond) }
	rem := space
	for iter := 0; rem > 0.0001 && iter <= len(tr) + 1; iter += 1 {
		n, wsum: f32
		for &x in tr { if !x.frozen { n += 1; wsum += x.max_v } }
		if n == 0 { break }
		use_w := by_flex && wsum > 0
		capped := false
		spent: f32
		if up_to {
			for &x in tr {
				if x.frozen { continue }
				share := use_w ? rem * x.max_v / wsum : rem / n
				if cp := grid_cap(&x, is_limit); cp <= share {
					x.inc += cp
					spent += cp
					x.frozen = true
					capped = true
				}
			}
		}
		if capped { rem -= spent; continue }
		for &x in tr {
			if !x.frozen { x.inc += use_w ? rem * x.max_v / wsum : rem / n }
		}
		rem = 0
	}
	return max(rem, 0)
}

// One step of §11.5 for a group of items: grows the base sizes (minimum phases) or growth limits (maximum phases) of the
// affected tracks so that the items' contributions fit.
@(private)
grid_distribute :: proc(c: ^Ctx, g: ^Grid, axis: int, group: []i32, ph: Grid_Phase, cons: Grid_Constraint, flex_only: bool) {
	ax := &g.ax[axis]
	tr := ax.tracks
	is_limit := ph >= .Intrinsic_Max
	touched := make([dynamic]i32, 0, 16, context.temp_allocator)
	kind := 2
	switch ph {
	case .Intrinsic_Min: kind = 2
	case .Content_Min, .Intrinsic_Max: kind = 0
	case .Max_Content_Min, .Max_Content_Max: kind = 1
	}
	for ii in group {
		it := &g.items[ii]
		a, e := it.area[axis][0], it.area[axis][1]
		naff := 0
		for t in a ..< e {
			x := &tr[t]
			x.aff = grid_affected(x, ph, cons, flex_only)
			x.inc = 0
			if !x.aff { continue }
			naff += 1
			if !x.touched { x.touched = true; x.planned = 0; append(&touched, t) }
		}
		if naff == 0 { continue }
		size := (ph == .Intrinsic_Min && cons != .None) ? grid_limited_min(c, g, it, axis) : grid_contrib(c, g, it, axis, kind)
		for t in a ..< e {
			x := &tr[t]
			size -= is_limit && x.limit != GRID_INF ? x.limit : x.base
		}
		size -= ax.gap * f32(e - a - 1)
		if size <= 0 { continue }
		size = grid_spread(tr[a:e], size, is_limit, flex_only, true)
		if size > 0.0001 {
			nb := 0
			for t in a ..< e {
				x := &tr[t]
				x.beyond = x.aff && grid_beyond(x, ph)
				if x.beyond { nb += 1 }
			}
			if nb == 0 { for t in a ..< e { tr[t].beyond = tr[t].aff } }
			grid_spread(tr[a:e], size, is_limit, flex_only, false)
		}
		for t in a ..< e {
			x := &tr[t]
			if x.aff && x.inc > x.planned { x.planned = x.inc }
		}
	}
	for t in touched {
		x := &tr[t]
		x.touched = false
		switch {
		case !is_limit: x.base += x.planned
		case x.limit == GRID_INF:
			x.limit = x.base + x.planned
			x.inf_grow = ph == .Intrinsic_Max   // may grow past it in the max-content step that follows
		case: x.limit += x.planned
		}
		if ph == .Max_Content_Max { x.inf_grow = false }
		x.planned = 0
	}
}

////////////////////////////////
// The algorithm

// "Find the size of an fr" (§11.7.1) over `tr`, with `space` to fill.
@(private)
grid_find_fr :: proc(tr: []Grid_Tr, space: f32) -> f32 {
	for &x in tr { x.frozen = x.max_k != .Flex }
	for _ in 0 ..= len(tr) {
		leftover := space
		flex_sum: f32
		for &x in tr { if x.frozen { leftover -= x.base } else { flex_sum += x.max_v } }
		hyp := leftover / max(flex_sum, 1)
		again := false
		for &x in tr {
			if !x.frozen && hyp * x.max_v < x.base { x.frozen = true; again = true }
		}
		if !again { return max(hyp, 0) }
	}
	return 0
}

// Distributes `free` to the base sizes of the tracks, equally, freezing them at their growth limits (§11.6).
@(private)
grid_grow_bases :: proc(tr: []Grid_Tr, free: f32) {
	for &x in tr { x.frozen = x.collapsed || x.base >= x.limit }
	rem := free
	for iter := 0; rem > 0.0001 && iter <= len(tr) + 1; iter += 1 {
		n: f32
		for &x in tr { if !x.frozen { n += 1 } }
		if n == 0 { break }
		share := rem / n
		capped := false
		spent: f32
		for &x in tr {
			if x.frozen || x.limit - x.base > share { continue }
			spent += x.limit - x.base
			x.base = x.limit
			x.frozen = true
			capped = true
		}
		if capped { rem -= spent; continue }
		for &x in tr { if !x.frozen { x.base += share } }
		rem = 0
	}
}

// Sizes the tracks of one axis. `avail` is the definite content size (< 0: indefinite), `cons` the constraint the
// container is sized under, `min_avail` / `max_avail` its content size bounds (< 0: none).
@(private)
grid_size_axis :: proc(c: ^Ctx, g: ^Grid, axis: int, avail: f32, cons: Grid_Constraint, min_avail, max_avail: f32) {
	ax := &g.ax[axis]
	grid_init_tracks(c, ax, cons == .None ? avail : -1)
	if ax.n == 0 { return }
	tr := ax.tracks
	grid_sync_subs(g, axis)

	// §11.5 step 2: items of span 1 not in a flexible track; collect the others
	Spanning :: struct { span: i32, item: i32 }
	multi := make([dynamic]Spanning, 0, 8, context.temp_allocator)
	flexy := make([dynamic]i32, 0, 8, context.temp_allocator)
	for &it, i in g.items {
		if !it.placed { continue }
		// a subgrid is sized through its items' proxies in its subgridded axes
		if it.proxy ? !it.axes[axis] : (it.sub != nil && it.axes[axis]) { continue }
		a, e := it.area[axis][0], it.area[axis][1]
		flex := false
		for t in a ..< e { if tr[t].max_k == .Flex { flex = true; break } }
		if flex { append(&flexy, i32(i)); continue }
		if e - a > 1 { append(&multi, Spanning{e - a, i32(i)}); continue }
		t := &tr[a]
		switch t.min_k {
		case .Fixed:
		case .Min_Content: t.base = max(t.base, grid_contrib(c, g, &it, axis, 0))
		case .Max_Content: t.base = max(t.base, grid_contrib(c, g, &it, axis, 1))
		case .Auto: t.base = max(t.base, cons != .None ? grid_limited_min(c, g, &it, axis) : grid_contrib(c, g, &it, axis, 2))
		}
		v: f32 = -1
		switch t.max_k {
		case .Fixed, .Flex:
		case .Min_Content: v = grid_contrib(c, g, &it, axis, 0)
		case .Max_Content, .Auto: v = grid_contrib(c, g, &it, axis, 1)
		case .Fit: v = min(grid_contrib(c, g, &it, axis, 1), t.max_v)
		}
		if v >= 0 { t.limit = t.limit == GRID_INF ? v : max(t.limit, v) }
	}
	for &t in tr { if t.limit != GRID_INF && t.limit < t.base { t.limit = t.base } }

	// step 3: spanning items, by increasing span
	if len(multi) > 0 {
		slice.sort_by(multi[:], proc(a, b: Spanning) -> bool { return a.span < b.span })
		group := make([dynamic]i32, 0, len(multi), context.temp_allocator)
		for i := 0; i < len(multi); {
			j := i
			clear(&group)
			for j < len(multi) && multi[j].span == multi[i].span { append(&group, multi[j].item); j += 1 }
			for ph in Grid_Phase {
				grid_distribute(c, g, axis, group[:], ph, cons, false)
				if ph == .Max_Content_Min {
					for &t in tr { if t.limit != GRID_INF && t.limit < t.base { t.limit = t.base } }
				}
			}
			i = j
		}
	}
	// step 4: items crossing flexible tracks, all together, into the flexible tracks only
	if len(flexy) > 0 {
		for ph in ([3]Grid_Phase{.Intrinsic_Min, .Content_Min, .Max_Content_Min}) { grid_distribute(c, g, axis, flexy[:], ph, cons, true) }
	}
	// step 5
	for &t in tr {
		if t.limit == GRID_INF || t.limit < t.base { t.limit = t.base }
		t.inf_grow = false
	}

	// maximize tracks (§11.6)
	switch {
	case cons == .Max || (cons == .None && avail < 0):
		before := grid_tracks_total(ax)
		saved: []f32
		if max_avail >= 0 {
			saved = make([]f32, len(tr), context.temp_allocator)
			for &t, i in tr { saved[i] = t.base }
		}
		for &t in tr { t.base = t.limit }
		if max_avail >= 0 && grid_tracks_total(ax) > max_avail {
			for &t, i in tr { t.base = saved[i] }
			grid_grow_bases(tr, max_avail - before)
		}
	case cons == .None:
		if free := avail - grid_tracks_total(ax); free > 0 { grid_grow_bases(tr, free) }
	}

	// expand flexible tracks (§11.7)
	has_flex := false
	for &t in tr { if t.max_k == .Flex { has_flex = true; break } }
	if has_flex && cons != .Min {
		nv: i32
		for &t in tr { if !t.collapsed { nv += 1 } }
		gaps := ax.gap * f32(max(nv - 1, 0))
		fr: f32
		if avail >= 0 && cons == .None {
			if avail - grid_tracks_total(ax) > 0 { fr = grid_find_fr(tr, avail - gaps) }
		} else {
			for &t in tr {
				if t.max_k == .Flex { fr = max(fr, t.max_v > 1 ? t.base / t.max_v : t.base) }
			}
			for ii in flexy {
				it := &g.items[ii]
				a, e := it.area[axis][0], it.area[axis][1]
				fr = max(fr, grid_find_fr(tr[a:e], grid_contrib(c, g, it, axis, 1) - ax.gap * f32(e - a - 1)))
			}
			// the container's min / max size bounds the result
			total := gaps
			for &t in tr {
				if t.collapsed { continue }
				total += t.max_k == .Flex ? max(t.base, fr * t.max_v) : t.base
			}
			if max_avail >= 0 && total > max_avail { fr = grid_find_fr(tr, max_avail - gaps) }
			if min_avail >= 0 && total < min_avail { fr = grid_find_fr(tr, min_avail - gaps) }
		}
		for &t in tr {
			if t.max_k == .Flex && fr * t.max_v > t.base { t.base = fr * t.max_v }
		}
	}

	// stretch auto tracks (§11.8)
	if cons == .None {
		cs := c.l.boxes[g.bi].cs
		al := axis == 0 ? cs.justify_content : cs.align_content
		size := avail >= 0 ? avail : min_avail
		if (al == .Normal || al == .Stretch) && size >= 0 {
			if free := size - grid_tracks_total(ax); free > 0 {
				n: f32
				for &t in tr { if t.max_k == .Auto && !t.collapsed { n += 1 } }
				if n > 0 {
					for &t in tr { if t.max_k == .Auto && !t.collapsed { t.base += free / n } }
				}
			}
		}
	}
}
