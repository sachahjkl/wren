// web_stream.odin: ReadableStream (Streams Standard), default readers and controllers: what fetch bodies, Blob.stream()
// and scripts' own streams need. Ported from native/js/runtime/web_stream.c: same wjr_* / web_stream_* symbols and
// behaviour.
//
// A stream has a queue of chunks, pending read requests and a source: a script's underlying source ({start, pull,
// cancel} with a ReadableStreamDefaultController), a browser body stream (module fetch: one Stream_read at a time,
// Uint8Array chunks), or a branch of tee(); none for the streams the engine feeds (web_stream_pending) or fills at once.
// The source is a tagged union: each kind carries only its own state, and marking / freeing / pulling switch on it.
// getReader() locks the stream; reader.read() takes the next chunk or waits for one; async iteration (for await) reads
// through a reader; pipeTo / pipeThrough are web_pipe.odin. Not implemented: byte streams' BYOB readers (type: "bytes"
// gives a default controller), queuing strategies' size() (each chunk counts 1 against highWaterMark).
package odin_glue

import "../odin/wj"

@(private = "file") RS_State :: enum i32 { Readable, Closed, Errored }

// tee(): the state both branches share (each branch counts one reference).
@(private = "file")
Tee_State :: struct {
	refs:       u32,
	reading:    bool,
	read_again: bool,
	canceled:   [2]bool,
	clone2:     bool,                // chunks are copied for the second branch (Response.clone)
	branch:     [2]^Stream,          // not counted: cleared when a branch dies
	reasons:    [2]wj.JSValue,       // counted (marked by the branch that set it)
	// what cancel() of a branch answers: settled when both are cancelled (or the teed stream errors). Counted, undefined until asked
	cancel_promise: wj.JSValue,
	cancel_funcs:   [2]wj.JSValue,
}

@(private = "file")
Js_Source :: struct {
	source, pull, cancel_fn, controller: wj.JSValue,
}

// a browser body stream (owned): one Stream_read in flight at a time
@(private = "file")
Host_Source :: struct {
	host:         u64,
	reading:      bool,
	signal, keep: wj.JSValue,   // the request's signal (its reason errors the stream); the Response, kept alive
}

@(private = "file")
Tee_Source :: struct {
	tee:    ^Tee_State,
	branch: int,
	reader: wj.JSValue,          // the reader of the teed stream (counted per branch)
}

@(private = "file") Source :: union { Js_Source, Host_Source, Tee_Source }

// a pending read: its promise's resolving functions
@(private = "file") Read_Request :: [2]wj.JSValue

@(private = "file")
Stream :: struct {
	state:           RS_State,
	disturbed:       bool,
	close_requested: bool,
	started:         bool,
	pulling:         bool,
	pull_again:      bool,
	error:           wj.JSValue,
	queue:           Queue(wj.JSValue),
	reqs:            [dynamic]Read_Request,
	reader:          wj.JSValue,     // the reader holding the lock, or undefined
	hwm:             f64,
	source:          Source,         // nil: the engine's own stream
	self:            wj.JSValue,     // not counted
}

@(private = "file")
Reader :: struct {
	stream:       wj.JSValue,        // undefined once released
	closed:       wj.JSValue,
	closed_funcs: [2]wj.JSValue,
}

@(private = "file")
Stream_Controller :: struct {
	stream: wj.JSValue,
}

@(private = "file") async_iter_proto: wj.JSValue   // %AsyncIteratorPrototype% (counted; set at pre-initialization)
@(private = "file") iter_proto := wj.UNDEFINED     // what a stream's iterators inherit from, over it (made on first use)

// ---- life ----

@(private = "file")
stream_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	s := (^Stream)(p)
	rt := wj.web_rt()
	for v in q_items(&s.queue) { wj.JS_FreeValueRT(rt, v) }
	q_destroy(&s.queue)
	for r in s.reqs { wj.JS_FreeValueRT(rt, r[0]); wj.JS_FreeValueRT(rt, r[1]) }
	delete(s.reqs)
	wj.JS_FreeValueRT(rt, s.error)
	wj.JS_FreeValueRT(rt, s.reader)
	switch &src in s.source {
	case Js_Source:
		wj.JS_FreeValueRT(rt, src.source)
		wj.JS_FreeValueRT(rt, src.pull)
		wj.JS_FreeValueRT(rt, src.cancel_fn)
		wj.JS_FreeValueRT(rt, src.controller)
	case Host_Source:
		wj.JS_FreeValueRT(rt, src.signal)
		wj.JS_FreeValueRT(rt, src.keep)
		if src.host != 0 { wj.wr_Stream_cancel(src.host); wj.wr_Object_release(src.host) }
	case Tee_Source:
		wj.JS_FreeValueRT(rt, src.reader)
		if t := src.tee; t != nil {
			t.branch[src.branch] = nil
			wj.JS_FreeValueRT(rt, t.reasons[src.branch])
			t.reasons[src.branch] = wj.UNDEFINED
			t.refs -= 1
			if t.refs == 0 {
				wj.JS_FreeValueRT(rt, t.cancel_promise)
				wj.JS_FreeValueRT(rt, t.cancel_funcs[0])
				wj.JS_FreeValueRT(rt, t.cancel_funcs[1])
				free(t)
			}
		}
	}
	free(s)
}

@(private = "file")
stream_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) {
	s := (^Stream)(p)
	for v in q_items(&s.queue) { wj.wj_mark(rt, v, mf) }
	for r in s.reqs { wj.wj_mark(rt, r[0], mf); wj.wj_mark(rt, r[1], mf) }
	wj.wj_mark(rt, s.error, mf)
	wj.wj_mark(rt, s.reader, mf)
	switch src in s.source {
	case Js_Source:
		wj.wj_mark(rt, src.source, mf)
		wj.wj_mark(rt, src.pull, mf)
		wj.wj_mark(rt, src.cancel_fn, mf)
		wj.wj_mark(rt, src.controller, mf)
	case Host_Source:
		wj.wj_mark(rt, src.signal, mf)
		wj.wj_mark(rt, src.keep, mf)
	case Tee_Source:
		wj.wj_mark(rt, src.reader, mf)
		if t := src.tee; t != nil {
			wj.wj_mark(rt, t.reasons[src.branch], mf)
			wj.wj_mark(rt, t.cancel_promise, mf)
			wj.wj_mark(rt, t.cancel_funcs[0], mf)
			wj.wj_mark(rt, t.cancel_funcs[1], mf)
		}
	}
}

@(private = "file")
reader_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	r := (^Reader)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, r.stream)
	wj.JS_FreeValueRT(rt, r.closed)
	wj.JS_FreeValueRT(rt, r.closed_funcs[0])
	wj.JS_FreeValueRT(rt, r.closed_funcs[1])
	free(r)
}

