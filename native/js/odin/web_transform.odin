// web_transform.odin: TransformStream and TransformStreamDefaultController (Streams Standard §6), and the transform
// streams built on it: TextDecoderStream and TextEncoderStream (Encoding Standard), CompressionStream and
// DecompressionStream (Compression Standard). Ported from native/js/runtime/web_transform.c: same wjr_* symbols and
// behaviour.
//
// A transform stream is a WritableStream and a ReadableStream (web_writable.odin, web_stream.odin) made with an
// underlying sink and source of this file's functions, which run the specification's algorithms (the names in the
// comments are its own): writes wait while the readable side has backpressure, each chunk goes through the
// transformer's transform() (or a native one: the encoding and compression streams), close() runs flush() and closes
// the readable side, abort() and cancel() run the transformer's cancel() and error the other side. The objects
// reference each other (stream, sides, their sink and source functions, controller): all are marked, a collection
// takes them together.
package odin_glue

import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// The native transformers: what each keeps, and its transform / flush below (native_transform, native_flush).
@(private = "file") Decoder_State :: struct { decoder: wj.JSValue }                  // a TextDecoder
@(private = "file") Encoder_State :: struct { encoder: wj.JSValue, pending_high: i32 }   // a TextEncoder; a high surrogate that ended the last chunk (-1: none)
@(private = "file") Zip_State     :: struct { host: api_decl.Compressor }            // the browser's compressor (owned)
@(private = "file") Native_Transformer :: union { Decoder_State, Encoder_State, Zip_State }

@(private = "file")
TS :: struct {
	readable, writable, controller: wj.JSValue,
	rctrl, wctrl:                   wj.JSValue,   // the sides' controllers, given to their start
	transformer, transform_fn, flush_fn, cancel_fn: wj.JSValue,   // undefined once cleared (ClearAlgorithms)
	start_promise:                  wj.JSValue,
	backpressure:                   Maybe(bool),  // nil: not set yet
	bp_promise, bp_resolve:         wj.JSValue,   // backpressureChangePromise and its resolving function
	finish_promise:                 wj.JSValue,   // the controller's finishPromise (undefined: none)
	finish_fn:                      [2]wj.JSValue,
	native:                         Native_Transformer,
	native_cleared:                 bool,         // ClearAlgorithms: the native transform and flush are gone too
}

@(private = "file")
TS_Controller :: struct {
	stream: wj.JSValue,
}

@(private = "file")
ts_values :: proc "contextless" (t: ^TS) -> [16]wj.JSValue {
	nv := wj.UNDEFINED
	switch n in t.native {
	case Decoder_State: nv = n.decoder
	case Encoder_State: nv = n.encoder
	case Zip_State:
	}
	return {t.readable, t.writable, t.controller, t.rctrl, t.wctrl, t.transformer, t.transform_fn, t.flush_fn,
		t.cancel_fn, t.start_promise, t.bp_promise, t.bp_resolve, t.finish_promise, t.finish_fn[0], t.finish_fn[1], nv}
}

@(private = "file")
ts_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	t := (^TS)(p)
	rt := wj.web_rt()
	for v in ts_values(t) { wj.JS_FreeValueRT(rt, v) }
	if z, ok := t.native.(Zip_State); ok && z.host != 0 { wj.wr_Object_release(u64(z.host)) }
	free(t)
}

@(private = "file")
ts_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) {
	for v in ts_values((^TS)(p)) { wj.wj_mark(rt, v, mf) }
}

@(private = "file")
tsc_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	wj.JS_FreeValueRT(wj.web_rt(), (^TS_Controller)(p).stream)
	free(p)
}

@(private = "file")
tsc_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) { wj.wj_mark(rt, (^TS_Controller)(p).stream, mf) }

// the impl of a transform stream object (TransformStream, TextDecoderStream...)
@(private = "file")
ts_of :: proc "contextless" (v: wj.JSValue) -> ^TS {
	o := wj.obj_of(v)
	return o != nil && o.impl_free == ts_free ? (^TS)(o.impl) : nil
}

// ---- the sides' controllers ----

@(private = "file")
rc_close :: proc "contextless" (ctx: ^wj.Context, t: ^TS) {
	wj.discard(ctx, wjr_ReadableStreamDefaultController_close(ctx, t.rctrl, 0, nil))
}

@(private = "file")
rc_error :: proc "contextless" (ctx: ^wj.Context, t: ^TS, e: wj.JSValue) {
	if web_stream_state(ctx, t.readable, nil) != 0 { return }
	ev := e
	wj.discard(ctx, wjr_ReadableStreamDefaultController_error(ctx, t.rctrl, 1, &ev))
}

// WritableStreamDefaultControllerErrorIfNeeded
@(private = "file")
wc_error_if_needed :: proc "contextless" (ctx: ^wj.Context, t: ^TS, e: wj.JSValue) {
	if web_writable_state(ctx, t.writable, nil) != 0 { return }
	ev := e
	wj.discard(ctx, wjr_WritableStreamDefaultController_error(ctx, t.wctrl, 1, &ev))
}

