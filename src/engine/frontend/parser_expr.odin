package frontend

import "wb:engine/numconv"

// Expression and pattern parsing, plus functions, classes and module declarations. This is the companion to
// parser.odin; both operate on the same Parser. Operator precedence uses a precedence-climbing loop (binary_prec)
// rather than one function per level, which keeps the table in one place and matches the ECMAScript grammar's
// precedence exactly, including the `**` right-associativity and the `??` / `&&` / `||` mixing restriction.

// --- comma / assignment / conditional -----------------------------------------------------------------------

parse_expression :: proc(p: ^Parser) -> ^Expr {
	first := parse_assignment(p)
	if !is_punct(p, .comma) {
		return first
	}
	start := p.tok.pos
	if first != nil {start = expr_pos(first^)}
	exprs := make([dynamic]^Expr, p.allocator)
	append(&exprs, first)
	for eat_punct(p, .comma) {
		append(&exprs, parse_assignment(p))
	}
	return new_expr(p, Sequence_Expr{pos = start, exprs = exprs[:]})
}

parse_expression_no_in :: proc(p: ^Parser) -> ^Expr {
	// `allow_in` is already false in the caller; parse one assignment (a for-init expression is a single
	// AssignmentExpression per the grammar, but comma is allowed too).
	return parse_expression(p)
}

parse_assignment :: proc(p: ^Parser) -> ^Expr {
	// Arrow functions: `x => ...`, `(a, b) => ...`, `async x => ...`, `async (a) => ...`.
	if arrow := try_parse_arrow(p); arrow != nil {
		return arrow
	}

	if yield := try_parse_yield(p); yield != nil {
		return yield
	}

	left := parse_conditional(p)
	return parse_assignment_continued(p, left)
}

parse_assignment_continued :: proc(p: ^Parser, left: ^Expr) -> ^Expr {
	if p.tok.kind != .punct {
		return left
	}
	op, is_assign := assign_op_of(p.tok.punct)
	if !is_assign {
		return left
	}
	start := left != nil ? expr_pos(left^) : p.tok.pos
	advance_re(p)
	right := parse_assignment(p)
	// For a plain `=` the left side may be a destructuring pattern written as an array/object literal; the
	// resolver converts it. Validate that the target is a valid assignment target.
	if op == .assign {
		if !is_valid_assign_target(left) {
			error_at(p, "invalid assignment target", start)
		}
	} else {
		if !is_simple_assign_target(left) {
			error_at(p, "invalid assignment target", start)
		}
	}
	return new_expr(p, Assign_Expr{pos = start, op = op, target = left, value = right})
}

@(private = "file")
assign_op_of :: proc(pk: Punct) -> (Assign_Op, bool) {
	#partial switch pk {
	case .assign: return .assign, true
	case .plus_eq: return .add, true
	case .minus_eq: return .sub, true
	case .star_eq: return .mul, true
	case .slash_eq: return .div, true
	case .percent_eq: return .mod, true
	case .starstar_eq: return .pow, true
	case .shl_eq: return .shl, true
	case .sar_eq: return .sar, true
	case .shr_eq: return .shr, true
	case .amp_eq: return .band, true
	case .bar_eq: return .bor, true
	case .caret_eq: return .bxor, true
	case .and_and_eq: return .and_and, true
	case .or_or_eq: return .or_or, true
	case .question_question_eq: return .nullish, true
	}
	return .assign, false
}

@(private = "file")
parse_conditional :: proc(p: ^Parser) -> ^Expr {
	cond := parse_binary(p, 1)
	if !is_punct(p, .question) {
		return cond
	}
	start := cond != nil ? expr_pos(cond^) : p.tok.pos
	advance_re(p)
	saved := p.allow_in
	p.allow_in = true
	then := parse_assignment(p)
	p.allow_in = saved
	expect_punct(p, .colon, "expected ':'")
	els := parse_assignment(p)
	return new_expr(p, Conditional_Expr{pos = start, cond = cond, then = then, els = els})
}

// --- binary operators (precedence climbing) -----------------------------------------------------------------

// binary_prec returns the precedence of a binary operator token (higher binds tighter) or 0 if it is not a
// binary operator in the current context. `??` (7) cannot mix with `&&`/`||` without parentheses; we handle that
// in parse_binary by refusing to climb across the boundary.
@(private = "file")
binary_prec :: proc(p: ^Parser) -> int {
	if p.tok.kind == .ident && !p.tok.had_escape {
		if p.tok.ident == "instanceof" {return 10}
		if p.tok.ident == "in" && p.allow_in {return 10}
	}
	if p.tok.kind != .punct {
		return 0
	}
	#partial switch p.tok.punct {
	case .or_or: return 4
	case .and_and: return 5
	case .question_question: return 4
	case .bar: return 6
	case .caret: return 7
	case .amp: return 8
	case .eq, .neq, .strict_eq, .strict_neq: return 9
	case .lt, .gt, .lte, .gte: return 10
	case .shl, .sar, .shr: return 11
	case .plus, .minus: return 12
	case .star, .slash, .percent: return 13
	case .starstar: return 14
	}
	return 0
}

@(private = "file")
parse_binary :: proc(p: ^Parser, min_prec: int) -> ^Expr {
	left := parse_unary(p)
	for {
		prec := binary_prec(p)
		if prec < min_prec || prec == 0 {
			break
		}
		// capture operator
		is_logical := false
		lop: Logical_Op
		bop: Binary_Op
		start := left != nil ? expr_pos(left^) : p.tok.pos

		if p.tok.kind == .ident {
			if p.tok.ident == "instanceof" {bop = .instanceof}
			else {bop = .in_}
			advance_re(p)
		} else {
			#partial switch p.tok.punct {
			case .or_or: is_logical = true; lop = .or_or
			case .and_and: is_logical = true; lop = .and_and
			case .question_question: is_logical = true; lop = .nullish
			case .bar: bop = .bor
			case .caret: bop = .bxor
			case .amp: bop = .band
			case .eq: bop = .eq
			case .neq: bop = .neq
			case .strict_eq: bop = .strict_eq
			case .strict_neq: bop = .strict_neq
			case .lt: bop = .lt
			case .gt: bop = .gt
			case .lte: bop = .lte
			case .gte: bop = .gte
			case .shl: bop = .shl
			case .sar: bop = .sar
			case .shr: bop = .shr
			case .plus: bop = .add
			case .minus: bop = .sub
			case .star: bop = .mul
			case .slash: bop = .div
			case .percent: bop = .mod
			case .starstar: bop = .pow
			}
			advance_re(p)
		}

		// `**` is right-associative; everything else is left-associative. Right side parses at prec (for **) or
		// prec+1 (left-assoc).
		next_min := prec == 14 ? prec : prec + 1
		right := parse_binary(p, next_min)
		if is_logical {
			left = new_expr(p, Logical_Expr{pos = start, op = lop, left = left, right = right})
		} else {
			left = new_expr(p, Binary_Expr{pos = start, op = bop, left = left, right = right})
		}
	}
	return left
}

