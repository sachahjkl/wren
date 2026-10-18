package fetch

import "base:runtime"
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
	}
	t.headers = http.headers_make()
	t.raw_headers = http.headers_make()
	t.nonce = strings.clone(r.nonce)
	t.method = http.normalize_method(r.method == "" ? "GET" : r.method)

	u, ok := url.parse_absolute(r.url)
	if ok { t.target = u } else { t.early_error = .Bad_URL }
	if t.early_error == .None {
		switch {
		case !http.is_token(t.method) || http.is_forbidden_method(t.method): t.early_error = .Bad_Method
		case (t.method == "GET" || t.method == "HEAD") && len(r.body) > 0:     t.early_error = .Bad_Method
		}
	}
	if t.early_error == .None {
		for p in r.headers {
			if !http.is_token(p.name) || !http.is_valid_header_value(p.value) { t.early_error = .Bad_Header; break }
			if r.guard == .Request && http.is_forbidden_request_header(p.name) { continue }   // silently ignored, as in browsers
			http.append_header(&t.headers, p.name, p.value)
		}
	}
	if len(r.body) > 0 { t.body = make([]byte, len(r.body)); copy(t.body, r.body) }
	if r.initiator != nil { t.origin = url.origin_clone(r.initiator.origin) } else { t.origin = url.new_opaque_origin() }

	h, tp := base.pool_insert(&l.tasks, t)
	tp.self = h
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
	run_hop(t)
}

@(private)
early_detail :: proc(k: Error_Kind) -> string {
	#partial switch k {
	case .Bad_URL: return "invalid URL"
	case .Bad_Method: return "invalid or forbidden method, or a body on GET/HEAD"
	case .Bad_Header: return "invalid header name or value"
	}
	return "request rejected"
}

@(private)
task_scope_closed :: proc(data: rawptr) {
	k := (^Kick)(data)
	release(k.l, k.h)
	free(k)
}

// Silent. False if the task already finished.
cancel :: proc(l: ^Loader, h: base.Handle) -> bool { return release(l, h) }

@(private)
release :: proc(l: ^Loader, h: base.Handle) -> bool {
	t, ok := base.pool_remove(&l.tasks, h)
	if !ok { return false }
	if t.net_req != base.NIL_HANDLE { net.cancel(l.net, t.net_req) }
	url.destroy(&t.target)
	url.origin_destroy(&t.origin)
	http.headers_destroy(&t.headers)
	http.headers_destroy(&t.raw_headers)
	delete(t.method)
	delete(t.nonce)
	delete(t.body)
	delete(t.collected)
	if t.scope != nil { base.run_cleanup(t.scope, t.cleanup) }
	return true
}

@(private)
deliver :: proc(t: ^Task, ev: ^Event) {
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
	if !content_security_check(t) { return }
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
	if t.mode != .Navigate && t.initiator != nil && t.loader.profile.settings.third_party_cookies == .Block {
		o := url.origin_of(t.target, context.temp_allocator)
		if !url.same_site(url.site_of(o, context.temp_allocator), t.initiator.top_level_site) { return false }
	}
	return true
}

