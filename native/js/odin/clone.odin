// clone.odin: HTML's structured serialization ("StructuredSerializeWithTransfer" / "StructuredDeserializeWithTransfer"):
// structuredClone(), and the messages of workers (workers.odin), ports (web_message.odin), history states and anything
// else that sends JavaScript values between realms (wj_clone_serialize / wj_clone_deserialize, the C names the rest of
// the runtime links against). Ported from native/js/runtime/clone.c: same bytes, same errors.
//
// The serialized form is bytes (a realm cannot share its heap with another): a header ("WSC" and a version byte), then
// one tagged record per value, depth first, little-endian. Objects seen before are written as a back-reference, so
// shared and cyclic graphs come back with the same shape. Supported: primitives (BigInt included), Boolean / Number /
// String / BigInt objects, Date, RegExp, ArrayBuffer (transferred ones are detached after the whole value is
// serialized), typed arrays and DataView (with their buffer), Map, Set, Error (name, message, stack, cause), arrays
// (holes and extra properties kept), plain objects (own enumerable string keys), Blob / File, the geometry objects and
// ImageData, FileSystemHandles, and in a transfer list MessagePorts, MediaSourceHandles and VideoFrames. Functions,
// symbols and other platform objects throw DataCloneError, as in browsers.
//
// The output is a dynamic array on the libc heap (the bytes handed out are free()-able, as the C's were); the memory of
// objects already written is an Odin map keyed by the object's pointer.
//
// The brand checks and iteration use the realm's original built-ins, captured when the realm starts (a page replacing
// Map.prototype.forEach does not change what gets cloned).
package odin_glue

import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file")
Clone_Tag :: enum u8 {
	Undefined = 0, Null, False, True, Int32, Double, Big_Int, String, Ref,
	Boolean_Obj, Number_Obj, String_Obj, Big_Int_Obj, Date, Reg_Exp,
	Array_Buffer, Typed_Array, Data_View, Map, Set, Error, Array, Object,
	Port,         // a MessagePort of the transfer list: its index among the transferred ports
	Blob,         // a Blob or File: is a file, its type, its bytes, and for a File its name and lastModified
	Geom,         // DOMPoint, DOMRect, DOMMatrix (and their ReadOnly forms), ImageData: a kind, then their attributes
	Fs_Handle,    // a FileSystemHandle: its description (web_fs), restored in the receiving realm
	Mse_Handle,   // a MediaSourceHandle of the transfer list: the browser's token
	Video_Frame,  // a VideoFrame of the transfer list: the host's transfer token
}

@(private = "file") MAGIC := [4]u8{'W', 'S', 'C', 1}
// nesting allowed; recursion is also bounded by the native stack (wj_stack_exhausted)
@(private = "file") MAX_DEPTH :: 10000

@(private = "file") if_port, if_msh, if_video_frame, if_file, if_fs_handle := i32(-2), i32(-2), i32(-2), i32(-2), i32(-2)

// ---- the realm's original built-ins ----

@(private = "file")
Builtins :: struct {
	bool_value_of, number_value_of, string_value_of, bigint_value_of: wj.JSValue,   // brand checks
	map_for_each, set_for_each, dataview_buffer, dataview_offset, dataview_length, date_get_time: wj.JSValue,
	ctor_dataview, ctor_bigint, ctor_regexp, ctor_map, ctor_set, ctor_number, ctor_boolean, ctor_string, ctor_object: wj.JSValue,
}
@(private = "file") builtins: Builtins

@(private = "file")
proto_method :: proc "contextless" (ctx: ^wj.Context, ctor: cstring, name: cstring, getter: bool) -> wj.JSValue {
	c := wj.global_get(ctx, ctor)
	p := wj.JS_GetPropertyStr(ctx, c, "prototype")
	wj.JS_FreeValue(ctx, c)
	r := wj.UNDEFINED
	if getter {
		d: wj.Property_Descriptor
		a := wj.JS_NewAtom(ctx, name)
		ok := wj.JS_GetOwnProperty(ctx, &d, p, a)
		wj.JS_FreeAtom(ctx, a)
		if ok > 0 { r = d.getter; wj.JS_FreeValue(ctx, d.setter); wj.JS_FreeValue(ctx, d.value) }
	} else {
		r = wj.JS_GetPropertyStr(ctx, p, name)
	}
	wj.JS_FreeValue(ctx, p)
	return r
}

// Realm start (load.c), before any script of the page ran.
@(export, link_name = "wj_clone_start")
wj_clone_start :: proc "c" (ctx: ^wj.Context) {
	b := &builtins
	b.bool_value_of = proto_method(ctx, "Boolean", "valueOf", false)
	b.number_value_of = proto_method(ctx, "Number", "valueOf", false)
	b.string_value_of = proto_method(ctx, "String", "valueOf", false)
	b.bigint_value_of = proto_method(ctx, "BigInt", "valueOf", false)
	b.map_for_each = proto_method(ctx, "Map", "forEach", false)
	b.set_for_each = proto_method(ctx, "Set", "forEach", false)
	b.dataview_buffer = proto_method(ctx, "DataView", "buffer", true)
	b.dataview_offset = proto_method(ctx, "DataView", "byteOffset", true)
	b.dataview_length = proto_method(ctx, "DataView", "byteLength", true)
	b.date_get_time = proto_method(ctx, "Date", "getTime", false)
	b.ctor_dataview = wj.global_get(ctx, "DataView")
	b.ctor_bigint = wj.global_get(ctx, "BigInt")
	b.ctor_regexp = wj.global_get(ctx, "RegExp")
	b.ctor_map = wj.global_get(ctx, "Map")
	b.ctor_set = wj.global_get(ctx, "Set")
	b.ctor_number = wj.global_get(ctx, "Number")
	b.ctor_boolean = wj.global_get(ctx, "Boolean")
	b.ctor_string = wj.global_get(ctx, "String")
	b.ctor_object = wj.global_get(ctx, "Object")
}

// Calls a brand-checking built-in: the result, or EXCEPTION (cleared) when `v` is not of its kind.
@(private = "file")
brand :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	if !wj.JS_IsFunction(ctx, fn) { return wj.EXCEPTION }
	r := wj.JS_Call(ctx, fn, v, 0, nil)
	if wj.is_exception(r) { wj.drop_exception(ctx) }
	return r
}

// The time value of a Date (false: `v` is not one; no exception pending).
@(export, link_name = "web_date_time")
web_date_time :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, t: ^f64) -> bool {
	tv := brand(ctx, builtins.date_get_time, v)
	if wj.is_exception(tv) { return false }
	ok := wj.JS_ToFloat64(ctx, t, tv) == 0
	wj.JS_FreeValue(ctx, tv)
	return ok
}

// ---- serialization ----

