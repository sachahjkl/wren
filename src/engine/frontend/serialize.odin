package frontend

import "base:runtime"

// Serialization to the QuickJS-ng 0.17 JS_WriteObject byte stream (BC_VERSION 28), as produced by
// JS_WriteObject(ctx, obj, JS_WRITE_OBJ_BYTECODE | JS_WRITE_OBJ_STRIP_SOURCE): a script's top-level function, or
// a module record wrapping it. This is the contract with E2 (which reads it back) and what the differential judge
// compares byte for byte.
//
// Container layout (JS_WriteObject2 + JS_WriteObjectAtoms):
//   [BC_VERSION u8] [checksum u32] [atom_count leb128] [atoms...] [object...]
// The checksum (bc_csum) covers everything after the first 5 bytes. Atoms are numbered in first-use order while
// the object is written (bc_atom_to_idx); predefined atoms (< JS_ATOM_END) and tagged integers are written inline.

Writer :: struct {
	allocator:   runtime.Allocator,
	buf:         [dynamic]u8,
	atoms:       ^Atom_Table,
	atom_to_idx: map[Atom]u32,
	idx_to_atom: [dynamic]Atom,
	first_atom:  Atom,
	allow_debug: bool,
}

writer_init :: proc(w: ^Writer, atoms: ^Atom_Table, allocator: runtime.Allocator) {
	w.allocator = allocator
	w.buf = make([dynamic]u8, 0, 1024, allocator)
	w.atoms = atoms
	w.atom_to_idx = make(map[Atom]u32, 64, allocator)
	w.idx_to_atom = make([dynamic]Atom, allocator)
	w.first_atom = JS_ATOM_END
	w.allow_debug = true
}

@(private = "file")
put_u8 :: proc(w: ^Writer, v: u8) {append(&w.buf, v)}

@(private = "file")
put_u16w :: proc(w: ^Writer, v: u16) {append(&w.buf, u8(v), u8(v >> 8))}

@(private = "file")
put_u32w :: proc(w: ^Writer, v: u32) {append(&w.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}

@(private = "file")
put_u64 :: proc(w: ^Writer, v: u64) {
	for i in 0 ..< 8 {append(&w.buf, u8(v >> uint(8 * i)))}
}

@(private = "file")
put_leb128 :: proc(w: ^Writer, v0: u32) {
	v := v0
	for {
		a := v & 0x7f
		v >>= 7
		if v != 0 {
			append(&w.buf, u8(a | 0x80))
		} else {
			append(&w.buf, u8(a))
			break
		}
	}
}

@(private = "file")
put_sleb128 :: proc(w: ^Writer, v1: i32) {
	v := u32(v1)
	put_leb128(w, (2 * v) ~ (0 - (v >> 31)))
}

@(private = "file")
atom_to_idx :: proc(w: ^Writer, atom: Atom) -> u32 {
	if atom < w.first_atom || atom_is_tagged_int(atom) {
		return u32(atom)
	}
	if v, ok := w.atom_to_idx[atom]; ok {
		return v
	}
	v := u32(len(w.idx_to_atom)) + u32(w.first_atom)
	append(&w.idx_to_atom, atom)
	w.atom_to_idx[atom] = v
	return v
}

@(private = "file")
put_atom :: proc(w: ^Writer, atom: Atom) {
	if atom_is_tagged_int(atom) {
		put_leb128(w, (atom_to_uint32(atom) << 1) | 1)
		return
	}
	put_leb128(w, atom_to_idx(w, atom) << 1)
}

@(private = "file")
write_string :: proc(w: ^Writer, sv: String_Value) {
	if sv.is_wide {
		put_leb128(w, (u32(len(sv.units)) << 1) | 1)
		for u in sv.units {put_u16w(w, u)}
	} else {
		put_leb128(w, u32(len(sv.latin1)) << 1)
		append(&w.buf, ..sv.latin1)
	}
}

BC_TAG_NULL :: 1
BC_TAG_UNDEFINED :: 2
BC_TAG_BOOL_FALSE :: 3
BC_TAG_BOOL_TRUE :: 4
BC_TAG_INT32 :: 5
BC_TAG_FLOAT64 :: 6
BC_TAG_STRING :: 7
BC_TAG_OBJECT :: 8
BC_TAG_ARRAY :: 9
BC_TAG_BIG_INT :: 10
BC_TAG_TEMPLATE_OBJECT :: 11
BC_TAG_FUNCTION_BYTECODE :: 12
BC_TAG_MODULE :: 13

BC_VERSION :: 28

JS_ATOM_TYPE_STRING :: 1

@(private = "file")
set_flag :: #force_inline proc(flags: ^u32, idx: ^uint, val: bool, n: uint) {
	if val {flags^ |= 1 << idx^}
	idx^ += n
}

