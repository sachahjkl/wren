package page

// Form controls for guests (import module "forms") and the glue between package forms and the page: events go to the
// guest listeners, submissions become planned navigations handed to the embedder outside any guest call, control state
// feeds the style engine's pseudo-classes.
//
// ABI notes, beyond those of bindings.odin:
//   * members shared by several interfaces (value, form, checkValidity...) are exported under every interface name
//     (HTMLInputElement_value, HTMLTextAreaElement_value...); they are the same import and accept any control
//   * selection positions are UTF-16 code units, as in JavaScript; -1 means null (the API does not apply)
//   * validity is a bitmask, bit i = forms.Validity_Flag i: valueMissing 0, typeMismatch 1, patternMismatch 2, tooLong 3,
//     tooShort 4, rangeUnderflow 5, rangeOverflow 6, stepMismatch 7, badInput 8, customError 9; valid = 0
//   * valueAsDate is milliseconds since the epoch, NaN for null
//   * events: InputEvent.data -> Event_data, InputEvent.inputType -> Event_text, SubmitEvent.submitter,
//     FocusEvent.relatedTarget and FormDataEvent.formData -> Event_object

import "core:math"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:style"

// What the embedder (the shell) provides. Every callback runs from a loop task, never inside guest code.
Forms_Embedder :: struct {
	user:       rawptr,
	navigate:   proc(user: rawptr, p: ^Page, s: ^forms.Submission),   // takes ownership of s
	pick_files: proc(user: rawptr, p: ^Page, input: base.Handle),
	pick_color: proc(user: rawptr, p: ^Page, input: base.Handle),
	changed:    proc(user: rawptr, p: ^Page),                          // something to repaint
}

Page_Forms :: struct {
	model:     ^forms.Forms,
	embedder:  Forms_Embedder,
	pending:   ^forms.Submission,   // the planned navigation (a newer submission replaces it)
	timer:     base.Handle,
	picker:    base.Handle,         // input waiting for its picker
	picker_color: bool,
	picker_timer: base.Handle,
	popover:   Popover_State,      // the showing popovers (popover.odin)
}

page_forms :: proc(p: ^Page) -> ^forms.Forms {
	m := p.formctl.model
	forms.collect(m)
	return m
}

set_forms_embedder :: proc(p: ^Page, e: Forms_Embedder) { p.formctl.embedder = e }

@(private)
forms_attach :: proc(p: ^Page) {
	pf := new(Page_Forms)
	p.formctl = pf
	pf.model = forms.forms_create(p.doc, &p.settings.forms, forms.Host{
		user = p,
		dispatch = proc(user: rawptr, target: base.Handle, ev: dom.Event) -> bool {
			p := (^Page)(user)
			if p.closed { return true }
			return dispatch_event(p, target, ev)
		},
		document_url = proc(user: rawptr) -> string { return (^Page)(user).env.location.href },
		navigate = forms_plan_navigation,
		style_changed = proc(user: rawptr) {
			p := (^Page)(user)
			if p.engine != nil { p.engine.restyle_needed = true }
		},
		formdata = formdata_event,
		now_ms = proc(user: rawptr) -> f64 { return f64(host.now_ns((^Page)(user).loop)) / 1e6 },
		focus_changed = proc(user: rawptr, focus: base.Handle, by_keyboard: bool) {
			p := (^Page)(user)
			st := p.style_state
			st.focus = focus
			set_style_state(p, st)
		},
		pick_files = proc(user: rawptr, input: base.Handle) { forms_plan_picker((^Page)(user), input, false) },
		pick_color = proc(user: rawptr, input: base.Handle) { forms_plan_picker((^Page)(user), input, true) },
		popover_invoke = proc(user: rawptr, invoker: base.Handle) { popover_invoke((^Page)(user), invoker) },
		popover_dismiss = proc(user: rawptr, target: base.Handle) { popover_light_dismiss((^Page)(user), target) },
		close_request = proc(user: rawptr) -> bool { return popover_close_request((^Page)(user)) },
		follow_link = proc(user: rawptr, link: base.Handle) { navigation_follow_script_link((^Page)(user), link) },
	})
	p.style_state.controls = style.Control_Provider{query = forms_style_query, user = p}
}

