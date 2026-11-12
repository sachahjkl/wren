package canvas2d

import "base:intrinsics"
import "core:math"
import "core:simd"

// Rows of pixels at once: source-over of premultiplied RGBA8 (job_row's common case: a canvas with alpha, the default
// operator), the premultiplication of putImageData, and the sources of a row of a drawn image. Four pixels go through
// one step in 16-bit lanes; each vector routine keeps the one-pixel routine it must match to the bit beside it
// (span_test.odin compares them).

// Coverage at or above this counts as full: the source is not scaled (a coverage of 0.998 scales 255 to 254.99).
FULL_COVERAGE :: f32(0.998)

@(private = "file") U8x16 :: #simd[16]u8
@(private = "file") U16x16 :: #simd[16]u16
@(private = "file") U32x4 :: #simd[4]u32
@(private = "file") F32x16 :: #simd[16]f32
@(private = "file") F32x4 :: #simd[4]f32

// What the rows of one context reuse, so that a draw allocates nothing per row.
Span_Scratch :: struct {
	a:   [dynamic]f32,   // a row's coverage times globalAlpha and the clip
	src: [dynamic]u8,    // a row's premultiplied source pixels
}

span_scratch_destroy :: proc(s: ^Span_Scratch) {
	delete(s.a)
	delete(s.src)
	s^ = {}
}

// floor(x / 255) for x <= 65407, in each lane: the division the blend and the premultiplication round with.
@(private = "file")
div255 :: #force_inline proc "contextless" (x: U16x16) -> U16x16 {
	return simd.shr(x + 1 + simd.shr(x, U16x16(8)), U16x16(8))
}

////////////////////////////////
// Source-over

// One pixel: the source `s` (premultiplied, 0..255) scaled by the coverage `a`, over the pixel. The reference of the
// vector routines below, and what job_row did per pixel before.
@(private)
over_px_scalar :: #force_inline proc "contextless" (px: []u8, s: [4]u32, a: f32) {
	if a <= 0 { return }
	s := s
	if a < FULL_COVERAGE {
		s[0], s[1], s[2], s[3] = u32(f32(s[0]) * a + 0.5), u32(f32(s[1]) * a + 0.5), u32(f32(s[2]) * a + 0.5), u32(f32(s[3]) * a + 0.5)
	}
	sa := s[3]
	if sa == 0 { return }
	if sa >= 255 {
		px[0], px[1], px[2], px[3] = u8(s[0]), u8(s[1]), u8(s[2]), 255
		return
	}
	inv := 255 - sa
	px[0] = u8(min(s[0] + (u32(px[0]) * inv + 127) / 255, 255))
	px[1] = u8(min(s[1] + (u32(px[1]) * inv + 127) / 255, 255))
	px[2] = u8(min(s[2] + (u32(px[2]) * inv + 127) / 255, 255))
	px[3] = u8(min(sa + (u32(px[3]) * inv + 127) / 255, 255))
}

// Four pixels of over_px_scalar. The coverage scales the source in f32, as the reference does, so that the rounding is
// the same; the rest is exact in 16 bits (255 * 255 + 127 fits).
@(private = "file")
over4 :: #force_inline proc "contextless" (d: ^u8, s8: U8x16, a4: F32x4) {
	// full coverage (and NaN, which compares false) leaves the source as it is; 0 or less makes it vanish
	a := simd.select(simd.lanes_lt(a4, F32x4(FULL_COVERAGE)), simd.max(a4, F32x4(0)), F32x4(1))
	x, y, z, w := simd.extract(a, 0), simd.extract(a, 1), simd.extract(a, 2), simd.extract(a, 3)
	af := F32x16{x, x, x, x, y, y, y, y, z, z, z, z, w, w, w, w}
	s := cast(U16x16)(cast(F32x16)s8 * af + 0.5)
	sa := simd.shuffle(s, s, 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15)
	// a source whose alpha rounds to 0 leaves the pixel alone, even if its color does not
	s = simd.select(simd.lanes_eq(sa, U16x16(0)), U16x16(0), s)
	dv := cast(U16x16)intrinsics.unaligned_load((^U8x16)(d))
	q := div255(dv * (255 - sa) + 127)
	intrinsics.unaligned_store((^U8x16)(d), cast(U8x16)simd.min(s + q, U16x16(255)))
}

