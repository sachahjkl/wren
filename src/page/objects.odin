package page

// Host objects: everything a guest holds a handle to that is not a DOM node (promises, buffers, event sources, sockets,
// workers, abort signals...). They share one registry so that:
//   * every kind is released the same way (`Object_release`) and freed with the page, whatever the guest forgets;
//   * every kind can be an EventTarget: `EventTarget_addEventListener` accepts node handles and object handles alike;
//   * a handle of one kind passed where another is expected is refused (the vtable is part of the check).
//
// Object handles carry OBJECT_TAG (bit 63) so they never alias a DOM node handle. A new kind defines an Object_VTable in
// its own file and uses object_create / object_data; nothing here needs to change.
//
// Calls into guests go through `call_guest`, which keeps the reentrancy depth and runs the microtask checkpoint when the
// outermost call returns: this is the HTML event loop's "perform a microtask checkpoint" after each task and callback.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:wasm"

OBJECT_TAG :: u64(1) << 63

Object_VTable :: struct {
	name:    string,                          // interface name, for messages ("EventSource")
	destroy: proc(p: ^Page, data: rawptr),    // frees `data`; called on release and when the page closes (p.closed is then true)
}

Object :: struct {
	vt:        ^Object_VTable,
	data:      rawptr,
	owner:     u32,                  // instance that created it
	self:      base.Handle,          // untagged pool handle
	listeners: [dynamic]dom.Listener,
}

Microtask :: struct {
	instance: u32,
	callback: u32,     // table index; signature (user: i32)            for queueMicrotask
	user:     u32,     //                          (user: i32, promise: i64, state: i32) for promise reactions
	promise:  u64,     // tagged handle of the settled promise, 0 for a plain microtask
	state:    i32,
}

Objects :: struct {
	pool:        base.Pool(Object),
	microtasks:  [dynamic]Microtask,
	depth:       int,                // guest calls in progress
	draining:    bool,
}

@(private)
objects_destroy :: proc(p: ^Page) {
	it: u32
	for _, o in base.pool_next(&p.objects.pool, &it) {
		if o.vt != nil && o.vt.destroy != nil { o.vt.destroy(p, o.data) }
		for l in o.listeners { delete(l.type) }
		delete(o.listeners)
	}
	base.pool_destroy(&p.objects.pool)
	delete(p.objects.microtasks)
}

is_object :: #force_inline proc "contextless" (h: u64) -> bool { return h & OBJECT_TAG != 0 }

object_create :: proc(p: ^Page, vt: ^Object_VTable, data: rawptr, owner: u32) -> u64 {
	h, o := base.pool_insert(&p.objects.pool, Object{vt = vt, data = data, owner = owner})
	o.self = h
	return u64(h) | OBJECT_TAG
}

object_get :: proc(p: ^Page, h: u64) -> ^Object {
	if !is_object(h) { return nil }
	return base.pool_get(&p.objects.pool, base.Handle(h &~ OBJECT_TAG))
}

// The data of an object of the given kind, nil when the handle is stale or of another kind.
object_data :: proc(p: ^Page, h: u64, vt: ^Object_VTable) -> rawptr {
	o := object_get(p, h)
	if o == nil || o.vt != vt { return nil }
	return o.data
}

object_release :: proc(p: ^Page, h: u64) -> bool {
	if !is_object(h) { return false }
	o, ok := base.pool_remove(&p.objects.pool, base.Handle(h &~ OBJECT_TAG))
	if !ok { return false }
	if o.vt != nil && o.vt.destroy != nil { o.vt.destroy(p, o.data) }
	for l in o.listeners { delete(l.type) }
	delete(o.listeners)
	return true
}

////////////////////////////////
// Events on objects

// `capture` matters for the Window only (the one object in a propagation path, js_dom_events.odin).
object_add_listener :: proc(p: ^Page, h: u64, type: string, callback, user: u32, once: bool, owner: u32, capture := false) -> (dom.Listener_Id, dom.Error) {
	o := object_get(p, h)
	if o == nil { return 0, .Invalid_Handle }
	if type == "" { return 0, .Invalid_Argument }
	for l in o.listeners {
		if !l.removed && l.type == type && l.callback == callback && l.user == user && l.owner == owner && l.capture == capture { return l.id, .None }
	}
	id := p.doc.next_listener
	p.doc.next_listener += 1
	append(&o.listeners, dom.Listener{id = id, type = strings.clone(type), callback = callback, user = user, owner = owner, once = once, capture = capture})
	return id, .None
}

object_remove_listener :: proc(p: ^Page, h: u64, id: dom.Listener_Id) -> dom.Error {
	o := object_get(p, h)
	if o == nil { return .Invalid_Handle }
	for &l in o.listeners {
		if l.id == id && !l.removed { delete(l.type); l.type = ""; l.removed = true; return .None }
	}
	return .Not_Found
}

// True when someone listens for `type` (lets a source skip work nobody would see).
object_has_listener :: proc(p: ^Page, h: u64, type: string) -> bool {
	o := object_get(p, h)
	if o == nil { return false }
	for l in o.listeners { if !l.removed && l.type == type { return true } }
	return false
}

