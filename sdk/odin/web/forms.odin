package web

// Form controls, forms, focus and FormData (import module "forms").
//
// Members shared by several interfaces (value, form, checkValidity...) are imported once under their HTMLInputElement
// name: the browser exports them under every interface name and they accept any control (input, textarea, select,
// button, option, output, fieldset, form where it applies). Selection positions are UTF-16 code units; -1 means null.

Validity_Flag :: enum u32 {
	Value_Missing, Type_Mismatch, Pattern_Mismatch, Too_Long, Too_Short,
	Range_Underflow, Range_Overflow, Step_Mismatch, Bad_Input, Custom_Error,
}
Validity :: bit_set[Validity_Flag; u32]   // empty = valid

Selection_Direction :: enum i32 { None, Forward, Backward }
Select_Mode :: enum i32 { Preserve, Select, Start, End }
Form_Enctype :: enum i32 { Multipart, Urlencoded, Text_Plain }

foreign import forms_mod "forms"

@(default_calling_convention = "contextless")
foreign forms_mod {
	@(link_name = "HTMLInputElement_value") raw_value :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "HTMLInputElement_setValue") raw_setValue :: proc(el: Handle, s: [^]u8, n: i32) -> Error ---
	@(link_name = "HTMLInputElement_defaultValue") raw_defaultValue :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "HTMLInputElement_setDefaultValue") raw_setDefaultValue :: proc(el: Handle, s: [^]u8, n: i32) -> Error ---
	HTMLInputElement_checked :: proc(el: Handle) -> i32 ---
	HTMLInputElement_setChecked :: proc(el: Handle, v: i32) -> Error ---
	HTMLInputElement_defaultChecked :: proc(el: Handle) -> i32 ---
	HTMLInputElement_setDefaultChecked :: proc(el: Handle, v: i32) -> Error ---
	HTMLInputElement_indeterminate :: proc(el: Handle) -> i32 ---
	HTMLInputElement_setIndeterminate :: proc(el: Handle, v: i32) -> Error ---
	@(link_name = "HTMLInputElement_type") raw_type :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "HTMLInputElement_name") raw_name :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---
	HTMLInputElement_form :: proc(el: Handle) -> Handle ---
	HTMLInputElement_disabled :: proc(el: Handle) -> i32 ---
	HTMLInputElement_setDisabled :: proc(el: Handle, v: i32) -> Error ---
	HTMLInputElement_readOnly :: proc(el: Handle) -> i32 ---
	HTMLInputElement_setReadOnly :: proc(el: Handle, v: i32) -> Error ---
	HTMLInputElement_required :: proc(el: Handle) -> i32 ---
	HTMLInputElement_setRequired :: proc(el: Handle, v: i32) -> Error ---
	HTMLInputElement_willValidate :: proc(el: Handle) -> i32 ---
	@(link_name = "HTMLInputElement_validity") raw_validity :: proc(el: Handle) -> i32 ---
	@(link_name = "HTMLInputElement_validationMessage") raw_validationMessage :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "HTMLInputElement_setCustomValidity") raw_setCustomValidity :: proc(el: Handle, s: [^]u8, n: i32) -> Error ---
	HTMLInputElement_checkValidity :: proc(el: Handle) -> i32 ---
	HTMLInputElement_reportValidity :: proc(el: Handle) -> i32 ---
	HTMLInputElement_select :: proc(el: Handle) -> Error ---
	HTMLInputElement_selectionStart :: proc(el: Handle) -> i32 ---
	HTMLInputElement_selectionEnd :: proc(el: Handle) -> i32 ---
	@(link_name = "HTMLInputElement_selectionDirection") raw_selectionDirection :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---
	HTMLInputElement_setSelectionRange :: proc(el: Handle, start, end: i32, dir: Selection_Direction) -> Error ---
	@(link_name = "HTMLInputElement_setRangeText") raw_setRangeText :: proc(el: Handle, s: [^]u8, n: i32, start, end: i32, mode: Select_Mode) -> Error ---
	HTMLInputElement_maxLength :: proc(el: Handle) -> i32 ---
	HTMLInputElement_minLength :: proc(el: Handle) -> i32 ---
	HTMLInputElement_stepUp :: proc(el: Handle, n: i32) -> Error ---
	HTMLInputElement_stepDown :: proc(el: Handle, n: i32) -> Error ---
	HTMLInputElement_valueAsNumber :: proc(el: Handle) -> f64 ---
	HTMLInputElement_setValueAsNumber :: proc(el: Handle, v: f64) -> Error ---
	HTMLInputElement_valueAsDate :: proc(el: Handle) -> f64 ---
	HTMLInputElement_setValueAsDate :: proc(el: Handle, ms: f64) -> Error ---
	HTMLInputElement_files_length :: proc(el: Handle) -> i32 ---
	@(link_name = "HTMLInputElement_fileName") raw_fileName :: proc(el: Handle, i: i32, buf: [^]u8, cap: i32) -> i32 ---
	HTMLInputElement_fileSize :: proc(el: Handle, i: i32) -> i64 ---

	HTMLSelectElement_selectedIndex :: proc(el: Handle) -> i32 ---
	HTMLSelectElement_setSelectedIndex :: proc(el: Handle, i: i32) -> Error ---
	HTMLSelectElement_length :: proc(el: Handle) -> i32 ---
	HTMLSelectElement_item :: proc(el: Handle, i: i32) -> Handle ---
	HTMLSelectElement_selectedOptions_length :: proc(el: Handle) -> i32 ---
	HTMLSelectElement_selectedOptions_item :: proc(el: Handle, i: i32) -> Handle ---
	HTMLOptionElement_selected :: proc(el: Handle) -> i32 ---
	HTMLOptionElement_setSelected :: proc(el: Handle, v: i32) -> Error ---
	HTMLOptionElement_defaultSelected :: proc(el: Handle) -> i32 ---
	HTMLOptionElement_setDefaultSelected :: proc(el: Handle, v: i32) -> Error ---
	HTMLOptionElement_index :: proc(el: Handle) -> i32 ---
	@(link_name = "HTMLOptionElement_text") raw_optionText :: proc(el: Handle, buf: [^]u8, cap: i32) -> i32 ---

	HTMLFormElement_submit :: proc(form: Handle) -> Error ---
	HTMLFormElement_requestSubmit :: proc(form, submitter: Handle) -> Error ---
	HTMLFormElement_reset :: proc(form: Handle) -> Error ---
	HTMLFormElement_length :: proc(form: Handle) -> i32 ---
	HTMLFormElement_elements :: proc(form: Handle, i: i32) -> Handle ---
	@(link_name = "HTMLFormElement_namedItem") raw_namedItem :: proc(form: Handle, s: [^]u8, n: i32) -> Handle ---
	HTMLLabelElement_control :: proc(label: Handle) -> Handle ---
	HTMLElement_focus :: proc(el: Handle) -> i32 ---
	HTMLElement_blur :: proc(el: Handle) -> Error ---
	HTMLElement_click :: proc(el: Handle) -> i32 ---
	Document_activeElement :: proc() -> Handle ---

	@(link_name = "FormData_create") raw_formDataCreate :: proc(form, submitter: Handle) -> Handle ---
	@(link_name = "FormData_append") raw_formDataAppend :: proc(fd: Handle, n: [^]u8, nl: i32, v: [^]u8, vl: i32) -> Error ---
	@(link_name = "FormData_appendBlob") raw_formDataAppendBlob :: proc(fd: Handle, n: [^]u8, nl: i32, buffer: Handle, fname: [^]u8, fl: i32, mime: [^]u8, ml: i32) -> Error ---
	@(link_name = "FormData_set") raw_formDataSet :: proc(fd: Handle, n: [^]u8, nl: i32, v: [^]u8, vl: i32) -> Error ---
	@(link_name = "FormData_delete") raw_formDataDelete :: proc(fd: Handle, n: [^]u8, nl: i32) -> Error ---
	@(link_name = "FormData_has") raw_formDataHas :: proc(fd: Handle, n: [^]u8, nl: i32) -> i32 ---
	@(link_name = "FormData_count") raw_formDataCount :: proc(fd: Handle, n: [^]u8, nl: i32) -> i32 ---
	@(link_name = "FormData_getAt") raw_formDataGetAt :: proc(fd: Handle, n: [^]u8, nl: i32, i: i32, buf: [^]u8, cap: i32) -> i32 ---
	FormData_size :: proc(fd: Handle) -> i32 ---
	@(link_name = "FormData_nameAt") raw_formDataNameAt :: proc(fd: Handle, i: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "FormData_valueAt") raw_formDataValueAt :: proc(fd: Handle, i: i32, buf: [^]u8, cap: i32) -> i32 ---
	FormData_isFileAt :: proc(fd: Handle, i: i32) -> i32 ---
	@(link_name = "Fetch_startFormData") raw_fetchFormData :: proc(url: [^]u8, ul: i32, method: [^]u8, ml: i32, headers: [^]u8, hl: i32, fd: Handle, enctype: Form_Enctype, options: i32, callback: Fetch_Callback, user: i32) -> Handle ---
}

