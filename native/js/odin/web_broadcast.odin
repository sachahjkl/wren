// web_broadcast.odin: BroadcastChannel. Each object is a port end of the browser's router keyed by the realm's origin
// and the channel's name: a posted message is serialized once and copied by the browser to every other end of the
// channel, in any realm; it comes back here through wj_port_message (web_message.c), which finds the object by its end.
// An open channel stays alive (it may receive); close() lets it go. Ported from native/js/runtime/web_broadcast.c;
// same wjr_* symbols and behaviour. web_bound_add/remove are web_message.odin's; web_message_event lives in
// web_socket.odin.
package odin_glue

import "../odin/wj"



@(private = "file")
Bc_Impl :: struct {
	end:    u64,
	name:   wj.JSValue,
	closed: bool,
}

@(private = "file") bc_free :: proc "c" (p: rawptr) {
	b := (^Bc_Impl)(p)
	wj.JS_FreeValueRT(wj.web_rt(), b.name)
	wj.libc_free(p)
}
@(private = "file") bc_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) { wj.wj_mark(rt, (^Bc_Impl)(p).name, mark_func) }

@(private = "file") iface_broadcast := i32(-2)
@(private = "file") iface_messageevent := i32(-2)
@(private = "file") broadcast_iface :: proc "c" () -> i32 {
	if iface_broadcast == -2 { iface_broadcast = wj.iface("BroadcastChannel") }
	return iface_broadcast
}
@(private = "file") messageevent_iface :: proc "c" () -> i32 {
	if iface_messageevent == -2 { iface_messageevent = wj.iface("MessageEvent") }
	return iface_messageevent
}

@(export, link_name = "wjr_BroadcastChannel_constructor")
wjr_BroadcastChannel_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor BroadcastChannel requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "BroadcastChannel", 1, argc) }
	name: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &name, 0, nil) { return wj.EXCEPTION }
	b := (^Bc_Impl)(wj.libc_calloc(1, size_of(Bc_Impl)))
	if b == nil { wj.wj_str_free(ctx, &name); return wj.JS_ThrowOutOfMemory(ctx) }
	b.name = wj.JS_NewStringLen(ctx, name.ptr, name.len)
	b.end = wj.wr_Broadcast_open(name.ptr, u32(name.len))
	wj.wj_str_free(ctx, &name)
	obj := wj.wj_wrap_owned(ctx, wj.wr_EventTarget_create(), broadcast_iface(), new_target)
	if wj.is_exception(obj) { if b.end != 0 { wj.wr_Port_close(b.end) }; bc_free(b); return obj }
	wj.web_set_impl(obj, b, bc_free, bc_mark)
	if b.end != 0 { web_bound_add(ctx, b.end, obj) }
	return obj
}

@(private = "file") bc_this :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> ^Bc_Impl {
	// the C reads wj_this(...)->impl; web_this_impl returns that impl directly (the object is engine-made)
	return (^Bc_Impl)(wj.web_this_impl(ctx, v, broadcast_iface()))
}

@(export, link_name = "wjr_BroadcastChannel_get_name")
wjr_BroadcastChannel_get_name :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	b := bc_this(ctx, this_val)
	return b != nil ? wj.JS_DupValue(ctx, b.name) : wj.EXCEPTION
}

@(export, link_name = "wjr_BroadcastChannel_postMessage")
wjr_BroadcastChannel_postMessage :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := bc_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "BroadcastChannel.postMessage", 1, argc) }
	if b.closed { return wj.wj_throw_dom(ctx, "InvalidStateError", "Failed to execute 'postMessage' on 'BroadcastChannel': Channel is closed") }
	length: uint
	data := web_clone_serialize(ctx, argv[0], &length)
	if data == nil { return wj.EXCEPTION }
	st := b.end != 0 ? wj.wr_Broadcast_post(b.end, data, u32(length)) : i32(0)
	web_clone_free(ctx, data)
	return st < 0 ? wj.wj_throw_status(ctx, st, "BroadcastChannel.postMessage") : wj.UNDEFINED
}

@(export, link_name = "wjr_BroadcastChannel_close")
wjr_BroadcastChannel_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := bc_this(ctx, this_val)
	if b == nil { return wj.EXCEPTION }
	if b.closed { return wj.UNDEFINED }
	b.closed = true
	if b.end != 0 {
		end := b.end
		b.end = 0
		wj.wr_Port_close(end)
		web_bound_remove(end)   // (may drop the last reference to `this`: nothing of it is used after)
	}
	return wj.UNDEFINED
}

// A message of the channel arrives (wj_port_message): a MessageEvent with the realm's origin, or messageerror.
@(export, link_name = "web_broadcast_deliver")
web_broadcast_deliver :: proc "c" (ctx: ^wj.Context, channel: wj.JSValue, data: [^]u8, length: uint) {
	o := wj.wj_unwrap(channel, broadcast_iface())
	b := (^Bc_Impl)(wj.impl_of(o))
	if b == nil || b.closed { return }
	value := web_clone_deserialize(ctx, data, length)
	ev: wj.JSValue
	if wj.is_exception(value) {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		ev = wj.web_event_new(ctx, messageevent_iface(), "messageerror", false, false)
	} else {
		origin := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "origin")
		os := wj.is_string(origin) ? wj.to_cstring(ctx, origin) : nil
		ev = web_message_event(ctx, value, os != nil ? os : "", wj.NULL)
		if os != nil { wj.free_cstring(ctx, os) }
		wj.JS_FreeValue(ctx, origin)
		wj.JS_FreeValue(ctx, value)
	}
	if wj.is_exception(ev) { wj.wj_report_pending(ctx); return }
	wj.web_event_fire(ctx, channel, ev)
	wj.JS_FreeValue(ctx, ev)
}
