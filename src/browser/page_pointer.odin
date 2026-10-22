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

page_pointer_events :: proc(app: ^App, t: ^Tab, was, now: base.Handle, pos: [2]f32) {
	p := t.page
	if p == nil { return }
	scale := max(page_scale(app), 0.01)
	cx, cy := f64((pos.x - app.page_rect.min.x) / scale), f64((pos.y - app.page_rect.min.y) / scale)
	for e in pointer_plan(p.doc, was, now) {
		page.dispatch_event(p, e.target, dom.Event{type = e.type, bubbles = e.bubbles, cancelable = e.cancelable, x = cx, y = cy})
		if t.page != p { return }   // a handler navigated away
	}
}
