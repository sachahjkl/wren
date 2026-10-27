package net

// The built-in network stack (native/net, linked into build\native\wren_native.lib): the transport under the same queues,
// limits, throttling, handles and events as WinHTTP's (network.backend = rust).
//
// Threading: the library runs every request on its own threads and keeps the results in a queue of its own. When the
// queue goes from empty to not empty it calls `rust_notify` on one of its threads, which only posts `rust_drain` to the
// loop (no allocation of ours off the loop thread). `rust_drain` takes the events one by one (`wn_net_poll`; their bytes
// belong to the library until the next poll), copies what the request keeps, and handles them as WinHTTP's.

import "core:os"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:host"

foreign import wren_native_net {
	"../../build/native/wren_native.lib",
	"system:ws2_32.lib",
	"system:advapi32.lib",
	"system:userenv.lib",
	"system:ntdll.lib",
	"system:kernel32.lib",
	"system:bcrypt.lib",
	"system:crypt32.lib",
	"system:secur32.lib",
	"system:ole32.lib",
	"system:oleaut32.lib",
	"system:iphlpapi.lib",
	"system:msvcrt.lib",
	"system:ucrt.lib",
	"system:libvcruntime.lib",
}

@(private)
Wn_Config :: struct {
	user_agent:         [^]u8,
	user_agent_len:     uint,
	extra_ca_pem:       [^]u8,
	extra_ca_pem_len:   uint,
	timeout_resolve_ms: u32,
	timeout_connect_ms: u32,
	timeout_send_ms:    u32,
	timeout_receive_ms: u32,
	read_chunk:         u64,
	high_water:         u64,
	low_water:          u64,
	idle_timeout_ms:    u32,
	max_idle_per_host:  u32,
	h3_race_ms:         u32,
	h3_broken_ms:       u32,
	threads:            u32,
	http2:              u8,
	http3:              u8,
	proxy_system:       u8,
	_pad:               u8,
}

@(private)
Wn_Request :: struct {
	tag:         u64,
	url:         [^]u8,
	url_len:     uint,
	method:      [^]u8,
	method_len:  uint,
	headers:     [^]u8,
	headers_len: uint,
	body:        [^]u8,
	body_len:    uint,
	max_body:    u64,
}

@(private)
Wn_Ws_Open :: struct {
	tag:          u64,
	url:          [^]u8,
	url_len:      uint,
	headers:      [^]u8,
	headers_len:  uint,
	max_message:  u64,
	high_water:   u64,
	low_water:    u64,
	keepalive_ms: u32,
	_pad:         u32,
}

@(private)
Wn_Event :: struct {
	kind:         u32,
	status:       u32,
	tag:          u64,
	error:        u32,
	secure_flags: u32,
	protocol:     u32,
	btype:        u32,
	code:         u32,
	op:           u32,
	n:            u64,
	headers:      [^]u8,
	headers_len:  uint,
	url:          [^]u8,
	url_len:      uint,
	data:         [^]u8,
	data_len:     uint,
	timing:       [9]f32,   // ms from the moment the library was handed the request; -1: did not happen
	remote_len:   u32,
	remote:       [48]u8,
}

@(private)
WN_HEADERS :: 0
@(private)
WN_DATA :: 1
@(private)
WN_DONE :: 2
@(private)
WN_FAILED :: 3
@(private)
WN_WS_FIRST :: 16

@(private)
Wn_Notify :: #type proc "c" (user: rawptr)

