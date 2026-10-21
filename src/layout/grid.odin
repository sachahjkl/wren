package layout

import "base:intrinsics"
import "core:slice"
import "core:strings"
import "wb:style"

// CSS Grid Layout 1: the explicit grid from the templates (line names, repeat() with auto-fill / auto-fit and the
// collapse of empty auto-fit tracks, grid-template-areas and the -start / -end lines they imply), the implicit grid,
// line-based placement with its conflict handling (§8.3), the auto-placement algorithm (§8.5: sparse and dense, row and
// column flow), the track sizing algorithm (§11, grid_size.odin), content and self alignment with baselines and auto
// margins, and absolutely positioned boxes whose containing block is a grid container (§9). Grid items are built like
// flex items (blockified, text runs in anonymous items, floats ignored) and paint like them.
//
// Coordinates: lines are numbered from the explicit grid's first line (0, "1" in CSS); the implicit grid adds tracks on
// both sides. Each axis then numbers its tracks from 0 with `off` = the track index of explicit line 0. Line numbers are
// clamped to ±layout.grid.max_tracks, so `grid-row: 100000` or a huge repeat() costs at most that many tracks.

@(private)
Grid_Item :: struct {
	box:      i32,
	area:     [2][2]i32,      // [axis: 0 columns, 1 rows] [start, end) track indices
	m:        [4]f32,         // used margins, top right bottom left (auto ones 0 until aligned)
	contrib:  [2][3]f32,      // [axis] min-content, max-content, minimum contributions (outer sizes); < 0: not computed
	size:     Vec2,           // border box
	content_h: f32,           // border-box height the item's content wants at its width
	baseline: f32,            // baseline-aligned in its row: first baseline from the top margin edge; < 0: not aligned
	shim:     f32,            // baseline alignment: space added above the item
	ratio_dep: bool,          // its min-content width follows its row size (aspect-ratio with a percentage height)
	placed:   bool,           // false: past layout.grid.max_items, not laid out
	// subgrids (CSS Grid 2 §9)
	sub:      ^Grid,          // the item is a subgrid: its grid; `axes` are its subgridded axes
	proxy:    bool,           // the item stands, in `axes`, for an item of a subgrid (it is sized, never laid out)
	axes:     [2]bool,
	src:      ^Grid,          // proxy: the subgrid and its item
	src_i:    i32,
	extra:    [2]f32,         // proxy: margin, border and padding of the subgrids whose edges it touches, per axis
}

@(private)
Grid_Min :: enum u8 { Fixed, Auto, Min_Content, Max_Content }
@(private)
Grid_Max :: enum u8 { Fixed, Auto, Min_Content, Max_Content, Flex, Fit }

// One track of the implicit grid while it is sized.
@(private)
Grid_Tr :: struct {
	min_k:     Grid_Min,
	max_k:     Grid_Max,
	min_v, max_v: f32,        // Fixed: device px; Flex: the factor; Fit: the fit-content() limit
	base, limit: f32,         // base size and growth limit (GRID_INF: infinite)
	planned, inc: f32,        // space distribution: planned increase, item-incurred increase
	inf_grow:  bool,
	collapsed: bool,          // an empty auto-fit track
	frozen, aff, beyond, touched: bool,
	pos:       f32,           // after alignment: start offset from the content box start
}

@(private)
Grid_Axis :: struct {
	count:     i32,                          // tracks of the explicit grid
	tmpl_n:    i32,                          // of which come from grid-template-rows / columns (the rest from areas)
	fns:       [dynamic]^style.Grid_Track,   // the template's sizing function of each explicit track
	auto_fns:  []style.Grid_Track,           // grid-auto-rows / columns
	names:     map[string][dynamic]i32,      // explicit line index of each named line, ascending
	rep_first, rep_len, rep_count: i32,      // auto-repeat: first explicit track, tracks per repetition, repetitions
	auto_fit:  bool,
	off:       i32,                          // track index of explicit line 0
	n:         i32,                          // tracks of the implicit grid
	tracks:    []Grid_Tr,
	gap:       f32,
}

@(private)
Grid :: struct {
	bi:       i32,
	items:    []Grid_Item,    // the container's items, then the proxies of its subgrids' items
	n_real:   int,            // items[:n_real] are the container's own
	parent:   ^Grid,          // a subgrid: the grid it is an item of, and that item's index there
	pitem:    i32,
	subgrid:  [2]bool,        // a subgrid: the axes whose tracks are the parent's
	ax:       [2]Grid_Axis,
	flow_col: bool,
	dense:    bool,
	size:     Vec2,           // content box the tracks were aligned in
	rtl:      bool,
}

@(private)
Grid_Key :: struct { box: i32, reps: [2]i32, intrinsic: bool }

// Per layout pass: placements are kept per container (and auto-repeat counts), the last layout of each container serves
// its absolutely positioned boxes.
@(private)
Grid_Pass :: struct {
	placed: map[Grid_Key]^Grid,
	last:   map[i32]^Grid,
	subs:   map[i32]^Grid,    // subgrids, as placed by their parent's current grid
}

@(private)
grid_pass :: proc(c: ^Ctx) -> ^Grid_Pass {
	if c.grid == nil {
		c.grid = new(Grid_Pass, context.temp_allocator)
		c.grid.placed = make(map[Grid_Key]^Grid, 16, context.temp_allocator)
		c.grid.last = make(map[i32]^Grid, 16, context.temp_allocator)
		c.grid.subs = make(map[i32]^Grid, 4, context.temp_allocator)
	}
	return c.grid
}

////////////////////////////////
// Explicit grid

@(private)
grid_add_names :: proc(ax: ^Grid_Axis, names: []string, line: i32) {
	for n in names {
		list := ax.names[n]
		if list == nil { list = make([dynamic]i32, 0, 2, context.temp_allocator) }
		if len(list) == 0 || list[len(list) - 1] != line { append(&list, line) }
		ax.names[n] = list
	}
}

// Size of a track for counting auto repetitions (§7.2.3.2): its max sizing function if definite, else its min.
@(private)
grid_fixed_size :: proc(c: ^Ctx, t: ^style.Grid_Track, base: f32) -> f32 {
	if t.kind == .Breadth || t.kind == .Minmax {
		if t.max.kind == .Length { if v, ok := definite(c, t.max.len, base); ok { return max(v, 0) } }
		if t.min.kind == .Length { if v, ok := definite(c, t.min.len, base); ok { return max(v, 0) } }
	}
	return 0
}

// Repetitions of the auto-fill / auto-fit repeat() of a template (0: none). `avail` is the definite content size, else
// the content size bounds `min_avail` / `max_avail` (< 0: none).
@(private)
grid_auto_repeat :: proc(c: ^Ctx, tmpl: ^style.Grid_Template, avail, min_avail, max_avail, gap: f32, lim: i32) -> i32 {
	if tmpl.kind != .Tracks { return 0 }
	base := avail >= 0 ? avail : max_avail
	fixed: f32
	other: i32
	rep_size: f32
	rep_len: i32
	for &t in tmpl.tracks {
		if t.kind != .Repeat { fixed += grid_fixed_size(c, &t, base); other += 1; continue }
		if t.repeat == .Count {
			for &u in t.tracks { fixed += grid_fixed_size(c, &u, base) * f32(t.count) }
			other += t.count * i32(len(t.tracks))
			continue
		}
		for &u in t.tracks { rep_size += grid_fixed_size(c, &u, base) }
		rep_len = i32(len(t.tracks))
	}
	if rep_len == 0 { return 0 }
	// a repetition is at least one CSS pixel wide: zero-sized tracks would repeat forever
	per := max(rep_size, c.scale) + gap * f32(rep_len)
	n: i32 = 1
	room_of :: proc(size, fixed, gap: f32, other: i32) -> f32 { return size - fixed - gap * f32(other - 1) }
	if limit := avail >= 0 ? avail : max_avail; limit >= 0 {
		n = i32(min(room_of(limit, fixed, gap, other) / per + 0.0001, 1e9))
	} else if min_avail > 0 {
		r := room_of(min_avail, fixed, gap, other) / per
		n = i32(min(r, 1e9))
		if f32(n) < r - 0.0001 { n += 1 }
	}
	return clamp(n, 1, max((lim - other) / rep_len, 1))
}

