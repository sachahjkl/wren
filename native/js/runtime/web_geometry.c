/* web_geometry.c: Geometry Interfaces Module Level 1 in the engine: DOMPointReadOnly / DOMPoint, DOMMatrixReadOnly /
 * DOMMatrix and DOMQuad (DOMRect is dom_layout.c). Pure arithmetic, so it runs here and not in the browser: no call
 * crosses the module's boundary. A point is a dom_impl of kind DOM_RECT holding x y z w; a quad is a dom_impl holding its
 * four DOMPoint objects; a matrix is a geo_matrix, its sixteen numbers in column-major order (m11 m12 m13 m14 m21 ... m44,
 * the order of the attributes) and the "2D" flag that says whether it was made from 2D values and has stayed 2D.
 * The 2D canvas takes and gives matrices (web_dommatrix_new_2d); the CSS transform-list parser below knows matrix(),
 * matrix3d(), translate*, scale*, rotate*, skew* and perspective(). */
#include <math.h>
#include <float.h>
#include <stdio.h>
#include "web.h"
#include "dom_internal.h"

#define GEO_PI 3.14159265358979323846

typedef struct geo_matrix {
    double m[16];
    bool   is2d;
} geo_matrix;

static const double IDENT[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
/* a b c d e f in the column-major array */
static const int IDX_2D[6] = { 0, 1, 4, 5, 12, 13 };

static void geo_matrix_free(void *p) { free(p); }

static inline JSValueConst arg_at(int argc, JSValueConst *argv, int i) { return i < argc ? argv[i] : JS_UNDEFINED; }

/* an optional unrestricted double: undefined (or absent) is `def` */
static bool num_arg(JSContext *ctx, int argc, JSValueConst *argv, int i, double def, double *out)
{
    *out = def;
    if (i >= argc || JS_IsUndefined(argv[i])) { return true; }
    return wj_to_double(ctx, argv[i], out, false);
}

static bool present(int argc, JSValueConst *argv, int i) { return i < argc && !JS_IsUndefined(argv[i]); }

/* ---- 4x4 arithmetic ---- */

/* out = a * b (the product applies b first, then a); out may be a or b */
static void mul4(const double *a, const double *b, double *out)
{
    double r[16];
    for (int c = 0; c < 4; c++) {
        for (int row = 0; row < 4; row++) {
            double s = 0;
            for (int k = 0; k < 4; k++) { s += a[k * 4 + row] * b[c * 4 + k]; }
            r[c * 4 + row] = s;
        }
    }
    memcpy(out, r, sizeof r);
}

/* The inverse by cofactors; false when the determinant is zero or not finite. */
static bool invert4(const double *m, double *out)
{
    double inv[16];
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    double det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (det == 0 || !isfinite(det)) { return false; }
    for (int i = 0; i < 16; i++) { out[i] = inv[i] / det; }
    return true;
}

static void m_ident(double *m) { memcpy(m, IDENT, sizeof IDENT); }
static void m_translate(double *m, double x, double y, double z) { m_ident(m); m[12] = x; m[13] = y; m[14] = z; }
static void m_scale(double *m, double x, double y, double z) { m_ident(m); m[0] = x; m[5] = y; m[10] = z; }
static void m_skew(double *m, double ax_deg, double ay_deg)
{
    m_ident(m);
    m[4] = tan(ax_deg * GEO_PI / 180);
    m[1] = tan(ay_deg * GEO_PI / 180);
}

/* The rotation of `deg` degrees around the vector (x, y, z) (CSS Transforms: rotate3d()). Around the z axis the cosine
 * and sine are used as they are (rotate(90deg) has a cos of 6e-17, not the 2e-16 the half angle formula would give). */
static void m_rotate(double *m, double x, double y, double z, double deg)
{
    m_ident(m);
    double len = hypot(hypot(x, y), z);
    if (len == 0) { return; }
    x /= len; y /= len; z /= len;
    if (x == 0 && y == 0) {
        double r = deg * GEO_PI / 180, c = cos(r), s = sin(r) * (z > 0 ? 1 : -1);
        m[0] = c; m[1] = s; m[4] = -s; m[5] = c;
        return;
    }
    double a = deg * GEO_PI / 360;   /* half angle */
    double sc = sin(a) * cos(a), sq = sin(a) * sin(a);
    m[0] = 1 - 2 * (y * y + z * z) * sq; m[1] = 2 * (x * y * sq + z * sc); m[2] = 2 * (x * z * sq - y * sc);
    m[4] = 2 * (x * y * sq - z * sc); m[5] = 1 - 2 * (x * x + z * z) * sq; m[6] = 2 * (y * z * sq + x * sc);
    m[8] = 2 * (x * z * sq + y * sc); m[9] = 2 * (y * z * sq - x * sc); m[10] = 1 - 2 * (x * x + y * y) * sq;
}

/* ---- matrix objects ---- */

static JSValue matrix_new(JSContext *ctx, int iface, JSValueConst new_target, const double *m, bool is2d)
{
    geo_matrix *g = malloc(sizeof *g);
    if (!g) { return JS_ThrowOutOfMemory(ctx); }
    memcpy(g->m, m, sizeof g->m);
    g->is2d = is2d;
    return wj_new_object_for(ctx, iface, new_target, g, geo_matrix_free);
}

JSValue web_dommatrix_new_2d(JSContext *ctx, const double m[6])
{
    double full[16];
    m_ident(full);
    for (int i = 0; i < 6; i++) { full[IDX_2D[i]] = m[i]; }
    return matrix_new(ctx, WJ_IFACE_DOMMatrix, JS_UNDEFINED, full, true);
}

static geo_matrix *matrix_of(JSContext *ctx, JSValueConst this_val, int iface)
{
    wj_obj *o = wj_this(ctx, this_val, iface);
    if (!o) { return NULL; }
    if (!o->impl || o->impl_free != geo_matrix_free) { JS_ThrowTypeError(ctx, "Illegal invocation"); return NULL; }
    return o->impl;
}

/* the matrix behind a value that is a DOMMatrixReadOnly, else NULL (no exception) */
static geo_matrix *matrix_peek(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_DOMMatrixReadOnly);
    return o && o->impl && o->impl_free == geo_matrix_free ? o->impl : NULL;
}

/* A DOMMatrixInit as a matrix (Geometry §"validate and fixup a DOMMatrixInit"): a and m11 name the same number (and
 * the other aliased pairs), a 3D member that is not the identity's makes the matrix 3D unless is2D says otherwise, and
 * is2D true with such a member is a TypeError. */
