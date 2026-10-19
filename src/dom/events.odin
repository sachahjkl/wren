package dom

import "core:strings"
import "wb:base"

Phase :: enum u8 { None, Capturing, At_Target, Bubbling }

Event :: struct {
	type:            string,    // owned
	target:          base.Handle,
	current_target:  base.Handle,
	phase:           Phase,
	bubbles:         bool,
	cancelable:      bool,
	default_prevented: bool,
	stop:            bool,
	stop_immediate:  bool,
	x, y:            f64,       // pointer position, client coordinates
	key:             u32,       // key code for keyboard events
	button:          i32,
	mods:            u32,
	// payload of non-UI events (message, error, close, progress...). `data` is owned by the event; `object` is a handle the
	// event carries (a buffer, a port...), `code` a numeric detail (close code, error kind, loaded bytes...).
	data:            string,
	object:          u64,
	code:            i64,
	text:            string,    // owned: a second string (origin of a message, reason of a close, key text...)
	// an Event object of the JavaScript engine being dispatched (its identifier; 0 for events the browser makes), which
	// is then not trusted, and its timeStamp (0: the time of the dispatch)
	engine_id:       i64,
	untrusted:       bool,
	time_stamp:      f64,
}

// What the embedder does to run a listener (the page calls into the Wasm instance). Returns false to stop dispatching
// altogether (the instance died).
Invoke_Proc :: #type proc(user: rawptr, l: Listener, event: base.Handle) -> bool

// The embedder's part of the propagation path beyond the document (HTML: an event of a node of the document reaches
// its Window, first in the capture phase, last in the bubble phase). Returns false to stop dispatching altogether.
Outer_Proc :: #type proc(user: rawptr, event: base.Handle, phase: Phase) -> bool

Dispatcher :: struct {
	events:  base.Pool(Event),   // transient: alive only while the dispatch runs
	invoke:  Invoke_Proc,
	outer:   Outer_Proc,         // nil: the path ends at the document
	user:    rawptr,
}

dispatcher_destroy :: proc(dp: ^Dispatcher) {
	it: u32
	for _, e in base.pool_next(&dp.events, &it) { delete(e.type); delete(e.data); delete(e.text) }
	base.pool_destroy(&dp.events)
}

add_listener :: proc(d: ^Document, target: base.Handle, type: string, callback, user: u32, capture, once, passive: bool, owner: u32 = 0) -> (Listener_Id, Error) {
	n := get(d, target)
	if n == nil { return 0, .Invalid_Handle }
	if type == "" { return 0, .Invalid_Argument }
	// same (type, callback, user, capture) is a no-op, as in the DOM
	for l in n.listeners {
		if !l.removed && l.type == type && l.callback == callback && l.user == user && l.capture == capture && l.owner == owner { return l.id, .None }
	}
	id := d.next_listener
	d.next_listener += 1
	append(&n.listeners, Listener{id = id, type = strings.clone(type), callback = callback, user = user, owner = owner, capture = capture, once = once, passive = passive})
	return id, .None
}

remove_listener :: proc(d: ^Document, target: base.Handle, id: Listener_Id) -> Error {
	n := get(d, target)
	if n == nil { return .Invalid_Handle }
	for l, i in n.listeners {
		if l.id == id && !l.removed {
			delete(l.type)
			n.listeners[i].type = ""
			n.listeners[i].removed = true
			return .None
		}
	}
	return .Not_Found
}

@(private)
compact_listeners :: proc(n: ^Node) {
	w := 0
	for l in n.listeners {
		if !l.removed { n.listeners[w] = l; w += 1 }
	}
	resize(&n.listeners, w)
}

// Runs the capture / target / bubble phases. Returns false if a listener called preventDefault on a cancelable event.
dispatch :: proc(d: ^Document, dp: ^Dispatcher, target: base.Handle, proto: Event) -> bool {
	if get(d, target) == nil { return true }
	ev := proto
	ev.type = strings.clone(proto.type)
	ev.data = strings.clone(proto.data)
	ev.text = strings.clone(proto.text)
	ev.target = target
	eh, _ := base.pool_insert(&dp.events, ev)
	defer {
		if e := base.pool_get(&dp.events, eh); e != nil { delete(e.type); delete(e.data); delete(e.text) }
		base.pool_remove(&dp.events, eh)
	}

	// propagation path, target first
	path: [dynamic]base.Handle
	defer delete(path)
	for cur := target; cur != base.NIL_HANDLE; {
		append(&path, cur)
		n := get(d, cur)
		if n == nil { break }
		cur = n.parent
	}

	alive :: proc(dp: ^Dispatcher, eh: base.Handle) -> ^Event { return base.pool_get(&dp.events, eh) }

	run_node :: proc(d: ^Document, dp: ^Dispatcher, eh: base.Handle, node: base.Handle, phase: Phase, want_capture: Maybe(bool)) -> bool {
		e := base.pool_get(&dp.events, eh)
		n := get(d, node)
		if e == nil || n == nil { return true }
		e.current_target = node
		e.phase = phase
		snapshot: [dynamic]Listener
		defer delete(snapshot)
		for l in n.listeners {
			if l.removed || l.type != e.type { continue }
			if c, has := want_capture.?; has && l.capture != c { continue }
			append(&snapshot, l)   // type string aliases the node's; used only inside this call before any invoke
		}
		for l in snapshot {
			n = get(d, node)
			if n == nil { return true }
			still := false
			for cur in n.listeners { if cur.id == l.id && !cur.removed { still = true; break } }
			if !still { continue }
			if l.once { remove_listener(d, node, l.id) }
			ok := dp.invoke(dp.user, l, eh)
			if !ok { return false }
			e = base.pool_get(&dp.events, eh)
			if e == nil || e.stop_immediate { return true }
		}
		if n = get(d, node); n != nil { compact_listeners(n) }
		return true
	}

	halted :: proc(dp: ^Dispatcher, eh: base.Handle) -> bool {
		e := base.pool_get(&dp.events, eh)
		return e == nil || e.stop || e.stop_immediate
	}

	// a node of the document: the path goes on to the embedder's Window
	outer := dp.outer != nil && path[len(path) - 1] == d.root ? dp.outer : nil

	phases: {
		if outer != nil {
			if !outer(dp.user, eh, .Capturing) { return true }
			if halted(dp, eh) { break phases }
		}
		// capture: root down to the target's parent
		for i := len(path) - 1; i >= 1; i -= 1 {
			if !run_node(d, dp, eh, path[i], .Capturing, true) { return true }
			if halted(dp, eh) { break phases }
		}
		// target: capture listeners first, then the others (current DOM behaviour)
		if !run_node(d, dp, eh, path[0], .At_Target, true) { return true }
		if e := alive(dp, eh); e != nil && !e.stop_immediate {
			if !run_node(d, dp, eh, path[0], .At_Target, false) { return true }
		}
		if halted(dp, eh) { break phases }
		// bubble
		if e := alive(dp, eh); e != nil && e.bubbles {
			for i in 1 ..< len(path) {
				if !run_node(d, dp, eh, path[i], .Bubbling, false) { return true }
				if halted(dp, eh) { break phases }
			}
			if outer != nil && !outer(dp.user, eh, .Bubbling) { return true }
		}
	}

	if e := alive(dp, eh); e != nil {
		e.phase = .None
		return !(e.cancelable && e.default_prevented)
	}
	return true
}