@(private)
forms_detach :: proc(p: ^Page) {
	pf := p.formctl
	if pf == nil { return }
	forms.submission_destroy(pf.pending)
	forms.forms_destroy(pf.model)
	popover_state_destroy(p, &pf.popover)
	free(pf)
	p.formctl = nil
}

// A submission becomes a planned navigation: performed by the embedder from a loop task (the submit may come from a
// guest listener that is still running).
@(private)
forms_plan_navigation :: proc(user: rawptr, s: ^forms.Submission) {
	p := (^Page)(user)
	pf := p.formctl
	forms.submission_destroy(pf.pending)
	pf.pending = s
	if pf.timer != base.NIL_HANDLE { host.clear_timer(p.loop, pf.timer) }
	pf.timer = host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		p := (^Page)(data)
		pf := p.formctl
		pf.timer = base.NIL_HANDLE
		s := pf.pending
		pf.pending = nil
		if s == nil { return }
		if pf.embedder.navigate != nil { pf.embedder.navigate(pf.embedder.user, p, s) } else {
			log(p, .Warn, "form submission ignored: no navigator")
			forms.submission_destroy(s)
		}
	}, p, p.scope)
}

@(private)
forms_plan_picker :: proc(p: ^Page, input: base.Handle, color: bool) {
	pf := p.formctl
	pf.picker, pf.picker_color = input, color
	if pf.picker_timer != base.NIL_HANDLE { return }
	pf.picker_timer = host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		p := (^Page)(data)
		pf := p.formctl
		pf.picker_timer = base.NIL_HANDLE
		input := pf.picker
		pf.picker = base.NIL_HANDLE
		if dom.get(p.doc, input) == nil { return }
		if pf.picker_color {
			if pf.embedder.pick_color != nil { pf.embedder.pick_color(pf.embedder.user, p, input) }
		} else if pf.embedder.pick_files != nil {
			pf.embedder.pick_files(pf.embedder.user, p, input)
		}
	}, p, p.scope)
}

// The style engine's view of control state.
@(private)
forms_style_query :: proc(user: rawptr, el: base.Handle, q: style.Control_Query) -> (answer: bool, known: bool) {
	p := (^Page)(user)
	if p.formctl == nil { return false, false }
	f := p.formctl.model
	n := dom.get(p.doc, el)
	if n == nil || n.kind != .Element { return false, false }
	if q == .Popover_Open { return popover_showing(p, el), true }   // (popover.odin)
	k := forms.kind_of(n)
	if k == .None && n.name != "progress" { return false, false }
	switch q {
	case .Popover_Open: return false, false
	case .Checked: return forms.matches_checked(f, el), true
	case .Indeterminate: return forms.matches_indeterminate(f, el), true
	case .Default: return forms.matches_default(f, el), true
	case .Disabled:
		#partial switch k { case .Input, .Button, .Select, .Textarea, .Option, .Optgroup, .Fieldset: return forms.is_disabled(f, el), true }
		return false, false
	case .Read_Write:
		#partial switch k { case .Input, .Textarea: return forms.is_read_write(f, el), true }
		return false, false
	case .Placeholder_Shown: return forms.placeholder_shown(f, el), true
	case .Valid, .Invalid:
		v, applies := forms.matches_valid(f, el)
		if !applies { return false, true }
		return q == .Valid ? v : !v, true
	case .User_Valid, .User_Invalid:
		v, applies := forms.matches_user_valid(f, el)
		if !applies { return false, true }
		return q == .User_Valid ? v : !v, true
	case .In_Range, .Out_Of_Range:
		v, applies := forms.matches_in_range(f, el)
		if !applies { return false, true }
		return q == .In_Range ? v : !v, true
	}
	return false, false
}

