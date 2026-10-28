// web_geometry.odin: Geometry Interfaces Module Level 1 in the engine: DOMPointReadOnly / DOMPoint, DOMMatrixReadOnly /
// DOMMatrix and DOMQuad (DOMRect is dom_layout.odin). Ported from native/js/runtime/web_geometry.c with the same
// behaviour, messages and symbols (web_dommatrix_new_2d is exported for the 2D canvas).
//
// Pure arithmetic, so it runs here and not in the browser: no call crosses the module's boundary, hence nothing to
// declare in api_decl. A point is a dom_impl of kind DOM_RECT holding x y z w; a quad is a dom_impl holding its four
// DOMPoint objects; a matrix is a Matrix, its sixteen numbers in column-major order (m11 m12 m13 m14 m21 ... m44, the
// order of the attributes) and the "2D" flag that says whether it was made from 2D values and has stayed 2D. The CSS
// transform-list parser knows matrix(), matrix3d(), translate*, scale*, rotate*, skew* and perspective(). The
// trigonometry is libm's (wj.libm_*), as in the C, so serialised numbers stay bit-identical.
package odin_glue

import "../odin/jsb"
import "../odin/wj"

// The interfaces, by name (jsb.iface_of resolves a type's name once).
@(private = "file") DOMMatrixReadOnly :: distinct u64
@(private = "file") DOMMatrix         :: distinct u64
@(private = "file") DOMPointReadOnly  :: distinct u64
@(private = "file") DOMPoint          :: distinct u64
@(private = "file") DOMQuad           :: distinct u64

@(private = "file") PI :: 3.14159265358979323846
@(private = "file") NAN :: f64(0h7FF8_0000_0000_0000)
@(private = "file") DBL_MAX :: f64(0h7FEF_FFFF_FFFF_FFFF)

@(private = "file") M16 :: [16]f64

@(private = "file")
Matrix :: struct {
	m:    M16,
	is2d: bool,
}

// (variables with constant initializers: a constant array cannot be indexed at run time)
@(private = "file") IDENT := M16{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
// a b c d e f in the column-major array
@(private = "file") IDX_2D := [6]int{0, 1, 4, 5, 12, 13}

@(private = "file")
is_2d_slot :: #force_inline proc "contextless" (i: int) -> bool {
	return i == 0 || i == 1 || i == 4 || i == 5 || i == 12 || i == 13
}

@(private = "file") is_nan :: #force_inline proc "contextless" (x: f64) -> bool { return x != x }
@(private = "file") is_finite :: #force_inline proc "contextless" (x: f64) -> bool { return x == x && x - x == 0 }

@(private = "file")
matrix_free :: proc "c" (p: rawptr) { wj.libc_free(p) }

// an optional unrestricted double: undefined (or absent) is `def`
@(private = "file")
num_arg :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32, def: f64, out: ^f64) -> bool {
	out^ = def
	if i >= argc || wj.is_undefined(argv[i]) { return true }
	return wj.wj_to_double(ctx, argv[i], out, false)
}

@(private = "file")
present :: #force_inline proc "contextless" (argc: i32, argv: [^]wj.JSValue, i: i32) -> bool {
	return i < argc && !wj.is_undefined(argv[i])
}

// ---- 4x4 arithmetic ----

// a * b (the product applies b first, then a)
@(private = "file")
mul4 :: proc "contextless" (a, b: M16) -> (r: M16) {
	for c in 0 ..< 4 {
		for row in 0 ..< 4 {
			s := 0.0
			for k in 0 ..< 4 { s += a[k * 4 + row] * b[c * 4 + k] }
			r[c * 4 + row] = s
		}
	}
	return
}

// The inverse by cofactors; false when the determinant is zero or not finite.
@(private = "file")
invert4 :: proc "contextless" (m: M16) -> (out: M16, ok: bool) {
	inv: M16
	inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
	inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
	inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
	inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
	inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
	inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
	inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
	inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
	inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
	inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
	inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
	inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
	inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
	inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
	inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
	inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
	det := m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
	if det == 0 || !is_finite(det) { return {}, false }
	for i in 0 ..< 16 { out[i] = inv[i] / det }
	return out, true
}

@(private = "file")
m_translate :: proc "contextless" (x, y, z: f64) -> M16 { m := IDENT; m[12] = x; m[13] = y; m[14] = z; return m }
@(private = "file")
m_scale :: proc "contextless" (x, y, z: f64) -> M16 { m := IDENT; m[0] = x; m[5] = y; m[10] = z; return m }
@(private = "file")
m_skew :: proc "contextless" (ax_deg, ay_deg: f64) -> M16 {
	m := IDENT
	m[4] = wj.libm_tan(ax_deg * PI / 180)
	m[1] = wj.libm_tan(ay_deg * PI / 180)
	return m
}

// The rotation of `deg` degrees around the vector (x, y, z) (CSS Transforms: rotate3d()). Around the z axis the cosine
// and sine are used as they are (rotate(90deg) has a cos of 6e-17, not the 2e-16 the half angle formula would give).
@(private = "file")
m_rotate :: proc "contextless" (vx, vy, vz, deg: f64) -> M16 {
	m := IDENT
	l := wj.libm_hypot(wj.libm_hypot(vx, vy), vz)
	if l == 0 { return m }
	x := vx / l; y := vy / l; z := vz / l
	if x == 0 && y == 0 {
		r := deg * PI / 180
		c := wj.libm_cos(r)
		s := wj.libm_sin(r) * (z > 0 ? 1 : -1)
		m[0] = c; m[1] = s; m[4] = -s; m[5] = c
		return m
	}
	a := deg * PI / 360   // half angle
	sc := wj.libm_sin(a) * wj.libm_cos(a)
	sq := wj.libm_sin(a) * wj.libm_sin(a)
	m[0] = 1 - 2 * (y * y + z * z) * sq; m[1] = 2 * (x * y * sq + z * sc); m[2] = 2 * (x * z * sq - y * sc)
	m[4] = 2 * (x * y * sq - z * sc); m[5] = 1 - 2 * (x * x + z * z) * sq; m[6] = 2 * (y * z * sq + x * sc)
	m[8] = 2 * (x * z * sq + y * sc); m[9] = 2 * (y * z * sq - x * sc); m[10] = 1 - 2 * (x * x + y * y) * sq
	return m
}

// ---- matrix objects ----

@(private = "file")
matrix_new :: proc "contextless" (ctx: ^wj.Context, iface: i32, new_target: wj.JSValue, m: M16, is2d: bool) -> wj.JSValue {
	g := (^Matrix)(wj.libc_malloc(size_of(Matrix)))
	if g == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	g^ = {m, is2d}
	return wj.wj_new_object_for(ctx, iface, new_target, g, matrix_free)
}

// A 2D DOMMatrix of a b c d e f (the canvas's getTransform).
@(export, link_name = "web_dommatrix_new_2d")
web_dommatrix_new_2d :: proc "c" (ctx: ^wj.Context, m: ^[6]f64) -> wj.JSValue {
	full := IDENT
	for i in 0 ..< 6 { full[IDX_2D[i]] = m[i] }
	return matrix_new(ctx, jsb.iface_of(DOMMatrix), wj.UNDEFINED, full, true)
}

@(private = "file")
matrix_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> ^Matrix {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return nil }
	if o.impl == nil || o.impl_free != matrix_free { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Matrix)(o.impl)
}

@(private = "file") ro :: #force_inline proc "contextless" () -> i32 { return jsb.iface_of(DOMMatrixReadOnly) }
@(private = "file") rw :: #force_inline proc "contextless" () -> i32 { return jsb.iface_of(DOMMatrix) }

// the matrix behind a value that is a DOMMatrixReadOnly, else nil (no exception)
@(private = "file")
matrix_peek :: proc "contextless" (v: wj.JSValue) -> ^Matrix {
	o := wj.wj_unwrap(v, ro())
	return o != nil && o.impl != nil && o.impl_free == matrix_free ? (^Matrix)(o.impl) : nil
}

