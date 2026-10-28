// dom_events.odin: UI Events for JavaScript: UIEvent, MouseEvent, PointerEvent, WheelEvent, KeyboardEvent, FocusEvent,
// InputEvent, CompositionEvent, DragEvent, TouchEvent. Ported from native/js/runtime/dom_events.c, same symbols and
// behaviour. Their fields live in the event's extension object (events: wj_event_ext): a plain object filled from the
// constructor's dictionary, or, for an event the browser dispatches, from its details when the event is first wrapped
// (src/page/js_dom_events.odin, Event_uiData), so they stay readable after the dispatch. document.createEvent() is here
// too.
//
// What a dictionary member becomes is a table (Field), read by one loop; a getter is its member's name and default.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file")
is_mouse :: #force_inline proc "contextless" (iface: i32) -> bool { return inherits(iface, ifc("MouseEvent")) }

@(private = "file")
set_num :: #force_inline proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, k: cstring, v: f64) { wj.JS_SetPropertyStr(ctx, o, k, wj.new_float64(ctx, v)) }
@(private = "file")
set_bool :: #force_inline proc "contextless" (ctx: ^wj.Context, o: wj.JSValue, k: cstring, v: bool) { wj.JS_SetPropertyStr(ctx, o, k, wj.new_bool(v)) }

@(private = "file") pointer_types := [3]cstring{"mouse", "pen", "touch"}

// The browser dispatches a UI event: its details into the extension object.
@(export, link_name = "wj_event_wrapped")
wj_event_wrapped :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, host: u64, iface: i32) {
	context = jsb.glue_context()
	if iface == ifc("MessageEvent") {
		// HTML deserializes a message before its event is dispatched: data (and its ports), origin and lastEventId
		// are read now, while the browser's event exists, so a listener that reads them after an await sees them
		getters := [3]wj.Getter{wj.wjr_MessageEvent_get_data, wj.wjr_MessageEvent_get_origin, wj.wjr_MessageEvent_get_lastEventId}
		for g in getters {
			v := g(ctx, obj)
			if wj.is_exception(v) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) } else { wj.JS_FreeValue(ctx, v) }
		}
		return
	}
	if !inherits(iface, ifc("UIEvent")) { return }
	ev := api_decl.Event(host)
	d: wj.wr_UiEventData
	wj.wr_Event_uiData(host, &d)   // (a struct result: not a shape of the generic boundary yet)
	x := wj.JS_NewObjectProto(ctx, wj.NULL)
	if wj.is_exception(x) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return }
	wj.JS_SetPropertyStr(ctx, x, "view", wj.JS_DupValue(ctx, wj.realm_global()))
	set_num(ctx, x, "detail", f64(d.detail))
	set_bool(ctx, x, "ctrlKey", d.mods & 1 != 0)
	set_bool(ctx, x, "shiftKey", d.mods & 2 != 0)
	set_bool(ctx, x, "altKey", d.mods & 4 != 0)
	set_bool(ctx, x, "metaKey", d.mods & 8 != 0)
	if is_mouse(iface) {
		nums := [?]struct { k: cstring, v: f64 }{
			{"clientX", d.client_x}, {"clientY", d.client_y}, {"screenX", d.screen_x}, {"screenY", d.screen_y},
			{"pageX", d.page_x}, {"pageY", d.page_y}, {"offsetX", d.offset_x}, {"offsetY", d.offset_y},
			{"button", f64(d.button)}, {"buttons", f64(d.buttons)},
			{"deltaX", d.delta_x}, {"deltaY", d.delta_y}, {"deltaZ", d.delta_z}, {"deltaMode", f64(d.delta_mode)},
			{"pointerId", f64(d.pointer_id)}, {"width", d.width}, {"height", d.height},
			{"pressure", d.pressure}, {"tangentialPressure", d.tangential_pressure},
			{"tiltX", d.tilt_x}, {"tiltY", d.tilt_y}, {"twist", d.twist},
		}
		for n in nums { set_num(ctx, x, n.k, n.v) }
		set_bool(ctx, x, "isPrimary", d.is_primary != 0)
		wj.JS_SetPropertyStr(ctx, x, "pointerType", wj.new_string(ctx, pointer_types[d.pointer_type < 3 ? d.pointer_type : 0]))
		if iface == ifc("DragEvent") {
			dt: abi.Handle
			jsb.host(&dt, api_decl.DragEvent_dataTransfer, wj.wr_DragEvent_dataTransfer, ev)
			wj.JS_SetPropertyStr(ctx, x, "dataTransfer", dt != 0 ? wj.wj_wrap_host(ctx, u64(dt), ifc("DataTransfer")) : wj.NULL)
		}
	}
	if iface == ifc("TouchEvent") { touch_lists_from_host(ctx, x, host) }
	if d.related != 0 { wj.JS_SetPropertyStr(ctx, x, "relatedTarget", wj.wj_wrap_node(ctx, d.related)) }
	if iface == ifc("KeyboardEvent") {
		s: string
		jsb.host(&s, api_decl.UiEvent_key, wj.wr_UiEvent_key, ev)
		wj.JS_SetPropertyStr(ctx, x, "key", wj.new_string_len(ctx, len(s) > 0 ? s : "Unidentified"))
		s = ""
		jsb.host(&s, api_decl.UiEvent_code, wj.wr_UiEvent_code, ev)
		wj.JS_SetPropertyStr(ctx, x, "code", wj.new_string_len(ctx, s))
		set_num(ctx, x, "keyCode", f64(d.key_code))
		set_num(ctx, x, "location", f64(d.location))
		set_bool(ctx, x, "repeat", d.repeat != 0)
	}
	if input, composition := iface == ifc("InputEvent"), iface == ifc("CompositionEvent"); input || composition {
		s: string
		jsb.host(&s, api_decl.Event_data, wj.wr_Event_data, ev)
		wj.JS_SetPropertyStr(ctx, x, "data", len(s) > 0 ? wj.new_string_len(ctx, s) : (input ? wj.NULL : wj.new_string(ctx, "")))
		if input {
			s = ""
			jsb.host(&s, api_decl.Event_text, wj.wr_Event_text, ev)
			wj.JS_SetPropertyStr(ctx, x, "inputType", wj.new_string_len(ctx, s))
		}
	}
	if iface == ifc("FocusEvent") {
		rel: api_decl.Node
		jsb.host(&rel, api_decl.Event_object, wj.wr_Event_object, ev)
		if rel != 0 { wj.JS_SetPropertyStr(ctx, x, "relatedTarget", wj.wj_wrap_node(ctx, u64(rel))) }
	}
	wj.wj_event_set_ext(ctx, obj, x)
}

