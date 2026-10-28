package jsrt

// The interpreter's hot loop, as a procedure of its own.
//
// interp_run (interp.odin) is one very large procedure: with its hundreds of live values the code generator
// keeps `sp`, `locals`, `args`, `code` ... in stack slots and reloads them in every handler. The commonest
// instructions live here instead, in a small procedure whose few live values (ip, s, locals, args, the
// constant pool) stay in registers, with raw pointers instead of slices and indices (no bounds checks: the
// reader's verifier has checked every operand index, jump target and stack height).
//
// Contract: run from (pc0, sp0) until an instruction this loop does not handle, or whose fast path does not
// apply (operand types, a due collection / interrupt at a back edge ...). The instruction has had NO effect
// then: the caller executes it with the full dispatch, and re-enters. Nothing here allocates, throws or calls
// out, so the collector never runs inside it (back edges leave when one is due).

import "base:intrinsics"
import "base:runtime"

#assert(size_of(Value) == 16 && offset_of(Value, u) == 8 && size_of(Tag) == 1)

@(private = "file")
put_int :: #force_inline proc "contextless" (p: ^Value, v: i32) {
	w := cast(^[2]u64)p
	w[0] = u64(Tag.int)
	w[1] = u64(u32(v))
}

@(private = "file")
put_bool :: #force_inline proc "contextless" (p: ^Value, v: bool) {
	w := cast(^[2]u64)p
	w[0] = u64(Tag.bool)
	w[1] = u64(v)
}

@(private = "file")
put_f64 :: #force_inline proc "contextless" (p: ^Value, v: f64) {
	w := cast(^[2]u64)p
	w[0] = u64(Tag.float)
	w[1] = transmute(u64)v
}

@(private = "file")
put_num :: #force_inline proc "contextless" (p: ^Value, v: f64) {
	p^ = mk_number(v)
}

@(private = "file")
put_i64 :: #force_inline proc "contextless" (p: ^Value, r: i64) {
	if r == i64(i32(r)) {put_int(p, i32(r))} else {put_f64(p, f64(r))}
}

@(private = "file")
rd16 :: #force_inline proc "contextless" (p: [^]u8) -> int {
	return int(intrinsics.unaligned_load(cast(^u16)p))
}

@(private = "file")
rd32 :: #force_inline proc "contextless" (p: [^]u8) -> u32 {
	return intrinsics.unaligned_load(cast(^u32)p)
}

// ToBoolean for the types that are quick to decide; ok = false when the full conversion is needed.
@(private = "file")
quick_truthy :: #force_inline proc "contextless" (v: Value) -> (t: bool, ok: bool) {
	#partial switch v.tag {
	case .bool: return v.u.b, true
	case .int: return v.u.i != 0, true
	case .undefined, .null: return false, true
	case .object: return !as_obj(v).is_htmldda, true
	}
	return false, false
}

// Own data property lookup, then the prototype chain of ordinary objects; ok = false for anything exotic
// (the full path handles it).
@(private = "file")
hot_get_prop :: proc "contextless" (rt: ^Runtime, o: ^Object, a: Atom) -> (v: Value, ok: bool) {
	p := o
	for {
		i := shape_find(p.shape, a)
		if i >= 0 {
			if raw_data(p.shape.props)[i].kind != .data {return}
			return p.slots[i].value, true
		}
		if p.fast_array || p.class == .proxy || p.class == .module_ns || p.class == .string || is_typed_array_class(p.class) {return}
		if p.class == .host && host_exotic_of(rt, p) != nil {return}
		p = p.shape.proto
		if p == nil {return UNDEFINED, true}
	}
}

// The registers of one frame.
@(private = "file")
Hot_Regs :: struct {
	code:      [^]u8,
	stack:     [^]Value,
	locals:    [^]Value,
	args:      [^]Value,
	var_refs:  [^]^Var_Ref,
	cpool:     [^]Value,
	root_base: int,
}

