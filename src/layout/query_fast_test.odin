package layout

import "core:math"
import "core:testing"
import "wb:dom"

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
