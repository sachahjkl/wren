package layout

import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"

// <foreignObject> of inline <svg> elements: its box in the <svg>'s coordinate space (viewBox, preserveAspectRatio, the
// transforms around it), the clip and blur it takes from SVG, hit testing through them.

@(private = "file")
el :: proc(f: ^Fixture, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

@(private = "file")
bx :: proc(f: ^Fixture, id: string) -> i32 { return box_index(&f.l, el(f, id)) }

@(private = "file")
hit :: proc(f: ^Fixture, x, y: f32) -> base.Handle { return hit_test(&f.l, {x, y}, f.vp, 0).node }

@(private = "file")
near :: proc(a, b: Vec2) -> bool { return math.abs(a.x - b.x) <= 0.01 && math.abs(a.y - b.y) <= 0.01 }

// Google's "G" (its results pages): a conic gradient in a foreignObject, blurred, clipped to the letter's path.
@(private = "file")
G_LOGO :: `<body style="margin:0"><svg id=svg style="display:block" height="26" width="26" viewBox="0 0 24 24"><clipPath id="c"><path d="M12 10v4.5h6.47c-.5 2.7-3 4.74-6.47 4.74-3.9 0-7.1-3.3-7.1-7.25S8.1 4.75 12 4.75c1.8 0 3.35.6 4.6 1.8l3.4-3.4C18 1.2 15.24 0 12 0 5.4 0 0 5.4 0 12s5.4 12 12 12c7 0 11.5-4.9 11.5-11.7 0-.8-.1-1.54-.2-2.3H12z"></path></clipPath><filter id="f"><feGaussianBlur stdDeviation="1"></feGaussianBlur></filter><g style="clip-path:url(#c)"><foreignObject id=fo style="filter:url(#f)" height="28" transform="translate(-2,-2)" width="28"><div id=grad style="width:100%;height:100%;background:conic-gradient(red,blue)"></div></foreignObject><rect fill="#3186FF" height="8" width="16" x="11" y="8"></rect></g></svg></body>`

@(test)
foreign_object_g_logo :: proc(t: ^testing.T) {
	f := fixture_load(G_LOGO)
	defer fixture_unload(f)
	sv, fo, gr := bx(f, "svg"), bx(f, "fo"), bx(f, "grad")
	if !testing.expect(t, sv != NONE && fo != NONE && gr != NONE, "the foreignObject and its content have boxes") { return }
	b := &f.l.boxes[fo]
	testing.expect(t, b.parent == sv && b.cb == sv && b.flags >= {.Abs, .Transformed, .Foreign}, "an absolutely positioned child of the <svg>")
	testing.expect(t, near(b.size, {28, 28}) && near(f.l.boxes[gr].size, {28, 28}), "its size in user units, its content laid out in it")
	k: f32 = 26.0 / 24
	m := box_matrix(&f.l, b)
	testing.expectf(t, near(mat_apply(m, b.abs), {-2 * k, -2 * k}) && near(mat_apply(m, b.abs + {28, 28}), {26 * k, 26 * k}), "viewBox and translate(-2,-2): %v", m)
	g: ^Group
	for &x in f.l.groups { if x.box == fo { g = &x } }
	testing.expect(t, g != nil && g.effects == {.Filter, .Clip_Path}, "a group: the blur, then the clip")
	testing.expect(t, len(b.cs.filter) == 1 && b.cs.filter[0].kind == .Blur && b.cs.filter[0].v == 1, "feGaussianBlur as blur(1px)")
	sh := clip_path_shape(&f.l, fo)
	testing.expect(t, sh.kind == .Polygon && len(sh.points) > 20, "the letter's path as a polygon")
	// in its own coordinates: the G's top stroke at user (12, 2), its hole at (8, 12), shifted by the translate
	testing.expect(t, clip_shape_contains(sh, b.abs + {14, 4}) && !clip_shape_contains(sh, b.abs + {10, 14}), "the clip in its own coordinates")
	testing.expect(t, hit(f, 12 * k, 2 * k) == el(f, "grad"), "the stroke hits the HTML inside")
	testing.expect(t, hit(f, 8 * k, 12 * k) == el(f, "svg"), "the hole hits the <svg>")
	testing.expect(t, f.l.boxes[sv].first == fo, "the <svg> picture leaves it out, the box carries it")
}

@(test)
foreign_object_viewport :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0">
<svg id=a style="display:block" width="300" height="100" viewBox="0 0 150 50"><g transform="translate(5 0)"><foreignObject id=fa x="5" y="5" width="130" height="40"><p id=pa style="margin:0;font-size:10px">hello</p></foreignObject></g></svg>
<svg id=b style="display:block" width="200" height="100" viewBox="0 0 50 50"><foreignObject id=fb width="50" height="50"><div id=db style="height:50px"></div></foreignObject></svg>
<svg id=c style="display:block" width="200" height="100" viewBox="0 0 50 50" preserveAspectRatio="none"><foreignObject id=fc width="50" height="50"><div style="height:50px"></div></foreignObject></svg>
<svg id=d width="10" height="10"><defs><foreignObject id=fd width="5" height="5"></foreignObject></defs><foreignObject id=fe width="0" height="5"></foreignObject></svg>
</body>`)
	defer fixture_unload(f)
	fa := bx(f, "fa")
	if !testing.expect(t, fa != NONE && bx(f, "pa") != NONE) { return }
	b := &f.l.boxes[fa]
	testing.expect(t, f.l.boxes[bx(f, "pa")].size.x == 130, "the HTML laid out at its own size")
	m := box_matrix(&f.l, b)
	testing.expectf(t, near(mat_apply(m, b.abs), {20, 10}) && near(mat_apply(m, b.abs + {130, 40}), {280, 90}), "scaled by 2, the <g>'s translate and x / y: %v", m)
	testing.expect(t, hit(f, 22, 12) == el(f, "pa"), "hit through the transform")
	// meet, centred: 2x, 50 px on each side
	fb := &f.l.boxes[bx(f, "fb")]
	top := content_rect(&f.l.boxes[bx(f, "b")]).min
	mb := box_matrix(&f.l, fb)
	testing.expect(t, near(mat_apply(mb, fb.abs), top + {50, 0}) && near(mat_apply(mb, fb.abs + {50, 50}), top + {150, 100}), "xMidYMid meet")
	fc := &f.l.boxes[bx(f, "fc")]
	topc := content_rect(&f.l.boxes[bx(f, "c")]).min
	mc := box_matrix(&f.l, fc)
	testing.expect(t, near(mat_apply(mc, fc.abs + {50, 50}), topc + {200, 100}), "preserveAspectRatio none stretches")
	testing.expect(t, bx(f, "fd") == NONE && bx(f, "fe") == NONE, "none in <defs>, none without a size")
}

// Shapes after a foreign object cover it: the <svg>'s item draws the part before it, the foreign object's paint is
// followed by an item of the part after it; an <svg> without foreign objects draws all of its picture at once.
@(test)
foreign_object_paint_order :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0"><svg id=svg width="40" height="20"><rect width="40" height="20"/><foreignObject id=fo width="20" height="20"><div id=in style="height:20px;background:red"></div></foreignObject><g><foreignObject width="0" height="5"></foreignObject><rect width="10" height="10"/><foreignObject id=fo2 x="20" width="20" height="20"></foreignObject></g><rect width="5" height="5"/></svg><svg id=plain width="5" height="5"></svg></body>`)
	defer fixture_unload(f)
	sv, fo, fo2 := bx(f, "svg"), bx(f, "fo"), bx(f, "fo2")
	if !testing.expect(t, sv != NONE && fo != NONE && fo2 != NONE) { return }
	parts := make([dynamic]Svg_Parts, 0, 4, context.temp_allocator)
	inner_at, rest_at := -1, -1
	for it, i in f.l.items {
		if it.kind == .Replaced && it.box == sv { append(&parts, it.parts) }
		if it.kind == .Replaced && it.box == sv && it.parts.from == 1 { rest_at = i }
		if it.box == bx(f, "in") && inner_at < 0 { inner_at = i }
		if it.kind == .Replaced && it.box == bx(f, "plain") { testing.expect(t, it.parts == {}, "no foreign object: the whole picture") }
	}
	// (the foreign object without a size makes no box: its part goes with the one before)
	testing.expectf(t, len(parts) == 3 && parts[0] == {0, 1} && parts[1] == {1, 3} && parts[2] == {3, 0}, "the parts: %v", parts)
	testing.expect(t, inner_at >= 0 && rest_at > inner_at, "the part after the foreign object comes after its content")
	testing.expect(t, .Clips in f.l.boxes[sv].flags, "an inline <svg> clips what it holds (overflow: hidden)")
}

