package jscapi

// Values: constructors, conversions, predicates, strings, atoms, errors, the engine heap.

import "base:runtime"
import "core:mem"
import js "wb:engine/jsrt"

// ---- the engine heap (js_malloc & co.): the host allocator ----

JS_ALLOC_ALIGN :: 8

js_malloc :: proc "c" (c: ^Context, size: uint) -> rawptr {
	context = api_ctx()
	p, _ := mem.alloc(max(int(size), 1), JS_ALLOC_ALIGN, host_allocator)
	return p
}

js_mallocz :: proc "c" (c: ^Context, size: uint) -> rawptr {
	return js_malloc(c, size)
}

js_calloc :: proc "c" (c: ^Context, count: uint, size: uint) -> rawptr {
	return js_malloc(c, count * size)
}

js_free :: proc "c" (c: ^Context, ptr: rawptr) {
	context = api_ctx()
	if ptr != nil {mem.free(ptr, host_allocator)}
}

js_free_rt :: proc "c" (r: ^Runtime, ptr: rawptr) {
	context = api_ctx()
	if ptr != nil {mem.free(ptr, host_allocator)}
}

js_realloc :: proc "c" (c: ^Context, ptr: rawptr, size: uint) -> rawptr {
	context = api_ctx()
	if ptr == nil {return js_malloc(c, size)}
	if size == 0 {
		mem.free(ptr, host_allocator)
		return nil
	}
	p, _ := mem.resize(ptr, 0, int(size), JS_ALLOC_ALIGN, host_allocator)
	return p
}

js_realloc_rt :: proc "c" (r: ^Runtime, ptr: rawptr, size: uint) -> rawptr {
	context = api_ctx()
	if ptr == nil {
		p, _ := mem.alloc(max(int(size), 1), JS_ALLOC_ALIGN, host_allocator)
		return p
	}
	if size == 0 {
		mem.free(ptr, host_allocator)
		return nil
	}
	p, _ := mem.resize(ptr, 0, int(size), JS_ALLOC_ALIGN, host_allocator)
	return p
}

js_malloc_usable_size :: proc "c" (ptr: rawptr) -> uint {return 0}

// ---- reference counting ----

JS_DupValue :: proc "c" (c: ^Context, v: JSValue) -> JSValue {
	context = api_ctx()
	dv := dec(v)
	if js.is_heap(dv) {js.ext_ref(jctx(c).rt, js.as_cell(dv))}
	return v
}

JS_FreeValue :: proc "c" (c: ^Context, v: JSValue) {
	disown(v)
}

JS_FreeValueRT :: proc "c" (r: ^Runtime, v: JSValue) {
	disown(v)
}

JS_DupAtom :: proc "c" (c: ^Context, a: Atom) -> Atom {return a}

// Atoms are never collected by jsrt: freeing one is a no-op.
JS_FreeAtom :: proc "c" (c: ^Context, a: Atom) {}

// ---- strings ----

// UTF-8 of a JS string as a NUL-terminated block of the host heap. cesu8 keeps a surrogate pair as two
// 3-byte sequences; a lone surrogate is U+FFFD either way.
@(private)
to_cstring :: proc(rt: ^js.Runtime, s: ^js.JS_String, cesu8: bool) -> (p: [^]u8, n: int) {
	f := js.str_flat(rt, s)
	units := int(f.len)
	size := 1
	i := 0
	for i < units {
		c := u32(js.str_at(f, i))
		i += 1
		if c < 0x80 {size += 1} else if c < 0x800 {size += 2} else if c >= 0xd800 && c < 0xdc00 && i < units && u32(js.str_at(f, i)) >= 0xdc00 && u32(js.str_at(f, i)) < 0xe000 {
			if cesu8 {size += 6} else {size += 4}
			i += 1
		} else {size += 3}
	}
	raw, _ := mem.alloc(size, JS_ALLOC_ALIGN, host_allocator)
	p = cast([^]u8)raw
	o := 0
	put :: #force_inline proc(p: [^]u8, o: ^int, b: u32) {
		p[o^] = u8(b)
		o^ += 1
	}
	i = 0
	for i < units {
		c := u32(js.str_at(f, i))
		i += 1
		if c >= 0xd800 && c < 0xe000 {
			if c < 0xdc00 && i < units && u32(js.str_at(f, i)) >= 0xdc00 && u32(js.str_at(f, i)) < 0xe000 {
				c2 := u32(js.str_at(f, i))
				i += 1
				if cesu8 {
					for u in ([2]u32{c, c2}) {
						put(p, &o, 0xe0 | (u >> 12))
						put(p, &o, 0x80 | ((u >> 6) & 0x3f))
						put(p, &o, 0x80 | (u & 0x3f))
					}
					continue
				}
				c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00)
			} else {
				c = 0xfffd
			}
		}
		switch {
		case c < 0x80: put(p, &o, c)
		case c < 0x800:
			put(p, &o, 0xc0 | (c >> 6))
			put(p, &o, 0x80 | (c & 0x3f))
		case c < 0x10000:
			put(p, &o, 0xe0 | (c >> 12))
			put(p, &o, 0x80 | ((c >> 6) & 0x3f))
			put(p, &o, 0x80 | (c & 0x3f))
		case:
			put(p, &o, 0xf0 | (c >> 18))
			put(p, &o, 0x80 | ((c >> 12) & 0x3f))
			put(p, &o, 0x80 | ((c >> 6) & 0x3f))
			put(p, &o, 0x80 | (c & 0x3f))
		}
	}
	p[o] = 0
	return p, o
}

