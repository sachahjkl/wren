package page

// A dialog shown by showModal() (HTML §4.11.4): in the top layer, above the page, whatever its ancestors do; what is outside it
// inert: no pointer reaches it (`:-wren-modal-active` in the UA sheet makes the root's tree `pointer-events: none`, `dialog:modal`
// takes them back) and Tab skips it. Escape asks it to close. The focus goes in, and comes back when it closes.
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

@(private)
dialog_modal_shown :: proc(p: ^Page, h: base.Handle) {
	s := popover_state(p)
	if s == nil { return }
	append(&s.modals, h)
	popover_restyle(p)
	forms_repaint(p)
	dialog_shown(p, h)
}

// (show() from showModal(): the focus moves after the dialog is modal)
@(thread_local)
dialog_opening_modal: bool

// show() or showModal(): the focus goes in, and is to come back.
@(private)
dialog_shown :: proc(p: ^Page, h: base.Handle) {
	s := popover_state(p)
	if s == nil { return }
	f := p.formctl
	if f.model.focus != base.NIL_HANDLE { s.focus_back[h] = f.model.focus }
	dialog_focus(p, h)
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

// Escape: a cancelable "cancel" at the modal dialog on top, closed unless a listener cancels it. True when there was one.
@(private)
dialog_close_request :: proc(p: ^Page) -> bool {
	top := dialog_top_modal(p)
	if top == base.NIL_HANDLE { return false }
	if !dispatch_event(p, top, dom.Event{type = "cancel", cancelable = true}) { return true }
	if dom.get(p.doc, top) != nil && dialog_is_modal(p, top) {
		forms.close_dialog(page_forms(p), top, "", false)
		forms_repaint(p)
	}
	return true
}