@(private = "file")
cut :: #force_inline proc "contextless" (buf: []u8, n: i32) -> string { return string(buf[:min(int(max(n, 0)), len(buf))]) }

// The value of any control; `needed` > len(buf) means the buffer was too small.
value :: proc "contextless" (el: Handle, buf: []u8) -> (s: string, needed: int) {
	n := raw_value(el, raw_data(buf), i32(len(buf)))
	return cut(buf, n), int(max(n, 0))
}
set_value :: proc "contextless" (el: Handle, s: string) -> Error { return raw_setValue(el, raw_data(s), i32(len(s))) }
default_value :: proc "contextless" (el: Handle, buf: []u8) -> string { return cut(buf, raw_defaultValue(el, raw_data(buf), i32(len(buf)))) }
set_default_value :: proc "contextless" (el: Handle, s: string) -> Error { return raw_setDefaultValue(el, raw_data(s), i32(len(s))) }
checked :: proc "contextless" (el: Handle) -> bool { return HTMLInputElement_checked(el) == 1 }
set_checked :: proc "contextless" (el: Handle, v: bool) -> Error { return HTMLInputElement_setChecked(el, v ? 1 : 0) }
control_type :: proc "contextless" (el: Handle, buf: []u8) -> string { return cut(buf, raw_type(el, raw_data(buf), i32(len(buf)))) }
control_name :: proc "contextless" (el: Handle, buf: []u8) -> string { return cut(buf, raw_name(el, raw_data(buf), i32(len(buf)))) }
validity :: proc "contextless" (el: Handle) -> Validity { return transmute(Validity)u32(max(raw_validity(el), 0)) }
validation_message :: proc "contextless" (el: Handle, buf: []u8) -> string { return cut(buf, raw_validationMessage(el, raw_data(buf), i32(len(buf)))) }
set_custom_validity :: proc "contextless" (el: Handle, s: string) -> Error { return raw_setCustomValidity(el, raw_data(s), i32(len(s))) }
check_validity :: proc "contextless" (el: Handle) -> bool { return HTMLInputElement_checkValidity(el) == 1 }
report_validity :: proc "contextless" (el: Handle) -> bool { return HTMLInputElement_reportValidity(el) == 1 }
set_range_text :: proc "contextless" (el: Handle, s: string, start: i32 = -1, end: i32 = -1, mode := Select_Mode.Preserve) -> Error {
	return raw_setRangeText(el, raw_data(s), i32(len(s)), start, end, mode)
}
file_name :: proc "contextless" (el: Handle, i: i32, buf: []u8) -> string { return cut(buf, raw_fileName(el, i, raw_data(buf), i32(len(buf)))) }
option_text :: proc "contextless" (el: Handle, buf: []u8) -> string { return cut(buf, raw_optionText(el, raw_data(buf), i32(len(buf)))) }
named_item :: proc "contextless" (form: Handle, name: string) -> Handle { return raw_namedItem(form, raw_data(name), i32(len(name))) }

