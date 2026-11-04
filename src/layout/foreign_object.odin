package layout

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:canvas2d"
import "wb:dom"
import "wb:style"

// <foreignObject> in an inline <svg> (SVG 2 §23.2): the HTML inside is laid out and painted by this layout, in the
// SVG's coordinate space. The <svg> is a replaced box whose picture (page/inline_svg.odin) leaves its foreign objects
// out; each one in its own viewport (not inside a nested <svg>, nor in <defs>, a <clipPath>, a <mask>... that are not
// drawn) becomes an absolutely positioned child of that box, with the style its element has and what SVG says of it:
//   * a block of its width and height (user units), its overflow clipped (the UA style of SVG 2 §6.4);
//   * a transform: the viewBox mapping of the <svg> box's content box (preserveAspectRatio), the transform attributes
//     of its ancestors and its own, then its x and y (box_matrix asks foreign_matrix, once the <svg> is laid out);
//   * the clip-path url(#id) of the nearest of it and its ancestors that has one, a <clipPath> in user space whose shapes
//     become one polygon in its own coordinates (clip-rule evenodd if a shape asks for it);
//   * its filters, and the url(#id) filters of it and its ancestors made of feGaussianBlur alone, as one blur();
//   * the opacity of its ancestors.
// What it is made from stays in Layout.foreign_objects: a restyle of the element makes its style again in place (foreign_restyle).
// Changes inside the <svg> other than in the foreign objects' content take a full pass (incremental.odin add_target,
// foreign_attribute_changed). Left: a foreign object that shapes drawn after it should cover (it paints over the whole
// picture), objectBoundingBox clip units, filters other than blurs, more than one clip.

// How far a clip's polygon may stray from its curves, in the foreign object's units (a 24-unit icon shown at 240 px:
// a tenth of a pixel).
FOREIGN_CLIP_TOLERANCE :: 0.01
// Most points one clip's polygon keeps.
FOREIGN_CLIP_MAX_POINTS :: 20000

Foreign_Align :: enum u8 { None, Min, Mid, Max }

// One foreign object of the layout (Layout.foreign_objects).
Foreign_Object :: struct {
	box, svg:  i32,                   // its box, the <svg>'s
	base:      ^style.Computed,       // the element's record its style was made from
	cs:        ^style.Computed,       // that style (in the layout's arena), with its own transform and rare groups
	transform: ^style.Transform_Group,
	rare:      ^style.Rare_Group,
	ops:       []style.Transform_Op,  // the identity, so that the box is transformed (foreign_matrix gives the matrix)
	filter:    []style.Filter_Op,
	clip:      ^style.Clip_Path,      // nil: none
	size:      Vec2,                  // width, height (user units)
	user:      Matrix,                // its coordinates to the <svg>'s user space
	view_box:  [4]f32,                // the <svg>'s viewBox (width 0: none)
	align:     [2]Foreign_Align,      // preserveAspectRatio (None: stretched)
	slice:     bool,
	opacity:   f32,                   // of its ancestors in the <svg>
}

// The <svg> of box `svg` (just placed, with frame `g`): a frame for each of its foreign objects, in document order.
@(private)
foreign_frames :: proc(c: ^Ctx, stack: ^[dynamic]Frame, svg: i32, g: Frame) {
	root := c.l.boxes[svg].node
	found := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	walk := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	n := dom.get(c.d, root)
	for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev { append(&walk, ch) }
	for len(walk) > 0 {
		h := pop(&walk)
		x := dom.get(c.d, h)
		if x == nil || x.kind != .Element { continue }
		if x.name == "foreignobject" { append(&found, h); continue }
		if !foreign_drawn_container(x.name) { continue }
		for ch := x.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev { append(&walk, ch) }
	}
	sb := &c.l.boxes[svg]
	for i := len(found) - 1; i >= 0; i -= 1 {
		append(stack, Frame{kind = .Foreign, node = found[i], parent = svg, mode = .Block, cb = svg, fcb = g.fcb, depth = sb.depth,
			ifc = NONE, deco_box = NONE, font_el = root, fi = sb.fi})
	}
}

