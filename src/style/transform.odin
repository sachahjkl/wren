package style

import "core:math"
import "core:strings"
import "wb:css"

// CSS Transforms 1 and 2, in 2D. 3D functions are parsed and flattened by orthographic projection (what a viewer looking
// straight at the page would see without perspective): rotateX/Y shrink an axis by the cosine of the angle, z components
// are dropped, perspective() is the identity.
//
// Matrices are [6]f32 {a, b, c, d, e, f}, as in CSS matrix(): x' = a*x + c*y + e, y' = b*x + d*y + f, with y pointing
// down, so a positive rotation turns clockwise on screen.

Matrix :: [6]f32

IDENTITY_MATRIX :: Matrix{1, 0, 0, 1, 0, 0}

// m * n: n is applied first.
matrix_mul :: proc(m, n: Matrix) -> Matrix {
	return Matrix{
		m[0] * n[0] + m[2] * n[1],
		m[1] * n[0] + m[3] * n[1],
		m[0] * n[2] + m[2] * n[3],
		m[1] * n[2] + m[3] * n[3],
		m[0] * n[4] + m[2] * n[5] + m[4],
		m[1] * n[4] + m[3] * n[5] + m[5],
	}
}

matrix_apply :: proc(m: Matrix, x, y: f32) -> [2]f32 { return {m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]} }

matrix_invert :: proc(m: Matrix) -> (Matrix, bool) {
	det := m[0] * m[3] - m[1] * m[2]
	// `!(x < y)` also takes NaN: a matrix with infinite entries (matrix(1e39, ...) in f32) has no usable inverse
	if !(abs(det) >= 1e-12) || math.is_inf(det) { return IDENTITY_MATRIX, false }
	inv := 1 / det
	a, b, c, d := m[3] * inv, -m[1] * inv, -m[2] * inv, m[0] * inv
	r := Matrix{a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5])}
	for x in r { if math.is_nan(x) || math.is_inf(x) { return IDENTITY_MATRIX, false } }
	return r, true
}

@(private)
translation :: #force_inline proc(x, y: f32) -> Matrix { return Matrix{1, 0, 0, 1, x, y} }

// The matrix of one transform function in a reference box of w x h (percentages of translate refer to it).
op_matrix :: proc(op: Transform_Op, w, h: f32) -> Matrix {
	switch op.kind {
	case .Translate: return translation(resolve(op.l[0], w), resolve(op.l[1], h))
	case .Scale: return Matrix{op.v[0], 0, 0, op.v[1], 0, 0}
	case .Rotate:
		s, c := math.sin(op.v[0]), math.cos(op.v[0])
		return Matrix{c, s, -s, c, 0, 0}
	case .Skew: return Matrix{1, math.tan(op.v[1]), math.tan(op.v[0]), 1, 0, 0}
	case .Matrix: return Matrix{op.v[0], op.v[1], op.v[2], op.v[3], op.v[4], op.v[5]}
	case .Perspective: return IDENTITY_MATRIX
	case .Mix:
		if op.mix == nil { return IDENTITY_MATRIX }
		a := ops_matrix(op.mix.from, w, h)
		b := ops_matrix(op.mix.to, w, h)
		return recompose(decomposed_lerp(decompose(a), decompose(b), op.mix.t))
	}
	return IDENTITY_MATRIX
}

// The product of a transform list, first function outermost (CSS: the list is applied right to left).
ops_matrix :: proc(ops: []Transform_Op, w, h: f32) -> Matrix {
	m := IDENTITY_MATRIX
	for op in ops { m = matrix_mul(m, op_matrix(op, w, h)) }
	return m
}

// Some transform applies (transform, translate, rotate or scale is not none).
has_transform :: proc(c: ^Computed) -> bool {
	return len(c.transform) > 0 || c.translate.set || c.rotate.set || c.scale.set
}

