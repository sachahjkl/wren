// web_pipe.odin: ReadableStream.pipeTo / pipeThrough (Streams "ReadableStreamPipeTo"). Ported from
// native/js/runtime/web_pipe.c: same wjr_* symbols and behaviour.
//
// The pipe locks the source with a default reader (web_stream.odin) and the destination with a writer
// (web_writable.odin), then: waits for the writer's ready (backpressure), reads a chunk, writes it without waiting for
// the write, and goes on. It shuts down when the source closes (closes the destination unless preventClose), when
// either side errors (aborts the destination unless preventAbort / cancels the source unless preventCancel), when the
// destination closes, or when the signal aborts (both, reason = signal.reason); a shutdown waits for the last write,
// releases both locks and settles the promise. The pipe's state is a plain object (`st`) the reactions share as their
// bound data: the engine's collector sees every value it holds, cycles with the streams included.
package odin_glue

import "../odin/wj"

// what a shutdown does once the writes are done
@(private = "file") Action :: enum i32 { None, Close, Abort, Cancel, Both }

@(private = "file") st_get :: #force_inline proc "contextless" (ctx: ^wj.Context, st: wj.JSValue, k: cstring) -> wj.JSValue { return wj.JS_GetPropertyStr(ctx, st, k) }
@(private = "file") st_set :: #force_inline proc "contextless" (ctx: ^wj.Context, st: wj.JSValue, k: cstring, v: wj.JSValue) { wj.JS_SetPropertyStr(ctx, st, k, v) }

@(private = "file")
st_flag :: proc "contextless" (ctx: ^wj.Context, st: wj.JSValue, k: cstring) -> bool {
	v := st_get(ctx, st, k)
	b := wj.JS_ToBool(ctx, v) > 0
	wj.JS_FreeValue(ctx, v)
	return b
}

// p.then(ok, err) with data = [st]; takes `p`
@(private = "file")
then_st :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue, ok, err: wj.Native_Data, st: wj.JSValue) {
	p := p
	if wj.is_exception(p) { p = wj.web_promise_reject_pending(ctx) }
	then_drop(ctx, p, ok != nil ? ok : noop_reaction, err != nil ? err : noop_reaction, st)
	wj.JS_FreeValue(ctx, p)
}

// signal.addEventListener / removeEventListener("abort", fn), errors dropped
@(private = "file")
signal_listener :: proc "contextless" (ctx: ^wj.Context, signal: wj.JSValue, method: cstring, fn: wj.JSValue) {
	m := wj.JS_GetPropertyStr(ctx, signal, method)
	args := [2]wj.JSValue{js_str(ctx, "abort"), fn}
	wj.discard(ctx, wj.JS_Call(ctx, m, signal, 2, &args[0]))
	wj.free_values(ctx, args[0], m)
}

// the end: both locks released, the promise settled (once)
@(private = "file")
pipe_finish :: proc "contextless" (ctx: ^wj.Context, st: wj.JSValue, is_err: bool, err: wj.JSValue) {
	if st_flag(ctx, st, "finished") { return }
	st_set(ctx, st, "finished", wj.TRUE)
	reader, writer := st_get(ctx, st, "reader"), st_get(ctx, st, "writer")
	wj.discard(ctx, wjr_WritableStreamDefaultWriter_releaseLock(ctx, writer, 0, nil))
	wj.discard(ctx, wjr_ReadableStreamDefaultReader_releaseLock(ctx, reader, 0, nil))
	wj.free_values(ctx, reader, writer)
	signal, onabort := st_get(ctx, st, "signal"), st_get(ctx, st, "onabort")
	if wj.is_object(signal) && wj.JS_IsFunction(ctx, onabort) { signal_listener(ctx, signal, "removeEventListener", onabort) }
	wj.free_values(ctx, signal, onabort)
	f := st_get(ctx, st, is_err ? "reject" : "resolve")
	wj.web_settle(ctx, f, is_err ? wj.JS_DupValue(ctx, err) : wj.UNDEFINED)
	wj.JS_FreeValue(ctx, f)
	// (the state no longer holds the streams: nothing keeps them alive past the pipe)
	for k in ([?]cstring{"reader", "writer", "resolve", "reject", "onabort", "signal", "read_promise", "last"}) { st_set(ctx, st, k, wj.UNDEFINED) }
}

