package page

// Setters of form controls' IDL attributes over content attributes (api/js_dom_forms.widl). The forms model reads the
// attributes, so it follows (a type change rebuilds the control's state as the forms model defines).

import "core:fmt"
import "wb:dom"

HTMLInputElement_set_type :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "type", value))
}

@(private)
set_length_attr :: proc(c: ^Call, element: Api_Element, attr: string, value: i32) -> Api_Error {
	if value < 0 { return fail(c, .Index_Size, "The value provided is negative.") }
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), attr, fmt.tprintf("%d", value)))
}

HTMLInputElement_set_maxLength :: proc(c: ^Call, element: Api_Element, value: i32) -> Api_Error { return set_length_attr(c, element, "maxlength", value) }
HTMLInputElement_set_minLength :: proc(c: ^Call, element: Api_Element, value: i32) -> Api_Error { return set_length_attr(c, element, "minlength", value) }
HTMLTextAreaElement_set_maxLength :: proc(c: ^Call, element: Api_Element, value: i32) -> Api_Error { return set_length_attr(c, element, "maxlength", value) }
HTMLTextAreaElement_set_minLength :: proc(c: ^Call, element: Api_Element, value: i32) -> Api_Error { return set_length_attr(c, element, "minlength", value) }

HTMLOptionElement_set_text :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_text_content(c.page.doc, H(element.handle), value))
}
