// Package net: HTTP(S) client on top of WinHTTP's asynchronous mode, or of the built-in stack (rust.odin,
// network.backend = rust: its own threads, the same queues, limits, events and handles as below).
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
//   * The WinHTTP calls live in client_winhttp_windows.odin / websocket_winhttp_windows.odin; elsewhere
//     (winhttp_other.odin) the built-in stack is the only backend and network.backend = winhttp falls back to it.
package net

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
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

// Where a request spent its time, in ms from the moment it was queued (-1: the step did not happen: a connection that was
// reused has no name lookup, a plain http request no secure handshake). Headers and Done events carry it.
Timing :: struct {
	started:      f32,   // left the queue: a connection slot was free (the time before it is "queued")
	dns_start:    f32,
	dns_end:      f32,
	connect_start: f32,
	connect_end:  f32,   // the connection is up (for https the handshake follows, up to `sending`)
	sending:      f32,   // the request starts to go out
	sent:         f32,   // the request is out
	response:     f32,   // the first byte of the answer (its head)
	done:         f32,   // the last byte of the body (Done)
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
	timing:       Timing,        // Headers, Done
	protocol:     u8,            // Headers: 0 http/1.1, 1 h2, 2 h3
	remote:       [48]u8,        // Headers: the address the connection is to ("ip:port"), remote_len bytes
	remote_len:   u8,
}

// The moments (ticks, ns) WinHTTP's notifications came, written by its callback threads one after the other.
@(private)
Marks :: struct {
	created, started, dns_start, dns_end, connect_start, connect_end, sending, sent, response, done: i64,
	ip:     [48]u8,
	ip_len: u8,
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
	link:     ^Throttle_Link,   // throttle.odin: the answer's events are held back as such a link would (nil: no throttling)
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
	marks:        Marks,
	url, method, headers: string,   // the Rust stack's (rust.odin): UTF-8, heap
}

Request :: struct {
	job:      ^Job,
	hconnect: HINTERNET,
	hrequest: HINTERNET,
	rid:      u64,         // the Rust stack's request (0: none)
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
	link:     ^Throttle_Link,
	delayed:  [dynamic]Delayed,   // events held back by the link, in order
	timer:    base.Handle,       // the timer that starts the request or delivers the next delayed event
	timer_owner: ^Owner,
	begin_pending: bool,         // the timer starts the request (its latency and its upload time)
}

@(private)
Delayed :: struct { ev: Event, due: f64 }

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
	rs:            rawptr,        // the Rust stack's client (rust.odin) when settings.backend == .Rust
}

// `settings` zero value = the defaults (what about:config shows). The WREN_NET_BACKEND environment variable (winhttp,
// rust) overrides the backend: a test suite runs on either stack unchanged.
client_init :: proc(c: ^Client, loop: ^host.Loop, settings: Settings = {}) -> bool {
	c.loop = loop
	c.settings = settings.max_total == 0 ? settings_default(context.temp_allocator) : settings
	c.settings.user_agent = strings.clone(c.settings.user_agent)   // the client owns its copy
	c.settings.extra_ca_file = strings.clone(c.settings.extra_ca_file)
	switch os.get_env("WREN_NET_BACKEND", context.temp_allocator) {
	case "rust":    c.settings.backend = .Rust
	case "winhttp": c.settings.backend = .Winhttp
	case:
		if c.settings.backend == .Rust && c.settings.proxy == .System && system_proxy_uses_pac() {
			fmt.eprintln("net: the system proxy is configured by a script (PAC): network.backend = winhttp for this session")
			c.settings.backend = .Winhttp
		}
	}
	if !WINHTTP_AVAILABLE { c.settings.backend = .Rust }   // the built-in stack is the only one on this system
	c.events = make([dynamic]Event, heap())    // appended to from WinHTTP threads
	c.scratch = make([dynamic]Event, heap())
	if c.settings.backend == .Rust { return rust_init(c) }
	return winhttp_open(c)
}

