package layout

import "core:math"
import "wb:style"

// Flexbox (CSS Flexible Box Layout 1, §9 algorithm): order, flex base size and hypothetical main size with the automatic
// minimum size, line collection, flexible length resolution with iterative freezing, cross sizes with stretch and
// baseline alignment, align-content, justify-content (auto margins first), reverse directions and wrap-reverse.

@(private)
Flex_Item :: struct {
	box:       i32,
	base, hyp: f32,
	min_main, max_main: f32,
	main:      f32,
	frozen:    bool,
	violation: f32,
	cross:     f32,
	m:         [4]f32,     // margins: main start, main end, cross start, cross end (in flow order)
	auto_m:    [4]bool,
	grow, shrink: f32,
	stretch:   bool,
	baseline:  f32,        // from the cross-start margin edge, < 0: none
	pos_main, pos_cross: f32,
}

@(private)
Flex_Line :: struct { first, count: int, cross, pos, above: f32 }

@(private)
gap_px :: proc(c: ^Ctx, l: style.Length, base: f32) -> f32 {
	if l.kind == .Normal || l.kind == .Auto { return 0 }
	return max(px_of(c, l, max(base, 0)), 0)
}

@(private)
self_align :: proc(container, item: ^style.Computed) -> style.Content_Align {
	a := item.align_self
	if a == .Auto { a = container.align_items }
	if a == .Normal { a = .Stretch }
	return a
}

// Does the content of `k` depend on its height (so that stretching it needs a new layout)?
@(private)
depends_on_height :: proc(c: ^Ctx, ki: i32) -> bool {
	k := &c.l.boxes[ki]
	if k.kind == .Flex || k.kind == .Table { return true }
	if k.abs_first != NONE { return true }
	for ch := k.first; ch != NONE; ch = c.l.boxes[ch].next {
		cs := c.l.boxes[ch].cs
		if style.has_percent(cs.height) || style.has_percent(cs.min_height) || style.has_percent(cs.max_height) { return true }
		if c.l.boxes[ch].kind == .Inline { continue }
	}
	return false
}

// Imposes a border-box height on a laid out box, laying it out again only when its content depends on it.
@(private)
set_height :: proc(c: ^Ctx, ki: i32, w, cb_h, h: f32) {
	k := &c.l.boxes[ki]
	if math.abs(k.size.y - h) < 0.01 { return }
	if depends_on_height(c, ki) {
		layout_contents(c, ki, w, cb_h, h, nil)
		return
	}
	k.size.y = h
	k.cache_ok = true
	k.cache_in = {w, cb_h, h}
	k.cache_h = h
}

@(private)
to_border_main :: proc(c: ^Ctx, k: ^Box, l: style.Length, base: f32, row: bool) -> (f32, bool) {
	if row { return to_border_w(c, k, l, base) }
	return to_border_h(c, k, l, base)
}

// Width of an item of a column flex container: specified, stretched to the line, or fit-content.
@(private)
flex_col_width :: proc(c: ^Ctx, it: ^Flex_Item, k: ^Box, cw: f32) -> f32 {
	if spec, ok := to_border_w(c, k, k.cs.width, cw); ok { return clamp_w(c, k, spec, cw) }
	if it.stretch { return clamp_w(c, k, cw - it.m[2] - it.m[3], cw) }
	return clamp_w(c, k, shrink_to_fit(c, it.box, cw - it.m[2] - it.m[3]), cw)
}

@(private)
flex_items :: proc(c: ^Ctx, bi: i32) -> [dynamic]i32 {
	b := &c.l.boxes[bi]
	list := make([dynamic]i32, 0, 8, context.temp_allocator)
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
		k := &c.l.boxes[ch]
		if .Abs in k.flags {
			k.static_ref = bi
			k.static_pos = {content_x(b), content_y(b)}
			continue
		}
		append(&list, ch)
	}
	// `order`, stable
	for i in 1 ..< len(list) {
		x := list[i]
		o := c.l.boxes[x].cs.order
		j := i
		for j > 0 && c.l.boxes[list[j - 1]].cs.order > o { list[j] = list[j - 1]; j -= 1 }
		list[j] = x
	}
	return list
}

