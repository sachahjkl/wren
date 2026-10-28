package frontend

import "base:runtime"

// The back half of the compiler, after parsing: resolve_variables (phase 2: scope opcodes to real accesses,
// hoisted definitions, first peepholes), resolve_labels (phase 3: peephole optimizer, short opcodes, jump
// sizing, the pc2line table), compute_stack_size, and js_create_function which runs them over the function tree
// child-first and produces the serializable Function_Bytecode.

// --- code_match ---------------------------------------------------------------------------------------------

Code_Context :: struct {
	bc_buf:   []u8,
	bc_len:   int,
	pos:      int,
	line_num: int,
	col_num:  int,
	op:       int,
	idx:      int,
	label:    int,
	val:      int,
	atom:     Atom,
}

M2 :: #force_inline proc "contextless" (a, b: int) -> int {return a | (b << 8)}
M3 :: #force_inline proc "contextless" (a, b, c: int) -> int {return a | (b << 8) | (c << 16)}
M4 :: #force_inline proc "contextless" (a, b, c, d: int) -> int {return int(u32(a) | u32(b) << 8 | u32(c) << 16 | u32(d) << 24)}

// code_match: match a sequence of opcodes (an entry may combine up to four alternatives with M2..M4), skipping
// source locations; operand slots of -1 capture the operand into the context. Terminated by -1.
code_match :: proc(s: ^Code_Context, pos0: int, pattern: ..int) -> bool {
	tab := s.bc_buf
	pos := pos0
	line_num := -1
	col_num := -1
	pi := 0
	for {
		op1 := pattern[pi]
		pi += 1
		if op1 == -1 {
			s.pos = pos
			s.line_num = line_num
			s.col_num = col_num
			return true
		}
		op: int
		for {
			if pos >= s.bc_len {return false}
			op = int(tab[pos])
			l := int(opcode_info_of(op).size)
			pos_next := pos + l
			if pos_next > s.bc_len {return false}
			if op == OP_source_loc {
				line_num = int(get_u32(tab, pos + 1))
				col_num = int(get_u32(tab, pos + 5))
				pos = pos_next
			} else {
				break
			}
		}
		pos_next := pos + int(opcode_info_of(op).size)
		u1 := u32(op1)
		if op != op1 {
			if u1 == u32(u8(u1)) || op == 0 {return false}
			if op != int(u8(u1)) && op != int(u8(u1 >> 8)) && op != int(u8(u1 >> 16)) && op != int(u8(u1 >> 24)) {
				return false
			}
			s.op = op
		}
		p := pos + 1
		#partial switch opcode_info_of(op).fmt {
		case .loc8, .u8:
			idx := int(tab[p])
			arg := pattern[pi]
			pi += 1
			if arg == -1 {
				s.idx = idx
			} else if arg != idx {
				return false
			}
		case .u16, .npop, .loc, .arg, .var_ref:
			idx := int(get_u16(tab, p))
			arg := pattern[pi]
			pi += 1
			if arg == -1 {
				s.idx = idx
			} else if arg != idx {
				return false
			}
		case .i32, .u32, .label, .const:
			s.label = int(i32(get_u32(tab, p)))
		case .label_u16:
			s.label = int(get_u32(tab, p))
			s.val = int(get_u16(tab, p + 4))
		case .atom:
			s.atom = Atom(get_u32(tab, p))
		case .atom_u8:
			s.atom = Atom(get_u32(tab, p))
			s.val = int(tab[p + 4])
		case .atom_u16:
			s.atom = Atom(get_u32(tab, p))
			s.val = int(get_u16(tab, p + 4))
		case .atom_label_u8:
			s.atom = Atom(get_u32(tab, p))
			s.label = int(get_u32(tab, p + 4))
			s.val = int(tab[p + 8])
		}
		pos = pos_next
	}
}

// --- phase 2: resolve_variables -----------------------------------------------------------------------------

JS_PROP_CONFIGURABLE :: 1 << 0
JS_PROP_WRITABLE :: 1 << 1

instantiate_hoisted_definitions :: proc(s: ^Func_Def, bc: ^Bc_Out) {
	label_next := -1
	for i in 0 ..< len(s.args) {
		vd := &s.args[i]
		if vd.func_pool_idx >= 0 {
			out_u8(bc, O(.fclosure))
			out_u32(bc, u32(vd.func_pool_idx))
			out_u8(bc, O(.put_arg))
			out_u16(bc, i)
		}
	}
	for i in 0 ..< len(s.vars) {
		vd := &s.vars[i]
		if vd.scope_level == 0 && vd.func_pool_idx >= 0 {
			out_u8(bc, O(.fclosure))
			out_u32(bc, u32(vd.func_pool_idx))
			out_u8(bc, O(.put_loc))
			out_u16(bc, i)
		}
	}
	if s.module != nil {
		label_next = new_label_fd(s)
		out_u8(bc, O(.push_this))
		out_u8(bc, O(.if_false))
		out_u32(bc, u32(label_next))
		update_label(s, label_next, 1)
	}
	for &hf in s.global_vars {
		has_closure := 0
		force_init := hf.force_init
		idx := 0
		for ; idx < len(s.closure_var); idx += 1 {
			cv := &s.closure_var[idx]
			if cv.var_name == hf.var_name {
				has_closure = 2
				force_init = false
				break
			}
			if cv.var_name == A__var_ || cv.var_name == A__arg_var_ {
				out_u8(bc, O(.get_var_ref))
				out_u16(bc, idx)
				has_closure = 1
				force_init = true
				break
			}
		}
		if has_closure == 0 {
			flags := 0
			if s.eval_type != .global {flags |= JS_PROP_CONFIGURABLE}
			if hf.cpool_idx >= 0 && !hf.is_lexical {
				out_u8(bc, O(.fclosure))
				out_u32(bc, u32(hf.cpool_idx))
				out_u8(bc, O(.define_func))
				out_u32(bc, u32(hf.var_name))
				out_u8(bc, flags)
				continue
			} else {
				if hf.is_lexical {
					flags |= DEFINE_GLOBAL_LEX_VAR
					if !hf.is_const {flags |= JS_PROP_WRITABLE}
				}
				out_u8(bc, O(.define_var))
				out_u32(bc, u32(hf.var_name))
				out_u8(bc, flags)
			}
		}
		if hf.cpool_idx >= 0 || force_init {
			if hf.cpool_idx >= 0 {
				out_u8(bc, O(.fclosure))
				out_u32(bc, u32(hf.cpool_idx))
				if hf.var_name == A__default_ {
					out_u8(bc, O(.set_name))
					out_u32(bc, u32(A_default))
				}
			} else {
				out_u8(bc, O(.undefined))
			}
			if has_closure == 2 {
				out_u8(bc, O(.put_var_ref))
				out_u16(bc, idx)
			} else if has_closure == 1 {
				out_u8(bc, O(.define_field))
				out_u32(bc, u32(hf.var_name))
				out_u8(bc, O(.drop))
			} else {
				out_u8(bc, O(.put_var))
				out_u32(bc, u32(hf.var_name))
			}
		}
	}
	if s.module != nil {
		out_u8(bc, O(.return_undef))
		out_u8(bc, OP_label)
		out_u32(bc, u32(label_next))
		s.label_slots[label_next].pos2 = len(bc)
	}
	clear(&s.global_vars)
}

