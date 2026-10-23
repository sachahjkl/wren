package canvas2d

import "core:math"

// A path as the Canvas API builds it (HTML "current default path" and Path2D): subpaths of lines and Bézier curves.
// Points are stored in the space the path was built in: for a context's current path, device space (each call
// transforms its arguments by the CTM of that moment, as the specification says); for a Path2D, the identity space.
// Every builder takes the matrix to apply; a non-finite argument makes the call a no-op (the specification's
// "if any of the arguments are infinite or NaN, then return").

Verb :: enum u8 { Move, Line, Quad, Cubic, Close }

Path :: struct {
	verbs:  [dynamic]Verb,
	pts:    [dynamic][2]f64,
	start:  [2]f64,   // first point of the last subpath (where a close returns to)
	cur:    [2]f64,
	limit:  int,      // most points the path keeps (0: no limit); further segments are ignored
	has:    bool,     // a subpath exists (the current point is valid)
	closed: bool,     // the last verb is a close: the next segment begins a subpath at `start`
}

Path_Error :: enum u8 { None, Index_Size }

path_destroy :: proc(p: ^Path) {
	delete(p.verbs)
	delete(p.pts)
	p^ = {}
}

path_clear :: proc(p: ^Path) {
	clear(&p.verbs)
	clear(&p.pts)
	p.has, p.closed = false, false
	p.start, p.cur = {}, {}
}

path_is_empty :: proc(p: ^Path) -> bool { return len(p.verbs) == 0 }

path_clone :: proc(p: ^Path, allocator := context.allocator) -> Path {
	r := p^
	r.verbs = make([dynamic]Verb, len(p.verbs), allocator)
	r.pts = make([dynamic][2]f64, len(p.pts), allocator)
	copy(r.verbs[:], p.verbs[:])
	copy(r.pts[:], p.pts[:])
	return r
}

// Appends `src` as it is after `m` transformed it (Path2D.addPath, the CTM applied to a Path2D being drawn).
path_append :: proc(p: ^Path, src: ^Path, m: Matrix) {
	if !matrix_finite(m) || len(src.verbs) == 0 { return }
	if p.limit > 0 && len(p.pts) + len(src.pts) > p.limit { return }
	// the first segment of a path that did not start with a move would join the current subpath: say so
	if p.closed && len(src.verbs) > 0 && src.verbs[0] != .Move { append(&p.verbs, Verb.Move); append(&p.pts, p.start) }
	for v in src.verbs { append(&p.verbs, v) }
	for pt in src.pts { append(&p.pts, clamp_pt(matrix_apply(m, pt))) }
	if len(src.verbs) > 0 {
		p.has = p.has || src.has
		p.start = clamp_pt(matrix_apply(m, src.start))
		p.cur = clamp_pt(matrix_apply(m, src.cur))
		p.closed = src.closed
	}
}

@(private)
clamp_pt :: #force_inline proc "contextless" (p: [2]f64) -> [2]f64 { return {clamp_coord(p.x), clamp_coord(p.y)} }

@(private)
all_finite :: proc "contextless" (vs: ..f64) -> bool {
	for v in vs { if !is_finite(v) { return false } }
	return true
}

@(private)
add_move :: proc(p: ^Path, d: [2]f64) {
	append(&p.verbs, Verb.Move)
	append(&p.pts, d)
	p.start, p.cur = d, d
	p.has, p.closed = true, false
}

// "Ensure there is a subpath" for a segment that starts at the current point: after a close the subpath restarts at
// its first point. false: there is none and the caller must begin one.
@(private)
continue_subpath :: proc(p: ^Path) -> bool {
	if !p.has { return false }
	if p.closed {
		append(&p.verbs, Verb.Move)
		append(&p.pts, p.start)
		p.cur, p.closed = p.start, false
	}
	return true
}

@(private)
full :: #force_inline proc(p: ^Path) -> bool { return p.limit > 0 && len(p.pts) >= p.limit }

path_move_to :: proc(p: ^Path, m: Matrix, x, y: f64) {
	if !all_finite(x, y) || full(p) { return }
	add_move(p, clamp_pt(matrix_apply(m, {x, y})))
}

path_line_to :: proc(p: ^Path, m: Matrix, x, y: f64) {
	if !all_finite(x, y) || full(p) { return }
	d := clamp_pt(matrix_apply(m, {x, y}))
	if !continue_subpath(p) { add_move(p, d); return }
	append(&p.verbs, Verb.Line)
	append(&p.pts, d)
	p.cur = d
}

