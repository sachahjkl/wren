package canvas2d

import "core:math"

// Polygons for the GPU: line edges grouped in horizontal bands, laid out as canvas.wgsl (shape_coverage) reads them. A shape's
// data is position independent (every offset is relative to its first entry), so a glyph's can be built once and copied
// into the heap of each list that draws it.
//
//   n_bands header entries: (edge count, first list entry, first edge, 0)
//   the edges: (x0 y0 x1 y1) as bit-cast floats, never horizontal
//   the lists: four edge numbers per entry (sorting them by x to let the shader stop early costs more on the CPU than it
//   saves on the GPU: bands hold a handful of edges)
// An edge belongs to every band its y range, widened by `margin`, touches.

MAX_BANDS :: 256

@(private)
Shape_Edge :: struct {
	a, b: [2]f32,
	xmax: f32,
}

// Appends the shape of `polys` (closed polygons; points are device-or-local f64, `origin` is subtracted) to `heap`. Returns the
// offset of the shape in the heap and its band count, the bounds of the edges (after the subtraction) and whether it has
// any edge. `margin` is in the shape's units: at least the half height of a pixel's footprint.
shape_build :: proc(heap: ^[dynamic][4]u32, polys: [][][2]f64, origin: [2]f64, margin: f32, max_edges: int) -> (base: int, nb: int, bounds: [4]f32, ok: bool) {
	total := 0
	for p in polys { total += len(p) }
	if total == 0 || (max_edges > 0 && total > max_edges) { return }
	edges := make([dynamic]Shape_Edge, 0, total, context.temp_allocator)
	lo, hi := [2]f32{math.F32_MAX, math.F32_MAX}, [2]f32{-math.F32_MAX, -math.F32_MAX}
	for p in polys {
		n := len(p)
		if n < 2 { continue }
		prev := p[n - 1] - origin
		for i in 0 ..< n {
			a := prev
			b := p[i] - origin
			prev = b
			fa := [2]f32{f32(a.x), f32(a.y)}
			fb := [2]f32{f32(b.x), f32(b.y)}
			if fa.x != fa.x || fa.y != fa.y || fb.x != fb.x || fb.y != fb.y { continue }
			lo = {min(lo.x, fb.x), min(lo.y, fb.y)}
			hi = {max(hi.x, fb.x), max(hi.y, fb.y)}
			if fa.y == fb.y { continue }
			append(&edges, Shape_Edge{a = fa, b = fb, xmax = max(fa.x, fb.x)})
		}
	}
	n := len(edges)
	if n == 0 || lo.x > hi.x { return }
	bounds = {lo.x, lo.y, hi.x, hi.y}
	height := max(hi.y - lo.y, 1e-6)
	nb = clamp(n / 6, 1, MAX_BANDS)
	nb = min(nb, max(1, int(math.ceil(height / max(margin, 0.25)))))
	band_h := height / f32(nb)
	inv_h := 1 / band_h

	counts := make([]int, nb, context.temp_allocator)
	ranges := make([][2]i16, n, context.temp_allocator)
	for e, i in edges {
		b0 := clamp(int((min(e.a.y, e.b.y) - margin - lo.y) * inv_h), 0, nb - 1)
		b1 := clamp(int((max(e.a.y, e.b.y) + margin - lo.y) * inv_h), 0, nb - 1)
		if (min(e.a.y, e.b.y) - margin - lo.y) < 0 { b0 = 0 }
		ranges[i] = {i16(b0), i16(b1)}
		for b in b0 ..= b1 { counts[b] += 1 }
	}
	entries := 0
	for c in counts { entries += (c + 3) / 4 }
	base = len(heap)
	need := base + nb + n + entries
	if cap(heap^) < need { reserve(heap, max(need, cap(heap^) * 2, 1024)) }
	resize(heap, need)
	h := heap[base:]
	for e, i in edges {
		h[nb + i] = {transmute(u32)e.a.x, transmute(u32)e.a.y, transmute(u32)e.b.x, transmute(u32)e.b.y}
	}
	// the lists: each band's edge numbers, in order, four to an entry
	list := nb + n
	starts := make([]int, nb, context.temp_allocator)
	for b in 0 ..< nb {
		h[b] = {u32(counts[b]), u32(list), u32(nb), 0}
		starts[b] = list
		for k in 0 ..< (counts[b] + 3) / 4 { h[list + k] = {} }
		list += (counts[b] + 3) / 4
	}
	fill := make([]int, nb, context.temp_allocator)
	for i in 0 ..< n {
		for b in int(ranges[i][0]) ..= int(ranges[i][1]) {
			k := fill[b]
			fill[b] += 1
			h[starts[b] + k / 4][k & 3] = u32(i)
		}
	}
	return base, nb, bounds, true
}
