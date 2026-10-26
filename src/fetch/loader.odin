package fetch

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:csp"
import "wb:host"
import "wb:http"
import "wb:net"
import "wb:url"

Loader :: struct {
	loop:     ^host.Loop,
	net:      ^net.Client,
	blocking: ^host.Blocking_Pool,
	profile:  ^Profile,
	tasks:    base.Pool(Task),
	revalidations: [dynamic]^Revalidation,   // stale-while-revalidate refreshes in flight (http_cache.odin)
	observer: Observer,   // the developer tools' view of every request (observe.odin)
	observers: [dynamic]Observer,   // more of them: the pages' timelines (observer_add)
	interceptor: Interceptor,   // the content blocker (intercept.odin)
	next_obs: u64,
	ws_ctx:   map[base.Handle]^Ws_Ctx,   // the open sockets, by handle (websocket.odin)
	hold:     bool,                 // the interceptor is not ready: http(s) requests wait in `held` (hold_requests)
	held:     [dynamic]base.Handle, // the tasks waiting for hold to end, in the order they were made
}

// While `on`, requests to the network are parked before the interceptor sees them; when it ends they start, in order. The content
// blocker uses it while its filter index is being compiled (a request let through before would escape every rule). A task cancelled
// meanwhile is simply gone when its turn comes.
hold_requests :: proc(l: ^Loader, on: bool) {
	if l == nil || l.hold == on { return }
	l.hold = on
	if on { return }
	for h in l.held { host.post(l.loop, kick, new_clone(Kick{l, h})) }
	clear(&l.held)
}

loader_init :: proc(l: ^Loader, loop: ^host.Loop, client: ^net.Client, blocking: ^host.Blocking_Pool, profile: ^Profile) {
	l.loop, l.net, l.blocking, l.profile = loop, client, blocking, profile
}

loader_destroy :: proc(l: ^Loader) {
	it: u32
	handles := make([dynamic]base.Handle, context.temp_allocator)
	for h, _ in base.pool_next(&l.tasks, &it) { append(&handles, h) }
	for h in handles { release(l, h) }
	base.pool_destroy(&l.tasks)
	revalidations_destroy(l)
	delete(l.observers)
	delete(l.held)
	delete(l.ws_ctx)
	l.ws_ctx = nil
}

in_flight :: proc(l: ^Loader) -> int { return l.tasks.count }

Stage :: enum u8 { Created, Preflight, Fetching, Local }

Task :: struct {
	loader:   ^Loader,
	self:     base.Handle,

	// the request, owned
	target:          url.URL,   // the current URL of the request (changes on redirects)
	method:          string,
	headers:         http.Headers,
	body:            []byte,
	mode:            Mode,
	credentials:     Credentials,
	redirect:        Redirect_Mode,
	destination:     Destination,
	referrer_policy: Referrer_Policy,
	no_referrer:     bool,
	user_activation: bool,
	initiator:       ^Environment,
	nonce:           string,
	script:          Script_Type,
	parser_inserted: bool,
	origin:          url.Origin,    // the request origin; becomes opaque once a cross-origin redirect tainted it
	max_body:        int,
	early_error:     Error_Kind,    // a validation failure found at start, reported from the loop

	// state
	cors_flag:       bool,
	taint:           Response_Type,
	redirect_count:  int,
	redirected:      bool,
	cross_site_seen: bool,
	stage:           Stage,
	net_req:         base.Handle,
	net_user:        rawptr,        // what net_req's callback owns (^Kick or ^Preflight, after stage): freed if it is cancelled
	status:          int,
	raw_headers:     http.Headers,
	has_raw:         bool,

	// delivery
	on_event:  Event_Proc,
	user:      rawptr,
	scope:     ^base.Scope,
	cleanup:   base.Cleanup_Id,
	collect:   bool,
	collected: [dynamic]byte,

	cache:     Task_Cache,      // the HTTP cache's view of the request (http_cache.odin)
	filter:    Body_Filter,     // the interceptor's rewrite of the body (intercept.odin)
	filtered:  [dynamic]byte,   // what the filter produced for the chunk in hand

	obs_id:    u64,             // observe.odin
	obs_bytes: int,
	obs_done:  bool,           // a Done or Failed was reported
	obs_timing: net.Timing,    // what the network layer measured (the last hop)
	obs_proto: u8,
	obs_remote: [48]u8,
	obs_remote_len: u8,
	obs_status: [64]u8,        // the reason phrase of the answer
	obs_status_len: u8,
	obs_net:   bool,           // the answer came over the network (obs_timing and the others are set)
	ping:      bool,
	rewritten: bool,           // the interceptor changed the URL
	skip_service_worker: bool, // no service worker may answer (Request service-workers mode "none", or it fell back)
}

////////////////////////////////
// Starting

@(private)
Kick :: struct { l: ^Loader, h: base.Handle }

// Starts a fetch. Never calls back synchronously. The initiator Environment (if any) must outlive the task: register
// both in the same scope, environment first.
start :: proc(l: ^Loader, d: Start_Desc) -> base.Handle {
	r := d.request
	t := Task{
		loader = l, mode = r.mode, credentials = r.credentials, redirect = r.redirect, destination = r.destination,
		referrer_policy = r.referrer_policy, no_referrer = r.no_referrer, user_activation = r.user_activation,
		initiator = r.initiator, max_body = r.max_body, on_event = d.on_event, user = d.user, scope = d.scope, collect = d.collect,
		script = r.script, parser_inserted = r.parser_inserted, ping = r.ping, skip_service_worker = r.skip_service_worker,
	}
	t.headers = http.headers_make()
	t.raw_headers = http.headers_make()
	t.nonce = strings.clone(r.nonce)
	t.method = http.normalize_method(r.method == "" ? "GET" : r.method)

	u, ok := url.parse_absolute(r.url)
	if ok { t.target = u } else { t.early_error = .Bad_URL }
	if ok && l.observer.block != nil && l.observer.block(l.observer.user, t.scope, t.target.href) { t.early_error = .Blocked_By_Client }
	if t.early_error == .None {
		switch {
		case !http.is_token(t.method) || http.is_forbidden_method(t.method): t.early_error = .Bad_Method
		case (t.method == "GET" || t.method == "HEAD") && len(r.body) > 0:     t.early_error = .Bad_Method
		}
	}
	if t.early_error == .None {
		for p in r.headers {
			if !http.is_token(p.name) || !http.is_valid_header_value(p.value) { t.early_error = .Bad_Header; break }
			if r.guard == .Request && http.is_forbidden_request_header(p.name, p.value) { continue }   // silently ignored, as in browsers
			http.append_header(&t.headers, p.name, p.value)
		}
	}
	if len(r.body) > 0 { t.body = make([]byte, len(r.body)); copy(t.body, r.body) }
	cache_task_init(&t, r)
	if r.initiator != nil { t.origin = url.origin_clone(r.initiator.origin) } else { t.origin = url.new_opaque_origin() }

	h, tp := base.pool_insert(&l.tasks, t)
	tp.self = h
	l.next_obs += 1
	tp.obs_id = l.next_obs
	if observing(l) {
		init_url := r.initiator != nil ? r.initiator.location.href : ""
		observe(tp, Observed{kind = .Started, scope = d.scope, initiator = r.initiator, method = tp.method, url = ok ? tp.target.href : r.url, destination = r.destination, mode = r.mode,
			navigate = r.mode == .Navigate, parser = r.parser_inserted, initiator_url = init_url})
	}
	if d.scope != nil { tp.cleanup = base.on_close(d.scope, task_scope_closed, new_clone(Kick{l, h})) }
	host.post(l.loop, kick, new_clone(Kick{l, h}))
	return h
}

