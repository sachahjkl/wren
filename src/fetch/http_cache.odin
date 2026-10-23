package fetch

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:cookies"
import "wb:http"
import "wb:httpcache"
import "wb:net"
import "wb:url"

// The HTTP cache in the Fetch Standard's "HTTP-network-or-cache fetch": between the policy checks of a hop (CORS
// preflight included) and the network. The rules (RFC 9111) and the store are package httpcache's; here, per request:
//
//   * the cache mode (Request.cache: default, no-store, reload, no-cache, force-cache, only-if-cached), with the
//     Fetch Standard's adjustments: a request carrying its own conditional headers bypasses the cache; no-cache adds
//     Cache-Control: max-age=0, reload and no-store add Pragma / Cache-Control: no-cache;
//   * the key: the request's partition (top-level site, frame site; a navigation is its own top level, and one coming
//     from another site is kept apart), whether credentials go with it, and the URL without its fragment. A document of
//     an opaque origin (a sandbox, a file) has no partition to share: its requests do not use the cache;
//   * a stored response that fits (Vary) is served when fresh, or stale inside stale-while-revalidate (refreshed in the
//     background), else revalidated with If-None-Match / If-Modified-Since: a 304 refreshes the stored fields and the
//     stored body is served;
//   * a response served from the cache goes through every check a network response goes through (CORS, redirects,
//     MIME / nosniff, filtering), but sets no cookie and no HSTS: those came with the network response that was stored;
//   * a network response is stored when RFC 9111 allows it (GET, final status, no no-store, Authorization only with
//     public / must-revalidate) and is not larger than an entry may be; an unsafe method that succeeds invalidates the
//     URL (and its Location / Content-Location of the same origin) in every partition.
//
// The shell reloads with no-cache for the document (F5: subresources stay as they are, as in Chromium) or reload for
// everything the new document loads (Ctrl+F5: Environment.cache_override), and walks the history with force-cache.

Cache_Mode :: enum u8 { Default, No_Store, Reload, No_Cache, Force_Cache, Only_If_Cached }

// Where a response came from (the shell's status bar, about:cache, Resource Timing).
Cache_Outcome :: enum u8 {
	Network,       // fetched (not stored before, or stale without validators, or the cache not used)
	Hit,           // served from the cache without asking
	Revalidated,   // the server answered 304: the stored body was served
	Stale,         // stale-while-revalidate: served at once, refreshed in the background
}

@(private)
Task_Cache :: struct {
	mode:         Cache_Mode,
	key:          string,             // owned: "" when this request does not use the cache
	validating:   bool,               // the request is conditional on the stored response of `key`
	pending_304:  bool,               // a 304 came while the stored response was not in memory: it is being read
	skip:         bool,               // go to the network without looking (after the stored response vanished)
	ticket:       httpcache.Ticket,   // waiting for the cache (its index, an entry read from disk)
	kick:         ^Kick,              // the waiter's data
	request_time: i64,
	sent:         string,             // owned: the request's fields as sent, without the cache's own (Vary values)
	store:        bool,               // the response is being kept for the cache
	body:         [dynamic]byte,      // ... its body (streaming tasks; collecting tasks use `collected`)
	outcome:      Cache_Outcome,
}

// Stats of a loader's requests (about:cache).
cache_of :: proc(l: ^Loader) -> ^httpcache.Cache { return l.profile.cache }

@(private)
cache_usable :: proc(t: ^Task) -> ^httpcache.Cache {
	c := t.loader.profile.cache
	if c == nil || !c.settings.enabled { return nil }
	return c
}

@(private)
cache_task_init :: proc(t: ^Task, r: Request_Desc) {
	t.cache.mode = r.cache
	if t.cache.mode == .Default && r.initiator != nil { t.cache.mode = r.initiator.cache_override }
	if t.cache.mode == .Default && t.loader.observer.no_cache { t.cache.mode = .No_Store }   // the developer tools' Disable cache
	if t.cache.mode == .Default {
		for n in ([]string{"if-modified-since", "if-none-match", "if-unmodified-since", "if-match", "if-range"}) {
			if http.has_header(t.headers, n) { t.cache.mode = .No_Store; break }
		}
	}
}