// Content-box bounds of the container along an axis from min-* / max-* (< 0: none). `pb` is its padding and border.
@(private)
grid_bounds :: proc(c: ^Ctx, cs: ^style.Computed, axis: int, pb, base: f32) -> (mn, mx: f32) {
	mn, mx = -1, -1
	bb := cs.box_sizing == .Border_Box
	lmin := axis == 0 ? cs.min_width : cs.min_height
	lmax := axis == 0 ? cs.max_width : cs.max_height
	if v, ok := definite(c, lmin, base); ok { mn = max(bb ? v - pb : v, 0) }
	if lmax.kind != .None {
		if v, ok := definite(c, lmax, base); ok { mx = max(bb ? v - pb : v, 0) }
	}
	return
}

@(private)
grid_template :: proc(cs: ^style.Computed, axis: int) -> ^style.Grid_Template {
	return axis == 0 ? &cs.grid_template_columns : &cs.grid_template_rows
}

@(private)
grid_axis_setup :: proc(c: ^Ctx, ax: ^Grid_Axis, cs: ^style.Computed, axis: int, reps, lim: i32) {
	tmpl := grid_template(cs, axis)
	ax.auto_fns = axis == 0 ? cs.grid_auto_columns : cs.grid_auto_rows
	ax.names = make(map[string][dynamic]i32, 8, context.temp_allocator)
	ax.fns = make([dynamic]^style.Grid_Track, 0, 8, context.temp_allocator)
	if tmpl.kind == .Tracks {
		line: i32 = 0
		outer: for ti in 0 ..< len(tmpl.tracks) {
			t := &tmpl.tracks[ti]
			if t.kind != .Repeat {
				if i32(len(ax.fns)) >= lim { break outer }
				grid_add_names(ax, t.names_before, line)
				append(&ax.fns, t)
				line += 1
				continue
			}
			count := t.count
			auto_rep := t.repeat != .Count
			if auto_rep { count = reps; ax.rep_first, ax.rep_len, ax.auto_fit = line, i32(len(t.tracks)), t.repeat == .Auto_Fit }
			grid_add_names(ax, t.names_before, line)
			for r in 0 ..< count {
				for ii in 0 ..< len(t.tracks) {
					if i32(len(ax.fns)) >= lim {
						if auto_rep { ax.rep_count = (line - ax.rep_first) / max(ax.rep_len, 1) }
						break outer
					}
					u := &t.tracks[ii]
					grid_add_names(ax, u.names_before, line)
					append(&ax.fns, u)
					line += 1
				}
				grid_add_names(ax, t.end_names, line)
				if auto_rep { ax.rep_count = r + 1 }
			}
		}
		grid_add_names(ax, tmpl.end_names, line)
	}
	ax.tmpl_n = i32(len(ax.fns))
	ax.count = ax.tmpl_n
	areas := &cs.grid_template_areas
	if areas.rows > 0 && areas.cols > 0 {
		ax.count = max(ax.count, min(axis == 0 ? areas.cols : areas.rows, lim))
		for a in areas.areas {
			s, e := axis == 0 ? a.col_start : a.row_start, axis == 0 ? a.col_end : a.row_end
			start := [1]string{strings.concatenate({a.name, "-start"}, context.temp_allocator)}
			end := [1]string{strings.concatenate({a.name, "-end"}, context.temp_allocator)}
			grid_add_names(ax, start[:], s - 1)
			grid_add_names(ax, end[:], e - 1)
		}
		grid_sort_names(ax)
	}
}

@(private)
grid_sort_names :: proc(ax: ^Grid_Axis) {
	for _, &list in ax.names {
		slice.sort(list[:])
		n := 0
		for v, i in list { if i == 0 || v != list[n - 1] { list[n] = v; n += 1 } }
		resize(&list, n)
	}
}

// A subgridded axis (CSS Grid 2 §9): as many tracks as the subgrid spans in its parent, with the line names of
// `subgrid [a] [b] ...` and those of the parent's lines it spans.
@(private)
grid_axis_setup_sub :: proc(ax: ^Grid_Axis, cs: ^style.Computed, axis: int, parent: ^Grid, pit: ^Grid_Item) {
	tmpl := grid_template(cs, axis)
	ax.names = make(map[string][dynamic]i32, 8, context.temp_allocator)
	ax.fns = make([dynamic]^style.Grid_Track, 0, 0, context.temp_allocator)
	span := pit.area[axis][1] - pit.area[axis][0]
	ax.count = span
	for t, i in tmpl.tracks {
		if i32(i) > span { break }
		grid_add_names(ax, t.names_before, i32(i))
	}
	pa := &parent.ax[axis]
	for name, lines in pa.names {
		for l in lines {
			tl := l + pa.off - pit.area[axis][0]
			if tl < 0 || tl > span { continue }
			one := [1]string{name}
			grid_add_names(ax, one[:], tl)
		}
	}
	grid_sort_names(ax)
}

// The sizing function of track `t` of the implicit grid (nil: auto).
@(private)
grid_fn :: proc(ax: ^Grid_Axis, t: i32) -> ^style.Grid_Track {
	e := t - ax.off
	if e >= 0 && e < ax.tmpl_n { return ax.fns[e] }
	na := i32(len(ax.auto_fns))
	if na == 0 { return nil }
	idx: i32
	switch {
	case e >= 0 && e < ax.count: idx = (e - ax.tmpl_n) % na
	case e >= ax.count: idx = (e - ax.count) % na
	case: idx = na - 1 - ((-e - 1) % na)
	}
	return &ax.auto_fns[idx]
}

////////////////////////////////
// Line resolution (§8.3)

@(private)
grid_nth_named :: proc(ax: ^Grid_Axis, name: string, n: i32) -> i32 {
	lines := ax.names[name]
	k := i32(len(lines))
	if n > 0 {
		if n <= k { return lines[n - 1] }
		return ax.count + (n - k)   // every implicit line after the explicit grid counts as having the name
	}
	m := -n
	if m <= k { return lines[k - m] }
	return -(m - k)
}

@(private)
grid_line_of :: proc(ax: ^Grid_Axis, gl: style.Grid_Line, end: bool) -> i32 {
	#partial switch gl.kind {
	case .Line:
		if gl.name == "" { return gl.n > 0 ? gl.n - 1 : ax.count + 1 + gl.n }
		return grid_nth_named(ax, gl.name, gl.n)
	case .Name:
		key := strings.concatenate({gl.name, end ? "-end" : "-start"}, context.temp_allocator)
		if l := ax.names[key]; len(l) > 0 { return l[0] }
		return grid_nth_named(ax, gl.name, 1)
	}
	return 0
}

