package frontend

// Expressions, part 2: destructuring patterns, postfix chains (member access, calls, optional chaining), unary
// and binary operators, assignment, and the break/return helpers they share with statements.

// js_parse_destructuring_element returns -1 on error, 0 if no initializer, 1 if a top-level initializer exists.
js_parse_destructuring_element :: proc(s: ^Parse_State, tok: int, is_arg: bool, hasval: bool, has_ellipsis0: int, allow_initializer: bool, export_flag: bool) -> int {
	has_ellipsis := has_ellipsis0
	label_lvalue := -1
	depth_lvalue := 0
	opcode, scope: int
	prop_name, var_name: Atom
	skip_bits: int

	if has_ellipsis < 0 {
		js_parse_skip_parens_token(s, &skip_bits, false)
		has_ellipsis = skip_bits & SKIP_HAS_ELLIPSIS
	}

	label_parse := new_label(s)
	label_assign := new_label(s)

	start_addr := len(s.cur_func.byte_code)
	if hasval {
		emit_op(s, O(.dup))
		emit_op(s, O(.undefined))
		emit_op(s, O(.strict_eq))
		emit_goto(s, O(.if_true), label_parse)
		emit_label(s, label_assign)
	} else {
		emit_goto(s, O(.goto), label_parse)
		emit_label(s, label_assign)
		emit_op(s, O(.dup))
	}
	assign_addr := len(s.cur_func.byte_code)
	if s.token.val == '{' {
		if next_token(s) {return -1}
		emit_op(s, O(.to_object))
		if has_ellipsis != 0 {
			emit_op(s, O(.object))
			emit_op(s, O(.swap))
		}
		for s.token.val != '}' {
			set_val := false
			if s.token.val == TOK_ELLIPSIS {
				if has_ellipsis == 0 {
					js_parse_error(s, "unexpected ellipsis token")
					return -1
				}
				if next_token(s) {return -1}
				if tok != 0 {
					var_name = js_parse_destructuring_var(s, tok, is_arg)
					if var_name == JS_ATOM_NULL {return -1}
					opcode = OP_scope_get_var
					scope = s.cur_func.scope_level
					label_lvalue = -1
					depth_lvalue = 0
				} else {
					if js_parse_left_hand_side_expr(s) {return -1}
					if get_lvalue(s, &opcode, &scope, &var_name, &label_lvalue, &depth_lvalue, false, '{') {return -1}
				}
				if s.token.val != '}' {
					js_parse_error(s, "assignment rest property must be last")
					return -1
				}
				emit_op(s, O(.object))
				emit_op(s, O(.copy_data_properties))
				emit_u8(s, u8(0 | ((depth_lvalue + 1) << 2) | ((depth_lvalue + 2) << 5)))
				set_val = true
			}
			if !set_val {
				prop_type := js_parse_property_name(s, &prop_name, false, true, false)
				if prop_type < 0 {return -1}
				var_name = JS_ATOM_NULL
				opcode = OP_scope_get_var
				scope = s.cur_func.scope_level
				label_lvalue = -1
				depth_lvalue = 0
				if prop_type == PROP_TYPE_IDENT {
					if next_token(s) {return -1}
					is_pattern := false
					if s.token.val == '[' || s.token.val == '{' {
						tok1 := js_parse_skip_parens_token(s, &skip_bits, false)
						is_pattern = tok1 == ',' || tok1 == '=' || tok1 == '}'
					}
					if is_pattern {
						if prop_name == JS_ATOM_NULL {
							if has_ellipsis != 0 {
								emit_op(s, O(.to_propkey))
								emit_op(s, O(.perm3))
								emit_op(s, O(.null))
								emit_op(s, O(.define_array_el))
								emit_op(s, O(.perm3))
							}
							emit_op(s, O(.get_array_el2))
						} else {
							if has_ellipsis != 0 {
								emit_op(s, O(.swap))
								emit_op(s, O(.null))
								emit_op(s, O(.define_field))
								emit_atom(s, prop_name)
								emit_op(s, O(.swap))
							}
							emit_op(s, O(.get_field2))
							emit_u32(s, u32(prop_name))
						}
						if js_parse_destructuring_element(s, tok, is_arg, true, -1, true, export_flag) < 0 {return -1}
						if s.token.val == '}' {break}
						if js_parse_expect(s, ',') {return -1}
						continue
					}
					if prop_name == JS_ATOM_NULL {
						emit_op(s, O(.to_propkey2))
						if has_ellipsis != 0 {
							emit_op(s, O(.perm3))
							emit_op(s, O(.null))
							emit_op(s, O(.define_array_el))
							emit_op(s, O(.perm3))
						}
						emit_op(s, O(.dup1))
					} else {
						if has_ellipsis != 0 {
							emit_op(s, O(.swap))
							emit_op(s, O(.null))
							emit_op(s, O(.define_field))
							emit_atom(s, prop_name)
							emit_op(s, O(.swap))
						}
						emit_op(s, O(.dup))
					}
					if tok != 0 {
						var_name = js_parse_destructuring_var(s, tok, is_arg)
						if var_name == JS_ATOM_NULL {return -1}
					} else {
						if js_parse_left_hand_side_expr(s) {return -1}
						if destructuring_lvalue(s, prop_name, &opcode, &scope, &var_name, &label_lvalue, &depth_lvalue) {return -1}
					}
					if prop_name == JS_ATOM_NULL {
						emit_op(s, O(.get_array_el))
					} else {
						emit_op(s, O(.get_field))
						emit_u32(s, u32(prop_name))
					}
				} else {
					// PROP_TYPE_VAR: shorthand, never computed
					if is_arg && js_parse_check_duplicate_parameter(s, prop_name) {return -1}
					if s.cur_func.is_strict_mode && (prop_name == A_eval || prop_name == A_arguments) {
						js_parse_error(s, "invalid destructuring target")
						return -1
					}
					if has_ellipsis != 0 {
						emit_op(s, O(.swap))
						emit_op(s, O(.null))
						emit_op(s, O(.define_field))
						emit_atom(s, prop_name)
						emit_op(s, O(.swap))
					}
					if tok == 0 || tok == TOK_VAR {
						emit_op(s, O(.dup))
						emit_op(s, OP_scope_get_var)
						emit_atom(s, prop_name)
						emit_u16(s, u16(s.cur_func.scope_level))
						if destructuring_lvalue(s, prop_name, &opcode, &scope, &var_name, &label_lvalue, &depth_lvalue) {return -1}
						emit_op(s, O(.get_field))
						emit_u32(s, u32(prop_name))
					} else {
						var_name = prop_name
						emit_op(s, O(.get_field2))
						emit_u32(s, u32(prop_name))
					}
				}
			}
			// set_val:
			if tok != 0 {
				if js_define_var(s, var_name, tok) {return -1}
				if export_flag {
					if add_export_entry(s, s.cur_func.module, var_name, var_name, .local) {return -1}
				}
				scope = s.cur_func.scope_level
			}
			if s.token.val == '=' {
				emit_op(s, O(.dup))
				emit_op(s, O(.undefined))
				emit_op(s, O(.strict_eq))
				label_hasval := emit_goto(s, O(.if_false), -1)
				if next_token(s) {return -1}
				emit_op(s, O(.drop))
				if js_parse_assign_expr(s) {return -1}
				if opcode == OP_scope_get_var || opcode == O(.get_ref_value) {
					set_object_name(s, var_name)
				}
				emit_label(s, label_hasval)
			}
			put_lvalue(s, opcode, scope, var_name, label_lvalue, .nokeep_depth, tok == TOK_CONST || tok == TOK_LET)
			if s.token.val == '}' {break}
			if js_parse_expect(s, ',') {return -1}
		}
		emit_op(s, O(.drop))
		if has_ellipsis != 0 {
			emit_op(s, O(.drop))
		}
		if next_token(s) {return -1}
	} else if s.token.val == '[' {
		block_env: Block_Env
		source_line_num := s.token.line_num
		source_col_num := s.token.col_num
		if next_token(s) {return -1}
		push_break_entry(s.cur_func, &block_env, JS_ATOM_NULL, -1, -1, 2)
		block_env.has_iterator = true
		emit_op(s, O(.for_of_start))
		has_spread := false
		for s.token.val != ']' {
			if s.token.val == TOK_ELLIPSIS {
				if next_token(s) {return -1}
				if s.token.val == ',' || s.token.val == ']' {
					js_parse_error(s, "missing binding pattern...")
					return -1
				}
				has_spread = true
			}
			tok1 := 0
			is_pattern := false
			if s.token.val != ',' && (s.token.val == '[' || s.token.val == '{') {
				tok1 = js_parse_skip_parens_token(s, &skip_bits, false)
				is_pattern = tok1 == ',' || tok1 == '=' || tok1 == ']'
			}
			if s.token.val == ',' {
				emit_op(s, O(.for_of_next))
				emit_u8(s, 0)
				emit_op(s, O(.drop))
				emit_op(s, O(.drop))
			} else if is_pattern {
				if has_spread {
					if tok1 == '=' {
						js_parse_error(s, "rest element cannot have a default value")
						return -1
					}
					js_emit_spread_code(s, 0)
				} else {
					emit_op(s, O(.for_of_next))
					emit_u8(s, 0)
					emit_op(s, O(.drop))
				}
				if js_parse_destructuring_element(s, tok, is_arg, true, skip_bits & SKIP_HAS_ELLIPSIS, true, export_flag) < 0 {return -1}
			} else {
				var_name = JS_ATOM_NULL
				enum_depth := 0
				if tok != 0 {
					var_name = js_parse_destructuring_var(s, tok, is_arg)
					if var_name == JS_ATOM_NULL {return -1}
					if js_define_var(s, var_name, tok) {return -1}
					if export_flag {
						if add_export_entry(s, s.cur_func.module, var_name, var_name, .local) {return -1}
					}
					opcode = OP_scope_get_var
					scope = s.cur_func.scope_level
				} else {
					if js_parse_left_hand_side_expr(s) {return -1}
					if get_lvalue(s, &opcode, &scope, &var_name, &label_lvalue, &enum_depth, false, '[') {return -1}
				}
				if has_spread {
					js_emit_spread_code(s, enum_depth)
				} else {
					emit_op(s, O(.for_of_next))
					emit_u8(s, u8(enum_depth))
					emit_op(s, O(.drop))
				}
				if s.token.val == '=' && !has_spread {
					emit_op(s, O(.dup))
					emit_op(s, O(.undefined))
					emit_op(s, O(.strict_eq))
					label_hasval := emit_goto(s, O(.if_false), -1)
					if next_token(s) {return -1}
					emit_op(s, O(.drop))
					if js_parse_assign_expr(s) {return -1}
					if opcode == OP_scope_get_var || opcode == O(.get_ref_value) {
						set_object_name(s, var_name)
					}
					emit_label(s, label_hasval)
				}
				put_lvalue(s, opcode, scope, var_name, label_lvalue, .nokeep_depth, tok == TOK_CONST || tok == TOK_LET)
			}
			if s.token.val == ']' {break}
			if has_spread {
				js_parse_error(s, "rest element must be the last one")
				return -1
			}
			if js_parse_expect(s, ',') {return -1}
		}
		emit_source_loc_at(s, source_line_num, source_col_num)
		emit_op(s, O(.iterator_close))
		pop_break_entry(s.cur_func)
		if next_token(s) {return -1}
	} else {
		js_parse_error(s, "invalid assignment syntax")
		return -1
	}
	has_initializer := 0
	if s.token.val == '=' && allow_initializer {
		label_done := emit_goto(s, O(.goto), -1)
		if next_token(s) {return -1}
		emit_label(s, label_parse)
		if hasval {emit_op(s, O(.drop))}
		if js_parse_assign_expr(s) {return -1}
		emit_goto(s, O(.goto), label_assign)
		emit_label(s, label_done)
		has_initializer = 1
	} else {
		if !hasval {
			js_parse_error(s, "too complicated destructuring expression")
			return -1
		}
		bc := s.cur_func.byte_code[:]
		for i in start_addr ..< assign_addr {bc[i] = u8(O(.nop))}
		s.cur_func.label_slots[label_parse].ref_count -= 1
	}
	return has_initializer
}

