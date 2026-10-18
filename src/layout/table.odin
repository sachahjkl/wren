package layout

import "wb:style"

// Tables (CSS 2.1 §17, automatic table layout §17.5.2.2): a slot grid with colspan / rowspan, column widths from the
// cells' min-content / max-content widths (spanning cells spread their excess), distribution of the table width between
// the minimum and maximum, row heights, vertical-align in cells, border-spacing, captions above the table. With
// border-collapse the spacing is zero and inner cell borders are not doubled (each cell drops its left / top border
// next to a neighbour): a simplification of the collapsing border model.

@(private)
Grid_Cell :: struct { box: i32, row, col, rs, cs: i32 }

@(private)
Table_Grid :: struct {
	rows:     [dynamic]i32,
	groups:   [dynamic]i32,
	group_end: [dynamic]i32,    // per group: index past its last row
	cells:    [dynamic]Grid_Cell,
	captions: [dynamic]i32,
	ncols:    i32,
}

@(private)
table_grid :: proc(c: ^Ctx, bi: i32) -> Table_Grid {
	g := Table_Grid{
		rows = make([dynamic]i32, context.temp_allocator), groups = make([dynamic]i32, context.temp_allocator),
		group_end = make([dynamic]i32, context.temp_allocator), cells = make([dynamic]Grid_Cell, context.temp_allocator),
		captions = make([dynamic]i32, context.temp_allocator),
	}
	b := &c.l.boxes[bi]
	heads := make([dynamic]i32, context.temp_allocator)
	bodies := make([dynamic]i32, context.temp_allocator)
	foots := make([dynamic]i32, context.temp_allocator)
	for ch := b.first; ch != NONE; ch = c.l.boxes[ch].next {
		k := &c.l.boxes[ch]
		if .Abs in k.flags { k.static_ref = bi; k.static_pos = {content_x(b), content_y(b)}; continue }
		#partial switch k.kind {
		case .Caption: append(&g.captions, ch)
		case .Row_Group:
			#partial switch k.cs.display {
			case .Table_Header_Group: if len(heads) == 0 { append(&heads, ch) } else { append(&bodies, ch) }
			case .Table_Footer_Group: if len(foots) == 0 { append(&foots, ch) } else { append(&bodies, ch) }
			case: append(&bodies, ch)
			}
		}
	}
	append(&g.groups, ..heads[:])
	append(&g.groups, ..bodies[:])
	append(&g.groups, ..foots[:])
	busy := make([dynamic]i32, context.temp_allocator)   // per column: first row index that is free again
	for grp in g.groups {
		first_row := i32(len(g.rows))
		for r := c.l.boxes[grp].first; r != NONE; r = c.l.boxes[r].next {
			if c.l.boxes[r].kind == .Row { append(&g.rows, r) }
		}
		end := i32(len(g.rows))
		append(&g.group_end, end)
		for ri in first_row ..< end {
			col: i32 = 0
			for cell := c.l.boxes[g.rows[ri]].first; cell != NONE; cell = c.l.boxes[cell].next {
				k := &c.l.boxes[cell]
				if k.kind != .Cell { continue }
				for int(col) < len(busy) && busy[col] > ri { col += 1 }
				rs := k.rowspan
				if rs == 0 || ri + rs > end { rs = end - ri }
				cs := k.colspan
				k.row, k.col = ri, col
				append(&g.cells, Grid_Cell{cell, ri, col, max(rs, 1), cs})
				for j in col ..< col + cs {
					for int(j) >= len(busy) { append(&busy, 0) }
					busy[j] = ri + max(rs, 1)
				}
				col += cs
				g.ncols = max(g.ncols, col)
			}
		}
		// spans never reach into the next group
		for &x in busy { x = min(x, end) }
	}
	return g
}

@(private)
spacing_of :: proc(c: ^Ctx, cs: ^style.Computed) -> (h, v: f32) {
	if cs.border_collapse { return 0, 0 }
	return cs.border_spacing[0] * c.scale, cs.border_spacing[1] * c.scale
}

