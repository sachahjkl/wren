// web_idb_native.odin: what IndexedDB does that needs no JavaScript semantics, as host functions of the object the
// model gets (web_idb.odin). First, the values of a page: the encoding of keys (a JavaScript value <-> the bytes of
// src/idb/key.odin, ordered by comparing bytes), the comparison of keys, the evaluation of key paths on a value (store
// and index keys, multi-entry indexes, the injection of a generated key), the validity of a key path, and names as
// WTF-8 (a lone surrogate keeps its own 3-byte form: two names that differ by one are two names).
//
//   utf8(string)                  Uint8Array
//   utf8d(bytes)                  string
//   key(value)                    the encoded key as a Uint8Array, or null when the value is not a key; what a getter or
//                                 an element of an array throws is thrown
//   keyValue(bytes)               the value of an encoded key
//   cmp(a, b)                     -1, 0, 1: the order of two encoded keys
//   validPath(path)               a valid key path (a string, or a non-empty array of strings)
//   pathKey(value, path)          the encoded key a key path gives: undefined when a step has no value, null when what
//                                 it gives is not a key
//   indexKeys(value, path, multi) an array of the encoded keys of an index for a value (multi: one per distinct valid
//                                 element)
//   canInject(value, path), inject(value, path, key)   "check that a key could be injected into a value", and doing it
//
// Then the execution of a transaction's requests (the model decides when, in what order and what an event does; what a
// request is made of and what its reply holds is here: the frames of src/idb/protocol.odin are written and read here,
// the keys and the values come back as JavaScript values). A failure of the browser is thrown as `new Failure(code)`
// (setFailure gives the class):
//   execGet(tx, store, index, range, keyOnly)       the value, the key or undefined
//   execCount(tx, store, index, range)              a number
//   execGetAll(tx, store, index, range, mode, flags, limit)   an array: keys (mode 1), values (2), key, primary key, value... (3)
//   execPut(tx, store, flags, key, value, indexKeys)          the key of the record; indexKeys is [index id, key, ...]
//   execDelete(tx, store, range), execClear(tx, store)
//   execCursor(tx, store, index, range, direction, key, pk, target, targetPk, count, keyOnly)   null at the end, else
//                                                   [key, pk, value]
// where a range is the bytes the model's packRange makes (a flags byte and the bounds).
//
// Ported from native/js/runtime/web_idb_native.c: same behaviour. The key encoding is one tagged walk (Idb_Key_Tag) over a
// growable buffer on the engine's heap; the frames are one writer and one reader.
package odin_glue

import "../odin/wj"

// ---- a growable buffer on the engine's heap (js_realloc), shared by keys and request frames ----

Idb_Buf :: struct {
	ctx: ^wj.Context,
	p:   [^]u8,
	n:   int,
	cap: int,
	oom: bool,
}

idb_buf_need :: proc "contextless" (b: ^Idb_Buf, k: int) -> bool {
	if b.oom { return false }
	if b.n + k <= b.cap { return true }
	c := b.cap != 0 ? b.cap * 2 : 64
	for c < b.n + k { c *= 2 }
	q := ([^]u8)(wj.js_realloc(b.ctx, b.p, uint(c)))
	if q == nil { b.oom = true; return false }
	b.p = q
	b.cap = c
	return true
}

idb_buf_free :: proc "contextless" (b: ^Idb_Buf) {
	if b.p != nil { wj.js_free(b.ctx, b.p) }
	b.p = nil
}

idb_buf_bytes :: #force_inline proc "contextless" (b: ^Idb_Buf) -> []u8 { return b.p != nil ? b.p[:b.n] : nil }

idb_buf_u8 :: proc "contextless" (b: ^Idb_Buf, v: u8) { if idb_buf_need(b, 1) { b.p[b.n] = v; b.n += 1 } }

// An unsigned LEB128 varint.
idb_buf_uv :: proc "contextless" (b: ^Idb_Buf, v: u64) {
	if !idb_buf_need(b, 10) { return }
	v := v
	for v >= 128 { b.p[b.n] = u8(v % 128) | 128; b.n += 1; v /= 128 }
	b.p[b.n] = u8(v)
	b.n += 1
}

idb_buf_raw :: proc "contextless" (b: ^Idb_Buf, bytes: []u8) {
	if len(bytes) > 0 && idb_buf_need(b, len(bytes)) { wj.memcpy(&b.p[b.n], raw_data(bytes), uint(len(bytes))); b.n += len(bytes) }
}

// A length-prefixed byte string.
idb_buf_bytes_lp :: proc "contextless" (b: ^Idb_Buf, bytes: []u8) { idb_buf_uv(b, u64(len(bytes))); idb_buf_raw(b, bytes) }

idb_buf_f64 :: proc "contextless" (b: ^Idb_Buf, v: f64) {
	if idb_buf_need(b, 8) { v := v; wj.memcpy(&b.p[b.n], &v, 8); b.n += 8 }
}

// A reader of a frame (bounds-checked: past the end, `bad`).
Idb_Reader :: struct {
	p:   []u8,
	pos: int,
	bad: bool,
}

idb_rd_u8 :: proc "contextless" (r: ^Idb_Reader) -> u8 {
	if r.pos >= len(r.p) { r.bad = true; return 0 }
	r.pos += 1
	return r.p[r.pos - 1]
}

idb_rd_uv :: proc "contextless" (r: ^Idb_Reader) -> u64 {
	v, m: u64 = 0, 1
	for _ in 0 ..< 10 {
		c := idb_rd_u8(r)
		if r.bad { return 0 }
		v += u64(c & 127) * m
		m *= 128
		if c & 128 == 0 { return v }
	}
	r.bad = true
	return 0
}

idb_rd_bytes :: proc "contextless" (r: ^Idb_Reader) -> []u8 {
	n := idb_rd_uv(r)
	if r.bad || n > u64(len(r.p) - r.pos) { r.bad = true; return nil }
	s := r.p[r.pos:][:n]
	r.pos += int(n)
	return s
}

idb_rd_f64 :: proc "contextless" (r: ^Idb_Reader) -> f64 {
	if r.pos + 8 > len(r.p) { r.bad = true; return 0 }
	v: f64
	wj.memcpy(&v, &r.p[r.pos], 8)
	r.pos += 8
	return v
}

// ---- the encoding of a key (src/idb/key.odin) ----

Idb_Key_Tag :: enum u8 { Number = 0x10, Date = 0x20, String = 0x30, Binary = 0x40, Array = 0x50 }

