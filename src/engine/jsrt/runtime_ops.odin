package jsrt

// Operations the interpreter needs that span the object and realm layers: global variable
// get/set, property access keyed by an atom (the get_field/put_field fast path), closure creation
// from a Function_Bytecode, and the Value-keyed set used by put_array_el.

// --- global variables ---
//
// Global `var`/`function` bindings and lexical globals live as properties of the realm global object.
// get_var throws a ReferenceError when the binding is absent (QuickJS's get_var vs get_var_undef).

global_get :: proc(ctx: ^Context, a: Atom, throw_if_missing: bool) -> Value {
	g := ctx.realm.global
	lk := object_get_own(g, a)
	if !lk.found {
		// Walk the prototype chain (the global's prototype is Object.prototype).
		v := object_get(ctx, g, a, mk_heap(.object, g))
		if !is_undefined(v) || object_has_property(ctx, g, a) {
			return v
		}
		value_free(ctx.rt, v)
		if throw_if_missing {
			name := atom_to_string(ctx.rt, a)
			defer string_unref(ctx.rt, name)
			u := string_to_utf8(ctx.rt, name, ctx.rt.allocator)
			defer delete(u, ctx.rt.allocator)
			return throw_type_errorf(ctx, "%s is not defined", u)
		}
		return UNDEFINED
	}
	return object_get(ctx, g, a, mk_heap(.object, g))
}

global_set :: proc(ctx: ^Context, a: Atom, val: Value) -> bool {
	g := ctx.realm.global
	return object_set(ctx, g, a, val, mk_heap(.object, g))
}

object_has_property :: proc(ctx: ^Context, obj: ^Object, a: Atom) -> bool {
	o := obj
	for o != nil {
		if object_get_own(o, a).found {return true}
		if _, handled := exotic_get_own(ctx, o, a, UNDEFINED); handled {return true}
		o = o.shape.proto
	}
	return false
}

// --- property access by atom (get_field / put_field) ---

object_get_value_by_atom :: proc(ctx: ^Context, obj: Value, a: Atom) -> Value {
	if obj.tag == .object {
		return object_get(ctx, as_object(obj), a, obj)
	}
	// Primitive receiver: box it, read, drop the box (String/Number/Boolean prototype methods).
	o := to_object(ctx, obj)
	if is_exception(o) {return o}
	res := object_get(ctx, as_object(o), a, obj)
	value_free(ctx.rt, o)
	return res
}

object_put_value_by_atom :: proc(ctx: ^Context, obj: Value, a: Atom, val: Value) -> bool {
	if obj.tag == .object {
		return object_set(ctx, as_object(obj), a, val, obj)
	}
	// Writing a property on a primitive silently fails in sloppy mode; the interpreter decides
	// strictness. We free the value and report success to keep sloppy code running.
	value_free(ctx.rt, val)
	return true
}

// --- Value-keyed set (put_array_el) ---

object_set_value :: proc(ctx: ^Context, obj: Value, key: Value, val: Value) -> bool {
	if obj.tag != .object {
		value_free(ctx.rt, val)
		return true
	}
	a, ok := value_to_atom(ctx, key)
	if !ok {value_free(ctx.rt, val); return false}
	return object_set(ctx, as_object(obj), a, val, obj)
}

// --- closures ---

