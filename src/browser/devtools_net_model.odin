package browser

// What the Network tab knows of a tab's requests: one Net_Entry each, filled step by step by the loader's observer
// (fetch/observe.odin) with its headers, its timing, its body (kept up to a limit, while the panel is open) and
// where it came from; the types the filters and the icons use; how the rows sort and filter; and the text forms of a
// request a developer copies (URL, cURL, fetch(), PowerShell).
//
// A request belongs to the tab whose scope it runs in (its navigation's, the page's: they are children of the tab's); a
// new navigation starts the list over unless it is kept. At most `browser.devtools.network.max_entries` are kept per
// tab, dropped from the oldest in batches. The bodies are the memory that can grow: a request keeps at most
// `max_body_kb`, a tab at most `max_body_mb` in all (the oldest bodies go first), and everything goes when the tab is
// closed or the log cleared.

import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:net"

Net_Type :: enum u8 { Doc, JS, CSS, Img, Media, Font, XHR, WS, Wasm, Other }

NET_TYPE_NAMES := [Net_Type]string{.Doc = "Doc", .JS = "JS", .CSS = "CSS", .Img = "Img", .Media = "Media", .Font = "Font", .XHR = "Fetch/XHR", .WS = "WS", .Wasm = "Wasm", .Other = "Other"}
NET_TYPE_LONG := [Net_Type]string{.Doc = "Document", .JS = "Script", .CSS = "Stylesheet", .Img = "Image", .Media = "Media", .Font = "Font", .XHR = "Fetch/XHR", .WS = "WebSocket", .Wasm = "WebAssembly", .Other = "Other"}
NET_TYPE_ICONS := [Net_Type]Dt_Icon{.Doc = .File_Doc, .JS = .File_Script, .CSS = .File_Css, .Img = .File_Image, .Media = .File_Media, .Font = .File_Font, .XHR = .File_Fetch, .WS = .File_Socket, .Wasm = .File_Wasm, .Other = .File_Other}

Net_Entry :: struct {
	id:      u64,
	seq:     int,               // order of arrival, from 1
	method:  string,            // owned
	url:     string,            // owned: the URL the request has now (the final one once it answered)
	dest:    fetch.Destination,
	mode:    fetch.Mode,
	type:    Net_Type,
	status:  int,               // 0 until it answers
	status_text: string,        // owned
	mime:    string,            // owned
	cache:   fetch.Cache_Outcome,
	bytes:   int,               // body bytes received (after decoding)
	transfer: int,              // what went over the wire as far as known: Content-Length, else the bytes
	start_ms: f64,              // when the request began (the loop's clock)
	ms:      f32,               // how long it took (< 0: still going)
	failed:  bool,
	blocked: bool,              // stopped by the user ("Block request URL")
	error:   string,            // owned: why it failed
	req_headers, res_headers: string,   // owned: "Name: value" lines
	req_body: []byte,           // owned
	protocol, remote: string,   // owned
	timing:  net.Timing,
	has_timing: bool,
	initiator: string,          // owned: the URL of the document that asked
	navigate, parser: bool,
	redirects: [dynamic]string, // owned: "301 http://a/ -> http://b/"
	body:    [dynamic]byte,     // kept body (up to the limits)
	body_total: int,            // bytes the body had
	body_cut: bool,             // `body` is not all of it
	time_text: string,          // (cached label)
	// a WebSocket or an event stream: its messages, in order
	is_ws, is_sse: bool,
	msgs:    [dynamic]Net_Msg,
	msgs_total: int,            // all the messages there were (`msgs` keeps the first and last ones within a limit)
	msgs_bytes: i64,            // the text the messages hold
	ws_state: Net_Ws_State,
	ws_code:  int,              // the close code (1005: none was sent)
	ws_reason, ws_sub: string,  // owned: the close reason, the subprotocol chosen
	ws_clean: bool,
	sse:     ^fetch.Sse_Parser, // the stream's parser (an event stream)
}

Net_Ws_State :: enum u8 { Connecting, Open, Closed, Failed }

// One message of a socket or an event of a stream.
Net_Msg :: struct {
	at:      f32,               // ms since the request began
	clock:   i64,               // time of day, ms (what the panel prints)
	out:     bool,              // sent by the page
	binary:  bool,
	control: bool,              // a close frame
	size:    int,               // bytes (of the whole message, which `text` may only start)
	text:    string,            // owned: the text, or the first bytes as hex for a binary message
	name:    string,            // owned: an event stream's event name, or a control frame's text
	id:      string,            // owned: an event stream's last event id
}

NET_MSG_KEEP :: 20000           // messages kept per socket or stream (the oldest go first)
NET_MSG_TEXT :: 1 << 16         // bytes of one message's text kept