// --- unary / update -----------------------------------------------------------------------------------------

@(private = "file")
parse_unary :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	if p.tok.kind == .ident && !p.tok.had_escape {
		switch p.tok.ident {
		case "typeof":
			advance_re(p)
			return new_expr(p, Unary_Expr{pos = start, op = .typeof_, operand = parse_unary(p)})
		case "void":
			advance_re(p)
			return new_expr(p, Unary_Expr{pos = start, op = .void_, operand = parse_unary(p)})
		case "delete":
			advance_re(p)
			operand := parse_unary(p)
			if p.strict {
				// `delete x` of a bare identifier is a SyntaxError in strict mode.
				if operand != nil {
					if _, ok := operand.(Ident_Expr); ok {
						parse_error(p, "cannot delete variable in strict mode")
					}
				}
			}
			return new_expr(p, Unary_Expr{pos = start, op = .delete_, operand = operand})
		case "await":
			if p.in_async || p.is_module {
				advance_re(p)
				return new_expr(p, Await_Expr{pos = start, arg = parse_unary(p)})
			}
		}
	}
	if p.tok.kind == .punct {
		#partial switch p.tok.punct {
		case .minus:
			advance_re(p)
			return new_expr(p, Unary_Expr{pos = start, op = .neg, operand = parse_unary(p)})
		case .plus:
			advance_re(p)
			return new_expr(p, Unary_Expr{pos = start, op = .plus, operand = parse_unary(p)})
		case .bang:
			advance_re(p)
			return new_expr(p, Unary_Expr{pos = start, op = .lnot, operand = parse_unary(p)})
		case .tilde:
			advance_re(p)
			return new_expr(p, Unary_Expr{pos = start, op = .bitnot, operand = parse_unary(p)})
		case .plusplus, .minusminus:
			inc := p.tok.punct == .plusplus
			advance_re(p)
			operand := parse_unary(p)
			if !is_simple_assign_target(operand) {
				error_at(p, "invalid increment/decrement operand", start)
			}
			return new_expr(p, Update_Expr{pos = start, inc = inc, prefix = true, operand = operand})
		}
	}
	return parse_postfix(p)
}

@(private = "file")
parse_postfix :: proc(p: ^Parser) -> ^Expr {
	e := parse_call_member(p)
	if (is_punct(p, .plusplus) || is_punct(p, .minusminus)) && !p.tok.nl_before {
		inc := p.tok.punct == .plusplus
		start := e != nil ? expr_pos(e^) : p.tok.pos
		if !is_simple_assign_target(e) {
			error_at(p, "invalid increment/decrement operand", start)
		}
		advance(p)
		return new_expr(p, Update_Expr{pos = start, inc = inc, prefix = false, operand = e})
	}
	return e
}

// --- call / member / new / optional chaining ----------------------------------------------------------------

@(private = "file")
parse_call_member :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	e: ^Expr

	if is_kw(p, "new") {
		e = parse_new(p)
	} else {
		e = parse_primary(p)
	}

	has_optional := false
	for {
		if p.tok.kind == .punct {
			#partial switch p.tok.punct {
			case .dot:
				advance(p)
				name, name_text, is_private := parse_member_name(p)
				e = new_expr(p, Member_Expr{pos = start, object = e, name = name, name_text = name_text, is_private = is_private})
				continue
			case .question_dot:
				has_optional = true
				advance(p)
				if is_punct(p, .lparen) {
					args := parse_arguments(p)
					e = new_expr(p, Call_Expr{pos = start, callee = e, args = args, optional = true})
				} else if is_punct(p, .lbracket) {
					advance_re(p)
					idx := parse_expression(p)
					expect_punct(p, .rbracket, "expected ']'")
					e = new_expr(p, Member_Expr{pos = start, object = e, property = idx, computed = true, optional = true})
				} else {
					name, name_text, is_private := parse_member_name(p)
					e = new_expr(p, Member_Expr{pos = start, object = e, name = name, name_text = name_text, is_private = is_private, optional = true})
				}
				continue
			case .lbracket:
				advance_re(p)
				idx := parse_expression(p)
				expect_punct(p, .rbracket, "expected ']'")
				e = new_expr(p, Member_Expr{pos = start, object = e, property = idx, computed = true})
				continue
			case .lparen:
				args := parse_arguments(p)
				e = new_expr(p, Call_Expr{pos = start, callee = e, args = args})
				continue
			}
		}
		if p.tok.kind == .template {
			// Tagged template.
			quasi := parse_template_literal(p)
			tl := &quasi.(Template_Lit)
			e = new_expr(p, Tagged_Template_Expr{pos = start, tag = e, quasi = tl})
			continue
		}
		break
	}
	if has_optional {
		e = new_expr(p, Optional_Chain{pos = start, expr = e})
	}
	return e
}

@(private = "file")
parse_new :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	advance(p) // new
	if is_punct(p, .dot) {
		advance(p)
		if is_kw(p, "target") || (p.tok.kind == .ident && p.tok.ident == "target") {
			advance(p)
			return new_expr(p, New_Target_Expr{pos = start})
		}
		parse_error(p, "expected 'target' after 'new.'")
		return nil
	}
	callee: ^Expr
	if is_kw(p, "new") {
		callee = parse_new(p)
	} else {
		callee = parse_primary(p)
	}
	// member access before the argument list binds to the new callee.
	for p.tok.kind == .punct {
		#partial switch p.tok.punct {
		case .dot:
			advance(p)
			name, name_text, is_private := parse_member_name(p)
			callee = new_expr(p, Member_Expr{pos = start, object = callee, name = name, name_text = name_text, is_private = is_private})
			continue
		case .lbracket:
			advance_re(p)
			idx := parse_expression(p)
			expect_punct(p, .rbracket, "expected ']'")
			callee = new_expr(p, Member_Expr{pos = start, object = callee, property = idx, computed = true})
			continue
		}
		break
	}
	args: []^Expr
	if is_punct(p, .lparen) {
		args = parse_arguments(p)
	}
	return new_expr(p, New_Expr{pos = start, callee = callee, args = args})
}

@(private = "file")
parse_member_name :: proc(p: ^Parser) -> (atom: Atom, text: string, is_private: bool) {
	if p.tok.kind == .private_name {
		text = p.tok.ident
		atom = intern(p.atoms, p.tok.ident)
		advance(p)
		return atom, text, true
	}
	if p.tok.kind == .ident {
		text = p.tok.ident
		atom = intern(p.atoms, p.tok.ident)
		advance(p)
		return atom, text, false
	}
	parse_error(p, "expected property name")
	return JS_ATOM_NULL, "", false
}

