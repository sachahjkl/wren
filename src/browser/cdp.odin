package browser

// CDP / WebDriver BiDi adapter: a WebSocket server (src/remote tcp_server + ws) in front of the same command engine
// `wren ctl` drives (remote_methods.odin), so standard tools (Puppeteer, Playwright connectOverCDP, Chrome DevTools)
// can drive Wren without a second control path. It translates: a CDP or BiDi message in, a Wren Call out, the Wren
// reply or event back in the shape the tool expects. The method names of `wren ctl` already follow CDP where Wren has
// the same thing (docs/remote.md), so most of the translation is the envelope (sessions, string target ids) and the
// few results whose shape differs.
//
// Security (docs/cdp.md): it listens on 127.0.0.1 only (tcp_server binds the loopback address); the handshake refuses a
// request whose Host or Origin is not loopback (the DNS-rebinding guard a page would need to reach it); it is off
// unless asked for (remote.cdp.enabled, or --remote-debugging-port=N on the command line). Everything a client does is
// what the user could do in the window.
//
// Transport: each client is a tcp_server connection. Before the WebSocket handshake it is an HTTP client (the /json
// endpoints); after, it carries CDP (or BiDi) messages as text frames. Its conn id, tagged with remote.CDP_CONN_TAG,
// lets remote_send route the Wren engine's replies back here (remote_shell.odin).

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import config "toolkit:config"
import "wb:base"
import "wb:host"
import "wb:remote"

// Cap on a client's buffered input or reassembled fragmented message so an unclosed request or frame cannot exhaust memory.
@(private) CDP_MAX_INBUF :: 16 << 20

// Shorthands used across the CDP files (json.Object is verbose and appears everywhere here).
json_obj :: json.Object

json_parse :: proc(s: string) -> (json.Value, bool) {
	root, err := json.parse(transmute([]byte)s, json.Specification.JSON, true, context.temp_allocator)
	return root, err == .None
}

// What a client is now, and the state of its CDP / BiDi session.
Cdp_Flavor :: enum u8 { None, Cdp, Bidi }

Cdp_Client :: struct {
	tcp_id:      u64,                  // the tcp_server connection (untagged)
	conn:        u64,                  // the tagged id the Wren engine answers to (tcp_id | CDP_CONN_TAG)
	upgraded:    bool,                 // the WebSocket handshake is done
	flavor:      Cdp_Flavor,           // CDP or BiDi (BiDi once a session.new / a bidi method arrives)
	inbuf:       [dynamic]byte,        // bytes not yet a whole handshake or frame (the process heap)
	frag_buf:    [dynamic]byte,        // payload accumulated across fragmented WebSocket frames
	frag_op:     remote.Ws_Opcode,     // initial opcode of the active fragmented message (.Text or .Binary)
	frag_active: bool,                 // a fragmented WebSocket message is in progress
	pending:     map[u64]Cdp_Pending,  // Wren request id -> how to shape its reply (the engine answers by id)
	next_wren:   u64,                  // the Wren request ids this client hands out
	session:     string,               // CDP sessionId handed to the tool (owned), or a BiDi context session
	auto_attach: bool,                 // Target.setAutoAttach: new targets are attached and announced
}

// How a Wren reply is to be turned back into a CDP / BiDi message for the client.
Cdp_Pending :: struct {
	kind:   Cdp_Reply_Kind,
	msg_id: string,     // the tool's message id as JSON text (owned)
	method: string,     // the CDP / BiDi method (owned), for a shape that depends on it
	bidi:   bool,
}

Cdp_Reply_Kind :: enum u8 { Passthrough, Targets, Screenshot, Empty, Bidi_Navigate, Bidi_Evaluate, Bidi_Tree, Bidi_Screenshot, Bidi_Empty }

Cdp :: struct {
	active:    bool,
	started:   bool,
	port:      int,
	clients:   map[u64]^Cdp_Client,   // by tcp_id
}

the_cdp: Cdp

////////////////////////////////
// Lifecycle

// `--remote-debugging-port` / `--remote-debugging-address` on the command line; "" and -1 when absent.
cdp_extract_args :: proc(args: []string) -> (port: int, have_port: bool, address: string, rest: [dynamic]string) {
	port = -1
	rest = make([dynamic]string, context.temp_allocator)
	for a in args {
		switch {
		case a == "--remote-debugging-port":
			port, have_port = 0, true   // bare: the system picks a free port (written to DevToolsActivePort)
		case strings.has_prefix(a, "--remote-debugging-port="):
			if n, ok := strconv.parse_int(a[len("--remote-debugging-port="):]); ok { port, have_port = n, true }
		case strings.has_prefix(a, "--remote-debugging-address="):
			address = a[len("--remote-debugging-address="):]   // only loopback is honoured (see cdp_start)
		case:
			append(&rest, a)
		}
	}
	return
}

