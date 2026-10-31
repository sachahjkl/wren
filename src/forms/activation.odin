package forms

import "core:strings"
import "wb:base"
import "wb:dom"

// Focus (§6.6), activation behaviour of controls (clicks on checkboxes, radios, buttons, labels...), keyboard default
// actions, implicit submission (§4.10.21.2) and reset (§4.10.22).

////////////////////////////////
// Focus

// Commits a text field: `change` when the value differs from the one it had when focused (or when last committed).
commit :: proc(f: ^Forms, h: base.Handle) {
	c := control_peek(f, h)
	if c == nil || element(f, h) == nil { return }
	if !is_text_field(f, h) && kind(f, h) != .Select { return }
	if !c.changed_since_focus { return }
	cur := value(f, h)
	if cur == c.value_at_focus && !(c.has_edit) { c.changed_since_focus = false; return }
	replace_owned(&c.value_at_focus, cur)
	c.changed_since_focus = false
	c.user_validity = true
	changed(f, h)
	fire(f, h, "change", bubbles = true)
}

// The focusing steps: blur / focusout on the old element, focus / focusin on the new one. Returns false when `h` cannot
// take the focus.
focus :: proc(f: ^Forms, h_in: base.Handle, by_keyboard := false) -> bool {
	h := h_in
	// a host that delegates focus: its focus delegate (unless the focus is in its shadow tree already)
	if delegates_focus(f, h) {
		if f.focus != base.NIL_HANDLE && dom.shadow_including_ancestor(f.doc, dom.shadow_root_of(f.doc, h), f.focus) { return true }
		h = focus_delegate(f, h)
		if h == base.NIL_HANDLE { return false }
	}
	if !is_focusable(f, h) { return false }
	if f.focus == h { f.focus_by_key = by_keyboard; return true }
	old := f.focus
	if old != base.NIL_HANDLE {
		commit(f, old)
		f.focus = base.NIL_HANDLE
		fire(f, old, "blur", object = u64(h), related = u64(h))
		fire(f, old, "focusout", bubbles = true, object = u64(h), related = u64(h))
		if f.focus != base.NIL_HANDLE { return f.focus == h }   // a listener moved the focus elsewhere
	}
	if !is_focusable(f, h) { notify_focus(f); return false }
	f.focus = h
	f.focus_by_key = by_keyboard
	if c := control_of(f, h); c != nil {
		replace_owned(&c.value_at_focus, value(f, h))
		c.changed_since_focus = false
		if by_keyboard && is_text_field(f, h) { select_all(f, h) }
	}
	notify_focus(f)
	fire(f, h, "focus", object = u64(old), related = u64(old))
	fire(f, h, "focusin", bubbles = true, object = u64(old), related = u64(old))
	return true
}

// Unfocuses whatever has the focus (click on nothing, blur()).
blur :: proc(f: ^Forms) {
	old := f.focus
	if old == base.NIL_HANDLE { return }
	commit(f, old)
	f.focus = base.NIL_HANDLE
	notify_focus(f)
	fire(f, old, "blur")
	fire(f, old, "focusout", bubbles = true)
}

// blur() on an element: only when it has the focus.
blur_element :: proc(f: ^Forms, h: base.Handle) { if f.focus == h { blur(f) } }

@(private)
notify_focus :: proc(f: ^Forms) {
	f.serial += 1
	if f.host.focus_changed != nil { f.host.focus_changed(f.host.user, f.focus, f.focus_by_key) }
}

// The first element with `autofocus` that can take the focus (called once the document is loaded).
run_autofocus :: proc(f: ^Forms) -> bool {
	if !f.settings.autofocus || f.focus != base.NIL_HANDLE { return false }
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	for h in all {
		if has_attr(element(f, h), "autofocus") && is_focusable(f, h) { return focus(f, h) }
	}
	return false
}

