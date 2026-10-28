// web_writable.odin: WritableStream, WritableStreamDefaultWriter and WritableStreamDefaultController, following the
// Streams Standard's algorithms (the names in the comments are the specification's). Ported from
// native/js/runtime/web_writable.c: same wjr_* / web_writable_* symbols and behaviour.
//
// The states writable, erroring, errored and closed; one write or close in flight at a time; abort() that waits for it
// and then calls the sink's abort; the queue with the strategy's sizes and highWaterMark, backpressure seen as
// desiredSize and the writer's ready; a writer's own closed and ready promises; the controller's signal (an
// AbortSignal aborted by abort()). Used by pages (new WritableStream(sink)), by the browser's own streams
// (FileSystemWritableFileStream: web_fs.c gives a sink of C functions), and by pipes from a ReadableStream
// (web_pipe.odin).
package odin_glue

import "../odin/wj"

// (exported values: web_writable_state's numbers)
@(private = "file") WS_State :: enum i32 { Writable, Erroring, Errored, Closed }

// a chunk queued with its size, or the close marker
@(private = "file")
WS_Item :: struct {
	value: wj.JSValue,
	size:  f64,
	close: bool,
}

// pendingAbortRequest
@(private = "file")
Abort_Request :: struct {
	prom:         Prom,
	reason:       wj.JSValue,
	was_erroring: bool,
}

@(private = "file")
Writable :: struct {
	state:           WS_State,
	stored_error:    wj.JSValue,
	writer:          wj.JSValue,            // the writer holding the lock, undefined when none
	controller:      wj.JSValue,            // the WritableStreamDefaultController
	self:            wj.JSValue,            // not counted
	write_reqs:      [dynamic]Prom,         // writeRequests
	in_flight_write: Maybe(Prom),
	close_req:       Maybe(Prom),
	in_flight_close: Maybe(Prom),
	abort:           Maybe(Abort_Request),
	backpressure:    bool,
	// the controller
	queue:           Queue(WS_Item),
	q_total, hwm:    f64,
	started:         bool,
	sink, write_fn, close_fn, abort_fn, size_fn: wj.JSValue,   // undefined once cleared (ClearAlgorithms)
	abort_controller: wj.JSValue,           // its signal is controller.signal
}

@(private = "file")
Writer :: struct {
	stream:        wj.JSValue,
	closed, ready: Prom,
}

@(private = "file")
WS_Controller :: struct {
	stream: wj.JSValue,
}

// ---- life ----

@(private = "file")
maybe_free_rt :: proc "contextless" (rt: ^wj.Runtime, p: ^Maybe(Prom)) {
	if v, ok := &p.?; ok { prom_free_rt(rt, v) }
}

@(private = "file")
maybe_mark :: proc "contextless" (rt: rawptr, p: ^Maybe(Prom), mf: rawptr) {
	if v, ok := &p.?; ok { prom_mark(rt, v, mf) }
}

@(private = "file")
ws_free :: proc "c" (v: rawptr) {
	context = wj.heap_context()
	w := (^Writable)(v)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, w.stored_error)
	wj.JS_FreeValueRT(rt, w.writer)
	wj.JS_FreeValueRT(rt, w.controller)
	for &p in w.write_reqs { prom_free_rt(rt, &p) }
	delete(w.write_reqs)
	maybe_free_rt(rt, &w.in_flight_write)
	maybe_free_rt(rt, &w.close_req)
	maybe_free_rt(rt, &w.in_flight_close)
	if a, ok := &w.abort.?; ok { prom_free_rt(rt, &a.prom); wj.JS_FreeValueRT(rt, a.reason) }
	for it in q_items(&w.queue) { wj.JS_FreeValueRT(rt, it.value) }
	q_destroy(&w.queue)
	for f in ([?]wj.JSValue{w.sink, w.write_fn, w.close_fn, w.abort_fn, w.size_fn, w.abort_controller}) { wj.JS_FreeValueRT(rt, f) }
	free(w)
}

@(private = "file")
ws_mark :: proc "c" (rt: rawptr, v: rawptr, mf: rawptr) {
	w := (^Writable)(v)
	wj.wj_mark(rt, w.stored_error, mf)
	wj.wj_mark(rt, w.writer, mf)
	wj.wj_mark(rt, w.controller, mf)
	for &p in w.write_reqs { prom_mark(rt, &p, mf) }
	maybe_mark(rt, &w.in_flight_write, mf)
	maybe_mark(rt, &w.close_req, mf)
	maybe_mark(rt, &w.in_flight_close, mf)
	if a, ok := &w.abort.?; ok { prom_mark(rt, &a.prom, mf); wj.wj_mark(rt, a.reason, mf) }
	for it in q_items(&w.queue) { wj.wj_mark(rt, it.value, mf) }
	for f in ([?]wj.JSValue{w.sink, w.write_fn, w.close_fn, w.abort_fn, w.size_fn, w.abort_controller}) { wj.wj_mark(rt, f, mf) }
}