// Clips of the bounding box, two clips intersected, a foreign object in a nested <svg>.
@(test)
foreign_object_clips_nested :: proc(t: ^testing.T) {
	f := fixture_load(`<body style="margin:0"><svg id=svg style="display:block" width="100" height="100">
<clipPath id=bb clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
<clipPath id=half><rect width="100" height="30"/></clipPath>
<foreignObject id=a x="10" y="10" width="40" height="40" clip-path="url(#bb)"></foreignObject>
<g clip-path="url(#half)"><foreignObject id=b width="100" height="100" clip-path="url(#bb)"></foreignObject></g>
<svg x="50" y="50" width="40" height="40" viewBox="0 0 20 20"><foreignObject id=c width="10" height="10"></foreignObject></svg>
</svg></body>`)
	defer fixture_unload(f)
	a, b, c := bx(f, "a"), bx(f, "b"), bx(f, "c")
	if !testing.expect(t, a != NONE && b != NONE && c != NONE) { return }
	sa := clip_path_shape(&f.l, a)
	pa := f.l.boxes[a].abs
	testing.expect(t, clip_shape_contains(sa, pa + {15, 20}) && !clip_shape_contains(sa, pa + {25, 20}), "objectBoundingBox: the left half of its own box")
	sb := clip_path_shape(&f.l, b)
	pb := f.l.boxes[b].abs
	testing.expect(t, clip_shape_contains(sb, pb + {40, 20}) && !clip_shape_contains(sb, pb + {40, 40}) && !clip_shape_contains(sb, pb + {60, 20}), "its clip and its group's: the top left")
	cb := &f.l.boxes[c]
	m := box_matrix(&f.l, cb)
	top := content_rect(&f.l.boxes[bx(f, "svg")]).min
	testing.expectf(t, near(mat_apply(m, cb.abs), top + {50, 50}) && near(mat_apply(m, cb.abs + {10, 10}), top + {70, 70}), "the nested viewport: x / y and its viewBox: %v", m)
}
