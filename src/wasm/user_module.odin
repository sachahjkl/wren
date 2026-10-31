package wasm

// The modules a page's JavaScript brings (the WebAssembly JavaScript API, src/page/webassembly.odin), as opposed to the
// engine's own and the pages written in WebAssembly: compiled by the same Wasmtime engine, so with the same features
// (wasm.features.*).

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "wb:base"

// A custom section of a module (Module.customSections). The name and the bytes are the module's own copies.
User_Section :: struct {
	name: string,
	data: []byte,
}

// A compiled module and what Module.imports, Module.exports and Module.customSections say of it: the source is not kept.
User_Module :: struct {
	module:   wt_module,
	refs:     i32,      // atomic: the agents of a cluster share it (user_module_share); nothing else changes once made
	imports:  string,   // JSON: [{"module", "name", "kind"}], in the order of the module
	exports:  string,   // JSON: [{"name", "kind"}], in the order of the module
	export_index: []u32,   // the index each export has in its index space, in the same order
	export_names: []string,   // and its name
	link_info: string,     // what user_module_link_info says of it
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

// WebAssembly.validate: whether `image` is a valid module for this engine's features (the old form of exceptions read as
// translate_legacy_exceptions makes it).
validate :: proc(image: []byte) -> bool {
	if wt.engine == nil { return false }
	e := wasmtime_module_validate(wt.engine, raw_data(image), uint(len(image)))
	if e == nil { return true }
	wasmtime_error_delete(e)
	if !wt.rs.features.exceptions { return false }
	translated := translate_legacy_exceptions(image, context.temp_allocator)
	if translated == nil { return false }
	e = wasmtime_module_validate(wt.engine, raw_data(translated), uint(len(translated)))
	if e == nil { return true }
	wasmtime_error_delete(e)
	return false
}

// Reads the import, export and custom sections of a module Wasmtime has accepted (so a failure here is a kind or a form
// this reader does not know, not a bad module).
@(private = "file")
user_module_describe :: proc(m: ^User_Module, image: []byte) -> (err: string) {
	imports := make([dynamic]Import_Entry, context.temp_allocator)
	exports := make([dynamic]Export_Entry, context.temp_allocator)
	sections := make([dynamic]User_Section)
	indexes := make([dynamic]u32)
	names := make([dynamic]string)
	defer { m.sections = sections[:]; m.export_index = indexes[:]; m.export_names = names[:] }
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
				append(&names, strings.clone(name))
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

// A compilation's result, not yet a User_Module: user_module_compile can run on any thread (a large module takes seconds);
// user_module_finish makes the module on the page's.
User_Compiled :: struct {
	module: wt_module,
	error:  wt_error,
}

// `partition`: the top-level site, for the disk cache: what one site compiled says nothing to another, as in other browsers.
user_module_compile :: proc(image: []byte, partition: string = "") -> (c: User_Compiled) {
	if wt.engine == nil { return }
	filekey: Digest
	path: string
	defer delete(path, base.process_allocator())
	if cache.disk {
		// (a module's compiled form depends on the settings: the fingerprint)
		filekey, _ = sha256(transmute([]byte)string("page module"), transmute([]byte)partition, image, wt.fingerprint[:])
		path = disk_path(filekey)
		if c.module = disk_load(path, filekey); c.module != nil {
			sync.mutex_guard(&cache.lock)
			cache.stats.disk_hits += 1
			return
		}
	}
	defer if cache.disk && c.error == nil && c.module != nil { disk_queue(path, filekey, c.module) }
	// (a module with a shared memory: its waits can be stopped; the module as it came if that does not compile)
	if waits := translate_shared_waits(image, base.process_allocator()); waits != nil {
		defer delete(waits, base.process_allocator())
		c = compile_image(waits)
		if c.error == nil { return }
		wasmtime_error_delete(c.error)
		c = {}
	}
	return compile_image(image)
}

@(private = "file")
compile_image :: proc(image: []byte) -> (c: User_Compiled) {
	c.error = wasmtime_module_new(wt.engine, raw_data(image), uint(len(image)), &c.module)
	if c.error == nil || !wt.rs.features.exceptions { return }
	// the old form of exceptions? (only what changes the module changes the answer: the first error stands otherwise)
	translated := translate_legacy_exceptions(image, base.process_allocator())
	if translated == nil { return }
	defer delete(translated, base.process_allocator())
	module: wt_module
	if e := wasmtime_module_new(wt.engine, raw_data(translated), uint(len(translated)), &module); e != nil {
		wasmtime_error_delete(e)
		return
	}
	wasmtime_error_delete(c.error)
	c.error, c.module = nil, module
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
	// (the heap of the process: the last agent that has the module frees it, on its thread)
	context.allocator = base.process_allocator()
	m = new(User_Module)
	m.module, m.refs = c.module, 1
	if err = user_module_describe(m, image); err != "" {
		user_module_delete(m)
		return nil, err
	}
	m.link_info = user_module_link_info(m)
	return m, ""
}

// Why Wasmtime refuses `image`, as it says it ("" when it takes it); in temporary memory.
user_module_compile_error :: proc(image: []byte) -> string {
	if e := wasmtime_module_validate(wt.engine, raw_data(image), uint(len(image))); e != nil {
		text := wt_error_text(e, context.temp_allocator)
		wasmtime_error_delete(e)
		return text
	}
	return ""
}

// WebAssembly.Module: compiles `image` on this thread.
user_module_new :: proc(image: []byte, partition: string = "") -> (m: ^User_Module, err: string) {
	return user_module_finish(user_module_compile(image, partition), image)
}

// One who had it does not any more.
user_module_delete :: proc(m: ^User_Module) {
	if sync.atomic_sub(&m.refs, 1) != 1 { return }
	context.allocator = base.process_allocator()
	wasmtime_module_delete(m.module)
	delete(m.imports)
	delete(m.exports)
	delete(m.export_index)
	for n in m.export_names { delete(n) }
	delete(m.export_names)
	delete(m.link_info)
	for s in m.sections {
		delete(s.name)
		delete(s.data)
	}
	delete(m.sections)
	free(m)
}
