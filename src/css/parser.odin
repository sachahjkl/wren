package css

import "base:runtime"
import "core:mem/virtual"
import "core:strings"

Arena_Alloc :: runtime.Allocator

Value_Kind :: enum u8 { Token, Function, Block }

// A component value: a preserved token, a function with its arguments, or a ( ) / [ ] / { } block with its contents.
Value :: struct {
	kind:     Value_Kind,
	tok:      Token,      // Token: the token; Function: tok.text is the name; Block: tok.kind is the opening token
	children: []Value,
}

Declaration :: struct {
	name:      string,    // lower case, except custom properties (--x), which keep their case
	value:     []Value,
	important: bool,
}

Rule_Kind :: enum u8 { Style, Media, Supports, Import, Font_Face, Keyframes, Layer_Block, Layer_Statement, Namespace, Page, Container, Unknown }

Rule :: struct {
	kind:         Rule_Kind,
	// Style: selectors + declarations + nested rules (CSS Nesting)
	selectors:    Selector_List,
	declarations: []Declaration,
	nested:       []^Rule,
	// Media / Supports / Container / Layer_Block: the rules inside
	rules:        []^Rule,
	media:        Media_Query_List,
	supports:     []Value,      // Supports: the condition, evaluated by the style system (it knows the property table)
	layer:        string,       // Layer_Block: the layer name ("" = anonymous); Import: layer(...) argument
	layer_names:  []string,     // Layer_Statement: @layer a, b;
	// Import
	url:          string,
	// Keyframes: name and keyframe blocks; Font_Face / Page: the declarations above
	name:         string,
	keyframes:    []Keyframe,
	prelude:      []Value,      // anything not understood, kept raw
}

Keyframe :: struct {
	offsets:      []f32,        // 0..1 (from = 0, to = 1)
	declarations: []Declaration,
}

Stylesheet :: struct {
	arena:  virtual.Arena,
	alloc:  Arena_Alloc,
	source: string,
	rules:  []^Rule,
	errors: [dynamic]string,   // parse problems, for the console
}

// Limits for hostile input. The style system fills them from preferences (`style.*`).
Parse_Options :: struct {
	max_nesting_depth: int,   // blocks and functions inside one another
	max_rules:         int,   // rules (nested ones included) in one sheet
}

stylesheet_destroy :: proc(s: ^Stylesheet) {
	virtual.arena_destroy(&s.arena)
	s^ = {}
}

@(private)
Parser :: struct {
	toks:  []Token,
	pos:   int,
	a:     Arena_Alloc,
	opt:   Parse_Options,
	rules: int,
	errors: ^[dynamic]string,
}

@(private)
perr :: proc(p: ^Parser, msg: string) {
	if len(p.errors^) < 100 { append(p.errors, strings.clone(msg)) }
}

// Parses `source` as a stylesheet (CSS Syntax §5, "parse a stylesheet").
parse_stylesheet :: proc(source: string, opt: Parse_Options) -> ^Stylesheet {
	s := new(Stylesheet)
	_ = virtual.arena_init_growing(&s.arena)
	s.alloc = virtual.arena_allocator(&s.arena)
	s.source = strings.clone(source, s.alloc)
	s.errors = make([dynamic]string)
	toks := tokenize(s.source, s.alloc)
	p := Parser{toks = toks, a = s.alloc, opt = opt, errors = &s.errors}
	s.rules = parse_rule_list(&p, true)
	return s
}

////////////////////////////////
// Component values

@(private)
closing_for :: proc(k: Token_Kind) -> Token_Kind {
	#partial switch k {
	case .Open_Paren: return .Close_Paren
	case .Open_Square: return .Close_Square
	case .Open_Curly: return .Close_Curly
	}
	return .EOF
}

// Consumes component values until `stop` (not consumed) or the end. depth guards nesting.
@(private)
parse_values :: proc(p: ^Parser, stop: Token_Kind, depth: int) -> []Value {
	out := make([dynamic]Value, p.a)
	for p.pos < len(p.toks) {
		t := p.toks[p.pos]
		if t.kind == stop && stop != .EOF { break }
		p.pos += 1
		#partial switch t.kind {
		case .Open_Paren, .Open_Square, .Open_Curly:
			v := Value{kind = .Block, tok = t}
			if depth >= p.opt.max_nesting_depth {
				perr(p, "nesting too deep: block skipped")
				skip_block(p, closing_for(t.kind))
			} else {
				v.children = parse_values(p, closing_for(t.kind), depth + 1)
				if p.pos < len(p.toks) && p.toks[p.pos].kind == closing_for(t.kind) { p.pos += 1 }
			}
			append(&out, v)
		case .Function:
			v := Value{kind = .Function, tok = t}
			if depth >= p.opt.max_nesting_depth {
				perr(p, "nesting too deep: function skipped")
				skip_block(p, .Close_Paren)
			} else {
				v.children = parse_values(p, .Close_Paren, depth + 1)
				if p.pos < len(p.toks) && p.toks[p.pos].kind == .Close_Paren { p.pos += 1 }
			}
			append(&out, v)
		case:
			append(&out, Value{kind = .Token, tok = t})
		}
	}
	return out[:]
}