Net_Log :: struct {
	entries:  [dynamic]Net_Entry,
	nav:      uintptr,           // the navigation these are the requests of
	bytes:    i64,               // transferred in all
	body_bytes: i64,             // kept in the bodies of the entries
	next_seq: int,
	t0_ms:    f64,               // the loop's clock when the first request of the navigation began
	version:  u64,               // bumped whenever an entry changed (what the view's rows depend on)
	pending:  int,               // requests that have not ended (the status bar's count)
	profile:  string,            // owned: the network speed of this tab (a profile's id); "" = the default (the preference)
	link:     net.Throttle_Link, // what the requests of this tab go through when it is throttled
	link_id:  string,            // owned: the profile `link` was made for
}

NETWORK_PREFS := [?]config.Def{
	{name = "browser.devtools.network.max_entries", kind = .Int, default = {i = 10000}, bounded = true, min = 100, max = 1000000,
		description = "The most requests the Network tab keeps per tab; the oldest go first."},
	{name = "browser.devtools.network.max_body_kb", kind = .Int, default = {i = 8192}, bounded = true, min = 0, max = 2097152, unit = "kB",
		description = "The most of one response the Network tab keeps for its Preview and Response views (0: no bodies are kept)."},
	{name = "browser.devtools.network.max_body_mb", kind = .Int, default = {i = 256}, bounded = true, min = 1, max = 16384, unit = "MB",
		description = "The most the Network tab keeps of the bodies of one tab in all; the oldest bodies are freed first. Closing the tab frees them all."},
	{name = "browser.devtools.network.keep_media", kind = .Bool, default = {b = true},
		description = "Keep the bodies of audio and video responses, up to the limit of one body (for the player of the Preview tab)."},
	{name = "browser.devtools.network.preserve", kind = .Bool, default = {b = false},
		description = "Keep the requests of the Network tab when the page navigates."},
	{name = "browser.devtools.network.disable_cache", kind = .Bool, default = {b = false},
		description = "While the developer tools are open, requests do not use the HTTP cache."},
	{name = "browser.devtools.network.columns", kind = .String, default = {s = "name:260,status:64,type:70,initiator:130,size:76,time:70,waterfall:0"},
		description = "The columns of the Network table, in order, each with its width (CSS pixels; 0 = the room that is left). A column that is not listed is hidden: name, method, status, type, protocol, domain, initiator, cache, size, time, waterfall."},
	{name = "browser.devtools.network.sort", kind = .String, default = {s = ""},
		description = "How the Network table is sorted: a column name, then :asc or :desc (empty: in order of arrival)."},
	{name = "browser.devtools.network.types", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 1023,
		description = "The request types the Network tab shows: a sum of bits (1 doc, 2 js, 4 css, 8 img, 16 media, 32 font, 64 fetch/xhr, 128 ws, 256 wasm, 512 other); 0 shows all."},
	{name = "browser.devtools.network.split", kind = .Float, default = {f = 0.5}, bounded = true, min = 0.15, max = 0.85,
		description = "The share of the Network tab's width (or height) the request list keeps while a request's details are open."},
	{name = "browser.devtools.network.detail_tab", kind = .String, default = {s = "headers"}, choices = {"headers", "payload", "preview", "response", "timing", "cookies", "messages"},
		description = "The view of a request's details that is shown."},
	{name = "browser.devtools.network.waterfall", kind = .Bool, default = {b = true},
		description = "Show the waterfall of each request (its time split into queueing, connecting, waiting and receiving)."},
	{name = "browser.devtools.network.throttle", kind = .String, default = {s = "none"},
		description = "The network speed the developer tools hold the traffic of a tab to (while they are open): none, fast_3g (1.6 Mbit/s, 150 ms), slow_3g (400 kbit/s, 400 ms), flaky (5 Mbit/s, 3 % loss), offline, or the id of a custom profile. A tab that chose another speed keeps its own."},
	{name = "browser.devtools.network.profiles", kind = .String, default = {s = ""},
		description = "The custom network speeds, \"id|name|download kbit/s|upload kbit/s|latency ms|loss %\" separated by semicolons. The Network tab's speed menu edits them."},
}

network_register_prefs :: proc(p: ^config.Prefs) { config.register(p, NETWORK_PREFS[:]) }

Net_Prefs :: struct {
	max_entries: int,
	max_body:    int,     // bytes of one body
	max_total:   i64,     // bytes of all the bodies of a tab
	keep_media:  bool,
	preserve:    bool,
	disable_cache: bool,
	waterfall:   bool,
	profile:     string,   // owned: the id of the speed profile the tabs start from
}

net_prefs: Net_Prefs

network_apply_prefs :: proc(p: ^config.Prefs) {
	old_profile := net_prefs.profile
	net_prefs = {
		max_entries = int(config.int_of(p, "browser.devtools.network.max_entries")),
		max_body = int(config.int_of(p, "browser.devtools.network.max_body_kb")) * 1024,
		max_total = config.int_of(p, "browser.devtools.network.max_body_mb") * 1024 * 1024,
		keep_media = config.bool_of(p, "browser.devtools.network.keep_media"),
		preserve = config.bool_of(p, "browser.devtools.network.preserve"),
		disable_cache = config.bool_of(p, "browser.devtools.network.disable_cache"),
		waterfall = config.bool_of(p, "browser.devtools.network.waterfall"),
	}
	delete(old_profile)
	net_prefs.profile = strings.clone(config.string_of(p, "browser.devtools.network.throttle"))
	net_profiles_load(config.string_of(p, "browser.devtools.network.profiles"))
	network_sync_observer()
}

