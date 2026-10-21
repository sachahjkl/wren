package idl

import "core:slice"
import "core:strconv"
import "core:strings"
import vmem "core:mem/virtual"

// Parses every (file name, contents) pair, in the order given, and checks the whole description. The result is usable
// for generation only when `api.diags` is empty.
// Everything the description is made of (declarations, types, diagnostics, ABIs) lives in the api's arena: `destroy`
// frees it at once. The file texts stay the caller's (names and docs are slices of them).
load :: proc(files: []File_Source) -> ^Api {
	api := new(Api)
	context.allocator = vmem.arena_allocator(&api.arena)
	api.types = make(map[string]^Decl)
	for f in files { parse_file(api, f.name, f.text) }
	if len(api.diags) == 0 { check(api) }
	return api
}

destroy :: proc(api: ^Api) {
	if api == nil { return }
	vmem.arena_destroy(&api.arena)
	free(api)
}

File_Source :: struct {
	name: string,
	text: string,
}

@(private)
builtin :: proc(name: string) -> (Type_Kind, bool) {
	switch name {
	case "void": return .Void, true
	case "i32": return .I32, true
	case "u32": return .U32, true
	case "i64": return .I64, true
	case "u64": return .U64, true
	case "f32": return .F32, true
	case "f64": return .F64, true
	case "bool": return .Bool, true
	case "string": return .String, true
	case "usvstring": return .Usv_String, true
	case "bytes": return .Bytes, true
	}
	return .Unresolved, false
}

@(private)
realm_named :: proc(name: string) -> (Realm, bool) {
	switch name {
	case "Window": return .Window, true
	case "Worker": return .Worker, true
	}
	return .Window, false
}

@(private)
FUNCTION_ATTRS :: []string{"Exposed", "On", "Effects", "Host"}

@(private)
check :: proc(api: ^Api) {
	// modules: one declaration each, partial ones extend it
	by_name := make(map[string]^Module, context.temp_allocator)
	for m in api.modules {
		if m.partial { continue }
		if prev, dup := by_name[m.name]; dup {
			diag(api, m.pos, "module %s is declared twice (first at %s:%d); use 'partial module' to extend it", m.name, prev.file, prev.pos.line)
			continue
		}
		by_name[m.name] = m
		m.exposed = {.Window}
		if a, ok := attr_find(m.attrs, "Exposed"); ok { m.exposed = realms_of(api, a) }
		for a in m.attrs { if a.name != "Exposed" { diag(api, a.pos, "unknown module attribute [%s]", a.name) } }
	}
	for m in api.modules {
		if !m.partial { continue }
		target, ok := by_name[m.name]
		if !ok { diag(api, m.pos, "partial module %s: no module %s is declared", m.name, m.name); continue }
		if len(m.attrs) > 0 { diag(api, m.attrs[0].pos, "a partial module takes the attributes of module %s", m.name) }
		for d in m.decls { d.module = target }
		m.exposed = target.exposed
	}

	// type names are global
	for m in api.modules {
		for d in m.decls {
			if d.kind == .Function || d.kind == .Export { continue }
			if _, b := builtin(d.name); b { diag(api, d.pos, "%s is a built-in type", d.name); continue }
			if prev, dup := api.types[d.name]; dup {
				diag(api, d.pos, "duplicate type %s (first declared at %s:%d)", d.name, prev.pos.file, prev.pos.line)
				continue
			}
			api.types[d.name] = d
			if d.kind == .Callback { append(&api.callbacks, d) }
		}
	}
	if e, ok := api.types["Error"]; ok && e.kind == .Enum { api.error_enum = e }

	for m in api.modules {
		for d in m.decls {
			switch d.kind {
			case .Handle:   check_handle(api, d)
			case .Enum, .Flags: check_enum(api, d)
			case .Struct:   check_struct(api, d)
			case .Callback: check_signature(api, d)
			case .Export:   check_signature(api, d); append(&api.exports, d)
			case .Function: check_signature(api, d); append(&api.functions, d)
			}
		}
	}

	// import names are unique per module; implementation names are unique overall
	seen_import := make(map[string]^Decl, context.temp_allocator)
	seen_host := make(map[string]^Decl, context.temp_allocator)
	seen_export := make(map[string]^Decl, context.temp_allocator)
	for d in api.functions {
		for name in d.imports {
			key := strings.concatenate({d.module.name, ".", name}, context.temp_allocator)
			if prev, dup := seen_import[key]; dup {
				diag(api, d.pos, "duplicate import %s (first declared at %s:%d)", key, prev.pos.file, prev.pos.line)
				continue
			}
			seen_import[key] = d
		}
		if prev, dup := seen_host[d.host_name]; dup {
			diag(api, d.pos, "two functions are implemented by %s (the other at %s:%d): rename one or set [Host=...]", d.host_name, prev.pos.file, prev.pos.line)
		} else {
			seen_host[d.host_name] = d
		}
	}
	for d in api.exports {
		if prev, dup := seen_export[d.name]; dup { diag(api, d.pos, "duplicate export %s (first at %s:%d)", d.name, prev.pos.file, prev.pos.line) }
		seen_export[d.name] = d
	}
}

