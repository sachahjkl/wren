package canvas2d

import "core:math"

Line_Cap :: enum u8 { Butt, Round, Square }
Line_Join :: enum u8 { Miter, Round, Bevel }

Stroke_Style :: struct {
	width:       f64,
	cap:         Line_Cap,
	join:        Line_Join,
	miter_limit: f64,
	dash:        []f64,   // even length, positive entries (the API has normalized it); empty: solid
	dash_offset: f64,
	max_dashes:  int,     // a dashed path that would need more pieces is drawn solid
}

// Closed polygons in device space: the stroke of a path as the union of simple pieces (one quad per segment, one wedge
// per join, one cap per end), every piece wound the same way so that the nonzero rule fills their union.
Polys :: struct {
	pts:  [dynamic][2]f64,
	ends: [dynamic]int,   // polygon k is pts[ends[k-1]:ends[k]]
}

polys_destroy :: proc(p: ^Polys) {
	delete(p.pts)
	delete(p.ends)
	p^ = {}
}

polys_clear :: proc(p: ^Polys) {
	clear(&p.pts)
	clear(&p.ends)
}

@(private)
Stroker :: struct {
	out:   ^Polys,
	ctm:   Matrix,
	hw:    f64,
	style: ^Stroke_Style,
	step:  f64,           // angle step of round joins and caps
	area_sign: f64,       // orientation the pieces are brought to, in user space
	scratch: [dynamic][2]f64,
}

// Stroke of the polylines of `flat` (device space, as drawn under `ctm`): the stroke is computed in user space, where
// the line width is round, then mapped back. `tol` is the flatness tolerance in device pixels for round parts.
polys_stroke :: proc(flat: ^Flat, ctm: Matrix, style: ^Stroke_Style, tol: f64, out: ^Polys) {
	inv, ok := matrix_invert(ctm)
	if !ok || !(style.width > 0) || !is_finite(style.width) { return }
	big, _ := matrix_scales(ctm)
	if big <= 0 || !is_finite(big) { return }
	s := Stroker{out = out, ctm = ctm, hw = style.width * 0.5, style = style}
	defer delete(s.scratch)
	r_dev := s.hw * big
	s.step = clamp(2 * math.acos(clamp(1 - max(tol, 1e-3) / max(r_dev, 1e-3), -1, 1)), math.PI / 64, math.PI / 4)
	user := make([dynamic][2]f64, 0, 64, context.temp_allocator)
	pieces := make([dynamic][2]f64, 0, 64, context.temp_allocator)
	piece_ends := make([dynamic]int, 0, 16, context.temp_allocator)
	for sp in flat.subs {
		n := sp.end - sp.start
		if n <= 0 { continue }
		clear(&user)
		for i in sp.start ..< sp.end {
			q := matrix_apply(inv, flat.pts[i])
			if len(user) > 0 && dist2(user[len(user) - 1], q) <= 1e-18 { continue }   // zero-length segments carry no direction
			append(&user, q)
		}
		closed := sp.closed
		if closed && len(user) > 1 && dist2(user[0], user[len(user) - 1]) <= 1e-18 { pop(&user) }
		if len(user) == 1 {
			// a point: drawn (as its cap) only if it is a zero-length segment or a closed point, not a lone moveTo
			if n >= 2 || closed { stroke_dot(&s, user[0]) }
			continue
		}
		if len(user) == 0 { continue }
		if len(style.dash) > 0 {
			clear(&pieces)
			clear(&piece_ends)
			if dash_polyline(user[:], closed, style.dash, style.dash_offset, style.max_dashes, &pieces, &piece_ends) {
				start := 0
				for e in piece_ends {
					stroke_polyline(&s, pieces[start:e], false)
					start = e
				}
				continue
			}
		}
		stroke_polyline(&s, user[:], closed)
	}
}

@(private)
dist2 :: #force_inline proc "contextless" (a, b: [2]f64) -> f64 {
	d := a - b
	return d.x * d.x + d.y * d.y
}

@(private)
len2 :: #force_inline proc "contextless" (a: [2]f64) -> f64 { return math.sqrt(a.x * a.x + a.y * a.y) }

