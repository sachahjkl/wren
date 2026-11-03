package layout

import "core:math"
import "core:slice"
import "wb:base"
import "wb:style"

// Multi-column layout (CSS Multicol 1, CSS Fragmentation 3).
//
// A multi-column container lays its content out in one strip as wide as a column, as high as it takes, with the block layout
// as it is. The strip is then cut: `gather_units` lists what must not be cut (lines, replaced boxes, what `break-inside:
// avoid` keeps whole...) and where breaks are forced or to be avoided, `place_units` finds the shift each of them takes
// so that it lands in one column at a given column height, without touching the boxes, and the height is found by
// bisection-free search: the smallest height at which the content fits the number of columns, from the height of the strip
// shared out, growing by what the first break that hurts lacked. `apply_shifts` then moves the boxes for that height: the
// strip is now the "flow", in which each column is a band of the column's height, and a box may lie across bands (what does not have to be whole does get cut).
//
// A container inside another's flow that would cross a column of the outer one is laid out again in rows: as many columns as it has in
// what is left of the outer column, then again in the next (Mc_Rows). Its columns hang from the outer column they show in.
//
// A column is a fragment (Mc_Frag): a band of the flow, and the translation that takes it where the column shows. Finishing makes one
// space per fragment (Space_Kind.Column) under a space of the flow (Space_Kind.Flow), which boxes inside point to; every display item
// in the flow space becomes one copy per fragment it lies in, clipped to the band (push_item). Hit testing and painting then have
// nothing to know. Queries map a rectangle through the fragments (flow_bounds, flow_rects).
//
// Spanners (column-span: all) are in the strip like any block, but with the container's width: they end a set of columns and
// are fragments of their own, as high as they are.

// Column boxes are this thick at least when the content is empty or the height would be 0 (a band of no height would never end).
MC_MIN_COLUMN_H :: 1
// How many heights the balancing tries: every try fixes a shortage of some break; a page reaches this only with thousands of breaks.
MC_BALANCE_MAX_TRIES :: 256
// What "unbounded" is for a band of the flow in the axes it does not cut (device px): more than any page, within what f32 sums hold.
FLOW_UNBOUNDED :: f32(1e7)
// How many rows of columns one container takes in the columns of those around it; how many times a container lays out what is inside
// again for the rows of containers inside it.
MC_ROWS_MAX :: 1024
MC_NEST_TRIES :: 8

// What the columns of the outer container leave a nested one: this much at first, then this much per outer column.
@(private)
Mc_Rows :: struct { first, h: f32 }

@(private)
Mc_Frag :: struct {
	flow_min, flow_max: f32,   // the band of the flow, along the block axis, from the container's border box (container's frame)
	dx, dy: f32,               // translation from the flow to where it shows (same frame)
	spanner: bool,
}

// The columns of a container, as its last layout found them. Logical, from its border box.
@(private)
Mc_Record :: struct {
	frags: [dynamic]Mc_Frag,
	rules: [dynamic]Rect,            // between columns with content, in the container's frame
	phys:  [2]i32,                   // its range of Layout.flow_frags (finish)
	apart: bool,                     // no two of those regions overlap (flow_bounds_add: a rect inside one is shown there alone)
	first_chain: f32,                // how high what must start it together is: less room than that and it starts in the next outer column
	outer_space, outer_clip: i32,    // the space and clip of the container's own content: for what is not in the flow
}

// The record of multi-column container `bi` (nil: none yet).
@(private)
mc_record :: #force_inline proc(l: ^Layout, bi: i32) -> ^Mc_Record {
	r := l.boxes[bi].mc
	return r == NONE ? nil : &l.mc_records[r]
}

// A fragment in layout coordinates, for the frame's pass over the display list and the queries.
Flow_Frag :: struct {
	region: Rect,   // of the flow: what is shown of it there
	shift:  Vec2,   // from the flow to where it shows
	space:  i32,
	clip:   i32,
	spanner: bool,
	show:   Vec2,   // where its start shows
}

////////////////////////////////
// How many columns

// Used column count and width (CSS Multicol 1 §3.4).
@(private)
columns_used :: proc(c: ^Ctx, cs: ^style.Computed, cw, gap: f32) -> (n: int, colw: f32) {
	count := int(cs.column_count)
	has_w := cs.column_width.kind == .Px
	w := has_w ? max(cs.column_width.v * c.scale, 1) : 0
	switch {
	case count > 0 && !has_w:
		n = count
		colw = max((cw - f32(n - 1) * gap) / f32(n), 0)
	case count == 0 && has_w:
		n = max(int(math.floor((cw + gap) / (w + gap))), 1)
		colw = (cw + gap) / f32(n) - gap
	case count > 0 && has_w:
		n = min(count, max(int(math.floor((cw + gap) / (w + gap))), 1))
		colw = (cw + gap) / f32(n) - gap
	case:
		n = 1
		colw = cw
	}
	return n, max(colw, 0)
}

@(private)
column_gap_px :: proc(c: ^Ctx, cs: ^style.Computed, cw: f32) -> f32 {
	#partial switch cs.column_gap.kind {
	case .Px, .Percent, .Calc: return max(px_of(c, cs.column_gap, cw), 0)
	}
	return cs.font_size * c.scale   // normal: 1em
}

// The intrinsic sizes of a multi-column container from those of its content (without border and padding).
@(private)
multicol_intrinsic :: proc(c: ^Ctx, b: ^Box, res: [2]f32, pb: f32) -> [2]f32 {
	cs := b.cs
	gap := column_gap_px(c, cs, 0)
	mn, mx := res[0] - pb, res[1] - pb
	w := cs.column_width.kind == .Px ? cs.column_width.v * c.scale : 0
	n := f32(max(cs.column_count, 1))
	if cs.column_count == 0 {
		// column-width alone: as many as fit; one is what it asks for at least
		return {min(max(mn, w), max(mn, w)) + pb, max(mx, w) + pb}
	}
	col_min, col_max := mn, mx
	if w > 0 { col_min, col_max = max(mn, min(w, mn)), max(mx, w) }
	if w > 0 { col_min = max(mn, 0) }
	return {n * col_min + (n - 1) * gap + pb, n * col_max + (n - 1) * gap + pb}
}

////////////////////////////////
// What must not be cut

