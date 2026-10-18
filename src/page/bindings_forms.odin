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
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:style"
import "wb:wasm"

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
	})
	p.style_state.controls = style.Control_Provider{query = forms_style_query, user = p}
}

@(private)
forms_detach :: proc(p: ^Page) {
	pf := p.formctl
	if pf == nil { return }
	forms.submission_destroy(pf.pending)
	forms.forms_destroy(pf.model)
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
	k := forms.kind_of(n)
	if k == .None && n.name != "progress" { return false, false }
	switch q {
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
F :: proc(env: wasm.Exec_Env) -> ^forms.Forms { return page_forms(page_of(env)) }

@(private)
is_el :: proc(env: wasm.Exec_Env, h: u64) -> bool {
	n := dom.get(page_of(env).doc, H(h))
	return n != nil && n.kind == .Element
}

@(private)
E :: proc(e: forms.Error) -> i32 { return i32(e) }

@(private)
bool_attr :: proc(env: wasm.Exec_Env, h: u64, name: string, v: i32) -> i32 {
	p := page_of(env)
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	if v != 0 { dom.set_attribute(p.doc, H(h), name, "") } else { dom.remove_attribute(p.doc, H(h), name) }
	forms.changed(page_forms(p), H(h))
	return 0
}

n_value :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return out_string(forms.value(F(env), H(h)), buf, cap)
}
n_setValue :: proc "c" (env: wasm.Exec_Env, h: u64, s: [^]u8, n: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return E(forms.set_value(F(env), H(h), str(s, n)))
}
n_defaultValue :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return out_string(forms.default_value(F(env), H(h)), buf, cap)
}
n_setDefaultValue :: proc "c" (env: wasm.Exec_Env, h: u64, s: [^]u8, n: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return E(forms.set_default_value(F(env), H(h), str(s, n)))
}
n_checked :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return forms.checked(F(env), H(h)) ? 1 : 0 }
n_setChecked :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 { context = ctx(); return E(forms.set_checked(F(env), H(h), v != 0)) }
n_defaultChecked :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return forms.default_checked(F(env), H(h)) ? 1 : 0 }
n_setDefaultChecked :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	forms.set_default_checked(F(env), H(h), v != 0)
	return 0
}
n_indeterminate :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return forms.indeterminate(F(env), H(h)) ? 1 : 0 }
n_setIndeterminate :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	forms.set_indeterminate(F(env), H(h), v != 0)
	return 0
}
n_type :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return out_string(forms.type_name(F(env), H(h)), buf, cap)
}
n_name :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	v, _ := dom.get_attribute(page_of(env).doc, H(h), "name")
	return out_string(v, buf, cap)
}
n_form :: proc "c" (env: wasm.Exec_Env, h: u64) -> u64 { context = ctx(); return u64(forms.form_owner(F(env), H(h))) }
n_disabled :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	v, ok := dom.get_attribute(page_of(env).doc, H(h), "disabled")
	_ = v
	return ok ? 1 : 0
}
n_setDisabled :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 { context = ctx(); return bool_attr(env, h, "disabled", v) }
n_readOnly :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); _, ok := dom.get_attribute(page_of(env).doc, H(h), "readonly"); return ok ? 1 : 0 }
n_setReadOnly :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 { context = ctx(); return bool_attr(env, h, "readonly", v) }
n_required :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); _, ok := dom.get_attribute(page_of(env).doc, H(h), "required"); return ok ? 1 : 0 }
n_setRequired :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 { context = ctx(); return bool_attr(env, h, "required", v) }
n_willValidate :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return forms.will_validate(F(env), H(h)) ? 1 : 0 }
n_validity :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return i32(transmute(u32)forms.validity(F(env), H(h)))
}
n_validationMessage :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return out_string(forms.validation_message(F(env), H(h)), buf, cap)
}
n_setCustomValidity :: proc "c" (env: wasm.Exec_Env, h: u64, s: [^]u8, n: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	forms.set_custom_validity(F(env), H(h), str(s, n))
	return 0
}
n_checkValidity :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return forms.check_validity(F(env), H(h)) ? 1 : 0
}
n_reportValidity :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	ok := forms.report_validity(F(env), H(h))
	forms_repaint(page_of(env))
	return ok ? 1 : 0
}
n_select :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return E(forms.select_text(F(env), H(h))) }
n_selectionStart :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	s, _, _, ok := forms.selection_utf16(F(env), H(h))
	return ok ? i32(s) : -1
}
n_selectionEnd :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	_, e, _, ok := forms.selection_utf16(F(env), H(h))
	return ok ? i32(e) : -1
}
n_selectionDirection :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	_, _, d, ok := forms.selection_utf16(F(env), H(h))
	if !ok { return i32(forms.Error.Invalid_State) }
	switch d {
	case .Forward: return out_string("forward", buf, cap)
	case .Backward: return out_string("backward", buf, cap)
	case .None:
	}
	return out_string("none", buf, cap)
}
// direction: 0 none, 1 forward, 2 backward
n_setSelectionRange :: proc "c" (env: wasm.Exec_Env, h: u64, start, end, dir: i32) -> i32 {
	context = ctx()
	d := forms.Direction.None
	if dir == 1 { d = .Forward } else if dir == 2 { d = .Backward }
	return E(forms.set_selection_range(F(env), H(h), int(start), int(end), d))
}
// start/end < 0: the selection. mode: 0 preserve, 1 select, 2 start, 3 end.
n_setRangeText :: proc "c" (env: wasm.Exec_Env, h: u64, s: [^]u8, n: i32, start, end, mode: i32) -> i32 {
	context = ctx()
	m := forms.Select_Mode.Preserve
	switch mode { case 1: m = .Select; case 2: m = .Start; case 3: m = .End }
	return E(forms.set_range_text(F(env), H(h), str(s, n), int(start), int(end), m))
}
n_stepUp :: proc "c" (env: wasm.Exec_Env, h: u64, count: i32) -> i32 { context = ctx(); return E(forms.step(F(env), H(h), int(count))) }
n_stepDown :: proc "c" (env: wasm.Exec_Env, h: u64, count: i32) -> i32 { context = ctx(); return E(forms.step(F(env), H(h), -int(count))) }
n_valueAsNumber :: proc "c" (env: wasm.Exec_Env, h: u64) -> f64 { context = ctx(); return forms.value_as_number(F(env), H(h)) }
n_setValueAsNumber :: proc "c" (env: wasm.Exec_Env, h: u64, v: f64) -> i32 { context = ctx(); return E(forms.set_value_as_number(F(env), H(h), v)) }
n_valueAsDate :: proc "c" (env: wasm.Exec_Env, h: u64) -> f64 {
	context = ctx()
	if ms, ok := forms.value_as_date(F(env), H(h)); ok { return ms }
	return math.nan_f64()
}
n_setValueAsDate :: proc "c" (env: wasm.Exec_Env, h: u64, ms: f64) -> i32 {
	context = ctx()
	return E(forms.set_value_as_date(F(env), H(h), ms, math.is_nan(ms)))
}
n_files_length :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(len(forms.files(F(env), H(h)))) }
n_fileName :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	fl := forms.files(F(env), H(h))
	if i < 0 || int(i) >= len(fl) { return i32(dom.Error.Not_Found) }
	return out_string(fl[i].name, buf, cap)
}
n_fileSize :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> i64 {
	context = ctx()
	fl := forms.files(F(env), H(h))
	if i < 0 || int(i) >= len(fl) { return -1 }
	return fl[i].size
}
n_fileType :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	fl := forms.files(F(env), H(h))
	if i < 0 || int(i) >= len(fl) { return i32(dom.Error.Not_Found) }
	return out_string(fl[i].mime, buf, cap)
}
n_maxLength :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(forms.max_length(F(env), H(h))) }
n_minLength :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(forms.min_length(F(env), H(h))) }

