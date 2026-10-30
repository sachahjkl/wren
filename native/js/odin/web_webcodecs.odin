// web_webcodecs.odin: the WebCodecs JavaScript surface of VideoFrame and VideoColorSpace. Ported from
// native/js/runtime/web_webcodecs.c, same symbols and messages.
//
// The pixel model, the format conversions and the memory accounting are native (src/page/webcodecs_frame.odin,
// bindings_webcodecs.odin). The calls into the host are declared (native/js/odin_abi/api_decl/webcodecs.odin) and go
// through jsb: a getter that only carries a value across is one line naming its declaration and import. What is
// written here is behaviour: the dictionaries (VideoFrameInit, VideoFrameBufferInit, VideoFrameCopyToOptions with its
// PlaneLayout[], VideoColorSpaceInit), the enum strings, null for an absent duration or rectangle, copyTo's promise
// (already resolved: the copy is synchronous on the host). A VideoFrame is a host object wrapped with wj_wrap_owned,
// so close() / transfer stay the host's business.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") VideoFrame :: api_decl.VideoFrame
@(private = "file") VideoColorSpace :: distinct u64   // an engine object (its members kept as extras)

// VideoPixelFormat <-> the host enum (Frame_Format order; 0 = none, not a JS value)
@(private = "file")
PX_NAMES := [10]string{"", "I420", "I420A", "I422", "I444", "NV12", "RGBA", "RGBX", "BGRA", "BGRX"}

// colour space enums (the host's Frame_Color_* order)
@(private = "file") PRIM_NAMES   := [6]string{"", "bt709", "bt470bg", "smpte170m", "bt2020", "smpte432"}
@(private = "file") TRANS_NAMES  := [7]string{"", "bt709", "smpte170m", "iec61966-2-1", "linear", "pq", "hlg"}
@(private = "file") MATRIX_NAMES := [6]string{"", "rgb", "bt709", "bt470bg", "smpte170m", "bt2020-ncl"}

@(private = "file")
name_or_null :: proc "contextless" (ctx: ^wj.Context, names: []string, i: i32) -> wj.JSValue {
	return i > 0 && int(i) < len(names) ? wj.new_string_len(ctx, names[i]) : wj.NULL
}

// ---- reading VideoFrameInit / VideoFrameCopyToOptions members ----

// an integer member of an options object, leaving out^ when absent / undefined / null
@(private = "file")
opt_i64 :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, key: cstring, out: ^i64, present: ^bool = nil) -> bool {
	if !wj.is_object(opt) { return true }
	v := wj.JS_GetPropertyStr(ctx, opt, key)
	if wj.is_exception(v) { return false }
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_nullish(v) {
		if wj.JS_ToInt64(ctx, out, v) < 0 { return false }
		if present != nil { present^ = true }
	}
	return true
}

// a DOMRectInit {x, y, width, height} of opt[key]; present when the member is an object
@(private = "file")
opt_rect :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, key: cstring, r: ^[4]f64, present: ^bool) -> bool {
	if !wj.is_object(opt) { return true }
	v := wj.JS_GetPropertyStr(ctx, opt, key)
	if wj.is_exception(v) { return false }
	if wj.is_object(v) {
		keys := [4]cstring{"x", "y", "width", "height"}
		for i in 0 ..< 4 {
			e := wj.JS_GetPropertyStr(ctx, v, keys[i])
			r[i] = 0
			if !wj.is_undefined(e) { wj.JS_ToFloat64(ctx, &r[i], e) }
			wj.JS_FreeValue(ctx, e)
		}
		present^ = true
	}
	wj.JS_FreeValue(ctx, v)
	return true
}

// the format member (a VideoPixelFormat) of an options object: -1 when absent or unknown, -2 with an exception
@(private = "file")
opt_format :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue) -> i32 {
	if !wj.is_object(opt) { return -1 }
	v := wj.JS_GetPropertyStr(ctx, opt, "format")
	if wj.is_exception(v) { return -2 }
	f := value_enum(ctx, v, PX_NAMES[:])
	wj.JS_FreeValue(ctx, v)
	return f
}

