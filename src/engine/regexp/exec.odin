package regexp

// The backtracking interpreter. It walks the bytecode with an explicit backtrack stack (no native recursion for
// alternation/quantifiers, so a pathological pattern cannot overflow the C stack), subject to a caller-controlled
// step budget and backtrack-stack depth. Input is a slice of code units: either UTF-8 bytes decoded to code
// points on the fly (`Input_UTF8`), or UTF-16 units (`Input_UTF16`). Capture positions are reported in code-unit
// offsets of the chosen encoding, matching JS semantics (UTF-16 indices for JS strings).

Input_Kind :: enum u8 { UTF8, UTF16 }

Input :: struct {
	kind:  Input_Kind,
	bytes: []u8,   // UTF8
	units: []u16,  // UTF16
}

input_utf8 :: proc(s: []u8) -> Input { return {kind = .UTF8, bytes = s} }
input_utf8_string :: proc(s: string) -> Input { return {kind = .UTF8, bytes = transmute([]u8)s} }
input_utf16 :: proc(u: []u16) -> Input { return {kind = .UTF16, units = u} }

// Controls on an exec run. Defaults (zero value) mean "generous but bounded".
Exec_Limits :: struct {
	max_steps: int, // opcode dispatches; 0 -> DEFAULT_MAX_STEPS
	max_stack: int, // backtrack entries;  0 -> DEFAULT_MAX_STACK
}

DEFAULT_MAX_STEPS :: 10_000_000
DEFAULT_MAX_STACK :: 1_000_000

Exec_Status :: enum u8 { No_Match, Match, Out_Of_Steps, Stack_Overflow }

// A saved backtrack choice: resume at `pc` with position `pos`, restoring the capture array to a snapshot. To
// avoid copying the whole capture array on every choice, we snapshot lazily: each entry records the captures that
// were modified since the previous checkpoint. For clarity and correctness first, this implementation keeps a
// compact copy of the capture slots; capture counts are small in practice.
@(private)
Backtrack :: struct {
	pc:   int,
	pos:  int,
	// Snapshot of the capture slots at the time of the choice (2 ints per group).
	caps: []int,
	// Snapshot of the char-pos guard stack length.
	guard_len: int,
}

@(private)
VM :: struct {
	re:      ^Regexp,
	input:   Input,
	n:       int, // number of code units
	caps:    []int, // 2 per group: start,end in code-unit offsets (-1 = unset)
	stack:   [dynamic]Backtrack,
	guards:  [dynamic]int, // Push_Char_Pos stack for empty-loop guards
	steps:   int,
	max_steps: int,
	max_stack: int,
	allocator: Allocator,
	unicode_mode: bool,
}

// Run the regexp against `input` starting at code-unit offset `start`. On a match, fills `out` with the capture
// spans and returns Match. `out.groups` is (re)sized to capture_count. The caller owns `out` (call
// captures_destroy). Non-global/non-sticky semantics: the engine itself tries each start position unless the
// pattern is sticky; `exec` here tries only `start` and lets `exec_search` scan.
exec :: proc(re: ^Regexp, input: Input, start: int, out: ^Captures,
             limits := Exec_Limits{}, allocator := context.allocator) -> Exec_Status {
	n := input_len(input)
	if start < 0 || start > n { return .No_Match }

	vm := VM{
		re = re, input = input, n = n,
		max_steps = limits.max_steps > 0 ? limits.max_steps : DEFAULT_MAX_STEPS,
		max_stack = limits.max_stack > 0 ? limits.max_stack : DEFAULT_MAX_STACK,
		allocator = allocator,
		unicode_mode = unicode_mode(re.flags),
	}
	ncap := re.capture_count
	vm.caps = make([]int, ncap * 2, allocator)
	for i in 0 ..< len(vm.caps) { vm.caps[i] = -1 }
	vm.stack = make([dynamic]Backtrack, allocator)
	vm.guards = make([dynamic]int, allocator)
	defer delete(vm.stack)
	defer delete(vm.guards)
	defer delete(vm.caps, allocator)

	st := vm_run(&vm, 0, start)
	if st != .Match { return st }

	// Copy captures into the output.
	if out.groups == nil {
		out.groups = make([dynamic]Capture, allocator)
		out.allocator = allocator
	}
	resize(&out.groups, ncap)
	for i in 0 ..< ncap {
		out.groups[i] = Capture{start = vm.caps[2 * i], end = vm.caps[2 * i + 1]}
	}
	return .Match
}

// Search for the first match at or after `start`, honoring the sticky flag (which forbids advancing the start).
// Returns the Exec_Status; on Match, `out` holds the captures.
exec_search :: proc(re: ^Regexp, input: Input, start: int, out: ^Captures,
                    limits := Exec_Limits{}, allocator := context.allocator) -> Exec_Status {
	n := input_len(input)
	sticky := .Sticky in re.flags
	pos := start
	for pos <= n {
		st := exec(re, input, pos, out, limits, allocator)
		if st == .Match { return .Match }
		if st == .Out_Of_Steps || st == .Stack_Overflow { return st }
		if sticky { return .No_Match }
		pos += 1
	}
	return .No_Match
}

@(private)
input_len :: proc(input: Input) -> int {
	switch input.kind {
	case .UTF8:  return len(input.bytes)
	case .UTF16: return len(input.units)
	}
	return 0
}
