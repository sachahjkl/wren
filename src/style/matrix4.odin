package style

import "core:math"

// 4x4 matrices of CSS Transforms 2, in the order of matrix3d(): column-major, m[column * 4 + row], column vectors:
//
//     | m0 m4 m8  m12 |   | x |        x' = m0 x + m4 y + m8 z + m12 (then divided by w' = m3 x + m7 y + m11 z + m15)
//     | m1 m5 m9  m13 | * | y |
//     | m2 m6 m10 m14 |   | z |
//     | m3 m7 m11 m15 |   | 1 |
//
// y points down, so a positive rotateZ turns clockwise on screen, and z points toward the viewer.

Matrix4 :: [16]f32

IDENTITY_MATRIX4 :: Matrix4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

// m * n: n is applied first.
m4_mul :: proc(m, n: Matrix4) -> Matrix4 {
	r: Matrix4
	for c in 0 ..< 4 {
		for row in 0 ..< 4 {
			s: f32
			for k in 0 ..< 4 { s += m[k * 4 + row] * n[c * 4 + k] }
			r[c * 4 + row] = s
		}
	}
	return r
}

m4_from_2d :: proc(m: Matrix) -> Matrix4 {
	return {m[0], m[1], 0, 0, m[2], m[3], 0, 0, 0, 0, 1, 0, m[4], m[5], 0, 1}
}

// The 2D matrix of a 4x4 that acts on the plane z = 0 without perspective: the orthographic projection (z dropped).
m4_flatten :: proc(m: Matrix4) -> Matrix { return Matrix{m[0], m[1], m[4], m[5], m[12], m[13]} }

// The matrix maps the plane z = 0 to itself without perspective, so a 2D matrix says all of it (z only matters for what it
// leaves out: its z row and column). `eps` forgives rounding of cos(90deg) and the like.
m4_is_2d :: proc(m: Matrix4, eps: f32 = 1e-6) -> bool {
	return abs(m[2]) <= eps && abs(m[3]) <= eps && abs(m[6]) <= eps && abs(m[7]) <= eps && abs(m[8]) <= eps && abs(m[9]) <= eps &&
		abs(m[11]) <= eps && abs(m[15] - 1) <= eps && abs(m[10] - 1) <= eps && abs(m[14]) <= eps
}

// The plane z = 0 is mapped to a plane the 2D part describes (no perspective, nothing moving in or out): drawing it with
// m4_flatten is right even when the matrix has z terms (the flat view of rotateX(30deg), say, is a plain 2D matrix).
m4_is_affine :: proc(m: Matrix4, eps: f32 = 1e-6) -> bool {
	return abs(m[3]) <= eps && abs(m[7]) <= eps && abs(m[15] - 1) <= eps
}

m4_translate :: proc(x, y, z: f32) -> Matrix4 {
	m := IDENTITY_MATRIX4
	m[12], m[13], m[14] = x, y, z
	return m
}

m4_scale :: proc(x, y, z: f32) -> Matrix4 {
	m := IDENTITY_MATRIX4
	m[0], m[5], m[10] = x, y, z
	return m
}

// CSS perspective(d): the viewer d in front of the plane. d < 1 counts as 1 (CSS Transforms 2 §perspective-function).
m4_perspective :: proc(d: f32) -> Matrix4 {
	m := IDENTITY_MATRIX4
	if d > 0 { m[11] = -1 / max(d, 1) }
	return m
}

// rotate3d(x, y, z, a) (CSS Transforms 2 §12.4). A zero axis is the identity.
m4_rotate :: proc(x_in, y_in, z_in, a: f32) -> Matrix4 {
	x, y, z := x_in, y_in, z_in
	l := math.sqrt(x * x + y * y + z * z)
	if l == 0 || math.is_nan(l) || math.is_inf(l) { return IDENTITY_MATRIX4 }
	x, y, z = x / l, y / l, z / l
	sc := math.sin(a / 2) * math.cos(a / 2)
	sq := math.sin(a / 2) * math.sin(a / 2)
	return {
		1 - 2 * (y * y + z * z) * sq, 2 * (x * y * sq + z * sc), 2 * (x * z * sq - y * sc), 0,
		2 * (x * y * sq - z * sc), 1 - 2 * (x * x + z * z) * sq, 2 * (y * z * sq + x * sc), 0,
		2 * (x * z * sq + y * sc), 2 * (y * z * sq - x * sc), 1 - 2 * (x * x + y * y) * sq, 0,
		0, 0, 0, 1,
	}
}

m4_skew :: proc(ax, ay: f32) -> Matrix4 {
	m := IDENTITY_MATRIX4
	m[1], m[4] = math.tan(ay), math.tan(ax)
	return m
}

