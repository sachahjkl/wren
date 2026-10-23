package canvas2d

import "core:math"
import "core:slice"

// Polygons for the GPU: line edges grouped in horizontal bands, laid out as canvas.wgsl (shape_coverage) reads them. A shape's
// data is position independent (every offset is relative to its first entry), so a glyph's can be built once and copied
// into the heap of each list that draws it.
//
//   n_bands header entries: (edge count, first list entry, first edge, 0)
//   the edges: (x0, y0, x1, y1) as bit-cast floats, never horizontal
//   the lists: four edge numbers per entry; each band's list starts on an entry and is sorted by the larger x of its edges,
//   descending (the shader stops at the first edge that lies left of the pixel)
// An edge belongs to every band its y range, widened by `margin`, touches.

MAX_BANDS :: 256

@(private)
Shape_Edge :: struct {
	a, b: [2]f32,
	xmax: f32,
}

@(private)
Keyed :: struct {
	key: f32,
	idx: u32,
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
		for i in 0 ..< n {
			a := p[i] - origin
			b := p[(i + 1) % n] - origin
			fa := [2]f32{f32(a.x), f32(a.y)}
			fb := [2]f32{f32(b.x), f32(b.y)}
			if fa.x != fa.x || fa.y != fa.y || fb.x != fb.x || fb.y != fb.y { continue }
			lo = {min(lo.x, fa.x), min(lo.y, fa.y)}
			hi = {max(hi.x, fa.x), max(hi.y, fa.y)}
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

	band_of :: #force_inline proc(y, y0, band_h: f32, nb: int) -> int {
		return clamp(int(math.floor((y - y0) / band_h)), 0, nb - 1)
	}
	counts := make([]int, nb, context.temp_allocator)
	for e in edges {
		b0 := band_of(min(e.a.y, e.b.y) - margin, lo.y, band_h, nb)
		b1 := band_of(max(e.a.y, e.b.y) + margin, lo.y, band_h, nb)
		for b in b0 ..= b1 { counts[b] += 1 }
	}
	entries := 0
	for c in counts { entries += (c + 3) / 4 }
	base = len(heap)
	resize(heap, base + nb + n + entries)
	h := heap[base:]
	// the edges
	for e, i in edges {
		h[nb + i] = {transmute(u32)e.a.x, transmute(u32)e.a.y, transmute(u32)e.b.x, transmute(u32)e.b.y}
	}
	// per band: the keyed edge numbers, sorted
	starts := make([]int, nb + 1, context.temp_allocator)
	for b in 0 ..< nb { starts[b + 1] = starts[b] + counts[b] }
	keyed := make([]Keyed, starts[nb], context.temp_allocator)
	fill := make([]int, nb, context.temp_allocator)
	for e, i in edges {
		b0 := band_of(min(e.a.y, e.b.y) - margin, lo.y, band_h, nb)
		b1 := band_of(max(e.a.y, e.b.y) + margin, lo.y, band_h, nb)
		for b in b0 ..= b1 {
			keyed[starts[b] + fill[b]] = Keyed{e.xmax, u32(i)}
			fill[b] += 1
		}
	}
	list := nb + n
	for b in 0 ..< nb {
		ks := keyed[starts[b]:starts[b + 1]]
		if len(ks) > 1 { slice.sort_by(ks, proc(l, r: Keyed) -> bool { return l.key > r.key || (l.key == r.key && l.idx < r.idx) }) }
		h[b] = {u32(len(ks)), u32(list), u32(nb), 0}
		for k := 0; k < len(ks); k += 4 {
			v: [4]u32
			for j in 0 ..< 4 { if k + j < len(ks) { v[j] = ks[k + j].idx } }
			h[list] = v
			list += 1
		}
	}
	return base, nb, bounds, true
}