@(private = "file")
action_ok :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	e := st_get(ctx, data[0], "error")
	pipe_finish(ctx, data[0], st_flag(ctx, data[0], "is_err"), e)
	wj.JS_FreeValue(ctx, e)
	return wj.UNDEFINED
}

@(private = "file")
action_failed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	// (the action's error wins over the original one: Streams "shutdown with an action")
	pipe_finish(ctx, data[0], true, wj.arg(argc, argv, 0))
	return wj.UNDEFINED
}

// the writes are done: the shutdown's action, then the end
@(private = "file")
writes_done :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	st := data[0]
	av := st_get(ctx, st, "action")
	act: i32
	wj.JS_ToInt32(ctx, &act, av)
	wj.JS_FreeValue(ctx, av)
	e := st_get(ctx, st, "error")
	reader, writer := st_get(ctx, st, "reader"), st_get(ctx, st, "writer")
	p := wj.UNDEFINED
	switch Action(act) {
	case .None:
	case .Close:  p = wjr_WritableStreamDefaultWriter_close(ctx, writer, 0, nil)
	case .Abort:  p = wjr_WritableStreamDefaultWriter_abort(ctx, writer, 1, &e)
	case .Cancel: p = wjr_ReadableStreamDefaultReader_cancel(ctx, reader, 1, &e)
	case .Both:
		// Promise.all([abort unless preventAbort, cancel unless preventCancel])
		list := wj.JS_NewArray(ctx)
		k: u32
		if !st_flag(ctx, st, "preventAbort") { wj.JS_SetPropertyUint32(ctx, list, k, wjr_WritableStreamDefaultWriter_abort(ctx, writer, 1, &e)); k += 1 }
		if !st_flag(ctx, st, "preventCancel") { wj.JS_SetPropertyUint32(ctx, list, k, wjr_ReadableStreamDefaultReader_cancel(ctx, reader, 1, &e)); k += 1 }
		promise := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "Promise")
		all := wj.JS_GetPropertyStr(ctx, promise, "all")
		p = wj.JS_Call(ctx, all, promise, 1, &list)
		wj.free_values(ctx, all, promise, list)
	}
	wj.free_values(ctx, reader, writer, e)
	if wj.is_undefined(p) { p = wj.web_promise_take(ctx, wj.UNDEFINED) }
	then_st(ctx, p, action_ok, action_failed, st)
	return wj.UNDEFINED
}

// Shuts the pipe down (once): after the last write settles, `act`, then the end with `err` when `is_err`.
@(private = "file")
pipe_shutdown :: proc "contextless" (ctx: ^wj.Context, st: wj.JSValue, act: Action, is_err: bool, err: wj.JSValue) {
	if st_flag(ctx, st, "shutting") { return }
	st_set(ctx, st, "shutting", wj.TRUE)
	st_set(ctx, st, "action", wj.new_int32(i32(act)))
	st_set(ctx, st, "is_err", wj.new_bool(is_err))
	st_set(ctx, st, "error", wj.JS_DupValue(ctx, err))
	last := st_get(ctx, st, "last")
	// (closing waits for the writes anyway: the close is queued after them)
	if !wj.is_object(last) || act == .Close { wj.JS_FreeValue(ctx, last); last = wj.web_promise_take(ctx, wj.UNDEFINED) }
	then_st(ctx, last, writes_done, writes_done, st)
}

// writes one chunk without waiting for it; a failed write errors the destination: its closed promise drives the
// shutdown
@(private = "file")
write_chunk :: proc "contextless" (ctx: ^wj.Context, st: wj.JSValue, value: wj.JSValue) {
	writer := st_get(ctx, st, "writer")
	v := value
	wp := wjr_WritableStreamDefaultWriter_write(ctx, writer, 1, &v)
	wj.JS_FreeValue(ctx, writer)
	if wj.is_exception(wp) { wp = wj.web_promise_reject_pending(ctx) }
	mark_handled(ctx, wp)
	st_set(ctx, st, "last", wp)
}