@(private = "file")
reader_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) {
	r := (^Reader)(p)
	wj.wj_mark(rt, r.stream, mf)
	wj.wj_mark(rt, r.closed, mf)
	wj.wj_mark(rt, r.closed_funcs[0], mf)
	wj.wj_mark(rt, r.closed_funcs[1], mf)
}

@(private = "file")
stream_controller_free :: proc "c" (p: rawptr) {
	context = wj.heap_context()
	wj.JS_FreeValueRT(wj.web_rt(), (^Stream_Controller)(p).stream)
	free(p)
}

@(private = "file")
stream_controller_mark :: proc "c" (rt: rawptr, p: rawptr, mf: rawptr) { wj.wj_mark(rt, (^Stream_Controller)(p).stream, mf) }

@(private = "file")
stream_of :: proc "contextless" (v: wj.JSValue) -> ^Stream {
	return (^Stream)(wj.impl_of(wj.wj_unwrap(v, net_iface(.ReadableStream))))
}

@(private = "file")
reader_of :: proc "contextless" (v: wj.JSValue) -> ^Reader {
	return (^Reader)(wj.impl_of(wj.wj_unwrap(v, net_iface(.ReadableStreamDefaultReader))))
}

@(export, link_name = "web_stream_is")
web_stream_is :: proc "c" (v: wj.JSValue) -> bool { return stream_of(v) != nil }

// 0 readable, 1 closed, 2 errored (-1: not a stream); `error`, when given, gets the stored error (counted)
@(export, link_name = "web_stream_state")
web_stream_state :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, error: ^wj.JSValue) -> i32 {
	s := stream_of(v)
	if s == nil { return -1 }
	if error != nil { error^ = wj.JS_DupValue(ctx, s.error) }
	return i32(s.state)
}

@(export, link_name = "web_stream_locked")
web_stream_locked :: proc "c" (v: wj.JSValue) -> bool { s := stream_of(v); return s != nil && !wj.is_undefined(s.reader) }

@(export, link_name = "web_stream_disturbed")
web_stream_disturbed :: proc "c" (v: wj.JSValue) -> bool { s := stream_of(v); return s != nil && s.disturbed }

@(private = "file")
stream_new :: proc(ctx: ^wj.Context, new_target: wj.JSValue, source: Source) -> wj.JSValue {
	s := new(Stream)
	if s == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	s.error, s.reader = wj.UNDEFINED, wj.UNDEFINED
	s.hwm = 1
	s.source = source
	obj := wj.wj_new_object_for(ctx, net_iface(.ReadableStream), new_target, nil, nil)
	if wj.is_exception(obj) { free(s); return obj }
	s.self = obj
	wj.web_set_impl(obj, s, stream_free, stream_mark)
	return obj
}

// ---- the stream's algorithms ----

@(private = "file")
desired_size :: proc "contextless" (s: ^Stream) -> f64 {
	switch s.state {
	case .Errored:  return NAN_F64
	case .Closed:   return 0
	case .Readable: return s.hwm - f64(q_len(&s.queue))
	}
	return 0
}

@(private = "file")
resolve_closed :: proc "contextless" (ctx: ^wj.Context, s: ^Stream, reject: bool) {
	r := reader_of(s.reader)
	if r == nil || wj.is_undefined(r.closed_funcs[0]) { return }
	f, other := r.closed_funcs[reject ? 1 : 0], r.closed_funcs[reject ? 0 : 1]
	r.closed_funcs = {wj.UNDEFINED, wj.UNDEFINED}
	if reject { wj.JS_PromiseMarkAsHandled(ctx, r.closed) }
	wj.web_settle(ctx, f, reject ? wj.JS_DupValue(ctx, s.error) : wj.UNDEFINED)
	wj.JS_FreeValue(ctx, f)
	wj.JS_FreeValue(ctx, other)
}

// Settling a read with a {value, done} object reads its `then` (a getter on Object.prototype runs a script, which can
// release the reader, the last reference to the stream): every algorithm that settles holds the stream's object while
// it still uses `s` (stream_hold / JS_FreeValue).
@(private = "file")
stream_hold :: #force_inline proc "contextless" (ctx: ^wj.Context, s: ^Stream) -> wj.JSValue { return wj.JS_DupValue(ctx, s.self) }

// the pending reads, taken off the stream (settling them may run scripts that read again)
@(private = "file")
take_requests :: proc(s: ^Stream) -> [dynamic]Read_Request {
	reqs := s.reqs
	s.reqs = nil
	return reqs
}

// the stream is closed for good: pending reads end with done
@(private = "file")
finish_close :: proc(ctx: ^wj.Context, s: ^Stream) {
	if s.state != .Readable { return }
	keep := stream_hold(ctx, s)
	defer wj.JS_FreeValue(ctx, keep)
	s.state = .Closed
	reqs := take_requests(s)
	for r in reqs {
		wj.web_settle(ctx, r[0], wj.web_iter_result(ctx, wj.UNDEFINED, true))
		wj.JS_FreeValue(ctx, r[0])
		wj.JS_FreeValue(ctx, r[1])
	}
	delete(reqs)
	resolve_closed(ctx, s, false)
}

@(private = "file")
reqs_reject_all :: proc(ctx: ^wj.Context, s: ^Stream, e: wj.JSValue) {
	reqs := take_requests(s)
	for r in reqs {
		wj.web_settle(ctx, r[1], wj.JS_DupValue(ctx, e))
		wj.JS_FreeValue(ctx, r[0])
		wj.JS_FreeValue(ctx, r[1])
	}
	delete(reqs)
}

@(private = "file")
queue_drop :: proc(ctx: ^wj.Context, s: ^Stream) {
	for v in q_items(&s.queue) { wj.JS_FreeValue(ctx, v) }
	q_reset(&s.queue)
}

@(private = "file")
stream_error :: proc(ctx: ^wj.Context, s: ^Stream, e: wj.JSValue) {
	if s.state != .Readable { return }
	keep := stream_hold(ctx, s)
	defer wj.JS_FreeValue(ctx, keep)
	s.state = .Errored
	wj.JS_FreeValue(ctx, s.error)
	s.error = wj.JS_DupValue(ctx, e)
	queue_drop(ctx, s)
	reqs_reject_all(ctx, s, e)
	resolve_closed(ctx, s, true)
}

// takes `chunk`
@(private = "file")
stream_enqueue :: proc(ctx: ^wj.Context, s: ^Stream, chunk: wj.JSValue) {
	if s.state != .Readable || s.close_requested { wj.JS_FreeValue(ctx, chunk); return }
	keep := stream_hold(ctx, s)
	defer wj.JS_FreeValue(ctx, keep)
	if len(s.reqs) > 0 {
		r := s.reqs[0]
		ordered_remove(&s.reqs, 0)
		wj.web_settle(ctx, r[0], wj.web_iter_result(ctx, chunk, false))
		wj.JS_FreeValue(ctx, r[0])
		wj.JS_FreeValue(ctx, r[1])
	} else if !q_push(&s.queue, chunk) {
		wj.JS_FreeValue(ctx, chunk)
	}
	pull_if_needed(ctx, s)
}

