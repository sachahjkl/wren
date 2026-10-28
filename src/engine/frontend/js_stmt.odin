package frontend

// Statements and declarations (js_parse_block .. js_parse_statement_or_decl).

DECL_MASK_FUNC :: 1 << 0
DECL_MASK_FUNC_WITH_LABEL :: 1 << 1
DECL_MASK_OTHER :: 1 << 2
DECL_MASK_ALL :: DECL_MASK_FUNC | DECL_MASK_FUNC_WITH_LABEL | DECL_MASK_OTHER

js_parse_statement :: proc(s: ^Parse_State) -> bool {
	return js_parse_statement_or_decl(s, 0)
}

js_parse_block :: proc(s: ^Parse_State) -> bool {
	fd := s.cur_func
	if js_parse_expect(s, '{') {return true}
	if s.token.val != '}' {
		using_be: Block_Env
		has_using_be := false
		push_scope(s)
		scope_level := fd.scope_level
		for {
			if js_parse_statement_or_decl(s, DECL_MASK_ALL) {return true}
			if !has_using_be && fd.scopes[scope_level].has_using {
				has_using_be = true
				push_break_entry(fd, &using_be, JS_ATOM_NULL, -1, -1, 1)
				using_be.has_using = true
				using_be.using_scope_level = scope_level
			}
			if s.token.val == '}' {break}
		}
		if has_using_be {
			label_catch := fd.scopes[scope_level].using_label_catch
			label_end := fd.scopes[scope_level].using_label_end
			pop_break_entry(fd)
			if js_is_live_code(s) {
				emit_op(s, O(.drop))
				emit_op(s, O(.using_dispose_init))
				emit_op(s, OP_dispose_scope)
				emit_u16(s, u16(scope_level))
				emit_op(s, O(.using_dispose_end))
				emit_goto(s, O(.goto), label_end)
			}
			emit_label(s, label_catch)
			emit_op(s, OP_dispose_scope)
			emit_u16(s, u16(scope_level))
			emit_op(s, O(.throw_))
			emit_label(s, label_end)
		}
		pop_scope(s)
	}
	return next_token(s)
}

js_parse_var :: proc(s: ^Parse_State, parse_flags: int, tok: int, export_flag: bool) -> bool {
	fd := s.cur_func
	for {
		if s.token.val == TOK_IDENT {
			if s.token.is_reserved {
				return js_parse_error_reserved_identifier(s)
			}
			name := s.token.atom
			if name == A_let && (tok == TOK_LET || tok == TOK_CONST || tok == TOK_USING) {
				return js_parse_error(s, "'let' is not a valid lexical identifier")
			}
			using_method_idx := -1
			if next_token(s) {return true}
			if js_define_var(s, name, tok) {return true}
			if tok == TOK_USING {
				using_method_idx = add_scope_var(s, fd, A__using_dispose_, .using_method)
				if using_method_idx < 0 {return true}
				fd.vars[using_method_idx].is_lexical = true
				fd.vars[using_method_idx].is_const = true
			}
			if export_flag {
				if add_export_entry(s, s.cur_func.module, name, name, .local) {return true}
			}
			if s.token.val == '=' {
				if next_token(s) {return true}
				if tok == TOK_VAR {
					opcode, scope, label: int
					name1: Atom
					emit_op(s, OP_scope_get_var)
					emit_atom(s, name)
					emit_u16(s, u16(fd.scope_level))
					if get_lvalue(s, &opcode, &scope, &name1, &label, nil, false, '=') {return true}
					if js_parse_assign_expr2(s, parse_flags) {return true}
					set_object_name(s, name)
					put_lvalue(s, opcode, scope, name1, label, .nokeep, false)
				} else {
					if tok == TOK_USING {
						is_await := (parse_flags & PF_AWAIT_USING) != 0
						sc := &fd.scopes[fd.scope_level]
						if !sc.has_using {
							sc.has_using = true
							sc.using_label_catch = new_label(s)
							fd.scopes[fd.scope_level].using_label_end = new_label(s)
							emit_goto(s, O(.catch), fd.scopes[fd.scope_level].using_label_catch)
						}
						if is_await {fd.scopes[fd.scope_level].is_await_using = true}
					}
					if js_parse_assign_expr2(s, parse_flags) {return true}
					set_object_name(s, name)
					if tok == TOK_USING {
						emit_op(s, O(.using_check))
						emit_u8(s, (parse_flags & PF_AWAIT_USING) != 0 ? 1 : 0)
						emit_op(s, O(.put_loc))
						emit_u16(s, u16(using_method_idx))
					}
					init := tok == TOK_CONST || tok == TOK_LET || tok == TOK_USING
					emit_op(s, init ? OP_scope_put_var_init : OP_scope_put_var)
					emit_atom(s, name)
					emit_u16(s, u16(fd.scope_level))
				}
			} else {
				if tok == TOK_CONST || tok == TOK_USING {
					return js_parse_error(s, "missing initializer for variable")
				}
				if tok == TOK_LET {
					emit_op(s, O(.undefined))
					emit_op(s, OP_scope_put_var_init)
					emit_atom(s, name)
					emit_u16(s, u16(fd.scope_level))
				}
			}
		} else {
			skip_bits: int
			if (s.token.val == '[' || s.token.val == '{') && js_parse_skip_parens_token(s, &skip_bits, false) == '=' {
				if tok == TOK_USING {
					return js_parse_error(s, "binding patterns are not allowed in using declarations")
				}
				emit_op(s, O(.undefined))
				if js_parse_destructuring_element(s, tok, false, true, skip_bits & SKIP_HAS_ELLIPSIS, true, export_flag) < 0 {return true}
			} else {
				return js_parse_error(s, "variable name expected")
			}
		}
		if s.token.val != ',' {break}
		if next_token(s) {return true}
	}
	return false
}