// options.layout (a PlaneLayout[]) into offsets / strides (at most 4 planes): the count, -1 when absent, -2 on error
@(private = "file")
opt_layout :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, offsets, strides: ^[4]i32) -> int {
	if !wj.is_object(opt) { return -1 }
	v := wj.JS_GetPropertyStr(ctx, opt, "layout")
	if wj.is_exception(v) { return -2 }
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_object(v) { return -1 }
	lenv := wj.JS_GetPropertyStr(ctx, v, "length")
	n: u32
	wj.JS_ToUint32(ctx, &n, lenv)
	wj.JS_FreeValue(ctx, lenv)
	n = min(n, 4)
	for i in 0 ..< n {
		pl := wj.JS_GetPropertyUint32(ctx, v, i)
		off := wj.JS_GetPropertyStr(ctx, pl, "offset")
		str := wj.JS_GetPropertyStr(ctx, pl, "stride")
		o, s: i32
		wj.JS_ToInt32(ctx, &o, off)
		wj.JS_ToInt32(ctx, &s, str)
		offsets[i] = o
		strides[i] = s
		wj.JS_FreeValue(ctx, off); wj.JS_FreeValue(ctx, str); wj.JS_FreeValue(ctx, pl)
	}
	return int(n)
}

// A VideoFrameCopyToOptions (or allocationSize's): format, rect, layout.
@(private = "file")
Copy_Options :: struct {
	format:   i32,
	rect:     [4]f64,
	has_rect: bool,
	offsets:  [4]i32,
	strides:  [4]i32,
	planes:   int,   // -1: no layout
}

@(private = "file")
copy_options :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, o: ^Copy_Options) -> bool {
	o.format = opt_format(ctx, opt)
	if o.format == -2 { return false }
	if !opt_rect(ctx, opt, "rect", &o.rect, &o.has_rect) { return false }
	o.planes = opt_layout(ctx, opt, &o.offsets, &o.strides)
	return o.planes != -2
}

@(private = "file") layout_n :: #force_inline proc "contextless" (o: ^Copy_Options) -> int { return max(o.planes, 0) }

// ---- VideoColorSpace ----

// the four members of a VideoColorSpaceInit (-1: null)
@(private = "file")
color_space_init :: proc "contextless" (ctx: ^wj.Context, init: wj.JSValue) -> (cs: [4]i32) {
	cs = {-1, -1, -1, -1}
	if !wj.is_object(init) { return }
	cs[0] = member_enum(ctx, init, "primaries", PRIM_NAMES[:])
	cs[1] = member_enum(ctx, init, "transfer", TRANS_NAMES[:])
	cs[2] = member_enum(ctx, init, "matrix", MATRIX_NAMES[:])
	v := wj.JS_GetPropertyStr(ctx, init, "fullRange")
	if !wj.is_nullish(v) { cs[3] = wj.JS_ToBool(ctx, v) != 0 ? 1 : 0 }
	wj.JS_FreeValue(ctx, v)
	return
}

@(private = "file")
color_space_fill :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, cs: [4]i32) {
	wj.web_extra_set(ctx, obj, "p", name_or_null(ctx, PRIM_NAMES[:], cs[0]))
	wj.web_extra_set(ctx, obj, "t", name_or_null(ctx, TRANS_NAMES[:], cs[1]))
	wj.web_extra_set(ctx, obj, "m", name_or_null(ctx, MATRIX_NAMES[:], cs[2]))
	wj.web_extra_set(ctx, obj, "f", cs[3] >= 0 ? wj.new_bool(cs[3] != 0) : wj.NULL)
}

@(private = "file")
cs_member :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, key: cstring) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(VideoColorSpace)) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, key)
	return wj.is_undefined(v) ? wj.NULL : v
}

@(export, link_name = "wjr_VideoColorSpace_get_primaries") wjr_VideoColorSpace_get_primaries :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return cs_member(ctx, t, "p") }
@(export, link_name = "wjr_VideoColorSpace_get_transfer")  wjr_VideoColorSpace_get_transfer  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return cs_member(ctx, t, "t") }
@(export, link_name = "wjr_VideoColorSpace_get_matrix")    wjr_VideoColorSpace_get_matrix    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return cs_member(ctx, t, "m") }
@(export, link_name = "wjr_VideoColorSpace_get_fullRange") wjr_VideoColorSpace_get_fullRange :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return cs_member(ctx, t, "f") }