@(private)
cache_task_release :: proc(l: ^Loader, t: ^Task) {
	cache_wait_cancel(l, t)
	delete(t.cache.key)
	delete(t.cache.sent)
	delete(t.cache.body)
	t.cache.key, t.cache.sent, t.cache.body = "", "", nil
}

@(private)
cache_wait_cancel :: proc(l: ^Loader, t: ^Task) {
	if t.cache.ticket != 0 {
		httpcache.cancel(l.profile.cache, t.cache.ticket)
		t.cache.ticket = 0
	}
	if t.cache.kick != nil { free(t.cache.kick); t.cache.kick = nil }
}

@(private)
site_text :: proc(s: url.Site) -> string {
	if s.opaque { return "" }
	return strings.concatenate({s.scheme, "://", s.domain}, context.temp_allocator)
}

// The key of the request's response (temp), "" when it is not to be cached. RFC 9111 keys by URL; the partition is
// what browsers add (Chromium's network isolation key, Firefox's first-party isolation of the cache).
@(private)
cache_key :: proc(t: ^Task, c: ^httpcache.Cache) -> string {
	target := url_no_fragment(t.target)
	cred := t.credentials == .Include || (t.credentials == .Same_Origin && t.taint == .Basic) ? "c" : "a"
	if !c.settings.partition { return fmt.tprintf("1/_ _ %s %s", cred, target) }
	top, frame, nav: string
	if t.destination == .Document || t.initiator == nil {
		// a document is its own top level; what the browser itself loads (address bar, icons) belongs to the site
		site := site_text(url.site_of(url.origin_of(t.target, context.temp_allocator), context.temp_allocator))
		if site == "" { return "" }
		top, frame = site, site
		if t.destination == .Document && t.initiator != nil {
			from := site_text(t.initiator.site)
			if from != site { nav = "n" }   // a cross-site navigation does not see what same-site ones stored
		}
	} else if t.destination == .Iframe {
		// a nested document: the top level's site, and the frame's own (the document it will be)
		top = site_text(t.initiator.top_level_site)
		frame = site_text(url.site_of(url.origin_of(t.target, context.temp_allocator), context.temp_allocator))
		if top == "" || frame == "" { return "" }
	} else {
		top, frame = site_text(t.initiator.top_level_site), site_text(t.initiator.site)
		if top == "" || frame == "" { return "" }
	}
	return fmt.tprintf("1/%s %s %s%s %s", top, frame, cred, nav, target)
}

@(private)
request_cache_control :: proc(h: http.Headers) -> httpcache.Cache_Control {
	cc := httpcache.cache_control_of(h)
	if !http.has_header(h, "cache-control") {
		// HTTP/1.0's Pragma: no-cache, when there is no Cache-Control (RFC 9111 §5.4)
		if v, ok := http.get_header(h, "pragma"); ok && strings.contains(strings.to_lower(v, context.temp_allocator), "no-cache") { cc.no_cache = true }
	}
	return cc
}

// The Vary block of a request for a response: the request's values of the fields the response varies on.
@(private)
vary_block :: proc(resp: http.Headers, req: http.Headers) -> string {
	names, _ := httpcache.vary_names(resp)
	sb := strings.builder_make(context.temp_allocator)
	for n in names {
		v, present := httpcache.vary_value(req, n)
		if !present { continue }
		fmt.sbprintf(&sb, "%s: %s\r\n", n, v)
	}
	return strings.to_string(sb)
}