// FormData: 0 for an empty one; with a form, its entry list (the form fires `formdata`).
form_data :: proc "contextless" (form: Handle = NIL, submitter: Handle = NIL) -> Handle { return raw_formDataCreate(form, submitter) }
form_data_append :: proc "contextless" (fd: Handle, name, value: string) -> Error {
	return raw_formDataAppend(fd, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)))
}
form_data_append_blob :: proc "contextless" (fd: Handle, name: string, buffer: Handle, filename := "blob", mime := "") -> Error {
	return raw_formDataAppendBlob(fd, raw_data(name), i32(len(name)), buffer, raw_data(filename), i32(len(filename)), raw_data(mime), i32(len(mime)))
}
form_data_set :: proc "contextless" (fd: Handle, name, value: string) -> Error {
	return raw_formDataSet(fd, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)))
}
form_data_delete :: proc "contextless" (fd: Handle, name: string) -> Error { return raw_formDataDelete(fd, raw_data(name), i32(len(name))) }
form_data_has :: proc "contextless" (fd: Handle, name: string) -> bool { return raw_formDataHas(fd, raw_data(name), i32(len(name))) == 1 }
form_data_count :: proc "contextless" (fd: Handle, name: string) -> int { return int(raw_formDataCount(fd, raw_data(name), i32(len(name)))) }
// get(name) is get_at(name, 0); getAll(name)[i] is get_at(name, i).
form_data_get :: proc "contextless" (fd: Handle, name: string, buf: []u8, index: i32 = 0) -> (s: string, found: bool) {
	n := raw_formDataGetAt(fd, raw_data(name), i32(len(name)), index, raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return cut(buf, n), true
}
form_data_name_at :: proc "contextless" (fd: Handle, i: i32, buf: []u8) -> string { return cut(buf, raw_formDataNameAt(fd, i, raw_data(buf), i32(len(buf)))) }
form_data_value_at :: proc "contextless" (fd: Handle, i: i32, buf: []u8) -> string { return cut(buf, raw_formDataValueAt(fd, i, raw_data(buf), i32(len(buf)))) }

// fetch() with a FormData body (multipart/form-data unless another encoding is asked for).
fetch_form_data :: proc "contextless" (url: string, fd: Handle, cb: Fetch_Callback, user: i32 = 0, method := "POST", headers := "", enctype := Form_Enctype.Multipart, opt := Fetch_Options{}) -> Handle {
	o := u32(opt.mode) | u32(opt.credentials) << 2 | u32(opt.redirect) << 4 | (opt.referrer_policy & 0xF) << 6
	if opt.no_referrer { o |= 1 << 10 }
	return raw_fetchFormData(raw_data(url), i32(len(url)), raw_data(method), i32(len(method)), raw_data(headers), i32(len(headers)), fd, enctype, i32(o), cb, user)
}