// Skips to the matching close of an already-opened block without building it.
@(private)
skip_block :: proc(p: ^Parser, close: Token_Kind) {
	depth := 1
	for p.pos < len(p.toks) && depth > 0 {
		#partial switch p.toks[p.pos].kind {
		case .Open_Paren, .Open_Square, .Open_Curly, .Function: depth += 1
		case .Close_Paren, .Close_Square, .Close_Curly: depth -= 1
		}
		p.pos += 1
	}
}

////////////////////////////////
// Rules

is_ws_value :: proc(v: Value) -> bool { return v.kind == .Token && v.tok.kind == .Whitespace }

trim_values :: proc(v: []Value) -> []Value {
	s, e := 0, len(v)
	for s < e && is_ws_value(v[s]) { s += 1 }
	for e > s && is_ws_value(v[e - 1]) { e -= 1 }
	return v[s:e]
}

@(private)
parse_rule_list :: proc(p: ^Parser, top_level: bool) -> []^Rule {
	rules := make([dynamic]^Rule, p.a)
	for p.pos < len(p.toks) {
		t := p.toks[p.pos]
		#partial switch t.kind {
		case .Whitespace: p.pos += 1; continue
		case .CDO, .CDC:
			if top_level { p.pos += 1; continue }
		case .Close_Curly:
			if !top_level { return rules[:] }
		}
		if p.rules >= p.opt.max_rules { perr(p, "too many rules: the rest of the sheet is ignored"); p.pos = len(p.toks); break }
		if t.kind == .At_Keyword {
			p.pos += 1
			if r := parse_at_rule(p, t.text); r != nil { append(&rules, r) }
		} else if r := parse_qualified_rule(p, nil); r != nil {
			append(&rules, r)
		}
	}
	return rules[:]
}

// A qualified rule: prelude, then a { } block. With `parent`, selectors may use & (CSS Nesting).
@(private)
parse_qualified_rule :: proc(p: ^Parser, parent: ^Rule) -> ^Rule {
	start := p.pos
	prelude := make([dynamic]Value, p.a)
	for p.pos < len(p.toks) {
		t := p.toks[p.pos]
		if t.kind == .Open_Curly {
			p.pos += 1
			body := parse_values(p, .Close_Curly, 1)
			if p.pos < len(p.toks) && p.toks[p.pos].kind == .Close_Curly { p.pos += 1 }
			return finish_style_rule(p, prelude[:], body, parent)
		}
		if t.kind == .Close_Curly && parent != nil { break }   // a stray } inside a nested block ends it
		// build values for the prelude (functions and blocks nest)
		vs := parse_one_value(p)
		append(&prelude, vs)
	}
	// EOF before a block: a parse error, the rule is dropped
	_ = start
	return nil
}

// One component value starting at p.pos.
@(private)
parse_one_value :: proc(p: ^Parser) -> Value {
	t := p.toks[p.pos]
	p.pos += 1
	#partial switch t.kind {
	case .Open_Paren, .Open_Square:
		v := Value{kind = .Block, tok = t}
		v.children = parse_values(p, closing_for(t.kind), 1)
		if p.pos < len(p.toks) && p.toks[p.pos].kind == closing_for(t.kind) { p.pos += 1 }
		return v
	case .Function:
		v := Value{kind = .Function, tok = t}
		v.children = parse_values(p, .Close_Paren, 1)
		if p.pos < len(p.toks) && p.toks[p.pos].kind == .Close_Paren { p.pos += 1 }
		return v
	}
	return Value{kind = .Token, tok = t}
}

@(private)
finish_style_rule :: proc(p: ^Parser, prelude, body: []Value, parent: ^Rule) -> ^Rule {
	p.rules += 1
	r := new(Rule, p.a)
	r.kind = .Style
	sel, ok := parse_selector_list(trim_values(prelude), p.a, parent != nil ? &parent.selectors : nil)
	if !ok {
		perr(p, "invalid selector: rule dropped")
		return nil
	}
	r.selectors = sel
	decls, nested := parse_block_contents(p, body, r)
	r.declarations = decls
	r.nested = nested
	return r
}

