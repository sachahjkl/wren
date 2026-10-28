package regexp

// The bytecode dispatch loop. Threaded, iterative backtracking: on a Split the VM pushes the deferred branch as a
// Backtrack entry and takes the preferred one; on a dead end it pops the most recent entry and resumes. Captures
// are snapshotted per choice point (small arrays in practice). The loop charges one step per dispatch and aborts
// when the step or stack budget is exceeded, so no input can make it run or recurse without bound.

import uni "wb:engine/unicode"

@(private)
vm_run :: proc(vm: ^VM, start_pc: int, start_pos: int) -> Exec_Status {
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
			c, w, ok := read_forward(vm, pos)
			if !ok || c != ch { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos += w

		case .Char_Fold:
			ch := get_u32(code, pc); pc += 4
			c, w, ok := read_forward(vm, pos)
			if !ok { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			if u32(uni.canonicalize(c, vm.unicode_mode)) != ch {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}
			pos += w

		case .Any:
			c, w, ok := read_forward(vm, pos)
			if !ok || is_line_terminator(c) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos += w

		case .Any_All:
			_, w, ok := read_forward(vm, pos)
			if !ok { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos += w

		case .Range:
			idx := get_u32(code, pc); pc += 4
			c, w, ok := read_forward(vm, pos)
			if !ok { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			cc := c
			if .Ignore_Case in vm.re.flags {
				cc = u32(uni.canonicalize(c, vm.unicode_mode))
			}
			in_set := uni.cr_contains(&vm.re.ranges[idx], cc)
			if !in_set && cc != c {
				in_set = uni.cr_contains(&vm.re.ranges[idx], c)
			}
			if !in_set { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos += w

		case .Range_Not:
			idx := get_u32(code, pc); pc += 4
			c, w, ok := read_forward(vm, pos)
			if !ok { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			if uni.cr_contains(&vm.re.ranges[idx], c) { if !backtrack(vm, &pc, &pos) { return .No_Match }; continue }
			pos += w

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
			// Prefer the branch at off; push fall-through as the deferred alternative.
			off := get_i32(code, pc); pc += 4
			target := pc + int(off)
			if !push_backtrack(vm, pc, pos) { return .Stack_Overflow }
			pc = target

		case .Split_Next:
			// Prefer fall-through; push the branch at off as the deferred alternative.
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
			for i := int(a); i <= int(b); i += 1 {
				vm.caps[2 * i] = -1
				vm.caps[2 * i + 1] = -1
			}

		case .Push_Char_Pos:
			append(&vm.guards, pos)

		case .Check_Advance:
			last := pop(&vm.guards)
			if pos == last {
				// Empty iteration: do not loop forever. Fail this path.
				if !backtrack(vm, &pc, &pos) { return .No_Match }
				continue
			}

		case .Back_Ref:
			nidx := get_u16(code, pc); pc += 2
			if !match_back_ref(vm, int(nidx), &pos, false) {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}

		case .Back_Ref_Fold:
			nidx := get_u16(code, pc); pc += 2
			if !match_back_ref(vm, int(nidx), &pos, true) {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}

		case .Lookahead:
			neg := code[pc]; pc += 1
			sub_len := get_i32(code, pc); pc += 4
			sub_start := pc
			matched := run_sub(vm, sub_start, pos, false)
			pc = pc + int(sub_len)
			if (neg == 0) != matched {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}

		case .Lookbehind:
			neg := code[pc]; pc += 1
			sub_len := get_i32(code, pc); pc += 4
			sub_start := pc
			matched := run_sub(vm, sub_start, pos, true)
			pc = pc + int(sub_len)
			if (neg == 0) != matched {
				if !backtrack(vm, &pc, &pos) { return .No_Match }; continue
			}

		case .Prev:
			_, w := read_back(vm, pos)
			pos -= w

		case .Match:
			return .Match
		}
	}
}

// Push a choice point, snapshotting the captures and guard-stack length.
@(private)
push_backtrack :: proc(vm: ^VM, pc, pos: int) -> bool {
	if len(vm.stack) >= vm.max_stack { return false }
	snap := make([]int, len(vm.caps), vm.allocator)
	copy(snap, vm.caps)
	append(&vm.stack, Backtrack{pc = pc, pos = pos, caps = snap, guard_len = len(vm.guards)})
	return true
}

// Pop the most recent choice point into (pc, pos), restoring captures and guards. Returns false if none remain.
@(private)
backtrack :: proc(vm: ^VM, pc: ^int, pos: ^int) -> bool {
	if len(vm.stack) == 0 { return false }
	bt := pop(&vm.stack)
	pc^ = bt.pc
	pos^ = bt.pos
	copy(vm.caps, bt.caps)
	delete(bt.caps, vm.allocator)
	resize(&vm.guards, bt.guard_len)
	return true
}