// Sequential navigation (Tab / Shift+Tab). Returns false at either end (the shell moves the focus to its own UI).
focus_next :: proc(f: ^Forms, dir: int, visible: proc(user: rawptr, h: base.Handle) -> bool = nil, user: rawptr = nil) -> bool {
	order := tab_order(f, visible, user)
	if len(order) == 0 { return false }
	idx := -1
	for h, i in order { if h == f.focus { idx = i; break } }
	next: int
	if idx < 0 { next = dir > 0 ? 0 : len(order) - 1 } else { next = idx + dir }
	if next < 0 || next >= len(order) { return false }
	// radio groups are one tab stop: skip unchecked members of a group that has a checked one
	for next >= 0 && next < len(order) {
		h := order[next]
		if f.host.inert != nil && f.host.inert(f.host.user, h) { next += dir; continue }
		if input_type(f, h) == .Radio && kind(f, h) == .Input && !checked(f, h) {
			group := radio_group(f, h)
			any_checked := false
			for g in group { if checked(f, g) { any_checked = true; break } }
			same_group_as_focus := false
			for g in group { if g == f.focus { same_group_as_focus = true } }
			if any_checked || same_group_as_focus { next += dir; continue }
		}
		return focus(f, h, by_keyboard = true)
	}
	return false
}

////////////////////////////////
// Activation

// Does the element have an activation behaviour of its own (§4.10, §4.4.4 labels)?
@(private)
has_activation :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	switch kind_of(n) {
	case .Input:
		#partial switch input_type_of(n) { case .Checkbox, .Radio, .Submit, .Image, .Reset, .Button, .File, .Color: return true }
	case .Button, .Label: return true
	case .None, .Textarea, .Select, .Option, .Optgroup, .Fieldset, .Legend, .Output, .Form, .Object, .Datalist, .Dialog:
	}
	if n != nil && (n.name == "a" || n.name == "area") && has_attr(n, "href") { return true }
	if n != nil && n.name == "summary" && details_of_summary(f, h) != base.NIL_HANDLE { return true }
	return false
}

// The <details> the <summary> `h` stands for (HTML §4.11.1: the first <summary> child of a <details>), else NIL.
@(private)
details_of_summary :: proc(f: ^Forms, h: base.Handle) -> base.Handle {
	p := parent_element(f, h)
	pn := element(f, p)
	if pn == nil || pn.name != "details" || pn.ns != .HTML { return base.NIL_HANDLE }
	for c := pn.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(f.doc, c)
		if cn == nil { break }
		if cn.kind == .Element && cn.name == "summary" { return c == h ? p : base.NIL_HANDLE }
		c = cn.next
	}
	return base.NIL_HANDLE
}

// The activation behaviour of a <summary>: its <details> opens or closes, and `toggle` is fired (it is queued, does not
// bubble, and is not cancelable).
@(private)
toggle_details :: proc(f: ^Forms, details: base.Handle) {
	n := element(f, details)
	if n == nil { return }
	was_open := has_attr(n, "open")
	if was_open { dom.remove_attribute(f.doc, details, "open") } else { dom.set_attribute(f.doc, details, "open", "") }
	changed_widely(f)
	// ToggleEvent: newState in `data`, oldState in `text`
	fire(f, details, "toggle", data = was_open ? "closed" : "open", text = was_open ? "open" : "closed")
}

// The activation target of a click on `target`: itself or the nearest ancestor with an activation behaviour.
activation_target :: proc(f: ^Forms, target: base.Handle) -> base.Handle {
	for cur := target; cur != base.NIL_HANDLE; cur = parent_element(f, cur) {
		if has_activation(f, cur) { return cur }
	}
	return base.NIL_HANDLE
}

@(private)
is_form_control_kind :: proc(k: Kind) -> bool {
	#partial switch k { case .Input, .Button, .Select, .Textarea, .Option, .Optgroup, .Fieldset: return true }
	return false
}

Click_Info :: struct {
	x, y:        f64,      // client coordinates (event fields)
	button:      i32,
	mods:        u32,
	offset:      [2]i32,   // position inside the activation target (image buttons)
	trusted:     bool,     // a real user click (file and color pickers need one)
}