// the readable side's desiredSize; ok false when it is null (errored)
@(private = "file")
rc_desired :: proc "contextless" (ctx: ^wj.Context, t: ^TS) -> (d: f64, ok: bool) {
	v := wjr_ReadableStreamDefaultController_get_desiredSize(ctx, t.rctrl)
	ok = wj.is_number(v)
	if ok { wj.JS_ToFloat64(ctx, &d, v) }
	if wj.is_exception(v) { wj.drop_exception(ctx) }
	wj.JS_FreeValue(ctx, v)
	return
}

// ---- the stream's algorithms ----

// TransformStreamSetBackpressure
@(private = "file")
set_backpressure :: proc "contextless" (ctx: ^wj.Context, t: ^TS, bp: bool) {
	if !wj.is_undefined(t.bp_resolve) { wj.JS_FreeValue(ctx, wj.JS_Call(ctx, t.bp_resolve, wj.UNDEFINED, 0, nil)) }
	wj.JS_FreeValue(ctx, t.bp_promise)
	wj.JS_FreeValue(ctx, t.bp_resolve)
	f: [2]wj.JSValue
	t.bp_promise = wj.web_promise_new(ctx, &f[0])
	t.bp_resolve = f[0]
	wj.JS_FreeValue(ctx, f[1])
	t.backpressure = bp
}

// TransformStreamDefaultControllerClearAlgorithms
@(private = "file")
clear_algorithms :: proc "contextless" (ctx: ^wj.Context, t: ^TS) {
	wj.free_values(ctx, t.transform_fn, t.flush_fn, t.cancel_fn)
	t.transform_fn, t.flush_fn, t.cancel_fn = wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	t.native_cleared = true
}

@(private = "file")
has_backpressure :: #force_inline proc "contextless" (t: ^TS) -> bool { return t.backpressure.? or_else false }

// TransformStreamUnblockWrite
@(private = "file")
unblock_write :: proc "contextless" (ctx: ^wj.Context, t: ^TS) { if has_backpressure(t) { set_backpressure(ctx, t, false) } }

// TransformStreamErrorWritableAndUnblockWrite
@(private = "file")
error_writable_and_unblock :: proc "contextless" (ctx: ^wj.Context, t: ^TS, e: wj.JSValue) {
	clear_algorithms(ctx, t)
	wc_error_if_needed(ctx, t, e)
	unblock_write(ctx, t)
}

// TransformStreamError
@(private = "file")
ts_error :: proc "contextless" (ctx: ^wj.Context, t: ^TS, e: wj.JSValue) {
	rc_error(ctx, t, e)
	error_writable_and_unblock(ctx, t, e)
}

// TransformStreamDefaultControllerEnqueue: false with an exception pending
@(private = "file")
ts_enqueue :: proc "contextless" (ctx: ^wj.Context, t: ^TS, chunk: wj.JSValue) -> bool {
	if web_stream_state(ctx, t.readable, nil) != 0 {
		wj.JS_ThrowTypeError(ctx, "Readable side is not in a state that permits enqueue")
		return false
	}
	c := chunk
	r := wjr_ReadableStreamDefaultController_enqueue(ctx, t.rctrl, 1, &c)
	if wj.is_exception(r) {
		e := wj.JS_GetException(ctx)
		error_writable_and_unblock(ctx, t, e)
		stored := wj.UNDEFINED
		web_stream_state(ctx, t.readable, &stored)
		wj.JS_FreeValue(ctx, e)
		wj.JS_Throw(ctx, stored)
		return false
	}
	wj.JS_FreeValue(ctx, r)
	d, ok := rc_desired(ctx, t)
	bp := !ok || d <= 0
	if bp && !has_backpressure(t) { set_backpressure(ctx, t, true) }
	return true
}

@(private = "file")
rejected_with_pending :: #force_inline proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	return wj.web_promise_rejected(ctx, wj.JS_GetException(ctx))
}

// a callback's result as a promise (an exception: a rejected one)
@(private = "file")
promise_call :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, this_val: wj.JSValue, args: []wj.JSValue) -> wj.JSValue {
	if !wj.JS_IsFunction(ctx, fn) { return wj.web_promise_resolved(ctx, wj.UNDEFINED) }
	r := wj.JS_Call(ctx, fn, this_val, i32(len(args)), raw_data(args))
	if wj.is_exception(r) { return rejected_with_pending(ctx) }
	return wj.web_promise_take(ctx, r)
}

// The algorithms the sink, the source and their reactions run (the `magic` of one native function).
@(private = "file")
Step :: enum i32 {
	W_Start, W_Write, W_Close, W_Abort, R_Start, R_Pull, R_Cancel,
	After_Backpressure, Transform_Failed, Close_Ok, Close_Failed, Abort_Ok, Abort_Failed, Cancel_Ok, Cancel_Failed,
}

// p.then(ok, err) with the steps' function (nil: none), data = [the transform stream, extra]
@(private = "file")
then_ts :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue, ok, err: Maybe(Step), ts_obj: wj.JSValue, extra: wj.JSValue) -> wj.JSValue {
	d := [2]wj.JSValue{ts_obj, extra}
	fok, ferr := wj.UNDEFINED, wj.UNDEFINED
	if s, has := ok.?; has { fok = wj.JS_NewCFunctionData(ctx, algo, 1, i32(s), 2, &d[0]) }
	if s, has := err.?; has { ferr = wj.JS_NewCFunctionData(ctx, algo, 1, i32(s), 2, &d[0]) }
	then := wj.JS_GetPropertyStr(ctx, p, "then")
	args := [2]wj.JSValue{fok, ferr}
	r := wj.JS_Call(ctx, then, p, 2, &args[0])
	wj.free_values(ctx, then, fok, ferr)
	return r
}

