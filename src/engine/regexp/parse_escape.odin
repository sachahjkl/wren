package regexp

// Escape sequences: the \-atoms (\b \B \d \w \s and their negations, back references, \p{}, \k<name>, numeric and
// control escapes) and the characters valid inside a class. Shared by parse_atom_escape (outside a class) and the
// class parser (inside []), which differ only in which escapes mean what (\b is a word boundary outside, a
// backspace inside).

import "core:strings"
import "core:unicode/utf8"
import uni "wb:engine/unicode"

@(private)
parse_atom_escape :: proc(p: ^Parser) -> ^Node {
	p.pos += 1 // backslash
	if p_eof(p) { return p_fail(p, "trailing backslash") }
	c := p_peek_byte(p)
	switch c {
	case 'b':
		p.pos += 1
		return new_node(p, .Word_Boundary)
	case 'B':
		p.pos += 1
		return new_node(p, .Not_Word_Boundary)
	case 'd', 'D', 'w', 'W', 's', 'S':
		p.pos += 1
		return class_escape_node(p, c)
	case 'p', 'P':
		if unicode_mode(p.flags) {
			p.pos += 1
			return unicode_prop_node(p, c == 'P')
		}
		// Annex B: \p is identity escape 'p'.
		p.pos += 1
		return char_node(p, c == 'p' ? 'p' : 'P')
	case 'k':
		// Named back reference \k<name>.
		if has_named_groups(p) || unicode_mode(p.flags) {
			p.pos += 1
			if !p_eat(p, '<') { return p_fail(p, "invalid named backreference") }
			start := p.pos
			for p.pos < len(p.src) && p.src[p.pos] != '>' { p.pos += 1 }
			if p.pos >= len(p.src) { return p_fail(p, "unterminated name") }
			name := strings.clone(p.src[start:p.pos], p.allocator)
			p.pos += 1
			n := new_node(p, .Back_Ref_Named)
			n.group_name = name
			return n
		}
		// Annex B without named groups: identity escape.
		p.pos += 1
		return char_node(p, 'k')
	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		return parse_back_ref_or_octal(p)
	}
	// A single-character escape, control escape, hex/unicode escape or identity escape.
	r, ok := parse_char_escape(p, false)
	if !ok { return nil }
	return char_node(p, r)
}

@(private)
char_node :: proc(p: ^Parser, r: rune) -> ^Node {
	n := new_node(p, .Char)
	n.ch = r
	return n
}

@(private)
class_escape_node :: proc(p: ^Parser, c: u8) -> ^Node {
	spec := new(Class_Spec, p.allocator)
	item: Class_Item
	switch c {
	case 'd': item.kind = .Digit
	case 'D': item.kind = .Not_Digit
	case 'w': item.kind = .Word
	case 'W': item.kind = .Not_Word
	case 's': item.kind = .Space
	case 'S': item.kind = .Not_Space
	}
	append(&spec.items, item)
	n := new_node(p, .Class)
	n.class = spec
	return n
}

@(private)
unicode_prop_node :: proc(p: ^Parser, negated: bool) -> ^Node {
	if !p_eat(p, '{') { p_fail(p, "\\p must be followed by {"); return nil }
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '}' { p.pos += 1 }
	if p.pos >= len(p.src) { return p_fail(p, "unterminated \\p{}") }
	body := p.src[start:p.pos]
	p.pos += 1
	name, value := split_prop(body)
	spec := new(Class_Spec, p.allocator)
	item := Class_Item{
		kind       = negated ? .Not_Prop : .Prop,
		prop_name  = strings.clone(name, p.allocator),
		prop_value = strings.clone(value, p.allocator),
	}
	append(&spec.items, item)
	n := new_node(p, .Class)
	n.class = spec
	return n
}

@(private)
split_prop :: proc(body: string) -> (name, value: string) {
	if idx := strings.index_byte(body, '='); idx >= 0 {
		return body[:idx], body[idx + 1:]
	}
	return body, ""
}

@(private)
has_named_groups :: proc(p: ^Parser) -> bool {
	return len(p.group_names) > 0
}

// \1 .. \9 and multi-digit: a back reference if the number is a valid group index, otherwise (Annex B only) a
// legacy octal escape or identity. In unicode mode a reference to a non-existent group is a syntax error.
@(private)
parse_back_ref_or_octal :: proc(p: ^Parser) -> ^Node {
	start := p.pos
	v := 0
	for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		v = v * 10 + int(p.src[p.pos] - '0')
		p.pos += 1
	}
	if v <= p.total_captures {
		n := new_node(p, .Back_Ref)
		n.ref_index = v
		return n
	}
	// Not a valid back reference.
	if unicode_mode(p.flags) {
		return p_fail(p, "invalid back reference")
	}
	// Annex B: reinterpret as a legacy octal escape if the leading digits are octal, else identity escape of the
	// first digit. Rewind and parse an octal escape.
	p.pos = start
	r := parse_legacy_octal(p)
	return char_node(p, r)
}

@(private)
parse_legacy_octal :: proc(p: ^Parser) -> rune {
	// Up to three octal digits, value <= 0377.
	v := 0
	n := 0
	for n < 3 && p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '7' {
		nv := v * 8 + int(p.src[p.pos] - '0')
		if nv > 0o377 { break }
		v = nv
		p.pos += 1
		n += 1
	}
	if n == 0 {
		// Not octal: identity escape of the next char.
		return p_next(p)
	}
	return rune(v)
}

