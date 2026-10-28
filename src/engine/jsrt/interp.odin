package jsrt

// The bytecode interpreter: a `switch` loop over the QuickJS-ng 0.17 instruction set, following the
// stack effects of quickjs-opcode.h opcode by opcode (JS_CallInternal).
//
// The operand stack pointer and pc live in locals; the collector traces a frame's whole stack area
// (gc.odin), so they never need publishing before a call. try/catch uses QuickJS's discipline: `catch`
// pushes a catch-offset marker, and an exception unwinds the operand stack to the nearest marker
// (offset 0 marks a for-of iterator to close). Coroutine frames (generators, async functions) return
// to their driver with the kind of suspension.

Exit_Kind :: enum u8 {
	ret,           // normal function return: the Value is the result
	exception,     // the Value is EXCEPTION
	coro_return,   // a coroutine finished: its result is at stack[sp-1]
	initial_yield, // a generator reached OP_initial_yield
	yield,
	yield_star,
	await,
}

@(private = "file")
rd_u16 :: #force_inline proc "contextless" (c: []u8, p: int) -> int {
	return int(c[p]) | int(c[p + 1]) << 8
}

@(private = "file")
rd_u32 :: #force_inline proc "contextless" (c: []u8, p: int) -> u32 {
	return u32(c[p]) | u32(c[p + 1]) << 8 | u32(c[p + 2]) << 16 | u32(c[p + 3]) << 24
}

@(private = "file")
rd_i32 :: #force_inline proc "contextless" (c: []u8, p: int) -> int {
	return int(i32(rd_u32(c, p)))
}

// JS_PROP_* bits as the compiler encodes them in define_var/define_func flags.
QJS_PROP_CONFIGURABLE :: 1
QJS_PROP_WRITABLE :: 2
QJS_PROP_ENUMERABLE :: 4
DEFINE_GLOBAL_LEX_VAR :: 1 << 7
DEFINE_GLOBAL_FUNC_VAR :: 1 << 6

Special_Object :: enum u8 {
	arguments,
	mapped_arguments,
	this_func,
	new_target,
	home_object,
	var_object,
	import_meta,
	null_proto,
}