// select
n_selectedIndex :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(forms.selected_index(F(env), H(h))) }
n_setSelectedIndex :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> i32 {
	context = ctx()
	if forms.kind(F(env), H(h)) != .Select { return i32(dom.Error.Invalid_Handle) }
	forms.set_selected_index(F(env), H(h), int(i))
	return 0
}
n_select_length :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(len(forms.select_options(F(env), H(h)))) }
n_select_item :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> u64 {
	context = ctx()
	opts := forms.select_options(F(env), H(h))
	if i < 0 || int(i) >= len(opts) { return 0 }
	return u64(opts[i])
}
n_selectedOptions_length :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	f := F(env)
	c: i32
	for o in forms.select_options_synced(f, H(h)) { if forms.option_selected(f, o) { c += 1 } }
	return c
}
n_selectedOptions_item :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> u64 {
	context = ctx()
	f := F(env)
	k: i32
	for o in forms.select_options_synced(f, H(h)) {
		if !forms.option_selected(f, o) { continue }
		if k == i { return u64(o) }
		k += 1
	}
	return 0
}

// option
n_option_selected :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return forms.option_selected(F(env), H(h)) ? 1 : 0 }
n_option_setSelected :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 {
	context = ctx()
	if forms.kind(F(env), H(h)) != .Option { return i32(dom.Error.Invalid_Handle) }
	forms.set_option_selected(F(env), H(h), v != 0)
	return 0
}
n_option_defaultSelected :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return forms.default_selected(F(env), H(h)) ? 1 : 0 }
n_option_setDefaultSelected :: proc "c" (env: wasm.Exec_Env, h: u64, v: i32) -> i32 {
	context = ctx()
	if forms.kind(F(env), H(h)) != .Option { return i32(dom.Error.Invalid_Handle) }
	forms.set_default_selected(F(env), H(h), v != 0)
	return 0
}
n_option_index :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(forms.option_index(F(env), H(h))) }
n_option_text :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return out_string(forms.option_text(F(env), H(h)), buf, cap)
}
n_option_label :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return out_string(forms.option_label(F(env), H(h)), buf, cap)
}