// The loader passes on pieces of bodies only while the panel is open and keeps are allowed.
network_sync_observer :: proc() {
	if the_app != nil {
		shown := devtools_any_visible(the_app)
		the_app.loader.observer.body_limit = shown && net_prefs.max_body > 0 ? net_prefs.max_body : 0
		the_app.loader.observer.no_cache = shown && net_prefs.disable_cache
	}
}

////////////////////////////////
// Entries

net_free_entry :: proc(e: ^Net_Entry) {
	delete(e.method); delete(e.url); delete(e.mime); delete(e.error); delete(e.status_text)
	delete(e.req_headers); delete(e.res_headers); delete(e.req_body); delete(e.protocol); delete(e.remote); delete(e.initiator)
	for r in e.redirects { delete(r) }
	delete(e.redirects)
	delete(e.body)
	for m in e.msgs { delete(m.text); delete(m.name); delete(m.id) }
	delete(e.msgs)
	delete(e.ws_reason); delete(e.ws_sub)
	if e.sse != nil { fetch.sse_parser_destroy(e.sse); free(e.sse) }
	e^ = {}
}

net_clear :: proc(l: ^Net_Log) {
	for &e in l.entries { net_free_entry(&e) }
	clear(&l.entries)
	l.bytes, l.body_bytes, l.next_seq, l.t0_ms, l.pending = 0, 0, 0, 0, 0
	l.version += 1
}

net_log_destroy :: proc(l: ^Net_Log) {
	net_clear(l)
	delete(l.entries)
	delete(l.profile); delete(l.link_id)
	l^ = {}
}

@(private = "file") net_owner: map[u64]u64   // request id -> id of its tab

// The tab a scope belongs to, and the scope of its navigation (the child of the tab's scope on the way up).
tab_of_scope :: proc(app: ^App, s: ^base.Scope) -> (t: ^Tab, nav: uintptr) {
	for sc := s; sc != nil; sc = sc.parent {
		for x in tabs_all(app) {
			if sc == x.scope { return x, 0 }
			if sc.parent == x.scope { return x, uintptr(sc) }
		}
	}
	return nil, 0
}

@(private = "file")
tab_by_id :: proc(app: ^App, id: u64) -> ^Tab {
	for t in tabs_all(app) { if t.id == id { return t } }
	return nil
}

net_entry_of :: proc(l: ^Net_Log, id: u64) -> ^Net_Entry {
	for i := len(l.entries) - 1; i >= 0; i -= 1 { if l.entries[i].id == id { return &l.entries[i] } }
	return nil
}

net_destroy_owner :: proc() {
	delete(net_owner)
	net_owner = nil
}

// Drops the oldest entries (a batch at a time) once the limit is passed.
@(private = "file")
net_trim :: proc(l: ^Net_Log) {
	limit := max(net_prefs.max_entries, 100)
	if len(l.entries) <= limit + max(limit / 8, 16) { return }
	drop := len(l.entries) - limit
	for &e in l.entries[:drop] {
		if e.ms < 0 { l.pending = max(l.pending - 1, 0) }
		l.body_bytes -= i64(len(e.body))
		net_free_entry(&e)
	}
	remove_range(&l.entries, 0, drop)
}

// The bodies of a tab stay within the total: the oldest are freed first.
@(private = "file")
net_enforce_total :: proc(l: ^Net_Log) {
	if l.body_bytes <= net_prefs.max_total { return }
	for &e in l.entries {
		if len(e.body) == 0 { continue }
		l.body_bytes -= i64(len(e.body))
		delete(e.body)
		e.body = nil
		e.body_cut = true
		if l.body_bytes <= net_prefs.max_total * 3 / 4 { break }
	}
}

