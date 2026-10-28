// frames.odin: other windows (HTML "nested navigables", "WindowProxy"), on top of module frames (api/frames.widl).
// Ported from native/js/runtime/frames.c; same wjr_* and wj_* symbols.
//
// Each document runs in its own engine instance: a window of another document cannot be an object of this realm. It is
// a WindowProxy exotic object (Class_Exotic_Methods), named by the navigable's id, that reaches only what HTML lets a
// cross-origin window reach (postMessage, location as a setter, closed, frames, length, top, parent, opener, window,
// self, close, focus, blur, indexed and named child frames), whatever the origins: two documents never share objects. A
// same-origin frame also yields this realm's own ECMAScript built-ins and the platform's interface objects / functions
// (for a pristine copy), never the frame's state. Here: those exotic objects and their cache, the Window and
// HTMLIFrameElement members that return windows, and the delivery of messages posted by other documents
// (wj_frames_message).
//
// The calls into the browser are the declarations of api_decl/frames.odin, through jsb.host.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") Navigable :: api_decl.Navigable

@(private = "file") wp_class, xo_loc_class: wj.Class_ID    // the WindowProxy; the cross-origin Location
@(private = "file") wp_exotic, xo_loc_exotic: wj.Class_Exotic_Methods
@(private = "file") wp_def, xo_loc_def: wj.Class_Def
@(private = "file") wp_cache: map[Navigable]wj.JSValue       // id -> WindowProxy (counted), the same object each time
@(private = "file") wp_ready: bool
@(private = "file") wp_self_id: Navigable
@(private = "file") none: abi.Nothing

// The state of a WindowProxy: the navigable, and the objects made on first use.
@(private = "file")
Window_State :: struct {
	id:       Navigable,
	location: wj.JSValue,   // the cross-origin Location (counted)
	history:  wj.JSValue,   // an object with History.prototype and no brand (counted)
}

// The state of the cross-origin Location.
@(private = "file")
Location_State :: struct {
	id: Navigable,
}

// The names the WindowProxy owns.
@(private = "file")
WP_MEMBERS := [?]string{"window", "self", "location", "close", "closed", "focus", "blur", "frames", "length", "top",
	"opener", "parent", "postMessage"}

// Stateless window functions given pristine from a same-origin frame (bound to this global).
@(private = "file")
WP_FUNCTIONS := [?]string{"fetch", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "requestAnimationFrame",
	"cancelAnimationFrame", "requestIdleCallback", "cancelIdleCallback", "queueMicrotask", "structuredClone", "atob",
	"btoa", "getComputedStyle", "matchMedia", "reportError", "createImageBitmap", "addEventListener",
	"removeEventListener", "dispatchEvent"}

@(private = "file")
WP_BUILTINS := [?]string{"JSON", "Math", "Reflect", "Intl", "Object", "Function", "Array", "String", "Number", "Boolean",
	"Symbol", "BigInt", "Date", "RegExp", "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
	"EvalError", "URIError", "AggregateError", "Map", "Set", "WeakMap", "WeakSet", "WeakRef", "Promise", "Proxy",
	"ArrayBuffer", "DataView", "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
	"Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array", "parseInt",
	"parseFloat", "isNaN", "isFinite", "encodeURI", "encodeURIComponent", "decodeURI", "decodeURIComponent", "escape",
	"unescape", "NaN", "Infinity", "undefined"}

@(private = "file")
in_list :: proc "contextless" (list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

// ---- the browser's side (api_decl/frames.odin) ----

// 0 when the realm has no frames.* imports (the engine run alone, not by a page): nothing is a frame there.
@(private = "file")
self_id :: proc "contextless" () -> Navigable {
	if !wj.wj_start_frames { return 0 }
	if wp_self_id == 0 {
		context = m4_context()
		jsb.host(&wp_self_id, api_decl.Frame_self, wj.wr_Frame_self)
	}
	return wp_self_id
}

@(private = "file")
frame_nav :: proc "contextless" ($D: typeid, imp: $R, id: Navigable) -> (r: Navigable) {
	context = m4_context()
	jsb.host(&r, D, imp, id)
	return
}

@(private = "file")
frame_top :: proc "contextless" (id: Navigable) -> Navigable { return frame_nav(api_decl.Frame_top, wj.wr_Frame_top, id) }
@(private = "file")
frame_parent :: proc "contextless" (id: Navigable) -> Navigable { return frame_nav(api_decl.Frame_parent, wj.wr_Frame_parent, id) }

@(private = "file")
frame_length :: proc "contextless" (id: Navigable) -> (n: u32) {
	context = m4_context()
	jsb.host(&n, api_decl.Frame_length, wj.wr_Frame_length, id)
	return
}

@(private = "file")
frame_closed :: proc "contextless" (id: Navigable) -> (closed: bool) {
	context = m4_context()
	jsb.host(&closed, api_decl.Frame_closed, wj.wr_Frame_closed, id)
	return
}

@(private = "file")
frame_same_origin :: proc "contextless" (id: Navigable) -> (same: bool) {
	context = m4_context()
	jsb.host(&same, api_decl.Frame_sameOrigin, wj.wr_Frame_sameOrigin, id)
	return
}

// The child at `index` or named `name` (0: none).
@(private = "file")
frame_child :: proc "contextless" (id: Navigable, name: string) -> (child: Navigable) {
	context = m4_context()
	if is_index_string(name) {
		// strtoul, as the C parsed it: clamped to the largest 32-bit value
		index: u64
		for c in transmute([]u8)name { index = min(index * 10 + u64(c - '0'), u64(max(u32))) }
		jsb.host(&child, api_decl.Frame_child, wj.wr_Frame_child, id, u32(index))
	} else {
		jsb.host(&child, api_decl.Frame_named, wj.wr_Frame_named, id, name)
	}
	return
}

// ---- JavaScript helpers ----

@(private = "file")
global_prop :: #force_inline proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	return wj.JS_GetPropertyStr(ctx, wj.realm_global(), name)
}