static bool matrix_from_init(JSContext *ctx, JSValueConst v, geo_matrix *out)
{
    wjd_DOMMatrixInit d;
    if (!wjd_DOMMatrixInit_from(ctx, v, &d)) { return false; }
    wjd_DOMMatrix2DInit *b = &d.base;
    bool ok = true;
    m_ident(out->m);
    #define PAIR(slot, a, ha, c, hc)                                                                  \
        do {                                                                                          \
            if (b->ha && b->hc && !(b->a == b->c || (isnan(b->a) && isnan(b->c)))) { ok = false; }    \
            if (b->ha) { out->m[slot] = b->a; } else if (b->hc) { out->m[slot] = b->c; }               \
        } while (0)
    PAIR(0, a, has_a, m11, has_m11);
    PAIR(1, b, has_b, m12, has_m12);
    PAIR(4, c, has_c, m21, has_m21);
    PAIR(5, d, has_d, m22, has_m22);
    PAIR(12, e, has_e, m41, has_m41);
    PAIR(13, f, has_f, m42, has_m42);
    #undef PAIR
    if (!ok) {
        wjd_DOMMatrixInit_free(ctx, &d);
        JS_ThrowTypeError(ctx, "Failed to convert the matrix: a and m11 (b and m12, c and m21, d and m22, e and m41, f and m42) must have the same value.");
        return false;
    }
    out->m[2] = d.m13; out->m[3] = d.m14; out->m[6] = d.m23; out->m[7] = d.m24;
    out->m[8] = d.m31; out->m[9] = d.m32; out->m[10] = d.m33; out->m[11] = d.m34;
    out->m[14] = d.m43; out->m[15] = d.m44;
    bool not2d = false;
    for (int i = 0; i < 16; i++) {
        bool is_2d_slot = i == 0 || i == 1 || i == 4 || i == 5 || i == 12 || i == 13;
        if (!is_2d_slot && out->m[i] != IDENT[i]) { not2d = true; }
    }
    out->is2d = d.has_is2D ? d.is2D : !not2d;
    bool has_2d = d.has_is2D && d.is2D;
    wjd_DOMMatrixInit_free(ctx, &d);
    if (has_2d && not2d) {
        JS_ThrowTypeError(ctx, "Failed to convert the matrix: a 2D matrix cannot have a non-identity value for m13, m14, m23, m24, m31, m32, m33, m34, m43 or m44.");
        return false;
    }
    return true;
}

/* an argument that is a matrix or a DOMMatrixInit */
static bool matrix_arg(JSContext *ctx, JSValueConst v, geo_matrix *out)
{
    geo_matrix *p = matrix_peek(v);
    if (p) { *out = *p; return true; }
    return matrix_from_init(ctx, v, out);
}

/* ---- parsing a transform list ("translate(10px, 5px) rotate(45deg)") ---- */

typedef struct cur { const char *p, *end; } cur;

static bool is_ws(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }
static bool is_digit(char c) { return c >= '0' && c <= '9'; }
static bool is_alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static void skip_ws(cur *c) { while (c->p < c->end && is_ws(*c->p)) { c->p++; } }

/* a CSS <number> at the cursor: sign, digits, fraction, exponent (an infinity is clamped to the largest double) */
static bool scan_number(cur *c, double *out)
{
    const char *s = c->p, *q = s;
    if (q < c->end && (*q == '+' || *q == '-')) { q++; }
    const char *int_start = q;
    while (q < c->end && is_digit(*q)) { q++; }
    bool any = q > int_start;
    if (q + 1 < c->end && *q == '.' && is_digit(q[1])) {
        q++;
        while (q < c->end && is_digit(*q)) { q++; }
        any = true;
    }
    if (!any) { return false; }
    if (q < c->end && (*q == 'e' || *q == 'E')) {
        const char *e = q + 1;
        if (e < c->end && (*e == '+' || *e == '-')) { e++; }
        if (e < c->end && is_digit(*e)) {
            while (e < c->end && is_digit(*e)) { e++; }
            q = e;
        }
    }
    char buf[400];
    size_t n = (size_t)(q - s);
    if (n >= sizeof buf) { return false; }
    memcpy(buf, s, n);
    buf[n] = 0;
    double v = strtod(buf, NULL);
    if (isinf(v)) { v = v > 0 ? DBL_MAX : -DBL_MAX; }
    *out = v;
    c->p = q;
    return true;
}

enum { ARG_NUMBER = 'n', ARG_LENGTH = 'l', ARG_ANGLE = 'a' };

/* One argument of a transform function. Lengths come out in px (only absolute units: a relative one cannot be resolved
 * without an element), angles in degrees; a unitless number is a length or an angle only when it is zero. */
static bool parse_arg(const char *s, const char *e, int kind, double *out)
{
    cur c = { s, e };
    skip_ws(&c);
    double v;
    if (!scan_number(&c, &v)) { return false; }
    const char *u = c.p;
    while (c.p < e && (is_alpha(*c.p) || *c.p == '%')) { c.p++; }
    size_t un = (size_t)(c.p - u);
    skip_ws(&c);
    if (c.p != e || un >= 8) { return false; }
    char unit[8];
    for (size_t i = 0; i < un; i++) { unit[i] = (char)(u[i] >= 'A' && u[i] <= 'Z' ? u[i] + 32 : u[i]); }
    unit[un] = 0;
    if (kind == ARG_NUMBER) {
        if (un) { return false; }
        *out = v;
    } else if (kind == ARG_LENGTH) {
        if (un == 0) { if (v != 0) { return false; } *out = 0; }
        else if (strcmp(unit, "px") == 0) { *out = v; }
        else if (strcmp(unit, "cm") == 0) { *out = v * 96 / 2.54; }
        else if (strcmp(unit, "mm") == 0) { *out = v * 96 / 25.4; }
        else if (strcmp(unit, "q") == 0) { *out = v * 96 / 101.6; }
        else if (strcmp(unit, "in") == 0) { *out = v * 96; }
        else if (strcmp(unit, "pt") == 0) { *out = v * 96 / 72; }
        else if (strcmp(unit, "pc") == 0) { *out = v * 16; }
        else { return false; }
    } else {
        if (un == 0) { if (v != 0) { return false; } *out = 0; }
        else if (strcmp(unit, "deg") == 0) { *out = v; }
        else if (strcmp(unit, "rad") == 0) { *out = v * 180 / GEO_PI; }
        else if (strcmp(unit, "grad") == 0) { *out = v * 0.9; }
        else if (strcmp(unit, "turn") == 0) { *out = v * 360; }
        else { return false; }
    }
    return true;
}

enum {
    TF_MATRIX, TF_MATRIX3D, TF_TRANSLATE, TF_TRANSLATEX, TF_TRANSLATEY, TF_TRANSLATEZ, TF_TRANSLATE3D,
    TF_SCALE, TF_SCALEX, TF_SCALEY, TF_SCALEZ, TF_SCALE3D,
    TF_ROTATE, TF_ROTATEX, TF_ROTATEY, TF_ROTATEZ, TF_ROTATE3D,
    TF_SKEW, TF_SKEWX, TF_SKEWY, TF_PERSPECTIVE, TF_COUNT
};

/* name, the number of arguments (min, max) and their kinds; three_d: the function makes the matrix 3D */
static const struct { const char *name; int min, max; const char *kinds; bool three_d; } TF[TF_COUNT] = {
    [TF_MATRIX] = { "matrix", 6, 6, "nnnnnn", false },
    [TF_MATRIX3D] = { "matrix3d", 16, 16, "nnnnnnnnnnnnnnnn", true },
    [TF_TRANSLATE] = { "translate", 1, 2, "ll", false },
    [TF_TRANSLATEX] = { "translatex", 1, 1, "l", false },
    [TF_TRANSLATEY] = { "translatey", 1, 1, "l", false },
    [TF_TRANSLATEZ] = { "translatez", 1, 1, "l", true },
    [TF_TRANSLATE3D] = { "translate3d", 3, 3, "lll", true },
    [TF_SCALE] = { "scale", 1, 2, "nn", false },
    [TF_SCALEX] = { "scalex", 1, 1, "n", false },
    [TF_SCALEY] = { "scaley", 1, 1, "n", false },
    [TF_SCALEZ] = { "scalez", 1, 1, "n", true },
    [TF_SCALE3D] = { "scale3d", 3, 3, "nnn", true },
    [TF_ROTATE] = { "rotate", 1, 1, "a", false },
    [TF_ROTATEX] = { "rotatex", 1, 1, "a", true },
    [TF_ROTATEY] = { "rotatey", 1, 1, "a", true },
    [TF_ROTATEZ] = { "rotatez", 1, 1, "a", true },
    [TF_ROTATE3D] = { "rotate3d", 4, 4, "nnna", true },
    [TF_SKEW] = { "skew", 1, 2, "aa", false },
    [TF_SKEWX] = { "skewx", 1, 1, "a", false },
    [TF_SKEWY] = { "skewy", 1, 1, "a", false },
    [TF_PERSPECTIVE] = { "perspective", 1, 1, "l", true },
};