// fetch.Observer.event: every step of every request, socket and event stream.
net_observe :: proc(user: rawptr, ev: ^fetch.Observed) {
	app := (^App)(user)
	now_ms := f64(host.now_ns(&app.loop)) / 1e6
	touched: ^Tab
	#partial switch ev.kind {
	case .Started, .Ws_Started:
		t, nav := tab_of_scope(app, ev.scope)
		if t == nil { return }
		touched = t
		if t.net.nav != nav {
			if net_prefs.preserve && len(t.net.entries) > 0 { t.net.nav = nav } else { net_clear(&t.net); t.net.nav = nav }
		}
		if net_owner == nil { net_owner = make(map[u64]u64) }
		net_owner[ev.id] = t.id
		net_trim(&t.net)
		if len(t.net.entries) == 0 { t.net.t0_ms = now_ms }
		t.net.next_seq += 1
		t.net.pending += 1
		append(&t.net.entries, Net_Entry{
			id = ev.id, seq = t.net.next_seq, method = strings.clone(ev.method), url = strings.clone(ev.url), dest = ev.destination, mode = ev.mode,
			start_ms = now_ms, ms = -1, navigate = ev.navigate, parser = ev.parser, initiator = strings.clone(ev.initiator_url),
		})
		e := &t.net.entries[len(t.net.entries) - 1]
		if ev.kind == .Ws_Started {
			e.is_ws, e.type = true, .WS
			e.req_headers = strings.clone(ev.headers)
		} else {
			e.type = net_type_of(e)
		}
	case:
		tid, found := net_owner[ev.id]
		if !found { return }
		t := tab_by_id(app, tid)
		if t == nil { delete_key(&net_owner, ev.id); return }
		e := net_entry_of(&t.net, ev.id)
		if e == nil { delete_key(&net_owner, ev.id); return }
		touched = t
		was_pending := e.ms < 0
		#partial switch ev.kind {
		case .Request:
			delete(e.req_headers)
			e.req_headers = strings.clone(ev.headers)
			if len(ev.request_body) > 0 && e.req_body == nil {
				e.req_body = make([]byte, min(len(ev.request_body), 1 << 20))
				copy(e.req_body, ev.request_body)
			}
			if ev.method != "" && ev.method != e.method { delete(e.method); e.method = strings.clone(ev.method) }
		case .Redirect:
			append(&e.redirects, fmt.aprintf("%d %s -> %s", ev.status, ev.url, ev.detail))
		case .Response:
			e.status, e.cache = ev.status, ev.cache
			if ev.url != "" && ev.url != e.url { delete(e.url); e.url = strings.clone(ev.url) }
			delete(e.mime); e.mime = strings.clone(ev.mime)
			delete(e.res_headers); e.res_headers = strings.clone(ev.headers)
			delete(e.status_text); e.status_text = strings.clone(ev.status_text)
			delete(e.protocol); e.protocol = strings.clone(ev.protocol)
			delete(e.remote); e.remote = strings.clone(ev.remote)
			if ev.has_timing { e.timing, e.has_timing = ev.timing, true }
			e.transfer = content_length_of(ev.headers)
			if net_mime_base(ev.mime) == "text/event-stream" && e.sse == nil {
				e.is_sse = true
				e.sse = new(fetch.Sse_Parser)
				fetch.sse_parser_init(e.sse, 1 << 20)
			}
			e.type = net_type_of(e)
		case .Body:
			if e.is_sse {
				// an event stream keeps its events, not its bytes
				events := make([dynamic]fetch.Sse_Event, context.temp_allocator)
				fetch.sse_feed(e.sse, ev.data, &events)
				for se in events { net_msg_push(e, now_ms, false, false, false, transmute([]byte)se.data, se.type, se.last_event_id) }
				e.body_total += len(ev.data)
			} else if net_keep_body(e) {
				room := net_prefs.max_body - len(e.body)
				take := min(room, len(ev.data))
				if take > 0 {
					append(&e.body, ..ev.data[:take])
					t.net.body_bytes += i64(take)
				}
				if take < len(ev.data) { e.body_cut = true }
				e.body_total += len(ev.data)
				net_enforce_total(&t.net)
			} else {
				e.body_total += len(ev.data)
				e.body_cut = true
			}
		case .Done:
			e.bytes = ev.bytes
			e.ms = f32(now_ms - e.start_ms)
			if e.body_total == 0 { e.body_total = ev.bytes }
			if e.transfer <= 0 { e.transfer = ev.bytes }
			if ev.has_timing { e.timing, e.has_timing = ev.timing, true }
			t.net.bytes += i64(e.transfer)
			if was_pending { t.net.pending = max(t.net.pending - 1, 0) }
			delete_key(&net_owner, ev.id)
		case .Failed:
			e.failed, e.ms = true, f32(now_ms - e.start_ms)
			if ev.bytes > e.bytes { e.bytes = ev.bytes }
			delete(e.error)
			e.error = strings.clone(ev.detail != "" ? ev.detail : "failed")
			e.blocked = ev.error == .Blocked_Csp || ev.error == .Blocked_Cors || ev.error == .Blocked_Mixed_Content || ev.error == .Blocked_Same_Origin || ev.error == .Blocked_Preflight || ev.error == .Blocked_By_Client
			if e.is_ws { e.ws_state = .Failed }
			t.net.bytes += i64(ev.bytes)
			if was_pending { t.net.pending = max(t.net.pending - 1, 0) }
			delete_key(&net_owner, ev.id)
		case .Ws_Response:
			e.status = ev.status
			delete(e.res_headers); e.res_headers = strings.clone(ev.headers)
			delete(e.status_text); e.status_text = strings.clone(ev.status == 101 ? "Switching Protocols" : ev.status_text)
			delete(e.ws_sub); e.ws_sub = strings.clone(ev.protocol)
			if ev.status == 101 { e.ws_state = .Open }
		case .Ws_Frame:
			data := ev.data
			name := ev.detail
			net_msg_push(e, now_ms, ev.outgoing, ev.binary, name != "" && len(data) == 0, data, name, "")
			t.net.bytes += i64(len(data))
			e.bytes += len(data)
		case .Ws_Closed:
			e.ws_state, e.ws_code, e.ws_clean = .Closed, ev.status, ev.clean
			delete(e.ws_reason); e.ws_reason = strings.clone(ev.detail)
			e.ms = f32(now_ms - e.start_ms)
			if was_pending { t.net.pending = max(t.net.pending - 1, 0) }
			delete_key(&net_owner, ev.id)
		}
	}
	// whatever the event was, the rows of that tab are made again, and a frame shows it
	if touched != nil { touched.net.version += 1 }
	if touched != nil && touched == current_tab(app) { request_frames(app, 2) }
	devtools_request_showing(app, touched, .Network)
	devtools_request_showing(app, nil, .Performance)
}

