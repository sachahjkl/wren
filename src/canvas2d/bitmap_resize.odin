package canvas2d

import "core:math"

// Resizing a premultiplied bitmap to a target size, for createImageBitmap's resizeWidth / resizeHeight / resizeQuality
// (HTML §2.9.5). The work stays native: the image source is already a premultiplied `Bitmap`, the result is a new
// premultiplied `Bitmap` the caller owns. Three qualities, matching the ImageBitmap `ResizeQuality` enum:
//   * "pixelated" : nearest neighbour (no smoothing);
//   * "low"       : bilinear of the source (fast; a strong shrink aliases);
//   * "medium"    : a box-reduced level then bilinear (most aliasing gone, little cost);
//   * "high"      : a separable triangle (tent) filter whose radius follows the scale, so any reduction is smooth with
//                   no seams and any enlargement is a clean bilinear-equivalent.
// Premultiplied channels are resampled directly (the right thing: a transparent texel contributes nothing).

Resize_Quality :: enum u8 {
	Pixelated,
	Low,
	Medium,
	High,
}

resize_quality_from :: proc "contextless" (s: string) -> Resize_Quality {
	switch s {
	case "pixelated": return .Pixelated
	case "medium":    return .Medium
	case "high":      return .High
	case:             return .Low
	}
}

// A new premultiplied bitmap of `dst_w` x `dst_h` holding `src` scaled to that size. false: a side is out of range, the
// byte count would pass `max_bytes`, or memory ran out. When the size is unchanged the source is cloned.
bitmap_resize_to :: proc(src: ^Bitmap, dst_w, dst_h: int, quality: Resize_Quality, max_bytes := max(int), allocator := context.allocator) -> (out: Bitmap, ok: bool) {
	if dst_w <= 0 || dst_h <= 0 { return }
	if src.w == dst_w && src.h == dst_h { return bitmap_clone(src, max_bytes, allocator) }
	out, ok = bitmap_create(dst_w, dst_h, max_bytes, allocator)
	if !ok { return }
	if src.w <= 0 || src.h <= 0 { return out, true }   // a 0-area source resizes to transparent

	switch quality {
	case .Pixelated: resize_nearest(src, &out)
	case .Low:       resize_bilinear(src, &out)
	case .Medium:    resize_medium(src, &out)
	case .High:      resize_triangle(src, &out)
	}
	bitmap_touch_all(&out)
	return out, true
}

@(private = "file")
resize_nearest :: proc "contextless" (src, out: ^Bitmap) {
	sx_ratio := f64(src.w) / f64(out.w)
	sy_ratio := f64(src.h) / f64(out.h)
	for dy in 0 ..< out.h {
		sy := clamp(int((f64(dy) + 0.5) * sy_ratio), 0, src.h - 1)
		for dx in 0 ..< out.w {
			sx := clamp(int((f64(dx) + 0.5) * sx_ratio), 0, src.w - 1)
			copy(out.pix[(dy * out.w + dx) * 4:][:4], src.pix[(sy * src.w + sx) * 4:][:4])
		}
	}
}

@(private = "file")
resize_bilinear :: proc "contextless" (src, out: ^Bitmap) {
	sx_ratio := f64(src.w) / f64(out.w)
	sy_ratio := f64(src.h) / f64(out.h)
	for dy in 0 ..< out.h {
		fy := (f64(dy) + 0.5) * sy_ratio - 0.5
		iy := int(math.floor(fy))
		ty := f32(fy - f64(iy))
		for dx in 0 ..< out.w {
			fx := (f64(dx) + 0.5) * sx_ratio - 0.5
			ix := int(math.floor(fx))
			tx := f32(fx - f64(ix))
			c00 := fetch_clamped(src, ix, iy)
			c10 := fetch_clamped(src, ix + 1, iy)
			c01 := fetch_clamped(src, ix, iy + 1)
			c11 := fetch_clamped(src, ix + 1, iy + 1)
			top := c00 + (c10 - c00) * tx
			bot := c01 + (c11 - c01) * tx
			store(out, dx, dy, top + (bot - top) * ty)
		}
	}
}

