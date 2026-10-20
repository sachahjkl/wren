package page

// The promise side of the Fetch API (import module "fetch"), on the same fetch records as the callback API of module
// "net" (a response handle is a fetch handle: Fetch_status, Fetch_headers, Fetch_release... apply to it):
//   * Fetch_promise: a promise fulfilled with the response handle when the headers arrive, rejected on a network error
//     (TypeError) or an abort (the signal's reason);
//   * Response_text / Response_arrayBuffer: promises fulfilled when the whole body is there (text in the promise's
//     text, length in its value; or a buffer handle). A body is consumed once (bodyUsed);
//   * Response_body: a minimal ReadableStream. Stream_read gives a promise fulfilled with a buffer of what arrived since
//     the last read, or 0 at the end; Stream_cancel stops the download;
//   * abort signals for both APIs (Fetch_startWithSignal is the callback API with a signal and a buffer body): aborting
//     cancels the request (fetch.cancel) and fails it with error kind Aborted.
// Request bodies may come from guest memory or from a buffer handle.

import "core:strings"
import "wb:base"
import "wb:url"

Body_Kind :: enum u8 { None, Text, Buffer }

Fetch_Ext :: struct {
	promise_mode: bool,
	response:     u64,          // promise for the response (promise mode)
	signal:       u64,
	algo:         int,          // our abort algorithm on `signal`
	body_used:    bool,
	body_kind:    Body_Kind,
	body_promise: u64,          // Response_text / Response_arrayBuffer waiting for the end of the body
	body_owner:   u32,
	stream:       u64,          // Response_body
	received:     bool,         // Data events came (Done then carries no body)
}

Body_Stream :: struct {
	page:    ^Page,
	fetch:   base.Handle,
	pending: [dynamic]byte,     // counted in p.held
	reads:   [dynamic]u64,      // promises waiting for data
	ended:   bool,
	failed:  bool,
	code:    i64,
	error:   string,            // owned
	owner:   u32,
}

body_stream_vt := Object_VTable{
	name = "ReadableStream",
	destroy = proc(p: ^Page, data: rawptr) {
		s := (^Body_Stream)(data)
		if !p.closed {
			p.held -= len(s.pending)
			// a released stream is a cancelled one: nobody will read the rest
			if f := base.pool_get(&p.fetches, s.fetch); f != nil {
				if f.ext != nil { f.ext.stream = 0 }
				if f.state < 2 {
					fetch_abort(p, f)   // in a worker the request is the page's: a message cancels it
					f.state = 2
					if f.ext != nil { fetch_ext_finished(p, f) }
				}
			}
		}
		delete(s.pending)
		delete(s.reads)
		delete(s.error)
		free(s)
	},
}

@(private)
stream_get :: proc(p: ^Page, h: u64) -> ^Body_Stream { return (^Body_Stream)(object_data(p, h, &body_stream_vt)) }

// A buffer object taking ownership of bytes already counted in p.held.
@(private)
buffer_adopt_counted :: proc(p: ^Page, bytes: [dynamic]byte, owner: u32) -> u64 {
	b := new(Buffer)
	b.bytes = bytes
	return object_create(p, &buffer_vt, b, owner)
}

// Called from fetch_begin: wires the abort signal. False when the signal is already aborted (the failure is queued).
@(private)
fetch_ext_attach :: proc(p: ^Page, f: ^Fetch) -> bool {
	e := f.ext
	if e.signal == 0 { return true }
	if aborted, code, reason := signal_aborted(p, e.signal); aborted {
		f.state, f.error_kind, f.error = 3, .Aborted, strings.clone(reason)
		queue_fetch_failure(p, f, code)
		return false
	}
	e.algo = signal_add_algorithm(p, e.signal, fetch_abort_algorithm, u64(f.self))
	return true
}

@(private)
fetch_abort_algorithm :: proc(p: ^Page, data: u64, signal: u64) {
	f := base.pool_get(&p.fetches, base.Handle(data))
	if f == nil || f.state >= 2 { return }
	if f.ext != nil { f.ext.algo = 0 }
	fetch_abort(p, f)   // in a worker the request is the page's: a message cancels it
	_, code, reason := signal_aborted(p, signal)
	delete(f.error)
	f.state, f.error_kind, f.error = 3, .Aborted, strings.clone(reason)
	queue_fetch_failure(p, f, code)
}

