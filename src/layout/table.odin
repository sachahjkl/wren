package layout

import "core:math"
import "wb:base"
import "wb:dom"
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
				// the table's width in columns is bounded (layout.table.max_columns): cells past it share the last column
				maxc := i32(max(c.set.table_max_columns, 1))
				if col >= maxc { col, cs = maxc - 1, 1 } else { cs = min(cs, maxc - col) }
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
	// whole device pixels, as in Chromium (which keeps the zoomed spacing as an integer): the UA's 2px is 3 device px
	// at 175 %, not 3.5, and rows land where Chrome and Edge put them
	return math.floor(cs.border_spacing[0] * c.scale), math.floor(cs.border_spacing[1] * c.scale)
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

// What the columns ask for: min-content and max-content widths, and the kind of width they were given (by a cell of
// the column or a <col>): a length (`fixed`, max-content becomes that width) or a percentage of the table (`pct`).
@(private)
Column_Extents :: struct {
	mins, maxs: []f32,
	fixed:      []bool,
	pct:        []f32,   // 0..100, their sum at most 100 (later columns lose what is over)
}

@(private)
column_extents :: proc(c: ^Ctx, bi: i32, g: ^Table_Grid, base: f32) -> (mins, maxs: []f32) {
	e := column_info(c, bi, g, base)
	return e.mins, e.maxs
}

@(private)
column_info :: proc(c: ^Ctx, bi: i32, g: ^Table_Grid, base: f32) -> Column_Extents {
	n := int(g.ncols)
	mins := make([]f32, n, context.temp_allocator)
	maxs := make([]f32, n, context.temp_allocator)
	fixed := make([]bool, n, context.temp_allocator)
	pct := make([]f32, n, context.temp_allocator)
	spec := make([]f32, n, context.temp_allocator)   // the widest length given to a fixed column (border-box)
	sh, _ := spacing_of(c, c.l.boxes[bi].cs)
	collapse := c.l.boxes[bi].cs.border_collapse
	// <col> / <colgroup> widths (they make no boxes: read from their elements' styles)
	column_widths(c, bi, n, fixed, pct, spec)
	for pass in 0 ..< 2 {
		for &gc in g.cells {
			if (pass == 0) != (gc.cs == 1) { continue }
			resolve_cell(c, gc.box, base, collapse)
			in2 := intrinsic(c, gc.box)
			if gc.cs == 1 {
				mins[gc.col] = max(mins[gc.col], in2[0])
				maxs[gc.col] = max(maxs[gc.col], in2[1])
				k := &c.l.boxes[gc.box]
				#partial switch k.cs.width.kind {
				case .Px:
					v := k.cs.width.v * c.scale
					pb := intrinsic_pb(c, k)
					fixed[gc.col] = true
					spec[gc.col] = max(spec[gc.col], k.cs.box_sizing == .Border_Box ? max(v, pb) : v + pb)
				case .Percent:
					pct[gc.col] = max(pct[gc.col], k.cs.width.v)
				}
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
		if pass == 0 {
			// a column given a length is as wide as that length (never below its content's minimum)
			for j in 0 ..< n {
				if fixed[j] && pct[j] == 0 { maxs[j] = max(mins[j], spec[j]) }
			}
		}
	}
	room: f32 = 100
	for &p in pct {
		p = clamp(p, 0, room)
		room -= p
	}
	for j in 0 ..< n { maxs[j] = max(maxs[j], mins[j]) }
	return {mins, maxs, fixed, pct}
}

// Widths given by the table's <col> and <colgroup> elements (a <col span>, a <colgroup span> without <col>).
@(private)
column_widths :: proc(c: ^Ctx, bi: i32, n: int, fixed: []bool, pct: []f32, spec: []f32) {
	tn := dom.get(c.d, c.l.boxes[bi].node)
	if tn == nil { return }
	col := 0
	apply :: proc(c: ^Ctx, h: base.Handle, at, span, n: int, fixed: []bool, pct: []f32, spec: []f32) {
		cs := style.style_of(c.st, h)
		if cs == nil || cs.display == .None { return }
		for j in at ..< min(at + span, n) {
			#partial switch cs.width.kind {
			case .Px: fixed[j] = true; spec[j] = max(spec[j], cs.width.v * c.scale)
			case .Percent: pct[j] = max(pct[j], cs.width.v)
			}
		}
	}
	span_of :: proc(c: ^Ctx, h: base.Handle) -> int {
		v, ok := dom.get_attribute(c.d, h, "span")
		if !ok { return 1 }
		return clamp(parse_int(v, 1), 1, 1000)
	}
	for ch := tn.first_child; ch != base.NIL_HANDLE && col < n; ch = dom.get(c.d, ch).next {
		cn := dom.get(c.d, ch)
		if cn.kind != .Element { continue }
		switch cn.name {
		case "col":
			s := span_of(c, ch)
			apply(c, ch, col, s, n, fixed, pct, spec)
			col += s
		case "colgroup":
			has_cols := false
			for g := cn.first_child; g != base.NIL_HANDLE && col < n; g = dom.get(c.d, g).next {
				gn := dom.get(c.d, g)
				if gn.kind != .Element || gn.name != "col" { continue }
				has_cols = true
				s := span_of(c, g)
				apply(c, g, col, s, n, fixed, pct, spec)
				col += s
			}
			if !has_cols {
				s := span_of(c, ch)
				apply(c, ch, col, s, n, fixed, pct, spec)
				col += s
			}
		}
	}
}