@(private = "file")
writer_free :: proc "c" (v: rawptr) {
	context = wj.heap_context()
	wr := (^Writer)(v)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, wr.stream)
	prom_free_rt(rt, &wr.closed)
	prom_free_rt(rt, &wr.ready)
	free(wr)
}

@(private = "file")
writer_mark :: proc "c" (rt: rawptr, v: rawptr, mf: rawptr) {
	wr := (^Writer)(v)
	wj.wj_mark(rt, wr.stream, mf)
	prom_mark(rt, &wr.closed, mf)
	prom_mark(rt, &wr.ready, mf)
}

@(private = "file")
ws_ctrl_free :: proc "c" (v: rawptr) {
	context = wj.heap_context()
	wj.JS_FreeValueRT(wj.web_rt(), (^WS_Controller)(v).stream)
	free(v)
}

@(private = "file")
ws_ctrl_mark :: proc "c" (rt: rawptr, v: rawptr, mf: rawptr) { wj.wj_mark(rt, (^WS_Controller)(v).stream, mf) }

@(private = "file")
ws_of :: proc "contextless" (v: wj.JSValue) -> ^Writable {
	return (^Writable)(wj.impl_of(wj.wj_unwrap(v, net_iface(.WritableStream))))
}

@(private = "file")
writer_of :: proc "contextless" (v: wj.JSValue) -> ^Writer {
	return (^Writer)(wj.impl_of(wj.wj_unwrap(v, net_iface(.WritableStreamDefaultWriter))))
}

// ---- the controller's queue ----

@(private = "file")
q_clear_values :: proc(ctx: ^wj.Context, w: ^Writable) {
	for it in q_items(&w.queue) { wj.JS_FreeValue(ctx, it.value) }
	q_reset(&w.queue)
	w.q_total = 0
}

@(private = "file")
ws_enqueue :: proc(w: ^Writable, v: wj.JSValue, size: f64, close: bool) -> bool {
	if !q_push(&w.queue, WS_Item{v, size, close}) { return false }
	w.q_total += size
	return true
}

@(private = "file")
ws_dequeue :: proc "contextless" (ctx: ^wj.Context, w: ^Writable) {
	it := q_pop(&w.queue)
	w.q_total = max(w.q_total - it.size, 0)
	wj.JS_FreeValue(ctx, it.value)
}

@(private = "file") desired :: #force_inline proc "contextless" (w: ^Writable) -> f64 { return w.hwm - w.q_total }
@(private = "file") get_backpressure :: #force_inline proc "contextless" (w: ^Writable) -> bool { return desired(w) <= 0 }
@(private = "file") close_queued_or_in_flight :: #force_inline proc "contextless" (w: ^Writable) -> bool { return w.close_req != nil || w.in_flight_close != nil }
@(private = "file") has_operation_in_flight :: #force_inline proc "contextless" (w: ^Writable) -> bool { return w.in_flight_write != nil || w.in_flight_close != nil }

@(private = "file")
clear_algorithms :: proc "contextless" (ctx: ^wj.Context, w: ^Writable) {
	wj.free_values(ctx, w.write_fn, w.close_fn, w.abort_fn, w.size_fn)
	w.write_fn, w.close_fn, w.abort_fn, w.size_fn = wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
}

// an algorithm of the sink as a promise (no method: resolved undefined; a throw: rejected)
@(private = "file")
sink_promise :: proc "contextless" (ctx: ^wj.Context, w: ^Writable, fn: wj.JSValue, args: []wj.JSValue) -> wj.JSValue {
	if !wj.JS_IsFunction(ctx, fn) { return wj.web_promise_take(ctx, wj.UNDEFINED) }
	return promise_of(ctx, wj.JS_Call(ctx, fn, w.sink, i32(len(args)), raw_data(args)))
}

// p.then(ok, err) with data = [stream] (p taken)
@(private = "file")
then_ws :: proc "contextless" (ctx: ^wj.Context, p: wj.JSValue, ok, err: wj.Native_Data, w: ^Writable) {
	then_drop(ctx, p, ok != nil ? ok : noop_reaction, err != nil ? err : noop_reaction, w.self)
	wj.JS_FreeValue(ctx, p)
}

// The settled promise of a finished request, resolved or rejected, then gone.
@(private = "file")
settle_taken :: proc "contextless" (ctx: ^wj.Context, m: ^Maybe(Prom), reject: bool, v: wj.JSValue) {
	p, ok := m.?
	if !ok { return }
	m^ = nil
	if reject { prom_reject(ctx, &p, v) } else { prom_resolve(ctx, &p, v) }
	prom_clear(ctx, &p)
}

// ---- the stream's algorithms ----

@(private = "file")
update_backpressure :: proc "contextless" (ctx: ^wj.Context, w: ^Writable, bp: bool) {
	if wr := writer_of(w.writer); wr != nil && bp != w.backpressure {
		if bp { prom_new(ctx, &wr.ready); mark_handled(ctx, wr.ready.p) } else { prom_resolve(ctx, &wr.ready, wj.UNDEFINED) }
	}
	w.backpressure = bp
}