// Fires `ev` at an object (no propagation path: objects are leaves). The object may be released by a listener.
object_dispatch :: proc(p: ^Page, h: u64, proto: dom.Event) -> bool {
	o := object_get(p, h)
	if o == nil || p.closed { return true }
	ev := proto
	ev.type = strings.clone(proto.type)
	ev.data = strings.clone(proto.data)
	ev.text = strings.clone(proto.text)
	ev.target = base.Handle(h)
	ev.current_target = base.Handle(h)
	ev.phase = .At_Target
	eh, _ := base.pool_insert(&p.dp.events, ev)
	defer {
		if e := base.pool_get(&p.dp.events, eh); e != nil { delete(e.type); delete(e.data); delete(e.text) }
		base.pool_remove(&p.dp.events, eh)
	}
	snapshot := make([dynamic]dom.Listener, context.temp_allocator)
	for l in o.listeners { if !l.removed && l.type == proto.type { append(&snapshot, l) } }
	for l in snapshot {
		o = object_get(p, h)
		if o == nil { break }
		still := false
		for cur in o.listeners { if cur.id == l.id && !cur.removed { still = true; break } }
		if !still { continue }
		if l.once { object_remove_listener(p, h, l.id) }
		argv := [3]u32{l.user, u32(u64(eh)), u32(u64(eh) >> 32)}
		inst := instance_by_index(p, l.owner)
		if inst != nil { call_guest(p, inst, l.callback, argv[:]) }
		e := base.pool_get(&p.dp.events, eh)
		if e == nil || e.stop_immediate { break }
	}
	if o = object_get(p, h); o != nil {
		w := 0
		for l in o.listeners { if !l.removed { o.listeners[w] = l; w += 1 } }
		resize(&o.listeners, w)
	}
	if e := base.pool_get(&p.dp.events, eh); e != nil { return !(e.cancelable && e.default_prevented) }
	return true
}

////////////////////////////////
// Calling guests, microtasks

// Every host -> guest call of the page goes through here. Returns false when the call trapped (already logged).
call_guest :: proc(p: ^Page, inst: ^wasm.Instance, table_index: u32, argv: []u32) -> bool {
	if inst == nil || inst.dead || p.closed || realm_halted(p) { return false }
	p.objects.depth += 1
	res := wasm.call_indirect(inst, table_index, argv)
	p.objects.depth -= 1
	if res != .Ok { guest_failed(p, inst) }
	if p.objects.depth == 0 { microtask_checkpoint(p) }
	return res == .Ok
}

// Calls an export of a module as a task of the page (embedders and tests): the microtask checkpoint runs afterwards.
call_export :: proc(p: ^Page, inst: ^wasm.Instance, name: cstring, argv: []u32 = nil) -> wasm.Call_Result {
	if inst == nil || inst.dead || p.closed || realm_halted(p) { return .Trapped }
	p.objects.depth += 1
	res := wasm.call_raw(inst, name, argv)
	p.objects.depth -= 1
	if res != .Ok { guest_failed(p, inst) }
	if p.objects.depth == 0 { microtask_checkpoint(p) }
	return res
}

// A guest call trapped (exception or instruction budget): the console of a page, the `error` event of a worker.
@(private)
guest_failed :: proc(p: ^Page, inst: ^wasm.Instance) {
	if p.js != nil && p.js.inst == inst { js_trapped(p, inst) }
	if p.worker != nil { worker_report_error(p, inst.last_error); return }
	log(p, .Error, inst.last_error)
}

queue_microtask :: proc(p: ^Page, m: Microtask) { append(&p.objects.microtasks, m) }

// Runs microtasks until the queue is empty. A microtask may queue more; a runaway chain is cut after the configured
// number (preference page.max_microtasks_per_checkpoint) and the rest waits for the next checkpoint, so a page cannot
// freeze the browser this way.
microtask_checkpoint :: proc(p: ^Page) {
	if p.objects.draining || p.closed { return }
	p.objects.draining = true
	defer p.objects.draining = false
	ran := 0
	limit := p.settings.max_microtasks
	// custom element reactions the parser's insertions queued; the browser's microtasks, then the JavaScript realm's
	// jobs, until neither has any left
	custom_elements_flush(p)
	// slotchange (js_shadow.odin) once the jobs and microtasks before it ran: they may signal more
	for len(p.objects.microtasks) > 0 || (p.js != nil && js_checkpoint(p) && len(p.objects.microtasks) > 0) || shadow_signal_slots(p) {
		if realm_halted(p) { return }   // a terminated worker runs nothing more
		if len(p.objects.microtasks) == 0 {
			// slotchange fired: counted as a microtask (a listener that keeps changing slots cannot loop forever)
			ran += 1
			if ran >= limit { host_post_checkpoint(p); break }
			continue
		}
		if ran >= limit {
			log(p, .Warn, fmt.tprintf("more than %d microtasks in one checkpoint: the rest runs later", limit))
			host_post_checkpoint(p)
			break
		}
		m := p.objects.microtasks[0]
		ordered_remove(&p.objects.microtasks, 0)
		ran += 1
		inst := instance_by_index(p, m.instance)
		if inst == nil { continue }
		p.objects.depth += 1
		res: wasm.Call_Result
		if m.promise == 0 {
			argv := [1]u32{m.user}
			res = wasm.call_indirect(inst, m.callback, argv[:])
		} else {
			argv := [4]u32{m.user, u32(m.promise), u32(m.promise >> 32), u32(m.state)}
			res = wasm.call_indirect(inst, m.callback, argv[:])
		}
		p.objects.depth -= 1
		if res != .Ok { guest_failed(p, inst) }
		if p.closed { return }
	}
	report_unhandled_rejections(p)
}
