// Package net: HTTP(S) client on top of WinHTTP's asynchronous mode.
//
// Design
//   * No thread of ours: WinHTTP's own pool runs the state machine (send, receive headers, read chunks) and calls
//     `status_callback` on its threads. Thousands of requests cost memory, not threads.
//   * Callback threads never touch browser state. They push `Event`s into a mutex-protected queue and ask the host
//     loop to run `drain` on the main thread (one post per burst). All user callbacks run on the loop thread.
//   * A request is a generational Handle. Cancelling, finishing or closing the owning Scope invalidates it, and any
//     event still in flight for it is dropped. Late events can never reach a recycled request.
//   * Exactly one place closes a request's WinHTTP handle: the main thread (`release`). The per-request `Job`, which
//     the callbacks use, is freed by the last callback WinHTTP sends for that handle (HANDLE_CLOSING).
//   * Back-pressure: reading pauses when too many bytes are queued for a request and resumes when the main thread
//     consumed enough. A slow consumer cannot make the process balloon. A hard cap (`max_body`) bounds a response.
//   * TLS, proxy, HTTP/2, decompression and certificate validation are the operating system's. Cookies and
//     redirects policy stay with the browser (cookies are disabled in WinHTTP).
package net

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import "wb:base"
import "wb:host"
import "wb:url"

// Errors that are not WinHTTP's own live below 12000.
ERROR_BAD_URL        :: 1
ERROR_BODY_TOO_LARGE :: 2
ERROR_START_FAILED   :: 3

Event_Kind :: enum u8 {
	Headers,   // status + raw header block + final URL (after redirects)
	Data,      // a chunk of the body (not delivered in collect mode)
	Done,      // success; in collect mode `data` holds the whole body
	Failed,    // `error` is a WinHTTP / ERROR_* code; see `error_text`
}

// Pointers inside an Event are valid only during the callback.
Event :: struct {
	kind:         Event_Kind,
	req:          base.Handle,
	status:       int,
	headers:      string,
	final_url:    string,
	data:         []byte,
	error:        u32,
	secure_flags: u32,
	job:          ^Job,   // internal
}

Event_Proc :: #type proc(user: rawptr, req: base.Handle, ev: ^Event)

Request_Desc :: struct {
	url:      string,
	method:   string,       // default "GET"
	headers:  string,       // "Name: value\r\nName: value" (no trailing CRLF needed)
	body:     []byte,       // copied
	on_event: Event_Proc,
	user:     rawptr,
	scope:    ^base.Scope,  // closing it cancels the request silently
	collect:  bool,         // deliver one Done event with the entire body instead of Data chunks
	max_body: int,          // 0 = the network.max_response_bytes setting
	priority: Priority,
}

// Requests wait in our own queues (per priority, FIFO) until a per-host and a global slot are free. Waiting for a
// slot therefore never counts against WinHTTP's connect timeout, and the browser decides the order, not the OS.
Priority :: enum u8 { High, Normal, Low }   // e.g. document + CSS, scripts + fetches, images

Request_State :: enum u8 { Queued, Active }

// Everything the WinHTTP callbacks need. Built at fetch time; owned by the callbacks once the request is
// activated (until HANDLE_CLOSING). A request cancelled while queued frees it directly.
Job :: struct {
	client:       ^Client,
	req:          base.Handle,
	port:         u16,
	secure:       bool,
	verb_w, host_w, target_w, headers_w: []u16,
	body:         []byte,
	cur:          []byte,
	total:        int,
	max_body:     int,   // atomic (set_max_body)
	queued:       int,   // atomic: bytes handed to the main thread and not consumed yet
	paused:       b32,   // atomic
	terminal:     bool,
	secure_flags: u32,
}

Request :: struct {
	job:      ^Job,
	hconnect: HINTERNET,
	hrequest: HINTERNET,
	on_event: Event_Proc,
	user:     rawptr,
	scope:    ^base.Scope,
	cleanup:  base.Cleanup_Id,
	collect:  bool,
	body:     [dynamic]byte,
	status:   int,
	state:    Request_State,
	priority: Priority,
	host_key: string,    // "host:port", counted in Client.active while Active; "" = never counted
}

