package frontend

// Expressions, as QuickJS's js_parse_* functions: parsing and phase-1 emission happen in one pass, and several
// decisions are taken by looking at (and rewriting) the last emitted instruction. Every procedure returns true
// on a syntax error (the C `-1`), so the bodies read like the original.

PF_IN_ACCEPTED :: 1 << 0
PF_POSTFIX_CALL :: 1 << 1
PF_POW_ALLOWED :: 1 << 2
PF_POW_FORBIDDEN :: 1 << 3
PF_AWAIT_USING :: 1 << 4

PROP_TYPE_IDENT :: 0
PROP_TYPE_VAR :: 1
PROP_TYPE_GET :: 2
PROP_TYPE_SET :: 3
PROP_TYPE_STAR :: 4
PROP_TYPE_ASYNC :: 5
PROP_TYPE_ASYNC_STAR :: 6
PROP_TYPE_PRIVATE :: 1 << 4

Put_LValue :: enum u8 {
	nokeep,        // [depth] v ->
	nokeep_depth,  // [depth] v -> , keep depth (disables optimizations)
	keep_top,      // [depth] v -> v
	keep_second,   // [depth] v0 v -> v0
	nokeep_bottom, // v [depth] ->
}

Func_Call_Type :: enum u8 {
	normal,
	new_,
	super_ctor,
	template,
}

// --- templates ----------------------------------------------------------------------------------------------

js_parse_template :: proc(s: ^Parse_State, call: bool, argc: ^int) -> bool {
	template_object: ^Template_Object
	cooked_list: [dynamic]Maybe(String_Value)
	raw_list: [dynamic]String_Value
	if call {
		template_object = new(Template_Object, s.allocator)
		emit_push_const(s, template_object, false)
		cooked_list = make([dynamic]Maybe(String_Value), s.allocator)
		raw_list = make([dynamic]String_Value, s.allocator)
	}
	depth := 0
	for s.token.val == TOK_TEMPLATE {
		p := s.token.ptr + 1
		cooked: JS_Token
		if call {
			append(&raw_list, s.token.str)
			_, failed := js_parse_string(s, '`', false, p, &cooked)
			if failed {
				append(&cooked_list, nil)
			} else {
				append(&cooked_list, cooked.str)
			}
		} else {
			_, failed := js_parse_string(s, '`', true, p, &cooked)
			if failed {return true}
			str := cooked.str
			if string_len(str) != 0 || depth == 0 {
				emit_push_const(s, str, true)
				if depth == 0 {
					if s.token.sep == '`' {
						return next_token(s)
					}
					emit_op(s, O(.get_field2))
					emit_atom(s, A_concat)
				}
				depth += 1
			}
		}
		if s.token.sep == '`' {
			if call {
				template_object.cooked = cooked_list[:]
				template_object.raw = raw_list[:]
				argc^ = depth + 1
			} else {
				emit_op(s, O(.call_method))
				emit_u16(s, u16(depth - 1))
			}
			return next_token(s)
		}
		if next_token(s) {return true}
		if js_parse_expr(s) {return true}
		depth += 1
		if s.token.val != '}' {
			return js_parse_error(s, "expected '}' after template expression")
		}
		s.got_lf = false
		s.last_line_num = s.token.line_num
		s.last_col_num = s.token.col_num
		if js_parse_template_part(s, s.buf_ptr) {return true}
	}
	return js_parse_expect(s, TOK_TEMPLATE)
}

// --- property names -----------------------------------------------------------------------------------------

token_is_ident :: #force_inline proc(tok: int) -> bool {
	return tok == TOK_IDENT || (tok >= TOK_FIRST_KEYWORD && tok <= TOK_LAST_KEYWORD)
}

