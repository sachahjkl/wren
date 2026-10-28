package regexp

// Reverse interpreter for lookbehind bodies. The compiler lays out a lookbehind's atoms in reverse order (see
// compile_lookaround with reverse=true), so running them while moving the position *backwards* matches a suffix
// ending at the lookbehind's anchor position. This is the same dispatch as vm_run, but every character-consuming
// op reads with read_back and decrements the position, and Save_Start/Save_End were already swapped by the
// compiler so the recorded span is oriented correctly.
//
// Lookbehind bodies are themselves full sub-programs: they may contain groups, alternation, quantifiers,
// back references and nested lookaround. Nested lookahead inside a lookbehind runs forward again (run_sub with
// behind=false); nested lookbehind runs backward.

import uni "wb:engine/unicode"

@(private)
vm_run_behind :: proc(vm: ^VM, start_pc: int, start_pos: int) -> Exec_Status {
	code := vm.re.bytecode[:]
	pc := start_pc
	pos := start_pos

	for {
		vm.steps += 1
		if vm.steps > vm.max_steps { return .Out_Of_Steps }

		op := Op(code[pc])
		pc += 1
		switch op {
		case .Char:
			ch := get_u32(code, pc); pc += 4
			c, w := read_back(vm, pos)
			if w == 0 || c != ch { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos -= w

		case .Char_Fold:
			ch := get_u32(code, pc); pc += 4
			c, w := read_back(vm, pos)
			if w == 0 { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			if u32(uni.canonicalize(c, vm.unicode_mode)) != ch {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}
			pos -= w

		case .Any:
			c, w := read_back(vm, pos)
			if w == 0 || is_line_terminator(c) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos -= w

		case .Any_All:
			_, w := read_back(vm, pos)
			if w == 0 { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos -= w

		case .Range:
			idx := get_u32(code, pc); pc += 4
			c, w := read_back(vm, pos)
			if w == 0 { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			cc := c
			if .Ignore_Case in vm.re.flags { cc = u32(uni.canonicalize(c, vm.unicode_mode)) }
			in_set := uni.cr_contains(&vm.re.ranges[idx], cc)
			if !in_set && cc != c { in_set = uni.cr_contains(&vm.re.ranges[idx], c) }
			if !in_set { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos -= w

		case .Range_Not:
			idx := get_u32(code, pc); pc += 4
			c, w := read_back(vm, pos)
			if w == 0 { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			if uni.cr_contains(&vm.re.ranges[idx], c) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos -= w

		case .Line_Start:
			if pos != 0 { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Line_End:
			if pos != vm.n { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Line_Start_M:
			if pos != 0 {
				prev, _ := read_back(vm, pos)
				if !is_line_terminator(prev) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			}

		case .Line_End_M:
			if pos != vm.n {
				c, _, _ := read_forward(vm, pos)
				if !is_line_terminator(c) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			}

		case .Word_Boundary:
			if !at_word_boundary(vm, pos) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Not_Word_Boundary:
			if at_word_boundary(vm, pos) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Goto:
			off := get_i32(code, pc); pc += 4
			pc = pc + int(off)

		case .Split_Goto:
			off := get_i32(code, pc); pc += 4
			target := pc + int(off)
			if !push_backtrack(vm, pc, pos) { return .Stack_Overflow }
			pc = target

		case .Split_Next:
			off := get_i32(code, pc); pc += 4
			target := pc + int(off)
			if !push_backtrack(vm, target, pos) { return .Stack_Overflow }

		case .Save_Start:
			nidx := get_u16(code, pc); pc += 2
			vm.caps[2 * int(nidx)] = pos

		case .Save_End:
			nidx := get_u16(code, pc); pc += 2
			vm.caps[2 * int(nidx) + 1] = pos

		case .Save_Reset:
			a := get_u16(code, pc); pc += 2
			b := get_u16(code, pc); pc += 2
			for i := int(a); i <= int(b); i += 1 { vm.caps[2 * i] = -1; vm.caps[2 * i + 1] = -1 }

		case .Push_Char_Pos:
			append(&vm.guards, pos)

		case .Check_Advance:
			last := pop(&vm.guards)
			if pos == last { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Back_Ref:
			nidx := get_u16(code, pc); pc += 2
			if !match_back_ref_behind(vm, int(nidx), &pos, false) {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}

		case .Back_Ref_Fold:
			nidx := get_u16(code, pc); pc += 2
			if !match_back_ref_behind(vm, int(nidx), &pos, true) {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}

		case .Lookahead:
			neg := code[pc]; pc += 1
			sub_len := get_i32(code, pc); pc += 4
			sub_start := pc
			matched := run_sub(vm, sub_start, pos, false)
			pc = pc + int(sub_len)
			if (neg == 0) != matched { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Lookbehind:
			neg := code[pc]; pc += 1
			sub_len := get_i32(code, pc); pc += 4
			sub_start := pc
			matched := run_sub(vm, sub_start, pos, true)
			pc = pc + int(sub_len)
			if (neg == 0) != matched { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }

		case .Prev:
			_, w := read_back(vm, pos)
			pos -= w

		case .Match:
			return .Match
		}
	}
}

// Back reference inside a lookbehind: consume the captured text ending at the current position, moving backward.
@(private)
match_back_ref_behind :: proc(vm: ^VM, n: int, pos: ^int, fold: bool) -> bool {
	s := vm.caps[2 * n]
	e := vm.caps[2 * n + 1]
	if s < 0 || e < 0 { return true }
	i := e
	p := pos^
	for i > s {
		rc, rw := read_back_at(vm, i)
		if rw == 0 { return false }
		pc, pw := read_back(vm, p)
		if pw == 0 { return false }
		if fold {
			if u32(uni.canonicalize(rc, vm.unicode_mode)) != u32(uni.canonicalize(pc, vm.unicode_mode)) {
				return false
			}
		} else if rc != pc {
			return false
		}
		i -= rw
		p -= pw
	}
	pos^ = p
	return true
}

@(private)
read_back_at :: proc(vm: ^VM, pos: int) -> (c: u32, width: int) {
	return read_back(vm, pos)
}