// The line `n` lines (named `name`, if any) away from `from`.
@(private)
grid_span_from :: proc(ax: ^Grid_Axis, from, n: i32, name: string, forward: bool) -> i32 {
	if name == "" { return forward ? from + n : from - n }
	lines := ax.names[name]
	found: i32
	if forward {
		for l in lines { if l > from { found += 1; if found == n { return l } } }
		return max(from, ax.count) + (n - found)
	}
	#reverse for l in lines { if l < from { found += 1; if found == n { return l } } }
	return min(from, 0) - (n - found)
}

// Placement of an item along one axis: definite lines [a, b), or (def = false) a span b to place automatically.
@(private)
grid_resolve :: proc(ax: ^Grid_Axis, s, e: style.Grid_Line, lim: i32) -> (a, b: i32, def: bool) {
	sk, ek := s.kind, e.kind
	if sk == .Span && ek == .Span { ek = .Auto }
	sdef := sk == .Line || sk == .Name
	edef := ek == .Line || ek == .Name
	switch {
	case sdef && edef:
		a, b = grid_line_of(ax, s, false), grid_line_of(ax, e, true)
		if a > b { a, b = b, a }
		if a == b { b = a + 1 }
	case sdef:
		a = grid_line_of(ax, s, false)
		b = ek == .Span ? grid_span_from(ax, a, e.n, e.name, true) : a + 1
	case edef:
		b = grid_line_of(ax, e, true)
		a = sk == .Span ? grid_span_from(ax, b, s.n, s.name, false) : b - 1
	case:
		// a span to a named line means span 1 for auto-placement
		span: i32 = 1
		if sk == .Span && s.name == "" { span = s.n } else if ek == .Span && e.name == "" { span = e.n }
		return 0, clamp(span, 1, lim), false
	}
	a = clamp(a, -lim, lim - 1)
	b = clamp(b, a + 1, lim)
	return a, b, true
}

// The same for an absolutely positioned box: each side is a line or auto (the padding edge).
@(private)
grid_resolve_abs :: proc(ax: ^Grid_Axis, s, e: style.Grid_Line) -> (a, b: i32, has_a, has_b: bool) {
	sk, ek := s.kind, e.kind
	if sk == .Span && ek == .Span { ek = .Auto }
	has_a = sk == .Line || sk == .Name
	has_b = ek == .Line || ek == .Name
	if has_a { a = grid_line_of(ax, s, false) }
	if has_b { b = grid_line_of(ax, e, true) }
	switch {
	case has_a && has_b:
		if a > b { a, b = b, a }
		if a == b { b = a + 1 }
	case has_a && ek == .Span: b, has_b = grid_span_from(ax, a, e.n, e.name, true), true
	case has_b && sk == .Span: a, has_a = grid_span_from(ax, b, s.n, s.name, false), true
	}
	return
}

////////////////////////////////
// Occupancy of the grid during auto-placement: one bit per cell, a row per secondary-axis track

@(private)
Grid_Occ :: struct {
	rows:  [dynamic][dynamic]u64,
	first: [dynamic]i32,          // per row: first free primary index (relative to p0)
	p0, s0: i32,
	dense: i32,                   // rows before this one are full (dense packing starts here)
}

@(private)
occ_row :: proc(o: ^Grid_Occ, s: i32) -> int {
	i := int(s - o.s0)
	for len(o.rows) <= i {
		append(&o.rows, make([dynamic]u64, 0, 0, context.temp_allocator))
		append(&o.first, 0)
	}
	return i
}

@(private)
occ_free :: proc(o: ^Grid_Occ, p0, p1, s0, s1: i32) -> bool {
	for s in s0 ..< s1 {
		i := int(s - o.s0)
		if i >= len(o.rows) { break }
		r := o.rows[i][:]
		j, end := int(p0 - o.p0), int(p1 - o.p0)
		if j < int(o.first[i]) && end <= int(o.first[i]) { return false }
		for j < end {
			w := j >> 6
			if w >= len(r) { break }
			bit := uint(j & 63)
			n := min(64 - int(bit), end - j)
			mask := (n == 64 ? ~u64(0) : (u64(1) << uint(n)) - 1) << bit
			if r[w] & mask != 0 { return false }
			j += n
		}
	}
	return true
}

// First free primary index at or after `from` in row `s` (a lower bound for any item starting in that row).
@(private)
occ_next_free :: proc(o: ^Grid_Occ, s, from: i32) -> i32 {
	i := int(s - o.s0)
	if i < 0 || i >= len(o.rows) { return from }
	r := o.rows[i][:]
	j := max(int(from - o.p0), 0)
	for {
		w := j >> 6
		if w >= len(r) { return o.p0 + i32(j) }
		x := ~r[w] >> uint(j & 63)
		if x != 0 { return o.p0 + i32(j) + i32(intrinsics.count_trailing_zeros(x)) }
		j = (w + 1) * 64
	}
}

@(private)
occ_mark :: proc(o: ^Grid_Occ, p0, p1, s0, s1: i32) {
	for s in s0 ..< s1 {
		i := occ_row(o, s)
		r := &o.rows[i]
		end := int(p1 - o.p0)
		words := (end + 63) >> 6
		if len(r) < words { resize(r, words) }
		for j := int(p0 - o.p0); j < end; {
			w := j >> 6
			bit := uint(j & 63)
			n := min(64 - int(bit), end - j)
			mask := (n == 64 ? ~u64(0) : (u64(1) << uint(n)) - 1) << bit
			r[w] |= mask
			j += n
		}
		if int(o.first[i]) >= int(p0 - o.p0) && int(o.first[i]) < end {
			o.first[i] = occ_next_free(o, s, p1) - o.p0
		}
	}
}

// The first row that is not full, given `width` primary tracks.
@(private)
occ_dense_row :: proc(o: ^Grid_Occ, width: i32) -> i32 {
	for int(o.dense) < len(o.rows) && o.first[o.dense] >= width { o.dense += 1 }
	return o.s0 + o.dense
}

////////////////////////////////
// Items and placement (§8.5)

// The in-flow children of a grid container in order-modified document order (absolutely positioned ones get their
// static position).
@(private)
grid_children :: proc(c: ^Ctx, bi: i32) -> []i32 {
	b := &c.l.boxes[bi]
	list := make([dynamic]i32, 0, 8, context.temp_allocator)
	ordered := false
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
		k := &c.l.boxes[ch]
		if .Abs in k.flags { continue }
		if k.cs.order != 0 { ordered = true }
		append(&list, ch)
	}
	if ordered {
		Ord :: struct { order: i32, box: i32 }
		tmp := make([]Ord, len(list), context.temp_allocator)
		for id, i in list { tmp[i] = {c.l.boxes[id].cs.order, id} }
		slice.stable_sort_by(tmp, proc(a, b: Ord) -> bool { return a.order < b.order })
		for o, i in tmp { list[i] = o.box }
	}
	return list[:]
}

