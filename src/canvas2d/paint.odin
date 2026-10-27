package canvas2d

import "core:math"

// Colors are [4]f32 = red, green, blue, alpha in 0..1, sRGB-encoded; "straight" unless a name says premultiplied.

premultiply :: #force_inline proc "contextless" (c: [4]f32) -> [4]f32 { return {c.r * c.a, c.g * c.a, c.b * c.a, c.a} }

////////////////////////////////
// Gradients

Gradient_Kind :: enum u8 { Linear, Radial, Conic }

Color_Stop :: struct {
	offset: f64,
	color:  [4]f32,   // straight
}

// createLinearGradient / createRadialGradient / createConicGradient. Shared by the objects scripts hold and by the
// states that use them: reference counted (`gradient_release`).
Gradient :: struct {
	refs:   int,
	kind:   Gradient_Kind,
	x0, y0, r0: f64,   // start circle (conic: x0, y0 = center, r0 = start angle)
	x1, y1, r1: f64,   // end circle
	stops:  [dynamic]Color_Stop,
}

gradient_linear :: proc(x0, y0, x1, y1: f64) -> ^Gradient {
	g := new(Gradient)
	g.refs, g.kind, g.x0, g.y0, g.x1, g.y1 = 1, .Linear, x0, y0, x1, y1
	return g
}

gradient_radial :: proc(x0, y0, r0, x1, y1, r1: f64) -> ^Gradient {
	g := new(Gradient)
	g.refs, g.kind, g.x0, g.y0, g.r0, g.x1, g.y1, g.r1 = 1, .Radial, x0, y0, r0, x1, y1, r1
	return g
}

gradient_conic :: proc(angle, x, y: f64) -> ^Gradient {
	g := new(Gradient)
	g.refs, g.kind, g.x0, g.y0, g.r0 = 1, .Conic, x, y, angle
	return g
}

gradient_retain :: proc(g: ^Gradient) -> ^Gradient {
	if g != nil { g.refs += 1 }
	return g
}

gradient_release :: proc(g: ^Gradient) {
	if g == nil { return }
	g.refs -= 1
	if g.refs <= 0 {
		delete(g.stops)
		free(g)
	}
}

// Most stops one gradient keeps (each insertion shifts the ones after it).
MAX_STOPS :: 1 << 16

// addColorStop: stops with the same offset keep the order they were added in.
gradient_add_stop :: proc(g: ^Gradient, offset: f64, color: [4]f32) {
	if len(g.stops) >= MAX_STOPS { return }
	i := len(g.stops)
	for i > 0 && g.stops[i - 1].offset > offset { i -= 1 }
	inject_at(&g.stops, i, Color_Stop{offset, color})
}

// The straight color at position t (not clamped: before the first stop and after the last, the end colors).
gradient_color :: proc(g: ^Gradient, t: f64) -> [4]f32 {
	n := len(g.stops)
	if n == 0 { return {} }
	if t != t { return g.stops[0].color }
	if t <= g.stops[0].offset { return g.stops[0].color }
	if t >= g.stops[n - 1].offset { return g.stops[n - 1].color }
	for i in 1 ..< n {
		b := g.stops[i]
		if t < b.offset {
			a := g.stops[i - 1]
			d := b.offset - a.offset
			if d <= 0 { return b.color }
			f := f32((t - a.offset) / d)
			return a.color + (b.color - a.color) * f
		}
	}
	return g.stops[n - 1].color
}

// Position along the gradient of a point of the gradient's own (user) space; ok = false where nothing is painted (a
// radial gradient has no circle through the point, a degenerate line).
gradient_t :: proc(g: ^Gradient, p: [2]f64) -> (t: f64, ok: bool) {
	switch g.kind {
	case .Linear:
		dx, dy := g.x1 - g.x0, g.y1 - g.y0
		l := dx * dx + dy * dy
		if l == 0 { return 0, false }
		return ((p.x - g.x0) * dx + (p.y - g.y0) * dy) / l, true
	case .Conic:
		a := math.atan2(p.y - g.y0, p.x - g.x0) - g.r0
		t = a / (2 * math.PI)
		t -= math.floor(t)
		return t, true
	case .Radial:
		// the largest s with r(s) >= 0 such that p is on the circle of center c0 + s (c1 - c0) and radius r0 + s (r1 - r0)
		cdx, cdy, dr := g.x1 - g.x0, g.y1 - g.y0, g.r1 - g.r0
		pdx, pdy := p.x - g.x0, p.y - g.y0
		a := cdx * cdx + cdy * cdy - dr * dr
		b := pdx * cdx + pdy * cdy + g.r0 * dr
		c := pdx * pdx + pdy * pdy - g.r0 * g.r0
		valid :: proc(g: ^Gradient, s: f64) -> bool { return g.r0 + s * (g.r1 - g.r0) >= 0 }
		if abs(a) < 1e-12 {
			if abs(b) < 1e-12 { return 0, false }
			s := c / (2 * b)
			return s, valid(g, s)
		}
		disc := b * b - a * c
		if disc < 0 { return 0, false }
		sq := math.sqrt(disc)
		s1, s2 := (b + sq) / a, (b - sq) / a
		if s1 < s2 { s1, s2 = s2, s1 }
		if valid(g, s1) { return s1, true }
		if valid(g, s2) { return s2, true }
		return 0, false
	}
	return 0, false
}