// destructuring_lvalue: the `lvalue:` block of js_parse_destructuring_element (get_lvalue + stack swap).
@(private = "file")
destructuring_lvalue :: proc(s: ^Parse_State, prop_name: Atom, opcode, scope: ^int, var_name: ^Atom, label_lvalue, depth_lvalue: ^int) -> bool {
	if get_lvalue(s, opcode, scope, var_name, label_lvalue, depth_lvalue, false, '{') {return true}
	if prop_name == JS_ATOM_NULL {
		switch depth_lvalue^ {
		case 1: emit_op(s, O(.rot3r))
		case 2: emit_op(s, O(.swap2))
		case 3:
			emit_op(s, O(.rot5l))
			emit_op(s, O(.rot5l))
		}
	} else {
		switch depth_lvalue^ {
		case 1: emit_op(s, O(.swap))
		case 2: emit_op(s, O(.rot3l))
		case 3: emit_op(s, O(.rot4l))
		}
	}
	return false
}

optional_chain_test :: proc(s: ^Parse_State, poptional_chaining_label: ^int, drop_count: int) {
	if poptional_chaining_label^ < 0 {
		poptional_chaining_label^ = new_label(s)
	}
	emit_op(s, O(.dup))
	emit_op(s, O(.is_undefined_or_null))
	label_next := emit_goto(s, O(.if_false), -1)
	for _ in 0 ..< drop_count {emit_op(s, O(.drop))}
	emit_op(s, O(.undefined))
	emit_goto(s, O(.goto), poptional_chaining_label^)
	emit_label(s, label_next)
}