// Builds the explicit grid and places the items. Auto-repeat counts come from `size` (definite content size per axis,
// < 0: indefinite) and the container's min / max sizes.
@(private)
grid_build :: proc(c: ^Ctx, bi: i32, reps: [2]i32, parent: ^Grid = nil, pitem: i32 = -1) -> ^Grid {
	b := &c.l.boxes[bi]
	cs := b.cs
	lim := i32(max(c.set.grid_max_tracks, 1))
	g := new(Grid, context.temp_allocator)
	g.bi = bi
	g.parent, g.pitem = parent, pitem
	g.flow_col = cs.grid_auto_flow.column
	g.dense = cs.grid_auto_flow.dense
	// a subgridded axis has exactly the tracks it spans in its parent: placements are clamped to them
	lims := [2]i32{lim, lim}
	for axis in 0 ..< 2 {
		if parent != nil && grid_template(cs, axis).kind == .Subgrid {
			g.subgrid[axis] = true
			grid_axis_setup_sub(&g.ax[axis], cs, axis, parent, &parent.items[pitem])
			lims[axis] = max(g.ax[axis].count, 1)
		} else {
			grid_axis_setup(c, &g.ax[axis], cs, axis, reps[axis], lim)
		}
	}

	ids := grid_children(c, bi)
	n := min(len(ids), max(c.set.grid_max_items, 0))
	g.items = make([]Grid_Item, len(ids), context.temp_allocator)
	g.n_real = len(ids)
	for id, i in ids { g.items[i] = Grid_Item{box = id, placed = i < n} }

	lines := make([][2][2]i32, n, context.temp_allocator)
	def := make([][2]bool, n, context.temp_allocator)
	for i in 0 ..< n {
		ks := c.l.boxes[ids[i]].cs
		a, e, d := grid_resolve(&g.ax[0], ks.grid_column_start, ks.grid_column_end, lim)
		lines[i][0], def[i][0] = {a, e}, d
		a, e, d = grid_resolve(&g.ax[1], ks.grid_row_start, ks.grid_row_end, lim)
		lines[i][1], def[i][1] = {a, e}, d
		for axis in 0 ..< 2 {
			if !g.subgrid[axis] { continue }
			cnt := lims[axis]
			if def[i][axis] {
				l := &lines[i][axis]
				l[0] = clamp(l[0], 0, cnt - 1)
				l[1] = clamp(l[1], l[0] + 1, cnt)
			} else {
				lines[i][axis][1] = min(lines[i][axis][1], cnt)
			}
		}
	}

	P := g.flow_col ? 1 : 0   // the axis the cursor moves along first (columns for row flow)
	S := 1 - P
	lim_p, lim_s := lims[P], lims[S]
	p_lo, s_lo: i32 = 0, 0
	p_hi := g.ax[P].count
	auto_span: i32 = 1
	for i in 0 ..< n {
		if def[i][P] { p_lo = min(p_lo, lines[i][P][0]); p_hi = max(p_hi, lines[i][P][1]) } else { auto_span = max(auto_span, lines[i][P][1]) }
		if def[i][S] { s_lo = min(s_lo, lines[i][S][0]) }
	}
	occ := Grid_Occ{p0 = p_lo, s0 = s_lo}
	occ.rows = make([dynamic][dynamic]u64, 0, 16, context.temp_allocator)
	occ.first = make([dynamic]i32, 0, 16, context.temp_allocator)
	mark :: proc(o: ^Grid_Occ, l: [2][2]i32, P, S: int) { occ_mark(o, l[P][0], l[P][1], l[S][0], l[S][1]) }

	// 1. items with a definite position in both axes
	for i in 0 ..< n { if def[i][P] && def[i][S] { mark(&occ, lines[i], P, S) } }

	// 2. items locked to a secondary track
	cursors := make(map[i32]i32, 16, context.temp_allocator)
	for i in 0 ..< n {
		if !def[i][S] || def[i][P] { continue }
		span := lines[i][P][1]
		s0, s1 := lines[i][S][0], lines[i][S][1]
		p := p_lo
		if !g.dense { if v, ok := cursors[s0]; ok { p = v } }
		for !occ_free(&occ, p, p + span, s0, s1) {
			if p + span > lim_p { break }
			nf := occ_next_free(&occ, s0, p)
			p = nf > p ? nf : p + 1
		}
		p = min(p, lim_p - span)
		lines[i][P], def[i][P] = {p, p + span}, true
		mark(&occ, lines[i], P, S)
		cursors[s0] = p + span
		p_hi = max(p_hi, p + span)
	}

	// 3. the primary axis of the implicit grid is now fixed
	p_hi = max(p_hi, p_lo + auto_span)
	width := p_hi - p_lo

	// 4. everything else
	cp, cs_ := p_lo, s_lo
	for i in 0 ..< n {
		if def[i][S] { continue }
		ss := lines[i][S][1]
		if def[i][P] {
			p0, p1 := lines[i][P][0], lines[i][P][1]
			if g.dense { cs_ = occ_dense_row(&occ, width) } else if p0 < cp { cs_ += 1 }
			for cs_ + ss < lim_s && !occ_free(&occ, p0, p1, cs_, cs_ + ss) { cs_ += 1 }
			cs_ = min(cs_, lim_s - ss)
			lines[i][S] = {cs_, cs_ + ss}
			cp = p1
		} else {
			ps := lines[i][P][1]
			if g.dense {
				cs_ = occ_dense_row(&occ, width)
				cp = p_lo
			}
			for {
				if cs_ + ss > lim_s { cs_ = lim_s - ss; cp = p_lo; break }
				if cp + ps > p_hi { cs_ += 1; cp = p_lo; continue }
				if occ_free(&occ, cp, cp + ps, cs_, cs_ + ss) { break }
				nf := occ_next_free(&occ, cs_, cp)
				cp = nf > cp ? nf : cp + 1
			}
			lines[i][P] = {cp, cp + ps}
			lines[i][S] = {cs_, cs_ + ss}
			cp += ps
		}
		def[i] = {true, true}
		mark(&occ, lines[i], P, S)
	}

	// the implicit grid and the track index of every item
	for axis in 0 ..< 2 {
		ax := &g.ax[axis]
		lo, hi := i32(0), ax.count
		for i in 0 ..< n { lo = min(lo, lines[i][axis][0]); hi = max(hi, lines[i][axis][1]) }
		ax.off = -lo
		ax.n = hi - lo
		ax.tracks = make([]Grid_Tr, ax.n, context.temp_allocator)
		for i in 0 ..< n { g.items[i].area[axis] = lines[i][axis] + ax.off }
		// auto-fit: the repeated tracks no item is in collapse
		if ax.auto_fit && ax.rep_len > 0 {
			covered := make([]i32, ax.n + 1, context.temp_allocator)
			for i in 0 ..< n {
				ar := g.items[i].area[axis]
				covered[ar[0]] += 1
				covered[ar[1]] -= 1
			}
			run: i32
			first, end := ax.rep_first + ax.off, ax.rep_first + ax.rep_len * ax.rep_count + ax.off
			for t in 0 ..< ax.n {
				run += covered[t]
				if t >= first && t < end && run == 0 { ax.tracks[t].collapsed = true }
			}
		}
	}
	grid_build_subs(c, g)
	return g
}

// Margin, border and padding of a box on one side (percentages as 0): what a subgrid adds at its edges.
@(private)
grid_edge :: proc(c: ^Ctx, k: ^Box, s: style.Side) -> f32 {
	cs := k.cs
	m := cs.margin[s].kind == .Px ? cs.margin[s].v * c.scale : 0
	return m + px_of(c, cs.padding[s], 0) + border_px(c, cs.border_width[s])
}

