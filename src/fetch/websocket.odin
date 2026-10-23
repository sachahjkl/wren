package fetch

// WebSocket policy: the WHATWG WebSockets constructor rules and Fetch's "obtain a WebSocket connection", on top of the
// transport in net/websocket.odin. Everything a page may not decide for itself is decided here, on the loop thread:
//
//   * URL: http(s) is mapped to ws(s), anything else (or a fragment) is a SyntaxError; subprotocols are unique tokens.
//   * Before connecting: upgrade-insecure-requests and HSTS (ws -> wss), bad ports, mixed content (ws from an https
//     document), CSP connect-src (checked against the http(s) form of the URL, which is the request Fetch makes).
//   * The handshake carries Origin (always), the profile's cookies (SameSite context from the document's top-level site,
//     third-party policy), Sec-WebSocket-Protocol, no extension offer, Fetch Metadata towards trustworthy hosts; the
//     User-Agent is the session's.
//   * The answer must be 101; Set-Cookie and Strict-Transport-Security are processed; the selected subprotocol must be
//     one we offered; any extension is refused (we offer none, so permessage-deflate cannot have been negotiated).

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:csp"
import "wb:http"
import "wb:net"
import "wb:url"

Socket_Event_Kind :: enum u8 {
	Open,      // `protocol`, `extensions` negotiated
	Message,   // `data`, `binary`
	Sent,      // `sent` bytes handed to the OS
	Closing,   // the server started the closing handshake (`code`, `reason`)
	Closed,    // terminal: `code`, `reason`, `clean`
	Failed,    // terminal: `error`, `detail`
}

// Pointers inside an event are valid only during the callback.
Socket_Event :: struct {
	kind:       Socket_Event_Kind,
	protocol:   string,
	extensions: string,
	data:       []byte,
	binary:     bool,
	sent:       int,
	code:       u16,
	reason:     string,
	clean:      bool,
	error:      Error_Kind,
	detail:     string,
	net_code:   u32,
	net_flags:  u32,
}

Socket_Proc :: #type proc(user: rawptr, sock: base.Handle, ev: ^Socket_Event)

Socket_Desc :: struct {
	url:       string,         // absolute ws: / wss: URL (see websocket_parse_url)
	protocols: []string,       // already validated (websocket_protocols_valid); copied
	initiator: ^Environment,   // the document; must outlive the socket (register both in its scope)
	on_event:  Socket_Proc,
	user:      rawptr,
	scope:     ^base.Scope,    // closing it aborts the socket silently
	limits:    net.Ws_Limits,
}

////////////////////////////////
// Constructor rules (WHATWG WebSockets §3.1)

// Parses `input` against `base_url` (nil: absolute only), mapping http(s) to ws(s). ok = false is a SyntaxError.
websocket_parse_url :: proc(input: string, base_url: ^url.URL, allocator := context.allocator) -> (u: url.URL, ok: bool) {
	parsed, pok := url.parse(input, base_url, context.temp_allocator)
	if !pok { return {}, false }
	href := parsed.href
	switch parsed.scheme {
	case "ws", "wss":
	case "http":  href = strings.concatenate({"ws", href[len("http"):]}, context.temp_allocator)
	case "https": href = strings.concatenate({"wss", href[len("https"):]}, context.temp_allocator)
	case: return {}, false
	}
	if parsed.has_fragment { return {}, false }
	return url.parse_absolute(href, allocator)
}

// Each protocol must be a token (RFC 6455 §4.1 / RFC 7230) and appear once (case-sensitive).
websocket_protocols_valid :: proc(list: []string) -> bool {
	for p, i in list {
		if !http.is_token(p) { return false }
		for q in list[:i] { if q == p { return false } }
	}
	return true
}

// The guest passes its protocol list as one comma-separated string (tokens cannot contain commas). "" = none.
websocket_split_protocols :: proc(s: string, allocator := context.temp_allocator) -> []string {
	if s == "" { return nil }
	return strings.split(s, ",", allocator)
}

Close_Check :: enum u8 { Ok, Invalid_Access, Syntax }

