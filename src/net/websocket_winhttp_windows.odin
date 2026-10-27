package net

// WinHTTP's WebSocket API (Windows 8+): the handshake is an ordinary request upgraded with
// WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, then WinHttpWebSocketCompleteUpgrade turns it into a WebSocket handle. The OS does
// the framing, masking, ping/pong, the Sec-WebSocket-Key / Accept check and TLS; we keep the policy and the reassembly.

import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "wb:base"
import "wb:url"

foreign import winhttp_ws "system:winhttp.lib"

WINHTTP_OPTION_SEND_TIMEOUT                   :: 5
WINHTTP_OPTION_RECEIVE_TIMEOUT                :: 6
WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT       :: 7
WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET          :: 114
WINHTTP_OPTION_WEB_SOCKET_CLOSE_TIMEOUT       :: 115
WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL  :: 116
WINHTTP_OPTION_WEB_SOCKET_RECEIVE_BUFFER_SIZE :: 122
WINHTTP_OPTION_WEB_SOCKET_SEND_BUFFER_SIZE    :: 123

WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE        :: 0x02000000
WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE     :: 0x04000000

WINHTTP_INVALID_STATUS_CALLBACK :: ~uintptr(0)

// `info` of READ_COMPLETE / WRITE_COMPLETE on a WebSocket handle.
Web_Socket_Status :: struct {
	bytes_transferred: win.DWORD,
	buffer_type:       Web_Socket_Buffer_Type,
}

// `info` of REQUEST_ERROR on a WebSocket handle. Starts with the ordinary Async_Result.
Web_Socket_Async_Result :: struct {
	result:    Async_Result,
	operation: Web_Socket_Operation,
}

@(default_calling_convention = "system")
foreign winhttp_ws {
	WinHttpWebSocketCompleteUpgrade :: proc(request: HINTERNET, ctx: win.DWORD_PTR) -> HINTERNET ---
	WinHttpWebSocketSend :: proc(ws: HINTERNET, type: Web_Socket_Buffer_Type, buffer: rawptr, length: win.DWORD) -> win.DWORD ---
	WinHttpWebSocketReceive :: proc(ws: HINTERNET, buffer: rawptr, length: win.DWORD, read: ^win.DWORD, type: ^Web_Socket_Buffer_Type) -> win.DWORD ---
	WinHttpWebSocketClose :: proc(ws: HINTERNET, status: u16, reason: rawptr, reason_len: win.DWORD) -> win.DWORD ---
	WinHttpWebSocketShutdown :: proc(ws: HINTERNET, status: u16, reason: rawptr, reason_len: win.DWORD) -> win.DWORD ---
	WinHttpWebSocketQueryCloseStatus :: proc(ws: HINTERNET, status: ^u16, reason: rawptr, reason_len: win.DWORD, consumed: ^win.DWORD) -> win.DWORD ---
}

////////////////////////////////
// Loop thread (websocket.odin's WinHTTP side)

@(private)
winhttp_ws_prepare :: proc(job: ^Ws_Job, u: url.URL, headers: string) {
	host_name := u.host
	if strings.has_prefix(host_name, "[") { host_name = host_name[1:len(host_name) - 1] }
	job.host_w = to_wide(host_name)
	job.target_w = to_wide(url.request_target(u, context.temp_allocator))
	if headers != "" { job.headers_w = to_wide(headers) }
}