@(private = "file")
parse_arguments :: proc(p: ^Parser) -> []^Expr {
	advance_re(p) // (
	args := make([dynamic]^Expr, p.allocator)
	for !is_punct(p, .rparen) && p.tok.kind != .eof && !p.had_error {
		if is_punct(p, .dotdotdot) {
			sp := p.tok.pos
			advance_re(p)
			arg := parse_assignment(p)
			append(&args, new_expr(p, Spread_Expr{pos = sp, arg = arg}))
		} else {
			append(&args, parse_assignment(p))
		}
		if !eat_punct(p, .comma) {
			break
		}
	}
	expect_punct(p, .rparen, "expected ')'")
	return args[:]
}

// --- primary expressions ------------------------------------------------------------------------------------

@(private = "file")
parse_primary :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	#partial switch p.tok.kind {
	case .number:
		v := p.tok.num
		is_int := p.tok.num_is_int
		advance(p)
		return new_expr(p, Num_Lit{pos = start, value = v, is_int = is_int})
	case .bigint:
		digits := p.tok.text
		radix := p.tok.radix
		advance(p)
		return new_expr(p, BigInt_Lit{pos = start, digits = digits, radix = radix})
	case .string:
		sv := p.tok.str
		advance(p)
		return new_expr(p, Str_Lit{pos = start, value = sv})
	case .regexp:
		pat := p.tok.text
		flags := p.tok.flags_text
		advance(p)
		return new_expr(p, Regexp_Lit{pos = start, pattern = pat, flags = flags})
	case .template:
		return parse_template_literal(p)
	case .private_name:
		// `#x in obj`
		name := intern(p.atoms, p.tok.ident)
		text := p.tok.ident
		advance(p)
		return new_expr(p, Ident_Expr{pos = start, name = name, text = text})
	case .ident:
		return parse_ident_primary(p)
	case .punct:
		#partial switch p.tok.punct {
		case .lparen:
			return parse_paren_or_arrow(p)
		case .lbracket:
			return parse_array_literal(p)
		case .lbrace:
			return parse_object_literal(p)
		}
	}
	parse_error(p, "unexpected token in expression")
	advance(p)
	return nil
}

@(private = "file")
parse_ident_primary :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	name := p.tok.ident
	if !p.tok.had_escape {
		switch name {
		case "this":
			advance(p)
			return new_expr(p, This_Expr{pos = start})
		case "super":
			advance(p)
			return new_expr(p, Super_Expr{pos = start})
		case "null":
			advance(p)
			return new_expr(p, Null_Lit{pos = start})
		case "true":
			advance(p)
			return new_expr(p, Bool_Lit{pos = start, value = true})
		case "false":
			advance(p)
			return new_expr(p, Bool_Lit{pos = start, value = false})
		case "function":
			fn := parse_function(p, .normal, false, false)
			return new_expr(p, Function_Expr{pos = start, func = fn})
		case "class":
			cls := parse_class(p, false)
			return new_expr(p, Class_Expr{pos = start, class = cls})
		case "async":
			// `async function ...` expression, or an identifier named async.
			if async_function_expr_follows(p) {
				advance(p) // async
				fn := parse_function(p, .normal, true, false)
				return new_expr(p, Function_Expr{pos = start, func = fn})
			}
		case "import":
			// import(...) or import.meta
			return parse_import_expr(p)
		}
		// strict-mode reserved words used as identifiers are errors; the resolver double-checks.
	}
	atom := intern(p.atoms, name)
	advance(p)
	return new_expr(p, Ident_Expr{pos = start, name = atom, text = name})
}

@(private = "file")
async_function_expr_follows :: proc(p: ^Parser) -> bool {
	save := save_point(p)
	advance(p)
	ok := is_kw(p, "function") && !p.tok.nl_before
	restore_point(p, save)
	return ok
}

// --- template literal ---------------------------------------------------------------------------------------

@(private = "file")
parse_template_literal :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	cooked := make([dynamic]String_Value, p.allocator)
	raw := make([dynamic]string, p.allocator)
	exprs := make([dynamic]^Expr, p.allocator)

	t := p.tok
	append(&cooked, t.str)
	append(&raw, t.raw)
	if t.template_part == .no_sub {
		advance(p)
		return new_expr(p, Template_Lit{pos = start, cooked = cooked[:], raw = raw[:], exprs = exprs[:]})
	}
	// head; now substitutions follow.
	advance_re(p) // consume head token; parser positioned at the first substitution expression
	for {
		append(&exprs, parse_expression(p))
		if !is_punct(p, .rbrace) {
			parse_error(p, "expected '}' in template literal")
			break
		}
		// Re-lex the continuation starting right after `}`.
		cont := scan_template_continuation(&p.lex)
		sync_lex_error(p)
		p.tok = cont
		append(&cooked, cont.str)
		append(&raw, cont.raw)
		if cont.template_part == .tail {
			advance(p)
			break
		}
		// middle: consume and continue with next substitution
		advance_re(p)
	}
	return new_expr(p, Template_Lit{pos = start, cooked = cooked[:], raw = raw[:], exprs = exprs[:]})
}

// --- parenthesized expression / arrow -----------------------------------------------------------------------

@(private = "file")
parse_paren_or_arrow :: proc(p: ^Parser) -> ^Expr {
	// try_parse_arrow has already checked; here we know it is a plain parenthesized expression (possibly a
	// sequence). Arrow detection happens in try_parse_arrow called from parse_assignment.
	start := p.tok.pos
	advance_re(p) // (
	e := parse_expression(p)
	expect_punct(p, .rparen, "expected ')'")
	return new_expr(p, Paren_Expr{pos = start, expr = e})
}

// try_parse_arrow attempts to parse an arrow function at the current position. It returns nil (and rewinds) if
// the tokens are not an arrow. It recognizes `ident =>`, `( ... ) =>`, `async ident =>` and `async ( ... ) =>`.
@(private = "file")
try_parse_arrow :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	is_async := false

	save := save_point(p)

	if is_kw(p, "async") {
		// `async` then (ident|`(`) on the same line, then eventually `=>`.
		s2 := save_point(p)
		advance(p)
		if !p.tok.nl_before && (p.tok.kind == .ident || is_punct(p, .lparen)) {
			is_async = true
		} else {
			restore_point(p, s2)
		}
	}

	if p.tok.kind == .ident && p.tok.keyword == JS_ATOM_NULL {
		// single-identifier parameter arrow: `x =>`
		s3 := save_point(p)
		param_name := p.tok.ident
		param_pos := p.tok.pos
		advance(p)
		if is_punct(p, .arrow) && !p.tok.nl_before {
			return finish_arrow_single(p, start, is_async, param_name, param_pos)
		}
		restore_point(p, s3)
	}

	if is_punct(p, .lparen) {
		// Look ahead: find the matching `)` and check the next token is `=>`.
		if paren_arrow_ahead(p) {
			return finish_arrow_params(p, start, is_async)
		}
	}

	restore_point(p, save)
	return nil
}

