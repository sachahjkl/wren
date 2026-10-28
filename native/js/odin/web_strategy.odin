// web_strategy.odin: CountQueuingStrategy and ByteLengthQueuingStrategy (Streams Standard), ported from
// native/js/runtime/web_strategy.c as the first proof that Wren's JavaScript glue can be written in Odin (see
// docs/js/odin-glue.md and native/js/odin_spike for the link proof). Behaviour and the wjr_* symbol names are identical
// to the C version, so the generated binding table (native/js/gen/bindings.c) resolves to these without any change; the
// C file is dropped from the build (tools/build_js.ps1).
//
// A strategy is a platform object whose engine-owned data is a highWaterMark. The size function of a kind is the same
// object for every strategy of that kind in a realm, kept on the global's hidden state (web_extra), so scripts get an
// identical function back each time, as the specification and the C version require.
package odin_glue

import "../odin/wj"

Strategy_Impl :: struct {
	hwm: f64,
}

// CountQueuingStrategy size(chunk) returns 1. The signature is a JSCFunction (wj.Native).
@(private = "file")
count_size :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(1)
}

// ByteLengthQueuingStrategy size(chunk) returns ? GetV(chunk, "byteLength").
@(private = "file")
byte_length_size :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.JS_GetPropertyStr(ctx, wj.arg(argc, argv, 0), "byteLength")
}

@(private = "file")
free_impl :: proc "c" (p: rawptr) { wj.free(p) }

@(private = "file")
construct :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor %s requires 'new'", name) }
	init := wj.arg(argc, argv, 0)
	if argc < 1 { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': 1 argument required, but only 0 present.", name) }
	if !wj.web_dict_check(ctx, init, "QueuingStrategyInit") { return wj.EXCEPTION }
	v := wj.UNDEFINED
	if !wj.web_dict_get(ctx, init, "highWaterMark", &v) { return wj.EXCEPTION }
	if wj.is_undefined(v) { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': required member highWaterMark is undefined.", name) }
	h: f64
	r := wj.JS_ToFloat64(ctx, &h, v)
	wj.JS_FreeValue(ctx, v)
	if r < 0 { return wj.EXCEPTION }
	s := (^Strategy_Impl)(wj.malloc(size_of(Strategy_Impl)))
	if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	s.hwm = h
	obj := wj.wj_new_object(ctx, iface, s, free_impl)
	if wj.is_exception(obj) { return obj }
	proto := wj.JS_GetPropertyStr(ctx, new_target, "prototype")
	if wj.is_object(proto) { wj.JS_SetPrototype(ctx, obj, proto) }
	wj.JS_FreeValue(ctx, proto)
	return obj
}

// Interface indices resolved once (by name: robust against table renumbering).
@(private = "file") iface_count := i32(-2)   // -2 = not resolved yet
@(private = "file") iface_bytelen := i32(-2)

@(private = "file")
count_iface :: proc "c" () -> i32 {
	if iface_count == -2 { iface_count = wj.iface("CountQueuingStrategy") }
	return iface_count
}
@(private = "file")
bytelen_iface :: proc "c" () -> i32 {
	if iface_bytelen == -2 { iface_bytelen = wj.iface("ByteLengthQueuingStrategy") }
	return iface_bytelen
}

@(export, link_name = "wjr_CountQueuingStrategy_constructor")
wjr_CountQueuingStrategy_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return construct(ctx, new_target, argc, argv, count_iface(), "CountQueuingStrategy")
}

@(export, link_name = "wjr_ByteLengthQueuingStrategy_constructor")
wjr_ByteLengthQueuingStrategy_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return construct(ctx, new_target, argc, argv, bytelen_iface(), "ByteLengthQueuingStrategy")
}

@(export, link_name = "wjr_CountQueuingStrategy_get_highWaterMark")
wjr_CountQueuingStrategy_get_highWaterMark :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s := (^Strategy_Impl)(wj.web_this_impl(ctx, t, count_iface()))
	return s != nil ? wj.new_float64(ctx, s.hwm) : wj.EXCEPTION
}

@(export, link_name = "wjr_ByteLengthQueuingStrategy_get_highWaterMark")
wjr_ByteLengthQueuingStrategy_get_highWaterMark :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	s := (^Strategy_Impl)(wj.web_this_impl(ctx, t, bytelen_iface()))
	return s != nil ? wj.new_float64(ctx, s.hwm) : wj.EXCEPTION
}

// The realm's size function of a kind (made on first use, kept on the global's hidden state so every strategy of the
// kind shares the same function object).
@(private = "file")
size_function :: proc "c" (ctx: ^wj.Context, key: cstring, fn: wj.Native) -> wj.JSValue {
	f := wj.web_extra_get(ctx, wj.realm_global(), key)
	if wj.JS_IsFunction(ctx, f) { return f }
	wj.JS_FreeValue(ctx, f)
	f = wj.new_cfunction(ctx, fn, "size", 1)
	if !wj.is_exception(f) { wj.web_extra_set(ctx, wj.realm_global(), key, wj.JS_DupValue(ctx, f)) }
	return f
}

@(export, link_name = "wjr_CountQueuingStrategy_get_size")
wjr_CountQueuingStrategy_get_size :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.web_this_impl(ctx, t, count_iface()) == nil { return wj.EXCEPTION }
	return size_function(ctx, "countSize", count_size)
}

@(export, link_name = "wjr_ByteLengthQueuingStrategy_get_size")
wjr_ByteLengthQueuingStrategy_get_size :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	if wj.web_this_impl(ctx, t, bytelen_iface()) == nil { return wj.EXCEPTION }
	return size_function(ctx, "byteLengthSize", byte_length_size)
}
