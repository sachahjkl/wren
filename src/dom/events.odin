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
	// UI Events details the shell may give (zero: unknown, derived from the fields above where UI Events allows)
	screen_x, screen_y: f64,
	buttons:         u16,       // MouseEvent.buttons; 0 with a `button` press: derived from it
	detail:          i32,       // UIEvent.detail (click count...)
	repeat:          bool,      // KeyboardEvent.repeat
	location:        u8,        // KeyboardEvent.location
	delta:           [3]f64,    // WheelEvent deltaX / deltaY / deltaZ
	delta_mode:      u8,
	related:         u64,       // relatedTarget (a node handle), 0 = null; retargeted for each listener while dispatching
	composed:        bool,      // crosses shadow boundaries (Event.composed); browser UI events are, see dispatch
	pointer:         Pointer_Details,   // PointerEvent / Touch details the shell gives (zero: the mouse)
	// while dispatching: the event path (DOM "event path"), and the entry whose listeners run
	path:            [dynamic]Path_Entry,
	path_index:      int,
}

// What a pointer event says of its device (Pointer Events). `kind` 0 = the mouse (id 1, primary, pressure from the
// buttons); a finger or a pen gives its own.
Pointer_Kind :: enum u8 { Mouse, Pen, Touch }

Pointer_Details :: struct {
	id:          i32,
	kind:        Pointer_Kind,
	primary:     bool,
	pressure:    f32,
	tangential:  f32,
	tilt:        [2]f32,
	twist:       f32,
	size:        [2]f32,     // width, height (CSS px; 0 = 1)
}

// One struct of DOM's event path. `node` NIL with `window`: the Window.
Path_Entry :: struct {
	node:          base.Handle,
	shadow_target: base.Handle,   // NIL: null (the entry is not a target as seen from its tree)
	related:       u64,
	window:        bool,
	root_of_closed_tree: bool,
	slot_in_closed_tree: bool,
	in_shadow_tree: bool,   // the node's root was a shadow root when the path was built (no window.event there)
}

// Event.mods bits
MOD_CTRL :: 1
MOD_SHIFT :: 2
MOD_ALT :: 4
MOD_META :: 8

// Runs the listeners of the Window for the event being dispatched, in one phase (capture or bubble). The Window is
// not a node: the embedder keeps its listeners (Dispatcher.window). Returns false to stop dispatching altogether.
Window_Proc :: #type proc(user: rawptr, event: base.Handle, capture: bool) -> bool

// What the embedder does to run a listener (the page calls into the Wasm instance). Returns false to stop dispatching
// altogether (the instance died).
Invoke_Proc :: #type proc(user: rawptr, l: Listener, event: base.Handle) -> bool

Dispatcher :: struct {
	events:  base.Pool(Event),   // transient: alive only while the dispatch runs
	invoke:  Invoke_Proc,
	user:    rawptr,
	// optional: the Window's listeners. The propagation path of an event whose path reaches the document goes on to
	// the Window (HTML "get the parent" of a Document), except for `load`.
	window:  Window_Proc,
	// the event's target and relatedTarget once the last dispatch ended (NIL / 0 when cleared: they were in a shadow tree)
	last_target:  base.Handle,
	last_related: u64,
}

dispatcher_destroy :: proc(dp: ^Dispatcher) {
	it: u32
	for _, e in base.pool_next(&dp.events, &it) { delete(e.type); delete(e.data); delete(e.text); delete(e.path) }
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
	d.listener_changes += 1
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
			d.listener_changes += 1
			// tombstones go when a dispatch ends at the node; one that never sees an event (listeners added and
			// removed in a loop) drops them here once they are half the list. A dispatch in progress reads a copy and
			// finds its listeners again by id: compacting under it is safe.
			dead := 0
			for x in n.listeners { if x.removed { dead += 1 } }
			if dead * 2 > len(n.listeners) { compact_listeners(n) }
			return .None
		}
	}
	return .Not_Found
}