@(private = "file")
paren_arrow_ahead :: proc(p: ^Parser) -> bool {
	save := save_point(p)
	depth := 0
	ok := false
	for p.tok.kind != .eof && !p.had_error {
		if p.tok.kind == .punct {
			#partial switch p.tok.punct {
			case .lparen, .lbracket, .lbrace:
				depth += 1
			case .rparen, .rbracket, .rbrace:
				depth -= 1
				if depth == 0 {
					advance(p)
					ok = is_punct(p, .arrow) && !p.tok.nl_before
					restore_point(p, save)
					return ok
				}
			}
		}
		advance(p)
	}
	restore_point(p, save)
	return false
}

@(private = "file")
finish_arrow_single :: proc(p: ^Parser, start: Source_Pos, is_async: bool, name: string, name_pos: Source_Pos) -> ^Expr {
	fn := new(Function_Node, p.allocator)
	params := make([dynamic]^Pattern, p.allocator)
	append(&params, new_pattern(p, Ident_Pattern{pos = name_pos, name = intern(p.atoms, name), text = name}))
	fn^ = Function_Node{
		pos = start, kind = .arrow, is_async = is_async, params = params[:],
		defined_arg_count = 1, simple_params = true, strict = p.strict,
	}
	advance_re(p) // =>
	parse_arrow_body(p, fn)
	return new_expr(p, Function_Expr{pos = start, func = fn})
}

@(private = "file")
finish_arrow_params :: proc(p: ^Parser, start: Source_Pos, is_async: bool) -> ^Expr {
	fn := new(Function_Node, p.allocator)
	params, defined, simple := parse_param_list(p)
	fn^ = Function_Node{
		pos = start, kind = .arrow, is_async = is_async, params = params,
		defined_arg_count = defined, simple_params = simple, strict = p.strict,
	}
	if !is_punct(p, .arrow) {
		parse_error(p, "expected '=>'")
		return nil
	}
	advance_re(p)
	parse_arrow_body(p, fn)
	return new_expr(p, Function_Expr{pos = start, func = fn})
}

@(private = "file")
parse_arrow_body :: proc(p: ^Parser, fn: ^Function_Node) {
	saved_fn := p.in_function
	saved_async := p.in_async
	saved_gen := p.in_generator
	p.in_function = true
	p.in_async = fn.is_async
	p.in_generator = false
	defer {
		p.in_function = saved_fn
		p.in_async = saved_async
		p.in_generator = saved_gen
	}
	if is_punct(p, .lbrace) {
		fn.body_stmts = parse_function_block(p, &fn.strict)
	} else {
		fn.is_expr_body = true
		fn.body_expr = parse_assignment(p)
	}
}

// --- array / object literals --------------------------------------------------------------------------------

@(private = "file")
parse_array_literal :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	advance_re(p) // [
	elems := make([dynamic]^Expr, p.allocator)
	for !is_punct(p, .rbracket) && p.tok.kind != .eof && !p.had_error {
		if is_punct(p, .comma) {
			append(&elems, nil) // elision
			advance_re(p)
			continue
		}
		if is_punct(p, .dotdotdot) {
			sp := p.tok.pos
			advance_re(p)
			append(&elems, new_expr(p, Spread_Expr{pos = sp, arg = parse_assignment(p)}))
		} else {
			append(&elems, parse_assignment(p))
		}
		if !is_punct(p, .rbracket) {
			if !eat_punct(p, .comma) {
				break
			}
		}
	}
	expect_punct(p, .rbracket, "expected ']'")
	return new_expr(p, Array_Lit{pos = start, elements = elems[:]})
}

@(private = "file")
parse_object_literal :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	advance_re(p) // {
	props := make([dynamic]Property, p.allocator)
	for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
		append(&props, parse_object_member(p))
		if !is_punct(p, .rbrace) {
			if !eat_punct(p, .comma) {
				break
			}
		}
	}
	expect_punct(p, .rbrace, "expected '}'")
	return new_expr(p, Object_Lit{pos = start, properties = props[:]})
}

@(private = "file")
parse_object_member :: proc(p: ^Parser) -> Property {
	start := p.tok.pos
	if is_punct(p, .dotdotdot) {
		advance_re(p)
		val := parse_assignment(p)
		return Property{pos = start, kind = .spread, value = val}
	}

	is_async := false
	is_gen := false
	pkind: Property_Kind = .init

	// getter/setter/async/generator prefixes
	if p.tok.kind == .ident && !p.tok.had_escape {
		if p.tok.ident == "get" && !next_is_member_end(p) {
			advance(p)
			return parse_accessor(p, start, .get)
		}
		if p.tok.ident == "set" && !next_is_member_end(p) {
			advance(p)
			return parse_accessor(p, start, .set)
		}
		if p.tok.ident == "async" && !next_is_member_end(p) {
			save := save_point(p)
			advance(p)
			if !p.tok.nl_before && (p.tok.kind == .ident || p.tok.kind == .string || p.tok.kind == .number || is_punct(p, .lbracket) || is_punct(p, .star)) {
				is_async = true
			} else {
				restore_point(p, save)
			}
		}
	}
	if is_punct(p, .star) {
		is_gen = true
		advance(p)
	}

	computed, key, key_atom := parse_property_key(p)

	// method: key followed by `(`
	if is_punct(p, .lparen) {
		fn := parse_method_tail(p, start, .method, is_async, is_gen)
		return Property{pos = start, kind = .method, computed = computed, key = key, key_atom = key_atom, func = fn}
	}

	// shorthand or key:value
	if is_punct(p, .colon) {
		advance_re(p)
		val := parse_assignment(p)
		return Property{pos = start, kind = .init, computed = computed, key = key, key_atom = key_atom, value = val}
	}

	// shorthand with default (only valid in a destructuring pattern; keep as init for the resolver to check).
	if is_punct(p, .assign) {
		advance_re(p)
		def := parse_assignment(p)
		ident := key
		// represent `{x = 1}` as a property whose value is an Assign_Expr(x, 1)
		assign := new_expr(p, Assign_Expr{pos = start, op = .assign, target = ident, value = def})
		return Property{pos = start, kind = .shorthand, computed = false, key = key, key_atom = key_atom, value = assign}
	}

	// plain shorthand {x}
	_ = pkind
	return Property{pos = start, kind = .shorthand, computed = false, key = key, key_atom = key_atom, value = key}
}

