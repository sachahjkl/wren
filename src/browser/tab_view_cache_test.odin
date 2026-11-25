package browser

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:page"
import "wb:style"

@(private = "file")
test_layout_run :: proc(l: ^Layout, doc: ^dom.Document, st: ^style.Styled, viewport: lay.Vec2, scale: f32 = 1) {
	ls := lay.settings_default()
	lay.run(l, lay.Input{
		doc = doc, styled = st, settings = &ls,
		text = lay.Text_Api{
			font = proc(_: rawptr, _: []string, _: u16, _: bool) -> lay.Font { return 1 },
			width = proc(_: rawptr, _: lay.Font, sz: f32, s: string) -> f32 { return f32(len(s)) * sz * 0.5 },
			metrics = proc(_: rawptr, _: lay.Font, sz: f32) -> lay.Font_Metrics { return {ascent = sz * 0.8, descent = sz * 0.2, x_height = sz * 0.5} },
		},
		viewport = viewport, scale = scale, band_h = 256,
	})
}

@(test)
tab_view_cache_hits_and_invalidates :: proc(t: ^testing.T) {
	app := test_app(t)
	tab := tab_new_bare(app, active_window(app), "https://example.test/")
	append(&active_window(app).tabs, tab)
	defer layout_destroy(&tab.layout)

	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<body style="margin:0;height:1800px">
		<div id=btn style="width:120px;height:40px">click</div>
		<div id=sc style="overflow:auto;width:200px;height:100px"><div style="height:400px">inner</div></div>
		<div id=extra></div>
	</body>`), 64 * 1024)

	ss := style.settings_default()
	defer style.settings_destroy(&ss)
	eng := style.engine_make(ss)
	defer style.engine_destroy(eng)
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)

	vp := lay.Vec2{600, 400}
	test_layout_run(&tab.layout, doc, st, vp, 1)

	// First call populates the cache; repeated unchanged queries hit in O(1) with the exact same View.
	v1 := tab_view(tab, vp, 0, cull = false)
	testing.expect(t, v1 != nil && tab.view_cache.valid, "tab_view populates cache")
	key0 := tab.view_cache.key
	offs_ptr := raw_data(v1.offsets)

	v2, hit := lay.view_cache_get(&tab.view_cache, &tab.layout, vp, 0, cull = false)
	testing.expect(t, hit && v2 == v1 && raw_data(v2.offsets) == offs_ptr, "unchanged frame hits cached view")

	// Hit-testing and box queries reuse the cached view without rebuilding it.
	btn := dom.find_by_id(doc, "btn")
	h := tab_hit_test(tab, {20, 20}, vp, 0)
	testing.expect(t, h.item != lay.NONE, "tab_hit_test hits button")
	br, bok := tab_box_of(tab, btn, vp, 0)
	testing.expect(t, bok && br.border.max.x - br.border.min.x > 100, "tab_box_of returns button box")
	testing.expect(t, tab.view_cache.key == key0 && raw_data(tab.view_cache.view.offsets) == offs_ptr, "hit_test and box_of reuse cached view")

	// Vertical scroll change rebuilds in place (same backing slice pointer) and updates offset.
	v_scroll := tab_view(tab, vp, 75, cull = false)
	testing.expect(t, v_scroll == v1 && raw_data(v_scroll.offsets) == offs_ptr, "scroll updates in place without reallocating")
	testing.expect_value(t, v_scroll.offsets[0].y, f32(-75))

	// Scroll container change updates scroll_digest and invalidates the cached view.
	sc := dom.find_by_id(doc, "sc")
	_, sc_ok := lay.set_scroll(&tab.layout, sc, {0, 35})
	testing.expect(t, sc_ok, "container scrolled")
	_, hit_sc := lay.view_cache_get(&tab.view_cache, &tab.layout, vp, 75, cull = false)
	testing.expect(t, !hit_sc, "container scroll invalidates cached view")

	// Viewport resize invalidates the cached view.
	_, hit_vp := lay.view_cache_get(&tab.view_cache, &tab.layout, {800, 600}, 75, cull = false)
	testing.expect(t, !hit_vp, "viewport resize invalidates cached view")

	// Layout pass change invalidates the cached view.
	extra := dom.find_by_id(doc, "extra")
	html.parse_into(doc, extra, transmute([]byte)string(`<div style="height:50px">more</div>`), 64 * 1024)
	st2 := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st2)
	test_layout_run(&tab.layout, doc, st2, {800, 600}, 1)
	_, hit_lay := lay.view_cache_get(&tab.view_cache, &tab.layout, {800, 600}, 75, cull = false)
	testing.expect(t, !hit_lay, "new layout pass invalidates cached view")

	// layout_reset destroys the tab's cached view cleanly.
	layout_reset(&tab.layout)
	testing.expect(t, !tab.view_cache.valid && cap(tab.view_cache.view.offs_buf) == 0, "layout_reset frees cached view buffers")
	testing.expect(t, tab_view(tab, vp, 0) == nil, "tab_view returns nil on invalid layout")
}

@(test)
tab_view_cache_cleans_up_on_bfcache_take_and_restore :: proc(t: ^testing.T) {
	app := test_app(t)
	app.page_settings = page.settings_default()
	defer page.settings_destroy(&app.page_settings)
	app.process = base.scope_make("test-bf", nil)
	app.hcfg = {bf_enabled = true, bf_max_entries = 4, bf_max_bytes = 64 << 20, bf_timeout_ms = 60_000}

	tab := tab_new(app)
	append(&active_window(app).tabs, tab)
	defer {
		clear(&active_window(app).tabs)
		tab_free(app, tab)
		bfcache_shutdown(app)
		base.scope_close(app.process)
		page.frames_shutdown()
	}
	nav_fresh(tab, .Web)

	p := page.page_create(&app.loop, &app.loader, &app.page_settings, tab.nav, "https://example.test/a")
	tab.page = p
	page.navigable_attach(tab.top, p)
	html.parse_into(p.doc, p.doc.root, transmute([]byte)string(`<body style="margin:0;height:1200px"><div id=a style="height:200px">page A</div></body>`), 64 * 1024)
	st := page.styles(p, 600, 400, 1)
	test_layout_run(&tab.layout, p.doc, st, {600, 400}, 1)
	page.first_paint_done(p)

	entry := page.session_push(&tab.session, "https://example.test/a", page.page_id(p))
	v_before := tab_view(tab, {600, 400}, 0, cull = true)
	testing.expect(t, v_before != nil && tab.view_cache.valid && cap(tab.view_cache.view.offs_buf) > 0, "cached view allocated before bfcache_take")

	// Freeze and take into bfcache: tab.view_cache must be destroyed with zero leaks.
	leave_page(app, tab, keep = true, save = true)
	taken := bfcache_take(app, tab)
	testing.expect(t, taken, "bfcache_take stored page")
	testing.expect(t, !tab.view_cache.valid && cap(tab.view_cache.view.offs_buf) == 0, "bfcache_take destroys tab view_cache")

	// Restore from bfcache: tab_view rebuilds cleanly for the restored layout.
	restored := bfcache_restore(app, tab, entry)
	testing.expect(t, restored, "bfcache_restore succeeded")
	testing.expect(t, !tab.view_cache.valid, "bfcache_restore starts with clean view_cache")
	v_after := tab_view(tab, {600, 400}, 0, cull = false)
	testing.expect(t, v_after != nil && tab.view_cache.valid, "tab_view works after bfcache_restore")

	// Also verify bfcache_take_held destroys tab.view_cache without leaking.
	tab.hold.page = tab.page
	tab.hold.nav = tab.nav
	tab.hold.layout = tab.layout
	tab.hold.bf_entry = entry.id
	tab.page = nil
	tab.nav = nil
	tab.layout = {}
	nav_fresh(tab, .Web)
	taken_held := bfcache_take_held(app, tab)
	testing.expect(t, taken_held, "bfcache_take_held stored held page")
	testing.expect(t, !tab.view_cache.valid && cap(tab.view_cache.view.offs_buf) == 0, "bfcache_take_held destroys tab view_cache")
}
