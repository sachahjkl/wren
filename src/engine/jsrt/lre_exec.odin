package jsrt

// The regexp matcher: executes libregexp bytecode, the format QuickJS-ng 0.17's lre_compile emits and
// that the Odin front-end (src/engine/frontend, fe.lre_compile) reproduces byte for byte. Regexp
// literals reach the runtime already compiled in this format (the second operand of OP_regexp), and
// the RegExp constructor compiles with the same front-end function, so one matcher serves both.
//
// It is lre_exec_backtrack with indices instead of pointers: the subject is a flat runtime string,
// read in place (Latin-1 bytes or UTF-16 units; with u/v the units are decoded as code points), a
// capture or register is an int (-1 = unset), and the backtrack stack is a growable []int.

import "base:runtime"
import "core:mem"
import fe "wb:engine/frontend"

LRE_HEADER_LEN :: 8
LRE_STACK_MAX :: 8 << 20 // backtrack stack words before "out of memory in regexp execution"

Lre_Status :: enum u8 {
	no_match,
	match,
	timeout,
	memory,
	bytecode_error,
}

lre_flags :: #force_inline proc(bc: []u8) -> int {return int(bc[0]) | int(bc[1]) << 8}
lre_capture_count :: #force_inline proc(bc: []u8) -> int {return int(bc[2])}
lre_register_count :: #force_inline proc(bc: []u8) -> int {return int(bc[3])}
lre_alloc_count :: #force_inline proc(bc: []u8) -> int {return 2 * lre_capture_count(bc) + lre_register_count(bc)}
lre_bytecode_len :: #force_inline proc(bc: []u8) -> int {return int(rd_u32(bc, 4))}

// lre_check_bytecode: a header and a body that fit in the buffer (anything read from serialized
// bytecode is checked before it runs).
lre_check_bytecode :: proc(bc: []u8) -> bool {
	if len(bc) < LRE_HEADER_LEN {return false}
	return u64(lre_bytecode_len(bc)) <= u64(len(bc) - LRE_HEADER_LEN)
}

// lre_verify: walks the instruction stream of bytecode that did not come from our own compiler (a
// serialized regexp literal): every instruction and its operands lie inside the body, every jump lands on
// an instruction, capture and register indices are in range. The matcher can then run it safely.
lre_verify :: proc(bc: []u8, scratch: mem.Allocator) -> bool {
	if !lre_check_bytecode(bc) {return false}
	ncap := lre_capture_count(bc)
	nreg := lre_register_count(bc)
	if ncap == 0 {return false}
	end := LRE_HEADER_LEN + lre_bytecode_len(bc)
	if lre_flags(bc) & fe.LRE_FLAG_NAMED_GROUPS != 0 {
		// capture_count-1 names, each ending with a NUL and a scope byte
		p := end
		for _ in 1 ..< ncap {
			for p < len(bc) && bc[p] != 0 {p += 1}
			p += fe.LRE_GROUP_NAME_TRAILER_LEN
			if p > len(bc) {return false}
		}
	}
	starts := make([]bool, end + 1, scratch)
	Jump :: struct {
		at, target: int,
	}
	jumps := make([dynamic]Jump, 0, 16, scratch)
	pc := LRE_HEADER_LEN
	for pc < end {
		starts[pc] = true
		op := bc[pc]
		if int(op) >= len(fe.REOP) || fe.REOP(op) == .invalid {return false}
		o := fe.REOP(op)
		size := int(fe.reop_size[o])
		if pc + size > end {return false}
		#partial switch o {
		case .range, .range_i:
			cnt := int(rd_u16(bc, pc + 1))
			if cnt == 0 {return false}
			size += 4 * cnt
		case .range32, .range32_i:
			cnt := int(rd_u16(bc, pc + 1))
			if cnt == 0 {return false}
			size += 8 * cnt
		case .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i:
			size += int(bc[pc + 1])
		case .goto, .split_goto_first, .split_next_first, .lookahead, .negative_lookahead:
			append(&jumps, Jump{pc, pc + 5 + int(i32(rd_u32(bc, pc + 1)))})
		case .loop:
			if int(bc[pc + 1]) >= nreg {return false}
			append(&jumps, Jump{pc, pc + 6 + int(i32(rd_u32(bc, pc + 2)))})
		case .loop_split_goto_first, .loop_split_next_first:
			if int(bc[pc + 1]) >= nreg {return false}
			append(&jumps, Jump{pc, pc + 10 + int(i32(rd_u32(bc, pc + 6)))})
		case .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first:
			if int(bc[pc + 1]) + 1 >= nreg {return false}
			append(&jumps, Jump{pc, pc + 10 + int(i32(rd_u32(bc, pc + 6)))})
		case .set_i32, .set_char_pos, .check_advance:
			if int(bc[pc + 1]) >= nreg {return false}
		case .save_start, .save_end:
			if int(bc[pc + 1]) >= ncap {return false}
		case .save_reset:
			if int(bc[pc + 1]) > int(bc[pc + 2]) || int(bc[pc + 2]) >= ncap {return false}
		}
		if pc + size > end {return false}
		pc += size
	}
	for j in jumps {
		if j.target < LRE_HEADER_LEN || j.target >= end || !starts[j.target] {return false}
	}
	return true
}