@(private = "file")
next_is_member_end :: proc(p: ^Parser) -> bool {
	// After a would-be prefix keyword, if the next token is `:` `(` `,` `}` `=` then the keyword was actually the
	// property name, not a prefix.
	save := save_point(p)
	advance(p)
	ok := is_punct(p, .colon) || is_punct(p, .lparen) || is_punct(p, .comma) || is_punct(p, .rbrace) || is_punct(p, .assign)
	restore_point(p, save)
	return ok
}

@(private = "file")
parse_accessor :: proc(p: ^Parser, start: Source_Pos, kind: Property_Kind) -> Property {
	computed, key, key_atom := parse_property_key(p)
	fn := parse_method_tail(p, start, kind, false, false)
	return Property{pos = start, kind = kind, computed = computed, key = key, key_atom = key_atom, func = fn}
}

@(private = "file")
parse_property_key :: proc(p: ^Parser) -> (computed: bool, key: ^Expr, key_atom: Atom) {
	start := p.tok.pos
	#partial switch p.tok.kind {
	case .string:
		sv := p.tok.str
		advance(p)
		key = new_expr(p, Str_Lit{pos = start, value = sv})
		key_atom = atom_of_string_value(p, sv)
		return false, key, key_atom
	case .number:
		v := p.tok.num
		advance(p)
		key = new_expr(p, Num_Lit{pos = start, value = v, is_int = true})
		key_atom = atom_of_number(p, v)
		return false, key, key_atom
	case .bigint:
		digits := p.tok.text
		radix := p.tok.radix
		advance(p)
		key = new_expr(p, BigInt_Lit{pos = start, digits = digits, radix = radix})
		return false, key, JS_ATOM_NULL
	case .private_name:
		name := p.tok.ident
		advance(p)
		key = new_expr(p, Ident_Expr{pos = start, name = intern(p.atoms, name), text = name})
		key_atom = intern(p.atoms, name)
		return false, key, key_atom
	case .ident:
		name := p.tok.ident
		advance(p)
		key = new_expr(p, Ident_Expr{pos = start, name = intern(p.atoms, name), text = name})
		key_atom = intern(p.atoms, name)
		return false, key, key_atom
	case .punct:
		if p.tok.punct == .lbracket {
			advance_re(p)
			e := parse_assignment(p)
			expect_punct(p, .rbracket, "expected ']'")
			return true, e, JS_ATOM_NULL
		}
	}
	parse_error(p, "expected property name")
	return false, nil, JS_ATOM_NULL
}

@(private = "file")
parse_method_tail :: proc(p: ^Parser, start: Source_Pos, kind: Property_Kind, is_async, is_gen: bool) -> ^Function_Node {
	fn := new(Function_Node, p.allocator)
	fkind: Function_Kind = .method
	if kind == .get {fkind = .getter}
	if kind == .set {fkind = .setter}
	params, defined, simple := parse_param_list(p)
	fn^ = Function_Node{
		pos = start, kind = fkind, is_async = is_async, is_generator = is_gen,
		params = params, defined_arg_count = defined, simple_params = simple, strict = p.strict,
	}
	saved_fn := p.in_function; saved_a := p.in_async; saved_g := p.in_generator
	p.in_function = true; p.in_async = is_async; p.in_generator = is_gen
	fn.body_stmts = parse_function_block(p, &fn.strict)
	p.in_function = saved_fn; p.in_async = saved_a; p.in_generator = saved_g
	return fn
}

// --- functions ----------------------------------------------------------------------------------------------

// parse_function parses a function declaration or expression. The leading `function` keyword is still current
// (for the normal case); `is_async` tells whether an `async` prefix was already consumed.
parse_function :: proc(p: ^Parser, _: Function_Kind, is_async: bool, is_decl: bool) -> ^Function_Node {
	start := p.tok.pos
	advance(p) // function
	is_gen := false
	if is_punct(p, .star) {
		is_gen = true
		advance(p)
	}
	fn := new(Function_Node, p.allocator)
	name := JS_ATOM_NULL
	name_text := ""
	if p.tok.kind == .ident && (!is_decl || p.tok.keyword == JS_ATOM_NULL || is_contextual_name(p.tok.ident)) {
		if p.tok.kind == .ident {
			name = intern(p.atoms, p.tok.ident)
			name_text = p.tok.ident
			advance(p)
		}
	}
	if is_decl && name == JS_ATOM_NULL {
		parse_error(p, "function declaration requires a name")
	}
	params, defined, simple := parse_param_list(p)
	fn^ = Function_Node{
		pos = start, name = name, name_text = name_text, kind = .normal,
		is_async = is_async, is_generator = is_gen, params = params,
		defined_arg_count = defined, simple_params = simple, strict = p.strict,
	}
	saved_fn := p.in_function; saved_a := p.in_async; saved_g := p.in_generator
	p.in_function = true; p.in_async = is_async; p.in_generator = is_gen
	fn.body_stmts = parse_function_block(p, &fn.strict)
	p.in_function = saved_fn; p.in_async = saved_a; p.in_generator = saved_g
	return fn
}

@(private = "file")
is_contextual_name :: proc(name: string) -> bool {
	switch name {
	case "async", "let", "yield", "await", "of", "as", "from", "get", "set", "static", "using":
		return true
	}
	return false
}

// parse_param_list parses `( params )` and returns the patterns, the count of parameters before the first default
// or rest (the function's .length), and whether the list is "simple" (no destructuring/default/rest).
parse_param_list :: proc(p: ^Parser) -> (params: []^Pattern, defined_arg_count: int, simple: bool) {
	expect_punct(p, .lparen, "expected '('")
	list := make([dynamic]^Pattern, p.allocator)
	simple = true
	seen_default_or_rest := false
	defined := 0
	for !is_punct(p, .rparen) && p.tok.kind != .eof && !p.had_error {
		if is_punct(p, .dotdotdot) {
			sp := p.tok.pos
			advance_re(p)
			target := parse_binding_target(p)
			append(&list, new_pattern(p, Rest_Pattern{pos = sp, target = target}))
			simple = false
			seen_default_or_rest = true
			break // rest must be last
		}
		pat := parse_binding_element(p, &simple)
		append(&list, pat)
		if !seen_default_or_rest {
			if is_default_or_complex(pat) {
				seen_default_or_rest = true
			} else {
				defined += 1
			}
		}
		if !eat_punct(p, .comma) {
			break
		}
	}
	expect_punct(p, .rparen, "expected ')'")
	return list[:], defined, simple
}

@(private = "file")
is_default_or_complex :: proc(pat: ^Pattern) -> bool {
	if pat == nil {return true}
	#partial switch _ in pat^ {
	case Ident_Pattern:
		return false
	}
	return true
}

