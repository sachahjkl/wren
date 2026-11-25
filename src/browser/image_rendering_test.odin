package browser

import "core:testing"
import config "toolkit:config"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

@(private = "file")
IR_SIZE :: [2]int{256, 128}

@(private = "file")
Ir_Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	face:  font.Font_Id,
	dc:    draw.Context,
	doc:   ^dom.Document,
	eng:   ^style.Engine,
	st:          ^style.Styled,
	l:           Layout,
	prefs:       config.Prefs,
	checker_tex: render.Texture,
	down_tex:    render.Texture,
	logo_tex:    render.Texture,
}

@(private = "file")
ir_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font((^Ir_Fx)(user).face) }
@(private = "file")
ir_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return font.text_width(&(^Ir_Fx)(user).fonts, font.Font_Id(f), size, text) }
@(private = "file")
ir_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
ir_open :: proc(f: ^Ir_Fx, src: string) -> bool {
	f.prefs = config.prefs_make()
	register_all_prefs(&f.prefs)
	s := render_settings_from_prefs(&f.prefs)
	if !render.init_offscreen(&f.r, IR_SIZE, warp = true, space = s.space) { return false }
	render.set_text_rendering(&f.r, s.text)
	font.init(&f.fonts)
	ok: bool
	f.face, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	the_app.page_render.settings = lay.settings_from_prefs(&f.prefs)
	the_app.effects_settings = effects_settings_from_prefs(&f.prefs)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	lay.run(&f.l, lay.Input{doc = f.doc, styled = f.st, settings = &the_app.page_render.settings,
		text = lay.Text_Api{user = f, font = ir_font, width = ir_width, metrics = ir_metrics},
		viewport = {f32(IR_SIZE.x), f32(IR_SIZE.y)}, scale = 1, band_h = 256})
	return ok
}

@(private = "file")
ir_close :: proc(f: ^Ir_Fx) {
	layout_destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
	font.destroy(&f.fonts)
	config.prefs_destroy(&f.prefs)
}