Client :: struct {
	loop:          ^host.Loop,
	session:       HINTERNET,
	requests:      base.Pool(Request),
	queues:        [Priority][dynamic]base.Handle,
	active:        map[string]int,
	active_total:  int,
	settings:      Settings,
	shutting_down: bool,

	mu:            sync.Mutex,
	events:        [dynamic]Event,
	scratch:       [dynamic]Event,
	drain_pending: bool,
	live_jobs:     int,   // atomic
	ws:            ^Ws_Manager,   // WebSockets of this client (websocket.odin), created on first use
}

// `settings` zero value = the defaults (what about:config shows).
client_init :: proc(c: ^Client, loop: ^host.Loop, settings: Settings = {}) -> bool {
	c.loop = loop
	c.settings = settings.max_total == 0 ? settings_default(context.temp_allocator) : settings
	c.settings.user_agent = strings.clone(c.settings.user_agent)   // the client owns its copy
	c.events = make([dynamic]Event, heap())    // appended to from WinHTTP threads
	c.scratch = make([dynamic]Event, heap())
	ua := win.utf8_to_wstring(c.settings.user_agent, context.temp_allocator)
	access: win.DWORD = c.settings.proxy == .System ? WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY : WINHTTP_ACCESS_TYPE_NO_PROXY
	c.session = WinHttpOpen(ua, access, nil, nil, WINHTTP_FLAG_ASYNC)
	if c.session == nil { return false }
	WinHttpSetStatusCallback(c.session, status_callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0)
	apply_timeouts(c)
	decompress: win.DWORD = WINHTTP_DECOMPRESSION_FLAG_ALL
	WinHttpSetOption(c.session, WINHTTP_OPTION_DECOMPRESSION, &decompress, size_of(decompress))
	protocols: win.DWORD
	if c.settings.http2 { protocols |= WINHTTP_PROTOCOL_FLAG_HTTP2 }
	if c.settings.http3 { protocols |= WINHTTP_PROTOCOL_FLAG_HTTP3 }
	if protocols != 0 && !WinHttpSetOption(c.session, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &protocols, size_of(protocols)) {
		protocols &= ~win.DWORD(WINHTTP_PROTOCOL_FLAG_HTTP3)   // HTTP/3 needs a recent Windows
		WinHttpSetOption(c.session, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &protocols, size_of(protocols))
	}
	// Policy belongs to the fetch layer: redirects are returned to it (each hop is re-checked), and the OS never sends
	// ambient credentials on its own.
	never: win.DWORD = WINHTTP_OPTION_REDIRECT_POLICY_NEVER
	WinHttpSetOption(c.session, WINHTTP_OPTION_REDIRECT_POLICY, &never, size_of(never))
	autologon: win.DWORD = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH
	WinHttpSetOption(c.session, WINHTTP_OPTION_AUTOLOGON_POLICY, &autologon, size_of(autologon))
	return true
}

@(private)
apply_timeouts :: proc(c: ^Client) {
	s := c.settings
	// WinHTTP: 0 means "use the default"; -1 is infinite
	t :: proc(v: i32) -> i32 { return v == 0 ? -1 : v }
	WinHttpSetTimeouts(c.session, t(s.timeout_resolve_ms), t(s.timeout_connect_ms), t(s.timeout_send_ms), t(s.timeout_receive_ms))
}

// Applies a changed configuration to the running client. Limits and timeouts take effect immediately (queued requests
// are re-examined); the user agent, protocols and proxy mode need a new session, so they apply at the next start.
client_apply :: proc(c: ^Client, s: Settings) {
	agent := c.settings.user_agent   // the session was opened with it; a new value shows after a restart
	c.settings = s
	c.settings.user_agent = agent
	if c.session != nil { apply_timeouts(c) }
	pump(c)
}
// Cancels everything, waits for WinHTTP to let go of every job, frees the rest.
client_destroy :: proc(c: ^Client) {
	websockets_destroy(c)
	sync.mutex_lock(&c.mu)
	c.shutting_down = true
	sync.mutex_unlock(&c.mu)
	it: u32
	handles: [dynamic]base.Handle
	defer delete(handles)
	for h, _ in base.pool_next(&c.requests, &it) { append(&handles, h) }
	for h in handles { release(c, h) }
	if c.session != nil { WinHttpCloseHandle(c.session); c.session = nil }
	start := time.tick_now()
	for sync.atomic_load(&c.live_jobs) > 0 && time.duration_seconds(time.tick_since(start)) < 5 { time.sleep(time.Millisecond) }
	for &ev in c.events { free_event(&ev) }
	delete(c.events)
	delete(c.scratch)
	for &q in c.queues { delete(q) }
	for k in c.active { delete(k, heap()) }
	delete(c.active)
	delete(c.settings.user_agent)
	base.pool_destroy(&c.requests)
}

