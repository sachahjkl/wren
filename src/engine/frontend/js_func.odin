package frontend

// Function definitions and the program entry: js_new_function_def, directives, parameter lists, function
// bodies (js_parse_function_decl2) and js_parse_program.

js_new_function_def :: proc(s: ^Parse_State, parent: ^Func_Def, is_eval, is_func_expr: bool, line_num, col_num: int) -> ^Func_Def {
	a := s.allocator
	fd := new(Func_Def, a)
	fd.child_list = make([dynamic]^Func_Def, a)
	fd.parent = parent
	fd.parent_cpool_idx = -1
	if parent != nil {
		append(&parent.child_list, fd)
		fd.is_strict_mode = parent.is_strict_mode
		fd.parent_scope_level = parent.scope_level
	}
	fd.is_eval = is_eval
	fd.is_func_expr = is_func_expr
	fd.byte_code = make([dynamic]u8, 0, 64, a)
	fd.last_opcode_pos = -1
	fd.func_name = JS_ATOM_NULL
	fd.var_object_idx = -1
	fd.arg_var_object_idx = -1
	fd.arguments_var_idx = -1
	fd.arguments_arg_idx = -1
	fd.func_var_idx = -1
	fd.eval_ret_idx = -1
	fd.this_var_idx = -1
	fd.new_target_var_idx = -1
	fd.this_active_func_var_idx = -1
	fd.home_object_var_idx = -1
	fd.vars = make([dynamic]Var_Def, a)
	fd.args = make([dynamic]Var_Def, a)
	fd.scopes = make([dynamic]Var_Scope, 0, 4, a)
	append(&fd.scopes, Var_Scope{parent = -1, first = -1, using_label_catch = -1, using_label_end = -1})
	fd.scope_level = 0
	fd.scope_first = -1
	fd.body_scope = -1
	fd.global_vars = make([dynamic]Global_Var, a)
	fd.label_slots = make([dynamic]Label_Slot, a)
	fd.cpool = make([dynamic]JS_Value, a)
	fd.closure_var = make([dynamic]Closure_Var, a)
	fd.jump_slots = make([dynamic]Jump_Slot, a)
	fd.source_loc_slots = make([dynamic]Source_Loc_Slot, a)
	fd.filename = s.filename
	fd.line_num = line_num
	fd.col_num = col_num
	fd.pc2line = make([dynamic]u8, a)
	return fd
}

js_parse_directives :: proc(s: ^Parse_State) -> bool {
	if s.token.val != TOK_STRING {return false}
	pos := js_parse_get_pos(s)
	for s.token.val == TOK_STRING {
		// the raw source text between the quotes, truncated like the C's 20-byte buffer
		raw_len := s.buf_ptr - s.token.ptr - 2
		if raw_len < 0 {raw_len = 0}
		if raw_len > 19 {raw_len = 19}
		str := string(s.buf[s.token.ptr + 1:][:raw_len])
		if next_token(s) {return true}
		has_semi := false
		switch s.token.val {
		case ';':
			if next_token(s) {return true}
			has_semi = true
		case '}', TOK_EOF:
			has_semi = true
		case TOK_NUMBER, TOK_STRING, TOK_TEMPLATE, TOK_IDENT, TOK_REGEXP, TOK_DEC, TOK_INC, TOK_NULL, TOK_FALSE,
		     TOK_TRUE, TOK_IF, TOK_RETURN, TOK_VAR, TOK_USING, TOK_THIS, TOK_DELETE, TOK_TYPEOF, TOK_NEW, TOK_DO,
		     TOK_WHILE, TOK_FOR, TOK_SWITCH, TOK_THROW, TOK_TRY, TOK_FUNCTION, TOK_DEBUGGER, TOK_WITH, TOK_CLASS,
		     TOK_CONST, TOK_ENUM, TOK_EXPORT, TOK_IMPORT, TOK_SUPER, TOK_INTERFACE, TOK_LET, TOK_PACKAGE,
		     TOK_PRIVATE, TOK_PROTECTED, TOK_PUBLIC, TOK_STATIC:
			if s.got_lf {has_semi = true}
		}
		if !has_semi {break}
		if str == "use strict" {
			s.cur_func.has_use_strict = true
			s.cur_func.is_strict_mode = true
		}
	}
	return js_parse_seek_token(s, &pos)
}

