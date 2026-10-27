package page

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:style"

// The Popover API (HTML §6.12; api/popover.widl, native/js/runtime/dom_popover.c): the `popover` attribute, showPopover /
// hidePopover / togglePopover, the popover target attributes of buttons (forms/activation.odin calls popover_invoke),
// light dismiss (a trusted click outside the showing auto popovers: popover_light_dismiss) and Escape as a close request.
//
// The showing popovers are kept in the order they were shown; the auto ones (and hints) form the popover stack, where
// showing an auto popover first hides those that are not its ancestors (its DOM ancestors, or its invoker's). Their
// state reaches the style engine through the control provider (:popover-open: bindings_forms.odin), so the UA sheet
// shows them (style/ua.odin: fixed to the viewport, above the page), and they are the style engine's top layer
// (popover_restyle: style.engine_set_top_layer, their ancestors' stacking contexts undone). `beforetoggle` is fired
// at once (cancelable when it opens); `toggle` is queued and coalesced per popover (its oldState stays the first one).
// A popover removed from the document stops showing without events.

Popover_Kind :: enum u8 { None, Auto, Manual, Hint }

Popover_State :: struct {
	showing:    [dynamic]base.Handle,           // in the order they were shown
	invokers:   map[base.Handle]base.Handle,    // the button (or element given as source) that showed each
	focus_back: map[base.Handle]base.Handle,    // what had the focus before each was shown
	toggles:    [dynamic]Popover_Toggle,        // queued toggle events
	timer:      base.Handle,
	busy:       int,                            // nesting of show / hide (listeners may call them again)
}

@(private)
Popover_Toggle :: struct { el: base.Handle, old_open, new_open: bool, source: base.Handle }

@(private)
popover_state_destroy :: proc(p: ^Page, s: ^Popover_State) {
	if s.timer != base.NIL_HANDLE { host.clear_timer(p.loop, s.timer) }
	delete(s.showing)
	delete(s.invokers)
	delete(s.focus_back)
	delete(s.toggles)
}

@(private)
popover_state :: proc(p: ^Page) -> ^Popover_State { return p.formctl != nil ? &p.formctl.popover : nil }

@(private)
node_attr :: proc(n: ^dom.Node, name: string) -> (string, bool) {
	if n == nil || n.kind != .Element { return "", false }
	for a in n.attrs { if a.name == name { return a.value, true } }   // (names are stored in lower case)
	return "", false
}

// The popover attribute's state (an invalid value is manual; an empty one auto).
popover_kind :: proc(n: ^dom.Node) -> Popover_Kind {
	if n == nil || n.kind != .Element || n.ns != .HTML { return .None }
	v, ok := node_attr(n, "popover")
	if !ok { return .None }
	if v == "" || strings.equal_fold(v, "auto") { return .Auto }
	if strings.equal_fold(v, "hint") { return .Hint }
	return .Manual
}

// `el` is a showing popover (pruning those that left the document).
popover_showing :: proc(p: ^Page, el: base.Handle) -> bool {
	s := popover_state(p)
	if s == nil { return false }
	for h, i in s.showing {
		if h != el { continue }
		if !dom.is_connected(p.doc, el) { popover_forget(p, s, i); return false }
		return true
	}
	return false
}

@(private)
popover_forget :: proc(p: ^Page, s: ^Popover_State, i: int) {
	h := s.showing[i]
	ordered_remove(&s.showing, i)
	delete_key(&s.invokers, h)
	delete_key(&s.focus_back, h)
	popover_restyle(p)
}

@(private)
popover_restyle :: proc(p: ^Page) {
	if p.engine == nil { return }
	p.engine.restyle_needed = true
	// the showing popovers are the top layer: their ancestors no longer hold them inside the page
	if s := popover_state(p); s != nil { style.engine_set_top_layer(p.engine, s.showing[:]) } else { style.engine_set_top_layer(p.engine, nil) }
}