// the native transformer of `t`, unless the algorithms were cleared
@(private = "file")
native_of :: #force_inline proc "contextless" (t: ^TS) -> bool { return t.native != nil && !t.native_cleared }

// TransformStreamDefaultControllerPerformTransform
@(private = "file")
perform_transform :: proc "contextless" (ctx: ^wj.Context, ts_obj: wj.JSValue, t: ^TS, chunk: wj.JSValue) -> wj.JSValue {
	p: wj.JSValue
	if native_of(t) {
		p = native_transform(ctx, t, chunk) ? wj.web_promise_resolved(ctx, wj.UNDEFINED) : rejected_with_pending(ctx)
	} else if wj.JS_IsFunction(ctx, t.transform_fn) {
		p = promise_call(ctx, t.transform_fn, t.transformer, {chunk, t.controller})
	} else {
		p = ts_enqueue(ctx, t, chunk) ? wj.web_promise_resolved(ctx, wj.UNDEFINED) : rejected_with_pending(ctx)
	}
	r := then_ts(ctx, p, nil, Step.Transform_Failed, ts_obj, wj.UNDEFINED)
	wj.JS_FreeValue(ctx, p)
	return r
}

@(private = "file")
finish_new :: proc "contextless" (ctx: ^wj.Context, t: ^TS) -> wj.JSValue {
	wj.JS_FreeValue(ctx, t.finish_promise)
	t.finish_promise = wj.web_promise_new(ctx, &t.finish_fn[0])
	return wj.JS_DupValue(ctx, t.finish_promise)
}

@(private = "file")
finish_settle :: proc "contextless" (ctx: ^wj.Context, t: ^TS, ok: bool, v: wj.JSValue) {
	fn := t.finish_fn[ok ? 0 : 1]
	if wj.is_undefined(fn) { return }
	wj.web_settle(ctx, fn, wj.JS_DupValue(ctx, v))
	wj.JS_FreeValue(ctx, t.finish_fn[0])
	wj.JS_FreeValue(ctx, t.finish_fn[1])
	t.finish_fn = {wj.UNDEFINED, wj.UNDEFINED}
}

@(private = "file")
algo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	ts_obj := data[0]
	t := ts_of(ts_obj)
	if t == nil { return wj.UNDEFINED }
	arg := wj.arg(argc, argv, 0)
	switch Step(magic) {
	case .W_Start:
		wj.JS_FreeValue(ctx, t.wctrl)
		t.wctrl = wj.JS_DupValue(ctx, arg)
		return wj.JS_DupValue(ctx, t.start_promise)
	case .R_Start:
		wj.JS_FreeValue(ctx, t.rctrl)
		t.rctrl = wj.JS_DupValue(ctx, arg)
		return wj.JS_DupValue(ctx, t.start_promise)
	case .W_Write:   // TransformStreamDefaultSinkWriteAlgorithm
		if has_backpressure(t) { return then_ts(ctx, t.bp_promise, Step.After_Backpressure, nil, ts_obj, arg) }
		return perform_transform(ctx, ts_obj, t, arg)
	case .After_Backpressure:
		err := wj.UNDEFINED
		if web_writable_state(ctx, t.writable, &err) == 1 { return wj.JS_Throw(ctx, err) }
		wj.JS_FreeValue(ctx, err)
		return perform_transform(ctx, ts_obj, t, data[1])
	case .Transform_Failed:
		ts_error(ctx, t, arg)
		return wj.JS_Throw(ctx, wj.JS_DupValue(ctx, arg))
	case .W_Close:   // TransformStreamDefaultSinkCloseAlgorithm
		if !wj.is_undefined(t.finish_promise) { return wj.JS_DupValue(ctx, t.finish_promise) }
		fin := finish_new(ctx, t)
		p: wj.JSValue
		if native_of(t) {
			p = native_flush(ctx, t) ? wj.web_promise_resolved(ctx, wj.UNDEFINED) : rejected_with_pending(ctx)
		} else {
			p = promise_call(ctx, t.flush_fn, t.transformer, {t.controller})
		}
		clear_algorithms(ctx, t)
		wj.JS_FreeValue(ctx, then_ts(ctx, p, Step.Close_Ok, Step.Close_Failed, ts_obj, wj.UNDEFINED))
		wj.JS_FreeValue(ctx, p)
		return fin
	case .Close_Ok:
		err := wj.UNDEFINED
		if web_stream_state(ctx, t.readable, &err) == 2 {
			finish_settle(ctx, t, false, err)
		} else {
			rc_close(ctx, t)
			finish_settle(ctx, t, true, wj.UNDEFINED)
		}
		wj.JS_FreeValue(ctx, err)
		return wj.UNDEFINED
	case .Close_Failed:
		rc_error(ctx, t, arg)
		finish_settle(ctx, t, false, arg)
		return wj.UNDEFINED
	case .W_Abort, .R_Cancel:   // TransformStreamDefaultSinkAbortAlgorithm, TransformStreamDefaultSourceCancelAlgorithm
		if !wj.is_undefined(t.finish_promise) { return wj.JS_DupValue(ctx, t.finish_promise) }
		fin := finish_new(ctx, t)
		p := promise_call(ctx, t.cancel_fn, t.transformer, {arg})
		clear_algorithms(ctx, t)
		abort := Step(magic) == .W_Abort
		wj.JS_FreeValue(ctx, then_ts(ctx, p, abort ? Step.Abort_Ok : Step.Cancel_Ok, abort ? Step.Abort_Failed : Step.Cancel_Failed, ts_obj, arg))
		wj.JS_FreeValue(ctx, p)
		return fin
	case .Abort_Ok:
		err := wj.UNDEFINED
		if web_stream_state(ctx, t.readable, &err) == 2 {
			finish_settle(ctx, t, false, err)
		} else {
			rc_error(ctx, t, data[1])
			finish_settle(ctx, t, true, wj.UNDEFINED)
		}
		wj.JS_FreeValue(ctx, err)
		return wj.UNDEFINED
	case .Abort_Failed:
		rc_error(ctx, t, arg)
		finish_settle(ctx, t, false, arg)
		return wj.UNDEFINED
	case .Cancel_Ok:
		err := wj.UNDEFINED
		if web_writable_state(ctx, t.writable, &err) == 2 {
			finish_settle(ctx, t, false, err)
		} else {
			wc_error_if_needed(ctx, t, data[1])
			unblock_write(ctx, t)
			finish_settle(ctx, t, true, wj.UNDEFINED)
		}
		wj.JS_FreeValue(ctx, err)
		return wj.UNDEFINED
	case .Cancel_Failed:
		wc_error_if_needed(ctx, t, arg)
		unblock_write(ctx, t)
		finish_settle(ctx, t, false, arg)
		return wj.UNDEFINED
	case .R_Pull:   // TransformStreamDefaultSourcePullAlgorithm
		set_backpressure(ctx, t, false)
		return wj.JS_DupValue(ctx, t.bp_promise)
	}
	return wj.UNDEFINED
}