// The group names that follow the bytecode: capture_count-1 NUL-terminated names, each followed by a
// NUL and a scope byte (LRE_GROUP_NAME_TRAILER_LEN); an empty name is an unnamed group. nil without names.
lre_group_names :: proc(bc: []u8) -> []u8 {
	if lre_flags(bc) & fe.LRE_FLAG_NAMED_GROUPS == 0 {return nil}
	return bc[LRE_HEADER_LEN + lre_bytecode_len(bc):]
}

@(private = "file")
rd_u16 :: #force_inline proc(b: []u8, p: int) -> u32 {return u32(b[p]) | u32(b[p + 1]) << 8}
@(private = "file")
rd_u32 :: #force_inline proc(b: []u8, p: int) -> u32 {
	return u32(b[p]) | u32(b[p + 1]) << 8 | u32(b[p + 2]) << 16 | u32(b[p + 3]) << 24
}

@(private = "file")
is_line_terminator :: #force_inline proc(c: u32) -> bool {return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029}

@(private = "file")
lre_is_word :: #force_inline proc(c: u32) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
lre_is_space :: proc(c: u32) -> bool {
	switch c {
	case 0x09 ..= 0x0d, 0x20, 0xa0, 0x1680, 0x2000 ..= 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	}
	return false
}

@(private = "file")
Subject :: struct {
	u8s:  []u8,
	u16s: []u16,
	n:    int,
	wide: bool,
	utf:  bool, // decode surrogate pairs (unicode mode over UTF-16)
}

@(private = "file")
unit :: #force_inline proc(s: ^Subject, i: int) -> u32 {return s.wide ? u32(s.u16s[i]) : u32(s.u8s[i])}

@(private = "file")
is_hi :: #force_inline proc(c: u32) -> bool {return c >= 0xd800 && c < 0xdc00}
@(private = "file")
is_lo :: #force_inline proc(c: u32) -> bool {return c >= 0xdc00 && c < 0xe000}

// GET_CHAR: the character at i and the index after it.
@(private = "file")
get_char :: #force_inline proc(s: ^Subject, i: int) -> (u32, int) {
	c := unit(s, i)
	if s.utf && is_hi(c) && i + 1 < s.n {
		c2 := unit(s, i + 1)
		if is_lo(c2) {return 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00), i + 2}
	}
	return c, i + 1
}

// GET_PREV_CHAR: the character before i (not below `start`) and its index.
@(private = "file")
get_prev_char :: #force_inline proc(s: ^Subject, i: int, start: int) -> (u32, int) {
	p := i - 1
	c := unit(s, p)
	if s.utf && is_lo(c) && p > start {
		c1 := unit(s, p - 1)
		if is_hi(c1) {return 0x10000 + ((c1 - 0xd800) << 10) + (c - 0xdc00), p - 1}
	}
	return c, p
}

@(private = "file")
State_Type :: enum {
	split,
	lookahead,
	negative_lookahead,
}

