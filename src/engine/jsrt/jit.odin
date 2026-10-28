package jsrt

// A loop JIT for the interpreter: a hot loop (found by sampling its back edges) is translated to a WebAssembly
// function that the host compiles (Cranelift) and attaches to the engine's own table; the interpreter then calls it
// like a C function pointer. WebAssembly stays the only execution engine: the generated code lives in the same
// sandbox as the engine and reaches only its memory (it is given the frame's argument, local and operand areas).
//
// What it compiles: the loop region [header, end of the back edge) of one function, entered at the header (on-stack
// replacement) from a frame whose locals the interpreter holds in memory. Locals and operand-stack entries the region
// uses as numbers are kept in Wasm locals (i32 for ints, f64 for doubles, i32 for bools; the types are speculated from
// the values the frame holds when the loop gets hot, widened int -> double when the region itself needs it), read once
// at entry (guarded by their tags) and written back when the code leaves. It never calls out and never allocates: an
// operation it cannot do inline (anything but number arithmetic, comparisons, branches, locals) keeps the loop from being
// compiled at all, and a speculation that fails at run time (int overflow, -0, a modulo of a negative number...) leaves
// through a deopt exit that stores the operand stack back in the frame and hands the interpreter the pc and sp of the
// instruction that was about to run. Exits: leaving the region, return, deopt, and every JIT_BUDGET iterations (so that
// the interpreter's safe point, interrupt poll and collection, still runs in a loop that does not end).
//
// Contract with the host: native/js/odin/jit.odin (the exports wj_jit_configure, wj_jit_stat) and the host's
// Engine_jitCompile / Engine_jitPoll (src/js/jit.odin: attach_function); the module imports the engine's memory
// ("e" "memory") and exports "f" (args, locals, stack) -> i64.

import "core:reflect"

JIT_STACK_MAX :: 32
JIT_BUDGET :: 16384
JIT_MAX_RESTARTS :: 4
JIT_MAX_LOOPS :: 4
JIT_MAX_REJITS :: 4

#assert(size_of(Value) == 16)
#assert(offset_of(Value, u) == 8)

Jit_Cfg :: struct {
	enabled:        bool,
	trace:          bool,
	max_code_bytes: int,
	compile:        proc "contextless" (module: [^]u8, n: u32) -> i32,   // Engine_jitCompile: a table index, 0 refused, < 0 a ticket
	poll:           proc "contextless" (ticket: i32) -> i32,             // Engine_jitPoll
	log:            proc(msg: string),
}

jit_cfg: Jit_Cfg

Jit_Stats :: struct {
	compiled, failed, refused, module_bytes, bytecode_bytes, entries, exits_leave, exits_return, exits_deopt, pending: f64,
}

jit_stats: Jit_Stats

Jit_Exit :: enum u8 {leave = 0, ret = 1, guard = 2, deopt = 3, budget = 4}

Jit_Loop_State :: enum u8 {fresh, pending, compiled, never}

Jit_Loop :: struct {
	header:     int,
	region_end: int,
	entry_sp:   int,
	state:      Jit_Loop_State,
	index:      u32,
	ticket:     i32,
	compiles:   int,
	deopts:     int,
	widen:      u64,   // slots (arguments, then locals) whose int speculation must be a double
	boxed:      u64,   // slots left to the interpreter's memory
}

Jit_Info :: struct {
	loops: [JIT_MAX_LOOPS]Jit_Loop,
	n:     int,
}

Jit_Resume :: enum u8 {none, resume, ret}

// I: an int32 (an Int in the interpreter); F: a double; B: a bool; L: an integer of at most 2^53 in magnitude, the exact
// result of an int +, - or * that may have left the int32 range (what the interpreter holds as a double, which a following
// `| 0` brings back; kept in an i64 so that code like (h + c) | 0 does not leave the loop at each overflow)
Jit_Ty :: enum u8 {I, F, B, L}

Jit_State :: struct {
	n: int,
	t: [JIT_STACK_MAX]Jit_Ty,
}

Jit_Slot_Kind :: enum u8 {unused, box, i32, f64}

@(private = "file")
jr_u16 :: #force_inline proc "contextless" (c: []u8, p: int) -> int {
	return int(c[p]) | int(c[p + 1]) << 8
}

@(private = "file")
jr_i32 :: #force_inline proc "contextless" (c: []u8, p: int) -> int {
	return int(i32(u32(c[p]) | u32(c[p + 1]) << 8 | u32(c[p + 2]) << 16 | u32(c[p + 3]) << 24))
}

jit_configure :: proc(enabled: bool, compile: proc "contextless" (module: [^]u8, n: u32) -> i32, poll: proc "contextless" (ticket: i32) -> i32, log: proc(msg: string)) {
	jit_cfg.enabled = enabled && compile != nil && ODIN_ARCH == .wasm32
	jit_cfg.compile = compile
	jit_cfg.poll = poll
	jit_cfg.log = log
	jit_cfg.trace = log != nil
	if jit_cfg.max_code_bytes == 0 {jit_cfg.max_code_bytes = 64 << 10}
}

jit_stat :: proc "contextless" (which: int) -> f64 {
	s := jit_stats
	switch which {
	case 0: return s.compiled
	case 1: return s.failed
	case 2: return s.refused
	case 3: return s.module_bytes
	case 4: return s.bytecode_bytes
	case 5: return 0
	case 6: return s.entries
	case 7: return s.exits_return
	case 8: return s.exits_leave
	case 9: return s.exits_deopt
	case 10: return 0
	case 11: return s.pending
	case 12: return s.entries
	}
	return -1
}

jit_trace :: proc(msg: string) {
	if jit_cfg.trace && jit_cfg.log != nil {jit_cfg.log(msg)}
}

// ---------------------------------------------------------------------------------------------------------------------
// The interpreter's side

// Called by the interpreter when a backward jump to `target` was taken (the instruction ended at `region_end`), after its
// safe point. Compiles the loop when it is first seen hot, and runs the compiled code. Resume: carry on at (pc, sp) in
// the interpreter. Ret: the function returns the value in f.stack[0].
jit_back_edge :: proc(ctx: ^Context, f: ^Frame, b: ^Function_Bytecode, target, region_end, sp: int) -> (res: Jit_Resume, pc: int, nsp: int) {
	when ODIN_ARCH != .wasm32 {
		return .none, 0, 0
	} else {
		if !jit_cfg.enabled || b.func_kind != .normal || len(b.code) > jit_cfg.max_code_bytes {return .none, 0, 0}
		rt := ctx.rt
		if b.jit == nil {b.jit = new(Jit_Info, rt_allocator(rt))}
		info := b.jit
		jl: ^Jit_Loop
		for i in 0 ..< info.n {
			if info.loops[i].header == target {
				jl = &info.loops[i]
				break
			}
		}
		if jl == nil {
			if info.n >= JIT_MAX_LOOPS {return .none, 0, 0}
			info.loops[info.n] = Jit_Loop{header = target, region_end = region_end, entry_sp = sp}
			jl = &info.loops[info.n]
			info.n += 1
		}
		switch jl.state {
		case .never:
			return .none, 0, 0
		case .fresh:
			jit_build(ctx, f, b, jl, sp)
			if jl.state != .compiled {return .none, 0, 0}
		case .pending:
			idx := jit_cfg.poll(jl.ticket)
			if idx < 0 {return .none, 0, 0}
			if idx == 0 {
				jl.state = .never
				jit_stats.failed += 1
				return .none, 0, 0
			}
			jl.index = u32(idx)
			jl.state = .compiled
			b.jit_active += 1
			jit_stats.pending -= 1
		case .compiled:
		}
		if sp != jl.entry_sp {return .none, 0, 0}

		Jit_Fn :: #type proc "c" (args: [^]Value, locals: [^]Value, stack: [^]Value) -> u64
		fn := transmute(Jit_Fn)uintptr(jl.index)
		jit_stats.entries += 1
		r := fn(f.args, f.locals, f.stack)
		kind := Jit_Exit((r >> 24) & 0xff)
		xpc := int(r & 0xffffff)
		xsp := int((r >> 32) & 0xffff)
		aux := int(r >> 48)
		switch kind {
		case .leave:
			jit_stats.exits_leave += 1
			return .resume, xpc, xsp
		case .ret:
			jit_stats.exits_return += 1
			return .ret, 0, 0
		case .budget:
			rt.interrupt_counter = 10_000
			return .resume, xpc, xsp
		case .guard:
			jit_stats.exits_deopt += 1
			jit_invalidate(f, b, jl, aux, true)
			return .none, 0, 0
		case .deopt:
			jit_stats.exits_deopt += 1
			jl.deopts += 1
			jit_invalidate(f, b, jl, aux, false)
			return .resume, xpc, xsp
		}
		return .none, 0, 0
	}
}