@(private, default_calling_convention = "c")
foreign wren_native_net {
	wn_net_create :: proc(cfg: ^Wn_Config, notify: Wn_Notify, user: rawptr) -> rawptr ---
	wn_net_destroy :: proc(c: rawptr) ---
	wn_net_configure :: proc(c: rawptr, cfg: ^Wn_Config) ---
	wn_net_request :: proc(c: rawptr, r: ^Wn_Request) -> u64 ---
	wn_net_cancel :: proc(c: rawptr, id: u64) ---
	wn_net_consumed :: proc(c: rawptr, id: u64, n: u64) ---
	wn_net_set_max_body :: proc(c: rawptr, id: u64, max_body: u64) ---
	wn_net_poll :: proc(c: rawptr, out: ^Wn_Event) -> u8 ---
	wn_ws_open :: proc(c: rawptr, d: ^Wn_Ws_Open) -> u64 ---
	wn_ws_accept :: proc(c: rawptr, id: u64) -> u8 ---
	wn_ws_send :: proc(c: rawptr, id: u64, binary: u8, data: [^]u8, len: uint) -> u8 ---
	wn_ws_shutdown :: proc(c: rawptr, id: u64, code: u16, reason: [^]u8, len: uint) -> u8 ---
}

@(private)
rust_config :: proc(c: ^Client, ca: []byte) -> Wn_Config {
	s := &c.settings
	clamp_u32 :: proc(v: int) -> u32 { return u32(clamp(v, 0, int(max(u32)))) }
	return Wn_Config{
		user_agent = raw_data(s.user_agent), user_agent_len = uint(len(s.user_agent)),
		extra_ca_pem = raw_data(ca), extra_ca_pem_len = uint(len(ca)),
		timeout_resolve_ms = clamp_u32(int(s.timeout_resolve_ms)), timeout_connect_ms = clamp_u32(int(s.timeout_connect_ms)),
		timeout_send_ms = clamp_u32(int(s.timeout_send_ms)), timeout_receive_ms = clamp_u32(int(s.timeout_receive_ms)),
		read_chunk = u64(max(s.read_chunk, 1024)), high_water = u64(max(s.high_water, 4096)), low_water = u64(max(s.low_water, 0)),
		idle_timeout_ms = clamp_u32(s.idle_timeout_ms), max_idle_per_host = clamp_u32(s.max_idle_per_host),
		h3_race_ms = clamp_u32(s.h3_race_ms), h3_broken_ms = clamp_u32(s.h3_broken_ms), threads = clamp_u32(max(s.threads, 1)),
		http2 = u8(s.http2), http3 = u8(s.http3), proxy_system = u8(s.proxy == .System),
	}
}

@(private)
rust_init :: proc(c: ^Client) -> bool {
	ca: []byte
	if c.settings.extra_ca_file != "" {
		data, err := os.read_entire_file(c.settings.extra_ca_file, heap())
		if err == nil { ca = data }
	}
	defer delete(ca, heap())
	cfg := rust_config(c, ca)
	c.rs = wn_net_create(&cfg, rust_notify, c)
	return c.rs != nil
}

@(private)
rust_apply :: proc(c: ^Client) {
	cfg := rust_config(c, nil)
	wn_net_configure(c.rs, &cfg)
}

@(private)
rust_destroy :: proc(c: ^Client) {
	if c.rs == nil { return }
	wn_net_destroy(c.rs)   // its threads are stopped: no notification follows
	c.rs = nil
	host.discard_posted(c.loop, rust_drain, proc(_: rawptr) {})
}

// A library thread: the queue just stopped being empty.
@(private)
rust_notify :: proc "c" (user: rawptr) {
	context = base.process_context()
	c := (^Client)(user)
	host.post(c.loop, rust_drain, c)
}

@(private)
rust_begin :: proc(c: ^Client, h: base.Handle, r: ^Request) -> u32 {
	job := r.job
	job.marks.started = tick_ns()
	d := Wn_Request{
		tag = u64(h),
		url = raw_data(job.url), url_len = uint(len(job.url)),
		method = raw_data(job.method), method_len = uint(len(job.method)),
		headers = raw_data(job.headers), headers_len = uint(len(job.headers)),
		body = raw_data(job.body), body_len = uint(len(job.body)),
		max_body = u64(max(sync.atomic_load(&job.max_body), 0)),
	}
	r.rid = wn_net_request(c.rs, &d)
	return r.rid == 0 ? ERROR_START_FAILED : 0
}

