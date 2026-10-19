package browser

import "core:log"
import "core:testing"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "wb:config"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

// Kept effect results (effects_cache.odin) against direct drawing, on an offscreen renderer (WARP): filtered groups,
// a drop shadow, a blend mode, a backdrop and a blurred text shadow composited from their kept results give the
// pixels of drawing them; a scroll reuses them (moved); a changed color under a backdrop or inside a filtered group
// draws them again.

@(private = "file")
Fx_Cx :: struct {
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

@(private = "file") FX_SIZE :: [2]int{360, 300}

@(private = "file")
fx_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font((^Fx_Cx)(user).face) }
@(private = "file")
fx_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return font.text_width(&(^Fx_Cx)(user).fonts, font.Font_Id(f), size, text) }
@(private = "file")
fx_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
fx_open :: proc(f: ^Fx_Cx, src: string) -> bool {
	f.prefs = config.prefs_make()
	register_all_prefs(&f.prefs)
	s := render_settings_from_prefs(&f.prefs)
	if !render.init_offscreen(&f.r, FX_SIZE, warp = true, space = s.space) { return false }
	render.set_text_rendering(&f.r, s.text)
	font.init(&f.fonts)
	ok: bool
	f.face, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	page_render.settings = lay.settings_from_prefs(&f.prefs)
	effects_settings = effects_settings_from_prefs(&f.prefs)
	fx_settings = fx_settings_from_prefs(&f.prefs)
	render.set_filter_precision(&f.r, fx_settings.precision)
	compositor_settings = compositor_settings_from_prefs(&f.prefs)
	compositor_settings.chunk_items = 8
	compositor_settings.settle_ms = 0
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	lay.run(&f.l, lay.Input{doc = f.doc, styled = f.st, settings = &page_render.settings,
		text = lay.Text_Api{user = f, font = fx_font, width = fx_width, metrics = fx_metrics},
		viewport = {f32(FX_SIZE.x), f32(FX_SIZE.y)}, scale = 1, band_h = 256})
	return ok
}

@(private = "file")
fx_close :: proc(f: ^Fx_Cx) {
	layout_destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	draw.destroy(&f.dc)
	render.destroy(&f.r)
	font.destroy(&f.fonts)
	config.prefs_destroy(&f.prefs)
	compositor_settings = {enabled = true, chunk_items = 512, max_chunks = 4096, settle_ms = 50, memory = 256 << 20}
}