@(private = "file")
ensure_rejected :: proc "contextless" (ctx: ^wj.Context, p: ^Prom, e: wj.JSValue) {
	if prom_pending(p) { prom_reject(ctx, p, e) } else { prom_rejected(ctx, p, e) }
	mark_handled(ctx, p.p)
}

@(private = "file")
reject_close_and_closed_if_needed :: proc "contextless" (ctx: ^wj.Context, w: ^Writable) {
	settle_taken(ctx, &w.close_req, true, w.stored_error)
	if wr := writer_of(w.writer); wr != nil { prom_reject(ctx, &wr.closed, w.stored_error); mark_handled(ctx, wr.closed.p) }
}

// the pending abort request settled (with `reject` and `v`), then gone
@(private = "file")
abort_settle :: proc "contextless" (ctx: ^wj.Context, w: ^Writable, reject: bool, v: wj.JSValue) {
	a, ok := w.abort.?
	if !ok { return }
	w.abort = nil
	if reject { prom_reject(ctx, &a.prom, v) } else { prom_resolve(ctx, &a.prom, v) }
	prom_clear(ctx, &a.prom)
	wj.JS_FreeValue(ctx, a.reason)
}

@(private = "file")
finish_erroring :: proc(ctx: ^wj.Context, w: ^Writable) {
	w.state = .Errored
	q_clear_values(ctx, w)   // the controller's [[ErrorSteps]]
	reqs := w.write_reqs
	w.write_reqs = nil
	for &r in reqs { prom_reject(ctx, &r, w.stored_error); prom_clear(ctx, &r) }
	delete(reqs)
	a, has := w.abort.?
	if !has { reject_close_and_closed_if_needed(ctx, w); return }
	if a.was_erroring {
		abort_settle(ctx, w, true, w.stored_error)
		reject_close_and_closed_if_needed(ctx, w)
		return
	}
	// the controller's [[AbortSteps]](reason)
	fn := wj.JS_DupValue(ctx, w.abort_fn)
	reason := a.reason
	p := sink_promise(ctx, w, fn, {reason})
	wj.JS_FreeValue(ctx, fn)
	clear_algorithms(ctx, w)
	then_ws(ctx, p, abort_done, abort_failed, w)
}

@(private = "file")
abort_done :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	w := ws_of(data[0])
	if w == nil { return wj.UNDEFINED }
	abort_settle(ctx, w, false, wj.UNDEFINED)
	reject_close_and_closed_if_needed(ctx, w)
	return wj.UNDEFINED
}

@(private = "file")
abort_failed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	w := ws_of(data[0])
	if w == nil { return wj.UNDEFINED }
	abort_settle(ctx, w, true, wj.arg(argc, argv, 0))
	reject_close_and_closed_if_needed(ctx, w)
	return wj.UNDEFINED
}

@(private = "file")
start_erroring :: proc(ctx: ^wj.Context, w: ^Writable, reason: wj.JSValue) {
	w.state = .Erroring
	wj.JS_FreeValue(ctx, w.stored_error)
	w.stored_error = wj.JS_DupValue(ctx, reason)
	if wr := writer_of(w.writer); wr != nil { ensure_rejected(ctx, &wr.ready, reason) }
	if !has_operation_in_flight(w) && w.started { finish_erroring(ctx, w) }
}

@(private = "file")
deal_with_rejection :: proc(ctx: ^wj.Context, w: ^Writable, e: wj.JSValue) {
	if w.state == .Writable { start_erroring(ctx, w, e); return }
	finish_erroring(ctx, w)
}

@(private = "file")
controller_error :: proc(ctx: ^wj.Context, w: ^Writable, e: wj.JSValue) {
	clear_algorithms(ctx, w)
	start_erroring(ctx, w, e)
}

@(private = "file")
controller_error_if_needed :: proc(ctx: ^wj.Context, w: ^Writable, e: wj.JSValue) {
	if w.state == .Writable { controller_error(ctx, w, e) }
}

@(private = "file")
write_done :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := ws_of(data[0])
	if w == nil { return wj.UNDEFINED }
	// FinishInFlightWrite
	settle_taken(ctx, &w.in_flight_write, false, wj.UNDEFINED)
	if !q_empty(&w.queue) { ws_dequeue(ctx, w) }
	if !close_queued_or_in_flight(w) && w.state == .Writable { update_backpressure(ctx, w, get_backpressure(w)) }
	advance_queue(ctx, w)
	return wj.UNDEFINED
}

@(private = "file")
write_failed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := ws_of(data[0])
	if w == nil { return wj.UNDEFINED }
	e := wj.arg(argc, argv, 0)
	if w.state == .Writable { clear_algorithms(ctx, w) }
	// FinishInFlightWriteWithError
	settle_taken(ctx, &w.in_flight_write, true, e)
	deal_with_rejection(ctx, w, e)
	return wj.UNDEFINED
}

