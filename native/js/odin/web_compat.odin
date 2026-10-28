// web_compat.odin: small platform pieces that pages probe or call without feature detection. Ported from
// native/js/runtime/web_compat.c; same wjr_* symbols, web_compat_preinit and web_compat_start.
//   window.alert / confirm / prompt   no dialog is shown: they return what a dismissed one does (undefined, false, null)
//                                     and say so on the console
//   window.visualViewport             the layout viewport (no pinch zoom: scale 1, no offset), with resize / scroll events
//   navigator.permissions             query(): PermissionStatus (granted for clipboard-write and fullscreen, prompt for
//                                     clipboard-read and the powers a page can ask for, denied for the ones this browser
//                                     lacks)
//   document.fonts                    a FontFaceSet without font faces of its own: ready, check, load, status, the Set
//                                     methods (the page's web fonts load as always; `await document.fonts.ready` works)
//   Element.scrollIntoViewIfNeeded, the WebKit-prefixed names of the Fullscreen API (webkitRequestFullscreen,
//   webkitFullscreenElement, onwebkitfullscreenchange...), document.execCommand("copy" / "cut"),
//   queryCommandSupported / queryCommandEnabled: not in any IDL, defined on the prototypes at pre-initialization.
// The browser's state (scroll offset, viewport size, an element's rectangle) is read through declared host calls.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") if_visual_viewport, if_permissions, if_permission_status, if_font_face_set := i32(-2), i32(-2), i32(-2), i32(-2)
@(private = "file") if_element, if_document, if_navigator_c, if_worker_navigator_c := i32(-2), i32(-2), i32(-2), i32(-2)
@(private = "file") nothing: abi.Nothing
@(private = "file") HIDDEN :: wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE

// ---- dialogs that are not shown ----

// "alert(message): this browser shows no dialogs" as a console warning
@(private = "file")
dialog_note :: proc "contextless" (ctx: ^wj.Context, name: string, argc: i32, argv: [^]wj.JSValue) -> bool {
	context = m4_context()
	b: [dynamic]u8
	defer delete(b)
	append(&b, name)
	append(&b, "(")
	if argc > 0 {
		c, s := to_text(ctx, argv[0])
		if c == nil { return false }
		append(&b, s)
		wj.free_cstring(ctx, c)
	}
	append(&b, "): this browser shows no dialogs")
	wj.wj_console_text(i32(wj.wr_ConsoleLevel.Warn), raw_data(b), uint(len(b)))
	return true
}

@(export, link_name = "wjr_Window_alert")
wjr_Window_alert :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return dialog_note(ctx, "alert", argc, argv) ? wj.UNDEFINED : wj.EXCEPTION
}
@(export, link_name = "wjr_Window_confirm")
wjr_Window_confirm :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return dialog_note(ctx, "confirm", argc, argv) ? wj.FALSE : wj.EXCEPTION
}
@(export, link_name = "wjr_Window_prompt")
wjr_Window_prompt :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return dialog_note(ctx, "prompt", argc, argv) ? wj.NULL : wj.EXCEPTION
}

// ---- window.visualViewport ----

// The window's resize and scroll events, as the viewport's (the layout viewport is the visual one). data[0]: the viewport.
@(private = "file")
viewport_forward :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	wj.web_fire_simple(ctx, data[0], magic != 0 ? "scroll" : "resize")
	return wj.UNDEFINED
}

@(private = "file")
make_viewport :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	context = m4_context()
	target: abi.Handle
	jsb.host(&target, api_decl.EventTarget_create, wj.wr_EventTarget_create)
	vv := wj.wj_wrap_owned(ctx, u64(target), iface_lazy(&if_visual_viewport, "VisualViewport"), wj.UNDEFINED)
	if !wj.is_object(vv) { return vv }
	TYPES :: [2]cstring{"resize", "scroll"}
	types := TYPES
	for type, i in types {
		args := [2]wj.JSValue{wj.new_string(ctx, type), wj.JS_NewCFunctionData(ctx, viewport_forward, 0, i32(i), 1, &vv)}
		r := wj.invoke(ctx, wj.realm_global(), "addEventListener", args[:])
		free_values(ctx, args[0], args[1])
		if wj.is_exception(r) { wj.JS_FreeValue(ctx, vv); return r }
		wj.JS_FreeValue(ctx, r)
	}
	return vv
}

