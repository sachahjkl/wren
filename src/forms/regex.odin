package forms

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The `pattern` attribute (§4.10.5.3.6): an ECMAScript regular expression compiled with the `v` flag and matched against
// the whole value, as if written ^(?:pattern)$.
//
// Matching uses a Pike VM (Thompson NFA simulation): time is linear in the value for a given pattern, so no pattern can
// make the browser hang (catastrophic backtracking does not exist here). The cost of that guarantee is the subset:
//
//   supported   literals, `.`, escapes (\t \n \v \f \r \0 \cX \xHH \uHHHH \u{H..} and surrogate pairs, identity escapes of
//               syntax characters), classes [..] / [^..] with ranges, class escapes \d \D \w \W \s \S, property escapes
//               \p{..} / \P{..} for the general categories L Lu Ll Lt Lm Lo M N Nd Nl No P S Z Zs Cc and their long names,
//               White_Space, Alphabetic, ASCII, Any; v-mode nested classes and the && and -- set operations, \q{..} with
//               single-character strings; groups ( ), (?: ), (?<name> ); alternation; quantifiers * + ? {n} {n,} {n,m}
//               (greedy or lazy: the same for a yes/no answer); assertions ^ $ \b \B.
//   refused     lookaround (?= ?! ?<= ?<!), backreferences \1 \k<name>, multi-character \q{..} strings. A pattern using them
//               is treated like an invalid pattern: ignored (it never causes a mismatch), as the specification says for
//               patterns that fail to compile.
//
// Counted repetitions are expanded; the program size is capped by forms.pattern.max_program.

@(private)
Class_Op :: enum u8 { Union, Intersect, Subtract }

@(private)
Pred :: enum u8 { Digit, Word, Space, Any, Letter, Upper, Lower, Title, Letter_Modifier, Letter_Other, Mark, Number, Decimal, Letter_Number, Other_Number, Punct, Symbol, Separator, Space_Sep, Control, White_Space, Alphabetic, Ascii, Line_Terminator }

@(private)
Class_Item :: struct {
	lo, hi: rune,
	pred:   Pred,
	is_pred: bool,
	neg:    bool,        // \D \W \S \P{}
	nested: ^Class,
}

@(private)
Class :: struct {
	negated: bool,
	op:      Class_Op,
	items:   [dynamic]Class_Item,
}

@(private)
Node_Kind :: enum u8 { Empty, Char, Any, Class, Concat, Alt, Repeat, Begin, End, Word_B, Not_Word_B }

@(private)
Node :: struct {
	kind:     Node_Kind,
	r:        rune,
	cls:      ^Class,
	children: [dynamic]^Node,
	min, max: int,   // Repeat; max < 0 = unbounded
}

@(private)
Op :: enum u8 { Char, Any, Class, Split, Jmp, Match, Begin, End, Word_B, Not_Word_B }

@(private)
Inst :: struct {
	op:   Op,
	r:    rune,
	cls:  ^Class,
	x, y: int,
}

Regex :: struct {
	insts:   [dynamic]Inst,
	classes: [dynamic]^Class,   // every class of the program (the parse tree itself is temporary)
}

@(private)
Parser :: struct {
	src:   []rune,
	i:     int,
	ok:    bool,
	re:    ^Regex,
}

regex_destroy :: proc(re: ^Regex) {
	if re == nil { return }
	for c in re.classes { delete(c.items); free(c) }
	delete(re.classes)
	delete(re.insts)
	free(re)
}

// Compiles `pattern`; nil when it is invalid, unsupported, or bigger than `max_program` instructions.
regex_compile :: proc(pattern: string, max_program: int) -> ^Regex {
	re := new(Regex)
	p := Parser{src = utf8.string_to_runes(pattern, context.temp_allocator), ok = true, re = re}
	root := parse_alt(&p, 0)
	if !p.ok || p.i != len(p.src) { regex_destroy(re); return nil }
	if !emit(re, root, max_program) { regex_destroy(re); return nil }
	append(&re.insts, Inst{op = .Match})
	return re
}

////////////////////////////////
// Parser (nodes live in the temp allocator; classes are owned by the regex)

@(private)
node :: proc(k: Node_Kind) -> ^Node {
	n := new(Node, context.temp_allocator)
	n.kind = k
	n.children = make([dynamic]^Node, context.temp_allocator)
	return n
}

@(private)
new_class :: proc(p: ^Parser) -> ^Class {
	c := new(Class)
	append(&p.re.classes, c)
	return c
}