// Elements whose children are drawn where they are (the others hold what is referenced, or a viewport of its own).
@(private = "file")
foreign_drawn_container :: proc(name: string) -> bool {
	switch name {
	case "g", "a", "switch": return true
	}
	return false
}

// The box of a foreign object (a Foreign frame): its style made, then placed as an element's.
@(private)
visit_foreign :: proc(c: ^Ctx, stack: ^[dynamic]Frame, f: Frame) {
	n := dom.get(c.d, f.node)
	el := style.style_of(c.st, f.node)
	if n == nil || el == nil || el.display == .None { return }
	fo, ok := foreign_make(c, f.node, f.parent, el)
	if !ok { return }
	bi := i32(len(c.l.boxes))
	place_element(c, stack, f, f.node, n, fo.cs, false, false)
	if bi >= i32(len(c.l.boxes)) || c.l.boxes[bi].node != f.node { return }
	c.l.boxes[bi].flags += {.Foreign}
	fo.box = bi
	append(&c.l.foreign_objects, fo)
}

// What SVG makes of foreign object `h` of the <svg> box `svg`. false: it draws nothing (no size, hidden by an
// ancestor, in a nested viewport).
@(private = "file")
foreign_make :: proc(c: ^Ctx, h: base.Handle, svg: i32, el: ^style.Computed) -> (fo: Foreign_Object, ok: bool) {
	d := c.d
	root := c.l.boxes[svg].node
	vb, has_vb := view_box_of(d, root)
	if has_vb { fo.view_box = vb }
	fo.align, fo.slice = aspect_of(d, root)
	ref := has_vb ? Vec2{vb[2], vb[3]} : Vec2{}
	x := length_attr(d, h, "x", ref.x)
	y := length_attr(d, h, "y", ref.y)
	fo.size = {length_attr(d, h, "width", ref.x), length_attr(d, h, "height", ref.y)}
	if fo.size.x <= 0 || fo.size.y <= 0 { return }

	// up to the <svg>: transforms, the nearest clip, blurs, opacity
	m := mat_translate({x, y})   // its coordinates to the user space of the element being looked at
	sigma2: f32
	fo.opacity = 1
	clip_from: base.Handle
	clip_m: Matrix
	for cur := h; cur != root; {
		cn := dom.get(d, cur)
		if cn == nil { return }
		cs := style.style_of(c.st, cur)
		if cs == nil || cs.display == .None { return }
		if cur != h {
			if !foreign_drawn_container(cn.name) { return }
			fo.opacity *= cs.opacity
		}
		// (a clip and a filter are in the element's user space: inside its own transform)
		if clip_from == base.NIL_HANDLE {
			if id := ref_id(d, cur, "clip-path", cs.clip_path != nil && cs.clip_path.kind == .Url ? cs.clip_path.url : ""); id != "" {
				clip_from, clip_m = dom.find_by_id(d, id), m
			}
		}
		filter_url := ""
		for op in cs.filter { if op.kind == .Url { filter_url = op.url } }
		if id := ref_id(d, cur, "filter", filter_url); id != "" {
			if s, blur := blur_of(d, dom.find_by_id(d, id)); blur {
				k := math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))
				if k > 0 { sigma2 += (s / k) * (s / k) }
			}
		}
		if t, has := dom.get_attribute(d, cur, "transform"); has { m = mat_mul(svg_transform(t), m) }
		cur = cn.parent
		if cur == base.NIL_HANDLE { return }
	}
	fo.user = m

	a := c.sa
	fo.svg, fo.base = svg, el
	fo.cs = new(style.Computed, a)
	fo.transform = new(style.Transform_Group, a)
	fo.rare = new(style.Rare_Group, a)
	fo.ops = make([]style.Transform_Op, 1, a)
	fo.ops[0] = style.Transform_Op{kind = .Matrix, v = {1, 0, 0, 1, 0, 0}}
	filters := make([dynamic]style.Filter_Op, 0, len(el.filter) + 1, a)
	for op in el.filter { if op.kind != .Url { append(&filters, op) } }
	if sigma2 > 0 { append(&filters, style.Filter_Op{kind = .Blur, v = math.sqrt(sigma2)}) }
	fo.filter = filters[:]
	if clip_from != base.NIL_HANDLE {
		if inv, inv_ok := mat_inverse(clip_m); inv_ok { fo.clip = clip_polygon(c, clip_from, inv) }
	}
	foreign_style(&fo, el)
	return fo, true
}

