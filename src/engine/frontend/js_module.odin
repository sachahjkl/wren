package frontend

// Module syntax: import / export declarations and the module record the serializer writes (JS_WriteModule).

Import_Attributes :: struct {
	keys:   [dynamic]Atom,
	values: [dynamic]String_Value,
}

add_req_module_entry :: proc(s: ^Parse_State, m: ^Module_Def, module_name: Atom, attributes: ^Import_Attributes) -> int {
	for &rme, i in m.req_module_entries {
		if rme.module_name == module_name && module_attributes_equal(rme.attributes, attributes) {
			return i
		}
	}
	append(&m.req_module_entries, Req_Module_Entry{module_name = module_name, attributes = attributes})
	return len(m.req_module_entries) - 1
}

// module_attributes_equal: same set of keys with the same string values (js_module_attributes_equal).
@(private = "file")
module_attributes_equal :: proc(a, b: ^Import_Attributes) -> bool {
	la := a == nil ? 0 : len(a.keys)
	lb := b == nil ? 0 : len(b.keys)
	if la != lb {return false}
	for i in 0 ..< la {
		found := false
		for j in 0 ..< lb {
			if b.keys[j] == a.keys[i] {
				found = string_equal(a.values[i], b.values[j])
				break
			}
		}
		if !found {return false}
	}
	return true
}

string_equal :: proc(a, b: String_Value) -> bool {
	if string_len(a) != string_len(b) {return false}
	for i in 0 ..< string_len(a) {
		if string_at(a, i) != string_at(b, i) {return false}
	}
	return true
}

find_export_entry :: proc(m: ^Module_Def, export_name: Atom) -> ^Export_Entry {
	for &me in m.export_entries {
		if me.export_name == export_name {return &me}
	}
	return nil
}

// add_export_entry returns true on error (duplicate export).
add_export_entry :: proc(s: ^Parse_State, m: ^Module_Def, local_name, export_name: Atom, export_type: Export_Type) -> bool {
	if find_export_entry(m, export_name) != nil {
		return js_parse_error(s, "duplicate exported name '", atom_text(s, export_name), "'")
	}
	append(&m.export_entries, Export_Entry{local_name = local_name, export_name = export_name, export_type = export_type})
	return false
}

add_star_export_entry :: proc(m: ^Module_Def, req_module_idx: int) {
	append(&m.star_export_entries, req_module_idx)
}

js_parse_with_clause :: proc(s: ^Parse_State, pattributes: ^^Import_Attributes) -> bool {
	pattributes^ = nil
	if s.token.val != TOK_WITH {return false}
	if next_token(s) {return true}
	if js_parse_expect(s, '{') {return true}
	for s.token.val != '}' {
		key: Atom
		if s.token.val == TOK_STRING {
			key = atom_from_string(s.atoms, s.token.str)
		} else {
			if !token_is_ident(s.token.val) {
				return js_parse_error(s, "identifier expected")
			}
			key = s.token.atom
		}
		if next_token(s) {return true}
		if js_parse_expect(s, ':') {return true}
		if s.token.val != TOK_STRING {
			return js_parse_error(s, "string expected")
		}
		if pattributes^ == nil {
			pattributes^ = new(Import_Attributes, s.allocator)
			pattributes^.keys = make([dynamic]Atom, s.allocator)
			pattributes^.values = make([dynamic]String_Value, s.allocator)
		}
		for k in pattributes^.keys {
			if k == key {
				return js_parse_error(s, "duplicate with key")
			}
		}
		append(&pattributes^.keys, key)
		append(&pattributes^.values, s.token.str)
		if next_token(s) {return true}
		if s.token.val != '}' {
			if js_parse_expect(s, ',') {return true}
		}
	}
	return js_parse_expect(s, '}')
}

js_parse_from_clause :: proc(s: ^Parse_State, m: ^Module_Def) -> int {
	if !token_is_pseudo_keyword(s, A_from) {
		js_parse_error(s, "from clause expected")
		return -1
	}
	if next_token(s) {return -1}
	if s.token.val != TOK_STRING {
		js_parse_error(s, "string expected")
		return -1
	}
	module_name := atom_from_string(s.atoms, s.token.str)
	if next_token(s) {return -1}
	attributes: ^Import_Attributes
	if js_parse_with_clause(s, &attributes) {return -1}
	return add_req_module_entry(s, m, module_name, attributes)
}