// A saved state is 3 stack words: pc, position, and (bp << 2 | type).
@(private = "file")
Exec :: struct {
	stack:     [dynamic]int,
	capture:   []int,
	ncap:      int,
	is_unicode: bool,
	ctx:       ^Context,
}

// lre_exec: run bytecode `bc` on subject `s` from index `cindex`; on a match `capture` (sized
// lre_alloc_count) holds start/end pairs (-1 = unset) followed by the registers.
// `scratch` holds the backtrack stack (the caller resets it).
lre_exec :: proc(ctx: ^Context, capture: []int, bc: []u8, str: ^JS_String, cindex: int, scratch: mem.Allocator) -> Lre_Status {
	rt := ctx.rt
	f := str_flat(rt, str)
	flags := lre_flags(bc)
	sub: Subject
	sub.n = int(f.len)
	sub.wide = f.is_wide
	if sub.wide {sub.u16s = str_u16(f)[:sub.n]} else {sub.u8s = str_u8(f)[:sub.n]}
	is_unicode := flags & (fe.LRE_FLAG_UNICODE | fe.LRE_FLAG_UNICODE_SETS) != 0
	sub.utf = sub.wide && is_unicode
	e := Exec {
		capture    = capture,
		ncap       = lre_capture_count(bc),
		is_unicode = is_unicode,
		ctx        = ctx,
	}
	e.stack = make([dynamic]int, 0, 64, scratch)
	for i in 0 ..< 2 * e.ncap {capture[i] = -1}
	for i in 2 * e.ncap ..< len(capture) {capture[i] = 0}
	cptr := cindex
	if sub.utf && 0 < cindex && cindex < sub.n && is_lo(unit(&sub, cindex)) && is_hi(unit(&sub, cindex - 1)) {
		cptr -= 1
	}
	end := LRE_HEADER_LEN + lre_bytecode_len(bc)
	return exec_backtrack(&e, &sub, bc[:end], LRE_HEADER_LEN, cptr)
}

@(private = "file")
poll :: #force_inline proc(e: ^Exec) -> bool {
	rt := e.ctx.rt
	if rt.interrupt_counter + 1 < 10_000 {
		rt.interrupt_counter += 1
		return false
	}
	return poll_interrupt(e.ctx) // throws the uncatchable interrupt itself
}

// The backtrack stack as a raw int buffer: pushes and truncations without the generic append / resize calls.
@(private = "file")
st_reserve :: #force_no_inline proc(stack: ^[dynamic]int, extra: int) {
	reserve(stack, max(2 * cap(stack), len(stack) + extra))
}

@(private = "file")
st_push2 :: #force_inline proc(stack: ^[dynamic]int, a, b: int) {
	n := len(stack)
	if n + 2 > cap(stack) {st_reserve(stack, 2)}
	d := raw_data(stack^)
	d[n] = a
	d[n + 1] = b
	(cast(^runtime.Raw_Dynamic_Array)stack).len = n + 2
}

@(private = "file")
st_push3 :: #force_inline proc(stack: ^[dynamic]int, a, b, c: int) {
	n := len(stack)
	if n + 3 > cap(stack) {st_reserve(stack, 3)}
	d := raw_data(stack^)
	d[n] = a
	d[n + 1] = b
	d[n + 2] = c
	(cast(^runtime.Raw_Dynamic_Array)stack).len = n + 3
}

@(private = "file")
st_truncate :: #force_inline proc(stack: ^[dynamic]int, n: int) {
	(cast(^runtime.Raw_Dynamic_Array)stack).len = n
}