// Places the subgrids among the items, and adds for each of their items a proxy that takes part in this grid's track
// sizing in the subgridded axes, the subgrid's margin, border and padding added at the edges it touches (CSS Grid 2
// §9). Subgrids of subgrids reach the outermost grid through their parent's proxies.
@(private)
grid_build_subs :: proc(c: ^Ctx, g: ^Grid) {
	gp := grid_pass(c)
	proxies := make([dynamic]Grid_Item, 0, 0, context.temp_allocator)
	for i in 0 ..< g.n_real {
		if !g.items[i].placed { continue }
		k := &c.l.boxes[g.items[i].box]
		if k.kind != .Grid || (k.cs.grid_template_columns.kind != .Subgrid && k.cs.grid_template_rows.kind != .Subgrid) { continue }
		if !stack_ok(c) { continue }
		sub := grid_build(c, g.items[i].box, grid_reps(c, g.items[i].box, {-1, -1}, true), g, i32(i))
		it := &g.items[i]
		it.sub, it.axes = sub, sub.subgrid
		gp.subs[it.box] = sub
		k = &c.l.boxes[it.box]
		edge := [2][2]f32{{grid_edge(c, k, .Left), grid_edge(c, k, .Right)}, {grid_edge(c, k, .Top), grid_edge(c, k, .Bottom)}}
		for j in 0 ..< len(sub.items) {
			sj := &sub.items[j]
			if !sj.placed { continue }
			px := Grid_Item{box = sj.box, placed = true, proxy = true, src = sub, src_i = i32(j)}
			used := false
			for axis in 0 ..< 2 {
				ok := sub.subgrid[axis] && (sj.proxy ? sj.axes[axis] : !(sj.sub != nil && sj.axes[axis]))
				px.axes[axis] = ok
				px.area[axis] = it.area[axis]
				if !ok { continue }
				used = true
				px.area[axis] = sj.area[axis] + it.area[axis][0]
				if sj.proxy { px.extra[axis] = sj.extra[axis] }
				if sj.area[axis][0] == 0 { px.extra[axis] += edge[axis][0] }
				if sj.area[axis][1] == sub.ax[axis].n { px.extra[axis] += edge[axis][1] }
			}
			if used { append(&proxies, px) }
		}
	}
	if len(proxies) == 0 { return }
	all := make([]Grid_Item, g.n_real + len(proxies), context.temp_allocator)
	copy(all, g.items[:g.n_real])
	copy(all[g.n_real:], proxies[:])
	g.items = all
}

// Copies the kinds of the parent's tracks into the subgridded axis of every subgrid (the automatic minimum of their
// items depends on them), down the nested subgrids.
@(private)
grid_sync_subs :: proc(g: ^Grid, axis: int) {
	for &it in g.items[:g.n_real] {
		if it.sub == nil || !it.axes[axis] { continue }
		sa := &it.sub.ax[axis]
		for t in 0 ..< min(sa.n, it.area[axis][1] - it.area[axis][0]) {
			src := &g.ax[axis].tracks[it.area[axis][0] + t]
			d := &sa.tracks[t]
			d.min_k, d.max_k, d.max_v, d.collapsed = src.min_k, src.max_k, src.max_v, src.collapsed
		}
		grid_sync_subs(it.sub, axis)
	}
}

// A subgridded axis takes the sizes and positions of the parent's tracks, its first and last tracks shortened by the
// subgrid's own margin, border and padding (its content box starts inside the parent's area).
@(private)
grid_sub_copy :: proc(c: ^Ctx, g: ^Grid, axis: int) {
	p := g.parent
	pit := &p.items[g.pitem]
	pa, sa := &p.ax[axis], &g.ax[axis]
	k := &c.l.boxes[g.bi]
	s := pit.area[axis][0]
	span := min(sa.n, pit.area[axis][1] - s)
	inset_s, inset_e: f32
	if axis == 0 {
		inset_s, inset_e = pit.m[3] + k.border[3] + k.padding[3], pit.m[1] + k.border[1] + k.padding[1]
		if p.rtl { inset_s, inset_e = inset_e, inset_s }
	} else {
		inset_s, inset_e = pit.m[0] + k.pre_h + k.border[0] + k.padding[0], pit.m[2] + k.border[2] + k.padding[2]
	}
	sa.gap = pa.gap
	if span <= 0 { return }
	origin := pa.tracks[s].pos + inset_s
	for t in 0 ..< span {
		src := &pa.tracks[s + t]
		d := &sa.tracks[t]
		d.min_k, d.max_k, d.max_v, d.collapsed = src.min_k, src.max_k, src.max_v, src.collapsed
		d.pos, d.base = src.pos - origin, src.base
	}
	f := &sa.tracks[0]
	f.base, f.pos = max(f.base - inset_s, 0), 0
	l := &sa.tracks[span - 1]
	l.base = max(l.base - inset_e, 0)
}

// Before the parent sizes its rows: the columns of each subgrid (the parent's, or its own sized in its width) and the
// widths of its items, whose heights the parent's row sizing then asks for.
@(private)
grid_prepare_subs :: proc(c: ^Ctx, g: ^Grid) {
	for &it in g.items[:g.n_real] {
		if it.sub == nil || !it.placed { continue }
		sub := it.sub
		k := &c.l.boxes[it.box]
		w := max(it.size.x - pb_w(k), 0)
		grid_item_margins(c, sub, w)
		for &si in sub.items { si.contrib = {{-1, -1, -1}, {-1, -1, -1}} }
		if sub.subgrid[0] {
			grid_sub_copy(c, sub, 0)
		} else {
			sub.ax[0].gap = gap_px(c, k.cs.column_gap, w)
			grid_size_axis(c, sub, 0, w, .None, -1, -1)
			grid_align_tracks(sub, 0, w, k.cs.justify_content)
		}
		grid_item_widths(c, sub)
		grid_prepare_subs(c, sub)
	}
}

// Resolves the margins (and padding, border) of the items against the container's content width.
@(private)
grid_item_margins :: proc(c: ^Ctx, g: ^Grid, cw: f32) {
	for &it in g.items[:g.n_real] {
		if !it.placed { continue }
		resolve_box_model(c, &c.l.boxes[it.box], cw)
		k := &c.l.boxes[it.box]
		it.m = k.margin
		if k.auto_t { it.m[0] = 0 }
		if k.auto_r { it.m[1] = 0 }
		if k.auto_b { it.m[2] = 0 }
		if k.auto_l { it.m[3] = 0 }
		it.ratio_dep = k.cs.aspect_ratio > 0 && k.cs.width.kind == .Auto && style.has_percent(k.cs.height)
	}
}

// Auto-repeat counts of a container for the given definite content sizes (< 0: indefinite).
@(private)
grid_reps :: proc(c: ^Ctx, bi: i32, size: Vec2, intrinsic_mode: bool) -> (reps: [2]i32) {
	b := &c.l.boxes[bi]
	cs := b.cs
	lim := i32(max(c.set.grid_max_tracks, 1))
	for axis in 0 ..< 2 {
		pb: f32
		if axis == 0 { pb = intrinsic_mode ? intrinsic_pb(c, b) : pb_w(b) } else if !intrinsic_mode { pb = pb_h(b) }
		mn, mx := grid_bounds(c, cs, axis, pb, -1)
		gap := gap_px(c, axis == 0 ? cs.column_gap : cs.row_gap, size[axis])
		reps[axis] = grid_auto_repeat(c, grid_template(cs, axis), size[axis], mn, mx, gap, lim)
	}
	return
}

