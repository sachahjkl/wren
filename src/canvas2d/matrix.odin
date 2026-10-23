// Package canvas2d: the software rasterizer behind the Canvas 2D API (HTML §4.12.5): paths, strokes, fills with
// coverage antialiasing, gradients, patterns, compositing, shadows, clips, text through a glyph-outline provider, image
// data. It knows nothing of the page, the DOM or the GPU: it draws into a premultiplied RGBA8 `Bitmap` that the shell
// uploads as a texture when `Bitmap.version` changes. Every function is total: NaN / Infinity / huge numbers from a
// script are refused or clamped, never trapped on.
package canvas2d

import "core:math"

// An affine transform in the order of the specification's matrix(a, b, c, d, e, f): a point (x, y) goes to
// (a x + c y + e, b x + d y + f).
Matrix :: struct { a, b, c, d, e, f: f64 }

IDENTITY :: Matrix{1, 0, 0, 1, 0, 0}

// m x n: the transform that applies `n` first, then `m` (CTM = CTM x M is what transform() does).
matrix_mul :: proc "contextless" (m, n: Matrix) -> Matrix {
	return Matrix{
		a = m.a * n.a + m.c * n.b,
		b = m.b * n.a + m.d * n.b,
		c = m.a * n.c + m.c * n.d,
		d = m.b * n.c + m.d * n.d,
		e = m.a * n.e + m.c * n.f + m.e,
		f = m.b * n.e + m.d * n.f + m.f,
	}
}

matrix_apply :: #force_inline proc "contextless" (m: Matrix, p: [2]f64) -> [2]f64 {
	return {m.a * p.x + m.c * p.y + m.e, m.b * p.x + m.d * p.y + m.f}
}

// The vector part only (no translation).
matrix_apply_vec :: #force_inline proc "contextless" (m: Matrix, p: [2]f64) -> [2]f64 {
	return {m.a * p.x + m.c * p.y, m.b * p.x + m.d * p.y}
}

matrix_det :: #force_inline proc "contextless" (m: Matrix) -> f64 { return m.a * m.d - m.b * m.c }

matrix_finite :: proc "contextless" (m: Matrix) -> bool {
	return is_finite(m.a) && is_finite(m.b) && is_finite(m.c) && is_finite(m.d) && is_finite(m.e) && is_finite(m.f)
}

// false: singular (or not finite), nothing to invert.
matrix_invert :: proc "contextless" (m: Matrix) -> (r: Matrix, ok: bool) {
	det := matrix_det(m)
	if !matrix_finite(m) || det == 0 || !is_finite(det) { return IDENTITY, false }
	id := 1 / det
	r = Matrix{
		a = m.d * id, b = -m.b * id, c = -m.c * id, d = m.a * id,
		e = (m.c * m.f - m.d * m.e) * id,
		f = (m.b * m.e - m.a * m.f) * id,
	}
	return r, matrix_finite(r)
}

matrix_translate :: proc "contextless" (x, y: f64) -> Matrix { return Matrix{1, 0, 0, 1, x, y} }
matrix_scale :: proc "contextless" (x, y: f64) -> Matrix { return Matrix{x, 0, 0, y, 0, 0} }
matrix_rotate :: proc "contextless" (angle: f64) -> Matrix {
	s, c := math.sin(angle), math.cos(angle)
	return Matrix{c, s, -s, c, 0, 0}
}

// The scale factors of the linear part (largest and smallest singular values): what a unit length becomes at most
// and at least. Used to turn device tolerances into user-space ones.
matrix_scales :: proc "contextless" (m: Matrix) -> (big, small: f64) {
	p := m.a * m.a + m.b * m.b + m.c * m.c + m.d * m.d
	q := math.sqrt((m.a * m.a + m.b * m.b - m.c * m.c - m.d * m.d) * (m.a * m.a + m.b * m.b - m.c * m.c - m.d * m.d) + 4 * (m.a * m.c + m.b * m.d) * (m.a * m.c + m.b * m.d))
	big = math.sqrt(max((p + q) * 0.5, 0))
	small = math.sqrt(max((p - q) * 0.5, 0))
	return
}

is_finite :: #force_inline proc "contextless" (v: f64) -> bool {
	return !math.is_nan(v) && !math.is_inf(v)
}

// The bounds that a rasterizer is asked to keep coordinates inside: wide enough for any visible geometry, narrow
// enough that arithmetic on them stays exact in f64.
COORD_LIMIT :: 1e12

// (NaN, which a sum of opposite infinities makes, becomes 0: nothing downstream may see one)
clamp_coord :: #force_inline proc "contextless" (v: f64) -> f64 {
	if v != v { return 0 }
	return clamp(v, -COORD_LIMIT, COORD_LIMIT)
}