@(private = "file")
close_done :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	w := ws_of(data[0])
	if w == nil { return wj.UNDEFINED }
	// FinishInFlightClose
	settle_taken(ctx, &w.in_flight_close, false, wj.UNDEFINED)
	if w.state == .Erroring {
		wj.JS_FreeValue(ctx, w.stored_error)
		w.stored_error = wj.UNDEFINED
		abort_settle(ctx, w, false, wj.UNDEFINED)
	}
	w.state = .Closed
	if wr := writer_of(w.writer); wr != nil { prom_resolve(ctx, &wr.closed, wj.UNDEFINED) }
	return wj.UNDEFINED
}

@(private = "file")
close_failed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := ws_of(data[0])
	if w == nil { return wj.UNDEFINED }
	e := wj.arg(argc, argv, 0)
	// FinishInFlightCloseWithError
	settle_taken(ctx, &w.in_flight_close, true, e)
	abort_settle(ctx, w, true, e)
	deal_with_rejection(ctx, w, e)
	return wj.UNDEFINED
}

// WritableStreamDefaultControllerAdvanceQueueIfNeeded
@(private = "file")
advance_queue :: proc(ctx: ^wj.Context, w: ^Writable) {
	if !w.started || w.in_flight_write != nil { return }
	switch w.state {
	case .Closed, .Errored: return
	case .Erroring:         finish_erroring(ctx, w); return
	case .Writable:
	}
	if q_empty(&w.queue) { return }
	head := q_front(&w.queue)^
	if head.close {
		// ProcessClose: MarkCloseRequestInFlight
		w.in_flight_close = w.close_req
		w.close_req = nil
		ws_dequeue(ctx, w)
		fn := wj.JS_DupValue(ctx, w.close_fn)
		p := sink_promise(ctx, w, fn, nil)
		wj.JS_FreeValue(ctx, fn)
		clear_algorithms(ctx, w)
		then_ws(ctx, p, close_done, close_failed, w)
		return
	}
	// ProcessWrite: MarkFirstWriteRequestInFlight
	w.in_flight_write = w.write_reqs[0]
	ordered_remove(&w.write_reqs, 0)
	chunk := wj.JS_DupValue(ctx, head.value)
	fn := wj.JS_DupValue(ctx, w.write_fn)
	p := sink_promise(ctx, w, fn, {chunk, w.controller})
	wj.JS_FreeValue(ctx, fn)
	wj.JS_FreeValue(ctx, chunk)
	then_ws(ctx, p, write_done, write_failed, w)
}

@(private = "file")
on_started :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if w := ws_of(data[0]); w != nil { w.started = true; advance_queue(ctx, w) }
	return wj.UNDEFINED
}

@(private = "file")
start_failed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if w := ws_of(data[0]); w != nil { w.started = true; deal_with_rejection(ctx, w, wj.arg(argc, argv, 0)) }
	return wj.UNDEFINED
}

// WritableStreamAbort
@(private = "file")
stream_abort :: proc(ctx: ^wj.Context, w: ^Writable, reason_in: wj.JSValue) -> wj.JSValue {
	if w.state == .Closed || w.state == .Errored { return wj.web_promise_take(ctx, wj.UNDEFINED) }
	// signal abort(controller.[[abortController]], reason)
	if wj.is_object(w.abort_controller) {
		f := wj.JS_GetPropertyStr(ctx, w.abort_controller, "abort")
		r := reason_in
		wj.discard(ctx, wj.JS_Call(ctx, f, w.abort_controller, 1, &r))
		wj.JS_FreeValue(ctx, f)
	}
	if w.state == .Closed || w.state == .Errored { return wj.web_promise_take(ctx, wj.UNDEFINED) }
	if a, ok := w.abort.?; ok { return wj.JS_DupValue(ctx, a.prom.p) }
	was_erroring := w.state == .Erroring
	reason := was_erroring ? wj.UNDEFINED : reason_in
	a := Abort_Request{prom = PROM_NONE, reason = wj.JS_DupValue(ctx, reason), was_erroring = was_erroring}
	prom_new(ctx, &a.prom)
	w.abort = a
	p := wj.JS_DupValue(ctx, a.prom.p)
	if !was_erroring { start_erroring(ctx, w, reason) }
	return p
}

// WritableStreamClose
@(private = "file")
stream_close :: proc(ctx: ^wj.Context, w: ^Writable) -> wj.JSValue {
	if w.state == .Closed || w.state == .Errored {
		wj.JS_ThrowTypeError(ctx, "The stream is closed or errored.")
		return wj.web_promise_reject_pending(ctx)
	}
	req := PROM_NONE
	prom_new(ctx, &req)
	w.close_req = req
	p := wj.JS_DupValue(ctx, req.p)
	if wr := writer_of(w.writer); wr != nil && w.backpressure && w.state == .Writable { prom_resolve(ctx, &wr.ready, wj.UNDEFINED) }
	ws_enqueue(w, wj.UNDEFINED, 0, true)
	advance_queue(ctx, w)
	return p
}

