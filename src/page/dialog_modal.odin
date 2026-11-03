package page

// A dialog shown by showModal() (HTML §4.11.4): in the top layer, above the page, whatever its ancestors do; what is outside it
// inert: no pointer reaches it (`:-wren-modal-active` in the UA sheet makes the root's tree `pointer-events: none`, `dialog:modal`
// takes them back) and Tab skips it. Escape asks it to close, unless its closedby attribute says none. The focus goes in, and comes back
// when it closes. Opening and closing a dialog, modal or not, fire beforetoggle and queue toggle, as a popover's.
//
// The list is with the popovers, the other part of the top layer (popover.odin). ::backdrop is not generated.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"

@(private)
dialog_is_modal :: proc(p: ^Page, h: base.Handle) -> bool {
	s := popover_state(p)
	if s == nil { return false }
	for m in s.modals {
		if m == h {
			_, open := node_attr(dom.get(p.doc, h), "open")   // (a script may remove the attribute: not modal then)
			return open && dom.is_connected(p.doc, h)
		}
	}
	return false
}

// The modal dialog on top, NIL when there is none showing.
@(private)
dialog_top_modal :: proc(p: ^Page) -> base.Handle {
	s := popover_state(p)
	if s == nil { return base.NIL_HANDLE }
	#reverse for m in s.modals { if dialog_is_modal(p, m) { return m } }
	return base.NIL_HANDLE
}

@(private)
dialog_makes_inert :: proc(p: ^Page, h: base.Handle) -> bool {
	top := dialog_top_modal(p)
	return top != base.NIL_HANDLE && top != h && !dom.shadow_including_ancestor(p.doc, top, h)
}

// The closedby attribute's states; without a valid one (Auto), closerequest for a modal dialog, else none.
Closed_By :: enum u8 { Any, Close_Request, None }

@(private)
closed_by_name :: proc(state: Closed_By) -> string {
	switch state {
	case .Any: return "any"
	case .Close_Request: return "closerequest"
	case .None: return "none"
	}
	return ""
}

@(private)
dialog_closed_by :: proc(p: ^Page, h: base.Handle) -> Closed_By {
	if v, ok := node_attr(dom.get(p.doc, h), "closedby"); ok {
		for state in Closed_By { if strings.equal_fold(v, closed_by_name(state)) { return state } }
	}
	return dialog_is_modal(p, h) ? .Close_Request : .None
}

// show() and showModal() past their checks: a cancelable "beforetoggle" first; opened unless a listener canceled it or
// opened it (or, for a modal one, took it out or made it a showing popover); "toggle" queued; the focus goes in, and is
// to come back.
@(private)
dialog_open :: proc(p: ^Page, h: base.Handle, modal: bool) {
	if !dispatch_event(p, h, dom.Event{type = "beforetoggle", cancelable = true, data = "open", text = "closed"}) { return }
	if _, open := node_attr(dom.get(p.doc, h), "open"); open || dom.get(p.doc, h) == nil { return }
	if modal && (!dom.is_connected(p.doc, h) || popover_showing(p, h)) { return }
	s := popover_state(p)
	dialog_queue_toggle(p, h, false, true)
	dom.set_attribute(p.doc, h, "open", "")
	forms.changed(page_forms(p), h)
	if modal {
		append(&s.modals, h)
		popover_restyle(p)
		forms_repaint(p)
	}
	if p.formctl.model.focus != base.NIL_HANDLE { s.focus_back[h] = p.formctl.model.focus }
	dialog_focus(p, h)
}

// "Close the dialog", before its open attribute goes: a "beforetoggle" (not cancelable), and, unless a listener closed
// it, "toggle" queued.
@(private)
dialog_closing :: proc(p: ^Page, h: base.Handle) {
	dispatch_event(p, h, dom.Event{type = "beforetoggle", data = "closed", text = "open"})
	if _, open := node_attr(dom.get(p.doc, h), "open"); open { dialog_queue_toggle(p, h, true, false) }
}

// A cancelable "cancel" at the dialog: true when no listener canceled it. False without firing for a dialog whose
// "cancel" is being fired (its close watcher's "is running cancel action").
@(private)
dialog_cancel :: proc(p: ^Page, h: base.Handle) -> bool {
	s := popover_state(p)
	if s == nil { return dispatch_event(p, h, dom.Event{type = "cancel", cancelable = true}) }
	if s.cancelling == h { return false }
	outer := s.cancelling
	s.cancelling = h
	go_on := dispatch_event(p, h, dom.Event{type = "cancel", cancelable = true})
	if s = popover_state(p); s != nil { s.cancelling = outer }
	return go_on
}