@(private)
kick :: proc(data: rawptr) {
	k := (^Kick)(data)
	defer free(k)
	t := base.pool_get(&k.l.tasks, k.h)
	if t == nil { return }
	if t.early_error != .None {
		fail(t, t.early_error, early_detail(t.early_error))
		return
	}
	if k.l.hold && (t.target.scheme == "http" || t.target.scheme == "https") {
		append(&k.l.held, k.h)
		return
	}
	run_hop(t)
}

@(private)
early_detail :: proc(k: Error_Kind) -> string {
	#partial switch k {
	case .Bad_URL: return "invalid URL"
	case .Bad_Method: return "invalid or forbidden method, or a body on GET/HEAD"
	case .Bad_Header: return "invalid header name or value"
	case .Blocked_By_Client: return "blocked by the developer tools"
	}
	return "request rejected"
}

@(private)
task_scope_closed :: proc(data: rawptr) {
	k := (^Kick)(data)
	release(k.l, k.h)
	free(k)
}

// Silent. False if the task already finished (or there is no loader: a worker's requests are made by its page).
cancel :: proc(l: ^Loader, h: base.Handle) -> bool { return l != nil && release(l, h) }

@(private)
release :: proc(l: ^Loader, h: base.Handle) -> bool {
	t, ok := base.pool_remove(&l.tasks, h)
	if !ok { return false }
	if !t.obs_done && observing(l) { t.obs_done = true; observe(&t, Observed{kind = .Failed, error = .Aborted, detail = "cancelled", bytes = t.obs_bytes}) }
	cancel_net(l, &t)
	cache_task_release(l, &t)
	url.destroy(&t.target)
	url.origin_destroy(&t.origin)
	http.headers_destroy(&t.headers)
	http.headers_destroy(&t.raw_headers)
	delete(t.method)
	delete(t.nonce)
	delete(t.body)
	delete(t.collected)
	delete(t.filtered)
	if t.filter.destroy != nil { t.filter.destroy(t.filter.user) }
	if t.scope != nil { base.run_cleanup(t.scope, t.cleanup) }
	return true
}

// Cancels the task's network request (silent: its callback is not called again) and frees what that callback owned.
@(private)
cancel_net :: proc(l: ^Loader, t: ^Task) {
	if t.net_req == base.NIL_HANDLE { return }
	net.cancel(l.net, t.net_req)
	t.net_req = base.NIL_HANDLE
	#partial switch t.stage {
	case .Preflight: if t.net_user != nil { free_preflight((^Preflight)(t.net_user)) }
	case .Fetching:  free(t.net_user)
	}
	t.net_user = nil
}

@(private)
deliver :: proc(t: ^Task, ev: ^Event) {
	if observing(t.loader) && !t.obs_done {
		switch ev.kind {
		case .Response:
			if r := ev.response; r != nil {
				mime := r.has_mime ? http.mime_essence(r.mime) : ""
				o := Observed{kind = .Response, url = r.url, destination = t.destination, status = r.status, mime = mime, cache = r.cache, redirected = r.redirected, redirects = t.redirect_count}
				// the answer as it came (the page may see less of it: a no-cors response has no headers for it)
				if len(t.raw_headers.list) > 0 { o.headers = join_headers(t.raw_headers) }
				if t.obs_net {
					o.protocol, o.remote, o.status_text = protocol_name(t.obs_proto), string(t.obs_remote[:t.obs_remote_len]), string(t.obs_status[:t.obs_status_len])
					o.timing, o.has_timing = t.obs_timing, true
				} else if t.status > 0 { o.status_text = string(t.obs_status[:t.obs_status_len]) }
				if r.status == 0 { o.status = t.status }
				observe(t, o)
			}
		case .Data:
			t.obs_bytes += len(ev.data)
			if t.loader.observer.body_limit > 0 { observe(t, Observed{kind = .Body, data = ev.data}) }
		case .Done:
			t.obs_done = true
			if t.collect && t.loader.observer.body_limit > 0 && len(ev.data) > 0 { observe(t, Observed{kind = .Body, data = ev.data}) }
			observe(t, Observed{kind = .Done, bytes = t.collect ? len(ev.data) : t.obs_bytes, timing = t.obs_timing, has_timing = t.obs_net})
		case .Failed:
			t.obs_done = true
			observe(t, Observed{kind = .Failed, error = ev.error, detail = ev.detail, bytes = t.obs_bytes, blocked_by = ev.error == .Blocked_By_Client ? ev.detail : ""})
		}
	}
	if t.on_event != nil { t.on_event(t.user, t.self, ev) }
}

@(private)
fail :: proc(t: ^Task, kind: Error_Kind, detail: string, net_code: u32 = 0, net_flags: u32 = 0) {
	ev := Event{kind = .Failed, error = kind, detail = detail, net_code = net_code, net_flags = net_flags}
	h := t.self
	l := t.loader
	deliver(t, &ev)
	release(l, h)
}