// The style of a foreign object made again from its element's record `el`, in place.
@(private = "file")
foreign_style :: proc(fo: ^Foreign_Object, el: ^style.Computed) {
	cs := fo.cs
	cs^ = el^
	fo.base = el
	cs.display, cs.position, cs.float = .Block, .Absolute, .None
	cs.inset = {.Top = style.px(0), .Left = style.px(0), .Right = {}, .Bottom = {}}
	cs.width, cs.height = style.px(fo.size.x), style.px(fo.size.y)
	cs.min_width, cs.min_height = {}, {}
	cs.max_width, cs.max_height = {kind = .None}, {kind = .None}
	for &m in cs.margin { m = style.px(0) }
	cs.box_sizing = .Border_Box
	cs.overflow_x, cs.overflow_y = .Clip, .Clip
	cs.opacity = el.opacity * fo.opacity
	fo.transform^ = el.transform_group^
	fo.transform.transform = fo.ops
	fo.transform.transform_origin = {style.px(0), style.px(0)}
	fo.transform.transform_box = .Border_Box
	fo.transform.translate, fo.transform.rotate, fo.transform.scale = {}, {}, {}
	cs.transform_group = fo.transform
	fo.rare^ = el.rare_group^
	fo.rare.filter = fo.filter
	fo.rare.clip_path = fo.clip
	fo.rare.clip = nil
	cs.rare_group = fo.rare
	cs.before, cs.after, cs.backdrop = nil, nil, nil
}

// The style box `bi` (a foreign object) has for its element's record `el` now: its own, made again in place (an
// animation rewrites a record without replacing it), the same record. `moved`: `el` is another record than before.
@(private)
foreign_restyle :: proc(l: ^Layout, bi: i32, el: ^style.Computed) -> (cs: ^style.Computed, moved: bool) {
	for &fo in l.foreign_objects {
		if fo.box != bi { continue }
		moved = fo.base != el
		foreign_style(&fo, el)
		return fo.cs, moved
	}
	return el, true
}

// The transformation of foreign object box `b` in layout coordinates (device px): from its border box, where it was
// placed, to the <svg>'s viewport.
@(private)
foreign_matrix :: proc(l: ^Layout, b: ^Box) -> Matrix {
	for &fo in l.foreign_objects {
		if &l.boxes[fo.box] != b { continue }
		s := l.scale > 0 ? l.scale : 1
		port := content_rect(&l.boxes[fo.svg])
		m := mat_mul(view_box_matrix(&fo, (port.max - port.min) / s), fo.user)
		// q (layout) -> its own units (q - abs) / s -> the viewport's CSS px -> layout
		a := b.abs
		return Matrix{m[0], m[1], m[2], m[3], port.min.x + s * m[4] - (m[0] * a.x + m[2] * a.y), port.min.y + s * m[5] - (m[1] * a.x + m[3] * a.y)}
	}
	return IDENTITY
}