// The full transformation of an element whose reference box (its border box, see transform-box) is at (x, y) with size
// w x h, in the coordinate space of that box: translate, rotate, scale, then transform, all around transform-origin
// (CSS Transforms 2 §6). Painters map the element's own drawing through it; hit testing uses its inverse.
transform_matrix :: proc(c: ^Computed, x, y, w, h: f32) -> Matrix {
	if c == nil || !has_transform(c) { return IDENTITY_MATRIX }
	ox := x + resolve(c.transform_origin[0], w)
	oy := y + resolve(c.transform_origin[1], h)
	m := translation(ox, oy)
	if c.translate.set { m = matrix_mul(m, translation(resolve(c.translate.x, w), resolve(c.translate.y, h))) }
	if c.rotate.set { m = matrix_mul(m, rotate_value_matrix(c.rotate)) }
	if c.scale.set { m = matrix_mul(m, Matrix{c.scale.s[0], 0, 0, c.scale.s[1], 0, 0}) }
	m = matrix_mul(m, ops_matrix(c.transform, w, h))
	return matrix_mul(m, translation(-ox, -oy))
}

@(private)
rotate_value_matrix :: proc(r: Rotate_Value) -> Matrix {
	return rotate3d_matrix(r.axis[0], r.axis[1], r.axis[2], r.angle)
}

// The 2D projection of rotate3d(x, y, z, a) (CSS Transforms 2 §12.4: the upper-left 2x2 of the 3D rotation).
rotate3d_matrix :: proc(x_in, y_in, z_in, a: f32) -> Matrix {
	x, y, z := x_in, y_in, z_in
	l := math.sqrt(x * x + y * y + z * z)
	if l == 0 { return IDENTITY_MATRIX }
	x, y, z = x / l, y / l, z / l
	sc := math.sin(a / 2) * math.cos(a / 2)
	sq := math.sin(a / 2) * math.sin(a / 2)
	m00 := 1 - 2 * (y * y + z * z) * sq
	m01 := 2 * (x * y * sq - z * sc)
	m10 := 2 * (x * y * sq + z * sc)
	m11 := 1 - 2 * (x * x + z * z) * sq
	return Matrix{m00, m10, m01, m11, 0, 0}
}

////////////////////////////////
// Decomposition (for interpolating matrices)

// M = translate(tx, ty) * rotate(angle) * skewX(atan(k)) * scale(sx, sy). sx >= 0; a reflection shows as a negative sy.
Decomposed :: struct { tx, ty, angle, sx, sy, k: f32 }

decompose :: proc(m: Matrix) -> Decomposed {
	d := Decomposed{tx = m[4], ty = m[5]}
	a, b, c, dd := m[0], m[1], m[2], m[3]
	d.sx = math.sqrt(a * a + b * b)
	if d.sx < 1e-12 {
		d.sx = 0
		d.sy = math.sqrt(c * c + dd * dd)
		d.angle = d.sy > 0 ? math.atan2(-c, dd) : 0
		return d
	}
	d.angle = math.atan2(b, a)
	co, si := math.cos(d.angle), math.sin(d.angle)
	d.sy = dd * co - c * si
	if abs(d.sy) > 1e-12 { d.k = (c * co + dd * si) / d.sy }
	return d
}

recompose :: proc(d: Decomposed) -> Matrix {
	co, si := math.cos(d.angle), math.sin(d.angle)
	return Matrix{d.sx * co, d.sx * si, d.sy * (d.k * co - si), d.sy * (d.k * si + co), d.tx, d.ty}
}

decomposed_lerp :: proc(a_in, b_in: Decomposed, t: f32) -> Decomposed {
	a, b := a_in, b_in
	// never the long way around
	for b.angle - a.angle > math.PI { a.angle += 2 * math.PI }
	for a.angle - b.angle > math.PI { b.angle += 2 * math.PI }
	lerp :: #force_inline proc(x, y, t: f32) -> f32 { return x + (y - x) * t }
	return Decomposed{
		tx = lerp(a.tx, b.tx, t), ty = lerp(a.ty, b.ty, t), angle = lerp(a.angle, b.angle, t),
		sx = lerp(a.sx, b.sx, t), sy = lerp(a.sy, b.sy, t), k = lerp(a.k, b.k, t),
	}
}

////////////////////////////////
// Parsing

@(private)
op_translate :: #force_inline proc(x, y: Length) -> Transform_Op { return Transform_Op{kind = .Translate, l = {x, y}} }

parse_transform_list :: proc(cx: ^Cx, vs: []css.Value) -> ([]Transform_Op, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return nil, true }
	if len(items) == 0 { return nil, false }
	out := make([]Transform_Op, len(items), cx.alloc)
	for it, i in items {
		op, ok := parse_transform_function(cx, it)
		if !ok { return nil, false }
		out[i] = op
	}
	return out, true
}