////////////////////////////////
// Entry points

// The placed grid of container `bi` for the given definite content sizes (< 0: indefinite), reset for a new sizing.
@(private)
grid_prepare :: proc(c: ^Ctx, bi: i32, size: Vec2, intrinsic_mode: bool) -> ^Grid {
	gp := grid_pass(c)
	// a subgrid is placed by its parent
	g, ok := gp.subs[bi]
	if !ok {
		reps := grid_reps(c, bi, size, intrinsic_mode)
		key := Grid_Key{bi, reps, intrinsic_mode}
		g, ok = gp.placed[key]
		if !ok {
			g = grid_build(c, bi, reps)
			gp.placed[key] = g
		}
	}
	grid_reset(gp, g)
	g.rtl = is_rtl(c.l.boxes[bi].cs)
	return g
}

// Forgets the contributions computed for another sizing, down the subgrids (whose items size this grid's tracks), and
// makes this grid's subgrids the current ones.
@(private)
grid_reset :: proc(gp: ^Grid_Pass, g: ^Grid) {
	for &it in g.items {
		it.contrib = {{-1, -1, -1}, {-1, -1, -1}}
		it.shim, it.baseline = 0, -1
	}
	for &it in g.items[:g.n_real] {
		if it.sub == nil { continue }
		gp.subs[it.box] = it.sub
		grid_reset(gp, it.sub)
	}
}

// Min-content and max-content widths of a grid container's content box (§12.2 via the track sizing algorithm under a
// min-content and a max-content constraint).
@(private)
grid_intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	g := grid_prepare(c, bi, {-1, -1}, true)
	g.ax[0].gap = gap_px(c, c.l.boxes[bi].cs.column_gap, 0)
	g.ax[1].gap = 0
	res: [2]f32
	cons := [2]Grid_Constraint{.Min, .Max}
	for k in 0 ..< 2 {
		grid_size_axis(c, g, 0, -1, cons[k], -1, -1)
		res[k] = grid_tracks_total(&g.ax[0])
	}
	return {res[0], max(res[0], res[1])}
}

// Lays out grid container `bi` (content width `cw`, definite content height `ch_def` or -1). Returns the content height.
@(private)
layout_grid :: proc(c: ^Ctx, bi: i32, cw, ch_def, cb_h: f32) -> f32 {
	b := &c.l.boxes[bi]
	cs := b.cs
	g := grid_prepare(c, bi, {cw, ch_def}, false)
	grid_pass(c).last[bi] = g
	b = &c.l.boxes[bi]
	cx, cy := content_x(b), content_y(b)
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
		k := &c.l.boxes[ch]
		if .Abs in k.flags { k.static_ref = bi; k.static_pos = {cx, cy} }
	}
	g.ax[0].gap = gap_px(c, cs.column_gap, cw)
	g.ax[1].gap = gap_px(c, cs.row_gap, ch_def)
	min_h, max_h := grid_bounds(c, cs, 1, pb_h(b), cb_h)
	grid_item_margins(c, g, cw)

	// columns, then rows from the items' heights at their widths; again when a min-content width followed the rows.
	// A subgridded axis takes its parent's tracks instead.
	content_h: f32
	for pass in 0 ..< 2 {
		if g.subgrid[0] {
			grid_sub_copy(c, g, 0)
		} else {
			grid_size_axis(c, g, 0, cw, .None, -1, -1)
			grid_align_tracks(g, 0, cw, cs.justify_content)
		}
		grid_item_widths(c, g)
		grid_prepare_subs(c, g)
		grid_baseline_shims(c, g)
		if g.subgrid[1] {
			grid_sub_copy(c, g, 1)
			content_h = ch_def >= 0 ? ch_def : grid_tracks_total(&g.ax[1])
		} else {
			grid_size_axis(c, g, 1, ch_def, .None, min_h, max_h)
			content_h = ch_def
			if content_h < 0 {
				content_h = grid_tracks_total(&g.ax[1])
				if max_h >= 0 { content_h = min(content_h, max_h) }
				if min_h >= 0 { content_h = max(content_h, min_h) }
			}
			grid_align_tracks(g, 1, content_h, cs.align_content)
		}
		if pass == 1 || !grid_rows_changed_widths(c, g) { break }
	}
	g.size = {cw, content_h}
	grid_place_items(c, g, cw)
	grid_container_baselines(c, g)
	return content_h
}

// Total size of an axis's tracks and gaps (collapsed tracks and their gaps excluded).
@(private)
grid_tracks_total :: proc(ax: ^Grid_Axis) -> f32 {
	sum: f32
	nv := 0
	for &t in ax.tracks {
		if t.collapsed { continue }
		sum += t.base
		nv += 1
	}
	return sum + ax.gap * f32(max(nv - 1, 0))
}

// Track positions after content distribution (justify-content / align-content: CSS Align §5).
@(private)
grid_align_tracks :: proc(g: ^Grid, axis: int, size: f32, align: style.Content_Align) {
	ax := &g.ax[axis]
	nv: f32
	for &t in ax.tracks { if !t.collapsed { nv += 1 } }
	free := size - grid_tracks_total(ax)
	offset, between: f32
	switch align {
	case .Normal, .Stretch, .Start, .Flex_Start, .Auto, .Baseline:
	case .End, .Flex_End: offset = free
	case .Center: offset = free * 0.5
	case .Space_Between: if free > 0 && nv > 1 { between = free / (nv - 1) }
	case .Space_Around: if free > 0 && nv > 0 { between = free / nv; offset = between * 0.5 }
	case .Space_Evenly: if free > 0 { between = free / (nv + 1); offset = between }
	}
	pos := offset
	first := true
	for &t in ax.tracks {
		if t.collapsed { t.pos = pos; continue }
		if !first { pos += ax.gap + between }
		t.pos = pos
		pos += t.base
		first = false
	}
}

// Start and size of an item's grid area along an axis.
@(private)
grid_area :: proc(g: ^Grid, it: ^Grid_Item, axis: int) -> (start, size: f32) {
	tr := g.ax[axis].tracks
	a, e := it.area[axis][0], it.area[axis][1] - 1
	return tr[a].pos, tr[e].pos + tr[e].base - tr[a].pos
}

// Self-alignment of an item along an axis (CSS Align §6), `normal` resolved: stretch, except for replaced boxes, and for
// boxes with an aspect ratio in an axis their ratio sizes: the block axis (from the width), the inline axis only when the
// height is specified (else the width stretches and the height follows it: aspect-square cells fill their column, as
// in Blink).
@(private)
grid_self :: proc(c: ^Ctx, container: ^style.Computed, k: ^Box, axis: int) -> style.Content_Align {
	a := axis == 0 ? k.cs.justify_self : k.cs.align_self
	if a == .Auto { a = axis == 0 ? container.justify_items : container.align_items }
	if a == .Normal || a == .Auto {
		ratio_sized := k.cs.aspect_ratio > 0 && (axis == 1 || k.cs.height.kind != .Auto || grid_stretched_h(container, k))
		a = (k.kind == .Replaced || ratio_sized) ? .Start : .Stretch
	}
	return a
}

// Whether an item's height is stretched to its area by an explicit `stretch` (align-self or align-items): with an
// aspect ratio, its width then follows that height (Blink; an item left at `normal` keeps its width instead).
@(private)
grid_stretched_h :: proc(container: ^style.Computed, k: ^Box) -> bool {
	a := k.cs.align_self
	if a == .Auto { a = container.align_items }
	return a == .Stretch && k.cs.height.kind == .Auto && !k.auto_t && !k.auto_b
}

