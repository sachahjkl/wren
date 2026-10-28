package frontend

import "base:runtime"

// The parser: recursive descent over the token stream, building the arena AST. It handles scripts, modules and
// the eval / Function-body variants, the full statement grammar, strict-mode and Annex B rules, automatic
// semicolon insertion, and early-error detection (duplicate lexical declarations, illegal break/continue,
// invalid assignment targets, etc.). Expression parsing lives in parser_expr.odin; both share this Parser state.
//
// Token lookahead: the parser keeps the current token and re-lexes on demand. Because the `/` vs regexp decision
// is context-sensitive, the parser recomputes the current token whenever it needs the regexp-allowed flag to
// change (peek_div / peek_regexp). This mirrors QuickJS's re-tokenization around the slash.

Parser :: struct {
	lex:        Lexer,
	allocator:  runtime.Allocator,
	atoms:      ^Atom_Table,
	tok:        Token,
	prev_end:   Source_Pos,
	kind:       Program_Kind,
	is_module:  bool,
	strict:     bool,
	// Context flags for the current function (whether yield/await are keywords, whether return is allowed, etc.).
	in_function:    bool,
	in_generator:   bool,
	in_async:       bool,
	in_loop_depth:  int,
	in_switch_depth:int,
	allow_in:       bool, // the `in` operator is forbidden in a for-init position
	had_error:  bool,
	error:      Error,
}

// --- arena allocation helpers -------------------------------------------------------------------------------

new_expr :: proc(p: ^Parser, e: Expr) -> ^Expr {
	ptr := new(Expr, p.allocator)
	ptr^ = e
	return ptr
}

new_stmt :: proc(p: ^Parser, s: Stmt) -> ^Stmt {
	ptr := new(Stmt, p.allocator)
	ptr^ = s
	return ptr
}

new_pattern :: proc(p: ^Parser, pat: Pattern) -> ^Pattern {
	ptr := new(Pattern, p.allocator)
	ptr^ = pat
	return ptr
}

// --- error handling -----------------------------------------------------------------------------------------

parse_error :: proc(p: ^Parser, msg: string) {
	if !p.had_error {
		p.had_error = true
		p.error = make_error(msg, p.tok.pos)
	}
}

error_at :: proc(p: ^Parser, msg: string, pos: Source_Pos) {
	if !p.had_error {
		p.had_error = true
		p.error = make_error(msg, pos)
	}
}

// --- token helpers ------------------------------------------------------------------------------------------

lex_opts :: proc(p: ^Parser, regexp_allowed: bool) -> Lex_Options {
	return Lex_Options{
		regexp_allowed = regexp_allowed,
		html_comments = !p.is_module,
		strict = p.strict,
	}
}

// advance scans the next token, deciding the `/`-vs-regexp context from the token being consumed: a regexp can
// begin only where a value can (after an operator, comma, open bracket, `;`, `=>`, or a keyword that is not a
// value). A `/` after something that can end an expression (identifier, literal, `)`, `]`, `}`) is division. This
// mirrors QuickJS re-tokenizing around the slash and removes the need for callers to track the context by hand.
advance :: proc(p: ^Parser) {
	allowed := regexp_allowed_after(p.tok)
	p.prev_end = p.tok.end
	p.tok = next_token(&p.lex, lex_opts(p, allowed))
	sync_lex_error(p)
}

// advance_re forces regexp-allowed context (used where the grammar guarantees a value follows). It is kept as an
// explicit alias for readability; it behaves like advance in positions where a regexp is allowed anyway.
advance_re :: proc(p: ^Parser) {
	p.prev_end = p.tok.end
	p.tok = next_token(&p.lex, lex_opts(p, true))
	sync_lex_error(p)
}