// ---- making one ----

@(private = "file")
put_fn :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, name: cstring, step: Step, ts_obj: wj.JSValue, length: i32) -> bool {
	d := ts_obj
	f := wj.JS_NewCFunctionData(ctx, algo, length, i32(step), 1, &d)
	if wj.is_exception(f) { return false }
	return wj.JS_SetPropertyStr(ctx, obj, name, f) >= 0
}

// a QueuingStrategy argument as the plain object the stream constructors read: {highWaterMark, size}
@(private = "file")
strategy_of :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue, default_hwm: f64) -> wj.JSValue {
	if !wj.web_dict_check(ctx, s, "QueuingStrategy") { return wj.EXCEPTION }
	hwm, size: wj.JSValue
	if !wj.web_dict_get(ctx, s, "highWaterMark", &hwm) { return wj.EXCEPTION }
	if !wj.web_dict_get(ctx, s, "size", &size) { wj.JS_FreeValue(ctx, hwm); return wj.EXCEPTION }
	o := wj.JS_NewObject(ctx)
	wj.JS_SetPropertyStr(ctx, o, "highWaterMark", wj.is_undefined(hwm) ? wj.new_float64(ctx, default_hwm) : hwm)
	if !wj.is_undefined(size) { wj.JS_SetPropertyStr(ctx, o, "size", size) }
	return o
}