skip_dead_code :: proc(s: ^Func_Def, bc_buf: []u8, bc_len: int, pos0: int, linep, colp: ^int) -> int {
	pos := pos0
	for pos < bc_len {
		op := int(bc_buf[pos])
		info := opcode_info_of(op)
		l := int(info.size)
		if op == OP_source_loc {
			linep^ = int(get_u32(bc_buf, pos + 1))
			colp^ = int(get_u32(bc_buf, pos + 5))
		} else if op == OP_label {
			label := int(get_u32(bc_buf, pos + 1))
			if update_label(s, label, 0) > 0 {break}
		} else {
			#partial switch info.fmt {
			case .label, .label_u16:
				label := int(get_u32(bc_buf, pos + 1))
				update_label(s, label, -1)
			case .atom_label_u8, .atom_label_u16:
				label := int(get_u32(bc_buf, pos + 5))
				update_label(s, label, -1)
			}
		}
		pos += l
	}
	return pos
}

get_label_pos :: proc(s: ^Func_Def, label0: int) -> int {
	label := label0
	pos: int
	for _ in 0 ..< 20 {
		pos = s.label_slots[label].pos
		inner: for {
			switch int(s.byte_code[pos]) {
			case OP_source_loc:
				pos += 9
				continue inner
			case OP_label:
				pos += 5
				continue inner
			case O(.goto):
				label = int(get_u32(s.byte_code[:], pos + 1))
				break inner
			case:
				return pos
			}
		}
	}
	return pos
}

Pass_State :: struct {
	atoms:            ^Atom_Table,
	allocator:        runtime.Allocator,
	source_loc_size:  map[^Func_Def]int,
	error:            string,
	stack:            Stack_Guard,
}

@(private = "file")
emit_src_loc :: proc(bc: ^Bc_Out, line, col: int) {
	out_u8(bc, OP_source_loc)
	out_u32(bc, u32(line))
	out_u32(bc, u32(col))
}

resolve_variables :: proc(ps: ^Pass_State, s: ^Func_Def) -> bool {
	bc_buf := s.byte_code[:]
	bc_len := len(bc_buf)
	cc := Code_Context{bc_buf = bc_buf, bc_len = bc_len}
	bc_out := make(Bc_Out, 0, bc_len + 64, ps.allocator)
	source_loc_size := 0

	for &hf in s.global_vars {
		skip := false
		for &cv in s.closure_var {
			if cv.var_name == hf.var_name {
				if s.eval_type == .direct && cv.is_lexical {
					out_u8(&bc_out, O(.throw_error))
					out_u32(&bc_out, u32(hf.var_name))
					out_u8(&bc_out, JS_THROW_VAR_REDECL)
				}
				skip = true
				break
			}
			if cv.var_name == A__var_ || cv.var_name == A__arg_var_ {
				skip = true
				break
			}
		}
		if skip {continue}
		out_u8(&bc_out, O(.check_define_var))
		out_u32(&bc_out, u32(hf.var_name))
		flags := 0
		if hf.is_lexical {flags |= DEFINE_GLOBAL_LEX_VAR}
		if hf.cpool_idx >= 0 {flags |= DEFINE_GLOBAL_FUNC_VAR}
		out_u8(&bc_out, flags)
	}

	line_num, col_num := 0, 0
	pos_next: int
	for pos := 0; pos < bc_len; pos = pos_next {
		op := int(bc_buf[pos])
		l := int(opcode_info_of(op).size)
		pos_next = pos + l
		no_change := false
		switch op {
		case OP_source_loc:
			line_num = int(get_u32(bc_buf, pos + 1))
			col_num = int(get_u32(bc_buf, pos + 5))
			source_loc_size += 1
			no_change = true
		case O(.eval):
			call_argc := int(get_u16(bc_buf, pos + 1))
			scope := int(get_u16(bc_buf, pos + 3))
			mark_eval_captured_variables(s, scope)
			out_u8(&bc_out, op)
			out_u16(&bc_out, call_argc)
			out_u16(&bc_out, s.scopes[scope].first + 1)
		case O(.apply_eval):
			scope := int(get_u16(bc_buf, pos + 1))
			mark_eval_captured_variables(s, scope)
			out_u8(&bc_out, op)
			out_u16(&bc_out, s.scopes[scope].first + 1)
		case OP_scope_get_var_undef, OP_scope_get_var, OP_scope_put_var, OP_scope_delete_var, OP_scope_get_ref, OP_scope_put_var_init:
			var_name := Atom(get_u32(bc_buf, pos + 1))
			scope := int(get_u16(bc_buf, pos + 5))
			pos_next = resolve_scope_var(s, var_name, scope, op, &bc_out, nil, nil, pos_next)
		case OP_scope_make_ref:
			var_name := Atom(get_u32(bc_buf, pos + 1))
			label := int(get_u32(bc_buf, pos + 5))
			scope := int(get_u16(bc_buf, pos + 9))
			ls := &s.label_slots[label]
			ls.ref_count -= 1
			pos_next = resolve_scope_var(s, var_name, scope, op, &bc_out, bc_buf, ls, pos_next)
		case OP_scope_get_private_field, OP_scope_get_private_field2, OP_scope_put_private_field, OP_scope_in_private_field:
			var_name := Atom(get_u32(bc_buf, pos + 1))
			scope := int(get_u16(bc_buf, pos + 5))
			if !resolve_scope_private_field(s, ps.atoms, var_name, scope, op, &bc_out) {
				ps.error = "undefined private field"
				return true
			}
		case O(.gosub):
			label := int(get_u32(bc_buf, pos + 1))
			ls := &s.label_slots[label]
			if code_match(&cc, ls.pos, O(.ret), -1) {
				ls.ref_count -= 1
			} else {
				no_change = true
			}
		case O(.insert3):
			if code_match(&cc, pos_next, M2(O(.put_array_el), O(.put_ref_value)), O(.drop), -1) {
				out_u8(&bc_out, cc.op)
				pos_next = cc.pos
				if cc.line_num != -1 {
					if cc.line_num != line_num || cc.col_num != col_num {
						line_num = cc.line_num
						col_num = cc.col_num
						source_loc_size += 1
						emit_src_loc(&bc_out, line_num, col_num)
					}
				}
			} else {
				no_change = true
			}
		case O(.lnot):
			if code_match(&cc, pos_next, M2(O(.if_false), O(.if_true)), -1) {
				out_u8(&bc_out, cc.op ~ O(.if_false) ~ O(.if_true))
				out_u32(&bc_out, u32(cc.label))
				pos_next = cc.pos
			} else {
				no_change = true
			}
		case O(.goto), O(.tail_call), O(.tail_call_method), O(.ret_), O(.return_undef), O(.throw_), O(.throw_error), O(.ret):
			line := -1
			col := -1
			append(&bc_out, ..bc_buf[pos:pos + l])
			p := skip_dead_code(s, bc_buf, bc_len, pos + l, &line, &col)
			pos_next = p
			if line >= 0 && p < bc_len {
				if line_num != line || col_num != col {
					line_num = line
					col_num = col
					source_loc_size += 1
					emit_src_loc(&bc_out, line_num, col_num)
				}
			}
		case OP_label:
			label := int(get_u32(bc_buf, pos + 1))
			s.label_slots[label].pos2 = len(bc_out) + int(opcode_info_of(op).size)
			no_change = true
		case OP_enter_scope:
			scope := int(get_u16(bc_buf, pos + 1))
			if scope == s.body_scope {
				instantiate_hoisted_definitions(s, &bc_out)
			}
			for scope_idx := s.scopes[scope].first; scope_idx >= 0; {
				vd := &s.vars[scope_idx]
				if vd.scope_level != scope {break}
				if scope_idx != s.arguments_arg_idx {
					if vd.var_kind == .function_decl || vd.var_kind == .new_function_decl {
						out_u8(&bc_out, O(.fclosure))
						out_u32(&bc_out, u32(vd.func_pool_idx))
						out_u8(&bc_out, O(.put_loc))
						out_u16(&bc_out, scope_idx)
					} else {
						out_u8(&bc_out, O(.set_loc_uninitialized))
						out_u16(&bc_out, scope_idx)
					}
				}
				scope_idx = vd.scope_next
			}
		case OP_leave_scope:
			scope := int(get_u16(bc_buf, pos + 1))
			for scope_idx := s.scopes[scope].first; scope_idx >= 0; {
				vd := &s.vars[scope_idx]
				if vd.scope_level != scope {break}
				if vd.is_captured {
					out_u8(&bc_out, O(.close_loc))
					out_u16(&bc_out, scope_idx)
				}
				scope_idx = vd.scope_next
			}
		case OP_dispose_scope:
			scope := int(get_u16(bc_buf, pos + 1))
			is_async := s.scopes[scope].is_await_using
			for scope_idx := s.scopes[scope].first; scope_idx >= 0; {
				vd := &s.vars[scope_idx]
				if vd.scope_level != scope {break}
				if vd.var_kind == .using_ {
					if is_async {
						label_catch := new_label_fd(s)
						label_end := new_label_fd(s)
						out_u8(&bc_out, O(.catch))
						out_u32(&bc_out, u32(label_catch))
						update_label(s, label_catch, 1)
						out_u8(&bc_out, O(.using_dispose_async))
						out_u16(&bc_out, scope_idx)
						out_u8(&bc_out, O(.await))
						out_u8(&bc_out, O(.drop))
						out_u8(&bc_out, O(.drop))
						out_u8(&bc_out, O(.goto))
						out_u32(&bc_out, u32(label_end))
						update_label(s, label_end, 1)
						out_u8(&bc_out, OP_label)
						out_u32(&bc_out, u32(label_catch))
						s.label_slots[label_catch].pos2 = len(bc_out)
						out_u8(&bc_out, O(.using_dispose_merge))
						out_u8(&bc_out, OP_label)
						out_u32(&bc_out, u32(label_end))
						s.label_slots[label_end].pos2 = len(bc_out)
					} else {
						out_u8(&bc_out, O(.using_dispose))
						out_u16(&bc_out, scope_idx)
					}
				}
				scope_idx = vd.scope_next
			}
		case O(.set_name):
			name := Atom(get_u32(bc_buf, pos + 1))
			if name != JS_ATOM_NULL {no_change = true}
		case O(.if_false), O(.if_true), O(.catch):
			no_change = true
		case O(.dup):
			matched := false
			if code_match(&cc, pos_next, M2(O(.if_false), O(.if_true)), O(.drop), -1) {
				lab0 := cc.label
				lab1 := cc.label
				op1 := cc.op
				pos1 := cc.pos
				line1 := cc.line_num
				col1 := cc.col_num
				pos2: int
				for {
					pos2 = get_label_pos(s, lab1)
					if !code_match(&cc, pos2, O(.dup), op1, O(.drop), -1) {break}
					lab1 = cc.label
				}
				if code_match(&cc, pos2, op1, -1) {
					update_label(s, lab0, -1)
					update_label(s, cc.label, +1)
					out_u8(&bc_out, op1)
					out_u32(&bc_out, u32(cc.label))
					pos_next = pos1
					if line1 != -1 {
						if line1 != line_num || col1 != col_num {
							line_num = line1
							col_num = col1
							source_loc_size += 1
							emit_src_loc(&bc_out, line_num, col_num)
						}
					}
					matched = true
				}
			}
			if !matched {no_change = true}
		case O(.nop):
		case OP_set_class_name:
		case OP_get_field_opt_chain:
			name := get_u32(bc_buf, pos + 1)
			out_u8(&bc_out, O(.get_field))
			out_u32(&bc_out, name)
		case OP_get_array_el_opt_chain:
			out_u8(&bc_out, O(.get_array_el))
		case:
			no_change = true
		}
		if no_change {
			append(&bc_out, ..bc_buf[pos:pos + l])
		}
	}
	ps.source_loc_size[s] = source_loc_size
	s.byte_code = bc_out
	return false
}