@(private)
winhttp_ws_handshake :: proc(m: ^Ws_Manager, s: ^Socket) -> u32 {
	c := m.client
	job := s.job
	s.hconnect = WinHttpConnect(c.session, cstring16(raw_data(job.host_w)), job.port, 0)
	if s.hconnect == nil { return u32(win.GetLastError()) }
	get := to_wide("GET")
	defer delete(get, heap())
	flags: win.DWORD = job.secure ? WINHTTP_FLAG_SECURE : 0
	s.hrequest = WinHttpOpenRequest(s.hconnect, cstring16(raw_data(get)), cstring16(raw_data(job.target_w)), nil, nil, nil, flags)
	if s.hrequest == nil { return u32(win.GetLastError()) }
	// our own callback before the context: the session's would read the job as an HTTP Job
	if transmute(uintptr)WinHttpSetStatusCallback(s.hrequest, ws_status_callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0) == WINHTTP_INVALID_STATUS_CALLBACK {
		return ERROR_START_FAILED
	}
	ctx := win.DWORD_PTR(uintptr(job))
	if !WinHttpSetOption(s.hrequest, WINHTTP_OPTION_CONTEXT_VALUE, &ctx, size_of(ctx)) { return ERROR_START_FAILED }
	sync.atomic_store(&job.refs, 1)
	cookies: win.DWORD = WINHTTP_DISABLE_COOKIES
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_DISABLE_FEATURE, &cookies, size_of(cookies))
	if !WinHttpSetOption(s.hrequest, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nil, 0) { return u32(win.GetLastError()) }
	// The upgrade is HTTP/1.1 only. Waiting for the 101 is bounded by our handshake timer, and an established socket may
	// stay silent for hours: the session's receive timeouts must not apply.
	h1: win.DWORD = 0
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &h1, size_of(h1))
	infinite: win.DWORD = 0xFFFF_FFFF
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_RECEIVE_TIMEOUT, &infinite, size_of(infinite))
	WinHttpSetOption(s.hrequest, WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT, &infinite, size_of(infinite))

	hdr: win.LPCWSTR = nil
	hdr_len: win.DWORD = 0
	if job.headers_w != nil { hdr = cstring16(raw_data(job.headers_w)); hdr_len = win.DWORD(len(job.headers_w) - 1) }
	if !WinHttpSendRequest(s.hrequest, hdr, hdr_len, nil, 0, 0, ctx) { return u32(win.GetLastError()) }
	return 0
}

// Turns the approved handshake into a WebSocket handle and arms the first receive.
@(private)
winhttp_ws_accept :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) -> bool {
	job := s.job
	hws := WinHttpWebSocketCompleteUpgrade(s.hrequest, win.DWORD_PTR(uintptr(job)))
	if hws == nil {
		ws_push(m, Raw{kind = .Handshake_Failed, sock = h, error = u32(win.GetLastError())})
		return false
	}
	sync.atomic_add(&job.refs, 1)
	s.hws = hws
	sync.atomic_store(&job.hws, uintptr(hws))
	WinHttpSetStatusCallback(hws, ws_status_callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0)
	if s.limits.keepalive_ms > 0 {
		v := win.DWORD(s.limits.keepalive_ms)
		WinHttpSetOption(hws, WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL, &v, size_of(v))
	}
	WinHttpCloseHandle(s.hrequest)   // its HANDLE_CLOSING drops one reference of the job
	s.hrequest = nil
	ws_clear_timer(m, s)
	ws_leave_connecting(m, s)
	s.state = .Open
	job.recv = make([]byte, s.limits.receive_chunk, heap())
	if err := winhttp_ws_receive(job, hws); err != 0 {
		ws_push(m, Raw{kind = .Error, sock = h, error = err, op = .Receive})
	}
	ws_pump(m)
	return true
}

// One frame of the message being sent: at most send_fragment bytes, a text frame cut on a character boundary.
@(private)
winhttp_ws_send :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket, buf: []byte, rest: int) {
	n := min(rest, s.limits.send_fragment)
	if n < rest && !s.cur_binary {
		// keep each text frame a whole number of characters
		k := n
		for k > 0 && buf[s.send_off + k] & 0xC0 == 0x80 { k -= 1 }
		if k > 0 { n = k }
	}
	last := n == rest
	t: Web_Socket_Buffer_Type
	if s.cur_binary { t = last ? .Binary_Message : .Binary_Fragment } else { t = last ? .Utf8_Message : .Utf8_Fragment }
	ptr: rawptr = n > 0 ? &buf[s.send_off] : nil
	s.sending = true
	s.send_len = n
	if err := WinHttpWebSocketSend(s.hws, t, ptr, win.DWORD(n)); err != 0 && err != ERROR_IO_PENDING {
		s.sending = false
		ws_push(m, Raw{kind = .Error, sock = h, error = err, op = .Send})
	}
}

