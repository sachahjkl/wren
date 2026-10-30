package page

// The WebAssembly JavaScript API (api/webassembly.odin; the objects are native/js/odin/web_wasm.odin and web_wasm.js). A
// page's own modules are compiled and run by Wasmtime beside the engine's instance (package wasm, user_module.odin).

import "wb:csp"
import "wb:host"
import "wb:wasm"

Wasm_Module :: wasm.User_Module

@(private)
wasm_module_vt := Object_VTable{name = "WebAssemblyModule", destroy = proc(p: ^Page, data: rawptr) {
	wasm.user_module_delete((^Wasm_Module)(data))
}}

lookup_WebAssemblyModule :: proc(c: ^Call, h: u64) -> ^Wasm_Module { return (^Wasm_Module)(object_data(c.page, h, &wasm_module_vt)) }

WebAssembly_enabled :: proc(c: ^Call) -> bool { return c.page.settings.js.webassembly }

WebAssembly_validate :: proc(c: ^Call, module: []u8) -> bool { return wasm.validate(module) }

@(private = "file")
WASM_CSP_REFUSED :: "Refused to compile or instantiate WebAssembly module because 'wasm-eval' is not an allowed source of script in the page's Content Security Policy"

@(private = "file")
wasm_csp_allows :: proc(p: ^Page) -> bool {
	return len(p.env.policies.policies) == 0 || csp_report(p, csp.check_wasm_eval(&p.env.policies))
}

WebAssembly_compile :: proc(c: ^Call, module: []u8) -> (u64, Api_Error) {
	if !wasm_csp_allows(c.page) { return 0, fail(c, .Security, WASM_CSP_REFUSED) }
	m, err := wasm.user_module_new(module)
	if m == nil { return 0, fail(c, .Syntax, err) }
	return object_create(c.page, &wasm_module_vt, m, c.owner), .None
}

@(private = "file")
Wasm_Compile_Job :: struct {
	page:     u64,
	promise:  u64,
	owner:    u32,
	image:    []byte,               // a copy: the bytes are the ones of the call, whatever the script does next
	compiled: wasm.User_Compiled,
}

@(private = "file")
wasm_compile_done :: proc(data: rawptr) {
	j := (^Wasm_Compile_Job)(data)
	defer { delete(j.image); free(j) }
	m, err := wasm.user_module_finish(j.compiled, j.image)
	pg := page_by_id(j.page)
	if pg == nil {
		if m != nil { wasm.user_module_delete(m) }
		return
	}
	if m == nil { promise_reject(pg, j.promise, i64(Api_Error.Syntax), err); return }
	promise_resolve_object(pg, j.promise, object_create(pg, &wasm_module_vt, m, j.owner))
}

// WebAssembly.compile: on a thread of the blocking pool, so the page goes on while a large module compiles.
WebAssembly_compileAsync :: proc(c: ^Call, module: []u8) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if !wasm_csp_allows(p) {
		promise_reject(p, pr, i64(Api_Error.Security), WASM_CSP_REFUSED)
		return pr
	}
	j := new(Wasm_Compile_Job)
	j^ = Wasm_Compile_Job{page = p.web.id, promise = pr, owner = c.owner, image = make([]byte, len(module))}
	copy(j.image, module)
	work := proc(data: rawptr) {
		j := (^Wasm_Compile_Job)(data)
		j.compiled = wasm.user_module_compile(j.image)
	}
	if p.loader != nil && p.loader.blocking != nil {
		host.run_blocking(p.loader.blocking, work, wasm_compile_done, j)
	} else {
		// (no pool in this embedding: the same steps, the promise still settling from a task)
		work(j)
		post_page_task(p, proc(_: ^Page, data: rawptr) { wasm_compile_done(data) }, j)
	}
	return pr
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
