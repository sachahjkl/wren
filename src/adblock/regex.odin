package adblock

// A small regular-expression engine for `/regex/` filters (JavaScript syntax, the part that filters use). It compiles to
// a program run by a Pike VM: matching time is O(text x program) whatever the expression, so a hostile or careless
// filter cannot hang the browser (no backtracking). Supported: literals, `.`, `\d \D \w \W \s \S \b \B`, classes,
// `^ $`, groups (capturing ones are plain groups), alternation, `* + ? {n} {n,} {n,m}` (lazy forms behave like greedy
// ones: only "does it match" matters), lookahead `(?= ) (?! )`. Back-references and lookbehind are rejected (the filter
// is dropped). Limits: program size, repetition counts, nesting depth (all bounded: `regex_compile` fails above them).

import "core:slice"
import "core:strings"

REGEX_MAX_PROGRAM :: 6000
REGEX_MAX_REPEAT  :: 1000
REGEX_MAX_DEPTH   :: 64
REGEX_MAX_TEXT    :: 8192   // longer URLs are matched on their first 8 KB

@(private)
Op :: enum u8 { Char, Char2, Any, Class, Split, Jmp, Bol, Eol, Word_B, Not_Word_B, Look, Match }

@(private)
Inst :: struct {
	op: Op,
	neg: bool,    // Look: negative
	c1, c2: u8,   // Char / Char2
	x, y: i32,    // Split targets / Jmp target / Class index / Look: sub-program start, (y: next pc)
}

Regex :: struct {
	prog:    []Inst,
	classes: [][32]u8,
	lits:    []string,     // literal runs every match contains, in order (lower case when icase)
	literal: string,       // the longest of them ("" if none); lower case when icase
	icase:   bool,
	anchored_start: bool,  // begins with `^`
}

regex_destroy :: proc(r: ^Regex) {
	delete(r.prog); delete(r.classes); delete(r.literal)
	for l in r.lits { delete(l) }
	delete(r.lits)
	r^ = {}
}

@(private)
Node_Kind :: enum u8 { Empty, Char, Any, Class, Cat, Alt, Repeat, Bol, Eol, Word_B, Not_Word_B, Look }

@(private)
Node :: struct {
	kind:     Node_Kind,
	c:        u8,
	class:    i32,
	a, b:     i32,     // children: Cat: first/next list via `next`; Alt: a|b; Repeat/Look: a
	next:     i32,     // sibling in a Cat
	min, max: i32,     // Repeat (max -1 = unbounded)
	neg:      bool,    // Look
}

@(private)
Parser :: struct {
	s:       string,
	pos:     int,
	nodes:   [dynamic]Node,
	classes: [dynamic][32]u8,
	icase:   bool,
	depth:   int,
	err:     bool,
}

@(private)
new_node :: proc(p: ^Parser, n: Node) -> i32 {
	append(&p.nodes, n)
	return i32(len(p.nodes) - 1)
}

regex_compile :: proc(pattern: string, icase: bool) -> (re: Regex, ok: bool) {
	if len(pattern) == 0 || len(pattern) > 4096 { return {}, false }
	p := Parser{s = pattern, icase = icase}
	p.nodes = make([dynamic]Node, 0, 32, context.temp_allocator)
	p.classes = make([dynamic][32]u8, 0, 4, context.temp_allocator)
	root := parse_alt(&p)
	if p.err || p.pos != len(p.s) { return {}, false }

	prog := make([dynamic]Inst, 0, 32)
	if !emit(&p, &prog, root) { delete(prog); return {}, false }
	append(&prog, Inst{op = .Match})
	if len(prog) > REGEX_MAX_PROGRAM { delete(prog); return {}, false }
	re.prog = prog[:]
	re.classes = slice.clone(p.classes[:])
	re.icase = icase
	// The literal runs every match must contain, in this order (a cheap prefilter before the VM): the runs of
	// literal characters of the top-level concatenation. `literal` is the longest of them.
	col := Lit_Collector{lit = make([dynamic]u8, context.temp_allocator), best = make([dynamic]u8, context.temp_allocator), runs = make([dynamic]string, context.temp_allocator)}
	collect_literals(&p, root, &col)
	col_flush(&col)
	if len(col.best) >= 2 {
		b := make([]u8, len(col.best))
		for c, i in col.best { b[i] = icase ? lower_byte(c) : c }
		re.literal = string(b)
	}
	if len(col.runs) > 0 {
		re.lits = make([]string, len(col.runs))
		for r, i in col.runs {
			b := make([]u8, len(r))
			for k in 0 ..< len(r) { b[k] = icase ? lower_byte(r[k]) : r[k] }
			re.lits[i] = string(b)
		}
	}	if root >= 0 {
		first := p.nodes[root]
		if first.kind == .Bol { re.anchored_start = true }
		if first.kind == .Cat && p.nodes[first.a].kind == .Bol { re.anchored_start = true }
	}
	return re, true
}