// The UTF-8 of a property name that is a string (nil, "" for a symbol); the cstring is freed by the caller.
@(private = "file")
prop_name :: proc "contextless" (ctx: ^wj.Context, prop: wj.Atom) -> (c: cstring, s: string) {
	v := wj.JS_AtomToValue(ctx, prop)
	defer wj.JS_FreeValue(ctx, v)
	if !wj.is_string(v) { return nil, "" }
	n: uint
	c = wj.JS_ToCStringLen(ctx, &n, v)
	if c == nil { return nil, "" }
	return c, string(([^]u8)(rawptr(c))[:n])
}

// The names a cross-origin object quietly answers undefined for: then, @@toStringTag, @@hasInstance,
// @@isConcatSpreadable.
@(private = "file")
is_fallback :: proc "contextless" (ctx: ^wj.Context, prop: wj.Atom) -> bool {
	v := wj.JS_AtomToValue(ctx, prop)
	defer wj.JS_FreeValue(ctx, v)
	if wj.is_string(v) { return js_str_is(ctx, v, "then") }
	// a well-known symbol: compared against Symbol.toStringTag / hasInstance / isConcatSpreadable
	sym := global_prop(ctx, "Symbol")
	defer wj.JS_FreeValue(ctx, sym)
	for name in ([?]cstring{"toStringTag", "hasInstance", "isConcatSpreadable"}) {
		ws := wj.JS_GetPropertyStr(ctx, sym, name)
		wa := wj.JS_ValueToAtom(ctx, ws)
		same := wa == prop
		wj.JS_FreeAtom(ctx, wa)
		wj.JS_FreeValue(ctx, ws)
		if same { return true }
	}
	return false
}

// A descriptor of a data property: configurable, plus `flags`.
@(private = "file")
fill_desc :: proc "contextless" (desc: ^wj.Property_Descriptor, flags: i32, value: wj.JSValue) {
	if desc == nil { return }
	desc^ = {flags = flags, value = value, getter = wj.UNDEFINED, setter = wj.UNDEFINED}
}

// A function named `name`, not enumerable or writable.
@(private = "file")
name_function :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, name: cstring) {
	wj.JS_DefinePropertyValueStr(ctx, fn, "name", wj.new_string(ctx, name), wj.PROP_CONFIGURABLE)
}

// ---- the SecurityError thrown for an out-of-reach name ----

@(private = "file")
security_error_value :: proc "contextless" (ctx: ^wj.Context, prop: wj.Atom) -> wj.JSValue {
	origin: [256]u8
	copy(origin[:], "null")
	loc := global_prop(ctx, "location")
	if wj.is_object(loc) {
		o := wj.JS_GetPropertyStr(ctx, loc, "origin")
		if wj.is_string(o) {
			if s := wj.JS_ToCString(ctx, o); s != nil {
				wj.snprintf(&origin[0], len(origin), "%s", s)
				wj.JS_FreeCString(ctx, s)
			}
		}
		wj.JS_FreeValue(ctx, o)
	} else if wj.is_exception(loc) {
		wj.drop_exception(ctx)
	}
	wj.JS_FreeValue(ctx, loc)
	what: [128]u8
	pv := wj.JS_AtomToValue(ctx, prop)
	if wj.is_string(pv) {
		s := wj.JS_ToCString(ctx, pv)
		wj.snprintf(&what[0], len(what), "'%s'", s != nil ? s : cstring(""))
		if s != nil { wj.JS_FreeCString(ctx, s) }
	} else {
		sv := wj.JS_ToString(ctx, pv)   // a Symbol throws: the SecurityError replaces that exception below
		s := wj.JS_ToCString(ctx, sv)
		wj.snprintf(&what[0], len(what), "%s", s != nil ? s : cstring("a symbol"))
		if s != nil { wj.JS_FreeCString(ctx, s) }
		wj.JS_FreeValue(ctx, sv)
	}
	wj.JS_FreeValue(ctx, pv)
	msg: [512]u8
	wj.snprintf(&msg[0], len(msg), "Blocked a frame with origin \"%s\" from accessing %s of another window: the documents of other frames are reachable through postMessage only.", cstring(&origin[0]), cstring(&what[0]))
	return wj.web_dom_exception(ctx, "SecurityError", cstring(&msg[0]))
}

