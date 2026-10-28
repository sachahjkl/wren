// dom_layout.odin: geometry for JavaScript (CSSOM View, Geometry Interfaces): DOMRect / DOMRectReadOnly / DOMRectList
// as engine objects, getBoundingClientRect / getClientRects, and the scrolling methods whose arguments are overloads
// or dictionaries. Ported from native/js/runtime/dom_layout.c with the same behaviour and symbols (dom_rect_new and
// dom_rect_list are exported for the other DOM glue). The geometry is the browser's (src/page/js_dom_layout.odin).
package odin_glue

import "../odin/wj"

@(private = "file") NAN :: f64(0h7FF8_0000_0000_0000)
@(private = "file") fmin :: proc "c" (a, b: f64) -> f64 { return a < b ? a : b }
@(private = "file") fmax :: proc "c" (a, b: f64) -> f64 { return a > b ? a : b }

@(private = "file") iface_dro := i32(-2)
@(private = "file") iface_dr := i32(-2)
@(private = "file") iface_drl := i32(-2)
@(private = "file") iface_window := i32(-2)
@(private = "file") iface_rect_ro :: proc "c" () -> i32 { if iface_dro == -2 { iface_dro = wj.iface("DOMRectReadOnly") }; return iface_dro }
@(private = "file") iface_rect :: proc "c" () -> i32 { if iface_dr == -2 { iface_dr = wj.iface("DOMRect") }; return iface_dr }
@(private = "file") iface_rect_list :: proc "c" () -> i32 { if iface_drl == -2 { iface_drl = wj.iface("DOMRectList") }; return iface_drl }
@(private = "file") iface_win :: proc "c" () -> i32 { if iface_window == -2 { iface_window = wj.iface("Window") }; return iface_window }

// ---- DOMRect ----

@(export, link_name = "dom_rect_new")
dom_rect_new :: proc "c" (ctx: ^wj.Context, x: f64, y: f64, w: f64, h: f64, read_only: bool) -> wj.JSValue {
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, read_only ? iface_rect_ro() : iface_rect(), wj.DOM_RECT, wj.UNDEFINED, 0, &d)
	if wj.is_exception(obj) { return obj }
	d.rect[0] = x; d.rect[1] = y; d.rect[2] = w; d.rect[3] = h
	return obj
}

@(private = "file")
rect_args :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, out: ^[4]f64) -> bool {
	for i in 0..<4 {
		out[i] = 0
		if i32(i) < argc && !wj.is_undefined(argv[i]) && !wj.wj_to_double(ctx, argv[i], &out[i], false) { return false }
	}
	return true
}

@(private = "file")
rect_construct :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor %s requires 'new'", name) }
	v: [4]f64
	if !rect_args(ctx, argc, argv, &v) { return wj.EXCEPTION }
	obj := dom_rect_new(ctx, v[0], v[1], v[2], v[3], iface == iface_rect_ro())
	if wj.is_exception(obj) { return obj }
	proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
	if wj.is_object(proto) { wj.JS_SetPrototype(ctx, obj, proto) }
	wj.JS_FreeValue(ctx, proto)
	return obj
}

@(export, link_name = "wjr_DOMRectReadOnly_constructor")
wjr_DOMRectReadOnly_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return rect_construct(ctx, new_target, argc, argv, iface_rect_ro(), "DOMRectReadOnly") }
@(export, link_name = "wjr_DOMRect_constructor")
wjr_DOMRect_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return rect_construct(ctx, new_target, argc, argv, iface_rect(), "DOMRect") }

@(private = "file")
rect_from :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, read_only: bool) -> wj.JSValue {
	v := [4]f64{0, 0, 0, 0}
	init := wj.arg(argc, argv, 0)
	names := [4]cstring{"x", "y", "width", "height"}
	for i in 0..<4 {
		f := wj.dom_dict_get(ctx, init, names[i])
		if wj.is_exception(f) { return f }
		if !wj.is_undefined(f) && !wj.wj_to_double(ctx, f, &v[i], false) { wj.JS_FreeValue(ctx, f); return wj.EXCEPTION }
		wj.JS_FreeValue(ctx, f)
	}
	return dom_rect_new(ctx, v[0], v[1], v[2], v[3], read_only)
}