@(private = "file")
Ser :: struct {
	ctx:      ^wj.Context,
	out:      [dynamic]u8,
	oom:      bool,
	seen:     map[rawptr]u32,   // object -> its reference index
	next_ref: u32,
	transfer: []wj.JSValue,     // the transfer list (counted by the caller)
	depth:    u32,
}

@(private = "file")
put :: proc(s: ^Ser, data: []u8) {
	if s.oom { return }
	if _, err := append(&s.out, ..data); err != nil { s.oom = true }
}
@(private = "file") put_u8  :: proc(s: ^Ser, v: u8) { b := [1]u8{v}; put(s, b[:]) }
@(private = "file") put_u32 :: proc(s: ^Ser, v: u32) { b := [4]u8{u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}; put(s, b[:]) }
@(private = "file") put_u64 :: proc(s: ^Ser, v: u64) { put_u32(s, u32(v)); put_u32(s, u32(v >> 32)) }
@(private = "file") put_f64 :: proc(s: ^Ser, d: f64) { put_u64(s, transmute(u64)d) }
@(private = "file") put_tag :: proc(s: ^Ser, t: Clone_Tag) { put_u8(s, u8(t)) }

@(private = "file")
put_string :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	c, text := to_text(s.ctx, v)
	if c == nil { return false }
	put_u32(s, u32(len(text)))
	put(s, transmute([]u8)text)
	wj.free_cstring(s.ctx, c)
	return true
}

@(private = "file")
clone_error :: proc "contextless" (ctx: ^wj.Context, what: cstring) -> bool {
	wj.wj_throw_dom(ctx, "DataCloneError", what)
	return false
}

@(private = "file")
remember :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	_, slot, _, err := map_entry(&s.seen, wj.value_get_ptr(v))
	if err != nil { wj.JS_ThrowOutOfMemory(s.ctx); return false }
	slot^ = s.next_ref
	s.next_ref += 1
	return true
}

@(private = "file")
listed :: proc "contextless" (s: ^Ser, v: wj.JSValue) -> bool {
	for t in s.transfer { if wj.same_ptr(t, v) { return true } }
	return false
}

// own enumerable string-keyed properties, the array indices skipped when `skip_indices`
@(private = "file")
serialize_properties :: proc(s: ^Ser, obj: wj.JSValue, skip_indices: bool) -> bool {
	ctx := s.ctx
	tab: [^]wj.Property_Enum
	n: u32
	if wj.JS_GetOwnPropertyNames(ctx, &tab, &n, obj, wj.GPN_STRING_MASK | wj.GPN_ENUM_ONLY) < 0 { return false }
	defer wj.JS_FreePropertyEnum(ctx, tab, n)
	is_index :: proc "contextless" (ctx: ^wj.Context, a: wj.Atom) -> bool { idx: u32; return wj.JS_AtomGetArrayIndex(ctx, &idx, a) }
	// counted first (properties deleted by getters meanwhile are still written: their value is undefined then)
	count: u32
	for i in 0 ..< n { if !(skip_indices && is_index(ctx, tab[i].atom)) { count += 1 } }
	put_u32(s, count)
	for i in 0 ..< n {
		a := tab[i].atom
		if skip_indices && is_index(ctx, a) { continue }
		key := wj.JS_AtomToString(ctx, a)
		ok := !wj.is_exception(key) && put_string(s, key)
		wj.JS_FreeValue(ctx, key)
		if !ok { return false }
		val := wj.JS_GetProperty(ctx, obj, a)
		if wj.is_exception(val) { return false }
		ok = serialize(s, val)
		wj.JS_FreeValue(ctx, val)
		if !ok { return false }
	}
	return true
}

// Map: (value, key) pairs pushed as key, value; Set: values (magic 1)
@(private = "file")
collect_cb :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	arr := data[0]
	n := wj.length_of(ctx, arr)
	if magic == 0 {
		wj.array_set64(ctx, arr, n, wj.JS_DupValue(ctx, wj.arg(argc, argv, 1)))
		wj.array_set64(ctx, arr, n + 1, wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)))
	} else {
		wj.array_set64(ctx, arr, n, wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)))
	}
	return wj.UNDEFINED
}

@(private = "file")
for_each_collect :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, obj: wj.JSValue, arr: wj.JSValue) -> bool {
	magic := wj.same_ptr(fn, builtins.map_for_each) ? i32(0) : i32(1)
	data := [1]wj.JSValue{arr}
	cb := wj.JS_NewCFunctionData(ctx, collect_cb, 2, magic, 1, &data[0])
	r := wj.JS_Call(ctx, fn, obj, 1, &cb)
	wj.JS_FreeValue(ctx, cb)
	if wj.is_exception(r) { return false }
	wj.JS_FreeValue(ctx, r)
	return true
}

// ---- platform objects with attributes only: DOMPoint, DOMRect, DOMMatrix (and ReadOnly), ImageData ----

@(private = "file") GEOM_NAMES := [7]cstring{"DOMPointReadOnly", "DOMPoint", "DOMRectReadOnly", "DOMRect", "DOMMatrixReadOnly", "DOMMatrix", "ImageData"}
@(private = "file") GEOM_POINT := [4]cstring{"x", "y", "z", "w"}
@(private = "file") GEOM_RECT := [4]cstring{"x", "y", "width", "height"}
@(private = "file") GEOM_MATRIX := [16]cstring{"m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34", "m41", "m42", "m43", "m44"}

@(private = "file")
geom_kind :: proc "contextless" (v: wj.JSValue) -> int {
	o := wj.obj_of(v)
	if o == nil { return -1 }
	n := string(wj.interfaces()[o.iface].name)
	for g, i in GEOM_NAMES { if string(g) == n { return i } }
	return -1
}

@(private = "file")
put_num_prop :: proc(s: ^Ser, v: wj.JSValue, name: cstring) -> bool {
	x := wj.JS_GetPropertyStr(s.ctx, v, name)
	d: f64
	ok := !wj.is_exception(x) && wj.JS_ToFloat64(s.ctx, &d, x) == 0
	wj.JS_FreeValue(s.ctx, x)
	if ok { put_f64(s, d) }
	return ok
}