@(private)
Unit :: struct {
	y0, y1: f32,        // in the strip
	forced: bool,       // a break comes before it
	avoid:  bool,       // no break before it, if it can be helped
	spanner: i32,       // a spanner (NONE: none)
	nested: i32,        // a nested container, whole (NONE: none)
	trunc:  f32,        // margins above it: what a break there takes away
}

@(private)
Gather :: struct {
	c:      ^Ctx,
	units:  [dynamic]Unit,
	force_next, avoid_next: bool,
	top_ext: f32,       // the start of the box whose border and padding open before the next unit, or inf
	trunc_next: f32,
	last_end: f32,      // where the last box or line ended in the strip: what is between it and the next is margins
}

@(private)
is_monolithic :: proc(l: ^Layout, k: ^Box) -> bool {
	if k.kind == .Replaced || .Atomic in k.flags || .Float in k.flags || .Transformed in k.flags { return true }
	if k.kind == .Row { return true }
	if .Clips in k.flags && .Propagated not_in k.flags { return true }
	if .Multicol in k.fx || .Spanner in k.fx { return true }
	if .Frame_Root in k.fx { return true }
	if .Size in k.cs.contain { return true }   // (CSS Contain 2 §3.1)
	if k.parent != NONE {
		pk := l.boxes[k.parent].kind
		if pk == .Flex || pk == .Grid { return true }
	}
	return style.break_inside_avoid(k.cs.break_inside)
}

@(private)
unit_add :: proc(g: ^Gather, y0, y1: f32, spanner: i32 = NONE) {
	u := Unit{y0 = min(y0, g.top_ext), y1 = y1, forced = g.force_next, avoid = g.avoid_next, spanner = spanner, nested = NONE, trunc = g.trunc_next}
	append(&g.units, u)
	g.force_next, g.avoid_next = false, false
	g.top_ext = math.F32_MAX
	g.trunc_next = 0
	g.last_end = max(g.last_end, y1)
}

@(private)
gather_ifc :: proc(g: ^Gather, bi: i32, top: f32) {
	l := g.c.l
	b := &l.boxes[bi]
	n := int(b.lines[1] - b.lines[0])
	orphans, widows := int(b.cs.orphans), int(b.cs.widows)
	for li in 0 ..< n {
		ln := &l.lines[int(b.lines[0]) + li]
		if li > 0 && (li < orphans || n - li < widows) { g.avoid_next = true }
		unit_add(g, top + ln.y, top + ln.y + ln.h)
	}
}

// Boxes of `bi` in tree order, and the lines of an inline formatting context among them. `top`: where `bi` is in the strip.
@(private)
gather_box :: proc(g: ^Gather, bi: i32, top: f32) {
	l := g.c.l
	b := &l.boxes[bi]
	if !stack_ok(g.c) { return }
	if .Ifc in b.flags { gather_ifc(g, bi, top) }
	// non-block containers: what is side by side goes together
	side_by_side := b.kind == .Flex || b.kind == .Grid
	if side_by_side {
		iv := make([dynamic][2]f32, 0, 8, context.temp_allocator)
		for ch := b.first; ch != NONE; ch = l.boxes[ch].next {
			k := &l.boxes[ch]
			if .Abs in k.flags { continue }
			append(&iv, [2]f32{top + k.pos.y - k.margin[0], top + k.pos.y + k.size.y + k.margin[2]})
		}
		slice.sort_by(iv[:], proc(a, b: [2]f32) -> bool { return a[0] < b[0] })
		i := 0
		for i < len(iv) {
			lo, hi := iv[i][0], iv[i][1]
			j := i + 1
			for j < len(iv) && iv[j][0] < hi { hi = max(hi, iv[j][1]); j += 1 }
			unit_add(g, lo, hi)
			i = j
		}
		return
	}
	for ch := b.first; ch != NONE; ch = l.boxes[ch].next { gather_child(g, ch, bi, top) }
}

@(private)
gather_child :: proc(g: ^Gather, ch, bi: i32, top: f32) {
	l := g.c.l
	k := &l.boxes[ch]
	if .Abs in k.flags { return }
	if k.kind == .Inline {
		// (a block inside an inline box)
		for x := k.first; x != NONE; x = l.boxes[x].next { gather_child(g, x, bi, top) }
		return
	}
	if .Atomic in k.flags { return }   // in its line
	if .Float in k.flags {
		unit_add(g, top + k.pos.y - k.margin[0], top + k.pos.y + k.size.y + k.margin[2])
		return
	}
	ktop := top + k.pos.y
	cs := k.cs
	before, after := cs.break_before, cs.break_after
	if style.break_is_forced(before) {
		g.force_next = true
		// a forced break with nothing to carry it: a unit of its own (margins kept: only unforced breaks truncate them)
		unit_add(g, ktop - k.margin[0], ktop - k.margin[0])
	} else if style.break_is_avoid(before) {
		g.avoid_next = true
	}
	if .Spanner in k.fx {
		g.top_ext = math.F32_MAX   // (the border and padding of its parent stay in the columns above)
		unit_add(g, ktop - k.margin[0], ktop + k.size.y + k.margin[2], ch)
	} else if .Multicol in k.fx && ch in g.c.mc_rows {
		// in rows made for the columns around it: it lies across them as it is
		g.last_end = max(g.last_end, ktop + k.size.y)
	} else if is_monolithic(l, k) {
		g.trunc_next = max(g.trunc_next, ktop - g.last_end)
		unit_add(g, ktop, ktop + k.size.y)
		if .Multicol in k.fx && ch not_in g.c.mc_whole { g.units[len(g.units) - 1].nested = ch }
	} else {
		g.trunc_next = max(g.trunc_next, ktop - g.last_end)
		// border and padding do not leave their first line: at the head of a column they go with it
		if content_y(k) > 0 { g.top_ext = min(g.top_ext, ktop) }
		g.last_end = max(g.last_end, ktop + content_y(k))
		gather_box(g, ch, ktop)
		g.top_ext = math.F32_MAX
		// (and a horizontal scroll bar its last)
		if k.border[2] + k.gutter[2] + k.padding[2] > 0 && len(g.units) > 0 {
			last := &g.units[len(g.units) - 1]
			if last.spanner == NONE { last.y1 = max(last.y1, ktop + k.size.y) }
		}
		g.last_end = max(g.last_end, ktop + k.size.y)
	}
	if style.break_is_forced(after) { g.force_next = true } else if style.break_is_avoid(after) { g.avoid_next = true }
}

