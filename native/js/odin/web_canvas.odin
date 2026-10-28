// web_canvas.odin: the 2D canvas of JavaScript (HTMLCanvasElement.getContext, the CanvasRenderingContext2D members
// whose arguments are unions or overloads, ImageData, Path2D, OffscreenCanvas, createImageBitmap). Ported from
// native/js/runtime/web_canvas.c, same symbols and messages.
//
// The simple members of the context are the generated glue of api/canvas.widl (module canvas); what is here is what
// Web IDL's overload resolution and unions need a hand for, on the declarations of api_decl/canvas.odin through jsb
// (no hand-typed transmission). The drawing itself is in the browser (package canvas2d): a context is a browser
// object, ImageData is the engine's (its Uint8ClampedArray lives in this heap).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") Ctx2D :: api_decl.CanvasRenderingContext2D
@(private = "file") ImageData :: distinct u64   // an engine object
@(private = "file") none: abi.Nothing

// ---- helpers ----

@(private = "file")
num :: #force_inline proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^f64) -> bool { return wj.wj_to_double(ctx, v, out, false) }

// arguments [first, first + n) as unrestricted doubles; the arity error names `what`
@(private = "file")
nums :: proc "contextless" (ctx: ^wj.Context, what: cstring, argc: i32, argv: [^]wj.JSValue, first, n: i32, out: []f64) -> bool {
	if argc < first + n { wj.wj_throw_arity(ctx, what, first + n, argc); return false }
	for i in 0 ..< n {
		if !num(ctx, argv[first + i], &out[i]) { return false }
	}
	return true
}

@(private = "file")
is_finite :: #force_inline proc "contextless" (x: f64) -> bool { return x == x && x - x == 0 }

// `this` of a member shared by CanvasRenderingContext2D and OffscreenCanvasRenderingContext2D (both are the host's
// context kind)
@(private = "file")
ctx_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (Ctx2D, bool) {
	o := wj.wj_unwrap(this_val, jsb.iface_of(api_decl.CanvasRenderingContext2D))
	if o == nil { o = wj.wj_unwrap(this_val, jsb.iface_of(api_decl.OffscreenCanvasRenderingContext2D)) }
	if o == nil { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return 0, false }
	return Ctx2D(o.handle), true
}

// The string of a value (DOMString), compared byte for byte.
@(private = "file")
str_is :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, want: string, bad: ^bool = nil) -> bool {
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { if bad != nil { bad^ = true }; return false }
	r := string(wj.str_slice(s)) == want
	wj.wj_str_free(ctx, &s)
	return r
}

// ---- getContext ----

@(private = "file")
context_options :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue, alpha, wrf: ^bool) -> bool {
	alpha^ = true
	wrf^ = false
	if !wj.is_object(options) { return true }
	a := wj.JS_GetPropertyStr(ctx, options, "alpha")
	if wj.is_exception(a) { return false }
	if !wj.is_undefined(a) { alpha^ = wj.JS_ToBool(ctx, a) != 0 }
	wj.JS_FreeValue(ctx, a)
	w := wj.JS_GetPropertyStr(ctx, options, "willReadFrequently")
	if wj.is_exception(w) { return false }
	if !wj.is_undefined(w) { wrf^ = wj.JS_ToBool(ctx, w) != 0 }
	wj.JS_FreeValue(ctx, w)
	return true
}

// ImageBitmapRenderingContextSettings {alpha}
@(private = "file")
bitmaprenderer_alpha :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue) -> bool {
	if !wj.is_object(options) { return true }
	a := wj.JS_GetPropertyStr(ctx, options, "alpha")
	alpha := wj.is_undefined(a) ? true : wj.JS_ToBool(ctx, a) != 0
	wj.JS_FreeValue(ctx, a)
	return alpha
}

// A context wrapper that keeps its canvas alive (context.canvas is the element or the OffscreenCanvas).
@(private = "file")
context_wrap :: proc "contextless" (ctx: ^wj.Context, h: u64, iface: i32, canvas: wj.JSValue) -> wj.JSValue {
	if h == 0 { return wj.NULL }
	v := wj.wj_wrap_host(ctx, h, iface)
	if !wj.is_exception(v) && wj.is_object(v) { wj.web_extra_set(ctx, v, "canvas", wj.JS_DupValue(ctx, canvas)) }
	return v
}

// getContext of an element (C = HTMLCanvasElement) or an OffscreenCanvas: "2d", "bitmaprenderer", anything else null
@(private = "file")
get_context :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, $C: typeid, what: cstring) -> wj.JSValue {
	canvas, ok := jsb.this(ctx, this_val, C)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, what, 1, argc) }
	bad: bool
	two_d := str_is(ctx, argv[0], "2d", &bad)
	if bad { return wj.EXCEPTION }
	if !two_d {
		if !str_is(ctx, argv[0], "bitmaprenderer") { return wj.NULL }   // webgl, webgl2, webgpu: none here
		alpha := bitmaprenderer_alpha(ctx, wj.arg(argc, argv, 1))
		h: api_decl.ImageBitmapRenderingContext
		st: abi.Api_Error
		when C == api_decl.HTMLCanvasElement {
			st = jsb.host(&h, api_decl.HTMLCanvasElement_bitmapRenderer, wj.wr_HTMLCanvasElement_bitmapRenderer, canvas, alpha)
		} else {
			st = jsb.host(&h, api_decl.OffscreenCanvas_bitmapRenderer, wj.wr_OffscreenCanvas_bitmapRenderer, canvas, alpha)
		}
		if st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
		return context_wrap(ctx, u64(h), jsb.iface_of(api_decl.ImageBitmapRenderingContext), this_val)
	}
	alpha, wrf: bool
	if !context_options(ctx, wj.arg(argc, argv, 1), &alpha, &wrf) { return wj.EXCEPTION }
	when C == api_decl.HTMLCanvasElement {
		h: api_decl.CanvasRenderingContext2D
		st := jsb.host(&h, api_decl.HTMLCanvasElement_context2d, wj.wr_HTMLCanvasElement_context2d, canvas, alpha, wrf)
	} else {
		h: api_decl.OffscreenCanvasRenderingContext2D
		st := jsb.host(&h, api_decl.OffscreenCanvas_context2d, wj.wr_OffscreenCanvas_context2d, canvas, alpha, wrf)
	}
	if st != .None { return wj.wj_throw_status(ctx, i32(st), what) }
	return context_wrap(ctx, u64(h), jsb.iface_of(type_of(h)), this_val)
}

@(export, link_name = "wjr_HTMLCanvasElement_getContext")
wjr_HTMLCanvasElement_getContext :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return get_context(ctx, this_val, argc, argv, api_decl.HTMLCanvasElement, "HTMLCanvasElement.getContext")
}

@(export, link_name = "wjr_OffscreenCanvas_getContext")
wjr_OffscreenCanvas_getContext :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	return get_context(ctx, this_val, argc, argv, api_decl.OffscreenCanvas, "OffscreenCanvas.getContext")
}

@(export, link_name = "wjr_CanvasSettings_getContextAttributes")
wjr_CanvasSettings_getContextAttributes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	alpha, wrf: bool
	jsb.host(&alpha, api_decl.CanvasSettings_alpha, wj.wr_CanvasSettings_alpha, c)
	jsb.host(&wrf, api_decl.CanvasSettings_willReadFrequently, wj.wr_CanvasSettings_willReadFrequently, c)
	r := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, r, "alpha", wj.new_bool(alpha))
	wj.JS_SetPropertyStr(ctx, r, "desynchronized", wj.FALSE)
	wj.JS_SetPropertyStr(ctx, r, "colorSpace", wj.new_string(ctx, "srgb"))
	wj.JS_SetPropertyStr(ctx, r, "colorType", wj.new_string(ctx, "unorm8"))
	wj.JS_SetPropertyStr(ctx, r, "willReadFrequently", wj.new_bool(wrf))
	return r
}