// Source-over of the solid premultiplied color `s` onto the len(a) pixels of `dst`, pixel i with coverage a[i]. An
// opaque color fully covering a run is stored, 32 bits a pixel.
over_span_solid :: proc "contextless" (dst: []u8, s: [4]u32, a: []f32) #no_bounds_check {
	n := len(a)
	if n == 0 || len(dst) < n * 4 { return }
	if s[3] == 0 { return }   // (a transparent color stays transparent at any coverage)
	b := [4]u8{u8(s[0]), u8(s[1]), u8(s[2]), u8(s[3])}
	src8 := transmute(U8x16)[4][4]u8{b, b, b, b}
	opaque := s[3] >= 255
	color := transmute(u32)[4]u8{b[0], b[1], b[2], 255}
	i := 0
	for i < n {
		if opaque && !(a[i] < FULL_COVERAGE) {
			for i < n && !(a[i] < FULL_COVERAGE) {
				intrinsics.unaligned_store((^u32)(&dst[i * 4]), color)
				i += 1
			}
			continue
		}
		if i + 4 <= n {
			over4(&dst[i * 4], src8, intrinsics.unaligned_load((^F32x4)(&a[i])))
			i += 4
		} else {
			over_px_scalar(dst[i * 4:][:4], s, a[i])
			i += 1
		}
	}
}

// The reference of over_span_solid.
over_span_solid_scalar :: proc "contextless" (dst: []u8, s: [4]u32, a: []f32) {
	for i in 0 ..< len(a) { over_px_scalar(dst[i * 4:][:4], s, a[i]) }
}

// Source-over of the premultiplied pixels `src` onto the len(a) pixels of `dst`, pixel i with coverage a[i]. Four
// opaque pixels fully covered are copied.
over_span :: proc "contextless" (dst, src: []u8, a: []f32) #no_bounds_check {
	n := len(a)
	if n == 0 || len(dst) < n * 4 || len(src) < n * 4 { return }
	i := 0
	for ; i + 4 <= n; i += 4 {
		s8 := intrinsics.unaligned_load((^U8x16)(&src[i * 4]))
		a4 := intrinsics.unaligned_load((^F32x4)(&a[i]))
		full := simd.reduce_and(simd.lanes_ge(a4, F32x4(FULL_COVERAGE))) != 0
		if full && simd.reduce_and(transmute(U32x4)s8) & 0xFF00_0000 == 0xFF00_0000 {
			intrinsics.unaligned_store((^U8x16)(&dst[i * 4]), s8)
			continue
		}
		over4(&dst[i * 4], s8, a4)
	}
	for ; i < n; i += 1 {
		p := src[i * 4:]
		over_px_scalar(dst[i * 4:][:4], {u32(p[0]), u32(p[1]), u32(p[2]), u32(p[3])}, a[i])
	}
}

// The reference of over_span.
over_span_scalar :: proc "contextless" (dst, src: []u8, a: []f32) {
	for i in 0 ..< len(a) {
		p := src[i * 4:]
		over_px_scalar(dst[i * 4:][:4], {u32(p[0]), u32(p[1]), u32(p[2]), u32(p[3])}, a[i])
	}
}

////////////////////////////////
// Premultiplication (putImageData)

// `n` straight RGBA8 pixels of `src` premultiplied into `dst`: each channel round(c * a / 255), ties up, alpha kept.
premultiply_row :: proc "contextless" (dst, src: []u8, n: int) #no_bounds_check {
	if n <= 0 || len(dst) < n * 4 || len(src) < n * 4 { return }
	i := 0
	for ; i + 4 <= n; i += 4 {
		v := cast(U16x16)intrinsics.unaligned_load((^U8x16)(&src[i * 4]))
		// each color times its pixel's alpha, the alpha times 255: (a * 255 + 127) / 255 is a again
		m := simd.shuffle(v, U16x16(255), 3, 3, 3, 16, 7, 7, 7, 16, 11, 11, 11, 16, 15, 15, 15, 16)
		intrinsics.unaligned_store((^U8x16)(&dst[i * 4]), cast(U8x16)div255(v * m + 127))
	}
	premultiply_row_scalar(dst[i * 4:], src[i * 4:], n - i)
}

// The reference of premultiply_row, and what bitmap_write_straight did per pixel before.
premultiply_row_scalar :: proc "contextless" (dst, src: []u8, n: int) {
	for i in 0 ..< n {
		s, d := src[i * 4:][:4], dst[i * 4:][:4]
		a := u32(s[3])
		if a == 255 {
			d[0], d[1], d[2], d[3] = s[0], s[1], s[2], 255
		} else {
			d[0] = u8((u32(s[0]) * a + 127) / 255)
			d[1] = u8((u32(s[1]) * a + 127) / 255)
			d[2] = u8((u32(s[2]) * a + 127) / 255)
			d[3] = u8(a)
		}
	}
}

////////////////////////////////
// Sources of a row