// Whether the stored response of `e` fits a request with fields `req` (RFC 9111 §4.1).
@(private)
vary_matches :: proc(e: ^httpcache.Entry, req: http.Headers) -> bool {
	resp := httpcache.headers_of(e)
	names, star := httpcache.vary_names(resp)
	if star { return false }
	if len(names) == 0 { return true }
	stored := http.parse_header_block(e.meta.vary, context.temp_allocator)
	for n in names {
		a, pa := httpcache.vary_value(stored, n)
		b, pb := httpcache.vary_value(req, n)
		if pa != pb || a != b { return false }
	}
	return true
}

////////////////////////////////
// Before the network

// The cache's part of sending the request. True when it took the task over: served from the cache, waiting for the
// disk, or failed (only-if-cached); false: the network, with `t.cache` saying how (conditional, storing).
@(private)
cache_lookup :: proc(t: ^Task) -> bool {
	t.cache.validating = false
	t.cache.outcome = .Network
	mode := t.cache.mode
	c := cache_usable(t)
	if c == nil || t.cache.skip || t.method != "GET" || http.has_header(t.headers, "range") {
		if mode == .Only_If_Cached && t.method == "GET" { cache_miss_fail(t); return true }
		return false
	}
	delete(t.cache.key)
	t.cache.key = strings.clone(cache_key(t, c))
	if t.cache.key == "" {
		if mode == .Only_If_Cached { cache_miss_fail(t); return true }
		return false
	}
	if mode == .No_Store || mode == .Reload { return false }
	rcc := request_cache_control(t.headers)
	if rcc.no_store { return false }   // the request's own Cache-Control: no-store (RFC 9111 §5.2.1.5)
	if !httpcache.is_ready(c) {
		cache_wait(t, c, nil)
		return true
	}
	e := httpcache.find(c, t.cache.key)
	if e != nil && !e.resident {
		cache_wait(t, c, e)
		return true
	}
	req := request_header_list(t)
	if e == nil || !vary_matches(e, req) {
		c.stats.misses += 1
		if mode == .Only_If_Cached { cache_miss_fail(t); return true }
		if rcc.only_if_cached { cache_gateway_timeout(t); return true }
		return false
	}
	resp := httpcache.headers_of(e)
	switch mode {
	case .Force_Cache, .Only_If_Cached:
		cache_serve(t, c, e, .Hit)
		return true
	case .No_Cache:
		t.cache.validating = httpcache.has_validator(resp)
		return false
	case .Default:
		times := httpcache.Response_Times{e.meta.request_time, e.meta.response_time}
		j := httpcache.judge(e.meta.status, resp, times, rcc, httpcache.now_s(), c.settings.heuristic, c.settings.stale_while_revalidate)
		switch j.use {
		case .Fresh:
			cache_serve(t, c, e, .Hit)
			return true
		case .Stale_Revalidate:
			revalidate_in_background(t, c, e)
			cache_serve(t, c, e, .Stale)
			return true
		case .Validate:
			if rcc.only_if_cached { cache_gateway_timeout(t); return true }
			t.cache.validating = httpcache.has_validator(resp)
			if !t.cache.validating { c.stats.misses += 1 }
			return false
		}
	case .No_Store, .Reload:
	}
	return false
}

@(private)
cache_miss_fail :: proc(t: ^Task) {
	fail(t, .Not_Cached, "only-if-cached: the response is not in the cache")
}

// RFC 9111 §5.2.1.7: a request with Cache-Control: only-if-cached and nothing usable stored gets a 504.
@(private)
cache_gateway_timeout :: proc(t: ^Task) {
	t.cache.outcome = .Hit
	synthetic(t, 504, "text/plain;charset=utf-8", nil)
}