@(private = "file") MAX_DEPTH :: 64

// What put_key did.
@(private = "file")
Put :: enum { Written, Not_A_Key, Thrown }

// A number (or a time value): its IEEE bits made to order as unsigned bytes.
@(private = "file")
put_number :: proc "contextless" (b: ^Idb_Buf, tag: Idb_Key_Tag, v: f64) {
	if !idb_buf_need(b, 9) { return }
	v := v
	if v == 0 { v = 0 }   // -0 is 0
	u := transmute(u64)v
	neg := u >> 63 != 0
	b.p[b.n] = u8(tag)
	b.n += 1
	for i in 0 ..< 8 {
		x := u8(u >> (56 - 8 * uint(i)))
		b.p[b.n] = neg ? x ~ 0xff : (i == 0 ? x ~ 0x80 : x)
		b.n += 1
	}
}

// A string: its UTF-16 code units + 1 big-endian, 0xfffe / 0xffff escaped, then two zero bytes.
@(private = "file")
put_string :: proc "contextless" (b: ^Idb_Buf, ctx: ^wj.Context, s: wj.JSValue) -> bool {
	n: uint
	u := wj.JS_ToCStringLenUTF16(ctx, &n, s)
	if u == nil { return false }
	if idb_buf_need(b, 2 * int(n) + 3) {
		b.p[b.n] = u8(Idb_Key_Tag.String)
		b.n += 1
		for c in u[:n] {
			if c >= 0xfffe {
				b.p[b.n] = 0xff; b.p[b.n + 1] = 0xff; b.p[b.n + 2] = c == 0xfffe ? 1 : 2
				b.n += 3
			} else {
				v := c + 1
				b.p[b.n] = u8(v >> 8); b.p[b.n + 1] = u8(v & 255)
				b.n += 2
			}
		}
		b.p[b.n] = 0; b.p[b.n + 1] = 0
		b.n += 2
	}
	wj.JS_FreeCStringUTF16(ctx, u)
	return true
}

// Binary: the bytes, a zero followed by 0xff, then a zero.
@(private = "file")
put_binary :: proc "contextless" (b: ^Idb_Buf, bytes: []u8) {
	if !idb_buf_need(b, 2 * len(bytes) + 2) { return }
	b.p[b.n] = u8(Idb_Key_Tag.Binary)
	b.n += 1
	for c in bytes {
		b.p[b.n] = c
		b.n += 1
		if c == 0 { b.p[b.n] = 0xff; b.n += 1 }
	}
	b.p[b.n] = 0
	b.n += 1
}

@(private = "file")
written :: #force_inline proc "contextless" (b: ^Idb_Buf) -> Put { return b.oom ? .Thrown : .Written }

// An own property `atom` of `obj` (without getting it): -1 thrown, 0 absent, 1 present.
@(private = "file")
has_own :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, atom: wj.Atom) -> i32 {
	d: wj.Property_Descriptor
	has := wj.JS_GetOwnProperty(ctx, &d, obj, atom)
	if has > 0 {
		wj.JS_FreeValue(ctx, d.value)
		wj.JS_FreeValue(ctx, d.getter)
		wj.JS_FreeValue(ctx, d.setter)
	}
	return has
}

// The length of an array (a getter may throw): false with an exception pending.
@(private = "file")
array_length :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (u32, bool) {
	lv := wj.JS_GetPropertyStr(ctx, v, "length")
	n: u32
	if wj.is_exception(lv) || wj.JS_ToUint32(ctx, &n, lv) < 0 { wj.JS_FreeValue(ctx, lv); return 0, false }
	wj.JS_FreeValue(ctx, lv)
	return n, true
}

@(private = "file")
put_key :: proc "contextless" (b: ^Idb_Buf, ctx: ^wj.Context, v: wj.JSValue, seen: ^[MAX_DEPTH]rawptr, depth: int) -> Put {
	if wj.is_number(v) {
		d: f64
		if wj.JS_ToFloat64(ctx, &d, v) < 0 { return .Thrown }
		if d != d { return .Not_A_Key }
		put_number(b, .Number, d)
		return written(b)
	}
	if wj.is_string(v) { return put_string(b, ctx, v) ? written(b) : .Thrown }
	if !wj.is_object(v) { return .Not_A_Key }
	if wj.JS_IsArray(v) && !wj.JS_IsProxy(v) {   // (a Proxy of an array is not an Array exotic object: no key)
		self := wj.value_get_ptr(v)
		if depth >= MAX_DEPTH { return .Not_A_Key }
		for i in 0 ..< depth { if seen[i] == self { return .Not_A_Key } }
		seen[depth] = self
		if !idb_buf_need(b, 1) { return .Thrown }
		b.p[b.n] = u8(Idb_Key_Tag.Array)
		b.n += 1
		n, ok := array_length(ctx, v)
		if !ok { return .Thrown }
		for i in 0 ..< n {
			a := wj.JS_NewAtomUInt32(ctx, i)
			has := has_own(ctx, v, a)
			wj.JS_FreeAtom(ctx, a)
			if has < 0 { return .Thrown }
			if has == 0 { return .Not_A_Key }   // a hole
			e := wj.JS_GetPropertyUint32(ctx, v, i)
			if wj.is_exception(e) { return .Thrown }
			r := put_key(b, ctx, e, seen, depth + 1)
			wj.JS_FreeValue(ctx, e)
			if r != .Written { return r }
		}
		if !idb_buf_need(b, 1) { return .Thrown }
		b.p[b.n] = 0
		b.n += 1
		return .Written
	}
	if wj.JS_IsDate(v) {
		t: f64
		if !web_date_time(ctx, v, &t) || t != t { return .Not_A_Key }
		put_number(b, .Date, t)
		return written(b)
	}
	p: [^]u8
	n: uint
	k := wj.wj_key_buffer_bytes(ctx, v, &p, &n)   // (a detached buffer is not a key)
	if k < 0 { return .Thrown }
	if k == 0 { return .Not_A_Key }
	put_binary(b, p != nil ? p[:n] : nil)
	return written(b)
}

@(private = "file")
throw_oom :: proc "contextless" (ctx: ^wj.Context, b: ^Idb_Buf) -> wj.JSValue {
	idb_buf_free(b)
	return wj.JS_ThrowOutOfMemory(ctx)
}