// regexp_allowed_after reports whether a `/` immediately after `tok` begins a regexp literal. False only when the
// token can end an expression: an identifier that is not a keyword, a literal, or a closing `)`/`]`/`}`. A
// keyword like `return`/`typeof`/`case` allows a regexp; `this`/`super`/`true`/`false`/`null` do not.
regexp_allowed_after :: proc(tok: Token) -> bool {
	#partial switch tok.kind {
	case .number, .bigint, .string, .regexp, .template:
		return false
	case .private_name:
		return false
	case .ident:
		// value-ish keywords end an expression; other keywords (control words) allow a regexp.
		if tok.keyword != JS_ATOM_NULL {
			switch tok.ident {
			case "this", "super", "true", "false", "null":
				return false
			}
			return true
		}
		return false // a plain identifier ends an expression
	case .punct:
		#partial switch tok.punct {
		case .rparen, .rbracket:
			return false
		case .rbrace:
			// `}` is ambiguous (block end vs object end); QuickJS treats a regexp as allowed after `}`.
			return true
		case .plusplus, .minusminus:
			return false
		}
		return true
	case .eof:
		return true
	}
	return true
}

sync_lex_error :: proc(p: ^Parser) {
	if p.lex.had_error && !p.had_error {
		p.had_error = true
		p.error = p.lex.error
	}
}

is_punct :: #force_inline proc(p: ^Parser, pk: Punct) -> bool {
	return p.tok.kind == .punct && p.tok.punct == pk
}

is_kw :: #force_inline proc(p: ^Parser, name: string) -> bool {
	return p.tok.kind == .ident && !p.tok.had_escape && p.tok.ident == name
}

// eat_punct consumes a punctuator if present (division context). Returns whether it matched.
eat_punct :: proc(p: ^Parser, pk: Punct) -> bool {
	if is_punct(p, pk) {
		advance(p)
		return true
	}
	return false
}

expect_punct :: proc(p: ^Parser, pk: Punct, msg: string) {
	if !is_punct(p, pk) {
		parse_error(p, msg)
		return
	}
	advance(p)
}

// --- top-level ---------------------------------------------------------------------------------------------

// parse parses a whole program. `kind` selects script / module / eval semantics; the returned Program points into
// the arena. On error, p.had_error is set and the Program is partial.
parse :: proc(p: ^Parser, src: string, kind: Program_Kind, atoms: ^Atom_Table, allocator: runtime.Allocator) -> ^Program {
	p.allocator = allocator
	p.atoms = atoms
	p.kind = kind
	p.is_module = kind == .module
	p.allow_in = true
	lexer_init(&p.lex, src, allocator)
	p.strict = kind == .module // modules are always strict
	p.lex.strict = p.strict

	prog := new(Program, allocator)
	prog.kind = kind

	advance_re(p)
	// Directive prologue: detect "use strict" among the leading string-literal statements.
	stmts := make([dynamic]^Stmt, allocator)
	parse_directive_prologue(p, &stmts, &prog.strict)
	p.strict = p.strict || prog.strict
	p.lex.strict = p.strict

	for p.tok.kind != .eof && !p.had_error {
		s := parse_statement_or_decl(p, true)
		if s != nil {
			append(&stmts, s)
		}
	}
	prog.stmts = stmts[:]
	prog.strict = p.strict
	return prog
}

// parse_directive_prologue consumes leading expression statements that are plain string literals. A "use strict"
// directive turns on strict mode for the rest of the program. Mirrors QuickJS's js_parse_directives.
parse_directive_prologue :: proc(p: ^Parser, out: ^[dynamic]^Stmt, strict: ^bool) {
	for p.tok.kind == .string && !p.had_error {
		start := p.tok.pos
		// A directive is a string literal that is the entire statement (no operators following).
		lit := p.tok
		// Peek: the raw directive text is the source slice between the quotes.
		raw := directive_raw(p, lit)
		advance(p)
		// If what follows continues an expression, this is not a directive; fall back to expression statement.
		if continues_expression(p) {
			e := finish_string_then_expr(p, lit, start)
			s := new_stmt(p, Expr_Stmt{pos = start, expr = e})
			append(out, s)
			consume_semicolon(p)
			continue
		}
		consume_semicolon(p)
		if raw == "use strict" {
			strict^ = true
		}
		se := new_expr(p, Str_Lit{pos = start, value = lit.str})
		s := new_stmt(p, Expr_Stmt{pos = start, expr = se, directive = raw})
		append(out, s)
	}
}