path_quad_to :: proc(p: ^Path, m: Matrix, cx, cy, x, y: f64) {
	if !all_finite(cx, cy, x, y) || full(p) { return }
	c, d := clamp_pt(matrix_apply(m, {cx, cy})), clamp_pt(matrix_apply(m, {x, y}))
	if !continue_subpath(p) { add_move(p, c) }
	append(&p.verbs, Verb.Quad)
	append(&p.pts, c, d)
	p.cur = d
}

path_cubic_to :: proc(p: ^Path, m: Matrix, c1x, c1y, c2x, c2y, x, y: f64) {
	if !all_finite(c1x, c1y, c2x, c2y, x, y) || full(p) { return }
	c1, c2, d := clamp_pt(matrix_apply(m, {c1x, c1y})), clamp_pt(matrix_apply(m, {c2x, c2y})), clamp_pt(matrix_apply(m, {x, y}))
	if !continue_subpath(p) { add_move(p, c1) }
	append(&p.verbs, Verb.Cubic)
	append(&p.pts, c1, c2, d)
	p.cur = d
}

path_close :: proc(p: ^Path) {
	if !p.has || p.closed { return }
	append(&p.verbs, Verb.Close)
	p.cur, p.closed = p.start, true
}

path_rect :: proc(p: ^Path, m: Matrix, x, y, w, h: f64) {
	if !all_finite(x, y, w, h) { return }
	path_move_to(p, m, x, y)
	path_line_to(p, m, x + w, y)
	path_line_to(p, m, x + w, y + h)
	path_line_to(p, m, x, y + h)
	path_close(p)
	path_move_to(p, m, x, y)   // the next segment starts a new subpath at the corner (HTML: rect())
}

// The point of the unit circle arc as Béziers: a sweep of any sign split into pieces of at most a quarter turn.
// `to_dev` maps unit-circle space to device space (center, radii, rotation and the CTM folded in).
@(private)
arc_segments :: proc(p: ^Path, to_dev: Matrix, a0, sweep: f64) {
	if sweep == 0 { return }
	n := max(int(math.ceil(abs(sweep) / (math.PI * 0.5) - 1e-9)), 1)
	step := sweep / f64(n)
	k := 4.0 / 3.0 * math.tan(step * 0.25)
	for i in 0 ..< n {
		a := a0 + step * f64(i)
		b := a + step
		sa, ca := math.sin(a), math.cos(a)
		sb, cb := math.sin(b), math.cos(b)
		c1 := clamp_pt(matrix_apply(to_dev, {ca - k * sa, sa + k * ca}))
		c2 := clamp_pt(matrix_apply(to_dev, {cb + k * sb, sb - k * cb}))
		e := clamp_pt(matrix_apply(to_dev, {cb, sb}))
		append(&p.verbs, Verb.Cubic)
		append(&p.pts, c1, c2, e)
		p.cur = e
	}
}

// ellipse() of the specification (arc() is the circle case): the sweep is normalized as HTML says (a full turn at
// most, in the direction asked), the path goes by a line to the start point, then along the curve.
path_ellipse :: proc(p: ^Path, m: Matrix, x, y, rx, ry, rotation, start, end: f64, ccw: bool) -> Path_Error {
	if !all_finite(x, y, rx, ry, rotation, start, end) { return .None }
	if rx < 0 || ry < 0 { return .Index_Size }
	if full(p) { return .None }
	TAU :: 2 * math.PI
	sweep: f64
	switch {
	case !ccw && end - start >= TAU: sweep = TAU
	case ccw && start - end >= TAU: sweep = -TAU
	case !ccw:
		sweep = math.mod(end - start, TAU)
		if sweep < 0 { sweep += TAU }
	case:
		sweep = -math.mod(start - end, TAU)
		if sweep > 0 { sweep -= TAU }
	}
	to_dev := matrix_mul(m, matrix_mul(matrix_translate(x, y), matrix_mul(matrix_rotate(rotation), matrix_scale(rx, ry))))
	if !matrix_finite(to_dev) { return .None }
	s := clamp_pt(matrix_apply(to_dev, {math.cos(start), math.sin(start)}))
	if !continue_subpath(p) { add_move(p, s) } else if p.cur != s {
		append(&p.verbs, Verb.Line)
		append(&p.pts, s)
		p.cur = s
	}
	arc_segments(p, to_dev, start, sweep)
	return .None
}

