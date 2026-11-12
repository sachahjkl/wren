package dom

import "core:strings"
import "wb:base"

Phase :: enum u8 { None, Capturing, At_Target, Bubbling }

Event :: struct {
	type:            string,    // owned
	atom:            Event_Atom,   // of `type` (event_types.odin), set when it is dispatched
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
	engine_realm:    u64,       // the page whose realm made it: its address means nothing to another realm's listeners
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
	tag:     u32,                // of its handles: the document (base.pool_insert_tagged)
	invoke:  Invoke_Proc,
	user:    rawptr,
	// optional: the Window's listeners. The propagation path of an event whose path reaches the document goes on to
	// the Window (HTML "get the parent" of a Document), except for `load`.
	window:  Window_Proc,
	// optional: the document and dispatcher of a node of another document (a listener moved a node of the path there)
	other:   proc(user: rawptr, node: base.Handle) -> (^Document, ^Dispatcher),
	// the event's target and relatedTarget once the last dispatch ended (NIL / 0 when cleared: they were in a shadow tree)
	last_target:  base.Handle,
	last_related: u64,
}

dispatcher_destroy :: proc(dp: ^Dispatcher) {
	it: u32
	for _, e in base.pool_next(&dp.events, &it) { delete(e.type); delete(e.data); delete(e.text); delete(e.path) }
	base.pool_destroy(&dp.events)
}

// DOM "invoke": the prefixed name of an event that has one; "" for the others.
legacy_event_type :: proc(type: string) -> string {
	return EVENT_TYPES[EVENT_TYPES[event_atom(type)].legacy].name
}

////////////////////////////////
// Listener lists
//
// A node's, a host object's and the Window's listeners are each a [dynamic]Listener, run by the procedures below (one
// copy of the rules: a snapshot of the matching listeners, each run only while still registered, `once` removed before
// it runs, tombstones dropped). `d` is the document whose counts the list is in (listener_changes, the listened
// types); nil for a host object's list.

// Adds a listener to `list` unless the same one is there (DOM: same type, callback, capture: a no-op). `max_live` bounds
// the list (0: no bound): past it, Quota.
listener_add :: proc(list: ^[dynamic]Listener, d: ^Document, id: Listener_Id, type: string, callback, user, owner: u32, capture, once, passive: bool, work: base.Work, max_live: int) -> (Listener_Id, Error) {
	if type == "" { return 0, .Invalid_Argument }
	atom := event_atom(type)
	live := 0
	for l in list^ {
		if l.removed { continue }
		live += 1
		if type_matches(l.atom, l.type, atom, type) && l.callback == callback && l.user == user && l.capture == capture && l.owner == owner { return l.id, .None }
	}
	if max_live > 0 && live >= max_live { return 0, .Quota }
	l := Listener{id = id, type = event_type_string(atom, type), atom = atom, callback = callback, user = user, owner = owner, capture = capture, once = once, passive = passive, work = work}
	append(list, l)
	if d != nil { listener_counted(d, l, 1) }
	return id, .None
}

// Removes listener `id` of `list` (a tombstone: a dispatch in progress reads a copy and finds its listeners again by id).
// Tombstones go when a dispatch ends at the target; a list that never sees an event (listeners added and removed in a
// loop) drops them here once they are half of it.
listener_remove :: proc(list: ^[dynamic]Listener, d: ^Document, id: Listener_Id) -> Error {
	for &l in list^ {
		if l.id != id || l.removed { continue }
		listener_tombstone(&l, d)
		dead := 0
		for x in list^ { if x.removed { dead += 1 } }
		if dead * 2 > len(list^) { listeners_compact(list) }
		return .None
	}
	return .Not_Found
}

// Every listener of `list` goes (tombstones, as listener_remove leaves).
listeners_erase :: proc(list: ^[dynamic]Listener, d: ^Document) {
	for &l in list^ { if !l.removed { listener_tombstone(&l, d) } }
}

// Drops the tombstones of `list`.
listeners_compact :: proc(list: ^[dynamic]Listener) {
	w := 0
	for l in list^ {
		if !l.removed { list^[w] = l; w += 1 }
	}
	resize(list, w)
}