js_parse_left_hand_side_expr :: proc(s: ^Parse_State) -> bool {
	return js_parse_postfix_expr(s, PF_POSTFIX_CALL)
}

js_parse_postfix_expr :: proc(s: ^Parse_State, parse_flags: int) -> bool {
	s.depth += 1
	defer s.depth -= 1
	if s.depth > s.max_depth || stack_exhausted(s.stack) {
		return js_parse_error(s, "stack overflow")
	}
	call_type := Func_Call_Type.normal
	accept_lparen := (parse_flags & PF_POSTFIX_CALL) != 0

	switch s.token.val {
	case TOK_NUMBER:
		#partial switch v in s.token.num {
		case i32:
			emit_op(s, O(.push_i32))
			emit_u32(s, u32(v))
		case Big_Int:
			if len(v.limbs) == 1 {
				emit_op(s, O(.push_bigint_i32))
				emit_u32(s, v.limbs[0])
			} else {
				emit_push_const(s, s.token.num, false)
			}
		case:
			emit_push_const(s, s.token.num, false)
		}
		if next_token(s) {return true}
	case TOK_TEMPLATE:
		if js_parse_template(s, false, nil) {return true}
	case TOK_STRING:
		emit_push_const(s, s.token.str, true)
		if next_token(s) {return true}
	case TOK_DIV_ASSIGN, '/':
		s.buf_ptr -= s.token.val == '/' ? 1 : 2
		if js_parse_regexp(s) {return true}
		emit_push_const(s, s.token.re_body, false)
		bc, ok := compile_regexp_literal(s, s.token.re_body, s.token.re_flags)
		if !ok {return true}
		emit_push_const(s, bc, false)
		emit_op(s, O(.regexp))
		if next_token(s) {return true}
	case '(':
		if js_parse_expr_paren(s) {return true}
	case TOK_FUNCTION:
		if js_parse_function_decl(s, .expr, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num) {return true}
	case TOK_CLASS:
		if js_parse_class(s, true, .none) {return true}
	case TOK_NULL:
		if next_token(s) {return true}
		emit_op(s, O(.null))
	case TOK_THIS:
		if next_token(s) {return true}
		emit_op(s, OP_scope_get_var)
		emit_atom(s, A_this)
		emit_u16(s, 0)
	case TOK_FALSE:
		if next_token(s) {return true}
		emit_op(s, O(.push_false))
	case TOK_TRUE:
		if next_token(s) {return true}
		emit_op(s, O(.push_true))
	case TOK_IDENT:
		identifier_line_num := s.token.line_num
		identifier_col_num := s.token.ptr - s.line_start + 1
		if s.token.is_reserved {
			return js_parse_error_reserved_identifier(s)
		}
		name: Atom
		if token_is_pseudo_keyword(s, A_async) && peek_token(s, true) != '\n' {
			source_ptr := s.token.ptr
			source_line_num := s.token.line_num
			source_col_num := s.token.col_num
			if next_token(s) {return true}
			if s.token.val == TOK_FUNCTION {
				if js_parse_function_decl(s, .expr, .async, JS_ATOM_NULL, source_ptr, source_line_num, source_col_num) {return true}
				break
			}
			name = A_async
		} else {
			if s.token.atom == A_arguments && !s.cur_func.arguments_allowed {
				return js_parse_error(s, "'arguments' identifier is not allowed in class field initializer")
			}
			name = s.token.atom
			if next_token(s) {return true}
		}
		emit_source_loc_at(s, identifier_line_num, identifier_col_num)
		emit_op(s, OP_scope_get_var)
		emit_u32(s, u32(name))
		emit_u16(s, u16(s.cur_func.scope_level))
	case '{', '[':
		skip_bits: int
		if js_parse_skip_parens_token(s, &skip_bits, false) == '=' {
			if js_parse_destructuring_element(s, 0, false, false, skip_bits & SKIP_HAS_ELLIPSIS, true, false) < 0 {return true}
		} else {
			if s.token.val == '{' {
				if js_parse_object_literal(s) {return true}
			} else {
				if js_parse_array_literal(s) {return true}
			}
		}
	case TOK_NEW:
		if next_token(s) {return true}
		if s.token.val == '.' {
			if next_token(s) {return true}
			if !token_is_pseudo_keyword(s, A_target) {
				return js_parse_error(s, "expecting target")
			}
			if !s.cur_func.new_target_allowed {
				return js_parse_error(s, "new.target only allowed within functions")
			}
			if next_token(s) {return true}
			emit_op(s, OP_scope_get_var)
			emit_atom(s, A_new_target)
			emit_u16(s, 0)
		} else {
			emit_source_loc(s)
			if js_parse_postfix_expr(s, 0) {return true}
			accept_lparen = true
			if s.token.val != '(' {
				emit_op(s, O(.dup))
				emit_op(s, O(.call_constructor))
				emit_u16(s, 0)
			} else {
				call_type = .new_
			}
		}
	case TOK_SUPER:
		if next_token(s) {return true}
		if s.token.val == '(' {
			if !s.cur_func.super_call_allowed {
				return js_parse_error(s, "super() is only valid in a derived class constructor")
			}
			call_type = .super_ctor
		} else if s.token.val == '.' || s.token.val == '[' {
			if !s.cur_func.super_allowed {
				return js_parse_error(s, "'super' is only valid in a method")
			}
			emit_op(s, OP_scope_get_var)
			emit_atom(s, A_this)
			emit_u16(s, 0)
			emit_op(s, OP_scope_get_var)
			emit_atom(s, A_home_object)
			emit_u16(s, 0)
			emit_op(s, O(.get_super))
		} else {
			return js_parse_error(s, "invalid use of 'super'")
		}
	case TOK_IMPORT:
		if next_token(s) {return true}
		if s.token.val == '.' {
			if next_token(s) {return true}
			if !token_is_pseudo_keyword(s, A_meta) {
				return js_parse_error(s, "meta expected")
			}
			if !s.is_module {
				return js_parse_error(s, "import.meta only valid in module code")
			}
			if next_token(s) {return true}
			emit_op(s, O(.special_object))
			emit_u8(s, OP_SPECIAL_OBJECT_IMPORT_META)
		} else {
			if js_parse_expect(s, '(') {return true}
			if !accept_lparen {
				return js_parse_error(s, "invalid use of 'import()'")
			}
			if js_parse_assign_expr(s) {return true}
			if s.token.val == ',' {
				if next_token(s) {return true}
				if s.token.val != ')' {
					if js_parse_assign_expr(s) {return true}
					if s.token.val == ',' {
						if next_token(s) {return true}
					}
				} else {
					emit_op(s, O(.undefined))
				}
			} else {
				emit_op(s, O(.undefined))
			}
			if js_parse_expect(s, ')') {return true}
			emit_op(s, O(.import_))
		}
	case:
		end := max(s.buf_ptr, s.token.ptr)
		return js_parse_error(s, "unexpected token in expression: '", string(s.buf[s.token.ptr:end]), "'")
	}

	optional_chaining_label := -1
	for {
		fd := s.cur_func
		has_optional_chain := false
		Step :: enum {none, func_call, func_call2, property, array_access}
		step := Step.none

		if s.token.val == TOK_QUESTION_MARK_DOT {
			if next_token(s) {return true}
			has_optional_chain = true
			if s.token.val == '(' && accept_lparen {
				step = .func_call
			} else if s.token.val == '[' {
				step = .array_access
			} else {
				step = .property
			}
		} else if s.token.val == TOK_TEMPLATE && call_type == .normal {
			if optional_chaining_label >= 0 {
				return js_parse_error(s, "template literal cannot appear in an optional chain")
			}
			call_type = .template
			step = .func_call2
		} else if s.token.val == '(' && accept_lparen {
			step = .func_call
		} else if s.token.val == '.' {
			if next_token(s) {return true}
			step = .property
		} else if s.token.val == '[' {
			step = .array_access
		} else {
			break
		}

		switch step {
		case .none:
		case .func_call, .func_call2:
			opcode := OP_invalid
			arg_count := 0
			drop_count: int
			if step == .func_call {
				if next_token(s) {return true}
			}
			if step == .func_call2 || call_type == .normal {
				emit_source_loc(s)
				opcode = get_prev_opcode(fd)
				switch opcode {
				case O(.get_field):
					fd.byte_code[fd.last_opcode_pos] = u8(O(.get_field2))
					drop_count = 2
				case OP_get_field_opt_chain:
					opt_chain_label := int(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1 + 4 + 1))
					fd.byte_code[fd.last_opcode_pos] = u8(O(.get_field2))
					resize(&fd.byte_code, fd.last_opcode_pos + 1 + 4)
					next_label := emit_goto(s, O(.goto), -1)
					emit_label(s, opt_chain_label)
					emit_op(s, O(.undefined))
					emit_label(s, next_label)
					drop_count = 2
					opcode = O(.get_field)
				case OP_scope_get_private_field:
					fd.byte_code[fd.last_opcode_pos] = u8(OP_scope_get_private_field2)
					drop_count = 2
				case O(.get_array_el):
					fd.byte_code[fd.last_opcode_pos] = u8(O(.get_array_el2))
					drop_count = 2
				case OP_get_array_el_opt_chain:
					opt_chain_label := int(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1 + 1))
					fd.byte_code[fd.last_opcode_pos] = u8(O(.get_array_el2))
					resize(&fd.byte_code, fd.last_opcode_pos + 1)
					next_label := emit_goto(s, O(.goto), -1)
					emit_label(s, opt_chain_label)
					emit_op(s, O(.undefined))
					emit_label(s, next_label)
					drop_count = 2
					opcode = O(.get_array_el)
				case OP_scope_get_var:
					name := Atom(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
					scope := int(get_u16(fd.byte_code[:], fd.last_opcode_pos + 5))
					if name == A_eval && call_type == .normal && !has_optional_chain {
						opcode = O(.eval)
					} else {
						if has_with_scope(fd, scope) {
							opcode = OP_scope_get_ref
							fd.byte_code[fd.last_opcode_pos] = u8(opcode)
						}
					}
					drop_count = 1
				case O(.get_super_value):
					fd.byte_code[fd.last_opcode_pos] = u8(O(.get_array_el))
					opcode = O(.get_array_el)
					drop_count = 2
				case:
					opcode = OP_invalid
					drop_count = 1
				}
				if has_optional_chain {
					optional_chain_test(s, &optional_chaining_label, drop_count)
				}
			} else {
				opcode = OP_invalid
			}

			emit_call := false
			if call_type == .template {
				if js_parse_template(s, true, &arg_count) {return true}
				emit_call = true
			} else if call_type == .super_ctor {
				emit_op(s, OP_scope_get_var)
				emit_atom(s, A_this_active_func)
				emit_u16(s, 0)
				emit_op(s, O(.get_super))
				emit_op(s, OP_scope_get_var)
				emit_atom(s, A_new_target)
				emit_u16(s, 0)
			} else if call_type == .new_ {
				emit_op(s, O(.dup))
			}

			if !emit_call {
				arg_count = 0
				for s.token.val != ')' {
					if arg_count >= 65535 {
						return js_parse_error(s, "Too many arguments in function call (only 65534 allowed)")
					}
					if s.token.val == TOK_ELLIPSIS {break}
					if js_parse_assign_expr(s) {return true}
					arg_count += 1
					if s.token.val == ')' {break}
					if js_parse_expect(s, ',') {return true}
				}
				if s.token.val == TOK_ELLIPSIS {
					emit_op(s, O(.array_from))
					emit_u16(s, u16(arg_count))
					emit_op(s, O(.push_i32))
					emit_u32(s, u32(arg_count))
					for s.token.val != ')' {
						if s.token.val == TOK_ELLIPSIS {
							if next_token(s) {return true}
							if js_parse_assign_expr(s) {return true}
							emit_op(s, O(.append))
						} else {
							if js_parse_assign_expr(s) {return true}
							emit_op(s, O(.define_array_el))
							emit_op(s, O(.inc))
						}
						if s.token.val == ')' {break}
						if js_parse_expect(s, ',') {return true}
					}
					if next_token(s) {return true}
					emit_op(s, O(.drop))
					switch opcode {
					case O(.get_field), OP_scope_get_private_field, O(.get_array_el), OP_scope_get_ref:
						emit_op(s, O(.perm3))
						emit_op(s, O(.apply))
						emit_u16(s, call_type == .new_ ? 1 : 0)
					case O(.eval):
						emit_op(s, O(.apply_eval))
						emit_u16(s, u16(fd.scope_level))
						fd.has_eval_call = true
					case:
						if call_type == .super_ctor {
							emit_op(s, O(.apply))
							emit_u16(s, 1)
							emit_op(s, O(.dup))
							emit_op(s, OP_scope_put_var_init)
							emit_atom(s, A_this)
							emit_u16(s, 0)
							emit_class_field_init(s)
						} else if call_type == .new_ {
							emit_op(s, O(.perm3))
							emit_op(s, O(.apply))
							emit_u16(s, 1)
						} else {
							emit_op(s, O(.undefined))
							emit_op(s, O(.swap))
							emit_op(s, O(.apply))
							emit_u16(s, 0)
						}
					}
				} else {
					if next_token(s) {return true}
					emit_call = true
				}
			}
			if emit_call {
				switch opcode {
				case O(.get_field), OP_scope_get_private_field, O(.get_array_el), OP_scope_get_ref:
					emit_op(s, O(.call_method))
					emit_u16(s, u16(arg_count))
				case O(.eval):
					emit_op(s, O(.eval))
					emit_u16(s, u16(arg_count))
					emit_u16(s, u16(fd.scope_level))
					fd.has_eval_call = true
				case:
					if call_type == .super_ctor {
						emit_op(s, O(.call_constructor))
						emit_u16(s, u16(arg_count))
						emit_op(s, O(.dup))
						emit_op(s, OP_scope_put_var_init)
						emit_atom(s, A_this)
						emit_u16(s, 0)
						emit_class_field_init(s)
					} else if call_type == .new_ {
						emit_op(s, O(.call_constructor))
						emit_u16(s, u16(arg_count))
					} else {
						emit_op(s, O(.call))
						emit_u16(s, u16(arg_count))
					}
				}
			}
			call_type = .normal
		case .property:
			if s.token.val == TOK_PRIVATE_NAME {
				if get_prev_opcode(fd) == O(.get_super) {
					return js_parse_error(s, "private class field forbidden after super")
				}
				if has_optional_chain {
					optional_chain_test(s, &optional_chaining_label, 1)
				}
				emit_op(s, OP_scope_get_private_field)
				emit_atom(s, s.token.atom)
				emit_u16(s, u16(s.cur_func.scope_level))
			} else {
				if !token_is_ident(s.token.val) {
					return js_parse_error(s, "expecting field name")
				}
				if get_prev_opcode(fd) == O(.get_super) {
					emit_push_const(s, atom_to_string(s.atoms, s.token.atom), true)
					emit_op(s, O(.get_super_value))
				} else {
					if has_optional_chain {
						optional_chain_test(s, &optional_chaining_label, 1)
					}
					emit_op(s, O(.get_field))
					emit_atom(s, s.token.atom)
				}
			}
			if next_token(s) {return true}
		case .array_access:
			prev_op := get_prev_opcode(fd)
			if has_optional_chain {
				optional_chain_test(s, &optional_chaining_label, 1)
			}
			if next_token(s) {return true}
			if js_parse_expr(s) {return true}
			if js_parse_expect(s, ']') {return true}
			if prev_op == O(.get_super) {
				emit_op(s, O(.get_super_value))
			} else {
				emit_op(s, O(.get_array_el))
			}
		}
	}
	if optional_chaining_label >= 0 {
		fd := s.cur_func
		emit_label_raw(s, optional_chaining_label)
		opcode := get_prev_opcode(fd)
		if opcode == O(.get_field) || opcode == O(.get_array_el) {
			fd.byte_code[fd.last_opcode_pos] = u8(opcode == O(.get_field) ? OP_get_field_opt_chain : OP_get_array_el_opt_chain)
		} else {
			fd.last_opcode_pos = -1
		}
	}
	return false
}