@(private = "file")
stream_close :: proc(ctx: ^wj.Context, s: ^Stream) {
	if s.state != .Readable || s.close_requested { return }
	s.close_requested = true
	if q_empty(&s.queue) { finish_close(ctx, s) }
}

// -- a script's source: pull() and its promise --

@(private = "file")
on_pull_done :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_of(data[0])
	if s == nil { return wj.UNDEFINED }
	s.pulling = false
	if s.pull_again { s.pull_again = false; pull_if_needed(ctx, s) }
	return wj.UNDEFINED
}

@(private = "file")
on_source_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if s := stream_of(data[0]); s != nil { stream_error(ctx, s, wj.arg(argc, argv, 0)) }
	return wj.UNDEFINED
}

@(private = "file")
on_started :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_of(data[0])
	if s == nil { return wj.UNDEFINED }
	s.started = true
	pull_if_needed(ctx, s)
	return wj.UNDEFINED
}

// -- a browser body stream: one Stream_read at a time --

@(private = "file")
host_chunk :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_of(data)
	src: ^Host_Source
	if s != nil {
		if hs, ok := &s.source.(Host_Source); ok { src = hs }
	}
	if src != nil { src.reading = false }
	reject^ = false
	if state != 1 {
		// an abort gives the signal's reason, a network failure a TypeError
		e: wj.JSValue
		if src != nil && web_signal_aborted(src.signal) {
			e = web_signal_reason(ctx, src.signal)
		} else {
			t := wj.wj_host_promise_text(ctx, host)
			m := wj.to_cstring(ctx, t)
			e = wj.web_type_error(ctx, m != nil ? m : "network error")
			if m != nil { wj.free_cstring(ctx, m) }
			wj.JS_FreeValue(ctx, t)
		}
		if s != nil { stream_error(ctx, s, e) }
		wj.JS_FreeValue(ctx, e)
		return wj.UNDEFINED
	}
	if s == nil { if value != 0 { wj.wr_Object_release(u64(value)) }; return wj.UNDEFINED }
	if value == 0 {
		stream_close(ctx, s)
	} else {
		u8a := wj.wj_uint8array_from_host(ctx, u64(value))
		wj.wr_Object_release(u64(value))
		if wj.is_exception(u8a) {
			e := wj.JS_GetException(ctx)
			stream_error(ctx, s, e)
			wj.JS_FreeValue(ctx, e)
		} else {
			stream_enqueue(ctx, s, u8a)
		}
	}
	return wj.UNDEFINED
}

@(private = "file")
pull_if_needed :: proc(ctx: ^wj.Context, s: ^Stream) {
	if s.state != .Readable || s.close_requested { return }
	if len(s.reqs) == 0 && !(desired_size(s) > 0) { return }
	switch &src in s.source {
	case Js_Source:
		if !s.started || wj.is_undefined(src.pull) { return }
		if s.pulling { s.pull_again = true; return }
		s.pulling = true
		keep := stream_hold(ctx, s)
		r := wj.JS_Call(ctx, src.pull, src.source, 1, &src.controller)
		p := promise_of(ctx, r)
		then_drop(ctx, p, on_pull_done, on_source_error, keep)
		wj.JS_FreeValue(ctx, p)
		wj.JS_FreeValue(ctx, keep)
	case Host_Source:
		if src.reading || src.host == 0 { return }
		src.reading = true
		p := wj.wj_promise_from_host(ctx, wj.wr_Stream_read(src.host), wj.HOST_UNDEFINED, host_chunk, s.self)
		wj.JS_FreeValue(ctx, p)
	case Tee_Source:
		if src.tee != nil {
			keep := stream_hold(ctx, s)
			tee_pull(ctx, src.tee, s.self)
			wj.JS_FreeValue(ctx, keep)
		}
	}
}

// ---- tee ----

@(private = "file")
copy_chunk :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	p: [^]u8
	n: uint
	if wj.wj_is_buffer_source(v) && wj.wj_to_buffer_source(ctx, v, &p, &n, wj.BS_ALLOW_SHARED, "tee") {
		t := wj.wj_typed_array_type(v)
		if t == wj.TYPED_ARRAY_UINT8 || t < 0 {
			return wj.wj_is_array_buffer(v) ? wj.JS_NewArrayBufferCopy(ctx, p, n) : wj.JS_NewUint8ArrayCopy(ctx, p, n)
		}
	}
	// (another kind of view, or any other value: StructuredClone, as Streams says)
	if !wj.is_object(v) { return wj.JS_DupValue(ctx, v) }
	size: uint
	bytes := wj_clone_serialize(ctx, v, wj.UNDEFINED, &size)
	if bytes == nil {
		wj.drop_exception(ctx)
		return wj.JS_DupValue(ctx, v)
	}
	defer wj.libc_free(bytes)
	c := wj_clone_deserialize(ctx, bytes, size)
	if wj.is_exception(c) {
		wj.drop_exception(ctx)
		return wj.JS_DupValue(ctx, v)
	}
	return c
}

@(private = "file")
tee_of :: proc "contextless" (b: ^Stream) -> ^Tee_State {
	if b == nil { return nil }
	src, ok := b.source.(Tee_Source)
	return ok ? src.tee : nil
}

@(private = "file")
on_tee_chunk :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	t := tee_of(stream_of(data[0]))
	if t == nil { return wj.UNDEFINED }
	t.reading = false
	res := wj.arg(argc, argv, 0)
	done := wj.JS_GetPropertyStr(ctx, res, "done")
	is_done := wj.JS_ToBool(ctx, done) > 0
	wj.JS_FreeValue(ctx, done)
	if is_done {
		for i in 0 ..< 2 { if t.branch[i] != nil && !t.canceled[i] { stream_close(ctx, t.branch[i]) } }
		if !(t.canceled[0] && t.canceled[1]) { tee_settle_cancel(ctx, t, wj.UNDEFINED) }
		return wj.UNDEFINED
	}
	v := wj.JS_GetPropertyStr(ctx, res, "value")
	for i in 0 ..< 2 {
		if t.branch[i] == nil || t.canceled[i] { continue }
		stream_enqueue(ctx, t.branch[i], i == 1 && t.clone2 ? copy_chunk(ctx, v) : wj.JS_DupValue(ctx, v))
	}
	wj.JS_FreeValue(ctx, v)
	if t.read_again {
		t.read_again = false
		for i in 0 ..< 2 {
			if t.branch[i] == nil { continue }
			keep := stream_hold(ctx, t.branch[i])
			tee_pull(ctx, t, keep)
			wj.JS_FreeValue(ctx, keep)
			break
		}
	}
	return wj.UNDEFINED
}

