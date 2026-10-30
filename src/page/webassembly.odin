package page

// The WebAssembly JavaScript API (api/webassembly.odin; the objects are native/js/odin/web_wasm.odin). A page's own
// modules are compiled and run by Wasmtime beside the engine's instance (package wasm, user_module.odin).

import "wb:wasm"

WebAssembly_enabled :: proc(c: ^Call) -> bool { return c.page.settings.js.webassembly }

WebAssembly_validate :: proc(c: ^Call, module: []u8) -> bool { return wasm.validate(module) }