// Splits a { } block into declarations and nested rules (CSS Nesting).
@(private)
parse_block_contents :: proc(p: ^Parser, body: []Value, owner: ^Rule) -> ([]Declaration, []^Rule) {
	decls := make([dynamic]Declaration, p.a)
	nested := make([dynamic]^Rule, p.a)
	i := 0
	for i < len(body) {
		// one item: values up to ';' or through a { } block
		start := i
		end := i
		has_block := false
		for end < len(body) {
			v := body[end]
			if v.kind == .Token && v.tok.kind == .Semicolon { break }
			end += 1
			if v.kind == .Block && v.tok.kind == .Open_Curly { has_block = true; break }
		}
		item := trim_values(body[start:end])
		i = end
		if i < len(body) && body[i].kind == .Token && body[i].tok.kind == .Semicolon { i += 1 }
		if len(item) == 0 { continue }

		if has_block {
			// a nested rule: re-parse the item through a sub-parser over its tokens
			if r := parse_nested_item(p, item, owner); r != nil { append(&nested, r) }
			continue
		}
		if d, ok := parse_declaration(p, item); ok { append(&decls, d) }
	}
	return decls[:], nested[:]
}

@(private)
parse_nested_item :: proc(p: ^Parser, item: []Value, owner: ^Rule) -> ^Rule {
	if len(item) == 0 { return nil }
	// the block is the last value; everything before is the prelude
	blk := item[len(item) - 1]
	prelude := trim_values(item[:len(item) - 1])
	if p.rules >= p.opt.max_rules { return nil }
	if item[0].kind == .Token && item[0].tok.kind == .At_Keyword {
		return build_at_rule(p, item[0].tok.text, prelude[1:], blk, owner)
	}
	return finish_style_rule(p, prelude, blk.children, owner)
}

@(private)
parse_declaration :: proc(p: ^Parser, item: []Value) -> (d: Declaration, ok: bool) {
	if len(item) < 2 || item[0].kind != .Token || item[0].tok.kind != .Ident { return {}, false }
	i := 1
	for i < len(item) && is_ws_value(item[i]) { i += 1 }
	if i >= len(item) || item[i].kind != .Token || item[i].tok.kind != .Colon { return {}, false }
	i += 1
	val := trim_values(item[i:])
	name := item[0].tok.text
	if !strings.has_prefix(name, "--") { name = strings.to_lower(name, p.a) }
	// !important: the last two non-whitespace values
	n := len(val)
	if n >= 2 {
		j := n - 1
		if val[j].kind == .Token && val[j].tok.kind == .Ident && strings.equal_fold(val[j].tok.text, "important") {
			k := j - 1
			for k >= 0 && is_ws_value(val[k]) { k -= 1 }
			if k >= 0 && val[k].kind == .Token && val[k].tok.kind == .Delim && val[k].tok.text == "!" {
				d.important = true
				val = trim_values(val[:k])
			}
		}
	}
	d.name = name
	d.value = val
	// an empty value is valid only for custom properties
	if len(val) == 0 && !strings.has_prefix(name, "--") { return {}, false }
	return d, true
}

// Component values of a piece of text (a substituted var(), a <style> attribute fragment).
parse_component_values :: proc(source: string, opt: Parse_Options, allocator: Arena_Alloc) -> []Value {
	errs := make([dynamic]string, context.temp_allocator)
	toks := tokenize(source, allocator)
	p := Parser{toks = toks, a = allocator, opt = opt, errors = &errs}
	return parse_values(&p, .EOF, 0)
}

// Declarations from a style attribute or any bare declaration list.
parse_declarations :: proc(source: string, opt: Parse_Options, allocator: Arena_Alloc) -> []Declaration {
	var_errors := make([dynamic]string, context.temp_allocator)
	toks := tokenize(source, allocator)
	p := Parser{toks = toks, a = allocator, opt = opt, errors = &var_errors}
	body := parse_values(&p, .EOF, 0)
	decls, _ := parse_block_contents(&p, body, nil)
	return decls
}

////////////////////////////////
// At-rules