// js_parse_property_name returns the property type (or -1) and the name (JS_ATOM_NULL for a computed key,
// whose value is then on the stack).
js_parse_property_name :: proc(s: ^Parse_State, pname: ^Atom, allow_method, allow_var, allow_private: bool) -> int {
	is_private := 0
	is_non_reserved_ident := false
	name: Atom
	prop_type := PROP_TYPE_IDENT
	ident_found := false
	pname^ = JS_ATOM_NULL
	if allow_method {
		if token_is_pseudo_keyword(s, A_get) || token_is_pseudo_keyword(s, A_set) {
			name = s.token.atom
			if next_token(s) {return -1}
			if s.token.val == ':' || s.token.val == ',' || s.token.val == '}' || s.token.val == '(' || s.token.val == '=' || s.token.val == ';' {
				is_non_reserved_ident = true
				ident_found = true
			} else {
				prop_type = PROP_TYPE_GET + (name == A_set ? 1 : 0)
			}
		} else if s.token.val == '*' {
			if next_token(s) {return -1}
			prop_type = PROP_TYPE_STAR
		} else if token_is_pseudo_keyword(s, A_async) && peek_token(s, true) != '\n' {
			name = s.token.atom
			if next_token(s) {return -1}
			if s.token.val == ':' || s.token.val == ',' || s.token.val == '}' || s.token.val == '(' || s.token.val == '=' || s.token.val == ';' {
				is_non_reserved_ident = true
				ident_found = true
			} else if s.token.val == '*' {
				if next_token(s) {return -1}
				prop_type = PROP_TYPE_ASYNC_STAR
			} else {
				prop_type = PROP_TYPE_ASYNC
			}
		}
	}
	if ident_found || token_is_ident(s.token.val) {
		if !ident_found {
			is_non_reserved_ident = s.token.val == TOK_IDENT && !s.token.is_reserved
			name = s.token.atom
			if next_token(s) {return -1}
		}
		if is_non_reserved_ident && prop_type == PROP_TYPE_IDENT && allow_var {
			if !(s.token.val == ':' || (s.token.val == '(' && allow_method)) {
				prop_type = PROP_TYPE_VAR
			}
		}
	} else if s.token.val == TOK_STRING {
		name = atom_from_string(s.atoms, s.token.str)
		if next_token(s) {return -1}
	} else if s.token.val == TOK_NUMBER {
		name = atom_from_number(s, s.token.num)
		if next_token(s) {return -1}
	} else if s.token.val == '[' {
		if next_token(s) {return -1}
		if js_parse_expr(s) {return -1}
		if js_parse_expect(s, ']') {return -1}
		name = JS_ATOM_NULL
	} else if s.token.val == TOK_PRIVATE_NAME && allow_private {
		name = s.token.atom
		if next_token(s) {return -1}
		is_private = PROP_TYPE_PRIVATE
	} else {
		js_parse_error(s, "invalid property name")
		return -1
	}
	if prop_type != PROP_TYPE_IDENT && prop_type != PROP_TYPE_VAR && s.token.val != '(' {
		js_parse_error(s, "invalid property name")
		return -1
	}
	pname^ = name
	return prop_type | is_private
}

// atom_from_number is JS_ValueToAtom on a number token: an int32 >= 0 is a tagged int, anything else goes
// through Number::toString.
atom_from_number :: proc(s: ^Parse_State, v: JS_Value) -> Atom {
	#partial switch n in v {
	case i32:
		if n >= 0 {return atom_from_uint32(u32(n))}
		return atom_from_string(s.atoms, string_from_utf8(number_to_js_string(f64(n)), s.allocator))
	case f64:
		return atom_from_string(s.atoms, string_from_utf8(number_to_js_string(n), s.allocator))
	case Big_Int:
		return atom_from_string(s.atoms, string_from_utf8(bigint_to_decimal(n, s.allocator), s.allocator))
	}
	return JS_ATOM_NULL
}

// --- object names -------------------------------------------------------------------------------------------