// 0: not one of them; 1: written; -1: failed (an exception is pending)
@(private = "file")
serialize_geom :: proc(s: ^Ser, v: wj.JSValue) -> int {
	ctx := s.ctx
	kind := geom_kind(v)
	if kind < 0 { return 0 }
	if !remember(s, v) { return -1 }
	put_tag(s, .Geom)
	put_u8(s, u8(kind))
	ok := true
	switch kind {
	case 0, 1:
		for name in GEOM_POINT { if ok { ok = put_num_prop(s, v, name) } }
	case 2, 3:
		for name in GEOM_RECT { if ok { ok = put_num_prop(s, v, name) } }
	case 4, 5:
		two := wj.JS_GetPropertyStr(ctx, v, "is2D")
		put_u8(s, wj.JS_ToBool(ctx, two) > 0 ? 1 : 0)
		wj.JS_FreeValue(ctx, two)
		for name in GEOM_MATRIX { if ok { ok = put_num_prop(s, v, name) } }
	case:
		ok = put_num_prop(s, v, "width") && put_num_prop(s, v, "height")
		if !ok { break }
		data := wj.JS_GetPropertyStr(ctx, v, "data")
		off, n, per, total: uint
		buf := wj.JS_GetTypedArrayBuffer(ctx, data, &off, &n, &per)
		wj.JS_FreeValue(ctx, data)
		if wj.is_exception(buf) { return -1 }
		bytes := wj.JS_GetArrayBuffer(ctx, &total, buf)
		if bytes == nil || off + n > total {
			wj.JS_FreeValue(ctx, buf)
			clone_error(ctx, "ImageData could not be cloned.")
			return -1
		}
		put_u64(s, u64(n))
		put(s, bytes[off:off + n])
		wj.JS_FreeValue(ctx, buf)
		cs := wj.JS_GetPropertyStr(ctx, v, "colorSpace")
		ok = !wj.is_exception(cs) && put_string(s, cs)
		wj.JS_FreeValue(ctx, cs)
	}
	return ok ? 1 : -1
}

// a transferable-only object of the transfer list, moved by the browser into a token (tag + token)
@(private = "file")
serialize_token :: proc(s: ^Ser, v: wj.JSValue, tag: Clone_Tag, token: u64) -> bool {
	if !remember(s, v) { return false }
	put_tag(s, tag)
	put_u64(s, token)
	return true
}

@(private = "file")
serialize_blob :: proc(s: ^Ser, v: wj.JSValue, bytes: []u8) -> bool {
	// a Blob or File is serializable: its bytes travel with it (a copy: the receiver's is independent)
	ctx := s.ctx
	if !remember(s, v) { return false }
	is_file := is_a(v, &if_file, "File")
	type := web_blob_type(ctx, v)
	put_tag(s, .Blob)
	put_u8(s, is_file ? 1 : 0)
	ok := !wj.is_exception(type) && put_string(s, type)
	wj.JS_FreeValue(ctx, type)
	if !ok { return false }
	put_u64(s, u64(len(bytes)))
	put(s, bytes)
	if is_file {
		name := wj.JS_GetPropertyStr(ctx, v, "name")
		lm := wj.JS_GetPropertyStr(ctx, v, "lastModified")
		t: f64
		ok = !wj.is_exception(name) && !wj.is_exception(lm) && put_string(s, name) && wj.JS_ToFloat64(ctx, &t, lm) == 0
		if ok { put_f64(s, t) }
		wj.JS_FreeValue(ctx, name)
		wj.JS_FreeValue(ctx, lm)
	}
	return ok
}

@(private = "file")
serialize_error :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	ctx := s.ctx
	put_tag(s, .Error)
	FIELDS :: [4]cstring{"name", "message", "stack", "cause"}
	fields := FIELDS
	for name, i in fields {
		a := wj.JS_NewAtom(ctx, name)
		has := i == 0 ? i32(1) : wj.JS_GetOwnProperty(ctx, nil, v, a)
		fv := has > 0 ? wj.JS_GetProperty(ctx, v, a) : wj.UNDEFINED
		wj.JS_FreeAtom(ctx, a)
		if has < 0 || wj.is_exception(fv) { return false }
		ok := true
		if i == 3 {
			put_u8(s, has > 0 ? 1 : 0)
			if has > 0 { ok = serialize(s, fv) }
		} else if wj.is_undefined(fv) {
			put_u8(s, 0)
		} else {
			str := wj.JS_ToString(ctx, fv)
			put_u8(s, 1)
			ok = !wj.is_exception(str) && put_string(s, str)
			wj.JS_FreeValue(ctx, str)
		}
		wj.JS_FreeValue(ctx, fv)
		if !ok { return false }
	}
	return true
}

@(private = "file")
serialize_array :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	ctx := s.ctx
	n: i64
	if wj.JS_GetLength(ctx, v, &n) < 0 { return false }
	put_tag(s, .Array)
	put_u32(s, u32(n))
	// indices present, then the other own enumerable properties
	for i in 0 ..< n {
		a := wj.JS_NewAtomUInt32(ctx, u32(i))
		has := wj.JS_GetOwnProperty(ctx, nil, v, a)
		if has < 0 { wj.JS_FreeAtom(ctx, a); return false }
		put_u8(s, has > 0 ? 1 : 0)
		ok := true
		if has > 0 {
			e := wj.JS_GetProperty(ctx, v, a)
			ok = !wj.is_exception(e) && serialize(s, e)
			wj.JS_FreeValue(ctx, e)
		}
		wj.JS_FreeAtom(ctx, a)
		if !ok { return false }
	}
	return serialize_properties(s, v, true)
}

