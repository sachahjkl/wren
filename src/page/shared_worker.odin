package page

// Shared workers (HTML "shared workers"), the browser's side. A shared worker is a JavaScript worker (worker.odin,
// js_workers.odin) that every document of one storage key naming the same (URL, name) shares:
//
//   * It is hosted by a page of its own that shows nothing (as a service worker is: service_worker.odin), so it lives
//     on whatever documents come and go; its realm's global is a SharedWorkerGlobalScope (js_realm.odin).
//   * new SharedWorker() in a document makes a SharedWorker object there and a pair of port ends (ports.odin): the
//     document's port takes one, the other travels to the worker in a Connect message, where it becomes the port of a
//     `connect` event (runtime/shared_workers.c). From then on the two ports talk through the router, thread to thread.
//   * Its owners are the documents that connected and are still open. When the last one closes, the worker stops (or,
//     made with {extendedLifetime: true}, after shared_workers.extended_lifetime_ms, unless a document connects again).
//     A worker that called close() or whose script failed is no longer matched: the next constructor starts another.
//   * Its script failing to load (or a module graph failing) fires a plain `error` event at every SharedWorker object
//     connected to it; its uncaught errors are its own (its onerror) and reach the consoles of its documents.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:host"
import "wb:url"

Shared_Worker :: struct {
	id:       u64,
	key:      string,                  // the storage key of the documents that share it
	url:      string,                  // the script's URL as the constructor resolved it
	name:     string,
	module:   bool,
	extended: bool,                    // a constructor asked for {extendedLifetime: true}
	host_page: ^Page,                  // the page hosting the worker
	worker:   ^Worker_Host,
	loop:     ^host.Loop,
	owners:   [dynamic]u64,            // open documents that connected (page ids)
	conns:    [dynamic]^Shared_Conn,   // the SharedWorker objects
	linger:   base.Handle,             // extended lifetime: the timer that stops it
	gone:     bool,                    // closed, failed or stopping: not matched any more
}

// A SharedWorker object (its data).
Shared_Conn :: struct {
	worker: ^Shared_Worker,   // nil once the worker is gone
	page:   u64,
	self:   u64,              // the SharedWorker object in `page`
	end:    u64,              // its port's end, until the engine takes it (SharedWorker_portEnd)
}

@(private) shared_workers: [dynamic]^Shared_Worker
@(private) shared_next: u64
@(private) shared_scope: ^base.Scope   // the host pages' parent

shared_worker_vt := Object_VTable{
	name = "SharedWorker",
	destroy = proc(p: ^Page, data: rawptr) {
		c := (^Shared_Conn)(data)
		if c.end != 0 { port_close_end(c.end) }
		if s := c.worker; s != nil {
			for x, i in s.conns { if x == c { unordered_remove(&s.conns, i); break } }
		}
		free(c)
	},
}

@(private)
shared_console :: proc(user: rawptr, level: Log_Level, message: string) {
	s := (^Shared_Worker)(user)
	text := strings.has_prefix(message, "[worker ") ? message : fmt.tprintf("[shared worker %s] %s", s.name != "" ? s.name : s.url, message)
	for id in s.owners { if pg := page_by_id(id); pg != nil && !pg.closed { log(pg, level, text) } }
}

@(private)
shared_by_id :: proc(id: u64) -> ^Shared_Worker {
	for s in shared_workers { if s.id == id { return s } }
	return nil
}

// Starts the shared worker of (key, href, name) in a host page made like `p` (its loop, loader, settings, storage).
@(private)
shared_start :: proc(p: ^Page, href, name, key: string, module: bool) -> ^Shared_Worker {
	if shared_scope == nil { shared_scope = base.scope_make("shared-workers") }
	s := new(Shared_Worker)
	shared_next += 1
	s.id = shared_next
	s.key, s.url, s.name, s.module, s.loop = strings.clone(key), strings.clone(href), strings.clone(name), module, p.loop
	hp := page_create(p.loop, p.loader, p.settings, shared_scope, p.env.location.href, shared_console, s)
	hp.web.embedder.storage = p.web.embedder.storage
	obj := worker_create(hp, href, name, 0, javascript = true, module = module)
	h := (^Worker_Host)(object_data(hp, obj, &worker_vt)) if obj != 0 else nil
	if h == nil {
		page_close(hp)
		shared_free(s)
		return nil
	}
	h.shared = s
	h.storage_key = strings.clone(key)
	s.host_page, s.worker = hp, h
	append(&shared_workers, s)
	return s
}

