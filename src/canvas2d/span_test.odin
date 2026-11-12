package canvas2d

import "core:math"
import "core:testing"

// The vector routines of span.odin and the row-wise blur against the per-pixel code they replace: the same bytes (or,
// for the fixed-point bilinear rows, within one unit), on widths 1 to 33 (every tail length) and at every byte offset.

@(private = "file")
Rng :: struct { s: u64 }

@(private = "file")
next :: proc(r: ^Rng) -> u32 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return u32(r.s >> 16)
}

// A premultiplied pixel: alpha 0, 255 or anything, the color mostly at or below it (and sometimes above, as a bad
// decoder leaves it).
@(private = "file")
random_px :: proc(r: ^Rng) -> [4]u8 {
	a: u32
	switch next(r) % 4 {
	case 0: a = 0
	case 1: a = 255
	case: a = next(r) % 256
	}
	limit := next(r) % 8 == 0 ? 256 : a + 1
	return {u8(next(r) % limit), u8(next(r) % limit), u8(next(r) % limit), u8(a)}
}

@(private = "file")
random_coverage :: proc(r: ^Rng) -> f32 {
	switch next(r) % 9 {
	case 0: return 0
	case 1: return 1
	case 2: return FULL_COVERAGE
	case 3: return FULL_COVERAGE - 0.0001
	case 4: return 0.5
	case 5: return 1.0 / 255
	case 6: return math.nan_f32()
	}
	return f32(next(r) % 10001) / 10000
}

@(test)
over_spans_match_the_scalar_blend :: proc(t: ^testing.T) {
	r := Rng{0x9E3779B97F4A7C15}
	for n in 1 ..= 33 {
		for off in 0 ..< 4 {
			for round in 0 ..< 8 {
				d1 := make([]u8, n * 4 + off)
				defer delete(d1)
				d2 := make([]u8, n * 4 + off)
				defer delete(d2)
				src := make([]u8, n * 4 + off)
				defer delete(src)
				a := make([]f32, n)
				defer delete(a)
				for i in 0 ..< n {
					p, q := random_px(&r), random_px(&r)
					// runs of opaque, fully covered pixels, so the copies and stores are taken too
					if round % 2 == 0 && i % 9 < 5 { p[3] = 255; a[i] = 1 } else { a[i] = random_coverage(&r) }
					for k in 0 ..< 4 { src[off + i * 4 + k], d1[off + i * 4 + k] = p[k], q[k] }
				}
				copy(d2, d1)
				over_span(d1[off:], src[off:], a)
				over_span_scalar(d2[off:], src[off:], a)
				testing.expectf(t, string(d1) == string(d2), "over_span: width %d, offset %d, round %d", n, off, round)

				solid := random_px(&r)
				if round % 2 == 0 { solid[3] = 255 }
				s := [4]u32{u32(solid[0]), u32(solid[1]), u32(solid[2]), u32(solid[3])}
				copy(d1, d2)
				over_span_solid(d1[off:], s, a)
				over_span_solid_scalar(d2[off:], s, a)
				testing.expectf(t, string(d1) == string(d2), "over_span_solid: width %d, offset %d, round %d", n, off, round)
			}
		}
	}
}

@(test)
premultiply_row_matches_the_scalar_rounding :: proc(t: ^testing.T) {
	// every color with every alpha
	N :: 256 * 256
	src := make([]u8, N * 4)
	defer delete(src)
	for k in 0 ..< N {
		c, a := u8(k & 255), u8(k >> 8)
		src[k * 4], src[k * 4 + 1], src[k * 4 + 2], src[k * 4 + 3] = c, 255 - c, c ~ 0x5A, a
	}
	d1 := make([]u8, N * 4)
	defer delete(d1)
	d2 := make([]u8, N * 4)
	defer delete(d2)
	premultiply_row(d1, src, N)
	premultiply_row_scalar(d2, src, N)
	testing.expect(t, string(d1) == string(d2), "all colors and alphas")
	// every tail length, at every byte offset of both rows
	for n in 1 ..= 33 {
		for off in 0 ..< 4 {
			s := src[N * 2 + off:][:n * 4]
			premultiply_row(d1[off:], s, n)
			premultiply_row_scalar(d2[off:], s, n)
			testing.expectf(t, string(d1[off:][:n * 4]) == string(d2[off:][:n * 4]), "width %d, offset %d", n, off)
		}
	}
}

