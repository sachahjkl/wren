package jsrt

// Error objects and the throw helpers used across the engine.

import "core:strings"

// Concatenate message parts in scratch memory.
cat :: proc(ctx: ^Context, parts: ..string) -> string {
	return strings.concatenate(parts, tmp(ctx.rt))
}

error_proto_for :: proc(ctx: ^Context, kind: Error_Kind) -> ^Object {
	if kind == .plain {return ctx.class_proto[.error]}
	return ctx.native_error_proto[kind]
}

// A new error object of `kind` with `msg` as its message (and a stack trace).
make_error :: proc(ctx: ^Context, kind: Error_Kind, msg: string) -> Value {
	o := object_new_proto(ctx, error_proto_for(ctx, kind), .error)
	define_value(ctx, o, pa(.A_message), new_string(ctx, msg), CW)
	error_add_stack(ctx, o)
	return mk_obj(o)
}

throw_error :: proc(ctx: ^Context, kind: Error_Kind, msg: string) -> Value {
	if ctx.rt.uncatchable {return EXCEPTION}
	return throw(ctx, make_error(ctx, kind, msg))
}

throw_type_error :: proc(ctx: ^Context, msg: string) -> Value {return throw_error(ctx, .type, msg)}
throw_range_error :: proc(ctx: ^Context, msg: string) -> Value {return throw_error(ctx, .range, msg)}
throw_reference_error :: proc(ctx: ^Context, msg: string) -> Value {return throw_error(ctx, .reference, msg)}
throw_syntax_error :: proc(ctx: ^Context, msg: string) -> Value {return throw_error(ctx, .syntax, msg)}
throw_internal_error :: proc(ctx: ^Context, msg: string) -> Value {return throw_error(ctx, .internal, msg)}

throw_reference_error_uninit :: proc(ctx: ^Context, a: Atom) -> Value {
	name := a == ATOM_NULL ? "lexical variable" : atom_utf8(ctx.rt, a)
	return throw_reference_error(ctx, cat(ctx, name, " is not initialized"))
}

throw_not_defined :: proc(ctx: ^Context, a: Atom) -> Value {
	return throw_reference_error(ctx, cat(ctx, atom_utf8(ctx.rt, a), " is not defined"))
}

throw_not_a_function :: proc(ctx: ^Context) -> Value {
	return throw_type_error(ctx, "not a function")
}

throw_not_object :: proc(ctx: ^Context) -> Value {
	return throw_type_error(ctx, "not an object")
}

// A best-effort "stack" property: function names and file:line of the active frames.
error_add_stack :: proc(ctx: ^Context, o: ^Object) {
	rt := ctx.rt
	sb := sb_init(rt, 64)
	n := 0
	for f := rt.cur_frame; f != nil && n < 32; f = f.prev {
		if f.bc == nil {continue}
		sb_ascii(&sb, "    at ")
		name := f.bc.func_name
		if name == ATOM_NULL || name == pa(.A_empty_string) {
			sb_ascii(&sb, "<anonymous>")
		} else {
			sb_str(&sb, atom_to_string(rt, name))
		}
		if f.bc.filename != ATOM_NULL {
			sb_ascii(&sb, " (")
			sb_str(&sb, atom_to_string(rt, f.bc.filename))
			line, col := pc_to_pos(f.bc, f.pc)
			if line > 0 {
				sb_ascii(&sb, ":")
				sb_str(&sb, str_from_u64(rt, u64(line)))
				if col > 0 {
					sb_ascii(&sb, ":")
					sb_str(&sb, str_from_u64(rt, u64(col)))
				}
			}
			sb_ascii(&sb, ")")
		}
		sb_ascii(&sb, "\n")
		n += 1
	}
	s := sb_finish(&sb)
	if o.class == .error {
		// [[ErrorData]]: read through the Error.prototype.stack accessor
		o.data = Prim_Data{mk_str(s)}
	} else {
		define_value(ctx, o, pa(.A_stack), mk_str(s), CW)
	}
}

error_stack_get :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_not_object(ctx)}
	o := as_obj(this)
	if o.class != .error {return UNDEFINED}
	if pd, ok := o.data.(Prim_Data); ok {return pd.v}
	return UNDEFINED
}

error_stack_set :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_not_object(ctx)}
	v := arg(args, 0)
	if v.tag != .string {return throw_type_error(ctx, "Error.prototype.stack setter expects a string")}
	o := as_obj(this)
	if o == ctx.class_proto[.error] {return throw_type_error(ctx, "Error.prototype.stack setter called on the home object")}
	d: Prop_Desc
	r := get_own_property(ctx, o, pa(.A_stack), &d)
	if r < 0 {return EXCEPTION}
	if r == 0 {
		if define_own_property(ctx, o, pa(.A_stack), data_desc(v, CWE), true) < 0 {return EXCEPTION}
	} else if set_property(ctx, this, pa(.A_stack), v, this, true) < 0 {
		return EXCEPTION
	}
	return UNDEFINED
}