// Applies a changed configuration to the running client. Limits and timeouts take effect immediately (queued requests
// are re-examined); the user agent, protocols and proxy mode need a new session, so they apply at the next start.
client_apply :: proc(c: ^Client, s: Settings) {
	// the session was opened with these; a new value shows after a restart
	agent, ca, backend := c.settings.user_agent, c.settings.extra_ca_file, c.settings.backend
	c.settings = s
	c.settings.user_agent, c.settings.extra_ca_file, c.settings.backend = agent, ca, backend
	if c.session != nil { winhttp_apply_timeouts(c) }
	if c.rs != nil { rust_apply(c) }
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
	if c.session != nil { winhttp_close(c.session); c.session = nil }
	rust_destroy(c)
	start := time.tick_now()
	for sync.atomic_load(&c.live_jobs) > 0 && time.duration_seconds(time.tick_since(start)) < 5 { time.sleep(time.Millisecond) }
	for &ev in c.events { free_event(&ev) }
	delete(c.events)
	delete(c.scratch)
	for &q in c.queues { delete(q) }
	for k in c.active { delete(k, heap()) }
	delete(c.active)
	delete(c.settings.user_agent)
	delete(c.settings.extra_ca_file)
	base.pool_destroy(&c.requests)
}

// Queues a request. Never calls back synchronously: failures arrive as a Failed event. Returns the request handle.
fetch :: proc(c: ^Client, d: Request_Desc) -> base.Handle {
	r := Request{on_event = d.on_event, user = d.user, scope = d.scope, collect = d.collect, priority = d.priority}
	if link_active(d.link) { r.link = d.link }
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
	if r.link != nil {
		// the request starts after its latency and the time its head and body need to go up
		now := now_ms(c)
		bytes := 300 + len(r.job.body) + len(r.job.headers_w)
		due := link_schedule(r.link, now, bytes, true) + f64(r.link.latency_ms)
		if due > now + 0.5 {
			r.begin_pending = true
			throttle_timer(c, h, r, due - now)
			return
		}
	}
	if code := begin(c, h, r); code != 0 {
		push_event(c, Event{kind = .Failed, req = h, error = code})
	}
}

@(private)
now_ms :: proc(c: ^Client) -> f64 { return f64(host.now_ns(c.loop)) / 1e6 }

@(private)
throttle_timer :: proc(c: ^Client, h: base.Handle, r: ^Request, delay: f64) {
	if r.timer != base.NIL_HANDLE { return }
	r.timer_owner = new_clone(Owner{c, h}, heap())
	r.timer = host.set_timer(c.loop, max(delay, 0), 0, throttle_fire, r.timer_owner)
}

