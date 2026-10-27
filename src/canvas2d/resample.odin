package canvas2d

import "core:math"

// imageSmoothingQuality on the CPU (the GPU path chooses its own sampler, gpu.odin gpu_filter_of). The three qualities
// trade sharpness of a shrunk image against time:
//   * Low    : bilinear of the source, no prefiltering. Fast; a strongly shrunk image aliases, as a one-tap filter does.
//   * Medium : one box-reduced level (a "mip") when the image is shrunk below half, then bilinear of that level. This is
//              what the package did before for strong reductions; it removes most of the aliasing at little cost.
//   * High   : a full box-filtered mip pyramid and trilinear sampling (bilinear in the two levels around the wanted
//              level of detail, blended), so a reduction of any factor is smooth with no visible level seams.
// `imageSmoothingEnabled = false` keeps nearest sampling whatever the quality. Enlarging never needs a mip, so every
// quality is plain bilinear there.

// A box-filtered pyramid of a source rectangle: level 0 is the rectangle itself (shared, not copied), each next level
// half the size of the one before (rounding up), until a 1x1 level. Built on the temp allocator for the life of a draw.
Mip_Chain :: struct {
	levels: [][]u8,   // level i is w_i * h_i * 4 premultiplied RGBA (level 0 a tight copy of the source rectangle)
	sizes:  [][2]int, // w_i, h_i
}

// Builds up to `max_levels` mip levels of texels [x0, x1) x [y0, y1) of `src` (premultiplied). Returns an empty chain
// when the rectangle is degenerate or memory runs out. Everything is allocated on `allocator` (the context's temp
// allocator at the call site), so the caller must not keep the chain past the draw.
mip_build :: proc(src: ^Bitmap, x0, y0, x1, y1: int, max_levels: int, allocator := context.temp_allocator) -> (m: Mip_Chain, ok: bool) {
	w0, h0 := x1 - x0, y1 - y0
	if w0 <= 0 || h0 <= 0 { return }
	// how many halvings reach 1x1 on the longer side (at least one level)
	n := 1
	for (w0 >> uint(n - 1)) > 1 || (h0 >> uint(n - 1)) > 1 { n += 1 }
	n = min(n, max(max_levels, 1))

	levels := make([][]u8, n, allocator)
	sizes := make([][2]int, n, allocator)

	// level 0: a tight copy of the rectangle so later levels read it with a simple stride
	l0 := make([]u8, w0 * h0 * 4, allocator)
	if l0 == nil { return }
	for row in 0 ..< h0 {
		copy(l0[row * w0 * 4:][:w0 * 4], src.pix[((y0 + row) * src.w + x0) * 4:][:w0 * 4])
	}
	levels[0], sizes[0] = l0, {w0, h0}

	pw, ph := w0, h0
	prev := l0
	for i in 1 ..< n {
		nw, nh := max((pw + 1) / 2, 1), max((ph + 1) / 2, 1)
		dst := make([]u8, nw * nh * 4, allocator)
		if dst == nil { break }
		mip_downsample(prev, pw, ph, dst, nw, nh)
		levels[i], sizes[i] = dst, {nw, nh}
		prev, pw, ph = dst, nw, nh
		if nw == 1 && nh == 1 { levels = levels[:i + 1]; sizes = sizes[:i + 1]; break }
	}
	m.levels, m.sizes = levels, sizes
	return m, true
}

// A 2x box reduction of a premultiplied RGBA level (odd sides average the three or one spare texels of the border too,
// so no edge is dropped).
@(private)
mip_downsample :: proc "contextless" (src: []u8, sw, sh: int, dst: []u8, dw, dh: int) {
	for dy in 0 ..< dh {
		sy0 := dy * 2
		sy1 := min(sy0 + 1, sh - 1)
		for dx in 0 ..< dw {
			sx0 := dx * 2
			sx1 := min(sx0 + 1, sw - 1)
			a := src[(sy0 * sw + sx0) * 4:][:4]
			b := src[(sy0 * sw + sx1) * 4:][:4]
			c := src[(sy1 * sw + sx0) * 4:][:4]
			d := src[(sy1 * sw + sx1) * 4:][:4]
			o := dst[(dy * dw + dx) * 4:][:4]
			for k in 0 ..< 4 {
				o[k] = u8((u32(a[k]) + u32(b[k]) + u32(c[k]) + u32(d[k]) + 2) / 4)
			}
		}
	}
}

// Bilinear sample of one mip level at texel (u, v) (texel i covers [i, i + 1)), premultiplied, with the source's wrap
// and the clamped-to-edge default. The level's texel coordinates are the source's scaled by 1 / 2^level.
@(private)
mip_sample_level :: proc "contextless" (m: ^Mip_Chain, level: int, s: ^Image_Source, u, v: f64) -> [4]f32 {
	lvl := clamp(level, 0, len(m.levels) - 1)
	data := m.levels[lvl]
	lw, lh := m.sizes[lvl][0], m.sizes[lvl][1]
	// the source rectangle maps to [0, lw) x [0, lh) of this level
	scale := 1.0 / f64(int(1) << uint(lvl))
	lu, lv := (u - f64(s.x0)) * scale, (v - f64(s.y0)) * scale
	fu, fv := lu - 0.5, lv - 0.5
	iu, iv := math.floor(fu), math.floor(fv)
	tx, ty := f32(fu - iu), f32(fv - iv)
	x, y := int(iu), int(iv)
	c00 := mip_fetch(data, lw, lh, s, x, y)
	c10 := mip_fetch(data, lw, lh, s, x + 1, y)
	c01 := mip_fetch(data, lw, lh, s, x, y + 1)
	c11 := mip_fetch(data, lw, lh, s, x + 1, y + 1)
	top := c00 + (c10 - c00) * tx
	bot := c01 + (c11 - c01) * tx
	return top + (bot - top) * ty
}

// A texel of a mip level, honoring the source's wrap modes (the level's extent is [0, lw) x [0, lh)).
@(private)
mip_fetch :: proc "contextless" (data: []u8, lw, lh: int, s: ^Image_Source, x, y: int) -> [4]f32 {
	x, y := x, y
	switch s.wrap_x {
	case .None: if x < 0 || x >= lw { return {} }
	case .Clamp: x = clamp(x, 0, lw - 1)
	case .Repeat: x = ((x % lw) + lw) % lw
	}
	switch s.wrap_y {
	case .None: if y < 0 || y >= lh { return {} }
	case .Clamp: y = clamp(y, 0, lh - 1)
	case .Repeat: y = ((y % lh) + lh) % lh
	}
	p := data[(y * lw + x) * 4:][:4]
	return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} * (1.0 / 255.0)
}

// Trilinear sample: the level of detail from the source footprint of one device pixel (`lod`, in levels where 0 is the
// source and each unit a halving), bilinear in the two levels around it, blended. Used for High quality.
@(private)
mip_sample_trilinear :: proc "contextless" (m: ^Mip_Chain, s: ^Image_Source, u, v, lod: f64) -> [4]f32 {
	top := len(m.levels) - 1
	l := clamp(lod, 0, f64(top))
	l0 := int(math.floor(l))
	if l0 >= top { return mip_sample_level(m, top, s, u, v) }
	f := f32(l - f64(l0))
	a := mip_sample_level(m, l0, s, u, v)
	b := mip_sample_level(m, l0 + 1, s, u, v)
	return a + (b - a) * f
}
