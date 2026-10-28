// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=33 partial
/// The setters of form controls' IDL attributes that are content attributes underneath (src/page/js_dom_forms.odin):
/// the controls' state stays the forms model's (module forms), which follows the attributes.
package api_js_dom_forms

/// input.type = value
//@wb fn raises
HTMLInputElement_set_type :: proc(element: Element, value: string)

/// input.maxLength = value: Index_Size for a negative value.
//@wb fn raises
HTMLInputElement_set_maxLength :: proc(element: Element, value: i32)

/// input.minLength = value: Index_Size for a negative value.
//@wb fn raises
HTMLInputElement_set_minLength :: proc(element: Element, value: i32)

/// textarea.maxLength = value: Index_Size for a negative value.
//@wb fn raises
HTMLTextAreaElement_set_maxLength :: proc(element: Element, value: i32)

/// textarea.minLength = value: Index_Size for a negative value.
//@wb fn raises
HTMLTextAreaElement_set_minLength :: proc(element: Element, value: i32)

/// option.text = value: its children replaced by one Text node.
//@wb fn raises
HTMLOptionElement_set_text :: proc(element: Element, value: string)