@(export, link_name = "wjr_DOMRectReadOnly_static_fromRect")
wjr_DOMRectReadOnly_static_fromRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return rect_from(ctx, argc, argv, true) }
@(export, link_name = "wjr_DOMRect_static_fromRect")
wjr_DOMRect_static_fromRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return rect_from(ctx, argc, argv, false) }

@(private = "file")
rect_of :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^wj.Dom_Impl { return wj.dom_impl_of(ctx, this_val, iface_rect_ro()) }

// field i of a rect: 0..3 x y width height, 4..7 top right bottom left
@(private = "file")
rect_field :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, i: i32) -> wj.JSValue {
	d := rect_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	r := &d.rect
	switch i {
	case 4: return wj.new_float64(ctx, fmin(r[1], r[1] + r[3]))
	case 5: return wj.new_float64(ctx, fmax(r[0], r[0] + r[2]))
	case 6: return wj.new_float64(ctx, fmax(r[1], r[1] + r[3]))
	case 7: return wj.new_float64(ctx, fmin(r[0], r[0] + r[2]))
	}
	return wj.new_float64(ctx, r[i])
}

@(export, link_name = "wjr_DOMRectReadOnly_get_x")
wjr_DOMRectReadOnly_get_x :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 0) }
@(export, link_name = "wjr_DOMRectReadOnly_get_y")
wjr_DOMRectReadOnly_get_y :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 1) }
@(export, link_name = "wjr_DOMRectReadOnly_get_width")
wjr_DOMRectReadOnly_get_width :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 2) }
@(export, link_name = "wjr_DOMRectReadOnly_get_height")
wjr_DOMRectReadOnly_get_height :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 3) }
@(export, link_name = "wjr_DOMRectReadOnly_get_top")
wjr_DOMRectReadOnly_get_top :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 4) }
@(export, link_name = "wjr_DOMRectReadOnly_get_right")
wjr_DOMRectReadOnly_get_right :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 5) }
@(export, link_name = "wjr_DOMRectReadOnly_get_bottom")
wjr_DOMRectReadOnly_get_bottom :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 6) }
@(export, link_name = "wjr_DOMRectReadOnly_get_left")
wjr_DOMRectReadOnly_get_left :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 7) }

@(private = "file")
rect_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue, i: i32) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_rect())
	if d == nil { return wj.EXCEPTION }
	x: f64
	if !wj.wj_to_double(ctx, v, &x, false) { return wj.EXCEPTION }
	d.rect[i] = x
	return wj.UNDEFINED
}

@(export, link_name = "wjr_DOMRect_set_x")
wjr_DOMRect_set_x :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return rect_set(ctx, this_val, v, 0) }
@(export, link_name = "wjr_DOMRect_set_y")
wjr_DOMRect_set_y :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return rect_set(ctx, this_val, v, 1) }
@(export, link_name = "wjr_DOMRect_set_width")
wjr_DOMRect_set_width :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return rect_set(ctx, this_val, v, 2) }
@(export, link_name = "wjr_DOMRect_set_height")
wjr_DOMRect_set_height :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue { return rect_set(ctx, this_val, v, 3) }
@(export, link_name = "wjr_DOMRect_get_x")
wjr_DOMRect_get_x :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 0) }
@(export, link_name = "wjr_DOMRect_get_y")
wjr_DOMRect_get_y :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 1) }
@(export, link_name = "wjr_DOMRect_get_width")
wjr_DOMRect_get_width :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 2) }
@(export, link_name = "wjr_DOMRect_get_height")
wjr_DOMRect_get_height :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return rect_field(ctx, this_val, 3) }

@(export, link_name = "wjr_DOMRectReadOnly_toJSON")
wjr_DOMRectReadOnly_toJSON :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := rect_of(ctx, this_val)
	if d == nil { return wj.EXCEPTION }
	r := &d.rect
	o := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, o, "x", wj.new_float64(ctx, r[0]))
	wj.JS_SetPropertyStr(ctx, o, "y", wj.new_float64(ctx, r[1]))
	wj.JS_SetPropertyStr(ctx, o, "width", wj.new_float64(ctx, r[2]))
	wj.JS_SetPropertyStr(ctx, o, "height", wj.new_float64(ctx, r[3]))
	wj.JS_SetPropertyStr(ctx, o, "top", wj.new_float64(ctx, fmin(r[1], r[1] + r[3])))
	wj.JS_SetPropertyStr(ctx, o, "right", wj.new_float64(ctx, fmax(r[0], r[0] + r[2])))
	wj.JS_SetPropertyStr(ctx, o, "bottom", wj.new_float64(ctx, fmax(r[1], r[1] + r[3])))
	wj.JS_SetPropertyStr(ctx, o, "left", wj.new_float64(ctx, fmin(r[0], r[0] + r[2])))
	return o
}

