package jsrt

// A loop JIT for the interpreter: a hot loop (found by sampling its back edges) is translated to a WebAssembly
// function that the host compiles (Cranelift) and attaches to the engine's own table; the interpreter then calls it
// like a C function pointer. WebAssembly stays the only execution engine: the generated code lives in the same
// sandbox as the engine and reaches only its memory (it is given the frame's argument, local and operand areas) and the
// helpers the engine exports to it.
//
// What it compiles: the loop region [header, end of the back edge) of one function, entered at the header (on-stack
// replacement) from a frame whose locals the interpreter holds in memory. Locals and operand-stack entries the region
// uses as numbers or objects are kept in Wasm locals (i32 for ints, f64 for doubles, i32 for bools and object pointers;
// the types are speculated from the values the frame holds when the loop gets hot, widened int -> double when the region
// itself needs it), read once at entry (guarded by their tags) and written back when the code leaves; other locals stay
// in the frame's memory. It allocates and calls only through the engine's helpers (JIT_HELPERS: an object, a call of a
// native function) and compiled code: an operation it cannot do inline keeps the loop from being compiled at all, a small
// function it calls is inlined (jit_inline), and a speculation that fails at run time (int overflow, -0, a modulo of a
// negative number...) leaves through a deopt exit that stores the operand stack back in the frame and hands the
// interpreter the pc and sp of the instruction that was about to run. Exits: leaving the region, return, deopt, a
// helper's call that threw, and every JIT_BUDGET iterations (so that the interpreter's safe point, interrupt poll and
// collection, still runs in a loop that does not end).
//
// Properties: a read or a write of a named property (get_field, put_field, get_length, a global's get_var / put_var) is
// a guard of the object's own shape against the shapes the site was compiled for, then the slot at a constant index (in
// the object, or in the prototype that holds it, whose shape is guarded too): a shape that is not a dictionary never
// changes, so the guard is a check of data in the object, nothing to invalidate. A dictionary shape (a holder's) is
// checked by the key at the index. What a site was compiled for is per site and bounded (Jit_Site: a few shapes, the
// type of the value read): taken from the frame's values when the loop is translated, and learned when the site misses
// (a learn exit: the interpreter looks at the object, the site takes its shape or a wider type, the loop is translated
// again, a bounded number of times). The shapes and objects the code compares against are kept alive by the loop (the
// collector marks them through Function_Bytecode.jit), so an address the code holds is never another shape's.
//
// Whole functions: a function without loops of its own (its backward jumps, if any, go to its start) is compiled whole
// once its calls reach jit_cfg.call_threshold, as the region [0, end) entered at its call (jit_fn_enter: from the
// interpreter's calls, or from compiled code). Compiled code calls such a function directly (j_direct_call): it pushes
// the callee's frame on the value stack as frame_push does, calls the callee's code through the engine's table, pops
// the frame; no state of the caller lives across the call but in its frame. The callee's code leaving other than by its
// return is finished by the interpreter (jit_call_finish). Compiled code nested this way is bounded (JIT_MAX_NEST): a
// recursion deeper than that goes on interpreted.
//
// Contract with the host: native/js/odin/jit.odin (the exports wj_jit_configure, wj_jit_stat, the helpers) and the host's
// Engine_jitCompile / Engine_jitPoll (src/js/jit.odin: attach_function); the module imports the engine's memory
// ("e" "memory") and, when the region calls, the helpers of JIT_HELPERS (exported by the glue) and the engine's table
// ("e" "table", src/wasm/attach.odin), and exports "f" (args, locals, stack, arrays, closure cells, frame) -> i64.

import "base:runtime"
import "core:reflect"
import "core:slice"
import "core:strings"

JIT_STACK_MAX :: 32
JIT_BUDGET :: 16384
JIT_MAX_RESTARTS :: 8
JIT_MAX_LOOPS :: 4
JIT_MAX_REJITS :: 4
JIT_MAX_DEOPTS :: 16   // deopt exits after which a loop is not compiled again
JIT_MAX_LEARNS :: 12   // learn exits (a site that missed) after which a loop is not compiled again
JIT_DEFAULT_MAX_CODE_BYTES :: 64 << 10   // the largest function compiled when the host does not choose
JIT_DEFAULT_CALL_THRESHOLD :: 500        // the calls after which a function is compiled whole, when the host does not choose
JIT_CALLS_NEVER :: min(int) / 2          // where a function that is not compiled whole counts its calls from
JIT_MAX_NEST :: 128    // compiled code running one inside another (a call made by compiled code to compiled code): past it, interpreted
JIT_PROBE :: 64        // entries after which a loop that runs too few iterations per entry is dropped
JIT_MIN_ITERS :: 6
JIT_MAX_SITES :: 32    // the property, global, element and call sites of a loop (an inlined callee's too)
JIT_SITE_SHAPES :: 4   // the shapes one property site takes (a guard for each, in turn)
JIT_MAX_CHAIN :: 4     // the prototypes a property read walks to its holder
JIT_MAX_KEEP :: 64     // the shapes and objects the compiled code of a loop compares against
JIT_ELEM_PEEK :: 16    // the first elements of an array looked at for the type of the elements a read takes
JIT_INLINE_MAX_CODE :: 96   // the bytecode of a function inlined at a call, at most
JIT_INLINE_DEPTH :: 2       // calls inlined in an inlined callee, at most one level down
JIT_INLINE_SITE_SHIFT :: 20 // an inlined callee's sites: (the call's site + 1) << this, plus the callee's pc
JIT_PRIMITIVE_STR_MAX :: 32   // the longest string a number, a bool, null or undefined converts to, at most
JIT_MAX_SHADOWS :: 4        // the objects seen whose properties a translation appended (a constructor's this), followed

// The aux word of a deopt exit: a slot to widen (< 64), none, a site that missed, a callee not to inline
JIT_AUX_NONE :: 0xffff
JIT_AUX_LEARN :: 0xfffd
JIT_AUX_NO_INLINE :: 0xfffc   // a deopt in a callee inlined at the call that left: it is called instead
JIT_AUX_CALLEE :: 0xfffb      // a call whose callee the translation did not know: the site takes the one met

#assert(size_of(Value) == 16)
#assert(offset_of(Value, u) == 8)

Jit_Cfg :: struct {
	enabled:        bool,
	trace:          bool,
	max_code_bytes: int,
	call_threshold: int,
	compile:        proc "contextless" (module: [^]u8, n: u32) -> i32,   // Engine_jitCompile: a table index, 0 refused, < 0 a ticket
	poll:           proc "contextless" (ticket: i32) -> i32,             // Engine_jitPoll
	log:            proc(msg: string),
}

jit_cfg: Jit_Cfg

// The engine's procedures compiled code calls: exported by the glue (native/js/odin/jit.odin) under these names,
// imported by a module whose loop calls (function index = the helper's), each (i32...) -> i32.
Jit_Helper :: enum u8 {call, array, finish, new, reserve, add, streq, get, set}

Jit_Helper_Def :: struct {
	name:   string,
	params: int,
}

JIT_HELPERS :: [Jit_Helper]Jit_Helper_Def {
	.call    = {"wj_jit_call", 5},
	.array   = {"wj_jit_array", 4},
	.finish  = {"wj_jit_finish", 5},
	.new     = {"wj_jit_new", 4},
	.reserve = {"wj_jit_reserve", 3},
	.add     = {"wj_jit_add", 3},
	.streq   = {"wj_jit_streq", 3},
	.get     = {"wj_jit_get", 7},
	.set     = {"wj_jit_set", 6},
}

// The engine's table, which a module whose code calls compiled code directly imports ("e" "table": the host gives it
// the table the compiled functions are attached to)
JIT_TABLE_IMPORT :: "table"

// Jit_Helper.call: a call instruction of a compiled loop. The operand stack is in the frame's memory below sp: the
// callee and its argc arguments on top, `this` under the callee for a method call (kind .method), new.target after
// the constructor for a construction (kind .construct). The result takes the place of the callee (and of `this` or
// new.target); pc is the instruction after the call. Threw: the exception is pending, the stack as it was; interpret:
// not made, the call is the interpreter's (a function that will not be compiled whole, which costs more called from
// here than from the interpreter).
Jit_Call_Kind :: enum i32 {call, method, construct}

Jit_Call_Result :: enum i32 {made, threw, interpret}

jit_call :: proc(f: ^Frame, sp: int, argc: int, kind: Jit_Call_Kind, pc: int) -> Jit_Call_Result {
	ctx := f.ctx
	rt := ctx.rt
	base := sp - argc
	f.pc = pc
	r: Value
	switch kind {
	case .call, .method:
		fv := f.stack[base - 1]
		this := kind == .method ? f.stack[base - 2] : UNDEFINED
		if fv.tag == .object && as_obj(fv).class == .bytecode_function {
			if nb := as_obj(fv).data.(Func_Data).bc; nb.jit != nil && nb.jit.fn.state == .never {return .interpret}
			r = jit_call_bytecode(ctx, as_obj(fv), this, f.stack[base:sp])
		} else if fv.tag == .object && as_obj(fv).class == .c_function && native_kind(as_obj(fv)) == .function &&
		          rt.stack_depth < rt.config.max_stack_depth && !stack_exhausted(rt) {
			// (a native function called as call_internal calls it, without its dispatch: as the hot loop's hot_call)
			fo := as_obj(fv)
			r = call_native(ctx, fo, &fo.data.(Native_Data), this, f.stack[base:sp])
		} else {
			r = call_internal(ctx, fv, this, UNDEFINED, f.stack[base:sp], false)
		}
	case .construct:
		fn := f.stack[base - 2]
		if !is_constructor(fn) {
			throw_type_error(ctx, "not a constructor")
			return .threw
		}
		r = call_internal(ctx, fn, UNDEFINED, f.stack[base - 1], f.stack[base:sp], true)
	}
	if is_exception(r) {
		// the instruction is made again by the interpreter, with a callee that throws the exception pending: it
		// unwinds from the call as if it had made it (and the interpreter's code needs no exit of its own for this)
		if ctx.jit_rethrow == nil {ctx.jit_rethrow = new_native_function(ctx, jit_rethrow, "", 0, 0, .constructor)}
		f.stack[kind == .method ? base - 1 : kind == .construct ? base - 2 : base - 1] = mk_obj(ctx.jit_rethrow)
		return .threw
	}
	f.stack[kind == .call ? base - 1 : base - 2] = r
	// (what the frame needs is on its stack: the temporaries of the call go, as at a back edge)
	if len(rt.temp_roots) > f.root_base {resize(&rt.temp_roots, f.root_base)}
	return .made
}

// Jit_Helper.finish: the compiled code of a function called directly by compiled code (j_direct_call) left other than
// by its return, with the exit word (lo, hi) of the code made at `index`: the rest of the call interpreted on its
// frame, which the caller pops. Its result in f.stack[0]; true: it threw (the caller's callee, at `slot` of its stack,
// is then jit_rethrow, as jit_call leaves it).
jit_call_finish :: proc(f: ^Frame, lo: u32, hi: u32, index: u32, slot: int) -> bool {
	b := f.bc
	res, pc, sp := jit_exit(f, b, &b.jit.fn, index, u64(lo) | u64(hi) << 32)
	v := f.stack[0]
	if res != .ret {
		f.pc = pc
		f.sp = sp
		v, _ = interp_run(f.ctx, f, f.closure_refs)
	}
	if is_exception(v) {
		ctx := f.prev.ctx
		if ctx.jit_rethrow == nil {ctx.jit_rethrow = new_native_function(ctx, jit_rethrow, "", 0, 0, .constructor)}
		f.prev.stack[slot] = mk_obj(ctx.jit_rethrow)
		return true
	}
	f.stack[0] = v
	return false
}

// A function the JIT may compile whole: a plain one within the size limit, with an operand stack (its result is
// returned in stack[0]; a function without one, which only returns undefined, has its frame there)
@(private = "file")
jit_fn_kind_ok :: proc(b: ^Function_Bytecode) -> bool {
	return b.func_kind == .normal && len(b.code) <= jit_cfg.max_code_bytes && b.stack_size > 0
}

// Can the function be compiled whole, and so be called from compiled code without the cost of an interpreted call
// through the helper: a plain function within the size limit whose backward jumps (if any) go to its start, not
// refused before.
@(private = "file")
jit_fn_compilable :: proc(b: ^Function_Bytecode) -> bool {
	if !jit_fn_kind_ok(b) || (b.jit != nil && b.jit.fn.state == .never) {return false}
	code := b.code
	for pc := 0; pc < len(code); {
		if int(code[pc]) >= OPCODE_COUNT {return false}
		op := Opcode(code[pc])
		if t, _, ok := jit_jump(op, code, pc); ok && t <= pc && t != 0 {return false}
		pc += int(opcode_info[op].size)
	}
	return true
}

// A call of a bytecode function made by compiled code: a plain function's frame pushed as the interpreter pushes it and
// its compiled code run on it at once when it has some (the compiled caller's state is in its frame: nothing else to
// keep), the rest of it interpreted when that code leaves; another kind of function called as the interpreter calls it.
@(private = "file")
jit_call_bytecode :: proc(ctx: ^Context, fo: ^Object, this: Value, args: []Value) -> Value {
	rt := ctx.rt
	nb := fo.data.(Func_Data).bc
	if nb.func_kind != .normal || rt.stack_depth >= rt.config.max_stack_depth || stack_exhausted(rt) {
		return call_internal(ctx, mk_obj(fo), this, UNDEFINED, args, false)
	}
	nf := frame_push(ctx, fo, this, args, false)
	res, pc, sp := Jit_Resume.none, 0, 0
	nb.jit_calls += 1
	if nb.jit_calls >= jit_cfg.call_threshold {res, pc, sp = jit_fn_enter(nf.ctx, nf)}
	r: Value
	if res == .ret {
		r = nf.stack[0]
	} else {
		nf.pc = pc
		nf.sp = sp
		r, _ = interp_run(nf.ctx, nf, nf.closure_refs)
	}
	// (the result is stored in the caller's frame before anything allocates)
	frame_pop(rt, nf)
	return r
}

// The callee jit_call leaves in the place of one that threw: the exception is still pending.
@(private = "file")
jit_rethrow :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return EXCEPTION
}

// Jit_Helper.new: an object for compiled code: a plain object (kind object), an Array of the argc values at f.stack[a:]
// (array), the object a construction makes for the constructor at f.stack[a], new.target at f.stack[a + 1] (ctor,
// create_from_ctor). nil: it threw (the constructor's place is then jit_rethrow's, as jit_call leaves a call). The
// object is only in the compiled code's hands: no collection runs before the code's next call, which writes what it
// holds to the frame first.
Jit_New_Kind :: enum i32 {object, array, ctor}

jit_new :: proc(f: ^Frame, kind: Jit_New_Kind, a: int, argc: int) -> ^Object {
	ctx := f.ctx
	rt := ctx.rt
	o: ^Object
	switch kind {
	case .object:
		o = new_plain_object(ctx)
	case .array:
		o = array_from_values(ctx, f.stack[a:a + argc])
	case .ctor:
		v := create_from_ctor(ctx, f.stack[a + 1], .object)
		if is_exception(v) {
			if ctx.jit_rethrow == nil {ctx.jit_rethrow = new_native_function(ctx, jit_rethrow, "", 0, 0, .constructor)}
			f.stack[a] = mk_obj(ctx.jit_rethrow)
			return nil
		}
		o = as_obj(v)
	}
	if len(rt.temp_roots) > f.root_base {resize(&rt.temp_roots, f.root_base)}
	return o
}

// Jit_Helper.reserve: room for n slots in o, which the compiled code appends a property to.
jit_reserve :: proc(f: ^Frame, o: ^Object, n: int) {
	object_slots_reserve(f.ctx.rt, o, n)
}

// Jit_Helper.add: `+` of the two values under sp in the frame (a site that saw a string), the result at sp - 2; with
// slot >= 0 (add_loc), of the argument or local `slot` and the value under sp, the result in the slot. False: not made,
// the interpreter makes it (an operand whose conversion may run code or throw: an object, a symbol, a BigInt; a result
// too long for a string), nothing done.
jit_add :: proc(f: ^Frame, sp: int, slot: int) -> bool {
	ctx := f.ctx
	rt := ctx.rt
	na := int(f.bc.arg_count)
	to := slot < 0 ? &f.stack[sp - 2] : slot < na ? &f.args[slot] : &f.locals[slot - na]
	x, y := to^, f.stack[sp - 1]
	n := 0
	for v in ([]Value{x, y}) {
		#partial switch v.tag {
		case .string: n += int(as_str(v).len)
		case .int, .float, .bool, .null, .undefined: n += JIT_PRIMITIVE_STR_MAX
		case: return false
		}
	}
	if n > STRING_LEN_MAX {return false}
	r := op_add(ctx, x, y)
	if is_exception(r) {return false}
	to^ = r
	// (the result is in the frame: the temporaries of the conversions go)
	if len(rt.temp_roots) > f.root_base {resize(&rt.temp_roots, f.root_base)}
	return true
}

// Jit_Helper.get: a read of `a` that found a native getter (a DOM attribute's) or a script's: the getter called on o
// (the entry `at`), the value at `dest`. True: it threw; the object at `at` is then the context's thrower, whose `a` is an
// accessor that throws the exception pending: the interpreter makes the read again, and unwinds from it as if it had
// called the getter. pc: the instruction after the read (the frame's, as the hot loop leaves it during the call).
jit_getter :: proc(f: ^Frame, getter: ^Object, o: ^Object, dest: int, at: int, a: Atom, pc: int) -> bool {
	f.pc = pc
	v := jit_accessor_call(f.ctx, getter, o, nil)
	if is_exception(v) {
		jit_thrower_at(f, at, a)
		return true
	}
	f.stack[dest] = v
	if len(f.ctx.rt.temp_roots) > f.root_base {resize(&f.ctx.rt.temp_roots, f.root_base)}
	return false
}

// Jit_Helper.set: a write of `a` that found a setter, a native or a script's: called on o (the entry `at`) with the
// value above it. True: it threw; the object at `at` is the thrower, the interpreter makes the write again and unwinds
// from it. pc: the instruction after the write.
jit_setter :: proc(f: ^Frame, setter: ^Object, o: ^Object, at: int, a: Atom, pc: int) -> bool {
	f.pc = pc
	if is_exception(jit_accessor_call(f.ctx, setter, o, f.stack[at + 1:at + 2])) {
		jit_thrower_at(f, at, a)
		return true
	}
	if len(f.ctx.rt.temp_roots) > f.root_base {resize(&f.ctx.rt.temp_roots, f.root_base)}
	return false
}

// A getter or a setter called on o: a native as the hot loop calls it (hot_getter), a script's as compiled code calls
// one (jit_call_bytecode).
@(private = "file")
jit_accessor_call :: #force_inline proc(ctx: ^Context, fn: ^Object, o: ^Object, args: []Value) -> Value {
	rt := ctx.rt
	if fn.class == .bytecode_function {return jit_call_bytecode(ctx, fn, mk_obj(o), args)}
	if rt.stack_depth >= rt.config.max_stack_depth || stack_exhausted(rt) {return stack_overflow(ctx)}
	return call_native(ctx, fn, &fn.data.(Native_Data), mk_obj(o), args)
}

// The context's thrower in the place of the object at `at`: its `a` is an accessor whose getter and setter throw the
// exception pending.
@(private = "file")
jit_thrower_at :: proc(f: ^Frame, at: int, a: Atom) {
	ctx := f.ctx
	if ctx.jit_rethrow == nil {ctx.jit_rethrow = new_native_function(ctx, jit_rethrow, "", 0, 0, .constructor)}
	if ctx.jit_thrower == nil {ctx.jit_thrower = object_new_proto(ctx, nil)}
	th := ctx.jit_thrower
	if shape_lookup(th.shape, a) < 0 {define_own_property(ctx, th, a, accessor_desc(mk_obj(ctx.jit_rethrow), mk_obj(ctx.jit_rethrow), {.configurable}), false)}
	f.stack[at] = mk_obj(th)
}

// Jit_Helper.streq: two strings equal by value.
jit_streq :: proc(f: ^Frame, a: ^JS_String, b: ^JS_String) -> bool {
	return str_eq(f.ctx.rt, a, b)
}

// Jit_Helper.array: after a call, the array in a held local again (the call may have grown, shrunk or detached it).
// False: it is no longer of the kind the code was made for.
jit_array_again :: proc(f: ^Frame, slot: int, kind: Jit_Arr_Kind, out: ^Jit_Arr) -> bool {
	a := jit_array_of(jit_slot_value(f, slot))
	if a.kind != kind {return false}
	out^ = a
	return true
}

Jit_Stats :: struct {
	compiled, failed, refused, module_bytes, bytecode_bytes, entries, exits_leave, exits_return, exits_deopt, exits_throw, pending: f64,
}

jit_stats: Jit_Stats

Jit_Exit :: enum u8 {leave = 0, ret = 1, guard = 2, deopt = 3, budget = 4, throw = 5}

Jit_Loop_State :: enum u8 {fresh, pending, compiled, never}

Jit_Loop :: struct {
	header:     int,
	region_end: int,
	entry_sp:   int,
	state:      Jit_Loop_State,
	whole:      bool,  // the whole function (header 0, entered at its call), not one of its loops
	index:      u32,
	ticket:     i32,
	compiles:   int,
	deopts:     int,
	entries:    int,
	iters:      int,
	widen:      u64,   // slots (arguments, then locals) whose int speculation must be a double
	boxed:      u64,   // slots left to the interpreter's memory
	learns:     int,
	join_f:     [8]int, // pcs of joins (the end of a ?: or a && ||) whose operand stack entries are all doubles
	n_join_f:   int,
	join_v:     [8]Jit_Join_V,
	n_join_v:   int,
	sites:      [JIT_MAX_SITES]Jit_Site,
	n_sites:    int,
	keep:       [JIT_MAX_KEEP]^Cell,   // what the compiled code compares against or reads (marked by the collector)
	n_keep:     int,
	arr_slots:  [JIT_MAX_ARRS]int,   // the locals the compiled code reaches arrays through, and the kind it expects of each
	arr_kinds:  [JIT_MAX_ARRS]Jit_Arr_Kind,
	n_arr:      int,
}

// A join whose entries of mask (bits by depth) arrive with types that differ: they are values (V) there.
Jit_Join_V :: struct {
	pc:   int,
	mask: u32,
}

// What a site (the instruction at pc) was compiled for: the shapes of the objects it reads or writes (with their class,
// for a read that goes to a prototype; inline: the code reads the property inline for objects of that shape, the others
// are left to the interpreter), and the type of the value it reads or of the numbers it takes (typed: one was seen).
Jit_Site :: struct {
	pc:      int,
	ty:      Jit_Ty,
	typed:   bool,
	n:       int,
	shapes:  [JIT_SITE_SHAPES]^Shape,
	classes: [JIT_SITE_SHAPES]Class_ID,
	inline:  bit_set[0 ..< JIT_SITE_SHAPES],
	str:     bool,   // a read that met a string
	callee:  ^Object,   // a call's callee as an exit found it, when the translation could not tell (marked by the collector)
}

Jit_Info :: struct {
	loops: [JIT_MAX_LOOPS]Jit_Loop,
	n:     int,
	fn:    Jit_Loop,   // the whole function (jit_fn_enter)
}

Jit_Resume :: enum u8 {none, resume, ret}

// I: an int32 (an Int in the interpreter); F: a double; B: a bool; L: an integer of at most 2^53 in magnitude, the exact
// result of an int +, - or * that may have left the int32 range (what the interpreter holds as a double, which a following
// `| 0` brings back; kept in an i64 so that code like (h + c) | 0 does not leave the loop at each overflow)
// O: an array or typed array held by a local (never in a Wasm local: its elements are reached through the Jit_Arr the
// interpreter fills at entry); Jit_State.a tells which local
// P: an object (its address in an i32); V: any value (its tag in the i32, its payload in the i64)
// M: an entry under the loop's own (a try's catch offset, an iterator) that the loop leaves in the frame's memory
Jit_Ty :: enum u8 {I, F, B, L, O, P, V, M}

// v: what the entry held when the loop was translated, as far as the translation can tell from the frame (tag
// .exception: not known); only a hint for the speculations, never relied on. k: the shape of a P that the code itself
// made since the last join (an object literal being filled), known exactly: its fields need no guard.
Jit_State :: struct {
	n: int,
	t: [JIT_STACK_MAX]Jit_Ty,
	a: [JIT_STACK_MAX]u16,
	v: [JIT_STACK_MAX]Value,
	k: [JIT_STACK_MAX]^Shape,
}

// obj: an object, in an i32 local; box: left to the frame's memory (read as a V)
Jit_Slot_Kind :: enum u8 {unused, box, i32, f64, arr, obj}

JIT_MAX_ARRS :: 8

// An array the loop reads or writes, as the interpreter resolves it at each entry (jit_array_of): where its elements are,
// how many may be touched, its length, what they are. The compiled code expects the kind it was made for.
Jit_Arr :: struct {
	base:   u32,
	count:  u32,
	length: u32,
	kind:   Jit_Arr_Kind,
}

Jit_Arr_Kind :: enum u32 {
	none,
	values,   // an Array: Values (int and double ones are read, any element stored)
	i8, u8, i16, u16, i32, u32, f32, f64,   // typed arrays over a fixed-length live buffer
}

@(private = "file")
jr_u16 :: #force_inline proc "contextless" (c: []u8, p: int) -> int {
	return int(c[p]) | int(c[p + 1]) << 8
}

@(private = "file")
jr_i32 :: #force_inline proc "contextless" (c: []u8, p: int) -> int {
	return int(i32(u32(c[p]) | u32(c[p + 1]) << 8 | u32(c[p + 2]) << 16 | u32(c[p + 3]) << 24))
}

