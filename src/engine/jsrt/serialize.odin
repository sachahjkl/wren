package jsrt

// The serialized-bytecode reader: parses JS_WriteObject(..., JS_WRITE_OBJ_BYTECODE) output of
// QuickJS-ng 0.17 (BC_VERSION 28) — what the reference C compiler and the Odin front-end (E1) emit.
//
// Every read is bounds-checked and every count is validated against the remaining input, so a
// corrupt or hostile buffer yields a SyntaxError, never an out-of-bounds access. Operands of the
// instruction stream are checked against the function's own tables (constant pool, locals,
// closure cells) by verify_function, which also keeps the interpreter's indexing safe.

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

BC_VERSION :: 28

@(private = "file")
Reader :: struct {
	ctx:        ^Context,
	buf:        []u8,
	pos:        int,
	err:        bool,
	msg:        string,
	atoms:      []Atom, // decoded header atoms
	first_atom: u32,
	depth:      int,
}

// Parse a serialized value. Returns a .function_bc / .module / ordinary value, or EXCEPTION.
read_object :: proc(ctx: ^Context, buf: []u8) -> Value {
	rt := ctx.rt
	r := Reader{ctx = ctx, buf = buf, first_atom = PREDEF_ATOM_COUNT}
	defer if r.atoms != nil {delete(r.atoms, rt.allocator)}
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
count :: proc(r: ^Reader, min_bytes: int, limit: u32 = 1 << 24) -> int {
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
	r.atoms = make([]Atom, n, rt.allocator)
	for i in 0 ..< n {
		t := u8_(r)
		if r.err {return false}
		if t & 0x80 != 0 {
			a: u32 = 0
			if t & 0x40 != 0 {a = leb(r)}
			a = (a << 6) | u32(t & 0x3f)
			if a >= PREDEF_ATOM_COUNT {fail(r, "invalid const atom"); return false}
			r.atoms[i] = Atom(a)
			continue
		}
		if t < 1 || t > 4 {fail(r, "invalid atom type"); return false}
		s := read_string(r)
		if s == nil {return false}
		switch t {
		case 1:
			r.atoms[i] = atom_from_string(rt, s)
		case:
			// symbols in a bytecode atom table: fresh symbols with that description
			sym := symbol_new_raw(rt, mk_str(s), t == 4)
			sym.is_registered = t == 2
			r.atoms[i] = atom_from_symbol(rt, sym)
		}
	}
	return !r.err
}

// bc_idx_to_atom: a stream atom index (tagged int, predefined, or header table).
@(private = "file")
idx_atom :: proc(r: ^Reader, idx: u32) -> Atom {
	if idx & ATOM_TAG_INT != 0 {return Atom(idx)}
	if idx < r.first_atom {return Atom(idx)}
	off := idx - r.first_atom
	if int(off) >= len(r.atoms) {
		fail(r, "invalid atom index")
		return ATOM_NULL
	}
	return r.atoms[off]
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
		u := make([]u16, n, tmp(rt))
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
	if r.depth > 1000 {fail(r, "bytecode nesting too deep"); return EXCEPTION}
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
	n := count(r, 1, 1 << 27)
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
	cpool_count := count(r, 1)
	code_len := count(r, 1)
	local_count := count(r, 4)
	if r.err {return EXCEPTION}
	if local_count != 0 && local_count != int(b.arg_count) + int(b.var_count) {fail(r, "invalid local count"); return EXCEPTION}
	if local_count == 0 && int(b.arg_count) + int(b.var_count) != 0 {fail(r, "missing variable definitions"); return EXCEPTION}
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
				if k >= u32(b.var_ref_count) {fail(r, "invalid var_ref index"); return EXCEPTION}
				vd.var_ref_idx = u16(k)
			}
			if r.err {return EXCEPTION}
		}
	}
	if b.closure_var_count > 0 {
		if int(b.closure_var_count) * 3 > len(r.buf) - r.pos {fail(r, "invalid closure count"); return EXCEPTION}
		b.closure_vars = make([]Closure_Var, int(b.closure_var_count), a)
		for i in 0 ..< int(b.closure_var_count) {
			cv := &b.closure_vars[i]
			cv.name = atom_(r)
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
	if cpool_count > 0 {
		b.cpool = make([]Value, cpool_count, a)
		for i in 0 ..< cpool_count {b.cpool[i] = UNDEFINED}
		for i in 0 ..< cpool_count {
			v := read_value(r)
			if r.err || is_exception(v) {return EXCEPTION}
			b.cpool[i] = v
		}
	}
	if code_len > len(r.buf) - r.pos {fail(r, "truncated bytecode"); return EXCEPTION}
	b.code = make([]u8, code_len, a)
	copy(b.code, r.buf[r.pos:r.pos + code_len])
	r.pos += code_len
	if !remap_code_atoms(r, b) {return EXCEPTION}
	if b.has_debug {
		b.filename = atom_(r)
		b.line_num = int(leb(r))
		b.col_num = int(leb(r))
		n := count(r, 1)
		if r.err {return EXCEPTION}
		if n > 0 {
			b.pc2line = make([]u8, n, a)
			copy(b.pc2line, r.buf[r.pos:r.pos + n])
			r.pos += n
		}
		sn := count(r, 1, 1 << 30)
		if r.err {return EXCEPTION}
		if sn > 0 {
			b.source = make([]u8, sn, a)
			copy(b.source, r.buf[r.pos:r.pos + sn])
			r.pos += sn
		}
	}
	if !verify_function(r, b) {return EXCEPTION}
	return mk_ptr(.function_bc, b)
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
	starts := make([]bool, n + 1, tmp(r.ctx.rt))
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
	for &cv in b.closure_vars {
		_ = cv
	}
	return true
}

// --- modules ---

@(private = "file")
read_module :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	m := module_new(r.ctx, atom_(r))
	n := count(r, 1)
	for _ in 0 ..< n {
		append(&m.req, Req_Entry{name = atom_(r), attributes = UNDEFINED})
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