js_invalid_strict_name :: proc(name: Atom) -> bool {
	switch name {
	case A_eval, A_arguments, Atom(38), Atom(39), A_let, Atom(41), Atom(42), Atom(43), Atom(44), A_static, A_yield:
		// eval arguments implements interface let package private protected public static yield
		return true
	}
	return false
}

js_parse_function_check_names :: proc(s: ^Parse_State, fd: ^Func_Def, func_name: Atom) -> bool {
	if fd.is_strict_mode {
		if !fd.has_simple_parameter_list && fd.has_use_strict {
			return js_parse_error(s, "\"use strict\" not allowed in function with default or destructuring parameter")
		}
		if js_invalid_strict_name(func_name) {
			return js_parse_error(s, "invalid function name in strict code")
		}
		for a in fd.args {
			if js_invalid_strict_name(a.var_name) {
				return js_parse_error(s, "invalid argument name in strict code")
			}
		}
	}
	if fd.is_strict_mode || !fd.has_simple_parameter_list || (fd.func_type == .method && fd.func_kind == .async) ||
	   fd.func_type == .arrow || fd.func_type == .method {
		for idx in 0 ..< len(fd.args) {
			name := fd.args[idx].var_name
			if name != JS_ATOM_NULL {
				for i in 0 ..< idx {
					if fd.args[i].var_name == name {
						return js_parse_error(s, "Duplicate parameter name not allowed in this context")
					}
				}
				for v in fd.vars {
					if v.var_name == name && v.scope_level == 0 {
						return js_parse_error(s, "Duplicate parameter name not allowed in this context")
					}
				}
			}
		}
	}
	return false
}

js_parse_function_class_fields_init :: proc(s: ^Parse_State) -> ^Func_Def {
	fd := js_new_function_def(s, s.cur_func, false, false, 0, 0)
	fd.func_name = JS_ATOM_NULL
	fd.has_prototype = false
	fd.has_home_object = true
	fd.has_arguments_binding = false
	fd.has_this_binding = true
	fd.is_derived_class_constructor = false
	fd.new_target_allowed = true
	fd.super_call_allowed = false
	fd.super_allowed = fd.has_home_object
	fd.arguments_allowed = false
	fd.func_kind = .normal
	fd.func_type = .method
	return fd
}

js_parse_function_decl :: proc(s: ^Parse_State, func_type: Parse_Func, func_kind: Func_Kind, func_name: Atom, ptr: int, start_line, start_col: int) -> bool {
	return js_parse_function_decl2(s, func_type, func_kind, func_name, ptr, start_line, start_col, .none, nil)
}