@(private = "file")
jr_u32 :: #force_inline proc "contextless" (c: []u8, p: int) -> u32 {
	return u32(c[p]) | u32(c[p + 1]) << 8 | u32(c[p + 2]) << 16 | u32(c[p + 3]) << 24
}

jit_configure :: proc(enabled: bool, compile: proc "contextless" (module: [^]u8, n: u32) -> i32, poll: proc "contextless" (ticket: i32) -> i32, log: proc(msg: string), call_threshold := 0) {
	jit_cfg.enabled = enabled && compile != nil && ODIN_ARCH == .wasm32
	jit_cfg.compile = compile
	jit_cfg.poll = poll
	jit_cfg.log = log
	jit_cfg.trace = log != nil
	jit_cfg.call_threshold = call_threshold > 0 ? call_threshold : JIT_DEFAULT_CALL_THRESHOLD
	if jit_cfg.max_code_bytes == 0 {jit_cfg.max_code_bytes = JIT_DEFAULT_MAX_CODE_BYTES}
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
	case 8: return s.exits_throw
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
		if !jit_region_ready(ctx, f, b, jl, sp) || sp != jl.entry_sp || ctx.rt.jit_depth >= JIT_MAX_NEST {return .none, 0, 0}
		return jit_run(ctx, f, b, jl)
	}
}

// Called with the frame of a call of a plain function before its first instruction (the interpreter's call, or a
// call compiled code makes through the helper): counts the call, compiles the whole function once it is hot, and runs
// the compiled code. None: interpret the function from its start (a collection is due, too deep in compiled code, not
// compiled); resume: carry on at (pc, sp); ret: the function returns the value in f.stack[0].
jit_fn_enter :: proc(ctx: ^Context, f: ^Frame) -> (res: Jit_Resume, pc: int, sp: int) {
	when ODIN_ARCH != .wasm32 {
		return .none, 0, 0
	} else {
		b := f.bc
		rt := ctx.rt
		if b.jit != nil && b.jit.fn.state == .compiled && rt.jit_depth < JIT_MAX_NEST && !gc_should_run(rt) {return jit_run(ctx, f, b, &b.jit.fn)}
		if !jit_fn_kind_ok(b) {
			b.jit_calls = JIT_CALLS_NEVER
			return .none, 0, 0
		}
		if rt.jit_depth >= JIT_MAX_NEST || gc_should_run(rt) {return .none, 0, 0}
		if b.jit == nil {b.jit = new(Jit_Info, rt_allocator(rt))}
		jl := &b.jit.fn
		if jl.region_end == 0 {jl^ = Jit_Loop{region_end = len(b.code), whole = true}}
		if !jit_region_ready(ctx, f, b, jl, 0) {
			if jl.state == .never {b.jit_calls = JIT_CALLS_NEVER}
			return .none, 0, 0
		}
		return jit_run(ctx, f, b, jl)
	}
}

// A frame the interpreter pushed for a call (frame_push): its call counted, and once they reach the threshold the
// function's compiled code run on it. The frame to carry on in: the callee's (at the f.pc, f.sp the code left it at),
// or the caller's when the callee returned (its result pushed). Out of line: the interpreter's code around its calls
// stays as it was.
jit_pushed :: #force_no_inline proc(f: ^Frame) -> ^Frame {
	b := f.bc
	b.jit_calls += 1
	if b.jit_calls < jit_cfg.call_threshold {return f}
	res, pc, sp := jit_fn_enter(f.ctx, f)
	switch res {
	case .none:
	case .resume:
		f.pc = pc
		f.sp = sp
	case .ret:
		v := f.stack[0]
		c := frame_pop(f.ctx.rt, f)
		c.stack[c.sp] = v
		c.sp += 1
		return c
	}
	return f
}

// The frame of a call interp_call makes (var_refs: the function's closure cells), before interp_run runs it: its call
// counted, the function's compiled code run on it once they reach the threshold. True: it returned (the value in
// f.stack[0]); else interp_run runs it from f.pc, f.sp.
jit_entered :: #force_no_inline proc(f: ^Frame, var_refs: [^]^Var_Ref) -> bool {
	b := f.bc
	f.closure_refs = var_refs
	f.stackless = false
	f.root_base = temp_mark(f.ctx.rt)
	b.jit_calls += 1
	if b.jit_calls < jit_cfg.call_threshold {return false}
	res, pc, sp := jit_fn_enter(f.ctx, f)
	if res == .resume {
		f.pc = pc
		f.sp = sp
	}
	return res == .ret
}

// The region compiled, or being compiled (its translation started when it is first seen hot): true when its code can
// run.
@(private = "file")
jit_region_ready :: proc(ctx: ^Context, f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop, sp: int) -> bool {
	switch jl.state {
	case .never:
		return false
	case .fresh:
		jit_build(ctx, f, b, jl, sp)
		return jl.state == .compiled
	case .pending:
		idx := jit_cfg.poll(jl.ticket)
		if idx < 0 {return false}
		jit_stats.pending -= 1
		if idx == 0 {
			jl.state = .never
			jit_stats.failed += 1
			return false
		}
		jl.index = u32(idx)
		jl.state = .compiled
		b.jit_active += 1
	case .compiled:
	}
	return true
}

// Runs the compiled code of the region on the frame (at its header, the operand stack at its entry height) and says
// where the interpreter carries on.
@(private = "file")
jit_run :: proc(ctx: ^Context, f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop) -> (res: Jit_Resume, pc: int, nsp: int) {
	rt := ctx.rt
	Jit_Fn :: #type proc "c" (args: [^]Value, locals: [^]Value, stack: [^]Value, arrays: [^]Jit_Arr, refs: [^]^Var_Ref, frame: ^Frame) -> u64
	fn := transmute(Jit_Fn)uintptr(jl.index)
	jit_stats.entries += 1
	arrays: [JIT_MAX_ARRS]Jit_Arr = ---
	for i in 0 ..< jl.n_arr {arrays[i] = jit_array_of(jit_slot_value(f, jl.arr_slots[i]))}
	index := jl.index
	rt.jit_depth += 1
	r := fn(f.args, f.locals, f.stack, raw_data(arrays[:]), f.closure_refs, f)
	rt.jit_depth -= 1
	if jl.whole && Jit_Exit((r >> 24) & 0xff) == .ret {
		// (the commonest exit of a function: nothing to count but the return)
		jit_stats.exits_return += 1
		return .ret, 0, 0
	}
	return jit_exit(f, b, jl, index, r)
}

// What an exit of the compiled code of the region (made at `index`) says, with the exit word r.
@(private = "file")
jit_exit :: proc(f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop, index: u32, r: u64) -> (res: Jit_Resume, pc: int, nsp: int) {
	kind := Jit_Exit((r >> 24) & 0xff)
	xpc := int(r & 0xffffff)
	xsp := int((r >> 32) & 0xffff)
	aux := int(r >> 48)
	if kind == .throw {
		// (the call is made again by the interpreter: its callee is now jit_rethrow, see jit_call)
		jit_stats.exits_throw += 1
		return .resume, xpc, xsp
	}
	if jl.state != .compiled || jl.index != index {
		// a call of the region's code ran it again in another frame, which changed what it is: this exit has nothing
		// more to say about it
		#partial switch kind {
		case .ret: return .ret, 0, 0
		case .guard: return .none, 0, 0
		}
		return .resume, xpc, xsp
	}
	switch kind {
	case .leave, .ret:
		// aux: the iterations this entry ran. A loop that runs a few iterations per entry costs more to enter than
		// the compiled code saves: after JIT_PROBE entries it is left to the interpreter
		jl.entries += 1
		jl.iters += aux
		if !jl.whole && jl.entries == JIT_PROBE && jl.iters < JIT_PROBE * JIT_MIN_ITERS {
			jl.state = .never
			b.jit_active -= 1
		}
		if kind == .ret {
			jit_stats.exits_return += 1
			return .ret, 0, 0
		}
		jit_stats.exits_leave += 1
		return .resume, xpc, xsp
	case .budget:
		f.ctx.rt.interrupt_counter = INTERRUPT_POLL_EVERY
		return .resume, xpc, xsp
	case .guard:
		jit_stats.exits_deopt += 1
		if jit_cfg.trace {
			jit_trace(cat(f.ctx, "jit: guard in ", atom_utf8(f.ctx.rt, b.func_name), jl.whole ? " (whole)" : "", " slot ", int_str(aux)))
		}
		jit_invalidate(f, b, jl, aux, true)
		return .none, 0, 0
	case .throw:
		return .resume, xpc, xsp
	case .deopt:
		jit_stats.exits_deopt += 1
		if jit_cfg.trace {
			op := xpc < len(b.code) ? reflect.enum_string(Opcode(b.code[xpc])) : "end"
			jit_trace(cat(f.ctx, "jit: deopt in ", atom_utf8(f.ctx.rt, b.func_name), jl.whole ? " (whole)" : "", " at ", int_str(xpc), " (", op, ") aux ", int_str(aux)))
		}
		if aux == JIT_AUX_LEARN || aux == JIT_AUX_NO_INLINE || aux == JIT_AUX_CALLEE {
			// a site met an object or a value it was not compiled for: it learns them, the region is translated again
			if jit_learn(f, b, jl, xpc, xsp, u32(aux)) {
				jl.learns += 1
				jl.state = jl.learns > JIT_MAX_LEARNS ? .never : .fresh
				b.jit_active -= 1
			} else {
				// nothing to learn (a shape the site does not take, more shapes than it takes): a deopt
				jl.deopts += 1
				jit_invalidate(f, b, jl, JIT_AUX_NONE, false)
			}
		} else {
			jl.deopts += 1
			jit_invalidate(f, b, jl, aux, false)
		}
		return .resume, xpc, xsp
	}
	return .none, 0, 0
}

// Is the loop at `header` one the JIT took (compiled, being compiled, to compile again)? The interpreter's hot loop
// then leaves at its back edges, which the full dispatch offers to jit_back_edge; the other loops of the function stay
// in the hot loop.
jit_loop_taken :: #force_inline proc "contextless" (info: ^Jit_Info, header: int) -> bool {
	for i in 0 ..< info.n {
		if info.loops[i].header == header {return info.loops[i].state != .never}
	}
	return false
}
// What the compiled code needs of the array in a local: a live fixed-length Array, or a fixed-length typed array over a
// live, writable buffer with Number elements (the interpreter's own fast-path conditions, ta_fast_ptr).
jit_array_of :: proc(v: Value) -> Jit_Arr {
	if v.tag != .object {return {}}
	o := as_obj(v)
	if o.fast_array {
		if o.class != .array {return {}}
		ad, ok := &o.data.(Array_Data)
		if !ok {return {}}
		return Jit_Arr{base = u32(uintptr(ad.values)), count = ad.count, length = array_length_u32(o), kind = .values}
	}
	if !is_typed_array_class(o.class) {return {}}
	ta, ok := o.data.(^Typed_Array)
	if !ok || ta.track_rab {return {}}
	ab, ok2 := ta.buffer.data.(^Array_Buffer)
	if !ok2 || ab.detached || ab.immutable || ab.data == nil {return {}}
	e := class_elem(o.class)
	if ta.offset + ta.length * elem_size[e] > ab.byte_length {return {}}
	kind: Jit_Arr_Kind
	#partial switch e {
	case .i8: kind = .i8
	case .u8: kind = .u8
	case .i16: kind = .i16
	case .u16: kind = .u16
	case .i32: kind = .i32
	case .u32: kind = .u32
	case .f32: kind = .f32
	case .f64: kind = .f64
	case: return {}
	}
	return Jit_Arr{base = u32(uintptr(&ab.data[ta.offset])), count = u32(ta.length), length = u32(ta.length), kind = kind}
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
	if jl.deopts > JIT_MAX_DEOPTS || jl.compiles - jl.learns >= JIT_MAX_REJITS {
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

// The collector's part: the shapes the sites learned and what the compiled code compares against stay alive.
jit_mark :: proc(rt: ^Runtime, info: ^Jit_Info) {
	mark :: proc(rt: ^Runtime, jl: ^Jit_Loop) {
		for k in 0 ..< jl.n_keep {mark_cell(rt, jl.keep[k])}
		for s in 0 ..< jl.n_sites {
			site := &jl.sites[s]
			for k in 0 ..< site.n {mark_cell(rt, site.shapes[k])}
			if site.callee != nil {mark_cell(rt, site.callee)}
		}
	}
	for i in 0 ..< info.n {mark(rt, &info.loops[i])}
	mark(rt, &info.fn)
}

// The site of the instruction at pc (nil: none, and no room for one when add).
@(private = "file")
jit_site_of :: proc(jl: ^Jit_Loop, pc: int, add: bool) -> ^Jit_Site {
	for i in 0 ..< jl.n_sites {if jl.sites[i].pc == pc {return &jl.sites[i]}}
	if !add || jl.n_sites >= JIT_MAX_SITES {return nil}
	jl.sites[jl.n_sites] = Jit_Site{pc = pc}
	jl.n_sites += 1
	return &jl.sites[jl.n_sites - 1]
}

// The type a value is taken for, widened by what the site saw before.
@(private = "file")
jit_ty_of :: proc(v: Value) -> Jit_Ty {
	#partial switch v.tag {
	case .int: return .I
	case .float: return .F
	case .bool: return .B
	case .object: return .P
	}
	return .V
}

// (changed: the site's type is wider than it was)
@(private = "file")
jit_site_see :: proc(site: ^Jit_Site, v: Value) -> (changed: bool) {
	t := jit_ty_of(v)
	if !site.typed {
		site.ty = t
		site.typed = true
		return true
	}
	if site.ty == t {return false}
	w: Jit_Ty = (site.ty == .I && t == .F) || (site.ty == .F && t == .I) ? .F : .V
	changed = w != site.ty
	site.ty = w
	return
}

// The shape of o for the site (sh: o's, or the one the translation knows o takes by then): a shape it can guard (not
// lazy), if there is room. changed: new, or one the code reads inline (then what missed is further on: a prototype, a
// dictionary's key).
@(private = "file")
jit_site_add_shape :: proc(site: ^Jit_Site, o: ^Object, sh: ^Shape) -> (changed: bool) {
	if sh.lazy != nil {return false}
	for k in 0 ..< site.n {if site.shapes[k] == sh {return k in site.inline}}
	if site.n >= JIT_SITE_SHAPES {return false}
	site.shapes[site.n] = sh
	site.classes[site.n] = o.class
	site.n += 1
	return true
}

// Classes whose objects, for a key that is not an index, have no say in a [[Get]] that goes on to their prototype (a host
// object: one without exotic hooks, Object.host_exotic checked where the code reads past it).
@(private = "file")
jit_ordinary_class :: proc(c: Class_ID) -> bool {
	#partial switch c {
	case .object, .array, .arguments, .error, .number, .boolean, .symbol, .bigint, .date, .regexp, .c_function,
	     .bytecode_function, .bound_function, .jsmap, .set, .weakmap, .weakset, .promise, .host:
		return true
	}
	return false
}

// Where a read of `a` from an object of shape `sh` finds a data property (an accessor too when `accessors`: its getter is
// called), as the hot loop's lookup does (calling nothing): in the object itself (depth 0) or in the prototype
// objs[depth - 1], whose shape is shapes[depth - 1], the objects before it walked without finding it (a dictionary shape,
// the object's or a prototype's, guarded by its version too: a key added in place would shadow what is found further).
// ok = false: an accessor not asked for, a lazy shape, an exotic object on the way, absent, or too deep.
Jit_Lookup :: struct {
	depth:    int,
	idx:      int,
	accessor: bool,
	objs:     [JIT_MAX_CHAIN]^Object,
	shapes:   [JIT_MAX_CHAIN]^Shape,
}

@(private = "file")
jit_lookup :: proc(sh: ^Shape, a: Atom, accessors := false) -> (l: Jit_Lookup, ok: bool) {
	if sh.lazy != nil {return}
	if i := shape_lookup(sh, a); i >= 0 {
		l.accessor = sh.props[i].kind == .accessor
		if sh.props[i].kind != .data && !(accessors && l.accessor) {return}
		l.idx = i
		return l, true
	}
	p := sh.proto
	for p != nil {
		if l.depth >= JIT_MAX_CHAIN {return}
		ps := p.shape
		if ps.lazy != nil {return}
		l.objs[l.depth] = p
		l.shapes[l.depth] = ps
		l.depth += 1
		if i := shape_lookup(ps, a); i >= 0 {
			l.accessor = ps.props[i].kind == .accessor
			if ps.props[i].kind != .data && !(accessors && l.accessor) {return}
			l.idx = i
			return l, true
		}
		if p.fast_array || p.class == .proxy || p.class == .module_ns || p.class == .string || p.host_exotic || is_typed_array_class(p.class) {return}
		p = ps.proto
	}
	return
}

// The value a read of `a` from o finds, calling nothing (ok = false: see jit_lookup).
@(private = "file")
jit_peek_field :: proc(o: ^Object, a: Atom) -> (v: Value, ok: bool) {
	l, found := jit_lookup(o.shape, a)
	if !found {return}
	holder := l.depth == 0 ? o : l.objs[l.depth - 1]
	return holder.slots[l.idx].value, true
}

// The global `a` as get_var finds it, calling nothing.
@(private = "file")
jit_peek_global :: proc(ctx: ^Context, a: Atom) -> (v: Value, ok: bool) {
	gv := ctx.global_var_obj
	if gv.shape.lazy != nil {return}
	if i := shape_lookup(gv.shape, a); i >= 0 {return gv.slots[i].value, true}
	g := ctx.global_obj
	if g.shape.lazy != nil {return}
	j := shape_lookup(g.shape, a)
	if j < 0 || g.shape.props[j].kind != .data {return}
	return g.slots[j].value, true
}

// The element a read finds in a fast array, calling nothing.
@(private = "file")
jit_peek_elem :: proc(o: Value, k: Value) -> (v: Value, ok: bool) {
	if o.tag != .object || k.tag != .int || k.u.i < 0 {return}
	p := as_obj(o)
	if !p.fast_array || p.class != .array {return}
	ad := &p.data.(Array_Data)
	if u32(k.u.i) >= ad.count {return}
	return ad.values[k.u.i], true
}

// A learn exit at the site of xpc: the operand stack is as the instruction there would find it. changed: the site
// learned something (or what it guards changed); otherwise the exit is only a deopt.
@(private = "file")
jit_learn :: proc(f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop, xpc: int, xsp: int, aux: u32) -> (changed: bool) {
	site := jit_site_of(jl, xpc, true)
	if site == nil {return false}
	st := f.stack
	op := Opcode(b.code[xpc])
	no_inline := aux == JIT_AUX_NO_INLINE
	if aux == JIT_AUX_CALLEE {
		// (a call's callee, under its arguments; a construction's under new.target too)
		argc := op >= .call0 && op <= .call3 ? int(op) - int(Opcode.call0) : jr_u16(b.code, xpc + 1)
		cv := st[xsp - argc - (op == .call_constructor ? 2 : 1)]
		if cv.tag != .object || site.callee == as_obj(cv) {return false}
		site.callee = as_obj(cv)
		return true
	}
	#partial switch op {
	case .get_field, .get_field2, .get_length:
		o := st[xsp - 1]
		if o.tag == .string && !site.str {
			site.str = true
			return true
		}
		if o.tag != .object {return false}
		changed = jit_site_add_shape(site, as_obj(o), as_obj(o).shape)
		a := op == .get_length ? pa(.A_length) : Atom(jr_u32(b.code, xpc + 1))
		if v, ok := jit_peek_field(as_obj(o), a); ok {changed = jit_site_see(site, v) || changed}
	case .put_field:
		o := st[xsp - 2]
		if o.tag == .object {changed = jit_site_add_shape(site, as_obj(o), as_obj(o).shape)}
	case .get_var, .get_var_undef, .put_var:
		// (the realm's shapes changed, or the value's type)
		changed = true
		if v, ok := jit_peek_global(f.ctx, Atom(jr_u32(b.code, xpc + 1))); ok && op != .put_var {jit_site_see(site, v)}
	case .get_var_ref, .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3, .get_var_ref_check:
		idx, _, _, _, _ := jit_var_ref_op(op, b.code, xpc)
		changed = jit_site_see(site, f.closure_refs[idx].pvalue^)
	case .get_array_el, .get_array_el2:
		if v, ok := jit_peek_elem(st[xsp - 2], st[xsp - 1]); ok {changed = jit_site_see(site, v)}
	case .call0, .call1, .call2, .call3, .call, .call_method:
		// the callee inlined there is another function (inlined in its turn, once: a second change means the site calls
		// more than one), or met what it was not compiled for (it is called instead)
		if !no_inline && site.n == 0 {
			site.n = 1
			return true
		}
		// (the first time, inlined again with its numbers taken for doubles; then called)
		changed = !(site.typed && site.ty == .V)
		site.ty = site.typed ? .V : .F
		site.typed = true
	case:
		// an instruction that takes numbers from values: the numbers it found (an add the strings too: it adds values then)
		for i in max(0, xsp - int(opcode_info[op].n_pop)) ..< xsp {
			v := st[i]
			if v.tag == .int || v.tag == .float || (op == .add && v.tag == .string) {changed = jit_site_see(site, v) || changed}
		}
	}
	return
}
// ---------------------------------------------------------------------------------------------------------------------
// Translation

Jc :: struct {
	rt:        ^Runtime,
	ctx:       ^Context,   // the function's realm (its globals)
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
	a0:        u32,
	arr_ord:   []int,    // per slot: its index in jl.arr_slots, or -1
	ft0:       u32,
	r64:       u32,
	ni, nf:    u32,
	out:       Wbuf,
	lidx:      []i32,
	lpcs:      []int,
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
	fast_bit:    u8,   // Object.bits: fast_array, is_htmldda, extensible
	htmldda_bit: u8,
	extensible_bit: u8,
	host_exotic_bit: u8,
	ctor_bits:   u8,   // Object.bits: is_constructor, ctor_only (a getter called as a native function has neither)
	calls:       bool, // the region calls (locals a closure may reach stay in memory)
	helpers:     bool, // the code calls the engine's helpers (they are imported)
	table:       bool, // the code calls compiled code through the engine's table (it is imported)
	shadows:     [JIT_MAX_SHADOWS]Jit_Shadow,   // the objects seen whose properties the translation appended, and their shapes then
	n_shadows:   int,
	// a callee being inlined (jit_inline): its code replaces the loop's, its slots are stack entries
	inl_depth:   int,
	inl_n:       int,   // the stack height and the pc of the outermost inlined call: a deopt in a callee resumes there
	inl_pc:      int,
	inl_first:   int,   // the entry of the callee's first argument, of its first local, of `this` (-1: none)
	inl_locals:  int,
	inl_nargs:   int,
	inl_this:    int,
	site_base:   int,   // added to a pc for its site (an inlined callee's sites are the call's)
	inl_wide:    bool,  // the callee's numbers are taken for doubles (it left once on an int that was not one)
}

Jit_Shadow :: struct {
	o:  ^Object,
	sh: ^Shape,
}

