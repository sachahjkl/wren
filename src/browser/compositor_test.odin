package browser

import "core:fmt"
import "core:log"
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

// The compositor (retained pictures) against direct drawing, on an offscreen renderer (WARP): the same pixels for
// representative pages, scrolled, with moving transforms, changed paint values and partial layout changes; and what it
// records each time (nothing for a scroll or a transform, one chunk for a color).

@(private = "file")
Cx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	face:  font.Font_Id,
	dc:    draw.Context,
	doc:   ^dom.Document,
	eng:   ^style.Engine,
	st:    ^style.Styled,
	l:     Layout,
	prefs: config.Prefs,
	real:  bool,             // the browser's text stack (DirectWrite cascades, shaping, bidi) instead of a fake one
	m:     Measure,
	ss:    style.Settings,
}

COMP_SIZE :: [2]int{360, 300}

@(private = "file")
cx_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font((^Cx)(user).face) }
@(private = "file")
cx_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return font.text_width(&(^Cx)(user).fonts, font.Font_Id(f), size, text) }
@(private = "file")
cx_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
cx_layout :: proc(f: ^Cx) {
	api := lay.Text_Api{user = f, font = cx_font, width = cx_width, metrics = cx_metrics}
	if f.real { api = page_text_api(&page_render.fonts, &f.m, &f.ss) }
	lay.run(&f.l, lay.Input{doc = f.doc, styled = f.st, settings = &page_render.settings,
		text = api,
		viewport = {f32(COMP_SIZE.x), f32(COMP_SIZE.y)}, scale = 1, band_h = 256})
}

@(private = "file")
cx_open :: proc(f: ^Cx, src: string, real := false) -> bool {
	f.prefs = config.prefs_make()
	register_all_prefs(&f.prefs)
	s := render_settings_from_prefs(&f.prefs)
	if !render.init_offscreen(&f.r, COMP_SIZE, warp = true, space = s.space) { return false }
	render.set_text_rendering(&f.r, s.text)
	font.init(&f.fonts)
	ok: bool
	f.face, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if real {
		f.real = true
		ui, uok := font.load_system(&f.fonts, "Segoe UI")
		if !uok { return false }
		page_fonts_init(&page_render.fonts, &f.fonts, ui)
		f.ss = style.settings_default()
	}
	draw.init(&f.dc, &f.r, &f.fonts)
	page_render.settings = lay.settings_from_prefs(&f.prefs)
	effects_settings = effects_settings_from_prefs(&f.prefs)
	compositor_settings = compositor_settings_from_prefs(&f.prefs)
	compositor_settings.chunk_items = 8   // several chunks even on a small page
	compositor_settings.settle_ms = 0   // record right after each layout pass
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	cx_layout(f)
	return ok
}

@(private = "file")
cx_close :: proc(f: ^Cx) {
	layout_destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
	if f.real {
		page_fonts_destroy(&page_render.fonts)
		style.settings_destroy(&f.ss)
	}
	font.destroy(&f.fonts)
	config.prefs_destroy(&f.prefs)
	compositor_settings = {enabled = true, chunk_items = 512, max_chunks = 4096, settle_ms = 50, memory = 256 << 20}
}

