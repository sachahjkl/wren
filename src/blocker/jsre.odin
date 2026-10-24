package blocker

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The regular expressions of uBlock Origin's scriptlets and of `$replace=` filters are JavaScript regular expressions, and they
// replace text: captures, `$1` in the replacement, lazy quantifiers (`.*?`), look-ahead, back-references. The filter engine's own
// regex (adblock/regex.odin) only answers "does it match" and is linear-time; this one is a backtracking machine with a step budget (a
// hostile pattern costs `RE_MAX_STEPS` steps and then fails to match), so that the blocker can do natively, on the response or on the
// DOM, what the page would have done in JavaScript.
//
// Supported: literals, `.`, classes (ranges, `\d \w \s` and their negations, escapes), `^ $` (multiline with `m`), `\b \B`, groups
// (capturing, `(?: )`, named `(?<n> )`), alternation, `* + ? {n} {n,} {n,m}` greedy and lazy, `(?= ) (?! ) (?<= ) (?<! )`, `\1`
// back-references, `\n \r \t \uXXXX \xXX`. Flags: `i` `m` `s` (dot matches a newline) `g` (replace every match) `u` and `y` (accepted).

RE_MAX_STEPS :: 2_000_000
RE_MAX_PROGRAM :: 20_000
RE_MAX_CAPS :: 20

Re_Op :: enum u8 { Char, Any, Class, Split, Jmp, Save, Bol, Eol, Word_B, Not_Word_B, Back, Look, Look_End, Match }

Re_Inst :: struct {
	op:   Re_Op,
	x, y: i32,       // Split: preferred, other; Jmp: target; Save: slot; Back: group; Look: the pc after the sub-program
	r:    rune,      // Char; Class: index
	neg:  bool,      // Look
	behind: bool,    // Look
}

Re_Class :: struct { ranges: [dynamic][2]rune, neg: bool }

Jsre :: struct {
	prog:    []Re_Inst,
	classes: []Re_Class,
	ncap:    int,           // groups, the whole match excluded
	icase, multiline, dotall, global: bool,
	prefix:  string,        // a literal every match starts with ("" when none): the scan skips to it
}

Re_Match :: struct {
	n:    int,                         // groups + 1
	span: [RE_MAX_CAPS][2]int,         // [0] the whole match; -1 for a group that did not take part
}

jsre_destroy :: proc(re: ^Jsre) {
	if re == nil { return }
	delete(re.prog)
	for &c in re.classes { delete(c.ranges) }
	delete(re.classes)
	delete(re.prefix)
	free(re)
}

////////////////////////////////
// Parser (to a tree), then the program

@(private = "file")
Rn_Kind :: enum u8 { Empty, Char, Any, Class, Cat, Alt, Repeat, Group, Bol, Eol, Word_B, Not_Word_B, Back, Look }

@(private = "file")
Rn :: struct {
	kind:   Rn_Kind,
	a, b:   i32,          // children (Cat: a then b; Alt: a or b; Repeat/Group/Look: a)
	r:      rune,         // Char; Class: index; Group / Back: the group number
	lo, hi: int,          // Repeat (hi -1: unbounded)
	greedy: bool,
	neg:    bool,
	behind: bool,
	capture: bool,        // Group
}

@(private = "file")
Rp :: struct {
	src:     string,
	pos:     int,
	nodes:   [dynamic]Rn,
	classes: [dynamic]Re_Class,
	ncap:    int,
	icase:   bool,
	err:     bool,
	depth:   int,
}

@(private = "file")
rp_node :: proc(p: ^Rp, n: Rn) -> i32 { append(&p.nodes, n); return i32(len(p.nodes) - 1) }

@(private = "file")
rp_more :: proc(p: ^Rp) -> bool { return p.pos < len(p.src) }

@(private = "file")
rp_peek :: proc(p: ^Rp) -> u8 { return p.pos < len(p.src) ? p.src[p.pos] : 0 }

@(private = "file")
rp_alt :: proc(p: ^Rp) -> i32 {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > 60 { p.err = true; return rp_node(p, Rn{kind = .Empty}) }
	left := rp_cat(p)
	if rp_more(p) && rp_peek(p) == '|' {
		p.pos += 1
		right := rp_alt(p)
		return rp_node(p, Rn{kind = .Alt, a = left, b = right})
	}
	return left
}