@(private)
Fetch_Fail_Task :: struct { fetch: base.Handle, code: i64 }

// Delivers a failure that happened inside a guest call (abort) from a task of its own: callbacks never reenter the
// guest that called abort(); promise rejections are microtasks anyway, but stay in the same order as the callback API.
@(private)
queue_fetch_failure :: proc(p: ^Page, f: ^Fetch, code: i64) {
	t := new(Fetch_Fail_Task)
	t^ = {f.self, code}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Fetch_Fail_Task)(data)
		defer free(t)
		if pg == nil { return }
		f := base.pool_get(&pg.fetches, t.fetch)
		if f == nil { return }
		fetch_settle_failure(pg, f, t.code)
	}, t)
}

// Every consumer of a failed fetch learns it: the callback, the response promise, the body promise, the stream.
@(private)
fetch_settle_failure :: proc(p: ^Page, fp: ^Fetch, code: i64) {
	f := fp
	e := f.ext
	msg := strings.clone(f.error, context.temp_allocator)
	if e == nil || !e.promise_mode {
		fetch_call_guest(p, f)
		return
	}
	self := f.self
	if e.response != 0 && promise_get(p, e.response) != nil && promise_get(p, e.response).state == .Pending {
		promise_reject(p, e.response, code, msg)
		release_fetch(p, self)   // rejected before a response: the guest never got the handle
		return
	}
	if f = base.pool_get(&p.fetches, self); f == nil { return }
	e = f.ext
	if e.body_promise != 0 {
		bp := e.body_promise
		e.body_promise = 0
		promise_reject(p, bp, code, msg)
	}
	if f = base.pool_get(&p.fetches, self); f == nil { return }
	if s := stream_get(p, f.ext.stream); s != nil { stream_fail(p, s, code, msg) }
}

@(private)
fetch_call_guest :: proc(p: ^Page, f: ^Fetch) {
	inst := instance_by_index(p, f.instance)
	if inst == nil { return }
	h := f.self
	argv := [4]u32{f.user, u32(u64(h)), u32(u64(h) >> 32), u32(f.state)}
	call_guest(p, inst, f.callback, argv[:])
}

@(private)
release_fetch :: proc(p: ^Page, h: base.Handle) {
	f, ok := base.pool_remove(&p.fetches, h)
	if !ok { return }
	fetch_abort(p, &f)   // in a worker the request is the page's: a message cancels it
	p.held -= len(f.body)
	free_fetch(&f)
}

// Network events of a fetch that has an ext (fetch_event hands them over, and worker_fetch_event in a worker).
@(private)
fetch_ext_event :: proc(fp: ^Fetch, ev: Fetch_Update) {
	f := fp
	p := f.page
	e := f.ext
	self := f.self
	if f.state >= 2 { return }   // aborted meanwhile: late events are ignored
	switch ev.kind {
	case .Response:
		f.state, f.status, f.type, f.redirected, f.usable = 1, ev.status, ev.type, ev.redirected, ev.usable
		f.final_url = strings.clone(ev.url)
		f.headers = strings.clone(ev.headers)
		if e.promise_mode {
			promise_resolve(p, e.response, i64(u64(self)))
			return
		}
	case .Data, .Done:
		data := ev.data
		if ev.kind == .Done {
			f.state, f.task = 2, base.NIL_HANDLE
			if e.received { data = nil }   // Done carries a body only when no Data event did
		} else {
			e.received = true
		}
		if f.usable && len(data) > 0 {
			if p.held + len(data) > p.settings.max_fetch_bytes {
				fetch_abort(p, f)   // in a worker the request is the page's: a message cancels it
				delete(f.error)
				f.state, f.error, f.error_kind = 3, strings.clone("page fetch memory limit reached"), .Body_Too_Large
				fetch_ext_finished(p, f)
				fetch_settle_failure(p, f, WEB_ERR_NETWORK)
				return
			}
			p.held += len(data)
			if s := stream_get(p, e.stream); s != nil {
				append(&s.pending, ..data)
				stream_pump(p, s)
			} else {
				append(&f.body, ..data)
			}
		}
		if ev.kind == .Data { return }
		if f = base.pool_get(&p.fetches, self); f == nil { return }
		fetch_ext_finished(p, f)
		if e.promise_mode {
			fetch_settle_body(p, f)
			if f = base.pool_get(&p.fetches, self); f == nil { return }
			if s := stream_get(p, f.ext.stream); s != nil { s.ended = true; stream_pump(p, s) }
			return
		}
	case .Failed:
		f.state, f.task = 3, base.NIL_HANDLE
		delete(f.error)
		f.error = strings.clone(ev.detail)
		f.error_kind = ev.error
		if ev.error != .Transport { log(p, .Error, ev.detail) }
		fetch_ext_finished(p, f)
		fetch_settle_failure(p, f, ev.error == .Aborted ? WEB_ERR_ABORT : WEB_ERR_NETWORK)
		return
	}
	fetch_call_guest(p, f)
}

