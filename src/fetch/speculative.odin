package fetch

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:csp"
import "wb:http"
import "wb:net"
import "wb:url"

// Requests made ahead of the document's parser (the preload scanner: page/preload_scan.odin). A document is parsed once it is
// complete; what its bytes name goes out while they arrive, and the request the parser's element makes later is the one
// already on its way.
//
// `speculate` starts a task like any other, its events going to an entry of the document's Speculation, which keeps them. A
// `start` of the same document for the same URL, destination, mode, credentials and script type (HTML's preload key) makes no
// request: its task follows the entry, gets what the entry has from a task of the loop and the rest as it comes. Whatever
// asks, the request is made once: nothing else changes (the consumers check integrity, MIME and status on what they get), and
// the policies still see each asker: a follower is checked against the Content-Security-Policy with its own nonce and its own
// parser-inserted flag. The developer tools and Resource Timing see the entry's task, one row, and not the followers.
//
// A <link rel=preload> follows without consuming (`Start_Desc.preload`): the element that uses the resource is to find it too,
// and it may come first (the parser's scripts ask before the links are revealed). Any other follower takes the entry: the next
// request of that URL is a request. The entries nobody took go at `speculation_end`, the document's load event.

Speculation :: struct {
	loader:   ^Loader,
	scope:    ^base.Scope,
	env:      ^Environment,
	entries:  map[string]^Spec_Entry,   // those a request can still find, by spec_key (keys owned by the entries)
	made:     int,                      // requests made so far
	reused:   int,                      // requests that followed one instead of being made
	ended:    bool,
}

@(private)
Spec_Entry :: struct {
	spec:         ^Speculation,
	key:          string,            // owned
	task:         base.Handle,       // the request; NIL once it ended
	followers:    [dynamic]base.Handle,
	response:     Response,          // owned, once has_response
	has_response: bool,
	body:         [dynamic]byte,
	ended:        bool,              // its task is over: Done, or Failed with what follows
	failed:       bool,
	error:        Error_Kind,
	detail:       string,            // owned
	net_code:     u32,
	net_flags:    u32,
	listed:       bool,              // in spec.entries
	taken:        bool,              // the element that uses the resource took it
	await_link:   bool,              // a <link rel=preload> was read for it: the link is revealed after the element may have asked
	passing:      bool,              // an event of its task is being passed on: its followers may go meanwhile, it stays
}

// What makes two requests one (HTML "preload key"); temporary.
@(private = "file")
spec_key :: proc(r: Request_Desc) -> string {
	return fmt.tprintf("%d %d %d %d %s", r.destination, r.mode, r.credentials, r.script, r.url)
}

// A plain GET a document's element makes: what can have been asked ahead.
@(private = "file")
spec_eligible :: proc(r: Request_Desc) -> bool {
	return (r.method == "" || r.method == "GET") && len(r.headers) == 0 && len(r.body) == 0 && r.cache == .Default && r.redirect == .Follow && !r.ping && !r.skip_service_worker
}

// Makes the table of a document's requests ahead and gives it to `env`: its fetches find it there. `env` and `scope` are the
// page's; speculation_destroy ends it.
speculation_make :: proc(l: ^Loader, env: ^Environment, scope: ^base.Scope) -> ^Speculation {
	s := new(Speculation)
	s.loader, s.env, s.scope = l, env, scope
	env.speculation = s
	return s
}

// Whether the document's policy lets the request go, without reporting anything: what is only guessed reports no violation
// (the element, if there is one, is refused and reports when the parser reaches it).
@(private = "file")
spec_csp_allows :: proc(l: ^Loader, env: ^Environment, r: Request_Desc) -> bool {
	if !l.profile.settings.csp || len(env.policies.policies) == 0 { return true }
	u, ok := url.parse_absolute(r.url, context.temp_allocator)
	if !ok { return false }
	kind, applies := csp_kind(r.destination)
	if !applies { return true }
	if r.destination == .Script && r.script != .Wasm {
		return csp.check_script_request(&env.policies, u, env.origin, false, r.nonce, r.parser_inserted).allowed
	}
	return csp.check_request(&env.policies, kind, u, env.origin, false, r.nonce).allowed
}

// Asks for `r` ahead of the element that will. False when it was not asked: asked already, refused by the document's policy,
// not a request an element makes, or the document is past that stage. `link`: it is a <link rel=preload> that asks.
speculate :: proc(s: ^Speculation, r: Request_Desc, link := false) -> bool {
	if s == nil || s.ended || !spec_eligible(r) { return false }
	key := spec_key(r)
	if e, ok := s.entries[key]; ok {
		e.await_link ||= link
		return false
	}
	if !spec_csp_allows(s.loader, s.env, r) { return false }
	e := new(Spec_Entry)
	e.spec = s
	e.key = strings.clone(key)
	e.listed = true
	e.await_link = link
	s.entries[e.key] = e
	s.made += 1
	req := r
	req.initiator = s.env
	req.speculative = true
	e.task = start(s.loader, {request = req, on_event = spec_event, user = e, scope = s.scope})
	return true
}

// <link rel=preconnect> or dns-prefetch: the origin of `u` will be asked soon. What the content blocker would refuse is not contacted.
preconnect :: proc(l: ^Loader, env: ^Environment, u: string, dns_only: bool) {
	if l.net == nil { return }
	if l.interceptor.request != nil {
		q := Intercept_Query{url = u, method = "GET", destination = .Empty, mode = .No_Cors, initiator = env}
		r: Intercept_Result
		l.interceptor.request(l.interceptor.user, &q, &r)
		if r.action != .Allow { return }
	}
	net.preconnect(l.net, u, dns_only)
}

