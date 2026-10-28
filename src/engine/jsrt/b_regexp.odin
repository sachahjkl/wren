package jsrt

// RegExp (ECMA-262 §22.2): the constructor, exec and the Symbol.match / matchAll / replace / search /
// split protocol, the flags accessors, and the RegExp String Iterator. A RegExp holds libregexp
// bytecode (QuickJS-ng 0.17's format): literals arrive compiled by the front-end, the constructor
// compiles with the same front-end function (fe.lre_compile), and lre_exec.odin runs it.

import "core:mem"
import fe "wb:engine/frontend"

RegExp_Data :: struct {
	bytecode:   []u8, // libregexp bytecode, owned
	source:     ^JS_String,
	flags_text: ^JS_String,
}

regexp_data_free :: proc(rt: ^Runtime, d: ^RegExp_Data) {
	if d.bytecode != nil {delete(d.bytecode, rt_allocator(rt))}
	free(d, rt_allocator(rt))
}

@(private = "file")
regexp_obj_data :: proc(v: Value) -> ^RegExp_Data {
	if v.tag != .object {return nil}
	o := as_obj(v)
	if o.class != .regexp {return nil}
	d, ok := o.data.(^RegExp_Data)
	if !ok {return nil}
	return d
}

// RegExpAlloc: an object with the RegExp prototype from newTarget and an own lastIndex.
@(private = "file")
regexp_alloc :: proc(ctx: ^Context, nt: Value) -> ^Object {
	proto, ok := proto_from_ctor(ctx, nt, .regexp)
	if !ok {return nil}
	o := object_new_proto(ctx, proto, .regexp)
	s := add_property(ctx.rt, o, pa(.A_lastIndex), {.writable})
	s.value = mk_int(0)
	return o
}

// Pattern text for lre_compile (JS_ToCStringLen2): UTF-8 with surrogate pairs joined in unicode mode,
// CESU-8 (each UTF-16 unit on its own) otherwise; a lone surrogate is a 3-byte sequence either way.
@(private = "file")
regexp_pattern_bytes :: proc(rt: ^Runtime, s: ^JS_String, cesu8: bool) -> []u8 {
	f := str_flat(rt, s)
	n := int(f.len)
	out := make([dynamic]u8, 0, n + 8, tmp(rt))
	for i := 0; i < n; {
		cp: u32
		if cesu8 {
			cp = u32(str_at(f, i))
			i += 1
		} else {
			c, w := str_code_point_at(f, i)
			cp = u32(c)
			i += w
		}
		switch {
		case cp < 0x80:
			append(&out, u8(cp))
		case cp < 0x800:
			append(&out, u8(0xc0 | cp >> 6), u8(0x80 | cp & 0x3f))
		case cp < 0x10000:
			append(&out, u8(0xe0 | cp >> 12), u8(0x80 | (cp >> 6) & 0x3f), u8(0x80 | cp & 0x3f))
		case:
			append(&out, u8(0xf0 | cp >> 18), u8(0x80 | (cp >> 12) & 0x3f), u8(0x80 | (cp >> 6) & 0x3f), u8(0x80 | cp & 0x3f))
		}
	}
	return out[:]
}

// The flags string of a set of LRE_FLAG_* bits, in the canonical "dgimsuvy" order.
@(private = "file")
regexp_flags_text :: proc(rt: ^Runtime, bits: int) -> ^JS_String {
	LRE := [8]struct {
		bit: int,
		ch:  u16,
	}{{fe.LRE_FLAG_INDICES, 'd'}, {fe.LRE_FLAG_GLOBAL, 'g'}, {fe.LRE_FLAG_IGNORECASE, 'i'}, {fe.LRE_FLAG_MULTILINE, 'm'}, {fe.LRE_FLAG_DOTALL, 's'}, {fe.LRE_FLAG_UNICODE, 'u'}, {fe.LRE_FLAG_UNICODE_SETS, 'v'}, {fe.LRE_FLAG_STICKY, 'y'}}
	sb := sb_init(rt, 8)
	for e in LRE {if bits & e.bit != 0 {sb_unit(&sb, e.ch)}}
	return sb_finish(&sb)
}

@(private = "file")
regexp_set_data :: proc(ctx: ^Context, o: ^Object, bc: []u8, source, flags_text: ^JS_String) -> Value {
	rt := ctx.rt
	d, has := o.data.(^RegExp_Data)
	if has && d != nil {
		if d.bytecode != nil {delete(d.bytecode, rt_allocator(rt))}
	} else {
		d = new(RegExp_Data, rt_allocator(rt))
		o.data = d
	}
	d.bytecode = make([]u8, len(bc), rt_allocator(rt))
	copy(d.bytecode, bc)
	d.source = source
	d.flags_text = flags_text
	if set(ctx, mk_obj(o), pa(.A_lastIndex), mk_int(0), true) < 0 {return EXCEPTION}
	return mk_obj(o)
}