js_parse_function_decl2 :: proc(s: ^Parse_State, func_type: Parse_Func, func_kind0: Func_Kind, func_name0: Atom, ptr: int, function_line_num, function_col_num: int, export_flag: Parse_Export, pfd: ^^Func_Def) -> bool {
	if stack_exhausted(s.stack) {
		return js_parse_error(s, "stack overflow")
	}
	fd := s.cur_func
	func_kind := func_kind0
	func_name := func_name0
	lexical_func_idx := -1
	create_func_var := false
	is_expr := func_type != .statement && func_type != .var_

	if func_type == .statement || func_type == .var_ || func_type == .expr {
		if func_kind == .normal && token_is_pseudo_keyword(s, A_async) && peek_token(s, true) != '\n' {
			if next_token(s) {return true}
			func_kind = .async
		}
		if next_token(s) {return true}
		if s.token.val == '*' {
			if next_token(s) {return true}
			func_kind = Func_Kind(u8(func_kind) | u8(Func_Kind.generator))
		}
		if s.token.val == TOK_IDENT {
			if s.token.is_reserved ||
			   (s.token.atom == A_yield && func_type == .expr && func_kind_is_generator(func_kind)) ||
			   (s.token.atom == A_await && ((func_type == .expr && func_kind_is_async(func_kind)) || func_type == .class_static_init)) {
				return js_parse_error_reserved_identifier(s)
			}
		}
		if s.token.val == TOK_IDENT ||
		   (((s.token.val == TOK_YIELD && !fd.is_strict_mode) || (s.token.val == TOK_AWAIT && !s.is_module)) && func_type == .expr) {
			func_name = s.token.atom
			if next_token(s) {return true}
		} else {
			if func_type != .expr && export_flag != .default_ {
				return js_parse_error(s, "function name expected")
			}
		}
	}

	if fd.is_eval && fd.eval_type == .module && (func_type == .statement || func_type == .var_) {
		hf := find_global_var(fd, func_name)
		if hf != nil && hf.scope_level == fd.scope_level {
			return js_parse_error(s, "invalid redefinition of global identifier in module code")
		}
	}

	if func_type == .var_ {
		if !fd.is_strict_mode && func_kind == .normal && find_lexical_decl(fd, func_name, fd.scope_first, false) < 0 {
			func_idx := find_var(fd, func_name)
			if !(func_idx >= 0 && (func_idx & ARGUMENT_VAR_OFFSET) != 0) && !(func_name == A_arguments && fd.has_arguments_binding) {
				create_func_var = true
			}
		}
		if fd.is_eval && (fd.eval_type == .global || fd.eval_type == .module) && fd.scope_level == fd.body_scope {
			hf := find_global_var(fd, func_name)
			if hf != nil && hf.scope_level == fd.scope_level {
				return js_parse_error(s, "invalid redefinition of global identifier")
			}
		} else {
			lexical_func_idx = define_var(s, fd, func_name, func_kind != .normal ? .new_function_decl : .function_decl)
			if lexical_func_idx < 0 {return true}
		}
	}

	fd = js_new_function_def(s, fd, false, is_expr, function_line_num, function_col_num)
	if pfd != nil {pfd^ = fd}
	s.cur_func = fd
	fd.func_name = func_name
	fd.has_prototype = (func_type == .statement || func_type == .var_ || func_type == .expr) && func_kind == .normal
	fd.has_home_object = func_type == .method || func_type == .getter || func_type == .setter ||
		func_type == .class_constructor || func_type == .derived_class_constructor
	fd.has_arguments_binding = func_type != .arrow && func_type != .class_static_init
	fd.has_this_binding = fd.has_arguments_binding
	fd.is_derived_class_constructor = func_type == .derived_class_constructor
	if func_type == .arrow {
		fd.new_target_allowed = fd.parent.new_target_allowed
		fd.super_call_allowed = fd.parent.super_call_allowed
		fd.super_allowed = fd.parent.super_allowed
		fd.arguments_allowed = fd.parent.arguments_allowed
	} else if func_type == .class_static_init {
		fd.new_target_allowed = true
		fd.super_call_allowed = false
		fd.super_allowed = true
		fd.arguments_allowed = false
	} else {
		fd.new_target_allowed = true
		fd.super_call_allowed = fd.is_derived_class_constructor
		fd.super_allowed = fd.has_home_object
		fd.arguments_allowed = true
	}
	fd.func_kind = func_kind
	fd.func_type = func_type

	if func_type == .class_constructor || func_type == .derived_class_constructor {
		emit_op(s, O(.check_ctor))
	}
	if func_type == .class_constructor {
		emit_class_field_init(s)
	}

	fd.has_simple_parameter_list = true
	fd.has_parameter_expressions = false
	has_opt_arg := false
	if func_type == .arrow && s.token.val == TOK_IDENT {
		if s.token.is_reserved {
			return js_parse_error_reserved_identifier(s)
		}
		if add_arg(s, fd, s.token.atom) < 0 {return true}
		fd.defined_arg_count = 1
	} else if func_type != .class_static_init {
		if s.token.val == '(' {
			skip_bits: int
			js_parse_skip_parens_token(s, &skip_bits, false)
			if (skip_bits & SKIP_HAS_ASSIGNMENT) != 0 {
				fd.has_parameter_expressions = true
			}
			if next_token(s) {return true}
		} else {
			if js_parse_expect(s, '(') {return true}
		}
		if fd.has_parameter_expressions {
			fd.scope_level = -1
			push_scope(s)
		}
		for s.token.val != ')' {
			rest := false
			if s.token.val == TOK_ELLIPSIS {
				fd.has_simple_parameter_list = false
				rest = true
				if next_token(s) {return true}
			}
			if s.token.val == '[' || s.token.val == '{' {
				fd.has_simple_parameter_list = false
				if rest {
					emit_op(s, O(.rest))
					emit_u16(s, u16(len(fd.args)))
				} else {
					idx := add_arg(s, fd, JS_ATOM_NULL)
					emit_op(s, O(.get_arg))
					emit_u16(s, u16(idx))
				}
				has_initializer := js_parse_destructuring_element(s, fd.has_parameter_expressions ? TOK_LET : TOK_VAR, true, true, -1, true, false)
				if has_initializer < 0 {return true}
				if has_initializer != 0 {has_opt_arg = true}
				if !has_opt_arg {fd.defined_arg_count += 1}
			} else if s.token.val == TOK_IDENT {
				if s.token.is_reserved {
					return js_parse_error_reserved_identifier(s)
				}
				name := s.token.atom
				if name == A_yield && fd.func_kind == .generator {
					return js_parse_error_reserved_identifier(s)
				}
				if fd.has_parameter_expressions {
					if js_parse_check_duplicate_parameter(s, name) {return true}
					if define_var(s, fd, name, .let_) < 0 {return true}
				}
				idx := add_arg(s, fd, name)
				if idx < 0 {return true}
				if next_token(s) {return true}
				if rest {
					emit_op(s, O(.rest))
					emit_u16(s, u16(idx))
					if fd.has_parameter_expressions {
						emit_op(s, O(.dup))
						emit_op(s, OP_scope_put_var_init)
						emit_atom(s, name)
						emit_u16(s, u16(fd.scope_level))
					}
					emit_op(s, O(.put_arg))
					emit_u16(s, u16(idx))
					fd.has_simple_parameter_list = false
					has_opt_arg = true
				} else if s.token.val == '=' {
					fd.has_simple_parameter_list = false
					has_opt_arg = true
					if next_token(s) {return true}
					label := new_label(s)
					emit_op(s, O(.get_arg))
					emit_u16(s, u16(idx))
					emit_op(s, O(.dup))
					emit_op(s, O(.undefined))
					emit_op(s, O(.strict_eq))
					emit_goto(s, O(.if_false), label)
					emit_op(s, O(.drop))
					if js_parse_assign_expr(s) {return true}
					set_object_name(s, name)
					emit_op(s, O(.dup))
					emit_op(s, O(.put_arg))
					emit_u16(s, u16(idx))
					emit_label(s, label)
					emit_op(s, OP_scope_put_var_init)
					emit_atom(s, name)
					emit_u16(s, u16(fd.scope_level))
				} else {
					if !has_opt_arg {fd.defined_arg_count += 1}
					if fd.has_parameter_expressions {
						emit_op(s, O(.get_arg))
						emit_u16(s, u16(idx))
						emit_op(s, OP_scope_put_var_init)
						emit_atom(s, name)
						emit_u16(s, u16(fd.scope_level))
					}
				}
			} else {
				return js_parse_error(s, "missing formal parameter")
			}
			if rest && s.token.val != ')' {
				js_parse_expect(s, ')')
				return true
			}
			if s.token.val == ')' {break}
			if js_parse_expect(s, ',') {return true}
		}
		if (func_type == .getter && len(fd.args) != 0) || (func_type == .setter && len(fd.args) != 1) {
			return js_parse_error(s, "invalid number of arguments for getter or setter")
		}
	}

	if fd.has_parameter_expressions {
		idx := fd.scopes[fd.scope_level].first
		for idx >= 0 {
			vd := &fd.vars[idx]
			if vd.scope_level != fd.scope_level {break}
			if find_var(fd, vd.var_name) < 0 {
				if add_var(s, fd, vd.var_name) < 0 {return true}
				vd = &fd.vars[idx]
				emit_op(s, OP_scope_get_var)
				emit_atom(s, vd.var_name)
				emit_u16(s, u16(fd.scope_level))
				emit_op(s, OP_scope_put_var)
				emit_atom(s, vd.var_name)
				emit_u16(s, 0)
			}
			idx = vd.scope_next
		}
		emit_op(s, OP_leave_scope)
		emit_u16(s, u16(fd.scope_level))
		fd.scope_level = 0
		fd.scope_first = fd.scopes[fd.scope_level].first
	}

	if next_token(s) {return true}

	if func_kind == .generator || func_kind == .async_generator {
		emit_op(s, O(.initial_yield))
	}

	fd.in_function_body = true
	push_scope(s)
	fd.body_scope = fd.scope_level

	done := false
	if s.token.val == TOK_ARROW {
		if next_token(s) {return true}
		if s.token.val != '{' {
			if js_parse_function_check_names(s, fd, func_name) {return true}
			if js_parse_assign_expr(s) {return true}
			if func_kind != .normal {
				emit_op(s, O(.return_async))
			} else {
				emit_op(s, O(.ret_))
			}
			done = true
		}
	}
	if !done {
		if func_type != .class_static_init {
			if js_parse_expect(s, '{') {return true}
		}
		if js_parse_directives(s) {return true}
		if js_parse_function_check_names(s, fd, func_name) {return true}

		using_be: Block_Env
		has_using_be := false
		for s.token.val != '}' {
			if js_parse_source_element(s) {return true}
			if !has_using_be && fd.scopes[fd.body_scope].has_using {
				has_using_be = true
				push_break_entry(fd, &using_be, JS_ATOM_NULL, -1, -1, 1)
				using_be.has_using = true
				using_be.using_scope_level = fd.body_scope
			}
		}
		if next_token(s) {return true}
		if has_using_be {
			label_catch := fd.scopes[fd.body_scope].using_label_catch
			label_end := fd.scopes[fd.body_scope].using_label_end
			pop_break_entry(fd)
			if js_is_live_code(s) {
				emit_op(s, O(.drop))
				emit_op(s, O(.using_dispose_init))
				emit_op(s, OP_dispose_scope)
				emit_u16(s, u16(fd.body_scope))
				emit_op(s, O(.using_dispose_end))
				emit_return(s, false)
			}
			emit_label(s, label_catch)
			emit_op(s, OP_dispose_scope)
			emit_u16(s, u16(fd.body_scope))
			emit_op(s, O(.throw_))
			emit_label(s, label_end)
		} else {
			if js_is_live_code(s) {
				emit_return(s, false)
			}
		}
	}

	s.cur_func = fd.parent
	reparse_ident_token(s)

	{
		fn := fd.func_name
		idx := cpool_add(s, JS_Null{})
		fd.parent_cpool_idx = idx
		if is_expr {
			if func_type != .class_constructor && func_type != .derived_class_constructor {
				emit_op(s, O(.fclosure))
				emit_u32(s, u32(idx))
				if fn == JS_ATOM_NULL {
					emit_op(s, O(.set_name))
					emit_u32(s, u32(JS_ATOM_NULL))
				}
			}
		} else if func_type == .var_ {
			emit_op(s, O(.fclosure))
			emit_u32(s, u32(idx))
			if create_func_var {
				if s.cur_func.is_global_var {
					hf := add_global_var(s.cur_func, fn)
					hf.scope_level = 0
					hf.force_init = s.cur_func.is_strict_mode
					emit_op(s, O(.dup))
					emit_op(s, OP_scope_put_var)
					emit_atom(s, fn)
					emit_u16(s, 0)
				} else {
					func_idx := find_var(s.cur_func, fn)
					if func_idx < 0 {
						func_idx = add_var(s, s.cur_func, fn)
						if func_idx < 0 {return true}
					}
					emit_op(s, O(.dup))
					emit_op(s, OP_scope_put_var)
					emit_atom(s, fn)
					emit_u16(s, 0)
				}
			}
			if lexical_func_idx >= 0 {
				s.cur_func.vars[lexical_func_idx].func_pool_idx = idx
				emit_op(s, O(.drop))
			} else {
				emit_op(s, OP_scope_put_var_init)
				emit_atom(s, fn)
				emit_u16(s, u16(s.cur_func.scope_level))
			}
		} else {
			if !s.cur_func.is_global_var {
				var_idx := define_var(s, s.cur_func, fn, .var_)
				if var_idx < 0 {return true}
				if (var_idx & ARGUMENT_VAR_OFFSET) != 0 {
					s.cur_func.args[var_idx - ARGUMENT_VAR_OFFSET].func_pool_idx = idx
				} else {
					s.cur_func.vars[var_idx].func_pool_idx = idx
				}
			} else {
				func_var_name := fn == JS_ATOM_NULL ? A__default_ : fn
				hf := add_global_var(s.cur_func, func_var_name)
				hf.cpool_idx = idx
				if export_flag != .none {
					if add_export_entry(s, s.cur_func.module, func_var_name, export_flag == .named ? func_var_name : A_default, .local) {return true}
				}
			}
		}
	}
	return false
}