// A transform stream of interface `iface`: the transformer's functions (JavaScript) or a native one (takes the native
// transformer's values).
@(private = "file")
ts_make :: proc(ctx: ^wj.Context, iface: i32, new_target: wj.JSValue, transformer: wj.JSValue, wstrat: wj.JSValue, rstrat: wj.JSValue, native: Native_Transformer) -> wj.JSValue {
	native := native
	drop_native :: proc "contextless" (ctx: ^wj.Context, n: ^Native_Transformer) {
		switch v in n {
		case Decoder_State: wj.JS_FreeValue(ctx, v.decoder)
		case Encoder_State: wj.JS_FreeValue(ctx, v.encoder)
		case Zip_State:
		}
		n^ = nil
	}
	start, transform, flush, cancel := wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	if wj.is_object(transformer) {
		names := [6]cstring{"cancel", "flush", "readableType", "start", "transform", "writableType"}
		v: [6]wj.JSValue
		for name, i in names {
			if !wj.web_dict_get(ctx, transformer, name, &v[i]) {
				for k in 0 ..< i { wj.JS_FreeValue(ctx, v[k]) }
				drop_native(ctx, &native)
				return wj.EXCEPTION
			}
		}
		cancel, flush, start, transform = v[0], v[1], v[3], v[4]
		types := !wj.is_undefined(v[2]) || !wj.is_undefined(v[5])
		wj.free_values(ctx, v[2], v[5])
		fn_or_undef :: proc "contextless" (ctx: ^wj.Context, f: wj.JSValue) -> bool { return wj.is_undefined(f) || wj.JS_IsFunction(ctx, f) }
		fns := fn_or_undef(ctx, cancel) && fn_or_undef(ctx, flush) && fn_or_undef(ctx, start) && fn_or_undef(ctx, transform)
		if types || !fns {
			wj.free_values(ctx, cancel, flush, start, transform)
			drop_native(ctx, &native)
			if types { return wj.JS_ThrowRangeError(ctx, "Failed to construct 'TransformStream': readableType and writableType must be undefined") }
			return wj.wj_throw_type(ctx, "Failed to construct 'TransformStream': the transformer's members must be functions")
		}
	}
	ws := strategy_of(ctx, wstrat, 1)
	rs := wj.is_exception(ws) ? wj.EXCEPTION : strategy_of(ctx, rstrat, 0)
	if wj.is_exception(rs) {
		wj.free_values(ctx, ws, cancel, flush, start, transform)
		drop_native(ctx, &native)
		return wj.EXCEPTION
	}
	t := new(TS)
	if t == nil {
		wj.free_values(ctx, ws, rs, cancel, flush, start, transform)
		drop_native(ctx, &native)
		return wj.JS_ThrowOutOfMemory(ctx)
	}
	t^ = {
		readable = wj.UNDEFINED, writable = wj.UNDEFINED, controller = wj.UNDEFINED, rctrl = wj.UNDEFINED, wctrl = wj.UNDEFINED,
		transformer = wj.is_object(transformer) ? wj.JS_DupValue(ctx, transformer) : wj.UNDEFINED,
		transform_fn = transform, flush_fn = flush, cancel_fn = cancel,
		bp_promise = wj.UNDEFINED, bp_resolve = wj.UNDEFINED, finish_promise = wj.UNDEFINED, finish_fn = {wj.UNDEFINED, wj.UNDEFINED},
		native = native,
	}
	start_fns: [2]wj.JSValue
	t.start_promise = wj.web_promise_new(ctx, &start_fns[0])
	obj := wj.wj_new_object_for(ctx, iface, new_target, nil, nil)
	if wj.is_exception(obj) {
		ts_free(t)
		wj.free_values(ctx, start, ws, rs, start_fns[0], start_fns[1])
		return obj
	}
	wj.web_set_impl(obj, t, ts_free, ts_mark)
	// InitializeTransformStream: the writable side, then the readable one, on this file's sink and source
	sink, source := wj.JS_NewObject(ctx), wj.JS_NewObject(ctx)
	ok := put_fn(ctx, sink, "start", .W_Start, obj, 1) && put_fn(ctx, sink, "write", .W_Write, obj, 1) &&
	      put_fn(ctx, sink, "close", .W_Close, obj, 0) && put_fn(ctx, sink, "abort", .W_Abort, obj, 1) &&
	      put_fn(ctx, source, "start", .R_Start, obj, 1) && put_fn(ctx, source, "pull", .R_Pull, obj, 0) &&
	      put_fn(ctx, source, "cancel", .R_Cancel, obj, 1)
	if ok {
		wargs := [2]wj.JSValue{sink, ws}
		t.writable = wjr_WritableStream_constructor(ctx, wj.wj_the_realm.ctors[net_iface(.WritableStream)], 2, &wargs[0])
		ok = !wj.is_exception(t.writable)
	}
	if ok {
		rargs := [2]wj.JSValue{source, rs}
		t.readable = wjr_ReadableStream_constructor(ctx, wj.wj_the_realm.ctors[net_iface(.ReadableStream)], 2, &rargs[0])
		ok = !wj.is_exception(t.readable)
	}
	wj.free_values(ctx, sink, source, ws, rs)
	if ok {
		set_backpressure(ctx, t, true)
		// SetUpTransformStreamDefaultController
		ci := new(TS_Controller)
		ctrl := ci != nil ? wj.wj_new_object(ctx, net_iface(.TransformStreamDefaultController), nil, nil) : wj.JS_ThrowOutOfMemory(ctx)
		if wj.is_exception(ctrl) {
			free(ci)
			ok = false
		} else {
			ci.stream = wj.JS_DupValue(ctx, obj)
			wj.web_set_impl(ctrl, ci, tsc_free, tsc_mark)
			t.controller = ctrl
		}
	}
	if !ok {
		wj.free_values(ctx, start, start_fns[0], start_fns[1], obj)
		return wj.EXCEPTION
	}
	// the transformer's start(controller) resolves startPromise
	r := wj.JS_IsFunction(ctx, start) ? wj.JS_Call(ctx, start, t.transformer, 1, &t.controller) : wj.UNDEFINED
	wj.JS_FreeValue(ctx, start)
	if wj.is_exception(r) { wj.free_values(ctx, start_fns[0], start_fns[1], obj); return r }
	wj.web_settle(ctx, start_fns[0], r)
	wj.free_values(ctx, start_fns[0], start_fns[1])
	return obj
}

@(export, link_name = "wjr_TransformStream_constructor")
wjr_TransformStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor TransformStream requires 'new'") }
	tr := wj.arg(argc, argv, 0)
	if !wj.is_nullish(tr) && !wj.is_object(tr) { return wj.wj_throw_type(ctx, "Failed to construct 'TransformStream': the transformer is not an object") }
	return ts_make(ctx, net_iface(.TransformStream), new_target, wj.is_null(tr) ? wj.UNDEFINED : tr, wj.arg(argc, argv, 1), wj.arg(argc, argv, 2), nil)
}