// Border-box width of each item in its column area.
@(private)
grid_item_widths :: proc(c: ^Ctx, g: ^Grid) {
	cs := c.l.boxes[g.bi].cs
	for &it in g.items[:g.n_real] {
		if !it.placed { continue }
		_, aw := grid_area(g, &it, 0)
		k := &c.l.boxes[it.box]
		kcs := k.cs
		avail := aw - it.m[1] - it.m[3]
		sub_axis := it.sub != nil && it.axes[0]
		w: f32
		switch {
		case k.kind == .Replaced:
			w = replaced_size(c, it.box, aw, -1).x
			if grid_self(c, cs, k, 0) == .Stretch && kcs.width.kind == .Auto && !k.auto_l && !k.auto_r { w = clamp_w(c, k, avail, aw) }
		case k.kind == .Table:
			w = table_width(c, it.box, aw, avail)
		case:
			if spec, ok := to_border_w(c, k, kcs.width, aw); ok {
				w = clamp_w(c, k, spec, aw)
				break
			}
			#partial switch kcs.width.kind {
			case .Min_Content: w = intrinsic(c, it.box)[0]
			case .Max_Content: w = intrinsic(c, it.box)[1]
			case .Fit_Content: w = shrink_to_fit(c, it.box, avail)
			case:
				// the width from a definite height through the aspect ratio (a percentage one once the rows are known)
				if it.ratio_dep || (kcs.aspect_ratio > 0 && kcs.height.kind != .Auto) {
					if h, ok := definite(c, kcs.height, grid_area_size(g, &it, 1)); ok {
						w = h * kcs.aspect_ratio + (kcs.box_sizing == .Border_Box ? 0 : pb_w(k))
						break
					}
				}
				if kcs.aspect_ratio > 0 && grid_stretched_h(cs, k) {
					if ah := grid_area_size(g, &it, 1); ah >= 0 {
						bh := max(ah - it.m[0] - it.m[2], 0)
						w = kcs.box_sizing == .Border_Box ? bh * kcs.aspect_ratio : max(bh - pb_h(k), 0) * kcs.aspect_ratio + pb_w(k)
						break
					}
				}
				// a subgrid always fills its area in a subgridded axis
				if sub_axis || (grid_self(c, cs, k, 0) == .Stretch && !k.auto_l && !k.auto_r) { w = avail } else { w = shrink_to_fit(c, it.box, avail) }
			}
			k = &c.l.boxes[it.box]
			w = clamp_w(c, k, w, aw)
			// the automatic minimum size (§6.6)
			if !sub_axis && kcs.min_width.kind == .Auto && grid_auto_min_applies(c, g, &it, 0) {
				w = max(w, grid_contrib(c, g, &it, 0, 2) - it.m[1] - it.m[3])
			}
		}
		k = &c.l.boxes[it.box]
		it.size.x = w
		it.content_h = -1
		it.contrib[1] = {-1, -1, -1}
	}
}

@(private)
grid_area_size :: proc(g: ^Grid, it: ^Grid_Item, axis: int) -> f32 {
	if len(g.ax[axis].tracks) == 0 { return -1 }
	_, s := grid_area(g, it, axis)
	return s
}

// Does a min-content width depend on the row sizes just computed? Then the columns are sized again (§11.1 step 3).
@(private)
grid_rows_changed_widths :: proc(c: ^Ctx, g: ^Grid) -> bool {
	changed := false
	cs := c.l.boxes[g.bi].cs
	for &it in g.items[:g.n_real] {
		if !it.placed { continue }
		k := &c.l.boxes[it.box]
		if k.cs.aspect_ratio > 0 && grid_stretched_h(cs, k) {
			if ah := grid_area_size(g, &it, 1); ah >= 0 {
				bh := max(ah - it.m[0] - it.m[2], 0)
				w := k.cs.box_sizing == .Border_Box ? bh * k.cs.aspect_ratio : max(bh - pb_h(k), 0) * k.cs.aspect_ratio + pb_w(k)
				w += it.m[1] + it.m[3]
				it.contrib[0] = {w, w, w}
				changed = true
			}
			continue
		}
		if !it.ratio_dep { continue }
		if h, ok := definite(c, k.cs.height, grid_area_size(g, &it, 1)); ok {
			w := h * k.cs.aspect_ratio + (k.cs.box_sizing == .Border_Box ? 0 : pb_w(k)) + it.m[1] + it.m[3]
			it.contrib[0] = {w, w, w}
			changed = true
		}
	}
	return changed
}

// Baseline alignment in the row axis: items aligned to the baseline and starting in the same row share a baseline; the
// space above each one (its shim) counts in its row contributions (§11.5 step 1).
@(private)
grid_baseline_shims :: proc(c: ^Ctx, g: ^Grid) {
	cs := c.l.boxes[g.bi].cs
	nrows := g.ax[1].n
	if nrows == 0 { return }
	best: []f32
	for &it in g.items[:g.n_real] {
		if !it.placed { continue }
		k := &c.l.boxes[it.box]
		if grid_self(c, cs, k, 1) != .Baseline || k.auto_t || k.auto_b { continue }
		h := grid_item_height(c, g, &it)
		k = &c.l.boxes[it.box]
		it.baseline = it.m[0] + k.pre_h + (k.baseline >= 0 ? k.baseline : h)
		if best == nil { best = make([]f32, nrows, context.temp_allocator) }
		r := it.area[1][0]
		best[r] = max(best[r], it.baseline)
	}
	if best == nil { return }
	for &it in g.items[:g.n_real] {
		if it.placed && it.baseline >= 0 { it.shim = best[it.area[1][0]] - it.baseline }
	}
}

// Border-box height an item's content wants at its width (laid out once per width).
@(private)
grid_item_height :: proc(c: ^Ctx, g: ^Grid, it: ^Grid_Item) -> f32 {
	if it.content_h >= 0 { return it.content_h }
	k := &c.l.boxes[it.box]
	h: f32
	if k.kind == .Replaced {
		h = replaced_size(c, it.box, grid_area_size(g, it, 0), -1).y
		layout_contents(c, it.box, it.size.x, -1, h, nil)
	} else if spec, ok := to_border_h(c, k, k.cs.height, -1); ok {
		h = clamp_h(c, k, spec, -1)
		layout_contents(c, it.box, it.size.x, -1, h, nil)
	} else {
		h = layout_contents(c, it.box, it.size.x, -1, -1, nil).h
	}
	k = &c.l.boxes[it.box]
	it.content_h = h + k.pre_h
	return it.content_h
}