// The request's timer: it starts the request, or delivers the events whose time has come.
@(private)
throttle_fire :: proc(data: rawptr) {
	o := (^Owner)(data)
	c, h := o.c, o.h
	r := base.pool_get(&c.requests, h)
	if r == nil { return }   // (release clears the timer: this does not happen)
	r.timer = base.NIL_HANDLE
	free(r.timer_owner, heap())
	r.timer_owner = nil
	if r.begin_pending {
		r.begin_pending = false
		if code := begin(c, h, r); code != 0 { push_event(c, Event{kind = .Failed, req = h, error = code}) }
		return
	}
	now := now_ms(c)
	for len(r.delayed) > 0 && r.delayed[0].due <= now + 0.5 {
		d := r.delayed[0]
		ordered_remove(&r.delayed, 0)
		ev := d.ev
		process_event(c, &ev)
		free_event(&ev)
		r = base.pool_get(&c.requests, h)   // (the event may have ended the request)
		if r == nil { return }
	}
	if len(r.delayed) > 0 { throttle_timer(c, h, r, r.delayed[0].due - now) }
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
	m := max_body > 0 ? max_body : c.settings.max_body
	sync.atomic_store(&r.job.max_body, m)
	if r.rid != 0 { wn_net_set_max_body(c.rs, r.rid, u64(max(m, 0))) }
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

// Builds the job (pure memory work, no OS handle yet). `key` identifies the origin server for the per-host limit.
@(private)
prepare :: proc(c: ^Client, h: base.Handle, d: Request_Desc) -> (job: ^Job, key: string, code: u32) {
	u, ok := url.parse_absolute(d.url, context.temp_allocator)
	if !ok || !(u.scheme == "http" || u.scheme == "https") { return nil, "", ERROR_BAD_URL }

	job = new(Job, heap())
	job.client = c
	job.req = h
	job.marks.created = tick_ns()
	job.port = u16(url.effective_port(u))
	job.secure = u.scheme == "https"
	job.max_body = d.max_body > 0 ? d.max_body : c.settings.max_body
	method := d.method == "" ? "GET" : d.method
	if len(d.body) > 0 { job.body = make([]byte, len(d.body), heap()); copy(job.body, d.body) }
	sync.atomic_add(&c.live_jobs, 1)
	key = fmt.aprintf("%s:%d", u.host, url.effective_port(u), allocator = heap())
	if c.settings.backend == .Rust {
		job.url = strings.clone(d.url, heap())
		job.method = strings.clone(method, heap())
		job.headers = strings.clone(d.headers, heap())
		return job, key, 0
	}
	winhttp_prepare(job, u, method, d.headers)
	return job, key, 0
}

// Opens the connection and sends the request. On failure the caller still owns the job through `r`.
@(private)
begin :: proc(c: ^Client, h: base.Handle, r: ^Request) -> u32 {
	if c.rs != nil { return rust_begin(c, h, r) }
	return winhttp_begin(c, r)
}

@(private)
free_job :: proc(job: ^Job) {
	a := heap()
	delete(job.verb_w, a); delete(job.host_w, a); delete(job.target_w, a); delete(job.headers_w, a)
	delete(job.body, a); delete(job.cur, a)
	delete(job.url, a); delete(job.method, a); delete(job.headers, a)
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
	if r.rid != 0 {
		wn_net_cancel(c.rs, r.rid)       // the library keeps nothing of the job: it is ours to free
		free_job(r.job)
	} else if r.hrequest != nil {
		winhttp_close(r.hrequest)        // the job is freed by its HANDLE_CLOSING callback
	} else if r.job != nil {
		free_job(r.job)                  // never reached WinHTTP (queued, or failed to open)
	}
	if r.hconnect != nil { winhttp_close(r.hconnect) }
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
	if r.timer != base.NIL_HANDLE { host.clear_timer(c.loop, r.timer); free(r.timer_owner, heap()) }
	for &d in r.delayed { free_event(&d.ev) }
	delete(r.delayed)
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
	if r.link != nil {
		// through the link: a piece leaves when the bytes before it are through, and a later event never passes an earlier one
		now := now_ms(c)
		due := now
		#partial switch ev.kind {
		case .Data: due = link_schedule(r.link, now, len(ev.data), false)
		}
		if len(r.delayed) > 0 { due = max(due, r.delayed[len(r.delayed) - 1].due) }
		if due > now + 0.5 || len(r.delayed) > 0 {
			req := ev.req
			append(&r.delayed, Delayed{ev = ev^, due = due})
			ev^ = {}   // the delayed list owns what it holds
			throttle_timer(c, req, r, r.delayed[0].due - now)
			return
		}
	}
	process_event(c, ev)
}

@(private)
process_event :: proc(c: ^Client, ev: ^Event) {
	r := base.pool_get(&c.requests, ev.req)
	if r == nil { return }
	switch ev.kind {
	case .Headers:
		r.status = ev.status
		deliver(r, ev)
	case .Data:
		n := len(ev.data)
		job := r.job
		if r.rid != 0 {
			wn_net_consumed(c.rs, r.rid, u64(n))
		} else if q := sync.atomic_sub(&job.queued, n) - n; q < c.settings.low_water {
			if _, resumed := sync.atomic_compare_exchange_strong(&job.paused, true, false); resumed {
				if err := winhttp_resume(r); err != 0 { push_event(c, Event{kind = .Failed, req = ev.req, error = err}) }
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
	job.marks.done = tick_ns()
	push_from_job(job, Event{kind = .Done, timing = timing_of(&job.marks)})
}

@(private)
tick_ns :: proc() -> i64 { return i64(time.tick_now()._nsec) }

// The marks as milliseconds from the moment the request was made (-1: that step did not happen).
@(private)
timing_of :: proc(m: ^Marks) -> Timing {
	at :: proc(m: ^Marks, v: i64) -> f32 { return v == 0 || v < m.created ? -1 : f32(f64(v - m.created) / 1e6) }
	return Timing{
		started = at(m, m.started), dns_start = at(m, m.dns_start), dns_end = at(m, m.dns_end), connect_start = at(m, m.connect_start),
		connect_end = at(m, m.connect_end), sending = at(m, m.sending), sent = at(m, m.sent), response = at(m, m.response), done = at(m, m.done),
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
	case 12037: return "secure connection failed: certificate expired or not yet valid"
	case 12038: return "secure connection failed: certificate name does not match the host"
	case 12045: return "secure connection failed: certificate issued by an untrusted authority"
	}
	return fmt.aprintf("network error %d", code, allocator = allocator)
}