// directive_raw returns the exact source characters of a string literal (without the quotes) so "use strict" is
// recognized only when written literally (no escapes). QuickJS compares the raw source slice.
@(private = "file")
directive_raw :: proc(p: ^Parser, t: Token) -> string {
	// t.pos.offset is the opening quote; t.end.offset is one past the closing quote.
	lo := int(t.pos.offset) + 1
	hi := int(t.end.offset) - 1
	if lo >= 0 && hi <= len(p.lex.src) && lo <= hi {
		return p.lex.src[lo:hi]
	}
	return ""
}

@(private = "file")
continues_expression :: proc(p: ^Parser) -> bool {
	// After a string literal, a punctuator that can continue an expression (., [, (, binary ops, etc.) means it
	// was not a standalone directive.
	if p.tok.kind != .punct {
		return false
	}
	#partial switch p.tok.punct {
	case .dot, .lbracket, .lparen, .plus, .minus, .star, .slash, .percent, .comma, .question, .assign,
	     .eq, .neq, .strict_eq, .strict_neq, .lt, .gt, .lte, .gte, .and_and, .or_or, .question_question,
	     .amp, .bar, .caret, .shl, .sar, .shr, .starstar:
		return true
	}
	return false
}

@(private = "file")
finish_string_then_expr :: proc(p: ^Parser, lit: Token, start: Source_Pos) -> ^Expr {
	base := new_expr(p, Str_Lit{pos = start, value = lit.str})
	return parse_assignment_continued(p, base)
}

// --- semicolons / ASI ---------------------------------------------------------------------------------------

// consume_semicolon applies automatic semicolon insertion: a `;` is consumed if present; otherwise a semicolon is
// inserted before `}`, at EOF, or when a line terminator preceded the current token.
consume_semicolon :: proc(p: ^Parser) {
	if is_punct(p, .semicolon) {
		advance_re(p)
		return
	}
	if is_punct(p, .rbrace) || p.tok.kind == .eof || p.tok.nl_before {
		return
	}
	parse_error(p, "expected ';'")
}

// --- statements ---------------------------------------------------------------------------------------------

// parse_statement_or_decl parses one statement or declaration. `top` indicates statement-list position where
// declarations (let/const/class/function/import/export) are allowed.
parse_statement_or_decl :: proc(p: ^Parser, top: bool) -> ^Stmt {
	if p.had_error {
		return nil
	}
	start := p.tok.pos

	if p.tok.kind == .punct {
		#partial switch p.tok.punct {
		case .lbrace:
			return parse_block(p)
		case .semicolon:
			advance_re(p)
			return new_stmt(p, Empty_Stmt{pos = start})
		}
	}

	if p.tok.kind == .ident {
		name := p.tok.ident
		if !p.tok.had_escape {
			switch name {
			case "var":
				return parse_var_decl(p, .var)
			case "let":
				if lexical_decl_follows(p) {
					return parse_var_decl(p, .let)
				}
			case "const":
				return parse_var_decl(p, .const_)
			case "using":
				if using_decl_follows(p) {
					return parse_var_decl(p, .using_)
				}
			case "function":
				return parse_function_decl(p, false)
			case "async":
				if async_function_follows(p) {
					return parse_function_decl(p, true)
				}
			case "class":
				return parse_class_decl(p)
			case "if":
				return parse_if(p)
			case "for":
				return parse_for(p)
			case "while":
				return parse_while(p)
			case "do":
				return parse_do_while(p)
			case "switch":
				return parse_switch(p)
			case "return":
				return parse_return(p)
			case "break":
				return parse_break_continue(p, true)
			case "continue":
				return parse_break_continue(p, false)
			case "throw":
				return parse_throw(p)
			case "try":
				return parse_try(p)
			case "with":
				return parse_with(p)
			case "debugger":
				advance(p)
				consume_semicolon(p)
				return new_stmt(p, Debugger_Stmt{pos = start})
			case "import":
				if top && p.is_module && !import_is_expression(p) {
					return parse_import(p)
				}
			case "export":
				if top && p.is_module {
					return parse_export(p)
				}
			}
			// Labeled statement: `ident :`
			if labeled_follows(p) {
				return parse_labeled(p)
			}
		}
	}

	// Fall through: an expression statement.
	return parse_expr_statement(p)
}