@(export, link_name = "wjr_VideoColorSpace_toJSON")
wjr_VideoColorSpace_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(VideoColorSpace)) == nil { return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	keys := [4]cstring{"p", "t", "m", "f"}
	names := [4]cstring{"primaries", "transfer", "matrix", "fullRange"}
	for i in 0 ..< 4 {
		// web_extra_get's value is returned counted (the C dup'ed it once more and leaked it)
		wj.JS_DefinePropertyValueStr(ctx, o, names[i], wj.web_extra_get(ctx, this_val, keys[i]), wj.PROP_C_W_E)
	}
	return o
}

@(export, link_name = "wjr_VideoColorSpace_constructor")
wjr_VideoColorSpace_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'VideoColorSpace': Please use the 'new' operator.") }
	cs := color_space_init(ctx, wj.arg(argc, argv, 0))
	obj := wj.wj_wrap_owned(ctx, 0, jsb.iface_of(VideoColorSpace), new_target)
	if wj.is_object(obj) { color_space_fill(ctx, obj, cs) }
	return obj
}

// ---- VideoFrame getters: one line each when the value only crosses ----

@(private = "file")
attr :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, $D: typeid, imp: $R) -> wj.JSValue {
	return jsb.method(ctx, t, 0, nil, D, imp, "VideoFrame")
}

@(export, link_name = "wjr_VideoFrame_get_codedWidth")    wjr_VideoFrame_get_codedWidth    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return attr(ctx, t, api_decl.VideoFrame_codedWidth, wj.wr_VideoFrame_codedWidth) }
@(export, link_name = "wjr_VideoFrame_get_codedHeight")   wjr_VideoFrame_get_codedHeight   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return attr(ctx, t, api_decl.VideoFrame_codedHeight, wj.wr_VideoFrame_codedHeight) }
@(export, link_name = "wjr_VideoFrame_get_displayWidth")  wjr_VideoFrame_get_displayWidth  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return attr(ctx, t, api_decl.VideoFrame_displayWidth, wj.wr_VideoFrame_displayWidth) }
@(export, link_name = "wjr_VideoFrame_get_displayHeight") wjr_VideoFrame_get_displayHeight :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return attr(ctx, t, api_decl.VideoFrame_displayHeight, wj.wr_VideoFrame_displayHeight) }
@(export, link_name = "wjr_VideoFrame_get_timestamp")     wjr_VideoFrame_get_timestamp     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return attr(ctx, t, api_decl.VideoFrame_timestamp, wj.wr_VideoFrame_timestamp) }

@(export, link_name = "wjr_VideoFrame_get_format")
wjr_VideoFrame_get_format :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, t, VideoFrame) or_else 0
	if f == 0 { return wj.EXCEPTION }
	v: i32
	jsb.host(&v, api_decl.VideoFrame_format, wj.wr_VideoFrame_format, f)
	return name_or_null(ctx, PX_NAMES[:], v)
}

@(export, link_name = "wjr_VideoFrame_get_duration")
wjr_VideoFrame_get_duration :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, t, VideoFrame) or_else 0
	if f == 0 { return wj.EXCEPTION }
	d: i64
	jsb.host(&d, api_decl.VideoFrame_duration, wj.wr_VideoFrame_duration, f)
	return d < 0 ? wj.NULL : wj.new_int64(ctx, d)
}

@(export, link_name = "wjr_VideoFrame_get_codedRect")
wjr_VideoFrame_get_codedRect :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, t, VideoFrame) or_else 0
	if f == 0 { return wj.EXCEPTION }
	closed: bool
	jsb.host(&closed, api_decl.VideoFrame_isClosed, wj.wr_VideoFrame_isClosed, f)
	if closed { return wj.NULL }
	w, h: u32
	jsb.host(&w, api_decl.VideoFrame_codedWidth, wj.wr_VideoFrame_codedWidth, f)
	jsb.host(&h, api_decl.VideoFrame_codedHeight, wj.wr_VideoFrame_codedHeight, f)
	return dom_rect_new(ctx, 0, 0, f64(w), f64(h), true)
}

@(export, link_name = "wjr_VideoFrame_get_visibleRect")
wjr_VideoFrame_get_visibleRect :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, t, VideoFrame) or_else 0
	if f == 0 { return wj.EXCEPTION }
	r: [4]f64
	for i in 0 ..< 4 { jsb.host(&r[i], api_decl.VideoFrame_visibleRect, wj.wr_VideoFrame_visibleRect, f, i32(i)) }
	if r[0] < 0 && r[2] < 0 { return wj.NULL }
	return dom_rect_new(ctx, r[0], r[1], r[2], r[3], true)
}