@(private = "file")
throw_security :: proc "contextless" (ctx: ^wj.Context, prop: wj.Atom) -> wj.JSValue {
	return wj.JS_Throw(ctx, security_error_value(ctx, prop))
}

// ---- the cross-origin Location ----

@(private = "file")
xo_loc_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	wj.libc_free(wj.JS_GetOpaque(val, xo_loc_class))
}

@(private = "file")
xo_loc_new :: proc "contextless" (ctx: ^wj.Context, id: Navigable) -> wj.JSValue {
	obj := wj.JS_NewObjectClass(ctx, xo_loc_class)
	if wj.is_exception(obj) { return obj }
	l := (^Location_State)(wj.libc_calloc(1, size_of(Location_State)))
	if l == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	l.id = id
	wj.JS_SetOpaque(obj, l)
	wj.JS_SetPrototype(ctx, obj, wj.NULL)
	return obj
}

// Navigates `id` to the URL `v`: false with the exception pending (location = "not a url" throws, as the host's answer
// says).
@(private = "file")
navigate :: proc "contextless" (ctx: ^wj.Context, id: Navigable, v: wj.JSValue, replace: bool) -> bool {
	context = m4_context()
	u: wj.Str
	if !wj.wj_to_str(ctx, v, &u, wj.STR_USV, "") { return false }
	defer wj.wj_str_free(ctx, &u)
	if st := jsb.host(&none, api_decl.Frame_navigate, wj.wr_Frame_navigate, id, str_view(u), replace); st != .None {
		wj.wj_throw_status(ctx, i32(st), "location")
		return false
	}
	return true
}

@(private = "file")
xo_loc_replace_fn :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	if !navigate(ctx, Navigable(data_handle(data)), wj.arg(argc, argv, 0), true) { return wj.EXCEPTION }
	return wj.UNDEFINED
}

@(private = "file")
xo_loc_replace :: proc "contextless" (ctx: ^wj.Context, id: Navigable) -> wj.JSValue {
	data := handle_data(u64(id))
	fn := wj.JS_NewCFunctionData(ctx, xo_loc_replace_fn, 1, 0, 2, &data[0])
	name_function(ctx, fn, "replace")
	return fn
}

@(private = "file")
xo_loc_id :: #force_inline proc "contextless" (obj: wj.JSValue) -> Navigable {
	l := (^Location_State)(wj.JS_GetOpaque(obj, xo_loc_class))
	return l != nil ? l.id : 0
}

@(private = "file")
xo_loc_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, receiver: wj.JSValue) -> wj.JSValue {
	if atom_is(ctx, prop, "replace") { return xo_loc_replace(ctx, xo_loc_id(obj)) }
	if is_fallback(ctx, prop) { return wj.UNDEFINED }
	return throw_security(ctx, prop)
}

@(private = "file")
xo_loc_set :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, value, receiver: wj.JSValue, flags: i32) -> i32 {
	if atom_is(ctx, prop, "href") { return navigate(ctx, xo_loc_id(obj), value, false) ? 1 : -1 }
	throw_security(ctx, prop)
	return -1
}

@(private = "file")
xo_loc_has :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	return atom_is(ctx, prop, "href") || atom_is(ctx, prop, "replace") || is_fallback(ctx, prop) ? 1 : 0
}

@(private = "file")
xo_loc_get_own :: proc "c" (ctx: ^wj.Context, desc: ^wj.Property_Descriptor, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	if atom_is(ctx, prop, "replace") {
		if desc != nil { fill_desc(desc, wj.PROP_CONFIGURABLE, xo_loc_replace(ctx, xo_loc_id(obj))) }
		return 1
	}
	if atom_is(ctx, prop, "href") {
		fill_desc(desc, wj.PROP_CONFIGURABLE | wj.PROP_HAS_SET | wj.PROP_HAS_GET, wj.UNDEFINED)
		return 1
	}
	if is_fallback(ctx, prop) {
		fill_desc(desc, wj.PROP_CONFIGURABLE, wj.UNDEFINED)
		return 1
	}
	throw_security(ctx, prop)
	return -1
}

@(private = "file")
xo_loc_names :: proc "c" (ctx: ^wj.Context, ptab: ^[^]wj.Property_Enum, plen: ^u32, obj: wj.JSValue) -> i32 {
	names := [?]cstring{"href", "replace"}
	tab := ([^]wj.Property_Enum)(wj.js_malloc(ctx, size_of(wj.Property_Enum) * len(names)))
	if tab == nil { return -1 }
	for name, i in names { tab[i] = {is_enumerable = false, atom = wj.JS_NewAtom(ctx, name)} }
	ptab^ = tab
	plen^ = len(names)
	return 0
}

@(private = "file")
xo_loc_define :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, val, getter, setter: wj.JSValue, flags: i32) -> i32 {
	throw_security(ctx, prop)
	return -1
}

@(private = "file")
xo_loc_delete :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	throw_security(ctx, prop)
	return -1
}

// ---- the WindowProxy ----

@(private = "file")
wp_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	w := (^Window_State)(wj.JS_GetOpaque(val, wp_class))
	if w == nil { return }
	wj.JS_FreeValueRT(rt, w.location)
	wj.JS_FreeValueRT(rt, w.history)
	wj.libc_free(w)
}