// --- phase 3: resolve_labels --------------------------------------------------------------------------------

PC2LINE_BASE :: -1
PC2LINE_RANGE :: 5
PC2LINE_OP_FIRST :: 1
PC2LINE_DIFF_PC_MAX :: (255 - PC2LINE_OP_FIRST) / PC2LINE_RANGE

@(private = "file")
Pc2_State :: struct {
	size: int,
}

add_pc2line_info :: proc(s: ^Func_Def, size_limit: int, pc: int, line_num, col_num: int) {
	if size_limit == 0 {return}
	if len(s.source_loc_slots) >= size_limit {return}
	if pc < s.line_number_last_pc {return}
	if line_num == s.line_number_last && col_num == s.col_number_last {return}
	append(&s.source_loc_slots, Source_Loc_Slot{pc = pc, line_num = line_num, col_num = col_num})
	s.line_number_last_pc = pc
	s.line_number_last = line_num
	s.col_number_last = col_num
}

@(private = "file")
put_leb128 :: proc(b: ^[dynamic]u8, v0: u32) {
	v := v0
	for {
		a := v & 0x7f
		v >>= 7
		if v != 0 {
			append(b, u8(a | 0x80))
		} else {
			append(b, u8(a))
			break
		}
	}
}

@(private = "file")
put_sleb128 :: proc(b: ^[dynamic]u8, v1: int) {
	v := u32(i32(v1))
	put_leb128(b, (2 * v) ~ (0 - (v >> 31)))
}

compute_pc2line_info :: proc(s: ^Func_Def, has_slots: bool) {
	if !has_slots {return}
	last_line_num := s.line_num
	last_col_num := s.col_num
	last_pc := 0
	for sl in s.source_loc_slots {
		pc := sl.pc
		line_num := sl.line_num
		col_num := sl.col_num
		if line_num < 0 {continue}
		diff_pc := pc - last_pc
		if diff_pc < 0 {continue}
		diff_line := line_num - last_line_num
		diff_col := col_num - last_col_num
		if diff_line == 0 && diff_col == 0 {continue}
		if diff_line >= PC2LINE_BASE && diff_line < PC2LINE_BASE + PC2LINE_RANGE && diff_pc <= PC2LINE_DIFF_PC_MAX {
			append(&s.pc2line, u8((diff_line - PC2LINE_BASE) + diff_pc * PC2LINE_RANGE + PC2LINE_OP_FIRST))
		} else {
			append(&s.pc2line, 0)
			put_leb128(&s.pc2line, u32(diff_pc))
			put_sleb128(&s.pc2line, diff_line)
		}
		put_sleb128(&s.pc2line, diff_col)
		last_pc = pc
		last_line_num = line_num
		last_col_num = col_num
	}
}

