// buffer.odin: Web IDL buffer source types (ArrayBuffer, SharedArrayBuffer, ArrayBufferView, BufferSource) and the
// browser's buffers (module async: Buffer), ported from native/js/runtime/buffer.c. Same symbols (web_buffer_preinit,
// wj_is_buffer_source, wj_is_array_buffer, wj_is_array_buffer_view, wj_typed_array_type, wj_to_buffer_source,
// wj_key_buffer_bytes, wj_arraybuffer_take, wj_uint8array_take, wj_arraybuffer_from_host, wj_uint8array_from_host,
// wj_host_buffer) and behaviour.
//
// The engine's heap is the module's linear memory, so a BufferSource's bytes are already where a browser function
// reads them: converting one is getting a pointer and a length, never a copy. A browser buffer becomes an ArrayBuffer
// with exactly one copy, into memory the ArrayBuffer then owns (from the engine's allocator). See docs/js/odin-glue.md.
package odin_glue

import "../odin/wj"

// WJ_BS_* flags (web.h).
@(private = "file") BS_VIEW_ONLY    :: 1 << 0
@(private = "file") BS_ALLOW_SHARED :: 1 << 1

@(private = "file") ab_class, sab_class, dataview_class: wj.Class_ID
@(private = "file") dv_buffer, dv_offset, dv_length: wj.JSValue   // DataView.prototype's getters (counted)

@(private = "file")
web_ab_realloc :: proc "c" (rt: ^wj.Runtime, opaque: rawptr, ptr: rawptr, size: uint) -> rawptr {
	if size == 0 { wj.js_free_rt(rt, ptr); return nil }
	return wj.js_realloc_rt(rt, ptr, size)
}

@(export, link_name = "web_buffer_preinit")
web_buffer_preinit :: proc "c" (ctx: ^wj.Context) -> i32 {
	src := "[new ArrayBuffer(0), typeof SharedArrayBuffer == 'function' ? new SharedArrayBuffer(0) : null, new DataView(new ArrayBuffer(0))]"
	v := wj.JS_Eval(ctx, ([^]u8)(raw_data(src)), len(src), "<web>", wj.EVAL_TYPE_GLOBAL)
	if wj.is_exception(v) { return -1 }
	a := wj.JS_GetPropertyUint32(ctx, v, 0)
	s := wj.JS_GetPropertyUint32(ctx, v, 1)
	d := wj.JS_GetPropertyUint32(ctx, v, 2)
	ab_class = wj.JS_GetClassID(a)
	sab_class = wj.is_object(s) ? wj.JS_GetClassID(s) : wj.Class_ID(0xFFFFFFFF)
	dataview_class = wj.JS_GetClassID(d)
	proto := wj.JS_GetPrototype(ctx, d)
	getters := [3]^wj.JSValue{ &dv_buffer, &dv_offset, &dv_length }
	names := [3]cstring{ "buffer", "byteOffset", "byteLength" }
	for i in 0 ..< 3 {
		at := wj.JS_NewAtom(ctx, names[i])
		desc: wj.Property_Descriptor
		getters[i]^ = wj.UNDEFINED
		if wj.JS_GetOwnProperty(ctx, &desc, proto, at) > 0 {
			getters[i]^ = desc.getter
			wj.JS_FreeValue(ctx, desc.setter)
			wj.JS_FreeValue(ctx, desc.value)
		}
		wj.JS_FreeAtom(ctx, at)
	}
	wj.JS_FreeValue(ctx, proto)
	wj.JS_FreeValue(ctx, a)
	wj.JS_FreeValue(ctx, s)
	wj.JS_FreeValue(ctx, d)
	wj.JS_FreeValue(ctx, v)
	return 0
}

@(export, link_name = "wj_is_array_buffer")
wj_is_array_buffer :: proc "c" (v: wj.JSValue) -> bool {
	return wj.is_object(v) && wj.JS_GetClassID(v) == ab_class
}

@(export, link_name = "wj_is_buffer_source")
wj_is_buffer_source :: proc "c" (v: wj.JSValue) -> bool {
	if !wj.is_object(v) { return false }
	id := wj.JS_GetClassID(v)
	return id == ab_class || id == sab_class || id == dataview_class || wj.JS_GetTypedArrayType(v) >= 0
}