@(private = "file")
cx_paint :: proc(f: ^Cx, composited: bool, scroll: f32 = 0) -> []u8 {
	compositor_settings.enabled = composited
	size := draw.Vec2{f32(COMP_SIZE.x), f32(COMP_SIZE.y)}
	draw.begin_frame(&f.dc, size)
	render.frame_begin(&f.r, {1, 1, 1, 1})
	paint(&f.l, &f.dc, f.doc, {0, 0}, size, scroll, {{0, 0}, size})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
cx_diff :: proc(a, b: []u8) -> (worst, count: int) {
	for i in 0 ..< len(a) {
		d := abs(int(a[i]) - int(b[i]))
		worst = max(worst, d)
		if d > 0 { count += 1 }
	}
	return
}

// Composited, then direct: the same pixels (`tol`: worst channel difference allowed, for content drawn under rotations,
// whose matrices are composed in another order).
@(private = "file")
cx_same :: proc(t: ^testing.T, f: ^Cx, what: string, scroll: f32 = 0, tol := 1, loc := #caller_location) -> (recorded: int) {
	a := cx_paint(f, true, scroll)
	recorded = composite_stats.recorded
	stats := composite_stats
	b := cx_paint(f, false, scroll)
	worst, count := cx_diff(a, b)
	log.infof("%s: %d of %d bytes differ, worst %d; %v", what, count, len(a), worst, stats)
	testing.expectf(t, worst <= tol, "%s: composited differs from direct drawing (%d bytes, worst %d; %v)", what, count, worst, stats, loc = loc)
	testing.expectf(t, stats.replayed > 0, "%s: something was replayed (%v)", what, stats, loc = loc)
	return
}

COMP_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #f4f6fb; font-size: 13px; color: #1d2433 }
.row { display: flex; gap: 8px; padding: 6px }
.card { width: 70px; height: 46px; border-radius: 9px; background: #4dabf7; border: 2px solid #1c7ed6; box-shadow: 0 3px 6px rgba(0,0,0,.3) }
.lin { background: linear-gradient(45deg, red, gold 40%, blue) }
.rad { background: radial-gradient(circle at 30% 40%, #fff, #e64980 60%, #5f3dc4) }
.con { background: conic-gradient(from 30deg, red, yellow, lime, aqua, blue, magenta, red) }
.rep { background: repeating-linear-gradient(90deg, #333 0 4px, #ddd 4px 9px) }
.inset { background: #fff; box-shadow: inset 2px 3px 6px 1px rgba(0,0,0,.5) }
.layers { background: linear-gradient(rgba(255,255,255,.6), transparent), radial-gradient(#ffd43b, #f08c00) }
.clip { width: 120px; height: 60px; overflow: hidden; border-radius: 16px; border: 3px solid #364fc7 }
.clip p { margin: 4px 8px }
.scroll { width: 140px; height: 70px; overflow: auto; border: 1px solid #888 }
.scroll div { height: 18px; margin: 2px; background: #d0bfff }
.ghost { opacity: .6; position: relative; width: 60px; height: 40px }
.ghost div { position: absolute; width: 36px; height: 30px; background: #e03131 }
.ghost div + div { left: 20px; top: 8px; background: #1971c2 }
ul { margin: 4px 24px } li { text-decoration: underline }
.out { outline: 2px dashed #e8590c; outline-offset: 2px; display: inline-block; padding: 2px }
.tall { height: 400px; background: linear-gradient(#fff, #c5f6fa) }
</style></head><body>
<div class="row"><div class="card"></div><div class="card lin"></div><div class="card rad"></div><div class="card con"></div></div>
<div class="row"><div class="card rep"></div><div class="card inset"></div><div class="card layers"></div><div class="ghost"><div></div><div></div></div></div>
<div class="row"><div class="clip"><p>Clipped text inside a rounded box that hides what overflows it.</p></div>
<div class="scroll" id="sc"><div>one</div><div>two</div><div>three</div><div>four</div><div>five</div><div>six</div></div></div>
<ul><li>first item</li><li>second item</li></ul><p>Plain <b>bold</b> <span class="out">outlined</span> text.</p>
<div class="tall"></div>
</body></html>`

// One test: the scenarios switch the compositor on and off (a global setting).
@(test)
compositor_matches_direct_drawing :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	composited_pages(t)
	transforms_move_slots(t)
	recording_follows_changes(t)
	multilingual_text(t)
	masks_clip_text_fieldset(t)
}

MASK_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #fff; font-size: 13px; color: #111 }
.row { display: flex; gap: 8px; padding: 6px }
.b { width: 60px; height: 40px; background: linear-gradient(90deg, #e03131, #1c7ed6) }
#fade { mask-image: linear-gradient(to right, black, transparent) }
#dot { background: #2b8a3e; -webkit-mask: radial-gradient(circle, black 49%, transparent 51%) center / 30px 30px no-repeat }
#lum { mask-image: linear-gradient(white, black); mask-mode: luminance }
#xor { mask-image: linear-gradient(black, black), linear-gradient(90deg, black 50%, transparent 50%); mask-size: 100% 50%, 100% 100%; mask-repeat: no-repeat; mask-composite: exclude }
#op { opacity: .5; mask-image: linear-gradient(black, transparent) }
.ct { font: bold 30px sans-serif; background: linear-gradient(90deg, #f00, #00f); -webkit-background-clip: text; background-clip: text; color: transparent; padding: 0 4px; display: inline-block }
fieldset { margin: 6px; border: 3px solid #364fc7; padding: 4px 10px; width: 200px }
legend { margin-left: 12px; padding: 0 6px; font-size: 16px }
#fs2 { border-width: 3px; padding: 4px 10px }
#lg2 { line-height: 20px; color: #fff }
.long { height: 500px }
</style></head><body>
<div class="row"><div class="b" id="fade"></div><div class="b" id="dot"></div><div class="b" id="lum"></div><div class="b" id="xor"></div><div class="b" id="op"></div></div>
<div class="ct" id="ct">Fire <span>text</span></div>
<fieldset id="fs"><legend id="lg">Navigation</legend>content of the fieldset</fieldset>
<fieldset id="fs2"><legend id="lg2">Navigation</legend>x</fieldset>
<div class="long"></div>
</body></html>`

// Masks (gradients, luminance, composition, under opacity), background-clip: text and a fieldset's legend: the
// compositor draws what direct drawing draws, and what it draws is masked.
@(private = "file")
masks_clip_text_fieldset :: proc(t: ^testing.T) {
	f := new(Cx)
	defer free(f)
	if !cx_open(f, MASK_PAGE) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer cx_close(f)
	cx_paint(f, false)
	cx_same(t, f, "masks, clip text, fieldset")
	again := cx_same(t, f, "masks scrolled", 9)
	testing.expectf(t, again == 0, "scrolling masked content records nothing (%d)", again)
	img := cx_paint(f, false)
	px :: proc(img: []u8, x, y: f32) -> [3]int {
		o := (int(y) * COMP_SIZE.x + int(x)) * 4
		return {int(img[o]), int(img[o + 1]), int(img[o + 2])}
	}
	rect :: proc(f: ^Cx, id: string) -> lay.Rect {
		r, _ := lay.box_of(&f.l, dom.find_by_id(f.doc, id), {f32(COMP_SIZE.x), f32(COMP_SIZE.y)}, 0)
		return r.border
	}
	// fade: opaque red on the left, white on the right
	fr := rect(f, "fade")
	l, r := px(img, fr.min.x + 2, fr.min.y + 20), px(img, fr.max.x - 1, fr.min.y + 20)
	testing.expectf(t, l[0] > 200 && l[1] < 70, "masked start %v", l)
	testing.expectf(t, r[0] > 240 && r[1] > 240 && r[2] > 240, "masked end %v", r)
	// a 30 px disc in the middle of the green box: green at its center, white in the corners
	dr := rect(f, "dot")
	cpx := px(img, (dr.min.x + dr.max.x) * 0.5, (dr.min.y + dr.max.y) * 0.5)
	corner := px(img, dr.min.x + 3, dr.min.y + 3)
	testing.expectf(t, cpx[1] > 100 && cpx[0] < 80, "disc center %v", cpx)
	testing.expectf(t, corner == {255, 255, 255}, "outside the disc %v", corner)
	// luminance: the top shows, the bottom does not
	lr := rect(f, "lum")
	top, bottom := px(img, lr.min.x + 30, lr.min.y + 2), px(img, lr.min.x + 30, lr.max.y - 2)
	testing.expectf(t, top[1] < 120 && bottom[0] > 235 && bottom[1] > 235, "luminance mask top %v bottom %v", top, bottom)
	// exclude: the top half minus its left half, plus the bottom-left quarter
	xr := rect(f, "xor")
	tl, tr := px(img, xr.min.x + 10, xr.min.y + 10), px(img, xr.max.x - 10, xr.min.y + 10)
	bl, br := px(img, xr.min.x + 10, xr.max.y - 10), px(img, xr.max.x - 10, xr.max.y - 10)
	testing.expectf(t, tl == {255, 255, 255} && tr != {255, 255, 255} && bl != {255, 255, 255} && br == {255, 255, 255}, "exclude: %v %v %v %v", tl, tr, bl, br)
	// clip text: the gradient through the glyphs, the box itself white, no gray of the text color
	cr := rect(f, "ct")
	colored, gray := 0, 0
	for y := cr.min.y; y < cr.max.y; y += 1 {
		for x := cr.min.x; x < cr.max.x; x += 1 {
			p := px(img, x, y)
			if p[1] < 60 && (p[0] > 150 || p[2] > 150) { colored += 1 }
			if abs(p[0] - p[1]) < 12 && abs(p[1] - p[2]) < 12 && p[0] < 180 { gray += 1 }
		}
	}
	testing.expectf(t, colored > 150 && gray < 5, "background-clip: text: %d gradient pixels, %d gray", colored, gray)
	testing.expectf(t, px(img, cr.max.x - 2, cr.min.y + 2) == {255, 255, 255}, "around the glyphs the box shows nothing")
	// the fieldset's top border runs through the legend's middle, interrupted behind it
	fs, lg := rect(f, "fs"), rect(f, "lg")
	mid := (lg.min.y + lg.max.y) * 0.5
	testing.expectf(t, lg.min.y < fs.min.y + 2 && lg.min.x > fs.min.x + 20, "the legend is on the top border (%v in %v)", lg, fs)
	border := px(img, fs.min.x + 6, mid)
	testing.expectf(t, border[2] > 150 && border[0] < 90, "top border at the legend's middle %v", border)
	testing.expectf(t, px(img, lg.min.x + 1, mid) == {255, 255, 255}, "the border stops at the legend's border box %v", px(img, lg.min.x + 1, mid))
	above := px(img, fs.min.x + 6, fs.min.y + 1)
	testing.expectf(t, above == {255, 255, 255}, "above the moved border: nothing %v", above)
	// a border through the legend's middle at a fractional y (a 20 px legend on a 3 px border: 8.5 px down): the pixel
	// row the border only partly covers is not drawn behind the legend either (its text is white: all white)
	fs2, lg2 := rect(f, "fs2"), rect(f, "lg2")
	shift, _, ok := lay.fieldset_border(&f.l, lay.box_index(&f.l, dom.find_by_id(f.doc, "fs2")))
	testing.expectf(t, ok && shift != f32(int(shift)), "a fractional shift (%v)", shift)
	for composited in ([2]bool{false, true}) {
		pic := cx_paint(f, composited)
		leaked := 0
		for y := fs2.min.y; y < lg2.max.y; y += 1 {
			for x := lg2.min.x + 1; x < lg2.max.x - 1; x += 1 {
				if px(pic, x, y) != {255, 255, 255} { leaked += 1 }
			}
		}
		testing.expectf(t, leaked == 0, "composited %v: %d pixels of the border behind the legend %v", composited, leaked, lg2)
	}
}

@(private = "file")
composited_pages :: proc(t: ^testing.T) {
	f := new(Cx)
	defer free(f)
	if !cx_open(f, COMP_PAGE) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer cx_close(f)
	cx_paint(f, false)   // the glyph atlas fills in the same order for both
	first := cx_same(t, f, "first frame")
	testing.expectf(t, first > 2, "several chunks recorded (%d)", first)
	cx_same(t, f, "scrolled down", 57)   // records what comes into view
	// the document scrolls back between both: only the replay matrix changes
	again := cx_same(t, f, "scrolled", 30)
	testing.expectf(t, again == 0, "scrolling records nothing (%d)", again)
	// a container scrolls: one slot changes
	sc := dom.find_by_id(f.doc, "sc")
	f.l.scroll[sc] = {0, 23}
	moved := cx_same(t, f, "container scrolled")
	testing.expectf(t, moved == 0, "scrolling a container records nothing (%d)", moved)
}

TRANSFORM_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #fff; font-size: 13px }
.t { margin: 30px; width: 120px; height: 60px; background: #ffd8a8; border: 2px solid #e8590c; border-radius: 10px; transform: rotate(12deg) }
.u { margin: 10px 40px; width: 100px; height: 40px; background: #b2f2bb; transform: translate(20px, 4px) }
.f { position: fixed; right: 4px; bottom: 4px; width: 50px; height: 30px; background: #e64980 }
.s { position: sticky; top: 0; height: 20px; background: #845ef7 }
.long { height: 900px }
</style></head><body><div class="s">sticky</div><div class="t">Turned <b>text</b></div><div class="u">moved</div><div class="f"></div><div class="long"></div></body></html>`

@(private = "file")
transforms_move_slots :: proc(t: ^testing.T) {
	f := new(Cx)
	defer free(f)
	if !cx_open(f, TRANSFORM_PAGE) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer cx_close(f)
	cx_paint(f, false)
	cx_same(t, f, "transformed page", 0, 2)
	cx_same(t, f, "scrolled under fixed and sticky boxes", 40, 2)
	// a transform animation: the refresh path gives the space another matrix
	turned := -1
	for &sp, i in f.l.spaces { if sp.kind == .Transform && sp.mat[1] != 0 { turned = i } }
	testing.expect(t, turned >= 0)
	f.l.spaces[turned].mat = lay.mat_mul(f.l.spaces[turned].mat, lay.Matrix{0.96, 0.28, -0.28, 0.96, 0, 0})
	f.l.passes[.Refresh] += 1
	n := cx_same(t, f, "rotated further", 40, 2)
	testing.expectf(t, n == 0, "a moved transform records nothing (%d)", n)
}

@(private = "file")
recording_follows_changes :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<!doctype html><html><head><style>html, body { margin: 0; background: #fff; font-size: 12px } p { margin: 2px 6px; padding: 1px; background: #e7f5ff }</style></head><body>`)
	for i in 0 ..< 60 { fmt.sbprintf(&sb, `<p id="p%d">Paragraph %d with a little text.</p>`, i, i) }
	strings.write_string(&sb, `</body></html>`)
	f := new(Cx)
	defer free(f)
	if !cx_open(f, strings.to_string(sb)) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer cx_close(f)
	at :: 650   // paragraphs 32 to 47 show
	cx_paint(f, false, at)
	total := cx_same(t, f, "paragraphs", at)
	c := comps[&f.l]
	testing.expectf(t, total >= 4 && len(c.chunks) >= 4, "several chunks (%d recorded, %d chunks)", total, len(c.chunks))
	// a paint value changes (a new style record for one paragraph, as a hover restyle gives): one chunk records again
	p44 := dom.find_by_id(f.doc, "p44")
	for &it in f.l.items {
		if it.node != p44 || it.kind != .Box { continue }
		nc := new(style.Computed, context.temp_allocator)
		nc^ = it.cs^
		nc.background_color = {1, 0.8, 0.2, 1}
		it.cs = nc
	}
	f.l.restyled += 1
	f.l.passes[.Refresh] += 1
	n := cx_same(t, f, "a background color changed", at)
	testing.expectf(t, n == 1, "one chunk recorded again (%d)", n)
	// a layout pass that changes one paragraph's text: the chunks before it keep their pictures
	// pictures by content, before
	versions := make(map[u64]u64, len(c.chunks), context.temp_allocator)
	for ch in c.chunks { if ch.recorded && ch.pic != nil { versions[ch.sig] = ch.pic.version } }
	dom.set_text_content(f.doc, dom.find_by_id(f.doc, "p40"), "Paragraph forty, longer now: it wraps onto a second line because it holds much more text than before.")
	old := f.st
	f.st = style.compute_styles(f.eng, f.doc, {})
	cx_layout(f)
	style.styled_destroy(old)
	m := cx_same(t, f, "after a layout pass", at)
	c = comps[&f.l]
	kept, changed := 0, 0
	for ch in c.chunks {
		if !ch.visible || ch.immediate { continue }
		if v, ok := versions[ch.sig]; ok {
			kept += 1
			testing.expectf(t, ch.pic.version == v, "chunk [%d, %d): same content, not recorded again", ch.first, ch.end)
		} else {
			changed += 1
		}
	}
	testing.expectf(t, kept > 0 && m == changed, "a layout pass records the changed chunks only (%d recorded, %d changed, %d kept, %d before)", m, changed, kept, total)
}

// Text through the browser's text stack: fallback (the arrow in a Latin font, emoji), ligatures, bidi (an Arabic
// paragraph with digits and Latin), color emoji with modifiers and ZWJ sequences, letter-spacing, justification,
// small caps, and text rotated and scaled by a transform (rasterized at its screen size in the picture as directly).
TEXT_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #fff; color: #111; font: 15px 'Segoe UI' }
p { margin: 3px 6px }
.sp { letter-spacing: 2px; word-spacing: 4px }
.j { text-align: justify; width: 220px }
.t { margin: 18px 30px; width: 200px; transform: rotate(-8deg) scale(1.3); background: #fff3bf }
.sc { font-variant: small-caps }
.long { height: 600px }
</style></head><body>
<p>office &#x2190; back, affluent fjords</p>
<p dir="rtl">&#x645;&#x631;&#x62D;&#x628;&#x627; &#x628;&#x627;&#x644;&#x639;&#x627;&#x644;&#x645; 123 abc</p>
<p>emoji &#x1F600;&#x1F44D;&#x1F3FD; family &#x1F468;&#x200D;&#x1F469;&#x200D;&#x1F467; &#x5E9;&#x5DC;&#x5D5;&#x5DD; end</p>
<p class="sp">spaced out words</p>
<p class="j">justified text that wraps onto more than one line in this narrow box</p>
<div class="t">Turned &#x639;&#x631;&#x628;&#x64A; &#x1F600; text</div>
<p class="sc">Small Caps Here</p>
<div class="long"></div>
</body></html>`

@(private = "file")
multilingual_text :: proc(t: ^testing.T) {
	f := new(Cx)
	defer free(f)
	if !cx_open(f, TEXT_PAGE, real = true) { testing.fail_now(t, "no D3D11 device (WARP) or Segoe UI") }
	defer cx_close(f)
	cx_paint(f, false)   // the glyph atlas fills in the same order for both
	cx_same(t, f, "multilingual text", 0, 2)
	again := cx_same(t, f, "multilingual text scrolled", 31, 2)
	testing.expectf(t, again == 0, "scrolling text records nothing (%d)", again)
	// the atlas pages its glyphs are on are cleared: every picture with text is stale and records again
	font.clear_atlas(&f.fonts)
	n := cx_same(t, f, "after the glyph atlas was cleared", 31, 2)
	testing.expectf(t, n > 0, "pictures with text recorded again (%d)", n)
}