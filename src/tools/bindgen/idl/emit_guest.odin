package idl

import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:base"

// The Odin guest SDK (freestanding_wasm32, memory 0 32-bit): one file per module, one package per area of the API
// (a module, or the modules Guest_Config.packages groups); a type of another package is qualified and its package
// imported from the collection (`import "wren:core"`). Every function has a private raw import and a wrapper taking
// Odin values:
//   * strings and bytes are Odin slices; optional ones are Maybe(...); a sequence is a slice;
//   * a function that raises returns its Error last; a string result is copied into a caller buffer:
//       F(args, buf) -> (string, Error)          .Truncated when it did not fit (the part that fit is returned)
//       F_len(args) -> (int, Error)              the full length          (not for [Effects] functions)
//       F_alloc(args, allocator) -> (string, Error)  allocated to fit     (not for [Effects] functions)
//   * handles are distinct types; a parameter whose type has sub-types (Object, Node, EventTarget) takes any handle.

Guest_Config :: struct {
	package_name: string,            // every module in this one package; "" = one package per area (below)
	collection:   string,            // what the packages are imported from: "wren" for `import "wren:dom"`
	packages:     []Guest_Package,   // the packages holding several modules; any other module is a package of its name
}

Guest_Package :: struct {
	name:    string,
	modules: []string,
}

GUEST_TRUNCATED :: -1000

// The package a module's Odin code is in.
guest_package_of :: proc(cfg: Guest_Config, module: string) -> string {
	if cfg.package_name != "" { return cfg.package_name }
	for p in cfg.packages { for m in p.modules { if m == module { return p.name } } }
	return module
}

// Odin names (keywords and the builtins the wrappers call) a function cannot take.
@(private)
GUEST_RESERVED :: [?]string{
	"auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer", "distinct", "do",
	"dynamic", "else", "enum", "fallthrough", "false", "for", "foreign", "if", "import", "in", "map", "matrix", "nil",
	"not_in", "or_break", "or_continue", "or_else", "or_return", "package", "proc", "return", "struct", "switch",
	"transmute", "true", "typeid", "union", "using", "when", "where",
	"cap", "delete", "len", "make", "max", "min", "raw_data", "size_of", "string",
}

// The name a function has in its Odin package: the Web IDL name, without its interface prefix when the prefix
// repeats the package's name (fetch.Fetch_promise is fetch.promise; dom.Node_appendChild keeps the Node of one
// interface among several). The one place guest names are made: a case conversion would go here.
guest_name :: proc(pkg, name: string) -> string {
	i := strings.index_byte(name, '_')
	if i <= 0 || !base.ascii_equal_fold(name[:i], pkg) { return name }
	rest := name[i + 1:]
	if rest == "" || (rest[0] >= '0' && rest[0] <= '9') { return name }
	for r in GUEST_RESERVED { if rest == r { return name } }
	return rest
}

// The Odin names two declarations of one package would share (a prefix dropped onto another's name), as messages.
guest_name_clashes :: proc(api: ^Api, cfg: Guest_Config) -> []string {
	clashes := make([dynamic]string)
	seen := make(map[string]string, context.temp_allocator)   // "<package>.<name>" -> what has it
	claim :: proc(seen: ^map[string]string, clashes: ^[dynamic]string, pkg, name, what: string) {
		key := strings.concatenate({pkg, ".", name}, context.temp_allocator)
		if had, ok := seen[key]; ok { append(clashes, fmt.aprintf("%s is both %s and %s", key, had, what)); return }
		seen[key] = what
	}
	for _, d in api.types { claim(&seen, &clashes, guest_package_of(cfg, d.module.name), d.name, fmt.tprintf("type %s", d.name)) }
	for d in api.functions {
		pkg := guest_package_of(cfg, d.module.name)
		for i in d.imports { claim(&seen, &clashes, pkg, guest_name(pkg, i), fmt.tprintf("function %s", i)) }
	}
	return clashes[:]
}

// What writing one module's file needs: the package it is in and the other packages its code names.
@(private)
Guest_Emit :: struct {
	api:  ^Api,
	cfg:  Guest_Config,
	pkg:  string,
	uses: map[string]bool,
}

@(private)
has_children :: proc(api: ^Api, d: ^Decl) -> bool {
	for _, t in api.types { if t.kind == .Handle && t.parent_decl == d { return true } }
	return false
}

// A declared type's name, qualified when it is another package's (and that package then imported).
@(private)
guest_decl_name :: proc(g: ^Guest_Emit, d: ^Decl) -> string {
	pkg := guest_package_of(g.cfg, d.module.name)
	if pkg == g.pkg { return d.name }
	g.uses[pkg] = true
	return strings.concatenate({pkg, ".", d.name}, context.temp_allocator)
}