@(private = "file")
serialize_object :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	ctx := s.ctx
	if ref, seen := s.seen[wj.value_get_ptr(v)]; seen { put_tag(s, .Ref); put_u32(s, ref); return true }
	if wj.JS_IsFunction(ctx, v) { return clone_error(ctx, "function could not be cloned.") }
	if is_a(v, &if_port, "MessagePort") {
		// a transferred port: its place among the ports of the transfer list (the receiver gets a port there)
		k: u32
		for t in s.transfer {
			if !is_a(t, &if_port, "MessagePort") { continue }
			if wj.same_ptr(t, v) { put_tag(s, .Port); put_u32(s, k); return true }
			k += 1
		}
		return clone_error(ctx, "A MessagePort could not be cloned because it was not transferred.")
	}
	if is_a(v, &if_msh, "MediaSourceHandle") {
		// transferable only: the browser hands out a token the receiving realm adopts (the sender's handle is detached)
		if !listed(s, v) { return clone_error(ctx, "A MediaSourceHandle could not be cloned because it was not transferred.") }
		token: u64
		if jsb.host(&token, api_decl.MediaSourceHandle_take, wj.wr_MediaSourceHandle_take, wj.obj_handle(v)) != .None {
			return clone_error(ctx, "A MediaSourceHandle could not be transferred (it was transferred before, or is in use).")
		}
		return serialize_token(s, v, .Mse_Handle, token)
	}
	if is_a(v, &if_video_frame, "VideoFrame") {
		// a VideoFrame is transferable only: it must be in the transfer list; the host moves its pixels into a token
		if !listed(s, v) { return clone_error(ctx, "A VideoFrame could not be cloned because it was not transferred.") }
		token: u64
		jsb.host(&token, api_decl.VideoFrame_takeForTransfer, wj.wr_VideoFrame_takeForTransfer, wj.obj_handle(v))
		if token == 0 { return clone_error(ctx, "A VideoFrame could not be transferred (it is closed).") }
		return serialize_token(s, v, .Video_Frame, token)
	}
	bp: [^]u8
	bn: uint
	if web_blob_bytes(v, &bp, &bn) { return serialize_blob(s, v, bp != nil ? bp[:bn] : nil) }
	if g := serialize_geom(s, v); g != 0 { return g > 0 }
	if is_a(v, &if_fs_handle, "FileSystemHandle") {
		desc := web_fs_handle_describe(ctx, v)
		if desc == nil { return clone_error(ctx, "FileSystemHandle object could not be cloned.") }
		defer wj.libc_free(rawptr(desc))
		if !remember(s, v) { return false }
		str := wj.new_string(ctx, cstring(desc))
		put_tag(s, .Fs_Handle)
		ok := put_string(s, str)
		wj.JS_FreeValue(ctx, str)
		return ok
	}
	if o := wj.obj_of(v); o != nil || wj.same_ptr(v, wj.realm_global()) {
		msg: [160]u8
		name: cstring = o != nil ? wj.interfaces()[o.iface].name : "Window"
		wj.snprintf(&msg[0], len(msg), "%s object could not be cloned.", name)
		return clone_error(ctx, cstring(&msg[0]))
	}
	s.depth += 1
	if s.depth > MAX_DEPTH { return clone_error(ctx, "the value is nested too deeply to be cloned.") }
	if wj.wj_stack_exhausted() { wj.JS_ThrowRangeError(ctx, "Maximum call stack size exceeded"); return false }
	defer s.depth -= 1
	b := &builtins
	if wj.JS_IsArrayBuffer(v) {
		if !remember(s, v) { return false }
		n: uint
		bytes := wj.JS_GetArrayBuffer(ctx, &n, v)
		if bytes == nil && wj.JS_HasException(ctx) {
			// a detached buffer cannot be cloned
			wj.drop_exception(ctx)
			return clone_error(ctx, "An ArrayBuffer is detached and could not be cloned.")
		}
		put_tag(s, .Array_Buffer)
		put_u64(s, u64(n))
		if bytes != nil { put(s, bytes[:n]) }
		return true
	}
	if wj.JS_GetTypedArrayType(v) >= 0 {
		if !remember(s, v) { return false }
		off, n, per: uint
		buf := wj.JS_GetTypedArrayBuffer(ctx, v, &off, &n, &per)
		if wj.is_exception(buf) { return false }
		put_tag(s, .Typed_Array)
		put_u8(s, u8(wj.JS_GetTypedArrayType(v)))
		put_u64(s, u64(off))
		put_u64(s, per != 0 ? u64(n / per) : 0)
		ok := serialize(s, buf)
		wj.JS_FreeValue(ctx, buf)
		return ok
	}
	if prim := brand(ctx, b.dataview_buffer, v); !wj.is_exception(prim) {
		defer wj.JS_FreeValue(ctx, prim)
		if !remember(s, v) { return false }
		off, n := brand(ctx, b.dataview_offset, v), brand(ctx, b.dataview_length, v)
		o, l: f64
		wj.JS_ToFloat64(ctx, &o, off)
		wj.JS_ToFloat64(ctx, &l, n)
		free_values(ctx, off, n)
		put_tag(s, .Data_View)
		put_u64(s, u64(o))
		put_u64(s, u64(l))
		return serialize(s, prim)
	}
	if wj.JS_IsDate(v) {
		if !remember(s, v) { return false }
		t := transmute(f64)u64(0x7ff8_0000_0000_0000)   // NaN
		tv := brand(ctx, b.date_get_time, v)
		if !wj.is_exception(tv) { wj.JS_ToFloat64(ctx, &t, tv) }
		wj.JS_FreeValue(ctx, tv)
		put_tag(s, .Date)
		put_f64(s, t)
		return true
	}
	if wj.JS_IsRegExp(v) {
		if !remember(s, v) { return false }
		src := wj.JS_GetPropertyStr(ctx, v, "source")
		flags := wj.JS_GetPropertyStr(ctx, v, "flags")
		put_tag(s, .Reg_Exp)
		ok := !wj.is_exception(src) && !wj.is_exception(flags) && put_string(s, src) && put_string(s, flags)
		free_values(ctx, src, flags)
		return ok
	}
	if wj.JS_IsMap(v) || wj.JS_IsSet(v) {
		is_map := wj.JS_IsMap(v)
		if !remember(s, v) { return false }
		arr := wj.JS_NewArray(ctx)
		defer wj.JS_FreeValue(ctx, arr)
		if !for_each_collect(ctx, is_map ? b.map_for_each : b.set_for_each, v, arr) { return false }
		n := wj.length_of(ctx, arr)
		put_tag(s, is_map ? .Map : .Set)
		put_u32(s, u32(is_map ? n / 2 : n))
		for i in 0 ..< n {
			e := wj.JS_GetPropertyInt64(ctx, arr, i)
			ok := serialize(s, e)
			wj.JS_FreeValue(ctx, e)
			if !ok { return false }
		}
		return true
	}
	if wj.JS_IsError(v) {
		if !remember(s, v) { return false }
		return serialize_error(s, v)
	}
	if wj.JS_IsArray(v) {
		if !remember(s, v) { return false }
		return serialize_array(s, v)
	}
	if prim := brand(ctx, b.bool_value_of, v); !wj.is_exception(prim) {
		defer wj.JS_FreeValue(ctx, prim)
		if !remember(s, v) { return false }
		put_tag(s, .Boolean_Obj)
		put_u8(s, wj.JS_ToBool(ctx, prim) > 0 ? 1 : 0)
		return true
	}
	if prim := brand(ctx, b.number_value_of, v); !wj.is_exception(prim) {
		defer wj.JS_FreeValue(ctx, prim)
		if !remember(s, v) { return false }
		d: f64
		wj.JS_ToFloat64(ctx, &d, prim)
		put_tag(s, .Number_Obj)
		put_f64(s, d)
		return true
	}
	if prim := brand(ctx, b.string_value_of, v); !wj.is_exception(prim) {
		defer wj.JS_FreeValue(ctx, prim)
		if !remember(s, v) { return false }
		put_tag(s, .String_Obj)
		return put_string(s, prim)
	}
	if prim := brand(ctx, b.bigint_value_of, v); !wj.is_exception(prim) {
		defer wj.JS_FreeValue(ctx, prim)
		if !remember(s, v) { return false }
		str := wj.JS_ToString(ctx, prim)
		put_tag(s, .Big_Int_Obj)
		ok := !wj.is_exception(str) && put_string(s, str)
		wj.JS_FreeValue(ctx, str)
		return ok
	}
	// an ordinary object (a Proxy or an exotic object is read through its own traps, as any object)
	if !remember(s, v) { return false }
	put_tag(s, .Object)
	return serialize_properties(s, v, false)
}