// A message of a socket, or an event of a stream, into the entry's list.
net_msg_push :: proc(e: ^Net_Entry, now_ms: f64, out, binary, control: bool, data: []byte, name, id: string) {
	m := Net_Msg{at = f32(now_ms - e.start_ms), clock = local_time_ms(), out = out, binary = binary, control = control, size = len(data), name = strings.clone(name), id = strings.clone(id)}
	n := min(len(data), binary ? 512 : NET_MSG_TEXT)
	if binary {
		b := strings.builder_make()
		for byte, i in data[:n] { fmt.sbprintf(&b, "%s%02x", i > 0 ? " " : "", byte) }
		m.text = strings.to_string(b)
	} else {
		end := n
		for end > 0 && end < len(data) && (data[end] & 0xC0) == 0x80 { end -= 1 }   // not in the middle of a character
		m.text = strings.clone(string(data[:end]))
	}
	e.msgs_bytes += i64(len(m.text))
	e.msgs_total += 1
	if len(e.msgs) >= NET_MSG_KEEP {
		drop := NET_MSG_KEEP / 8
		for &d in e.msgs[:drop] { e.msgs_bytes -= i64(len(d.text)); delete(d.text); delete(d.name); delete(d.id) }
		remove_range(&e.msgs, 0, drop)
	}
	append(&e.msgs, m)
}
@(private = "file")
net_keep_body :: proc(e: ^Net_Entry) -> bool {
	if net_prefs.max_body <= 0 { return false }
	if !net_prefs.keep_media && (e.dest == .Audio || e.dest == .Video || strings.has_prefix(e.mime, "audio/") || strings.has_prefix(e.mime, "video/")) { return false }
	return true
}

// "Content-Length" of a header block (0 when there is none).
content_length_of :: proc(headers: string) -> int {
	v := net_header(headers, "content-length")
	n := 0
	for c in transmute([]u8)v {
		if c < '0' || c > '9' { break }
		n = n * 10 + int(c - '0')
		if n > 1 << 40 { break }
	}
	return n
}

// The value of header `name` (lower case) in a block of "Name: value" lines; "" when absent.
net_header :: proc(block: string, name: string) -> string {
	rest := block
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		ln := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end + 1:]
		ln = strings.trim_right(ln, "\r")
		colon := strings.index_byte(ln, ':')
		if colon <= 0 || colon != len(name) { continue }
		if strings.equal_fold(ln[:colon], name) { return strings.trim_space(ln[colon + 1:]) }
	}
	return ""
}

// The lines of a header block as (name, value) pairs (memory of the temporary allocator).
net_header_pairs :: proc(block: string) -> [][2]string {
	out := make([dynamic][2]string, 0, 16, context.temp_allocator)
	rest := block
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		ln := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end + 1:]
		ln = strings.trim_right(ln, "\r")
		colon := strings.index_byte(ln, ':')
		if colon <= 0 { continue }
		append(&out, [2]string{ln[:colon], strings.trim_space(ln[colon + 1:])})
	}
	return out[:]
}

////////////////////////////////
// Types, names, statuses

net_mime_base :: proc(mime: string) -> string {
	m := mime
	if i := strings.index_byte(m, ';'); i >= 0 { m = m[:i] }
	return strings.trim_space(m)
}

net_type_of :: proc(e: ^Net_Entry) -> Net_Type {
	if e.is_ws { return .WS }
	m := net_mime_base(e.mime)
	switch e.dest {
	case .Document, .Iframe, .Frame: return .Doc
	case .Script, .Worker:   return m == "application/wasm" ? .Wasm : .JS
	case .Style:             return .CSS
	case .Image:             return .Img
	case .Font:              return .Font
	case .Audio, .Video:     return .Media
	case .Manifest, .Report: return .Other
	case .Empty:
	}
	switch {
	case m == "application/wasm": return .Wasm
	case strings.has_prefix(m, "image/"): return .Img
	case strings.has_prefix(m, "audio/") || strings.has_prefix(m, "video/"): return .Media
	case strings.has_prefix(m, "font/") || strings.has_suffix(m, "font-woff") || strings.has_suffix(m, "font-woff2") || strings.has_suffix(m, "vnd.ms-fontobject"): return .Font
	case m == "text/css": return .CSS
	case m == "text/html" && e.navigate: return .Doc
	case strings.has_suffix(m, "javascript") || strings.has_suffix(m, "ecmascript"): return .JS
	}
	if e.dest == .Empty { return .XHR }
	return .Other
}

