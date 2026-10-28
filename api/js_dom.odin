// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=29 partial
/// The DOM Standard's tree as JavaScript reaches it (Node, Element, Document...): the members the bindings bind by
/// name (Interface_member, Interface_set_member; see src/tools/bindgen/jsgen).
package api_js_dom

/// element.id
//@wb fn
Element_id :: proc(element: Element) -> string

/// element.id = value
//@wb fn raises
Element_set_id :: proc(element: Element, value: string)

/// element.className
//@wb fn
Element_className :: proc(element: Element) -> string

/// element.className = value
//@wb fn raises
Element_set_className :: proc(element: Element, value: string)

