// frames_bridge.odin: values across the realms of same-origin documents (frame.contentWindow.foo, parent.foo()). Each document
// has its own engine instance, so no value of one is a value of another. A request to another realm goes through the browser
// (Frame_bridge: it checks the origin on each one) as bytes:
//
//   undefined, null, booleans, numbers, strings, bigints  copied
//   well-known symbols                                    by name (any other symbol is not carried: undefined)
//   a DOM node                                            its handle: the receiving realm's wrapper of that node
//   a window                                              its navigable: the receiving realm's WindowProxy, or its global
//   any other object, function                            a reference: a Proxy in the receiving realm (web_bridge.js) that forwards
//                                                         get, set, call, construct... to the realm that has it
//
// What it is not: one heap. Objects keep their realm's prototypes, as in a browser (`x instanceof Array` is false across frames),
// a native function refuses a Proxy for one of its own objects (a typed array or a Blob passed across), and a cycle between two realms
// (a listener of one kept by the other) lives until one of them goes. A realm that is gone answers undefined.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") OP_GET :: 1
@(private = "file") OP_SET :: 2
@(private = "file") OP_HAS :: 3
@(private = "file") OP_DELETE :: 4
@(private = "file") OP_KEYS :: 5
@(private = "file") OP_GOPD :: 6
@(private = "file") OP_DEFINE :: 7
@(private = "file") OP_APPLY :: 10
@(private = "file") OP_CONSTRUCT :: 11
@(private = "file") GLOBAL_NUMBER :: 0

@(private = "file") Tag :: enum u8 { Undefined, Null, False, True, Number, String, Bigint, Node, Window, Object, Symbol, List, Error }

@(private = "file") bridge: wj.JSValue   // what web_bridge.js returned (in the image: counted for good)
@(private = "file") dispatch_fn, import_ref_fn, export_ref_fn, symbol_name_fn, symbol_of_fn, bigint_fn, describe_error_fn, make_error_fn: wj.JSValue
@(private = "file") self_realm: f64      // this realm's number (its document's), once asked

@(private = "file")
realm_self :: proc "contextless" () -> f64 {
	if self_realm == 0 {
		context = jsb.glue_context()
		id: u64
		jsb.host(&id, api_decl.Frame_realmSelf, wj.wr_Frame_realmSelf)
		self_realm = f64(id)
	}
	return self_realm
}

// ---- encoding ----

@(private = "file")
put_string :: proc "contextless" (b: ^Pack, s: string) -> bool {
	return pack_le(b, u64(len(s)), 4) && pack_bytes(b, transmute([]u8)s)
}

// Encodes `v`; false with an exception pending.
@(private = "file")
put_value :: proc "contextless" (ctx: ^wj.Context, b: ^Pack, v: wj.JSValue) -> bool {
	switch {
	case wj.is_undefined(v): return pack_u8(b, u8(Tag.Undefined))
	case wj.is_null(v): return pack_u8(b, u8(Tag.Null))
	case wj.is_bool(v): return pack_u8(b, u8(wj.JS_ToBool(ctx, v) != 0 ? Tag.True : Tag.False))
	case wj.is_number(v):
		d: f64
		wj.JS_ToFloat64(ctx, &d, v)
		return pack_u8(b, u8(Tag.Number)) && pack_le(b, transmute(u64)d, 8)
	case wj.is_string(v):
		c, s := to_text(ctx, v)
		if c == nil { return false }
		defer wj.JS_FreeCString(ctx, c)
		return pack_u8(b, u8(Tag.String)) && put_string(b, s)
	case wj.is_symbol(v):
		arg := v
		name := wj.JS_Call(ctx, symbol_name_fn, wj.UNDEFINED, 1, &arg)
		defer wj.JS_FreeValue(ctx, name)
		if !wj.is_string(name) { return pack_u8(b, u8(Tag.Undefined)) }
		c, s := to_text(ctx, name)
		if c == nil { return false }
		defer wj.JS_FreeCString(ctx, c)
		return pack_u8(b, u8(Tag.Symbol)) && put_string(b, s)
	case wj.is_object(v):
		return put_object(ctx, b, v)
	}
	// a bigint: as text
	text := wj.JS_ToString(ctx, v)
	if wj.is_exception(text) { return false }
	defer wj.JS_FreeValue(ctx, text)
	c, s := to_text(ctx, text)
	if c == nil { return false }
	defer wj.JS_FreeCString(ctx, c)
	return pack_u8(b, u8(Tag.Bigint)) && put_string(b, s)
}