// The encoded key of `v` as a Uint8Array; null when it is not a key.
idb_key_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	seen: [MAX_DEPTH]rawptr
	r := put_key(&b, ctx, v, &seen, 0)
	if b.oom { return throw_oom(ctx, &b) }
	defer idb_buf_free(&b)
	switch r {
	case .Thrown:    return wj.EXCEPTION
	case .Not_A_Key: return wj.NULL
	case .Written:   return idb_u8(ctx, idb_buf_bytes(&b))
	}
	return wj.NULL
}

// ---- the value of an encoded key ----

@(private = "file")
read_number :: proc "contextless" (p: []u8) -> f64 {
	neg := p[0] & 0x80 == 0   // transformed: a set top bit means it was non-negative
	u: u64
	for i in 0 ..< 8 {
		x := neg ? p[i] ~ 0xff : (i == 0 ? p[i] ~ 0x80 : p[i])
		u = (u << 8) | u64(x)
	}
	return transmute(f64)u
}

// The value of the key at *pos in p (undefined when malformed).
idb_read_key :: proc "contextless" (ctx: ^wj.Context, p: []u8, pos: ^int) -> wj.JSValue {
	n := len(p)
	if pos^ >= n { return wj.UNDEFINED }
	tag := p[pos^]
	pos^ += 1
	switch Idb_Key_Tag(tag) {
	case .Number, .Date:
		if pos^ + 8 > n { return wj.UNDEFINED }
		d := read_number(p[pos^:])
		pos^ += 8
		return Idb_Key_Tag(tag) == .Number ? wj.new_float64(ctx, d) : wj.JS_NewDate(ctx, d)
	case .String:
		units := ([^]u16)(wj.js_malloc(ctx, uint(n) * size_of(u16) + 2))
		if units == nil { return wj.EXCEPTION }
		k := 0
		for pos^ + 1 < n {
			a, c := p[pos^], p[pos^ + 1]
			if a == 0 && c == 0 { pos^ += 2; break }
			if a == 0xff && c == 0xff {
				if pos^ + 2 >= n { break }
				units[k] = u16(0xfffe + u32(p[pos^ + 2]) - 1)
				k += 1
				pos^ += 3
			} else {
				units[k] = u16(((u32(a) << 8) | u32(c)) - 1)
				k += 1
				pos^ += 2
			}
		}
		s := wj.JS_NewStringUTF16(ctx, units, uint(k))
		wj.js_free(ctx, units)
		return s
	case .Binary:
		out := ([^]u8)(wj.js_malloc(ctx, uint(max(n, 1))))
		if out == nil { return wj.EXCEPTION }
		k := 0
		for pos^ < n {
			c := p[pos^]
			pos^ += 1
			if c == 0 {
				if pos^ < n && p[pos^] == 0xff { pos^ += 1; out[k] = 0; k += 1; continue }
				break
			}
			out[k] = c
			k += 1
		}
		ab := wj.JS_NewArrayBufferCopy(ctx, out, uint(k))
		wj.js_free(ctx, out)
		return ab
	case .Array:
		arr := wj.JS_NewArray(ctx)
		i: u32
		for pos^ < n && p[pos^] != 0 {
			e := idb_read_key(ctx, p, pos)
			if wj.is_exception(e) { wj.JS_FreeValue(ctx, arr); return e }
			wj.array_set(ctx, arr, i, e)
			i += 1
		}
		pos^ += 1
		return arr
	}
	return wj.UNDEFINED
}

// The bytes of a BufferSource (a key, a reply). False with an exception pending.
idb_bytes_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (bytes: []u8, ok: bool) {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, v, &p, &n, 0, "IndexedDB") { return }
	return p != nil ? p[:n] : nil, true
}

// The order of two encoded keys: -1, 0, 1 (bytes compared, then lengths).
idb_cmp :: proc "contextless" (a, b: []u8) -> i32 {
	n := min(len(a), len(b))
	c := n > 0 ? wj.memcmp(raw_data(a), raw_data(b), uint(n)) : 0
	if c == 0 { return len(a) == len(b) ? 0 : (len(a) < len(b) ? -1 : 1) }
	return c < 0 ? -1 : 1
}

@(private = "file")
host_key :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return idb_key_of(ctx, wj.arg(argc, argv, 0))
}

@(private = "file")
host_key_value :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	bytes, ok := idb_bytes_of(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	pos := 0
	return idb_read_key(ctx, bytes, &pos)
}

@(private = "file")
host_cmp :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	a, ok := idb_bytes_of(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	b, ok2 := idb_bytes_of(ctx, wj.arg(argc, argv, 1))
	if !ok2 { return wj.EXCEPTION }
	return wj.new_int32(idb_cmp(a, b))
}

// ---- names ----

@(private = "file")
host_utf8 :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	bytes, ok := wj.wtf8_of(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	defer delete(bytes, wj.libc_allocator())
	return idb_u8(ctx, bytes)
}

@(private = "file")
host_utf8d :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	bytes, ok := idb_bytes_of(ctx, wj.arg(argc, argv, 0))
	if !ok { return wj.EXCEPTION }
	return wj.string_of_wtf8(ctx, bytes)
}

// ---- key paths ----

// One part of a dotted path: an identifier (the first code point starts one, the others continue it).
@(private = "file")
valid_path_part :: proc "contextless" (u: []u16) -> bool {
	if len(u) == 0 { return false }
	first := true
	for i := 0; i < len(u); i += 1 {
		c := u32(u[i])
		if c >= 0xd800 && c <= 0xdbff && i + 1 < len(u) && u[i + 1] >= 0xdc00 && u[i + 1] <= 0xdfff {
			c = 0x10000 + ((c - 0xd800) << 10) + (u32(u[i + 1]) - 0xdc00)
			i += 1
		}
		start := c == '$' || c == '_' || wj.lre_is_id_start(c)   // (libunicode has neither of those two)
		ok := first ? start : (start || wj.lre_is_id_continue(c) || c == 0x200c || c == 0x200d)
		if !ok { return false }
		first = false
	}
	return true
}

// 1: valid; 0: not; -1: exception. The empty path is valid.
@(private = "file")
valid_path_string :: proc "contextless" (ctx: ^wj.Context, s: wj.JSValue) -> i32 {
	n: uint
	p := wj.JS_ToCStringLenUTF16(ctx, &n, s)
	if p == nil { return -1 }
	defer wj.JS_FreeCStringUTF16(ctx, p)
	u := p[:n]
	start := 0
	for i in 0 ..= len(u) {
		if len(u) == 0 { break }
		if i == len(u) || u[i] == '.' {
			if !valid_path_part(u[start:i]) { return 0 }
			start = i + 1
		}
	}
	return 1
}