@(export, link_name = "wjr_Window_get_visualViewport")
wjr_Window_get_visualViewport :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_VISUAL_VIEWPORT, make_viewport)
}

@(private = "file")
Viewport_Number :: enum { Offset_Left, Offset_Top, Page_Left, Page_Top, Width, Height, Scale }

@(private = "file")
viewport_number :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, which: Viewport_Number) -> wj.JSValue {
	context = m4_context()
	if wj.wj_this(ctx, this_val, iface_lazy(&if_visual_viewport, "VisualViewport")) == nil { return wj.EXCEPTION }
	v: f64
	switch which {
	case .Offset_Left, .Offset_Top:
	case .Page_Left: jsb.host(&v, api_decl.Window_scrollX, wj.wr_Window_scrollX)
	case .Page_Top:  jsb.host(&v, api_decl.Window_scrollY, wj.wr_Window_scrollY)
	case .Width, .Height:
		root: u64
		jsb.host(&root, api_decl.Document_documentElement, wj.wr_Document_documentElement)
		if root != 0 {
			n: i32
			if which == .Width { jsb.host(&n, api_decl.Element_clientWidth, wj.wr_Element_clientWidth, root) }
			else { jsb.host(&n, api_decl.Element_clientHeight, wj.wr_Element_clientHeight, root) }
			v = f64(n)
		}
	case .Scale: v = 1
	}
	return wj.new_float64(ctx, v)
}

@(export, link_name = "wjr_VisualViewport_get_offsetLeft") wjr_VisualViewport_get_offsetLeft :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Offset_Left) }
@(export, link_name = "wjr_VisualViewport_get_offsetTop")  wjr_VisualViewport_get_offsetTop  :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Offset_Top) }
@(export, link_name = "wjr_VisualViewport_get_pageLeft")   wjr_VisualViewport_get_pageLeft   :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Page_Left) }
@(export, link_name = "wjr_VisualViewport_get_pageTop")    wjr_VisualViewport_get_pageTop    :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Page_Top) }
@(export, link_name = "wjr_VisualViewport_get_width")      wjr_VisualViewport_get_width      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Width) }
@(export, link_name = "wjr_VisualViewport_get_height")     wjr_VisualViewport_get_height     :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Height) }
@(export, link_name = "wjr_VisualViewport_get_scale")      wjr_VisualViewport_get_scale      :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { return viewport_number(ctx, t, .Scale) }

// ---- navigator.permissions ----

@(private = "file")
PERMISSION_NAMES := [32]cstring{
	"geolocation", "notifications", "push", "midi", "camera", "microphone", "speaker-selection", "device-info",
	"background-fetch", "background-sync", "bluetooth", "persistent-storage", "ambient-light-sensor", "accelerometer",
	"gyroscope", "magnetometer", "clipboard-read", "clipboard-write", "screen-wake-lock", "nfc", "display-capture",
	"accessibility-events", "payment-handler", "storage-access", "top-level-storage-access", "window-management",
	"local-fonts", "idle-detection", "keyboard-lock", "pointer-lock", "captured-surface-control", "fullscreen",
}

@(private = "file")
permission_state :: proc "contextless" (name: cstring) -> cstring {
	switch string(name) {
	case "clipboard-write", "fullscreen": return "granted"
	case "clipboard-read", "persistent-storage", "storage-access": return "prompt"
	}
	return "denied"
}

@(private = "file")
make_permissions :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, iface_lazy(&if_permissions, "Permissions"), nil, nil) }

@(export, link_name = "wjr_Navigator_get_permissions")
wjr_Navigator_get_permissions :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_lazy(&if_navigator_c, "Navigator")) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_PERMISSIONS, make_permissions)
}

