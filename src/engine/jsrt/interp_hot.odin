package jsrt

// The interpreter's hot loop.
//
// interp_run (interp.odin) is one very large procedure: with its hundreds of live values the code generator
// keeps `sp`, `locals`, `args`, `code` ... in stack slots and reloads them in every handler. The commonest
// instructions run here instead, in a loop whose few live values (ip, s, locals, args, the constant pool) stay
// in registers, with raw pointers instead of slices and indices (no bounds checks: the reader's verifier has
// checked every operand index, jump target and stack height).
//
// The loop itself calls nothing. Wasmtime's code saves no register across a Wasm call, so a value the loop
// carries across a call in one handler must be split around it or kept in a stack slot, and where the register
// allocator drew that line moved with any change of the code around the loop (round 13 of docs/performance.md:
// a test of one bit in a property lookup slowed every instruction by 12 %). What needs a call (a call
// instruction, a return, a getter, a lazy shape, an atom's number made a string) is a procedure of its own,
// never inlined, that reads and writes the loop's registers in a `Hot` in memory: they are written before the
// call and read back after it, so none of them lives across one. A loop that calls nothing is inlined into
// interp_run (#force_inline): the full dispatch and the loop then pass pc and sp without a call.
//
// Contract: run from (pc0, sp0) until an instruction this loop does not handle, or whose fast path does not
// apply (operand types, a due collection / interrupt at a back edge ...). The instruction has had NO effect
// then: the caller executes it with the full dispatch, and re-enters. Nothing here allocates; the natives it
// calls (call instructions, getters) run at a safepoint as call_native makes them, and back edges leave when a
// collection is due.

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

// What a property lookup of the loop found: a data property's value, an accessor's native getter for the caller to
// call (a DOM attribute), or something the loop leaves to a procedure that may call (a lazy shape) or to the full
// dispatch (a proxy, a host object whose class has exotic hooks ...).
@(private = "file")
Hot_Found :: enum u8 {
	value,
	getter,
	slow,
}

// Own property lookup, then the prototype chain of ordinary objects, calling nothing. `p` is the object of a lazy shape
// when the answer is .slow because of one (nil when the full dispatch must answer).
@(private = "file")
hot_find :: #force_inline proc "contextless" (o: ^Object, a: Atom) -> (v: Value, getter: ^Object, p: ^Object, found: Hot_Found) {
	p = o
	for {
		sh := p.shape
		if sh.lazy != nil {return {}, nil, p, .slow}
		i := shape_lookup(sh, a)
		if i >= 0 {
			#partial switch raw_data(sh.props)[i].kind {
			case .data: return p.slots[i].value, nil, p, .value
			case .accessor:
				g := p.slots[i].getset.getter
				if hot_native_getter(g) {return {}, g, p, .getter}
			}
			return {}, nil, nil, .slow
		}
		if p.fast_array || p.class == .proxy || p.class == .module_ns || p.class == .string || p.host_exotic || is_typed_array_class(p.class) {return {}, nil, nil, .slow}
		p = sh.proto
		if p == nil {return UNDEFINED, nil, nil, .value}
	}
}

// The lookup of hot_find from `p` on, the members of lazy shapes defined. ok = false for anything else (the full path
// handles it).
@(private = "file")
hot_find_slow :: proc "contextless" (p_in: ^Object, a: Atom) -> (v: Value, getter: ^Object, ok: bool) {
	p := p_in
	for {
		i := shape_find(p.shape, a)
		if i >= 0 {
			#partial switch raw_data(p.shape.props)[i].kind {
			case .data: return p.slots[i].value, nil, true
			case .accessor:
				g := p.slots[i].getset.getter
				return {}, g, hot_native_getter(g)
			}
			return
		}
		if p.fast_array || p.class == .proxy || p.class == .module_ns || p.class == .string || p.host_exotic || is_typed_array_class(p.class) {return}
		p = p.shape.proto
		if p == nil {return UNDEFINED, nil, true}
	}
}

// A getter the hot loop calls itself: a native function called as a function (call_native, as a call instruction does).
@(private = "file")
hot_native_getter :: #force_inline proc "contextless" (g: ^Object) -> bool {
	return g != nil && g.class == .c_function && !g.is_constructor && !g.ctor_only
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