// The fetch is over: it no longer listens to its signal.
@(private)
fetch_ext_finished :: proc(p: ^Page, f: ^Fetch) {
	e := f.ext
	if e.algo != 0 { signal_remove_algorithm(p, e.signal, e.algo); e.algo = 0 }
}

@(private)
fetch_settle_body :: proc(p: ^Page, f: ^Fetch) {
	e := f.ext
	if e.body_promise == 0 || f.state != 2 { return }
	bp := e.body_promise
	e.body_promise = 0
	switch e.body_kind {
	case .None:
	case .Text:
		text := url.utf8_decode(f.body[:], context.temp_allocator)
		promise_resolve(p, bp, i64(len(text)), text)
	case .Buffer:
		body := f.body
		f.body = {}
		promise_resolve(p, bp, i64(buffer_adopt_counted(p, body, e.body_owner)))
	}
}

// Frees what a fetch record's ext holds; with the page alive, consumers still waiting are told the response is gone.
@(private)
fetch_ext_free :: proc(f: ^Fetch) {
	e := f.ext
	if e == nil { return }
	f.ext = nil
	p := f.page
	if !p.closed {
		if e.algo != 0 { signal_remove_algorithm(p, e.signal, e.algo) }
		if e.response != 0 { promise_reject(p, e.response, WEB_ERR_ABORT, "AbortError: the request was released") }
		if e.body_promise != 0 { promise_reject(p, e.body_promise, WEB_ERR_ABORT, "AbortError: the response was released") }
		if s := stream_get(p, e.stream); s != nil {
			s.fetch = base.NIL_HANDLE
			if !s.ended && !s.failed { stream_fail(p, s, WEB_ERR_ABORT, "AbortError: the response was released") }
		}
	}
	free(e)
}

////////////////////////////////
// Stream

// Fulfils waiting reads: all pending bytes go to the first read; at the end, reads get 0.
@(private)
stream_pump :: proc(p: ^Page, s: ^Body_Stream) {
	for len(s.reads) > 0 {
		if len(s.pending) > 0 {
			r := s.reads[0]
			ordered_remove(&s.reads, 0)
			chunk := s.pending
			s.pending = {}
			promise_resolve(p, r, i64(buffer_adopt_counted(p, chunk, s.owner)))
			continue
		}
		if s.failed {
			r := s.reads[0]
			ordered_remove(&s.reads, 0)
			promise_reject(p, r, s.code, s.error)
			continue
		}
		if s.ended {
			r := s.reads[0]
			ordered_remove(&s.reads, 0)
			promise_resolve(p, r, 0, "done")
			continue
		}
		break
	}
}

@(private)
stream_fail :: proc(p: ^Page, s: ^Body_Stream, code: i64, msg: string) {
	if s.failed || s.ended { return }
	s.failed, s.code = true, code
	s.error = strings.clone(msg)
	p.held -= len(s.pending)
	delete(s.pending)
	s.pending = {}
	stream_pump(p, s)
}

////////////////////////////////
// Imports

// The body of a request: the bytes of `body_buffer` when given, else `body`.
@(private)
request_body :: proc(body: Maybe([]u8), body_buffer: Api_Buffer) -> []byte {
	if body_buffer.data != nil { return body_buffer.data.bytes[:] }
	return body.? or_else nil
}

