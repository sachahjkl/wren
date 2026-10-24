package browser

import "core:math"
import "core:strings"
import "core:testing"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "wb:config"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

////////////////////////////////
// The registry, the card's relief and the shader on a page (WARP).

@(test)
the_registry_is_well_formed :: proc(t: ^testing.T) {
	seen := make(map[string]bool, context.temp_allocator)
	for d in SHADERS {
		testing.expectf(t, d.name != "" && d.name not_in seen, "shader %q: empty or twice", d.name)
		seen[d.name] = true
		testing.expectf(t, len(d.args) <= style.MAX_SHADER_ARGS && len(d.defaults) <= len(d.args), "shader %q: arguments %v, defaults %v", d.name, d.args, d.defaults)
		testing.expectf(t, len(d.passes) > 0, "shader %q draws nothing", d.name)
		testing.expectf(t, shader_def(d.name) != nil, "shader %q is found by name", d.name)
	}
	testing.expect(t, shader_def("card-foil") != nil && shader_def("nope") == nil)
	testing.expect(t, shader_def("") == nil, "none is not a shader")
}

// The Direct3D 11 pixel shader embedded for each shader is the one of the sources it ships with (and of the toolkit's rect.wgsl and
// app.wgsl it is compiled with): odin run ext/gui_toolkit/tools/shaders -- app card_foil src/browser/shaders/card_foil.wgsl src/browser/shaders
@(test)
the_embedded_pixel_shader_matches_its_sources :: proc(t: ^testing.T) {
	for d in SHADERS {
		testing.expectf(t, strings.trim_space(d.hash) == render.app_module_hash(d.wgsl, context.temp_allocator), "shader %q: its compiled blob is stale", d.name)
		testing.expectf(t, len(d.dxbc) > 1000, "shader %q has no blob", d.name)
	}
}

@(test)
the_relief_of_the_card_is_a_normal_map_and_the_same_every_time :: proc(t: ^testing.T) {
	a := card_normal_map(context.allocator)
	defer delete(a)
	b := card_normal_map(context.allocator)
	defer delete(b)
	testing.expect_value(t, len(a), NORMAL_W * NORMAL_H * 4)
	testing.expect(t, string(a) == string(b), "no randomness: the same bytes at every build (and on any number of threads)")
	long, cut, deep, lo, hi := 0, 0, 0, 255, 0
	for i := 0; i < len(a); i += 4 {
		x, y := (f32(a[i]) - 128) / 127, (f32(a[i + 1]) - 128) / 127
		if x * x + y * y > 1.02 { long += 1 }
		if math.abs(x) > 0.05 || math.abs(y) > 0.05 { cut += 1 }
		if a[i + 3] > 40 { deep += 1 }
		lo, hi = min(lo, int(a[i + 2])), max(hi, int(a[i + 2]))
	}
	n := NORMAL_W * NORMAL_H
	testing.expectf(t, long == 0, "%d texels whose x and y are longer than a unit normal", long)
	testing.expectf(t, cut > n / 2, "the engraving tilts the surface (%d of %d texels)", cut, n)
	testing.expectf(t, deep > n / 200 && deep < n / 2, "the cavities are the lines of the engraving, not nothing and not everything (%d of %d)", deep, n)
	testing.expectf(t, lo == 0 && hi == 255, "the height uses its whole range (%d .. %d)", lo, hi)
	// the micro-lettering in the lip along the top edge: its rows are cut deeper than the lip beside it
	at :: proc(a: []u8, x, y: int) -> u8 { return a[(y * NORMAL_W + x) * 4 + 2] }
	cuts := 0
	for x in 42 ..< 42 + 24 * 12 { if at(a, x, 8 + 4) < at(a, x, 8 - 6) - 40 { cuts += 1 } }
	testing.expectf(t, cuts > 40, "micro-lettering cut into the lip (%d dots)", cuts)
}

@(test)
the_card_style_asks_for_the_shader_and_carries_no_picture :: proc(t: ^testing.T) {
	css := card_css()
	for want in ([]string{"-wren-shader: card-foil var(--sweep) var(--bx) var(--by) var(--live)", "@property --sweep", "@property --bx", "@keyframes sweep", "prefers-reduced-motion", ".lic.live .base"}) {
		testing.expectf(t, strings.contains(css, want), "the card's style lacks %q", want)
	}
	testing.expect(t, !strings.contains(css, "data:image") && !strings.contains(css, "mask-image") && len(css) < 12000, "no picture of the relief in the page: it is made natively")
}

////////////////////////////////
// A box with the property on a page, painted

@(private = "file")
Sh_Fx :: struct {
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

SH_SIZE :: [2]int{256, 160}

@(private = "file")
sh_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font((^Sh_Fx)(user).face) }
@(private = "file")
sh_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return font.text_width(&(^Sh_Fx)(user).fonts, font.Font_Id(f), size, text) }
@(private = "file")
sh_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
sh_open :: proc(f: ^Sh_Fx, src: string, internal: bool) -> bool {
	f.prefs = config.prefs_make()
	register_all_prefs(&f.prefs)
	s := render_settings_from_prefs(&f.prefs)
	if !render.init_offscreen(&f.r, SH_SIZE, warp = true, space = s.space) { return false }
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
	ss.internal_document = internal
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	lay.run(&f.l, lay.Input{doc = f.doc, styled = f.st, settings = &page_render.settings,
		text = lay.Text_Api{user = f, font = sh_font, width = sh_width, metrics = sh_metrics},
		viewport = {f32(SH_SIZE.x), f32(SH_SIZE.y)}, scale = 1, band_h = 256})
	return ok
}

