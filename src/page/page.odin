// Package page: one loaded document = DOM + its Wasm instances + the resources that belong to it (requests, timers) and
// its security context (Environment: URL, origin, site, CSP, referrer policy).
//
// A Page owns a base.Scope. Everything the page starts (instances, DOM, in-flight requests, timers) is registered in that
// scope, so closing a tab is one call: `page_close`. Nothing the page started can outlive it or call into freed memory:
// late network events are dropped by the generational handles, timers are removed from the loop, instances are freed
// before the DOM they point to.
//
// A document runs as many modules as it names (<script type="application/wasm"> elements, in document order). Each
// module is a separate instance with its own linear memory; they share the DOM and the event loop. A listener, timer or
// request is delivered to the instance that created it.
package page

import "core:fmt"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:csp"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:http"
import "wb:style"
import "wb:url"
import "wb:wasm"

Log_Level :: enum i32 { Log, Warn, Error }

Console_Proc :: #type proc(user: rawptr, level: Log_Level, message: string)

Fetch :: struct {
	page:       ^Page,
	self:       base.Handle,
	instance:   u32,
	task:       base.Handle,    // the fetch task, NIL when finished
	sync_loader: ^fetch.Loader, // the task is of this loader, not the page's (a document's synchronous request)
	callback:   u32,
	user:       u32,
	state:      i32,            // 0 pending, 1 response, 2 done, 3 failed
	body_told:  time.Tick,      // when the callback last heard of a part of the body (state Body: fetch_tell_body)
	status:     int,
	type:       fetch.Response_Type,
	redirected: bool,
	usable:     bool,
	headers:    string,
	final_url:  string,
	status_text: string,
	head:       bool,           // to a HEAD: no body
	body:       [dynamic]byte,
	error:      string,
	error_kind: fetch.Error_Kind,
	ext:        ^Fetch_Ext,     // promise / stream / abort signal state (bindings_fetch.odin), nil for plain callback fetches
	event_source: ^Event_Source,   // a worker realm's EventSource (eventsource.odin)
	module:     ^Module_Entry,  // a worker realm fetching a module of its graph (js_load_modules.odin)
}

Timer :: struct {
	page:     ^Page,
	self:     base.Handle,
	instance: u32,
	handle:   base.Handle,     // the loop's timer
	callback: u32,
	user:     u32,
	interval: bool,
	user64:   u64,             // wide: the callback takes (user: i64)
	wide:     bool,
	delay:    f64,             // requested delay (ms), re-applied to each repetition of an interval
	nesting:  int,             // HTML timer nesting level
	throttled: bool,           // re-armed to the background wake-up grid: run on the next fire
}