////////////////////////////////
// Imports: module "forms"

@(private)
F :: proc(c: ^Call) -> ^forms.Forms { return page_forms(c.page) }

// forms.Error -> the API's codes.
@(private)
E :: proc(c: ^Call, e: forms.Error) -> Api_Error {
	switch e {
	case .None:          return .None
	case .Invalid_Handle: return .Invalid_Handle
	case .Not_Supported: return fail(c, .Not_Supported, "NotSupportedError: this does not apply to this control")
	case .Invalid_State: return fail(c, .Invalid_State, "InvalidStateError")
	case .Index_Size:    return fail(c, .Index_Size, "IndexSizeError")
	case .Not_Allowed:   return fail(c, .Not_Allowed, "NotAllowedError")
	}
	return .Invalid_Argument
}

@(private)
bool_attr :: proc(c: ^Call, el: Api_Element, name: string, v: bool) {
	p := c.page
	if v { dom.set_attribute(p.doc, H(el.handle), name, "") } else { dom.remove_attribute(p.doc, H(el.handle), name) }
	forms.changed(page_forms(p), H(el.handle))
}

@(private)
has_attr :: proc(c: ^Call, el: Api_Element, name: string) -> bool {
	_, ok := dom.get_attribute(c.page.doc, H(el.handle), name)
	return ok
}

forms_value :: proc(c: ^Call, control: Api_Element) -> string { return forms.value(F(c), H(control.handle)) }
forms_setValue :: proc(c: ^Call, control: Api_Element, value: string) -> Api_Error { return E(c, forms.set_value(F(c), H(control.handle), value)) }
forms_defaultValue :: proc(c: ^Call, control: Api_Element) -> string { return forms.default_value(F(c), H(control.handle)) }
forms_setDefaultValue :: proc(c: ^Call, control: Api_Element, value: string) -> Api_Error { return E(c, forms.set_default_value(F(c), H(control.handle), value)) }
forms_checked :: proc(c: ^Call, control: Api_Element) -> bool { return forms.checked(F(c), H(control.handle)) }
forms_setChecked :: proc(c: ^Call, control: Api_Element, checked: bool) -> Api_Error { return E(c, forms.set_checked(F(c), H(control.handle), checked)) }
forms_defaultChecked :: proc(c: ^Call, control: Api_Element) -> bool { return forms.default_checked(F(c), H(control.handle)) }
forms_setDefaultChecked :: proc(c: ^Call, control: Api_Element, checked: bool) { forms.set_default_checked(F(c), H(control.handle), checked) }
forms_indeterminate :: proc(c: ^Call, control: Api_Element) -> bool { return forms.indeterminate(F(c), H(control.handle)) }
forms_setIndeterminate :: proc(c: ^Call, control: Api_Element, indeterminate: bool) { forms.set_indeterminate(F(c), H(control.handle), indeterminate) }
forms_type :: proc(c: ^Call, control: Api_Element) -> string { return forms.type_name(F(c), H(control.handle)) }

forms_name :: proc(c: ^Call, control: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(control.handle), "name")
	return v
}