@(private)
peek :: proc(p: ^Parser, off := 0) -> rune {
	if p.i + off < len(p.src) { return p.src[p.i + off] }
	return -1
}

@(private)
fail :: proc(p: ^Parser) -> ^Node { p.ok = false; return node(.Empty) }

@(private)
parse_alt :: proc(p: ^Parser, depth: int) -> ^Node {
	if depth > 256 { return fail(p) }
	first := parse_concat(p, depth)
	if peek(p) != '|' { return first }
	alt := node(.Alt)
	append(&alt.children, first)
	for p.ok && peek(p) == '|' {
		p.i += 1
		append(&alt.children, parse_concat(p, depth))
	}
	return alt
}

@(private)
parse_concat :: proc(p: ^Parser, depth: int) -> ^Node {
	cat := node(.Concat)
	for p.ok && p.i < len(p.src) {
		c := peek(p)
		if c == '|' || c == ')' { break }
		atom := parse_atom(p, depth)
		if !p.ok { break }
		atom = parse_quantifier(p, atom)
		append(&cat.children, atom)
	}
	return cat
}

@(private)
parse_int :: proc(p: ^Parser) -> (int, bool) {
	start := p.i
	v := 0
	for p.i < len(p.src) && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
		v = min(v * 10 + int(p.src[p.i] - '0'), 1 << 24)
		p.i += 1
	}
	return v, p.i > start
}

@(private)
parse_quantifier :: proc(p: ^Parser, atom: ^Node) -> ^Node {
	c := peek(p)
	lo, hi := -1, -1
	switch c {
	case '*': lo, hi = 0, -1; p.i += 1
	case '+': lo, hi = 1, -1; p.i += 1
	case '?': lo, hi = 0, 1; p.i += 1
	case '{':
		save := p.i
		p.i += 1
		a, ok := parse_int(p)
		if !ok { p.i = save; return fail(p) }   // a lone `{` is a syntax error with the u / v flags
		lo, hi = a, a
		if peek(p) == ',' {
			p.i += 1
			if b, okb := parse_int(p); okb { hi = b } else { hi = -1 }
		}
		if peek(p) != '}' { return fail(p) }
		p.i += 1
		if hi >= 0 && hi < lo { return fail(p) }
	case: return atom
	}
	if peek(p) == '?' { p.i += 1 }   // lazy: same language
	switch atom.kind {
	case .Begin, .End, .Word_B, .Not_Word_B: return fail(p)   // quantified assertions are errors with the u / v flags
	case .Empty, .Char, .Any, .Class, .Concat, .Alt, .Repeat:
	}
	if peek(p) == '*' || peek(p) == '+' || peek(p) == '?' || peek(p) == '{' { return fail(p) }
	r := node(.Repeat)
	r.min, r.max = lo, hi
	append(&r.children, atom)
	return r
}

@(private)
is_syntax_char :: proc(c: rune) -> bool {
	switch c {
	case '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/': return true
	}
	return false
}

@(private)
parse_atom :: proc(p: ^Parser, depth: int) -> ^Node {
	c := peek(p)
	switch c {
	case '^': p.i += 1; return node(.Begin)
	case '$': p.i += 1; return node(.End)
	case '.': p.i += 1; return node(.Any)
	case '(':
		p.i += 1
		if peek(p) == '?' {
			switch peek(p, 1) {
			case ':': p.i += 2
			case '<':
				if peek(p, 2) == '=' || peek(p, 2) == '!' { return fail(p) }   // lookbehind
				p.i += 2
				for p.i < len(p.src) && p.src[p.i] != '>' { p.i += 1 }
				if peek(p) != '>' { return fail(p) }
				p.i += 1
			case: return fail(p)   // lookahead, modifiers
			}
		}
		inner := parse_alt(p, depth + 1)
		if peek(p) != ')' { return fail(p) }
		p.i += 1
		return inner
	case '[':
		p.i += 1
		cls := parse_class(p, depth + 1)
		n := node(.Class)
		n.cls = cls
		return n
	case '\\':
		p.i += 1
		return parse_escape_atom(p)
	case ')', ']', '}', '{', '*', '+', '?', '|':
		return fail(p)
	}
	p.i += 1
	n := node(.Char)
	n.r = c
	return n
}

@(private)
hex_val :: proc(c: rune) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}

