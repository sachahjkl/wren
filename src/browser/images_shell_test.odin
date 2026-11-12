package browser

import "core:testing"
import "wb:canvas2d"

// The conversion of a canvas to straight alpha for its texture: the table's reciprocals give the bytes the divisions give,
// for every value of a channel under every alpha, and the edges outside the bitmap are transparent black.
@(test)
unpremultiply_fast_is_exact :: proc(t: ^testing.T) {
	test_app(t)
	// one row per alpha, one pixel per channel value (a premultiplied channel may exceed alpha after rounding: kept too)
	W, H :: 256, 256
	pix := make([]u8, W * H * 4)
	defer delete(pix)
	for a in 0 ..< H {
		for c in 0 ..< W {
			p := pix[(a * W + c) * 4:][:4]
			p[0], p[1], p[2], p[3] = u8(c), u8(255 - c), u8(c / 2), u8(a)
		}
	}
	bmp := canvas2d.Bitmap{w = W, h = H, pix = pix}
	slow := make([]u8, W * H * 4)
	defer delete(slow)
	fast := make([]u8, W * H * 4)
	defer delete(fast)
	canvas2d.bitmap_read_straight(&bmp, 0, 0, W, H, slow)
	canvas2d.bitmap_read_straight_fast(&bmp, 0, 0, W, H, fast)
	differ := 0
	for i in 0 ..< len(slow) { if slow[i] != fast[i] { differ += 1 } }
	testing.expect_value(t, differ, 0)

	// a block past the bitmap's edges
	BW, BH :: 8, 6
	slow2: [BW * BH * 4]u8
	fast2: [BW * BH * 4]u8
	for &b in fast2 { b = 0xAA }   // (what is outside must be written, not left)
	canvas2d.bitmap_read_straight(&bmp, W - 4, H - 3, BW, BH, slow2[:])
	canvas2d.bitmap_read_straight_fast(&bmp, W - 4, H - 3, BW, BH, fast2[:])
	testing.expect(t, slow2 == fast2, "the same bytes past the edges")
	canvas2d.bitmap_read_straight(&bmp, -3, -2, BW, BH, slow2[:])
	canvas2d.bitmap_read_straight_fast(&bmp, -3, -2, BW, BH, fast2[:])
	testing.expect(t, slow2 == fast2, "the same bytes before the edges")

	// an opaque bitmap is copied
	opaque := canvas2d.Bitmap{w = W, h = H, pix = pix, all_opaque = true}
	canvas2d.bitmap_read_straight(&opaque, 1, 1, BW, BH, slow2[:])
	canvas2d.bitmap_read_straight_fast(&opaque, 1, 1, BW, BH, fast2[:])
	testing.expect(t, slow2 == fast2, "an opaque bitmap: the same copy")
}
