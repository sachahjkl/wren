// dom_touch.odin: Touch Events for JavaScript: Touch, TouchList, and the lists of a TouchEvent. Ported from
// native/js/runtime/dom_touch.c with the same behaviour and symbols (wjr_* and the helpers dom_touch_list,
// touch_lists_from_host, dom_touch_list_from_sequence that dom_events.c calls). A touch event the browser dispatches
// gets its lists from the browser when first wrapped, as plain Touch objects in the event's extension object.
package odin_glue

import "../odin/wj"

Touch_Impl :: struct {
	identifier: i32,
	target:     wj.JSValue,
	client_x:   f64,
	client_y:   f64,
	screen_x:   f64,
	screen_y:   f64,
	page_x:     f64,
	page_y:     f64,
	radius_x:   f64,
	radius_y:   f64,
	angle:      f64,
	force:      f64,
	altitude:   f64,
	azimuth:    f64,
	stylus:     bool,
}

@(private = "file") iface_t := i32(-2)
@(private = "file") iface_tl := i32(-2)
@(private = "file") iface_touch :: proc "c" () -> i32 { if iface_t == -2 { iface_t = wj.iface("Touch") }; return iface_t }
@(private = "file") iface_touch_list :: proc "c" () -> i32 { if iface_tl == -2 { iface_tl = wj.iface("TouchList") }; return iface_tl }

@(private = "file")
touch_free :: proc "c" (p: rawptr) { t := (^Touch_Impl)(p); wj.JS_FreeValueRT(wj.the_runtime(wj.wj_the_realm.ctx), t.target); wj.libc_free(t) }
@(private = "file")
touch_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Touch_Impl)(p).target, mark_func) }

@(private = "file")
touch_new :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, t: ^Touch_Impl) -> wj.JSValue {
	obj := wj.wj_new_object_for(ctx, iface_touch(), new_target, nil, nil)
	if wj.is_exception(obj) { touch_free(t); return obj }
	wj.web_set_impl(obj, t, touch_free, touch_mark)
	return obj
}

Tlist_Impl :: struct { items: wj.JSValue }   // an array of Touch
@(private = "file")
tlist_free :: proc "c" (p: rawptr) { l := (^Tlist_Impl)(p); wj.JS_FreeValueRT(wj.the_runtime(wj.wj_the_realm.ctx), l.items); wj.libc_free(l) }
@(private = "file")
tlist_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Tlist_Impl)(p).items, mark_func) }

// A TouchList holding `items` (an array of Touch, taken).
@(export, link_name = "dom_touch_list")
dom_touch_list :: proc "c" (ctx: ^wj.Context, items: wj.JSValue) -> wj.JSValue {
	l := (^Tlist_Impl)(wj.libc_malloc(size_of(Tlist_Impl)))
	if l == nil { wj.JS_FreeValue(ctx, items); return wj.JS_ThrowOutOfMemory(ctx) }
	l.items = items
	obj := wj.wj_new_object(ctx, iface_touch_list(), nil, nil)
	if wj.is_exception(obj) { tlist_free(l); return obj }
	wj.web_set_impl(obj, l, tlist_free, tlist_mark)
	return obj
}

@(private = "file") list_names := [3]cstring{ "touches", "targetTouches", "changedTouches" }

// The browser's three lists of the touch event `host` into the extension object `x`.
@(export, link_name = "touch_lists_from_host")
touch_lists_from_host :: proc "c" (ctx: ^wj.Context, x: wj.JSValue, host: u64) {
	for k in i32(0)..<3 {
		arr := wj.JS_NewArray(ctx)
		n := wj.wr_TouchEvent_count(host, k)
		for i in i32(0)..<n {
			tp: wj.wr_TouchPoint
			if wj.wr_TouchEvent_touch(host, k, i, &tp) < 0 { break }
			t := (^Touch_Impl)(wj.libc_calloc(1, size_of(Touch_Impl)))
			if t == nil { break }
			t.identifier = tp.identifier
			t.target = tp.target != 0 ? wj.wj_wrap_node(ctx, tp.target) : wj.NULL
			t.client_x = tp.client_x; t.client_y = tp.client_y
			t.screen_x = tp.screen_x; t.screen_y = tp.screen_y
			t.page_x = tp.page_x; t.page_y = tp.page_y
			t.radius_x = tp.radius_x; t.radius_y = tp.radius_y
			t.angle = tp.rotation_angle; t.force = tp.force
			obj := touch_new(ctx, wj.UNDEFINED, t)
			if wj.is_exception(obj) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); break }
			wj.JS_SetPropertyUint32(ctx, arr, u32(i), obj)
		}
		wj.JS_SetPropertyStr(ctx, x, list_names[k], dom_touch_list(ctx, arr))
	}
}