@(private)
read_hex :: proc(p: ^Parser, n: int) -> (rune, bool) {
	v: rune
	for _ in 0 ..< n {
		h := hex_val(peek(p))
		if h < 0 { return 0, false }
		v = v * 16 + rune(h)
		p.i += 1
	}
	return v, true
}

// \u.... (with a following low surrogate joined) or \u{...}
@(private)
read_unicode_escape :: proc(p: ^Parser) -> (rune, bool) {
	if peek(p) == '{' {
		p.i += 1
		v: rune
		count := 0
		for peek(p) != '}' {
			h := hex_val(peek(p))
			if h < 0 { return 0, false }
			v = v * 16 + rune(h)
			if v > 0x10FFFF { return 0, false }
			count += 1
			p.i += 1
		}
		p.i += 1
		return v, count > 0
	}
	hi, ok := read_hex(p, 4)
	if !ok { return 0, false }
	if hi >= 0xD800 && hi <= 0xDBFF && peek(p) == '\\' && peek(p, 1) == 'u' {
		save := p.i
		p.i += 2
		if lo, ok2 := read_hex(p, 4); ok2 && lo >= 0xDC00 && lo <= 0xDFFF {
			return 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00), true
		}
		p.i = save
	}
	return hi, true
}

// The character of a character escape, or ok = false. Class escapes are handled by the callers.
@(private)
char_escape :: proc(p: ^Parser, in_class: bool) -> (rune, bool) {
	c := peek(p)
	p.i += 1
	switch c {
	case 't': return '\t', true
	case 'n': return '\n', true
	case 'v': return '\v', true
	case 'f': return '\f', true
	case 'r': return '\r', true
	case '0':
		if peek(p) >= '0' && peek(p) <= '9' { return 0, false }
		return 0, true
	case 'c':
		l := peek(p)
		if (l >= 'a' && l <= 'z') || (l >= 'A' && l <= 'Z') { p.i += 1; return l % 32, true }
		return 0, false
	case 'x': return read_hex(p, 2)
	case 'u': return read_unicode_escape(p)
	case '-': if in_class { return '-', true }
	}
	if is_syntax_char(c) { return c, true }
	if in_class {
		switch c {
		case '&', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~': return c, true   // v-mode class punctuators
		}
	}
	return 0, false
}

@(private)
pred_escape :: proc(c: rune) -> (item: Class_Item, ok: bool) {
	switch c {
	case 'd': return {is_pred = true, pred = .Digit}, true
	case 'D': return {is_pred = true, pred = .Digit, neg = true}, true
	case 'w': return {is_pred = true, pred = .Word}, true
	case 'W': return {is_pred = true, pred = .Word, neg = true}, true
	case 's': return {is_pred = true, pred = .Space}, true
	case 'S': return {is_pred = true, pred = .Space, neg = true}, true
	}
	return {}, false
}

@(private)
property :: proc(name: string) -> (Pred, bool) {
	n := name
	if strings.has_prefix(n, "General_Category=") { n = n[len("General_Category="):] } else if strings.has_prefix(n, "gc=") { n = n[3:] }
	switch n {
	case "L", "Letter": return .Letter, true
	case "Lu", "Uppercase_Letter": return .Upper, true
	case "Ll", "Lowercase_Letter": return .Lower, true
	case "Lt", "Titlecase_Letter": return .Title, true
	case "Lm", "Modifier_Letter": return .Letter_Modifier, true
	case "Lo", "Other_Letter": return .Letter_Other, true
	case "M", "Mark", "Combining_Mark": return .Mark, true
	case "N", "Number": return .Number, true
	case "Nd", "Decimal_Number", "digit": return .Decimal, true
	case "Nl", "Letter_Number": return .Letter_Number, true
	case "No", "Other_Number": return .Other_Number, true
	case "P", "Punctuation", "punct": return .Punct, true
	case "S", "Symbol": return .Symbol, true
	case "Z", "Separator": return .Separator, true
	case "Zs", "Space_Separator": return .Space_Sep, true
	case "Cc", "Control", "cntrl": return .Control, true
	case "White_Space", "space": return .White_Space, true
	case "Alphabetic", "Alpha": return .Alphabetic, true
	case "ASCII": return .Ascii, true
	case "Any": return .Any, true
	}
	return .Any, false
}

@(private)
parse_property :: proc(p: ^Parser, neg: bool) -> (Class_Item, bool) {
	if peek(p) != '{' { return {}, false }
	p.i += 1
	start := p.i
	for p.i < len(p.src) && p.src[p.i] != '}' { p.i += 1 }
	if peek(p) != '}' { return {}, false }
	name := utf8.runes_to_string(p.src[start:p.i], context.temp_allocator)
	p.i += 1
	pr, ok := property(name)
	return Class_Item{is_pred = true, pred = pr, neg = neg}, ok
}