JS_ToCStringLen2 :: proc "c" (c: ^Context, plen: ^uint, val: JSValue, cesu8: bool) -> cstring {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	s := js.to_str(ctx, dec(val))
	if s == nil {
		if plen != nil {plen^ = 0}
		return nil
	}
	p, n := to_cstring(ctx.rt, s, cesu8)
	if plen != nil {plen^ = uint(n)}
	return cstring(p)
}

JS_ToCString :: proc "c" (c: ^Context, v: JSValue) -> cstring {
	return JS_ToCStringLen2(c, nil, v, false)
}

JS_FreeCString :: proc "c" (c: ^Context, ptr: cstring) {
	context = api_ctx()
	if ptr != nil {mem.free(rawptr(ptr), host_allocator)}
}

// The UTF-16 view (QuickJS-ng JS_ToCStringLenUTF16): a NUL-terminated block of code units.
JS_ToCStringLenUTF16 :: proc "c" (c: ^Context, plen: ^uint, val: JSValue) -> [^]u16 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	s := js.to_str(ctx, dec(val))
	if s == nil {
		if plen != nil {plen^ = 0}
		return nil
	}
	f := js.str_flat(ctx.rt, s)
	n := int(f.len)
	raw, _ := mem.alloc((n + 1) * 2, JS_ALLOC_ALIGN, host_allocator)
	out := cast([^]u16)raw
	for i in 0 ..< n {out[i] = js.str_at(f, i)}
	out[n] = 0
	if plen != nil {plen^ = uint(n)}
	return out
}

JS_FreeCStringUTF16 :: proc "c" (c: ^Context, ptr: [^]u16) {
	context = api_ctx()
	if ptr != nil {mem.free(rawptr(ptr), host_allocator)}
}

JS_NewStringLen :: proc "c" (c: ^Context, buf: [^]u8, len: uint) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	text := len == 0 ? "" : string(buf[:len])
	return own(ctx.rt, js.mk_str(js.str_from_utf8(ctx.rt, text)))
}

JS_NewString :: proc "c" (c: ^Context, str: cstring) -> JSValue {
	return JS_NewStringLen(c, ([^]u8)(rawptr(str)), uint(len(str)))
}

JS_NewStringUTF16 :: proc "c" (c: ^Context, buf: [^]u16, len: uint) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	sb := js.sb_init(ctx.rt, int(len))
	for i in 0 ..< int(len) {js.sb_unit(&sb, buf[i])}
	return own(ctx.rt, js.mk_str(js.sb_finish(&sb)))
}

// ---- value constructors ----

JS_NewNumber :: proc "c" (c: ^Context, d: f64) -> JSValue {
	return enc(js.mk_number(d))
}

JS_NewFloat64 :: proc "c" (c: ^Context, d: f64) -> JSValue {
	return enc(js.mk_number(d))
}

JS_NewObject :: proc "c" (c: ^Context) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.mk_obj(js.new_plain_object(ctx)))
}