// RegExpInitialize(obj, pattern, flags), compiled as js_compile_regexp does.
@(private = "file")
regexp_initialize :: proc(ctx: ^Context, o: ^Object, pattern: Value, flags: Value) -> Value {
	rt := ctx.rt
	p := rt.empty_string
	if !is_undefined(pattern) {
		p = to_str(ctx, pattern)
		if p == nil {return EXCEPTION}
	}
	f := rt.empty_string
	if !is_undefined(flags) {
		f = to_str(ctx, flags)
		if f == nil {return EXCEPTION}
	}
	re_flags := 0
	ff := str_flat(rt, f)
	for i in 0 ..< int(ff.len) {
		mask := 0
		switch str_at(ff, i) {
		case 'd': mask = fe.LRE_FLAG_INDICES
		case 'g': mask = fe.LRE_FLAG_GLOBAL
		case 'i': mask = fe.LRE_FLAG_IGNORECASE
		case 'm': mask = fe.LRE_FLAG_MULTILINE
		case 's': mask = fe.LRE_FLAG_DOTALL
		case 'u': mask = fe.LRE_FLAG_UNICODE
		case 'v': mask = fe.LRE_FLAG_UNICODE_SETS
		case 'y': mask = fe.LRE_FLAG_STICKY
		}
		if mask == 0 || re_flags & mask != 0 {return throw_syntax_error(ctx, "invalid regular expression flags")}
		re_flags |= mask
	}
	if re_flags & fe.LRE_FLAG_UNICODE != 0 && re_flags & fe.LRE_FLAG_UNICODE_SETS != 0 {
		return throw_syntax_error(ctx, "invalid regular expression flags")
	}
	unicode := re_flags & (fe.LRE_FLAG_UNICODE | fe.LRE_FLAG_UNICODE_SETS) != 0
	src := regexp_pattern_bytes(rt, p, !unicode)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, rt.allocator, rt.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	bc, err := fe.lre_compile(src, re_flags, mem.dynamic_arena_allocator(&arena), fe.stack_guard_here(256 * 1024))
	if bc == nil {
		if err == "stack overflow" {return throw_range_error(ctx, "Maximum call stack size exceeded")}
		return throw_syntax_error(ctx, err)
	}
	return regexp_set_data(ctx, o, bc, p, regexp_flags_text(rt, re_flags))
}

// A regexp literal (OP_regexp): the pattern and its libregexp bytecode, compiled by the front-end
// (or read from serialized bytecode, hence the verification).
regexp_create_literal :: proc(ctx: ^Context, pattern, bytecode: Value) -> Value {
	rt := ctx.rt
	if bytecode.tag != .string || pattern.tag != .string {return throw_type_error(ctx, "invalid regexp literal")}
	bs := str_flat(rt, as_str(bytecode))
	if bs.is_wide {return throw_internal_error(ctx, "corrupted bytecode in regexp literal")}
	bc := str_u8(bs)[:bs.len]
	scratch := mem.dynamic_arena_allocator(&rt.regexp_arena)
	ok := lre_verify(bc, scratch)
	mem.dynamic_arena_reset(&rt.regexp_arena)
	if !ok {return throw_internal_error(ctx, "corrupted bytecode in regexp literal")}
	o := object_new_proto(ctx, ctx.class_proto[.regexp], .regexp)
	s := add_property(rt, o, pa(.A_lastIndex), {.writable})
	s.value = mk_int(0)
	return regexp_set_data(ctx, o, bc, as_str(pattern), regexp_flags_text(rt, lre_flags(bc)))
}

// RegExpCreate(P, F).
regexp_create :: proc(ctx: ^Context, pattern, flags: Value) -> Value {
	o := regexp_alloc(ctx, UNDEFINED)
	if o == nil {return EXCEPTION}
	return regexp_initialize(ctx, o, pattern, flags)
}