// ---- constructors: the dictionary's members into the extension object ----

@(private = "file")
Field_Type :: enum u8 { Num, Bool, Str, Null_Str, Obj }

@(private = "file")
Field :: struct {
	name: cstring,
	type: Field_Type,
	def:  f64,
}

@(private = "file") ui_fields := [?]Field{{"view", .Obj, 0}, {"detail", .Num, 0}, {"which", .Num, 0}}
@(private = "file") mod_fields := [?]Field{
	{"ctrlKey", .Bool, 0}, {"shiftKey", .Bool, 0}, {"altKey", .Bool, 0}, {"metaKey", .Bool, 0},
	{"modifierAltGraph", .Bool, 0}, {"modifierCapsLock", .Bool, 0}, {"modifierFn", .Bool, 0},
	{"modifierNumLock", .Bool, 0}, {"modifierScrollLock", .Bool, 0}, {"modifierSymbol", .Bool, 0},
}
@(private = "file") mouse_fields := [?]Field{
	{"screenX", .Num, 0}, {"screenY", .Num, 0}, {"clientX", .Num, 0}, {"clientY", .Num, 0},
	{"button", .Num, 0}, {"buttons", .Num, 0}, {"relatedTarget", .Obj, 0}, {"movementX", .Num, 0}, {"movementY", .Num, 0},
}
@(private = "file") pointer_fields := [?]Field{
	{"pointerId", .Num, 0}, {"width", .Num, 1}, {"height", .Num, 1}, {"pressure", .Num, 0},
	{"tangentialPressure", .Num, 0}, {"tiltX", .Num, 0}, {"tiltY", .Num, 0}, {"twist", .Num, 0},
	{"altitudeAngle", .Num, 1.5707963267948966}, {"azimuthAngle", .Num, 0}, {"pointerType", .Str, 0}, {"isPrimary", .Bool, 0},
}
@(private = "file") wheel_fields := [?]Field{{"deltaX", .Num, 0}, {"deltaY", .Num, 0}, {"deltaZ", .Num, 0}, {"deltaMode", .Num, 0}}
@(private = "file") key_fields := [?]Field{
	{"key", .Str, 0}, {"code", .Str, 0}, {"location", .Num, 0}, {"repeat", .Bool, 0},
	{"isComposing", .Bool, 0}, {"charCode", .Num, 0}, {"keyCode", .Num, 0},
}
@(private = "file") focus_fields := [?]Field{{"relatedTarget", .Obj, 0}}
@(private = "file") input_fields := [?]Field{{"data", .Null_Str, 0}, {"isComposing", .Bool, 0}, {"inputType", .Str, 0}}
@(private = "file") composition_fields := [?]Field{{"data", .Str, 0}}