// What the compiled code reads of an object, a shape, a property and an array (the engine's own layout on wasm32)
OBJ_SHAPE :: u32(offset_of(Object, shape))
OBJ_SLOTS :: u32(offset_of(Object, slots))
OBJ_CLASS :: u32(offset_of(Object, class))
OBJ_BITS :: u32(offset_of(Object, bits))
OBJ_DATA :: u32(offset_of(Object, data))
OBJ_SLOT_CAP :: u32(offset_of(Object, slot_cap))
ARR_VALUES :: u32(offset_of(Array_Data, values))
ARR_COUNT :: u32(offset_of(Array_Data, count))
ARR_CAP :: u32(offset_of(Array_Data, cap))
#assert(size_of(Object_Data) % size_of(u32) == 0)
SHAPE_PROPS :: u32(offset_of(Shape, props))
SHAPE_VERSION :: u32(offset_of(Shape, version))
SHAPE_PROPS_LEN :: SHAPE_PROPS + u32(offset_of(runtime.Raw_Dynamic_Array, len))
PROP_SIZE :: u32(size_of(Shape_Prop))
PROP_ATOM :: u32(offset_of(Shape_Prop, atom))
PROP_FLAGS :: u32(offset_of(Shape_Prop, flags))
PROP_KIND :: u32(offset_of(Shape_Prop, kind))
VARREF_PVALUE :: u32(offset_of(Var_Ref, pvalue))
GETSET_GETTER :: u32(offset_of(Prop_Slot, getset) + offset_of(Getset, getter))
GETSET_SETTER :: u32(offset_of(Prop_Slot, getset) + offset_of(Getset, setter))
STR_LEN :: u32(offset_of(JS_String, len))
STR_WIDE :: u32(offset_of(JS_String, is_wide))
STR_ROPE :: u32(offset_of(JS_String, is_rope))
STR_DATA :: u32(offset_of(JS_String, data))
FRAME_THIS :: u32(offset_of(Frame, this_val))
VALUE_SHIFT :: 4   // log2 of size_of(Value)
// what a direct call writes of the frame it pushes (as frame_push does) and of the runtime
FRAME_PREV :: u32(offset_of(Frame, prev))
FRAME_CTX :: u32(offset_of(Frame, ctx))
FRAME_CALLER_CTX :: u32(offset_of(Frame, caller_ctx))
FRAME_FUNC :: u32(offset_of(Frame, func))
FRAME_BC :: u32(offset_of(Frame, bc))
FRAME_NEW_TARGET :: u32(offset_of(Frame, new_target))
FRAME_ARGS :: u32(offset_of(Frame, args))
FRAME_ARG_BUF_LEN :: u32(offset_of(Frame, arg_buf_len))
FRAME_ARGC :: u32(offset_of(Frame, argc))
FRAME_LOCALS :: u32(offset_of(Frame, locals))
FRAME_STACK :: u32(offset_of(Frame, stack))
FRAME_SP :: u32(offset_of(Frame, sp))
FRAME_VAR_REFS :: u32(offset_of(Frame, var_refs))
FRAME_PC :: u32(offset_of(Frame, pc))
FRAME_EXTRA_ARGS :: u32(offset_of(Frame, extra_args))
FRAME_CORO :: u32(offset_of(Frame, coro))
FRAME_SEG_INDEX :: u32(offset_of(Frame, seg_index))
FRAME_SEG_TOP :: u32(offset_of(Frame, seg_top))
FRAME_STORAGE :: u32(offset_of(Frame, storage))
FRAME_STORAGE_LEN :: u32(offset_of(Frame, storage_len))
FRAME_PENDING_THROW :: u32(offset_of(Frame, pending_throw))
FRAME_CLOSURE_REFS :: u32(offset_of(Frame, closure_refs))
FRAME_ROOT_BASE :: u32(offset_of(Frame, root_base))
FRAME_STACKLESS :: u32(offset_of(Frame, stackless))
RT_CUR_FRAME :: u32(offset_of(Runtime, cur_frame))
RT_STACK_DEPTH :: u32(offset_of(Runtime, stack_depth))
RT_JIT_DEPTH :: u32(offset_of(Runtime, jit_depth))
RT_INTERRUPT_COUNTER :: u32(offset_of(Runtime, interrupt_counter))
RT_MAX_STACK_DEPTH :: u32(offset_of(Runtime, config) + offset_of(Host_Config, max_stack_depth))
RT_TEMP_ROOTS_LEN :: u32(offset_of(Runtime, temp_roots) + offset_of(runtime.Raw_Dynamic_Array, len))
RT_VSTACK_DATA :: u32(offset_of(Runtime, vstack) + offset_of(runtime.Raw_Dynamic_Array, data))
RT_VSTACK_LEN :: u32(offset_of(Runtime, vstack) + offset_of(runtime.Raw_Dynamic_Array, len))
RT_VSTACK_CUR :: u32(offset_of(Runtime, vstack_cur))
SEG_SIZE :: u32(size_of(Value_Segment))
SEG_DATA :: u32(offset_of(Value_Segment, data) + offset_of(runtime.Raw_Slice, data))
SEG_LEN :: u32(offset_of(Value_Segment, data) + offset_of(runtime.Raw_Slice, len))
SEG_TOP :: u32(offset_of(Value_Segment, top))
// a function's compiled code as a direct call reads it (Function_Bytecode.jit, its fn)
INFO_FN_STATE :: u32(offset_of(Jit_Info, fn) + offset_of(Jit_Loop, state))
INFO_FN_INDEX :: u32(offset_of(Jit_Info, fn) + offset_of(Jit_Loop, index))
INFO_FN_N_ARR :: u32(offset_of(Jit_Info, fn) + offset_of(Jit_Loop, n_arr))
// what an object the code allocates itself writes (j_alloc: cell_new, object_new_shape) of the pool and the cell
RT_POOL_FREE :: u32(offset_of(Runtime, pool_free))
RT_POOL_BUMP :: u32(offset_of(Runtime, pool_bump))
RT_POOL_LEFT :: u32(offset_of(Runtime, pool_left))
RT_CELLS :: u32(offset_of(Runtime, cells))
RT_CELL_COUNT :: u32(offset_of(Runtime, cell_count))
RT_HEAP_BYTES :: u32(offset_of(Runtime, heap_bytes))
RT_PEAK_HEAP_BYTES :: u32(offset_of(Runtime, peak_heap_bytes))
CELL_GC_NEXT :: u32(offset_of(Cell, gc_next))
CELL_SIZE :: u32(offset_of(Cell, size))
CELL_KIND :: u32(offset_of(Cell, kind))
POOL_BLOCK_NEXT :: u32(offset_of(Pool_Block, next))
JIT_OBJ_BYTES :: size_of(Object) + INLINE_SLOTS * size_of(Prop_Slot)               // a plain object with its inline slots
JIT_ARR_MAX :: POOL_MAX_BYTES / size_of(Value)   // the entries of an array literal the code allocates itself, at most
#assert(JIT_OBJ_BYTES <= POOL_MAX_BYTES && POOL_GRAIN % size_of(i64) == 0 && size_of(Cell_Kind) == 1 && size_of(Class_ID) == 1)
FUNC_BC :: OBJ_DATA + u32(offset_of(Func_Data, bc))   // (a bytecode function's data is its Func_Data)
FUNC_VAR_REFS :: OBJ_DATA + u32(offset_of(Func_Data, var_refs))

#assert(size_of(Value) == 1 << VALUE_SHIFT && size_of(Prop_Slot) == size_of(Value))
#assert(size_of(Atom) == 4 && size_of(Prop_Flags) == 1 && size_of(Prop_Kind) == 1 && size_of(Class_ID) == 1)
when ODIN_ARCH == .wasm32 {
	#assert(size_of(rawptr) == 4 && size_of(int) == 4)
}

// The bit of Object.bits that a field of it is.
@(private = "file")
Jit_Object_Bit :: enum u8 {fast_array, is_htmldda, extensible, host_exotic, is_constructor, ctor_only}

@(private = "file")
jit_object_bit :: proc(which: Jit_Object_Bit) -> u8 {
	o: Object
	switch which {
	case .fast_array: o.fast_array = true
	case .extensible: o.extensible = true
	case .host_exotic: o.host_exotic = true
	case .is_constructor: o.is_constructor = true
	case .ctor_only: o.ctor_only = true
	case .is_htmldda: o.is_htmldda = true
	}
	return (cast(^u8)(uintptr(&o) + uintptr(OBJ_BITS)))^
}

// A cell the compiled code compares against or reads: kept alive with the loop (false: no room).
@(private = "file")
j_keep :: proc(c: ^Jc, cell: ^Cell) -> bool {
	jl := c.jl
	for k in 0 ..< jl.n_keep {if jl.keep[k] == cell {return true}}
	if jl.n_keep >= JIT_MAX_KEEP {
		j_fail(c, "too many shapes to guard")
		return false
	}
	jl.keep[jl.n_keep] = cell
	jl.n_keep += 1
	return true
}

// the function's parameters and fixed locals
P_ARGS :: 0
P_LOCALS :: 1
P_STACK :: 2
P_ARRAYS :: 3
P_REFS :: 4   // the function's closure cells (Frame.closure_refs)
P_FRAME :: 5  // the frame, for the helpers
JIT_PARAMS :: 6
I_PC :: 6
I_SP :: 7
I_KIND :: 8
I_AUX :: 9
I_BUDGET :: 10
I_T0 :: 11
I_T1 :: 12
I_T2 :: 13   // (I_T2 .. I_T6: a direct call's own, j_direct_call)
I_T3 :: 14
I_T4 :: 15
I_T5 :: 16
I_T6 :: 17
I_FIRST :: 18

Jit_Outcome :: enum u8 {ok, refuse, restart}

@(private = "file")
j_fail :: proc(c: ^Jc, why: string) {
	if !c.fail {c.fail = true; c.why = why}
}

@(private = "file")
j_op :: #force_inline proc(c: ^Jc, op: u8) {append(&c.out, op)}

// a call of the engine's helper h (which the module then imports)
@(private = "file")
j_helper :: proc(c: ^Jc, h: Jit_Helper) {
	c.helpers = true
	j_op(c, W_CALL)
	w_uleb(&c.out, u64(h))
}

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
	case .I, .B, .O, .P, .V, .M: return c.si0 + u32(d)
	}
	return 0
}

// the entry `to` becomes a copy of `from` (of type t: a V is two Wasm locals, an O none)
@(private = "file")
j_copy :: proc(c: ^Jc, from: int, to: int, t: Jit_Ty) {
	if t == .O {return}
	j_lget(c, j_sloc(c, from, t))
	j_lset(c, j_sloc(c, to, t))
	if t == .V {
		j_lget(c, c.sl0 + u32(from))
		j_lset(c, c.sl0 + u32(to))
	}
}

@(private = "file")
j_push :: proc(c: ^Jc, t: Jit_Ty) -> int {
	if c.st.n >= c.ss {
		j_fail(c, "operand stack too deep")
		return 0
	}
	c.st.t[c.st.n] = t
	c.st.v[c.st.n] = EXCEPTION
	c.st.k[c.st.n] = nil
	c.st.n += 1
	return c.st.n - 1
}

@(private = "file")
j_is_num :: #force_inline proc(t: Jit_Ty) -> bool {return t == .I || t == .F || t == .L}

// Element access ---------------------------------------------------------------------------------------------------

// leaves nothing on the Wasm stack: the index of the stack entry `idx` is within the array's count, or the instruction
// at pc is left to the interpreter
@(private = "file")
j_bounds :: proc(c: ^Jc, ord: int, idx: int, pc: int) -> bool {
	count := c.a0 + 3 * u32(ord) + 1
	switch c.st.t[idx] {
	case .I, .B:
		j_lget(c, j_si(c, idx))
		j_lget(c, count)
		j_op(c, W_I32_GE_U)
	case .L:
		j_lget(c, c.sl0 + u32(idx))
		j_lget(c, count)
		j_op(c, W_I64_EXTEND_I32_U)
		j_op(c, W_I64_GE_U)
	case .F, .O, .P, .V, .M:
		j_fail(c, "array index that is not an integer")
		return false
	}
	j_deopt_if(c, pc)
	return true
}

// the address of element idx (already in bounds) on the Wasm stack
@(private = "file")
j_elem_addr :: proc(c: ^Jc, ord: int, idx: int, kind: Jit_Arr_Kind) {
	j_lget(c, c.a0 + 3 * u32(ord))
	if c.st.t[idx] == .L {
		j_lget(c, c.sl0 + u32(idx))
		j_op(c, W_I32_WRAP_I64)
	} else {
		j_lget(c, j_si(c, idx))
	}
	shift: i32
	switch kind {
	case .none: shift = 0
	case .values: shift = 4
	case .i8, .u8: shift = 0
	case .i16, .u16: shift = 1
	case .i32, .u32, .f32: shift = 2
	case .f64: shift = 3
	}
	if shift != 0 {
		j_i32(c, shift)
		j_op(c, W_I32_SHL)
	}
	j_op(c, W_I32_ADD)
}

// The type an element read of an Array takes its elements for: what the site saw, or what the first elements of the
// array (its value when the loop was translated) are.
@(private = "file")
j_elem_ty :: proc(c: ^Jc, site: ^Jit_Site, arr: Value) -> Jit_Ty {
	if site.typed {return site.ty}
	if arr.tag == .object {
		if ad, ok := &as_obj(arr).data.(Array_Data); ok {
			for i in 0 ..< min(int(ad.count), JIT_ELEM_PEEK) {jit_site_see(site, ad.values[i])}
		}
	}
	t := site.typed ? site.ty : Jit_Ty.I
	return c.inl_wide && t == .I ? .F : t
}

// An Array reached through the object of entry `o` (not a held local): it must be a fast Array and the index of entry
// `idx` within its count, or the instruction is left to the interpreter. The element's address goes to I_T0.
@(private = "file")
j_parr_addr :: proc(c: ^Jc, o: int, idx: int, pc: int) -> bool {
	if c.st.t[idx] != .I {
		j_fail(c, "index that is not an int")
		return false
	}
	p := j_si(c, o)
	j_lget(c, p)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_CLASS)
	j_i32(c, i32(Class_ID.array))
	j_op(c, W_I32_NE)
	j_lget(c, p)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_BITS)
	j_i32(c, i32(c.fast_bit))
	j_op(c, W_I32_AND)
	j_op(c, W_I32_EQZ)
	j_op(c, W_I32_OR)
	j_deopt_if(c, pc)
	j_lget(c, j_si(c, idx))
	j_lget(c, p)
	j_mem(c, W_I32_LOAD, 2, OBJ_DATA + ARR_COUNT)
	j_op(c, W_I32_GE_U)
	j_deopt_if(c, pc)
	j_lget(c, p)
	j_mem(c, W_I32_LOAD, 2, OBJ_DATA + ARR_VALUES)
	j_lget(c, j_si(c, idx))
	j_i32(c, VALUE_SHIFT)
	j_op(c, W_I32_SHL)
	j_op(c, W_I32_ADD)
	j_lset(c, I_T0)
	return true
}

// The V entry d is an object (or the instruction at pc is left to the interpreter, aux: for its site to learn what it is
// instead): it becomes a P.
@(private = "file")
j_as_obj :: proc(c: ^Jc, d: int, pc: int, aux: u32 = JIT_AUX_NONE) {
	if c.st.t[d] != .V {return}
	j_lget(c, j_si(c, d))
	j_i32(c, i32(Tag.object))
	j_op(c, W_I32_NE)
	j_deopt_if(c, pc, aux)
	j_lget(c, c.sl0 + u32(d))
	j_op(c, W_I32_WRAP_I64)
	j_lset(c, j_si(c, d))
	c.st.t[d] = .P
}

@(private = "file")
jit_get_array_el :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	n := c.st.n
	j_as_obj(c, n - 2, pc)
	ta := c.st.t[n - 2]
	idx := n - 1
	site := jit_site_of(c.jl, c.site_base + pc, true)
	if site == nil {
		j_fail(c, "too many sites")
		return false
	}
	shadow := EXCEPTION
	if v, ok := jit_peek_elem(c.st.v[n - 2], c.st.v[idx]); ok {shadow = v}
	rt: Jit_Ty
	if ta == .P {
		if !j_parr_addr(c, n - 2, idx, pc) {return false}
		rt = j_elem_ty(c, site, c.st.v[n - 2])
		j_check_value(c, I_T0, rt, pc)
	} else {
		if ta != .O {
			j_fail(c, "element of something that is not an array")
			return false
		}
		ord := int(c.st.a[n - 2])
		kind := c.jl.arr_kinds[ord]
		if !j_bounds(c, ord, idx, pc) {return false}
		j_elem_addr(c, ord, idx, kind)
		switch kind {
		case .none:
			j_fail(c, "no array")
			return false
		case .values:
			j_lset(c, I_T0)
			rt = j_elem_ty(c, site, c.st.v[n - 2])
			j_check_value(c, I_T0, rt, pc)
		case .i8: rt = .I; j_mem(c, W_I32_LOAD8_S, 0, 0)
		case .u8: rt = .I; j_mem(c, W_I32_LOAD8_U, 0, 0)
		case .i16: rt = .I; j_mem(c, W_I32_LOAD16_S, 1, 0)
		case .u16: rt = .I; j_mem(c, W_I32_LOAD16_U, 1, 0)
		case .i32: rt = .I; j_mem(c, W_I32_LOAD, 2, 0)
		case .u32:
			rt = .L
			j_mem(c, W_I32_LOAD, 2, 0)
			j_op(c, W_I64_EXTEND_I32_U)
		case .f32:
			rt = .F
			j_mem(c, W_F32_LOAD, 2, 0)
			j_op(c, W_F64_PROMOTE_F32)
		case .f64:
			rt = .F
			j_mem(c, W_F64_LOAD, 3, 0)
		}
		if kind != .values {
			// the result replaces the index (get_array_el2 keeps the array under it, get_array_el drops it too)
			if op == .get_array_el {c.st.n -= 2} else {c.st.n -= 1}
			d := j_push(c, rt)
			j_lset(c, j_sloc(c, d, rt))
			return true
		}
	}
	if op == .get_array_el {c.st.n -= 2} else {c.st.n -= 1}
	d := j_push(c, rt)
	j_take_value(c, I_T0, rt, d)
	c.st.v[d] = shadow
	return true
}

@(private = "file")
jit_put_array_el :: proc(c: ^Jc, pc: int) -> bool {
	n := c.st.n
	idx, v := n - 2, n - 1
	tv := c.st.t[v]
	j_as_obj(c, n - 3, pc)
	if c.st.t[n - 3] == .P {
		if !j_parr_addr(c, n - 3, idx, pc) {return false}
		if !j_store_value(c, v, pc) {return false}
		c.st.n -= 3
		return true
	}
	if c.st.t[n - 3] != .O {
		j_fail(c, "store into something that is not an array")
		return false
	}
	ord := int(c.st.a[n - 3])
	kind := c.jl.arr_kinds[ord]
	if kind != .values && !j_is_num(tv) && tv != .B {
		j_fail(c, "store of something that is not a number into a typed array")
		return false
	}
	if !j_bounds(c, ord, idx, pc) {return false}
	j_elem_addr(c, ord, idx, kind)
	switch kind {
	case .none:
		j_fail(c, "no array")
		return false
	case .values:
		j_lset(c, I_T0)
		if !j_store_value(c, v, pc) {return false}
	case .i8, .u8:
		j_get_i32(c, v, pc)
		j_mem(c, W_I32_STORE8, 0, 0)
	case .i16, .u16:
		j_get_i32(c, v, pc)
		j_mem(c, W_I32_STORE16, 1, 0)
	case .i32, .u32:
		j_get_i32(c, v, pc)
		j_mem(c, W_I32_STORE, 2, 0)
	case .f32:
		j_get_f(c, v)
		j_op(c, W_F32_DEMOTE_F64)
		j_mem(c, W_F32_STORE, 2, 0)
	case .f64:
		j_get_f(c, v)
		j_mem(c, W_F64_STORE, 3, 0)
	}
	c.st.n -= 3
	return true
}

// The stack entry d stored as a Value at the address in I_T0 (an integer beyond the int32 range leaves the instruction
// at pc to the interpreter).
@(private = "file")
j_store_value :: proc(c: ^Jc, d: int, pc: int) -> bool {
	j_fits_value(c, d, pc)
	j_store_entry(c, d, I_T0, 0)
	return !c.fail
}

// The stack entry d can be stored as a Value, or the instruction at pc is left to the interpreter (an integer beyond
// the int32 range; before anything of the instruction is done: a property it appends, a shape it changes).
@(private = "file")
j_fits_value :: proc(c: ^Jc, d: int, pc: int) {
	if c.st.t[d] != .L {return}
	j_l_not_i32(c, d)
	j_deopt_if(c, pc)
}

// The Value at the address in local `addr` is of type t (a V: anything but a hole of the TDZ), or the site at pc learns
// what it is. Its tag stays in I_T1 for j_take_value.
@(private = "file")
j_check_value :: proc(c: ^Jc, addr: u32, t: Jit_Ty, pc: int) {
	j_lget(c, addr)
	j_mem(c, W_I32_LOAD8_U, 0, 0)
	j_lset(c, I_T1)
	j_lget(c, I_T1)
	#partial switch t {
	case .I: j_i32(c, i32(Tag.int))
	case .B: j_i32(c, i32(Tag.bool))
	case .P: j_i32(c, i32(Tag.object))
	case .V: j_i32(c, i32(Tag.uninitialized))
	case .F:
		j_i32(c, i32(Tag.float))
		j_op(c, W_I32_NE)
		j_lget(c, I_T1)
		j_i32(c, i32(Tag.int))
	case:
		j_fail(c, "a value of this type is not read from memory")
		return
	}
	j_op(c, t == .V ? W_I32_EQ : W_I32_NE)
	if t == .F {j_op(c, W_I32_AND)}
	j_deopt_if(c, pc, JIT_AUX_LEARN)
}

// The Value at the address in `addr` (checked by j_check_value) into the entry d of type t.
@(private = "file")
j_take_value :: proc(c: ^Jc, addr: u32, t: Jit_Ty, d: int) {
	#partial switch t {
	case .I, .P:
		j_lget(c, addr)
		j_mem(c, W_I32_LOAD, 2, 8)
		j_lset(c, j_si(c, d))
	case .B:
		j_lget(c, addr)
		j_mem(c, W_I32_LOAD8_U, 0, 8)
		j_lset(c, j_si(c, d))
	case .F:
		j_lget(c, addr)
		j_mem(c, W_F64_LOAD, 3, 8)
		j_lget(c, addr)
		j_mem(c, W_I32_LOAD, 2, 8)
		j_op(c, W_F64_CONVERT_I32_S)
		j_lget(c, I_T1)
		j_i32(c, i32(Tag.float))
		j_op(c, W_I32_EQ)
		j_op(c, W_SELECT)
		j_lset(c, j_sf(c, d))
	case .V:
		j_lget(c, I_T1)
		j_lset(c, j_si(c, d))
		j_lget(c, addr)
		j_mem(c, W_I64_LOAD, 3, 8)
		j_lset(c, c.sl0 + u32(d))
	}
}

// Properties ---------------------------------------------------------------------------------------------------------

// The i32 local that holds the object of entry d (an O's is read from its local's memory).
@(private = "file")
j_obj_local :: proc(c: ^Jc, d: int) -> (u32, bool) {
	#partial switch c.st.t[d] {
	case .P:
		return j_si(c, d), true
	case .O:
		base, off := j_slot_addr(c, c.jl.arr_slots[c.st.a[d]])
		j_lget(c, base)
		j_mem(c, W_I32_LOAD, 2, off + 8)
		j_lset(c, I_T1)
		return I_T1, true
	}
	j_fail(c, "property of something that is not an object")
	return 0, false
}

// The shape in memory at (the object `obj` local or the constant object) is `sh`, or the site at pc learns.
@(private = "file")
j_guard_shape :: proc(c: ^Jc, holder: ^Object, obj: u32, sh: ^Shape, pc: int) {
	if holder != nil {j_i32(c, i32(uintptr(holder)))} else {j_lget(c, obj)}
	j_mem(c, W_I32_LOAD, 2, OBJ_SHAPE)
	j_i32(c, i32(uintptr(sh)))
	j_op(c, W_I32_NE)
	j_deopt_if(c, pc, JIT_AUX_LEARN)
}

// A dictionary shape walked past (it does not have the key): unchanged since the translation, or the site learns.
@(private = "file")
j_guard_version :: proc(c: ^Jc, sh: ^Shape, pc: int) {
	j_i32(c, i32(uintptr(sh)))
	j_mem(c, W_I32_LOAD, 2, SHAPE_VERSION)
	j_i32(c, i32(sh.version))
	j_op(c, W_I32_NE)
	j_deopt_if(c, pc, JIT_AUX_LEARN)
}

// A dictionary shape changes in place: the property at idx is still `a`, a data property (writable for a write; an
// accessor for a getter's read).
@(private = "file")
j_dict_check :: proc(c: ^Jc, sh: ^Shape, idx: int, a: Atom, write: bool, pc: int, accessor := false) {
	j_i32(c, i32(uintptr(sh)))
	j_mem(c, W_I32_LOAD, 2, SHAPE_PROPS_LEN)
	j_i32(c, i32(idx))
	j_op(c, W_I32_LE_U)
	j_deopt_if(c, pc, JIT_AUX_LEARN)
	j_i32(c, i32(uintptr(sh)))
	j_mem(c, W_I32_LOAD, 2, SHAPE_PROPS)
	j_lset(c, I_T0)
	off := u32(idx) * PROP_SIZE
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, off + PROP_ATOM)
	j_i32(c, i32(a))
	j_op(c, W_I32_NE)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD8_U, 0, off + PROP_KIND)
	j_i32(c, i32(accessor ? Prop_Kind.accessor : Prop_Kind.data))
	j_op(c, W_I32_NE)
	j_op(c, W_I32_OR)
	if write {
		j_lget(c, I_T0)
		j_mem(c, W_I32_LOAD8_U, 0, off + PROP_FLAGS)
		j_i32(c, i32(transmute(u8)Prop_Flags{.writable}))
		j_op(c, W_I32_AND)
		j_op(c, W_I32_EQZ)
		j_op(c, W_I32_OR)
	}
	j_deopt_if(c, pc, JIT_AUX_LEARN)
}

// The address of the slot of a found property in I_T0: the holder's slots (the object in `obj`, or a constant one), at
// the index.
@(private = "file")
j_slot_of :: proc(c: ^Jc, holder: ^Object, obj: u32, idx: int) {
	if holder != nil {j_i32(c, i32(uintptr(holder)))} else {j_lget(c, obj)}
	j_mem(c, W_I32_LOAD, 2, OBJ_SLOTS)
	if idx != 0 {
		j_i32(c, i32(idx << VALUE_SHIFT))
		j_op(c, W_I32_ADD)
	}
	j_lset(c, I_T0)
}

// The address of the property `a` of the object in local `obj`, in I_T0: a guard for each shape the site knows, the
// first that matches taken; none matching is a learn exit. write: an own writable data property; getter: an accessor
// (its Getset), where the site reads through getters (jit_get_field).
@(private = "file")
j_prop_addr :: proc(c: ^Jc, obj: u32, site: ^Jit_Site, a: Atom, write: bool, pc: int, getter := false) -> bool {
	j_op(c, W_BLOCK)
	j_op(c, W_VOID)
	c.nest += 1
	site.inline = {}
	for k in 0 ..< site.n {
		sh := site.shapes[k]
		// objects of a shape whose property is not a plain data property (an accessor, an exotic object, absent; for a
		// write, an own writable one) take the exit
		l, ok := jit_lookup(sh, a, getter)
		if ok && l.accessor != getter {continue}
		if !ok {
			// (a write of a property the object does not have: appended, when objects of this shape take it as such)
			if write && j_prop_add(c, obj, sh, site.classes[k], a, pc) {site.inline += {k}}
			if c.fail {return false}
			continue
		}
		if write && (l.depth != 0 || .writable not_in sh.props[l.idx].flags || (site.classes[k] == .array && a == pa(.A_length))) {continue}
		if l.depth != 0 && !jit_ordinary_class(site.classes[k]) {continue}
		site.inline += {k}
		j_lget(c, obj)
		j_mem(c, W_I32_LOAD, 2, OBJ_SHAPE)
		j_i32(c, i32(uintptr(sh)))
		j_op(c, W_I32_EQ)
		j_op(c, W_IF)
		j_op(c, W_VOID)
		c.nest += 1
		if l.depth != 0 {
			// the object's class (a shape may be shared by an ordinary object and an exotic one), then the prototypes
			j_lget(c, obj)
			j_mem(c, W_I32_LOAD8_U, 0, OBJ_CLASS)
			j_i32(c, i32(site.classes[k]))
			j_op(c, W_I32_NE)
			if site.classes[k] == .host {
				// (a host object with exotic hooks has its say)
				j_lget(c, obj)
				j_mem(c, W_I32_LOAD8_U, 0, OBJ_BITS)
				j_i32(c, i32(c.host_exotic_bit))
				j_op(c, W_I32_AND)
				j_op(c, W_I32_OR)
			}
			j_deopt_if(c, pc, JIT_AUX_LEARN)
			if sh.is_dict {j_guard_version(c, sh, pc)}
			for j in 0 ..< l.depth {
				if !j_keep(c, l.shapes[j]) {return false}
				j_guard_shape(c, l.objs[j], 0, l.shapes[j], pc)
				if j < l.depth - 1 && l.shapes[j].is_dict {j_guard_version(c, l.shapes[j], pc)}
			}
			hs := l.shapes[l.depth - 1]
			if hs.is_dict {j_dict_check(c, hs, l.idx, a, write, pc, getter)}
			j_slot_of(c, l.objs[l.depth - 1], 0, l.idx)
		} else {
			if sh.is_dict {j_dict_check(c, sh, l.idx, a, write, pc, getter)}
			j_slot_of(c, nil, obj, l.idx)
		}
		j_op(c, W_BR)
		w_uleb(&c.out, 1)
		j_op(c, W_END)
		c.nest -= 1
	}
	j_stub(c, pc, .deopt, JIT_AUX_LEARN)
	j_op(c, W_END)
	c.nest -= 1
	return !c.fail
}

