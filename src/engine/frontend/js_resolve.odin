package frontend

// Variable resolution (phase 2 helpers): closures, the scope_* temporary opcodes lowered to local / argument /
// closure / global accesses, private fields, and the eval capture rules. resolve_variables (js_passes.odin)
// drives these over the phase-1 stream.

add_closure_var :: proc(s: ^Func_Def, closure_type: Closure_Type, var_idx: int, var_name: Atom, is_const, is_lexical: bool, var_kind: Var_Kind) -> int {
	if len(s.closure_var) >= JS_MAX_LOCAL_VARS {return -1}
	append(&s.closure_var, Closure_Var{
		closure_type = closure_type,
		is_const = is_const,
		is_lexical = is_lexical,
		var_kind = var_kind,
		var_idx = var_idx,
		var_name = var_name,
	})
	return len(s.closure_var) - 1
}

find_closure_var :: proc(s: ^Func_Def, var_name: Atom) -> int {
	for cv, i in s.closure_var {
		if cv.var_name == var_name {return i}
	}
	return -1
}

// get_closure_var: 'fd' must be a parent of 's'; create in 's' a closure referencing one in 'fd'.
get_closure_var :: proc(s: ^Func_Def, fd: ^Func_Def, closure_type0: Closure_Type, var_idx0: int, var_name: Atom, is_const, is_lexical: bool, var_kind: Var_Kind) -> int {
	closure_type := closure_type0
	var_idx := var_idx0
	if fd != s.parent {
		var_idx = get_closure_var(s.parent, fd, closure_type, var_idx, var_name, is_const, is_lexical, var_kind)
		if var_idx < 0 {return -1}
		if closure_type != .global_ref {closure_type = .ref}
	}
	for cv, i in s.closure_var {
		if cv.var_idx == var_idx && cv.closure_type == closure_type {return i}
	}
	return add_closure_var(s, closure_type, var_idx, var_name, is_const, is_lexical, var_kind)
}

get_with_scope_opcode :: proc(op: int) -> int {
	if op == OP_scope_get_var_undef {return O(.with_get_var)}
	return O(.with_get_var) + (op - OP_scope_get_var)
}

can_opt_put_ref_value :: proc(bc_buf: []u8, pos: int) -> bool {
	opcode := int(bc_buf[pos])
	return int(bc_buf[pos + 1]) == O(.put_ref_value) &&
		(opcode == O(.insert3) || opcode == O(.perm4) || opcode == O(.nop) || opcode == O(.rot3l))
}

// Bc_Out is the DynBuf the passes write into.
Bc_Out :: [dynamic]u8

out_u8 :: #force_inline proc(bc: ^Bc_Out, v: int) {append(bc, u8(v))}
out_u16 :: #force_inline proc(bc: ^Bc_Out, v: int) {append(bc, u8(v), u8(v >> 8))}
out_u32 :: #force_inline proc(bc: ^Bc_Out, v: u32) {append(bc, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}

optimize_scope_make_ref :: proc(s: ^Func_Def, bc: ^Bc_Out, bc_buf: []u8, ls: ^Label_Slot, pos_next0: int, get_op: int, var_idx: int) -> int {
	pos_next := pos_next0
	if int(bc_buf[pos_next]) == O(.get_ref_value) {
		out_u8(bc, get_op)
		out_u16(bc, var_idx)
		pos_next += 1
	}
	label_pos := ls.pos
	pos := label_pos - 5
	end_pos := label_pos + 2
	if int(bc_buf[label_pos]) == O(.insert3) {
		bc_buf[pos] = u8(O(.dup))
		pos += 1
	}
	bc_buf[pos] = u8(get_op + 1)
	put_u16(bc_buf, pos + 1, u16(var_idx))
	pos += 3
	for pos < end_pos {
		bc_buf[pos] = u8(O(.nop))
		pos += 1
	}
	return pos_next
}