@(private)
Lit_Collector :: struct {
	lit, best: [dynamic]u8,
	runs:      [dynamic]string,
}

@(private)
col_flush :: proc(c: ^Lit_Collector) {
	if len(c.lit) > len(c.best) { clear(&c.best); append(&c.best, ..c.lit[:]) }
	if len(c.lit) >= 2 && len(c.runs) < 6 { append(&c.runs, strings.clone(string(c.lit[:]), context.temp_allocator)) }
	clear(&c.lit)
}

@(private)
collect_literals :: proc(p: ^Parser, n: i32, c: ^Lit_Collector) {
	if n < 0 { return }
	nd := p.nodes[n]
	#partial switch nd.kind {
	case .Char: append(&c.lit, nd.c)
	case .Cat:
		k := nd.a
		for k >= 0 { collect_literals(p, k, c); k = p.nodes[k].next }
	case .Repeat:
		col_flush(c)
		if nd.min >= 1 { collect_literals(p, nd.a, c) }
		col_flush(c)
	case .Bol, .Eol, .Word_B, .Not_Word_B, .Look: // zero width: the run goes on
	case: col_flush(c)
	}
}
@(private)
peek :: proc(p: ^Parser) -> (u8, bool) {
	if p.pos >= len(p.s) { return 0, false }
	return p.s[p.pos], true
}

@(private)
parse_alt :: proc(p: ^Parser) -> i32 {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > REGEX_MAX_DEPTH { p.err = true; return -1 }
	left := parse_cat(p)
	for {
		c, ok := peek(p)
		if !ok || c != '|' || p.err { break }
		p.pos += 1
		right := parse_cat(p)
		left = new_node(p, Node{kind = .Alt, a = left, b = right, next = -1})
	}
	return left
}

@(private)
parse_cat :: proc(p: ^Parser) -> i32 {
	first, last: i32 = -1, -1
	for !p.err {
		c, ok := peek(p)
		if !ok || c == '|' || c == ')' { break }
		atom := parse_quantified(p)
		if p.err { break }
		if first < 0 { first = atom } else { p.nodes[last].next = atom }
		last = atom
	}
	if first < 0 { return new_node(p, Node{kind = .Empty, next = -1}) }
	if first == last { return first }
	return new_node(p, Node{kind = .Cat, a = first, next = -1})
}

@(private)
parse_quantified :: proc(p: ^Parser) -> i32 {
	atom := parse_atom(p)
	if p.err { return -1 }
	for {
		c, ok := peek(p)
		if !ok { break }
		mn, mx: i32
		switch c {
		case '*': mn, mx = 0, -1; p.pos += 1
		case '+': mn, mx = 1, -1; p.pos += 1
		case '?': mn, mx = 0, 1; p.pos += 1
		case '{':
			// {n} {n,} {n,m}; anything else is a literal brace
			j := p.pos + 1
			n1, n2 := -1, -1
			comma := false
			v := 0
			digits := 0
			for j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' { v = v * 10 + int(p.s[j] - '0'); digits += 1; j += 1; if v > 100000 { p.err = true; return -1 } }
			if digits == 0 { return atom }
			n1 = v
			if j < len(p.s) && p.s[j] == ',' {
				comma = true; j += 1
				v, digits = 0, 0
				for j < len(p.s) && p.s[j] >= '0' && p.s[j] <= '9' { v = v * 10 + int(p.s[j] - '0'); digits += 1; j += 1; if v > 100000 { p.err = true; return -1 } }
				if digits > 0 { n2 = v }
			}
			if j >= len(p.s) || p.s[j] != '}' { return atom }
			p.pos = j + 1
			mn = i32(n1)
			mx = comma ? i32(n2) : i32(n1)
			if comma && n2 < 0 { mx = -1 }
			if mx >= 0 && mx < mn { p.err = true; return -1 }
			if mn > REGEX_MAX_REPEAT || mx > REGEX_MAX_REPEAT { p.err = true; return -1 }
		case: return atom
		}
		// lazy / possessive suffix: same language for a yes/no match
		if c2, ok2 := peek(p); ok2 && c2 == '?' { p.pos += 1 }
		if c3, ok3 := peek(p); ok3 && (c3 == '*' || c3 == '+' || c3 == '?') { p.err = true; return -1 }
		atom = new_node(p, Node{kind = .Repeat, a = atom, min = mn, max = mx, next = -1})
	}
	return atom
}