@(export, link_name = "wjr_VideoFrame_get_colorSpace")
wjr_VideoFrame_get_colorSpace :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, t, VideoFrame) or_else 0
	if f == 0 { return wj.EXCEPTION }
	cs: [4]i32
	for i in 0 ..< 4 { jsb.host(&cs[i], api_decl.VideoFrame_colorSpace, wj.wr_VideoFrame_colorSpace, f, i32(i)) }
	obj := wj.wj_new_object(ctx, jsb.iface_of(VideoColorSpace), nil, nil)
	if wj.is_object(obj) { color_space_fill(ctx, obj, cs) }
	return obj
}

// ---- allocationSize / copyTo ----

@(export, link_name = "wjr_VideoFrame_allocationSize")
wjr_VideoFrame_allocationSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, this_val, VideoFrame) or_else 0
	if f == 0 { return wj.EXCEPTION }
	o: Copy_Options
	if !copy_options(ctx, wj.arg(argc, argv, 0), &o) { return wj.EXCEPTION }
	n := layout_n(&o)
	size: i32
	st := jsb.host_n(&size, api_decl.VideoFrame_allocationSize, wj.wr_VideoFrame_allocationSize, f, o.format,
		i32(o.rect[0]), i32(o.rect[1]), i32(o.rect[2]), i32(o.rect[3]), o.has_rect, o.offsets[:n], o.strides[:n], o.planes > 0)
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "VideoFrame.allocationSize") }
	return wj.new_uint32(ctx, u32(size))
}

@(export, link_name = "wjr_VideoFrame_copyTo")
wjr_VideoFrame_copyTo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	f := jsb.this(ctx, this_val, VideoFrame) or_else 0
	if f == 0 { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'copyTo' on 'VideoFrame': 1 argument required, but only 0 present.")
		return wj.web_promise_reject_pending(ctx)
	}
	dst: [^]u8
	dlen: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &dst, &dlen, wj.BS_ALLOW_SHARED, "copyTo on 'VideoFrame'") { return wj.web_promise_reject_pending(ctx) }
	o: Copy_Options
	if !copy_options(ctx, wj.arg(argc, argv, 1), &o) { return wj.web_promise_reject_pending(ctx) }
	n := layout_n(&o)
	planes: i32
	st := jsb.host_n(&planes, api_decl.VideoFrame_copyTo, wj.wr_VideoFrame_copyTo, f, dst[:dlen], o.format,
		i32(o.rect[0]), i32(o.rect[1]), i32(o.rect[2]), i32(o.rect[3]), o.has_rect, o.offsets[:n], o.strides[:n], o.planes > 0)
	if st != .None { return wj.web_promise_rejected(ctx, wj.web_error_value(ctx, i32(st), nil, 0)) }
	wj.JS_ArrayBufferCommit(ctx, dst, dlen)
	// resolve with the PlaneLayout[] the host kept
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< min(planes, 4) {
		off, stride: i32
		jsb.host(&off, api_decl.VideoFrame_copyLayout, wj.wr_VideoFrame_copyLayout, f, i, i32(0))
		jsb.host(&stride, api_decl.VideoFrame_copyLayout, wj.wr_VideoFrame_copyLayout, f, i, i32(1))
		pl := wj.JS_NewObject(ctx)
		wj.JS_DefinePropertyValueStr(ctx, pl, "offset", wj.new_uint32(ctx, u32(off)), wj.PROP_C_W_E)
		wj.JS_DefinePropertyValueStr(ctx, pl, "stride", wj.new_uint32(ctx, u32(stride)), wj.PROP_C_W_E)
		wj.JS_SetPropertyUint32(ctx, arr, u32(i), pl)
	}
	return wj.web_promise_resolved(ctx, arr)
}

// ---- clone / close ----

@(export, link_name = "wjr_VideoFrame_clone")
wjr_VideoFrame_clone :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, this_val, argc, argv, api_decl.VideoFrame_clone, wj.wr_VideoFrame_clone, "VideoFrame.clone")
}

@(export, link_name = "wjr_VideoFrame_close")
wjr_VideoFrame_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return jsb.method(ctx, this_val, argc, argv, api_decl.VideoFrame_close, wj.wr_VideoFrame_close, "VideoFrame.close")
}