////////////////////////////////
// One hop

// Everything that happens for the current URL of the task; called again after each redirect.
@(private)
run_hop :: proc(t: ^Task) {
	l := t.loader
	// track whether any URL of the chain is cross-site with the initiator (SameSite cookies)
	if t.initiator != nil {
		o := url.origin_of(t.target, context.temp_allocator)
		s := url.site_of(o, context.temp_allocator)
		if !url.same_site(s, t.initiator.top_level_site) { t.cross_site_seen = true }
	}
	if !intercept_hop(t) { return }
	if !content_security_check(t) { return }
	if sw_takes(t) { return }   // service_worker.odin: a service worker answers (zero cost while none can)
	switch t.target.scheme {
	case "http", "https": http_hop(t)
	case "data":          data_hop(t)
	case "file":          file_hop(t)
	case "about":
		if t.target.href == "about:blank" { synthetic(t, 200, "text/html;charset=utf-8", nil); return }
		fail(t, .Bad_Scheme, "unsupported about: URL")
	case:
		fail(t, .Bad_Scheme, fmt.tprintf("unsupported scheme %q", t.target.scheme))
	}
	_ = l
}

// Ports that must never be contacted (Fetch Standard "bad port"): other protocols live there.
@(private)
is_bad_port :: proc(p: int, s: ^Settings) -> bool {
	for a in s.bad_ports_allowed { if a == p { return false } }
	for b in s.bad_ports_blocked { if b == p { return true } }
	switch p {
	case 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102, 103, 104, 109, 110, 111,
	     113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532, 540, 548,
	     554, 556, 563, 587, 601, 636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566,
	     6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080:
		return true
	}
	return false
}

@(private)
http_hop :: proc(t: ^Task) {
	l := t.loader
	p := l.profile
	now := now_ms()

	if is_bad_port(url.effective_port(t.target), &p.settings) { fail(t, .Bad_Port, fmt.tprintf("port %d is blocked", url.effective_port(t.target))); return }
	if (t.target.username != "" || t.target.password != "") && (t.mode == .Cors || t.mode == .Same_Origin) {
		fail(t, .Credentials_In_URL, "URLs with credentials are not allowed for this request"); return
	}

	// HSTS: upgrade before anything is sent
	if t.target.scheme == "http" && p.settings.hsts && hsts_should_upgrade(&l.profile.hsts, t.target.host, now) {
		if up, ok := upgrade_to_https(t.target); ok { url.destroy(&t.target); t.target = up }
	}

	// mixed content: a secure document must not load insecure subresources
	if t.initiator != nil && t.initiator.location.scheme == "https" && t.destination != .Document && !url.is_potentially_trustworthy(t.target) {
		#partial switch t.destination {
		case .Image, .Audio, .Video:   // optionally blockable: upgraded, unless the configuration says otherwise
			if p.settings.upgrade_passive_mixed {
				if up, ok := upgrade_to_https(t.target); ok { url.destroy(&t.target); t.target = up } else { fail(t, .Blocked_Mixed_Content, "mixed content"); return }
			} else {
				fail(t, .Blocked_Mixed_Content, fmt.tprintf("blocked insecure request to %s from a secure document", t.target.href)); return
			}
		case:
			if p.settings.block_active_mixed {
				fail(t, .Blocked_Mixed_Content, fmt.tprintf("blocked insecure request to %s from a secure document", t.target.href)); return
			}
		}
	}

	// same-origin / CORS classification
	target_origin := url.origin_of(t.target, context.temp_allocator)
	same := url.same_origin(t.origin, target_origin)
	t.cors_flag = false
	switch t.mode {
	case .Navigate:    t.taint = .Basic
	case .Same_Origin:
		if !same { fail(t, .Blocked_Same_Origin, "cross-origin request in same-origin mode"); return }
		t.taint = .Basic
	case .No_Cors:
		t.taint = same ? .Basic : .Opaque
	case .Cors:
		t.cors_flag = !same
		t.taint = same ? .Basic : .Cors
	}
	if t.mode == .No_Cors { restrict_no_cors_headers(t) }

	// preflight when the request is not "simple"
	if t.cors_flag {
		unsafe := http.unsafe_request_header_names(t.headers)
		if !http.is_safelisted_method(t.method) || len(unsafe) > 0 {
			ser := url.origin_serialize(t.origin, context.temp_allocator)
			creds := credentials_include(t)
			if !preflight_cache_allows(&p.preflights, ser, url_no_fragment(t.target), creds, t.method, unsafe, now) {
				send_preflight(t, unsafe)
				return
			}
		}
	}
	send_main(t)
}

@(private)
url_no_fragment :: proc(u: url.URL) -> string { return url.without_fragment(u) }

// no-cors requests may only carry CORS-safelisted headers and methods.
@(private)
restrict_no_cors_headers :: proc(t: ^Task) {
	for i := len(t.headers.list) - 1; i >= 0; i -= 1 {
		e := t.headers.list[i]
		if !http.is_cors_safelisted_request_header(e.name, e.value) {
			delete(e.name); delete(e.value)
			ordered_remove(&t.headers.list, i)
		}
	}
}

@(private)
credentials_include :: proc(t: ^Task) -> bool { return t.credentials == .Include }

// May cookies travel with / be stored from this request?
@(private)
cookies_allowed :: proc(t: ^Task) -> bool {
	include := t.credentials == .Include || (t.credentials == .Same_Origin && t.taint == .Basic)
	if !include { return false }
	// a nested document's navigation is a third-party request like a subresource's (only top-level navigations are not)
	if (t.mode != .Navigate || is_frame_destination(t.destination)) && t.initiator != nil && t.loader.profile.settings.third_party_cookies == .Block {
		o := url.origin_of(t.target, context.temp_allocator)
		if !url.same_site(url.site_of(o, context.temp_allocator), t.initiator.top_level_site) { return false }
	}
	return true
}

@(private)
site_context :: proc(t: ^Task) -> cookies.Site_Context {
	if t.initiator == nil { return .Same_Site }   // typed in the address bar
	if !t.cross_site_seen { return .Same_Site }
	// (SameSite=Lax cookies go with top-level navigations only, not with a cross-site <iframe>'s)
	if t.mode == .Navigate && !is_frame_destination(t.destination) && http.is_safe_method(t.method) { return .Cross_Site_Top_Level_Safe }
	return .Cross_Site
}

