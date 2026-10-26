package page

// Nested workers (HTML "workers": new Worker() in a dedicated or a shared worker). The machinery is worker.odin's; a
// worker's realm can neither start a thread of the browser nor load anything (the loader lives on the interface
// thread), so:
//   * the parent's thread makes the child's link and its Worker object (a Nested_Worker), then asks the interface
//     thread to start it (Child_Create, on the parent's own link);
//   * the interface thread makes the child's Worker_Host in the parent's page (its loader and limits: the nested
//     workers count in workers.max_per_page and workers.max_total, workers.max_depth bounds the nesting), fetches its
//     script with the parent's environment as the client, relays its requests and its console as for any worker;
//   * the parent posts to the child straight on the child's link (the queues are thread-safe); what the child sends
//     goes to the interface thread, which forwards it on the parent's link (Child_Event): messages (with their
//     buffers and ports), uncaught errors, and its end;
//   * terminate(), or the Worker object going away, halts the child at once (the stop flag of its link) and tells the
//     interface thread (Child_Terminate); a worker that is terminated or ends takes its children with it, down the
//     tree (HTML: a worker's lifetime is bound to its owners').
// A service worker has no Worker constructor (Service Workers: not exposed there); SharedWorker is a documents' API
// only (HTML: [Exposed=Window]).

import "core:fmt"
import "core:strings"
import "wb:dom"
import "wb:url"

NESTED_MESSAGE :: 0
NESTED_ERROR   :: 1
NESTED_GONE    :: 2

// A Worker object in a worker's realm (the parent's thread).
Nested_Worker :: struct {
	link:       ^Worker_Link,   // the child's (a reference of its own)
	self:       u64,
	owner:      u32,
	terminated: bool,           // terminate() was called (or the object went away)
	gone:       bool,           // the child ended
}

nested_worker_vt := Object_VTable{
	name = "Worker",
	destroy = proc(p: ^Page, data: rawptr) {
		n := (^Nested_Worker)(data)
		nested_terminate(p, n, true)
		if g := p.worker; g != nil { for x, i in g.children { if x == n { unordered_remove(&g.children, i); break } } }
		link_release(n.link)
		free(n)
	},
}

@(private)
nested_id :: #force_inline proc(n: ^Nested_Worker) -> u64 { return u64(uintptr(n.link)) }

// The Nested_Worker of object `w` in a worker's realm (nil: not one).
nested_of :: proc(p: ^Page, w: u64) -> ^Nested_Worker {
	if p.worker == nil { return nil }
	return (^Nested_Worker)(object_data(p, w, &nested_worker_vt))
}

////////////////////////////////
// The parent's thread

// new Worker(src) in the worker realm `p`: its Worker object; the child starts (or fails, with an error event) once
// the interface thread got the request. 0 (and a message on the console) when the URL is not one.
nested_worker_request :: proc(p: ^Page, src, name: string, owner: u32, javascript, module: bool, image: []byte) -> u64 {
	g := p.worker
	if g.sw.version != 0 { log(p, .Error, "Worker: a service worker does not start workers"); return 0 }
	u, ok := url.parse(src, &p.env.location, context.temp_allocator)
	if !ok { log(p, .Error, fmt.tprintf("Worker: invalid URL %q", src)); return 0 }
	l := link_make(g.link.ui_loop, p.settings.workers.max_pending_bytes)   // (this reference goes to the child's host)
	link_retain(l)                                                         // the Worker object's
	n := new(Nested_Worker)
	n.link, n.owner = l, owner
	n.self = object_create(p, &nested_worker_vt, n, owner)
	append(&g.children, n)
	m := new(Worker_Msg)
	m.kind, m.id = .Child_Create, nested_id(n)
	m.text, m.text2 = strings.clone(u.href), strings.clone(name)
	m.code = (javascript ? 1 : 0) | (module ? 2 : 0) | (image != nil ? 4 : 0)
	if image != nil { m.bytes = make([]byte, len(image)); copy(m.bytes, image) }
	link_send(g.link, false, m)
	return n.self
}

// terminate() (or the object released: `release`): the child stops at once; the interface thread is told.
nested_terminate :: proc(p: ^Page, n: ^Nested_Worker, release: bool) {
	first := !n.terminated
	n.terminated = true
	if first { link_halt(n.link) }
	if p.worker == nil || (!first && !release) { return }
	m := new(Worker_Msg)
	m.kind, m.id, m.code = .Child_Terminate, nested_id(n), release ? 1 : 0
	link_send(p.worker.link, false, m)
}

// What a child sent, forwarded by the interface thread: a message, an error, its end.
nested_event :: proc(p: ^Page, m: ^Worker_Msg) {
	g := p.worker
	n: ^Nested_Worker
	for x in g.children { if nested_id(x) == m.id { n = x; break } }
	if n == nil || n.self == 0 { return }
	switch m.code {
	case NESTED_MESSAGE:
		if !n.terminated { deliver_message(p, n.self, m, n.owner) }
	case NESTED_ERROR:
		if n.terminated { return }
		allowed := object_dispatch(p, n.self, dom.Event{type = "error", cancelable = true, data = m.text, text = m.text2})
		if !allowed { return }
		// HTML "run a worker": an uncaught exception its Worker object did not cancel is reported in this realm
		runtime := strings.has_prefix(m.text, "Uncaught") && !strings.has_prefix(m.text, "Uncaught SyntaxError")
		if r := p.js; runtime && r != nil && !r.failed && r.inst != nil && !r.inst.dead {
			worker_error_text = fmt.tprintf("%s\t%s", m.text, m.text2)
			js_call(p, r.inst, "wj_worker_error_to_global", nil)
			worker_error_text = ""
		} else {
			log(p, .Error, fmt.tprintf("[worker %s] uncaught error: %s", m.text2, m.text))
		}
	case NESTED_GONE:
		n.gone = true
		js_worker_gone(p, n.self)   // its object may be collected now
	}
}