@(private = "file")
regexp_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	pattern := arg(args, 0)
	flags := arg(args, 1)
	ir := is_regexp(ctx, pattern)
	if ir < 0 {return EXCEPTION}
	newt := nt
	if is_undefined(nt) {
		newt = mk_obj(rt.native_self)
		if ir == 1 && is_undefined(flags) {
			pc := get(ctx, pattern, pa(.A_constructor))
			if is_exception(pc) {return EXCEPTION}
			if same_value(ctx, pc, newt) {return pattern}
		}
	}
	p, f := pattern, flags
	if d := regexp_obj_data(pattern); d != nil {
		p = mk_str(d.source)
		if is_undefined(flags) {f = mk_str(d.flags_text)}
	} else if ir == 1 {
		p = get(ctx, pattern, pa(.A_source))
		if is_exception(p) {return EXCEPTION}
		if is_undefined(flags) {
			f = get(ctx, pattern, pa(.A_flags))
			if is_exception(f) {return EXCEPTION}
		}
	}
	o := regexp_alloc(ctx, newt)
	if o == nil {return EXCEPTION}
	return regexp_initialize(ctx, o, p, f)
}

// RegExpBuiltinExec(R, S): a match result array or null.
regexp_builtin_exec :: proc(ctx: ^Context, rv: Value, s: ^JS_String) -> Value {
	rt := ctx.rt
	d := regexp_obj_data(rv)
	liv := get(ctx, rv, pa(.A_lastIndex))
	if is_exception(liv) {return EXCEPTION}
	last_index, ok := to_length(ctx, liv)
	if !ok {return EXCEPTION}
	bc := d.bytecode
	re_flags := lre_flags(bc)
	global_or_sticky := re_flags & (fe.LRE_FLAG_GLOBAL | fe.LRE_FLAG_STICKY) != 0
	if !global_or_sticky {last_index = 0}
	if last_index > i64(s.len) {
		if set(ctx, rv, pa(.A_lastIndex), mk_int(0), true) < 0 {return EXCEPTION}
		return NULL
	}
	arena := &rt.regexp_arena
	defer mem.dynamic_arena_reset(arena)
	scratch := mem.dynamic_arena_allocator(arena)
	capture := make([]int, max(lre_alloc_count(bc), 2), scratch)
	st := lre_exec(ctx, capture, bc, s, int(last_index), scratch)
	switch st {
	case .match:
	case .no_match:
		if global_or_sticky {
			if set(ctx, rv, pa(.A_lastIndex), mk_int(0), true) < 0 {return EXCEPTION}
		}
		return NULL
	case .timeout:
		return EXCEPTION // poll_interrupt threw
	case .memory:
		return throw_internal_error(ctx, "out of memory in regexp execution")
	case .bytecode_error:
		return throw_internal_error(ctx, "corrupted bytecode in regexp execution")
	}
	if global_or_sticky {
		if set(ctx, rv, pa(.A_lastIndex), mk_int(i32(capture[1])), true) < 0 {return EXCEPTION}
	}
	ncap := lre_capture_count(bc)
	names := lre_group_names(bc)
	has_names := names != nil
	has_indices := re_flags & fe.LRE_FLAG_INDICES != 0
	arr := array_new(ctx, ncap)
	define_value(ctx, arr, pa(.A_index), mk_int(i32(capture[0])), CWE)
	define_value(ctx, arr, pa(.A_input), mk_str(s), CWE)
	groups: ^Object
	if has_names {groups = object_new_proto(ctx, nil)}
	ind: ^Object
	igroups: ^Object
	if has_indices {
		ind = array_new(ctx, ncap)
		if has_names {igroups = object_new_proto(ctx, nil)}
	}
	np := 0
	for i in 0 ..< ncap {
		name := ATOM_NULL
		if has_names && i > 0 {
			e := np
			for e < len(names) && names[e] != 0 {e += 1}
			if e > np {name = atom_from_utf8(rt, string(names[np:e]))}
			np = e + fe.LRE_GROUP_NAME_TRAILER_LEN
		}
		start, end := capture[2 * i], capture[2 * i + 1]
		matched := start >= 0 && end >= 0
		if has_indices {
			v := UNDEFINED
			if matched {v = mk_obj(array_from_values(ctx, {mk_int(i32(start)), mk_int(i32(end))}))}
			if name != ATOM_NULL && (matched || shape_find(igroups.shape, name) < 0) {
				create_data_property(ctx, igroups, name, v, false)
			}
			create_data_index(ctx, ind, i64(i), v)
		}
		v := UNDEFINED
		if matched {v = mk_str(str_sub(rt, s, start, end))}
		if name != ATOM_NULL && (matched || shape_find(groups.shape, name) < 0) {
			create_data_property(ctx, groups, name, v, false)
		}
		create_data_index(ctx, arr, i64(i), v)
	}
	define_value(ctx, arr, pa(.A_groups), groups != nil ? mk_obj(groups) : UNDEFINED, CWE)
	if has_indices {
		define_value(ctx, ind, pa(.A_groups), igroups != nil ? mk_obj(igroups) : UNDEFINED, CWE)
		define_value(ctx, arr, pa(.A_indices), mk_obj(ind), CWE)
	}
	return mk_obj(arr)
}