////////////////////////////////
// Request construction

@(private)
dest_name :: proc(d: Destination) -> string {
	switch d {
	case .Empty: return "empty"
	case .Document: return "document"
	case .Script: return "script"
	case .Style: return "style"
	case .Image: return "image"
	case .Font: return "font"
	case .Audio: return "audio"
	case .Video: return "video"
	case .Manifest: return "manifest"
	case .Report: return "report"
	case .Worker: return "worker"
	case .Iframe: return "iframe"
	case .Frame: return "frame"
	}
	return "empty"
}

@(private)
mode_name :: proc(m: Mode) -> string {
	switch m {
	case .Navigate: return "navigate"
	case .Same_Origin: return "same-origin"
	case .No_Cors: return "no-cors"
	case .Cors: return "cors"
	}
	return "cors"
}

@(private)
default_accept :: proc(d: Destination) -> string {
	switch d {
	case .Document, .Iframe, .Frame: return "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
	case .Script, .Worker: return "application/wasm,*/*;q=0.8"
	case .Style:    return "text/css,*/*;q=0.1"
	// the formats package images decodes whatever the system has installed (built-in AVIF, WebP and SVG decoders)
	case .Image:    return "image/avif,image/webp,image/svg+xml,image/*,*/*;q=0.8"
	case .Empty, .Font, .Audio, .Video, .Manifest, .Report: return "*/*"
	}
	return "*/*"
}

@(private)
sec_fetch_site :: proc(t: ^Task) -> string {
	if t.initiator == nil { return "none" }
	o := url.origin_of(t.target, context.temp_allocator)
	if url.same_origin(t.initiator.origin, o) && !t.cross_site_seen { return "same-origin" }
	if !t.cross_site_seen { return "same-site" }
	return "cross-site"
}

// The header block for the real request (everything the browser adds, in one place).
@(private)
build_request_headers :: proc(t: ^Task) -> string { return join_headers(request_header_list(t)) }

// The fields of the real request (temp allocator).
@(private)
request_header_list :: proc(t: ^Task) -> http.Headers {
	l := t.loader
	h := http.headers_clone(t.headers, context.temp_allocator)
	if !http.has_header(h, "accept") {
		// JavaScript scripts: HTML's "*/*"; JSON modules: "application/json,*/*;q=0.5"
		accept := default_accept(t.destination)
		if (t.destination == .Script || t.destination == .Worker) && t.script != .Wasm { accept = t.script == .Json_Module ? "application/json,*/*;q=0.5" : "*/*" }
		http.append_header(&h, "Accept", accept)
	}
	if !http.has_header(h, "accept-language") && l.profile.settings.accept_language != "" { http.append_header(&h, "Accept-Language", l.profile.settings.accept_language) }

	// Origin
	if t.initiator != nil {
		ser := url.origin_serialize(t.origin, context.temp_allocator)
		policy := effective_referrer_policy(t)
		if t.cors_flag {
			http.set_header(&h, "Origin", ser)
		} else if t.method != "GET" && t.method != "HEAD" {
			http.set_header(&h, "Origin", policy == .No_Referrer ? "null" : ser)
		}
	}
	// Referer
	if !t.no_referrer && t.initiator != nil {
		if ref, ok := determine_referrer(t.initiator.location, t.target, effective_referrer_policy(t), l.profile.settings.referrer_max_length, context.temp_allocator); ok {
			http.set_header(&h, "Referer", ref)
		}
	}
	// Fetch Metadata, only towards trustworthy destinations
	if l.profile.settings.fetch_metadata && url.is_potentially_trustworthy(t.target) {
		http.set_header(&h, "Sec-Fetch-Dest", dest_name(t.destination))
		http.set_header(&h, "Sec-Fetch-Mode", mode_name(t.mode))
		http.set_header(&h, "Sec-Fetch-Site", sec_fetch_site(t))
		if t.mode == .Navigate && t.user_activation { http.set_header(&h, "Sec-Fetch-User", "?1") }
	}
	// Cookies
	if cookies_allowed(t) {
		ctx := cookies.Context{url = t.target, site_context = site_context(t), http_api = true, now_ms = now_ms()}
		if c := cookies.header_for(&l.profile.jar, ctx, context.temp_allocator); c != "" { http.set_header(&h, "Cookie", c) }
	}
	return h
}

@(private)
effective_referrer_policy :: proc(t: ^Task) -> Referrer_Policy {
	if t.referrer_policy != .Default { return t.referrer_policy }
	if t.initiator != nil && t.initiator.referrer_policy != .Default { return t.initiator.referrer_policy }
	return t.loader.profile.settings.referrer_policy
}

@(private)
join_headers :: proc(h: http.Headers) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for e, i in h.list {
		if i > 0 { strings.write_string(&sb, "\r\n") }
		strings.write_string(&sb, e.name)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, e.value)
	}
	return strings.to_string(sb)
}

////////////////////////////////
// Preflight

@(private)
Preflight :: struct { loader: ^Loader, task: base.Handle, unsafe: []string }

@(private)
send_preflight :: proc(t: ^Task, unsafe: []string) {
	l := t.loader
	t.stage = .Preflight
	h := http.headers_make(context.temp_allocator)
	http.append_header(&h, "Accept", "*/*")
	http.append_header(&h, "Access-Control-Request-Method", t.method)
	if len(unsafe) > 0 { http.append_header(&h, "Access-Control-Request-Headers", strings.join(unsafe, ",", context.temp_allocator)) }
	http.append_header(&h, "Origin", url.origin_serialize(t.origin, context.temp_allocator))
	if !t.no_referrer && t.initiator != nil {
		if ref, ok := determine_referrer(t.initiator.location, t.target, effective_referrer_policy(t), l.profile.settings.referrer_max_length, context.temp_allocator); ok { http.append_header(&h, "Referer", ref) }
	}
	if l.profile.settings.fetch_metadata && url.is_potentially_trustworthy(t.target) {
		http.append_header(&h, "Sec-Fetch-Dest", "empty")
		http.append_header(&h, "Sec-Fetch-Mode", "cors")
		http.append_header(&h, "Sec-Fetch-Site", sec_fetch_site(t))
	}
	if l.profile.settings.accept_language != "" { http.append_header(&h, "Accept-Language", l.profile.settings.accept_language) }

	// the unsafe names are copied: the task may be released before the answer arrives
	pf := new(Preflight)
	pf.loader = l
	pf.task = t.self
	pf.unsafe = make([]string, len(unsafe))
	for s, i in unsafe { pf.unsafe[i] = strings.clone(s) }
	t.net_user = pf
	t.net_req = net.fetch(l.net, {
		url = url_no_fragment(t.target), method = "OPTIONS", headers = join_headers(h), on_event = preflight_event, user = pf,
		collect = true, max_body = 1 << 20, priority = .High, link = link_of(l, t.scope),
	})
}

