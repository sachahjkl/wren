// Package headless: documents loaded as the browser loads them, without a window, for the measuring tools (src/tools/wpt,
// src/tools/jspage). A document is navigated to with the network stack and the Fetch policy (fetch.start, destination
// document), parsed (off the UI thread when preferences say so), adopted, its scripts started; the event loop is
// pumped by the caller, animation frames are run at the configured frame rate while the page asks for them. The page is
// visible and has Web Storage (a profile folder of the caller's choice) and a session history of its own; navigations
// it asks for are recorded, not followed.
//
// Windows its scripts open (window.open, links to _blank) are windows as the browser makes them, without the shell: each a
// Doc of its own with a top-level navigable (src/page/auxiliary.odin), its initial about:blank document, then the documents
// it navigates to (keeping the initial one's Window when it may: page.navigable_keep_window); they follow their navigations, with a
// session history across their documents (Doc.session) whose traversals they follow, close on window.close(), and close with the document that opened the
// first of them (Doc.popups of the root). A document such a window leaves may stay, frozen, in its back/forward cache (Doc.cached, as the
// browser's tab keeps one: page.bfcache_blockers, page_freeze, page_thaw): a traversal back to its entry shows it again instead of
// loading it. Their console messages go to the root's on_console with their own Doc (root set).
package headless

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:httpcache"
import "wb:net"
import "wb:page"
import "wb:url"

Env :: struct {
	loop:     host.Loop,
	client:   net.Client,
	blocking: host.Blocking_Pool,
	profile:  fetch.Profile,
	loader:   fetch.Loader,
	settings: page.Settings,
	storage:  page.Storage_Manager,
	process:  ^base.Scope,
	has_storage: bool,
	pages:    page.Pages,   // what its pages share (init binds this thread to it)
}

Navigable :: page.Navigable   // (a field named `page` hides the package in Doc)
Session_History :: page.Session_History

// Most documents a window keeps in its back/forward cache (the browser's history.bfcache.max_entries).
BFCACHE_MAX_PAGES :: 6

// A document a window left, frozen, for its entry of the window's session history.
Cached_Page :: struct {
	entry: u64,
	scope: ^base.Scope,   // its navigation's (the window's scope holds it)
	page:  ^page.Page,
}

Message :: struct {
	level: page.Log_Level,
	text:  string,   // owned
}

Doc :: struct {
	env:       ^Env,
	scope:     ^base.Scope,     // the window: its navigations and documents
	shown:     ^base.Scope,     // the current document's navigation (its request, then its page)
	loading:   ^base.Scope,     // a navigation in flight that has no response yet (a window following one); nil: none
	initiator: fetch.Environment,   // who asked for the navigation in flight (a copy: that document may be gone by the response)
	has_initiator: bool,
	task:      base.Handle,
	page:      ^page.Page,
	url:       string,          // owned: what was asked for
	final_url: string,          // owned
	status:    int,
	charset:   string,          // owned
	failed:    string,          // owned: why the document could not load ("" when it did)
	parsed:    bool,            // adopted, scripts started
	console:   [dynamic]Message,
	on_console: proc(d: ^Doc, level: page.Log_Level, text: string),
	on_parsed:  proc(d: ^Doc),  // optional: the document is adopted, its scripts have not started (set it after open)
	by_type:   bool,            // application/xhtml+xml is parsed as XML, as the browser does (set it after open); else as HTML
	mime:      string,          // owned: the response's type
	user:      rawptr,
	navigations: [dynamic]string,   // owned: what the page asked to navigate to
	last_frame: f64,
	created_ns: i64,
	top:       ^Navigable,      // its window's top-level navigable (window.open, opener, name, Cross-Origin-Opener-Policy)
	root:      ^Doc,            // a window a script opened: the document `open` loaded, whose windows it is; nil for that one
	popups:    [dynamic]^Doc,   // (the root) every window its documents and theirs opened, still open
	session:   Session_History,   // a window a script opened: its history across its documents, which it traverses
	cached:    [dynamic]Cached_Page,   // a window a script opened: its back/forward cache, oldest first
	restoring: u64,             // the entry whose cached document comes back in the task of the navigation in flight (0: none)
}

// The preferences `init` reads: the page's and the network's.
register_prefs :: proc(p: ^config.Prefs) {
	page.register_prefs(p)
	net.register_prefs(p)
}

