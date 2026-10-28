package frontend

// Phase-1 emission helpers and the variable/scope bookkeeping of a function definition (quickjs.c, the block
// from get_prev_opcode to add_private_class_field). The phase-1 stream is plain bytes with QuickJS's opcode
// numbering, temporary opcodes included, because several parser decisions (get_lvalue, set_object_name, the
// call-site rewrites) inspect and patch the last emitted instruction in place.

// Temporary opcodes share the byte space just after OP_nop, as in OPCodeEnum.
OP_TEMP_START :: int(Opcode.nop) + 1
OP_enter_scope :: OP_TEMP_START + int(Temp_Op.enter_scope)
OP_leave_scope :: OP_TEMP_START + int(Temp_Op.leave_scope)
OP_label :: OP_TEMP_START + int(Temp_Op.label)
OP_scope_get_var_undef :: OP_TEMP_START + int(Temp_Op.scope_get_var_undef)
OP_scope_get_var :: OP_TEMP_START + int(Temp_Op.scope_get_var)
OP_scope_put_var :: OP_TEMP_START + int(Temp_Op.scope_put_var)
OP_scope_delete_var :: OP_TEMP_START + int(Temp_Op.scope_delete_var)
OP_scope_make_ref :: OP_TEMP_START + int(Temp_Op.scope_make_ref)
OP_scope_get_ref :: OP_TEMP_START + int(Temp_Op.scope_get_ref)
OP_scope_put_var_init :: OP_TEMP_START + int(Temp_Op.scope_put_var_init)
OP_scope_get_private_field :: OP_TEMP_START + int(Temp_Op.scope_get_private_field)
OP_scope_get_private_field2 :: OP_TEMP_START + int(Temp_Op.scope_get_private_field2)
OP_scope_put_private_field :: OP_TEMP_START + int(Temp_Op.scope_put_private_field)
OP_scope_in_private_field :: OP_TEMP_START + int(Temp_Op.scope_in_private_field)
OP_get_field_opt_chain :: OP_TEMP_START + int(Temp_Op.get_field_opt_chain)
OP_get_array_el_opt_chain :: OP_TEMP_START + int(Temp_Op.get_array_el_opt_chain)
OP_set_class_name :: OP_TEMP_START + int(Temp_Op.set_class_name)
OP_dispose_scope :: OP_TEMP_START + int(Temp_Op.dispose_scope)
OP_source_loc :: OP_TEMP_START + int(Temp_Op.source_loc)
OP_TEMP_END :: OP_TEMP_START + len(Temp_Op)
OP_invalid :: 0

// Commonly used real opcodes as ints, so phase-1 code reads like the C.
O :: proc "contextless" (op: Opcode) -> int {return int(op)}

OP_DEFINE_METHOD_METHOD :: 0
OP_DEFINE_METHOD_GETTER :: 1
OP_DEFINE_METHOD_SETTER :: 2
OP_DEFINE_METHOD_ENUMERABLE :: 4

OP_SPECIAL_OBJECT_ARGUMENTS :: 0
OP_SPECIAL_OBJECT_MAPPED_ARGUMENTS :: 1
OP_SPECIAL_OBJECT_THIS_FUNC :: 2
OP_SPECIAL_OBJECT_NEW_TARGET :: 3
OP_SPECIAL_OBJECT_HOME_OBJECT :: 4
OP_SPECIAL_OBJECT_VAR_OBJECT :: 5
OP_SPECIAL_OBJECT_IMPORT_META :: 6
OP_SPECIAL_OBJECT_NULL_PROTO :: 7

JS_THROW_VAR_RO :: 0
JS_THROW_VAR_REDECL :: 1
JS_THROW_VAR_UNINITIALIZED :: 2
JS_THROW_ERROR_DELETE_SUPER :: 3
JS_THROW_ERROR_ITERATOR_THROW :: 4

JS_DEFINE_CLASS_HAS_HERITAGE :: 1 << 0

DEFINE_GLOBAL_LEX_VAR :: 1 << 7
DEFINE_GLOBAL_FUNC_VAR :: 1 << 6