@(private = "file")
has_unmatched_surrogate :: proc(u: []u16) -> bool {
	n := len(u)
	for i := 0; i < n; i += 1 {
		if u[i] >= 0xDC00 && u[i] < 0xE000 {return true}
		if !(u[i] >= 0xD800 && u[i] < 0xDC00) {continue}
		i += 1
		if i == n {return true}
		if !(u[i] >= 0xDC00 && u[i] < 0xE000) {return true}
	}
	return false
}

js_parse_export :: proc(s: ^Parse_State) -> bool {
	m := s.cur_func.module
	if next_token(s) {return true}
	tok := s.token.val
	if tok == TOK_CLASS {
		return js_parse_class(s, false, .named)
	} else if tok == TOK_FUNCTION || (token_is_pseudo_keyword(s, A_async) && peek_token(s, true) == TOK_FUNCTION) {
		return js_parse_function_decl2(s, .statement, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num, .named, nil)
	}
	if next_token(s) {return true}
	switch tok {
	case '{':
		first_export := len(m.export_entries)
		has_string_binding := false
		for s.token.val != '}' {
			local_name, export_name: Atom
			if token_is_ident(s.token.val) {
				local_name = s.token.atom
			} else if s.token.val == TOK_STRING {
				local_name = atom_from_string(s.atoms, s.token.str)
				has_string_binding = true
			} else {
				return js_parse_error(s, "identifier or string expected")
			}
			if next_token(s) {return true}
			if token_is_pseudo_keyword(s, A_as) {
				if next_token(s) {return true}
				if token_is_ident(s.token.val) {
					export_name = s.token.atom
				} else if s.token.val == TOK_STRING {
					if s.token.str.is_wide && has_unmatched_surrogate(s.token.str.units) {
						return js_parse_error(s, "illegal export name")
					}
					export_name = atom_from_string(s.atoms, s.token.str)
				} else {
					return js_parse_error(s, "identifier or string expected")
				}
				if next_token(s) {return true}
			} else {
				export_name = local_name
			}
			if add_export_entry(s, m, local_name, export_name, .local) {return true}
			if s.token.val != ',' {break}
			if next_token(s) {return true}
		}
		if js_parse_expect(s, '}') {return true}
		if token_is_pseudo_keyword(s, A_from) {
			idx := js_parse_from_clause(s, m)
			if idx < 0 {return true}
			for i in first_export ..< len(m.export_entries) {
				me := &m.export_entries[i]
				me.export_type = .indirect
				me.req_module_idx = idx
			}
		} else if has_string_binding {
			return js_parse_error(s, "string export name only allowed with 'from' clause")
		}
	case '*':
		if token_is_pseudo_keyword(s, A_as) {
			if next_token(s) {return true}
			export_name: Atom
			if token_is_ident(s.token.val) {
				export_name = s.token.atom
			} else if s.token.val == TOK_STRING {
				export_name = atom_from_string(s.atoms, s.token.str)
			} else {
				return js_parse_error(s, "identifier or string expected")
			}
			if next_token(s) {return true}
			idx := js_parse_from_clause(s, m)
			if idx < 0 {return true}
			if add_export_entry(s, m, A__star_, export_name, .indirect) {return true}
			m.export_entries[len(m.export_entries) - 1].req_module_idx = idx
		} else {
			idx := js_parse_from_clause(s, m)
			if idx < 0 {return true}
			add_star_export_entry(m, idx)
		}
	case TOK_DEFAULT:
		if s.token.val == TOK_CLASS {
			return js_parse_class(s, false, .default_)
		} else if s.token.val == TOK_FUNCTION || (token_is_pseudo_keyword(s, A_async) && peek_token(s, true) == TOK_FUNCTION) {
			return js_parse_function_decl2(s, .statement, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num, .default_, nil)
		} else {
			if js_parse_assign_expr(s) {return true}
		}
		set_object_name(s, A_default)
		local_name := A__default_
		if define_var(s, s.cur_func, local_name, .let_) < 0 {return true}
		emit_op(s, OP_scope_put_var_init)
		emit_atom(s, local_name)
		emit_u16(s, 0)
		if add_export_entry(s, m, local_name, A_default, .local) {return true}
	case TOK_VAR, TOK_LET, TOK_CONST, TOK_USING:
		return js_parse_var(s, PF_IN_ACCEPTED, tok, true)
	case:
		return js_parse_error(s, "invalid export syntax")
	}
	return js_parse_expect_semi(s)
}