// RegExpExec(R, S): user `exec` if overridden.
regexp_exec :: proc(ctx: ^Context, r: Value, s: ^JS_String) -> Value {
	ex := get(ctx, r, pa(.A_exec))
	if is_exception(ex) {return EXCEPTION}
	if is_callable(ex) && !(ex.tag == .object && as_obj(ex) == ctx.regexp_exec) {
		res := call(ctx, ex, r, {mk_str(s)})
		if is_exception(res) {return EXCEPTION}
		if res.tag != .object && res.tag != .null {return throw_type_error(ctx, "exec result must be an object or null")}
		return res
	}
	if regexp_obj_data(r) == nil {return throw_type_error(ctx, "not a RegExp")}
	return regexp_builtin_exec(ctx, r, s)
}

@(private = "file")
rp_exec :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if regexp_obj_data(this) == nil {return throw_type_error(ctx, "RegExp.prototype.exec: not a RegExp")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	return regexp_builtin_exec(ctx, this, s)
}

@(private = "file")
rp_test :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	r := regexp_exec(ctx, this, s)
	if is_exception(r) {return EXCEPTION}
	return mk_bool(!is_null(r))
}

@(private = "file")
rp_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	p := get(ctx, this, pa(.A_source))
	if is_exception(p) {return EXCEPTION}
	ps := to_str(ctx, p)
	if ps == nil {return EXCEPTION}
	f := get(ctx, this, pa(.A_flags))
	if is_exception(f) {return EXCEPTION}
	fs := to_str(ctx, f)
	if fs == nil {return EXCEPTION}
	sb := sb_init(ctx.rt)
	sb_unit(&sb, '/')
	sb_str(&sb, ps)
	sb_unit(&sb, '/')
	sb_str(&sb, fs)
	return mk_str(sb_finish(&sb))
}

@(private = "file")
rp_compile :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if regexp_obj_data(this) == nil {return throw_type_error(ctx, "not a RegExp")}
	o := as_obj(this)
	if o.shape.proto != nil && function_realm(ctx, mk_obj(ctx.regexp_ctor)) != ctx {
		return throw_type_error(ctx, "RegExp.prototype.compile: cross-realm")
	}
	p, f := arg(args, 0), arg(args, 1)
	if d := regexp_obj_data(p); d != nil {
		if !is_undefined(f) {return throw_type_error(ctx, "flags must be undefined")}
		p = mk_str(d.source)
		f = mk_str(d.flags_text)
	}
	return regexp_initialize(ctx, o, p, f)
}

// flag getters; magic = the LRE_FLAG_* bit
@(private = "file")
rp_flag :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	d := regexp_obj_data(this)
	if d == nil {
		if as_obj(this) == ctx.class_proto[.regexp] {return UNDEFINED}
		return throw_type_error(ctx, "not a RegExp")
	}
	return mk_bool(lre_flags(d.bytecode) & int(magic) != 0)
}

@(private = "file")
rp_flags :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	order := [8]struct {
		name: string,
		ch:   u16,
	}{{"hasIndices", 'd'}, {"global", 'g'}, {"ignoreCase", 'i'}, {"multiline", 'm'}, {"dotAll", 's'}, {"unicode", 'u'}, {"unicodeSets", 'v'}, {"sticky", 'y'}}
	sb := sb_init(rt)
	for e in order {
		v := get(ctx, this, atom_from_utf8(rt, e.name))
		if is_exception(v) {sb_destroy(&sb); return EXCEPTION}
		if to_boolean(v) {sb_unit(&sb, e.ch)}
	}
	return mk_str(sb_finish(&sb))
}