// ---- ImageBitmapRenderingContext ----

@(export, link_name = "wjr_ImageBitmapRenderingContext_get_canvas")
wjr_ImageBitmapRenderingContext_get_canvas :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.ImageBitmapRenderingContext)) == nil { return wj.EXCEPTION }
	// kept under web_extra at getContext time (the element node wrapper or the OffscreenCanvas object)
	c := wj.web_extra_get(ctx, this_val, "canvas")
	if wj.is_object(c) { return c }
	wj.JS_FreeValue(ctx, c)
	return wj.NULL
}

@(export, link_name = "wjr_ImageBitmapRenderingContext_transferFromImageBitmap")
wjr_ImageBitmapRenderingContext_transferFromImageBitmap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.ImageBitmapRenderingContext))
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "transferFromImageBitmap", 1, argc) }
	bitmap: u64
	has := false
	if !wj.is_nullish(argv[0]) {
		b := wj.wj_unwrap(argv[0], jsb.iface_of(api_decl.ImageBitmap))
		if b == nil { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'transferFromImageBitmap': the argument is not an ImageBitmap") }
		bitmap = b.handle
		has = true
	}
	st := jsb.host(&none, api_decl.ImageBitmapRenderingContext_transferFromImageBitmap, wj.wr_ImageBitmapRenderingContext_transferFromImageBitmap,
		api_decl.ImageBitmapRenderingContext(o.handle), bitmap, has)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "transferFromImageBitmap") }
	return wj.UNDEFINED
}

// ---- OffscreenCanvas ----

@(export, link_name = "wjr_OffscreenCanvas_constructor")
wjr_OffscreenCanvas_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor OffscreenCanvas requires 'new'") }
	if argc < 2 { return wj.wj_throw_arity(ctx, "OffscreenCanvas", 2, argc) }
	w, h: u64
	if !wj.wj_to_uint64(ctx, argv[0], &w, wj.ENFORCE_RANGE) || !wj.wj_to_uint64(ctx, argv[1], &h, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
	c: abi.Owned(api_decl.OffscreenCanvas)
	if st := jsb.host(&c, api_decl.OffscreenCanvas_create, wj.wr_OffscreenCanvas_create, w, h); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "OffscreenCanvas")
	}
	return wj.wj_wrap_owned(ctx, u64(c.handle), jsb.iface_of(api_decl.OffscreenCanvas), new_target)
}

// ---- encoding: toDataURL, toBlob, convertToBlob ----

@(private = "file") B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// The type to encode as: PNG unless JPEG was asked for (the only two this browser writes).
@(private = "file")
encode_type :: proc "contextless" (t: wj.Str) -> string {
	s := wj.str_slice(t)
	if len(s) == 10 && wj.web_ascii_ieq(raw_data(s), 10, "image/jpeg") { return "image/jpeg" }
	if len(s) == 9 && wj.web_ascii_ieq(raw_data(s), 9, "image/jpg") { return "image/jpeg" }
	return "image/png"
}

// quality: a number from 0 to 1, else -1 (the browser's default)
@(private = "file")
encode_quality :: proc "contextless" (ctx: ^wj.Context, q: wj.JSValue) -> f64 {
	d: f64
	if !wj.is_number(q) || wj.JS_ToFloat64(ctx, &d, q) < 0 { return -1 }
	return d >= 0 && d <= 1 ? d : -1
}

// The encoded bytes of a canvas (an element or an OffscreenCanvas handle), in an ArrayBuffer `keep` the caller frees
// (undefined and no bytes for a canvas with no pixels). False: an exception is pending.
@(private = "file")
encode_canvas :: proc(ctx: ^wj.Context, canvas: u64, type: string, quality: f64, keep: ^wj.JSValue) -> (bytes: []u8, ok: bool) {
	keep^ = wj.UNDEFINED
	buf: u64
	if st := jsb.host(&buf, api_decl.Canvas_encode, wj.wr_Canvas_encode, canvas, type, quality); st != .None {
		wj.wj_throw_status(ctx, i32(st), "toDataURL")
		return nil, false
	}
	if buf == 0 { return nil, true }
	ab := wj.wj_arraybuffer_from_host(ctx, buf)
	wj.wr_Object_release(buf)
	if wj.is_exception(ab) { return nil, false }
	got: uint
	p := wj.JS_GetArrayBuffer(ctx, &got, ab)
	keep^ = ab
	return p != nil ? p[:got] : nil, true
}

@(export, link_name = "wjr_HTMLCanvasElement_toDataURL")
wjr_HTMLCanvasElement_toDataURL :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.HTMLCanvasElement))
	if o == nil { return wj.EXCEPTION }
	t: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &t, 0, "image/png") { return wj.EXCEPTION }
	type := encode_type(t)
	wj.wj_str_free(ctx, &t)
	ab: wj.JSValue
	p, ok := encode_canvas(ctx, o.handle, type, encode_quality(ctx, wj.arg(argc, argv, 1)), &ab)
	if !ok { return wj.EXCEPTION }
	defer wj.JS_FreeValue(ctx, ab)
	if len(p) == 0 { return wj.new_string(ctx, "data:,") }
	head := len(type) + 13   // data:TYPE;base64,
	total := head + (len(p) + 2) / 3 * 4
	out := ([^]u8)(wj.js_malloc(ctx, uint(total) + 1))
	if out == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	w := 0
	put :: #force_inline proc "contextless" (out: [^]u8, w: ^int, s: string) { for i in 0 ..< len(s) { out[w^] = s[i]; w^ += 1 } }
	put(out, &w, "data:"); put(out, &w, type); put(out, &w, ";base64,")
	n := len(p)
	for i := 0; i < n; i += 3 {
		v := u32(p[i]) << 16 | (i + 1 < n ? u32(p[i + 1]) << 8 : 0) | (i + 2 < n ? u32(p[i + 2]) : 0)
		out[w] = B64[(v >> 18) & 63]
		out[w + 1] = B64[(v >> 12) & 63]
		out[w + 2] = i + 1 < n ? B64[(v >> 6) & 63] : '='
		out[w + 3] = i + 2 < n ? B64[v & 63] : '='
		w += 4
	}
	s := wj.JS_NewStringLen(ctx, out, uint(total))
	wj.js_free(ctx, out)
	return s
}

// the callback of toBlob, run from a task of its own with the blob (or null)
@(private = "file")
blob_callback_task :: proc "c" (ctx: ^wj.Context, data: wj.JSValue) {
	cb := wj.JS_GetPropertyUint32(ctx, data, 0)
	blob := wj.JS_GetPropertyUint32(ctx, data, 1)
	r := wj.JS_Call(ctx, cb, wj.UNDEFINED, 1, &blob)
	if wj.is_exception(r) { wj.wj_report_exception(ctx, wj.JS_GetException(ctx)) } else { wj.JS_FreeValue(ctx, r) }
	wj.JS_FreeValue(ctx, cb)
	wj.JS_FreeValue(ctx, blob)
}

@(private = "file")
blob_of :: proc "contextless" (ctx: ^wj.Context, p: []u8, type: string) -> wj.JSValue {
	return web_blob_new(ctx, raw_data(p), uint(len(p)), cstring(raw_data(type)), uint(len(type)))
}