// The auto (and hint) popovers showing, bottom to top.
@(private)
popover_stack :: proc(p: ^Page, s: ^Popover_State) -> [dynamic]base.Handle {
	out := make([dynamic]base.Handle, 0, len(s.showing), context.temp_allocator)
	for i := len(s.showing) - 1; i >= 0; i -= 1 {
		if !dom.is_connected(p.doc, s.showing[i]) { popover_forget(p, s, i) }
	}
	for h in s.showing {
		k := popover_kind(dom.get(p.doc, h))
		if k == .Auto || k == .Hint { append(&out, h) }
	}
	return out
}

// "Check popover validity": ok false when the element is already in the wanted state; an error when it cannot be one.
@(private)
popover_check :: proc(p: ^Page, el: base.Handle, expect_showing: bool) -> (ok: bool, err: Api_Error, msg: string) {
	n := dom.get(p.doc, el)
	if popover_kind(n) == .None { return false, .Not_Supported, "Not supported on elements that do not have a valid value for the 'popover' attribute." }
	if popover_showing(p, el) != expect_showing { return false, .None, "" }
	if !dom.is_connected(p.doc, el) { return false, .Invalid_State, "Invalid on disconnected popover elements." }
	if p.style_state.fullscreen == el { return false, .Invalid_State, "Invalid on popover elements that are in the fullscreen element." }
	return true, .None, ""
}

// The highest popover of the stack that `el` (or its invoker) is inside: what showing `el` must keep open.
@(private)
popover_ancestor :: proc(p: ^Page, stack: []base.Handle, el, invoker: base.Handle) -> base.Handle {
	best := -1
	consider :: proc(p: ^Page, stack: []base.Handle, from: base.Handle, inclusive: bool, best: ^int) {
		for cur := inclusive ? from : dom.parent_or_host(p.doc, from); cur != base.NIL_HANDLE; cur = dom.parent_or_host(p.doc, cur) {
			for h, i in stack { if h == cur && i > best^ { best^ = i } }
		}
	}
	consider(p, stack, el, false, &best)
	if invoker != base.NIL_HANDLE { consider(p, stack, invoker, true, &best) }
	return best >= 0 ? stack[best] : base.NIL_HANDLE
}

// "Hide all popovers until": the popovers above `endpoint` in the stack (all of them for NIL), topmost first.
@(private)
popover_hide_until :: proc(p: ^Page, endpoint: base.Handle, focus_back, fire_events: bool) {
	s := popover_state(p)
	if s == nil { return }
	for _ in 0 ..< 64 {
		stack := popover_stack(p, s)
		if len(stack) == 0 { return }
		top := stack[len(stack) - 1]
		if top == endpoint { return }
		if endpoint != base.NIL_HANDLE {
			found := false
			for h in stack { if h == endpoint { found = true } }
			if !found { return }
		}
		popover_hide(p, top, focus_back, fire_events)
		if popover_showing(p, top) { return }   // a listener showed it again: stop
	}
}

@(private)
popover_queue_toggle :: proc(p: ^Page, el: base.Handle, old_open, new_open: bool, source: base.Handle) {
	s := popover_state(p)
	for &t in s.toggles {
		if t.el == el { t.new_open = new_open; t.source = source; return }   // coalesced: the first oldState stays
	}
	append(&s.toggles, Popover_Toggle{el = el, old_open = old_open, new_open = new_open, source = source})
	if s.timer != base.NIL_HANDLE { return }
	s.timer = host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		p := (^Page)(data)
		s := popover_state(p)
		if p.closed || s == nil { return }
		s.timer = base.NIL_HANDLE
		batch := s.toggles
		s.toggles = make([dynamic]Popover_Toggle)
		defer delete(batch)
		for t in batch {
			if p.closed { return }
			if dom.get(p.doc, t.el) == nil { continue }
			dispatch_event(p, t.el, dom.Event{type = "toggle", data = t.new_open ? "open" : "closed", text = t.old_open ? "open" : "closed", object = u64(t.source)})
		}
	}, p, p.scope)
}