// Queues a request. Never calls back synchronously: failures arrive as a Failed event. Returns the request handle.
fetch :: proc(c: ^Client, d: Request_Desc) -> base.Handle {
	r := Request{on_event = d.on_event, user = d.user, scope = d.scope, collect = d.collect, priority = d.priority}
	h, rp := base.pool_insert(&c.requests, r)
	if d.scope != nil {
		rp.cleanup = base.on_close(d.scope, request_scope_closed, new_clone(Owner{c, h}))
	}
	job, key, code := prepare(c, h, d)
	if code != 0 {
		rp.state = .Active   // nothing queued, nothing counted: it only has to deliver its failure
		push_event(c, Event{kind = .Failed, req = h, error = code})
		return h
	}
	rp.job = job
	rp.host_key = key
	append(&c.queues[d.priority], h)
	pump(c)
	return h
}

// Starts every queued request that fits under the limits, highest priority first, FIFO within a priority.
@(private)
pump :: proc(c: ^Client) {
	if c.shutting_down { return }
	for &q in c.queues {
		w := 0
		for i in 0 ..< len(q) {
			h := q[i]
			r := base.pool_get(&c.requests, h)
			if r == nil || r.state != .Queued { continue }   // cancelled while waiting
			if c.active_total < c.settings.max_total && c.active[r.host_key] < c.settings.max_per_host {
				activate(c, h, r)
			} else {
				q[w] = h
				w += 1
			}
		}
		resize(&q, w)
	}
}

@(private)
activate :: proc(c: ^Client, h: base.Handle, r: ^Request) {
	r.state = .Active
	c.active_total += 1
	if n, ok := c.active[r.host_key]; ok {
		c.active[r.host_key] = n + 1
	} else {
		c.active[strings.clone(r.host_key, heap())] = 1   // the map owns its key: requests come and go
	}
	if code := begin(c, r); code != 0 {
		push_event(c, Event{kind = .Failed, req = h, error = code})
	}
}

// Silent: the request's callbacks will not run again. False if it already finished or was cancelled.
cancel :: proc(c: ^Client, h: base.Handle) -> bool {
	return release(c, h)
}

in_flight :: proc(c: ^Client) -> int { return c.requests.count }

// Changes the cap of a request's body while it runs (0 = the network.max_response_bytes setting): a navigation that
// becomes a download (fetch.task_hand_over). The WinHTTP threads read it atomically.
set_max_body :: proc(c: ^Client, h: base.Handle, max_body: int) {
	r := base.pool_get(&c.requests, h)
	if r == nil || r.job == nil { return }
	sync.atomic_store(&r.job.max_body, max_body > 0 ? max_body : c.settings.max_body)
}

////////////////////////////////
// Main thread

@(private)
Owner :: struct { c: ^Client, h: base.Handle }

@(private)
request_scope_closed :: proc(data: rawptr) {
	o := (^Owner)(data)
	release(o.c, o.h)
	free(o)
}

@(private)
heap :: proc() -> runtime.Allocator { return base.process_allocator() }

@(private)
to_wide :: proc(s: string) -> []u16 {
	w16 := win.utf8_to_utf16(s, heap())
	out := make([]u16, len(w16) + 1, heap())
	copy(out, w16)
	delete(w16, heap())
	return out
}