js_parse_delete :: proc(s: ^Parse_State) -> bool {
	fd := s.cur_func
	if next_token(s) {return true}
	if js_parse_unary(s, PF_POW_FORBIDDEN) {return true}
	opcode := get_prev_opcode(fd)
	switch opcode {
	case O(.get_field), OP_get_field_opt_chain:
		opt_chain_label := -1
		if opcode == OP_get_field_opt_chain {
			opt_chain_label = int(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1 + 4 + 1))
		}
		name := Atom(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		resize(&fd.byte_code, fd.last_opcode_pos)
		emit_push_const(s, atom_to_string(s.atoms, name), true)
		emit_op(s, O(.delete_))
		if opt_chain_label >= 0 {
			next_label := emit_goto(s, O(.goto), -1)
			emit_label(s, opt_chain_label)
			emit_op(s, O(.drop))
			emit_op(s, O(.push_true))
			emit_label(s, next_label)
		}
		fd.last_opcode_pos = -1
	case O(.get_array_el):
		resize(&fd.byte_code, fd.last_opcode_pos)
		fd.last_opcode_pos = -1
		emit_op(s, O(.delete_))
	case OP_get_array_el_opt_chain:
		opt_chain_label := int(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1 + 1))
		resize(&fd.byte_code, fd.last_opcode_pos)
		emit_op(s, O(.delete_))
		next_label := emit_goto(s, O(.goto), -1)
		emit_label(s, opt_chain_label)
		emit_op(s, O(.drop))
		emit_op(s, O(.push_true))
		emit_label(s, next_label)
		fd.last_opcode_pos = -1
	case OP_scope_get_var:
		name := Atom(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		if name == A_this || name == A_new_target {
			emit_op(s, O(.drop))
			emit_op(s, O(.push_true))
		} else if fd.is_strict_mode {
			return js_parse_error(s, "cannot delete a direct reference in strict mode")
		} else {
			fd.byte_code[fd.last_opcode_pos] = u8(OP_scope_delete_var)
		}
	case OP_scope_get_private_field:
		return js_parse_error(s, "cannot delete a private class field")
	case O(.get_super_value):
		resize(&fd.byte_code, fd.last_opcode_pos)
		fd.last_opcode_pos = -1
		emit_op(s, O(.throw_error))
		emit_atom(s, JS_ATOM_NULL)
		emit_u8(s, JS_THROW_ERROR_DELETE_SUPER)
	case:
		emit_op(s, O(.drop))
		emit_op(s, O(.push_true))
	}
	return false
}

