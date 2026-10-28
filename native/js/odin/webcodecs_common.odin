// webcodecs_common.odin: what the WebCodecs domains share (web_webcodecs*.odin): the callback records of the decoders,
// isConfigSupported, the string-enum tables of the dictionaries, and the CanvasImageSource handle (also the 2D
// canvas's). Package odin_glue: a helper of the domains, not of the layer.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// ---- a decoder's two JS callbacks, kept by slot ----
//
// The host carries `user` = 16 bits of generation | 16 bits of slot and calls the decoder's wj_cb_* exports by table
// index; a record released (close) bumps its generation, so a late callback of a closed decoder finds nothing. Raw
// libc memory, as the C's realloc (the table is the module's, not a realm's).

Codec_Rec :: struct {
	used:   bool,
	gen:    u32,
	output: wj.JSValue,   // counted while used
	error:  wj.JSValue,
	host:   u64,
}

Codec_Table :: struct {
	recs:     [^]Codec_Rec,
	cap:      u32,
	count:    u32,
	free:     [^]u32,
	free_n:   u32,
	free_cap: u32,
}

codec_alloc :: proc "contextless" (t: ^Codec_Table) -> u32 {
	if t.free_n > 0 { t.free_n -= 1; return t.free[t.free_n] }
	if t.count == t.cap {
		cap := t.cap != 0 ? t.cap * 2 : 8
		n := ([^]Codec_Rec)(wj.libc_realloc(t.recs, uint(cap) * size_of(Codec_Rec)))
		if n == nil { return max(u32) }
		for i in t.cap ..< cap { n[i] = {} }
		t.recs = n
		t.cap = cap
	}
	t.count += 1
	return t.count - 1
}

codec_release :: proc "contextless" (ctx: ^wj.Context, t: ^Codec_Table, slot: u32) {
	if slot >= t.count || !t.recs[slot].used { return }
	r := &t.recs[slot]
	wj.JS_FreeValue(ctx, r.output)
	wj.JS_FreeValue(ctx, r.error)
	r.used = false
	r.gen += 1
	r.output = wj.UNDEFINED
	r.error = wj.UNDEFINED
	if t.free_n == t.free_cap {
		c := t.free_cap != 0 ? t.free_cap * 2 : 8
		if n := ([^]u32)(wj.libc_realloc(t.free, uint(c) * size_of(u32))); n != nil { t.free = n; t.free_cap = c }
	}
	if t.free_n < t.free_cap { t.free[t.free_n] = slot; t.free_n += 1 }
}

codec_user :: #force_inline proc "contextless" (t: ^Codec_Table, slot: u32) -> i32 {
	return i32(((t.recs[slot].gen & 0xFFFF) << 16) | (slot & 0xFFFF))
}

codec_from_user :: proc "contextless" (t: ^Codec_Table, user: i32) -> ^Codec_Rec {
	slot := u32(user) & 0xFFFF
	gen := (u32(user) >> 16) & 0xFFFF
	if slot >= t.count || !t.recs[slot].used || (t.recs[slot].gen & 0xFFFF) != gen { return nil }
	return &t.recs[slot]
}

// host -> engine: a decoded object (a VideoFrame / AudioData handle of interface `iface`) for the output callback
codec_output :: proc "contextless" (t: ^Codec_Table, user: i32, lo, hi: u32, iface: i32) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	r := codec_from_user(t, user)
	if r == nil { return }
	v := wj.wj_wrap_owned(ctx, u64(hi) << 32 | u64(lo), iface, wj.UNDEFINED)
	if wj.is_exception(v) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return }
	wj.JS_FreeValue(ctx, wj.JS_Call(ctx, r.output, wj.UNDEFINED, 1, &v))
	wj.JS_FreeValue(ctx, v)
}

// host -> engine: an error code for the error callback
codec_error :: proc "contextless" (t: ^Codec_Table, user: i32, code: i32) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	r := codec_from_user(t, user)
	if r == nil { return }
	e := wj.web_error_value(ctx, code, nil, 0)
	wj.JS_FreeValue(ctx, wj.JS_Call(ctx, r.error, wj.UNDEFINED, 1, &e))
	wj.JS_FreeValue(ctx, e)
}

// new VideoDecoder(init) / new AudioDecoder(init): the callbacks in a record, the host decoder created with the two
// exports (output, error) and the record's `user`, the slot kept on the wrapper for close().
codec_construct :: proc(ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, t: ^Codec_Table,
	$D: typeid, imp: $R, $H: typeid, on_output, on_error: rawptr, name: cstring) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': Please use the 'new' operator.", name) }
	if argc < 1 || !wj.is_object(argv[0]) { return wj.JS_ThrowTypeError(ctx, "Failed to construct '%s': an init is required.", name) }
	out := wj.JS_GetPropertyStr(ctx, argv[0], "output")
	err := wj.JS_GetPropertyStr(ctx, argv[0], "error")
	if !wj.JS_IsFunction(ctx, out) || !wj.JS_IsFunction(ctx, err) {
		wj.JS_FreeValue(ctx, out); wj.JS_FreeValue(ctx, err)
		return wj.JS_ThrowTypeError(ctx, "%sInit needs 'output' and 'error' callbacks.", name)
	}
	slot := codec_alloc(t)
	if slot == max(u32) { wj.JS_FreeValue(ctx, out); wj.JS_FreeValue(ctx, err); return wj.JS_ThrowOutOfMemory(ctx) }
	t.recs[slot] = {used = true, gen = t.recs[slot].gen, output = out, error = err}
	user := codec_user(t, slot)
	h: abi.Owned(H)
	if st := jsb.host(&h, D, imp, wj.table_index(on_output), user, wj.table_index(on_error), user); st != .None {
		codec_release(ctx, t, slot)
		return wj.wj_throw_status(ctx, i32(st), name)
	}
	t.recs[slot].host = u64(h.handle)
	dec := wj.wj_wrap_owned(ctx, u64(h.handle), jsb.iface_of(H), new_target)
	if wj.is_object(dec) { wj.web_extra_set(ctx, dec, "slot", wj.new_int32(i32(slot))) }
	return dec
}

