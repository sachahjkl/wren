// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=18 partial
/// <iframe srcdoc>, reflected as a string (TrustedHTML is not supported: strings are).
package api_frames__dom

/// iframe.srcdoc
//@wb fn
HTMLIFrameElement_srcdoc :: proc(element: Element) -> string

/// iframe.srcdoc = value
//@wb fn raises
HTMLIFrameElement_set_srcdoc :: proc(element: Element, value: string)