// The dialog focusing steps: what has autofocus, else the first thing that can have the focus, else the dialog.
@(private = "file")
dialog_focus :: proc(p: ^Page, dialog: base.Handle) {
	f := p.formctl
	first_auto, first_any := base.NIL_HANDLE, base.NIL_HANDLE
	if _, auto := node_attr(dom.get(p.doc, dialog), "autofocus"); auto { first_auto = dialog }
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	append(&stack, dialog)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(p.doc, h)
		if n == nil || n.kind != .Element { continue }
		if h != dialog {
			if _, auto := node_attr(n, "autofocus"); auto && first_auto == base.NIL_HANDLE { first_auto = h }
			// (what Tab reaches: not a negative tabindex)
			if first_any == base.NIL_HANDLE {
				t, has := node_attr(n, "tabindex")
				if has ? !strings.has_prefix(strings.trim_space(t), "-") : focusable_by_default(p.doc, h, n) { first_any = h }
			}
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(p.doc, ch).prev { append(&stack, ch) }
	}
	if first_auto != base.NIL_HANDLE && forms.focus(f.model, first_auto) { return }
	if first_any != base.NIL_HANDLE && forms.focus(f.model, first_any) { return }
	if !forms.focus(f.model, dialog) { forms.blur(f.model) }
}

@(private)
dialog_closed :: proc(p: ^Page, h: base.Handle) {
	s := popover_state(p)
	if s == nil { return }
	for m, i in s.modals {
		if m != h { continue }
		ordered_remove(&s.modals, i)
		popover_restyle(p)
		break
	}
	back := s.focus_back[h] or_else base.NIL_HANDLE
	delete_key(&s.focus_back, h)
	if back != base.NIL_HANDLE && dom.is_connected(p.doc, back) { forms.focus(p.formctl.model, back) }
}

@(private = "file")
Dialog_Close_Task :: struct { dialog: base.Handle }

// HTML: "close" is fired from a task (user interaction task source).
@(private)
dialog_queue_close :: proc(p: ^Page, h: base.Handle) {
	t := new(Dialog_Close_Task)
	t.dialog = h
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Dialog_Close_Task)(data)
		defer free(t)
		if pg != nil && dom.get(pg.doc, t.dialog) != nil { dispatch_event(pg, t.dialog, dom.Event{type = "close"}) }
	}, t)
}

// Escape: a cancelable "cancel" at the modal dialog on top, closed unless a listener cancels it. True when there was one
// a close request reaches (closedby none: none does).
@(private)
dialog_close_request :: proc(p: ^Page) -> bool {
	top := dialog_top_modal(p)
	if top == base.NIL_HANDLE || dialog_closed_by(p, top) == .None { return false }
	if !dialog_cancel(p, top) { return true }
	if dom.get(p.doc, top) != nil && dialog_is_modal(p, top) {
		forms.close_dialog(page_forms(p), top, "", false)
		forms_repaint(p)
	}
	return true
}

// A dialog's "toggle" to fire from a task, its old state the one of a toggle still queued for it (which it replaces).
Dialog_Toggle :: struct { dialog: base.Handle, old_open, new_open: bool, seq: u32 }

@(private = "file")
Dialog_Toggle_Task :: struct { dialog: base.Handle, seq: u32 }

@(private)
dialog_queue_toggle :: proc(p: ^Page, h: base.Handle, old_open, new_open: bool) {
	s := popover_state(p)
	if s == nil { return }
	s.dialog_toggle_seq += 1
	entry := Dialog_Toggle{dialog = h, old_open = old_open, new_open = new_open, seq = s.dialog_toggle_seq}
	found := false
	for &q in s.dialog_toggles {
		if q.dialog == h { entry.old_open = q.old_open; q = entry; found = true }
	}
	if !found { append(&s.dialog_toggles, entry) }
	t := new(Dialog_Toggle_Task)
	t^ = {dialog = h, seq = entry.seq}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Dialog_Toggle_Task)(data)
		defer free(t)
		s := pg != nil ? popover_state(pg) : nil
		if s == nil { return }
		for q, i in s.dialog_toggles {
			if q.dialog != t.dialog || q.seq != t.seq { continue }   // (a later toggle replaced it)
			unordered_remove(&s.dialog_toggles, i)
			if dom.get(pg.doc, q.dialog) != nil {
				dispatch_event(pg, q.dialog, dom.Event{type = "toggle", data = q.new_open ? "open" : "closed", text = q.old_open ? "open" : "closed"})
			}
			return
		}
	}, t)
}