// Package headless: documents loaded as the browser loads them, without a window, for the measuring tools (src/tools/wpt,
// src/tools/jspage). A document is navigated to with the network stack and the Fetch policy (fetch.start, destination
// document), parsed (off the UI thread when preferences say so), adopted, its scripts started; the event loop is
// pumped by the caller, animation frames are run at the configured frame rate while the page asks for them. The page is
// visible and has Web Storage (a profile folder of the caller's choice) and a session history of its own; navigations
// it asks for are recorded, not followed.
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
}

Message :: struct {
	level: page.Log_Level,
	text:  string,   // owned
}

Doc :: struct {
	env:       ^Env,
	scope:     ^base.Scope,     // the navigation: the request, then the page
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
	user:      rawptr,
	navigations: [dynamic]string,   // owned: what the page asked to navigate to
	last_frame: f64,
	created_ns: i64,
}

// Starts the stack: event loop, network client, blocking pool, the Fetch profile, the page settings (from `prefs` when
// given: --pref name=value of the command line, else the defaults). `profile_dir` holds Web Storage ("" = none).
init :: proc(e: ^Env, prefs: ^config.Prefs = nil, profile_dir := "", blocking_threads := 2) -> bool {
	host.loop_init(&e.loop)
	if !net.client_init(&e.client, &e.loop) { return false }
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

@(private)
navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	d := (^Doc)(user)
	append(&d.navigations, fmt.aprintf("%v %s", req.kind, req.url))
}

@(private)
doc_closed :: proc(data: rawptr) {
	d := (^Doc)(data)
	d.page = nil
	d.task = base.NIL_HANDLE
}

// Navigates a new document to `url`. Follow it with `pump`; `close` frees it.
open :: proc(e: ^Env, url: string, on_console: proc(d: ^Doc, level: page.Log_Level, text: string) = nil, user: rawptr = nil) -> ^Doc {
	d := new(Doc)
	d.env = e
	d.url = strings.clone(url)
	d.on_console = on_console
	d.user = user
	d.created_ns = host.now_ns(&e.loop)
	d.scope = base.scope_make("navigation", e.process)
	base.on_close(d.scope, doc_closed, d)
	d.task = fetch.start(&e.loader, {
		request = {url = d.url, mode = .Navigate, credentials = .Include, redirect = .Follow, destination = .Document},
		on_event = document_event, user = d, scope = d.scope, collect = true,
	})
	return d
}

@(private)
document_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	d := (^Doc)(user)
	e := d.env
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		d.status = r.status
		d.final_url = strings.clone(r.url)
		if r.has_mime {
			if cs, ok := http.mime_param(r.mime, "charset"); ok { d.charset = strings.clone(cs) }
		}
		d.page = page.page_create(&e.loop, &e.loader, &e.settings, d.scope, r.url, console_sink, d)
		page.set_embedder(d.page, {navigate = navigate_hook, user = d, tab_key = d.url, storage = e.has_storage ? &e.storage : nil})
		csp_h := http.get_all(r.headers, "content-security-policy")
		ro_h := http.get_all(r.headers, "content-security-policy-report-only")
		rp, _ := http.get_header(r.headers, "referrer-policy")
		page.apply_response_headers(d.page, csp_h, ro_h, rp)
	case .Done:
		d.task = base.NIL_HANDLE
		if d.page == nil { d.failed = strings.clone("no response"); return }
		page.parse_document(d.page, ev.data, d.charset, document_parsed, d)
	case .Failed:
		d.task = base.NIL_HANDLE
		d.failed = strings.clone(ev.detail != "" ? ev.detail : "the request failed")
	}
}

@(private)
document_parsed :: proc(p: ^page.Page, user: rawptr, pd: ^page.Parsed_Document) {
	d := (^Doc)(user)
	if !pd.decoded { d.failed = strings.clone("the document could not be decoded"); return }
	page.adopt_document(p, pd)
	if !p.render.adopted { page.render_begin(p) }
	d.parsed = true
	page.scripts_start(p)
}

// Runs the event loop for at most `ms`, or until `until(d)` is true; animation frames run at the page's frame rate
// while it asks for them. True when `until` became true.
pump :: proc(d: ^Doc, ms: f64, until: proc(d: ^Doc) -> bool = nil) -> bool {
	e := d.env
	start := time.tick_now()
	for {
		if until != nil && until(d) { return true }
		if time.duration_milliseconds(time.tick_since(start)) >= ms { return until != nil && until(d) }
		wait := 5
		if p := d.page; p != nil && !p.closed && page.wants_animation_frame(p) {
			now := f64(host.now_ns(&e.loop)) / 1e6
			interval := page.frame_interval_ms(e.settings.web)
			if now - d.last_frame >= interval {
				d.last_frame = now
				page.run_animation_frames(p, now)
			}
			wait = max(0, min(wait, int(interval - (now - d.last_frame))))
		}
		host.loop_wait(&e.loop, wait)
	}
}

// Whether the document finished (failed, or parsed and every script ran: readyState complete).
loaded :: proc(d: ^Doc) -> bool {
	if d.failed != "" { return true }
	if d.page == nil || !d.parsed { return false }
	s := d.page.scripts
	return s == nil || s.ready_state == .Complete
}

// Closes the document and frees it.
close :: proc(d: ^Doc) {
	if d == nil { return }
	base.scope_close(d.scope)
	for m in d.console { delete(m.text) }
	delete(d.console)
	for n in d.navigations { delete(n) }
	delete(d.navigations)
	delete(d.url); delete(d.final_url); delete(d.charset); delete(d.failed)
	free(d)
}