interp_run :: proc(ctx: ^Context, f: ^Frame, var_refs: [^]^Var_Ref) -> (Value, Exit_Kind) {
	rt := ctx.rt
	b := f.bc
	code := b.code
	stack := f.stack[:max(int(b.stack_size), 1)]
	locals := f.locals
	args := f.args
	sp := f.sp
	pc := f.pc
	root_base := temp_mark(rt)
	strict := b.is_strict_mode
	is_coro := b.func_kind != .normal
	ret_val: Value
	caller_ctx := f.caller_ctx != nil ? f.caller_ctx : ctx

	// a coroutine resumed with throw() enters straight into the unwinder with the exception pending
	exc := f.pending_throw
	f.pending_throw = false
	if !exc && pc == 0 && !gc_safepoint(ctx) {return EXCEPTION, .exception}

	for {
		if !exc {
			op := Opcode(code[pc])
			pc += 1
			#partial switch op {
			case .push_i32:
				stack[sp] = mk_int(i32(rd_u32(code, pc)))
				sp += 1
				pc += 4
			case .push_bigint_i32:
				stack[sp] = bigint_from_i64(ctx, i64(i32(rd_u32(code, pc))))
				sp += 1
				pc += 4
			case .push_const:
				stack[sp] = b.cpool[rd_u32(code, pc)]
				sp += 1
				pc += 4
			case .push_const8:
				stack[sp] = b.cpool[code[pc]]
				sp += 1
				pc += 1
			case .fclosure:
				fb := cast(^Function_Bytecode)b.cpool[rd_u32(code, pc)].u.ptr
				pc += 4
				stack[sp] = make_closure(ctx, fb, var_refs, f)
				sp += 1
			case .fclosure8:
				fb := cast(^Function_Bytecode)b.cpool[code[pc]].u.ptr
				pc += 1
				stack[sp] = make_closure(ctx, fb, var_refs, f)
				sp += 1
			case .push_minus1, .push_0, .push_1, .push_2, .push_3, .push_4, .push_5, .push_6, .push_7:
				stack[sp] = mk_int(i32(op) - i32(Opcode.push_0))
				sp += 1
			case .push_i8:
				stack[sp] = mk_int(i32(i8(code[pc])))
				sp += 1
				pc += 1
			case .push_i16:
				stack[sp] = mk_int(i32(i16(u16(rd_u16(code, pc)))))
				sp += 1
				pc += 2
			case .push_empty_string:
				stack[sp] = mk_str(rt.empty_string)
				sp += 1
			case .push_atom_value:
				stack[sp] = atom_to_value(rt, Atom(rd_u32(code, pc)))
				sp += 1
				pc += 4
			case .private_symbol:
				a := Atom(rd_u32(code, pc))
				pc += 4
				stack[sp] = mk_sym(symbol_new_raw(rt, mk_str(atom_to_string(rt, a)), true))
				sp += 1
			case .undefined:
				stack[sp] = UNDEFINED
				sp += 1
			case .null:
				stack[sp] = NULL
				sp += 1
			case .push_false:
				stack[sp] = FALSE
				sp += 1
			case .push_true:
				stack[sp] = TRUE
				sp += 1
			case .push_this:
				t := f.this_val
				if !strict {
					if is_nullish(t) {
						t = mk_obj(ctx.global_obj)
					} else if t.tag != .object {
						t = to_object(ctx, t)
						if is_exception(t) {exc = true; break}
					}
				}
				stack[sp] = t
				sp += 1
			case .object:
				stack[sp] = mk_obj(new_plain_object(ctx))
				sp += 1
			case .special_object:
				kind := Special_Object(code[pc])
				pc += 1
				switch kind {
				case .arguments:
					stack[sp] = build_arguments(ctx, args[:f.argc])
				case .mapped_arguments:
					stack[sp] = build_mapped_arguments(ctx, f, min(f.argc, int(b.arg_count)))
				case .this_func:
					stack[sp] = f.func
				case .new_target:
					stack[sp] = f.new_target
				case .home_object:
					fd := as_obj(f.func).data.(Func_Data)
					stack[sp] = fd.home != nil ? mk_obj(fd.home) : UNDEFINED
				case .var_object:
					stack[sp] = mk_obj(object_new_proto(ctx, nil))
				case .import_meta:
					v := import_meta_for(ctx, f)
					if is_exception(v) {exc = true; break}
					stack[sp] = v
				case .null_proto:
					stack[sp] = mk_obj(object_new_proto(ctx, nil))
				}
				if !exc {sp += 1}
			case .rest:
				first := rd_u16(code, pc)
				pc += 2
				i := min(first, f.argc)
				stack[sp] = mk_obj(array_from_values(ctx, args[i:f.argc]))
				sp += 1

			// --- stack manipulation ---
			case .drop:
				sp -= 1
			case .nip:
				stack[sp - 2] = stack[sp - 1]
				sp -= 1
			case .nip1:
				stack[sp - 3] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 1]
				sp -= 1
			case .dup:
				stack[sp] = stack[sp - 1]
				sp += 1
			case .dup1:
				stack[sp] = stack[sp - 1]
				stack[sp - 1] = stack[sp - 2]
				sp += 1
			case .dup2:
				stack[sp] = stack[sp - 2]
				stack[sp + 1] = stack[sp - 1]
				sp += 2
			case .dup3:
				stack[sp] = stack[sp - 3]
				stack[sp + 1] = stack[sp - 2]
				stack[sp + 2] = stack[sp - 1]
				sp += 3
			case .insert2:
				stack[sp] = stack[sp - 1]
				stack[sp - 1] = stack[sp - 2]
				stack[sp - 2] = stack[sp]
				sp += 1
			case .insert3:
				stack[sp] = stack[sp - 1]
				stack[sp - 1] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 3]
				stack[sp - 3] = stack[sp]
				sp += 1
			case .insert4:
				stack[sp] = stack[sp - 1]
				stack[sp - 1] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 3]
				stack[sp - 3] = stack[sp - 4]
				stack[sp - 4] = stack[sp]
				sp += 1
			case .perm3:
				stack[sp - 2], stack[sp - 3] = stack[sp - 3], stack[sp - 2]
			case .rot3l:
				t := stack[sp - 3]
				stack[sp - 3] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 1]
				stack[sp - 1] = t
			case .rot4l:
				t := stack[sp - 4]
				stack[sp - 4] = stack[sp - 3]
				stack[sp - 3] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 1]
				stack[sp - 1] = t
			case .rot5l:
				t := stack[sp - 5]
				stack[sp - 5] = stack[sp - 4]
				stack[sp - 4] = stack[sp - 3]
				stack[sp - 3] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 1]
				stack[sp - 1] = t
			case .rot3r:
				t := stack[sp - 1]
				stack[sp - 1] = stack[sp - 2]
				stack[sp - 2] = stack[sp - 3]
				stack[sp - 3] = t
			case .perm4:
				t := stack[sp - 2]
				stack[sp - 2] = stack[sp - 3]
				stack[sp - 3] = stack[sp - 4]
				stack[sp - 4] = t
			case .perm5:
				t := stack[sp - 2]
				stack[sp - 2] = stack[sp - 3]
				stack[sp - 3] = stack[sp - 4]
				stack[sp - 4] = stack[sp - 5]
				stack[sp - 5] = t
			case .swap:
				stack[sp - 2], stack[sp - 1] = stack[sp - 1], stack[sp - 2]
			case .swap2:
				t1, t2 := stack[sp - 4], stack[sp - 3]
				stack[sp - 4] = stack[sp - 2]
				stack[sp - 3] = stack[sp - 1]
				stack[sp - 2] = t1
				stack[sp - 1] = t2

			// --- calls ---
			case .call0, .call1, .call2, .call3, .call, .tail_call:
				argc: int
				if op == .call || op == .tail_call {
					argc = rd_u16(code, pc)
					pc += 2
				} else {
					argc = int(op) - int(Opcode.call0)
				}
				f.pc = pc
				base := sp - argc
				r := call_internal(ctx, stack[base - 1], UNDEFINED, UNDEFINED, stack[base:sp], false)
				if is_exception(r) {exc = true; break}
				if op == .tail_call {ret_val = r; return finish(f, rt, ret_val, root_base)}
				sp = base - 1
				stack[sp] = r
				sp += 1
			case .call_method, .tail_call_method:
				argc := rd_u16(code, pc)
				pc += 2
				f.pc = pc
				base := sp - argc
				r := call_internal(ctx, stack[base - 1], stack[base - 2], UNDEFINED, stack[base:sp], false)
				if is_exception(r) {exc = true; break}
				if op == .tail_call_method {ret_val = r; return finish(f, rt, ret_val, root_base)}
				sp = base - 2
				stack[sp] = r
				sp += 1
			case .call_constructor:
				argc := rd_u16(code, pc)
				pc += 2
				f.pc = pc
				base := sp - argc
				fn := stack[base - 2]
				if !is_constructor(fn) {throw_type_error(ctx, "not a constructor"); exc = true; break}
				r := call_internal(ctx, fn, UNDEFINED, stack[base - 1], stack[base:sp], true)
				if is_exception(r) {exc = true; break}
				sp = base - 2
				stack[sp] = r
				sp += 1
			case .array_from:
				argc := rd_u16(code, pc)
				pc += 2
				base := sp - argc
				arr := array_from_values(ctx, stack[base:sp])
				sp = base
				stack[sp] = mk_obj(arr)
				sp += 1
			case .apply:
				magic := rd_u16(code, pc)
				pc += 2
				f.pc = pc
				r := function_apply(ctx, stack[sp - 3], stack[sp - 2], stack[sp - 1], magic)
				if is_exception(r) {exc = true; break}
				sp -= 3
				stack[sp] = r
				sp += 1
			case .op_return:
				sp -= 1
				ret_val = stack[sp]
				if is_coro {
					stack[sp] = ret_val
					sp += 1
					f.sp = sp
					f.pc = pc
					temp_reset(rt, root_base)
					return UNDEFINED, .coro_return
				}
				return finish(f, rt, ret_val, root_base)
			case .return_undef:
				if is_coro {
					stack[sp] = UNDEFINED
					sp += 1
					f.sp = sp
					f.pc = pc
					temp_reset(rt, root_base)
					return UNDEFINED, .coro_return
				}
				return finish(f, rt, UNDEFINED, root_base)
			case .return_async:
				f.sp = sp
				f.pc = pc
				temp_reset(rt, root_base)
				return UNDEFINED, .coro_return
			case .initial_yield:
				f.sp = sp
				f.pc = pc
				temp_reset(rt, root_base)
				return UNDEFINED, .initial_yield
			case .yield:
				f.sp = sp
				f.pc = pc
				return UNDEFINED, .yield
			case .yield_star, .async_yield_star:
				f.sp = sp
				f.pc = pc
				return UNDEFINED, .yield_star
			case .await:
				f.sp = sp
				f.pc = pc
				return UNDEFINED, .await

			case .check_ctor_return:
				v := stack[sp - 1]
				if v.tag != .object {
					if v.tag != .undefined {
						throw_type_error(caller_ctx, "derived class constructor must return an object or undefined")
						exc = true
						break
					}
					stack[sp] = TRUE
				} else {
					stack[sp] = FALSE
				}
				sp += 1
			case .check_ctor:
				if is_undefined(f.new_target) {
					throw_type_error(ctx, "class constructors must be invoked with 'new'")
					exc = true
				}
			case .init_ctor:
				f.pc = pc
				if is_undefined(f.new_target) {
					throw_type_error(ctx, "class constructors must be invoked with 'new'")
					exc = true
					break
				}
				super := get_prototype_of(ctx, as_obj(f.func))
				if is_exception(super) {exc = true; break}
				if !is_constructor(super) {throw_type_error(ctx, "parent class must be a constructor"); exc = true; break}
				r := call_internal(ctx, super, UNDEFINED, f.new_target, args[:f.argc], true)
				if is_exception(r) {exc = true; break}
				stack[sp] = r
				sp += 1
			case .check_brand:
				r := check_brand(ctx, stack[sp - 2], stack[sp - 1])
				if r < 0 {exc = true; break}
				if r == 0 {throw_type_error(ctx, "invalid brand on object"); exc = true}
			case .add_brand:
				if add_brand(ctx, stack[sp - 2], stack[sp - 1]) < 0 {exc = true; break}
				sp -= 2

			case .op_throw:
				sp -= 1
				throw(ctx, stack[sp])
				exc = true
			case .throw_error:
				a := Atom(rd_u32(code, pc))
				kind := code[pc + 4]
				pc += 5
				switch kind {
				case 0: throw_read_only(ctx, a)
				case 1: throw_syntax_error(ctx, cat(ctx, "redeclaration of '", atom_utf8(rt, a), "'"))
				case 2: throw_reference_error_uninit(ctx, a)
				case 3: throw_reference_error(ctx, "unsupported reference to 'super'")
				case 4: throw_type_error(ctx, "iterator does not have a throw method")
				case: throw_internal_error(ctx, "invalid throw var type")
				}
				exc = true
			case .eval:
				argc := rd_u16(code, pc)
				scope_idx := rd_u16(code, pc + 2) - 1
				pc += 4
				f.pc = pc
				base := sp - argc
				fn := stack[base - 1]
				r: Value
				if fn.tag == .object && as_obj(fn) == ctx.eval_obj {
					r = eval_direct(ctx, f, var_refs, argc >= 1 ? stack[base] : UNDEFINED, scope_idx)
				} else {
					r = call_internal(ctx, fn, UNDEFINED, UNDEFINED, stack[base:sp], false)
				}
				if is_exception(r) {exc = true; break}
				sp = base - 1
				stack[sp] = r
				sp += 1
			case .apply_eval:
				scope_idx := rd_u16(code, pc) - 1
				pc += 2
				f.pc = pc
				list, ok := build_arg_list(ctx, stack[sp - 1])
				if !ok {exc = true; break}
				fn := stack[sp - 2]
				r: Value
				if fn.tag == .object && as_obj(fn) == ctx.eval_obj {
					r = eval_direct(ctx, f, var_refs, len(list) >= 1 ? list[0] : UNDEFINED, scope_idx)
				} else {
					r = call_internal(ctx, fn, UNDEFINED, UNDEFINED, list, false)
				}
				if is_exception(r) {exc = true; break}
				sp -= 2
				stack[sp] = r
				sp += 1
			case .regexp:
				r := regexp_create_literal(ctx, stack[sp - 2], stack[sp - 1])
				if is_exception(r) {exc = true; break}
				sp -= 1
				stack[sp - 1] = r
			case .get_super:
				v := stack[sp - 1]
				if v.tag != .object {throw_not_object(ctx); exc = true; break}
				p := get_prototype_of(ctx, as_obj(v))
				if is_exception(p) {exc = true; break}
				stack[sp - 1] = p
			case .op_import:
				f.pc = pc
				r := dynamic_import(ctx, f, stack[sp - 2], stack[sp - 1])
				if is_exception(r) {exc = true; break}
				sp -= 1
				stack[sp - 1] = r

			// --- global variables ---
			case .get_var_undef, .get_var:
				a := Atom(rd_u32(code, pc))
				pc += 4
				f.pc = pc
				v := global_get(ctx, a, op == .get_var)
				if is_exception(v) {exc = true; break}
				stack[sp] = v
				sp += 1
			case .put_var, .put_var_init:
				a := Atom(rd_u32(code, pc))
				pc += 4
				f.pc = pc
				sp -= 1
				if global_set(ctx, a, stack[sp], op == .put_var_init, strict) < 0 {exc = true}
			case .check_define_var:
				a := Atom(rd_u32(code, pc))
				flags := int(code[pc + 4])
				pc += 5
				if global_check_define(ctx, a, flags) < 0 {exc = true}
			case .define_var:
				a := Atom(rd_u32(code, pc))
				flags := int(code[pc + 4])
				pc += 5
				if global_define_var(ctx, a, flags) < 0 {exc = true}
			case .define_func:
				a := Atom(rd_u32(code, pc))
				flags := int(code[pc + 4])
				pc += 5
				if global_define_func(ctx, a, stack[sp - 1], flags) < 0 {exc = true; break}
				sp -= 1
			case .get_ref_value:
				f.pc = pc
				o := stack[sp - 2]
				if is_undefined(o) {
					a, ok := to_property_key(ctx, stack[sp - 1])
					if ok {throw_not_defined(ctx, a)}
					exc = true
					break
				}
				if o.tag == .object && (o.u.ptr == ctx.global_obj || o.u.ptr == ctx.global_var_obj) {
					a, ok := to_property_key(ctx, stack[sp - 1])
					if !ok {exc = true; break}
					if o.u.ptr == ctx.global_obj {
						h := has_property(ctx, ctx.global_obj, a)
						if h < 0 {exc = true; break}
						if h == 0 && strict {throw_not_defined(ctx, a); exc = true; break}
					}
				}
				v := get_by_value(ctx, o, stack[sp - 1])
				if is_exception(v) {exc = true; break}
				stack[sp] = v
				sp += 1
			case .put_ref_value:
				f.pc = pc
				o := stack[sp - 3]
				if is_undefined(o) {
					if strict {
						a, ok := to_property_key(ctx, stack[sp - 2])
						if ok {throw_not_defined(ctx, a)}
						exc = true
						break
					}
					o = mk_obj(ctx.global_obj)
				} else if strict && o.tag == .object {
					// SetMutableBinding of an object environment: the binding may have vanished meanwhile
					a, ok := to_property_key(ctx, stack[sp - 2])
					if !ok {exc = true; break}
					h := has_property(ctx, as_obj(o), a)
					if h < 0 {exc = true; break}
					if h == 0 {throw_not_defined(ctx, a); exc = true; break}
				}
				if set_by_value(ctx, o, stack[sp - 2], stack[sp - 1], strict) < 0 {exc = true; break}
				sp -= 3

			// --- properties ---
			case .get_field, .get_field2, .get_length:
				a: Atom
				if op == .get_length {
					a = pa(.A_length)
				} else {
					a = Atom(rd_u32(code, pc))
					pc += 4
				}
				o := stack[sp - 1]
				v: Value
				fast := false
				if o.tag == .object {
					p := as_obj(o)
					for {
						i := shape_find(p.shape, a)
						if i >= 0 {
							if p.shape.props[i].kind == .data {v = p.slots[i].value; fast = true}
							break
						}
						if p.fast_array || p.class == .proxy || p.class == .module_ns || p.class == .string || is_typed_array_class(p.class) {break}
						p = p.shape.proto
						if p == nil {v = UNDEFINED; fast = true; break}
					}
				}
				if !fast {
					f.pc = pc
					v = get_property(ctx, o, a, o)
					if is_exception(v) {exc = true; break}
				}
				if op == .get_field2 {
					stack[sp] = v
					sp += 1
				} else {
					stack[sp - 1] = v
				}
			case .put_field:
				a := Atom(rd_u32(code, pc))
				pc += 4
				o := stack[sp - 2]
				done := false
				if o.tag == .object {
					p := as_obj(o)
					i := shape_find(p.shape, a)
					if i >= 0 {
						sp_ := p.shape.props[i]
						if sp_.kind == .data && .writable in sp_.flags && !(p.class == .array && a == pa(.A_length)) {
							p.slots[i].value = stack[sp - 1]
							done = true
						}
					}
				}
				if !done {
					f.pc = pc
					if set_property(ctx, o, a, stack[sp - 1], o, strict) < 0 {exc = true; break}
				}
				sp -= 2
			case .get_private_field:
				v := get_private_field(ctx, stack[sp - 2], stack[sp - 1])
				if is_exception(v) {exc = true; break}
				sp -= 1
				stack[sp - 1] = v
			case .put_private_field:
				if set_private_field(ctx, stack[sp - 3], stack[sp - 1], stack[sp - 2]) < 0 {exc = true; break}
				sp -= 3
			case .define_private_field:
				if define_private_field(ctx, stack[sp - 3], stack[sp - 2], stack[sp - 1]) < 0 {exc = true; break}
				sp -= 2
			case .get_array_el, .get_array_el2:
				o := stack[sp - 2]
				k := stack[sp - 1]
				v: Value
				fast := false
				if o.tag == .object && k.tag == .int && k.u.i >= 0 {
					p := as_obj(o)
					if p.fast_array {
						ad := &p.data.(Array_Data)
						if u32(k.u.i) < ad.count {v = ad.values[k.u.i]; fast = true}
					}
				}
				if !fast {
					f.pc = pc
					v = get_by_value(ctx, o, k)
					if is_exception(v) {exc = true; break}
				}
				if op == .get_array_el {
					sp -= 1
					stack[sp - 1] = v
				} else {
					stack[sp - 1] = v
				}
			case .put_array_el:
				o := stack[sp - 3]
				k := stack[sp - 2]
				done := false
				if o.tag == .object && k.tag == .int && k.u.i >= 0 {
					p := as_obj(o)
					if p.fast_array && p.class == .array {
						ad := &p.data.(Array_Data)
						idx := u32(k.u.i)
						if idx < ad.count {
							ad.values[idx] = stack[sp - 1]
							done = true
						} else if idx == ad.count && p.extensible && array_append_ok(ctx, p) && .writable in p.shape.props[0].flags && idx >= array_length_u32(p) {
							array_push_fast(rt, p, stack[sp - 1])
							done = true
						}
					}
				}
				if !done {
					f.pc = pc
					if set_by_value(ctx, o, k, stack[sp - 1], strict) < 0 {exc = true; break}
				}
				sp -= 3
			case .get_super_value:
				f.pc = pc
				o := stack[sp - 2]
				if o.tag != .object {throw_not_object(ctx); exc = true; break}
				a, ok := to_property_key(ctx, stack[sp - 1])
				if !ok {exc = true; break}
				v := get_property(ctx, o, a, stack[sp - 3])
				if is_exception(v) {exc = true; break}
				sp -= 2
				stack[sp - 1] = v
			case .put_super_value:
				f.pc = pc
				o := stack[sp - 3]
				if o.tag != .object {throw_not_object(ctx); exc = true; break}
				a, ok := to_property_key(ctx, stack[sp - 2])
				if !ok {exc = true; break}
				if set_property(ctx, o, a, stack[sp - 1], stack[sp - 4], strict) < 0 {exc = true; break}
				sp -= 4
			case .define_field:
				a := Atom(rd_u32(code, pc))
				pc += 4
				o := stack[sp - 2]
				if o.tag != .object {throw_not_object(ctx); exc = true; break}
				if define_own_property(ctx, as_obj(o), a, data_desc(stack[sp - 1], CWE), true) < 0 {exc = true; break}
				sp -= 1
			case .set_name:
				a := Atom(rd_u32(code, pc))
				pc += 4
				if define_object_name(ctx, stack[sp - 1], a) < 0 {exc = true}
			case .set_name_computed:
				if define_object_name_computed(ctx, stack[sp - 1], stack[sp - 2]) < 0 {exc = true}
			case .set_proto:
				proto := stack[sp - 1]
				if proto.tag == .object || proto.tag == .null {
					if set_prototype_of(ctx, as_obj(stack[sp - 2]), proto.tag == .object ? as_obj(proto) : nil, true) < 0 {exc = true; break}
				}
				sp -= 1
			case .set_home_object:
				set_home_object(stack[sp - 1], stack[sp - 2])
			case .define_array_el:
				o := as_obj(stack[sp - 3])
				a, ok := to_property_key(ctx, stack[sp - 2])
				if !ok {exc = true; break}
				if create_data_property(ctx, o, a, stack[sp - 1], true) < 0 {exc = true; break}
				sp -= 1
			case .append:
				f.pc = pc
				if !append_enumerate(ctx, stack[:], sp) {exc = true; break}
				sp -= 1
			case .copy_data_properties:
				mask := int(code[pc])
				pc += 1
				f.pc = pc
				target := stack[sp - 1 - (mask & 3)]
				source := stack[sp - 1 - ((mask >> 2) & 7)]
				excluded := stack[sp - 1 - ((mask >> 5) & 7)]
				if !copy_data_properties(ctx, target, source, excluded, false) {exc = true}
			case .define_method, .define_method_computed:
				is_computed := op == .define_method_computed
				a: Atom
				if is_computed {
					ok: bool
					a, ok = to_property_key(ctx, stack[sp - 2])
					if !ok {exc = true; break}
				} else {
					a = Atom(rd_u32(code, pc))
					pc += 4
				}
				op_flags := int(code[pc])
				pc += 1
				ofs := is_computed ? 1 : 0
				obj := stack[sp - 2 - ofs]
				fn := stack[sp - 1]
				enumerable := op_flags & 4 != 0
				kind := op_flags & 3
				if method_set_properties(ctx, fn, a, kind, obj) < 0 {exc = true; break}
				flags: Prop_Flags = {.configurable}
				if enumerable {flags += {.enumerable}}
				d: Prop_Desc
				switch kind {
				case 0:
					d = Prop_Desc{value = fn, flags = flags + {.writable}, has = {.value, .writable, .enumerable, .configurable}}
				case 1:
					d = Prop_Desc{getter = fn, setter = UNDEFINED, flags = flags, has = {.get, .enumerable, .configurable}}
				case:
					d = Prop_Desc{getter = UNDEFINED, setter = fn, flags = flags, has = {.set, .enumerable, .configurable}}
				}
				if define_own_property(ctx, as_obj(obj), a, d, true) < 0 {exc = true; break}
				sp -= 1 + ofs
			case .define_class, .define_class_computed:
				a := Atom(rd_u32(code, pc))
				class_flags := int(code[pc + 4])
				pc += 5
				if !define_class(ctx, stack[:], sp, a, class_flags, var_refs, f, op == .define_class_computed) {exc = true}

			// --- locals, arguments, closure cells ---
			case .get_loc:
				stack[sp] = locals[rd_u16(code, pc)]
				sp += 1
				pc += 2
			case .put_loc:
				sp -= 1
				locals[rd_u16(code, pc)] = stack[sp]
				pc += 2
			case .set_loc:
				locals[rd_u16(code, pc)] = stack[sp - 1]
				pc += 2
			case .get_arg:
				stack[sp] = args[rd_u16(code, pc)]
				sp += 1
				pc += 2
			case .put_arg:
				sp -= 1
				args[rd_u16(code, pc)] = stack[sp]
				pc += 2
			case .set_arg:
				args[rd_u16(code, pc)] = stack[sp - 1]
				pc += 2
			case .get_loc8:
				stack[sp] = locals[code[pc]]
				sp += 1
				pc += 1
			case .put_loc8:
				sp -= 1
				locals[code[pc]] = stack[sp]
				pc += 1
			case .set_loc8:
				locals[code[pc]] = stack[sp - 1]
				pc += 1
			case .get_loc0_loc1:
				stack[sp] = locals[0]
				stack[sp + 1] = locals[1]
				sp += 2
			case .get_loc0, .get_loc1, .get_loc2, .get_loc3:
				stack[sp] = locals[int(op) - int(Opcode.get_loc0)]
				sp += 1
			case .put_loc0, .put_loc1, .put_loc2, .put_loc3:
				sp -= 1
				locals[int(op) - int(Opcode.put_loc0)] = stack[sp]
			case .set_loc0, .set_loc1, .set_loc2, .set_loc3:
				locals[int(op) - int(Opcode.set_loc0)] = stack[sp - 1]
			case .get_arg0, .get_arg1, .get_arg2, .get_arg3:
				stack[sp] = args[int(op) - int(Opcode.get_arg0)]
				sp += 1
			case .put_arg0, .put_arg1, .put_arg2, .put_arg3:
				sp -= 1
				args[int(op) - int(Opcode.put_arg0)] = stack[sp]
			case .set_arg0, .set_arg1, .set_arg2, .set_arg3:
				args[int(op) - int(Opcode.set_arg0)] = stack[sp - 1]
			case .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3:
				stack[sp] = var_refs[int(op) - int(Opcode.get_var_ref0)].pvalue^
				sp += 1
			case .put_var_ref0, .put_var_ref1, .put_var_ref2, .put_var_ref3:
				sp -= 1
				var_refs[int(op) - int(Opcode.put_var_ref0)].pvalue^ = stack[sp]
			case .set_var_ref0, .set_var_ref1, .set_var_ref2, .set_var_ref3:
				var_refs[int(op) - int(Opcode.set_var_ref0)].pvalue^ = stack[sp - 1]
			case .get_var_ref:
				stack[sp] = var_refs[rd_u16(code, pc)].pvalue^
				sp += 1
				pc += 2
			case .put_var_ref:
				sp -= 1
				var_refs[rd_u16(code, pc)].pvalue^ = stack[sp]
				pc += 2
			case .set_var_ref:
				var_refs[rd_u16(code, pc)].pvalue^ = stack[sp - 1]
				pc += 2
			case .get_var_ref_check:
				idx := rd_u16(code, pc)
				pc += 2
				v := var_refs[idx].pvalue^
				if v.tag == .uninitialized {throw_reference_error_uninit(ctx, b.closure_vars[idx].name); exc = true; break}
				stack[sp] = v
				sp += 1
			case .put_var_ref_check:
				idx := rd_u16(code, pc)
				pc += 2
				if var_refs[idx].pvalue^.tag == .uninitialized {throw_reference_error_uninit(ctx, b.closure_vars[idx].name); exc = true; break}
				sp -= 1
				var_refs[idx].pvalue^ = stack[sp]
			case .put_var_ref_check_init:
				idx := rd_u16(code, pc)
				pc += 2
				if var_refs[idx].pvalue^.tag != .uninitialized {throw_reference_error_uninit(ctx, b.closure_vars[idx].name); exc = true; break}
				sp -= 1
				var_refs[idx].pvalue^ = stack[sp]
			case .set_loc_uninitialized:
				locals[rd_u16(code, pc)] = UNINITIALIZED
				pc += 2
			case .get_loc_check:
				idx := rd_u16(code, pc)
				pc += 2
				v := locals[idx]
				if v.tag == .uninitialized {throw_reference_error_uninit(caller_ctx, b.vardefs[int(b.arg_count) + idx].name); exc = true; break}
				stack[sp] = v
				sp += 1
			case .put_loc_check:
				idx := rd_u16(code, pc)
				pc += 2
				if locals[idx].tag == .uninitialized {throw_reference_error_uninit(caller_ctx, b.vardefs[int(b.arg_count) + idx].name); exc = true; break}
				sp -= 1
				locals[idx] = stack[sp]
			case .put_loc_check_init:
				idx := rd_u16(code, pc)
				pc += 2
				if locals[idx].tag != .uninitialized {throw_reference_error(caller_ctx, "'this' can be initialized only once"); exc = true; break}
				sp -= 1
				locals[idx] = stack[sp]
			case .close_loc:
				idx := rd_u16(code, pc)
				pc += 2
				close_lexical_var(f, idx)
			case .make_loc_ref, .make_arg_ref, .make_var_ref_ref:
				a := Atom(rd_u32(code, pc))
				idx := rd_u16(code, pc + 4)
				pc += 6
				o := object_new_proto(ctx, nil)
				vr: ^Var_Ref
				if op == .make_var_ref_ref {
					vr = var_refs[idx]
				} else {
					vr = get_var_ref(rt, f, idx, op == .make_arg_ref)
				}
				s := add_property(rt, o, a, {.writable}, .var_ref)
				s.var_ref = vr
				stack[sp] = mk_obj(o)
				stack[sp + 1] = atom_to_value(rt, a)
				sp += 2
			case .make_var_ref:
				a := Atom(rd_u32(code, pc))
				pc += 4
				f.pc = pc
				if global_make_ref(ctx, a, stack[:], sp) < 0 {exc = true; break}
				sp += 2

			// --- control flow ---
			case .goto:
				d := rd_i32(code, pc)
				pc += d
				if d < 0 {
					temp_reset(rt, root_base)
					if poll_interrupt(ctx) || !gc_safepoint(ctx) {exc = true}
				}
			case .goto16:
				d := int(i16(u16(rd_u16(code, pc))))
				pc += d
				if d < 0 {
					temp_reset(rt, root_base)
					if poll_interrupt(ctx) || !gc_safepoint(ctx) {exc = true}
				}
			case .goto8:
				d := int(i8(code[pc]))
				pc += d
				if d < 0 {
					temp_reset(rt, root_base)
					if poll_interrupt(ctx) || !gc_safepoint(ctx) {exc = true}
				}
			case .if_true, .if_false:
				d := rd_i32(code, pc)
				pc += 4
				sp -= 1
				v := stack[sp]
				t := v.tag == .bool ? v.u.b : to_boolean(v)
				if t == (op == .if_true) {
					pc += d - 4
					if d < 0 {
						temp_reset(rt, root_base)
						if poll_interrupt(ctx) || !gc_safepoint(ctx) {exc = true}
					}
				}
			case .if_true8, .if_false8:
				d := int(i8(code[pc]))
				pc += 1
				sp -= 1
				v := stack[sp]
				t := v.tag == .bool ? v.u.b : to_boolean(v)
				if t == (op == .if_true8) {
					pc += d - 1
					if d < 0 {
						temp_reset(rt, root_base)
						if poll_interrupt(ctx) || !gc_safepoint(ctx) {exc = true}
					}
				}
			case .op_catch:
				d := rd_i32(code, pc)
				stack[sp] = mk_catch(i32(pc + d))
				sp += 1
				pc += 4
			case .gosub:
				d := rd_i32(code, pc)
				stack[sp] = mk_int(i32(pc + 4))
				sp += 1
				pc += d
			case .ret:
				v := stack[sp - 1]
				if v.tag != .int || int(v.u.i) >= len(code) || v.u.i < 0 {
					throw_internal_error(ctx, "invalid ret value")
					exc = true
					break
				}
				sp -= 1
				pc = int(v.u.i)
			case .nip_catch:
				sp -= 1
				rv := stack[sp]
				for sp > 0 && stack[sp - 1].tag != .catch_offset {sp -= 1}
				if sp == 0 {throw_internal_error(ctx, "nip_catch"); exc = true; break}
				stack[sp - 1] = rv

			case .check_object:
				if stack[sp - 1].tag != .object {throw_type_error(ctx, "not an object"); exc = true}
			case .to_object:
				v := stack[sp - 1]
				if v.tag != .object {
					f.pc = pc
					o := to_object(ctx, v)
					if is_exception(o) {exc = true; break}
					stack[sp - 1] = o
				}
			case .to_propkey:
				v := stack[sp - 1]
				if v.tag != .int && v.tag != .string && v.tag != .symbol {
					f.pc = pc
					k := to_property_key_value(ctx, v)
					if is_exception(k) {exc = true; break}
					stack[sp - 1] = k
				}
			case .to_propkey2:
				if is_nullish(stack[sp - 2]) {throw_type_error(ctx, "value has no property"); exc = true; break}
				v := stack[sp - 1]
				if v.tag != .int && v.tag != .string && v.tag != .symbol {
					f.pc = pc
					k := to_property_key_value(ctx, v)
					if is_exception(k) {exc = true; break}
					stack[sp - 1] = k
				}

			case .with_get_var, .with_put_var, .with_delete_var, .with_make_ref, .with_get_ref, .with_get_ref_undef:
				a := Atom(rd_u32(code, pc))
				diff := rd_i32(code, pc + 4)
				is_with := code[pc + 8] != 0
				pc += 9
				f.pc = pc
				obj := stack[sp - 1]
				if obj.tag != .object {sp -= 1; break}
				o := as_obj(obj)
				h := has_property(ctx, o, a)
				if h < 0 {exc = true; break}
				if h == 1 && is_with {
					u := has_unscopable(ctx, obj, a)
					if u < 0 {exc = true; break}
					if u == 1 {h = 0}
				}
				if h == 0 {
					sp -= 1
					break
				}
				#partial switch op {
				case .with_get_var, .with_get_ref, .with_get_ref_undef:
					// GetBindingValue: HasProperty again (an @@unscopables getter may have deleted it)
					h2 := has_property(ctx, o, a)
					if h2 < 0 {exc = true; break}
					v := UNDEFINED
					if h2 == 0 {
						if strict {throw_not_defined(ctx, a); exc = true; break}
					} else {
						v = get(ctx, obj, a)
						if is_exception(v) {exc = true; break}
					}
					#partial switch op {
					case .with_get_var:
						stack[sp - 1] = v
					case .with_get_ref:
						stack[sp] = v
						sp += 1
					case:
						stack[sp - 1] = UNDEFINED
						stack[sp] = v
						sp += 1
					}
				case .with_put_var:
					if set_property(ctx, obj, a, stack[sp - 2], obj, strict) < 0 {exc = true; break}
					sp -= 2
				case .with_delete_var:
					r := delete_property(ctx, o, a)
					if r < 0 {exc = true; break}
					stack[sp - 1] = mk_bool(r == 1)
				case .with_make_ref:
					stack[sp] = atom_to_value(rt, a)
					sp += 1
				}
				if !exc {pc += diff - 5}

			// --- iteration ---
			case .for_in_start:
				f.pc = pc
				it := build_for_in_iterator(ctx, stack[sp - 1])
				if is_exception(it) {exc = true; break}
				stack[sp - 1] = it
			case .for_in_next:
				f.pc = pc
				if !for_in_next(ctx, stack[:], sp) {exc = true; break}
				sp += 2
			case .for_of_start, .for_await_of_start:
				f.pc = pc
				it := get_iterator(ctx, stack[sp - 1], op == .for_await_of_start)
				if is_exception(it) {exc = true; break}
				stack[sp - 1] = it
				m := get(ctx, it, pa(.A_next))
				if is_exception(m) {exc = true; break}
				stack[sp] = m
				stack[sp + 1] = mk_catch(0)
				sp += 2
			case .for_of_next:
				offset := -3 - int(i8(code[pc]))
				pc += 1
				f.pc = pc
				itp := sp + offset
				value := UNDEFINED
				done := true
				if !is_undefined(stack[itp]) {
					v, d, ok := iterator_step_value(ctx, stack[itp], stack[itp + 1])
					if !ok {
						stack[itp] = UNDEFINED
						exc = true
						break
					}
					done = d
					if d {stack[itp] = UNDEFINED} else {value = v}
				}
				stack[sp] = value
				stack[sp + 1] = mk_bool(done)
				sp += 2
			case .iterator_get_value_done:
				f.pc = pc
				r := stack[sp - 1]
				if r.tag != .object {throw_type_error(ctx, "iterator must return an object"); exc = true; break}
				dv := get(ctx, r, pa(.A_done))
				if is_exception(dv) {exc = true; break}
				done := to_boolean(dv)
				v := get(ctx, r, pa(.A_value))
				if is_exception(v) {exc = true; break}
				stack[sp - 1] = v
				stack[sp] = mk_bool(done)
				sp += 1
				if done {stack[sp - 5] = UNDEFINED}
			case .iterator_close:
				sp -= 2 // catch offset, next method
				it := stack[sp - 1]
				if !is_undefined(it) {
					f.pc = pc
					if iterator_close(ctx, it, false) < 0 {exc = true; break}
				}
				sp -= 1
			case .iterator_next:
				f.pc = pc
				r := call_internal(ctx, stack[sp - 3], stack[sp - 4], UNDEFINED, stack[sp - 1:sp], false)
				if is_exception(r) {exc = true; break}
				stack[sp - 1] = r
			case .iterator_call:
				flags := int(code[pc])
				pc += 1
				f.pc = pc
				m := get(ctx, stack[sp - 4], (flags & 1) != 0 ? pa(.A_throw) : pa(.A_return))
				if is_exception(m) {exc = true; break}
				ret_flag := false
				if is_nullish(m) {
					ret_flag = true
				} else {
					r: Value
					if flags & 2 != 0 {
						r = call_internal(ctx, m, stack[sp - 4], UNDEFINED, {}, false)
					} else {
						r = call_internal(ctx, m, stack[sp - 4], UNDEFINED, stack[sp - 1:sp], false)
					}
					if is_exception(r) {exc = true; break}
					stack[sp - 1] = r
				}
				stack[sp] = mk_bool(ret_flag)
				sp += 1

			// --- unary / arithmetic ---
			case .neg:
				v := stack[sp - 1]
				if v.tag == .int && v.u.i != 0 && v.u.i != min(i32) {
					stack[sp - 1] = mk_int(-v.u.i)
				} else if v.tag == .int || v.tag == .float {
					stack[sp - 1] = mk_float(-as_f64(v))
				} else {
					r := op_unary(ctx, .neg, v)
					if is_exception(r) {exc = true; break}
					stack[sp - 1] = r
				}
			case .plus:
				v := stack[sp - 1]
				if v.tag != .int && v.tag != .float {
					r := op_unary(ctx, .plus, v)
					if is_exception(r) {exc = true; break}
					stack[sp - 1] = r
				}
			case .inc, .dec:
				v := stack[sp - 1]
				if v.tag == .int && v.u.i != max(i32) && v.u.i != min(i32) {
					stack[sp - 1] = mk_int(op == .inc ? v.u.i + 1 : v.u.i - 1)
				} else {
					r := op_unary(ctx, op == .inc ? .inc : .dec, v)
					if is_exception(r) {exc = true; break}
					stack[sp - 1] = r
				}
			case .post_inc, .post_dec:
				v := stack[sp - 1]
				if v.tag == .int && v.u.i != max(i32) && v.u.i != min(i32) {
					stack[sp] = mk_int(op == .post_inc ? v.u.i + 1 : v.u.i - 1)
				} else {
					n := to_numeric(ctx, v)
					if is_exception(n) {exc = true; break}
					stack[sp - 1] = n
					r := op_unary(ctx, op == .post_inc ? .inc : .dec, n)
					if is_exception(r) {exc = true; break}
					stack[sp] = r
				}
				sp += 1
			case .inc_loc, .dec_loc:
				idx := code[pc]
				pc += 1
				v := locals[idx]
				if v.tag == .int && v.u.i != max(i32) && v.u.i != min(i32) {
					locals[idx] = mk_int(op == .inc_loc ? v.u.i + 1 : v.u.i - 1)
				} else {
					r := op_unary(ctx, op == .inc_loc ? .inc : .dec, v)
					if is_exception(r) {exc = true; break}
					locals[idx] = r
				}
			case .add_loc:
				idx := code[pc]
				pc += 1
				x := locals[idx]
				y := stack[sp - 1]
				if x.tag == .int && y.tag == .int {
					r := i64(x.u.i) + i64(y.u.i)
					locals[idx] = mk_i64(r)
				} else if x.tag == .float && y.tag == .float {
					locals[idx] = mk_float(x.u.f + y.u.f)
				} else {
					f.pc = pc
					r := op_add(ctx, x, y)
					if is_exception(r) {exc = true; break}
					locals[idx] = r
				}
				sp -= 1
			case .op_not:
				v := stack[sp - 1]
				if v.tag == .int {
					stack[sp - 1] = mk_int(~v.u.i)
				} else {
					r := op_unary(ctx, .not, v)
					if is_exception(r) {exc = true; break}
					stack[sp - 1] = r
				}
			case .lnot:
				v := stack[sp - 1]
				stack[sp - 1] = mk_bool(!(v.tag == .bool ? v.u.b : to_boolean(v)))
			case .op_typeof:
				stack[sp - 1] = atom_to_value(rt, typeof_atom(stack[sp - 1]))
			case .delete:
				f.pc = pc
				r := delete_property_value(ctx, stack[sp - 2], stack[sp - 1], strict)
				if r < 0 {exc = true; break}
				sp -= 1
				stack[sp - 1] = mk_bool(r == 1)
			case .delete_var:
				a := Atom(rd_u32(code, pc))
				pc += 4
				r := global_delete(ctx, a)
				if r < 0 {exc = true; break}
				stack[sp] = mk_bool(r == 1)
				sp += 1
			case .add:
				x, y := stack[sp - 2], stack[sp - 1]
				if x.tag == .int && y.tag == .int {
					stack[sp - 2] = mk_i64(i64(x.u.i) + i64(y.u.i))
				} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
					stack[sp - 2] = mk_float(as_f64(x) + as_f64(y))
				} else {
					f.pc = pc
					r := op_add(ctx, x, y)
					if is_exception(r) {exc = true; break}
					stack[sp - 2] = r
				}
				sp -= 1
			case .sub:
				x, y := stack[sp - 2], stack[sp - 1]
				if x.tag == .int && y.tag == .int {
					stack[sp - 2] = mk_i64(i64(x.u.i) - i64(y.u.i))
				} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
					stack[sp - 2] = mk_float(as_f64(x) - as_f64(y))
				} else {
					f.pc = pc
					r := op_arith(ctx, .sub, x, y)
					if is_exception(r) {exc = true; break}
					stack[sp - 2] = r
				}
				sp -= 1
			case .mul:
				x, y := stack[sp - 2], stack[sp - 1]
				if x.tag == .int && y.tag == .int {
					r := i64(x.u.i) * i64(y.u.i)
					if r == 0 && (x.u.i | y.u.i) < 0 {
						stack[sp - 2] = mk_float(-0.0)
					} else {
						stack[sp - 2] = mk_i64(r)
					}
				} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
					stack[sp - 2] = mk_float(as_f64(x) * as_f64(y))
				} else {
					f.pc = pc
					r := op_arith(ctx, .mul, x, y)
					if is_exception(r) {exc = true; break}
					stack[sp - 2] = r
				}
				sp -= 1
			case .div:
				x, y := stack[sp - 2], stack[sp - 1]
				if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
					stack[sp - 2] = mk_number(as_f64(x) / as_f64(y))
				} else {
					f.pc = pc
					r := op_arith(ctx, .div, x, y)
					if is_exception(r) {exc = true; break}
					stack[sp - 2] = r
				}
				sp -= 1
			case .mod:
				x, y := stack[sp - 2], stack[sp - 1]
				if x.tag == .int && y.tag == .int && x.u.i >= 0 && y.u.i > 0 {
					stack[sp - 2] = mk_int(x.u.i % y.u.i)
				} else {
					f.pc = pc
					r := op_arith(ctx, .mod, x, y)
					if is_exception(r) {exc = true; break}
					stack[sp - 2] = r
				}
				sp -= 1
			case .pow:
				f.pc = pc
				r := op_arith(ctx, .pow, stack[sp - 2], stack[sp - 1])
				if is_exception(r) {exc = true; break}
				stack[sp - 2] = r
				sp -= 1
			case .shl, .sar, .shr, .op_and, .op_or, .xor:
				x, y := stack[sp - 2], stack[sp - 1]
				if x.tag == .int && y.tag == .int {
					sh := u32(y.u.i) & 31
					#partial switch op {
					case .shl: stack[sp - 2] = mk_int(i32(u32(x.u.i) << sh))
					case .sar: stack[sp - 2] = mk_int(x.u.i >> sh)
					case .shr: stack[sp - 2] = mk_u32(u32(x.u.i) >> sh)
					case .op_and: stack[sp - 2] = mk_int(x.u.i & y.u.i)
					case .op_or: stack[sp - 2] = mk_int(x.u.i | y.u.i)
					case .xor: stack[sp - 2] = mk_int(x.u.i ~ y.u.i)
					}
				} else {
					f.pc = pc
					aop: Arith_Op
					#partial switch op {
					case .shl: aop = .shl
					case .sar: aop = .sar
					case .shr: aop = .shr
					case .op_and: aop = .and
					case .op_or: aop = .or
					case .xor: aop = .xor
					}
					r := op_arith(ctx, aop, x, y)
					if is_exception(r) {exc = true; break}
					stack[sp - 2] = r
				}
				sp -= 1
			case .lt, .lte, .gt, .gte:
				x, y := stack[sp - 2], stack[sp - 1]
				res: bool
				if x.tag == .int && y.tag == .int {
					#partial switch op {
					case .lt: res = x.u.i < y.u.i
					case .lte: res = x.u.i <= y.u.i
					case .gt: res = x.u.i > y.u.i
					case .gte: res = x.u.i >= y.u.i
					}
				} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
					a1, b1 := as_f64(x), as_f64(y)
					#partial switch op {
					case .lt: res = a1 < b1
					case .lte: res = a1 <= b1
					case .gt: res = a1 > b1
					case .gte: res = a1 >= b1
					}
				} else {
					f.pc = pc
					cop: Cmp_Op
					#partial switch op {
					case .lt: cop = .lt
					case .lte: cop = .lte
					case .gt: cop = .gt
					case .gte: cop = .gte
					}
					r := op_compare(ctx, cop, x, y)
					if r < 0 {exc = true; break}
					res = r == 1
				}
				stack[sp - 2] = mk_bool(res)
				sp -= 1
			case .eq, .neq:
				x, y := stack[sp - 2], stack[sp - 1]
				res: bool
				if x.tag == .int && y.tag == .int {
					res = x.u.i == y.u.i
				} else {
					f.pc = pc
					r, ok := loose_equals(ctx, x, y)
					if !ok {exc = true; break}
					res = r
				}
				stack[sp - 2] = mk_bool(res == (op == .eq))
				sp -= 1
			case .strict_eq, .strict_neq:
				x, y := stack[sp - 2], stack[sp - 1]
				res := x.tag == .int && y.tag == .int ? x.u.i == y.u.i : strict_equals(ctx, x, y)
				stack[sp - 2] = mk_bool(res == (op == .strict_eq))
				sp -= 1
			case .op_in:
				f.pc = pc
				o := stack[sp - 1]
				if o.tag != .object {throw_type_error(ctx, "invalid 'in' operand"); exc = true; break}
				a, ok := to_property_key(ctx, stack[sp - 2])
				if !ok {exc = true; break}
				r := has_property(ctx, as_obj(o), a)
				if r < 0 {exc = true; break}
				stack[sp - 2] = mk_bool(r == 1)
				sp -= 1
			case .private_in:
				r := private_in(ctx, stack[sp - 2], stack[sp - 1])
				if r < 0 {exc = true; break}
				stack[sp - 2] = mk_bool(r == 1)
				sp -= 1
			case .instanceof:
				f.pc = pc
				r := op_instanceof(ctx, stack[sp - 2], stack[sp - 1])
				if r < 0 {exc = true; break}
				stack[sp - 2] = mk_bool(r == 1)
				sp -= 1
			case .is_undefined_or_null:
				stack[sp - 1] = mk_bool(is_nullish(stack[sp - 1]))
			case .is_undefined:
				stack[sp - 1] = mk_bool(is_undefined(stack[sp - 1]))
			case .is_null:
				stack[sp - 1] = mk_bool(is_null(stack[sp - 1]))
			case .typeof_is_undefined:
				stack[sp - 1] = mk_bool(typeof_atom(stack[sp - 1]) == pa(.A_undefined))
			case .typeof_is_function:
				stack[sp - 1] = mk_bool(typeof_atom(stack[sp - 1]) == pa(.A_function))

			// --- explicit resource management ---
			case .using_dispose_init:
				stack[sp] = UNINITIALIZED
				sp += 1
			case .using_dispose:
				idx := rd_u16(code, pc)
				pc += 2
				val := locals[idx]
				method := locals[idx + 1]
				if is_nullish(val) || val.tag == .uninitialized {break}
				f.pc = pc
				r := call_internal(ctx, method, val, UNDEFINED, {}, false)
				if is_exception(r) {
					nerr := take_exception(ctx)
					es := stack[sp - 1]
					if es.tag != .uninitialized {
						se := new_suppressed_error(ctx, nerr, es)
						if is_exception(se) {stack[sp - 1] = take_exception(ctx)} else {stack[sp - 1] = se}
					} else {
						stack[sp - 1] = nerr
					}
				}
			case .using_dispose_async:
				idx := rd_u16(code, pc)
				pc += 2
				val := locals[idx]
				method := locals[idx + 1]
				if is_nullish(val) || val.tag == .uninitialized {
					stack[sp] = UNDEFINED
					sp += 1
					break
				}
				f.pc = pc
				r := call_internal(ctx, method, val, UNDEFINED, {}, false)
				if is_exception(r) {exc = true; break}
				stack[sp] = r
				sp += 1
			case .using_dispose_merge:
				nerr := stack[sp - 1]
				es := stack[sp - 2]
				sp -= 1
				if es.tag != .uninitialized {
					se := new_suppressed_error(ctx, nerr, es)
					if is_exception(se) {stack[sp - 1] = take_exception(ctx)} else {stack[sp - 1] = se}
				} else {
					stack[sp - 1] = nerr
				}
			case .using_dispose_end:
				sp -= 1
				es := stack[sp]
				if es.tag != .uninitialized {throw(ctx, es); exc = true}
			case .using_check:
				hint := int(code[pc])
				pc += 1
				f.pc = pc
				m, ok := using_check(ctx, stack[sp - 1], hint)
				if !ok {exc = true; break}
				stack[sp] = m
				sp += 1

			case .op_nop:
			case:
				throw_internal_error(ctx, "invalid opcode")
				exc = true
			}
			if !exc {continue}
		}

		// --- exception unwinding ---
		exc = false
		f.pc = pc
		caught := false
		if !rt.uncatchable {
			for sp > 0 {
				sp -= 1
				v := stack[sp]
				if v.tag == .catch_offset {
					pos := int(v.u.i)
					if pos == 0 {
						// a for-of iterator: close it, keeping the pending exception
						sp -= 1
						iterator_close(ctx, stack[sp - 1], true)
					} else {
						stack[sp] = take_exception(ctx)
						sp += 1
						pc = pos
						caught = true
						break
					}
				}
			}
		}
		if caught {continue}
		f.sp = sp
		temp_reset(rt, root_base)
		return EXCEPTION, .exception
	}
}

