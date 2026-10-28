package regexp

// Input reading and the helper predicates the VM uses: code-point decoding in both directions for UTF-8 and
// UTF-16, line-terminator and word-character tests, back-reference matching, and the lookaround sub-runner.

import "core:unicode/utf8"
import uni "wb:engine/unicode"

// Decode the code point starting at code-unit offset `pos`. Returns (code point, width in code units, ok). In
// non-unicode mode, UTF-16 surrogates are treated as lone code units (JS legacy behaviour): width is always 1.
@(private)
read_forward :: proc(vm: ^VM, pos: int) -> (c: u32, width: int, ok: bool) {
	if pos >= vm.n { return 0, 0, false }
	switch vm.input.kind {
	case .UTF8:
		r, sz := utf8.decode_rune(vm.input.bytes[pos:])
		if sz == 0 { return 0, 0, false }
		return u32(r), sz, true
	case .UTF16:
		u := vm.input.units
		hi := u[pos]
		if vm.unicode_mode && hi >= 0xD800 && hi <= 0xDBFF && pos + 1 < vm.n {
			lo := u[pos + 1]
			if lo >= 0xDC00 && lo <= 0xDFFF {
				return 0x10000 + ((u32(hi) - 0xD800) << 10) + (u32(lo) - 0xDC00), 2, true
			}
		}
		return u32(hi), 1, true
	}
	return 0, 0, false
}

// Decode the code point ending just before `pos` (walking backwards). Returns (code point, width).
@(private)
read_back :: proc(vm: ^VM, pos: int) -> (c: u32, width: int) {
	if pos <= 0 { return 0, 0 }
	switch vm.input.kind {
	case .UTF8:
		// Step back over continuation bytes.
		i := pos - 1
		for i > 0 && (vm.input.bytes[i] & 0xC0) == 0x80 { i -= 1 }
		r, sz := utf8.decode_rune(vm.input.bytes[i:])
		return u32(r), sz == 0 ? 1 : sz
	case .UTF16:
		u := vm.input.units
		lo := u[pos - 1]
		if vm.unicode_mode && lo >= 0xDC00 && lo <= 0xDFFF && pos - 2 >= 0 {
			hi := u[pos - 2]
			if hi >= 0xD800 && hi <= 0xDBFF {
				return 0x10000 + ((u32(hi) - 0xD800) << 10) + (u32(lo) - 0xDC00), 2
			}
		}
		return u32(lo), 1
	}
	return 0, 0
}

@(private)
is_line_terminator :: proc(c: u32) -> bool {
	return c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
}

// A word character for \b: [A-Za-z0-9_], plus (in unicode+ignoreCase) the extra code points whose fold is a word
// character. We keep the ASCII rule which matches ECMAScript exactly for the non-unicode case; the rare unicode-i
// extension (e.g. Kelvin sign) is handled by folding the code point first.
@(private)
is_word_char :: proc(vm: ^VM, c: u32) -> bool {
	if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' {
		return true
	}
	if vm.unicode_mode && .Ignore_Case in vm.re.flags {
		f := u32(uni.canonicalize(c, true))
		return (f >= 'a' && f <= 'z') || (f >= 'A' && f <= 'Z')
	}
	return false
}

@(private)
at_word_boundary :: proc(vm: ^VM, pos: int) -> bool {
	before := false
	after := false
	if pos > 0 {
		pc, _ := read_back(vm, pos)
		before = is_word_char(vm, pc)
	}
	if pos < vm.n {
		c, _, ok := read_forward(vm, pos)
		if ok { after = is_word_char(vm, c) }
	}
	return before != after
}

// Match the text previously captured by group `n` at the current position, advancing `pos`. An unset group
// matches the empty string (ECMAScript: a back reference to a group that did not participate succeeds trivially).
@(private)
match_back_ref :: proc(vm: ^VM, n: int, pos: ^int, fold: bool) -> bool {
	s := vm.caps[2 * n]
	e := vm.caps[2 * n + 1]
	if s < 0 || e < 0 { return true }
	// Walk the captured span and the current position code point by code point.
	i := s
	p := pos^
	for i < e {
		if p >= vm.n { return false }
		rc, rw, rok := read_forward_at(vm, i)
		if !rok { return false }
		pc, pw, pok := read_forward(vm, p)
		if !pok { return false }
		if fold {
			if u32(uni.canonicalize(rc, vm.unicode_mode)) != u32(uni.canonicalize(pc, vm.unicode_mode)) {
				return false
			}
		} else if rc != pc {
			return false
		}
		i += rw
		p += pw
	}
	pos^ = p
	return true
}

// read_forward but from an arbitrary offset (used to re-read a captured span).
@(private)
read_forward_at :: proc(vm: ^VM, pos: int) -> (c: u32, width: int, ok: bool) {
	return read_forward(vm, pos)
}

// Run a lookaround sub-program at `sub_start` with the current position. For lookahead it runs forward; for
// lookbehind the sub-program was compiled in reverse and each atom steps backwards (the compiler emits Prev-like
// motion implicitly by reversing concatenation and using read_back inside atoms). To keep the forward dispatch
// loop reusable, the lookbehind body is compiled so that its atoms consume backwards: we achieve that by running
// the same loop but with a position that the sub-program decrements. Here we implement lookbehind by scanning: we
// try the reversed program which, because atoms were emitted reversed and use read_back, matches a suffix ending
// at `pos`.
//
// Captures set inside a positive lookaround persist (ECMAScript); inside a negative one they are discarded.
@(private)
run_sub :: proc(vm: ^VM, sub_start: int, pos: int, behind: bool) -> bool {
	// Snapshot captures so a failing/negative sub does not leak its writes.
	snap := make([]int, len(vm.caps), vm.allocator)
	copy(snap, vm.caps)
	defer delete(snap, vm.allocator)

	saved_stack := vm.stack
	saved_guards := vm.guards
	vm.stack = make([dynamic]Backtrack, vm.allocator)
	vm.guards = make([dynamic]int, vm.allocator)

	st: Exec_Status
	if behind {
		st = vm_run_behind(vm, sub_start, pos)
	} else {
		st = vm_run(vm, sub_start, pos)
	}

	// Clean up the sub's backtrack stack.
	for &bt in vm.stack { delete(bt.caps, vm.allocator) }
	delete(vm.stack)
	delete(vm.guards)
	vm.stack = saved_stack
	vm.guards = saved_guards

	if st == .Match {
		return true
	}
	// Restore captures on failure (negative lookaround handling happens in the caller via the match/neg test;
	// here we only guarantee that a failed sub leaves no partial captures).
	copy(vm.caps, snap)
	return false
}