parse_block :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance_re(p) // {
	stmts := make([dynamic]^Stmt, p.allocator)
	for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
		s := parse_statement_or_decl(p, true)
		if s != nil {append(&stmts, s)}
	}
	expect_punct(p, .rbrace, "expected '}'")
	// re-arm regexp context after the closing brace
	return new_stmt(p, Block_Stmt{pos = start, stmts = stmts[:]})
}

@(private = "file")
parse_var_decl :: proc(p: ^Parser, kind: Decl_Kind) -> ^Stmt {
	start := p.tok.pos
	advance_re(p) // var/let/const/using
	// await using
	actual := kind
	if kind == .using_ && false {
		// placeholder; await using handled in statement dispatch
	}
	decls := make([dynamic]Var_Declarator, p.allocator)
	for {
		dstart := p.tok.pos
		target := parse_binding_target(p)
		init: ^Expr = nil
		if eat_punct(p, .assign) {
			init = parse_assignment(p)
		} else if (actual == .const_) && p.allow_in {
			// const requires an initializer, except in for-in/of heads (allow_in is false there).
			parse_error(p, "missing initializer in const declaration")
		}
		append(&decls, Var_Declarator{pos = dstart, target = target, init = init})
		if !eat_punct(p, .comma) {
			break
		}
	}
	if p.allow_in {
		consume_semicolon(p)
	}
	return new_stmt(p, Var_Decl{pos = start, kind = actual, decls = decls[:]})
}

@(private = "file")
parse_function_decl :: proc(p: ^Parser, is_async: bool) -> ^Stmt {
	start := p.tok.pos
	if is_async {
		advance(p) // async
	}
	fn := parse_function(p, .normal, is_async, true)
	return new_stmt(p, Function_Stmt{pos = start, func = fn})
}

@(private = "file")
parse_class_decl :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	cls := parse_class(p, true)
	return new_stmt(p, Class_Stmt{pos = start, class = cls})
}

@(private = "file")
parse_if :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance(p)
	expect_punct(p, .lparen, "expected '(' after 'if'")
	cond := parse_expression(p)
	expect_punct(p, .rparen, "expected ')'")
	then := parse_statement_or_decl(p, false)
	els: ^Stmt = nil
	if is_kw(p, "else") {
		advance_re(p)
		els = parse_statement_or_decl(p, false)
	}
	return new_stmt(p, If_Stmt{pos = start, cond = cond, then = then, els = els})
}

@(private = "file")
parse_while :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance(p)
	expect_punct(p, .lparen, "expected '('")
	cond := parse_expression(p)
	expect_punct(p, .rparen, "expected ')'")
	p.in_loop_depth += 1
	body := parse_statement_or_decl(p, false)
	p.in_loop_depth -= 1
	return new_stmt(p, While_Stmt{pos = start, cond = cond, body = body})
}

@(private = "file")
parse_do_while :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance_re(p)
	p.in_loop_depth += 1
	body := parse_statement_or_decl(p, false)
	p.in_loop_depth -= 1
	if !is_kw(p, "while") {
		parse_error(p, "expected 'while'")
		return nil
	}
	advance(p)
	expect_punct(p, .lparen, "expected '('")
	cond := parse_expression(p)
	expect_punct(p, .rparen, "expected ')'")
	eat_punct(p, .semicolon) // optional per Annex B
	return new_stmt(p, Do_While_Stmt{pos = start, body = body, cond = cond})
}