// Waits for the index (e = nil) or for `e` to be read from disk, then looks again.
@(private)
cache_wait :: proc(t: ^Task, c: ^httpcache.Cache, e: ^httpcache.Entry) {
	cache_wait_cancel(t.loader, t)
	k := new_clone(Kick{t.loader, t.self})
	t.cache.kick = k
	if e == nil {
		t.cache.ticket = httpcache.when_ready(c, cache_resume, k)
		return
	}
	ticket, pending := httpcache.load(c, e, cache_resume, k)
	if pending { t.cache.ticket = ticket; return }
	// (already in memory: nothing to wait for)
	t.cache.kick = nil
	free(k)
	if t.cache.pending_304 { t.cache.pending_304 = false; cache_answer_304(t) } else { send_main(t) }
}

@(private)
cache_resume :: proc(user: rawptr, ok: bool) {
	k := (^Kick)(user)
	l, h := k.l, k.h
	t := base.pool_get(&l.tasks, h)
	if t == nil || t.cache.kick != k { free(k); return }
	t.cache.kick, t.cache.ticket = nil, 0
	free(k)
	if t.cache.pending_304 {
		t.cache.pending_304 = false
		cache_answer_304(t)
		return
	}
	send_main(t)
}

// The fields the cache adds to a request going to the network (Fetch: cache mode headers; RFC 9111 §4.3.1:
// validators of the stored response).
@(private)
cache_request_headers :: proc(t: ^Task, h: ^http.Headers) {
	delete(t.cache.sent)
	t.cache.sent = strings.clone(join_headers(h^))
	t.cache.request_time = httpcache.now_s()
	switch t.cache.mode {
	case .No_Cache:
		if !http.has_header(h^, "cache-control") { http.append_header(h, "Cache-Control", "max-age=0") }
	case .No_Store, .Reload:
		if !http.has_header(h^, "pragma") { http.append_header(h, "Pragma", "no-cache") }
		if !http.has_header(h^, "cache-control") { http.append_header(h, "Cache-Control", "no-cache") }
	case .Default, .Force_Cache, .Only_If_Cached:
	}
	if !t.cache.validating { return }
	c := cache_usable(t)
	e := c != nil ? httpcache.find(c, t.cache.key) : nil
	if e == nil || !e.resident { t.cache.validating = false; return }
	inm, ims := httpcache.conditional_headers(httpcache.headers_of(e))
	if inm != "" { http.set_header(h, "If-None-Match", inm) }
	if ims != "" { http.set_header(h, "If-Modified-Since", ims) }
}

////////////////////////////////
// Serving

// Delivers the stored response of `e` as the task's response: the checks of a network response, then the body.
@(private)
cache_serve :: proc(t: ^Task, c: ^httpcache.Cache, e: ^httpcache.Entry, outcome: Cache_Outcome) {
	httpcache.touch(c, e)
	if outcome == .Hit || outcome == .Stale { c.stats.hits += 1 }
	c.stats.bytes_served += e.body_size
	body := httpcache.body_retain(e.body)
	defer httpcache.body_release(body)
	t.cache.outcome = outcome
	t.cache.store = false
	http.headers_destroy(&t.raw_headers)
	t.raw_headers = http.parse_header_block(e.meta.headers)
	t.status = e.meta.status
	h, l := t.self, t.loader
	if !check_and_send_response(t) { return }
	cur := base.pool_get(&l.tasks, h)
	if cur == nil { return }
	data := body != nil ? body.data : nil
	if cur.collect {
		append(&cur.collected, ..data)
	} else if len(data) > 0 {
		ev := Event{kind = .Data, data = data}
		deliver(cur, &ev)
		if cur = base.pool_get(&l.tasks, h); cur == nil { return }
	}
	done := Event{kind = .Done}
	if cur.collect { done.data = cur.collected[:] }
	deliver(cur, &done)
	release(l, h)
}

////////////////////////////////
// After the network