optimize_scope_make_global_ref :: proc(s: ^Func_Def, bc: ^Bc_Out, bc_buf: []u8, ls: ^Label_Slot, pos_next0: int, var_name: Atom) -> int {
	pos_next := pos_next0
	if int(bc_buf[pos_next]) == O(.get_ref_value) {
		out_u8(bc, O(.get_var))
		out_u32(bc, u32(var_name))
		pos_next += 1
	}
	label_pos := ls.pos
	pos := label_pos - 5
	end_pos := label_pos + 2
	if int(bc_buf[label_pos]) == O(.insert3) {
		bc_buf[pos] = u8(O(.dup))
		pos += 1
	}
	bc_buf[pos] = u8(O(.put_var))
	put_u32(bc_buf, pos + 1, u32(var_name))
	pos += 5
	for pos < end_pos {
		bc_buf[pos] = u8(O(.nop))
		pos += 1
	}
	return pos_next
}

// The compile-time variable additions done during resolution cannot fail on a well-formed program except for
// the 65535-variable cap, which the parser already enforces; they use a parse state only for that error.
@(private = "file")
rs_add_var :: proc(fd: ^Func_Def, name: Atom) -> int {
	append(&fd.vars, Var_Def{var_name = name, func_pool_idx = -1})
	return len(fd.vars) - 1
}

add_var_this :: proc(fd: ^Func_Def) -> int {
	idx := rs_add_var(fd, A_this)
	if idx >= 0 && fd.is_derived_class_constructor {
		fd.vars[idx].is_lexical = true
	}
	return idx
}

rs_add_arguments_var :: proc(fd: ^Func_Def) -> int {
	idx := fd.arguments_var_idx
	if idx < 0 {
		idx = rs_add_var(fd, A_arguments)
		fd.arguments_var_idx = idx
	}
	return idx
}

rs_add_func_var :: proc(fd: ^Func_Def, name: Atom) -> int {
	idx := fd.func_var_idx
	if idx < 0 {
		idx = rs_add_var(fd, name)
		fd.func_var_idx = idx
		fd.vars[idx].var_kind = .function_name
		if fd.is_strict_mode {fd.vars[idx].is_const = true}
	}
	return idx
}

rs_add_arguments_arg :: proc(fd: ^Func_Def) {
	if fd.arguments_arg_idx < 0 {
		idx := find_var_in_scope(fd, A_arguments, ARG_SCOPE_INDEX)
		if idx < 0 {
			idx = rs_add_var(fd, A_arguments)
			fd.vars[idx].scope_next = fd.scopes[ARG_SCOPE_INDEX].first
			fd.scopes[ARG_SCOPE_INDEX].first = idx
			fd.vars[idx].scope_level = ARG_SCOPE_INDEX
			fd.vars[idx].is_lexical = true
			fd.arguments_arg_idx = idx
		}
	}
}

resolve_pseudo_var :: proc(s: ^Func_Def, var_name: Atom) -> int {
	if !s.has_this_binding {return -1}
	switch var_name {
	case A_home_object:
		if s.home_object_var_idx < 0 {s.home_object_var_idx = rs_add_var(s, var_name)}
		return s.home_object_var_idx
	case A_this_active_func:
		if s.this_active_func_var_idx < 0 {s.this_active_func_var_idx = rs_add_var(s, var_name)}
		return s.this_active_func_var_idx
	case A_new_target:
		if s.new_target_var_idx < 0 {s.new_target_var_idx = rs_add_var(s, var_name)}
		return s.new_target_var_idx
	case A_this:
		if s.this_var_idx < 0 {s.this_var_idx = add_var_this(s)}
		return s.this_var_idx
	}
	return -1
}