// ---- DOMRectList ----

@(export, link_name = "dom_rect_list")
dom_rect_list :: proc "c" (ctx: ^wj.Context, packed: [^]u8, count: u32) -> wj.JSValue {
	d: ^wj.Dom_Impl
	obj := wj.dom_new(ctx, iface_rect_list(), wj.DOM_VALUES, wj.UNDEFINED, 0, &d)
	if wj.is_exception(obj) || count == 0 { return obj }
	d.values = ([^]wj.JSValue)(wj.calloc(uint(count), size_of(wj.JSValue)))
	if d.values == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	for i in u32(0)..<count {
		v: [4]f64
		for k in 0..<4 {
			bits := wj.read_u64(packed[i * 32 + u32(k) * 8:])
			v[k] = transmute(f64)bits
		}
		d.values[i] = dom_rect_new(ctx, v[0], v[1], v[2], v[3], false)
		d.n_values = i + 1
	}
	return obj
}

@(private = "file")
values_of :: proc "c" (obj: wj.JSValue) -> ^wj.Dom_Impl {
	o := wj.obj_of(obj)
	d := o != nil ? (^wj.Dom_Impl)(o.impl) : nil
	return d != nil && d.kind == wj.DOM_VALUES ? d : nil
}

@(export, link_name = "wjr_DOMRectList_length_hook")
wjr_DOMRectList_length_hook :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue) -> u32 { d := values_of(obj); return d != nil ? d.n_values : 0 }

@(export, link_name = "wjr_DOMRectList_index_get")
wjr_DOMRectList_index_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, index: u32, found: ^bool) -> wj.JSValue {
	d := values_of(obj)
	found^ = d != nil && index < d.n_values
	return found^ ? wj.JS_DupValue(ctx, d.values[index]) : wj.UNDEFINED
}

@(export, link_name = "wjr_DOMRectList_get_length")
wjr_DOMRectList_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_rect_list())
	return d != nil ? wj.new_uint32(ctx, d.n_values) : wj.EXCEPTION
}

@(export, link_name = "wjr_DOMRectList_item")
wjr_DOMRectList_item :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	d := wj.dom_impl_of(ctx, this_val, iface_rect_list())
	if d == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "DOMRectList.item", 1, argc) }
	i: u32
	if !wj.wj_to_uint32(ctx, argv[0], &i, 32, 0) { return wj.EXCEPTION }
	return i < d.n_values ? wj.JS_DupValue(ctx, d.values[i]) : wj.NULL
}

// ---- Element ----

@(export, link_name = "wjr_Element_getBoundingClientRect")
wjr_Element_getBoundingClientRect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface_element())
	if o == nil { return wj.EXCEPTION }
	r := wj.Wr_DomRect{}
	wr_Element_boundingRect(o.handle, &r)
	return dom_rect_new(ctx, r.x, r.y, r.width, r.height, false)
}

@(export, link_name = "wjr_Element_getClientRects")
wjr_Element_getClientRects :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface_element())
	if o == nil { return wj.EXCEPTION }
	n := wr_Element_clientRectsPacked(o.handle, wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap { if wj.wj_scratch_grow(u32(n)) { n = wr_Element_clientRectsPacked(o.handle, wj.wj_scratch.data, wj.wj_scratch.cap) } }
	return dom_rect_list(ctx, wj.wj_scratch.data, n > 0 ? u32(n) / 32 : 0)
}