Page :: struct {
	base_url:  Base_Url_Cache,   // the parsed base URL of the document (js_dom_tree.odin)
	scope:     ^base.Scope,
	tag:       u32,            // in the handles of its nodes, events and host objects (base.pool_insert_tagged)
	prior_tag: u32,            // the tag of what its Window made before its document was replaced in it (frame_keep_window); 0: none
	route_next:     u32,       // the tag the realm's next import acts on (Frame_target, frames_access.odin)
	route_busy:     int,       // import calls of other realms acting on this document now
	origin_owner:   u64,       // the page whose origin this document has (an about:blank or srcdoc frame's: its parent's; 0: its own): document.domain sets it for all of them
	dispatching:    int,       // events being dispatched at this document now (a listener of another realm may remove its frame)
	trusted_runs:   int,       // the browser's own scripts running now (js_run trusted): their eval passes the page's CSP
	checkpoint_owed: bool,     // a microtask checkpoint waits for those calls to end (frames_pay_checkpoint)
	close_pending:  bool,      // closed while in use: closes once nothing runs in it (frames_access.odin)
	frames_pending_parent: ^Page,   // the document it was a frame of, while it waits
	foreign_owners: [dynamic]Foreign_Owner,   // realms of other documents with listeners or callbacks here
	bridge_reply:   []u8,      // owned: the last reply of the value bridge (Frame_bridge)
	loop:      ^host.Loop,
	canvases:  ^Canvas_Page,   // its canvases, once one was asked for (canvas.odin); a worker's are its own thread's
	loader:    ^fetch.Loader,
	settings:  ^Settings,     // shared, owned by the shell; follows preference changes
	env:       fetch.Environment,
	doc:       ^dom.Document,
	encoding:  string,         // what the document was decoded from (WHATWG name, static: html.canonical_encoding); "" = UTF-8
	dp:        dom.Dispatcher,
	instances: [dynamic]^wasm.Instance,
	fetches:   base.Pool(Fetch),
	timers:    base.Pool(Timer),
	held:      int,            // bytes retained by fetch records
	console:   Console_Proc,
	console_user: rawptr,
	test_host:    ^Test_Host,   // a test program's (test_host.odin); a browser has none
	closed:    bool,
	body:      base.Handle,
	head:      base.Handle,
	doc_el:    base.Handle,
	objects:      Objects,              // promises, buffers and every other non-DOM object (objects.odin)
	pointer:      ^Pointer_Page,        // pointer capture and the pointers held (pointer_input.odin); freed when the page closes
	drag:         ^Drag_Session,        // the drag in progress (dnd_session.odin); freed when the page closes
	host_reactions: [dynamic]Host_Reaction,
	// styling (styles.odin)
	engine:       ^style.Engine,
	styled:       ^style.Styled,
	style_state:  style.State,
	forced:       Forced_State,   // :hover / :active / :focus / :visited the developer tools force on an element (devtools_api.odin)
	style_stale:  bool,
	link_loads:   map[base.Handle]^Style_Load,
	link_preloads: map[base.Handle]^Link_Preload,   // link_preload.odin
	scan:         ^Preload_Scan,        // the document's bytes being read as they arrive (preload_scan.odin)
	speculation:  ^fetch.Speculation,   // what was asked ahead of the parser (fetch/speculative.odin)
	import_loads: [dynamic]^Style_Load,
	web:          ^Web_State,           // platform web APIs (web.odin)
	names:        Name_Filter,          // what names the document's elements have (js_dom_collections.odin)
	formctl:      ^Page_Forms,          // form controls (bindings_forms.odin)
	// threads (worker.odin, offthread.odin)
	worker:       ^Worker_Global,       // non-nil: this Page is the global scope of a dedicated worker, on its thread, without a document
	workers:      Page_Workers,         // the workers this page started
	offthread:    Offthread_State,      // background parsing in flight
	crypto_jobs:  int,                  // computations of crypto.subtle in flight (bindings_crypto_subtle.odin)
	anim:         Page_Animations,      // transitions and animations (animations.odin)
	fonts:        Page_Fonts,           // @font-face downloads (fonts.odin)
	images:       Page_Images,          // <img>, CSS images, Image_decode (images.odin)
	render:       Render_Block,         // what the first paint waits for (render_blocking.odin)
	selection:    Page_Selection,       // the document's selection (selection.odin)
	highlights:   ^Page_Highlights,     // CSS.highlights (highlights.odin); nil until a script registers one
	js:           ^Js_Realm,            // the JavaScript realm, created on first use (js_realm.odin)
	ext:          ^Ext_Realm,           // the realm is an extension context: its extension and its events (ext_realm.odin); nil: a web page's
	worlds:       [dynamic]^World,      // the isolated worlds of extensions' content scripts, one engine instance each (ext_worlds.odin)
	ext_doc:      ^Ext_Doc,             // what extensions injected in this document and when (ext_inject.odin); nil: nothing yet
	wasm_store:   ^wasm.User_Store,     // what the page's JavaScript made with the WebAssembly API, on first use (webassembly.odin)
	font_face_sheets: [dynamic]^style.Sheet,   // of FontFace objects added to document.fonts (fontface.odin)
	blob_urls: ^[dynamic]string,   // what this realm's URL.createObjectURL made (bloburl.odin)
	scripts:      ^Page_Scripts,        // the document's <script> elements (js_scripts.odin)
	jsdom:        ^Js_Dom_State,        // the DOM bindings' state: selectors, observers, layout hook (js_dom_collections.odin)
	scroll_events: ^Scroll_Events,      // scroll offsets of the last frame, for scroll events (scroll_events.odin)
	link_sync_timer: base.Handle,       // a script inserted a <link>: the sheets are read again in this task (styles.odin)
	frames:       ^Page_Frames,         // nested browsing contexts: its navigable, its frames (frames.odin)
	media:        ^Page_Media,          // <video> / <audio> elements (media_element.odin)
	template_doc: Template_Doc,         // the inert document the contents of <template>s belong to (js_dom_tree.odin)
	fullscreen:   ^Page_Fullscreen,     // the document's fullscreen element, made on first use (fullscreen.odin)
	timeline:     ^Page_Timeline,       // Performance Timeline entries: navigation, resources, paints, slow input (timeline.odin)
	image_document: Image_Document,     // an image opened by itself: the viewer's state (image_document.odin)
}