// Starts the CDP channel when asked for. `cli_port` / `have_cli`: --remote-debugging-port. Called with remote_start (the
// loop and the first tab exist). The address is ignored beyond a warning when it is not loopback: the server binds
// 127.0.0.1 whatever is asked (a remote bind is a security hazard this build does not offer).
cdp_start :: proc(app: ^App, cli_port: int, have_cli: bool, cli_address: string) {
	c := &the_cdp
	cfg_enabled := config.bool_of(&app.prefs, "remote.cdp.enabled")
	if !have_cli && !cfg_enabled { return }
	if cli_address != "" && cli_address != "127.0.0.1" && cli_address != "localhost" {
		tab_log(current_tab(app), .Warn, fmt.tprintf("remote debugging binds 127.0.0.1 only; --remote-debugging-address=%s ignored", cli_address))
	}
	port := have_cli ? cli_port : int(config.int_of(app_prefs(app), "remote.cdp.port"))
	max_clients := int(config.int_of(app_prefs(app), "remote.cdp.max_clients"))
	c.clients = make(map[u64]^Cdp_Client)
	if err := remote.tcp_start(&app.loop, port, max_clients, cdp_handle, cdp_closed, nil); err != "" {
		tab_log(current_tab(app), .Warn, fmt.tprintf("remote debugging: %s", err))
		delete(c.clients)
		c^ = {}
		return
	}
	c.active, c.started, c.port = true, true, remote.tcp_port()
	// the engine that runs the scripts and the operations (wren ctl's) answers the CDP calls too: it works without the pipe
	if !app.remote.active {
		app.remote.cfg = remote.settings_from_prefs(app_prefs(app))
		app.remote.active = true
		remote_take_baseline(app)
	}
	// a line a tool reads to find the browser endpoint, as Chrome writes DevToolsActivePort in its profile
	cdp_write_active_port(app)
}

cdp_stop :: proc(app: ^App) {
	c := &the_cdp
	if !c.active { return }
	if c.started { remote.tcp_stop() }
	for _, cl in c.clients { cdp_client_free(cl) }
	delete(c.clients)
	cdp_remove_active_port(app)
	c^ = {}
}

cdp_running :: proc() -> bool { return the_cdp.active }
cdp_port :: proc() -> int { return the_cdp.port }

@(private = "file")
app_prefs :: proc(app: ^App) -> ^config.Prefs { return &app.prefs }

@(private = "file")
cdp_client_free :: proc(cl: ^Cdp_Client) {
	// the client's subscription to Wren events is dropped (it was added on upgrade)
	if the_app != nil {
		for i := len(the_app.remote.subs) - 1; i >= 0; i -= 1 { if the_app.remote.subs[i] == cl.conn { unordered_remove(&the_app.remote.subs, i) } }
	}
	delete(cl.inbuf)
	delete(cl.frag_buf)
	for _, p in cl.pending { delete(p.msg_id); delete(p.method) }
	delete(cl.pending)
	delete(cl.session)
	free(cl)
}

////////////////////////////////
// The transport: HTTP, then WebSocket frames

@(private = "file")
cdp_closed :: proc(user: rawptr, tcp_id: u64) {
	c := &the_cdp
	if cl, ok := c.clients[tcp_id]; ok {
		cdp_client_free(cl)
		delete_key(&c.clients, tcp_id)
	}
}

// Appends incoming bytes to `cl.inbuf` if the result fits within CDP_MAX_INBUF; returns false on overflow.
@(private)
cdp_append_inbuf :: proc(cl: ^Cdp_Client, data: []byte) -> bool {
	if len(data) > CDP_MAX_INBUF || len(cl.inbuf) > CDP_MAX_INBUF - len(data) {
		clear(&cl.inbuf)
		return false
	}
	append(&cl.inbuf, ..data)
	return true
}

// Raw bytes from a client (the loop thread). Collects them until a handshake or a frame is whole.
@(private = "file")
cdp_handle :: proc(user: rawptr, tcp_id: u64, data: []byte) {
	app := the_app
	if app == nil { return }
	c := &the_cdp
	cl := c.clients[tcp_id]
	if cl == nil {
		cl = new(Cdp_Client)
		cl.tcp_id = tcp_id
		cl.conn = tcp_id | CDP_CONN_TAG
		cl.pending = make(map[u64]Cdp_Pending)
		c.clients[tcp_id] = cl
	}
	if !cdp_append_inbuf(cl, data) {
		if cl.upgraded {
			remote.tcp_send(cl.tcp_id, remote.ws_close_frame(1009, context.temp_allocator))
		} else {
			cdp_http_send(cl, "413 Content Too Large", "text/plain", "request too large")
		}
		remote.tcp_close_client(cl.tcp_id)
		return
	}
	cdp_drain(app, cl)
}