@(private)
guest_error :: proc(g: ^Guest_Emit) -> string { return guest_decl_name(g, g.api.error_enum) }

@(private)
guest_type :: proc(g: ^Guest_Emit, t: Type) -> string {
	s: string
	#partial switch t.kind {
	case .Void: s = ""
	case .I32: s = "i32"
	case .U32: s = "u32"
	case .I64: s = "i64"
	case .U64: s = "u64"
	case .F32: s = "f32"
	case .F64: s = "f64"
	case .Bool: s = "bool"
	case .String, .Usv_String: s = "string"
	case .Bytes: s = "[]u8"
	case .Handle, .Enum, .Flags, .Struct, .Callback: s = guest_decl_name(g, t.decl)
	}
	if t.seq { return strings.concatenate({"[]", s}, context.temp_allocator) }
	return s
}

// The parameter list of a raw import, and the arguments the wrapper passes to it.
@(private)
raw_params :: proc(g: ^Guest_Emit, d: ^Decl, decl, call: ^strings.Builder) {
	api := g.api
	sep := ""
	add :: proc(decl, call: ^strings.Builder, sep: ^string, name, type, arg: string) {
		fmt.sbprintf(decl, "%s%s: %s", sep^, name, type)
		fmt.sbprintf(call, "%s%s", sep^, arg)
		sep^ = ", "
	}
	for p in d.params {
		t := p.type
		n := p.name
		switch {
		case t.seq:
			el := guest_type(g, Type{kind = t.kind, decl = t.decl})
			add(decl, call, &sep, n, fmt.tprintf("[^]%s", el), fmt.tprintf("raw_data(%s)", n))
			add(decl, call, &sep, fmt.tprintf("%s_len", n), "u32", fmt.tprintf("u32(len(%s))", n))
		case t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes:
			if p.optional {
				add(decl, call, &sep, n, "[^]u8", fmt.tprintf("_%s_p", n))
				add(decl, call, &sep, fmt.tprintf("%s_len", n), "u32", fmt.tprintf("_%s_n", n))
			} else {
				add(decl, call, &sep, n, "[^]u8", fmt.tprintf("raw_data(%s)", n))
				add(decl, call, &sep, fmt.tprintf("%s_len", n), "u32", fmt.tprintf("u32(len(%s))", n))
			}
		case t.kind == .Struct:
			for f in t.decl.fields {
				add(decl, call, &sep, fmt.tprintf("%s_%s", n, f.name), raw_scalar(g, f.type), raw_arg(f.type, fmt.tprintf("%s.%s", n, f.name)))
			}
		case t.kind == .Handle && has_children(api, t.decl):
			add(decl, call, &sep, n, "u64", fmt.tprintf("u64(%s)", n))
		case:
			add(decl, call, &sep, n, raw_scalar(g, t), raw_arg(t, n))
		}
	}
	if d.abi.out_string {
		add(decl, call, &sep, "_buf", "[^]u8", "raw_data(buf)")
		add(decl, call, &sep, "_cap", "u32", "u32(len(buf))")
	}
	if d.abi.ret_ptr { add(decl, call, &sep, "_ret", fmt.tprintf("^%s", guest_type(g, d.result)), "&result") }
}

@(private)
raw_scalar :: proc(g: ^Guest_Emit, t: Type) -> string {
	#partial switch t.kind {
	case .Bool: return "i32"
	case .Flags: return t.decl.base.name
	}
	return guest_type(g, t)
}

@(private)
raw_arg :: proc(t: Type, v: string) -> string {
	#partial switch t.kind {
	case .Bool: return fmt.tprintf("i32(1 if %s else 0)", v)
	case .Flags: return fmt.tprintf("transmute(%s)%s", t.decl.base.name, v)
	}
	return v
}

@(private)
guest_param :: proc(g: ^Guest_Emit, p: Param, poly: ^bool) -> string {
	t := p.type
	if t.kind == .Handle && !t.seq && has_children(g.api, t.decl) {
		poly^ = true
		return fmt.tprintf("%s: $T_%s", p.name, p.name)
	}
	s := guest_type(g, t)
	if p.optional && (t.kind == .String || t.kind == .Usv_String || t.kind == .Bytes) { s = fmt.tprintf("Maybe(%s)", s) }
	def := ""
	if p.default != "" {
		#partial switch t.kind {
		case .Enum: def = fmt.tprintf(" = .%s", p.default)
		case .Flags, .Struct: def = " = {}"
		case .Handle, .Callback: def = " = nil" if t.kind == .Callback else " = 0"
		case: def = fmt.tprintf(" = %s", p.default)
		}
	} else if p.optional {
		#partial switch t.kind {
		case .Handle: def = " = 0"
		case .Callback: def = " = nil"
		case: def = " = nil"
		}
	}
	return fmt.tprintf("%s: %s%s", p.name, s, def)
}