@(private)
class_add_range :: proc(bm: ^[32]u8, lo, hi: int) {
	for c in lo ..= hi { bm[c >> 3] |= 1 << u8(c & 7) }
}

@(private)
class_add_escape :: proc(bm: ^[32]u8, e: u8) -> bool {
	switch e {
	case 'd': class_add_range(bm, '0', '9')
	case 'w': class_add_range(bm, '0', '9'); class_add_range(bm, 'a', 'z'); class_add_range(bm, 'A', 'Z'); class_add_range(bm, '_', '_')
	case 's':
		for c in ([]u8{' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0}) { class_add_range(bm, int(c), int(c)) }
	case 'D', 'W', 'S':
		tmp: [32]u8
		class_add_escape(&tmp, e + 32)
		for i in 0 ..< 32 { bm[i] |= ~tmp[i] }
	case: return false
	}
	return true
}

@(private)
parse_escape_char :: proc(p: ^Parser) -> (c: u8, ok: bool) {
	// after the backslash: a character escape that denotes one byte
	e, has := peek(p)
	if !has { p.err = true; return 0, false }
	p.pos += 1
	switch e {
	case 'n': return '\n', true
	case 'r': return '\r', true
	case 't': return '\t', true
	case 'f': return 0x0c, true
	case 'v': return 0x0b, true
	case '0': return 0, true
	case 'x', 'u':
		n := e == 'x' ? 2 : 4
		if p.pos + n > len(p.s) { p.err = true; return 0, false }
		v := 0
		for k in 0 ..< n {
			h := p.s[p.pos + k]
			d: int
			switch {
			case h >= '0' && h <= '9': d = int(h - '0')
			case h >= 'a' && h <= 'f': d = int(h - 'a') + 10
			case h >= 'A' && h <= 'F': d = int(h - 'A') + 10
			case: p.err = true; return 0, false
			}
			v = v * 16 + d
		}
		p.pos += n
		if v > 0x7f { p.err = true; return 0, false }   // URLs are ASCII once escaped: wider code points never match
		return u8(v), true
	}
	if is_alnum(e) { p.err = true; return 0, false }   // \1 back-references, \p{..}, \k<..>: unsupported
	return e, true
}

@(private)
parse_atom :: proc(p: ^Parser) -> i32 {
	c, _ := peek(p)
	p.pos += 1
	switch c {
	case '.': return new_node(p, Node{kind = .Any, next = -1})
	case '^': return new_node(p, Node{kind = .Bol, next = -1})
	case '$': return new_node(p, Node{kind = .Eol, next = -1})
	case '(':
		look := false
		neg := false
		if p.pos + 1 < len(p.s) && p.s[p.pos] == '?' {
			switch p.s[p.pos + 1] {
			case ':': p.pos += 2
			case '=': p.pos += 2; look = true
			case '!': p.pos += 2; look = true; neg = true
			case: p.err = true; return -1   // lookbehind, named groups, flags
			}
		}
		inner := parse_alt(p)
		if p.err { return -1 }
		if cc, ok := peek(p); !ok || cc != ')' { p.err = true; return -1 }
		p.pos += 1
		if look { return new_node(p, Node{kind = .Look, a = inner, neg = neg, next = -1}) }
		// wrap so that a quantifier applies to the whole group
		return new_node(p, Node{kind = .Cat, a = inner, next = -1})
	case '[':
		bm: [32]u8
		negate := false
		if cc, ok := peek(p); ok && cc == '^' { negate = true; p.pos += 1 }
		first := true
		for {
			cc, ok := peek(p)
			if !ok { p.err = true; return -1 }
			if cc == ']' && !first { p.pos += 1; break }
			if cc == ']' && first { p.pos += 1; break }   // "[]" is an empty class (matches nothing) in JS
			first = false
			p.pos += 1
			lo: int
			if cc == '\\' {
				e, has := peek(p)
				if !has { p.err = true; return -1 }
				if class_add_escape(&bm, e) { p.pos += 1; continue }
				if e == 'b' { p.pos += 1; lo = 8 } else {
					b, okc := parse_escape_char(p)
					if !okc { return -1 }
					lo = int(b)
				}
			} else { lo = int(cc) }
			// range?
			if p.pos + 1 < len(p.s) && p.s[p.pos] == '-' && p.s[p.pos + 1] != ']' {
				p.pos += 1
				hc := p.s[p.pos]
				p.pos += 1
				hi: int
				if hc == '\\' {
					e, has := peek(p)
					if !has { p.err = true; return -1 }
					if class_add_escape(&bm, e) {   // [a-\d]: a literal '-'
						p.pos += 1
						class_add_range(&bm, lo, lo); class_add_range(&bm, '-', '-')
						continue
					}
					b, okc := parse_escape_char(p)
					if !okc { return -1 }
					hi = int(b)
				} else { hi = int(hc) }
				if hi < lo { p.err = true; return -1 }
				class_add_range(&bm, lo, hi)
			} else {
				class_add_range(&bm, lo, lo)
			}
		}
		if p.icase { fold_case(&bm) }
		if negate { for i in 0 ..< 32 { bm[i] = ~bm[i] } }
		append(&p.classes, bm)
		return new_node(p, Node{kind = .Class, class = i32(len(p.classes) - 1), next = -1})
	case '\\':
		e, has := peek(p)
		if !has { p.err = true; return -1 }
		switch e {
		case 'b': p.pos += 1; return new_node(p, Node{kind = .Word_B, next = -1})
		case 'B': p.pos += 1; return new_node(p, Node{kind = .Not_Word_B, next = -1})
		case 'd', 'D', 'w', 'W', 's', 'S':
			p.pos += 1
			bm: [32]u8
			class_add_escape(&bm, e)
			append(&p.classes, bm)
			return new_node(p, Node{kind = .Class, class = i32(len(p.classes) - 1), next = -1})
		}
		b, okc := parse_escape_char(p)
		if !okc { p.err = true; return -1 }
		return new_node(p, Node{kind = .Char, c = b, next = -1})
	case '*', '+', '?': p.err = true; return -1   // nothing to repeat
	case ')': p.err = true; return -1
	}
	return new_node(p, Node{kind = .Char, c = c, next = -1})
}

@(private)
fold_case :: proc(bm: ^[32]u8) {
	for c in 'a' ..= 'z' {
		up := int(c) - 32
		lo := int(c)
		hasl := bm[lo >> 3] & (1 << u8(lo & 7)) != 0
		hasu := bm[up >> 3] & (1 << u8(up & 7)) != 0
		if hasl || hasu {
			bm[lo >> 3] |= 1 << u8(lo & 7)
			bm[up >> 3] |= 1 << u8(up & 7)
		}
	}
}

// Emits the code of node `n` (and of its following siblings when they belong to the same concatenation).
@(private)
emit :: proc(p: ^Parser, prog: ^[dynamic]Inst, n: i32) -> bool {
	if len(prog^) > REGEX_MAX_PROGRAM { return false }
	nd := p.nodes[n]
	switch nd.kind {
	case .Empty:
	case .Char:
		if p.icase && is_alnum(nd.c) && !(nd.c >= '0' && nd.c <= '9') {
			append(prog, Inst{op = .Char2, c1 = lower_byte(nd.c), c2 = lower_byte(nd.c) - 32})
		} else {
			append(prog, Inst{op = .Char, c1 = nd.c})
		}
	case .Any: append(prog, Inst{op = .Any})
	case .Class: append(prog, Inst{op = .Class, x = nd.class})
	case .Bol: append(prog, Inst{op = .Bol})
	case .Eol: append(prog, Inst{op = .Eol})
	case .Word_B: append(prog, Inst{op = .Word_B})
	case .Not_Word_B: append(prog, Inst{op = .Not_Word_B})
	case .Cat:
		c := nd.a
		for c >= 0 {
			if !emit(p, prog, c) { return false }
			c = p.nodes[c].next
		}
	case .Alt:
		// split L1, L2; L1: a; jmp end; L2: b; end:
		split := len(prog^)
		append(prog, Inst{op = .Split})
		prog[split].x = i32(len(prog^))
		if !emit(p, prog, nd.a) { return false }
		jmp := len(prog^)
		append(prog, Inst{op = .Jmp})
		prog[split].y = i32(len(prog^))
		if !emit(p, prog, nd.b) { return false }
		prog[jmp].x = i32(len(prog^))
	case .Repeat:
		// the child is a single node (siblings belong to the enclosing Cat, so emit only this node)
		child := nd.a
		saved := p.nodes[child].next
		p.nodes[child].next = -1
		defer p.nodes[child].next = saved
		for _ in 0 ..< nd.min { if !emit(p, prog, child) { return false } }
		if nd.max < 0 {
			// L: split body, end; body; jmp L
			l := len(prog^)
			append(prog, Inst{op = .Split})
			prog[l].x = i32(len(prog^))
			if !emit(p, prog, child) { return false }
			append(prog, Inst{op = .Jmp, x = i32(l)})
			prog[l].y = i32(len(prog^))
		} else {
			// (max-min) optional copies, each a split to the common end
			splits := make([dynamic]int, context.temp_allocator)
			for _ in nd.min ..< nd.max {
				s := len(prog^)
				append(prog, Inst{op = .Split})
				prog[s].x = i32(len(prog^))
				append(&splits, s)
				if !emit(p, prog, child) { return false }
			}
			for s in splits { prog[s].y = i32(len(prog^)) }
		}
	case .Look:
		// Look: x = sub-program start (right after), y = next pc after the sub-program
		l := len(prog^)
		append(prog, Inst{op = .Look, neg = nd.neg})
		prog[l].x = i32(len(prog^))
		child := nd.a
		saved := p.nodes[child].next
		p.nodes[child].next = -1
		ok := emit(p, prog, child)
		p.nodes[child].next = saved
		if !ok { return false }
		append(prog, Inst{op = .Match})
		prog[l].y = i32(len(prog^))
	}
	return true
}

////////////////////////////////
// The VM

Regex_Scratch :: struct {
	dense_a, dense_b:   []i32,
	sparse_a, sparse_b: []i32,
	stack:              []i32,
	cap:                int,
}

regex_scratch_destroy :: proc(s: ^Regex_Scratch) {
	delete(s.dense_a); delete(s.dense_b); delete(s.sparse_a); delete(s.sparse_b); delete(s.stack)
	s^ = {}
}

@(private)
scratch_ensure :: proc(s: ^Regex_Scratch, n: int) {
	if s.cap >= n { return }
	regex_scratch_destroy(s)
	m := max(n, 256)
	s.dense_a = make([]i32, m); s.dense_b = make([]i32, m)
	s.sparse_a = make([]i32, m); s.sparse_b = make([]i32, m)
	s.stack = make([]i32, m * 2 + 8)
	s.cap = m
}

@(private)
Sparse :: struct { dense, sparse: []i32, n: int }

@(private)
sset_has :: #force_inline proc "contextless" (s: ^Sparse, pc: i32) -> bool {
	i := s.sparse[pc]
	return int(i) < s.n && s.dense[i] == pc
}

@(private)
sset_add :: #force_inline proc "contextless" (s: ^Sparse, pc: i32) {
	s.sparse[pc] = i32(s.n)
	s.dense[s.n] = pc
	s.n += 1
}

