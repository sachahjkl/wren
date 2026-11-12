package jsrt

// The serialized-bytecode reader: parses the stream of the Odin front-end (E1), the layout of
// JS_WriteObject(..., JS_WRITE_OBJ_BYTECODE) of QuickJS-ng 0.17 but for a function's record (BC_VERSION).
//
// Most functions of a page's scripts never run. A function is read in two steps: its head when its parent's constant pool is read
// (what a closure and a frame need), its body at its first run (bytecode_ready), from the stream, which stays in memory
// (Bytecode_Store). A script's atoms are read the same way, at their first use. Until then the function's code is LAZY_CODE.
//
// Every read is bounds-checked and every count is validated against the remaining input, so a
// corrupt or hostile buffer yields a SyntaxError, never an out-of-bounds access: from read_object for the top-level function, from
// the first call for the others. Operands of the instruction stream are checked against the function's own tables (constant
// pool, locals, closure cells) by verify_function, which also keeps the interpreter's indexing safe.

BC_MAX_NESTING :: 16              // values nested in one another (a template object is 3; the functions of a pool are not read within it)
BC_COUNT_LIMIT :: 1 << 24         // the elements of a table, unless the table says otherwise
BC_BIGINT_COUNT_LIMIT :: 1 << 27  // the bytes of a bigint
BC_SOURCE_COUNT_LIMIT :: 1 << 30  // the bytes of a function's source text

BC_Tag :: enum u8 {
	invalid = 0,
	null,
	undefined,
	bool_false,
	bool_true,
	int32,
	float64,
	string,
	object,
	array,
	big_int,
	template_object,
	function_bytecode,
	module,
	typed_array,
	array_buffer,
	shared_array_buffer,
	regexp,
	date,
	object_value,
	object_reference,
	map_tag,
	set_tag,
	symbol,
}

BC_VERSION :: 29 // 28 is QuickJS's: frontend/serialize.odin says what differs

// A script's stream, shared by the functions read from it: the bodies not read yet are in it, the line tables and the source
// of those that were point into it. Never written to: JS_WriteObject hands it out as it came.
Bytecode_Store :: struct {
	buf:     []u8,
	atoms:   []Atom, // the stream's atoms, ATOM_NULL until read if atom_at has an offset
	atom_at: []u32,
	refs:    int,    // the functions, and a reader at work
	marked:  int,    // the collection (Runtime.gc_count + 1) that marked its atoms last: once for all its functions
}

// The atoms a stream's functions use are those of its table: a live function keeps them (the atoms are weak, atom.odin).
store_mark_atoms :: proc(rt: ^Runtime, s: ^Bytecode_Store) {
	if s == nil || s.marked == rt.gc_count + 1 {return}
	s.marked = rt.gc_count + 1
	for a in s.atoms {mark_atom(rt, a)}
}

@(private = "file")
store_new :: proc(rt: ^Runtime, buf: []u8) -> ^Bytecode_Store {
	s := new(Bytecode_Store, rt_allocator(rt))
	s.buf = buf
	s.refs = 1
	return s
}

store_release :: proc(rt: ^Runtime, s: ^Bytecode_Store) {
	s.refs -= 1
	if s.refs > 0 {return}
	a := rt_allocator(rt)
	delete(s.buf, a)
	delete(s.atoms, a)
	delete(s.atom_at, a)
	free(s, a)
}

@(private = "file")
Reader :: struct {
	ctx:   ^Context,
	store: ^Bytecode_Store,
	buf:   []u8,
	pos:   int,
	err:   bool,
	msg:   string,
	depth: int,
}

// Parse a serialized value. Returns a .function_bc / .module / ordinary value, or EXCEPTION.
read_object :: proc(ctx: ^Context, buf: []u8) -> Value {
	own := make([]u8, len(buf), rt_allocator(ctx.rt))
	copy(own, buf)
	return read_object_own(ctx, own)
}

// read_object of a stream made with rt_allocator: the functions keep it.
read_object_own :: proc(ctx: ^Context, buf: []u8) -> Value {
	rt := ctx.rt
	store := store_new(rt, buf)
	defer store_release(rt, store)
	r := Reader{ctx = ctx, store = store, buf = buf}
	rt.gc_disabled += 1
	defer rt.gc_disabled -= 1
	if !read_header(&r) {
		return throw_syntax_error(ctx, r.msg != "" ? r.msg : "invalid bytecode header")
	}
	v := read_value(&r)
	if r.err || is_exception(v) {
		if has_exception(ctx) {return EXCEPTION}
		return throw_syntax_error(ctx, r.msg != "" ? r.msg : "invalid bytecode")
	}
	// (what runs at once is read now: a caller can still compile the source instead)
	top: ^Function_Bytecode
	#partial switch v.tag {
	case .function_bc: top = cast(^Function_Bytecode)v.u.ptr
	case .module: top = (cast(^Module)v.u.ptr).func_bc
	}
	if top != nil {
		if msg := function_body(ctx, top); msg != "" {return throw_syntax_error(ctx, msg)}
	}
	return v
}