@(private = "file")
serialize :: proc(s: ^Ser, v: wj.JSValue) -> bool {
	ctx := s.ctx
	if s.oom { wj.JS_ThrowOutOfMemory(ctx); return false }
	switch {
	case wj.is_undefined(v): put_tag(s, .Undefined)
	case wj.is_null(v):      put_tag(s, .Null)
	case wj.is_bool(v):      put_tag(s, wj.int_of(v) != 0 ? .True : .False)
	case wj.tag_of(v) == i32(wj.Tag.Int):
		put_tag(s, .Int32)
		put_u32(s, u32(wj.int_of(v)))
	case wj.is_string(v):
		put_tag(s, .String)
		return put_string(s, v)
	case wj.is_symbol(v):    return clone_error(ctx, "Symbol could not be cloned.")
	case wj.is_object(v):    return serialize_object(s, v)
	case wj.is_big_int(v):
		str := wj.JS_ToString(ctx, v)
		put_tag(s, .Big_Int)
		ok := !wj.is_exception(str) && put_string(s, str)
		wj.JS_FreeValue(ctx, str)
		return ok
	case wj.is_number(v):
		d: f64
		wj.JS_ToFloat64(ctx, &d, v)
		put_tag(s, .Double)
		put_f64(s, d)
	case:
		return clone_error(ctx, "the value could not be cloned.")
	}
	return true
}

// The transferables of a transfer list (a sequence<object>), validated: DataCloneError for anything else, a duplicate or
// a detached buffer. Counted references, freed with transfer_free.
@(private = "file")
transfer_list :: proc(ctx: ^wj.Context, list: wj.JSValue, items: ^[dynamic]wj.JSValue) -> bool {
	if wj.is_nullish(list) { return true }
	if !wj.is_object(list) { wj.JS_ThrowTypeError(ctx, "The transfer list is not a sequence."); return false }
	n: i64
	if wj.JS_GetLength(ctx, list, &n) < 0 { return false }
	if n == 0 { return true }
	if reserve(items, int(n)) != nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	for i in 0 ..< n {
		item := wj.JS_GetPropertyInt64(ctx, list, i)
		if wj.is_exception(item) { return false }
		append(items, item)
		port := is_a(item, &if_port, "MessagePort")
		movable := port || is_a(item, &if_msh, "MediaSourceHandle") || is_a(item, &if_video_frame, "VideoFrame")
		if !movable && !wj.JS_IsArrayBuffer(item) {
			return clone_error(ctx, "Value at index in the transfer list is not transferable (only ArrayBuffer, MessagePort, MediaSourceHandle and VideoFrame are).")
		}
		if wj.JS_IsArrayBufferHost(item) { return clone_error(ctx, "The buffer of a WebAssembly.Memory cannot be transferred.") }
		bn: uint
		if !movable && wj.JS_GetArrayBuffer(ctx, &bn, item) == nil && wj.JS_HasException(ctx) {
			wj.drop_exception(ctx)
			return clone_error(ctx, "An ArrayBuffer is detached and could not be transferred.")
		}
		for earlier in items[:len(items) - 1] {
			if wj.same_ptr(earlier, item) {
				return clone_error(ctx, port ? "MessagePort at index is a duplicate of an earlier MessagePort." : "ArrayBuffer at index is a duplicate of an earlier ArrayBuffer.")
			}
		}
	}
	return true
}

@(private = "file")
transfer_free :: proc(ctx: ^wj.Context, items: ^[dynamic]wj.JSValue) {
	for v in items { wj.JS_FreeValue(ctx, v) }
	delete(items^)
}

// Serializes `value` (its ArrayBuffers in `transfer` are detached afterwards). The bytes (free with free()), nil with an
// exception pending (DataCloneError...). A MessagePort in the transfer list is refused (a caller that cannot send
// ports: wj_clone_serialize_ports is the one that can).
@(export, link_name = "wj_clone_serialize")
wj_clone_serialize :: proc "c" (ctx: ^wj.Context, value: wj.JSValue, transfer: wj.JSValue, length: ^uint) -> [^]u8 {
	return clone_serialize_no_ports(ctx, value, transfer, nil, length)
}

// wj_clone_serialize with `prefix` written before the serialization (web_clone_serialize's tag byte), in the same block.
clone_serialize_no_ports :: proc "contextless" (ctx: ^wj.Context, value: wj.JSValue, transfer: wj.JSValue, prefix: []u8, length: ^uint) -> [^]u8 {
	ports := wj.UNDEFINED
	p := clone_serialize(ctx, value, transfer, prefix, length, &ports)
	defer wj.JS_FreeValue(ctx, ports)
	if p != nil && wj.JS_IsArray(ports) && wj.length_of(ctx, ports) > 0 {
		wj.libc_free(p)
		wj.wj_throw_dom(ctx, "DataCloneError", "A MessagePort cannot be sent there.")
		return nil
	}
	return p
}

// The same, MessagePorts allowed in the transfer list: they are listed in *ports (an array, in transfer order, to ship:
// web_message.odin web_ship_ports); the serialization names them by index (Port).
@(export, link_name = "wj_clone_serialize_ports")
wj_clone_serialize_ports :: proc "c" (ctx: ^wj.Context, value: wj.JSValue, transfer: wj.JSValue, length: ^uint, ports: ^wj.JSValue) -> [^]u8 {
	return clone_serialize(ctx, value, transfer, nil, length, ports)
}

@(private = "file")
clone_serialize :: proc "contextless" (ctx: ^wj.Context, value: wj.JSValue, transfer: wj.JSValue, prefix: []u8, length: ^uint, ports: ^wj.JSValue) -> [^]u8 {
	context = m4_context()
	ports^ = wj.UNDEFINED
	items: [dynamic]wj.JSValue
	defer transfer_free(ctx, &items)
	if !transfer_list(ctx, transfer, &items) { return nil }
	s := Ser{ctx = ctx, transfer = items[:]}
	defer delete(s.seen)
	put(&s, prefix)
	put(&s, MAGIC[:])
	ok := serialize(&s, value)
	if ok && s.oom { wj.JS_ThrowOutOfMemory(ctx); ok = false }
	if !ok { delete(s.out); return nil }
	list := wj.JS_NewArray(ctx)
	k: u32
	for item in items {
		switch {
		case is_a(item, &if_port, "MessagePort"):
			wj.JS_SetPropertyUint32(ctx, list, k, wj.JS_DupValue(ctx, item))
			k += 1
		case is_a(item, &if_msh, "MediaSourceHandle"), is_a(item, &if_video_frame, "VideoFrame"):
			// (detached by the browser when it took them)
		case:
			wj.JS_DetachArrayBuffer(ctx, item)
		}
	}
	ports^ = list
	length^ = uint(len(s.out))
	return raw_data(s.out)   // the libc block of the dynamic array: the caller frees it
}

@(export, link_name = "wj_clone_is_serialized")
wj_clone_is_serialized :: proc "c" (data: [^]u8, n: uint) -> bool {
	return n >= len(MAGIC) && data[0] == MAGIC[0] && data[1] == MAGIC[1] && data[2] == MAGIC[2] && data[3] == MAGIC[3]
}