js_parse_unary :: proc(s: ^Parse_State, parse_flags0: int) -> bool {
	parse_flags := parse_flags0
	s.depth += 1
	defer s.depth -= 1
	if s.depth > s.max_depth || stack_exhausted(s.stack) {
		return js_parse_error(s, "stack overflow")
	}
	switch s.token.val {
	case '+', '-', '!', '~', TOK_VOID:
		op := s.token.val
		if next_token(s) {return true}
		if js_parse_unary(s, PF_POW_FORBIDDEN) {return true}
		switch op {
		case '-': emit_op(s, O(.neg))
		case '+': emit_op(s, O(.plus))
		case '!': emit_op(s, O(.lnot))
		case '~': emit_op(s, O(.not))
		case TOK_VOID:
			emit_op(s, O(.drop))
			emit_op(s, O(.undefined))
		}
		parse_flags = 0
	case TOK_DEC, TOK_INC:
		opcode, scope, label: int
		name: Atom
		op := s.token.val
		if next_token(s) {return true}
		if js_parse_unary(s, 0) {return true}
		if get_lvalue(s, &opcode, &scope, &name, &label, nil, true, op) {return true}
		emit_op(s, O(.dec) + op - TOK_DEC)
		put_lvalue(s, opcode, scope, name, label, .keep_top, false)
	case TOK_TYPEOF:
		if next_token(s) {return true}
		if js_parse_unary(s, PF_POW_FORBIDDEN) {return true}
		fd := s.cur_func
		if get_prev_opcode(fd) == OP_scope_get_var {
			fd.byte_code[fd.last_opcode_pos] = u8(OP_scope_get_var_undef)
		}
		emit_op(s, O(.typeof_))
		parse_flags = 0
	case TOK_DELETE:
		if js_parse_delete(s) {return true}
		parse_flags = 0
	case TOK_AWAIT:
		if !func_kind_is_async(s.cur_func.func_kind) {
			return js_parse_error(s, "unexpected 'await' keyword")
		}
		if !s.cur_func.in_function_body {
			return js_parse_error(s, "await in default expression")
		}
		if next_token(s) {return true}
		if js_parse_unary(s, PF_POW_FORBIDDEN) {return true}
		emit_op(s, O(.await))
		s.cur_func.has_await = true
		parse_flags = 0
	case:
		if js_parse_postfix_expr(s, PF_POSTFIX_CALL) {return true}
		if !s.got_lf && (s.token.val == TOK_DEC || s.token.val == TOK_INC) {
			opcode, scope, label: int
			name: Atom
			op := s.token.val
			if get_lvalue(s, &opcode, &scope, &name, &label, nil, true, op) {return true}
			emit_op(s, O(.post_dec) + op - TOK_DEC)
			put_lvalue(s, opcode, scope, name, label, .keep_second, false)
			if next_token(s) {return true}
		}
	}
	if (parse_flags & (PF_POW_ALLOWED | PF_POW_FORBIDDEN)) != 0 {
		if s.token.val == TOK_POW {
			if (parse_flags & PF_POW_FORBIDDEN) != 0 {
				return js_parse_error(s, "unparenthesized unary expression can't appear on the left-hand side of '**'")
			}
			if next_token(s) {return true}
			if js_parse_unary(s, PF_POW_ALLOWED) {return true}
			emit_op(s, O(.pow))
		}
	}
	return false
}