// Homogeneous (x, y, z, w) of the point (x, y, z).
m4_apply :: proc(m: Matrix4, x, y, z: f32) -> [4]f32 {
	return {
		m[0] * x + m[4] * y + m[8] * z + m[12],
		m[1] * x + m[5] * y + m[9] * z + m[13],
		m[2] * x + m[6] * y + m[10] * z + m[14],
		m[3] * x + m[7] * y + m[11] * z + m[15],
	}
}

// The plane z = 0 point (x, y) after the divide by w. ok = false: behind the viewer (w <= 0).
m4_project :: proc(m: Matrix4, x, y: f32) -> (p: [2]f32, ok: bool) {
	h := m4_apply(m, x, y, 0)
	if !(h[3] > 1e-9) { return {}, false }
	return {h[0] / h[3], h[1] / h[3]}, true
}

m4_determinant :: proc(m: Matrix4) -> f32 {
	a := [4][4]f64{}
	for c in 0 ..< 4 { for r in 0 ..< 4 { a[r][c] = f64(m[c * 4 + r]) } }
	return f32(det4(a))
}

@(private)
det3 :: proc(a, b, c, d, e, f, g, h, i: f64) -> f64 { return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g) }

@(private)
det4 :: proc(a: [4][4]f64) -> f64 {
	return a[0][0] * det3(a[1][1], a[1][2], a[1][3], a[2][1], a[2][2], a[2][3], a[3][1], a[3][2], a[3][3]) -
		a[0][1] * det3(a[1][0], a[1][2], a[1][3], a[2][0], a[2][2], a[2][3], a[3][0], a[3][2], a[3][3]) +
		a[0][2] * det3(a[1][0], a[1][1], a[1][3], a[2][0], a[2][1], a[2][3], a[3][0], a[3][1], a[3][3]) -
		a[0][3] * det3(a[1][0], a[1][1], a[1][2], a[2][0], a[2][1], a[2][2], a[3][0], a[3][1], a[3][2])
}

// The inverse by cofactors in f64. ok = false: singular, or not finite.
m4_invert :: proc(m: Matrix4) -> (r: Matrix4, ok: bool) {
	a: [16]f64
	for i in 0 ..< 16 { a[i] = f64(m[i]) }
	inv: [16]f64
	inv[0] = a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15] + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10]
	inv[4] = -a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15] - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10]
	inv[8] = a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15] + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9]
	inv[12] = -a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14] - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9]
	inv[1] = -a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15] - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10]
	inv[5] = a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15] + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10]
	inv[9] = -a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15] - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9]
	inv[13] = a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14] + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9]
	inv[2] = a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15] + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6]
	inv[6] = -a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15] - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6]
	inv[10] = a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15] + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5]
	inv[14] = -a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14] - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5]
	inv[3] = -a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11] - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6]
	inv[7] = a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11] + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6]
	inv[11] = -a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11] - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5]
	inv[15] = a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10] + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5]
	det := a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12]
	if !(abs(det) > 1e-30) || math.is_inf(det) || math.is_nan(det) { return IDENTITY_MATRIX4, false }
	for i in 0 ..< 16 {
		v := f32(inv[i] / det)
		if math.is_nan(v) || math.is_inf(v) { return IDENTITY_MATRIX4, false }
		r[i] = v
	}
	return r, true
}

// Does the plane z = 0 seen through `m` show its back? (The z of its transformed normal points away: the third entry of the
// inverse's third column, as Chromium and CSS Transforms 2 §backface-visibility decide.)
m4_back_facing :: proc(m: Matrix4) -> bool {
	inv, ok := m4_invert(m)
	return ok && inv[10] < 0
}

////////////////////////////////
// Decomposition (CSS Transforms 2 §"Decomposing a 3D matrix", from Graphics Gems II "unmatrix")

Decomposed4 :: struct {
	translate:   [3]f32,
	scale:       [3]f32,
	skew:        [3]f32,   // xy, xz, yz
	perspective: [4]f32,
	quaternion:  [4]f32,   // x y z w
}