// ---- constructor ----

// new VideoFrame(image, init) | new VideoFrame(bufferSource, bufferInit). The first argument decides: a BufferSource
// (ArrayBuffer / view) takes the buffer path, anything else is a CanvasImageSource.
@(export, link_name = "wjr_VideoFrame_constructor")
wjr_VideoFrame_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': Please use the 'new' operator.") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "VideoFrame", 1, argc) }
	if wj.wj_is_buffer_source(argv[0]) { return frame_from_buffer(ctx, new_target, argc, argv) }

	// the image overload: the source handle (an element or an object, VideoFrame included)
	src := image_source_handle(argv[0])
	if src == 0 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': the first argument is not a CanvasImageSource or a BufferSource.") }
	init := wj.arg(argc, argv, 1)
	ts, dur: i64
	has_ts, has_dur: bool
	if !opt_i64(ctx, init, "timestamp", &ts, &has_ts) || !opt_i64(ctx, init, "duration", &dur, &has_dur) { return wj.EXCEPTION }
	out: abi.Owned(VideoFrame)
	if st := jsb.host_n(&out, api_decl.VideoFrame_fromImage, wj.wr_VideoFrame_fromImage, src, ts, has_ts, dur, has_dur); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "VideoFrame")
	}
	return wj.wj_wrap_owned(ctx, u64(out.handle), jsb.iface_of(VideoFrame), new_target)
}

// The buffer overload. VideoFrame_fromBuffer has more wire parameters than a declaration carries today (api_decl's
// note), so this one call names the generated import directly.
@(private = "file")
frame_from_buffer :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 2 || !wj.is_object(argv[1]) { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': 2 arguments required for a buffer source.") }
	init := argv[1]
	// required: format, codedWidth, codedHeight, timestamp
	fmt := member_enum(ctx, init, "format", PX_NAMES[:])
	if fmt < 0 { return wj.JS_ThrowTypeError(ctx, "Failed to construct 'VideoFrame': invalid or missing 'format'.") }
	cw, ch, ts, dur, dw, dh: i64
	has_dur, has_dw, has_dh, has_vis: bool
	if !opt_i64(ctx, init, "codedWidth", &cw) || !opt_i64(ctx, init, "codedHeight", &ch) ||
	   !opt_i64(ctx, init, "timestamp", &ts) || !opt_i64(ctx, init, "duration", &dur, &has_dur) { return wj.EXCEPTION }
	vr: [4]f64
	if !opt_rect(ctx, init, "visibleRect", &vr, &has_vis) { return wj.EXCEPTION }
	if !opt_i64(ctx, init, "displayWidth", &dw, &has_dw) || !opt_i64(ctx, init, "displayHeight", &dh, &has_dh) { return wj.EXCEPTION }
	loff, lstr: [4]i32
	ln := opt_layout(ctx, init, &loff, &lstr)
	if ln == -2 { return wj.EXCEPTION }
	csv := wj.JS_GetPropertyStr(ctx, init, "colorSpace")
	cs_has := wj.is_object(csv)
	cs := color_space_init(ctx, csv)
	wj.JS_FreeValue(ctx, csv)

	data: [^]u8
	dlen: uint
	if !wj.wj_to_buffer_source(ctx, argv[0], &data, &dlen, wj.BS_ALLOW_SHARED, "VideoFrame constructor") { return wj.EXCEPTION }
	b :: #force_inline proc "contextless" (x: bool) -> i32 { return x ? 1 : 0 }
	n := u32(max(ln, 0))
	out: u64
	st := wj.wr_VideoFrame_fromBuffer(data, u32(dlen), fmt, i32(cw), i32(ch), ts, dur, b(has_dur),
		i32(vr[0]), i32(vr[1]), i32(vr[2]), i32(vr[3]), b(has_vis),
		i32(dw), i32(dh), b(has_dw && has_dh),
		&loff[0], n, &lstr[0], n, b(ln > 0),
		cs[0], cs[1], cs[2], cs[3], b(cs_has), &out)
	if st < 0 { return wj.wj_throw_status(ctx, st, "VideoFrame") }
	return wj.wj_wrap_owned(ctx, out, jsb.iface_of(VideoFrame), new_target)
}