// Dispatches a click with the activation behaviour around it (the dispatch algorithm's legacy-pre-activation, activation
// and legacy-canceled-activation steps). Returns false when a listener cancelled the click (or nothing was dispatched
// because the target is a disabled control).
click :: proc(f: ^Forms, target: base.Handle, info: Click_Info) -> bool {
	if element(f, target) == nil && dom.get(f.doc, target) == nil { return true }
	// a press outside the showing auto popovers closes them (HTML "light dismiss")
	if info.trusted && f.in_activation == 0 && f.host.popover_dismiss != nil { f.host.popover_dismiss(f.host.user, target) }
	// disabled form controls swallow user clicks
	for cur := target; cur != base.NIL_HANDLE; cur = parent_element(f, cur) {
		k := kind(f, cur)
		if is_form_control_kind(k) && k != .Fieldset && is_disabled(f, cur) { return false }
	}
	if f.in_activation > 8 { return true }
	f.in_activation += 1
	defer f.in_activation -= 1

	at := activation_target(f, target)
	n := element(f, at)
	t := input_type_of(n)
	is_input := kind_of(n) == .Input
	// legacy-pre-activation
	old_checked, old_indeterminate := false, false
	old_radio := base.NIL_HANDLE
	if is_input && t == .Checkbox {
		old_checked = checked(f, at)
		old_indeterminate = indeterminate(f, at)
		set_checked(f, at, !old_checked)
		if c := control_of(f, at); c != nil { c.indeterminate = false }
	} else if is_input && t == .Radio {
		old_checked = checked(f, at)
		for g in radio_group(f, at) { if checked(f, g) { old_radio = g } }
		set_checked(f, at, true)
	}
	if is_input && t == .Image {
		if c := control_of(f, at); c != nil { c.image_coords = info.offset }
	}
	ok := fire(f, target, "click", bubbles = true, cancelable = true, x = info.x, y = info.y, code = i64(info.button))
	if at == base.NIL_HANDLE || element(f, at) == nil { return ok }
	if !ok {
		// legacy-canceled-activation
		if is_input && t == .Checkbox {
			set_checked(f, at, old_checked)
			if c := control_of(f, at); c != nil { c.indeterminate = old_indeterminate }
		} else if is_input && t == .Radio {
			if old_radio != base.NIL_HANDLE { set_checked(f, old_radio, true) } else { set_checked(f, at, false) }
		}
		return false
	}
	activate(f, at, target, info, old_checked)
	return true
}

@(private)
activate :: proc(f: ^Forms, at, target: base.Handle, info: Click_Info, was_checked: bool) {
	n := element(f, at)
	switch kind_of(n) {
	case .Input:
		t := input_type_of(n)
		if (t == .Button || ((t == .Submit || t == .Image || t == .Reset) && form_owner(f, at) == base.NIL_HANDLE)) && popover_invoker(f, at) { return }
		#partial switch t {
		case .Checkbox:
			if !is_connected(f, at) { return }
			if c := control_of(f, at); c != nil { c.user_validity = true }
			fire(f, at, "input", bubbles = true)
			fire(f, at, "change", bubbles = true)
		case .Radio:
			if !is_connected(f, at) || was_checked { return }
			if c := control_of(f, at); c != nil { c.user_validity = true }
			fire(f, at, "input", bubbles = true)
			fire(f, at, "change", bubbles = true)
		case .Submit, .Image:
			if owner := form_owner(f, at); owner != base.NIL_HANDLE { submit(f, owner, at) }
		case .Reset:
			if owner := form_owner(f, at); owner != base.NIL_HANDLE { reset(f, owner) }
		case .File:
			if info.trusted && is_mutable(f, at) && f.host.pick_files != nil { f.host.pick_files(f.host.user, at) }
		case .Color:
			if info.trusted && is_mutable(f, at) && f.host.pick_color != nil { f.host.pick_color(f.host.user, at) }
		}
	case .Button:
		if is_disabled(f, at) { return }
		owner := form_owner(f, at)
		if (button_type_of(n) == .Button || owner == base.NIL_HANDLE) && popover_invoker(f, at) { return }
		switch button_type_of(n) {
		case .Submit: if owner != base.NIL_HANDLE { submit(f, owner, at) }
		case .Reset: if owner != base.NIL_HANDLE { reset(f, owner) }
		case .Button:
		}
	case .Label:
		ctl := labeled_control(f, at)
		if ctl == base.NIL_HANDLE || ctl == target { return }
		// a click on interactive content inside the label is that content's, not the label's
		for cur := target; cur != at && cur != base.NIL_HANDLE; cur = parent_element(f, cur) {
			if cur == ctl || is_labelable(f, cur) || has_activation(f, cur) { return }
		}
		if is_focusable(f, ctl) && kind(f, ctl) != .Button { focus(f, ctl) }
		sub := info
		sub.offset = {}
		click(f, ctl, sub)
	case .None, .Textarea, .Select, .Option, .Optgroup, .Fieldset, .Legend, .Output, .Form, .Object, .Datalist, .Dialog:
		// (a <summary> has no kind of its own)
		if n != nil && n.name == "summary" {
			if d := details_of_summary(f, at); d != base.NIL_HANDLE { toggle_details(f, d) }
		}
		if n != nil && (n.name == "a" || n.name == "area") && !info.trusted && f.host.follow_link != nil && is_connected(f, at) { f.host.follow_link(f.host.user, at) }
	}
}