// Cell edges: collapsed tables keep one border between neighbours.
@(private)
resolve_cell :: proc(c: ^Ctx, cell: i32, base: f32, collapse: bool) {
	k := &c.l.boxes[cell]
	resolve_box_model(c, k, base)
	if collapse {
		if k.col > 0 { k.border[3] = 0 }
		if k.row > 0 { k.border[0] = 0 }
	}
	for i in 0 ..< 4 { k.margin[i] = 0 }
}

@(private)
column_extents :: proc(c: ^Ctx, bi: i32, g: ^Table_Grid, base: f32) -> (mins, maxs: []f32) {
	n := int(g.ncols)
	mins = make([]f32, n, context.temp_allocator)
	maxs = make([]f32, n, context.temp_allocator)
	sh, _ := spacing_of(c, c.l.boxes[bi].cs)
	collapse := c.l.boxes[bi].cs.border_collapse
	for pass in 0 ..< 2 {
		for &gc in g.cells {
			if (pass == 0) != (gc.cs == 1) { continue }
			resolve_cell(c, gc.box, base, collapse)
			in2 := intrinsic(c, gc.box)
			if gc.cs == 1 {
				mins[gc.col] = max(mins[gc.col], in2[0])
				maxs[gc.col] = max(maxs[gc.col], in2[1])
				continue
			}
			// a spanning cell spreads what the columns lack, in proportion to their maximum widths
			end := min(int(gc.col + gc.cs), n)
			span_sp := sh * f32(gc.cs - 1)
			have_min, have_max: f32
			for j in int(gc.col) ..< end { have_min += mins[j]; have_max += maxs[j] }
			need_min := in2[0] - span_sp - have_min
			need_max := in2[1] - span_sp - have_max
			cnt := f32(end - int(gc.col))
			for j in int(gc.col) ..< end {
				share := have_max > 0 ? maxs[j] / have_max : 1 / cnt
				if need_min > 0 { mins[j] += need_min * share }
				if need_max > 0 { maxs[j] += need_max * share }
				maxs[j] = max(maxs[j], mins[j])
			}
		}
	}
	return
}

@(private)
table_pb :: proc(c: ^Ctx, b: ^Box) -> f32 { return intrinsic_pb(c, b) }

table_intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	g := table_grid(c, bi)
	mins, maxs := column_extents(c, bi, &g, 0)
	b := &c.l.boxes[bi]
	sh, _ := spacing_of(c, b.cs)
	pb := table_pb(c, b)
	if b.cs.border_collapse { pb -= px_of(c, b.cs.padding[.Left], 0) + px_of(c, b.cs.padding[.Right], 0) }
	mn := pb + sh * f32(g.ncols + 1)
	mx := mn
	for v in mins { mn += v }
	for v in maxs { mx += v }
	for cap in g.captions {
		in2 := intrinsic(c, cap)
		mn = max(mn, in2[0])
	}
	if b.cs.width.kind == .Px {
		v := b.cs.width.v * c.scale
		w := b.cs.box_sizing == .Border_Box ? v : v + pb
		mn = max(mn, w)
		mx = mn
	}
	return {mn, max(mx, mn)}
}

// Used border-box width of a table (§17.5.2.2): never below its minimum; auto: as wide as its content wants, within
// the available width.
table_width :: proc(c: ^Ctx, bi: i32, cb_w, avail: f32) -> f32 {
	in2 := intrinsic(c, bi)
	b := &c.l.boxes[bi]
	w: f32
	if spec, ok := to_border_w(c, b, b.cs.width, cb_w); ok {
		w = max(spec, in2[0])
	} else {
		w = max(in2[0], min(avail, in2[1]))
	}
	if b.cs.max_width.kind != .None {
		if mx, ok := to_border_w(c, b, b.cs.max_width, cb_w); ok { w = max(min(w, mx), in2[0]) }
	}
	if mn, ok := to_border_w(c, b, b.cs.min_width, cb_w); ok { w = max(w, mn) }
	return w
}