// A write of the property `a` an object of shape sh does not have, as a case of j_prop_addr (the slot's address in I_T0,
// out of its block): the property appended as [[Set]] appends it, when the object is an ordinary extensible one and `a`
// is nowhere on its prototype chain (each prototype's shape guarded, a dictionary's version), the shape's transition taken. False: objects of
// this shape take the exit.
@(private = "file")
j_prop_add :: proc(c: ^Jc, obj: u32, sh: ^Shape, class: Class_ID, a: Atom, pc: int) -> bool {
	if class != .object || sh.lazy != nil || sh.is_dict || shape_lookup(sh, a) >= 0 {return false}
	protos: [JIT_MAX_CHAIN]^Object
	np := 0
	for p := sh.proto; p != nil; p = p.shape.proto {
		ps := p.shape
		if np >= JIT_MAX_CHAIN || ps.lazy != nil || shape_lookup(ps, a) >= 0 || p.fast_array || p.class == .proxy ||
		   p.class == .module_ns || p.class == .string || p.host_exotic || is_typed_array_class(p.class) {
			return false
		}
		protos[np] = p
		np += 1
	}
	next := shape_transition(c.rt, sh, a, CWE, .data)
	if next.is_dict || !j_keep(c, sh) || !j_keep(c, next) {return false}
	for j in 0 ..< np {if !j_keep(c, protos[j].shape) {return false}}
	j_lget(c, obj)
	j_mem(c, W_I32_LOAD, 2, OBJ_SHAPE)
	j_i32(c, i32(uintptr(sh)))
	j_op(c, W_I32_EQ)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	c.nest += 1
	// an ordinary object (a shape may be shared with an exotic one), extensible
	j_lget(c, obj)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_CLASS)
	j_i32(c, i32(Class_ID.object))
	j_op(c, W_I32_NE)
	j_lget(c, obj)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_BITS)
	j_i32(c, i32(c.extensible_bit))
	j_op(c, W_I32_AND)
	j_op(c, W_I32_EQZ)
	j_op(c, W_I32_OR)
	j_deopt_if(c, pc)
	for j in 0 ..< np {
		j_guard_shape(c, protos[j], 0, protos[j].shape, pc)
		if protos[j].shape.is_dict {j_guard_version(c, protos[j].shape, pc)}
	}
	j_add_slot(c, obj, next, len(next.props) - 1)
	j_op(c, W_BR)
	w_uleb(&c.out, 1)
	j_op(c, W_END)
	c.nest -= 1
	return !c.fail
}

// The object in local `obj` takes the shape `next`, which appends a property at idx: room for its slot (the helper
// grows the slots), the shape stored, the slot's address in I_T0.
@(private = "file")
j_add_slot :: proc(c: ^Jc, obj: u32, next: ^Shape, idx: int) {
	j_lget(c, obj)
	j_mem(c, W_I32_LOAD, 2, OBJ_SLOT_CAP)
	j_i32(c, i32(idx))
	j_op(c, W_I32_LE_U)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	j_lget(c, P_FRAME)
	j_lget(c, obj)
	j_i32(c, i32(idx + 1))
	j_helper(c, .reserve)
	j_op(c, W_DROP)
	j_op(c, W_END)
	j_lget(c, obj)
	j_i32(c, i32(uintptr(next)))
	j_mem(c, W_I32_STORE, 2, OBJ_SHAPE)
	j_slot_of(c, nil, obj, idx)
}

// Objects made by compiled code ---------------------------------------------------------------------------------------

// An object made by the helper (Jit_Helper.new, jit_new), its address on the Wasm stack.
@(private = "file")
j_new :: proc(c: ^Jc, kind: Jit_New_Kind, a: int, argc: int) {
	j_lget(c, P_FRAME)
	j_i32(c, i32(kind))
	j_i32(c, i32(a))
	j_i32(c, i32(argc))
	j_helper(c, .new)
}

// A plain object made by the code itself: block $done { block $slow { the caller's guards (br_if 0), j_alloc } the
// caller's helper call } (j_alloc_open, j_alloc, its helper's code, j_alloc_end).
@(private = "file")
j_alloc_open :: proc(c: ^Jc) {
	for _ in 0 ..< 2 {
		j_op(c, W_BLOCK)
		j_op(c, W_VOID)
		c.nest += 1
	}
}

// A block the code took from the pool (j_pool_take): the local that holds it, the size it was taken for.
Jit_Block :: struct {
	local: u32,
	bytes: int,
}

// The address of the free list of the pool class of `bytes` (raw_alloc's), and the size of its blocks.
@(private = "file")
j_pool_class :: proc(c: ^Jc, bytes: int) -> (free: i32, n: int) {
	n = (bytes + POOL_GRAIN - 1) &~ (POOL_GRAIN - 1)
	return i32(uintptr(c.rt)) + i32(RT_POOL_FREE) + i32(n / POOL_GRAIN) * size_of(rawptr), n
}

// A block for `bytes` into local `out`, as raw_alloc takes it: popped from its pool class's free list (zeroed) or cut
// from the bump chunk (zero). No block in the free list and the chunk's end reached: the blocks taken before go back
// to their free lists (as raw_free gives them back) and the code leaves $slow, to the helper. Emitted in $slow itself
// (j_alloc_open).
@(private = "file")
j_pool_take :: proc(c: ^Jc, bytes: int, out: u32, taken: []Jit_Block) {
	rtp := i32(uintptr(c.rt))
	free, n := j_pool_class(c, bytes)
	j_i32(c, free)
	j_mem(c, W_I32_LOAD, 2, 0)
	j_op(c, W_LOCAL_TEE)
	w_uleb(&c.out, u64(out))
	j_op(c, W_IF)
	j_op(c, W_VOID)
	// popped, zeroed
	j_i32(c, free)
	j_lget(c, out)
	j_mem(c, W_I32_LOAD, 2, POOL_BLOCK_NEXT)
	j_mem(c, W_I32_STORE, 2, 0)
	for off := u32(0); off < u32(n); off += size_of(i64) {
		j_lget(c, out)
		j_op(c, W_I64_CONST)
		w_sleb(&c.out, 0)
		j_mem(c, W_I64_STORE, 3, off)
	}
	j_op(c, W_ELSE)
	// cut from the chunk, or the blocks taken given back and $slow (out of the two ifs: depth 2)
	j_i32(c, rtp)
	j_mem(c, W_I32_LOAD, 2, RT_POOL_LEFT)
	j_i32(c, i32(n))
	j_op(c, W_I32_LT_S)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	for t in taken {
		tfree, _ := j_pool_class(c, t.bytes)
		j_lget(c, t.local)
		j_i32(c, tfree)
		j_mem(c, W_I32_LOAD, 2, 0)
		j_mem(c, W_I32_STORE, 2, POOL_BLOCK_NEXT)
		j_i32(c, tfree)
		j_lget(c, t.local)
		j_mem(c, W_I32_STORE, 2, 0)
	}
	j_op(c, W_BR)
	w_uleb(&c.out, 2)
	j_op(c, W_END)
	j_i32(c, rtp)
	j_mem(c, W_I32_LOAD, 2, RT_POOL_BUMP)
	j_lset(c, out)
	j_i32(c, rtp)
	j_lget(c, out)
	j_i32(c, i32(n))
	j_op(c, W_I32_ADD)
	j_mem(c, W_I32_STORE, 2, RT_POOL_BUMP)
	j_i32(c, rtp)
	j_i32(c, rtp)
	j_mem(c, W_I32_LOAD, 2, RT_POOL_LEFT)
	j_i32(c, i32(n))
	j_op(c, W_I32_SUB)
	j_mem(c, W_I32_STORE, 2, RT_POOL_LEFT)
	j_op(c, W_END)
}

// The block in local `out` made a cell of `size` bytes, as cell_new makes it: its size and kind, first of the
// runtime's cells, counted; `charge` bytes (the cell's and the blocks it owns) charged to the heap, and its peak.
@(private = "file")
j_cell_new :: proc(c: ^Jc, out: u32, size: int, charge: int) {
	rtp := i32(uintptr(c.rt))
	j_st32(c, out, CELL_SIZE, i32(size))
	j_lget(c, out)
	j_i32(c, i32(Cell_Kind.object))
	j_mem(c, W_I32_STORE8, 0, CELL_KIND)
	j_lget(c, out)
	j_ld32(c, uintptr(rtp), RT_CELLS)
	j_mem(c, W_I32_STORE, 2, CELL_GC_NEXT)
	j_i32(c, rtp)
	j_lget(c, out)
	j_mem(c, W_I32_STORE, 2, RT_CELLS)
	j_i32(c, rtp)
	j_ld32(c, uintptr(rtp), RT_CELL_COUNT)
	j_i32(c, 1)
	j_op(c, W_I32_ADD)
	j_mem(c, W_I32_STORE, 2, RT_CELL_COUNT)
	j_i32(c, rtp)
	j_i32(c, rtp)
	j_mem(c, W_I64_LOAD, 3, RT_HEAP_BYTES)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, i64(charge))
	j_op(c, W_I64_ADD)
	j_mem(c, W_I64_STORE, 3, RT_HEAP_BYTES)
	j_i32(c, rtp)
	j_mem(c, W_I64_LOAD, 3, RT_HEAP_BYTES)
	j_i32(c, rtp)
	j_mem(c, W_I64_LOAD, 3, RT_PEAK_HEAP_BYTES)
	j_op(c, W_I64_GT_S)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	j_i32(c, rtp)
	j_i32(c, rtp)
	j_mem(c, W_I64_LOAD, 3, RT_HEAP_BYTES)
	j_mem(c, W_I64_STORE, 3, RT_PEAK_HEAP_BYTES)
	j_op(c, W_END)
}

// The object in local `out` (a cell made by j_cell_new) as object_new_shape makes it: of class `class`, extensible (and
// `bits`), of shape sh, its slots at the address in local `slots` (0: the inline ones), slot_cap of them.
@(private = "file")
j_object_init :: proc(c: ^Jc, out: u32, class: Class_ID, bits: u8, sh: ^Shape, slots: u32, slot_cap: int) {
	j_lget(c, out)
	j_i32(c, i32(class))
	j_mem(c, W_I32_STORE8, 0, OBJ_CLASS)
	j_lget(c, out)
	j_i32(c, i32(c.extensible_bit | bits))
	j_mem(c, W_I32_STORE8, 0, OBJ_BITS)
	j_st32(c, out, OBJ_SHAPE, i32(uintptr(sh)))
	j_lget(c, out)
	if slots != 0 {
		j_lget(c, slots)
	} else {
		j_lget(c, out)
		j_i32(c, size_of(Object))
		j_op(c, W_I32_ADD)
	}
	j_mem(c, W_I32_STORE, 2, OBJ_SLOTS)
	j_st32(c, out, OBJ_SLOT_CAP, i32(slot_cap))
}

// A plain object of the shape sh (a root shape: no properties) into local `out`, as cell_new and object_new_shape make
// it (its slots the inline ones), then out of $done; no block for it: out of $slow, to the helper. Allocation never
// collects, as with the helper: the object is in the code's hands until its next call or exit.
@(private = "file")
j_alloc :: proc(c: ^Jc, sh: ^Shape, out: u32) {
	j_pool_take(c, JIT_OBJ_BYTES, out, nil)
	j_cell_new(c, out, JIT_OBJ_BYTES, JIT_OBJ_BYTES)
	j_object_init(c, out, .object, 0, sh, 0, INLINE_SLOTS)
	j_op(c, W_BR)
	w_uleb(&c.out, 1)
	j_op(c, W_END)
	c.nest -= 1
}

// The end of block $done (j_alloc_open).
@(private = "file")
j_alloc_end :: proc(c: ^Jc) {
	j_op(c, W_END)
	c.nest -= 1
}

// `object`: a plain object, whose shape (the root one of Object.prototype) the code knows until the next join.
@(private = "file")
jit_object :: proc(c: ^Jc) -> bool {
	sh := shape_root_for(c.rt, c.ctx.class_proto[.object])
	if !j_keep(c, sh) {return false}
	d := j_push(c, .P)
	j_alloc_open(c)
	j_alloc(c, sh, j_si(c, d))
	j_new(c, .object, 0, 0)
	j_lset(c, j_si(c, d))
	j_alloc_end(c)
	c.st.k[d] = sh
	return true
}

// array_from: an Array of the argc top entries, made by the code as array_from_values makes it (array_new: the object,
// its slots, its values, three pool blocks; the length in its slot) when the values fit a pool block; else, or when the
// pool has no block for one of them, by the helper, the entries written to the frame for it to copy.
@(private = "file")
jit_array_from :: proc(c: ^Jc, argc: int) -> bool {
	base := c.st.n - argc
	if base < 0 {
		j_fail(c, "an array of entries under the loop's stack")
		return false
	}
	for d in base ..< c.st.n {
		if c.st.t[d] == .M {
			j_fail(c, "an array of entries under the loop's own")
			return false
		}
	}
	sh := c.ctx.array_shape
	at := shape_lookup(sh, pa(.A_length))
	if argc <= JIT_ARR_MAX && at >= 0 {
		if !j_keep(c, sh) {return false}
		slot_bytes := len(sh.props) * size_of(Prop_Slot)
		value_bytes := argc * size_of(Value)
		// I_T2 the values, I_T1 the slots, I_T0 the object (the entries' locals hold them until they are stored)
		taken: [2]Jit_Block
		nt := 0
		j_alloc_open(c)
		if argc > 0 {
			j_pool_take(c, value_bytes, I_T2, nil)
			for d in base ..< c.st.n {j_store_entry(c, d, I_T2, u32((d - base) * size_of(Value)), true, true)}
			taken[nt] = {I_T2, value_bytes}
			nt += 1
		}
		j_pool_take(c, slot_bytes, I_T1, taken[:nt])
		taken[nt] = {I_T1, slot_bytes}
		nt += 1
		j_pool_take(c, size_of(Object), I_T0, taken[:nt])
		j_cell_new(c, I_T0, size_of(Object), size_of(Object) + slot_bytes + value_bytes)
		j_object_init(c, I_T0, .array, c.fast_bit, sh, I_T1, len(sh.props))
		j_st_value(c, I_T1, u32(at * size_of(Prop_Slot)), .int, i64(argc))
		// its data: an Array_Data (the union's tag, as an Object_Data of that variant has it), argc values
		tmpl: Object
		tmpl.data = Array_Data{}
		words := ([^]u32)(uintptr(&tmpl) + uintptr(OBJ_DATA))
		for w in 0 ..< u32(size_of(Object_Data) / size_of(u32)) {
			if words[w] != 0 {j_st32(c, I_T0, OBJ_DATA + w * size_of(u32), i32(words[w]))}
		}
		if argc > 0 {
			j_st32l(c, I_T0, OBJ_DATA + ARR_VALUES, I_T2)
			j_st32(c, I_T0, OBJ_DATA + ARR_COUNT, i32(argc))
			j_st32(c, I_T0, OBJ_DATA + ARR_CAP, i32(argc))
		}
		j_op(c, W_BR)
		w_uleb(&c.out, 1)
		j_op(c, W_END)
		c.nest -= 1
	}
	for d in base ..< c.st.n {j_store_entry(c, d, P_STACK, u32(d * size_of(Value)), true, true)}
	j_new(c, .array, base, argc)
	j_lset(c, I_T0)
	if argc <= JIT_ARR_MAX && at >= 0 {j_alloc_end(c)}
	c.st.n = base
	d := j_push(c, .P)
	j_lget(c, I_T0)
	j_lset(c, j_si(c, d))
	return true
}

// define_field of an object the code made (an object literal's field): the property appended, its shape known, no
// guard; a key defined again with the same attributes stored.
@(private = "file")
jit_define_field :: proc(c: ^Jc, a: Atom, pc: int) -> bool {
	n := c.st.n
	o := n - 2
	sh := c.st.k[o]
	if _, is_index := atom_index(c.rt, a); is_index || c.st.t[o] != .P || sh == nil || sh.lazy != nil || sh.is_dict {
		j_fail(c, "a field of an object the JIT did not make")
		return false
	}
	obj := j_si(c, o)
	next := sh
	j_fits_value(c, n - 1, pc)
	if i := shape_lookup(sh, a); i >= 0 {
		if sh.props[i].kind != .data || sh.props[i].flags != CWE {
			j_fail(c, "a field defined again with other attributes")
			return false
		}
		j_slot_of(c, nil, obj, i)
	} else {
		next = shape_transition(c.rt, sh, a, CWE, .data)
		if next.is_dict {
			j_fail(c, "an object literal of a dictionary's size")
			return false
		}
		if !j_keep(c, next) {return false}
		j_add_slot(c, obj, next, len(next.props) - 1)
	}
	j_store_entry(c, n - 1, I_T0, 0)
	c.st.n -= 1
	c.st.k[o] = next
	return true
}

// The site of pc, with the shape of the object the translation sees there (shadow) added.
@(private = "file")
j_prop_site :: proc(c: ^Jc, pc: int, shadow: Value) -> ^Jit_Site {
	site := jit_site_of(c.jl, c.site_base + pc, true)
	if site == nil {
		j_fail(c, "too many sites")
		return nil
	}
	if shadow.tag == .object {jit_site_add_shape(site, as_obj(shadow), j_shadow_shape(c, as_obj(shadow)))}
	return site
}

// The type a read at the site is taken for: what it saw, or the value the translation sees there (in a callee inlined
// widened, a double for an int).
@(private = "file")
j_read_ty :: proc(c: ^Jc, site: ^Jit_Site, shadow: Value) -> Jit_Ty {
	if !site.typed && shadow.tag != .exception {jit_site_see(site, shadow)}
	t := site.typed ? site.ty : .V
	return c.inl_wide && t == .I ? .F : t
}

// get_field, get_field2, get_length of an object: `a` read from the object of the top entry.
@(private = "file")
jit_get_field :: proc(c: ^Jc, op: Opcode, a: Atom, pc: int) -> bool {
	n := c.st.n
	if _, is_index := atom_index(c.rt, a); is_index {
		j_fail(c, "a property named by an index")
		return false
	}
	recv := c.st.v[n - 1]
	site := j_prop_site(c, pc, recv)
	if site == nil {return false}
	if c.st.t[n - 1] == .V && (site.str || recv.tag == .string) {return jit_get_field_str(c, op, a, pc)}
	shadow := EXCEPTION
	if recv.tag == .object {
		if v, ok := jit_peek_field(as_obj(recv), a); ok {shadow = v}
	} else {
		// (an object the translation cannot tell, of a shape the site learned: what its prototype holds, a method)
		for k in 0 ..< site.n {
			if l, ok := jit_lookup(site.shapes[k], a); ok && l.depth > 0 {
				shadow = l.objs[l.depth - 1].slots[l.idx].value
				break
			}
		}
	}
	// (a string there: the site learns it, the read is compiled for strings too)
	j_as_obj(c, n - 1, pc, JIT_AUX_LEARN)
	obj, ok := j_obj_local(c, n - 1)
	if !ok {return false}
	// (a site whose first shape it can read finds an accessor reads through getters)
	getter := false
	for k in 0 ..< site.n {
		if l, found := jit_lookup(site.shapes[k], a, true); found {
			getter = l.accessor
			break
		}
	}
	if !j_prop_addr(c, obj, site, a, false, pc, getter) {return false}
	if getter {return j_call_getter(c, op, a, obj, nil, pc)}
	t := j_read_ty(c, site, shadow)
	if t == .O || t == .L {t = .V}
	j_check_value(c, I_T0, t, pc)
	if op != .get_field2 {c.st.n -= 1}
	d := j_push(c, t)
	j_take_value(c, I_T0, t, d)
	c.st.v[d] = shadow
	return true
}

// The getter of the accessor whose Getset is at I_T0, called on the object in local `obj` (the top entry) by the helper,
// when it is a native function called as a function (hot_native_getter) or a function of the script's (compiled whole
// or interpreted, as compiled code calls one), else the interpreter reads the property: the result a V in the place of
// the object (above it for get_field2). An exception leaves through a throw exit, the object replaced by the thrower
// (jit_getter); the held arrays are taken again after it.
// A global's (get_var: `global`, the global object, its `this`): the result pushed. There is no object on the stack to
// put the thrower in, so the instruction after the read must be a read of a named property of its result (get_field,
// get_field2, get_length: window.document.createElement): the thrower is put in the result's place, whose property
// is the accessor that throws, and the throw exit resumes at that instruction, which throws the exception pending.
@(private = "file")
j_call_getter :: proc(c: ^Jc, op: Opcode, a: Atom, obj: u32, global: ^Object, pc: int) -> bool {
	n := c.st.n
	if c.inl_depth > 0 {
		j_fail(c, "a getter in a callee being inlined")
		return false
	}
	// where the result goes, where the thrower goes and the property it throws for, where the throw exit resumes
	dest, at, ta, xpc := op == .get_field2 ? n : n - 1, n - 1, a, pc
	if global != nil {
		next := pc + int(opcode_info[op].size)
		#partial switch Opcode(c.code[next]) {
		case .get_field, .get_field2: ta = Atom(jr_u32(c.code, next + 1))
		case .get_length: ta = pa(.A_length)
		case:
			j_fail(c, "a global's accessor whose value is not read from at once")
			return false
		}
		dest, at, xpc = n, n, next
	}
	j_accessor_fn(c, GETSET_GETTER, pc)
	j_flush_objs(c)
	j_materialize(c, true)
	j_lget(c, P_FRAME)
	j_lget(c, I_T2)
	if global != nil {j_i32(c, i32(uintptr(global)))} else {j_lget(c, obj)}
	j_i32(c, i32(dest))
	j_i32(c, i32(at))
	j_i32(c, i32(ta))
	j_i32(c, i32(pc + int(opcode_info[op].size)))
	j_helper(c, .get)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	c.nest += 1
	// (the thrower's place stays in the frame)
	c.st.n = at
	j_stub(c, xpc, .throw, 0, at + 1)
	c.st.n = n
	j_op(c, W_END)
	c.nest -= 1
	if op == .get_field || op == .get_length {c.st.n -= 1}
	d := j_push(c, .V)
	off := u32(d * size_of(Value))
	j_lget(c, P_STACK)
	j_mem(c, W_I32_LOAD8_U, 0, off)
	j_lset(c, j_si(c, d))
	j_lget(c, P_STACK)
	j_mem(c, W_I64_LOAD, 3, off + 8)
	j_lset(c, c.sl0 + u32(d))
	j_retake_arrays(c, pc + int(opcode_info[op].size))
	return !c.fail
}

// The getter or the setter (at `off` of the Getset at I_T0) into I_T2 when the helper calls it: a native function called
// as a function (hot_native_getter) or a function of the script's; else a deopt at pc.
@(private = "file")
j_accessor_fn :: proc(c: ^Jc, off: u32, pc: int) {
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, off)
	j_lset(c, I_T2)
	j_lget(c, I_T2)
	j_op(c, W_I32_EQZ)
	j_op(c, W_IF)
	j_op(c, W_I32)
	j_i32(c, 1)
	j_op(c, W_ELSE)
	j_lget(c, I_T2)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_CLASS)
	j_i32(c, i32(Class_ID.c_function))
	j_op(c, W_I32_NE)
	j_lget(c, I_T2)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_BITS)
	j_i32(c, i32(c.ctor_bits))
	j_op(c, W_I32_AND)
	j_op(c, W_I32_OR)
	j_lget(c, I_T2)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_CLASS)
	j_i32(c, i32(Class_ID.bytecode_function))
	j_op(c, W_I32_NE)
	j_op(c, W_I32_AND)
	j_op(c, W_END)
	j_deopt_if(c, pc)
}

// A write that found a setter (the Getset at I_T0) of the object in local `obj` (under the value, the top entry): the
// setter called by the helper with the value; an exception leaves through a throw exit with the object replaced by
// the thrower (jit_setter), the held arrays taken again after it.
@(private = "file")
j_call_setter :: proc(c: ^Jc, a: Atom, obj: u32, pc: int) -> bool {
	n := c.st.n
	if c.inl_depth > 0 {
		j_fail(c, "a setter in a callee being inlined")
		return false
	}
	j_accessor_fn(c, GETSET_SETTER, pc)
	j_flush_objs(c)
	j_materialize(c, true)
	next := pc + int(opcode_info[Opcode.put_field].size)
	j_lget(c, P_FRAME)
	j_lget(c, I_T2)
	j_lget(c, obj)
	j_i32(c, i32(n - 2))
	j_i32(c, i32(a))
	j_i32(c, i32(next))
	j_helper(c, .set)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	c.nest += 1
	// (the object's place is the thrower's, the value above it: the write is made again)
	c.st.n = n - 2
	j_stub(c, pc, .throw, 0, n)
	c.st.n = n
	j_op(c, W_END)
	c.nest -= 1
	c.st.n -= 2
	j_retake_arrays(c, next)
	return !c.fail
}