// A speculation failed: at the entry (the frame's value in `slot` has another type) or inside the loop (`slot` = the
// slot to widen, 0xffff none). Compile it again with what was learned, a few times, then leave the loop interpreted.
@(private = "file")
jit_invalidate :: proc(f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop, slot: int, at_entry: bool) {
	if at_entry && slot < 64 {
		v := jit_slot_value(f, slot)
		bit := u64(1) << uint(slot)
		if v.tag == .float || v.tag == .int {jl.widen |= bit} else {jl.boxed |= bit}
	} else if !at_entry && slot < 64 {
		jl.widen |= u64(1) << uint(slot)
	}
	if jl.deopts > 16 || jl.compiles >= JIT_MAX_REJITS {
		jl.state = .never
		b.jit_active -= 1
		return
	}
	if at_entry || slot != 0xffff {
		jl.state = .fresh
		b.jit_active -= 1
	}
}

@(private = "file")
jit_slot_value :: proc(f: ^Frame, slot: int) -> Value {
	na := int(f.bc.arg_count)
	if slot < na {return f.args[slot]}
	return f.locals[slot - na]
}

// ---------------------------------------------------------------------------------------------------------------------
// Translation

Jc :: struct {
	rt:        ^Runtime,
	b:         ^Function_Bytecode,
	jl:        ^Jit_Loop,
	code:      []u8,
	header:    int,
	rend:      int,
	entry_sp:  int,
	nargs:     int,
	nslots:    int,
	skind:     []Jit_Slot_Kind,
	ref:       []bool,
	written:   []bool,
	wl:        []u32,
	ss:        int,
	si0:       u32,
	sf0:       u32,
	sl0:       u32,
	ft0:       u32,
	r64:       u32,
	ni, nf:    u32,
	out:       Wbuf,
	lidx:      []i32,
	nleaders:  int,
	lstate:    []Jit_State,
	lvalid:    []bool,
	nblocks:   int,
	cur:       int,
	nest:      int,
	st:        Jit_State,
	fail:      bool,
	why:       string,
	restart:   bool,
}

// the function's parameters and fixed locals
P_ARGS :: 0
P_LOCALS :: 1
P_STACK :: 2
I_PC :: 3
I_SP :: 4
I_KIND :: 5
I_AUX :: 6
I_BUDGET :: 7
I_T0 :: 8
I_T1 :: 9
I_FIRST :: 10

Jit_Outcome :: enum u8 {ok, refuse, restart}

@(private = "file")
j_fail :: proc(c: ^Jc, why: string) {
	if !c.fail {c.fail = true; c.why = why}
}

@(private = "file")
j_op :: #force_inline proc(c: ^Jc, op: u8) {append(&c.out, op)}

@(private = "file")
j_lget :: proc(c: ^Jc, i: u32) {
	append(&c.out, W_LOCAL_GET)
	w_uleb(&c.out, u64(i))
}

@(private = "file")
j_lset :: proc(c: ^Jc, i: u32) {
	append(&c.out, W_LOCAL_SET)
	w_uleb(&c.out, u64(i))
}

@(private = "file")
j_i32 :: proc(c: ^Jc, v: i32) {
	append(&c.out, W_I32_CONST)
	w_sleb(&c.out, i64(v))
}

@(private = "file")
j_f64 :: proc(c: ^Jc, v: f64) {
	append(&c.out, W_F64_CONST)
	bits := transmute(u64)v
	for i in 0 ..< 8 {append(&c.out, u8(bits >> (8 * uint(i))))}
}

@(private = "file")
j_mem :: proc(c: ^Jc, op: u8, align: u64, off: u32) {
	append(&c.out, op)
	w_uleb(&c.out, align)
	w_uleb(&c.out, u64(off))
}

@(private = "file")
j_si :: #force_inline proc(c: ^Jc, d: int) -> u32 {return c.si0 + u32(d)}

@(private = "file")
j_sf :: #force_inline proc(c: ^Jc, d: int) -> u32 {return c.sf0 + u32(d)}

@(private = "file")
j_sloc :: #force_inline proc(c: ^Jc, d: int, t: Jit_Ty) -> u32 {
	switch t {
	case .F: return c.sf0 + u32(d)
	case .L: return c.sl0 + u32(d)
	case .I, .B: return c.si0 + u32(d)
	}
	return 0
}

// the scratch local of a type (a: 0 or 1)
@(private = "file")
j_scratch :: #force_inline proc(c: ^Jc, t: Jit_Ty, a: u32) -> u32 {
	switch t {
	case .F: return c.ft0 + a
	case .L: return c.r64 + a
	case .I, .B: return I_T0 + a
	}
	return 0
}

@(private = "file")
j_push :: proc(c: ^Jc, t: Jit_Ty) -> int {
	if c.st.n >= c.ss {
		j_fail(c, "operand stack too deep")
		return 0
	}
	c.st.t[c.st.n] = t
	c.st.n += 1
	return c.st.n - 1
}

@(private = "file")
j_is_num :: #force_inline proc(t: Jit_Ty) -> bool {return t != .B}

// the stack entry d as a double on the Wasm stack
@(private = "file")
j_get_f :: proc(c: ^Jc, d: int) {
	switch c.st.t[d] {
	case .F:
		j_lget(c, j_sf(c, d))
	case .L:
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_F64_CONVERT_I64_S)
	case .I, .B:
		j_lget(c, j_si(c, d))
		j_op(c, W_F64_CONVERT_I32_S)
	}
}

// the stack entry d (an I or an L) as an i64 on the Wasm stack
@(private = "file")
j_get_i64 :: proc(c: ^Jc, d: int) {
	if c.st.t[d] == .L {
		j_lget(c, c.sl0 + u32(d))
	} else {
		j_lget(c, j_si(c, d))
		j_op(c, W_I64_EXTEND_I32_S)
	}
}

// the i64 on the Wasm stack is out of the exact range (|v| > 2^53): the condition for a deopt
@(private = "file")
j_l_out_of_range :: proc(c: ^Jc) {
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 1 << 53)
	j_op(c, W_I64_ADD)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 1 << 54)
	j_op(c, W_I64_GT_U)
}