@(private)
rust_drain :: proc(data: rawptr) {
	c := (^Client)(data)
	we: Wn_Event
	for c.rs != nil && wn_net_poll(c.rs, &we) != 0 {
		if we.kind >= WN_WS_FIRST {
			rust_ws_event(c, &we)
			continue
		}
		h := base.Handle(we.tag)
		r := base.pool_get(&c.requests, h)
		if r == nil || r.job == nil { continue }   // cancelled: its bytes stay the library's
		ev := Event{req = h, status = int(we.status), error = we.error, secure_flags = we.secure_flags, protocol = u8(we.protocol)}
		switch we.kind {
		case WN_HEADERS:
			ev.kind = .Headers
			ev.headers = strings.clone(string(we.headers[:we.headers_len]), heap())
			ev.final_url = strings.clone(string(we.url[:we.url_len]), heap())
			ev.timing = rust_timing(r.job, we.timing)
			n := min(int(we.remote_len), len(ev.remote))
			copy(ev.remote[:], we.remote[:n])
			ev.remote_len = u8(n)
		case WN_DATA:
			ev.kind = .Data
			ev.data = make([]byte, we.data_len, heap())
			copy(ev.data, we.data[:we.data_len])
		case WN_DONE:
			ev.kind = .Done
			ev.timing = rust_timing(r.job, we.timing)
		case:
			ev.kind = .Failed
		}
		handle_event(c, &ev)
		free_event(&ev)
	}
}

// The library's marks are from the moment it was handed the request; ours from the moment the request was queued.
@(private)
rust_timing :: proc(job: ^Job, t: [9]f32) -> Timing {
	m := &job.marks
	off := f32(f64(m.started - m.created) / 1e6)
	at :: proc(v, off: f32) -> f32 { return v < 0 ? -1 : v + off }
	return Timing{
		started = off, dns_start = at(t[1], off), dns_end = at(t[2], off), connect_start = at(t[3], off), connect_end = at(t[4], off),
		sending = at(t[5], off), sent = at(t[6], off), response = at(t[7], off), done = at(t[8], off),
	}
}

////////////////////////////////
// WebSockets

@(private)
rust_ws_begin :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) -> u32 {
	job := s.job
	d := Wn_Ws_Open{
		tag = u64(h),
		url = raw_data(job.url), url_len = uint(len(job.url)),
		headers = raw_data(job.headers), headers_len = uint(len(job.headers)),
		max_message = u64(max(s.limits.max_message, 1)),
		high_water = u64(max(s.limits.high_water, 1)), low_water = u64(max(s.limits.low_water, 0)),
		keepalive_ms = u32(clamp(s.limits.keepalive_ms, 0, int(max(u32)))),
	}
	s.rid = wn_ws_open(m.client.rs, &d)
	return s.rid == 0 ? ERROR_START_FAILED : 0
}

@(private)
rust_ws_event :: proc(c: ^Client, we: ^Wn_Event) {
	m := c.ws
	if m == nil || m.shutting_down { return }
	h := base.Handle(we.tag)
	if base.pool_get(&m.sockets, h) == nil { return }
	r := Raw{sock = h, status = int(we.status), error = we.error, secure_flags = we.secure_flags, op = Web_Socket_Operation(we.op), n = int(we.n)}
	switch we.kind - WN_WS_FIRST {
	case 0:
		r.kind = .Headers
		r.headers = strings.clone(string(we.headers[:we.headers_len]), heap())
	case 1:
		r.kind = .Handshake_Failed
	case 2:
		r.kind = .Fragment
		r.btype = Web_Socket_Buffer_Type(we.btype)
		if we.data_len > 0 { r.data = make([]byte, we.data_len, heap()); copy(r.data, we.data[:we.data_len]) }
	case 3:
		r.kind = .Peer_Close
		r.code = u16(we.code)
		r.reason = strings.clone(string(we.data[:we.data_len]), heap())
	case 4:
		r.kind = .Write_Done
	case 5:
		r.kind = .Shutdown_Done
	case:
		r.kind = .Error
	}
	ws_handle(m, &r)
	raw_free(&r)
}
