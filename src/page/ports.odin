package page

// MessagePorts between realms (HTML "channel messaging" across documents and workers). Each realm runs in its own engine
// instance: a MessagePort sent to another realm cannot be the same object there. When a port goes to another realm (in
// the transfer list of window.postMessage, of a worker's message or of another port's message), the engine turns its
// pair into a pair of port ends routed here (api/ports.widl; native/js/runtime/web_message.c):
//
//   realm A: port Q ──Port_post(end a)──▶ router (ends a ⇄ b, queue of b) ──wake──▶ realm B: wj_port_message(end b)
//
// An end belongs to one realm at a time (Port_bind): a document (its page id, UI thread) or a worker (its link, its own
// thread). While it travels in a message it belongs to none (Port_ship) and what is posted to it waits in its queue.
// Delivery is one wake per message: a task on the UI loop for a document, a message on the worker's link for a worker;
// the wake takes the first message of the queue if the end still belongs to that realm (else its next owner gets it).
// The router is shared by every thread: one mutex, never held while a realm runs.

import "core:sync"
import "wb:host"
import "wb:js"

@(private)
Port_Msg :: struct {
	data:  []byte,   // structured serialization (runtime/clone.c)
	ports: []u64,    // ends travelling with it
}

@(private)
Port_End :: struct {
	id:     u64,
	peer:   u64,             // 0: disentangled
	page:   u64,             // owner: a document's page id (UI thread)
	link:   ^Worker_Link,    // owner: a worker realm
	queue:  [dynamic]Port_Msg,
	channel: string,         // owned: a BroadcastChannel's key (broadcast.odin), "" for a MessagePort's end
}

@(private)
Port_Router :: struct {
	mu:      sync.Mutex,
	ends:    map[u64]^Port_End,
	next:    u64,
	ui_loop: ^host.Loop,
}

@(private)
router: Port_Router

// (locked)
@(private)
port_close_locked :: proc(id: u64) {
	e, ok := router.ends[id]
	if !ok { return }
	if pe, pok := router.ends[e.peer]; pok { pe.peer = 0 }
	delete_key(&router.ends, id)
	for m in e.queue {
		delete(m.data)
		for x in m.ports { port_close_locked(x) }
		delete(m.ports)
	}
	delete(e.queue)
	delete(e.channel)
	free(e)
}

port_close_end :: proc(id: u64) {
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	port_close_locked(id)
}

// A document closes: the ends it owns go (their peers are disentangled).
ports_page_closed :: proc(p: ^Page) {
	if p.web == nil || p.web.id == 0 { return }
	id := p.web.id
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	if len(router.ends) == 0 { return }
	dead := make([dynamic]u64, context.temp_allocator)
	for k, e in router.ends { if e.page == id { append(&dead, k) } }
	for k in dead { port_close_locked(k) }
}

// A worker's thread ends: the ends its realm owns go.
ports_link_closed :: proc(l: ^Worker_Link) {
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	if len(router.ends) == 0 { return }
	dead := make([dynamic]u64, context.temp_allocator)
	for k, e in router.ends { if e.link == l { append(&dead, k) } }
	for k in dead { port_close_locked(k) }
}

// Process end (process_shutdown).
ports_shutdown :: proc() {
	sync.mutex_lock(&router.mu)
	for len(router.ends) > 0 {
		for k in router.ends { port_close_locked(k); break }
	}
	delete(router.ends)
	router.ends = nil
	sync.mutex_unlock(&router.mu)
}

@(private)
Port_Wake :: struct { end: u64 }

// One wake for the owner of `e` (locked): it takes the first message of the queue.
@(private)
port_wake_locked :: proc(e: ^Port_End) {
	switch {
	case e.page != 0 && router.ui_loop != nil:
		w := new(Port_Wake)
		w.end = e.id
		host.post(router.ui_loop, port_wake_page, w)
	case e.link != nil:
		m := new(Worker_Msg)
		m.kind, m.id = .Port_Wake, e.id
		link_send(e.link, true, m)
	}
}

// UI thread: a message for an end a document owns.
@(private)
port_wake_page :: proc(data: rawptr) {
	w := (^Port_Wake)(data)
	end := w.end
	free(w)
	sync.mutex_lock(&router.mu)
	e, ok := router.ends[end]
	if !ok || e.page == 0 || len(e.queue) == 0 { sync.mutex_unlock(&router.mu); return }
	p := page_by_id(e.page)
	if p == nil || p.closed { sync.mutex_unlock(&router.mu); return }
	if p.web.frozen {
		// in the back/forward cache: delivered when it is shown again (its tasks wait the same way)
		sync.mutex_unlock(&router.mu)
		w2 := new(Port_Wake)
		w2.end = end
		post_page_task(p, proc(pg: ^Page, d: rawptr) { if pg == nil { free(d); return }; port_wake_page(d) }, w2)
		return
	}
	m := e.queue[0]
	ordered_remove(&e.queue, 0)
	sync.mutex_unlock(&router.mu)
	js_port_deliver(p, end, m)
	delete(m.data)
	delete(m.ports)
}

// A worker's thread: the same for an end its realm owns.
ports_wake_worker :: proc(p: ^Page, end: u64) {
	sync.mutex_lock(&router.mu)
	e, ok := router.ends[end]
	if !ok || p.worker == nil || e.link != p.worker.link || len(e.queue) == 0 { sync.mutex_unlock(&router.mu); return }
	m := e.queue[0]
	ordered_remove(&e.queue, 0)
	sync.mutex_unlock(&router.mu)
	js_port_deliver(p, end, m)
	delete(m.data)
	delete(m.ports)
}