@(private)
parse_escape_atom :: proc(p: ^Parser) -> ^Node {
	c := peek(p)
	switch c {
	case 'b': p.i += 1; return node(.Word_B)
	case 'B': p.i += 1; return node(.Not_Word_B)
	case 'd', 'D', 'w', 'W', 's', 'S':
		p.i += 1
		it, _ := pred_escape(c)
		cls := new_class(p)
		append(&cls.items, it)
		n := node(.Class)
		n.cls = cls
		return n
	case 'p', 'P':
		p.i += 1
		it, ok := parse_property(p, c == 'P')
		if !ok { return fail(p) }
		cls := new_class(p)
		append(&cls.items, it)
		n := node(.Class)
		n.cls = cls
		return n
	case 'k', '1' ..= '9': return fail(p)   // backreferences
	}
	r, ok := char_escape(p, false)
	if !ok { return fail(p) }
	n := node(.Char)
	n.r = r
	return n
}

// One operand of a v-mode class: a nested class, an escape, a character or a range.
@(private)
class_operand :: proc(p: ^Parser, depth: int) -> (item: Class_Item, ok: bool) {
	c := peek(p)
	if c < 0 { return {}, false }
	if c == '[' {
		p.i += 1
		nested := parse_class(p, depth + 1)
		return Class_Item{nested = nested}, p.ok
	}
	lo: rune
	if c == '\\' {
		p.i += 1
		e := peek(p)
		if it, is_pred := pred_escape(e); is_pred { p.i += 1; return it, true }
		if e == 'p' || e == 'P' { p.i += 1; return parse_property(p, e == 'P') }
		if e == 'q' {
			// \q{a|b|c}: single characters only
			p.i += 1
			if peek(p) != '{' { return {}, false }
			p.i += 1
			nested := new_class(p)
			for peek(p) != '}' {
				if peek(p) < 0 { return {}, false }
				if peek(p) == '|' { p.i += 1; continue }
				ch: rune
				if peek(p) == '\\' { p.i += 1; r, ok2 := char_escape(p, true); if !ok2 { return {}, false }; ch = r } else { ch = peek(p); p.i += 1 }
				if peek(p) != '|' && peek(p) != '}' { return {}, false }   // a string of several characters
				append(&nested.items, Class_Item{lo = ch, hi = ch})
			}
			p.i += 1
			return Class_Item{nested = nested}, true
		}
		r, good := char_escape(p, true)
		if !good { return {}, false }
		lo = r
	} else {
		switch c {
		case '(', ')', '{', '}', '/', '|': return {}, false   // must be escaped in v-mode classes
		}
		lo = c
		p.i += 1
	}
	hi := lo
	if peek(p) == '-' && peek(p, 1) != '-' && peek(p, 1) != ']' {
		p.i += 1
		h := peek(p)
		if h == '\\' {
			p.i += 1
			r, good := char_escape(p, true)
			if !good { return {}, false }
			hi = r
		} else {
			if h < 0 || h == '[' || h == ']' { return {}, false }
			hi = h
			p.i += 1
		}
		if hi < lo { return {}, false }
	}
	return Class_Item{lo = lo, hi = hi}, true
}

@(private)
parse_class :: proc(p: ^Parser, depth: int) -> ^Class {
	cls := new_class(p)
	if depth > 64 { p.ok = false; return cls }
	if peek(p) == '^' { cls.negated = true; p.i += 1 }
	op_set := false
	for p.ok {
		c := peek(p)
		if c < 0 { p.ok = false; break }
		if c == ']' { p.i += 1; break }
		if (c == '&' && peek(p, 1) == '&') || (c == '-' && peek(p, 1) == '-') {
			op := c == '&' ? Class_Op.Intersect : Class_Op.Subtract
			if len(cls.items) == 0 || (op_set && cls.op != op) || (!op_set && len(cls.items) > 1) { p.ok = false; break }
			cls.op = op
			op_set = true
			p.i += 2
			continue
		}
		it, ok := class_operand(p, depth)
		if !ok { p.ok = false; break }
		append(&cls.items, it)
	}
	return cls
}

////////////////////////////////
// Code generation