// One closed polygon (user space) into the output, wound positively and mapped to device space.
@(private)
emit_poly :: proc(s: ^Stroker, pts: [][2]f64) {
	if len(pts) < 3 { return }
	area := 0.0
	for i in 0 ..< len(pts) {
		a, b := pts[i], pts[(i + 1) % len(pts)]
		area += a.x * b.y - b.x * a.y
	}
	if area == 0 { return }
	n := len(pts)
	if area > 0 {
		for i in 0 ..< n { append(&s.out.pts, clamp_pt(matrix_apply(s.ctm, pts[i]))) }
	} else {
		for i := n - 1; i >= 0; i -= 1 { append(&s.out.pts, clamp_pt(matrix_apply(s.ctm, pts[i]))) }
	}
	append(&s.out.ends, len(s.out.pts))
}

@(private)
stroke_dot :: proc(s: ^Stroker, c: [2]f64) {
	switch s.style.cap {
	case .Butt:
	case .Round:
		clear(&s.scratch)
		n := max(int(math.ceil(2 * math.PI / s.step)), 8)
		for i in 0 ..< n {
			a := 2 * math.PI * f64(i) / f64(n)
			append(&s.scratch, c + [2]f64{math.cos(a), math.sin(a)} * s.hw)
		}
		emit_poly(s, s.scratch[:])
	case .Square:
		h := s.hw
		q := [4][2]f64{c + {-h, -h}, c + {h, -h}, c + {h, h}, c + {-h, h}}
		emit_poly(s, q[:])
	}
}

@(private)
stroke_polyline :: proc(s: ^Stroker, input: [][2]f64, closed: bool) {
	// (a dash that ends on a vertex repeats it: a zero-length segment has no direction)
	pts := make([dynamic][2]f64, 0, len(input), context.temp_allocator)
	for q in input { if len(pts) == 0 || dist2(pts[len(pts) - 1], q) > 1e-18 { append(&pts, q) } }
	n := len(pts)
	if n < 2 { return }
	hw := s.hw
	segs := closed ? n : n - 1
	dirs := make([][2]f64, segs, context.temp_allocator)
	for i in 0 ..< segs {
		a, b := pts[i], pts[(i + 1) % n]
		d := b - a
		l := len2(d)
		dirs[i] = l > 0 ? d / l : [2]f64{1, 0}
	}
	for i in 0 ..< segs {
		a, b := pts[i], pts[(i + 1) % n]
		d := dirs[i]
		nn := [2]f64{-d.y, d.x} * hw
		q := [4][2]f64{a + nn, b + nn, b - nn, a - nn}
		emit_poly(s, q[:])
	}
	// joins at the interior vertices (all of them when closed)
	first_join := closed ? 0 : 1
	last_join := closed ? n - 1 : n - 2
	for i in first_join ..= last_join {
		prev := (i - 1 + segs) % segs
		next := i % segs
		if !closed && i == 0 { continue }
		stroke_join(s, pts[i], dirs[prev], dirs[next])
	}
	if !closed {
		stroke_cap(s, pts[0], -dirs[0])
		stroke_cap(s, pts[n - 1], dirs[segs - 1])
	}
}