@(private = "file")
sh_close :: proc(f: ^Sh_Fx) {
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
sh_paint :: proc(f: ^Sh_Fx) -> []u8 {
	size := draw.Vec2{f32(SH_SIZE.x), f32(SH_SIZE.y)}
	draw.begin_frame(&f.dc, size)
	render.frame_begin(&f.r, {1, 1, 1, 1})
	paint(&f.l, &f.dc, f.doc, {0, 0}, size, 0, {{0, 0}, size})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

// The sum of the pixel differences between two frames, and how many pixels differ by more than `tol`.
@(private = "file")
sh_diff :: proc(a, b: []u8, tol := 3) -> (pixels: int, worst: int) {
	for i := 0; i < len(a); i += 4 {
		d := max(abs(int(a[i]) - int(b[i])), abs(int(a[i + 1]) - int(b[i + 1])), abs(int(a[i + 2]) - int(b[i + 2])))
		worst = max(worst, d)
		if d > tol { pixels += 1 }
	}
	return
}

SH_PAGE :: `<!doctype html><html><head><style>
@property --s { syntax: '<number>'; inherits: true; initial-value: 0.5 }
html, body { margin: 0; background: #fff }
#c { position: absolute; left: 20px; top: 20px; width: 200px; height: 112px; background: #202028; border-radius: 14px; overflow: hidden; %s }
</style></head><body><div id="c"></div></body></html>`

@(private = "file")
sh_page :: proc(decl: string) -> string {
	s, _ := strings.replace(SH_PAGE, "%s", decl, 1, context.temp_allocator)
	return s
}

// Where the box is, in 0 .. 255 of a pixel's red.
@(private = "file")
sh_px :: proc(img: []u8, x, y: int) -> [3]int {
	o := (y * SH_SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2])}
}

@(test)
a_built_in_page_paints_the_shader_and_any_other_page_ignores_it :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	decl := "-wren-shader: card-foil var(--s) 0.5 0.5 0 1"

	plain := new(Sh_Fx)
	defer free(plain)
	if !sh_open(plain, sh_page(""), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(plain)
	base := sh_paint(plain)

	lit := new(Sh_Fx)
	defer free(lit)
	if !sh_open(lit, sh_page(decl), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(lit)
	img := sh_paint(lit)
	n, worst := sh_diff(base, img)
	testing.expectf(t, n > 2000 && worst > 20, "the shader lights the box: %d pixels changed (worst %d)", n, worst)
	// outside the box (and its rounded corner) nothing changed
	outside := 0
	for y in 0 ..< SH_SIZE.y {
		for x in 0 ..< SH_SIZE.x {
			if x >= 18 && x < 222 && y >= 18 && y < 134 { continue }
			o := (y * SH_SIZE.x + x) * 4
			if img[o] != base[o] || img[o + 1] != base[o + 1] || img[o + 2] != base[o + 2] { outside += 1 }
		}
	}
	testing.expect_value(t, outside, 0)
	corner := sh_px(img, 21, 21)
	testing.expectf(t, corner == sh_px(base, 21, 21) && corner == [3]int{255, 255, 255}, "the rounded corner (14px) is cut: %v", corner)

	// the same page in a document that is not one of the browser's: the declaration is invalid, the box is its plain background
	web := new(Sh_Fx)
	defer free(web)
	if !sh_open(web, sh_page(decl), false) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(web)
	imgw := sh_paint(web)
	nw, _ := sh_diff(base, imgw, 0)
	testing.expect_value(t, nw, 0)
	testing.expect(t, !style.has_shader(style.style_of(web.st, dom.find_by_id(web.doc, "c"))), "no shader in a web page's computed style")
}

@(test)
the_box_keeps_its_background_where_the_shader_cannot_be_had :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	f := new(Sh_Fx)
	defer free(f)
	if !sh_open(f, sh_page("-wren-shader: card-foil 0.5 0.5 0.5 0 1"), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(f)
	plain := new(Sh_Fx)
	defer free(plain)
	if !sh_open(plain, sh_page(""), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(plain)
	base := sh_paint(plain)
	// the renderer refused the module (as a stale blob would be): marked as failed for this renderer
	shader_states[0] = Shader_State{renderer = render.renderer_id(&f.r), device = f.r.device_generation, live = true, failed = true}
	defer shader_states[0] = {}
	img := sh_paint(f)
	n, _ := sh_diff(base, img, 0)
	testing.expect_value(t, n, 0)
	// an unknown shader name: nothing either
	g := new(Sh_Fx)
	defer free(g)
	if !sh_open(g, sh_page("-wren-shader: no-such-shader 1"), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(g)
	n2, _ := sh_diff(base, sh_paint(g), 0)
	testing.expect_value(t, n2, 0)
}

@(test)
the_shader_is_painted_with_and_without_the_compositor_and_follows_its_arguments :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	saved := compositor_settings.enabled
	defer compositor_settings.enabled = saved
	a := new(Sh_Fx)
	defer free(a)
	if !sh_open(a, sh_page("-wren-shader: card-foil 0.5 0.5 0.5 0 1"), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(a)
	compositor_settings.enabled = true
	composited := sh_paint(a)
	compositor_settings.enabled = false
	direct := sh_paint(a)
	n, worst := sh_diff(composited, direct, 1)
	testing.expectf(t, n == 0, "composited and direct drawing give the same pixels (%d differ, worst %d)", n, worst)
	// another argument (the sweeping light's place) is another picture: the shader reads its arguments from the computed style
	b := new(Sh_Fx)
	defer free(b)
	if !sh_open(b, sh_page("-wren-shader: card-foil 0.8 0.5 0.5 0 1"), true) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer sh_close(b)
	compositor_settings.enabled = true
	moved := sh_paint(b)
	n2, _ := sh_diff(composited, moved, 6)
	testing.expectf(t, n2 > 1500, "the light moved: %d pixels differ", n2)
}
