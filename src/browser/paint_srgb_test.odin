package browser

import "core:math"
import "core:testing"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "wb:config"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

// The page painter on an offscreen renderer (WARP) in the default blend space (render.blend_space = srgb): what every
// browser shows for translucent colors, gradients, opacity, antialiased edges and translucent images.

@(private = "file")
Paint_Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	face:  font.Font_Id,
	dc:    draw.Context,
	doc:   ^dom.Document,
	eng:   ^style.Engine,
	st:    ^style.Styled,
	l:     Layout,
	prefs: config.Prefs,
}

PAINT_SIZE :: [2]int{256, 128}

@(private = "file")
pf_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font((^Paint_Fx)(user).face) }
@(private = "file")
pf_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return font.text_width(&(^Paint_Fx)(user).fonts, font.Font_Id(f), size, text) }
@(private = "file")
pf_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
pf_open :: proc(f: ^Paint_Fx, src: string) -> bool {
	f.prefs = config.prefs_make()
	register_all_prefs(&f.prefs)
	s := render_settings_from_prefs(&f.prefs)
	if !render.init_offscreen(&f.r, PAINT_SIZE, warp = true, space = s.space) { return false }
	render.set_text_rendering(&f.r, s.text)
	font.init(&f.fonts)
	ok: bool
	f.face, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	page_render.settings = lay.settings_from_prefs(&f.prefs)
	effects_settings = effects_settings_from_prefs(&f.prefs)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	lay.run(&f.l, lay.Input{doc = f.doc, styled = f.st, settings = &page_render.settings,
		text = lay.Text_Api{user = f, font = pf_font, width = pf_width, metrics = pf_metrics},
		viewport = {f32(PAINT_SIZE.x), f32(PAINT_SIZE.y)}, scale = 1, band_h = 256})
	return ok
}

@(private = "file")
pf_close :: proc(f: ^Paint_Fx) {
	layout_destroy(&f.l)   // with its retained pictures
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
	font.destroy(&f.fonts)
	config.prefs_destroy(&f.prefs)
}