// the L entry d does not fit an int32: the condition for a deopt
@(private = "file")
j_l_not_i32 :: proc(c: ^Jc, d: int) {
	j_lget(c, c.sl0 + u32(d))
	j_op(c, W_I32_WRAP_I64)
	j_op(c, W_I64_EXTEND_I32_S)
	j_lget(c, c.sl0 + u32(d))
	j_op(c, W_I64_NE)
}

// the address of a frame slot: the base parameter and the byte offset
@(private = "file")
j_slot_addr :: proc(c: ^Jc, s: int) -> (base: u32, off: u32) {
	if s < c.nargs {return P_ARGS, u32(s * 16)}
	return P_LOCALS, u32((s - c.nargs) * 16)
}

@(private = "file")
j_store_tag :: proc(c: ^Jc, base: u32, off: u32, tag: Tag) {
	j_lget(c, base)
	j_i32(c, i32(tag))
	j_mem(c, W_I32_STORE8, 0, off)
}

// the stack entries back into the frame's operand stack
@(private = "file")
j_materialize :: proc(c: ^Jc) {
	for d in 0 ..< c.st.n {
		j_store_entry(c, d, P_STACK, u32(d * 16), true)
	}
}

@(private = "file")
j_exit_depth :: proc(c: ^Jc) -> u64 {return u64(c.nest + (c.nblocks - c.cur) + 1)}

@(private = "file")
j_loop_depth :: proc(c: ^Jc) -> u64 {return u64(c.nest + (c.nblocks - c.cur))}

// leave the loop with the current stack, to resume at `pc`
@(private = "file")
j_stub :: proc(c: ^Jc, pc: int, kind: Jit_Exit, aux: u32) {
	j_materialize(c)
	j_i32(c, i32(pc))
	j_lset(c, I_PC)
	j_i32(c, i32(c.st.n))
	j_lset(c, I_SP)
	j_i32(c, i32(kind))
	j_lset(c, I_KIND)
	j_i32(c, i32(aux))
	j_lset(c, I_AUX)
	j_op(c, W_BR)
	w_uleb(&c.out, j_exit_depth(c))
}

// the condition (i32) is on the Wasm stack: when true, leave through a deopt at the instruction at `pc`
@(private = "file")
j_deopt_if :: proc(c: ^Jc, pc: int, aux: u32 = 0xffff) {
	j_op(c, W_IF)
	j_op(c, W_VOID)
	c.nest += 1
	j_stub(c, pc, .deopt, aux)
	j_op(c, W_END)
	c.nest -= 1
}

@(private = "file")
j_state_eq :: proc(a, b: ^Jit_State) -> bool {
	if a.n != b.n {return false}
	for i in 0 ..< a.n {if a.t[i] != b.t[i] {return false}}
	return true
}

// ToInt32 of the stack entry d, on the Wasm stack (a double outside the int32 range leaves through a deopt)
@(private = "file")
j_get_i32 :: proc(c: ^Jc, d: int, pc: int) {
	if c.st.t[d] == .I {
		j_lget(c, j_si(c, d))
		return
	}
	if c.st.t[d] == .L {
		// an exact integer: ToInt32 is its low 32 bits
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I32_WRAP_I64)
		return
	}
	j_lget(c, j_sf(c, d))
	j_f64(c, -2147483649.0)
	j_op(c, W_F64_GT)
	j_lget(c, j_sf(c, d))
	j_f64(c, 2147483648.0)
	j_op(c, W_F64_LT)
	j_op(c, W_I32_AND)
	j_op(c, W_I32_EQZ)
	j_deopt_if(c, pc)
	j_lget(c, j_sf(c, d))
	j_op(c, 0xFC)
	w_uleb(&c.out, 2)   // i32.trunc_sat_f64_s
}

// ToBoolean of the stack entry d (i32 on the Wasm stack)
@(private = "file")
j_get_bool :: proc(c: ^Jc, d: int) {
	if c.st.t[d] == .L {
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I64_CONST)
		w_sleb(&c.out, 0)
		j_op(c, W_I64_NE)
		return
	}
	if c.st.t[d] != .F {
		j_lget(c, j_sloc(c, d, c.st.t[d]))
		return
	}
	j_lget(c, j_sf(c, d))
	j_f64(c, 0)
	j_op(c, W_F64_NE)
	j_lget(c, j_sf(c, d))
	j_lget(c, j_sf(c, d))
	j_op(c, W_F64_EQ)
	j_op(c, W_I32_AND)
}

// the slot a local/argument instruction names; write: it stores into the slot
@(private = "file")
jit_op_slot :: proc(op: Opcode, code: []u8, pc: int, nargs: int) -> (slot: int, write: bool, ok: bool) {
	#partial switch op {
	case .get_loc, .get_loc_check: return nargs + jr_u16(code, pc + 1), false, true
	case .put_loc, .set_loc, .put_loc_check: return nargs + jr_u16(code, pc + 1), true, true
	case .get_loc8: return nargs + int(code[pc + 1]), false, true
	case .put_loc8, .set_loc8: return nargs + int(code[pc + 1]), true, true
	case .get_loc0, .get_loc1, .get_loc2, .get_loc3: return nargs + int(op) - int(Opcode.get_loc0), false, true
	case .put_loc0, .put_loc1, .put_loc2, .put_loc3: return nargs + int(op) - int(Opcode.put_loc0), true, true
	case .set_loc0, .set_loc1, .set_loc2, .set_loc3: return nargs + int(op) - int(Opcode.set_loc0), true, true
	case .get_arg: return jr_u16(code, pc + 1), false, true
	case .put_arg, .set_arg: return jr_u16(code, pc + 1), true, true
	case .get_arg0, .get_arg1, .get_arg2, .get_arg3: return int(op) - int(Opcode.get_arg0), false, true
	case .put_arg0, .put_arg1, .put_arg2, .put_arg3: return int(op) - int(Opcode.put_arg0), true, true
	case .set_arg0, .set_arg1, .set_arg2, .set_arg3: return int(op) - int(Opcode.set_arg0), true, true
	case .inc_loc, .dec_loc, .add_loc: return nargs + int(code[pc + 1]), true, true
	}
	return 0, false, false
}

// the target of a jump instruction; cond: 0 unconditional, 1 when true, 2 when false
@(private = "file")
jit_jump :: proc(op: Opcode, code: []u8, pc: int) -> (target: int, cond: int, ok: bool) {
	#partial switch op {
	case .goto: return pc + 1 + jr_i32(code, pc + 1), 0, true
	case .goto8: return pc + 1 + int(i8(code[pc + 1])), 0, true
	case .goto16: return pc + 1 + int(i16(u16(jr_u16(code, pc + 1)))), 0, true
	case .if_true: return pc + 1 + jr_i32(code, pc + 1), 1, true
	case .if_false: return pc + 1 + jr_i32(code, pc + 1), 2, true
	case .if_true8: return pc + 1 + int(i8(code[pc + 1])), 1, true
	case .if_false8: return pc + 1 + int(i8(code[pc + 1])), 2, true
	}
	return 0, 0, false
}