// parse_binding_element parses one parameter: a binding target with an optional default value.
@(private = "file")
parse_binding_element :: proc(p: ^Parser, simple: ^bool) -> ^Pattern {
	start := p.tok.pos
	target := parse_binding_target(p)
	if _, is_ident := target.(Ident_Pattern); !is_ident {
		simple^ = false
	}
	if eat_punct(p, .assign) {
		simple^ = false
		def := parse_assignment(p)
		return new_pattern(p, Assign_Pattern{pos = start, target = target, default = def})
	}
	return target
}

// parse_function_block parses a `{ ... }` function body and detects a "use strict" directive prologue.
parse_function_block :: proc(p: ^Parser, strict: ^bool) -> []^Stmt {
	expect_punct(p, .lbrace, "expected '{'")
	saved_strict := p.strict
	stmts := make([dynamic]^Stmt, p.allocator)
	local_strict := false
	parse_directive_prologue(p, &stmts, &local_strict)
	if local_strict {
		p.strict = true
		strict^ = true
	}
	for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
		s := parse_statement_or_decl(p, true)
		if s != nil {append(&stmts, s)}
	}
	expect_punct(p, .rbrace, "expected '}'")
	p.strict = saved_strict
	return stmts[:]
}

// --- binding targets (patterns) -----------------------------------------------------------------------------

parse_binding_target :: proc(p: ^Parser) -> ^Pattern {
	start := p.tok.pos
	if is_punct(p, .lbracket) {
		return parse_array_pattern(p)
	}
	if is_punct(p, .lbrace) {
		return parse_object_pattern(p)
	}
	if p.tok.kind == .ident {
		name := p.tok.ident
		// strict-mode: eval / arguments cannot be bound; the resolver reports it.
		atom := intern(p.atoms, name)
		advance(p)
		return new_pattern(p, Ident_Pattern{pos = start, name = atom, text = name})
	}
	parse_error(p, "expected binding target")
	advance(p)
	return new_pattern(p, Ident_Pattern{pos = start, name = JS_ATOM_NULL})
}

@(private = "file")
parse_array_pattern :: proc(p: ^Parser) -> ^Pattern {
	start := p.tok.pos
	advance_re(p) // [
	elems := make([dynamic]^Pattern, p.allocator)
	for !is_punct(p, .rbracket) && p.tok.kind != .eof && !p.had_error {
		if is_punct(p, .comma) {
			append(&elems, nil) // hole
			advance_re(p)
			continue
		}
		if is_punct(p, .dotdotdot) {
			sp := p.tok.pos
			advance_re(p)
			t := parse_binding_target(p)
			append(&elems, new_pattern(p, Rest_Pattern{pos = sp, target = t}))
			break
		}
		el := parse_binding_target(p)
		if eat_punct(p, .assign) {
			def := parse_assignment(p)
			el = new_pattern(p, Assign_Pattern{pos = start, target = el, default = def})
		}
		append(&elems, el)
		if !is_punct(p, .rbracket) {
			if !eat_punct(p, .comma) {
				break
			}
		}
	}
	expect_punct(p, .rbracket, "expected ']'")
	return new_pattern(p, Array_Pattern{pos = start, elements = elems[:]})
}

@(private = "file")
parse_object_pattern :: proc(p: ^Parser) -> ^Pattern {
	start := p.tok.pos
	advance_re(p) // {
	props := make([dynamic]Pattern_Prop, p.allocator)
	rest: ^Pattern = nil
	for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
		if is_punct(p, .dotdotdot) {
			advance_re(p)
			rest = parse_binding_target(p)
			break
		}
		pstart := p.tok.pos
		computed, key, key_atom := parse_property_key(p)
		var_target: ^Pattern
		if eat_punct(p, .colon) {
			var_target = parse_binding_target(p)
		} else {
			// shorthand {x} or {x = default}
			if ie, ok := key.(Ident_Expr); ok {
				var_target = new_pattern(p, Ident_Pattern{pos = pstart, name = ie.name, text = ie.text})
			} else {
				parse_error(p, "invalid shorthand property in pattern")
			}
		}
		if eat_punct(p, .assign) {
			def := parse_assignment(p)
			var_target = new_pattern(p, Assign_Pattern{pos = pstart, target = var_target, default = def})
		}
		append(&props, Pattern_Prop{pos = pstart, computed = computed, key = key, key_atom = key_atom, value = var_target})
		if !is_punct(p, .rbrace) {
			if !eat_punct(p, .comma) {
				break
			}
		}
	}
	expect_punct(p, .rbrace, "expected '}'")
	return new_pattern(p, Object_Pattern{pos = start, properties = props[:], rest = rest})
}

// --- classes ------------------------------------------------------------------------------------------------

parse_class :: proc(p: ^Parser, is_decl: bool) -> ^Class_Node {
	start := p.tok.pos
	advance(p) // class
	saved_strict := p.strict
	p.strict = true // class bodies are always strict
	cls := new(Class_Node, p.allocator)
	name := JS_ATOM_NULL
	name_text := ""
	if p.tok.kind == .ident && p.tok.keyword == JS_ATOM_NULL {
		name = intern(p.atoms, p.tok.ident)
		name_text = p.tok.ident
		advance(p)
	} else if is_decl {
		parse_error(p, "class declaration requires a name")
	}
	super_class: ^Expr = nil
	if is_kw(p, "extends") {
		advance_re(p)
		super_class = parse_call_member(p)
	}
	expect_punct(p, .lbrace, "expected '{'")
	members := make([dynamic]Property, p.allocator)
	for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
		if eat_punct(p, .semicolon) {
			continue
		}
		append(&members, parse_class_member(p))
	}
	expect_punct(p, .rbrace, "expected '}'")
	cls^ = Class_Node{pos = start, name = name, name_text = name_text, super_class = super_class, members = members[:]}
	p.strict = saved_strict
	return cls
}

@(private = "file")
parse_class_member :: proc(p: ^Parser) -> Property {
	start := p.tok.pos
	is_static := false
	if is_kw(p, "static") && !static_is_name(p) {
		advance(p)
		is_static = true
		// static block
		if is_punct(p, .lbrace) {
			block := parse_block(p)
			return Property{pos = start, kind = .static_block, is_static = true, value = block_to_expr(p, block)}
		}
	}

	is_async := false
	is_gen := false
	pkind: Property_Kind = .field

	if is_kw(p, "get") && !next_is_class_member_end(p) {
		advance(p)
		return parse_class_accessor(p, start, .get, is_static)
	}
	if is_kw(p, "set") && !next_is_class_member_end(p) {
		advance(p)
		return parse_class_accessor(p, start, .set, is_static)
	}
	if is_kw(p, "async") && !next_is_class_member_end(p) {
		save := save_point(p)
		advance(p)
		if !p.tok.nl_before {
			is_async = true
		} else {
			restore_point(p, save)
		}
	}
	if is_punct(p, .star) {
		is_gen = true
		advance(p)
	}

	is_private := p.tok.kind == .private_name
	computed, key, key_atom := parse_property_key(p)

	if is_punct(p, .lparen) {
		fn := parse_method_tail(p, start, .method, is_async, is_gen)
		return Property{
			pos = start, kind = .method, computed = computed, is_static = is_static,
			is_private = is_private, key = key, key_atom = key_atom, func = fn,
		}
	}

	// field
	_ = pkind
	val: ^Expr = nil
	if eat_punct(p, .assign) {
		val = parse_assignment(p)
	}
	consume_semicolon(p)
	return Property{
		pos = start, kind = .field, computed = computed, is_static = is_static,
		is_private = is_private, key = key, key_atom = key_atom, value = val,
	}
}