@(private = "file")
host_valid_path :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p := wj.arg(argc, argv, 0)
	if wj.is_string(p) {
		r := valid_path_string(ctx, p)
		return r < 0 ? wj.EXCEPTION : wj.new_bool(r != 0)
	}
	if !wj.JS_IsArray(p) || wj.JS_IsProxy(p) { return wj.FALSE }
	n, ok := array_length(ctx, p)
	if !ok { return wj.EXCEPTION }
	if n == 0 { return wj.FALSE }
	for i in 0 ..< n {
		e := wj.JS_GetPropertyUint32(ctx, p, i)
		if wj.is_exception(e) { return e }
		r := wj.is_string(e) ? valid_path_string(ctx, e) : 0
		wj.JS_FreeValue(ctx, e)
		if r < 0 { return wj.EXCEPTION }
		if r == 0 { return wj.FALSE }
	}
	return wj.TRUE
}

// What evaluating a key path on a value gave.
@(private = "file")
Eval :: enum { Value, No_Value, Thrown }

// "Evaluate a key path on a value": .Value with the value in out (counted), .No_Value when a step has none.
@(private = "file")
eval_path :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, path: string, out: ^wj.JSValue) -> Eval {
	cur := wj.JS_DupValue(ctx, v)
	if len(path) > 0 {
		start := 0
		for i in 0 ..= len(path) {
			if i != len(path) && path[i] != '.' { continue }
			id := path[start:i]
			start = i + 1
			next: wj.JSValue
			if wj.is_string(cur) && id == "length" {
				next = wj.JS_GetPropertyStr(ctx, cur, "length")
			} else if !wj.is_object(cur) {
				wj.JS_FreeValue(ctx, cur)
				return .No_Value
			} else if wj.JS_IsArray(cur) && id == "length" {
				next = wj.JS_GetPropertyStr(ctx, cur, "length")
			} else {
				bp: [^]u8
				bl: uint
				is_blob := web_blob_bytes(cur, &bp, &bl)
				special := is_blob && (id == "size" || id == "type" || (wj.wj_unwrap(cur, file_iface()) != nil && (id == "name" || id == "lastModified")))
				a := wj.JS_NewAtomLen(ctx, raw_data(id), uint(len(id)))
				if !special {
					has := has_own(ctx, cur, a)
					if has <= 0 {
						wj.JS_FreeAtom(ctx, a)
						wj.JS_FreeValue(ctx, cur)
						return has < 0 ? .Thrown : .No_Value
					}
				}
				next = wj.JS_GetProperty(ctx, cur, a)
				wj.JS_FreeAtom(ctx, a)
			}
			wj.JS_FreeValue(ctx, cur)
			if wj.is_exception(next) { return .Thrown }
			cur = next
		}
	}
	out^ = cur
	return .Value
}

@(private = "file") iface_file := i32(-2)
@(private = "file")
file_iface :: proc "contextless" () -> i32 {
	if iface_file == -2 { iface_file = wj.iface("File") }
	return iface_file
}

// A key path (a string or an array of strings) as the model gave it, its parts as engine C strings (path_free).
@(private = "file")
Path :: struct {
	parts:    [^]string,   // js_mallocz'ed; each part's bytes are a JS_ToCStringLen result
	count:    u32,
	is_array: bool,
}

@(private = "file")
path_free :: proc "contextless" (ctx: ^wj.Context, p: ^Path) {
	if p.parts == nil { return }
	for i in 0 ..< p.count { wj.free_cstring(ctx, cstring(raw_data(p.parts[i]))) }
	wj.js_free(ctx, p.parts)
	p.parts = nil
}

@(private = "file")
path_get :: proc "contextless" (ctx: ^wj.Context, path: wj.JSValue, p: ^Path) -> bool {
	p^ = {}
	if wj.is_string(path) {
		p.count = 1
	} else {
		p.is_array = true
		n, ok := array_length(ctx, path)
		if !ok { return false }
		p.count = n
	}
	p.parts = ([^]string)(wj.js_mallocz(ctx, uint(max(p.count, 1)) * size_of(string)))
	if p.parts == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	for i in 0 ..< p.count {
		e := p.is_array ? wj.JS_GetPropertyUint32(ctx, path, i) : wj.JS_DupValue(ctx, path)
		if wj.is_exception(e) { p.count = i; path_free(ctx, p); return false }
		n: uint
		s := wj.to_cstring_len(ctx, &n, e)
		wj.JS_FreeValue(ctx, e)
		if s == nil { p.count = i; path_free(ctx, p); return false }
		p.parts[i] = string(([^]u8)(rawptr(s))[:n])
	}
	return true
}

// undefined: a step has no value; null: not a key; else the encoded key
@(private = "file")
path_key :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, p: ^Path) -> wj.JSValue {
	if !p.is_array {
		r: wj.JSValue
		switch eval_path(ctx, v, p.parts[0], &r) {
		case .Thrown:   return wj.EXCEPTION
		case .No_Value: return wj.UNDEFINED
		case .Value:
		}
		k := idb_key_of(ctx, r)
		wj.JS_FreeValue(ctx, r)
		return k
	}
	b := Idb_Buf{ ctx = ctx }
	if !idb_buf_need(&b, 1) { return throw_oom(ctx, &b) }
	b.p[b.n] = u8(Idb_Key_Tag.Array)
	b.n += 1
	for i in 0 ..< p.count {
		r: wj.JSValue
		switch eval_path(ctx, v, p.parts[i], &r) {
		case .Thrown:   idb_buf_free(&b); return wj.EXCEPTION
		case .No_Value: idb_buf_free(&b); return wj.UNDEFINED
		case .Value:
		}
		seen: [MAX_DEPTH]rawptr
		k := put_key(&b, ctx, r, &seen, 0)
		wj.JS_FreeValue(ctx, r)
		if b.oom { return throw_oom(ctx, &b) }
		switch k {
		case .Thrown:    idb_buf_free(&b); return wj.EXCEPTION
		case .Not_A_Key: idb_buf_free(&b); return wj.NULL
		case .Written:
		}
	}
	if !idb_buf_need(&b, 1) { return throw_oom(ctx, &b) }
	b.p[b.n] = 0
	b.n += 1
	out := idb_u8(ctx, idb_buf_bytes(&b))
	idb_buf_free(&b)
	return out
}