// Builds the module for the loop and hands it to the host.
@(private = "file")
jit_build :: proc(ctx: ^Context, f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop, sp: int) {
	rt := ctx.rt
	saved := context.allocator
	context.allocator = tmp(rt)
	defer context.allocator = saved
	if jl.compiles >= JIT_MAX_REJITS + 1 {
		jl.state = .never
		return
	}
	jl.compiles += 1
	for _ in 0 ..< JIT_MAX_RESTARTS {
		c := Jc{rt = rt, b = b, jl = jl, code = b.code, header = jl.header, rend = jl.region_end, entry_sp = sp}
		out := jit_translate(&c, f)
		switch out {
		case .restart:
			continue
		case .refuse:
			jit_stats.refused += 1
			jl.state = .never
			if jit_cfg.trace {
				jit_trace(cat(ctx, "jit: refused ", atom_utf8(rt, b.func_name), " loop at ", int_str(jl.header), ": ", c.why))
			}
			return
		case .ok:
			idx := jit_cfg.compile(raw_data(c.out), u32(len(c.out)))
			if idx == 0 {
				jit_stats.failed += 1
				jl.state = .never
				jit_trace("jit: the host refused the module")
				return
			}
			jit_stats.compiled += 1
			jit_stats.module_bytes += f64(len(c.out))
			jit_stats.bytecode_bytes += f64(jl.region_end - jl.header)
			if idx < 0 {
				jl.state = .pending
				jl.ticket = -idx
				jit_stats.pending += 1
				return
			}
			jl.index = u32(idx)
			jl.state = .compiled
			b.jit_active += 1
			if jit_cfg.trace {
				jit_trace(cat(ctx, "jit: compiled ", atom_utf8(rt, b.func_name), " loop at ", int_str(jl.header), " (", int_str(len(c.out)), " bytes)"))
			}
			return
		}
	}
	jl.state = .never
}

@(private = "file")
int_str :: proc(n: int) -> string {
	buf: [24]u8
	i := len(buf)
	neg := n < 0
	v := neg ? -n : n
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	return string(clone_bytes(buf[i:]))
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	r := make([]u8, len(b))
	copy(r, b)
	return r
}

@(private = "file")
jit_translate :: proc(c: ^Jc, f: ^Frame) -> Jit_Outcome {
	b := c.b
	code := c.code
	c.nargs = int(b.arg_count)
	c.nslots = c.nargs + int(b.var_count)
	if c.rend > len(code) || c.header < 0 || c.header >= c.rend {
		j_fail(c, "bad region")
		return .refuse
	}
	if c.entry_sp > JIT_STACK_MAX {
		j_fail(c, "deep operand stack at the loop")
		return .refuse
	}
	c.ss = min(max(int(b.stack_size), 1), JIT_STACK_MAX)
	c.skind = make([]Jit_Slot_Kind, c.nslots)
	c.ref = make([]bool, c.nslots)
	c.written = make([]bool, c.nslots)
	c.wl = make([]u32, c.nslots)
	c.lidx = make([]i32, c.rend - c.header + 1)
	for i in 0 ..< len(c.lidx) {c.lidx[i] = -1}

	// pass 1: the region's instructions, the slots they use, the leaders
	leader := make([]bool, c.rend - c.header + 1)
	leader[0] = true
	pc := c.header
	for pc < c.rend {
		opb := code[pc]
		if int(opb) >= OPCODE_COUNT {
			j_fail(c, "bad opcode")
			return .refuse
		}
		op := Opcode(opb)
		size := int(opcode_info[op].size)
		if pc + size > c.rend {
			j_fail(c, "region ends inside an instruction")
			return .refuse
		}
		if op == .get_loc0_loc1 {
			for k in 0 ..< 2 {
				if c.nargs + k < c.nslots {c.ref[c.nargs + k] = true}
			}
		}
		if s, w, ok := jit_op_slot(op, code, pc, c.nargs); ok {
			if s >= c.nslots {
				j_fail(c, "slot out of range")
				return .refuse
			}
			c.ref[s] = true
			if w {c.written[s] = true}
		}
		if t, _, ok := jit_jump(op, code, pc); ok {
			if t <= pc && t != c.header {
				j_fail(c, "nested loop")
				return .refuse
			}
			if t >= c.header && t < c.rend {leader[t - c.header] = true}
			if pc + size < c.rend {leader[pc + size - c.header] = true}
		}
		pc += size
	}
	if pc != c.rend {
		j_fail(c, "region does not end on an instruction")
		return .refuse
	}
	n := 0
	for i in 0 ..< c.rend - c.header {
		if leader[i] {
			c.lidx[i] = i32(n)
			n += 1
		}
	}
	c.nleaders = n
	c.nblocks = n - 1
	c.lstate = make([]Jit_State, n)
	c.lvalid = make([]bool, n)

	// the speculated type of each slot the region uses
	n_i, n_f: u32
	for s in 0 ..< c.nslots {
		if !c.ref[s] {continue}
		v := jit_slot_value(f, s)
		kind := Jit_Slot_Kind.box
		if c.jl.boxed & (u64(1) << uint(s)) != 0 && s < 64 {
			kind = .box
		} else if v.tag == .int {
			kind = (s < 64 && c.jl.widen & (u64(1) << uint(s)) != 0) ? .f64 : .i32
		} else if v.tag == .float {
			kind = .f64
		}
		c.skind[s] = kind
	}
	for s in 0 ..< c.nslots {
		#partial switch c.skind[s] {
		case .i32:
			c.wl[s] = u32(I_FIRST) + n_i
			n_i += 1
		case .f64:
			c.wl[s] = n_f
			n_f += 1
		}
	}
	// entry stack types from the frame
	c.st.n = c.entry_sp
	for d in 0 ..< c.entry_sp {
		switch f.stack[d].tag {
		case .int: c.st.t[d] = .I
		case .float: c.st.t[d] = .F
		case .bool: c.st.t[d] = .B
		case .undefined, .null, .string, .symbol, .object, .bigint, .function_bc, .module, .uninitialized, .exception, .catch_offset:
			j_fail(c, "operand stack holds a non-number at the loop")
			return .refuse
		}
	}
	c.lstate[0] = c.st
	c.lvalid[0] = true

	// the Wasm locals: i32 [fixed][slots][stack], i64 [2], f64 [slots][stack][2]
	c.si0 = u32(I_FIRST) + n_i
	c.ni = c.si0 + u32(c.ss) - 3   // (the parameters take 3 indices: count the declared i32 locals)
	c.sl0 = c.si0 + u32(c.ss)      // the i64 locals: one per stack entry (type L), then 2 scratch
	c.r64 = c.sl0 + u32(c.ss)
	c.nf = n_f + u32(c.ss) + 2
	// the f64 group follows the i64 locals; the slots' f64 indices are relative to it so far
	fbase := c.r64 + 2
	for s in 0 ..< c.nslots {
		if c.skind[s] == .f64 {c.wl[s] += fbase}
	}
	c.sf0 = fbase + n_f
	c.ft0 = c.sf0 + u32(c.ss)

	jit_emit(c, f)
	if c.restart {return .restart}
	if c.fail {return .refuse}
	return .ok
}

