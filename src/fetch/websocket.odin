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
import "wb:host"
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
Ws_Delayed :: struct {
	out:   bool,   // a message of the page, not yet sent
	due:   f64,
	ev:    Socket_Event,   // what the page is to be told (strings and data owned)
}

// The socket's record in the fetch layer: what its policy and its observer need, kept until the transport lets go of it.
@(private)
Ws_Ctx :: struct {
	loader:    ^Loader,
	sock:      base.Handle,
	obs_id:    u64,
	link:      ^net.Throttle_Link,
	queue:     [dynamic]Ws_Delayed,   // events held back by the link, by when they are due
	timer:     base.Handle,
	last_in, last_out: f64,   // when the last held message of each direction is due (a direction keeps its order)
	ended:     bool,           // the observer was told the socket is over
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
		if l.observer.event != nil {
			l.next_obs += 1
			id := l.next_obs
			observe_id(l, id, Observed{kind = .Ws_Started, method = "GET", url = d.url, scope = d.scope, destination = .Empty, initiator_url = d.initiator != nil ? d.initiator.location.href : ""})
			observe_id(l, id, Observed{kind = .Failed, error = e, detail = why})
		}
		url.destroy(&u)
		return base.NIL_HANDLE, e, why
	}
	env := d.initiator
	p := l.profile

	ctx := new(Ws_Ctx)
	ctx.loader, ctx.env, ctx.target, ctx.on_event, ctx.user = l, env, u, d.on_event, d.user
	if l.observer.event != nil {
		l.next_obs += 1
		ctx.obs_id = l.next_obs
	}
	ctx.link = link_of(l, d.scope)
	if !net.link_active(ctx.link) { ctx.link = nil }
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

	if ctx.obs_id != 0 {
		observe_id(l, ctx.obs_id, Observed{kind = .Ws_Started, method = "GET", url = u.href, scope = d.scope, destination = .Empty, initiator_url = env != nil ? env.location.href : "",
			headers = join_headers(h), detail = strings.join(ctx.protocols, ", ", context.temp_allocator)})
	}
	sock = net.websocket_open(l.net, {
		url = u.href, headers = join_headers(h), on_event = ws_net_event, user = ctx, free_user = ws_ctx_free,
		scope = d.scope, limits = d.limits,
	})
	ctx.sock = sock
	if l.ws_ctx == nil { l.ws_ctx = make(map[base.Handle]^Ws_Ctx) }
	l.ws_ctx[sock] = ctx
	return sock, .None, ""
}

@(private)
ws_ctx_of :: proc(l: ^Loader, sock: base.Handle) -> ^Ws_Ctx {
	if l.ws_ctx == nil { return nil }
	return l.ws_ctx[sock]
}

@(private)
ws_now :: proc(l: ^Loader) -> f64 { return f64(host.now_ns(l.loop)) / 1e6 }

websocket_send :: proc(l: ^Loader, sock: base.Handle, data: []byte, binary: bool) -> bool {
	ctx := ws_ctx_of(l, sock)
	if ctx != nil && ctx.link != nil {
		// a message goes up the link: it reaches the transport when the bytes before it are through, and after the latency
		now := ws_now(l)
		due := max(net.link_schedule(ctx.link, now, len(data), true) + f64(ctx.link.latency_ms), ctx.last_out)
		if due > now + 0.5 || len(ctx.queue) > 0 {
			ctx.last_out = due
			ws_hold(ctx, Ws_Delayed{out = true, due = due, ev = Socket_Event{kind = .Message, data = slice_clone(data), binary = binary}})
			return true
		}
	}
	if ctx != nil { observe_id(l, ctx.obs_id, Observed{kind = .Ws_Frame, data = data, binary = binary, outgoing = true}) }
	return net.websocket_send(l.net, sock, data, binary)
}