@(private = "file")
parse_for :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance(p)
	is_await := false
	if is_kw(p, "await") {
		is_await = true
		advance(p)
	}
	expect_punct(p, .lparen, "expected '('")

	// Parse the init part. It may be a var/let/const/using declaration, an expression, or empty, and may be the
	// left side of for-in / for-of.
	init_decl: ^Var_Decl = nil
	init_expr: ^Expr = nil
	left_expr: ^Expr = nil
	saved_allow_in := p.allow_in
	p.allow_in = false

	if is_punct(p, .semicolon) {
		// classic for with empty init
	} else if decl_keyword_here(p) {
		d := parse_for_decl_head(p)
		init_decl = d
	} else {
		init_expr = parse_expression_no_in(p)
		left_expr = init_expr
	}
	p.allow_in = saved_allow_in

	// for-in / for-of
	if is_kw(p, "in") || is_kw(p, "of") {
		of := is_kw(p, "of")
		advance_re(p)
		fk: For_In_Kind = of ? (is_await ? .await_of : .of_) : .in_
		right: ^Expr
		if of {
			right = parse_assignment(p)
		} else {
			right = parse_expression(p)
		}
		expect_punct(p, .rparen, "expected ')'")
		p.in_loop_depth += 1
		body := parse_statement_or_decl(p, false)
		p.in_loop_depth -= 1
		return new_stmt(p, For_In_Stmt{
			pos = start, kind = fk, left_decl = init_decl, left_expr = left_expr,
			right = right, body = body,
		})
	}

	// classic for(;;)
	if init_decl == nil {
		// init_expr already parsed, or empty
	}
	expect_punct(p, .semicolon, "expected ';'")
	cond: ^Expr = nil
	if !is_punct(p, .semicolon) {
		cond = parse_expression(p)
	}
	expect_punct(p, .semicolon, "expected ';'")
	update: ^Expr = nil
	if !is_punct(p, .rparen) {
		update = parse_expression(p)
	}
	expect_punct(p, .rparen, "expected ')'")
	p.in_loop_depth += 1
	body := parse_statement_or_decl(p, false)
	p.in_loop_depth -= 1
	return new_stmt(p, For_Stmt{
		pos = start, init_decl = init_decl, init_expr = init_expr,
		cond = cond, update = update, body = body,
	})
}

@(private = "file")
decl_keyword_here :: proc(p: ^Parser) -> bool {
	if p.tok.kind != .ident || p.tok.had_escape {
		return false
	}
	switch p.tok.ident {
	case "var":
		return true
	case "const":
		return true
	case "let":
		return lexical_decl_follows(p)
	case "using":
		return using_decl_follows(p)
	}
	return false
}

@(private = "file")
parse_for_decl_head :: proc(p: ^Parser) -> ^Var_Decl {
	kind: Decl_Kind = .var
	switch p.tok.ident {
	case "var": kind = .var
	case "let": kind = .let
	case "const": kind = .const_
	case "using": kind = .using_
	}
	start := p.tok.pos
	advance_re(p)
	decls := make([dynamic]Var_Declarator, p.allocator)
	for {
		dstart := p.tok.pos
		target := parse_binding_target(p)
		init: ^Expr = nil
		if eat_punct(p, .assign) {
			init = parse_assignment(p)
		}
		append(&decls, Var_Declarator{pos = dstart, target = target, init = init})
		if !eat_punct(p, .comma) {
			break
		}
	}
	vd := new(Var_Decl, p.allocator)
	vd^ = Var_Decl{pos = start, kind = kind, decls = decls[:]}
	return vd
}