// The loop's registers in memory, for the procedures that call: written before one runs, read back after.
@(private = "file")
Hot :: struct {
	ctx:    ^Context,
	rt:     ^Runtime,
	f:      ^Frame,
	ip:     [^]u8,
	s:      [^]Value, // the next free slot
	regs:   Hot_Regs,
	moved:  bool,
	thrown: bool,
}

// A call instruction (call0 ... call3, call, call_method): a native function called at once, its result replacing the
// callee and its arguments; a plain bytecode function's frame pushed and run by this loop. False: the loop stops
// (the instruction not run, or `thrown`, or a collection due on entering the new frame).
@(private = "file")
hot_call :: #force_no_inline proc(h: ^Hot, op: Opcode) -> bool {
	rt, ctx, f, ip, s := h.rt, h.ctx, h.f, h.ip, h.s
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
	if fv.tag != .object {return false}
	fo := as_obj(fv)
	if fo.class == .c_function {
		nd := &fo.data.(Native_Data)
		if fo.ctor_only || rt.stack_depth >= rt.config.max_stack_depth || stack_exhausted(rt) {return false}
		this := UNDEFINED
		slot := intrinsics.ptr_offset(first, -1)
		if op == .call_method {
			if !fo.is_constructor {this = first[-2]}
			slot = intrinsics.ptr_offset(first, -2)
		}
		h.ip = ip[isz:]
		f.pc = int(uintptr(h.ip) - uintptr(h.regs.code))
		r := call_native(ctx, fo, nd, this, first[:argc])
		if r.tag == .exception {
			h.thrown = true
			return false
		}
		slot[0] = r
		h.s = slot[1:]
		return true
	}
	if fo.class != .bytecode_function {return false}
	nb := fo.data.(Func_Data).bc
	if nb.func_kind != .normal || rt.stack_depth >= rt.config.max_stack_depth || (nb.realm != nil && nb.realm != ctx) {return false}
	this := UNDEFINED
	slot := intrinsics.ptr_offset(first, -1) // where the result goes
	if op == .call_method {
		this = first[-2]
		slot = intrinsics.ptr_offset(first, -2)
	}
	f.pc = int(uintptr(ip) - uintptr(h.regs.code)) + isz
	f.sp = int(uintptr(slot) - uintptr(h.regs.stack)) / size_of(Value)
	// (the frame to carry on in: the callee's, or this one when the callee's compiled code returned already)
	nf := frame_push(ctx, fo, this, first[:argc])
	h.f = nf
	h.moved = true
	h.regs = hot_regs(nf)
	h.ip = h.regs.code[nf.pc:]
	h.s = h.regs.stack[nf.sp:]
	// the entry safepoint (a collection due) is for interp_run: it sees pc == 0; so is an exception compiled code left pending
	return !gc_should_run(rt) && !nf.pending_throw && nf.recording == nil
}

// op_return / return_undef of a frame this loop pushed: back to its caller's frame.
@(private = "file")
hot_return :: #force_no_inline proc(h: ^Hot, op: Opcode) -> bool {
	f := h.f
	if !f.stackless {return false}
	ret := op == .op_return ? h.s[-1] : UNDEFINED
	c := frame_pop(h.rt, f)
	c.stack[c.sp] = ret
	c.sp += 1
	h.f = c
	h.moved = true
	h.regs = hot_regs(c)
	h.ip = h.regs.code[c.pc:]
	h.s = h.regs.stack[c.sp:]
	return c.recording == nil
}

// A native getter called where a lookup found it, with `this`, its value at `at`; `next` is the instruction after.
@(private = "file")
hot_getter :: proc(h: ^Hot, getter: ^Object, this: Value, at: ^Value, next: [^]u8) -> bool {
	rt := h.rt
	if rt.stack_depth >= rt.config.max_stack_depth || stack_exhausted(rt) {return false}
	h.f.pc = int(uintptr(next) - uintptr(h.regs.code))
	v := call_native(h.ctx, getter, &getter.data.(Native_Data), this, {})
	if v.tag == .exception {
		h.ip = next
		h.thrown = true
		return false
	}
	at^ = v
	return true
}