@(private = "file")
on_tee_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	t := tee_of(stream_of(data[0]))
	if t == nil { return wj.UNDEFINED }
	t.reading = false
	for i in 0 ..< 2 { if t.branch[i] != nil { stream_error(ctx, t.branch[i], wj.arg(argc, argv, 0)) } }
	// (a branch's cancel() no longer waits for the other)
	if !(t.canceled[0] && t.canceled[1]) { tee_settle_cancel(ctx, t, wj.UNDEFINED) }
	return wj.UNDEFINED
}

@(private = "file")
tee_pull :: proc(ctx: ^wj.Context, t: ^Tee_State, branch_obj: wj.JSValue) {
	if t.reading { t.read_again = true; return }
	b := stream_of(branch_obj)
	if b == nil { return }
	src, _ := b.source.(Tee_Source)
	t.reading = true
	p := wjr_ReadableStreamDefaultReader_read(ctx, src.reader, 0, nil)
	if wj.is_exception(p) { t.reading = false; wj.wj_report_pending(ctx); return }
	then_drop(ctx, p, on_tee_chunk, on_tee_error, branch_obj)
	wj.JS_FreeValue(ctx, p)
}

// The teed stream closed: the branches do, whether they are reading or not.
@(private = "file")
on_tee_closed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	t := tee_of(stream_of(data[0]))
	if t == nil || t.reading { return wj.UNDEFINED }   // (a read under way says so itself, after its chunk)
	for i in 0 ..< 2 { if t.branch[i] != nil && !t.canceled[i] { stream_close(ctx, t.branch[i]) } }
	if !(t.canceled[0] && t.canceled[1]) { tee_settle_cancel(ctx, t, wj.UNDEFINED) }
	return wj.UNDEFINED
}

// Takes `v`.
@(private = "file")
tee_settle_cancel :: proc(ctx: ^wj.Context, t: ^Tee_State, v: wj.JSValue) {
	if wj.is_undefined(t.cancel_funcs[0]) {
		wj.JS_FreeValue(ctx, v)
		return
	}
	wj.web_settle(ctx, t.cancel_funcs[0], v)
	wj.JS_FreeValue(ctx, t.cancel_funcs[0])
	wj.JS_FreeValue(ctx, t.cancel_funcs[1])
	t.cancel_funcs = {wj.UNDEFINED, wj.UNDEFINED}
}

// stream.tee(): two streams (an array), chunks copied for the second (Response.clone)
@(export, link_name = "web_stream_tee")
web_stream_tee :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue, clone_second: bool) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_of(stream)
	if s == nil { return wj.wj_throw_type(ctx, "not a ReadableStream") }
	if !wj.is_undefined(s.reader) { return wj.wj_throw_type(ctx, "Failed to execute 'tee' on 'ReadableStream': the stream is locked") }
	reader := get_reader(ctx, stream)
	if wj.is_exception(reader) { return reader }
	defer wj.JS_FreeValue(ctx, reader)
	t := new(Tee_State)
	if t == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	t.reasons = {wj.UNDEFINED, wj.UNDEFINED}
	t.cancel_promise = wj.UNDEFINED
	t.cancel_funcs = {wj.UNDEFINED, wj.UNDEFINED}
	t.clone2 = clone_second
	arr := wj.JS_NewArray(ctx)
	for i in 0 ..< 2 {
		b := stream_new(ctx, wj.UNDEFINED, Tee_Source{tee = t, branch = i, reader = wj.JS_DupValue(ctx, reader)})
		if wj.is_exception(b) {
			wj.JS_FreeValue(ctx, reader)   // the reference the failed branch did not take
			// a branch made first holds a reference and frees the state with it (when arr goes); else it is ours
			orphan := t.refs == 0
			wj.JS_FreeValue(ctx, arr)
			if orphan { free(t) }
			return b
		}
		bs := stream_of(b)
		bs.started = true
		t.branch[i] = bs
		t.refs += 1
		wj.array_set(ctx, arr, u32(i), b)
	}
	// the teed stream erroring reaches the branches whether they are reading or not
	if r := reader_of(reader); r != nil {
		first := wj.JS_GetPropertyUint32(ctx, arr, 0)
		watch := wj.web_then(ctx, r.closed, rawptr(on_tee_closed), rawptr(on_tee_error), 1, &first)
		wj.free_values(ctx, watch, first)
	}
	return arr
}

// ---- cancel ----

@(private = "file")
stream_cancel :: proc(ctx: ^wj.Context, s: ^Stream, reason: wj.JSValue) -> wj.JSValue {
	keep := stream_hold(ctx, s)
	defer wj.JS_FreeValue(ctx, keep)
	s.disturbed = true
	switch s.state {
	case .Closed:   return wj.web_promise_resolved(ctx, wj.UNDEFINED)
	case .Errored:  return wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, s.error))
	case .Readable:
	}
	queue_drop(ctx, s)
	finish_close(ctx, s)
	switch &src in s.source {
	case Js_Source:
		if wj.JS_IsFunction(ctx, src.cancel_fn) {
			reason_v := reason
			r := wj.JS_Call(ctx, src.cancel_fn, src.source, 1, &reason_v)
			p := promise_of(ctx, r)
			d := then_with(ctx, p, noop_reaction, nil)
			wj.JS_FreeValue(ctx, p)
			return d
		}
	case Host_Source:
		if src.host != 0 { wj.wr_Stream_cancel(src.host); wj.wr_Object_release(src.host); src.host = 0 }
	case Tee_Source:
		t := src.tee
		if t == nil { break }
		t.canceled[src.branch] = true
		wj.JS_FreeValue(ctx, t.reasons[src.branch])
		t.reasons[src.branch] = wj.JS_DupValue(ctx, reason)
		if wj.is_undefined(t.cancel_promise) { t.cancel_promise = wj.web_promise_new(ctx, &t.cancel_funcs[0]) }
		answer := wj.JS_DupValue(ctx, t.cancel_promise)
		if t.canceled[0] && t.canceled[1] {
			// both branches cancelled: the teed stream is, with both reasons
			reasons := wj.JS_NewArray(ctx)
			wj.array_set(ctx, reasons, 0, wj.JS_DupValue(ctx, t.reasons[0]))
			wj.array_set(ctx, reasons, 1, wj.JS_DupValue(ctx, t.reasons[1]))
			if r := reader_of(src.reader); r != nil {
				if teed := stream_of(r.stream); teed != nil { tee_settle_cancel(ctx, t, stream_cancel(ctx, teed, reasons)) }
			}
			wj.JS_FreeValue(ctx, reasons)
		}
		return answer
	}
	return wj.web_promise_resolved(ctx, wj.UNDEFINED)
}

// cancel(reason) (promise)
@(export, link_name = "web_stream_cancel")
web_stream_cancel :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue, reason: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_of(stream)
	if s == nil { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "not a ReadableStream")) }
	return stream_cancel(ctx, s, reason)
}

// ---- ReadableStream ----

