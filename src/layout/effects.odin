package layout

import "core:math"
import "wb:style"

// Effect groups (CSS Filter Effects 1 and 2, Compositing 1, Masking 1) in layout: which boxes paint through a group,
// how far their filters spread what they paint (layer zones, culling), the geometry of clip-path shapes (painting and
// hit testing).
//
// Every effect makes a stacking context, so the items of a group are contiguous in paint order. A blending element
// blends with what its stacking context painted before it, and with nothing behind that context: stacking contexts
// are isolated groups (Compositing 1 §3.2). The stacking context around a blending element therefore gets a group of
// its own (`.Isolate`), painted in a layer; the root stacking context blends with the canvas directly.

Group_Effect :: enum u8 {
	Opacity,      // opacity below 1
	Filter,       // filter: a list (functions that change nothing are skipped by the painter)
	Backdrop,     // backdrop-filter
	Blend,        // mix-blend-mode other than normal
	Isolate,      // an isolated group for blending descendants
	Clip_Path,    // clip-path other than none
	Mask,         // a mask-image layer with an image
}
Group_Effects :: bit_set[Group_Effect; u8]

// The effects of a style that need a group. Their presence is structural (style.structure_sig): it only changes
// with a full layout.
box_effects :: proc(cs: ^style.Computed) -> Group_Effects {
	if cs == nil { return {} }
	fx: Group_Effects
	if cs.opacity < 1 { fx += {.Opacity} }
	if len(cs.filter) > 0 { fx += {.Filter} }
	if len(cs.backdrop_filter) > 0 { fx += {.Backdrop} }
	if cs.mix_blend_mode != .Normal { fx += {.Blend} }
	if cs.clip_path != nil { fx += {.Clip_Path} }
	if style.has_mask(cs) { fx += {.Mask} }
	return fx
}

// Boxes whose stacking context must be painted as an isolated group: the nearest stacking-context ancestor of each
// blending box, unless that is the root stacking context.
@(private)
isolated_contexts :: proc(l: ^Layout) -> []bool {
	out := make([]bool, len(l.boxes), context.temp_allocator)
	root_el := len(l.boxes) > 0 ? l.boxes[0].first : NONE
	for &b in l.boxes {
		// dead boxes (left by partial rebuilds) keep a stale style pointer
		if .Blends not_in b.flags || .Dead in b.flags || b.cs == nil || b.cs.mix_blend_mode == .Normal || .Root in b.flags { continue }
		for p := b.parent; p != NONE; p = l.boxes[p].parent {
			pb := &l.boxes[p]
			if .Root in pb.flags || p == root_el { break }
			if .Stacking in pb.flags { out[p] = true; break }
		}
	}
	return out
}

// How far a filter list spreads what it filters, in device px of the box's own space: left, top, right, bottom.
// blur() reaches three standard deviations; drop-shadow() its offset plus three standard deviations of its blur
// (half the blur radius, as box-shadow).
filter_outset :: proc(filters: []style.Filter_Op, scale: f32) -> [4]f32 {
	o: [4]f32
	for f in filters {
		#partial switch f.kind {
		case .Blur:
			o += math.ceil(3 * max(f.v, 0) * scale)
		case .Drop_Shadow:
			if f.shadow.color.a <= 0 { continue }
			e := math.ceil(1.5 * max(f.shadow.blur, 0) * scale)
			dx, dy := f.shadow.x * scale, f.shadow.y * scale
			o = {max(o[0], o[0] + e - dx), max(o[1], o[1] + e - dy), max(o[2], o[2] + e + dx), max(o[3], o[3] + e + dy)}
		}
	}
	return o
}

// The reach of every group: its own filter outset (largest side) plus that of the groups around it.
@(private)
groups_reach :: proc(l: ^Layout) {
	for &g, i in l.groups {
		own: f32
		if .Filter in g.effects {
			o := filter_outset(l.boxes[g.box].cs.filter, l.scale)
			own = max(o[0], o[1], o[2], o[3])
		}
		g.reach = own + (g.parent != NONE && int(g.parent) < i ? l.groups[g.parent].reach : 0)
	}
}

////////////////////////////////
// clip-path (CSS Masking 1 §5)

Clip_Shape_Kind :: enum u8 { None, Rect, Ellipse, Polygon }

// A resolved clip-path, in layout coordinates of the box's own space (device px, before scrolling and transforms).
Clip_Shape :: struct {
	kind:    Clip_Shape_Kind,
	rect:    Rect,           // Rect: inset() or a reference box alone
	radii:   [4]f32,         // Rect: corners in draw order (top-left, bottom-left, top-right, bottom-right)
	center:  Vec2,           // Ellipse (a circle has equal radii)
	radius:  Vec2,
	points:  []Vec2,         // Polygon
	evenodd: bool,
}