@(private)
parse_at_rule :: proc(p: ^Parser, name: string) -> ^Rule {
	// prelude up to ';' (statement) or a { } block
	prelude := make([dynamic]Value, p.a)
	for p.pos < len(p.toks) {
		t := p.toks[p.pos]
		if t.kind == .Semicolon { p.pos += 1; return build_at_rule(p, name, trim_values(prelude[:]), Value{}, nil) }
		if t.kind == .Open_Curly {
			p.pos += 1
			blk := Value{kind = .Block, tok = t}
			blk.children = parse_values(p, .Close_Curly, 1)
			if p.pos < len(p.toks) && p.toks[p.pos].kind == .Close_Curly { p.pos += 1 }
			return build_at_rule(p, name, trim_values(prelude[:]), blk, nil)
		}
		if t.kind == .Close_Curly { break }
		append(&prelude, parse_one_value(p))
	}
	// EOF ends the rule
	return build_at_rule(p, name, trim_values(prelude[:]), Value{}, nil)
}

@(private)
parse_rules_in_block :: proc(p: ^Parser, blk: Value) -> []^Rule {
	sub := Parser{toks = flatten(blk.children, p.a), a = p.a, opt = p.opt, errors = p.errors, rules = p.rules}
	rules := parse_rule_list(&sub, false)
	p.rules = sub.rules
	return rules
}

// Re-flattens component values to tokens (so nested blocks can be parsed by the rule-list parser).
@(private)
flatten :: proc(vs: []Value, a: Arena_Alloc) -> []Token {
	out := make([dynamic]Token, a)
	flatten_into(&out, vs)
	return out[:]
}

@(private)
flatten_into :: proc(out: ^[dynamic]Token, vs: []Value) {
	// iterative with an explicit stack of (values, index, closing token)
	Frame :: struct { vs: []Value, i: int, close: Token_Kind }
	stack := make([dynamic]Frame, context.temp_allocator)
	append(&stack, Frame{vs, 0, .EOF})
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		if f.i >= len(f.vs) {
			if f.close != .EOF { append(out, Token{kind = f.close}) }
			pop(&stack)
			continue
		}
		v := f.vs[f.i]
		f.i += 1
		switch v.kind {
		case .Token: append(out, v.tok)
		case .Function:
			append(out, v.tok)
			append(&stack, Frame{v.children, 0, .Close_Paren})
		case .Block:
			append(out, Token{kind = v.tok.kind})
			append(&stack, Frame{v.children, 0, closing_for(v.tok.kind)})
		}
	}
}

@(private)
build_at_rule :: proc(p: ^Parser, name: string, prelude: []Value, blk: Value, parent: ^Rule) -> ^Rule {
	p.rules += 1
	r := new(Rule, p.a)
	lname := strings.to_lower(name, p.a)
	r.name = lname
	has_block := blk.kind == .Block
	switch lname {
	case "media":
		if !has_block { return nil }
		r.kind = .Media
		r.media = parse_media_query_list(prelude, p.a)
		r.rules = parse_rules_in_block_or_nested(p, blk, parent)
	case "supports":
		if !has_block { return nil }
		r.kind = .Supports
		r.supports = prelude
		r.rules = parse_rules_in_block_or_nested(p, blk, parent)
	case "container":
		if !has_block { return nil }
		r.kind = .Container
		r.prelude = prelude
		r.rules = parse_rules_in_block_or_nested(p, blk, parent)
	case "import":
		r.kind = .Import
		url := ""
		for v, i in prelude {
			if v.kind == .Token && (v.tok.kind == .String || v.tok.kind == .Url) { url = v.tok.text; r.prelude = prelude[i + 1:]; break }
			if v.kind == .Function && strings.equal_fold(v.tok.text, "url") && len(v.children) > 0 { url = v.children[0].tok.text; r.prelude = prelude[i + 1:]; break }
		}
		if url == "" { return nil }
		r.url = url
		// the rest of the prelude: layer(...), supports(...), media queries
		rest := trim_values(r.prelude)
		layer_idx := -1
		for v, i in rest {
			if v.kind == .Function && strings.equal_fold(v.tok.text, "layer") { r.layer = layer_name_of(v.children, p.a); layer_idx = i }
			if v.kind == .Token && v.tok.kind == .Ident && strings.equal_fold(v.tok.text, "layer") { r.layer = ""; layer_idx = i }
		}
		media_vals := rest
		if layer_idx >= 0 { media_vals = trim_values(rest[layer_idx + 1:]) }
		for v, i in media_vals { if v.kind == .Function && strings.equal_fold(v.tok.text, "supports") { r.supports = v.children; media_vals = trim_values(media_vals[i + 1:]); break } }
		r.media = parse_media_query_list(media_vals, p.a)
		if layer_idx >= 0 && r.layer == "" { r.layer = "\x00anonymous" }
	case "layer":
		if has_block {
			r.kind = .Layer_Block
			r.layer = layer_name_of(prelude, p.a)
			r.rules = parse_rules_in_block_or_nested(p, blk, parent)
		} else {
			r.kind = .Layer_Statement
			names := make([dynamic]string, p.a)
			cur := strings.builder_make(p.a)
			flush :: proc(names: ^[dynamic]string, cur: ^strings.Builder, a: Arena_Alloc) {
				if strings.builder_len(cur^) > 0 { append(names, strings.clone(strings.to_string(cur^), a)); strings.builder_reset(cur) }
			}
			for v in prelude {
				if v.kind == .Token && v.tok.kind == .Comma { flush(&names, &cur, p.a); continue }
				if v.kind == .Token && v.tok.kind == .Ident { strings.write_string(&cur, v.tok.text) }
				if v.kind == .Token && v.tok.kind == .Delim && v.tok.text == "." { strings.write_byte(&cur, '.') }
			}
			flush(&names, &cur, p.a)
			r.layer_names = names[:]
		}
	case "font-face":
		if !has_block { return nil }
		r.kind = .Font_Face
		r.declarations, _ = parse_block_contents(p, blk.children, r)
	case "page":
		if !has_block { return nil }
		r.kind = .Page
		r.prelude = prelude
		r.declarations, _ = parse_block_contents(p, blk.children, r)
	case "keyframes", "-webkit-keyframes":
		if !has_block { return nil }
		r.kind = .Keyframes
		if len(prelude) > 0 && prelude[0].kind == .Token { r.name = prelude[0].tok.text }
		r.keyframes = parse_keyframes(p, blk.children)
	case "namespace":
		r.kind = .Namespace
		r.prelude = prelude
	case "charset":
		return nil   // meaningful only to the byte-level decoder
	case:
		perr(p, strings.concatenate({"unknown at-rule @", lname}, context.temp_allocator))
		return nil
	}
	return r
}