/* The matrix of a function and its arguments. */
static bool transform_function(int id, const double *a, int na, double *t)
{
    m_ident(t);
    switch (id) {
    case TF_MATRIX: t[0] = a[0]; t[1] = a[1]; t[4] = a[2]; t[5] = a[3]; t[12] = a[4]; t[13] = a[5]; break;
    case TF_MATRIX3D: memcpy(t, a, 16 * sizeof(double)); break;
    case TF_TRANSLATE: m_translate(t, a[0], na > 1 ? a[1] : 0, 0); break;
    case TF_TRANSLATEX: m_translate(t, a[0], 0, 0); break;
    case TF_TRANSLATEY: m_translate(t, 0, a[0], 0); break;
    case TF_TRANSLATEZ: m_translate(t, 0, 0, a[0]); break;
    case TF_TRANSLATE3D: m_translate(t, a[0], a[1], a[2]); break;
    case TF_SCALE: m_scale(t, a[0], na > 1 ? a[1] : a[0], 1); break;
    case TF_SCALEX: m_scale(t, a[0], 1, 1); break;
    case TF_SCALEY: m_scale(t, 1, a[0], 1); break;
    case TF_SCALEZ: m_scale(t, 1, 1, a[0]); break;
    case TF_SCALE3D: m_scale(t, a[0], a[1], a[2]); break;
    case TF_ROTATE: case TF_ROTATEZ: m_rotate(t, 0, 0, 1, a[0]); break;
    case TF_ROTATEX: m_rotate(t, 1, 0, 0, a[0]); break;
    case TF_ROTATEY: m_rotate(t, 0, 1, 0, a[0]); break;
    case TF_ROTATE3D: m_rotate(t, a[0], a[1], a[2], a[3]); break;
    case TF_SKEW: m_skew(t, a[0], na > 1 ? a[1] : 0); break;
    case TF_SKEWX: m_skew(t, a[0], 0); break;
    case TF_SKEWY: m_skew(t, 0, a[0]); break;
    case TF_PERSPECTIVE:
        if (a[0] < 0) { return false; }
        t[11] = a[0] == 0 ? 0 : -1 / a[0];
        break;
    default: return false;
    }
    return true;
}

/* "none", an empty string or a list of transform functions (the product of their matrices, left to right). False for
 * anything else. */
static bool parse_transform(const char *s, size_t n, double *out, bool *is2d)
{
    m_ident(out);
    *is2d = true;
    cur c = { s, s + n };
    while (c.end > c.p && is_ws(c.end[-1])) { c.end--; }
    skip_ws(&c);
    if (c.p == c.end) { return true; }
    if (c.end - c.p == 4 && web_ascii_ieq(c.p, 4, "none")) { return true; }
    while (c.p < c.end) {
        const char *name = c.p;
        while (c.p < c.end && (is_alpha(*c.p) || is_digit(*c.p))) { c.p++; }
        size_t nl = (size_t)(c.p - name);
        if (nl == 0 || nl >= 16 || c.p >= c.end || *c.p != '(') { return false; }
        c.p++;
        const char *close = memchr(c.p, ')', (size_t)(c.end - c.p));
        if (!close) { return false; }
        int id = -1;
        for (int i = 0; i < TF_COUNT; i++) { if (web_ascii_ieq(name, nl, TF[i].name)) { id = i; break; } }
        if (id < 0) { return false; }
        double a[16];
        int na = 0;
        const char *as = c.p;
        for (;;) {
            const char *comma = memchr(as, ',', (size_t)(close - as));
            const char *ae = comma ? comma : close;
            if (na >= TF[id].max) { return false; }
            const char *ts = as, *te = ae;
            while (ts < te && is_ws(*ts)) { ts++; }
            while (te > ts && is_ws(te[-1])) { te--; }
            /* perspective(none) is perspective(0): the identity */
            if (id == TF_PERSPECTIVE && te - ts == 4 && web_ascii_ieq(ts, 4, "none")) { a[na++] = 0; }
            else if (!parse_arg(as, ae, TF[id].kinds[na], &a[na])) { return false; }
            else { na++; }
            if (!comma) { break; }
            as = comma + 1;
        }
        if (na < TF[id].min) { return false; }
        double t[16];
        if (!transform_function(id, a, na, t)) { return false; }
        mul4(out, t, out);
        if (TF[id].three_d) { *is2d = false; }
        c.p = close + 1;
        skip_ws(&c);
    }
    return true;
}

static bool matrix_from_string(JSContext *ctx, JSValueConst v, geo_matrix *out)
{
    wj_str s;
    if (!wj_to_str(ctx, v, &s, 0, NULL)) { return false; }
    bool ok = parse_transform(s.ptr ? s.ptr : "", s.len, out->m, &out->is2d);
    wj_str_free(ctx, &s);
    if (!ok) { wj_throw_dom(ctx, "SyntaxError", "Failed to parse transform list."); }
    return ok;
}

/* ---- constructors and factories ---- */

typedef struct seq { double v[16]; int n; } seq;

static bool seq_item(JSContext *ctx, JSValueConst item, void *opaque)
{
    seq *s = opaque;
    double d;
    if (!wj_to_double(ctx, item, &d, false)) { return false; }
    if (s->n < 16) { s->v[s->n] = d; }
    s->n++;
    return true;
}

/* 6 numbers (a b c d e f) make a 2D matrix, 16 a 3D one */
static bool matrix_from_numbers(JSContext *ctx, const double *v, int n, geo_matrix *out, const char *what)
{
    m_ident(out->m);
    if (n == 6) {
        for (int i = 0; i < 6; i++) { out->m[IDX_2D[i]] = v[i]; }
        out->is2d = true;
    } else if (n == 16) {
        memcpy(out->m, v, 16 * sizeof(double));
        out->is2d = false;
    } else {
        JS_ThrowTypeError(ctx, "%s: The sequence must contain 6 elements for a 2D matrix or 16 elements for a 3D matrix.", what);
        return false;
    }
    return true;
}

static JSValue matrix_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name)
{
    if (JS_IsUndefined(new_target)) {
        return JS_ThrowTypeError(ctx, "Failed to construct '%s': Please use the 'new' operator, this DOM object constructor cannot be called as a function.", name);
    }
    geo_matrix g;
    m_ident(g.m);
    g.is2d = true;
    JSValueConst init = arg_at(argc, argv, 0);
    if (!JS_IsUndefined(init)) {
        int iterable = JS_IsObject(init) ? web_is_iterable(ctx, init) : 0;
        if (iterable < 0) { return JS_EXCEPTION; }
        if (iterable) {
            seq s = { {0}, 0 };
            if (!web_for_of(ctx, init, seq_item, &s)) { return JS_EXCEPTION; }
            char what[64];
            snprintf(what, sizeof what, "Failed to construct '%s'", name);
            if (!matrix_from_numbers(ctx, s.v, s.n, &g, what)) { return JS_EXCEPTION; }
        } else {
            if (!web_is_window()) { return JS_ThrowTypeError(ctx, "Failed to construct '%s': Cannot parse a string in a worker.", name); }
            if (!matrix_from_string(ctx, init, &g)) { return JS_EXCEPTION; }
        }
    }
    return matrix_new(ctx, iface, new_target, g.m, g.is2d);
}