js_parse_expr_binary :: proc(s: ^Parse_State, level: int, parse_flags: int) -> bool {
	if level == 0 {
		return js_parse_unary(s, PF_POW_ALLOWED)
	} else if s.token.val == TOK_PRIVATE_NAME && (parse_flags & PF_IN_ACCEPTED) != 0 && level == 4 && peek_token(s, false) == TOK_IN {
		atom := s.token.atom
		if next_token(s) {return true}
		if s.token.val != TOK_IN {return true}
		if next_token(s) {return true}
		if js_parse_expr_binary(s, level - 1, parse_flags) {return true}
		emit_op(s, OP_scope_in_private_field)
		emit_atom(s, atom)
		emit_u16(s, u16(s.cur_func.scope_level))
		return false
	} else {
		if js_parse_expr_binary(s, level - 1, parse_flags) {return true}
	}
	for {
		op := s.token.val
		opcode: Opcode
		switch level {
		case 1:
			switch op {
			case '*': opcode = .mul
			case '/': opcode = .div
			case '%': opcode = .mod
			case: return false
			}
		case 2:
			switch op {
			case '+': opcode = .add
			case '-': opcode = .sub
			case: return false
			}
		case 3:
			switch op {
			case TOK_SHL: opcode = .shl
			case TOK_SAR: opcode = .sar
			case TOK_SHR: opcode = .shr
			case: return false
			}
		case 4:
			switch op {
			case '<': opcode = .lt
			case '>': opcode = .gt
			case TOK_LTE: opcode = .lte
			case TOK_GTE: opcode = .gte
			case TOK_INSTANCEOF: opcode = .instanceof
			case TOK_IN:
				if (parse_flags & PF_IN_ACCEPTED) != 0 {
					opcode = .in_
				} else {
					return false
				}
			case: return false
			}
		case 5:
			switch op {
			case TOK_EQ: opcode = .eq
			case TOK_NEQ: opcode = .neq
			case TOK_STRICT_EQ: opcode = .strict_eq
			case TOK_STRICT_NEQ: opcode = .strict_neq
			case: return false
			}
		case 6:
			if op != '&' {return false}
			opcode = .and
		case 7:
			if op != '^' {return false}
			opcode = .xor
		case 8:
			if op != '|' {return false}
			opcode = .or
		}
		if next_token(s) {return true}
		emit_source_loc(s)
		if js_parse_expr_binary(s, level - 1, parse_flags) {return true}
		emit_op(s, int(opcode))
	}
}

js_parse_logical_and_or :: proc(s: ^Parse_State, op: int, parse_flags: int) -> bool {
	if op == TOK_LAND {
		if js_parse_expr_binary(s, 8, parse_flags) {return true}
	} else {
		if js_parse_logical_and_or(s, TOK_LAND, parse_flags) {return true}
	}
	if s.token.val == op {
		label1 := new_label(s)
		for {
			if next_token(s) {return true}
			emit_op(s, O(.dup))
			emit_goto(s, op == TOK_LAND ? O(.if_false) : O(.if_true), label1)
			emit_op(s, O(.drop))
			if op == TOK_LAND {
				if js_parse_expr_binary(s, 8, parse_flags) {return true}
			} else {
				if js_parse_logical_and_or(s, TOK_LAND, parse_flags) {return true}
			}
			if s.token.val != op {
				if s.token.val == TOK_DOUBLE_QUESTION_MARK {
					return js_parse_error(s, "cannot mix ?? with && or ||")
				}
				break
			}
		}
		emit_label(s, label1)
	}
	return false
}

js_parse_coalesce_expr :: proc(s: ^Parse_State, parse_flags: int) -> bool {
	if js_parse_logical_and_or(s, TOK_LOR, parse_flags) {return true}
	if s.token.val == TOK_DOUBLE_QUESTION_MARK {
		label1 := new_label(s)
		for {
			if next_token(s) {return true}
			emit_op(s, O(.dup))
			emit_op(s, O(.is_undefined_or_null))
			emit_goto(s, O(.if_false), label1)
			emit_op(s, O(.drop))
			if js_parse_expr_binary(s, 8, parse_flags) {return true}
			if s.token.val != TOK_DOUBLE_QUESTION_MARK {break}
		}
		emit_label(s, label1)
	}
	return false
}

js_parse_cond_expr :: proc(s: ^Parse_State, parse_flags: int) -> bool {
	if js_parse_coalesce_expr(s, parse_flags) {return true}
	if s.token.val == '?' {
		if next_token(s) {return true}
		label1 := emit_goto(s, O(.if_false), -1)
		if js_parse_assign_expr(s) {return true}
		if js_parse_expect(s, ':') {return true}
		label2 := emit_goto(s, O(.goto), -1)
		emit_label(s, label1)
		if js_parse_assign_expr2(s, parse_flags & PF_IN_ACCEPTED) {return true}
		emit_label(s, label2)
	}
	return false
}