@(export, link_name = "wjr_ReadableStream_constructor")
wjr_ReadableStream_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor ReadableStream requires 'new'") }
	source, strategy := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)
	if !wj.is_nullish(source) && !wj.is_object(source) { return wj.wj_throw_type(ctx, "Failed to construct 'ReadableStream': the underlying source is not an object") }
	if !wj.web_dict_check(ctx, strategy, "ReadableStream") { return wj.EXCEPTION }
	start, pull, cancel, hwm := wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
	if !wj.web_dict_get(ctx, source, "start", &start) || !wj.web_dict_get(ctx, source, "pull", &pull) ||
	   !wj.web_dict_get(ctx, source, "cancel", &cancel) || !wj.web_dict_get(ctx, strategy, "highWaterMark", &hwm) {
		wj.free_values(ctx, start, pull, cancel)
		return wj.EXCEPTION
	}
	not_fn :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> bool { return !wj.is_undefined(v) && !wj.JS_IsFunction(ctx, v) }
	if not_fn(ctx, start) || not_fn(ctx, pull) || not_fn(ctx, cancel) {
		wj.free_values(ctx, start, pull, cancel, hwm)
		return wj.wj_throw_type(ctx, "Failed to construct 'ReadableStream': start, pull and cancel must be functions")
	}
	h := 1.0
	if !wj.is_undefined(hwm) {
		if !wj.wj_to_double(ctx, hwm, &h, false) || wj.is_nan(h) || h < 0 {
			wj.free_values(ctx, start, pull, cancel, hwm)
			if !wj.JS_HasException(ctx) { wj.JS_ThrowRangeError(ctx, "Failed to construct 'ReadableStream': invalid highWaterMark") }
			return wj.EXCEPTION
		}
	}
	wj.JS_FreeValue(ctx, hwm)
	src := Js_Source{
		source = wj.is_object(source) ? wj.JS_DupValue(ctx, source) : wj.UNDEFINED,
		pull = pull, cancel_fn = cancel, controller = wj.UNDEFINED,
	}
	obj := stream_new(ctx, new_target, src)
	if wj.is_exception(obj) { wj.free_values(ctx, start, src.source, pull, cancel); return obj }
	s := stream_of(obj)
	s.hwm = h
	js := &s.source.(Js_Source)
	c := new(Stream_Controller)
	ctrl := c != nil ? wj.wj_new_object(ctx, net_iface(.ReadableStreamDefaultController), nil, nil) : wj.JS_ThrowOutOfMemory(ctx)
	if wj.is_exception(ctrl) { free(c); wj.JS_FreeValue(ctx, start); wj.JS_FreeValue(ctx, obj); return ctrl }
	c.stream = wj.JS_DupValue(ctx, obj)
	wj.web_set_impl(ctrl, c, stream_controller_free, stream_controller_mark)
	js.controller = ctrl
	r := wj.JS_IsFunction(ctx, start) ? wj.JS_Call(ctx, start, js.source, 1, &js.controller) : wj.UNDEFINED
	wj.JS_FreeValue(ctx, start)
	if wj.is_exception(r) { wj.JS_FreeValue(ctx, obj); return r }
	p := promise_of(ctx, r)
	then_drop(ctx, p, on_started, on_source_error, obj)
	wj.JS_FreeValue(ctx, p)
	return obj
}

// A stream of the chunks of a browser body stream (module fetch: ReadableStream handle, owned). `signal`, when an
// AbortSignal, gives the error once it aborts; `keep` (the Response) lives as long as the stream.
@(export, link_name = "web_stream_from_host")
web_stream_from_host :: proc "c" (ctx: ^wj.Context, host_stream: u64, signal: wj.JSValue, keep: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	obj := stream_new(ctx, wj.UNDEFINED, Host_Source{host = host_stream, signal = wj.JS_DupValue(ctx, signal), keep = wj.JS_DupValue(ctx, keep)})
	if wj.is_exception(obj) {
		wj.JS_FreeValue(ctx, signal)
		wj.JS_FreeValue(ctx, keep)
		wj.wr_Object_release(host_stream)
		return obj
	}
	s := stream_of(obj)
	s.started = true
	s.hwm = 0   // read on demand
	return obj
}

// A stream the engine fills: started, no source.
@(private = "file")
engine_stream :: proc(ctx: ^wj.Context) -> (wj.JSValue, ^Stream) {
	obj := stream_new(ctx, wj.UNDEFINED, nil)
	if wj.is_exception(obj) { return obj, nil }
	s := stream_of(obj)
	s.started = true
	return obj, s
}

// A stream of one Uint8Array chunk (a copy of the bytes), then closed.
@(export, link_name = "web_stream_from_bytes")
web_stream_from_bytes :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint) -> wj.JSValue {
	context = wj.heap_context()
	obj, s := engine_stream(ctx)
	if s == nil { return obj }
	if n > 0 {
		u8a := wj.JS_NewUint8ArrayCopy(ctx, p, n)
		if wj.is_exception(u8a) { wj.JS_FreeValue(ctx, obj); return u8a }
		if !q_push(&s.queue, u8a) { wj.JS_FreeValue(ctx, u8a) }
	}
	stream_close(ctx, s)
	return obj
}

// A stream the engine feeds: chunks pushed, then ended or failed.
@(export, link_name = "web_stream_pending")
web_stream_pending :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	context = wj.heap_context()
	obj, _ := engine_stream(ctx)
	return obj
}

@(export, link_name = "web_stream_push")
web_stream_push :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue, chunk: wj.JSValue) {
	context = wj.heap_context()
	if s := stream_of(stream); s != nil { stream_enqueue(ctx, s, wj.JS_DupValue(ctx, chunk)) }
}

@(export, link_name = "web_stream_end")
web_stream_end :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue) {
	context = wj.heap_context()
	if s := stream_of(stream); s != nil { stream_close(ctx, s) }
}

@(export, link_name = "web_stream_fail")
web_stream_fail :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue, e: wj.JSValue) {
	context = wj.heap_context()
	if s := stream_of(stream); s != nil { stream_error(ctx, s, e) }
}

// A stream of one chunk (any value), then closed.
@(export, link_name = "web_stream_of")
web_stream_of :: proc "c" (ctx: ^wj.Context, chunk: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	obj, s := engine_stream(ctx)
	if s == nil { return obj }
	c := wj.JS_DupValue(ctx, chunk)
	if !q_push(&s.queue, c) { wj.JS_FreeValue(ctx, c) }
	stream_close(ctx, s)
	return obj
}

@(private = "file")
stream_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Stream {
	return (^Stream)(wj.this_impl(ctx, this_val, net_iface(.ReadableStream)))
}

@(export, link_name = "wjr_ReadableStream_get_locked")
wjr_ReadableStream_get_locked :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	s := stream_this(ctx, this_val)
	return s != nil ? wj.new_bool(!wj.is_undefined(s.reader)) : wj.EXCEPTION
}