// A DOMMatrixInit as a matrix (Geometry §"validate and fixup a DOMMatrixInit"): a and m11 name the same number (and
// the other aliased pairs), a 3D member that is not the identity's makes the matrix 3D unless is2D says otherwise, and
// is2D true with such a member is a TypeError.
@(private = "file")
matrix_from_init :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^Matrix) -> bool {
	d: wjd_DOMMatrixInit
	if !wjd_DOMMatrixInit_from(ctx, v, &d) { return false }
	b := &d.base
	ok := true
	out.m = IDENT
	pair :: proc "contextless" (ok: ^bool, slot: ^f64, a: f64, ha: bool, c: f64, hc: bool) {
		if ha && hc && !(a == c || (is_nan(a) && is_nan(c))) { ok^ = false }
		if ha { slot^ = a } else if hc { slot^ = c }
	}
	pair(&ok, &out.m[0], b.a, b.has_a, b.m11, b.has_m11)
	pair(&ok, &out.m[1], b.b, b.has_b, b.m12, b.has_m12)
	pair(&ok, &out.m[4], b.c, b.has_c, b.m21, b.has_m21)
	pair(&ok, &out.m[5], b.d, b.has_d, b.m22, b.has_m22)
	pair(&ok, &out.m[12], b.e, b.has_e, b.m41, b.has_m41)
	pair(&ok, &out.m[13], b.f, b.has_f, b.m42, b.has_m42)
	if !ok {
		wjd_DOMMatrixInit_free(ctx, &d)
		wj.JS_ThrowTypeError(ctx, "Failed to convert the matrix: a and m11 (b and m12, c and m21, d and m22, e and m41, f and m42) must have the same value.")
		return false
	}
	out.m[2] = d.m13; out.m[3] = d.m14; out.m[6] = d.m23; out.m[7] = d.m24
	out.m[8] = d.m31; out.m[9] = d.m32; out.m[10] = d.m33; out.m[11] = d.m34
	out.m[14] = d.m43; out.m[15] = d.m44
	not2d := false
	for i in 0 ..< 16 {
		if !is_2d_slot(i) && out.m[i] != IDENT[i] { not2d = true }
	}
	out.is2d = d.has_is2D ? d.is2D : !not2d
	has_2d := d.has_is2D && d.is2D
	wjd_DOMMatrixInit_free(ctx, &d)
	if has_2d && not2d {
		wj.JS_ThrowTypeError(ctx, "Failed to convert the matrix: a 2D matrix cannot have a non-identity value for m13, m14, m23, m24, m31, m32, m33, m34, m43 or m44.")
		return false
	}
	return true
}

// an argument that is a matrix or a DOMMatrixInit
@(private = "file")
matrix_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^Matrix) -> bool {
	if p := matrix_peek(v); p != nil { out^ = p^; return true }
	return matrix_from_init(ctx, v, out)
}

// ---- parsing a transform list ("translate(10px, 5px) rotate(45deg)") ----

@(private = "file") is_ws :: #force_inline proc "contextless" (c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }
@(private = "file") is_digit :: #force_inline proc "contextless" (c: u8) -> bool { return c >= '0' && c <= '9' }
@(private = "file") is_alpha :: #force_inline proc "contextless" (c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

@(private = "file")
trim_ws :: proc "contextless" (s: []u8) -> []u8 {
	s := s
	for len(s) > 0 && is_ws(s[0]) { s = s[1:] }
	for len(s) > 0 && is_ws(s[len(s) - 1]) { s = s[:len(s) - 1] }
	return s
}

@(private = "file")
ascii_ieq :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		x := a[i]; y := b[i]
		if x >= 'A' && x <= 'Z' { x += 32 }
		if y >= 'A' && y <= 'Z' { y += 32 }
		if x != y { return false }
	}
	return true
}

// a CSS <number> at the start of s: sign, digits, fraction, exponent (an infinity is clamped to the largest double);
// the bytes it took
@(private = "file")
scan_number :: proc "contextless" (s: []u8) -> (v: f64, n: int, ok: bool) {
	q := 0
	if q < len(s) && (s[q] == '+' || s[q] == '-') { q += 1 }
	int_start := q
	for q < len(s) && is_digit(s[q]) { q += 1 }
	any := q > int_start
	if q + 1 < len(s) && s[q] == '.' && is_digit(s[q + 1]) {
		q += 1
		for q < len(s) && is_digit(s[q]) { q += 1 }
		any = true
	}
	if !any { return 0, 0, false }
	if q < len(s) && (s[q] == 'e' || s[q] == 'E') {
		e := q + 1
		if e < len(s) && (s[e] == '+' || s[e] == '-') { e += 1 }
		if e < len(s) && is_digit(s[e]) {
			for e < len(s) && is_digit(s[e]) { e += 1 }
			q = e
		}
	}
	buf: [400]u8
	if q >= len(buf) { return 0, 0, false }
	copy(buf[:], s[:q])
	buf[q] = 0
	v = wj.strtod(&buf[0], nil)
	if v - v != 0 && v == v { v = v > 0 ? DBL_MAX : -DBL_MAX }   // an infinity
	return v, q, true
}

@(private = "file") Arg_Kind :: enum u8 { Number = 'n', Length = 'l', Angle = 'a' }

// One argument of a transform function. Lengths come out in px (only absolute units: a relative one cannot be resolved
// without an element), angles in degrees; a unitless number is a length or an angle only when it is zero.
@(private = "file")
parse_arg :: proc "contextless" (s: []u8, kind: u8) -> (out: f64, ok: bool) {
	c := s
	for len(c) > 0 && is_ws(c[0]) { c = c[1:] }
	v, n := scan_number(c) or_return
	c = c[n:]
	un := 0
	for un < len(c) && (is_alpha(c[un]) || c[un] == '%') { un += 1 }
	unit_raw := c[:un]
	rest := c[un:]
	for len(rest) > 0 && is_ws(rest[0]) { rest = rest[1:] }
	if len(rest) != 0 || un >= 8 { return 0, false }
	switch Arg_Kind(kind) {
	case .Number:
		if un != 0 { return 0, false }
		return v, true
	case .Length:
		if un == 0 { return 0, v == 0 }
		switch {
		case ascii_ieq(unit_raw, "px"): return v, true
		case ascii_ieq(unit_raw, "cm"): return v * 96 / 2.54, true
		case ascii_ieq(unit_raw, "mm"): return v * 96 / 25.4, true
		case ascii_ieq(unit_raw, "q"):  return v * 96 / 101.6, true
		case ascii_ieq(unit_raw, "in"): return v * 96, true
		case ascii_ieq(unit_raw, "pt"): return v * 96 / 72, true
		case ascii_ieq(unit_raw, "pc"): return v * 16, true
		}
		return 0, false
	case .Angle:
		if un == 0 { return 0, v == 0 }
		switch {
		case ascii_ieq(unit_raw, "deg"):  return v, true
		case ascii_ieq(unit_raw, "rad"):  return v * 180 / PI, true
		case ascii_ieq(unit_raw, "grad"): return v * 0.9, true
		case ascii_ieq(unit_raw, "turn"): return v * 360, true
		}
		return 0, false
	}
	return 0, false
}

@(private = "file")
TF :: enum {
	Matrix, Matrix3d, Translate, TranslateX, TranslateY, TranslateZ, Translate3d,
	Scale, ScaleX, ScaleY, ScaleZ, Scale3d,
	Rotate, RotateX, RotateY, RotateZ, Rotate3d,
	Skew, SkewX, SkewY, Perspective,
}

// name, the number of arguments (min, max) and their kinds; three_d: the function makes the matrix 3D
@(private = "file")
TF_Def :: struct { name: string, min, max: int, kinds: string, three_d: bool }