@(private)
preflight_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	pf := (^Preflight)(user)
	#partial switch ev.kind {
	case .Headers:
		// handled on Done (the body of a preflight is irrelevant, and `collect` gives us Done with the headers kept below)
		t := base.pool_get(&pf.loader.tasks, pf.task)
		if t != nil {
			http.headers_destroy(&t.raw_headers)
			t.raw_headers = http.parse_header_block(ev.headers)
			t.status = ev.status
		}
	case .Done:
		t := base.pool_get(&pf.loader.tasks, pf.task)
		defer free_preflight(pf)
		if t == nil { return }
		t.net_req, t.net_user = base.NIL_HANDLE, nil
		handle_preflight_result(t, pf)
	case .Failed:
		t := base.pool_get(&pf.loader.tasks, pf.task)
		defer free_preflight(pf)
		if t == nil { return }
		t.net_req, t.net_user = base.NIL_HANDLE, nil
		fail(t, .Blocked_Preflight, "preflight request failed", ev.error, ev.secure_flags)
	}
}

@(private)
free_preflight :: proc(pf: ^Preflight) {
	for s in pf.unsafe { delete(s) }
	delete(pf.unsafe)
	free(pf)
}

@(private)
handle_preflight_result :: proc(t: ^Task, pf: ^Preflight) {
	l := t.loader
	v := check_preflight_response(t.origin, credentials_include(t), t.status, t.raw_headers, t.method, pf.unsafe, l.profile.settings.preflight_default_age_s)
	if !v.ok {
		fail(t, .Blocked_Preflight, fmt.tprintf("CORS preflight failed: %s", v.reason))
		return
	}
	preflight_cache_store(&l.profile.preflights, url.origin_serialize(t.origin, context.temp_allocator), url_no_fragment(t.target),
		credentials_include(t), v.methods, v.headers, v.max_age_s, now_ms(),
		l.profile.settings.preflight_max_age_s, l.profile.settings.preflight_max_entries)
	send_main(t)
}

////////////////////////////////
// The real request

@(private)
send_main :: proc(t: ^Task) {
	l := t.loader
	t.stage = .Fetching
	if cache_lookup(t) { return }   // served from the HTTP cache, waiting for it, or failed (only-if-cached)
	h := request_header_list(t)
	cache_request_headers(t, &h)
	if observing(t.loader) { observe(t, Observed{kind = .Request, method = t.method, url = t.target.href, headers = join_headers(h), request_body = t.body}) }
	k := new_clone(Kick{l, t.self})
	t.net_user = k
	t.net_req = net.fetch(l.net, {
		url = url_no_fragment(t.target), method = t.method, headers = join_headers(h), body = t.body,
		on_event = main_event, user = k, collect = false, max_body = t.max_body, link = link_of(l, t.scope),
		priority = t.destination == .Document || is_frame_destination(t.destination) || t.destination == .Script || t.destination == .Style ? .High : .Normal,
	})
}

@(private)
main_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	k := (^Kick)(user)
	t := base.pool_get(&k.l.tasks, k.h)
	// the Kick is freed on the terminal events (by cancel_net when the request is cancelled before)
	terminal := ev.kind == .Done || ev.kind == .Failed
	defer if terminal { free(k) }
	if t == nil { return }
	if terminal { t.net_user = nil }
	switch ev.kind {
	case .Headers: on_response_headers(t, ev)
	case .Data:
		cache_on_data(t, ev.data)
		if t.initiator != nil && t.destination != .Document { t.initiator.counts.network_bytes += i64(len(ev.data)) }
		data := ev.data
		if t.filter.push != nil { clear(&t.filtered); t.filter.push(t.filter.user, data, &t.filtered); data = t.filtered[:] }
		if t.collect {
			append(&t.collected, ..data)
		} else if len(data) > 0 || t.filter.push == nil {
			out := Event{kind = .Data, data = data}
			deliver(t, &out)
		}
	case .Done:
		t.net_req = base.NIL_HANDLE
		cache_on_done(t)
		filter_finish(t)
		out := Event{kind = .Done}
		if t.obs_net { t.obs_timing.done = ev.timing.done }
		if t.collect { out.data = t.collected[:] }
		h, l := t.self, t.loader
		deliver(t, &out)
		release(l, h)
	case .Failed:
		t.net_req = base.NIL_HANDLE
		kind := Error_Kind.Transport
		if ev.error == net.ERROR_BODY_TOO_LARGE { kind = .Body_Too_Large }
		fail(t, kind, net.error_text(ev.error, ev.secure_flags), ev.error, ev.secure_flags)
	}
}

// The end of a filtered body: what the filter still held goes out before Done.
@(private)
filter_finish :: proc(t: ^Task) {
	if t.filter.push == nil || t.filter.finish == nil { return }
	clear(&t.filtered)
	t.filter.finish(t.filter.user, &t.filtered)
	if len(t.filtered) == 0 { return }
	if t.collect { append(&t.collected, ..t.filtered[:]) } else {
		out := Event{kind = .Data, data = t.filtered[:]}
		deliver(t, &out)
	}
}

@(private)
is_redirect_status :: proc(s: int) -> bool { return s == 301 || s == 302 || s == 303 || s == 307 || s == 308 }