@(private = "file")
host_path_key :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p: Path
	if !path_get(ctx, wj.arg(argc, argv, 1), &p) { return wj.EXCEPTION }
	r := path_key(ctx, wj.arg(argc, argv, 0), &p)
	path_free(ctx, &p)
	return r
}

@(private = "file")
same_bytes :: proc "contextless" (ctx: ^wj.Context, a, b: wj.JSValue) -> bool {
	pa, ok := idb_bytes_of(ctx, a)
	pb, ok2 := idb_bytes_of(ctx, b)
	if !ok || !ok2 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return false }
	return len(pa) == len(pb) && (len(pa) == 0 || wj.memcmp(raw_data(pa), raw_data(pb), uint(len(pa))) == 0)
}

// The keys of an index for a value: [] (no value, not a key), [key], or for a multi-entry index with an array result
// one per distinct valid element.
@(private = "file")
host_index_keys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	value := wj.arg(argc, argv, 0)
	multi := wj.JS_ToBool(ctx, wj.arg(argc, argv, 2)) > 0
	p: Path
	if !path_get(ctx, wj.arg(argc, argv, 1), &p) { return wj.EXCEPTION }
	out := wj.JS_NewArray(ctx)
	if p.is_array || !multi {
		key := path_key(ctx, value, &p)
		path_free(ctx, &p)
		if wj.is_exception(key) { wj.JS_FreeValue(ctx, out); return key }
		if wj.is_nullish(key) { return out }
		wj.JS_SetPropertyUint32(ctx, out, 0, key)
		return out
	}
	r: wj.JSValue
	e := eval_path(ctx, value, p.parts[0], &r)
	path_free(ctx, &p)
	switch e {
	case .Thrown:   wj.JS_FreeValue(ctx, out); return wj.EXCEPTION
	case .No_Value: return out
	case .Value:
	}
	defer wj.JS_FreeValue(ctx, r)
	if !wj.JS_IsArray(r) || wj.JS_IsProxy(r) {
		key := idb_key_of(ctx, r)
		if wj.is_exception(key) { wj.JS_FreeValue(ctx, out); return key }
		if !wj.is_null(key) { wj.JS_SetPropertyUint32(ctx, out, 0, key) }
		return out
	}
	n, ok := array_length(ctx, r)
	if !ok { wj.JS_FreeValue(ctx, out); return wj.EXCEPTION }
	k: u32
	for i in 0 ..< n {
		a := wj.JS_NewAtomUInt32(ctx, i)
		has := has_own(ctx, r, a)
		wj.JS_FreeAtom(ctx, a)
		if has < 0 { wj.JS_FreeValue(ctx, out); return wj.EXCEPTION }
		if has == 0 { continue }
		el := wj.JS_GetPropertyUint32(ctx, r, i)
		if wj.is_exception(el) { wj.JS_FreeValue(ctx, out); return el }
		key := idb_key_of(ctx, el)
		wj.JS_FreeValue(ctx, el)
		if wj.is_exception(key) { wj.JS_FreeValue(ctx, out); return key }
		if wj.is_null(key) { continue }
		dup := false
		for j in 0 ..< k {
			other := wj.JS_GetPropertyUint32(ctx, out, j)
			dup = same_bytes(ctx, other, key)
			wj.JS_FreeValue(ctx, other)
			if dup { break }
		}
		if dup { wj.JS_FreeValue(ctx, key) } else { wj.JS_SetPropertyUint32(ctx, out, k, key); k += 1 }
	}
	return out
}

// ---- injecting a generated key ----

@(private = "file") MAX_PARTS :: 64

// The parts of a dotted string path, each as a new atom (atoms_free).
@(private = "file")
path_atoms :: proc "contextless" (ctx: ^wj.Context, s: string, atoms: ^[MAX_PARTS]wj.Atom) -> u32 {
	if len(s) == 0 { return 0 }
	k: u32
	start := 0
	for i in 0 ..= len(s) {
		if k >= MAX_PARTS { break }
		if i == len(s) || s[i] == '.' {
			atoms[k] = wj.JS_NewAtomLen(ctx, raw_data(s[start:]), uint(i - start))
			k += 1
			start = i + 1
		}
	}
	return k
}

@(private = "file")
atoms_free :: proc "contextless" (ctx: ^wj.Context, atoms: []wj.Atom) { for a in atoms { wj.JS_FreeAtom(ctx, a) } }

// The atoms of argument 1 (a string path). False with an exception pending.
@(private = "file")
path_arg_atoms :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, atoms: ^[MAX_PARTS]wj.Atom) -> (u32, bool) {
	n: uint
	s := wj.to_cstring_len(ctx, &n, v)
	if s == nil { return 0, false }
	count := path_atoms(ctx, string(([^]u8)(rawptr(s))[:n]), atoms)
	wj.free_cstring(ctx, s)
	return count, true
}

@(private = "file")
host_can_inject :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	atoms: [MAX_PARTS]wj.Atom
	count, ok := path_arg_atoms(ctx, wj.arg(argc, argv, 1), &atoms)
	if !ok { return wj.EXCEPTION }
	defer atoms_free(ctx, atoms[:count])
	cur := wj.JS_DupValue(ctx, wj.arg(argc, argv, 0))
	defer wj.JS_FreeValue(ctx, cur)
	for i: u32 = 0; i + 1 < count; i += 1 {
		if !wj.is_object(cur) { return wj.FALSE }
		has := has_own(ctx, cur, atoms[i])
		if has < 0 { return wj.EXCEPTION }
		if has == 0 { return wj.TRUE }   // (the rest of the path would be made)
		next := wj.JS_GetProperty(ctx, cur, atoms[i])
		wj.JS_FreeValue(ctx, cur)
		cur = wj.UNDEFINED
		if wj.is_exception(next) { return wj.EXCEPTION }
		cur = next
	}
	return wj.new_bool(wj.is_object(cur))
}