var_object_test :: proc(s: ^Func_Def, var_name: Atom, op: int, bc: ^Bc_Out, plabel_done: ^int, is_with: bool) {
	out_u8(bc, get_with_scope_opcode(op))
	out_u32(bc, u32(var_name))
	if plabel_done^ < 0 {
		plabel_done^ = new_label_fd(s)
	}
	out_u32(bc, u32(plabel_done^))
	out_u8(bc, is_with ? 1 : 0)
	update_label(s, plabel_done^, 1)
}

capture_var :: #force_inline proc(s: ^Func_Def, vd: ^Var_Def) {
	if !vd.is_captured {
		vd.is_captured = true
		vd.var_ref_idx = s.var_ref_count
		s.var_ref_count += 1
	}
}

@(private = "file")
emit_throw_ro :: proc(bc: ^Bc_Out, var_name: Atom) {
	out_u8(bc, O(.throw_error))
	out_u32(bc, u32(var_name))
	out_u8(bc, JS_THROW_VAR_RO)
}

// resolve_scope_var lowers one scope_* opcode; returns the position of the next opcode.
resolve_scope_var :: proc(s: ^Func_Def, var_name: Atom, scope_level0: int, op: int, bc: ^Bc_Out, bc_buf: []u8, ls: ^Label_Slot, pos_next0: int) -> int {
	pos_next := pos_next0
	scope_level := scope_level0
	label_done := -1
	is_pseudo_var := var_name == A_home_object || var_name == A_this_active_func || var_name == A_new_target || var_name == A_this
	var_idx := -1
	idx: int
	fd: ^Func_Def

	defer if label_done >= 0 {
		out_u8(bc, OP_label)
		out_u32(bc, u32(label_done))
		s.label_slots[label_done].pos2 = len(bc)
	}

	idx = s.scopes[scope_level].first
	for idx >= 0 {
		vd := &s.vars[idx]
		if vd.var_name == var_name {
			if op == OP_scope_put_var || op == OP_scope_make_ref {
				if vd.is_const {
					emit_throw_ro(bc, var_name)
					return pos_next
				}
			}
			var_idx = idx
			break
		} else if vd.var_name == A__with_ && !is_pseudo_var {
			out_u8(bc, O(.get_loc))
			out_u16(bc, idx)
			var_object_test(s, var_name, op, bc, &label_done, true)
		}
		idx = vd.scope_next
	}
	is_arg_scope := idx == ARG_SCOPE_END
	if var_idx < 0 {
		if !is_arg_scope {
			var_idx = find_var(s, var_name)
		}
		if var_idx < 0 && is_pseudo_var {
			var_idx = resolve_pseudo_var(s, var_name)
		}
		if var_idx < 0 && var_name == A_arguments && s.has_arguments_binding {
			var_idx = rs_add_arguments_var(s)
		}
		if var_idx < 0 && s.is_func_expr && var_name == s.func_name {
			var_idx = rs_add_func_var(s, var_name)
		}
	}
	if var_idx >= 0 {
		if (op == OP_scope_put_var || op == OP_scope_make_ref) && (var_idx & ARGUMENT_VAR_OFFSET) == 0 && s.vars[var_idx].is_const {
			emit_throw_ro(bc, var_name)
			return pos_next
		}
		local_scope_var := false
		switch op {
		case OP_scope_make_ref:
			if (var_idx & ARGUMENT_VAR_OFFSET) == 0 && s.vars[var_idx].var_kind == .function_name {
				out_u8(bc, O(.object))
				out_u8(bc, O(.get_loc))
				out_u16(bc, var_idx)
				out_u8(bc, O(.define_field))
				out_u32(bc, u32(var_name))
				out_u8(bc, O(.push_atom_value))
				out_u32(bc, u32(var_name))
			} else if label_done == -1 && can_opt_put_ref_value(bc_buf, ls.pos) {
				get_op: int
				vi := var_idx
				if (vi & ARGUMENT_VAR_OFFSET) != 0 {
					get_op = O(.get_arg)
					vi -= ARGUMENT_VAR_OFFSET
				} else {
					get_op = s.vars[vi].is_lexical ? O(.get_loc_check) : O(.get_loc)
				}
				pos_next = optimize_scope_make_ref(s, bc, bc_buf, ls, pos_next, get_op, vi)
			} else {
				if (var_idx & ARGUMENT_VAR_OFFSET) != 0 {
					capture_var(s, &s.args[var_idx - ARGUMENT_VAR_OFFSET])
					out_u8(bc, O(.make_arg_ref))
					out_u32(bc, u32(var_name))
					out_u16(bc, var_idx - ARGUMENT_VAR_OFFSET)
				} else {
					capture_var(s, &s.vars[var_idx])
					out_u8(bc, O(.make_loc_ref))
					out_u32(bc, u32(var_name))
					out_u16(bc, var_idx)
				}
			}
		case OP_scope_put_var:
			if (var_idx & ARGUMENT_VAR_OFFSET) == 0 && s.vars[var_idx].var_kind == .function_name {
				out_u8(bc, O(.drop))
				return pos_next
			}
			local_scope_var = true
		case OP_scope_get_ref:
			out_u8(bc, O(.undefined))
			local_scope_var = true
		case OP_scope_get_var_undef, OP_scope_get_var, OP_scope_put_var_init:
			local_scope_var = true
		case OP_scope_delete_var:
			out_u8(bc, O(.push_false))
		}
		if local_scope_var {
			is_put := op == OP_scope_put_var || op == OP_scope_put_var_init
			if (var_idx & ARGUMENT_VAR_OFFSET) != 0 {
				out_u8(bc, O(.get_arg) + (is_put ? 1 : 0))
				out_u16(bc, var_idx - ARGUMENT_VAR_OFFSET)
			} else {
				if is_put {
					if s.vars[var_idx].is_lexical {
						if op == OP_scope_put_var_init {
							out_u8(bc, var_name == A_this ? O(.put_loc_check_init) : O(.put_loc))
						} else {
							out_u8(bc, O(.put_loc_check))
						}
					} else {
						out_u8(bc, O(.put_loc))
					}
				} else {
					out_u8(bc, s.vars[var_idx].is_lexical ? O(.get_loc_check) : O(.get_loc))
				}
				out_u16(bc, var_idx)
			}
		}
		return pos_next
	}
	if !is_arg_scope && s.var_object_idx >= 0 && !is_pseudo_var {
		out_u8(bc, O(.get_loc))
		out_u16(bc, s.var_object_idx)
		var_object_test(s, var_name, op, bc, &label_done, false)
	}
	if s.arg_var_object_idx >= 0 && !is_pseudo_var {
		out_u8(bc, O(.get_loc))
		out_u16(bc, s.arg_var_object_idx)
		var_object_test(s, var_name, op, bc, &label_done, false)
	}

	fd = s
	for fd.parent != nil {
		scope_level = fd.parent_scope_level
		fd = fd.parent
		idx = fd.scopes[scope_level].first
		for idx >= 0 {
			vd := &fd.vars[idx]
			if vd.var_name == var_name {
				if op == OP_scope_put_var || op == OP_scope_make_ref {
					if vd.is_const {
						emit_throw_ro(bc, var_name)
						return pos_next
					}
				}
				var_idx = idx
				break
			} else if vd.var_name == A__with_ && !is_pseudo_var {
				capture_var(fd, vd)
				idx2 := get_closure_var(s, fd, .local, idx, vd.var_name, false, false, .normal)
				if idx2 >= 0 {
					out_u8(bc, O(.get_var_ref))
					out_u16(bc, idx2)
					var_object_test(s, var_name, op, bc, &label_done, true)
				}
			}
			idx = vd.scope_next
		}
		is_arg_scope = idx == ARG_SCOPE_END
		if var_idx >= 0 {break}
		if !is_arg_scope {
			var_idx = find_var(fd, var_name)
			if var_idx >= 0 {break}
		}
		if is_pseudo_var {
			var_idx = resolve_pseudo_var(fd, var_name)
			if var_idx >= 0 {break}
		}
		if var_name == A_arguments && fd.has_arguments_binding {
			var_idx = rs_add_arguments_var(fd)
			break
		}
		if fd.is_func_expr && fd.func_name == var_name {
			var_idx = rs_add_func_var(fd, var_name)
			break
		}
		if !is_arg_scope && fd.var_object_idx >= 0 && !is_pseudo_var {
			vd := &fd.vars[fd.var_object_idx]
			capture_var(fd, vd)
			idx2 := get_closure_var(s, fd, .local, fd.var_object_idx, vd.var_name, false, false, .normal)
			out_u8(bc, O(.get_var_ref))
			out_u16(bc, idx2)
			var_object_test(s, var_name, op, bc, &label_done, false)
		}
		if fd.arg_var_object_idx >= 0 && !is_pseudo_var {
			vd := &fd.vars[fd.arg_var_object_idx]
			capture_var(fd, vd)
			idx2 := get_closure_var(s, fd, .local, fd.arg_var_object_idx, vd.var_name, false, false, .normal)
			out_u8(bc, O(.get_var_ref))
			out_u16(bc, idx2)
			var_object_test(s, var_name, op, bc, &label_done, false)
		}
		if fd.is_eval {break}
	}

	cidx := -1
	if var_idx < 0 && fd.is_eval {
		for idx1 in 0 ..< len(fd.closure_var) {
			cv := fd.closure_var[idx1]
			if var_name == cv.var_name {
				if fd != s {
					cidx = get_closure_var(s, fd, .ref, idx1, cv.var_name, cv.is_const, cv.is_lexical, cv.var_kind)
				} else {
					cidx = idx1
				}
				break
			} else if (cv.var_name == A__var_ || cv.var_name == A__arg_var_ || cv.var_name == A__with_) && !is_pseudo_var {
				is_with := cv.var_name == A__with_
				i2: int
				if fd != s {
					i2 = get_closure_var(s, fd, .ref, idx1, cv.var_name, false, false, .normal)
				} else {
					i2 = idx1
				}
				out_u8(bc, O(.get_var_ref))
				out_u16(bc, i2)
				var_object_test(s, var_name, op, bc, &label_done, is_with)
			}
		}
	}

	if cidx < 0 && var_idx >= 0 {
		if (var_idx & ARGUMENT_VAR_OFFSET) != 0 {
			capture_var(fd, &fd.args[var_idx - ARGUMENT_VAR_OFFSET])
			cidx = get_closure_var(s, fd, .arg, var_idx - ARGUMENT_VAR_OFFSET, var_name, false, false, .normal)
		} else {
			capture_var(fd, &fd.vars[var_idx])
			v := fd.vars[var_idx]
			cidx = get_closure_var(s, fd, .local, var_idx, var_name, v.is_const, v.is_lexical, v.var_kind)
		}
	}
	if cidx >= 0 {
		idx = cidx
		if (op == OP_scope_put_var || op == OP_scope_make_ref) && s.closure_var[idx].is_const {
			emit_throw_ro(bc, var_name)
			return pos_next
		}
		closure_scope_var := false
		switch op {
		case OP_scope_make_ref:
			if s.closure_var[idx].var_kind == .function_name {
				out_u8(bc, O(.object))
				out_u8(bc, O(.get_var_ref))
				out_u16(bc, idx)
				out_u8(bc, O(.define_field))
				out_u32(bc, u32(var_name))
				out_u8(bc, O(.push_atom_value))
				out_u32(bc, u32(var_name))
			} else if label_done == -1 && can_opt_put_ref_value(bc_buf, ls.pos) {
				get_op := s.closure_var[idx].is_lexical ? O(.get_var_ref_check) : O(.get_var_ref)
				pos_next = optimize_scope_make_ref(s, bc, bc_buf, ls, pos_next, get_op, idx)
			} else {
				out_u8(bc, O(.make_var_ref_ref))
				out_u32(bc, u32(var_name))
				out_u16(bc, idx)
			}
		case OP_scope_put_var:
			if s.closure_var[idx].var_kind == .function_name {
				out_u8(bc, O(.drop))
				return pos_next
			}
			closure_scope_var = true
		case OP_scope_get_ref:
			out_u8(bc, O(.undefined))
			closure_scope_var = true
		case OP_scope_get_var_undef, OP_scope_get_var, OP_scope_put_var_init:
			closure_scope_var = true
		case OP_scope_delete_var:
			out_u8(bc, O(.push_false))
		}
		if closure_scope_var {
			is_put := op == OP_scope_put_var || op == OP_scope_put_var_init
			if is_put {
				if s.closure_var[idx].is_lexical {
					if op == OP_scope_put_var_init {
						out_u8(bc, var_name == A_this ? O(.put_var_ref_check_init) : O(.put_var_ref))
					} else {
						out_u8(bc, O(.put_var_ref_check))
					}
				} else {
					out_u8(bc, O(.put_var_ref))
				}
			} else {
				out_u8(bc, s.closure_var[idx].is_lexical ? O(.get_var_ref_check) : O(.get_var_ref))
			}
			out_u16(bc, idx)
		}
		return pos_next
	}

	// global variable access
	switch op {
	case OP_scope_make_ref:
		if label_done == -1 && can_opt_put_ref_value(bc_buf, ls.pos) {
			pos_next = optimize_scope_make_global_ref(s, bc, bc_buf, ls, pos_next, var_name)
		} else {
			out_u8(bc, O(.make_var_ref))
			out_u32(bc, u32(var_name))
		}
	case OP_scope_get_ref:
		out_u8(bc, O(.undefined))
		out_u8(bc, O(.get_var))
		out_u32(bc, u32(var_name))
	case OP_scope_get_var_undef, OP_scope_get_var, OP_scope_put_var:
		out_u8(bc, O(.get_var_undef) + (op - OP_scope_get_var_undef))
		out_u32(bc, u32(var_name))
	case OP_scope_put_var_init:
		out_u8(bc, O(.put_var_init))
		out_u32(bc, u32(var_name))
	case OP_scope_delete_var:
		out_u8(bc, O(.delete_var))
		out_u32(bc, u32(var_name))
	}
	return pos_next
}

