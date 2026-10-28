package regexp

// The regexp bytecode. One opcode byte followed by its operands, little-endian. The layout mirrors the shape of
// QuickJS's bytecode closely enough to share its correctness model (splits, saves, loops, lookaround, back
// references), but it is our own encoding: ranges are stored as an index into the compiled range table rather
// than inline, and lookaround is a self-contained subprogram length rather than a jump pair.

Op :: enum u8 {
	Char,          // u32 ch           : match one code point exactly
	Char_Fold,     // u32 ch           : match one code point under case folding (ch is already canonicalized)
	Any,           //                  : match any code point except line terminators (`.` without s)
	Any_All,       //                  : match any code point (`.` with s, or when matching raw)
	Range,         // u32 idx          : match a code point in range table entry idx
	Range_Not,     // u32 idx          : match a code point NOT in range table entry idx
	Line_Start,    //                  : ^ (not multiline)
	Line_End,      //                  : $ (not multiline)
	Line_Start_M,  //                  : ^ (multiline)
	Line_End_M,    //                  : $ (multiline)
	Word_Boundary, //                  : \b
	Not_Word_Boundary, //              : \B
	Goto,          // i32 off          : unconditional jump (relative to end of operand)
	Split_Goto,    // i32 off          : try the branch at off first, then fall through  (greedy prefers off)
	Split_Next,    // i32 off          : try fall through first, then the branch at off   (lazy / quantifier)
	Save_Start,    // u16 n            : record current position as capture n start
	Save_End,      // u16 n            : record current position as capture n end
	Save_Reset,    // u16 a, u16 b     : clear captures [a, b]
	Match,         //                  : whole pattern matched (accept)
	Back_Ref,      // u16 n            : match the text previously captured by group n
	Back_Ref_Fold, // u16 n            : case-insensitive back reference
	Lookahead,     // u8 neg, i32 len  : (?= ) / (?! ) sub-program of `len` bytes follows
	Lookbehind,    // u8 neg, i32 len  : (?<= ) / (?<! )
	Prev,          //                  : step one code point backwards (used inside lookbehind)
	Push_Char_Pos, //                  : push current position (for empty-match loop guard)
	Check_Advance, //                  : pop a pushed position; fail the iteration if it did not advance
}

// ---- encoding helpers ---------------------------------------------------------------------------------------

@(private)
emit_op :: proc(c: ^Compiler, op: Op) {
	append(&c.code, u8(op))
}

@(private)
emit_u8 :: proc(c: ^Compiler, v: u8) {
	append(&c.code, v)
}

@(private)
emit_u16 :: proc(c: ^Compiler, v: u16) {
	append(&c.code, u8(v), u8(v >> 8))
}

@(private)
emit_u32 :: proc(c: ^Compiler, v: u32) {
	append(&c.code, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
emit_i32 :: proc(c: ^Compiler, v: i32) {
	emit_u32(c, u32(v))
}

// Reserve 4 bytes for a jump target, return the offset to patch later.
@(private)
emit_jump_placeholder :: proc(c: ^Compiler) -> int {
	pos := len(c.code)
	append(&c.code, 0, 0, 0, 0)
	return pos
}

// Patch a 4-byte relative offset at `at` so a jump there lands at the current end of the program.
@(private)
patch_jump_to_here :: proc(c: ^Compiler, at: int) {
	// Offset is relative to the position just past the 4 operand bytes.
	target := len(c.code)
	off := i32(target - (at + 4))
	put_i32(c.code[:], at, off)
}

@(private)
patch_jump_to :: proc(c: ^Compiler, at: int, target: int) {
	off := i32(target - (at + 4))
	put_i32(c.code[:], at, off)
}

@(private)
put_i32 :: proc(buf: []u8, at: int, v: i32) {
	u := u32(v)
	buf[at]   = u8(u)
	buf[at + 1] = u8(u >> 8)
	buf[at + 2] = u8(u >> 16)
	buf[at + 3] = u8(u >> 24)
}

// ---- decoding helpers (interpreter) -------------------------------------------------------------------------

@(private)
get_u16 :: proc(buf: []u8, pc: int) -> u16 {
	return u16(buf[pc]) | (u16(buf[pc + 1]) << 8)
}

@(private)
get_u32 :: proc(buf: []u8, pc: int) -> u32 {
	return u32(buf[pc]) | (u32(buf[pc + 1]) << 8) | (u32(buf[pc + 2]) << 16) | (u32(buf[pc + 3]) << 24)
}

@(private)
get_i32 :: proc(buf: []u8, pc: int) -> i32 {
	return i32(get_u32(buf, pc))
}