// get_field / get_field2 when the loop's lookup did not settle it: a getter it found (`getter`), or the lookup from
// `p` on (hot_find_slow), a getter it finds called too.
@(private = "file")
hot_get_field :: #force_no_inline proc(h: ^Hot, op: Opcode, getter_in: ^Object, p: ^Object) -> bool {
	ip, s := h.ip, h.s
	o := s[-1]
	getter := getter_in
	v: Value
	if getter == nil {
		if p == nil {return false}
		ok: bool
		v, getter, ok = hot_find_slow(p, Atom(rd32(ip[1:])))
		if !ok {return false}
	}
	at := op == .get_field2 ? &s[0] : &s[-1]
	if getter != nil {
		if !hot_getter(h, getter, o, at, ip[5:]) {return false}
	} else {
		at^ = v
	}
	if op == .get_field2 {h.s = s[1:]}
	h.ip = ip[5:]
	return true
}

// get_var of a global object's own accessor (window.document, [LegacyUnforgeable]): its native getter called here.
@(private = "file")
hot_get_var_getter :: #force_no_inline proc(h: ^Hot, getter: ^Object) -> bool {
	if !hot_native_getter(getter) {return false}
	ip, s := h.ip, h.s
	if !hot_getter(h, getter, mk_obj(h.ctx.global_obj), &s[0], ip[5:]) {return false}
	h.s = s[1:]
	h.ip = ip[5:]
	return true
}

// push_atom_value of an atom that is an integer: its string made.
@(private = "file")
hot_push_atom :: #force_no_inline proc(h: ^Hot) {
	h.s[0] = atom_to_value(h.rt, Atom(rd32(h.ip[1:])))
	h.s = h.s[1:]
	h.ip = h.ip[5:]
}

