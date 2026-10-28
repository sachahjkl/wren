package jsrt

// The interpreter call frame.
//
// A Call_Frame holds everything the bytecode of one function activation needs: the argument and local
// variable slots, the operand (value) stack, the captured closure upvalues, and the program counter.
// Frames are heap-allocated (not on the Odin native stack) so generators and async functions can
// suspend a frame and resume it later, and so the engine's own stack-depth budget — not the host C
// stack — bounds recursion.
//
// Layout of `locals`: [ arguments (arg_count) | declared vars/lexicals (var_count) ]. The operand
// stack grows above that in `stack`, bounded by bc.stack_size.

Call_Frame :: struct {
	bc:          ^Function_Bytecode,
	func_obj:    Value, // the function being run (for home object, new.target wiring)
	this_val:    Value,
	new_target:  Value,
	realm:       ^Realm,

	locals:      []Value,   // arg_count + var_count slots
	stack:       []Value,   // operand stack storage
	sp:          int,       // operand stack pointer (index of the next free slot)
	pc:          int,       // program counter into bc.byte_code

	var_refs:    []^Var_Ref, // closure upvalues for this activation
	// Open var-refs created for this frame's locals (closed when the frame unwinds).
	open_refs:   [dynamic]^Var_Ref,

	parent:      ^Call_Frame, // caller, for backtraces
}

frame_alloc :: proc(rt: ^Runtime, bc: ^Function_Bytecode) -> ^Call_Frame {
	f := new(Call_Frame, rt.allocator)
	n_locals := int(bc.arg_count + bc.var_count)
	f.bc = function_bc_ref(bc)
	f.locals = make([]Value, n_locals, rt.allocator)
	for i in 0 ..< n_locals {f.locals[i] = UNINITIALIZED}
	f.stack = make([]Value, int(bc.stack_size) + 4, rt.allocator)
	f.open_refs = make([dynamic]^Var_Ref, rt.allocator)
	f.this_val = UNDEFINED
	f.new_target = UNDEFINED
	return f
}

frame_free :: proc(rt: ^Runtime, f: ^Call_Frame) {
	// Close any still-open upvalues so their values survive the frame, then drop the frame's own
	// references.
	for vr in f.open_refs {
		var_ref_close(vr)
		var_ref_unref(rt, vr)
	}
	delete(f.open_refs)
	for v in f.locals {value_free(rt, v)}
	delete(f.locals, rt.allocator)
	// Any values left on the operand stack (exception unwinding) are freed here.
	for i in 0 ..< f.sp {value_free(rt, f.stack[i])}
	delete(f.stack, rt.allocator)
	value_free(rt, f.this_val)
	value_free(rt, f.new_target)
	value_free(rt, f.func_obj)
	if f.var_refs != nil {
		for vr in f.var_refs {
			if vr != nil {var_ref_unref(rt, vr)}
		}
		delete(f.var_refs, rt.allocator)
	}
	if f.bc != nil {function_bc_unref(rt, f.bc)}
	free(f, rt.allocator)
}

// --- operand stack helpers ---

push :: #force_inline proc(f: ^Call_Frame, v: Value) {
	f.stack[f.sp] = v
	f.sp += 1
}

pop :: #force_inline proc(f: ^Call_Frame) -> Value {
	f.sp -= 1
	return f.stack[f.sp]
}

peek :: #force_inline proc(f: ^Call_Frame, back := 0) -> Value {
	return f.stack[f.sp - 1 - back]
}