// The <svg>'s user space to its viewport of `port` CSS px (SVG 2 §8.2 "viewBox to viewport transformation").
@(private = "file")
view_box_matrix :: proc(fo: ^Foreign_Object, port: Vec2) -> Matrix {
	vb := fo.view_box
	if vb[2] <= 0 || vb[3] <= 0 { return IDENTITY }
	sx, sy := port.x / vb[2], port.y / vb[3]
	if fo.align.x != .None {
		k := fo.slice ? max(sx, sy) : min(sx, sy)
		sx, sy = k, k
	}
	shift :: proc(a: Foreign_Align, free: f32) -> f32 {
		#partial switch a {
		case .Mid: return free / 2
		case .Max: return free
		}
		return 0
	}
	tx := shift(fo.align.x, port.x - vb[2] * sx) - vb[0] * sx
	ty := shift(fo.align.y, port.y - vb[3] * sy) - vb[1] * sy
	return Matrix{sx, 0, 0, sy, tx, ty}
}

// A change of an attribute of element `h`: true when it is in an <svg> with foreign objects and not in their content
// (their geometry, their clip or their transforms may follow from it).
@(private)
foreign_attribute_changed :: proc(c: ^Ctx, h: base.Handle) -> bool {
	if len(c.l.foreign_objects) == 0 { return false }
	for cur := h; cur != base.NIL_HANDLE; cur = up(c, cur) {
		if bi := live_box(c.l, cur); bi != NONE {
			b := &c.l.boxes[bi]
			return (b.kind == .Replaced && b.first != NONE) || .Foreign in b.flags
		}
	}
	return false
}

////////////////////////////////
// SVG attributes

// The id an attribute or a computed url() references: `url(#id)`, the computed value first.
@(private = "file")
ref_id :: proc(d: ^dom.Document, h: base.Handle, attr, computed: string) -> string {
	v := computed
	if v == "" {
		a, ok := dom.get_attribute(d, h, attr)
		if !ok { return "" }
		t := strings.trim_space(a)
		if !base.ascii_has_prefix_fold(t, "url(") || !strings.has_suffix(t, ")") { return "" }
		v = strings.trim(strings.trim_space(t[4:len(t) - 1]), "\"'")
	}
	return strings.has_prefix(v, "#") ? v[1:] : ""
}

// The standard deviation of a <filter> made of feGaussianBlur primitives alone (their deviations combined); false:
// another filter.
@(private = "file")
blur_of :: proc(d: ^dom.Document, h: base.Handle) -> (sigma: f32, ok: bool) {
	n := dom.get(d, h)
	if n == nil || n.kind != .Element || n.name != "filter" { return }
	s2: f32
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		x := dom.get(d, ch)
		if x.kind != .Element { continue }
		if x.name != "fegaussianblur" { return 0, false }
		v, _ := dom.get_attribute(d, ch, "stddeviation")
		r := canvas2d.Svg_Reader{s = v}
		sx, okx := canvas2d.svg_number(&r)
		sy, oky := canvas2d.svg_number(&r)
		if !okx { continue }
		if !oky { sy = sx }
		s := f32(max(sx, sy, 0))
		s2 += s * s
	}
	return math.sqrt(s2), s2 > 0
}

// A length attribute in user units (a number, px, or a percentage of `ref`); 0 when missing or invalid.
@(private = "file")
length_attr :: proc(d: ^dom.Document, h: base.Handle, name: string, ref: f32) -> f32 {
	v, ok := dom.get_attribute(d, h, name)
	if !ok { return 0 }
	t := strings.trim_space(v)
	if strings.has_suffix(t, "%") {
		p, pok := strconv.parse_f32(t[:len(t) - 1])
		return pok ? p * ref / 100 : 0
	}
	if base.ascii_has_suffix_fold(t, "px") { t = t[:len(t) - 2] }
	n, nok := strconv.parse_f32(t)
	return nok ? n : 0
}

@(private = "file")
view_box_of :: proc(d: ^dom.Document, h: base.Handle) -> (vb: [4]f32, ok: bool) {
	v, has := dom.get_attribute(d, h, "viewbox")
	if !has { return }
	r := canvas2d.Svg_Reader{s = v}
	for i in 0 ..< 4 {
		x, xok := canvas2d.svg_number(&r)
		if !xok { return {}, false }
		vb[i] = f32(x)
	}
	return vb, vb[2] > 0 && vb[3] > 0
}