// Lays out each item in its grid area and aligns it there (CSS Align §6, auto margins first).
@(private)
grid_place_items :: proc(c: ^Ctx, g: ^Grid, cw: f32) {
	b := &c.l.boxes[g.bi]
	cs := b.cs
	cx, cy := content_x(b), content_y(b)
	for &it in g.items[:g.n_real] {
		k := &c.l.boxes[it.box]
		if !it.placed {
			k.size, k.pos = {}, {cx, cy}
			continue
		}
		ax0, aw := grid_area(g, &it, 0)
		ay0, ah := grid_area(g, &it, 1)
		w := it.size.x
		// block size
		h: f32
		forced := false
		al := grid_self(c, cs, k, 1)
		sub_axis := it.sub != nil && it.axes[1]
		if sub_axis { al = .Stretch }
		if k.kind == .Replaced {
			h = replaced_size(c, it.box, aw, ah).y
			forced = true
		} else if spec, ok := to_border_h(c, k, k.cs.height, ah); ok && !sub_axis {
			h = clamp_h(c, k, spec, ah)
			forced = true
		} else if sub_axis || (al == .Stretch && !k.auto_t && !k.auto_b) {
			h = clamp_h(c, k, max(ah - it.m[0] - it.m[2] - k.pre_h, 0), ah)
			// never below the automatic minimum (the content, for a visible-overflow item)
			if !sub_axis && k.cs.min_height.kind == .Auto && grid_auto_min_applies(c, g, &it, 1) { h = max(h, grid_item_height(c, g, &it) - k.pre_h) }
			forced = true
		} else {
			h = grid_item_height(c, g, &it) - k.pre_h
		}
		k = &c.l.boxes[it.box]
		if forced {
			// a box whose content does not depend on its height keeps the layout it got at this width (when the track
			// sizing laid it out: not in fixed tracks, and not a box an incremental pass marked: laid out here)
			if k.size.x != w || k.inc != {} || depends_on_height(c, it.box) { layout_contents(c, it.box, w, ah, h, nil) }
		} else if depends_on_height(c, it.box) {
			r := layout_contents(c, it.box, w, ah, -1, nil)
			h = r.h
		}
		k = &c.l.boxes[it.box]
		k.size = {w, h}
		outer_h := h + k.pre_h

		// inline axis: logical start margin first
		ms, me := it.m[3], it.m[1]
		as_, ae := k.auto_l, k.auto_r
		if g.rtl { ms, me, as_, ae = me, ms, ae, as_ }
		free_x := aw - w - ms - me
		x: f32
		if as_ || ae {
			f := max(free_x, 0)
			if as_ && ae { ms += f * 0.5; me += f * 0.5 } else if as_ { ms += f } else { me += f }
			x = ms
		} else {
			#partial switch grid_self(c, cs, k, 0) {
			case .End, .Flex_End: x = free_x + ms
			case .Center: x = free_x * 0.5 + ms
			case: x = ms
			}
		}
		px := ax0 + x
		if g.rtl {
			px = cw - px - w
			k.margin[1], k.margin[3] = ms, me
		} else {
			k.margin[3], k.margin[1] = ms, me
		}

		// block axis
		mt, mb := it.m[0], it.m[2]
		free_y := ah - outer_h - mt - mb
		y: f32
		if k.auto_t || k.auto_b {
			f := max(free_y, 0)
			if k.auto_t && k.auto_b { mt += f * 0.5; mb += f * 0.5 } else if k.auto_t { mt += f } else { mb += f }
			y = mt
		} else {
			#partial switch al {
			case .End, .Flex_End: y = free_y + mt
			case .Center: y = free_y * 0.5 + mt
			case .Baseline: y = mt + it.shim
			case: y = mt
			}
		}
		k.margin[0], k.margin[2] = mt, mb
		k.pos = {cx + px, cy + ay0 + y + k.pre_h}
	}
}

// First and last baselines of the container: those of the first / last row's items (a baseline-aligned one preferred,
// else the first in grid order), synthesized from the border box when the item has none (CSS Grid 1, grid container
// baselines).
@(private)
grid_container_baselines :: proc(c: ^Ctx, g: ^Grid) {
	b := &c.l.boxes[g.bi]
	b.baseline, b.last_baseline = -1, -1
	first, last := -1, -1
	better :: proc(g: ^Grid, a, cur: int, last: bool) -> bool {
		if cur < 0 { return true }
		x, y := &g.items[a], &g.items[cur]
		if last {
			if x.area[1][1] != y.area[1][1] { return x.area[1][1] > y.area[1][1] }
		} else if x.area[1][0] != y.area[1][0] { return x.area[1][0] < y.area[1][0] }
		if (x.baseline >= 0) != (y.baseline >= 0) { return x.baseline >= 0 }
		return last ? x.area[0][0] > y.area[0][0] : x.area[0][0] < y.area[0][0]
	}
	for &it, i in g.items[:g.n_real] {
		if !it.placed { continue }
		if better(g, i, first, false) { first = i }
		if better(g, i, last, true) { last = i }
	}
	of :: proc(c: ^Ctx, it: ^Grid_Item) -> f32 {
		k := &c.l.boxes[it.box]
		return k.pos.y + (k.baseline >= 0 ? k.baseline : k.size.y)
	}
	b = &c.l.boxes[g.bi]
	if first >= 0 { b.baseline = of(c, &g.items[first]) }
	if last >= 0 { b.last_baseline = of(c, &g.items[last]) }
}

// Absolutely positioned boxes whose containing block is grid container `cbi`: the containing block is the grid area
// their placement lines give, a missing line being the padding edge (§9.1). Replaces layout_abs_list for grids.
@(private)
grid_abs :: proc(c: ^Ctx, cbi: i32) {
	gp := grid_pass(c)
	g, ok := gp.last[cbi]
	if !ok { layout_abs_list(c, cbi); return }
	cb := &c.l.boxes[cbi]
	pad := Rect{{cb.border[3], cb.border[0]}, cb.size - {cb.border[1], cb.border[2]}}
	cx, cy := content_x(cb), content_y(cb)
	origin := Vec2{cx, cy}
	for a := cb.abs_first; a != NONE; a = c.l.boxes[a].abs_next {
		ab := &c.l.boxes[a]
		if .Fixed in ab.flags { layout_abs(c, a, cbi, Rect{{0, 0}, c.vp}); continue }
		r := pad
		ks := ab.cs
		for axis in 0 ..< 2 {
			ax := &g.ax[axis]
			s, e := axis == 0 ? ks.grid_column_start : ks.grid_row_start, axis == 0 ? ks.grid_column_end : ks.grid_row_end
			la, lb, ha, hb := grid_resolve_abs(ax, s, e)
			ta, tb := la + ax.off, lb + ax.off
			// a line outside the implicit grid is auto
			if ha && (ta < 0 || ta > ax.n) { ha = false }
			if hb && (tb < 0 || tb > ax.n) { hb = false }
			lo, hi := pad.min[axis], pad.max[axis]
			if axis == 0 && g.rtl {
				// columns run from the right edge of the content box
				if ha { hi = origin.x + g.size.x - grid_line_pos(ax, ta, false) }
				if hb { lo = origin.x + g.size.x - grid_line_pos(ax, tb, true) }
			} else {
				if ha { lo = origin[axis] + grid_line_pos(ax, ta, false) }
				if hb { hi = origin[axis] + grid_line_pos(ax, tb, true) }
			}
			r.min[axis], r.max[axis] = lo, max(hi, lo)
		}
		layout_abs(c, a, cbi, r)
	}
}

// Position of line `t` (track index) from the content box start: the start of track t, or (as an end edge) the end of
// track t - 1.
@(private)
grid_line_pos :: proc(ax: ^Grid_Axis, t: i32, end: bool) -> f32 {
	n := i32(len(ax.tracks))
	if n == 0 { return 0 }
	if end && t > 0 { return ax.tracks[t - 1].pos + ax.tracks[t - 1].base }
	if t < n { return ax.tracks[t].pos }
	return ax.tracks[n - 1].pos + ax.tracks[n - 1].base
}