// Moves the content of a cell down by `dy` (vertical-align).
@(private)
shift_contents :: proc(c: ^Ctx, cell: i32, dy: f32) {
	if dy == 0 { return }
	k := &c.l.boxes[cell]
	stack := make([dynamic]i32, 0, 8, context.temp_allocator)
	for ch := k.first; ch != NONE; ch = c.l.boxes[ch].next { append(&stack, ch) }
	for len(stack) > 0 {
		x := pop(&stack)
		xb := &c.l.boxes[x]
		if xb.pos_ref == cell { xb.pos.y += dy }
		if xb.kind == .Inline { for ch := xb.first; ch != NONE; ch = c.l.boxes[ch].next { append(&stack, ch) } }
	}
	for a := k.abs_first; a != NONE; a = c.l.boxes[a].abs_next {
		if c.l.boxes[a].pos_ref == cell { c.l.boxes[a].pos.y += dy }
	}
	for li in k.lines[0] ..< k.lines[1] {
		ln := &c.l.lines[li]
		ln.y += dy
		for fi in ln.frags[0] ..< ln.frags[1] {
			c.l.frags[fi].y += dy
			c.l.frags[fi].baseline += dy
		}
	}
	if k.baseline >= 0 { k.baseline += dy }
	if k.last_baseline >= 0 { k.last_baseline += dy }
	k.marker_pos.y += dy
}