// close(): the record goes with the decoder (its callbacks are released)
codec_forget :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, t: ^Codec_Table) {
	sv := wj.web_extra_get(ctx, this_val, "slot")
	slot := i32(-1)
	if wj.is_number(sv) { wj.JS_ToInt32(ctx, &slot, sv) }
	if slot >= 0 { codec_release(ctx, t, u32(slot)) }
}

// The `codec` string member of a config (nil and false when it is not a string).
config_codec :: proc "contextless" (ctx: ^wj.Context, config: wj.JSValue, codec: ^wj.Str) -> bool {
	cv := wj.JS_GetPropertyStr(ctx, config, "codec")
	ok := wj.is_string(cv) && wj.wj_to_str(ctx, cv, codec, 0, "")
	wj.JS_FreeValue(ctx, cv)
	return ok
}

// isConfigSupported(config) of the decoders and encoders: a promise of {supported, config}
codec_is_config_supported :: proc(ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, $D: typeid, imp: $R) -> wj.JSValue {
	if argc < 1 || !wj.is_object(argv[0]) { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "isConfigSupported: a config is required.")) }
	codec: wj.Str
	if !config_codec(ctx, argv[0], &codec) { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "isConfigSupported: 'codec' must be a string.")) }
	sup: bool
	jsb.host(&sup, D, imp, str_text(codec))
	wj.wj_str_free(ctx, &codec)
	res := wj.JS_NewObject(ctx)
	wj.JS_DefinePropertyValueStr(ctx, res, "supported", wj.new_bool(sup), wj.PROP_C_W_E)
	wj.JS_DefinePropertyValueStr(ctx, res, "config", wj.JS_DupValue(ctx, argv[0]), wj.PROP_C_W_E)
	return wj.web_promise_resolved(ctx, res)
}

// A promise settled by a host status: resolved with undefined, or rejected with its error (flush()).
status_promise :: proc "contextless" (ctx: ^wj.Context, st: abi.Api_Error) -> wj.JSValue {
	if st != .None { return wj.web_promise_rejected(ctx, wj.web_error_value(ctx, i32(st), nil, 0)) }
	return wj.web_promise_resolved(ctx, wj.UNDEFINED)
}

// "unconfigured" / "configured" / "closed" of a codec's state
codec_state :: proc "contextless" (ctx: ^wj.Context, s: i32) -> wj.JSValue {
	states := [3]cstring{"unconfigured", "configured", "closed"}
	return wj.new_string(ctx, states[s >= 0 && s < 3 ? s : 0])
}

// ---- strings ----

// A converted string as an Odin string (empty for a nil pointer), for a declaration's string argument.
str_text :: #force_inline proc "contextless" (s: wj.Str) -> string { return s.ptr != nil ? string(s.ptr[:s.len]) : "" }

// The index of `s` among names[1:] (names[0] is the host's "none"), -1 when it is none of them.
enum_index_from :: proc "contextless" (names: []string, s: []u8) -> i32 {
	for i in 1 ..< len(names) { if names[i] == string(s) { return i32(i) } }
	return -1
}

// The enum index of a value among names: -1 when it is not a string or none of them.
value_enum :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, names: []string) -> i32 {
	if !wj.is_string(v) { return -1 }
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return -1 }
	r := enum_index_from(names, wj.str_slice(s))
	wj.wj_str_free(ctx, &s)
	return r
}

// The enum index of the string member `key` of `obj` among names (-1 when absent, not a string or unknown).
member_enum :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, key: cstring, names: []string) -> i32 {
	v := wj.JS_GetPropertyStr(ctx, obj, key)
	r := value_enum(ctx, v, names)
	wj.JS_FreeValue(ctx, v)
	return r
}

// ---- CanvasImageSource ----

@(private = "file") HTMLImageElement  :: distinct u64
@(private = "file") HTMLCanvasElement :: distinct u64
@(private = "file") HTMLVideoElement  :: distinct u64
@(private = "file") ImageBitmap       :: distinct u64
@(private = "file") OffscreenCanvas   :: distinct u64

// The handle of a CanvasImageSource (an element's or an object's, a VideoFrame included: the host draws its captured
// pixels), 0 when `v` is none (no exception).
image_source_handle :: proc "contextless" (v: wj.JSValue) -> u64 {
	if !wj.is_object(v) { return 0 }
	ifaces := [6]i32{
		jsb.iface_of(HTMLImageElement), jsb.iface_of(HTMLCanvasElement), jsb.iface_of(HTMLVideoElement),
		jsb.iface_of(ImageBitmap), jsb.iface_of(OffscreenCanvas), jsb.iface_of(api_decl.VideoFrame),
	}
	for i in ifaces {
		if o := wj.wj_unwrap(v, i); o != nil && o.handle != 0 { return o.handle }
	}
	return 0
}