////////////////////////////////
// Where a column height sends them

// From this y of the strip on, the flow is this far from it.
@(private)
Shift :: struct { y, by: f32 }

// `shift`: the flow position of `y` is y + by of the last entry at or before it; for the end of something, strictly before it.
@(private)
shift_at :: proc(shifts: []Shift, y: f32) -> f32 {
	lo, hi := 0, len(shifts)
	for lo < hi {
		m := (lo + hi) / 2
		if shifts[m].y <= y { lo = m + 1 } else { hi = m }
	}
	return lo > 0 ? shifts[lo - 1].by : 0
}

@(private)
shift_before :: proc(shifts: []Shift, y: f32) -> f32 {
	lo, hi := 0, len(shifts)
	for lo < hi {
		m := (lo + hi) / 2
		if shifts[m].y < y { lo = m + 1 } else { hi = m }
	}
	return lo > 0 ? shifts[lo - 1].by : 0
}

@(private)
Placed :: struct {
	columns:  int,    // columns the set takes
	shortage: f32,    // the least more height that would have avoided a break that was not forced (0: none)
	too_tall: f32,    // the most something that must stay whole is taller than a column by
	end:      f32,    // where the set ends in the flow
}

// Sends the units of one set of columns in columns of height `h` starting at flow `start` of the strip position `s0`. The
// shifts it finds go to `out` when given.
@(private)
place_units :: proc(units: []Unit, s0, s1, start, h: f32, base_shift: f32, out: ^[dynamic]Shift) -> Placed {
	shift := base_shift
	col_start := start
	col_end := start + h
	col := 0
	shortage: f32 = 0
	too_tall: f32 = 0
	prev_end := start
	note :: proc(out: ^[dynamic]Shift, y, by: f32) { if out != nil { append(out, Shift{y, by}) } }
	i := 0
	for i < len(units) {
		u := units[i]
		y0 := u.y0 + shift
		if u.forced {
			if y0 > col_start + 0.001 || prev_end > col_start + 0.001 {
				for col_end <= y0 { col_start, col_end = col_end, col_end + h; col += 1 }
				col_start, col_end = col_end, col_end + h
				col += 1
				shift += col_start - y0
				note(out, u.y0, shift)
				y0 = col_start
			}
		} else {
			for y0 >= col_end { col_start, col_end = col_end, col_end + h; col += 1 }
			// the margins above what starts a column are gone (CSS Fragmentation 3 §5.2)
			if col > 0 && u.trunc > 0 && y0 > col_start && y0 - u.trunc <= col_start + 0.001 && prev_end <= col_start + 0.001 {
				shift -= y0 - col_start
				note(out, u.y0, shift)
				y0 = col_start
			}
			// a nested container is not pushed: where it crosses a column it goes in rows (layout_multicol)
			if u.nested != NONE {
				prev_end = max(prev_end, u.y1 + shift)
				i += 1
				continue
			}
			// what stays together (the chain of units that avoid a break before them), when it can
			e := i
			for e + 1 < len(units) && units[e + 1].avoid && !units[e + 1].forced { e += 1 }
			chain_h := units[e].y1 - u.y0
			last := chain_h <= h ? e : i
			y1 := units[last].y1 + shift
			if y1 > col_end + 0.001 && y0 > col_start + 0.001 {
				lack := y1 - col_end
				if shortage == 0 || lack < shortage { shortage = lack }
				col_start, col_end = col_end, col_end + h
				col += 1
				shift += col_start - y0
				note(out, u.y0, shift)
				y0 = col_start
			} else if y1 > col_end + 0.001 {
				// taller than the column
				lack := y1 - col_end
				if shortage == 0 || lack < shortage { shortage = lack }
				too_tall = max(too_tall, lack)
			}
			// (the chain's units are placed one by one: no break comes inside it while it fits)
			if last > i {
				for k in i + 1 ..= last { prev_end = max(prev_end, units[k].y1 + shift) }
				for y1 > col_end + 0.001 { col_start, col_end = col_end, col_end + h; col += 1 }
				prev_end = max(prev_end, u.y1 + shift)
				i = last + 1
				continue
			}
		}
		prev_end = max(prev_end, u.y1 + shift)
		for prev_end > col_end + 0.001 && h > 0 && i + 1 < len(units) && units[i + 1].y0 + shift >= col_end { col_start, col_end = col_end, col_end + h; col += 1 }
		i += 1
	}
	flow_end := s1 + shift
	if prev_end > flow_end { flow_end = prev_end }
	cols := col + 1
	if flow_end > start { cols = max(cols, int(math.ceil((flow_end - start - 0.001) / h))) }
	return Placed{columns = max(cols, 1), shortage = shortage, too_tall = too_tall, end = flow_end}
}

// How many parts forced breaks make of a set of columns, and the height of the highest in the strip.
@(private)
forced_parts :: proc(units: []Unit, s0, s1: f32) -> (parts: int, highest: f32) {
	parts = 1
	start := s0
	for &u in units {
		if !u.forced || u.y0 <= start + 0.001 { continue }
		highest = max(highest, u.y0 - start)
		start = u.y0
		parts += 1
	}
	return parts, max(highest, s1 - start)
}

// The height columns take: the balancing of a set of columns (or `room`, all of it, when they fill it).
@(private)
mc_column_height :: proc(units: []Unit, s0, s1, flow_start, flow_shift: f32, n: int, room: f32, fill: bool) -> f32 {
	if fill { return max(room, MC_MIN_COLUMN_H) }
	h := max(math.ceil((s1 - s0) / f32(n)), MC_MIN_COLUMN_H)
	// forced breaks that use up the columns: as high as the highest of what lies between them, and the rest overflows
	parts, highest := forced_parts(units, s0, s1)
	forced_out := parts >= n
	if forced_out { h = max(highest, MC_MIN_COLUMN_H) }
	if room >= 0 && h > room { h = max(room, MC_MIN_COLUMN_H) }
	for _ in 0 ..< MC_BALANCE_MAX_TRIES {
		p := place_units(units, s0, s1, flow_start, h, flow_shift, nil)
		if p.columns <= n && p.too_tall <= 0 { break }
		if room >= 0 && h >= room { break }
		if p.columns <= n {
			// fits, but what must stay whole is cut
			h += max(p.too_tall, 0.01)
			if room >= 0 && h > room { h = room }
			continue
		}
		if forced_out && p.shortage <= 0 { break }
		grow := p.shortage
		// nothing lacks (a forced break too many, or cut content): what is left over, shared out
		over := p.end - (flow_start + h * f32(n))
		if over > 0 { grow = grow > 0 ? min(grow, max(over / f32(n), 1)) : max(over / f32(n), 1) }
		if grow <= 0 { break }
		h += max(grow, 0.01)
		if room >= 0 && h > room { h = room }
	}
	return h
}

