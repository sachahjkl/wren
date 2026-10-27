package net

// The HTTP client's WinHTTP backend (network.backend = winhttp): the session, a request's handles and the status
// callback that runs WinHTTP's state machine on its own threads. client.odin holds the queues, limits and events both
// backends share; this file is the only one that calls WinHTTP for plain requests.

import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "wb:base"
import "wb:url"

// WinHTTP exists here: network.backend = winhttp is honoured.
WINHTTP_AVAILABLE :: true

// Opens the WinHTTP session with the client's settings (the user agent, proxy mode, protocols and timeouts).
@(private)
winhttp_open :: proc(c: ^Client) -> bool {
	ua := win.utf8_to_wstring(c.settings.user_agent, context.temp_allocator)
	access: win.DWORD = c.settings.proxy == .System ? WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY : WINHTTP_ACCESS_TYPE_NO_PROXY
	c.session = WinHttpOpen(ua, access, nil, nil, WINHTTP_FLAG_ASYNC)
	if c.session == nil { return false }
	WinHttpSetStatusCallback(c.session, status_callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0)
	winhttp_apply_timeouts(c)
	decompress: win.DWORD = WINHTTP_DECOMPRESSION_FLAG_ALL
	WinHttpSetOption(c.session, WINHTTP_OPTION_DECOMPRESSION, &decompress, size_of(decompress))
	// TLS 1.2 and 1.3 asked for by name: WinHTTP leaves TLS 1.3 off unless the program says so, and servers that speak only TLS 1.3
	// (speedtest.net's measurement servers) then fail with a security channel error. An older Windows without 1.3 keeps 1.2.
	tls: win.DWORD = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
	if !WinHttpSetOption(c.session, WINHTTP_OPTION_SECURE_PROTOCOLS, &tls, size_of(tls)) {
		tls = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2
		WinHttpSetOption(c.session, WINHTTP_OPTION_SECURE_PROTOCOLS, &tls, size_of(tls))
	}
	// Never HTTP/3: for a site that announces it WinHTTP tries QUIC first and, where UDP does not get through, never falls
	// back to TCP (odin-lang.org stayed on Connecting). network.http3.enabled is the built-in stack's, which races the two.
	protocols: win.DWORD
	if c.settings.http2 { protocols |= WINHTTP_PROTOCOL_FLAG_HTTP2 }
	if protocols != 0 { WinHttpSetOption(c.session, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &protocols, size_of(protocols)) }
	// Policy belongs to the fetch layer: redirects are returned to it (each hop is re-checked), and the OS never sends
	// ambient credentials on its own.
	never: win.DWORD = WINHTTP_OPTION_REDIRECT_POLICY_NEVER
	WinHttpSetOption(c.session, WINHTTP_OPTION_REDIRECT_POLICY, &never, size_of(never))
	autologon: win.DWORD = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH
	WinHttpSetOption(c.session, WINHTTP_OPTION_AUTOLOGON_POLICY, &autologon, size_of(autologon))
	return true
}

@(private)
winhttp_apply_timeouts :: proc(c: ^Client) {
	s := c.settings
	// WinHTTP: 0 means "use the default"; -1 is infinite
	t :: proc(v: i32) -> i32 { return v == 0 ? -1 : v }
	WinHttpSetTimeouts(c.session, t(s.timeout_resolve_ms), t(s.timeout_connect_ms), t(s.timeout_send_ms), t(s.timeout_receive_ms))
}

@(private)
winhttp_close :: proc(h: HINTERNET) { WinHttpCloseHandle(h) }

@(private)
to_wide :: proc(s: string) -> []u16 {
	w16 := win.utf8_to_utf16(s, heap())
	out := make([]u16, len(w16) + 1, heap())
	copy(out, w16)
	delete(w16, heap())
	return out
}

// The job's UTF-16 copies of what WinHttpConnect / WinHttpOpenRequest / WinHttpSendRequest take.
@(private)
winhttp_prepare :: proc(job: ^Job, u: url.URL, method, headers: string) {
	job.verb_w = to_wide(method)
	host := u.host   // WinHTTP takes IPv6 literals without brackets
	if strings.has_prefix(host, "[") { host = host[1:len(host) - 1] }
	job.host_w = to_wide(host)
	job.target_w = to_wide(url.request_target(u, context.temp_allocator))
	if headers != "" { job.headers_w = to_wide(headers) }
}