path_arc :: proc(p: ^Path, m: Matrix, x, y, r, start, end: f64, ccw: bool) -> Path_Error {
	return path_ellipse(p, m, x, y, r, r, 0, start, end, ccw)
}

// arcTo(x1, y1, x2, y2, radius): the arc of the given radius tangent to the lines (current point, p1) and (p1, p2).
path_arc_to :: proc(p: ^Path, m: Matrix, x1, y1, x2, y2, r: f64) -> Path_Error {
	if !all_finite(x1, y1, x2, y2, r) { return .None }
	if r < 0 { return .Index_Size }
	if !p.has { path_move_to(p, m, x1, y1) }
	inv, ok := matrix_invert(m)
	if !ok { path_line_to(p, m, x1, y1); return .None }
	p0 := matrix_apply(inv, p.closed ? p.start : p.cur)   // (user space: the arc is round there)
	p1, p2 := [2]f64{x1, y1}, [2]f64{x2, y2}
	v0, v2 := p0 - p1, p2 - p1
	l0, l2 := math.sqrt(v0.x * v0.x + v0.y * v0.y), math.sqrt(v2.x * v2.x + v2.y * v2.y)
	cross := v0.x * v2.y - v0.y * v2.x
	if l0 == 0 || l2 == 0 || r == 0 || abs(cross) <= 1e-12 * l0 * l2 {
		path_line_to(p, m, x1, y1)
		return .None
	}
	u0, u2 := v0 / l0, v2 / l2
	cos_t := clamp(u0.x * u2.x + u0.y * u2.y, -1, 1)
	half := math.acos(cos_t) * 0.5            // half the angle at p1
	t := r / math.tan(half)                   // distance from p1 to the tangent points
	if !is_finite(t) { path_line_to(p, m, x1, y1); return .None }
	t0, t2 := p1 + u0 * t, p1 + u2 * t
	bis := u0 + u2
	bl := math.sqrt(bis.x * bis.x + bis.y * bis.y)
	centre := p1 + bis / bl * (r / math.sin(half))
	a0 := math.atan2(t0.y - centre.y, t0.x - centre.x)
	a1 := math.atan2(t2.y - centre.y, t2.x - centre.x)
	sweep := a1 - a0
	for sweep > math.PI { sweep -= 2 * math.PI }
	for sweep < -math.PI { sweep += 2 * math.PI }
	path_line_to(p, m, t0.x, t0.y)
	to_dev := matrix_mul(m, matrix_mul(matrix_translate(centre.x, centre.y), matrix_scale(r, r)))
	arc_segments(p, to_dev, a0, sweep)
	return .None
}

// roundRect: `radii` are the four corners (upper-left, upper-right, lower-right, lower-left), each (x, y) radii. The
// caller has expanded the 1-4 values of the API and refused negatives.
path_round_rect :: proc(p: ^Path, m: Matrix, x, y, w, h: f64, radii: [4][2]f64) {
	if !all_finite(x, y, w, h) { return }
	r := radii
	x, y, w, h := x, y, w, h
	for c in r { if !all_finite(c.x, c.y) || c.x < 0 || c.y < 0 { return } }
	// a negative size mirrors the rectangle: it is the same shape with the corners swapped
	if w < 0 { x += w; w = -w; r[0], r[1] = r[1], r[0]; r[3], r[2] = r[2], r[3] }
	if h < 0 { y += h; h = -h; r[0], r[3] = r[3], r[0]; r[1], r[2] = r[2], r[1] }
	// radii that do not fit shrink together (CSS Backgrounds §5.5, the same rule)
	scale := 1.0
	top, bottom, left, right := r[0].x + r[1].x, r[3].x + r[2].x, r[0].y + r[3].y, r[1].y + r[2].y
	if top > w && top > 0 { scale = min(scale, w / top) }
	if bottom > w && bottom > 0 { scale = min(scale, w / bottom) }
	if left > h && left > 0 { scale = min(scale, h / left) }
	if right > h && right > 0 { scale = min(scale, h / right) }
	if scale < 1 { for &c in r { c *= scale } }
	H :: math.PI * 0.5
	path_move_to(p, m, x + r[0].x, y)
	path_line_to(p, m, x + w - r[1].x, y)
	path_ellipse(p, m, x + w - r[1].x, y + r[1].y, r[1].x, r[1].y, 0, -H, 0, false)
	path_line_to(p, m, x + w, y + h - r[2].y)
	path_ellipse(p, m, x + w - r[2].x, y + h - r[2].y, r[2].x, r[2].y, 0, 0, H, false)
	path_line_to(p, m, x + r[3].x, y + h)
	path_ellipse(p, m, x + r[3].x, y + h - r[3].y, r[3].x, r[3].y, 0, H, 2 * H, false)
	path_line_to(p, m, x, y + r[0].y)
	path_ellipse(p, m, x + r[0].x, y + r[0].y, r[0].x, r[0].y, 0, 2 * H, 3 * H, false)
	path_close(p)
	path_move_to(p, m, x, y)
}