@(private = "file")
TF_DEFS := [TF]TF_Def{
	.Matrix      = {"matrix", 6, 6, "nnnnnn", false},
	.Matrix3d    = {"matrix3d", 16, 16, "nnnnnnnnnnnnnnnn", true},
	.Translate   = {"translate", 1, 2, "ll", false},
	.TranslateX  = {"translatex", 1, 1, "l", false},
	.TranslateY  = {"translatey", 1, 1, "l", false},
	.TranslateZ  = {"translatez", 1, 1, "l", true},
	.Translate3d = {"translate3d", 3, 3, "lll", true},
	.Scale       = {"scale", 1, 2, "nn", false},
	.ScaleX      = {"scalex", 1, 1, "n", false},
	.ScaleY      = {"scaley", 1, 1, "n", false},
	.ScaleZ      = {"scalez", 1, 1, "n", true},
	.Scale3d     = {"scale3d", 3, 3, "nnn", true},
	.Rotate      = {"rotate", 1, 1, "a", false},
	.RotateX     = {"rotatex", 1, 1, "a", true},
	.RotateY     = {"rotatey", 1, 1, "a", true},
	.RotateZ     = {"rotatez", 1, 1, "a", true},
	.Rotate3d    = {"rotate3d", 4, 4, "nnna", true},
	.Skew        = {"skew", 1, 2, "aa", false},
	.SkewX       = {"skewx", 1, 1, "a", false},
	.SkewY       = {"skewy", 1, 1, "a", false},
	.Perspective = {"perspective", 1, 1, "l", true},
}

// The matrix of a function and its arguments.
@(private = "file")
transform_function :: proc "contextless" (id: TF, a: ^[16]f64, na: int) -> (t: M16, ok: bool) {
	t = IDENT
	switch id {
	case .Matrix:      t[0] = a[0]; t[1] = a[1]; t[4] = a[2]; t[5] = a[3]; t[12] = a[4]; t[13] = a[5]
	case .Matrix3d:    t = a^
	case .Translate:   t = m_translate(a[0], na > 1 ? a[1] : 0, 0)
	case .TranslateX:  t = m_translate(a[0], 0, 0)
	case .TranslateY:  t = m_translate(0, a[0], 0)
	case .TranslateZ:  t = m_translate(0, 0, a[0])
	case .Translate3d: t = m_translate(a[0], a[1], a[2])
	case .Scale:       t = m_scale(a[0], na > 1 ? a[1] : a[0], 1)
	case .ScaleX:      t = m_scale(a[0], 1, 1)
	case .ScaleY:      t = m_scale(1, a[0], 1)
	case .ScaleZ:      t = m_scale(1, 1, a[0])
	case .Scale3d:     t = m_scale(a[0], a[1], a[2])
	case .Rotate, .RotateZ: t = m_rotate(0, 0, 1, a[0])
	case .RotateX:     t = m_rotate(1, 0, 0, a[0])
	case .RotateY:     t = m_rotate(0, 1, 0, a[0])
	case .Rotate3d:    t = m_rotate(a[0], a[1], a[2], a[3])
	case .Skew:        t = m_skew(a[0], na > 1 ? a[1] : 0)
	case .SkewX:       t = m_skew(a[0], 0)
	case .SkewY:       t = m_skew(0, a[0])
	case .Perspective:
		if a[0] < 0 { return t, false }
		t[11] = a[0] == 0 ? 0 : -1 / a[0]
	}
	return t, true
}

@(private = "file")
index_byte :: proc "contextless" (s: []u8, c: u8) -> int {
	for i in 0 ..< len(s) { if s[i] == c { return i } }
	return -1
}

// "none", an empty string or a list of transform functions (the product of their matrices, left to right). False for
// anything else.
@(private = "file")
parse_transform :: proc "contextless" (s: []u8) -> (out: Matrix, ok: bool) {
	out = {IDENT, true}
	c := trim_ws(s)
	if len(c) == 0 { return out, true }
	if ascii_ieq(c, "none") { return out, true }
	for len(c) > 0 {
		nl := 0
		for nl < len(c) && (is_alpha(c[nl]) || is_digit(c[nl])) { nl += 1 }
		if nl == 0 || nl >= 16 || nl >= len(c) || c[nl] != '(' { return out, false }
		name := c[:nl]
		c = c[nl + 1:]
		close := index_byte(c, ')')
		if close < 0 { return out, false }
		id: TF
		found := false
		for d, k in TF_DEFS { if ascii_ieq(name, d.name) { id = k; found = true; break } }
		if !found { return out, false }
		def := TF_DEFS[id]
		a: [16]f64
		na := 0
		args := c[:close]
		for {
			comma := index_byte(args, ',')
			one := comma >= 0 ? args[:comma] : args
			if na >= def.max { return out, false }
			// perspective(none) is perspective(0): the identity
			if id == .Perspective && ascii_ieq(trim_ws(one), "none") {
				a[na] = 0
			} else {
				v, aok := parse_arg(one, def.kinds[na])
				if !aok { return out, false }
				a[na] = v
			}
			na += 1
			if comma < 0 { break }
			args = args[comma + 1:]
		}
		if na < def.min { return out, false }
		t, tok := transform_function(id, &a, na)
		if !tok { return out, false }
		out.m = mul4(out.m, t)
		if def.three_d { out.is2d = false }
		c = c[close + 1:]
		for len(c) > 0 && is_ws(c[0]) { c = c[1:] }
	}
	return out, true
}

@(private = "file")
matrix_from_string :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^Matrix) -> bool {
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { return false }
	ok: bool
	out^, ok = parse_transform(wj.str_slice(s))
	wj.wj_str_free(ctx, &s)
	if !ok { wj.wj_throw_dom(ctx, "SyntaxError", "Failed to parse transform list.") }
	return ok
}

// ---- constructors and factories ----

@(private = "file") Seq :: struct { v: [16]f64, n: int }

@(private = "file")
seq_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	s := (^Seq)(opaque)
	d: f64
	if !wj.wj_to_double(ctx, item, &d, false) { return false }
	if s.n < 16 { s.v[s.n] = d }
	s.n += 1
	return true
}

// 6 numbers (a b c d e f) make a 2D matrix, 16 a 3D one
@(private = "file")
matrix_from_numbers :: proc "contextless" (ctx: ^wj.Context, v: ^[16]f64, n: int, out: ^Matrix, what: cstring, what_on: cstring = nil) -> bool {
	out.m = IDENT
	if n == 6 {
		for i in 0 ..< 6 { out.m[IDX_2D[i]] = v[i] }
		out.is2d = true
	} else if n == 16 {
		out.m = v^
		out.is2d = false
	} else {
		MSG :: "The sequence must contain 6 elements for a 2D matrix or 16 elements for a 3D matrix."
		if what_on != nil {
			wj.JS_ThrowTypeError(ctx, "Failed to execute '%s' on '%s': " + MSG, what, what_on)
		} else {
			wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': " + MSG, what)
		}
		return false
	}
	return true
}

@(private = "file")
matrix_construct :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': Please use the 'new' operator, this DOM object constructor cannot be called as a function.", name)
	}
	g := Matrix{IDENT, true}
	init := wj.arg(argc, argv, 0)
	if !wj.is_undefined(init) {
		iterable := wj.is_object(init) ? wj.web_is_iterable(ctx, init) : 0
		if iterable < 0 { return wj.EXCEPTION }
		if iterable != 0 {
			s: Seq
			if !wj.web_for_of(ctx, init, seq_item, &s) { return wj.EXCEPTION }
			if !matrix_from_numbers(ctx, &s.v, s.n, &g, name) { return wj.EXCEPTION }
		} else {
			if !wj.is_window() { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': Cannot parse a string in a worker.", name) }
			if !matrix_from_string(ctx, init, &g) { return wj.EXCEPTION }
		}
	}
	return matrix_new(ctx, iface, new_target, g.m, g.is2d)
}

