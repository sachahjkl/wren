package url

// A compact backtracking regular-expression engine for URLPattern custom groups (the "(<regexp>)" tokens). Wren has
// no JavaScript regexp in the host, so the URL Pattern matcher (pattern_match.odin) compiles each component's part
// list to this engine rather than to an ECMAScript RegExp. The engine supports the subset that appears in URL
// patterns: literals, '.', character classes "[...]" (with ranges and negation), the shorthands \d \D \w \W \s \S,
// alternation '|', grouping '(...)' and non-capturing '(?:...)', and the quantifiers * + ? and {m,n} with an
// optional lazy '?'. It matches Unicode code points. It is used for anchored, whole-string matches, so there are no
// '^' / '$' anchors in the group sources themselves.
//
// Captures inside custom groups are not surfaced as URLPattern groups (the specification names a part, not its inner
// groups), so grouping here is treated as non-capturing for the purposes of the result; the engine only needs to
// decide whether a slice matches and how far it reached.

import "core:unicode/utf8"

@(private = "file")
Rx_Op :: enum u8 {
	Char,        // a literal code point (arg = rune)
	Any,         // .
	Class,       // a character class (class_index)
	Group_Start, // ( — bytecode uses jumps; groups are structural only
	Save_Open,   // unused (no captures surfaced)
	Jmp,         // unconditional jump to x
	Split,       // try x first then y (greedy) / y first then x (lazy)
	Match,       // success
}

// The engine is a small recursive-descent compiler to a program of instructions, run by a backtracking VM with a
// visited guard to bound work on pathological patterns.
@(private = "file")
Rx_Inst :: struct {
	op:    Rx_Op,
	r:     rune,     // Char
	cls:   int,      // Class: index into classes
	x, y:  int,      // Jmp/Split targets
}

@(private = "file")
Rx_Class :: struct {
	negate: bool,
	ranges: [][2]rune,   // inclusive code-point ranges
	shorthand: u8,       // 0 none, else 'd','w','s' etc. combined via `extra`
	extra:  []u8,        // additional shorthand letters in the class (d,w,s,D,W,S)
}

Regexp :: struct {
	prog:    []Rx_Inst,
	classes: []Rx_Class,
	ok:      bool,
}

@(private = "file")
Rx_Compiler :: struct {
	src:     []rune,
	pos:     int,
	prog:    [dynamic]Rx_Inst,
	classes: [dynamic]Rx_Class,
	ok:      bool,
}

regexp_destroy :: proc(rx: ^Regexp) {
	for c in rx.classes { delete(c.ranges); delete(c.extra) }
	delete(rx.classes)
	delete(rx.prog)
	rx^ = {}
}

// Compiles an anchored whole-string regexp from an ASCII source (the group's inner text). ok=false on a malformed
// source (a TypeError upstream, mirroring RegExpCreate throwing). Allocates the program with `allocator`.
regexp_compile :: proc(source: string, ignore_case: bool, allocator := context.allocator) -> (rx: Regexp, ok: bool) {
	c: Rx_Compiler
	c.src = utf8.string_to_runes(source, context.temp_allocator)
	c.prog = make([dynamic]Rx_Inst, allocator)
	c.classes = make([dynamic]Rx_Class, allocator)
	c.ok = true
	_ = ignore_case   // handled by the caller folding case before match; kept for signature symmetry
	rx_compile_alt(&c)
	if c.ok && c.pos != len(c.src) { c.ok = false }   // trailing ) or garbage
	append(&c.prog, Rx_Inst{op = .Match})
	if !c.ok {
		for cl in c.classes { delete(cl.ranges); delete(cl.extra) }
		delete(c.classes); delete(c.prog)
		return {}, false
	}
	return Regexp{prog = c.prog[:], classes = c.classes[:], ok = true}, true
}

@(private = "file")
rx_peek :: proc(c: ^Rx_Compiler) -> rune { return c.pos < len(c.src) ? c.src[c.pos] : -1 }

