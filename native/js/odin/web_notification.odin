// web_notification.odin: Notification (WHATWG Notifications API) over module notification (api/notification.widl,
// src/page/notification.odin). new Notification() asks the browser to show it; the object then waits on
// Notification_next: each answer is an event it fires ("show", "click", then "close" at its end), and it waits again
// until the end. A notification that could not be shown (no permission, no notification service) fires "error".
// Notification.permission is generated (bindings_gen.odin); requestPermission takes the deprecated callback too.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file")
Note_Impl :: struct {
	id:                     u64,
	title, body, tag:       wj.JSValue,
	silent:                 bool,
}

// The answers of Notification_next (src/page/notification.odin).
@(private = "file") NOTE_CLICK :: 0
@(private = "file") NOTE_GONE  :: 1
@(private = "file") NOTE_SHOWN :: 2

@(private = "file") note_free :: proc "c" (p: rawptr) {
	n := (^Note_Impl)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, n.title); wj.JS_FreeValueRT(rt, n.body); wj.JS_FreeValueRT(rt, n.tag)
	wj.libc_free(p)
}
@(private = "file") note_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	n := (^Note_Impl)(p)
	wj.wj_mark(rt, n.title, mark_func); wj.wj_mark(rt, n.body, mark_func); wj.wj_mark(rt, n.tag, mark_func)
}

@(private = "file") iface_note := i32(-2)
@(private = "file") note_iface :: proc "c" () -> i32 {
	if iface_note == -2 { iface_note = wj.iface("Notification") }
	return iface_note
}

// A string member of the options dictionary (`def` when absent). False with an exception pending.
@(private = "file")
option_string :: proc "c" (ctx: ^wj.Context, opt: wj.JSValue, name: cstring, out: ^wj.Str) -> bool {
	v := wj.UNDEFINED
	if !wj.is_undefined(opt) && !wj.is_null(opt) {
		if !wj.web_dict_get(ctx, opt, name, &v) { return false }
	}
	defer wj.JS_FreeValue(ctx, v)
	if wj.is_undefined(v) { out^ = {}; return true }
	return wj.wj_to_str(ctx, v, out, 0, nil)
}

// Waits for what happens next to notification `id` of `obj`.
@(private = "file")
note_wait :: proc "c" (ctx: ^wj.Context, obj: wj.JSValue, id: u64) {
	p := wj.wj_promise_from_host(ctx, wj.wr_Notification_next(id), wj.HOST_NUMBER, note_settle, obj)
	wj.JS_FreeValue(ctx, p)
}

@(private = "file")
note_settle :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	n := (^Note_Impl)(wj.web_this_impl(ctx, data, note_iface()))
	if n == nil { return wj.UNDEFINED }
	if n.id == 0 {
		wj.web_fire_simple(ctx, data, "error")   // (not shown: no permission, no notification service)
		return wj.UNDEFINED
	}
	switch value {
	case NOTE_SHOWN: wj.web_fire_simple(ctx, data, "show")
	case NOTE_CLICK: wj.web_fire_simple(ctx, data, "click")
	case:
		n.id = 0
		wj.web_fire_simple(ctx, data, "close")
		return wj.UNDEFINED
	}
	note_wait(ctx, data, n.id)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Notification_constructor")
wjr_Notification_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor Notification requires 'new'") }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Notification", 1, argc) }
	opt := wj.arg(argc, argv, 1)
	if !wj.is_undefined(opt) && !wj.web_dict_check(ctx, opt, "NotificationOptions") { return wj.EXCEPTION }
	title, body, tag: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &title, 0, nil) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &title)
	if !option_string(ctx, opt, "body", &body) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &body)
	if !option_string(ctx, opt, "tag", &tag) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &tag)
	silent := false
	if !wj.is_undefined(opt) && !wj.is_null(opt) {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, opt, "silent", &v) { return wj.EXCEPTION }
		silent = wj.JS_ToBool(ctx, v) > 0
		wj.JS_FreeValue(ctx, v)
	}
	n := (^Note_Impl)(wj.libc_calloc(1, size_of(Note_Impl)))
	if n == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	n.title = wj.JS_NewStringLen(ctx, title.ptr, title.len)
	n.body = wj.JS_NewStringLen(ctx, body.ptr, body.len)
	n.tag = wj.JS_NewStringLen(ctx, tag.ptr, tag.len)
	n.silent = silent
	target: api_decl.EventTarget
	jsb.host(&target, api_decl.EventTarget_create, wj.wr_EventTarget_create)
	obj := wj.wj_wrap_owned(ctx, u64(target), note_iface(), new_target)
	if wj.is_exception(obj) { note_free(n); return obj }
	wj.web_set_impl(obj, n, note_free, note_mark)
	n.id = wj.wr_Notification_show(title.ptr, u32(title.len), body.ptr, u32(body.len), tag.ptr, u32(tag.len), silent ? 1 : 0)
	note_wait(ctx, obj, n.id)   // (id 0: settles at once as gone, and fires "error")
	return obj
}

@(private = "file") note_this :: proc "c" (ctx: ^wj.Context, v: wj.JSValue) -> ^Note_Impl {
	return (^Note_Impl)(wj.web_this_impl(ctx, v, note_iface()))
}

@(export, link_name = "wjr_Notification_get_title")
wjr_Notification_get_title :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	n := note_this(ctx, this_val)
	return n != nil ? wj.JS_DupValue(ctx, n.title) : wj.EXCEPTION
}

@(export, link_name = "wjr_Notification_get_body")
wjr_Notification_get_body :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	n := note_this(ctx, this_val)
	return n != nil ? wj.JS_DupValue(ctx, n.body) : wj.EXCEPTION
}

@(export, link_name = "wjr_Notification_get_tag")
wjr_Notification_get_tag :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	n := note_this(ctx, this_val)
	return n != nil ? wj.JS_DupValue(ctx, n.tag) : wj.EXCEPTION
}

@(export, link_name = "wjr_Notification_get_silent")
wjr_Notification_get_silent :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	n := note_this(ctx, this_val)
	return n != nil ? wj.JS_NewBool(ctx, n.silent) : wj.EXCEPTION
}

@(export, link_name = "wjr_Notification_close")
wjr_Notification_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n := note_this(ctx, this_val)
	if n == nil { return wj.EXCEPTION }
	if n.id != 0 { wj.wr_Notification_close(n.id) }   // ("close" fires when the system says it is gone)
	return wj.UNDEFINED
}

@(private = "file") NOTE_STATE_NAMES := [3]cstring{"default", "granted", "denied"}

@(private = "file")
settle_permission :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	name := wj.new_string(ctx, NOTE_STATE_NAMES[clamp(value, 0, 2)])
	if wj.JS_IsFunction(ctx, data) {   // (the deprecated callback: called with the state as well)
		args := [1]wj.JSValue{name}
		r := wj.JS_Call(ctx, data, wj.UNDEFINED, 1, &args[0])
		wj.JS_FreeValue(ctx, r)
	}
	return name
}

@(export, link_name = "wjr_Notification_static_requestPermission")
wjr_Notification_static_requestPermission :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.wj_promise_from_host(ctx, wj.wr_Notification_ask(), wj.HOST_NUMBER, settle_permission, wj.arg(argc, argv, 0))
}

_ :: abi