@(private = "file")
jit_emit :: proc(c: ^Jc, f: ^Frame) {
	code := c.code
	// -- the module around the function
	m: Wbuf
	sec: Wbuf
	append(&m, 0, 'a', 's', 'm', 1, 0, 0, 0)
	// types: 0 = (i32 i32 i32) -> i64
	w_uleb(&sec, 1)
	w_u8(&sec, 0x60)
	w_uleb(&sec, 3)
	w_u8(&sec, W_I32)
	w_u8(&sec, W_I32)
	w_u8(&sec, W_I32)
	w_uleb(&sec, 1)
	w_u8(&sec, W_I64)
	w_section(&m, 1, &sec)
	// imports: the engine's memory
	w_uleb(&sec, 1)
	w_name(&sec, "e")
	w_name(&sec, "memory")
	w_u8(&sec, 0x02)
	w_u8(&sec, 0x00)
	w_uleb(&sec, 0)
	w_section(&m, 2, &sec)
	// one function, exported as "f"
	w_uleb(&sec, 1)
	w_uleb(&sec, 0)
	w_section(&m, 3, &sec)
	w_uleb(&sec, 1)
	w_name(&sec, "f")
	w_u8(&sec, 0x00)
	w_uleb(&sec, 0)
	w_section(&m, 7, &sec)

	// -- the entry: guards and loads
	for s in 0 ..< c.nslots {
		kind := c.skind[s]
		if kind != .i32 && kind != .f64 {continue}
		base, off := j_slot_addr(c, s)
		j_lget(c, base)
		j_mem(c, W_I32_LOAD8_U, 0, off)
		if kind == .i32 {
			j_i32(c, i32(Tag.int))
			j_op(c, W_I32_NE)
			j_ret_if(c, c.header, .guard, u32(s))
			j_lget(c, base)
			j_mem(c, W_I32_LOAD, 2, off + 8)
			j_lset(c, c.wl[s])
		} else {
			j_i32(c, i32(Tag.float))
			j_op(c, W_I32_EQ)
			j_op(c, W_IF)
			j_op(c, W_F64)
			j_lget(c, base)
			j_mem(c, W_F64_LOAD, 3, off + 8)
			j_op(c, W_ELSE)
			j_lget(c, base)
			j_mem(c, W_I32_LOAD8_U, 0, off)
			j_i32(c, i32(Tag.int))
			j_op(c, W_I32_NE)
			j_ret_if(c, c.header, .guard, u32(s))
			j_lget(c, base)
			j_mem(c, W_I32_LOAD, 2, off + 8)
			j_op(c, W_F64_CONVERT_I32_S)
			j_op(c, W_END)
			j_lset(c, c.wl[s])
		}
	}
	for d in 0 ..< c.entry_sp {
		t := c.st.t[d]
		off := u32(d * 16)
		j_lget(c, P_STACK)
		j_mem(c, W_I32_LOAD8_U, 0, off)
		j_i32(c, i32(t == .I ? Tag.int : t == .F ? Tag.float : Tag.bool))
		j_op(c, W_I32_NE)
		j_ret_if(c, c.header, .guard, 0xffff)
		j_lget(c, P_STACK)
		switch t {
		case .I:
			j_mem(c, W_I32_LOAD, 2, off + 8)
			j_lset(c, j_si(c, d))
		case .F:
			j_mem(c, W_F64_LOAD, 3, off + 8)
			j_lset(c, j_sf(c, d))
		case .B:
			j_mem(c, W_I32_LOAD8_U, 0, off + 8)
			j_lset(c, j_si(c, d))
		case .L:
			j_op(c, W_UNREACHABLE)   // (no entry stack entry has this type)
		}
	}
	j_i32(c, JIT_BUDGET)
	j_lset(c, I_BUDGET)

	// -- the structure: block $exit, loop $top, one block per leader but the first
	j_op(c, W_BLOCK)
	j_op(c, W_VOID)
	j_op(c, W_LOOP)
	j_op(c, W_VOID)
	for _ in 0 ..< c.nblocks {
		j_op(c, W_BLOCK)
		j_op(c, W_VOID)
	}
	c.cur = 0
	c.nest = 0
	valid := true
	pc := c.header
	for pc < c.rend && !c.fail && !c.restart {
		op := Opcode(code[pc])
		size := int(opcode_info[op].size)
		k := int(c.lidx[pc - c.header])
		if k > 0 {
			if valid {
				if c.lvalid[k] {
					if !j_state_eq(&c.lstate[k], &c.st) {
						j_fail(c, "operand stack types differ at a join")
						break
					}
				} else {
					c.lstate[k] = c.st
					c.lvalid[k] = true
				}
			}
			j_op(c, W_END)
			c.cur = k
			valid = c.lvalid[k]
			if valid {c.st = c.lstate[k]}
		}
		if !valid {
			pc += size
			continue
		}
		valid = jit_insn(c, f, op, pc)
		pc += size
	}
	if c.fail || c.restart {return}
	if valid {
		// falls out of the region
		j_stub(c, c.rend, .leave, 0)
	}
	j_op(c, W_END)   // loop
	j_op(c, W_END)   // block $exit

	// -- the exit: the slots the loop wrote go back to the frame, the result is the exit word
	for s in 0 ..< c.nslots {
		kind := c.skind[s]
		if (kind != .i32 && kind != .f64) || !c.written[s] {continue}
		base, off := j_slot_addr(c, s)
		j_store_tag(c, base, off, kind == .i32 ? .int : .float)
		j_lget(c, base)
		j_lget(c, c.wl[s])
		if kind == .f64 {j_mem(c, W_F64_STORE, 3, off + 8)} else {j_mem(c, W_I32_STORE, 2, off + 8)}
	}
	j_lget(c, I_AUX)
	j_op(c, W_I64_EXTEND_I32_U)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 48)
	j_op(c, W_I64_SHL)
	j_lget(c, I_SP)
	j_op(c, W_I64_EXTEND_I32_U)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 32)
	j_op(c, W_I64_SHL)
	j_op(c, W_I64_OR)
	j_lget(c, I_KIND)
	j_op(c, W_I64_EXTEND_I32_U)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 24)
	j_op(c, W_I64_SHL)
	j_op(c, W_I64_OR)
	j_lget(c, I_PC)
	j_op(c, W_I64_EXTEND_I32_U)
	j_op(c, W_I64_OR)
	j_op(c, W_END)   // function

	// -- code section
	body: Wbuf
	w_uleb(&body, 3)
	w_uleb(&body, u64(c.ni))
	w_u8(&body, W_I32)
	w_uleb(&body, u64(c.ss + 2))
	w_u8(&body, W_I64)
	w_uleb(&body, u64(c.nf))
	w_u8(&body, W_F64)
	for x in c.out {append(&body, x)}
	w_uleb(&sec, 1)
	w_uleb(&sec, u64(len(body)))
	for x in body {append(&sec, x)}
	w_section(&m, 10, &sec)
	c.out = m
}

// the condition is on the Wasm stack: when true, return the exit word at once (the entry guards)
@(private = "file")
j_ret_if :: proc(c: ^Jc, pc: int, kind: Jit_Exit, aux: u32) {
	j_op(c, W_IF)
	j_op(c, W_VOID)
	j_op(c, W_I64_CONST)
	word := u64(pc) | u64(kind) << 24 | u64(c.entry_sp) << 32 | u64(aux & 0xffff) << 48
	w_sleb(&c.out, i64(word))
	j_op(c, W_RETURN)
	j_op(c, W_END)
}

// a store of the stack entry d into frame memory (a slot the loop leaves to the interpreter)
@(private = "file")
j_store_entry :: proc(c: ^Jc, d: int, base: u32, off: u32, exiting := false) {
	t := c.st.t[d]
	switch t {
	case .I:
		j_store_tag(c, base, off, .int)
		j_lget(c, base)
		j_lget(c, j_si(c, d))
		j_mem(c, W_I32_STORE, 2, off + 8)
	case .B:
		j_store_tag(c, base, off, .bool)
		j_lget(c, base)
		j_lget(c, j_si(c, d))
		j_mem(c, W_I32_STORE, 2, off + 8)
	case .F:
		j_store_tag(c, base, off, .float)
		j_lget(c, base)
		j_lget(c, j_sf(c, d))
		j_mem(c, W_F64_STORE, 3, off + 8)
	case .L:
		// leaving: a double (what the interpreter would hold); into a local the loop leaves to the interpreter: it
		// must fit an int32, or the instruction is left to the interpreter
		if exiting {
			j_store_tag(c, base, off, .float)
			j_lget(c, base)
			j_lget(c, c.sl0 + u32(d))
			j_op(c, W_F64_CONVERT_I64_S)
			j_mem(c, W_F64_STORE, 3, off + 8)
		} else {
			j_store_tag(c, base, off, .int)
			j_lget(c, base)
			j_lget(c, c.sl0 + u32(d))
			j_op(c, W_I32_WRAP_I64)
			j_mem(c, W_I32_STORE, 2, off + 8)
		}
	}
}