@(private = "file")
rp_source :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	d := regexp_obj_data(this)
	if d == nil {
		if as_obj(this) == ctx.class_proto[.regexp] {return new_string(ctx, "(?:)")}
		return throw_type_error(ctx, "not a RegExp")
	}
	if d.source.len == 0 {return new_string(ctx, "(?:)")}
	// EscapeRegExpPattern: escape '/' and line terminators outside classes
	f := str_flat(rt, d.source)
	sb := sb_init(rt, int(f.len))
	in_class := false
	for i := 0; i < int(f.len); i += 1 {
		c := str_at(f, i)
		if c == '\\' && i + 1 < int(f.len) {
			sb_unit(&sb, c)
			i += 1
			c2 := str_at(f, i)
			switch c2 {
			case '\n': sb_ascii(&sb, "n")
			case '\r': sb_ascii(&sb, "r")
			case 0x2028: sb_ascii(&sb, "u2028")
			case 0x2029: sb_ascii(&sb, "u2029")
			case: sb_unit(&sb, c2)
			}
			continue
		}
		switch c {
		case '[': in_class = true; sb_unit(&sb, c)
		case ']': in_class = false; sb_unit(&sb, c)
		case '/': if in_class {sb_unit(&sb, c)} else {sb_ascii(&sb, "\\/")}
		case '\n': sb_ascii(&sb, "\\n")
		case '\r': sb_ascii(&sb, "\\r")
		case 0x2028: sb_ascii(&sb, "\\u2028")
		case 0x2029: sb_ascii(&sb, "\\u2029")
		case: sb_unit(&sb, c)
		}
	}
	return mk_str(sb_finish(&sb))
}

advance_string_index :: proc(rt: ^Runtime, s: ^JS_String, idx: i64, unicode: bool) -> i64 {
	if !unicode || idx + 1 >= i64(s.len) {return idx + 1}
	f := str_flat(rt, s)
	_, w := str_code_point_at(f, int(idx))
	return idx + i64(w)
}

@(private = "file")
flags_has :: proc(ctx: ^Context, rv: Value, c: u16) -> (bool, bool) {
	fl := get(ctx, rv, pa(.A_flags))
	if is_exception(fl) {return false, false}
	fs := to_str(ctx, fl)
	if fs == nil {return false, false}
	return str_index_of(ctx.rt, fs, str_from_code_unit(ctx.rt, c), 0) >= 0, true
}

// @@match
@(private = "file")
rp_match :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	global, ok := flags_has(ctx, this, 'g')
	if !ok {return EXCEPTION}
	if !global {return regexp_exec(ctx, this, s)}
	unicode, ok2 := flags_has(ctx, this, 'u')
	if !ok2 {return EXCEPTION}
	if !unicode {
		v, ok3 := flags_has(ctx, this, 'v')
		if !ok3 {return EXCEPTION}
		unicode = v
	}
	if set(ctx, this, pa(.A_lastIndex), mk_int(0), true) < 0 {return EXCEPTION}
	a := array_new(ctx)
	m := temp_mark(rt)
	for {
		temp_reset(rt, m)
		r := regexp_exec(ctx, this, s)
		if is_exception(r) {return EXCEPTION}
		if is_null(r) {
			if a.data.(Array_Data).count == 0 {return NULL}
			return mk_obj(a)
		}
		mv := get_index(ctx, r, 0)
		if is_exception(mv) {return EXCEPTION}
		ms := to_str(ctx, mv)
		if ms == nil {return EXCEPTION}
		array_push_fast(rt, a, mk_str(ms))
		if ms.len == 0 {
			li := get(ctx, this, pa(.A_lastIndex))
			if is_exception(li) {return EXCEPTION}
			l, ok4 := to_length(ctx, li)
			if !ok4 {return EXCEPTION}
			if set(ctx, this, pa(.A_lastIndex), mk_i64(advance_string_index(rt, s, l, unicode)), true) < 0 {return EXCEPTION}
		}
	}
}

// @@search
@(private = "file")
rp_search :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	prev := get(ctx, this, pa(.A_lastIndex))
	if is_exception(prev) {return EXCEPTION}
	if !same_value(ctx, prev, mk_int(0)) {
		if set(ctx, this, pa(.A_lastIndex), mk_int(0), true) < 0 {return EXCEPTION}
	}
	r := regexp_exec(ctx, this, s)
	if is_exception(r) {return EXCEPTION}
	cur := get(ctx, this, pa(.A_lastIndex))
	if is_exception(cur) {return EXCEPTION}
	if !same_value(ctx, cur, prev) {
		if set(ctx, this, pa(.A_lastIndex), prev, true) < 0 {return EXCEPTION}
	}
	if is_null(r) {return mk_int(-1)}
	return get(ctx, r, pa(.A_index))
}