emit_guest_module :: proc(api: ^Api, cfg: Guest_Config, m: ^Module) -> string {
	g := Guest_Emit{api = api, cfg = cfg, pkg = guest_package_of(cfg, m.name), uses = make(map[string]bool, context.temp_allocator)}
	body := emit_guest_body(&g, m)
	o := out_make()
	wl(&o, "// %s", GENERATED_BY)
	write_doc(&o, m.doc, "")
	wl(&o, "package %s", g.pkg)
	wl(&o, "")
	uses_runtime := false
	for d in api.functions { if d.module == m && d.abi.out_string && !d.effects { uses_runtime = true } }
	if uses_runtime { wl(&o, "import \"base:runtime\"") }
	uses_intrinsics := false
	for d in api.functions {
		if d.module != m { continue }
		for p in d.params { if p.type.kind == .Handle && !p.type.seq && has_children(api, p.type.decl) { uses_intrinsics = true } }
	}
	if uses_intrinsics { wl(&o, "import \"base:intrinsics\"") }
	pkgs := make([dynamic]string, context.temp_allocator)
	for p in g.uses { append(&pkgs, p) }
	slice.sort(pkgs[:])
	for p in pkgs { wl(&o, "import \"%s:%s\"", cfg.collection, p) }
	if uses_runtime || uses_intrinsics || len(pkgs) > 0 { wl(&o, "") }
	ws(&o, body)
	return out_text(&o)
}

// The types, raw imports and wrappers of a module (what comes after its imports, which this finds out).
@(private)
emit_guest_body :: proc(g: ^Guest_Emit, m: ^Module) -> string {
	api := g.api
	o := out_make()
	all_decls := make([dynamic]^Decl, context.temp_allocator)
	for mm in api.modules { if mm.name == m.name { append(&all_decls, ..mm.decls[:]) } }
	for d in all_decls {
		#partial switch d.kind {
		case .Handle:
			write_doc(&o, d.doc, "")
			if d.parent_decl != nil { wl(&o, "%s :: distinct %s", d.name, guest_decl_name(g, d.parent_decl)) } else { wl(&o, "%s :: distinct u64", d.name) }
			wl(&o, "")
		case .Enum:
			write_doc(&o, d.doc, "")
			wl(&o, "%s :: enum %s {{", d.name, d.base.name)
			for mb in d.members {
				write_doc(&o, mb.doc, "\t")
				wl(&o, "\t%s = %d,", mb.name, mb.value)
			}
			if d == api.error_enum {
				wl(&o, "\t// guest side only: a result did not fit in the buffer given (the part that fit was returned)")
				wl(&o, "\tTruncated = %d,", GUEST_TRUNCATED)
			}
			wl(&o, "}")
			wl(&o, "")
		case .Flags:
			write_doc(&o, d.doc, "")
			wl(&o, "%s_Flag :: enum %s {{", d.name, d.base.name)
			for mb in d.members {
				write_doc(&o, mb.doc, "\t")
				wl(&o, "\t%s = %d,", mb.name, mb.value)
			}
			wl(&o, "}")
			wl(&o, "%s :: bit_set[%s_Flag; %s]", d.name, d.name, d.base.name)
			wl(&o, "")
		case .Struct:
			write_doc(&o, d.doc, "")
			wl(&o, "%s :: struct {{", d.name)
			for f in d.fields {
				write_doc(&o, f.doc, "\t")
				wl(&o, "\t%s: %s,", f.name, guest_type(g, f.type))
			}
			wl(&o, "}")
			wl(&o, "")
		case .Callback:
			write_doc(&o, d.doc, "")
			w(&o, "%s :: #type proc \"contextless\" (", d.name)
			for p, i in d.params { w(&o, "%s%s: %s", i > 0 ? ", " : "", p.name, guest_type(g, p.type)) }
			wl(&o, ")")
			wl(&o, "")
		case .Export:
			// a comment: the types it names are no reason to import their packages
			c := Guest_Emit{api = api, cfg = g.cfg, pkg = g.pkg, uses = make(map[string]bool, context.temp_allocator)}
			write_doc(&o, d.doc, "")
			w(&o, "// Export expected from the guest: @(export) %s :: proc \"contextless\" (", d.name)
			for p, i in d.params { w(&o, "%s%s: %s", i > 0 ? ", " : "", p.name, guest_type(&c, p.type)) }
			r := guest_type(&c, d.result)
			if r != "" { wl(&o, ") -> %s", r) } else { wl(&o, ")") }
			wl(&o, "")
		}
	}

	// raw imports
	has_fn := false
	for d in api.functions { if d.module == m { has_fn = true } }
	if !has_fn { return out_text(&o) }
	wl(&o, "foreign import _m_%s %s", m.name, base.json_quote(m.name))
	wl(&o, "")
	wl(&o, "@(private = \"file\", default_calling_convention = \"contextless\")")
	wl(&o, "foreign _m_%s {{", m.name)
	for d in api.functions {
		if d.module != m { continue }
		decl := strings.builder_make(context.temp_allocator)
		call := strings.builder_make(context.temp_allocator)
		raw_params(g, d, &decl, &call)
		res := ""
		switch {
		case d.abi.status: res = fmt.tprintf(" -> %s", guest_error(g))
		case d.abi.out_string: res = " -> i32"
		case d.abi.ret_ptr:
		case d.result.kind != .Void: res = fmt.tprintf(" -> %s", raw_scalar(g, d.result))
		}
		wl(&o, "\t@(link_name = %s) _%s :: proc(%s)%s ---", base.json_quote(d.imports[0]), d.host_name, strings.to_string(decl), res)
	}
	wl(&o, "}")
	wl(&o, "")

	for d in api.functions {
		if d.module != m { continue }
		emit_guest_wrapper(g, &o, d)
	}
	return out_text(&o)
}