// A jump to `target`; the condition (i32, true = jump) is on the Wasm stack when cond != 0 (already negated for
// if_false). Returns whether the code after it is reachable.
@(private = "file")
j_jump :: proc(c: ^Jc, pc: int, target: int, conditional: bool) -> bool {
	if target < c.header || target >= c.rend {
		// leaves the region
		if conditional {
			j_op(c, W_IF)
			j_op(c, W_VOID)
			c.nest += 1
			j_stub(c, target, .leave, 0)
			j_op(c, W_END)
			c.nest -= 1
			return true
		}
		j_stub(c, target, .leave, 0)
		return false
	}
	j := int(c.lidx[target - c.header])
	if j < 0 {
		j_fail(c, "jump into the middle of a block")
		return false
	}
	if j == 0 {
		if !j_state_eq(&c.lstate[0], &c.st) {
			j_fail(c, "operand stack types differ at the back edge")
			return false
		}
		if conditional {
			j_op(c, W_IF)
			j_op(c, W_VOID)
			c.nest += 1
		}
		// the budget: every JIT_BUDGET iterations the interpreter gets a turn (interrupt poll, collection)
		j_lget(c, I_BUDGET)
		j_i32(c, 1)
		j_op(c, W_I32_SUB)
		j_op(c, 0x22)   // local.tee
		w_uleb(&c.out, I_BUDGET)
		j_op(c, W_I32_EQZ)
		j_op(c, W_IF)
		j_op(c, W_VOID)
		c.nest += 1
		j_stub_budget(c)
		j_op(c, W_END)
		c.nest -= 1
		j_op(c, W_BR)
		w_uleb(&c.out, j_loop_depth(c))
		if conditional {
			j_op(c, W_END)
			c.nest -= 1
			return true
		}
		return false
	}
	if j <= c.cur {
		j_fail(c, "nested loop")
		return false
	}
	if c.lvalid[j] {
		if !j_state_eq(&c.lstate[j], &c.st) {
			j_fail(c, "operand stack types differ at a join")
			return false
		}
	} else {
		c.lstate[j] = c.st
		c.lvalid[j] = true
	}
	j_op(c, conditional ? W_BR_IF : W_BR)
	w_uleb(&c.out, u64(c.nest + (j - c.cur - 1)))
	return !(!conditional)
}

// leaves at the loop header (the stack holds what it held at the back edge)
@(private = "file")
j_stub_budget :: proc(c: ^Jc) {
	j_stub(c, c.header, .budget, 0)
}