// The reference box of a clip-path (<geometry-box>; SVG boxes map to the CSS ones as for HTML elements) with its
// corner radii.
@(private)
reference_box :: proc(l: ^Layout, b: ^Box, gb: style.Geometry_Box) -> (r: Rect, radii: [4]f32) {
	border := border_rect(b)
	outer := border_radii(b.cs, border.max.x - border.min.x, border.max.y - border.min.y, l.scale)
	bt, br, bb, bl := b.border[0], b.border[1], b.border[2], b.border[3]
	pt, pr, pb, pl := b.padding[0], b.padding[1], b.padding[2], b.padding[3]
	shrink :: proc(o: [4]f32, l, t, r, b: f32) -> [4]f32 {
		return {max(o[0] - min(l, t), 0), max(o[1] - min(l, b), 0), max(o[2] - min(r, t), 0), max(o[3] - min(r, b), 0)}
	}
	switch gb {
	case .Border_Box, .Stroke_Box, .View_Box:
		return border, outer
	case .Padding_Box:
		return Rect{border.min + {bl, bt}, border.max - {br, bb}}, shrink(outer, bl, bt, br, bb)
	case .Content_Box, .Fill_Box:
		return Rect{border.min + {bl + pl, bt + pt}, border.max - {br + pr, bb + pb}}, shrink(outer, bl + pl, bt + pt, br + pr, bb + pb)
	case .Margin_Box:
		m := b.margin
		grow :: proc(o: [4]f32, l, t, r, b: f32) -> [4]f32 {
			return {o[0] > 0 ? o[0] + max(l, t) : 0, o[1] > 0 ? o[1] + max(l, b) : 0, o[2] > 0 ? o[2] + max(r, t) : 0, o[3] > 0 ? o[3] + max(r, b) : 0}
		}
		return Rect{border.min - {m[3], m[0]}, border.max + {m[1], m[2]}}, grow(outer, m[3], m[0], m[1], m[2])
	}
	return border, outer
}

// The clip-path of box `bi` resolved against its reference box. None: no clip (none, or url(), which needs SVG).
// Polygon points are allocated with `allocator`.
clip_path_shape :: proc(l: ^Layout, bi: i32, allocator := context.temp_allocator) -> Clip_Shape {
	if bi < 0 || int(bi) >= len(l.boxes) { return {} }
	b := &l.boxes[bi]
	cs := b.cs
	if cs == nil || cs.clip_path == nil { return {} }
	cp := cs.clip_path
	s := l.scale > 0 ? l.scale : 1
	ref, ref_radii := reference_box(l, b, cp.box)
	w, h := max(ref.max.x - ref.min.x, 0), max(ref.max.y - ref.min.y, 0)
	// lengths are CSS px, percentages of a reference size in device px
	res :: proc(v: style.Length, base, s: f32) -> f32 { return style.resolve(v, base / s) * s }
	switch cp.kind {
	case .None, .Url: return {}
	case .Box:
		return Clip_Shape{kind = .Rect, rect = ref, radii = ref_radii}
	case .Inset:
		t := res(cp.inset[.Top], h, s)
		r := res(cp.inset[.Right], w, s)
		bo := res(cp.inset[.Bottom], h, s)
		le := res(cp.inset[.Left], w, s)
		rect := Rect{ref.min + {le, t}, ref.max - {r, bo}}
		// insets that cross collapse to an empty rect at their meeting point (CSS Shapes §3.1)
		if rect.max.x < rect.min.x { mid := (rect.min.x + rect.max.x) * 0.5; rect.min.x, rect.max.x = mid, mid }
		if rect.max.y < rect.min.y { mid := (rect.min.y + rect.max.y) * 0.5; rect.min.y, rect.max.y = mid, mid }
		rw, rh := rect.max.x - rect.min.x, rect.max.y - rect.min.y
		rad :: proc(cr: style.Corner_Radius, w, h, s: f32) -> f32 {
			hv := style.resolve(cr.h, w / s) * s
			vv := cr.v.kind == .Auto ? hv : style.resolve(cr.v, h / s) * s
			return max(min(hv, vv), 0)
		}
		tl := rad(cp.round[.Top_Left], rw, rh, s)
		tr := rad(cp.round[.Top_Right], rw, rh, s)
		br := rad(cp.round[.Bottom_Right], rw, rh, s)
		bl := rad(cp.round[.Bottom_Left], rw, rh, s)
		f: f32 = 1
		if tl + tr > rw && rw > 0 { f = min(f, rw / (tl + tr)) }
		if bl + br > rw && rw > 0 { f = min(f, rw / (bl + br)) }
		if tl + bl > rh && rh > 0 { f = min(f, rh / (tl + bl)) }
		if tr + br > rh && rh > 0 { f = min(f, rh / (tr + br)) }
		return Clip_Shape{kind = .Rect, rect = rect, radii = {tl * f, bl * f, tr * f, br * f}}
	case .Circle, .Ellipse:
		c := ref.min + {res(cp.center[0], w, s), res(cp.center[1], h, s)}
		dl, dr, dt, db := abs(c.x - ref.min.x), abs(ref.max.x - c.x), abs(c.y - ref.min.y), abs(ref.max.y - c.y)
		side :: proc(e: style.Radial_Extent, a, b: f32) -> f32 { return e == .Farthest_Side ? max(a, b) : min(a, b) }
		rad: Vec2
		if cp.kind == .Circle {
			switch cp.extent[0] {
			case .Explicit:
				rad.x = res(cp.radius[0], math.sqrt(w * w + h * h) / math.SQRT_TWO, s)
			case .Farthest_Side, .Farthest_Corner:
				rad.x = max(dl, dr, dt, db)
			case .Closest_Side, .Closest_Corner:
				rad.x = min(dl, dr, dt, db)
			}
			rad.y = rad.x
		} else {
			rad.x = cp.extent[0] == .Explicit ? res(cp.radius[0], w, s) : side(cp.extent[0], dl, dr)
			rad.y = cp.extent[1] == .Explicit ? res(cp.radius[1], h, s) : side(cp.extent[1], dt, db)
		}
		return Clip_Shape{kind = .Ellipse, center = c, radius = {max(rad.x, 0), max(rad.y, 0)}}
	case .Polygon:
		pts := make([]Vec2, len(cp.points), allocator)
		for p, i in cp.points { pts[i] = ref.min + {res(p[0], w, s), res(p[1], h, s)} }
		return Clip_Shape{kind = .Polygon, points = pts, evenodd = cp.evenodd}
	}
	return {}
}