// Lays out a table at border-box width `w`; returns the border-box height of the table grid. Captions go above it
// (`pre_h`).
@(private)
layout_table :: proc(c: ^Ctx, bi: i32, w, cb_h, forced_h: f32) -> f32 {
	g := table_grid(c, bi)
	b := &c.l.boxes[bi]
	cs := b.cs
	collapse := cs.border_collapse
	sh, sv := spacing_of(c, cs)
	cx, cy := content_x(b), content_y(b)
	cw := max(w - pb_w(b), 0)
	n := int(g.ncols)
	mins, maxs := column_extents(c, bi, &g, cw)

	// column widths
	widths := make([]f32, n, context.temp_allocator)
	avail := cw - sh * f32(n + 1)
	sum_min, sum_max: f32
	for i in 0 ..< n { sum_min += mins[i]; sum_max += maxs[i] }
	for i in 0 ..< n {
		switch {
		case avail >= sum_max:
			extra := avail - sum_max
			widths[i] = maxs[i] + (sum_max > 0 ? extra * maxs[i] / sum_max : extra / f32(n))
		case avail > sum_min && sum_max > sum_min:
			t := (avail - sum_min) / (sum_max - sum_min)
			widths[i] = mins[i] + (maxs[i] - mins[i]) * t
		case:
			widths[i] = mins[i]
		}
	}
	col_x := make([]f32, n + 1, context.temp_allocator)
	{
		x := cx + sh
		for i in 0 ..< n { col_x[i] = x; x += widths[i] + sh }
		col_x[n] = x
	}

	// cells at their widths, then row heights
	nr := len(g.rows)
	heights := make([]f32, nr, context.temp_allocator)
	for r, i in g.rows {
		rb := &c.l.boxes[r]
		resolve_box_model(c, rb, cw)
		if h, ok := definite(c, rb.cs.height, -1); ok { heights[i] = h }
	}
	cell_h := make([]f32, len(g.cells), context.temp_allocator)
	for &gc, i in g.cells {
		end := min(int(gc.col + gc.cs), n)
		cwid := col_x[end] - sh - col_x[gc.col]
		resolve_cell(c, gc.box, cw, collapse)
		r := layout_contents(c, gc.box, max(cwid, 0), -1, -1, nil)
		cell_h[i] = r.h
		if gc.rs == 1 { heights[gc.row] = max(heights[gc.row], r.h) }
	}
	for &gc, i in g.cells {
		if gc.rs == 1 { continue }
		have := sv * f32(gc.rs - 1)
		for r in gc.row ..< gc.row + gc.rs { have += heights[r] }
		if cell_h[i] > have { heights[gc.row + gc.rs - 1] += cell_h[i] - have }
	}
	content_h := sv
	for h in heights { content_h += h + sv }
	if nr == 0 { content_h = 0 }
	target := forced_h
	if target < 0 {
		if spec, ok := to_border_h(c, b, cs.height, cb_h); ok { target = spec }
	}
	if target >= 0 && target - pb_h(b) > content_h && nr > 0 {
		extra := (target - pb_h(b) - content_h) / f32(nr)
		for &h in heights { h += extra }
		content_h = target - pb_h(b)
	}
	row_y := make([]f32, nr + 1, context.temp_allocator)
	{
		y := cy + sv
		for i in 0 ..< nr { row_y[i] = y; y += heights[i] + sv }
		row_y[nr] = y
	}

	// groups, rows, cells
	for grp, k in g.groups {
		first := k == 0 ? 0 : int(g.group_end[k - 1])
		end := int(g.group_end[k])
		top := first < nr ? row_y[first] : cy
		bottom := end > first ? row_y[end - 1] + heights[end - 1] : top
		gb := &c.l.boxes[grp]
		gb.pos = {cx, top}
		gb.size = {cw, bottom - top}
		for ri in first ..< end {
			rb := &c.l.boxes[g.rows[ri]]
			rb.pos = {0, row_y[ri] - top}
			rb.size = {cw, heights[ri]}
		}
	}
	// baselines per row, then each cell takes its rows' height and aligns its content
	row_base := make([]f32, nr, context.temp_allocator)
	for &x in row_base { x = -1 }
	for &gc in g.cells {
		k := &c.l.boxes[gc.box]
		if k.cs.vertical_align.kind == .Baseline && k.baseline >= 0 { row_base[gc.row] = max(row_base[gc.row], k.baseline) }
	}
	for &gc, i in g.cells {
		k := &c.l.boxes[gc.box]
		span_h := row_y[gc.row + gc.rs - 1] + heights[gc.row + gc.rs - 1] - row_y[gc.row]
		k.pos = {col_x[gc.col] - cx, 0}
		content := cell_h[i]
		k.size.y = span_h
		k.cache_ok = false
		dy: f32
		#partial switch k.cs.vertical_align.kind {
		case .Middle: dy = (span_h - content) * 0.5
		case .Bottom: dy = span_h - content
		case .Baseline:
			if k.baseline >= 0 && row_base[gc.row] >= 0 { dy = row_base[gc.row] - k.baseline }
		}
		shift_contents(c, gc.box, max(dy, 0))
	}

	// captions
	b = &c.l.boxes[bi]
	pre: f32
	for cap in g.captions {
		resolve_box_model(c, &c.l.boxes[cap], w)
		kb := &c.l.boxes[cap]
		if kb.auto_l { kb.margin[3] = 0 }
		if kb.auto_r { kb.margin[1] = 0 }
		cwid := max(w - mg_w(kb), 0)
		r := layout_contents(c, cap, cwid, -1, -1, nil)
		kb = &c.l.boxes[cap]
		pre += kb.margin[0]
		kb.pos = {kb.margin[3], pre}
		pre += r.h + kb.margin[2]
	}
	for cap in g.captions { c.l.boxes[cap].pos.y -= pre }
	b = &c.l.boxes[bi]
	b.pre_h = pre
	b.baseline = -1
	if nr > 0 {
		if row_base[0] >= 0 { b.baseline = row_y[0] + row_base[0] } else { b.baseline = row_y[0] + heights[0] }
	}
	b.last_baseline = b.baseline
	return content_h + pb_h(b)
}