@(private)
parse_rules_in_block_or_nested :: proc(p: ^Parser, blk: Value, parent: ^Rule) -> []^Rule {
	if parent == nil { return parse_rules_in_block(p, blk) }
	// inside a style rule: a conditional group holds declarations (applied to the parent's selector) and nested rules
	decls, nested := parse_block_contents(p, blk.children, parent)
	rules := make([dynamic]^Rule, p.a)
	if len(decls) > 0 {
		inner := new(Rule, p.a)
		inner.kind = .Style
		inner.selectors = parent.selectors
		inner.declarations = decls
		append(&rules, inner)
	}
	for n in nested { append(&rules, n) }
	return rules[:]
}

@(private)
layer_name_of :: proc(vs: []Value, a: Arena_Alloc) -> string {
	sb := strings.builder_make(a)
	for v in vs {
		if v.kind == .Token && v.tok.kind == .Ident { strings.write_string(&sb, v.tok.text) }
		if v.kind == .Token && v.tok.kind == .Delim && v.tok.text == "." { strings.write_byte(&sb, '.') }
	}
	return strings.to_string(sb)
}

@(private)
parse_keyframes :: proc(p: ^Parser, body: []Value) -> []Keyframe {
	out := make([dynamic]Keyframe, p.a)
	i := 0
	for i < len(body) {
		start := i
		for i < len(body) && !(body[i].kind == .Block && body[i].tok.kind == .Open_Curly) { i += 1 }
		if i >= len(body) { break }
		sel := trim_values(body[start:i])
		blk := body[i]
		i += 1
		offs := make([dynamic]f32, p.a)
		valid := true
		for v in sel {
			switch {
			case v.kind == .Token && v.tok.kind == .Comma:
			case v.kind == .Token && v.tok.kind == .Whitespace:
			case v.kind == .Token && v.tok.kind == .Ident && strings.equal_fold(v.tok.text, "from"): append(&offs, 0)
			case v.kind == .Token && v.tok.kind == .Ident && strings.equal_fold(v.tok.text, "to"): append(&offs, 1)
			case v.kind == .Token && v.tok.kind == .Percentage && v.tok.num >= 0 && v.tok.num <= 100: append(&offs, f32(v.tok.num / 100))
			case: valid = false
			}
		}
		if !valid || len(offs) == 0 { continue }
		decls, _ := parse_block_contents(p, blk.children, nil)
		append(&out, Keyframe{offs[:], decls})
	}
	return out[:]
}