@(private = "file")
parse_switch :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance(p)
	expect_punct(p, .lparen, "expected '('")
	disc := parse_expression(p)
	expect_punct(p, .rparen, "expected ')'")
	expect_punct(p, .lbrace, "expected '{'")
	cases := make([dynamic]Switch_Case, p.allocator)
	seen_default := false
	p.in_switch_depth += 1
	for !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
		cstart := p.tok.pos
		test: ^Expr = nil
		if is_kw(p, "case") {
			advance_re(p)
			test = parse_expression(p)
		} else if is_kw(p, "default") {
			if seen_default {
				parse_error(p, "more than one default clause in switch statement")
			}
			seen_default = true
			advance_re(p)
		} else {
			parse_error(p, "expected 'case' or 'default'")
			break
		}
		expect_punct(p, .colon, "expected ':'")
		body := make([dynamic]^Stmt, p.allocator)
		for !is_kw(p, "case") && !is_kw(p, "default") && !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.had_error {
			s := parse_statement_or_decl(p, true)
			if s != nil {append(&body, s)}
		}
		append(&cases, Switch_Case{pos = cstart, test = test, body = body[:]})
	}
	p.in_switch_depth -= 1
	expect_punct(p, .rbrace, "expected '}'")
	return new_stmt(p, Switch_Stmt{pos = start, disc = disc, cases = cases[:]})
}

@(private = "file")
parse_return :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	if !p.in_function {
		parse_error(p, "return not in a function")
	}
	advance_re(p)
	arg: ^Expr = nil
	if !is_punct(p, .semicolon) && !is_punct(p, .rbrace) && p.tok.kind != .eof && !p.tok.nl_before {
		arg = parse_expression(p)
	}
	consume_semicolon(p)
	return new_stmt(p, Return_Stmt{pos = start, arg = arg})
}

@(private = "file")
parse_break_continue :: proc(p: ^Parser, is_break: bool) -> ^Stmt {
	start := p.tok.pos
	advance(p)
	label := JS_ATOM_NULL
	label_text := ""
	if p.tok.kind == .ident && !p.tok.nl_before && p.tok.keyword == JS_ATOM_NULL {
		label = intern(p.atoms, p.tok.ident)
		label_text = p.tok.ident
		advance(p)
	}
	if label == JS_ATOM_NULL {
		if is_break && p.in_loop_depth == 0 && p.in_switch_depth == 0 {
			parse_error(p, "break must be inside loop or switch")
		}
		if !is_break && p.in_loop_depth == 0 {
			parse_error(p, "continue must be inside loop")
		}
	}
	consume_semicolon(p)
	if is_break {
		return new_stmt(p, Break_Stmt{pos = start, label = label, label_text = label_text})
	}
	return new_stmt(p, Continue_Stmt{pos = start, label = label, label_text = label_text})
}

@(private = "file")
parse_throw :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance_re(p)
	if p.tok.nl_before {
		parse_error(p, "line break not allowed after 'throw'")
	}
	arg := parse_expression(p)
	consume_semicolon(p)
	return new_stmt(p, Throw_Stmt{pos = start, arg = arg})
}

@(private = "file")
parse_try :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	advance_re(p)
	block := parse_block(p)
	catch_param: ^Pattern = nil
	catch_block: ^Stmt = nil
	finally_block: ^Stmt = nil
	if is_kw(p, "catch") {
		advance(p)
		if eat_punct(p, .lparen) {
			catch_param = parse_binding_target(p)
			expect_punct(p, .rparen, "expected ')'")
		}
		catch_block = parse_block(p)
	}
	if is_kw(p, "finally") {
		advance_re(p)
		finally_block = parse_block(p)
	}
	if catch_block == nil && finally_block == nil {
		parse_error(p, "missing catch or finally after try")
	}
	return new_stmt(p, Try_Stmt{
		pos = start, block = block, catch_param = catch_param,
		catch_block = catch_block, finally_block = finally_block,
	})
}

@(private = "file")
parse_with :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	if p.strict {
		parse_error(p, "'with' statements are not allowed in strict mode")
	}
	advance(p)
	expect_punct(p, .lparen, "expected '('")
	obj := parse_expression(p)
	expect_punct(p, .rparen, "expected ')'")
	body := parse_statement_or_decl(p, false)
	return new_stmt(p, With_Stmt{pos = start, obj = obj, body = body})
}