// What the row calls the request: the last part of its path (or the host for the root), with the query.
net_name_of :: proc(url: string) -> string {
	s := url
	if strings.has_prefix(url, "data:") { return "data:" }
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] }
	slash := strings.index_byte(s, '/')
	if slash < 0 || slash == len(s) - 1 { return slash < 0 ? s : s[:slash] }
	rest := s[slash + 1:]
	trimmed := rest
	if trimmed[len(trimmed) - 1] == '/' { trimmed = trimmed[:len(trimmed) - 1] }
	if i := strings.last_index_byte(trimmed, '/'); i >= 0 { trimmed = trimmed[i + 1:] }
	if trimmed == "" { return rest }
	return trimmed
}

// "host" of a URL ("" for data: and the like).
net_host_of :: proc(url: string) -> string {
	i := strings.index(url, "://")
	if i < 0 { return "" }
	s := url[i + 3:]
	if j := strings.index_any(s, "/?#"); j >= 0 { s = s[:j] }
	if at := strings.last_index_byte(s, '@'); at >= 0 { s = s[at + 1:] }
	return s
}

// "/path/to/file?query" of a URL.
net_path_of :: proc(url: string) -> string {
	i := strings.index(url, "://")
	if i < 0 { return url }
	s := url[i + 3:]
	j := strings.index_any(s, "/?#")
	if j < 0 { return "/" }
	return s[j:]
}

Net_Tone :: enum u8 { Pending, Ok, Redirect, Client, Server, Failed, Blocked, Cached }

net_tone :: proc(e: ^Net_Entry) -> Net_Tone {
	switch {
	case e.blocked: return .Blocked
	case e.failed: return .Failed
	case e.status == 0: return e.ms < 0 ? .Pending : .Ok
	case e.status >= 500: return .Server
	case e.status >= 400: return .Client
	case e.status >= 300: return .Redirect
	}
	return .Ok
}

net_status_text :: proc(e: ^Net_Entry) -> string {
	switch {
	case e.blocked: return "(blocked)"
	case e.failed: return "(failed)"
	case e.status == 0: return e.ms >= 0 ? "(opaque)" : "(pending)"
	}
	return fmt.tprintf("%d", e.status)
}

// The text of a size column cell: "(memory cache)" for what came from the cache, else the transfer.
net_size_text :: proc(e: ^Net_Entry) -> string {
	if e.ms < 0 && e.bytes == 0 { return "" }
	#partial switch e.cache {
	case .Hit, .Stale: return "(cache)"
	case .Revalidated: return "(304)"
	}
	return dt_size_text(i64(e.transfer > 0 ? e.transfer : e.bytes))
}

////////////////////////////////
// Rows: filtering and sorting

Net_Col :: enum u8 { Name, Method, Status, Type, Protocol, Domain, Initiator, Cache, Size, Time, Waterfall }

NET_COL_NAMES := [Net_Col]string{.Name = "name", .Method = "method", .Status = "status", .Type = "type", .Protocol = "protocol", .Domain = "domain", .Initiator = "initiator", .Cache = "cache", .Size = "size", .Time = "time", .Waterfall = "waterfall"}
NET_COL_TITLES := [Net_Col]string{.Name = "Name", .Method = "Method", .Status = "Status", .Type = "Type", .Protocol = "Protocol", .Domain = "Domain", .Initiator = "Initiator", .Cache = "Cache", .Size = "Size", .Time = "Time", .Waterfall = "Waterfall"}

net_col_less :: proc(a, b: ^Net_Entry, col: Net_Col) -> int {
	cmp :: proc(x, y: $T) -> int { return x < y ? -1 : (x > y ? 1 : 0) }
	switch col {
	case .Name:     return cmp(strings.to_lower(net_name_of(a.url), context.temp_allocator), strings.to_lower(net_name_of(b.url), context.temp_allocator))
	case .Method:   return cmp(a.method, b.method)
	case .Status:   return cmp(a.status, b.status)
	case .Type:     return cmp(int(a.type), int(b.type))
	case .Protocol: return cmp(a.protocol, b.protocol)
	case .Domain:   return cmp(net_host_of(a.url), net_host_of(b.url))
	case .Initiator: return cmp(a.initiator, b.initiator)
	case .Cache:    return cmp(int(a.cache), int(b.cache))
	case .Size:     return cmp(a.transfer > 0 ? a.transfer : a.bytes, b.transfer > 0 ? b.transfer : b.bytes)
	case .Time:     return cmp(a.ms, b.ms)
	case .Waterfall: return cmp(a.start_ms, b.start_ms)
	}
	return 0
}