decompose4 :: proc(m_in: Matrix4) -> (d: Decomposed4, ok: bool) {
	// matrix[col][row]
	mt: [4][4]f64
	for c in 0 ..< 4 { for r in 0 ..< 4 { mt[c][r] = f64(m_in[c * 4 + r]) } }
	if mt[3][3] == 0 || math.is_nan(mt[3][3]) { return {}, false }
	for c in 0 ..< 4 { for r in 0 ..< 4 { mt[c][r] /= mt[3][3] } }
	pm := mt
	for c in 0 ..< 3 { pm[c][3] = 0 }
	pm[3][3] = 1
	if abs(det4(transpose_cr(pm))) < 1e-30 { return {}, false }
	if mt[0][3] != 0 || mt[1][3] != 0 || mt[2][3] != 0 {
		// perspective = (inverse(perspectiveMatrix))^T * rhs
		flat: Matrix4
		for c in 0 ..< 4 { for r in 0 ..< 4 { flat[c * 4 + r] = f32(pm[c][r]) } }
		inv, iok := m4_invert(flat)
		if !iok { return {}, false }
		rhs := [4]f64{mt[0][3], mt[1][3], mt[2][3], mt[3][3]}
		// transpose(inv) * rhs: component k = sum_j inv[k][j]... in matrix[col][row]: inv_t[c][r] = inv[r][c]
		for k in 0 ..< 4 {
			s: f64
			for j in 0 ..< 4 { s += f64(inv[k * 4 + j]) * rhs[j] }
			d.perspective[k] = f32(s)
		}
	} else {
		d.perspective = {0, 0, 0, 1}
	}
	d.translate = {f32(mt[3][0]), f32(mt[3][1]), f32(mt[3][2])}
	row: [3][3]f64
	for i in 0 ..< 3 { for j in 0 ..< 3 { row[i][j] = mt[i][j] } }
	sc: [3]f64
	skew: [3]f64
	sc[0] = vlen(row[0])
	row[0] = vnorm(row[0])
	skew[0] = vdot(row[0], row[1])
	row[1] = vcomb(row[1], row[0], 1, -skew[0])
	sc[1] = vlen(row[1])
	row[1] = vnorm(row[1])
	if sc[1] != 0 { skew[0] /= sc[1] }
	skew[1] = vdot(row[0], row[2])
	row[2] = vcomb(row[2], row[0], 1, -skew[1])
	skew[2] = vdot(row[1], row[2])
	row[2] = vcomb(row[2], row[1], 1, -skew[2])
	sc[2] = vlen(row[2])
	row[2] = vnorm(row[2])
	if sc[2] != 0 { skew[1] /= sc[2]; skew[2] /= sc[2] }
	// a reflection: negate everything
	cross := [3]f64{row[1][1] * row[2][2] - row[1][2] * row[2][1], row[1][2] * row[2][0] - row[1][0] * row[2][2], row[1][0] * row[2][1] - row[1][1] * row[2][0]}
	if vdot(row[0], cross) < 0 {
		for i in 0 ..< 3 { sc[i] = -sc[i]; for j in 0 ..< 3 { row[i][j] = -row[i][j] } }
	}
	q: [4]f64
	q[0] = 0.5 * math.sqrt(max(1 + row[0][0] - row[1][1] - row[2][2], 0))
	q[1] = 0.5 * math.sqrt(max(1 - row[0][0] + row[1][1] - row[2][2], 0))
	q[2] = 0.5 * math.sqrt(max(1 - row[0][0] - row[1][1] + row[2][2], 0))
	q[3] = 0.5 * math.sqrt(max(1 + row[0][0] + row[1][1] + row[2][2], 0))
	if row[2][1] > row[1][2] { q[0] = -q[0] }
	if row[0][2] > row[2][0] { q[1] = -q[1] }
	if row[1][0] > row[0][1] { q[2] = -q[2] }
	for i in 0 ..< 3 { d.scale[i], d.skew[i] = f32(sc[i]), f32(skew[i]) }
	for i in 0 ..< 4 { d.quaternion[i] = f32(q[i]) }
	for v in d.translate { if math.is_nan(v) || math.is_inf(v) { return {}, false } }
	for v in d.scale { if math.is_nan(v) || math.is_inf(v) { return {}, false } }
	return d, true
}

@(private)
transpose_cr :: proc(a: [4][4]f64) -> [4][4]f64 {
	r: [4][4]f64
	for c in 0 ..< 4 { for k in 0 ..< 4 { r[k][c] = a[c][k] } }
	return r
}