@(private = "file")
ts_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, k: Net_Iface) -> ^TS {
	if wj.wj_this(ctx, this_val, net_iface(k)) == nil { return nil }
	t := ts_of(this_val)
	if t == nil { wj.wj_throw_type(ctx, "Illegal invocation") }
	return t
}

@(private = "file")
side :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, k: Net_Iface, readable: bool) -> wj.JSValue {
	t := ts_this(ctx, this_val, k)
	if t == nil { return wj.EXCEPTION }
	return wj.JS_DupValue(ctx, readable ? t.readable : t.writable)
}

@(export, link_name = "wjr_TransformStream_get_readable")
wjr_TransformStream_get_readable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .TransformStream, true) }
@(export, link_name = "wjr_TransformStream_get_writable")
wjr_TransformStream_get_writable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .TransformStream, false) }

// ---- TransformStreamDefaultController ----

@(private = "file")
ctrl_stream :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^TS {
	c := (^TS_Controller)(wj.this_impl(ctx, this_val, net_iface(.TransformStreamDefaultController)))
	if c == nil { return nil }
	t := ts_of(c.stream)
	if t == nil { wj.wj_throw_type(ctx, "Illegal invocation") }
	return t
}

@(export, link_name = "wjr_TransformStreamDefaultController_get_desiredSize")
wjr_TransformStreamDefaultController_get_desiredSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	t := ctrl_stream(ctx, this_val)
	if t == nil { return wj.EXCEPTION }
	d, ok := rc_desired(ctx, t)
	return ok ? wj.new_float64(ctx, d) : wj.NULL
}

@(export, link_name = "wjr_TransformStreamDefaultController_enqueue")
wjr_TransformStreamDefaultController_enqueue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	t := ctrl_stream(ctx, this_val)
	if t == nil { return wj.EXCEPTION }
	return ts_enqueue(ctx, t, wj.arg(argc, argv, 0)) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_TransformStreamDefaultController_error")
wjr_TransformStreamDefaultController_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	t := ctrl_stream(ctx, this_val)
	if t == nil { return wj.EXCEPTION }
	ts_error(ctx, t, wj.arg(argc, argv, 0))
	return wj.UNDEFINED
}

// TransformStreamDefaultControllerTerminate
@(export, link_name = "wjr_TransformStreamDefaultController_terminate")
wjr_TransformStreamDefaultController_terminate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	t := ctrl_stream(ctx, this_val)
	if t == nil { return wj.EXCEPTION }
	rc_close(ctx, t)
	e := wj.web_type_error(ctx, "TransformStream terminated")
	error_writable_and_unblock(ctx, t, e)
	wj.JS_FreeValue(ctx, e)
	return wj.UNDEFINED
}

// ---- the native transformers ----

// enqueues `s` (taken) when it is a non-empty string
@(private = "file")
enqueue_text :: proc "contextless" (ctx: ^wj.Context, t: ^TS, s: wj.JSValue) -> bool {
	n: i64
	wj.JS_GetLength(ctx, s, &n)
	ok := n == 0 || ts_enqueue(ctx, t, s)
	wj.JS_FreeValue(ctx, s)
	return ok
}

// The bytes of a push / finish of the compressor (status: its result) as a Uint8Array enqueued when not empty.
@(private = "file")
zip_output :: proc "contextless" (ctx: ^wj.Context, t: ^TS, z: Zip_State, n: i32) -> bool {
	n := n
	if n < 0 {
		if n == i32(wj.wr_Error.Type) { wj.JS_ThrowTypeError(ctx, "The compressed data is not valid."); return false }
		wj.wj_throw_status(ctx, n, "CompressionStream")
		return false
	}
	if n == 0 { return true }
	if u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { wj.JS_ThrowOutOfMemory(ctx); return false }
		// (the browser keeps the output of a call: read back, the input is not fed twice)
		n = wj.wr_Compression_output(u64(z.host), wj.wj_scratch.data, wj.wj_scratch.cap)
		if n <= 0 { return true }
	}
	p := ([^]u8)(wj.js_malloc(ctx, uint(n)))   // (an ArrayBuffer takes memory of the engine's allocator)
	if p == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	wj.memcpy(p, wj.wj_scratch.data, uint(n))
	bytes := wj.wj_uint8array_take(ctx, p, uint(n))
	if wj.is_exception(bytes) { return false }
	ok := ts_enqueue(ctx, t, bytes)
	wj.JS_FreeValue(ctx, bytes)
	return ok
}

