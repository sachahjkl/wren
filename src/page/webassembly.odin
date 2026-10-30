package page

// The WebAssembly JavaScript API (api/webassembly.odin; the objects are native/js/odin/web_wasm.odin and web_wasm.js). A
// page's own modules are compiled and run by Wasmtime beside the engine's instance (package wasm, user_module.odin).

import "wb:csp"
import "wb:wasm"

Wasm_Module :: wasm.User_Module

@(private)
wasm_module_vt := Object_VTable{name = "WebAssemblyModule", destroy = proc(p: ^Page, data: rawptr) {
	wasm.user_module_delete((^Wasm_Module)(data))
}}

lookup_WebAssemblyModule :: proc(c: ^Call, h: u64) -> ^Wasm_Module { return (^Wasm_Module)(object_data(c.page, h, &wasm_module_vt)) }

WebAssembly_enabled :: proc(c: ^Call) -> bool { return c.page.settings.js.webassembly }

WebAssembly_validate :: proc(c: ^Call, module: []u8) -> bool { return wasm.validate(module) }

WebAssembly_compile :: proc(c: ^Call, module: []u8) -> (u64, Api_Error) {
	p := c.page
	if len(p.env.policies.policies) > 0 && !csp_report(p, csp.check_wasm_eval(&p.env.policies)) {
		return 0, fail(c, .Security, "Refused to compile or instantiate WebAssembly module because 'wasm-eval' is not an allowed source of script in the page's Content Security Policy")
	}
	m, err := wasm.user_module_new(module)
	if m == nil { return 0, fail(c, .Syntax, err) }
	return object_create(p, &wasm_module_vt, m, c.owner), .None
}

WebAssembly_Module_imports :: proc(c: ^Call, module: Api_WebAssemblyModule) -> string { return module.data.imports }

WebAssembly_Module_exports :: proc(c: ^Call, module: Api_WebAssemblyModule) -> string { return module.data.exports }

WebAssembly_Module_customSectionCount :: proc(c: ^Call, module: Api_WebAssemblyModule, name: string) -> i32 {
	n: i32
	for &s in module.data.sections { if s.name == name { n += 1 } }
	return n
}

WebAssembly_Module_customSection :: proc(c: ^Call, module: Api_WebAssemblyModule, name: string, index: i32) -> []u8 {
	i: i32
	for &s in module.data.sections {
		if s.name != name { continue }
		if i == index { return s.data }
		i += 1
	}
	return nil
}