// WritableStreamDefaultWriterWrite
@(private = "file")
writer_write :: proc(ctx: ^wj.Context, writer: wj.JSValue, chunk: wj.JSValue) -> wj.JSValue {
	wr := writer_of(writer)
	w := wr != nil ? ws_of(wr.stream) : nil
	if w == nil { wj.JS_ThrowTypeError(ctx, "The writer has been released."); return wj.web_promise_reject_pending(ctx) }
	keep := wj.JS_DupValue(ctx, wr.stream)
	defer wj.JS_FreeValue(ctx, keep)
	// GetChunkSize
	size := 1.0
	if wj.JS_IsFunction(ctx, w.size_fn) {
		fn := wj.JS_DupValue(ctx, w.size_fn)
		c := chunk
		r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 1, &c)
		wj.JS_FreeValue(ctx, fn)
		if wj.is_exception(r) {
			e := wj.JS_GetException(ctx)
			controller_error_if_needed(ctx, w, e)
			wj.JS_FreeValue(ctx, e)
		} else {
			if wj.JS_ToFloat64(ctx, &size, r) < 0 {
				e := wj.JS_GetException(ctx)
				controller_error_if_needed(ctx, w, e)
				wj.JS_FreeValue(ctx, e)
				size = 1
			}
			wj.JS_FreeValue(ctx, r)
		}
	}
	switch {
	case writer_of(w.writer) != wr:
		wj.JS_ThrowTypeError(ctx, "The writer has been released.")
		return wj.web_promise_reject_pending(ctx)
	case w.state == .Errored:
		return wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, w.stored_error))
	case close_queued_or_in_flight(w) || w.state == .Closed:
		wj.JS_ThrowTypeError(ctx, "The stream is closing or closed.")
		return wj.web_promise_reject_pending(ctx)
	case w.state == .Erroring:
		return wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, w.stored_error))
	}
	// WritableStreamAddWriteRequest
	rq := PROM_NONE
	prom_new(ctx, &rq)
	if _, err := append(&w.write_reqs, rq); err != nil {
		prom_clear(ctx, &rq)
		wj.JS_ThrowOutOfMemory(ctx)
		return wj.web_promise_reject_pending(ctx)
	}
	result := wj.JS_DupValue(ctx, rq.p)
	// WritableStreamDefaultControllerWrite
	if !(size >= 0) || wj.is_inf(size) {
		e := wj.web_range_error(ctx, "The size of a chunk must be a finite, non-negative number.")
		controller_error_if_needed(ctx, w, e)
		wj.JS_FreeValue(ctx, e)
	} else {
		c := wj.JS_DupValue(ctx, chunk)
		if !ws_enqueue(w, c, size, false) { wj.JS_FreeValue(ctx, c) }
		if !close_queued_or_in_flight(w) && w.state == .Writable { update_backpressure(ctx, w, get_backpressure(w)) }
		advance_queue(ctx, w)
	}
	return result
}

// ---- construction ----

@(private = "file")
sink_member :: proc "contextless" (ctx: ^wj.Context, sink: wj.JSValue, name: cstring, out: ^wj.JSValue) -> bool {
	out^ = wj.UNDEFINED
	if !wj.is_object(sink) { return true }
	v := wj.JS_GetPropertyStr(ctx, sink, name)
	if wj.is_exception(v) { return false }
	if !wj.is_undefined(v) && !wj.JS_IsFunction(ctx, v) {
		wj.JS_FreeValue(ctx, v)
		wj.JS_ThrowTypeError(ctx, "Failed to construct 'WritableStream': member %s is not a function.", name)
		return false
	}
	out^ = v
	return true
}

@(private = "file")
set_proto_from :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, proto_from: wj.JSValue) {
	if !wj.is_object(proto_from) { return }
	proto := wj.JS_GetPropertyStr(ctx, proto_from, "prototype")
	if wj.is_object(proto) { wj.JS_SetPrototype(ctx, obj, proto) }
	wj.JS_FreeValue(ctx, proto)
}

