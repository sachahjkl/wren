// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=28 partial
/// The document's life cycle as scripts see it (HTML "the current document readiness", "currentScript").
package api_js_document

/// document.readyState: "loading", "interactive" or "complete".
//@wb fn
Document_readyState :: proc() -> string

/// document.currentScript: the classic script element running, null otherwise.
//@wb fn
Document_currentScript :: proc() -> Element

/// window.document: the document node (null in a worker).
//@wb fn
Window_document :: proc() -> Node

/// `url` parsed against the document's base URL, serialized: Syntax when it is not a valid URL (reflected URL
/// attributes then give the attribute's value as is).
//@wb fn raises
Document_resolveURL :: proc(url: string) -> string