////////////////////////////////
// The interface thread

// Child_Create from the worker of `ph`: the child's host, started (or refused: an error event in the parent).
nested_host_create :: proc(ph: ^Worker_Host, m: ^Worker_Msg) {
	l := (^Worker_Link)(uintptr(m.id))
	id := m.id
	m.id = 0   // the reference is taken here
	p := ph.page
	javascript, module, has_image := m.code & 1 != 0, m.code & 2 != 0, m.code & 4 != 0
	if ph.terminated || ph.state == .Exited || p.closed { link_release(l); return }   // nobody to start it for
	ws := &p.settings.workers
	why := worker_refused(p, javascript)
	u, ok := url.parse_absolute(m.text, context.temp_allocator)
	switch {
	case why != "":
	case !ok: why = fmt.tprintf("Worker: invalid URL %q", m.text)
	case ph.depth + 1 > ws.max_depth: why = fmt.tprintf("Worker: workers nest %d deep at most (workers.max_depth)", ws.max_depth)
	case u.scheme != "data" && !url.same_origin(url.origin_of(u, context.temp_allocator), ph.env.origin):
		// (HTML: the script is fetched in mode same-origin for its parent: the fetch fails, an error event follows)
		why = fmt.tprintf("Worker: %s is not same-origin with its parent worker %s", u.href, ph.url)
	case !worker_take_slot(ws): why = fmt.tprintf("Worker: the browser already runs %d workers (workers.max_total)", ws.max_total)
	}
	if why != "" {
		log(p, .Error, why)
		nested_send(ph, id, NESTED_ERROR, why, m.text)
		nested_send(ph, id, NESTED_GONE, "", "")
		link_release(l)
		return
	}
	h := worker_host_new(p, u, m.text2, javascript, module, l, &ph.env)
	h.parent, h.ref_held, h.ref_id, h.depth = ph, true, id, ph.depth + 1
	h.storage_key = strings.clone(ph.storage_key)   // (a shared worker's child: its documents' storage key)
	worker_host_load(h, has_image ? m.bytes : nil, &ph.env)
}

// An event for the parent's realm about its child `id`.
@(private)
nested_send :: proc(ph: ^Worker_Host, id: u64, kind: i64, text, text2: string) {
	f := new(Worker_Msg)
	f.kind, f.id, f.code = .Child_Event, id, kind
	f.text, f.text2 = strings.clone(text), strings.clone(text2)
	link_send(ph.link, true, f)
}

// What the child of `h` sent goes to its parent's realm (its text, buffers and ports move along).
nested_forward :: proc(h: ^Worker_Host, m: ^Worker_Msg, kind: i64) {
	ph := h.parent
	if ph == nil || ph.terminated || ph.state == .Exited { return }   // nobody hears it any more
	f := new(Worker_Msg)
	f.kind, f.id, f.code, f.size = .Child_Event, h.ref_id, kind, m.size
	f.text, m.text = m.text, ""
	f.text2, m.text2 = m.text2, ""
	f.buffers, m.buffers = m.buffers, nil
	f.ports, m.ports = m.ports, nil
	if kind == NESTED_ERROR && f.text2 == "" { f.text2 = strings.clone(h.url) }
	link_send(ph.link, true, f)
}

// The child's script could not be fetched or started: an error event, then its end, in the parent's realm.
nested_failed :: proc(h: ^Worker_Host, message: string) {
	if ph := h.parent; ph != nil && !ph.terminated && ph.state != .Exited {
		nested_send(ph, h.ref_id, NESTED_ERROR, message, h.url)
		nested_send(ph, h.ref_id, NESTED_GONE, "", "")
	}
	worker_maybe_free(h)
}

// terminate() of child `id` of `ph` (`release`: its Worker object is gone too).
nested_terminate_child :: proc(ph: ^Worker_Host, id: u64, release: bool) {
	for x in ph.page.workers.hosts {
		if x.parent != ph || x.ref_id != id { continue }
		worker_terminate(x)
		if release { x.ref_held = false; worker_maybe_free(x) }
		return
	}
}

// The workers `h` made are terminated with it (worker_terminate).
nested_terminate_children :: proc(h: ^Worker_Host) {
	for x in h.page.workers.hosts { if x.parent == h && !x.terminated { worker_terminate(x) } }
}

// `h` ended or goes: its children stop and no longer have a parent to answer to.
nested_orphan :: proc(h: ^Worker_Host) {
	kids := make([dynamic]^Worker_Host, context.temp_allocator)
	for x in h.page.workers.hosts { if x.parent == h { append(&kids, x) } }
	for x in kids {
		x.parent, x.ref_held = nil, false
		worker_terminate(x)
		worker_maybe_free(x)
	}
}