@(private = "file")
hot_regs :: #force_inline proc "contextless" (f: ^Frame) -> Hot_Regs {
	b := f.bc
	return Hot_Regs{code = raw_data(b.code), stack = f.stack, locals = f.locals, args = f.args, var_refs = f.closure_refs, cpool = raw_data(b.cpool), root_base = f.root_base}
}

// Runs frame `f_in` from (pc0, sp0). Plain calls and returns between frames pushed by this very loop
// (Frame.stackless) are handled here too, so `f` of the result may be another frame than `f_in`; the
// returned pc / sp belong to it. `moved` says a frame was pushed or popped: `f` may then have the address of
// f_in (frame memory is reused) and still be another frame, so the pointer alone cannot tell.
interp_hot :: proc(ctx: ^Context, rt: ^Runtime, f_in: ^Frame, pc0: int, sp0: int) -> (f: ^Frame, pc: int, sp: int, moved: bool) {
	f = f_in
	regs := hot_regs(f)
	ip := regs.code[pc0:]
	s := regs.stack[sp0:] // the next free slot
	temp := cast(^runtime.Raw_Dynamic_Array)&rt.temp_roots
	loop: for {
		op := Opcode(ip[0])
		#partial switch op {
		case .call0, .call1, .call2, .call3, .call, .call_method:
			argc: int
			isz := 1
			if op == .call || op == .call_method {
				argc = rd16(ip[1:])
				isz = 3
			} else {
				argc = int(op) - int(Opcode.call0)
			}
			first := intrinsics.ptr_offset(s, -argc) // the first argument
			fv := first[-1]
			if fv.tag != .object {break loop}
			fo := as_obj(fv)
			if fo.class != .bytecode_function {break loop}
			nb := fo.data.(Func_Data).bc
			if nb.func_kind != .normal || rt.stack_depth >= rt.config.max_stack_depth || (nb.realm != nil && nb.realm != ctx) {break loop}
			this := UNDEFINED
			slot := intrinsics.ptr_offset(first, -1) // where the result goes
			if op == .call_method {
				this = first[-2]
				slot = intrinsics.ptr_offset(first, -2)
			}
			f.pc = int(uintptr(ip) - uintptr(regs.code)) + isz
			f.sp = int(uintptr(slot) - uintptr(regs.stack)) / size_of(Value)
			f = frame_push(ctx, fo, this, first[:argc])
			moved = true
			regs = hot_regs(f)
			ip = regs.code
			s = regs.stack
			// the entry safepoint (a collection due) is for interp_run: it sees pc == 0
			if gc_should_run(rt) {break loop}
		case .op_return, .return_undef:
			if !f.stackless {break loop}
			ret := op == .op_return ? s[-1] : UNDEFINED
			f = frame_pop(rt, f)
			moved = true
			f.stack[f.sp] = ret
			f.sp += 1
			regs = hot_regs(f)
			ip = regs.code[f.pc:]
			s = regs.stack[f.sp:]
		case .get_loc0, .get_loc1, .get_loc2, .get_loc3:
			s[0] = regs.locals[int(op) - int(Opcode.get_loc0)]
			s = s[1:]
			ip = ip[1:]
		case .put_loc0, .put_loc1, .put_loc2, .put_loc3:
			regs.locals[int(op) - int(Opcode.put_loc0)] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .set_loc0, .set_loc1, .set_loc2, .set_loc3:
			regs.locals[int(op) - int(Opcode.set_loc0)] = s[-1]
			ip = ip[1:]
		case .get_loc8:
			s[0] = regs.locals[ip[1]]
			s = s[1:]
			ip = ip[2:]
		case .put_loc8:
			regs.locals[ip[1]] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[2:]
		case .set_loc8:
			regs.locals[ip[1]] = s[-1]
			ip = ip[2:]
		case .get_loc:
			s[0] = regs.locals[rd16(ip[1:])]
			s = s[1:]
			ip = ip[3:]
		case .put_loc:
			regs.locals[rd16(ip[1:])] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[3:]
		case .set_loc:
			regs.locals[rd16(ip[1:])] = s[-1]
			ip = ip[3:]
		case .get_loc0_loc1:
			s[0] = regs.locals[0]
			s[1] = regs.locals[1]
			s = s[2:]
			ip = ip[1:]
		case .get_arg0, .get_arg1, .get_arg2, .get_arg3:
			s[0] = regs.args[int(op) - int(Opcode.get_arg0)]
			s = s[1:]
			ip = ip[1:]
		case .put_arg0, .put_arg1, .put_arg2, .put_arg3:
			regs.args[int(op) - int(Opcode.put_arg0)] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .set_arg0, .set_arg1, .set_arg2, .set_arg3:
			regs.args[int(op) - int(Opcode.set_arg0)] = s[-1]
			ip = ip[1:]
		case .get_arg:
			s[0] = regs.args[rd16(ip[1:])]
			s = s[1:]
			ip = ip[3:]
		case .put_arg:
			regs.args[rd16(ip[1:])] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[3:]
		case .set_arg:
			regs.args[rd16(ip[1:])] = s[-1]
			ip = ip[3:]
		case .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3:
			s[0] = regs.var_refs[int(op) - int(Opcode.get_var_ref0)].pvalue^
			s = s[1:]
			ip = ip[1:]
		case .put_var_ref0, .put_var_ref1, .put_var_ref2, .put_var_ref3:
			regs.var_refs[int(op) - int(Opcode.put_var_ref0)].pvalue^ = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .set_var_ref0, .set_var_ref1, .set_var_ref2, .set_var_ref3:
			regs.var_refs[int(op) - int(Opcode.set_var_ref0)].pvalue^ = s[-1]
			ip = ip[1:]
		case .get_var_ref:
			s[0] = regs.var_refs[rd16(ip[1:])].pvalue^
			s = s[1:]
			ip = ip[3:]
		case .put_var_ref:
			regs.var_refs[rd16(ip[1:])].pvalue^ = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[3:]
		case .set_var_ref:
			regs.var_refs[rd16(ip[1:])].pvalue^ = s[-1]
			ip = ip[3:]
		case .get_loc_check:
			v := regs.locals[rd16(ip[1:])]
			if v.tag == .uninitialized {break loop}
			s[0] = v
			s = s[1:]
			ip = ip[3:]
		case .put_loc_check:
			l := &regs.locals[rd16(ip[1:])]
			if l.tag == .uninitialized {break loop}
			l^ = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[3:]
		case .get_var_ref_check:
			v := regs.var_refs[rd16(ip[1:])].pvalue^
			if v.tag == .uninitialized {break loop}
			s[0] = v
			s = s[1:]
			ip = ip[3:]
		case .put_var_ref_check:
			l := regs.var_refs[rd16(ip[1:])].pvalue
			if l.tag == .uninitialized {break loop}
			l^ = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[3:]

		case .push_minus1, .push_0, .push_1, .push_2, .push_3, .push_4, .push_5, .push_6, .push_7:
			put_int(&s[0], i32(op) - i32(Opcode.push_0))
			s = s[1:]
			ip = ip[1:]
		case .push_i8:
			put_int(&s[0], i32(i8(ip[1])))
			s = s[1:]
			ip = ip[2:]
		case .push_i16:
			put_int(&s[0], i32(i16(u16(rd16(ip[1:])))))
			s = s[1:]
			ip = ip[3:]
		case .push_i32:
			put_int(&s[0], i32(rd32(ip[1:])))
			s = s[1:]
			ip = ip[5:]
		case .push_const8:
			s[0] = regs.cpool[ip[1]]
			s = s[1:]
			ip = ip[2:]
		case .push_const:
			s[0] = regs.cpool[rd32(ip[1:])]
			s = s[1:]
			ip = ip[5:]
		case .undefined:
			s[0] = UNDEFINED
			s = s[1:]
			ip = ip[1:]
		case .null:
			s[0] = NULL
			s = s[1:]
			ip = ip[1:]
		case .push_false:
			put_bool(&s[0], false)
			s = s[1:]
			ip = ip[1:]
		case .push_true:
			put_bool(&s[0], true)
			s = s[1:]
			ip = ip[1:]
		case .push_empty_string:
			s[0] = mk_str(rt.empty_string)
			s = s[1:]
			ip = ip[1:]
		case .op_nop:
			ip = ip[1:]

		case .drop:
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .dup:
			s[0] = s[-1]
			s = s[1:]
			ip = ip[1:]
		case .dup1:
			s[0] = s[-1]
			s[-1] = s[-2]
			s = s[1:]
			ip = ip[1:]
		case .dup2:
			s[0] = s[-2]
			s[1] = s[-1]
			s = s[2:]
			ip = ip[1:]
		case .nip:
			s[-2] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .nip1:
			s[-3] = s[-2]
			s[-2] = s[-1]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .swap:
			t := s[-2]
			s[-2] = s[-1]
			s[-1] = t
			ip = ip[1:]
		case .insert2:
			s[0] = s[-1]
			s[-1] = s[-2]
			s[-2] = s[0]
			s = s[1:]
			ip = ip[1:]
		case .insert3:
			s[0] = s[-1]
			s[-1] = s[-2]
			s[-2] = s[-3]
			s[-3] = s[0]
			s = s[1:]
			ip = ip[1:]
		case .perm3:
			t := s[-2]
			s[-2] = s[-3]
			s[-3] = t
			ip = ip[1:]
		case .rot3l:
			t := s[-3]
			s[-3] = s[-2]
			s[-2] = s[-1]
			s[-1] = t
			ip = ip[1:]

		case .inc_loc, .dec_loc:
			l := &regs.locals[ip[1]]
			if l.tag != .int || l.u.i == max(i32) || l.u.i == min(i32) {break loop}
			put_int(l, op == .inc_loc ? l.u.i + 1 : l.u.i - 1)
			ip = ip[2:]
		case .inc:
			v := &s[-1]
			if v.tag != .int || v.u.i == max(i32) {break loop}
			put_int(v, v.u.i + 1)
			ip = ip[1:]
		case .dec:
			v := &s[-1]
			if v.tag != .int || v.u.i == min(i32) {break loop}
			put_int(v, v.u.i - 1)
			ip = ip[1:]
		case .post_inc:
			v := s[-1]
			if v.tag != .int || v.u.i == max(i32) {break loop}
			put_int(&s[0], v.u.i + 1)
			s = s[1:]
			ip = ip[1:]
		case .post_dec:
			v := s[-1]
			if v.tag != .int || v.u.i == min(i32) {break loop}
			put_int(&s[0], v.u.i - 1)
			s = s[1:]
			ip = ip[1:]
		case .neg:
			v := s[-1]
			if v.tag == .int && v.u.i != 0 && v.u.i != min(i32) {
				put_int(&s[-1], -v.u.i)
			} else if v.tag == .int || v.tag == .float {
				put_f64(&s[-1], -as_f64(v))
			} else {
				break loop
			}
			ip = ip[1:]
		case .add_loc:
			l := &regs.locals[ip[1]]
			y := s[-1]
			if l.tag == .int && y.tag == .int {
				put_i64(l, i64(l.u.i) + i64(y.u.i))
			} else if l.tag == .float && y.tag == .float {
				put_f64(l, l.u.f + y.u.f)
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[2:]

		case .add:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				put_i64(&s[-2], i64(x.u.i) + i64(y.u.i))
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_f64(&s[-2], as_f64(x) + as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .sub:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				put_i64(&s[-2], i64(x.u.i) - i64(y.u.i))
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_f64(&s[-2], as_f64(x) - as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .mul:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				r := i64(x.u.i) * i64(y.u.i)
				if r == 0 && (x.u.i | y.u.i) < 0 {
					put_f64(&s[-2], -0.0)
				} else {
					put_i64(&s[-2], r)
				}
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_f64(&s[-2], as_f64(x) * as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .div:
			x, y := s[-2], s[-1]
			if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_num(&s[-2], as_f64(x) / as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .mod:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int || x.u.i < 0 || y.u.i <= 0 {break loop}
			put_int(&s[-2], x.u.i % y.u.i)
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .op_and:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_int(&s[-2], x.u.i & y.u.i)
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .op_or:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_int(&s[-2], x.u.i | y.u.i)
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .xor:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_int(&s[-2], x.u.i ~ y.u.i)
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .shl:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_int(&s[-2], i32(u32(x.u.i) << (u32(y.u.i) & 31)))
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .sar:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_int(&s[-2], x.u.i >> (u32(y.u.i) & 31))
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .shr:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			s[-2] = mk_u32(u32(x.u.i) >> (u32(y.u.i) & 31))
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .op_not:
			v := s[-1]
			if v.tag != .int {break loop}
			put_int(&s[-1], ~v.u.i)
			ip = ip[1:]
		case .lnot:
			t, ok := quick_truthy(s[-1])
			if !ok {break loop}
			put_bool(&s[-1], !t)
			ip = ip[1:]

		case .lt:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				put_bool(&s[-2], x.u.i < y.u.i)
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_bool(&s[-2], as_f64(x) < as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .lte:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				put_bool(&s[-2], x.u.i <= y.u.i)
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_bool(&s[-2], as_f64(x) <= as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .gt:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				put_bool(&s[-2], x.u.i > y.u.i)
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_bool(&s[-2], as_f64(x) > as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .gte:
			x, y := s[-2], s[-1]
			if x.tag == .int && y.tag == .int {
				put_bool(&s[-2], x.u.i >= y.u.i)
			} else if (x.tag == .float || x.tag == .int) && (y.tag == .float || y.tag == .int) {
				put_bool(&s[-2], as_f64(x) >= as_f64(y))
			} else {
				break loop
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .strict_eq, .eq:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_bool(&s[-2], x.u.i == y.u.i)
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .strict_neq, .neq:
			x, y := s[-2], s[-1]
			if x.tag != .int || y.tag != .int {break loop}
			put_bool(&s[-2], x.u.i != y.u.i)
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .is_undefined:
			put_bool(&s[-1], s[-1].tag == .undefined)
			ip = ip[1:]
		case .is_null:
			put_bool(&s[-1], s[-1].tag == .null)
			ip = ip[1:]
		case .is_undefined_or_null:
			put_bool(&s[-1], s[-1].tag == .undefined || s[-1].tag == .null)
			ip = ip[1:]

		case .if_true8, .if_false8:
			t, ok := quick_truthy(s[-1])
			if !ok {break loop}
			d := int(i8(ip[1]))
			if t == (op == .if_true8) {
				if d < 0 {
					if temp.len > regs.root_base {temp.len = regs.root_base}
					rt.interrupt_counter += 1
					if rt.interrupt_counter >= 10_000 || gc_should_run(rt) {break loop}
				}
				ip = intrinsics.ptr_offset(ip, 1 + d)
			} else {
				ip = ip[2:]
			}
			s = intrinsics.ptr_offset(s, -1)
		case .if_true, .if_false:
			t, ok := quick_truthy(s[-1])
			if !ok {break loop}
			d := int(i32(rd32(ip[1:])))
			if t == (op == .if_true) {
				if d < 0 {
					if temp.len > regs.root_base {temp.len = regs.root_base}
					rt.interrupt_counter += 1
					if rt.interrupt_counter >= 10_000 || gc_should_run(rt) {break loop}
				}
				ip = intrinsics.ptr_offset(ip, 1 + d)
			} else {
				ip = ip[5:]
			}
			s = intrinsics.ptr_offset(s, -1)
		case .goto8:
			d := int(i8(ip[1]))
			if d < 0 {
				if temp.len > regs.root_base {temp.len = regs.root_base}
				rt.interrupt_counter += 1
				if rt.interrupt_counter >= 10_000 || gc_should_run(rt) {break loop}
			}
			ip = intrinsics.ptr_offset(ip, 1 + d)
		case .goto16:
			d := int(i16(u16(rd16(ip[1:]))))
			if d < 0 {
				if temp.len > regs.root_base {temp.len = regs.root_base}
				rt.interrupt_counter += 1
				if rt.interrupt_counter >= 10_000 || gc_should_run(rt) {break loop}
			}
			ip = intrinsics.ptr_offset(ip, 1 + d)
		case .goto:
			d := int(i32(rd32(ip[1:])))
			if d < 0 {
				if temp.len > regs.root_base {temp.len = regs.root_base}
				rt.interrupt_counter += 1
				if rt.interrupt_counter >= 10_000 || gc_should_run(rt) {break loop}
			}
			ip = intrinsics.ptr_offset(ip, 1 + d)

		case .get_array_el:
			o, k := s[-2], s[-1]
			if o.tag != .object || k.tag != .int || k.u.i < 0 {break loop}
			p := as_obj(o)
			if !p.fast_array {break loop}
			ad := &p.data.(Array_Data)
			if u32(k.u.i) >= ad.count {break loop}
			s[-2] = ad.values[k.u.i]
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[1:]
		case .put_array_el:
			o, k := s[-3], s[-2]
			if o.tag != .object || k.tag != .int || k.u.i < 0 {break loop}
			p := as_obj(o)
			if !p.fast_array || p.class != .array {break loop}
			ad := &p.data.(Array_Data)
			if u32(k.u.i) >= ad.count {break loop}
			ad.values[k.u.i] = s[-1]
			s = intrinsics.ptr_offset(s, -3)
			ip = ip[1:]
		case .get_var, .get_var_undef:
			a := Atom(rd32(ip[1:]))
			gv := ctx.global_var_obj
			i := len(gv.shape.props) != 0 ? shape_find(gv.shape, a) : -1
			if i >= 0 {
				v := gv.slots[i].value
				if v.tag == .uninitialized {break loop}
				s[0] = v
			} else {
				g := ctx.global_obj
				j := global_slot(ctx, g, a)
				if j < 0 {break loop}
				s[0] = g.slots[j].value
			}
			s = s[1:]
			ip = ip[5:]
		case .put_var:
			a := Atom(rd32(ip[1:]))
			gv := ctx.global_var_obj
			i := len(gv.shape.props) != 0 ? shape_find(gv.shape, a) : -1
			if i >= 0 {
				if gv.slots[i].value.tag == .uninitialized || .writable not_in raw_data(gv.shape.props)[i].flags {break loop}
				gv.slots[i].value = s[-1]
			} else {
				g := ctx.global_obj
				j := global_slot(ctx, g, a)
				if j < 0 || .writable not_in raw_data(g.shape.props)[j].flags {break loop}
				g.slots[j].value = s[-1]
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[5:]
		case .get_field, .get_field2:
			o := s[-1]
			if o.tag != .object {break loop}
			v, ok := hot_get_prop(rt, as_obj(o), Atom(rd32(ip[1:])))
			if !ok {break loop}
			if op == .get_field2 {
				s[0] = v
				s = s[1:]
			} else {
				s[-1] = v
			}
			ip = ip[5:]
		case .get_length:
			o := s[-1]
			if o.tag != .object {break loop}
			p := as_obj(o)
			if !p.fast_array {break loop}
			i := shape_find(p.shape, pa(.A_length))
			if i < 0 || raw_data(p.shape.props)[i].kind != .data {break loop}
			s[-1] = p.slots[i].value
			ip = ip[1:]
		case .put_field:
			o := s[-2]
			if o.tag != .object {break loop}
			p := as_obj(o)
			a := Atom(rd32(ip[1:]))
			i := shape_find(p.shape, a)
			if i < 0 {break loop}
			sp_ := raw_data(p.shape.props)[i]
			if sp_.kind != .data || .writable not_in sp_.flags || (p.class == .array && a == pa(.A_length)) {break loop}
			p.slots[i].value = s[-1]
			s = intrinsics.ptr_offset(s, -2)
			ip = ip[5:]
		case:
			break loop
		}
	}
	return f, int(uintptr(ip) - uintptr(regs.code)), int(uintptr(s) - uintptr(regs.stack)) / size_of(Value), moved
}