////////////////////////////////
// Patterns and image sources

Wrap :: enum u8 {
	None,     // outside the source: transparent
	Clamp,    // outside the source: its nearest edge pixel
	Repeat,
}

// createPattern: a snapshot of the image (the specification takes it at creation), repeated as asked.
Pattern :: struct {
	refs:      int,
	bmp:       Bitmap,      // premultiplied copy
	repeat_x:  bool,
	repeat_y:  bool,
	transform: Matrix,      // setTransform
}

pattern_create :: proc(src: ^Bitmap, repeat_x, repeat_y: bool, max_bytes := max(int)) -> ^Pattern {
	bmp, ok := bitmap_clone(src, max_bytes)
	if !ok { return nil }
	p := new(Pattern)
	p.refs, p.bmp, p.repeat_x, p.repeat_y, p.transform = 1, bmp, repeat_x, repeat_y, IDENTITY
	return p
}

pattern_retain :: proc(p: ^Pattern) -> ^Pattern {
	if p != nil { p.refs += 1 }
	return p
}

pattern_release :: proc(p: ^Pattern) {
	if p == nil { return }
	p.refs -= 1
	if p.refs <= 0 {
		bitmap_destroy(&p.bmp)
		free(p)
	}
}

// Where a sampled image comes from: texels [x0, x1) x [y0, y1) of `bmp`, what lies outside it, and the filter.
Image_Source :: struct {
	bmp:        ^Bitmap,
	x0, y0, x1, y1: int,
	wrap_x, wrap_y: Wrap,
	smooth:     bool,              // bilinear; else nearest
	quality:    Smoothing_Quality, // how a shrunk image is resampled (Medium / High use mips, below)
	mips:       ^Mip_Chain,        // Medium / High: a box-filtered pyramid of the source rectangle (nil: not built)
	lod:        f64,               // levels of detail one device pixel spans in the source (log2 of texels per pixel); <= 0 enlarging
}

@(private)
fetch :: #force_inline proc(s: ^Image_Source, x, y: int) -> [4]f32 {
	x, y := x, y
	w, h := s.x1 - s.x0, s.y1 - s.y0
	switch s.wrap_x {
	case .None: if x < s.x0 || x >= s.x1 { return {} }
	case .Clamp: x = clamp(x, s.x0, s.x1 - 1)
	case .Repeat: x = s.x0 + ((x - s.x0) % w + w) % w
	}
	switch s.wrap_y {
	case .None: if y < s.y0 || y >= s.y1 { return {} }
	case .Clamp: y = clamp(y, s.y0, s.y1 - 1)
	case .Repeat: y = s.y0 + ((y - s.y0) % h + h) % h
	}
	p := s.bmp.pix[(y * s.bmp.w + x) * 4:][:4]
	return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} * (1.0 / 255.0)
}

// The premultiplied color of the source at (u, v), in texel units (texel i covers [i, i + 1)). With a mip chain built
// (Medium / High quality on a shrunk image), it samples the right level of detail; otherwise it is plain bilinear of
// the source, as Low quality and enlarging always are.
sample :: proc(s: ^Image_Source, u, v: f64) -> [4]f32 {
	if s.x1 <= s.x0 || s.y1 <= s.y0 { return {} }
	if !s.smooth {
		return fetch(s, int(math.floor(u)), int(math.floor(v)))
	}
	if s.mips != nil && len(s.mips.levels) > 0 && s.lod > 0 {
		if s.quality == .High {
			return mip_sample_trilinear(s.mips, s, u, v, s.lod)
		}
		// Medium: the nearest single level (rounded), bilinear within it
		return mip_sample_level(s.mips, int(s.lod + 0.5), s, u, v)
	}
	fu, fv := u - 0.5, v - 0.5
	iu, iv := math.floor(fu), math.floor(fv)
	tx, ty := f32(fu - iu), f32(fv - iv)
	x, y := int(clamp(iu, -1e9, 1e9)), int(clamp(iv, -1e9, 1e9))
	c00, c10 := fetch(s, x, y), fetch(s, x + 1, y)
	c01, c11 := fetch(s, x, y + 1), fetch(s, x + 1, y + 1)
	top := c00 + (c10 - c00) * tx
	bot := c01 + (c11 - c01) * tx
	return top + (bot - top) * ty
}