@(private)
is_word :: #force_inline proc "contextless" (c: u8) -> bool { return is_alnum(c) || c == '_' }

@(private)
assertion_ok :: proc "contextless" (op: Op, text: string, pos: int) -> bool {
	switch op {
	case .Bol: return pos == 0
	case .Eol: return pos == len(text)
	case .Word_B, .Not_Word_B:
		a := pos > 0 && is_word(text[pos - 1])
		b := pos < len(text) && is_word(text[pos])
		return (a != b) == (op == .Word_B)
	case .Char, .Char2, .Any, .Class, .Split, .Jmp, .Look, .Match:
	}
	return true
}

// Follows empty transitions from `pc0` at text position `pos`, adding the consuming instructions (and Match) to `set`.
@(private)
add_thread :: proc(re: ^Regex, s: ^Regex_Scratch, set: ^Sparse, pc0: i32, text: string, pos: int, depth: int) -> bool {
	stack := s.stack
	sp := 0
	stack[sp] = pc0; sp += 1
	matched := false
	for sp > 0 {
		sp -= 1
		pc := stack[sp]
		if sset_has(set, pc) { continue }
		sset_add(set, pc)
		in_ := re.prog[pc]
		switch in_.op {
		case .Jmp: if sp + 2 < len(stack) { stack[sp] = in_.x; sp += 1 }
		case .Split:
			if sp + 3 < len(stack) {
				stack[sp] = in_.y; sp += 1
				stack[sp] = in_.x; sp += 1
			}
		case .Bol, .Eol, .Word_B, .Not_Word_B:
			if assertion_ok(in_.op, text, pos) && sp + 2 < len(stack) { stack[sp] = pc + 1; sp += 1 }
		case .Look:
			ok := look_match(re, s, in_.x, text, pos, depth + 1)
			if ok != in_.neg && sp + 2 < len(stack) { stack[sp] = in_.y; sp += 1 }
		case .Match: matched = true
		case .Char, .Char2, .Any, .Class:
		}
	}
	return matched
}