@(private)
stroke_join :: proc(s: ^Stroker, v: [2]f64, d0, d1: [2]f64) {
	hw := s.hw
	cross := d0.x * d1.y - d0.y * d1.x
	dot := d0.x * d1.x + d0.y * d1.y
	if abs(cross) < 1e-9 && dot > 0 { return }   // straight on: the quads meet
	// the outer side of the turn: left normals point to the left of the direction of travel
	side := cross > 0 ? -1.0 : 1.0
	n0 := [2]f64{-d0.y, d0.x} * (hw * side)
	n1 := [2]f64{-d1.y, d1.x} * (hw * side)
	a, b := v + n0, v + n1
	switch s.style.join {
	case .Bevel:
		t := [3][2]f64{v, a, b}
		emit_poly(s, t[:])
	case .Miter:
		// miter length / line width = 1 / cos(turn / 2), where cos(turn) = dot
		c2 := (1 + dot) * 0.5
		if c2 > 1e-12 && 1 / math.sqrt(c2) <= s.style.miter_limit {
			tip := v + (n0 + n1) / (1 + dot)
			q := [4][2]f64{v, a, tip, b}
			emit_poly(s, q[:])
		} else {
			t := [3][2]f64{v, a, b}
			emit_poly(s, t[:])
		}
	case .Round:
		a0 := math.atan2(n0.y, n0.x)
		a1 := math.atan2(n1.y, n1.x)
		sweep := a1 - a0
		for sweep > math.PI { sweep -= 2 * math.PI }
		for sweep < -math.PI { sweep += 2 * math.PI }
		clear(&s.scratch)
		append(&s.scratch, v)
		k := max(int(math.ceil(abs(sweep) / s.step)), 1)
		for i in 0 ..= k {
			ang := a0 + sweep * f64(i) / f64(k)
			append(&s.scratch, v + [2]f64{math.cos(ang), math.sin(ang)} * hw)
		}
		emit_poly(s, s.scratch[:])
	}
}

// The cap at `e` of a line leaving in direction `out` (unit vector pointing away from the line).
@(private)
stroke_cap :: proc(s: ^Stroker, e: [2]f64, out: [2]f64) {
	hw := s.hw
	perp := [2]f64{-out.y, out.x}
	switch s.style.cap {
	case .Butt:
	case .Square:
		q := [4][2]f64{e + perp * hw, e + perp * hw + out * hw, e - perp * hw + out * hw, e - perp * hw}
		emit_poly(s, q[:])
	case .Round:
		clear(&s.scratch)
		k := max(int(math.ceil(math.PI / s.step)), 4)
		for i in 0 ..= k {
			t := math.PI * f64(i) / f64(k)
			append(&s.scratch, e + (perp * math.cos(t) + out * math.sin(t)) * hw)
		}
		emit_poly(s, s.scratch[:])
	}
}

// Cuts a polyline into dashes. The pieces are appended to `pieces` (their ends in `ends`). false: not dashed (the pattern
// sums to zero, or it would make more than `limit` pieces): the caller strokes the path solid.
@(private)
dash_polyline :: proc(pts: [][2]f64, closed: bool, pattern: []f64, offset: f64, limit: int, pieces: ^[dynamic][2]f64, ends: ^[dynamic]int) -> bool {
	total := 0.0
	for d in pattern { total += d }
	if len(pattern) == 0 || !(total > 0) || !is_finite(total) { return false }
	limit := limit > 0 ? limit : 100_000
	n := len(pts)
	segs := closed ? n : n - 1
	length := 0.0
	for i in 0 ..< segs { length += math.sqrt(dist2(pts[i], pts[(i + 1) % n])) }
	if length / total * f64(len(pattern)) > f64(limit) { return false }
	phase := math.mod(offset, total)
	if phase < 0 { phase += total }
	idx := 0
	for phase >= pattern[idx] {   // (ends: phase < total, so a positive entry stops it)
		phase -= pattern[idx]
		idx = (idx + 1) % len(pattern)
	}
	left := pattern[idx] - phase   // what remains of the current dash or gap
	on := idx % 2 == 0
	if on { append(pieces, pts[0]) }
	toggles := 0
	for i in 0 ..< segs {
		a, b := pts[i], pts[(i + 1) % n]
		seg := math.sqrt(dist2(a, b))
		if seg == 0 { continue }
		dir := (b - a) / seg
		pos := 0.0
		for seg - pos > left {
			pos += left
			// a dash ends here, or a gap does and the next dash starts: the point belongs to a piece either way
			append(pieces, a + dir * pos)
			if on { append(ends, len(pieces)) }
			on = !on
			idx = (idx + 1) % len(pattern)
			left = pattern[idx]
			toggles += 1
			if toggles > 2 * limit { return false }
		}
		left -= seg - pos
		if on { append(pieces, b) }
	}
	if on {
		last := len(ends) > 0 ? ends[len(ends) - 1] : 0
		if len(pieces) > last { append(ends, len(pieces)) }
	}
	return true
}