// Op_Info of any opcode byte in phase-1 / phase-2 streams (temporary opcodes included).
opcode_info_of :: proc(op: int) -> Op_Info {
	if op >= OP_TEMP_START && op < OP_TEMP_END {
		return temp_op_info[Temp_Op(op - OP_TEMP_START)]
	}
	return op_info[Opcode(op)]
}

// short_opcode_info: final-bytecode opcode metadata (short opcodes overlap the temporary range).
short_opcode_info :: #force_inline proc(op: int) -> Op_Info {
	return op_info[Opcode(op)]
}

get_u32 :: #force_inline proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}
get_u16 :: #force_inline proc(b: []u8, at: int) -> u16 {
	return u16(b[at]) | u16(b[at + 1]) << 8
}
put_u32 :: #force_inline proc(b: []u8, at: int, v: u32) {
	b[at] = u8(v); b[at + 1] = u8(v >> 8); b[at + 2] = u8(v >> 16); b[at + 3] = u8(v >> 24)
}
put_u16 :: #force_inline proc(b: []u8, at: int, v: u16) {
	b[at] = u8(v); b[at + 1] = u8(v >> 8)
}

get_prev_opcode :: proc(fd: ^Func_Def) -> int {
	if fd.last_opcode_pos < 0 {return OP_invalid}
	return int(fd.byte_code[fd.last_opcode_pos])
}

js_is_live_code :: proc(s: ^Parse_State) -> bool {
	#partial switch Opcode(get_prev_opcode(s.cur_func)) {
	case .tail_call, .tail_call_method, .ret_, .return_undef, .return_async, .throw_, .throw_error, .goto, .goto8, .goto16, .ret:
		return false
	case:
		return true
	}
}