// Starts the stack: event loop, network client, blocking pool, the Fetch profile, the page settings (from `prefs` when
// given, made with register_prefs: --pref name=value of the command line, else the defaults). `profile_dir` holds Web Storage ("" = none).
init :: proc(e: ^Env, prefs: ^config.Prefs = nil, profile_dir := "", blocking_threads := 2) -> bool {
	page.bind(&e.pages)   // (this thread runs the pages of the stack)
	host.loop_init(&e.loop)
	// the network.* preferences too (network.hosts, network.loopback_only: what a test run gives its pages)
	ns: net.Settings
	if prefs != nil { ns = net.settings_from_prefs(prefs, context.temp_allocator) }
	if !net.client_init(&e.client, &e.loop, ns) { return false }
	host.blocking_init(&e.blocking, &e.loop, blocking_threads)
	e.profile = fetch.profile_make()
	{
		// an HTTP cache in memory, as a browser has (fetch/http-cache)
		cs := httpcache.settings_default()
		e.profile.cache = httpcache.create(&e.loop, cs, "")
		httpcache.settings_destroy(&cs)
	}
	fetch.loader_init(&e.loader, &e.loop, &e.client, &e.blocking, &e.profile)
	e.settings = prefs != nil ? page.settings_from_prefs(prefs) : page.settings_default()
	if !page.register_imports() { return false }
	if profile_dir != "" {
		os.remove_all(profile_dir)
		page.storage_manager_init(&e.storage, &e.loop, &e.blocking, profile_dir)
		e.has_storage = true
	}
	e.process = base.scope_make("process")
	return true
}

destroy :: proc(e: ^Env) {
	base.scope_close(e.process)
	defer page.bind(nil)
	if e.has_storage { page.storage_manager_destroy(&e.storage) }
	httpcache.destroy(e.profile.cache)
	e.profile.cache = nil
}

@(private)
console_sink :: proc(user: rawptr, level: page.Log_Level, message: string) {
	d := (^Doc)(user)
	append(&d.console, Message{level, strings.clone(message)})
	if d.on_console != nil { d.on_console(d, level, message) }
}

// What a document asks of its window: the root records it, a window a script opened follows it (as the browser's tab does).
@(private)
navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	d := (^Doc)(user)
	append(&d.navigations, fmt.aprintf("%v %s", req.kind, req.url))
	if d.root == nil || d.page != p { return }
	sh := &d.session
	#partial switch req.kind {
	case .Assign, .Replace:
		// (a navigation from the initial about:blank replaces its entry, HTML "navigate")
		if req.kind == .Replace || page.navigable_blank_window(d.top, p) {
			page.session_replace(sh, req.url)
		} else {
			page.session_push(sh, req.url, 0, max_entries = d.env.settings.web.history_max_entries)
		}
		if req.has_nav_state { page.session_set_nav_state(sh, req.nav_state, true) }
		navigation_start(d, req.url, &p.env)
	case .Reload:
		if req.has_nav_state { page.session_set_nav_state(sh, req.nav_state, true) }
		navigation_start(d, strings.clone(p.env.location.href, context.temp_allocator), &p.env)
	case .Traverse:
		// an entry of the document: popstate there; another document's: the window loads it again (no back/forward cache here)
		e := page.session_peek(sh, req.delta)
		if e == nil { return }
		#partial switch page.history_traverse_to(p, e) {
		case .Same_Document, .Canceled: return
		}
		if d.page != p || p.closed { return }
		page.session_goto(sh, e)
		if bfcache_start(d, e.id) { return }
		navigation_start(d, strings.clone(e.url, context.temp_allocator), &p.env)
	}
}

// window.open, a link to a new window (Embedder.open): a Doc of the root's, its initial about:blank document, then its URL.
@(private)
open_hook :: proc(user: rawptr, p: ^page.Page, req: page.Open_Request) -> ^page.Navigable {
	opener := (^Doc)(user)
	root := opener.root != nil ? opener.root : opener
	e := opener.env
	d := new(Doc)
	d.env = e
	d.root = root
	d.on_console, d.user = root.on_console, root.user   // (the caller tells them apart by Doc.root)
	d.url = strings.clone(req.url)
	d.created_ns = host.now_ns(&e.loop)
	d.scope = base.scope_make("window", e.process)
	d.top = page.navigable_top_new()
	d.shown = base.scope_make("navigation", d.scope)
	d.page = page.auxiliary_document(d.top, req, d.shown, console_sink, d)
	page.session_push(&d.session, req.url, 0, max_entries = e.settings.web.history_max_entries)
	connect(d)
	d.parsed = true
	append(&root.popups, d)
	if !page.open_is_blank(req.url) { navigation_start(d, req.url, &req.source.env, req.noreferrer) }
	return d.top
}

// window.close() of a window a script opened (Embedder.close, from a task of its own).
@(private)
close_hook :: proc(user: rawptr, p: ^page.Page) {
	d := (^Doc)(user)
	root := d.root
	if root == nil || d.page != p { return }
	for x, i in root.popups {
		if x == d { ordered_remove(&root.popups, i); break }
	}
	doc_free(d)
}