@(export, link_name = "wjr_DOMMatrixReadOnly_constructor")
wjr_DOMMatrixReadOnly_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_construct(ctx, nt, argc, argv, ro(), "DOMMatrixReadOnly") }
@(export, link_name = "wjr_DOMMatrix_constructor")
wjr_DOMMatrix_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_construct(ctx, nt, argc, argv, rw(), "DOMMatrix") }

@(private = "file")
matrix_from_matrix :: proc "contextless" (ctx: ^wj.Context, iface: i32, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	g: Matrix
	if !matrix_arg(ctx, wj.arg(argc, argv, 0), &g) { return wj.EXCEPTION }
	return matrix_new(ctx, iface, wj.UNDEFINED, g.m, g.is2d)
}

@(export, link_name = "wjr_DOMMatrixReadOnly_static_fromMatrix")
wjr_DOMMatrixReadOnly_static_fromMatrix :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_from_matrix(ctx, ro(), argc, argv) }
@(export, link_name = "wjr_DOMMatrix_static_fromMatrix")
wjr_DOMMatrix_static_fromMatrix :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_from_matrix(ctx, rw(), argc, argv) }

@(private = "file")
matrix_from_floats :: proc "contextless" (ctx: ^wj.Context, iface: i32, iface_name: cstring, argc: i32, argv: [^]wj.JSValue, f64s: bool) -> wj.JSValue {
	fn: cstring = f64s ? "fromFloat64Array" : "fromFloat32Array"
	type: cstring = f64s ? "Float64Array" : "Float32Array"
	what: [96]u8
	wj.snprintf(&what[0], len(what), "%s.%s", iface_name, fn)
	if argc < 1 { return wj.wj_throw_arity(ctx, cstring(&what[0]), 1, argc) }
	want := f64s ? wj.Typed_Array.Float64 : wj.Typed_Array.Float32
	if wj.wj_typed_array_type(argv[0]) != i32(want) {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute '%s' on '%s': parameter 1 is not of type '%s'.", fn, iface_name, type)
	}
	p: [^]u8
	bytes: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &p, &bytes, wj.BS_VIEW_ONLY, cstring(&what[0])) { return wj.EXCEPTION }
	width := uint(f64s ? 8 : 4)
	count := bytes / width
	v: [16]f64
	if count == 6 || count == 16 {
		for i in 0 ..< count {
			if f64s {
				v[i] = (^f64)(rawptr(p[i * 8:]))^
			} else {
				v[i] = f64((^f32)(rawptr(p[i * 4:]))^)
			}
		}
	}
	g: Matrix
	if !matrix_from_numbers(ctx, &v, int(count), &g, fn, iface_name) { return wj.EXCEPTION }
	return matrix_new(ctx, iface, wj.UNDEFINED, g.m, g.is2d)
}

@(export, link_name = "wjr_DOMMatrixReadOnly_static_fromFloat32Array")
wjr_DOMMatrixReadOnly_static_fromFloat32Array :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_from_floats(ctx, ro(), "DOMMatrixReadOnly", argc, argv, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_static_fromFloat64Array")
wjr_DOMMatrixReadOnly_static_fromFloat64Array :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_from_floats(ctx, ro(), "DOMMatrixReadOnly", argc, argv, true) }
@(export, link_name = "wjr_DOMMatrix_static_fromFloat32Array")
wjr_DOMMatrix_static_fromFloat32Array :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_from_floats(ctx, rw(), "DOMMatrix", argc, argv, false) }
@(export, link_name = "wjr_DOMMatrix_static_fromFloat64Array")
wjr_DOMMatrix_static_fromFloat64Array :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return matrix_from_floats(ctx, rw(), "DOMMatrix", argc, argv, true) }

// ---- attributes ----

@(private = "file")
mat_get :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, idx: int) -> wj.JSValue {
	s := matrix_of(ctx, this_val, iface)
	return s != nil ? wj.new_float64(ctx, s.m[idx]) : wj.EXCEPTION
}

// A 3D attribute set to anything but its identity value makes the matrix 3D.
@(private = "file")
mat_set :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, idx: int) -> wj.JSValue {
	s := matrix_of(ctx, this_val, rw())
	if s == nil { return wj.EXCEPTION }
	x: f64
	if !wj.wj_to_double(ctx, v, &x, false) { return wj.EXCEPTION }
	if !is_2d_slot(idx) && x != IDENT[idx] { s.is2d = false }
	s.m[idx] = x
	return wj.UNDEFINED
}

@(private = "file") G :: wj.Context
@(private = "file") V :: wj.JSValue

@(export, link_name = "wjr_DOMMatrixReadOnly_get_a")   wjr_DOMMatrixReadOnly_get_a   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 0) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_b")   wjr_DOMMatrixReadOnly_get_b   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 1) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_c")   wjr_DOMMatrixReadOnly_get_c   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 4) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_d")   wjr_DOMMatrixReadOnly_get_d   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 5) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_e")   wjr_DOMMatrixReadOnly_get_e   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 12) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_f")   wjr_DOMMatrixReadOnly_get_f   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 13) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m11") wjr_DOMMatrixReadOnly_get_m11 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 0) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m12") wjr_DOMMatrixReadOnly_get_m12 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 1) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m13") wjr_DOMMatrixReadOnly_get_m13 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 2) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m14") wjr_DOMMatrixReadOnly_get_m14 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 3) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m21") wjr_DOMMatrixReadOnly_get_m21 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 4) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m22") wjr_DOMMatrixReadOnly_get_m22 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 5) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m23") wjr_DOMMatrixReadOnly_get_m23 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 6) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m24") wjr_DOMMatrixReadOnly_get_m24 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 7) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m31") wjr_DOMMatrixReadOnly_get_m31 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 8) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m32") wjr_DOMMatrixReadOnly_get_m32 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 9) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m33") wjr_DOMMatrixReadOnly_get_m33 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 10) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m34") wjr_DOMMatrixReadOnly_get_m34 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 11) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m41") wjr_DOMMatrixReadOnly_get_m41 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 12) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m42") wjr_DOMMatrixReadOnly_get_m42 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 13) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m43") wjr_DOMMatrixReadOnly_get_m43 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 14) }
@(export, link_name = "wjr_DOMMatrixReadOnly_get_m44") wjr_DOMMatrixReadOnly_get_m44 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, ro(), 15) }

// DOMMatrix redeclares them as read-write attributes
@(export, link_name = "wjr_DOMMatrix_get_a")   wjr_DOMMatrix_get_a   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 0) }
@(export, link_name = "wjr_DOMMatrix_get_b")   wjr_DOMMatrix_get_b   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 1) }
@(export, link_name = "wjr_DOMMatrix_get_c")   wjr_DOMMatrix_get_c   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 4) }
@(export, link_name = "wjr_DOMMatrix_get_d")   wjr_DOMMatrix_get_d   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 5) }
@(export, link_name = "wjr_DOMMatrix_get_e")   wjr_DOMMatrix_get_e   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 12) }
@(export, link_name = "wjr_DOMMatrix_get_f")   wjr_DOMMatrix_get_f   :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 13) }
@(export, link_name = "wjr_DOMMatrix_get_m11") wjr_DOMMatrix_get_m11 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 0) }
@(export, link_name = "wjr_DOMMatrix_get_m12") wjr_DOMMatrix_get_m12 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 1) }
@(export, link_name = "wjr_DOMMatrix_get_m13") wjr_DOMMatrix_get_m13 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 2) }
@(export, link_name = "wjr_DOMMatrix_get_m14") wjr_DOMMatrix_get_m14 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 3) }
@(export, link_name = "wjr_DOMMatrix_get_m21") wjr_DOMMatrix_get_m21 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 4) }
@(export, link_name = "wjr_DOMMatrix_get_m22") wjr_DOMMatrix_get_m22 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 5) }
@(export, link_name = "wjr_DOMMatrix_get_m23") wjr_DOMMatrix_get_m23 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 6) }
@(export, link_name = "wjr_DOMMatrix_get_m24") wjr_DOMMatrix_get_m24 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 7) }
@(export, link_name = "wjr_DOMMatrix_get_m31") wjr_DOMMatrix_get_m31 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 8) }
@(export, link_name = "wjr_DOMMatrix_get_m32") wjr_DOMMatrix_get_m32 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 9) }
@(export, link_name = "wjr_DOMMatrix_get_m33") wjr_DOMMatrix_get_m33 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 10) }
@(export, link_name = "wjr_DOMMatrix_get_m34") wjr_DOMMatrix_get_m34 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 11) }
@(export, link_name = "wjr_DOMMatrix_get_m41") wjr_DOMMatrix_get_m41 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 12) }
@(export, link_name = "wjr_DOMMatrix_get_m42") wjr_DOMMatrix_get_m42 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 13) }
@(export, link_name = "wjr_DOMMatrix_get_m43") wjr_DOMMatrix_get_m43 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 14) }
@(export, link_name = "wjr_DOMMatrix_get_m44") wjr_DOMMatrix_get_m44 :: proc "c" (c: ^G, t: V) -> V { return mat_get(c, t, rw(), 15) }

