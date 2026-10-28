package jsrt

// The serialized-bytecode reader: parses the output of QuickJS-ng 0.17's JS_WriteObject
// (JS_WRITE_OBJ_BYTECODE). This is the engine's testable entry point before the Odin compiler
// front-end (E1) exists: feed it bytecode produced by the reference C compiler (qjsc / jsengine.exe)
// and run it.
//
// The format (see JS_WriteObjectAtoms / JS_WriteFunctionTag in quickjs.c, BC_VERSION 28):
//   header:  u8 version (==28), u32 checksum, leb128 atom_count, then atom_count atom entries.
//   An atom entry is: u8 type; if type&0x80 it encodes a predefined/const atom index inline, else the
//   low type is the Atom_Type and a JS_WriteString follows.
//   body:    one tagged value (BC_TAG_*). We implement the subset needed to run compiled scripts:
//   function bytecode, module, the primitive and container tags.
//
// Atoms in the stream are indices into a per-read table: value < first_atom (== PREDEF_ATOM_COUNT for
// bytecode) is a predefined atom used directly; otherwise it indexes the atoms decoded from the
// header. We map both onto the runtime's atom table.

import "wb:engine/bigint"
import "core:fmt"

// Flip to true when diagnosing a reader failure against reference bytecode.
SERIALIZE_DEBUG :: #config(SERIALIZE_DEBUG, false)

@(private = "file")
serialize_dbg :: proc(msg: string, pos: int) {
	fmt.eprintfln("[serialize] fail: %s at pos %d", msg, pos)
}

@(private = "file")
serialize_dbg_fn :: proc(ac, vc, cvc, cpool, bclen: u32, pos: int) {
	fmt.eprintfln("[serialize] fn: args=%d vars=%d closures=%d cpool=%d bc_len=%d pos=%d", ac, vc, cvc, cpool, bclen, pos)
}

@(private = "file")
serialize_dbg_dbg :: proc(fn: Atom, line, col, p2l: u32, pos: int) {
	fmt.eprintfln("[serialize] dbg: filename=%d line=%d col=%d pc2line=%d pos=%d", fn, line, col, p2l, pos)
}

// Serialized-value tags, mirroring BC_TAG_* in quickjs.c (order matters).
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

Reader :: struct {
	ctx:          ^Context,
	buf:          []u8,
	pos:          int,
	err:          bool,
	err_msg:      string,
	// Per-read atom table: the atoms decoded from the header, 0-based (index i is the (first_atom+i)th
	// atom in the stream's numbering). Predefined atoms (index < first_atom) are not stored here.
	idx_to_atom:  []Atom,
	decoded_count: int,
	first_atom:   u32,
	allow_bytecode: bool,
}

// Parse a serialized object and return it as a Value (owned). On failure, throws a SyntaxError and
// returns EXCEPTION.
read_object :: proc(ctx: ^Context, buf: []u8, allow_bytecode := true) -> Value {
	r := Reader{ctx = ctx, buf = buf, allow_bytecode = allow_bytecode}
	r.first_atom = allow_bytecode ? PREDEF_ATOM_COUNT : 1
	defer if r.idx_to_atom != nil {delete(r.idx_to_atom, ctx.rt.allocator)}

	if !read_atoms(&r) {
		return throw_syntax_error(ctx, r.err_msg != "" ? r.err_msg : "invalid bytecode header")
	}
	v := read_value(&r)
	if r.err {
		value_free(ctx.rt, v)
		when SERIALIZE_DEBUG {
			serialize_dbg(r.err_msg, r.pos)
		}
		return throw_syntax_error(ctx, r.err_msg != "" ? r.err_msg : "invalid bytecode")
	}
	return v
}

// --- primitive stream readers ---

@(private = "file")
rd_u8 :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.buf) {r.err = true; return 0}
	v := r.buf[r.pos]
	r.pos += 1
	return v
}

@(private = "file")
rd_u16 :: proc(r: ^Reader) -> u16 {
	a := u16(rd_u8(r))
	b := u16(rd_u8(r))
	return a | (b << 8)
}

@(private = "file")
rd_u32 :: proc(r: ^Reader) -> u32 {
	a := u32(rd_u8(r))
	b := u32(rd_u8(r))
	c := u32(rd_u8(r))
	d := u32(rd_u8(r))
	return a | (b << 8) | (c << 16) | (d << 24)
}