JSValue wjr_DOMMatrixReadOnly_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return matrix_construct(ctx, new_target, argc, argv, WJ_IFACE_DOMMatrixReadOnly, "DOMMatrixReadOnly"); }
JSValue wjr_DOMMatrix_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return matrix_construct(ctx, new_target, argc, argv, WJ_IFACE_DOMMatrix, "DOMMatrix"); }

static JSValue matrix_from_matrix(JSContext *ctx, int iface, int argc, JSValueConst *argv)
{
    geo_matrix g;
    if (!matrix_arg(ctx, arg_at(argc, argv, 0), &g)) { return JS_EXCEPTION; }
    return matrix_new(ctx, iface, JS_UNDEFINED, g.m, g.is2d);
}

JSValue wjr_DOMMatrixReadOnly_static_fromMatrix(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return matrix_from_matrix(ctx, WJ_IFACE_DOMMatrixReadOnly, argc, argv); }
JSValue wjr_DOMMatrix_static_fromMatrix(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return matrix_from_matrix(ctx, WJ_IFACE_DOMMatrix, argc, argv); }

static JSValue matrix_from_floats(JSContext *ctx, int iface, const char *iface_name, int argc, JSValueConst *argv, bool f64)
{
    const char *fn = f64 ? "fromFloat64Array" : "fromFloat32Array";
    const char *type = f64 ? "Float64Array" : "Float32Array";
    char what[96];
    snprintf(what, sizeof what, "%s.%s", iface_name, fn);
    if (argc < 1) { return wj_throw_arity(ctx, what, 1, argc); }
    if (wj_typed_array_type(argv[0]) != (f64 ? JS_TYPED_ARRAY_FLOAT64 : JS_TYPED_ARRAY_FLOAT32)) {
        return JS_ThrowTypeError(ctx, "Failed to execute '%s' on '%s': parameter 1 is not of type '%s'.", fn, iface_name, type);
    }
    uint8_t *p = NULL;
    size_t bytes = 0;
    if (!wj_to_buffer_source(ctx, argv[0], &p, &bytes, WJ_BS_VIEW_ONLY, what)) { return JS_EXCEPTION; }
    size_t width = f64 ? 8 : 4, count = bytes / width;
    double v[16];
    if (count == 6 || count == 16) {
        for (size_t i = 0; i < count; i++) {
            if (f64) { memcpy(&v[i], p + i * 8, 8); }
            else { float f; memcpy(&f, p + i * 4, 4); v[i] = f; }
        }
    }
    geo_matrix g;
    char msg[128];
    snprintf(msg, sizeof msg, "Failed to execute '%s' on '%s'", fn, iface_name);
    if (!matrix_from_numbers(ctx, v, (int)count, &g, msg)) { return JS_EXCEPTION; }
    return matrix_new(ctx, iface, JS_UNDEFINED, g.m, g.is2d);
}

JSValue wjr_DOMMatrixReadOnly_static_fromFloat32Array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return matrix_from_floats(ctx, WJ_IFACE_DOMMatrixReadOnly, "DOMMatrixReadOnly", argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_static_fromFloat64Array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return matrix_from_floats(ctx, WJ_IFACE_DOMMatrixReadOnly, "DOMMatrixReadOnly", argc, argv, true); }
JSValue wjr_DOMMatrix_static_fromFloat32Array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return matrix_from_floats(ctx, WJ_IFACE_DOMMatrix, "DOMMatrix", argc, argv, false); }
JSValue wjr_DOMMatrix_static_fromFloat64Array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return matrix_from_floats(ctx, WJ_IFACE_DOMMatrix, "DOMMatrix", argc, argv, true); }

/* ---- attributes ---- */

static JSValue mat_get(JSContext *ctx, JSValueConst this_val, int iface, int idx)
{
    geo_matrix *s = matrix_of(ctx, this_val, iface);
    return s ? JS_NewFloat64(ctx, s->m[idx]) : JS_EXCEPTION;
}

/* A 3D attribute set to anything but its identity value makes the matrix 3D. */
static JSValue mat_set(JSContext *ctx, JSValueConst this_val, JSValueConst v, int idx)
{
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrix);
    if (!s) { return JS_EXCEPTION; }
    double x;
    if (!wj_to_double(ctx, v, &x, false)) { return JS_EXCEPTION; }
    bool is_2d_slot = idx == 0 || idx == 1 || idx == 4 || idx == 5 || idx == 12 || idx == 13;
    if (!is_2d_slot && x != IDENT[idx]) { s->is2d = false; }
    s->m[idx] = x;
    return JS_UNDEFINED;
}

JSValue wjr_DOMMatrixReadOnly_get_a(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 0); }
JSValue wjr_DOMMatrixReadOnly_get_b(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 1); }
JSValue wjr_DOMMatrixReadOnly_get_c(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 4); }
JSValue wjr_DOMMatrixReadOnly_get_d(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 5); }
JSValue wjr_DOMMatrixReadOnly_get_e(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 12); }
JSValue wjr_DOMMatrixReadOnly_get_f(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 13); }
JSValue wjr_DOMMatrixReadOnly_get_m11(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 0); }
JSValue wjr_DOMMatrixReadOnly_get_m12(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 1); }
JSValue wjr_DOMMatrixReadOnly_get_m13(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 2); }
JSValue wjr_DOMMatrixReadOnly_get_m14(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 3); }
JSValue wjr_DOMMatrixReadOnly_get_m21(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 4); }
JSValue wjr_DOMMatrixReadOnly_get_m22(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 5); }
JSValue wjr_DOMMatrixReadOnly_get_m23(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 6); }
JSValue wjr_DOMMatrixReadOnly_get_m24(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 7); }
JSValue wjr_DOMMatrixReadOnly_get_m31(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 8); }
JSValue wjr_DOMMatrixReadOnly_get_m32(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 9); }
JSValue wjr_DOMMatrixReadOnly_get_m33(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 10); }
JSValue wjr_DOMMatrixReadOnly_get_m34(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 11); }
JSValue wjr_DOMMatrixReadOnly_get_m41(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 12); }
JSValue wjr_DOMMatrixReadOnly_get_m42(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 13); }
JSValue wjr_DOMMatrixReadOnly_get_m43(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 14); }
JSValue wjr_DOMMatrixReadOnly_get_m44(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly, 15); }

