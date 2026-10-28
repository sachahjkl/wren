package regexp

// Recursive-descent grammar for ECMAScript patterns. Entry point is parse_pattern; it returns the AST root or
// nil with p.err set. The structure follows the Annex 22.2.1 productions: Disjunction -> Alternative -> Term.

import "core:strings"
import "core:unicode/utf8"
import uni "wb:engine/unicode"

@(private)
parse_pattern :: proc(p: ^Parser) -> ^Node {
	prescan_groups(p)
	// Reset the running capture counter used while building nodes; the prescan already filled names/indices.
	saved_total := p.capture_count
	p.capture_count = 0
	root := parse_disjunction(p)
	if p.err != "" { return nil }
	if !p_eof(p) {
		// A stray ) or an otherwise unconsumed tail.
		return p_fail(p, "unexpected character")
	}
	p.capture_count = saved_total
	return root
}

@(private)
parse_disjunction :: proc(p: ^Parser) -> ^Node {
	first := parse_alternative(p)
	if p.err != "" { return nil }
	if p_peek_byte(p) != '|' {
		return first
	}
	alt := new_node(p, .Alt)
	append(&alt.children, first)
	for p_eat(p, '|') {
		n := parse_alternative(p)
		if p.err != "" { return nil }
		append(&alt.children, n)
	}
	return alt
}

@(private)
parse_alternative :: proc(p: ^Parser) -> ^Node {
	seq := new_node(p, .Concat)
	for !p_eof(p) {
		b := p_peek_byte(p)
		if b == '|' || b == ')' { break }
		t := parse_term(p)
		if p.err != "" { return nil }
		if t != nil { append(&seq.children, t) }
	}
	if len(seq.children) == 0 {
		return new_node(p, .Empty)
	}
	if len(seq.children) == 1 {
		return seq.children[0]
	}
	return seq
}

@(private)
parse_term :: proc(p: ^Parser) -> ^Node {
	b := p_peek_byte(p)
	// Assertions that take no quantifier.
	switch b {
	case '^':
		p.pos += 1
		return new_node(p, .Assert_Start)
	case '$':
		p.pos += 1
		return new_node(p, .Assert_End)
	}
	atom := parse_atom(p)
	if p.err != "" { return nil }
	if atom == nil { return nil }

	// A lookaround is an assertion: in u/v mode it cannot be quantified, in Annex B lookahead can. Keep it
	// simple and spec-correct for the common path: allow a quantifier only on quantifiable atoms.
	if atom.kind == .Lookbehind {
		return atom // never quantifiable
	}
	return maybe_quantifier(p, atom)
}

@(private)
maybe_quantifier :: proc(p: ^Parser, atom: ^Node) -> ^Node {
	b := p_peek_byte(p)
	min, max: int
	has := false
	switch b {
	case '*': p.pos += 1; min = 0; max = -1; has = true
	case '+': p.pos += 1; min = 1; max = -1; has = true
	case '?': p.pos += 1; min = 0; max = 1;  has = true
	case '{':
		if m0, m1, ok := parse_brace_quantifier(p); ok {
			min = m0; max = m1; has = true
		}
	}
	if !has { return atom }
	// Lookahead assertions are not quantifiable in u mode; in Annex B they are (rare). We follow the lenient
	// rule for non-unicode and reject for unicode.
	if atom.kind == .Lookahead && unicode_mode(p.flags) {
		p_fail(p, "quantifier on lookahead assertion")
		return nil
	}
	if atom.kind == .Assert_Start || atom.kind == .Assert_End ||
	   atom.kind == .Word_Boundary || atom.kind == .Not_Word_Boundary {
		if unicode_mode(p.flags) {
			p_fail(p, "nothing to repeat")
			return nil
		}
		return atom
	}
	q := new_node(p, .Quant)
	q.min = min
	q.max = max
	q.greedy = !p_eat(p, '?')
	append(&q.children, atom)
	return q
}

// Parse "{n}", "{n,}", "{n,m}". On a malformed brace in Annex B mode, rewinds and returns ok=false so `{` is a
// literal. In unicode mode a lone `{` is a syntax error (handled by parse_atom rejecting it).
@(private)
parse_brace_quantifier :: proc(p: ^Parser) -> (min: int, max: int, ok: bool) {
	start := p.pos
	p.pos += 1 // consume '{'
	n0, ok0 := parse_decimal(p)
	if !ok0 { p.pos = start; return 0, 0, false }
	min = n0
	max = n0
	if p_eat(p, ',') {
		if p_peek_byte(p) == '}' {
			max = -1
		} else {
			n1, ok1 := parse_decimal(p)
			if !ok1 { p.pos = start; return 0, 0, false }
			max = n1
		}
	}
	if !p_eat(p, '}') { p.pos = start; return 0, 0, false }
	if max != -1 && max < min {
		p_fail(p, "numbers out of order in {} quantifier")
		return 0, 0, false
	}
	return min, max, true
}