// The document is its window's: navigations, storage, the windows it opens.
@(private)
connect :: proc(d: ^Doc) {
	e := d.env
	page.navigable_attach(d.top, d.page)
	page.set_embedder(d.page, {navigate = navigate_hook, user = d, session = d.root != nil ? &d.session : nil, tab_key = fmt.tprintf("window-%p", d), storage = e.has_storage ? &e.storage : nil, open = open_hook, close = close_hook})
}

// Navigates a new document to `url`. Follow it with `pump`; `close` frees it.
open :: proc(e: ^Env, url: string, on_console: proc(d: ^Doc, level: page.Log_Level, text: string) = nil, user: rawptr = nil) -> ^Doc {
	d := new(Doc)
	d.env = e
	d.on_console = on_console
	d.user = user
	d.created_ns = host.now_ns(&e.loop)
	d.scope = base.scope_make("window", e.process)
	d.top = page.navigable_top_new()
	navigation_start(d, url, nil)
	return d
}

// The window's next document: its request, which a later one replaces; the document it shows stays until the response.
@(private)
navigation_start :: proc(d: ^Doc, url: string, initiator: ^fetch.Environment, no_referrer := false) {
	e := d.env
	if d.loading != nil { base.scope_close(d.loading) }
	d.restoring = 0
	if d.has_initiator { fetch.environment_destroy(&d.initiator); d.has_initiator = false }
	if initiator != nil { d.initiator, d.has_initiator = fetch.environment_clone(initiator^), true }
	if d.url != url {
		delete(d.url)
		d.url = strings.clone(url)
	}
	d.loading = base.scope_make("navigation", d.scope)
	d.task = fetch.start(&e.loader, {
		request = {url = d.url, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Document,
			initiator = d.has_initiator ? &d.initiator : nil, no_referrer = no_referrer},
		on_event = document_event, user = d, scope = d.loading, collect = true,
	})
}

@(private)
document_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	d := (^Doc)(user)
	e := d.env
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		// the new document replaces the one shown, in its Window when that is the window's initial about:blank of its origin
		// (whose scope stays the document's; the request's goes with the next navigation)
		kept := page.navigable_keep_window(d.top, d.page, r.url, r.headers)
		if kept == nil {
			leave(d)
			d.shown, d.loading = d.loading, nil
		}
		delete(d.final_url); delete(d.charset); delete(d.mime)
		d.final_url, d.charset, d.mime = "", "", ""
		d.parsed = false
		d.status = r.status
		d.final_url = strings.clone(r.url)
		if r.has_mime {
			if cs, ok := http.mime_param(r.mime, "charset"); ok { d.charset = strings.clone(cs) }
			d.mime = strings.clone(http.mime_essence(r.mime))
		}
		// a redirect: the window's entry is the final address (a response has no fragment: the entry's stays)
		if cur := page.session_current(&d.session); d.root != nil && cur != nil && !same_but_fragment(cur.url, r.url) { page.session_replace(&d.session, r.url, set_state = false) }
		d.page = kept != nil ? kept : page.page_create(&e.loop, &e.loader, &e.settings, d.shown, r.url, console_sink, d)
		connect(d)
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		page.apply_response_headers(d.page, csp_h, ro_h, rp)
		page.apply_isolation_headers(d.page, r.headers)
	case .Done:
		d.task = base.NIL_HANDLE
		if d.page == nil { d.failed = strings.clone("no response"); return }
		page.parse_document(d.page, ev.data, d.charset, document_parsed, d, d.by_type ? d.mime : "")
	case .Failed:
		d.task = base.NIL_HANDLE
		if d.page != nil && d.root != nil { return }   // (a window's next document did not come: it keeps the one it shows)
		d.failed = strings.clone(ev.detail != "" ? ev.detail : "the request failed")
	}
}

// The window leaves the document it shows (another one is coming, or one of its cache): a window a script opened keeps it frozen
// when it may (its entry still in the session, not the current one: a reload and location.replace give the entry another document),
// else it goes with its navigation.
@(private)
leave :: proc(d: ^Doc) {
	p := d.page
	d.page = nil
	if d.shown == nil { return }
	defer d.shown = nil
	if d.root == nil || p == nil || p.closed || page.bfcache_blockers(p) != {} { base.scope_close(d.shown); return }
	entry: u64
	for x in d.session.entries { if x.doc == page.page_id(p) { entry = x.id } }
	if entry == 0 || entry == page.session_current_id(&d.session) { base.scope_close(d.shown); return }
	page.page_freeze(p)
	if p.closed { base.scope_close(d.shown); return }
	// one page per entry; entries gone from the session (a push after going back) and the oldest past the count go
	for i := len(d.cached) - 1; i >= 0; i -= 1 {
		c := d.cached[i]
		if c.entry == entry || page.session_find(&d.session, c.entry) == nil || c.page.closed {
			ordered_remove(&d.cached, i)
			base.scope_close(c.scope)
		}
	}
	append(&d.cached, Cached_Page{entry = entry, scope = d.shown, page = p})
	for len(d.cached) > BFCACHE_MAX_PAGES { base.scope_close(pop_front(&d.cached).scope) }
}