@(private = "file")
rd_u64 :: proc(r: ^Reader) -> u64 {
	lo := u64(rd_u32(r))
	hi := u64(rd_u32(r))
	return lo | (hi << 32)
}

// Unsigned LEB128.
@(private = "file")
rd_leb128 :: proc(r: ^Reader) -> u32 {
	result: u32 = 0
	shift: u32 = 0
	for {
		b := rd_u8(r)
		if r.err {return 0}
		result |= u32(b & 0x7F) << shift
		if b & 0x80 == 0 {break}
		shift += 7
		if shift >= 32 {r.err = true; break}
	}
	return result
}

// Signed LEB128.
@(private = "file")
rd_sleb128 :: proc(r: ^Reader) -> i32 {
	result: i32 = 0
	shift: u32 = 0
	b: u8
	for {
		b = rd_u8(r)
		if r.err {return 0}
		result |= i32(b & 0x7F) << shift
		shift += 7
		if b & 0x80 == 0 {break}
		if shift >= 32 {r.err = true; break}
	}
	if shift < 32 && (b & 0x40) != 0 {
		result |= ~i32(0) << shift
	}
	return result
}

// --- atom header ---

@(private = "file")
read_atoms :: proc(r: ^Reader) -> bool {
	version := rd_u8(r)
	if r.err || version != BC_VERSION {
		r.err_msg = "unsupported bytecode version"
		return false
	}
	_ = rd_u32(r) // checksum; the writer may store UINT32_MAX to disable it. We do not verify it.

	count := rd_leb128(r)
	if r.err || count > 1_000_000 {
		r.err_msg = "unreasonable atom count"
		return false
	}
	// idx_to_atom holds just the decoded atoms, 0-based.
	r.idx_to_atom = make([]Atom, int(count), r.ctx.rt.allocator)
	r.decoded_count = int(count)
	for i in 0 ..< count {
		type := rd_u8(r)
		if r.err {return false}
		if type & 0x80 != 0 {
			// Inline predefined/const atom.
			atom: u32 = 0
			if type & 0x40 != 0 {
				atom = rd_leb128(r)
			}
			atom = (atom << 6) | u32(type & 0x3F)
			r.idx_to_atom[i] = Atom(atom)
		} else {
			if type < u8(Atom_Type.string) || type >= u8(Atom_Type.private) {
				r.err_msg = "invalid atom type"
				return false
			}
			s := read_string_cell(r)
			if s == nil {return false}
			a := atom_intern_string(r.ctx.rt, s, Atom_Type(type))
			string_unref(r.ctx.rt, s)
			r.idx_to_atom[i] = a
		}
	}
	return true
}

// Read an atom in the bc_get_atom encoding (used for func_name, vardef/closure names, filename): a
// leb128 where bit 0 flags a tagged-int atom (value in the high bits) and otherwise the high bits are
// an index resolved by bc_idx_to_atom.
@(private = "file")
rd_atom :: proc(r: ^Reader) -> Atom {
	v := rd_leb128(r)
	if r.err {return Atom(Predef_Atom.null_atom)}
	if v & 1 != 0 {
		return atom_from_int(v >> 1)
	}
	return idx_to_atom(r, v >> 1)
}

// Resolve a 0-based atom index as bc_idx_to_atom does: a tagged int passes through; an index below
// first_atom is a predefined atom used directly; otherwise it indexes the per-read decoded table.
@(private = "file")
idx_to_atom :: proc(r: ^Reader, idx: u32) -> Atom {
	if idx & ATOM_TAG_INT != 0 {
		return Atom(idx)
	}
	if idx < r.first_atom {
		return Atom(idx)
	}
	off := idx - r.first_atom
	if int(off) >= r.decoded_count {
		r.err = true
		r.err_msg = "invalid atom index"
		return Atom(Predef_Atom.null_atom)
	}
	return r.idx_to_atom[off]
}

// --- JS_ReadString: leb128 (len<<1 | is_wide), then the code units ---