// `parent` is the tab's scope (or the process scope). `document_url` defines the document's origin; an invalid URL gives
// about:blank. The page makes its own child scope.
page_create :: proc(loop: ^host.Loop, loader: ^fetch.Loader, settings: ^Settings, parent: ^base.Scope, document_url: string, console: Console_Proc = nil, console_user: rawptr = nil) -> ^Page {
	p := new(Page)
	p.scope = base.scope_make("page", parent)
	p.tag = base.tag_new()
	p.loop = loop
	p.loader = loader
	p.settings = settings
	p.console = console
	p.console_user = console_user
	base.on_close(p.scope, page_cleanup, p)   // registered first, so it runs last

	u, ok := url.parse_absolute(document_url, context.temp_allocator)
	if !ok { u, _ = url.parse_absolute("about:blank", context.temp_allocator) }
	p.env = fetch.environment_make(u)
	p.env.on_violation = csp_violation
	p.env.violation_user = p
	fetch.document_begin(loader, &p.env, p.scope)   // the content blocker's per-document state (fetch/intercept.odin)
	web_init(p)
	timeline_attach(p)   // its requests become Resource Timing entries (timeline.odin)

	p.doc = dom.document_create(p.scope, p.tag)
	shadow_doc_attached(p)
	p.dp.tag = p.tag
	p.dp.invoke = invoke_listener
	p.dp.user = p
	p.dp.window = window_phase   // js_dom_events.odin: the Window after the document in the propagation path
	p.dp.other = frames_dispatcher_of
	styles_init(p)
	forms_attach(p)
	blank_document(p)
	return p
}

// Closes the page and everything it owns. The pointer is dead afterwards.
page_close :: proc(p: ^Page) {
	if p == nil || p.closed { return }
	if frames_close_later(p) { return }
	base.scope_close(p.scope)
}

@(private)
page_cleanup :: proc(data: rawptr) {
	p := (^Page)(data)
	p.closed = true
	frames_closed(p)
	preload_scan_end(p)
	fetch.speculation_destroy(p.speculation)
	p.speculation = nil
	// requests first: their callbacks reference the page
	it: u32
	for _, f in base.pool_next(&p.fetches, &it) {
		// a worker's requests run on the UI thread and are cancelled there when the worker stops
		if f.task != base.NIL_HANDLE && p.worker == nil { fetch.cancel(p.loader, f.task) }
		free_fetch(f)
	}
	base.pool_destroy(&p.fetches)
	it = 0
	for _, t in base.pool_next(&p.timers, &it) { host.clear_timer(p.loop, t.handle) }
	base.pool_destroy(&p.timers)
	forms_detach(p)
	media_destroy(p)    // before the objects: play() promises and the players' notices
	images_destroy(p)   // before the objects: decode() promises are objects
	objects_destroy(p)   // before the dispatcher: an object's destructor may still look at events
	web_destroy(p)
	workers_destroy(p)   // after the Worker objects: stops and joins every thread this page started
	offthread_destroy(p)
	delete(p.host_reactions)
	if p.engine != nil { styles_destroy(p) }
	dom.dispatcher_destroy(&p.dp)
	delete(p.instances)
	delete(p.foreign_owners)
	delete(p.bridge_reply)
	delete(p.style_state.target_id)
	fetch.document_end(p.loader, &p.env)
	fetch.environment_destroy(&p.env)
	free(p)
}

@(private)
free_fetch :: proc(f: ^Fetch) {
	delete(f.headers); delete(f.final_url); delete(f.status_text); delete(f.error); delete(f.body)
	fetch_ext_free(f)
}

@(private)
blank_document :: proc(p: ^Page) {
	d := p.doc
	p.doc_el = dom.create_element(d, "html")
	p.head = dom.create_element(d, "head")
	p.body = dom.create_element(d, "body")
	dom.append_child(d, d.root, p.doc_el)
	dom.append_child(d, p.doc_el, p.head)
	dom.append_child(d, p.doc_el, p.body)
}

log :: proc(p: ^Page, level: Log_Level, message: string) {
	if p.console != nil { p.console(p.console_user, level, message) }
}

@(private)
csp_violation :: proc(user: rawptr, v: csp.Violation) {
	p := (^Page)(user)
	log(p, v.enforced ? .Error : .Warn, fmt.tprintf("Content-Security-Policy%s: %s violated by %s", v.enforced ? "" : " (report only)", v.directive, v.blocked))
}