add_reloc :: proc(ls: ^Label_Slot, addr: int, size: int, allocator: runtime.Allocator) {
	re := new(Reloc_Entry, allocator)
	re.addr = addr
	re.size = size
	re.next = ls.first_reloc
	ls.first_reloc = re
}

code_has_label :: proc(s: ^Code_Context, pos0: int, label: int) -> bool {
	pos := pos0
	for pos < s.bc_len {
		op := int(s.bc_buf[pos])
		if op == OP_source_loc {
			pos += 9
			continue
		}
		if op == OP_label {
			lab := int(get_u32(s.bc_buf, pos + 1))
			if lab == label {return true}
			pos += 5
			continue
		}
		if op == O(.goto) {
			lab := int(get_u32(s.bc_buf, pos + 1))
			if lab == label {return true}
		}
		break
	}
	return false
}

find_jump_target :: proc(s: ^Func_Def, label0: int, pop: ^int) -> int {
	label := label0
	op: int
	update_label(s, label, -1)
	outer: for _ in 0 ..< 10 {
		pos := s.label_slots[label].pos2
		for {
			op = int(s.byte_code[pos])
			switch op {
			case OP_source_loc, OP_label:
				pos += int(opcode_info_of(op).size)
				continue
			case O(.goto):
				label = int(get_u32(s.byte_code[:], pos + 1))
				continue outer
			case O(.drop):
				pos += 1
				for int(s.byte_code[pos]) == O(.drop) {pos += 1}
				if int(s.byte_code[pos]) == O(.return_undef) {
					op = O(.return_undef)
				}
				break outer
			case:
				break outer
			}
		}
	}
	pop^ = op
	update_label(s, label, +1)
	return label
}

push_short_int :: proc(bc: ^Bc_Out, val: int) {
	if val >= -1 && val <= 7 {
		out_u8(bc, O(.push_0) + val)
		return
	}
	if val == int(i8(val)) {
		out_u8(bc, O(.push_i8))
		out_u8(bc, val)
		return
	}
	if val == int(i16(val)) {
		out_u8(bc, O(.push_i16))
		out_u16(bc, val)
		return
	}
	out_u8(bc, O(.push_i32))
	out_u32(bc, u32(i32(val)))
}

put_short_code :: proc(bc: ^Bc_Out, op: int, idx: int) {
	if idx < 4 {
		switch op {
		case O(.get_loc): out_u8(bc, O(.get_loc0) + idx); return
		case O(.put_loc): out_u8(bc, O(.put_loc0) + idx); return
		case O(.set_loc): out_u8(bc, O(.set_loc0) + idx); return
		case O(.get_arg): out_u8(bc, O(.get_arg0) + idx); return
		case O(.put_arg): out_u8(bc, O(.put_arg0) + idx); return
		case O(.set_arg): out_u8(bc, O(.set_arg0) + idx); return
		case O(.get_var_ref): out_u8(bc, O(.get_var_ref0) + idx); return
		case O(.put_var_ref): out_u8(bc, O(.put_var_ref0) + idx); return
		case O(.set_var_ref): out_u8(bc, O(.set_var_ref0) + idx); return
		case O(.call): out_u8(bc, O(.call0) + idx); return
		}
	}
	if idx < 256 {
		switch op {
		case O(.get_loc):
			out_u8(bc, O(.get_loc8)); out_u8(bc, idx); return
		case O(.put_loc):
			out_u8(bc, O(.put_loc8)); out_u8(bc, idx); return
		case O(.set_loc):
			out_u8(bc, O(.set_loc8)); out_u8(bc, idx); return
		}
	}
	out_u8(bc, op)
	out_u16(bc, idx)
}

