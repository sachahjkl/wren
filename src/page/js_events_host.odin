package page

// Events as the JavaScript engine needs them (api/js_events.widl): dispatching the engine's own Event objects, and the
// interface and state of the browser's events for their wrappers.

import "wb:base"
import "wb:dom"

EventTarget_dispatchEngineEvent :: proc(c: ^Call, target: u64, type: string, init: Api_EventInit, engine_id: i64, time_stamp: f64) -> (bool, Api_Error) {
	p := c.page
	ev := dom.Event{
		type = type, bubbles = .Bubbles in init, cancelable = .Cancelable in init, composed = .Composed in init,
		engine_id = engine_id, untrusted = true, time_stamp = time_stamp,
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
	if p.worker != nil || dom.get(p.doc, H(target)) == nil { return false, fail(c, .Invalid_Handle, "dispatchEvent: the target is gone") }
	ok, final := dom.dispatch_ex(p.doc, &p.dp, H(target), ev)
	// the target as the event shows it once dispatched (EventTarget_lastTarget): null when it was in a shadow tree
	js_dom_state(p).shadow.last_target = u64(final)
	return ok, .None
}

Event_engineId :: proc(c: ^Call, event: Api_Event) -> i64 { return event.data.engine_id }

Event_isLive :: proc(c: ^Call, event: u64) -> bool { return base.pool_get(&c.page.dp.events, H(event)) != nil }

Event_bubbles :: proc(c: ^Call, event: Api_Event) -> bool { return event.data.bubbles }
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
	switch event.data.type {
	case "click", "dblclick", "auxclick", "mousedown", "mouseup", "mousemove", "mouseover", "mouseout", "mouseenter",
	     "mouseleave", "contextmenu":
		return JS_IFACE_MouseEvent
	case "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout", "pointerenter", "pointerleave",
	     "pointercancel", "gotpointercapture", "lostpointercapture":
		return JS_IFACE_PointerEvent
	case "wheel": return JS_IFACE_WheelEvent
	case "keydown", "keyup", "keypress": return JS_IFACE_KeyboardEvent
	case "focus", "blur", "focusin", "focusout": return JS_IFACE_FocusEvent
	case "input", "beforeinput": return JS_IFACE_InputEvent
	case "compositionstart", "compositionupdate", "compositionend": return JS_IFACE_CompositionEvent
	case "message", "messageerror": return JS_IFACE_MessageEvent
	case "hashchange": return JS_IFACE_HashChangeEvent
	case "popstate": return JS_IFACE_PopStateEvent
	case "storage": return JS_IFACE_StorageEvent
	case "close": if is_object(u64(event.data.target)) { return JS_IFACE_CloseEvent }
	case "change": if mql_get(c.page, u64(event.data.target)) != nil { return JS_IFACE_MediaQueryListEvent }
	case "submit": return JS_IFACE_SubmitEvent
	case "formdata": return JS_IFACE_FormDataEvent
	case "toggle", "beforetoggle": return JS_IFACE_ToggleEvent
	case "transitionrun", "transitionstart", "transitionend", "transitioncancel": return JS_IFACE_TransitionEvent
	case "animationstart", "animationend", "animationiteration", "animationcancel": return JS_IFACE_AnimationEvent
	case "pageshow", "pagehide": return JS_IFACE_PageTransitionEvent
	case "progress", "loadstart", "loadend", "abort", "timeout":
		if is_object(u64(event.data.target)) { return JS_IFACE_ProgressEvent }
	case "error":
		t := u64(event.data.target)
		// a worker's uncaught error at its Worker object is an ErrorEvent too (worker.odin: message, filename)
		if event.data.data != "" && (!is_object(t) || object_data(c.page, t, &worker_vt) != nil) { return JS_IFACE_ErrorEvent }
	}
	return JS_IFACE_Event
}