@(export, link_name = "wjr_ReadableStream_cancel")
wjr_ReadableStream_cancel :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_this(ctx, this_val)
	if s == nil { return wj.web_promise_reject_pending(ctx) }
	if !wj.is_undefined(s.reader) { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "Failed to execute 'cancel' on 'ReadableStream': Cannot cancel a locked stream")) }
	return stream_cancel(ctx, s, wj.arg(argc, argv, 0))
}

@(private = "file")
get_reader :: proc(ctx: ^wj.Context, stream: wj.JSValue) -> wj.JSValue {
	s := stream_of(stream)
	if !wj.is_undefined(s.reader) { return wj.wj_throw_type(ctx, "ReadableStreamDefaultReader constructor can only accept readable streams that are not yet locked to a reader") }
	r := new(Reader)
	if r == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	r.stream = wj.JS_DupValue(ctx, stream)
	r.closed = wj.web_promise_new(ctx, &r.closed_funcs[0])
	obj := wj.wj_new_object(ctx, net_iface(.ReadableStreamDefaultReader), nil, nil)
	if wj.is_exception(obj) { reader_free(r); return obj }
	wj.web_set_impl(obj, r, reader_free, reader_mark)
	s.reader = wj.JS_DupValue(ctx, obj)
	#partial switch s.state {
	case .Closed:  resolve_closed(ctx, s, false)
	case .Errored: resolve_closed(ctx, s, true)
	}
	return obj
}

@(export, link_name = "wjr_ReadableStream_getReader")
wjr_ReadableStream_getReader :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if stream_this(ctx, this_val) == nil { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "getReader") { return wj.EXCEPTION }
	mode: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "mode", &mode) { return wj.EXCEPTION }
	if !wj.is_undefined(mode) {
		m, mc, ok := wj.to_string_view(ctx, mode)
		wj.JS_FreeValue(ctx, mode)
		if !ok { return wj.EXCEPTION }
		byob := m == "byob"
		wj.free_cstring(ctx, mc)
		if byob { return wj.wj_throw_dom(ctx, "NotSupportedError", "BYOB readers are not supported by this browser") }
		return wj.wj_throw_type(ctx, "Failed to execute 'getReader' on 'ReadableStream': invalid mode")
	}
	return get_reader(ctx, this_val)
}

@(export, link_name = "wjr_ReadableStream_tee")
wjr_ReadableStream_tee :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if stream_this(ctx, this_val) == nil { return wj.EXCEPTION }
	return web_stream_tee(ctx, this_val, false)
}

// -- async iteration: for await (const chunk of stream) --

@(private = "file")
release_quietly :: proc "contextless" (ctx: ^wj.Context, reader: wj.JSValue) {
	wj.discard(ctx, wjr_ReadableStreamDefaultReader_releaseLock(ctx, reader, 0, nil))
}

// Web IDL's asynchronous iterator: one call at a time (each waits for the one before: "_ongoing"), and once finished it says
// so ("_finished"). Its methods are on a prototype of its own, over %AsyncIteratorPrototype%; the state is hidden on the object.
@(private = "file")
iter_state :: proc "contextless" (ctx: ^wj.Context, it: wj.JSValue) -> (reader: wj.JSValue, ok: bool) {
	reader = wj.web_extra_get(ctx, it, "_reader")
	if wj.is_undefined(reader) { return reader, false }
	return reader, true
}

@(private = "file")
iter_finished :: proc "contextless" (ctx: ^wj.Context, it: wj.JSValue) -> bool {
	v := wj.web_extra_get(ctx, it, "_finished")
	defer wj.JS_FreeValue(ctx, v)
	return !wj.is_undefined(v)
}

@(private = "file")
iter_finish :: proc "contextless" (ctx: ^wj.Context, it: wj.JSValue) {
	wj.web_extra_set(ctx, it, "_finished", wj.new_bool(true))
}

// (data[0]: the iterator) the end of the iteration releases the reader
@(private = "file")
iter_step :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	res := wj.arg(argc, argv, 0)
	done := wj.JS_GetPropertyStr(ctx, res, "done")
	if wj.JS_ToBool(ctx, done) > 0 {
		iter_finish(ctx, data[0])
		if reader, ok := iter_state(ctx, data[0]); ok {
			release_quietly(ctx, reader)
			wj.JS_FreeValue(ctx, reader)
		}
	}
	wj.JS_FreeValue(ctx, done)
	return wj.JS_DupValue(ctx, res)
}

@(private = "file")
iter_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	iter_finish(ctx, data[0])
	if reader, ok := iter_state(ctx, data[0]); ok {
		release_quietly(ctx, reader)
		wj.JS_FreeValue(ctx, reader)
	}
	return wj.JS_Throw(ctx, wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)))
}

// (magic 1: return, with data[1] the value it was given; both ways once the call before it has settled)
@(private = "file")
iter_steps :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	it := data[0]
	if magic == 1 {
		value := data[1]
		if iter_finished(ctx, it) { return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.JS_DupValue(ctx, value), true)) }
		iter_finish(ctx, it)
		reader, ok := iter_state(ctx, it)
		if !ok { return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.JS_DupValue(ctx, value), true)) }
		defer wj.JS_FreeValue(ctx, reader)
		prevent := wj.web_extra_get(ctx, it, "_prevent")
		keep_open := wj.JS_ToBool(ctx, prevent) > 0
		wj.JS_FreeValue(ctx, prevent)
		cancelled := wj.UNDEFINED
		if r := reader_of(reader); r != nil && !keep_open {
			if s := stream_of(r.stream); s != nil { cancelled = stream_cancel(ctx, s, value) }
		}
		release_quietly(ctx, reader)
		if wj.is_undefined(cancelled) { return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.JS_DupValue(ctx, value), true)) }
		defer wj.JS_FreeValue(ctx, cancelled)
		d := [1]wj.JSValue{value}
		return wj.web_then(ctx, cancelled, rawptr(iter_returned), nil, 1, &d[0])
	}
	if iter_finished(ctx, it) { return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.UNDEFINED, true)) }
	reader, ok := iter_state(ctx, it)
	if !ok { return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.UNDEFINED, true)) }
	defer wj.JS_FreeValue(ctx, reader)
	p := wjr_ReadableStreamDefaultReader_read(ctx, reader, 0, nil)
	if wj.is_exception(p) { return p }
	defer wj.JS_FreeValue(ctx, p)
	d := [1]wj.JSValue{it}
	return wj.web_then(ctx, p, rawptr(iter_step), rawptr(iter_error), 1, &d[0])
}

@(private = "file")
iter_returned :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return wj.web_iter_result(ctx, wj.JS_DupValue(ctx, data[0]), true)
}