// The instruction at pc, translated; returns whether the next instruction is reachable from it.
@(private = "file")
jit_insn :: proc(c: ^Jc, f: ^Frame, op: Opcode, pc: int) -> bool {
	code := c.code
	n := c.st.n

	// slot instructions
	if s, w, ok := jit_op_slot(op, code, pc, c.nargs); ok {
		return jit_slot_insn(c, op, pc, s, w)
	}
	#partial switch op {
	case .op_nop:
		return true
	case .get_loc0_loc1:
		for k in 0 ..< 2 {
			s := c.nargs + k
			#partial switch c.skind[s] {
			case .i32:
				d := j_push(c, .I)
				j_lget(c, c.wl[s])
				j_lset(c, j_si(c, d))
			case .f64:
				d := j_push(c, .F)
				j_lget(c, c.wl[s])
				j_lset(c, j_sf(c, d))
			case:
				j_fail(c, "read of a local the loop does not hold")
				return false
			}
		}
	case .push_minus1, .push_0, .push_1, .push_2, .push_3, .push_4, .push_5, .push_6, .push_7:
		d := j_push(c, .I)
		j_i32(c, i32(op) - i32(Opcode.push_0))
		j_lset(c, j_si(c, d))
	case .push_i8:
		d := j_push(c, .I)
		j_i32(c, i32(i8(code[pc + 1])))
		j_lset(c, j_si(c, d))
	case .push_i16:
		d := j_push(c, .I)
		j_i32(c, i32(i16(u16(jr_u16(code, pc + 1)))))
		j_lset(c, j_si(c, d))
	case .push_i32:
		d := j_push(c, .I)
		j_i32(c, i32(jr_i32(code, pc + 1)))
		j_lset(c, j_si(c, d))
	case .push_false, .push_true:
		d := j_push(c, .B)
		j_i32(c, op == .push_true ? 1 : 0)
		j_lset(c, j_si(c, d))
	case .push_const, .push_const8:
		idx := op == .push_const ? jr_i32(code, pc + 1) : int(code[pc + 1])
		if idx < 0 || idx >= len(c.b.cpool) {
			j_fail(c, "constant out of range")
			return false
		}
		v := c.b.cpool[idx]
		#partial switch v.tag {
		case .int:
			d := j_push(c, .I)
			j_i32(c, v.u.i)
			j_lset(c, j_si(c, d))
		case .float:
			d := j_push(c, .F)
			j_f64(c, v.u.f)
			j_lset(c, j_sf(c, d))
		case:
			j_fail(c, "constant that is not a number")
			return false
		}
	case .drop:
		c.st.n -= 1
	case .dup:
		t := c.st.t[n - 1]
		d := j_push(c, t)
		j_lget(c, j_sloc(c, n - 1, t))
		j_lset(c, j_sloc(c, d, t))
	case .nip:
		tb := c.st.t[n - 1]
		j_lget(c, j_sloc(c, n - 1, tb))
		j_lset(c, j_sloc(c, n - 2, tb))
		c.st.t[n - 2] = tb
		c.st.n -= 1
	case .swap:
		ta, tb := c.st.t[n - 2], c.st.t[n - 1]
		sa := j_scratch(c, ta, 0)
		sb := j_scratch(c, tb, 1)
		j_lget(c, j_sloc(c, n - 2, ta))
		j_lset(c, sa)
		j_lget(c, j_sloc(c, n - 1, tb))
		j_lset(c, sb)
		j_lget(c, sb)
		j_lset(c, j_sloc(c, n - 2, tb))
		j_lget(c, sa)
		j_lset(c, j_sloc(c, n - 1, ta))
		c.st.t[n - 2], c.st.t[n - 1] = tb, ta
	case .add, .sub, .mul, .div, .mod:
		return jit_arith(c, op, pc)
	case .shl, .sar, .shr, .op_and, .op_or, .xor:
		return jit_bitwise(c, op, pc)
	case .lt, .lte, .gt, .gte, .eq, .neq, .strict_eq, .strict_neq:
		return jit_compare(c, op)
	case .neg:
		t := c.st.t[n - 1]
		if t == .I {
			j_lget(c, j_si(c, n - 1))
			j_op(c, W_I32_EQZ)
			j_lget(c, j_si(c, n - 1))
			j_i32(c, min(i32))
			j_op(c, W_I32_EQ)
			j_op(c, W_I32_OR)
			j_deopt_if(c, pc)
			j_i32(c, 0)
			j_lget(c, j_si(c, n - 1))
			j_op(c, W_I32_SUB)
			j_lset(c, j_si(c, n - 1))
		} else if t == .F {
			j_lget(c, j_sf(c, n - 1))
			j_op(c, W_F64_NEG)
			j_lset(c, j_sf(c, n - 1))
		} else {
			j_fail(c, "neg of a bool")
			return false
		}
	case .plus:
		if !j_is_num(c.st.t[n - 1]) {
			j_fail(c, "plus of a bool")
			return false
		}
	case .inc, .dec:
		t := c.st.t[n - 1]
		if t == .I {
			j_lget(c, j_si(c, n - 1))
			j_i32(c, op == .inc ? max(i32) : min(i32))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
			j_lget(c, j_si(c, n - 1))
			j_i32(c, 1)
			j_op(c, op == .inc ? W_I32_ADD : W_I32_SUB)
			j_lset(c, j_si(c, n - 1))
		} else if t == .F {
			j_lget(c, j_sf(c, n - 1))
			j_f64(c, 1)
			j_op(c, op == .inc ? W_F64_ADD : W_F64_SUB)
			j_lset(c, j_sf(c, n - 1))
		} else {
			j_fail(c, "inc of a bool")
			return false
		}
	case .post_inc, .post_dec:
		t := c.st.t[n - 1]
		if t != .I && t != .F {
			j_fail(c, "post_inc of a bool or a large integer")
			return false
		}
		if t == .I {
			j_lget(c, j_si(c, n - 1))
			j_i32(c, op == .post_inc ? max(i32) : min(i32))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
			d := j_push(c, .I)
			j_lget(c, j_si(c, n - 1))
			j_i32(c, 1)
			j_op(c, op == .post_inc ? W_I32_ADD : W_I32_SUB)
			j_lset(c, j_si(c, d))
		} else {
			d := j_push(c, .F)
			j_lget(c, j_sf(c, n - 1))
			j_f64(c, 1)
			j_op(c, op == .post_inc ? W_F64_ADD : W_F64_SUB)
			j_lset(c, j_sf(c, d))
		}
	case .op_not:
		t := c.st.t[n - 1]
		if !j_is_num(t) {
			j_fail(c, "~ of a bool")
			return false
		}
		j_get_i32(c, n - 1, pc)
		j_i32(c, -1)
		j_op(c, W_I32_XOR)
		c.st.n -= 1
		d := j_push(c, .I)
		j_lset(c, j_si(c, d))
	case .lnot:
		j_get_bool(c, n - 1)
		j_op(c, W_I32_EQZ)
		c.st.n -= 1
		d := j_push(c, .B)
		j_lset(c, j_si(c, d))
	case .is_undefined, .is_null, .is_undefined_or_null, .typeof_is_undefined, .typeof_is_function:
		// a number or a bool is none of these
		c.st.n -= 1
		d := j_push(c, .B)
		j_i32(c, 0)
		j_lset(c, j_si(c, d))
	case .op_return:
		j_store_entry(c, n - 1, P_STACK, 0, true)
		c.st.n = 0
		j_i32(c, 0)
		j_lset(c, I_PC)
		j_i32(c, 0)
		j_lset(c, I_SP)
		j_i32(c, i32(Jit_Exit.ret))
		j_lset(c, I_KIND)
		j_i32(c, 0)
		j_lset(c, I_AUX)
		j_op(c, W_BR)
		w_uleb(&c.out, j_exit_depth(c))
		return false
	case .return_undef:
		j_store_tag(c, P_STACK, 0, .undefined)
		j_i32(c, 0)
		j_lset(c, I_PC)
		j_i32(c, 0)
		j_lset(c, I_SP)
		j_i32(c, i32(Jit_Exit.ret))
		j_lset(c, I_KIND)
		j_i32(c, 0)
		j_lset(c, I_AUX)
		j_op(c, W_BR)
		w_uleb(&c.out, j_exit_depth(c))
		return false
	case .goto, .goto8, .goto16:
		target, _, _ := jit_jump(op, code, pc)
		return j_jump(c, pc, target, false)
	case .if_true, .if_false, .if_true8, .if_false8:
		target, cond, _ := jit_jump(op, code, pc)
		j_get_bool(c, n - 1)
		if cond == 2 {j_op(c, W_I32_EQZ)}
		c.st.n -= 1
		return j_jump(c, pc, target, true)
	case:
		j_fail(c, reflect.enum_string(op))
		return false
	}
	return true
}

// locals and arguments
@(private = "file")
jit_slot_insn :: proc(c: ^Jc, op: Opcode, pc: int, s: int, write: bool) -> bool {
	n := c.st.n
	kind := c.skind[s]
	if op == .get_loc0_loc1 {
		return true
	}
	#partial switch op {
	case .inc_loc, .dec_loc:
		#partial switch kind {
		case .i32:
			j_lget(c, c.wl[s])
			j_i32(c, op == .inc_loc ? max(i32) : min(i32))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
			j_lget(c, c.wl[s])
			j_i32(c, 1)
			j_op(c, op == .inc_loc ? W_I32_ADD : W_I32_SUB)
			j_lset(c, c.wl[s])
		case .f64:
			j_lget(c, c.wl[s])
			j_f64(c, 1)
			j_op(c, op == .inc_loc ? W_F64_ADD : W_F64_SUB)
			j_lset(c, c.wl[s])
		case:
			j_fail(c, "inc of a local the loop does not hold")
			return false
		}
		return true
	case .add_loc:
		tv := c.st.t[n - 1]
		if !j_is_num(tv) {
			j_fail(c, "add_loc of a bool")
			return false
		}
		#partial switch kind {
		case .i32:
			if tv == .F {
				j_widen(c, s)
				return false
			}
			j_lget(c, c.wl[s])
			j_op(c, W_I64_EXTEND_I32_S)
			j_get_i64(c, n - 1)
			j_op(c, W_I64_ADD)
			j_lset(c, c.r64)
			j_lget(c, c.r64)
			j_op(c, W_I32_WRAP_I64)
			j_op(c, W_I64_EXTEND_I32_S)
			j_lget(c, c.r64)
			j_op(c, W_I64_NE)
			j_deopt_if(c, pc)
			j_lget(c, c.r64)
			j_op(c, W_I32_WRAP_I64)
			j_lset(c, c.wl[s])
		case .f64:
			j_lget(c, c.wl[s])
			j_get_f(c, n - 1)
			j_op(c, W_F64_ADD)
			j_lset(c, c.wl[s])
		case:
			j_fail(c, "add_loc to a local the loop does not hold")
			return false
		}
		c.st.n -= 1
		return true
	}
	if !write {
		// get_*
		#partial switch kind {
		case .i32:
			d := j_push(c, .I)
			j_lget(c, c.wl[s])
			j_lset(c, j_si(c, d))
		case .f64:
			d := j_push(c, .F)
			j_lget(c, c.wl[s])
			j_lset(c, j_sf(c, d))
		case:
			j_fail(c, "read of a local the loop does not hold")
			return false
		}
		return true
	}
	// put_* / set_*
	keep := op == .set_loc || op == .set_loc8 || op == .set_loc0 || op == .set_loc1 || op == .set_loc2 || op == .set_loc3 ||
		op == .set_arg || op == .set_arg0 || op == .set_arg1 || op == .set_arg2 || op == .set_arg3
	tv := c.st.t[n - 1]
	#partial switch kind {
	case .i32:
		if tv == .I {
			j_lget(c, j_si(c, n - 1))
			j_lset(c, c.wl[s])
		} else if tv == .L {
			j_l_not_i32(c, n - 1)
			j_deopt_if(c, pc)
			j_lget(c, c.sl0 + u32(n - 1))
			j_op(c, W_I32_WRAP_I64)
			j_lset(c, c.wl[s])
		} else if tv == .F {
			j_widen(c, s)
			return false
		} else {
			j_fail(c, "bool stored in an int local")
			return false
		}
	case .f64:
		if tv == .B {
			j_fail(c, "bool stored in a double local")
			return false
		}
		j_get_f(c, n - 1)
		j_lset(c, c.wl[s])
	case .box:
		if tv == .L {
			j_l_not_i32(c, n - 1)
			j_deopt_if(c, pc)
		}
		base, off := j_slot_addr(c, s)
		j_store_entry(c, n - 1, base, off)
	case:
		j_fail(c, "store to an unknown local")
		return false
	}
	if !keep {c.st.n -= 1}
	return true
}