@(export, link_name = "wjr_WorkerNavigator_get_permissions")
wjr_WorkerNavigator_get_permissions :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_lazy(&if_worker_navigator_c, "WorkerNavigator")) == nil { return wj.EXCEPTION }
	return wj.web_singleton(ctx, wj.SINGLE_PERMISSIONS, make_permissions)
}

// A PermissionStatus keeps the name it answers for (one of PERMISSION_NAMES, static) as its impl.
@(private = "file")
make_status :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	context = m4_context()
	target: abi.Handle
	jsb.host(&target, api_decl.EventTarget_create, wj.wr_EventTarget_create)
	st := wj.wj_wrap_owned(ctx, u64(target), iface_lazy(&if_permission_status, "PermissionStatus"), wj.UNDEFINED)
	if !wj.is_object(st) { return wj.is_exception(st) ? st : wj.JS_ThrowTypeError(ctx, "there is no document to ask about") }
	wj.web_set_impl(st, rawptr(name), nil, nil)
	return st
}

@(export, link_name = "wjr_Permissions_query")
wjr_Permissions_query :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface_lazy(&if_permissions, "Permissions")) == nil { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "Permissions.query", 1, argc); return wj.web_promise_reject_pending(ctx) }
	if !wj.is_object(argv[0]) {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'query' on 'Permissions': parameter 1 is not of type 'PermissionDescriptor'.")
		return wj.web_promise_reject_pending(ctx)
	}
	n := wj.JS_GetPropertyStr(ctx, argv[0], "name")
	if wj.is_exception(n) { return wj.web_promise_reject_pending(ctx) }
	if wj.is_undefined(n) {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'query' on 'Permissions': Failed to read the 'name' property from 'PermissionDescriptor': Required member is undefined.")
		return wj.web_promise_reject_pending(ctx)
	}
	c, name := to_text(ctx, n)
	wj.JS_FreeValue(ctx, n)
	if c == nil { return wj.web_promise_reject_pending(ctx) }
	known: cstring
	for p in PERMISSION_NAMES { if string(p) == name { known = p; break } }
	if known == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'query' on 'Permissions': Failed to read the 'name' property from 'PermissionDescriptor': The provided value '%s' is not a valid enum value of type PermissionName.", c)
		wj.free_cstring(ctx, c)
		return wj.web_promise_reject_pending(ctx)
	}
	wj.free_cstring(ctx, c)
	st := make_status(ctx, known)
	if wj.is_exception(st) { return wj.web_promise_reject_pending(ctx) }
	return wj.web_promise_take(ctx, st)
}

@(private = "file")
status_name :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> cstring {
	return cstring(wj.web_this_impl(ctx, this_val, iface_lazy(&if_permission_status, "PermissionStatus")))
}
@(export, link_name = "wjr_PermissionStatus_get_name")
wjr_PermissionStatus_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	name := status_name(ctx, this_val)
	return name != nil ? wj.new_string(ctx, name) : wj.EXCEPTION
}
@(export, link_name = "wjr_PermissionStatus_get_state")
wjr_PermissionStatus_get_state :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	name := status_name(ctx, this_val)
	return name != nil ? wj.new_string(ctx, permission_state(name)) : wj.EXCEPTION
}

// ---- document.fonts ----

// The faces a script adds are kept in a Set the FontFaceSet hides (nothing loads from them); `ready` is a promise
// fulfilled with the set, made once.
@(private = "file")
fonts_store :: proc "contextless" (ctx: ^wj.Context, self: wj.JSValue) -> wj.JSValue {
	s := wj.web_extra_get(ctx, self, "set")
	if !wj.is_undefined(s) { return s }
	ctor := wj.global_get(ctx, "Set")
	s = wj.JS_CallConstructor(ctx, ctor, 0, nil)
	wj.JS_FreeValue(ctx, ctor)
	if wj.is_exception(s) { return s }
	if !wj.web_extra_set(ctx, self, "set", wj.JS_DupValue(ctx, s)) { wj.JS_FreeValue(ctx, s); return wj.EXCEPTION }
	return s
}

