package regexp

// Character class parser: [ ... ]. Handles single characters, ranges (a-z), the class escapes (\d \w \s and
// negations, \p{} in u/v mode), escaped characters, a leading ^ negation, and -- for the `v` flag's nested set
// difference / intersection (&&). In Annex B (no u/v), a `-` in a position where it cannot form a range is a
// literal, and class escapes inside ranges degrade gracefully as browsers do.

import "core:unicode/utf8"
import uni "wb:engine/unicode"

@(private)
parse_class :: proc(p: ^Parser) -> ^Node {
	p.pos += 1 // '['
	spec := parse_class_body(p)
	if p.err != "" { return nil }
	n := new_node(p, .Class)
	n.class = spec
	return n
}

@(private)
parse_class_body :: proc(p: ^Parser) -> ^Class_Spec {
	spec := new(Class_Spec, p.allocator)
	if p_eat(p, '^') { spec.negated = true }

	for !p_eof(p) && p_peek_byte(p) != ']' {
		// `v`-flag set operators between class elements.
		if .Unicode_Sets in p.flags {
			if p.pos + 1 < len(p.src) && p.src[p.pos] == '&' && p.src[p.pos + 1] == '&' {
				p.pos += 2
				right := parse_class_body_until_op(p)
				if p.err != "" { return nil }
				spec.op = .Intersection
				append(&spec.operands, right)
				break
			}
			if p.pos + 1 < len(p.src) && p.src[p.pos] == '-' && p.src[p.pos + 1] == '-' {
				p.pos += 2
				right := parse_class_body_until_op(p)
				if p.err != "" { return nil }
				spec.op = .Subtraction
				append(&spec.operands, right)
				break
			}
		}
		parse_class_atom_into(p, spec)
		if p.err != "" { return nil }
	}
	if !p_eat(p, ']') { p_fail(p, "unterminated character class"); return nil }
	return spec
}

// For the v-flag nested operand, parse a sub-class body that stops at the next operator or the closing ].
@(private)
parse_class_body_until_op :: proc(p: ^Parser) -> ^Class_Spec {
	sub := new(Class_Spec, p.allocator)
	for !p_eof(p) && p_peek_byte(p) != ']' {
		if p.pos + 1 < len(p.src) &&
		   ((p.src[p.pos] == '&' && p.src[p.pos + 1] == '&') ||
		    (p.src[p.pos] == '-' && p.src[p.pos + 1] == '-')) {
			break
		}
		parse_class_atom_into(p, sub)
		if p.err != "" { return nil }
	}
	return sub
}

// Parse one class element (char, range, or class escape) and append it to `spec`.
@(private)
parse_class_atom_into :: proc(p: ^Parser, spec: ^Class_Spec) {
	lo, lo_is_set := parse_class_single(p, spec)
	if p.err != "" { return }
	if lo_is_set {
		// A class escape like \d was already appended; it cannot be a range endpoint.
		return
	}
	// Possible range: lo '-' hi, but not if '-' is the last char before ']'.
	if p_peek_byte(p) == '-' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] != ']' {
		// Peek: a '-' followed by a class escape is not a range in unicode mode (error) / literal in Annex B.
		save := p.pos
		p.pos += 1 // consume '-'
		hi, hi_is_set := parse_class_single(p, spec)
		if p.err != "" { return }
		if hi_is_set {
			// `a-\d`: not a valid range. Unicode mode: error. Annex B: treat '-' and the escape literally.
			if unicode_mode(p.flags) { p_fail(p, "invalid class range"); return }
			append_char(spec, lo)
			append_char(spec, '-')
			// the set escape was already appended by parse_class_single
			return
		}
		if hi < lo {
			if unicode_mode(p.flags) { p_fail(p, "range out of order in character class"); return }
			// Annex B: treat as three literals.
			append_char(spec, lo)
			append_char(spec, '-')
			append_char(spec, hi)
			p.pos = p.pos // keep
			return
		}
		append_range(spec, lo, hi)
		return
	}
	append_char(spec, lo)
}

// Parse a single class member. Returns (rune, is_set): is_set=true means a class escape (\d, \p, ...) was already
// appended to `spec` and no rune is produced.
@(private)
parse_class_single :: proc(p: ^Parser, spec: ^Class_Spec) -> (rune, bool) {
	b := p_peek_byte(p)
	if b == '\\' {
		p.pos += 1
		if p_eof(p) { p_fail(p, "trailing backslash in class"); return 0, false }
		e := p_peek_byte(p)
		switch e {
		case 'd', 'D', 'w', 'W', 's', 'S':
			p.pos += 1
			append_class_escape(spec, e)
			return 0, true
		case 'p', 'P':
			if unicode_mode(p.flags) {
				p.pos += 1
				append_prop(p, spec, e == 'P')
				return 0, true
			}
			p.pos += 1
			return e == 'p' ? 'p' : 'P', false
		}
		r, ok := parse_char_escape(p, true)
		if !ok { return 0, false }
		return r, false
	}
	r := p_next(p)
	return r, false
}

@(private)
append_char :: proc(spec: ^Class_Spec, r: rune) {
	append(&spec.items, Class_Item{kind = .Char, lo = r, hi = r})
}

@(private)
append_range :: proc(spec: ^Class_Spec, lo, hi: rune) {
	append(&spec.items, Class_Item{kind = .Range, lo = lo, hi = hi})
}

@(private)
append_class_escape :: proc(spec: ^Class_Spec, e: u8) {
	item: Class_Item
	switch e {
	case 'd': item.kind = .Digit
	case 'D': item.kind = .Not_Digit
	case 'w': item.kind = .Word
	case 'W': item.kind = .Not_Word
	case 's': item.kind = .Space
	case 'S': item.kind = .Not_Space
	}
	append(&spec.items, item)
}

@(private)
append_prop :: proc(p: ^Parser, spec: ^Class_Spec, negated: bool) {
	if !p_eat(p, '{') { p_fail(p, "\\p must be followed by {"); return }
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '}' { p.pos += 1 }
	if p.pos >= len(p.src) { p_fail(p, "unterminated \\p{} in class"); return }
	body := p.src[start:p.pos]
	p.pos += 1
	name, value := split_prop(body)
	append(&spec.items, Class_Item{
		kind = negated ? .Not_Prop : .Prop,
		prop_name = name,
		prop_value = value,
	})
}

_ :: uni
_ :: utf8