@(private)
emit_guest_wrapper :: proc(g: ^Guest_Emit, o: ^Out, d: ^Decl) {
	api := g.api
	name := guest_name(g.pkg, d.imports[0])
	err := guest_error(g) if d.abi.out_string || d.abi.status || d.raises else ""   // named (and imported) when used only
	decl := strings.builder_make(context.temp_allocator)
	call := strings.builder_make(context.temp_allocator)
	raw_params(g, d, &decl, &call)
	params := strings.builder_make(context.temp_allocator)
	poly := false
	for p, i in d.params {
		if i > 0 { strings.write_string(&params, ", ") }
		strings.write_string(&params, guest_param(g, p, &poly))
	}
	where_clause := strings.builder_make(context.temp_allocator)
	for p in d.params {
		if p.type.kind == .Handle && !p.type.seq && has_children(api, p.type.decl) {
			fmt.sbprintf(&where_clause, "%s intrinsics.type_is_integer(intrinsics.type_core_type(T_%s)) && size_of(T_%s) == 8", strings.builder_len(where_clause) == 0 ? " where" : " &&", p.name, p.name)
		}
	}
	prelude := strings.builder_make(context.temp_allocator)
	for p in d.params {
		if !p.optional { continue }
		k := p.type.kind
		if k != .String && k != .Usv_String && k != .Bytes { continue }
		fmt.sbprintf(&prelude, "\t_%s_p: [^]u8\n\t_%s_n := max(u32)\n", p.name, p.name)
		if k == .Bytes {
			fmt.sbprintf(&prelude, "\tif v, ok := %s.?; ok {{ _%s_p, _%s_n = raw_data(v), u32(len(v)) }}\n", p.name, p.name, p.name)
		} else {
			fmt.sbprintf(&prelude, "\tif v, ok := %s.?; ok {{ _%s_p, _%s_n = raw_data(v), u32(len(v)) }}\n", p.name, p.name, p.name)
		}
	}
	write_doc(o, d.doc, "")
	if len(d.imports) > 1 { wl(o, "// Also imported as %s.", strings.join(d.imports[1:], ", ", context.temp_allocator)) }
	ps := strings.to_string(params)
	args := strings.to_string(call)
	wc := strings.to_string(where_clause)
	pre := strings.to_string(prelude)
	r := guest_type(g, d.result)

	if d.abi.out_string {
		bufp := len(ps) > 0 ? fmt.tprintf("%s, buf: []u8", ps) : "buf: []u8"
		is_bytes := d.result.kind == .Bytes
		rt := is_bytes ? "[]u8" : "string"
		conv := is_bytes ? "" : "string"   // a bytes result is the buffer itself
		wl(o, "%s :: proc \"contextless\" (%s) -> (%s, %s)%s {{", name, bufp, rt, err, wc)
		ws(o, pre)
		wl(o, "\tn := _%s(%s)", d.host_name, args)
		wl(o, "\tif n < 0 {{ return {{}}, %s(n) }}", err)
		wl(o, "\tif int(n) > len(buf) {{ return %s(buf), .Truncated }}", conv)
		wl(o, "\treturn %s(buf[:n]), .None", conv)
		wl(o, "}")
		wl(o, "")
		if !d.effects {
			nobuf, _ := strings.replace_all(args, "raw_data(buf), u32(len(buf))", "nil, 0", context.temp_allocator)
			wl(o, "// The full length of %s's result.", name)
			wl(o, "%s_len :: proc \"contextless\" (%s) -> (int, %s)%s {{", name, ps, err, wc)
			ws(o, pre)
			wl(o, "\tn := _%s(%s)", d.host_name, nobuf)
			wl(o, "\tif n < 0 {{ return 0, %s(n) }}", err)
			wl(o, "\treturn int(n), .None")
			wl(o, "}")
			wl(o, "")
			allocp := len(ps) > 0 ? fmt.tprintf("%s, allocator: runtime.Allocator", ps) : "allocator: runtime.Allocator"
			wl(o, "// %s's result in a buffer allocated to fit.", name)
			wl(o, "%s_alloc :: proc(%s) -> (%s, %s)%s {{", name, allocp, rt, err, wc)
			ws(o, pre)
			wl(o, "\tcap := 64")
			wl(o, "\tfor _ in 0 ..< 4 {{")
			wl(o, "\t\tbuf := make([]u8, cap, allocator)")
			wl(o, "\t\tn := _%s(%s)", d.host_name, args)
			wl(o, "\t\tif n < 0 {{ delete(buf, allocator); return {{}}, %s(n) }}", err)
			wl(o, "\t\tif int(n) <= cap {{ return %s(buf[:n]), .None }}", conv)
			wl(o, "\t\tdelete(buf, allocator)")
			wl(o, "\t\tcap = int(n)")
			wl(o, "\t}")
			wl(o, "\treturn {{}}, .Truncated")
			wl(o, "}")
			wl(o, "")
		}
		alias_wrappers(g, o, d, true)
		return
	}

	switch {
	case d.abi.ret_ptr && d.raises:
		wl(o, "%s :: proc \"contextless\" (%s) -> (result: %s, err: %s)%s {{", name, ps, r, err, wc)
		ws(o, pre)
		wl(o, "\terr = _%s(%s)", d.host_name, args)
		wl(o, "\treturn")
	case d.abi.ret_ptr:
		wl(o, "%s :: proc \"contextless\" (%s) -> (result: %s)%s {{", name, ps, r, wc)
		ws(o, pre)
		wl(o, "\t_%s(%s)", d.host_name, args)
		wl(o, "\treturn")
	case d.abi.status:
		wl(o, "%s :: proc \"contextless\" (%s) -> %s%s {{", name, ps, err, wc)
		ws(o, pre)
		wl(o, "\treturn _%s(%s)", d.host_name, args)
	case r == "":
		wl(o, "%s :: proc \"contextless\" (%s)%s {{", name, ps, wc)
		ws(o, pre)
		wl(o, "\t_%s(%s)", d.host_name, args)
	case d.result.kind == .Bool:
		wl(o, "%s :: proc \"contextless\" (%s) -> bool%s {{", name, ps, wc)
		ws(o, pre)
		wl(o, "\treturn _%s(%s) != 0", d.host_name, args)
	case d.result.kind == .Flags:
		wl(o, "%s :: proc \"contextless\" (%s) -> %s%s {{", name, ps, r, wc)
		ws(o, pre)
		wl(o, "\treturn transmute(%s)_%s(%s)", r, d.host_name, args)
	case:
		wl(o, "%s :: proc \"contextless\" (%s) -> %s%s {{", name, ps, r, wc)
		ws(o, pre)
		wl(o, "\treturn _%s(%s)", d.host_name, args)
	}
	wl(o, "}")
	wl(o, "")
	alias_wrappers(g, o, d, false)
}

@(private)
alias_wrappers :: proc(g: ^Guest_Emit, o: ^Out, d: ^Decl, with_len: bool) {
	name := guest_name(g.pkg, d.imports[0])
	for import_name in d.imports[1:] {
		alias := guest_name(g.pkg, import_name)
		wl(o, "%s :: %s", alias, name)
		if with_len && !d.effects {
			wl(o, "%s_len :: %s_len", alias, name)
			wl(o, "%s_alloc :: %s_alloc", alias, name)
		}
	}
	if len(d.imports) > 1 { wl(o, "") }
}