emit_u8 :: proc(s: ^Parse_State, v: u8) {append(&s.cur_func.byte_code, v)}
emit_u16 :: proc(s: ^Parse_State, v: u16) {append(&s.cur_func.byte_code, u8(v), u8(v >> 8))}
emit_u32 :: proc(s: ^Parse_State, v: u32) {append(&s.cur_func.byte_code, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}

emit_source_loc_at :: proc(s: ^Parse_State, line_num, col_num: int) {
	bc := &s.cur_func.byte_code
	append(bc, u8(OP_source_loc))
	v := u32(line_num); append(bc, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	w := u32(col_num); append(bc, u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24))
}

emit_source_loc :: proc(s: ^Parse_State) {
	emit_source_loc_at(s, s.token.line_num, s.token.col_num)
}

emit_op :: proc(s: ^Parse_State, op: int) {
	fd := s.cur_func
	fd.last_opcode_pos = len(fd.byte_code)
	append(&fd.byte_code, u8(op))
}

emit_atom :: proc(s: ^Parse_State, name: Atom) {emit_u32(s, u32(name))}

update_label :: proc(fd: ^Func_Def, label: int, delta: int) -> int {
	ls := &fd.label_slots[label]
	ls.ref_count += delta
	return ls.ref_count
}

new_label_fd :: proc(fd: ^Func_Def) -> int {
	append(&fd.label_slots, Label_Slot{ref_count = 0, pos = -1, pos2 = -1, addr = -1})
	return len(fd.label_slots) - 1
}

new_label :: proc(s: ^Parse_State) -> int {return new_label_fd(s.cur_func)}

emit_label_raw :: proc(s: ^Parse_State, label: int) {
	emit_u8(s, u8(OP_label))
	emit_u32(s, u32(label))
	s.cur_func.label_slots[label].pos = len(s.cur_func.byte_code)
}

emit_label :: proc(s: ^Parse_State, label: int) -> int {
	if label >= 0 {
		emit_op(s, OP_label)
		emit_u32(s, u32(label))
		s.cur_func.label_slots[label].pos = len(s.cur_func.byte_code)
		return len(s.cur_func.byte_code) - 4
	}
	return -1
}

emit_goto :: proc(s: ^Parse_State, opcode: int, label0: int) -> int {
	label := label0
	if js_is_live_code(s) {
		if label < 0 {label = new_label(s)}
		emit_op(s, opcode)
		emit_u32(s, u32(label))
		s.cur_func.label_slots[label].ref_count += 1
		return label
	}
	return -1
}

cpool_add :: proc(s: ^Parse_State, val: JS_Value) -> int {
	fd := s.cur_func
	append(&fd.cpool, val)
	return len(fd.cpool) - 1
}

emit_push_const :: proc(s: ^Parse_State, val: JS_Value, as_atom: bool) {
	if str, ok := val.(String_Value); ok && as_atom {
		atom := atom_from_string(s.atoms, str)
		if atom != JS_ATOM_NULL && !atom_is_tagged_int(atom) {
			emit_op(s, O(.push_atom_value))
			emit_u32(s, u32(atom))
			return
		}
	}
	idx := cpool_add(s, val)
	emit_op(s, O(.push_const))
	emit_u32(s, u32(idx))
}

// --- variable lookup -------------------------------------------------------------------------------------------

find_arg :: proc(fd: ^Func_Def, name: Atom) -> int {
	for i := len(fd.args) - 1; i >= 0; i -= 1 {
		if fd.args[i].var_name == name {return i | ARGUMENT_VAR_OFFSET}
	}
	return -1
}

// find_var: the function-scope ('var', scope_level 0) variable of that name, else the argument. QuickJS speeds
// this up with a hash index over vars; the answer is the same because a name has at most one scope-0 entry.
find_var :: proc(fd: ^Func_Def, name: Atom) -> int {
	for i := len(fd.vars) - 1; i >= 0; i -= 1 {
		vd := &fd.vars[i]
		if vd.var_name == name && vd.scope_level == 0 {return i}
	}
	return find_arg(fd, name)
}

find_var_in_scope :: proc(fd: ^Func_Def, name: Atom, scope_level: int) -> int {
	for scope_idx := fd.scopes[scope_level].first; scope_idx >= 0; scope_idx = fd.vars[scope_idx].scope_next {
		if fd.vars[scope_idx].scope_level != scope_level {break}
		if fd.vars[scope_idx].var_name == name {return scope_idx}
	}
	return -1
}

is_child_scope :: proc(fd: ^Func_Def, scope0, parent_scope: int) -> bool {
	scope := scope0
	for scope >= 0 {
		if scope == parent_scope {return true}
		scope = fd.scopes[scope].parent
	}
	return false
}

find_var_in_child_scope :: proc(fd: ^Func_Def, name: Atom, scope_level: int) -> int {
	for i in 0 ..< len(fd.vars) {
		vd := &fd.vars[i]
		if vd.var_name == name && vd.scope_level == 0 {
			if is_child_scope(fd, vd.scope_next, scope_level) {return i}
		}
	}
	return -1
}

find_global_var :: proc(fd: ^Func_Def, name: Atom) -> ^Global_Var {
	for &hf in fd.global_vars {
		if hf.var_name == name {return &hf}
	}
	return nil
}

find_lexical_global_var :: proc(fd: ^Func_Def, name: Atom) -> ^Global_Var {
	hf := find_global_var(fd, name)
	if hf != nil && hf.is_lexical {return hf}
	return nil
}

find_lexical_decl :: proc(fd: ^Func_Def, name: Atom, scope_idx0: int, check_catch_var: bool) -> int {
	scope_idx := scope_idx0
	for scope_idx >= 0 {
		vd := &fd.vars[scope_idx]
		if vd.var_name == name && (vd.is_lexical || (vd.var_kind == .catch_ && check_catch_var)) {
			return scope_idx
		}
		scope_idx = vd.scope_next
	}
	if fd.is_eval && fd.eval_type == .global {
		if find_lexical_global_var(fd, name) != nil {return GLOBAL_VAR_OFFSET}
	}
	return -1
}

push_scope :: proc(s: ^Parse_State) -> int {
	if s.cur_func != nil {
		fd := s.cur_func
		scope := len(fd.scopes)
		append(&fd.scopes, Var_Scope{parent = fd.scope_level, first = fd.scope_first, using_label_catch = -1, using_label_end = -1})
		emit_op(s, OP_enter_scope)
		emit_u16(s, u16(scope))
		fd.scope_level = scope
		return scope
	}
	return 0
}

get_first_lexical_var :: proc(fd: ^Func_Def, scope0: int) -> int {
	scope := scope0
	for scope >= 0 {
		scope_idx := fd.scopes[scope].first
		if scope_idx >= 0 {return scope_idx}
		scope = fd.scopes[scope].parent
	}
	return -1
}

pop_scope :: proc(s: ^Parse_State) {
	if s.cur_func != nil {
		fd := s.cur_func
		scope := fd.scope_level
		emit_op(s, OP_leave_scope)
		emit_u16(s, u16(scope))
		fd.scope_level = fd.scopes[scope].parent
		fd.scope_first = get_first_lexical_var(fd, fd.scope_level)
	}
}

close_scopes :: proc(s: ^Parse_State, scope0, scope_stop: int) {
	scope := scope0
	for scope > scope_stop {
		emit_op(s, OP_leave_scope)
		emit_u16(s, u16(scope))
		scope = s.cur_func.scopes[scope].parent
	}
}

add_var :: proc(s: ^Parse_State, fd: ^Func_Def, name: Atom) -> int {
	if len(fd.vars) >= JS_MAX_LOCAL_VARS {
		js_parse_error(s, "too many variables declared (only 65534 allowed)")
		return -1
	}
	append(&fd.vars, Var_Def{var_name = name, func_pool_idx = -1})
	return len(fd.vars) - 1
}

add_scope_var :: proc(s: ^Parse_State, fd: ^Func_Def, name: Atom, var_kind: Var_Kind) -> int {
	idx := add_var(s, fd, name)
	if idx >= 0 {
		vd := &fd.vars[idx]
		vd.var_kind = var_kind
		vd.scope_level = fd.scope_level
		vd.scope_next = fd.scope_first
		fd.scopes[fd.scope_level].first = idx
		fd.scope_first = idx
	}
	return idx
}

add_func_var :: proc(s: ^Parse_State, fd: ^Func_Def, name: Atom) -> int {
	idx := fd.func_var_idx
	if idx < 0 {
		idx = add_var(s, fd, name)
		if idx >= 0 {
			fd.func_var_idx = idx
			fd.vars[idx].var_kind = .function_name
			if fd.is_strict_mode {fd.vars[idx].is_const = true}
		}
	}
	return idx
}

add_arguments_var :: proc(s: ^Parse_State, fd: ^Func_Def) -> int {
	idx := fd.arguments_var_idx
	if idx < 0 {
		idx = add_var(s, fd, A_arguments)
		if idx >= 0 {fd.arguments_var_idx = idx}
	}
	return idx
}

add_arguments_arg :: proc(s: ^Parse_State, fd: ^Func_Def) -> int {
	if fd.arguments_arg_idx < 0 {
		idx := find_var_in_scope(fd, A_arguments, ARG_SCOPE_INDEX)
		if idx < 0 {
			idx = add_var(s, fd, A_arguments)
			if idx < 0 {return -1}
			fd.vars[idx].scope_next = fd.scopes[ARG_SCOPE_INDEX].first
			fd.scopes[ARG_SCOPE_INDEX].first = idx
			fd.vars[idx].scope_level = ARG_SCOPE_INDEX
			fd.vars[idx].is_lexical = true
			fd.arguments_arg_idx = idx
		}
	}
	return 0
}

add_arg :: proc(s: ^Parse_State, fd: ^Func_Def, name: Atom) -> int {
	if len(fd.args) >= JS_MAX_LOCAL_VARS {
		js_parse_error(s, "too many parameters in function definition (only 65534 allowed)")
		return -1
	}
	append(&fd.args, Var_Def{var_name = name, func_pool_idx = -1})
	return len(fd.args) - 1
}

add_global_var :: proc(fd: ^Func_Def, name: Atom) -> ^Global_Var {
	append(&fd.global_vars, Global_Var{cpool_idx = -1, scope_level = fd.scope_level, var_name = name})
	return &fd.global_vars[len(fd.global_vars) - 1]
}

Var_Def_Type :: enum u8 {
	with_,
	let_,
	const_,
	function_decl,
	new_function_decl,
	catch_,
	var_,
	using_,
}

define_var :: proc(s: ^Parse_State, fd: ^Func_Def, name: Atom, var_def_type: Var_Def_Type) -> int {
	idx: int
	switch var_def_type {
	case .with_:
		idx = add_scope_var(s, fd, name, .normal)
	case .let_, .const_, .using_, .function_decl, .new_function_decl:
		idx = find_lexical_decl(fd, name, fd.scope_first, true)
		if idx >= 0 {
			if idx < GLOBAL_VAR_OFFSET {
				if fd.vars[idx].scope_level == fd.scope_level {
					if !(!fd.is_strict_mode && var_def_type == .function_decl && fd.vars[idx].var_kind == .function_decl) {
						js_parse_error(s, "invalid redefinition of lexical identifier")
						return -1
					}
				} else if fd.vars[idx].var_kind == .catch_ && (fd.vars[idx].scope_level + 2) == fd.scope_level {
					js_parse_error(s, "invalid redefinition of lexical identifier")
					return -1
				}
			} else {
				if fd.scope_level == fd.body_scope {
					js_parse_error(s, "invalid redefinition of lexical identifier")
					return -1
				}
			}
		}
		if var_def_type != .function_decl && var_def_type != .new_function_decl && fd.scope_level == fd.body_scope && find_arg(fd, name) >= 0 {
			js_parse_error(s, "invalid redefinition of parameter name")
			return -1
		}
		if find_var_in_child_scope(fd, name, fd.scope_level) >= 0 {
			js_parse_error(s, "invalid redefinition of a variable")
			return -1
		}
		if fd.is_global_var {
			hf := find_global_var(fd, name)
			if hf != nil && is_child_scope(fd, hf.scope_level, fd.scope_level) {
				js_parse_error(s, "invalid redefinition of global identifier")
				return -1
			}
		}
		if fd.is_eval && (fd.eval_type == .global || fd.eval_type == .module) && fd.scope_level == fd.body_scope && var_def_type != .using_ {
			hf := add_global_var(fd, name)
			hf.is_lexical = true
			hf.is_const = var_def_type == .const_
			idx = GLOBAL_VAR_OFFSET
		} else {
			var_kind: Var_Kind
			#partial switch var_def_type {
			case .function_decl: var_kind = .function_decl
			case .new_function_decl: var_kind = .new_function_decl
			case .using_: var_kind = .using_
			case: var_kind = .normal
			}
			idx = add_scope_var(s, fd, name, var_kind)
			if idx >= 0 {
				vd := &fd.vars[idx]
				vd.is_lexical = true
				vd.is_const = var_def_type == .const_ || var_def_type == .using_
			}
		}
	case .catch_:
		idx = add_scope_var(s, fd, name, .catch_)
	case .var_:
		if find_lexical_decl(fd, name, fd.scope_first, false) >= 0 {
			js_parse_error(s, "invalid redefinition of lexical identifier")
			return -1
		}
		if fd.is_global_var {
			hf := find_global_var(fd, name)
			if hf != nil && hf.is_lexical && hf.scope_level == fd.scope_level && fd.eval_type == .module {
				js_parse_error(s, "invalid redefinition of lexical identifier")
				return -1
			}
			add_global_var(fd, name)
			idx = GLOBAL_VAR_OFFSET
		} else {
			idx = find_var(fd, name)
			if idx >= 0 {break}
			idx = add_var(s, fd, name)
			if idx >= 0 {
				if name == A_arguments && fd.has_arguments_binding {
					fd.arguments_var_idx = idx
				}
				fd.vars[idx].scope_next = fd.scope_level
			}
		}
	}
	return idx
}

add_private_class_field :: proc(s: ^Parse_State, fd: ^Func_Def, name: Atom, var_kind: Var_Kind, is_static: bool) -> int {
	idx := add_scope_var(s, fd, name, var_kind)
	if idx < 0 {return idx}
	vd := &fd.vars[idx]
	vd.is_lexical = true
	vd.is_const = true
	vd.is_static_private = is_static
	return idx
}
