// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=forms order=15 exposed=Window
/// Form controls (HTML forms): values, checkedness, validity, selection, select / option / form members, focus, and
/// FormData. Members shared by several interfaces are one function imported under each interface's name
/// (HTMLInputElement_value, HTMLTextAreaElement_value...): it accepts any control and does what HTML says for its kind.
/// * selection positions are UTF-16 code units, as in JavaScript; -1 means null (the API does not apply);
/// * valueAsDate is milliseconds since the epoch, NaN for null;
/// * events: InputEvent.data is Event_data, inputType Event_text; SubmitEvent.submitter, FocusEvent.relatedTarget and
/// FormDataEvent.formData are Event_object.
package api_forms__forms

//@wb handle parent=Object host=Form_Data lookup=lookup_FormData
FormData :: distinct Handle

/// ValidityState: every flag that is set (none = valid).
//@wb flags base=u32
ValidityState :: enum u32 {
	Value_Missing,
	Type_Mismatch,
	Pattern_Mismatch,
	Too_Long,
	Too_Short,
	Range_Underflow,
	Range_Overflow,
	Step_Mismatch,
	Bad_Input,
	Custom_Error,
}

SelectionDirection :: enum i32 {
	None,
	Forward,
	Backward,
}

/// setRangeText's selectMode.
SelectionMode :: enum i32 {
	Preserve,
	Select,
	Start,
	End,
}

/// How a FormData body is encoded.
FormEnctype :: enum i32 {
	Multipart,
	Urlencoded,
	Text_Plain,
}

/// control.value
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOptionElement,HTMLOutputElement)
value :: proc(control: Element) -> string

/// control.value = value: Invalid_State for a file input given anything but "".
//@wb fn raises on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOptionElement,HTMLOutputElement)
setValue :: proc(control: Element, value: string)

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLOutputElement)
defaultValue :: proc(control: Element) -> string

//@wb fn raises on=(HTMLInputElement,HTMLTextAreaElement,HTMLOutputElement)
setDefaultValue :: proc(control: Element, value: string)

//@wb fn on=HTMLInputElement
checked :: proc(control: Element) -> bool

//@wb fn raises on=HTMLInputElement
setChecked :: proc(control: Element, checked: bool)

//@wb fn on=HTMLInputElement
defaultChecked :: proc(control: Element) -> bool

//@wb fn on=HTMLInputElement
setDefaultChecked :: proc(control: Element, checked: bool)

//@wb fn on=HTMLInputElement
indeterminate :: proc(control: Element) -> bool

//@wb fn on=HTMLInputElement
setIndeterminate :: proc(control: Element, indeterminate: bool)

/// control.type
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement)
type :: proc(control: Element) -> string

/// control.name
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement)
name :: proc(control: Element) -> string

/// The form owner (null when none).
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement,HTMLOptionElement,HTMLLabelElement,HTMLLegendElement)
form :: proc(control: Element) -> Element

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLFieldSetElement,HTMLOptionElement,HTMLOptGroupElement)
disabled :: proc(control: Element) -> bool

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLFieldSetElement,HTMLOptionElement,HTMLOptGroupElement)
setDisabled :: proc(control: Element, disabled: bool)

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement)
readOnly :: proc(control: Element) -> bool

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement)
setReadOnly :: proc(control: Element, read_only: bool)

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement)
required :: proc(control: Element) -> bool

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement)
setRequired :: proc(control: Element, required: bool)

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement)
willValidate :: proc(control: Element) -> bool

/// control.validity
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement)
validity :: proc(control: Element) -> ValidityState

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement)
validationMessage :: proc(control: Element) -> string

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement)
setCustomValidity :: proc(control: Element, message: string)

/// checkValidity(): fires "invalid" when it is not valid.
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement,HTMLFormElement)
checkValidity :: proc(control: Element) -> bool

/// reportValidity(): also shows the problem to the user.
//@wb fn on=(HTMLInputElement,HTMLTextAreaElement,HTMLSelectElement,HTMLButtonElement,HTMLOutputElement,HTMLFieldSetElement,HTMLObjectElement,HTMLFormElement)
reportValidity :: proc(control: Element) -> bool

//@wb fn raises on=(HTMLInputElement,HTMLTextAreaElement)
select :: proc(control: Element)

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement)
selectionStart :: proc(control: Element) -> i32

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement)
selectionEnd :: proc(control: Element) -> i32

/// "forward", "backward" or "none". Invalid_State when the control has no selection.
//@wb fn raises on=(HTMLInputElement,HTMLTextAreaElement)
selectionDirection :: proc(control: Element) -> string

//@wb fn raises on=(HTMLInputElement,HTMLTextAreaElement)
setSelectionRange :: proc(control: Element, start: i32, end: i32, direction: SelectionDirection = .None)

/// setRangeText(text, start, end, mode): start / end < 0 use the selection.
//@wb fn raises on=(HTMLInputElement,HTMLTextAreaElement)
setRangeText :: proc(control: Element, text: string, start: i32 = -1, end: i32 = -1, mode: SelectionMode = .Preserve)

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement)
maxLength :: proc(control: Element) -> i32

//@wb fn on=(HTMLInputElement,HTMLTextAreaElement)
minLength :: proc(control: Element) -> i32

//@wb fn raises on=HTMLInputElement
stepUp :: proc(control: Element, count: i32 = 1)

//@wb fn raises on=HTMLInputElement
stepDown :: proc(control: Element, count: i32 = 1)

//@wb fn on=HTMLInputElement
valueAsNumber :: proc(control: Element) -> f64