@(private)
parse_decimal :: proc(p: ^Parser) -> (int, bool) {
	start := p.pos
	v := 0
	for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		v = v * 10 + int(p.src[p.pos] - '0')
		p.pos += 1
		if v > 1 << 30 { v = 1 << 30 } // clamp to avoid overflow; spec allows large but we cap
	}
	return v, p.pos > start
}

@(private)
parse_atom :: proc(p: ^Parser) -> ^Node {
	b := p_peek_byte(p)
	switch b {
	case '(':
		return parse_group(p)
	case '[':
		return parse_class(p)
	case '.':
		p.pos += 1
		return new_node(p, .Any)
	case '\\':
		return parse_atom_escape(p)
	case '*', '+', '?':
		return p_fail(p, "nothing to repeat")
	case '{':
		// In unicode mode a lone { is an error; in Annex B it is a literal.
		if unicode_mode(p.flags) {
			// Only an error if not a valid quantifier (but a quantifier here has no atom).
			return p_fail(p, "lone quantifier brace")
		}
		p.pos += 1
		n := new_node(p, .Char)
		n.ch = '{'
		return n
	case ')':
		return p_fail(p, "unmatched )")
	case ']', '}':
		if unicode_mode(p.flags) {
			return p_fail(p, "lone bracket")
		}
		p.pos += 1
		n := new_node(p, .Char)
		n.ch = rune(b)
		return n
	}
	// A plain character (possibly multibyte).
	r := p_next(p)
	n := new_node(p, .Char)
	n.ch = r
	return n
}

@(private)
parse_group :: proc(p: ^Parser) -> ^Node {
	p.pos += 1 // '('
	if p_eat(p, '?') {
		c := p_peek_byte(p)
		switch c {
		case ':':
			p.pos += 1
			child := parse_disjunction(p)
			if p.err != "" { return nil }
			if !p_eat(p, ')') { return p_fail(p, "unterminated group") }
			g := new_node(p, .Group)
			g.capture_index = 0
			append(&g.children, child)
			return g
		case '=', '!':
			p.pos += 1
			child := parse_disjunction(p)
			if p.err != "" { return nil }
			if !p_eat(p, ')') { return p_fail(p, "unterminated lookahead") }
			la := new_node(p, .Lookahead)
			la.neg = c == '!'
			append(&la.children, child)
			return la
		case '<':
			p.pos += 1
			c2 := p_peek_byte(p)
			if c2 == '=' || c2 == '!' {
				p.pos += 1
				child := parse_disjunction(p)
				if p.err != "" { return nil }
				if !p_eat(p, ')') { return p_fail(p, "unterminated lookbehind") }
				lb := new_node(p, .Lookbehind)
				lb.neg = c2 == '!'
				append(&lb.children, child)
				return lb
			}
			// Named capturing group (?<name> ... )
			name := parse_group_name(p)
			if p.err != "" { return nil }
			p.capture_count += 1
			idx := p.capture_count
			child := parse_disjunction(p)
			if p.err != "" { return nil }
			if !p_eat(p, ')') { return p_fail(p, "unterminated group") }
			g := new_node(p, .Group)
			g.capture_index = idx
			g.group_name = name
			append(&g.children, child)
			return g
		case:
			return p_fail(p, "invalid group")
		}
	}
	// Plain capturing group.
	p.capture_count += 1
	idx := p.capture_count
	child := parse_disjunction(p)
	if p.err != "" { return nil }
	if !p_eat(p, ')') { return p_fail(p, "unterminated group") }
	g := new_node(p, .Group)
	g.capture_index = idx
	append(&g.children, child)
	return g
}

@(private)
parse_group_name :: proc(p: ^Parser) -> string {
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '>' {
		p.pos += 1
	}
	if p.pos >= len(p.src) {
		p_fail(p, "unterminated group name")
		return ""
	}
	name := p.src[start:p.pos]
	p.pos += 1 // '>'
	return strings.clone(name, p.allocator)
}

_ :: uni
_ :: utf8