@(private)
shared_free :: proc(s: ^Shared_Worker) {
	delete(s.key); delete(s.url); delete(s.name)
	delete(s.owners); delete(s.conns)
	free(s)
}

// Stops the worker (its host page closes: the thread is joined) and forgets it.
@(private)
shared_destroy :: proc(s: ^Shared_Worker) {
	for x, i in shared_workers { if x == s { ordered_remove(&shared_workers, i); break } }
	s.gone = true
	gone := make([dynamic]Shared_Conn, 0, len(s.conns), context.temp_allocator)
	for c in s.conns { c.worker = nil; append(&gone, c^) }
	clear(&s.conns)
	for c in gone {   // their objects may be collected now (a collection releases them: the copies are what is read)
		if pg := page_by_id(c.page); pg != nil && !pg.closed { js_worker_gone(pg, c.self) }
	}
	if s.linger != base.NIL_HANDLE { host.clear_timer(s.loop, s.linger); s.linger = base.NIL_HANDLE }
	if hp := s.host_page; hp != nil { s.host_page, s.worker = nil, nil; page_close(hp) }
	shared_free(s)
}

// The worker closed itself or its thread ended: not matched any more, stopped from a task of its own (this runs while
// its host handles one of its messages).
shared_gone :: proc(h: ^Worker_Host) {
	s := h.shared
	if s == nil || s.gone { return }
	s.gone = true
	host.post(s.loop, shared_reap, rawptr(uintptr(s.id)))
}

@(private)
shared_reap :: proc(data: rawptr) {
	if s := shared_by_id(u64(uintptr(data))); s != nil { shared_destroy(s) }
}

// Its script could not be fetched or did not run: `error` at every SharedWorker object connected to it.
shared_failed :: proc(h: ^Worker_Host, message: string) {
	s := h.shared
	if s == nil { return }
	shared_console(s, .Error, message)
	for c in s.conns { shared_error_later(c) }
	shared_gone(h)
}

// A plain `error` event at the SharedWorker object, from a task of its document.
@(private)
shared_error_later :: proc(c: ^Shared_Conn) {
	pg := page_by_id(c.page)
	if pg == nil || pg.closed { return }
	box := new(u64)
	box^ = c.self
	post_page_task(pg, proc(p: ^Page, data: rawptr) {
		h := (^u64)(data)^
		free(data)
		if p == nil || p.closed || object_data(p, h, &shared_worker_vt) == nil { return }
		object_dispatch(p, h, {type = "error"})
	}, box)
}

// A document closes: it no longer owns the shared workers it connected to; one without owners stops.
shared_workers_page_closed :: proc(p: ^Page) {
	if len(shared_workers) == 0 || p.web == nil { return }
	id := p.web.id
	for i := len(shared_workers) - 1; i >= 0; i -= 1 {
		if i >= len(shared_workers) { continue }
		s := shared_workers[i]
		owned := false
		for o, k in s.owners { if o == id { ordered_remove(&s.owners, k); owned = true; break } }
		if !owned || len(s.owners) > 0 || s.gone { continue }
		linger := p.settings.sw.shared_linger_ms
		if s.extended && linger > 0 {
			if s.linger == base.NIL_HANDLE { s.linger = host.set_timer(s.loop, f64(linger), 0, shared_linger_done, rawptr(uintptr(s.id))) }
			continue
		}
		// stopped from a task: the document is in the middle of closing
		s.gone = true
		host.post(s.loop, shared_reap, rawptr(uintptr(s.id)))
	}
}

@(private)
shared_linger_done :: proc(data: rawptr) {
	s := shared_by_id(u64(uintptr(data)))
	if s == nil { return }
	s.linger = base.NIL_HANDLE
	if len(s.owners) == 0 { shared_destroy(s) }
}

// Every shared worker stops (the profile's storage closes, or the process ends).
shared_workers_shutdown :: proc() {
	for len(shared_workers) > 0 { shared_destroy(shared_workers[len(shared_workers) - 1]) }
	delete(shared_workers)
	shared_workers = nil
	if shared_scope != nil { base.scope_close(shared_scope); shared_scope = nil }
}

////////////////////////////////
// Module "scripts", a document's side