is_label :: proc(s: ^Parse_State) -> bool {
	return s.token.val == TOK_IDENT && !s.token.is_reserved && peek_token(s, false) == ':'
}

// is_let returns 1 if `let` starts a declaration here, 0 if not, -1 on error.
is_let :: proc(s: ^Parse_State, decl_mask: int) -> int {
	res := 0
	if token_is_pseudo_keyword(s, A_let) {
		pos := js_parse_get_pos(s)
		for {
			if next_token(s) {
				res = -1
				break
			}
			if s.token.val == '[' {
				res = 1
				break
			}
			if s.token.val == '{' || (s.token.val == TOK_IDENT && !s.token.is_reserved) || s.token.val == TOK_LET ||
			   s.token.val == TOK_YIELD || s.token.val == TOK_AWAIT {
				if s.last_line_num == s.token.line_num || (decl_mask & DECL_MASK_OTHER) != 0 {
					res = 1
				}
				break
			}
			break
		}
		if js_parse_seek_token(s, &pos) {res = -1}
	}
	return res
}

is_using :: proc(s: ^Parse_State, is_for_of: bool) -> int {
	res := 0
	if token_is_pseudo_keyword(s, A_using) {
		pos := js_parse_get_pos(s)
		if next_token(s) {return -1}
		if s.last_line_num == s.token.line_num {
			if s.token.val == TOK_IDENT && !s.token.is_reserved {
				if !(is_for_of && s.token.atom == A_of) {
					res = 1
				}
			}
		}
		if js_parse_seek_token(s, &pos) {res = -1}
	}
	return res
}

// move_code moves bytecode [pos_from, pos_to) to the end and relocates the labels defined in it.
@(private = "file")
move_code_to_end :: proc(s: ^Parse_State, pos_from, pos_to: int, first_label: int) {
	fd := s.cur_func
	chunk_size := pos_to - pos_from
	offset := len(fd.byte_code) - pos_from
	for i in 0 ..< chunk_size {
		append(&fd.byte_code, fd.byte_code[pos_from + i])
	}
	for i in 0 ..< chunk_size {
		fd.byte_code[pos_from + i] = u8(O(.nop))
	}
	fd.last_opcode_pos = len(fd.byte_code) - 5
	for i in first_label ..< len(fd.label_slots) {
		ls := &fd.label_slots[i]
		if ls.pos >= pos_from && ls.pos < pos_to {
			ls.pos += offset
		}
	}
}