js_parse_assign_expr2 :: proc(s: ^Parse_State, parse_flags: int) -> bool {
	s.depth += 1
	defer s.depth -= 1
	if s.depth > s.max_depth || stack_exhausted(s.stack) {
		return js_parse_error(s, "stack overflow")
	}
	name0 := JS_ATOM_NULL
	if s.token.val == TOK_YIELD {
		is_star := false
		if !func_kind_is_generator(s.cur_func.func_kind) {
			return js_parse_error(s, "unexpected 'yield' keyword")
		}
		if !s.cur_func.in_function_body {
			return js_parse_error(s, "yield in default expression")
		}
		if next_token(s) {return true}
		if s.token.val != ';' && s.token.val != ')' && s.token.val != ']' && s.token.val != '}' &&
		   s.token.val != ',' && s.token.val != ':' && !s.got_lf {
			if s.token.val == '*' {
				is_star = true
				if next_token(s) {return true}
			}
			if js_parse_assign_expr2(s, parse_flags) {return true}
		} else {
			emit_op(s, O(.undefined))
		}
		is_async := s.cur_func.func_kind == .async_generator
		if is_star {
			label_loop := new_label(s)
			label_yield := new_label(s)
			emit_op(s, is_async ? O(.for_await_of_start) : O(.for_of_start))
			emit_op(s, O(.drop))
			emit_op(s, O(.undefined))
			emit_op(s, O(.undefined))
			emit_label(s, label_loop)
			emit_op(s, O(.iterator_next))
			if is_async {emit_op(s, O(.await))}
			emit_op(s, O(.check_object))
			emit_op(s, O(.get_field2))
			emit_atom(s, A_done)
			label_next := emit_goto(s, O(.if_true), -1)
			emit_label(s, label_yield)
			if is_async {
				emit_op(s, O(.get_field))
				emit_atom(s, A_value)
				emit_op(s, O(.async_yield_star))
			} else {
				emit_op(s, O(.yield_star))
			}
			emit_op(s, O(.dup))
			label_return := emit_goto(s, O(.if_true), -1)
			emit_op(s, O(.drop))
			emit_goto(s, O(.goto), label_loop)

			emit_label(s, label_return)
			emit_op(s, O(.push_i32))
			emit_u32(s, 2)
			emit_op(s, O(.strict_eq))
			label_throw := emit_goto(s, O(.if_true), -1)

			if is_async {emit_op(s, O(.await))}
			emit_op(s, O(.iterator_call))
			emit_u8(s, 0)
			label_return1 := emit_goto(s, O(.if_true), -1)
			if is_async {emit_op(s, O(.await))}
			emit_op(s, O(.check_object))
			emit_op(s, O(.get_field2))
			emit_atom(s, A_done)
			emit_goto(s, O(.if_false), label_yield)

			emit_op(s, O(.get_field))
			emit_atom(s, A_value)

			emit_label(s, label_return1)
			emit_op(s, O(.nip))
			emit_op(s, O(.nip))
			emit_op(s, O(.nip))
			emit_return(s, true)

			emit_label(s, label_throw)
			emit_op(s, O(.iterator_call))
			emit_u8(s, 1)
			label_throw1 := emit_goto(s, O(.if_true), -1)
			if is_async {emit_op(s, O(.await))}
			emit_op(s, O(.check_object))
			emit_op(s, O(.get_field2))
			emit_atom(s, A_done)
			emit_goto(s, O(.if_false), label_yield)
			emit_goto(s, O(.goto), label_next)
			emit_label(s, label_throw1)
			emit_op(s, O(.iterator_call))
			emit_u8(s, 2)
			label_throw2 := emit_goto(s, O(.if_true), -1)
			if is_async {emit_op(s, O(.await))}
			emit_label(s, label_throw2)

			emit_op(s, O(.throw_error))
			emit_atom(s, JS_ATOM_NULL)
			emit_u8(s, JS_THROW_ERROR_ITERATOR_THROW)

			emit_label(s, label_next)
			emit_op(s, O(.get_field))
			emit_atom(s, A_value)
			emit_op(s, O(.nip))
			emit_op(s, O(.nip))
			emit_op(s, O(.nip))
		} else {
			if is_async {emit_op(s, O(.await))}
			emit_op(s, O(.yield))
			label_next := emit_goto(s, O(.if_false), -1)
			emit_return(s, true)
			emit_label(s, label_next)
		}
		return false
	} else if s.token.val == '(' && js_parse_skip_parens_token(s, nil, true) == TOK_ARROW {
		return js_parse_function_decl(s, .arrow, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num)
	} else if token_is_pseudo_keyword(s, A_async) {
		tok := peek_token(s, true)
		if tok != TOK_FUNCTION && tok != '\n' {
			source_ptr := s.token.ptr
			source_line_num := s.token.line_num
			source_col_num := s.token.col_num
			pos := js_parse_get_pos(s)
			if next_token(s) {return true}
			if (s.token.val == '(' && js_parse_skip_parens_token(s, nil, true) == TOK_ARROW) ||
			   (s.token.val == TOK_IDENT && !s.token.is_reserved && peek_token(s, true) == TOK_ARROW) {
				return js_parse_function_decl(s, .arrow, .async, JS_ATOM_NULL, source_ptr, source_line_num, source_col_num)
			} else {
				if js_parse_seek_token(s, &pos) {return true}
			}
		}
	} else if s.token.val == TOK_IDENT && peek_token(s, true) == TOK_ARROW {
		return js_parse_function_decl(s, .arrow, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num)
	}
	if s.token.val == TOK_IDENT {
		name0 = s.token.atom
	}
	if js_parse_cond_expr(s, parse_flags) {return true}

	op := s.token.val
	if op == '=' || (op >= TOK_MUL_ASSIGN && op <= TOK_POW_ASSIGN) {
		opcode, scope, label: int
		name: Atom
		if next_token(s) {return true}
		if get_lvalue(s, &opcode, &scope, &name, &label, nil, op != '=', op) {return true}
		if op == '=' && opcode == O(.get_array_el) {
			fd := s.cur_func
			resize(&fd.byte_code, fd.last_opcode_pos)
			fd.last_opcode_pos = -1
			emit_op(s, O(.swap))
			emit_op(s, O(.dup))
			emit_op(s, O(.is_undefined_or_null))
			label_next := emit_goto(s, O(.if_true), -1)
			emit_op(s, O(.swap))
			emit_op(s, O(.to_propkey))
			emit_op(s, O(.swap))
			emit_label(s, label_next)
			emit_op(s, O(.swap))
		}
		if js_parse_assign_expr2(s, parse_flags) {return true}
		if op == '=' && opcode == O(.get_array_el) {
			emit_op(s, O(.swap))
			emit_op(s, O(.to_propkey))
			emit_op(s, O(.swap))
		}
		if op == '=' {
			if (opcode == O(.get_ref_value) || opcode == OP_scope_get_var) && name == name0 {
				set_object_name(s, name)
			}
		} else {
			emit_op(s, op - TOK_MUL_ASSIGN + O(.mul))
		}
		put_lvalue(s, opcode, scope, name, label, .keep_top, false)
	} else if op >= TOK_LAND_ASSIGN && op <= TOK_DOUBLE_QUESTION_MARK_ASSIGN {
		opcode, scope, label, depth_lvalue: int
		name: Atom
		if next_token(s) {return true}
		if get_lvalue(s, &opcode, &scope, &name, &label, &depth_lvalue, true, op) {return true}
		emit_op(s, O(.dup))
		if op == TOK_DOUBLE_QUESTION_MARK_ASSIGN {
			emit_op(s, O(.is_undefined_or_null))
		}
		label1 := emit_goto(s, op == TOK_LOR_ASSIGN ? O(.if_true) : O(.if_false), -1)
		emit_op(s, O(.drop))
		if js_parse_assign_expr2(s, parse_flags) {return true}
		if (opcode == O(.get_ref_value) || opcode == OP_scope_get_var) && name == name0 {
			set_object_name(s, name)
		}
		switch depth_lvalue {
		case 0: emit_op(s, O(.dup))
		case 1: emit_op(s, O(.insert2))
		case 2: emit_op(s, O(.insert3))
		case 3: emit_op(s, O(.insert4))
		}
		put_lvalue(s, opcode, scope, name, label, .nokeep_depth, false)
		label2 := emit_goto(s, O(.goto), -1)
		emit_label(s, label1)
		for depth_lvalue != 0 {
			emit_op(s, O(.nip))
			depth_lvalue -= 1
		}
		emit_label(s, label2)
	}
	return false
}