// alternation: branch ( '|' branch )*. Each branch is compiled, lifted out with rx_extract (which rebases its
// internal Jmp/Split targets relative to 0), then re-appended with rx_append_relative under a Split chain:
//   Split b1, (b2...) ; <b1> ; Jmp END ; Split b2, (b3...) ; <b2> ; Jmp END ; ... ; <bN>
@(private = "file")
rx_compile_alt :: proc(c: ^Rx_Compiler) {
	start := len(c.prog)
	rx_compile_concat(c)
	if !c.ok || rx_peek(c) != '|' { return }
	branches := make([dynamic][]Rx_Inst, context.temp_allocator)
	append(&branches, rx_extract(c, start))   // first branch, lifted and rebased to 0
	for rx_peek(c) == '|' {
		c.pos += 1
		bs := len(c.prog)
		rx_compile_concat(c)
		if !c.ok { return }
		append(&branches, rx_extract(c, bs))
	}
	jmp_fixups := make([dynamic]int, context.temp_allocator)
	for b, bi in branches {
		last := bi == len(branches) - 1
		split_at := -1
		if !last {
			split_at = len(c.prog)
			append(&c.prog, Rx_Inst{op = .Split})
		}
		base := len(c.prog)
		rx_append_relative(c, b, base)
		if !last {
			jmp := len(c.prog)
			append(&c.prog, Rx_Inst{op = .Jmp})
			append(&jmp_fixups, jmp)
			c.prog[split_at].x = split_at + 1
			c.prog[split_at].y = len(c.prog)
		}
	}
	end := len(c.prog)
	for j in jmp_fixups { c.prog[j].x = end }
}

// concatenation of pieces until '|' or ')' or end
@(private = "file")
rx_compile_concat :: proc(c: ^Rx_Compiler) {
	for {
		ch := rx_peek(c)
		if ch == -1 || ch == '|' || ch == ')' { break }
		rx_compile_piece(c)
		if !c.ok { break }
	}
}

// a single atom plus an optional quantifier
@(private = "file")
rx_compile_piece :: proc(c: ^Rx_Compiler) {
	atom_start := len(c.prog)
	rx_compile_atom(c)
	if !c.ok { return }
	q := rx_peek(c)
	lazy := false
	switch q {
	case '*', '+', '?':
		c.pos += 1
		if rx_peek(c) == '?' { lazy = true; c.pos += 1 }
		rx_apply_quant(c, atom_start, q, lazy, 0, 0)
	case '{':
		// {m}, {m,}, {m,n}
		save := c.pos
		c.pos += 1
		m, has_m := rx_read_int(c)
		n := m
		open_n := false
		if rx_peek(c) == ',' {
			c.pos += 1
			open_n = true
			if nn, has_n := rx_read_int(c); has_n { n = nn; open_n = false }
		}
		if !has_m || rx_peek(c) != '}' {
			c.pos = save   // not a quantifier, treat '{' literally (already emitted as atom? no) — emit literal
			rx_emit_char(c, '{')
			return
		}
		c.pos += 1
		if rx_peek(c) == '?' { lazy = true; c.pos += 1 }
		rx_apply_repeat(c, atom_start, m, n, open_n, lazy)
	}
}

@(private = "file")
rx_read_int :: proc(c: ^Rx_Compiler) -> (int, bool) {
	start := c.pos
	v := 0
	for rx_peek(c) >= '0' && rx_peek(c) <= '9' { v = v * 10 + int(c.src[c.pos] - '0'); c.pos += 1 }
	return v, c.pos > start
}

@(private = "file")
rx_emit_char :: proc(c: ^Rx_Compiler, r: rune) { append(&c.prog, Rx_Inst{op = .Char, r = r}) }

// Apply a simple * + ? quantifier to the atom instructions in [atom_start, end).
@(private = "file")
rx_apply_quant :: proc(c: ^Rx_Compiler, atom_start: int, q: rune, lazy: bool, _m, _n: int) {
	atom := rx_extract(c, atom_start)
	switch q {
	case '?':
		split := len(c.prog)
		append(&c.prog, Rx_Inst{op = .Split})
		base := len(c.prog)
		rx_append_relative(c, atom, base)
		set_split(c, split, split + 1, len(c.prog), lazy)
	case '*':
		split := len(c.prog)
		append(&c.prog, Rx_Inst{op = .Split})
		base := len(c.prog)
		rx_append_relative(c, atom, base)
		append(&c.prog, Rx_Inst{op = .Jmp, x = split})
		set_split(c, split, split + 1, len(c.prog), lazy)
	case '+':
		base := len(c.prog)
		rx_append_relative(c, atom, base)
		split := len(c.prog)
		append(&c.prog, Rx_Inst{op = .Split})
		set_split(c, split, base, len(c.prog), lazy)
	}
}