// --- private fields -----------------------------------------------------------------------------------------

find_private_class_field_all :: proc(fd: ^Func_Def, name: Atom, scope_level: int) -> int {
	idx := fd.scopes[scope_level].first
	for idx >= 0 {
		if fd.vars[idx].var_name == name {return idx}
		idx = fd.vars[idx].scope_next
	}
	return -1
}

get_loc_or_ref :: proc(bc: ^Bc_Out, is_ref: bool, idx: int) {
	out_u8(bc, is_ref ? O(.get_var_ref) : O(.get_loc))
	out_u16(bc, idx)
}

resolve_scope_private_field1 :: proc(pis_ref: ^bool, pvar_kind: ^Var_Kind, s: ^Func_Def, var_name: Atom, scope_level0: int) -> int {
	scope_level := scope_level0
	fd := s
	is_ref := false
	var_kind: Var_Kind
	idx: int
	for {
		idx = find_private_class_field_all(fd, var_name, scope_level)
		if idx >= 0 {
			var_kind = fd.vars[idx].var_kind
			if is_ref {
				capture_var(fd, &fd.vars[idx])
				idx = get_closure_var(s, fd, .local, idx, var_name, true, true, .normal)
				if idx < 0 {return -1}
			}
			break
		}
		scope_level = fd.parent_scope_level
		if fd.parent == nil {
			if fd.is_eval {
				for cv, ci in fd.closure_var {
					if cv.var_name == var_name {
						var_kind = cv.var_kind
						is_ref = true
						idx = ci
						if fd != s {
							idx = get_closure_var(s, fd, .ref, ci, cv.var_name, cv.is_const, cv.is_lexical, cv.var_kind)
							if idx < 0 {return -1}
						}
						pis_ref^ = is_ref
						pvar_kind^ = var_kind
						return idx
					}
				}
			}
			return -1
		}
		fd = fd.parent
		is_ref = true
	}
	pis_ref^ = is_ref
	pvar_kind^ = var_kind
	return idx
}