// the loop stores a double into an int local: speculate a double for it and translate again
@(private = "file")
j_widen :: proc(c: ^Jc, s: int) {
	if s >= 64 {
		j_fail(c, "double stored in an int local")
		return
	}
	bit := u64(1) << uint(s)
	if c.jl.widen & bit != 0 {
		j_fail(c, "double stored in an int local")
		return
	}
	c.jl.widen |= bit
	c.restart = true
}

@(private = "file")
jit_arith :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	n := c.st.n
	a, b := n - 2, n - 1
	ta, tb := c.st.t[a], c.st.t[b]
	if !j_is_num(ta) || !j_is_num(tb) {
		j_fail(c, "arithmetic on a bool")
		return false
	}
	if ta != .F && tb != .F && op != .div && (op != .mul || (ta == .I && tb == .I)) {
		if op == .mod {
			if ta != .I || tb != .I {
				j_fail(c, "modulo of a large integer")
				return false
			}
			j_lget(c, j_si(c, a))
			j_i32(c, 0)
			j_op(c, W_I32_GE_S)
			j_lget(c, j_si(c, b))
			j_i32(c, 0)
			j_op(c, W_I32_GT_S)
			j_op(c, W_I32_AND)
			j_op(c, W_I32_EQZ)
			j_deopt_if(c, pc)
			j_lget(c, j_si(c, a))
			j_lget(c, j_si(c, b))
			j_op(c, W_I32_REM_S)
			c.st.n -= 2
			d := j_push(c, .I)
			j_lset(c, j_si(c, d))
			return true
		}
		// the exact result, in an i64: a following | 0 or a store into an int local decides what becomes of it
		j_get_i64(c, a)
		j_get_i64(c, b)
		j_op(c, op == .add ? W_I64_ADD : op == .sub ? W_I64_SUB : W_I64_MUL)
		j_lset(c, c.r64)
		if op == .mul || ta == .L || tb == .L {
			// beyond 2^53 the interpreter's double would have rounded
			j_lget(c, c.r64)
			j_l_out_of_range(c)
			j_deopt_if(c, pc)
		}
		if op == .mul {
			// a zero product of a negative operand is -0
			j_lget(c, c.r64)
			j_op(c, W_I64_EQZ)
			j_lget(c, j_si(c, a))
			j_lget(c, j_si(c, b))
			j_op(c, W_I32_OR)
			j_i32(c, 0)
			j_op(c, W_I32_LT_S)
			j_op(c, W_I32_AND)
			j_deopt_if(c, pc)
		}
		c.st.n -= 2
		d := j_push(c, .L)
		j_lget(c, c.r64)
		j_lset(c, c.sl0 + u32(d))
		return true
	}
	if op == .mod {
		j_fail(c, "modulo of doubles")
		return false
	}
	j_get_f(c, a)
	j_get_f(c, b)
	j_op(c, op == .add ? W_F64_ADD : op == .sub ? W_F64_SUB : op == .mul ? W_F64_MUL : W_F64_DIV)
	c.st.n -= 2
	d := j_push(c, .F)
	j_lset(c, j_sf(c, d))
	return true
}

@(private = "file")
jit_bitwise :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	n := c.st.n
	a, b := n - 2, n - 1
	if !j_is_num(c.st.t[a]) || !j_is_num(c.st.t[b]) {
		j_fail(c, "bitwise operation on a bool")
		return false
	}
	j_get_i32(c, a, pc)
	j_get_i32(c, b, pc)
	#partial switch op {
	case .shl: j_op(c, W_I32_SHL)
	case .sar: j_op(c, W_I32_SHR_S)
	case .shr: j_op(c, W_I32_SHR_U)
	case .op_and: j_op(c, W_I32_AND)
	case .op_or: j_op(c, W_I32_OR)
	case .xor: j_op(c, W_I32_XOR)
	}
	if op == .shr {
		// an unsigned result above 2^31 - 1 is a double for the interpreter
		j_lset(c, I_T0)
		j_lget(c, I_T0)
		j_i32(c, 0)
		j_op(c, W_I32_LT_S)
		j_deopt_if(c, pc)
		j_lget(c, I_T0)
	}
	c.st.n -= 2
	d := j_push(c, .I)
	j_lset(c, j_si(c, d))
	return true
}

@(private = "file")
jit_compare :: proc(c: ^Jc, op: Opcode) -> bool {
	n := c.st.n
	a, b := n - 2, n - 1
	ta, tb := c.st.t[a], c.st.t[b]
	equality := op == .eq || op == .neq || op == .strict_eq || op == .strict_neq
	if ta == .B || tb == .B {
		if ta == .B && tb == .B && equality {
			j_lget(c, j_si(c, a))
			j_lget(c, j_si(c, b))
			j_op(c, (op == .eq || op == .strict_eq) ? W_I32_EQ : W_I32_NE)
			c.st.n -= 2
			d := j_push(c, .B)
			j_lset(c, j_si(c, d))
			return true
		}
		j_fail(c, "comparison with a bool")
		return false
	}
	if ta == .I && tb == .I {
		j_lget(c, j_si(c, a))
		j_lget(c, j_si(c, b))
		#partial switch op {
		case .lt: j_op(c, W_I32_LT_S)
		case .lte: j_op(c, W_I32_LE_S)
		case .gt: j_op(c, W_I32_GT_S)
		case .gte: j_op(c, W_I32_GE_S)
		case .eq, .strict_eq: j_op(c, W_I32_EQ)
		case: j_op(c, W_I32_NE)
		}
	} else if ta != .F && tb != .F {
		// an I and an L: exact integers, compared as i64
		j_get_i64(c, a)
		j_get_i64(c, b)
		#partial switch op {
		case .lt: j_op(c, W_I64_LT_S)
		case .lte: j_op(c, W_I64_LE_S)
		case .gt: j_op(c, W_I64_GT_S)
		case .gte: j_op(c, W_I64_GE_S)
		case .eq, .strict_eq: j_op(c, W_I64_EQ)
		case: j_op(c, W_I64_NE)
		}
	} else {
		j_get_f(c, a)
		j_get_f(c, b)
		#partial switch op {
		case .lt: j_op(c, W_F64_LT)
		case .lte: j_op(c, W_F64_LE)
		case .gt: j_op(c, W_F64_GT)
		case .gte: j_op(c, W_F64_GE)
		case .eq, .strict_eq: j_op(c, W_F64_EQ)
		case: j_op(c, W_F64_NE)
		}
	}
	c.st.n -= 2
	d := j_push(c, .B)
	j_lset(c, j_si(c, d))
	return true
}