// The fragments, and the rules between them, of `cols` columns of height `h` from `flow_start`, showing from `visual_y`.
@(private)
mc_add_columns :: proc(c: ^Ctx, rec: ^Mc_Record, cs: ^style.Computed, cols: int, h, flow_start, visual_y, cw, colw, gap, cx: f32, rule_h: f32 = -1) {
	rtl := is_rtl(cs)
	for i in 0 ..< cols {
		x := rtl ? cw - colw - f32(i) * (colw + gap) : f32(i) * (colw + gap)
		fmin := flow_start + f32(i) * h
		f := Mc_Frag{flow_min = fmin, flow_max = fmin + h, dx = x, dy = visual_y - fmin}
		if len(rec.frags) == 0 { f.flow_min = -FLOW_UNBOUNDED }
		append(&rec.frags, f)
		if i > 0 && cs.column_rule_width > 0 {
			rx := rtl ? x + colw + gap * 0.5 : x - gap * 0.5
			w := cs.column_rule_width * c.scale
			append(&rec.rules, Rect{{cx + rx - w * 0.5, visual_y}, {cx + rx + w * 0.5, visual_y + (rule_h >= 0 ? rule_h : h)}})
		}
	}
}

////////////////////////////////
// The layout

// Whether a box of this style takes part in `column-span: all`: an in-flow block.
@(private)
can_span :: #force_inline proc(k: ^Box) -> bool {
	return k.kind != .Inline && k.cs != nil && k.cs.column_span == .All && k.flags & {.Abs, .Float, .Atomic, .Block_In_Inline} == {}
}

// The multi-column container whose spanner box `bi` is, by the block path up to it (CSS Multicol 1 §6: `column-span` has no effect
// otherwise); NONE: it is none. Known when boxes are made, for what is contained in it, as mark_flow knows it for layout.
@(private)
spanner_container :: proc(l: ^Layout, bi: i32) -> i32 {
	if !can_span(&l.boxes[bi]) { return NONE }
	for p := l.boxes[bi].parent; p != NONE; p = l.boxes[p].parent {
		k := &l.boxes[p]
		if .Multicol in k.fx { return p }
		if k.kind != .Block || .Bfc in k.flags { return NONE }
	}
	return NONE
}

// The element of the container `node` is a spanner of (NIL: it is not one).
spanner_container_of :: proc(l: ^Layout, node: base.Handle) -> base.Handle {
	bi := box_index(l, node)
	if bi == NONE { return base.NIL_HANDLE }
	if mc := spanner_container(l, bi); mc != NONE { return l.boxes[mc].node }
	return base.NIL_HANDLE
}

// Boxes in the flow: marked, their caches dropped (what lies in the strip is moved by apply_shifts: a cached box would be moved
// again), and which are spanners.
@(private)
mark_flow :: proc(c: ^Ctx, container, x: i32, block_path: bool) {
	l := c.l
	for ch := l.boxes[x].first; ch != NONE; ch = l.boxes[ch].next {
		k := &l.boxes[ch]
		if .Dead in k.flags { continue }
		if .Abs in k.flags && (k.cb == container || !box_inside(l, k.cb, container)) {
			k.fx -= {.In_Flow}
			continue
		}
		k.fx += {.In_Flow}
		k.cache_ok = false
		k.fx -= {.Spanner}
		if block_path && can_span(k) {
			k.fx += {.Spanner}
			k.flags += {.Bfc}
		}
		path := block_path && k.kind == .Block && .Bfc not_in k.flags && .Multicol not_in k.fx && .Spanner not_in k.fx
		mark_flow(c, container, ch, path)
	}
}

// The flows of every container, marked as their layout marks them (outer containers first: a full pass makes a parent
// before its children), before the layout threads start: they read the boxes mark_flow writes.
@(private)
flows_mark :: proc(c: ^Ctx) {
	l := c.l
	for &b, i in l.boxes {
		if .Multicol in b.fx && .Dead not_in b.flags { mark_flow(c, i32(i), i32(i), true) }
	}
}

// Moves what is inside `bi` (at `top` in the strip, now at `new_top` in the flow).
@(private)
apply_shifts :: proc(c: ^Ctx, bi: i32, top, new_top: f32, shifts: []Shift) {
	l := c.l
	b := &l.boxes[bi]
	if !stack_ok(c) { return }
	if .List_Item in b.flags && b.marker_w != 0 {
		s := top + b.marker_pos.y
		b.marker_pos.y = s + shift_at(shifts, s) - new_top
	}
	if .Ifc in b.flags && b.lines[1] > b.lines[0] {
		for li in b.lines[0] ..< b.lines[1] {
			ln := &l.lines[li]
			s := top + ln.y
			d := (s + shift_at(shifts, s) - new_top) - ln.y
			if d == 0 { continue }
			ln.y += d
			for fk in ln.frags[0] ..< ln.frags[1] {
				f := &l.frags[fk]
				f.y += d
				f.baseline += d
				if f.kind == .Atomic { l.boxes[f.box].pos.y += d }
			}
		}
		ifc_settle(c, bi, b.lines)
	}
	for ch := b.first; ch != NONE; ch = l.boxes[ch].next { apply_child(c, ch, top, new_top, shifts) }
	if .Ifc not_in b.flags { block_baselines_keep(c, bi) }
}

@(private)
block_baselines_keep :: proc(c: ^Ctx, bi: i32) {
	b := &c.l.boxes[bi]
	if b.kind == .Block || b.kind == .Cell || b.kind == .Caption { block_baselines(c, bi) }
}