// Each member of `init` the table names, converted, into x (a string's default is "").
@(private = "file")
read_fields :: proc "contextless" (ctx: ^wj.Context, init: wj.JSValue, x: wj.JSValue, fields: []Field) -> bool {
	for f in fields {
		v := wj.dom_dict_get(ctx, init, f.name)
		if wj.is_exception(v) { return false }
		defer wj.JS_FreeValue(ctx, v)
		absent := wj.is_undefined(v)
		out: wj.JSValue
		switch f.type {
		case .Num:
			d := f.def
			if !absent && !wj.wj_to_double(ctx, v, &d, false) { return false }
			out = wj.new_float64(ctx, d)
		case .Bool:
			out = wj.new_bool(!absent && wj.JS_ToBool(ctx, v) != 0)
		case .Str:
			out = absent ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, v)
		case .Null_Str:
			out = absent || wj.is_null(v) ? wj.NULL : wj.JS_ToString(ctx, v)
		case .Obj:
			out = absent ? wj.NULL : wj.JS_DupValue(ctx, v)
			if !wj.is_null(out) && !wj.is_object(out) {
				wj.JS_FreeValue(ctx, out)
				wj.JS_ThrowTypeError(ctx, "member %s is not an object", f.name)
				return false
			}
		}
		if wj.is_exception(out) { return false }
		wj.JS_SetPropertyStr(ctx, x, f.name, out)
	}
	return true
}

@(private = "file") touch_list_names := [3]cstring{"touches", "targetTouches", "changedTouches"}

@(private = "file")
ui_construct :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring) -> wj.JSValue {
	obj := wj.wj_event_construct(ctx, new_target, argc, argv, iface, name)
	if wj.is_exception(obj) { return obj }
	init := wj.arg(argc, argv, 1)
	x := wj.JS_NewObjectProto(ctx, wj.NULL)
	ok := read_fields(ctx, init, x, ui_fields[:])
	plain := iface == ifc("UIEvent") || iface == ifc("CompositionEvent") || iface == ifc("InputEvent") || iface == ifc("FocusEvent")
	if ok && !plain { ok = read_fields(ctx, init, x, mod_fields[:]) }
	if ok && is_mouse(iface) { ok = read_fields(ctx, init, x, mouse_fields[:]) }
	if ok && iface == ifc("PointerEvent") { ok = read_fields(ctx, init, x, pointer_fields[:]) }
	if ok && iface == ifc("WheelEvent") { ok = read_fields(ctx, init, x, wheel_fields[:]) }
	if ok && iface == ifc("KeyboardEvent") { ok = read_fields(ctx, init, x, key_fields[:]) }
	if ok && iface == ifc("FocusEvent") { ok = read_fields(ctx, init, x, focus_fields[:]) }
	if ok && iface == ifc("InputEvent") { ok = read_fields(ctx, init, x, input_fields[:]) }
	if ok && iface == ifc("CompositionEvent") { ok = read_fields(ctx, init, x, composition_fields[:]) }
	if ok && iface == ifc("DragEvent") {
		dt := wj.dom_dict_get(ctx, init, "dataTransfer")
		switch {
		case wj.is_exception(dt):
			ok = false
		case wj.is_nullish(dt):
			wj.JS_SetPropertyStr(ctx, x, "dataTransfer", wj.NULL)
		case wj.wj_unwrap(dt, ifc("DataTransfer")) == nil:
			wj.JS_FreeValue(ctx, dt)
			wj.wj_throw_type(ctx, "Failed to construct 'DragEvent': member dataTransfer is not of type 'DataTransfer'.")
			ok = false
		case:
			wj.JS_SetPropertyStr(ctx, x, "dataTransfer", dt)
		}
	}
	if ok && iface == ifc("TouchEvent") {
		for list in touch_list_names {
			seq := wj.dom_dict_get(ctx, init, list)
			if wj.is_exception(seq) { ok = false; break }
			tl := dom_touch_list_from_sequence(ctx, seq, list)
			wj.JS_FreeValue(ctx, seq)
			if wj.is_exception(tl) { ok = false; break }
			wj.JS_SetPropertyStr(ctx, x, list, tl)
		}
	}
	if !ok { wj.JS_FreeValue(ctx, x); wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	// MouseEvent: page and offset coordinates follow the client ones for a synthetic event
	if is_mouse(iface) {
		wj.JS_SetPropertyStr(ctx, x, "pageX", wj.JS_GetPropertyStr(ctx, x, "clientX"))
		wj.JS_SetPropertyStr(ctx, x, "pageY", wj.JS_GetPropertyStr(ctx, x, "clientY"))
		wj.JS_SetPropertyStr(ctx, x, "offsetX", wj.JS_GetPropertyStr(ctx, x, "clientX"))
		wj.JS_SetPropertyStr(ctx, x, "offsetY", wj.JS_GetPropertyStr(ctx, x, "clientY"))
	}
	wj.wj_event_set_ext(ctx, obj, x)
	return obj
}

@(export, link_name = "wjr_UIEvent_constructor")
wjr_UIEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("UIEvent"), "UIEvent") }
@(export, link_name = "wjr_MouseEvent_constructor")
wjr_MouseEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("MouseEvent"), "MouseEvent") }
@(export, link_name = "wjr_PointerEvent_constructor")
wjr_PointerEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("PointerEvent"), "PointerEvent") }
@(export, link_name = "wjr_DragEvent_constructor")
wjr_DragEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("DragEvent"), "DragEvent") }
@(export, link_name = "wjr_TouchEvent_constructor")
wjr_TouchEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("TouchEvent"), "TouchEvent") }
@(export, link_name = "wjr_WheelEvent_constructor")
wjr_WheelEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("WheelEvent"), "WheelEvent") }
@(export, link_name = "wjr_KeyboardEvent_constructor")
wjr_KeyboardEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("KeyboardEvent"), "KeyboardEvent") }
@(export, link_name = "wjr_FocusEvent_constructor")
wjr_FocusEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("FocusEvent"), "FocusEvent") }
@(export, link_name = "wjr_InputEvent_constructor")
wjr_InputEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("InputEvent"), "InputEvent") }
@(export, link_name = "wjr_CompositionEvent_constructor")
wjr_CompositionEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return ui_construct(ctx, nt, argc, argv, ifc("CompositionEvent"), "CompositionEvent") }