// resolve_scope_private_field returns false if the private field could not be resolved.
resolve_scope_private_field :: proc(s: ^Func_Def, atoms: ^Atom_Table, var_name: Atom, scope_level: int, op: int, bc: ^Bc_Out) -> bool {
	is_ref: bool
	var_kind: Var_Kind
	idx := resolve_scope_private_field1(&is_ref, &var_kind, s, var_name, scope_level)
	if idx < 0 {return false}
	switch op {
	case OP_scope_get_private_field, OP_scope_get_private_field2:
		#partial switch var_kind {
		case .private_field:
			if op == OP_scope_get_private_field2 {out_u8(bc, O(.dup))}
			get_loc_or_ref(bc, is_ref, idx)
			out_u8(bc, O(.get_private_field))
		case .private_method:
			get_loc_or_ref(bc, is_ref, idx)
			out_u8(bc, O(.check_brand))
			if op != OP_scope_get_private_field2 {out_u8(bc, O(.nip))}
		case .private_getter, .private_getter_setter:
			if op == OP_scope_get_private_field2 {out_u8(bc, O(.dup))}
			get_loc_or_ref(bc, is_ref, idx)
			out_u8(bc, O(.check_brand))
			out_u8(bc, O(.call_method))
			out_u16(bc, 0)
		case .private_setter:
			emit_throw_ro(bc, var_name)
		}
	case OP_scope_put_private_field:
		#partial switch var_kind {
		case .private_field:
			get_loc_or_ref(bc, is_ref, idx)
			out_u8(bc, O(.put_private_field))
		case .private_method, .private_getter:
			emit_throw_ro(bc, var_name)
		case .private_setter, .private_getter_setter:
			setter_name := atom_concat(atoms, var_name, "<set>")
			idx = resolve_scope_private_field1(&is_ref, &var_kind, s, setter_name, scope_level)
			if idx < 0 {return false}
			get_loc_or_ref(bc, is_ref, idx)
			out_u8(bc, O(.swap))
			out_u8(bc, O(.rot3r))
			out_u8(bc, O(.check_brand))
			out_u8(bc, O(.rot3l))
			out_u8(bc, O(.call_method))
			out_u16(bc, 1)
			out_u8(bc, O(.drop))
		}
	case OP_scope_in_private_field:
		get_loc_or_ref(bc, is_ref, idx)
		out_u8(bc, O(.private_in))
	}
	return true
}