// form
n_form_submit :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if forms.kind(F(env), H(h)) != .Form { return i32(dom.Error.Invalid_Handle) }
	forms.submit(F(env), H(h), base.NIL_HANDLE, from_method = true)
	return 0
}
n_form_requestSubmit :: proc "c" (env: wasm.Exec_Env, h, submitter: u64) -> i32 {
	context = ctx()
	return E(forms.request_submit(F(env), H(h), H(submitter)))
}
n_form_reset :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if forms.kind(F(env), H(h)) != .Form { return i32(dom.Error.Invalid_Handle) }
	forms.reset(F(env), H(h))
	return 0
}
n_form_length :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 { context = ctx(); return i32(len(forms.form_elements(F(env), H(h)))) }
n_form_elements :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> u64 {
	context = ctx()
	els := forms.form_elements(F(env), H(h))
	if i < 0 || int(i) >= len(els) { return 0 }
	return u64(els[i])
}
// namedItem: the first owned element whose id or name is `name`.
n_form_namedItem :: proc "c" (env: wasm.Exec_Env, h: u64, s: [^]u8, n: i32) -> u64 {
	context = ctx()
	p := page_of(env)
	name := str(s, n)
	for e in forms.form_elements(F(env), H(h)) {
		if v, ok := dom.get_attribute(p.doc, e, "id"); ok && v == name { return u64(e) }
		if v, ok := dom.get_attribute(p.doc, e, "name"); ok && v == name { return u64(e) }
	}
	return 0
}
n_label_control :: proc "c" (env: wasm.Exec_Env, h: u64) -> u64 { context = ctx(); return u64(forms.labeled_control(F(env), H(h))) }

// focus
n_focus :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	ok := forms.focus(F(env), H(h))
	forms_repaint(page_of(env))
	return ok ? 1 : 0
}
n_blur :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	forms.blur_element(F(env), H(h))
	forms_repaint(page_of(env))
	return 0
}
n_click :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	if !is_el(env, h) { return i32(dom.Error.Invalid_Handle) }
	return forms.synthetic_click(F(env), H(h)) ? 1 : 0
}
n_activeElement :: proc "c" (env: wasm.Exec_Env) -> u64 {
	context = ctx()
	p := page_of(env)
	if f := page_forms(p).focus; f != base.NIL_HANDLE { return u64(f) }
	return u64(p.body)
}
n_dialog_returnValue :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	return out_string(forms.dialog_return_value(F(env), H(h)), buf, cap)
}

@(private)
forms_repaint :: proc(p: ^Page) {
	if pf := p.formctl; pf != nil && pf.embedder.changed != nil { pf.embedder.changed(pf.embedder.user, p) }
}

@(private)
Alias :: struct { names: []string, member: string, fn: rawptr, sig: cstring }

@(private)
INPUT :: []string{"HTMLInputElement"}
@(private)
VALUE_IFACES :: []string{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "HTMLButtonElement", "HTMLOptionElement", "HTMLOutputElement"}
@(private)
CONTROL_IFACES :: []string{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "HTMLButtonElement", "HTMLOutputElement", "HTMLFieldSetElement", "HTMLObjectElement"}
@(private)
TEXT_IFACES :: []string{"HTMLInputElement", "HTMLTextAreaElement"}
@(private)
VALIDATE_IFACES :: []string{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "HTMLButtonElement", "HTMLOutputElement", "HTMLFieldSetElement", "HTMLObjectElement", "HTMLFormElement"}