@(private = "file")
rp_cat :: proc(p: ^Rp) -> i32 {
	first := i32(-1)
	for rp_more(p) && rp_peek(p) != '|' && rp_peek(p) != ')' && !p.err {
		item := rp_quantified(p)
		if first < 0 { first = item } else { first = rp_node(p, Rn{kind = .Cat, a = first, b = item}) }
	}
	if first < 0 { return rp_node(p, Rn{kind = .Empty}) }
	return first
}

@(private = "file")
rp_int :: proc(p: ^Rp) -> (n: int, ok: bool) {
	start := p.pos
	for rp_more(p) && rp_peek(p) >= '0' && rp_peek(p) <= '9' { n = n * 10 + int(rp_peek(p) - '0'); p.pos += 1; if n > 1000 { n = 1000 } }
	return n, p.pos > start
}

@(private = "file")
rp_quantified :: proc(p: ^Rp) -> i32 {
	atom := rp_atom(p)
	if p.err || !rp_more(p) { return atom }
	lo, hi := 0, -1
	switch rp_peek(p) {
	case '*': lo, hi = 0, -1; p.pos += 1
	case '+': lo, hi = 1, -1; p.pos += 1
	case '?': lo, hi = 0, 1; p.pos += 1
	case '{':
		save := p.pos
		p.pos += 1
		n, ok := rp_int(p)
		if !ok { p.pos = save; return atom }   // a literal brace
		lo, hi = n, n
		if rp_more(p) && rp_peek(p) == ',' {
			p.pos += 1
			if m, ok2 := rp_int(p); ok2 { hi = m } else { hi = -1 }
		}
		if !rp_more(p) || rp_peek(p) != '}' { p.pos = save; return atom }
		p.pos += 1
	case: return atom
	}
	greedy := true
	if rp_more(p) && rp_peek(p) == '?' { greedy = false; p.pos += 1 }
	return rp_node(p, Rn{kind = .Repeat, a = atom, lo = lo, hi = hi, greedy = greedy})
}

@(private = "file")
class_add :: proc(c: ^Re_Class, lo, hi: rune) { append(&c.ranges, [2]rune{lo, hi}) }

@(private = "file")
class_escape :: proc(c: ^Re_Class, e: u8) -> bool {
	switch e {
	case 'd': class_add(c, '0', '9')
	case 'w': class_add(c, '0', '9'); class_add(c, 'a', 'z'); class_add(c, 'A', 'Z'); class_add(c, '_', '_')
	case 's':
		class_add(c, '\t', '\r'); class_add(c, ' ', ' '); class_add(c, 0xa0, 0xa0); class_add(c, 0x2028, 0x2029); class_add(c, 0xfeff, 0xfeff)
	case: return false
	}
	return true
}

// The complement of a class given as ranges (`\D`, `\W`, `\S` inside a bigger class).
@(private = "file")
class_add_negated :: proc(c: ^Re_Class, e: u8) {
	tmp: Re_Class
	defer delete(tmp.ranges)
	class_escape(&tmp, e + ('a' - 'A'))
	// sort by start (few ranges: insertion sort)
	for i in 1 ..< len(tmp.ranges) {
		j := i
		for j > 0 && tmp.ranges[j][0] < tmp.ranges[j - 1][0] { tmp.ranges[j], tmp.ranges[j - 1] = tmp.ranges[j - 1], tmp.ranges[j]; j -= 1 }
	}
	next: rune = 0
	for r in tmp.ranges {
		if r[0] > next { class_add(c, next, r[0] - 1) }
		if r[1] + 1 > next { next = r[1] + 1 }
	}
	class_add(c, next, 0x10ffff)
}

@(private = "file")
hex_val :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

