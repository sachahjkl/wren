package page

// Pointer capture (Pointer Events §10) and touch events (Touch Events) for the shell's input routing.
//
// Capture: Element.setPointerCapture records a pending capture; the shell asks pointer_capture_process before each event
// of that pointer, which fires gotpointercapture / lostpointercapture as the pending target replaces the active one, and
// pointer_target to retarget the event to the capturing element. A pointer's capture is released implicitly after its
// pointerup / pointercancel (pointer_up), and when the element leaves the document.
//
// Touches: touch_dispatch fires touchstart / touchmove / touchend / touchcancel with the page's active touches; each
// touch keeps the element it started on. The lists are read by the engine when it wraps the event (TouchEvent_count,
// TouchEvent_touch).

import "wb:base"
import "wb:dom"

@(private)
Capture :: struct {
	id:      i32,
	active:  base.Handle,
	pending: base.Handle,
}

@(private)
Pointer_Page :: struct {
	captures: [dynamic]Capture,
	down:     [dynamic]i32,        // pointers with a button / contact down (the mouse is always active)
	touches:  [dynamic]Touch_Point,
	dispatch: ^Touch_Dispatch,     // the touch event being dispatched
	mouse_held: bool,              // a mouse button is held over the page
}

// One finger on the page.
Touch_Point :: struct {
	id:       i32,
	target:   base.Handle,
	x, y:     f64,          // client
	screen:   [2]f64,
	radius:   [2]f64,
	angle:    f64,
	force:    f64,
}

@(private)
Touch_Dispatch :: struct {
	event:   base.Handle,
	touches: []Touch_Point,
	target:  []Touch_Point,
	changed: []Touch_Point,
	scroll:  [2]f64,
}

MOUSE_POINTER_ID :: 1

// (a field of the page, not a table of the process: pages run on several threads, and a table is not left behind at exit)
@(private)
pointer_page :: proc(p: ^Page, create := true) -> ^Pointer_Page {
	pp := p.pointer
	if pp == nil && create && !p.closed {
		pp = new(Pointer_Page)
		p.pointer = pp
		base.on_close(p.scope, proc(data: rawptr) {
			pg := (^Page)(data)
			if pp := pg.pointer; pp != nil {
				delete(pp.captures)
				delete(pp.down)
				delete(pp.touches)
				free(pp)
				pg.pointer = nil
			}
		}, p)
	}
	return pp
}

@(private)
pointer_is_active :: proc(p: ^Page, id: i32) -> bool {
	if id == MOUSE_POINTER_ID { return true }
	pp := pointer_page(p, false)
	if pp == nil { return false }
	for d in pp.down { if d == id { return true } }
	return false
}

@(private)
capture_of :: proc(pp: ^Pointer_Page, id: i32, create: bool) -> ^Capture {
	for &c in pp.captures { if c.id == id { return &c } }
	if !create { return nil }
	append(&pp.captures, Capture{id = id})
	return &pp.captures[len(pp.captures) - 1]
}

// A pointer went down / came up (the shell, for fingers and pens: their capture needs them active).
pointer_set_down :: proc(p: ^Page, id: i32, down: bool) {
	pp := pointer_page(p)
	if pp == nil { return }
	for d, i in pp.down {
		if d == id {
			if !down { unordered_remove(&pp.down, i) }
			return
		}
	}
	if down { append(&pp.down, id) }
}

PointerCapture_set :: proc(c: ^Call, element: Api_Element, pointer_id: i32) -> Api_Error {
	p := c.page
	if !pointer_is_active(p, pointer_id) { return fail(c, .Not_Found, "No active pointer with the given id is found.") }
	if !dom.is_connected(p.doc, H(element.handle)) { return fail(c, .Invalid_State, "The element is not connected.") }
	pp := pointer_page(p)
	if pp == nil { return .None }
	// the mouse only captures while a button is held (Pointer Events: "active buttons state")
	if pointer_id == MOUSE_POINTER_ID && !mouse_buttons_held(p) { return .None }
	capture_of(pp, pointer_id, true).pending = H(element.handle)
	return .None
}

PointerCapture_release :: proc(c: ^Call, element: Api_Element, pointer_id: i32) -> Api_Error {
	p := c.page
	if !pointer_is_active(p, pointer_id) { return fail(c, .Not_Found, "No active pointer with the given id is found.") }
	pp := pointer_page(p, false)
	if pp == nil { return .None }
	if cap := capture_of(pp, pointer_id, false); cap != nil && cap.pending == H(element.handle) { cap.pending = base.NIL_HANDLE }
	return .None
}

PointerCapture_has :: proc(c: ^Call, element: Api_Element, pointer_id: i32) -> bool {
	pp := pointer_page(c.page, false)
	if pp == nil { return false }
	cap := capture_of(pp, pointer_id, false)
	return cap != nil && cap.pending == H(element.handle)
}

// The shell says whether a mouse button is held over the page (the mouse captures only then).
pointer_mouse_held :: proc(p: ^Page, held: bool) {
	if pp := pointer_page(p, held); pp != nil { pp.mouse_held = held }
}

@(private)
mouse_buttons_held :: proc(p: ^Page) -> bool {
	pp := pointer_page(p, false)
	return pp != nil && pp.mouse_held
}

