package layout

import "core:math"
import "wb:style"

// CSS Transforms 1 and 2 in layout: which boxes are transformed, their matrices in layout coordinates, and the
// geometry helpers (matrices, rounded rects) shared by finishing, views, hit testing and the refresh path.
//
// A transformed box establishes a stacking context and the containing block of its absolutely positioned and fixed
// descendants (§3). It does not move anything else: its matrix only affects painting, hit testing and the scrollable
// overflow of its scroll container (CSS Overflow 3 §2.2: the transformed bounds count).

IDENTITY :: Matrix{1, 0, 0, 1, 0, 0}

mat_mul :: #force_inline proc(m, n: Matrix) -> Matrix { return style.matrix_mul(m, n) }
mat_apply :: #force_inline proc(m: Matrix, p: Vec2) -> Vec2 { return style.matrix_apply(m, p.x, p.y) }
mat_inverse :: #force_inline proc(m: Matrix) -> (Matrix, bool) { return style.matrix_invert(m) }
mat_translate :: #force_inline proc(d: Vec2) -> Matrix { return Matrix{1, 0, 0, 1, d.x, d.y} }
mat_is_identity :: #force_inline proc(m: Matrix) -> bool { return m == IDENTITY }

// Axis-aligned bounds of a transformed rect.
mat_bounds :: proc(m: Matrix, r: Rect) -> Rect {
	if mat_is_identity(m) { return r }
	p0 := mat_apply(m, r.min)
	p1 := mat_apply(m, {r.max.x, r.min.y})
	p2 := mat_apply(m, {r.min.x, r.max.y})
	p3 := mat_apply(m, r.max)
	return Rect{{min(p0.x, p1.x, p2.x, p3.x), min(p0.y, p1.y, p2.y, p3.y)}, {max(p0.x, p1.x, p2.x, p3.x), max(p0.y, p1.y, p2.y, p3.y)}}
}

// `m` (which maps untransformed coordinates) expressed for coordinates shifted by `d`: T(d) * m * T(-d).
mat_shifted :: proc(m: Matrix, d: Vec2) -> Matrix {
	if d == {} { return m }
	return mat_mul(mat_translate(d), mat_mul(m, mat_translate(-d)))
}

// A box is the containing block of its fixed descendants (and of its absolutely positioned ones) when a transform
// applies, when it promises one (will-change: transform), or when a filter applies (CSS Filter Effects §5).
@(private)
contains_fixed :: proc(cs: ^style.Computed) -> bool {
	if style.has_transform(cs) || len(cs.filter) > 0 || len(cs.backdrop_filter) > 0 { return true }
	for w in cs.will_change { if w == "transform" || w == "translate" || w == "rotate" || w == "scale" || w == "filter" { return true } }
	return false
}

// Effects that make a stacking context besides positioning, opacity and transforms (CSS 2.1 Appendix E as extended by
// CSS Transforms, Compositing, Masking, Filter Effects 2 and Will Change).
@(private)
stacking_effect :: proc(cs: ^style.Computed) -> bool {
	if len(cs.filter) > 0 || len(cs.backdrop_filter) > 0 || cs.clip_path != nil || cs.isolation == .Isolate || cs.mix_blend_mode != .Normal { return true }
	for w in cs.will_change {
		switch w {
		case "transform", "translate", "rotate", "scale", "opacity", "filter", "backdrop-filter", "clip-path", "isolation", "mix-blend-mode": return true
		}
	}
	return false
}

// The transformation of a transformed box in layout coordinates (device px): its reference box (the border box, or
// the content box for transform-box: content-box / fill-box), transform-origin and the transform properties resolved
// in CSS px, then scaled to device px (the linear part does not change; translations scale).
box_matrix :: proc(l: ^Layout, b: ^Box) -> Matrix {
	if .Transformed not_in b.flags || b.cs == nil { return IDENTITY }
	s := l.scale > 0 ? l.scale : 1
	r := Rect{b.abs, b.abs + b.size}
	if b.cs.transform_box == .Content_Box || b.cs.transform_box == .Fill_Box { r = content_rect(b) }
	m := style.transform_matrix(b.cs, r.min.x / s, r.min.y / s, (r.max.x - r.min.x) / s, (r.max.y - r.min.y) / s)
	m[4] *= s
	m[5] *= s
	for v in m { if math.is_nan(v) || math.is_inf(v) { return Matrix{0, 0, 0, 0, 0, 0} } }
	return m
}

// Corner radii of a border box of size w x h (device px), reduced so adjacent ones fit (CSS Backgrounds §5.5), in draw
// order: top-left, bottom-left, top-right, bottom-right.
border_radii :: proc(cs: ^style.Computed, w, h, scale: f32) -> [4]f32 {
	if cs == nil { return {} }
	rad :: proc(cr: style.Corner_Radius, w, h, scale: f32) -> f32 {
		hv := style.resolve(cr.h, w / scale) * scale
		vv := style.resolve(cr.v, h / scale) * scale
		if cr.v.kind == .Auto { vv = hv }
		return max(min(hv, vv), 0)
	}
	tl := rad(cs.radius[.Top_Left], w, h, scale)
	tr := rad(cs.radius[.Top_Right], w, h, scale)
	br := rad(cs.radius[.Bottom_Right], w, h, scale)
	bl := rad(cs.radius[.Bottom_Left], w, h, scale)
	f: f32 = 1
	if tl + tr > w && w > 0 { f = min(f, w / (tl + tr)) }
	if bl + br > w && w > 0 { f = min(f, w / (bl + br)) }
	if tl + bl > h && h > 0 { f = min(f, h / (tl + bl)) }
	if tr + br > h && h > 0 { f = min(f, h / (tr + br)) }
	return {tl * f, bl * f, tr * f, br * f}
}

// Radii of the padding edge, what overflow clips to (CSS Backgrounds §5.3: outer radius minus the border). One radius
// per corner, the larger of the two the border widths leave, so clipped content never shows outside the border's
// inner curve.
@(private)
clip_radii :: proc(l: ^Layout, b: ^Box) -> [4]f32 {
	if b.kind == .Inline { return {} }
	out := border_radii(b.cs, b.size.x, b.size.y, l.scale)
	if out == {} { return {} }
	bt, br, bb, bl := b.border[0], b.border[1], b.border[2], b.border[3]
	return {max(out[0] - min(bl, bt), 0), max(out[1] - min(bl, bb), 0), max(out[2] - min(br, bt), 0), max(out[3] - min(br, bb), 0)}
}

// Is `p` inside the rounded rect (circular corners)?
rounded_contains :: proc(r: Rect, radii: [4]f32, p: Vec2) -> bool {
	if !rect_contains(r, p) { return false }
	if radii == {} { return true }
	corner :: proc(p, c: Vec2, rad: f32) -> bool {
		d := p - c
		return d.x * d.x + d.y * d.y <= rad * rad
	}
	if rad := radii[0]; rad > 0 && p.x < r.min.x + rad && p.y < r.min.y + rad { return corner(p, r.min + rad, rad) }
	if rad := radii[1]; rad > 0 && p.x < r.min.x + rad && p.y > r.max.y - rad { return corner(p, {r.min.x + rad, r.max.y - rad}, rad) }
	if rad := radii[2]; rad > 0 && p.x > r.max.x - rad && p.y < r.min.y + rad { return corner(p, {r.max.x - rad, r.min.y + rad}, rad) }
	if rad := radii[3]; rad > 0 && p.x > r.max.x - rad && p.y > r.max.y - rad { return corner(p, r.max - rad, rad) }
	return true
}