// put_field: the top entry stored into `a` of the object under it.
@(private = "file")
jit_put_field :: proc(c: ^Jc, a: Atom, pc: int) -> bool {
	n := c.st.n
	if _, is_index := atom_index(c.rt, a); is_index {
		j_fail(c, "a property named by an index")
		return false
	}
	site := j_prop_site(c, pc, c.st.v[n - 2])
	if site == nil {return false}
	j_as_obj(c, n - 2, pc)
	j_fits_value(c, n - 1, pc)
	obj, ok := j_obj_local(c, n - 2)
	if !ok {return false}
	// (a site whose first shape finds an accessor, own or on a prototype, writes through setters)
	if site.n > 0 {
		if l, found := jit_lookup(site.shapes[0], a, true); found && l.accessor {
			if !j_prop_addr(c, obj, site, a, false, pc, true) {return false}
			return j_call_setter(c, a, obj, pc)
		}
	}
	if !j_prop_addr(c, obj, site, a, true, pc) {return false}
	j_store_entry(c, n - 1, I_T0, 0)
	if shadow := c.st.v[n - 2]; shadow.tag == .object {
		// (the object the translation sees takes the property: a write that follows is compiled for its next shape)
		sh := j_shadow_shape(c, as_obj(shadow))
		for t in sh.transitions {
			if t.atom == a && t.flags == CWE && t.kind == .data {j_shadow_took(c, as_obj(shadow), t.to)}
		}
	}
	c.st.n -= 2
	return true
}

// The shape the translation knows the object it sees takes by then (an object whose properties it appended: a
// constructor's `this`), else its own.
@(private = "file")
j_shadow_shape :: proc(c: ^Jc, o: ^Object) -> ^Shape {
	for i in 0 ..< c.n_shadows {if c.shadows[i].o == o {return c.shadows[i].sh}}
	return o.shape
}

@(private = "file")
j_shadow_took :: proc(c: ^Jc, o: ^Object, sh: ^Shape) {
	for i in 0 ..< c.n_shadows {
		if c.shadows[i].o == o {
			c.shadows[i].sh = sh
			return
		}
	}
	if c.n_shadows < len(c.shadows) {
		c.shadows[c.n_shadows] = {o, sh}
		c.n_shadows += 1
	}
}

// get_var / put_var of a global the realm holds as a data property: in its lexical declarations (whose shape is
// guarded) or on the global object, where none of them shadows it (the declarations' shape guarded too).
@(private = "file")
jit_global :: proc(c: ^Jc, op: Opcode, a: Atom, pc: int) -> bool {
	ctx := c.ctx
	write := op == .put_var
	gv := ctx.global_var_obj
	g := ctx.global_obj
	if gv.shape.lazy != nil || gv.shape.is_dict || g.shape.lazy != nil {
		j_fail(c, "globals in a shape the JIT does not guard")
		return false
	}
	site := jit_site_of(c.jl, c.site_base + pc, true)
	if site == nil {
		j_fail(c, "too many sites")
		return false
	}
	if !j_keep(c, gv.shape) || !j_keep(c, g.shape) {return false}
	j_guard_shape(c, gv, 0, gv.shape, pc)
	lexical, accessor := true, false
	i := shape_lookup(gv.shape, a)
	if i < 0 {
		lexical = false
		i = shape_lookup(g.shape, a)
		// (an own accessor of the global object, window.document: its native getter called)
		accessor = !write && i >= 0 && g.shape.props[i].kind == .accessor
		if i < 0 || (g.shape.props[i].kind != .data && !accessor) || (write && .writable not_in g.shape.props[i].flags) {
			j_fail(c, "a global the JIT does not read inline")
			return false
		}
		if g.shape.is_dict {j_dict_check(c, g.shape, i, a, write, pc, accessor)} else {j_guard_shape(c, g, 0, g.shape, pc)}
	} else if write && .writable not_in gv.shape.props[i].flags {
		j_fail(c, "a write to a constant")
		return false
	}
	holder := lexical ? gv : g
	j_slot_of(c, holder, 0, i)
	if accessor {return j_call_getter(c, op, a, 0, g, pc)}
	n := c.st.n
	if write {
		if lexical {
			// (a declaration not initialized yet: the interpreter throws)
			j_lget(c, I_T0)
			j_mem(c, W_I32_LOAD8_U, 0, 0)
			j_i32(c, i32(Tag.uninitialized))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
		}
		if !j_store_value(c, n - 1, pc) {return false}
		c.st.n -= 1
		return true
	}
	shadow := holder.slots[i].value
	t := j_read_ty(c, site, shadow)
	if t == .O || t == .L {t = .V}
	j_check_value(c, I_T0, t, pc)
	d := j_push(c, t)
	j_take_value(c, I_T0, t, d)
	c.st.v[d] = shadow
	return true
}

// A closure cell's instruction: the cell's index, whether it writes (keep: set_*, the value stays), whether it checks
// for the hole of the TDZ.
@(private = "file")
jit_var_ref_op :: proc(op: Opcode, code: []u8, pc: int) -> (idx: int, write: bool, keep: bool, check: bool, ok: bool) {
	#partial switch op {
	case .get_var_ref: return jr_u16(code, pc + 1), false, false, false, true
	case .get_var_ref_check: return jr_u16(code, pc + 1), false, false, true, true
	case .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3: return int(op) - int(Opcode.get_var_ref0), false, false, false, true
	case .put_var_ref: return jr_u16(code, pc + 1), true, false, false, true
	case .put_var_ref_check: return jr_u16(code, pc + 1), true, false, true, true
	case .put_var_ref0, .put_var_ref1, .put_var_ref2, .put_var_ref3: return int(op) - int(Opcode.put_var_ref0), true, false, false, true
	case .set_var_ref: return jr_u16(code, pc + 1), true, true, false, true
	case .set_var_ref0, .set_var_ref1, .set_var_ref2, .set_var_ref3: return int(op) - int(Opcode.set_var_ref0), true, true, false, true
	}
	return
}

// A read or a write of a closure cell: the value where the cell points (an open cell points into its frame).
@(private = "file")
jit_var_ref :: proc(c: ^Jc, f: ^Frame, op: Opcode, pc: int) -> bool {
	idx, write, keep, check, _ := jit_var_ref_op(op, c.code, pc)
	if idx >= int(c.b.closure_var_count) || f.closure_refs == nil {
		j_fail(c, "closure cell out of range")
		return false
	}
	j_lget(c, P_REFS)
	j_mem(c, W_I32_LOAD, 2, u32(idx * size_of(rawptr)))
	j_mem(c, W_I32_LOAD, 2, VARREF_PVALUE)
	j_lset(c, I_T0)
	n := c.st.n
	if write {
		if check {
			// (a hole of the TDZ: the interpreter throws)
			j_lget(c, I_T0)
			j_mem(c, W_I32_LOAD8_U, 0, 0)
			j_i32(c, i32(Tag.uninitialized))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
		}
		if !j_store_value(c, n - 1, pc) {return false}
		if !keep {c.st.n -= 1}
		return true
	}
	site := jit_site_of(c.jl, c.site_base + pc, true)
	if site == nil {
		j_fail(c, "too many sites")
		return false
	}
	shadow := f.closure_refs[idx].pvalue^
	t := j_read_ty(c, site, shadow)
	if t == .O || t == .L {t = .V}
	j_check_value(c, I_T0, t, pc)
	d := j_push(c, t)
	j_take_value(c, I_T0, t, d)
	c.st.v[d] = shadow
	return true
}

// The two top entries as (tag, payload) for a comparison of values: the tags in I_T0, I_T1, the payloads in the i64
// scratch locals (r64, r64 + 1).
@(private = "file")
j_ref_sides :: proc(c: ^Jc) -> bool {
	n := c.st.n
	for k in 0 ..< 2 {
		d := n - 2 + k
		tl := u32(k == 0 ? I_T0 : I_T1)
		pl := c.r64 + u32(k)
		#partial switch c.st.t[d] {
		case .P, .I, .B:
			t := c.st.t[d]
			j_i32(c, i32(t == .P ? Tag.object : t == .I ? Tag.int : Tag.bool))
			j_lset(c, tl)
			j_lget(c, j_si(c, d))
			j_op(c, W_I64_EXTEND_I32_U)
			j_lset(c, pl)
		case .V:
			j_lget(c, j_si(c, d))
			j_lset(c, tl)
			j_lget(c, c.sl0 + u32(d))
			j_lset(c, pl)
		case .O:
			base, off := j_slot_addr(c, c.jl.arr_slots[c.st.a[d]])
			j_lget(c, base)
			j_mem(c, W_I32_LOAD8_U, 0, off)
			j_lset(c, tl)
			j_lget(c, base)
			j_mem(c, W_I64_LOAD, 3, off + 8)
			j_lset(c, pl)
		case:
			j_fail(c, "equality of an object and a double")
			return false
		}
	}
	return true
}

// strict_eq / strict_neq with an object or another value (P, V): equal tags and payloads, numbers and strings (whose
// equality is by value) left to the interpreter.
@(private = "file")
jit_strict_eq_ref :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	if !j_ref_sides(c) {return false}
	// a float or a BigInt on either side: by value, the interpreter's
	for tl in ([]u32{I_T0, I_T1}) {
		for tag in ([]Tag{.float, .bigint}) {
			j_lget(c, tl)
			j_i32(c, i32(tag))
			j_op(c, W_I32_EQ)
		}
		j_op(c, W_I32_OR)
	}
	j_op(c, W_I32_OR)
	j_deopt_if(c, pc)
	// two strings: the same one, or equal by value (the helper)
	for tl in ([]u32{I_T0, I_T1}) {
		j_lget(c, tl)
		j_i32(c, i32(Tag.string))
		j_op(c, W_I32_EQ)
	}
	j_op(c, W_I32_AND)
	j_op(c, W_IF)
	j_op(c, W_I32)
	j_lget(c, c.r64)
	j_op(c, W_I32_WRAP_I64)
	j_lget(c, c.r64 + 1)
	j_op(c, W_I32_WRAP_I64)
	j_op(c, W_I32_EQ)
	j_op(c, W_IF)
	j_op(c, W_I32)
	j_i32(c, 1)
	j_op(c, W_ELSE)
	j_lget(c, P_FRAME)
	j_lget(c, c.r64)
	j_op(c, W_I32_WRAP_I64)
	j_lget(c, c.r64 + 1)
	j_op(c, W_I32_WRAP_I64)
	j_helper(c, .streq)
	j_op(c, W_END)
	j_op(c, W_ELSE)
	// same tag, and undefined or null or the same low word (an int's, a bool's, a pointer's; a string's: by value is the
	// other case)
	j_lget(c, I_T0)
	j_lget(c, I_T1)
	j_op(c, W_I32_EQ)
	j_lget(c, I_T0)
	j_i32(c, i32(Tag.null))
	j_op(c, W_I32_LE_U)
	j_lget(c, c.r64)
	j_lget(c, c.r64 + 1)
	j_op(c, W_I64_XOR)
	j_op(c, W_I32_WRAP_I64)
	j_low_mask(c, I_T0)
	j_op(c, W_I32_AND)
	j_op(c, W_I32_EQZ)
	j_op(c, W_I32_OR)
	j_op(c, W_I32_AND)
	j_op(c, W_END)
	if op == .strict_neq {j_op(c, W_I32_EQZ)}
	c.st.n -= 2
	d := j_push(c, .B)
	j_lset(c, j_si(c, d))
	return true
}

// Whether the side (tag local, payload local) is undefined, null or document.all (i32 on the Wasm stack).
@(private = "file")
j_nullish :: proc(c: ^Jc, tag: u32, pl: u32) {
	j_lget(c, tag)
	j_i32(c, i32(Tag.object))
	j_op(c, W_I32_EQ)
	j_op(c, W_IF)
	j_op(c, W_I32)
	j_lget(c, pl)
	j_op(c, W_I32_WRAP_I64)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_BITS)
	j_i32(c, i32(c.htmldda_bit))
	j_op(c, W_I32_AND)
	j_i32(c, 0)
	j_op(c, W_I32_NE)
	j_op(c, W_ELSE)
	j_lget(c, tag)
	j_i32(c, i32(Tag.null))
	j_op(c, W_I32_LE_U)
	j_op(c, W_END)
}

// eq / neq with an object or another value: with undefined or null on a side, whether both are of those (or
// document.all); two objects by identity; anything else left to the interpreter.
@(private = "file")
jit_loose_eq_ref :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	if !j_ref_sides(c) {return false}
	pa_, pb := c.r64, c.r64 + 1
	// I_T0 / I_T1 hold the tags; the condition "a side is undefined or null" is computed twice where needed
	either_nullish :: proc(c: ^Jc) {
		j_lget(c, I_T0)
		j_i32(c, i32(Tag.null))
		j_op(c, W_I32_LE_U)
		j_lget(c, I_T1)
		j_i32(c, i32(Tag.null))
		j_op(c, W_I32_LE_U)
		j_op(c, W_I32_OR)
	}
	either_nullish(c)
	j_lget(c, I_T0)
	j_i32(c, i32(Tag.object))
	j_op(c, W_I32_EQ)
	j_lget(c, I_T1)
	j_i32(c, i32(Tag.object))
	j_op(c, W_I32_EQ)
	j_op(c, W_I32_AND)
	j_op(c, W_I32_OR)
	j_op(c, W_I32_EQZ)
	j_deopt_if(c, pc)
	either_nullish(c)
	j_op(c, W_IF)
	j_op(c, W_I32)
	j_nullish(c, I_T0, pa_)
	j_nullish(c, I_T1, pb)
	j_op(c, W_I32_AND)
	j_op(c, W_ELSE)
	j_lget(c, pa_)
	j_op(c, W_I32_WRAP_I64)
	j_lget(c, pb)
	j_op(c, W_I32_WRAP_I64)
	j_op(c, W_I32_EQ)
	j_op(c, W_END)
	if op == .neq {j_op(c, W_I32_EQZ)}
	c.st.n -= 2
	d := j_push(c, .B)
	j_lset(c, j_si(c, d))
	return true
}
// Strings ------------------------------------------------------------------------------------------------------------

// get_field, get_field2, get_length of a string (the V entry on top, checked to be one, or the site learns): its
// length, or a property of String.prototype (its shape and those of its prototypes guarded, a dictionary's key checked).
@(private = "file")
jit_get_field_str :: proc(c: ^Jc, op: Opcode, a: Atom, pc: int) -> bool {
	n := c.st.n
	j_lget(c, j_si(c, n - 1))
	j_i32(c, i32(Tag.string))
	j_op(c, W_I32_NE)
	j_deopt_if(c, pc, JIT_AUX_LEARN)
	if a == pa(.A_length) {
		if op == .get_field2 {
			j_fail(c, "a call of a string's length")
			return false
		}
		// (a string's length is at most 2^30 units: an int)
		j_lget(c, c.sl0 + u32(n - 1))
		j_op(c, W_I32_WRAP_I64)
		j_mem(c, W_I32_LOAD, 2, STR_LEN)
		c.st.n -= 1
		d := j_push(c, .I)
		j_lset(c, j_si(c, d))
		return true
	}
	p0 := c.ctx.class_proto[.string]
	l, ok := jit_lookup(p0.shape, a)
	if !ok {
		j_fail(c, "a property of a string the JIT does not read inline")
		return false
	}
	// the objects walked: String.prototype, then its prototypes up to the holder
	objs := [JIT_MAX_CHAIN + 1]^Object{0 = p0}
	shapes := [JIT_MAX_CHAIN + 1]^Shape{0 = p0.shape}
	for j in 0 ..< l.depth {
		objs[j + 1] = l.objs[j]
		shapes[j + 1] = l.shapes[j]
	}
	for j in 0 ..= l.depth {
		if !j_keep(c, shapes[j]) {return false}
		j_guard_shape(c, objs[j], 0, shapes[j], pc)
		if j < l.depth && shapes[j].is_dict {j_guard_version(c, shapes[j], pc)}
	}
	if shapes[l.depth].is_dict {j_dict_check(c, shapes[l.depth], l.idx, a, false, pc)}
	j_slot_of(c, objs[l.depth], 0, l.idx)
	site := jit_site_of(c.jl, c.site_base + pc, true)
	if site == nil {
		j_fail(c, "too many sites")
		return false
	}
	shadow := objs[l.depth].slots[l.idx].value
	t := j_read_ty(c, site, shadow)
	if t == .O || t == .L {t = .V}
	j_check_value(c, I_T0, t, pc)
	if op != .get_field2 {c.st.n -= 1}
	d := j_push(c, t)
	j_take_value(c, I_T0, t, d)
	c.st.v[d] = shadow
	return true
}

// s.charCodeAt(i) of a flat string and an index within it (a rope, an index out of it: the interpreter makes the call),
// the callee guarded: false when it does not apply (the call is then made).
@(private = "file")
j_char_code_at :: proc(c: ^Jc, fo: ^Object, argc: int, low: int, pc: int) -> bool {
	n := c.st.n
	if argc != 1 || c.st.t[n - 1] != .I || c.st.t[low] != .V {return false}
	if !j_guard_callee(c, n - 2, fo, pc) {return false}
	idx := j_si(c, n - 1)
	j_lget(c, j_si(c, low))
	j_i32(c, i32(Tag.string))
	j_op(c, W_I32_NE)
	j_deopt_if(c, pc)
	j_lget(c, c.sl0 + u32(low))
	j_op(c, W_I32_WRAP_I64)
	j_lset(c, I_T0)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD8_U, 0, STR_ROPE)
	j_lget(c, idx)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, STR_LEN)
	j_op(c, W_I32_GE_U)
	j_op(c, W_I32_OR)
	j_deopt_if(c, pc)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD8_U, 0, STR_WIDE)
	j_op(c, W_IF)
	j_op(c, W_I32)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, STR_DATA)
	j_lget(c, idx)
	j_i32(c, 1)
	j_op(c, W_I32_SHL)
	j_op(c, W_I32_ADD)
	j_mem(c, W_I32_LOAD16_U, 1, 0)
	j_op(c, W_ELSE)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, STR_DATA)
	j_lget(c, idx)
	j_op(c, W_I32_ADD)
	j_mem(c, W_I32_LOAD8_U, 0, 0)
	j_op(c, W_END)
	c.st.n = low
	d := j_push(c, .I)
	j_lset(c, j_si(c, d))
	return true
}

// Calls --------------------------------------------------------------------------------------------------------------

// The objects the loop wrote into locals it holds, back in the frame (what the collector sees during a call).
@(private = "file")
j_flush_objs :: proc(c: ^Jc) {
	for s in 0 ..< c.nslots {
		if c.skind[s] != .obj || !c.written[s] {continue}
		base, off := j_slot_addr(c, s)
		j_store_tag(c, base, off, .object)
		j_store_low(c, base, off + 8, c.wl[s])
	}
}

// The callee entry d is the function object fo, or the call at pc is left to the interpreter.
@(private = "file")
j_guard_callee :: proc(c: ^Jc, d: int, fo: ^Object, pc: int, aux: u32 = JIT_AUX_NONE) -> bool {
	if !j_keep(c, fo) {return false}
	#partial switch c.st.t[d] {
	case .P:
		j_lget(c, j_si(c, d))
	case .V:
		j_lget(c, j_si(c, d))
		j_i32(c, i32(Tag.object))
		j_op(c, W_I32_NE)
		j_deopt_if(c, pc, aux)
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I32_WRAP_I64)
	case:
		j_fail(c, "a callee that is not an object")
		return false
	}
	j_i32(c, i32(uintptr(fo)))
	j_op(c, W_I32_NE)
	j_deopt_if(c, pc, aux)
	return true
}

// A call of a Math function the code computes itself (the callee guarded to be it), its arguments numbers: false when
// it does not apply (the call is then made).
@(private = "file")
j_math :: proc(c: ^Jc, fo: ^Object, mi: Math_Intrinsic, argc: int, low: int, pc: int) -> bool {
	n := c.st.n
	unary := mi == .abs || mi == .floor || mi == .ceil || mi == .trunc || mi == .sqrt
	if argc != (unary ? 1 : 2) {return false}
	for d in n - argc ..< n {if !j_is_num(c.st.t[d]) {return false}}
	if !j_guard_callee(c, n - argc - 1, fo, pc) {return false}
	a := n - argc
	ta := c.st.t[a]
	rt: Jit_Ty = .F
	if unary {
		if ta == .I && mi != .sqrt {
			rt = .I
			if mi == .abs {
				// (the absolute value of -2^31 is not an int)
				j_lget(c, j_si(c, a))
				j_i32(c, min(i32))
				j_op(c, W_I32_EQ)
				j_deopt_if(c, pc)
				j_i32(c, 0)
				j_lget(c, j_si(c, a))
				j_op(c, W_I32_SUB)
				j_lget(c, j_si(c, a))
				j_lget(c, j_si(c, a))
				j_i32(c, 0)
				j_op(c, W_I32_LT_S)
				j_op(c, W_SELECT)
			} else {
				j_lget(c, j_si(c, a))
			}
		} else {
			j_get_f(c, a)
			#partial switch mi {
			case .abs: j_op(c, W_F64_ABS)
			case .floor: j_op(c, W_F64_FLOOR)
			case .ceil: j_op(c, W_F64_CEIL)
			case .trunc: j_op(c, W_F64_TRUNC)
			case .sqrt: j_op(c, W_F64_SQRT)
			}
		}
	} else if mi == .imul {
		rt = .I
		j_get_i32(c, a, pc)
		j_get_i32(c, a + 1, pc)
		j_op(c, W_I32_MUL)
	} else if ta == .I && c.st.t[a + 1] == .I {
		rt = .I
		j_lget(c, j_si(c, a))
		j_lget(c, j_si(c, a + 1))
		j_lget(c, j_si(c, a))
		j_lget(c, j_si(c, a + 1))
		j_op(c, mi == .max ? W_I32_GT_S : W_I32_LT_S)
		j_op(c, W_SELECT)
	} else {
		j_get_f(c, a)
		j_get_f(c, a + 1)
		j_op(c, mi == .max ? W_F64_MAX : W_F64_MIN)
	}
	c.st.n = low
	d := j_push(c, rt)
	j_lset(c, j_sloc(c, d, rt))
	return true
}

// A call instruction (kind: the stack's layout, Jit_Call_Kind): a Math function computed inline, or the call made
// through the helper, the operand stack in the frame's memory; its result is a V. An exception leaves through a throw
// exit; the held arrays are taken again after it.
@(private = "file")
jit_call_insn :: proc(c: ^Jc, f: ^Frame, op: Opcode, argc: int, kind: Jit_Call_Kind, pc: int) -> bool {
	n := c.st.n
	low := n - argc - (kind == .call ? 1 : 2)   // where the result goes
	if low < 0 {
		j_fail(c, "a call under the loop's stack")
		return false
	}
	for d in low ..< n {
		if c.st.t[d] == .M {
			j_fail(c, "a call that takes an entry from under the loop's own")
			return false
		}
	}
	next := pc + int(opcode_info[op].size)
	tail := op == .tail_call || op == .tail_call_method
	fv := c.st.v[n - argc - (kind == .construct ? 2 : 1)]
	if fv.tag != .object && c.inl_depth == 0 {
		// a callee the translation cannot tell (a method of an object a getter returned): the one an exit met, else
		// such an exit, for the site to learn it
		site := jit_site_of(c.jl, pc, true)
		if site == nil {
			j_fail(c, "too many sites")
			return false
		}
		if site.callee == nil {
			j_stub(c, pc, .deopt, JIT_AUX_CALLEE)
			c.st.n = low
			d := j_push(c, .V)
			if tail {
				j_return(c, d)
				return false
			}
			return true
		}
		fv = mk_obj(site.callee)
	}
	if fv.tag == .object && kind != .construct && !tail {
		fo := as_obj(fv)
		if mi := math_intrinsic_of(fo); mi != .none && j_math(c, fo, mi, argc, low, pc) {return true}
		if kind == .method && string_is_char_code_at(fo) && j_char_code_at(c, fo, argc, low, pc) {return true}
		if c.fail {return false}
		if fo.class == .bytecode_function {
			site := jit_site_of(c.jl, c.site_base + pc, true)
			if site != nil && !(site.typed && site.ty == .V) && j_inline(c, f, fo, op, argc, kind, low, pc, site.typed) {return true}
			if c.fail || c.restart {return false}
		}
	}
	// the helper: a call of a native function, or of a function compiled whole (through the helper, a call of bytecode
	// that is interpreted costs more than the interpreter's own); a callee being inlined calls nothing that has effects
	bytecode_callee := fv.tag == .object && as_obj(fv).class == .bytecode_function
	if c.inl_depth > 0 || fv.tag != .object || (bytecode_callee && !(kind == .construct ? j_construct_ok(as_obj(fv)) : jit_fn_compilable(as_obj(fv).data.(Func_Data).bc))) {
		j_fail(c, "a call the JIT does not make (a function it does not inline or compile, or not known)")
		return false
	}
	j_flush_objs(c)
	j_materialize(c, true)
	direct := !tail && j_direct_ok(c, as_obj(fv))
	if direct {
		// block $result: the direct call, which leaves through its end with the result in the frame; else block $slow
		// (one of its checks failed): the helper's call
		for _ in 0 ..< 2 {
			j_op(c, W_BLOCK)
			j_op(c, W_VOID)
			c.nest += 1
		}
		j_direct_call(c, as_obj(fv), argc, kind, low, pc, next)
		j_op(c, W_END)
		c.nest -= 1
	}
	j_lget(c, P_FRAME)
	j_i32(c, i32(n))
	j_i32(c, i32(argc))
	j_i32(c, i32(kind))
	j_i32(c, i32(next))
	j_helper(c, .call)
	// (only a call of bytecode may come back not made: a native's has no stub for it, which keeps its code small)
	bytecode := as_obj(fv).class == .bytecode_function
	if bytecode {j_lset(c, I_T0); j_lget(c, I_T0)}
	j_op(c, W_IF)
	j_op(c, W_VOID)
	c.nest += 1
	if bytecode {
		j_lget(c, I_T0)
		j_i32(c, i32(Jit_Call_Result.threw))
		j_op(c, W_I32_EQ)
		j_op(c, W_IF)
		j_op(c, W_VOID)
		c.nest += 1
	}
	// (the entries from low up are in the frame as the call left them: the call is made again)
	c.st.n = low
	j_stub(c, pc, .throw, 0, n)
	c.st.n = n
	if bytecode {
		j_op(c, W_ELSE)
		// not made: the interpreter makes it
		j_stub(c, pc, .deopt, JIT_AUX_NONE)
		j_op(c, W_END)
		c.nest -= 1
	}
	j_op(c, W_END)
	c.nest -= 1
	if direct {
		j_op(c, W_END)
		c.nest -= 1
	}
	c.st.n = low
	d := j_push(c, .V)
	off := u32(d * size_of(Value))
	j_lget(c, P_STACK)
	j_mem(c, W_I32_LOAD8_U, 0, off)
	j_lset(c, j_si(c, d))
	j_lget(c, P_STACK)
	j_mem(c, W_I64_LOAD, 3, off + 8)
	j_lset(c, c.sl0 + u32(d))
	if tail {
		// (the function returns the call's result: nothing of it runs after the call, where there may be no instruction)
		j_return(c, d)
		return false
	}
	j_retake_arrays(c, next)
	return true
}