// Pointer Events "process pending pointer capture" before an event of pointer `id`: lostpointercapture at the element
// that loses it, gotpointercapture at the one that gets it.
pointer_capture_process :: proc(p: ^Page, id: i32, proto: dom.Event) {
	pp := pointer_page(p, false)
	if pp == nil { return }
	cap := capture_of(pp, id, false)
	if cap == nil { return }
	if cap.pending != base.NIL_HANDLE && !dom.is_connected(p.doc, cap.pending) { cap.pending = base.NIL_HANDLE }
	if cap.pending == cap.active { return }
	old, now := cap.active, cap.pending
	cap.active = now
	ev := proto
	ev.bubbles, ev.cancelable, ev.composed = true, false, true
	if old != base.NIL_HANDLE && dom.get(p.doc, old) != nil {
		ev.type = "lostpointercapture"
		dispatch_event(p, old, ev)
	}
	if now != base.NIL_HANDLE && dom.get(p.doc, now) != nil {
		ev.type = "gotpointercapture"
		dispatch_event(p, now, ev)
	}
}

// The element a pointer event of `id` goes to: the capturing element, else `hit`.
pointer_target :: proc(p: ^Page, id: i32, hit: base.Handle) -> base.Handle {
	pp := pointer_page(p, false)
	if pp == nil { return hit }
	if cap := capture_of(pp, id, false); cap != nil && cap.active != base.NIL_HANDLE && dom.is_connected(p.doc, cap.active) { return cap.active }
	return hit
}

// After pointerup / pointercancel: the capture is released (lostpointercapture fires now).
pointer_up :: proc(p: ^Page, id: i32, proto: dom.Event) {
	if pp := pointer_page(p, false); pp != nil {
		if cap := capture_of(pp, id, false); cap != nil { cap.pending = base.NIL_HANDLE }
	}
	pointer_capture_process(p, id, proto)
	if id != MOUSE_POINTER_ID { pointer_set_down(p, id, false) }
}

////////////////////////////////
// Touch events

Touch_Phase :: enum u8 { Start, Move, End, Cancel }

// Fires the touch event of `phase` for the finger `t` (its target: the element hit at touchstart; ignored after).
// Returns false when a listener cancelled it (the shell then drops the system's mouse emulation of that touch).
touch_dispatch :: proc(p: ^Page, phase: Touch_Phase, t: Touch_Point, mods: u32, scroll: [2]f64) -> bool {
	pp := pointer_page(p)
	if pp == nil || p.doc == nil { return true }
	idx := -1
	for tp, i in pp.touches { if tp.id == t.id { idx = i; break } }
	changed := t
	switch phase {
	case .Start:
		if idx >= 0 { pp.touches[idx] = t } else { append(&pp.touches, t) }
	case .Move, .End, .Cancel:
		if idx < 0 { return true }
		changed.target = pp.touches[idx].target
		pp.touches[idx] = changed
	}
	target := changed.target
	if target == base.NIL_HANDLE || dom.get(p.doc, target) == nil {
		if phase == .End || phase == .Cancel { touch_forget(pp, t.id) }
		return true
	}
	all := make([dynamic]Touch_Point, context.temp_allocator)
	on_target := make([dynamic]Touch_Point, context.temp_allocator)
	for tp in pp.touches {
		if (phase == .End || phase == .Cancel) && tp.id == t.id { continue }   // a finger that left is in changedTouches only
		append(&all, tp)
		if tp.target == target { append(&on_target, tp) }
	}
	ch := []Touch_Point{changed}
	d := Touch_Dispatch{touches = all[:], target = on_target[:], changed = ch, scroll = scroll}
	saved := pp.dispatch
	pp.dispatch = &d
	names := [Touch_Phase]string{.Start = "touchstart", .Move = "touchmove", .End = "touchend", .Cancel = "touchcancel"}
	ok := dispatch_event(p, target, dom.Event{type = names[phase], bubbles = true, cancelable = phase != .Cancel, composed = true, x = changed.x, y = changed.y, mods = mods})
	if pp2 := pointer_page(p, false); pp2 == pp {
		pp.dispatch = saved
		if phase == .End || phase == .Cancel { touch_forget(pp, t.id) }
	}
	return ok
}

@(private)
touch_forget :: proc(pp: ^Pointer_Page, id: i32) {
	for tp, i in pp.touches { if tp.id == id { ordered_remove(&pp.touches, i); return } }
}

@(private)
touch_list :: proc(c: ^Call, event: Api_Event, list: Api_TouchListKind) -> ([]Touch_Point, [2]f64) {
	pp := pointer_page(c.page, false)
	if pp == nil || pp.dispatch == nil { return nil, {} }
	switch event.data.type {
	case "touchstart", "touchmove", "touchend", "touchcancel":
	case: return nil, {}
	}
	d := pp.dispatch
	switch list {
	case .Touches: return d.touches, d.scroll
	case .Target_Touches: return d.target, d.scroll
	case .Changed_Touches: return d.changed, d.scroll
	}
	return nil, {}
}

TouchEvent_count :: proc(c: ^Call, event: Api_Event, list: Api_TouchListKind) -> i32 {
	l, _ := touch_list(c, event, list)
	return i32(len(l))
}

TouchEvent_touch :: proc(c: ^Call, event: Api_Event, list: Api_TouchListKind, index: i32) -> (Api_TouchPoint, Api_Error) {
	l, scroll := touch_list(c, event, list)
	if index < 0 || int(index) >= len(l) { return {}, fail(c, .Invalid_Argument, "no touch at this index") }
	t := l[index]
	return Api_TouchPoint{
		identifier = t.id, target = u64(t.target), client_x = t.x, client_y = t.y,
		screen_x = t.screen.x != 0 ? t.screen.x : t.x, screen_y = t.screen.y != 0 ? t.screen.y : t.y,
		page_x = t.x + scroll.x, page_y = t.y + scroll.y,
		radius_x = t.radius.x, radius_y = t.radius.y, rotation_angle = t.angle, force = t.force,
	}, .None
}