@(private = "file")
fail :: proc(r: ^Reader, msg: string) {
	if !r.err {r.msg = msg}
	r.err = true
}

@(private = "file")
u8_ :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.buf) {fail(r, "truncated bytecode"); return 0}
	v := r.buf[r.pos]
	r.pos += 1
	return v
}

@(private = "file")
u16_ :: proc(r: ^Reader) -> u16 {
	if r.pos + 2 > len(r.buf) {fail(r, "truncated bytecode"); return 0}
	v := u16(r.buf[r.pos]) | u16(r.buf[r.pos + 1]) << 8
	r.pos += 2
	return v
}

@(private = "file")
u32_ :: proc(r: ^Reader) -> u32 {
	if r.pos + 4 > len(r.buf) {fail(r, "truncated bytecode"); return 0}
	b := r.buf[r.pos:]
	v := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	r.pos += 4
	return v
}

@(private = "file")
u64_ :: proc(r: ^Reader) -> u64 {
	lo := u64(u32_(r))
	hi := u64(u32_(r))
	return lo | hi << 32
}

@(private = "file")
leb :: proc(r: ^Reader) -> u32 {
	v: u32 = 0
	for i in 0 ..< 5 {
		if r.pos >= len(r.buf) {fail(r, "truncated bytecode"); return 0}
		c := r.buf[r.pos]
		r.pos += 1
		v |= u32(c & 0x7f) << uint(i * 7)
		if c & 0x80 == 0 {return v}
	}
	fail(r, "invalid leb128")
	return 0
}

@(private = "file")
sleb :: proc(r: ^Reader) -> i32 {
	v := leb(r)
	return i32(v >> 1) ~ -i32(v & 1)
}

// A count that must fit in the remaining input (each element takes at least `min_bytes`).
@(private = "file")
count :: proc(r: ^Reader, min_bytes: int, limit: u32 = BC_COUNT_LIMIT) -> int {
	n := leb(r)
	if r.err {return 0}
	if n > limit || int(n) * min_bytes > len(r.buf) - r.pos {
		fail(r, "invalid count in bytecode")
		return 0
	}
	return int(n)
}

@(private = "file")
read_header :: proc(r: ^Reader) -> bool {
	rt := r.ctx.rt
	if u8_(r) != BC_VERSION || r.err {
		r.msg = "unsupported bytecode version"
		return false
	}
	_ = u32_(r) // checksum (not verified)
	n := count(r, 1)
	if r.err {return false}
	a := rt_allocator(rt)
	st := r.store
	st.atoms = make([]Atom, n, a)
	st.atom_at = make([]u32, n, a)
	for i in 0 ..< n {
		at := r.pos
		t := u8_(r)
		if r.err {return false}
		if t & 0x80 != 0 {
			c: u32 = 0
			if t & 0x40 != 0 {c = leb(r)}
			c = (c << 6) | u32(t & 0x3f)
			if c >= PREDEF_ATOM_COUNT {fail(r, "invalid const atom"); return false}
			st.atoms[i] = Atom(c)
			continue
		}
		if t < 1 || t > 4 {fail(r, "invalid atom type"); return false}
		st.atom_at[i] = u32(at)
		packed := leb(r)
		if r.err {return false}
		size := packed & 1 != 0 ? int(packed >> 1) * 2 : int(packed >> 1)
		if int(packed >> 1) > STRING_LEN_MAX || size > len(r.buf) - r.pos {fail(r, "invalid string length"); return false}
		r.pos += size
	}
	return !r.err
}

// The atom the table has at `i`, read at its first use.
@(private = "file")
atom_load :: proc(r: ^Reader, i: int) -> Atom {
	rt := r.ctx.rt
	st := r.store
	saved := r.pos
	defer r.pos = saved
	r.pos = int(st.atom_at[i])
	t := u8_(r)
	s := read_string(r)
	if s == nil {return ATOM_NULL}
	if t == 1 {
		st.atoms[i] = atom_from_string(rt, s)
	} else {
		// symbols in a bytecode atom table: fresh symbols with that description
		sym := symbol_new_raw(rt, mk_str(s), t == 4)
		sym.is_registered = t == 2
		st.atoms[i] = atom_from_symbol(rt, sym)
	}
	return st.atoms[i]
}

// bc_idx_to_atom: a stream atom index (tagged int, predefined, or header table).
@(private = "file")
idx_atom :: proc(r: ^Reader, idx: u32) -> Atom {
	if idx & ATOM_TAG_INT != 0 {return Atom(idx)}
	if idx < PREDEF_ATOM_COUNT {return Atom(idx)}
	off := int(idx - PREDEF_ATOM_COUNT)
	st := r.store
	if off >= len(st.atoms) {
		fail(r, "invalid atom index")
		return ATOM_NULL
	}
	if st.atoms[off] == ATOM_NULL && st.atom_at[off] != 0 {return atom_load(r, off)}
	return st.atoms[off]
}