@(private = "file")
on_read :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	st := data[0]
	st_set(ctx, st, "reading", wj.FALSE)
	if st_flag(ctx, st, "shutting") { return wj.UNDEFINED }
	res := wj.arg(argc, argv, 0)
	done := wj.JS_GetPropertyStr(ctx, res, "done")
	is_done := wj.JS_ToBool(ctx, done) > 0
	wj.JS_FreeValue(ctx, done)
	if is_done {
		pipe_shutdown(ctx, st, st_flag(ctx, st, "preventClose") ? .None : .Close, false, wj.UNDEFINED)
		return wj.UNDEFINED
	}
	value := wj.JS_GetPropertyStr(ctx, res, "value")
	write_chunk(ctx, st, value)
	wj.JS_FreeValue(ctx, value)
	pipe_step(ctx, st)
	return wj.UNDEFINED
}

@(private = "file")
on_ready :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	st := data[0]
	if st_flag(ctx, st, "shutting") { return wj.UNDEFINED }
	reader := st_get(ctx, st, "reader")
	st_set(ctx, st, "reading", wj.TRUE)
	rp := wjr_ReadableStreamDefaultReader_read(ctx, reader, 0, nil)
	wj.JS_FreeValue(ctx, reader)
	if !wj.is_exception(rp) { st_set(ctx, st, "read_promise", wj.JS_DupValue(ctx, rp)) }
	then_st(ctx, rp, on_read, nil, st)   // (a read that fails: the source errored, its closed promise says so)
	return wj.UNDEFINED
}

@(private = "file")
pipe_step :: proc "contextless" (ctx: ^wj.Context, st: wj.JSValue) {
	writer := st_get(ctx, st, "writer")
	ready := wjr_WritableStreamDefaultWriter_get_ready(ctx, writer)
	wj.JS_FreeValue(ctx, writer)
	then_st(ctx, ready, on_ready, nil, st)
}

// What happened to a side, the `magic` of side_event.
@(private = "file") Side_Event :: enum i32 { Source_Errored, Dest_Errored, Dest_Closed, Source_Closed }

@(private = "file")
side_event :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	st := data[0]
	if st_flag(ctx, st, "shutting") { return wj.UNDEFINED }
	e := wj.arg(argc, argv, 0)
	switch Side_Event(magic) {
	case .Source_Errored:
		pipe_shutdown(ctx, st, st_flag(ctx, st, "preventAbort") ? .None : .Abort, true, e)
	case .Source_Closed:
		// a read in flight may already hold the last chunk (its reaction comes after this one): written first
		if st_flag(ctx, st, "reading") {
			rp := st_get(ctx, st, "read_promise")
			if wj.JS_PromiseState(ctx, rp) == .Fulfilled {
				res := wj.JS_PromiseResult(ctx, rp)
				done := wj.JS_GetPropertyStr(ctx, res, "done")
				if wj.JS_ToBool(ctx, done) <= 0 {
					value := wj.JS_GetPropertyStr(ctx, res, "value")
					write_chunk(ctx, st, value)
					wj.JS_FreeValue(ctx, value)
				}
				wj.free_values(ctx, done, res)
			}
			wj.JS_FreeValue(ctx, rp)
		}
		pipe_shutdown(ctx, st, st_flag(ctx, st, "preventClose") ? .None : .Close, false, wj.UNDEFINED)
	case .Dest_Errored:
		pipe_shutdown(ctx, st, st_flag(ctx, st, "preventCancel") ? .None : .Cancel, true, e)
	case .Dest_Closed:
		te := wj.web_type_error(ctx, "the destination of the pipe was closed")
		pipe_shutdown(ctx, st, st_flag(ctx, st, "preventCancel") ? .None : .Cancel, true, te)
		wj.JS_FreeValue(ctx, te)
	}
	return wj.UNDEFINED
}