// Box-reduce the source to the nearest level above the target, then bilinear of that (the Medium rule, matching the
// draw path's Medium sampler).
@(private = "file")
resize_medium :: proc(src, out: ^Bitmap) {
	// how many halvings keep the level at or above the destination on both axes
	level := 0
	w, h := src.w, src.h
	for (w + 1) / 2 >= out.w && (h + 1) / 2 >= out.h && (w > 1 || h > 1) {
		w, h = max((w + 1) / 2, 1), max((h + 1) / 2, 1)
		level += 1
	}
	if level == 0 { resize_bilinear(src, out); return }
	m, mok := mip_build(src, 0, 0, src.w, src.h, level + 1, context.temp_allocator)
	if !mok || level >= len(m.levels) { resize_bilinear(src, out); return }
	lvl := m.levels[level]
	lw, lh := m.sizes[level][0], m.sizes[level][1]
	tmp := Bitmap{w = lw, h = lh, pix = lvl}
	resize_bilinear(&tmp, out)
}

// A separable triangle (tent) filter. For a shrink the tent width on each axis is the scale factor (a proper area
// average); for an enlargement it is 1 (plain bilinear). Done in two passes through a premultiplied float scratch so a
// big image is O(src + dst) in the kernel, not O(src*dst).
@(private = "file")
resize_triangle :: proc(src, out: ^Bitmap) {
	// horizontal pass: src.w -> out.w, height stays src.h
	mid := make([]f32, out.w * src.h * 4, context.temp_allocator)
	if mid == nil { resize_bilinear(src, out); return }
	resize_axis_h(src, mid, out.w)
	resize_axis_v(mid, out.w, src.h, out)
}

@(private = "file")
resize_axis_h :: proc "contextless" (src: ^Bitmap, mid: []f32, dw: int) {
	ratio := f64(src.w) / f64(dw)
	scale := max(ratio, 1.0)              // tent radius grows when shrinking
	support := scale
	inv := 1.0 / scale
	for dx in 0 ..< dw {
		center := (f64(dx) + 0.5) * ratio
		lo := max(int(math.floor(center - support)), 0)
		hi := min(int(math.ceil(center + support)), src.w - 1)
		for y in 0 ..< src.h {
			acc: [4]f32
			wsum: f32
			for sx in lo ..= hi {
				t := f32(math.abs((f64(sx) + 0.5 - center) * inv))
				if t >= 1 { continue }
				wt := 1 - t
				p := src.pix[(y * src.w + sx) * 4:][:4]
				acc += [4]f32{f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} * wt
				wsum += wt
			}
			o := mid[(y * dw + dx) * 4:][:4]
			if wsum > 0 { acc /= wsum }
			o[0], o[1], o[2], o[3] = acc[0], acc[1], acc[2], acc[3]
		}
	}
}

@(private = "file")
resize_axis_v :: proc "contextless" (mid: []f32, mw, sh: int, out: ^Bitmap) {
	ratio := f64(sh) / f64(out.h)
	scale := max(ratio, 1.0)
	support := scale
	inv := 1.0 / scale
	for dy in 0 ..< out.h {
		center := (f64(dy) + 0.5) * ratio
		lo := max(int(math.floor(center - support)), 0)
		hi := min(int(math.ceil(center + support)), sh - 1)
		for dx in 0 ..< out.w {
			acc: [4]f32
			wsum: f32
			for sy in lo ..= hi {
				t := f32(math.abs((f64(sy) + 0.5 - center) * inv))
				if t >= 1 { continue }
				wt := 1 - t
				p := mid[(sy * mw + dx) * 4:][:4]
				acc += [4]f32{p[0], p[1], p[2], p[3]} * wt
				wsum += wt
			}
			if wsum > 0 { acc /= wsum }
			store(out, dx, dy, acc)
		}
	}
}

@(private = "file")
fetch_clamped :: proc "contextless" (b: ^Bitmap, x, y: int) -> [4]f32 {
	cx, cy := clamp(x, 0, b.w - 1), clamp(y, 0, b.h - 1)
	p := b.pix[(cy * b.w + cx) * 4:][:4]
	return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])}
}

@(private = "file")
store :: proc "contextless" (b: ^Bitmap, x, y: int, c: [4]f32) {
	p := b.pix[(y * b.w + x) * 4:][:4]
	// premultiplied: a channel may not exceed alpha, and all are 0..255
	a := clamp(c[3] + 0.5, 0, 255)
	p[0] = u8(clamp(c[0] + 0.5, 0, a))
	p[1] = u8(clamp(c[1] + 0.5, 0, a))
	p[2] = u8(clamp(c[2] + 0.5, 0, a))
	p[3] = u8(a)
}