// {m,n}: unroll m required copies then (n-m) optional copies, or a '*'/'+' tail for an open upper bound.
@(private = "file")
rx_apply_repeat :: proc(c: ^Rx_Compiler, atom_start: int, m, n: int, open_n, lazy: bool) {
	atom := rx_extract(c, atom_start)
	// first, m mandatory copies
	for _ in 0 ..< m {
		base := len(c.prog)
		rx_append_relative(c, atom, base)
	}
	if open_n {
		// m.. : a '*' on the atom
		split := len(c.prog)
		append(&c.prog, Rx_Inst{op = .Split})
		base := len(c.prog)
		rx_append_relative(c, atom, base)
		append(&c.prog, Rx_Inst{op = .Jmp, x = split})
		set_split(c, split, split + 1, len(c.prog), lazy)
		return
	}
	// optional copies for the remaining (n-m)
	splits := make([dynamic]int, context.temp_allocator)
	for _ in m ..< n {
		split := len(c.prog)
		append(&c.prog, Rx_Inst{op = .Split})
		append(&splits, split)
		base := len(c.prog)
		rx_append_relative(c, atom, base)
	}
	end := len(c.prog)
	for s in splits { set_split(c, s, s + 1, end, lazy) }
}

@(private = "file")
set_split :: proc(c: ^Rx_Compiler, at, prefer, other: int, lazy: bool) {
	if lazy { c.prog[at].x = other; c.prog[at].y = prefer } else { c.prog[at].x = prefer; c.prog[at].y = other }
}

// Copy the instructions [from, len) out of the program (and truncate), for re-emission under a quantifier.
@(private = "file")
rx_extract :: proc(c: ^Rx_Compiler, from: int) -> []Rx_Inst {
	out := make([]Rx_Inst, len(c.prog) - from, context.temp_allocator)
	for i in from ..< len(c.prog) { out[i - from] = c.prog[i] }
	// record the original base so relative re-appends can rebase internal targets
	for &inst in out {
		#partial switch inst.op {
		case .Jmp: inst.x -= from
		case .Split: inst.x -= from; inst.y -= from
		}
	}
	resize(&c.prog, from)
	return out
}

@(private = "file")
rx_append_relative :: proc(c: ^Rx_Compiler, atom: []Rx_Inst, base: int) {
	for inst in atom {
		ni := inst
		#partial switch ni.op {
		case .Jmp: ni.x += base
		case .Split: ni.x += base; ni.y += base
		}
		append(&c.prog, ni)
	}
}

// an atom: group, class, escape, '.', or a literal
@(private = "file")
rx_compile_atom :: proc(c: ^Rx_Compiler) {
	ch := rx_peek(c)
	switch ch {
	case '(':
		c.pos += 1
		if rx_peek(c) == '?' {
			// non-capturing (?:...) — other (?...) forms are unsupported
			c.pos += 1
			if rx_peek(c) != ':' { c.ok = false; return }
			c.pos += 1
		}
		rx_compile_alt(c)
		if rx_peek(c) != ')' { c.ok = false; return }
		c.pos += 1
	case '[':
		rx_compile_class(c)
	case '.':
		c.pos += 1
		append(&c.prog, Rx_Inst{op = .Any})
	case '\\':
		c.pos += 1
		rx_compile_escape(c)
	case ')', '|', -1:
		c.ok = false
	case:
		c.pos += 1
		rx_emit_char(c, ch)
	}
}

@(private = "file")
rx_compile_escape :: proc(c: ^Rx_Compiler) {
	ch := rx_peek(c)
	if ch == -1 { c.ok = false; return }
	c.pos += 1
	switch ch {
	case 'd', 'D', 'w', 'W', 's', 'S':
		idx := len(c.classes)
		extra := make([dynamic]u8, context.allocator)
		append(&extra, u8(ch))
		append(&c.classes, Rx_Class{ranges = make([][2]rune, 0), extra = extra[:]})
		append(&c.prog, Rx_Inst{op = .Class, cls = idx})
	case 'n': rx_emit_char(c, '\n')
	case 'r': rx_emit_char(c, '\r')
	case 't': rx_emit_char(c, '\t')
	case 'f': rx_emit_char(c, '\f')
	case 'v': rx_emit_char(c, '\v')
	case '0': rx_emit_char(c, 0)
	case:
		rx_emit_char(c, ch)   // escaped metacharacter → literal
	}
}