// A lookahead's sub-program, anchored at `pos`. Needs scratch memory of its own: a nested run on fresh buffers.
@(private)
look_match :: proc(re: ^Regex, outer: ^Regex_Scratch, start: i32, text: string, pos: int, depth: int) -> bool {
	if depth > 4 { return false }
	n := len(re.prog)
	sub := Regex_Scratch{}
	scratch_ensure(&sub, n)
	defer regex_scratch_destroy(&sub)
	return run_from(re, &sub, start, text, pos, true, depth)
}

// Runs the program from `start` over text[pos:]; true when Match is reached. `anchored`: only a match beginning at pos.
@(private)
run_from :: proc(re: ^Regex, s: ^Regex_Scratch, start: i32, text: string, pos0: int, anchored: bool, depth: int) -> bool {
	cur := Sparse{s.dense_a, s.sparse_a, 0}
	nxt := Sparse{s.dense_b, s.sparse_b, 0}
	pos := pos0
	if add_thread(re, s, &cur, start, text, pos, depth) { return true }
	for {
		if pos >= len(text) { break }
		c := text[pos]
		nxt.n = 0
		for i in 0 ..< cur.n {
			pc := cur.dense[i]
			in_ := re.prog[pc]
			ok := false
			switch in_.op {
			case .Char: ok = c == in_.c1
			case .Char2: ok = c == in_.c1 || c == in_.c2
			case .Any: ok = c != '\n'
			case .Class: ok = re.classes[in_.x][c >> 3] & (1 << (c & 7)) != 0
			case .Jmp, .Split, .Bol, .Eol, .Word_B, .Not_Word_B, .Look, .Match:
			}
			if ok {
				if add_thread(re, s, &nxt, pc + 1, text, pos + 1, depth) { return true }
			}
		}
		pos += 1
		if !anchored {
			if add_thread(re, s, &nxt, start, text, pos, depth) { return true }
		}
		cur, nxt = nxt, cur
		if cur.n == 0 && anchored { break }
	}
	return false
}

// Does the regex match anywhere in `text`? (text is cut to REGEX_MAX_TEXT bytes)
regex_match :: proc(re: ^Regex, s: ^Regex_Scratch, text_in: string) -> bool {
	text := text_in
	if len(text) > REGEX_MAX_TEXT { text = text[:REGEX_MAX_TEXT] }
	pos := 0
	for l in re.lits {
		at := find_literal(text[pos:], l, re.icase)
		if at < 0 { return false }
		pos += at + len(l)
	}
	scratch_ensure(s, len(re.prog))
	return run_from(re, s, 0, text, 0, re.anchored_start, 0)
}

@(private)
find_literal :: proc(text, lit: string, icase: bool) -> int {
	n, m := len(text), len(lit)
	if m > n { return -1 }
	first := lit[0]
	for i := 0; i + m <= n; i += 1 {
		c := text[i]
		if icase { c = lower_byte(c) }
		if c != first { continue }
		ok := true
		for j in 1 ..< m {
			d := text[i + j]
			if icase { d = lower_byte(d) }
			if d != lit[j] { ok = false; break }
		}
		if ok { return i }
	}
	return -1
}