// ---- getters: the extension object's member, or the default ----

@(private = "file")
Default :: enum u8 { Zero, One, False, Null, Empty, Half_Pi, Undefined }

@(private = "file")
default_value :: proc "contextless" (ctx: ^wj.Context, d: Default) -> wj.JSValue {
	switch d {
	case .Zero:      return wj.new_int32(0)
	case .One:       return wj.new_int32(1)
	case .False:     return wj.FALSE
	case .Null:      return wj.NULL
	case .Empty:     return wj.new_string(ctx, "")
	case .Half_Pi:   return wj.new_float64(ctx, 1.5707963267948966)
	case .Undefined: return wj.UNDEFINED
	}
	return wj.UNDEFINED
}

// member `name` of the extension object of `this` (an event of `iface`), the default when it has none
@(private = "file")
xf :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, name: cstring, def: Default) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface) == nil { return wj.EXCEPTION }
	x := wj.wj_event_ext(this_val)
	if !wj.is_object(x) { return default_value(ctx, def) }
	v := wj.JS_GetPropertyStr(ctx, x, name)
	return wj.is_undefined(v) ? default_value(ctx, def) : v
}

@(export, link_name = "wjr_UIEvent_get_view")
wjr_UIEvent_get_view :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("UIEvent"), "view", .Null) }
@(export, link_name = "wjr_UIEvent_get_detail")
wjr_UIEvent_get_detail :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("UIEvent"), "detail", .Zero) }

// which: the key code of a keyboard event, button + 1 of a mouse event
@(export, link_name = "wjr_UIEvent_get_which")
wjr_UIEvent_get_which :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	o := wj.wj_this(ctx, t, ifc("UIEvent"))
	if o == nil { return wj.EXCEPTION }
	if i32(o.iface) == ifc("KeyboardEvent") { return xf(ctx, t, ifc("UIEvent"), "keyCode", .Zero) }
	if is_mouse(i32(o.iface)) {
		b := xf(ctx, t, ifc("UIEvent"), "button", .Zero)
		d: f64
		wj.JS_ToFloat64(ctx, &d, b)
		wj.JS_FreeValue(ctx, b)
		return wj.new_int32(i32(d) + 1)
	}
	return xf(ctx, t, ifc("UIEvent"), "which", .Zero)
}