// A WritableStream of interface `iface` (WritableStream or one inheriting from it) on `sink`, with `hwm` and the size
// function `size` (undefined: 1 per chunk); `proto_from`: the new.target of a constructor (subclasses), or undefined.
@(private = "file")
writable_make :: proc(ctx: ^wj.Context, iface: i32, sink: wj.JSValue, hwm: f64, size: wj.JSValue, proto_from: wj.JSValue) -> wj.JSValue {
	abort_fn, close_fn, start_fn, write_fn := wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	// (the dictionary's members in order: abort, close, start, type (checked here), write)
	if !sink_member(ctx, sink, "abort", &abort_fn) { return wj.EXCEPTION }
	if !sink_member(ctx, sink, "close", &close_fn) { wj.JS_FreeValue(ctx, abort_fn); return wj.EXCEPTION }
	if !sink_member(ctx, sink, "start", &start_fn) { wj.free_values(ctx, abort_fn, close_fn); return wj.EXCEPTION }
	if wj.is_object(sink) {
		type := wj.JS_GetPropertyStr(ctx, sink, "type")
		has := !wj.is_undefined(type)
		wj.JS_FreeValue(ctx, type)
		if has {
			wj.free_values(ctx, abort_fn, close_fn, start_fn)
			return wj.JS_ThrowRangeError(ctx, "Failed to construct 'WritableStream': Invalid type is specified")
		}
	}
	if !sink_member(ctx, sink, "write", &write_fn) { wj.free_values(ctx, abort_fn, close_fn, start_fn); return wj.EXCEPTION }
	w := new(Writable)
	if w == nil { wj.free_values(ctx, abort_fn, close_fn, start_fn, write_fn); return wj.JS_ThrowOutOfMemory(ctx) }
	w.stored_error, w.writer, w.controller, w.abort_controller = wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	w.sink = wj.is_object(sink) ? wj.JS_DupValue(ctx, sink) : wj.UNDEFINED
	w.write_fn, w.close_fn, w.abort_fn, w.size_fn = write_fn, close_fn, abort_fn, wj.JS_DupValue(ctx, size)
	w.hwm = hwm
	obj := wj.wj_new_object(ctx, iface, nil, nil)
	if wj.is_exception(obj) { ws_free(w); wj.JS_FreeValue(ctx, start_fn); return obj }
	wj.web_set_impl(obj, w, ws_free, ws_mark)
	w.self = obj
	set_proto_from(ctx, obj, proto_from)
	// the controller and its AbortController
	ci := new(WS_Controller)
	ctrl := ci != nil ? wj.wj_new_object(ctx, net_iface(.WritableStreamDefaultController), nil, nil) : wj.JS_ThrowOutOfMemory(ctx)
	if wj.is_exception(ctrl) { free(ci); wj.JS_FreeValue(ctx, start_fn); wj.JS_FreeValue(ctx, obj); return ctrl }
	ci.stream = wj.JS_DupValue(ctx, obj)
	wj.web_set_impl(ctrl, ci, ws_ctrl_free, ws_ctrl_mark)
	w.controller = ctrl
	ac := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "AbortController")
	if wj.JS_IsFunction(ctx, ac) {
		w.abort_controller = wj.JS_CallConstructor(ctx, ac, 0, nil)
		if wj.is_exception(w.abort_controller) { wj.drop_exception(ctx); w.abort_controller = wj.UNDEFINED }
	}
	wj.JS_FreeValue(ctx, ac)
	// SetUpWritableStreamDefaultController
	update_backpressure(ctx, w, get_backpressure(w))
	start_result := wj.UNDEFINED
	if wj.JS_IsFunction(ctx, start_fn) {
		start_result = wj.JS_Call(ctx, start_fn, w.sink, 1, &w.controller)
		if wj.is_exception(start_result) { wj.JS_FreeValue(ctx, start_fn); wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	}
	wj.JS_FreeValue(ctx, start_fn)
	then_ws(ctx, wj.web_promise_take(ctx, start_result), on_started, start_failed, w)
	return obj
}

// 0 writable, 1 erroring, 2 errored, 3 closed (-1: not a WritableStream); `error`, when given, gets the stored error
// (counted)
@(export, link_name = "web_writable_state")
web_writable_state :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, error: ^wj.JSValue) -> i32 {
	w := ws_of(v)
	if w == nil { return -1 }
	if error != nil { error^ = wj.JS_DupValue(ctx, w.stored_error) }
	return i32(w.state)
}

// A WritableStream of `iface` on a sink object (FileSystemWritableFileStream's, from web_fs.c).
@(export, link_name = "web_writable_new")
web_writable_new :: proc "c" (ctx: ^wj.Context, iface: i32, sink: wj.JSValue, hwm: f64, proto_from: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return writable_make(ctx, iface, sink, hwm, wj.UNDEFINED, proto_from)
}

@(export, link_name = "wjr_WritableStream_constructor")
wjr_WritableStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor WritableStream requires 'new'") }
	sink, strategy := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)
	if !wj.is_nullish(sink) && !wj.is_object(sink) { return wj.wj_throw_type(ctx, "Failed to construct 'WritableStream': the underlying sink is not an object") }
	if !wj.web_dict_check(ctx, strategy, "QueuingStrategy") { return wj.EXCEPTION }
	// QueuingStrategy: highWaterMark, size
	hv, size := wj.UNDEFINED, wj.UNDEFINED
	if !wj.web_dict_get(ctx, strategy, "highWaterMark", &hv) { return wj.EXCEPTION }
	h := 1.0
	if !wj.is_undefined(hv) && wj.JS_ToFloat64(ctx, &h, hv) < 0 { wj.JS_FreeValue(ctx, hv); return wj.EXCEPTION }
	wj.JS_FreeValue(ctx, hv)
	if !wj.web_dict_get(ctx, strategy, "size", &size) { return wj.EXCEPTION }
	if !wj.is_undefined(size) && !wj.JS_IsFunction(ctx, size) {
		wj.JS_FreeValue(ctx, size)
		return wj.wj_throw_type(ctx, "Failed to construct 'WritableStream': member size is not a function.")
	}
	// (the sink is converted before the strategy is checked: Streams "new WritableStream" step 2, then 4)
	if wj.is_nan(h) || h < 0 { wj.JS_FreeValue(ctx, size); return wj.JS_ThrowRangeError(ctx, "Failed to construct 'WritableStream': invalid highWaterMark") }
	r := writable_make(ctx, net_iface(.WritableStream), wj.is_null(sink) ? wj.UNDEFINED : sink, h, size, new_target)
	wj.JS_FreeValue(ctx, size)
	return r
}