// The premultiplied RGBA8 of `p` at the len(a) device pixels from (x, y) along a row, for job_row's source-over. The
// result is either `buf` (resized) or, for an image drawn at its own size, the image's own row. Pixels with no
// coverage may be left as they were: nothing is drawn there.
@(private)
paint_row :: proc(p: ^Paint, x, y: int, a: []f32, buf: ^[dynamic]u8) -> []u8 {
	n := len(a)
	switch p.kind {
	case .Image:
		if src, ok := image_row(&p.img, p.inv, x, y, n, buf); ok { return src }
	case .Gradient:
		// a linear gradient is an affine function of x along a row: t is stepped, not computed from the matrix
		if p.grad.kind == .Linear && p.lut != nil {
			g := p.grad
			dx, dy := g.x1 - g.x0, g.y1 - g.y0
			len2 := dx * dx + dy * dy
			if len2 != 0 {
				q := matrix_apply(p.inv, {f64(x) + 0.5, f64(y) + 0.5})
				t := ((q.x - g.x0) * dx + (q.y - g.y0) * dy) / len2
				dt := (p.inv.a * dx + p.inv.b * dy) / len2
				resize(buf, n * 4)
				out := buf[:]
				for i in 0 ..< n {
					ti := t
					t += dt
					e := p.lut[ti == ti ? int(clamp(ti, 0, 1) * f64(LUT_SIZE - 1) + 0.5) : 0]
					out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = e[0], e[1], e[2], e[3]
				}
				return out
			}
		}
	case .Solid, .Pattern:
	}
	resize(buf, n * 4)
	out := buf[:]
	for i in 0 ..< n {
		if a[i] <= 0 { continue }
		f := paint_at(p, x + i, y)
		out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = u8(f.r * 255 + 0.5), u8(f.g * 255 + 0.5), u8(f.b * 255 + 0.5), u8(f.a * 255 + 0.5)
	}
	return out
}

// The n pixels of a drawn image from device pixel (x, y) along a row, `inv` taking device space to texels. Two cases,
// false for the others (sample per pixel then):
//   * an integer translation at scale 1: the texels are the image's own row (what sample gives, to the bit);
//   * a smoothed image without mips: (u, v) steps by the inverse's first column and the bilinear blend runs in fixed
//     point with weights in 1/256 (within one unit of sample).
@(private)
image_row :: proc(s: ^Image_Source, inv: Matrix, x, y, n: int, buf: ^[dynamic]u8) -> ([]u8, bool) {
	if s.x1 <= s.x0 || s.y1 <= s.y0 || s.wrap_x != .Clamp || s.wrap_y != .Clamp { return nil, false }
	if s.smooth && s.mips != nil && len(s.mips.levels) > 0 && s.lod > 0 { return nil, false }
	b := s.bmp
	if inv.a == 1 && inv.b == 0 && inv.c == 0 && inv.d == 1 && abs(inv.e) < 1e9 && abs(inv.f) < 1e9 &&
	   inv.e == math.floor(inv.e) && inv.f == math.floor(inv.f) {
		line := b.pix[clamp(y + int(inv.f), s.y0, s.y1 - 1) * b.w * 4:][:b.w * 4]
		bx := x + int(inv.e)
		if bx >= s.x0 && bx + n <= s.x1 { return line[bx * 4:][:n * 4], true }
		resize(buf, n * 4)
		out := buf[:]
		for i in 0 ..< n {
			sx := clamp(bx + i, s.x0, s.x1 - 1)
			copy(out[i * 4:][:4], line[sx * 4:][:4])
		}
		return out, true
	}
	if !s.smooth { return nil, false }
	image_row_bilinear(s, inv, x, y, n, buf)
	return buf[:], true
}

// The bilinear half of image_row. Each (u, v) is computed from the row's first one, not accumulated, so a long row
// does not drift.
@(private)
image_row_bilinear :: proc(s: ^Image_Source, inv: Matrix, x, y, n: int, buf: ^[dynamic]u8) {
	resize(buf, n * 4)
	out := buf[:]
	b := s.bmp
	q := matrix_apply(inv, {f64(x) + 0.5, f64(y) + 0.5})
	for i in 0 ..< n {
		fu, fv := q.x + f64(i) * inv.a - 0.5, q.y + f64(i) * inv.b - 0.5
		iu, iv := math.floor(fu), math.floor(fv)
		wx, wy := u32((fu - iu) * 256 + 0.5), u32((fv - iv) * 256 + 0.5)
		tx, ty := int(clamp(iu, -1e9, 1e9)), int(clamp(iv, -1e9, 1e9))
		xa, xb := clamp(tx, s.x0, s.x1 - 1), clamp(tx + 1, s.x0, s.x1 - 1)
		ya, yb := clamp(ty, s.y0, s.y1 - 1), clamp(ty + 1, s.y0, s.y1 - 1)
		p00, p10 := b.pix[(ya * b.w + xa) * 4:][:4], b.pix[(ya * b.w + xb) * 4:][:4]
		p01, p11 := b.pix[(yb * b.w + xa) * 4:][:4], b.pix[(yb * b.w + xb) * 4:][:4]
		o := out[i * 4:][:4]
		for k in 0 ..< 4 {
			top := u32(p00[k]) * (256 - wx) + u32(p10[k]) * wx
			bot := u32(p01[k]) * (256 - wx) + u32(p11[k]) * wx
			o[k] = u8((top * (256 - wy) + bot * wy + 32768) >> 16)
		}
	}
}