// After a backslash (already consumed) that is not a class escape or a back-reference: the character it stands for.
@(private = "file")
rp_escape_char :: proc(p: ^Rp) -> rune {
	c := rp_peek(p)
	p.pos += 1
	switch c {
	case 'n': return '\n'
	case 'r': return '\r'
	case 't': return '\t'
	case 'f': return '\f'
	case 'v': return '\v'
	case '0': return 0
	case 'x':
		if p.pos + 2 <= len(p.src) {
			a, b := hex_val(p.src[p.pos]), hex_val(p.src[p.pos + 1])
			if a >= 0 && b >= 0 { p.pos += 2; return rune(a * 16 + b) }
		}
		return 'x'
	case 'u':
		if p.pos + 4 <= len(p.src) {
			v := 0
			ok := true
			for i in 0 ..< 4 { h := hex_val(p.src[p.pos + i]); if h < 0 { ok = false; break }; v = v * 16 + h }
			if ok { p.pos += 4; return rune(v) }
		}
		return 'u'
	}
	if c >= 0x80 { p.pos -= 1; r, n := utf8.decode_rune_in_string(p.src[p.pos:]); p.pos += n; return r }
	return rune(c)
}

@(private = "file")
rp_class :: proc(p: ^Rp) -> i32 {
	c: Re_Class
	if rp_more(p) && rp_peek(p) == '^' { c.neg = true; p.pos += 1 }
	first := true
	for {
		if !rp_more(p) { p.err = true; break }
		if rp_peek(p) == ']' && !first { p.pos += 1; break }
		first = false
		lo: rune
		if rp_peek(p) == '\\' {
			p.pos += 1
			if !rp_more(p) { p.err = true; break }
			e := rp_peek(p)
			if class_escape(&c, e) { p.pos += 1; continue }
			if e == 'D' || e == 'W' || e == 'S' { p.pos += 1; class_add_negated(&c, e); continue }
			if e == 'b' { p.pos += 1; lo = 8 } else { lo = rp_escape_char(p) }
		} else {
			r, n := utf8.decode_rune_in_string(p.src[p.pos:])
			p.pos += n
			lo = r
		}
		hi := lo
		if p.pos + 1 < len(p.src) && p.src[p.pos] == '-' && p.src[p.pos + 1] != ']' {
			p.pos += 1
			if rp_peek(p) == '\\' {
				p.pos += 1
				hi = rp_escape_char(p)
			} else {
				r, n := utf8.decode_rune_in_string(p.src[p.pos:])
				p.pos += n
				hi = r
			}
			if hi < lo { p.err = true }
		}
		class_add(&c, lo, hi)
	}
	append(&p.classes, c)
	return rp_node(p, Rn{kind = .Class, r = rune(len(p.classes) - 1)})
}

@(private = "file")
rp_atom :: proc(p: ^Rp) -> i32 {
	c := rp_peek(p)
	switch c {
	case '(':
		p.pos += 1
		capture := true
		look, neg, behind := false, false, false
		group := 0
		if rp_peek(p) == '?' {
			p.pos += 1
			switch rp_peek(p) {
			case ':': p.pos += 1; capture = false
			case '=': p.pos += 1; capture = false; look = true
			case '!': p.pos += 1; capture = false; look, neg = true, true
			case '<':
				p.pos += 1
				if rp_peek(p) == '=' { p.pos += 1; capture = false; look, behind = true, true } else if rp_peek(p) == '!' { p.pos += 1; capture = false; look, neg, behind = true, true, true } else {
					// a named group: the name is skipped, the group is numbered
					for rp_more(p) && rp_peek(p) != '>' { p.pos += 1 }
					p.pos += 1
				}
			case: p.err = true
			}
		}
		if capture {
			p.ncap += 1
			group = p.ncap
			if group >= RE_MAX_CAPS { p.err = true }
		}
		inner := rp_alt(p)
		if !rp_more(p) || rp_peek(p) != ')' { p.err = true; return inner }
		p.pos += 1
		if look { return rp_node(p, Rn{kind = .Look, a = inner, neg = neg, behind = behind}) }
		return rp_node(p, Rn{kind = .Group, a = inner, r = rune(group), capture = capture})
	case '[': p.pos += 1; return rp_class(p)
	case '.': p.pos += 1; return rp_node(p, Rn{kind = .Any})
	case '^': p.pos += 1; return rp_node(p, Rn{kind = .Bol})
	case '$': p.pos += 1; return rp_node(p, Rn{kind = .Eol})
	case '\\':
		p.pos += 1
		if !rp_more(p) { p.err = true; return rp_node(p, Rn{kind = .Empty}) }
		e := rp_peek(p)
		switch e {
		case 'b': p.pos += 1; return rp_node(p, Rn{kind = .Word_B})
		case 'B': p.pos += 1; return rp_node(p, Rn{kind = .Not_Word_B})
		case 'd', 'w', 's':
			p.pos += 1
			cl: Re_Class
			class_escape(&cl, e)
			append(&p.classes, cl)
			return rp_node(p, Rn{kind = .Class, r = rune(len(p.classes) - 1)})
		case 'D', 'W', 'S':
			p.pos += 1
			cl: Re_Class
			class_escape(&cl, e + ('a' - 'A'))
			cl.neg = true
			append(&p.classes, cl)
			return rp_node(p, Rn{kind = .Class, r = rune(len(p.classes) - 1)})
		case '1' ..= '9':
			n, _ := rp_int(p)
			return rp_node(p, Rn{kind = .Back, r = rune(n)})
		}
		return rp_node(p, Rn{kind = .Char, r = rp_escape_char(p)})
	case ')', '|': p.err = true; return rp_node(p, Rn{kind = .Empty})
	case '*', '+', '?': p.err = true; return rp_node(p, Rn{kind = .Empty})
	}
	r, n := utf8.decode_rune_in_string(p.src[p.pos:])
	p.pos += n
	return rp_node(p, Rn{kind = .Char, r = r})
}