// preserveAspectRatio: the alignment on each axis (None: none, stretched) and meet or slice.
@(private = "file")
aspect_of :: proc(d: ^dom.Document, h: base.Handle) -> (align: [2]Foreign_Align, slice: bool) {
	align = {.Mid, .Mid}
	v, has := dom.get_attribute(d, h, "preserveaspectratio")
	if !has { return }
	words := strings.fields(v, context.temp_allocator)
	if len(words) == 0 { return }
	a := words[0]
	if a == "none" { return {.None, .None}, false }
	pick :: proc(s: string) -> Foreign_Align {
		switch s {
		case "Min", "min": return .Min
		case "Max", "max": return .Max
		}
		return .Mid
	}
	if len(a) == 8 && a[0] == 'x' && a[4] == 'Y' { align = {pick(a[1:4]), pick(a[5:8])} }
	slice = len(words) > 1 && words[1] == "slice"
	return
}

// An SVG transform list (SVG 2 §8.5): matrix, translate, scale, rotate (about a point), skewX, skewY. An error ends the
// list (the identity from there, as browsers do for the whole list: here what came before stays).
@(private = "file")
svg_transform :: proc(s: string) -> Matrix {
	m := IDENTITY
	r := canvas2d.Svg_Reader{s = s}
	for {
		canvas2d.svg_skip(&r, true)
		start := r.i
		for r.i < len(r.s) && ((r.s[r.i] >= 'a' && r.s[r.i] <= 'z') || (r.s[r.i] >= 'A' && r.s[r.i] <= 'Z')) { r.i += 1 }
		name := r.s[start:r.i]
		if name == "" { return m }
		canvas2d.svg_skip(&r, false)
		if r.i >= len(r.s) || r.s[r.i] != '(' { return m }
		r.i += 1
		args: [6]f32
		n := 0
		for n < len(args) {
			v, ok := canvas2d.svg_number(&r)
			if !ok { break }
			args[n] = f32(v)
			n += 1
		}
		canvas2d.svg_skip(&r, false)
		if r.i >= len(r.s) || r.s[r.i] != ')' { return m }
		r.i += 1
		t: Matrix
		switch name {
		case "matrix":
			if n != 6 { return m }
			t = Matrix{args[0], args[1], args[2], args[3], args[4], args[5]}
		case "translate":
			if n != 1 && n != 2 { return m }
			t = mat_translate({args[0], n == 2 ? args[1] : 0})
		case "scale":
			if n != 1 && n != 2 { return m }
			t = Matrix{args[0], 0, 0, n == 2 ? args[1] : args[0], 0, 0}
		case "rotate":
			if n != 1 && n != 3 { return m }
			rad := args[0] * math.PI / 180
			sn, cn := math.sin(rad), math.cos(rad)
			t = Matrix{cn, sn, -sn, cn, 0, 0}
			if n == 3 { t = mat_mul(mat_translate({args[1], args[2]}), mat_mul(t, mat_translate({-args[1], -args[2]}))) }
		case "skewX":
			if n != 1 { return m }
			t = Matrix{1, 0, math.tan(args[0] * math.PI / 180), 1, 0, 0}
		case "skewY":
			if n != 1 { return m }
			t = Matrix{1, math.tan(args[0] * math.PI / 180), 0, 1, 0, 0}
		case: return m
		}
		m = mat_mul(m, t)
	}
}

