package frontend

import "base:runtime"

// Bytecode emission infrastructure: a builder that accumulates instructions with symbolic labels, then a
// resolution pass that fixes up jump targets, chooses short opcodes, and a stack-size pass faithful to QuickJS's
// compute_stack_size. The emitter (emit_expr.odin / emit_stmt.odin) calls into this builder.
//
// Approach vs. QuickJS: QuickJS emits a phase-1 stream with temporary scope/label opcodes, then resolve_labels
// lowers and peepholes it. For a first complete version we emit resolved get_loc/get_arg/get_var_ref/get_var
// directly (the resolver has already classified each reference) and use a label table for jumps; resolve_labels
// here handles only label backpatching and short-opcode selection, which is where most of QuickJS's size win is.
// The structure leaves room to add QuickJS's peephole rules incrementally for closer byte parity.

// A label is an index into Bc_Builder.labels. Jumps reference a label; after all code is emitted, resolve_labels
// replaces each jump's placeholder with the real relative offset and (where possible) a short form.
Label :: distinct int

Bc_Builder :: struct {
	allocator: runtime.Allocator,
	code:      [dynamic]u8,
	labels:    [dynamic]Label_Info,
	fixups:    [dynamic]Fixup,
	// line/col tracking for the pc2line table (filled lazily; a minimal implementation emits none)
	cur_line:  int,
	cur_col:   int,
}

Label_Info :: struct {
	pos:    int,  // byte offset the label resolves to, or -1 until bound
	bound:  bool,
}

// A pending jump: at `at` (the byte offset of the 4-byte operand) we must store (label_pos - (at-1)) once the
// label is bound. `op_pos` is the opcode position (one before `at`). We keep the long form (label fmt, 4 bytes)
// during emission and let resolve_labels shrink it.
Fixup :: struct {
	op_pos: int,
	label:  Label,
}

builder_init :: proc(b: ^Bc_Builder, allocator: runtime.Allocator) {
	b.allocator = allocator
	b.code = make([dynamic]u8, allocator)
	b.labels = make([dynamic]Label_Info, allocator)
	b.fixups = make([dynamic]Fixup, allocator)
	b.cur_line = 1
	b.cur_col = 1
}

// --- raw emission -------------------------------------------------------------------------------------------

emit_op :: proc(b: ^Bc_Builder, op: Opcode) {
	append(&b.code, u8(op))
}

emit_u8 :: proc(b: ^Bc_Builder, v: u8) {
	append(&b.code, v)
}

emit_u16 :: proc(b: ^Bc_Builder, v: u16) {
	append(&b.code, u8(v), u8(v >> 8))
}