@(private)
flex_intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	cs := c.l.boxes[bi].cs
	row := cs.flex_direction == .Row || cs.flex_direction == .Row_Reverse
	items := flex_items(c, bi)
	mn, mx: f32
	gap := gap_px(c, row ? cs.column_gap : cs.row_gap, 0)
	for k, i in items {
		in2 := intrinsic(c, k)
		m := intrinsic_margins(c, k)
		if row {
			g := i > 0 ? gap : 0
			if cs.flex_wrap == .Nowrap { mn += in2[0] + m + g } else { mn = max(mn, in2[0] + m) }
			mx += in2[1] + m + g
		} else {
			mn = max(mn, in2[0] + m)
			mx = max(mx, in2[1] + m)
		}
	}
	return {mn, max(mx, mn)}
}

// Lays out the items of flex container `bi` (content width `cw`, definite content height `ch_def` or -1). Returns
// the content height.
@(private)
layout_flex :: proc(c: ^Ctx, bi: i32, cw, ch_def, cb_h: f32) -> f32 {
	b := &c.l.boxes[bi]
	cs := b.cs
	row := cs.flex_direction == .Row || cs.flex_direction == .Row_Reverse
	main_rev := cs.flex_direction == .Row_Reverse || cs.flex_direction == .Column_Reverse
	if row && is_rtl(cs) { main_rev = !main_rev }
	wrap := cs.flex_wrap != .Nowrap
	cross_rev := cs.flex_wrap == .Wrap_Reverse
	cx, cy := content_x(b), content_y(b)
	gap_main := gap_px(c, row ? cs.column_gap : cs.row_gap, row ? cw : ch_def)
	gap_cross := gap_px(c, row ? cs.row_gap : cs.column_gap, row ? ch_def : cw)
	main_avail := row ? cw : ch_def
	cross_avail := row ? ch_def : cw

	ids := flex_items(c, bi)
	items := make([]Flex_Item, len(ids), context.temp_allocator)
	for id, i in ids {
		it := &items[i]
		it.box = id
		resolve_box_model(c, &c.l.boxes[id], cw)
		k := &c.l.boxes[id]
		ks := k.cs
		// margins in flow order
		if row {
			s, e := 3, 1
			if main_rev { s, e = 1, 3 }
			it.m = {k.margin[s], k.margin[e], k.margin[0], k.margin[2]}
			it.auto_m = {s == 3 ? k.auto_l : k.auto_r, s == 3 ? k.auto_r : k.auto_l, k.auto_t, k.auto_b}
		} else {
			s, e := 0, 2
			if main_rev { s, e = 2, 0 }
			it.m = {k.margin[s], k.margin[e], k.margin[3], k.margin[1]}
			it.auto_m = {s == 0 ? k.auto_t : k.auto_b, s == 0 ? k.auto_b : k.auto_t, k.auto_l, k.auto_r}
		}
		for j in 0 ..< 4 { if it.auto_m[j] { it.m[j] = 0 } }
		it.grow, it.shrink = ks.flex_grow, ks.flex_shrink
		al := self_align(cs, ks)
		cross_auto := row ? ks.height.kind == .Auto : ks.width.kind == .Auto
		it.stretch = al == .Stretch && cross_auto && !it.auto_m[2] && !it.auto_m[3]

		// flex base size (§9.2 step 3)
		basis := ks.flex_basis
		if basis.kind == .Auto { basis = row ? ks.width : ks.height }
		got := false
		if basis.kind == .Px || basis.kind == .Percent || basis.kind == .Calc {
			v, ok := to_border_main(c, k, basis, main_avail, row)
			if ok { it.base, got = v, true }
		}
		content_main: f32 = -1
		if !got {
			if row {
				if k.kind == .Replaced {
					it.base = replaced_size(c, id, cw, cross_avail).x
				} else {
					#partial switch basis.kind {
					case .Min_Content: it.base = intrinsic(c, id)[0]
					case: it.base = intrinsic(c, id)[1]
					}
				}
			} else {
				w := flex_col_width(c, it, k, cw)
				r := layout_contents(c, id, w, -1, -1, nil)
				it.base = r.h
				content_main = r.h
			}
		}
		k = &c.l.boxes[id]
		// min / max main sizes, with the automatic minimum (§4.5)
		it.max_main = math.F32_MAX
		mxl := row ? ks.max_width : ks.max_height
		if mxl.kind != .None {
			if v, ok := to_border_main(c, k, mxl, main_avail, row); ok { it.max_main = v }
		}
		// the style engine computes `min-width: auto` to 0, so a zero minimum is taken as auto (see the report on Computed)
		mnl := row ? ks.min_width : ks.min_height
		explicit_min := false
		if v, ok := to_border_main(c, k, mnl, main_avail, row); ok {
			it.min_main = v
			explicit_min = mnl.kind != .Px || mnl.v != 0
		}
		scroll := ks.overflow_x != .Visible || ks.overflow_y != .Visible
		if !explicit_min && !scroll {
			// content-based minimum: the min-content size, never more than a specified size
			auto_min: f32
			if row {
				auto_min = k.kind == .Replaced ? it.base : intrinsic_content_min(c, id)
				if spec, ok := to_border_w(c, k, ks.width, main_avail); ok { auto_min = min(auto_min, spec) }
			} else {
				if content_main < 0 {
					w := flex_col_width(c, it, k, cw)
					content_main = layout_contents(c, id, w, -1, -1, nil).h
				}
				auto_min = content_main
				if spec, ok := to_border_h(c, k, ks.height, main_avail); ok { auto_min = min(auto_min, spec) }
			}
			it.min_main = max(it.min_main, min(auto_min, it.max_main))
		}
		k = &c.l.boxes[id]
		it.min_main = max(it.min_main, row ? pb_w(k) : pb_h(k))
		it.hyp = clamp(it.base, it.min_main, max(it.max_main, it.min_main))
	}

	// lines (§9.3)
	lines := make([dynamic]Flex_Line, 0, 2, context.temp_allocator)
	{
		ln := Flex_Line{first = 0}
		used: f32
		for &it, i in items {
			outer := it.hyp + it.m[0] + it.m[1]
			if wrap && main_avail >= 0 && ln.count > 0 && used + gap_main + outer > main_avail + 0.01 {
				append(&lines, ln)
				ln = Flex_Line{first = i}
				used = 0
			}
			used += (ln.count > 0 ? gap_main : 0) + outer
			ln.count += 1
		}
		if ln.count > 0 || len(lines) == 0 { append(&lines, ln) }
	}

	// flexible lengths (§9.7)
	content_main: f32 = 0
	for &ln in lines {
		li := items[ln.first:ln.first + ln.count]
		gaps := f32(max(ln.count - 1, 0)) * gap_main
		sum_outer: f32 = gaps
		for &it in li { sum_outer += it.hyp + it.m[0] + it.m[1] }
		avail := main_avail >= 0 ? main_avail : sum_outer
		grow := sum_outer < avail
		for &it in li {
			it.main = it.hyp
			it.frozen = (grow ? it.grow == 0 : it.shrink == 0) || (grow && it.base > it.hyp) || (!grow && it.base < it.hyp)
			if main_avail < 0 { it.frozen = true }
		}
		initial_free := avail - gaps
		for &it in li { initial_free -= (it.frozen ? it.main : it.base) + it.m[0] + it.m[1] }
		for iter := 0; iter <= len(li) + 1; iter += 1 {
			all := true
			for &it in li { if !it.frozen { all = false } }
			if all { break }
			free := avail - gaps
			factors: f32
			scaled: f32
			for &it in li {
				free -= (it.frozen ? it.main : it.base) + it.m[0] + it.m[1]
				if !it.frozen { factors += grow ? it.grow : it.shrink; scaled += it.shrink * it.base }
			}
			if factors < 1 && math.abs(initial_free * factors) < math.abs(free) { free = initial_free * factors }
			total: f32
			for &it in li {
				if it.frozen { continue }
				target := it.base
				if grow {
					if factors > 0 { target = it.base + free * it.grow / factors }
				} else if scaled > 0 {
					target = it.base + free * (it.shrink * it.base) / scaled
				}
				clamped := clamp(target, it.min_main, max(it.max_main, it.min_main))
				it.violation = clamped - target
				it.main = clamped
				total += it.violation
			}
			for &it in li {
				if it.frozen { continue }
				if math.abs(total) < 0.001 || (total > 0 && it.violation > 0) || (total < 0 && it.violation < 0) { it.frozen = true }
			}
		}
		used := gaps
		for &it in li { used += it.main + it.m[0] + it.m[1] }
		content_main = max(content_main, used)
	}
	main_size := main_avail >= 0 ? main_avail : content_main

	// cross sizes (§9.4)
	for &it in items {
		k := &c.l.boxes[it.box]
		if row {
			if spec, ok := to_border_h(c, k, k.cs.height, cross_avail); ok {
				h := clamp_h(c, k, spec, cross_avail)
				layout_contents(c, it.box, it.main, cross_avail, h, nil)
				it.cross = h
			} else {
				r := layout_contents(c, it.box, it.main, cross_avail, -1, nil)
				it.cross = r.h
			}
		} else {
			w := flex_col_width(c, &it, k, cw)
			layout_contents(c, it.box, w, main_avail, it.main, nil)
			it.cross = w
		}
		k = &c.l.boxes[it.box]
		it.baseline = -1
		if row && self_align(cs, k.cs) == .Baseline {
			it.baseline = it.m[2] + (k.baseline >= 0 ? k.baseline : it.cross)
		}
	}
	for &ln in lines {
		li := items[ln.first:ln.first + ln.count]
		above, below, outer: f32
		for &it in li {
			if it.baseline >= 0 {
				above = max(above, it.baseline)
				below = max(below, it.cross + it.m[2] + it.m[3] - it.baseline)
			} else {
				outer = max(outer, it.cross + it.m[2] + it.m[3])
			}
		}
		ln.cross = max(outer, above + below)
		ln.above = above
	}
	if len(lines) == 1 && cross_avail >= 0 { lines[0].cross = cross_avail }

	// align-content (§9.4 step 15 / CSS Align)
	{
		total := f32(max(len(lines) - 1, 0)) * gap_cross
		for &ln in lines { total += ln.cross }
		free := cross_avail >= 0 ? cross_avail - total : 0
		n := f32(len(lines))
		offset, between: f32
		ac := cs.align_content
		if len(lines) > 1 || !wrap {
			switch ac {
			case .Normal, .Stretch:
				if free > 0 && len(lines) > 1 { for &ln in lines { ln.cross += free / n } }
			case .Start, .Flex_Start, .Auto, .Baseline:
			case .End, .Flex_End: offset = free
			case .Center: offset = free * 0.5
			case .Space_Between: if free > 0 && n > 1 { between = free / (n - 1) }
			case .Space_Around: if free > 0 { between = free / n; offset = between * 0.5 } else { offset = free * 0.5 }
			case .Space_Evenly: if free > 0 { between = free / (n + 1); offset = between } else { offset = free * 0.5 }
			}
		} else if free > 0 && (ac == .Normal || ac == .Stretch) {
			for &ln in lines { ln.cross += free }
		}
		p := offset
		for &ln in lines {
			ln.pos = p
			p += ln.cross + gap_cross + between
		}
	}
	cross_size: f32
	for &ln in lines { cross_size = max(cross_size, ln.pos + ln.cross) }
	if cross_avail >= 0 { cross_size = cross_avail }

	// stretch, then positions in each line
	for &ln in lines {
		li := items[ln.first:ln.first + ln.count]
		for &it in li {
			if !it.stretch { continue }
			k := &c.l.boxes[it.box]
			target := ln.cross - it.m[2] - it.m[3]
			if row {
				target = clamp_h(c, k, target, cross_avail)
				if math.abs(target - it.cross) > 0.01 { set_height(c, it.box, it.main, cross_avail, target); it.cross = target }
			} else {
				target = clamp_w(c, k, target, cw)
				if math.abs(target - it.cross) > 0.01 {
					layout_contents(c, it.box, target, main_avail, it.main, nil)
					it.cross = target
				}
			}
		}
		// main axis: auto margins take free space first, then justify-content
		used := f32(max(ln.count - 1, 0)) * gap_main
		autos := 0
		for &it in li {
			used += it.main + it.m[0] + it.m[1]
			if it.auto_m[0] { autos += 1 }
			if it.auto_m[1] { autos += 1 }
		}
		free := main_size - used
		offset, between: f32
		if autos > 0 && free > 0 {
			share := free / f32(autos)
			for &it in li {
				if it.auto_m[0] { it.m[0] = share }
				if it.auto_m[1] { it.m[1] = share }
			}
			free = 0
		}
		n := f32(ln.count)
		switch cs.justify_content {
		case .Normal, .Start, .Flex_Start, .Stretch, .Auto, .Baseline:
		case .End, .Flex_End: offset = free
		case .Center: offset = free * 0.5
		case .Space_Between: if free > 0 && n > 1 { between = free / (n - 1) }
		case .Space_Around: if free > 0 { between = free / n; offset = between * 0.5 } else { offset = free * 0.5 }
		case .Space_Evenly: if free > 0 { between = free / (n + 1); offset = between } else { offset = free * 0.5 }
		}
		p := offset
		for &it in li {
			p += it.m[0]
			it.pos_main = p
			p += it.main + it.m[1] + gap_main + between
		}
		// cross axis
		for &it in li {
			k := &c.l.boxes[it.box]
			outer := it.cross + it.m[2] + it.m[3]
			free_c := ln.cross - outer
			pos: f32
			if it.auto_m[2] || it.auto_m[3] {
				if it.auto_m[2] && it.auto_m[3] { pos = max(free_c, 0) * 0.5 } else if it.auto_m[2] { pos = max(free_c, 0) }
				if it.auto_m[2] { it.m[2] = it.auto_m[3] ? max(free_c, 0) * 0.5 : max(free_c, 0) }
				if it.auto_m[3] { it.m[3] = it.auto_m[2] ? max(free_c, 0) * 0.5 : max(free_c, 0) }
				pos = it.m[2]
			} else {
				#partial switch self_align(cs, k.cs) {
				case .End, .Flex_End: pos = free_c + it.m[2]
				case .Center: pos = free_c * 0.5 + it.m[2]
				case .Baseline:
					pos = it.baseline >= 0 ? ln.above - it.baseline + it.m[2] : it.m[2]
				case: pos = it.m[2]
				}
			}
			if cross_rev { pos = ln.cross - pos - it.cross }
			it.pos_cross = (cross_rev ? cross_size - ln.pos - ln.cross : ln.pos) + pos
		}
	}

	// physical positions, used margins
	for &it in items {
		k := &c.l.boxes[it.box]
		mp := it.pos_main
		if main_rev { mp = main_size - mp - it.main }
		if row {
			k.pos = {cx + mp, cy + it.pos_cross}
			s, e := 3, 1
			if main_rev { s, e = 1, 3 }
			k.margin[s], k.margin[e], k.margin[0], k.margin[2] = it.m[0], it.m[1], it.m[2], it.m[3]
		} else {
			k.pos = {cx + it.pos_cross, cy + mp}
			s, e := 0, 2
			if main_rev { s, e = 2, 0 }
			k.margin[s], k.margin[e], k.margin[3], k.margin[1] = it.m[0], it.m[1], it.m[2], it.m[3]
		}
	}
	b = &c.l.boxes[bi]
	b.baseline, b.last_baseline = -1, -1
	if len(items) > 0 {
		k := &c.l.boxes[items[0].box]
		if k.baseline >= 0 { b.baseline = k.pos.y + k.baseline } else { b.baseline = k.pos.y + k.size.y }
		b.last_baseline = b.baseline
	}
	return row ? cross_size : main_size
}