// Frees what the listeners of `list` own (the list itself too), taking the live ones out of `d`'s counts.
listeners_free :: proc(list: ^[dynamic]Listener, d: ^Document) {
	for l in list^ {
		if !l.removed && d != nil { listener_counted(d, l, -1) }
		event_type_free(l.atom, l.type)
	}
	delete(list^)
	list^ = nil
}

// Whether someone in `list` listens for `type`.
listeners_have :: proc(list: []Listener, type: string) -> bool {
	atom := event_atom(type)
	for l in list { if !l.removed && type_matches(l.atom, l.type, atom, type) { return true } }
	return false
}

// Appends to `out` the live listeners of `list` for (`atom`, `type`), of one phase (`capture`) unless `any_phase`.
// The copies do not share the list's strings (a listener may remove, and free, its own): the event has the type.
listeners_snapshot :: proc(list: []Listener, atom: Event_Atom, type: string, capture, any_phase: bool, out: ^[dynamic]Listener) {
	for l in list {
		if l.removed || !type_matches(l.atom, l.type, atom, type) || (!any_phase && l.capture != capture) { continue }
		snap := l
		snap.type = ""
		append(out, snap)
	}
}

// What listeners_run needs of a target: its list as it is now (nil: the target is gone; with the document whose counts
// it is in), running one listener (false: stop dispatching altogether), and whether the event says stop
// (stopImmediatePropagation, or the event is gone).
Listener_Target :: struct {
	user:    rawptr,
	list:    proc(user: rawptr) -> (^[dynamic]Listener, ^Document),
	run:     proc(user: rawptr, l: Listener) -> bool,
	stopped: proc(user: rawptr) -> bool,
}

// Runs the listeners of `snapshot` that are still registered, in order: a `once` one is removed before it runs, the
// owner is the one the list has now (a node moved to another document has its owners in that document's terms).
// Drops the list's tombstones at the end. Returns false when `run` did.
listeners_run :: proc(t: Listener_Target, snapshot: []Listener) -> bool {
	for l in snapshot {
		list, d := t.list(t.user)
		if list == nil { return true }
		run := l
		still := false
		for &cur in list^ {
			if cur.id != l.id || cur.removed { continue }
			still = true
			run.owner = cur.owner
			if cur.once { listener_tombstone(&cur, d) }
			break
		}
		if !still { continue }
		if !t.run(t.user, run) { return false }
		if t.stopped(t.user) { break }
	}
	if list, _ := t.list(t.user); list != nil { listeners_compact(list) }
	return true
}

@(private)
listener_tombstone :: proc(l: ^Listener, d: ^Document) {
	if d != nil { listener_counted(d, l^, -1) }
	event_type_free(l.atom, l.type)
	l.type = ""
	l.removed = true
}

// A live listener added to (+1) or taken from (-1) a list of document `d`: listener_changes moves, and the count of
// its type (Document.listened_atoms, listened_others) that `listens` reads.
@(private)
listener_counted :: proc(d: ^Document, l: Listener, delta: int) {
	d.listener_changes += 1
	if l.atom != .None {
		d.listened_atoms[l.atom] = u32(max(int(d.listened_atoms[l.atom]) + delta, 0))
		return
	}
	if delta > 0 {
		if v, ok := &d.listened_others[l.type]; ok { v^ += delta; return }
		d.listened_others[strings.clone(l.type)] = delta
		return
	}
	if v, ok := &d.listened_others[l.type]; ok {
		v^ += delta
		if v^ <= 0 {
			key, _ := delete_key(&d.listened_others, l.type)
			delete(key)
		}
	}
}

// Whether some node of the document (in its tree or not) has a listener of `type`: an event of that type would run
// the page's code. One read, whatever the size of the document.
listens :: proc(d: ^Document, type: string) -> bool {
	if atom := event_atom(type); atom != .None { return d.listened_atoms[atom] > 0 }
	return d.listened_others[type] > 0
}

add_listener :: proc(d: ^Document, target: base.Handle, type: string, callback, user: u32, capture, once, passive: bool, owner: u32 = 0, work := base.Work{}) -> (Listener_Id, Error) {
	n := get(d, target)
	if n == nil { return 0, .Invalid_Handle }
	id, err := listener_add(&n.listeners, d, d.next_listener, type, callback, user, owner, capture, once, passive, work, d.limits.max_listeners)
	if err == .None && id == d.next_listener { d.next_listener += 1 }
	return id, err
}