@(export, link_name = "wjr_HTMLCanvasElement_toBlob")
wjr_HTMLCanvasElement_toBlob :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.HTMLCanvasElement))
	if o == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "HTMLCanvasElement.toBlob", 1, argc) }
	if !wj.JS_IsFunction(ctx, argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'toBlob' on 'HTMLCanvasElement': The callback provided as parameter 1 is not a function.") }
	t: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &t, 0, "image/png") { return wj.EXCEPTION }
	type := encode_type(t)
	wj.wj_str_free(ctx, &t)
	ab: wj.JSValue
	p, ok := encode_canvas(ctx, o.handle, type, encode_quality(ctx, wj.arg(argc, argv, 2)), &ab)
	if !ok { return wj.EXCEPTION }
	blob := len(p) > 0 ? blob_of(ctx, p, type) : wj.NULL
	wj.JS_FreeValue(ctx, ab)
	if wj.is_exception(blob) { return blob }
	pair := wj.JS_NewArray(ctx)
	wj.JS_SetPropertyUint32(ctx, pair, 0, wj.JS_DupValue(ctx, argv[0]))
	wj.JS_SetPropertyUint32(ctx, pair, 1, blob)
	queued := wj.web_queue_task(ctx, blob_callback_task, pair)
	wj.JS_FreeValue(ctx, pair)
	return queued ? wj.UNDEFINED : wj.JS_ThrowOutOfMemory(ctx)
}

@(export, link_name = "wjr_OffscreenCanvas_convertToBlob")
wjr_OffscreenCanvas_convertToBlob :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(api_decl.OffscreenCanvas))
	if o == nil { return wj.web_promise_reject_pending(ctx) }
	opts := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opts, "ImageEncodeOptions") { return wj.web_promise_reject_pending(ctx) }
	tv, qv: wj.JSValue
	if !wj.web_dict_get(ctx, opts, "type", &tv) { return wj.web_promise_reject_pending(ctx) }
	if !wj.web_dict_get(ctx, opts, "quality", &qv) { wj.JS_FreeValue(ctx, tv); return wj.web_promise_reject_pending(ctx) }
	t: wj.Str
	sok := wj.wj_to_str(ctx, tv, &t, 0, "image/png")
	wj.JS_FreeValue(ctx, tv)
	if !sok { wj.JS_FreeValue(ctx, qv); return wj.web_promise_reject_pending(ctx) }
	type := encode_type(t)
	wj.wj_str_free(ctx, &t)
	q := encode_quality(ctx, qv)
	wj.JS_FreeValue(ctx, qv)
	ab: wj.JSValue
	p, ok := encode_canvas(ctx, o.handle, type, q, &ab)
	if !ok { return wj.web_promise_reject_pending(ctx) }
	if len(p) == 0 {
		wj.JS_FreeValue(ctx, ab)
		return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "IndexSizeError", "The canvas has a width or height of zero."))
	}
	blob := blob_of(ctx, p, type)
	wj.JS_FreeValue(ctx, ab)
	if wj.is_exception(blob) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, blob)
}

// ---- styles ----

@(private = "file")
style_get :: proc(ctx: ^wj.Context, this_val: wj.JSValue, stroke: bool) -> wj.JSValue {
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	kind: api_decl.CanvasStyleKind
	jsb.host(&kind, api_decl.CanvasStyle_kind, wj.wr_CanvasStyle_kind, c, stroke)
	if kind == .Color {
		s: string
		jsb.host(&s, api_decl.CanvasStyle_color, wj.wr_CanvasStyle_color, c, stroke)
		return wj.new_string_len(ctx, s)
	}
	h: u64
	jsb.host(&h, api_decl.CanvasStyle_object, wj.wr_CanvasStyle_object, c, stroke)
	if h == 0 { return wj.new_string(ctx, "#000000") }
	v := wj.wj_cached(ctx, h)
	if !wj.is_undefined(v) { return wj.JS_DupValue(ctx, v) }
	iface := kind == .Gradient ? jsb.iface_of(api_decl.CanvasGradient) : jsb.iface_of(api_decl.CanvasPattern)
	return wj.wj_wrap_owned(ctx, h, iface, wj.UNDEFINED)
}

@(private = "file")
style_set :: proc(ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, stroke: bool) -> wj.JSValue {
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	g: ^wj.Obj
	if wj.is_object(v) {
		g = wj.wj_unwrap(v, jsb.iface_of(api_decl.CanvasGradient))
		if g == nil { g = wj.wj_unwrap(v, jsb.iface_of(api_decl.CanvasPattern)) }
	}
	if g != nil {
		jsb.host(&none, api_decl.CanvasStyle_setObject, wj.wr_CanvasStyle_setObject, c, stroke, g.handle)
		return wj.UNDEFINED
	}
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, nil) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.CanvasStyle_setColor, wj.wr_CanvasStyle_setColor, c, stroke, str_text(s))   // an invalid colour is ignored
	wj.wj_str_free(ctx, &s)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CanvasFillStrokeStyles_get_fillStyle")
wjr_CanvasFillStrokeStyles_get_fillStyle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return style_get(ctx, t, false) }
@(export, link_name = "wjr_CanvasFillStrokeStyles_get_strokeStyle")
wjr_CanvasFillStrokeStyles_get_strokeStyle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return style_get(ctx, t, true) }
@(export, link_name = "wjr_CanvasFillStrokeStyles_set_fillStyle")
wjr_CanvasFillStrokeStyles_set_fillStyle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return style_set(ctx, t, v, false) }
@(export, link_name = "wjr_CanvasFillStrokeStyles_set_strokeStyle")
wjr_CanvasFillStrokeStyles_set_strokeStyle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, v: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return style_set(ctx, t, v, true) }

// The handle of an image source, 0 when it is none (a TypeError is then pending).
@(private = "file")
image_source :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, what: cstring) -> u64 {
	if h := image_source_handle(v); h != 0 { return h }
	wj.JS_ThrowTypeError(ctx, "Failed to execute '%s': The provided value is not of type '(HTMLOrSVGImageElement or HTMLVideoElement or HTMLCanvasElement or ImageBitmap or OffscreenCanvas or VideoFrame)'.", what)
	return 0
}

@(export, link_name = "wjr_CanvasFillStrokeStyles_createPattern")
wjr_CanvasFillStrokeStyles_createPattern :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.createPattern", 2, argc) }
	src := image_source(ctx, argv[0], "createPattern on 'CanvasRenderingContext2D'")
	if src == 0 { return wj.EXCEPTION }
	rep: wj.Str
	// [LegacyNullToEmptyString]
	if !wj.wj_to_str(ctx, argv[1], &rep, wj.STR_NULL_EMPTY, nil) { return wj.EXCEPTION }
	h: abi.Owned(api_decl.CanvasPattern)
	st := jsb.host(&h, api_decl.Canvas_createPattern, wj.wr_Canvas_createPattern, c, src, str_text(rep))
	wj.wj_str_free(ctx, &rep)
	if st == .Not_Found { return wj.NULL }
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "CanvasRenderingContext2D.createPattern") }
	return wj.wj_wrap_owned(ctx, u64(h.handle), jsb.iface_of(api_decl.CanvasPattern), wj.UNDEFINED)
}

// ---- transforms ----

// DOMMatrix2DInit -> a b c d e f ("validate and fixup": a and m11 name the same number)
@(private = "file")
matrix_init :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, m: ^[6]f64) -> bool {
	d: wjd_DOMMatrix2DInit
	if !wjd_DOMMatrix2DInit_from(ctx, v, &d) { return false }
	ok := true
	pair :: proc "contextless" (ok: ^bool, a: f64, ha: bool, b: f64, hb: bool, def: f64) -> f64 {
		if ha && hb && !(a == b || (a != a && b != b)) { ok^ = false }
		return ha ? a : (hb ? b : def)
	}
	m[0] = pair(&ok, d.a, d.has_a, d.m11, d.has_m11, 1)
	m[1] = pair(&ok, d.b, d.has_b, d.m12, d.has_m12, 0)
	m[2] = pair(&ok, d.c, d.has_c, d.m21, d.has_m21, 0)
	m[3] = pair(&ok, d.d, d.has_d, d.m22, d.has_m22, 1)
	m[4] = pair(&ok, d.e, d.has_e, d.m41, d.has_m41, 0)
	m[5] = pair(&ok, d.f, d.has_f, d.m42, d.has_m42, 0)
	wjd_DOMMatrix2DInit_free(ctx, &d)
	if !ok { wj.JS_ThrowTypeError(ctx, "The a and m11 members (and the other aliased pairs) must have the same value.") }
	return ok
}

