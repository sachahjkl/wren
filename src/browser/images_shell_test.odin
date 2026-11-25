package browser

import "core:testing"
import "toolkit:draw"
import "wb:canvas2d"
import "wb:page"

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

// Canvas texture upload uses direct premultiplied uploads with on-demand mipmaps and sparse dirty-tile sub-uploads.
@(test)
canvas_texture_uses_premultiplied_sparse_upload_and_on_demand_mips :: proc(t: ^testing.T) {
	test_app(t)
	page_render_test_lock()
	defer page_render_test_unlock()
	Mock :: struct {
		next_tex:    Image_Texture,
		creates:     int,
		last_mips:   bool,
		uploads:     int,
		upload_area: int,
		destroys:    int,
	}
	m: Mock
	saved_api := the_app.images_shell.api
	saved_textures := the_app.images_shell.textures
	saved_bytes := the_app.images_shell.bytes
	the_app.images_shell.textures = make(map[u64]^Shell_Texture)
	the_app.images_shell.bytes = 0
	defer {
		for _, st in the_app.images_shell.textures {
			if the_app.images_shell.api.destroy != nil { the_app.images_shell.api.destroy(the_app.images_shell.api.user, st.tex) }
			free(st)
		}
		delete(the_app.images_shell.textures)
		the_app.images_shell.textures = saved_textures
		the_app.images_shell.bytes = saved_bytes
		the_app.images_shell.api = saved_api
	}
	the_app.images_shell.api = Texture_Api{
		user = rawptr(&m),
		create = proc(u: rawptr, w, h: int) -> Image_Texture {
			mk := (^Mock)(u)
			mk.next_tex += 1
			return mk.next_tex
		},
		update = proc(u: rawptr, tex: Image_Texture, x, y, w, h: int, px: []u8, stride: int) {},
		destroy = proc(u: rawptr, tex: Image_Texture) { (^Mock)(u).destroys += 1 },
		draw = proc(u: rawptr, dc: ^draw.Context, tex: Image_Texture, dst, src: draw.Rect, tint: draw.Color, radii: [4]f32) {},
		create_premultiplied = proc(u: rawptr, w, h: int, mips: bool) -> Image_Texture {
			mk := (^Mock)(u)
			mk.creates += 1
			mk.last_mips = mips
			mk.next_tex += 1
			return mk.next_tex
		},
		update_premultiplied = proc(u: rawptr, tex: Image_Texture, x, y, w, h: int, px: []u8, stride: int) {
			mk := (^Mock)(u)
			mk.uploads += 1
			mk.upload_area += w * h
		},
	}

	bmp, ok := canvas2d.bitmap_create(512, 512)
	testing.expect(t, ok, "bitmap created")
	defer canvas2d.bitmap_destroy(&bmp)
	ctx: canvas2d.Context
	canvas2d.context_init(&ctx, &bmp, canvas2d.DEFAULT_OPTIONS)
	defer canvas2d.context_destroy(&ctx)

	v := page.Canvas_View{id = 999_001, bmp = &bmp, ok = true}

	// 1:1 draw creates a premultiplied texture without mipmaps and uploads initial frame.
	_, tok := canvas_texture_for(v, false)
	testing.expect(t, tok && m.creates == 1 && !m.last_mips, "1:1 canvas skips mipmaps")

	// Clear initial conservative nonzero state, then draw one small sprite and clear: upload must stay sparse.
	canvas2d.ctx_clear_rect(&ctx, 0, 0, 512, 512)
	_, _ = canvas_texture_for(v, false)

	m.uploads, m.upload_area = 0, 0
	canvas2d.style_set_color(&ctx.state.fill, {1, 1, 1, 1})
	canvas2d.ctx_fill_rect(&ctx, 16, 16, 12, 12)
	_, _ = canvas_texture_for(v, false)
	testing.expectf(t, m.uploads == 1 && m.upload_area <= 16 * 16, "single small draw uploads only its dirty rect: uploads=%d area=%d", m.uploads, m.upload_area)

	m.uploads, m.upload_area = 0, 0
	canvas2d.ctx_clear_rect(&ctx, 0, 0, 512, 512)
	canvas2d.ctx_fill_rect(&ctx, 400, 400, 12, 12)
	_, _ = canvas_texture_for(v, false)
	testing.expectf(t, m.uploads == 2 && m.upload_area <= 2 * canvas2d.TILE_SIZE * canvas2d.TILE_SIZE, "sparse clear+draw uploads only 2 tiles: uploads=%d area=%d", m.uploads, m.upload_area)

	// Shrinking below 0.75x upgrades once to mips=true; returning to 1:1 keeps mips=true without thrashing.
	_, _ = canvas_texture_for(v, true)
	testing.expect(t, m.creates == 2 && m.last_mips && m.destroys == 1, "downscaled canvas upgrades to mips=true")
	_, _ = canvas_texture_for(v, false)
	testing.expect(t, m.creates == 2 && m.last_mips, "returning to 1:1 keeps mips=true without recreating")
}