// bc_get_atom: leb128 with bit 0 = tagged int.
@(private = "file")
atom_ :: proc(r: ^Reader) -> Atom {
	v := leb(r)
	if r.err {return ATOM_NULL}
	if v & 1 != 0 {
		n := v >> 1
		if n > ATOM_MAX_INT {fail(r, "invalid int atom"); return ATOM_NULL}
		return atom_from_u32(n)
	}
	return idx_atom(r, v >> 1)
}

@(private = "file")
read_string :: proc(r: ^Reader) -> ^JS_String {
	rt := r.ctx.rt
	packed := leb(r)
	if r.err {return nil}
	wide := packed & 1 != 0
	n := int(packed >> 1)
	need := wide ? n * 2 : n
	if n > STRING_LEN_MAX || need > len(r.buf) - r.pos {fail(r, "invalid string length"); return nil}
	if wide {
		u := make([]u16, n, rt.allocator)
		defer delete(u, rt.allocator)
		for i in 0 ..< n {u[i] = u16(r.buf[r.pos + 2 * i]) | u16(r.buf[r.pos + 2 * i + 1]) << 8}
		r.pos += need
		return str_from_u16(rt, u)
	}
	s := str_from_latin1(rt, r.buf[r.pos:r.pos + n])
	r.pos += n
	return s
}

@(private = "file")
read_value :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	r.depth += 1
	defer r.depth -= 1
	if r.depth > BC_MAX_NESTING {fail(r, "bytecode nesting too deep"); return EXCEPTION}
	t := u8_(r)
	if r.err {return EXCEPTION}
	if t > u8(BC_Tag.symbol) {fail(r, "invalid tag"); return EXCEPTION}
	#partial switch BC_Tag(t) {
	case .null:
		return NULL
	case .undefined:
		return UNDEFINED
	case .bool_false:
		return FALSE
	case .bool_true:
		return TRUE
	case .int32:
		return mk_int(sleb(r))
	case .float64:
		return mk_float(transmute(f64)u64_(r))
	case .string:
		s := read_string(r)
		if s == nil {return EXCEPTION}
		return mk_str(s)
	case .big_int:
		return read_bigint(r)
	case .function_bytecode:
		return read_function(r)
	case .module:
		return read_module(r)
	case .array, .template_object:
		return read_array(r, BC_Tag(t) == .template_object)
	case .object:
		o := new_plain_object(r.ctx)
		n := count(r, 2)
		for _ in 0 ..< n {
			a := atom_(r)
			v := read_value(r)
			if r.err || is_exception(v) {return EXCEPTION}
			define_value(r.ctx, o, a, v, CWE)
		}
		return mk_obj(o)
	case .symbol:
		a := atom_(r)
		if r.err {return EXCEPTION}
		sym := atom_symbol(rt, a)
		if sym == nil {fail(r, "invalid symbol"); return EXCEPTION}
		return mk_sym(sym)
	}
	fail(r, "unsupported bytecode tag")
	return EXCEPTION
}

@(private = "file")
read_array :: proc(r: ^Reader, is_template: bool) -> Value {
	ctx := r.ctx
	n := count(r, 1)
	if r.err {return EXCEPTION}
	arr := array_new(ctx, n)
	for i in 0 ..< n {
		v := read_value(r)
		if r.err || is_exception(v) {return EXCEPTION}
		if is_template {
			define_own_property(ctx, arr, atom_from_u32(u32(i)), data_desc(v, {.enumerable}), false)
		} else {
			create_data_property(ctx, arr, atom_from_u32(u32(i)), v, false)
		}
	}
	if is_template {
		raw := read_value(r)
		if r.err || is_exception(raw) {return EXCEPTION}
		if !is_undefined(raw) {
			define_own_property(ctx, arr, pa(.A_raw), data_desc(raw, {}), false)
		}
		set_property_flags(ctx.rt, arr, 0, {}, .data) // length: non-writable
		arr.extensible = false
	}
	return mk_obj(arr)
}

@(private = "file")
read_bigint :: proc(r: ^Reader) -> Value {
	n := count(r, 1, BC_BIGINT_COUNT_LIMIT)
	if r.err {return EXCEPTION}
	ctx := r.ctx
	if n == 0 {return bigint_from_i64(ctx, 0)}
	bytes := r.buf[r.pos:r.pos + n]
	r.pos += n
	return mk_big(bigint_from_twos_complement(ctx.rt, bytes))
}

