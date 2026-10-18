// Package page: one loaded document = DOM + Wasm instance + the resources that belong to it (requests, timers).
//
// A Page owns a base.Scope. Everything the page starts (the instance, the DOM, in-flight requests, timers) is
// registered in that scope, so closing a tab is one call: `page_close`. Nothing the page started can outlive it or
// call into freed memory: late network events are dropped by the generational request handle, timers are removed
// from the loop, the instance is freed before the DOM it points to.
package page

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:net"
import "wb:wasm"

Log_Level :: enum i32 { Log, Warn, Error }

Console_Proc :: #type proc(user: rawptr, level: Log_Level, message: string)

Fetch :: struct {
	page:      ^Page,
	self:      base.Handle,
	request:   base.Handle,    // net request, NIL when finished
	callback:  u32,
	user:      u32,
	state:     i32,            // 0 pending, 1 headers, 2 done, 3 failed
	status:    int,
	headers:   string,
	final_url: string,
	body:      [dynamic]byte,
	error:     string,
}

Timer :: struct {
	page:     ^Page,
	self:     base.Handle,
	handle:   base.Handle,     // the loop's timer
	callback: u32,
	user:     u32,
	interval: bool,
}

Page :: struct {
	scope:    ^base.Scope,
	loop:     ^host.Loop,
	client:   ^net.Client,
	doc:      ^dom.Document,
	dp:       dom.Dispatcher,
	inst:     ^wasm.Instance,
	fetches:  base.Pool(Fetch),
	timers:   base.Pool(Timer),
	url:      string,
	console:  Console_Proc,
	console_user: rawptr,
	closed:   bool,
	body:     base.Handle,
	head:     base.Handle,
	doc_el:   base.Handle,
}

// `parent` is the tab's scope (or the process scope). The page makes its own child scope.
page_create :: proc(loop: ^host.Loop, client: ^net.Client, parent: ^base.Scope, console: Console_Proc = nil, console_user: rawptr = nil) -> ^Page {
	p := new(Page)
	p.scope = base.scope_make("page", parent)
	p.loop = loop
	p.client = client
	p.console = console
	p.console_user = console_user
	base.on_close(p.scope, page_cleanup, p)   // runs last: registered first
	p.doc = dom.document_create(p.scope)
	p.dp.invoke = invoke_listener
	p.dp.user = p
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
		if f.request != base.NIL_HANDLE { net.cancel(p.client, f.request) }
		delete(f.headers); delete(f.final_url); delete(f.error); delete(f.body)
	}
	base.pool_destroy(&p.fetches)
	it = 0
	for _, t in base.pool_next(&p.timers, &it) { host.clear_timer(p.loop, t.handle) }
	base.pool_destroy(&p.timers)
	dom.dispatcher_destroy(&p.dp)
	delete(p.url)
	free(p)
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

// Loads and starts a module: instantiates it in the page scope and calls its `wb_main` export.
load_module :: proc(p: ^Page, image: []byte, name := "page") -> (ok: bool, err: string) {
	if p.inst != nil { return false, "a module is already loaded" }
	inst, e := wasm.instance_create(image, p, p.scope, {}, name)
	if inst == nil { return false, e }
	p.inst = inst
	if wasm.has_export(inst, "wb_main") {
		if res := wasm.call_raw(inst, "wb_main"); res != .Ok {
			return false, strings.clone(inst.last_error)
		}
	}
	return true, ""
}

// Delivers an event to the DOM (from the shell: input, or a synthetic one). False if default was prevented.
dispatch_event :: proc(p: ^Page, target: base.Handle, ev: dom.Event) -> bool {
	return dom.dispatch(p.doc, &p.dp, target, ev)
}

@(private)
invoke_listener :: proc(user: rawptr, l: dom.Listener, event: base.Handle) -> bool {
	p := (^Page)(user)
	if p.inst == nil || p.inst.dead { return false }
	argv := [3]u32{l.user, u32(u64(event)), u32(u64(event) >> 32)}   // (user: i32, event: i64)
	res := wasm.call_indirect(p.inst, l.callback, argv[:])
	if res != .Ok {
		log(p, .Error, p.inst.last_error)
		return true   // one failing listener does not stop the others
	}
	return true
}