// Parse a character escape that yields a single code point: \f \n \r \t \v \0 \cX \xHH \uHHHH \u{...} or an
// identity escape. `in_class` relaxes some rules (\b is backspace). Returns (rune, ok).
@(private)
parse_char_escape :: proc(p: ^Parser, in_class: bool) -> (rune, bool) {
	c := p_peek_byte(p)
	switch c {
	case 'f': p.pos += 1; return '\f', true
	case 'n': p.pos += 1; return '\n', true
	case 'r': p.pos += 1; return '\r', true
	case 't': p.pos += 1; return '\t', true
	case 'v': p.pos += 1; return '\v', true
	case '0':
		// \0 not followed by a digit is NUL; otherwise (Annex B) legacy octal.
		if p.pos + 1 < len(p.src) && p.src[p.pos + 1] >= '0' && p.src[p.pos + 1] <= '9' {
			if unicode_mode(p.flags) { p_fail(p, "invalid escape"); return 0, false }
			return parse_legacy_octal(p), true
		}
		p.pos += 1
		return 0, true
	case 'c':
		// Control escape \cA .. \cZ.
		if p.pos + 1 < len(p.src) {
			ch := p.src[p.pos + 1]
			if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') {
				p.pos += 2
				return rune(ch & 0x1f), true
			}
		}
		if unicode_mode(p.flags) { p_fail(p, "invalid control escape"); return 0, false }
		// Annex B: \c is a literal backslash-c; identity of 'c' won't match browsers exactly but is close.
		p.pos += 1
		return '\\', true
	case 'x':
		p.pos += 1
		return parse_hex_escape(p, 2)
	case 'u':
		p.pos += 1
		return parse_unicode_escape(p)
	case 'b':
		if in_class {
			p.pos += 1
			return '\b', true
		}
		// Outside a class \b is handled before reaching here; identity fallback.
		p.pos += 1
		return 'b', true
	}
	// Identity escape: in unicode mode only syntax chars and '/' are allowed; in Annex B anything goes.
	r := p_next(p)
	if unicode_mode(p.flags) {
		if !is_syntax_char(r) && r != '/' {
			p_fail(p, "invalid identity escape")
			return 0, false
		}
	}
	return r, true
}

@(private)
is_syntax_char :: proc(r: rune) -> bool {
	switch r {
	case '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/':
		return true
	}
	return false
}

@(private)
parse_hex_escape :: proc(p: ^Parser, count: int) -> (rune, bool) {
	v := 0
	for i in 0 ..< count {
		if p.pos >= len(p.src) { p_fail(p, "invalid hex escape"); return 0, false }
		d, ok := hex_digit(p.src[p.pos])
		if !ok {
			if unicode_mode(p.flags) { p_fail(p, "invalid hex escape"); return 0, false }
			// Annex B lenient: treat as literal 'x'. Rewind.
			return 'x', true
		}
		v = v * 16 + d
		p.pos += 1
	}
	return rune(v), true
}

@(private)
parse_unicode_escape :: proc(p: ^Parser) -> (rune, bool) {
	if p_eat(p, '{') {
		if !unicode_mode(p.flags) {
			// Not valid outside u-mode; Annex B treats \u{ as 'u' then '{'. Rewind to before '{'.
			p.pos -= 1
			return 'u', true
		}
		v := 0
		n := 0
		for p.pos < len(p.src) && p.src[p.pos] != '}' {
			d, ok := hex_digit(p.src[p.pos])
			if !ok { p_fail(p, "invalid unicode escape"); return 0, false }
			v = v * 16 + d
			n += 1
			if v > 0x10FFFF { p_fail(p, "unicode escape out of range"); return 0, false }
			p.pos += 1
		}
		if n == 0 || !p_eat(p, '}') { p_fail(p, "invalid unicode escape"); return 0, false }
		return rune(v), true
	}
	// \uHHHH, with surrogate-pair combining in unicode mode.
	hi, ok := parse_hex_escape(p, 4)
	if !ok { return 0, false }
	if unicode_mode(p.flags) && hi >= 0xD800 && hi <= 0xDBFF {
		// Look for a trailing \uDC00..\uDFFF.
		save := p.pos
		if p.pos + 1 < len(p.src) && p.src[p.pos] == '\\' && p.src[p.pos + 1] == 'u' {
			p.pos += 2
			lo, ok2 := parse_hex_escape(p, 4)
			if ok2 && lo >= 0xDC00 && lo <= 0xDFFF {
				return rune(0x10000 + ((u32(hi) - 0xD800) << 10) + (u32(lo) - 0xDC00)), true
			}
			p.pos = save
		}
	}
	return hi, true
}

@(private)
hex_digit :: proc(b: u8) -> (int, bool) {
	switch {
	case b >= '0' && b <= '9': return int(b - '0'), true
	case b >= 'a' && b <= 'f': return int(b - 'a' + 10), true
	case b >= 'A' && b <= 'F': return int(b - 'A' + 10), true
	}
	return 0, false
}

_ :: uni
_ :: utf8