@(private)
on_response_headers :: proc(t: ^Task, ev: ^net.Event) {
	l := t.loader
	now := now_ms()
	http.headers_destroy(&t.raw_headers)
	t.raw_headers = http.parse_header_block(ev.headers)
	t.status = ev.status
	raw := t.raw_headers
	t.obs_net, t.obs_timing, t.obs_proto, t.obs_remote, t.obs_remote_len = true, ev.timing, ev.protocol, ev.remote, ev.remote_len
	st := status_text_of(ev.headers)
	t.obs_status_len = u8(min(len(st), len(t.obs_status)))
	copy(t.obs_status[:], st[:t.obs_status_len])

	// cookies and HSTS are processed for every response, redirects included
	if cookies_allowed(t) {
		ctx := cookies.Context{url = t.target, site_context = site_context(t), http_api = true, now_ms = now}
		for v in http.get_all(raw, "set-cookie") { cookies.store(&l.profile.jar, v, ctx) }
	}
	if t.target.scheme == "https" && l.profile.settings.hsts {
		if v, ok := http.get_header(raw, "strict-transport-security"); ok { hsts_note(&l.profile.hsts, t.target.host, v, now) }
	}
	if cache_on_response(t) { return }   // a 304 for the stored response: the cache answers (http_cache.odin)
	check_and_send_response(t)
}

// What every response goes through, from the network or from the cache: the CORS check, redirects, the MIME rules of
// the destination, then the filtered Response. True when the Response was delivered (its body is to follow); false
// when the task failed or went on to a redirect.
@(private)
check_and_send_response :: proc(t: ^Task) -> bool {
	raw := t.raw_headers

	// CORS: the server must opt in, for a redirect too (Fetch: the CORS check of HTTP fetch comes before the redirect)
	if t.cors_flag {
		if ok, why := cors_check(t.origin, credentials_include(t), raw); !ok {
			fail(t, .Blocked_Cors, fmt.tprintf("blocked by CORS policy: %s", why))
			return false
		}
	}

	// redirects
	if is_redirect_status(t.status) {
		if loc, ok := http.get_header(raw, "location"); ok {
			handle_redirect(t, loc)
			return false
		}
	}

	if !intercept_response(t) { return false }
	raw = t.raw_headers
	m, has_mime := http.extract_mime(raw, context.temp_allocator)
	nosniff := false
	if v, ok := http.get_header(raw, "x-content-type-options"); ok { nosniff = strings.equal_fold(strings.trim_space(strings.split(v, ",", context.temp_allocator)[0]), "nosniff") }
	if why, ok := check_task_mime(t, m, has_mime, nosniff); !ok {
		fail(t, .Bad_Mime, why)
		return false
	}
	send_response(t, t.status, raw, m, has_mime)
	return true
}

// Builds the filtered Response and delivers it.
@(private)
send_response :: proc(t: ^Task, status: int, raw: http.Headers, m: http.Mime, has_mime: bool) {
	resp := Response{url = t.target.href, redirected = t.redirected, mime = m, has_mime = has_mime, cache = t.cache.outcome}
	if t.initiator != nil && t.destination != .Document {
		switch t.cache.outcome {
		case .Network:           t.initiator.counts.network += 1
		case .Hit, .Stale:       t.initiator.counts.cache += 1
		case .Revalidated:       t.initiator.counts.revalidated += 1
		}
	}
	switch t.taint {
	case .Basic:
		resp.type, resp.status, resp.body_usable = .Basic, status, true
		resp.headers = filter_basic_response_headers(raw, context.temp_allocator)
	case .Cors:
		resp.type, resp.status, resp.body_usable = .Cors, status, true
		resp.headers = filter_cors_response_headers(raw, credentials_include(t), context.temp_allocator)
	case .Opaque, .Opaque_Redirect:
		resp.type, resp.status, resp.body_usable = .Opaque, 0, false
		resp.headers = http.headers_make(context.temp_allocator)
	}
	ev := Event{kind = .Response, response = &resp}
	deliver(t, &ev)
}

// A JavaScript script follows HTML's rules (script_type.odin), anything else its destination's.
@(private)
check_task_mime :: proc(t: ^Task, m: http.Mime, has: bool, nosniff: bool) -> (why: string, ok: bool) {
	if (t.destination == .Script || t.destination == .Worker) && t.script != .Wasm {
		// HTML "fetch a classic worker script": over HTTP(S), a worker's script must have a JavaScript MIME type (a data:
		// or blob: URL may have any)
		if t.destination == .Worker && t.script == .Classic && (strings.has_prefix(t.target.href, "http:") || strings.has_prefix(t.target.href, "https:")) &&
		   !(has && is_javascript_mime(m.type, m.subtype)) {
			return "a worker's script must be served with a JavaScript MIME type", false
		}
		return check_script_mime(t.script, m.type, m.subtype, has, nosniff)
	}
	return check_destination_mime(t.destination, m, has, nosniff)
}

// What a destination requires of the response's type (nosniff and the WebAssembly MIME rule).
@(private)
check_destination_mime :: proc(d: Destination, m: http.Mime, has: bool, nosniff: bool) -> (why: string, ok: bool) {
	#partial switch d {
	case .Script, .Worker:
		if !has || !http.is_wasm_mime(m) { return "a Wasm module must be served as application/wasm", false }
	case .Style:
		if nosniff && !(has && m.type == "text" && m.subtype == "css") { return "stylesheet blocked: nosniff and not text/css", false }
	}
	return "", true
}

////////////////////////////////
// Redirects