@(private = "file")
make_fonts :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	context = m4_context()
	target: abi.Handle
	jsb.host(&target, api_decl.EventTarget_create, wj.wr_EventTarget_create)
	return wj.wj_wrap_owned(ctx, u64(target), iface_lazy(&if_font_face_set, "FontFaceSet"), wj.UNDEFINED)
}

@(export, link_name = "wjr_FontFaceSource_get_fonts")
wjr_FontFaceSource_get_fonts :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.web_singleton(ctx, wj.SINGLE_FONTS, make_fonts)
}

@(private = "file")
fonts_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> bool {
	return wj.wj_this(ctx, this_val, iface_lazy(&if_font_face_set, "FontFaceSet")) != nil
}

// Set.prototype[method](args) on the hidden set
@(private = "file")
fonts_call :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, method: cstring, args: []wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.EXCEPTION }
	set := fonts_store(ctx, this_val)
	if wj.is_exception(set) { return set }
	r := wj.invoke(ctx, set, method, args)
	wj.JS_FreeValue(ctx, set)
	return r
}

@(export, link_name = "wjr_FontFaceSet_add")
wjr_FontFaceSet_add :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "FontFaceSet.add", 1, argc) }
	r := fonts_call(ctx, this_val, "add", argv[:1])
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.JS_DupValue(ctx, this_val)
}
@(export, link_name = "wjr_FontFaceSet_delete")
wjr_FontFaceSet_delete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "FontFaceSet.delete", 1, argc) }
	return fonts_call(ctx, this_val, "delete", argv[:1])
}
@(export, link_name = "wjr_FontFaceSet_has")
wjr_FontFaceSet_has :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "FontFaceSet.has", 1, argc) }
	return fonts_call(ctx, this_val, "has", argv[:1])
}
@(export, link_name = "wjr_FontFaceSet_clear")
wjr_FontFaceSet_clear :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fonts_call(ctx, this_val, "clear", nil) }

@(export, link_name = "wjr_FontFaceSet_get_size")
wjr_FontFaceSet_get_size :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.EXCEPTION }
	set := fonts_store(ctx, this_val)
	if wj.is_exception(set) { return set }
	n := wj.JS_GetPropertyStr(ctx, set, "size")
	wj.JS_FreeValue(ctx, set)
	return n
}

@(export, link_name = "wjr_FontFaceSet_keys")
wjr_FontFaceSet_keys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fonts_call(ctx, this_val, "values", nil) }
@(export, link_name = "wjr_FontFaceSet_values")
wjr_FontFaceSet_values :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fonts_call(ctx, this_val, "values", nil) }
@(export, link_name = "wjr_FontFaceSet_entries")
wjr_FontFaceSet_entries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fonts_call(ctx, this_val, "entries", nil) }

// data: the callback, thisArg, the FontFaceSet; called by Set.prototype.forEach with (value, key, set)
@(private = "file")
fonts_each :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	face := wj.arg(argc, argv, 0)
	args := [3]wj.JSValue{face, face, data[2]}
	r := wj.JS_Call(ctx, data[0], data[1], 3, &args[0])
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_FontFaceSet_forEach")
wjr_FontFaceSet_forEach :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 || !wj.JS_IsFunction(ctx, argv[0]) {
		return wj.JS_ThrowTypeError(ctx, "Failed to execute 'forEach' on 'FontFaceSet': parameter 1 is not of type 'Function'.")
	}
	data := [3]wj.JSValue{argv[0], wj.arg(argc, argv, 1), this_val}
	each := wj.JS_NewCFunctionData(ctx, fonts_each, 3, 0, 3, &data[0])
	if wj.is_exception(each) { return each }
	r := fonts_call(ctx, this_val, "forEach", ([^]wj.JSValue)(&each)[:1])
	wj.JS_FreeValue(ctx, each)
	if wj.is_exception(r) { return r }
	wj.JS_FreeValue(ctx, r)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_FontFaceSet_check")