// The entry the request `d` can follow.
@(private)
spec_claim :: proc(l: ^Loader, d: Start_Desc) -> ^Spec_Entry {
	r := d.request
	if r.speculative || r.initiator == nil { return nil }
	s := r.initiator.speculation
	if s == nil || s.loader != l || len(s.entries) == 0 || !spec_eligible(r) { return nil }
	e, ok := s.entries[spec_key(r)]
	if !ok || (e.taken && !d.preload) { return nil }
	s.reused += 1
	if d.preload { e.await_link = false } else { e.taken = true }
	if e.taken && !e.await_link { spec_unlist(e) }
	return e
}

@(private = "file")
spec_unlist :: proc(e: ^Spec_Entry) {
	if !e.listed { return }
	e.listed = false
	delete_key(&e.spec.entries, e.key)
}

// An entry out of the table with nobody following has no use left: its request stops.
@(private = "file")
spec_settle :: proc(e: ^Spec_Entry) {
	if e.listed || e.passing || len(e.followers) > 0 { return }
	if h := e.task; h != base.NIL_HANDLE {
		e.task = base.NIL_HANDLE
		release(e.spec.loader, h)
	}
	if e.has_response {
		r := &e.response
		delete(r.status_text); delete(r.url)
		http.headers_destroy(&r.headers)
		http.mime_destroy(&r.mime)
	}
	delete(e.key); delete(e.body); delete(e.followers); delete(e.detail)
	free(e)
}

// A follower went (cancelled or served).
@(private)
spec_forget :: proc(e: ^Spec_Entry, h: base.Handle) {
	for f, i in e.followers {
		if f == h { unordered_remove(&e.followers, i); break }
	}
	spec_settle(e)
}

@(private = "file")
too_large :: proc(t: ^Task, bytes: int) -> bool { return t.max_body > 0 && bytes > t.max_body }

// The follower's end, as its entry's.
@(private = "file")
spec_finish :: proc(t: ^Task, e: ^Spec_Entry) {
	if e.failed {
		fail(t, e.error, e.detail, e.net_code, e.net_flags)
		return
	}
	l, h := t.loader, t.self
	out := Event{kind = .Done}
	if t.collect { out.data = e.body[:] }
	deliver(t, &out)
	release(l, h)
}

// The follower's first turn: its own policy check, then what came so far.
@(private)
spec_follow :: proc(task: ^Task) {
	t := task
	e := t.follows
	l, h := t.loader, t.self
	if !content_security_check(t) { return }
	if t = base.pool_get(&l.tasks, h); t == nil { return }
	t.follow_live = true
	if e.has_response {
		ev := Event{kind = .Response, response = &e.response}
		deliver(t, &ev)
		if t = base.pool_get(&l.tasks, h); t == nil { return }
		if too_large(t, len(e.body)) {
			fail(t, .Body_Too_Large, "response body too large")
			return
		}
		if !t.collect && len(e.body) > 0 {
			data := Event{kind = .Data, data = e.body[:]}
			deliver(t, &data)
			if t = base.pool_get(&l.tasks, h); t == nil { return }
		}
	}
	if e.ended { spec_finish(t, e) }
}

// The entry's task: kept, and passed on to the followers that had their first turn.
@(private = "file")
spec_event :: proc(user: rawptr, task: base.Handle, ev: ^Event) {
	e := (^Spec_Entry)(user)
	l := e.spec.loader
	switch ev.kind {
	case .Response:
		r := ev.response
		e.response = r^
		e.response.status_text = strings.clone(r.status_text)
		e.response.url = strings.clone(r.url)
		e.response.headers = http.headers_clone(r.headers)
		e.response.mime = http.mime_clone(r.mime)
		e.has_response = true
	case .Data: append(&e.body, ..ev.data)
	case .Done:
		e.ended = true
		e.task = base.NIL_HANDLE
	case .Failed:
		e.ended, e.failed = true, true
		e.task = base.NIL_HANDLE
		e.error, e.net_code, e.net_flags = ev.error, ev.net_code, ev.net_flags
		e.detail = strings.clone(ev.detail)
		if ev.error == .Blocked_Csp { spec_unlist(e) }   // (found on a redirect: the element's own request is to report it)
	}
	e.passing = true
	list := make([]base.Handle, len(e.followers), context.temp_allocator)
	copy(list, e.followers[:])
	for h in list {
		t := base.pool_get(&l.tasks, h)   // (a follower's callback may have cancelled others)
		if t == nil || !t.follow_live { continue }
		switch ev.kind {
		case .Response: deliver(t, ev)
		case .Data:
			if too_large(t, len(e.body)) { fail(t, .Body_Too_Large, "response body too large"); continue }
			if !t.collect { deliver(t, ev) }
		case .Done, .Failed: spec_finish(t, e)
		}
	}
	e.passing = false
	spec_settle(e)
}

// The document's load event: what no element took is not waited for and not kept.
speculation_end :: proc(s: ^Speculation) {
	if s == nil || s.ended { return }
	s.ended = true
	list := make([dynamic]^Spec_Entry, 0, len(s.entries), context.temp_allocator)
	for _, e in s.entries { append(&list, e) }
	for e in list {
		spec_unlist(e)
		spec_settle(e)
	}
}

// How many requests were asked ahead, and how many times an element took one (a <link rel=preload> and its element: twice).
speculation_counts :: proc(s: ^Speculation) -> (made, reused: int) {
	if s == nil { return 0, 0 }
	return s.made, s.reused
}

// The page goes, its tasks with its scope.
speculation_destroy :: proc(s: ^Speculation) {
	if s == nil { return }
	speculation_end(s)
	s.env.speculation = nil
	delete(s.entries)
	free(s)
}

