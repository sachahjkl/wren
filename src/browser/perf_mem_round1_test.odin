package browser

import "core:fmt"
import "core:testing"
import "toolkit:font"
import "wb:base"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:page"
import "wb:style"

@(test)
font_cache_shares_system_cascades_and_evicts_lru_without_leaks :: proc(t: ^testing.T) {
	test_app(t)
	fs := new(font.State)
	defer free(fs)
	font.init(fs)
	defer font.destroy(fs)
	ui_id, _ := font.load_embedded(fs, font.FALLBACK_UI_DATA)

	pf: Page_Fonts
	page_fonts_init(&pf, fs, ui_id)

	tab_a := rawptr(uintptr(0x1001))
	tab_b := rawptr(uintptr(0x2002))
	fams := []string{"sans-serif"}

	// Two tabs with no matching web fonts share a single nil-scoped cache entry
	page_fonts_scope(&pf, tab_a)
	id_a := resolve_font(&pf, fams, 400, false, nil)
	page_fonts_scope(&pf, tab_b)
	id_b := resolve_font(&pf, fams, 400, false, nil)
	testing.expect(t, id_a != 0 && id_a == id_b, "system font cascade shared across tabs")
	testing.expect_value(t, len(pf.resolved), 1)
	for k in pf.resolved { testing.expect(t, k.scope == nil, "shared system entry omits tab scope") }

	// Registering a web font on tab_a scopes only tab_a's matching family request
	data := #load("../../examples/site/fonts/roboto.ttf")
	wf := page.Web_Font{family = "ScopedWeb", weight = {400, 400}, font_style = .Normal, data = data}
	testing.expect(t, register_web_face(&pf, tab_a, &wf), "web face loads")

	web_fams := []string{"ScopedWeb"}
	page_fonts_scope(&pf, tab_a)
	id_web := resolve_font(&pf, web_fams, 400, false, nil)
	page_fonts_scope(&pf, tab_b)
	id_sys := resolve_font(&pf, web_fams, 400, false, nil)
	testing.expect(t, id_web != 0 && id_sys != 0 && id_web != id_sys, "tab_a gets web font, tab_b gets shared fallback")
	// register_web_face calls page_fonts_forget, so only the two post-registration resolutions are cached
	testing.expect_value(t, len(pf.resolved), 2)

	// Bounded LRU eviction caps pf.resolved while keeping live Font_Ids valid until page_fonts_destroy
	page_fonts_scope(&pf, tab_b)
	pf.resolved_max = 8
	first_id: font.Font_Id
	for i in 0 ..< 20 {
		lang := fmt.tprintf("x-t%d", i)
		req := lay.Font_Request{families = fams, weight = 400, style = .Normal, stretch = 100, language = lang}
		cid := resolve_request(&pf, &req, nil)
		if i == 0 { first_id = cid }
	}
	testing.expect(t, len(pf.resolved) <= 8, "resolved map stays within LRU cap")
	testing.expect(t, first_id != 0 && font.valid(fs, first_id), "evicted cascade stays valid while live")

	// All tracked non-web cascades (including evicted ones) are unloaded on page_fonts_destroy
	kept := make([dynamic]font.Font_Id, 0, len(pf.shared_cascades), context.temp_allocator)
	for cid in pf.shared_cascades { append(&kept, cid) }
	page_fonts_destroy(&pf)
	testing.expect(t, !font.valid(fs, first_id), "first_id unloaded on page_fonts_destroy")
	for cid in kept {
		testing.expect(t, !font.valid(fs, cid), "non-web cascade unloaded on page_fonts_destroy")
	}
}

@(test)
bfcache_spares_release_leaves_layout_and_engine_reusable :: proc(t: ^testing.T) {
	test_app(t)
	testing.expect_value(t, PAGE_TEMP_KEEP_MAX, 32 << 20)

	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<div id=c><p>hello</p></div>`), 64 * 1024)

	ss := style.settings_default()
	defer style.settings_destroy(&ss)
	eng := style.engine_make(ss)
	defer style.engine_destroy(eng)
	_ = style.engine_add_sheet(eng, `#c { container-type: inline-size; } @container (min-width: 10px) { p { color: green; } }`, base.NIL_HANDLE)
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)
	_ = style.engine_containers(eng, st)

	l: Layout
	defer layout_destroy(&l)
	ls := lay.settings_default()
	lay.run(&l, lay.Input{
		doc = doc, styled = st, settings = &ls,
		text = lay.Text_Api{
			font = proc(_: rawptr, _: []string, _: u16, _: bool) -> lay.Font { return 1 },
			width = proc(_: rawptr, _: lay.Font, sz: f32, s: string) -> f32 { return f32(len(s)) * sz * 0.5 },
			metrics = proc(_: rawptr, _: lay.Font, sz: f32) -> lay.Font_Metrics { return {ascent = sz * 0.8, descent = sz * 0.2, x_height = sz * 0.5} },
		},
		viewport = {600, 400}, scale = 1, band_h = 256,
	})

	composite_forget(&l)
	text_clip_forget(&l)
	lay.release_spares(&l)
	style.engine_release_spares(eng)

	testing.expect(t, l.valid && len(l.boxes) > 0, "layout stays valid after releasing spares")
	testing.expect(t, len(eng.cq_containers) == 0 && eng.cq_settled_layout == nil, "engine spares cleared")
	st2 := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st2)
	testing.expect(t, st2 != nil && len(style.engine_containers(eng, st2)) == 1, "engine remains reusable after releasing spares")
}
