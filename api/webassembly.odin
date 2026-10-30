// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webassembly order=68 exposed=(Window,Worker)
/// The WebAssembly JavaScript API (src/page/webassembly.odin, the objects: native/js/odin/web_wasm.odin): a page's own
/// WebAssembly modules, compiled and run by Wasmtime beside the engine's. Off until it is complete
/// (javascript.webassembly.enabled): a page that finds a `WebAssembly` object expects all of it.
package api_webassembly

/// Whether the page's realm has the `WebAssembly` object (javascript.webassembly.enabled).
//@wb fn
WebAssembly_enabled :: proc() -> bool

/// WebAssembly.validate(bytes): whether `bytes` is a valid module.
//@wb fn
WebAssembly_validate :: proc(module: bytes) -> bool

