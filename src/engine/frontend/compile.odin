package frontend

import "base:runtime"
import "wb:engine/numconv"

// Public entry points: compile a script or a module to QuickJS-ng 0.17 bytecode, and serialize the result to the
// JS_WriteObject byte stream. This mirrors __JS_EvalInternal with JS_EVAL_FLAG_COMPILE_ONLY: a top-level
// function named "<eval>" whose body scope is scope 1, parsed in a single pass, then resolved and optimized.

Program_Kind :: enum u8 {
	script,
	module,
}

Compile_Options :: struct {
	filename:    string, // the script name recorded in the debug info (QuickJS's `filename` argument)
	max_nesting: int,    // recursion guard; 0 means DEFAULT_COMPILE_MAX_DEPTH
	// stack bytes the compiler may use below its entry before it reports "stack overflow"; 0 means
	// DEFAULT_COMPILE_STACK_BUDGET, a negative value disables the check. Pick it from the stack the caller has
	// left (the wasm build links a 1 MiB stack).
	stack_budget: int,
}

DEFAULT_COMPILE_MAX_DEPTH :: 6000
DEFAULT_COMPILE_STACK_BUDGET :: 512 * 1024

Compile_Result :: struct {
	top:    ^Function_Bytecode,
	module: ^Module_Def, // non-nil for a module: the record that wraps `top`
	atoms:  ^Atom_Table,
	err:    Error,
}

compile_script :: proc(src: string, allocator: runtime.Allocator) -> Compile_Result {
	return compile_program(src, .script, allocator)
}

compile_module :: proc(src: string, allocator: runtime.Allocator) -> Compile_Result {
	return compile_program(src, .module, allocator)
}

compile_program :: proc(src: string, kind: Program_Kind, allocator: runtime.Allocator, opts := Compile_Options{}) -> Compile_Result {
	context.allocator = allocator
	at := new(Atom_Table, allocator)
	atom_table_init(at, allocator)

	s := new(Parse_State, allocator)
	s.allocator = allocator
	s.atoms = at
	s.max_depth = opts.max_nesting > 0 ? opts.max_nesting : DEFAULT_COMPILE_MAX_DEPTH
	budget := opts.stack_budget == 0 ? DEFAULT_COMPILE_STACK_BUDGET : max(opts.stack_budget, 0)
	s.stack = stack_guard_here(uintptr(budget))
	filename := opts.filename != "" ? opts.filename : "<input>"
	s.filename = intern(at, filename)

	// js_parse_init: the source must be followed by NUL bytes (the lexer peeks a few bytes ahead).
	buf := make([]u8, len(src) + 16, allocator)
	copy(buf, src)
	s.buf = buf
	s.line_num = 1
	s.col_num = 1
	s.buf_start = 0
	s.buf_ptr = 0
	s.buf_end = len(src)
	s.line_start = 0
	s.mark = min(1, len(src))
	s.eol = 0
	s.token.val = ' '
	s.token.line_num = 1
	s.token.col_num = 1
	s.buf_ptr = skip_shebang(s.buf, s.buf_ptr, s.buf_end)

	m: ^Module_Def
	eval_type := Eval_Type.global
	is_strict := false
	if kind == .module {
		eval_type = .module
		m = new(Module_Def, allocator)
		m.module_name = s.filename
		m.req_module_entries = make([dynamic]Req_Module_Entry, allocator)
		m.export_entries = make([dynamic]Export_Entry, allocator)
		m.star_export_entries = make([dynamic]int, allocator)
		m.import_entries = make([dynamic]Import_Entry, allocator)
		is_strict = true
	}
	fd := js_new_function_def(s, nil, true, false, 1, 1)
	s.cur_func = fd
	fd.eval_type = eval_type
	fd.has_this_binding = true
	fd.new_target_allowed = false
	fd.super_call_allowed = false
	fd.super_allowed = false
	fd.arguments_allowed = true
	fd.is_strict_mode = is_strict
	fd.func_name = A__eval_
	fd.module = m
	if m != nil {
		fd.in_function_body = true
		fd.func_kind = .async
	}
	s.is_module = m != nil
	s.allow_html_comments = !s.is_module

	push_scope(s)
	fd.body_scope = fd.scope_level

	if js_parse_program(s) || s.has_error {
		err := s.error
		if !s.has_error {
			err = make_error("SyntaxError", Source_Pos{line = u32(s.token.line_num), col = u32(s.token.col_num)})
		}
		return Compile_Result{atoms = at, err = err}
	}
	if m != nil {
		m.has_tla = fd.has_await
	}

	ps := Pass_State{atoms = at, allocator = allocator, stack = s.stack}
	ps.source_loc_size = make(map[^Func_Def]int, 64, allocator)
	b := js_create_function(&ps, fd)
	if b == nil {
		msg := ps.error != "" ? ps.error : "SyntaxError"
		return Compile_Result{atoms = at, err = make_error(msg, Source_Pos{})}
	}
	if m != nil {
		m.func_obj = b
	}
	return Compile_Result{top = b, module = m, atoms = at, err = no_error}
}

// write_object_of serializes a compiled program to the JS_WriteObject byte stream.
write_object_of :: proc(res: Compile_Result, allocator: runtime.Allocator) -> []u8 {
	w: Writer
	writer_init(&w, res.atoms, allocator)
	return write_object(&w, res.top, res.module)
}