// @@replace
@(private = "file")
rp_replace :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	replace := arg(args, 1)
	functional := is_callable(replace)
	rs: ^JS_String
	if !functional {
		rs = to_str(ctx, replace)
		if rs == nil {return EXCEPTION}
	}
	global, ok := flags_has(ctx, this, 'g')
	if !ok {return EXCEPTION}
	unicode := false
	if global {
		u, ok2 := flags_has(ctx, this, 'u')
		if !ok2 {return EXCEPTION}
		v, ok3 := flags_has(ctx, this, 'v')
		if !ok3 {return EXCEPTION}
		unicode = u || v
		if set(ctx, this, pa(.A_lastIndex), mk_int(0), true) < 0 {return EXCEPTION}
	}
	results := make([dynamic]Value, 0, 4, tmp(rt))
	for {
		r := regexp_exec(ctx, this, s)
		if is_exception(r) {return EXCEPTION}
		if is_null(r) {break}
		append(&results, r)
		if !global {break}
		mv := get_index(ctx, r, 0)
		if is_exception(mv) {return EXCEPTION}
		ms := to_str(ctx, mv)
		if ms == nil {return EXCEPTION}
		if ms.len == 0 {
			li := get(ctx, this, pa(.A_lastIndex))
			if is_exception(li) {return EXCEPTION}
			l, ok4 := to_length(ctx, li)
			if !ok4 {return EXCEPTION}
			if set(ctx, this, pa(.A_lastIndex), mk_i64(advance_string_index(rt, s, l, unicode)), true) < 0 {return EXCEPTION}
		}
	}
	sb := sb_init(rt, int(s.len))
	next_pos := 0
	for r in results {
		nc, ok5 := length_of_array_like(ctx, r)
		if !ok5 {sb_destroy(&sb); return EXCEPTION}
		ncap := max(nc - 1, 0)
		mv := get_index(ctx, r, 0)
		if is_exception(mv) {sb_destroy(&sb); return EXCEPTION}
		matched := to_str(ctx, mv)
		if matched == nil {sb_destroy(&sb); return EXCEPTION}
		pv := get(ctx, r, pa(.A_index))
		if is_exception(pv) {sb_destroy(&sb); return EXCEPTION}
		pd, ok6 := to_integer(ctx, pv)
		if !ok6 {sb_destroy(&sb); return EXCEPTION}
		position := int(clamp(pd, 0, f64(s.len)))
		caps := make([]Value, ncap, tmp(rt))
		for k in 1 ..= ncap {
			cv := get_index(ctx, r, k)
			if is_exception(cv) {sb_destroy(&sb); return EXCEPTION}
			if !is_undefined(cv) {
				cs := to_str(ctx, cv)
				if cs == nil {sb_destroy(&sb); return EXCEPTION}
				cv = mk_str(cs)
			}
			caps[k - 1] = cv
		}
		named := get(ctx, r, pa(.A_groups))
		if is_exception(named) {sb_destroy(&sb); return EXCEPTION}
		repl: ^JS_String
		if functional {
			fargs := make([dynamic]Value, 0, ncap + 4, tmp(rt))
			append(&fargs, mk_str(matched))
			append(&fargs, ..caps)
			append(&fargs, mk_int(i32(position)))
			append(&fargs, mk_str(s))
			if !is_undefined(named) {append(&fargs, named)}
			rv := call(ctx, replace, UNDEFINED, fargs[:])
			if is_exception(rv) {sb_destroy(&sb); return EXCEPTION}
			repl = to_str(ctx, rv)
			if repl == nil {sb_destroy(&sb); return EXCEPTION}
		} else {
			if !is_undefined(named) {
				nv := to_object(ctx, named)
				if is_exception(nv) {sb_destroy(&sb); return EXCEPTION}
				named = nv
			}
			tb := sb_init(rt)
			if !get_substitution(ctx, &tb, matched, s, position, caps, named, rs) {sb_destroy(&tb); sb_destroy(&sb); return EXCEPTION}
			repl = sb_finish(&tb)
		}
		if position >= next_pos {
			sb_str_range(&sb, s, next_pos, position)
			sb_str(&sb, repl)
			next_pos = position + int(matched.len)
		}
	}
	if next_pos < int(s.len) {sb_str_range(&sb, s, next_pos, int(s.len))}
	return sb_finish_value(ctx, &sb)
}