@(private = "file")
read_function :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	a := rt_allocator(rt)
	b := function_bc_new(rt)
	b.realm = r.ctx
	b.store = r.store
	b.store.refs += 1
	b.code = LAZY_CODE[:]
	flags := u16_(r)
	idx: uint = 0
	bit :: proc(f: u16, idx: ^uint, n: uint) -> u16 {
		v := (f >> idx^) & u16((1 << n) - 1)
		idx^ += n
		return v
	}
	b.has_prototype = bit(flags, &idx, 1) != 0
	b.has_simple_parameter_list = bit(flags, &idx, 1) != 0
	b.is_derived_class_ctor = bit(flags, &idx, 1) != 0
	b.need_home_object = bit(flags, &idx, 1) != 0
	b.func_kind = Func_Kind(bit(flags, &idx, 2))
	b.new_target_allowed = bit(flags, &idx, 1) != 0
	b.super_call_allowed = bit(flags, &idx, 1) != 0
	b.super_allowed = bit(flags, &idx, 1) != 0
	b.arguments_allowed = bit(flags, &idx, 1) != 0
	b.backtrace_barrier = bit(flags, &idx, 1) != 0
	b.has_debug = bit(flags, &idx, 1) != 0
	b.is_strict_mode = u8_(r) != 0
	b.func_name = atom_(r)
	u16v :: proc(r: ^Reader) -> u16 {
		v := leb(r)
		if v > 0xffff {fail(r, "invalid function size field")}
		return u16(v)
	}
	b.arg_count = u16v(r)
	b.var_count = u16v(r)
	b.defined_arg_count = u16v(r)
	b.stack_size = u16v(r)
	b.var_ref_count = u16v(r)
	b.closure_var_count = u16v(r)
	if b.has_debug {
		b.filename = atom_(r)
		b.line_num = int(leb(r))
		b.col_num = int(leb(r))
	}
	if r.err {return EXCEPTION}
	if b.closure_var_count > 0 {
		if int(b.closure_var_count) * 2 > len(r.buf) - r.pos {fail(r, "invalid closure count"); return EXCEPTION}
		b.closure_vars = make([]Closure_Var, int(b.closure_var_count), a)
		for i in 0 ..< int(b.closure_var_count) {
			cv := &b.closure_vars[i]
			vi := leb(r)
			if vi > 0xffff {fail(r, "invalid closure index"); return EXCEPTION}
			cv.var_idx = u16(vi)
			cf := leb(r)
			cv.closure_type = Closure_Type(cf & 7)
			cv.is_const = (cf >> 3) & 1 != 0
			cv.is_lexical = (cf >> 4) & 1 != 0
			cv.var_kind = u8((cf >> 5) & 0xf)
			if r.err {return EXCEPTION}
		}
	}
	body_len := int(u32_(r))
	if r.err {return EXCEPTION}
	if body_len == 0 || body_len > len(r.buf) - r.pos {fail(r, "invalid function body"); return EXCEPTION}
	b.body_at = u32(r.pos)
	b.body_len = u32(body_len)
	r.pos += body_len
	rt.functions_read += 1
	return mk_ptr(.function_bc, b)
}

// What is not needed before the function runs. The line table and the source stay in the stream.
@(private = "file")
read_body :: proc(r: ^Reader, b: ^Function_Bytecode) -> bool {
	a := rt_allocator(r.ctx.rt)
	for &cv in b.closure_vars {cv.name = atom_(r)}
	cpool_count := count(r, 1)
	code_len := count(r, 1)
	local_count := count(r, 4)
	if r.err {return false}
	if local_count != 0 && local_count != int(b.arg_count) + int(b.var_count) {fail(r, "invalid local count"); return false}
	if local_count == 0 && int(b.arg_count) + int(b.var_count) != 0 {fail(r, "missing variable definitions"); return false}
	if local_count > 0 {
		b.vardefs = make([]Var_Def, local_count, a)
		for i in 0 ..< local_count {
			vd := &b.vardefs[i]
			vd.name = atom_(r)
			vd.scope_level = i32(leb(r))
			vd.scope_next = i32(leb(r)) - 1
			vf := u8_(r)
			vd.var_kind = vf & 0x0f
			vd.is_const = (vf >> 4) & 1 != 0
			vd.is_lexical = (vf >> 5) & 1 != 0
			vd.is_captured = (vf >> 6) & 1 != 0
			if vd.is_captured {
				k := leb(r)
				if k >= u32(b.var_ref_count) {fail(r, "invalid var_ref index"); return false}
				vd.var_ref_idx = u16(k)
			}
			if r.err {return false}
		}
	}
	if cpool_count > 0 {
		b.cpool = make([]Value, cpool_count, a)
		for i in 0 ..< cpool_count {b.cpool[i] = UNDEFINED}
		for i in 0 ..< cpool_count {
			v := read_value(r)
			if r.err || is_exception(v) {return false}
			b.cpool[i] = v
		}
	}
	if code_len == 0 {fail(r, "empty bytecode"); return false}
	if code_len > len(r.buf) - r.pos {fail(r, "truncated bytecode"); return false}
	code := make([]u8, code_len, a)
	copy(code, r.buf[r.pos:r.pos + code_len])
	b.code = code
	r.pos += code_len
	if !remap_code_atoms(r, b) {return false}
	if b.has_debug {
		n := count(r, 1)
		if r.err {return false}
		b.pc2line = r.buf[r.pos:r.pos + n]
		r.pos += n
		sn := count(r, 1, BC_SOURCE_COUNT_LIMIT)
		if r.err {return false}
		b.source = r.buf[r.pos:r.pos + sn]
		r.pos += sn
	}
	return true
}