js_parse_for_in_of :: proc(s: ^Parse_State, label_name: Atom, is_async: bool, source_line_num, source_col_num: int) -> bool {
	fd := s.cur_func
	var_name: Atom
	has_initializer := false
	has_destructuring := false
	is_for_of := false
	opcode, scope: int
	break_entry: Block_Env

	block_scope_level := fd.scope_level
	label_cont := new_label(s)
	label_body := new_label(s)
	label_break := new_label(s)
	label_next := new_label(s)

	push_scope(s)
	push_break_entry(s.cur_func, &break_entry, label_name, label_break, label_cont, 1)
	break_entry.scope_level = block_scope_level

	label_expr := emit_goto(s, O(.goto), -1)

	pos_next := len(s.cur_func.byte_code)
	emit_label(s, label_next)

	tok := s.token.val
	switch is_let(s, DECL_MASK_OTHER) {
	case 1: tok = TOK_LET
	case 0:
	case: return true
	}
	is_await_using := false
	if tok == TOK_AWAIT {
		if next_token(s) {return true}
		u := is_using(s, false)
		if u < 0 {return true}
		if u == 0 {
			return js_parse_error(s, "'using' expected")
		}
		tok = TOK_USING
		is_await_using = true
		s.cur_func.has_await = true
	} else if token_is_pseudo_keyword(s, A_using) {
		u := is_using(s, true)
		if u < 0 {return true}
		if u != 0 {tok = TOK_USING}
	}
	if tok == TOK_VAR || tok == TOK_LET || tok == TOK_CONST || tok == TOK_USING {
		if next_token(s) {return true}
		if !(s.token.val == TOK_IDENT && !s.token.is_reserved) {
			if s.token.val == '[' || s.token.val == '{' {
				if js_parse_destructuring_element(s, tok, false, true, -1, false, false) < 0 {return true}
				has_destructuring = true
			} else {
				return js_parse_error(s, "variable name expected")
			}
			var_name = JS_ATOM_NULL
		} else {
			var_name = s.token.atom
			if var_name == A_let && (tok == TOK_LET || tok == TOK_CONST || tok == TOK_USING) {
				return js_parse_error(s, "'let' is not a valid lexical identifier")
			}
			if next_token(s) {return true}
			if js_define_var(s, var_name, tok) {return true}
			if tok == TOK_USING {
				mi := add_scope_var(s, fd, A__using_dispose_, .using_method)
				if mi < 0 {return true}
				fd.vars[mi].is_lexical = true
				fd.vars[mi].is_const = true
				emit_op(s, O(.using_check))
				emit_u8(s, is_await_using ? 1 : 0)
				emit_op(s, O(.put_loc))
				emit_u16(s, u16(mi))
			}
			init := tok == TOK_CONST || tok == TOK_LET || tok == TOK_USING
			emit_op(s, init ? OP_scope_put_var_init : OP_scope_put_var)
			emit_atom(s, var_name)
			emit_u16(s, u16(fd.scope_level))
			if tok == TOK_USING {
				if !fd.scopes[fd.scope_level].has_using {
					fd.scopes[fd.scope_level].has_using = true
					fd.scopes[fd.scope_level].using_label_catch = new_label(s)
					fd.scopes[fd.scope_level].using_label_end = new_label(s)
				}
				if is_await_using {fd.scopes[fd.scope_level].is_await_using = true}
			}
		}
	} else if !is_async && token_is_pseudo_keyword(s, A_async) && peek_token(s, false) == TOK_OF {
		return js_parse_error(s, "'for of' expression cannot start with 'async'")
	} else {
		skip_bits: int
		tok1 := 0
		if s.token.val == '[' || s.token.val == '{' {
			tok1 = js_parse_skip_parens_token(s, &skip_bits, false)
		}
		if (s.token.val == '[' || s.token.val == '{') && (tok1 == TOK_IN || tok1 == TOK_OF) {
			if js_parse_destructuring_element(s, 0, false, true, skip_bits & SKIP_HAS_ELLIPSIS, true, false) < 0 {return true}
		} else {
			lvalue_label: int
			if js_parse_left_hand_side_expr(s) {return true}
			if get_lvalue(s, &opcode, &scope, &var_name, &lvalue_label, nil, false, TOK_FOR) {return true}
			put_lvalue(s, opcode, scope, var_name, lvalue_label, .nokeep_bottom, false)
		}
		var_name = JS_ATOM_NULL
	}
	emit_goto(s, O(.goto), label_body)

	pos_expr := len(s.cur_func.byte_code)
	emit_label(s, label_expr)
	if s.token.val == '=' {
		has_initializer = true
		if next_token(s) {return true}
		if js_parse_assign_expr2(s, 0) {return true}
		if var_name != JS_ATOM_NULL {
			emit_op(s, OP_scope_put_var)
			emit_atom(s, var_name)
			emit_u16(s, u16(fd.scope_level))
		}
	}

	if token_is_pseudo_keyword(s, A_of) {
		is_for_of = true
		if has_initializer {
			return js_parse_error(s, "a declaration in the head of a for-of loop can't have an initializer")
		}
	} else if s.token.val == TOK_IN {
		if is_async {
			return js_parse_error(s, "'for await' loop should be used with 'of'")
		}
		if tok == TOK_USING {
			return js_parse_error(s, "using declaration not allowed in for-in")
		}
		if has_initializer && (tok != TOK_VAR || fd.is_strict_mode || has_destructuring) {
			return js_parse_error(s, "a declaration in the head of a for-in loop can't have an initializer")
		}
	} else {
		return js_parse_error(s, "expected 'of' or 'in' in for control expression")
	}
	if next_token(s) {return true}
	if is_for_of {
		if js_parse_assign_expr(s) {return true}
	} else {
		if js_parse_expr(s) {return true}
	}
	close_scopes(s, s.cur_func.scope_level, block_scope_level)
	if is_for_of {
		break_entry.has_iterator = true
		break_entry.is_async_iterator = is_async
		break_entry.drop_count += 2
		emit_op(s, is_async ? O(.for_await_of_start) : O(.for_of_start))
	} else {
		emit_op(s, O(.for_in_start))
	}
	emit_goto(s, O(.goto), label_cont)

	if js_parse_expect(s, ')') {return true}

	move_code_to_end(s, pos_next, pos_expr, label_cont)

	emit_label(s, label_body)
	{
		scope_has_using := fd.scopes[fd.scope_level].has_using
		using_scope_level := fd.scope_level
		using_be: Block_Env
		had_using_be := false
		if scope_has_using {
			emit_goto(s, O(.catch), fd.scopes[using_scope_level].using_label_catch)
			push_break_entry(fd, &using_be, JS_ATOM_NULL, -1, -1, 1)
			using_be.has_using = true
			using_be.using_scope_level = using_scope_level
			had_using_be = true
		}
		if js_parse_statement(s) {return true}
		if had_using_be {pop_break_entry(fd)}
		if scope_has_using && js_is_live_code(s) {
			emit_op(s, O(.drop))
			emit_op(s, O(.using_dispose_init))
			emit_op(s, OP_dispose_scope)
			emit_u16(s, u16(using_scope_level))
			emit_op(s, O(.using_dispose_end))
			emit_goto(s, O(.goto), fd.scopes[using_scope_level].using_label_end)
		}
		if scope_has_using {
			emit_label(s, fd.scopes[using_scope_level].using_label_catch)
			emit_op(s, OP_dispose_scope)
			emit_u16(s, u16(using_scope_level))
			emit_op(s, O(.throw_))
			emit_label(s, fd.scopes[using_scope_level].using_label_end)
		}
	}

	close_scopes(s, s.cur_func.scope_level, block_scope_level)

	emit_label(s, label_cont)
	if is_for_of {
		if is_async {
			emit_op(s, O(.dup3))
			emit_op(s, O(.drop))
			emit_op(s, O(.call_method))
			emit_u16(s, 0)
			emit_op(s, O(.await))
			emit_op(s, O(.iterator_get_value_done))
		} else {
			emit_op(s, O(.for_of_next))
			emit_u8(s, 0)
		}
	} else {
		emit_op(s, O(.for_in_next))
	}
	emit_goto(s, O(.if_false), label_next)
	emit_op(s, O(.drop))

	emit_label(s, label_break)
	if is_for_of {
		emit_source_loc_at(s, source_line_num, source_col_num)
		emit_iterator_close(s, is_async, false)
	} else {
		emit_op(s, O(.drop))
	}
	pop_break_entry(s.cur_func)
	pop_scope(s)
	return false
}