mark_eval_captured_variables :: proc(s: ^Func_Def, scope_level: int) {
	idx := s.scopes[scope_level].first
	for idx >= 0 {
		vd := &s.vars[idx]
		capture_var(s, vd)
		idx = vd.scope_next
	}
}

is_var_in_arg_scope :: proc(vd: ^Var_Def) -> bool {
	return vd.var_name == A_home_object || vd.var_name == A_this_active_func || vd.var_name == A_new_target ||
		vd.var_name == A_this || vd.var_name == A__arg_var_ || vd.var_kind == .function_name
}

add_eval_variables :: proc(s: ^Func_Def) {
	if !s.is_eval && !s.is_strict_mode {
		s.var_object_idx = rs_add_var(s, A__var_)
		if s.has_parameter_expressions {
			s.arg_var_object_idx = rs_add_var(s, A__arg_var_)
		}
	}
	has_this_binding := s.has_this_binding
	if has_this_binding {
		if s.this_var_idx < 0 {s.this_var_idx = add_var_this(s)}
		if s.new_target_var_idx < 0 {s.new_target_var_idx = rs_add_var(s, A_new_target)}
		if s.is_derived_class_constructor && s.this_active_func_var_idx < 0 {s.this_active_func_var_idx = rs_add_var(s, A_this_active_func)}
		if s.has_home_object && s.home_object_var_idx < 0 {s.home_object_var_idx = rs_add_var(s, A_home_object)}
	}
	has_arguments_binding := s.has_arguments_binding
	if has_arguments_binding {
		rs_add_arguments_var(s)
		if s.has_parameter_expressions && !s.is_strict_mode {
			rs_add_arguments_arg(s)
		}
	}
	if s.is_func_expr && s.func_name != JS_ATOM_NULL {
		rs_add_func_var(s, s.func_name)
	}
	if !s.is_eval {
		for i in 0 ..< len(s.args) {capture_var(s, &s.args[i])}
		for i in 0 ..< len(s.vars) {capture_var(s, &s.vars[i])}
	}
	fd := s
	for {
		scope_level := fd.parent_scope_level
		fd = fd.parent
		if fd == nil {break}
		if !has_this_binding && fd.has_this_binding {
			if fd.this_var_idx < 0 {fd.this_var_idx = add_var_this(fd)}
			if fd.new_target_var_idx < 0 {fd.new_target_var_idx = rs_add_var(fd, A_new_target)}
			if fd.is_derived_class_constructor && fd.this_active_func_var_idx < 0 {fd.this_active_func_var_idx = rs_add_var(fd, A_this_active_func)}
			if fd.has_home_object && fd.home_object_var_idx < 0 {fd.home_object_var_idx = rs_add_var(fd, A_home_object)}
			has_this_binding = true
		}
		if !has_arguments_binding && fd.has_arguments_binding {
			rs_add_arguments_var(fd)
			has_arguments_binding = true
		}
		if fd.is_func_expr && fd.func_name != JS_ATOM_NULL {
			rs_add_func_var(fd, fd.func_name)
		}
		scope_idx := fd.scopes[scope_level].first
		for scope_idx >= 0 {
			vd := &fd.vars[scope_idx]
			capture_var(fd, vd)
			get_closure_var(s, fd, .local, scope_idx, vd.var_name, vd.is_const, vd.is_lexical, vd.var_kind)
			scope_idx = vd.scope_next
		}
		is_arg_scope := scope_idx == ARG_SCOPE_END
		if !is_arg_scope {
			for i in 0 ..< len(fd.args) {
				vd := &fd.args[i]
				if vd.var_name != JS_ATOM_NULL {
					capture_var(fd, vd)
					get_closure_var(s, fd, .arg, i, vd.var_name, false, vd.is_lexical, .normal)
				}
			}
			for i in 0 ..< len(fd.vars) {
				vd := &fd.vars[i]
				if vd.scope_level == 0 && vd.var_name != A__ret_ && vd.var_name != JS_ATOM_NULL {
					capture_var(fd, vd)
					get_closure_var(s, fd, .local, i, vd.var_name, false, vd.is_lexical, .normal)
				}
			}
		} else {
			for i in 0 ..< len(fd.vars) {
				vd := &fd.vars[i]
				if vd.scope_level == 0 && is_var_in_arg_scope(vd) {
					capture_var(fd, vd)
					get_closure_var(s, fd, .local, i, vd.var_name, false, vd.is_lexical, .normal)
				}
			}
		}
		if fd.is_eval {
			for ci in 0 ..< len(fd.closure_var) {
				cv := fd.closure_var[ci]
				get_closure_var(s, fd, .ref, ci, cv.var_name, cv.is_const, cv.is_lexical, cv.var_kind)
			}
		}
	}
}