@(private = "file")
finish :: #force_inline proc(f: ^Frame, rt: ^Runtime, v: Value, root_base: int) -> (Value, Exit_Kind) {
	temp_reset(rt, root_base)
	root(rt, v)
	return v, .ret
}

// --- helpers used by the interpreter ---

to_property_key_value :: proc(ctx: ^Context, v: Value) -> Value {
	a, ok := to_property_key(ctx, v)
	if !ok {return EXCEPTION}
	return atom_to_value(ctx.rt, a)
}

has_unscopable :: proc(ctx: ^Context, obj: Value, a: Atom) -> int {
	u := get(ctx, obj, well_known_atom(.unscopables))
	if is_exception(u) {return -1}
	if u.tag != .object {return 0}
	v := get(ctx, u, a)
	if is_exception(v) {return -1}
	return to_boolean(v) ? 1 : 0
}

// The unmapped arguments object.
build_arguments :: proc(ctx: ^Context, args: []Value) -> Value {
	rt := ctx.rt
	o := object_new_shape(rt, ctx.arguments_shape, .arguments)
	o.slots[0].value = mk_int(i32(len(args)))
	o.slots[1].value = mk_obj(ctx.array_proto_values)
	o.slots[2].getset = Getset{ctx.throw_type_error, ctx.throw_type_error}
	ad := Array_Data{}
	if len(args) > 0 {
		ad.values = mem_array(rt, Value, len(args))
		for v, i in args {ad.values[i] = v}
		ad.count = u32(len(args))
		ad.cap = u32(len(args))
	}
	o.data = ad
	o.fast_array = true
	return mk_obj(o)
}