set_eval_ret_undefined :: proc(s: ^Parse_State) {
	if s.cur_func.eval_ret_idx >= 0 {
		emit_op(s, O(.undefined))
		emit_op(s, O(.put_loc))
		emit_u16(s, u16(s.cur_func.eval_ret_idx))
	}
}

js_parse_statement_or_decl :: proc(s: ^Parse_State, decl_mask: int) -> bool {
	s.depth += 1
	defer s.depth -= 1
	if s.depth > s.max_depth {
		return js_parse_error(s, "stack overflow")
	}
	label_name := JS_ATOM_NULL
	if is_label(s) {
		label_name = s.token.atom
		for be := s.cur_func.top_break; be != nil; be = be.prev {
			if be.label_name == label_name {
				return js_parse_error(s, "duplicate label name")
			}
		}
		if next_token(s) {return true}
		if js_parse_expect(s, ':') {return true}
		if s.token.val != TOK_FOR && s.token.val != TOK_DO && s.token.val != TOK_WHILE {
			fd := s.cur_func
			break_entry: Block_Env
			label_break := new_label(s)
			push_break_entry(fd, &break_entry, label_name, label_break, -1, 0)
			fd.top_break.is_regular_stmt = true
			mask := 0
			if !fd.is_strict_mode && (decl_mask & DECL_MASK_FUNC_WITH_LABEL) != 0 {
				mask = DECL_MASK_FUNC | DECL_MASK_FUNC_WITH_LABEL
			}
			if js_parse_statement_or_decl(s, mask) {return true}
			emit_label(s, label_break)
			pop_break_entry(fd)
			return false
		}
	}

	tok := s.token.val
	Path :: enum {none, haslet, hasexpr, func_decl_error, parse_func_var}
	path := Path.none
	switch tok {
	case '{':
		if js_parse_block(s) {return true}
	case TOK_RETURN:
		if s.cur_func.is_eval {
			return js_parse_error(s, "return not in a function")
		}
		if s.cur_func.func_type == .class_static_init {
			return js_parse_error(s, "return in a static initializer block")
		}
		if next_token(s) {return true}
		if s.token.val != ';' && s.token.val != '}' && !s.got_lf {
			if js_parse_expr(s) {return true}
			emit_return(s, true)
		} else {
			emit_return(s, false)
		}
		if js_parse_expect_semi(s) {return true}
	case TOK_THROW:
		if next_token(s) {return true}
		if s.got_lf {
			return js_parse_error(s, "line terminator not allowed after throw")
		}
		emit_source_loc(s)
		if js_parse_expr(s) {return true}
		emit_op(s, O(.throw_))
		if js_parse_expect_semi(s) {return true}
	case TOK_AWAIT:
		if func_kind_is_async(s.cur_func.func_kind) {
			pos := js_parse_get_pos(s)
			if next_token(s) {return true}
			u := is_using(s, false)
			if u < 0 {return true}
			if u != 0 {
				if (decl_mask & DECL_MASK_OTHER) == 0 {
					return js_parse_error(s, "lexical declarations can't appear in single-statement context")
				}
				s.cur_func.has_await = true
				if next_token(s) {return true}
				if js_parse_var(s, PF_IN_ACCEPTED | PF_AWAIT_USING, TOK_USING, false) {return true}
				if js_parse_expect_semi(s) {return true}
				break
			}
			if js_parse_seek_token(s, &pos) {return true}
		}
		path = .hasexpr
	case TOK_LET, TOK_CONST:
		path = .haslet
	case TOK_VAR:
		if next_token(s) {return true}
		if js_parse_var(s, PF_IN_ACCEPTED, tok, false) {return true}
		if js_parse_expect_semi(s) {return true}
	case TOK_IF:
		if next_token(s) {return true}
		push_scope(s)
		set_eval_ret_undefined(s)
		if js_parse_expr_paren(s) {return true}
		label1 := emit_goto(s, O(.if_false), -1)
		mask := s.cur_func.is_strict_mode ? 0 : DECL_MASK_FUNC
		if js_parse_statement_or_decl(s, mask) {return true}
		if s.token.val == TOK_ELSE {
			label2 := emit_goto(s, O(.goto), -1)
			if next_token(s) {return true}
			emit_label(s, label1)
			if js_parse_statement_or_decl(s, mask) {return true}
			label1 = label2
		}
		emit_label(s, label1)
		pop_scope(s)
	case TOK_WHILE:
		break_entry: Block_Env
		label_cont := new_label(s)
		label_break := new_label(s)
		push_break_entry(s.cur_func, &break_entry, label_name, label_break, label_cont, 0)
		if next_token(s) {return true}
		set_eval_ret_undefined(s)
		emit_label(s, label_cont)
		if js_parse_expr_paren(s) {return true}
		emit_goto(s, O(.if_false), label_break)
		if js_parse_statement(s) {return true}
		emit_goto(s, O(.goto), label_cont)
		emit_label(s, label_break)
		pop_break_entry(s.cur_func)
	case TOK_DO:
		break_entry: Block_Env
		label_cont := new_label(s)
		label_break := new_label(s)
		label1 := new_label(s)
		push_break_entry(s.cur_func, &break_entry, label_name, label_break, label_cont, 0)
		if next_token(s) {return true}
		emit_label(s, label1)
		set_eval_ret_undefined(s)
		if js_parse_statement(s) {return true}
		emit_label(s, label_cont)
		if js_parse_expect(s, TOK_WHILE) {return true}
		if js_parse_expr_paren(s) {return true}
		if s.token.val == ';' {
			if next_token(s) {return true}
		}
		emit_goto(s, O(.if_true), label1)
		emit_label(s, label_break)
		pop_break_entry(s.cur_func)
	case TOK_FOR:
		if js_parse_for_stmt(s, label_name) {return true}
	case TOK_BREAK, TOK_CONTINUE:
		is_cont := s.token.val == TOK_CONTINUE
		if next_token(s) {return true}
		label := JS_ATOM_NULL
		if !s.got_lf && s.token.val == TOK_IDENT && !s.token.is_reserved {
			label = s.token.atom
		}
		if emit_break(s, label, is_cont) {return true}
		if label != JS_ATOM_NULL {
			if next_token(s) {return true}
		}
		if js_parse_expect_semi(s) {return true}
	case TOK_SWITCH:
		if js_parse_switch(s, label_name) {return true}
	case TOK_TRY:
		if js_parse_try(s) {return true}
	case ';':
		if next_token(s) {return true}
	case TOK_WITH:
		if s.cur_func.is_strict_mode {
			return js_parse_error(s, "invalid keyword: with")
		}
		if next_token(s) {return true}
		if js_parse_expr_paren(s) {return true}
		push_scope(s)
		with_idx := define_var(s, s.cur_func, A__with_, .with_)
		if with_idx < 0 {return true}
		emit_op(s, O(.to_object))
		emit_op(s, O(.put_loc))
		emit_u16(s, u16(with_idx))
		set_eval_ret_undefined(s)
		if js_parse_statement(s) {return true}
		pop_scope(s)
	case TOK_FUNCTION:
		if (decl_mask & DECL_MASK_FUNC) == 0 {
			path = .func_decl_error
		} else if (decl_mask & DECL_MASK_OTHER) == 0 && peek_token(s, false) == '*' {
			path = .func_decl_error
		} else {
			path = .parse_func_var
		}
	case TOK_IDENT:
		if s.token.is_reserved {
			return js_parse_error_reserved_identifier(s)
		}
		switch is_let(s, decl_mask) {
		case 1:
			tok = TOK_LET
			path = .haslet
		case 0:
		case:
			return true
		}
		if path == .haslet {break}
		if token_is_pseudo_keyword(s, A_using) {
			u := is_using(s, false)
			if u < 0 {return true}
			if u != 0 {
				fd := s.cur_func
				if (decl_mask & DECL_MASK_OTHER) == 0 {
					return js_parse_error(s, "lexical declarations can't appear in single-statement context")
				}
				if fd.is_eval && (fd.eval_type == .global || fd.eval_type == .direct || fd.eval_type == .indirect) && fd.scope_level == fd.body_scope {
					return js_parse_error(s, "using declaration is not allowed at the top level of a script")
				}
				if next_token(s) {return true}
				if js_parse_var(s, PF_IN_ACCEPTED, TOK_USING, false) {return true}
				if js_parse_expect_semi(s) {return true}
				break
			}
		}
		if token_is_pseudo_keyword(s, A_async) && peek_token(s, true) == TOK_FUNCTION {
			if (decl_mask & DECL_MASK_OTHER) == 0 {
				path = .func_decl_error
			} else {
				path = .parse_func_var
			}
		} else {
			path = .hasexpr
		}
	case TOK_CLASS:
		if (decl_mask & DECL_MASK_OTHER) == 0 {
			return js_parse_error(s, "class declarations can't appear in single-statement context")
		}
		if js_parse_class(s, false, .none) {return true}
	case TOK_DEBUGGER:
		if next_token(s) {return true}
		if js_parse_expect_semi(s) {return true}
	case TOK_ENUM, TOK_EXPORT, TOK_EXTENDS:
		return js_parse_error(s, "unsupported keyword: ", atom_text(s, s.token.atom))
	case:
		path = .hasexpr
	}

	switch path {
	case .none:
	case .haslet:
		if (decl_mask & DECL_MASK_OTHER) == 0 {
			return js_parse_error(s, "lexical declarations can't appear in single-statement context")
		}
		if next_token(s) {return true}
		if js_parse_var(s, PF_IN_ACCEPTED, tok, false) {return true}
		if js_parse_expect_semi(s) {return true}
	case .func_decl_error:
		return js_parse_error(s, "function declarations can't appear in single-statement context")
	case .parse_func_var:
		if js_parse_function_decl(s, .var_, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num) {return true}
	case .hasexpr:
		emit_source_loc(s)
		if js_parse_expr(s) {return true}
		if s.cur_func.eval_ret_idx >= 0 {
			emit_op(s, O(.put_loc))
			emit_u16(s, u16(s.cur_func.eval_ret_idx))
		} else {
			emit_op(s, O(.drop))
		}
		if js_parse_expect_semi(s) {return true}
	}
	return false
}