// Column widths for `avail` (CSS Tables 3 §3.9.4, as browsers do): between the guesses min-content, min-content with
// percentages, with specified widths, and max-content, linearly; past max-content the excess goes to the automatic
// columns (by their max-content widths), else to the fixed ones, else to the percentage ones.
@(private)
distribute_columns :: proc(e: Column_Extents, avail: f32, widths: []f32) {
	n := len(widths)
	guess :: proc(e: Column_Extents, avail: f32, i, stage: int) -> f32 {
		if e.pct[i] > 0 {
			if stage == 0 { return e.mins[i] }
			return max(e.mins[i], e.pct[i] * avail / 100)
		}
		switch stage {
		case 0, 1: return e.mins[i]
		case 2: return e.fixed[i] ? e.maxs[i] : e.mins[i]
		}
		return e.maxs[i]
	}
	sums: [4]f32
	for s in 0 ..< 4 { for i in 0 ..< n { sums[s] += guess(e, avail, i, s) } }
	if avail <= sums[0] {
		for i in 0 ..< n { widths[i] = e.mins[i] }
		return
	}
	for s in 1 ..< 4 {
		if avail <= sums[s] {
			t := sums[s] > sums[s - 1] ? (avail - sums[s - 1]) / (sums[s] - sums[s - 1]) : 1
			for i in 0 ..< n {
				a, b := guess(e, avail, i, s - 1), guess(e, avail, i, s)
				widths[i] = a + (b - a) * t
			}
			return
		}
	}
	for i in 0 ..< n { widths[i] = guess(e, avail, i, 3) }
	extra := avail - sums[3]
	// who takes the rest: automatic columns, else fixed ones, else percentage ones, else all
	pick :: proc(e: Column_Extents, i, kind: int) -> bool {
		switch kind {
		case 0: return e.pct[i] == 0 && !e.fixed[i]
		case 1: return e.pct[i] == 0 && e.fixed[i]
		case 2: return e.pct[i] > 0
		}
		return true
	}
	for kind in 0 ..< 4 {
		weight, count: f32
		for i in 0 ..< n {
			if !pick(e, i, kind) { continue }
			count += 1
			weight += kind == 2 ? e.pct[i] : widths[i]
		}
		if count == 0 { continue }
		for i in 0 ..< n {
			if !pick(e, i, kind) { continue }
			share := weight > 0 ? (kind == 2 ? e.pct[i] : widths[i]) / weight : 1 / count
			widths[i] += extra * share
		}
		return
	}
}

@(private)
table_pb :: proc(c: ^Ctx, b: ^Box) -> f32 { return intrinsic_pb(c, b) }

// table-layout: fixed (CSS 2.1 §17.5.2.1) applies to a table whose width is not auto: the columns' widths come from the
// <col> elements and the cells of the first row, never from the content (what does not fit is clipped or overflows),
// and the automatic columns share what is left equally.
@(private)
table_is_fixed :: proc(b: ^Box) -> bool {
	#partial switch b.cs.width.kind {
	case .Px, .Percent, .Calc: return b.cs.table_layout == .Fixed
	}
	return false
}

// The widths a fixed table's columns were given: a length (border-box, px; -1 when none) or a percentage of the table
// (0 when none). A <col> wins over a cell of the first row; a cell that spans columns gives each its share.
@(private)
fixed_column_specs :: proc(c: ^Ctx, bi: i32, g: ^Table_Grid, base: f32) -> (spec, pct: []f32) {
	n := int(g.ncols)
	fixed := make([]bool, n, context.temp_allocator)
	pct = make([]f32, n, context.temp_allocator)
	spec = make([]f32, n, context.temp_allocator)
	sh, _ := spacing_of(c, c.l.boxes[bi].cs)
	collapse := c.l.boxes[bi].cs.border_collapse
	column_widths(c, bi, n, fixed, pct, spec)
	given := make([]bool, n, context.temp_allocator)
	for j in 0 ..< n { given[j] = fixed[j] || pct[j] > 0 }
	for &gc in g.cells {
		if gc.row != 0 { continue }
		resolve_cell(c, gc.box, base, collapse)
		k := &c.l.boxes[gc.box]
		end := min(int(gc.col + gc.cs), n)
		span := f32(end - int(gc.col))
		#partial switch k.cs.width.kind {
		case .Px:
			v := k.cs.width.v * c.scale
			pb := intrinsic_pb(c, k)
			w := k.cs.box_sizing == .Border_Box ? max(v, pb) : v + pb
			share := max(w - sh * (span - 1), 0) / span
			for j in int(gc.col) ..< end {
				if given[j] { continue }
				fixed[j], spec[j] = true, share
			}
		case .Percent:
			for j in int(gc.col) ..< end {
				if given[j] { continue }
				pct[j] = k.cs.width.v / span
			}
		}
	}
	for j in 0 ..< n { if !fixed[j] || pct[j] > 0 { spec[j] = -1 } }
	return
}