// @@split
@(private = "file")
rp_split :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	c := species_constructor(ctx, this, mk_obj(ctx.regexp_ctor))
	if is_exception(c) {return EXCEPTION}
	fl := get(ctx, this, pa(.A_flags))
	if is_exception(fl) {return EXCEPTION}
	fs := to_str(ctx, fl)
	if fs == nil {return EXCEPTION}
	unicode := str_index_of(rt, fs, rt.char_strings['u'], 0) >= 0 || str_index_of(rt, fs, rt.char_strings['v'], 0) >= 0
	nfs := fs
	if str_index_of(rt, fs, rt.char_strings['y'], 0) < 0 {
		nfs = str_concat(rt, fs, rt.char_strings['y'])
	}
	splitter := construct(ctx, c, {this, mk_str(nfs)}, c)
	if is_exception(splitter) {return EXCEPTION}
	a := array_new(ctx)
	lim := u32(0xffffffff)
	if !is_undefined(arg(args, 1)) {
		l, ok := to_uint32(ctx, args[1])
		if !ok {return EXCEPTION}
		lim = l
	}
	if lim == 0 {return mk_obj(a)}
	size := i64(s.len)
	if size == 0 {
		z := regexp_exec(ctx, splitter, s)
		if is_exception(z) {return EXCEPTION}
		if is_null(z) {array_push_fast(rt, a, mk_str(s))}
		return mk_obj(a)
	}
	p: i64 = 0
	q := p
	for q < size {
		if set(ctx, splitter, pa(.A_lastIndex), mk_i64(q), true) < 0 {return EXCEPTION}
		z := regexp_exec(ctx, splitter, s)
		if is_exception(z) {return EXCEPTION}
		if is_null(z) {
			q = advance_string_index(rt, s, q, unicode)
			continue
		}
		ev := get(ctx, splitter, pa(.A_lastIndex))
		if is_exception(ev) {return EXCEPTION}
		e, ok := to_length(ctx, ev)
		if !ok {return EXCEPTION}
		e = min(e, size)
		if e == p {
			q = advance_string_index(rt, s, q, unicode)
			continue
		}
		array_push_fast(rt, a, mk_str(str_sub(rt, s, int(p), int(q))))
		if a.data.(Array_Data).count == lim {return mk_obj(a)}
		p = e
		nc, ok2 := length_of_array_like(ctx, z)
		if !ok2 {return EXCEPTION}
		for i in 1 ..< nc {
			cv := get_index(ctx, z, i)
			if is_exception(cv) {return EXCEPTION}
			array_push_fast(rt, a, cv)
			if a.data.(Array_Data).count == lim {return mk_obj(a)}
		}
		q = p
	}
	array_push_fast(rt, a, mk_str(str_sub(rt, s, int(p), int(size))))
	return mk_obj(a)
}

// @@matchAll and the RegExp String Iterator
@(private = "file")
rp_match_all :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	c := species_constructor(ctx, this, mk_obj(ctx.regexp_ctor))
	if is_exception(c) {return EXCEPTION}
	fl := get(ctx, this, pa(.A_flags))
	if is_exception(fl) {return EXCEPTION}
	fs := to_str(ctx, fl)
	if fs == nil {return EXCEPTION}
	matcher := construct(ctx, c, {this, mk_str(fs)}, c)
	if is_exception(matcher) {return EXCEPTION}
	li := get(ctx, this, pa(.A_lastIndex))
	if is_exception(li) {return EXCEPTION}
	l, ok := to_length(ctx, li)
	if !ok {return EXCEPTION}
	if set(ctx, matcher, pa(.A_lastIndex), mk_i64(l), true) < 0 {return EXCEPTION}
	global := str_index_of(rt, fs, rt.char_strings['g'], 0) >= 0
	unicode := str_index_of(rt, fs, rt.char_strings['u'], 0) >= 0 || str_index_of(rt, fs, rt.char_strings['v'], 0) >= 0
	it := iter_state_new(ctx, ctx.class_proto[.regexp_string_iterator], .regexp_string_iterator, .regexp_string, matcher)
	st := it.data.(^Iter_State)
	st.c = mk_str(s)
	st.sub = (global ? 1 : 0) | (unicode ? 2 : 0)
	return mk_obj(it)
}

@(private = "file")
regexp_string_iterator_next :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o := this_class(ctx, this, .regexp_string_iterator, "RegExp String Iterator")
	if o == nil {return EXCEPTION}
	st := o.data.(^Iter_State)
	if st.done {return iter_result(ctx, UNDEFINED, true)}
	s := as_str(st.c)
	r := regexp_exec(ctx, st.target, s)
	if is_exception(r) {return EXCEPTION}
	if is_null(r) {
		st.done = true
		return iter_result(ctx, UNDEFINED, true)
	}
	if st.sub & 1 == 0 {
		st.done = true
		return iter_result(ctx, r, false)
	}
	mv := get_index(ctx, r, 0)
	if is_exception(mv) {return EXCEPTION}
	ms := to_str(ctx, mv)
	if ms == nil {return EXCEPTION}
	if ms.len == 0 {
		li := get(ctx, st.target, pa(.A_lastIndex))
		if is_exception(li) {return EXCEPTION}
		l, ok := to_length(ctx, li)
		if !ok {return EXCEPTION}
		if set(ctx, st.target, pa(.A_lastIndex), mk_i64(advance_string_index(rt, s, l, st.sub & 2 != 0)), true) < 0 {return EXCEPTION}
	}
	return iter_result(ctx, r, false)
}