@(private = "file")
host_inject :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	atoms: [MAX_PARTS]wj.Atom
	count, ok := path_arg_atoms(ctx, wj.arg(argc, argv, 1), &atoms)
	if !ok { return wj.EXCEPTION }
	defer atoms_free(ctx, atoms[:count])
	if count == 0 { return wj.EXCEPTION }
	cur := wj.JS_DupValue(ctx, wj.arg(argc, argv, 0))
	defer wj.JS_FreeValue(ctx, cur)
	for i: u32 = 0; i + 1 < count; i += 1 {
		has := has_own(ctx, cur, atoms[i])
		if has < 0 { return wj.EXCEPTION }
		if has == 0 && wj.JS_DefinePropertyValue(ctx, cur, atoms[i], wj.JS_NewObject(ctx), wj.PROP_C_W_E) < 0 { return wj.EXCEPTION }
		next := wj.JS_GetProperty(ctx, cur, atoms[i])
		wj.JS_FreeValue(ctx, cur)
		cur = wj.UNDEFINED
		if wj.is_exception(next) { return wj.EXCEPTION }
		cur = next
	}
	if wj.JS_DefinePropertyValue(ctx, cur, atoms[count - 1], wj.JS_DupValue(ctx, wj.arg(argc, argv, 2)), wj.PROP_C_W_E | wj.PROP_THROW) < 0 {
		return wj.EXCEPTION
	}
	return wj.UNDEFINED
}

// ---- the execution of requests ----

IDB_OP_EXEC :: i32(9)

// The request kinds of an EXEC frame (src/idb/protocol.odin).
Idb_Req :: enum u8 {
	Get = 1, Count = 2, Get_All = 3, Cursor = 4, Put = 5, Gen_Key = 6, Delete = 7, Clear = 8, Index_Put = 9,
	Create_Store = 10, Delete_Store = 11, Rename_Store = 12, Create_Index = 13, Delete_Index = 14, Rename_Index = 15,
	Peek_Key = 16,
}

// The class a failure of the browser is thrown as (setFailure), undefined until the model gives it.
@(private = "file") failure_ctor: wj.JSValue
@(private = "file") failure_set: bool

@(private = "file")
host_set_failure :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if failure_set { wj.JS_FreeValue(ctx, failure_ctor) }
	failure_ctor = wj.JS_DupValue(ctx, wj.arg(argc, argv, 0))
	failure_set = true
	return wj.UNDEFINED
}

// The class the model throws a browser failure as (web_idb_prelude's own Failure), for the Odin model.
idb_set_failure_class :: proc "contextless" (ctx: ^wj.Context, c: wj.JSValue) {
	if failure_set { wj.JS_FreeValue(ctx, failure_ctor) }
	failure_ctor = wj.JS_DupValue(ctx, c)
	failure_set = true
}

@(private = "file")
throw_failure :: proc "contextless" (ctx: ^wj.Context, code: i32) -> wj.JSValue {
	if !failure_set { return wj.JS_ThrowInternalError(ctx, "IndexedDB: the browser failed (%d)", code) }
	c := wj.new_int32(code)
	e := wj.JS_CallConstructor(ctx, failure_ctor, 1, &c)
	return wj.is_exception(e) ? e : wj.JS_Throw(ctx, e)
}

// A number argument as a u64 (negative and NaN: 0). False with an exception pending.
@(private = "file")
arg_u64 :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> (u64, bool) {
	d: f64
	if wj.JS_ToFloat64(ctx, &d, v) < 0 { return 0, false }
	return d > 0 ? u64(d) : 0, true
}

// The start of a request frame: transaction, operation, object store.
@(private = "file")
begin_request :: proc "contextless" (ctx: ^wj.Context, b: ^Idb_Buf, tx: wj.JSValue, op: Idb_Req, store: wj.JSValue) -> bool {
	t := arg_u64(ctx, tx) or_return
	s := arg_u64(ctx, store) or_return
	idb_buf_uv(b, t)
	idb_buf_u8(b, u8(op))
	idb_buf_uv(b, s)
	return true
}

// A BufferSource argument into the frame (null / undefined: nothing, or an empty length-prefixed string).
@(private = "file")
put_arg_bytes :: proc "contextless" (ctx: ^wj.Context, b: ^Idb_Buf, v: wj.JSValue, length_prefixed: bool) -> bool {
	if wj.is_nullish(v) { if length_prefixed { idb_buf_uv(b, 0) }; return true }
	bytes := idb_bytes_of(ctx, v) or_return
	if length_prefixed { idb_buf_bytes_lp(b, bytes) } else { idb_buf_raw(b, bytes) }
	return true
}

// Sends the frame; a failure of the browser is thrown. The payload (after the status byte) is a copy to js_free
// (`base`), so that the values built from it cannot be disturbed by another call.
@(private = "file")
send_request :: proc "contextless" (ctx: ^wj.Context, req: ^Idb_Buf, base: ^[^]u8, r: ^Idb_Reader) -> bool {
	if req.oom { wj.JS_ThrowOutOfMemory(ctx); return false }
	rep := idb_call_copy(ctx, IDB_OP_EXEC, idb_buf_bytes(req)) or_return
	if len(rep) == 0 || rep[0] != 0 {
		code := len(rep) > 0 ? i32(rep[0]) : 10
		wj.js_free(ctx, raw_data(rep))
		throw_failure(ctx, code)
		return false
	}
	base^ = raw_data(rep)
	r^ = { p = rep[1:] }
	return true
}

@(private = "file")
malformed :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return wj.JS_ThrowInternalError(ctx, "IndexedDB: a reply of the browser is malformed") }

@(private = "file")
value_of :: proc "contextless" (ctx: ^wj.Context, r: ^Idb_Reader) -> wj.JSValue {
	bytes := idb_rd_bytes(r)
	if r.bad { return malformed(ctx) }
	return web_clone_deserialize(ctx, raw_data(bytes), uint(len(bytes)))
}

@(private = "file")
key_value_of :: proc "contextless" (ctx: ^wj.Context, r: ^Idb_Reader) -> wj.JSValue {
	bytes := idb_rd_bytes(r)
	if r.bad { return malformed(ctx) }
	pos := 0
	return idb_read_key(ctx, bytes, &pos)
}

// A frame with the store's request header and the index and range every query has: argv = tx, store, index, range
@(private = "file")
query_header :: proc "contextless" (ctx: ^wj.Context, b: ^Idb_Buf, argc: i32, argv: [^]wj.JSValue, op: Idb_Req) -> bool {
	begin_request(ctx, b, wj.arg(argc, argv, 0), op, wj.arg(argc, argv, 1)) or_return
	index := arg_u64(ctx, wj.arg(argc, argv, 2)) or_return
	idb_buf_uv(b, index)
	return put_arg_bytes(ctx, b, wj.arg(argc, argv, 3), false)
}

