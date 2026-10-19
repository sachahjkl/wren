package page

// The DOM members JavaScript reaches through api/js_dom.widl (module dom): the tree, attributes and documents as the
// DOM Standard defines them, on the browser's own DOM (package dom).

import "wb:dom"

Element_id :: proc(c: ^Call, element: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "id")
	return v
}

Element_set_id :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "id", value))
}

Element_className :: proc(c: ^Call, element: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "class")
	return v
}

Element_set_className :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "class", value))
}