@(private = "file")
js_parse_for_stmt :: proc(s: ^Parse_State, label_name: Atom) -> bool {
	break_entry: Block_Env
	source_line_num := s.token.line_num
	source_col_num := s.token.col_num
	if next_token(s) {return true}
	set_eval_ret_undefined(s)
	bits := 0
	is_async := false
	if s.token.val == '(' {
		js_parse_skip_parens_token(s, &bits, false)
	} else if s.token.val == TOK_AWAIT {
		if !func_kind_is_async(s.cur_func.func_kind) {
			return js_parse_error(s, "for await is only valid in asynchronous functions")
		}
		is_async = true
		if next_token(s) {return true}
		s.cur_func.has_await = true
	}
	if js_parse_expect(s, '(') {return true}
	if (bits & SKIP_HAS_SEMI) == 0 {
		return js_parse_for_in_of(s, label_name, is_async, source_line_num, source_col_num)
	}
	block_scope_level := s.cur_func.scope_level
	push_scope(s)
	for_scope_level := s.cur_func.scope_level
	tok := s.token.val
	if tok != ';' {
		init_done := false
		switch is_let(s, DECL_MASK_OTHER) {
		case 1: tok = TOK_LET
		case 0:
		case: return true
		}
		if tok != TOK_VAR && tok != TOK_LET && tok != TOK_CONST && token_is_pseudo_keyword(s, A_using) {
			u := is_using(s, false)
			if u < 0 {return true}
			if u != 0 {tok = TOK_USING}
		}
		if tok == TOK_AWAIT && func_kind_is_async(s.cur_func.func_kind) {
			pos := js_parse_get_pos(s)
			if next_token(s) {return true}
			u := is_using(s, false)
			if u < 0 {return true}
			if u != 0 {
				s.cur_func.has_await = true
				tok = TOK_USING
				if next_token(s) {return true}
				if js_parse_var(s, PF_IN_ACCEPTED | PF_AWAIT_USING, TOK_USING, false) {return true}
				init_done = true
			} else {
				if js_parse_seek_token(s, &pos) {return true}
			}
		}
		if !init_done {
			if tok == TOK_VAR || tok == TOK_LET || tok == TOK_CONST || tok == TOK_USING {
				pf := 0
				if tok == TOK_USING && is_async {pf |= PF_AWAIT_USING}
				if next_token(s) {return true}
				if js_parse_var(s, pf, tok, false) {return true}
			} else {
				if js_parse_expr2(s, 0) {return true}
				emit_op(s, O(.drop))
			}
		}
		close_scopes(s, s.cur_func.scope_level, block_scope_level)
	}
	if js_parse_expect(s, ';') {return true}

	label_test := new_label(s)
	label_cont := new_label(s)
	label_body := new_label(s)
	label_break := new_label(s)

	push_break_entry(s.cur_func, &break_entry, label_name, label_break, label_cont, 0)
	if s.cur_func.scopes[for_scope_level].has_using {
		break_entry.has_using = true
		break_entry.using_scope_level = for_scope_level
		break_entry.drop_count = 1
	}

	if s.token.val == ';' {
		label_test = label_body
	} else {
		emit_label(s, label_test)
		if js_parse_expr(s) {return true}
		emit_goto(s, O(.if_false), label_break)
	}
	if js_parse_expect(s, ';') {return true}

	pos_cont := 0
	if s.token.val == ')' {
		label_cont = label_test
		break_entry.label_cont = label_cont
	} else {
		emit_goto(s, O(.goto), label_body)
		pos_cont = len(s.cur_func.byte_code)
		emit_label(s, label_cont)
		if js_parse_expr(s) {return true}
		emit_op(s, O(.drop))
		if label_test != label_body {
			emit_goto(s, O(.goto), label_test)
		}
	}
	if js_parse_expect(s, ')') {return true}

	pos_body := len(s.cur_func.byte_code)
	emit_label(s, label_body)
	if js_parse_statement(s) {return true}

	close_scopes(s, s.cur_func.scope_level, block_scope_level)

	if label_test != label_body && label_cont != label_test {
		move_code_to_end(s, pos_cont, pos_body, label_cont)
	} else {
		emit_goto(s, O(.goto), label_cont)
	}

	emit_label(s, label_break)
	pop_break_entry(s.cur_func)

	if s.cur_func.scopes[for_scope_level].has_using {
		label_catch := s.cur_func.scopes[for_scope_level].using_label_catch
		label_end := s.cur_func.scopes[for_scope_level].using_label_end
		emit_op(s, O(.drop))
		emit_op(s, O(.using_dispose_init))
		emit_op(s, OP_dispose_scope)
		emit_u16(s, u16(for_scope_level))
		emit_op(s, O(.using_dispose_end))
		emit_goto(s, O(.goto), label_end)
		emit_label(s, label_catch)
		emit_op(s, OP_dispose_scope)
		emit_u16(s, u16(for_scope_level))
		emit_op(s, O(.throw_))
		emit_label(s, label_end)
	}
	pop_scope(s)
	return false
}