js_parse_program :: proc(s: ^Parse_State) -> bool {
	fd := s.cur_func
	using_be: Block_Env
	has_using_be := false
	if next_token(s) {return true}
	if js_parse_directives(s) {return true}
	fd.is_global_var = fd.eval_type == .global || fd.eval_type == .module || !fd.is_strict_mode
	if !s.is_module {
		idx := add_var(s, fd, A__ret_)
		fd.eval_ret_idx = idx
		if idx < 0 {return true}
	}
	for s.token.val != TOK_EOF {
		if js_parse_source_element(s) {return true}
		if !has_using_be && fd.scopes[fd.body_scope].has_using {
			has_using_be = true
			push_break_entry(fd, &using_be, JS_ATOM_NULL, -1, -1, 1)
			using_be.has_using = true
			using_be.using_scope_level = fd.body_scope
		}
	}
	emit_result :: proc(s: ^Parse_State, fd: ^Func_Def) {
		if !s.is_module {
			if fd.func_kind == .async {
				emit_op(s, O(.object))
				emit_op(s, O(.dup))
				emit_op(s, O(.get_loc))
				emit_u16(s, u16(fd.eval_ret_idx))
				emit_op(s, O(.put_field))
				emit_atom(s, A_value)
			} else {
				emit_op(s, O(.get_loc))
				emit_u16(s, u16(fd.eval_ret_idx))
			}
			emit_return(s, true)
		} else {
			emit_return(s, false)
		}
	}
	if has_using_be {
		label_catch := fd.scopes[fd.body_scope].using_label_catch
		label_end := fd.scopes[fd.body_scope].using_label_end
		pop_break_entry(fd)
		if js_is_live_code(s) {
			emit_op(s, O(.drop))
			emit_op(s, O(.using_dispose_init))
			emit_op(s, OP_dispose_scope)
			emit_u16(s, u16(fd.body_scope))
			emit_op(s, O(.using_dispose_end))
		}
		emit_result(s, fd)
		emit_label(s, label_catch)
		emit_op(s, OP_dispose_scope)
		emit_u16(s, u16(fd.body_scope))
		emit_op(s, O(.throw_))
		emit_label(s, label_end)
	} else {
		emit_result(s, fd)
	}
	return false
}
