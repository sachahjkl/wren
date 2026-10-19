package page

// The Window's place in the propagation path of the document's events (DOM "get the parent": a Document's parent is
// its Window): capture listeners of the window run first, bubbling ones last, with the window as currentTarget, for
// every event dispatched at a node of the document (click, DOMContentLoaded, input...). Events fired at the window
// itself (load, popstate...) are object_dispatch's.

import "wb:base"
import "wb:dom"

@(private)
window_outer_phase :: proc(user: rawptr, eh: base.Handle, phase: dom.Phase) -> bool {
	p := (^Page)(user)
	if p.closed || p.web == nil { return false }
	w := p.web.window
	o := object_get(p, w)
	if w == 0 || o == nil { return true }
	e := base.pool_get(&p.dp.events, eh)
	if e == nil { return true }
	capture := phase == .Capturing
	snapshot := make([dynamic]dom.Listener, context.temp_allocator)
	for l in o.listeners { if !l.removed && l.type == e.type && l.capture == capture { append(&snapshot, l) } }
	if len(snapshot) == 0 { return true }
	for l in snapshot {
		o = object_get(p, w)
		if o == nil { break }
		still := false
		for cur in o.listeners { if cur.id == l.id && !cur.removed { still = true; break } }
		if !still { continue }
		e = base.pool_get(&p.dp.events, eh)
		if e == nil { return true }
		e.current_target = base.Handle(w)
		e.phase = phase
		if l.once { object_remove_listener(p, w, l.id) }
		argv := [3]u32{l.user, u32(u64(eh)), u32(u64(eh) >> 32)}
		if inst := instance_by_index(p, l.owner); inst != nil { call_guest(p, inst, l.callback, argv[:]) }
		if p.closed { return false }
		e = base.pool_get(&p.dp.events, eh)
		if e == nil || e.stop_immediate { break }
	}
	if o = object_get(p, w); o != nil {
		n := 0
		for l in o.listeners { if !l.removed { o.listeners[n] = l; n += 1 } }
		resize(&o.listeners, n)
	}
	return true
}