@(private = "file")
wp_mark :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue, mark: wj.Mark_Func) {
	w := (^Window_State)(wj.JS_GetOpaque(val, wp_class))
	if w == nil { return }
	wj.JS_MarkValue(rt, w.location, mark)
	wj.JS_MarkValue(rt, w.history, mark)
}

@(private = "file")
state_of :: #force_inline proc "contextless" (obj: wj.JSValue) -> ^Window_State {
	return (^Window_State)(wj.JS_GetOpaque(obj, wp_class))
}

// The child frame named / indexed `name` of navigable `id` as a window; UNINITIALIZED for none.
@(private = "file")
wp_child :: proc "contextless" (ctx: ^wj.Context, id: Navigable, name: string) -> wj.JSValue {
	if !wj.wj_start_frames { return wj.UNINITIALIZED }
	c := frame_child(id, name)
	return c != 0 ? window_of(ctx, c) : wj.UNINITIALIZED
}

// "native function": its source ends with [native code] }
@(private = "file")
native_function :: proc "contextless" (ctx: ^wj.Context, f: wj.JSValue) -> bool {
	if !wj.JS_IsFunction(ctx, f) { return false }
	fp := global_prop(ctx, "Function")
	fproto := wj.JS_GetPropertyStr(ctx, fp, "prototype")
	to_string := wj.JS_GetPropertyStr(ctx, fproto, "toString")
	src := wj.JS_Call(ctx, to_string, f, 0, nil)
	wj.free_values(ctx, to_string, fproto, fp)
	defer wj.JS_FreeValue(ctx, src)
	if wj.is_exception(src) { wj.drop_exception(ctx); return false }
	c, s := to_text(ctx, src)
	if c == nil { return false }
	defer wj.JS_FreeCString(ctx, c)
	m := wj.index_of(raw_data(s), len(s), "[native code]")
	if m < 0 { return false }
	for ch in transmute([]u8)s[m:] { if ch == '}' { return true } }
	return false
}

// A stateless window function bound to this global (pristine copy), or UNINITIALIZED.
@(private = "file")
pristine_function :: proc "contextless" (ctx: ^wj.Context, name: cstring) -> wj.JSValue {
	v := global_prop(ctx, name)
	if native_function(ctx, v) {
		bind := wj.JS_GetPropertyStr(ctx, v, "bind")
		g := wj.realm_global()
		bound := wj.JS_Call(ctx, bind, v, 1, &g)
		wj.free_values(ctx, bind, v)
		return bound
	}
	wj.JS_FreeValue(ctx, v)
	return wj.UNINITIALIZED
}

// A member value (window/self/.../postMessage) or UNINITIALIZED.
@(private = "file")
wp_member :: proc "contextless" (ctx: ^wj.Context, self: wj.JSValue, w: ^Window_State, p: string) -> wj.JSValue {
	id := w.id
	switch p {
	case "window", "self", "frames":
		return wj.JS_DupValue(ctx, self)
	case "location":
		if wj.is_undefined(w.location) { w.location = xo_loc_new(ctx, id) }
		return wj.JS_DupValue(ctx, w.location)
	case "closed":
		return wj.new_bool(frame_closed(id))
	case "length":
		return wj.new_uint32(ctx, frame_length(id))
	case "top":
		t := frame_top(id)
		return t != 0 ? window_of(ctx, t) : wj.NULL
	case "parent":
		q := frame_parent(id)
		return q != 0 ? window_of(ctx, q) : wj.JS_DupValue(ctx, self)
	case "opener":
		return wj.NULL
	case "postMessage":
		return wp_postmessage_fn(ctx, id)
	case "close", "focus", "blur":
		// an empty function (the old fns.close/focus/blur)
		empty := "(function(){})"
		f := wj.JS_Eval(ctx, raw_data(empty), uint(len(empty)), "<frames>", wj.EVAL_TYPE_GLOBAL)
		name_function(ctx, f, p == "close" ? "close" : p == "focus" ? "focus" : "blur")
		return f
	}
	return wj.UNINITIALIZED
}

// A same-origin frame's ECMAScript built-in (this realm's own), or UNINITIALIZED.
@(private = "file")
wp_builtin :: proc "contextless" (ctx: ^wj.Context, id: Navigable, c: cstring, p: string) -> wj.JSValue {
	if !in_list(WP_BUILTINS[:], p) || !frame_same_origin(id) { return wj.UNINITIALIZED }
	return global_prop(ctx, c)
}