// Opens the connection and sends the request. On failure the caller still owns the job through `r`.
@(private)
winhttp_begin :: proc(c: ^Client, r: ^Request) -> u32 {
	job := r.job
	r.hconnect = WinHttpConnect(c.session, cstring16(raw_data(job.host_w)), job.port, 0)
	if r.hconnect == nil { return u32(win.GetLastError()) }
	flags: win.DWORD = job.secure ? WINHTTP_FLAG_SECURE : 0
	r.hrequest = WinHttpOpenRequest(r.hconnect, cstring16(raw_data(job.verb_w)), cstring16(raw_data(job.target_w)), nil, nil, nil, flags)
	if r.hrequest == nil { return u32(win.GetLastError()) }
	ctx := win.DWORD_PTR(uintptr(job))
	job.marks.started = tick_ns()
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

// Reading paused on back-pressure: start it again (0, or the error that ends the request).
@(private)
winhttp_resume :: proc(r: ^Request) -> u32 {
	if !WinHttpQueryDataAvailable(r.hrequest, nil) { return u32(win.GetLastError()) }
	return 0
}

////////////////////////////////
// WinHTTP threads

// The text of an address WinHTTP reports (ANSI or UTF-16, whichever it is: a wide string has a zero second byte; its
// length is then in characters, not bytes: halving it cut "127.0.0.1" to "127.0").
@(private)
remember_address :: proc(m: ^Marks, info: rawptr, info_len: win.DWORD) {
	b := ([^]u8)(info)
	n := 0
	if info_len >= 2 && b[1] == 0 && b[0] != 0 {
		w := ([^]u16)(info)
		for i in 0 ..< int(info_len) {
			if w[i] == 0 || n >= len(m.ip) - 8 { break }
			if w[i] > 127 { n = 0; break }
			m.ip[n] = u8(w[i])
			n += 1
		}
	} else {
		for i in 0 ..< int(info_len) {
			if b[i] == 0 || n >= len(m.ip) - 8 { break }
			m.ip[n] = b[i]
			n += 1
		}
	}
	m.ip_len = u8(n)
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
	m := &job.marks

	switch status {
	case WINHTTP_CALLBACK_STATUS_RESOLVING_NAME:        m.dns_start = tick_ns()
	case WINHTTP_CALLBACK_STATUS_NAME_RESOLVED:
		m.dns_end = tick_ns()
		if info != nil && info_len > 0 { remember_address(m, info, info_len) }
	case WINHTTP_CALLBACK_STATUS_CONNECTING_TO_SERVER:
		m.connect_start = tick_ns()
		if m.ip_len == 0 && info != nil && info_len > 0 { remember_address(m, info, info_len) }
	case WINHTTP_CALLBACK_STATUS_CONNECTED_TO_SERVER:   m.connect_end = tick_ns()
	case WINHTTP_CALLBACK_STATUS_SENDING_REQUEST:       m.sending = tick_ns()
	case WINHTTP_CALLBACK_STATUS_REQUEST_SENT:          m.sent = tick_ns()
	case WINHTTP_CALLBACK_STATUS_RESPONSE_RECEIVED:     m.response = tick_ns()

	case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
		if !WinHttpReceiveResponse(h, nil) { fail(job, u32(win.GetLastError())) }

	case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
		code: win.DWORD
		size: win.DWORD = size_of(code)
		WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil)
		if m.response == 0 { m.response = tick_ns() }
		ev := Event{kind = .Headers, status = int(code), timing = timing_of(m)}
		used: win.DWORD
		usize_p: win.DWORD = size_of(used)
		if WinHttpQueryOption(h, WINHTTP_OPTION_HTTP_PROTOCOL_USED, &used, &usize_p) {
			ev.protocol = used & WINHTTP_PROTOCOL_FLAG_HTTP3 != 0 ? 2 : (used & WINHTTP_PROTOCOL_FLAG_HTTP2 != 0 ? 1 : 0)
		}
		if m.ip_len > 0 {
			ev.remote = m.ip
			ev.remote_len = m.ip_len
			// ":port" follows the address
			digits: [6]u8
			nd := 0
			for p := int(job.port); ; p /= 10 {
				digits[nd] = u8('0' + p % 10)
				nd += 1
				if p < 10 { break }
			}
			if int(ev.remote_len) + nd + 1 <= len(ev.remote) {
				ev.remote[ev.remote_len] = ':'
				ev.remote_len += 1
				for i := nd - 1; i >= 0; i -= 1 {
					ev.remote[ev.remote_len] = digits[i]
					ev.remote_len += 1
				}
			}
		}
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