@(export, link_name = "wjr_DOMMatrix_set_a")   wjr_DOMMatrix_set_a   :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 0) }
@(export, link_name = "wjr_DOMMatrix_set_b")   wjr_DOMMatrix_set_b   :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 1) }
@(export, link_name = "wjr_DOMMatrix_set_c")   wjr_DOMMatrix_set_c   :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 4) }
@(export, link_name = "wjr_DOMMatrix_set_d")   wjr_DOMMatrix_set_d   :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 5) }
@(export, link_name = "wjr_DOMMatrix_set_e")   wjr_DOMMatrix_set_e   :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 12) }
@(export, link_name = "wjr_DOMMatrix_set_f")   wjr_DOMMatrix_set_f   :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 13) }
@(export, link_name = "wjr_DOMMatrix_set_m11") wjr_DOMMatrix_set_m11 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 0) }
@(export, link_name = "wjr_DOMMatrix_set_m12") wjr_DOMMatrix_set_m12 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 1) }
@(export, link_name = "wjr_DOMMatrix_set_m13") wjr_DOMMatrix_set_m13 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 2) }
@(export, link_name = "wjr_DOMMatrix_set_m14") wjr_DOMMatrix_set_m14 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 3) }
@(export, link_name = "wjr_DOMMatrix_set_m21") wjr_DOMMatrix_set_m21 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 4) }
@(export, link_name = "wjr_DOMMatrix_set_m22") wjr_DOMMatrix_set_m22 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 5) }
@(export, link_name = "wjr_DOMMatrix_set_m23") wjr_DOMMatrix_set_m23 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 6) }
@(export, link_name = "wjr_DOMMatrix_set_m24") wjr_DOMMatrix_set_m24 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 7) }
@(export, link_name = "wjr_DOMMatrix_set_m31") wjr_DOMMatrix_set_m31 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 8) }
@(export, link_name = "wjr_DOMMatrix_set_m32") wjr_DOMMatrix_set_m32 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 9) }
@(export, link_name = "wjr_DOMMatrix_set_m33") wjr_DOMMatrix_set_m33 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 10) }
@(export, link_name = "wjr_DOMMatrix_set_m34") wjr_DOMMatrix_set_m34 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 11) }
@(export, link_name = "wjr_DOMMatrix_set_m41") wjr_DOMMatrix_set_m41 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 12) }
@(export, link_name = "wjr_DOMMatrix_set_m42") wjr_DOMMatrix_set_m42 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 13) }
@(export, link_name = "wjr_DOMMatrix_set_m43") wjr_DOMMatrix_set_m43 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 14) }
@(export, link_name = "wjr_DOMMatrix_set_m44") wjr_DOMMatrix_set_m44 :: proc "c" (c: ^G, t: V, v: V) -> V { return mat_set(c, t, v, 15) }

@(export, link_name = "wjr_DOMMatrixReadOnly_get_is2D")
wjr_DOMMatrixReadOnly_get_is2D :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	s := matrix_of(ctx, this_val, ro())
	return s != nil ? wj.new_bool(s.is2d) : wj.EXCEPTION
}

@(export, link_name = "wjr_DOMMatrixReadOnly_get_isIdentity")
wjr_DOMMatrixReadOnly_get_isIdentity :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	s := matrix_of(ctx, this_val, ro())
	if s == nil { return wj.EXCEPTION }
	return wj.new_bool(s.m == IDENT)
}

// ---- operations ----

@(private = "file")
Op :: enum {
	Translate, Scale, Scale_Nonuniform, Scale3d, Rotate, Rotate_From_Vector, Rotate_Axis_Angle,
	Skew_X, Skew_Y, Flip_X, Flip_Y,
}

// origin translation * scale * back translation
@(private = "file")
scale_around :: proc "contextless" (sx, sy, sz, ox, oy, oz: f64) -> M16 {
	return mul4(mul4(m_translate(ox, oy, oz), m_scale(sx, sy, sz)), m_translate(-ox, -oy, -oz))
}

// The matrix an operation multiplies by (arguments converted in order, undefined is the default), and whether it makes
// the matrix 3D.
@(private = "file")
op_matrix :: proc "contextless" (ctx: ^wj.Context, op: Op, argc: i32, argv: [^]wj.JSValue) -> (t: M16, is3d: bool, ok: bool) {
	a: [6]f64
	t = IDENT
	n :: num_arg
	switch op {
	case .Translate:
		if !n(ctx, argc, argv, 0, 0, &a[0]) || !n(ctx, argc, argv, 1, 0, &a[1]) || !n(ctx, argc, argv, 2, 0, &a[2]) { return }
		t = m_translate(a[0], a[1], a[2])
		is3d = a[2] != 0
	case .Scale:
		if !n(ctx, argc, argv, 0, 1, &a[0]) { return }
		// scaleY has no default: it is scaleX when absent
		if !n(ctx, argc, argv, 1, a[0], &a[1]) || !n(ctx, argc, argv, 2, 1, &a[2]) || !n(ctx, argc, argv, 3, 0, &a[3]) ||
		   !n(ctx, argc, argv, 4, 0, &a[4]) || !n(ctx, argc, argv, 5, 0, &a[5]) { return }
		t = scale_around(a[0], a[1], a[2], a[3], a[4], a[5])
		is3d = a[2] != 1 || a[5] != 0
	case .Scale_Nonuniform:
		if !n(ctx, argc, argv, 0, 1, &a[0]) || !n(ctx, argc, argv, 1, 1, &a[1]) { return }
		t = m_scale(a[0], a[1], 1)
	case .Scale3d:
		if !n(ctx, argc, argv, 0, 1, &a[0]) || !n(ctx, argc, argv, 1, 0, &a[1]) || !n(ctx, argc, argv, 2, 0, &a[2]) || !n(ctx, argc, argv, 3, 0, &a[3]) { return }
		t = scale_around(a[0], a[0], a[0], a[1], a[2], a[3])
		is3d = true
	case .Rotate:
		rx, ry, rz: f64
		has_y := present(argc, argv, 1)
		has_z := present(argc, argv, 2)
		if !n(ctx, argc, argv, 0, 0, &rx) { return }
		if !has_y && !has_z {
			rz = rx; rx = 0
		} else if !n(ctx, argc, argv, 1, 0, &ry) || !n(ctx, argc, argv, 2, 0, &rz) {
			return
		}
		if rz != 0 { t = mul4(t, m_rotate(0, 0, 1, rz)) }
		if ry != 0 { t = mul4(t, m_rotate(0, 1, 0, ry)) }
		if rx != 0 { t = mul4(t, m_rotate(1, 0, 0, rx)) }
		is3d = rx != 0 || ry != 0
	case .Rotate_From_Vector:
		if !n(ctx, argc, argv, 0, 0, &a[0]) || !n(ctx, argc, argv, 1, 0, &a[1]) { return }
		if !(a[0] == 0 && a[1] == 0) { t = m_rotate(0, 0, 1, wj.libm_atan2(a[1], a[0]) * 180 / PI) }
	case .Rotate_Axis_Angle:
		if !n(ctx, argc, argv, 0, 0, &a[0]) || !n(ctx, argc, argv, 1, 0, &a[1]) || !n(ctx, argc, argv, 2, 0, &a[2]) || !n(ctx, argc, argv, 3, 0, &a[3]) { return }
		t = m_rotate(a[0], a[1], a[2], a[3])
		is3d = a[0] != 0 || a[1] != 0
	case .Skew_X:
		if !n(ctx, argc, argv, 0, 0, &a[0]) { return }
		t = m_skew(a[0], 0)
	case .Skew_Y:
		if !n(ctx, argc, argv, 0, 0, &a[0]) { return }
		t = m_skew(0, a[0])
	case .Flip_X: t = m_scale(-1, 1, 1)
	case .Flip_Y: t = m_scale(1, -1, 1)
	}
	return t, is3d, true
}