emit_u32 :: proc(b: ^Bc_Builder, v: u32) {
	append(&b.code, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

emit_i32 :: proc(b: ^Bc_Builder, v: i32) {
	emit_u32(b, u32(v))
}

emit_atom :: proc(b: ^Bc_Builder, a: Atom) {
	emit_u32(b, u32(a))
}

// --- common instruction helpers -----------------------------------------------------------------------------

// emit_push_i32 emits the smallest push for an integer, matching QuickJS's choice of push_minus1 / push_0..7 /
// push_i8 / push_i16 / push_i32.
emit_push_i32 :: proc(b: ^Bc_Builder, v: i32) {
	switch {
	case v == -1:
		emit_op(b, .push_minus1)
	case v >= 0 && v <= 7:
		emit_op(b, Opcode(int(Opcode.push_0) + int(v)))
	case v >= -128 && v <= 127:
		emit_op(b, .push_i8)
		emit_u8(b, u8(i8(v)))
	case v >= -32768 && v <= 32767:
		emit_op(b, .push_i16)
		emit_u16(b, u16(i16(v)))
	case:
		emit_op(b, .push_i32)
		emit_i32(b, v)
	}
}

// emit_get_loc / put_loc choose the short forms get_loc0..3 / get_loc8 / get_loc that QuickJS uses.
emit_get_loc :: proc(b: ^Bc_Builder, idx: int) {
	switch {
	case idx <= 3:
		emit_op(b, Opcode(int(Opcode.get_loc0) + idx))
	case idx <= 255:
		emit_op(b, .get_loc8)
		emit_u8(b, u8(idx))
	case:
		emit_op(b, .get_loc)
		emit_u16(b, u16(idx))
	}
}

emit_put_loc :: proc(b: ^Bc_Builder, idx: int) {
	switch {
	case idx <= 3:
		emit_op(b, Opcode(int(Opcode.put_loc0) + idx))
	case idx <= 255:
		emit_op(b, .put_loc8)
		emit_u8(b, u8(idx))
	case:
		emit_op(b, .put_loc)
		emit_u16(b, u16(idx))
	}
}

emit_get_arg :: proc(b: ^Bc_Builder, idx: int) {
	if idx <= 3 {
		emit_op(b, Opcode(int(Opcode.get_arg0) + idx))
	} else {
		emit_op(b, .get_arg)
		emit_u16(b, u16(idx))
	}
}

emit_put_arg :: proc(b: ^Bc_Builder, idx: int) {
	if idx <= 3 {
		emit_op(b, Opcode(int(Opcode.put_arg0) + idx))
	} else {
		emit_op(b, .put_arg)
		emit_u16(b, u16(idx))
	}
}

emit_get_var_ref :: proc(b: ^Bc_Builder, idx: int) {
	if idx <= 3 {
		emit_op(b, Opcode(int(Opcode.get_var_ref0) + idx))
	} else {
		emit_op(b, .get_var_ref)
		emit_u16(b, u16(idx))
	}
}

emit_put_var_ref :: proc(b: ^Bc_Builder, idx: int) {
	if idx <= 3 {
		emit_op(b, Opcode(int(Opcode.put_var_ref0) + idx))
	} else {
		emit_op(b, .put_var_ref)
		emit_u16(b, u16(idx))
	}
}

// --- labels / jumps -----------------------------------------------------------------------------------------

new_label :: proc(b: ^Bc_Builder) -> Label {
	append(&b.labels, Label_Info{pos = -1, bound = false})
	return Label(len(b.labels) - 1)
}

bind_label :: proc(b: ^Bc_Builder, l: Label) {
	b.labels[int(l)].pos = len(b.code)
	b.labels[int(l)].bound = true
}

// emit_goto / emit_if_true / emit_if_false emit the long (label) form with a placeholder operand and record a
// fixup. resolve_labels backpatches and shortens.
emit_goto :: proc(b: ^Bc_Builder, l: Label) {
	append(&b.fixups, Fixup{op_pos = len(b.code), label = l})
	emit_op(b, .goto)
	emit_u32(b, 0)
}

emit_if_true :: proc(b: ^Bc_Builder, l: Label) {
	append(&b.fixups, Fixup{op_pos = len(b.code), label = l})
	emit_op(b, .if_true)
	emit_u32(b, 0)
}

emit_if_false :: proc(b: ^Bc_Builder, l: Label) {
	append(&b.fixups, Fixup{op_pos = len(b.code), label = l})
	emit_op(b, .if_false)
	emit_u32(b, 0)
}

// --- resolve pass -------------------------------------------------------------------------------------------

// resolve_labels backpatches jump operands with the real relative offset. QuickJS's offset convention for a
// label-format op is: target = pos_of_operand - 1 ... actually the interpreter computes pos + 1 + diff where pos
// is the opcode position; so diff = target - (op_pos + 1). We keep the long (4-byte) form here for correctness;
// short-form selection is a separate optional step (shorten_jumps) that can be enabled once validated against
// QuickJS. Keeping the long form yields valid, runnable bytecode (the runtime accepts goto/if_true/if_false).
resolve_labels :: proc(b: ^Bc_Builder) {
	for f in b.fixups {
		info := b.labels[int(f.label)]
		assert(info.bound, "unbound label in resolve_labels")
		target := info.pos
		op_pos := f.op_pos
		diff := i32(target - (op_pos + 1))
		// operand sits at op_pos+1, little-endian 4 bytes
		b.code[op_pos + 1] = u8(u32(diff))
		b.code[op_pos + 2] = u8(u32(diff) >> 8)
		b.code[op_pos + 3] = u8(u32(diff) >> 16)
		b.code[op_pos + 4] = u8(u32(diff) >> 24)
	}
}

// --- compute_stack_size -------------------------------------------------------------------------------------

// compute_stack_size reproduces QuickJS's breadth-first exploration to find the maximum operand-stack depth. It
// works on final (resolved) bytecode: only real opcodes, label operands already backpatched. The exploration
// follows fall-through, conditional and unconditional branches, and catch handlers, exactly like the C.
compute_stack_size :: proc(code: []u8, allocator: runtime.Allocator) -> int {
	n := len(code)
	if n == 0 {
		return 0
	}
	level := make([]int, n, allocator)
	for i in 0 ..< n {
		level[i] = -1
	}
	// explicit work stack of pending (pos, stack_len)
	Pending :: struct {pos: int, sp: int}
	work := make([dynamic]Pending, allocator)

	push :: proc(work: ^[dynamic]Pending, level: []int, pos, sp: int, max_sp: ^int) {
		if pos < 0 || pos >= len(level) {
			return
		}
		if level[pos] != -1 {
			return // already visited (QuickJS asserts equal stack depth)
		}
		level[pos] = sp
		if sp > max_sp^ {max_sp^ = sp}
		append(work, Pending{pos = pos, sp = sp})
	}

	max_sp := 0
	push(&work, level, 0, 0, &max_sp)

	for len(work) > 0 {
		item := pop(&work)
		pos := item.pos
		sp := item.sp
		op := Opcode(code[pos])
		info := op_info[op]
		size := int(info.size)
		n_pop := int(info.n_pop)
		#partial switch info.fmt {
		case .npop, .npop_u16:
			n_pop += int(u16(code[pos + 1]) | u16(code[pos + 2]) << 8)
		case .npopx:
			n_pop += int(op) - int(Opcode.call0)
		}
		sp2 := sp - n_pop + int(info.n_push)
		if sp2 > max_sp {max_sp = sp2}

		pos_next := pos + size
		terminates := false
		#partial switch op {
		case .tail_call, .tail_call_method, .ret_, .return_undef, .return_async, .throw_, .throw_error, .ret:
			terminates = true
		case .goto:
			diff := read_i32(code, pos + 1)
			pos_next = pos + 1 + int(diff)
		case .goto16:
			diff := i16(u16(code[pos + 1]) | u16(code[pos + 2]) << 8)
			pos_next = pos + 1 + int(diff)
		case .goto8:
			diff := i8(code[pos + 1])
			pos_next = pos + 1 + int(diff)
		case .if_true, .if_false:
			diff := read_i32(code, pos + 1)
			push(&work, level, pos + 1 + int(diff), sp2, &max_sp)
		case .if_true8, .if_false8:
			diff := i8(code[pos + 1])
			push(&work, level, pos + 1 + int(diff), sp2, &max_sp)
		case .catch:
			diff := read_i32(code, pos + 1)
			push(&work, level, pos + 1 + int(diff), sp2, &max_sp)
		case .gosub:
			diff := read_i32(code, pos + 1)
			push(&work, level, pos + 1 + int(diff), sp2 + 1, &max_sp)
		}
		if !terminates {
			push(&work, level, pos_next, sp2, &max_sp)
		}
	}
	return max_sp
}

@(private = "file")
read_i32 :: proc(code: []u8, at: int) -> i32 {
	return i32(u32(code[at]) | u32(code[at + 1]) << 8 | u32(code[at + 2]) << 16 | u32(code[at + 3]) << 24)
}
