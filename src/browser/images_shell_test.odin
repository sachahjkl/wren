package browser

import "core:testing"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
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
		create = proc(u: rawptr, w, h: int, mips: bool) -> Image_Texture {
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

// Regression test: software 2D canvas uploaded through renderer_texture_api must preserve exact sRGB colors
// (no double sRGB encoding from linear data textures) in both sRGB and linear blend spaces, and with pixelated filtering.
@(test)
canvas_srgb_colors_match_source_without_double_encoding :: proc(t: ^testing.T) {
	app := test_app(t)
	page_render_test_lock()
	defer page_render_test_unlock()

	SZ :: [2]int{128, 64}
	if !render.init_offscreen(&app.r, SZ, warp = true, space = .Srgb) {
		testing.fail_now(t, "no offscreen renderer")
	}
	defer render.destroy(&app.r)

	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	dc: draw.Context
	draw.init(&dc, &app.r, &fonts)
	defer draw.destroy(&dc)

	clear_textures :: proc() {
		for _, st in the_app.images_shell.textures {
			if the_app.images_shell.api.destroy != nil { the_app.images_shell.api.destroy(the_app.images_shell.api.user, st.tex) }
			free(st)
		}
		clear(&the_app.images_shell.textures)
		the_app.images_shell.bytes = 0
	}

	saved_api := the_app.images_shell.api
	saved_textures := the_app.images_shell.textures
	saved_bytes := the_app.images_shell.bytes
	saved_scratch := the_app.images_shell.canvas_scratch
	the_app.images_shell.textures = make(map[u64]^Shell_Texture)
	the_app.images_shell.bytes = 0
	the_app.images_shell.canvas_scratch = nil
	the_app.images_shell.api = renderer_texture_api(app)
	defer {
		clear_textures()
		delete(the_app.images_shell.textures)
		delete(the_app.images_shell.canvas_scratch)
		the_app.images_shell.textures = saved_textures
		the_app.images_shell.bytes = saved_bytes
		the_app.images_shell.canvas_scratch = saved_scratch
		the_app.images_shell.api = saved_api
	}

	// Build a 32x32 2D canvas with the modus.systems heron logo colors + a translucent quadrant.
	bmp, ok := canvas2d.bitmap_create(32, 32)
	testing.expect(t, ok, "bitmap created")
	defer canvas2d.bitmap_destroy(&bmp)
	ctx: canvas2d.Context
	canvas2d.context_init(&ctx, &bmp, canvas2d.DEFAULT_OPTIONS)
	defer canvas2d.context_destroy(&ctx)

	eye_src   := [4]u8{11, 16, 24, 255}
	body_src  := [4]u8{71, 116, 173, 255}
	water_src := [4]u8{55, 150, 139, 255}
	half_src  := [4]u8{71, 116, 173, 128}

	fill_quad :: proc(b: ^canvas2d.Bitmap, x0, y0, x1, y1: int, rgba: [4]u8) {
		w, h := x1 - x0, y1 - y0
		row := make([]u8, w * h * 4, context.temp_allocator)
		for i in 0 ..< w * h {
			row[i * 4 + 0] = rgba[0]
			row[i * 4 + 1] = rgba[1]
			row[i * 4 + 2] = rgba[2]
			row[i * 4 + 3] = rgba[3]
		}
		canvas2d.bitmap_write_straight(b, row, w, 0, 0, w, h, x0, y0)
	}
	fill_quad(&bmp, 0, 0, 16, 16, eye_src)
	fill_quad(&bmp, 16, 0, 32, 16, body_src)
	fill_quad(&bmp, 0, 16, 16, 32, water_src)
	fill_quad(&bmp, 16, 16, 32, 32, half_src)

	v := page.Canvas_View{id = 999_002, bmp = &bmp, ok = true}

	px_at :: proc(img: []u8, x, y: int) -> [4]int {
		o := (y * SZ.x + x) * 4
		return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
	}
	near_rgb :: proc(p: [4]int, want: [4]u8, tol: int) -> bool {
		return abs(p[0] - int(want[0])) <= tol && abs(p[1] - int(want[1])) <= tol && abs(p[2] - int(want[2])) <= tol
	}

	// 1) Default sRGB blend space: pixelated (modus.systems hero) + smooth must preserve exact sRGB colors.
	tex, tok := canvas_texture_for(v, false)
	testing.expect(t, tok && tex != 0, "canvas texture created in sRGB space")
	testing.expect_value(t, render.texture_space(&app.r, render.Texture(tex)), render.Blend_Space.Srgb)
	st := the_app.images_shell.textures[v.id]
	testing.expect(t, st != nil && !st.mips, "1:1 canvas still skips mipmaps on RGBA fallback")

	draw_and_read :: proc(r: ^render.Renderer, dc: ^draw.Context, api: ^Texture_Api, tex: Image_Texture) -> []u8 {
		size := draw.Vec2{f32(SZ.x), f32(SZ.y)}
		draw.begin_frame(dc, size)
		render.frame_begin(r, {1, 1, 1, 1})
		prev := draw.set_image_filter(dc, .Pixelated)
		api.draw(api.user, dc, tex, {{0, 0}, {32, 32}}, {}, draw.WHITE, {})
		draw.set_image_filter(dc, .Smooth)
		api.draw(api.user, dc, tex, {{40, 0}, {72, 32}}, {}, draw.WHITE, {})
		draw.set_image_filter(dc, prev)
		draw.end_frame(dc)
		render.frame_end(r)
		return render.read_pixels(r, context.temp_allocator)
	}

	img := draw_and_read(&app.r, &dc, &the_app.images_shell.api, tex)
	for ox in ([2]int{0, 40}) {
		testing.expectf(t, near_rgb(px_at(img, ox + 8, 8), eye_src, 1), "sRGB eye at ox=%d: got %v want %v", ox, px_at(img, ox + 8, 8), eye_src)
		testing.expectf(t, near_rgb(px_at(img, ox + 24, 8), body_src, 1), "sRGB body at ox=%d: got %v want %v", ox, px_at(img, ox + 24, 8), body_src)
		testing.expectf(t, near_rgb(px_at(img, ox + 8, 24), water_src, 1), "sRGB water at ox=%d: got %v want %v", ox, px_at(img, ox + 8, 24), water_src)
		// Half-alpha body blue over white in sRGB space: round((c*128 + 255*127)/255) = (163, 185, 214)
		want_half := [4]u8{163, 185, 214, 255}
		testing.expectf(t, near_rgb(px_at(img, ox + 24, 24), want_half, 2), "sRGB translucent at ox=%d: got %v want %v", ox, px_at(img, ox + 24, 24), want_half)
	}

	// 2) Linear blend space: recreating textures in linear space must still output exact opaque sRGB colors.
	render.set_blend_space(&app.r, .Linear)
	clear_textures()
	tex_lin, tok_lin := canvas_texture_for(v, false)
	testing.expect(t, tok_lin && tex_lin != 0, "canvas texture created in linear space")
	img_lin := draw_and_read(&app.r, &dc, &the_app.images_shell.api, tex_lin)
	testing.expectf(t, near_rgb(px_at(img_lin, 8, 8), eye_src, 2), "linear eye: got %v want %v", px_at(img_lin, 8, 8), eye_src)
	testing.expectf(t, near_rgb(px_at(img_lin, 24, 8), body_src, 2), "linear body: got %v want %v", px_at(img_lin, 24, 8), body_src)
	testing.expectf(t, near_rgb(px_at(img_lin, 8, 24), water_src, 2), "linear water: got %v want %v", px_at(img_lin, 8, 24), water_src)
}
