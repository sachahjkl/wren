// wjd_g1.odin: the generated Web IDL dictionaries (gen/bindings.c wjd_*) the G1 glue reads. The _from / _free
// functions are real symbols in the generated C (bindings.c, which stays); this file mirrors each struct's layout
// exactly (field order and types from gen/bindings.h) so the engine fills it in place, and declares the two functions
// foreign. Do not reorder fields: the layout must match the C.
package odin_glue

import "../odin/wj"

// wjd_ResizeObserverOptions (ResizeObserver.observe) — gen/bindings.h.
wjd_ResizeObserverOptions :: struct {
	box: wj.Str,
}

// wjd_DOMRectInit (gen/bindings.h): fields are height, width, x, y (in that order).
wjd_DOMRectInit :: struct {
	height: f64,
	width:  f64,
	x:      f64,
	y:      f64,
}

// wjd_IntersectionObserverInit (gen/bindings.h).
wjd_IntersectionObserverInit :: struct {
	delay:            i32,
	root:             wj.JSValue,   // (Element or Document)?
	rootMargin:       wj.Str,
	scrollMargin:     wj.Str,
	threshold:        wj.JSValue,   // (double or sequence<double>)
	trackVisibility:  bool,
}

// wjd_IntersectionObserverEntryInit (gen/bindings.h): each member followed by its has_* presence flag.
wjd_IntersectionObserverEntryInit :: struct {
	boundingClientRect:     wjd_DOMRectInit,
	has_boundingClientRect: bool,
	intersectionRatio:      f64,
	has_intersectionRatio:  bool,
	intersectionRect:       wjd_DOMRectInit,
	has_intersectionRect:   bool,
	isIntersecting:         bool,
	has_isIntersecting:     bool,
	isVisible:              bool,
	has_isVisible:          bool,
	rootBounds:             wj.JSValue,   // DOMRectInit?
	has_rootBounds:         bool,
	target:                 wj.JSValue,   // Element
	has_target:             bool,
	time:                   f64,
	has_time:               bool,
}

@(default_calling_convention = "c")
foreign {
	wjd_ResizeObserverOptions_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_ResizeObserverOptions) -> bool ---
	wjd_ResizeObserverOptions_free :: proc(ctx: ^wj.Context, d: ^wjd_ResizeObserverOptions) ---
	wjd_DOMRectInit_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_DOMRectInit) -> bool ---
	wjd_DOMRectInit_free :: proc(ctx: ^wj.Context, d: ^wjd_DOMRectInit) ---
	wjd_IntersectionObserverInit_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_IntersectionObserverInit) -> bool ---
	wjd_IntersectionObserverInit_free :: proc(ctx: ^wj.Context, d: ^wjd_IntersectionObserverInit) ---
	wjd_IntersectionObserverEntryInit_from :: proc(ctx: ^wj.Context, v: wj.JSValue, out: ^wjd_IntersectionObserverEntryInit) -> bool ---
	wjd_IntersectionObserverEntryInit_free :: proc(ctx: ^wj.Context, d: ^wjd_IntersectionObserverEntryInit) ---
}