add_import :: proc(s: ^Parse_State, m: ^Module_Def, local_name, import_name: Atom) -> bool {
	if local_name == A_arguments || local_name == A_eval {
		return js_parse_error(s, "invalid import binding")
	}
	if local_name != A_default {
		for cv in s.cur_func.closure_var {
			if cv.var_name == local_name {
				return js_parse_error(s, "duplicate import binding")
			}
		}
	}
	closure_type := import_name == A__star_ ? Closure_Type.module_decl : Closure_Type.module_import
	var_idx := add_closure_var(s.cur_func, closure_type, len(m.import_entries), local_name, true, true, .normal)
	if var_idx < 0 {
		return js_parse_error(s, "too many closure variables")
	}
	append(&m.import_entries, Import_Entry{import_name = import_name, var_idx = var_idx})
	return false
}

js_parse_import :: proc(s: ^Parse_State) -> bool {
	m := s.cur_func.module
	if next_token(s) {return true}
	first_import := len(m.import_entries)
	idx: int
	if s.token.val == TOK_STRING {
		module_name := atom_from_string(s.atoms, s.token.str)
		if next_token(s) {return true}
		attributes: ^Import_Attributes
		if js_parse_with_clause(s, &attributes) {return true}
		idx = add_req_module_entry(s, m, module_name, attributes)
	} else {
		end_clause := false
		if s.token.val == TOK_IDENT {
			if s.token.is_reserved {
				return js_parse_error_reserved_identifier(s)
			}
			local_name := s.token.atom
			if next_token(s) {return true}
			if add_import(s, m, local_name, A_default) {return true}
			if s.token.val != ',' {
				end_clause = true
			} else {
				if next_token(s) {return true}
			}
		}
		if !end_clause {
			if s.token.val == '*' {
				if next_token(s) {return true}
				if !token_is_pseudo_keyword(s, A_as) {
					return js_parse_error(s, "expecting 'as'")
				}
				if next_token(s) {return true}
				if !token_is_ident(s.token.val) {
					return js_parse_error(s, "identifier expected")
				}
				local_name := s.token.atom
				if next_token(s) {return true}
				if add_import(s, m, local_name, A__star_) {return true}
			} else if s.token.val == '{' {
				if next_token(s) {return true}
				for s.token.val != '}' {
					import_name: Atom
					if token_is_ident(s.token.val) {
						import_name = s.token.atom
					} else if s.token.val == TOK_STRING {
						import_name = atom_from_string(s.atoms, s.token.str)
					} else {
						return js_parse_error(s, "identifier or string expected expected")
					}
					local_name: Atom
					if next_token(s) {return true}
					if token_is_pseudo_keyword(s, A_as) {
						if next_token(s) {return true}
						if !token_is_ident(s.token.val) {
							return js_parse_error(s, "identifier expected")
						}
						local_name = s.token.atom
						if next_token(s) {return true}
					} else {
						local_name = import_name
					}
					if add_import(s, m, local_name, import_name) {return true}
					if s.token.val != ',' {break}
					if next_token(s) {return true}
				}
				if js_parse_expect(s, '}') {return true}
			}
		}
		idx = js_parse_from_clause(s, m)
		if idx < 0 {return true}
	}
	for i in first_import ..< len(m.import_entries) {
		m.import_entries[i].req_module_idx = idx
	}
	return js_parse_expect_semi(s)
}

js_parse_source_element :: proc(s: ^Parse_State) -> bool {
	fd := s.cur_func
	if s.token.val == TOK_FUNCTION || (token_is_pseudo_keyword(s, A_async) && peek_token(s, true) == TOK_FUNCTION) {
		if js_parse_function_decl(s, .statement, .normal, JS_ATOM_NULL, s.token.ptr, s.token.line_num, s.token.col_num) {return true}
	} else if s.token.val == TOK_EXPORT && fd.module != nil {
		if js_parse_export(s) {return true}
	} else if s.token.val == TOK_IMPORT && fd.module != nil {
		tok := peek_token(s, false)
		if tok != '(' && tok != '.' {
			if js_parse_import(s) {return true}
		} else {
			if js_parse_statement_or_decl(s, DECL_MASK_ALL) {return true}
		}
	} else {
		if js_parse_statement_or_decl(s, DECL_MASK_ALL) {return true}
	}
	return false
}