forms_form :: proc(c: ^Call, control: Api_Element) -> u64 { return u64(forms.form_owner(F(c), H(control.handle))) }
forms_disabled :: proc(c: ^Call, control: Api_Element) -> bool { return has_attr(c, control, "disabled") }
forms_setDisabled :: proc(c: ^Call, control: Api_Element, disabled: bool) { bool_attr(c, control, "disabled", disabled) }
forms_readOnly :: proc(c: ^Call, control: Api_Element) -> bool { return has_attr(c, control, "readonly") }
forms_setReadOnly :: proc(c: ^Call, control: Api_Element, read_only: bool) { bool_attr(c, control, "readonly", read_only) }
forms_required :: proc(c: ^Call, control: Api_Element) -> bool { return has_attr(c, control, "required") }
forms_setRequired :: proc(c: ^Call, control: Api_Element, required: bool) { bool_attr(c, control, "required", required) }
forms_willValidate :: proc(c: ^Call, control: Api_Element) -> bool { return forms.will_validate(F(c), H(control.handle)) }
forms_validity :: proc(c: ^Call, control: Api_Element) -> Api_ValidityState { return transmute(Api_ValidityState)u32(transmute(u32)forms.validity(F(c), H(control.handle))) }
forms_validationMessage :: proc(c: ^Call, control: Api_Element) -> string { return forms.validation_message(F(c), H(control.handle)) }
forms_setCustomValidity :: proc(c: ^Call, control: Api_Element, message: string) { forms.set_custom_validity(F(c), H(control.handle), message) }
forms_checkValidity :: proc(c: ^Call, control: Api_Element) -> bool { return forms.check_validity(F(c), H(control.handle)) }

forms_reportValidity :: proc(c: ^Call, control: Api_Element) -> bool {
	ok := forms.report_validity(F(c), H(control.handle))
	forms_repaint(c.page)
	return ok
}

forms_select :: proc(c: ^Call, control: Api_Element) -> Api_Error { return E(c, forms.select_text(F(c), H(control.handle))) }

forms_selectionStart :: proc(c: ^Call, control: Api_Element) -> i32 {
	s, _, _, ok := forms.selection_utf16(F(c), H(control.handle))
	return ok ? i32(s) : -1
}

forms_selectionEnd :: proc(c: ^Call, control: Api_Element) -> i32 {
	_, e, _, ok := forms.selection_utf16(F(c), H(control.handle))
	return ok ? i32(e) : -1
}

forms_selectionDirection :: proc(c: ^Call, control: Api_Element) -> (string, Api_Error) {
	_, _, d, ok := forms.selection_utf16(F(c), H(control.handle))
	if !ok { return "", E(c, .Invalid_State) }
	switch d {
	case .Forward: return "forward", .None
	case .Backward: return "backward", .None
	case .None:
	}
	return "none", .None
}

forms_setSelectionRange :: proc(c: ^Call, control: Api_Element, start, end: i32, direction: Api_SelectionDirection) -> Api_Error {
	d := forms.Direction.None
	switch direction {
	case .None:
	case .Forward: d = .Forward
	case .Backward: d = .Backward
	}
	return E(c, forms.set_selection_range(F(c), H(control.handle), int(start), int(end), d))
}

// start / end < 0: the selection.
forms_setRangeText :: proc(c: ^Call, control: Api_Element, text: string, start, end: i32, mode: Api_SelectionMode) -> Api_Error {
	m := forms.Select_Mode.Preserve
	switch mode {
	case .Preserve:
	case .Select: m = .Select
	case .Start: m = .Start
	case .End: m = .End
	}
	return E(c, forms.set_range_text(F(c), H(control.handle), text, int(start), int(end), m))
}

forms_maxLength :: proc(c: ^Call, control: Api_Element) -> i32 { return i32(forms.max_length(F(c), H(control.handle))) }
forms_minLength :: proc(c: ^Call, control: Api_Element) -> i32 { return i32(forms.min_length(F(c), H(control.handle))) }
forms_stepUp :: proc(c: ^Call, control: Api_Element, count: i32) -> Api_Error { return E(c, forms.step(F(c), H(control.handle), int(count))) }
forms_stepDown :: proc(c: ^Call, control: Api_Element, count: i32) -> Api_Error { return E(c, forms.step(F(c), H(control.handle), -int(count))) }
forms_valueAsNumber :: proc(c: ^Call, control: Api_Element) -> f64 { return forms.value_as_number(F(c), H(control.handle)) }
forms_setValueAsNumber :: proc(c: ^Call, control: Api_Element, value: f64) -> Api_Error { return E(c, forms.set_value_as_number(F(c), H(control.handle), value)) }

