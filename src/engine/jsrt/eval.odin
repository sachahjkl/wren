package jsrt

// Running source text: scripts, eval (direct and indirect), the Function constructors and module
// sources all go through the host's compiler hook (the Odin front-end, or the reference compiler in
// the test judge), which returns a function-bytecode or module record value.

compile :: proc(ctx: ^Context, req: ^Compile_Request) -> Value {
	rt := ctx.rt
	req.user = rt.config.compile_user
	compile_proc := rt.config.compile != nil ? rt.config.compile : frontend_compile
	rt.gc_disabled += 1
	v := compile_proc(ctx, req)
	rt.gc_disabled -= 1
	if is_exception(v) {return EXCEPTION}
	if v.tag != .function_bc && v.tag != .module {return throw_internal_error(ctx, "compiler returned an invalid value")}
	root(rt, v)
	return v
}

// Evaluate a global script in the context's realm; returns its completion value.
eval_script :: proc(ctx: ^Context, source: string, filename: string, strict := false) -> Value {
	req := Compile_Request{kind = .script, source = source, filename = filename, strict = strict}
	fb := compile(ctx, &req)
	if is_exception(fb) {return EXCEPTION}
	return run_function_bc(ctx, fb)
}

// Run a top-level function bytecode (a compiled script) with `this` = the global object.
run_function_bc :: proc(ctx: ^Context, fb: Value) -> Value {
	b := cast(^Function_Bytecode)fb.u.ptr
	f := make_toplevel_function(ctx, b)
	root(ctx.rt, f)
	return call(ctx, f, mk_obj(ctx.global_obj), {})
}

eval_direct :: proc(ctx: ^Context, f: ^Frame, var_refs: [^]^Var_Ref, x: Value, scope_idx: int) -> Value {
	if x.tag != .string {return x}
	rt := ctx.rt
	if rt.config.compile_strings != nil && !rt.config.compile_strings(ctx, x, true, rt.config.compile_strings_user) {return EXCEPTION}
	src := str_to_utf8(rt, as_str(x), tmp(rt), true)
	req := Compile_Request{kind = .eval_direct, source = src, filename = "<input>", strict = f.bc.is_strict_mode, parent = f.bc, scope_idx = scope_idx}
	fb := compile(ctx, &req)
	if is_exception(fb) {return EXCEPTION}
	b := cast(^Function_Bytecode)fb.u.ptr
	o := object_new_proto(ctx, ctx.function_proto, .bytecode_function)
	closure_bind(ctx, o, b, var_refs, f)
	root(rt, mk_obj(o))
	return call(ctx, mk_obj(o), UNDEFINED, {})
}

// %eval% (indirect eval).
eval_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	x := arg(args, 0)
	if x.tag != .string {return x}
	rt := ctx.rt
	if rt.config.compile_strings != nil && !rt.config.compile_strings(ctx, x, false, rt.config.compile_strings_user) {return EXCEPTION}
	src := str_to_utf8(rt, as_str(x), tmp(rt), true)
	req := Compile_Request{kind = .eval_indirect, source = src, filename = "<input>"}
	fb := compile(ctx, &req)
	if is_exception(fb) {return EXCEPTION}
	return run_function_bc(ctx, fb)
}

// Function / GeneratorFunction / AsyncFunction / AsyncGeneratorFunction constructors (magic = kind).
function_ctor_fn :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	sb := sb_init(rt, 64)
	switch Func_Kind(magic) {
	case .normal: sb_ascii(&sb, "(function")
	case .generator: sb_ascii(&sb, "(function*")
	case .async: sb_ascii(&sb, "(async function")
	case .async_generator: sb_ascii(&sb, "(async function*")
	}
	sb_ascii(&sb, " anonymous(")
	n := len(args)
	for i in 0 ..< max(n - 1, 0) {
		if i > 0 {sb_ascii(&sb, ",")}
		s := to_str(ctx, args[i])
		if s == nil {sb_destroy(&sb); return EXCEPTION}
		sb_str(&sb, s)
	}
	sb_ascii(&sb, "\n) {\n")
	if n > 0 {
		s := to_str(ctx, args[n - 1])
		if s == nil {sb_destroy(&sb); return EXCEPTION}
		sb_str(&sb, s)
	}
	sb_ascii(&sb, "\n})")
	if sb.overflow {sb_destroy(&sb); return throw_range_error(ctx, "invalid string length")}
	text := sb_finish(&sb)
	if rt.config.compile_strings != nil && !rt.config.compile_strings(ctx, mk_str(text), false, rt.config.compile_strings_user) {return EXCEPTION}
	req := Compile_Request{kind = .function_ctor, source = str_to_utf8(rt, text, tmp(rt), true), filename = "<input>"}
	fb := compile(ctx, &req)
	if is_exception(fb) {return EXCEPTION}
	fv := run_function_bc(ctx, fb)
	if is_exception(fv) {return EXCEPTION}
	if !is_undefined(nt) && fv.tag == .object {
		// the prototype comes from new.target (GetPrototypeFromConstructor)
		kinds := [4]Class_ID{.object, .generator_function, .async_function, .async_generator_function}
		_ = kinds
		fallback := function_proto_for_kind(ctx, Func_Kind(magic))
		p := get(ctx, nt, pa(.A_prototype))
		if is_exception(p) {return EXCEPTION}
		proto := p.tag == .object ? as_obj(p) : fallback
		if p.tag != .object {
			realm := function_realm(ctx, nt)
			if realm == nil {return EXCEPTION}
			proto = function_proto_for_kind(realm, Func_Kind(magic))
		}
		set_object_proto(rt, as_obj(fv), proto)
	}
	return fv
}