wjr_FontFaceSet_check :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "FontFaceSet.check", 1, argc) }
	return wj.TRUE
}

@(export, link_name = "wjr_FontFaceSet_load")
wjr_FontFaceSet_load :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.web_promise_reject_pending(ctx) }
	if argc < 1 { wj.wj_throw_arity(ctx, "FontFaceSet.load", 1, argc); return wj.web_promise_reject_pending(ctx) }
	none := wj.JS_NewArray(ctx)
	return wj.is_exception(none) ? wj.web_promise_reject_pending(ctx) : wj.web_promise_take(ctx, none)
}

@(export, link_name = "wjr_FontFaceSet_get_ready")
wjr_FontFaceSet_get_ready :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.EXCEPTION }
	p := wj.web_extra_get(ctx, this_val, "ready")
	if !wj.is_undefined(p) { return p }
	p = wj.web_promise_resolved(ctx, this_val)
	if wj.is_exception(p) { return p }
	if !wj.web_extra_set(ctx, this_val, "ready", wj.JS_DupValue(ctx, p)) { wj.JS_FreeValue(ctx, p); return wj.EXCEPTION }
	return p
}

@(export, link_name = "wjr_FontFaceSet_get_status")
wjr_FontFaceSet_get_status :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if !fonts_this(ctx, this_val) { return wj.EXCEPTION }
	return wj.new_string(ctx, "loaded")
}

// ---- Element.scrollIntoViewIfNeeded (WebKit) ----

// scrollIntoView when the element is not fully in the viewport: centered, or the nearest edge when the argument is false
@(private = "file")
scroll_into_view_if_needed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	o := wj.wj_this(ctx, this_val, iface_lazy(&if_element, "Element"))
	if o == nil { return wj.EXCEPTION }
	r: wj.wr_DomRect
	wj.wr_Element_boundingRect(o.handle, &r)   // (a struct result: outside the comptime bridge)
	root: u64
	jsb.host(&root, api_decl.Document_documentElement, wj.wr_Document_documentElement)
	cw, ch: i32
	if root != 0 {
		jsb.host(&cw, api_decl.Element_clientWidth, wj.wr_Element_clientWidth, root)
		jsb.host(&ch, api_decl.Element_clientHeight, wj.wr_Element_clientHeight, root)
	}
	width, height := f64(cw), f64(ch)
	left, right := r.width < 0 ? r.x + r.width : r.x, r.width < 0 ? r.x : r.x + r.width
	top, bottom := r.height < 0 ? r.y + r.height : r.y, r.height < 0 ? r.y : r.y + r.height
	inside := top >= 0 && left >= 0 && bottom <= height && right <= width
	if !inside {
		nearest := argc > 0 && wj.is_bool(argv[0]) && wj.JS_ToBool(ctx, argv[0]) == 0
		jsb.host(&nothing, api_decl.Element_scrollIntoViewAt, wj.wr_Element_scrollIntoViewAt, o.handle, i32(nearest ? 3 : 1), i32(3))
	}
	return wj.UNDEFINED
}

// ---- the Fullscreen API under WebKit's names ----

@(private = "file")
ignore_rejection :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.UNDEFINED }

// p.catch(() => {}) so that a rejection stays unreported
@(private = "file")
swallow_rejection :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue) {
	if !wj.is_object(p) { return }
	swallow := wj.new_cfunction(ctx, ignore_rejection, "", 1)
	r := wj.invoke(ctx, p, "catch", ([^]wj.JSValue)(&swallow)[:1])
	free_values(ctx, swallow, r)
}

// data[0]: the standard method; the prefixed one returns nothing and leaves a rejection unreported
@(private = "file")
webkit_quiet :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	p := wj.JS_Call(ctx, data[0], this_val, argc > 0 ? 1 : 0, argv)
	if wj.is_exception(p) { return p }
	swallow_rejection(ctx, p)
	wj.JS_FreeValue(ctx, p)
	return wj.UNDEFINED
}