// The mapped (sloppy) arguments object: the first `mapped` elements alias the parameters.
build_mapped_arguments :: proc(ctx: ^Context, f: ^Frame, mapped: int) -> Value {
	rt := ctx.rt
	o := object_new_proto(ctx, ctx.class_proto[.object], .mapped_arguments)
	object_make_dict(rt, o)
	for i in 0 ..< f.argc {
		if i < mapped {
			vr := get_var_ref(rt, f, i, true)
			s := add_property(rt, o, atom_from_u32(u32(i)), CWE, .var_ref)
			s.var_ref = vr
		} else {
			s := add_property(rt, o, atom_from_u32(u32(i)), CWE)
			s.value = f.args[i]
		}
	}
	s := add_property(rt, o, pa(.A_length), CW)
	s.value = mk_int(i32(f.argc))
	s = add_property(rt, o, well_known_atom(.iterator), CW)
	s.value = mk_obj(ctx.array_proto_values)
	s = add_property(rt, o, pa(.A_callee), CW)
	s.value = f.func
	return mk_obj(o)
}

// js_function_apply as used by OP_apply: magic 0 call, 1 construct, 2 Reflect.apply.
function_apply :: proc(ctx: ^Context, fn, this_arg, array_arg: Value, magic: int) -> Value {
	if !is_callable(fn) {return throw_not_a_function(ctx)}
	if is_nullish(array_arg) && magic != 2 {
		return call_internal(ctx, fn, this_arg, UNDEFINED, {}, false)
	}
	list, ok := build_arg_list(ctx, array_arg)
	if !ok {return EXCEPTION}
	if magic & 1 != 0 {
		if !is_constructor(fn) {return throw_type_error(ctx, "not a constructor")}
		return call_internal(ctx, fn, UNDEFINED, this_arg, list, true)
	}
	return call_internal(ctx, fn, this_arg, UNDEFINED, list, false)
}