// Encoding Standard "encode and enqueue a chunk": a high surrogate that ends a chunk waits for the next one; a lone
// surrogate is U+FFFD (the encoder converts as USVString).
@(private = "file")
encoder_transform :: proc "contextless" (ctx: ^wj.Context, t: ^TS, e: ^Encoder_State, chunk: wj.JSValue) -> bool {
	s := wj.JS_ToString(ctx, chunk)
	if wj.is_exception(s) { return false }
	if e.pending_high >= 0 {
		// String.fromCharCode(the held code unit) + the chunk
		str := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "String")
		from := wj.JS_GetPropertyStr(ctx, str, "fromCharCode")
		cu := wj.new_int32(e.pending_high)
		l := wj.JS_Call(ctx, from, str, 1, &cu)
		wj.free_values(ctx, from, str)
		if wj.is_exception(l) { wj.JS_FreeValue(ctx, s); return false }
		concat := wj.JS_GetPropertyStr(ctx, l, "concat")
		joined := wj.JS_Call(ctx, concat, l, 1, &s)
		wj.free_values(ctx, concat, l, s)
		if wj.is_exception(joined) { return false }
		s = joined
		e.pending_high = -1
	}
	n: i64
	wj.JS_GetLength(ctx, s, &n)
	if n > 0 {
		code := wj.JS_GetPropertyStr(ctx, s, "charCodeAt")
		idx := wj.new_int64(ctx, n - 1)
		cu := wj.JS_Call(ctx, code, s, 1, &idx)
		wj.JS_FreeValue(ctx, code)
		u: i32
		wj.JS_ToInt32(ctx, &u, cu)
		wj.JS_FreeValue(ctx, cu)
		if u >= 0xD800 && u <= 0xDBFF {
			e.pending_high = u
			slice := wj.JS_GetPropertyStr(ctx, s, "slice")
			args := [2]wj.JSValue{wj.new_int32(0), idx}
			cut := wj.JS_Call(ctx, slice, s, 2, &args[0])
			wj.free_values(ctx, slice, s)
			if wj.is_exception(cut) { return false }
			s = cut
			n -= 1
		}
	}
	if n == 0 { wj.JS_FreeValue(ctx, s); return true }
	bytes := wjr_TextEncoder_encode(ctx, e.encoder, 1, &s)
	wj.JS_FreeValue(ctx, s)
	if wj.is_exception(bytes) { return false }
	ok := ts_enqueue(ctx, t, bytes)
	wj.JS_FreeValue(ctx, bytes)
	return ok
}

@(private = "file")
native_transform :: proc "contextless" (ctx: ^wj.Context, t: ^TS, chunk: wj.JSValue) -> bool {
	switch &n in t.native {
	case Decoder_State:
		p: [^]u8
		size: uint
		if !wj.wj_to_buffer_source(ctx, chunk, &p, &size, wj.BS_ALLOW_SHARED, "TextDecoderStream") { return false }
		opt := wj.JS_NewObject(ctx)
		wj.JS_SetPropertyStr(ctx, opt, "stream", wj.TRUE)
		args := [2]wj.JSValue{chunk, opt}
		s := wjr_TextDecoder_decode(ctx, n.decoder, 2, &args[0])
		wj.JS_FreeValue(ctx, opt)
		if wj.is_exception(s) { return false }
		return enqueue_text(ctx, t, s)
	case Encoder_State:
		return encoder_transform(ctx, t, &n, chunk)
	case Zip_State:
		p: [^]u8
		size: uint
		if !wj.wj_to_buffer_source(ctx, chunk, &p, &size, wj.BS_ALLOW_SHARED, "CompressionStream") { return false }
		if u64(size) > 0xFFFF_FFFF { wj.JS_ThrowRangeError(ctx, "CompressionStream: the chunk is too large"); return false }
		if wj.wj_scratch.data == nil && !wj.wj_scratch_grow(4096) { wj.JS_ThrowOutOfMemory(ctx); return false }
		r := wj.wr_Compression_push(u64(n.host), size > 0 ? p : wj.empty_ptr(), u32(size), wj.wj_scratch.data, wj.wj_scratch.cap)
		return zip_output(ctx, t, n, r)
	}
	return true
}

@(private = "file")
native_flush :: proc "contextless" (ctx: ^wj.Context, t: ^TS) -> bool {
	switch &n in t.native {
	case Decoder_State:
		s := wjr_TextDecoder_decode(ctx, n.decoder, 0, nil)
		if wj.is_exception(s) { return false }
		return enqueue_text(ctx, t, s)
	case Encoder_State:
		if n.pending_high < 0 { return true }
		n.pending_high = -1
		fffd := ([^]u8)(wj.js_malloc(ctx, 3))   // (an ArrayBuffer takes memory of the engine's allocator)
		if fffd == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
		fffd[0], fffd[1], fffd[2] = 0xEF, 0xBF, 0xBD
		bytes := wj.wj_uint8array_take(ctx, fffd, 3)
		if wj.is_exception(bytes) { return false }
		ok := ts_enqueue(ctx, t, bytes)
		wj.JS_FreeValue(ctx, bytes)
		return ok
	case Zip_State:
		if wj.wj_scratch.data == nil && !wj.wj_scratch_grow(4096) { wj.JS_ThrowOutOfMemory(ctx); return false }
		r := wj.wr_Compression_finish(u64(n.host), wj.wj_scratch.data, wj.wj_scratch.cap)
		if r == i32(wj.wr_Error.Type) { wj.JS_ThrowTypeError(ctx, "The compressed data ended before its end."); return false }
		return zip_output(ctx, t, n, r)
	}
	return true
}

// ---- TextDecoderStream ----

