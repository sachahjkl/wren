package layout

import "core:math"
import "core:mem"
import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:style"

@(private = "file")
near_f32 :: proc(a, b: f32, eps: f32 = 0.01) -> bool { return math.abs(a - b) <= eps }

@(test)
content_size_and_box_sizes_match_box_of :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0">
		<div id=box style="width:200px;height:120px;padding:10px 12px 14px 16px;border:2px solid black;box-sizing:content-box"></div>
		<div id=bb style="width:200px;height:120px;padding:10px;border:5px solid black;box-sizing:border-box"></div>
		<span id=inl style="padding:4px 8px;border:1px solid black">hello</span>
	</body>`)
	defer fixture_unload(f)

	for id in ([]string{"box", "bb"}) {
		h := dom.find_by_id(f.doc, id)
		r, rok := box_of(&f.l, h, f.vp, 0)
		testing.expect(t, rok, "box_of succeeds")
		csz, cok := content_size(&f.l, h)
		testing.expect(t, cok, "content_size succeeds")
		testing.expect(t, near_f32(csz.x, r.content.max.x - r.content.min.x) && near_f32(csz.y, r.content.max.y - r.content.min.y), "content_size matches box_of")

		border, content, pad_off, inline_box, bok := box_sizes(&f.l, h)
		testing.expect(t, bok && !inline_box, "box_sizes succeeds for block")
		testing.expect(t, near_f32(border.x, r.border.max.x - r.border.min.x) && near_f32(border.y, r.border.max.y - r.border.min.y), "border size matches")
		testing.expect(t, near_f32(content.x, r.content.max.x - r.content.min.x) && near_f32(content.y, r.content.max.y - r.content.min.y), "content size matches")
		testing.expect(t, near_f32(pad_off.x, r.content.min.x - r.padding.min.x) && near_f32(pad_off.y, r.content.min.y - r.padding.min.y), "padding offset matches")
	}

	inl := dom.find_by_id(f.doc, "inl")
	_, _, _, is_inl, iok := box_sizes(&f.l, inl)
	testing.expect(t, iok && is_inl, "inline box reported as inline_box")
}

@(test)
space_offset_matches_view_make_and_scroll_digest_tracks_changes :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0;height:2000px">
		<div id=sc style="overflow:auto;width:200px;height:100px"><div id=inner style="height:500px;width:400px"></div></div>
		<div id=fx style="position:fixed;top:10px;left:10px;width:50px;height:50px"></div>
	</body>`)
	defer fixture_unload(f)

	d0 := scroll_digest(&f.l)
	sc := dom.find_by_id(f.doc, "sc")
	_, set_ok := set_scroll(&f.l, sc, {20, 45})
	testing.expect(t, set_ok, "scroll container scrolls")
	d1 := scroll_digest(&f.l)
	testing.expect(t, d1 != d0, "scroll_digest changes when container scrolls")

	set_doc_scroll_x(&f.l, 15)
	d2 := scroll_digest(&f.l)
	testing.expect(t, d2 != d1, "scroll_digest changes when doc_scroll_x changes")

	v := view_make(&f.l, f.vp, 120, cull = false)
	for s in 0 ..< len(f.l.spaces) {
		got := space_offset(&f.l, i32(s), f.vp, 120)
		want := v.offsets[s]
		testing.expectf(t, near_f32(got.x, want.x) && near_f32(got.y, want.y), "space %d offset %v != %v", s, got, want)
	}
}

@(private = "file")
f32_bits :: #force_inline proc(x: f32) -> u32 { return transmute(u32)x }