js_parse_assign_expr :: proc(s: ^Parse_State) -> bool {
	return js_parse_assign_expr2(s, PF_IN_ACCEPTED)
}

js_parse_expr2 :: proc(s: ^Parse_State, parse_flags: int) -> bool {
	comma := false
	for {
		if js_parse_assign_expr2(s, parse_flags) {return true}
		if comma {
			s.cur_func.last_opcode_pos = -1
		}
		if s.token.val != ',' {break}
		comma = true
		if next_token(s) {return true}
		emit_op(s, O(.drop))
	}
	return false
}

js_parse_expr :: proc(s: ^Parse_State) -> bool {
	return js_parse_expr2(s, PF_IN_ACCEPTED)
}

// --- break / continue / return ------------------------------------------------------------------------------

push_break_entry :: proc(fd: ^Func_Def, be: ^Block_Env, label_name: Atom, label_break, label_cont, drop_count: int) {
	be.prev = fd.top_break
	fd.top_break = be
	be.label_name = label_name
	be.label_break = label_break
	be.label_cont = label_cont
	be.drop_count = drop_count
	be.label_finally = -1
	be.scope_level = fd.scope_level
	be.has_iterator = false
	be.is_async_iterator = false
	be.is_regular_stmt = false
	be.has_using = false
	be.using_scope_level = -1
}

pop_break_entry :: proc(fd: ^Func_Def) {
	be := fd.top_break
	fd.top_break = be.prev
}

emit_iterator_close :: proc(s: ^Parse_State, is_async: bool, preserve_completion: bool) {
	if !is_async {
		emit_op(s, O(.iterator_close))
		return
	}
	if preserve_completion {
		emit_op(s, O(.nip))
		emit_op(s, O(.swap))
	} else {
		emit_op(s, O(.drop))
		emit_op(s, O(.drop))
	}
	emit_op(s, O(.dup))
	emit_op(s, O(.is_undefined))
	label_done := emit_goto(s, O(.if_true), -1)
	emit_op(s, O(.get_field2))
	emit_atom(s, A_return)
	emit_op(s, O(.dup))
	emit_op(s, O(.is_undefined_or_null))
	label_no_return := emit_goto(s, O(.if_true), -1)
	emit_op(s, O(.call_method))
	emit_u16(s, 0)
	emit_op(s, O(.await))
	emit_op(s, O(.check_object))
	emit_goto(s, O(.goto), label_done)
	emit_label(s, label_no_return)
	emit_op(s, O(.drop))
	emit_label(s, label_done)
	emit_op(s, O(.drop))
}

emit_break :: proc(s: ^Parse_State, name: Atom, is_cont: bool) -> bool {
	scope_level := s.cur_func.scope_level
	top := s.cur_func.top_break
	for top != nil {
		close_scopes(s, scope_level, top.scope_level)
		scope_level = top.scope_level
		if is_cont && top.label_cont != -1 && (name == JS_ATOM_NULL || top.label_name == name) {
			emit_goto(s, O(.goto), top.label_cont)
			return false
		}
		if !is_cont && top.label_break != -1 {
			if top.label_name == name || (name == JS_ATOM_NULL && !top.is_regular_stmt) {
				emit_goto(s, O(.goto), top.label_break)
				return false
			}
		}
		i := 0
		if top.has_iterator {
			emit_iterator_close(s, top.is_async_iterator, false)
			i += 3
		}
		for ; i < top.drop_count; i += 1 {
			emit_op(s, O(.drop))
		}
		if top.has_using {
			emit_op(s, O(.using_dispose_init))
			emit_op(s, OP_dispose_scope)
			emit_u16(s, u16(top.using_scope_level))
			emit_op(s, O(.using_dispose_end))
		}
		if top.label_finally != -1 {
			emit_op(s, O(.undefined))
			emit_goto(s, O(.gosub), top.label_finally)
			emit_op(s, O(.drop))
		}
		top = top.prev
	}
	if name == JS_ATOM_NULL {
		if is_cont {
			return js_parse_error(s, "continue must be inside loop")
		}
		return js_parse_error(s, "break must be inside loop or switch")
	}
	return js_parse_error(s, "break/continue label not found")
}

emit_return :: proc(s: ^Parse_State, hasval0: bool) {
	hasval := hasval0
	if s.cur_func.func_kind != .normal {
		if !hasval {
			emit_op(s, O(.undefined))
			hasval = true
		} else if s.cur_func.func_kind == .async_generator {
			emit_op(s, O(.await))
		}
	}
	top := s.cur_func.top_break
	for top != nil {
		if top.has_iterator || top.label_finally != -1 || top.has_using {
			if !hasval {
				emit_op(s, O(.undefined))
				hasval = true
			}
			emit_op(s, O(.nip_catch))
			if top.has_iterator {
				if top.is_async_iterator {
					emit_iterator_close(s, true, true)
				} else {
					emit_op(s, O(.rot3r))
					emit_op(s, O(.undefined))
					emit_op(s, O(.iterator_close))
				}
			} else if top.has_using {
				emit_op(s, O(.using_dispose_init))
				emit_op(s, OP_dispose_scope)
				emit_u16(s, u16(top.using_scope_level))
				emit_op(s, O(.using_dispose_end))
			} else {
				emit_goto(s, O(.gosub), top.label_finally)
			}
		}
		top = top.prev
	}
	if s.cur_func.is_derived_class_constructor {
		label_return := -1
		if hasval {
			emit_op(s, O(.check_ctor_return))
			label_return = emit_goto(s, O(.if_false), -1)
			emit_op(s, O(.drop))
		}
		emit_op(s, OP_scope_get_var)
		emit_atom(s, A_this)
		emit_u16(s, 0)
		emit_label(s, label_return)
		emit_op(s, O(.ret_))
	} else if s.cur_func.func_kind != .normal {
		emit_op(s, O(.return_async))
	} else {
		emit_op(s, hasval ? O(.ret_) : O(.return_undef))
	}
}