resolve_labels :: proc(ps: ^Pass_State, s: ^Func_Def) -> bool {
	label_slots := s.label_slots[:]
	line_num := s.line_num
	col_num := s.col_num
	bc_buf := s.byte_code[:]
	bc_len := len(bc_buf)
	cc := Code_Context{bc_buf = bc_buf, bc_len = bc_len}
	bc_out := make(Bc_Out, 0, bc_len + 16, ps.allocator)
	sl_size := ps.source_loc_size[s]
	has_slots := sl_size > 0
	clear(&s.jump_slots)
	clear(&s.source_loc_slots)
	if has_slots {
		s.line_number_last = s.line_num
		s.col_number_last = s.col_num
		s.line_number_last_pc = 0
	}
	pc2 :: proc(s: ^Func_Def, n: int, bc: ^Bc_Out, line, col: int) {add_pc2line_info(s, n, len(bc), line, col)}

	if s.home_object_var_idx >= 0 {
		out_u8(&bc_out, O(.special_object))
		out_u8(&bc_out, OP_SPECIAL_OBJECT_HOME_OBJECT)
		put_short_code(&bc_out, O(.put_loc), s.home_object_var_idx)
	}
	if s.this_active_func_var_idx >= 0 {
		out_u8(&bc_out, O(.special_object))
		out_u8(&bc_out, OP_SPECIAL_OBJECT_THIS_FUNC)
		put_short_code(&bc_out, O(.put_loc), s.this_active_func_var_idx)
	}
	if s.new_target_var_idx >= 0 {
		out_u8(&bc_out, O(.special_object))
		out_u8(&bc_out, OP_SPECIAL_OBJECT_NEW_TARGET)
		put_short_code(&bc_out, O(.put_loc), s.new_target_var_idx)
	}
	if s.this_var_idx >= 0 {
		if s.is_derived_class_constructor {
			out_u8(&bc_out, O(.set_loc_uninitialized))
			out_u16(&bc_out, s.this_var_idx)
		} else {
			out_u8(&bc_out, O(.push_this))
			put_short_code(&bc_out, O(.put_loc), s.this_var_idx)
		}
	}
	if s.arguments_var_idx >= 0 {
		if s.is_strict_mode || !s.has_simple_parameter_list {
			out_u8(&bc_out, O(.special_object))
			out_u8(&bc_out, OP_SPECIAL_OBJECT_ARGUMENTS)
		} else {
			for i in 0 ..< len(s.args) {capture_var(s, &s.args[i])}
			out_u8(&bc_out, O(.special_object))
			out_u8(&bc_out, OP_SPECIAL_OBJECT_MAPPED_ARGUMENTS)
		}
		if s.arguments_arg_idx >= 0 {
			put_short_code(&bc_out, O(.set_loc), s.arguments_arg_idx)
		}
		put_short_code(&bc_out, O(.put_loc), s.arguments_var_idx)
	}
	if s.func_var_idx >= 0 {
		out_u8(&bc_out, O(.special_object))
		out_u8(&bc_out, OP_SPECIAL_OBJECT_THIS_FUNC)
		put_short_code(&bc_out, O(.put_loc), s.func_var_idx)
	}
	if s.var_object_idx >= 0 {
		out_u8(&bc_out, O(.special_object))
		out_u8(&bc_out, OP_SPECIAL_OBJECT_VAR_OBJECT)
		put_short_code(&bc_out, O(.put_loc), s.var_object_idx)
	}
	if s.arg_var_object_idx >= 0 {
		out_u8(&bc_out, O(.special_object))
		out_u8(&bc_out, OP_SPECIAL_OBJECT_VAR_OBJECT)
		put_short_code(&bc_out, O(.put_loc), s.arg_var_object_idx)
	}

	pos_next: int
	for pos := 0; pos < bc_len; pos = pos_next {
		op := int(bc_buf[pos])
		l := int(opcode_info_of(op).size)
		pos_next = pos + l
		label := 0
		op1: int
		val: int

		// The C's goto-driven control flow becomes a small state machine: each case sets `next` to say which
		// shared tail (no_change / has_goto / has_label / has_constant_test) to run.
		Next :: enum {done, no_change, has_goto, has_label, has_constant_test}
		next := Next.done

		switch op {
		case OP_source_loc:
			line_num = int(get_u32(bc_buf, pos + 1))
			col_num = int(get_u32(bc_buf, pos + 5))
		case OP_label:
			label = int(get_u32(bc_buf, pos + 1))
			ls := &label_slots[label]
			ls.addr = len(bc_out)
			for re := ls.first_reloc; re != nil; re = re.next {
				diff := ls.addr - re.addr
				switch re.size {
				case 4: put_u32(bc_out[:], re.addr, u32(i32(diff)))
				case 2: put_u16(bc_out[:], re.addr, u16(i16(diff)))
				case 1: bc_out[re.addr] = u8(i8(diff))
				}
			}
			ls.first_reloc = nil
		case O(.call), O(.call_method):
			argc := int(get_u16(bc_buf, pos + 1))
			if code_match(&cc, pos_next, O(.ret_), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				put_short_code(&bc_out, op + 1, argc)
				pos_next = skip_dead_code(s, bc_buf, bc_len, cc.pos, &line_num, &col_num)
			} else {
				pc2(s, sl_size, &bc_out, line_num, col_num)
				put_short_code(&bc_out, op, argc)
			}
		case O(.ret_), O(.return_undef), O(.return_async), O(.throw_), O(.throw_error):
			pos_next = skip_dead_code(s, bc_buf, bc_len, pos_next, &line_num, &col_num)
			next = .no_change
		case O(.goto):
			label = int(get_u32(bc_buf, pos + 1))
			next = .has_goto
		case O(.gosub), O(.catch):
			label = int(get_u32(bc_buf, pos + 1))
			next = .has_label
		case O(.if_true), O(.if_false):
			label = int(get_u32(bc_buf, pos + 1))
			label = find_jump_target(s, label, &op1)
			if code_has_label(&cc, pos_next, label) {
				update_label(s, label, -1)
				out_u8(&bc_out, O(.drop))
				break
			}
			if code_match(&cc, pos_next, O(.goto), -1) {
				pos1 := cc.pos
				line1 := cc.line_num
				col1 := cc.col_num
				if code_has_label(&cc, pos1, label) {
					if line1 >= 0 {line_num = line1}
					if col1 >= 0 {col_num = col1}
					pos_next = pos1
					update_label(s, label, -1)
					label = cc.label
					op ~= O(.if_true) ~ O(.if_false)
				}
			}
			next = .has_label
		case O(.with_get_var), O(.with_put_var), O(.with_delete_var), O(.with_make_ref), O(.with_get_ref), O(.with_get_ref_undef):
			atom := get_u32(bc_buf, pos + 1)
			label = int(get_u32(bc_buf, pos + 5))
			is_with := int(bc_buf[pos + 9])
			label = find_jump_target(s, label, &op1)
			ls := &label_slots[label]
			pc2(s, sl_size, &bc_out, line_num, col_num)
			append(&s.jump_slots, Jump_Slot{op = op, size = 4, pos = len(bc_out) + 5, label = label})
			out_u8(&bc_out, op)
			out_u32(&bc_out, atom)
			out_u32(&bc_out, u32(i32(ls.addr - len(bc_out))))
			if ls.addr == -1 {
				add_reloc(ls, len(bc_out) - 4, 4, ps.allocator)
			}
			out_u8(&bc_out, is_with)
		case O(.drop):
			if code_match(&cc, pos_next, O(.return_undef), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				break
			}
			next = .no_change
		case O(.null), O(.push_false), O(.push_true):
			if op == O(.null) {
				if code_match(&cc, pos_next, O(.strict_eq), -1) {
					if cc.line_num >= 0 {line_num = cc.line_num}
					if cc.col_num >= 0 {col_num = cc.col_num}
					pc2(s, sl_size, &bc_out, line_num, col_num)
					out_u8(&bc_out, O(.is_null))
					pos_next = cc.pos
					break
				}
				if code_match(&cc, pos_next, O(.strict_neq), M2(O(.if_false), O(.if_true)), -1) {
					if cc.line_num >= 0 {line_num = cc.line_num}
					if cc.col_num >= 0 {col_num = cc.col_num}
					pc2(s, sl_size, &bc_out, line_num, col_num)
					out_u8(&bc_out, O(.is_null))
					pos_next = cc.pos
					label = cc.label
					op = cc.op ~ O(.if_false) ~ O(.if_true)
					next = .has_label
					break
				}
			}
			val = op == O(.push_true) ? 1 : 0
			if code_match(&cc, pos_next, M2(O(.if_false), O(.if_true)), -1) {
				next = .has_constant_test
			} else {
				next = .no_change
			}
		case O(.push_i32):
			val = int(i32(get_u32(bc_buf, pos + 1)))
			if val != int(min(i32)) && val != 0 && code_match(&cc, pos_next, O(.neg), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				if code_match(&cc, cc.pos, O(.drop), -1) {
					if cc.line_num >= 0 {line_num = cc.line_num}
					if cc.col_num >= 0 {col_num = cc.col_num}
				} else {
					pc2(s, sl_size, &bc_out, line_num, col_num)
					push_short_int(&bc_out, -val)
				}
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, M2(O(.if_false), O(.if_true)), -1) {
				val = val != 0 ? 1 : 0
				next = .has_constant_test
				break
			}
			pc2(s, sl_size, &bc_out, line_num, col_num)
			push_short_int(&bc_out, val)
		case O(.push_bigint_i32):
			val = int(i32(get_u32(bc_buf, pos + 1)))
			if val != int(min(i32)) && code_match(&cc, pos_next, O(.neg), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				if code_match(&cc, cc.pos, O(.drop), -1) {
					if cc.line_num >= 0 {line_num = cc.line_num}
					if cc.col_num >= 0 {col_num = cc.col_num}
				} else {
					pc2(s, sl_size, &bc_out, line_num, col_num)
					out_u8(&bc_out, O(.push_bigint_i32))
					out_u32(&bc_out, u32(i32(-val)))
				}
				pos_next = cc.pos
				break
			}
			next = .no_change
		case O(.push_const), O(.fclosure):
			idx := int(get_u32(bc_buf, pos + 1))
			if idx < 256 {
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.push_const8) + op - O(.push_const))
				out_u8(&bc_out, idx)
				break
			}
			next = .no_change
		case O(.get_field):
			atom := Atom(get_u32(bc_buf, pos + 1))
			if atom == A_length {
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.get_length))
				break
			}
			next = .no_change
		case O(.push_atom_value):
			atom := Atom(get_u32(bc_buf, pos + 1))
			if code_match(&cc, pos_next, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pos_next = cc.pos
				break
			}
			if atom == A_empty_string {
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.push_empty_string))
				break
			}
			next = .no_change
		case O(.to_propkey), O(.to_propkey2):
			if code_match(&cc, pos_next, M3(O(.get_loc), O(.get_arg), O(.get_var_ref)), -1, O(.put_array_el), -1) ||
			   code_match(&cc, pos_next, M3(O(.push_i32), O(.push_const), O(.push_atom_value)), O(.put_array_el), -1) ||
			   code_match(&cc, pos_next, M4(O(.undefined), O(.null), O(.push_true), O(.push_false)), O(.put_array_el), -1) {
				break
			}
			next = .no_change
		case O(.undefined):
			if code_match(&cc, pos_next, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, O(.ret_), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.return_undef))
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, M2(O(.if_false), O(.if_true)), -1) {
				val = 0
				next = .has_constant_test
				break
			}
			if code_match(&cc, pos_next, O(.strict_eq), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.is_undefined))
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, O(.strict_neq), M2(O(.if_false), O(.if_true)), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.is_undefined))
				pos_next = cc.pos
				label = cc.label
				op = cc.op ~ O(.if_false) ~ O(.if_true)
				next = .has_label
				break
			}
			next = .no_change
		case O(.insert2):
			if code_match(&cc, pos_next, O(.put_field), O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.put_field))
				out_u32(&bc_out, u32(cc.atom))
				pos_next = cc.pos
				break
			}
			next = .no_change
		case O(.dup):
			line2 := -1
			if code_match(&cc, pos_next, M3(O(.put_loc), O(.put_arg), O(.put_var_ref)), -1, -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				dop := cc.op + 1
				pos_next = cc.pos
				if code_match(&cc, cc.pos, O(.drop), -1) {
					if cc.line_num >= 0 {line_num = cc.line_num}
					if cc.col_num >= 0 {col_num = cc.col_num}
					dop -= 1
					pos_next = cc.pos
					if code_match(&cc, cc.pos, dop - 1, cc.idx, -1) {
						line2 = cc.line_num
						dop += 1
						pos_next = cc.pos
					}
				}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				put_short_code(&bc_out, dop, cc.idx)
				if line2 >= 0 {line_num = line2}
				break
			}
			next = .no_change
		case O(.swap):
			if code_match(&cc, pos_next, O(.swap), -1, -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pos_next = cc.pos
				break
			}
			next = .no_change
		case O(.get_loc):
			idx := int(get_u16(bc_buf, pos + 1))
			if idx >= 256 {
				next = .no_change
				break
			}
			if code_match(&cc, pos_next, M2(O(.post_dec), O(.post_inc)), O(.put_loc), idx, O(.drop), -1) ||
			   code_match(&cc, pos_next, M2(O(.dec), O(.inc)), O(.dup), O(.put_loc), idx, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, (cc.op == O(.inc) || cc.op == O(.post_inc)) ? O(.inc_loc) : O(.dec_loc))
				out_u8(&bc_out, idx)
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, O(.push_atom_value), O(.add), O(.dup), O(.put_loc), idx, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				if cc.atom == A_empty_string {
					out_u8(&bc_out, O(.push_empty_string))
				} else {
					out_u8(&bc_out, O(.push_atom_value))
					out_u32(&bc_out, u32(cc.atom))
				}
				out_u8(&bc_out, O(.add_loc))
				out_u8(&bc_out, idx)
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, O(.push_i32), O(.add), O(.dup), O(.put_loc), idx, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				push_short_int(&bc_out, cc.label)
				out_u8(&bc_out, O(.add_loc))
				out_u8(&bc_out, idx)
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, M3(O(.get_loc), O(.get_arg), O(.get_var_ref)), -1, O(.add), O(.dup), O(.put_loc), idx, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				put_short_code(&bc_out, cc.op, cc.idx)
				out_u8(&bc_out, O(.add_loc))
				out_u8(&bc_out, idx)
				pos_next = cc.pos
				break
			}
			if idx == 0 && code_match(&cc, pos_next, O(.get_loc), 1, -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.get_loc0_loc1))
				pos_next = cc.pos
				break
			}
			pc2(s, sl_size, &bc_out, line_num, col_num)
			put_short_code(&bc_out, op, idx)
		case O(.get_arg), O(.get_var_ref):
			idx := int(get_u16(bc_buf, pos + 1))
			pc2(s, sl_size, &bc_out, line_num, col_num)
			put_short_code(&bc_out, op, idx)
		case O(.put_loc), O(.put_arg), O(.put_var_ref):
			idx := int(get_u16(bc_buf, pos + 1))
			if code_match(&cc, pos_next, op - 1, idx, -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				put_short_code(&bc_out, op + 1, idx)
				pos_next = cc.pos
				break
			}
			pc2(s, sl_size, &bc_out, line_num, col_num)
			put_short_code(&bc_out, op, idx)
		case O(.post_inc), O(.post_dec):
			if code_match(&cc, pos_next, M3(O(.put_loc), O(.put_arg), O(.put_var_ref)), -1, O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pop1 := cc.op
				idx := cc.idx
				pos_next = cc.pos
				if code_match(&cc, cc.pos, pop1 - 1, idx, -1) {
					if cc.line_num >= 0 {line_num = cc.line_num}
					if cc.col_num >= 0 {col_num = cc.col_num}
					pop1 += 1
					pos_next = cc.pos
				}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.dec) + (op - O(.post_dec)))
				put_short_code(&bc_out, pop1, idx)
				break
			}
			if code_match(&cc, pos_next, O(.perm3), O(.put_field), O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.dec) + (op - O(.post_dec)))
				out_u8(&bc_out, O(.put_field))
				out_u32(&bc_out, u32(cc.atom))
				pos_next = cc.pos
				break
			}
			if code_match(&cc, pos_next, O(.perm4), O(.put_array_el), O(.drop), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.dec) + (op - O(.post_dec)))
				out_u8(&bc_out, O(.put_array_el))
				pos_next = cc.pos
				break
			}
			next = .no_change
		case O(.typeof_):
			if code_match(&cc, pos_next, O(.push_atom_value), M4(O(.strict_eq), O(.strict_neq), O(.eq), O(.neq)), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				top1 := (cc.op == O(.strict_eq) || cc.op == O(.eq)) ? O(.strict_eq) : O(.strict_neq)
				op2 := -1
				if cc.atom == A_undefined {
					op2 = O(.typeof_is_undefined)
				} else if cc.atom == A_function {
					op2 = O(.typeof_is_function)
				}
				if op2 >= 0 {
					if top1 == O(.strict_eq) {
						pc2(s, sl_size, &bc_out, line_num, col_num)
						out_u8(&bc_out, op2)
						pos_next = cc.pos
						break
					}
					if top1 == O(.strict_neq) && code_match(&cc, cc.pos, O(.if_false), -1) {
						if cc.line_num >= 0 {line_num = cc.line_num}
						if cc.col_num >= 0 {col_num = cc.col_num}
						pc2(s, sl_size, &bc_out, line_num, col_num)
						out_u8(&bc_out, op2)
						pos_next = cc.pos
						label = cc.label
						op = O(.if_true)
						next = .has_label
						break
					}
				}
			}
			next = .no_change
		case O(.object):
			if code_match(&cc, pos_next, O(.null), O(.set_proto), -1) {
				if cc.line_num >= 0 {line_num = cc.line_num}
				if cc.col_num >= 0 {col_num = cc.col_num}
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, O(.special_object))
				out_u8(&bc_out, OP_SPECIAL_OBJECT_NULL_PROTO)
				pos_next = cc.pos
				break
			}
			next = .no_change
		case:
			next = .no_change
		}

		// shared tails
		if next == .has_constant_test {
			if cc.line_num >= 0 {line_num = cc.line_num}
			if cc.col_num >= 0 {col_num = cc.col_num}
			if val == cc.op - O(.if_false) {
				pos_next = cc.pos
				op = O(.goto)
				label = cc.label
				next = .has_goto
			} else {
				pos_next = cc.pos
				update_label(s, cc.label, -1)
				next = .done
			}
		}
		if next == .has_goto {
			label = find_jump_target(s, label, &op1)
			if code_has_label(&cc, pos_next, label) {
				update_label(s, label, -1)
				next = .done
			} else if op1 == O(.ret_) || op1 == O(.return_undef) || op1 == O(.throw_) {
				update_label(s, label, -1)
				pc2(s, sl_size, &bc_out, line_num, col_num)
				out_u8(&bc_out, op1)
				pos_next = skip_dead_code(s, bc_buf, bc_len, pos_next, &line_num, &col_num)
				next = .done
			} else {
				next = .has_label
			}
		}
		if next == .has_label {
			pc2(s, sl_size, &bc_out, line_num, col_num)
			if op == O(.goto) {
				pos_next = skip_dead_code(s, bc_buf, bc_len, pos_next, &line_num, &col_num)
			}
			ls := &label_slots[label]
			append(&s.jump_slots, Jump_Slot{op = op, size = 4, pos = len(bc_out) + 1, label = label})
			jp := &s.jump_slots[len(s.jump_slots) - 1]
			emitted := false
			if ls.addr == -1 {
				diff := ls.pos2 - pos - 1
				if diff < 128 && (op == O(.if_false) || op == O(.if_true) || op == O(.goto)) {
					jp.size = 1
					jp.op = O(.if_false8) + (op - O(.if_false))
					out_u8(&bc_out, jp.op)
					out_u8(&bc_out, 0)
					add_reloc(ls, len(bc_out) - 1, 1, ps.allocator)
					emitted = true
				} else if diff < 32768 && op == O(.goto) {
					jp.size = 2
					jp.op = O(.goto16)
					out_u8(&bc_out, O(.goto16))
					out_u16(&bc_out, 0)
					add_reloc(ls, len(bc_out) - 2, 2, ps.allocator)
					emitted = true
				}
			} else {
				diff := ls.addr - len(bc_out) - 1
				if diff == int(i8(diff)) && (op == O(.if_false) || op == O(.if_true) || op == O(.goto)) {
					jp.size = 1
					jp.op = O(.if_false8) + (op - O(.if_false))
					out_u8(&bc_out, jp.op)
					out_u8(&bc_out, diff)
					emitted = true
				} else if diff == int(i16(diff)) && op == O(.goto) {
					jp.size = 2
					jp.op = O(.goto16)
					out_u8(&bc_out, O(.goto16))
					out_u16(&bc_out, diff)
					emitted = true
				}
			}
			if !emitted {
				out_u8(&bc_out, op)
				out_u32(&bc_out, u32(i32(ls.addr - len(bc_out))))
				if ls.addr == -1 {
					add_reloc(ls, len(bc_out) - 4, 4, ps.allocator)
				}
			}
		} else if next == .no_change {
			pc2(s, sl_size, &bc_out, line_num, col_num)
			append(&bc_out, ..bc_buf[pos:pos + l])
		}
	}

	// more jump optimizations
	patch_offsets := 0
	for i := 0; i < len(s.jump_slots); i += 1 {
		jp := &s.jump_slots[i]
		delta := 3
		jop := jp.op
		switch jop {
		case O(.goto16), O(.if_false), O(.if_true), O(.goto):
			if jop == O(.goto16) {delta = 1}
			pos := jp.pos
			diff := label_slots[jp.label].addr - pos
			shrink := false
			if diff >= -128 && diff <= 127 + delta {
				jp.size = 1
				if jop == O(.goto16) {
					jp.op = O(.goto8)
				} else {
					jp.op = O(.if_false8) + (jop - O(.if_false))
				}
				bc_out[pos - 1] = u8(jp.op)
				shrink = true
			} else if diff == int(i16(diff)) && jop == O(.goto) {
				jp.size = 2
				delta = 2
				jp.op = O(.goto16)
				bc_out[pos - 1] = u8(jp.op)
				shrink = true
			}
			if shrink {
				src := pos + jp.size + delta
				dst := pos + jp.size
				n := len(bc_out) - pos - jp.size - delta
				copy(bc_out[dst:dst + n], bc_out[src:src + n])
				resize(&bc_out, len(bc_out) - delta)
				patch_offsets += 1
				for &ls in label_slots {
					if ls.addr > pos {ls.addr -= delta}
				}
				for j := i + 1; j < len(s.jump_slots); j += 1 {
					jp1 := &s.jump_slots[j]
					if jp1.pos > pos {jp1.pos -= delta}
				}
				for &sl in s.source_loc_slots {
					if sl.pc > pos {sl.pc -= delta}
				}
			}
		}
	}
	if patch_offsets > 0 {
		for jp1 in s.jump_slots {
			diff1 := label_slots[jp1.label].addr - jp1.pos
			switch jp1.size {
			case 1: bc_out[jp1.pos] = u8(i8(diff1))
			case 2: put_u16(bc_out[:], jp1.pos, u16(i16(diff1)))
			case 4: put_u32(bc_out[:], jp1.pos, u32(i32(diff1)))
			}
		}
	}
	compute_pc2line_info(s, has_slots)
	s.byte_code = bc_out
	s.use_short_opcodes = true
	return false
}