@(private)
realms_of :: proc(api: ^Api, a: Attr) -> (r: Realms) {
	if len(a.values) == 0 { diag(api, a.pos, "[Exposed] needs a value: Window, Worker or (Window,Worker)") }
	for v in a.values {
		realm, ok := realm_named(v)
		if !ok { diag(api, a.pos, "unknown realm %s in [Exposed] (Window or Worker)", v); continue }
		r += {realm}
	}
	return
}

@(private)
resolve :: proc(api: ^Api, t: ^Type) -> bool {
	if k, ok := builtin(t.name); ok {
		t.kind = k
		if t.arg != nil {
			diag(api, t.pos, "%s takes no type argument", t.name)
			return false
		}
	} else if d, found := api.types[t.name]; found {
		// Promise<T>: the handle of a promise, T documents what it settles with
		if t.arg != nil {
			if d.kind != .Handle || !handle_is(d, "Promise") { diag(api, t.pos, "%s takes no type argument", t.name); return false }
			if !resolve(api, t.arg) { return false }
		}
		t.decl = d
		switch d.kind {
		case .Handle:   t.kind = .Handle
		case .Enum:     t.kind = .Enum
		case .Flags:    t.kind = .Flags
		case .Struct:   t.kind = .Struct
		case .Callback: t.kind = .Callback
		case .Function, .Export: unreachable()
		}
	} else {
		diag(api, t.pos, "unknown type %s", t.name)
		return false
	}
	if t.seq {
		switch t.kind {
		case .I32, .U32, .I64, .U64, .F32, .F64, .Handle, .Promise:
		case .Unresolved, .Void, .Bool, .String, .Usv_String, .Bytes, .Enum, .Flags, .Struct, .Callback:
			diag(api, t.pos, "a sequence holds numbers or handles, not %s", t.name)
			return false
		}
	}
	return true
}

@(private)
is_integer :: proc(k: Type_Kind) -> bool { return k == .I32 || k == .U32 || k == .I64 || k == .U64 }

@(private)
check_handle :: proc(api: ^Api, d: ^Decl) {
	if d.parent != "" {
		p, ok := api.types[d.parent]
		if !ok || p.kind != .Handle { diag(api, d.pos, "handle %s: unknown parent handle %s", d.name, d.parent); return }
		d.parent_decl = p
		for q := p; q != nil; q = q.parent_decl {
			if q == d { diag(api, d.pos, "handle %s inherits from itself", d.name); d.parent_decl = nil; return }
		}
	}
}

@(private)
check_enum :: proc(api: ^Api, d: ^Decl) {
	if !resolve(api, &d.base) { return }
	if d.base.kind != .I32 && d.base.kind != .U32 { diag(api, d.base.pos, "%s %s: the base type is i32 or u32", d.kind == .Enum ? "enum" : "flags", d.name); return }
	if len(d.members) == 0 { diag(api, d.pos, "%s has no members", d.name) }
	names := make(map[string]bool, context.temp_allocator)
	values := make(map[i64]string, context.temp_allocator)
	next: i64
	lo, hi: i64 = d.base.kind == .I32 ? i64(min(i32)) : 0, d.base.kind == .I32 ? i64(max(i32)) : i64(max(u32))
	for &m, i in d.members {
		if names[m.name] { diag(api, m.pos, "duplicate member %s.%s", d.name, m.name) }
		names[m.name] = true
		if d.kind == .Flags {
			if m.has_value { diag(api, m.pos, "flags members are bits in order: %s.%s cannot have a value", d.name, m.name) }
			m.value = i64(i)
			if i >= 32 { diag(api, m.pos, "%s has more than 32 flags", d.name) }
			continue
		}
		if !m.has_value { m.value = next }
		if m.value < lo || m.value > hi { diag(api, m.pos, "%s.%s = %d does not fit in %s", d.name, m.name, m.value, d.base.name) }
		if other, dup := values[m.value]; dup { diag(api, m.pos, "%s.%s has the value of %s.%s (%d)", d.name, m.name, d.name, other, m.value) }
		values[m.value] = m.name
		next = m.value + 1
	}
}

