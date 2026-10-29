package frontend

import "base:runtime"
import "wb:engine/numconv"

// Public entry points: compile a script or a module to QuickJS-ng 0.17 bytecode, and serialize the result to the
// JS_WriteObject byte stream. This mirrors __JS_EvalInternal with JS_EVAL_FLAG_COMPILE_ONLY: a top-level
// function named "<eval>" whose body scope is scope 1, parsed in a single pass, then resolved and optimized.

Program_Kind :: enum u8 {
	script,
	module,
	indirect_eval, // JS_EVAL_TYPE_INDIRECT
	direct_eval,   // JS_EVAL_TYPE_DIRECT: needs Compile_Options.parent
}

Compile_Options :: struct {
	filename:    string, // the script name recorded in the debug info (QuickJS's `filename` argument)
	max_nesting: int,    // recursion guard; 0 means DEFAULT_COMPILE_MAX_DEPTH
	// stack bytes the compiler may use below its entry before it reports "stack overflow"; 0 means
	// DEFAULT_COMPILE_STACK_BUDGET, a negative value disables the check. Pick it from the stack the caller has
	// left (the wasm build links a 1 MiB stack).
	stack_budget: int,
	strict:       bool,         // JS_EVAL_FLAG_STRICT (scripts and indirect eval)
	parent:       ^Eval_Parent, // the calling function of a direct eval
	// JS_WriteModule drops import attributes; with this set a request imported `with { type: T }` is renamed
	// "specifier\0T" so a runtime reading the bytecode still sees the type.
	encode_import_type: bool,
	// Keep each function's source text in the bytecode (what Function.prototype.toString returns); the
	// differential judge compares against JS_WRITE_OBJ_STRIP_SOURCE output and leaves it off.
	keep_source: bool,
}

// The calling function of a direct eval, as the runtime knows it from the caller's bytecode: the parts of a
// JSFunctionBytecode that add_closure_variables reads, with names as UTF-8.
Eval_Parent_Var :: struct {
	name:                  string,
	scope_level, scope_next: int,
	var_kind:              Var_Kind,
	is_const, is_lexical:  bool,
}

Eval_Parent_Closure :: struct {
	name:                 string,
	var_idx:              int,
	closure_type:         Closure_Type,
	var_kind:             Var_Kind,
	is_const, is_lexical: bool,
}

Eval_Parent :: struct {
	arg_count:                                     int,
	vardefs:                                       []Eval_Parent_Var, // arg_count arguments, then the locals
	closure_vars:                                  []Eval_Parent_Closure,
	scope_idx:                                     int, // the caller's innermost scope at the eval call
	is_strict, new_target_allowed, super_call_allowed, super_allowed, arguments_allowed: bool,
}

// add_closure_variables: the eval body sees the caller's lexical variables in scope at the call, then its
// arguments and top-level vars (or only the pseudo variables when called from a parameter scope), then the
// caller's own closure variables.
@(private = "file")
add_closure_variables :: proc(at: ^Atom_Table, fd: ^Func_Def, p: ^Eval_Parent) {
	var_count := len(p.vardefs) - p.arg_count
	local_cv :: proc(at: ^Atom_Table, fd: ^Func_Def, vd: ^Eval_Parent_Var, i: int) {
		append(&fd.closure_var, Closure_Var{closure_type = .local, is_const = vd.is_const, is_lexical = vd.is_lexical, var_kind = vd.var_kind, var_idx = i, var_name = intern(at, vd.name)})
	}
	i := p.scope_idx
	for i >= 0 {
		vd := &p.vardefs[p.arg_count + i]
		if vd.scope_level > 0 {local_cv(at, fd, vd, i)}
		i = vd.scope_next
	}
	if i != ARG_SCOPE_END {
		for k in 0 ..< p.arg_count {
			append(&fd.closure_var, Closure_Var{closure_type = .arg, var_kind = .normal, var_idx = k, var_name = intern(at, p.vardefs[k].name)})
		}
		for k in 0 ..< var_count {
			vd := &p.vardefs[p.arg_count + k]
			if vd.scope_level == 0 && vd.name != "<ret>" {local_cv(at, fd, vd, k)}
		}
	} else {
		for k in 0 ..< var_count {
			vd := &p.vardefs[p.arg_count + k]
			if vd.scope_level != 0 {continue}
			tmp := Var_Def{var_name = intern(at, vd.name), var_kind = vd.var_kind}
			if is_var_in_arg_scope(&tmp) {local_cv(at, fd, vd, k)}
		}
	}
	for cv0, k in p.closure_vars {
		append(&fd.closure_var, Closure_Var{closure_type = .ref, is_const = cv0.is_const, is_lexical = cv0.is_lexical, var_kind = cv0.var_kind, var_idx = k, var_name = intern(at, cv0.name)})
	}
}