@(private)
emit :: proc(re: ^Regex, n: ^Node, limit: int) -> bool {
	if len(re.insts) > limit { return false }
	switch n.kind {
	case .Empty:
	case .Char: append(&re.insts, Inst{op = .Char, r = n.r})
	case .Any: append(&re.insts, Inst{op = .Any})
	case .Class: append(&re.insts, Inst{op = .Class, cls = n.cls})
	case .Begin: append(&re.insts, Inst{op = .Begin})
	case .End: append(&re.insts, Inst{op = .End})
	case .Word_B: append(&re.insts, Inst{op = .Word_B})
	case .Not_Word_B: append(&re.insts, Inst{op = .Not_Word_B})
	case .Concat:
		for c in n.children { if !emit(re, c, limit) { return false } }
	case .Alt:
		// split L1, next; L1: a; jmp end; next: split ... ; last
		jumps := make([dynamic]int, context.temp_allocator)
		for c, i in n.children {
			if i < len(n.children) - 1 {
				split := len(re.insts)
				append(&re.insts, Inst{op = .Split})
				re.insts[split].x = len(re.insts)
				if !emit(re, c, limit) { return false }
				append(&jumps, len(re.insts))
				append(&re.insts, Inst{op = .Jmp})
				re.insts[split].y = len(re.insts)
			} else {
				if !emit(re, c, limit) { return false }
			}
		}
		for j in jumps { re.insts[j].x = len(re.insts) }
	case .Repeat:
		e := n.children[0]
		for _ in 0 ..< n.min { if !emit(re, e, limit) { return false } }
		if n.max < 0 {
			// L1: split L2, L3; L2: e; jmp L1; L3:
			l1 := len(re.insts)
			append(&re.insts, Inst{op = .Split})
			re.insts[l1].x = len(re.insts)
			if !emit(re, e, limit) { return false }
			append(&re.insts, Inst{op = .Jmp, x = l1})
			re.insts[l1].y = len(re.insts)
		} else {
			// (e(e(e)?)?)?: every optional copy can skip to the end
			splits := make([dynamic]int, context.temp_allocator)
			for _ in n.min ..< n.max {
				s := len(re.insts)
				append(&re.insts, Inst{op = .Split})
				re.insts[s].x = len(re.insts)
				append(&splits, s)
				if !emit(re, e, limit) { return false }
			}
			for s in splits { re.insts[s].y = len(re.insts) }
		}
	}
	return len(re.insts) <= limit
}

////////////////////////////////
// Matching

@(private)
is_word_char :: proc(r: rune) -> bool { return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' }

@(private)
is_js_space :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
	}
	return r >= 0x2000 && r <= 0x200A
}

@(private)
pred_matches :: proc(pr: Pred, r: rune) -> bool {
	switch pr {
	case .Digit: return r >= '0' && r <= '9'
	case .Word: return is_word_char(r)
	case .Space: return is_js_space(r)
	case .Any: return true
	case .Letter: return unicode.is_letter(r)
	case .Upper: return unicode.is_upper(r)
	case .Lower: return unicode.is_lower(r)
	case .Title: return unicode.is_title(r)
	case .Letter_Modifier: return unicode.is_letter(r) && !unicode.is_upper(r) && !unicode.is_lower(r) && !unicode.is_title(r) && r >= 0x2B0 && r <= 0x2FF
	case .Letter_Other: return unicode.is_letter(r) && !unicode.is_upper(r) && !unicode.is_lower(r) && !unicode.is_title(r)
	case .Mark: return unicode.is_combining(r) || unicode.is_nonspacing_mark(r) || unicode.is_spacing_mark(r) || unicode.is_enclosing_mark(r)
	case .Number: return unicode.is_number(r)
	case .Decimal: return unicode.is_digit(r)
	case .Letter_Number: return unicode.is_number(r) && !unicode.is_digit(r) && ((r >= 0x2160 && r <= 0x2188) || (r >= 0x3007 && r <= 0x3029) || r == 0x16EE || r == 0x16EF || r == 0x16F0)
	case .Other_Number: return unicode.is_number(r) && !unicode.is_digit(r)
	case .Punct: return unicode.is_punct(r)
	case .Symbol: return unicode.is_symbol(r)
	case .Separator: return r == ' ' || r == 0xA0 || r == 0x1680 || (r >= 0x2000 && r <= 0x200A) || r == 0x2028 || r == 0x2029 || r == 0x202F || r == 0x205F || r == 0x3000
	case .Space_Sep: return r == ' ' || r == 0xA0 || r == 0x1680 || (r >= 0x2000 && r <= 0x200A) || r == 0x202F || r == 0x205F || r == 0x3000
	case .Control: return r < 0x20 || (r >= 0x7F && r < 0xA0)
	case .White_Space: return unicode.is_space(r) || r == 0x85
	case .Alphabetic: return unicode.is_letter(r) || (unicode.is_number(r) && !unicode.is_digit(r) && r >= 0x2160 && r <= 0x2188)
	case .Ascii: return r < 0x80
	case .Line_Terminator: return r == '\n' || r == '\r' || r == 0x2028 || r == 0x2029
	}
	return false
}