@(private = "file")
views_bit_identical :: proc(a, b: ^View) -> bool {
	if f32_bits(a.viewport.x) != f32_bits(b.viewport.x) || f32_bits(a.viewport.y) != f32_bits(b.viewport.y) { return false }
	if f32_bits(a.doc_scroll) != f32_bits(b.doc_scroll) || f32_bits(a.doc_scroll_x) != f32_bits(b.doc_scroll_x) { return false }
	if a.transformed != b.transformed || a.culled != b.culled { return false }
	if len(a.offsets) != len(b.offsets) || len(a.mats) != len(b.mats) || len(a.invs) != len(b.invs) || len(a.accs) != len(b.accs) { return false }
	if len(a.singular) != len(b.singular) || len(a.clips) != len(b.clips) || len(a.alphas) != len(b.alphas) || len(a.visible) != len(b.visible) { return false }
	for i in 0 ..< len(a.offsets) {
		if f32_bits(a.offsets[i].x) != f32_bits(b.offsets[i].x) || f32_bits(a.offsets[i].y) != f32_bits(b.offsets[i].y) { return false }
	}
	for i in 0 ..< len(a.mats) {
		for k in 0 ..< 6 { if f32_bits(a.mats[i][k]) != f32_bits(b.mats[i][k]) { return false } }
		for k in 0 ..< 6 { if f32_bits(a.invs[i][k]) != f32_bits(b.invs[i][k]) { return false } }
		if a.singular[i] != b.singular[i] { return false }
	}
	for i in 0 ..< len(a.accs) {
		for k in 0 ..< 16 { if f32_bits(a.accs[i][k]) != f32_bits(b.accs[i][k]) { return false } }
	}
	for i in 0 ..< len(a.clips) {
		ca, cb := a.clips[i], b.clips[i]
		if f32_bits(ca.min.x) != f32_bits(cb.min.x) || f32_bits(ca.min.y) != f32_bits(cb.min.y) ||
		   f32_bits(ca.max.x) != f32_bits(cb.max.x) || f32_bits(ca.max.y) != f32_bits(cb.max.y) { return false }
	}
	for i in 0 ..< len(a.alphas) {
		if f32_bits(a.alphas[i]) != f32_bits(b.alphas[i]) { return false }
	}
	for i in 0 ..< len(a.visible) {
		if a.visible[i] != b.visible[i] { return false }
	}
	return true
}