@(private = "file")
exec_backtrack :: proc(e: ^Exec, s: ^Subject, bc: []u8, pc0: int, cptr0: int) -> Lre_Status {
	pc := pc0
	cptr := cptr0
	capture := e.capture
	ncap := e.ncap
	stack := &e.stack
	bp := 0
	n := s.n

	save :: #force_inline proc(stack: ^[dynamic]int, capture: []int, idx: int, value: int) {
		st_push2(stack, idx, capture[idx])
		capture[idx] = value
	}
	save_check :: #force_inline proc(stack: ^[dynamic]int, capture: []int, bp: int, idx: int, value: int) {
		sp1 := len(stack)
		for {
			if sp1 > bp {
				if stack[sp1 - 2] == idx {break}
				sp1 -= 2
			} else {
				st_push2(stack, idx, capture[idx])
				break
			}
		}
		capture[idx] = value
	}
	push_state :: #force_inline proc(stack: ^[dynamic]int, bp: ^int, pc, cptr: int, type: State_Type) {
		st_push3(stack, pc, cptr, bp^ << 2 | int(type))
		bp^ = len(stack)
	}

	for {
		if pc >= len(bc) {return .bytecode_error}
		if len(stack) > LRE_STACK_MAX {return .memory}
		opcode := fe.REOP(bc[pc])
		pc += 1
		matched := true
		#partial switch opcode {
		case .match:
			return .match
		case .lookahead_match:
			// pop the saved states down to the lookahead's, keeping the capture undo records
			sp := len(stack)
			sp_top := sp
			type: State_Type
			for {
				sp1 := sp
				sp = bp
				pc = stack[sp - 3]
				cptr = stack[sp - 2]
				w := stack[sp - 1]
				type = State_Type(w & 3)
				bp = w >> 2
				stack[sp - 1] = sp1 // next value for the copy step
				sp -= 3
				if type == .lookahead {break}
			}
			if sp != 0 {
				sp1 := sp
				for sp1 < sp_top {
					next_sp := stack[sp1 + 2]
					sp1 += 3
					for sp1 < next_sp {
						stack[sp] = stack[sp1]
						sp += 1
						sp1 += 1
					}
				}
			}
			st_truncate(stack, sp)
		case .negative_lookahead_match:
			for {
				sp := len(stack)
				for sp > bp {
					capture[stack[sp - 2]] = stack[sp - 1]
					sp -= 2
				}
				pc = stack[sp - 3]
				cptr = stack[sp - 2]
				w := stack[sp - 1]
				bp = w >> 2
				st_truncate(stack, sp - 3)
				if State_Type(w & 3) == .negative_lookahead {break}
			}
			matched = false
		case .char32, .char32_i, .char, .char_i:
			val: u32
			if opcode == .char32 || opcode == .char32_i {
				val = rd_u32(bc, pc)
				pc += 4
			} else {
				val = rd_u16(bc, pc)
				pc += 2
			}
			if cptr >= n {matched = false; break}
			c: u32
			c, cptr = get_char(s, cptr)
			if opcode == .char_i || opcode == .char32_i {c = fe.lre_canonicalize(c, e.is_unicode)}
			if val != c {matched = false}
		case .split_goto_first, .split_next_first:
			val := int(i32(rd_u32(bc, pc)))
			pc += 4
			pc1: int
			if opcode == .split_next_first {
				pc1 = pc + val
			} else {
				pc1 = pc
				pc = pc + val
			}
			push_state(stack, &bp, pc1, cptr, .split)
		case .lookahead, .negative_lookahead:
			val := int(i32(rd_u32(bc, pc)))
			pc += 4
			push_state(stack, &bp, pc + val, cptr, opcode == .lookahead ? .lookahead : .negative_lookahead)
		case .goto:
			val := int(i32(rd_u32(bc, pc)))
			pc += 4 + val
			if poll(e) {return .timeout}
		case .line_start, .line_start_m:
			if cptr == 0 {break}
			if opcode == .line_start {matched = false; break}
			c, _ := get_prev_char(s, cptr, 0)
			if !is_line_terminator(c) {matched = false}
		case .line_end, .line_end_m:
			if cptr == n {break}
			if opcode == .line_end {matched = false; break}
			c, _ := get_char(s, cptr)
			if !is_line_terminator(c) {matched = false}
		case .dot:
			if cptr == n {matched = false; break}
			c: u32
			c, cptr = get_char(s, cptr)
			if is_line_terminator(c) {matched = false}
		case .any:
			if cptr == n {matched = false; break}
			_, cptr = get_char(s, cptr)
		case .space, .not_space:
			if cptr == n {matched = false; break}
			c: u32
			c, cptr = get_char(s, cptr)
			if lre_is_space(c) != (opcode == .space) {matched = false}
		case .save_start, .save_end:
			val := int(bc[pc])
			pc += 1
			if val >= ncap {return .bytecode_error}
			save(stack, capture, 2 * val + (opcode == .save_end ? 1 : 0), cptr)
		case .save_reset:
			val := int(bc[pc])
			val2 := int(bc[pc + 1])
			pc += 2
			if val2 >= ncap {return .bytecode_error}
			for v in val ..= val2 {
				save(stack, capture, 2 * v, -1)
				save(stack, capture, 2 * v + 1, -1)
			}
		case .set_i32:
			idx := 2 * ncap + int(bc[pc])
			val := int(rd_u32(bc, pc + 1))
			pc += 5
			if idx >= len(capture) {return .bytecode_error}
			save_check(stack, capture, bp, idx, val)
		case .loop:
			idx := 2 * ncap + int(bc[pc])
			val := int(i32(rd_u32(bc, pc + 1)))
			pc += 5
			if idx >= len(capture) {return .bytecode_error}
			val2 := int(u32(capture[idx]) - 1)
			save_check(stack, capture, bp, idx, val2)
			if val2 != 0 {
				pc += val
				if poll(e) {return .timeout}
			}
		case .loop_split_goto_first, .loop_split_next_first, .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first:
			idx := 2 * ncap + int(bc[pc])
			limit := rd_u32(bc, pc + 1)
			val := int(i32(rd_u32(bc, pc + 5)))
			pc += 9
			if idx + 1 >= len(capture) && (opcode == .loop_check_adv_split_goto_first || opcode == .loop_check_adv_split_next_first) {return .bytecode_error}
			if idx >= len(capture) {return .bytecode_error}
			val2 := u32(capture[idx]) - 1
			save_check(stack, capture, bp, idx, int(val2))
			if val2 > limit {
				pc += val
				if poll(e) {return .timeout}
			} else {
				if (opcode == .loop_check_adv_split_goto_first || opcode == .loop_check_adv_split_next_first) && capture[idx + 1] == cptr && val2 != limit {
					matched = false
					break
				}
				if val2 != 0 {
					pc1: int
					if opcode == .loop_split_next_first || opcode == .loop_check_adv_split_next_first {
						pc1 = pc + val
					} else {
						pc1 = pc
						pc = pc + val
					}
					push_state(stack, &bp, pc1, cptr, .split)
				}
			}
		case .set_char_pos:
			idx := 2 * ncap + int(bc[pc])
			pc += 1
			if idx >= len(capture) {return .bytecode_error}
			save_check(stack, capture, bp, idx, cptr)
		case .check_advance:
			idx := 2 * ncap + int(bc[pc])
			pc += 1
			if idx >= len(capture) {return .bytecode_error}
			if capture[idx] == cptr {matched = false}
		case .word_boundary, .word_boundary_i, .not_word_boundary, .not_word_boundary_i:
			ignore_case := opcode == .word_boundary_i || opcode == .not_word_boundary_i
			is_boundary := opcode == .word_boundary || opcode == .word_boundary_i
			v1, v2: bool
			if cptr > 0 {
				c, _ := get_prev_char(s, cptr, 0)
				v1 = c < 256 ? lre_is_word(c) : ignore_case && (c == 0x017f || c == 0x212a)
			}
			if cptr < n {
				c, _ := get_char(s, cptr)
				v2 = c < 256 ? lre_is_word(c) : ignore_case && (c == 0x017f || c == 0x212a)
			}
			if v1 ~ v2 ~ is_boundary {matched = false}
		case .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i:
			cnt := int(bc[pc])
			pc += 1
			pc1 := pc
			pc += cnt
			if pc > len(bc) {return .bytecode_error}
			icase := opcode == .back_reference_i || opcode == .backward_back_reference_i
			brk: for i in 0 ..< cnt {
				val := int(bc[pc1 + i])
				if val >= ncap {matched = false; break}
				c1s := capture[2 * val]
				c1e := capture[2 * val + 1]
				if c1s < 0 || c1e < 0 {continue}
				if opcode == .back_reference || opcode == .back_reference_i {
					p := c1s
					for p < c1e {
						if cptr >= n {matched = false; break brk}
						c1, c2: u32
						// GET_CHAR on the captured span is bounded by its end
						c1 = unit(s, p)
						if s.utf && is_hi(c1) && p + 1 < c1e && is_lo(unit(s, p + 1)) {
							c1 = 0x10000 + ((c1 - 0xd800) << 10) + (unit(s, p + 1) - 0xdc00)
							p += 2
						} else {
							p += 1
						}
						c2, cptr = get_char(s, cptr)
						if icase {
							c1 = fe.lre_canonicalize(c1, e.is_unicode)
							c2 = fe.lre_canonicalize(c2, e.is_unicode)
						}
						if c1 != c2 {matched = false; break brk}
					}
				} else {
					p := c1e
					for p > c1s {
						if cptr == 0 {matched = false; break brk}
						c1, c2: u32
						c1, p = get_prev_char(s, p, c1s)
						c2, cptr = get_prev_char(s, cptr, 0)
						if icase {
							c1 = fe.lre_canonicalize(c1, e.is_unicode)
							c2 = fe.lre_canonicalize(c2, e.is_unicode)
						}
						if c1 != c2 {matched = false; break brk}
					}
				}
				break
			}
		case .range, .range_i:
			cnt := int(rd_u16(bc, pc))
			pc += 2
			if pc + 4 * cnt > len(bc) || cnt == 0 {return .bytecode_error}
			if cptr >= n {matched = false; break}
			c: u32
			c, cptr = get_char(s, cptr)
			if opcode == .range_i {c = fe.lre_canonicalize(c, e.is_unicode)}
			ok := false
			high := rd_u16(bc, pc + (cnt - 1) * 4 + 2)
			if c < rd_u16(bc, pc) {
				ok = false
			} else if c >= 0xffff && high == 0xffff {
				ok = true
			} else if c <= high {
				lo, hi := 0, cnt - 1
				for lo <= hi {
					mid := (lo + hi) / 2
					l := rd_u16(bc, pc + mid * 4)
					h := rd_u16(bc, pc + mid * 4 + 2)
					if c < l {hi = mid - 1} else if c > h {lo = mid + 1} else {ok = true; break}
				}
			}
			if !ok {matched = false; break}
			pc += 4 * cnt
		case .range32, .range32_i:
			cnt := int(rd_u16(bc, pc))
			pc += 2
			if pc + 8 * cnt > len(bc) || cnt == 0 {return .bytecode_error}
			if cptr >= n {matched = false; break}
			c: u32
			c, cptr = get_char(s, cptr)
			if opcode == .range32_i {c = fe.lre_canonicalize(c, e.is_unicode)}
			ok := false
			if c >= rd_u32(bc, pc) && c <= rd_u32(bc, pc + (cnt - 1) * 8 + 4) {
				lo, hi := 0, cnt - 1
				for lo <= hi {
					mid := (lo + hi) / 2
					l := rd_u32(bc, pc + mid * 8)
					h := rd_u32(bc, pc + mid * 8 + 4)
					if c < l {hi = mid - 1} else if c > h {lo = mid + 1} else {ok = true; break}
				}
			}
			if !ok {matched = false; break}
			pc += 8 * cnt
		case .prev:
			if cptr == 0 {matched = false; break}
			_, cptr = get_prev_char(s, cptr, 0)
		case:
			return .bytecode_error
		}
		if matched {continue}
		// no_match: unwind to the last split state (lookahead states are skipped)
		for {
			if bp == 0 {return .no_match}
			sp := len(stack)
			for sp > bp {
				capture[stack[sp - 2]] = stack[sp - 1]
				sp -= 2
			}
			pc = stack[sp - 3]
			cptr = stack[sp - 2]
			w := stack[sp - 1]
			bp = w >> 2
			st_truncate(stack, sp - 3)
			if State_Type(w & 3) != .lookahead {break}
		}
		if poll(e) {return .timeout}
	}
}