// security.csp.enabled: off, no policy is taken from the document (headers, <meta>, a worker's script): the requests,
// inline scripts, eval and javascript: URLs of the page are then all allowed.
@(private)
csp_on :: proc(p: ^Page) -> bool {
	return p.loader == nil || p.loader.profile == nil || p.loader.profile.settings.csp
}

// Applies the security headers of the document's own response (Content-Security-Policy[-Report-Only], Referrer-Policy).
apply_response_headers :: proc(p: ^Page, csp_values, csp_report_only_values: []string, referrer_policy_value: string) {
	if csp_on(p) {
		for v in csp_values { csp.parse_header(&p.env.policies, v, .Enforce) }
		for v in csp_report_only_values { csp.parse_header(&p.env.policies, v, .Report_Only) }
		csp_sandbox_apply(p)   // (frames_csp.odin)
	}
	if referrer_policy_value != "" {
		if rp := fetch.parse_referrer_policy(referrer_policy_value); rp != .Default { p.env.referrer_policy = rp }
	}
}

// Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy of the document's own response: HTML's cross-origin isolated
// capability. A frame (`parent`) has it from its parent, when of the same origin; it has no opener policy of its own.
// What makes a SharedArrayBuffer safe here is that a realm cannot read another's memory at all (each is a Wasm instance): the
// embedder policy still holds, since what such a page may read is what the web expects of it.
// A top-level document's opener policy is matched with that of the document it replaces (auxiliary.odin): a mismatch puts its
// navigable in a new browsing context group. A document that is no secure context has none (unsafe-none).
apply_isolation_headers :: proc(p: ^Page, headers: http.Headers, parent: ^Page = nil) {
	// a frame of its parent's origin is in its parent's agent cluster, a secure context or not (a WebAssembly.Module goes between them)
	same := parent != nil && url.same_origin(p.env.origin, parent.env.origin)
	if same { page_join_cluster(p, parent) }
	// HTML "obtain a similar-origin window agent": Origin-Agent-Cluster (a structured boolean) asks for an origin-keyed one
	// (absent: keyed by site); a cross-origin isolated document's is origin-keyed too (below)
	oac, _ := http.get_header(headers, "origin-agent-cluster")
	p.env.origin_keyed = strings.trim_space(oac) == "?1"
	defer if p.env.cross_origin_isolated { p.env.origin_keyed = true }
	if !p.env.secure_context {
		if parent == nil { navigable_commit_policy(page_navigable(p), p, .Unsafe_None) }
		return
	}
	coep, _ := http.get_header(headers, "cross-origin-embedder-policy")
	p.env.embedder_policy = parse_embedder_policy(coep)
	coop, _ := http.get_header(headers, "cross-origin-opener-policy")
	if parent == nil { navigable_commit_policy(page_navigable(p), p, opener_policy_parse(http.get_all(headers, "cross-origin-opener-policy"), p.env.embedder_policy)) }
	if parent != nil {
		p.env.cross_origin_isolated = parent.env.cross_origin_isolated && same && p.env.embedder_policy != .Unsafe_None
		return
	}
	value := strings.trim_space(strings.split(coop, ";", context.temp_allocator)[0])
	p.env.cross_origin_isolated = value == "same-origin" && p.env.embedder_policy != .Unsafe_None
}

parse_embedder_policy :: proc(value: string) -> fetch.Embedder_Policy {
	switch strings.trim_space(strings.split(value, ";", context.temp_allocator)[0]) {
	case "require-corp": return .Require_Corp
	case "credentialless": return .Credentialless
	}
	return .Unsafe_None
}

// `p` is in the agent cluster of `of` (a frame of its parent's origin, a window's initial document of its opener's).
@(private)
page_join_cluster :: proc(p, of: ^Page) {
	p.env.agent_cluster = page_cluster(of)
	wasm.user_cluster_retain(p.env.agent_cluster)
	base.on_close(p.scope, proc(data: rawptr) { wasm.user_cluster_release(u64(uintptr(data))) }, rawptr(uintptr(p.env.agent_cluster)))
}

// The page's agent cluster, made the first time it matters.
page_cluster :: proc(p: ^Page) -> u64 {
	if p.env.agent_cluster == 0 {
		p.env.agent_cluster = wasm.user_cluster_new()
		base.on_close(p.scope, proc(data: rawptr) { wasm.user_cluster_release(u64(uintptr(data))) }, rawptr(uintptr(p.env.agent_cluster)))
	}
	return p.env.agent_cluster
}