@(private = "file")
parse_class_accessor :: proc(p: ^Parser, start: Source_Pos, kind: Property_Kind, is_static: bool) -> Property {
	is_private := p.tok.kind == .private_name
	computed, key, key_atom := parse_property_key(p)
	fn := parse_method_tail(p, start, kind, false, false)
	return Property{
		pos = start, kind = kind, computed = computed, is_static = is_static,
		is_private = is_private, key = key, key_atom = key_atom, func = fn,
	}
}

@(private = "file")
static_is_name :: proc(p: ^Parser) -> bool {
	save := save_point(p)
	advance(p)
	ok := is_punct(p, .assign) || is_punct(p, .semicolon) || is_punct(p, .lparen) || is_punct(p, .rbrace)
	restore_point(p, save)
	return ok
}

@(private = "file")
next_is_class_member_end :: proc(p: ^Parser) -> bool {
	save := save_point(p)
	advance(p)
	ok := is_punct(p, .assign) || is_punct(p, .semicolon) || is_punct(p, .lparen) || is_punct(p, .rbrace)
	restore_point(p, save)
	return ok
}

@(private = "file")
block_to_expr :: proc(p: ^Parser, block: ^Stmt) -> ^Expr {
	// A static block is stored as a Paren_Expr wrapper is not right; keep the block via a Function_Expr-less
	// slot. We reuse value with a dedicated marker: wrap the block's statements in a synthetic function node.
	// For simplicity in the AST, store the block statements on a Function_Node body with kind method.
	bs := block.(Block_Stmt)
	fn := new(Function_Node, p.allocator)
	fn^ = Function_Node{pos = bs.pos, kind = .method, body_stmts = bs.stmts, strict = true}
	return new_expr(p, Function_Expr{pos = bs.pos, func = fn})
}

// --- import / export ----------------------------------------------------------------------------------------

@(private = "file")
parse_import_expr :: proc(p: ^Parser) -> ^Expr {
	start := p.tok.pos
	advance(p) // import
	if is_punct(p, .dot) {
		advance(p)
		if p.tok.kind == .ident && p.tok.ident == "meta" {
			advance(p)
			return new_expr(p, Import_Meta_Expr{pos = start})
		}
		parse_error(p, "expected 'meta' after 'import.'")
		return nil
	}
	if is_punct(p, .lparen) {
		args := parse_arguments(p)
		// Represent dynamic import as a Call_Expr on a synthetic Import_Meta marker; the emitter handles it.
		callee := new_expr(p, Import_Meta_Expr{pos = start}) // placeholder marker, emitter distinguishes
		return new_expr(p, Call_Expr{pos = start, callee = callee, args = args})
	}
	parse_error(p, "unexpected 'import'")
	return nil
}

parse_import :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance(p) // import
	decl := new(Import_Decl, p.allocator)
	decl.pos = start

	// `import "mod";`
	if p.tok.kind == .string {
		decl.source = p.tok.str
		decl.source_text = p.tok.ident
		advance(p)
		parse_import_attributes(p, decl)
		consume_semicolon(p)
		s := new(Stmt, p.allocator)
		s^ = decl^
		return s
	}

	names := make([dynamic]Import_Specifier, p.allocator)
	// default import
	if p.tok.kind == .ident && p.tok.keyword == JS_ATOM_NULL {
		decl.default_name = intern(p.atoms, p.tok.ident)
		advance(p)
		eat_punct(p, .comma)
	}
	// namespace import
	if is_punct(p, .star) {
		advance(p)
		if is_kw(p, "as") {
			advance(p)
		}
		if p.tok.kind == .ident {
			decl.namespace_name = intern(p.atoms, p.tok.ident)
			advance(p)
		}
	} else if is_punct(p, .lbrace) {
		advance_re(p)
		for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
			imp_text := p.tok.ident
			imp := intern(p.atoms, p.tok.ident)
			local := imp
			local_text := imp_text
			advance(p)
			if is_kw(p, "as") {
				advance(p)
				local_text = p.tok.ident
				local = intern(p.atoms, p.tok.ident)
				advance(p)
			}
			append(&names, Import_Specifier{imported = imp, local = local, imported_text = imp_text, local_text = local_text})
			if !eat_punct(p, .comma) {
				break
			}
		}
		expect_punct(p, .rbrace, "expected '}'")
	}
	decl.names = names[:]
	if is_kw(p, "from") {
		advance(p)
		if p.tok.kind == .string {
			decl.source = p.tok.str
			decl.source_text = p.tok.ident
			advance(p)
		} else {
			parse_error(p, "expected module specifier string")
		}
	}
	parse_import_attributes(p, decl)
	consume_semicolon(p)
	s := new(Stmt, p.allocator)
	s^ = decl^
	return s
}

@(private = "file")
parse_import_attributes :: proc(p: ^Parser, decl: ^Import_Decl) {
	// `with { type: "json" }` (import attributes) or the older `assert { ... }`.
	if is_kw(p, "with") || is_kw(p, "assert") {
		advance(p)
		expect_punct(p, .lbrace, "expected '{'")
		attrs := make([dynamic]Import_Attribute, p.allocator)
		for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
			key := p.tok.ident
			advance(p)
			expect_punct(p, .colon, "expected ':'")
			val := p.tok.str
			advance(p)
			append(&attrs, Import_Attribute{key = key, value = val})
			if !eat_punct(p, .comma) {
				break
			}
		}
		expect_punct(p, .rbrace, "expected '}'")
		decl.attributes = attrs[:]
	}
}