// Bounds of a clip shape (layout coordinates of its space).
clip_shape_bounds :: proc(sh: Clip_Shape) -> Rect {
	switch sh.kind {
	case .None: return {}
	case .Rect: return sh.rect
	case .Ellipse: return Rect{sh.center - sh.radius, sh.center + sh.radius}
	case .Polygon:
		if len(sh.points) == 0 { return {} }
		r := Rect{sh.points[0], sh.points[0]}
		for p in sh.points { r = Rect{{min(r.min.x, p.x), min(r.min.y, p.y)}, {max(r.max.x, p.x), max(r.max.y, p.y)}} }
		return r
	}
	return {}
}

// Is `p` (layout coordinates of the shape's space) inside the shape? A polygon follows its fill rule.
clip_shape_contains :: proc(sh: Clip_Shape, p: Vec2) -> bool {
	switch sh.kind {
	case .None: return true
	case .Rect: return rounded_contains(sh.rect, sh.radii, p)
	case .Ellipse:
		if sh.radius.x <= 0 || sh.radius.y <= 0 { return false }
		d := (p - sh.center) / sh.radius
		return d.x * d.x + d.y * d.y <= 1
	case .Polygon:
		n := len(sh.points)
		if n < 3 { return false }
		winding := 0
		a := sh.points[n - 1]
		for bp in sh.points {
			side := (bp.x - a.x) * (p.y - a.y) - (bp.y - a.y) * (p.x - a.x)
			if a.y <= p.y {
				if bp.y > p.y && side > 0 { winding += 1 }
			} else if bp.y <= p.y && side < 0 { winding -= 1 }
			a = bp
		}
		return sh.evenodd ? winding % 2 != 0 : winding != 0
	}
	return true
}

// Does the viewport point `p` survive the clip-paths of group `g` and of the groups around it? (A point outside an
// element's clip-path does not hit it or its descendants.)
group_clips_contain :: proc(l: ^Layout, v: ^View, g: i32, p: Vec2) -> bool {
	for cur := g; cur != NONE; cur = l.groups[cur].parent {
		gr := &l.groups[cur]
		if .Clip_Path not_in gr.effects { continue }
		sh := clip_path_shape(l, gr.box)
		if sh.kind == .None { continue }
		q, ok := view_to_local(l, v, l.boxes[gr.box].space, p)
		if !ok || !clip_shape_contains(sh, q) { return false }
	}
	return true
}