@(private)
port_owned_by :: proc(e: ^Port_End, p: ^Page) -> bool {
	if p.worker != nil { return e.link == p.worker.link }
	return e.page != 0 && e.page == page_id(p)
}

@(private)
ports_note_loop :: proc(p: ^Page) {
	if router.ui_loop == nil { router.ui_loop = p.worker != nil ? p.worker.link.ui_loop : p.loop }
}

Port_entangle :: proc(c: ^Call) -> u64 {
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	ports_note_loop(c.page)
	if router.ends == nil { router.ends = make(map[u64]^Port_End) }
	a, b := new(Port_End), new(Port_End)
	router.next += 2
	a.id, b.id = router.next - 1, router.next
	a.peer, b.peer = b.id, a.id
	router.ends[a.id] = a
	router.ends[b.id] = b
	return a.id
}

Port_bind :: proc(c: ^Call, end: u64) -> Api_Error {
	p := c.page
	if p.worker == nil { frames_of(p) }   // its cleanup closes the ends the document owns
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	ports_note_loop(p)
	e, ok := router.ends[end]
	if !ok || e.page != 0 || e.link != nil { return fail(c, .Invalid_Argument, "no such port end") }
	if p.worker != nil { e.link = p.worker.link } else { e.page = page_id(p) }
	for _ in e.queue { port_wake_locked(e) }
	return .None
}

Port_ship :: proc(c: ^Call, end: u64) {
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	if e, ok := router.ends[end]; ok && port_owned_by(e, c.page) { e.page, e.link = 0, nil }
}

Port_post :: proc(c: ^Call, end: u64, data: []u8, ports: []u64) -> Api_Error {
	max_bytes := c.page.settings.frames.max_message_bytes
	if max_bytes > 0 && len(data) > max_bytes {
		for x in ports { port_close_end(x) }
		return fail(c, .Data_Clone, "DataCloneError: the message is larger than frames.max_message_bytes")
	}
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	e, ok := router.ends[end]
	pe: ^Port_End
	pok := false
	if ok && port_owned_by(e, c.page) { pe, pok = router.ends[e.peer] }
	if !pok {
		for x in ports { port_close_locked(x) }   // a closed port: nothing happens
		return .None
	}
	m := Port_Msg{data = make([]byte, len(data)), ports = make([]u64, len(ports))}
	copy(m.data, data)
	copy(m.ports, ports)
	append(&pe.queue, m)
	port_wake_locked(pe)
	return .None
}

Port_close :: proc(c: ^Call, end: u64) {
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	if e, ok := router.ends[end]; ok && (port_owned_by(e, c.page) || (e.page == 0 && e.link == nil)) { port_close_locked(end) }
}

// The engine of `p` receives a message for its port bound to `end`: the ports that came with it are bound there.
@(private)
js_port_deliver :: proc(p: ^Page, end: u64, m: Port_Msg) {
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead {
		for x in m.ports { port_close_end(x) }
		return
	}
	d := js.guest_copy(r.inst, m.data, false)
	if d == 0 && len(m.data) > 0 { return }
	defer js.guest_free(r.inst, d)
	pp := js.guest_copy(r.inst, ([^]byte)(raw_data(m.ports))[:len(m.ports) * 8], false)
	defer js.guest_free(r.inst, pp)
	argv := [6]u32{u32(end), u32(end >> 32), d, u32(len(m.data)), pp, u32(len(m.ports))}
	js_call(p, r.inst, "wj_port_message", argv[:])
	js_after_task(p, r, "message")
}

////////////////////////////////
// Workers' messages with ports

Worker_postSerializedPorts :: proc(c: ^Call, worker: u64, data: []u8, ports: []u64) -> Api_Error {
	p := c.page
	if p.worker != nil { for x in ports { port_close_end(x) }; return fail(c, .Invalid_Argument, "a worker posts with DedicatedWorkerGlobalScope_postSerializedPorts") }
	h := (^Worker_Host)(object_data(p, worker, &worker_vt))
	if h == nil || h.terminated || h.state == .Closed || h.state == .Exited { for x in ports { port_close_end(x) }; return .None }
	err := post_message(p, h.link, true, string(data), nil, ports)
	if err != .None { for x in ports { port_close_end(x) } }
	return dom_error(err)
}

DedicatedWorkerGlobalScope_postSerializedPorts :: proc(c: ^Call, data: []u8, ports: []u64) -> Api_Error {
	p := c.page
	g := p.worker
	if g == nil { for x in ports { port_close_end(x) }; return fail(c, .Invalid_Argument, "not in a worker") }
	err := post_message(p, g.link, false, string(data), nil, ports)
	if err != .None { for x in ports { port_close_end(x) } }
	return dom_error(err)
}

// The ends that came with the message event being dispatched (given once: the engine binds them).
MessageEvent_portEnds :: proc(c: ^Call, event: Api_Event) -> []u8 {
	d := message_delivery(c.page, u64(event.handle))
	if d == nil || d.ports == nil || d.ports_taken { return nil }
	d.ports_taken = true
	return ([^]u8)(raw_data(d.ports))[:len(d.ports) * 8]
}