// execGet(tx, store, index, range, keyOnly)
@(private = "file")
host_exec_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	key_only := wj.JS_ToBool(ctx, wj.arg(argc, argv, 4)) > 0
	if !query_header(ctx, &b, argc, argv, .Get) { idb_buf_free(&b); return wj.EXCEPTION }
	idb_buf_u8(&b, key_only ? 1 : 0)
	base: [^]u8
	r: Idb_Reader
	sent := send_request(ctx, &b, &base, &r)
	idb_buf_free(&b)
	if !sent { return wj.EXCEPTION }
	defer wj.js_free(ctx, base)
	out := wj.UNDEFINED
	if idb_rd_u8(&r) != 0 {
		if key_only {
			out = key_value_of(ctx, &r)
		} else {
			idb_rd_bytes(&r)   // the primary key: the value follows
			out = r.bad ? malformed(ctx) : value_of(ctx, &r)
		}
	}
	if r.bad && !wj.is_exception(out) { wj.JS_FreeValue(ctx, out); out = malformed(ctx) }
	return out
}

// execCount(tx, store, index, range)
@(private = "file")
host_exec_count :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	if !query_header(ctx, &b, argc, argv, .Count) { idb_buf_free(&b); return wj.EXCEPTION }
	base: [^]u8
	r: Idb_Reader
	sent := send_request(ctx, &b, &base, &r)
	idb_buf_free(&b)
	if !sent { return wj.EXCEPTION }
	n := idb_rd_uv(&r)
	bad := r.bad
	wj.js_free(ctx, base)
	return bad ? malformed(ctx) : wj.new_int64(ctx, i64(n))
}

// What execGetAll returns per record.
@(private = "file")
Get_All_Mode :: enum u64 { Keys = 1, Values = 2, Records = 3 }

// execGetAll(tx, store, index, range, mode, flags, limit): the browser answers a long list in pieces of about 2 MiB
// (with where to go on): one piece of bytes is in flight at a time.
@(private = "file")
host_exec_get_all :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	mode_n, ok1 := arg_u64(ctx, wj.arg(argc, argv, 4))
	flags, ok2 := arg_u64(ctx, wj.arg(argc, argv, 5))
	limit, ok3 := arg_u64(ctx, wj.arg(argc, argv, 6))
	if !ok1 || !ok2 || !ok3 { return wj.EXCEPTION }
	mode := Get_All_Mode(mode_n)
	per := u32(mode == .Records ? 3 : 1)
	out := wj.JS_NewArray(ctx)
	count: u32
	resume: [^]u8   // key, primary key: two length-prefixed byte strings
	resume_n: int
	fail :: proc "contextless" (ctx: ^wj.Context, out: wj.JSValue, resume: [^]u8) -> wj.JSValue {
		if resume != nil { wj.js_free(ctx, resume) }
		wj.JS_FreeValue(ctx, out)
		return wj.EXCEPTION
	}
	for {
		b := Idb_Buf{ ctx = ctx }
		if !query_header(ctx, &b, argc, argv, .Get_All) { idb_buf_free(&b); return fail(ctx, out, resume) }
		idb_buf_u8(&b, u8(mode_n))
		idb_buf_u8(&b, u8(flags | (resume != nil ? 4 : 0)))
		idb_buf_uv(&b, limit > 0 ? limit - u64(count / per) : 0)
		if resume != nil { idb_buf_raw(&b, resume[:resume_n]) }
		base: [^]u8
		r: Idb_Reader
		sent := send_request(ctx, &b, &base, &r)
		idb_buf_free(&b)
		if !sent { return fail(ctx, out, resume) }
		if resume != nil { wj.js_free(ctx, resume); resume = nil }
		n := idb_rd_uv(&r)
		for i: u64 = 0; i < n && !r.bad; i += 1 {
			v, v2, v3 := wj.UNDEFINED, wj.UNDEFINED, wj.UNDEFINED
			#partial switch mode {
			case .Keys:   v = key_value_of(ctx, &r)
			case .Values: v = value_of(ctx, &r)
			case:
				v = key_value_of(ctx, &r)
				v2 = wj.is_exception(v) ? wj.UNDEFINED : key_value_of(ctx, &r)
				v3 = wj.is_exception(v2) ? wj.UNDEFINED : value_of(ctx, &r)
			}
			if wj.is_exception(v) || wj.is_exception(v2) || wj.is_exception(v3) {
				if !wj.is_exception(v) { wj.JS_FreeValue(ctx, v) }
				if !wj.is_exception(v2) { wj.JS_FreeValue(ctx, v2) }
				if !wj.is_exception(v3) { wj.JS_FreeValue(ctx, v3) }
				wj.js_free(ctx, base)
				return fail(ctx, out, resume)
			}
			wj.JS_SetPropertyUint32(ctx, out, count, v)
			count += 1
			if mode == .Records {
				wj.JS_SetPropertyUint32(ctx, out, count, v2)
				wj.JS_SetPropertyUint32(ctx, out, count + 1, v3)
				count += 2
			}
		}
		more := idb_rd_u8(&r)
		items := count / per
		if r.bad { wj.js_free(ctx, base); malformed(ctx); return fail(ctx, out, resume) }
		if more == 0 || (limit > 0 && u64(items) >= limit) { wj.js_free(ctx, base); break }
		start := r.pos
		idb_rd_bytes(&r)
		idb_rd_bytes(&r)
		if r.bad { wj.js_free(ctx, base); malformed(ctx); return fail(ctx, out, resume) }
		resume_n = r.pos - start
		resume = ([^]u8)(wj.js_malloc(ctx, uint(max(resume_n, 1))))
		if resume == nil { wj.js_free(ctx, base); return fail(ctx, out, nil) }
		wj.memcpy(resume, &r.p[start], uint(resume_n))
		wj.js_free(ctx, base)
	}
	return out
}