// Parses the buffer: the handshake until the upgrade, then frames. A chrome frame under a page's script runs the loop
// too; nothing of a page may be touched from there, so processing is deferred to the interface frame (the bytes stay in
// the buffer, and a posted task drains them again). A page cannot reach this channel: there is no path from it to a socket.
@(private = "file")
cdp_drain :: proc(app: ^App, cl: ^Cdp_Client) {
	if shell_nested() {
		host.post(&app.loop, cdp_drain_posted, rawptr(uintptr(cl.tcp_id)))
		return
	}
	if !cl.upgraded {
		cdp_try_handshake(app, cl)
		if !cl.upgraded { return }   // still HTTP, rejected, or waiting for headers
	}
	cdp_drain_frames(app, cl)
}

@(private = "file")
cdp_drain_posted :: proc(data: rawptr) {
	app := the_app
	if app == nil { return }
	if cl, ok := the_cdp.clients[u64(uintptr(data))]; ok { cdp_drain(app, cl) }
}

// Before the upgrade: parse the HTTP request. Both WebSocket upgrades and the /json HTTP endpoints enforce the loopback
// Host/Origin guard against DNS rebinding; frames arriving right after the upgrade are drained once by cdp_drain.
@(private)
cdp_try_handshake :: proc(app: ^App, cl: ^Cdp_Client) {
	h := remote.ws_parse_handshake(cl.inbuf[:])
	if !h.complete { return }
	if !cdp_origin_ok(h.host, h.origin) {
		cdp_http_send(cl, "403 Forbidden", "text/plain", "origin not allowed")
		clear(&cl.inbuf)
		remote.tcp_close_client(cl.tcp_id)
		return
	}
	if h.ok {
		resp := remote.ws_accept_response(h.key)
		remote.tcp_send(cl.tcp_id, transmute([]byte)resp)
		cl.upgraded = true
		cl.flavor = .Cdp
		// a CDP client gets Wren's events (translated): it joins the subscription list, as Remote.subscribe does
		if app != nil { append(&app.remote.subs, cl.conn) }
		// keep any frame bytes after the handshake; cdp_drain will drain them immediately
		remove_range(&cl.inbuf, 0, h.header_end)
		return
	}
	// a plain HTTP request: the /json endpoints
	cdp_http_request(app, cl, h.path)
	// the request is consumed; keep anything after it for a next one
	remove_range(&cl.inbuf, 0, h.header_end)
}

// The loopback guard against DNS rebinding: Host and Origin, when present, must be a loopback name. A tool connecting
// by ws://127.0.0.1:<port> sends Host "127.0.0.1:<port>" and usually no Origin; a page on a site has an Origin of that
// site, which is refused.
@(private)
cdp_origin_ok :: proc(host, origin: string) -> bool {
	loopback :: proc(s: string) -> bool {
		hostpart := strings.trim_space(s)
		// strip a scheme (origin: http://127.0.0.1) and any path
		if i := strings.index(hostpart, "://"); i >= 0 { hostpart = hostpart[i + 3:] }
		if i := strings.index_byte(hostpart, '/'); i >= 0 { hostpart = hostpart[:i] }
		if strings.index_byte(hostpart, '@') >= 0 { return false }
		// bracketed IPv6 literal: [::1] or [::1]:<port>
		if strings.has_prefix(hostpart, "[") {
			close := strings.index_byte(hostpart, ']')
			if close < 0 { return false }
			rest := hostpart[close + 1:]
			if len(rest) > 0 {
				if rest[0] != ':' || len(rest) == 1 { return false }
				for c in transmute([]byte)rest[1:] { if c < '0' || c > '9' { return false } }
			}
			return hostpart[1:close] == "::1"
		}
		if hostpart == "::1" { return true }
		if i := strings.index_byte(hostpart, ':'); i >= 0 {
			port := hostpart[i + 1:]
			if len(port) == 0 { return false }
			for c in transmute([]byte)port { if c < '0' || c > '9' { return false } }
			hostpart = hostpart[:i]
		}
		return hostpart == "127.0.0.1" || base.ascii_equal_fold(hostpart, "localhost")
	}
	if host != "" && !loopback(host) { return false }
	if origin != "" && !loopback(origin) { return false }
	return true
}

