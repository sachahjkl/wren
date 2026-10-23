package canvas2d

import "core:math"
import "core:slice"

Fill_Rule :: enum u8 { Nonzero, Evenodd }

// A polygon edge, oriented downwards (y0 < y1): `dir` says whether the polygon went down (+1) or up (-1) along it.
@(private)
Edge :: struct {
	x0, y0: f64,
	y1:     f64,
	dxdy:   f64,
	dir:    i32,
}

@(private)
Crossing :: struct {
	x:   f64,
	dir: i32,
}

// Scanline rasterizer with exact horizontal coverage and `samples` sub-scanlines per pixel row: each sub-scanline finds
// where the polygon edges cross it, applies the fill rule to get spans, and adds each span's fractional pixel coverage.
// Overlapping pieces (the union of a stroke's quads and joins) therefore never double count, unlike signed-area
// accumulation. Reusable: edges are cleared by `raster_reset`, buffers keep their memory.
Raster :: struct {
	edges:   [dynamic]Edge,
	active:  [dynamic]int,
	xs:      [dynamic]Crossing,
	area:    [dynamic]f32,
	delta:   [dynamic]f32,
	cov:     [dynamic]f32,
	min_pt:  [2]f64,
	max_pt:  [2]f64,
	any:     bool,
}

raster_destroy :: proc(r: ^Raster) {
	delete(r.edges)
	delete(r.active)
	delete(r.xs)
	delete(r.area)
	delete(r.delta)
	delete(r.cov)
	r^ = {}
}

raster_reset :: proc(r: ^Raster) {
	clear(&r.edges)
	r.any = false
}

raster_has_edges :: proc(r: ^Raster) -> bool { return len(r.edges) > 0 }

@(private)
add_edge :: proc(r: ^Raster, a, b: [2]f64) {
	if a.y == b.y { return }   // horizontal edges cross no sub-scanline
	if !r.any {
		r.min_pt, r.max_pt = a, a
		r.any = true
	}
	for p in ([2][2]f64{a, b}) {
		r.min_pt = {min(r.min_pt.x, p.x), min(r.min_pt.y, p.y)}
		r.max_pt = {max(r.max_pt.x, p.x), max(r.max_pt.y, p.y)}
	}
	if a.y < b.y {
		append(&r.edges, Edge{x0 = a.x, y0 = a.y, y1 = b.y, dxdy = (b.x - a.x) / (b.y - a.y), dir = 1})
	} else {
		append(&r.edges, Edge{x0 = b.x, y0 = b.y, y1 = a.y, dxdy = (a.x - b.x) / (a.y - b.y), dir = -1})
	}
}

// A closed polygon.
raster_add_polygon :: proc(r: ^Raster, pts: [][2]f64) {
	n := len(pts)
	if n < 2 { return }
	for i in 0 ..< n { add_edge(r, pts[i], pts[(i + 1) % n]) }
}

// Every subpath of `flat` as a closed polygon (what filling does).
raster_add_flat :: proc(r: ^Raster, flat: ^Flat) {
	for sp in flat.subs { raster_add_polygon(r, flat.pts[sp.start:sp.end]) }
}

raster_add_polys :: proc(r: ^Raster, polys: ^Polys) {
	start := 0
	for e in polys.ends {
		raster_add_polygon(r, polys.pts[start:e])
		start = e
	}
}

// Pixel rectangle (half-open) a pixel-aligned bounding box of the edges covers, before clipping.
raster_extent :: proc(r: ^Raster) -> (x0, y0, x1, y1: int, ok: bool) {
	if !r.any { return }
	f :: proc(v: f64) -> int { return int(clamp(v, -1e9, 1e9)) }
	return f(math.floor(r.min_pt.x)), f(math.floor(r.min_pt.y)), f(math.ceil(r.max_pt.x)), f(math.ceil(r.max_pt.y)), true
}

// Receives the coverage (0 to 1) of the pixels [x0, x0 + len(cov)) of row y. Rows come in increasing order, and only
// rows (and, within them, runs) the shape touches are reported.
Row_Proc :: #type proc(user: rawptr, y, x0: int, cov: []f32)

