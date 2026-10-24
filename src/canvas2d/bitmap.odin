package canvas2d

import "base:runtime"

// Hard ceiling on one side of a bitmap: Direct3D 11's texture limit is 16384 on most hardware and 32767 is the
// largest size the browser would ever hold; the page's preferences (canvas.max_dimension, canvas.max_pixels) are
// tighter.
MAX_SIDE :: 32767

// Pixels are RGBA8, premultiplied alpha, sRGB-encoded (the canvas blends encoded values, as browsers do), rows top
// to bottom. `version` grows with every change; `dirty` is the part changed since `bitmap_clean` (half-open pixel
// rectangle, empty when min >= max): the shell uploads only that part to its texture.
Bitmap :: struct {
	w, h:      int,
	pix:       []u8,
	version:   u64,
	dirty_min: [2]int,
	dirty_max: [2]int,
	opaque:    bool,   // getContext("2d", { alpha: false }): alpha is always 1, the canvas is composited over black
	allocator: runtime.Allocator,
	uid:       u64,    // names the bitmap for the GPU's cache of uploaded sources (0: not a bitmap made by bitmap_create)
	accounted: int,    // bytes the owner charged to a budget for it (a GPU canvas charges what its pixels would take)
}

@(private)
next_bitmap_uid: u64

// A transparent bitmap. false: a side is over MAX_SIDE, the byte count would overflow or pass `max_bytes`, or the
// memory could not be had (the bitmap is then empty: 0 x 0).
bitmap_create :: proc(w, h: int, max_bytes := max(int), allocator := context.allocator) -> (b: Bitmap, ok: bool) {
	b.allocator = allocator
	if w < 0 || h < 0 || w > MAX_SIDE || h > MAX_SIDE { return }
	n := w * h * 4   // (at most 2^15 * 2^15 * 4 = 2^32: fits an int)
	if n > max_bytes { return }
	if n > 0 {
		err: runtime.Allocator_Error
		b.pix, err = make([]u8, n, allocator)
		if err != nil { return }
	}
	b.w, b.h = w, h
	next_bitmap_uid += 1
	b.uid = next_bitmap_uid
	bitmap_touch_all(&b)
	return b, true
}

// A bitmap with a size but no pixels: a canvas drawn on the GPU (its pixels are read back into `pix` when something needs
// them). `accounted` is what the owner charged for it.
bitmap_virtual :: proc(w, h: int, accounted: int) -> (b: Bitmap, ok: bool) {
	if w < 0 || h < 0 || w > MAX_SIDE || h > MAX_SIDE { return }
	next_bitmap_uid += 1
	return Bitmap{w = w, h = h, uid = next_bitmap_uid, accounted = accounted, allocator = context.allocator}, true
}

bitmap_destroy :: proc(b: ^Bitmap) {
	if b.pix != nil { delete(b.pix, b.allocator) }
	alloc := b.allocator
	b^ = {}
	b.allocator = alloc
}

// Transparent black everywhere, at a new size (the canvas's width / height changed). false: as bitmap_create (the
// old contents are then gone and the bitmap is 0 x 0).
bitmap_resize :: proc(b: ^Bitmap, w, h: int, max_bytes := max(int)) -> bool {
	ver := b.version
	alloc := b.allocator
	bitmap_destroy(b)
	nb, ok := bitmap_create(w, h, max_bytes, alloc)
	b^ = nb
	b.version = ver + 1
	return ok
}

// Marks [x0, x1) x [y0, y1) changed (clamped to the bitmap).
bitmap_touch :: proc "contextless" (b: ^Bitmap, ax0, ay0, ax1, ay1: int) {
	x0, y0, x1, y1 := max(ax0, 0), max(ay0, 0), min(ax1, b.w), min(ay1, b.h)
	if x0 >= x1 || y0 >= y1 { return }
	b.version += 1
	if b.dirty_min.x >= b.dirty_max.x || b.dirty_min.y >= b.dirty_max.y {
		b.dirty_min, b.dirty_max = {x0, y0}, {x1, y1}
		return
	}
	b.dirty_min = {min(b.dirty_min.x, x0), min(b.dirty_min.y, y0)}
	b.dirty_max = {max(b.dirty_max.x, x1), max(b.dirty_max.y, y1)}
}

bitmap_touch_all :: proc "contextless" (b: ^Bitmap) {
	b.version += 1
	b.dirty_min, b.dirty_max = {0, 0}, {b.w, b.h}
}