// --- compute_stack_size -------------------------------------------------------------------------------------

compute_stack_size :: proc(fd: ^Func_Def, allocator: runtime.Allocator) -> (int, bool) {
	bc_buf := fd.byte_code[:]
	bc_len := len(bc_buf)
	if bc_len == 0 {return 0, true}
	stack_level_tab := make([]u16, bc_len, allocator)
	catch_pos_tab := make([]i32, bc_len, allocator)
	for i in 0 ..< bc_len {stack_level_tab[i] = 0xffff}
	pc_stack := make([dynamic]int, 0, 32, allocator)
	stack_len_max := 0

	ss_check :: proc(stack_level_tab: []u16, catch_pos_tab: []i32, pc_stack: ^[dynamic]int, stack_len_max: ^int, pos, stack_len, catch_pos: int) -> bool {
		if pos < 0 || pos >= len(stack_level_tab) {return false}
		if stack_len > stack_len_max^ {
			stack_len_max^ = stack_len
			if stack_len_max^ > JS_STACK_SIZE_MAX {return false}
		}
		if stack_level_tab[pos] != 0xffff {
			return int(stack_level_tab[pos]) == stack_len && int(catch_pos_tab[pos]) == catch_pos
		}
		stack_level_tab[pos] = u16(stack_len)
		catch_pos_tab[pos] = i32(catch_pos)
		append(pc_stack, pos)
		return true
	}

	if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, 0, 0, -1) {return 0, false}
	for len(pc_stack) > 0 {
		pos := pop(&pc_stack)
		stack_len := int(stack_level_tab[pos])
		catch_pos := int(catch_pos_tab[pos])
		op := int(bc_buf[pos])
		if op == 0 || op >= OP_COUNT {return 0, false}
		oi := short_opcode_info(op)
		pos_next := pos + int(oi.size)
		if pos_next > bc_len {return 0, false}
		n_pop := int(oi.n_pop)
		if oi.fmt == .npop || oi.fmt == .npop_u16 {
			n_pop += int(get_u16(bc_buf, pos + 1))
		} else if oi.fmt == .npopx {
			n_pop += op - O(.call0)
		}
		if stack_len < n_pop {return 0, false}
		stack_len += int(oi.n_push) - n_pop
		if stack_len > stack_len_max {
			stack_len_max = stack_len
			if stack_len_max > JS_STACK_SIZE_MAX {return 0, false}
		}
		terminal := false
		catch_level := 0
		check_catch := false
		#partial switch Opcode(op) {
		case .tail_call, .tail_call_method, .ret_, .return_undef, .return_async, .throw_, .throw_error, .ret:
			terminal = true
		case .goto:
			pos_next = pos + 1 + int(i32(get_u32(bc_buf, pos + 1)))
		case .goto16:
			pos_next = pos + 1 + int(i16(get_u16(bc_buf, pos + 1)))
		case .goto8:
			pos_next = pos + 1 + int(i8(bc_buf[pos + 1]))
		case .if_true8, .if_false8:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 1 + int(i8(bc_buf[pos + 1])), stack_len, catch_pos) {return 0, false}
		case .if_true, .if_false:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 1 + int(i32(get_u32(bc_buf, pos + 1))), stack_len, catch_pos) {return 0, false}
		case .gosub:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 1 + int(i32(get_u32(bc_buf, pos + 1))), stack_len + 1, catch_pos) {return 0, false}
		case .with_get_var, .with_delete_var:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 5 + int(i32(get_u32(bc_buf, pos + 5))), stack_len + 1, catch_pos) {return 0, false}
		case .with_make_ref, .with_get_ref, .with_get_ref_undef:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 5 + int(i32(get_u32(bc_buf, pos + 5))), stack_len + 2, catch_pos) {return 0, false}
		case .with_put_var:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 5 + int(i32(get_u32(bc_buf, pos + 5))), stack_len - 1, catch_pos) {return 0, false}
		case .catch:
			if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos + 1 + int(i32(get_u32(bc_buf, pos + 1))), stack_len, catch_pos) {return 0, false}
			catch_pos = pos
		case .for_of_start, .for_await_of_start:
			catch_pos = pos
		case .drop:
			catch_level = stack_len
			check_catch = true
		case .nip, .nip1:
			catch_level = stack_len - 1
			check_catch = true
		case .iterator_close:
			catch_level = stack_len + 2
			check_catch = true
		case .nip_catch:
			if catch_pos < 0 {return 0, false}
			stack_len = int(stack_level_tab[catch_pos])
			if int(bc_buf[catch_pos]) != O(.catch) {stack_len += 1}
			stack_len += 1
			catch_pos = int(catch_pos_tab[catch_pos])
		case:
		}
		if terminal {continue}
		if check_catch && catch_pos >= 0 {
			level := int(stack_level_tab[catch_pos])
			if int(bc_buf[catch_pos]) != O(.catch) {level += 1}
			if catch_level == level {
				catch_pos = int(catch_pos_tab[catch_pos])
			}
		}
		if !ss_check(stack_level_tab, catch_pos_tab, &pc_stack, &stack_len_max, pos_next, stack_len, catch_pos) {return 0, false}
	}
	return stack_len_max, true
}