// CreateListFromArrayLike (in scratch memory; elements rooted).
build_arg_list :: proc(ctx: ^Context, a: Value) -> ([]Value, bool) {
	rt := ctx.rt
	if a.tag != .object {
		throw_type_error(ctx, "argument list must be an object")
		return nil, false
	}
	n, ok := length_of_array_like(ctx, a)
	if !ok {return nil, false}
	if n > 65535 * 16 {
		throw_range_error(ctx, "too many arguments in function call")
		return nil, false
	}
	list := make([]Value, int(n), tmp(rt))
	o := as_obj(a)
	if (o.class == .array || o.class == .arguments) && o.fast_array && u32(n) == o.data.(Array_Data).count {
		ad := &o.data.(Array_Data)
		for i in 0 ..< int(n) {
			list[i] = ad.values[i]
			root(rt, list[i])
		}
		return list, true
	}
	for i in 0 ..< int(n) {
		v := get_index(ctx, a, i64(i))
		if is_exception(v) {return nil, false}
		list[i] = v
	}
	return list, true
}

// OP_append: array pos iterable -> array pos (spread into an array literal / argument list).
append_enumerate :: proc(ctx: ^Context, stack: []Value, sp: int) -> bool {
	if stack[sp - 2].tag != .int {
		throw_internal_error(ctx, "invalid index for append")
		return false
	}
	pos := i64(stack[sp - 2].u.i)
	arr := as_obj(stack[sp - 3])
	src := stack[sp - 1]
	if src.tag == .object && is_fast_array_iteration(ctx, as_obj(src)) {
		so := as_obj(src)
		ad := &so.data.(Array_Data)
		for i in 0 ..< int(ad.count) {
			if create_data_index(ctx, arr, pos, ad.values[i]) < 0 {return false}
			pos += 1
		}
		stack[sp - 2] = mk_i64(pos)
		return true
	}
	it := get_iterator(ctx, src, false)
	if is_exception(it) {return false}
	next := get(ctx, it, pa(.A_next))
	if is_exception(next) {return false}
	for {
		v, done, ok := iterator_step_value(ctx, it, next)
		if !ok {return false}
		if done {break}
		if create_data_index(ctx, arr, pos, v) < 0 {
			iterator_close(ctx, it, true)
			return false
		}
		pos += 1
	}
	stack[sp - 2] = mk_i64(pos)
	return true
}