@(private)
handle_redirect :: proc(t: ^Task, location: string) {
	l := t.loader
	switch t.redirect {
	case .Error:  fail(t, .Redirect_Error, "redirects are not allowed for this request"); return
	case .Manual:
		// the caller wants to see the redirect itself
		resp := Response{type = .Opaque_Redirect, status = 0, url = t.target.href, headers = http.headers_make(context.temp_allocator)}
		ev := Event{kind = .Response, response = &resp}
		h := t.self
		deliver(t, &ev)
		// the Response callback may have cancelled the task, and another task may have taken its slot: by handle
		cur := base.pool_get(&l.tasks, h)
		if cur == nil { return }
		done := Event{kind = .Done}
		deliver(cur, &done)
		release(l, h)
		return
	case .Follow:
	}
	if t.redirect_count >= l.profile.settings.max_redirects { fail(t, .Redirect_Loop, "too many redirects"); return }

	next, ok := url.parse(location, &t.target)
	if !ok { fail(t, .Bad_Redirect, fmt.tprintf("invalid redirect location %q", location)); return }
	if next.scheme != "http" && next.scheme != "https" {
		url.destroy(&next)
		fail(t, .Bad_Redirect, "redirect to a non-http(s) URL"); return
	}
	if t.cors_flag && (next.username != "" || next.password != "") {
		url.destroy(&next)
		fail(t, .Bad_Redirect, "redirect URL contains credentials"); return
	}

	// taint the origin when a cross-origin request is redirected cross-origin
	prev_origin := url.origin_of(t.target, context.temp_allocator)
	next_origin := url.origin_of(next, context.temp_allocator)
	if !url.same_origin(prev_origin, next_origin) && !url.same_origin(t.origin, prev_origin) && !t.origin.opaque {
		url.origin_destroy(&t.origin)
		t.origin = url.new_opaque_origin()
	}
	if !url.same_origin(prev_origin, next_origin) {
		http.delete_header(&t.headers, "authorization")   // never leak credentials across origins
	}

	// method rewriting
	if ((t.status == 301 || t.status == 302) && t.method == "POST") || (t.status == 303 && t.method != "GET" && t.method != "HEAD") {
		delete(t.method)
		t.method = strings.clone("GET")
		delete(t.body)
		t.body = nil
		for n in ([]string{"content-encoding", "content-language", "content-location", "content-type"}) { http.delete_header(&t.headers, n) }
	}

	if observing(t.loader) { observe(t, Observed{kind = .Redirect, url = t.target.href, status = t.status, detail = next.href}) }
	t.redirect_count += 1
	t.redirected = true
	cancel_net(l, t)
	url.destroy(&t.target)
	t.target = next
	run_hop(t)
}

////////////////////////////////
// Local schemes

@(private)
synthetic :: proc(t: ^Task, status: int, mime: string, body: []byte) {
	raw := http.headers_make(context.temp_allocator)
	http.append_header(&raw, "Content-Type", mime)
	buf: [24]byte
	http.append_header(&raw, "Content-Length", fmt.bprintf(buf[:], "%d", len(body)))
	m, has := http.parse_mime(mime, context.temp_allocator)
	if why, ok := check_task_mime(t, m, has, false); !ok { fail(t, .Bad_Mime, why); return }
	// each callback may cancel the task (and another task may take its slot): it is found again by handle after each
	h, l := t.self, t.loader
	send_response(t, status, raw, m, has)
	cur := base.pool_get(&l.tasks, h)
	if cur == nil { return }
	if cur.collect {
		append(&cur.collected, ..body)
	} else if len(body) > 0 {
		ev := Event{kind = .Data, data = body}
		deliver(cur, &ev)
		if cur = base.pool_get(&l.tasks, h); cur == nil { return }
	}
	done := Event{kind = .Done}
	if cur.collect { done.data = cur.collected[:] }
	deliver(cur, &done)
	release(l, h)
}

@(private)
data_hop :: proc(t: ^Task) {
	// top-level only: a data: document in a frame is allowed (its origin is opaque: the page package makes it so)
	if t.mode == .Navigate && !is_frame_destination(t.destination) { fail(t, .Unsupported, "navigation to data: URLs is blocked"); return }
	d, ok := process_data_url(t.target)
	if !ok { fail(t, .Bad_Data_URL, "malformed data: URL"); return }
	defer data_url_destroy(&d)
	t.taint = .Basic   // a data: response is readable by whoever asked for it
	synthetic(t, 200, d.mime, d.body)
}

@(private)
File_Outcome :: enum u8 { File, Redirect, Index, Listing }

@(private)
File_Job :: struct {
	loader: ^Loader,
	task:   base.Handle,
	path:   string,
	max:    int,
	data:   []byte,
	err:    string,
	size_exceeded: bool,
	// folders (directory.odin)
	document:   bool,            // a navigation: a folder shows its index or its listing
	slash:      bool,            // the URL's path ends with '/'
	files:      File_Settings,   // a copy: the preferences may change while the job runs
	sort:       Listing_Sort,
	descending: bool,
	outcome:    File_Outcome,
	index:      string,          // the index file shown
	root:       string,          // the tree the file must really be in (a document's own), "" when anything goes
}

// A navigation may open a file outside the initiator's tree: the browser UI (nil) opens anything, and so does a file:
// document (a listing's links, a local page linking to its neighbours), unless file: documents may read nothing at all.
// A web page never does: it can neither open nor list the disk.
//
// A file on another machine (file://server/share/...) is opened from a document of that machine only: Windows connects
// to the server named, and signs in to it with the user's credentials, for whatever local page names it.
file_navigation_allowed :: proc(env: ^Environment, policy: File_Access, target_host := "") -> bool {
	if env == nil { return true }
	if policy == .None || env.location.scheme != "file" { return false }
	if target_host != "" && target_host != "localhost" && !strings.equal_fold(target_host, env.location.host) { return false }
	return true
}

@(private)
file_hop :: proc(t: ^Task) {
	l := t.loader
	path, ok := file_path_from_url(t.target)
	if !ok { fail(t, .Bad_URL, "invalid file URL"); return }
	defer delete(path)
	document := t.mode == .Navigate && (t.destination == .Document || is_frame_destination(t.destination))
	policy := l.profile.settings.file_access
	navigation := document && file_navigation_allowed(t.initiator, policy, t.target.host)
	if !navigation && !file_access_allowed(t.initiator, path, policy) {
		fail(t, .Blocked_File, fmt.tprintf("a document may only read files in its own directory tree (%s)", path)); return
	}
	t.taint = .Basic
	t.stage = .Local
	a := base.process_allocator()
	job := new(File_Job, a)
	job.loader = l
	job.task = t.self
	job.path = strings.clone(path, a)
	job.max = t.max_body > 0 ? t.max_body : l.net.settings.max_body
	job.document = document
	job.slash = strings.has_suffix(t.target.path, "/")
	job.files = file_settings_clone(l.profile.settings.files, a)
	job.sort, job.descending = listing_order(t.target.query, &l.profile.settings.files)
	// allowed by the tree rule only: the file must still be in the tree once links and junctions are followed
	if !navigation && t.initiator != nil && policy == .Own_Tree { job.root = strings.clone(t.initiator.file_root, a) }
	host.run_blocking(l.blocking, file_work, file_done, job)
}