SharedWorker_connect :: proc(c: ^Call, u: string, name: string, type: Api_WorkerType, extended_lifetime: bool) -> (u64, Api_Error) {
	p := c.page
	if p.worker != nil || p.web == nil { return 0, fail(c, .Not_Supported, "NotSupportedError: a shared worker is started from a document") }
	if !p.settings.sw.shared_enabled || !p.settings.workers.enabled || !p.settings.js.workers {
		log(p, .Error, "SharedWorker: shared workers are disabled (shared_workers.enabled, workers.enabled, javascript.workers.enabled)")
		return 0, fail(c, .Not_Allowed, "NotAllowedError: shared workers are disabled")
	}
	pu, ok := url.parse(u, &p.env.location, context.temp_allocator)
	if !ok { return 0, fail(c, .Syntax, fmt.tprintf("SyntaxError: %q is not a valid URL", u)) }
	if pu.scheme != "data" && !url.same_origin(url.origin_of(pu, context.temp_allocator), p.env.origin) {
		return 0, fail(c, .Security, fmt.tprintf("SecurityError: %s is not same-origin with the document", pu.href))
	}
	key := storage_origin_key(p)
	module := type == .Module
	s: ^Shared_Worker
	for x in shared_workers { if !x.gone && x.key == key && x.url == pu.href && x.name == name { s = x; break } }
	mismatch := s != nil && s.module != module   // HTML: an error event, no connection
	if s == nil {
		s = shared_start(p, pu.href, name, key, module)
		if s == nil { return 0, fail(c, .Not_Allowed, "NotAllowedError: the shared worker was refused (see the console)") }
	}
	if extended_lifetime { s.extended = true }
	if s.linger != base.NIL_HANDLE { host.clear_timer(s.loop, s.linger); s.linger = base.NIL_HANDLE }
	frames_of(p)   // its cleanup tells shared_workers_page_closed (frames.odin)
	id := page_id(p)
	known := false
	for o in s.owners { if o == id { known = true; break } }
	if !known { append(&s.owners, id) }
	conn := new(Shared_Conn)
	conn.worker, conn.page = s, id
	conn.self = object_create(p, &shared_worker_vt, conn, c.owner)
	append(&s.conns, conn)
	a := port_pair(p)
	conn.end = a
	if mismatch {
		port_close_end(a + 1)   // the document's port stays disentangled
		log(p, .Error, fmt.tprintf("SharedWorker: %s (%q) already runs as a %s worker", pu.href, name, s.module ? "module" : "classic"))
		shared_error_later(conn)
	} else {
		m := new(Worker_Msg)
		m.kind = .Connect
		m.ports = make([]u64, 1)
		m.ports[0] = a + 1
		link_send(s.worker.link, true, m)
	}
	return conn.self, .None
}

SharedWorker_portEnd :: proc(c: ^Call, w: u64) -> u64 {
	conn := (^Shared_Conn)(object_data(c.page, w, &shared_worker_vt))
	if conn == nil { return 0 }
	e := conn.end
	conn.end = 0
	return e
}

////////////////////////////////
// The worker's side (its thread)

// A connection arrived: its port end waits for the engine's connect event.
shared_connect_event :: proc(p: ^Page, m: ^Worker_Msg) {
	g := p.worker
	if len(m.ports) != 1 { return }
	end := m.ports[0]
	delete(m.ports)
	m.ports = nil
	if !g.shared || g.closing { port_close_end(end); return }
	append(&g.connects, end)
	if r := js_realm(p); r != nil {
		js_call(p, r.inst, "wj_shared_connect", nil)
		js_after_task(p, r, "connect")
	}
}

SharedWorkerGlobalScope_takeConnection :: proc(c: ^Call) -> u64 {
	g := c.page.worker
	if g == nil || len(g.connects) == 0 { return 0 }
	e := g.connects[0]
	ordered_remove(&g.connects, 0)
	return e
}

SharedWorkerGlobalScope_close :: proc(c: ^Call) -> Api_Error {
	p := c.page
	if p.worker == nil || !p.worker.shared { return fail(c, .Invalid_Argument, "not in a shared worker") }
	worker_close(p)
	return .None
}

SharedWorkerGlobalScope_name :: proc(c: ^Call) -> (string, Api_Error) {
	p := c.page
	if p.worker == nil || !p.worker.shared { return "", fail(c, .Invalid_Argument, "not in a shared worker") }
	return p.worker.name, .None
}