@(private = "file")
emit_node :: proc(p: ^Rp, prog: ^[dynamic]Re_Inst, ni: i32) {
	if len(prog) > RE_MAX_PROGRAM { p.err = true; return }
	n := p.nodes[ni]
	switch n.kind {
	case .Empty:
	case .Char: append(prog, Re_Inst{op = .Char, r = n.r})
	case .Any: append(prog, Re_Inst{op = .Any})
	case .Class: append(prog, Re_Inst{op = .Class, r = n.r})
	case .Bol: append(prog, Re_Inst{op = .Bol})
	case .Eol: append(prog, Re_Inst{op = .Eol})
	case .Word_B: append(prog, Re_Inst{op = .Word_B})
	case .Not_Word_B: append(prog, Re_Inst{op = .Not_Word_B})
	case .Back: append(prog, Re_Inst{op = .Back, x = i32(n.r)})
	case .Cat: emit_node(p, prog, n.a); emit_node(p, prog, n.b)
	case .Group:
		if n.capture { append(prog, Re_Inst{op = .Save, x = i32(n.r) * 2}) }
		emit_node(p, prog, n.a)
		if n.capture { append(prog, Re_Inst{op = .Save, x = i32(n.r) * 2 + 1}) }
	case .Alt:
		sp := len(prog)
		append(prog, Re_Inst{op = .Split})
		prog[sp].x = i32(len(prog))
		emit_node(p, prog, n.a)
		jp := len(prog)
		append(prog, Re_Inst{op = .Jmp})
		prog[sp].y = i32(len(prog))
		emit_node(p, prog, n.b)
		prog[jp].x = i32(len(prog))
	case .Look:
		lp := len(prog)
		append(prog, Re_Inst{op = .Look, neg = n.neg, behind = n.behind})
		emit_node(p, prog, n.a)
		append(prog, Re_Inst{op = .Look_End})
		prog[lp].x = i32(len(prog))
	case .Repeat:
		for _ in 0 ..< n.lo { emit_node(p, prog, n.a); if p.err { return } }
		if n.hi < 0 {
			// L: split body, exit; body; jmp L
			l := len(prog)
			append(prog, Re_Inst{op = .Split})
			body := i32(len(prog))
			emit_node(p, prog, n.a)
			append(prog, Re_Inst{op = .Jmp, x = i32(l)})
			exit := i32(len(prog))
			if n.greedy { prog[l].x, prog[l].y = body, exit } else { prog[l].x, prog[l].y = exit, body }
		} else {
			splits := make([dynamic]int, context.temp_allocator)
			for _ in 0 ..< n.hi - n.lo {
				append(&splits, len(prog))
				append(prog, Re_Inst{op = .Split})
				prog[splits[len(splits) - 1]].x = i32(len(prog))   // the body follows
				emit_node(p, prog, n.a)
				if p.err { return }
			}
			exit := i32(len(prog))
			for s in splits {
				body := prog[s].x
				if n.greedy { prog[s].x, prog[s].y = body, exit } else { prog[s].x, prog[s].y = exit, body }
			}
		}
	}
}