// Builds the job (pure memory work, no OS handle yet). `key` identifies the origin server for the per-host limit.
@(private)
prepare :: proc(c: ^Client, h: base.Handle, d: Request_Desc) -> (job: ^Job, key: string, code: u32) {
	u, ok := url.parse_absolute(d.url, context.temp_allocator)
	if !ok || !(u.scheme == "http" || u.scheme == "https") { return nil, "", ERROR_BAD_URL }

	job = new(Job, heap())
	job.client = c
	job.req = h
	job.port = u16(url.effective_port(u))
	job.secure = u.scheme == "https"
	job.max_body = d.max_body > 0 ? d.max_body : c.settings.max_body
	method := d.method == "" ? "GET" : d.method
	job.verb_w = to_wide(method)
	host := u.host   // WinHTTP takes IPv6 literals without brackets
	if strings.has_prefix(host, "[") { host = host[1:len(host) - 1] }
	job.host_w = to_wide(host)
	target := url.request_target(u, context.temp_allocator)
	job.target_w = to_wide(target)
	if d.headers != "" { job.headers_w = to_wide(d.headers) }
	if len(d.body) > 0 { job.body = make([]byte, len(d.body), heap()); copy(job.body, d.body) }
	sync.atomic_add(&c.live_jobs, 1)

	key = fmt.aprintf("%s:%d", u.host, url.effective_port(u), allocator = heap())
	return job, key, 0
}

// Opens the connection and sends the request. On failure the caller still owns the job through `r`.
@(private)
begin :: proc(c: ^Client, r: ^Request) -> u32 {
	job := r.job
	r.hconnect = WinHttpConnect(c.session, cstring16(raw_data(job.host_w)), job.port, 0)
	if r.hconnect == nil { return u32(win.GetLastError()) }
	flags: win.DWORD = job.secure ? WINHTTP_FLAG_SECURE : 0
	r.hrequest = WinHttpOpenRequest(r.hconnect, cstring16(raw_data(job.verb_w)), cstring16(raw_data(job.target_w)), nil, nil, nil, flags)
	if r.hrequest == nil { return u32(win.GetLastError()) }
	ctx := win.DWORD_PTR(uintptr(job))
	if !WinHttpSetOption(r.hrequest, WINHTTP_OPTION_CONTEXT_VALUE, &ctx, size_of(ctx)) {
		// without a context WinHTTP's HANDLE_CLOSING cannot reach the job: free it here, once
		WinHttpCloseHandle(r.hrequest); r.hrequest = nil
		free_job(job); r.job = nil
		return ERROR_START_FAILED
	}
	cookies: win.DWORD = WINHTTP_DISABLE_COOKIES
	WinHttpSetOption(r.hrequest, WINHTTP_OPTION_DISABLE_FEATURE, &cookies, size_of(cookies))

	hdr: win.LPCWSTR = nil
	hdr_len: win.DWORD = 0
	if job.headers_w != nil { hdr = cstring16(raw_data(job.headers_w)); hdr_len = win.DWORD(len(job.headers_w) - 1) }
	body_ptr: rawptr = len(job.body) > 0 ? raw_data(job.body) : nil
	body_len := win.DWORD(len(job.body))
	if !WinHttpSendRequest(r.hrequest, hdr, hdr_len, body_ptr, body_len, body_len, ctx) {
		return u32(win.GetLastError())
	}
	return 0
}

@(private)
free_job :: proc(job: ^Job) {
	a := heap()
	delete(job.verb_w, a); delete(job.host_w, a); delete(job.target_w, a); delete(job.headers_w, a)
	delete(job.body, a); delete(job.cur, a)
	sync.atomic_sub(&job.client.live_jobs, 1)
	free(job, a)
}

@(private)
free_event :: proc(ev: ^Event) {
	a := heap()
	delete(ev.data, a)
	delete(ev.headers, a)
	delete(ev.final_url, a)
	ev^ = {}
}