@(private = "file")
js_parse_switch :: proc(s: ^Parse_State, label_name: Atom) -> bool {
	break_entry: Block_Env
	if next_token(s) {return true}
	set_eval_ret_undefined(s)
	if js_parse_expr_paren(s) {return true}
	push_scope(s)
	label_break := new_label(s)
	push_break_entry(s.cur_func, &break_entry, label_name, label_break, -1, 1)
	if js_parse_expect(s, '{') {return true}
	default_label_pos := -1
	label_case := -1
	for s.token.val != '}' {
		if s.token.val == TOK_CASE {
			label1 := -1
			if label_case >= 0 {
				label1 = emit_goto(s, O(.goto), -1)
			}
			emit_label(s, label_case)
			label_case = -1
			for {
				if next_token(s) {return true}
				emit_op(s, O(.dup))
				if js_parse_expr(s) {return true}
				if js_parse_expect(s, ':') {return true}
				emit_op(s, O(.strict_eq))
				if s.token.val == TOK_CASE {
					label1 = emit_goto(s, O(.if_true), label1)
				} else {
					label_case = emit_goto(s, O(.if_false), -1)
					emit_label(s, label1)
					break
				}
			}
		} else if s.token.val == TOK_DEFAULT {
			if next_token(s) {return true}
			if js_parse_expect(s, ':') {return true}
			if default_label_pos >= 0 {
				return js_parse_error(s, "duplicate default")
			}
			if label_case < 0 {
				label_case = emit_goto(s, O(.goto), -1)
			}
			emit_op(s, OP_label)
			emit_u32(s, 0)
			default_label_pos = len(s.cur_func.byte_code) - 4
		} else {
			if label_case < 0 {
				return js_parse_error(s, "invalid switch statement")
			}
			if token_is_pseudo_keyword(s, A_using) {
				u := is_using(s, false)
				if u < 0 {return true}
				if u != 0 {
					return js_parse_error(s, "using declaration is not allowed in this context")
				}
			}
			if s.token.val == TOK_AWAIT && func_kind_is_async(s.cur_func.func_kind) {
				pos := js_parse_get_pos(s)
				if next_token(s) {return true}
				u := is_using(s, false)
				if u < 0 {return true}
				if js_parse_seek_token(s, &pos) {return true}
				if u != 0 {
					return js_parse_error(s, "await using declaration is not allowed in this context")
				}
			}
			if js_parse_statement_or_decl(s, DECL_MASK_ALL) {return true}
		}
	}
	if js_parse_expect(s, '}') {return true}
	if default_label_pos >= 0 {
		put_u32(s.cur_func.byte_code[:], default_label_pos, u32(label_case))
		s.cur_func.label_slots[label_case].pos = default_label_pos + 4
	} else {
		emit_label(s, label_case)
	}
	emit_label(s, label_break)
	emit_op(s, O(.drop))
	pop_break_entry(s.cur_func)
	pop_scope(s)
	return false
}