// The code of a function that has not run: one instruction, which makes it ready and starts it again. Whatever enters a function
// ends up here, so nothing runs unread or unchecked, and a call pays nothing for it. What a frame is made of (the counts of the
// function's head) does not need the body; stack_size is checked against the code before anything uses the stack.
LAZY_CODE := [1]u8{u8(Opcode.lazy_body)}

// Reads and verifies the function's body if it never ran. "": it may run. Else why not: it stays as it was, each call fails again.
bytecode_check :: proc(ctx: ^Context, b: ^Function_Bytecode) -> string {
	if b.body_len == 0 {return ""}
	span_stage(.deserialize, true)
	defer span_stage(.deserialize, false)
	return function_body(ctx, b)
}

@(private = "file")
function_body :: proc(ctx: ^Context, b: ^Function_Bytecode) -> string {
	rt := ctx.rt
	end := int(b.body_at) + int(b.body_len)
	r := Reader{ctx = b.realm, store = b.store, buf = b.store.buf[:end], pos = int(b.body_at)}
	// (a body read makes strings and the heads of the functions in it, held by nothing yet)
	rt.gc_disabled += 1
	defer rt.gc_disabled -= 1
	if read_body(&r, b) && r.pos == end && verify_function(&r, b) {
		b.body_len = 0
		rt.functions_verified += 1
		return ""
	}
	function_bc_free_body(rt, b)
	b.code = LAZY_CODE[:]
	return r.msg != "" ? r.msg : "invalid bytecode"
}

// bytecode_check, its failure thrown: a SyntaxError from the call, in place of the one the reader gave for the whole script.
bytecode_ready :: proc(ctx: ^Context, b: ^Function_Bytecode) -> bool {
	msg := bytecode_check(ctx, b)
	if msg != "" {
		throw_syntax_error(ctx, msg)
		return false
	}
	return true
}

// Reads the body of the function and of those nested in it, as their first runs would: the fuzzer's way to every body. False: one failed.
bytecode_read_all :: proc(ctx: ^Context, b: ^Function_Bytecode) -> bool {
	if bytecode_check(ctx, b) != "" {return false}
	ok := true
	for c in b.cpool {
		if c.tag == .function_bc {ok = bytecode_read_all(ctx, cast(^Function_Bytecode)c.u.ptr) && ok}
	}
	return ok
}

// Rewrite the atom operands of the instruction stream to runtime atoms.
@(private = "file")
remap_code_atoms :: proc(r: ^Reader, b: ^Function_Bytecode) -> bool {
	code := b.code
	pos := 0
	for pos < len(code) {
		op := code[pos]
		if int(op) >= OPCODE_COUNT {fail(r, "invalid opcode"); return false}
		info := opcode_info[Opcode(op)]
		size := int(info.size)
		if size == 0 || pos + size > len(code) {fail(r, "truncated instruction"); return false}
		#partial switch info.fmt {
		case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
			p := pos + 1
			idx := u32(code[p]) | u32(code[p + 1]) << 8 | u32(code[p + 2]) << 16 | u32(code[p + 3]) << 24
			at := idx_atom(r, idx)
			if r.err {return false}
			code[p] = u8(at)
			code[p + 1] = u8(at >> 8)
			code[p + 2] = u8(at >> 16)
			code[p + 3] = u8(at >> 24)
		}
		pos += size
	}
	return true
}