@(export, link_name = "wjr_CanvasTransform_setTransform")
wjr_CanvasTransform_setTransform :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	m: [6]f64
	if argc >= 2 {
		if !nums(ctx, "CanvasRenderingContext2D.setTransform", argc, argv, 0, 6, m[:]) { return wj.EXCEPTION }
	} else if !matrix_init(ctx, wj.arg(argc, argv, 0), &m) {
		return wj.EXCEPTION
	}
	jsb.host_n(&none, api_decl.CanvasTransform_setTransform, wj.wr_CanvasTransform_setTransform, c, m[0], m[1], m[2], m[3], m[4], m[5])
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CanvasTransform_getTransform")
wjr_CanvasTransform_getTransform :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	m: [6]f64
	for i in 0 ..< 6 { jsb.host(&m[i], api_decl.CanvasTransform_matrixElement, wj.wr_CanvasTransform_matrixElement, c, i32(i)) }
	return web_dommatrix_new_2d(ctx, &m)
}

@(export, link_name = "wjr_CanvasPattern_setTransform")
wjr_CanvasPattern_setTransform :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	p, ok := jsb.this(ctx, this_val, api_decl.CanvasPattern)
	if !ok { return wj.EXCEPTION }
	m: [6]f64
	if !matrix_init(ctx, wj.arg(argc, argv, 0), &m) { return wj.EXCEPTION }
	jsb.host_n(&none, api_decl.CanvasPattern_setTransformMatrix, wj.wr_CanvasPattern_setTransformMatrix, p, m[0], m[1], m[2], m[3], m[4], m[5])
	return wj.UNDEFINED
}

// ---- paths ----

@(private = "file") Fill_Rule :: enum { Nonzero, Evenodd }
@(private = "file") RULE_NAMES := [Fill_Rule]string{.Nonzero = "nonzero", .Evenodd = "evenodd"}

// a CanvasFillRule argument (undefined: nonzero); false with a TypeError for another string
@(private = "file")
fill_rule :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^Fill_Rule) -> bool {
	out^ = .Nonzero
	if wj.is_undefined(v) { return true }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "nonzero") { return false }
	rules := [3]cstring{"nonzero", "evenodd", nil}
	i := wj.wj_enum_index(&s, &rules[0])
	if i < 0 { return wj.wj_check_enum(ctx, &s, &rules[0], "CanvasFillRule") }
	wj.wj_str_free(ctx, &s)
	out^ = Fill_Rule(i)
	return true
}

// fill(), fill(rule), fill(path), fill(path, rule) ...
@(private = "file")
path_and_rule :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, takes_rule: bool, path: ^u64, rule: ^Fill_Rule) -> bool {
	path^ = 0
	rule^ = .Nonzero
	at := i32(0)
	if argc > 0 && wj.is_object(argv[0]) {
		p := wj.wj_unwrap(argv[0], jsb.iface_of(api_decl.Path2D))
		if p == nil { wj.JS_ThrowTypeError(ctx, "The provided value is not of type 'Path2D'."); return false }
		path^ = p.handle
		at = 1
	}
	if takes_rule && argc > at { return fill_rule(ctx, argv[at], rule) }
	return true
}

@(export, link_name = "wjr_CanvasDrawPath_fill")
wjr_CanvasDrawPath_fill :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	path: u64
	rule: Fill_Rule
	if !path_and_rule(ctx, argc, argv, true, &path, &rule) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.CanvasDrawPath_fill, wj.wr_CanvasDrawPath_fill, c, path, RULE_NAMES[rule])
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CanvasDrawPath_stroke")
wjr_CanvasDrawPath_stroke :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	path: u64
	rule: Fill_Rule
	if !path_and_rule(ctx, argc, argv, false, &path, &rule) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.CanvasDrawPath_stroke, wj.wr_CanvasDrawPath_stroke, c, path)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CanvasDrawPath_clip")
wjr_CanvasDrawPath_clip :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	path: u64
	rule: Fill_Rule
	if !path_and_rule(ctx, argc, argv, true, &path, &rule) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.CanvasDrawPath_clip, wj.wr_CanvasDrawPath_clip, c, path, RULE_NAMES[rule])
	return wj.UNDEFINED
}

// isPointInPath(x, y [, rule]), isPointInPath(path, x, y [, rule]); isPointInStroke(x, y), isPointInStroke(path, x, y)
@(private = "file")
point_in :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, stroke: bool) -> wj.JSValue {
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	what: cstring = stroke ? "CanvasRenderingContext2D.isPointInStroke" : "CanvasRenderingContext2D.isPointInPath"
	path: u64
	at := i32(0)
	if argc > 0 && wj.is_object(argv[0]) {
		p := wj.wj_unwrap(argv[0], jsb.iface_of(api_decl.Path2D))
		if p == nil { return wj.JS_ThrowTypeError(ctx, "%s: parameter 1 is not of type 'Path2D'.", what) }
		path = p.handle
		at = 1
	}
	xy: [2]f64
	if !nums(ctx, what, argc, argv, at, 2, xy[:]) { return wj.EXCEPTION }
	rule: Fill_Rule
	if !stroke && argc > at + 2 && !fill_rule(ctx, argv[at + 2], &rule) { return wj.EXCEPTION }
	r: bool
	if stroke {
		jsb.host(&r, api_decl.CanvasDrawPath_isPointInStroke, wj.wr_CanvasDrawPath_isPointInStroke, c, path, xy[0], xy[1])
	} else {
		jsb.host_n(&r, api_decl.CanvasDrawPath_isPointInPath, wj.wr_CanvasDrawPath_isPointInPath, c, path, xy[0], xy[1], RULE_NAMES[rule])
	}
	return wj.new_bool(r)
}

@(export, link_name = "wjr_CanvasDrawPath_isPointInPath")
wjr_CanvasDrawPath_isPointInPath :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return point_in(ctx, t, argc, argv, false) }
@(export, link_name = "wjr_CanvasDrawPath_isPointInStroke")
wjr_CanvasDrawPath_isPointInStroke :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return point_in(ctx, t, argc, argv, true) }

// the focus ring of an element in the canvas's fallback content: nothing to draw
@(export, link_name = "wjr_CanvasUserInterface_drawFocusIfNeeded")
wjr_CanvasUserInterface_drawFocusIfNeeded :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.UNDEFINED }

@(export, link_name = "wjr_CanvasPathDrawingStyles_setLineDash")
wjr_CanvasPathDrawingStyles_setLineDash :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.setLineDash", 1, argc) }
	if !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "The provided value cannot be converted to a sequence.") }
	lenv := wj.JS_GetPropertyStr(ctx, argv[0], "length")
	n: u32
	rc := wj.JS_ToUint32(ctx, &n, lenv)
	wj.JS_FreeValue(ctx, lenv)
	if rc < 0 { return wj.EXCEPTION }
	n = min(n, 65536)
	d: [^]f64
	if n > 0 {
		d = ([^]f64)(wj.js_malloc(ctx, uint(n) * size_of(f64)))
		if d == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	}
	defer if d != nil { wj.js_free(ctx, d) }
	for i in 0 ..< n {
		e := wj.JS_GetPropertyUint32(ctx, argv[0], i)
		eok := !wj.is_exception(e) && wj.JS_ToFloat64(ctx, &d[i], e) == 0
		wj.JS_FreeValue(ctx, e)
		if !eok { return wj.EXCEPTION }
	}
	jsb.host(&none, api_decl.CanvasPathDrawingStyles_setLineDash, wj.wr_CanvasPathDrawingStyles_setLineDash, c, d[:n])
	return wj.UNDEFINED
}