// ---- deserialization ----

@(private = "file")
Deser :: struct {
	ctx:   ^wj.Context,
	in_:   []u8,               // what is left to read
	refs:  [dynamic]wj.JSValue,  // counted
	depth: u32,
	ports: wj.JSValue,         // the received ports (Port), or undefined
}

@(private = "file")
get_bytes :: proc "contextless" (d: ^Deser, n: u64) -> ([]u8, bool) {
	if u64(len(d.in_)) < n { return nil, false }
	b := d.in_[:n]
	d.in_ = d.in_[n:]
	return b, true
}
@(private = "file") get_u8 :: proc "contextless" (d: ^Deser) -> (v: u8, ok: bool) { b := get_bytes(d, 1) or_return; return b[0], true }
@(private = "file")
get_u32 :: proc "contextless" (d: ^Deser) -> (v: u32, ok: bool) {
	b := get_bytes(d, 4) or_return
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24, true
}
@(private = "file")
get_u64 :: proc "contextless" (d: ^Deser) -> (v: u64, ok: bool) {
	lo := get_u32(d) or_return
	hi := get_u32(d) or_return
	return u64(hi) << 32 | u64(lo), true
}
@(private = "file") get_f64 :: proc "contextless" (d: ^Deser) -> (v: f64, ok: bool) { u := get_u64(d) or_return; return transmute(f64)u, true }

@(private = "file")
malformed :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return wj.JS_ThrowSyntaxError(ctx, "malformed serialized value") }

@(private = "file")
get_string :: proc "contextless" (d: ^Deser) -> wj.JSValue {
	n, ok := get_u32(d)
	if !ok { return malformed(d.ctx) }
	b, ok2 := get_bytes(d, u64(n))
	if !ok2 { return malformed(d.ctx) }
	return wj.new_string_len(d.ctx, b)
}

@(private = "file")
add_ref :: proc(d: ^Deser, v: wj.JSValue) -> bool {
	if _, err := append(&d.refs, wj.JS_DupValue(d.ctx, v)); err != nil {
		wj.JS_FreeValue(d.ctx, v)
		wj.JS_ThrowOutOfMemory(d.ctx)
		return false
	}
	return true
}

// r, remembered as the next back-reference (EXCEPTION when that fails; r is released then)
@(private = "file")
keep :: proc(d: ^Deser, r: wj.JSValue) -> wj.JSValue {
	if wj.is_exception(r) { return r }
	if !add_ref(d, r) { wj.JS_FreeValue(d.ctx, r); return wj.EXCEPTION }
	return r
}

@(private = "file")
read_properties :: proc(d: ^Deser, obj: wj.JSValue) -> wj.JSValue {
	ctx := d.ctx
	count, ok := get_u32(d)
	if !ok { wj.JS_FreeValue(ctx, obj); return malformed(ctx) }
	for _ in 0 ..< count {
		key := get_string(d)
		if wj.is_exception(key) { wj.JS_FreeValue(ctx, obj); return key }
		val := deserialize(d)
		if wj.is_exception(val) { free_values(ctx, key, obj); return val }
		a := wj.JS_ValueToAtom(ctx, key)
		wj.JS_FreeValue(ctx, key)
		r := wj.JS_DefinePropertyValue(ctx, obj, a, val, wj.PROP_C_W_E)
		wj.JS_FreeAtom(ctx, a)
		if r < 0 { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	}
	return obj
}

// the attributes of a platform object read back as the arguments of its constructor
@(private = "file")
deserialize_geom :: proc(d: ^Deser) -> wj.JSValue {
	ctx := d.ctx
	kind, ok := get_u8(d)
	if !ok || int(kind) >= len(GEOM_NAMES) { return malformed(ctx) }
	ctor := wj.global_get(ctx, GEOM_NAMES[kind])
	if wj.is_exception(ctor) { return ctor }
	defer wj.JS_FreeValue(ctx, ctor)
	if !wj.JS_IsFunction(ctx, ctor) { return malformed(ctx) }
	v: [16]f64
	switch kind {
	case 0, 1, 2, 3:
		args: [4]wj.JSValue
		for i in 0 ..< 4 {
			x, okx := get_f64(d)
			if !okx { return malformed(ctx) }
			args[i] = wj.new_float64(ctx, x)
		}
		r := wj.JS_CallConstructor(ctx, ctor, 4, &args[0])
		for a in args { wj.JS_FreeValue(ctx, a) }
		return r
	case 4, 5:
		two, ok2 := get_u8(d)
		if !ok2 { return malformed(ctx) }
		for i in 0 ..< 16 {
			x, okx := get_f64(d)
			if !okx { return malformed(ctx) }
			v[i] = x
		}
		arr := wj.JS_NewArray(ctx)
		if two != 0 {
			IDX :: [6]int{0, 1, 4, 5, 12, 13}   // a b c d e f: m11 m12 m21 m22 m41 m42
			idx := IDX
			for k, i in idx { wj.JS_SetPropertyUint32(ctx, arr, u32(i), wj.new_float64(ctx, v[k])) }
		} else {
			for i in 0 ..< 16 { wj.JS_SetPropertyUint32(ctx, arr, u32(i), wj.new_float64(ctx, v[i])) }
		}
		r := wj.JS_CallConstructor(ctx, ctor, 1, &arr)
		wj.JS_FreeValue(ctx, arr)
		return r
	case:
		w, ok1 := get_f64(d)
		h, ok2 := get_f64(d)
		n, ok3 := get_u64(d)
		if !ok1 || !ok2 || !ok3 { return malformed(ctx) }
		bytes, ok4 := get_bytes(d, n)
		if !ok4 { return malformed(ctx) }
		cs := get_string(d)
		if wj.is_exception(cs) { return cs }
		ab := wj.JS_NewArrayBufferCopy(ctx, raw_data(bytes), uint(len(bytes)))
		clamped := wj.global_get(ctx, "Uint8ClampedArray")
		data := wj.JS_CallConstructor(ctx, clamped, 1, &ab)
		free_values(ctx, clamped, ab)
		if wj.is_exception(data) { wj.JS_FreeValue(ctx, cs); return data }
		settings := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, settings, "colorSpace", cs)
		a := [4]wj.JSValue{data, wj.new_float64(ctx, w), wj.new_float64(ctx, h), settings}
		r := wj.JS_CallConstructor(ctx, ctor, 4, &a[0])
		for x in a { wj.JS_FreeValue(ctx, x) }
		return r
	}
}