@(private = "file")
read_string_cell :: proc(r: ^Reader) -> ^JS_String {
	packed := rd_leb128(r)
	if r.err {return nil}
	is_wide := (packed & 1) != 0
	n := packed >> 1
	if is_wide {
		s := string_alloc_wide(r.ctx.rt, n)
		if s == nil {r.err = true; return nil}
		dst := ([^]u16)(s.data)
		for i in 0 ..< n {
			dst[i] = rd_u16(r)
		}
		if r.err {string_unref(r.ctx.rt, s); return nil}
		return s
	}
	s := string_alloc_latin1(r.ctx.rt, n)
	if s == nil {r.err = true; return nil}
	dst := ([^]u8)(s.data)
	for i in 0 ..< n {
		dst[i] = rd_u8(r)
	}
	if r.err {string_unref(r.ctx.rt, s); return nil}
	return s
}

// --- the tagged value dispatch ---

read_value :: proc(r: ^Reader) -> Value {
	tag := BC_Tag(rd_u8(r))
	if r.err {return EXCEPTION}
	rt := r.ctx.rt
	#partial switch tag {
	case .null:
		return NULL
	case .undefined:
		return UNDEFINED
	case .bool_false:
		return FALSE
	case .bool_true:
		return TRUE
	case .int32:
		return mk_int(rd_sleb128(r))
	case .float64:
		bits := rd_u64(r)
		return mk_number(transmute(f64)bits)
	case .string:
		s := read_string_cell(r)
		if s == nil {return EXCEPTION}
		return mk_heap(.string, s)
	case .big_int:
		return read_bigint(r)
	case .function_bytecode:
		return read_function(r)
	case .module:
		return read_module(r)
	case .array:
		return read_array(r)
	case .object:
		return read_plain_object(r)
	case .template_object:
		return read_array(r) // a frozen array of raw strings; treated as an array here
	case:
		r.err = true
		r.err_msg = "unsupported bytecode tag"
		return EXCEPTION
	}
}

// --- BigInt (two's-complement little-endian byte length) ---

@(private = "file")
read_bigint :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	n := rd_leb128(r)
	if r.err {return EXCEPTION}
	if n == 0 {
		return mk_heap(.bigint, bigint_from_i64(rt, 0))
	}
	bytes := make([]u8, int(n), rt.allocator)
	defer delete(bytes, rt.allocator)
	for i in 0 ..< n {
		bytes[i] = rd_u8(r)
	}
	if r.err {return EXCEPTION}
	cell := bigint_from_twos_complement(rt, bytes)
	if cell == nil {return EXCEPTION}
	return mk_heap(.bigint, cell)
}

// --- function bytecode ---