// Replaces the blank skeleton by the parsed document, then applies <meta http-equiv="Content-Security-Policy"> and
// <meta name="referrer">. `utf8` is already decoded (see html.decode_document).
// Synchronous, on the calling thread; `parse_document` + `adopt_document` is the same with decoding, off the UI thread.
// `mime` an XML type (xml_document_kind): parsed as XML (offthread.odin).
load_html :: proc(p: ^Page, utf8: []byte, mime := "") -> html.Parse_Result {
	j := html_job_make(p, utf8, false, "")
	defer html_job_free(j)
	j.page = nil
	if kind := xml_document_kind(mime); kind != .None { j.xml, j.location = kind, strings.clone(p.env.location.href) }
	html_work(j)
	return adopt_document(p, &j.out)
}

@(private)
apply_meta :: proc(p: ^Page) {
	// iterative walk over the <head>/<body> for <meta> elements
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, p.doc.root)
	script_seen := false
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(p.doc, cur)
		if n == nil { continue }
		// (document order. The first script the reveal stops at, as scripts_start finds it: a <meta> after it is revealed later)
		if is_script_element(n) {
			if _, ok := script_kind_of(p.doc, cur); ok { script_seen = true }
		}
		if n.kind == .Element && n.name == "meta" {
			content, _ := dom.get_attribute(p.doc, cur, "content")
			if he, ok := dom.get_attribute(p.doc, cur, "http-equiv"); ok && base.ascii_equal_fold(he, "content-security-policy") && csp_on(p) {
				before := len(p.env.policies.policies)
				csp.parse_header(&p.env.policies, content, .Enforce)   // a <meta> policy cannot be report-only
				if script_seen {
					for &pol in p.env.policies.policies[before:] { pol.held_by = u64(cur) }
				}
			}
			if he, ok := dom.get_attribute(p.doc, cur, "http-equiv"); ok && base.ascii_equal_fold(he, "refresh") { meta_refresh(p, content) }
			if name, ok := dom.get_attribute(p.doc, cur, "name"); ok && base.ascii_equal_fold(name, "referrer") {
				if rp := fetch.parse_referrer_policy(content); rp != .Default { p.env.referrer_policy = rp }
			}
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(p.doc, ch).prev { append(&stack, ch) }
	}
}

Meta_Refresh :: struct {
	loaded: bool,   // the document was seen complete
	page: ^Page,
	url:  string,
	delay: f64,
}

META_REFRESH_MS_PER_S :: 1000

// <meta http-equiv="refresh" content="N; url=...">, or "N": a delay alone reloads the document ("" for the URL).
@(private)
meta_refresh_parse :: proc(content: string) -> (delay: f64, target: string, ok: bool) {
	s := strings.trim_space(content)
	i := 0
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == '.') { i += 1 }
	if i == 0 { return }
	whole, frac, scale := 0.0, 0.0, 1.0
	seen_dot := false
	for c in transmute([]byte)s[:i] {
		if c == '.' { seen_dot = true } else if seen_dot { scale /= 10; frac += f64(c - '0') * scale } else { whole = whole * 10 + f64(c - '0') }
	}
	rest := strings.trim_left(s[i:], " \t\r\n;,")
	if rest == "" { return whole + frac, "", true }
	if len(rest) >= 3 && base.ascii_equal_fold(rest[:3], "url") {
		rest = strings.trim_left(rest[3:], " \t\r\n")
		if len(rest) == 0 || rest[0] != '=' { return }
		rest = strings.trim_left(rest[1:], " \t\r\n")
	}
	if len(rest) > 0 && (rest[0] == '\'' || rest[0] == '"') {
		q := rest[0]
		rest = rest[1:]
		if e := strings.index_byte(rest, q); e >= 0 { rest = rest[:e] }
	}
	if rest == "" { return }
	return whole + frac, rest, true
}

@(private)
meta_refresh :: proc(p: ^Page, content: string) {
	delay, rest, parsed := meta_refresh_parse(content)
	if !parsed { return }
	href := ""   // (none: a delay alone reloads the document)
	if rest != "" {
		target, ok := url.parse(rest, &p.env.location, context.temp_allocator)
		if !ok || (target.scheme != "http" && target.scheme != "https" && target.scheme != "file") { return }
		href = target.href
	}
	m := new(Meta_Refresh)
	m^ = Meta_Refresh{page = p, url = strings.clone(href), delay = delay}
	host.set_timer(p.loop, delay * META_REFRESH_MS_PER_S, 0, meta_refresh_fire, m, p.scope)
}