// ---- Touch ----

@(private = "file")
dict_num :: proc "c" (ctx: ^wj.Context, init: wj.JSValue, name: cstring, out: ^f64) -> bool {
	v := wj.JS_GetPropertyStr(ctx, init, name)
	if wj.is_exception(v) { return false }
	ok := wj.is_undefined(v) || wj.wj_to_double(ctx, v, out, true)
	wj.JS_FreeValue(ctx, v)
	return ok
}

@(export, link_name = "wjr_Touch_constructor")
wjr_Touch_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor Touch requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Touch", 1, argc) }
	init := argv[0]
	if !wj.is_object(init) { return wj.wj_throw_type(ctx, "Failed to construct 'Touch': parameter 1 is not of type 'TouchInit'.") }
	t := (^Touch_Impl)(wj.libc_calloc(1, size_of(Touch_Impl)))
	if t == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	t.target = wj.UNDEFINED
	id := wj.JS_GetPropertyStr(ctx, init, "identifier")
	target := wj.JS_GetPropertyStr(ctx, init, "target")
	if wj.is_undefined(id) || wj.is_undefined(target) {
		wj.JS_FreeValue(ctx, id); wj.JS_FreeValue(ctx, target); touch_free(t)
		return wj.wj_throw_type(ctx, "Failed to construct 'Touch': required member identifier / target is undefined.")
	}
	ok := wj.wj_to_int32(ctx, id, &t.identifier, 32, 0)
	wj.JS_FreeValue(ctx, id)
	if !ok || wj.wj_unwrap(target, iface_event_target()) == nil {
		wj.JS_FreeValue(ctx, target); touch_free(t)
		return ok ? wj.wj_throw_type(ctx, "Failed to construct 'Touch': member target is not of type 'EventTarget'.") : wj.EXCEPTION
	}
	t.target = target
	Num :: struct { name: cstring, out: ^f64 }
	nums := [12]Num{
		{"clientX", &t.client_x}, {"clientY", &t.client_y}, {"screenX", &t.screen_x}, {"screenY", &t.screen_y},
		{"pageX", &t.page_x}, {"pageY", &t.page_y}, {"radiusX", &t.radius_x}, {"radiusY", &t.radius_y},
		{"rotationAngle", &t.angle}, {"force", &t.force}, {"altitudeAngle", &t.altitude}, {"azimuthAngle", &t.azimuth},
	}
	for i in 0..<12 { if !dict_num(ctx, init, nums[i].name, nums[i].out) { touch_free(t); return wj.EXCEPTION } }
	tt := wj.JS_GetPropertyStr(ctx, init, "touchType")
	if !wj.is_undefined(tt) {
		s := wj.JS_ToCString(ctx, tt)
		known := s != nil && (wj.str_eq(s, "direct") || wj.str_eq(s, "stylus"))
		t.stylus = s != nil && wj.str_eq(s, "stylus")
		if s != nil { wj.JS_FreeCString(ctx, s) }
		if !known { wj.JS_FreeValue(ctx, tt); touch_free(t); return wj.wj_throw_type(ctx, "Failed to construct 'Touch': The provided value is not a valid enum value of type TouchType.") }
	}
	wj.JS_FreeValue(ctx, tt)
	return touch_new(ctx, new_target, t)
}

@(private = "file")
touch_this :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> ^Touch_Impl { return (^Touch_Impl)(wj.web_this_impl(ctx, v, iface_touch())) }