// HTML "erase all event listeners and handlers" on every shadow-including inclusive descendant of `root` (what
// document.open() does to its document). Tombstones, as remove_listener leaves: a dispatch in progress skips them.
erase_listeners :: proc(d: ^Document, root: base.Handle) {
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := get(d, h)
		if n == nil { continue }
		for &l in n.listeners {
			if l.removed { continue }
			delete(l.type)
			l.type = ""
			l.removed = true
			d.listener_changes += 1
		}
		compact_listeners(n)
		if n.kind == .Element && n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = get(d, ch).next { append(&stack, ch) }
	}
}

@(private)
compact_listeners :: proc(n: ^Node) {
	w := 0
	for l in n.listeners {
		if !l.removed { n.listeners[w] = l; w += 1 }
	}
	resize(&n.listeners, w)
}

// Event types the browser dispatches with `composed` set (UI Events, Pointer Events, Input Events, HTML focus): they
// cross shadow boundaries. Events scripts make say themselves.
ui_composed :: proc(type: string) -> bool {
	switch type {
	case "click", "dblclick", "auxclick", "mousedown", "mouseup", "mousemove", "mouseover", "mouseout", "contextmenu",
	     "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout", "pointercancel", "gotpointercapture",
	     "lostpointercapture", "wheel", "keydown", "keyup", "keypress", "focus", "blur", "focusin", "focusout", "input",
	     "beforeinput", "compositionstart", "compositionupdate", "compositionend", "touchstart", "touchend", "touchmove",
	     "touchcancel", "dragstart", "drag", "dragenter", "dragleave", "dragover", "drop", "dragend", "select",
	     "selectstart", "copy", "cut", "paste":
		return true
	}
	return false
}

// Runs the capture / target / bubble phases. Returns false if a listener called preventDefault on a cancelable event.
dispatch :: proc(d: ^Document, dp: ^Dispatcher, target: base.Handle, proto: Event) -> bool {
	ok, _ := dispatch_ex(d, dp, target, proto)
	return ok
}