@(export, link_name = "wjr_CanvasPathDrawingStyles_getLineDash")
wjr_CanvasPathDrawingStyles_getLineDash :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	n: i32
	jsb.host(&n, api_decl.CanvasPathDrawingStyles_lineDashCount, wj.wr_CanvasPathDrawingStyles_lineDashCount, c)
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< n {
		x: f64
		jsb.host(&x, api_decl.CanvasPathDrawingStyles_lineDashAt, wj.wr_CanvasPathDrawingStyles_lineDashAt, c, i)
		wj.JS_SetPropertyUint32(ctx, arr, u32(i), wj.new_float64(ctx, x))
	}
	return arr
}

// roundRect(x, y, w, h [, radii]): radii is a number, a DOMPointInit, or a list of 1 to 4 of them
@(private = "file")
corner_radius :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, r: ^[2]f64) -> bool {
	if wj.is_object(v) {
		p: wjd_DOMPointInit
		if !wjd_DOMPointInit_from(ctx, v, &p) { return false }
		r^ = {p.x, p.y}
		wjd_DOMPointInit_free(ctx, &p)
		return true
	}
	if !num(ctx, v, &r[0]) { return false }
	r[1] = r[0]
	return true
}

@(export, link_name = "wjr_CanvasPath_roundRect")
wjr_CanvasPath_roundRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_unwrap(this_val, jsb.iface_of(api_decl.CanvasRenderingContext2D))
	if o == nil { o = wj.wj_unwrap(this_val, jsb.iface_of(api_decl.OffscreenCanvasRenderingContext2D)) }
	if o == nil { o = wj.wj_unwrap(this_val, jsb.iface_of(api_decl.Path2D)) }
	if o == nil { return wj.JS_ThrowTypeError(ctx, "Illegal invocation") }
	r: [4]f64
	if !nums(ctx, "roundRect", argc, argv, 0, 4, r[:]) { return wj.EXCEPTION }
	rv := wj.arg(argc, argv, 4)
	list: [4][2]f64
	count := 0
	if wj.is_undefined(rv) {
		count = 1
	} else if wj.is_object(rv) && wj.web_is_iterable(ctx, rv) == 1 {
		lenv := wj.JS_GetPropertyStr(ctx, rv, "length")
		n: u32
		rc := wj.JS_ToUint32(ctx, &n, lenv)
		wj.JS_FreeValue(ctx, lenv)
		if rc < 0 { return wj.EXCEPTION }
		if n < 1 || n > 4 { return wj.JS_ThrowRangeError(ctx, "%u radii provided. Between one and four radii are necessary.", n) }
		for i in 0 ..< n {
			e := wj.JS_GetPropertyUint32(ctx, rv, i)
			eok := !wj.is_exception(e) && corner_radius(ctx, e, &list[i])
			wj.JS_FreeValue(ctx, e)
			if !eok { return wj.EXCEPTION }
		}
		count = int(n)
	} else {
		if !corner_radius(ctx, rv, &list[0]) { return wj.EXCEPTION }
		count = 1
	}
	// CSS border-radius shorthand order: 1 all; 2 (tl, br) (tr, bl); 3 tl (tr, bl) br; 4 tl tr br bl
	corner_map := [4][4]int{{0, 0, 0, 0}, {0, 1, 0, 1}, {0, 1, 2, 1}, {0, 1, 2, 3}}
	radii: [8]f64
	for i in 0 ..< 4 {
		radii[2 * i] = list[corner_map[count - 1][i]][0]
		radii[2 * i + 1] = list[corner_map[count - 1][i]][1]
	}
	for x in radii { if !is_finite(x) { return wj.UNDEFINED } }   // non-finite: the call is ignored
	for x in r { if !is_finite(x) { return wj.UNDEFINED } }
	if st := jsb.host_n(&none, api_decl.CanvasPath_roundRect, wj.wr_CanvasPath_roundRect, o.handle, r[0], r[1], r[2], r[3], radii[:]); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "CanvasRenderingContext2D.roundRect")
	}
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Path2D_constructor")
wjr_Path2D_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor Path2D requires 'new'") }
	from: u64
	svg: wj.Str
	a := wj.arg(argc, argv, 0)
	if !wj.is_undefined(a) {
		p := wj.is_object(a) ? wj.wj_unwrap(a, jsb.iface_of(api_decl.Path2D)) : nil
		if p != nil { from = p.handle } else if !wj.wj_to_str(ctx, a, &svg, 0, nil) { return wj.EXCEPTION }
	}
	h: api_decl.Path2D
	jsb.host(&h, api_decl.Path2D_create, wj.wr_Path2D_create, from, str_text(svg))
	wj.wj_str_free(ctx, &svg)
	return wj.wj_wrap_owned(ctx, u64(h), jsb.iface_of(api_decl.Path2D), new_target)
}

@(export, link_name = "wjr_Path2D_addPath")
wjr_Path2D_addPath :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	target, ok := jsb.this(ctx, this_val, api_decl.Path2D)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Path2D.addPath", 1, argc) }
	p := wj.is_object(argv[0]) ? wj.wj_unwrap(argv[0], jsb.iface_of(api_decl.Path2D)) : nil
	if p == nil { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'addPath' on 'Path2D': parameter 1 is not of type 'Path2D'.") }
	m := [6]f64{1, 0, 0, 1, 0, 0}
	if argc > 1 && !wj.is_undefined(argv[1]) && !matrix_init(ctx, argv[1], &m) { return wj.EXCEPTION }
	jsb.host_n(&none, api_decl.Path2D_addPath, wj.wr_Path2D_addPath, target, api_decl.Path2D(p.handle), m[0], m[1], m[2], m[3], m[4], m[5])
	return wj.UNDEFINED
}

// ---- text ----

@(private = "file")
text_op :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, stroke: bool) -> wj.JSValue {
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	what: cstring = stroke ? "CanvasRenderingContext2D.strokeText" : "CanvasRenderingContext2D.fillText"
	if argc < 3 { return wj.wj_throw_arity(ctx, what, 3, argc) }
	text: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &text, 0, nil) { return wj.EXCEPTION }
	x, y, mw: f64
	has_max := argc > 3 && !wj.is_undefined(argv[3])
	nok := num(ctx, argv[1], &x) && num(ctx, argv[2], &y) && (!has_max || num(ctx, argv[3], &mw))
	if nok {
		if stroke {
			jsb.host_n(&none, api_decl.CanvasText_strokeText, wj.wr_CanvasText_strokeText, c, str_text(text), x, y, mw, has_max)
		} else {
			jsb.host_n(&none, api_decl.CanvasText_fillText, wj.wr_CanvasText_fillText, c, str_text(text), x, y, mw, has_max)
		}
	}
	wj.wj_str_free(ctx, &text)
	return nok ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_CanvasText_fillText")
wjr_CanvasText_fillText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return text_op(ctx, t, argc, argv, false) }
@(export, link_name = "wjr_CanvasText_strokeText")
wjr_CanvasText_strokeText :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return text_op(ctx, t, argc, argv, true) }

// ---- ImageData ----

@(private = "file")
Image_Data :: struct {
	w, h: u32,
	data: wj.JSValue,   // a Uint8ClampedArray (counted)
}

@(private = "file")
image_data_free :: proc "c" (p: rawptr) {
	d := (^Image_Data)(p)
	wj.JS_FreeValueRT(wj.web_rt(), d.data)
	wj.libc_free(p)
}

@(private = "file")
image_data_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	wj.wj_mark(rt, (^Image_Data)(p).data, mark_func)
}

@(private = "file")
image_data_of :: proc "contextless" (v: wj.JSValue) -> ^Image_Data {
	o := wj.is_object(v) ? wj.wj_unwrap(v, jsb.iface_of(ImageData)) : nil
	return o != nil ? (^Image_Data)(o.impl) : nil
}

