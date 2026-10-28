package regexp

// AST -> bytecode. The compiler walks the node tree emitting opcodes, lowering quantifiers to split/goto/loop
// forms, resolving character classes to interval sets (one entry in the range table per class, already case-
// folded when the i flag is set), and reversing the body of a lookbehind so the interpreter can walk it
// backwards with the same forward engine.
//
// Public entry: compile(pattern, flags, allocator).

import "core:strings"
import "core:unicode/utf8"
import uni "wb:engine/unicode"

Compiler :: struct {
	code:        [dynamic]u8,
	ranges:      [dynamic]uni.Char_Range, // range table: Range/Range_Not operands index into this
	flags:       Flags,
	allocator:   Allocator,
	reverse:     bool, // true while compiling the body of a lookbehind: emit atoms in reverse
	// Named-group tables (borrowed from the parser) for resolving \k<name> during compilation.
	group_names:   []string,
	group_indices: []int,
	err:         string,
	err_pos:     int,
}

compile :: proc(pattern: string, flags: Flags, allocator := context.allocator) -> (re: Regexp, err: Error) {
	p := Parser{src = pattern, flags = flags, allocator = allocator}
	root := parse_pattern(&p)
	if p.err != "" {
		return {}, Error{message = p.err, pos = p.err_pos}
	}

	c := Compiler{flags = flags, allocator = allocator}
	c.code = make([dynamic]u8, allocator)
	c.ranges = make([dynamic]uni.Char_Range, allocator)
	c.group_names = p.group_names[:]
	c.group_indices = p.group_indices[:]

	// Whole-match capture is group 0.
	emit_op(&c, .Save_Start)
	emit_u16(&c, 0)
	compile_node(&c, root)
	emit_op(&c, .Save_End)
	emit_u16(&c, 0)
	emit_op(&c, .Match)

	if c.err != "" {
		for &r in c.ranges { uni.cr_destroy(&r) }
		delete(c.ranges)
		delete(c.code)
		return {}, Error{message = c.err, pos = c.err_pos}
	}

	re.bytecode = c.code
	re.flags = flags
	re.capture_count = p.total_captures + 1
	re.allocator = allocator
	re.ranges = c.ranges
	// Take ownership of the parser's cloned named-group tables.
	re.group_names = p.group_names
	re.group_indices = p.group_indices
	return
}

@(private)
c_fail :: proc(c: ^Compiler, msg: string) {
	if c.err == "" { c.err = msg }
}

@(private)
compile_node :: proc(c: ^Compiler, n: ^Node) {
	if n == nil { return }
	switch n.kind {
	case .Empty:
		// nothing
	case .Char:
		compile_char(c, n.ch)
	case .Any:
		emit_op(c, .Dot_All in c.flags ? .Any_All : .Any)
	case .Class:
		compile_class(c, n.class)
	case .Concat:
		if c.reverse {
			#reverse for child in n.children { compile_node(c, child) }
		} else {
			for child in n.children { compile_node(c, child) }
		}
	case .Alt:
		compile_alt(c, n)
	case .Group:
		compile_group(c, n)
	case .Quant:
		compile_quant(c, n)
	case .Assert_Start:
		emit_op(c, .Multiline in c.flags ? .Line_Start_M : .Line_Start)
	case .Assert_End:
		emit_op(c, .Multiline in c.flags ? .Line_End_M : .Line_End)
	case .Word_Boundary:
		emit_op(c, .Word_Boundary)
	case .Not_Word_Boundary:
		emit_op(c, .Not_Word_Boundary)
	case .Lookahead:
		compile_lookaround(c, n, false)
	case .Lookbehind:
		compile_lookaround(c, n, true)
	case .Back_Ref:
		compile_back_ref(c, n.ref_index)
	case .Back_Ref_Named:
		idx := resolve_named(c, n.group_name)
		if idx < 0 { c_fail(c, "reference to non-existent named group"); return }
		compile_back_ref(c, idx)
	}
}

@(private)
compile_char :: proc(c: ^Compiler, ch: rune) {
	if .Ignore_Case in c.flags {
		emit_op(c, .Char_Fold)
		emit_u32(c, u32(uni.canonicalize(u32(ch), unicode_mode(c.flags))))
	} else {
		emit_op(c, .Char)
		emit_u32(c, u32(ch))
	}
}

@(private)
compile_alt :: proc(c: ^Compiler, n: ^Node) {
	// a | b | c lowers to a chain of Split_Next, each preferring the fall-through (the current branch) and
	// deferring to its `off` operand (the rest):
	//     Split_Next L1 ; <a> ; Goto END ; L1: Split_Next L2 ; <b> ; Goto END ; L2: <c> ; END:
	end_jumps := make([dynamic]int, c.allocator)
	defer delete(end_jumps)
	for child, i in n.children {
		last := i == len(n.children) - 1
		if !last {
			emit_op(c, .Split_Next)
			split_at := emit_jump_placeholder(c)
			compile_node(c, child)
			emit_op(c, .Goto)
			append(&end_jumps, emit_jump_placeholder(c))
			// The deferred branch (off) is the code that follows: the next alternative.
			patch_jump_to_here(c, split_at)
		} else {
			compile_node(c, child)
		}
	}
	for at in end_jumps {
		patch_jump_to_here(c, at)
	}
}

@(private)
compile_group :: proc(c: ^Compiler, n: ^Node) {
	if n.capture_index > 0 {
		// In reverse (lookbehind) the end is written before the body, start after.
		if c.reverse {
			emit_op(c, .Save_End); emit_u16(c, u16(n.capture_index))
			compile_node(c, n.children[0])
			emit_op(c, .Save_Start); emit_u16(c, u16(n.capture_index))
		} else {
			emit_op(c, .Save_Start); emit_u16(c, u16(n.capture_index))
			compile_node(c, n.children[0])
			emit_op(c, .Save_End); emit_u16(c, u16(n.capture_index))
		}
	} else {
		compile_node(c, n.children[0])
	}
}

@(private)
compile_lookaround :: proc(c: ^Compiler, n: ^Node, behind: bool) {
	emit_op(c, behind ? .Lookbehind : .Lookahead)
	emit_u8(c, n.neg ? 1 : 0)
	len_at := emit_jump_placeholder(c)
	start := len(c.code)
	old_reverse := c.reverse
	if behind { c.reverse = true }
	compile_node(c, n.children[0])
	c.reverse = old_reverse
	emit_op(c, .Match) // a lookaround subprogram ends in Match (accept the sub-match)
	// Patch the length operand (bytes of the subprogram, relative to end of operand).
	patch_jump_to_here(c, len_at)
	_ = start
}

@(private)
compile_back_ref :: proc(c: ^Compiler, idx: int) {
	emit_op(c, .Ignore_Case in c.flags ? .Back_Ref_Fold : .Back_Ref)
	emit_u16(c, u16(idx))
}

@(private)
resolve_named :: proc(c: ^Compiler, name: string) -> int {
	for n, i in c.group_names { if n == name { return c.group_indices[i] } }
	return -1
}

_ :: strings
_ :: utf8