// The popover target attributes' activation behaviour: a button with `popovertarget` shows, hides or toggles the popover
// it names (the page decides). Returns whether the button is such an invoker.
@(private)
popover_invoker :: proc(f: ^Forms, at: base.Handle) -> bool {
	n := element(f, at)
	if n == nil || !has_attr(n, "popovertarget") || f.host.popover_invoke == nil { return false }
	f.host.popover_invoke(f.host.user, at)
	return true
}

// element.click(): a synthetic, untrusted click with activation behaviour.
synthetic_click :: proc(f: ^Forms, h: base.Handle) -> bool { return click(f, h, Click_Info{}) }

// Implicit submission: Enter in a field submits its form through the default button, or directly when the form has a
// single field that blocks implicit submission.
implicit_submit :: proc(f: ^Forms, field: base.Handle) {
	form := form_owner(f, field)
	if form == base.NIL_HANDLE { return }
	if db := default_button(f, form); db != base.NIL_HANDLE {
		if !is_disabled(f, db) { click(f, db, Click_Info{trusted = true}) }
		return
	}
	blocking := 0
	for e in form_submittables(f, form) {
		n := element(f, e)
		if kind_of(n) == .Input && input_type_of(n) in BLOCKS_IMPLICIT { blocking += 1 }
	}
	if blocking > 1 { return }
	submit(f, form, base.NIL_HANDLE)
}

////////////////////////////////
// Keyboard

Key :: enum u8 { None, Left, Right, Up, Down, Home, End, Page_Up, Page_Down, Backspace, Delete, Enter, Space, Escape, Tab, A, Z, Y, F4 }
Mod :: enum u8 { Ctrl, Shift, Alt }
Mods :: bit_set[Mod; u8]