// Rasterizes the edges added so far, limited to the pixel rectangle [cx0, cx1) x [cy0, cy1).
raster_fill :: proc(r: ^Raster, rule: Fill_Rule, cx0, cy0, cx1, cy1: int, samples: int, row: Row_Proc, user: rawptr) {
	ex0, ey0, ex1, ey1, ok := raster_extent(r)
	if !ok { return }
	x0, y0, x1, y1 := max(cx0, ex0), max(cy0, ey0), min(cx1, ex1), min(cy1, ey1)
	if x0 >= x1 || y0 >= y1 { return }
	n := clamp(samples, 1, 64)
	width := x1 - x0
	resize(&r.area, width + 2)
	resize(&r.delta, width + 2)
	resize(&r.cov, width + 2)
	for i in 0 ..< len(r.area) { r.area[i] = 0; r.delta[i] = 0 }
	slice.sort_by(r.edges[:], proc(a, b: Edge) -> bool { return a.y0 < b.y0 })
	clear(&r.active)
	next := 0
	wgt := f32(1) / f32(n)
	fx0, fx1 := f64(x0), f64(x1)
	for y in y0 ..< y1 {
		lo, hi := max(int), -1
		for k in 0 ..< n {
			sy := f64(y) + (f64(k) + 0.5) / f64(n)
			for next < len(r.edges) && r.edges[next].y0 <= sy {
				if r.edges[next].y1 > sy { append(&r.active, next) }
				next += 1
			}
			// drop what ended, collect the crossings of the rest
			clear(&r.xs)
			w := 0
			for ei in r.active {
				e := &r.edges[ei]
				if e.y1 <= sy { continue }
				r.active[w] = ei
				w += 1
				append(&r.xs, Crossing{x = e.x0 + (sy - e.y0) * e.dxdy, dir = e.dir})
			}
			resize(&r.active, w)
			if len(r.xs) < 2 { continue }
			sort_crossings(r.xs[:])
			wind := i32(0)
			span := 0.0
			inside := false
			for c in r.xs {
				prev := inside
				if rule == .Nonzero { wind += c.dir; inside = wind != 0 } else { wind += 1; inside = wind & 1 == 1 }
				if inside && !prev {
					span = c.x
				} else if !inside && prev {
					add_span(r, span, c.x, fx0, fx1, wgt, &lo, &hi)
				}
			}
			if inside { add_span(r, span, fx1, fx0, fx1, wgt, &lo, &hi) }
		}
		if hi < 0 { continue }
		// area + running sum of the interior deltas = coverage
		run := f32(0)
		for x in lo ..= hi {
			run += r.delta[x]
			c := run + r.area[x]
			r.cov[x - lo] = clamp(c, 0, 1)
			r.delta[x] = 0
			r.area[x] = 0
		}
		r.delta[hi + 1] = 0
		last := min(hi, width - 1)   // (a span that ends on the right edge touches the accumulator one past it)
		if last >= lo { row(user, y, x0 + lo, r.cov[:last - lo + 1]) }
	}
}

@(private)
sort_crossings :: proc(xs: []Crossing) {
	if len(xs) > 24 {
		slice.sort_by(xs, proc(a, b: Crossing) -> bool { return a.x < b.x })
		return
	}
	for i in 1 ..< len(xs) {
		c := xs[i]
		j := i
		for j > 0 && xs[j - 1].x > c.x {
			xs[j] = xs[j - 1]
			j -= 1
		}
		xs[j] = c
	}
}

// Adds the span [xa, xb) (pixel units, clamped to [fx0, fx1]) to the row accumulators, relative to fx0.
@(private)
add_span :: proc(r: ^Raster, xa, xb, fx0, fx1: f64, wgt: f32, lo, hi: ^int) {
	a, b := clamp(xa, fx0, fx1) - fx0, clamp(xb, fx0, fx1) - fx0
	if b <= a { return }
	ia, ib := int(a), int(b)   // (a, b >= 0: truncation is floor)
	lo^, hi^ = min(lo^, ia), max(hi^, ib)
	if ia == ib {
		r.area[ia] += f32(b - a) * wgt
		return
	}
	r.area[ia] += f32(f64(ia + 1) - a) * wgt
	r.delta[ia + 1] += wgt
	r.delta[ib] -= wgt
	r.area[ib] += f32(b - f64(ib)) * wgt
}

// Coverage of an axis-aligned rectangle [rx0, rx1] x [ry0, ry1] (pixel units), exact, within the pixel rectangle
// [cx0, cx1) x [cy0, cy1): the fast path of fillRect, clearRect and the images drawn without rotation.
raster_fill_rect :: proc(r: ^Raster, rx0, ry0, rx1, ry1: f64, cx0, cy0, cx1, cy1: int, row: Row_Proc, user: rawptr) {
	if !(rx1 > rx0) || !(ry1 > ry0) { return }
	x0, y0 := max(cx0, int(clamp(math.floor(rx0), -1e9, 1e9))), max(cy0, int(clamp(math.floor(ry0), -1e9, 1e9)))
	x1, y1 := min(cx1, int(clamp(math.ceil(rx1), -1e9, 1e9))), min(cy1, int(clamp(math.ceil(ry1), -1e9, 1e9)))
	if x0 >= x1 || y0 >= y1 { return }
	resize(&r.cov, x1 - x0 + 2)
	for x in x0 ..< x1 {
		r.cov[x - x0] = f32(max(min(f64(x + 1), rx1) - max(f64(x), rx0), 0))
	}
	cx := r.cov[:x1 - x0]
	line := make([]f32, x1 - x0, context.temp_allocator)
	for y in y0 ..< y1 {
		cy := f32(max(min(f64(y + 1), ry1) - max(f64(y), ry0), 0))
		if cy <= 0 { continue }
		if cy == 1 {
			row(user, y, x0, cx)
		} else {
			for i in 0 ..< len(cx) { line[i] = cx[i] * cy }
			row(user, y, x0, line)
		}
	}
}
