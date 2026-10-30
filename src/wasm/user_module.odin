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

// Reads the import, export and custom sections of a module Wasmtime has accepted (so a failure here is a kind or a form
// this reader does not know, not a bad module).
@(private = "file")
user_module_describe :: proc(m: ^User_Module, image: []byte) -> (err: string) {
	imports := make([dynamic]Import_Entry, context.temp_allocator)
	exports := make([dynamic]Export_Entry, context.temp_allocator)
	sections := make([dynamic]User_Section)
	defer m.sections = sections[:]
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
				rd_leb(&body, 32)
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

// WebAssembly.Module: compiles `image`. nil and the reason (in temporary memory) when it is not a valid module.
user_module_new :: proc(image: []byte) -> (m: ^User_Module, err: string) {
	if wt.engine == nil { return nil, "the WebAssembly engine is not running" }
	module: wt_module
	if e := wasmtime_module_new(wt.engine, raw_data(image), uint(len(image)), &module); e != nil {
		err = wt_error_text(e, context.temp_allocator)
		wasmtime_error_delete(e)
		return nil, err
	}
	m = new(User_Module)
	m.module = module
	if err = user_module_describe(m, image); err != "" {
		user_module_delete(m)
		return nil, err
	}
	return m, ""
}

user_module_delete :: proc(m: ^User_Module) {
	wasmtime_module_delete(m.module)
	delete(m.imports)
	delete(m.exports)
	for s in m.sections {
		delete(s.name)
		delete(s.data)
	}
	delete(m.sections)
	free(m)
}