// Sorts row indices of `entries` by a column (stable: ties keep the order of arrival).
net_sort :: proc(rows: []int, entries: []Net_Entry, col: Net_Col, descending: bool) {
	Ctx :: struct { entries: []Net_Entry, col: Net_Col, desc: bool }
	ctx := Ctx{entries, col, descending}
	context.user_ptr = &ctx
	slice.stable_sort_by(rows, proc(a, b: int) -> bool {
		c := (^Ctx)(context.user_ptr)
		r := net_col_less(&c.entries[a], &c.entries[b], c.col)
		if r == 0 { return a < b }
		return c.desc ? r > 0 : r < 0
	})
}

////////////////////////////////
// What a developer copies

net_shell_quote :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '\'')
	for c in transmute([]u8)s {
		if c == '\'' { strings.write_string(&b, "'\\''") } else { strings.write_byte(&b, c) }
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

@(private = "file")
net_skip_header :: proc(name: string) -> bool {
	l := strings.to_lower(name, context.temp_allocator)
	switch l {
	case "host", "content-length", "connection", "accept-encoding", "sec-fetch-dest", "sec-fetch-mode", "sec-fetch-site", "sec-fetch-user": return true
	}
	return false
}

// `curl 'url' -H 'Name: value' --data-raw '...'` (bash).
net_curl :: proc(e: ^Net_Entry, windows := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	q :: proc(s: string, windows: bool) -> string {
		if !windows { return net_shell_quote(s) }
		r, _ := strings.replace_all(s, "\"", "\\\"", context.temp_allocator)
		r, _ = strings.replace_all(r, "%", "%%", context.temp_allocator)
		return strings.concatenate({"\"", r, "\""}, context.temp_allocator)
	}
	nl := windows ? " ^\n  " : " \\\n  "
	fmt.sbprintf(&b, "curl %s", q(e.url, windows))
	if e.method != "GET" && e.method != "HEAD" && len(e.req_body) == 0 { fmt.sbprintf(&b, " -X %s", e.method) }
	if e.method == "HEAD" { strings.write_string(&b, " -I") }
	for h in net_header_pairs(e.req_headers) {
		if net_skip_header(h[0]) { continue }
		fmt.sbprintf(&b, "%s-H %s", nl, q(fmt.tprintf("%s: %s", h[0], h[1]), windows))
	}
	if len(e.req_body) > 0 { fmt.sbprintf(&b, "%s--data-raw %s", nl, q(string(e.req_body), windows)) }
	strings.write_string(&b, nl)
	strings.write_string(&b, "--compressed")
	return strings.to_string(b)
}

// `fetch("url", { ... })` as a developer pastes it into a console.
net_fetch_code :: proc(e: ^Net_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	js :: proc(s: string) -> string {
		r := strings.builder_make(context.temp_allocator)
		strings.write_byte(&r, '"')
		for c in transmute([]u8)s {
			switch c {
			case '"': strings.write_string(&r, "\\\"")
			case '\\': strings.write_string(&r, "\\\\")
			case '\n': strings.write_string(&r, "\\n")
			case '\r': strings.write_string(&r, "\\r")
			case '\t': strings.write_string(&r, "\\t")
			case: strings.write_byte(&r, c)
			}
		}
		strings.write_byte(&r, '"')
		return strings.to_string(r)
	}
	fmt.sbprintf(&b, "fetch(%s, {{\n  \"method\": %s", js(e.url), js(e.method))
	hs := net_header_pairs(e.req_headers)
	n := 0
	for h in hs { if !net_skip_header(h[0]) { n += 1 } }
	if n > 0 {
		strings.write_string(&b, ",\n  \"headers\": {")
		i := 0
		for h in hs {
			if net_skip_header(h[0]) { continue }
			fmt.sbprintf(&b, "%s\n    %s: %s", i > 0 ? "," : "", js(h[0]), js(h[1]))
			i += 1
		}
		strings.write_string(&b, "\n  }")
	}
	if len(e.req_body) > 0 { fmt.sbprintf(&b, ",\n  \"body\": %s", js(string(e.req_body))) }
	strings.write_string(&b, "\n});")
	return strings.to_string(b)
}

// `Invoke-WebRequest` for PowerShell.
net_powershell :: proc(e: ^Net_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	ps :: proc(s: string) -> string {
		r, _ := strings.replace_all(s, "'", "''", context.temp_allocator)
		return strings.concatenate({"'", r, "'"}, context.temp_allocator)
	}
	fmt.sbprintf(&b, "Invoke-WebRequest -UseBasicParsing -Uri %s", ps(e.url))
	if e.method != "GET" { fmt.sbprintf(&b, " `\n  -Method %s", e.method) }
	hs := net_header_pairs(e.req_headers)
	n := 0
	for h in hs { if !net_skip_header(h[0]) { n += 1 } }
	if n > 0 {
		strings.write_string(&b, " `\n  -Headers @{")
		i := 0
		for h in hs {
			if net_skip_header(h[0]) { continue }
			fmt.sbprintf(&b, "%s\n    %s = %s", i > 0 ? ";" : "", ps(h[0]), ps(h[1]))
			i += 1
		}
		strings.write_string(&b, "\n  }")
	}
	if len(e.req_body) > 0 { fmt.sbprintf(&b, " `\n  -Body %s", ps(string(e.req_body))) }
	return strings.to_string(b)
}

// The whole log as HAR 1.2 (what other tools import), for "Save all as HAR".
net_har :: proc(t: ^Tab) -> string {
	b := strings.builder_make(context.temp_allocator)
	esc :: proc(s: string) -> string {
		r := strings.builder_make(context.temp_allocator)
		for c in transmute([]u8)s {
			switch c {
			case '"': strings.write_string(&r, "\\\"")
			case '\\': strings.write_string(&r, "\\\\")
			case '\n': strings.write_string(&r, "\\n")
			case '\r': strings.write_string(&r, "\\r")
			case '\t': strings.write_string(&r, "\\t")
			case: if c < 0x20 { fmt.sbprintf(&r, "\\u%04x", c) } else { strings.write_byte(&r, c) }
			}
		}
		return strings.to_string(r)
	}
	headers :: proc(b: ^strings.Builder, block: string) {
		strings.write_string(b, "[")
		for h, i in net_header_pairs(block) {
			fmt.sbprintf(b, "%s{{\"name\":\"%s\",\"value\":\"%s\"}}", i > 0 ? "," : "", esc(h[0]), esc(h[1]))
		}
		strings.write_string(b, "]")
	}
	fmt.sbprintf(&b, "{{\"log\":{{\"version\":\"1.2\",\"creator\":{{\"name\":\"%s\",\"version\":\"%s\"}},\"pages\":[],\"entries\":[", APP_NAME, APP_VERSION_SHOWN)
	for &e, i in t.net.entries {
		if i > 0 { strings.write_string(&b, ",") }
		fmt.sbprintf(&b, "{{\"startedDateTime\":\"1970-01-01T00:00:00.000Z\",\"time\":%.2f,\"request\":{{\"method\":\"%s\",\"url\":\"%s\",\"httpVersion\":\"%s\",\"headers\":", max(e.ms, 0), esc(e.method), esc(e.url), esc(e.protocol == "" ? "http/1.1" : e.protocol))
		headers(&b, e.req_headers)
		fmt.sbprintf(&b, ",\"queryString\":[],\"cookies\":[],\"headersSize\":-1,\"bodySize\":%d}}", len(e.req_body))
		fmt.sbprintf(&b, ",\"response\":{{\"status\":%d,\"statusText\":\"%s\",\"httpVersion\":\"%s\",\"headers\":", e.status, esc(e.status_text), esc(e.protocol == "" ? "http/1.1" : e.protocol))
		headers(&b, e.res_headers)
		fmt.sbprintf(&b, ",\"cookies\":[],\"content\":{{\"size\":%d,\"mimeType\":\"%s\"}},\"redirectURL\":\"\",\"headersSize\":-1,\"bodySize\":%d}}", e.bytes, esc(e.mime), e.transfer)
		strings.write_string(&b, ",\"cache\":{},\"timings\":{\"send\":0,\"wait\":0,\"receive\":0}}")
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// "/path?a=1&b=2" -> the pairs of the query (decoded), for the Headers view.
net_query_pairs :: proc(url: string) -> [][2]string {
	out := make([dynamic][2]string, 0, 8, context.temp_allocator)
	q := strings.index_byte(url, '?')
	if q < 0 { return out[:] }
	s := url[q + 1:]
	if h := strings.index_byte(s, '#'); h >= 0 { s = s[:h] }
	for part in strings.split(s, "&", context.temp_allocator) {
		if part == "" { continue }
		eq := strings.index_byte(part, '=')
		k, v := part, ""
		if eq >= 0 { k, v = part[:eq], part[eq + 1:] }
		append(&out, [2]string{url_decode(k), url_decode(v)})
	}
	return out[:]
}

url_decode :: proc(s: string) -> string {
	if !strings.contains_any(s, "%+") { return s }
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '+' { strings.write_byte(&b, ' '); i += 1; continue }
		if c == '%' && i + 2 < len(s) {
			h, ok1 := hex_val(s[i + 1])
			l, ok2 := hex_val(s[i + 2])
			if ok1 && ok2 { strings.write_byte(&b, u8(h * 16 + l)); i += 3; continue }
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
hex_val :: proc(c: u8) -> (int, bool) {
	switch {
	case c >= '0' && c <= '9': return int(c - '0'), true
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10, true
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10, true
	}
	return 0, false
}