////////////////////////////////
// Paint: what a fill puts down

Paint_Kind :: enum u8 { Solid, Gradient, Pattern, Image }

Paint :: struct {
	kind:    Paint_Kind,
	color:   [4]f32,        // straight (Solid)
	premul:  [4]f32,        // premultiplied (Solid)
	s8:      [4]u32,        // the same on 0..255 (Solid)
	lut:     [][4]u8,       // Gradient: premultiplied colors along 0..1 (paint_lut), nil: evaluated per pixel
	grad:    ^Gradient,
	pat:     ^Pattern,
	img:     Image_Source,  // Image: the source rectangle; Pattern keeps its own
	inv:     Matrix,        // device space -> the space of the gradient / pattern / image's texels
	pat_mips: Mip_Chain,    // Pattern on Medium / High quality, shrunk: the pyramid of pat.bmp
	has_pat_mips: bool,     // pat_mips is built (else the pattern is plain bilinear)
}

LUT_SIZE :: 1024

paint_solid :: proc(c: [4]f32) -> Paint {
	pm := premultiply(c)
	return Paint{kind = .Solid, color = c, premul = pm, s8 = {u32(pm.r * 255 + 0.5), u32(pm.g * 255 + 0.5), u32(pm.b * 255 + 0.5), u32(pm.a * 255 + 0.5)}}
}

// The premultiplied color at device pixel (x, y) (its center is sampled).
paint_at :: proc(p: ^Paint, x, y: int) -> [4]f32 {
	switch p.kind {
	case .Solid: return p.premul
	case .Gradient:
		q := matrix_apply(p.inv, {f64(x) + 0.5, f64(y) + 0.5})
		t, ok := gradient_t(p.grad, q)
		if !ok { return {} }
		return premultiply(gradient_color(p.grad, clamp(t, 0, 1)))
	case .Pattern:
		q := matrix_apply(p.inv, {f64(x) + 0.5, f64(y) + 0.5})
		src := Image_Source{bmp = &p.pat.bmp, x0 = 0, y0 = 0, x1 = p.pat.bmp.w, y1 = p.pat.bmp.h,
			wrap_x = p.pat.repeat_x ? .Repeat : .None, wrap_y = p.pat.repeat_y ? .Repeat : .None, smooth = p.img.smooth,
			quality = p.img.quality, mips = p.has_pat_mips ? &p.pat_mips : nil, lod = p.img.lod}
		return sample(&src, q.x, q.y)
	case .Image:
		q := matrix_apply(p.inv, {f64(x) + 0.5, f64(y) + 0.5})
		return sample(&p.img, q.x, q.y)
	}
	return {}
}

// The level of detail one device pixel spans, from the device -> texel inverse `inv`: log2 of the source texels a unit
// device step covers (the larger singular value of the linear part). <= 0 when the image is enlarged (no mip wanted).
image_lod :: proc "contextless" (inv: Matrix) -> f64 {
	big, _ := matrix_scales(inv)
	if big <= 1 { return 0 }
	return math.log2(big)
}

// A copy of texels [x0, x1) x [y0, y1) of `src` reduced by an integer factor `f` in each direction (box filter): the
// source a strongly shrunk image is sampled from, so that it does not alias. The result is a whole bitmap.
bitmap_reduce :: proc(src: ^Bitmap, x0, y0, x1, y1, f: int, max_bytes := max(int)) -> (r: Bitmap, ok: bool) {
	w, h := (x1 - x0 + f - 1) / f, (y1 - y0 + f - 1) / f
	r, ok = bitmap_create(max(w, 1), max(h, 1), max_bytes, context.allocator)
	if !ok { return }
	for dy in 0 ..< h {
		for dx in 0 ..< w {
			sum: [4]u32
			n := u32(0)
			for yy in 0 ..< f {
				sy := y0 + dy * f + yy
				if sy >= y1 { break }
				for xx in 0 ..< f {
					sx := x0 + dx * f + xx
					if sx >= x1 { break }
					px := src.pix[(sy * src.w + sx) * 4:][:4]
					sum += {u32(px[0]), u32(px[1]), u32(px[2]), u32(px[3])}
					n += 1
				}
			}
			d := r.pix[(dy * r.w + dx) * 4:][:4]
			if n > 0 {
				d[0], d[1], d[2], d[3] = u8((sum[0] + n / 2) / n), u8((sum[1] + n / 2) / n), u8((sum[2] + n / 2) / n), u8((sum[3] + n / 2) / n)
			}
		}
	}
	return
}
