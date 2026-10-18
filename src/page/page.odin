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
import "wb:base"
import "wb:csp"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
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
	callback:   u32,
	user:       u32,
	state:      i32,            // 0 pending, 1 response, 2 done, 3 failed
	status:     int,
	type:       fetch.Response_Type,
	redirected: bool,
	usable:     bool,
	headers:    string,
	final_url:  string,
	body:       [dynamic]byte,
	error:      string,
	error_kind: fetch.Error_Kind,
}

Timer :: struct {
	page:     ^Page,
	self:     base.Handle,
	instance: u32,
	handle:   base.Handle,     // the loop's timer
	callback: u32,
	user:     u32,
	interval: bool,
}

Page :: struct {
	scope:     ^base.Scope,
	loop:      ^host.Loop,
	loader:    ^fetch.Loader,
	settings:  ^Settings,     // shared, owned by the shell; follows preference changes
	env:       fetch.Environment,
	doc:       ^dom.Document,
	dp:        dom.Dispatcher,
	instances: [dynamic]^wasm.Instance,
	fetches:   base.Pool(Fetch),
	timers:    base.Pool(Timer),
	held:      int,            // bytes retained by fetch records
	console:   Console_Proc,
	console_user: rawptr,
	closed:    bool,
	body:      base.Handle,
	head:      base.Handle,
	doc_el:    base.Handle,
	objects:      Objects,              // promises, buffers and every other non-DOM object (objects.odin)
	host_reactions: [dynamic]Host_Reaction,
	// styling (styles.odin)
	engine:       ^style.Engine,
	styled:       ^style.Styled,
	style_state:  style.State,
	style_stale:  bool,
	link_loads:   map[base.Handle]^Style_Load,
	import_loads: [dynamic]^Style_Load,
	formctl:      ^Page_Forms,          // form controls (bindings_forms.odin)
}

// `parent` is the tab's scope (or the process scope). `document_url` defines the document's origin; an invalid URL gives
// about:blank. The page makes its own child scope.
page_create :: proc(loop: ^host.Loop, loader: ^fetch.Loader, settings: ^Settings, parent: ^base.Scope, document_url: string, console: Console_Proc = nil, console_user: rawptr = nil) -> ^Page {
	p := new(Page)
	p.scope = base.scope_make("page", parent)
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

	p.doc = dom.document_create(p.scope)
	p.dp.invoke = invoke_listener
	p.dp.user = p
	styles_init(p)
	forms_attach(p)
	blank_document(p)
	return p
}

// Closes the page and everything it owns. The pointer is dead afterwards.
page_close :: proc(p: ^Page) {
	if p == nil || p.closed { return }
	base.scope_close(p.scope)
}

@(private)
page_cleanup :: proc(data: rawptr) {
	p := (^Page)(data)
	p.closed = true
	// requests first: their callbacks reference the page
	it: u32
	for _, f in base.pool_next(&p.fetches, &it) {
		if f.task != base.NIL_HANDLE { fetch.cancel(p.loader, f.task) }
		free_fetch(f)
	}
	base.pool_destroy(&p.fetches)
	it = 0
	for _, t in base.pool_next(&p.timers, &it) { host.clear_timer(p.loop, t.handle) }
	base.pool_destroy(&p.timers)
	forms_detach(p)
	objects_destroy(p)   // before the dispatcher: an object's destructor may still look at events
	delete(p.host_reactions)
	styles_destroy(p)
	dom.dispatcher_destroy(&p.dp)
	delete(p.instances)
	fetch.environment_destroy(&p.env)
	free(p)
}

@(private)
free_fetch :: proc(f: ^Fetch) {
	delete(f.headers); delete(f.final_url); delete(f.error); delete(f.body)
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

// Applies the security headers of the document's own response (Content-Security-Policy[-Report-Only], Referrer-Policy).
apply_response_headers :: proc(p: ^Page, csp_values, csp_report_only_values: []string, referrer_policy_value: string) {
	for v in csp_values { csp.parse_header(&p.env.policies, v, .Enforce) }
	for v in csp_report_only_values { csp.parse_header(&p.env.policies, v, .Report_Only) }
	if referrer_policy_value != "" {
		if rp := fetch.parse_referrer_policy(referrer_policy_value); rp != .Default { p.env.referrer_policy = rp }
	}
}

// Replaces the blank skeleton by the parsed document, then applies <meta http-equiv="Content-Security-Policy"> and
// <meta name="referrer">. `utf8` is already decoded (see html.decode_document).
load_html :: proc(p: ^Page, utf8: []byte) -> html.Parse_Result {
	dom.set_text_content(p.doc, p.doc.root, "")
	r := html.parse_into(p.doc, p.doc.root, utf8, p.settings.html.max_nodes)
	p.doc_el = dom.find_first_by_tag(p.doc, "html")
	p.head = dom.find_first_by_tag(p.doc, "head")
	p.body = dom.find_first_by_tag(p.doc, "body")
	if p.body == base.NIL_HANDLE { blank_document(p) }   // parse failure: keep the page usable
	apply_meta(p)
	return r
}

@(private)
apply_meta :: proc(p: ^Page) {
	// iterative walk over the <head>/<body> for <meta> elements
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, p.doc.root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(p.doc, cur)
		if n == nil { continue }
		if n.kind == .Element && n.name == "meta" {
			content, _ := dom.get_attribute(p.doc, cur, "content")
			if he, ok := dom.get_attribute(p.doc, cur, "http-equiv"); ok && strings.equal_fold(he, "content-security-policy") {
				csp.parse_header(&p.env.policies, content, .Enforce)   // a <meta> policy cannot be report-only
			}
			if name, ok := dom.get_attribute(p.doc, cur, "name"); ok && strings.equal_fold(name, "referrer") {
				if rp := fetch.parse_referrer_policy(content); rp != .Default { p.env.referrer_policy = rp }
			}
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(p.doc, ch).prev { append(&stack, ch) }
	}
}

// Instantiates a module in the page scope and calls its `wb_main` export. Any number of modules may be loaded.
load_module :: proc(p: ^Page, image: []byte, name := "module") -> (inst: ^wasm.Instance, ok: bool, err: string) {
	inst, err = wasm.instance_create(image, p, p.scope, p.settings.wasm, name)
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
	if int(i) >= len(p.instances) { return nil }
	inst := p.instances[i]
	if inst == nil || inst.dead { return nil }
	return inst
}

// Delivers an event to the DOM (from the shell: input, or a synthetic one). False if default was prevented.
dispatch_event :: proc(p: ^Page, target: base.Handle, ev: dom.Event) -> bool {
	return dom.dispatch(p.doc, &p.dp, target, ev)
}

@(private)
invoke_listener :: proc(user: rawptr, l: dom.Listener, event: base.Handle) -> bool {
	p := (^Page)(user)
	inst := instance_by_index(p, l.owner)
	if inst == nil { return true }   // that module is gone: its listener has nothing to call
	argv := [3]u32{l.user, u32(u64(event)), u32(u64(event) >> 32)}   // (user: i32, event: i64)
	call_guest(p, inst, l.callback, argv[:])
	return true   // one failing listener does not stop the others
}