// `this` changed in place (the ...Self methods of DOMMatrix, returning `this`), or a new DOMMatrix
@(private = "file")
matrix_result :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, s: ^Matrix, r: M16, is2d: bool, self: bool) -> wj.JSValue {
	if self {
		s^ = {r, is2d}
		return wj.JS_DupValue(ctx, this_val)
	}
	return matrix_new(ctx, rw(), wj.UNDEFINED, r, is2d)
}

// this * the operation's matrix
@(private = "file")
matrix_apply :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, op: Op, argc: i32, argv: [^]wj.JSValue, self: bool) -> wj.JSValue {
	s := matrix_of(ctx, this_val, self ? rw() : ro())
	if s == nil { return wj.EXCEPTION }
	t, is3d, ok := op_matrix(ctx, op, argc, argv)
	if !ok { return wj.EXCEPTION }
	return matrix_result(ctx, this_val, s, mul4(s.m, t), s.is2d && !is3d, self)
}

@(private = "file") A :: [^]wj.JSValue

@(export, link_name = "wjr_DOMMatrixReadOnly_translate")         wjr_DOMMatrixReadOnly_translate         :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Translate, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_scale")             wjr_DOMMatrixReadOnly_scale             :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Scale, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_scaleNonUniform")   wjr_DOMMatrixReadOnly_scaleNonUniform   :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Scale_Nonuniform, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_scale3d")           wjr_DOMMatrixReadOnly_scale3d           :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Scale3d, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_rotate")            wjr_DOMMatrixReadOnly_rotate            :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Rotate, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_rotateFromVector")  wjr_DOMMatrixReadOnly_rotateFromVector  :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Rotate_From_Vector, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_rotateAxisAngle")   wjr_DOMMatrixReadOnly_rotateAxisAngle   :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Rotate_Axis_Angle, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_skewX")             wjr_DOMMatrixReadOnly_skewX             :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Skew_X, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_skewY")             wjr_DOMMatrixReadOnly_skewY             :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Skew_Y, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_flipX")             wjr_DOMMatrixReadOnly_flipX             :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Flip_X, n, a, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_flipY")             wjr_DOMMatrixReadOnly_flipY             :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Flip_Y, n, a, false) }

@(export, link_name = "wjr_DOMMatrix_translateSelf")             wjr_DOMMatrix_translateSelf             :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Translate, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_scaleSelf")                 wjr_DOMMatrix_scaleSelf                 :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Scale, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_scale3dSelf")               wjr_DOMMatrix_scale3dSelf               :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Scale3d, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_rotateSelf")                wjr_DOMMatrix_rotateSelf                :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Rotate, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_rotateFromVectorSelf")      wjr_DOMMatrix_rotateFromVectorSelf      :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Rotate_From_Vector, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_rotateAxisAngleSelf")       wjr_DOMMatrix_rotateAxisAngleSelf       :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Rotate_Axis_Angle, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_skewXSelf")                 wjr_DOMMatrix_skewXSelf                 :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Skew_X, n, a, true) }
@(export, link_name = "wjr_DOMMatrix_skewYSelf")                 wjr_DOMMatrix_skewYSelf                 :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_apply(c, t, .Skew_Y, n, a, true) }

// this * other, or other * this (preMultiplySelf)
@(private = "file")
matrix_multiply :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, self, pre: bool) -> wj.JSValue {
	s := matrix_of(ctx, this_val, self ? rw() : ro())
	if s == nil { return wj.EXCEPTION }
	o: Matrix
	if !matrix_arg(ctx, wj.arg(argc, argv, 0), &o) { return wj.EXCEPTION }
	r := pre ? mul4(o.m, s.m) : mul4(s.m, o.m)
	return matrix_result(ctx, this_val, s, r, s.is2d && o.is2d, self)
}

@(export, link_name = "wjr_DOMMatrixReadOnly_multiply")  wjr_DOMMatrixReadOnly_multiply  :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_multiply(c, t, n, a, false, false) }
@(export, link_name = "wjr_DOMMatrix_multiplySelf")      wjr_DOMMatrix_multiplySelf      :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_multiply(c, t, n, a, true, false) }
@(export, link_name = "wjr_DOMMatrix_preMultiplySelf")   wjr_DOMMatrix_preMultiplySelf   :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_multiply(c, t, n, a, true, true) }

// A matrix that cannot be inverted becomes all NaN and 3D.
@(private = "file")
matrix_invert :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, self: bool) -> wj.JSValue {
	s := matrix_of(ctx, this_val, self ? rw() : ro())
	if s == nil { return wj.EXCEPTION }
	r, ok := invert4(s.m)
	is2d := s.is2d
	if !ok {
		for i in 0 ..< 16 { r[i] = NAN }
		is2d = false
	}
	return matrix_result(ctx, this_val, s, r, is2d, self)
}

@(export, link_name = "wjr_DOMMatrixReadOnly_inverse") wjr_DOMMatrixReadOnly_inverse :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_invert(c, t, false) }
@(export, link_name = "wjr_DOMMatrix_invertSelf")      wjr_DOMMatrix_invertSelf      :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_invert(c, t, true) }

@(export, link_name = "wjr_DOMMatrix_setMatrixValue")
wjr_DOMMatrix_setMatrixValue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := matrix_of(ctx, this_val, rw())
	if s == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "DOMMatrix.setMatrixValue", 1, argc) }
	g: Matrix
	if !matrix_from_string(ctx, argv[0], &g) { return wj.EXCEPTION }
	s^ = g
	return wj.JS_DupValue(ctx, this_val)
}

// ---- conversions ----

@(private = "file")
matrix_floats :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, f64s: bool) -> wj.JSValue {
	s := matrix_of(ctx, this_val, ro())
	if s == nil { return wj.EXCEPTION }
	ab: wj.JSValue
	if f64s {
		ab = wj.JS_NewArrayBufferCopy(ctx, ([^]u8)(rawptr(&s.m[0])), size_of(M16))
	} else {
		f: [16]f32
		for i in 0 ..< 16 { f[i] = f32(s.m[i]) }
		ab = wj.JS_NewArrayBufferCopy(ctx, ([^]u8)(rawptr(&f[0])), size_of(f))
	}
	if wj.is_exception(ab) { return ab }
	arr := wj.JS_NewTypedArray(ctx, 1, &ab, i32(f64s ? wj.Typed_Array.Float64 : wj.Typed_Array.Float32))
	wj.JS_FreeValue(ctx, ab)
	return arr
}

@(export, link_name = "wjr_DOMMatrixReadOnly_toFloat32Array") wjr_DOMMatrixReadOnly_toFloat32Array :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_floats(c, t, false) }
@(export, link_name = "wjr_DOMMatrixReadOnly_toFloat64Array") wjr_DOMMatrixReadOnly_toFloat64Array :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return matrix_floats(c, t, true) }

// A byte buffer on the stack for a short serialisation (a matrix3d() is at most ~430 bytes: 16 shortest doubles).
@(private = "file")
Text :: struct { b: [1024]u8, n: int }