set_object_name :: proc(s: ^Parse_State, name: Atom) {
	fd := s.cur_func
	opcode := get_prev_opcode(fd)
	if opcode == O(.set_name) {
		resize(&fd.byte_code, fd.last_opcode_pos)
		fd.last_opcode_pos = -1
		emit_op(s, O(.set_name))
		emit_atom(s, name)
	} else if opcode == OP_set_class_name {
		define_class_pos := fd.last_opcode_pos + 1 - int(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		put_u32(fd.byte_code[:], define_class_pos + 1, u32(name))
		fd.last_opcode_pos = -1
	}
}

set_object_name_computed :: proc(s: ^Parse_State) {
	fd := s.cur_func
	opcode := get_prev_opcode(fd)
	if opcode == O(.set_name) {
		resize(&fd.byte_code, fd.last_opcode_pos)
		fd.last_opcode_pos = -1
		emit_op(s, O(.set_name_computed))
	} else if opcode == OP_set_class_name {
		define_class_pos := fd.last_opcode_pos + 1 - int(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		fd.byte_code[define_class_pos] = u8(O(.define_class_computed))
		fd.last_opcode_pos = -1
	}
}

// --- object literal -----------------------------------------------------------------------------------------

js_parse_object_literal :: proc(s: ^Parse_State) -> bool {
	name: Atom
	if next_token(s) {return true}
	emit_op(s, O(.object))
	has_proto := false
	for s.token.val != '}' {
		start_ptr := s.token.ptr
		start_line := s.token.line_num
		start_col := s.token.col_num
		if s.token.val == TOK_ELLIPSIS {
			if next_token(s) {return true}
			if js_parse_assign_expr(s) {return true}
			emit_op(s, O(.null))
			emit_op(s, O(.copy_data_properties))
			emit_u8(s, 2 | (1 << 2) | (0 << 5))
			emit_op(s, O(.drop))
			emit_op(s, O(.drop))
		} else {
			prop_type := js_parse_property_name(s, &name, true, true, false)
			if prop_type < 0 {return true}
			if prop_type == PROP_TYPE_VAR {
				emit_op(s, OP_scope_get_var)
				emit_atom(s, name)
				emit_u16(s, u16(s.cur_func.scope_level))
				emit_op(s, O(.define_field))
				emit_atom(s, name)
			} else if s.token.val == '(' {
				is_getset := prop_type == PROP_TYPE_GET || prop_type == PROP_TYPE_SET
				func_type: Parse_Func
				func_kind := Func_Kind.normal
				if is_getset {
					func_type = prop_type == PROP_TYPE_GET ? .getter : .setter
				} else {
					func_type = .method
					if prop_type == PROP_TYPE_STAR {
						func_kind = .generator
					} else if prop_type == PROP_TYPE_ASYNC {
						func_kind = .async
					} else if prop_type == PROP_TYPE_ASYNC_STAR {
						func_kind = .async_generator
					}
				}
				if js_parse_function_decl(s, func_type, func_kind, JS_ATOM_NULL, start_ptr, start_line, start_col) {return true}
				if name == JS_ATOM_NULL {
					emit_op(s, O(.define_method_computed))
				} else {
					emit_op(s, O(.define_method))
					emit_atom(s, name)
				}
				op_flags: int
				if is_getset {
					op_flags = OP_DEFINE_METHOD_GETTER + prop_type - PROP_TYPE_GET
				} else {
					op_flags = OP_DEFINE_METHOD_METHOD
				}
				emit_u8(s, u8(op_flags | OP_DEFINE_METHOD_ENUMERABLE))
			} else {
				if js_parse_expect(s, ':') {return true}
				if js_parse_assign_expr(s) {return true}
				if name == JS_ATOM_NULL {
					set_object_name_computed(s)
					emit_op(s, O(.define_array_el))
					emit_op(s, O(.drop))
				} else if name == A___proto__ {
					if has_proto {
						return js_parse_error(s, "duplicate __proto__ property name")
					}
					emit_op(s, O(.set_proto))
					has_proto = true
				} else {
					set_object_name(s, name)
					emit_op(s, O(.define_field))
					emit_atom(s, name)
				}
			}
		}
		name = JS_ATOM_NULL
		if s.token.val != ',' {break}
		if next_token(s) {return true}
	}
	return js_parse_expect(s, '}')
}

// --- classes ------------------------------------------------------------------------------------------------

find_private_class_field :: proc(fd: ^Func_Def, name: Atom, scope_level: int) -> int {
	idx := fd.scopes[scope_level].first
	for idx != -1 {
		if fd.vars[idx].scope_level != scope_level {break}
		if fd.vars[idx].var_name == name {return idx}
		idx = fd.vars[idx].scope_next
	}
	return -1
}

emit_class_field_init :: proc(s: ^Parse_State) {
	emit_op(s, OP_scope_get_var)
	emit_atom(s, A_class_fields_init)
	emit_u16(s, u16(s.cur_func.scope_level))
	emit_op(s, O(.dup))
	label_next := emit_goto(s, O(.if_false), -1)
	emit_op(s, OP_scope_get_var)
	emit_atom(s, A_this)
	emit_u16(s, 0)
	emit_op(s, O(.swap))
	emit_op(s, O(.call_method))
	emit_u16(s, 0)
	emit_label(s, label_next)
	emit_op(s, O(.drop))
}

Class_Fields_Def :: struct {
	fields_init_fd:        ^Func_Def,
	computed_fields_count: int,
	need_brand:            bool,
	brand_push_pos:        int,
	is_static:             bool,
}

emit_class_init_start :: proc(s: ^Parse_State, cf: ^Class_Fields_Def) -> bool {
	cf.fields_init_fd = js_parse_function_class_fields_init(s)
	if cf.fields_init_fd == nil {return true}
	s.cur_func = cf.fields_init_fd
	if !cf.is_static {
		emit_op(s, O(.push_false))
		cf.brand_push_pos = cf.fields_init_fd.last_opcode_pos
		label_add_brand := emit_goto(s, O(.if_false), -1)
		emit_op(s, OP_scope_get_var)
		emit_atom(s, A_this)
		emit_u16(s, 0)
		emit_op(s, OP_scope_get_var)
		emit_atom(s, A_home_object)
		emit_u16(s, 0)
		emit_op(s, O(.add_brand))
		emit_label(s, label_add_brand)
	}
	s.cur_func = s.cur_func.parent
	return false
}

emit_class_init_end :: proc(s: ^Parse_State, cf: ^Class_Fields_Def) {
	s.cur_func = cf.fields_init_fd
	emit_op(s, O(.return_undef))
	s.cur_func = s.cur_func.parent
	cpool_idx := cpool_add(s, JS_Null{})
	cf.fields_init_fd.parent_cpool_idx = cpool_idx
	emit_op(s, O(.fclosure))
	emit_u32(s, u32(cpool_idx))
	emit_op(s, O(.set_home_object))
}

js_parse_class_default_ctor :: proc(s: ^Parse_State, has_super: bool, pfd: ^^Func_Def) -> bool {
	fd := js_new_function_def(s, s.cur_func, false, false, s.token.line_num, s.token.col_num)
	s.cur_func = fd
	fd.has_home_object = true
	fd.super_allowed = true
	fd.has_prototype = false
	fd.has_this_binding = true
	fd.new_target_allowed = true
	push_scope(s)
	fd.body_scope = fd.scope_level
	func_type: Parse_Func
	if has_super {
		fd.is_derived_class_constructor = true
		fd.super_call_allowed = true
		fd.arguments_allowed = true
		fd.has_arguments_binding = true
		func_type = .derived_class_constructor
		emit_op(s, O(.init_ctor))
		emit_op(s, OP_scope_put_var_init)
		emit_atom(s, A_this)
		emit_u16(s, 0)
		emit_class_field_init(s)
	} else {
		func_type = .class_constructor
		emit_op(s, O(.check_ctor))
		emit_class_field_init(s)
	}
	fd.func_kind = .normal
	fd.func_type = func_type
	emit_return(s, false)
	s.cur_func = fd.parent
	if pfd != nil {pfd^ = fd}
	idx := cpool_add(s, JS_Null{})
	fd.parent_cpool_idx = idx
	return false
}

js_parse_class :: proc(s: ^Parse_State, is_class_expr: bool, export_flag: Parse_Export) -> bool {
	fd := s.cur_func
	name, class_name, class_name1, class_var_name: Atom
	class_flags := 0
	class_fields: [2]Class_Fields_Def
	ctor_fd: ^Func_Def
	method_fd: ^Func_Def

	is_strict_mode := fd.is_strict_mode
	fd.is_strict_mode = true
	defer fd.is_strict_mode = is_strict_mode

	if next_token(s) {return true}
	if s.token.val == TOK_IDENT {
		if s.token.is_reserved {
			return js_parse_error_reserved_identifier(s)
		}
		class_name = s.token.atom
		if next_token(s) {return true}
	} else if !is_class_expr && export_flag != .default_ {
		return js_parse_error(s, "class statement requires a name")
	}
	if !is_class_expr {
		class_var_name = class_name == JS_ATOM_NULL ? A__default_ : class_name
	}

	push_scope(s)

	if s.token.val == TOK_EXTENDS {
		class_flags = JS_DEFINE_CLASS_HAS_HERITAGE
		if next_token(s) {return true}
		if js_parse_left_hand_side_expr(s) {return true}
	} else {
		emit_op(s, O(.undefined))
	}

	if class_name != JS_ATOM_NULL {
		if define_var(s, fd, class_name, .const_) < 0 {return true}
	}

	if js_parse_expect(s, '{') {return true}

	push_scope(s)

	emit_op(s, O(.push_const))
	ctor_cpool_offset := len(fd.byte_code)
	emit_u32(s, 0)

	if class_name == JS_ATOM_NULL {
		class_name1 = class_var_name != JS_ATOM_NULL ? A_default : A_empty_string
	} else {
		class_name1 = class_name
	}

	emit_op(s, O(.define_class))
	emit_atom(s, class_name1)
	emit_u8(s, u8(class_flags))
	define_class_offset := fd.last_opcode_pos

	for i in 0 ..< 2 {
		class_fields[i] = Class_Fields_Def{is_static = i == 1}
	}

	for s.token.val != '}' {
		if s.token.val == ';' {
			if next_token(s) {return true}
			continue
		}
		is_static := false
		if s.token.val == TOK_STATIC {
			nxt := peek_token(s, true)
			if !(nxt == ';' || nxt == '}' || nxt == '(' || nxt == '=') {
				is_static = true
			}
		}
		prop_type := -1
		if is_static {
			if next_token(s) {return true}
			if s.token.val == '{' {
				cf := &class_fields[1]
				if cf.fields_init_fd == nil {
					if emit_class_init_start(s, cf) {return true}
				}
				s.cur_func = cf.fields_init_fd
				init: ^Func_Def
				if js_parse_function_decl2(s, .class_static_init, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num, .none, &init) {
					return true
				}
				push_scope(s)
				emit_op(s, OP_scope_get_var)
				emit_atom(s, A_this)
				emit_u16(s, 0)
				if class_name != JS_ATOM_NULL {
					emit_op(s, O(.dup))
					emit_op(s, OP_scope_put_var_init)
					emit_atom(s, class_name)
					emit_u16(s, u16(s.cur_func.scope_level))
				}
				emit_op(s, O(.swap))
				emit_op(s, O(.call_method))
				emit_u16(s, 0)
				emit_op(s, O(.drop))
				pop_scope(s)
				s.cur_func = s.cur_func.parent
				continue
			}
			if s.token.val == ';' || s.token.val == '=' {
				is_static = false
				name = A_static
				prop_type = PROP_TYPE_IDENT
			}
		}
		if is_static {emit_op(s, O(.swap))}
		start_ptr := s.token.ptr
		if prop_type < 0 {
			prop_type = js_parse_property_name(s, &name, true, false, true)
			if prop_type < 0 {return true}
		}
		is_private := (prop_type & PROP_TYPE_PRIVATE) != 0
		prop_type &~= PROP_TYPE_PRIVATE

		if (name == A_constructor && !is_static && prop_type != PROP_TYPE_IDENT) ||
		   (name == A_prototype && is_static) ||
		   name == A_hash_constructor {
			return js_parse_error(s, "invalid method name")
		}
		si := is_static ? 1 : 0
		if prop_type == PROP_TYPE_GET || prop_type == PROP_TYPE_SET {
			is_set := prop_type == PROP_TYPE_SET
			if is_private {
				idx := find_private_class_field(fd, name, fd.scope_level)
				if idx >= 0 {
					var_kind := fd.vars[idx].var_kind
					is_static1 := fd.vars[idx].is_static_private
					getter_kind := Var_Kind(int(Var_Kind.private_getter) + (is_set ? 1 : 0))
					other_kind := Var_Kind(int(Var_Kind.private_getter) + 1 - (is_set ? 1 : 0))
					if var_kind == .private_field || var_kind == .private_method || var_kind == .private_getter_setter ||
					   var_kind == getter_kind || (var_kind == other_kind && is_static != is_static1) {
						return js_parse_error(s, "private class field is already defined")
					}
					fd.vars[idx].var_kind = .private_getter_setter
				} else {
					if add_private_class_field(s, fd, name, Var_Kind(int(Var_Kind.private_getter) + (is_set ? 1 : 0)), is_static) < 0 {return true}
				}
				class_fields[si].need_brand = true
			}
			if js_parse_function_decl2(s, is_set ? .setter : .getter, .normal, JS_ATOM_NULL, start_ptr, s.token.line_num, s.token.col_num, .none, &method_fd) {
				return true
			}
			if is_private {
				method_fd.need_home_object = true
				emit_op(s, O(.set_home_object))
				emit_op(s, OP_scope_put_var_init)
				if is_set {
					setter_name := atom_concat(s.atoms, name, "<set>")
					emit_atom(s, setter_name)
					if add_private_class_field(s, fd, setter_name, .private_setter, is_static) < 0 {return true}
				} else {
					emit_atom(s, name)
				}
				emit_u16(s, u16(s.cur_func.scope_level))
			} else {
				if name == JS_ATOM_NULL {
					emit_op(s, O(.define_method_computed))
				} else {
					emit_op(s, O(.define_method))
					emit_atom(s, name)
				}
				emit_u8(s, u8(OP_DEFINE_METHOD_GETTER + (is_set ? 1 : 0)))
			}
		} else if prop_type == PROP_TYPE_IDENT && s.token.val != '(' {
			cf := &class_fields[si]
			field_var_name := JS_ATOM_NULL
			if name == A_constructor || name == A_prototype {
				return js_parse_error(s, "invalid field name")
			}
			if is_private {
				if find_private_class_field(fd, name, fd.scope_level) >= 0 {
					return js_parse_error(s, "private class field is already defined")
				}
				if add_private_class_field(s, fd, name, .private_field, is_static) < 0 {return true}
				emit_op(s, O(.private_symbol))
				emit_atom(s, name)
				emit_op(s, OP_scope_put_var_init)
				emit_atom(s, name)
				emit_u16(s, u16(s.cur_func.scope_level))
			}
			if cf.fields_init_fd == nil {
				if emit_class_init_start(s, cf) {return true}
			}
			if name == JS_ATOM_NULL {
				field_var_name = atom_concat_num(s.atoms, is_static ? A_static_computed_field : A_computed_field, cf.computed_fields_count)
				if define_var(s, fd, field_var_name, .const_) < 0 {return true}
				emit_op(s, O(.to_propkey))
				emit_op(s, OP_scope_put_var_init)
				emit_atom(s, field_var_name)
				emit_u16(s, u16(s.cur_func.scope_level))
			}
			s.cur_func = cf.fields_init_fd
			emit_op(s, OP_scope_get_var)
			emit_atom(s, A_this)
			emit_u16(s, 0)
			if is_static && class_name != JS_ATOM_NULL {
				emit_op(s, O(.dup))
				emit_op(s, OP_scope_put_var_init)
				emit_atom(s, class_name)
				emit_u16(s, u16(s.cur_func.scope_level))
			}
			if name == JS_ATOM_NULL {
				emit_op(s, OP_scope_get_var)
				emit_atom(s, field_var_name)
				emit_u16(s, u16(s.cur_func.scope_level))
				cf.computed_fields_count += 1
			} else if is_private {
				emit_op(s, OP_scope_get_var)
				emit_atom(s, name)
				emit_u16(s, u16(s.cur_func.scope_level))
			}
			if s.token.val == '=' {
				if next_token(s) {return true}
				if js_parse_assign_expr(s) {return true}
			} else {
				emit_op(s, O(.undefined))
			}
			if is_private {
				set_object_name_computed(s)
				emit_op(s, O(.define_private_field))
			} else if name == JS_ATOM_NULL {
				set_object_name_computed(s)
				emit_op(s, O(.define_array_el))
				emit_op(s, O(.drop))
			} else {
				set_object_name(s, name)
				emit_op(s, O(.define_field))
				emit_atom(s, name)
			}
			s.cur_func = s.cur_func.parent
			if js_parse_expect_semi(s) {return true}
		} else {
			func_type := Parse_Func.method
			func_kind := Func_Kind.normal
			if prop_type == PROP_TYPE_STAR {
				func_kind = .generator
			} else if prop_type == PROP_TYPE_ASYNC {
				func_kind = .async
			} else if prop_type == PROP_TYPE_ASYNC_STAR {
				func_kind = .async_generator
			} else if name == A_constructor && !is_static {
				if ctor_fd != nil {
					return js_parse_error(s, "property constructor appears more than once")
				}
				if (class_flags & JS_DEFINE_CLASS_HAS_HERITAGE) != 0 {
					func_type = .derived_class_constructor
				} else {
					func_type = .class_constructor
				}
			}
			if is_private {
				class_fields[si].need_brand = true
			}
			if js_parse_function_decl2(s, func_type, func_kind, JS_ATOM_NULL, start_ptr, s.token.line_num, s.token.col_num, .none, &method_fd) {
				return true
			}
			if func_type == .derived_class_constructor || func_type == .class_constructor {
				ctor_fd = method_fd
			} else if is_private {
				method_fd.need_home_object = true
				if find_private_class_field(fd, name, fd.scope_level) >= 0 {
					return js_parse_error(s, "private class field is already defined")
				}
				if add_private_class_field(s, fd, name, .private_method, is_static) < 0 {return true}
				emit_op(s, O(.set_home_object))
				emit_op(s, O(.set_name))
				emit_atom(s, name)
				emit_op(s, OP_scope_put_var_init)
				emit_atom(s, name)
				emit_u16(s, u16(s.cur_func.scope_level))
			} else {
				if name == JS_ATOM_NULL {
					emit_op(s, O(.define_method_computed))
				} else {
					emit_op(s, O(.define_method))
					emit_atom(s, name)
				}
				emit_u8(s, u8(OP_DEFINE_METHOD_METHOD))
			}
		}
		if is_static {emit_op(s, O(.swap))}
		name = JS_ATOM_NULL
	}

	if s.token.val != '}' {
		return js_parse_error(s, "expecting '}'")
	}
	if ctor_fd == nil {
		if js_parse_class_default_ctor(s, (class_flags & JS_DEFINE_CLASS_HAS_HERITAGE) != 0, &ctor_fd) {return true}
	}
	put_u32(fd.byte_code[:], ctor_cpool_offset, u32(ctor_fd.parent_cpool_idx))

	if next_token(s) {return true}

	{
		cf := &class_fields[0]
		if cf.need_brand {
			emit_op(s, O(.dup))
			emit_op(s, O(.null))
			emit_op(s, O(.swap))
			emit_op(s, O(.add_brand))
			if cf.fields_init_fd == nil {
				if emit_class_init_start(s, cf) {return true}
			}
			cf.fields_init_fd.byte_code[cf.brand_push_pos] = u8(O(.push_true))
		}
		if define_var(s, fd, A_class_fields_init, .const_) < 0 {return true}
		if cf.fields_init_fd != nil {
			emit_class_init_end(s, cf)
		} else {
			emit_op(s, O(.undefined))
		}
		emit_op(s, OP_scope_put_var_init)
		emit_atom(s, A_class_fields_init)
		emit_u16(s, u16(s.cur_func.scope_level))
	}

	emit_op(s, O(.drop))

	if class_fields[1].need_brand {
		emit_op(s, O(.dup))
		emit_op(s, O(.dup))
		emit_op(s, O(.add_brand))
	}

	if class_fields[1].fields_init_fd != nil {
		cf := &class_fields[1]
		emit_op(s, O(.dup))
		emit_class_init_end(s, cf)
		emit_op(s, O(.call_method))
		emit_u16(s, 0)
		emit_op(s, O(.drop))
	}

	if class_name != JS_ATOM_NULL {
		emit_op(s, O(.dup))
		emit_op(s, OP_scope_put_var_init)
		emit_atom(s, class_name)
		emit_u16(s, u16(fd.scope_level))
	}
	pop_scope(s)
	pop_scope(s)

	if class_var_name != JS_ATOM_NULL {
		if define_var(s, fd, class_var_name, .let_) < 0 {return true}
		emit_op(s, OP_scope_put_var_init)
		emit_atom(s, class_var_name)
		emit_u16(s, u16(fd.scope_level))
	} else {
		if class_name == JS_ATOM_NULL {
			emit_op(s, OP_set_class_name)
			emit_u32(s, u32(fd.last_opcode_pos + 1 - define_class_offset))
		}
	}

	if export_flag != .none {
		if add_export_entry(s, fd.module, class_var_name, export_flag == .named ? class_var_name : A_default, .local) {return true}
	}
	return false
}

// --- array literal ------------------------------------------------------------------------------------------

js_parse_array_literal :: proc(s: ^Parse_State) -> bool {
	if next_token(s) {return true}
	idx: u32 = 0
	for s.token.val != ']' && idx < 32 {
		if s.token.val == ',' || s.token.val == TOK_ELLIPSIS {break}
		if js_parse_assign_expr(s) {return true}
		idx += 1
		if s.token.val == ',' {
			if next_token(s) {return true}
		} else if s.token.val != ']' {
			return js_parse_expect(s, ']')
		}
	}
	emit_op(s, O(.array_from))
	emit_u16(s, u16(idx))

	need_length := false
	for s.token.val != ']' && idx < 0x7fffffff {
		if s.token.val == TOK_ELLIPSIS {break}
		need_length = true
		if s.token.val != ',' {
			if js_parse_assign_expr(s) {return true}
			emit_op(s, O(.define_field))
			emit_u32(s, u32(atom_from_uint32(idx)))
			need_length = false
		}
		idx += 1
		if s.token.val == ',' {
			if next_token(s) {return true}
		}
	}
	if s.token.val == ']' {
		if need_length {
			emit_op(s, O(.dup))
			emit_op(s, O(.push_i32))
			emit_u32(s, idx)
			emit_op(s, O(.put_field))
			emit_atom(s, A_length)
		}
		return js_parse_expect(s, ']')
	}

	emit_op(s, O(.push_i32))
	emit_u32(s, idx)
	for s.token.val != ']' {
		if s.token.val == TOK_ELLIPSIS {
			if next_token(s) {return true}
			if js_parse_assign_expr(s) {return true}
			emit_op(s, O(.append))
		} else {
			need_length = true
			if s.token.val != ',' {
				if js_parse_assign_expr(s) {return true}
				emit_op(s, O(.define_array_el))
				need_length = false
			}
			emit_op(s, O(.inc))
		}
		if s.token.val != ',' {break}
		if next_token(s) {return true}
	}
	if need_length {
		emit_op(s, O(.dup1))
		emit_op(s, O(.put_field))
		emit_atom(s, A_length)
	} else {
		emit_op(s, O(.drop))
	}
	return js_parse_expect(s, ']')
}

// --- lvalues ------------------------------------------------------------------------------------------------

has_with_scope :: proc(s0: ^Func_Def, scope_level0: int) -> bool {
	s := s0
	scope_level := scope_level0
	for s != nil {
		if !s.is_strict_mode {
			scope_idx := s.scopes[scope_level].first
			for scope_idx >= 0 {
				vd := &s.vars[scope_idx]
				if vd.var_name == A__with_ {return true}
				scope_idx = vd.scope_next
			}
		}
		scope_level = s.parent_scope_level
		s = s.parent
	}
	return false
}

get_lvalue :: proc(s: ^Parse_State, popcode, pscope: ^int, pname: ^Atom, plabel: ^int, pdepth: ^int, keep: bool, tok: int) -> bool {
	fd := s.cur_func
	scope := 0
	name := JS_ATOM_NULL
	label := -1
	depth := 0
	opcode := get_prev_opcode(fd)
	invalid := false
	switch opcode {
	case OP_scope_get_var:
		name = Atom(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		scope = int(get_u16(fd.byte_code[:], fd.last_opcode_pos + 5))
		if (name == A_arguments || name == A_eval) && fd.is_strict_mode {
			return js_parse_error(s, "invalid lvalue in strict mode")
		}
		if name == A_this || name == A_new_target {
			invalid = true
		} else if has_with_scope(fd, scope) {
			depth = 2
		} else {
			depth = 0
		}
	case O(.get_field):
		name = Atom(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		depth = 1
	case OP_scope_get_private_field:
		name = Atom(get_u32(fd.byte_code[:], fd.last_opcode_pos + 1))
		scope = int(get_u16(fd.byte_code[:], fd.last_opcode_pos + 5))
		depth = 1
	case O(.get_array_el):
		depth = 2
	case O(.get_super_value):
		depth = 3
	case:
		invalid = true
	}
	if invalid {
		if tok == TOK_FOR {
			return js_parse_error(s, "invalid for in/of left hand-side")
		} else if tok == TOK_INC || tok == TOK_DEC {
			return js_parse_error(s, "invalid increment/decrement operand")
		} else if tok == '[' || tok == '{' {
			return js_parse_error(s, "invalid destructuring target")
		}
		return js_parse_error(s, "invalid assignment left-hand side")
	}
	resize(&fd.byte_code, fd.last_opcode_pos)
	fd.last_opcode_pos = -1

	if keep {
		switch opcode {
		case OP_scope_get_var:
			if depth != 0 {
				label = new_label(s)
				emit_op(s, OP_scope_make_ref)
				emit_atom(s, name)
				emit_u32(s, u32(label))
				emit_u16(s, u16(scope))
				update_label(fd, label, 1)
				emit_op(s, O(.get_ref_value))
				opcode = O(.get_ref_value)
			} else {
				emit_op(s, OP_scope_get_var)
				emit_atom(s, name)
				emit_u16(s, u16(scope))
			}
		case O(.get_field):
			emit_op(s, O(.get_field2))
			emit_atom(s, name)
		case OP_scope_get_private_field:
			emit_op(s, OP_scope_get_private_field2)
			emit_atom(s, name)
			emit_u16(s, u16(scope))
		case O(.get_array_el):
			emit_op(s, O(.to_propkey2))
			emit_op(s, O(.dup2))
			emit_op(s, O(.get_array_el))
		case O(.get_super_value):
			emit_op(s, O(.to_propkey))
			emit_op(s, O(.dup3))
			emit_op(s, O(.get_super_value))
		}
	} else {
		switch opcode {
		case OP_scope_get_var:
			if depth != 0 {
				label = new_label(s)
				emit_op(s, OP_scope_make_ref)
				emit_atom(s, name)
				emit_u32(s, u32(label))
				emit_u16(s, u16(scope))
				update_label(fd, label, 1)
				opcode = O(.get_ref_value)
			}
		case O(.get_array_el):
			emit_op(s, O(.to_propkey2))
		case O(.get_super_value):
			emit_op(s, O(.to_propkey))
		}
	}
	popcode^ = opcode
	pscope^ = scope
	pname^ = name
	plabel^ = label
	if pdepth != nil {pdepth^ = depth}
	return false
}

put_lvalue :: proc(s: ^Parse_State, opcode, scope: int, name: Atom, label: int, special: Put_LValue, is_let: bool) {
	switch opcode {
	case OP_scope_get_var:
		if special == .keep_top {emit_op(s, O(.dup))}
	case O(.get_field), OP_scope_get_private_field:
		#partial switch special {
		case .keep_top: emit_op(s, O(.insert2))
		case .keep_second: emit_op(s, O(.perm3))
		case .nokeep_bottom: emit_op(s, O(.swap))
		}
	case O(.get_array_el), O(.get_ref_value):
		if opcode == O(.get_ref_value) {
			emit_label(s, label)
		}
		switch special {
		case .nokeep: emit_op(s, O(.nop))
		case .nokeep_depth:
		case .keep_top: emit_op(s, O(.insert3))
		case .keep_second: emit_op(s, O(.perm4))
		case .nokeep_bottom: emit_op(s, O(.rot3l))
		}
	case O(.get_super_value):
		#partial switch special {
		case .keep_top: emit_op(s, O(.insert4))
		case .keep_second: emit_op(s, O(.perm5))
		case .nokeep_bottom: emit_op(s, O(.rot4l))
		}
	}
	switch opcode {
	case OP_scope_get_var:
		emit_op(s, is_let ? OP_scope_put_var_init : OP_scope_put_var)
		emit_u32(s, u32(name))
		emit_u16(s, u16(scope))
	case O(.get_field):
		emit_op(s, O(.put_field))
		emit_u32(s, u32(name))
	case OP_scope_get_private_field:
		emit_op(s, OP_scope_put_private_field)
		emit_u32(s, u32(name))
		emit_u16(s, u16(scope))
	case O(.get_array_el):
		emit_op(s, O(.put_array_el))
	case O(.get_ref_value):
		emit_op(s, O(.put_ref_value))
	case O(.get_super_value):
		emit_op(s, O(.put_super_value))
	}
}

js_parse_expr_paren :: proc(s: ^Parse_State) -> bool {
	if js_parse_expect(s, '(') {return true}
	if js_parse_expr(s) {return true}
	if js_parse_expect(s, ')') {return true}
	return false
}

js_define_var :: proc(s: ^Parse_State, name: Atom, tok: int) -> bool {
	fd := s.cur_func
	if name == A_yield && fd.func_kind == .generator {
		return js_parse_error(s, "yield is a reserved identifier")
	}
	if (name == A_arguments || name == A_eval) && fd.is_strict_mode {
		return js_parse_error(s, "invalid variable name in strict mode")
	}
	if tok == TOK_LET || tok == TOK_CONST {
		if name == A_let {
			return js_parse_error(s, "invalid lexical variable name 'let'")
		}
		if name == A_undefined && fd.scope_level == 1 && fd.is_global_var && fd.module == nil {
			return js_parse_error(s, "'undefined' already declared")
		}
	}
	var_def_type: Var_Def_Type
	switch tok {
	case TOK_LET: var_def_type = .let_
	case TOK_CONST: var_def_type = .const_
	case TOK_VAR: var_def_type = .var_
	case TOK_USING: var_def_type = .using_
	case TOK_CATCH: var_def_type = .catch_
	}
	if define_var(s, fd, name, var_def_type) < 0 {return true}
	return false
}

js_emit_spread_code :: proc(s: ^Parse_State, depth: int) {
	emit_op(s, O(.array_from))
	emit_u16(s, 0)
	emit_op(s, O(.push_i32))
	emit_u32(s, 0)
	label_rest_next := new_label(s)
	emit_label(s, label_rest_next)
	emit_op(s, O(.for_of_next))
	emit_u8(s, u8(2 + depth))
	label_rest_done := emit_goto(s, O(.if_true), -1)
	emit_op(s, O(.define_array_el))
	emit_op(s, O(.inc))
	emit_goto(s, O(.goto), label_rest_next)
	emit_label(s, label_rest_done)
	emit_op(s, O(.drop))
	emit_op(s, O(.drop))
}

js_parse_check_duplicate_parameter :: proc(s: ^Parse_State, name: Atom) -> bool {
	fd := s.cur_func
	for a in fd.args {
		if a.var_name == name {
			return js_parse_error(s, "Duplicate parameter name not allowed in this context")
		}
	}
	for v in fd.vars {
		if v.var_name == name {
			return js_parse_error(s, "Duplicate parameter name not allowed in this context")
		}
	}
	return false
}

js_parse_destructuring_var :: proc(s: ^Parse_State, tok: int, is_arg: bool) -> Atom {
	if !(s.token.val == TOK_IDENT && !s.token.is_reserved) ||
	   (s.cur_func.is_strict_mode && (s.token.atom == A_eval || s.token.atom == A_arguments)) {
		js_parse_error(s, "invalid destructuring target")
		return JS_ATOM_NULL
	}
	name := s.token.atom
	if is_arg && js_parse_check_duplicate_parameter(s, name) {return JS_ATOM_NULL}
	if next_token(s) {return JS_ATOM_NULL}
	return name
}