// side_event bound to one kind (a reaction's magic is that of the function web_then makes)
@(private = "file")
src_errored :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return side_event(ctx, t, argc, argv, i32(Side_Event.Source_Errored), data)
}
@(private = "file")
dest_errored :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return side_event(ctx, t, argc, argv, i32(Side_Event.Dest_Errored), data)
}
@(private = "file")
src_closed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return side_event(ctx, t, argc, argv, i32(Side_Event.Source_Closed), data)
}
@(private = "file")
dest_closed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return side_event(ctx, t, argc, argv, i32(Side_Event.Dest_Closed), data)
}

@(private = "file")
on_abort :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	st := data[0]
	signal := st_get(ctx, st, "signal")
	reason := web_signal_reason(ctx, signal)
	pipe_shutdown(ctx, st, .Both, true, reason)
	wj.free_values(ctx, reason, signal)
	return wj.UNDEFINED
}

@(private = "file")
option :: proc "contextless" (ctx: ^wj.Context, opt: wj.JSValue, name: cstring, st: wj.JSValue) -> bool {
	v := wj.UNDEFINED
	if !wj.web_dict_get(ctx, opt, name, &v) { return false }
	st_set(ctx, st, name, wj.new_bool(wj.JS_ToBool(ctx, v) > 0))
	wj.JS_FreeValue(ctx, v)
	return true
}

@(private = "file")
dest_locked :: proc "contextless" (ctx: ^wj.Context, dest: wj.JSValue) -> bool {
	locked := wjr_WritableStream_get_locked(ctx, dest)
	l := wj.JS_ToBool(ctx, locked) > 0
	wj.JS_FreeValue(ctx, locked)
	return l
}

// The pipe from `source` to `dest` (both checked): its promise.
@(private = "file")
pipe_to :: proc "contextless" (ctx: ^wj.Context, source: wj.JSValue, dest: wj.JSValue, opt: wj.JSValue) -> wj.JSValue {
	if !wj.web_dict_check(ctx, opt, "StreamPipeOptions") { return wj.web_promise_reject_pending(ctx) }
	st := wj.JS_NewObject(ctx)
	signal := wj.UNDEFINED
	// (the members in alphabetical order, as Web IDL converts a dictionary)
	if !option(ctx, opt, "preventAbort", st) || !option(ctx, opt, "preventCancel", st) || !option(ctx, opt, "preventClose", st) ||
	   !wj.web_dict_get(ctx, opt, "signal", &signal) {
		wj.JS_FreeValue(ctx, st)
		return wj.web_promise_reject_pending(ctx)
	}
	if !wj.is_undefined(signal) && wj.wj_unwrap(signal, net_iface(.AbortSignal)) == nil {
		wj.free_values(ctx, signal, st)
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'pipeTo' on 'ReadableStream': member signal is not of type AbortSignal.")
		return wj.web_promise_reject_pending(ctx)
	}
	if web_stream_locked(source) || dest_locked(ctx, dest) {
		wj.free_values(ctx, signal, st)
		if web_stream_locked(source) {
			wj.JS_ThrowTypeError(ctx, "Failed to execute 'pipeTo' on 'ReadableStream': Cannot pipe a locked stream")
		} else {
			wj.JS_ThrowTypeError(ctx, "Failed to execute 'pipeTo' on 'ReadableStream': Cannot pipe to a locked stream")
		}
		return wj.web_promise_reject_pending(ctx)
	}
	reader := wjr_ReadableStream_getReader(ctx, source, 0, nil)
	if wj.is_exception(reader) { wj.free_values(ctx, signal, st); return wj.web_promise_reject_pending(ctx) }
	writer := wjr_WritableStream_getWriter(ctx, dest, 0, nil)
	if wj.is_exception(writer) {
		wj.JS_FreeValue(ctx, wjr_ReadableStreamDefaultReader_releaseLock(ctx, reader, 0, nil))
		wj.free_values(ctx, reader, signal, st)
		return wj.web_promise_reject_pending(ctx)
	}
	funcs: [2]wj.JSValue
	promise := wj.web_promise_new(ctx, &funcs[0])
	st_set(ctx, st, "reader", reader)
	st_set(ctx, st, "writer", writer)
	st_set(ctx, st, "resolve", funcs[0])
	st_set(ctx, st, "reject", funcs[1])
	st_set(ctx, st, "signal", wj.JS_DupValue(ctx, signal))
	// the sides' fates
	then_st(ctx, wjr_ReadableStreamDefaultReader_get_closed(ctx, reader), src_closed, src_errored, st)
	then_st(ctx, wjr_WritableStreamDefaultWriter_get_closed(ctx, writer), dest_closed, dest_errored, st)
	if wj.is_object(signal) {
		if web_signal_aborted(signal) {
			reason := web_signal_reason(ctx, signal)
			pipe_shutdown(ctx, st, .Both, true, reason)
			wj.JS_FreeValue(ctx, reason)
		} else {
			s := st
			fn := wj.JS_NewCFunctionData(ctx, on_abort, 0, 0, 1, &s)
			signal_listener(ctx, signal, "addEventListener", fn)
			st_set(ctx, st, "onabort", fn)
		}
	}
	wj.JS_FreeValue(ctx, signal)
	if !st_flag(ctx, st, "shutting") { pipe_step(ctx, st) }
	wj.JS_FreeValue(ctx, st)
	return promise
}