// A fixed table's column widths for `avail` (the table's width less the spacing).
@(private)
fixed_column_widths :: proc(spec, pct: []f32, avail: f32, widths: []f32) {
	n := len(widths)
	known: f32
	autos := 0
	room: f32 = 100
	for j in 0 ..< n {
		switch {
		case spec[j] >= 0: widths[j] = spec[j]
		case pct[j] > 0:
			p := clamp(pct[j], 0, room)
			room -= p
			widths[j] = p * avail / 100
		case:
			widths[j] = -1
			autos += 1
			continue
		}
		known += widths[j]
	}
	left := max(avail - known, 0)
	if autos > 0 {
		for j in 0 ..< n { if widths[j] < 0 { widths[j] = left / f32(autos) } }
		return
	}
	// every column was given a width: the table's width is what they ask for, or more: the excess is shared by them
	if left > 0 && known > 0 {
		for j in 0 ..< n { widths[j] += left * widths[j] / known }
	} else if left > 0 && n > 0 {
		for j in 0 ..< n { widths[j] = left / f32(n) }
	}
}

table_intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	g := table_grid(c, bi)
	b := &c.l.boxes[bi]
	sh, _ := spacing_of(c, b.cs)
	if table_is_fixed(b) {
		// the columns given a length: what a fixed table asks for, whatever its content
		spec, _ := fixed_column_specs(c, bi, &g, 0)
		pb := table_pb(c, b)
		if b.cs.border_collapse { pb -= px_of(c, b.cs.padding[.Left], 0) + px_of(c, b.cs.padding[.Right], 0) }
		total := pb + sh * f32(g.ncols + 1)
		for v in spec { total += max(v, 0) }
		for cap in g.captions { total = max(total, intrinsic(c, cap)[0]) }
		return {total, total}
	}
	e := column_info(c, bi, &g, 0)
	pb := table_pb(c, b)
	if b.cs.border_collapse { pb -= px_of(c, b.cs.padding[.Left], 0) + px_of(c, b.cs.padding[.Right], 0) }
	mn := pb + sh * f32(g.ncols + 1)
	mx := mn
	for v in e.mins { mn += v }
	// max-content: wide enough that percentage columns get their share of the columns' width with their content
	// whole, and the others theirs (as browsers compute it; capped)
	TABLE_MAX :: 1_000_000
	sum_max, non_pct, room: f32 = 0, 0, 100
	need: f32 = 0
	for v, i in e.maxs {
		sum_max += v
		if e.pct[i] > 0 {
			need = max(need, v * 100 / e.pct[i])
			room -= e.pct[i]
		} else {
			non_pct += v
		}
	}
	if non_pct > 0 { need = max(need, room > 0.01 ? non_pct * 100 / room : TABLE_MAX) }
	mx += min(max(sum_max, need), TABLE_MAX * c.scale)
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
	if k.marker_w != 0 { k.marker_pos.y += dy }   // set by each layout of a list item only: do not accumulate otherwise
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

	// column widths
	widths := make([]f32, n, context.temp_allocator)
	if table_is_fixed(b) {
		spec, pct := fixed_column_specs(c, bi, &g, cw)
		fixed_column_widths(spec, pct, cw - sh * f32(n + 1), widths)
	} else {
		e := column_info(c, bi, &g, cw)
		distribute_columns(e, cw - sh * f32(n + 1), widths)
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
	cell_content := make([]f32, len(g.cells), context.temp_allocator)   // what vertical-align moves: without the specified height
	for &gc, i in g.cells {
		end := min(int(gc.col + gc.cs), n)
		cwid := col_x[end] - sh - col_x[gc.col]
		resolve_cell(c, gc.box, cw, collapse)
		r := layout_contents(c, gc.box, max(cwid, 0), -1, -1, nil)
		// (a cell's height is a minimum: content taller than it makes the row taller, CSS 2.1 §17.5.3)
		k := &c.l.boxes[gc.box]
		cell_content[i] = k.tmp + pb_h(k)
		cell_h[i] = max(r.h, cell_content[i])
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
		content := cell_content[i]
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