@(private = "file")
read_function :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	if !r.allow_bytecode {
		r.err = true
		r.err_msg = "bytecode not allowed"
		return EXCEPTION
	}
	fb := function_bc_new(rt)
	if fb == nil {return EXCEPTION}

	flags := rd_u16(r)
	idx := 0
	get_flag :: proc(flags: u16, idx: ^int, n: int) -> u16 {
		mask := u16((1 << uint(n)) - 1)
		v := (flags >> uint(idx^)) & mask
		idx^ += n
		return v
	}
	fb.has_prototype = get_flag(flags, &idx, 1) != 0
	fb.has_simple_parameter_list = get_flag(flags, &idx, 1) != 0
	fb.is_derived_class_ctor = get_flag(flags, &idx, 1) != 0
	fb.need_home_object = get_flag(flags, &idx, 1) != 0
	fb.func_kind = Func_Kind(get_flag(flags, &idx, 2))
	fb.new_target_allowed = get_flag(flags, &idx, 1) != 0
	fb.super_call_allowed = get_flag(flags, &idx, 1) != 0
	fb.super_allowed = get_flag(flags, &idx, 1) != 0
	fb.arguments_allowed = get_flag(flags, &idx, 1) != 0
	fb.backtrace_barrier = get_flag(flags, &idx, 1) != 0
	fb.has_debug = get_flag(flags, &idx, 1) != 0

	fb.is_strict_mode = rd_u8(r) != 0
	fb.func_name = rd_atom(r)

	fb.arg_count = rd_leb128(r)
	fb.var_count = rd_leb128(r)
	fb.defined_arg_count = rd_leb128(r)
	fb.stack_size = rd_leb128(r)
	fb.var_ref_count = rd_leb128(r)
	fb.closure_var_count = rd_leb128(r)
	cpool_count := rd_leb128(r)
	byte_code_len := rd_leb128(r)
	if r.err {function_bc_unref(rt, fb); return EXCEPTION}
	when SERIALIZE_DEBUG {
		serialize_dbg_fn(fb.arg_count, fb.var_count, fb.closure_var_count, cpool_count, byte_code_len, r.pos)
	}

	// Local variable definitions.
	vardef_count := rd_leb128(r)
	if vardef_count > 0 {
		fb.vardefs = make([]Var_Def, int(vardef_count), rt.allocator)
		for i in 0 ..< vardef_count {
			vd := &fb.vardefs[i]
			vd.name = rd_atom(r)
			vd.scope_level = rd_leb128(r)
			vd.scope_next = i32(rd_leb128(r)) - 1
			vflags := rd_u8(r)
			vd.var_kind = vflags & 0x0F
			vd.is_const = (vflags >> 4) & 1 != 0
			vd.is_lexical = (vflags >> 5) & 1 != 0
			vd.is_captured = (vflags >> 6) & 1 != 0
			if vd.is_captured {
				vd.var_ref_idx = rd_leb128(r)
			}
		}
	}

	// Closure variables.
	if fb.closure_var_count > 0 {
		fb.closure_vars = make([]Closure_Var, int(fb.closure_var_count), rt.allocator)
		for i in 0 ..< fb.closure_var_count {
			cv := &fb.closure_vars[i]
			cv.name = rd_atom(r)
			cv.var_idx = rd_leb128(r)
			cflags := rd_leb128(r)
			cv.closure_type = u8(cflags & 0x07)
			cv.is_const = (cflags >> 3) & 1 != 0
			cv.is_lexical = (cflags >> 4) & 1 != 0
			cv.var_kind = u8((cflags >> 5) & 0x0F)
		}
	}

	// Constant pool (written before the code).
	if cpool_count > 0 {
		fb.cpool = make([]Value, int(cpool_count), rt.allocator)
		for i in 0 ..< cpool_count {
			fb.cpool[i] = read_value(r)
			if r.err {function_bc_unref(rt, fb); return EXCEPTION}
		}
	}

	// The instruction stream. Atom operands are stored as 32-bit stream indices; rewrite them to
	// runtime atoms in place so the interpreter reads final atoms directly.
	if byte_code_len > 0 {
		fb.byte_code = make([]u8, int(byte_code_len), rt.allocator)
		for i in 0 ..< byte_code_len {
			fb.byte_code[i] = rd_u8(r)
		}
		if r.err {function_bc_unref(rt, fb); return EXCEPTION}
		if !rewrite_atoms(r, fb.byte_code) {
			function_bc_unref(rt, fb)
			return EXCEPTION
		}
	}

	// Debug info.
	if fb.has_debug {
		fb.filename = rd_atom(r)
		fb.line_num = rd_leb128(r)
		fb.col_num = rd_leb128(r)
		p2l := rd_leb128(r)
		when SERIALIZE_DEBUG {
			serialize_dbg_dbg(fb.filename, fb.line_num, fb.col_num, p2l, r.pos)
		}
		if p2l > 0 {
			fb.pc2line = make([]u8, int(p2l), rt.allocator)
			for i in 0 ..< p2l {fb.pc2line[i] = rd_u8(r)}
		}
		src_len := rd_leb128(r)
		if src_len > 0 {
			fb.source = make([]u8, int(src_len), rt.allocator)
			for i in 0 ..< src_len {fb.source[i] = rd_u8(r)}
		}
	}
	if r.err {function_bc_unref(rt, fb); return EXCEPTION}
	return mk_heap(.function_bc, cast(^GC_Header)fb)
}