// DOM "dispatch" with shadow trees: the event path with its shadow-adjusted targets and retargeted related targets,
// the closed-tree marks composedPath() needs, both passes as the standard runs them (a host on the path is a target as
// seen from its tree: AT_TARGET for its capture and its other listeners). Returns whether the event was not
// canceled, and the event's target once dispatched (NIL when it was cleared: the target was in a shadow tree).
dispatch_ex :: proc(d: ^Document, dp: ^Dispatcher, target: base.Handle, proto: Event) -> (not_canceled: bool, final_target: base.Handle) {
	if get(d, target) == nil { return true, target }
	ev := proto
	ev.type = strings.clone(proto.type)
	ev.data = strings.clone(proto.data)
	ev.text = strings.clone(proto.text)
	ev.target = target
	ev.path = nil
	if !proto.untrusted && proto.engine_id == 0 && !proto.composed { ev.composed = ui_composed(proto.type) }
	original_related := proto.related
	eh, _ := base.pool_insert(&dp.events, ev)
	defer {
		if e := base.pool_get(&dp.events, eh); e != nil { delete(e.type); delete(e.data); delete(e.text); delete(e.path) }
		base.pool_remove(&dp.events, eh)
	}
	composed := base.pool_get(&dp.events, eh).composed
	to_window_ok := dp.window != nil && proto.type != "load"

	closed_root :: proc(d: ^Document, h: base.Handle) -> bool {
		n := get(d, h)
		if n == nil || !n.is_shadow { return false }
		info := shadow_info(d, h)
		return info != nil && info.mode == .Closed
	}
	retarget_rel :: proc(d: ^Document, rel: u64, against: base.Handle) -> u64 {
		if rel == 0 || get(d, base.Handle(rel)) == nil { return rel }
		return u64(retarget(d, base.Handle(rel), against))
	}
	// DOM "get the parent": (node, is_window); NIL node and false: none
	get_parent :: proc(d: ^Document, h: base.Handle, composed, window_ok: bool, first: base.Handle) -> (base.Handle, bool) {
		n := get(d, h)
		if n == nil { return base.NIL_HANDLE, false }
		if h == d.root { return base.NIL_HANDLE, window_ok }
		if n.is_shadow {
			if !composed && tree_root(d, first) == h { return base.NIL_HANDLE, false }
			return n.shadow, false
		}
		if n.slot != base.NIL_HANDLE { return n.slot, false }
		return n.parent, false
	}

	// the event path
	path := make([dynamic]Path_Entry)
	{
		cur_target := target
		rel := retarget_rel(d, original_related, target)
		if u64(cur_target) != rel || u64(target) == original_related {
			append(&path, Path_Entry{node = target, shadow_target = target, related = rel, root_of_closed_tree = closed_root(d, target)})
			slottable := get(d, target).slot != base.NIL_HANDLE
			slot_in_closed := false
			parent, is_win := get_parent(d, target, composed, to_window_ok, target)
			for parent != base.NIL_HANDLE || is_win {
				if slottable {
					slottable = false
					if closed_root(d, tree_root(d, parent)) { slot_in_closed = true }
				}
				if is_win {
					rel = original_related
					if rel != 0 && get(d, base.Handle(rel)) != nil {
						// retargeted against the Window: out of every shadow tree
						r := base.Handle(rel)
						for {
							rr := tree_root(d, r)
							rn := get(d, rr)
							if rn == nil || !rn.is_shadow { break }
							r = rn.shadow
						}
						rel = u64(r)
					}
					append(&path, Path_Entry{window = true, related = rel, slot_in_closed_tree = slot_in_closed})
					break
				}
				rel = retarget_rel(d, original_related, parent)
				if shadow_including_ancestor(d, tree_root(d, cur_target), parent) {
					append(&path, Path_Entry{node = parent, related = rel, root_of_closed_tree = closed_root(d, parent), slot_in_closed_tree = slot_in_closed})
				} else if u64(parent) == rel {
					break
				} else {
					cur_target = parent
					append(&path, Path_Entry{node = parent, shadow_target = parent, related = rel, root_of_closed_tree = closed_root(d, parent), slot_in_closed_tree = slot_in_closed})
				}
				slot_in_closed = false
				parent, is_win = get_parent(d, parent, composed, to_window_ok, target)
			}
		}
	}
	// DOM "clear targets", decided on the path as built (listeners moving nodes do not change it): the last struct's
	// shadow-adjusted target or relatedTarget is in a shadow tree
	clear_targets := false
	if has_shadow_trees(d) {
		for &s in path { if !s.window { s.in_shadow_tree = is_shadow_root(d, tree_root(d, s.node)) } }
	}
	for i := len(path) - 1; i >= 0; i -= 1 {
		s := path[i]
		if s.shadow_target == base.NIL_HANDLE { continue }
		clear_targets = is_shadow_root(d, tree_root(d, s.shadow_target))
		if s.related != 0 && get(d, base.Handle(s.related)) != nil && is_shadow_root(d, tree_root(d, base.Handle(s.related))) { clear_targets = true }
		break
	}
	if e := base.pool_get(&dp.events, eh); e != nil { e.path = path } else { delete(path) }

	run_node :: proc(d: ^Document, dp: ^Dispatcher, eh: base.Handle, node: base.Handle, phase: Phase, capture: bool) -> bool {
		e := base.pool_get(&dp.events, eh)
		n := get(d, node)
		if e == nil || n == nil { return true }
		e.current_target = node
		e.phase = phase
		snapshot: [dynamic]Listener
		defer delete(snapshot)
		for l in n.listeners {
			if l.removed || l.type != e.type || l.capture != capture { continue }
			snap := l
			snap.type = ""   // the node's string: a listener may remove (and free) it; the event has the type
			append(&snapshot, snap)
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

	// one struct of the path: target and relatedTarget as seen from it, then its listeners of one pass
	invoke :: proc(d: ^Document, dp: ^Dispatcher, eh: base.Handle, i: int, capture: bool) -> bool {
		e := base.pool_get(&dp.events, eh)
		if e == nil { return true }
		s := e.path[i]
		for j := i; j >= 0; j -= 1 {
			if e.path[j].shadow_target != base.NIL_HANDLE { e.target = e.path[j].shadow_target; break }
		}
		e.related = s.related
		e.path_index = i
		phase: Phase = s.shadow_target != base.NIL_HANDLE ? .At_Target : (capture ? .Capturing : .Bubbling)
		if e.stop { return true }
		if s.window {
			e.phase = phase
			e.current_target = base.NIL_HANDLE
			return dp.window(dp.user, eh, capture)
		}
		return run_node(d, dp, eh, s.node, phase, capture)
	}

	n_path := len(path)
	for i := n_path - 1; i >= 0; i -= 1 {
		if !invoke(d, dp, eh, i, true) { return true, target }
	}
	for i in 0 ..< n_path {
		e := base.pool_get(&dp.events, eh)
		if e == nil { break }
		if e.path[i].shadow_target == base.NIL_HANDLE && !e.bubbles { continue }
		if !invoke(d, dp, eh, i, false) { return true, target }
	}

	e := base.pool_get(&dp.events, eh)
	if e == nil { return true, target }
	e.phase = .None
	e.current_target = base.NIL_HANDLE
	final_target = e.target
	final_related := e.related
	if clear_targets { final_target, final_related = base.NIL_HANDLE, 0 }
	dp.last_target, dp.last_related = final_target, final_related
	return !(e.cancelable && e.default_prevented), final_target
}

// The type ("click", "load"...) of the event being dispatched, by its handle, or "" when the handle is stale. Used by the
// Long Animation Frames instrumentation to name the invoker of an event listener (src/page/timeline_loaf.odin).
event_type :: proc(dp: ^Dispatcher, eh: base.Handle) -> string {
	e := base.pool_get(&dp.events, eh)
	return e != nil ? e.type : ""
}

// Event.composedPath() of the event being dispatched (DOM §2.9): the invocation targets around the current one that a
// listener there may see (closed shadow trees it is not inside are hidden). A NIL handle stands for the Window.
composed_path :: proc(dp: ^Dispatcher, eh: base.Handle, allocator := context.temp_allocator) -> []base.Handle {
	e := base.pool_get(&dp.events, eh)
	out := make([dynamic]base.Handle, allocator)
	if e == nil || len(e.path) == 0 || e.phase == .None { return out[:] }
	path := e.path[:]
	inv :: proc(s: Path_Entry) -> base.Handle { return s.window ? base.NIL_HANDLE : s.node }
	cur_index := clamp(e.path_index, 0, len(path) - 1)
	// currentTarget's hidden level, from the outermost struct in
	hidden := 0
	for index := len(path) - 1; index >= 0; index -= 1 {
		if path[index].root_of_closed_tree { hidden += 1 }
		if index == cur_index { break }
		if path[index].slot_in_closed_tree { hidden -= 1 }
	}
	before := make([dynamic]base.Handle, context.temp_allocator)
	level, max_level := hidden, hidden
	for index := cur_index - 1; index >= 0; index -= 1 {
		if path[index].root_of_closed_tree { level += 1 }
		if level <= max_level { append(&before, inv(path[index])) }
		if path[index].slot_in_closed_tree {
			level -= 1
			if level < max_level { max_level = level }
		}
	}
	for i := len(before) - 1; i >= 0; i -= 1 { append(&out, before[i]) }
	append(&out, inv(path[cur_index]))
	level, max_level = hidden, hidden
	for index in cur_index + 1 ..< len(path) {
		if path[index].slot_in_closed_tree { level += 1 }
		if level <= max_level { append(&out, inv(path[index])) }
		if path[index].root_of_closed_tree {
			level -= 1
			if level < max_level { max_level = level }
		}
	}
	return out[:]
}