@(private)
check_struct :: proc(api: ^Api, d: ^Decl) {
	if len(d.fields) == 0 { diag(api, d.pos, "struct %s has no fields", d.name) }
	names := make(map[string]bool, context.temp_allocator)
	for &f in d.fields {
		if names[f.name] { diag(api, f.pos, "duplicate field %s.%s", d.name, f.name) }
		names[f.name] = true
		if !resolve(api, &f.type) { continue }
		if f.type.seq || !is_scalar(f.type.kind) {
			diag(api, f.pos, "field %s.%s: a struct holds numbers, bools, enums, flags and handles only", d.name, f.name)
		}
	}
}

// Fits in one wasm value (no memory, no sequence): what struct fields and callback parameters may be.
is_scalar :: proc(k: Type_Kind) -> bool {
	#partial switch k {
	case .I32, .U32, .I64, .U64, .F32, .F64, .Bool, .Handle, .Promise, .Enum, .Flags: return true
	}
	return false
}

@(private)
check_literal :: proc(api: ^Api, p: ^Param) {
	v := p.default
	t := p.type
	if t.seq { diag(api, p.pos, "parameter %s: a sequence has no default", p.name); return }
	#partial switch t.kind {
	case .I32, .U32, .I64, .U64:
		if _, ok := strconv.parse_i64(v); !ok { diag(api, p.pos, "parameter %s: default %s is not an integer", p.name, v) }
	case .F32, .F64:
		if _, ok := strconv.parse_f64(v); !ok { diag(api, p.pos, "parameter %s: default %s is not a number", p.name, v) }
	case .Bool:
		if v != "true" && v != "false" { diag(api, p.pos, "parameter %s: default %s is not true or false", p.name, v) }
	case .String, .Usv_String:
		if !strings.has_prefix(v, "\"") { diag(api, p.pos, "parameter %s: default %s is not a string", p.name, v) }
	case .Enum:
		found := false
		for m in t.decl.members { if m.name == v { found = true } }
		if !found { diag(api, p.pos, "parameter %s: %s is not a member of %s", p.name, v, t.decl.name) }
	case .Flags, .Struct:
		if v != "none" { diag(api, p.pos, "parameter %s: the only default of flags or a struct is none (all zero)", p.name) }
	case .Handle, .Promise, .Callback:
		if v != "null" { diag(api, p.pos, "parameter %s: the only default of a handle or callback is null", p.name) }
	case:
		diag(api, p.pos, "parameter %s: a %s parameter has no default", p.name, t.name)
	}
}

@(private)
check_signature :: proc(api: ^Api, d: ^Decl) {
	names := make(map[string]bool, context.temp_allocator)
	ok := true
	for &p in d.params {
		if names[p.name] { diag(api, p.pos, "%s: duplicate parameter %s", d.name, p.name); ok = false }
		names[p.name] = true
		if p.name == "c" || p.name == "a" || p.name == "f" || strings.has_prefix(p.name, "_") {
			diag(api, p.pos, "%s: parameter name %s is reserved", d.name, p.name)
			ok = false
		}
		for a in p.attrs { diag(api, a.pos, "unknown parameter attribute [%s]", a.name) }
		if !resolve(api, &p.type) { ok = false; continue }
		k := p.type.kind
		if k == .Void { diag(api, p.pos, "%s: parameter %s cannot be void", d.name, p.name); ok = false }
		if p.out && (k != .Bytes || p.type.seq || p.optional) {
			diag(api, p.pos, "%s: only a bytes parameter can be out (a buffer the host fills)", d.name)
			ok = false
		}
		if p.optional {
			#partial switch k {
			case .String, .Usv_String, .Bytes, .Handle, .Promise, .Callback:
			case: diag(api, p.pos, "%s: parameter %s: only strings, bytes, handles and callbacks can be optional (give a default instead)", d.name, p.name); ok = false
			}
		}
		if p.default != "" { check_literal(api, &p) }
		if d.kind != .Function && !is_scalar(k) && !(d.kind == .Export && false) {
			diag(api, p.pos, "%s %s: parameter %s must be a number, bool, enum, flags or handle (it is passed in wasm values)", d.kind == .Callback ? "callback" : "export", d.name, p.name)
			ok = false
		}
		if k == .Struct && p.type.seq { ok = false }
	}
	if !resolve(api, &d.result) { ok = false }
	if d.result.seq { diag(api, d.result.pos, "%s: a sequence cannot be returned", d.name); ok = false }
	if d.result.kind == .Callback { diag(api, d.result.pos, "%s: a callback cannot be returned", d.name); ok = false }
	if d.kind != .Function {
		if d.raises { diag(api, d.pos, "%s: only functions raise", d.name) }
		if d.result.kind != .Void && !is_scalar(d.result.kind) { diag(api, d.result.pos, "%s: an export returns a number, bool, enum or handle", d.name); ok = false }
		for a in d.attrs { diag(api, a.pos, "unknown attribute [%s] on %s", a.name, d.name) }
		return
	}
	if d.raises && api.error_enum == nil { diag(api, d.pos, "%s raises, but no 'enum Error' declares the error codes", d.name) }

	// attributes
	d.exposed = d.module.exposed
	d.host_name = d.name
	for a in d.attrs {
		if !slice.contains(FUNCTION_ATTRS, a.name) { diag(api, a.pos, "unknown attribute [%s] on %s", a.name, d.name) }
	}
	if a, has := attr_find(d.attrs, "Exposed"); has { d.exposed = realms_of(api, a) }
	if _, has := attr_find(d.attrs, "Effects"); has { d.effects = true }
	if a, has := attr_find(d.attrs, "On"); has {
		if len(a.values) == 0 { diag(api, a.pos, "[On] lists the interfaces of %s", d.name) }
		list := make([dynamic]string)
		for iface in a.values { append(&list, strings.concatenate({iface, "_", d.name})) }
		d.imports = list[:]
		d.host_name = strings.concatenate({d.module.name, "_", d.name})
	} else {
		list := make([]string, 1)
		list[0] = d.name
		d.imports = list
	}
	if a, has := attr_find(d.attrs, "Host"); has {
		if len(a.values) != 1 { diag(api, a.pos, "[Host] names one procedure") } else { d.host_name = a.values[0] }
	}
	if ok { compute_abi(d) }
}