// close(code, reason): a code must be 1000 or in 3000-4999 (InvalidAccessError); the reason at most 123 UTF-8 bytes
// (SyntaxError).
websocket_close_check :: proc(code: int, has_code: bool, reason: string) -> Close_Check {
	if has_code && code != 1000 && !(code >= 3000 && code <= 4999) { return .Invalid_Access }
	if len(reason) > net.WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON { return .Syntax }
	return .Ok
}

////////////////////////////////
// Connecting

@(private)
Ws_Ctx :: struct {
	loader:    ^Loader,
	env:       ^Environment,
	target:    url.URL,
	protocols: []string,
	with_cookies: bool,
	site_ctx:  cookies.Site_Context,
	on_event:  Socket_Proc,
	user:      rawptr,
}

// The http(s) origin a ws(s) URL stands for (sites are schemeful: ws://a and http://a are the same site).
@(private)
http_origin_of :: proc(u: url.URL, allocator := context.temp_allocator) -> url.Origin {
	scheme := u.scheme == "wss" ? "https" : u.scheme == "ws" ? "http" : u.scheme
	return url.Origin{scheme = strings.clone(scheme, allocator), host = strings.clone(u.host, allocator), port = url.effective_port(u)}
}

// The checks made before anything is sent, in Fetch order. May upgrade `u` to wss. Exposed for tests.
websocket_policy_check :: proc(l: ^Loader, env: ^Environment, u: ^url.URL) -> (err: Error_Kind, detail: string) {
	p := l.profile
	if u.scheme != "ws" && u.scheme != "wss" { return .Bad_Scheme, "not a WebSocket URL" }
	if l.interceptor.request != nil {
		q := Intercept_Query{url = u.href, method = "GET", destination = .Empty, mode = .Cors, initiator = env, websocket = true}
		r: Intercept_Result
		l.interceptor.request(l.interceptor.user, &q, &r)
		if r.action == .Block { return .Blocked_By_Client, r.reason != "" ? r.reason : "blocked by the content blocker" }
	}
	csp_on := env != nil && p.settings.csp && len(env.policies.policies) > 0
	if u.scheme == "ws" && !url.is_potentially_trustworthy(u^) {
		upgrade := csp_on && csp.has_directive(&env.policies, "upgrade-insecure-requests")
		upgrade ||= p.settings.hsts && hsts_should_upgrade(&p.hsts, u.host, now_ms())
		if upgrade {
			next, ok := url.parse_absolute(strings.concatenate({"wss", u.href[len("ws"):]}, context.temp_allocator))
			if ok { url.destroy(u); u^ = next }
		}
	}
	if port := url.effective_port(u^); is_bad_port(port, &p.settings) { return .Bad_Port, fmt.tprintf("port %d is blocked", port) }
	if env != nil && env.location.scheme == "https" && !url.is_potentially_trustworthy(u^) {
		if p.settings.block_active_mixed || (csp_on && csp.has_directive(&env.policies, "block-all-mixed-content")) {
			return .Blocked_Mixed_Content, fmt.tprintf("blocked insecure WebSocket %s from a secure document", u.href)
		}
	}
	if csp_on {
		// Fetch makes the request for the http(s) form of the URL, and that is what CSP sees ('self', host sources
		// without a scheme and the http->https upgrade then cover ws and wss the way CSP3 intends)
		req, _ := url.parse_absolute(strings.concatenate({u.scheme == "wss" ? "https" : "http", u.href[len(u.scheme):]}, context.temp_allocator), context.temp_allocator)
		v := csp.check_request(&env.policies, .Connect_Src, req, env.origin)
		for viol in v.violations { if env.on_violation != nil { env.on_violation(env.violation_user, viol) } }
		if !v.allowed { return .Blocked_Csp, "blocked by Content-Security-Policy (connect-src)" }
	}
	return .None, ""
}