@(private = "file")
pf_paint :: proc(f: ^Paint_Fx, extra: proc(f: ^Paint_Fx) = nil) -> []u8 {
	size := draw.Vec2{f32(PAINT_SIZE.x), f32(PAINT_SIZE.y)}
	draw.begin_frame(&f.dc, size)
	render.frame_begin(&f.r, {1, 1, 1, 1})
	paint(&f.l, &f.dc, f.doc, {0, 0}, size, 0, {{0, 0}, size})
	if extra != nil { extra(f) }
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
ppx :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * PAINT_SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

@(private = "file")
pnear :: proc(p: [4]int, r, g, b, tol: int) -> bool { return abs(p[0] - r) <= tol && abs(p[1] - g) <= tol && abs(p[2] - b) <= tol }

PAINT_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #fff }
div { position: absolute; top: 0; width: 40px; height: 40px }
#half { left: 0; background: rgba(0, 0, 0, .5) }
#grad { left: 50px; width: 100px; background: linear-gradient(to right, red, blue) }
#fade { left: 160px; width: 60px; background: linear-gradient(to right, red, transparent) }
#black { left: 0; top: 50px; background: #000 }
#op { left: 0; top: 0; background: #fff; opacity: .5 }
#group { left: 50px; top: 50px; background: #000 }
#g1, #g2 { left: 0; top: 0; background: #fff }
#g2 { left: 10px }
#og { left: 0; top: 0; width: 40px; opacity: .5 }
#circle { left: 100px; top: 50px; width: 60px; height: 60px; border-radius: 50%; background: #000 }
</style></head><body><div id="half"></div><div id="grad"></div><div id="fade"></div><div id="black"><div id="op"></div></div><div id="group"><div id="og"><div id="g1"></div><div id="g2"></div></div></div><div id="circle"></div></body></html>`

@(private = "file", thread_local) png_tex: render.Texture

@(test)
srgb_painting_matches_browsers :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	f := new(Paint_Fx)
	defer free(f)
	if !pf_open(f, PAINT_PAGE) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer pf_close(f)
	testing.expect(t, render.blend_space(&f.r) == .Srgb, "render.blend_space defaults to srgb")
	testing.expect(t, render.text_rendering(&f.r) == render.TEXT_RENDERING_SRGB, "text: Chromium's gamma 1.2 and contrast 1")

	// a translucent PNG pixel rgba(255, 0, 0, 128) drawn like images_shell draws decoded images
	png_tex = render.create_texture_rgba(&f.r, 2, 2)
	pix := [16]u8{255, 0, 0, 128, 255, 0, 0, 128, 255, 0, 0, 128, 255, 0, 0, 128}
	render.update_texture_rgba(&f.r, png_tex, 0, 0, 2, 2, pix[:])
	defer render.destroy_texture(&f.r, png_tex)
	img := pf_paint(f, proc(f: ^Paint_Fx) { draw.image(&f.dc, png_tex, {{230, 0}, {256, 40}}) })

	// rgba(0, 0, 0, .5) over white: 128 in every browser
	testing.expectf(t, pnear(ppx(img, 20, 20), 128, 128, 128, 1), "rgba(0,0,0,.5) on white: %v", ppx(img, 20, 20))
	// linear-gradient(red, blue): (128, 0, 128) in the middle (pixels 99 and 100 straddle it)
	l, r := ppx(img, 99, 20), ppx(img, 100, 20)
	mid := [4]int{(l[0] + r[0]) / 2, (l[1] + r[1]) / 2, (l[2] + r[2]) / 2, 255}
	testing.expectf(t, pnear(mid, 128, 0, 128, 2), "linear-gradient(red, blue) middle: %v %v", l, r)
	// red to transparent: premultiplied interpolation, half red over white in the middle (no grey band)
	fm := ppx(img, 190, 20)
	testing.expectf(t, fm[0] >= 254 && abs(fm[1] - 128) <= 3 && fm[1] == fm[2], "linear-gradient(red, transparent) middle: %v", fm)
	// opacity: .5 of white over black: 128; a group of two overlapping boxes too (one layer, no double blending)
	testing.expectf(t, pnear(ppx(img, 20, 70), 128, 128, 128, 1), "opacity .5 white over black: %v", ppx(img, 20, 70))
	testing.expectf(t, pnear(ppx(img, 70, 70), 128, 128, 128, 1) && pnear(ppx(img, 55, 70), 128, 128, 128, 1), "opacity group: %v %v", ppx(img, 55, 70), ppx(img, 70, 70))
	// antialiased circle: the ring of partly covered pixels takes the sRGB value of its coverage (128 at 50 %)
	ring := 0
	worst := 0
	for y in 50 ..< 110 {
		for x in 100 ..< 160 {
			d := math.sqrt(math.pow(f32(x) + 0.5 - 130, 2) + math.pow(f32(y) + 0.5 - 80, 2))
			cov := clamp(30.5 - d, 0, 1)
			if cov < 0.2 || cov > 0.8 { continue }
			ring += 1
			worst = max(worst, abs(ppx(img, x, y)[0] - int(math.round(255 * (1 - cov)))))
		}
	}
	testing.expectf(t, ring > 50 && worst <= 16, "circle edge: %d ring pixels, worst %d levels from the sRGB coverage", ring, worst)
	// the translucent PNG over white: (255, 127, 127) as in Chromium
	testing.expectf(t, pnear(ppx(img, 243, 20), 255, 127, 127, 1), "PNG rgba(255,0,0,128) on white: %v", ppx(img, 243, 20))

	// render.blend_space = linear: the physically linear result (188)
	testing.expect(t, config.set_from_string(&f.prefs, "render.blend_space", "linear", .User) == nil)
	s := render_settings_from_prefs(&f.prefs)
	testing.expect(t, s.space == .Linear)
	render.set_blend_space(&f.r, s.space)
	lin := pf_paint(f)
	testing.expectf(t, pnear(ppx(lin, 20, 20), 188, 188, 188, 1), "linear blending: %v", ppx(lin, 20, 20))
	// gradients still interpolate on sRGB values
	l, r = ppx(lin, 99, 20), ppx(lin, 100, 20)
	testing.expectf(t, abs((l[0] + r[0]) / 2 - 128) <= 2, "linear blending, gradient middle: %v %v", l, r)
}