@(private) vdot :: proc(a, b: [3]f64) -> f64 { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
@(private) vlen :: proc(a: [3]f64) -> f64 { return math.sqrt(vdot(a, a)) }
@(private) vnorm :: proc(a: [3]f64) -> [3]f64 { l := vlen(a); return l == 0 ? a : a / l }
@(private) vcomb :: proc(a, b: [3]f64, fa, fb: f64) -> [3]f64 { return a * fa + b * fb }

recompose4 :: proc(d: Decomposed4) -> Matrix4 {
	var_m: [4][4]f64   // matrix[col][row]
	for i in 0 ..< 4 { var_m[i][i] = 1 }
	for i in 0 ..< 4 { var_m[i][3] = f64(d.perspective[i]) }
	// translation: matrix = translate * matrix
	// (the fourth row too: with a perspective, the translation reaches w)
	for i in 0 ..< 4 {
		for j in 0 ..< 3 { var_m[3][i] += f64(d.translate[j]) * var_m[j][i] }
	}
	x, y, z, w := f64(d.quaternion[0]), f64(d.quaternion[1]), f64(d.quaternion[2]), f64(d.quaternion[3])
	rot: [4][4]f64
	rot[0][0] = 1 - 2 * (y * y + z * z); rot[0][1] = 2 * (x * y + z * w); rot[0][2] = 2 * (x * z - y * w)
	rot[1][0] = 2 * (x * y - z * w); rot[1][1] = 1 - 2 * (x * x + z * z); rot[1][2] = 2 * (y * z + x * w)
	rot[2][0] = 2 * (x * z + y * w); rot[2][1] = 2 * (y * z - x * w); rot[2][2] = 1 - 2 * (x * x + y * y)
	rot[3][3] = 1
	var_m = mul_cr(var_m, rot)
	if d.skew[2] != 0 {
		t: [4][4]f64
		for i in 0 ..< 4 { t[i][i] = 1 }
		t[2][1] = f64(d.skew[2])
		var_m = mul_cr(var_m, t)
	}
	if d.skew[1] != 0 {
		t: [4][4]f64
		for i in 0 ..< 4 { t[i][i] = 1 }
		t[2][0] = f64(d.skew[1])
		var_m = mul_cr(var_m, t)
	}
	if d.skew[0] != 0 {
		t: [4][4]f64
		for i in 0 ..< 4 { t[i][i] = 1 }
		t[1][0] = f64(d.skew[0])
		var_m = mul_cr(var_m, t)
	}
	for i in 0 ..< 3 { for j in 0 ..< 4 { var_m[i][j] *= f64(d.scale[i]) } }
	r: Matrix4
	for c in 0 ..< 4 { for k in 0 ..< 4 { r[c * 4 + k] = f32(var_m[c][k]) } }
	return r
}

// a * b with matrix[col][row] indexing (b applied first).
@(private)
mul_cr :: proc(a, b: [4][4]f64) -> [4][4]f64 {
	r: [4][4]f64
	for c in 0 ..< 4 { for row in 0 ..< 4 {
		s: f64
		for k in 0 ..< 4 { s += a[k][row] * b[c][k] }
		r[c][row] = s
	} }
	return r
}

quat_slerp :: proc(a_in, b_in: [4]f32, t: f64) -> [4]f32 {
	a, b := a_in, b_in
	dot := f64(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])
	if dot < 0 { for i in 0 ..< 4 { b[i] = -b[i] }; dot = -dot }
	dot = clamp(dot, -1, 1)
	if dot > 0.9995 {
		r: [4]f32
		l: f64
		for i in 0 ..< 4 { r[i] = lerp32(a[i], b[i], t); l += f64(r[i]) * f64(r[i]) }
		l = math.sqrt(l)
		if l > 0 { for i in 0 ..< 4 { r[i] = f32(f64(r[i]) / l) } }
		return r
	}
	th := math.acos(dot)
	s := math.sin(th)
	wa, wb := math.sin((1 - t) * th) / s, math.sin(t * th) / s
	r: [4]f32
	for i in 0 ..< 4 { r[i] = f32(wa * f64(a[i]) + wb * f64(b[i])) }
	return r
}

decomposed4_lerp :: proc(a, b: Decomposed4, t: f64) -> Decomposed4 {
	r: Decomposed4
	for i in 0 ..< 3 {
		r.translate[i] = lerp32(a.translate[i], b.translate[i], t)
		r.scale[i] = lerp32(a.scale[i], b.scale[i], t)
		r.skew[i] = lerp32(a.skew[i], b.skew[i], t)
	}
	for i in 0 ..< 4 { r.perspective[i] = lerp32(a.perspective[i], b.perspective[i], t) }
	r.quaternion = quat_slerp(a.quaternion, b.quaternion, t)
	return r
}

// Axis and angle (radians) of a unit quaternion (x y z w).
quat_axis_angle :: proc(q: [4]f32) -> (axis: [3]f32, angle: f32) {
	w := clamp(q[3], -1, 1)
	angle = 2 * math.acos(w)
	s := math.sqrt(max(1 - w * w, 0))
	if s < 1e-6 { return {0, 0, 1}, 0 }
	return {q[0] / s, q[1] / s, q[2] / s}, angle
}

quat_from_axis_angle :: proc(axis: [3]f32, angle: f32) -> [4]f32 {
	l := math.sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
	if l == 0 { return {0, 0, 0, 1} }
	s := math.sin(angle / 2) / l
	return {axis[0] * s, axis[1] * s, axis[2] * s, math.cos(angle / 2)}
}