@(private = "file")
ir_paint :: proc(f: ^Ir_Fx, extra: proc(f: ^Ir_Fx)) -> []u8 {
	size := draw.Vec2{f32(IR_SIZE.x), f32(IR_SIZE.y)}
	draw.begin_frame(&f.dc, size)
	render.frame_begin(&f.r, {1, 1, 1, 1})
	paint(&f.l, &f.dc, f.doc, {0, 0}, size, 0, {{0, 0}, size})
	if extra != nil { extra(f) }
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
ir_px :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * IR_SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

@(private = "file")
ir_near :: proc(p: [4]int, r, g, b, tol: int) -> bool { return abs(p[0] - r) <= tol && abs(p[1] - g) <= tol && abs(p[2] - b) <= tol }

@(test)
image_rendering_filter_mapping_and_hash :: proc(t: ^testing.T) {
	testing.expect_value(t, image_filter_of(nil), draw.Image_Filter.Smooth)

	inh: style.Inherited_Group
	bg: style.Background_Group
	dec: style.Decor_Group
	rare: style.Rare_Group
	cs := style.Computed{inherited_group = &inh, background_group = &bg, decor_group = &dec, rare_group = &rare}

	testing.expect_value(t, image_filter_of(&cs), draw.Image_Filter.Smooth)
	h_auto := raster_hash(&cs, nil)

	inh.image_rendering = .Smooth
	testing.expect_value(t, image_filter_of(&cs), draw.Image_Filter.Smooth)
	inh.image_rendering = .High_Quality
	testing.expect_value(t, image_filter_of(&cs), draw.Image_Filter.Smooth)

	inh.image_rendering = .Pixelated
	testing.expect_value(t, image_filter_of(&cs), draw.Image_Filter.Pixelated)
	h_pix := raster_hash(&cs, nil)
	testing.expect(t, h_pix != h_auto, "raster_hash changes when image-rendering changes to pixelated")

	inh.image_rendering = .Crisp_Edges
	testing.expect_value(t, image_filter_of(&cs), draw.Image_Filter.Nearest)
	h_crisp := raster_hash(&cs, nil)
	testing.expect(t, h_crisp != h_pix, "raster_hash changes when image-rendering changes to crisp-edges")
}

@(private = "file")
IMAGE_RENDERING_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #fff }
.bar-home img { display: block; image-rendering: pixelated; }
#wrap { image-rendering: pixelated; }
#crisp { image-rendering: crisp-edges; }
#smooth { image-rendering: auto; }
</style></head><body>
<a class="bar-home"><picture><img id="logo" width="24" height="24"></picture></a>
<div id="wrap"><img id="inh" width="24" height="24"></div>
<img id="crisp" width="24" height="24">
<img id="smooth" width="24" height="24">
</body></html>`

// End-to-end CSS image-rendering -> style inheritance -> image_filter_of -> draw.set_image_filter -> GPU pixels,
// including a 24x24 pixel-art logo upscaled to 36x36 (1.5x DPI) and 48x48 (2x DPI) like modus.systems/docs navbar.
@(test)
image_rendering_pixelated_end_to_end :: proc(t: ^testing.T) {
	test_app(t)
	page_render_test_lock()
	defer page_render_test_unlock()

	f := new(Ir_Fx)
	defer free(f)
	if !ir_open(f, IMAGE_RENDERING_PAGE) { testing.fail_now(t, "no offscreen renderer or font") }
	defer ir_close(f)

	cs_logo := style.style_of(f.st, dom.find_by_id(f.doc, "logo"))
	cs_inh := style.style_of(f.st, dom.find_by_id(f.doc, "inh"))
	cs_crisp := style.style_of(f.st, dom.find_by_id(f.doc, "crisp"))
	cs_smooth := style.style_of(f.st, dom.find_by_id(f.doc, "smooth"))
	testing.expect_value(t, image_filter_of(cs_logo), draw.Image_Filter.Pixelated)
	testing.expect_value(t, image_filter_of(cs_inh), draw.Image_Filter.Pixelated)
	testing.expect_value(t, image_filter_of(cs_crisp), draw.Image_Filter.Nearest)
	testing.expect_value(t, image_filter_of(cs_smooth), draw.Image_Filter.Smooth)

	checker := [2 * 2 * 4]u8{
		255, 0, 0, 255,   0, 0, 255, 255,
		0, 0, 255, 255,   255, 0, 0, 255,
	}
	f.checker_tex = render.create_texture_rgba(&f.r, 2, 2, mips = false)
	defer render.destroy_texture(&f.r, f.checker_tex)
	render.update_texture_rgba(&f.r, f.checker_tex, 0, 0, 2, 2, checker[:])

	down_src: [4 * 4 * 4]u8
	for y in 0 ..< 4 {
		for x in 0 ..< 4 {
			o := (y * 4 + x) * 4
			if (x + y) & 1 == 0 {
				down_src[o], down_src[o + 1], down_src[o + 2], down_src[o + 3] = 255, 0, 0, 255
			} else {
				down_src[o], down_src[o + 1], down_src[o + 2], down_src[o + 3] = 0, 0, 255, 255
			}
		}
	}
	f.down_tex = render.create_texture_rgba(&f.r, 4, 4, mips = true)
	defer render.destroy_texture(&f.r, f.down_tex)
	render.update_texture_rgba(&f.r, f.down_tex, 0, 0, 4, 4, down_src[:])

	// 24x24 alternating 1-px vertical red/blue stripes (like a 24x24 pixel-art navbar logo)
	logo_src: [24 * 24 * 4]u8
	for y in 0 ..< 24 {
		for x in 0 ..< 24 {
			o := (y * 24 + x) * 4
			if x & 1 == 0 {
				logo_src[o], logo_src[o + 1], logo_src[o + 2], logo_src[o + 3] = 255, 0, 0, 255
			} else {
				logo_src[o], logo_src[o + 1], logo_src[o + 2], logo_src[o + 3] = 0, 0, 255, 255
			}
		}
	}
	f.logo_tex = render.create_texture_rgba(&f.r, 24, 24, mips = false)
	defer render.destroy_texture(&f.r, f.logo_tex)
	render.update_texture_rgba(&f.r, f.logo_tex, 0, 0, 24, 24, logo_src[:])

	img := ir_paint(f, proc(f: ^Ir_Fx) {
		cs_logo := style.style_of(f.st, dom.find_by_id(f.doc, "logo"))
		cs_inh := style.style_of(f.st, dom.find_by_id(f.doc, "inh"))
		cs_crisp := style.style_of(f.st, dom.find_by_id(f.doc, "crisp"))
		cs_smooth := style.style_of(f.st, dom.find_by_id(f.doc, "smooth"))

		prev := draw.set_image_filter(&f.dc, image_filter_of(cs_logo))
		draw.image_corners(&f.dc, f.checker_tex, {{0, 0}, {40, 40}}, {}, draw.WHITE, {})
		draw.image_corners(&f.dc, f.down_tex, {{0, 50}, {2, 52}}, {}, draw.WHITE, {})
		// 24x24 logo at 1.5x (36x36) and 2x (48x48) DPI
		draw.image_corners(&f.dc, f.logo_tex, {{10, 60}, {46, 96}}, {}, draw.WHITE, {})
		draw.image_corners(&f.dc, f.logo_tex, {{60, 60}, {108, 108}}, {}, draw.WHITE, {})
		draw.set_image_filter(&f.dc, prev)

		prev = draw.set_image_filter(&f.dc, image_filter_of(cs_inh))
		draw.image_tiled(&f.dc, f.checker_tex, {{50, 0}, {90, 40}}, {{50, 0}, {70, 20}}, draw.WHITE, {})
		draw.set_image_filter(&f.dc, prev)

		prev = draw.set_image_filter(&f.dc, image_filter_of(cs_crisp))
		draw.image_corners(&f.dc, f.checker_tex, {{100, 0}, {140, 40}}, {}, draw.WHITE, {})
		draw.image_corners(&f.dc, f.down_tex, {{100, 50}, {102, 52}}, {}, draw.WHITE, {})
		draw.set_image_filter(&f.dc, prev)

		prev = draw.set_image_filter(&f.dc, image_filter_of(cs_smooth))
		draw.image_corners(&f.dc, f.checker_tex, {{150, 0}, {190, 40}}, {}, draw.WHITE, {})
		draw.set_image_filter(&f.dc, prev)
	})

	// pixelated upscale: razor-sharp red/blue seam at x=19 vs x=20
	testing.expectf(t, ir_near(ir_px(img, 19, 10), 255, 0, 0, 1), "pixelated logo left of seam: %v", ir_px(img, 19, 10))
	testing.expectf(t, ir_near(ir_px(img, 20, 10), 0, 0, 255, 1), "pixelated logo right of seam: %v", ir_px(img, 20, 10))
	// pixelated downscale: falls back to smooth mip blend
	pd := ir_px(img, 0, 50)
	testing.expectf(t, pd[0] >= 80 && pd[2] >= 80, "pixelated downscale blends smoothly: %v", pd)

	// 24x24 pixelated logo upscaled to 36x36 (1.5x) and 48x48 (2x): every pixel stays pure red or pure blue (no purple blur)
	for x in 10 ..< 46 {
		c := ir_px(img, x, 75)
		pure := ir_near(c, 255, 0, 0, 1) || ir_near(c, 0, 0, 255, 1)
		testing.expectf(t, pure, "24x24 logo at 1.5x DPI x=%d must be unblended: %v", x, c)
	}
	for x in 60 ..< 108 {
		c := ir_px(img, x, 75)
		want_red := ((x - 60) / 2) & 1 == 0
		if want_red {
			testing.expectf(t, ir_near(c, 255, 0, 0, 1), "24x24 logo at 2x DPI x=%d want red: %v", x, c)
		} else {
			testing.expectf(t, ir_near(c, 0, 0, 255, 1), "24x24 logo at 2x DPI x=%d want blue: %v", x, c)
		}
	}

	// inherited pixelated tiled background: sharp across tile seam (x=69 blue -> x=70 red)
	testing.expectf(t, ir_near(ir_px(img, 59, 5), 255, 0, 0, 1), "tiled pixelated tile 0 left: %v", ir_px(img, 59, 5))
	testing.expectf(t, ir_near(ir_px(img, 60, 5), 0, 0, 255, 1), "tiled pixelated tile 0 right: %v", ir_px(img, 60, 5))
	testing.expectf(t, ir_near(ir_px(img, 69, 5), 0, 0, 255, 1), "tiled pixelated seam left: %v", ir_px(img, 69, 5))
	testing.expectf(t, ir_near(ir_px(img, 70, 5), 255, 0, 0, 1), "tiled pixelated seam right: %v", ir_px(img, 70, 5))

	// crisp-edges: sharp both upscaled and downscaled
	testing.expectf(t, ir_near(ir_px(img, 119, 10), 255, 0, 0, 1), "crisp-edges left of seam: %v", ir_px(img, 119, 10))
	testing.expectf(t, ir_near(ir_px(img, 120, 10), 0, 0, 255, 1), "crisp-edges right of seam: %v", ir_px(img, 120, 10))
	cd := ir_px(img, 100, 50)
	testing.expectf(t, (cd[0] >= 250 && cd[2] <= 5) || (cd[2] >= 250 && cd[0] <= 5), "crisp-edges downscale stays nearest: %v", cd)

	// auto (smooth): blends at seam (x=169, 170)
	sm := ir_px(img, 169, 10)
	testing.expectf(t, sm[0] > 30 && sm[2] > 30, "auto upscale blends at seam: %v", sm)
}