@(private)
apply_child :: proc(c: ^Ctx, ch: i32, top, new_top: f32, shifts: []Shift) {
	l := c.l
	k := &l.boxes[ch]
	if .Abs in k.flags { return }
	if k.kind == .Inline {
		for x := k.first; x != NONE; x = l.boxes[x].next { apply_child(c, x, top, new_top, shifts) }
		return
	}
	if .Atomic in k.flags { return }
	s := top + k.pos.y
	nt := s + shift_at(shifts, s)
	old_h := k.size.y
	k.pos.y = nt - new_top
	if is_monolithic(l, k) { return }
	apply_shifts(c, ch, s, nt, shifts)
	k = &l.boxes[ch]
	if k.cs.height.kind == .Auto && k.kind != .Row {
		bottom := s + old_h
		k.size.y = max(bottom + shift_before(shifts, bottom) - nt, 0)
	}
}

// Lays the content of container `bi` out in columns, returns the height of its content box. `cw`: its content width; `ch_def`:
// its content height when definite (else < 0).
@(private)
layout_multicol :: proc(c: ^Ctx, bi: i32, cw, ch_def: f32, fc: ^Flow_Ctx) -> f32 {
	l := c.l
	b := &l.boxes[bi]
	cs := b.cs
	gap := column_gap_px(c, cs, cw)
	n, colw := columns_used(c, cs, cw, gap)

	if c.pre == nil { mark_flow(c, bi, bi, true) }   // (else marked before the threads started: flows_mark)
	saved_full := c.mc_full_w
	c.mc_full_w = cw
	strip_h: f32
	if .Ifc in b.flags {
		h, _, trail := layout_ifc(c, bi, colw, fc, ch_def)
		strip_h = h + trail
	} else {
		h, _, _ := flow_blocks(c, bi, colw, ch_def, fc, false, false)
		strip_h = h
	}
	if fc.bfc != nil && len(fc.bfc.floats) > 0 { strip_h = max(strip_h, bfc_bottom(fc.bfc)) }
	c.mc_full_w = saved_full
	// (after the content: a container inside adds to the table)
	if l.boxes[bi].mc == NONE { l.boxes[bi].mc = i32(len(l.mc_records)); append(&l.mc_records, Mc_Record{}) }
	rec := mc_record(l, bi)
	clear(&rec.frags)
	clear(&rec.rules)
	b = &l.boxes[bi]
	cs = b.cs
	cy := content_y(b)
	cx := content_x(b)

	g := Gather{c = c, units = make([dynamic]Unit, 0, 64, context.temp_allocator), top_ext = math.F32_MAX, last_end = cy}
	gather_box(&g, bi, 0)

	// the height of the columns that can be taken as a limit
	limit: f32 = -1
	if ch_def >= 0 {
		limit = ch_def
	} else if mx, ok := to_border_h(c, b, cs.max_height, -1); ok && cs.max_height.kind != .None {
		limit = max(mx - pb_h(b), 0)
	}
	// (columns balanced around a nested container stay around it whole: only a given height cuts it)
	rec.first_chain = 0
	// (a first unit lower than the start: what is above it, an empty box, can be cut, and starts the container anywhere)
	if len(g.units) > 0 && g.units[0].y0 <= cy + 0.001 {
		e := 0
		for e + 1 < len(g.units) && g.units[e + 1].avoid && !g.units[e + 1].forced { e += 1 }
		rec.first_chain = g.units[e].y1 - g.units[0].y0
	}

	shifts := make([dynamic]Shift, 0, 32, context.temp_allocator)
	visual_y := cy
	strip_end := cy + strip_h
	set_start := cy        // in the strip
	flow_shift: f32 = 0    // what the strip has moved so far in the flow
	total_used: int = 0
	u0 := 0
	// inside another container, in what its columns leave
	rows, has_rows := c.mc_rows[bi]
	row_room := rows.first
	for {
		// the units of this set, up to the next spanner
		u1 := u0
		for u1 < len(g.units) && g.units[u1].spanner == NONE { u1 += 1 }
		set_units := g.units[u0:u1]
		set_end := u1 < len(g.units) ? g.units[u1].y0 : strip_end
		has_spanner := u1 < len(g.units)
		// (a set with no content and nothing but its spanners makes no column)
		content := set_end - set_start
		empty_set := len(set_units) == 0 && content <= 0.001
		if !empty_set && has_rows {
			// rows of columns: all of what the outer column leaves, as long as there is more
			us := set_units
			s, fs, sh := set_start, set_start + flow_shift, flow_shift
			for _ in 0 ..< MC_ROWS_MAX {
				if row_room <= 0.01 { row_room = rows.h }
				room := row_room
				if limit >= 0 { room = min(room, max(limit - (visual_y - cy), MC_MIN_COLUMN_H)) }
				fill := cs.column_fill == .Auto && limit >= 0 && !has_spanner
				h := mc_column_height(us, s, set_end, fs, sh, n, room, fill)
				p := place_units(us, s, set_end, fs, h, sh, nil)
				if p.columns <= n && (p.too_tall <= 0 || room >= rows.h) || room >= rows.h && limit < 0 && p.columns <= 1 {
					last := place_units(us, s, set_end, fs, h, sh, &shifts)
					// (rules reach the content edge of a container with a height of its own, or the end of this outer column)
					mc_add_columns(c, rec, cs, last.columns, h, fs, visual_y, cw, colw, gap, cx, limit >= 0 && !has_spanner ? max(room, h) : h)
					flow_shift = fs + f32(last.columns) * h - set_end
					visual_y += h
					row_room -= h
					break
				}
				// this row is full: where the next starts
				t := make([dynamic]Shift, 0, 16, context.temp_allocator)
				append(&t, Shift{s, sh})
				place_units(us, s, set_end, fs, room, sh, &t)
				end := fs + f32(n) * room
				k := 0
				for k < len(us) && us[k].y0 + shift_at(t[:], us[k].y0) < end {
					// what must stay whole, too tall for this row and not for a full outer column, waits for the next
					if room < rows.h {
						e := k
						for e + 1 < len(us) && us[e + 1].avoid && !us[e + 1].forced { e += 1 }
						chain := us[e].y1 - us[k].y0
						if chain > room + 0.001 && chain <= rows.h + 0.001 { break }
					}
					k += 1
				}
				next_s := k < len(us) ? us[k].y0 : end - t[len(t) - 1].by
				for e in t { if e.y < next_s { append(&shifts, e) } }
				mc_add_columns(c, rec, cs, n, room, fs, visual_y, cw, colw, gap, cx)
				visual_y += room
				sh = end - next_s
				append(&shifts, Shift{next_s, sh})
				s, fs = next_s, end
				us = us[k:]
				row_room = rows.h
				flow_shift = sh
			}
		} else if !empty_set {
			flow_start := set_start + flow_shift
			last_limit := limit
			if limit >= 0 { last_limit = max(limit - (visual_y - cy), 0) }
			fill_auto := cs.column_fill == .Auto && limit >= 0 && !has_spanner
			h := mc_column_height(set_units, set_start, set_end, flow_start, flow_shift, n, last_limit, fill_auto)
			// (forced breaks may ask for more columns than there are, height or not: they overflow, as the rest)
			p := place_units(set_units, set_start, set_end, flow_start, h, flow_shift, &shifts)
			cols := p.columns
			// (rules reach the content edge of a container with a height of its own, however low the columns are balanced)
			mc_add_columns(c, rec, cs, cols, h, flow_start, visual_y, cw, colw, gap, cx, limit >= 0 && !has_spanner ? max(last_limit, h) : h)
			total_used += cols
			// what follows starts after the last column's band, whatever is left of it
			flow_shift = flow_start + f32(cols) * h - set_end
			visual_y += h
		}
		if !has_spanner { break }
		// the spanner: a fragment of its own
		su := g.units[u1]
		sb := &l.boxes[su.spanner]
		sflow := su.y0 + flow_shift
		append(&shifts, Shift{su.y0, flow_shift})
		sx := multicol_strip_x(l, su.spanner, bi) - sb.margin[3]
		f := Mc_Frag{flow_min = sflow, flow_max = sflow + (su.y1 - su.y0), dx = cx - sx, dy = visual_y - sflow, spanner = true}
		if len(rec.frags) == 0 { f.flow_min = -FLOW_UNBOUNDED }
		append(&rec.frags, f)
		visual_y += su.y1 - su.y0
		if has_rows { row_room -= su.y1 - su.y0 }
		set_start = su.y1
		u0 = u1 + 1
		if u0 >= len(g.units) && set_start >= strip_end - 0.001 { break }
	}
	if len(rec.frags) == 0 {
		h: f32 = max(limit, 0)
		append(&rec.frags, Mc_Frag{flow_min = -FLOW_UNBOUNDED, flow_max = cy + h, dx = 0, dy = 0})
		visual_y = cy + h
	}
	rec.frags[len(rec.frags) - 1].flow_max = FLOW_UNBOUNDED
	if limit >= 0 && visual_y < cy + limit { visual_y = cy + limit }

	// a nested container that crosses a column of this one: in rows, and everything again
	if c.mc_nest_tries < MC_NEST_TRIES {
		slice.stable_sort_by(shifts[:], proc(a, b: Shift) -> bool { return a.y < b.y })
		again := false
		for &u in g.units {
			if u.nested == NONE { continue }
			top := u.y0 + shift_at(shifts[:], u.y0)
			bottom := top + (u.y1 - u.y0)
			for &f in rec.frags {
				if f.spanner || top < f.flow_min || top >= f.flow_max { continue }
				if f.flow_max == FLOW_UNBOUNDED || bottom <= f.flow_max + 0.5 { break }
				ib := &l.boxes[u.nested]
				room := f.flow_max - top - content_y(ib)
				if nr := mc_record(l, u.nested); nr != nil && nr.first_chain > room {
					// no room for what must start it: whole, in the next column
					if c.mc_whole == nil { c.mc_whole = make(map[i32]bool, 8, context.temp_allocator) }
					c.mc_whole[u.nested] = true
				} else {
					if c.mc_rows == nil { c.mc_rows = make(map[i32]Mc_Rows, 8, context.temp_allocator) }
					// (the first column's band starts without bound: its height is from the content box)
					c.mc_rows[u.nested] = Mc_Rows{room, f.flow_max - max(f.flow_min, cy)}
				}
				again = true
				break
			}
		}
		if again {
			c.mc_nest_tries += 1
			defer c.mc_nest_tries -= 1
			if fc.bfc != nil { fc.bfc^ = bfc_make() }
			return layout_multicol(c, bi, cw, ch_def, fc)
		}
	}

	// the boxes, for that height
	slice.stable_sort_by(shifts[:], proc(a, b: Shift) -> bool { return a.y < b.y })
	apply_shifts(c, bi, 0, 0, shifts[:])
	b = &l.boxes[bi]
	if .Ifc in b.flags { b.baseline = b.lines[1] > b.lines[0] ? l.lines[b.lines[0]].y + l.lines[b.lines[0]].baseline : -1; b.last_baseline = b.baseline }
	return visual_y - cy
}