// execPut(tx, store, flags, key, value, indexKeys)
@(private = "file")
host_exec_put :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	defer idb_buf_free(&b)
	if !begin_request(ctx, &b, wj.arg(argc, argv, 0), .Put, wj.arg(argc, argv, 1)) { return wj.EXCEPTION }
	flags, ok := arg_u64(ctx, wj.arg(argc, argv, 2))
	if !ok { return wj.EXCEPTION }
	idb_buf_u8(&b, u8(flags))
	if !wj.is_null(wj.arg(argc, argv, 3)) && !put_arg_bytes(ctx, &b, wj.arg(argc, argv, 3), true) { return wj.EXCEPTION }
	if !put_arg_bytes(ctx, &b, wj.arg(argc, argv, 4), true) { return wj.EXCEPTION }
	list := wj.arg(argc, argv, 5)
	n: u32
	if wj.is_object(list) {
		n, ok = array_length(ctx, list)
		if !ok { return wj.EXCEPTION }
	}
	idb_buf_uv(&b, u64(n / 2))
	for i: u32 = 0; i + 1 < n; i += 2 {
		id := wj.JS_GetPropertyUint32(ctx, list, i)
		k := wj.JS_GetPropertyUint32(ctx, list, i + 1)
		good := !wj.is_exception(id) && !wj.is_exception(k)
		idv: u64
		if good { idv, good = arg_u64(ctx, id) }
		if good { idb_buf_uv(&b, idv); good = put_arg_bytes(ctx, &b, k, true) }
		wj.JS_FreeValue(ctx, id)
		wj.JS_FreeValue(ctx, k)
		if !good { return wj.EXCEPTION }
	}
	base: [^]u8
	r: Idb_Reader
	if !send_request(ctx, &b, &base, &r) { return wj.EXCEPTION }
	key := key_value_of(ctx, &r)
	wj.js_free(ctx, base)
	return key
}

// execDelete(tx, store, range), execClear(tx, store)
@(private = "file")
host_exec_delete :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	defer idb_buf_free(&b)
	if !begin_request(ctx, &b, wj.arg(argc, argv, 0), .Delete, wj.arg(argc, argv, 1)) || !put_arg_bytes(ctx, &b, wj.arg(argc, argv, 2), false) {
		return wj.EXCEPTION
	}
	base: [^]u8
	r: Idb_Reader
	if !send_request(ctx, &b, &base, &r) { return wj.EXCEPTION }
	wj.js_free(ctx, base)
	return wj.UNDEFINED
}

@(private = "file")
host_exec_clear :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	defer idb_buf_free(&b)
	if !begin_request(ctx, &b, wj.arg(argc, argv, 0), .Clear, wj.arg(argc, argv, 1)) { return wj.EXCEPTION }
	base: [^]u8
	r: Idb_Reader
	if !send_request(ctx, &b, &base, &r) { return wj.EXCEPTION }
	wj.js_free(ctx, base)
	return wj.UNDEFINED
}

// execCursor(tx, store, index, range, direction, key, pk, target, targetPk, count, keyOnly)
@(private = "file")
host_exec_cursor :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Idb_Buf{ ctx = ctx }
	defer idb_buf_free(&b)
	if !query_header(ctx, &b, argc, argv, .Cursor) { return wj.EXCEPTION }
	direction, ok1 := arg_u64(ctx, wj.arg(argc, argv, 4))
	if !ok1 { return wj.EXCEPTION }
	count, ok2 := arg_u64(ctx, wj.arg(argc, argv, 9))
	if !ok2 { return wj.EXCEPTION }
	key_only := wj.JS_ToBool(ctx, wj.arg(argc, argv, 10)) > 0
	idb_buf_u8(&b, u8(direction))
	if wj.is_null(wj.arg(argc, argv, 5)) {
		idb_buf_u8(&b, 0); idb_buf_uv(&b, 0); idb_buf_uv(&b, 0)
	} else {
		idb_buf_u8(&b, 1)
		if !put_arg_bytes(ctx, &b, wj.arg(argc, argv, 5), true) || !put_arg_bytes(ctx, &b, wj.arg(argc, argv, 6), true) { return wj.EXCEPTION }
	}
	for i in i32(7) ..= 8 {
		if wj.is_null(wj.arg(argc, argv, i)) {
			idb_buf_u8(&b, 0); idb_buf_uv(&b, 0)
		} else {
			idb_buf_u8(&b, 1)
			if !put_arg_bytes(ctx, &b, wj.arg(argc, argv, i), true) { return wj.EXCEPTION }
		}
	}
	idb_buf_uv(&b, count)
	idb_buf_u8(&b, key_only ? 1 : 0)
	base: [^]u8
	r: Idb_Reader
	if !send_request(ctx, &b, &base, &r) { return wj.EXCEPTION }
	defer wj.js_free(ctx, base)
	if idb_rd_u8(&r) == 0 { return r.bad ? malformed(ctx) : wj.NULL }
	k := idb_rd_bytes(&r)
	pk := idb_rd_bytes(&r)
	if r.bad { return malformed(ctx) }
	kv := idb_u8(ctx, k)
	pv := idb_u8(ctx, pk)
	val := key_only ? wj.UNDEFINED : value_of(ctx, &r)
	if wj.is_exception(kv) || wj.is_exception(pv) || wj.is_exception(val) {
		if !wj.is_exception(kv) { wj.JS_FreeValue(ctx, kv) }
		if !wj.is_exception(pv) { wj.JS_FreeValue(ctx, pv) }
		if !wj.is_exception(val) { wj.JS_FreeValue(ctx, val) }
		return wj.EXCEPTION
	}
	out := wj.JS_NewArray(ctx)
	wj.JS_SetPropertyUint32(ctx, out, 0, kv)
	wj.JS_SetPropertyUint32(ctx, out, 1, pv)
	wj.JS_SetPropertyUint32(ctx, out, 2, val)
	return out
}

// navigator.storage.getDirectory() and StorageBucket.getDirectory() (web_fs.odin; the bucket's name, "" for the
// default one)
@(private = "file")
host_get_directory :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return web_fs_get_directory(ctx, wj.arg(argc, argv, 0))
}

// The host object's native members (web_idb.odin makes the object).
idb_native_install :: proc "contextless" (ctx: ^wj.Context, host: wj.JSValue) {
	fns := [?]struct { name: cstring, fn: wj.Native, length: i32 }{
		{"utf8", host_utf8, 1}, {"utf8d", host_utf8d, 1}, {"key", host_key, 1}, {"keyValue", host_key_value, 1}, {"cmp", host_cmp, 2},
		{"validPath", host_valid_path, 1}, {"pathKey", host_path_key, 2}, {"indexKeys", host_index_keys, 3},
		{"canInject", host_can_inject, 2}, {"inject", host_inject, 3},
		{"setFailure", host_set_failure, 1}, {"execGet", host_exec_get, 5}, {"execCount", host_exec_count, 4},
		{"execGetAll", host_exec_get_all, 7}, {"execPut", host_exec_put, 6}, {"execDelete", host_exec_delete, 3},
		{"execClear", host_exec_clear, 2}, {"execCursor", host_exec_cursor, 11},
		{"getDirectory", host_get_directory, 1},
	}
	for f in fns { idb_host_fn(ctx, host, f.name, f.fn, f.length) }
}