@(private = "file")
ws_this :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> ^Writable {
	return (^Writable)(wj.this_impl(ctx, t, net_iface(.WritableStream)))
}

@(export, link_name = "wjr_WritableStream_get_locked")
wjr_WritableStream_get_locked :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	w := ws_this(ctx, t)
	return w != nil ? wj.new_bool(!wj.is_undefined(w.writer)) : wj.EXCEPTION
}

@(export, link_name = "wjr_WritableStream_abort")
wjr_WritableStream_abort :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := ws_this(ctx, t)
	if w == nil { return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(w.writer) { wj.JS_ThrowTypeError(ctx, "Cannot abort a locked stream"); return wj.web_promise_reject_pending(ctx) }
	return stream_abort(ctx, w, wj.arg(argc, argv, 0))
}

@(export, link_name = "wjr_WritableStream_close")
wjr_WritableStream_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := ws_this(ctx, t)
	if w == nil { return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(w.writer) { wj.JS_ThrowTypeError(ctx, "Cannot close a locked stream"); return wj.web_promise_reject_pending(ctx) }
	if close_queued_or_in_flight(w) { wj.JS_ThrowTypeError(ctx, "Cannot close a stream that is already closing"); return wj.web_promise_reject_pending(ctx) }
	return stream_close(ctx, w)
}

// ---- the writer ----

// SetUpWritableStreamDefaultWriter
@(private = "file")
writer_new :: proc(ctx: ^wj.Context, stream: wj.JSValue, proto_from: wj.JSValue) -> wj.JSValue {
	w := ws_of(stream)
	if w == nil { return wj.wj_throw_type(ctx, "Failed to construct 'WritableStreamDefaultWriter': parameter 1 is not of type 'WritableStream'.") }
	if !wj.is_undefined(w.writer) { return wj.wj_throw_type(ctx, "Failed to construct 'WritableStreamDefaultWriter': the stream is locked") }
	wr := new(Writer)
	if wr == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	wr^ = {stream = wj.JS_DupValue(ctx, stream), closed = PROM_NONE, ready = PROM_NONE}
	obj := wj.wj_new_object(ctx, net_iface(.WritableStreamDefaultWriter), nil, nil)
	if wj.is_exception(obj) { writer_free(wr); return obj }
	wj.web_set_impl(obj, wr, writer_free, writer_mark)
	set_proto_from(ctx, obj, proto_from)
	w.writer = wj.JS_DupValue(ctx, obj)
	switch w.state {
	case .Writable:
		if !close_queued_or_in_flight(w) && w.backpressure { prom_new(ctx, &wr.ready) } else { prom_resolved(ctx, &wr.ready) }
		prom_new(ctx, &wr.closed)
	case .Erroring:
		prom_rejected(ctx, &wr.ready, w.stored_error)
		prom_new(ctx, &wr.closed)
	case .Closed:
		prom_resolved(ctx, &wr.ready)
		prom_resolved(ctx, &wr.closed)
	case .Errored:
		prom_rejected(ctx, &wr.ready, w.stored_error)
		prom_rejected(ctx, &wr.closed, w.stored_error)
	}
	mark_handled(ctx, wr.ready.p)
	mark_handled(ctx, wr.closed.p)
	return obj
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_constructor")
wjr_WritableStreamDefaultWriter_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor WritableStreamDefaultWriter requires 'new'") }
	return writer_new(ctx, wj.arg(argc, argv, 0), new_target)
}

@(export, link_name = "wjr_WritableStream_getWriter")
wjr_WritableStream_getWriter :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if ws_this(ctx, t) == nil { return wj.EXCEPTION }
	return writer_new(ctx, t, wj.UNDEFINED)
}

@(private = "file")
writer_this :: #force_inline proc "contextless" (ctx: ^wj.Context, t: wj.JSValue) -> ^Writer {
	return (^Writer)(wj.this_impl(ctx, t, net_iface(.WritableStreamDefaultWriter)))
}

// the writer's stream while it holds the lock (nil: released, with nothing thrown)
@(private = "file")
writer_stream :: #force_inline proc "contextless" (wr: ^Writer) -> ^Writable { return wr != nil ? ws_of(wr.stream) : nil }

