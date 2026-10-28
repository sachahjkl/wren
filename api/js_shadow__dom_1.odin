// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=46 partial
package api_js_shadow__dom_1

/// element.attachInternals(): Not_Supported unless a custom element (or attached already). An ElementInternals.
//@wb fn raises
Element_attachInternals :: proc(element: Element) -> u64

/// internals.shadowRoot: the host's shadow root when it is available to element internals (else null).
//@wb fn
ElementInternals_shadowRootOf :: proc(internals: u64) -> Node

/// The element of an ElementInternals.
//@wb fn
ElementInternals_element :: proc(internals: u64) -> Element

/// CustomStateSet: add / delete (true when it was there) / has / clear / the states (each followed by a NUL byte).
//@wb fn
CustomStates_add :: proc(internals: u64, state: string)

//@wb fn
CustomStates_delete :: proc(internals: u64, state: string) -> bool

//@wb fn
CustomStates_has :: proc(internals: u64, state: string) -> bool

//@wb fn
CustomStates_clear :: proc(internals: u64)

//@wb fn
CustomStates_list :: proc(internals: u64) -> string