@(private)
FORMS_SHARED := [?]Alias{
		{VALUE_IFACES, "value", rawptr(n_value), "(I*~)i"},
		{VALUE_IFACES, "setValue", rawptr(n_setValue), "(I*~)i"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLOutputElement"}, "defaultValue", rawptr(n_defaultValue), "(I*~)i"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLOutputElement"}, "setDefaultValue", rawptr(n_setDefaultValue), "(I*~)i"},
		{INPUT, "checked", rawptr(n_checked), "(I)i"},
		{INPUT, "setChecked", rawptr(n_setChecked), "(Ii)i"},
		{INPUT, "defaultChecked", rawptr(n_defaultChecked), "(I)i"},
		{INPUT, "setDefaultChecked", rawptr(n_setDefaultChecked), "(Ii)i"},
		{INPUT, "indeterminate", rawptr(n_indeterminate), "(I)i"},
		{INPUT, "setIndeterminate", rawptr(n_setIndeterminate), "(Ii)i"},
		{CONTROL_IFACES, "type", rawptr(n_type), "(I*~)i"},
		{CONTROL_IFACES, "name", rawptr(n_name), "(I*~)i"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "HTMLButtonElement", "HTMLOutputElement", "HTMLFieldSetElement", "HTMLObjectElement", "HTMLOptionElement", "HTMLLabelElement", "HTMLLegendElement"}, "form", rawptr(n_form), "(I)I"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "HTMLButtonElement", "HTMLFieldSetElement", "HTMLOptionElement", "HTMLOptGroupElement"}, "disabled", rawptr(n_disabled), "(I)i"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "HTMLButtonElement", "HTMLFieldSetElement", "HTMLOptionElement", "HTMLOptGroupElement"}, "setDisabled", rawptr(n_setDisabled), "(Ii)i"},
		{TEXT_IFACES, "readOnly", rawptr(n_readOnly), "(I)i"},
		{TEXT_IFACES, "setReadOnly", rawptr(n_setReadOnly), "(Ii)i"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement"}, "required", rawptr(n_required), "(I)i"},
		{{"HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement"}, "setRequired", rawptr(n_setRequired), "(Ii)i"},
		{CONTROL_IFACES, "willValidate", rawptr(n_willValidate), "(I)i"},
		{CONTROL_IFACES, "validity", rawptr(n_validity), "(I)i"},
		{CONTROL_IFACES, "validationMessage", rawptr(n_validationMessage), "(I*~)i"},
		{CONTROL_IFACES, "setCustomValidity", rawptr(n_setCustomValidity), "(I*~)i"},
		{VALIDATE_IFACES, "checkValidity", rawptr(n_checkValidity), "(I)i"},
		{VALIDATE_IFACES, "reportValidity", rawptr(n_reportValidity), "(I)i"},
		{TEXT_IFACES, "select", rawptr(n_select), "(I)i"},
		{TEXT_IFACES, "selectionStart", rawptr(n_selectionStart), "(I)i"},
		{TEXT_IFACES, "selectionEnd", rawptr(n_selectionEnd), "(I)i"},
		{TEXT_IFACES, "selectionDirection", rawptr(n_selectionDirection), "(I*~)i"},
		{TEXT_IFACES, "setSelectionRange", rawptr(n_setSelectionRange), "(Iiii)i"},
		{TEXT_IFACES, "setRangeText", rawptr(n_setRangeText), "(I*~iii)i"},
		{TEXT_IFACES, "maxLength", rawptr(n_maxLength), "(I)i"},
		{TEXT_IFACES, "minLength", rawptr(n_minLength), "(I)i"},
		{INPUT, "stepUp", rawptr(n_stepUp), "(Ii)i"},
		{INPUT, "stepDown", rawptr(n_stepDown), "(Ii)i"},
		{INPUT, "valueAsNumber", rawptr(n_valueAsNumber), "(I)F"},
		{INPUT, "setValueAsNumber", rawptr(n_setValueAsNumber), "(IF)i"},
		{INPUT, "valueAsDate", rawptr(n_valueAsDate), "(I)F"},
		{INPUT, "setValueAsDate", rawptr(n_setValueAsDate), "(IF)i"},
		{INPUT, "files_length", rawptr(n_files_length), "(I)i"},
		{INPUT, "fileName", rawptr(n_fileName), "(Ii*~)i"},
		{INPUT, "fileSize", rawptr(n_fileSize), "(Ii)I"},
		{INPUT, "fileType", rawptr(n_fileType), "(Ii*~)i"},
}