/* DOMMatrix redeclares them as read-write attributes */
JSValue wjr_DOMMatrix_get_a(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 0); }
JSValue wjr_DOMMatrix_get_b(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 1); }
JSValue wjr_DOMMatrix_get_c(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 4); }
JSValue wjr_DOMMatrix_get_d(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 5); }
JSValue wjr_DOMMatrix_get_e(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 12); }
JSValue wjr_DOMMatrix_get_f(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 13); }
JSValue wjr_DOMMatrix_get_m11(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 0); }
JSValue wjr_DOMMatrix_get_m12(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 1); }
JSValue wjr_DOMMatrix_get_m13(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 2); }
JSValue wjr_DOMMatrix_get_m14(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 3); }
JSValue wjr_DOMMatrix_get_m21(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 4); }
JSValue wjr_DOMMatrix_get_m22(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 5); }
JSValue wjr_DOMMatrix_get_m23(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 6); }
JSValue wjr_DOMMatrix_get_m24(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 7); }
JSValue wjr_DOMMatrix_get_m31(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 8); }
JSValue wjr_DOMMatrix_get_m32(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 9); }
JSValue wjr_DOMMatrix_get_m33(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 10); }
JSValue wjr_DOMMatrix_get_m34(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 11); }
JSValue wjr_DOMMatrix_get_m41(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 12); }
JSValue wjr_DOMMatrix_get_m42(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 13); }
JSValue wjr_DOMMatrix_get_m43(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 14); }
JSValue wjr_DOMMatrix_get_m44(JSContext *ctx, JSValueConst this_val) { return mat_get(ctx, this_val, WJ_IFACE_DOMMatrix, 15); }

JSValue wjr_DOMMatrix_set_a(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 0); }
JSValue wjr_DOMMatrix_set_b(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 1); }
JSValue wjr_DOMMatrix_set_c(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 4); }
JSValue wjr_DOMMatrix_set_d(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 5); }
JSValue wjr_DOMMatrix_set_e(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 12); }
JSValue wjr_DOMMatrix_set_f(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 13); }
JSValue wjr_DOMMatrix_set_m11(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 0); }
JSValue wjr_DOMMatrix_set_m12(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 1); }
JSValue wjr_DOMMatrix_set_m13(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 2); }
JSValue wjr_DOMMatrix_set_m14(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 3); }
JSValue wjr_DOMMatrix_set_m21(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 4); }
JSValue wjr_DOMMatrix_set_m22(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 5); }
JSValue wjr_DOMMatrix_set_m23(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 6); }
JSValue wjr_DOMMatrix_set_m24(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 7); }
JSValue wjr_DOMMatrix_set_m31(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 8); }
JSValue wjr_DOMMatrix_set_m32(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 9); }
JSValue wjr_DOMMatrix_set_m33(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 10); }
JSValue wjr_DOMMatrix_set_m34(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 11); }
JSValue wjr_DOMMatrix_set_m41(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 12); }
JSValue wjr_DOMMatrix_set_m42(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 13); }
JSValue wjr_DOMMatrix_set_m43(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 14); }
JSValue wjr_DOMMatrix_set_m44(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return mat_set(ctx, this_val, v, 15); }

JSValue wjr_DOMMatrixReadOnly_get_is2D(JSContext *ctx, JSValueConst this_val)
{
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly);
    return s ? JS_NewBool(ctx, s->is2d) : JS_EXCEPTION;
}

JSValue wjr_DOMMatrixReadOnly_get_isIdentity(JSContext *ctx, JSValueConst this_val)
{
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    for (int i = 0; i < 16; i++) { if (s->m[i] != IDENT[i]) { return JS_FALSE; } }
    return JS_TRUE;
}

/* ---- operations ---- */

enum {
    OP_TRANSLATE, OP_SCALE, OP_SCALE_NONUNIFORM, OP_SCALE3D, OP_ROTATE, OP_ROTATE_FROM_VECTOR, OP_ROTATE_AXIS_ANGLE,
    OP_SKEW_X, OP_SKEW_Y, OP_FLIP_X, OP_FLIP_Y,
};

/* t = origin translation * scale * back translation */
static void scale_around(double *t, double sx, double sy, double sz, double ox, double oy, double oz)
{
    double a[16], s[16], b[16];
    m_translate(a, ox, oy, oz);
    m_scale(s, sx, sy, sz);
    m_translate(b, -ox, -oy, -oz);
    mul4(a, s, t);
    mul4(t, b, t);
}

/* The matrix an operation multiplies by (arguments converted in order, undefined is the default), and whether it makes
 * the matrix 3D. */
static bool op_matrix(JSContext *ctx, int op, int argc, JSValueConst *argv, double *t, bool *is3d)
{
    double a[6];
    *is3d = false;
    m_ident(t);
    switch (op) {
    case OP_TRANSLATE:
        if (!num_arg(ctx, argc, argv, 0, 0, &a[0]) || !num_arg(ctx, argc, argv, 1, 0, &a[1]) || !num_arg(ctx, argc, argv, 2, 0, &a[2])) { return false; }
        m_translate(t, a[0], a[1], a[2]);
        *is3d = a[2] != 0;
        break;
    case OP_SCALE: {
        if (!num_arg(ctx, argc, argv, 0, 1, &a[0])) { return false; }
        /* scaleY has no default: it is scaleX when absent */
        if (!num_arg(ctx, argc, argv, 1, a[0], &a[1]) || !num_arg(ctx, argc, argv, 2, 1, &a[2]) || !num_arg(ctx, argc, argv, 3, 0, &a[3])
            || !num_arg(ctx, argc, argv, 4, 0, &a[4]) || !num_arg(ctx, argc, argv, 5, 0, &a[5])) { return false; }
        scale_around(t, a[0], a[1], a[2], a[3], a[4], a[5]);
        *is3d = a[2] != 1 || a[5] != 0;
        break;
    }
    case OP_SCALE_NONUNIFORM:
        if (!num_arg(ctx, argc, argv, 0, 1, &a[0]) || !num_arg(ctx, argc, argv, 1, 1, &a[1])) { return false; }
        m_scale(t, a[0], a[1], 1);
        break;
    case OP_SCALE3D:
        if (!num_arg(ctx, argc, argv, 0, 1, &a[0]) || !num_arg(ctx, argc, argv, 1, 0, &a[1]) || !num_arg(ctx, argc, argv, 2, 0, &a[2]) || !num_arg(ctx, argc, argv, 3, 0, &a[3])) { return false; }
        scale_around(t, a[0], a[0], a[0], a[1], a[2], a[3]);
        *is3d = true;
        break;
    case OP_ROTATE: {
        double rx, ry = 0, rz = 0;
        bool has_y = present(argc, argv, 1), has_z = present(argc, argv, 2);
        if (!num_arg(ctx, argc, argv, 0, 0, &rx)) { return false; }
        if (!has_y && !has_z) { rz = rx; rx = 0; }
        else if (!num_arg(ctx, argc, argv, 1, 0, &ry) || !num_arg(ctx, argc, argv, 2, 0, &rz)) { return false; }
        double r[16];
        if (rz != 0) { m_rotate(r, 0, 0, 1, rz); mul4(t, r, t); }
        if (ry != 0) { m_rotate(r, 0, 1, 0, ry); mul4(t, r, t); }
        if (rx != 0) { m_rotate(r, 1, 0, 0, rx); mul4(t, r, t); }
        *is3d = rx != 0 || ry != 0;
        break;
    }
    case OP_ROTATE_FROM_VECTOR:
        if (!num_arg(ctx, argc, argv, 0, 0, &a[0]) || !num_arg(ctx, argc, argv, 1, 0, &a[1])) { return false; }
        if (!(a[0] == 0 && a[1] == 0)) { m_rotate(t, 0, 0, 1, atan2(a[1], a[0]) * 180 / GEO_PI); }
        break;
    case OP_ROTATE_AXIS_ANGLE:
        if (!num_arg(ctx, argc, argv, 0, 0, &a[0]) || !num_arg(ctx, argc, argv, 1, 0, &a[1]) || !num_arg(ctx, argc, argv, 2, 0, &a[2]) || !num_arg(ctx, argc, argv, 3, 0, &a[3])) { return false; }
        m_rotate(t, a[0], a[1], a[2], a[3]);
        *is3d = a[0] != 0 || a[1] != 0;
        break;
    case OP_SKEW_X:
        if (!num_arg(ctx, argc, argv, 0, 0, &a[0])) { return false; }
        m_skew(t, a[0], 0);
        break;
    case OP_SKEW_Y:
        if (!num_arg(ctx, argc, argv, 0, 0, &a[0])) { return false; }
        m_skew(t, 0, a[0]);
        break;
    case OP_FLIP_X: m_scale(t, -1, 1, 1); break;
    case OP_FLIP_Y: m_scale(t, 1, -1, 1); break;
    default: break;
    }
    return true;
}