@(private = "file")
put_object :: proc "contextless" (ctx: ^wj.Context, b: ^Pack, v: wj.JSValue) -> bool {
	if n := wj.wj_unwrap(v, ifc("Node")); n != nil && n.handle != 0 && n.kind == wj.KIND_NODE {
		return pack_u8(b, u8(Tag.Node)) && pack_le(b, n.handle, 8)
	}
	if id := frames_window_id(v); id != 0 { return pack_u8(b, u8(Tag.Window)) && pack_le(b, u64(id), 8) }
	args := [2]wj.JSValue{wj.new_float64(ctx, realm_self()), v}
	ref := wj.JS_Call(ctx, export_ref_fn, wj.UNDEFINED, 2, &args[0])
	if wj.is_exception(ref) { return false }
	defer wj.JS_FreeValue(ctx, ref)
	realm, number, kind: f64
	for x, i in ([3]^f64{&realm, &number, &kind}) {
		f := wj.JS_GetPropertyUint32(ctx, ref, u32(i))
		wj.JS_ToFloat64(ctx, x, f)
		wj.JS_FreeValue(ctx, f)
	}
	return pack_u8(b, u8(Tag.Object)) && pack_le(b, u64(realm), 8) && pack_le(b, u64(number), 8) && pack_u8(b, u8(kind))
}

// An array as a list of values.
@(private = "file")
put_list :: proc "contextless" (ctx: ^wj.Context, b: ^Pack, list: wj.JSValue) -> bool {
	n: i64
	if wj.JS_GetLength(ctx, list, &n) < 0 { return false }
	if !pack_u8(b, u8(Tag.List)) || !pack_le(b, u64(n), 4) { return false }
	for i in 0 ..< n {
		x := wj.JS_GetPropertyInt64(ctx, list, i)
		if wj.is_exception(x) { return false }
		ok := put_value(ctx, b, x)
		wj.JS_FreeValue(ctx, x)
		if !ok { return false }
	}
	return true
}

// ---- decoding ----

@(private = "file") Reader :: struct { p: []u8, at: int }

@(private = "file")
read_le :: proc "contextless" (r: ^Reader, size: int) -> (x: u64) {
	if r.at + size > len(r.p) { r.at = len(r.p); return 0 }
	for i in 0 ..< size { x |= u64(r.p[r.at + i]) << (8 * uint(i)) }
	r.at += size
	return
}

@(private = "file")
read_string :: proc "contextless" (r: ^Reader) -> string {
	n := int(read_le(r, 4))
	if r.at + n > len(r.p) { r.at = len(r.p); return "" }
	s := string(r.p[r.at:r.at + n])
	r.at += n
	return s
}

@(private = "file")
take_value :: proc "contextless" (ctx: ^wj.Context, r: ^Reader) -> wj.JSValue {
	if r.at >= len(r.p) { return wj.UNDEFINED }
	tag := Tag(r.p[r.at])
	r.at += 1
	switch tag {
	case .Undefined: return wj.UNDEFINED
	case .Null: return wj.NULL
	case .False: return wj.FALSE
	case .True: return wj.TRUE
	case .Number: return wj.new_float64(ctx, transmute(f64)read_le(r, 8))
	case .String:
		s := read_string(r)
		return wj.JS_NewStringLen(ctx, raw_data(s), uint(len(s)))
	case .Bigint, .Symbol:
		s := read_string(r)
		text := wj.JS_NewStringLen(ctx, raw_data(s), uint(len(s)))
		defer wj.JS_FreeValue(ctx, text)
		return wj.JS_Call(ctx, tag == .Bigint ? bigint_fn : symbol_of_fn, wj.UNDEFINED, 1, &text)
	case .Node: return wj.wj_wrap_node(ctx, read_le(r, 8))
	case .Window: return frames_window_value(ctx, api_decl.Navigable(read_le(r, 8)))
	case .Object:
		realm := read_le(r, 8)
		number := read_le(r, 8)
		kind := read_le(r, 1)
		args := [4]wj.JSValue{wj.new_float64(ctx, realm_self()), wj.new_float64(ctx, f64(realm)), wj.new_float64(ctx, f64(number)), wj.new_float64(ctx, f64(kind))}
		return wj.JS_Call(ctx, import_ref_fn, wj.UNDEFINED, 4, &args[0])
	case .Error:
		list := take_value(ctx, r)
		defer wj.JS_FreeValue(ctx, list)
		arg := list
		return wj.is_exception(list) ? list : wj.JS_Call(ctx, make_error_fn, wj.UNDEFINED, 1, &arg)
	case .List:
		n := read_le(r, 4)
		arr := wj.JS_NewArray(ctx)
		for i in 0 ..< n {
			x := take_value(ctx, r)
			if wj.is_exception(x) { wj.JS_FreeValue(ctx, arr); return x }
			wj.JS_SetPropertyUint32(ctx, arr, u32(i), x)
		}
		return arr
	}
	return wj.UNDEFINED
}