@(export, link_name = "wjr_UIEvent_initUIEvent")
wjr_UIEvent_initUIEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	init := wj.JS_GetPropertyStr(ctx, this_val, "initEvent")
	r := wj.JS_Call(ctx, init, this_val, min(argc, 3), argv)
	wj.JS_FreeValue(ctx, init)
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	x := wj.JS_NewObjectProto(ctx, wj.NULL)
	wj.JS_SetPropertyStr(ctx, x, "view", argc > 3 ? wj.JS_DupValue(ctx, argv[3]) : wj.NULL)
	detail: f64
	if argc > 4 { wj.wj_to_double(ctx, argv[4], &detail, false) }
	set_num(ctx, x, "detail", detail)
	wj.wj_event_set_ext(ctx, this_val, x)
	return wj.UNDEFINED
}

@(private = "file") M :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring, def: Default) -> wj.JSValue { return xf(ctx, t, ifc("MouseEvent"), name, def) }

@(export, link_name = "wjr_MouseEvent_get_screenX")   wjr_MouseEvent_get_screenX   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "screenX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_screenY")   wjr_MouseEvent_get_screenY   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "screenY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_clientX")   wjr_MouseEvent_get_clientX   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "clientX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_clientY")   wjr_MouseEvent_get_clientY   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "clientY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_x")         wjr_MouseEvent_get_x         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "clientX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_y")         wjr_MouseEvent_get_y         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "clientY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_pageX")     wjr_MouseEvent_get_pageX     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "pageX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_pageY")     wjr_MouseEvent_get_pageY     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "pageY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_offsetX")   wjr_MouseEvent_get_offsetX   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "offsetX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_offsetY")   wjr_MouseEvent_get_offsetY   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "offsetY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_layerX")    wjr_MouseEvent_get_layerX    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "offsetX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_layerY")    wjr_MouseEvent_get_layerY    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "offsetY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_movementX") wjr_MouseEvent_get_movementX :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "movementX", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_movementY") wjr_MouseEvent_get_movementY :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "movementY", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_ctrlKey")   wjr_MouseEvent_get_ctrlKey   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "ctrlKey", .False) }
@(export, link_name = "wjr_MouseEvent_get_shiftKey")  wjr_MouseEvent_get_shiftKey  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "shiftKey", .False) }
@(export, link_name = "wjr_MouseEvent_get_altKey")    wjr_MouseEvent_get_altKey    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "altKey", .False) }
@(export, link_name = "wjr_MouseEvent_get_metaKey")   wjr_MouseEvent_get_metaKey   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "metaKey", .False) }
@(export, link_name = "wjr_MouseEvent_get_button")    wjr_MouseEvent_get_button    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "button", .Zero) }
@(export, link_name = "wjr_MouseEvent_get_buttons")   wjr_MouseEvent_get_buttons   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return M(ctx, t, "buttons", .Zero) }

// relatedTarget: while the event is dispatched, as the current listener sees it (retargeted by the browser)
@(private = "file")
related_now :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32) -> wj.JSValue {
	context = jsb.glue_context()
	if host := wj.wj_event_host(t); host != 0 && wj.wj_this(ctx, t, iface) != nil {
		rel: abi.Handle
		jsb.host(&rel, api_decl.Event_relatedNow, wj.wr_Event_relatedNow, api_decl.Event(host))
		return wj.wj_wrap_target(ctx, u64(rel))
	}
	return xf(ctx, t, iface, "relatedTarget", .Null)
}

@(export, link_name = "wjr_MouseEvent_get_relatedTarget")
wjr_MouseEvent_get_relatedTarget :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return related_now(ctx, t, ifc("MouseEvent")) }

// getModifierState(key) of mouse, keyboard and touch events
@(private = "file")
modifier_state :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, iface: i32, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "getModifierState", 1, argc) }
	n: uint
	k := wj.to_cstring_len(ctx, &n, argv[0])
	if k == nil { return wj.EXCEPTION }
	field: cstring
	switch string(([^]u8)(rawptr(k))[:n]) {
	case "Control":    field = "ctrlKey"
	case "Shift":      field = "shiftKey"
	case "Alt":        field = "altKey"
	case "Meta":       field = "metaKey"
	case "AltGraph":   field = "modifierAltGraph"
	case "CapsLock":   field = "modifierCapsLock"
	case "NumLock":    field = "modifierNumLock"
	case "ScrollLock": field = "modifierScrollLock"
	}
	wj.JS_FreeCString(ctx, k)
	if field == nil { return wj.wj_this(ctx, t, iface) != nil ? wj.FALSE : wj.EXCEPTION }
	v := xf(ctx, t, iface, field, .False)
	if wj.is_exception(v) { return v }
	b := wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return wj.new_bool(b)
}