forms_valueAsDate :: proc(c: ^Call, control: Api_Element) -> f64 {
	if ms, ok := forms.value_as_date(F(c), H(control.handle)); ok { return ms }
	return math.nan_f64()
}

forms_setValueAsDate :: proc(c: ^Call, control: Api_Element, ms: f64) -> Api_Error {
	return E(c, forms.set_value_as_date(F(c), H(control.handle), ms, math.is_nan(ms)))
}

forms_files_length :: proc(c: ^Call, control: Api_Element) -> i32 { return i32(len(forms.files(F(c), H(control.handle)))) }

forms_fileName :: proc(c: ^Call, control: Api_Element, index: i32) -> (string, Api_Error) {
	fl := forms.files(F(c), H(control.handle))
	if index < 0 || int(index) >= len(fl) { return "", .Not_Found }
	return fl[index].name, .None
}

forms_fileSize :: proc(c: ^Call, control: Api_Element, index: i32) -> i64 {
	fl := forms.files(F(c), H(control.handle))
	if index < 0 || int(index) >= len(fl) { return -1 }
	return fl[index].size
}

forms_fileType :: proc(c: ^Call, control: Api_Element, index: i32) -> (string, Api_Error) {
	fl := forms.files(F(c), H(control.handle))
	if index < 0 || int(index) >= len(fl) { return "", .Not_Found }
	return fl[index].mime, .None
}

// select
HTMLSelectElement_selectedIndex :: proc(c: ^Call, select: Api_Element) -> i32 { return i32(forms.selected_index(F(c), H(select.handle))) }

HTMLSelectElement_setSelectedIndex :: proc(c: ^Call, select: Api_Element, index: i32) -> Api_Error {
	if forms.kind(F(c), H(select.handle)) != .Select { return fail(c, .Invalid_Handle, "not a select") }
	forms.set_selected_index(F(c), H(select.handle), int(index))
	return .None
}

HTMLSelectElement_length :: proc(c: ^Call, select: Api_Element) -> i32 { return i32(len(forms.select_options(F(c), H(select.handle)))) }

HTMLSelectElement_item :: proc(c: ^Call, select: Api_Element, index: i32) -> u64 {
	opts := forms.select_options(F(c), H(select.handle))
	if index < 0 || int(index) >= len(opts) { return 0 }
	return u64(opts[index])
}

HTMLSelectElement_selectedOptions_length :: proc(c: ^Call, select: Api_Element) -> i32 {
	f := F(c)
	n: i32
	for o in forms.select_options_synced(f, H(select.handle)) { if forms.option_selected(f, o) { n += 1 } }
	return n
}

HTMLSelectElement_selectedOptions_item :: proc(c: ^Call, select: Api_Element, index: i32) -> u64 {
	f := F(c)
	k: i32
	for o in forms.select_options_synced(f, H(select.handle)) {
		if !forms.option_selected(f, o) { continue }
		if k == index { return u64(o) }
		k += 1
	}
	return 0
}

// option
HTMLOptionElement_selected :: proc(c: ^Call, option: Api_Element) -> bool { return forms.option_selected(F(c), H(option.handle)) }

HTMLOptionElement_setSelected :: proc(c: ^Call, option: Api_Element, selected: bool) -> Api_Error {
	if forms.kind(F(c), H(option.handle)) != .Option { return fail(c, .Invalid_Handle, "not an option") }
	forms.set_option_selected(F(c), H(option.handle), selected)
	return .None
}

HTMLOptionElement_defaultSelected :: proc(c: ^Call, option: Api_Element) -> bool { return forms.default_selected(F(c), H(option.handle)) }