// Removes the request and closes its handles. The only place that closes them.
@(private)
release :: proc(c: ^Client, h: base.Handle) -> bool {
	r, ok := base.pool_remove(&c.requests, h)
	if !ok { return false }
	if r.hrequest != nil {
		WinHttpCloseHandle(r.hrequest)   // the job is freed by its HANDLE_CLOSING callback
	} else if r.job != nil {
		free_job(r.job)                  // never reached WinHTTP (queued, or failed to open)
	}
	if r.hconnect != nil { WinHttpCloseHandle(r.hconnect) }
	freed_slot := false
	if r.host_key != "" {
		if r.state == .Active {
			c.active_total -= 1
			if n := c.active[r.host_key]; n <= 1 {
				k, _ := delete_key(&c.active, r.host_key)
				delete(k, heap())
			} else {
				c.active[r.host_key] = n - 1
			}
			freed_slot = true
		}
		delete(r.host_key, heap())
	}
	delete(r.body)
	if r.scope != nil { base.run_cleanup(r.scope, r.cleanup) }
	if freed_slot { pump(c) }
	return true
}

@(private)
push_event :: proc(c: ^Client, ev: Event) {
	sync.mutex_lock(&c.mu)
	if c.shutting_down {   // client_destroy freed (or is freeing) the queue: a late completion is dropped
		sync.mutex_unlock(&c.mu)
		ev := ev
		free_event(&ev)
		return
	}
	append(&c.events, ev)
	post := !c.drain_pending
	c.drain_pending = true
	sync.mutex_unlock(&c.mu)
	if post { host.post(c.loop, drain, c) }
}

@(private)
drain :: proc(data: rawptr) {
	c := (^Client)(data)
	sync.mutex_lock(&c.mu)
	c.drain_pending = false
	c.events, c.scratch = c.scratch, c.events
	sync.mutex_unlock(&c.mu)
	for &ev in c.scratch {
		handle_event(c, &ev)
		free_event(&ev)
	}
	clear(&c.scratch)
}

@(private)
handle_event :: proc(c: ^Client, ev: ^Event) {
	r := base.pool_get(&c.requests, ev.req)
	if r == nil {
		// cancelled or finished already: the bytes still count against nothing (the job is gone or going)
		return
	}
	switch ev.kind {
	case .Headers:
		r.status = ev.status
		deliver(r, ev)
	case .Data:
		n := len(ev.data)
		job := r.job
		q := sync.atomic_sub(&job.queued, n) - n
		if q < c.settings.low_water {
			if _, resumed := sync.atomic_compare_exchange_strong(&job.paused, true, false); resumed {
				if !WinHttpQueryDataAvailable(r.hrequest, nil) {
					push_event(c, Event{kind = .Failed, req = ev.req, error = u32(win.GetLastError())})
				}
			}
		}
		if r.collect {
			append(&r.body, ..ev.data)
		} else {
			deliver(r, ev)
		}
	case .Done:
		if r.collect { ev.data = r.body[:] }
		ev.status = r.status
		deliver(r, ev)
		ev.data = nil   // not the event's to free
		release(c, ev.req)
	case .Failed:
		deliver(r, ev)
		release(c, ev.req)
	}
}

@(private)
deliver :: proc(r: ^Request, ev: ^Event) {
	if r.on_event != nil { r.on_event(r.user, ev.req, ev) }
}

////////////////////////////////
// WinHTTP threads

@(private)
push_from_job :: proc(job: ^Job, ev: Event) {
	ev := ev
	ev.req = job.req
	ev.job = job
	push_event(job.client, ev)
}

@(private)
fail :: proc(job: ^Job, code: u32) {
	if job.terminal { return }
	job.terminal = true
	push_from_job(job, Event{kind = .Failed, error = code, secure_flags = job.secure_flags})
}

@(private)
finish :: proc(job: ^Job) {
	if job.terminal { return }
	job.terminal = true
	push_from_job(job, Event{kind = .Done})
}

@(private)
query_wide :: proc(h: HINTERNET, level: win.DWORD) -> string {
	size: win.DWORD
	WinHttpQueryHeaders(h, level, nil, nil, &size, nil)
	if size == 0 { return "" }
	buf := make([]u16, size / 2 + 1, heap())
	defer delete(buf, heap())
	if !WinHttpQueryHeaders(h, level, nil, raw_data(buf), &size, nil) { return "" }
	s, _ := win.utf16_to_utf8(buf[:size / 2], heap())
	return s
}