//@wb fn raises on=HTMLInputElement
setValueAsNumber :: proc(control: Element, value: f64)

/// NaN for null.
//@wb fn on=HTMLInputElement
valueAsDate :: proc(control: Element) -> f64

/// NaN sets null.
//@wb fn raises on=HTMLInputElement
setValueAsDate :: proc(control: Element, ms: f64)

/// input.files.length
//@wb fn on=HTMLInputElement
files_length :: proc(control: Element) -> i32

//@wb fn raises on=HTMLInputElement
fileName :: proc(control: Element, index: i32) -> string

/// -1 past the end.
//@wb fn on=HTMLInputElement
fileSize :: proc(control: Element, index: i32) -> i64

//@wb fn raises on=HTMLInputElement
fileType :: proc(control: Element, index: i32) -> string

//@wb fn
HTMLSelectElement_selectedIndex :: proc(select: Element) -> i32

/// Invalid_Handle when it is not a select.
//@wb fn raises
HTMLSelectElement_setSelectedIndex :: proc(select: Element, index: i32)

//@wb fn
HTMLSelectElement_length :: proc(select: Element) -> i32

/// select.item(index): null past the end.
//@wb fn
HTMLSelectElement_item :: proc(select: Element, index: i32) -> Element

//@wb fn
HTMLSelectElement_selectedOptions_length :: proc(select: Element) -> i32

//@wb fn
HTMLSelectElement_selectedOptions_item :: proc(select: Element, index: i32) -> Element

//@wb fn
HTMLOptionElement_selected :: proc(option: Element) -> bool

//@wb fn raises
HTMLOptionElement_setSelected :: proc(option: Element, selected: bool)

//@wb fn
HTMLOptionElement_defaultSelected :: proc(option: Element) -> bool

//@wb fn raises
HTMLOptionElement_setDefaultSelected :: proc(option: Element, selected: bool)

//@wb fn
HTMLOptionElement_index :: proc(option: Element) -> i32

//@wb fn
HTMLOptionElement_text :: proc(option: Element) -> string

//@wb fn
HTMLOptionElement_label :: proc(option: Element) -> string

/// form.submit(): no submit event, no validation.
//@wb fn raises
HTMLFormElement_submit :: proc(form: Element)

/// form.requestSubmit(submitter)
//@wb fn raises optional=submitter
HTMLFormElement_requestSubmit :: proc(form: Element, submitter: Element)

//@wb fn raises
HTMLFormElement_reset :: proc(form: Element)

//@wb fn
HTMLFormElement_length :: proc(form: Element) -> i32

/// form.elements[index]: null past the end.
//@wb fn
HTMLFormElement_elements :: proc(form: Element, index: i32) -> Element

/// form.elements.namedItem(name): the first owned element whose id or name is `name` (null when none).
//@wb fn
HTMLFormElement_namedItem :: proc(form: Element, name: string) -> Element

/// label.control (null when none).
//@wb fn
HTMLLabelElement_control :: proc(label: Element) -> Element

/// element.focus(): whether it got the focus.
//@wb fn
HTMLElement_focus :: proc(element: Element) -> bool

//@wb fn
HTMLElement_blur :: proc(element: Element)

/// element.click(): false when the click was cancelled.
//@wb fn
HTMLElement_click :: proc(element: Element) -> bool

/// document.activeElement (the body when nothing has the focus).
//@wb fn
Document_activeElement :: proc() -> Element

//@wb fn
HTMLDialogElement_returnValue :: proc(dialog: Element) -> string

/// new FormData(form, submitter): both optional. Invalid_Handle when form is not a form or submitter not one of its
/// submit buttons, Invalid_State while the form is constructing its entry list.
//@wb fn raises optional=form,submitter
FormData_create :: proc(form: Element, submitter: Element) -> FormData

/// Invalid_Argument past forms.max_entries.
//@wb fn raises
FormData_append :: proc(data: FormData, name: usvstring, value: usvstring)

/// append(name, blob, filename): the bytes of a buffer as a file entry ("blob" when no file name is given).
//@wb fn raises
FormData_appendBlob :: proc(data: FormData, name: usvstring, blob: Buffer, filename: usvstring = "", mime: string = "")

/// set(name, value): replaces the first entry of that name and removes the others.
//@wb fn raises
FormData_set :: proc(data: FormData, name: usvstring, value: usvstring)

//@wb fn
FormData_delete :: proc(data: FormData, name: string)

//@wb fn
FormData_has :: proc(data: FormData, name: string) -> bool

/// getAll(name).length
//@wb fn
FormData_count :: proc(data: FormData, name: string) -> i32

/// get(name): the value (a file entry gives its file name). Not_Found when absent.
//@wb fn raises
FormData_get :: proc(data: FormData, name: string) -> string

/// getAll(name)[index]
//@wb fn raises
FormData_getAt :: proc(data: FormData, name: string, index: i32) -> string

/// The number of entries.
//@wb fn
FormData_size :: proc(data: FormData) -> i32

//@wb fn raises
FormData_nameAt :: proc(data: FormData, index: i32) -> string

//@wb fn raises
FormData_valueAt :: proc(data: FormData, index: i32) -> string

//@wb fn raises
FormData_isFileAt :: proc(data: FormData, index: i32) -> bool

/// -1 for a non-file entry or past the end.
//@wb fn
FormData_fileSizeAt :: proc(data: FormData, index: i32) -> i64

//@wb fn raises
FormData_fileTypeAt :: proc(data: FormData, index: i32) -> string