@(export, link_name = "wj_is_array_buffer_view")
wj_is_array_buffer_view :: proc "c" (v: wj.JSValue) -> bool {
	return wj.is_object(v) && (wj.JS_GetClassID(v) == dataview_class || wj.JS_GetTypedArrayType(v) >= 0)
}

@(export, link_name = "wj_typed_array_type")
wj_typed_array_type :: proc "c" (v: wj.JSValue) -> i32 {
	return wj.is_object(v) ? wj.JS_GetTypedArrayType(v) : -1
}

@(private = "file")
dv_number :: proc "c" (ctx: ^wj.Context, getter: wj.JSValue, v: wj.JSValue, out: ^uint) -> bool {
	r := wj.JS_Call(ctx, getter, v, 0, nil)
	if wj.is_exception(r) { return false }
	d: f64 = 0
	wj.JS_ToFloat64(ctx, &d, r)
	wj.JS_FreeValue(ctx, r)
	out^ = d > 0 ? uint(d) : 0
	return true
}

@(private = "file") bs_empty: [1]u8

@(export, link_name = "wj_to_buffer_source")
wj_to_buffer_source :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, ptr: ^[^]u8, length: ^uint, flags: i32, what: cstring) -> bool {
	ptr^ = &bs_empty[0]
	length^ = 0
	if !wj.is_object(v) { return not_one(ctx, flags, what) }
	id := wj.JS_GetClassID(v)
	if id == ab_class || id == sab_class {
		if flags & BS_VIEW_ONLY != 0 { return not_one(ctx, flags, what) }
		if id == sab_class && flags & BS_ALLOW_SHARED == 0 { wj.JS_ThrowTypeError(ctx, "%s: a SharedArrayBuffer is not allowed", what); return false }
		n: uint = 0
		p := wj.JS_GetArrayBuffer(ctx, &n, v)
		if p == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return true }   // detached: no bytes
		ptr^ = p
		length^ = n
		return true
	}
	buffer: wj.JSValue
	off: uint = 0
	n: uint = 0
	if wj.JS_GetTypedArrayType(v) >= 0 {
		buffer = wj.JS_GetTypedArrayBuffer(ctx, v, &off, &n, nil)
		if wj.is_exception(buffer) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return true }   // out of bounds / detached
	} else if id == dataview_class {
		buffer = wj.JS_Call(ctx, dv_buffer, v, 0, nil)
		if wj.is_exception(buffer) { return false }
		if !dv_number(ctx, dv_offset, v, &off) || !dv_number(ctx, dv_length, v, &n) {
			wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
			wj.JS_FreeValue(ctx, buffer)
			return true   // detached
		}
	} else {
		return not_one(ctx, flags, what)
	}
	if wj.JS_GetClassID(buffer) == sab_class && flags & BS_ALLOW_SHARED == 0 {
		wj.JS_FreeValue(ctx, buffer)
		wj.JS_ThrowTypeError(ctx, "%s: a view on a SharedArrayBuffer is not allowed", what)
		return false
	}
	total: uint = 0
	p := wj.JS_GetArrayBuffer(ctx, &total, buffer)
	wj.JS_FreeValue(ctx, buffer)   // the view keeps it alive
	if p == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return true }
	if off > total { off = total }
	if n > total - off { n = total - off }
	ptr^ = p[off:]
	length^ = n
	return true
}

@(private = "file")
not_one :: proc "c" (ctx: ^wj.Context, flags: i32, what: cstring) -> bool {
	kind := flags & BS_VIEW_ONLY != 0 ? "an ArrayBufferView" : "an ArrayBuffer or ArrayBufferView"
	wj.JS_ThrowTypeError(ctx, "%s: the argument is not %s", what, kind)
	return false
}