@(private)
file_work :: proc(data: rawptr) {
	j := (^File_Job)(data)
	context.allocator = base.process_allocator()
	attrs, st := file_attributes(j.path)
	if st != .Ok { j.err = strings.clone(file_status_text(st, j.path)); return }
	if j.root != "" {
		real, ok := final_path(j.path, context.temp_allocator)
		real_root, ok_root := final_path(j.root, context.temp_allocator)
		if !ok || !ok_root || !path_within(real_root, real) {
			j.err = strings.clone(fmt.tprintf("%s leads out of the document's directory tree (a link or a junction)", j.path))
			return
		}
	}
	if attrs.folder {
		if !j.document { j.err = strings.clone(fmt.tprintf("%s is a folder", j.path)); return }
		if !j.slash { j.outcome = .Redirect; return }
		dir := strings.trim_right(j.path, "\\")
		for name in j.files.index_names {
			p := strings.concatenate({dir, "\\", name}, context.temp_allocator)
			ia, ist := file_attributes(p)
			if ist != .Ok || ia.folder { continue }
			if read_file_into(j, p, ia.size) { j.outcome = .Index; j.index = strings.clone(name) }
			return
		}
		if !j.files.listing { j.err = strings.clone(fmt.tprintf("%s is a folder without an index file, and folder listings are off (file.directory.listing)", j.path)); return }
		l, lst := read_directory(j.path, &j.files)
		defer dir_listing_destroy(&l)
		if lst != .Ok { j.err = strings.clone(file_status_text(lst, j.path)); return }
		sort_listing(&l, j.sort, j.descending, j.files.folders_first)
		j.data = transmute([]byte)directory_listing_html(j.path, &l, j.sort, j.descending)
		j.outcome = .Listing
		return
	}
	read_file_into(j, j.path, attrs.size)
}

@(private)
read_file_into :: proc(j: ^File_Job, path: string, size: i64) -> bool {
	if size > i64(j.max) { j.size_exceeded = true; j.err = strings.clone(fmt.tprintf("%s is too large (%d bytes)", path, size)); return false }
	bytes, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil { j.err = strings.clone(fmt.tprintf("%s: cannot be read", path)); return false }
	j.data = bytes
	return true
}

@(private)
file_done :: proc(data: rawptr) {
	j := (^File_Job)(data)
	a := base.process_allocator()
	defer {
		delete(j.path, a); delete(j.data, a); delete(j.err, a); delete(j.index, a); delete(j.root, a)
		file_settings_destroy(&j.files, a)
		free(j, a)
	}
	t := base.pool_get(&j.loader.tasks, j.task)
	if t == nil { return }
	if j.err != "" {
		fail(t, j.size_exceeded ? .Body_Too_Large : .Transport, j.err)
		return
	}
	switch j.outcome {
	case .Redirect:
		// a folder's URL ends with '/', as http servers and browsers make it: its relative links resolve inside it
		if t.redirect_count >= t.loader.profile.settings.max_redirects { fail(t, .Redirect_Loop, "too many redirects"); return }
		u := t.target
		href := directory_redirect_href(u.scheme, u.host, u.path, u.query, u.fragment, u.has_query, u.has_fragment, context.temp_allocator)
		next, ok := url.parse_absolute(href)
		if !ok { fail(t, .Bad_Redirect, fmt.tprintf("invalid folder URL %q", href)); return }
		url.destroy(&t.target)
		t.target = next
		t.redirect_count += 1
		t.redirected = true
		run_hop(t)
	case .Index:
		synthetic(t, 200, mime_for_extension(j.index), j.data)
	case .Listing:
		synthetic(t, 200, "text/html;charset=utf-8", j.data)
	case .File:
		path, _ := file_path_from_url(t.target, context.temp_allocator)
		synthetic(t, 200, mime_for_extension(path), j.data)
	}
}

////////////////////////////////
// Content Security Policy

@(private)
csp_kind :: proc(d: Destination) -> (csp.Directive_Kind, bool) {
	switch d {
	case .Empty, .Report: return .Connect_Src, true
	case .Script:         return .Script_Src_Elem, true
	case .Worker:         return .Worker_Src, true   // worker-src, then child-src, script-src, default-src (CSP 3)
	case .Style:          return .Style_Src_Elem, true
	case .Image:          return .Img_Src, true
	case .Font:           return .Font_Src, true
	case .Audio, .Video:  return .Media_Src, true
	case .Manifest:       return .Manifest_Src, true
	case .Iframe, .Frame: return .Frame_Src, true    // frame-src, then child-src, default-src
	case .Document:       return {}, false   // navigations are not governed by the initiator's policy here
	}
	return {}, false
}

// upgrade-insecure-requests, then the policy check. False when the task was failed.
@(private)
content_security_check :: proc(t: ^Task) -> bool {
	env := t.initiator
	if env == nil || !t.loader.profile.settings.csp || len(env.policies.policies) == 0 || t.target.href == "about:blank" { return true }

	if t.target.scheme == "http" && !url.is_potentially_trustworthy(t.target) && csp.has_directive(&env.policies, "upgrade-insecure-requests") {
		if up, ok := upgrade_to_https(t.target); ok { url.destroy(&t.target); t.target = up }
	}
	if csp.has_directive(&env.policies, "block-all-mixed-content") && t.target.scheme == "http" && !url.is_potentially_trustworthy(t.target) && t.destination != .Document {
		fail(t, .Blocked_Mixed_Content, "blocked by block-all-mixed-content"); return false
	}
	kind, applies := csp_kind(t.destination)
	if !applies { return true }
	v: csp.Verdict
	if t.destination == .Script && t.script != .Wasm {
		// JavaScript: 'strict-dynamic' and nonces as CSP 3 applies them to script elements (csp/script.odin)
		v = csp.check_script_request(&env.policies, t.target, env.origin, t.redirected, t.nonce, t.parser_inserted)
	} else {
		v = csp.check_request(&env.policies, kind, t.target, env.origin, t.redirected, t.nonce)
	}
	for viol in v.violations { if env.on_violation != nil { env.on_violation(env.violation_user, viol) } }
	if !v.allowed {
		name := len(v.violations) > 0 ? v.violations[0].directive : "?"
		fail(t, .Blocked_Csp, fmt.tprintf("blocked by Content-Security-Policy (%s)", name))
		return false
	}
	return true
}