// --- js_create_function -------------------------------------------------------------------------------------

add_module_variables :: proc(ps: ^Pass_State, fd: ^Func_Def) -> bool {
	m := fd.module
	for hf, i in fd.global_vars {
		if add_closure_var(fd, .module_decl, i, hf.var_name, hf.is_const, hf.is_lexical, .normal) < 0 {return true}
	}
	for &me in m.export_entries {
		if me.export_type == .local {
			idx := find_closure_var(fd, me.local_name)
			if idx < 0 {
				ps.error = "exported variable does not exist"
				return true
			}
			me.var_idx = idx
		}
	}
	return false
}

js_create_function :: proc(ps: ^Pass_State, fd: ^Func_Def) -> ^Function_Bytecode {
	if stack_exhausted(ps.stack) {
		ps.error = "stack overflow"
		return nil
	}
	for i in 0 ..< len(fd.scopes) {
		fd.scopes[i].first = -1
	}
	if fd.has_parameter_expressions {
		fd.scopes[ARG_SCOPE_INDEX].first = ARG_SCOPE_END
	}
	for idx in 0 ..< len(fd.vars) {
		vd := &fd.vars[idx]
		vd.scope_next = fd.scopes[vd.scope_level].first
		fd.scopes[vd.scope_level].first = idx
	}
	for scope in 2 ..< len(fd.scopes) {
		sd := &fd.scopes[scope]
		if sd.first < 0 {
			sd.first = fd.scopes[sd.parent].first
		}
	}
	for idx in 0 ..< len(fd.vars) {
		vd := &fd.vars[idx]
		if vd.scope_next < 0 && vd.scope_level > 1 {
			scope := fd.scopes[vd.scope_level].parent
			vd.scope_next = fd.scopes[scope].first
		}
	}

	if fd.has_eval_call {
		add_eval_variables(fd)
	}
	if fd.module != nil {
		if add_module_variables(ps, fd) {return nil}
	}

	for fd1 in fd.child_list {
		cpool_idx := fd1.parent_cpool_idx
		b := js_create_function(ps, fd1)
		if b == nil {return nil}
		fd.cpool[cpool_idx] = b
	}

	if resolve_variables(ps, fd) {return nil}
	if resolve_labels(ps, fd) {return nil}
	stack_size, ok := compute_stack_size(fd, ps.allocator)
	if !ok {
		ps.error = "internal error: inconsistent stack"
		return nil
	}

	b := new(Function_Bytecode, ps.allocator)
	b.byte_code = fd.byte_code[:]
	b.func_name = fd.func_name
	if len(fd.args) + len(fd.vars) > 0 {
		vardefs := make([]Var_Def, len(fd.args) + len(fd.vars), ps.allocator)
		copy(vardefs, fd.args[:])
		copy(vardefs[len(fd.args):], fd.vars[:])
		b.vardefs = vardefs
		b.var_count = len(fd.vars)
		b.arg_count = len(fd.args)
		b.defined_arg_count = fd.defined_arg_count
		b.var_ref_count = fd.var_ref_count
	}
	b.cpool = fd.cpool[:]
	b.stack_size = stack_size
	b.filename = fd.filename
	b.line_num = fd.line_num
	b.col_num = fd.col_num
	b.pc2line = fd.pc2line[:]
	b.closure_var = fd.closure_var[:]
	b.has_prototype = fd.has_prototype
	b.has_simple_parameter_list = fd.has_simple_parameter_list
	b.is_strict_mode = fd.is_strict_mode
	b.is_derived_class_constructor = fd.is_derived_class_constructor
	b.func_kind = fd.func_kind
	b.need_home_object = fd.home_object_var_idx >= 0 || fd.need_home_object
	b.new_target_allowed = fd.new_target_allowed
	b.super_call_allowed = fd.super_call_allowed
	b.super_allowed = fd.super_allowed
	b.arguments_allowed = fd.arguments_allowed
	b.backtrace_barrier = fd.backtrace_barrier
	return b
}
