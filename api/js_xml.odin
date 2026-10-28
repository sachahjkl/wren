// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=52 partial
/// XMLSerializer for JavaScript (src/page/js_xml.odin; the object: native/js/runtime/dom_core.c).
package api_js_xml

/// new XMLSerializer().serializeToString(node): the node and its subtree as XML (DOM Parsing §3.2, not
/// well-formed-checked). Range past page.max_fetch_bytes.
//@wb fn raises
XMLSerializer_serialize :: proc(node: Node) -> string