@(private)
abi_of_scalar :: proc(t: Type) -> Abi_Kind {
	#partial switch t.kind {
	case .I64, .U64, .Handle, .Promise: return .I64
	case .F32: return .F32
	case .F64: return .F64
	}
	return .I32
}

@(private)
compute_abi :: proc(d: ^Decl) {
	a := &d.abi
	for p in d.params {
		t := p.type
		switch {
		case t.seq, t.kind == .String, t.kind == .Usv_String, t.kind == .Bytes:
			append(&a.params, Abi_Kind.P, Abi_Kind.P)
		case t.kind == .Struct:
			for f in t.decl.fields { append(&a.params, abi_of_scalar(f.type)) }
		case:
			append(&a.params, abi_of_scalar(t))
		}
	}
	r := d.result
	switch {
	case r.kind == .Void:
		if d.raises { a.status = true; append(&a.results, Abi_Kind.I32) }
	case r.kind == .String || r.kind == .Usv_String || r.kind == .Bytes:
		a.out_string = true
		append(&a.params, Abi_Kind.P, Abi_Kind.P)
		append(&a.results, Abi_Kind.P)
	case r.kind == .Struct || d.raises:
		a.ret_ptr = true
		append(&a.params, Abi_Kind.P)
		if d.raises { a.status = true; append(&a.results, Abi_Kind.I32) }
	case:
		append(&a.results, abi_of_scalar(r))
	}
}

// Whether a handle is (or derives from) `name`.
handle_is :: proc(d: ^Decl, name: string) -> bool {
	for h := d; h != nil; h = h.parent_decl { if h.name == name { return true } }
	return false
}

// The handle that validates `d`: itself, or the nearest parent with a lookup.
handle_checker :: proc(d: ^Decl) -> ^Decl {
	for h := d; h != nil; h = h.parent_decl { if h.lookup != "" { return h } }
	return nil
}

// Bytes a value takes in guest memory (struct fields, sequences, return pointers): natural size, natural alignment.
mem_size :: proc(t: Type) -> int {
	#partial switch t.kind {
	case .Bool: return 1
	case .I32, .U32, .F32, .Enum, .Flags, .Callback: return 4
	case .I64, .U64, .F64, .Handle, .Promise: return 8
	case .Struct:
		size, _ := struct_layout(t.decl, nil)
		return size
	}
	return 0
}

mem_align :: proc(t: Type) -> int {
	if t.kind == .Struct {
		al := 1
		for f in t.decl.fields { al = max(al, mem_size(f.type)) }
		return al
	}
	return max(mem_size(t), 1)
}

// C layout of a struct: total size and each field's offset.
struct_layout :: proc(d: ^Decl, offsets: ^[dynamic]int) -> (size: int, align: int) {
	align = 1
	for f in d.fields {
		s := mem_size(f.type)
		size = (size + s - 1) / s * s
		if offsets != nil { append(offsets, size) }
		size += s
		align = max(align, s)
	}
	size = (size + align - 1) / align * align
	return
}