// A fast array iterated by the unmodified %ArrayIteratorPrototype%.next with the original
// Array.prototype[@@iterator]: element access has no observable side effects.
is_fast_array_iteration :: proc(ctx: ^Context, o: ^Object) -> bool {
	if o.class != .array || !o.fast_array {return false}
	if o.data.(Array_Data).count != array_length_u32(o) {return false}
	if o.shape.proto != ctx.class_proto[.array] {return false}
	if shape_find(o.shape, well_known_atom(.iterator)) >= 0 {return false}
	ap := ctx.class_proto[.array]
	i := shape_find(ap.shape, well_known_atom(.iterator))
	if i < 0 || ap.shape.props[i].kind != .data || ap.slots[i].value.u.ptr != ctx.array_proto_values {return false}
	ip := ctx.class_proto[.array_iterator]
	j := shape_find(ip.shape, pa(.A_next))
	if j < 0 || ip.shape.props[j].kind != .data {return false}
	nv := ip.slots[j].value
	if nv.tag != .object || as_obj(nv).class != .c_function {return false}
	return as_obj(nv).data.(Native_Data).fn == array_iterator_next_native
}

// CopyDataProperties(target, source, excluded).
copy_data_properties :: proc(ctx: ^Context, target, source, excluded: Value, setprop: bool) -> bool {
	if source.tag != .object {return true}
	rt := ctx.rt
	src := as_obj(source)
	excl: ^Object = excluded.tag == .object ? as_obj(excluded) : nil
	keys := make([dynamic]Atom, 0, 16, tmp(rt))
	if !own_property_keys(ctx, src, &keys) {return false}
	for k in keys {
		if excl != nil {
			r := get_own_property(ctx, excl, k, nil)
			if r < 0 {return false}
			if r == 1 {continue}
		}
		e := own_enumerable(ctx, src, k)
		if e < 0 {return false}
		if e == 0 {continue}
		v := get(ctx, source, k)
		if is_exception(v) {return false}
		if setprop {
			if set(ctx, target, k, v) < 0 {return false}
		} else {
			if create_data_property(ctx, as_obj(target), k, v) < 0 {return false}
		}
	}
	return true
}