// Pristine platform object / function from a same-origin frame, or UNINITIALIZED. `history` is an object with
// History.prototype and no brand; console is this realm's console; functions are bound; constructors (an upper-case
// name of a native function) are given as is.
@(private = "file")
wp_pristine :: proc "contextless" (ctx: ^wj.Context, w: ^Window_State, c: cstring, p: string) -> wj.JSValue {
	if !frame_same_origin(w.id) { return wj.UNINITIALIZED }
	switch {
	case p == "history":
		if wj.is_undefined(w.history) {
			hc := global_prop(ctx, "History")
			hp := wj.JS_GetPropertyStr(ctx, hc, "prototype")
			wj.JS_FreeValue(ctx, hc)
			w.history = wj.JS_NewObjectProto(ctx, hp)
			wj.JS_FreeValue(ctx, hp)
		}
		return wj.JS_DupValue(ctx, w.history)
	case p == "console":
		return global_prop(ctx, "console")
	case in_list(WP_FUNCTIONS[:], p):
		return pristine_function(ctx, c)
	case len(p) > 0 && p[0] >= 'A' && p[0] <= 'Z':
		// Object.getOwnPropertyDescriptor(globalThis, p) !== undefined && nativeFunction(v)
		objc := global_prop(ctx, "Object")
		gopd := wj.JS_GetPropertyStr(ctx, objc, "getOwnPropertyDescriptor")
		args := [2]wj.JSValue{wj.realm_global(), wj.new_string(ctx, c)}
		desc := wj.JS_Call(ctx, gopd, objc, 2, &args[0])
		wj.free_values(ctx, args[1], gopd, objc)
		present := !wj.is_undefined(desc) && !wj.is_exception(desc)
		wj.JS_FreeValue(ctx, desc)
		if present {
			v := global_prop(ctx, c)
			if native_function(ctx, v) { return v }
			wj.JS_FreeValue(ctx, v)
		}
	}
	return wj.UNINITIALIZED
}

// The WindowProxy's [[Get]] combining member / child / builtin / pristine, as the old proxy get trap did. found is
// false when the name is none of them (the SecurityError).
@(private = "file")
wp_lookup :: proc "contextless" (ctx: ^wj.Context, self: wj.JSValue, w: ^Window_State, prop: wj.Atom) -> (v: wj.JSValue, found: bool) {
	if is_fallback(ctx, prop) { return wj.UNDEFINED, true }
	c, p := prop_name(ctx, prop)   // a member / child / builtin / pristine is only ever a string name
	if c == nil { return wj.UNINITIALIZED, false }
	defer wj.JS_FreeCString(ctx, c)
	if v = wp_member(ctx, self, w, p); !wj.is_uninitialized(v) { return v, true }
	if v = wp_child(ctx, w.id, p); !wj.is_uninitialized(v) { return v, true }
	if v = wp_builtin(ctx, w.id, c, p); !wj.is_uninitialized(v) { return v, true }
	if v = wp_pristine(ctx, w, c, p); !wj.is_uninitialized(v) { return v, true }
	return wj.UNINITIALIZED, false
}

@(private = "file")
wp_get :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, receiver: wj.JSValue) -> wj.JSValue {
	context = m4_context()
	w := state_of(obj)
	if w == nil { return wj.UNDEFINED }
	if v, found := wp_lookup(ctx, obj, w, prop); found { return v }
	return throw_security(ctx, prop)
}

@(private = "file")
wp_set :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, value, receiver: wj.JSValue, flags: i32) -> i32 {
	context = m4_context()
	if w := state_of(obj); w != nil && atom_is(ctx, prop, "location") { return navigate(ctx, w.id, value, false) ? 1 : -1 }
	throw_security(ctx, prop)
	return -1
}

@(private = "file")
wp_has :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	context = m4_context()
	w := state_of(obj)
	if w == nil { return 0 }
	if is_fallback(ctx, prop) { return 1 }
	c, p := prop_name(ctx, prop)
	if c == nil { return 0 }
	defer wj.JS_FreeCString(ctx, c)
	if in_list(WP_MEMBERS[:], p) { return 1 }
	if v := wp_child(ctx, w.id, p); !wj.is_uninitialized(v) { wj.JS_FreeValue(ctx, v); return 1 }
	if v := wp_builtin(ctx, w.id, c, p); !wj.is_uninitialized(v) { wj.JS_FreeValue(ctx, v); return 1 }
	if v := wp_pristine(ctx, w, c, p); !wj.is_uninitialized(v) { wj.JS_FreeValue(ctx, v); return 1 }
	return 0
}

@(private = "file")
wp_get_own :: proc "c" (ctx: ^wj.Context, desc: ^wj.Property_Descriptor, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	context = m4_context()
	w := state_of(obj)
	if w == nil { return 0 }
	c, p := prop_name(ctx, prop)
	defer if c != nil { wj.JS_FreeCString(ctx, c) }
	if c != nil {
		// a child frame: value, writable false, enumerable iff an index, configurable
		if child := wp_child(ctx, w.id, p); !wj.is_uninitialized(child) {
			if desc != nil { fill_desc(desc, (is_index_string(p) ? wj.PROP_ENUMERABLE : 0) | wj.PROP_CONFIGURABLE, child) } else { wj.JS_FreeValue(ctx, child) }
			return 1
		}
		switch p {
		case "postMessage", "close", "focus", "blur":
			if desc != nil { fill_desc(desc, wj.PROP_CONFIGURABLE, wp_member(ctx, obj, w, p)) }
			return 1
		}
		if in_list(WP_MEMBERS[:], p) {
			// get: () => member(p), set: undefined (location has a setter in the old code too, but as an accessor)
			if desc != nil { fill_desc(desc, wj.PROP_CONFIGURABLE, wp_member(ctx, obj, w, p)) }
			return 1
		}
	}
	if is_fallback(ctx, prop) {
		fill_desc(desc, wj.PROP_CONFIGURABLE, wj.UNDEFINED)
		return 1
	}
	if c != nil {
		v := wp_builtin(ctx, w.id, c, p)
		if wj.is_uninitialized(v) { v = wp_pristine(ctx, w, c, p) }
		if !wj.is_uninitialized(v) {
			if desc != nil { fill_desc(desc, wj.PROP_CONFIGURABLE, v) } else { wj.JS_FreeValue(ctx, v) }
			return 1
		}
	}
	throw_security(ctx, prop)
	return -1
}