// An ImageData of w x h taking `array` (a Uint8ClampedArray, counted: taken).
@(private = "file")
image_data_make :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, w, h: u32, array: wj.JSValue) -> wj.JSValue {
	d := (^Image_Data)(wj.libc_calloc(1, size_of(Image_Data)))
	if d == nil { wj.JS_FreeValue(ctx, array); return wj.JS_ThrowOutOfMemory(ctx) }
	d^ = {w, h, array}
	obj := wj.wj_new_object_for(ctx, jsb.iface_of(ImageData), new_target, nil, nil)
	if wj.is_exception(obj) { image_data_free(d); return obj }
	wj.web_set_impl(obj, d, image_data_free, image_data_mark)
	return obj
}

@(private = "file")
too_large :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.JS_ThrowRangeError(ctx, "Out of memory: the image data is too large (canvas.max_image_data_bytes).")
}

@(private = "file")
max_bytes :: proc() -> u64 {
	n: u64
	jsb.host(&n, api_decl.CanvasImageData_maxBytes, wj.wr_CanvasImageData_maxBytes)
	return n
}

// a Uint8ClampedArray over bytes the engine owns (taken; freed on failure)
@(private = "file")
clamped_of :: proc "contextless" (ctx: ^wj.Context, p: [^]u8, n: uint) -> wj.JSValue {
	ab := wj.wj_arraybuffer_take(ctx, p, n)
	if wj.is_exception(ab) { return ab }
	arr := wj.JS_NewTypedArray(ctx, 1, &ab, i32(wj.Typed_Array.Uint8C))
	wj.JS_FreeValue(ctx, ab)
	return arr
}

// a zeroed Uint8ClampedArray of n bytes
@(private = "file")
clamped_zeroes :: proc(ctx: ^wj.Context, n: u64) -> wj.JSValue {
	if n > 0x7fffffff || n > max_bytes() { return too_large(ctx) }
	p := ([^]u8)(wj.js_malloc(ctx, n > 0 ? uint(n) : 1))
	if p == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	wj.memset(p, 0, uint(n))
	return clamped_of(ctx, p, uint(n))
}

@(private = "file")
image_data_settings :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> bool {
	s: wjd_ImageDataSettings
	if !wjd_ImageDataSettings_from(ctx, v, &s) { return false }
	ok := true
	cs := string(wj.str_slice(s.colorSpace))
	if s.has_colorSpace && cs != "srgb" && cs != "display-p3" {
		wj.JS_ThrowTypeError(ctx, "The provided value is not a valid enum value of type PredefinedColorSpace.")
		ok = false
	}
	if ok && s.pixelFormat.ptr != nil && string(wj.str_slice(s.pixelFormat)) != "rgba-unorm8" {
		wj.JS_ThrowTypeError(ctx, "The pixel format is not supported (only rgba-unorm8).")
		ok = false
	}
	wjd_ImageDataSettings_free(ctx, &s)
	return ok
}

@(export, link_name = "wjr_ImageData_constructor")
wjr_ImageData_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor ImageData requires 'new'") }
	if argc < 2 { return wj.wj_throw_arity(ctx, "ImageData", 2, argc) }
	if wj.is_object(argv[0]) {
		if wj.wj_typed_array_type(argv[0]) != i32(wj.Typed_Array.Uint8C) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'ImageData': parameter 1 is not of type 'Uint8ClampedArray'.") }
		sw, sh: u32
		if !wj.wj_to_uint32(ctx, argv[1], &sw, 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
		has_sh := argc > 2 && !wj.is_undefined(argv[2])
		if has_sh && !wj.wj_to_uint32(ctx, argv[2], &sh, 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
		if argc > 3 && !image_data_settings(ctx, argv[3]) { return wj.EXCEPTION }
		p: [^]u8
		n: uint
		if !wj.wj_to_buffer_source(ctx, argv[0], &p, &n, wj.BS_VIEW_ONLY, "ImageData") { return wj.EXCEPTION }
		if n == 0 || n % 4 != 0 { return wj.wj_throw_dom(ctx, "InvalidStateError", "The input data length is not a multiple of 4.") }
		if sw == 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The source width is zero or not a number.") }
		if (n / 4) % uint(sw) != 0 { return wj.wj_throw_dom(ctx, "InvalidStateError", "The input data length is not a multiple of (4 * width).") }
		rows := u32(n / 4 / uint(sw))
		if has_sh && sh != rows { return wj.wj_throw_dom(ctx, "IndexSizeError", "The input data byte length is not equal to (4 * width * height).") }
		return image_data_make(ctx, new_target, sw, rows, wj.JS_DupValue(ctx, argv[0]))
	}
	sw, sh: u32
	if !wj.wj_to_uint32(ctx, argv[0], &sw, 32, wj.ENFORCE_RANGE) || !wj.wj_to_uint32(ctx, argv[1], &sh, 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
	if argc > 2 && !image_data_settings(ctx, argv[2]) { return wj.EXCEPTION }
	if sw == 0 || sh == 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The source width or height is zero.") }
	if u64(sw) * u64(sh) * 4 > 0x7fffffff { return wj.JS_ThrowRangeError(ctx, "Out of memory: the image data is too large.") }
	arr := clamped_zeroes(ctx, u64(sw) * u64(sh) * 4)
	if wj.is_exception(arr) { return arr }
	return image_data_make(ctx, new_target, sw, sh, arr)
}

@(private = "file")
image_data_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Image_Data {
	return (^Image_Data)(wj.web_this_impl(ctx, this_val, jsb.iface_of(ImageData)))
}

@(export, link_name = "wjr_ImageData_get_width")
wjr_ImageData_get_width :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { d := image_data_this(ctx, t); return d != nil ? wj.new_uint32(ctx, d.w) : wj.EXCEPTION }
@(export, link_name = "wjr_ImageData_get_height")
wjr_ImageData_get_height :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { d := image_data_this(ctx, t); return d != nil ? wj.new_uint32(ctx, d.h) : wj.EXCEPTION }
@(export, link_name = "wjr_ImageData_get_data")
wjr_ImageData_get_data :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { d := image_data_this(ctx, t); return d != nil ? wj.JS_DupValue(ctx, d.data) : wj.EXCEPTION }
@(export, link_name = "wjr_ImageData_get_colorSpace")
wjr_ImageData_get_colorSpace :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return image_data_this(ctx, t) != nil ? wj.new_string(ctx, "srgb") : wj.EXCEPTION }
@(export, link_name = "wjr_ImageData_get_pixelFormat")
wjr_ImageData_get_pixelFormat :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return image_data_this(ctx, t) != nil ? wj.new_string(ctx, "rgba-unorm8") : wj.EXCEPTION }

@(export, link_name = "wjr_CanvasImageData_createImageData")
wjr_CanvasImageData_createImageData :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if _, ok := ctx_this(ctx, this_val); !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.createImageData", 1, argc) }
	w, h: u32
	if src := image_data_of(argv[0]); src != nil {
		w = src.w
		h = src.h
	} else {
		sw, sh: i32
		if argc < 2 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.createImageData", 2, argc) }
		if !wj.wj_to_int32(ctx, argv[0], &sw, 32, wj.ENFORCE_RANGE) || !wj.wj_to_int32(ctx, argv[1], &sh, 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
		if argc > 2 && !image_data_settings(ctx, argv[2]) { return wj.EXCEPTION }
		if sw == 0 || sh == 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The source width or height is zero.") }
		w = u32(abs(i64(sw)))
		h = u32(abs(i64(sh)))
	}
	if u64(w) * u64(h) * 4 > 0x7fffffff { return wj.JS_ThrowRangeError(ctx, "Out of memory: the image data is too large.") }
	arr := clamped_zeroes(ctx, u64(w) * u64(h) * 4)
	if wj.is_exception(arr) { return arr }
	return image_data_make(ctx, wj.UNDEFINED, w, h, arr)
}