@(private = "file")
set_flags :: #force_inline proc(flags: ^u32, idx: ^uint, val: u32, n: uint) {
	flags^ |= val << idx^
	idx^ += n
}

write_function :: proc(w: ^Writer, b: ^Function_Bytecode) {
	put_u8(w, BC_TAG_FUNCTION_BYTECODE)
	flags: u32 = 0
	idx: uint = 0
	set_flag(&flags, &idx, b.has_prototype, 1)
	set_flag(&flags, &idx, b.has_simple_parameter_list, 1)
	set_flag(&flags, &idx, b.is_derived_class_constructor, 1)
	set_flag(&flags, &idx, b.need_home_object, 1)
	set_flags(&flags, &idx, u32(b.func_kind), 2)
	set_flag(&flags, &idx, b.new_target_allowed, 1)
	set_flag(&flags, &idx, b.super_call_allowed, 1)
	set_flag(&flags, &idx, b.super_allowed, 1)
	set_flag(&flags, &idx, b.arguments_allowed, 1)
	set_flag(&flags, &idx, b.backtrace_barrier, 1)
	set_flag(&flags, &idx, w.allow_debug, 1)
	put_u16w(w, u16(flags))
	put_u8(w, b.is_strict_mode ? 1 : 0)
	put_atom(w, b.func_name)

	put_leb128(w, u32(b.arg_count))
	put_leb128(w, u32(b.var_count))
	put_leb128(w, u32(b.defined_arg_count))
	put_leb128(w, u32(b.stack_size))
	put_leb128(w, u32(b.var_ref_count))
	put_leb128(w, u32(len(b.closure_var)))
	put_leb128(w, u32(len(b.cpool)))
	put_leb128(w, u32(len(b.byte_code)))
	if b.vardefs != nil {
		put_leb128(w, u32(b.arg_count + b.var_count))
		for i in 0 ..< b.arg_count + b.var_count {
			vd := &b.vardefs[i]
			put_atom(w, vd.var_name)
			put_leb128(w, u32(vd.scope_level))
			put_leb128(w, u32(vd.scope_next + 1))
			vf: u32 = 0
			vi: uint = 0
			set_flags(&vf, &vi, u32(vd.var_kind), 4)
			set_flag(&vf, &vi, vd.is_const, 1)
			set_flag(&vf, &vi, vd.is_lexical, 1)
			set_flag(&vf, &vi, vd.is_captured, 1)
			put_u8(w, u8(vf))
			if vd.is_captured {
				put_leb128(w, u32(vd.var_ref_idx))
			}
		}
	} else {
		put_leb128(w, 0)
	}
	for &cv in b.closure_var {
		put_atom(w, cv.var_name)
		put_leb128(w, u32(cv.var_idx))
		cf: u32 = 0
		ci: uint = 0
		set_flags(&cf, &ci, u32(cv.closure_type), 3)
		set_flag(&cf, &ci, cv.is_const, 1)
		set_flag(&cf, &ci, cv.is_lexical, 1)
		set_flags(&cf, &ci, u32(cv.var_kind), 4)
		put_leb128(w, cf)
	}
	for c in b.cpool {
		write_value(w, c)
	}
	write_bytecode(w, b.byte_code)
	if w.allow_debug {
		put_atom(w, b.filename)
		put_leb128(w, u32(b.line_num))
		put_leb128(w, u32(b.col_num))
		put_leb128(w, u32(len(b.pc2line)))
		append(&w.buf, ..b.pc2line)
		put_leb128(w, 0) // source stripped
	}
}

