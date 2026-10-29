package browser

import "wb:base"
import "wb:dom"
import "wb:page"

////////////////////////////////
// The pointer's events for the page: mousemove / pointermove at the element under it, and mouseover / mouseout /
// mouseenter / mouseleave (and the pointer* ones) when that element changes, as UI Events and Pointer Events order them.
// Until now the page only got presses, releases and clicks, so a script could not follow the pointer (a tilting card,
// a custom tooltip, a drag it starts itself).
//
// Called once per frame that moved the pointer, with the element the hit test found (route_page_input): the frame's
// last position is the only one that matters, as for :hover. An event nobody listens to costs the walk of its path.

Pointer_Event :: struct {
	type:       string,
	target:     base.Handle,
	bubbles:    bool,
	cancelable: bool,
}

// What the pointer is over for the scripts: the element the hit test found, else the document's root element (the part of the page no box
// covers: its canvas, a pointer-events: none overlay), as other browsers do. NIL: no document.
hit_or_root :: proc(t: ^Tab, h: base.Handle) -> base.Handle {
	if h == base.NIL_HANDLE && t != nil && t.page != nil { return t.page.doc_el }
	return h
}

// The ancestors of `h` that are elements, `h` first.
@(private = "file")
element_chain :: proc(d: ^dom.Document, h: base.Handle) -> []base.Handle {
	out := make([dynamic]base.Handle, context.temp_allocator)
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element { append(&out, cur) }
		cur = n.parent
	}
	return out[:]
}

// The events for a pointer that was over `was` and is over `now` (either may be NIL: outside the page), in the order
// they are dispatched: out / leave on what it left (deepest first), over / enter on what it entered (outermost first),
// then move; each as pointer* then mouse*. The elements both chains share are neither left nor entered.
pointer_plan :: proc(d: ^dom.Document, was, now: base.Handle) -> []Pointer_Event {
	plan := make([dynamic]Pointer_Event, context.temp_allocator)
	old_chain, new_chain := element_chain(d, was), element_chain(d, now)
	shared := 0
	for shared < len(old_chain) && shared < len(new_chain) && old_chain[len(old_chain) - 1 - shared] == new_chain[len(new_chain) - 1 - shared] { shared += 1 }
	left, entered := old_chain[:len(old_chain) - shared], new_chain[:len(new_chain) - shared]
	if was != now || len(left) > 0 || len(entered) > 0 {
		if len(old_chain) > 0 {
			append(&plan, Pointer_Event{"pointerout", old_chain[0], true, true})
			for h in left { append(&plan, Pointer_Event{"pointerleave", h, false, false}) }
			append(&plan, Pointer_Event{"mouseout", old_chain[0], true, true})
			for h in left { append(&plan, Pointer_Event{"mouseleave", h, false, false}) }
		}
		if len(new_chain) > 0 {
			append(&plan, Pointer_Event{"pointerover", new_chain[0], true, true})
			#reverse for h in entered { append(&plan, Pointer_Event{"pointerenter", h, false, false}) }
			append(&plan, Pointer_Event{"mouseover", new_chain[0], true, true})
			#reverse for h in entered { append(&plan, Pointer_Event{"mouseenter", h, false, false}) }
		}
	}
	if len(new_chain) > 0 {
		append(&plan, Pointer_Event{"pointermove", new_chain[0], true, true})
		append(&plan, Pointer_Event{"mousemove", new_chain[0], true, true})
	}
	return plan[:]
}

// `buttons`: MouseEvent.buttons held during the move; `mouse_only`: the system's emulation of a finger (its pointer
// events came from route_device_pointer). The moves of a captured pointer go to the capturing element.
page_pointer_events :: proc(app: ^App, t: ^Tab, was, now: base.Handle, pos: [2]f32, buttons: u16 = 0, mouse_only := false) {
	wnd := active_window(app)
	p := t.page
	if p == nil { return }
	scale := max(page_scale(app), 0.01)
	cx, cy := f64((pos.x - wnd.page_rect.min.x) / scale), f64((pos.y - wnd.page_rect.min.y) / scale)
	for e in pointer_plan(p.doc, was, now) {
		if mouse_only && len(e.type) > 7 && e.type[:7] == "pointer" { continue }
		target := e.target
		if e.type == "pointermove" || e.type == "mousemove" {
			proto := dom.Event{type = e.type, bubbles = true, cancelable = true, composed = true, x = cx, y = cy, buttons = buttons}
			if e.type == "pointermove" { page.pointer_capture_process(p, page.MOUSE_POINTER_ID, proto) }
			if t.page != p { return }
			target = page.pointer_target(p, page.MOUSE_POINTER_ID, target)
		}
		page.dispatch_event(p, target, dom.Event{type = e.type, bubbles = e.bubbles, cancelable = e.cancelable, x = cx, y = cy, buttons = buttons})
		if t.page != p { return }   // a handler navigated away
	}
}