@(private)
item_matches :: proc(it: Class_Item, r: rune) -> bool {
	if it.nested != nil { return class_matches(it.nested, r) }
	if it.is_pred { return pred_matches(it.pred, r) != it.neg }
	return r >= it.lo && r <= it.hi
}

@(private)
class_matches :: proc(c: ^Class, r: rune) -> bool {
	m: bool
	switch c.op {
	case .Union:
		for it in c.items { if item_matches(it, r) { m = true; break } }
	case .Intersect:
		m = len(c.items) > 0
		for it in c.items { if !item_matches(it, r) { m = false; break } }
	case .Subtract:
		m = len(c.items) > 0 && item_matches(c.items[0], r)
		for it in c.items[1:] { if m && item_matches(it, r) { m = false } }
	}
	return m != c.negated
}

@(private)
Thread_List :: struct {
	dense:  [dynamic]int,
	sparse: []int,
}

@(private)
list_has :: proc(l: ^Thread_List, pc: int) -> bool {
	i := l.sparse[pc]
	return i < len(l.dense) && l.dense[i] == pc
}

@(private)
list_add :: proc(l: ^Thread_List, pc: int) {
	l.sparse[pc] = len(l.dense)
	append(&l.dense, pc)
}

// Follows the epsilon transitions from `pc` at position `pos` (prev / next characters for the assertions).
@(private)
add_thread :: proc(re: ^Regex, l: ^Thread_List, start: int, at_start, at_end: bool, prev, next: rune, stack: ^[dynamic]int) {
	clear(stack)
	append(stack, start)
	for len(stack) > 0 {
		pc := pop(stack)
		if list_has(l, pc) { continue }
		list_add(l, pc)
		in_ := re.insts[pc]
		#partial switch in_.op {
		case .Jmp: append(stack, in_.x)
		case .Split: append(stack, in_.y); append(stack, in_.x)
		case .Begin: if at_start { append(stack, pc + 1) }
		case .End: if at_end { append(stack, pc + 1) }
		case .Word_B, .Not_Word_B:
			a := !at_start && is_word_char(prev)
			b := !at_end && is_word_char(next)
			if (a != b) == (in_.op == .Word_B) { append(stack, pc + 1) }
		}
	}
}

// Does the whole of `s` match? ok = false when the work budget ran out (no answer).
regex_full_match :: proc(re: ^Regex, s: string, max_steps: int) -> (matched: bool, ok: bool) {
	runes := utf8.string_to_runes(s, context.temp_allocator)
	n := len(re.insts)
	cur := Thread_List{dense = make([dynamic]int, 0, n, context.temp_allocator), sparse = make([]int, n, context.temp_allocator)}
	nxt := Thread_List{dense = make([dynamic]int, 0, n, context.temp_allocator), sparse = make([]int, n, context.temp_allocator)}
	stack := make([dynamic]int, 0, 64, context.temp_allocator)
	steps := 0
	first: rune = len(runes) > 0 ? runes[0] : -1
	add_thread(re, &cur, 0, true, len(runes) == 0, -1, first, &stack)
	for i in 0 ..< len(runes) {
		r := runes[i]
		clear(&nxt.dense)
		next_r: rune = i + 1 < len(runes) ? runes[i + 1] : -1
		for pc in cur.dense {
			steps += 1
			in_ := re.insts[pc]
			hit := false
			#partial switch in_.op {
			case .Char: hit = in_.r == r
			case .Any: hit = !pred_matches(.Line_Terminator, r)
			case .Class: hit = class_matches(in_.cls, r)
			}
			if hit { add_thread(re, &nxt, pc + 1, false, i + 1 == len(runes), r, next_r, &stack) }
		}
		if steps > max_steps { return false, false }
		cur, nxt = nxt, cur
		if len(cur.dense) == 0 { return false, true }
	}
	for pc in cur.dense { if re.insts[pc].op == .Match { return true, true } }
	return false, true
}