// each getter reads its own field of the Touch impl (written out one per line, as the C: bindgen finds hand-written
// members by their definition line).
@(export, link_name = "wjr_Touch_get_screenX")
wjr_Touch_get_screenX :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.screen_x) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_screenY")
wjr_Touch_get_screenY :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.screen_y) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_clientX")
wjr_Touch_get_clientX :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.client_x) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_clientY")
wjr_Touch_get_clientY :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.client_y) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_pageX")
wjr_Touch_get_pageX :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.page_x) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_pageY")
wjr_Touch_get_pageY :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.page_y) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_radiusX")
wjr_Touch_get_radiusX :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.radius_x) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_radiusY")
wjr_Touch_get_radiusY :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.radius_y) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_rotationAngle")
wjr_Touch_get_rotationAngle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.angle) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_force")
wjr_Touch_get_force :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.force) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_altitudeAngle")
wjr_Touch_get_altitudeAngle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.altitude) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_azimuthAngle")
wjr_Touch_get_azimuthAngle :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_float64(ctx, x.azimuth) : wj.EXCEPTION }

@(export, link_name = "wjr_Touch_get_identifier")
wjr_Touch_get_identifier :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.new_int32(x.identifier) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_target")
wjr_Touch_get_target :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.JS_DupValue(ctx, x.target) : wj.EXCEPTION }
@(export, link_name = "wjr_Touch_get_touchType")
wjr_Touch_get_touchType :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { x := touch_this(ctx, t); return x != nil ? wj.JS_NewString(ctx, x.stylus ? "stylus" : "direct") : wj.EXCEPTION }

// ---- TouchList ----

@(private = "file")
tlist_of :: proc "c" (v: wj.JSValue) -> ^Tlist_Impl {
	o := wj.wj_unwrap(v, iface_touch_list())
	return o != nil ? (^Tlist_Impl)(o.impl) : nil
}

@(private = "file")
tlist_len :: proc "c" (ctx: ^wj.Context, l: ^Tlist_Impl) -> u32 {
	n := i64(0)
	if l != nil { wj.JS_GetLength(ctx, l.items, &n) }
	return n > 0 ? u32(n) : 0
}

@(export, link_name = "wjr_TouchList_get_length")
wjr_TouchList_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_touch_list()) == nil { return wj.EXCEPTION }
	return wj.new_uint32(ctx, tlist_len(ctx, tlist_of(this_val)))
}

@(export, link_name = "wjr_TouchList_item")
wjr_TouchList_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_touch_list()) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "TouchList.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	l := tlist_of(this_val)
	if l == nil || i >= tlist_len(ctx, l) { return wj.NULL }
	return wj.JS_GetPropertyUint32(ctx, l.items, i)
}

@(export, link_name = "wjr_TouchList_length_hook")
wjr_TouchList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { return tlist_len(ctx, tlist_of(obj)) }

@(export, link_name = "wjr_TouchList_index_get")
wjr_TouchList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	l := tlist_of(obj)
	if l == nil || index >= tlist_len(ctx, l) { found^ = false; return wj.UNDEFINED }
	found^ = true
	return wj.JS_GetPropertyUint32(ctx, l.items, index)
}

// A TouchList from a sequence<Touch> of TouchEventInit (TypeError for anything else).
@(export, link_name = "dom_touch_list_from_sequence")
dom_touch_list_from_sequence :: proc "c" (ctx: ^wj.Context, seq: wj.JSValue, member: cstring) -> wj.JSValue {
	arr := wj.JS_NewArray(ctx)
	if !wj.is_undefined(seq) {
		if !wj.is_object(seq) { wj.JS_FreeValue(ctx, arr); return wj.wj_throw_type(ctx, "Failed to construct 'TouchEvent': member %s is not iterable.", member) }
		n := i64(0)
		if wj.JS_GetLength(ctx, seq, &n) < 0 { wj.JS_FreeValue(ctx, arr); return wj.EXCEPTION }
		for i in 0..<n {
			t := wj.JS_GetPropertyInt64(ctx, seq, i)
			if wj.wj_unwrap(t, iface_touch()) == nil { wj.JS_FreeValue(ctx, t); wj.JS_FreeValue(ctx, arr); return wj.wj_throw_type(ctx, "Failed to construct 'TouchEvent': member %s contains a value that is not a Touch.", member) }
			wj.JS_SetPropertyUint32(ctx, arr, u32(i), t)
		}
	}
	return dom_touch_list(ctx, arr)
}