// next() (magic 0), return(value) (magic 1): after the call before it, whichever way that went.
@(private = "file")
iter_call :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32) -> wj.JSValue {
	context = wj.heap_context()
	reader, ok := iter_state(ctx, this_val)
	if !ok && !iter_finished(ctx, this_val) { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "not a ReadableStream async iterator")) }
	wj.JS_FreeValue(ctx, reader)
	d := [2]wj.JSValue{this_val, wj.arg(argc, argv, 0)}
	steps := wj.JS_NewCFunctionData(ctx, iter_steps, 0, magic, 2, &d[0])
	defer wj.JS_FreeValue(ctx, steps)
	ongoing := wj.web_extra_get(ctx, this_val, "_ongoing")
	defer wj.JS_FreeValue(ctx, ongoing)
	r: wj.JSValue
	if wj.is_undefined(ongoing) {
		r = wj.JS_Call(ctx, steps, wj.UNDEFINED, 0, nil)
	} else {
		r = wj.JS_PromiseThen(ctx, ongoing, steps, steps)
	}
	if wj.is_exception(r) { return wj.web_promise_reject_pending(ctx) }
	wj.web_extra_set(ctx, this_val, "_ongoing", wj.JS_DupValue(ctx, r))
	return r
}

@(export, link_name = "wjr_ReadableStream_values")
wjr_ReadableStream_values :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if stream_this(ctx, this_val) == nil { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "values") { return wj.EXCEPTION }
	pc: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "preventCancel", &pc) { return wj.EXCEPTION }
	prevent := wj.new_bool(wj.JS_ToBool(ctx, pc) > 0)
	wj.JS_FreeValue(ctx, pc)
	reader := get_reader(ctx, this_val)
	if wj.is_exception(reader) { return reader }
	if wj.is_undefined(iter_proto) {
		iter_proto = wj.JS_NewObjectProto(ctx, async_iter_proto)
		wj.JS_DefinePropertyValueStr(ctx, iter_proto, "next", wj.new_cfunction_magic(ctx, iter_call, "next", 0, wj.CFUNC_generic_magic, 0), wj.PROP_C_W_E)
		wj.JS_DefinePropertyValueStr(ctx, iter_proto, "return", wj.new_cfunction_magic(ctx, iter_call, "return", 1, wj.CFUNC_generic_magic, 1), wj.PROP_C_W_E)
	}
	it := wj.JS_NewObjectProto(ctx, iter_proto)
	wj.web_extra_set(ctx, it, "_reader", reader)   // (takes it)
	wj.web_extra_set(ctx, it, "_prevent", prevent)
	return it
}

// ---- ReadableStreamDefaultReader ----

@(export, link_name = "wjr_ReadableStreamDefaultReader_constructor")
wjr_ReadableStreamDefaultReader_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor ReadableStreamDefaultReader requires 'new'") }
	st := wj.arg(argc, argv, 0)
	if stream_of(st) == nil { return wj.wj_throw_type(ctx, "Failed to construct 'ReadableStreamDefaultReader': parameter 1 is not of type 'ReadableStream'.") }
	return get_reader(ctx, st)
}

@(private = "file")
reader_this :: #force_inline proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Reader {
	return (^Reader)(wj.this_impl(ctx, this_val, net_iface(.ReadableStreamDefaultReader)))
}

@(export, link_name = "wjr_ReadableStreamDefaultReader_read")
wjr_ReadableStreamDefaultReader_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reader_this(ctx, this_val)
	if r == nil { return wj.web_promise_reject_pending(ctx) }
	s := stream_of(r.stream)
	if s == nil { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "This readable stream reader has been released and cannot be used to read from its previous owner stream")) }
	s.disturbed = true
	switch s.state {
	case .Closed:   return wj.web_promise_take(ctx, wj.web_iter_result(ctx, wj.UNDEFINED, true))
	case .Errored:  return wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, s.error))
	case .Readable:
	}
	if !q_empty(&s.queue) {
		keep := stream_hold(ctx, s)
		defer wj.JS_FreeValue(ctx, keep)
		p := wj.web_promise_take(ctx, wj.web_iter_result(ctx, q_pop(&s.queue), false))
		if q_empty(&s.queue) && s.close_requested { finish_close(ctx, s) } else { pull_if_needed(ctx, s) }
		return p
	}
	req: Read_Request
	p := wj.web_promise_new(ctx, &req[0])
	if wj.is_exception(p) { return p }
	if _, err := append(&s.reqs, req); err != nil {
		wj.free_values(ctx, req[0], req[1], p)
		return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "out of memory"))
	}
	pull_if_needed(ctx, s)
	return p
}

@(export, link_name = "wjr_ReadableStreamDefaultReader_releaseLock")
wjr_ReadableStreamDefaultReader_releaseLock :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reader_this(ctx, this_val)
	if r == nil { return wj.EXCEPTION }
	s := stream_of(r.stream)
	if s == nil { return wj.UNDEFINED }
	e := wj.web_type_error(ctx, "Releasing Default reader")
	reqs_reject_all(ctx, s, e)
	// closed is rejected (a new rejected promise once settled)
	if !wj.is_undefined(r.closed_funcs[1]) {
		wj.web_settle(ctx, r.closed_funcs[1], wj.JS_DupValue(ctx, e))
		wj.JS_FreeValue(ctx, r.closed_funcs[0])
		wj.JS_FreeValue(ctx, r.closed_funcs[1])
		r.closed_funcs = {wj.UNDEFINED, wj.UNDEFINED}
	} else {
		wj.JS_FreeValue(ctx, r.closed)
		r.closed = wj.web_promise_rejected(ctx, wj.JS_DupValue(ctx, e))
	}
	wj.JS_PromiseMarkAsHandled(ctx, r.closed)
	wj.JS_FreeValue(ctx, e)
	wj.JS_FreeValue(ctx, s.reader)
	s.reader = wj.UNDEFINED
	wj.JS_FreeValue(ctx, r.stream)
	r.stream = wj.UNDEFINED
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ReadableStreamDefaultReader_get_closed")
wjr_ReadableStreamDefaultReader_get_closed :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	r := reader_this(ctx, this_val)
	return r != nil ? wj.JS_DupValue(ctx, r.closed) : wj.EXCEPTION
}

@(export, link_name = "wjr_ReadableStreamDefaultReader_cancel")
wjr_ReadableStreamDefaultReader_cancel :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	r := reader_this(ctx, this_val)
	if r == nil { return wj.web_promise_reject_pending(ctx) }
	s := stream_of(r.stream)
	if s == nil { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "This readable stream reader has been released")) }
	return stream_cancel(ctx, s, wj.arg(argc, argv, 0))
}

// ---- ReadableStreamDefaultController ----

@(private = "file")
controller_stream :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Stream {
	c := (^Stream_Controller)(wj.this_impl(ctx, this_val, net_iface(.ReadableStreamDefaultController)))
	if c == nil { return nil }
	s := stream_of(c.stream)
	if s == nil { wj.wj_throw_type(ctx, "Illegal invocation") }
	return s
}