// HTML "refresh": once the document has completely loaded, a navigation as a script's would be, with its navigate event.
@(private = "file")
meta_refresh_fire :: proc(data: rawptr) {
	m := (^Meta_Refresh)(data)
	p := m.page
	// (one turn more once it has: its container's load event goes first)
	if !p.closed && !m.loaded {
		// (a frame's document, a window's initial about:blank: their frames state says; a tab's, its scripts' load)
		f := frame_navigable_of(p) != nil ? p.frames : nil
		m.loaded = f != nil ? f.complete : (p.frames != nil && p.frames.complete) || p.scripts == nil || p.scripts.timing.load_end_ms != 0
		host.set_timer(p.loop, p.settings.js_load.poll_ms, 0, meta_refresh_fire, m, p.scope)
		return
	}
	defer { delete(m.url); free(m) }
	if p.closed { return }
	if m.url == "" {
		navigation_reload(p, {})
	} else if target, ok := url.parse(m.url, nil, context.temp_allocator); ok {
		location_navigate(p, target, m.delay == 0)
	}
}

// Instantiates a module in the page scope and calls its `wb_main` export. Any number of modules may be loaded.
load_module :: proc(p: ^Page, image: []byte, name := "module") -> (inst: ^wasm.Instance, ok: bool, err: string) {
	return instantiate(p, image, name, p.settings.wasm, nil)
}

@(private)
instantiate :: proc(p: ^Page, image: []byte, name: string, opt: wasm.Options, filter: wasm.Import_Filter) -> (inst: ^wasm.Instance, ok: bool, err: string) {
	inst, err = wasm.instance_create(image, p, p.scope, opt, name, filter)
	if inst == nil { return nil, false, err }
	inst.index = u32(len(p.instances))
	append(&p.instances, inst)
	if wasm.has_export(inst, "wb_main") {
		p.objects.depth += 1
		res := wasm.call_raw(inst, "wb_main")
		p.objects.depth -= 1
		if res != .Ok { return inst, false, strings.clone(inst.last_error) }
		if p.objects.depth == 0 { microtask_checkpoint(p) }
	}
	return inst, true, ""
}

@(private)
instance_by_index :: proc(p: ^Page, i: u32) -> ^wasm.Instance {
	if i & FOREIGN_OWNER != 0 { return foreign_owner_instance(p, i) }
	if int(i) >= len(p.instances) { return nil }
	inst := p.instances[i]
	if inst == nil || inst.dead { return nil }
	return inst
}

// Delivers an event to the DOM (from the shell: input, or a synthetic one). False if default was prevented.
dispatch_event :: proc(p: ^Page, target: base.Handle, ev: dom.Event) -> bool {
	webauthn_note_input(p, ev)   // HTML transient activation (bindings_webauthn.odin)
	media_note_input(p, ev)      // sticky activation for autoplay (media_element.odin)
	ev := ev
	if timeline_is_discrete_input(ev.type) { timeline_layout_shift_input(p) }   // stops LCP, marks layout shifts near input
	if dom.ui_composed(ev.type) { loaf_note_ui_event(p) }   // Long Animation Frames: firstUIEventTimestamp
	timed := timeline_event_begin(p, &ev)   // Event Timing (timeline.odin)
	p.dispatching += 1   // (not freed under its own dispatch: frames_close_later)
	ok := dom.dispatch(p.doc, &p.dp, target, ev)
	p.dispatching -= 1
	if timed != 0 { timeline_event_end(p, &ev, timed) }
	if (ev.type == "pointerdown" || ev.type == "pointerup") && !ev.untrusted && !p.closed { dialog_light_dismiss(p, ev.type == "pointerdown", target, ev.x, ev.y) }
	return ok
}

@(private)
invoke_listener :: proc(user: rawptr, l: dom.Listener, event: base.Handle) -> bool {
	p := (^Page)(user)
	inst := instance_by_index(p, l.owner)
	if inst == nil { return true }   // that module is gone: its listener has nothing to call
	argv := [3]u32{l.user, u32(u64(event)), u32(u64(event) >> 32)}   // (user: i32, event: i64)
	loaf_set_invoker(p, .Event_Listener, dom.event_type(&p.dp, event))   // Long Animation Frames: invoker = event type
	scope := host.work_enter(p.loop, callback_work(l.work, p.loop.work.class))
	call_guest(p, inst, l.callback, argv[:])
	host.work_leave(p.loop, scope)
	return true   // one failing listener does not stop the others
}