@(test)
put_image_data_clips_rows_as_before :: proc(t: ^testing.T) {
	b, _ := bitmap_create(5, 4)
	defer bitmap_destroy(&b)
	data := make([]u8, 3 * 3 * 4)
	defer delete(data)
	for &v, i in data { v = u8(i * 37 + 11) }
	// a block hanging over the left and top edges, and a source rectangle that runs past the data's end
	bitmap_write_straight(&b, data, 3, 0, 0, 3, 3, -1, -1)
	bitmap_write_straight(&b, data, 3, 1, 2, 3, 3, 3, 2)
	want, _ := bitmap_create(5, 4)
	defer bitmap_destroy(&want)
	put :: proc(b: ^Bitmap, src: []u8, src_w, sx, sy, dw, dh, x, y: int) {
		for row in 0 ..< dh {
			for col in 0 ..< dw {
				dx, dy := x + col, y + row
				si := ((sy + row) * src_w + sx + col) * 4
				if dx < 0 || dx >= b.w || dy < 0 || dy >= b.h || si < 0 || si + 4 > len(src) { continue }
				premultiply_row_scalar(b.pix[(dy * b.w + dx) * 4:][:4], src[si:][:4], 1)
			}
		}
	}
	put(&want, data, 3, 0, 0, 3, 3, -1, -1)
	put(&want, data, 3, 1, 2, 3, 3, 3, 2)
	testing.expect(t, string(b.pix) == string(want.pix), "the same pixels written")
}

// The blur as it was: each column copied out, blurred as a line, copied back.
@(private = "file")
blur_by_columns :: proc(plane: []f32, w, h: int, sigma: f64) {
	tmp := make([]f32, max(w, h))
	defer delete(tmp)
	line := make([]f32, max(w, h))
	defer delete(line)
	for r in boxes_for_gauss(sigma) {
		for y in 0 ..< h { box_blur_line(plane[y * w:][:w], tmp[:w], r) }
		for x in 0 ..< w {
			for y in 0 ..< h { line[y] = plane[y * w + x] }
			box_blur_line(line[:h], tmp[:h], r)
			for y in 0 ..< h { plane[y * w + x] = line[y] }
		}
	}
}

@(test)
blur_by_rows_matches_the_blur_by_columns :: proc(t: ^testing.T) {
	r := Rng{12345}
	sizes := [?][2]int{{1, 1}, {1, 9}, {9, 1}, {5, 3}, {17, 33}, {33, 17}, {40, 7}}
	sigmas := [?]f64{0.3, 1, 2.5, 7.3, 30}
	for sz in sizes {
		for sigma in sigmas {
			w, h := sz[0], sz[1]
			a := make([]f32, w * h)
			defer delete(a)
			b := make([]f32, w * h)
			defer delete(b)
			for i in 0 ..< w * h { a[i] = next(&r) % 3 == 0 ? 0 : f32(next(&r) % 1000) / 999 }
			copy(b, a)
			gaussian_blur(a, w, h, sigma)
			blur_by_columns(b, w, h, sigma)
			same := true
			for i in 0 ..< w * h { if a[i] != b[i] { same = false; break } }
			testing.expectf(t, same, "%d x %d, sigma %v", w, h, sigma)
		}
	}
}

@(test)
image_rows_match_the_sampled_pixels :: proc(t: ^testing.T) {
	r := Rng{777}
	img, _ := bitmap_create(7, 5)
	defer bitmap_destroy(&img)
	for i in 0 ..< 7 * 5 {
		p := random_px(&r)
		p[0], p[1], p[2] = min(p[0], p[3]), min(p[1], p[3]), min(p[2], p[3])
		copy(img.pix[i * 4:][:4], p[:])
	}
	buf: [dynamic]u8
	defer delete(buf)
	a := make([]f32, 40)
	defer delete(a)
	for &v in a { v = 1 }
	Case :: struct { inv: Matrix, exact: bool }
	cases := [?]Case{
		{Matrix{1, 0, 0, 1, -3, 2}, true},           // drawn at its size, moved by whole pixels
		{Matrix{1, 0, 0, 1, 2, -1}, true},
		{Matrix{0.37, 0, 0, 0.41, 0.2, -0.3}, false}, // enlarged
		{Matrix{1.7, 0, 0, 1.3, -0.6, 0.1}, false},   // shrunk
		{Matrix{0.8, 0.6, -0.6, 0.8, 1.5, -2.25}, false},   // turned
	}
	for smooth in ([2]bool{true, false}) {
		for cs in cases {
			if !smooth && !cs.exact { continue }   // (nearest sampling of other transforms goes per pixel)
			p := Paint{kind = .Image, inv = cs.inv}
			p.img = Image_Source{bmp = &img, x0 = 1, y0 = 0, x1 = 7, y1 = 4, wrap_x = .Clamp, wrap_y = .Clamp, smooth = smooth}
			for y in -3 ..< 9 {
				for n in ([3]int{1, 5, 33}) {
					x := -4 + y % 3
					row := paint_row(&p, x, y, a[:n], &buf)
					for i in 0 ..< n {
						f := paint_at(&p, x + i, y)
						want := [4]u8{u8(f.r * 255 + 0.5), u8(f.g * 255 + 0.5), u8(f.b * 255 + 0.5), u8(f.a * 255 + 0.5)}
						for k in 0 ..< 4 {
							diff := abs(int(row[i * 4 + k]) - int(want[k]))
							if diff > (cs.exact ? 0 : 1) {
								testing.expectf(t, false, "matrix %v, smooth %v, pixel (%d, %d) channel %d: %d, sampled %d", cs.inv, smooth, x + i, y, k, row[i * 4 + k], want[k])
								return
							}
						}
					}
				}
			}
		}
	}
}