HTMLOptionElement_setDefaultSelected :: proc(c: ^Call, option: Api_Element, selected: bool) -> Api_Error {
	if forms.kind(F(c), H(option.handle)) != .Option { return fail(c, .Invalid_Handle, "not an option") }
	forms.set_default_selected(F(c), H(option.handle), selected)
	return .None
}

HTMLOptionElement_index :: proc(c: ^Call, option: Api_Element) -> i32 { return i32(forms.option_index(F(c), H(option.handle))) }
HTMLOptionElement_text :: proc(c: ^Call, option: Api_Element) -> string { return forms.option_text(F(c), H(option.handle)) }
HTMLOptionElement_label :: proc(c: ^Call, option: Api_Element) -> string { return forms.option_label(F(c), H(option.handle)) }

// form
HTMLFormElement_submit :: proc(c: ^Call, form: Api_Element) -> Api_Error {
	if forms.kind(F(c), H(form.handle)) != .Form { return fail(c, .Invalid_Handle, "not a form") }
	forms.submit(F(c), H(form.handle), base.NIL_HANDLE, from_method = true)
	return .None
}

HTMLFormElement_requestSubmit :: proc(c: ^Call, form: Api_Element, submitter: Api_Element) -> Api_Error {
	return E(c, forms.request_submit(F(c), H(form.handle), H(submitter.handle)))
}

HTMLFormElement_reset :: proc(c: ^Call, form: Api_Element) -> Api_Error {
	if forms.kind(F(c), H(form.handle)) != .Form { return fail(c, .Invalid_Handle, "not a form") }
	forms.reset(F(c), H(form.handle))
	return .None
}

HTMLFormElement_length :: proc(c: ^Call, form: Api_Element) -> i32 { return i32(len(forms.form_elements(F(c), H(form.handle)))) }

HTMLFormElement_elements :: proc(c: ^Call, form: Api_Element, index: i32) -> u64 {
	els := forms.form_elements(F(c), H(form.handle))
	if index < 0 || int(index) >= len(els) { return 0 }
	return u64(els[index])
}

// namedItem: the first owned element whose id or name is `name`.
HTMLFormElement_namedItem :: proc(c: ^Call, form: Api_Element, name: string) -> u64 {
	p := c.page
	for e in forms.form_elements(F(c), H(form.handle)) {
		if v, ok := dom.get_attribute(p.doc, e, "id"); ok && v == name { return u64(e) }
		if v, ok := dom.get_attribute(p.doc, e, "name"); ok && v == name { return u64(e) }
	}
	return 0
}

HTMLLabelElement_control :: proc(c: ^Call, label: Api_Element) -> u64 { return u64(forms.labeled_control(F(c), H(label.handle))) }

// focus
HTMLElement_focus :: proc(c: ^Call, element: Api_Element) -> bool {
	ok := forms.focus(F(c), H(element.handle))
	forms_repaint(c.page)
	return ok
}

HTMLElement_blur :: proc(c: ^Call, element: Api_Element) {
	forms.blur_element(F(c), H(element.handle))
	forms_repaint(c.page)
}

HTMLElement_click :: proc(c: ^Call, element: Api_Element) -> bool { return forms.synthetic_click(F(c), H(element.handle)) }

Document_activeElement :: proc(c: ^Call) -> u64 {
	p := c.page
	// retargeted against the document: a focused element in a shadow tree shows as its host (HTML §6.6.2)
	if f := page_forms(p).focus; f != base.NIL_HANDLE { return u64(dom.retarget(p.doc, f, p.doc.root)) }
	return u64(p.body)
}

HTMLDialogElement_returnValue :: proc(c: ^Call, dialog: Api_Element) -> string { return forms.dialog_return_value(F(c), H(dialog.handle)) }

@(private)
forms_repaint :: proc(p: ^Page) {
	if pf := p.formctl; pf != nil && pf.embedder.changed != nil { pf.embedder.changed(pf.embedder.user, p) }
}