websocket_close :: proc(l: ^Loader, sock: base.Handle, code: u16, reason: string) -> bool {
	ctx := ws_ctx_of(l, sock)
	if ctx != nil && ctx.link != nil && ctx.last_out > ws_now(l) {
		// after the messages still on their way up
		ws_hold(ctx, Ws_Delayed{out = true, due = ctx.last_out, ev = Socket_Event{kind = .Closing, code = code, reason = strings.clone(reason)}})
		return true
	}
	if ctx != nil { observe_id(l, ctx.obs_id, Observed{kind = .Ws_Frame, outgoing = true, detail = fmt.tprintf("close %d %s", code, reason)}) }
	return net.websocket_close(l.net, sock, code, reason)
}

websocket_abort :: proc(l: ^Loader, sock: base.Handle) -> bool { return net.websocket_abort(l.net, sock) }

websocket_buffered :: proc(l: ^Loader, sock: base.Handle) -> int {
	n := net.websocket_buffered(l.net, sock)
	if ctx := ws_ctx_of(l, sock); ctx != nil { for d in ctx.queue { if d.out { n += len(d.ev.data) } } }
	return n
}

@(private)
slice_clone :: proc(b: []byte) -> []byte {
	if len(b) == 0 { return nil }
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

@(private)
ws_delayed_free :: proc(d: ^Ws_Delayed) {
	delete(d.ev.data); delete(d.ev.protocol); delete(d.ev.reason); delete(d.ev.detail); delete(d.ev.extensions)
	d^ = {}
}

// Puts an event in the queue by its due time (after the ones due at the same moment) and arms the timer for the first.
@(private)
ws_hold :: proc(ctx: ^Ws_Ctx, d: Ws_Delayed) {
	at := len(ctx.queue)
	for i in 0 ..< len(ctx.queue) { if ctx.queue[i].due > d.due { at = i; break } }
	inject_at(&ctx.queue, at, d)
	ws_arm(ctx)
}

@(private)
ws_arm :: proc(ctx: ^Ws_Ctx) {
	if ctx.timer != base.NIL_HANDLE { host.clear_timer(ctx.loader.loop, ctx.timer); ctx.timer = base.NIL_HANDLE }
	if len(ctx.queue) == 0 { return }
	ctx.timer = host.set_timer(ctx.loader.loop, max(ctx.queue[0].due - ws_now(ctx.loader), 0), 0, ws_fire, ctx)
}

// The timer: the first held event goes on its way (up to the transport, or down to the page).
@(private)
ws_fire :: proc(data: rawptr) {
	ctx := (^Ws_Ctx)(data)
	ctx.timer = base.NIL_HANDLE
	if len(ctx.queue) == 0 { return }
	d := ctx.queue[0]
	ordered_remove(&ctx.queue, 0)
	l, sock := ctx.loader, ctx.sock
	ws_arm(ctx)   // before delivering: the page may drop the socket, and the record's release clears this timer
	defer ws_delayed_free(&d)
	if d.out {
		#partial switch d.ev.kind {
		case .Message:
			observe_id(l, ctx.obs_id, Observed{kind = .Ws_Frame, data = d.ev.data, binary = d.ev.binary, outgoing = true})
			net.websocket_send(l.net, sock, d.ev.data, d.ev.binary)
		case .Closing:
			observe_id(l, ctx.obs_id, Observed{kind = .Ws_Frame, outgoing = true, detail = fmt.tprintf("close %d %s", d.ev.code, d.ev.reason)})
			net.websocket_close(l.net, sock, d.ev.code, d.ev.reason)
		}
		return
	}
	ev := d.ev
	ctx_deliver_now(ctx, sock, &ev)
}