// A network response's headers arrived (cookies and HSTS processed). True when the cache answered instead (a 304 for
// the stored response).
@(private)
cache_on_response :: proc(t: ^Task) -> bool {
	l := t.loader
	c := cache_usable(t)
	t.cache.store = false
	clear(&t.cache.body)
	if c == nil { return false }
	// RFC 9111 §4.4: an unsafe method that succeeded makes what is stored for its URL stale
	if !http.is_safe_method(t.method) && t.status >= 200 && t.status < 400 {
		httpcache.invalidate_url(c, url_no_fragment(t.target))
		for f in ([]string{"location", "content-location"}) {
			if v, ok := http.get_header(t.raw_headers, f); ok {
				if u, uok := url.parse(v, &t.target, context.temp_allocator); uok && url.same_origin(url.origin_of(u, context.temp_allocator), url.origin_of(t.target, context.temp_allocator)) {
					httpcache.invalidate_url(c, url_no_fragment(u))
				}
			}
		}
	}
	if t.cache.key == "" || t.cache.mode == .No_Store { return false }
	if t.cache.validating && t.status == 304 {
		cancel_net(l, t)   // a 304 has no body worth waiting for
		cache_answer_304(t)
		return true
	}
	t.cache.validating = false
	req := http.parse_header_block(t.cache.sent, context.temp_allocator)
	req_cc := httpcache.cache_control_of(req)
	if req_cc.no_store { return false }   // neither stored nor replacing what is
	resp_cc := httpcache.cache_control_of(t.raw_headers)
	keep := c.settings.keep_unvalidated_documents && t.destination == .Document
	verdict := httpcache.storable(t.method, t.status, req_cc, resp_cc, t.raw_headers, http.has_header(t.headers, "authorization"), keep)
	if verdict != .Store {
		// what was stored for the key is outdated by this answer
		if verdict != .Method { httpcache.remove_key(c, t.cache.key) }
		return false
	}
	if is_redirect_status(t.status) {
		// a redirect has no body for us: stored now (the hop goes on to the next URL)
		cache_store(t, c, nil)
		return false
	}
	t.cache.store = true
	return false
}

// A chunk of a response being stored (streaming tasks).
@(private)
cache_on_data :: proc(t: ^Task, data: []byte) {
	if !t.cache.store || t.collect { return }
	c := cache_usable(t)
	if c == nil || i64(len(t.cache.body) + len(data)) > c.settings.max_entry_bytes {
		t.cache.store = false
		delete(t.cache.body)
		t.cache.body = nil
		return
	}
	append(&t.cache.body, ..data)
}

// The response is complete: stored.
@(private)
cache_on_done :: proc(t: ^Task) {
	if !t.cache.store { return }
	t.cache.store = false
	c := cache_usable(t)
	if c == nil { return }
	cache_store(t, c, t.collect ? t.collected[:] : t.cache.body[:])
	delete(t.cache.body)
	t.cache.body = nil
}

@(private)
cache_store :: proc(t: ^Task, c: ^httpcache.Cache, body: []byte) {
	if i64(len(body)) > c.settings.max_entry_bytes { httpcache.remove_key(c, t.cache.key); return }
	now := httpcache.now_s()
	req := http.parse_header_block(t.cache.sent, context.temp_allocator)
	times := httpcache.Response_Times{t.cache.request_time, now}
	cc := httpcache.cache_control_of(t.raw_headers)
	life, _ := httpcache.freshness_lifetime(t.status, t.raw_headers, cc, c.settings.heuristic)
	age := httpcache.current_age(t.raw_headers, times, now)
	httpcache.store(c, {
		key = t.cache.key, url = url_no_fragment(t.target), status = t.status, headers = t.raw_headers,
		vary = vary_block(t.raw_headers, req), request_time = t.cache.request_time, response_time = now, body = body,
		fresh_until = now + max(life - age, 0),
	})
}