@(private = "file")
released :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	wj.JS_ThrowTypeError(ctx, "The writer has been released.")
	return wj.web_promise_reject_pending(ctx)
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_write")
wjr_WritableStreamDefaultWriter_write :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	wr := writer_this(ctx, t)
	if wr == nil { return wj.web_promise_reject_pending(ctx) }
	if writer_stream(wr) == nil { return released(ctx) }
	return writer_write(ctx, t, wj.arg(argc, argv, 0))
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_close")
wjr_WritableStreamDefaultWriter_close :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	wr := writer_this(ctx, t)
	if wr == nil { return wj.web_promise_reject_pending(ctx) }
	w := writer_stream(wr)
	if w == nil { return released(ctx) }
	if close_queued_or_in_flight(w) { wj.JS_ThrowTypeError(ctx, "Cannot close a stream that is already closing"); return wj.web_promise_reject_pending(ctx) }
	return stream_close(ctx, w)
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_abort")
wjr_WritableStreamDefaultWriter_abort :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	wr := writer_this(ctx, t)
	if wr == nil { return wj.web_promise_reject_pending(ctx) }
	w := writer_stream(wr)
	if w == nil { return released(ctx) }
	return stream_abort(ctx, w, wj.arg(argc, argv, 0))
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_releaseLock")
wjr_WritableStreamDefaultWriter_releaseLock :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wr := writer_this(ctx, t)
	if wr == nil { return wj.EXCEPTION }
	w := writer_stream(wr)
	if w == nil { return wj.UNDEFINED }
	// WritableStreamDefaultWriterRelease
	e := wj.web_type_error(ctx, "The writer has been released.")
	ensure_rejected(ctx, &wr.ready, e)
	ensure_rejected(ctx, &wr.closed, e)
	wj.JS_FreeValue(ctx, e)
	old, s := w.writer, wr.stream
	w.writer = wj.UNDEFINED
	wr.stream = wj.UNDEFINED
	wj.JS_FreeValue(ctx, old)
	wj.JS_FreeValue(ctx, s)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_get_closed")
wjr_WritableStreamDefaultWriter_get_closed :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	wr := writer_this(ctx, t)
	return wr != nil ? wj.JS_DupValue(ctx, wr.closed.p) : wj.EXCEPTION
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_get_ready")
wjr_WritableStreamDefaultWriter_get_ready :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	wr := writer_this(ctx, t)
	return wr != nil ? wj.JS_DupValue(ctx, wr.ready.p) : wj.EXCEPTION
}

@(export, link_name = "wjr_WritableStreamDefaultWriter_get_desiredSize")
wjr_WritableStreamDefaultWriter_get_desiredSize :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	wr := writer_this(ctx, t)
	if wr == nil { return wj.EXCEPTION }
	w := writer_stream(wr)
	if w == nil { return wj.wj_throw_type(ctx, "The writer has been released.") }
	switch w.state {
	case .Errored, .Erroring: return wj.NULL
	case .Closed:             return wj.new_int32(0)
	case .Writable:           return wj.new_float64(ctx, desired(w))
	}
	return wj.NULL
}

// ---- the controller ----

@(export, link_name = "wjr_WritableStreamDefaultController_error")
wjr_WritableStreamDefaultController_error :: proc "c" (ctx: ^wj.Context, t: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	ci := (^WS_Controller)(wj.this_impl(ctx, t, net_iface(.WritableStreamDefaultController)))
	if ci == nil { return wj.EXCEPTION }
	if w := ws_of(ci.stream); w != nil && w.state == .Writable { controller_error(ctx, w, wj.arg(argc, argv, 0)) }
	return wj.UNDEFINED
}

@(export, link_name = "wjr_WritableStreamDefaultController_get_signal")
wjr_WritableStreamDefaultController_get_signal :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue {
	ci := (^WS_Controller)(wj.this_impl(ctx, t, net_iface(.WritableStreamDefaultController)))
	if ci == nil { return wj.EXCEPTION }
	w := ws_of(ci.stream)
	if w == nil || !wj.is_object(w.abort_controller) { return wj.UNDEFINED }
	return wj.JS_GetPropertyStr(ctx, w.abort_controller, "signal")
}

// FileSystemWritableFileStream.write / seek / truncate: a writer is acquired, written with, then released (a locked
// stream: TypeError).
@(export, link_name = "web_writable_write")
web_writable_write :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue, chunk: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	w := ws_of(stream)
	if w == nil { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(w.writer) { wj.JS_ThrowTypeError(ctx, "The stream is locked."); return wj.web_promise_reject_pending(ctx) }
	writer := writer_new(ctx, stream, wj.UNDEFINED)
	if wj.is_exception(writer) { return wj.web_promise_reject_pending(ctx) }
	r := writer_write(ctx, writer, chunk)
	wj.JS_FreeValue(ctx, wjr_WritableStreamDefaultWriter_releaseLock(ctx, writer, 0, nil))
	wj.JS_FreeValue(ctx, writer)
	return r
}