@(private)
parse_transform_function :: proc(cx: ^Cx, f: css.Value) -> (Transform_Op, bool) {
	if f.kind != .Function { return {}, false }
	args := css.split_commas(f.children, context.temp_allocator)
	vals := make([]css.Value, len(args), context.temp_allocator)
	for a, i in args {
		t := css.trim_values(a)
		if len(t) != 1 { return {}, false }
		vals[i] = t[0]
	}
	n := len(vals)
	lp :: proc(cx: ^Cx, v: css.Value) -> (Length, bool) { return length_of(cx, v, {.Percent, .Negative}) }
	len_only :: proc(cx: ^Cx, v: css.Value) -> (Length, bool) {
		l, ok := length_of(cx, v, {.Negative})
		return l, ok && l.kind == .Px
	}
	zero := px(0)
	switch css.lower_temp(f.tok.text) {
	case "matrix":
		if n != 6 { return {}, false }
		op := Transform_Op{kind = .Matrix}
		for v, i in vals {
			x, ok := number_of(v)
			if !ok { return {}, false }
			op.v[i] = f32(x)
		}
		return op, true
	case "matrix3d":
		if n != 16 { return {}, false }
		m: [16]f32
		for v, i in vals {
			x, ok := number_of(v)
			if !ok { return {}, false }
			m[i] = f32(x)
		}
		return Transform_Op{kind = .Matrix, v = {m[0], m[1], m[4], m[5], m[12], m[13]}}, true
	case "translate":
		if n < 1 || n > 2 { return {}, false }
		x, ok := lp(cx, vals[0])
		if !ok { return {}, false }
		y := zero
		if n == 2 { y, ok = lp(cx, vals[1]); if !ok { return {}, false } }
		return op_translate(x, y), true
	case "translatex":
		if n != 1 { return {}, false }
		x, ok := lp(cx, vals[0])
		return op_translate(x, zero), ok
	case "translatey":
		if n != 1 { return {}, false }
		y, ok := lp(cx, vals[0])
		return op_translate(zero, y), ok
	case "translatez":
		if n != 1 { return {}, false }
		_, ok := len_only(cx, vals[0])
		return op_translate(zero, zero), ok
	case "translate3d":
		if n != 3 { return {}, false }
		x, ok1 := lp(cx, vals[0])
		y, ok2 := lp(cx, vals[1])
		_, ok3 := len_only(cx, vals[2])
		return op_translate(x, y), ok1 && ok2 && ok3
	case "scale", "scalex", "scaley", "scalez", "scale3d":
		name := css.lower_temp(f.tok.text)
		want_min, want_max := 1, 1
		switch name {
		case "scale": want_max = 2
		case "scale3d": want_min, want_max = 3, 3
		}
		if n < want_min || n > want_max { return {}, false }
		s: [3]f32
		for v, i in vals {
			x, ok := factor_of(v)
			if !ok { return {}, false }
			s[i] = x
		}
		op := Transform_Op{kind = .Scale, v = {1, 1, 0, 0, 0, 0}}
		switch name {
		case "scale": op.v[0], op.v[1] = s[0], n == 2 ? s[1] : s[0]
		case "scalex": op.v[0] = s[0]
		case "scaley": op.v[1] = s[0]
		case "scalez":
		case "scale3d": op.v[0], op.v[1] = s[0], s[1]
		}
		return op, true
	case "rotate", "rotatez":
		if n != 1 { return {}, false }
		a, ok := parse_angle(vals[0])
		return Transform_Op{kind = .Rotate, v = {a, 0, 0, 0, 0, 0}}, ok
	case "rotatex", "rotatey":
		if n != 1 { return {}, false }
		a, ok := parse_angle(vals[0])
		c := math.cos(a)
		is_x := strings.equal_fold(f.tok.text, "rotatex")
		return Transform_Op{kind = .Scale, v = {is_x ? 1 : c, is_x ? c : 1, 0, 0, 0, 0}}, ok
	case "rotate3d":
		if n != 4 { return {}, false }
		axis: [3]f32
		for i in 0 ..< 3 {
			x, ok := number_of(vals[i])
			if !ok { return {}, false }
			axis[i] = f32(x)
		}
		a, ok := parse_angle(vals[3])
		if !ok { return {}, false }
		if axis[0] == 0 && axis[1] == 0 {
			if axis[2] == 0 { return Transform_Op{kind = .Matrix, v = IDENTITY_MATRIX}, true }
			return Transform_Op{kind = .Rotate, v = {axis[2] > 0 ? a : -a, 0, 0, 0, 0, 0}}, true
		}
		m := rotate3d_matrix(axis[0], axis[1], axis[2], a)
		return Transform_Op{kind = .Matrix, v = m}, true
	case "skew":
		if n < 1 || n > 2 { return {}, false }
		ax, ok := parse_angle(vals[0])
		if !ok { return {}, false }
		ay: f32
		if n == 2 { ay, ok = parse_angle(vals[1]); if !ok { return {}, false } }
		return Transform_Op{kind = .Skew, v = {ax, ay, 0, 0, 0, 0}}, true
	case "skewx":
		if n != 1 { return {}, false }
		a, ok := parse_angle(vals[0])
		return Transform_Op{kind = .Skew, v = {a, 0, 0, 0, 0, 0}}, ok
	case "skewy":
		if n != 1 { return {}, false }
		a, ok := parse_angle(vals[0])
		return Transform_Op{kind = .Skew, v = {0, a, 0, 0, 0, 0}}, ok
	case "perspective":
		if n != 1 { return {}, false }
		if ident_lower(vals[0]) == "none" { return Transform_Op{kind = .Perspective}, true }
		l, ok := len_only(cx, vals[0])
		if !ok || l.v < 0 { return {}, false }
		return Transform_Op{kind = .Perspective, v = {l.v, 0, 0, 0, 0, 0}}, true
	}
	return {}, false
}

