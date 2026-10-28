package regexp

// ECMAScript regular expressions in Odin: a parser and bytecode compiler, plus a bounded backtracking
// interpreter, replacing QuickJS's libregexp. The design leans on the language rather than copying the C:
//
//   * opcodes are an `enum`, instructions are decoded from a flat `[]u8` bytecode buffer;
//   * character classes are `unicode.Char_Range` interval sets, not inline bitmaps;
//   * all compile-time and run-time allocation goes through a caller-supplied allocator (an arena frees a whole
//     compilation or a whole match at once), so the package builds for freestanding_wasm32 with no libc;
//   * the interpreter's backtrack stack is an explicit `[dynamic]` with a caller-controlled depth and step
//     budget: there is no unbounded native recursion, so a pathological pattern cannot blow the C stack.
//
// Public API:
//   compile(pattern, flags, allocator) -> (Regexp, Error)
//   exec(&re, input, start, allocator) -> (Captures, bool)     // input is UTF-8 bytes or UTF-16 units
//   named_group_index(&re, name) -> (int, bool)
//   destroy(&re)

import "base:runtime"
import "core:strings"
import uni "wb:engine/unicode"

Flag :: enum u8 {
	Global,      // d g i m s u v y  -> this is `g`
	Ignore_Case, // i
	Multiline,   // m
	Dot_All,     // s
	Unicode,     // u
	Sticky,      // y
	Indices,     // d  (recorded; affects exec result shape only)
	Unicode_Sets, // v
}
Flags :: bit_set[Flag; u16]

Error :: struct {
	message: string, // empty when compilation succeeded
	// Byte offset in the pattern where parsing failed (best effort).
	pos:     int,
}

// A compiled regular expression. Owns its bytecode and group-name storage on `allocator`.
Regexp :: struct {
	bytecode:      [dynamic]u8,
	flags:         Flags,
	capture_count: int, // including the implicit whole-match group 0
	// Character-class interval sets; Range/Range_Not operands index into this.
	ranges:        [dynamic]uni.Char_Range,
	// Parallel arrays of named groups: name -> 1-based capture index (group 0 is the whole match).
	group_names:   [dynamic]string,
	group_indices: [dynamic]int,
	allocator:     Allocator,
}

Allocator :: runtime.Allocator

// One capture: a half-open [start, end) span in *code unit* positions of the input, or {-1,-1} if the group did
// not participate in the match. Index 0 is the whole match.
Capture :: struct {
	start: int,
	end:   int,
}

Captures :: struct {
	groups:    [dynamic]Capture,
	allocator: Allocator,
}

captures_destroy :: proc(c: ^Captures) {
	delete(c.groups)
	c.groups = nil
}

destroy :: proc(re: ^Regexp) {
	delete(re.bytecode)
	for &r in re.ranges { uni.cr_destroy(&r) }
	delete(re.ranges)
	for n in re.group_names { delete(n, re.allocator) }
	delete(re.group_names)
	delete(re.group_indices)
	re^ = {}
}

named_group_index :: proc(re: ^Regexp, name: string) -> (int, bool) {
	for n, i in re.group_names {
		if n == name { return re.group_indices[i], true }
	}
	return 0, false
}

// Parse the textual flags "dgimsuvy" into a Flags set. Returns ok=false on an unknown or duplicate flag.
parse_flags :: proc(s: string) -> (flags: Flags, ok: bool) {
	seen: Flags
	for ch in s {
		f: Flag
		switch ch {
		case 'd': f = .Indices
		case 'g': f = .Global
		case 'i': f = .Ignore_Case
		case 'm': f = .Multiline
		case 's': f = .Dot_All
		case 'u': f = .Unicode
		case 'v': f = .Unicode_Sets
		case 'y': f = .Sticky
		case:     return {}, false
		}
		if f in seen { return {}, false }
		seen += {f}
	}
	// `u` and `v` are mutually exclusive.
	if .Unicode in seen && .Unicode_Sets in seen { return {}, false }
	return seen, true
}

flags_to_string :: proc(flags: Flags, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	// Canonical order per spec: d g i m s u v y.
	if .Indices in flags      { strings.write_byte(&b, 'd') }
	if .Global in flags       { strings.write_byte(&b, 'g') }
	if .Ignore_Case in flags  { strings.write_byte(&b, 'i') }
	if .Multiline in flags    { strings.write_byte(&b, 'm') }
	if .Dot_All in flags      { strings.write_byte(&b, 's') }
	if .Unicode in flags      { strings.write_byte(&b, 'u') }
	if .Unicode_Sets in flags { strings.write_byte(&b, 'v') }
	if .Sticky in flags       { strings.write_byte(&b, 'y') }
	return strings.to_string(b)
}

unicode_mode :: proc(flags: Flags) -> bool {
	return .Unicode in flags || .Unicode_Sets in flags
}
