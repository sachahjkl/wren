package jsrt

// The bytecode interpreter: a switch-dispatch loop over the QuickJS-ng 0.17 instruction set.
//
// We start with a plain `switch` on the opcode byte. Odin's switch on a dense enum compiles to a jump
// table, so this is already close to computed-goto dispatch; whether a hand-rolled jump table with
// #no_bounds_check or a block-based loop beats it is a measurement for later (see docs), and the
// opcode decode is isolated so that change stays local. Operands are read little-endian straight out
// of the (atom-rewritten) instruction stream.
//
// The loop maintains the operand stack in the frame. Each opcode follows QuickJS's stack effect
// (n_pop / n_push in opcode_info). Errors set ctx.exception and unwind by returning EXCEPTION up to
// the nearest catch handler (the exception-table walk is handled by the catch/throw opcodes).

import "core:math"
import "core:fmt"

INTERP_DEBUG :: #config(INTERP_DEBUG, false)

@(private = "file")
interp_dbg_op :: proc(op: Opcode, pc: int) {
	fmt.eprintfln("[interp] unimplemented opcode %v (=%d) at pc %d", op, int(op), pc)
}

// Run `f` to completion. Returns the function's result (owned) or EXCEPTION.
interp_run :: proc(ctx: ^Context, f: ^Call_Frame) -> Value {
	rt := ctx.rt
	code := f.bc.byte_code
	interrupt_counter := 0

	for f.pc < len(code) {
		// Periodic interrupt / GC check on a budget, not every instruction.
		interrupt_counter += 1
		if interrupt_counter >= 4096 {
			interrupt_counter = 0
			if check_interrupt(rt) {
				return throw_error(ctx, .internal, "execution interrupted")
			}
			maybe_collect(rt)
		}

		op := Opcode(code[f.pc])
		start := f.pc

		#partial switch op {
		case .invalid, .op_nop:
			f.pc += 1

		// --- push constants ---
		case .push_i32:
			f.pc += 1
			push(f, mk_int(i32(read_u32(code, f.pc))))
			f.pc += 4
		case .push_const, .fclosure:
			f.pc += 1
			idx := read_u32(code, f.pc)
			f.pc += 4
			v := cpool_value(ctx, f, int(idx), op == .fclosure)
			if is_exception(v) {return unwind(ctx, f, v)}
			push(f, v)
		case .push_const8, .fclosure8:
			f.pc += 1
			idx := code[f.pc]
			f.pc += 1
			v := cpool_value(ctx, f, int(idx), op == .fclosure8)
			if is_exception(v) {return unwind(ctx, f, v)}
			push(f, v)
		case .push_atom_value:
			f.pc += 1
			a := Atom(read_u32(code, f.pc))
			f.pc += 4
			push(f, mk_heap(.string, atom_to_string(rt, a)))
		case .undefined:
			push(f, UNDEFINED); f.pc += 1
		case .null:
			push(f, NULL); f.pc += 1
		case .push_this:
			push(f, value_dup(f.this_val)); f.pc += 1
		case .push_false:
			push(f, FALSE); f.pc += 1
		case .push_true:
			push(f, TRUE); f.pc += 1
		case .push_empty_string:
			push(f, mk_heap(.string, string_empty(rt))); f.pc += 1
		case .object:
			o := object_new(rt, ctx.realm.object_proto)
			push(f, o != nil ? mk_heap(.object, o) : UNDEFINED)
			f.pc += 1
		case .push_minus1:
			push(f, mk_int(-1)); f.pc += 1
		case .push_0:
			push(f, mk_int(0)); f.pc += 1
		case .push_1:
			push(f, mk_int(1)); f.pc += 1
		case .push_2:
			push(f, mk_int(2)); f.pc += 1
		case .push_3:
			push(f, mk_int(3)); f.pc += 1
		case .push_4:
			push(f, mk_int(4)); f.pc += 1
		case .push_5:
			push(f, mk_int(5)); f.pc += 1
		case .push_6:
			push(f, mk_int(6)); f.pc += 1
		case .push_7:
			push(f, mk_int(7)); f.pc += 1
		case .push_i8:
			f.pc += 1
			push(f, mk_int(i32(i8(code[f.pc]))))
			f.pc += 1
		case .push_i16:
			f.pc += 1
			push(f, mk_int(i32(i16(read_u16(code, f.pc)))))
			f.pc += 2

		// --- stack manipulation ---
		case .drop:
			value_free(rt, pop(f)); f.pc += 1
		case .dup:
			push(f, value_dup(peek(f))); f.pc += 1
		case .dup2:
			a := peek(f, 1); b := peek(f, 0)
			push(f, value_dup(a)); push(f, value_dup(b)); f.pc += 1
		case .swap:
			a := pop(f); b := pop(f); push(f, a); push(f, b); f.pc += 1
		case .nip:
			b := pop(f); value_free(rt, pop(f)); push(f, b); f.pc += 1

		// --- locals and arguments ---
		case .get_loc:
			f.pc += 1
			idx := read_u16(code, f.pc)
			f.pc += 2
			push(f, value_dup(f.locals[idx]))
		case .put_loc:
			f.pc += 1
			idx := read_u16(code, f.pc)
			f.pc += 2
			value_free(rt, f.locals[idx])
			f.locals[idx] = pop(f)
		case .set_loc:
			f.pc += 1
			idx := read_u16(code, f.pc)
			f.pc += 2
			value_free(rt, f.locals[idx])
			f.locals[idx] = value_dup(peek(f))
		case .get_loc8:
			f.pc += 1
			idx := code[f.pc]; f.pc += 1
			push(f, value_dup(f.locals[idx]))
		case .put_loc8:
			f.pc += 1
			idx := code[f.pc]; f.pc += 1
			value_free(rt, f.locals[idx]); f.locals[idx] = pop(f)
		case .set_loc8:
			f.pc += 1
			idx := code[f.pc]; f.pc += 1
			value_free(rt, f.locals[idx]); f.locals[idx] = value_dup(peek(f))
		case .get_loc0:
			push(f, value_dup(f.locals[0])); f.pc += 1
		case .get_loc1:
			push(f, value_dup(f.locals[1])); f.pc += 1
		case .get_loc2:
			push(f, value_dup(f.locals[2])); f.pc += 1
		case .get_loc3:
			push(f, value_dup(f.locals[3])); f.pc += 1
		case .put_loc0:
			value_free(rt, f.locals[0]); f.locals[0] = pop(f); f.pc += 1
		case .put_loc1:
			value_free(rt, f.locals[1]); f.locals[1] = pop(f); f.pc += 1
		case .put_loc2:
			value_free(rt, f.locals[2]); f.locals[2] = pop(f); f.pc += 1
		case .put_loc3:
			value_free(rt, f.locals[3]); f.locals[3] = pop(f); f.pc += 1
		case .set_loc0:
			value_free(rt, f.locals[0]); f.locals[0] = value_dup(peek(f)); f.pc += 1
		case .set_loc1:
			value_free(rt, f.locals[1]); f.locals[1] = value_dup(peek(f)); f.pc += 1
		case .set_loc2:
			value_free(rt, f.locals[2]); f.locals[2] = value_dup(peek(f)); f.pc += 1
		case .set_loc3:
			value_free(rt, f.locals[3]); f.locals[3] = value_dup(peek(f)); f.pc += 1
		case .get_loc0_loc1:
			push(f, value_dup(f.locals[0])); push(f, value_dup(f.locals[1])); f.pc += 1
		case .get_arg:
			f.pc += 1
			idx := read_u16(code, f.pc); f.pc += 2
			push(f, value_dup(f.locals[idx]))
		case .put_arg:
			f.pc += 1
			idx := read_u16(code, f.pc); f.pc += 2
			value_free(rt, f.locals[idx]); f.locals[idx] = pop(f)
		case .set_arg:
			f.pc += 1
			idx := read_u16(code, f.pc); f.pc += 2
			value_free(rt, f.locals[idx]); f.locals[idx] = value_dup(peek(f))

		// --- closure upvalues ---
		case .get_var_ref:
			f.pc += 1
			idx := read_u16(code, f.pc); f.pc += 2
			push(f, value_dup(f.var_refs[idx].pvalue^))
		case .put_var_ref:
			f.pc += 1
			idx := read_u16(code, f.pc); f.pc += 2
			vr := f.var_refs[idx]
			value_free(rt, vr.pvalue^)
			vr.pvalue^ = pop(f)
		case .set_var_ref:
			f.pc += 1
			idx := read_u16(code, f.pc); f.pc += 2
			vr := f.var_refs[idx]
			value_free(rt, vr.pvalue^)
			vr.pvalue^ = value_dup(peek(f))

		// --- global variable declaration (top-level) ---
		case .check_define_var:
			f.pc += 1
			_ = read_u32(code, f.pc) // atom
			f.pc += 4
			_ = code[f.pc] // flags
			f.pc += 1
			// Redeclaration conflict checking is a strict-mode nicety; permissive for now.
		case .define_var:
			f.pc += 1
			a := Atom(read_u32(code, f.pc)); f.pc += 4
			_ = code[f.pc]; f.pc += 1
			// Create the global binding if absent, initialised to undefined.
			if !object_get_own(ctx.realm.global, a).found {
				object_define_own(ctx, ctx.realm.global, a, UNDEFINED, {.writable, .enumerable, .configurable})
			}
		case .define_func:
			f.pc += 1
			a := Atom(read_u32(code, f.pc)); f.pc += 4
			_ = code[f.pc]; f.pc += 1
			fn := pop(f)
			object_define_own(ctx, ctx.realm.global, a, fn, {.writable, .enumerable, .configurable})

		// --- global variables ---
		case .get_var, .get_var_undef:
			f.pc += 1
			a := Atom(read_u32(code, f.pc)); f.pc += 4
			v := global_get(ctx, a, op == .get_var)
			if is_exception(v) {return unwind(ctx, f, v)}
			push(f, v)
		case .put_var, .put_var_init:
			f.pc += 1
			a := Atom(read_u32(code, f.pc)); f.pc += 4
			if !global_set(ctx, a, pop(f)) {return unwind(ctx, f, EXCEPTION)}

		// --- property access ---
		case .get_field, .get_field2:
			f.pc += 1
			a := Atom(read_u32(code, f.pc)); f.pc += 4
			obj := peek(f)
			v := object_get_value_by_atom(ctx, obj, a)
			if is_exception(v) {return unwind(ctx, f, v)}
			if op == .get_field {
				value_free(rt, pop(f))
			}
			push(f, v)
		case .put_field:
			f.pc += 1
			a := Atom(read_u32(code, f.pc)); f.pc += 4
			val := pop(f)
			obj := pop(f)
			ok := object_put_value_by_atom(ctx, obj, a, val)
			value_free(rt, obj)
			if !ok && has_exception(ctx) {return unwind(ctx, f, EXCEPTION)}
		case .get_array_el:
			f.pc += 1
			key := pop(f)
			obj := pop(f)
			v := object_get_value(ctx, obj, key)
			value_free(rt, key); value_free(rt, obj)
			if is_exception(v) {return unwind(ctx, f, v)}
			push(f, v)
		case .put_array_el:
			f.pc += 1
			val := pop(f)
			key := pop(f)
			obj := pop(f)
			ok := object_set_value(ctx, obj, key, val)
			value_free(rt, key); value_free(rt, obj)
			if !ok && has_exception(ctx) {return unwind(ctx, f, EXCEPTION)}

		// --- arithmetic ---
		case .add:
			if !op_add(ctx, f) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .sub:
			if !op_arith(ctx, f, .sub) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .mul:
			if !op_arith(ctx, f, .mul) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .div:
			if !op_arith(ctx, f, .div) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .mod:
			if !op_arith(ctx, f, .mod) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .pow:
			if !op_arith(ctx, f, .pow) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .neg:
			a := pop(f)
			n, ok := to_f64_val(ctx, a); value_free(rt, a)
			if !ok {return unwind(ctx, f, EXCEPTION)}
			push(f, mk_number(-n)); f.pc += 1
		case .inc:
			a := pop(f)
			n, ok := to_f64_val(ctx, a); value_free(rt, a)
			if !ok {return unwind(ctx, f, EXCEPTION)}
			push(f, mk_number(n + 1)); f.pc += 1
		case .dec:
			a := pop(f)
			n, ok := to_f64_val(ctx, a); value_free(rt, a)
			if !ok {return unwind(ctx, f, EXCEPTION)}
			push(f, mk_number(n - 1)); f.pc += 1
		case .plus:
			a := pop(f)
			n, ok := to_f64_val(ctx, a); value_free(rt, a)
			if !ok {return unwind(ctx, f, EXCEPTION)}
			push(f, mk_number(n)); f.pc += 1

		// --- bitwise ---
		case .op_and:
			if !op_bitwise(ctx, f, .and) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .op_or:
			if !op_bitwise(ctx, f, .or) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .xor:
			if !op_bitwise(ctx, f, .xor) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .shl:
			if !op_bitwise(ctx, f, .shl) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .shr:
			if !op_bitwise(ctx, f, .shr) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .sar:
			if !op_bitwise(ctx, f, .sar) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .op_not:
			a := pop(f)
			iv, ok := to_int32(ctx, a); value_free(rt, a)
			if !ok {return unwind(ctx, f, EXCEPTION)}
			push(f, mk_int(~iv)); f.pc += 1
		case .lnot:
			a := pop(f)
			push(f, mk_bool(!to_boolean(a))); value_free(rt, a); f.pc += 1

		// --- comparison ---
		case .lt:
			if !op_compare(ctx, f, .lt) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .lte:
			if !op_compare(ctx, f, .lte) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .gt:
			if !op_compare(ctx, f, .gt) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .gte:
			if !op_compare(ctx, f, .gte) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .eq:
			if !op_equality(ctx, f, false, false) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .neq:
			if !op_equality(ctx, f, false, true) {return unwind(ctx, f, EXCEPTION)}
			f.pc += 1
		case .strict_eq:
			op_equality(ctx, f, true, false); f.pc += 1
		case .strict_neq:
			op_equality(ctx, f, true, true); f.pc += 1

		case .op_typeof:
			a := pop(f)
			push(f, mk_heap(.string, string_from_utf8(rt, typeof_string(a))))
			value_free(rt, a); f.pc += 1
		case .is_undefined:
			a := pop(f); push(f, mk_bool(is_undefined(a))); value_free(rt, a); f.pc += 1
		case .is_null:
			a := pop(f); push(f, mk_bool(is_null(a))); value_free(rt, a); f.pc += 1
		case .is_undefined_or_null:
			a := pop(f); push(f, mk_bool(is_undefined_or_null(a))); value_free(rt, a); f.pc += 1

		// --- control flow ---
		case .goto:
			f.pc += 1
			target := i32(read_u32(code, f.pc))
			f.pc = start + 1 + 4 + int(target)
		case .goto8:
			f.pc += 1
			target := i8(code[f.pc])
			f.pc = start + 1 + 1 + int(target)
		case .goto16:
			f.pc += 1
			target := i16(read_u16(code, f.pc))
			f.pc = start + 1 + 2 + int(target)
		case .if_true:
			f.pc += 1
			target := i32(read_u32(code, f.pc)); f.pc += 4
			c := pop(f)
			if to_boolean(c) {f.pc = start + 5 + int(target)}
			value_free(rt, c)
		case .if_false:
			f.pc += 1
			target := i32(read_u32(code, f.pc)); f.pc += 4
			c := pop(f)
			if !to_boolean(c) {f.pc = start + 5 + int(target)}
			value_free(rt, c)
		case .if_true8:
			f.pc += 1
			target := i8(code[f.pc]); f.pc += 1
			c := pop(f)
			if to_boolean(c) {f.pc = start + 2 + int(target)}
			value_free(rt, c)
		case .if_false8:
			f.pc += 1
			target := i8(code[f.pc]); f.pc += 1
			c := pop(f)
			if !to_boolean(c) {f.pc = start + 2 + int(target)}
			value_free(rt, c)

		// --- calls ---
		case .call, .tail_call:
			f.pc += 1
			argc := int(read_u16(code, f.pc)); f.pc += 2
			if !do_call(ctx, f, argc, UNDEFINED, op == .tail_call) {return unwind(ctx, f, EXCEPTION)}
			if op == .tail_call {return pop(f)}
		case .call_method, .tail_call_method:
			f.pc += 1
			argc := int(read_u16(code, f.pc)); f.pc += 2
			if !do_call_method(ctx, f, argc, op == .tail_call_method) {return unwind(ctx, f, EXCEPTION)}
			if op == .tail_call_method {return pop(f)}
		case .call0, .call1, .call2, .call3:
			argc := int(op) - int(Opcode.call0)
			f.pc += 1
			if !do_call(ctx, f, argc, UNDEFINED, false) {return unwind(ctx, f, EXCEPTION)}
		case .call_constructor:
			f.pc += 1
			argc := int(read_u16(code, f.pc)); f.pc += 2
			if !do_construct(ctx, f, argc) {return unwind(ctx, f, EXCEPTION)}

		// --- return / throw ---
		case .op_return:
			return pop(f)
		case .return_undef:
			return UNDEFINED
		case .op_throw:
			v := pop(f)
			return unwind(ctx, f, throw(ctx, v))

		case:
			// Opcode recognised by the table but not yet implemented in the loop.
			when INTERP_DEBUG {
				interp_dbg_op(op, start)
			}
			return unwind(ctx, f, throw_error(ctx, .internal, interp_unimplemented(op)))
		}
	}
	return UNDEFINED
}