// The x of spanner `x` in the strip, from the container's border box.
@(private)
multicol_strip_x :: proc(l: ^Layout, x, container: i32) -> f32 {
	v: f32
	cur := x
	for cur != NONE && cur != container {
		b := &l.boxes[cur]
		if b.kind != .Inline { v += b.pos.x }
		cur = b.pos_ref
	}
	return v
}

// A point of the flow (container's frame, from its border box) where it shows: for what is positioned from a box in the flow by
// something that is not (a static position).
@(private)
multicol_flow_to_visual :: proc(l: ^Layout, container: i32, p: Vec2) -> Vec2 {
	rec := mc_record(l, container)
	if rec == nil { return p }
	for &f in rec.frags {
		if p.y >= f.flow_min && p.y < f.flow_max { return p + {f.dx, f.dy} }
	}
	return p
}

////////////////////////////////
// Finishing: layout coordinates

// Fragments and rules of every container, in layout coordinates, once boxes have their final coordinates.
@(private)
flows_finish :: proc(l: ^Layout, order: []i32) {
	clear(&l.flow_frags)
	for x in order {
		b := &l.boxes[x]
		if .Multicol not_in b.fx { continue }
		rec := mc_record(l, x)
		if rec == nil { continue }
		first := i32(len(l.flow_frags))
		wm := b.wm
		for &f in rec.frags {
			min_y, max_y := f.flow_min, f.flow_max
			inner := Rect{{-FLOW_UNBOUNDED, min_y}, {FLOW_UNBOUNDED, max_y}}
			r := logical_to_physical_rect(inner, b.size.x, b.size.y, wm)
			off := logical_to_physical_point({f.dx, f.dy}, 0, 0, wm)
			#partial switch wm {
			case .Vertical_Rl, .Sideways_Rl: off = {-f.dy, f.dx}
			case .Sideways_Lr: off = {f.dy, -f.dx}
			}
			fr := Flow_Frag{region = rect_shift(r, b.abs), shift = off, space = NONE, clip = NONE, spanner = f.spanner}
			start := logical_to_physical_point({0, max(f.flow_min, 0)}, b.size.x, b.size.y, wm)
			fr.show = b.abs + start + off
			append(&l.flow_frags, fr)
		}
		rec.phys = {first, i32(len(l.flow_frags))}
		// (the regions are bands across the flow: apart when each ends before the next begins)
		rec.apart = true
		for k in 1 ..< len(rec.frags) { if rec.frags[k - 1].flow_max > rec.frags[k].flow_min { rec.apart = false } }
	}
}