// Validates and starts a connection. On a policy failure nothing is started and the error is returned (the caller
// reports it asynchronously, as the specification's "fail the WebSocket connection" from a task). Otherwise every
// later outcome arrives through `d.on_event`, never synchronously.
websocket_connect :: proc(l: ^Loader, d: Socket_Desc) -> (sock: base.Handle, err: Error_Kind, detail: string) {
	u, ok := url.parse_absolute(d.url)
	if !ok { return base.NIL_HANDLE, .Bad_URL, "invalid WebSocket URL" }
	if e, why := websocket_policy_check(l, d.initiator, &u); e != .None {
		url.destroy(&u)
		return base.NIL_HANDLE, e, why
	}
	env := d.initiator
	p := l.profile

	ctx := new(Ws_Ctx)
	ctx.loader, ctx.env, ctx.target, ctx.on_event, ctx.user = l, env, u, d.on_event, d.user
	ctx.protocols = make([]string, len(d.protocols))
	for s, i in d.protocols { ctx.protocols[i] = strings.clone(s) }

	// credentials mode "include": the jar decides, the third-party policy may veto
	ctx.with_cookies, ctx.site_ctx = true, .Same_Site
	if env != nil {
		site := url.site_of(http_origin_of(u), context.temp_allocator)
		if !url.same_site(site, env.top_level_site) {
			ctx.site_ctx = .Cross_Site
			if p.settings.third_party_cookies == .Block { ctx.with_cookies = false }
		}
	}

	h := http.headers_make(context.temp_allocator)
	http.append_header(&h, "Origin", env != nil ? url.origin_serialize(env.origin, context.temp_allocator) : "null")
	if len(ctx.protocols) > 0 { http.append_header(&h, "Sec-WebSocket-Protocol", strings.join(ctx.protocols, ", ", context.temp_allocator)) }
	http.append_header(&h, "Cache-Control", "no-cache")
	http.append_header(&h, "Pragma", "no-cache")
	if p.settings.accept_language != "" { http.append_header(&h, "Accept-Language", p.settings.accept_language) }
	if ctx.with_cookies {
		cc := cookies.Context{url = u, site_context = ctx.site_ctx, http_api = true, now_ms = now_ms()}
		if c := cookies.header_for(&p.jar, cc, context.temp_allocator); c != "" { http.append_header(&h, "Cookie", c) }
	}
	if p.settings.fetch_metadata && url.is_potentially_trustworthy(u) {
		http.append_header(&h, "Sec-Fetch-Dest", "websocket")
		http.append_header(&h, "Sec-Fetch-Mode", "websocket")
		site := "none"
		if env != nil {
			target_origin := http_origin_of(u)
			switch {
			case url.same_origin(env.origin, target_origin): site = "same-origin"
			case ctx.site_ctx == .Same_Site:                 site = "same-site"
			case:                                             site = "cross-site"
			}
		}
		http.append_header(&h, "Sec-Fetch-Site", site)
	}

	sock = net.websocket_open(l.net, {
		url = u.href, headers = join_headers(h), on_event = ws_net_event, user = ctx, free_user = ws_ctx_free,
		scope = d.scope, limits = d.limits,
	})
	return sock, .None, ""
}

websocket_send :: proc(l: ^Loader, sock: base.Handle, data: []byte, binary: bool) -> bool { return net.websocket_send(l.net, sock, data, binary) }
websocket_close :: proc(l: ^Loader, sock: base.Handle, code: u16, reason: string) -> bool { return net.websocket_close(l.net, sock, code, reason) }
websocket_abort :: proc(l: ^Loader, sock: base.Handle) -> bool { return net.websocket_abort(l.net, sock) }
websocket_buffered :: proc(l: ^Loader, sock: base.Handle) -> int { return net.websocket_buffered(l.net, sock) }

@(private)
ws_ctx_free :: proc(user: rawptr) {
	ctx := (^Ws_Ctx)(user)
	url.destroy(&ctx.target)
	for s in ctx.protocols { delete(s) }
	delete(ctx.protocols)
	free(ctx)
}

Handshake_Verdict :: struct {
	ok:         bool,
	reason:     string,
	protocol:   string,
	extensions: string,
}

// Checks the server's answer to the upgrade request (WinHTTP has checked Upgrade, Connection and Sec-WebSocket-Accept).
check_websocket_handshake :: proc(status: int, h: http.Headers, offered: []string) -> Handshake_Verdict {
	v: Handshake_Verdict
	if status != 101 { v.reason = fmt.tprintf("unexpected response code %d to the WebSocket handshake", status); return v }
	protos := http.get_all(h, "sec-websocket-protocol")
	if len(protos) > 1 { v.reason = "several Sec-WebSocket-Protocol headers in the response"; return v }
	if len(protos) == 1 {
		p := http.trim_http_whitespace(protos[0])
		found := false
		for o in offered { if o == p { found = true; break } }
		if !found { v.reason = fmt.tprintf("the server selected subprotocol %q which was not offered", p); return v }
		v.protocol = p
	}
	for e in http.get_all(h, "sec-websocket-extensions") {
		if http.trim_http_whitespace(e) != "" { v.reason = fmt.tprintf("the server selected extension %q which was not offered", e); return v }
	}
	v.ok = true
	return v
}