// Indices, then named children not already a member, then the members, then "then" and the three symbols.
@(private = "file")
wp_names :: proc "c" (ctx: ^wj.Context, ptab: ^[^]wj.Property_Enum, plen: ^u32, obj: wj.JSValue) -> i32 {
	context = m4_context()
	w := state_of(obj)
	if w == nil {
		ptab^ = ([^]wj.Property_Enum)(wj.js_malloc(ctx, size_of(wj.Property_Enum)))
		plen^ = 0
		return ptab^ != nil ? 0 : -1
	}
	n := frame_length(w.id)
	extra: [dynamic]wj.Atom
	defer delete(extra)
	names: abi.Bytes
	jsb.host(&names, api_decl.Frame_childNames, wj.wr_Frame_childNames, w.id)
	list := ([]u8)(names)
	start := 0
	for i in 0 ..= len(list) {
		if i < len(list) && list[i] != 0 { continue }
		if i > start && !in_list(WP_MEMBERS[:], string(list[start:i])) {
			append(&extra, wj.JS_NewAtomLen(ctx, raw_data(list[start:]), uint(i - start)))
		}
		start = i + 1
	}
	total := int(n) + len(extra) + len(WP_MEMBERS) + 4   // + "then" and 3 symbols
	tab := ([^]wj.Property_Enum)(wj.js_malloc(ctx, uint(size_of(wj.Property_Enum) * total)))
	if tab == nil {
		for a in extra { wj.JS_FreeAtom(ctx, a) }
		return -1
	}
	k := 0
	for i in 0 ..< n { tab[k] = {is_enumerable = true, atom = wj.JS_NewAtomUInt32(ctx, i)}; k += 1 }
	for a in extra { tab[k] = {is_enumerable = true, atom = a}; k += 1 }
	for m in WP_MEMBERS {
		a := wj.JS_NewAtomLen(ctx, raw_data(m), uint(len(m)))
		tab[k] = {is_enumerable = false, atom = a}; k += 1
	}
	tab[k] = {is_enumerable = false, atom = wj.JS_NewAtom(ctx, "then")}; k += 1
	sym := global_prop(ctx, "Symbol")
	for name in ([?]cstring{"toStringTag", "hasInstance", "isConcatSpreadable"}) {
		ws := wj.JS_GetPropertyStr(ctx, sym, name)
		tab[k] = {is_enumerable = false, atom = wj.JS_ValueToAtom(ctx, ws)}; k += 1
		wj.JS_FreeValue(ctx, ws)
	}
	wj.JS_FreeValue(ctx, sym)
	ptab^ = tab
	plen^ = u32(k)
	return 0
}

@(private = "file")
wp_define :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom, val, getter, setter: wj.JSValue, flags: i32) -> i32 {
	throw_security(ctx, prop)
	return -1
}

@(private = "file")
wp_delete :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, prop: wj.Atom) -> i32 {
	throw_security(ctx, prop)
	return -1
}

// postMessage(message, targetOrigin, transfer) or postMessage(message, {targetOrigin, transfer}) bound to id.
@(private = "file")
wp_postmessage_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	id := Navigable(data_handle(data))
	if argc < 1 { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'postMessage' on 'Window': 1 argument required, but only 0 present.") }
	message := argv[0]
	target_origin := wj.arg(argc, argv, 1)
	to: wj.JSValue                    // always owned
	transfer := wj.UNDEFINED          // owned
	if !wj.is_null(target_origin) && wj.is_object(target_origin) {
		tov := wj.JS_GetPropertyStr(ctx, target_origin, "targetOrigin")
		to = wj.is_undefined(tov) ? wj.new_string(ctx, "/") : wj.JS_ToString(ctx, tov)
		wj.JS_FreeValue(ctx, tov)
		transfer = wj.JS_GetPropertyStr(ctx, target_origin, "transfer")
	} else if !wj.is_undefined(target_origin) {
		to = wj.JS_ToString(ctx, target_origin)
		transfer = wj.JS_DupValue(ctx, wj.arg(argc, argv, 2))
	} else {
		to = wj.new_string(ctx, "/")
	}
	defer wj.JS_FreeValue(ctx, transfer)
	defer wj.JS_FreeValue(ctx, to)
	tostr: wj.Str
	if !wj.wj_to_str(ctx, to, &tostr, wj.STR_USV, "/") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &tostr)
	n: uint
	ports := wj.UNDEFINED
	bytes := wj_clone_serialize_ports(ctx, message, transfer, &n, &ports)
	if bytes == nil { return wj.EXCEPTION }
	defer wj.libc_free(bytes)
	ends: [^]u64
	n_ends: u32
	shipped := web_ship_ports(ctx, ports, &ends, &n_ends)
	wj.JS_FreeValue(ctx, ports)
	if !shipped { return wj.EXCEPTION }
	defer wj.libc_free(ends)
	ship: []u64
	if ends != nil { ship = ends[:n_ends] }
	if st := jsb.host(&none, api_decl.Frame_postMessagePorts, wj.wr_Frame_postMessagePorts, id, abi.Bytes(bytes[:n]), str_view(tostr), ship); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "postMessage")
	}
	return wj.UNDEFINED
}