// After a call (a native may grow, shrink or detach them), the arrays the code holds taken again; one that is not of the
// kind the code was made for leaves at `next` (the instruction after the call).
@(private = "file")
j_retake_arrays :: proc(c: ^Jc, next: int) {
	for k in 0 ..< c.jl.n_arr {
		at := u32(k * size_of(Jit_Arr))
		j_lget(c, P_FRAME)
		j_i32(c, i32(c.jl.arr_slots[k]))
		j_i32(c, i32(c.jl.arr_kinds[k]))
		j_lget(c, P_ARRAYS)
		j_i32(c, i32(at))
		j_op(c, W_I32_ADD)
		j_helper(c, .array)
		j_deopt_if(c, next)
		for w in 0 ..< u32(3) {
			j_lget(c, P_ARRAYS)
			j_mem(c, W_I32_LOAD, 2, at + 4 * w)
			j_lset(c, c.a0 + 3 * u32(k) + w)
		}
	}
}

// Direct calls -------------------------------------------------------------------------------------------------------

// Can a call of fo be made directly (j_direct_call): a plain function of the realm that may be compiled whole, with no
// closure cells of its own (its frame then needs nothing done when it ends).
@(private = "file")
j_direct_ok :: proc(c: ^Jc, fo: ^Object) -> bool {
	if fo.class != .bytecode_function {return false}
	nb := fo.data.(Func_Data).bc
	if (nb.realm != nil && nb.realm != c.ctx) || nb.var_ref_count != 0 || !jit_fn_compilable(nb) {return false}
	if nb.jit == nil {nb.jit = new(Jit_Info, rt_allocator(c.rt))}
	return j_keep(c, nb)
}

// Can a construction of fo be made by compiled code: a constructor that may be compiled whole, not a derived class's (its
// `this` is super()'s).
@(private = "file")
j_construct_ok :: proc(fo: ^Object) -> bool {
	nb := fo.data.(Func_Data).bc
	return fo.is_constructor && !nb.is_derived_class_ctor && jit_fn_compilable(nb)
}

// The prototype a construction of fo gives the object it makes (create_from_ctor, new.target the callee: the callee's
// own `prototype`, a data property that holds an object) and the root shape of such objects, kept with the code; nil
// when the translation cannot tell (the helper makes the object).
@(private = "file")
j_ctor_proto :: proc(c: ^Jc, fo: ^Object) -> (^Object, ^Shape) {
	sh := fo.shape
	if sh.lazy != nil || sh.is_dict {return nil, nil}
	i := shape_lookup(sh, pa(.A_prototype))
	if i < 0 || sh.props[i].kind != .data || fo.slots[i].value.tag != .object {return nil, nil}
	p := as_obj(fo.slots[i].value)
	psh := shape_root_for(c.rt, p)
	if !j_keep(c, sh) || !j_keep(c, p) || !j_keep(c, psh) {return nil, nil}
	return p, psh
}

// i32 stores at the address in local `base`: a constant, or a local's value
@(private = "file")
j_st32 :: proc(c: ^Jc, base: u32, off: u32, v: i32) {
	j_lget(c, base)
	j_i32(c, v)
	j_mem(c, W_I32_STORE, 2, off)
}

@(private = "file")
j_st32l :: proc(c: ^Jc, base: u32, off: u32, src: u32) {
	j_lget(c, base)
	j_lget(c, src)
	j_mem(c, W_I32_STORE, 2, off)
}

// a Value at the address in local `base`: its two words
@(private = "file")
j_st_value :: proc(c: ^Jc, base: u32, off: u32, tag: Tag, payload: i64) {
	j_lget(c, base)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, i64(tag))
	j_mem(c, W_I64_STORE, 3, off)
	j_lget(c, base)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, payload)
	j_mem(c, W_I64_STORE, 3, off + 8)
}

// the object whose address is in local `obj` as a Value at the address in local `base`
@(private = "file")
j_st_object :: proc(c: ^Jc, base: u32, off: u32, obj: u32) {
	j_lget(c, base)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, i64(Tag.object))
	j_mem(c, W_I64_STORE, 3, off)
	j_lget(c, base)
	j_lget(c, obj)
	j_op(c, W_I64_EXTEND_I32_U)
	j_mem(c, W_I64_STORE, 3, off + 8)
}

// a Value copied from (local `from` + off_from) to (local `to` + off_to)
@(private = "file")
j_copy_value :: proc(c: ^Jc, from: u32, off_from: u32, to: u32, off_to: u32) {
	for half in 0 ..< u32(2) {
		j_lget(c, to)
		j_lget(c, from)
		j_mem(c, W_I64_LOAD, 3, off_from + 8 * half)
		j_mem(c, W_I64_STORE, 3, off_to + 8 * half)
	}
}

// the i32 at a constant address
@(private = "file")
j_ld32 :: proc(c: ^Jc, addr: uintptr, off: u32) {
	j_i32(c, i32(addr))
	j_mem(c, W_I32_LOAD, 2, off)
}

// The call at pc of fo (argc arguments materialized on the frame's stack, its result to go at `low`) made directly
// when the callee is a function of fo's bytecode (any of its closures: T5), compiled and holding no arrays (and for a
// construction new.target is the callee, the object made by the helper: T6), and there
// is room: its frame pushed on the value stack as frame_push pushes it (so that the collector, a deopt, an exception
// see an interpreter's frame), its code called through the engine's table, its frame popped as frame_pop pops it. Emitted inside block $slow, which any check that
// fails leaves (the helper then makes the call), itself in block $result, which the call leaves with the result in the
// frame at `low`. The callee's code leaving other than by its return: the helper finishes the call (jit_call_finish).
@(private = "file")
j_direct_call :: proc(c: ^Jc, fo: ^Object, argc: int, kind: Jit_Call_Kind, low: int, pc: int, next: int) {
	nb := fo.data.(Func_Data).bc
	info := uintptr(nb.jit)
	rtp := uintptr(c.rt)
	n := c.st.n
	abl := max(argc, int(nb.arg_count))
	stack0 := u32(abl + int(nb.var_count)) * size_of(Value)
	total := abl + int(nb.var_count) + int(nb.stack_size)   // (no closure cells: no room for their pointers)
	construct := kind == .construct
	slot := n - argc - (construct ? 2 : 1)   // the callee's (a construction's new.target after it)
	callee := u32(slot * size_of(Value))
	// the callee is a function of nb, its code compiled and holding no arrays
	j_lget(c, P_STACK)
	j_mem(c, W_I32_LOAD8_U, 0, callee)
	j_i32(c, i32(Tag.object))
	j_op(c, W_I32_NE)
	j_op(c, W_BR_IF)
	w_uleb(&c.out, 0)
	j_lget(c, P_STACK)
	j_mem(c, W_I32_LOAD, 2, callee + 8)
	j_op(c, W_LOCAL_TEE)
	w_uleb(&c.out, I_T5)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_CLASS)
	j_i32(c, i32(Class_ID.bytecode_function))
	j_op(c, W_I32_NE)
	j_op(c, W_BR_IF)
	w_uleb(&c.out, 0)
	j_lget(c, I_T5)
	j_mem(c, W_I32_LOAD, 2, FUNC_BC)
	j_i32(c, i32(uintptr(nb)))
	j_op(c, W_I32_NE)
	j_i32(c, i32(info))
	j_mem(c, W_I32_LOAD8_U, 0, INFO_FN_STATE)
	j_i32(c, i32(Jit_Loop_State.compiled))
	j_op(c, W_I32_NE)
	j_op(c, W_I32_OR)
	j_ld32(c, info, INFO_FN_N_ARR)
	j_op(c, W_I32_OR)
	if construct {
		// new F(): new.target is the callee
		j_lget(c, P_STACK)
		j_mem(c, W_I32_LOAD8_U, 0, callee + size_of(Value))
		j_i32(c, i32(Tag.object))
		j_op(c, W_I32_NE)
		j_op(c, W_I32_OR)
		j_lget(c, P_STACK)
		j_mem(c, W_I32_LOAD, 2, callee + size_of(Value) + 8)
		j_lget(c, I_T5)
		j_op(c, W_I32_NE)
		j_op(c, W_I32_OR)
	}
	// room: on the host stack, in the call depth, in the value stack's segment (T3 its index, T2 its address, T4 its
	// top)
	j_ld32(c, rtp, RT_JIT_DEPTH)
	j_i32(c, JIT_MAX_NEST)
	j_op(c, W_I32_GE_S)
	j_op(c, W_I32_OR)
	j_ld32(c, rtp, RT_STACK_DEPTH)
	j_ld32(c, rtp, RT_MAX_STACK_DEPTH)
	j_op(c, W_I32_GE_S)
	j_op(c, W_I32_OR)
	j_ld32(c, rtp, RT_VSTACK_CUR)
	j_op(c, W_LOCAL_TEE)
	w_uleb(&c.out, I_T3)
	j_ld32(c, rtp, RT_VSTACK_LEN)
	j_op(c, W_I32_GE_U)
	j_op(c, W_I32_OR)
	j_op(c, W_BR_IF)
	w_uleb(&c.out, 0)
	j_ld32(c, rtp, RT_VSTACK_DATA)
	j_lget(c, I_T3)
	j_i32(c, i32(SEG_SIZE))
	j_op(c, W_I32_MUL)
	j_op(c, W_I32_ADD)
	j_lset(c, I_T2)
	j_lget(c, I_T2)
	j_mem(c, W_I32_LOAD, 2, SEG_TOP)
	j_lset(c, I_T4)
	j_lget(c, I_T4)
	j_i32(c, i32(total + FRAME_VALUES))
	j_op(c, W_I32_ADD)
	j_lget(c, I_T2)
	j_mem(c, W_I32_LOAD, 2, SEG_LEN)
	j_op(c, W_I32_GT_U)
	j_op(c, W_BR_IF)
	w_uleb(&c.out, 0)
	if construct {
		// the object the construction makes (T6): made by the code when the callee's `prototype` is the object it was
		// for (its shape and the slot's value guarded), else by the helper; it threw: the interpreter makes the
		// construction again, with a constructor jit_new made one that throws
		proto, psh := j_ctor_proto(c, fo)
		if psh != nil {
			j_alloc_open(c)
			j_lget(c, I_T5)
			j_mem(c, W_I32_LOAD, 2, OBJ_SHAPE)
			j_i32(c, i32(uintptr(fo.shape)))
			j_op(c, W_I32_NE)
			j_op(c, W_BR_IF)
			w_uleb(&c.out, 0)
			j_lget(c, I_T5)
			j_mem(c, W_I32_LOAD, 2, OBJ_SLOTS)
			j_lset(c, I_T0)
			at := u32(shape_lookup(fo.shape, pa(.A_prototype)) * size_of(Prop_Slot))
			j_lget(c, I_T0)
			j_mem(c, W_I32_LOAD8_U, 0, at)
			j_i32(c, i32(Tag.object))
			j_op(c, W_I32_NE)
			j_lget(c, I_T0)
			j_mem(c, W_I32_LOAD, 2, at + 8)
			j_i32(c, i32(uintptr(proto)))
			j_op(c, W_I32_NE)
			j_op(c, W_I32_OR)
			j_op(c, W_BR_IF)
			w_uleb(&c.out, 0)
			j_alloc(c, psh, I_T6)
		}
		j_new(c, .ctor, slot, 0)
		j_op(c, W_LOCAL_TEE)
		w_uleb(&c.out, I_T6)
		j_op(c, W_I32_EQZ)
		j_op(c, W_IF)
		j_op(c, W_VOID)
		c.nest += 1
		c.st.n = low
		j_stub(c, pc, .throw, 0, n)
		c.st.n = n
		j_op(c, W_END)
		c.nest -= 1
		if psh != nil {j_alloc_end(c)}
	}
	// the block: T1 its values, T0 the frame after them; the segment's top moves past it
	j_lget(c, I_T2)
	j_mem(c, W_I32_LOAD, 2, SEG_DATA)
	j_lget(c, I_T4)
	j_i32(c, VALUE_SHIFT)
	j_op(c, W_I32_SHL)
	j_op(c, W_I32_ADD)
	j_op(c, W_LOCAL_TEE)
	w_uleb(&c.out, I_T1)
	j_i32(c, i32(total * size_of(Value)))
	j_op(c, W_I32_ADD)
	j_lset(c, I_T0)
	j_lget(c, I_T2)
	j_lget(c, I_T4)
	j_i32(c, i32(total + FRAME_VALUES))
	j_op(c, W_I32_ADD)
	j_mem(c, W_I32_STORE, 2, SEG_TOP)
	// the arguments, then undefined in the other arguments, the locals and the operand stack (frame_layout)
	for k in 0 ..< argc {j_copy_value(c, P_STACK, u32((n - argc + k) * size_of(Value)), I_T1, u32(k * size_of(Value)))}
	for i in argc ..< total {j_st_value(c, I_T1, u32(i * size_of(Value)), .undefined, 0)}
	// the frame (frame_push)
	j_st32l(c, I_T0, FRAME_PREV, P_FRAME)
	j_st32(c, I_T0, FRAME_CTX, i32(uintptr(c.ctx)))
	j_st32(c, I_T0, FRAME_CALLER_CTX, i32(uintptr(c.ctx)))
	j_st_object(c, I_T0, FRAME_FUNC, I_T5)
	j_st32(c, I_T0, FRAME_BC, i32(uintptr(nb)))
	switch kind {
	case .method:
		j_copy_value(c, P_STACK, u32(low * size_of(Value)), I_T0, FRAME_THIS)
	case .construct:
		j_st_object(c, I_T0, FRAME_THIS, I_T6)
	case .call:
		j_st_value(c, I_T0, FRAME_THIS, .undefined, 0)
	}
	if construct {
		j_copy_value(c, P_STACK, callee + size_of(Value), I_T0, FRAME_NEW_TARGET)
	} else {
		j_st_value(c, I_T0, FRAME_NEW_TARGET, .undefined, 0)
	}
	j_st32l(c, I_T0, FRAME_ARGS, I_T1)
	j_st32(c, I_T0, FRAME_ARG_BUF_LEN, i32(abl))
	j_st32(c, I_T0, FRAME_ARGC, i32(argc))
	for slot in ([]struct {off: u32, at: u32}{{FRAME_LOCALS, u32(abl * size_of(Value))}, {FRAME_STACK, stack0}}) {
		j_lget(c, I_T0)
		j_lget(c, I_T1)
		j_i32(c, i32(slot.at))
		j_op(c, W_I32_ADD)
		j_mem(c, W_I32_STORE, 2, slot.off)
	}
	j_st32l(c, I_T0, FRAME_VAR_REFS, I_T0)
	for off in ([]u32{FRAME_SP, FRAME_PC, FRAME_EXTRA_ARGS, FRAME_EXTRA_ARGS + size_of(rawptr), FRAME_CORO, FRAME_STORAGE, FRAME_STORAGE_LEN}) {
		j_st32(c, I_T0, off, 0)
	}
	j_st32l(c, I_T0, FRAME_SEG_INDEX, I_T3)
	j_st32l(c, I_T0, FRAME_SEG_TOP, I_T4)
	j_lget(c, I_T0)
	j_i32(c, 0)
	j_mem(c, W_I32_STORE8, 0, FRAME_PENDING_THROW)
	j_lget(c, I_T0)
	j_i32(c, 1)
	j_mem(c, W_I32_STORE8, 0, FRAME_STACKLESS)
	j_lget(c, I_T0)
	j_lget(c, I_T5)
	j_mem(c, W_I32_LOAD, 2, FUNC_VAR_REFS)
	j_mem(c, W_I32_STORE, 2, FRAME_CLOSURE_REFS)
	j_lget(c, I_T0)
	j_ld32(c, rtp, RT_TEMP_ROOTS_LEN)
	j_mem(c, W_I32_STORE, 2, FRAME_ROOT_BASE)
	// the runtime: the frame is the current one, one call deeper; the caller's pc after its call
	j_i32(c, i32(rtp))
	j_lget(c, I_T0)
	j_mem(c, W_I32_STORE, 2, RT_CUR_FRAME)
	for off in ([]u32{RT_STACK_DEPTH, RT_JIT_DEPTH}) {
		j_i32(c, i32(rtp))
		j_ld32(c, rtp, off)
		j_i32(c, 1)
		j_op(c, W_I32_ADD)
		j_mem(c, W_I32_STORE, 2, off)
	}
	j_st32(c, P_FRAME, FRAME_PC, i32(next))
	// the call (T3: the index of the code called)
	j_ld32(c, info, INFO_FN_INDEX)
	j_lset(c, I_T3)
	j_lget(c, I_T1)
	j_lget(c, I_T1)
	j_i32(c, i32(abl * size_of(Value)))
	j_op(c, W_I32_ADD)
	j_lget(c, I_T1)
	j_i32(c, i32(stack0))
	j_op(c, W_I32_ADD)
	j_i32(c, 0)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, FRAME_CLOSURE_REFS)
	j_lget(c, I_T0)
	j_lget(c, I_T3)
	c.table = true
	j_op(c, W_CALL_INDIRECT)
	w_uleb(&c.out, 0)   // (type 0: the compiled functions')
	w_uleb(&c.out, 0)
	j_lset(c, c.r64)
	j_i32(c, i32(rtp))
	j_ld32(c, rtp, RT_JIT_DEPTH)
	j_i32(c, 1)
	j_op(c, W_I32_SUB)
	j_mem(c, W_I32_STORE, 2, RT_JIT_DEPTH)
	// not its return: the rest of the call is the helper's (T2: it threw)
	j_i32(c, 0)
	j_lset(c, I_T2)
	j_lget(c, c.r64)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 24)
	j_op(c, W_I64_SHR_U)
	j_op(c, W_I32_WRAP_I64)
	j_i32(c, 0xff)
	j_op(c, W_I32_AND)
	j_i32(c, i32(Jit_Exit.ret))
	j_op(c, W_I32_NE)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	j_lget(c, I_T0)
	j_lget(c, c.r64)
	j_op(c, W_I32_WRAP_I64)
	j_lget(c, c.r64)
	j_op(c, W_I64_CONST)
	w_sleb(&c.out, 32)
	j_op(c, W_I64_SHR_U)
	j_op(c, W_I32_WRAP_I64)
	j_lget(c, I_T3)
	j_i32(c, i32(slot))
	j_helper(c, .finish)
	j_lset(c, I_T2)
	j_op(c, W_END)
	// the frame popped (frame_pop): the caller's again, one call less deep, the temporary roots of the call gone, the
	// value stack's top back where it was (its segments may have moved: their array is read again)
	j_i32(c, i32(rtp))
	j_lget(c, P_FRAME)
	j_mem(c, W_I32_STORE, 2, RT_CUR_FRAME)
	j_i32(c, i32(rtp))
	j_ld32(c, rtp, RT_STACK_DEPTH)
	j_i32(c, 1)
	j_op(c, W_I32_SUB)
	j_mem(c, W_I32_STORE, 2, RT_STACK_DEPTH)
	j_i32(c, i32(rtp))
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, FRAME_ROOT_BASE)
	j_ld32(c, rtp, RT_TEMP_ROOTS_LEN)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, FRAME_ROOT_BASE)
	j_ld32(c, rtp, RT_TEMP_ROOTS_LEN)
	j_op(c, W_I32_LT_U)
	j_op(c, W_SELECT)
	j_mem(c, W_I32_STORE, 2, RT_TEMP_ROOTS_LEN)
	j_i32(c, i32(rtp))
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, FRAME_SEG_INDEX)
	j_mem(c, W_I32_STORE, 2, RT_VSTACK_CUR)
	j_ld32(c, rtp, RT_VSTACK_DATA)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, FRAME_SEG_INDEX)
	j_i32(c, i32(SEG_SIZE))
	j_op(c, W_I32_MUL)
	j_op(c, W_I32_ADD)
	j_lget(c, I_T0)
	j_mem(c, W_I32_LOAD, 2, FRAME_SEG_TOP)
	j_mem(c, W_I32_STORE, 2, SEG_TOP)
	// it threw: the interpreter makes the call again, whose callee jit_call_finish made one that throws
	j_lget(c, I_T2)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	c.nest += 1
	c.st.n = low
	j_stub(c, pc, .throw, 0, n)
	c.st.n = n
	j_op(c, W_END)
	c.nest -= 1
	// the result where the helper's call leaves it
	j_lget(c, I_T1)
	j_i32(c, i32(stack0))
	j_op(c, W_I32_ADD)
	j_lset(c, I_T1)
	if construct {
		// (a construction's result: the callee's when it is an object, else the object made)
		j_lget(c, I_T1)
		j_mem(c, W_I32_LOAD8_U, 0, 0)
		j_i32(c, i32(Tag.object))
		j_op(c, W_I32_EQ)
		j_op(c, W_IF)
		j_op(c, W_VOID)
		j_copy_value(c, I_T1, 0, P_STACK, u32(low * size_of(Value)))
		j_op(c, W_ELSE)
		j_st_object(c, P_STACK, u32(low * size_of(Value)), I_T6)
		j_op(c, W_END)
	} else {
		j_copy_value(c, I_T1, 0, P_STACK, u32(low * size_of(Value)))
	}
	j_op(c, W_BR)
	w_uleb(&c.out, 1)
}

// Inlining ------------------------------------------------------------------------------------------------------------

// Can the function b be inlined at a call of `kind`: a small function of straight-line code that has no effect but on
// its own locals (it reads properties, globals and elements, computes, calls functions that are inlined too), so that a
// deopt anywhere in it can leave the call to the interpreter as if it had not begun.
@(private = "file")
jit_inlinable :: proc(c: ^Jc, b: ^Function_Bytecode, kind: Jit_Call_Kind) -> bool {
	if b.func_kind != .normal || b.closure_var_count != 0 || b.realm != c.ctx || len(b.code) > JIT_INLINE_MAX_CODE ||
	   c.inl_depth >= JIT_INLINE_DEPTH {
		return false
	}
	code := b.code
	nargs := int(b.arg_count)
	for pc := 0; pc < len(code); {
		if int(code[pc]) >= OPCODE_COUNT {return false}
		op := Opcode(code[pc])
		size := int(opcode_info[op].size)
		if pc + size > len(code) {return false}
		if s, w, ok := jit_op_slot(op, code, pc, nargs); ok {
			#partial switch op {
			case .inc_loc, .dec_loc, .add_loc, .get_loc_check, .put_loc_check: return false
			}
			if w && s < nargs {return false}
			pc += size
			continue
		}
		#partial switch op {
		case .op_return, .return_undef, .tail_call, .tail_call_method:
			return true
		case .push_this:
			// (a sloppy function's `this` is its call's object only when there is one)
			if kind != .method && !b.is_strict_mode {return false}
		case .push_minus1, .push_0, .push_1, .push_2, .push_3, .push_4, .push_5, .push_6, .push_7, .push_i8, .push_i16,
		     .push_i32, .push_const, .push_const8, .undefined, .null, .push_true, .push_false, .drop, .dup, .dup1, .dup2,
		     .nip, .swap, .insert2, .insert3, .insert4, .rot3l, .rot3r, .perm3, .get_field, .get_field2, .get_length,
		     .get_array_el, .get_array_el2, .get_var, .get_var_undef, .add, .sub, .mul, .div, .mod, .shl, .sar, .shr,
		     .op_and, .op_or, .xor, .lt, .lte, .gt, .gte, .eq, .neq, .strict_eq, .strict_neq, .neg, .plus, .inc, .dec,
		     .op_not, .lnot, .is_undefined, .is_null, .is_undefined_or_null, .typeof_is_undefined, .get_loc0_loc1,
		     .call0, .call1, .call2, .call3, .call, .call_method, .op_nop:
		case:
			return false
		}
		pc += size
	}
	return false
}