// The shapes of <clipPath> `h` (user space units) as one polygon in the foreign object's coordinates (`to_local`: from
// the clipped element's user space). Subpaths are joined through their first point and back, which adds nothing under
// either fill rule. nil: no clip that can be made (objectBoundingBox units, nothing in it: then nothing is drawn).
@(private = "file")
clip_polygon :: proc(c: ^Ctx, h: base.Handle, to_local: Matrix) -> ^style.Clip_Path {
	d := c.d
	n := dom.get(d, h)
	if n == nil || n.kind != .Element || n.name != "clippath" { return nil }
	if u, ok := dom.get_attribute(d, h, "clippathunits"); ok && strings.trim_space(u) == "objectBoundingBox" { return nil }
	base_m := to_local
	if t, ok := dom.get_attribute(d, h, "transform"); ok { base_m = mat_mul(base_m, svg_transform(t)) }
	flat: canvas2d.Flat
	flat.pts = make([dynamic][2]f64, 0, 64, context.temp_allocator)
	flat.subs = make([dynamic]canvas2d.Subpath, 0, 4, context.temp_allocator)
	evenodd := false
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		x := dom.get(d, ch)
		if x.kind != .Element { continue }
		p: canvas2d.Path
		p.verbs = make([dynamic]canvas2d.Verb, 0, 16, context.temp_allocator)
		p.pts = make([dynamic][2]f64, 0, 32, context.temp_allocator)
		num :: proc(d: ^dom.Document, h: base.Handle, name: string) -> f64 { return f64(length_attr(d, h, name, 0)) }
		switch x.name {
		case "path":
			if v, ok := dom.get_attribute(d, ch, "d"); ok { canvas2d.path_add_svg(&p, v) }
		case "rect":
			canvas2d.path_rect(&p, canvas2d.IDENTITY, num(d, ch, "x"), num(d, ch, "y"), num(d, ch, "width"), num(d, ch, "height"))
		case "circle":
			r := num(d, ch, "r")
			_ = canvas2d.path_ellipse(&p, canvas2d.IDENTITY, num(d, ch, "cx"), num(d, ch, "cy"), r, r, 0, 0, math.TAU, false)
		case "ellipse":
			_ = canvas2d.path_ellipse(&p, canvas2d.IDENTITY, num(d, ch, "cx"), num(d, ch, "cy"), num(d, ch, "rx"), num(d, ch, "ry"), 0, 0, math.TAU, false)
		case "polygon", "polyline":
			if v, ok := dom.get_attribute(d, ch, "points"); ok { canvas2d.path_add_svg(&p, fmt.tprintf("M%sZ", v)) }
		case: continue
		}
		if v, ok := dom.get_attribute(d, ch, "clip-rule"); ok && strings.trim_space(v) == "evenodd" { evenodd = true }
		if cs := style.style_of(c.st, ch); cs != nil && cs.display == .None { continue }
		m := base_m
		if t, ok := dom.get_attribute(d, ch, "transform"); ok { m = mat_mul(m, svg_transform(t)) }
		canvas2d.path_flatten(&p, canvas2d.Matrix{f64(m[0]), f64(m[1]), f64(m[2]), f64(m[3]), f64(m[4]), f64(m[5])}, FOREIGN_CLIP_TOLERANCE, &flat)
	}
	cp := new(style.Clip_Path, c.sa)
	cp.kind, cp.box, cp.evenodd = .Polygon, .Border_Box, evenodd
	pts := make([dynamic][2]style.Length, 0, len(flat.pts) + 2 * len(flat.subs), c.sa)
	pt :: proc(q: [2]f64) -> [2]style.Length { return {style.px(f32(q.x)), style.px(f32(q.y))} }
	for s in flat.subs {
		if s.end - s.start < 3 { continue }
		for i in s.start ..< s.end { append(&pts, pt(flat.pts[i])) }
		append(&pts, pt(flat.pts[s.start]))
		if len(pts) > s.end - s.start + 1 { append(&pts, pts[0]) }   // back to the first subpath's start
		if len(pts) > FOREIGN_CLIP_MAX_POINTS { break }
	}
	if len(pts) == 0 {
		// nothing to draw in: an empty polygon
		append(&pts, pt({0, 0}), pt({0, 0}), pt({0, 0}))
	}
	cp.points = pts[:]
	return cp
}