@(private = "file")
wp_postmessage_fn :: proc "contextless" (ctx: ^wj.Context, id: Navigable) -> wj.JSValue {
	data := handle_data(u64(id))
	fn := wj.JS_NewCFunctionData(ctx, wp_postmessage_call, 1, 0, 2, &data[0])
	name_function(ctx, fn, "postMessage")
	return fn
}

// A new WindowProxy for navigable `id`.
@(private = "file")
wp_new :: proc "contextless" (ctx: ^wj.Context, id: Navigable) -> wj.JSValue {
	obj := wj.JS_NewObjectClass(ctx, wp_class)
	if wj.is_exception(obj) { return obj }
	w := (^Window_State)(wj.libc_calloc(1, size_of(Window_State)))
	if w == nil { wj.JS_FreeValue(ctx, obj); return wj.JS_ThrowOutOfMemory(ctx) }
	w^ = {id = id, location = wj.UNDEFINED, history = wj.UNDEFINED}
	wj.JS_SetOpaque(obj, w)
	wj.JS_SetPrototype(ctx, obj, wj.NULL)
	return obj
}

// Drops the proxies of closed navigables.
@(private = "file")
cache_prune :: proc "contextless" (ctx: ^wj.Context) {
	context = m4_context()
	closed: [dynamic]Navigable
	defer delete(closed)
	for id in wp_cache { if frame_closed(id) { append(&closed, id) } }
	for id in closed {
		wj.JS_FreeValue(ctx, wp_cache[id])
		delete_key(&wp_cache, id)
	}
}

// The window of navigable `id` in this realm: the global itself, a WindowProxy, or null (0: none).
@(private = "file")
window_of :: proc "contextless" (ctx: ^wj.Context, id: Navigable) -> wj.JSValue {
	context = m4_context()
	if id == 0 { return wj.NULL }
	if id == self_id() { return wj.JS_DupValue(ctx, wj.realm_global()) }
	if !wp_ready { return wj.NULL }
	if w, ok := wp_cache[id]; ok { return wj.JS_DupValue(ctx, w) }
	w := wp_new(ctx, id)
	if wj.is_exception(w) { return w }
	wp_cache[id] = wj.JS_DupValue(ctx, w)
	// pruned every 64 entries
	if len(wp_cache) % 64 == 0 { cache_prune(ctx) }
	return w
}

// Whether `v` is a WindowProxy of this realm (a message's source, MessageEvent's source member).
@(export, link_name = "wj_frames_is_window")
wj_frames_is_window :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> bool {
	return wp_ready && wj.is_object(v) && wj.JS_GetOpaque(v, wp_class) != nil
}

// The window's frame named `name` or at index `name` (the Window's named properties: shadow.odin), or undefined.
frames_lookup :: proc "contextless" (ctx: ^wj.Context, name: wj.JSValue) -> wj.JSValue {
	if !wp_ready || !wj.is_string(name) { return wj.UNDEFINED }
	me := self_id()
	if me == 0 { return wj.UNDEFINED }
	n: uint
	c := wj.JS_ToCStringLen(ctx, &n, name)
	if c == nil { return wj.UNDEFINED }
	defer wj.JS_FreeCString(ctx, c)
	w := wp_child(ctx, me, string(([^]u8)(rawptr(c))[:n]))
	return wj.is_uninitialized(w) ? wj.UNDEFINED : w
}

// Registers the classes and the cache at pre-initialization (called from the realm's preludes).
@(export, link_name = "wj_install_frames")
wj_install_frames :: proc "c" (ctx: ^wj.Context) {
	rt := wj.JS_GetRuntime(ctx)
	wj.JS_NewClassID(rt, &wp_class)
	wj.JS_NewClassID(rt, &xo_loc_class)
	xo_loc_exotic = {
		get_own_property = xo_loc_get_own, get_own_property_names = xo_loc_names, delete_property = xo_loc_delete,
		define_own_property = xo_loc_define, has_property = xo_loc_has, get_property = xo_loc_get, set_property = xo_loc_set,
	}
	wp_exotic = {
		get_own_property = wp_get_own, get_own_property_names = wp_names, delete_property = wp_delete,
		define_own_property = wp_define, has_property = wp_has, get_property = wp_get, set_property = wp_set,
	}
	xo_loc_def = {class_name = "Location", finalizer = xo_loc_finalizer, exotic = &xo_loc_exotic}
	wp_def = {class_name = "Window", finalizer = wp_finalizer, gc_mark = wp_mark, exotic = &wp_exotic}
	if wj.JS_NewClass(rt, wp_class, &wp_def) < 0 || wj.JS_NewClass(rt, xo_loc_class, &xo_loc_def) < 0 { return }
	wp_ready = true
}