@(export, link_name = "wjr_TextDecoderStream_constructor")
wjr_TextDecoderStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor TextDecoderStream requires 'new'") }
	dec := wjr_TextDecoder_constructor(ctx, wj.wj_the_realm.ctors[net_iface(.TextDecoder)], argc, argv)
	if wj.is_exception(dec) { return dec }
	return ts_make(ctx, net_iface(.TextDecoderStream), new_target, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, Decoder_State{dec})
}

@(private = "file")
decoder_of :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> (wj.JSValue, bool) {
	t := ts_this(ctx, this_val, .TextDecoderStream)
	if t == nil { return wj.UNDEFINED, false }
	d, _ := t.native.(Decoder_State)
	return d.decoder, true
}

@(export, link_name = "wjr_TextDecoderStream_get_encoding")
wjr_TextDecoderStream_get_encoding :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d, ok := decoder_of(ctx, this_val)
	return ok ? wj.JS_GetPropertyStr(ctx, d, "encoding") : wj.EXCEPTION
}

@(export, link_name = "wjr_TextDecoderStream_get_fatal")
wjr_TextDecoderStream_get_fatal :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d, ok := decoder_of(ctx, this_val)
	return ok ? wjr_TextDecoder_get_fatal(ctx, d) : wj.EXCEPTION
}

@(export, link_name = "wjr_TextDecoderStream_get_ignoreBOM")
wjr_TextDecoderStream_get_ignoreBOM :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	d, ok := decoder_of(ctx, this_val)
	return ok ? wjr_TextDecoder_get_ignoreBOM(ctx, d) : wj.EXCEPTION
}

@(export, link_name = "wjr_TextDecoderStream_get_readable")
wjr_TextDecoderStream_get_readable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .TextDecoderStream, true) }
@(export, link_name = "wjr_TextDecoderStream_get_writable")
wjr_TextDecoderStream_get_writable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .TextDecoderStream, false) }

// ---- TextEncoderStream ----

@(export, link_name = "wjr_TextEncoderStream_constructor")
wjr_TextEncoderStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor TextEncoderStream requires 'new'") }
	enc := wjr_TextEncoder_constructor(ctx, wj.wj_the_realm.ctors[net_iface(.TextEncoder)], 0, nil)
	if wj.is_exception(enc) { return enc }
	return ts_make(ctx, net_iface(.TextEncoderStream), new_target, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, Encoder_State{enc, -1})
}

@(export, link_name = "wjr_TextEncoderStream_get_encoding")
wjr_TextEncoderStream_get_encoding :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return ts_this(ctx, this_val, .TextEncoderStream) != nil ? js_str(ctx, "utf-8") : wj.EXCEPTION
}
@(export, link_name = "wjr_TextEncoderStream_get_readable")
wjr_TextEncoderStream_get_readable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .TextEncoderStream, true) }
@(export, link_name = "wjr_TextEncoderStream_get_writable")
wjr_TextEncoderStream_get_writable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .TextEncoderStream, false) }

// ---- CompressionStream, DecompressionStream ----

@(private = "file")
zip_make :: proc(ctx: ^wj.Context, new_target: wj.JSValue, k: Net_Iface, argc: i32, argv: [^]wj.JSValue, decompress: bool) -> wj.JSValue {
	name: cstring = decompress ? "DecompressionStream" : "CompressionStream"
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor %s requires 'new'", name) }
	if argc < 1 { return wj.wj_throw_arity(ctx, name, 1, argc) }
	s: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &s, 0, "") { return wj.EXCEPTION }
	formats := [?]cstring{"gzip", "deflate", "deflate-raw", nil}
	f := wj.wj_enum_index(&s, &formats[0])
	if f < 0 {
		e := wj.wj_throw_type(ctx, "Failed to construct '%s': Unsupported compression format: '%.*s'", name, i32(min(s.len, 32)), wj.cstr_bytes(s.ptr))
		wj.wj_str_free(ctx, &s)
		return e
	}
	wj.wj_str_free(ctx, &s)
	h: api_decl.Compressor
	if st := jsb.host(&h, api_decl.Compression_create, wj.wr_Compression_create, api_decl.CompressionFormat(f), decompress); st != .None {
		return wj.wj_throw_status(ctx, i32(st), name)
	}
	obj := ts_make(ctx, net_iface(k), new_target, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, Zip_State{h})
	if wj.is_exception(obj) { wj.wr_Object_release(u64(h)) }
	return obj
}

@(export, link_name = "wjr_CompressionStream_constructor")
wjr_CompressionStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return zip_make(ctx, new_target, .CompressionStream, argc, argv, false)
}
@(export, link_name = "wjr_DecompressionStream_constructor")
wjr_DecompressionStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return zip_make(ctx, new_target, .DecompressionStream, argc, argv, true)
}

@(export, link_name = "wjr_CompressionStream_get_readable")
wjr_CompressionStream_get_readable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .CompressionStream, true) }
@(export, link_name = "wjr_CompressionStream_get_writable")
wjr_CompressionStream_get_writable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .CompressionStream, false) }
@(export, link_name = "wjr_DecompressionStream_get_readable")
wjr_DecompressionStream_get_readable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .DecompressionStream, true) }
@(export, link_name = "wjr_DecompressionStream_get_writable")
wjr_DecompressionStream_get_writable :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue { return side(ctx, this_val, .DecompressionStream, false) }