////////////////////////////////
// Flattening

Subpath :: struct {
	start, end: int,    // pts[start:end]
	closed:     bool,
}

// A path as polylines.
Flat :: struct {
	pts:  [dynamic][2]f64,
	subs: [dynamic]Subpath,
}

flat_destroy :: proc(f: ^Flat) {
	delete(f.pts)
	delete(f.subs)
	f^ = {}
}

flat_clear :: proc(f: ^Flat) {
	clear(&f.pts)
	clear(&f.subs)
}

// Largest number of line segments one curve is cut into.
MAX_CURVE_SEGMENTS :: 400

// `tol`: the distance the polyline may stray from the curve, in the units of the points after `m`.
path_flatten :: proc(p: ^Path, m: Matrix, tolerance: f64, out: ^Flat) {
	tol := max(tolerance, 1e-4)
	pi := 0
	cur: [2]f64
	begin :: proc(out: ^Flat) { append(&out.subs, Subpath{start = len(out.pts)}) }
	finish :: proc(out: ^Flat, closed: bool) {
		if len(out.subs) == 0 { return }
		s := &out.subs[len(out.subs) - 1]
		if s.end == 0 || s.end < s.start { s.end = len(out.pts) }
		s.closed = closed
	}
	open := false
	tp :: #force_inline proc "contextless" (m: Matrix, q: [2]f64) -> [2]f64 { return clamp_pt(matrix_apply(m, q)) }
	for v in p.verbs {
		switch v {
		case .Move:
			if open { finish(out, false) }
			begin(out)
			cur = tp(m, p.pts[pi]); pi += 1
			append(&out.pts, cur)
			open = true
		case .Line:
			cur = tp(m, p.pts[pi]); pi += 1
			append(&out.pts, cur)
		case .Quad:
			c, e := tp(m, p.pts[pi]), tp(m, p.pts[pi + 1])
			pi += 2
			d := cur - 2 * c + e
			n := clamp(int(math.ceil(math.sqrt(math.sqrt(d.x * d.x + d.y * d.y) / (4 * tol)))), 1, MAX_CURVE_SEGMENTS)
			for i in 1 ..< n {
				t := f64(i) / f64(n)
				u := 1 - t
				append(&out.pts, u * u * cur + 2 * u * t * c + t * t * e)
			}
			append(&out.pts, e)
			cur = e
		case .Cubic:
			c1, c2, e := tp(m, p.pts[pi]), tp(m, p.pts[pi + 1]), tp(m, p.pts[pi + 2])
			pi += 3
			d1, d2 := cur - 2 * c1 + c2, c1 - 2 * c2 + e
			l := max(math.sqrt(d1.x * d1.x + d1.y * d1.y), math.sqrt(d2.x * d2.x + d2.y * d2.y))
			n := clamp(int(math.ceil(math.sqrt(0.75 * l / tol))), 1, MAX_CURVE_SEGMENTS)
			for i in 1 ..< n {
				t := f64(i) / f64(n)
				u := 1 - t
				append(&out.pts, u * u * u * cur + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * e)
			}
			append(&out.pts, e)
			cur = e
		case .Close:
			if open {
				finish(out, true)
				open = false
			}
		}
	}
	if open { finish(out, false) }
	// the end of every subpath is where the next one begins
	for i in 0 ..< len(out.subs) {
		out.subs[i].end = i + 1 < len(out.subs) ? out.subs[i + 1].start : len(out.pts)
	}
}