// The default action of a key press on the focused element (after `keydown` was not cancelled). Returns true when
// the key did something here (the shell then does not use it). Clipboard keys are the shell's (it owns the clipboard),
// as are Tab and opening a select's list.
key_down :: proc(f: ^Forms, key: Key, mods: Mods) -> bool {
	// Escape is a close request: the topmost auto popover goes first
	if key == .Escape && mods == {} && f.host.close_request != nil && f.host.close_request(f.host.user) { return true }
	h := f.focus
	n := element(f, h)
	if n == nil { return false }
	k := kind_of(n)
	ctrl, shift, alt := .Ctrl in mods, .Shift in mods, .Alt in mods
	if is_text_field(f, h) {
		t := input_type_of(n)
		multiline := k == .Textarea
		if alt { return false }
		// number-like fields step with the arrows
		if k == .Input && (t in MINMAX_APPLIES) && (key == .Up || key == .Down) && is_mutable(f, h) {
			step(f, h, key == .Up ? 1 : -1, by_user = true)
			return true
		}
		#partial switch key {
		case .Left: move_caret(f, h, ctrl ? .Word : .Char, -1, shift); return true
		case .Right: move_caret(f, h, ctrl ? .Word : .Char, 1, shift); return true
		case .Home: move_caret(f, h, ctrl ? .Doc_Edge : .Line_Edge, -1, shift); return true
		case .End: move_caret(f, h, ctrl ? .Doc_Edge : .Line_Edge, 1, shift); return true
		case .Up: if multiline { move_caret(f, h, .Line, -1, shift); return true }
		case .Down: if multiline { move_caret(f, h, .Line, 1, shift); return true }
		case .Page_Up: if multiline { move_caret(f, h, .Doc_Edge, -1, shift); return true }
		case .Page_Down: if multiline { move_caret(f, h, .Doc_Edge, 1, shift); return true }
		case .Backspace: edit(f, h, ctrl ? .Delete_Word_Backward : .Delete_Backward); return true
		case .Delete: edit(f, h, ctrl ? .Delete_Word_Forward : .Delete_Forward); return true
		case .A: if ctrl && !shift { select_all(f, h); return true }
		case .Z:
			if ctrl { edit(f, h, shift ? .History_Redo : .History_Undo); return true }
		case .Y: if ctrl { edit(f, h, .History_Redo); return true }
		case .Enter:
			if multiline { if !ctrl { edit(f, h, .Insert_Line_Break) }; return true }
			commit(f, h)
			implicit_submit(f, h)
			return true
		case .Escape:
			if f.report.node != base.NIL_HANDLE { dismiss_report(f); return true }
		}
		return false
	}
	#partial switch k {
	case .Input:
		t := input_type_of(n)
		#partial switch t {
		case .Checkbox, .Submit, .Reset, .Button, .Image, .File, .Color:
			if key == .Space { click(f, h, Click_Info{trusted = true}); return true }
			if key == .Enter {
				if t == .Checkbox { implicit_submit(f, h) } else { click(f, h, Click_Info{trusted = true}) }
				return true
			}
		case .Radio:
			if key == .Space { click(f, h, Click_Info{trusted = true}); return true }
			if key == .Enter { implicit_submit(f, h); return true }
			if key == .Left || key == .Right || key == .Up || key == .Down {
				dir := (key == .Left || key == .Up) ? -1 : 1
				group := radio_group(f, h)
				if len(group) < 2 { return true }
				idx := 0
				for g, i in group { if g == h { idx = i } }
				for _ in 0 ..< len(group) {
					idx = (idx + dir + len(group)) % len(group)
					g := group[idx]
					if !is_disabled(f, g) {
						focus(f, g, by_keyboard = true)
						click(f, g, Click_Info{trusted = true})
						break
					}
				}
				return true
			}
		case .Range:
			if !is_mutable(f, h) { return false }
			#partial switch key {
			case .Left, .Down: step(f, h, -1, by_user = true); return true
			case .Right, .Up: step(f, h, 1, by_user = true); return true
			case .Page_Down: step(f, h, -10, by_user = true); return true
			case .Page_Up: step(f, h, 10, by_user = true); return true
			case .Home, .End:
				lim := limits(f, n, t)
				target := key == .Home ? lim.min : lim.max
				s, _ := string_from_number(t, target)
				nv := sanitize(f, n, t, s)
				if nv != value(f, h) {
					set_value(f, h, nv, by_user = true)
					fire(f, h, "input", bubbles = true)
					fire(f, h, "change", bubbles = true)
				}
				return true
			}
		}
	case .Button:
		if key == .Space || key == .Enter { click(f, h, Click_Info{trusted = true}); return true }
	case .None:
		// the summary of a details: Enter and Space click it, as they click a button
		if n.name == "summary" && details_of_summary(f, h) != base.NIL_HANDLE && (key == .Space || key == .Enter) && !alt && !ctrl {
			click(f, h, Click_Info{trusted = true})
			return true
		}
	case .Select:
		if is_disabled(f, h) { return false }
		if key == .Up || key == .Down || key == .Home || key == .End || key == .Page_Up || key == .Page_Down {
			if alt { return false }   // Alt+Down opens the list (shell)
			opts := select_options_synced(f, h)
			if len(opts) == 0 { return true }
			cur := selected_index(f, h)
			idx := cur
			#partial switch key {
			case .Up: idx = cur - 1
			case .Down: idx = cur + 1
			case .Home: idx = 0
			case .End: idx = len(opts) - 1
			case .Page_Up: idx = cur - max(f.settings.select_rows - 1, 1)
			case .Page_Down: idx = cur + max(f.settings.select_rows - 1, 1)
			}
			step_dir := (key == .Up || key == .Page_Up || key == .End) ? -1 : 1
			if key == .Home { step_dir = 1 }
			idx = clamp(idx, 0, len(opts) - 1)
			for idx >= 0 && idx < len(opts) && is_disabled(f, opts[idx]) { idx += step_dir }
			if idx < 0 || idx >= len(opts) || idx == cur { return true }
			choose_option(f, h, opts[idx], extend = shift && has_attr(n, "multiple"))
			return true
		}
		if key == .Enter { implicit_submit(f, h); return true }
	}
	return false
}

