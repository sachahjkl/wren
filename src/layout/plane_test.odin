package layout

import "core:fmt"
import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// 3D transforms in layout: which boxes are planes, how planes chain into 3D rendering contexts, the projection a view
// computes for them, and hit testing and box queries through it.

@(private = "file")
Px :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	tl:  ^style.Timeline,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
pt_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
pt_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) }
@(private = "file")
pt_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
pt_load :: proc(src: string, three_d := true) -> ^Px {
	f := new(Px)
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
	f.set.transforms_3d = three_d
	f.vp = {800, 600}
	pt_run(f)
	return f
}

@(private = "file")
pt_run :: proc(f: ^Px) {
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = Text_Api{font = pt_font, width = pt_width, metrics = pt_metrics}, viewport = f.vp, scale = 1, band_h = 256})
}

@(private = "file")
pt_unload :: proc(f: ^Px) {
	destroy(&f.l)
	style.timeline_destroy(f.tl, f.st)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
pbx :: proc(f: ^Px, id: string) -> ^Box {
	bi := box_index(&f.l, dom.find_by_id(f.doc, id))
	return bi == NONE ? nil : &f.l.boxes[bi]
}

@(private = "file")
phit :: proc(f: ^Px, x, y: f32) -> base.Handle { return hit_test(&f.l, {x, y}, f.vp, 0).node }

@(private = "file")
pnear :: proc(a, b: f32, eps: f32 = 0.5) -> bool { return math.abs(a - b) <= eps }

CARD :: `<body style="margin:0"><div id=wrap style="perspective:400px;width:200px;height:200px">
	<div id=card style="transform:rotateY(45deg);width:200px;height:200px;background:red"></div></div><div id=other style="width:300px;height:50px"></div></body>`

@(test)
planes_are_the_boxes_with_a_3d_transform :: proc(t: ^testing.T) {
	f := pt_load(`<body style="margin:0">
		<div id=a style="transform:rotateY(30deg);width:50px;height:50px"></div>
		<div id=b style="transform:translateZ(0px);width:50px;height:50px"></div>
		<div id=c style="transform:translate3d(0, 0, 0) rotate(10deg);width:50px;height:50px"></div>
		<div id=d style="perspective:100px;width:50px;height:50px"></div>
		<div id=e style="transform-style:preserve-3d;width:50px;height:50px"></div>
		<div id=g style="rotate:x 20deg;width:50px;height:50px"></div>
		<div id=h style="transform:matrix3d(1,0,0,0, 0,1,0,0, 0,0,1,0.001, 0,0,0,1);width:50px;height:50px"></div>
	</body>`)
	defer pt_unload(f)
	is_plane :: proc(f: ^Px, id: string) -> bool { b := pbx(f, id); return .Plane in b.flags && .Transformed in b.flags }
	testing.expect(t, is_plane(f, "a") && is_plane(f, "e") && is_plane(f, "g") && is_plane(f, "h"), "3D transforms and preserve-3d are planes")
	testing.expect(t, !is_plane(f, "b") && !is_plane(f, "c"), "translateZ(0) and 2D transforms are not")
	d := pbx(f, "d")
	testing.expect(t, .Transformed in d.flags && .Stacking in d.flags && .Plane not_in d.flags, "perspective alone: a transformed carrier, not a plane")
	testing.expect(t, f.l.spaces[pbx(f, "a").space].proj && f.l.spaces[pbx(f, "a").space].plane == pbx(f, "a").space)
	// with 3D off: nothing is a plane
	g := pt_load(`<body style="margin:0"><div id=a style="transform:rotateY(30deg);width:50px;height:50px"></div></body>`, false)
	defer pt_unload(g)
	testing.expect(t, .Plane not_in pbx(g, "a").flags && .Transformed in pbx(g, "a").flags, "3D off: an ordinary (flattened) transform")
}

@(test)
plane_projection_and_hit_test :: proc(t: ^testing.T) {
	f := pt_load(CARD)
	defer pt_unload(f)
	card := pbx(f, "card")
	sp := &f.l.spaces[card.space]
	testing.expect(t, sp.proj && sp.persp_from == pbx(f, "wrap").space, "the card sits in the perspective of wrap")
	v := view_make(&f.l, f.vp, 0, cull = false)
	testing.expect(t, !v.singular[card.space])
	// the middle stays; the right edge is farther (smaller) than the left
	mid, mok := plane_project(&f.l, &v, card.space, {100, 100})
	testing.expect(t, mok && pnear(mid.x, 100) && pnear(mid.y, 100), "rotation is about the middle")
	tl, _ := plane_project(&f.l, &v, card.space, {0, 0})
	tr, _ := plane_project(&f.l, &v, card.space, {200, 0})
	bl, _ := plane_project(&f.l, &v, card.space, {0, 200})
	br, _ := plane_project(&f.l, &v, card.space, {200, 200})
	hl, hr := bl.y - tl.y, br.y - tr.y
	testing.expectf(t, hr < hl - 20, "the edge turned away is shorter (%.1f vs %.1f)", hr, hl)
	// by hand: rotateY(45deg) of (100, 0) about the middle: z = -70.7, w = 1 + 70.7 / 400
	w := 1 + 100 * math.sin(f32(math.PI / 4)) / 400
	testing.expectf(t, pnear(tr.x, 100 + 100 * math.cos(f32(math.PI / 4)) / w) && pnear(tr.y, 100 - 100 / w), "top right corner (%v)", tr)
	// hit testing: inside the projection hits the card, the corner of the untransformed rect outside it does not
	testing.expect(t, phit(f, 100, 100) == dom.find_by_id(f.doc, "card"), "the middle hits the card")
	testing.expect(t, phit(f, 40, 100) == dom.find_by_id(f.doc, "card"))
	testing.expect(t, phit(f, 195, 5) != dom.find_by_id(f.doc, "card"), "outside the projected quad: not the card")
	testing.expect(t, phit(f, 195, 5) == dom.find_by_id(f.doc, "wrap"), "...but still wrap's box")
	// the round trip of a point through the plane
	q, _, ok := plane_point(&f.l, &v, card.space, tr)
	testing.expect(t, ok && pnear(q.x, 200, 0.05) && pnear(q.y, 0, 0.05), "plane_point inverts plane_project")
	// box queries: the quad and its bounding box
	r, rok := box_of(&f.l, dom.find_by_id(f.doc, "card"), f.vp, 0)
	testing.expect(t, rok && r.transformed)
	testing.expect(t, pnear(r.quad[1].x, tr.x) && pnear(r.quad[1].y, tr.y) && pnear(r.quad[3].y, bl.y))
	testing.expect(t, pnear(r.bounds.min.x, 14.1, 1) && pnear(r.bounds.max.x, 160, 1), "bounds of the projection")
	testing.expect(t, pnear(r.bounds.max.y - r.bounds.min.y, 243, 2), "the near edge grows")
}

// A point where the card is drawn goes back to the point of the card that is there, exactly (perspective divide included): the
// affine fit through three corners is off by several pixels at the far corner of a strongly turned card.
@(test)
box_point_to_local_is_exact_in_a_plane :: proc(t: ^testing.T) {
	f := pt_load(CARD)
	defer pt_unload(f)
	card := pbx(f, "card")
	v := view_make(&f.l, f.vp, 0, cull = false)
	r, ok := box_of(&f.l, dom.find_by_id(f.doc, "card"), f.vp, 0)
	testing.expect(t, ok && r.projective)
	worst, affine_worst: f32
	for p in ([]Vec2{{0, 0}, {200, 0}, {200, 200}, {0, 200}, {100, 100}, {30, 170}, {180, 20}, {150, 100}}) {
		screen, sok := plane_project(&f.l, &v, card.space, p)
		testing.expect(t, sok)
		back := box_point_to_local(r, screen)
		worst = max(worst, math.abs(back.x - p.x), math.abs(back.y - p.y))
		approx := mat_apply(r.inverse, screen)
		affine_worst = max(affine_worst, math.abs(approx.x - p.x), math.abs(approx.y - p.y))
	}
	testing.expectf(t, worst < 0.05, "the round trip is exact (off by %.3f)", worst)
	testing.expectf(t, affine_worst > 2, "(the affine fit alone is off by %.2f: the exact map is needed)", affine_worst)
}
@(test)
preserve_3d_contexts :: proc(t: ^testing.T) {
	f := pt_load(`<body style="margin:0"><div id=root style="perspective:600px;width:300px;height:300px">
		<div id=scene style="transform-style:preserve-3d;transform:rotateY(20deg);width:300px;height:300px">
			<div id=back style="transform:translateZ(-100px) rotateX(0deg);position:absolute;left:0;top:0;width:200px;height:200px;background:blue"></div>
			<div id=front style="transform:translateZ(100px) rotateX(0deg);position:absolute;left:0;top:0;width:200px;height:200px;background:red"></div>
			<div id=flat style="transform:rotateY(10deg);position:absolute;left:0;top:0;width:10px;height:10px">
				<div id=inner style="transform:rotateX(10deg);width:5px;height:5px"></div></div>
		</div></div></body>`)
	defer pt_unload(f)
	sp :: proc(f: ^Px, id: string) -> ^Space { return &f.l.spaces[pbx(f, id).space] }
	scene, back, front, flat, inner := sp(f, "scene"), sp(f, "back"), sp(f, "front"), sp(f, "flat"), sp(f, "inner")
	root_space := pbx(f, "scene").space
	testing.expect(t, scene.proj && scene.preserve && scene.ctx == root_space && scene.dest == NONE, "scene roots a context drawn on the page")
	testing.expect(t, back.ctx == root_space && front.ctx == root_space && back.dest == NONE, "its children are members of it")
	testing.expect(t, flat.ctx == root_space && flat.preserve == false, "flat is a member too; it keeps nothing 3D below it")
	testing.expect(t, inner.ctx == pbx(f, "inner").space && inner.dest == pbx(f, "flat").space, "a child of a flat plane is flattened into it")
	// the groups: members land where their root does
	gs := &f.l.groups[pbx(f, "front").group]
	testing.expect(t, .Plane in gs.effects && gs.space == pbx(f, "front").space)
	testing.expect(t, gs.dest == f.l.groups[pbx(f, "scene").group].parent, "front lands where scene does")
	// depth: the front plane is nearer than the back one at the same pixel
	v := view_make(&f.l, f.vp, 0, cull = false)
	_, zf, okf := plane_point(&f.l, &v, front.plane, {100, 100})
	_, zb, okb := plane_point(&f.l, &v, back.plane, {100, 100})
	testing.expect(t, okf && okb && zf > zb, "translateZ(100px) is nearer than translateZ(-100px)")
	// the nearer plane wins the hit even though it comes later in tree order
	testing.expect(t, phit(f, 150, 150) == dom.find_by_id(f.doc, "front"), "hit: the nearer plane")
}

@(test)
backface_hidden_boxes_in_a_3d_context_are_planes :: proc(t: ^testing.T) {
	f := pt_load(`<body style="margin:0"><div id=card style="perspective:500px;width:200px;height:200px">
		<div id=flip style="transform-style:preserve-3d;transform:rotateY(180deg);width:200px;height:200px">
			<div id=face style="backface-visibility:hidden;position:absolute;width:200px;height:200px"></div>
			<div id=lone style="width:50px;height:50px"></div></div></div>
		<div id=plain style="backface-visibility:hidden;width:50px;height:50px"></div></body>`)
	defer pt_unload(f)
	face := pbx(f, "face")
	testing.expect(t, .Plane in face.flags && f.l.spaces[face.space].back_hidden, "a hidden backface under preserve-3d is a plane of its own")
	testing.expect(t, .Transformed not_in pbx(f, "plain").flags && .Plane not_in pbx(f, "lone").flags, "elsewhere backface-visibility changes nothing")
	v := view_make(&f.l, f.vp, 0, cull = false)
	flip := pbx(f, "flip").space
	testing.expect(t, style.m4_back_facing(v.accs[flip]) && style.m4_back_facing(v.accs[face.space]), "rotateY(180deg): seen from behind, and so is its child")
}


// Every point of a box that holds a tilted preserve-3d card hits something of the box (the card, or the box itself): the pointer
// never "leaves" it while it is over it (the licence card of about:wren).
@(test)
hit_inside_a_box_with_a_tilted_card :: proc(t: ^testing.T) {
	for tilt in ([]string{"rotateX(11.20deg) rotateY(16.74deg)", "rotateX(-11deg) rotateY(16deg)", "rotateX(11deg) rotateY(-16deg)", "rotateX(0deg) rotateY(0deg)"}) {
		src := fmt.tprintf(`<body style="margin:0"><div id=box style="perspective:900px;width:440px;padding:12px 0;margin:40px"><div id=lic style="position:relative;width:100%;aspect-ratio:1.586;transform-style:preserve-3d;transform:%s">
			<div id=base style="position:absolute;inset:0;border-radius:14px;overflow:hidden;background:#446"></div>
			<div id=face style="position:absolute;inset:0;transform:translate3d(0,0,18px) scale(0.98)">Face text</div>
			<div id=seal style="position:absolute;right:16px;bottom:14px;width:88px;height:88px;border-radius:50%;background:#2a2;transform:translate3d(0,0,30px) scale(0.9667)"></div></div></div></body>`, tilt)
		f := pt_load(src)
		defer pt_unload(f)
		box := dom.find_by_id(f.doc, "box")
		bb := pbx(f, "box")
		bad := 0
		first := Vec2{}
		for y := bb.abs.y + 1; y < bb.abs.y + bb.size.y - 1; y += 7 {
			for x := bb.abs.x + 1; x < bb.abs.x + bb.size.x - 1; x += 9 {
				h := hit_test(&f.l, {x, y}, f.vp, 0)
				inside := false
				for n := h.node; n != base.NIL_HANDLE; n = dom.get(f.doc, n).parent { if n == box { inside = true; break } }
				if !inside { if bad == 0 { first = {x, y} }; bad += 1 }
			}
		}
		testing.expectf(t, bad == 0, "%s: %d points of the box hit something outside it (first at %v)", tilt, bad, first)
	}
}