@(private)
site_context :: proc(t: ^Task) -> cookies.Site_Context {
	if t.initiator == nil { return .Same_Site }   // typed in the address bar
	if !t.cross_site_seen { return .Same_Site }
	if t.mode == .Navigate && http.is_safe_method(t.method) { return .Cross_Site_Top_Level_Safe }
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
	case .Document: return "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
	case .Script, .Worker: return "application/wasm,*/*;q=0.8"
	case .Style:    return "text/css,*/*;q=0.1"
	case .Image:    return "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5"
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
build_request_headers :: proc(t: ^Task) -> string {
	l := t.loader
	h := http.headers_clone(t.headers, context.temp_allocator)
	if !http.has_header(h, "accept") { http.append_header(&h, "Accept", default_accept(t.destination)) }
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
	return join_headers(h)
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
	t.net_req = net.fetch(l.net, {
		url = url_no_fragment(t.target), method = "OPTIONS", headers = join_headers(h), on_event = preflight_event, user = pf,
		collect = true, max_body = 1 << 20, priority = .High,
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
		t.net_req = base.NIL_HANDLE
		handle_preflight_result(t, pf)
	case .Failed:
		t := base.pool_get(&pf.loader.tasks, pf.task)
		defer free_preflight(pf)
		if t == nil { return }
		t.net_req = base.NIL_HANDLE
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
	t.net_req = net.fetch(l.net, {
		url = url_no_fragment(t.target), method = t.method, headers = build_request_headers(t), body = t.body,
		on_event = main_event, user = new_clone(Kick{l, t.self}), collect = false, max_body = t.max_body,
		priority = t.destination == .Document || t.destination == .Script || t.destination == .Style ? .High : .Normal,
	})
}

@(private)
main_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	k := (^Kick)(user)
	t := base.pool_get(&k.l.tasks, k.h)
	// the Kick is freed on the terminal events
	terminal := ev.kind == .Done || ev.kind == .Failed
	defer if terminal { free(k) }
	if t == nil { return }
	switch ev.kind {
	case .Headers: on_response_headers(t, ev)
	case .Data:
		if t.collect {
			append(&t.collected, ..ev.data)
		} else {
			out := Event{kind = .Data, data = ev.data}
			deliver(t, &out)
		}
	case .Done:
		t.net_req = base.NIL_HANDLE
		out := Event{kind = .Done}
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

	// cookies and HSTS are processed for every response, redirects included
	if cookies_allowed(t) {
		ctx := cookies.Context{url = t.target, site_context = site_context(t), http_api = true, now_ms = now}
		for v in http.get_all(raw, "set-cookie") { cookies.store(&l.profile.jar, v, ctx) }
	}
	if t.target.scheme == "https" && l.profile.settings.hsts {
		if v, ok := http.get_header(raw, "strict-transport-security"); ok { hsts_note(&l.profile.hsts, t.target.host, v, now) }
	}

	// redirects
	if is_redirect_status(t.status) {
		if loc, ok := http.get_header(raw, "location"); ok {
			handle_redirect(t, loc)
			return
		}
	}

	// CORS: the server must opt in
	if t.cors_flag {
		if ok, why := cors_check(t.origin, credentials_include(t), raw); !ok {
			fail(t, .Blocked_Cors, fmt.tprintf("blocked by CORS policy: %s", why))
			return
		}
	}

	m, has_mime := http.extract_mime(raw, context.temp_allocator)
	nosniff := false
	if v, ok := http.get_header(raw, "x-content-type-options"); ok { nosniff = strings.equal_fold(strings.trim_space(strings.split(v, ",", context.temp_allocator)[0]), "nosniff") }
	if why, ok := check_destination_mime(t.destination, m, has_mime, nosniff); !ok {
		fail(t, .Bad_Mime, why)
		return
	}
	send_response(t, t.status, raw, m, has_mime)
}

// Builds the filtered Response and delivers it.
@(private)
send_response :: proc(t: ^Task, status: int, raw: http.Headers, m: http.Mime, has_mime: bool) {
	resp := Response{url = t.target.href, redirected = t.redirected, mime = m, has_mime = has_mime}
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
		deliver(t, &ev)
		done := Event{kind = .Done}
		h := t.self
		deliver(t, &done)
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

	t.redirect_count += 1
	t.redirected = true
	if t.net_req != base.NIL_HANDLE { net.cancel(l.net, t.net_req); t.net_req = base.NIL_HANDLE }
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
	if why, ok := check_destination_mime(t.destination, m, has, false); !ok { fail(t, .Bad_Mime, why); return }
	send_response(t, status, raw, m, has)
	if t.collect {
		append(&t.collected, ..body)
	}
	h, l := t.self, t.loader
	if !t.collect && len(body) > 0 {
		ev := Event{kind = .Data, data = body}
		deliver(t, &ev)
	}
	// the Response callback may have cancelled the task
	if base.pool_get(&l.tasks, h) == nil { return }
	done := Event{kind = .Done}
	if t.collect { done.data = t.collected[:] }
	deliver(t, &done)
	release(l, h)
}

@(private)
data_hop :: proc(t: ^Task) {
	if t.mode == .Navigate { fail(t, .Unsupported, "navigation to data: URLs is blocked"); return }
	d, ok := process_data_url(t.target)
	if !ok { fail(t, .Bad_Data_URL, "malformed data: URL"); return }
	defer data_url_destroy(&d)
	t.taint = .Basic   // a data: response is readable by whoever asked for it
	synthetic(t, 200, d.mime, d.body)
}

@(private)
File_Job :: struct {
	loader: ^Loader,
	task:   base.Handle,
	path:   string,
	max:    int,
	data:   []byte,
	err:    string,
	size_exceeded: bool,
}

@(private)
file_hop :: proc(t: ^Task) {
	l := t.loader
	path, ok := file_path_from_url(t.target)
	if !ok { fail(t, .Bad_URL, "invalid file URL"); return }
	defer delete(path)
	if !file_access_allowed(t.initiator, path, l.profile.settings.file_access) {
		fail(t, .Blocked_File, fmt.tprintf("a document may only read files in its own directory tree (%s)", path)); return
	}
	t.taint = .Basic
	t.stage = .Local
	job := new(File_Job, runtime.heap_allocator())
	job.loader = l
	job.task = t.self
	job.path = strings.clone(path, runtime.heap_allocator())
	job.max = t.max_body > 0 ? t.max_body : l.net.settings.max_body
	host.run_blocking(l.blocking, file_work, file_done, job)
}

@(private)
file_work :: proc(data: rawptr) {
	j := (^File_Job)(data)
	context.allocator = runtime.heap_allocator()
	info, serr := os.stat(j.path, context.allocator)
	if serr != nil { j.err = "file not found"; return }
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory { j.err = "is a directory"; return }
	if int(info.size) > j.max { j.size_exceeded = true; j.err = "file too large"; return }
	bytes, rerr := os.read_entire_file(j.path, context.allocator)
	if rerr != nil { j.err = "cannot read file"; return }
	j.data = bytes
}

@(private)
file_done :: proc(data: rawptr) {
	j := (^File_Job)(data)
	a := runtime.heap_allocator()
	defer { delete(j.path, a); delete(j.data, a); free(j, a) }
	t := base.pool_get(&j.loader.tasks, j.task)
	if t == nil { return }
	if j.err != "" {
		fail(t, j.size_exceeded ? .Body_Too_Large : .Transport, j.err)
		return
	}
	path, _ := file_path_from_url(t.target, context.temp_allocator)
	synthetic(t, 200, mime_for_extension(path), j.data)
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
	v := csp.check_request(&env.policies, kind, t.target, env.origin, t.redirected, t.nonce)
	for viol in v.violations { if env.on_violation != nil { env.on_violation(env.violation_user, viol) } }
	if !v.allowed {
		name := len(v.violations) > 0 ? v.violations[0].directive : "?"
		fail(t, .Blocked_Csp, fmt.tprintf("blocked by Content-Security-Policy (%s)", name))
		return false
	}
	return true
}