// Walk the instruction stream and replace the 4-byte atom-index operands with runtime atoms. Uses the
// generated opcode_info table (size + fmt) to step through instructions.
@(private = "file")
rewrite_atoms :: proc(r: ^Reader, code: []u8) -> bool {
	pos := 0
	for pos < len(code) {
		op := code[pos]
		if int(op) >= OPCODE_COUNT {
			r.err = true
			r.err_msg = "invalid opcode in stream"
			return false
		}
		info := opcode_info[Opcode(op)]
		size := int(info.size)
		#partial switch info.fmt {
		case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
			if pos + 5 > len(code) {r.err = true; r.err_msg = "atom operand overruns code"; return false}
			stream_idx := get_u32_le(code[pos + 1:])
			a := map_stream_atom(r, stream_idx)
			put_u32_le(code[pos + 1:], u32(a))
		}
		if size == 0 {
			r.err = true
			r.err_msg = "opcode with zero size in stream"
			return false
		}
		pos += size
	}
	return true
}

// Map a raw bytecode-stream atom operand (no shift) through bc_idx_to_atom.
@(private = "file")
map_stream_atom :: proc(r: ^Reader, idx: u32) -> Atom {
	return idx_to_atom(r, idx)
}

@(private = "file")
get_u32_le :: proc(b: []u8) -> u32 {
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24)
}

@(private = "file")
put_u32_le :: proc(b: []u8, v: u32) {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}

// --- module, array, plain object ---

@(private = "file")
read_module :: proc(r: ^Reader) -> Value {
	// Modules carry their own structure; for now we read the minimal shape needed to reach the
	// function object and surface a clear error for the parts not yet implemented. The full module
	// linker is a later wave; see docs/engine/runtime.md.
	r.err = true
	r.err_msg = "module bytecode not yet supported"
	return EXCEPTION
}

@(private = "file")
read_array :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	n := rd_leb128(r)
	if r.err {return EXCEPTION}
	arr := array_new(rt, n)
	if arr == nil {return EXCEPTION}
	ad := &arr.exotic.(Array_Data)
	for i in 0 ..< n {
		v := read_value(r)
		if r.err {object_unref(rt, arr); return EXCEPTION}
		ad.dense[i] = v
	}
	return mk_heap(.object, arr)
}

@(private = "file")
read_plain_object :: proc(r: ^Reader) -> Value {
	rt := r.ctx.rt
	ctx := r.ctx
	n := rd_leb128(r)
	if r.err {return EXCEPTION}
	obj := object_new(rt, ctx.realm.object_proto)
	if obj == nil {return EXCEPTION}
	for _ in 0 ..< n {
		key := rd_atom(r)
		val := read_value(r)
		if r.err {object_unref(rt, obj); return EXCEPTION}
		object_define_own(ctx, obj, key, val, {.writable, .enumerable, .configurable})
	}
	return mk_heap(.object, obj)
}

// Build a bigint cell from a little-endian two's-complement byte string.
@(private = "file")
bigint_from_twos_complement :: proc(rt: ^Runtime, bytes: []u8) -> ^JS_BigInt {
	// Sign is the top bit of the most significant byte.
	neg := len(bytes) > 0 && (bytes[len(bytes) - 1] & 0x80) != 0
	// Build the magnitude: if negative, take the two's complement first.
	mag := make([]u8, len(bytes), rt.allocator)
	defer delete(mag, rt.allocator)
	if neg {
		carry := u16(1)
		for i in 0 ..< len(bytes) {
			v := u16(~bytes[i]) + carry
			mag[i] = u8(v)
			carry = v >> 8
		}
	} else {
		copy(mag, bytes)
	}
	context.allocator = rt.allocator
	// Accumulate the magnitude from most-significant 32-bit chunk down, shifting left 32 bits each
	// step: value = (((chunk_hi) << 32) | next) ... The bigint package's public add/shl/from_u64 are
	// used so we do not reach into its private limb layout.
	acc := bigint.from_u64(0)
	chunks := (len(mag) + 3) / 4
	for ci := chunks - 1; ci >= 0; ci -= 1 {
		word: u32 = 0
		base := ci * 4
		for k in 0 ..< 4 {
			if base + k < len(mag) {
				word |= u32(mag[base + k]) << uint(k * 8)
			}
		}
		shifted := bigint.shl(acc, 32)
		bigint.destroy(&acc)
		part := bigint.from_u64(u64(word))
		acc = bigint.add(shifted, part)
		bigint.destroy(&shifted)
		bigint.destroy(&part)
	}
	if neg {
		negated := bigint.neg(acc)
		bigint.destroy(&acc)
		acc = negated
	}
	return bigint_create(rt, acc)
}