// SetFunctionName for an anonymous function value (only if it has no own "name").
define_object_name :: proc(ctx: ^Context, v: Value, name: Atom) -> int {
	if name == ATOM_NULL || v.tag != .object {return 0}
	o := as_obj(v)
	if object_has_name(o) {return 0}
	return define_own_property(ctx, o, pa(.A_name), data_desc(mk_str(atom_to_string(ctx.rt, name)), {.configurable}), true)
}

define_object_name_computed :: proc(ctx: ^Context, v: Value, key: Value) -> int {
	if v.tag != .object {return 0}
	o := as_obj(v)
	if object_has_name(o) {return 0}
	a, ok := to_property_key(ctx, key)
	if !ok {return -1}
	return define_own_property(ctx, o, pa(.A_name), data_desc(function_name_value(ctx, a, ""), {.configurable}), true)
}

@(private = "file")
object_has_name :: proc(o: ^Object) -> bool {
	i := shape_find(o.shape, pa(.A_name))
	if i < 0 {return false}
	p := o.shape.props[i]
	if p.kind != .data {return true}
	v := o.slots[i].value
	if v.tag != .string {return true}
	return as_str(v).len != 0
}

// The `name` of a function defined with key `a`: symbols become "[description]".
function_name_value :: proc(ctx: ^Context, a: Atom, prefix: string) -> Value {
	rt := ctx.rt
	s: ^JS_String
	if atom_is_symbol(rt, a) {
		sym := atom_symbol(rt, a)
		if sym != nil && is_string(sym.description) && atom_is_private(rt, a) {
			s = as_str(sym.description) // a private name is its description ("#x"), without brackets
		} else if sym != nil && is_string(sym.description) {
			sb := sb_init(rt)
			sb_ascii(&sb, "[")
			sb_str(&sb, as_str(sym.description))
			sb_ascii(&sb, "]")
			s = sb_finish(&sb)
		} else {
			s = rt.empty_string
		}
	} else {
		s = atom_to_string(rt, a)
	}
	if prefix != "" {
		sb := sb_init(rt)
		sb_ascii(&sb, prefix)
		sb_str(&sb, s)
		s = sb_finish(&sb)
	}
	return mk_str(s)
}

