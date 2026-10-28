package regexp

// ECMAScript pattern -> AST. The parser handles the full grammar: alternation, groups (capturing, non-capturing,
// named), the assertions ^ $ \b \B, lookahead/lookbehind (positive and negative), character classes with ranges
// and the class escapes \d \D \w \W \s \S and \p{} \P{}, back references (numbered and named), quantifiers
// * + ? {n} {n,} {n,m} with an optional lazy `?`, and the escape forms. In Annex B mode (no u/v flag) it also
// accepts the web-reality leniencies: a lone `{`, invalid back references treated as octal/identity escapes,
// `]` and `}` as literals, etc.
//
// The AST nodes carry everything the compiler needs; character sets are resolved to unicode.Char_Range at
// compile time (parser stores the class items and lets the compiler build the range so case folding happens once).

import "core:strings"
import "core:unicode/utf8"
import uni "wb:engine/unicode"

Node_Kind :: enum u8 {
	Empty,
	Char,        // single code point
	Any,         // .
	Class,       // [...] or a class escape; resolved to a Char_Range
	Concat,      // sequence of children
	Alt,         // alternation of children
	Group,       // capturing/non-capturing group; `capture_index` > 0 if capturing
	Quant,       // child repeated
	Assert_Start,// ^
	Assert_End,  // $
	Word_Boundary,
	Not_Word_Boundary,
	Lookahead,   // neg flag
	Lookbehind,  // neg flag
	Back_Ref,    // numbered
	Back_Ref_Named,
}

Node :: struct {
	kind:          Node_Kind,
	ch:            rune,          // Char
	class:         ^Class_Spec,   // Class
	children:      [dynamic]^Node,// Concat / Alt / Group / Lookahead / Lookbehind wrap a single child in children[0]
	capture_index: int,           // Group (0 = non-capturing)
	group_name:    string,        // Group (named), Back_Ref_Named
	// Quant
	min, max:      int,           // max = -1 means unbounded
	greedy:        bool,
	// Back_Ref
	ref_index:     int,
	neg:           bool,          // Lookahead / Lookbehind
}

// A character class before range resolution: a list of items (single chars, ranges, class escapes, \p props)
// and whether it is negated. The compiler turns this into a unicode.Char_Range honoring the i/u/v flags.
Class_Spec :: struct {
	items:    [dynamic]Class_Item,
	negated:  bool,
	// `v`-flag set operations: nested classes combined by && or -- . For simplicity the parser stores a flat
	// list plus an operator; full nested set arithmetic is represented by `op` and `operands`.
	op:       Set_Operator,
	operands: [dynamic]^Class_Spec,
}

Set_Operator :: enum u8 { None, Intersection, Subtraction }

Class_Item_Kind :: enum u8 { Char, Range, Digit, Not_Digit, Word, Not_Word, Space, Not_Space, Prop, Not_Prop }

Class_Item :: struct {
	kind:       Class_Item_Kind,
	lo, hi:     rune,   // Char: lo==hi; Range: lo..hi
	prop_name:  string, // Prop / Not_Prop
	prop_value: string,
}

Parser :: struct {
	src:        string,
	pos:        int,
	flags:      Flags,
	allocator:  Allocator,
	// Capture bookkeeping.
	capture_count: int, // running index assigned while building nodes
	total_captures: int, // grand total from the prescan (for forward back references)
	group_names:   [dynamic]string,
	group_indices: [dynamic]int,
	// Error reporting.
	err:        string,
	err_pos:    int,
	// Named-group references seen before their definition (resolved after a first counting pass).
	// We do a pre-scan for group count + names so forward references work.
}

@(private)
p_fail :: proc(p: ^Parser, msg: string) -> ^Node {
	if p.err == "" {
		p.err = msg
		p.err_pos = p.pos
	}
	return nil
}

@(private)
p_eof :: proc(p: ^Parser) -> bool {
	return p.pos >= len(p.src)
}

@(private)
p_peek :: proc(p: ^Parser) -> rune {
	if p.pos >= len(p.src) { return -1 }
	r, _ := utf8.decode_rune_in_string(p.src[p.pos:])
	return r
}

@(private)
p_peek_byte :: proc(p: ^Parser) -> u8 {
	if p.pos >= len(p.src) { return 0 }
	return p.src[p.pos]
}

@(private)
p_next :: proc(p: ^Parser) -> rune {
	if p.pos >= len(p.src) { return -1 }
	r, sz := utf8.decode_rune_in_string(p.src[p.pos:])
	p.pos += sz
	return r
}

@(private)
p_eat :: proc(p: ^Parser, b: u8) -> bool {
	if p.pos < len(p.src) && p.src[p.pos] == b {
		p.pos += 1
		return true
	}
	return false
}

@(private)
new_node :: proc(p: ^Parser, kind: Node_Kind) -> ^Node {
	n := new(Node, p.allocator)
	n.kind = kind
	return n
}

// Pre-scan the pattern to count capturing groups and collect named-group names, so numbered and named back
// references that appear before their group still resolve. Mirrors QuickJS's two-pass approach.
@(private)
prescan_groups :: proc(p: ^Parser) {
	i := 0
	src := p.src
	in_class := false
	for i < len(src) {
		c := src[i]
		if c == '\\' {
			i += 2
			continue
		}
		if in_class {
			if c == ']' { in_class = false }
			i += 1
			continue
		}
		switch c {
		case '[':
			in_class = true
			i += 1
		case '(':
			// Distinguish capturing "(" and "(?..." forms.
			if i + 1 < len(src) && src[i + 1] == '?' {
				// (?: , (?= , (?! , (?<= , (?<! , (?<name>
				if i + 2 < len(src) && src[i + 2] == '<' &&
				   i + 3 < len(src) && src[i + 3] != '=' && src[i + 3] != '!' {
					// Named capturing group.
					p.capture_count += 1
					idx := p.capture_count
					j := i + 3
					start := j
					for j < len(src) && src[j] != '>' { j += 1 }
					name := strings.clone(src[start:j], p.allocator)
					append(&p.group_names, name)
					append(&p.group_indices, idx)
					i = j
				} else {
					i += 1
				}
			} else {
				p.capture_count += 1
				i += 1
			}
		case:
			i += 1
		}
	}
	p.total_captures = p.capture_count
	p.pos = 0
}
