package page

// Events as the JavaScript engine needs them (api/js_events.widl): dispatching the engine's own Event objects, and the
// interface and state of the browser's events for their wrappers.

import "wb:base"
import "wb:dom"
import "wb:forms"

EventTarget_dispatchEngineEvent :: proc(c: ^Call, target: u64, type: string, init: Api_EventInit, engine_id: i64, time_stamp: f64) -> (bool, Api_Error) {
	p := c.page
	ev := dom.Event{
		type = type, bubbles = .Bubbles in init, cancelable = .Cancelable in init, composed = .Composed in init,
		engine_id = engine_id, engine_realm = page_id(c.caller), untrusted = true, time_stamp = time_stamp,
	}
	if p.jsdom != nil {
		p.jsdom.shadow.last_target = target
		ev.related = p.jsdom.shadow.next_related   // Event_setNextRelated, for this dispatch only
		p.jsdom.shadow.next_related = 0
	}
	p.dp.last_related = ev.related
	if is_object(target) {
		if object_get(p, target) == nil { return false, fail(c, .Invalid_Handle, "dispatchEvent: the target is gone") }
		return object_dispatch(p, target, ev), .None
	}
	// (the realm that dispatched asks for the results next, with no node to name this document)
	defer if c.routed {
		q := js_dom_state(c.caller)
		q.shadow.last_target = js_dom_state(p).shadow.last_target
		c.caller.dp.last_related = p.dp.last_related
	}
	if p.worker != nil || dom.get(p.doc, H(target)) == nil { return false, fail(c, .Invalid_Handle, "dispatchEvent: the target is gone") }
	if type == "click" && .Activation in init && p.formctl != nil {
		// a script's MouseEvent click: its target's activation behaviour around its dispatch (DOM "dispatch" steps 5.3
		// and 11 to 13, as the browser's own clicks: forms.click)
		Dispatch :: struct { p: ^Page, target: base.Handle, ev: dom.Event, final: base.Handle }
		d := Dispatch{p = p, target = H(target), ev = ev, final = H(target)}
		ok := forms.click(page_forms(p), H(target), {}, forms.Click_Dispatch{user = &d, bubbles = ev.bubbles, fire = proc(user: rawptr) -> bool {
			x := (^Dispatch)(user)
			ok: bool
			ok, x.final = dom.dispatch_ex(x.p.doc, &x.p.dp, x.target, x.ev)
			return ok
		}})
		js_dom_state(p).shadow.last_target = u64(d.final)
		return ok, .None
	}
	ok, final := dom.dispatch_ex(p.doc, &p.dp, H(target), ev)
	// the target as the event shows it once dispatched (EventTarget_lastTarget): null when it was in a shadow tree
	js_dom_state(p).shadow.last_target = u64(final)
	return ok, .None
}

// (0 for the listeners of another realm than the one that made it: to them it is an event of the browser's)
Event_engineId :: proc(c: ^Call, event: Api_Event) -> i64 {
	return event.data.engine_realm == page_id(c.caller) ? event.data.engine_id : 0
}

Event_isLive :: proc(c: ^Call, event: u64) -> bool { return base.pool_get(&c.page.dp.events, H(event)) != nil }

Event_bubbles :: proc(c: ^Call, event: Api_Event) -> bool { return event.data.bubbles }
Event_composed :: proc(c: ^Call, event: Api_Event) -> bool { return event.data.composed }
Event_cancelable :: proc(c: ^Call, event: Api_Event) -> bool { return event.data.cancelable }
Event_eventPhase :: proc(c: ^Call, event: Api_Event) -> i32 { return i32(event.data.phase) }
Event_isTrusted :: proc(c: ^Call, event: Api_Event) -> bool { return !event.data.untrusted }
Event_propagationStopped :: proc(c: ^Call, event: Api_Event) -> bool { return event.data.stop }

Event_timeStamp :: proc(c: ^Call, event: Api_Event) -> f64 {
	if event.data.time_stamp == 0 { event.data.time_stamp = page_now_ms(c.page) }
	return event.data.time_stamp
}

EventTarget_create :: proc(c: ^Call) -> u64 { return object_create(c.page, &event_target_vt, nil, c.owner) }

@(private)
event_target_vt := Object_VTable{name = "EventTarget"}

// The wrapper interface of an event the browser made, from its type (UI Events, HTML, CSSOM...).
Event_interface :: proc(c: ^Call, event: Api_Event) -> u32 {
	// (the event type's class: one table read, dom/event_types.odin)
	switch dom.event_info(event_atom_of(event.data)).class {
	case .Event: return JS_IFACE_Event
	case .Mouse: return JS_IFACE_MouseEvent
	case .Pointer: return JS_IFACE_PointerEvent
	case .Drag: return JS_IFACE_DragEvent
	case .Touch: return JS_IFACE_TouchEvent
	case .Wheel: return JS_IFACE_WheelEvent
	case .Keyboard: return JS_IFACE_KeyboardEvent
	case .Focus: return JS_IFACE_FocusEvent
	case .Input: return JS_IFACE_InputEvent
	case .Composition: return JS_IFACE_CompositionEvent
	case .Message: return JS_IFACE_MessageEvent
	case .Hash_Change: return JS_IFACE_HashChangeEvent
	case .Pop_State: return JS_IFACE_PopStateEvent
	case .Storage: return JS_IFACE_StorageEvent
	case .Close: if is_object(u64(event.data.target)) { return JS_IFACE_CloseEvent }
	case .Change: if mql_get(c.page, u64(event.data.target)) != nil { return JS_IFACE_MediaQueryListEvent }
	case .Submit: return JS_IFACE_SubmitEvent
	case .Form_Data: return JS_IFACE_FormDataEvent
	case .Toggle: return JS_IFACE_ToggleEvent
	case .Transition: return JS_IFACE_TransitionEvent
	case .Animation: return JS_IFACE_AnimationEvent
	case .Page_Transition: return JS_IFACE_PageTransitionEvent
	case .Before_Unload: return JS_IFACE_BeforeUnloadEvent
	case .Playback:
		if object_data(c.page, u64(event.data.target), &web_animation_vt) != nil { return JS_IFACE_AnimationPlaybackEvent }
	case .Progress:
		if is_object(u64(event.data.target)) { return JS_IFACE_ProgressEvent }
	case .Error:
		t := u64(event.data.target)
		// a worker's uncaught error at its Worker object is an ErrorEvent too (worker.odin: message, filename)
		if event.data.data != "" && (!is_object(t) || object_data(c.page, t, &worker_vt) != nil || nested_of(c.page, t) != nil) { return JS_IFACE_ErrorEvent }
	}
	return JS_IFACE_Event
}