// Compiles `pattern` with `flags` ("gimsuy"). nil when it is not a valid pattern (or too big).
jsre_compile :: proc(pattern, flags: string) -> ^Jsre {
	p := Rp{src = pattern}
	defer { delete(p.nodes); }
	for f in transmute([]u8)flags {
		switch f {
		case 'i': p.icase = true
		case 'g', 'm', 's', 'u', 'y', 'd':
		case: return nil
		}
	}
	root := rp_alt(&p)
	if p.err || p.pos != len(p.src) {
		for &c in p.classes { delete(c.ranges) }
		delete(p.classes)
		return nil
	}
	prog := make([dynamic]Re_Inst)
	emit_node(&p, &prog, root)
	append(&prog, Re_Inst{op = .Match})
	if p.err {
		delete(prog)
		for &c in p.classes { delete(c.ranges) }
		delete(p.classes)
		return nil
	}
	re := new(Jsre)
	re.prog = prog[:]
	re.classes = p.classes[:]
	re.ncap = p.ncap
	for f in transmute([]u8)flags {
		switch f {
		case 'i': re.icase = true
		case 'm': re.multiline = true
		case 's': re.dotall = true
		case 'g': re.global = true
		}
	}
	// a literal every match begins with: the first run of Char instructions (not under a case fold)
	if !re.icase {
		sb := strings.builder_make()
		for ins in re.prog {
			if ins.op == .Char { strings.write_rune(&sb, ins.r) } else if ins.op == .Save { continue } else { break }
		}
		re.prefix = strings.to_string(sb)
		if len(re.prefix) == 0 { strings.builder_destroy(&sb) }
	}
	return re
}

////////////////////////////////
// The machine

@(private = "file")
Re_Frame :: struct {
	pc:   i32,
	pos:  int,
	slot: i32,    // -1: an alternative to try; else a capture slot to restore to `pos`
}

@(private = "file")
Re_Run :: struct {
	re:    ^Jsre,
	text:  string,
	caps:  [RE_MAX_CAPS * 2]int,
	steps: int,
}

@(private = "file")
is_word_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
fold :: #force_inline proc(r: rune) -> rune {
	if r < 0x80 { return (r >= 'A' && r <= 'Z') ? r + 32 : r }
	return unicode.to_lower(r)
}

@(private = "file")
class_has :: proc(c: ^Re_Class, r: rune, icase: bool) -> bool {
	in_set := false
	for rg in c.ranges {
		if r >= rg[0] && r <= rg[1] { in_set = true; break }
		if icase {
			lo, up := unicode.to_lower(r), unicode.to_upper(r)
			if (lo >= rg[0] && lo <= rg[1]) || (up >= rg[0] && up <= rg[1]) { in_set = true; break }
		}
	}
	return in_set != c.neg
}

@(private = "file")
is_line_end :: #force_inline proc(r: rune) -> bool { return r == '\n' || r == '\r' || r == 0x2028 || r == 0x2029 }