// RegExp.escape
@(private = "file")
regexp_escape :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	v := arg(args, 0)
	if v.tag != .string {return throw_type_error(ctx, "RegExp.escape requires a string")}
	f := str_flat(rt, as_str(v))
	n := int(f.len)
	sb := sb_init(rt, n * 2)
	HEX := "0123456789abcdef"
	syntax := "^$\\.*+?()[]{}|/"
	punct := ",-=<>#&!%:;@~'`\""
	for i := 0; i < n; {
		cp, w := str_code_point_at(f, i)
		if i == 0 && ((cp >= '0' && cp <= '9') || (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z')) {
			sb_ascii(&sb, "\\x")
			sb_unit(&sb, u16(HEX[cp >> 4]))
			sb_unit(&sb, u16(HEX[cp & 15]))
			i += w
			continue
		}
		is_syn := false
		for x in transmute([]u8)syntax {if u32(x) == cp {is_syn = true; break}}
		is_p := false
		for x in transmute([]u8)punct {if u32(x) == cp {is_p = true; break}}
		switch {
		case is_syn:
			sb_unit(&sb, '\\')
			sb_code_point(&sb, cp)
		case cp == '\t': sb_ascii(&sb, "\\t")
		case cp == '\n': sb_ascii(&sb, "\\n")
		case cp == 0x0b: sb_ascii(&sb, "\\v")
		case cp == 0x0c: sb_ascii(&sb, "\\f")
		case cp == '\r': sb_ascii(&sb, "\\r")
		case is_p || is_trim_space(cp) || (cp >= 0xd800 && cp < 0xe000):
			if cp <= 0xff {
				sb_ascii(&sb, "\\x")
				sb_unit(&sb, u16(HEX[cp >> 4]))
				sb_unit(&sb, u16(HEX[cp & 15]))
			} else {
				sb_ascii(&sb, "\\u")
				sb_unit(&sb, u16(HEX[(cp >> 12) & 15]))
				sb_unit(&sb, u16(HEX[(cp >> 8) & 15]))
				sb_unit(&sb, u16(HEX[(cp >> 4) & 15]))
				sb_unit(&sb, u16(HEX[cp & 15]))
			}
		case:
			sb_code_point(&sb, cp)
		}
		i += w
	}
	return sb_finish_value(ctx, &sb)
}

init_regexp_builtins :: proc(ctx: ^Context) {
	rt := ctx.rt
	rp := ctx.class_proto[.regexp]
	rc := def_ctor(ctx, "RegExp", regexp_ctor, 2, rp)
	ctx.regexp_ctor = rc
	install_species(ctx, rc)
	def_method(ctx, rc, "escape", regexp_escape, 1)
	ctx.regexp_exec = def_method(ctx, rp, "exec", rp_exec, 1)
	def_method(ctx, rp, "test", rp_test, 1)
	def_method(ctx, rp, "toString", rp_to_string, 0)
	def_method(ctx, rp, "compile", rp_compile, 2)
	def_getter(ctx, rp, pa(.A_flags), rp_flags)
	def_getter(ctx, rp, pa(.A_source), rp_source)
	flags := [8]struct {
		name: string,
		f:    int,
	}{{"global", fe.LRE_FLAG_GLOBAL}, {"ignoreCase", fe.LRE_FLAG_IGNORECASE}, {"multiline", fe.LRE_FLAG_MULTILINE}, {"dotAll", fe.LRE_FLAG_DOTALL}, {"unicode", fe.LRE_FLAG_UNICODE}, {"unicodeSets", fe.LRE_FLAG_UNICODE_SETS}, {"sticky", fe.LRE_FLAG_STICKY}, {"hasIndices", fe.LRE_FLAG_INDICES}}
	for f in flags {def_getter(ctx, rp, atom_from_utf8(rt, f.name), rp_flag, nil, i32(f.f))}
	def_method_sym(ctx, rp, .match, rp_match, 1)
	def_method_sym(ctx, rp, .match_all, rp_match_all, 1)
	def_method_sym(ctx, rp, .replace, rp_replace, 2)
	def_method_sym(ctx, rp, .search, rp_search, 1)
	def_method_sym(ctx, rp, .split, rp_split, 2)
	rsip := ctx.class_proto[.regexp_string_iterator]
	def_method(ctx, rsip, "next", regexp_string_iterator_next, 0)
	def_tag(ctx, rsip, "RegExp String Iterator")
}