// write_bytecode copies the code, rewriting each atom operand to its serialized index (JS_WriteFunctionBytecode).
@(private = "file")
write_bytecode :: proc(w: ^Writer, code: []u8) {
	pos := 0
	for pos < len(code) {
		op := Opcode(code[pos])
		info := op_info[op]
		size := int(info.size)
		#partial switch info.fmt {
		case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
			a := get_u32(code, pos + 1)
			v := atom_to_idx(w, Atom(a))
			append(&w.buf, code[pos])
			append(&w.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
			append(&w.buf, ..code[pos + 5:pos + size])
		case:
			append(&w.buf, ..code[pos:pos + size])
		}
		pos += size
	}
}

@(private = "file")
write_value :: proc(w: ^Writer, c: JS_Value) {
	switch v in c {
	case nil:
		put_u8(w, BC_TAG_UNDEFINED)
	case JS_Null:
		put_u8(w, BC_TAG_NULL)
	case i32:
		put_u8(w, BC_TAG_INT32)
		put_sleb128(w, v)
	case f64:
		put_u8(w, BC_TAG_FLOAT64)
		put_u64(w, transmute(u64)v)
	case String_Value:
		put_u8(w, BC_TAG_STRING)
		write_string(w, v)
	case Big_Int:
		put_u8(w, BC_TAG_BIG_INT)
		write_bigint(w, v)
	case ^Function_Bytecode:
		write_function(w, v)
	case ^Func_Def:
		put_u8(w, BC_TAG_NULL)
	case ^Template_Object:
		// a sealed array is written as a template object: its elements, then its `raw` property; the raw array
		// is itself sealed, so it is written the same way and its own `raw` is undefined.
		put_u8(w, BC_TAG_TEMPLATE_OBJECT)
		put_leb128(w, u32(len(v.cooked)))
		for e in v.cooked {
			if s, ok := e.?; ok {
				put_u8(w, BC_TAG_STRING)
				write_string(w, s)
			} else {
				put_u8(w, BC_TAG_UNDEFINED)
			}
		}
		put_u8(w, BC_TAG_TEMPLATE_OBJECT)
		put_leb128(w, u32(len(v.raw)))
		for s in v.raw {
			put_u8(w, BC_TAG_STRING)
			write_string(w, s)
		}
		put_u8(w, BC_TAG_UNDEFINED)
	}
}

// write_bigint: JS_WriteBigInt, the two's-complement limbs trimmed to the shortest byte length.
@(private = "file")
write_bigint :: proc(w: ^Writer, v: Big_Int) {
	limbs := v.limbs
	n := len(limbs)
	l: int
	if n == 1 && limbs[0] == 0 {
		l = 0
	} else {
		l = n * 4
		top := limbs[n - 1]
		shift := 32 - 8
		for shift > 0 {
			bb := (top >> uint(shift)) & 0xff
			if bb != 0x00 && bb != 0xff {break}
			if (bb & 1) != ((top >> uint(shift - 1)) & 1) {break}
			shift -= 8
			l -= 1
		}
	}
	put_leb128(w, u32(l))
	if l > 0 {
		for i in 0 ..< l / 4 {put_u32w(w, limbs[i])}
		for i in 0 ..< l % 4 {
			put_u8(w, u8(limbs[n - 1] >> uint(i * 8)))
		}
	}
}