// The call at pc of the function object fo (argc arguments, the callee's entry under them) inlined: its code
// translated in place, its arguments and locals entries of the stack, its result taking the place of the callee (and
// of `this`). False: not inlined, nothing emitted (the translation as it was before).
@(private = "file")
j_inline :: proc(c: ^Jc, f: ^Frame, fo: ^Object, op: Opcode, argc: int, kind: Jit_Call_Kind, low: int, pc: int, wide: bool) -> bool {
	b := fo.data.(Func_Data).bc
	n := c.st.n
	nargs := int(b.arg_count)
	first := n - argc
	locals := first + max(argc, nargs)
	if !jit_inlinable(c, b, kind) || locals + int(b.var_count) + int(b.stack_size) > c.ss {return false}
	saved := c^
	saved_out := len(c.out)
	ok := j_guard_callee(c, n - argc - 1, fo, pc, JIT_AUX_LEARN)
	if ok {
		if c.inl_depth == 0 {
			c.inl_n = n
			c.inl_pc = pc
		}
		// missing arguments and the locals start undefined
		for _ in argc ..< nargs {j_push_undefined(c)}
		for _ in 0 ..< int(b.var_count) {j_push_undefined(c)}
		c.inl_depth += 1
		c.inl_first = first
		c.inl_locals = locals
		c.inl_nargs = nargs
		c.inl_this = kind == .method ? low : -1
		c.inl_wide = c.inl_wide || wide
		c.site_base = (c.site_base + pc + 1) << JIT_INLINE_SITE_SHIFT
		c.code = b.code
		c.b = b
		result := -1
		for cp := 0; cp < len(b.code) && !c.fail && !c.restart; {
			o := Opcode(b.code[cp])
			if o == .op_return {
				result = c.st.n - 1
				break
			}
			if o == .return_undef {
				result = j_push_undefined(c)
				break
			}
			if o == .tail_call || o == .tail_call_method {
				// (the call's result is the callee's)
				method := o == .tail_call_method
				if jit_call_insn(c, f, method ? .call_method : .call, jr_u16(b.code, cp + 1), method ? .method : .call, cp) {result = c.st.n - 1}
				break
			}
			if !jit_insn(c, f, o, cp) {break}
			cp += int(opcode_info[o].size)
		}
		ok = result >= 0 && !c.fail && !c.restart
		if ok {
			t := c.st.t[result]
			j_copy(c, result, low, t)
			c.st.t[low] = t
			c.st.a[low] = c.st.a[result]
			c.st.v[low] = c.st.v[result]
			c.st.n = low + 1
		}
	}
	restart, out, st, helpers, table := c.restart, c.out, c.st, c.helpers, c.table
	c^ = saved
	c.out = out
	c.helpers, c.table = helpers, table   // (what the module imports: what any code emitted calls)
	if !ok {
		// back to the translation of before the call
		resize(&c.out, saved_out)
		c.restart = restart
		return restart
	}
	c.st = st
	return true
}

// A V entry undefined, pushed.
@(private = "file")
j_push_undefined :: proc(c: ^Jc) -> int {
	d := j_push(c, .V)
	j_i32(c, i32(Tag.undefined))
	j_lset(c, j_si(c, d))
	c.st.v[d] = UNDEFINED
	return d
}

// A slot instruction of a callee being inlined: its slots are stack entries.
@(private = "file")
j_inline_slot :: proc(c: ^Jc, op: Opcode, s: int, write: bool) -> bool {
	at :: proc(c: ^Jc, s: int) -> int {return s < c.inl_nargs ? c.inl_first + s : c.inl_locals + (s - c.inl_nargs)}
	if op == .get_loc0_loc1 {
		for k in 0 ..< 2 {j_inline_slot(c, .get_loc, c.inl_nargs + k, false)}
		return !c.fail
	}
	n := c.st.n
	e := at(c, s)
	if !write {
		t := c.st.t[e]
		d := j_push(c, t)
		c.st.a[d] = c.st.a[e]
		c.st.v[d] = c.st.v[e]
		j_copy(c, e, d, t)
		return !c.fail
	}
	t := c.st.t[n - 1]
	j_copy(c, n - 1, e, t)
	c.st.t[e] = t
	c.st.a[e] = c.st.a[n - 1]
	c.st.v[e] = c.st.v[n - 1]
	keep := op == .set_loc || op == .set_loc8 || op == .set_loc0 || op == .set_loc1 || op == .set_loc2 || op == .set_loc3
	if !keep {c.st.n -= 1}
	return true
}

// the stack entry d as a double on the Wasm stack
@(private = "file")
j_get_f :: proc(c: ^Jc, d: int) {
	switch c.st.t[d] {
	case .F:
		j_lget(c, j_sf(c, d))
	case .L:
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_F64_CONVERT_I64_S)
	case .I, .B, .O, .P, .V, .M:
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

// the i32 local src as a payload (the word the interpreter reads of an int, a bool, a pointer)
@(private = "file")
j_store_low :: proc(c: ^Jc, base: u32, off: u32, src: u32) {
	j_lget(c, base)
	j_lget(c, src)
	j_mem(c, W_I32_STORE, 2, off)
}

@(private = "file")
j_store_tag :: proc(c: ^Jc, base: u32, off: u32, tag: Tag) {
	j_lget(c, base)
	j_i32(c, i32(tag))
	j_mem(c, W_I32_STORE8, 0, off)
}

// the stack entries back into the frame's operand stack (in a callee being inlined, the caller's at the call); exact:
// for a call (j_store_entry)
@(private = "file")
j_materialize :: proc(c: ^Jc, exact := false) {
	for d in 0 ..< (c.inl_depth > 0 ? c.inl_n : c.st.n) {
		j_store_entry(c, d, P_STACK, u32(d * 16), true, exact)
	}
}

@(private = "file")
j_exit_depth :: proc(c: ^Jc) -> u64 {return u64(c.nest + (c.nblocks - c.cur) + 1)}

@(private = "file")
j_loop_depth :: proc(c: ^Jc) -> u64 {return u64(c.nest + (c.nblocks - c.cur))}

// leave the loop with the current stack, to resume at `pc`; in a callee being inlined, at the call with the caller's
// stack, the call's site learning that the callee is not to be inlined
@(private = "file")
j_stub :: proc(c: ^Jc, pc: int, kind: Jit_Exit, aux: u32, sp := -1) {
	j_materialize(c)
	inlined := c.inl_depth > 0
	j_i32(c, i32(inlined ? c.inl_pc : pc))
	j_lset(c, I_PC)
	j_i32(c, i32(inlined ? c.inl_n : sp >= 0 ? sp : c.st.n))
	j_lset(c, I_SP)
	j_i32(c, i32(kind))
	j_lset(c, I_KIND)
	j_i32(c, i32(inlined ? JIT_AUX_NO_INLINE : aux))
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
	for i in 0 ..< a.n {
		if a.t[i] != b.t[i] || (a.t[i] == .O && a.a[i] != b.a[i]) {return false}
	}
	return true
}

// The operand stack reaches the leader j (a forward jump or the fall-through): where the join is forced its numbers
// become doubles, then the state is recorded (first edge) or compared. Two edges that carry different kinds of numbers
// (the arms of `c ? 1 : 0.5`) make the join a forced one and the loop is translated again.
@(private = "file")
j_join :: proc(c: ^Jc, j: int) -> bool {
	lpc := c.lpcs[j]
	forced_f := false
	for i in 0 ..< c.jl.n_join_f {if c.jl.join_f[i] == lpc {forced_f = true}}
	vmask: u32
	for i in 0 ..< c.jl.n_join_v {if c.jl.join_v[i].pc == lpc {vmask = c.jl.join_v[i].mask}}
	for d in 0 ..< c.st.n {
		t := c.st.t[d]
		if vmask & (u32(1) << uint(d)) != 0 {
			if t != .V && !j_to_v(c, d) {return false}
		} else if forced_f && (t == .I || t == .L) {
			j_get_f(c, d)
			j_lset(c, j_sf(c, d))
			c.st.t[d] = .F
		}
	}
	// (the shapes the code knows of the objects it made are not followed across a join)
	for d in 0 ..< c.st.n {c.st.k[d] = nil}
	if !c.lvalid[j] {
		c.lstate[j] = c.st
		c.lvalid[j] = true
		return true
	}
	if j_state_eq(&c.lstate[j], &c.st) {return true}
	if c.lstate[j].n == c.st.n {
		// the entries whose types differ: numbers become doubles there, anything else values (V)
		numeric := true
		mask: u32
		for d in 0 ..< c.st.n {
			a, b := c.st.t[d], c.lstate[j].t[d]
			if a != b || (a == .O && c.st.a[d] != c.lstate[j].a[d]) {
				mask |= u32(1) << uint(d)
				if !j_is_num(a) || !j_is_num(b) {numeric = false}
			}
		}
		if numeric && !forced_f && c.jl.n_join_f < len(c.jl.join_f) {
			c.jl.join_f[c.jl.n_join_f] = lpc
			c.jl.n_join_f += 1
			c.restart = true
			return false
		}
		if vmask & mask != mask {
			k := 0
			for k < c.jl.n_join_v && c.jl.join_v[k].pc != lpc {k += 1}
			if k < len(c.jl.join_v) {
				if k == c.jl.n_join_v {
					c.jl.join_v[k] = Jit_Join_V{pc = lpc}
					c.jl.n_join_v += 1
				}
				c.jl.join_v[k].mask |= mask
				c.restart = true
				return false
			}
		}
	}
	j_fail(c, "operand stack types differ at a join")
	return false
}

// The entry d becomes a V (the value it holds, tagged).
@(private = "file")
j_to_v :: proc(c: ^Jc, d: int) -> bool {
	tag, pl := j_si(c, d), c.sl0 + u32(d)
	#partial switch c.st.t[d] {
	case .I, .B, .P:
		j_lget(c, tag)
		j_op(c, c.st.t[d] == .I ? W_I64_EXTEND_I32_S : W_I64_EXTEND_I32_U)
		j_lset(c, pl)
		j_i32(c, i32(c.st.t[d] == .I ? Tag.int : c.st.t[d] == .B ? Tag.bool : Tag.object))
		j_lset(c, tag)
	case .F:
		j_lget(c, j_sf(c, d))
		j_op(c, W_I64_REINTERPRET_F64)
		j_lset(c, pl)
		j_i32(c, i32(Tag.float))
		j_lset(c, tag)
	case .L:
		// an int when it fits, else the double the interpreter would hold
		j_l_not_i32(c, d)
		j_lset(c, I_T0)
		j_lget(c, pl)
		j_op(c, W_F64_CONVERT_I64_S)
		j_op(c, W_I64_REINTERPRET_F64)
		j_lget(c, pl)
		j_lget(c, I_T0)
		j_op(c, W_SELECT)
		j_lset(c, pl)
		j_i32(c, i32(Tag.float))
		j_i32(c, i32(Tag.int))
		j_lget(c, I_T0)
		j_op(c, W_SELECT)
		j_lset(c, tag)
	case .O:
		base, off := j_slot_addr(c, c.jl.arr_slots[c.st.a[d]])
		j_lget(c, base)
		j_mem(c, W_I32_LOAD8_U, 0, off)
		j_lset(c, tag)
		j_lget(c, base)
		j_mem(c, W_I64_LOAD, 3, off + 8)
		j_lset(c, pl)
	case:
		j_fail(c, "an entry that cannot be a value")
		return false
	}
	c.st.t[d] = .V
	return true
}
// ToInt32 of the stack entry d, on the Wasm stack (a double outside the int32 range leaves through a deopt)
@(private = "file")
j_get_i32 :: proc(c: ^Jc, d: int, pc: int) {
	if c.st.t[d] == .I || c.st.t[d] == .B {
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

// the bits of a payload's low word that carry the value, for the tag in local `tag` (a bool is its low byte)
@(private = "file")
j_low_mask :: proc(c: ^Jc, tag: u32) {
	j_i32(c, 0xff)
	j_i32(c, -1)
	j_lget(c, tag)
	j_i32(c, i32(Tag.bool))
	j_op(c, W_I32_EQ)
	j_op(c, W_SELECT)
}

// an object's ToBoolean: true but for document.all (i32 on the Wasm stack, from the object's address in local p)
@(private = "file")
j_obj_truthy :: proc(c: ^Jc, p: u32) {
	j_lget(c, p)
	j_mem(c, W_I32_LOAD8_U, 0, OBJ_BITS)
	j_i32(c, i32(c.htmldda_bit))
	j_op(c, W_I32_AND)
	j_op(c, W_I32_EQZ)
}

// ToBoolean of the stack entry d (i32 on the Wasm stack); a V that is neither undefined, null, a bool, an int nor an
// object leaves the instruction at pc to the interpreter
@(private = "file")
j_get_bool :: proc(c: ^Jc, d: int, pc: int) {
	if c.st.t[d] == .P {
		j_obj_truthy(c, j_si(c, d))
		return
	}
	if c.st.t[d] == .O {
		// (an array or a typed array: never document.all; an O has no Wasm local)
		j_i32(c, 1)
		return
	}
	if c.st.t[d] == .V {
		tag := j_si(c, d)
		j_lget(c, tag)
		j_i32(c, i32(Tag.object))
		j_op(c, W_I32_EQ)
		j_lget(c, tag)
		j_i32(c, i32(Tag.int))
		j_op(c, W_I32_GT_U)
		j_op(c, W_I32_XOR)
		// (above int: only an object is quick to decide)
		j_deopt_if(c, pc)
		j_lget(c, tag)
		j_i32(c, i32(Tag.object))
		j_op(c, W_I32_EQ)
		j_op(c, W_IF)
		j_op(c, W_I32)
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I32_WRAP_I64)
		j_lset(c, I_T1)
		j_obj_truthy(c, I_T1)
		j_op(c, W_ELSE)
		// undefined, null: false; a bool or an int: its payload (a bool's low byte)
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I32_WRAP_I64)
		j_low_mask(c, tag)
		j_op(c, W_I32_AND)
		j_i32(c, 0)
		j_op(c, W_I32_NE)
		j_lget(c, tag)
		j_i32(c, i32(Tag.bool))
		j_op(c, W_I32_GE_U)
		j_op(c, W_I32_AND)
		j_op(c, W_END)
		return
	}
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

// Does the function make a mapped arguments object (whose elements are its arguments' slots)?
@(private = "file")
jit_has_mapped_arguments :: proc(b: ^Function_Bytecode) -> bool {
	code := b.code
	for pc := 0; pc < len(code); {
		op := Opcode(code[pc])
		if int(code[pc]) >= OPCODE_COUNT {return true}
		if op == .special_object && pc + 1 < len(code) && Special_Object(code[pc + 1]) == .mapped_arguments {return true}
		pc += int(opcode_info[op].size)
	}
	return false
}
// Builds the module for the loop and hands it to the host.
@(private = "file")
jit_build :: proc(ctx: ^Context, f: ^Frame, b: ^Function_Bytecode, jl: ^Jit_Loop, sp: int) {
	rt := ctx.rt
	saved := context.allocator
	context.allocator = tmp(rt)
	defer context.allocator = saved
	if jl.compiles - jl.learns >= JIT_MAX_REJITS + 1 {
		jl.state = .never
		return
	}
	jl.compiles += 1
	for _ in 0 ..< JIT_MAX_RESTARTS {
		c := Jc{rt = rt, ctx = f.ctx, b = b, jl = jl, code = b.code, header = jl.header, rend = jl.region_end, entry_sp = sp}
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
	return string(slice.clone(buf[i:]))
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
	c.ss = min(max(int(b.stack_size), 1) + 6, JIT_STACK_MAX)   // (+ room for the temporaries of stack shuffles)
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
		#partial switch op {
		case .call0, .call1, .call2, .call3, .call, .call_method, .call_constructor, .tail_call, .tail_call_method:
			c.calls = true
		}
		pc += size
	}
	if pc != c.rend {
		j_fail(c, "region does not end on an instruction")
		return .refuse
	}
	if c.calls {c.ss = JIT_STACK_MAX}   // (room for the callees inlined)
	n := 0
	for i in 0 ..< c.rend - c.header {
		if leader[i] {n += 1}
	}
	c.lpcs = make([]int, n)
	n = 0
	for i in 0 ..< c.rend - c.header {
		if leader[i] {
			c.lidx[i] = i32(n)
			c.lpcs[n] = c.header + i
			n += 1
		}
	}
	c.nleaders = n
	c.nblocks = n - 1
	c.lstate = make([]Jit_State, n)
	c.lvalid = make([]bool, n)

	// the speculated type of each slot the region uses; a loop that calls leaves to the frame's memory the locals a
	// closure may reach (captured ones, the arguments of a function with a mapped arguments object)
	mapped := c.calls && jit_has_mapped_arguments(b)
	n_i, n_f: u32
	c.arr_ord = make([]int, c.nslots)
	c.jl.n_arr = 0
	for s in 0 ..< c.nslots {
		c.arr_ord[s] = -1
		if !c.ref[s] {continue}
		v := jit_slot_value(f, s)
		kind := Jit_Slot_Kind.box
		if c.jl.boxed & (u64(1) << uint(s)) != 0 && s < 64 {
			kind = .box
		} else if c.calls && ((s < len(b.vardefs) && b.vardefs[s].is_captured) || (mapped && s < c.nargs)) {
			kind = .box
		} else if v.tag == .int {
			kind = (s < 64 && c.jl.widen & (u64(1) << uint(s)) != 0) ? .f64 : .i32
		} else if v.tag == .float {
			kind = .f64
		} else if ak := jit_array_of(v); ak.kind != .none && c.jl.n_arr < JIT_MAX_ARRS && !c.written[s] {
			kind = .arr
			c.arr_ord[s] = c.jl.n_arr
			c.jl.arr_slots[c.jl.n_arr] = s
			c.jl.arr_kinds[c.jl.n_arr] = ak.kind
			c.jl.n_arr += 1
		} else if v.tag == .object {
			kind = .obj
		}
		c.skind[s] = kind
	}
	for s in 0 ..< c.nslots {
		#partial switch c.skind[s] {
		case .i32, .obj:
			c.wl[s] = u32(I_FIRST) + n_i
			n_i += 1
		case .f64:
			c.wl[s] = n_f
			n_f += 1
		}
	}
	c.fast_bit = jit_object_bit(.fast_array)
	c.extensible_bit = jit_object_bit(.extensible)
	c.host_exotic_bit = jit_object_bit(.host_exotic)
	c.ctor_bits = jit_object_bit(.is_constructor) | jit_object_bit(.ctor_only)
	c.htmldda_bit = jit_object_bit(.is_htmldda)
	// entry stack types from the frame
	c.st.n = c.entry_sp
	for d in 0 ..< JIT_STACK_MAX {c.st.v[d] = EXCEPTION}
	for d in 0 ..< c.entry_sp {
		switch f.stack[d].tag {
		case .int: c.st.t[d] = .I
		case .float: c.st.t[d] = .F
		case .bool: c.st.t[d] = .B
		case .undefined, .null, .string, .symbol, .object, .bigint, .function_bc, .module, .uninitialized, .exception, .catch_offset:
			c.st.t[d] = .M
		}
	}
	c.lstate[0] = c.st
	c.lvalid[0] = true

	// the Wasm locals: i32 [fixed][slots][stack], i64 [2], f64 [slots][stack][2]
	c.a0 = u32(I_FIRST) + n_i           // three i32 per array: base, count, length
	c.si0 = c.a0 + 3 * u32(c.jl.n_arr)
	c.ni = c.si0 + u32(c.ss) - JIT_PARAMS   // (the parameters take the first indices: count the declared i32 locals)
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
	// -- the entry: guards and loads
	for s in 0 ..< c.nslots {
		kind := c.skind[s]
		if kind != .i32 && kind != .f64 && kind != .obj {continue}
		base, off := j_slot_addr(c, s)
		j_lget(c, base)
		j_mem(c, W_I32_LOAD8_U, 0, off)
		if kind != .f64 {
			j_i32(c, i32(kind == .i32 ? Tag.int : Tag.object))
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
	for k in 0 ..< c.jl.n_arr {
		o := u32(k * 16)
		j_lget(c, P_ARRAYS)
		j_mem(c, W_I32_LOAD, 2, o + 12)
		j_i32(c, i32(c.jl.arr_kinds[k]))
		j_op(c, W_I32_NE)
		j_ret_if(c, c.header, .guard, u32(c.jl.arr_slots[k]))
		for w in 0 ..< u32(3) {
			j_lget(c, P_ARRAYS)
			j_mem(c, W_I32_LOAD, 2, o + 4 * w)
			j_lset(c, c.a0 + 3 * u32(k) + w)
		}
	}
	for d in 0 ..< c.entry_sp {
		t := c.st.t[d]
		if t == .M {continue}
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
		case .L, .O, .P, .V, .M:
			j_op(c, W_UNREACHABLE)   // (no entry stack entry has these types)
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
			if valid && !j_join(c, k) {break}
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
		if (kind != .i32 && kind != .f64 && kind != .obj) || !c.written[s] {continue}
		base, off := j_slot_addr(c, s)
		j_store_tag(c, base, off, kind == .i32 ? .int : kind == .obj ? .object : .float)
		if kind == .f64 {
			j_lget(c, base)
			j_lget(c, c.wl[s])
			j_mem(c, W_F64_STORE, 3, off + 8)
		} else {
			j_store_low(c, base, off + 8, c.wl[s])
		}
	}
	// leaving or returning: the aux word is the number of iterations this entry ran
	j_lget(c, I_KIND)
	j_i32(c, 2)
	j_op(c, W_I32_LT_U)
	j_op(c, W_IF)
	j_op(c, W_VOID)
	j_i32(c, JIT_BUDGET)
	j_lget(c, I_BUDGET)
	j_op(c, W_I32_SUB)
	j_lset(c, I_AUX)
	j_op(c, W_END)
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

	// -- the module around the function (after its code: what the code calls is known then)
	m: Wbuf
	sec: Wbuf
	append(&m, 0, 'a', 's', 'm', 1, 0, 0, 0)
	// types: 0 = (args, locals, stack, arrays, refs, frame: i32) -> i64, then the helpers' (Jit_Helper)
	w_uleb(&sec, 1 + len(Jit_Helper))
	w_u8(&sec, 0x60)
	w_uleb(&sec, JIT_PARAMS)
	for _ in 0 ..< JIT_PARAMS {w_u8(&sec, W_I32)}
	w_uleb(&sec, 1)
	w_u8(&sec, W_I64)
	helpers := JIT_HELPERS
	for h in Jit_Helper {
		w_u8(&sec, 0x60)
		w_uleb(&sec, u64(helpers[h].params))
		for _ in 0 ..< helpers[h].params {w_u8(&sec, W_I32)}
		w_uleb(&sec, 1)
		w_u8(&sec, W_I32)
	}
	w_section(&m, 1, &sec)
	// imports: the engine's memory, the helpers when the code calls one (function indices from 0), the table when it
	// calls compiled code
	n_imports := c.helpers ? len(Jit_Helper) : 0
	w_uleb(&sec, u64(1 + n_imports + (c.table ? 1 : 0)))
	w_name(&sec, "e")
	w_name(&sec, "memory")
	w_u8(&sec, 0x02)
	w_u8(&sec, 0x00)
	w_uleb(&sec, 0)
	if n_imports > 0 {
		for h in Jit_Helper {
			w_name(&sec, "e")
			w_name(&sec, helpers[h].name)
			w_u8(&sec, 0x00)
			w_uleb(&sec, u64(1 + int(h)))
		}
	}
	if c.table {
		w_name(&sec, "e")
		w_name(&sec, JIT_TABLE_IMPORT)
		w_u8(&sec, 0x01)
		w_u8(&sec, W_FUNCREF)
		w_u8(&sec, 0x00)
		w_uleb(&sec, 0)
	}
	w_section(&m, 2, &sec)
	// one function, exported as "f"
	w_uleb(&sec, 1)
	w_uleb(&sec, 0)
	w_section(&m, 3, &sec)
	w_uleb(&sec, 1)
	w_name(&sec, "f")
	w_u8(&sec, 0x00)
	w_uleb(&sec, u64(n_imports))
	w_section(&m, 7, &sec)

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
j_store_entry :: proc(c: ^Jc, d: int, base: u32, off: u32, exiting := false, exact := false) {
	t := c.st.t[d]
	switch t {
	case .I:
		j_store_tag(c, base, off, .int)
		j_store_low(c, base, off + 8, j_si(c, d))
	case .B:
		j_store_tag(c, base, off, .bool)
		j_store_low(c, base, off + 8, j_si(c, d))
	case .F:
		j_store_tag(c, base, off, .float)
		j_lget(c, base)
		j_lget(c, j_sf(c, d))
		j_mem(c, W_F64_STORE, 3, off + 8)
	case .P:
		j_store_tag(c, base, off, .object)
		j_store_low(c, base, off + 8, j_si(c, d))
	case .V:
		j_lget(c, base)
		j_lget(c, j_si(c, d))
		j_mem(c, W_I32_STORE8, 0, off)
		j_lget(c, base)
		j_lget(c, c.sl0 + u32(d))
		j_mem(c, W_I64_STORE, 3, off + 8)
	case .M:
		// (where it is already: only the loop's own entries move)
		if base != P_STACK || off != u32(d * 16) {j_fail(c, "an entry under the loop's moved")}
	case .O:
		// the array's own Value, copied from the local it came from (the loop never writes such a local)
		sb, so := j_slot_addr(c, c.jl.arr_slots[c.st.a[d]])
		for half in 0 ..< u32(2) {
			j_lget(c, base)
			j_lget(c, sb)
			j_mem(c, W_I64_LOAD, 3, so + 8 * half)
			j_mem(c, W_I64_STORE, 3, off + 8 * half)
		}
	case .L:
		// leaving: a double (a value the interpreter may hold; a deopt stub stays small); exact: what the interpreter
		// would hold, an int when it fits (what a callee or a caller is given: its type speculated from it); into a
		// local the loop leaves to the interpreter: it must fit an int32, or the instruction is left to the interpreter
		if exiting && !exact {
			j_store_tag(c, base, off, .float)
			j_lget(c, base)
			j_lget(c, c.sl0 + u32(d))
			j_op(c, W_F64_CONVERT_I64_S)
			j_mem(c, W_F64_STORE, 3, off + 8)
		} else if exiting {
			j_lget(c, base)
			j_i32(c, i32(Tag.float))
			j_i32(c, i32(Tag.int))
			j_l_not_i32(c, d)
			j_op(c, W_SELECT)
			j_mem(c, W_I32_STORE8, 0, off)
			j_lget(c, base)
			j_lget(c, c.sl0 + u32(d))
			j_op(c, W_F64_CONVERT_I64_S)
			j_op(c, W_I64_REINTERPRET_F64)
			j_lget(c, c.sl0 + u32(d))
			j_op(c, W_I32_WRAP_I64)
			j_op(c, W_I64_EXTEND_I32_U)
			j_l_not_i32(c, d)
			j_op(c, W_SELECT)
			j_mem(c, W_I64_STORE, 3, off + 8)
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
		// the budget: every JIT_BUDGET iterations the interpreter gets a turn (interrupt poll, collection); in a loop
		// that calls, also once the calls made count for a poll (call_native adds NATIVE_CALL_POLL_WEIGHT to
		// interrupt_counter, as in the interpreter): a loop of slow natives (document.write) otherwise polled after
		// JIT_BUDGET of them, past the host's hard limit (wasm.max_call_ms), and the page lost its engine
		j_lget(c, I_BUDGET)
		j_i32(c, 1)
		j_op(c, W_I32_SUB)
		j_op(c, 0x22)   // local.tee
		w_uleb(&c.out, I_BUDGET)
		j_op(c, W_I32_EQZ)
		if c.helpers || c.table {
			j_ld32(c, uintptr(c.rt), RT_INTERRUPT_COUNTER)
			j_i32(c, INTERRUPT_POLL_EVERY)
			j_op(c, W_I32_GE_S)
			j_op(c, W_I32_OR)
		}
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
	if !j_join(c, j) {return false}
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

	// the entries under the loop's own stay where they are
	for i in max(0, n - int(opcode_info[op].n_pop)) ..< n {
		if c.st.t[i] == .M {
			j_fail(c, "an instruction that takes an entry from under the loop's own")
			return false
		}
	}
	// values taken as numbers
	if !j_unbox_operands(c, op, pc) {return false}
	// a callee being inlined: its slots are stack entries
	if c.inl_depth > 0 {
		if op == .get_loc0_loc1 {return j_inline_slot(c, op, 0, false)}
		if s, w, ok := jit_op_slot(op, code, pc, c.inl_nargs); ok {return j_inline_slot(c, op, s, w)}
		if op == .push_this {
			if c.inl_this < 0 {
				j_push_undefined(c)
				return true
			}
			t := c.st.t[c.inl_this]
			d := j_push(c, t)
			c.st.a[d] = c.st.a[c.inl_this]
			c.st.v[d] = c.st.v[c.inl_this]
			j_copy(c, c.inl_this, d, t)
			return true
		}
	}
	// slot instructions
	if s, w, ok := jit_op_slot(op, code, pc, c.nargs); ok {
		return jit_slot_insn(c, f, op, pc, s, w)
	}
	// objects and other values (O, P, V) take part in few instructions
	#partial switch op {
	case .drop, .dup, .dup2, .get_array_el, .get_array_el2, .put_array_el, .get_length, .nip, .swap, .dup1, .insert2,
	     .insert3, .insert4, .rot3l, .rot3r, .perm3, .to_propkey, .to_propkey2, .check_object, .is_undefined, .is_null, .is_undefined_or_null,
	     .typeof_is_undefined, .typeof_is_function, .get_field, .get_field2, .put_field, .put_var, .strict_eq, .strict_neq,
	     .eq, .neq, .lnot, .if_true, .if_false, .if_true8, .if_false8, .op_return, .put_var_ref, .put_var_ref0, .put_var_ref1, .put_var_ref2,
	     .put_var_ref3, .put_var_ref_check, .set_var_ref, .set_var_ref0, .set_var_ref1, .set_var_ref2, .set_var_ref3, .call0,
	     .call1, .call2, .call3, .call, .tail_call, .call_method, .tail_call_method, .call_constructor, .define_field, .array_from,
	     .add:
	case:
		for i in max(0, n - int(opcode_info[op].n_pop)) ..< n {
			t := c.st.t[i]
			if t == .O || t == .P || t == .V {
				j_fail(c, strings.concatenate([]string{"object used as a number by ", reflect.enum_string(op)}))
				return false
			}
		}
	}
	#partial switch op {
	case .op_nop:
		return true
	case .get_array_el, .get_array_el2:
		return jit_get_array_el(c, op, pc)
	case .put_array_el:
		return jit_put_array_el(c, pc)
	case .get_field, .get_field2:
		return jit_get_field(c, op, Atom(jr_u32(code, pc + 1)), pc)
	case .put_field:
		return jit_put_field(c, Atom(jr_u32(code, pc + 1)), pc)
	case .object:
		return jit_object(c)
	case .array_from:
		return jit_array_from(c, jr_u16(code, pc + 1))
	case .define_field:
		return jit_define_field(c, Atom(jr_u32(code, pc + 1)), pc)
	case .get_var, .get_var_undef, .put_var:
		return jit_global(c, op, Atom(jr_u32(code, pc + 1)), pc)
	case .get_var_ref, .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3, .get_var_ref_check, .put_var_ref, .put_var_ref0,
	     .put_var_ref1, .put_var_ref2, .put_var_ref3, .put_var_ref_check, .set_var_ref, .set_var_ref0, .set_var_ref1, .set_var_ref2,
	     .set_var_ref3:
		return jit_var_ref(c, f, op, pc)
	case .push_atom_value, .push_empty_string:
		// a string constant (the atom's own string, which the atom table keeps)
		v := mk_str(c.rt.empty_string)
		if op == .push_atom_value {
			a := Atom(jr_u32(code, pc + 1))
			if atom_is_int(a) {
				j_fail(c, "a constant string made at each use")
				return false
			}
			v = atom_to_value(c.rt, a)
		}
		d := j_push(c, .V)
		j_i32(c, i32(v.tag))
		j_lset(c, j_si(c, d))
		j_op(c, W_I64_CONST)
		w_sleb(&c.out, i64(uintptr(v.u.ptr)))
		j_lset(c, c.sl0 + u32(d))
		c.st.v[d] = v
	case .undefined, .null:
		d := j_push(c, .V)
		j_i32(c, i32(op == .null ? Tag.null : Tag.undefined))
		j_lset(c, j_si(c, d))
		c.st.v[d] = op == .null ? NULL : UNDEFINED
	case .push_this:
		// the frame's `this` (a sloppy function's, when it is not an object, is the interpreter's to make one)
		d := j_push(c, .V)
		j_lget(c, P_FRAME)
		j_mem(c, W_I32_LOAD8_U, 0, FRAME_THIS)
		j_lset(c, j_si(c, d))
		if !c.b.is_strict_mode {
			j_lget(c, j_si(c, d))
			j_i32(c, i32(Tag.object))
			j_op(c, W_I32_NE)
			c.st.n -= 1
			j_deopt_if(c, pc)
			c.st.n += 1
		}
		j_lget(c, P_FRAME)
		j_mem(c, W_I64_LOAD, 3, FRAME_THIS + 8)
		j_lset(c, c.sl0 + u32(d))
		c.st.v[d] = f.this_val
	case .get_length:
		if c.st.t[n - 1] != .O {
			return jit_get_field(c, op, pa(.A_length), pc)
		}
		ord := int(c.st.a[n - 1])
		// a length above 2^31 - 1 is not an int
		j_lget(c, c.a0 + 3 * u32(ord) + 2)
		j_i32(c, 0)
		j_op(c, W_I32_LT_S)
		j_deopt_if(c, pc)
		c.st.n -= 1
		d := j_push(c, .I)
		j_lget(c, c.a0 + 3 * u32(ord) + 2)
		j_lset(c, j_si(c, d))
	case .dup2:
		for k in 0 ..< 2 {
			src := n - 2 + k
			t := c.st.t[src]
			d := j_push(c, t)
			c.st.a[d] = c.st.a[src]
			c.st.v[d] = c.st.v[src]
			c.st.k[d] = c.st.k[src]
			j_copy(c, src, d, t)
		}
	case .get_loc0_loc1:
		for k in 0 ..< 2 {
			if !j_slot_read(c, f, op, c.nargs + k, pc) {return false}
		}
	case .push_minus1, .push_0, .push_1, .push_2, .push_3, .push_4, .push_5, .push_6, .push_7:
		d := j_push(c, .I)
		j_i32(c, i32(op) - i32(Opcode.push_0))
		j_lset(c, j_si(c, d))
		c.st.v[d] = mk_int(i32(op) - i32(Opcode.push_0))
	case .push_i8:
		d := j_push(c, .I)
		j_i32(c, i32(i8(code[pc + 1])))
		j_lset(c, j_si(c, d))
		c.st.v[d] = mk_int(i32(i8(code[pc + 1])))
	case .push_i16:
		d := j_push(c, .I)
		j_i32(c, i32(i16(u16(jr_u16(code, pc + 1)))))
		j_lset(c, j_si(c, d))
		c.st.v[d] = mk_int(i32(i16(u16(jr_u16(code, pc + 1)))))
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
			c.st.v[d] = v
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
		c.st.a[d] = c.st.a[n - 1]
		c.st.v[d] = c.st.v[n - 1]
		c.st.k[d] = c.st.k[n - 1]
		j_copy(c, n - 1, d, t)
	// stack shuffles: the top entries become copies of some of the old ones (QuickJS's names: bottom to top)
	case .nip: j_permute(c, n - 2, {1})
	case .swap: j_permute(c, n - 2, {1, 0})
	case .dup1: j_permute(c, n - 2, {0, 0, 1})
	case .insert2: j_permute(c, n - 2, {1, 0, 1})
	case .insert3: j_permute(c, n - 3, {2, 0, 1, 2})
	case .insert4: j_permute(c, n - 4, {3, 0, 1, 2, 3})
	case .rot3l: j_permute(c, n - 3, {1, 2, 0})
	case .rot3r: j_permute(c, n - 3, {2, 0, 1})
	case .perm3: j_permute(c, n - 3, {1, 0, 2})
	case .check_object:
		if c.st.t[n - 1] != .O && c.st.t[n - 1] != .P {
			j_fail(c, "check_object of something that is not an object")
			return false
		}
	case .to_propkey, .to_propkey2:
		// an int key stays as it is (other keys become strings)
		if c.st.t[n - 1] != .I && c.st.t[n - 1] != .L {
			j_fail(c, "property key that is not an int")
			return false
		}
	case .add, .sub, .mul, .div, .mod, .shl, .sar, .shr, .op_and, .op_or, .xor:
		// (an add of values or of objects: j_add_values, which refuses objects; the other operations take numbers only)
		ta, tb := c.st.t[n - 2], c.st.t[n - 1]
		if op == .add && ((!j_is_num(ta) && ta != .B) || (!j_is_num(tb) && tb != .B)) {return j_add_values(c, pc)}
		sa, sb := c.st.v[n - 2], c.st.v[n - 1]
		arith := op == .add || op == .sub || op == .mul || op == .div || op == .mod
		ok := arith ? jit_arith(c, op, pc) : jit_bitwise(c, op, pc)
		if ok && !c.fail {c.st.v[c.st.n - 1] = jit_shadow_op(op, sa, sb)}
		return ok
	case .lt, .lte, .gt, .gte, .eq, .neq, .strict_eq, .strict_neq:
		for d in n - 2 ..< n {
			t := c.st.t[d]
			if t == .O || t == .P || t == .V {
				if op == .eq || op == .neq {return jit_loose_eq_ref(c, op, pc)}
				if op != .strict_eq && op != .strict_neq {
					j_fail(c, "comparison of an object")
					return false
				}
				return jit_strict_eq_ref(c, op, pc)
			}
		}
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
		j_get_bool(c, n - 1, pc)
		j_op(c, W_I32_EQZ)
		c.st.n -= 1
		d := j_push(c, .B)
		j_lset(c, j_si(c, d))
	case .is_undefined, .is_null, .is_undefined_or_null, .typeof_is_undefined, .typeof_is_function:
		t := c.st.t[n - 1]
		if (t == .P || t == .V) && op == .typeof_is_function {
			j_fail(c, "typeof of an object")
			return false
		}
		if t == .V {
			tag := j_si(c, n - 1)
			if op == .typeof_is_undefined {
				// (document.all is an object whose typeof is "undefined")
				j_lget(c, tag)
				j_i32(c, i32(Tag.object))
				j_op(c, W_I32_EQ)
				j_deopt_if(c, pc)
			}
			j_lget(c, tag)
			j_i32(c, i32(op == .is_null ? Tag.null : Tag.undefined))
			j_op(c, op == .is_undefined_or_null ? W_I32_LE_U : W_I32_EQ)
		} else if t == .P && op == .typeof_is_undefined {
			j_obj_truthy(c, j_si(c, n - 1))
			j_op(c, W_I32_EQZ)
		} else {
			// a number, a bool or an object is none of these
			j_i32(c, 0)
		}
		c.st.n -= 1
		d := j_push(c, .B)
		j_lset(c, j_si(c, d))
	case .op_return:
		j_return(c, n - 1)
		return false
	case .call0, .call1, .call2, .call3:
		return jit_call_insn(c, f, op, int(op) - int(Opcode.call0), .call, pc)
	case .call, .tail_call:
		return jit_call_insn(c, f, op, jr_u16(code, pc + 1), .call, pc)
	case .call_method, .tail_call_method:
		return jit_call_insn(c, f, op, jr_u16(code, pc + 1), .method, pc)
	case .call_constructor:
		return jit_call_insn(c, f, op, jr_u16(code, pc + 1), .construct, pc)
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
		j_get_bool(c, n - 1, pc)
		if cond == 2 {j_op(c, W_I32_EQZ)}
		c.st.n -= 1
		return j_jump(c, pc, target, true)
	case:
		j_fail(c, reflect.enum_string(op))
		return false
	}
	return true
}

// The V entry d taken as a number: an int, or a double (an int converted) once the site of pc saw one; a value of
// another type is a learn exit (the interpreter runs the instruction).
@(private = "file")
j_unbox_num :: proc(c: ^Jc, d: int, pc: int) -> bool {
	site := jit_site_of(c.jl, c.site_base + pc, true)
	if site == nil {
		j_fail(c, "too many sites")
		return false
	}
	want := site.typed ? site.ty : Jit_Ty.I
	if c.inl_wide && want == .I {want = .F}
	if want != .I && want != .F {
		j_fail(c, "a value that is not a number taken as one")
		return false
	}
	tag := j_si(c, d)
	j_lget(c, tag)
	j_i32(c, i32(Tag.int))
	j_op(c, W_I32_NE)
	if want == .F {
		j_lget(c, tag)
		j_i32(c, i32(Tag.float))
		j_op(c, W_I32_NE)
		j_op(c, W_I32_AND)
	}
	j_deopt_if(c, pc, JIT_AUX_LEARN)
	if want == .I {
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I32_WRAP_I64)
		j_lset(c, tag)
	} else {
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_F64_REINTERPRET_I64)
		j_lget(c, c.sl0 + u32(d))
		j_op(c, W_I32_WRAP_I64)
		j_op(c, W_F64_CONVERT_I32_S)
		j_lget(c, tag)
		j_i32(c, i32(Tag.float))
		j_op(c, W_I32_EQ)
		j_op(c, W_SELECT)
		j_lset(c, j_sf(c, d))
	}
	c.st.t[d] = want
	return true
}