// a typed array or a DataView: its reference index is taken before its buffer's (a placeholder keeps back-references
// right), then the view is built over the buffer read after it
@(private = "file")
deserialize_view :: proc(d: ^Deser, typed: bool, type: u8, off, n: u64) -> wj.JSValue {
	ctx := d.ctx
	slot := len(d.refs)
	if !add_ref(d, wj.UNDEFINED) { return wj.EXCEPTION }
	buf := deserialize(d)
	if wj.is_exception(buf) { return buf }
	args := [3]wj.JSValue{buf, wj.new_int64(ctx, i64(off)), wj.new_int64(ctx, i64(n))}
	r := typed ? wj.JS_NewTypedArray(ctx, 3, &args[0], i32(type)) : wj.JS_CallConstructor(ctx, builtins.ctor_dataview, 3, &args[0])
	wj.JS_FreeValue(ctx, buf)
	if !wj.is_exception(r) { d.refs[slot] = wj.JS_DupValue(ctx, r) }
	return r
}

@(private = "file")
deserialize_collection :: proc(d: ^Deser, is_map: bool) -> wj.JSValue {
	ctx := d.ctx
	n, ok := get_u32(d)
	if !ok { return malformed(ctx) }
	r := keep(d, wj.JS_CallConstructor(ctx, is_map ? builtins.ctor_map : builtins.ctor_set, 0, nil))
	if wj.is_exception(r) { return r }
	adder := wj.JS_GetPropertyStr(ctx, r, is_map ? "set" : "add")
	defer wj.JS_FreeValue(ctx, adder)
	for _ in 0 ..< n {
		kv := [2]wj.JSValue{deserialize(d), wj.UNDEFINED}
		if wj.is_exception(kv[0]) { wj.JS_FreeValue(ctx, r); return wj.EXCEPTION }
		if is_map {
			kv[1] = deserialize(d)
			if wj.is_exception(kv[1]) { free_values(ctx, kv[0], r); return wj.EXCEPTION }
		}
		x := wj.JS_Call(ctx, adder, r, is_map ? 2 : 1, &kv[0])
		free_values(ctx, kv[0], kv[1])
		if wj.is_exception(x) { wj.JS_FreeValue(ctx, r); return wj.EXCEPTION }
		wj.JS_FreeValue(ctx, x)
	}
	return r
}

@(private = "file")
deserialize_error :: proc(d: ^Deser) -> wj.JSValue {
	ctx := d.ctx
	r := keep(d, wj.JS_NewError(ctx))
	if wj.is_exception(r) { return r }
	FIELDS :: [4]cstring{"name", "message", "stack", "cause"}
	KNOWN :: [7]cstring{"Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError"}
	fields := FIELDS
	known := KNOWN
	for name, i in fields {
		has, ok := get_u8(d)
		if !ok { wj.JS_FreeValue(ctx, r); return malformed(ctx) }
		if has == 0 { continue }
		fv := i == 3 ? deserialize(d) : get_string(d)
		if wj.is_exception(fv) { wj.JS_FreeValue(ctx, r); return fv }
		if i == 0 {
			// the prototype of the error's kind (one of the standard ones, else Error)
			kind: cstring = "Error"
			c, nm := to_text(ctx, fv)
			for k in known { if nm == string(k) { kind = k } }
			if c != nil { wj.free_cstring(ctx, c) }
			ctor := wj.global_get(ctx, kind)
			proto := wj.JS_GetPropertyStr(ctx, ctor, "prototype")
			wj.JS_SetPrototype(ctx, r, proto)
			free_values(ctx, proto, ctor, fv)
		} else {
			wj.JS_DefinePropertyValueStr(ctx, r, name, fv, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
		}
	}
	return r
}

@(private = "file")
deserialize_array :: proc(d: ^Deser) -> wj.JSValue {
	ctx := d.ctx
	n, ok := get_u32(d)
	if !ok { return malformed(ctx) }
	r := keep(d, wj.JS_NewArray(ctx))
	if wj.is_exception(r) { return r }
	wj.JS_SetPropertyStr(ctx, r, "length", wj.new_uint32(ctx, n))
	for i in 0 ..< n {
		has, ok2 := get_u8(d)
		if !ok2 { wj.JS_FreeValue(ctx, r); return malformed(ctx) }
		if has == 0 { continue }
		e := deserialize(d)
		if wj.is_exception(e) { wj.JS_FreeValue(ctx, r); return e }
		wj.JS_DefinePropertyValueUint32(ctx, r, i, e, wj.PROP_C_W_E)
	}
	return read_properties(d, r)
}

@(private = "file")
deserialize_blob :: proc(d: ^Deser) -> wj.JSValue {
	ctx := d.ctx
	is_file, ok := get_u8(d)
	if !ok { return malformed(ctx) }
	type := get_string(d)
	if wj.is_exception(type) { return type }
	defer wj.JS_FreeValue(ctx, type)
	n, ok2 := get_u64(d)
	if !ok2 { return malformed(ctx) }
	bytes, ok3 := get_bytes(d, n)
	if !ok3 { return malformed(ctx) }
	tc, t := to_text(ctx, type)
	if tc == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, tc)
	if is_file == 0 { return web_blob_new(ctx, raw_data(bytes), uint(len(bytes)), tc, uint(len(t))) }
	name := get_string(d)
	if wj.is_exception(name) { return name }
	defer wj.JS_FreeValue(ctx, name)
	lm, ok4 := get_f64(d)
	if !ok4 { return malformed(ctx) }
	nc, nm := to_text(ctx, name)
	if nc == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, nc)
	return web_file_new(ctx, raw_data(bytes), uint(len(bytes)), tc, uint(len(t)), nc, uint(len(nm)), lm)
}

