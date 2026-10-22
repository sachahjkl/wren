package layout

import "core:math"
import "wb:style"

// CSS Transforms 2 in layout: planes.
//
// A box with a 3D transform (or transform-style: preserve-3d, or backface-visibility: hidden in a 3D context) is a plane
// (Box_Flag.Plane): its Transform space is flagged `proj`, and its box and everything under it up to nested planes are
// drawn offscreen in the plane's own frame, then projected onto what receives them. The frame of a plane is its layout
// coordinates plus the offsets (scroll, sticky) that apply to it: the same frame the 2D matrices of its space work in.
//
// Inside a plane, `View.mats` of a space is the product of the 2D transforms between the plane and the space (the plane's
// own is not in it: it is the projection), so painting a plane's content needs nothing but those. A plane is projected by
// its `View.accs` entry: plane frame -> the frame of what receives it (the page, or another plane's layer), a 4x4:
//
//     acc = [base] * persp(A) * shift(mat4)
//
// with A the nearest transformed ancestor, persp(A) the perspective of its `perspective` property, and `base` what A adds
// when it is not a flattening boundary: the 2D matrix of a plain transformed ancestor (a "carrier"), or, for the members
// of a preserve-3d context, the projection of the ancestor plane (so that the whole context is projected at once, in one
// space, and its planes can be sorted by depth).

@(private)
used_preserve_3d :: proc(cs: ^style.Computed) -> bool {
	if cs == nil || cs.transform_style != .Preserve_3d { return false }
	// grouping properties flatten (CSS Transforms 2 §transform-style)
	return cs.opacity >= 1 && len(cs.filter) == 0 && len(cs.backdrop_filter) == 0 && cs.clip_path == nil && !style.has_mask(cs) &&
		cs.mix_blend_mode == .Normal && cs.isolation != .Isolate && cs.overflow_x == .Visible && cs.overflow_y == .Visible
}

// The 4x4 of a transformed box in layout coordinates (device px): box_matrix with the third dimension.
box_matrix4 :: proc(l: ^Layout, b: ^Box) -> Matrix4 {
	if .Transformed not_in b.flags || b.cs == nil { return style.IDENTITY_MATRIX4 }
	s := l.scale > 0 ? l.scale : 1
	r := Rect{b.abs, b.abs + b.size}
	if b.cs.transform_box == .Content_Box || b.cs.transform_box == .Fill_Box { r = content_rect(b) }
	m := style.transform_matrix4(b.cs, r.min.x / s, r.min.y / s, (r.max.x - r.min.x) / s, (r.max.y - r.min.y) / s)
	return finite4(units4(m, s))
}

// The perspective property of a box as a matrix in layout coordinates (identity without one).
perspective_of :: proc(l: ^Layout, b: ^Box) -> Matrix4 {
	if b.cs == nil || !(b.cs.perspective > 0) { return style.IDENTITY_MATRIX4 }
	s := l.scale > 0 ? l.scale : 1
	r := Rect{b.abs, b.abs + b.size}
	m := style.perspective_matrix(b.cs, r.min.x / s, r.min.y / s, (r.max.x - r.min.x) / s, (r.max.y - r.min.y) / s)
	return finite4(units4(m, s))
}

// A matrix of CSS px as a matrix of device px (scale s): M' = S M S^-1, S = scale(s, s, s) on points.
@(private)
units4 :: proc(m: Matrix4, s: f32) -> Matrix4 {
	r := m
	for col in 0 ..< 4 {
		for row in 0 ..< 4 {
			e: f32 = 1
			if row < 3 { e *= s }
			if col < 3 { e /= s }
			r[col * 4 + row] = m[col * 4 + row] * e
		}
	}
	return r
}

// A matrix with infinite or NaN entries is no transformation at all (it draws nothing).
@(private)
finite4 :: proc(m: Matrix4) -> Matrix4 {
	for v in m { if math.is_nan(v) || math.is_inf(v) { return Matrix4{} } }
	return m
}

// m for coordinates shifted by d (x, y): T(d) * m * T(-d).
shift4 :: proc(m: Matrix4, d: Vec2) -> Matrix4 {
	if d == {} { return m }
	return style.m4_mul(style.m4_translate(d.x, d.y, 0), style.m4_mul(m, style.m4_translate(-d.x, -d.y, 0)))
}

// The 3x3 of a 4x4 acting on the plane z = 0: rows x, y, w; columns x, y, 1.
plane_h3 :: proc(m: Matrix4) -> [9]f32 {
	return {m[0], m[4], m[12], m[1], m[5], m[13], m[3], m[7], m[15]}
}

h3_det :: proc(h: [9]f32) -> f32 {
	return h[0] * (h[4] * h[8] - h[5] * h[7]) - h[1] * (h[3] * h[8] - h[5] * h[6]) + h[2] * (h[3] * h[7] - h[4] * h[6])
}

h3_inverse :: proc(h: [9]f32) -> (r: [9]f32, ok: bool) {
	det := h3_det(h)
	if !(abs(det) > 1e-18) || math.is_inf(det) { return {}, false }
	k := 1 / det
	r = {
		(h[4] * h[8] - h[5] * h[7]) * k, (h[2] * h[7] - h[1] * h[8]) * k, (h[1] * h[5] - h[2] * h[4]) * k,
		(h[5] * h[6] - h[3] * h[8]) * k, (h[0] * h[8] - h[2] * h[6]) * k, (h[2] * h[3] - h[0] * h[5]) * k,
		(h[3] * h[7] - h[4] * h[6]) * k, (h[1] * h[6] - h[0] * h[7]) * k, (h[0] * h[4] - h[1] * h[3]) * k,
	}
	for v in r { if math.is_nan(v) || math.is_inf(v) { return {}, false } }
	return r, true
}