Fetch_promise :: proc(c: ^Call, url: string, method: string, headers: string, body: Maybe([]u8), body_buffer: Api_Buffer, signal: Api_AbortSignal, options: Api_FetchOptions) -> (u64, Api_Error) {
	p := c.page
	pr := promise_create(p, c.owner)
	e := new(Fetch_Ext)
	e^ = Fetch_Ext{promise_mode = true, response = pr, signal = signal.handle}
	fetch_begin(p, c.owner, url, method, headers, request_body(body, body_buffer), fetch_options_pack(options), 0, 0, e)
	return pr, .None
}

// The callback API with an abort signal and an optional buffer body.
Fetch_startWithSignal :: proc(c: ^Call, url: string, callback: u32, user: i32, method: string, headers: string, body: Maybe([]u8), body_buffer: Api_Buffer, signal: Api_AbortSignal, options: Api_FetchOptions) -> (u64, Api_Error) {
	e := new(Fetch_Ext)
	e^ = Fetch_Ext{signal = signal.handle}
	return fetch_begin(c.page, c.owner, url, method, headers, request_body(body, body_buffer), fetch_options_pack(options), callback, u32(user), e), .None
}

// Starts consuming the body. Plain callback fetches can be consumed once they are done.
@(private)
consume_body :: proc(c: ^Call, r: Api_Fetch, kind: Body_Kind) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	f := r.data
	if f.ext == nil {
		if f.state < 2 { promise_reject(p, pr, WEB_ERR_INVALID_STATE, "InvalidStateError: the body is still loading (use Fetch_promise)"); return pr }
		f.ext = new(Fetch_Ext)
		f.ext.promise_mode = true
	}
	e := f.ext
	if e.body_used || e.body_promise != 0 { promise_reject(p, pr, WEB_ERR_TYPE, "TypeError: body already used"); return pr }
	e.body_used = true
	if f.state == 3 { promise_reject(p, pr, f.error_kind == .Aborted ? WEB_ERR_ABORT : WEB_ERR_NETWORK, f.error); return pr }
	e.body_kind, e.body_promise, e.body_owner = kind, pr, c.owner
	fetch_settle_body(p, f)
	return pr
}

Response_text :: proc(c: ^Call, response: Api_Fetch) -> u64 { return consume_body(c, response, .Text) }
Response_arrayBuffer :: proc(c: ^Call, response: Api_Fetch) -> u64 { return consume_body(c, response, .Buffer) }
Response_bytes :: proc(c: ^Call, response: Api_Fetch) -> u64 { return consume_body(c, response, .Buffer) }

Response_bodyUsed :: proc(c: ^Call, response: Api_Fetch) -> bool {
	f := response.data
	return f.ext != nil && f.ext.body_used
}

// The body as a stream.
Response_body :: proc(c: ^Call, response: Api_Fetch) -> (u64, Api_Error) {
	p := c.page
	f := response.data
	if f.ext == nil {
		f.ext = new(Fetch_Ext)
		f.ext.promise_mode = true
	}
	e := f.ext
	if e.body_used { return 0, fail(c, .Type, "TypeError: body already used") }
	e.body_used = true
	s := new(Body_Stream)
	s.page, s.fetch, s.owner = p, f.self, c.owner
	s.pending = f.body       // what arrived already is the first chunk
	f.body = {}
	s.ended = f.state == 2
	if f.state == 3 { s.failed, s.code, s.error = true, f.error_kind == .Aborted ? WEB_ERR_ABORT : WEB_ERR_NETWORK, strings.clone(f.error) }
	e.stream = object_create(p, &body_stream_vt, s, s.owner)
	return e.stream, .None
}

Stream_read :: proc(c: ^Call, stream: Api_ReadableStream) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	append(&stream.data.reads, pr)
	stream_pump(p, stream.data)
	return pr
}

// reader.cancel(): the download stops, waiting reads finish with "done".
Stream_cancel :: proc(c: ^Call, stream: Api_ReadableStream) {
	p := c.page
	s := stream.data
	if f := base.pool_get(&p.fetches, s.fetch); f != nil && f.state < 2 {
		fetch_abort(p, f)   // in a worker the request is the page's: a message cancels it
		f.state = 2
		fetch_ext_finished(p, f)
	}
	p.held -= len(s.pending)
	delete(s.pending)
	s.pending = {}
	s.ended = true
	stream_pump(p, s)
}