// Build a closure object from a Function_Bytecode, capturing the current frame's upvalues per the
// bytecode's closure_vars table. Returns an owned function object Value.
make_closure :: proc(ctx: ^Context, f: ^Call_Frame, bc: ^Function_Bytecode) -> Value {
	rt := ctx.rt
	obj := object_new(rt, ctx.realm.function_proto)
	if obj == nil {return EXCEPTION}

	var_refs: []^Var_Ref
	if bc.closure_var_count > 0 {
		var_refs = make([]^Var_Ref, int(bc.closure_var_count), rt.allocator)
		for cv, i in bc.closure_vars {
			if cv.closure_type == 0 {
				// Capture a local of the current (parent) frame: get or create an open Var_Ref over
				// that local slot so the closure sees later writes until the frame returns.
				var_refs[i] = frame_capture_local(rt, f, cv.var_idx)
			} else {
				// Capture one of the parent's own upvalues.
				if f.var_refs != nil && int(cv.var_idx) < len(f.var_refs) {
					var_refs[i] = var_ref_ref(f.var_refs[cv.var_idx])
				}
			}
		}
	}

	obj.exotic = Function_Data{
		bc       = function_bc_ref(bc),
		var_refs = var_refs,
		home     = UNDEFINED,
		realm    = ctx.realm,
	}

	// A function has a "length" and "name" own property; set the common ones. "prototype" is created
	// lazily for ordinary functions.
	nlen := mk_number(f64(bc.defined_arg_count))
	object_define_own(ctx, obj, pa(.A_length), nlen, {.configurable})
	if bc.func_name != Atom(Predef_Atom.null_atom) {
		nm := mk_heap(.string, atom_to_string(rt, bc.func_name))
		object_define_own(ctx, obj, pa(.A_name), nm, {.configurable})
	}
	return mk_heap(.object, obj)
}

// Get or create the open Var_Ref boxing frame local `idx`, tracking it so the frame closes it on exit.
frame_capture_local :: proc(rt: ^Runtime, f: ^Call_Frame, idx: u32) -> ^Var_Ref {
	for vr in f.open_refs {
		if vr.pvalue == &f.locals[idx] {
			return var_ref_ref(vr)
		}
	}
	vr := var_ref_new(rt, &f.locals[idx])
	append(&f.open_refs, var_ref_ref(vr)) // the frame holds one reference
	return vr
}

// --- call opcode support ---
//
// The call opcodes leave [func, this?, arg0..argN] on the stack. do_call reads the function and
// arguments, invokes it, frees the consumed slots and pushes the result.

do_call :: proc(ctx: ^Context, f: ^Call_Frame, argc: int, this_override: Value, tail: bool) -> bool {
	rt := ctx.rt
	// Stack layout for OP_call: func, arg0 .. arg(argc-1).
	base := f.sp - argc
	func := f.stack[base - 1]
	args := f.stack[base:base + argc]
	res := call_function(ctx, func, this_override, args)
	// Free the function and arguments.
	for i in base ..< f.sp {value_free(rt, f.stack[i])}
	value_free(rt, func)
	f.sp = base - 1
	if is_exception(res) {return false}
	push(f, res)
	return true
}

// OP_call_method: this, func are both on the stack below the args (obj, func, args...). QuickJS pushes
// the receiver then the function; we read both.
do_call_method :: proc(ctx: ^Context, f: ^Call_Frame, argc: int, tail: bool) -> bool {
	rt := ctx.rt
	base := f.sp - argc
	func := f.stack[base - 1]
	this_val := f.stack[base - 2]
	args := f.stack[base:base + argc]
	res := call_function(ctx, func, this_val, args)
	for i in base ..< f.sp {value_free(rt, f.stack[i])}
	value_free(rt, func)
	value_free(rt, this_val)
	f.sp = base - 2
	if is_exception(res) {return false}
	push(f, res)
	return true
}

do_construct :: proc(ctx: ^Context, f: ^Call_Frame, argc: int) -> bool {
	rt := ctx.rt
	// OP_call_constructor: func, new.target, arg0.. ; new.target == func for a plain `new`.
	base := f.sp - argc
	new_target := f.stack[base - 1]
	func := f.stack[base - 2]
	args := f.stack[base:base + argc]
	res := construct(ctx, func, args, new_target)
	for i in base ..< f.sp {value_free(rt, f.stack[i])}
	value_free(rt, func)
	value_free(rt, new_target)
	f.sp = base - 2
	if is_exception(res) {return false}
	push(f, res)
	return true
}