// Check every operand that indexes a table of the function, and every jump target, so the
// interpreter can index without further checks. Stack depth is bounded by slicing the operand
// stack to stack_size in the interpreter.
@(private = "file")
verify_function :: proc(r: ^Reader, b: ^Function_Bytecode) -> bool {
	code := b.code
	n := len(code)
	// (not the scratch memory: it lasts until the outermost call returns, and a page's first calls of its functions come within one)
	rt := r.ctx.rt
	starts := make([]bool, n + 1, rt.allocator)
	defer delete(starts, rt.allocator)
	pos := 0
	for pos < n {
		starts[pos] = true
		pos += int(opcode_info[Opcode(code[pos])].size)
	}
	starts[n] = true
	rd16 :: proc(c: []u8, p: int) -> int {return int(c[p]) | int(c[p + 1]) << 8}
	rd32 :: proc(c: []u8, p: int) -> int {return int(i32(u32(c[p]) | u32(c[p + 1]) << 8 | u32(c[p + 2]) << 16 | u32(c[p + 3]) << 24))}
	target_ok :: proc(starts: []bool, t: int) -> bool {return t >= 0 && t < len(starts) && starts[t]}
	pos = 0
	for pos < n {
		op := Opcode(code[pos])
		info := opcode_info[op]
		p := pos + 1
		ok := true
		#partial switch info.fmt {
		case .loc, .atom_u16 :
			if info.fmt == .loc {ok = rd16(code, p) < int(b.var_count)}
		case .loc8:
			ok = int(code[p]) < int(b.var_count)
		case .arg:
			ok = rd16(code, p) < int(b.arg_count)
		case .var_ref:
			ok = rd16(code, p) < int(b.closure_var_count)
		case .const:
			ok = rd32(code, p) >= 0 && rd32(code, p) < len(b.cpool)
		case .const8:
			ok = int(code[p]) < len(b.cpool)
		case .label:
			ok = target_ok(starts, p + rd32(code, p))
		case .label8:
			ok = target_ok(starts, p + int(i8(code[p])))
		case .label16:
			ok = target_ok(starts, p + int(i16(u16(rd16(code, p)))))
		case .atom_label_u8:
			ok = target_ok(starts, p + 4 + rd32(code, p + 4))
		case .none_loc:
			k := 0
			#partial switch op {
			case .get_loc0_loc1: k = 1
			case .get_loc1, .put_loc1, .set_loc1: k = 1
			case .get_loc2, .put_loc2, .set_loc2: k = 2
			case .get_loc3, .put_loc3, .set_loc3: k = 3
			}
			ok = k < int(b.var_count)
		case .none_arg:
			k := 0
			#partial switch op {
			case .get_arg1, .put_arg1, .set_arg1: k = 1
			case .get_arg2, .put_arg2, .set_arg2: k = 2
			case .get_arg3, .put_arg3, .set_arg3: k = 3
			}
			ok = k < int(b.arg_count)
		case .none_var_ref:
			k := 0
			#partial switch op {
			case .get_var_ref1, .put_var_ref1, .set_var_ref1: k = 1
			case .get_var_ref2, .put_var_ref2, .set_var_ref2: k = 2
			case .get_var_ref3, .put_var_ref3, .set_var_ref3: k = 3
			}
			ok = k < int(b.closure_var_count)
		}
		#partial switch op {
		case .fclosure, .fclosure8:
			idx := op == .fclosure ? rd32(code, p) : int(code[p])
			ok = ok && idx >= 0 && idx < len(b.cpool) && b.cpool[idx].tag == .function_bc
		case .define_class, .define_class_computed:
			// the class constructor bytecode is on the operand stack; checked at run time
		case .make_loc_ref:
			ok = rd16(code, p + 4) < int(b.var_count)
		case .make_arg_ref:
			ok = rd16(code, p + 4) < int(b.arg_count)
		case .make_var_ref_ref:
			ok = rd16(code, p + 4) < int(b.closure_var_count)
		case .using_dispose, .using_dispose_async:
			ok = rd16(code, p) + 1 < int(b.var_count)
		case .close_loc:
			k := rd16(code, p)
			ok = k < int(b.var_count) && b.vardefs != nil
		case .op_catch, .gosub:
		}
		if !ok {
			fail(r, "invalid operand in bytecode")
			return false
		}
		pos += int(info.size)
	}
	// closure cells: a captured variable's cell index, and each child function's captures
	for vd in b.vardefs {
		if vd.is_captured && int(vd.var_ref_idx) >= int(b.var_ref_count) {
			fail(r, "invalid closure cell index")
			return false
		}
	}
	for c in b.cpool {
		if c.tag != .function_bc {continue}
		child := cast(^Function_Bytecode)c.u.ptr
		for cv in child.closure_vars {
			ok := true
			#partial switch cv.closure_type {
			case .local: ok = int(cv.var_idx) < int(b.var_count)
			case .arg: ok = int(cv.var_idx) < int(b.arg_count)
			case: ok = int(cv.var_idx) < int(b.closure_var_count) // read from the parent's cells
			}
			if !ok {
				fail(r, "invalid closure variable")
				return false
			}
		}
	}
	return verify_stack(r, b)
}

// The operand stack height at every instruction (QuickJS's compute_stack_size): no underflow, the
// same height on every path into an instruction, never above stack_size. With this, and the operand
// checks above, the interpreter may index the frame without bounds checks.
@(private = "file")
bad_code :: proc(r: ^Reader, msg: string) -> bool {
	fail(r, msg)
	return false
}