@(private = "file")
cdp_http_request :: proc(app: ^App, cl: ^Cdp_Client, path: string) {
	switch {
	case path == "/json/version":
		cdp_http_send(cl, "200 OK", "application/json", cdp_version_json(app))
	case path == "/json" || path == "/json/list":
		cdp_http_send(cl, "200 OK", "application/json", cdp_list_json(app))
	case strings.has_prefix(path, "/json/new"):
		cdp_http_send(cl, "200 OK", "application/json", cdp_new_target(app, cdp_query_url(path)))
	case strings.has_prefix(path, "/json/close/"):
		cdp_close_target(app, path[len("/json/close/"):])
		cdp_http_send(cl, "200 OK", "text/plain", "Target is closing")
	case strings.has_prefix(path, "/json/activate/"):
		cdp_activate_target(app, path[len("/json/activate/"):])
		cdp_http_send(cl, "200 OK", "text/plain", "Target activated")
	case path == "/json/protocol":
		cdp_http_send(cl, "200 OK", "application/json", `{"domains":[]}`)   // the full descriptor is not shipped; tools fall back to their own
	case:
		cdp_http_send(cl, "404 Not Found", "text/plain", "unknown endpoint")
	}
}

@(private = "file")
cdp_http_send :: proc(cl: ^Cdp_Client, status, mime, body: string) {
	resp := fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s", status, mime, len(body), body)
	remote.tcp_send(cl.tcp_id, transmute([]byte)resp)
}

@(private = "file")
cdp_query_url :: proc(path: string) -> string {
	if i := strings.index_byte(path, '?'); i >= 0 { return path[i + 1:] }
	// Chrome also accepts /json/new?<url> and /json/new/<url>; the common form is the query
	if i := strings.index_byte(path, ' '); i >= 0 { return path[:i] }
	return ""
}

// Closes the WebSocket client with `code` and drops any buffered bytes.
@(private = "file")
cdp_fail_ws :: proc(cl: ^Cdp_Client, code: u16) {
	remote.tcp_send(cl.tcp_id, remote.ws_close_frame(code, context.temp_allocator))
	clear(&cl.inbuf)
	clear(&cl.frag_buf)
	cl.frag_active = false
	remote.tcp_close_client(cl.tcp_id)
}

// Reads whole WebSocket frames out of the buffer and acts on each.
// Returns the WebSocket close code sent if the connection was closed (0 while still open).
@(private)
cdp_drain_frames :: proc(app: ^App, cl: ^Cdp_Client) -> u16 {
	for {
		f, consumed, got, bad := remote.ws_decode_frame(cl.inbuf[:])
		if bad { cdp_fail_ws(cl, 1002); return 1002 }
		if !got { return 0 }
		switch f.opcode {
		case .Text, .Binary:
			if cl.frag_active { cdp_fail_ws(cl, 1002); return 1002 }
			if f.fin {
				if f.opcode == .Text {
					// the frame payload points into inbuf; copy it before the buffer is shifted
					msg := make([]byte, len(f.payload), context.temp_allocator)
					copy(msg, f.payload)
					remove_range(&cl.inbuf, 0, consumed)
					cdp_message(app, cl, msg)
					continue
				}
			} else {
				cl.frag_active = true
				cl.frag_op = f.opcode
				clear(&cl.frag_buf)
				if f.opcode == .Text {
					if len(f.payload) > CDP_MAX_INBUF { cdp_fail_ws(cl, 1009); return 1009 }
					append(&cl.frag_buf, ..f.payload)
				}
			}
		case .Continuation:
			if !cl.frag_active { cdp_fail_ws(cl, 1002); return 1002 }
			if cl.frag_op == .Text {
				if len(f.payload) > CDP_MAX_INBUF || len(cl.frag_buf) > CDP_MAX_INBUF - len(f.payload) {
					cdp_fail_ws(cl, 1009)
					return 1009
				}
				append(&cl.frag_buf, ..f.payload)
			}
			if f.fin {
				op := cl.frag_op
				cl.frag_active = false
				remove_range(&cl.inbuf, 0, consumed)
				if op == .Text {
					msg := make([]byte, len(cl.frag_buf), context.temp_allocator)
					copy(msg, cl.frag_buf[:])
					clear(&cl.frag_buf)
					cdp_message(app, cl, msg)
				}
				continue
			}
		case .Ping:
			if !f.fin || len(f.payload) > 125 { cdp_fail_ws(cl, 1002); return 1002 }
			remote.tcp_send(cl.tcp_id, remote.ws_encode_frame(.Pong, f.payload, context.temp_allocator))
		case .Pong:
			if !f.fin || len(f.payload) > 125 { cdp_fail_ws(cl, 1002); return 1002 }
		case .Close:
			if !f.fin || len(f.payload) > 125 { cdp_fail_ws(cl, 1002); return 1002 }
			cdp_fail_ws(cl, 1000)
			return 1000
		case:
			cdp_fail_ws(cl, 1002)
			return 1002
		}
		remove_range(&cl.inbuf, 0, consumed)
	}
}

cdp_frame_text :: proc(cl: ^Cdp_Client, s: string) {
	frame := remote.ws_text_frame(s, context.temp_allocator)
	remote.tcp_send(cl.tcp_id, frame)
}