// --- unwinding ---
//
// On an exception, QuickJS walks the function's exception table (catch opcodes) to find a handler.
// Our handler table is driven by the `catch`/`gosub`/`ret` opcodes which push PC targets; a full
// try/catch unwinder is part of the control-flow wave. For now an exception propagates straight out
// of the frame (the caller sees EXCEPTION), which is correct for code without try/catch and fails
// loudly otherwise.
unwind :: proc(ctx: ^Context, f: ^Call_Frame, v: Value) -> Value {
	return EXCEPTION
}

// --- small decode helpers ---

@(private = "file")
read_u16 :: proc(code: []u8, pos: int) -> u16 {
	return u16(code[pos]) | (u16(code[pos + 1]) << 8)
}

@(private = "file")
read_u32 :: proc(code: []u8, pos: int) -> u32 {
	return u32(code[pos]) | (u32(code[pos + 1]) << 8) | (u32(code[pos + 2]) << 16) | (u32(code[pos + 3]) << 24)
}

// Resolve a constant-pool entry. For fclosure, wrap the Function_Bytecode in a closure object that
// captures the current frame's upvalues.
@(private = "file")
cpool_value :: proc(ctx: ^Context, f: ^Call_Frame, idx: int, as_closure: bool) -> Value {
	if idx >= len(f.bc.cpool) {
		return throw_error(ctx, .internal, "constant pool index out of range")
	}
	v := f.bc.cpool[idx]
	if as_closure && v.tag == .function_bc {
		return make_closure(ctx, f, cast(^Function_Bytecode)v.payload.ptr)
	}
	return value_dup(v)
}

@(private = "file")
interp_unimplemented :: proc(op: Opcode) -> string {
	return "unimplemented opcode in interpreter"
}

// Adaptive cycle-collector trigger.
maybe_collect :: proc(rt: ^Runtime) {
	if rt.malloc_size > rt.gc_threshold {
		gc_run(rt)
		rt.gc_threshold = max(rt.malloc_size * 2, 1 << 20)
	}
}

typeof_string :: proc(v: Value) -> string {
	#partial switch v.tag {
	case .undefined, .uninitialized:
		return "undefined"
	case .null:
		return "object"
	case .bool:
		return "boolean"
	case .int32, .float64:
		return "number"
	case .string:
		return "string"
	case .symbol:
		return "symbol"
	case .bigint:
		return "bigint"
	case .object:
		return is_callable(v) ? "function" : "object"
	case .exception:
		return "undefined"
	}
	return "undefined"
}
