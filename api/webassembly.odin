// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=webassembly order=68 exposed=(Window,Worker)
/// The WebAssembly JavaScript API (src/page/webassembly.odin, the objects: native/js/odin/web_wasm.odin): a page's own
/// WebAssembly modules, compiled and run by Wasmtime beside the engine's. Off until it is complete
/// (javascript.webassembly.enabled): a page that finds a `WebAssembly` object expects all of it.
package api_webassembly

//@wb handle parent=Object host=Wasm_Module lookup=lookup_WebAssemblyModule
WebAssemblyModule :: distinct Handle

/// Whether the page's realm has the `WebAssembly` object (javascript.webassembly.enabled).
//@wb fn
WebAssembly_enabled :: proc() -> bool

/// WebAssembly.validate(bytes): whether `bytes` is a valid module.
//@wb fn
WebAssembly_validate :: proc(module: bytes) -> bool

/// new WebAssembly.Module(bytes): `bytes` compiled. Syntax with the reason when it is not a valid module, Security when
/// the page's Content Security Policy refuses it.
//@wb fn raises
WebAssembly_compile :: proc(module: bytes) -> WebAssemblyModule

/// WebAssembly.Module.imports(module), as JSON.
//@wb fn
WebAssembly_Module_imports :: proc(module: WebAssemblyModule) -> string

/// WebAssembly.Module.exports(module), as JSON.
//@wb fn
WebAssembly_Module_exports :: proc(module: WebAssemblyModule) -> string

/// How many custom sections of the module are called `name`.
//@wb fn
WebAssembly_Module_customSectionCount :: proc(module: WebAssemblyModule, name: string) -> i32

/// The bytes of the custom section number `index` of those called `name`.
//@wb fn
WebAssembly_Module_customSection :: proc(module: WebAssemblyModule, name: string, index: i32) -> bytes