@(export, link_name = "wjr_CanvasImageData_getImageData")
wjr_CanvasImageData_getImageData :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	if argc < 4 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.getImageData", 4, argc) }
	v: [4]i32
	for i in 0 ..< 4 {
		if !wj.wj_to_int32(ctx, argv[i], &v[i], 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
	}
	if argc > 4 && !image_data_settings(ctx, argv[4]) { return wj.EXCEPTION }
	sx, sy, sw, sh := i64(v[0]), i64(v[1]), i64(v[2]), i64(v[3])
	if sw == 0 || sh == 0 { return wj.wj_throw_dom(ctx, "IndexSizeError", "The source width or height is 0.") }
	if sw < 0 { sx += sw; sw = -sw }
	if sh < 0 { sy += sh; sh = -sh }
	if sw * sh * 4 > 0x7fffffff || u64(sw * sh * 4) > max_bytes() { return too_large(ctx) }
	n := uint(sw * sh * 4)
	p := ([^]u8)(wj.js_malloc(ctx, n > 0 ? n : 1))
	if p == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	if st := jsb.host_n(&none, api_decl.CanvasImageData_get, wj.wr_CanvasImageData_get, c, i32(sx), i32(sy), i32(sw), i32(sh), p[:n]); st != .None {
		wj.js_free(ctx, p)
		return wj.wj_throw_status(ctx, i32(st), "CanvasRenderingContext2D.getImageData")
	}
	arr := clamped_of(ctx, p, n)
	if wj.is_exception(arr) { return arr }
	return image_data_make(ctx, wj.UNDEFINED, u32(sw), u32(sh), arr)
}

@(export, link_name = "wjr_CanvasImageData_putImageData")
wjr_CanvasImageData_putImageData :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	if argc < 3 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.putImageData", 3, argc) }
	d := image_data_of(argv[0])
	if d == nil { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'putImageData' on 'CanvasRenderingContext2D': parameter 1 is not of type 'ImageData'.") }
	v := [6]i32{0, 0, 0, 0, i32(d.w), i32(d.h)}   // dx dy dirtyX dirtyY dirtyW dirtyH
	for i in 1 ..< 3 {
		if !wj.wj_to_int32(ctx, argv[i], &v[i - 1], 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
	}
	if argc >= 7 {
		for i in 3 ..< 7 {
			if !wj.wj_to_int32(ctx, argv[i], &v[i - 1], 32, wj.ENFORCE_RANGE) { return wj.EXCEPTION }
		}
	} else if argc > 3 {
		return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.putImageData", 7, argc)
	}
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, d.data, &p, &n, 0, "ImageData") { return wj.EXCEPTION }
	jsb.host_n(&none, api_decl.CanvasImageData_put, wj.wr_CanvasImageData_put, c, p[:n], i32(d.w), i32(d.h), v[0], v[1], v[2], v[3], v[4], v[5])
	return wj.UNDEFINED
}

// ---- drawImage ----

@(export, link_name = "wjr_CanvasDrawImage_drawImage")
wjr_CanvasDrawImage_drawImage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	c, ok := ctx_this(ctx, this_val)
	if !ok { return wj.EXCEPTION }
	if argc < 3 { return wj.wj_throw_arity(ctx, "CanvasRenderingContext2D.drawImage", 3, argc) }
	src := image_source(ctx, argv[0], "drawImage on 'CanvasRenderingContext2D'")
	if src == 0 { return wj.EXCEPTION }
	// drawImage(image, dx, dy) / (image, dx, dy, dw, dh) / (image, sx, sy, sw, sh, dx, dy, dw, dh): overloads of 3, 5 and 9
	form: i32
	switch {
	case argc == 3: form = 2
	case argc == 5: form = 4
	case argc >= 9: form = 8
	case: return wj.JS_ThrowTypeError(ctx, "Failed to execute 'drawImage' on 'CanvasRenderingContext2D': Valid arities are: [3, 5, 9], but %d arguments provided.", argc)
	}
	n: [8]f64
	if !nums(ctx, "CanvasRenderingContext2D.drawImage", argc, argv, 1, form, n[:]) { return wj.EXCEPTION }
	sx, sy, sw, sh, dx, dy, dw, dh: f64
	if form == 8 {
		sx, sy, sw, sh, dx, dy, dw, dh = n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7]
	} else {
		dx, dy = n[0], n[1]
		if form == 4 { dw, dh = n[2], n[3] }
	}
	if st := jsb.host_n(&none, api_decl.CanvasDrawImage_drawImage, wj.wr_CanvasDrawImage_drawImage, c, src, form, sx, sy, sw, sh, dx, dy, dw, dh); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "CanvasRenderingContext2D.drawImage")
	}
	return wj.UNDEFINED
}

// ---- createImageBitmap ----

// The ImageBitmapOptions of a createImageBitmap call, as the integers the native binding reads (api/canvas.widl).
@(private = "file")
Bitmap_Opts :: struct {
	orient:     i32,   // 0 from-image / none, 1 flipY
	premul:     i32,   // 0 default, 1 premultiply, 2 none
	colorspace: i32,   // 0 default, 1 none
	resize_w:   i32,   // 0: keep
	resize_h:   i32,
	resize_q:   i32,   // 0 pixelated, 1 low, 2 medium, 3 high
}

@(private = "file") BITMAP_DEFAULTS :: Bitmap_Opts{resize_q = 1}

// one enum string of `options` into out^ by a table of names and values; absent or undefined keeps out^
@(private = "file")
opt_enum :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue, key: cstring, names: []string, vals: []i32, out: ^i32) -> bool {
	v := wj.JS_GetPropertyStr(ctx, options, key)
	if wj.is_exception(v) { return false }
	defer wj.JS_FreeValue(ctx, v)
	if wj.is_undefined(v) { return true }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return false }
	for name, i in names {
		if string(wj.str_slice(s)) == name { out^ = vals[i]; break }
	}
	wj.wj_str_free(ctx, &s)
	return true
}

@(private = "file")
opt_long :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue, key: cstring, out: ^i32) -> bool {
	v := wj.JS_GetPropertyStr(ctx, options, key)
	if wj.is_exception(v) { return false }
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_undefined(v) {
		n: i32
		if wj.JS_ToInt32(ctx, &n, v) < 0 { return false }
		out^ = max(n, 0)
	}
	return true
}

@(private = "file") ORIENT_NAMES := [3]string{"from-image", "flipY", "none"}
@(private = "file") ORIENT_VALS  := [3]i32{0, 1, 0}
@(private = "file") PREMUL_NAMES := [3]string{"default", "premultiply", "none"}
@(private = "file") PREMUL_VALS  := [3]i32{0, 1, 2}
@(private = "file") CS_NAMES     := [2]string{"default", "none"}
@(private = "file") CS_VALS      := [2]i32{0, 1}
@(private = "file") Q_NAMES      := [4]string{"pixelated", "low", "medium", "high"}
@(private = "file") Q_VALS       := [4]i32{0, 1, 2, 3}

@(private = "file")
bitmap_options :: proc "contextless" (ctx: ^wj.Context, options: wj.JSValue, o: ^Bitmap_Opts) -> bool {
	o^ = BITMAP_DEFAULTS
	if !wj.is_object(options) { return true }
	return opt_enum(ctx, options, "imageOrientation", ORIENT_NAMES[:], ORIENT_VALS[:], &o.orient) &&
	       opt_enum(ctx, options, "premultiplyAlpha", PREMUL_NAMES[:], PREMUL_VALS[:], &o.premul) &&
	       opt_enum(ctx, options, "colorSpaceConversion", CS_NAMES[:], CS_VALS[:], &o.colorspace) &&
	       opt_long(ctx, options, "resizeWidth", &o.resize_w) &&
	       opt_long(ctx, options, "resizeHeight", &o.resize_h) &&
	       opt_enum(ctx, options, "resizeQuality", Q_NAMES[:], Q_VALS[:], &o.resize_q)
}