// Runs frame `f_in` from (pc0, sp0). Plain calls and returns between frames pushed by this very loop
// (Frame.stackless) are handled here too, so `f` of the result may be another frame than `f_in`; the
// returned pc / sp belong to it. `moved` says a frame was pushed or popped: `f` may then have the address of
// f_in (frame memory is reused) and still be another frame, so the pointer alone cannot tell. `thrown`: a native
// callee raised an exception; pc is past the call and sp still above its arguments, as the unwinder expects.
interp_hot :: #force_inline proc(ctx: ^Context, rt: ^Runtime, f_in: ^Frame, pc0: int, sp0: int) -> (f: ^Frame, pc: int, sp: int, moved: bool, thrown: bool) {
	h := Hot{ctx = ctx, rt = rt, f = f_in, regs = hot_regs(f_in)}
	regs := h.regs
	ip := regs.code[pc0:]
	s := regs.stack[sp0:]
	loop: for {
		op := Opcode(ip[0])
		#partial switch op {
		case .call0, .call1, .call2, .call3, .call, .call_method:
			h.ip, h.s = ip, s
			go := hot_call(&h, op)
			ip, s, regs = h.ip, h.s, h.regs
			if !go {break loop}
		case .op_return, .return_undef:
			h.ip, h.s = ip, s
			go := hot_return(&h, op)
			ip, s, regs = h.ip, h.s, h.regs
			if !go {break loop}
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
			s[0] = mk_str(h.rt.empty_string)
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
				if d < 0 && !hot_back_edge(&h, regs.root_base, intrinsics.ptr_offset(ip, 1 + d)) {break loop}
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
				if d < 0 && !hot_back_edge(&h, regs.root_base, intrinsics.ptr_offset(ip, 1 + d)) {break loop}
				ip = intrinsics.ptr_offset(ip, 1 + d)
			} else {
				ip = ip[5:]
			}
			s = intrinsics.ptr_offset(s, -1)
		case .goto8:
			d := int(i8(ip[1]))
			if d < 0 && !hot_back_edge(&h, regs.root_base, intrinsics.ptr_offset(ip, 1 + d)) {break loop}
			ip = intrinsics.ptr_offset(ip, 1 + d)
		case .goto16:
			d := int(i16(u16(rd16(ip[1:]))))
			if d < 0 && !hot_back_edge(&h, regs.root_base, intrinsics.ptr_offset(ip, 1 + d)) {break loop}
			ip = intrinsics.ptr_offset(ip, 1 + d)
		case .goto:
			d := int(i32(rd32(ip[1:])))
			if d < 0 && !hot_back_edge(&h, regs.root_base, intrinsics.ptr_offset(ip, 1 + d)) {break loop}
			ip = intrinsics.ptr_offset(ip, 1 + d)

		case .push_atom_value:
			a := Atom(rd32(ip[1:]))
			if atom_is_int(a) {
				h.ip, h.s = ip, s
				hot_push_atom(&h)
				ip, s, regs = h.ip, h.s, h.regs
				continue loop
			}
			e := &h.rt.atoms[a]
			if e.sym != nil {
				s[0] = mk_sym(e.sym)
			} else {
				if e.str == nil {break loop} // ATOM_NULL (only malformed bytecode asks)
				s[0] = mk_str(e.str)
			}
			s = s[1:]
			ip = ip[5:]
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
			cx := h.ctx
			gv := cx.global_var_obj
			if gv.shape.lazy != nil {break loop}
			i := len(gv.shape.props) != 0 ? shape_lookup(gv.shape, a) : -1
			if i >= 0 {
				v := gv.slots[i].value
				if v.tag == .uninitialized {break loop}
				s[0] = v
			} else {
				g := cx.global_obj
				if g.shape.lazy != nil {break loop}
				j := global_index(cx, g, a)
				if j < 0 {break loop}
				#partial switch raw_data(g.shape.props)[j].kind {
				case .data: s[0] = g.slots[j].value
				case .accessor:
					h.ip, h.s = ip, s
					go := hot_get_var_getter(&h, g.slots[j].getset.getter)
					ip, s, regs = h.ip, h.s, h.regs
					if !go {break loop}
					continue loop
				case: break loop
				}
			}
			s = s[1:]
			ip = ip[5:]
		case .put_var:
			a := Atom(rd32(ip[1:]))
			cx := h.ctx
			gv := cx.global_var_obj
			if gv.shape.lazy != nil {break loop}
			i := len(gv.shape.props) != 0 ? shape_lookup(gv.shape, a) : -1
			if i >= 0 {
				if gv.slots[i].value.tag == .uninitialized || .writable not_in raw_data(gv.shape.props)[i].flags {break loop}
				gv.slots[i].value = s[-1]
			} else {
				g := cx.global_obj
				if g.shape.lazy != nil {break loop}
				j := global_slot(cx, g, a)
				if j < 0 || .writable not_in raw_data(g.shape.props)[j].flags {break loop}
				g.slots[j].value = s[-1]
			}
			s = intrinsics.ptr_offset(s, -1)
			ip = ip[5:]
		case .get_field, .get_field2:
			o := s[-1]
			if o.tag != .object {break loop}
			v, getter, p, found := hot_find(as_obj(o), Atom(rd32(ip[1:])))
			if found != .value {
				h.ip, h.s = ip, s
				go := hot_get_field(&h, op, getter, p)
				ip, s, regs = h.ip, h.s, h.regs
				if !go {break loop}
				continue loop
			}
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
			if !p.fast_array || p.shape.lazy != nil {break loop}
			i := shape_lookup(p.shape, pa(.A_length))
			if i < 0 || raw_data(p.shape.props)[i].kind != .data {break loop}
			s[-1] = p.slots[i].value
			ip = ip[1:]
		case .put_field:
			o := s[-2]
			if o.tag != .object {break loop}
			p := as_obj(o)
			if p.shape.lazy != nil {break loop}
			a := Atom(rd32(ip[1:]))
			i := shape_lookup(p.shape, a)
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
	return h.f, int(uintptr(ip) - uintptr(regs.code)), int(uintptr(s) - uintptr(regs.stack)) / size_of(Value), h.moved, h.thrown
}

// Is the loop at target one the JIT took (out of line: only a function with a compiled loop asks)?
@(private = "file")
hot_jit_taken :: #force_no_inline proc "contextless" (h: ^Hot, target: [^]u8) -> bool {
	b := h.f.bc
	return jit_loop_taken(b.jit, int(uintptr(target) - uintptr(raw_data(b.code))))
}

// A back edge to `target`: false when the loop must leave (a loop the JIT compiled or is compiling, whose back edges go
// through the full dispatch, which offers them to the JIT; an interrupt to poll or a collection due). Calls nothing.
@(private = "file")
hot_back_edge :: #force_inline proc "contextless" (h: ^Hot, root_base: int, target: [^]u8) -> bool {
	if h.f.bc.jit_active != 0 && hot_jit_taken(h, target) {return false}
	rt := h.rt
	temp := cast(^runtime.Raw_Dynamic_Array)&rt.temp_roots
	if temp.len > root_base {temp.len = root_base}
	rt.interrupt_counter += 1
	return rt.interrupt_counter < INTERRUPT_POLL_EVERY && !gc_should_run(rt)
}