JS_NewObjectProto :: proc "c" (c: ^Context, proto: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	p: ^js.Object
	if tag_of(proto) == TAG_OBJECT {p = js.as_obj(dec(proto))}
	return own(ctx.rt, js.mk_obj(js.object_new_proto(ctx, p)))
}

JS_NewArray :: proc "c" (c: ^Context) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.mk_obj(js.array_new(ctx)))
}

JS_NewError :: proc "c" (c: ^Context) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.make_error(ctx, .plain, ""))
}

JS_NewDate :: proc "c" (c: ^Context, epoch_ms: f64) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	o := js.object_new_proto(ctx, ctx.class_proto[.date], .date)
	// TimeClip: out of range or not a number is an invalid date
	if epoch_ms != epoch_ms || abs(epoch_ms) > 8.64e15 {
		o.data = js.Date_Data{t = transmute(f64)u64(0x7ff8000000000000)}
	} else {
		o.data = js.Date_Data{t = f64(i64(epoch_ms))}
	}
	return own(ctx.rt, js.mk_obj(o))
}

JS_NewSymbol :: proc "c" (c: ^Context, description: cstring, is_global: bool) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	rt := ctx.rt
	text := string(description)
	if is_global {
		key := js.atom_from_utf8(rt, text)
		if s, ok := rt.symbol_registry[key]; ok {return own(rt, js.mk_sym(s))}
		sym := js.symbol_new_raw(rt, js.mk_str(js.str_from_utf8(rt, text)), false)
		rt.symbol_registry[key] = sym
		return own(rt, js.mk_sym(sym))
	}
	sym := js.symbol_new_raw(rt, js.mk_str(js.str_from_utf8(rt, text)), false)
	return own(rt, js.mk_sym(sym))
}

// ---- conversions ----

JS_ToBool :: proc "c" (c: ^Context, v: JSValue) -> i32 {
	context = api_ctx()
	return js.to_boolean(dec(v)) ? 1 : 0
}

JS_ToString :: proc "c" (c: ^Context, v: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	r := js.to_string(ctx, dec(v))
	return own(ctx.rt, r)
}

JS_ToObject :: proc "c" (c: ^Context, v: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.to_object(ctx, dec(v)))
}

JS_ToNumber :: proc "c" (c: ^Context, v: JSValue) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	d, ok := js.to_number(ctx, dec(v))
	if !ok {return EXCEPTION}
	return enc(js.mk_number(d))
}

JS_ToFloat64 :: proc "c" (c: ^Context, pres: ^f64, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	d, ok := js.to_number(ctx, dec(val))
	if !ok {
		pres^ = 0
		return -1
	}
	pres^ = d
	return 0
}

JS_ToInt32 :: proc "c" (c: ^Context, pres: ^i32, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	i, ok := js.to_int32(ctx, dec(val))
	if !ok {
		pres^ = 0
		return -1
	}
	pres^ = i
	return 0
}

// JS_ToInt64: ToNumber, NaN is 0 and the result saturates.
JS_ToInt64 :: proc "c" (c: ^Context, pres: ^i64, val: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	d, ok := js.to_number(ctx, dec(val))
	if !ok {
		pres^ = 0
		return -1
	}
	switch {
	case d != d: pres^ = 0
	case d >= 9.223372036854775807e18: pres^ = max(i64)
	case d <= -9.223372036854775808e18: pres^ = min(i64)
	case: pres^ = i64(d)
	}
	return 0
}

// ---- predicates ----

@(private)
class_of :: #force_inline proc "contextless" (v: JSValue) -> (js.Class_ID, bool) {
	if tag_of(v) != TAG_OBJECT {return {}, false}
	return js.as_obj(dec(v)).class, true
}

JS_IsError :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .error
}

JS_IsDate :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .date
}

JS_IsRegExp :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .regexp
}

JS_IsPromise :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .promise
}

JS_IsProxy :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .proxy
}

JS_IsMap :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .jsmap
}

JS_IsSet :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .set
}

JS_IsArray :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && cl == .array
}

JS_IsArrayBuffer :: proc "c" (v: JSValue) -> bool {
	cl, ok := class_of(v)
	return ok && (cl == .array_buffer || cl == .shared_array_buffer)
}

JS_IsFunction :: proc "c" (c: ^Context, v: JSValue) -> bool {
	return js.is_callable(dec(v))
}

JS_IsConstructor :: proc "c" (c: ^Context, v: JSValue) -> bool {
	return js.is_constructor(dec(v))
}

