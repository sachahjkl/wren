package page

// MessagePorts between documents (HTML "channel messaging" across realms). Each document runs in its own engine
// instance: a MessagePort sent to another document cannot be the same object there. When a port goes to another realm
// (in the transfer list of window.postMessage or of another port's message), the engine turns its pair into a pair of
// port ends routed by the browser:
//
//   realm A: port Q ──Port_post(end a)──▶ router (ends a ⇄ b) ──task──▶ realm B: wj_port_message(end b) ──▶ port P'
//
// An end belongs to one document at a time (Port_bind); while it travels in a message it belongs to none (Port_ship),
// and what is posted to it waits in its queue until its next owner binds it. Closing either end, or the document that
// owns it, disentangles the pair. UI thread only: the documents of frames and tabs (a worker's realm has none yet).

import "wb:js"

@(private)
Port_Msg :: struct {
	data:  []byte,   // structured serialization (runtime/clone.c)
	ports: []u64,    // ends travelling with it
}

@(private)
Port_End :: struct {
	id:     u64,
	peer:   u64,          // 0: disentangled
	owner:  u64,          // the page id of the document that has it; 0 while in a message
	queue:  [dynamic]Port_Msg,
	queued: int,          // bytes waiting
}

@(private)
port_ends: map[u64]^Port_End
@(private)
next_port_end: u64

@(private)
port_msg_free :: proc(m: ^Port_Msg) {
	delete(m.data)
	for e in m.ports { port_close_end(e) }
	delete(m.ports)
}

@(private)
port_end_free :: proc(e: ^Port_End) {
	delete_key(&port_ends, e.id)
	for &m in e.queue { port_msg_free(&m) }
	delete(e.queue)
	free(e)
}

@(private)
port_close_end :: proc(id: u64) {
	e, ok := port_ends[id]
	if !ok { return }
	if pe, pok := port_ends[e.peer]; pok { pe.peer = 0 }
	port_end_free(e)
}

// A document closes: the ends it owns go (their peers are disentangled).
ports_page_closed :: proc(p: ^Page) {
	if len(port_ends) == 0 || p.web == nil { return }
	id := p.web.id
	dead := make([dynamic]u64, context.temp_allocator)
	for k, e in port_ends { if e.owner == id { append(&dead, k) } }
	for k in dead { port_close_end(k) }
}

// Process end (process_shutdown).
ports_shutdown :: proc() {
	for len(port_ends) > 0 {
		for k in port_ends { port_close_end(k); break }
	}
	delete(port_ends)
	port_ends = nil
}

@(private)
Port_Task :: struct { end: u64 }

// Delivers what waits for `e` to its owner, one message per task (in order: the queue keeps them).
@(private)
port_flush :: proc(e: ^Port_End) {
	if e.owner == 0 || len(e.queue) == 0 { return }
	p := page_by_id(e.owner)
	if p == nil { return }
	for _ in e.queue {
		t := new(Port_Task)
		t.end = e.id
		post_page_task(p, proc(pg: ^Page, data: rawptr) {
			t := (^Port_Task)(data)
			defer free(t)
			e, ok := port_ends[t.end]
			if !ok || len(e.queue) == 0 { return }
			if pg == nil || pg.closed || e.owner != page_id(pg) { return }   // shipped meanwhile: its next owner gets it
			m := e.queue[0]
			ordered_remove(&e.queue, 0)
			e.queued -= len(m.data)
			js_port_deliver(pg, t.end, m)
			delete(m.data)
			delete(m.ports)
		}, t)
	}
}

Port_entangle :: proc(c: ^Call) -> u64 {
	if c.page.worker != nil { return 0 }
	if port_ends == nil { port_ends = make(map[u64]^Port_End) }
	a, b := new(Port_End), new(Port_End)
	next_port_end += 2
	a.id, b.id = next_port_end - 1, next_port_end
	a.peer, b.peer = b.id, a.id
	port_ends[a.id] = a
	port_ends[b.id] = b
	frames_of(c.page)   // its cleanup closes the ends the document owns
	return a.id
}

Port_bind :: proc(c: ^Call, end: u64) -> Api_Error {
	e, ok := port_ends[end]
	if !ok || e.owner != 0 || c.page.worker != nil { return fail(c, .Invalid_Argument, "no such port end") }
	e.owner = page_id(c.page)
	frames_of(c.page)
	port_flush(e)
	return .None
}

Port_ship :: proc(c: ^Call, end: u64) {
	if e, ok := port_ends[end]; ok && e.owner == page_id(c.page) { e.owner = 0 }
}

Port_post :: proc(c: ^Call, end: u64, data: []u8, ports: []u64) -> Api_Error {
	e, ok := port_ends[end]
	if !ok || e.owner != page_id(c.page) {
		for x in ports { port_close_end(x) }
		return .None   // a closed port: nothing happens
	}
	if len(data) > c.page.settings.frames.max_message_bytes { return fail(c, .Data_Clone, "DataCloneError: the message is larger than frames.max_message_bytes") }
	pe, pok := port_ends[e.peer]
	if !pok {
		for x in ports { port_close_end(x) }
		return .None
	}
	m := Port_Msg{data = make([]byte, len(data)), ports = make([]u64, len(ports))}
	copy(m.data, data)
	copy(m.ports, ports)
	append(&pe.queue, m)
	pe.queued += len(data)
	if pe.owner != 0 {
		// one task per message posted now (port_flush posts one per queued message: only this one is new)
		if p := page_by_id(pe.owner); p != nil {
			t := new(Port_Task)
			t.end = pe.id
			post_page_task(p, proc(pg: ^Page, data: rawptr) {
				t := (^Port_Task)(data)
				defer free(t)
				e, ok := port_ends[t.end]
				if !ok || len(e.queue) == 0 || pg == nil || pg.closed || e.owner != page_id(pg) { return }
				m := e.queue[0]
				ordered_remove(&e.queue, 0)
				e.queued -= len(m.data)
				js_port_deliver(pg, t.end, m)
				delete(m.data)
				delete(m.ports)
			}, t)
		}
	}
	return .None
}

Port_close :: proc(c: ^Call, end: u64) {
	if e, ok := port_ends[end]; ok && (e.owner == page_id(c.page) || e.owner == 0) { port_close_end(end) }
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