// The point (x, y) of the plane z = 0 through a 4x4: screen position, depth z (larger: nearer the viewer) and 1/w.
// ok = false: behind the viewer (w <= 0).
project4 :: proc(m: Matrix4, p: Vec2) -> (q: Vec2, z: f32, ok: bool) {
	h := style.m4_apply(m, p.x, p.y, 0)
	if !(h[3] > 1e-9) { return {}, h[2], false }
	return {h[0] / h[3], h[1] / h[3]}, h[2] / h[3], true
}

////////////////////////////////
// Building (finish)

// Sets up the plane fields of the Transform space `sp` (index `si`) of plane box `b`, which is in the space b.space.
@(private)
plane_space :: proc(l: ^Layout, sp: ^Space, si: i32, b: ^Box) {
	sp.proj = true
	sp.plane = si
	sp.mat4 = box_matrix4(l, b)
	sp.preserve = used_preserve_3d(b.cs)
	sp.back_hidden = b.cs.backface_visibility == .Hidden
	a := l.spaces[b.space].xform
	sp.persp_from = a
	sp.persp = style.IDENTITY_MATRIX4
	if a != NONE { sp.persp = perspective_of(l, &l.boxes[l.spaces[a].box]) }
	// a member of the context of the transformed ancestor when that one keeps its children in 3D
	if a != NONE && l.spaces[a].proj && l.spaces[a].preserve {
		sp.ctx = l.spaces[a].ctx
		sp.dest = l.spaces[sp.ctx].dest
	} else {
		sp.ctx = si
		sp.dest = a == NONE ? NONE : l.spaces[a].plane
	}
}

// The group of plane box `g`'s box now knows its space: where its projection lands.
@(private)
plane_group :: proc(l: ^Layout, g: i32, si: i32) {
	grp := &l.groups[g]
	grp.space = si
	sp := &l.spaces[si]
	if sp.ctx != si {
		// a member of a context: it lands where the context's root does
		root := l.boxes[l.spaces[sp.ctx].box].group
		if root != NONE { grp.dest = l.groups[root].parent }
	}
}

// Is a plane (a 3D transform, preserve-3d, or a hidden backface in a 3D context)? Used while the boxes are made.
@(private)
plane_wanted :: proc(l: ^Layout, b: ^Box, parent: i32) -> bool {
	cs := b.cs
	if cs == nil || !l.settings.transforms_3d || b.kind == .Inline { return false }
	if .Transformed in b.flags && (style.transform_is_3d(cs) || cs.transform_style == .Preserve_3d) { return true }
	if cs.backface_visibility == .Hidden {
		// hidden backfaces matter in a 3D context only: inside a box that keeps its children in 3D
		for p := parent; p != NONE; p = l.boxes[p].parent {
			pb := &l.boxes[p]
			if .Transformed in pb.flags { return .Plane in pb.flags && used_preserve_3d(pb.cs) }
			if .Root in pb.flags { break }
		}
	}
	return false
}

////////////////////////////////
// Views

// Where the plane `i` lands in the frame of what receives it, for this view's offsets and the matrices of the transform
// spaces between. ok = false: it flattens to nothing (edge-on, singular).
@(private)
plane_acc :: proc(l: ^Layout, v: ^View, i: i32) -> (Matrix4, bool) {
	sp := &l.spaces[i]
	base := style.IDENTITY_MATRIX4
	a := sp.persp_from
	if a != NONE {
		as := &l.spaces[a]
		if as.proj {
			if sp.ctx != i { base = v.accs[a] }
		} else {
			base = style.m4_from_2d(v.mats[a])
		}
		base = style.m4_mul(base, shift4(sp.persp, v.offsets[a]))
	}
	acc := style.m4_mul(base, shift4(sp.mat4, v.offsets[i]))
	return acc, abs(h3_det(plane_h3(acc))) > 1e-12
}

// A viewport point in the frame of plane `pl`: the point of that plane under it (its depth z in the frame of what
// receives it, larger = nearer). ok = false: no such point (edge-on, behind the viewer).
plane_point :: proc(l: ^Layout, v: ^View, pl: i32, p: Vec2) -> (q: Vec2, z: f32, ok: bool) {
	sp := &l.spaces[pl]
	pd := p
	if sp.dest != NONE {
		dok: bool
		pd, _, dok = plane_point(l, v, sp.dest, p)
		if !dok { return {}, 0, false }
	}
	if v.singular[pl] { return {}, 0, false }
	acc := v.accs[pl]
	inv, iok := h3_inverse(plane_h3(acc))
	if !iok { return {}, 0, false }
	a := inv[0] * pd.x + inv[1] * pd.y + inv[2]
	b := inv[3] * pd.x + inv[4] * pd.y + inv[5]
	c := inv[6] * pd.x + inv[7] * pd.y + inv[8]
	if c == 0 || math.is_nan(c) { return {}, 0, false }
	q = {a / c, b / c}
	h := style.m4_apply(acc, q.x, q.y, 0)
	// the matrix may carry the point behind the viewer: no hit there
	if !(h[3] > 0) { return q, h[2], false }
	return q, h[2], true
}

// A point of plane `pl`'s frame in the viewport (through the planes that receive it). ok = false: behind the viewer.
plane_project :: proc(l: ^Layout, v: ^View, pl: i32, u: Vec2) -> (Vec2, bool) {
	q, _, ok := project4(v.accs[pl], u)
	if !ok { return q, false }
	if d := l.spaces[pl].dest; d != NONE { return plane_project(l, v, d, q) }
	return q, true
}