// Names that are not shared: (full import name, function, signature).
@(private)
FORMS_SINGLE := [?]wasm.Native_Symbol{
	{"HTMLSelectElement_selectedIndex", rawptr(n_selectedIndex), "(I)i", nil},
	{"HTMLSelectElement_setSelectedIndex", rawptr(n_setSelectedIndex), "(Ii)i", nil},
	{"HTMLSelectElement_length", rawptr(n_select_length), "(I)i", nil},
	{"HTMLSelectElement_item", rawptr(n_select_item), "(Ii)I", nil},
	{"HTMLSelectElement_selectedOptions_length", rawptr(n_selectedOptions_length), "(I)i", nil},
	{"HTMLSelectElement_selectedOptions_item", rawptr(n_selectedOptions_item), "(Ii)I", nil},
	{"HTMLOptionElement_selected", rawptr(n_option_selected), "(I)i", nil},
	{"HTMLOptionElement_setSelected", rawptr(n_option_setSelected), "(Ii)i", nil},
	{"HTMLOptionElement_defaultSelected", rawptr(n_option_defaultSelected), "(I)i", nil},
	{"HTMLOptionElement_setDefaultSelected", rawptr(n_option_setDefaultSelected), "(Ii)i", nil},
	{"HTMLOptionElement_index", rawptr(n_option_index), "(I)i", nil},
	{"HTMLOptionElement_text", rawptr(n_option_text), "(I*~)i", nil},
	{"HTMLOptionElement_label", rawptr(n_option_label), "(I*~)i", nil},
	{"HTMLFormElement_submit", rawptr(n_form_submit), "(I)i", nil},
	{"HTMLFormElement_requestSubmit", rawptr(n_form_requestSubmit), "(II)i", nil},
	{"HTMLFormElement_reset", rawptr(n_form_reset), "(I)i", nil},
	{"HTMLFormElement_length", rawptr(n_form_length), "(I)i", nil},
	{"HTMLFormElement_elements", rawptr(n_form_elements), "(Ii)I", nil},
	{"HTMLFormElement_namedItem", rawptr(n_form_namedItem), "(I*~)I", nil},
	{"HTMLLabelElement_control", rawptr(n_label_control), "(I)I", nil},
	{"HTMLElement_focus", rawptr(n_focus), "(I)i", nil},
	{"HTMLElement_blur", rawptr(n_blur), "(I)i", nil},
	{"HTMLElement_click", rawptr(n_click), "(I)i", nil},
	{"Document_activeElement", rawptr(n_activeElement), "()I", nil},
	{"HTMLDialogElement_returnValue", rawptr(n_dialog_returnValue), "(I*~)i", nil},
	{"FormData_create", rawptr(n_FormData_create), "(II)I", nil},
	{"FormData_append", rawptr(n_FormData_append), "(I*~*~)i", nil},
	{"FormData_appendBlob", rawptr(n_FormData_appendBlob), "(I*~I*~*~)i", nil},
	{"FormData_set", rawptr(n_FormData_set), "(I*~*~)i", nil},
	{"FormData_delete", rawptr(n_FormData_delete), "(I*~)i", nil},
	{"FormData_has", rawptr(n_FormData_has), "(I*~)i", nil},
	{"FormData_count", rawptr(n_FormData_count), "(I*~)i", nil},
	{"FormData_get", rawptr(n_FormData_get), "(I*~*~)i", nil},
	{"FormData_getAt", rawptr(n_FormData_getAt), "(I*~i*~)i", nil},
	{"FormData_size", rawptr(n_FormData_size), "(I)i", nil},
	{"FormData_nameAt", rawptr(n_FormData_nameAt), "(Ii*~)i", nil},
	{"FormData_valueAt", rawptr(n_FormData_valueAt), "(Ii*~)i", nil},
	{"FormData_isFileAt", rawptr(n_FormData_isFileAt), "(Ii)i", nil},
	{"FormData_fileSizeAt", rawptr(n_FormData_fileSizeAt), "(Ii)I", nil},
	{"FormData_fileTypeAt", rawptr(n_FormData_fileTypeAt), "(Ii*~)i", nil},
	{"Fetch_startFormData", rawptr(n_Fetch_startFormData), "(*~*~*~Iiiii)I", nil},
}

// The import table of module "forms" (built once; WAMR keeps pointers into it for the life of the runtime).
@(private)
forms_symbols: [dynamic]wasm.Native_Symbol

@(private)
build_forms_symbols :: proc() -> []wasm.Native_Symbol {
	if len(forms_symbols) > 0 { return forms_symbols[:] }
	for a in FORMS_SHARED {
		for iface in a.names {
			name := strings.clone_to_cstring(strings.concatenate({iface, "_", a.member}, context.temp_allocator))
			append(&forms_symbols, wasm.Native_Symbol{name, a.fn, a.sig, nil})
		}
	}
	for s in FORMS_SINGLE { append(&forms_symbols, s) }
	return forms_symbols[:]
}