/* this * the operation's matrix: a new DOMMatrix, or `this` itself changed (the ...Self methods of DOMMatrix) */
static JSValue matrix_apply(JSContext *ctx, JSValueConst this_val, int op, int argc, JSValueConst *argv, bool self)
{
    geo_matrix *s = matrix_of(ctx, this_val, self ? WJ_IFACE_DOMMatrix : WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    double t[16], r[16];
    bool is3d;
    if (!op_matrix(ctx, op, argc, argv, t, &is3d)) { return JS_EXCEPTION; }
    mul4(s->m, t, r);
    bool is2d = s->is2d && !is3d;
    if (self) {
        memcpy(s->m, r, sizeof r);
        s->is2d = is2d;
        return JS_DupValue(ctx, this_val);
    }
    return matrix_new(ctx, WJ_IFACE_DOMMatrix, JS_UNDEFINED, r, is2d);
}

JSValue wjr_DOMMatrixReadOnly_translate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_TRANSLATE, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_scale(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SCALE, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_scaleNonUniform(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SCALE_NONUNIFORM, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_scale3d(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SCALE3D, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_rotate(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_ROTATE, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_rotateFromVector(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_ROTATE_FROM_VECTOR, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_rotateAxisAngle(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_ROTATE_AXIS_ANGLE, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_skewX(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SKEW_X, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_skewY(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SKEW_Y, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_flipX(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_FLIP_X, argc, argv, false); }
JSValue wjr_DOMMatrixReadOnly_flipY(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_FLIP_Y, argc, argv, false); }

JSValue wjr_DOMMatrix_translateSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_TRANSLATE, argc, argv, true); }
JSValue wjr_DOMMatrix_scaleSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SCALE, argc, argv, true); }
JSValue wjr_DOMMatrix_scale3dSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SCALE3D, argc, argv, true); }
JSValue wjr_DOMMatrix_rotateSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_ROTATE, argc, argv, true); }
JSValue wjr_DOMMatrix_rotateFromVectorSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_ROTATE_FROM_VECTOR, argc, argv, true); }
JSValue wjr_DOMMatrix_rotateAxisAngleSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_ROTATE_AXIS_ANGLE, argc, argv, true); }
JSValue wjr_DOMMatrix_skewXSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SKEW_X, argc, argv, true); }
JSValue wjr_DOMMatrix_skewYSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_apply(ctx, this_val, OP_SKEW_Y, argc, argv, true); }

/* this * other, or other * this (preMultiplySelf) */
static JSValue matrix_multiply(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, bool self, bool pre)
{
    geo_matrix *s = matrix_of(ctx, this_val, self ? WJ_IFACE_DOMMatrix : WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    geo_matrix o;
    if (!matrix_arg(ctx, arg_at(argc, argv, 0), &o)) { return JS_EXCEPTION; }
    double r[16];
    if (pre) { mul4(o.m, s->m, r); } else { mul4(s->m, o.m, r); }
    bool is2d = s->is2d && o.is2d;
    if (self) {
        memcpy(s->m, r, sizeof r);
        s->is2d = is2d;
        return JS_DupValue(ctx, this_val);
    }
    return matrix_new(ctx, WJ_IFACE_DOMMatrix, JS_UNDEFINED, r, is2d);
}

JSValue wjr_DOMMatrixReadOnly_multiply(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_multiply(ctx, this_val, argc, argv, false, false); }
JSValue wjr_DOMMatrix_multiplySelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_multiply(ctx, this_val, argc, argv, true, false); }
JSValue wjr_DOMMatrix_preMultiplySelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { return matrix_multiply(ctx, this_val, argc, argv, true, true); }

/* A matrix that cannot be inverted becomes all NaN and 3D. */
static JSValue matrix_invert(JSContext *ctx, JSValueConst this_val, bool self)
{
    geo_matrix *s = matrix_of(ctx, this_val, self ? WJ_IFACE_DOMMatrix : WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    double r[16];
    bool is2d = s->is2d;
    if (!invert4(s->m, r)) {
        for (int i = 0; i < 16; i++) { r[i] = NAN; }
        is2d = false;
    }
    if (self) {
        memcpy(s->m, r, sizeof r);
        s->is2d = is2d;
        return JS_DupValue(ctx, this_val);
    }
    return matrix_new(ctx, WJ_IFACE_DOMMatrix, JS_UNDEFINED, r, is2d);
}

JSValue wjr_DOMMatrixReadOnly_inverse(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return matrix_invert(ctx, this_val, false); }
JSValue wjr_DOMMatrix_invertSelf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return matrix_invert(ctx, this_val, true); }

JSValue wjr_DOMMatrix_setMatrixValue(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrix);
    if (!s) { return JS_EXCEPTION; }
    if (argc < 1) { return wj_throw_arity(ctx, "DOMMatrix.setMatrixValue", 1, argc); }
    geo_matrix g;
    if (!matrix_from_string(ctx, argv[0], &g)) { return JS_EXCEPTION; }
    memcpy(s->m, g.m, sizeof g.m);
    s->is2d = g.is2d;
    return JS_DupValue(ctx, this_val);
}

/* ---- conversions ---- */

static JSValue matrix_floats(JSContext *ctx, JSValueConst this_val, bool f64)
{
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    uint8_t buf[16 * sizeof(double)];
    size_t n;
    if (f64) {
        memcpy(buf, s->m, sizeof s->m);
        n = sizeof s->m;
    } else {
        float f[16];
        for (int i = 0; i < 16; i++) { f[i] = (float)s->m[i]; }
        memcpy(buf, f, sizeof f);
        n = sizeof f;
    }
    JSValue ab = JS_NewArrayBufferCopy(ctx, buf, n);
    if (JS_IsException(ab)) { return ab; }
    JSValue arr = JS_NewTypedArray(ctx, 1, (JSValueConst *)&ab, f64 ? JS_TYPED_ARRAY_FLOAT64 : JS_TYPED_ARRAY_FLOAT32);
    JS_FreeValue(ctx, ab);
    return arr;
}

JSValue wjr_DOMMatrixReadOnly_toFloat32Array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return matrix_floats(ctx, this_val, false); }
JSValue wjr_DOMMatrixReadOnly_toFloat64Array(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(argc); WJ_UNUSED(argv); return matrix_floats(ctx, this_val, true); }