// "Show popover". `invoker`: the button or source element (NIL: none).
popover_show :: proc(p: ^Page, el, invoker: base.Handle) -> (Api_Error, string) {
	s := popover_state(p)
	if s == nil { return .Not_Supported, "no document" }
	ok, err, msg := popover_check(p, el, false)
	if !ok { return err, msg }
	s.busy += 1
	defer s.busy -= 1
	if s.busy > 32 { return .None, "" }
	if !dispatch_event(p, el, dom.Event{type = "beforetoggle", cancelable = true, data = "open", text = "closed", object = u64(invoker)}) { return .None, "" }
	if ok, err, msg = popover_check(p, el, false); !ok { return err, msg }
	kind := popover_kind(dom.get(p.doc, el))
	if kind == .Auto || kind == .Hint {
		stack := popover_stack(p, s)
		ancestor := popover_ancestor(p, stack[:], el, invoker)
		popover_hide_until(p, ancestor, false, true)
		if popover_kind(dom.get(p.doc, el)) != kind { return .Invalid_State, "The popover attribute changed while the popover was shown." }
		if ok, err, msg = popover_check(p, el, false); !ok { return err, msg }
	}
	append(&s.showing, el)
	if invoker != base.NIL_HANDLE { s.invokers[el] = invoker }
	if f := p.formctl; f != nil && f.model.focus != base.NIL_HANDLE { s.focus_back[el] = f.model.focus }
	popover_restyle(p)
	popover_focus_first(p, el)
	popover_queue_toggle(p, el, false, true, invoker)
	return .None, ""
}

// The popover focusing steps: the element itself when it has autofocus, else its first descendant that has.
@(private)
popover_focus_first :: proc(p: ^Page, el: base.Handle) {
	f := p.formctl
	if f == nil { return }
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	append(&stack, el)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(p.doc, h)
		if n == nil || n.kind != .Element { continue }
		if _, ok := node_attr(n, "autofocus"); ok {
			if forms.focus(f.model, h) { return }
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(p.doc, ch).prev { append(&stack, ch) }
	}
}

// "Hide popover"
popover_hide :: proc(p: ^Page, el: base.Handle, focus_back := true, fire_events := true) -> (Api_Error, string) {
	s := popover_state(p)
	if s == nil { return .Not_Supported, "no document" }
	ok, err, msg := popover_check(p, el, true)
	if !ok { return err, msg }
	s.busy += 1
	defer s.busy -= 1
	if s.busy > 32 { return .None, "" }
	kind := popover_kind(dom.get(p.doc, el))
	if kind == .Auto || kind == .Hint {
		popover_hide_until(p, el, focus_back, fire_events)
		if ok, err, msg = popover_check(p, el, true); !ok { return err, msg }
	}
	invoker := s.invokers[el] or_else base.NIL_HANDLE
	if fire_events {
		dispatch_event(p, el, dom.Event{type = "beforetoggle", data = "closed", text = "open", object = u64(invoker)})
		if ok, err, msg = popover_check(p, el, true); !ok { return err, msg }
	}
	back := s.focus_back[el] or_else base.NIL_HANDLE
	for h, i in s.showing { if h == el { popover_forget(p, s, i); break } }
	if fire_events { popover_queue_toggle(p, el, true, false, invoker) }
	// the focus goes back where it was when it is inside the popover
	if focus_back && back != base.NIL_HANDLE && dom.is_connected(p.doc, back) {
		if f := p.formctl; f != nil && f.model.focus != base.NIL_HANDLE && (f.model.focus == el || dom.shadow_including_ancestor(p.doc, el, f.model.focus)) {
			forms.focus(f.model, back)
		}
	}
	return .None, ""
}