@(private)
ws_net_event :: proc(user: rawptr, sock: base.Handle, ev: ^net.Ws_Event) {
	ctx := (^Ws_Ctx)(user)
	l := ctx.loader
	// Every branch delivers last: the page may abort the socket from its listener, which frees `ctx`.
	switch ev.kind {
	case .Handshake:
		raw := http.parse_header_block(ev.headers, context.temp_allocator)
		if ctx.with_cookies {
			cc := cookies.Context{url = ctx.target, site_context = ctx.site_ctx, http_api = true, now_ms = now_ms()}
			for v in http.get_all(raw, "set-cookie") { cookies.store(&l.profile.jar, v, cc) }
		}
		if ctx.target.scheme == "wss" && l.profile.settings.hsts {
			if v, found := http.get_header(raw, "strict-transport-security"); found { hsts_note(&l.profile.hsts, ctx.target.host, v, now_ms()) }
		}
		v := check_websocket_handshake(ev.status, raw, ctx.protocols)
		if !v.ok {
			on, u := ctx.on_event, ctx.user
			reason := strings.clone(v.reason, context.temp_allocator)
			net.websocket_abort(l.net, sock)   // frees ctx
			out := Socket_Event{kind = .Failed, error = .Transport, detail = reason}
			if on != nil { on(u, sock, &out) }
			return
		}
		protocol := strings.clone(v.protocol, context.temp_allocator)
		if !net.websocket_accept(l.net, sock) { return }   // a Failed event follows
		out := Socket_Event{kind = .Open, protocol = protocol}
		ctx_deliver(ctx, sock, &out)
	case .Message:
		out := Socket_Event{kind = .Message, data = ev.data, binary = ev.binary}
		ctx_deliver(ctx, sock, &out)
	case .Sent:
		out := Socket_Event{kind = .Sent, sent = ev.sent}
		ctx_deliver(ctx, sock, &out)
	case .Closing:
		out := Socket_Event{kind = .Closing, code = ev.code, reason = ev.reason}
		ctx_deliver(ctx, sock, &out)
	case .Closed:
		out := Socket_Event{kind = .Closed, code = ev.code, reason = ev.reason, clean = ev.clean, net_code = ev.error}
		ctx_deliver(ctx, sock, &out)
	case .Failed:
		out := Socket_Event{kind = .Failed, error = .Transport, detail = websocket_error_text(ev.error, ev.secure_flags), net_code = ev.error, net_flags = ev.secure_flags}
		ctx_deliver(ctx, sock, &out)
	}
}

@(private)
ctx_deliver :: proc(ctx: ^Ws_Ctx, sock: base.Handle, ev: ^Socket_Event) {
	if ctx.on_event != nil { ctx.on_event(ctx.user, sock, ev) }
}

websocket_error_text :: proc(code, secure_flags: u32, allocator := context.temp_allocator) -> string {
	switch code {
	case net.WS_ERROR_HANDSHAKE_TIMEOUT: return "the WebSocket handshake timed out"
	case net.WS_ERROR_MESSAGE_TOO_BIG:   return "a received WebSocket message exceeds websocket.max_message_bytes"
	case net.WS_ERROR_INVALID_UTF8:      return "a received WebSocket text message is not valid UTF-8"
	case net.WS_ERROR_TOO_MANY:          return "too many WebSockets are open (websocket.max_connections_total)"
	case net.WS_ERROR_PROTOCOL:          return "WebSocket protocol error"
	case net.WS_ERROR_CLOSE_TIMEOUT:     return "the server did not answer the close frame within websocket.close_timeout_ms"
	case 12152:                          return "invalid data from the WebSocket server (malformed handshake, frame or UTF-8 text)"
	}
	return net.error_text(code, secure_flags, allocator)
}