JS_IsStrictEqual :: proc "c" (c: ^Context, a: JSValue, b: JSValue) -> bool {
	context = api_ctx()
	return js.strict_equals(jctx(c), dec(a), dec(b))
}

JS_IsInstanceOf :: proc "c" (c: ^Context, val: JSValue, obj: JSValue) -> i32 {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return i32(js.op_instanceof(ctx, dec(val), dec(obj)))
}

// An error object that cannot be caught (an interrupt, running out of memory) is the pending exception
// with the runtime's uncatchable flag.
JS_IsUncatchableError :: proc "c" (val: JSValue) -> bool {
	rt := last_rt
	if rt == nil || !rt.uncatchable {return false}
	return tag_of(val) == TAG_OBJECT && rt.exception.tag == .object && rt.exception.u.ptr == dec(val).u.ptr
}

// ---- atoms ----

JS_NewAtom :: proc "c" (c: ^Context, str: cstring) -> Atom {
	context = api_ctx()
	return js.atom_from_utf8(jctx(c).rt, string(str))
}

JS_NewAtomLen :: proc "c" (c: ^Context, str: [^]u8, len: uint) -> Atom {
	context = api_ctx()
	return js.atom_from_utf8(jctx(c).rt, len == 0 ? "" : string(str[:len]))
}

JS_NewAtomUInt32 :: proc "c" (c: ^Context, n: u32) -> Atom {
	context = api_ctx()
	if n < 0x80000000 {return js.atom_from_u32(n)}
	return js.atom_from_string(jctx(c).rt, js.str_from_u64(jctx(c).rt, u64(n)))
}

JS_ValueToAtom :: proc "c" (c: ^Context, v: JSValue) -> Atom {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	a, ok := js.to_property_key(ctx, dec(v))
	return ok ? a : 0
}

JS_AtomToValue :: proc "c" (c: ^Context, a: Atom) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.atom_to_value(ctx.rt, a))
}

JS_AtomToString :: proc "c" (c: ^Context, a: Atom) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	return own(ctx.rt, js.mk_str(js.atom_to_string(ctx.rt, a)))
}

JS_AtomToCStringLen :: proc "c" (c: ^Context, plen: ^uint, a: Atom) -> cstring {
	context = api_ctx()
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	s := js.atom_to_string(ctx.rt, a)
	p, n := to_cstring(ctx.rt, s, false)
	if plen != nil {plen^ = uint(n)}
	return cstring(p)
}

JS_AtomGetArrayIndex :: proc "c" (c: ^Context, pidx: ^u32, a: Atom) -> bool {
	context = api_ctx()
	idx, ok := js.atom_index(jctx(c).rt, a)
	if ok {pidx^ = idx}
	return ok
}

// ---- exceptions ----

JS_Throw :: proc "c" (c: ^Context, obj: JSValue) -> JSValue {
	context = api_ctx()
	disown(obj)
	return enc(js.throw(jctx(c), dec(obj)))
}

JS_GetException :: proc "c" (c: ^Context) -> JSValue {
	context = api_ctx()
	ctx := jctx(c)
	return own(ctx.rt, js.take_exception(ctx))
}

JS_HasException :: proc "c" (c: ^Context) -> bool {
	context = api_ctx()
	return js.has_exception(jctx(c))
}

