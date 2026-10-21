// Package idl: the declarative description of the web platform's Wasm imports (api/*.widl) and everything generated
// from it (host trampolines, guest SDK, documentation, conformance tests). One source of truth: a function exists once,
// with its types, its errors, its availability and its documentation; every copy of it in the code base is generated.
//
// The language is a small dialect of Web IDL, flattened for an ABI without objects (see docs/api/README.md):
//
//   /// Doc comment of the module.
//   [Exposed=(Window,Worker)]
//   module url {
//     /// A parsed absolute URL.
//     handle URL : Object = Url_Object via lookup_URL;
//     enum URLComponent : i32 { Href, Protocol, ... }
//     /// new URL(input, base): TypeError when the input is not a valid URL.
//     URL URL_parse(string input, optional string base) raises;
//   }
package idl

import vmem "core:mem/virtual"

Pos :: struct {
	file: string,
	line: int,
	col:  int,
}

Diag :: struct {
	pos: Pos,
	msg: string,
}

Realm :: enum u8 { Window, Worker }
Realms :: bit_set[Realm; u8]

Type_Kind :: enum u8 {
	Unresolved,
	Void,
	I32, U32, I64, U64, F32, F64, Bool,
	String,       // UTF-8, checked: invalid input is an error
	Usv_String,   // UTF-8, invalid sequences replaced by U+FFFD (Web IDL USVString)
	Bytes,
	Handle,
	Promise,      // a promise handle; Promise<T> documents what it settles with
	Enum,
	Flags,
	Struct,
	Callback,
}

Type :: struct {
	name: string,
	arg:  ^Type,    // Promise<T>
	seq:  bool,     // T[]: a sequence in guest memory
	pos:  Pos,
	kind: Type_Kind,
	decl: ^Decl,    // handle, enum, flags, struct, callback
}

Attr :: struct {
	name:   string,
	values: []string,
	pos:    Pos,
}

Param :: struct {
	name:        string,
	type:        Type,
	optional:    bool,
	out:         bool,
	default:     string,   // literal as written, "" = none
	pos:         Pos,
	attrs:       []Attr,
}

Member :: struct {
	name:      string,
	value:     i64,
	has_value: bool,
	doc:       string,
	pos:       Pos,
}

Field :: struct {
	name: string,
	type: Type,
	doc:  string,
	pos:  Pos,
}

Decl_Kind :: enum u8 { Handle, Enum, Flags, Struct, Callback, Function, Export }

Decl :: struct {
	kind:   Decl_Kind,
	name:   string,
	doc:    string,
	pos:    Pos,
	attrs:  []Attr,
	module: ^Module,

	// handle
	parent:      string,
	parent_decl: ^Decl,
	host_type:   string,   // "" = not checked by the binding layer (the implementation gets the raw handle)
	lookup:      string,

	// enum, flags
	base:    Type,
	members: []Member,

	// struct
	fields: []Field,

	// function, callback, export
	params:    []Param,
	result:    Type,
	raises:    bool,

	// resolved (functions)
	imports:   []string,   // import names: the declared one, or one per interface of [On=(...)]
	host_name: string,     // the implementation the host must provide
	exposed:   Realms,
	effects:   bool,       // calling it twice is not the same as once: no retrying wrappers, no capacity test
	abi:       Abi,
}

Module :: struct {
	name:    string,
	doc:     string,
	pos:     Pos,
	attrs:   []Attr,
	exposed: Realms,
	decls:   [dynamic]^Decl,
	partial: bool,
	file:    string,   // file of the (non-partial) declaration
}

// The wasm-level shape of a function. `P` values are addresses: i32 for a module whose memory 0 is 32-bit, i64 for a
// memory64 module.
Abi_Kind :: enum u8 { I32, I64, F32, F64, P }

Abi :: struct {
	params:      [dynamic]Abi_Kind,
	results:     [dynamic]Abi_Kind,
	ret_ptr:     bool,     // the result is written to guest memory at the last parameter
	out_string:  bool,     // the result is a string or bytes copied to the (ptr, cap) pair before the return pointer
	status:      bool,     // the wasm result is a status (0 or a negative Error)
}

Api :: struct {
	modules:   [dynamic]^Module,
	types:     map[string]^Decl,
	functions: [dynamic]^Decl,   // every function, in declaration order (files sorted by name)
	exports:   [dynamic]^Decl,
	callbacks: [dynamic]^Decl,
	diags:     [dynamic]Diag,
	error_enum: ^Decl,           // `enum Error`: the codes of `raises`
	arena:     vmem.Arena,       // owns all of the above (load, destroy)
}

attr_find :: proc(attrs: []Attr, name: string) -> (Attr, bool) {
	for a in attrs { if a.name == name { return a, true } }
	return {}, false
}