@(private = "file")
rx_compile_class :: proc(c: ^Rx_Compiler) {
	c.pos += 1   // consume '['
	cls: Rx_Class
	ranges := make([dynamic][2]rune, context.allocator)
	extra := make([dynamic]u8, context.allocator)
	if rx_peek(c) == '^' { cls.negate = true; c.pos += 1 }
	for {
		ch := rx_peek(c)
		if ch == -1 { c.ok = false; break }
		if ch == ']' { c.pos += 1; break }
		if ch == '\\' {
			c.pos += 1
			e := rx_peek(c)
			if e == -1 { c.ok = false; break }
			c.pos += 1
			switch e {
			case 'd', 'D', 'w', 'W', 's', 'S': append(&extra, u8(e)); continue
			case 'n': ch = '\n'
			case 'r': ch = '\r'
			case 't': ch = '\t'
			case 'f': ch = '\f'
			case 'v': ch = '\v'
			case: ch = e
			}
		} else {
			c.pos += 1
		}
		lo := ch
		hi := ch
		if rx_peek(c) == '-' && c.pos + 1 < len(c.src) && c.src[c.pos + 1] != ']' {
			c.pos += 1
			e := rx_peek(c)
			if e == '\\' { c.pos += 1; e = rx_peek(c) }
			if e == -1 { c.ok = false; break }
			c.pos += 1
			hi = e
		}
		append(&ranges, [2]rune{lo, hi})
	}
	cls.ranges = ranges[:]
	cls.extra = extra[:]
	idx := len(c.classes)
	append(&c.classes, cls)
	append(&c.prog, Rx_Inst{op = .Class, cls = idx})
}

////////////////////////////////
// The VM.

@(private = "file")
shorthand_match :: proc(letter: u8, r: rune) -> bool {
	is_d := r >= '0' && r <= '9'
	is_w := is_d || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_'
	is_s := r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\f' || r == '\v' || r == 0x00A0 || r == 0xFEFF
	switch letter {
	case 'd': return is_d
	case 'D': return !is_d
	case 'w': return is_w
	case 'W': return !is_w
	case 's': return is_s
	case 'S': return !is_s
	}
	return false
}

@(private = "file")
class_match :: proc(rx: ^Regexp, cls: int, r: rune, fold: bool) -> bool {
	c := rx.classes[cls]
	matched := false
	for letter in c.extra { if shorthand_match(letter, r) { matched = true; break } }
	if !matched {
		for rg in c.ranges {
			if r >= rg[0] && r <= rg[1] { matched = true; break }
			if fold {
				fr := fold_rune(r)
				if fr >= fold_rune(rg[0]) && fr <= fold_rune(rg[1]) && rg[1] - rg[0] < 64 {
					// fold only for simple ASCII ranges to avoid surprises
					for x := rg[0]; x <= rg[1]; x += 1 { if fold_rune(x) == fr { matched = true; break } }
					if matched { break }
				}
			}
		}
	}
	return c.negate ? !matched : matched
}

@(private = "file")
fold_rune :: proc(r: rune) -> rune {
	if r >= 'A' && r <= 'Z' { return r + 32 }
	return r
}

// Matches the whole input `s` (as runes) against the compiled program, anchored at both ends. Returns true and the
// number of runes consumed (== len for a whole-string match). Backtracking with a bounded step budget.
@(private = "file")
Rx_VM :: struct {
	rx:    ^Regexp,
	input: []rune,
	fold:  bool,
	steps: int,
}

regexp_full_match :: proc(rx: ^Regexp, s: []rune, ignore_case: bool) -> bool {
	vm := Rx_VM{rx = rx, input = s, fold = ignore_case}
	return rx_run(&vm, 0, 0)
}

@(private = "file")
RX_STEP_BUDGET :: 2_000_000

@(private = "file")
rx_run :: proc(vm: ^Rx_VM, pc, sp: int) -> bool {
	pc := pc
	sp := sp
	for {
		vm.steps += 1
		if vm.steps > RX_STEP_BUDGET { return false }
		inst := vm.rx.prog[pc]
		switch inst.op {
		case .Match:
			return sp == len(vm.input)
		case .Char:
			if sp >= len(vm.input) { return false }
			r := vm.input[sp]
			if r == inst.r || (vm.fold && fold_rune(r) == fold_rune(inst.r)) { pc += 1; sp += 1; continue }
			return false
		case .Any:
			if sp >= len(vm.input) { return false }
			pc += 1; sp += 1; continue
		case .Class:
			if sp >= len(vm.input) { return false }
			if class_match(vm.rx, inst.cls, vm.input[sp], vm.fold) { pc += 1; sp += 1; continue }
			return false
		case .Jmp:
			pc = inst.x; continue
		case .Split:
			if rx_run(vm, inst.x, sp) { return true }
			pc = inst.y; continue
		case .Group_Start, .Save_Open:
			pc += 1; continue
		}
	}
}