// printf-style messages: the glue passes plain text or a few %s / %d. The conversions are done here, on the
// Odin values (a cstring, an integer, a double); %.*s takes a length then a pointer.
@(private)
format_message :: proc(f: cstring, args: []any, alloc: runtime.Allocator) -> string {
	out := make([dynamic]u8, 0, 64, alloc)
	fs := string(f)
	ai := 0
	i := 0
	for i < len(fs) {
		ch := fs[i]
		i += 1
		if ch != '%' {
			append(&out, ch)
			continue
		}
		if i >= len(fs) {break}
		prec := -1
		for i < len(fs) && (fs[i] == 'l' || fs[i] == 'z' || fs[i] == 'h' || fs[i] == 'j' || fs[i] == 't') {i += 1}
		if i + 1 < len(fs) && fs[i] == '.' && fs[i + 1] == '*' {
			if ai < len(args) {prec = any_int(args[ai])}
			ai += 1
			i += 2
		}
		for i < len(fs) && (fs[i] == 'l' || fs[i] == 'z' || fs[i] == 'h') {i += 1}
		if i >= len(fs) {break}
		spec := fs[i]
		i += 1
		switch spec {
		case '%': append(&out, '%')
		case 's':
			if ai < len(args) {
				s := any_string(args[ai])
				if prec >= 0 && prec < len(s) {s = s[:prec]}
				append(&out, ..transmute([]u8)s)
			}
			ai += 1
		case 'd', 'i', 'u':
			if ai < len(args) {put_int(&out, any_int64(args[ai]), spec == 'u')}
			ai += 1
		case 'c':
			if ai < len(args) {append(&out, u8(any_int(args[ai])))}
			ai += 1
		case 'x', 'X':
			if ai < len(args) {
				v := u64(any_int64(args[ai]))
				digits := "0123456789abcdef"
				if spec == 'X' {digits = "0123456789ABCDEF"}
				tmp: [16]u8
				n := 0
				for {
					tmp[n] = digits[v & 15]
					n += 1
					v >>= 4
					if v == 0 {break}
				}
				for k := n - 1; k >= 0; k -= 1 {append(&out, tmp[k])}
			}
			ai += 1
		case:
			append(&out, '%', spec)
		}
	}
	return string(out[:])
}

@(private)
put_int :: proc(out: ^[dynamic]u8, v: i64, unsigned: bool) {
	buf: [24]u8
	n := 0
	neg := false
	u: u64
	if unsigned {u = u64(v)} else if v < 0 {
		neg = true
		u = u64(-v)
	} else {u = u64(v)}
	for {
		buf[n] = u8('0' + u % 10)
		n += 1
		u /= 10
		if u == 0 {break}
	}
	if neg {append(out, '-')}
	for k := n - 1; k >= 0; k -= 1 {append(out, buf[k])}
}

@(private)
any_string :: proc(a: any) -> string {
	switch v in a {
	case cstring: return string(v)
	case string: return v
	case [^]u8: return v == nil ? "(null)" : string(cstring(v))
	case ^u8: return v == nil ? "(null)" : string(cstring(v))
	case rawptr: return v == nil ? "(null)" : string(cstring(v))
	}
	return ""
}

@(private)
any_int64 :: proc(a: any) -> i64 {
	switch v in a {
	case i8: return i64(v)
	case i16: return i64(v)
	case i32: return i64(v)
	case i64: return v
	case int: return i64(v)
	case u8: return i64(v)
	case u16: return i64(v)
	case u32: return i64(v)
	case u64: return i64(v)
	case uint: return i64(v)
	case bool: return v ? 1 : 0
	}
	return 0
}

@(private)
any_int :: proc(a: any) -> int {return int(any_int64(a))}

@(private)
throw_formatted :: proc(c: ^Context, kind: js.Error_Kind, f: cstring, args: []any) -> JSValue {
	ctx := jctx(c)
	m := js.host_enter(ctx.rt)
	defer js.host_exit(ctx.rt, m, js.UNDEFINED)
	msg := format_message(f, args, js.tmp(ctx.rt))
	return enc(js.throw_error(ctx, kind, msg))
}

JS_ThrowTypeError :: proc "c" (c: ^Context, fmt: cstring, args: ..any) -> JSValue {
	context = api_ctx()
	return throw_formatted(c, .type, fmt, args)
}

JS_ThrowRangeError :: proc "c" (c: ^Context, fmt: cstring, args: ..any) -> JSValue {
	context = api_ctx()
	return throw_formatted(c, .range, fmt, args)
}

JS_ThrowReferenceError :: proc "c" (c: ^Context, fmt: cstring, args: ..any) -> JSValue {
	context = api_ctx()
	return throw_formatted(c, .reference, fmt, args)
}

JS_ThrowSyntaxError :: proc "c" (c: ^Context, fmt: cstring, args: ..any) -> JSValue {
	context = api_ctx()
	return throw_formatted(c, .syntax, fmt, args)
}

JS_ThrowInternalError :: proc "c" (c: ^Context, fmt: cstring, args: ..any) -> JSValue {
	context = api_ctx()
	return throw_formatted(c, .internal, fmt, args)
}

JS_ThrowOutOfMemory :: proc "c" (c: ^Context) -> JSValue {
	context = api_ctx()
	return throw_formatted(c, .internal, "out of memory", nil)
}