@(private = "file")
verify_stack :: proc(r: ^Reader, b: ^Function_Bytecode) -> bool {
	code := b.code
	n := len(code)
	if n == 0 {return bad_code(r, "empty bytecode")}
	rt := r.ctx.rt
	level := make([]i32, n, rt.allocator)
	defer delete(level, rt.allocator)
	catch_tab := make([]i32, n, rt.allocator)
	defer delete(catch_tab, rt.allocator)
	for i in 0 ..< n {level[i] = -1}
	work := make([dynamic]int, 0, 64, rt.allocator)
	defer delete(work)
	catches := make([dynamic]Catch_Level, 0, 4, rt.allocator)
	defer {
		if len(catches) > 0 && b.catch_levels == nil {
			b.catch_levels = make([]Catch_Level, len(catches), rt_allocator(rt))
			copy(b.catch_levels, catches[:])
		}
		delete(catches)
	}
	max_len := 0
	limit := int(b.stack_size)
	bad :: proc(r: ^Reader, msg: string) -> bool {fail(r, msg); return false}
	check :: proc(level, catch_tab: []i32, work: ^[dynamic]int, pos, stack_len, catch_pos: int) -> int {
		if pos < 0 || pos >= len(level) {return 1}
		if level[pos] >= 0 {
			if int(level[pos]) != stack_len || int(catch_tab[pos]) != catch_pos {return 2}
			return 0
		}
		level[pos] = i32(stack_len)
		catch_tab[pos] = i32(catch_pos)
		append(work, pos)
		return 0
	}
	rd32 :: proc(c: []u8, p: int) -> int {return int(i32(u32(c[p]) | u32(c[p + 1]) << 8 | u32(c[p + 2]) << 16 | u32(c[p + 3]) << 24))}
	rd16 :: proc(c: []u8, p: int) -> int {return int(c[p]) | int(c[p + 1]) << 8}
	if check(level, catch_tab, &work, 0, 0, -1) != 0 {return bad(r, "invalid bytecode")}
	for len(work) > 0 {
		pos := pop(&work)
		stack_len := int(level[pos])
		catch_pos := int(catch_tab[pos])
		op := Opcode(code[pos])
		info := opcode_info[op]
		pos_next := pos + int(info.size)
		n_pop := int(info.n_pop)
		#partial switch info.fmt {
		case .npop, .npop_u16: n_pop += rd16(code, pos + 1)
		case .npopx: n_pop += int(op) - int(Opcode.call0)
		}
		if stack_len < n_pop {return bad(r, "bytecode stack underflow")}
		// instructions that reach below their own operands (the for-of record)
		#partial switch op {
		case .for_of_next:
			k := int(i8(code[pos + 1]))
			if k < 0 || stack_len < 3 + k {return bad(r, "bytecode stack underflow")}
		case .iterator_get_value_done:
			if stack_len < 4 {return bad(r, "bytecode stack underflow")}
		case .copy_data_properties:
			m := int(code[pos + 1])
			if stack_len < 1 + max(m & 3, (m >> 2) & 7, (m >> 5) & 7) {return bad(r, "bytecode stack underflow")}
		}
		stack_len += int(info.n_push) - n_pop
		max_len = max(max_len, stack_len)
		if max_len > limit {return bad(r, "bytecode stack overflow")}
		branch := -1
		has_branch := false
		branch_len := stack_len
		terminal := false
		#partial switch op {
		case .op_return, .return_undef, .return_async, .op_throw, .throw_error, .ret:
			terminal = true
		case .goto: pos_next = pos + 1 + rd32(code, pos + 1)
		case .goto16: pos_next = pos + 1 + int(i16(u16(rd16(code, pos + 1))))
		case .goto8: pos_next = pos + 1 + int(i8(code[pos + 1]))
		case .if_true8, .if_false8:
			branch, has_branch = pos + 1 + int(i8(code[pos + 1])), true
		case .if_true, .if_false:
			branch, has_branch = pos + 1 + rd32(code, pos + 1), true
		case .gosub:
			branch, has_branch = pos + 1 + rd32(code, pos + 1), true
			branch_len = stack_len + 1
		case .with_get_var, .with_delete_var:
			branch, has_branch = pos + 5 + rd32(code, pos + 5), true
			branch_len = stack_len + 1
		case .with_make_ref, .with_get_ref, .with_get_ref_undef:
			branch, has_branch = pos + 5 + rd32(code, pos + 5), true
			branch_len = stack_len + 2
		case .with_put_var:
			branch, has_branch = pos + 5 + rd32(code, pos + 5), true
			branch_len = stack_len - 1
		case .op_catch:
			branch, has_branch = pos + 1 + rd32(code, pos + 1), true
		case .for_of_start, .for_await_of_start:
		case .drop, .nip, .nip1, .iterator_close:
		case .nip_catch:
			if catch_pos < 0 {return bad(r, "nip_catch without catch")}
			stack_len = int(level[catch_pos])
			if Opcode(code[catch_pos]) != .op_catch {stack_len += 1}
			stack_len += 1
			catch_pos = int(catch_tab[catch_pos])
		}
		// the catch bookkeeping of QuickJS (which catch is innermost after an instruction)
		#partial switch op {
		case .op_catch, .for_of_start, .for_await_of_start:
			catch_pos = pos
		case .drop, .nip, .nip1, .iterator_close:
			catch_level := stack_len
			#partial switch op {
			case .nip, .nip1: catch_level = stack_len - 1
			case .iterator_close: catch_level = stack_len + 2
			}
			if catch_pos >= 0 {
				lv := int(level[catch_pos])
				if Opcode(code[catch_pos]) != .op_catch {lv += 1}
				if catch_level == lv {catch_pos = int(catch_tab[catch_pos])}
			}
		}
		if has_branch {
			if branch_len < 0 || branch_len > limit {return bad(r, "bytecode stack overflow")}
			if op == .op_catch {
				found := false
				for c in catches {if int(c.pos) == branch {found = true}}
				if !found {append(&catches, Catch_Level{i32(branch), i32(branch_len)})}
			}
			bc := op == .op_catch ? int(catch_tab[pos]) : catch_pos
			if check(level, catch_tab, &work, branch, branch_len, bc) != 0 {return bad(r, "invalid bytecode branch")}
		}
		if terminal {continue}
		if check(level, catch_tab, &work, pos_next, stack_len, catch_pos) != 0 {return bad(r, "inconsistent bytecode stack")}
	}
	return true
}