@(private = "file")
put :: proc "contextless" (t: ^Text, s: string) {
	k := min(len(s), len(t.b) - t.n)
	copy(t.b[t.n:], s[:k])
	t.n += k
}

// the number as JavaScript writes it (the shortest text that reads back as the same double)
@(private = "file")
put_number :: proc "contextless" (ctx: ^wj.Context, t: ^Text, x: f64) {
	nv := wj.new_float64(ctx, x)
	n: uint
	cs := wj.to_cstring_len(ctx, &n, nv)
	if cs != nil { put(t, string(([^]u8)(rawptr(cs))[:n])); wj.free_cstring(ctx, cs) }
	wj.JS_FreeValue(ctx, nv)
}

@(export, link_name = "wjr_DOMMatrixReadOnly_toString")
wjr_DOMMatrixReadOnly_toString :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := matrix_of(ctx, this_val, ro())
	if s == nil { return wj.EXCEPTION }
	for x in s.m {
		if !is_finite(x) { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'toString' on 'DOMMatrixReadOnly': Cannot be serialized with NaN or Infinity values.") }
	}
	t: Text
	put(&t, s.is2d ? "matrix(" : "matrix3d(")
	n := s.is2d ? 6 : 16
	for i in 0 ..< n {
		if i > 0 { put(&t, ", ") }
		put_number(ctx, &t, s.m[s.is2d ? IDX_2D[i] : i])
	}
	put(&t, ")")
	return wj.new_string_len(ctx, t.b[:t.n])
}

@(export, link_name = "wjr_DOMMatrixReadOnly_toJSON")
wjr_DOMMatrixReadOnly_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := matrix_of(ctx, this_val, ro())
	if s == nil { return wj.EXCEPTION }
	alias := [6]cstring{"a", "b", "c", "d", "e", "f"}
	names := [16]cstring{"m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34", "m41", "m42", "m43", "m44"}
	o := wj.JS_NewObject(ctx)
	for i in 0 ..< 6 { wj.JS_SetPropertyStr(ctx, o, alias[i], wj.new_float64(ctx, s.m[IDX_2D[i]])) }
	for i in 0 ..< 16 { wj.JS_SetPropertyStr(ctx, o, names[i], wj.new_float64(ctx, s.m[i])) }
	wj.JS_SetPropertyStr(ctx, o, "is2D", wj.new_bool(s.is2d))
	wj.JS_SetPropertyStr(ctx, o, "isIdentity", wj.new_bool(s.m == IDENT))
	return o
}

// ---- points ----

@(private = "file")
point_transform :: proc "contextless" (m: M16, p: [4]f64) -> [4]f64 {
	return {
		m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12] * p[3],
		m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13] * p[3],
		m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14] * p[3],
		m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15] * p[3],
	}
}

// the prototype of new.target: subclasses get theirs
@(private = "file")
adopt_new_target :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, new_target: wj.JSValue) {
	if !wj.is_object(new_target) { return }
	proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
	if wj.is_object(proto) { wj.JS_SetPrototype(ctx, obj, proto) }
	wj.JS_FreeValue(ctx, proto)
}

@(private = "file")
point_new :: proc "contextless" (ctx: ^wj.Context, iface: i32, new_target: wj.JSValue, p: [4]f64) -> wj.JSValue {
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, iface, wj.DOM_RECT, wj.UNDEFINED, 0, &d)
	if wj.is_exception(obj) { return obj }
	d.rect = p
	adopt_new_target(ctx, obj, new_target)
	return obj
}

@(private = "file") pro :: #force_inline proc "contextless" () -> i32 { return jsb.iface_of(DOMPointReadOnly) }
@(private = "file") prw :: #force_inline proc "contextless" () -> i32 { return jsb.iface_of(DOMPoint) }
@(private = "file") quad :: #force_inline proc "contextless" () -> i32 { return jsb.iface_of(DOMQuad) }

@(private = "file")
point_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, pro()) }

// the coordinates of a DOMPointReadOnly argument (no exception), or nil
@(private = "file")
point_peek :: proc "contextless" (v: wj.JSValue) -> ^wj.Dom_Impl {
	o := wj.wj_unwrap(v, pro())
	d := o != nil ? (^wj.Dom_Impl)(o.impl) : nil
	return d != nil && d.kind == wj.DOM_RECT ? d : nil
}

// x y z w of a DOMPointInit or a point
@(private = "file")
point_arg :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, p: ^[4]f64) -> bool {
	if d := point_peek(v); d != nil { p^ = d.rect; return true }
	pi: wjd_DOMPointInit
	if !wjd_DOMPointInit_from(ctx, v, &pi) { return false }
	p^ = {pi.x, pi.y, pi.z, pi.w}
	wjd_DOMPointInit_free(ctx, &pi)
	return true
}

@(private = "file")
point_construct :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': Please use the 'new' operator, this DOM object constructor cannot be called as a function.", name)
	}
	v: [4]f64
	if !num_arg(ctx, argc, argv, 0, 0, &v[0]) || !num_arg(ctx, argc, argv, 1, 0, &v[1]) || !num_arg(ctx, argc, argv, 2, 0, &v[2]) || !num_arg(ctx, argc, argv, 3, 1, &v[3]) { return wj.EXCEPTION }
	return point_new(ctx, iface, new_target, v)
}

@(export, link_name = "wjr_DOMPointReadOnly_constructor")
wjr_DOMPointReadOnly_constructor :: proc "c" (c: ^G, nt: V, n: i32, a: A) -> V { return point_construct(c, nt, n, a, pro(), "DOMPointReadOnly") }
@(export, link_name = "wjr_DOMPoint_constructor")
wjr_DOMPoint_constructor :: proc "c" (c: ^G, nt: V, n: i32, a: A) -> V { return point_construct(c, nt, n, a, prw(), "DOMPoint") }

@(private = "file")
point_from :: proc "contextless" (ctx: ^wj.Context, iface: i32, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p: [4]f64
	if !point_arg(ctx, wj.arg(argc, argv, 0), &p) { return wj.EXCEPTION }
	return point_new(ctx, iface, wj.UNDEFINED, p)
}

@(export, link_name = "wjr_DOMPointReadOnly_static_fromPoint") wjr_DOMPointReadOnly_static_fromPoint :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return point_from(c, pro(), n, a) }
@(export, link_name = "wjr_DOMPoint_static_fromPoint")         wjr_DOMPoint_static_fromPoint         :: proc "c" (c: ^G, t: V, n: i32, a: A) -> V { return point_from(c, prw(), n, a) }

@(private = "file")
point_field :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, i: int) -> wj.JSValue {
	d := point_of(ctx, this_val)
	return d != nil ? wj.new_float64(ctx, d.rect[i]) : wj.EXCEPTION
}

@(private = "file")
point_set :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, i: int) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, prw())
	if d == nil { return wj.EXCEPTION }
	x: f64
	if !wj.wj_to_double(ctx, v, &x, false) { return wj.EXCEPTION }
	d.rect[i] = x
	return wj.UNDEFINED
}