@(private = "file")
js_parse_try :: proc(s: ^Parse_State) -> bool {
	block_env: Block_Env
	set_eval_ret_undefined(s)
	if next_token(s) {return true}
	label_catch := new_label(s)
	label_catch2 := new_label(s)
	label_finally := new_label(s)
	label_end := new_label(s)

	emit_goto(s, O(.catch), label_catch)
	push_break_entry(s.cur_func, &block_env, JS_ATOM_NULL, -1, -1, 1)
	block_env.label_finally = label_finally
	if js_parse_block(s) {return true}
	pop_break_entry(s.cur_func)
	if js_is_live_code(s) {
		emit_op(s, O(.drop))
		emit_op(s, O(.undefined))
		emit_goto(s, O(.gosub), label_finally)
		emit_op(s, O(.drop))
		emit_goto(s, O(.goto), label_end)
	}
	if s.token.val == TOK_CATCH {
		if next_token(s) {return true}
		push_scope(s)
		emit_label(s, label_catch)
		if s.token.val == '{' {
			emit_op(s, O(.drop))
		} else {
			if js_parse_expect(s, '(') {return true}
			if !(s.token.val == TOK_IDENT && !s.token.is_reserved) {
				if s.token.val == '[' || s.token.val == '{' {
					if js_parse_destructuring_element(s, TOK_LET, false, true, -1, true, false) < 0 {return true}
				} else {
					return js_parse_error(s, "identifier expected")
				}
			} else {
				name := s.token.atom
				if next_token(s) {return true}
				if js_define_var(s, name, TOK_CATCH) {return true}
				emit_op(s, OP_scope_put_var)
				emit_u32(s, u32(name))
				emit_u16(s, u16(s.cur_func.scope_level))
			}
			if js_parse_expect(s, ')') {return true}
		}
		emit_goto(s, O(.catch), label_catch2)
		push_scope(s)
		push_break_entry(s.cur_func, &block_env, JS_ATOM_NULL, -1, -1, 1)
		block_env.label_finally = label_finally
		if js_parse_block(s) {return true}
		pop_break_entry(s.cur_func)
		pop_scope(s)
		pop_scope(s)
		if js_is_live_code(s) {
			emit_op(s, O(.drop))
			emit_op(s, O(.undefined))
			emit_goto(s, O(.gosub), label_finally)
			emit_op(s, O(.drop))
			emit_goto(s, O(.goto), label_end)
		}
		emit_label(s, label_catch2)
		emit_goto(s, O(.gosub), label_finally)
		emit_op(s, O(.throw_))
	} else if s.token.val == TOK_FINALLY {
		emit_label(s, label_catch)
		emit_goto(s, O(.gosub), label_finally)
		emit_op(s, O(.throw_))
	} else {
		return js_parse_error(s, "expecting catch or finally")
	}
	emit_label(s, label_finally)
	if s.token.val == TOK_FINALLY {
		saved_eval_ret_idx := 0
		if next_token(s) {return true}
		push_break_entry(s.cur_func, &block_env, JS_ATOM_NULL, -1, -1, 2)
		if s.cur_func.eval_ret_idx >= 0 {
			saved_eval_ret_idx = add_var(s, s.cur_func, A__ret_)
			if saved_eval_ret_idx < 0 {return true}
			emit_op(s, O(.get_loc))
			emit_u16(s, u16(s.cur_func.eval_ret_idx))
			emit_op(s, O(.put_loc))
			emit_u16(s, u16(saved_eval_ret_idx))
			set_eval_ret_undefined(s)
		}
		if js_parse_block(s) {return true}
		if s.cur_func.eval_ret_idx >= 0 {
			emit_op(s, O(.get_loc))
			emit_u16(s, u16(saved_eval_ret_idx))
			emit_op(s, O(.put_loc))
			emit_u16(s, u16(s.cur_func.eval_ret_idx))
		}
		pop_break_entry(s.cur_func)
	}
	emit_op(s, O(.ret))
	emit_label(s, label_end)
	return false
}