// Runs the program from `pc0` at `pos0`. The position the match ended at, and whether it matched. `must_end` >= 0: a look-behind's
// sub-program has to end exactly there.
@(private = "file")
re_vm :: proc(run: ^Re_Run, pc0: i32, pos0: int, must_end: int) -> (int, bool) {
	re := run.re
	text := run.text
	stack := make([dynamic]Re_Frame, 0, 32, context.temp_allocator)
	pc, pos := pc0, pos0
	for {
		run.steps += 1
		if run.steps > RE_MAX_STEPS { return 0, false }
		ins := &re.prog[pc]
		ok := true
		switch ins.op {
		case .Char:
			if pos < len(text) {
				r: rune = ---
				n: int = ---
				if text[pos] < 0x80 { r, n = rune(text[pos]), 1 } else { r, n = utf8.decode_rune_in_string(text[pos:]) }
				if r == ins.r || (re.icase && fold(r) == fold(ins.r)) { pos += n; pc += 1 } else { ok = false }
			} else { ok = false }
		case .Any:
			if pos < len(text) {
				r, n := utf8.decode_rune_in_string(text[pos:])
				if !re.dotall && is_line_end(r) { ok = false } else { pos += n; pc += 1 }
			} else { ok = false }
		case .Class:
			if pos < len(text) {
				r, n := utf8.decode_rune_in_string(text[pos:])
				if class_has(&re.classes[ins.r], r, re.icase) { pos += n; pc += 1 } else { ok = false }
			} else { ok = false }
		case .Split:
			append(&stack, Re_Frame{pc = ins.y, pos = pos, slot = -1})
			pc = ins.x
		case .Jmp: pc = ins.x
		case .Save:
			append(&stack, Re_Frame{pc = 0, pos = run.caps[ins.x], slot = ins.x})
			run.caps[ins.x] = pos
			pc += 1
		case .Bol:
			if pos == 0 || (re.multiline && pos > 0 && is_line_end(rune(text[pos - 1]))) { pc += 1 } else { ok = false }
		case .Eol:
			if pos == len(text) || (re.multiline && is_line_end(rune(text[pos]))) { pc += 1 } else { ok = false }
		case .Word_B, .Not_Word_B:
			a := pos > 0 && is_word_byte(text[pos - 1])
			b := pos < len(text) && is_word_byte(text[pos])
			if (a != b) == (ins.op == .Word_B) { pc += 1 } else { ok = false }
		case .Back:
			s, e := run.caps[ins.x * 2], run.caps[ins.x * 2 + 1]
			if s < 0 || e < 0 { pc += 1 } else {
				sub := text[s:e]
				if pos + len(sub) <= len(text) && (text[pos:pos + len(sub)] == sub || (re.icase && strings.equal_fold(text[pos:pos + len(sub)], sub))) { pos += len(sub); pc += 1 } else { ok = false }
			}
		case .Look:
			found := false
			if !ins.behind {
				_, found = re_vm(run, pc + 1, pos, -1)
			} else {
				for start := pos; start >= max(0, pos - 512); start -= 1 {
					if end, m := re_vm(run, pc + 1, start, pos); m && end == pos { found = true; break }
				}
			}
			if found != ins.neg { pc = ins.x } else { ok = false }
		case .Look_End:
			if must_end >= 0 && pos != must_end { ok = false } else { return pos, true }
		case .Match:
			return pos, true
		}
		if ok { continue }
		// backtrack
		for {
			if len(stack) == 0 { return 0, false }
			fr := pop(&stack)
			if fr.slot >= 0 { run.caps[fr.slot] = fr.pos; continue }
			pc, pos = fr.pc, fr.pos
			break
		}
	}
}

// The first match at or after `from`. `m` holds the spans.
jsre_find :: proc(re: ^Jsre, text: string, from: int, m: ^Re_Match) -> bool {
	run := Re_Run{re = re, text = text}
	start := from
	for start <= len(text) {
		if re.prefix != "" {
			i := strings.index(text[start:], re.prefix)
			if i < 0 { return false }
			start += i
		}
		for i in 0 ..< len(run.caps) { run.caps[i] = -1 }
		if end, ok := re_vm(&run, 0, start, -1); ok {
			m.n = re.ncap + 1
			m.span[0] = {start, end}
			for g in 1 ..= re.ncap {
				s, e := run.caps[g * 2], run.caps[g * 2 + 1]
				m.span[g] = (s >= 0 && e >= 0) ? [2]int{s, e} : [2]int{-1, -1}
			}
			return true
		}
		if run.steps > RE_MAX_STEPS { return false }
		if start >= len(text) { break }
		_, n := utf8.decode_rune_in_string(text[start:])
		start += max(n, 1)
	}
	return false
}

jsre_test :: proc(re: ^Jsre, text: string) -> bool {
	m: Re_Match
	return jsre_find(re, text, 0, &m)
}