// ---- Window ----

@(export, link_name = "wjr_Window_get_top")
wjr_Window_get_top :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := self_id()
	return window_of(ctx, self != 0 ? frame_top(self) : 0)
}

@(export, link_name = "wjr_Window_get_parent")
wjr_Window_get_parent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := self_id()
	p := self != 0 ? frame_parent(self) : 0
	return p != 0 ? window_of(ctx, p) : wj.JS_DupValue(ctx, wj.realm_global())
}

@(export, link_name = "wjr_Window_get_length")
wjr_Window_get_length :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	self := self_id()
	return wj.new_uint32(ctx, self != 0 ? frame_length(self) : 0)
}

// A window of another document is never reachable as an element of this one: null (as a cross-origin parent gives).
@(export, link_name = "wjr_Window_get_frameElement")
wjr_Window_get_frameElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.NULL }

@(export, link_name = "wjr_Window_get_closed")
wjr_Window_get_closed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return wj.FALSE }

// A tab's window is not script-closable (not opened by a script); focus and blur concern the browser's windows.
@(export, link_name = "wjr_Window_close")
wjr_Window_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.UNDEFINED }
@(export, link_name = "wjr_Window_focus")
wjr_Window_focus :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.UNDEFINED }
@(export, link_name = "wjr_Window_blur")
wjr_Window_blur :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return wj.UNDEFINED }

// window.open(url, target, features): a frame of this tab, or a new tab (null: no opener relationship).
@(export, link_name = "wjr_Window_open")
wjr_Window_open :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = m4_context()
	u, target: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &u, wj.STR_USV, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &u)
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &target, 0, "_blank") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &target)
	id: Navigable
	if st := jsb.host(&id, api_decl.Frame_open, wj.wr_Frame_open, str_view(u), str_view(target)); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "open")
	}
	return window_of(ctx, id)
}

// ---- frame elements ----

@(private = "file")
content_window :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> wj.JSValue {
	context = m4_context()
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	id: Navigable
	jsb.host(&id, api_decl.Frame_ofElement, wj.wr_Frame_ofElement, api_decl.Element(o.handle))
	return window_of(ctx, id)
}

@(export, link_name = "wjr_HTMLIFrameElement_get_contentWindow")
wjr_HTMLIFrameElement_get_contentWindow :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return content_window(ctx, this_val, ifc("HTMLIFrameElement"))
}
@(export, link_name = "wjr_HTMLFrameElement_get_contentWindow")
wjr_HTMLFrameElement_get_contentWindow :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return content_window(ctx, this_val, ifc("HTMLFrameElement"))
}

// The nested document is another realm's: never reachable as a Document of this one (null, as across origins).
@(export, link_name = "wjr_HTMLIFrameElement_get_contentDocument")
wjr_HTMLIFrameElement_get_contentDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, ifc("HTMLIFrameElement")) != nil ? wj.NULL : wj.EXCEPTION
}
@(export, link_name = "wjr_HTMLFrameElement_get_contentDocument")
wjr_HTMLFrameElement_get_contentDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, ifc("HTMLFrameElement")) != nil ? wj.NULL : wj.EXCEPTION
}
@(export, link_name = "wjr_HTMLIFrameElement_getSVGDocument")
wjr_HTMLIFrameElement_getSVGDocument :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, ifc("HTMLIFrameElement")) != nil ? wj.NULL : wj.EXCEPTION
}

// ---- messages from other documents ----

// The browser delivers a message another document posted to this window (src/page/frames_scripts.odin): a trusted
// "message" MessageEvent, its data deserialized here (a messageerror when it cannot be), its source the sender's
// WindowProxy (the global itself when the sender is this document).
@(export, link_name = "wj_frames_message")
wj_frames_message :: proc "c" (data, data_len, origin, origin_len, src_lo, src_hi, ends, n_ends: u32) {
	context = m4_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	src := Navigable(u64(src_lo) | u64(src_hi) << 32)
	o := make([]u8, int(origin_len) + 1, wj.libc_allocator())
	if o == nil { return }
	defer delete(o, wj.libc_allocator())
	copy(o, ([^]u8)(uintptr(origin))[:origin_len])
	list := make([]u64, int(n_ends), wj.libc_allocator())
	copy(list, ([^]u64)(uintptr(ends))[:n_ends])
	ports := web_receive_ports(ctx, raw_data(list), n_ends)
	delete(list, wj.libc_allocator())
	value := wj_clone_deserialize_ports(ctx, ([^]u8)(uintptr(data)), uint(data_len), ports)
	source := window_of(ctx, src)
	if wj.is_exception(source) { wj.drop_exception(ctx); source = wj.NULL }
	ev: wj.JSValue
	if wj.is_exception(value) {
		wj.drop_exception(ctx)
		ev = wj.web_event_new(ctx, ifc("MessageEvent"), "messageerror", false, false)
	} else {
		ev = web_message_event_ports(ctx, value, cstring(&o[0]), source, ports)
		wj.JS_FreeValue(ctx, value)
	}
	wj.free_values(ctx, ports, source)
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_event_fire(ctx, wj.realm_global(), ev)
	wj.JS_FreeValue(ctx, ev)
}
