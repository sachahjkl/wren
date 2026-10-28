// m5_dicts.odin: the generated Web IDL dictionaries (gen/bindings.c wjd_*) the geometry, canvas and animation glue
// reads, mirrored field for field from gen/bindings.h (same order, same types: the engine fills them in place) with
// their _from / _free symbols. Kept apart from dicts.odin so the domains ported in parallel do not edit one file.
package odin_glue

import "../odin/wj"

// wjd_DOMMatrix2DInit: each member followed by its has_* presence flag.
wjd_DOMMatrix2DInit :: struct {
	a: f64, has_a: bool,
	b: f64, has_b: bool,
	c: f64, has_c: bool,
	d: f64, has_d: bool,
	e: f64, has_e: bool,
	f: f64, has_f: bool,
	m11: f64, has_m11: bool,
	m12: f64, has_m12: bool,
	m21: f64, has_m21: bool,
	m22: f64, has_m22: bool,
	m41: f64, has_m41: bool,
	m42: f64, has_m42: bool,
}

// wjd_DOMMatrixInit: the 2D members as its base, then the 3D ones (no presence flags: they default to the identity's).
wjd_DOMMatrixInit :: struct {
	base:     wjd_DOMMatrix2DInit,
	is2D:     bool,
	has_is2D: bool,
	m13, m14, m23, m24, m31, m32, m33, m34, m43, m44: f64,
}

// wjd_DOMPointInit: fields are w, x, y, z (in that order).
wjd_DOMPointInit :: struct {
	w, x, y, z: f64,
}

// wjd_DOMQuadInit.
wjd_DOMQuadInit :: struct {
	p1: wjd_DOMPointInit, has_p1: bool,
	p2: wjd_DOMPointInit, has_p2: bool,
	p3: wjd_DOMPointInit, has_p3: bool,
	p4: wjd_DOMPointInit, has_p4: bool,
}

// wjd_ImageDataSettings.
wjd_ImageDataSettings :: struct {
	colorSpace:     wj.Str,
	has_colorSpace: bool,
	pixelFormat:    wj.Str,
}

// wasm32 C layouts (natural alignment): what gen/bindings.h gives the same structs.
#assert(size_of(wjd_DOMMatrix2DInit) == 192 && offset_of(wjd_DOMMatrix2DInit, has_m42) == 184)
#assert(size_of(wjd_DOMMatrixInit) == 280 && offset_of(wjd_DOMMatrixInit, m13) == 200)
#assert(size_of(wjd_DOMQuadInit) == 160 && offset_of(wjd_DOMQuadInit, p4) == 120)
#assert(size_of(wjd_ImageDataSettings) == 28 && offset_of(wjd_ImageDataSettings, pixelFormat) == 16)

@(default_calling_convention = "c")
foreign {
	wjd_DOMMatrix2DInit_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_DOMMatrix2DInit) -> bool ---
	wjd_DOMMatrix2DInit_free :: proc(ctx: ^wj.Context, d: ^wjd_DOMMatrix2DInit) ---
	wjd_DOMMatrixInit_from   :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_DOMMatrixInit) -> bool ---
	wjd_DOMMatrixInit_free   :: proc(ctx: ^wj.Context, d: ^wjd_DOMMatrixInit) ---
	wjd_DOMPointInit_from    :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_DOMPointInit) -> bool ---
	wjd_DOMPointInit_free    :: proc(ctx: ^wj.Context, d: ^wjd_DOMPointInit) ---
	wjd_DOMQuadInit_from     :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_DOMQuadInit) -> bool ---
	wjd_DOMQuadInit_free     :: proc(ctx: ^wj.Context, d: ^wjd_DOMQuadInit) ---
	wjd_ImageDataSettings_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_ImageDataSettings) -> bool ---
	wjd_ImageDataSettings_free :: proc(ctx: ^wj.Context, d: ^wjd_ImageDataSettings) ---
}