@(export, link_name = "wjr_ReadableStreamDefaultController_get_desiredSize")
wjr_ReadableStreamDefaultController_get_desiredSize :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	s := controller_stream(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if s.state == .Errored { return wj.NULL }
	return wj.new_float64(ctx, desired_size(s))
}

@(export, link_name = "wjr_ReadableStreamDefaultController_enqueue")
wjr_ReadableStreamDefaultController_enqueue :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := controller_stream(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if s.close_requested || s.state != .Readable { return wj.wj_throw_type(ctx, "Failed to execute 'enqueue' on 'ReadableStreamDefaultController': Cannot enqueue a chunk into a closed readable stream") }
	stream_enqueue(ctx, s, wj.JS_DupValue(ctx, wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ReadableStreamDefaultController_close")
wjr_ReadableStreamDefaultController_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := controller_stream(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	if s.close_requested || s.state != .Readable { return wj.wj_throw_type(ctx, "Failed to execute 'close' on 'ReadableStreamDefaultController': Cannot close a readable stream that has already been requested to be closed") }
	stream_close(ctx, s)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_ReadableStreamDefaultController_error")
wjr_ReadableStreamDefaultController_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := controller_stream(ctx, this_val)
	if s == nil { return wj.EXCEPTION }
	stream_error(ctx, s, wj.arg(argc, argv, 0))
	return wj.UNDEFINED
}

// ---- read all (fetch bodies) ----

// data: [reader, resolve, reject, chunks (an array)]
@(private = "file")
read_all_next :: proc "contextless" (ctx: ^wj.Context, data: [^]wj.JSValue) {
	p := wjr_ReadableStreamDefaultReader_read(ctx, data[0], 0, nil)
	if wj.is_exception(p) { wj.web_settle(ctx, data[2], wj.JS_GetException(ctx)); return }
	d := wj.web_then(ctx, p, rawptr(read_all_step), nil, 4, data)
	wj.JS_FreeValue(ctx, wj.JS_PromiseThen(ctx, d, wj.UNDEFINED, data[2]))
	wj.JS_FreeValue(ctx, d)
	wj.JS_FreeValue(ctx, p)
}

@(private = "file")
read_all_step :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	res := wj.arg(argc, argv, 0)
	done := wj.JS_GetPropertyStr(ctx, res, "done")
	is_done := wj.JS_ToBool(ctx, done) > 0
	wj.JS_FreeValue(ctx, done)
	chunks := data[3]
	n: i64
	wj.JS_GetLength(ctx, chunks, &n)
	if is_done {
		// one ArrayBuffer of every chunk
		total: uint
		for i in 0 ..< n {
			c := wj.JS_GetPropertyUint32(ctx, chunks, u32(i))
			p: [^]u8
			length: uint
			wj.wj_to_buffer_source(ctx, c, &p, &length, wj.BS_ALLOW_SHARED, "read")
			total += length
			wj.JS_FreeValue(ctx, c)
		}
		all := ([^]u8)(wj.js_malloc(ctx, max(total, 1)))   // (an ArrayBuffer takes memory of the engine's allocator)
		if all == nil { wj.web_settle(ctx, data[2], wj.JS_GetException(ctx)); return wj.UNDEFINED }
		w: uint
		for i in 0 ..< n {
			c := wj.JS_GetPropertyUint32(ctx, chunks, u32(i))
			p: [^]u8
			length: uint
			wj.wj_to_buffer_source(ctx, c, &p, &length, wj.BS_ALLOW_SHARED, "read")
			if length > 0 { wj.memcpy(all[w:], p, length) }
			w += length
			wj.JS_FreeValue(ctx, c)
		}
		wj.web_settle(ctx, data[1], wj.wj_arraybuffer_take(ctx, all, w))
		return wj.UNDEFINED
	}
	v := wj.JS_GetPropertyStr(ctx, res, "value")
	if wj.wj_typed_array_type(v) != wj.TYPED_ARRAY_UINT8 {
		wj.JS_FreeValue(ctx, v)
		e := wj.web_type_error(ctx, "a chunk of the body is not a Uint8Array")
		if r := reader_of(data[0]); r != nil {
			if s := stream_of(r.stream); s != nil { wj.JS_FreeValue(ctx, stream_cancel(ctx, s, e)) }
		}
		wj.web_settle(ctx, data[2], e)
		return wj.UNDEFINED
	}
	wj.array_set(ctx, chunks, u32(n), v)
	read_all_next(ctx, data)
	return wj.UNDEFINED
}

// Reads every chunk (Uint8Array, or any BufferSource) of an unlocked stream: a promise of an ArrayBuffer of all the
// bytes. TypeError (rejection) for a locked or disturbed stream, or a chunk that is not bytes.
@(export, link_name = "web_stream_read_all")
web_stream_read_all :: proc "c" (ctx: ^wj.Context, stream: wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	s := stream_of(stream)
	if s == nil { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "not a ReadableStream")) }
	if !wj.is_undefined(s.reader) || s.disturbed { return wj.web_promise_rejected(ctx, wj.web_type_error(ctx, "body stream already read")) }
	reader := get_reader(ctx, stream)
	if wj.is_exception(reader) { return wj.web_promise_reject_pending(ctx) }
	funcs: [2]wj.JSValue
	p := wj.web_promise_new(ctx, &funcs[0])
	data := [4]wj.JSValue{reader, funcs[0], funcs[1], wj.JS_NewArray(ctx)}
	read_all_next(ctx, &data[0])
	for v in data { wj.JS_FreeValue(ctx, v) }
	return p
}

@(export, link_name = "web_stream_preinit")
web_stream_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	src: cstring = "Object.getPrototypeOf(Object.getPrototypeOf(async function*(){}).prototype)"   // (NUL-terminated: JS_Eval wants it)
	async_iter_proto = wj.JS_Eval(ctx, ([^]u8)(rawptr(src)), wj.strlen(src), "<web>", wj.EVAL_TYPE_GLOBAL)
	if wj.is_exception(async_iter_proto) { return -1 }
	// ReadableStream.prototype[@@asyncIterator] is values()
	proto := wj.realm_proto(net_iface(.ReadableStream))
	if wj.is_object(proto) {
		values := wj.JS_GetPropertyStr(ctx, proto, "values")
		sym := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "Symbol")
		ai := wj.JS_GetPropertyStr(ctx, sym, "asyncIterator")
		a := wj.JS_ValueToAtom(ctx, ai)
		if wj.JS_IsFunction(ctx, values) {
			wj.JS_DefinePropertyValue(ctx, proto, a, values, wj.PROP_WRITABLE | wj.PROP_CONFIGURABLE)
		} else {
			wj.JS_FreeValue(ctx, values)
		}
		wj.JS_FreeAtom(ctx, a)
		wj.JS_FreeValue(ctx, ai)
		wj.JS_FreeValue(ctx, sym)
	}
	return 0
}