@(private)
status_callback :: proc "system" (h: HINTERNET, ctx: win.DWORD_PTR, status: win.DWORD, info: rawptr, info_len: win.DWORD) {
	if ctx == 0 { return }
	context = base.process_context()
	job := (^Job)(uintptr(ctx))

	switch status {
	case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
		if !WinHttpReceiveResponse(h, nil) { fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
		code: win.DWORD
		size: win.DWORD = size_of(code)
		WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil)
		ev := Event{kind = .Headers, status = int(code)}
		ev.headers = query_wide(h, WINHTTP_QUERY_RAW_HEADERS_CRLF)
		usize: win.DWORD
		WinHttpQueryOption(h, WINHTTP_OPTION_URL, nil, &usize)
		if usize > 0 {
			ubuf := make([]u16, usize / 2 + 1, heap())
			if WinHttpQueryOption(h, WINHTTP_OPTION_URL, raw_data(ubuf), &usize) {
				ev.final_url, _ = win.utf16_to_utf8(ubuf[:usize / 2], heap())
			}
			delete(ubuf, heap())
		}
		push_from_job(job, ev)
		if !WinHttpQueryDataAvailable(h, nil) { fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
		n := int((^win.DWORD)(info)^)
		if n == 0 { finish(job); return }
		n = min(n, job.client.settings.read_chunk)
		job.cur = make([]byte, n, heap())
		if !WinHttpReadData(h, raw_data(job.cur), win.DWORD(n), nil) { fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
		n := int(info_len)
		buf := job.cur
		job.cur = nil
		if n == 0 { delete(buf, heap()); finish(job); return }
		job.total += n
		if job.total > sync.atomic_load(&job.max_body) { delete(buf, heap()); fail(job, ERROR_BODY_TOO_LARGE); return }
		push_from_job(job, Event{kind = .Data, data = buf[:n]})
		if sync.atomic_add(&job.queued, n) + n >= job.client.settings.high_water {
			sync.atomic_store(&job.paused, true)
			// The consumer may have drained everything between the add and the store: recheck, then exactly one
			// side (this one or the consumer) wins the b32 and continues.
			if sync.atomic_load(&job.queued) < job.client.settings.low_water {
				if _, mine := sync.atomic_compare_exchange_strong(&job.paused, true, false); !mine { return }
			} else {
				return
			}
		}
		if !WinHttpQueryDataAvailable(h, nil) { fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_SECURE_FAILURE:
		job.secure_flags = u32((^win.DWORD)(info)^)

	case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
		fail(job, u32((^Async_Result)(info).error))

	case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
		free_job(job)
	}
}

////////////////////////////////
// Diagnostics

secure_failure_text :: proc(flags: u32) -> string {
	switch {
	case flags & 0x4 != 0:        return "certificate revoked"
	case flags & 0x20 != 0:       return "certificate expired or not yet valid"
	case flags & 0x10 != 0:       return "certificate name does not match the host"
	case flags & 0x8 != 0:        return "certificate issued by an untrusted authority"
	case flags & 0x2 != 0:        return "invalid certificate"
	case flags & 0x1 != 0:        return "certificate revocation check failed"
	case flags & 0x80000000 != 0: return "TLS channel error"
	}
	return ""
}

error_text :: proc(code, secure_flags: u32, allocator := context.temp_allocator) -> string {
	switch code {
	case ERROR_BAD_URL:        return "invalid or unsupported URL"
	case ERROR_BODY_TOO_LARGE: return "response body too large"
	case ERROR_START_FAILED:   return "could not start the request"
	case 12002:                return "request timed out"
	case 12007:                return "host name could not be resolved"
	case 12017:                return "request cancelled"
	case 12029:                return "could not connect to the server"
	case 12030:                return "connection with the server was lost"
	case 12152:                return "invalid response from the server"
	case 12157, 12175:
		if t := secure_failure_text(secure_flags); t != "" { return fmt.aprintf("secure connection failed: %s", t, allocator = allocator) }
		return "secure connection failed"
	case 12038: return "secure connection failed: certificate name does not match the host"
	case 12045: return "secure connection failed: certificate issued by an untrusted authority"
	}
	return fmt.aprintf("network error %d", code, allocator = allocator)
}