@(private = "file")
fx_paint :: proc(f: ^Fx_Cx, composited: bool, scroll: f32 = 0) -> []u8 {
	compositor_settings.enabled = composited
	size := draw.Vec2{f32(FX_SIZE.x), f32(FX_SIZE.y)}
	draw.begin_frame(&f.dc, size)
	render.frame_begin(&f.r, {1, 1, 1, 1})
	paint(&f.l, &f.dc, f.doc, {0, 0}, size, scroll, {{0, 0}, size})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

// Composited (frames enough for the results to be kept), then direct: the same pixels; the stats of the last
// composited frame.
@(private = "file")
fx_same :: proc(t: ^testing.T, f: ^Fx_Cx, what: string, scroll: f32 = 0, frames := 3, loc := #caller_location) -> draw.Layer_Cache_Stats {
	a: []u8
	for _ in 0 ..< frames { a = fx_paint(f, true, scroll) }
	s := draw.layer_cache_stats(&f.dc)
	b := fx_paint(f, false, scroll)
	worst, count := 0, 0
	for i in 0 ..< len(a) {
		d := abs(int(a[i]) - int(b[i]))
		worst = max(worst, d)
		if d > 0 { count += 1 }
	}
	log.infof("%s: %d of %d bytes differ, worst %d; %v", what, count, len(a), worst, s)
	testing.expectf(t, worst <= 2, "%s: composited with kept effects differs from direct drawing (%d bytes, worst %d; %v)", what, count, worst, s, loc = loc)
	return s
}

FX_CACHE_PAGE :: `<!doctype html><html><head><style>
html, body { margin: 0; background: #fff; font-size: 13px }
.bg { position: relative; height: 220px; background: linear-gradient(90deg, #ff8787, #ffd43b 50%, #4dabf7) }
.stripe { position: absolute; left: 0; width: 360px; height: 6px; background: rgba(0, 0, 0, 0.4) }
.card { position: absolute; left: 20px; top: 20px; width: 100px; height: 60px; background: #69db7c; border-radius: 8px;
        filter: drop-shadow(3px 4px 3px rgba(0, 0, 0, 0.5)) sepia(0.6) }
.blurred { position: absolute; left: 150px; top: 20px; width: 80px; height: 60px; background: #7048e8; filter: blur(5px) }
.glass { position: absolute; left: 60px; top: 110px; width: 160px; height: 70px; border-radius: 12px;
         backdrop-filter: blur(8px) saturate(1.5); background: rgba(255, 255, 255, 0.2) }
.mult { position: absolute; left: 250px; top: 110px; width: 80px; height: 60px; background: #e64980; mix-blend-mode: multiply }
.glow { margin: 6px; font-size: 20px; text-shadow: 0 0 6px #1971c2 }
.long { height: 600px }
</style></head><body><div class="bg"><div class="stripe" style="top: 40px"></div><div class="stripe" style="top: 140px"></div>
<div class="card" id="card">card</div><div class="blurred"></div><div class="glass" id="glass">glass</div><div class="mult"></div></div>
<p class="glow">Glowing text</p><div class="long"></div></body></html>`

@(test)
kept_effects_match_direct_drawing :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	f := new(Fx_Cx)
	defer free(f)
	if !fx_open(f, FX_CACHE_PAGE) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer fx_close(f)
	fx_paint(f, false)   // the glyph atlas fills in the same order for both
	s := fx_same(t, f, "kept effects")
	testing.expectf(t, s.hits >= 4 && s.misses == 0, "every effect reused on the third frame: %v", s)

	// the document scrolls by whole pixels: the kept results move with it
	s = fx_same(t, f, "scrolled", 31, 1)
	testing.expectf(t, s.hits >= 4 && s.misses == 0, "scrolling reuses them: %v", s)

	// a color inside a filtered group: that group is filtered again, the others are reused
	card := dom.find_by_id(f.doc, "card")
	for &it in f.l.items {
		if it.node != card || it.kind != .Box { continue }
		nc := new(style.Computed, context.temp_allocator)
		nc^ = it.cs^
		nc.background_color = {0.9, 0.2, 0.1, 1}
		it.cs = nc
	}
	f.l.restyled += 1
	f.l.passes[.Refresh] += 1
	s = fx_same(t, f, "a color in a filtered group", 31, 1)
	testing.expectf(t, s.misses >= 1 && s.hits >= 3, "the changed group is drawn again, the others reused: %v", s)

	// the stripe under the glass changes color: its backdrop is captured again
	for &it in f.l.items {
		if it.kind != .Box || it.cs == nil || it.cs.background_color.a != 0.4 { continue }
		nc := new(style.Computed, context.temp_allocator)
		nc^ = it.cs^
		nc.background_color = {0, 0.3, 0, 0.6}
		it.cs = nc
	}
	f.l.restyled += 1
	f.l.passes[.Refresh] += 1
	s = fx_same(t, f, "under the glass changed", 31, 1)
	testing.expectf(t, s.misses >= 1, "the backdrop is captured again: %v", s)
	fx_same(t, f, "settled again", 0)

	// caching off: the same pixels
	fx_settings.enabled = false
	defer fx_settings.enabled = true
	s = fx_same(t, f, "cache off", 0, 1)
	testing.expectf(t, s.hits == 0, "nothing reused with the cache off: %v", s)
}