@(private)
winhttp_ws_shutdown :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) {
	reason: rawptr = s.close_len > 0 ? &s.job.close_reason[0] : nil
	if err := WinHttpWebSocketShutdown(s.hws, s.close_code, reason, win.DWORD(s.close_len)); err != 0 && err != ERROR_IO_PENDING {
		ws_push(m, Raw{kind = .Error, sock = h, error = err, op = .Shutdown})
	}
}

////////////////////////////////
// WinHTTP threads

@(private)
winhttp_ws_receive :: proc(job: ^Ws_Job, hws: HINTERNET) -> u32 {
	err := WinHttpWebSocketReceive(hws, raw_data(job.recv), win.DWORD(len(job.recv)), nil, nil)
	if err == 0 || err == ERROR_IO_PENDING { return 0 }
	return err
}

@(private)
ws_push_job :: proc(job: ^Ws_Job, r: Raw) {
	r := r
	r.sock = job.sock
	ws_push(job.mgr, r)
}

@(private)
ws_query_close :: proc(hws: HINTERNET) -> (code: u16, reason: string) {
	buf: [WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON]u8
	used: win.DWORD
	if WinHttpWebSocketQueryCloseStatus(hws, &code, &buf[0], win.DWORD(len(buf)), &used) != 0 { return WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS, "" }
	return code, strings.clone(string(buf[:min(int(used), len(buf))]), heap())
}

@(private)
ws_status_callback :: proc "system" (h: HINTERNET, ctx: win.DWORD_PTR, status: win.DWORD, info: rawptr, info_len: win.DWORD) {
	if ctx == 0 { return }
	context = base.process_context()
	job := (^Ws_Job)(uintptr(ctx))
	is_ws := uintptr(rawptr(h)) == sync.atomic_load(&job.hws)

	switch status {
	case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
		if !WinHttpReceiveResponse(h, nil) { ws_handshake_fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
		code: win.DWORD
		size: win.DWORD = size_of(code)
		WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil)
		ws_push_job(job, Raw{kind = .Headers, status = int(code), headers = query_wide(h, WINHTTP_QUERY_RAW_HEADERS_CRLF)})

	case WINHTTP_CALLBACK_STATUS_SECURE_FAILURE:
		job.secure_flags = u32((^win.DWORD)(info)^)

	case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
		if !is_ws { return }
		st := (^Web_Socket_Status)(info)
		if st.buffer_type == .Close {
			c, reason := ws_query_close(h)
			ws_push_job(job, Raw{kind = .Peer_Close, code = c, reason = reason})
			return
		}
		n := int(st.bytes_transferred)
		data: []byte
		if n > 0 { data = make([]byte, n, heap()); copy(data, job.recv[:n]) }
		ws_push_job(job, Raw{kind = .Fragment, data = data, btype = st.buffer_type})
		if sync.atomic_add(&job.queued, n) + n >= job.high_water {
			sync.atomic_store(&job.paused, true)
			// same race as the HTTP client: whoever wins the b32 continues reading
			if sync.atomic_load(&job.queued) < job.low_water {
				if _, mine := sync.atomic_compare_exchange_strong(&job.paused, true, false); !mine { return }
			} else {
				return
			}
		}
		if err := winhttp_ws_receive(job, h); err != 0 { ws_push_job(job, Raw{kind = .Error, error = err, op = .Receive}) }

	case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
		if !is_ws { return }
		ws_push_job(job, Raw{kind = .Write_Done, n = int((^Web_Socket_Status)(info).bytes_transferred)})

	case WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE:
		if is_ws { ws_push_job(job, Raw{kind = .Shutdown_Done}) }

	case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
		if is_ws {
			ar := (^Web_Socket_Async_Result)(info)
			ws_push_job(job, Raw{kind = .Error, error = u32(ar.result.error), op = ar.operation})
		} else {
			ws_handshake_fail(job, u32((^Async_Result)(info).error))
		}

	case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
		ws_job_unref(job)
	}
}

@(private)
ws_handshake_fail :: proc(job: ^Ws_Job, code: u32) {
	if _, first := sync.atomic_compare_exchange_strong(&job.terminal, false, true); !first { return }
	ws_push_job(job, Raw{kind = .Handshake_Failed, error = code, secure_flags = job.secure_flags})
}
