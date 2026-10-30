package wasm

// The modules a page's JavaScript brings (the WebAssembly JavaScript API, src/page/webassembly.odin), as opposed to the
// engine's own and the pages written in WebAssembly: compiled by the same Wasmtime engine, so with the same features
// (wasm.features.*).

// WebAssembly.validate: whether `image` is a valid module for this engine's features.
validate :: proc(image: []byte) -> bool {
	if wt.engine == nil { return false }
	e := wasmtime_module_validate(wt.engine, raw_data(image), uint(len(image)))
	if e != nil {
		wasmtime_error_delete(e)
		return false
	}
	return true
}