// The initial contents: transparent black, or opaque black for an opaque canvas.
bitmap_reset_contents :: proc "contextless" (b: ^Bitmap) {
	for i := 0; i < len(b.pix); i += 4 {
		b.pix[i], b.pix[i + 1], b.pix[i + 2], b.pix[i + 3] = 0, 0, 0, b.opaque ? 255 : 0
	}
	bitmap_touch_all(b)
}

bitmap_clean :: proc "contextless" (b: ^Bitmap) { b.dirty_min, b.dirty_max = {}, {} }

bitmap_has_dirty :: proc "contextless" (b: ^Bitmap) -> bool {
	return b.dirty_min.x < b.dirty_max.x && b.dirty_min.y < b.dirty_max.y
}

// Straight-alpha RGBA8 of a w x h block at (x, y), written to `out` (len >= w * h * 4, rows tightly packed) as
// getImageData and the shell's texture upload want it. The part of the block outside the bitmap is transparent black.
bitmap_read_straight :: proc(b: ^Bitmap, x, y, w, h: int, out: []u8) {
	if w <= 0 || h <= 0 || len(out) < w * h * 4 { return }
	for row in 0 ..< h {
		sy := y + row
		dst := out[row * w * 4:][:w * 4]
		if sy < 0 || sy >= b.h {
			for i in 0 ..< len(dst) { dst[i] = 0 }
			continue
		}
		for col in 0 ..< w {
			sx := x + col
			d := dst[col * 4:][:4]
			if sx < 0 || sx >= b.w { d[0], d[1], d[2], d[3] = 0, 0, 0, 0; continue }
			s := b.pix[(sy * b.w + sx) * 4:][:4]
			a := s[3]
			switch a {
			case 255: d[0], d[1], d[2], d[3] = s[0], s[1], s[2], 255
			case 0: d[0], d[1], d[2], d[3] = 0, 0, 0, 0
			case:
				// round(c * 255 / a), capped (a premultiplied channel may exceed alpha after rounding)
				d[0] = u8(min((u32(s[0]) * 255 + u32(a) / 2) / u32(a), 255))
				d[1] = u8(min((u32(s[1]) * 255 + u32(a) / 2) / u32(a), 255))
				d[2] = u8(min((u32(s[2]) * 255 + u32(a) / 2) / u32(a), 255))
				d[3] = a
			}
		}
	}
}

// Writes straight-alpha RGBA8 `src` (w x h, tightly packed, from (sx, sy) of it, `dw` x `dh` pixels) at (x, y) of the
// bitmap, premultiplying; no compositing, no transform, no clip (putImageData). Pixels outside the bitmap are skipped.
bitmap_write_straight :: proc(b: ^Bitmap, src: []u8, src_w: int, sx, sy, dw, dh: int, x, y: int) {
	if src_w <= 0 || dw <= 0 || dh <= 0 { return }
	for row in 0 ..< dh {
		dy := y + row
		if dy < 0 || dy >= b.h { continue }
		for col in 0 ..< dw {
			dx := x + col
			if dx < 0 || dx >= b.w { continue }
			si := ((sy + row) * src_w + sx + col) * 4
			if si < 0 || si + 4 > len(src) { continue }
			s := src[si:][:4]
			d := b.pix[(dy * b.w + dx) * 4:][:4]
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
	bitmap_touch(b, x, y, x + dw, y + dh)
}

// A copy of the whole bitmap (a pattern or drawImage source kept apart from the canvas it came from).
bitmap_clone :: proc(b: ^Bitmap, max_bytes := max(int), allocator := context.allocator) -> (r: Bitmap, ok: bool) {
	r, ok = bitmap_create(b.w, b.h, max_bytes, allocator)
	if ok && len(b.pix) > 0 { copy(r.pix, b.pix) }
	return
}

clear_rect_pixels :: proc "contextless" (b: ^Bitmap, ax0, ay0, ax1, ay1: int) {
	x0, y0, x1, y1 := max(ax0, 0), max(ay0, 0), min(ax1, b.w), min(ay1, b.h)
	if x0 >= x1 || y0 >= y1 { return }
	for y in y0 ..< y1 {
		row := b.pix[(y * b.w + x0) * 4:(y * b.w + x1) * 4]
		for i in 0 ..< len(row) { row[i] = 0 }
	}
	bitmap_touch(b, x0, y0, x1, y1)
}