parse_transform_origin :: proc(cx: ^Cx, vs: []css.Value) -> ([2]Length, bool) {
	items := split_items(css.trim_values(vs))
	switch len(items) {
	case 1, 2:
		return parse_position(cx, items)
	case 3:
		if _, ok := length_of(cx, items[2], {.Negative}); !ok || ident_lower(items[2]) != "" { return {}, false }
		return parse_position(cx, items[:2])
	}
	return {}, false
}

parse_translate :: proc(cx: ^Cx, vs: []css.Value) -> (Translate_Value, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return {}, true }
	if len(items) < 1 || len(items) > 3 { return {}, false }
	t := Translate_Value{set = true, y = px(0)}
	ok: bool
	if t.x, ok = length_of(cx, items[0], {.Percent, .Negative}); !ok { return {}, false }
	if len(items) >= 2 { if t.y, ok = length_of(cx, items[1], {.Percent, .Negative}); !ok { return {}, false } }
	if len(items) == 3 {
		z, good := length_of(cx, items[2], {.Negative})
		if !good || z.kind != .Px { return {}, false }
		t.z = z.v
	}
	return t, true
}

parse_rotate :: proc(vs: []css.Value) -> (Rotate_Value, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return {}, true }
	r := Rotate_Value{set = true, axis = {0, 0, 1}}
	have_angle, have_axis := false, false
	nums := make([dynamic]f32, context.temp_allocator)
	for it in items {
		if a, ok := parse_angle(it, false); ok {
			if have_angle { return {}, false }
			r.angle, have_angle = a, true
			continue
		}
		switch ident_lower(it) {
		case "x": if have_axis { return {}, false }; r.axis, have_axis = {1, 0, 0}, true; continue
		case "y": if have_axis { return {}, false }; r.axis, have_axis = {0, 1, 0}, true; continue
		case "z": if have_axis { return {}, false }; r.axis, have_axis = {0, 0, 1}, true; continue
		}
		n, ok := number_of(it)
		if !ok || have_axis && len(nums) == 0 { return {}, false }
		append(&nums, f32(n))
	}
	if len(nums) != 0 && len(nums) != 3 { return {}, false }
	if len(nums) == 3 {
		if have_axis { return {}, false }
		r.axis = {nums[0], nums[1], nums[2]}
	}
	if !have_angle { return {}, false }
	return r, true
}

parse_scale :: proc(vs: []css.Value) -> (Scale_Value, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "none" { return {}, true }
	if len(items) < 1 || len(items) > 3 { return {}, false }
	s := Scale_Value{set = true}
	for it, i in items {
		f, ok := factor_of(it)
		if !ok { return {}, false }
		s.s[i] = f
	}
	if len(items) == 1 { s.s[1] = s.s[0] }
	if len(items) < 3 { s.s[2] = 1 }
	return s, true
}
