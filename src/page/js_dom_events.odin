package page

// Events for JavaScript beyond the core (api/js_dom_events.widl): the details of the UI events the browser
// dispatches (MouseEvent, PointerEvent, WheelEvent, KeyboardEvent, FocusEvent), and the Window's part of the
// propagation path (dom.Dispatcher.window): after the document comes the Window, whose listeners are those of the
// page's Window host object (bindings_history.odin, window_object), for every event but `load`.

import "core:fmt"
import "wb:base"
import "wb:dom"

// dom.Dispatcher.window: runs the Window's listeners of one phase for the event being dispatched.
@(private)
window_phase :: proc(user: rawptr, eh: base.Handle, capture: bool) -> bool {
	p := (^Page)(user)
	if p.closed || p.web == nil || p.web.window == 0 { return true }
	win := p.web.window
	o := object_get(p, win)
	if o == nil || len(o.listeners) == 0 { return true }
	e := base.pool_get(&p.dp.events, eh)
	if e == nil { return true }
	e.current_target = base.Handle(win)
	snapshot := make([dynamic]dom.Listener, 0, 4, context.temp_allocator)
	for l in o.listeners { if !l.removed && l.type == e.type && l.capture == capture { append(&snapshot, l) } }
	for l in snapshot {
		o = object_get(p, win)
		if o == nil { break }
		still := false
		for cur in o.listeners { if cur.id == l.id && !cur.removed { still = true; break } }
		if !still { continue }
		if l.once { object_remove_listener(p, win, l.id) }
		argv := [3]u32{l.user, u32(u64(eh)), u32(u64(eh) >> 32)}
		if inst := instance_by_index(p, l.owner); inst != nil { call_guest(p, inst, l.callback, argv[:]) }
		e = base.pool_get(&p.dp.events, eh)
		if e == nil || e.stop_immediate { break }
		e.current_target = base.Handle(win)
	}
	if o = object_get(p, win); o != nil {
		k := 0
		for l in o.listeners { if !l.removed { o.listeners[k] = l; k += 1 } }
		resize(&o.listeners, k)
	}
	return true
}

// MouseEvent.buttons of a browser event that did not say: the button pressed for a mousedown (bit 1 primary, 2
// secondary, 4 auxiliary), nothing otherwise.
@(private)
derived_buttons :: proc(e: ^dom.Event) -> u32 {
	if e.buttons != 0 { return u32(e.buttons) }
	switch e.type {
	case "mousedown", "pointerdown":
		switch e.button {
		case 0: return 1
		case 1: return 4
		case 2: return 2
		case 3: return 8
		case 4: return 16
		}
	}
	return 0
}

@(private)
derived_detail :: proc(e: ^dom.Event) -> i32 {
	if e.detail != 0 { return e.detail }
	switch e.type {
	case "click", "mousedown", "mouseup", "auxclick", "contextmenu": return 1
	case "dblclick": return 2
	}
	return 0
}

Event_uiData :: proc(c: ^Call, event: Api_Event) -> Api_UiEventData {
	e := event.data
	p := c.page
	r := Api_UiEventData{
		client_x = e.x, client_y = e.y,
		screen_x = e.screen_x != 0 ? e.screen_x : e.x, screen_y = e.screen_y != 0 ? e.screen_y : e.y,
		delta_x = e.delta[0], delta_y = e.delta[1], delta_z = e.delta[2],
		related = e.related, mods = e.mods, button = e.button, buttons = derived_buttons(e), detail = derived_detail(e),
		key_code = e.key, location = u32(e.location), repeat = e.repeat ? 1 : 0, delta_mode = u32(e.delta_mode),
	}
	r.page_x, r.page_y = e.x, e.y
	r.offset_x, r.offset_y = e.x, e.y
	if p.worker == nil && (e.x != 0 || e.y != 0 || is_pointer_type(e.type)) {
		vp := viewport_now(c)
		r.page_x, r.page_y = e.x + vp.scroll_x, e.y + vp.scroll_y
		// offsetX / offsetY: from the target's padding edge
		if t := e.target; jd_is_element(p.doc, t) {
			if g, _, _ := element_geometry(p, t); g.ok && g.box != nil {
				s := vp.scale > 0 ? vp.scale : 1
				r.offset_x = e.x - (g.client.x + f64(g.box.border[3]) / s)
				r.offset_y = e.y - (g.client.y + f64(g.box.border[0]) / s)
			}
		}
	}
	return r
}

@(private)
is_pointer_type :: proc(t: string) -> bool {
	switch t {
	case "click", "dblclick", "auxclick", "mousedown", "mouseup", "mousemove", "mouseover", "mouseout", "mouseenter",
	     "mouseleave", "contextmenu", "wheel", "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout",
	     "pointerenter", "pointerleave":
		return true
	}
	return false
}

UiEvent_key :: proc(c: ^Call, event: Api_Event) -> string {
	e := event.data
	if e.text != "" && (e.type == "keydown" || e.type == "keyup" || e.type == "keypress") { return e.text }
	return "Unidentified"
}

// KeyboardEvent.code of a Windows virtual-key code (UI Events KeyboardEvent code values, US layout positions).
UiEvent_code :: proc(c: ^Call, event: Api_Event) -> string {
	k := event.data.key
	switch k {
	case 'A' ..= 'Z': return fmt.tprintf("Key%c", rune(k))
	case '0' ..= '9': return fmt.tprintf("Digit%c", rune(k))
	case 0x70 ..= 0x87: return fmt.tprintf("F%d", k - 0x70 + 1)
	case 0x60 ..= 0x69: return fmt.tprintf("Numpad%d", k - 0x60)
	case 8: return "Backspace"
	case 9: return "Tab"
	case 13: return "Enter"
	case 16: return "ShiftLeft"
	case 17: return "ControlLeft"
	case 18: return "AltLeft"
	case 19: return "Pause"
	case 20: return "CapsLock"
	case 27: return "Escape"
	case 32: return "Space"
	case 33: return "PageUp"
	case 34: return "PageDown"
	case 35: return "End"
	case 36: return "Home"
	case 37: return "ArrowLeft"
	case 38: return "ArrowUp"
	case 39: return "ArrowRight"
	case 40: return "ArrowDown"
	case 45: return "Insert"
	case 46: return "Delete"
	case 91: return "MetaLeft"
	case 93: return "ContextMenu"
	case 0x6A: return "NumpadMultiply"
	case 0x6B: return "NumpadAdd"
	case 0x6D: return "NumpadSubtract"
	case 0x6E: return "NumpadDecimal"
	case 0x6F: return "NumpadDivide"
	case 0xBA: return "Semicolon"
	case 0xBB: return "Equal"
	case 0xBC: return "Comma"
	case 0xBD: return "Minus"
	case 0xBE: return "Period"
	case 0xBF: return "Slash"
	case 0xC0: return "Backquote"
	case 0xDB: return "BracketLeft"
	case 0xDC: return "Backslash"
	case 0xDD: return "BracketRight"
	case 0xDE: return "Quote"
	}
	return ""
}