remove_listener :: proc(d: ^Document, target: base.Handle, id: Listener_Id) -> Error {
	n := get(d, target)
	if n == nil { return .Invalid_Handle }
	return listener_remove(&n.listeners, d, id)
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
		listeners_erase(&n.listeners, d)
		listeners_compact(&n.listeners)
		if n.kind == .Element && n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = get(d, ch).next { append(&stack, ch) }
	}
}

// Event types the browser dispatches with `composed` set (UI Events, Pointer Events, Input Events, HTML focus): they
// cross shadow boundaries. Events scripts make say themselves.
ui_composed :: proc(type: string) -> bool { return EVENT_TYPES[event_atom(type)].composed }

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
	ev.atom = event_atom(proto.type)
	if !proto.untrusted && proto.engine_id == 0 && !proto.composed { ev.composed = EVENT_TYPES[ev.atom].composed }
	original_related := proto.related
	eh, _ := base.pool_insert_tagged(&dp.events, dp.tag, ev)
	defer {
		if e := base.pool_get(&dp.events, eh); e != nil { delete(e.type); delete(e.data); delete(e.text); delete(e.path) }
		base.pool_remove_tagged(&dp.events, eh)
	}
	composed := base.pool_get(&dp.events, eh).composed
	to_window_ok := dp.window != nil && ev.atom != .load

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

	// the event path. The tree roots it compares are carried along the walk, not looked up again at each ancestor: a
	// parent reached by its child's `parent` link has that child's root, so only a step across a shadow boundary (to a slot
	// or a host) looks one up, and the ancestry test of two roots is redone only when one of them changes. A document
	// without shadow trees needs neither (one tree: every ancestor is in the target's), and building the path of a
	// deep tree stays O(depth).
	path := make([dynamic]Path_Entry)
	{
		shadows := has_shadow_trees(d)
		cur_target := target
		rel := shadows ? retarget_rel(d, original_related, target) : original_related
		if u64(cur_target) != rel || u64(target) == original_related {
			prev, prev_root := target, shadows ? tree_root(d, target) : base.NIL_HANDLE
			cur_root := prev_root   // the root of cur_target's tree
			anc_cur, anc_parent: base.Handle   // the pair `anc` was computed for
			anc := false
			append(&path, Path_Entry{node = target, shadow_target = target, related = rel, root_of_closed_tree = closed_root(d, target), in_shadow_tree = shadows && is_shadow_root(d, prev_root)})
			slottable := get(d, target).slot != base.NIL_HANDLE
			slot_in_closed := false
			parent, is_win := get_parent(d, target, composed, to_window_ok, target)
			for parent != base.NIL_HANDLE || is_win {
				parent_root := base.NIL_HANDLE
				if shadows && !is_win {
					if pn := get(d, prev); pn != nil && pn.parent == parent { parent_root = prev_root } else { parent_root = tree_root(d, parent) }
				}
				if slottable {
					slottable = false
					if closed_root(d, shadows ? parent_root : tree_root(d, parent)) { slot_in_closed = true }
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
				in_cur_tree := true   // cur_target's root is a shadow-including inclusive ancestor of parent
				if shadows {
					rel = retarget_rel(d, original_related, parent)
					// cur_root is a root: it is an ancestor of `parent` exactly when it is one of parent_root (the only
					// parentless node between them)
					if anc_cur != cur_root || anc_parent != parent_root {
						anc_cur, anc_parent = cur_root, parent_root
						anc = shadow_including_ancestor(d, cur_root, parent_root)
					}
					in_cur_tree = anc
				}
				in_shadow := shadows && is_shadow_root(d, parent_root)
				if in_cur_tree {
					append(&path, Path_Entry{node = parent, related = rel, root_of_closed_tree = closed_root(d, parent), slot_in_closed_tree = slot_in_closed, in_shadow_tree = in_shadow})
				} else if u64(parent) == rel {
					break
				} else {
					cur_target = parent
					cur_root = parent_root
					append(&path, Path_Entry{node = parent, shadow_target = parent, related = rel, root_of_closed_tree = closed_root(d, parent), slot_in_closed_tree = slot_in_closed, in_shadow_tree = in_shadow})
				}
				slot_in_closed = false
				prev, prev_root = parent, parent_root
				parent, is_win = get_parent(d, parent, composed, to_window_ok, target)
			}
		}
	}
	// DOM "clear targets", decided on the path as built (listeners moving nodes do not change it): the last struct's
	// shadow-adjusted target or relatedTarget is in a shadow tree
	// (each entry's in_shadow_tree was set as the path was built)
	clear_targets := false
	for i := len(path) - 1; i >= 0; i -= 1 {
		s := path[i]
		if s.shadow_target == base.NIL_HANDLE { continue }
		clear_targets = is_shadow_root(d, tree_root(d, s.shadow_target))
		if s.related != 0 && get(d, base.Handle(s.related)) != nil && is_shadow_root(d, tree_root(d, base.Handle(s.related))) { clear_targets = true }
		break
	}
	if e := base.pool_get(&dp.events, eh); e != nil { e.path = path } else { delete(path) }

	// The node of the path's current entry and the document holding it now: this one, or the one a listener moved it to while
	// the event was on its way (event_path_moved rewrites the path).
	holder :: proc(d: ^Document, dp: ^Dispatcher, e: ^Event) -> (^Document, ^Dispatcher, base.Handle) {
		node := e.path[e.path_index].node
		if get(d, node) != nil { return d, dp, node }
		if dp.other == nil { return nil, nil, node }
		od, odp := dp.other(dp.user, node)
		return od, odp, node
	}

	run_node :: proc(d_in: ^Document, dp: ^Dispatcher, eh: base.Handle, phase: Phase, capture: bool) -> bool {
		e := base.pool_get(&dp.events, eh)
		if e == nil { return true }
		d, _, node := holder(d_in, dp, e)
		n := d != nil ? get(d, node) : nil
		if n == nil { return true }
		e.current_target = node
		e.phase = phase
		snapshot := make([dynamic]Listener, context.temp_allocator)
		listeners_snapshot(n.listeners[:], e.atom, e.type, capture, false, &snapshot)
		// DOM "invoke": a trusted event nobody listens to under its name goes to those of its legacy name, under that name
		name, atom := e.type, e.atom
		defer if cur := base.pool_get(&dp.events, eh); cur != nil { cur.type, cur.atom = name, atom }
		if legacy := EVENT_TYPES[e.atom].legacy; legacy != .None && len(snapshot) == 0 && !e.untrusted {
			listeners_snapshot(n.listeners[:], legacy, EVENT_TYPES[legacy].name, capture, false, &snapshot)
			if len(snapshot) > 0 { e.type, e.atom = EVENT_TYPES[legacy].name, legacy }
		}
		// the node is looked up again before each listener: one may have moved it to another document (its listeners
		// went with it, owners in that document's terms) or destroyed it
		Node_Run :: struct { d_in: ^Document, dp: ^Dispatcher, eh: base.Handle, runner: ^Dispatcher, node: base.Handle }
		r := Node_Run{d_in = d_in, dp = dp, eh = eh}
		return listeners_run(Listener_Target{
			user = &r,
			list = proc(user: rawptr) -> (^[dynamic]Listener, ^Document) {
				r := (^Node_Run)(user)
				e := base.pool_get(&r.dp.events, r.eh)
				if e == nil { return nil, nil }
				d, runner, node := holder(r.d_in, r.dp, e)
				n := d != nil ? get(d, node) : nil
				if n == nil { return nil, nil }
				r.runner, r.node = runner, node
				return &n.listeners, d
			},
			run = proc(user: rawptr, l: Listener) -> bool {
				r := (^Node_Run)(user)
				if e := base.pool_get(&r.dp.events, r.eh); e != nil { e.current_target = r.node }
				return r.runner.invoke(r.runner.user, l, r.eh)
			},
			stopped = proc(user: rawptr) -> bool {
				r := (^Node_Run)(user)
				e := base.pool_get(&r.dp.events, r.eh)
				return e == nil || e.stop_immediate
			},
		}, snapshot[:])
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
		return run_node(d, dp, eh, phase, capture)
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

// A node moved to another document under a new handle (Frame_adoptNode): the events on their way through it go on there, as
// DOM's path does not change.
event_path_moved :: proc(dp: ^Dispatcher, from, to: base.Handle) {
	it: u32
	for _, e in base.pool_next(&dp.events, &it) {
		if e.target == from { e.target = to }
		if e.current_target == from { e.current_target = to }
		for &s in e.path {
			if s.node == from { s.node = to }
			if s.shadow_target == from { s.shadow_target = to }
		}
	}
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