@(export, link_name = "wjr_MouseEvent_getModifierState")
wjr_MouseEvent_getModifierState :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return modifier_state(ctx, t, ifc("MouseEvent"), argc, argv) }
@(export, link_name = "wjr_KeyboardEvent_getModifierState")
wjr_KeyboardEvent_getModifierState :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return modifier_state(ctx, t, ifc("KeyboardEvent"), argc, argv) }
@(export, link_name = "wjr_TouchEvent_getModifierState")
wjr_TouchEvent_getModifierState :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return modifier_state(ctx, t, ifc("TouchEvent"), argc, argv) }

@(private = "file") P :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring, def: Default) -> wj.JSValue { return xf(ctx, t, ifc("PointerEvent"), name, def) }

@(export, link_name = "wjr_PointerEvent_get_pointerId")          wjr_PointerEvent_get_pointerId          :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "pointerId", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_width")              wjr_PointerEvent_get_width              :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "width", .One) }
@(export, link_name = "wjr_PointerEvent_get_height")             wjr_PointerEvent_get_height             :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "height", .One) }
@(export, link_name = "wjr_PointerEvent_get_pressure")           wjr_PointerEvent_get_pressure           :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "pressure", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_tangentialPressure") wjr_PointerEvent_get_tangentialPressure :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "tangentialPressure", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_tiltX")              wjr_PointerEvent_get_tiltX              :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "tiltX", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_tiltY")              wjr_PointerEvent_get_tiltY              :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "tiltY", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_twist")              wjr_PointerEvent_get_twist              :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "twist", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_altitudeAngle")      wjr_PointerEvent_get_altitudeAngle      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "altitudeAngle", .Half_Pi) }
@(export, link_name = "wjr_PointerEvent_get_azimuthAngle")       wjr_PointerEvent_get_azimuthAngle       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "azimuthAngle", .Zero) }
@(export, link_name = "wjr_PointerEvent_get_pointerType")        wjr_PointerEvent_get_pointerType        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "pointerType", .Empty) }
@(export, link_name = "wjr_PointerEvent_get_isPrimary")          wjr_PointerEvent_get_isPrimary          :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return P(ctx, t, "isPrimary", .False) }

@(export, link_name = "wjr_DragEvent_get_dataTransfer")
wjr_DragEvent_get_dataTransfer :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("DragEvent"), "dataTransfer", .Null) }

// a TouchList member: the dictionary's, else an empty list made once
@(private = "file")
touch_list_field :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, name: cstring) -> wj.JSValue {
	v := xf(ctx, t, ifc("TouchEvent"), name, .Undefined)
	if !wj.is_undefined(v) { return v }
	tl := dom_touch_list(ctx, wj.JS_NewArray(ctx))
	if x := wj.wj_event_ext(t); wj.is_object(x) && !wj.is_exception(tl) { wj.JS_SetPropertyStr(ctx, x, name, wj.JS_DupValue(ctx, tl)) }
	return tl
}

@(private = "file") T :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring) -> wj.JSValue { return xf(ctx, t, ifc("TouchEvent"), name, .False) }

@(export, link_name = "wjr_TouchEvent_get_touches")        wjr_TouchEvent_get_touches        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return touch_list_field(ctx, t, "touches") }
@(export, link_name = "wjr_TouchEvent_get_targetTouches")  wjr_TouchEvent_get_targetTouches  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return touch_list_field(ctx, t, "targetTouches") }
@(export, link_name = "wjr_TouchEvent_get_changedTouches") wjr_TouchEvent_get_changedTouches :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return touch_list_field(ctx, t, "changedTouches") }
@(export, link_name = "wjr_TouchEvent_get_ctrlKey")        wjr_TouchEvent_get_ctrlKey        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return T(ctx, t, "ctrlKey") }
@(export, link_name = "wjr_TouchEvent_get_shiftKey")       wjr_TouchEvent_get_shiftKey       :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return T(ctx, t, "shiftKey") }
@(export, link_name = "wjr_TouchEvent_get_altKey")         wjr_TouchEvent_get_altKey         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return T(ctx, t, "altKey") }
@(export, link_name = "wjr_TouchEvent_get_metaKey")        wjr_TouchEvent_get_metaKey        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return T(ctx, t, "metaKey") }