@(private = "file")
deserialize :: proc(d: ^Deser) -> wj.JSValue {
	ctx := d.ctx
	raw, ok := get_u8(d)
	if !ok { return malformed(ctx) }
	d.depth += 1
	defer d.depth -= 1
	if d.depth > MAX_DEPTH { return wj.JS_ThrowRangeError(ctx, "serialized value nested too deeply") }
	if wj.wj_stack_exhausted() { return wj.JS_ThrowRangeError(ctx, "Maximum call stack size exceeded") }
	if raw > u8(max(Clone_Tag)) { return malformed(ctx) }
	b := &builtins
	switch Clone_Tag(raw) {
	case .Undefined: return wj.UNDEFINED
	case .Null:      return wj.NULL
	case .False:     return wj.FALSE
	case .True:      return wj.TRUE
	case .Int32:
		u, oku := get_u32(d)
		return oku ? wj.new_int32(i32(u)) : malformed(ctx)
	case .Double:
		x, okx := get_f64(d)
		return okx ? wj.new_float64(ctx, x) : malformed(ctx)
	case .String:
		return get_string(d)
	case .Big_Int:
		s := get_string(d)
		if wj.is_exception(s) { return s }
		r := wj.JS_Call(ctx, b.ctor_bigint, wj.UNDEFINED, 1, &s)
		wj.JS_FreeValue(ctx, s)
		return r
	case .Ref:
		i, oki := get_u32(d)
		if !oki || int(i) >= len(d.refs) { return malformed(ctx) }
		return wj.JS_DupValue(ctx, d.refs[i])
	case .Boolean_Obj:
		x, okx := get_u8(d)
		if !okx { return malformed(ctx) }
		arg := wj.new_bool(x != 0)
		return keep(d, wj.JS_CallConstructor(ctx, b.ctor_boolean, 1, &arg))
	case .Number_Obj:
		x, okx := get_f64(d)
		if !okx { return malformed(ctx) }
		arg := wj.new_float64(ctx, x)
		return keep(d, wj.JS_CallConstructor(ctx, b.ctor_number, 1, &arg))
	case .String_Obj:
		s := get_string(d)
		if wj.is_exception(s) { return s }
		r := wj.JS_CallConstructor(ctx, b.ctor_string, 1, &s)
		wj.JS_FreeValue(ctx, s)
		return keep(d, r)
	case .Big_Int_Obj:
		s := get_string(d)
		if wj.is_exception(s) { return s }
		big := wj.JS_Call(ctx, b.ctor_bigint, wj.UNDEFINED, 1, &s)
		wj.JS_FreeValue(ctx, s)
		if wj.is_exception(big) { return big }
		r := wj.JS_Call(ctx, b.ctor_object, wj.UNDEFINED, 1, &big)
		wj.JS_FreeValue(ctx, big)
		return keep(d, r)
	case .Date:
		t, okt := get_f64(d)
		if !okt { return malformed(ctx) }
		return keep(d, wj.JS_NewDate(ctx, t))
	case .Reg_Exp:
		args: [2]wj.JSValue
		args[0] = get_string(d)
		if wj.is_exception(args[0]) { return args[0] }
		args[1] = get_string(d)
		if wj.is_exception(args[1]) { wj.JS_FreeValue(ctx, args[0]); return args[1] }
		r := wj.JS_CallConstructor(ctx, b.ctor_regexp, 2, &args[0])
		free_values(ctx, args[0], args[1])
		return keep(d, r)
	case .Array_Buffer:
		n, okn := get_u64(d)
		if !okn { return malformed(ctx) }
		bytes, okb := get_bytes(d, n)
		if !okb { return malformed(ctx) }
		return keep(d, wj.JS_NewArrayBufferCopy(ctx, raw_data(bytes), uint(len(bytes))))
	case .Typed_Array:
		type, ok1 := get_u8(d)
		off, ok2 := get_u64(d)
		n, ok3 := get_u64(d)
		if !ok1 || !ok2 || !ok3 || i32(type) > i32(wj.Typed_Array.Float64) { return malformed(ctx) }
		return deserialize_view(d, true, type, off, n)
	case .Data_View:
		off, ok2 := get_u64(d)
		n, ok3 := get_u64(d)
		if !ok2 || !ok3 { return malformed(ctx) }
		return deserialize_view(d, false, 0, off, n)
	case .Map, .Set:
		return deserialize_collection(d, Clone_Tag(raw) == .Map)
	case .Error:
		return deserialize_error(d)
	case .Array:
		return deserialize_array(d)
	case .Object:
		r := keep(d, wj.JS_NewObject(ctx))
		if wj.is_exception(r) { return r }
		return read_properties(d, r)
	case .Port:
		i, oki := get_u32(d)
		if !oki || !wj.JS_IsArray(d.ports) { return malformed(ctx) }
		r := wj.JS_GetPropertyUint32(ctx, d.ports, i)
		return wj.is_undefined(r) ? malformed(ctx) : r
	case .Mse_Handle:
		token, okt := get_u64(d)
		if !okt { return malformed(ctx) }
		h: api_decl.MediaSourceHandle
		if jsb.host(&h, api_decl.MediaSourceHandle_adopt, wj.wr_MediaSourceHandle_adopt, token) != .None || h == 0 { return malformed(ctx) }
		return keep(d, wj.wj_wrap_owned(ctx, u64(h), jsb.iface_of(api_decl.MediaSourceHandle), wj.UNDEFINED))
	case .Video_Frame:
		token, okt := get_u64(d)
		if !okt { return malformed(ctx) }
		h: api_decl.VideoFrame
		jsb.host(&h, api_decl.VideoFrame_adoptTransfer, wj.wr_VideoFrame_adoptTransfer, token)
		if h == 0 { return malformed(ctx) }
		return keep(d, wj.wj_wrap_owned(ctx, u64(h), jsb.iface_of(api_decl.VideoFrame), wj.UNDEFINED))
	case .Fs_Handle:
		str := get_string(d)
		if wj.is_exception(str) { return str }
		c, s := to_text(ctx, str)
		r := c != nil ? web_fs_handle_restore(ctx, raw_data(s), uint(len(s))) : malformed(ctx)
		if c != nil { wj.free_cstring(ctx, c) }
		wj.JS_FreeValue(ctx, str)
		return keep(d, r)
	case .Geom:
		return keep(d, deserialize_geom(d))
	case .Blob:
		return keep(d, deserialize_blob(d))
	}
	return malformed(ctx)
}

// The value `data` serializes (a new reference), or EXCEPTION.
@(export, link_name = "wj_clone_deserialize")
wj_clone_deserialize :: proc "c" (ctx: ^wj.Context, data: [^]u8, n: uint) -> wj.JSValue {
	return wj_clone_deserialize_ports(ctx, data, n, wj.UNDEFINED)
}

// The same, with the ports that came with the message (an array, in transfer order).
@(export, link_name = "wj_clone_deserialize_ports")
wj_clone_deserialize_ports :: proc "c" (ctx: ^wj.Context, data: [^]u8, n: uint, ports: wj.JSValue) -> wj.JSValue {
	context = m4_context()
	if !wj_clone_is_serialized(data, n) { return wj.JS_ThrowSyntaxError(ctx, "not a serialized value") }
	d := Deser{ctx = ctx, in_ = data[len(MAGIC):n], ports = ports}
	v := deserialize(&d)
	for r in d.refs { wj.JS_FreeValue(ctx, r) }
	delete(d.refs)
	return v
}

// structuredClone(value, {transfer})
@(export, link_name = "wjr_WindowOrWorkerGlobalScope_structuredClone")
wjr_WindowOrWorkerGlobalScope_structuredClone :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "structuredClone", 1, argc) }
	transfer := wj.UNDEFINED
	if opt := wj.arg(argc, argv, 1); !wj.is_nullish(opt) {
		if !wj.is_object(opt) { return wj.JS_ThrowTypeError(ctx, "Failed to execute 'structuredClone': The provided value is not of type 'StructuredSerializeOptions'.") }
		transfer = wj.JS_GetPropertyStr(ctx, opt, "transfer")
		if wj.is_exception(transfer) { return transfer }
	}
	n: uint
	bytes := wj_clone_serialize(ctx, argv[0], transfer, &n)
	wj.JS_FreeValue(ctx, transfer)
	if bytes == nil { return wj.EXCEPTION }
	v := wj_clone_deserialize(ctx, bytes, n)
	wj.libc_free(bytes)
	return v
}