/* the number as JavaScript writes it (the shortest text that reads back as the same double) */
static void put_number(JSContext *ctx, web_buf *b, double x)
{
    JSValue nv = JS_NewFloat64(ctx, x);
    const char *cs = JS_ToCString(ctx, nv);
    if (cs) { web_buf_puts(b, cs); JS_FreeCString(ctx, cs); }
    JS_FreeValue(ctx, nv);
}

JSValue wjr_DOMMatrixReadOnly_toString(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    for (int i = 0; i < 16; i++) {
        if (!isfinite(s->m[i])) { return wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'toString' on 'DOMMatrixReadOnly': Cannot be serialized with NaN or Infinity values."); }
    }
    web_buf b = { 0 };
    web_buf_puts(&b, s->is2d ? "matrix(" : "matrix3d(");
    int n = s->is2d ? 6 : 16;
    for (int i = 0; i < n; i++) {
        if (i) { web_buf_puts(&b, ", "); }
        put_number(ctx, &b, s->m[s->is2d ? IDX_2D[i] : i]);
    }
    web_buf_puts(&b, ")");
    JSValue r = b.failed ? JS_ThrowOutOfMemory(ctx) : JS_NewStringLen(ctx, (const char *)b.p, b.len);
    web_buf_free(&b);
    return r;
}

JSValue wjr_DOMMatrixReadOnly_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    static const char *const alias[6] = { "a", "b", "c", "d", "e", "f" };
    static const char *const names[16] = { "m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34", "m41", "m42", "m43", "m44" };
    JSValue o = JS_NewObject(ctx);
    for (int i = 0; i < 6; i++) { JS_SetPropertyStr(ctx, o, alias[i], JS_NewFloat64(ctx, s->m[IDX_2D[i]])); }
    for (int i = 0; i < 16; i++) { JS_SetPropertyStr(ctx, o, names[i], JS_NewFloat64(ctx, s->m[i])); }
    bool identity = true;
    for (int i = 0; i < 16; i++) { if (s->m[i] != IDENT[i]) { identity = false; } }
    JS_SetPropertyStr(ctx, o, "is2D", JS_NewBool(ctx, s->is2d));
    JS_SetPropertyStr(ctx, o, "isIdentity", JS_NewBool(ctx, identity));
    return o;
}

/* ---- points ---- */

static void point_transform(const double *m, const double *p, double *out)
{
    out[0] = m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12] * p[3];
    out[1] = m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13] * p[3];
    out[2] = m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14] * p[3];
    out[3] = m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15] * p[3];
}

static JSValue point_new(JSContext *ctx, int iface, JSValueConst new_target, double x, double y, double z, double w)
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, iface, DOM_RECT, JS_UNDEFINED, 0, &d);
    if (JS_IsException(obj)) { return obj; }
    d->rect[0] = x; d->rect[1] = y; d->rect[2] = z; d->rect[3] = w;
    if (JS_IsObject(new_target)) {
        /* the prototype of new.target: subclasses get theirs */
        JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    return obj;
}

static dom_impl *point_of(JSContext *ctx, JSValueConst this_val) { return dom_impl_of(ctx, this_val, WJ_IFACE_DOMPointReadOnly); }

/* the coordinates of a DOMPointReadOnly argument (no exception), or NULL */
static dom_impl *point_peek(JSValueConst v)
{
    wj_obj *o = wj_unwrap(v, WJ_IFACE_DOMPointReadOnly);
    dom_impl *d = o ? o->impl : NULL;
    return d && d->kind == DOM_RECT ? d : NULL;
}

/* x y z w of a DOMPointInit or a point */
static bool point_arg(JSContext *ctx, JSValueConst v, double *p)
{
    dom_impl *d = point_peek(v);
    if (d) { memcpy(p, d->rect, 4 * sizeof(double)); return true; }
    wjd_DOMPointInit pi;
    if (!wjd_DOMPointInit_from(ctx, v, &pi)) { return false; }
    p[0] = pi.x; p[1] = pi.y; p[2] = pi.z; p[3] = pi.w;
    wjd_DOMPointInit_free(ctx, &pi);
    return true;
}

static JSValue point_construct(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int iface, const char *name)
{
    if (JS_IsUndefined(new_target)) {
        return JS_ThrowTypeError(ctx, "Failed to construct '%s': Please use the 'new' operator, this DOM object constructor cannot be called as a function.", name);
    }
    double v[4];
    if (!num_arg(ctx, argc, argv, 0, 0, &v[0]) || !num_arg(ctx, argc, argv, 1, 0, &v[1]) || !num_arg(ctx, argc, argv, 2, 0, &v[2]) || !num_arg(ctx, argc, argv, 3, 1, &v[3])) { return JS_EXCEPTION; }
    return point_new(ctx, iface, new_target, v[0], v[1], v[2], v[3]);
}

JSValue wjr_DOMPointReadOnly_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return point_construct(ctx, new_target, argc, argv, WJ_IFACE_DOMPointReadOnly, "DOMPointReadOnly"); }
JSValue wjr_DOMPoint_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) { return point_construct(ctx, new_target, argc, argv, WJ_IFACE_DOMPoint, "DOMPoint"); }

static JSValue point_from(JSContext *ctx, int iface, int argc, JSValueConst *argv)
{
    double p[4];
    if (!point_arg(ctx, arg_at(argc, argv, 0), p)) { return JS_EXCEPTION; }
    return point_new(ctx, iface, JS_UNDEFINED, p[0], p[1], p[2], p[3]);
}

JSValue wjr_DOMPointReadOnly_static_fromPoint(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return point_from(ctx, WJ_IFACE_DOMPointReadOnly, argc, argv); }
JSValue wjr_DOMPoint_static_fromPoint(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) { WJ_UNUSED(this_val); return point_from(ctx, WJ_IFACE_DOMPoint, argc, argv); }

static JSValue point_field(JSContext *ctx, JSValueConst this_val, int i)
{
    dom_impl *d = point_of(ctx, this_val);
    return d ? JS_NewFloat64(ctx, d->rect[i]) : JS_EXCEPTION;
}

static JSValue point_set(JSContext *ctx, JSValueConst this_val, JSValueConst v, int i)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMPoint);
    if (!d) { return JS_EXCEPTION; }
    double x;
    if (!wj_to_double(ctx, v, &x, false)) { return JS_EXCEPTION; }
    d->rect[i] = x;
    return JS_UNDEFINED;
}

JSValue wjr_DOMPointReadOnly_get_x(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 0); }
JSValue wjr_DOMPointReadOnly_get_y(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 1); }
JSValue wjr_DOMPointReadOnly_get_z(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 2); }
JSValue wjr_DOMPointReadOnly_get_w(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 3); }
JSValue wjr_DOMPoint_get_x(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 0); }
JSValue wjr_DOMPoint_get_y(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 1); }
JSValue wjr_DOMPoint_get_z(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 2); }
JSValue wjr_DOMPoint_get_w(JSContext *ctx, JSValueConst this_val) { return point_field(ctx, this_val, 3); }
JSValue wjr_DOMPoint_set_x(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return point_set(ctx, this_val, v, 0); }
JSValue wjr_DOMPoint_set_y(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return point_set(ctx, this_val, v, 1); }
JSValue wjr_DOMPoint_set_z(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return point_set(ctx, this_val, v, 2); }
JSValue wjr_DOMPoint_set_w(JSContext *ctx, JSValueConst this_val, JSValueConst v) { return point_set(ctx, this_val, v, 3); }

