package forms

import "wb:base"
import "wb:dom"

// Form-associated custom elements (HTML §4.13.7): an autonomous custom element whose definition says formAssociated is a
// listed, labelable, submittable and resettable element, disabled by its attribute or a fieldset as a button is. Its
// submission value and its validity are what its ElementInternals set; its callbacks are the page's
// (Host.face_callback): the form owner and the disabledness they last told are kept, `face_sync` tells the changes.

Face_Callback :: enum u8 { Associated, Disabled, Enabled, Reset }

// The element became custom with a form-associated definition (upgraded, or made by its constructor).
face_add :: proc(f: ^Forms, h: base.Handle) {
	c := control_of(f, h)
	if c == nil || c.kind == .Custom { return }
	c.kind = .Custom
	append(&f.faces, h)
	face_sync_one(f, c)
}

is_face :: proc(f: ^Forms, h: base.Handle) -> bool {
	c := control_peek(f, h)
	return c != nil && c.kind == .Custom
}

// Tells each form-associated custom element whose form owner or disabledness changed (the page calls it after a mutation).
face_sync :: proc(f: ^Forms) {
	for h in f.faces { if c := control_peek(f, h); c != nil { face_sync_one(f, c) } }
}

@(private)
face_sync_one :: proc(f: ^Forms, c: ^Control) {
	if dom.get(f.doc, c.node) == nil { return }
	if owner := form_owner(f, c.node); owner != c.face_owner {
		c.face_owner = owner
		face_tell(f, c.node, .Associated, owner)
	}
	if d := is_disabled(f, c.node); d != c.face_disabled {
		c.face_disabled = d
		face_tell(f, c.node, d ? .Disabled : .Enabled)
	}
}

@(private)
face_tell :: proc(f: ^Forms, h: base.Handle, cb: Face_Callback, form := base.NIL_HANDLE) {
	if f.host.face_callback != nil { f.host.face_callback(f.host.user, h, cb, form) }
}

// ElementInternals.setFormValue(value): `entries` (taken) is the submission value: one entry the element's name names
// (list = false: a string or a File), or a FormData's entries (list = true); none: null.
face_set_value :: proc(f: ^Forms, h: base.Handle, entries: [dynamic]Entry, list: bool) {
	e := entries
	c := control_peek(f, h)
	if c == nil || c.kind != .Custom { entries_destroy(&e); return }
	entries_destroy(&c.face_value)
	c.face_value = e
	c.face_list = list
}

// ElementInternals.setValidity(flags, message): the flags, and the message (its newlines LF) while any is set.
face_set_validity :: proc(f: ^Forms, h: base.Handle, flags: Validity, message: string) {
	c := control_peek(f, h)
	if c == nil || c.kind != .Custom { return }
	c.face_flags = flags
	replace_owned(&c.custom_error, flags == {} ? "" : normalize_newlines(message))
	changed(f, h)
}

// The entries of its submission value (the entry list's construction).
@(private)
face_entries :: proc(c: ^Control, name: string, list: ^[dynamic]Entry) {
	if c.face_list {
		for e in c.face_value { append(list, entry_clone(e)) }
		return
	}
	if len(c.face_value) == 0 || name == "" { return }
	e := entry_clone(c.face_value[0])
	replace_owned(&e.name, name)
	append(list, e)
}