// The operands an instruction takes as numbers, unboxed when they are V entries.
@(private = "file")
j_unbox_operands :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	n := c.st.n
	lo, hi := 0, 0   // the entries [n - lo, n - hi)
	#partial switch op {
	case .add, .sub, .mul, .div, .mod, .shl, .sar, .shr, .op_and, .op_or, .xor, .lt, .lte, .gt, .gte:
		lo, hi = 2, 0
		if op == .add {
			// (a site that saw a string adds values: j_add_values)
			if site := jit_site_of(c.jl, c.site_base + pc, false); site != nil && site.typed && site.ty == .V {return true}
		}
	case .eq, .neq, .strict_eq, .strict_neq:
		// a value compared with a number (two values are compared as values)
		ta, tb := c.st.t[n - 2], c.st.t[n - 1]
		if ta == .V && j_is_num(tb) {lo, hi = 2, 1} else if tb == .V && j_is_num(ta) {lo, hi = 1, 0}
	case .neg, .plus, .inc, .dec, .post_inc, .post_dec, .op_not, .get_array_el, .get_array_el2, .to_propkey, .to_propkey2:
		lo, hi = 1, 0
	case .add_loc:
		// (a local in the frame's memory adds values: j_slot_insn)
		if s := c.nargs + int(c.code[pc + 1]); c.inl_depth > 0 || s >= c.nslots || c.skind[s] != .box {lo, hi = 1, 0}
	case .put_array_el:
		lo, hi = 2, 1
	}
	for d in n - lo ..< n - hi {
		if c.st.t[d] == .V && !j_unbox_num(c, d, pc) {return false}
	}
	return true
}
// The function returns the entry d (its value in the frame's stack[0]).
@(private = "file")
j_return :: proc(c: ^Jc, d: int) {
	j_store_entry(c, d, P_STACK, 0, true, true)
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
}
// The entries from `base` up become copies of old entries (src: indices from base); the old ones are read before any is
// written (through free stack depths above the current top).
@(private = "file")
j_permute :: proc(c: ^Jc, base: int, src: []int) {
	n := c.st.n
	m := len(src)
	if base < 0 || n + m > c.ss || base + m > c.ss {
		j_fail(c, "stack shuffle too deep")
		return
	}
	old := c.st
	for j in 0 ..< m {
		from := base + src[j]
		j_copy(c, from, n + j, old.t[from])
	}
	for j in 0 ..< m {
		from := base + src[j]
		t := old.t[from]
		j_copy(c, n + j, base + j, t)
		c.st.t[base + j] = t
		c.st.a[base + j] = old.a[from]
		c.st.v[base + j] = old.v[from]
		c.st.k[base + j] = old.k[from]
	}
	c.st.n = base + m
}

// A read of local or argument s, pushed.
@(private = "file")
j_slot_read :: proc(c: ^Jc, f: ^Frame, op: Opcode, s: int, pc: int) -> bool {
	#partial switch c.skind[s] {
	case .i32:
		d := j_push(c, .I)
		j_lget(c, c.wl[s])
		j_lset(c, j_si(c, d))
		c.st.v[d] = jit_slot_value(f, s)
	case .f64:
		d := j_push(c, .F)
		j_lget(c, c.wl[s])
		j_lset(c, j_sf(c, d))
		c.st.v[d] = jit_slot_value(f, s)
	case .arr:
		d := j_push(c, .O)
		c.st.a[d] = u16(c.arr_ord[s])
		c.st.v[d] = jit_slot_value(f, s)
	case .obj:
		d := j_push(c, .P)
		j_lget(c, c.wl[s])
		j_lset(c, j_si(c, d))
		c.st.v[d] = jit_slot_value(f, s)
	case .box:
		// the frame's memory: any value (a hole of the TDZ is the interpreter's to throw)
		base, off := j_slot_addr(c, s)
		d := j_push(c, .V)
		j_lget(c, base)
		j_mem(c, W_I32_LOAD8_U, 0, off)
		j_lset(c, j_si(c, d))
		if op == .get_loc_check {
			c.st.n -= 1
			j_lget(c, j_si(c, d))
			j_i32(c, i32(Tag.uninitialized))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
			c.st.n += 1
		}
		j_lget(c, base)
		j_mem(c, W_I64_LOAD, 3, off + 8)
		j_lset(c, c.sl0 + u32(d))
		c.st.v[d] = jit_slot_value(f, s)
	case:
		j_fail(c, "read of a local the loop does not hold")
		return false
	}
	return true
}

// locals and arguments
@(private = "file")
jit_slot_insn :: proc(c: ^Jc, f: ^Frame, op: Opcode, pc: int, s: int, write: bool) -> bool {
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
		if !j_is_num(tv) && kind != .box {
			j_fail(c, "add_loc of something that is not a number")
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
		case .box:
			// (a value, in the frame's memory: added there by the helper, `s += x` of a string)
			if c.inl_depth > 0 {
				j_fail(c, "add_loc in a callee being inlined")
				return false
			}
			j_store_entry(c, n - 1, P_STACK, u32((n - 1) * size_of(Value)), true, true)
			j_lget(c, P_FRAME)
			j_i32(c, i32(n))
			j_i32(c, i32(s))
			j_helper(c, .add)
			j_op(c, W_I32_EQZ)
			j_deopt_if(c, pc)
		case:
			j_fail(c, "add_loc to a local the loop does not hold")
			return false
		}
		c.st.n -= 1
		return true
	}
	if !write {return j_slot_read(c, f, op, s, pc)}
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
		} else if tv == .B {
			j_fail(c, "bool stored in an int local")
			return false
		} else {
			j_box(c, s)
			return false
		}
	case .f64:
		if !j_is_num(tv) {
			j_fail(c, "something that is not a number stored in a double local")
			return false
		}
		j_get_f(c, n - 1)
		j_lset(c, c.wl[s])
	case .obj:
		if tv != .P {
			j_box(c, s)
			return false
		}
		j_lget(c, j_si(c, n - 1))
		j_lset(c, c.wl[s])
	case .box:
		base, off := j_slot_addr(c, s)
		if op == .put_loc_check {
			// (a hole of the TDZ: the interpreter throws)
			j_lget(c, base)
			j_mem(c, W_I32_LOAD8_U, 0, off)
			j_i32(c, i32(Tag.uninitialized))
			j_op(c, W_I32_EQ)
			j_deopt_if(c, pc)
		}
		if tv == .L {
			j_l_not_i32(c, n - 1)
			j_deopt_if(c, pc)
		}
		j_store_entry(c, n - 1, base, off)
	case:
		j_fail(c, "store to an unknown local")
		return false
	}
	if !keep {c.st.n -= 1}
	return true
}

// the loop stores something else than an object into a local that held one: the local is left to the frame's memory
// and the loop translated again
@(private = "file")
j_box :: proc(c: ^Jc, s: int) {
	bit := u64(1) << uint(s)
	if s >= 64 || c.jl.boxed & bit != 0 {
		j_fail(c, "a value of another type stored in a local")
		return
	}
	c.jl.boxed |= bit
	c.restart = true
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

// What an operation of two ints the translation sees gives (for the hints of the reads that follow: an index, a key).
@(private = "file")
jit_shadow_op :: proc(op: Opcode, a: Value, b: Value) -> Value {
	if a.tag != .int || b.tag != .int {return EXCEPTION}
	x, y := a.u.i, b.u.i
	#partial switch op {
	case .add: return mk_i64(i64(x) + i64(y))
	case .sub: return mk_i64(i64(x) - i64(y))
	case .mul: return mk_i64(i64(x) * i64(y))
	case .op_and: return mk_int(x & y)
	case .op_or: return mk_int(x | y)
	case .xor: return mk_int(x ~ y)
	case .shl: return mk_int(x << (u32(y) & 31))
	case .sar: return mk_int(x >> (u32(y) & 31))
	}
	return EXCEPTION
}
// add of values (a site that saw a string): the two entries written to the frame and added by the helper (jit_add),
// the result a V; when it does not make it, the interpreter does (a deopt: nothing was done).
@(private = "file")
j_add_values :: proc(c: ^Jc, pc: int) -> bool {
	n := c.st.n
	if c.inl_depth > 0 {
		// (a callee's entries are beyond the frame's operand stack: none of them goes to its memory)
		j_fail(c, "values added in a callee being inlined")
		return false
	}
	for d in n - 2 ..< n {
		if t := c.st.t[d]; t == .O || t == .P || t == .M {
			j_fail(c, "an object added")
			return false
		}
		j_store_entry(c, d, P_STACK, u32(d * size_of(Value)), true, true)
	}
	j_lget(c, P_FRAME)
	j_i32(c, i32(n))
	j_i32(c, -1)
	j_helper(c, .add)
	j_op(c, W_I32_EQZ)
	j_deopt_if(c, pc)
	c.st.n -= 2
	d := j_push(c, .V)
	off := u32(d * size_of(Value))
	j_lget(c, P_STACK)
	j_mem(c, W_I32_LOAD8_U, 0, off)
	j_lset(c, j_si(c, d))
	j_lget(c, P_STACK)
	j_mem(c, W_I64_LOAD, 3, off + 8)
	j_lset(c, c.sl0 + u32(d))
	return true
}

@(private = "file")
jit_arith :: proc(c: ^Jc, op: Opcode, pc: int) -> bool {
	n := c.st.n
	a, b := n - 2, n - 1
	ta, tb := c.st.t[a], c.st.t[b]
	// a bool is the number 0 or 1 here
	if ta == .B {ta = .I}
	if tb == .B {tb = .I}
	if ta != .F && tb != .F && op != .div && (op != .mul || (ta == .I && tb == .I)) {
		if op == .mod {
			// (an exact integer beyond the int32 range: the interpreter's double)
			for d in ([]int{a, b}) {
				if c.st.t[d] != .L {continue}
				j_l_not_i32(c, d)
				j_deopt_if(c, pc)
				j_lget(c, c.sl0 + u32(d))
				j_op(c, W_I32_WRAP_I64)
				j_lset(c, j_si(c, d))
				c.st.t[d] = .I
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
	if (ta == .B || tb == .B) && equality {
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
