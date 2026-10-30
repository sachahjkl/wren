package wasm

// The modules a page's JavaScript brings (the WebAssembly JavaScript API, src/page/webassembly.odin), as opposed to the
// engine's own and the pages written in WebAssembly: compiled by the same Wasmtime engine, so with the same features
// (wasm.features.*).

import "core:encoding/json"
import "core:strings"

// A custom section of a module (Module.customSections). The name and the bytes are the module's own copies.
User_Section :: struct {
	name: string,
	data: []byte,
}

// A compiled module and what Module.imports, Module.exports and Module.customSections say of it: the source is not kept.
User_Module :: struct {
	module:   wt_module,
	imports:  string,   // JSON: [{"module", "name", "kind"}], in the order of the module
	exports:  string,   // JSON: [{"name", "kind"}], in the order of the module
	export_index: []u32,   // the index each export has in its index space, in the same order
	link_info: string,     // made on first use (user_module_link_info)
	sections: []User_Section,
}

@(private = "file")
Import_Entry :: struct {
	module, name, kind: string,
}

@(private = "file")
Export_Entry :: struct {
	name, kind: string,
}

// The names the JavaScript API gives the kinds of the binary format ("" for a kind it does not know).
@(private = "file")
extern_kind_name :: proc(kind: u8) -> string {
	switch kind {
	case 0: return "function"
	case 1: return "table"
	case 2: return "memory"
	case 3: return "global"
	case 4: return "tag"
	}
	return ""
}

// WebAssembly.validate: whether `image` is a valid module for this engine's features. One exception: the module sites
// test to ask "are there WebAssembly exceptions?" (wasm-feature-detect, .NET's runtime) uses the old form of the proposal
// (try / catch_all), which Wasmtime does not take although it has exceptions (try_table): it gets yes, or a .NET
// application built for exceptions refuses to start. A module really using the old form still gets a CompileError.
validate :: proc(image: []byte) -> bool {
	if wt.engine == nil { return false }
	PROBE :: [28]u8{0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 8, 1, 6, 0, 6, 64, 25, 11, 11}
	probe := PROBE
	if wt.rs.features.exceptions && string(image) == string(probe[:]) { return true }
	e := wasmtime_module_validate(wt.engine, raw_data(image), uint(len(image)))
	if e != nil {
		wasmtime_error_delete(e)
		return false
	}
	return true
}

// Reads the import, export and custom sections of a module Wasmtime has accepted (so a failure here is a kind or a form
// this reader does not know, not a bad module).
@(private = "file")
user_module_describe :: proc(m: ^User_Module, image: []byte) -> (err: string) {
	imports := make([dynamic]Import_Entry, context.temp_allocator)
	exports := make([dynamic]Export_Entry, context.temp_allocator)
	sections := make([dynamic]User_Section)
	indexes := make([dynamic]u32)
	defer { m.sections = sections[:]; m.export_index = indexes[:] }
	r := Reader{b = image, pos = 8}
	for r.pos < len(image) {
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		if r.bad || r.pos + size > len(image) { return "malformed module: truncated section" }
		body := Reader{b = image[r.pos:r.pos + size]}
		r.pos += size
		switch id {
		case 0:
			name := rd_name(&body)
			if !body.bad {
				append(&sections, User_Section{strings.clone(name), transmute([]byte)strings.clone(string(body.b[body.pos:]))})
			}
		case 2:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n {
				if body.bad { break }
				module := rd_name(&body)
				name := rd_name(&body)
				kind := rd_byte(&body)
				switch kind {
				case 0: rd_leb(&body, 32)
				case 1: rd_reftype(&body); rd_limits(&body)
				case 2: rd_limits(&body)
				case 3: rd_reftype(&body); rd_byte(&body)   // (a value type reads as a reference type does)
				case 4: rd_byte(&body); rd_leb(&body, 32)
				case: body.bad = true
				}
				append(&imports, Import_Entry{module, name, extern_kind_name(kind)})
			}
		case 7:
			n := rd_leb(&body, 32)
			for _ in 0 ..< n {
				if body.bad { break }
				name := rd_name(&body)
				kind := rd_byte(&body)
				append(&indexes, u32(rd_leb(&body, 32)))
				if extern_kind_name(kind) == "" { body.bad = true }
				append(&exports, Export_Entry{name, extern_kind_name(kind)})
			}
		}
		if body.bad { return "the module has a section this browser cannot read" }
	}
	a, e1 := json.marshal(imports[:], allocator = context.temp_allocator)
	b, e2 := json.marshal(exports[:], allocator = context.temp_allocator)
	if e1 != nil || e2 != nil { return "the description of the module cannot be written" }
	m.imports = strings.clone(string(a))
	m.exports = strings.clone(string(b))
	return ""
}

// A compilation's result, not yet a User_Module: user_module_compile touches no Odin allocator, so it can run on any
// thread (a large module takes seconds); user_module_finish makes the module on the page's.
User_Compiled :: struct {
	module: wt_module,
	error:  wt_error,
}

user_module_compile :: proc "contextless" (image: []byte) -> (c: User_Compiled) {
	if wt.engine == nil { return }
	c.error = wasmtime_module_new(wt.engine, raw_data(image), uint(len(image)), &c.module)
	return
}

// Takes `c`. nil and the reason (in temporary memory) when `image`, what was compiled, is not a valid module.
user_module_finish :: proc(c: User_Compiled, image: []byte) -> (m: ^User_Module, err: string) {
	if c.error != nil {
		err = wt_error_text(c.error, context.temp_allocator)
		wasmtime_error_delete(c.error)
		return nil, err
	}
	if c.module == nil { return nil, "the WebAssembly engine is not running" }
	m = new(User_Module)
	m.module = c.module
	if err = user_module_describe(m, image); err != "" {
		user_module_delete(m)
		return nil, err
	}
	return m, ""
}

// WebAssembly.Module: compiles `image` on this thread.
user_module_new :: proc(image: []byte) -> (m: ^User_Module, err: string) {
	return user_module_finish(user_module_compile(image), image)
}

user_module_delete :: proc(m: ^User_Module) {
	wasmtime_module_delete(m.module)
	delete(m.imports)
	delete(m.exports)
	delete(m.export_index)
	delete(m.link_info)
	for s in m.sections {
		delete(s.name)
		delete(s.data)
	}
	delete(m.sections)
	free(m)
}