// The bytes of a candidate for an IndexedDB key: 1 with the bytes, 0 when it is neither or its buffer is detached /
// the view out of bounds (no exception), -1 with an exception pending.
@(export, link_name = "wj_key_buffer_bytes")
wj_key_buffer_bytes :: proc "c" (ctx: ^wj.Context, v: wj.JSValue, ptr: ^[^]u8, length: ^uint) -> i32 {
	ptr^ = nil
	length^ = 0
	if !wj.is_object(v) { return 0 }
	id := wj.JS_GetClassID(v)
	buffer: wj.JSValue
	off: uint = 0
	n: uint = 0
	if id == ab_class {
		total: uint = 0
		p := wj.JS_GetArrayBuffer(ctx, &total, v)
		if p == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 0 }
		ptr^ = p
		length^ = total
		return 1
	}
	if wj.JS_GetTypedArrayType(v) >= 0 {
		buffer = wj.JS_GetTypedArrayBuffer(ctx, v, &off, &n, nil)
		if wj.is_exception(buffer) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 0 }
	} else if id == dataview_class {
		buffer = wj.JS_Call(ctx, dv_buffer, v, 0, nil)
		if wj.is_exception(buffer) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 0 }
		if !dv_number(ctx, dv_offset, v, &off) || !dv_number(ctx, dv_length, v, &n) {
			wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
			wj.JS_FreeValue(ctx, buffer)
			return 0
		}
	} else {
		return 0
	}
	total: uint = 0
	p := wj.JS_GetArrayBuffer(ctx, &total, buffer)
	wj.JS_FreeValue(ctx, buffer)   // the view keeps it alive
	if p == nil { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 0 }
	if off > total || n > total - off { return 0 }
	ptr^ = p[off:]
	length^ = n
	return 1
}

@(export, link_name = "wj_arraybuffer_take")
wj_arraybuffer_take :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint) -> wj.JSValue {
	ab := wj.JS_NewArrayBuffer(ctx, p, n, 0, web_ab_realloc, nil, false)
	if wj.is_exception(ab) { wj.js_free(ctx, p) }
	return ab
}

@(export, link_name = "wj_uint8array_take")
wj_uint8array_take :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint) -> wj.JSValue {
	ab := wj_arraybuffer_take(ctx, p, n)
	if wj.is_exception(ab) { return ab }
	u8v := wj.JS_NewTypedArray(ctx, 1, &ab, wj.TYPED_ARRAY_UINT8)
	wj.JS_FreeValue(ctx, ab)
	return u8v
}

// the bytes of a browser buffer in memory of the engine's allocator (one copy)
@(private = "file")
host_bytes :: proc "c" (ctx: ^wj.Context, buffer: u64, n_out: ^uint) -> [^]u8 {
	n := buffer != 0 ? wj.wr_Buffer_length(buffer) : 0
	if n < 0 { n = 0 }
	p := ([^]u8)(wj.js_malloc(ctx, n > 0 ? uint(n) : 1))
	if p == nil { return nil }
	done: uint = 0
	// Buffer_read copies at most 2^31 bytes per call
	for i64(done) < n {
		chunk := uint(n) - done
		if chunk > 0x40000000 { chunk = 0x40000000 }
		got := wj.wr_Buffer_read(buffer, i64(done), p[done:], u32(chunk))
		if got <= 0 { break }
		done += uint(got)
	}
	n_out^ = done
	return p
}

@(export, link_name = "wj_arraybuffer_from_host")
wj_arraybuffer_from_host :: proc "c" (ctx: ^wj.Context, buffer: u64) -> wj.JSValue {
	n: uint = 0
	p := host_bytes(ctx, buffer, &n)
	if p == nil { return wj.EXCEPTION }
	return wj_arraybuffer_take(ctx, p, n)
}

@(export, link_name = "wj_uint8array_from_host")
wj_uint8array_from_host :: proc "c" (ctx: ^wj.Context, buffer: u64) -> wj.JSValue {
	n: uint = 0
	p := host_bytes(ctx, buffer, &n)
	if p == nil { return wj.EXCEPTION }
	return wj_uint8array_take(ctx, p, n)
}

@(export, link_name = "wj_host_buffer")
wj_host_buffer :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint) -> u64 {
	if n > 0xFFFFFFFF { wj.JS_ThrowRangeError(ctx, "the data is too large"); return 0 }
	h: u64 = 0
	data := p != nil ? p : ([^]u8)(&bs_empty[0])
	st := wj.wr_Buffer_create(data, u32(n), &h)
	if st < 0 { wj.wj_throw_status(ctx, st, "Buffer_create"); return 0 }
	return h
}