// togglePopover(force): `force` -1 none, 0 hide only, 1 show only. Returns whether it is showing after.
popover_toggle :: proc(p: ^Page, el: base.Handle, force: i32, invoker: base.Handle) -> (bool, Api_Error, string) {
	if popover_showing(p, el) && force != 1 {
		if err, msg := popover_hide(p, el); err != .None { return false, err, msg }
	} else if !popover_showing(p, el) && force != 0 {
		if err, msg := popover_show(p, el, invoker); err != .None { return false, err, msg }
	} else {
		// already in the asked state: the validity checks still throw
		if _, err, msg := popover_check(p, el, popover_showing(p, el)); err != .None { return false, err, msg }
	}
	return popover_showing(p, el), .None, ""
}

// The popover a button's `popovertarget` names (an element with that id in the button's tree), NIL when none.
popover_target_of :: proc(p: ^Page, invoker: base.Handle) -> base.Handle {
	n := dom.get(p.doc, invoker)
	if n == nil || n.kind != .Element { return base.NIL_HANDLE }
	id, ok := node_attr(n, "popovertarget")
	if !ok || id == "" { return base.NIL_HANDLE }
	t := dom.find_by_id(p.doc, id)
	if popover_kind(dom.get(p.doc, t)) == .None { return base.NIL_HANDLE }
	return t
}

// The activation behaviour of a popover target button (popovertargetaction: toggle, show or hide).
popover_invoke :: proc(p: ^Page, invoker: base.Handle) {
	target := popover_target_of(p, invoker)
	if target == base.NIL_HANDLE { return }
	n := dom.get(p.doc, invoker)
	action, _ := node_attr(n, "popovertargetaction")
	showing := popover_showing(p, target)
	switch {
	case strings.equal_fold(action, "show"): if !showing { popover_show(p, target, invoker) }
	case strings.equal_fold(action, "hide"): if showing { popover_hide(p, target) }
	case: if showing { popover_hide(p, target) } else { popover_show(p, target, invoker) }
	}
}

// Light dismiss: a trusted click on `target` hides the auto popovers that neither contain it nor are invoked by a
// button that does.
popover_light_dismiss :: proc(p: ^Page, target: base.Handle) {
	s := popover_state(p)
	if s == nil || len(s.showing) == 0 { return }
	stack := popover_stack(p, s)
	if len(stack) == 0 { return }
	best := -1
	for cur := target; cur != base.NIL_HANDLE; cur = dom.parent_or_host(p.doc, cur) {
		for h, i in stack {
			if (h == cur || popover_target_of(p, cur) == h) && i > best { best = i }
		}
	}
	popover_hide_until(p, best >= 0 ? stack[best] : base.NIL_HANDLE, false, true)
}

// Escape: the topmost auto popover is hidden. True when one was.
popover_close_request :: proc(p: ^Page) -> bool {
	s := popover_state(p)
	if s == nil || len(s.showing) == 0 { return false }
	stack := popover_stack(p, s)
	if len(stack) == 0 { return false }
	popover_hide(p, stack[len(stack) - 1])
	return true
}

////////////////////////////////
// The API

Popover_show :: proc(c: ^Call, element: Api_Element, source: Api_Element) -> Api_Error {
	err, msg := popover_show(c.page, H(element.handle), H(source.handle))
	return err != .None ? fail(c, err, msg) : .None
}

Popover_hide :: proc(c: ^Call, element: Api_Element) -> Api_Error {
	err, msg := popover_hide(c.page, H(element.handle))
	return err != .None ? fail(c, err, msg) : .None
}

Popover_toggle :: proc(c: ^Call, element: Api_Element, force: i32, source: Api_Element) -> (bool, Api_Error) {
	r, err, msg := popover_toggle(c.page, H(element.handle), force, H(source.handle))
	return r, err != .None ? fail(c, err, msg) : .None
}

Popover_state :: proc(c: ^Call, element: Api_Element) -> i32 { return i32(popover_kind(element.data)) }

Popover_targetOf :: proc(c: ^Call, invoker: Api_Element) -> u64 { return u64(popover_target_of(c.page, H(invoker.handle))) }