JSValue wjr_DOMPointReadOnly_matrixTransform(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    dom_impl *d = point_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    geo_matrix m;
    if (!matrix_arg(ctx, arg_at(argc, argv, 0), &m)) { return JS_EXCEPTION; }
    double r[4];
    point_transform(m.m, d->rect, r);
    return point_new(ctx, WJ_IFACE_DOMPoint, JS_UNDEFINED, r[0], r[1], r[2], r[3]);
}

JSValue wjr_DOMMatrixReadOnly_transformPoint(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    geo_matrix *s = matrix_of(ctx, this_val, WJ_IFACE_DOMMatrixReadOnly);
    if (!s) { return JS_EXCEPTION; }
    double p[4], r[4];
    if (!point_arg(ctx, arg_at(argc, argv, 0), p)) { return JS_EXCEPTION; }
    point_transform(s->m, p, r);
    return point_new(ctx, WJ_IFACE_DOMPoint, JS_UNDEFINED, r[0], r[1], r[2], r[3]);
}

JSValue wjr_DOMPointReadOnly_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = point_of(ctx, this_val);
    if (!d) { return JS_EXCEPTION; }
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "x", JS_NewFloat64(ctx, d->rect[0]));
    JS_SetPropertyStr(ctx, o, "y", JS_NewFloat64(ctx, d->rect[1]));
    JS_SetPropertyStr(ctx, o, "z", JS_NewFloat64(ctx, d->rect[2]));
    JS_SetPropertyStr(ctx, o, "w", JS_NewFloat64(ctx, d->rect[3]));
    return o;
}

/* ---- quads ---- */

/* A DOMQuad over four points (x y z w each); its points are DOMPoint objects it keeps. */
static JSValue quad_new(JSContext *ctx, JSValueConst new_target, const double p[4][4])
{
    dom_impl *d;
    JSValue obj = dom_new(ctx, WJ_IFACE_DOMQuad, DOM_VALUES, JS_UNDEFINED, 0, &d);
    if (JS_IsException(obj)) { return obj; }
    d->values = calloc(4, sizeof(JSValue));
    if (!d->values) { JS_FreeValue(ctx, obj); return JS_ThrowOutOfMemory(ctx); }
    for (int i = 0; i < 4; i++) {
        d->values[i] = point_new(ctx, WJ_IFACE_DOMPoint, JS_UNDEFINED, p[i][0], p[i][1], p[i][2], p[i][3]);
        d->n_values = (uint32_t)i + 1;
        if (JS_IsException(d->values[i])) { d->values[i] = JS_UNDEFINED; JS_FreeValue(ctx, obj); return JS_EXCEPTION; }
    }
    if (JS_IsObject(new_target)) {
        JSValue proto = JS_GetPropertyStr(ctx, new_target, "prototype");
        if (JS_IsObject(proto)) { JS_SetPrototype(ctx, obj, proto); }
        JS_FreeValue(ctx, proto);
    }
    return obj;
}

JSValue wjr_DOMQuad_constructor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target)) { return JS_ThrowTypeError(ctx, "Failed to construct 'DOMQuad': Please use the 'new' operator, this DOM object constructor cannot be called as a function."); }
    double p[4][4];
    for (int i = 0; i < 4; i++) { if (!point_arg(ctx, arg_at(argc, argv, i), p[i])) { return JS_EXCEPTION; } }
    return quad_new(ctx, new_target, p);
}

JSValue wjr_DOMQuad_static_fromRect(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wjd_DOMRectInit r;
    if (!wjd_DOMRectInit_from(ctx, arg_at(argc, argv, 0), &r)) { return JS_EXCEPTION; }
    double p[4][4] = {
        { r.x, r.y, 0, 1 }, { r.x + r.width, r.y, 0, 1 }, { r.x + r.width, r.y + r.height, 0, 1 }, { r.x, r.y + r.height, 0, 1 },
    };
    wjd_DOMRectInit_free(ctx, &r);
    return quad_new(ctx, JS_UNDEFINED, p);
}

JSValue wjr_DOMQuad_static_fromQuad(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(this_val);
    wjd_DOMQuadInit q;
    if (!wjd_DOMQuadInit_from(ctx, arg_at(argc, argv, 0), &q)) { return JS_EXCEPTION; }
    const wjd_DOMPointInit *in[4] = { &q.p1, &q.p2, &q.p3, &q.p4 };
    bool has[4] = { q.has_p1, q.has_p2, q.has_p3, q.has_p4 };
    double p[4][4];
    for (int i = 0; i < 4; i++) {
        if (has[i]) { p[i][0] = in[i]->x; p[i][1] = in[i]->y; p[i][2] = in[i]->z; p[i][3] = in[i]->w; }
        else { p[i][0] = 0; p[i][1] = 0; p[i][2] = 0; p[i][3] = 1; }
    }
    wjd_DOMQuadInit_free(ctx, &q);
    return quad_new(ctx, JS_UNDEFINED, p);
}

static JSValue quad_point(JSContext *ctx, JSValueConst this_val, int i)
{
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMQuad);
    if (!d) { return JS_EXCEPTION; }
    return i < (int)d->n_values ? JS_DupValue(ctx, d->values[i]) : JS_UNDEFINED;
}

JSValue wjr_DOMQuad_get_p1(JSContext *ctx, JSValueConst this_val) { return quad_point(ctx, this_val, 0); }
JSValue wjr_DOMQuad_get_p2(JSContext *ctx, JSValueConst this_val) { return quad_point(ctx, this_val, 1); }
JSValue wjr_DOMQuad_get_p3(JSContext *ctx, JSValueConst this_val) { return quad_point(ctx, this_val, 2); }
JSValue wjr_DOMQuad_get_p4(JSContext *ctx, JSValueConst this_val) { return quad_point(ctx, this_val, 3); }

/* the smallest / largest of the four, NaN when one is (Geometry: "NaN-safe minimum / maximum") */
static double nan_min(const double *v) { double r = v[0]; for (int i = 1; i < 4; i++) { if (isnan(v[i]) || isnan(r)) { return NAN; } if (v[i] < r) { r = v[i]; } } return r; }
static double nan_max(const double *v) { double r = v[0]; for (int i = 1; i < 4; i++) { if (isnan(v[i]) || isnan(r)) { return NAN; } if (v[i] > r) { r = v[i]; } } return r; }

JSValue wjr_DOMQuad_getBounds(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMQuad);
    if (!d) { return JS_EXCEPTION; }
    double xs[4], ys[4];
    for (int i = 0; i < 4; i++) {
        dom_impl *pt = point_peek(d->values[i]);
        xs[i] = pt ? pt->rect[0] : 0;
        ys[i] = pt ? pt->rect[1] : 0;
    }
    double left = nan_min(xs), top = nan_min(ys), right = nan_max(xs), bottom = nan_max(ys);
    return dom_rect_new(ctx, left, top, right - left, bottom - top, false);
}

JSValue wjr_DOMQuad_toJSON(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    WJ_UNUSED(argc); WJ_UNUSED(argv);
    dom_impl *d = dom_impl_of(ctx, this_val, WJ_IFACE_DOMQuad);
    if (!d) { return JS_EXCEPTION; }
    static const char *const names[4] = { "p1", "p2", "p3", "p4" };
    JSValue o = JS_NewObject(ctx);
    for (int i = 0; i < 4; i++) { JS_SetPropertyStr(ctx, o, names[i], JS_DupValue(ctx, d->values[i])); }
    return o;
}