// js_method_set_properties: name ("get x"/"set x") and home object of a method.
method_set_properties :: proc(ctx: ^Context, fn: Value, a: Atom, kind: int, home: Value) -> int {
	prefix := kind == 1 ? "get " : (kind == 2 ? "set " : "")
	name := function_name_value(ctx, a, prefix)
	if fn.tag == .object {
		if define_own_property(ctx, as_obj(fn), pa(.A_name), data_desc(name, {.configurable}), true) < 0 {return -1}
	}
	set_home_object(fn, home)
	return 0
}

// js_op_define_class: parent ctor_bytecode -> ctor proto
define_class :: proc(ctx: ^Context, stack: []Value, sp: int, name: Atom, class_flags: int, var_refs: [^]^Var_Ref, f: ^Frame, computed: bool) -> bool {
	rt := ctx.rt
	parent_class := stack[sp - 2]
	bfunc := stack[sp - 1]
	parent_proto: ^Object
	ctor_proto: ^Object
	if class_flags & 1 != 0 {
		if is_null(parent_class) {
			parent_proto = nil
			ctor_proto = ctx.function_proto
		} else {
			if !is_constructor(parent_class) {
				throw_type_error(ctx, "parent class must be constructor")
				return false
			}
			pp := get(ctx, parent_class, pa(.A_prototype))
			if is_exception(pp) {return false}
			if !is_null(pp) && pp.tag != .object {
				throw_type_error(ctx, "parent prototype must be an object or null")
				return false
			}
			parent_proto = pp.tag == .object ? as_obj(pp) : nil
			ctor_proto = as_obj(parent_class)
		}
	} else {
		parent_proto = ctx.class_proto[.object]
		ctor_proto = ctx.function_proto
	}
	proto := object_new_proto(ctx, parent_proto)
	fb := cast(^Function_Bytecode)bfunc.u.ptr
	ctor := object_new_proto(ctx, ctor_proto, .bytecode_function)
	closure_bind(ctx, ctor, fb, var_refs, f)
	ctor.is_constructor = true
	ctor.is_class_ctor = true
	set_home_object(mk_obj(ctor), mk_obj(proto))
	define_value(ctx, ctor, pa(.A_length), mk_int(i32(fb.defined_arg_count)), {.configurable})
	if computed {
		if define_object_name_computed(ctx, mk_obj(ctor), stack[sp - 3]) < 0 {return false}
	} else {
		if define_object_name(ctx, mk_obj(ctor), name) < 0 {return false}
	}
	if define_own_property(ctx, proto, pa(.A_constructor), data_desc(mk_obj(ctor), CW), true) < 0 {return false}
	if define_own_property(ctx, ctor, pa(.A_prototype), data_desc(mk_obj(proto), {}), true) < 0 {return false}
	stack[sp - 2] = mk_obj(ctor)
	stack[sp - 1] = mk_obj(proto)
	_ = rt
	return true
}

// --- private names and brands ---

private_atom :: proc(ctx: ^Context, name: Value) -> (Atom, bool) {
	if name.tag != .symbol {
		throw_type_error(ctx, "not a symbol")
		return ATOM_NULL, false
	}
	return atom_from_symbol(ctx.rt, as_sym(name)), true
}

get_private_field :: proc(ctx: ^Context, obj, name: Value) -> Value {
	if obj.tag != .object {return throw_not_object(ctx)}
	a, ok := private_atom(ctx, name)
	if !ok {return EXCEPTION}
	o := as_obj(obj)
	i := shape_find(o.shape, a)
	if i < 0 {return throw_type_error(ctx, cat(ctx, "private class field '", atom_utf8(ctx.rt, a), "' does not exist"))}
	return o.slots[i].value
}

set_private_field :: proc(ctx: ^Context, obj, name, val: Value) -> int {
	if obj.tag != .object {throw_not_object(ctx); return -1}
	a, ok := private_atom(ctx, name)
	if !ok {return -1}
	o := as_obj(obj)
	i := shape_find(o.shape, a)
	if i < 0 {
		throw_type_error(ctx, cat(ctx, "private class field '", atom_utf8(ctx.rt, a), "' does not exist"))
		return -1
	}
	o.slots[i].value = val
	return 0
}

define_private_field :: proc(ctx: ^Context, obj, name, val: Value) -> int {
	if obj.tag != .object {throw_not_object(ctx); return -1}
	a, ok := private_atom(ctx, name)
	if !ok {return -1}
	o := as_obj(obj)
	if !o.extensible {
		throw_type_error(ctx, "object is not extensible")
		return -1
	}
	if shape_find(o.shape, a) >= 0 {
		throw_type_error(ctx, cat(ctx, "private class field '", atom_utf8(ctx.rt, a), "' already exists"))
		return -1
	}
	s := add_property(ctx.rt, o, a, CWE)
	s.value = val
	return 0
}

add_brand :: proc(ctx: ^Context, obj, home: Value) -> int {
	rt := ctx.rt
	if home.tag != .object {throw_not_object(ctx); return -1}
	h := as_obj(home)
	i := shape_find(h.shape, pa(.A_Private_brand))
	brand: Value
	if i < 0 {
		brand = mk_sym(symbol_new_raw(rt, mk_str(atom_to_string(rt, pa(.A_brand))), true))
		s := add_property(rt, h, pa(.A_Private_brand), CWE)
		s.value = brand
	} else {
		brand = h.slots[i].value
	}
	ba := atom_from_symbol(rt, as_sym(brand))
	if obj.tag == .object {
		o := as_obj(obj)
		if !o.extensible {
			throw_type_error(ctx, "object is not extensible")
			return -1
		}
		if shape_find(o.shape, ba) >= 0 {
			throw_type_error(ctx, "private method is already present")
			return -1
		}
		s := add_property(rt, o, ba, CWE)
		s.value = UNDEFINED
	}
	return 0
}

check_brand :: proc(ctx: ^Context, obj, fn: Value) -> int {
	if fn.tag != .object {throw_not_object(ctx); return -1}
	fo := as_obj(fn)
	fd, ok := fo.data.(Func_Data)
	if !ok || fd.home == nil {throw_not_object(ctx); return -1}
	i := shape_find(fd.home.shape, pa(.A_Private_brand))
	if i < 0 {
		throw_type_error(ctx, "expecting <brand> private field")
		return -1
	}
	brand := fd.home.slots[i].value
	if brand.tag != .symbol {throw_not_object(ctx); return -1}
	if obj.tag != .object {throw_not_object(ctx); return -1}
	return shape_find(as_obj(obj).shape, atom_from_symbol(ctx.rt, as_sym(brand))) >= 0 ? 1 : 0
}

private_in :: proc(ctx: ^Context, obj, name: Value) -> int {
	if obj.tag != .object {
		throw_type_error(ctx, "invalid 'in' operand")
		return -1
	}
	if name.tag == .object {return check_brand(ctx, obj, name)}
	a, ok := private_atom(ctx, name)
	if !ok {return -1}
	return shape_find(as_obj(obj).shape, a) >= 0 ? 1 : 0
}

// --- explicit resource management helpers ---

new_suppressed_error :: proc(ctx: ^Context, err, suppressed: Value) -> Value {
	o := object_new_proto(ctx, ctx.native_error_proto[.suppressed], .error)
	define_value(ctx, o, pa(.A_error), err, CW)
	define_value(ctx, o, pa(.A_suppressed), suppressed, CW)
	error_add_stack(ctx, o)
	return mk_obj(o)
}

@(private = "file")
sync_dispose_wrapper :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	d := native_data(ctx)
	r := call(ctx, d[0], this, {})
	if is_exception(r) {
		e := take_exception(ctx)
		return promise_reject_value(ctx, e)
	}
	return promise_resolve_value(ctx, UNDEFINED)
}

using_check :: proc(ctx: ^Context, val: Value, hint: int) -> (Value, bool) {
	if is_nullish(val) {return UNDEFINED, true}
	if val.tag != .object {
		throw_type_error(ctx, "not an object")
		return UNDEFINED, false
	}
	sync_fallback := false
	m: Value
	if hint == 1 {
		m = get(ctx, val, well_known_atom(.async_dispose))
		if is_exception(m) {return UNDEFINED, false}
		if is_nullish(m) {
			m = get(ctx, val, well_known_atom(.dispose))
			if is_exception(m) {return UNDEFINED, false}
			sync_fallback = true
		}
	} else {
		m = get(ctx, val, well_known_atom(.dispose))
		if is_exception(m) {return UNDEFINED, false}
	}
	if is_nullish(m) {
		throw_type_error(ctx, "value is not disposable")
		return UNDEFINED, false
	}
	if !is_callable(m) {
		throw_type_error(ctx, "dispose method is not a function")
		return UNDEFINED, false
	}
	if sync_fallback {
		w := new_native_anon(ctx, sync_dispose_wrapper, 0, {m})
		return mk_obj(w), true
	}
	return m, true
}