// The user picked an option (list popup or arrow keys): selectedness, then input and change.
choose_option :: proc(f: ^Forms, sel, opt: base.Handle, extend := false, toggle := false) {
	if is_disabled(f, sel) || is_disabled(f, opt) { return }
	multiple := has_attr(element(f, sel), "multiple")
	before := make([dynamic]bool, context.temp_allocator)
	opts := select_options_synced(f, sel)
	for o in opts { append(&before, control_of(f, o).selected) }
	if multiple && toggle {
		set_option_selected(f, opt, !option_selected(f, opt))
	} else if multiple && extend {
		set_option_selected(f, opt, true)
	} else {
		for o in opts {
			c := control_of(f, o)
			c.selected = o == opt
			c.dirty_selected = true
		}
		select_run_selectedness(f, sel)
	}
	same := true
	for o, i in opts { if control_of(f, o).selected != before[i] { same = false; break } }
	changed_widely(f)
	if same { return }
	if c := control_of(f, sel); c != nil { c.user_validity = true }
	fire(f, sel, "input", bubbles = true)
	fire(f, sel, "change", bubbles = true)
	if c := control_peek(f, sel); c != nil { replace_owned(&c.value_at_focus, value(f, sel)); c.changed_since_focus = false }
}

// Typed text goes to the focused field.
type_text :: proc(f: ^Forms, text: string) -> bool {
	h := f.focus
	if !is_text_field(f, h) { return false }
	return edit(f, h, .Insert_Text, text)
}

////////////////////////////////
// Reset

reset_control :: proc(f: ^Forms, h: base.Handle) {
	n := element(f, h)
	c := control_of(f, h)
	if c == nil { return }
	switch kind_of(n) {
	case .Input:
		c.dirty_value = false
		c.dirty_checked = false
		c.user_edited = false
		c.has_edit = false
		c.user_validity = false
		replace_owned(&c.value, "")
		present := has_attr(n, "checked")
		c.checked = present
		c.checked_attr = present
		c.checked_init = true
		if present { c.checked_seq = next_seq(f) }
		for &fl in c.files { file_destroy(&fl) }
		clear(&c.files)
		undo_clear(&c.undo); undo_clear(&c.redo)
		v := value(f, h)
		c.sel_start, c.sel_end, c.sel_dir = len(v), len(v), .None
	case .Textarea:
		c.dirty_value = false
		c.user_edited = false
		c.user_validity = false
		replace_owned(&c.value, "")
		undo_clear(&c.undo); undo_clear(&c.redo)
		v := value(f, h)
		c.sel_start, c.sel_end, c.sel_dir = len(v), len(v), .None
	case .Select:
		c.user_validity = false
		for o in select_options(f, h) {
			oc := control_of(f, o)
			oc.selected = has_attr(element(f, o), "selected")
			oc.selected_attr = oc.selected
			oc.selected_init = true
			oc.dirty_selected = false
		}
		select_run_selectedness(f, h)
	case .Output:
	case .None, .Button, .Option, .Optgroup, .Fieldset, .Legend, .Form, .Label, .Object, .Datalist, .Dialog:
	}
	changed(f, h)
}

// form.reset(): `reset` (cancelable), then every resettable element owned by the form.
reset :: proc(f: ^Forms, form: base.Handle) {
	if kind(f, form) != .Form { return }
	if !fire(f, form, "reset", bubbles = true, cancelable = true) { return }
	for e in form_elements(f, form) { if is_resettable(kind(f, e)) { reset_control(f, e) } }
	changed_widely(f)
}

_ :: strings