// ---- a request to another realm ----

// Runs `op` on object `number` of `realm`. `list_b`: `b` is an array, sent as a list. The value (counted), or an exception:
// what the other realm threw, as a value of this one.
frames_bridge_send :: proc "contextless" (ctx: ^wj.Context, realm: u64, op: u8, number: u64, a, b: wj.JSValue, list_a := false, list_b := false) -> wj.JSValue {
	context = jsb.glue_context()
	req: Pack
	defer pack_free(&req)
	ok := pack_u8(&req, op) && pack_le(&req, number, 8)
	ok = ok && (list_a ? put_list(ctx, &req, a) : put_value(ctx, &req, a))
	ok = ok && (list_b ? put_list(ctx, &req, b) : put_value(ctx, &req, b))
	if !ok { return wj.is_exception(wj.JS_GetException(ctx)) ? wj.EXCEPTION : wj.JS_Throw(ctx, wj.JS_GetException(ctx)) }
	size: u32
	jsb.host(&size, api_decl.Frame_bridge, wj.wr_Frame_bridge, realm, abi.Bytes(pack_slice(&req)))
	if size == 0 { return wj.UNDEFINED }   // that realm is gone, or out of reach now
	reply: abi.Bytes
	jsb.host(&reply, api_decl.Frame_bridgeReply, wj.wr_Frame_bridgeReply)
	bytes := ([]u8)(reply)
	r := Reader{p = bytes}
	thrown := read_le(&r, 1) != 0
	v := take_value(ctx, &r)
	if thrown && !wj.is_exception(v) { return wj.JS_Throw(ctx, v) }
	return v
}

// send(realm, op, number, a, b), for web_bridge.js
@(private = "file")
bridge_native_send :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	realm, op, number: f64
	wj.JS_ToFloat64(ctx, &realm, wj.arg(argc, argv, 0))
	wj.JS_ToFloat64(ctx, &op, wj.arg(argc, argv, 1))
	wj.JS_ToFloat64(ctx, &number, wj.arg(argc, argv, 2))
	o := u8(op)
	return frames_bridge_send(ctx, u64(realm), o, u64(number), wj.arg(argc, argv, 3), wj.arg(argc, argv, 4),
		list_a = o == OP_CONSTRUCT, list_b = o == OP_APPLY || o == OP_DEFINE)
}

// ---- a request from another realm ----

// Runs a request (bytes in this realm's memory, wj_alloc'ed by the browser): the address of the reply, u32 length then
// a thrown flag and a value; malloc'ed, freed by the browser (wj_free).
@(export, link_name = "wj_bridge_dispatch")
wj_bridge_dispatch :: proc "c" (data, data_len: u32) -> u32 {
	context = jsb.glue_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	r := Reader{p = ([^]u8)(uintptr(data))[:data_len]}
	op := read_le(&r, 1)
	number := read_le(&r, 8)
	a := take_value(ctx, &r)
	defer wj.JS_FreeValue(ctx, a)
	b := take_value(ctx, &r)
	defer wj.JS_FreeValue(ctx, b)
	args := [4]wj.JSValue{wj.new_float64(ctx, f64(op)), wj.new_float64(ctx, f64(number)), a, b}
	v := wj.is_exception(a) || wj.is_exception(b) ? wj.EXCEPTION : wj.JS_Call(ctx, dispatch_fn, wj.UNDEFINED, 4, &args[0])
	thrown := wj.is_exception(v)
	if thrown { v = wj.JS_GetException(ctx) }
	defer wj.JS_FreeValue(ctx, v)
	reply: Pack
	pack_le(&reply, 0, 4)
	pack_u8(&reply, thrown ? 1 : 0)
	lists := op == OP_KEYS || op == OP_GOPD
	ok: bool
	described := thrown ? wj.JS_Call(ctx, describe_error_fn, wj.UNDEFINED, 1, &v) : wj.UNDEFINED
	defer wj.JS_FreeValue(ctx, described)
	if wj.is_object(described) {
		ok = pack_u8(&reply, u8(Tag.Error)) && put_list(ctx, &reply, described)
	} else {
		ok = lists && wj.is_object(v) ? put_list(ctx, &reply, v) : put_value(ctx, &reply, v)
	}
	if !ok {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))   // what cannot be carried answers undefined
		reply.n = 5
		pack_u8(&reply, u8(Tag.Undefined))
	}
	size := u32(reply.n)
	(^u32le)(reply.p)^ = u32le(size)
	return u32(uintptr(reply.p))
}

// ---- for the WindowProxy (frames.odin) ----