// String.prototype.replace: `$$`, `$&`, `` $` ``, `$'`, `$1`...`$99`. `max` > 0 caps the number of replacements (0: every match when the regex
// is global, else the first).
jsre_replace :: proc(re: ^Jsre, text, repl: string, max_count := 0, allocator := context.allocator) -> (out: string, count: int) {
	limit := max_count
	if limit <= 0 { limit = re.global ? max(int) : 1 }
	sb := strings.builder_make(allocator)
	last := 0
	pos := 0
	m: Re_Match
	for count < limit && pos <= len(text) && jsre_find(re, text, pos, &m) {
		s, e := m.span[0][0], m.span[0][1]
		strings.write_string(&sb, text[last:s])
		i := 0
		for i < len(repl) {
			c := repl[i]
			if c != '$' || i + 1 >= len(repl) { strings.write_byte(&sb, c); i += 1; continue }
			d := repl[i + 1]
			switch {
			case d == '$': strings.write_byte(&sb, '$'); i += 2
			case d == '&': strings.write_string(&sb, text[s:e]); i += 2
			case d == '`': strings.write_string(&sb, text[:s]); i += 2
			case d == '\'': strings.write_string(&sb, text[e:]); i += 2
			case d >= '0' && d <= '9':
				g := int(d - '0')
				used := 2
				if i + 2 < len(repl) && repl[i + 2] >= '0' && repl[i + 2] <= '9' && g * 10 + int(repl[i + 2] - '0') < m.n { g = g * 10 + int(repl[i + 2] - '0'); used = 3 }
				if g >= 1 && g < m.n {
					if m.span[g][0] >= 0 { strings.write_string(&sb, text[m.span[g][0]:m.span[g][1]]) }
					i += used
				} else { strings.write_byte(&sb, '$'); i += 1 }
			case: strings.write_byte(&sb, '$'); i += 1
			}
		}
		last = e
		count += 1
		pos = e
		if e == s {   // an empty match moves on by a character
			if pos >= len(text) { break }
			_, n := utf8.decode_rune_in_string(text[pos:])
			pos += n
		}
	}
	strings.write_string(&sb, text[last:])
	return strings.to_string(sb), count
}

////////////////////////////////
// The patterns of scriptlet arguments

// `text`, `/regex/flags` or `!text` (negated): the argument language of uBlock Origin's scriptlets. An empty pattern matches everything.
Needle :: struct {
	re:   ^Jsre,
	text: string,     // owned
	neg:  bool,
	any:  bool,
	bad:  bool,       // a /regex/ that does not compile: never matches
}

needle_make :: proc(pattern: string) -> Needle {
	n: Needle
	p := pattern
	if p == "" { n.any = true; return n }
	if p[0] == '!' { n.neg = true; p = p[1:] }
	if len(p) >= 2 && p[0] == '/' {
		if end := strings.last_index_byte(p, '/'); end > 0 {
			flags := p[end + 1:]
			ok := true
			for c in transmute([]u8)flags { if !strings.contains_rune("gimsuyd", rune(c)) { ok = false } }
			if ok {
				n.re = jsre_compile(p[1:end], flags)
				n.bad = n.re == nil
				return n
			}
		}
	}
	n.text = strings.clone(p)
	return n
}

needle_destroy :: proc(n: ^Needle) { jsre_destroy(n.re); delete(n.text); n^ = {} }

needle_test :: proc(n: ^Needle, s: string) -> bool {
	if n.any { return true }
	hit := false
	switch {
	case n.bad: hit = false
	case n.re != nil: hit = jsre_test(n.re, s)
	case: hit = strings.contains(s, n.text)
	}
	return hit != n.neg
}

// A replace pattern: `/regex/flags`, else the text itself (every occurrence), as uBlock Origin's replace scriptlets read it.
pattern_regex :: proc(pattern: string, extra_flags := "g") -> ^Jsre {
	if len(pattern) >= 2 && pattern[0] == '/' {
		if end := strings.last_index_byte(pattern, '/'); end > 0 { return jsre_compile(pattern[1:end], pattern[end + 1:]) }
	}
	sb := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)pattern {
		if strings.contains_rune(".*+?^${}()|[]\\/", rune(c)) { strings.write_byte(&sb, '\\') }
		strings.write_byte(&sb, c)
	}
	return jsre_compile(strings.to_string(sb), extra_flags)
}
