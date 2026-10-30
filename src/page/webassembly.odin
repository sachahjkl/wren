package page

// The WebAssembly JavaScript API (api/webassembly.odin; the objects are native/js/odin/web_wasm.odin and web_wasm.js). A
// page's own modules are compiled and run by Wasmtime beside the engine's instance (package wasm, user_module.odin).

import "core:fmt"
import "wb:base"
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
wasm_compile_settle :: proc(pg: ^Page, j: ^Wasm_Compile_Job) {
	defer { delete(j.image); free(j) }
	m, err := wasm.user_module_finish(j.compiled, j.image)
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
	j^ = Wasm_Compile_Job{page = p.web != nil ? p.web.id : 0, promise = pr, owner = c.owner, image = make([]byte, len(module))}
	copy(j.image, module)
	work := proc(data: rawptr) {
		j := (^Wasm_Compile_Job)(data)
		j.compiled = wasm.user_module_compile(j.image)
	}
	if p.loader != nil && p.loader.blocking != nil {
		host.run_blocking(p.loader.blocking, work, proc(data: rawptr) {
			j := (^Wasm_Compile_Job)(data)
			wasm_compile_settle(page_by_id(j.page), j)
		}, j)
	} else {
		// (no pool here, a worker: the worker's own thread compiles; the promise still settles from a task)
		work(j)
		post_page_task(p, proc(pg: ^Page, data: rawptr) { wasm_compile_settle(pg, (^Wasm_Compile_Job)(data)) }, j)
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

// ---- what a page makes: one store per realm (package wasm, user_store.odin) ----

@(private = "file")
wasm_store :: proc(c: ^Call) -> ^wasm.User_Store {
	p := c.page
	if p.wasm_store != nil { return p.wasm_store }
	if p.js == nil || p.js.inst == nil { return nil }
	p.wasm_store = wasm.user_store_new(p.js.inst, wasm_run_import, p)
	if p.wasm_store != nil {
		base.on_close(p.scope, proc(data: rawptr) { wasm.user_store_delete((^wasm.User_Store)(data)) }, p.wasm_store)
	}
	return p.wasm_store
}

// An import of the page's module, called from inside its code: into the realm (wj_wasm_import, native/js/odin/web_wasm.odin).
@(private = "file")
wasm_run_import :: proc(s: ^wasm.User_Store, slot: i32) -> bool {
	p := (^Page)(s.user)
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead {
		wasm.user_set_error(s, "the realm of this module is gone")
		return false
	}
	argv := [1]u32{u32(slot)}
	if js_call(p, r.inst, "wj_wasm_import", argv[:]) != .Ok {
		wasm.user_set_error(s, "the JavaScript engine stopped during an import")
		return false
	}
	return argv[0] == 0
}

@(private = "file")
NO_STORE :: i32(-4)   // (a TypeError: wasm.User_Failure.Type)

@(private = "file")
wasm_status :: proc(id: i32, f: wasm.User_Failure) -> i32 { return f != .None ? -i32(f) : id }

WebAssembly_lastError :: proc(c: ^Call) -> string {
	s := wasm_store(c)
	return s != nil ? s.error : "the WebAssembly engine is not running"
}

WebAssembly_Memory_create :: proc(c: ^Call, initial: i64, maximum: i64) -> i32 {
	s := wasm_store(c)
	if s == nil { return NO_STORE }
	return wasm_status(wasm.user_memory_new(s, initial, maximum))
}

WebAssembly_Memory_pages :: proc(c: ^Call, memory: i32) -> i64 {
	s := wasm_store(c)
	return s != nil ? wasm.user_memory_pages(s, memory) : -1
}

WebAssembly_Memory_grow :: proc(c: ^Call, memory: i32, delta: i64) -> i64 {
	s := wasm_store(c)
	if s == nil { return i64(NO_STORE) }
	prev, f := wasm.user_memory_grow(s, memory, delta)
	return f != .None ? -i64(f) : prev
}

WebAssembly_Memory_read :: proc(c: ^Call, memory: i32, offset: i64, destination: []u8) -> i32 {
	s := wasm_store(c)
	return s != nil ? i32(wasm.user_memory_read(s, memory, offset, destination)) : 0
}

WebAssembly_Memory_write :: proc(c: ^Call, memory: i32, offset: i64, source: []u8) -> i32 {
	s := wasm_store(c)
	return s != nil ? i32(wasm.user_memory_write(s, memory, offset, source)) : 0
}

WebAssembly_Table_create :: proc(c: ^Call, element: string, initial: i64, maximum: i64, init: i64) -> i32 {
	s := wasm_store(c)
	if s == nil || len(element) != 1 { return NO_STORE }
	return wasm_status(wasm.user_table_new(s, element[0], initial, maximum, u64(init)))
}

WebAssembly_Table_element :: proc(c: ^Call, table: i32) -> string {
	s := wasm_store(c)
	if s == nil { return "" }
	switch wasm.user_table_letter(s, table) {
	case 'r': return "r"
	case 'e': return "e"
	}
	return ""
}

WebAssembly_Table_length :: proc(c: ^Call, table: i32) -> i64 {
	s := wasm_store(c)
	return s != nil ? wasm.user_table_length(s, table) : -1
}

WebAssembly_Table_get :: proc(c: ^Call, table: i32, index: i64, cell: []u8) -> i32 {
	s := wasm_store(c)
	if s == nil || len(cell) < 8 { return NO_STORE }
	v, f := wasm.user_table_get(s, table, index)
	if f != .None { return -i32(f) }
	(^u64le)(raw_data(cell))^ = u64le(v)
	return 0
}

WebAssembly_Table_set :: proc(c: ^Call, table: i32, index: i64, cell: i64) -> i32 {
	s := wasm_store(c)
	if s == nil { return NO_STORE }
	return -i32(wasm.user_table_set(s, table, index, u64(cell)))
}

WebAssembly_Table_grow :: proc(c: ^Call, table: i32, delta: i64, init: i64) -> i64 {
	s := wasm_store(c)
	if s == nil { return i64(NO_STORE) }
	prev, f := wasm.user_table_grow(s, table, delta, u64(init))
	return f != .None ? -i64(f) : prev
}

WebAssembly_Global_create :: proc(c: ^Call, type: string, mutable: bool, cell: i64) -> i32 {
	s := wasm_store(c)
	if s == nil || len(type) != 1 { return NO_STORE }
	return wasm_status(wasm.user_global_new(s, type[0], mutable, u64(cell)))
}

WebAssembly_Global_type :: proc(c: ^Call, global: i32) -> string {
	s := wasm_store(c)
	if s == nil { return "" }
	letter, mutable := wasm.user_global_type(s, global)
	if letter == 0 { return "" }
	return fmt.tprintf("%c%s", rune(letter), mutable ? "m" : "")
}

WebAssembly_Global_get :: proc(c: ^Call, global: i32) -> i64 {
	s := wasm_store(c)
	return s != nil ? i64(wasm.user_global_get(s, global)) : 0
}

WebAssembly_Global_set :: proc(c: ^Call, global: i32, cell: i64) -> i32 {
	s := wasm_store(c)
	if s == nil { return NO_STORE }
	return -i32(wasm.user_global_set(s, global, u64(cell)))
}

WebAssembly_Func_import :: proc(c: ^Call, slot: i32, sig: string) -> i32 {
	s := wasm_store(c)
	if s == nil { return NO_STORE }
	return wasm_status(wasm.user_func_import(s, slot, sig))
}

WebAssembly_Func_sig :: proc(c: ^Call, func: i32) -> string {
	s := wasm_store(c)
	if s == nil { return "" }
	f := wasm.user_func(s, func)
	return f != nil ? f.sig : ""
}

WebAssembly_Func_call :: proc(c: ^Call, func: i32, args: []u8) -> i32 {
	s := wasm_store(c)
	if s == nil || len(args) % 8 != 0 { return NO_STORE }
	fn := wasm.user_func(s, func)
	if fn == nil { return NO_STORE }
	// (the cells are in the engine's memory, which an import may move during the call: a copy)
	cargs := make([]u64, len(args) / 8, context.temp_allocator)
	copy(([^]u8)(raw_data(cargs))[:len(args)], args)
	cres := make([]u64, fn.nresults, context.temp_allocator)
	if f := wasm.user_func_call(s, func, cargs, cres); f != .None { return -i32(f) }
	clear(&s.call_results)
	append(&s.call_results, ..cres)
	return 0
}

WebAssembly_Func_results :: proc(c: ^Call) -> []u8 {
	s := wasm_store(c)
	if s == nil || len(s.call_results) == 0 { return nil }
	return ([^]u8)(raw_data(s.call_results))[:len(s.call_results) * 8]
}

WebAssembly_import_args :: proc(c: ^Call) -> []u8 {
	s := wasm_store(c)
	if s == nil || len(s.import_args) == 0 { return nil }
	return ([^]u8)(raw_data(s.import_args))[:len(s.import_args) * 8]
}

WebAssembly_import_results :: proc(c: ^Call, results: []u8) {
	s := wasm_store(c)
	if s == nil { return }
	n := min(len(results), len(s.import_results) * 8)
	if n > 0 { copy(([^]u8)(raw_data(s.import_results))[:n], results[:n]) }
}

WebAssembly_import_failed :: proc(c: ^Call, message: string) {
	if s := wasm_store(c); s != nil { wasm.user_set_error(s, message) }
}

WebAssembly_Module_linkInfo :: proc(c: ^Call, module: Api_WebAssemblyModule) -> string {
	m := module.data
	if m.link_info == "" { m.link_info = wasm.user_module_link_info(m) }
	return m.link_info
}

WebAssembly_Tag_create :: proc(c: ^Call, parameters: string) -> i32 {
	s := wasm_store(c)
	if s == nil { return NO_STORE }
	return wasm_status(wasm.user_tag_new(s, fmt.tprintf("%s:", parameters)))
}

WebAssembly_Tag_sig :: proc(c: ^Call, tag: i32) -> string {
	s := wasm_store(c)
	return s != nil ? wasm.user_tag_sig(s, tag, context.temp_allocator) : ""
}

WebAssembly_exception_tag :: proc(c: ^Call) -> i32 {
	s := wasm_store(c)
	return s != nil ? s.exn_tag : -1
}

WebAssembly_import_throw :: proc(c: ^Call, tag: i32, values: []u8) {
	s := wasm_store(c)
	if s == nil { return }
	clear(&s.call_results)
	resize(&s.call_results, len(values) / 8)
	if len(values) >= 8 { copy(([^]u8)(raw_data(s.call_results))[:len(values) &~ 7], values) }
	s.exn_tag = tag
	s.import_throw = true
}

WebAssembly_extern_released :: proc(c: ^Call) -> i32 {
	s := wasm_store(c)
	if s == nil || len(s.extern_released) == 0 { return 0 }
	return i32(pop(&s.extern_released))
}

WebAssembly_Instance_create :: proc(c: ^Call, module: Api_WebAssemblyModule, externs: []u8) -> i32 {
	s := wasm_store(c)
	if s == nil || len(externs) % 4 != 0 { return NO_STORE }
	ids := make([]u32, len(externs) / 4, context.temp_allocator)
	if len(ids) > 0 { copy(([^]u8)(raw_data(ids))[:len(externs)], externs) }
	return wasm_status(wasm.user_instance_new(s, module.data, ids))
}

WebAssembly_Instance_exports :: proc(c: ^Call, instance: i32, module: Api_WebAssemblyModule) -> string {
	s := wasm_store(c)
	if s == nil { return "[]" }
	return wasm.user_instance_exports(s, instance, module.data, context.temp_allocator)
}