// the six options as a JS array, the promise's data payload (it outlives the call), and back
@(private = "file")
opts_to_array :: proc "contextless" (ctx: ^wj.Context, o: Bitmap_Opts) -> wj.JSValue {
	a := wj.JS_NewArray(ctx)
	if wj.is_exception(a) { return a }
	v := [6]i32{o.orient, o.premul, o.colorspace, o.resize_w, o.resize_h, o.resize_q}
	for x, i in v { wj.JS_SetPropertyUint32(ctx, a, u32(i), wj.new_int32(x)) }
	return a
}

@(private = "file")
opts_from_array :: proc "contextless" (ctx: ^wj.Context, a: wj.JSValue) -> (o: Bitmap_Opts) {
	o = BITMAP_DEFAULTS
	if !wj.JS_IsArray(a) { return }
	f := [6]^i32{&o.orient, &o.premul, &o.colorspace, &o.resize_w, &o.resize_h, &o.resize_q}
	for p, i in f {
		v := wj.JS_GetPropertyUint32(ctx, a, u32(i))
		n: i32
		wj.JS_ToInt32(ctx, &n, v)
		wj.JS_FreeValue(ctx, v)
		p^ = n
	}
	return
}

// "WxH" (the decoder's text) as two numbers; 0 when it does not read as one
@(private = "file")
parse_size :: proc "contextless" (s: []u8) -> (w, h: u32) {
	i := 0
	read :: proc "contextless" (s: []u8, i: ^int) -> (v: u32, ok: bool) {
		start := i^
		for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' { v = v * 10 + u32(s[i^] - '0'); i^ += 1 }
		return v, i^ > start
	}
	ok: bool
	if w, ok = read(s, &i); !ok { return 0, 0 }
	if i >= len(s) || s[i] != 'x' { return w, 0 }
	i += 1
	h, _ = read(s, &i)
	return
}

@(private = "file")
bitmap_from_pixels :: proc(p: []u8, w, h: i32, o: Bitmap_Opts, out: ^abi.Owned(api_decl.ImageBitmap)) -> abi.Api_Error {
	return jsb.host_n(out, api_decl.Canvas_bitmapFromPixels, wj.wr_Canvas_bitmapFromPixels, p, w, h, o.orient, o.premul, o.colorspace, o.resize_w, o.resize_h, o.resize_q)
}

// a decoded Blob (RGBA pixels, "WxH") becomes an ImageBitmap; `data` carries the ImageBitmapOptions as an array
@(private = "file")
bitmap_from_decoded :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = jsb.glue_context()
	if state != 1 {
		promise := host
		n := wj.fetch_string_user(proc "contextless" (user: rawptr, buf: [^]u8, cap: u32) -> i32 { return wj.wr_Promise_text((^u64)(user)^, buf, cap) }, &promise)
		reject^ = true
		return wj.web_error_value(ctx, i32(value), wj.scratch_data(), n > 0 ? uint(n) : 0)
	}
	o := opts_from_array(ctx, data)
	text := wj.wj_host_promise_text(ctx, host)
	t: wj.Str
	w, h: u32
	if wj.wj_to_str(ctx, text, &t, 0, nil) { w, h = parse_size(wj.str_slice(t)); wj.wj_str_free(ctx, &t) }
	wj.JS_FreeValue(ctx, text)
	ab := wj.wj_arraybuffer_from_host(ctx, u64(value))
	wj.wr_Object_release(u64(value))
	if wj.is_exception(ab) { reject^ = true; return wj.UNDEFINED }
	got: uint
	p := wj.JS_GetArrayBuffer(ctx, &got, ab)
	bm: abi.Owned(api_decl.ImageBitmap)
	st := abi.Api_Error.Invalid_Argument
	if p != nil && w != 0 && h != 0 && u64(got) >= u64(w) * u64(h) * 4 { st = bitmap_from_pixels(p[:got], i32(w), i32(h), o, &bm) }
	wj.JS_FreeValue(ctx, ab)
	if st != .None { wj.wj_throw_status(ctx, i32(st), "createImageBitmap"); reject^ = true; return wj.UNDEFINED }
	return wj.wj_wrap_owned(ctx, u64(bm.handle), jsb.iface_of(api_decl.ImageBitmap), wj.UNDEFINED)
}

@(export, link_name = "wjr_WindowOrWorkerGlobalScope_createImageBitmap")
wjr_WindowOrWorkerGlobalScope_createImageBitmap :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if argc < 1 {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'createImageBitmap' on 'Window': 1 argument required, but only 0 present.")
		return wj.web_promise_reject_pending(ctx)
	}
	image := argv[0]
	// (image, options) or (image, sx, sy, sw, sh, options)
	rect := argc >= 5 && !wj.is_object(argv[1])
	r: [4]f64
	if rect && !nums(ctx, "createImageBitmap", argc, argv, 1, 4, r[:]) { return wj.web_promise_reject_pending(ctx) }
	o: Bitmap_Opts
	if !bitmap_options(ctx, wj.arg(argc, argv, rect ? 5 : 1), &o) { return wj.web_promise_reject_pending(ctx) }

	// a Blob: decoded on the decoding threads
	bytes: [^]u8
	blen: uint
	if web_blob_bytes(image, &bytes, &blen) {
		if blen == 0 { return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, "InvalidStateError", "The source image could not be decoded.")) }
		buf := wj.wj_host_buffer(ctx, bytes, blen)
		if buf == 0 { return wj.web_promise_reject_pending(ctx) }
		pr: u64
		jsb.host(&pr, api_decl.Image_decode, wj.wr_Image_decode, buf)
		wj.wr_Object_release(buf)
		payload := opts_to_array(ctx, o)
		if wj.is_exception(payload) { return wj.web_promise_reject_pending(ctx) }
		p := wj.wj_promise_from_host(ctx, pr, wj.HOST_UNDEFINED, bitmap_from_decoded, payload)
		wj.JS_FreeValue(ctx, payload)
		return p
	}
	// ImageData: its pixels
	bm: abi.Owned(api_decl.ImageBitmap)
	st: abi.Api_Error
	if d := image_data_of(image); d != nil {
		p: [^]u8
		n: uint
		if !wj.wj_to_buffer_source(ctx, d.data, &p, &n, 0, "ImageData") { return wj.web_promise_reject_pending(ctx) }
		st = bitmap_from_pixels(p[:n], i32(d.w), i32(d.h), o, &bm)
	} else {
		src := image_source(ctx, image, "createImageBitmap on 'Window'")
		if src == 0 { return wj.web_promise_reject_pending(ctx) }
		st = jsb.host_n(&bm, api_decl.Canvas_createBitmap, wj.wr_Canvas_createBitmap, src, i32(rect ? 4 : 0), r[0], r[1], r[2], r[3],
			o.orient, o.premul, o.colorspace, o.resize_w, o.resize_h, o.resize_q)
	}
	if st != .None {
		name: cstring = st == .Index_Size ? "IndexSizeError" : (st == .Not_Found ? "InvalidStateError" : nil)
		if name != nil { return wj.web_promise_rejected(ctx, wj.web_dom_exception(ctx, name, "The source image cannot be used to make a bitmap.")) }
		wj.wj_throw_status(ctx, i32(st), "createImageBitmap")
		return wj.web_promise_reject_pending(ctx)
	}
	obj := wj.wj_wrap_owned(ctx, u64(bm.handle), jsb.iface_of(api_decl.ImageBitmap), wj.UNDEFINED)
	if wj.is_exception(obj) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, obj)
}