// A traversal to `entry` (now the session's current one) whose document is in the cache: it comes back in a task of the window's
// next navigation, as a response would (a navigation that starts before it cancels it). False: not cached, the window loads the entry.
@(private)
bfcache_start :: proc(d: ^Doc, entry: u64) -> bool {
	found := false
	for c in d.cached { if c.entry == entry && !c.page.closed { found = true } }
	if !found { return false }
	if d.loading != nil { base.scope_close(d.loading) }
	d.loading, d.task, d.restoring = base.scope_make("navigation", d.scope), base.NIL_HANDLE, entry
	host.set_timer(&d.env.loop, 0, 0, proc(data: rawptr) { bfcache_restore((^Doc)(data)) }, d, d.loading)
	return true
}

// The document of the entry the window traverses to from the cache, thawed (pageshow persisted), in place of the one shown, which
// leaves as for any navigation.
@(private)
bfcache_restore :: proc(d: ^Doc) {
	at := -1
	for c, i in d.cached { if c.entry == d.restoring && !c.page.closed { at = i; break } }
	d.restoring = 0
	if at < 0 { return }
	c := d.cached[at]
	ordered_remove(&d.cached, at)
	leave(d)
	d.page, d.shown = c.page, c.scope
	delete(d.final_url)
	d.final_url = strings.clone(c.page.env.location.href)
	d.parsed = true
	page.navigable_attach(d.top, d.page)   // (its embedder and its entry are still its own)
	page.page_thaw(d.page)
}

@(private)
same_but_fragment :: proc(a, b: string) -> bool {
	ua, oka := url.parse(a, nil, context.temp_allocator)
	ub, okb := url.parse(b, nil, context.temp_allocator)
	return oka && okb && url.without_fragment(ua) == url.without_fragment(ub)
}

@(private)
document_parsed :: proc(p: ^page.Page, user: rawptr, pd: ^page.Parsed_Document) {
	d := (^Doc)(user)
	if !pd.decoded { d.failed = strings.clone("the document could not be decoded"); return }
	page.adopt_document(p, pd)
	if !p.render.adopted { page.render_begin(p) }
	d.parsed = true
	if d.on_parsed != nil { d.on_parsed(d) }
	page.scripts_start(p)
}

// Runs the event loop for at most `ms`, or until `until(d)` is true; animation frames run at the page's frame rate
// while it asks for them (in the windows it opened too). True when `until` became true.
pump :: proc(d: ^Doc, ms: f64, until: proc(d: ^Doc) -> bool = nil) -> bool {
	e := d.env
	start := time.tick_now()
	for {
		if until != nil && until(d) { return true }
		if time.duration_milliseconds(time.tick_since(start)) >= ms { return until != nil && until(d) }
		wait := 5
		wait = min(wait, run_frames(d))
		for w in d.popups { wait = min(wait, run_frames(w)) }
		host.loop_wait(&e.loop, wait)
	}
}

// The animation frames of a window's document, when it asks for them: how long until the next one, ms.
@(private)
run_frames :: proc(d: ^Doc) -> int {
	p := d.page
	if p == nil || p.closed || !page.wants_animation_frame(p) { return max(int) }
	e := d.env
	now := f64(host.now_ns(&e.loop)) / 1e6
	interval := page.frame_interval_ms(e.settings.web)
	if now - d.last_frame >= interval {
		d.last_frame = now
		page.run_animation_frames(p, now)
	}
	return max(0, int(interval - (now - d.last_frame)))
}

// Whether the document finished (failed, or parsed and every script ran: readyState complete).
loaded :: proc(d: ^Doc) -> bool {
	if d.failed != "" { return true }
	if d.page == nil || !d.parsed || (d.loading != nil && d.task != base.NIL_HANDLE) { return false }
	s := d.page.scripts
	return s == nil || s.ready_state == .Complete
}

// Closes the document, the windows it opened, and frees them.
close :: proc(d: ^Doc) {
	if d == nil { return }
	for len(d.popups) > 0 { doc_free(pop(&d.popups)) }
	delete(d.popups)
	doc_free(d)
}

@(private)
doc_free :: proc(d: ^Doc) {
	base.scope_close(d.scope)
	page.navigable_top_free(d.top)
	page.session_destroy(&d.session)
	delete(d.cached)   // (their scopes are the window's)
	if d.has_initiator { fetch.environment_destroy(&d.initiator) }
	for m in d.console { delete(m.text) }
	delete(d.console)
	for n in d.navigations { delete(n) }
	delete(d.navigations)
	delete(d.url); delete(d.final_url); delete(d.charset); delete(d.failed); delete(d.mime)
	free(d)
}