@(export, link_name = "wjr_ReadableStream_pipeTo")
wjr_ReadableStream_pipeTo :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !web_stream_is(this_val) { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return wj.web_promise_reject_pending(ctx) }
	dest := wj.arg(argc, argv, 0)
	if wj.wj_unwrap(dest, net_iface(.WritableStream)) == nil {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'pipeTo' on 'ReadableStream': parameter 1 is not of type 'WritableStream'.")
		return wj.web_promise_reject_pending(ctx)
	}
	return pipe_to(ctx, this_val, dest, wj.arg(argc, argv, 1))
}

@(export, link_name = "wjr_ReadableStream_pipeThrough")
wjr_ReadableStream_pipeThrough :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if !web_stream_is(this_val) { return wj.wj_throw_type(ctx, "Illegal invocation") }
	pair := wj.arg(argc, argv, 0)
	if !wj.is_object(pair) { return wj.wj_throw_type(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': parameter 1 is not an object.") }
	// ReadableWritablePair: readable, then writable (alphabetical)
	readable := wj.JS_GetPropertyStr(ctx, pair, "readable")
	if wj.is_exception(readable) { return readable }
	if !web_stream_is(readable) {
		wj.JS_FreeValue(ctx, readable)
		return wj.wj_throw_type(ctx, "Failed to execute 'pipeThrough' on 'ReadableStream': member readable is not of type ReadableStream.")
	}
	writable := wj.JS_GetPropertyStr(ctx, pair, "writable")
	if wj.is_exception(writable) { wj.JS_FreeValue(ctx, readable); return writable }
	fail :: proc "contextless" (ctx: ^wj.Context, readable, writable: wj.JSValue, msg: cstring) -> wj.JSValue {
		wj.free_values(ctx, readable, writable)
		return msg != nil ? wj.wj_throw_type(ctx, msg) : wj.EXCEPTION
	}
	if wj.wj_unwrap(writable, net_iface(.WritableStream)) == nil {
		return fail(ctx, readable, writable, "Failed to execute 'pipeThrough' on 'ReadableStream': member writable is not of type WritableStream.")
	}
	opt := wj.arg(argc, argv, 1)
	if !wj.web_dict_check(ctx, opt, "StreamPipeOptions") { return fail(ctx, readable, writable, nil) }
	if web_stream_locked(this_val) { return fail(ctx, readable, writable, "Failed to execute 'pipeThrough' on 'ReadableStream': Cannot pipe a locked stream") }
	if dest_locked(ctx, writable) { return fail(ctx, readable, writable, "Failed to execute 'pipeThrough' on 'ReadableStream': Cannot pipe to a locked stream") }
	p := pipe_to(ctx, this_val, writable, opt)
	mark_handled(ctx, p)   // (its result is not observable)
	wj.free_values(ctx, p, writable)
	return readable
}