// scroll(x, y) / scroll(options): x and y (NaN: unchanged), smooth or not
@(private = "file")
scroll_args :: proc "c" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, x: ^f64, y: ^f64, smooth: ^bool) -> bool {
	x^ = NAN; y^ = NAN; smooth^ = false
	if argc >= 2 {
		if !wj.wj_to_double(ctx, argv[0], x, false) || !wj.wj_to_double(ctx, argv[1], y, false) { return false }
		if !is_finite(x^) { x^ = 0 }
		if !is_finite(y^) { y^ = 0 }
		return true
	}
	opt := wj.arg(argc, argv, 0)
	if wj.is_undefined(opt) || wj.is_null(opt) { return true }
	if !wj.is_object(opt) { wj.wj_throw_type(ctx, "The provided value is not of type 'ScrollToOptions'."); return false }
	left := wj.JS_GetPropertyStr(ctx, opt, "left")
	top := wj.JS_GetPropertyStr(ctx, opt, "top")
	beh := wj.JS_GetPropertyStr(ctx, opt, "behavior")
	ok := true
	if !wj.is_undefined(left) && !wj.wj_to_double(ctx, left, x, false) { ok = false }
	if ok && !wj.is_undefined(top) && !wj.wj_to_double(ctx, top, y, false) { ok = false }
	if ok && wj.is_string(beh) {
		b := wj.JS_ToCString(ctx, beh)
		if b != nil { smooth^ = wj.str_eq(b, "smooth"); wj.JS_FreeCString(ctx, b) }
	}
	wj.JS_FreeValue(ctx, left); wj.JS_FreeValue(ctx, top); wj.JS_FreeValue(ctx, beh)
	if ok && !is_nan(x^) && !is_finite(x^) { x^ = 0 }
	if ok && !is_nan(y^) && !is_finite(y^) { y^ = 0 }
	return ok
}

@(private = "file") is_nan :: proc "c" (x: f64) -> bool { return x != x }
@(private = "file") is_finite :: proc "c" (x: f64) -> bool { return x == x && x - x == 0 }

@(private = "file")
element_scroll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, relative: bool) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface_element())
	if o == nil { return wj.EXCEPTION }
	x, y: f64
	smooth: bool
	if !scroll_args(ctx, argc, argv, &x, &y, &smooth) { return wj.EXCEPTION }
	wr_Element_scrollToXY(o.handle, x, y, relative)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Element_scroll")
wjr_Element_scroll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_scroll(ctx, this_val, argc, argv, false) }
@(export, link_name = "wjr_Element_scrollTo")
wjr_Element_scrollTo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_scroll(ctx, this_val, argc, argv, false) }
@(export, link_name = "wjr_Element_scrollBy")
wjr_Element_scrollBy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return element_scroll(ctx, this_val, argc, argv, true) }

@(private = "file")
logical_position :: proc "c" (ctx: ^wj.Context, opt: wj.JSValue, name: cstring, def: i32) -> i32 {
	v := wj.JS_GetPropertyStr(ctx, opt, name)
	r := def
	if wj.is_string(v) {
		s := wj.JS_ToCString(ctx, v)
		if s != nil {
			if wj.str_eq(s, "start") { r = 0 } else if wj.str_eq(s, "center") { r = 1 } else if wj.str_eq(s, "end") { r = 2 } else if wj.str_eq(s, "nearest") { r = 3 }
			wj.JS_FreeCString(ctx, s)
		}
	}
	wj.JS_FreeValue(ctx, v)
	return r
}

@(export, link_name = "wjr_Element_scrollIntoView")
wjr_Element_scrollIntoView :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface_element())
	if o == nil { return wj.EXCEPTION }
	arg := wj.arg(argc, argv, 0)
	block := i32(0); inline_pos := i32(3)
	if wj.is_object(arg) {
		block = logical_position(ctx, arg, "block", 0)
		inline_pos = logical_position(ctx, arg, "inline", 3)
	} else if !wj.is_undefined(arg) && wj.JS_ToBool(ctx, arg) == 0 {
		block = 2
	}
	wr_Element_scrollIntoViewAt(o.handle, block, inline_pos)
	return wj.UNDEFINED
}

// ---- Window ----

@(private = "file")
window_scroll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, relative: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_win()) == nil { return wj.EXCEPTION }
	x, y: f64
	smooth: bool
	if !scroll_args(ctx, argc, argv, &x, &y, &smooth) { return wj.EXCEPTION }
	wr_Window_scrollToXY(x, y, relative, smooth)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Window_scroll")
wjr_Window_scroll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return window_scroll(ctx, this_val, argc, argv, false) }
@(export, link_name = "wjr_Window_scrollTo")
wjr_Window_scrollTo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return window_scroll(ctx, this_val, argc, argv, false) }
@(export, link_name = "wjr_Window_scrollBy")
wjr_Window_scrollBy :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return window_scroll(ctx, this_val, argc, argv, true) }