// data[0]: the name of the standard attribute
@(private = "file")
webkit_alias :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	a := wj.JS_ValueToAtom(ctx, data[0])
	v := wj.JS_GetProperty(ctx, this_val, a)
	wj.JS_FreeAtom(ctx, a)
	return v
}

// onwebkitfullscreenchange / onwebkitfullscreenerror: magic bit 0 the error one, bit 1 on Element (else Document)
@(private = "file")
webkit_handler :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	iface := magic & 2 != 0 ? iface_lazy(&if_element, "Element") : iface_lazy(&if_document, "Document")
	type: cstring = magic & 1 != 0 ? "webkitfullscreenerror" : "webkitfullscreenchange"
	if argc > 0 { return wj.wj_event_handler_set(ctx, this_val, iface, type, argv[0], 0) }
	return wj.wj_event_handler_get(ctx, this_val, iface, type)
}

@(private = "file")
define_webkit_fullscreen :: proc "contextless" (ctx: ^wj.Context) {
	element, document := wj.realm_proto(iface_lazy(&if_element, "Element")), wj.realm_proto(iface_lazy(&if_document, "Document"))
	if !wj.is_object(element) || !wj.is_object(document) { return }
	request := wj.JS_GetPropertyStr(ctx, element, "requestFullscreen")
	exit := wj.JS_GetPropertyStr(ctx, document, "exitFullscreen")
	defer free_values(ctx, request, exit)
	if !wj.JS_IsFunction(ctx, request) || !wj.JS_IsFunction(ctx, exit) { return }
	REQUESTS :: [2]cstring{"webkitRequestFullscreen", "webkitRequestFullScreen"}
	EXITS :: [2]cstring{"webkitExitFullscreen", "webkitCancelFullScreen"}
	requests, exits := REQUESTS, EXITS
	for i in 0 ..< 2 {
		wj.JS_DefinePropertyValueStr(ctx, element, requests[i], wj.JS_NewCFunctionData(ctx, webkit_quiet, 1, 0, 1, &request), HIDDEN)
		wj.JS_DefinePropertyValueStr(ctx, document, exits[i], wj.JS_NewCFunctionData(ctx, webkit_quiet, 0, 0, 1, &exit), HIDDEN)
	}
	ALIASES :: [4][2]cstring{
		{"webkitFullscreenElement", "fullscreenElement"}, {"webkitCurrentFullScreenElement", "fullscreenElement"},
		{"webkitFullscreenEnabled", "fullscreenEnabled"}, {"webkitIsFullScreen", "fullscreen"},
	}
	aliases := ALIASES
	for alias in aliases {
		target := wj.new_string(ctx, alias[1])
		name := wj.JS_NewAtom(ctx, alias[0])
		wj.JS_DefinePropertyGetSet(ctx, document, name, wj.JS_NewCFunctionData(ctx, webkit_alias, 0, 0, 1, &target), wj.UNDEFINED, wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
		wj.JS_FreeAtom(ctx, name)
		wj.JS_FreeValue(ctx, target)
	}
	HANDLERS :: [2]cstring{"onwebkitfullscreenchange", "onwebkitfullscreenerror"}
	handlers := HANDLERS
	for on_element in 0 ..< 2 {
		for h in 0 ..< 2 {
			magic := i32(h) | (on_element != 0 ? 2 : 0)
			name := wj.JS_NewAtom(ctx, handlers[h])
			wj.JS_DefinePropertyGetSet(ctx, on_element != 0 ? element : document, name,
				wj.JS_NewCFunctionData(ctx, webkit_handler, 0, magic, 0, nil),
				wj.JS_NewCFunctionData(ctx, webkit_handler, 1, magic, 0, nil), wj.PROP_CONFIGURABLE | wj.PROP_ENUMERABLE)
			wj.JS_FreeAtom(ctx, name)
		}
	}
}

// ---- document.execCommand("copy" / "cut"), queryCommandSupported / queryCommandEnabled ----
// The clipboard fallback of pages: glue between the page's selection and navigator.clipboard, both read through their
// JavaScript objects (the DOM accessors are native; this calls them).

// The text of the current selection: an input / textarea with a non-empty selection (that control in *control,
// counted), else the document's Selection as a string (control undefined).
@(private = "file")
selected_text :: proc(ctx: ^wj.Context, text: ^[dynamic]u8, control: ^wj.JSValue) {
	control^ = wj.UNDEFINED
	document := wj.global_get(ctx, "document")
	active := wj.JS_GetPropertyStr(ctx, document, "activeElement")
	wj.JS_FreeValue(ctx, document)
	defer wj.JS_FreeValue(ctx, active)
	if wj.is_object(active) {
		lnv := wj.JS_GetPropertyStr(ctx, active, "localName")
		lc, ln := to_text(ctx, lnv)
		is_field := lc != nil && (ln == "input" || ln == "textarea")
		if lc != nil { wj.free_cstring(ctx, lc) }
		wj.JS_FreeValue(ctx, lnv)
		if is_field {
			ss := wj.JS_GetPropertyStr(ctx, active, "selectionStart")
			se := wj.JS_GetPropertyStr(ctx, active, "selectionEnd")
			defer free_values(ctx, ss, se)
			if wj.is_number(ss) {
				start, end: i64
				wj.JS_ToInt64(ctx, &start, ss)
				wj.JS_ToInt64(ctx, &end, se)
				if start != end {
					value := wj.JS_GetPropertyStr(ctx, active, "value")
					bounds := [2]wj.JSValue{ss, se}
					sub := wj.invoke(ctx, value, "substring", bounds[:])
					wj.JS_FreeValue(ctx, value)
					sc, s := to_text(ctx, sub)
					if sc != nil { append(text, s); wj.free_cstring(ctx, sc) }
					wj.JS_FreeValue(ctx, sub)
					control^ = wj.JS_DupValue(ctx, active)
					return
				}
			}
		}
	}
	// globalThis.getSelection() as a string
	getsel := wj.global_get(ctx, "getSelection")
	defer wj.JS_FreeValue(ctx, getsel)
	if !wj.JS_IsFunction(ctx, getsel) { return }
	sel := wj.JS_Call(ctx, getsel, wj.realm_global(), 0, nil)
	defer wj.JS_FreeValue(ctx, sel)
	if !wj.is_object(sel) { return }
	s := wj.JS_ToString(ctx, sel)
	sc, str := to_text(ctx, s)
	if sc != nil { append(text, str); wj.free_cstring(ctx, sc) }
	wj.JS_FreeValue(ctx, s)
}

@(private = "file")
Command :: enum { Unknown, Copy, Cut }

// "copy" / "cut", ASCII case-insensitively
@(private = "file")
command_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> Command {
	c, s := to_text(ctx, v)
	if c == nil { return .Unknown }
	defer wj.free_cstring(ctx, c)
	lower: [16]u8
	if len(s) > len(lower) - 1 { return .Unknown }
	for ch, i in transmute([]u8)s { lower[i] = ch >= 'A' && ch <= 'Z' ? ch + 32 : ch }
	switch string(lower[:len(s)]) {
	case "copy": return .Copy
	case "cut":  return .Cut
	}
	return .Unknown
}

@(private = "file")
exec_command :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if argc < 1 { return wj.FALSE }
	cmd := command_of(ctx, argv[0])
	if cmd == .Unknown { return wj.FALSE }
	text: [dynamic]u8
	defer delete(text)
	control: wj.JSValue
	selected_text(ctx, &text, &control)
	defer wj.JS_FreeValue(ctx, control)
	if len(text) == 0 { return wj.FALSE }
	navigator := wj.global_get(ctx, "navigator")
	clipboard := wj.JS_GetPropertyStr(ctx, navigator, "clipboard")
	wj.JS_FreeValue(ctx, navigator)
	defer wj.JS_FreeValue(ctx, clipboard)
	if !wj.is_object(clipboard) { return wj.FALSE }
	a := wj.new_string_len(ctx, text[:])
	p := wj.invoke(ctx, clipboard, "writeText", ([^]wj.JSValue)(&a)[:1])
	wj.JS_FreeValue(ctx, a)
	swallow_rejection(ctx, p)   // (like the JavaScript did)
	wj.JS_FreeValue(ctx, p)
	if cmd == .Cut && wj.is_object(control) {
		ro := wj.JS_GetPropertyStr(ctx, control, "readOnly")
		dis := wj.JS_GetPropertyStr(ctx, control, "disabled")
		editable := wj.JS_ToBool(ctx, ro) <= 0 && wj.JS_ToBool(ctx, dis) <= 0
		free_values(ctx, ro, dis)
		if editable {
			empty := wj.new_string(ctx, "")
			r := wj.invoke(ctx, control, "setRangeText", ([^]wj.JSValue)(&empty)[:1])
			free_values(ctx, empty, r)
		}
	}
	return wj.TRUE
}