@(private = "file") W :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring) -> wj.JSValue { return xf(ctx, t, ifc("WheelEvent"), name, .Zero) }

@(export, link_name = "wjr_WheelEvent_get_deltaX")    wjr_WheelEvent_get_deltaX    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return W(ctx, t, "deltaX") }
@(export, link_name = "wjr_WheelEvent_get_deltaY")    wjr_WheelEvent_get_deltaY    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return W(ctx, t, "deltaY") }
@(export, link_name = "wjr_WheelEvent_get_deltaZ")    wjr_WheelEvent_get_deltaZ    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return W(ctx, t, "deltaZ") }
@(export, link_name = "wjr_WheelEvent_get_deltaMode") wjr_WheelEvent_get_deltaMode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return W(ctx, t, "deltaMode") }

@(private = "file") K :: proc "contextless" (ctx: ^wj.Context, t: wj.JSValue, name: cstring, def: Default) -> wj.JSValue { return xf(ctx, t, ifc("KeyboardEvent"), name, def) }

@(export, link_name = "wjr_KeyboardEvent_get_key")         wjr_KeyboardEvent_get_key         :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "key", .Empty) }
@(export, link_name = "wjr_KeyboardEvent_get_code")        wjr_KeyboardEvent_get_code        :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "code", .Empty) }
@(export, link_name = "wjr_KeyboardEvent_get_location")    wjr_KeyboardEvent_get_location    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "location", .Zero) }
@(export, link_name = "wjr_KeyboardEvent_get_ctrlKey")     wjr_KeyboardEvent_get_ctrlKey     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "ctrlKey", .False) }
@(export, link_name = "wjr_KeyboardEvent_get_shiftKey")    wjr_KeyboardEvent_get_shiftKey    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "shiftKey", .False) }
@(export, link_name = "wjr_KeyboardEvent_get_altKey")      wjr_KeyboardEvent_get_altKey      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "altKey", .False) }
@(export, link_name = "wjr_KeyboardEvent_get_metaKey")     wjr_KeyboardEvent_get_metaKey     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "metaKey", .False) }
@(export, link_name = "wjr_KeyboardEvent_get_repeat")      wjr_KeyboardEvent_get_repeat      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "repeat", .False) }
@(export, link_name = "wjr_KeyboardEvent_get_isComposing") wjr_KeyboardEvent_get_isComposing :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "isComposing", .False) }
@(export, link_name = "wjr_KeyboardEvent_get_keyCode")     wjr_KeyboardEvent_get_keyCode     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return K(ctx, t, "keyCode", .Zero) }

// charCode: the character of a keypress
@(export, link_name = "wjr_KeyboardEvent_get_charCode")
wjr_KeyboardEvent_get_charCode :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	v := K(ctx, t, "charCode", .Undefined)
	if !wj.is_undefined(v) { return v }
	type := wj.JS_GetPropertyStr(ctx, t, "type")
	press := js_str_is(ctx, type, "keypress")
	if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
	wj.JS_FreeValue(ctx, type)
	if !press { return wj.new_int32(0) }
	key := wjr_KeyboardEvent_get_key(ctx, t)
	defer wj.JS_FreeValue(ctx, key)
	n: uint
	k := wj.to_cstring_len(ctx, &n, key)
	if k == nil { return wj.new_int32(0) }
	defer wj.JS_FreeCString(ctx, k)
	return wj.new_int32(n == 1 ? i32(([^]u8)(rawptr(k))[0]) : 0)
}

@(export, link_name = "wjr_FocusEvent_get_relatedTarget")
wjr_FocusEvent_get_relatedTarget :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return related_now(ctx, t, ifc("FocusEvent")) }
@(export, link_name = "wjr_InputEvent_get_data")
wjr_InputEvent_get_data :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("InputEvent"), "data", .Null) }
@(export, link_name = "wjr_InputEvent_get_isComposing")
wjr_InputEvent_get_isComposing :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("InputEvent"), "isComposing", .False) }
@(export, link_name = "wjr_InputEvent_get_inputType")
wjr_InputEvent_get_inputType :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("InputEvent"), "inputType", .Empty) }
@(export, link_name = "wjr_InputEvent_get_dataTransfer")
wjr_InputEvent_get_dataTransfer :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return wj.wj_this(ctx, t, ifc("InputEvent")) != nil ? wj.NULL : wj.EXCEPTION }
@(export, link_name = "wjr_CompositionEvent_get_data")
wjr_CompositionEvent_get_data :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return xf(ctx, t, ifc("CompositionEvent"), "data", .Empty) }