// encode_import_types folds the `type` import attribute into the request name ("specifier\0type").
@(private = "file")
encode_import_types :: proc(at: ^Atom_Table, m: ^Module_Def, allocator: runtime.Allocator) {
	for &rme in m.req_module_entries {
		if rme.attributes == nil {continue}
		for k, i in rme.attributes.keys {
			if string_to_utf8(atom_to_string(at, k), allocator) != "type" {continue}
			name := string_to_utf8(atom_to_string(at, rme.module_name), allocator)
			ty := string_to_utf8(rme.attributes.values[i], allocator)
			buf := make([]u8, len(name) + 1 + len(ty), allocator)
			copy(buf, name)
			copy(buf[len(name) + 1:], ty)
			rme.module_name = intern(at, string(buf))
			break
		}
	}
}

// error_kind classifies a compile error the way QuickJS throws it: a stack overflow is a RangeError
// ("Maximum call stack size exceeded" at run time), everything else a SyntaxError.
Error_Kind :: enum u8 {
	syntax,
	range,
}

error_kind :: proc(e: Error) -> Error_Kind {
	return e.message == "stack overflow" ? .range : .syntax
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
	s.keep_source = opts.keep_source
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
	is_strict := opts.strict
	parent := kind == .direct_eval ? opts.parent : nil
	switch kind {
	case .script:
	case .indirect_eval:
		eval_type = .indirect
	case .direct_eval:
		eval_type = .direct
		if parent != nil {is_strict = parent.is_strict}
	case .module:
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
	fd.has_this_binding = eval_type != .direct
	fd.new_target_allowed = false
	fd.super_call_allowed = false
	fd.super_allowed = false
	fd.arguments_allowed = true
	if parent != nil {
		fd.new_target_allowed = parent.new_target_allowed
		fd.super_call_allowed = parent.super_call_allowed
		fd.super_allowed = parent.super_allowed
		fd.arguments_allowed = parent.arguments_allowed
	}
	fd.is_strict_mode = is_strict
	fd.func_name = A__eval_
	if parent != nil {add_closure_variables(at, fd, parent)}
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
	b := js_create_function(&ps, fd)
	if b == nil {
		msg := ps.error != "" ? ps.error : "SyntaxError"
		return Compile_Result{atoms = at, err = make_error(msg, Source_Pos{})}
	}
	if m != nil {
		m.func_obj = b
		if opts.encode_import_type {encode_import_types(at, m, allocator)}
	}
	return Compile_Result{top = b, module = m, atoms = at, err = no_error}
}

// write_object_of serializes a compiled program to the JS_WriteObject byte stream.
write_object_of :: proc(res: Compile_Result, allocator: runtime.Allocator) -> []u8 {
	w: Writer
	writer_init(&w, res.atoms, allocator)
	out := write_object(&w, res.top, res.module)
	// (no-ops on an arena; they give a heap allocator its memory back before the caller goes on; the buffer is the result)
	delete(w.idx_to_atom)
	delete(w.atom_to_idx)
	return out
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