// The server said the stored response is still good: its fields are refreshed and it is served.
@(private)
cache_answer_304 :: proc(t: ^Task) {
	c := cache_usable(t)
	e := c != nil ? httpcache.find(c, t.cache.key) : nil
	if e == nil {
		// evicted or cleared while the request was out: ask again, unconditionally
		t.cache.validating = false
		t.cache.skip = true
		send_main(t)
		return
	}
	if !e.resident {
		t.cache.pending_304 = true
		cache_wait(t, c, e)
		return
	}
	now := httpcache.now_s()
	merged := httpcache.merge_304(httpcache.headers_of(e), t.raw_headers, context.temp_allocator)
	times := httpcache.Response_Times{t.cache.request_time, now}
	life, _ := httpcache.freshness_lifetime(e.meta.status, merged, httpcache.cache_control_of(merged), c.settings.heuristic)
	age := httpcache.current_age(merged, times, now)
	httpcache.refresh(c, e, t.raw_headers, t.cache.request_time, now, now + max(life - age, 0))
	t.cache.validating = false
	cache_serve(t, c, e, .Revalidated)
}

////////////////////////////////
// stale-while-revalidate: the refresh nobody waits for

@(private)
Revalidation :: struct {
	loader:       ^Loader,
	key:          string,
	target:       string,
	sent:         string,    // the request's fields (Vary values), without the validators
	request_time: i64,
	status:       int,
	headers:      string,
	destination:  Destination,
	cookie_ctx:   cookies.Context,
	cookie_url:   url.URL,
	cookies:      bool,
	req:          base.Handle,
}

@(private)
revalidate_in_background :: proc(t: ^Task, c: ^httpcache.Cache, e: ^httpcache.Entry) {
	l := t.loader
	for r in l.revalidations { if r.key == t.cache.key { return } }   // one at a time per response
	h := request_header_list(t)
	sent := join_headers(h)
	inm, ims := httpcache.conditional_headers(httpcache.headers_of(e))
	if inm != "" { http.set_header(&h, "If-None-Match", inm) }
	if ims != "" { http.set_header(&h, "If-Modified-Since", ims) }
	r := new(Revalidation)
	r.loader = l
	r.key = strings.clone(t.cache.key)
	r.target = strings.clone(url_no_fragment(t.target))
	r.sent = strings.clone(sent)
	r.request_time = httpcache.now_s()
	r.destination = t.destination
	if cookies_allowed(t) {
		r.cookies = true
		r.cookie_url = url.clone(t.target)
		r.cookie_ctx = cookies.Context{site_context = site_context(t), http_api = true}
	}
	append(&l.revalidations, r)
	r.req = net.fetch(l.net, {
		url = r.target, method = "GET", headers = join_headers(h), on_event = revalidation_event, user = r,
		collect = true, max_body = int(min(c.settings.max_entry_bytes, i64(max(int)))), priority = .Low,
	})
}

@(private)
revalidation_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	r := (^Revalidation)(user)
	l := r.loader
	switch ev.kind {
	case .Headers:
		r.status = ev.status
		delete(r.headers)
		r.headers = strings.clone(ev.headers)
		if r.cookies {
			raw := http.parse_header_block(ev.headers, context.temp_allocator)
			ctx := r.cookie_ctx
			ctx.url = r.cookie_url
			ctx.now_ms = now_ms()
			for v in http.get_all(raw, "set-cookie") { cookies.store(&l.profile.jar, v, ctx) }
		}
	case .Data:
	case .Done:
		revalidation_done(r, ev.data)
		revalidation_free(l, r)
	case .Failed:
		revalidation_free(l, r)
	}
}