// The realm of a window the calling document may reach, 0 otherwise.
frames_bridge_realm :: proc "contextless" (id: api_decl.Navigable) -> u64 {
	context = jsb.glue_context()
	realm: u64
	jsb.host(&realm, api_decl.Frame_realmOf, wj.wr_Frame_realmOf, id)
	return realm
}

frames_bridge_get :: proc "contextless" (ctx: ^wj.Context, realm: u64, key: wj.JSValue) -> wj.JSValue {
	return frames_bridge_send(ctx, realm, OP_GET, GLOBAL_NUMBER, key, wj.UNDEFINED)
}
frames_bridge_set :: proc "contextless" (ctx: ^wj.Context, realm: u64, key, value: wj.JSValue) -> wj.JSValue {
	return frames_bridge_send(ctx, realm, OP_SET, GLOBAL_NUMBER, key, value)
}
frames_bridge_has :: proc "contextless" (ctx: ^wj.Context, realm: u64, key: wj.JSValue) -> wj.JSValue {
	return frames_bridge_send(ctx, realm, OP_HAS, GLOBAL_NUMBER, key, wj.UNDEFINED)
}
frames_bridge_delete :: proc "contextless" (ctx: ^wj.Context, realm: u64, key: wj.JSValue) -> wj.JSValue {
	return frames_bridge_send(ctx, realm, OP_DELETE, GLOBAL_NUMBER, key, wj.UNDEFINED)
}
// [value, writable, enumerable, configurable, get, set], or undefined
frames_bridge_descriptor :: proc "contextless" (ctx: ^wj.Context, realm: u64, key: wj.JSValue) -> wj.JSValue {
	return frames_bridge_send(ctx, realm, OP_GOPD, GLOBAL_NUMBER, key, wj.UNDEFINED)
}
// [hasValue, value, writable, enumerable, configurable, get, set, hasWritable, hasEnumerable, hasConfigurable]
frames_bridge_define :: proc "contextless" (ctx: ^wj.Context, realm: u64, key, desc: wj.JSValue) -> wj.JSValue {
	return frames_bridge_send(ctx, realm, OP_DEFINE, GLOBAL_NUMBER, key, desc, list_b = true)
}

// document.<method>() of a document of another realm, run in that realm: what comes back is its object (a Range its Selection takes).
frames_bridge_document_call :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, doc: u64, method: cstring) -> wj.JSValue {
	context = jsb.glue_context()
	id: api_decl.Navigable
	jsb.host(&id, api_decl.Frame_ofDocument, wj.wr_Frame_ofDocument, api_decl.Node(doc))
	realm := id != 0 ? frames_bridge_realm(id) : 0
	if realm == 0 { return wj.wj_throw_gone(ctx) }
	key := wj.new_string(ctx, "Document")
	defer wj.JS_FreeValue(ctx, key)
	ctor := frames_bridge_get(ctx, realm, key)
	if wj.is_exception(ctor) { return ctor }
	defer wj.JS_FreeValue(ctx, ctor)
	proto := wj.JS_GetPropertyStr(ctx, ctor, "prototype")
	if wj.is_exception(proto) { return proto }
	defer wj.JS_FreeValue(ctx, proto)
	fn := wj.JS_GetPropertyStr(ctx, proto, method)
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	return wj.JS_Call(ctx, fn, this_val, 0, nil)
}

// At pre-initialization: the bridge's JavaScript, so that it holds this realm's pristine built-ins.
frames_bridge_install :: proc "contextless" (ctx: ^wj.Context) {
	fn := eval_prelude(ctx, "web_bridge.js", #load("web_bridge.js"))
	if wj.is_exception(fn) { return }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	wj.JS_DefinePropertyValueStr(ctx, native, "send", wj.new_cfunction(ctx, bridge_native_send, "send", 5), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, native, "global", wj.JS_DupValue(ctx, wj.wj_the_realm.global), wj.PROP_C_W_E)
	arg := native
	bridge = wj.JS_Call(ctx, fn, wj.UNDEFINED, 1, &arg)
	if wj.is_exception(bridge) { wj.wj_report_pending(ctx); return }
	dispatch_fn = wj.JS_GetPropertyStr(ctx, bridge, "dispatch")
	import_ref_fn = wj.JS_GetPropertyStr(ctx, bridge, "importRef")
	export_ref_fn = wj.JS_GetPropertyStr(ctx, bridge, "exportRef")
	symbol_name_fn = wj.JS_GetPropertyStr(ctx, bridge, "symbolName")
	symbol_of_fn = wj.JS_GetPropertyStr(ctx, bridge, "symbolOf")
	bigint_fn = wj.JS_GetPropertyStr(ctx, bridge, "bigint")
	describe_error_fn = wj.JS_GetPropertyStr(ctx, bridge, "describeError")
	make_error_fn = wj.JS_GetPropertyStr(ctx, bridge, "makeError")
}