@(export, link_name = "wjr_DOMPointReadOnly_get_x") wjr_DOMPointReadOnly_get_x :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 0) }
@(export, link_name = "wjr_DOMPointReadOnly_get_y") wjr_DOMPointReadOnly_get_y :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 1) }
@(export, link_name = "wjr_DOMPointReadOnly_get_z") wjr_DOMPointReadOnly_get_z :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 2) }
@(export, link_name = "wjr_DOMPointReadOnly_get_w") wjr_DOMPointReadOnly_get_w :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 3) }
@(export, link_name = "wjr_DOMPoint_get_x")         wjr_DOMPoint_get_x         :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 0) }
@(export, link_name = "wjr_DOMPoint_get_y")         wjr_DOMPoint_get_y         :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 1) }
@(export, link_name = "wjr_DOMPoint_get_z")         wjr_DOMPoint_get_z         :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 2) }
@(export, link_name = "wjr_DOMPoint_get_w")         wjr_DOMPoint_get_w         :: proc "c" (c: ^G, t: V) -> V { return point_field(c, t, 3) }
@(export, link_name = "wjr_DOMPoint_set_x")         wjr_DOMPoint_set_x         :: proc "c" (c: ^G, t: V, v: V) -> V { return point_set(c, t, v, 0) }
@(export, link_name = "wjr_DOMPoint_set_y")         wjr_DOMPoint_set_y         :: proc "c" (c: ^G, t: V, v: V) -> V { return point_set(c, t, v, 1) }
@(export, link_name = "wjr_DOMPoint_set_z")         wjr_DOMPoint_set_z         :: proc "c" (c: ^G, t: V, v: V) -> V { return point_set(c, t, v, 2) }
@(export, link_name = "wjr_DOMPoint_set_w")         wjr_DOMPoint_set_w         :: proc "c" (c: ^G, t: V, v: V) -> V { return point_set(c, t, v, 3) }

@(export, link_name = "wjr_DOMPointReadOnly_matrixTransform")
wjr_DOMPointReadOnly_matrixTransform :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := point_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	m: Matrix
	if !matrix_arg(ctx, wj.arg(argc, argv, 0), &m) { return wj.EXCEPTION }
	return point_new(ctx, prw(), wj.UNDEFINED, point_transform(m.m, d.rect))
}

@(export, link_name = "wjr_DOMMatrixReadOnly_transformPoint")
wjr_DOMMatrixReadOnly_transformPoint :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	s := matrix_of(ctx, this_val, ro())
	if s == nil { return wj.EXCEPTION }
	p: [4]f64
	if !point_arg(ctx, wj.arg(argc, argv, 0), &p) { return wj.EXCEPTION }
	return point_new(ctx, prw(), wj.UNDEFINED, point_transform(s.m, p))
}

@(export, link_name = "wjr_DOMPointReadOnly_toJSON")
wjr_DOMPointReadOnly_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := point_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, o, "x", wj.new_float64(ctx, d.rect[0]))
	wj.JS_SetPropertyStr(ctx, o, "y", wj.new_float64(ctx, d.rect[1]))
	wj.JS_SetPropertyStr(ctx, o, "z", wj.new_float64(ctx, d.rect[2]))
	wj.JS_SetPropertyStr(ctx, o, "w", wj.new_float64(ctx, d.rect[3]))
	return o
}

// ---- quads ----

// A DOMQuad over four points (x y z w each); its points are DOMPoint objects it keeps.
@(private = "file")
quad_new :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, p: [4][4]f64) -> wj.JSValue {
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, quad(), wj.DOM_VALUES, wj.UNDEFINED, 0, &d)
	if wj.is_exception(obj) { return obj }
	d.values = ([^]wj.JSValue)(wj.libc_calloc(4, size_of(wj.JSValue)))
	if d.values == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	for i in 0 ..< 4 {
		d.values[i] = point_new(ctx, prw(), wj.UNDEFINED, p[i])
		d.n_values = u32(i) + 1
		if wj.is_exception(d.values[i]) { d.values[i] = wj.UNDEFINED; wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	}
	adopt_new_target(ctx, obj, new_target)
	return obj
}

@(export, link_name = "wjr_DOMQuad_constructor")
wjr_DOMQuad_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'DOMQuad': Please use the 'new' operator, this DOM object constructor cannot be called as a function.") }
	p: [4][4]f64
	for i in 0 ..< 4 { if !point_arg(ctx, wj.arg(argc, argv, i32(i)), &p[i]) { return wj.EXCEPTION } }
	return quad_new(ctx, new_target, p)
}

@(export, link_name = "wjr_DOMQuad_static_fromRect")
wjr_DOMQuad_static_fromRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r: wjd_DOMRectInit
	if !wjd_DOMRectInit_from(ctx, wj.arg(argc, argv, 0), &r) { return wj.EXCEPTION }
	p := [4][4]f64{
		{r.x, r.y, 0, 1}, {r.x + r.width, r.y, 0, 1}, {r.x + r.width, r.y + r.height, 0, 1}, {r.x, r.y + r.height, 0, 1},
	}
	wjd_DOMRectInit_free(ctx, &r)
	return quad_new(ctx, wj.UNDEFINED, p)
}

@(export, link_name = "wjr_DOMQuad_static_fromQuad")
wjr_DOMQuad_static_fromQuad :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	q: wjd_DOMQuadInit
	if !wjd_DOMQuadInit_from(ctx, wj.arg(argc, argv, 0), &q) { return wj.EXCEPTION }
	in_ := [4]^wjd_DOMPointInit{&q.p1, &q.p2, &q.p3, &q.p4}
	has := [4]bool{q.has_p1, q.has_p2, q.has_p3, q.has_p4}
	p: [4][4]f64
	for i in 0 ..< 4 {
		if has[i] { p[i] = {in_[i].x, in_[i].y, in_[i].z, in_[i].w} } else { p[i] = {0, 0, 0, 1} }
	}
	wjd_DOMQuadInit_free(ctx, &q)
	return quad_new(ctx, wj.UNDEFINED, p)
}

@(private = "file")
quad_point :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, i: u32) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, quad())
	if d == nil { return wj.EXCEPTION }
	return i < d.n_values ? wj.JS_DupValue(ctx, d.values[i]) : wj.UNDEFINED
}

@(export, link_name = "wjr_DOMQuad_get_p1") wjr_DOMQuad_get_p1 :: proc "c" (c: ^G, t: V) -> V { return quad_point(c, t, 0) }
@(export, link_name = "wjr_DOMQuad_get_p2") wjr_DOMQuad_get_p2 :: proc "c" (c: ^G, t: V) -> V { return quad_point(c, t, 1) }
@(export, link_name = "wjr_DOMQuad_get_p3") wjr_DOMQuad_get_p3 :: proc "c" (c: ^G, t: V) -> V { return quad_point(c, t, 2) }
@(export, link_name = "wjr_DOMQuad_get_p4") wjr_DOMQuad_get_p4 :: proc "c" (c: ^G, t: V) -> V { return quad_point(c, t, 3) }

// the smallest / largest of the four, NaN when one is (Geometry: "NaN-safe minimum / maximum")
@(private = "file")
nan_min :: proc "contextless" (v: [4]f64) -> f64 {
	r := v[0]
	for i in 1 ..< 4 { if is_nan(v[i]) || is_nan(r) { return NAN }; if v[i] < r { r = v[i] } }
	return r
}
@(private = "file")
nan_max :: proc "contextless" (v: [4]f64) -> f64 {
	r := v[0]
	for i in 1 ..< 4 { if is_nan(v[i]) || is_nan(r) { return NAN }; if v[i] > r { r = v[i] } }
	return r
}

@(export, link_name = "wjr_DOMQuad_getBounds")
wjr_DOMQuad_getBounds :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, quad())
	if d == nil { return wj.EXCEPTION }
	xs, ys: [4]f64
	for i in 0 ..< 4 {
		pt := i < int(d.n_values) ? point_peek(d.values[i]) : nil
		xs[i] = pt != nil ? pt.rect[0] : 0
		ys[i] = pt != nil ? pt.rect[1] : 0
	}
	left, top, right, bottom := nan_min(xs), nan_min(ys), nan_max(xs), nan_max(ys)
	return dom_rect_new(ctx, left, top, right - left, bottom - top, false)
}

@(export, link_name = "wjr_DOMQuad_toJSON")
wjr_DOMQuad_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, quad())
	if d == nil { return wj.EXCEPTION }
	names := [4]cstring{"p1", "p2", "p3", "p4"}
	o := wj.JS_NewObject(ctx)
	for i in 0 ..< 4 { wj.JS_SetPropertyStr(ctx, o, names[i], i < int(d.n_values) ? wj.JS_DupValue(ctx, d.values[i]) : wj.UNDEFINED) }
	return o
}