@(private = "file")
query_supported :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(argc >= 1 && command_of(ctx, argv[0]) != .Unknown)
}

@(private = "file")
query_enabled :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if argc < 1 || command_of(ctx, argv[0]) == .Unknown { return wj.FALSE }
	text: [dynamic]u8
	control: wj.JSValue
	selected_text(ctx, &text, &control)
	wj.JS_FreeValue(ctx, control)
	defer delete(text)
	return wj.new_bool(len(text) != 0)
}

@(private = "file")
install_exec_command :: proc "contextless" (ctx: ^wj.Context) {
	document := wj.realm_proto(iface_lazy(&if_document, "Document"))
	if !wj.is_object(document) { return }
	wj.JS_DefinePropertyValueStr(ctx, document, "execCommand", wj.new_cfunction(ctx, exec_command, "execCommand", 3), HIDDEN)
	wj.JS_DefinePropertyValueStr(ctx, document, "queryCommandSupported", wj.new_cfunction(ctx, query_supported, "queryCommandSupported", 1), HIDDEN)
	wj.JS_DefinePropertyValueStr(ctx, document, "queryCommandEnabled", wj.new_cfunction(ctx, query_enabled, "queryCommandEnabled", 1), HIDDEN)
}

// ---- life cycle ----

@(export, link_name = "web_compat_preinit")
web_compat_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	// a FontFaceSet is iterable: @@iterator is values() (Web IDL setlike)
	if fonts := wj.realm_proto(iface_lazy(&if_font_face_set, "FontFaceSet")); wj.is_object(fonts) {
		sym := wj.global_get(ctx, "Symbol")
		iter := wj.JS_GetPropertyStr(ctx, sym, "iterator")
		atom := wj.JS_ValueToAtom(ctx, iter)
		values := wj.JS_GetPropertyStr(ctx, fonts, "values")
		if wj.JS_IsFunction(ctx, values) { wj.JS_DefinePropertyValue(ctx, fonts, atom, values, HIDDEN) } else { wj.JS_FreeValue(ctx, values) }
		wj.JS_FreeAtom(ctx, atom)
		free_values(ctx, iter, sym)
	}
	if element := wj.realm_proto(iface_lazy(&if_element, "Element")); wj.is_object(element) {
		wj.JS_DefinePropertyValueStr(ctx, element, "scrollIntoViewIfNeeded", wj.new_cfunction(ctx, scroll_into_view_if_needed, "scrollIntoViewIfNeeded", 1), HIDDEN)
	}
	define_webkit_fullscreen(ctx)
	install_exec_command(ctx)
	return 0
}

@(export, link_name = "web_compat_start")
web_compat_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	if !wj.is_window() { return 0 }
	// the console description for the developer tools (web_devtools.odin)
	wj_devtools_install(ctx)
	return 0
}