@(test)
view_update_matches_view_make_and_reuses_buffers_without_allocs :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0;height:2000px">
		<div id=fx style="position:fixed;top:5px;left:5px;width:40px;height:40px">fixed</div>
		<div id=wrap style="height:600px">
			<div id=st style="position:sticky;top:12px;height:40px">sticky</div>
			<div id=sc style="overflow:auto;width:200px;height:100px;border-radius:8px">
				<div id=inner style="height:500px;width:400px;opacity:0.6">scroll content</div>
			</div>
		</div>
		<div id=rot style="width:100px;height:80px;transform:rotate(15deg) translateX(20px)">rot2d</div>
		<div id=scene style="perspective:400px;width:200px;height:150px">
			<div id=p3d style="transform:rotateY(30deg);transform-style:preserve-3d;width:100px;height:100px;opacity:0.8">
				<div id=child3d style="transform:translateZ(20px);width:50px;height:50px">3d</div>
			</div>
		</div>
		<div id=extra></div>
	</body>`)
	defer fixture_unload(f)

	testing.expect(t, len(f.l.planes) > 0, "fixture has 3D planes")
	testing.expect(t, len(f.l.clips) > 0, "fixture has clips")
	testing.expect(t, len(f.l.groups) > 0, "fixture has opacity/plane groups")

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}
	alloc := mem.tracking_allocator(&track)

	// Warm up backing arrays (including vis_buf at full height so subsequent culled scrolls do not grow it).
	v: View
	defer view_destroy(&v)
	view_update(&v, &f.l, {f.vp.x, 2500}, 0, cull = true, allocator = alloc)
	ref0 := view_make(&f.l, {f.vp.x, 2500}, 0, cull = true)
	testing.expect(t, views_bit_identical(&v, &ref0), "initial view_update matches view_make")

	allocs_after_warmup := track.total_allocation_count
	sc := dom.find_by_id(f.doc, "sc")

	// Scroll, container scroll, horizontal scroll, viewport resize, and cull toggles: zero extra heap allocations.
	for scroll_y in ([]f32{0, 50, 140, 320, 80}) {
		view_update(&v, &f.l, f.vp, scroll_y, cull = false, allocator = alloc)
		ref_nc := view_make(&f.l, f.vp, scroll_y, cull = false)
		testing.expectf(t, views_bit_identical(&v, &ref_nc), "view_update(cull=false) differs at scroll=%v", scroll_y)

		view_update(&v, &f.l, f.vp, scroll_y, cull = true, allocator = alloc)
		ref_c := view_make(&f.l, f.vp, scroll_y, cull = true)
		testing.expectf(t, views_bit_identical(&v, &ref_c), "view_update(cull=true) differs at scroll=%v", scroll_y)
	}

	_, _ = set_scroll(&f.l, sc, {15, 65})
	set_doc_scroll_x(&f.l, 22)
	view_update(&v, &f.l, {640, 480}, 110, cull = true, allocator = alloc)
	ref_sc := view_make(&f.l, {640, 480}, 110, cull = true)
	testing.expect(t, views_bit_identical(&v, &ref_sc), "view_update matches after container scroll, doc_scroll_x, and resize")
	testing.expect_value(t, track.total_allocation_count, allocs_after_warmup)

	// Mutate DOM and relayout (adds a new 3D plane and sticky space, then removes them): stays bit-identical.
	extra := dom.find_by_id(f.doc, "extra")
	html.parse_into(f.doc, extra, transmute([]byte)string(`<div style="position:sticky;top:20px;transform:rotateX(25deg);height:60px">added</div>`), 64 * 1024)
	style.styled_destroy(f.st)
	f.st = style.compute_styles(f.eng, f.doc, {})
	fixture_run(f)
	view_update(&v, &f.l, f.vp, 90, cull = true, allocator = alloc)
	ref_grow := view_make(&f.l, f.vp, 90, cull = true)
	testing.expect(t, views_bit_identical(&v, &ref_grow), "view_update matches after layout growth")

	for dom.get(f.doc, extra).first_child != 0 {
		dom.remove_child(f.doc, extra, dom.get(f.doc, extra).first_child)
	}
	style.styled_destroy(f.st)
	f.st = style.compute_styles(f.eng, f.doc, {})
	fixture_run(f)
	view_update(&v, &f.l, f.vp, 40, cull = true, allocator = alloc)
	ref_shrink := view_make(&f.l, f.vp, 40, cull = true)
	testing.expect(t, views_bit_identical(&v, &ref_shrink), "view_update matches after layout shrink")

	// View_Cache hit/miss and cull upgrade without extra allocations.
	vc: View_Cache
	defer view_cache_destroy(&vc)
	cv1, hit1 := view_cache_get(&vc, &f.l, f.vp, 40, cull = false, allocator = alloc)
	testing.expect(t, cv1 != nil && !hit1 && !cv1.culled, "first cache access populates")
	cv2, hit2 := view_cache_get(&vc, &f.l, f.vp, 40, cull = false, allocator = alloc)
	testing.expect(t, cv2 == cv1 && hit2, "second identical access hits cache")
	cv3, hit3 := view_cache_get(&vc, &f.l, f.vp, 40, cull = true, allocator = alloc)
	testing.expect(t, cv3 == cv1 && hit3 && cv3.culled, "cull upgrade hits cache and computes visible")
	testing.expect(t, views_bit_identical(cv3, &ref_shrink), "cached culled view matches view_make")

	_, hit_scroll := view_cache_get(&vc, &f.l, f.vp, 45, cull = false, allocator = alloc)
	testing.expect(t, !hit_scroll, "doc_scroll change invalidates cache")
	_, hit_vp := view_cache_get(&vc, &f.l, {700, 500}, 45, cull = false, allocator = alloc)
	testing.expect(t, !hit_vp, "viewport change invalidates cache")
	_, _ = set_scroll(&f.l, sc, {0, 0})
	_, hit_cont := view_cache_get(&vc, &f.l, {700, 500}, 45, cull = false, allocator = alloc)
	testing.expect(t, !hit_cont, "container scroll change invalidates cache")
	view_cache_invalidate(&vc)
	_, hit_inv := view_cache_get(&vc, &f.l, {700, 500}, 45, cull = false, allocator = alloc)
	testing.expect(t, !hit_inv, "explicit invalidation forces rebuild")
}