// --- modules ---

// A module request. QuickJS bytecode has no import attributes; our compilers fold the `type`
// attribute into the request name as "specifier\0type".
@(private = "file")
request_entry :: proc(ctx: ^Context, name: Atom) -> Req_Entry {
	rt := ctx.rt
	e := Req_Entry{name = name, attributes = UNDEFINED}
	if atom_is_int(name) || atom_is_symbol(rt, name) {return e}
	s := str_flat(rt, atom_to_string(rt, name))
	for i in 0 ..< int(s.len) {
		if str_at(s, i) != 0 {continue}
		e.name = atom_from_string(rt, str_sub(rt, s, 0, i))
		ao := new_plain_object(ctx)
		define_value(ctx, ao, atom_from_utf8(rt, "type"), mk_str(str_sub(rt, s, i + 1, int(s.len))), CWE)
		e.attributes = mk_obj(ao)
		break
	}
	return e
}

@(private = "file")
read_module :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	m := module_new(r.ctx, atom_(r))
	n := count(r, 1)
	for _ in 0 ..< n {
		append(&m.req, request_entry(r.ctx, atom_(r)))
	}
	n = count(r, 2)
	for _ in 0 ..< n {
		e := Export_Entry{}
		e.kind = u8_(r)
		if e.kind == 0 {
			e.var_idx = int(leb(r))
		} else {
			e.req_idx = int(leb(r))
			e.local_name = atom_(r)
		}
		e.export_name = atom_(r)
		if r.err {return EXCEPTION}
		if e.kind != 0 && e.req_idx >= len(m.req) {fail(r, "invalid module request index"); return EXCEPTION}
		append(&m.exports, e)
	}
	n = count(r, 1)
	for _ in 0 ..< n {
		k := int(leb(r))
		if k >= len(m.req) {fail(r, "invalid module request index"); return EXCEPTION}
		append(&m.star_exports, k)
	}
	n = count(r, 3)
	for _ in 0 ..< n {
		e := Import_Entry{}
		e.var_idx = int(leb(r))
		e.import_name = atom_(r)
		e.req_idx = int(leb(r))
		if r.err {return EXCEPTION}
		if e.req_idx >= len(m.req) {fail(r, "invalid module request index"); return EXCEPTION}
		append(&m.imports, e)
	}
	m.has_tla = u8_(r) != 0
	fv := read_value(r)
	if r.err || is_exception(fv) || fv.tag != .function_bc {
		fail(r, "invalid module function")
		return EXCEPTION
	}
	m.func_bc = cast(^Function_Bytecode)fv.u.ptr
	cvc := int(m.func_bc.closure_var_count)
	for e in m.exports {if e.kind == 0 && e.var_idx >= cvc {fail(r, "invalid export index"); return EXCEPTION}}
	for e in m.imports {if e.var_idx >= cvc {fail(r, "invalid import index"); return EXCEPTION}}
	_ = rt
	return mk_ptr(.module, m)
}

// A bigint from a little-endian two's-complement byte string.
bigint_from_twos_complement :: proc(rt: ^Runtime, bytes: []u8) -> ^JS_BigInt {
	context.allocator = rt_allocator(rt)
	neg := len(bytes) > 0 && bytes[len(bytes) - 1] & 0x80 != 0
	n := len(bytes)
	limbs := make([]u32, (n + 3) / 4)
	for i in 0 ..< n {
		b := bytes[i]
		if neg {b = ~b}
		limbs[i / 4] |= u32(b) << uint((i % 4) * 8)
	}
	if neg {
		// magnitude = ~x + 1
		carry: u64 = 1
		for i in 0 ..< len(limbs) {
			s := u64(limbs[i]) + carry
			limbs[i] = u32(s)
			carry = s >> 32
		}
	}
	// trim leading zero limbs
	k := len(limbs)
	for k > 0 && limbs[k - 1] == 0 {k -= 1}
	b := bigint_new(rt, {})
	if k > 0 {
		mag := make([]u32, k)
		copy(mag, limbs[:k])
		b.val.mag = mag
		b.val.neg = neg
	}
	delete(limbs)
	return b
}