@(private)
revalidation_done :: proc(r: ^Revalidation, body: []byte) {
	c := r.loader.profile.cache
	if c == nil || !c.settings.enabled { return }
	raw := http.parse_header_block(r.headers, context.temp_allocator)
	now := httpcache.now_s()
	times := httpcache.Response_Times{r.request_time, now}
	if r.status == 304 {
		e := httpcache.find(c, r.key)
		if e == nil || !e.resident { return }
		merged := httpcache.merge_304(httpcache.headers_of(e), raw, context.temp_allocator)
		life, _ := httpcache.freshness_lifetime(e.meta.status, merged, httpcache.cache_control_of(merged), c.settings.heuristic)
		httpcache.refresh(c, e, raw, r.request_time, now, now + max(life - httpcache.current_age(merged, times, now), 0))
		return
	}
	req := http.parse_header_block(r.sent, context.temp_allocator)
	keep := c.settings.keep_unvalidated_documents && r.destination == .Document
	if httpcache.storable("GET", r.status, httpcache.cache_control_of(req), httpcache.cache_control_of(raw), raw, false, keep) != .Store {
		httpcache.remove_key(c, r.key)
		return
	}
	life, _ := httpcache.freshness_lifetime(r.status, raw, httpcache.cache_control_of(raw), c.settings.heuristic)
	httpcache.store(c, {
		key = r.key, url = r.target, status = r.status, headers = raw, vary = vary_block(raw, req),
		request_time = r.request_time, response_time = now, body = body,
		fresh_until = now + max(life - httpcache.current_age(raw, times, now), 0),
	})
}

@(private)
revalidation_free :: proc(l: ^Loader, r: ^Revalidation) {
	for x, i in l.revalidations { if x == r { unordered_remove(&l.revalidations, i); break } }
	delete(r.key); delete(r.target); delete(r.sent); delete(r.headers)
	if r.cookies { url.destroy(&r.cookie_url) }
	free(r)
}

// Loader shutdown: background refreshes are cancelled.
@(private)
revalidations_destroy :: proc(l: ^Loader) {
	for len(l.revalidations) > 0 {
		r := l.revalidations[len(l.revalidations) - 1]
		net.cancel(l.net, r.req)
		revalidation_free(l, r)
	}
	delete(l.revalidations)
}

////////////////////////////////
// Questions from outside

Cache_Peek :: enum u8 {
	None,     // nothing stored for the request (or the cache is off / not used for it)
	Stored,   // something is stored: it may need a revalidation, or a read from disk
	Fresh,    // a fresh response is stored: the request will be answered without the network
}

// What the cache holds for a request, without starting it (a web font that is in the cache may hold the first paint
// for the few milliseconds it takes, instead of showing the fallback font first). Same key as the request would have;
// Vary is not checked.
cache_peek :: proc(l: ^Loader, r: Request_Desc) -> Cache_Peek {
	c := l.profile.cache
	if c == nil || !c.settings.enabled || !httpcache.is_ready(c) { return .None }
	mode := r.cache
	if mode == .Default && r.initiator != nil { mode = r.initiator.cache_override }
	if mode == .Default && l.observer.no_cache { mode = .No_Store }
	if mode == .No_Store || mode == .Reload { return .None }
	u, ok := url.parse_absolute(r.url, context.temp_allocator)
	if !ok || (u.scheme != "http" && u.scheme != "https") { return .None }
	t := Task{loader = l, target = u, mode = r.mode, credentials = r.credentials, destination = r.destination, initiator = r.initiator}
	t.taint = .Basic
	if r.initiator != nil && !url.same_origin(r.initiator.origin, url.origin_of(u, context.temp_allocator)) {
		t.taint = r.mode == .Cors ? .Cors : .Opaque
	}
	key := cache_key(&t, c)
	if key == "" { return .None }
	e := httpcache.find(c, key)
	if e == nil { return .None }
	if mode == .Force_Cache || mode == .Only_If_Cached { return .Fresh }
	if mode == .No_Cache { return .Stored }
	if e.resident {
		times := httpcache.Response_Times{e.meta.request_time, e.meta.response_time}
		j := httpcache.judge(e.meta.status, httpcache.headers_of(e), times, {max_age = -1, s_maxage = -1, stale_while_revalidate = -1, stale_if_error = -1, max_stale = -1, min_fresh = -1}, httpcache.now_s(), c.settings.heuristic, c.settings.stale_while_revalidate)
		return j.use == .Validate ? .Stored : .Fresh
	}
	return e.fresh_until > httpcache.now_s() ? .Fresh : .Stored
}