write_module :: proc(w: ^Writer, m: ^Module_Def) {
	put_u8(w, BC_TAG_MODULE)
	put_atom(w, m.module_name)
	put_leb128(w, u32(len(m.req_module_entries)))
	for rme in m.req_module_entries {
		put_atom(w, rme.module_name)
	}
	put_leb128(w, u32(len(m.export_entries)))
	for me in m.export_entries {
		put_u8(w, u8(me.export_type))
		if me.export_type == .local {
			put_leb128(w, u32(me.var_idx))
		} else {
			put_leb128(w, u32(me.req_module_idx))
			put_atom(w, me.local_name)
		}
		put_atom(w, me.export_name)
	}
	put_leb128(w, u32(len(m.star_export_entries)))
	for idx in m.star_export_entries {
		put_leb128(w, u32(idx))
	}
	put_leb128(w, u32(len(m.import_entries)))
	for mi in m.import_entries {
		put_leb128(w, u32(mi.var_idx))
		put_atom(w, mi.import_name)
		put_leb128(w, u32(mi.req_module_idx))
	}
	put_u8(w, m.has_tla ? 1 : 0)
	write_function(w, m.func_obj)
}

// finish_object prepends the version, checksum and atom table to the object section (JS_WriteObjectAtoms).
@(private = "file")
finish_object :: proc(w: ^Writer) -> []u8 {
	head := make([dynamic]u8, 0, 64 + len(w.buf), w.allocator)
	append(&head, BC_VERSION, 0, 0, 0, 0)
	leb :: proc(b: ^[dynamic]u8, v0: u32) {
		v := v0
		for {
			a := v & 0x7f
			v >>= 7
			if v != 0 {
				append(b, u8(a | 0x80))
			} else {
				append(b, u8(a))
				break
			}
		}
	}
	leb(&head, u32(len(w.idx_to_atom)))
	for atom in w.idx_to_atom {
		if atom_is_const(atom) {
			a := u32(atom)
			if a < 64 {
				append(&head, u8(0x80 | a))
			} else {
				append(&head, u8(0xC0 | (a & 0x3F)))
				leb(&head, a >> 6)
			}
		} else {
			append(&head, u8(JS_ATOM_TYPE_STRING))
			s := w.atoms.runtime[int(atom) - int(JS_ATOM_END)]
			if s.is_wide {
				leb(&head, (u32(len(s.units)) << 1) | 1)
				for u in s.units {append(&head, u8(u), u8(u >> 8))}
			} else {
				leb(&head, u32(len(s.latin1)) << 1)
				append(&head, ..s.latin1)
			}
		}
	}
	append(&head, ..w.buf[:])
	h := bc_csum(head[5:])
	head[1] = u8(h)
	head[2] = u8(h >> 8)
	head[3] = u8(h >> 16)
	head[4] = u8(h >> 24)
	return head[:]
}

write_object :: proc(w: ^Writer, top: ^Function_Bytecode, module: ^Module_Def) -> []u8 {
	if module != nil {
		write_module(w, module)
	} else {
		write_function(w, top)
	}
	return finish_object(w)
}

@(private = "file")
bc_csum :: proc(p: []u8) -> u32 {
	n := len(p)
	h: u32 = 0
	i := 0
	for i + 4 < n {
		h += u32(p[i]) | u32(p[i + 1]) << 8 | u32(p[i + 2]) << 16 | u32(p[i + 3]) << 24
		h *= 0x9e370001
		i += 4
	}
	a, b, c: u32 = 0, 0, 0
	switch n - i {
	case 3:
		c = u32(p[i + 2]); fallthrough
	case 2:
		b = u32(p[i + 1]); fallthrough
	case 1:
		a = u32(p[i + 0]); fallthrough
	case 0:
	}
	h += a | b << 8 | c << 16
	h *= 0x9e370001
	return h
}