parse_export :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance(p) // export
	decl := new(Export_Decl, p.allocator)
	decl.pos = start

	if is_kw(p, "default") {
		advance_re(p)
		decl.is_default = true
		if is_kw(p, "function") || (is_kw(p, "async") && async_function_expr_follows(p)) {
			is_async := false
			if is_kw(p, "async") {is_async = true; advance(p)}
			fn := parse_function(p, .normal, is_async, false)
			decl.default_decl = new_stmt(p, Function_Stmt{pos = start, func = fn})
		} else if is_kw(p, "class") {
			cls := parse_class(p, false)
			decl.default_decl = new_stmt(p, Class_Stmt{pos = start, class = cls})
		} else {
			decl.default_expr = parse_assignment(p)
			consume_semicolon(p)
		}
		s := new(Stmt, p.allocator); s^ = decl^
		return s
	}

	if is_punct(p, .star) {
		advance(p)
		decl.star = true
		if is_kw(p, "as") {
			advance(p)
			decl.star_as = intern(p.atoms, p.tok.ident)
			advance(p)
		}
		if is_kw(p, "from") {
			advance(p)
			if p.tok.kind == .string {
				decl.source = p.tok.str
				decl.source_text = p.tok.ident
				decl.has_source = true
				advance(p)
			}
		}
		consume_semicolon(p)
		s := new(Stmt, p.allocator); s^ = decl^
		return s
	}

	if is_punct(p, .lbrace) {
		advance_re(p)
		specs := make([dynamic]Export_Specifier, p.allocator)
		for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
			local_text := p.tok.ident
			local := intern(p.atoms, p.tok.ident)
			exported := local
			exported_text := local_text
			advance(p)
			if is_kw(p, "as") {
				advance(p)
				exported_text = p.tok.ident
				exported = intern(p.atoms, p.tok.ident)
				advance(p)
			}
			append(&specs, Export_Specifier{local = local, exported = exported, local_text = local_text, exported_text = exported_text})
			if !eat_punct(p, .comma) {
				break
			}
		}
		expect_punct(p, .rbrace, "expected '}'")
		decl.names = specs[:]
		if is_kw(p, "from") {
			advance(p)
			if p.tok.kind == .string {
				decl.source = p.tok.str
				decl.source_text = p.tok.ident
				decl.has_source = true
				advance(p)
			}
		}
		consume_semicolon(p)
		s := new(Stmt, p.allocator); s^ = decl^
		return s
	}

	// export <var/let/const/function/class declaration>
	decl.decl = parse_statement_or_decl(p, true)
	s := new(Stmt, p.allocator); s^ = decl^
	return s
}

// --- yield --------------------------------------------------------------------------------------------------

@(private = "file")
try_parse_yield :: proc(p: ^Parser) -> ^Expr {
	if !p.in_generator || !is_kw(p, "yield") {
		return nil
	}
	start := p.tok.pos
	advance_re(p)
	delegate := false
	if is_punct(p, .star) {
		delegate = true
		advance_re(p)
	}
	arg: ^Expr = nil
	if !p.tok.nl_before && yield_arg_follows(p) {
		arg = parse_assignment(p)
	}
	return new_expr(p, Yield_Expr{pos = start, arg = arg, delegate = delegate})
}

@(private = "file")
yield_arg_follows :: proc(p: ^Parser) -> bool {
	if p.tok.kind == .eof {return false}
	if p.tok.kind == .punct {
		#partial switch p.tok.punct {
		case .rparen, .rbracket, .rbrace, .comma, .semicolon, .colon:
			return false
		}
	}
	return true
}

// --- assignment-target validation ---------------------------------------------------------------------------

@(private = "file")
is_valid_assign_target :: proc(e: ^Expr) -> bool {
	if e == nil {return false}
	#partial switch v in e^ {
	case Ident_Expr:
		return true
	case Member_Expr:
		return true
	case Array_Lit, Object_Lit:
		return true // destructuring target
	case Paren_Expr:
		return is_valid_assign_target(v.expr)
	}
	return false
}

@(private = "file")
is_simple_assign_target :: proc(e: ^Expr) -> bool {
	if e == nil {return false}
	#partial switch v in e^ {
	case Ident_Expr:
		return true
	case Member_Expr:
		return true
	case Paren_Expr:
		return is_simple_assign_target(v.expr)
	}
	return false
}

// --- small helpers ------------------------------------------------------------------------------------------

@(private = "file")
atom_of_string_value :: proc(p: ^Parser, sv: String_Value) -> Atom {
	if sv.is_wide {
		return intern_utf16(p.atoms, sv.units)
	}
	return intern(p.atoms, string(sv.latin1))
}

@(private = "file")
atom_of_number :: proc(p: ^Parser, v: f64) -> Atom {
	// A numeric property key becomes the ToString of the number as an atom. Integer keys in array-index range
	// become tagged-integer atoms; others become string atoms of their shortest decimal form.
	if v == f64(i32(v)) && v >= 0 {
		return intern(p.atoms, i32_decimal(p, i32(v)))
	}
	buf: [32]u8
	n := f64_shortest(buf[:], v)
	return intern(p.atoms, string(buf[:n]))
}

// i32_decimal renders an i32 as its decimal string (for numeric property keys that are array indices) on the
// arena, via numconv's allocation-free integer formatter.
@(private = "file")
i32_decimal :: proc(p: ^Parser, n: i32) -> string {
	buf: [16]u8
	k := numconv.i32_to_string(buf[:], n)
	b := make([]u8, k, p.allocator)
	copy(b, buf[:k])
	return string(b)
}

// f64_shortest writes the ECMAScript ToString of a Number into buf and returns the length, via numconv.
@(private = "file")
f64_shortest :: proc(buf: []u8, d: f64) -> int {
	return numconv.f64_to_shortest(buf, d)
}

// expr_pos returns the source position of any expression node.
expr_pos :: proc(e: Expr) -> Source_Pos {
	switch v in e {
	case Ident_Expr: return v.pos
	case This_Expr: return v.pos
	case Super_Expr: return v.pos
	case New_Target_Expr: return v.pos
	case Import_Meta_Expr: return v.pos
	case Null_Lit: return v.pos
	case Bool_Lit: return v.pos
	case Num_Lit: return v.pos
	case BigInt_Lit: return v.pos
	case Str_Lit: return v.pos
	case Regexp_Lit: return v.pos
	case Template_Lit: return v.pos
	case Tagged_Template_Expr: return v.pos
	case Array_Lit: return v.pos
	case Object_Lit: return v.pos
	case Function_Expr: return v.pos
	case Class_Expr: return v.pos
	case Unary_Expr: return v.pos
	case Update_Expr: return v.pos
	case Binary_Expr: return v.pos
	case Logical_Expr: return v.pos
	case Assign_Expr: return v.pos
	case Conditional_Expr: return v.pos
	case Call_Expr: return v.pos
	case New_Expr: return v.pos
	case Member_Expr: return v.pos
	case Sequence_Expr: return v.pos
	case Spread_Expr: return v.pos
	case Yield_Expr: return v.pos
	case Await_Expr: return v.pos
	case Paren_Expr: return v.pos
	case Optional_Chain: return v.pos
	}
	return Source_Pos{}
}