// The nearest multi-column container around a box in a flow.
@(private)
flow_container :: proc(l: ^Layout, bi: i32) -> i32 {
	for p := l.boxes[bi].parent; p != NONE; p = l.boxes[p].parent {
		if .Multicol in l.boxes[p].fx { return p }
	}
	return NONE
}

@(private)
frag_overlaps :: proc(fr: ^Flow_Frag, r: Rect) -> bool {
	// (a rect of no size belongs where its origin is)
	return r.min.x < fr.region.max.x && r.max.x >= fr.region.min.x && r.min.y < fr.region.max.y && r.max.y >= fr.region.min.y
}

// What fragment `fr` shows of rect `r` of the flow (before its shift), and whether it counts: a fragment `r` does not
// reach shows nothing, and once some fragment showed part of it, nothing is shown where a column just begins (a box that
// ends on the band's edge).
@(private)
flow_cut :: #force_inline proc(fr: ^Flow_Frag, r: Rect, shown: bool) -> (cut: Rect, ok: bool) {
	if !frag_overlaps(fr, r) { return }
	cut = rect_intersect(r, fr.region)
	if cut.max.y < cut.min.y { cut.max.y = cut.min.y }
	if cut.max.x < cut.min.x { cut.max.x = cut.min.x }
	if shown && rect_empty(cut) && !rect_empty(r) { return }
	return cut, true
}

// The part of a rect of the flow shown in each fragment, in layout coordinates, through the containers around it.
flow_rects :: proc(l: ^Layout, container: i32, r: Rect, out: ^[dynamic]Rect) {
	rec := mc_record(l, container)
	if rec == nil { append(out, r); return }
	n0 := len(out)
	for fi in rec.phys[0] ..< rec.phys[1] {
		fr := &l.flow_frags[fi]
		if cut, shows := flow_cut(fr, r, len(out) > n0); shows { append(out, rect_shift(cut, fr.shift)) }
	}
	if len(out) == n0 { append(out, r) }
	// a container inside another: then through that one's
	if .In_Flow in l.boxes[container].fx {
		if outer := flow_container(l, container); outer != NONE {
			mine := make([dynamic]Rect, 0, len(out) - n0, context.temp_allocator)
			append(&mine, ..out[n0:])
			resize(out, n0)
			for q in mine { flow_rects(l, outer, q, out) }
		}
	}
}

// The union of what flow_rects gives, without making the list (called for every box and line of a flow). `near`: a
// fragment to try first (see flow_bounds_add).
flow_bounds :: proc(l: ^Layout, container: i32, r: Rect, near: ^i32 = nil) -> Rect {
	u: Rect
	n := 0
	flow_bounds_add(l, container, r, &u, &n, near)
	return u
}

// Whether `r` lies inside the region of `fr`, short of its end edges: where the regions are apart, no other fragment
// reaches it (frag_overlaps), and the fragment shows it whole.
@(private)
flow_inside :: #force_inline proc(fr: ^Flow_Frag, r: Rect) -> bool {
	g := fr.region
	return r.min.x >= g.min.x && r.min.x <= r.max.x && r.max.x < g.max.x && r.min.y >= g.min.y && r.min.y <= r.max.y && r.max.y < g.max.y
}

// The parts of `r` united into `u` in the order flow_rects lists them (`n`: how many so far): an empty one adds nothing to
// a union that is not empty, and is replaced by the first that is not. `near`, a fragment of any container or none: where
// the container's regions are apart and `r` lies inside that fragment's, that fragment alone shows it; else every
// fragment is tried, and `near` becomes the one `r` lies inside, if any (the boxes and lines a caller walks in tree order
// are mostly in the column of the one before).
@(private)
flow_bounds_add :: proc(l: ^Layout, container: i32, r: Rect, u: ^Rect, n: ^int, near: ^i32 = nil) {
	unite :: #force_inline proc(u: ^Rect, n: ^int, q: Rect) {
		switch {
		case n^ == 0: u^ = q
		case rect_empty(q) && !rect_empty(u^):
		case rect_empty(u^) && !rect_empty(q): u^ = q
		case: u^ = rect_union(u^, q)
		}
		n^ += 1
	}
	rec := mc_record(l, container)
	if rec == nil { unite(u, n, r); return }
	outer := .In_Flow in l.boxes[container].fx ? flow_container(l, container) : NONE
	apart := near != nil && rec.apart
	if apart && near^ >= rec.phys[0] && near^ < rec.phys[1] && flow_inside(&l.flow_frags[near^], r) {
		fr := &l.flow_frags[near^]
		if q := rect_shift(r, fr.shift); outer != NONE { flow_bounds_add(l, outer, q, u, n) } else { unite(u, n, q) }
		return
	}
	shown := false
	for fi in rec.phys[0] ..< rec.phys[1] {
		fr := &l.flow_frags[fi]
		cut, shows := flow_cut(fr, r, shown)
		if !shows { continue }
		shown = true
		if apart && flow_inside(fr, r) { near^ = fi }
		if q := rect_shift(cut, fr.shift); outer != NONE { flow_bounds_add(l, outer, q, u, n) } else { unite(u, n, q) }
	}
	if !shown { if outer != NONE { flow_bounds_add(l, outer, r, u, n) } else { unite(u, n, r) } }
}