@(private)
ws_ctx_free :: proc(user: rawptr) {
	ctx := (^Ws_Ctx)(user)
	l := ctx.loader
	if ctx.timer != base.NIL_HANDLE { host.clear_timer(l.loop, ctx.timer) }
	for &d in ctx.queue { ws_delayed_free(&d) }
	delete(ctx.queue)
	if !ctx.ended { observe_id(l, ctx.obs_id, Observed{kind = .Ws_Closed, status = 1006, detail = "the connection was dropped"}) }
	if l.ws_ctx != nil { delete_key(&l.ws_ctx, ctx.sock) }
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
		observe_id(l, ctx.obs_id, Observed{kind = .Ws_Response, status = ev.status, headers = ev.headers, protocol = v.protocol})
		if !v.ok {
			on, u := ctx.on_event, ctx.user
			reason := strings.clone(v.reason, context.temp_allocator)
			ctx.ended = true
			observe_id(l, ctx.obs_id, Observed{kind = .Failed, error = .Transport, detail = reason})
			net.websocket_abort(l.net, sock)   // frees ctx
			out := Socket_Event{kind = .Failed, error = .Transport, detail = reason}
			if on != nil { on(u, sock, &out) }
			return
		}
		protocol := strings.clone(v.protocol, context.temp_allocator)
		if !net.websocket_accept(l.net, sock) { return }   // a Failed event follows
		out := Socket_Event{kind = .Open, protocol = protocol}
		ctx_incoming(ctx, sock, &out)
	case .Message:
		out := Socket_Event{kind = .Message, data = ev.data, binary = ev.binary}
		ctx_incoming(ctx, sock, &out)
	case .Sent:
		out := Socket_Event{kind = .Sent, sent = ev.sent}
		ctx_incoming(ctx, sock, &out)
	case .Closing:
		out := Socket_Event{kind = .Closing, code = ev.code, reason = ev.reason}
		ctx_incoming(ctx, sock, &out)
	case .Closed:
		out := Socket_Event{kind = .Closed, code = ev.code, reason = ev.reason, clean = ev.clean, net_code = ev.error}
		ctx_incoming(ctx, sock, &out)
	case .Failed:
		out := Socket_Event{kind = .Failed, error = .Transport, detail = websocket_error_text(ev.error, ev.secure_flags), net_code = ev.error, net_flags = ev.secure_flags}
		ctx_incoming(ctx, sock, &out)
	}
}

// What comes from the transport goes to the page: at once, or through the link (a message is paced by its size, the open
// event waits the latency; whatever follows a held event is held too, so the order never changes).
@(private)
ctx_incoming :: proc(ctx: ^Ws_Ctx, sock: base.Handle, ev: ^Socket_Event) {
	if ctx.link != nil {
		l := ctx.loader
		now := ws_now(l)
		due := now
		#partial switch ev.kind {
		case .Message: due = net.link_schedule(ctx.link, now, len(ev.data), false)
		case .Open:    due = now + f64(ctx.link.latency_ms)
		}
		due = max(due, ctx.last_in)
		if due > now + 0.5 || len(ctx.queue) > 0 {
			ctx.last_in = due
			d := Ws_Delayed{due = due, ev = ev^}
			d.ev.data, d.ev.protocol, d.ev.reason, d.ev.detail, d.ev.extensions = slice_clone(ev.data), strings.clone(ev.protocol), strings.clone(ev.reason), strings.clone(ev.detail), strings.clone(ev.extensions)
			ws_hold(ctx, d)
			return
		}
	}
	ctx_deliver_now(ctx, sock, ev)
}

@(private)
ctx_deliver_now :: proc(ctx: ^Ws_Ctx, sock: base.Handle, ev: ^Socket_Event) {
	l, id := ctx.loader, ctx.obs_id
	if id != 0 && l.observer.event != nil {
		#partial switch ev.kind {
		case .Message: observe_id(l, id, Observed{kind = .Ws_Frame, data = ev.data, binary = ev.binary})
		case .Closing: observe_id(l, id, Observed{kind = .Ws_Frame, detail = fmt.tprintf("close %d %s", ev.code, ev.reason)})
		case .Closed:
			ctx.ended = true
			observe_id(l, id, Observed{kind = .Ws_Closed, status = int(ev.code), detail = ev.reason, clean = ev.clean})
		case .Failed:
			ctx.ended = true
			observe_id(l, id, Observed{kind = .Failed, error = ev.error, detail = ev.detail})
		}
	}
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
