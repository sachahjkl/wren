package layout

import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Effect groups in layout: which boxes get one, isolation of blending descendants, how far filters spread (layer
// zones, culling), clip-path geometry and hit testing under it, and the refresh path of animated effects.

@(private = "file")
Fx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	tl:  ^style.Timeline,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
fx_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
fx_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) }
@(private = "file")
fx_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
fx_run :: proc(f: ^Fx) {
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = Text_Api{font = fx_font, width = fx_width, metrics = fx_metrics}, viewport = f.vp, scale = 1, band_h = 256})
}

@(private = "file")
fx_load :: proc(src: string, vw: f32 = 800, vh: f32 = 600) -> ^Fx {
	f := new(Fx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.tl = style.timeline_make(f.eng)
	style.timeline_restyled(f.tl, f.doc, nil, f.st, 0)
	style.timeline_tick(f.tl, f.doc, f.st, 0)
	f.set = settings_default()
	f.vp = {vw, vh}
	fx_run(f)
	return f
}

@(private = "file")
fx_unload :: proc(f: ^Fx) {
	destroy(&f.l)
	style.timeline_destroy(f.tl, f.st)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
el :: proc(f: ^Fx, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

@(private = "file")
bi_of :: proc(f: ^Fx, id: string) -> i32 { return box_index(&f.l, el(f, id)) }

@(private = "file")
group_of :: proc(f: ^Fx, id: string) -> ^Group {
	bi := bi_of(f, id)
	if bi == NONE { return nil }
	for &g in f.l.groups { if g.box == bi { return &g } }
	return nil
}

@(private = "file")
hit :: proc(f: ^Fx, x, y: f32) -> base.Handle { return hit_test(&f.l, {x, y}, f.vp, 0).node }

@(test)
effect_groups_and_stacking :: proc(t: ^testing.T) {
	f := fx_load(`<body style="margin:0">
<div id=fl style="filter:blur(2px)"><div id=fx style="position:fixed;left:0;top:0;width:5px;height:5px"></div></div>
<div id=bd style="backdrop-filter:blur(4px)"><div id=bx style="position:fixed;left:0;top:0;width:5px;height:5px"></div></div>
<div id=cp style="clip-path:circle(10px)"></div>
<div id=plain style="opacity:1"></div>
<div id=ctx style="position:relative;z-index:0"><p id=mid><span id=bl style="mix-blend-mode:multiply">x</span></p></div>
<div id=top style="mix-blend-mode:screen;width:10px;height:10px"></div>
</body>`)
	defer fx_unload(f)
	g := group_of(f, "fl")
	testing.expect(t, g != nil && g.effects == {.Filter}, "filter: a group")
	testing.expect(t, .Stacking in f.l.boxes[bi_of(f, "fl")].flags)
	testing.expect(t, f.l.boxes[bi_of(f, "fx")].cb == bi_of(f, "fl"), "filter: containing block of fixed descendants")
	g = group_of(f, "bd")
	testing.expect(t, g != nil && g.effects == {.Backdrop}, "backdrop-filter: a group")
	testing.expect(t, .Stacking in f.l.boxes[bi_of(f, "bd")].flags, "backdrop-filter: a stacking context")
	testing.expect(t, f.l.boxes[bi_of(f, "bx")].cb == bi_of(f, "bd"), "backdrop-filter: containing block of fixed descendants")
	g = group_of(f, "cp")
	testing.expect(t, g != nil && g.effects == {.Clip_Path} && .Stacking in f.l.boxes[bi_of(f, "cp")].flags, "clip-path: a group, a stacking context")
	testing.expect(t, group_of(f, "plain") == nil, "nothing to do: no group")
	// the blending span is isolated in its stacking context (the positioned div), not in the paragraph
	g = group_of(f, "ctx")
	testing.expect(t, g != nil && g.effects == {.Isolate}, "the stacking context of a blending element is an isolated group")
	testing.expect(t, group_of(f, "mid") == nil, "a box that is not a stacking context is not isolated")
	g = group_of(f, "bl")
	testing.expect(t, g != nil && .Blend in g.effects && g.parent != NONE && f.l.groups[g.parent].box == bi_of(f, "ctx"), "the blend group nests in the isolated one")
	// a blending child of the root stacking context blends with the canvas: no isolation group above it
	g = group_of(f, "top")
	testing.expect(t, g != nil && g.parent == NONE, "blending at the root: no isolated group")
}

@(test)
filter_outsets_and_reach :: proc(t: ^testing.T) {
	ops := []style.Filter_Op{{kind = .Blur, v = 4}}
	testing.expect_value(t, filter_outset(ops, 1), [4]f32{12, 12, 12, 12})
	testing.expect_value(t, filter_outset(ops, 2), [4]f32{24, 24, 24, 24})
	// drop-shadow(10px 5px 8px): 3 sigma = 1.5 x blur radius = 12, moved by the offset
	sh := []style.Filter_Op{{kind = .Drop_Shadow, shadow = style.Shadow{x = 10, y = 5, blur = 8, color = {0, 0, 0, 1}}}}
	testing.expect_value(t, filter_outset(sh, 1), [4]f32{2, 7, 22, 17})
	// a blur after the shadow spreads everything again; a transparent shadow spreads nothing
	both := []style.Filter_Op{sh[0], {kind = .Blur, v = 2}}
	testing.expect_value(t, filter_outset(both, 1), [4]f32{8, 13, 28, 23})
	none := []style.Filter_Op{{kind = .Drop_Shadow, shadow = style.Shadow{x = 10, blur = 8}}, {kind = .Grayscale, v = 1}}
	testing.expect_value(t, filter_outset(none, 1), [4]f32{0, 0, 0, 0})

	// reach: the group's own spread plus its ancestors'; culling keeps what a blur brings into view
	f := fx_load(`<body style="margin:0">
<div id=o style="filter:blur(5px);margin-top:600px"><div id=i style="filter:drop-shadow(0 0 4px black)"><div id=c style="height:10px;background:red"></div></div></div>
</body>`, 800, 590)
	defer fx_unload(f)
	go, gi := group_of(f, "o"), group_of(f, "i")
	testing.expect(t, go != nil && gi != nil)
	testing.expectf(t, go.reach == 15, "outer reach %v", go.reach)
	testing.expectf(t, gi.reach == 15 + 6, "inner reach adds the outer one: %v", gi.reach)
	v := view_make(&f.l, f.vp, 0)
	found := false
	for idx in v.visible { if f.l.items[idx].node == el(f, "c") { found = true } }
	testing.expect(t, found, "a box 10 px below the viewport, blurred by 15 px, is painted")
	v2 := view_make(&f.l, {800, 560}, 0)
	found = false
	for idx in v2.visible { if f.l.items[idx].node == el(f, "c") { found = true } }
	testing.expect(t, !found, "40 px below: culled")
}

@(private = "file")
near :: proc(a, b: f32, eps: f32 = 0.01) -> bool { return math.abs(a - b) <= eps }

@(test)
clip_path_geometry :: proc(t: ^testing.T) {
	f := fx_load(`<body style="margin:0">
<div id=in style="width:100px;height:80px;border:5px solid;padding:10px;clip-path:inset(10px 20% 5px 0 round 8px 4px)"></div>
<div id=ci style="width:100px;height:60px;clip-path:circle(closest-side at 30px 50%)"></div>
<div id=cr style="width:100px;height:60px;clip-path:circle(50%)"></div>
<div id=el style="width:100px;height:60px;padding:10px;clip-path:ellipse(25% 40% at right top) content-box"></div>
<div id=po style="width:100px;height:50px;clip-path:polygon(evenodd, 0 0, 100% 0, 50% 100%)"></div>
<div id=bo style="width:100px;height:50px;border:10px solid;border-radius:20px;clip-path:padding-box"></div>
<div id=ma style="width:100px;height:50px;margin:5px 7px;clip-path:margin-box"></div>
<div id=ur style="width:10px;height:10px;clip-path:url(#c)"></div>
</body>`)
	defer fx_unload(f)
	b := &f.l.boxes[bi_of(f, "in")]
	s := clip_path_shape(&f.l, bi_of(f, "in"))
	// border box 130 x 110 at y = 0; insets 10 / 26 / 5 / 0
	testing.expectf(t, s.kind == .Rect && s.rect.min == b.abs + {0, 10} && s.rect.max == b.abs + {104, 105}, "inset rect %v", s.rect)
	testing.expectf(t, s.radii == {8, 4, 4, 8}, "round 8px 4px: tl br = 8, tr bl = 4 (draw order tl bl tr br): %v", s.radii)

	ci := clip_path_shape(&f.l, bi_of(f, "ci"))
	cb := &f.l.boxes[bi_of(f, "ci")]
	testing.expectf(t, ci.kind == .Ellipse && ci.center == cb.abs + {30, 30} && ci.radius == {30, 30}, "closest side at 30px: %v %v", ci.center, ci.radius)
	cr := clip_path_shape(&f.l, bi_of(f, "cr"))
	want := f32(50) * math.sqrt(f32(100 * 100 + 60 * 60)) / math.SQRT_TWO / 100
	testing.expectf(t, near(cr.radius.x, want), "circle(50%%): of sqrt(w^2 + h^2) / sqrt 2: %v want %v", cr.radius.x, want)

	eb := &f.l.boxes[bi_of(f, "el")]
	e := clip_path_shape(&f.l, bi_of(f, "el"))
	// content box 100 x 60 at (10, 10) of the border box
	testing.expectf(t, e.center == eb.abs + {110, 10} && e.radius == {25, 24}, "ellipse in the content box: %v %v", e.center, e.radius)

	p := clip_path_shape(&f.l, bi_of(f, "po"))
	pb := &f.l.boxes[bi_of(f, "po")]
	testing.expect(t, p.kind == .Polygon && len(p.points) == 3 && p.evenodd)
	testing.expect(t, p.points[2] == pb.abs + {50, 50}, "polygon percentages of the reference box")

	bo := clip_path_shape(&f.l, bi_of(f, "bo"))
	bb := &f.l.boxes[bi_of(f, "bo")]
	testing.expectf(t, bo.kind == .Rect && bo.rect.min == bb.abs + 10 && bo.radii == {10, 10, 10, 10}, "padding-box with inner radii: %v %v", bo.rect, bo.radii)
	ma := clip_path_shape(&f.l, bi_of(f, "ma"))
	mb := &f.l.boxes[bi_of(f, "ma")]
	testing.expectf(t, ma.rect.min == mb.abs - {7, 5} && ma.rect.max == {800, mb.abs.y + mb.size.y + 5}, "margin-box (the used right margin fills the line): %v", ma.rect)
	testing.expect(t, clip_path_shape(&f.l, bi_of(f, "ur")).kind == .None, "url(): not a basic shape, no clip")

	testing.expect(t, clip_shape_contains(p, pb.abs + {50, 10}) && !clip_shape_contains(p, pb.abs + {5, 40}), "inside / outside the triangle")
	testing.expect(t, clip_shape_contains(s, b.abs + {50, 50}) && !clip_shape_contains(s, b.abs + {1, 11}) && !clip_shape_contains(s, b.abs + {50, 5}), "rounded inset")
}

@(test)
hit_test_follows_clip_path :: proc(t: ^testing.T) {
	f := fx_load(`<body style="margin:0">
<div id=c style="position:absolute;left:0;top:0;width:100px;height:100px;background:red;clip-path:circle(50px)">
  <div id=k style="position:absolute;left:80px;top:0;width:40px;height:20px;background:blue"></div>
</div>
<div id=s style="position:absolute;left:200px;top:0;width:100px;height:100px;background:red;clip-path:polygon(evenodd, 50% 0, 100% 100%, 0 38%, 100% 38%, 0 100%)"></div>
<div id=r style="position:absolute;left:0;top:200px;width:100px;height:100px;background:red;transform:rotate(45deg);clip-path:inset(0 50% 0 0)"></div>
<div id=under style="position:absolute;left:0;top:400px;width:100px;height:100px"></div>
<div id=over style="position:absolute;left:0;top:400px;width:100px;height:100px;background:red;clip-path:inset(50px 0 0 0)"></div>
</body>`)
	defer fx_unload(f)
	c, k := el(f, "c"), el(f, "k")
	testing.expect(t, hit(f, 50, 50) == c, "inside the circle")
	testing.expect(t, hit(f, 5, 5) != c, "corner of the box, outside the circle: not hit")
	testing.expect(t, hit(f, 90, 18) != k, "a child outside its parent's clip-path is not hit")
	testing.expect(t, hit(f, 85, 15) == k, "a child inside it is")
	testing.expect(t, hit(f, 110, 10) != k, "past the clipped box")
	s := el(f, "s")
	testing.expect(t, hit(f, 250, 10) == s, "a point of the star")
	testing.expect(t, hit(f, 250, 50) != s, "even-odd: the center is a hole")
	// rotated 45 degrees, left half kept: the left half of the diamond
	r := el(f, "r")
	testing.expect(t, hit(f, 30, 250) == r, "left part of the rotated box")
	testing.expect(t, hit(f, 70, 250) != r, "right part: clipped away")
	// what a clip-path cuts away lets the pointer through to what is below
	testing.expect(t, hit(f, 50, 420) == el(f, "under"), "the clipped-out top half of the box above")
	testing.expect(t, hit(f, 50, 470) == el(f, "over"), "its visible half")
}

@(test)
animated_clip_path_refreshes :: proc(t: ^testing.T) {
	f := fx_load(`<style>@keyframes iris { from { clip-path: circle(10px at 50% 50%) } to { clip-path: circle(50px at 50% 50%) } }</style>
<body style="margin:0"><div id=a style="position:absolute;left:0;top:0;width:100px;height:100px;background:red;animation:iris 1s linear infinite"></div></body>`)
	defer fx_unload(f)
	a := el(f, "a")
	testing.expect(t, hit(f, 50, 50) == a && hit(f, 50, 25) != a, "radius 10 at the start")
	fulls := f.l.passes[.Full]
	style.timeline_tick(f.tl, f.doc, f.st, 750)
	fx_run(f)
	testing.expectf(t, f.l.passes[.Full] == fulls && f.l.last_pass == .Refresh, "an animated clip-path refreshes the layout: %v", f.l.last_pass)
	testing.expect(t, hit(f, 50, 25) == a && hit(f, 50, 5) != a, "radius 40 at 3/4: the hit test follows")
}