// Finishing: the spaces of a container's columns. `b.content_space` becomes the flow's.
@(private)
flow_spaces :: proc(l: ^Layout, x: i32) {
	b := &l.boxes[x]
	rec := mc_record(l, x)
	if rec == nil { return }
	rec.outer_space, rec.outer_clip = b.content_space, b.content_clip
	ps := l.spaces[b.content_space]
	parent := b.content_space
	xform, plane := ps.xform, ps.plane
	outer := b.content_clip
	base := i32(len(l.spaces))
	append(&l.spaces, Space{kind = .Flow, parent = parent, box = x, frame = NONE, clip = outer, xform = xform, plane = plane, persp_from = NONE, ctx = NONE, dest = NONE, flow = rec.phys})
	for fi in rec.phys[0] ..< rec.phys[1] {
		fr := &l.flow_frags[fi]
		fr.space = i32(len(l.spaces))
		// (a spanner is whole: what it paints around itself, an outline, a shadow, is not cut)
		cut := fr.spanner ? Rect{{-FLOW_UNBOUNDED, -FLOW_UNBOUNDED}, {FLOW_UNBOUNDED, FLOW_UNBOUNDED}} : fr.region
		// inside a column of an outer container: the one it shows in
		col_parent, clip_parent := parent, outer
		if ps.kind == .Flow {
			at := l.flow_frags[ps.flow[0]]
			for oi in ps.flow[0] ..< ps.flow[1] {
				of := l.flow_frags[oi]
				if frag_overlaps(&of, Rect{fr.show, fr.show}) { at = of; break }
			}
			col_parent, clip_parent = at.space, at.clip
		}
		append(&l.clips, Clip{parent = clip_parent, space = fr.space, box = NONE, rect = cut})
		fr.clip = i32(len(l.clips) - 1)
		append(&l.spaces, Space{kind = .Column, parent = col_parent, box = x, frame = NONE, clip = fr.clip, xform = xform, plane = plane, persp_from = NONE, ctx = NONE, dest = NONE, shift = fr.shift, flow = {fi - rec.phys[0], 0}})
	}
	b.content_space = base
}

// A box in a flow that makes a space of its own (a transform, a scroll port): its space hangs from the fragment where it starts, not
// from the flow; it is not cut. A box positioned against the container itself is not in the flow.
@(private)
flow_fix_box :: proc(l: ^Layout, x: i32) {
	b := &l.boxes[x]
	if .Abs in b.flags && b.cb != NONE && .Multicol in l.boxes[b.cb].fx {
		if rec := mc_record(l, b.cb); rec != nil { b.space, b.clip = rec.outer_space, rec.outer_clip }
		return
	}
	if l.spaces[b.space].kind != .Flow { return }
	if b.flags & {.Transformed, .Sticky, .Scroll} == {} { return }
	sp := l.spaces[b.space]
	at := &l.flow_frags[sp.flow[0]]
	for fi in sp.flow[0] ..< sp.flow[1] {
		fr := &l.flow_frags[fi]
		if frag_overlaps(fr, Rect{b.abs, b.abs}) { at = fr; break }
	}
	b.space = at.space
	b.clip = l.clips[at.clip].parent
}

// Display list: an item of the flow space, one copy per fragment it lies in.
@(private)
push_flow_item :: proc(c: ^Ctx, it: Display_Item) {
	l := c.l
	sp := l.spaces[it.space]
	out := c.dl_out != nil ? c.dl_out : &l.items
	it2 := it
	placed := false
	for fi in sp.flow[0] ..< sp.flow[1] {
		fr := l.flow_frags[fi]
		if !frag_overlaps(&fr, it.rect) { continue }
		// an item that ends where a column begins is not in that column
		if it.rect.max.y == fr.region.min.y && it.rect.min.y < it.rect.max.y && it.rect.max.x > it.rect.min.x { continue }
		if it.rect.max.x == fr.region.min.x && it.rect.min.x < it.rect.max.x && it.rect.max.y > it.rect.min.y { continue }
		it2.space = fr.space
		it2.clip = flow_clip(c, it.clip, sp.clip, it.space, fr)
		append(out, it2)
		placed = true
	}
	if !placed {
		fr := l.flow_frags[sp.flow[0]]
		it2.space = fr.space
		it2.clip = flow_clip(c, it.clip, sp.clip, it.space, fr)
		append(out, it2)
	}
}

// No clip lies in the space of a flow: flow_clip makes none, and the display list can be made on the layout threads.
@(private)
flows_clip_free :: proc(l: ^Layout) -> bool {
	for &cl in l.clips { if l.spaces[cl.space].kind == .Flow { return false } }
	return true
}

// Clip `ci` for an item shown in fragment `fr`: the clips inside the flow again, in the fragment's space, under the fragment's clip.
@(private)
flow_clip :: proc(c: ^Ctx, ci, outer, flow_space: i32, fr: Flow_Frag) -> i32 {
	l := c.l
	if ci == outer || ci == NONE { return fr.clip }
	cl := l.clips[ci]
	if cl.space != flow_space { return ci }
	key := [2]i32{ci, fr.space}
	if c.flow_clips == nil { c.flow_clips = make(map[[2]i32]i32, 16, context.temp_allocator) }
	if v, ok := c.flow_clips[key]; ok { return v }
	parent := flow_clip(c, cl.parent, outer, flow_space, fr)
	append(&l.clips, Clip{parent = parent, space = fr.space, box = cl.box, rect = cl.rect, radii = cl.radii})
	v := i32(len(l.clips) - 1)
	c.flow_clips[key] = v
	return v
}

// The column rules of a container (behind its content, after its box).
@(private)
emit_column_rules :: proc(c: ^Ctx, bi: i32) {
	l := c.l
	b := &l.boxes[bi]
	rec := mc_record(l, bi)
	if rec == nil { return }
	for r in rec.rules {
		phys := logical_to_physical_rect(r, b.size.x, b.size.y, b.wm)
		it := item_for_box(c, .Column_Rule, bi, rect_shift(phys, b.abs))
		it.flags -= {.Hit}
		if is_vert(b.wm) { it.flags += {.Vertical} }
		push_item(c, it)
	}
}
