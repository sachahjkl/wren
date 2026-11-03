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
	open_dialogs_add(s, h)
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

// HTML's dialog removing steps: a dialog out of the document leaves the open dialogs, a modal one the top layer too, and is
// not modal when it comes back (it keeps its open attribute).
@(private)
dialog_note_removed :: proc(p: ^Page) {
	s := popover_state(p)
	if s == nil { return }
	open_dialogs_prune(p, s)
	if len(s.modals) == 0 { return }
	kept := 0
	for m in s.modals {
		if dom.is_connected(p.doc, m) { s.modals[kept] = m; kept += 1 }
	}
	if kept == len(s.modals) { return }
	resize(&s.modals, kept)
	popover_restyle(p)
}

@(private)
dialog_closed :: proc(p: ^Page, h: base.Handle) {
	s := popover_state(p)
	if s == nil { return }
	for d, i in s.open_dialogs {
		if d == h { ordered_remove(&s.open_dialogs, i); break }
	}
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

// Escape: a cancelable "cancel" at the open dialog on top, closed unless a listener cancels it. True when there was one
// a close request reaches (closedby none: its close watcher is disabled, and the dialogs below are of other groups).
@(private)
dialog_close_request :: proc(p: ^Page) -> bool {
	s := popover_state(p)
	if s == nil { return false }
	open_dialogs_prune(p, s)
	if len(s.open_dialogs) == 0 { return false }
	top := s.open_dialogs[len(s.open_dialogs) - 1]
	if dialog_closed_by(p, top) == .None { return false }
	if !dialog_cancel(p, top) { return true }
	if _, open := node_attr(dom.get(p.doc, top), "open"); open {
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

// HTML "light dismiss open dialogs", run by a trusted pointerdown or pointerup (dispatch_event): the press records the
// open dialog it is in; a release in that same dialog (or, after a press outside them all, outside them all) asks the
// open dialog on top to close, unless it is that dialog or its closedby is not any.
@(private)
dialog_light_dismiss :: proc(p: ^Page, down: bool, target: base.Handle, x, y: f64) {
	s := popover_state(p)
	if s == nil { return }
	open_dialogs_prune(p, s)
	if len(s.open_dialogs) == 0 { return }
	clicked := dialog_clicked(p, target, x, y)
	if down { s.dialog_pointerdown = clicked; return }
	same := clicked == s.dialog_pointerdown
	s.dialog_pointerdown = base.NIL_HANDLE
	top := s.open_dialogs[len(s.open_dialogs) - 1]
	if !same || clicked == top || dialog_closed_by(p, top) != .Any { return }
	if !dialog_cancel(p, top) || dom.get(p.doc, top) == nil { return }
	forms.close_dialog(page_forms(p), top, "", false)
	forms_repaint(p)
}

// HTML "nearest clicked dialog": the open dialog `target` is in (flat tree), none for a modal dialog itself clicked outside
// its border box (its ::backdrop).
@(private = "file")
dialog_clicked :: proc(p: ^Page, target: base.Handle, x, y: f64) -> base.Handle {
	if dialog_is_modal(p, target) {
		g, _, _ := element_geometry(p, target)
		r := g.client
		if g.ok && (x < r.x || y < r.y || x >= r.x + r.width || y >= r.y + r.height) { return base.NIL_HANDLE }
	}
	for cur := target; cur != base.NIL_HANDLE; cur = dom.flat_parent(p.doc, cur) {
		n := dom.get(p.doc, cur)
		if n == nil { break }
		if n.kind != .Element || n.name != "dialog" || n.ns != .HTML { continue }
		if _, open := node_attr(n, "open"); open { return cur }
	}
	return base.NIL_HANDLE
}

// The open dialogs list without what left it another way than close(): a dialog out of the document (HTML's removing
// steps), or whose open attribute a script removed.
@(private = "file")
open_dialogs_prune :: proc(p: ^Page, s: ^Popover_State) {
	kept := 0
	for d in s.open_dialogs {
		_, open := node_attr(dom.get(p.doc, d), "open")
		if open && dom.is_connected(p.doc, d) { s.open_dialogs[kept] = d; kept += 1 }
	}
	resize(&s.open_dialogs, kept)
}

@(private = "file")
open_dialogs_add :: proc(s: ^Popover_State, h: base.Handle) {
	for d in s.open_dialogs { if d == h { return } }
	append(&s.open_dialogs, h)
}

// HTML's dialog attribute change and insertion steps: a dialog in the document given its open attribute another way than
// show() or showModal() (dialog.open = true), or inserted with it, is an open dialog too.
@(private)
dialog_note_attribute :: proc(p: ^Page, el: base.Handle) {
	n := dom.get(p.doc, el)
	s := popover_state(p)
	if n == nil || s == nil || n.name != "dialog" || n.ns != .HTML || !dom.is_connected(p.doc, el) { return }
	if _, open := node_attr(n, "open"); open { open_dialogs_add(s, el) }
}