// ---- document.createEvent(interface) (DOM §4.5, the legacy names) ----

@(export, link_name = "wjr_Document_createEvent")
wjr_Document_createEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, ifc("Document")) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Document.createEvent", 1, argc) }
	n: uint
	s := wj.to_cstring_len(ctx, &n, argv[0])
	if s == nil { return wj.EXCEPTION }
	lower: [40]u8
	// (the name up to its first NUL, as a C string compare reads it)
	l := 0
	for l < min(int(n), len(lower) - 1) && ([^]u8)(rawptr(s))[l] != 0 { lower[l] = lower_ascii(([^]u8)(rawptr(s))[l]); l += 1 }
	wj.JS_FreeCString(ctx, s)
	iface := i32(-1)
	switch string(lower[:l]) {
	case "event", "events", "htmlevents", "svgevents": iface = ifc("Event")
	case "customevent":                                iface = ifc("CustomEvent")
	case "uievent", "uievents":                        iface = ifc("UIEvent")
	case "mouseevent", "mouseevents":                  iface = ifc("MouseEvent")
	case "keyboardevent":                              iface = ifc("KeyboardEvent")
	case "focusevent":                                 iface = ifc("FocusEvent")
	case "compositionevent", "textevent":              iface = ifc("CompositionEvent")
	case "messageevent":                               iface = ifc("MessageEvent")
	case "hashchangeevent":                            iface = ifc("HashChangeEvent")
	case "storageevent":                               iface = ifc("StorageEvent")
	}
	if iface < 0 { return wj.wj_throw_dom(ctx, "NotSupportedError", "The provided event type is not supported.") }
	e := wj.wj_event_new_uninitialized(ctx, iface)
	if !wj.is_exception(e) && inherits(iface, ifc("UIEvent")) { wj.wj_event_set_ext(ctx, e, wj.JS_NewObjectProto(ctx, wj.NULL)) }
	return e
}

// initMouseEvent / initKeyboardEvent (legacy)
@(private = "file") init_mouse_names := [10]cstring{"screenX", "screenY", "clientX", "clientY", "ctrlKey", "altKey", "shiftKey", "metaKey", "button", "relatedTarget"}

@(export, link_name = "wjr_MouseEvent_initMouseEvent")
wjr_MouseEvent_initMouseEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := wjr_UIEvent_initUIEvent(ctx, this_val, argc, argv)
	if wj.is_exception(r) { return r }
	x := wj.wj_event_ext(this_val)
	if !wj.is_object(x) { return wj.UNDEFINED }
	for name, i in init_mouse_names {
		v := wj.arg(argc, argv, 5 + i32(i))
		switch {
		case i >= 4 && i < 8:
			wj.JS_SetPropertyStr(ctx, x, name, wj.new_bool(wj.JS_ToBool(ctx, v) != 0))
		case i == 9:
			wj.JS_SetPropertyStr(ctx, x, name, wj.is_object(v) ? wj.JS_DupValue(ctx, v) : wj.NULL)
		case:
			d: f64
			if !wj.is_undefined(v) { wj.wj_to_double(ctx, v, &d, false) }
			set_num(ctx, x, name, d)
		}
	}
	wj.JS_SetPropertyStr(ctx, x, "pageX", wj.JS_GetPropertyStr(ctx, x, "clientX"))
	wj.JS_SetPropertyStr(ctx, x, "pageY", wj.JS_GetPropertyStr(ctx, x, "clientY"))
	return wj.UNDEFINED
}

@(private = "file") init_key_mods := [4]cstring{"ctrlKey", "altKey", "shiftKey", "metaKey"}

@(export, link_name = "wjr_KeyboardEvent_initKeyboardEvent")
wjr_KeyboardEvent_initKeyboardEvent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	r := wjr_UIEvent_initUIEvent(ctx, this_val, argc, argv)
	if wj.is_exception(r) { return r }
	x := wj.wj_event_ext(this_val)
	if !wj.is_object(x) { return wj.UNDEFINED }
	wj.JS_SetPropertyStr(ctx, x, "key", argc > 4 ? wj.JS_ToString(ctx, argv[4]) : wj.new_string(ctx, ""))
	loc: f64
	if argc > 5 { wj.wj_to_double(ctx, argv[5], &loc, false) }
	set_num(ctx, x, "location", loc)
	for name, i in init_key_mods { set_bool(ctx, x, name, argc > 6 + i32(i) && wj.JS_ToBool(ctx, argv[6 + i]) != 0) }
	return wj.UNDEFINED
}