// --- literal helpers ----------------------------------------------------------------------------------------

// number_to_js_string is Number::toString(x) in base 10.
number_to_js_string :: proc(d: f64) -> string {
	if d != d {return "NaN"}
	if d > max(f64) {return "Infinity"}
	if d < -max(f64) {return "-Infinity"}
	buf: [numconv.MAX_STR_LEN]u8
	n := numconv.f64_to_shortest(buf[:], d)
	out := make([]u8, n)
	copy(out, buf[:n])
	return string(out)
}

// bigint_to_decimal formats a (non-negative) BigInt literal value in base 10.
bigint_to_decimal :: proc(v: Big_Int, allocator: runtime.Allocator) -> string {
	limbs := make([]u32, len(v.limbs), allocator)
	copy(limbs, v.limbs)
	n := len(limbs)
	for n > 0 && limbs[n - 1] == 0 {n -= 1}
	if n == 0 {return "0"}
	digits := make([dynamic]u8, 0, n * 10, allocator)
	for n > 0 {
		rem: u64 = 0
		for i := n - 1; i >= 0; i -= 1 {
			cur := (rem << 32) | u64(limbs[i])
			limbs[i] = u32(cur / 1_000_000_000)
			rem = cur % 1_000_000_000
		}
		for n > 0 && limbs[n - 1] == 0 {n -= 1}
		for k in 0 ..< 9 {
			if n == 0 && rem == 0 && k > 0 {break}
			append(&digits, u8('0' + rem % 10))
			rem /= 10
		}
	}
	for len(digits) > 1 && digits[len(digits) - 1] == '0' {pop(&digits)}
	for i in 0 ..< len(digits) / 2 {
		digits[i], digits[len(digits) - 1 - i] = digits[len(digits) - 1 - i], digits[i]
	}
	return string(digits[:])
}

// compile_regexp_literal validates a regexp literal and returns the constant QuickJS stores next to its source:
// the compiled libregexp bytecode as an 8-bit string. A pattern or flags error is a SyntaxError.
compile_regexp_literal :: proc(s: ^Parse_State, body, flags: String_Value) -> (JS_Value, bool) {
	// js_compile_regexp: each flag at most once, u and v exclusive
	re_flags := 0
	for i in 0 ..< string_len(flags) {
		mask := 0
		switch string_at(flags, i) {
		case 'd': mask = LRE_FLAG_INDICES
		case 'g': mask = LRE_FLAG_GLOBAL
		case 'i': mask = LRE_FLAG_IGNORECASE
		case 'm': mask = LRE_FLAG_MULTILINE
		case 's': mask = LRE_FLAG_DOTALL
		case 'u': mask = LRE_FLAG_UNICODE
		case 'v': mask = LRE_FLAG_UNICODE_SETS
		case 'y': mask = LRE_FLAG_STICKY
		}
		if mask == 0 || (re_flags & mask) != 0 {
			js_parse_error(s, "invalid regular expression flags")
			return nil, false
		}
		re_flags |= mask
	}
	if (re_flags & LRE_FLAG_UNICODE) != 0 && (re_flags & LRE_FLAG_UNICODE_SETS) != 0 {
		js_parse_error(s, "invalid regular expression flags")
		return nil, false
	}
	unicode := (re_flags & (LRE_FLAG_UNICODE | LRE_FLAG_UNICODE_SETS)) != 0
	pattern := string_to_utf8(body, s.allocator, cesu8 = !unicode)
	bc, err := lre_compile(transmute([]u8)pattern, re_flags, s.allocator, s.stack)
	if bc == nil {
		js_parse_error(s, err)
		return nil, false
	}
	return String_Value{latin1 = bc}, true
}

// string_to_utf8 encodes a JS string as UTF-8; with cesu8 a surrogate pair stays two 3-byte sequences
// (JS_ToCStringLen2's CESU-8 mode), otherwise it becomes one 4-byte sequence. Lone surrogates are 3 bytes.
string_to_utf8 :: proc(sv: String_Value, allocator: runtime.Allocator, cesu8 := false) -> string {
	out := make([dynamic]u8, 0, string_len(sv) + 8, allocator)
	n := string_len(sv)
	for i := 0; i < n; i += 1 {
		c := u32(string_at(sv, i))
		if !cesu8 && c >= 0xD800 && c < 0xDC00 && i + 1 < n {
			c2 := u32(string_at(sv, i + 1))
			if c2 >= 0xDC00 && c2 < 0xE000 {
				c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00)
				i += 1
			}
		}
		switch {
		case c < 0x80:
			append(&out, u8(c))
		case c < 0x800:
			append(&out, u8(0xC0 | (c >> 6)), u8(0x80 | (c & 0x3F)))
		case c < 0x10000:
			append(&out, u8(0xE0 | (c >> 12)), u8(0x80 | ((c >> 6) & 0x3F)), u8(0x80 | (c & 0x3F)))
		case:
			append(&out, u8(0xF0 | (c >> 18)), u8(0x80 | ((c >> 12) & 0x3F)), u8(0x80 | ((c >> 6) & 0x3F)), u8(0x80 | (c & 0x3F)))
		}
	}
	return string(out[:])
}