@(private = "file")
parse_labeled :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	label := intern(p.atoms, p.tok.ident)
	label_text := p.tok.ident
	advance(p) // ident
	advance_re(p) // ':'
	body := parse_statement_or_decl(p, false)
	return new_stmt(p, Labeled_Stmt{pos = start, label = label, label_text = label_text, body = body})
}

@(private = "file")
parse_expr_statement :: proc(p: ^Parser) -> ^Stmt {
	start := p.tok.pos
	e := parse_expression(p)
	consume_semicolon(p)
	return new_stmt(p, Expr_Stmt{pos = start, expr = e})
}

// --- lookahead predicates -----------------------------------------------------------------------------------

// lexical_decl_follows decides whether `let` begins a lexical declaration (vs. an identifier named "let"). `let`
// is a declaration when followed by an identifier, `[`, or `{`. QuickJS does the same one-token lookahead.
@(private = "file")
lexical_decl_follows :: proc(p: ^Parser) -> bool {
	save := save_point(p)
	advance(p)
	ok := (p.tok.kind == .ident && p.tok.keyword == JS_ATOM_NULL) ||
		is_punct(p, .lbracket) || is_punct(p, .lbrace) ||
		(p.tok.kind == .ident && (p.tok.ident == "let" || p.tok.ident == "yield" || p.tok.ident == "await"))
	restore_point(p, save)
	return ok
}

@(private = "file")
using_decl_follows :: proc(p: ^Parser) -> bool {
	// `using x` is a declaration when the next token is an identifier on the same line and not `of`/`in`.
	save := save_point(p)
	advance(p)
	ok := p.tok.kind == .ident && !p.tok.nl_before && p.tok.keyword == JS_ATOM_NULL && p.tok.ident != "of"
	restore_point(p, save)
	return ok
}

@(private = "file")
async_function_follows :: proc(p: ^Parser) -> bool {
	save := save_point(p)
	advance(p)
	ok := is_kw(p, "function") && !p.tok.nl_before
	restore_point(p, save)
	return ok
}

@(private = "file")
labeled_follows :: proc(p: ^Parser) -> bool {
	if p.tok.keyword != JS_ATOM_NULL {
		return false
	}
	save := save_point(p)
	advance(p)
	ok := is_punct(p, .colon)
	restore_point(p, save)
	return ok
}

@(private = "file")
import_is_expression :: proc(p: ^Parser) -> bool {
	// `import(` (dynamic) or `import.meta` are expressions, not declarations.
	save := save_point(p)
	advance(p)
	ok := is_punct(p, .lparen) || is_punct(p, .dot)
	restore_point(p, save)
	return ok
}

// A save/restore point for bounded lookahead. Because the lexer is a forward scanner, we snapshot its cursor and
// the current token; restore rewinds both. This is cheap (a few fields) and used only for one-token lookahead.
Save_Point :: struct {
	lex_pos:    int,
	lex_line:   u32,
	lex_col:    u32,
	lex_ls:     int,
	tok:        Token,
	prev_end:   Source_Pos,
	had_error:  bool,
}

save_point :: proc(p: ^Parser) -> Save_Point {
	return Save_Point{
		lex_pos = p.lex.pos, lex_line = p.lex.line, lex_col = p.lex.col, lex_ls = p.lex.line_start,
		tok = p.tok, prev_end = p.prev_end, had_error = p.had_error,
	}
}

restore_point :: proc(p: ^Parser, s: Save_Point) {
	p.lex.pos = s.lex_pos
	p.lex.line = s.lex_line
	p.lex.col = s.lex_col
	p.lex.line_start = s.lex_ls
	p.tok = s.tok
	p.prev_end = s.prev_end
	p.had_error = s.had_error
	p.lex.had_error = false
}
