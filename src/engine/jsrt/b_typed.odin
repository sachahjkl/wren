package jsrt

// ArrayBuffer, SharedArrayBuffer (resizable/growable), the TypedArray family, DataView and Atomics
// (ECMA-262 §25.1–25.4, §23.2). Elements are stored little-endian, as on every target we build for.

import "base:intrinsics"
import "core:math"
import "wb:engine/bigint"

MAX_BUFFER_BYTES :: 1 << 32

Elem :: enum u8 {u8c, i8, u8, i16, u16, i32, u32, i64, u64, f16, f32, f64}

elem_size := [Elem]int{.u8c = 1, .i8 = 1, .u8 = 1, .i16 = 2, .u16 = 2, .i32 = 4, .u32 = 4, .i64 = 8, .u64 = 8, .f16 = 2, .f32 = 4, .f64 = 8}
elem_names := [Elem]string {
	.u8c = "Uint8ClampedArray", .i8 = "Int8Array", .u8 = "Uint8Array", .i16 = "Int16Array", .u16 = "Uint16Array",
	.i32 = "Int32Array", .u32 = "Uint32Array", .i64 = "BigInt64Array", .u64 = "BigUint64Array", .f16 = "Float16Array",
	.f32 = "Float32Array", .f64 = "Float64Array",
}

class_elem :: #force_inline proc(c: Class_ID) -> Elem {return Elem(u8(c) - u8(FIRST_TYPED_ARRAY))}
elem_class :: #force_inline proc(e: Elem) -> Class_ID {return Class_ID(u8(FIRST_TYPED_ARRAY) + u8(e))}
elem_is_bigint :: #force_inline proc(e: Elem) -> bool {return e == .i64 || e == .u64}

// --- buffers ---

array_buffer_of :: proc(o: ^Object) -> ^Array_Buffer {
	if o == nil {return nil}
	ab, ok := o.data.(^Array_Buffer)
	if !ok {return nil}
	return ab
}

// AllocateArrayBuffer / AllocateSharedArrayBuffer
array_buffer_new :: proc(ctx: ^Context, proto: ^Object, class: Class_ID, n: i64, max_len: i64 = -1) -> ^Object {
	rt := ctx.rt
	if n > MAX_BUFFER_BYTES || max_len > MAX_BUFFER_BYTES || mem_over_limit(rt, max(n, max_len)) {
		throw_range_error(ctx, "array buffer allocation failed")
		return nil
	}
	o := object_new_proto(ctx, proto, class)
	ab := new(Array_Buffer, rt_allocator(rt))
	ab.byte_length = int(n)
	ab.max_byte_length = int(max_len)
	ab.shared = class == .shared_array_buffer
	cap := int(max(n, max_len, 1))
	ab.data = cast([^]u8)mem_alloc(rt, cap)
	ab.alloc_len = cap
	ab.views = make([dynamic]^Object, rt_allocator(rt))
	o.data = ab
	return o
}

// An ArrayBuffer of `n` bytes that live with the embedder (Buffer_Host). Not resizable, not transferable.
array_buffer_new_host :: proc(ctx: ^Context, n: i64, host: Buffer_Host) -> ^Object {
	rt := ctx.rt
	o := object_new_proto(ctx, ctx.class_proto[.array_buffer], .array_buffer)
	ab := new(Array_Buffer, rt_allocator(rt))
	ab.byte_length = int(n)
	ab.max_byte_length = -1
	ab.views = make([dynamic]^Object, rt_allocator(rt))
	ab.host = new_clone(host, rt_allocator(rt))
	o.data = ab
	return o
}

// The bytes [lo, hi) of a host buffer are in `data` until the matching host_unpin (`data` keeps its meaning: an offset in
// the buffer). No JavaScript may run while pinned, so nothing else sees the copy. Pins nest: a builtin with two views on
// one buffer pins both before it writes anything (the second, when larger, reads the union again). Does nothing for an
// ordinary buffer. `n` bytes of the engine's heap are taken for the time.
host_pin :: proc(rt: ^Runtime, ab: ^Array_Buffer, lo, hi: int) {
	h := ab.host
	if h == nil {return}
	lo, hi := lo, hi
	if h.pin_depth > 0 {
		h.pin_depth += 1
		if lo >= h.pin_lo && hi <= h.pin_hi {return}
		lo, hi = min(lo, h.pin_lo), max(hi, h.pin_hi)
		mem_free(rt, h.pin, h.pin_hi - h.pin_lo)
	} else {
		h.pin_depth = 1
		h.pin_dirty = false
	}
	// (never empty: `data` nil means not pinned)
	hi = max(hi, lo + 1)
	h.pin = cast([^]u8)mem_alloc(rt, hi - lo)
	h.pin_lo, h.pin_hi = lo, hi
	n := min(hi, ab.byte_length) - lo
	if n > 0 {h.read(h.user, lo, h.pin, n)}
	ab.data = cast([^]u8)(uintptr(h.pin) - uintptr(lo))
}

// `written`: what was pinned goes back to the embedder at the last unpin.
host_unpin :: proc(rt: ^Runtime, ab: ^Array_Buffer, written: bool) {
	h := ab.host
	if h == nil {return}
	if written {h.pin_dirty = true}
	h.pin_depth -= 1
	if h.pin_depth > 0 {return}
	n := min(h.pin_hi, ab.byte_length) - h.pin_lo
	if h.pin_dirty && n > 0 {h.write(h.user, h.pin_lo, h.pin, n)}
	mem_free(rt, h.pin, h.pin_hi - h.pin_lo)
	h.pin = nil
	ab.data = nil
}

// The bytes of a whole view in `data`, for a builtin that goes through them (host_unpin_view after).
@(private = "file")
host_pin_view :: proc(ctx: ^Context, o: ^Object) {
	ta := typed_array_of(o)
	ab := array_buffer_of(ta.buffer)
	if ab.host == nil {return}
	es := o.class == .dataview ? 1 : elem_size[class_elem(o.class)]
	host_pin(ctx.rt, ab, ta.offset, ta.offset + typed_array_length(ctx, o) * es)
}

@(private = "file")
host_unpin_view :: proc(ctx: ^Context, o: ^Object, written: bool) {
	host_unpin(ctx.rt, array_buffer_of(typed_array_of(o).buffer), written)
}

// (the object is going, or the embedder detached it: a pin cannot be under way, no JavaScript runs during one)
buffer_host_release :: proc(rt: ^Runtime, ab: ^Array_Buffer) {
	for &s in rt.host_snapshots {
		if s.host == ab.host {s.host = nil}   // (the copy stays until its slot is used again: a caller may be reading it)
	}
	free(ab.host, rt_allocator(rt))
	ab.host = nil
}

// What the embedder does when the memory behind a host buffer grew: the buffer is detached (only the embedder can).
detach_host_buffer :: proc(ctx: ^Context, o: ^Object) {
	ab := array_buffer_of(o)
	if ab == nil || ab.host == nil {return}
	buffer_host_release(ctx.rt, ab)
	ab.byte_length = 0
	ab.detached = true
}

// Free what a buffer's data pointer owns: host memory through its release proc, shared memory of
// another agent not at all, the engine's own memory through the heap.
buffer_release_data :: proc(rt: ^Runtime, ab: ^Array_Buffer) {
	if ab.data == nil {return}
	if ab.free_proc != nil {
		ab.free_proc(ab.data, ab.free_user)
		ab.free_proc = nil
	} else if !ab.external {
		mem_free(rt, ab.data, ab.alloc_len)
	}
}

// The memory behind a SharedArrayBuffer, to hand to another agent (a thread with its own Runtime).
// The buffer must outlive that agent.
shared_buffer_info :: proc(v: Value) -> (data: [^]u8, length, max_length: int, ok: bool) {
	if v.tag != .object || as_obj(v).class != .shared_array_buffer {return}
	ab := array_buffer_of(as_obj(v))
	return ab.data, ab.byte_length, ab.max_byte_length, true
}

// A SharedArrayBuffer over memory owned by another agent's buffer.
shared_buffer_attach :: proc(ctx: ^Context, data: [^]u8, length, max_length: int) -> Value {
	o := array_buffer_new(ctx, ctx.class_proto[.shared_array_buffer], .shared_array_buffer, 0, -1)
	if o == nil {return EXCEPTION}
	ab := array_buffer_of(o)
	mem_free(ctx.rt, ab.data, ab.alloc_len)
	ab.data = data
	ab.alloc_len = max(length, max_length, 1)
	ab.byte_length = length
	ab.max_byte_length = max_length
	ab.external = true
	return mk_obj(o)
}

@(private = "file")
this_buffer :: proc(ctx: ^Context, this: Value, shared: bool) -> ^Array_Buffer {
	cls: Class_ID = shared ? .shared_array_buffer : .array_buffer
	if this.tag == .object && as_obj(this).class == cls {return array_buffer_of(as_obj(this))}
	throw_type_error(ctx, shared ? "not a SharedArrayBuffer" : "not an ArrayBuffer")
	return nil
}

detach_array_buffer :: proc(ctx: ^Context, o: ^Object) -> bool {
	ab := array_buffer_of(o)
	if ab == nil || ab.shared || ab.host != nil {
		throw_type_error(ctx, "not a detachable ArrayBuffer")
		return false
	}
	if ab.detached {return true}
	buffer_release_data(ctx.rt, ab)
	ab.data = nil
	ab.alloc_len = 0
	ab.byte_length = 0
	ab.detached = true
	return true
}

detach_array_buffer_value :: proc(ctx: ^Context, v: Value) -> Value {
	if v.tag != .object || as_obj(v).class != .array_buffer {return throw_type_error(ctx, "not an ArrayBuffer")}
	if !detach_array_buffer(ctx, as_obj(v)) {return EXCEPTION}
	return NULL
}

@(private = "file")
buffer_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	cls := Class_ID(magic)
	n, ok := to_index(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	max_len: i64 = -1
	opts := arg(args, 1)
	if opts.tag == .object {
		mv := get(ctx, opts, pa(.A_maxByteLength))
		if is_exception(mv) {return EXCEPTION}
		if !is_undefined(mv) {
			m, ok2 := to_index(ctx, mv)
			if !ok2 {return EXCEPTION}
			if n > m {return throw_range_error(ctx, "byte length exceeds maxByteLength")}
			max_len = m
		}
	}
	proto, ok3 := proto_from_ctor(ctx, nt, cls)
	if !ok3 {return EXCEPTION}
	o := array_buffer_new(ctx, proto, cls, n, max_len)
	if o == nil {return EXCEPTION}
	return mk_obj(o)
}

@(private = "file")
buffer_is_view :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v := arg(args, 0)
	if v.tag != .object {return FALSE}
	c := as_obj(v).class
	return mk_bool(is_typed_array_class(c) || c == .dataview)
}

// byteLength(0) maxByteLength(1) resizable(2) detached(3); magic bit 8: shared
@(private = "file")
buffer_getter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	shared := magic & 0x100 != 0
	ab := this_buffer(ctx, this, shared)
	if ab == nil {return EXCEPTION}
	switch magic & 0xff {
	case 0: return mk_i64(i64(ab.byte_length))
	case 1: return mk_i64(i64(ab.max_byte_length >= 0 ? ab.max_byte_length : ab.byte_length))
	case 2: return mk_bool(ab.max_byte_length >= 0)
	case 3: return mk_bool(ab.detached)
	case 4: return mk_bool(ab.immutable)
	}
	return UNDEFINED
}

@(private = "file")
throw_immutable :: proc(ctx: ^Context) -> Value {return throw_type_error(ctx, "ArrayBuffer is immutable")}

// Is the buffer under this view immutable?
view_is_immutable :: proc(o: ^Object) -> bool {
	ta := typed_array_of(o)
	if ta == nil {return false}
	ab := array_buffer_of(ta.buffer)
	return ab != nil && ab.immutable
}

// resize (ArrayBuffer) / grow (SharedArrayBuffer)
@(private = "file")
buffer_resize :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	shared := magic == 1
	ab := this_buffer(ctx, this, shared)
	if ab == nil {return EXCEPTION}
	if ab.immutable {return throw_immutable(ctx)}
	if ab.max_byte_length < 0 {return throw_type_error(ctx, shared ? "SharedArrayBuffer is not growable" : "ArrayBuffer is not resizable")}
	n, ok := to_index(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
	if n > i64(ab.max_byte_length) {return throw_range_error(ctx, "new length exceeds maxByteLength")}
	if shared && n < i64(ab.byte_length) {return throw_range_error(ctx, "SharedArrayBuffer cannot shrink")}
	old := ab.byte_length
	if int(n) > old {
		for i in old ..< int(n) {ab.data[i] = 0}
	} else {
		for i in int(n) ..< old {ab.data[i] = 0}
	}
	ab.byte_length = int(n)
	_ = rt
	return UNDEFINED
}

@(private = "file")
// slice (magic bit 0: shared) / sliceToImmutable (bit 1)
buffer_slice :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	shared := magic & 1 != 0
	immutable := magic & 2 != 0
	cls: Class_ID = shared ? .shared_array_buffer : .array_buffer
	ab := this_buffer(ctx, this, shared)
	if ab == nil {return EXCEPTION}
	if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
	if ab.immutable {return throw_immutable(ctx)}
	n := i64(ab.byte_length)
	first, ok := relative_index(ctx, arg(args, 0), n, 0)
	if !ok {return EXCEPTION}
	final, ok2 := relative_index(ctx, arg(args, 1), n, n)
	if !ok2 {return EXCEPTION}
	count := max(final - first, 0)
	nv: Value
	if immutable {
		o := array_buffer_new(ctx, ctx.class_proto[.array_buffer], .array_buffer, count)
		if o == nil {return EXCEPTION}
		nv = mk_obj(o)
	} else {
		c := species_constructor(ctx, this, get(ctx, mk_obj(ctx.global_obj), atom_from_utf8(ctx.rt, shared ? "SharedArrayBuffer" : "ArrayBuffer")))
		if is_exception(c) {return EXCEPTION}
		nv = construct(ctx, c, {mk_i64(count)}, c)
		if is_exception(nv) {return EXCEPTION}
	}
	if nv.tag != .object || as_obj(nv).class != cls {return throw_type_error(ctx, "species constructor did not return a buffer")}
	nb := array_buffer_of(as_obj(nv))
	if nb.immutable {return throw_immutable(ctx)}
	if as_obj(nv) == as_obj(this) {return throw_type_error(ctx, "species constructor returned the same buffer")}
	if nb.detached {return throw_type_error(ctx, "species result is detached")}
	if i64(nb.byte_length) < count {return throw_type_error(ctx, "species result is too small")}
	if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
	cur := i64(ab.byte_length)
	if immutable && cur < first + count {return throw_range_error(ctx, "invalid array buffer length")}
	if first < cur {
		end := min(first + count, cur)
		host_pin(ctx.rt, ab, int(first), int(end))
		host_pin(ctx.rt, nb, 0, int(end - first))
		for i in first ..< end {nb.data[i - first] = ab.data[i]}
		host_unpin(ctx.rt, nb, true)
		host_unpin(ctx.rt, ab, false)
	}
	nb.immutable = immutable
	return nv
}

// transfer(0) transferToFixedLength(1)
@(private = "file")
buffer_transfer :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	ab := this_buffer(ctx, this, false)
	if ab == nil {return EXCEPTION}
	n := i64(ab.byte_length)
	if !is_undefined(arg(args, 0)) {
		ok: bool
		n, ok = to_index(ctx, args[0])
		if !ok {return EXCEPTION}
	}
	if ab.immutable {return throw_immutable(ctx)}
	if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
	if ab.host != nil {return throw_type_error(ctx, "the buffer of a WebAssembly.Memory cannot be transferred")}
	max_len: i64 = -1
	if magic == 0 && ab.max_byte_length >= 0 {max_len = i64(ab.max_byte_length)}
	if max_len >= 0 && n > max_len {return throw_range_error(ctx, "new length exceeds maxByteLength")}
	o := array_buffer_new(ctx, ctx.class_proto[.array_buffer], .array_buffer, n, max_len)
	if o == nil {return EXCEPTION}
	nb := array_buffer_of(o)
	k := min(int(n), ab.byte_length)
	for i in 0 ..< k {nb.data[i] = ab.data[i]}
	detach_array_buffer(ctx, as_obj(this))
	nb.immutable = magic == 2
	_ = rt
	return mk_obj(o)
}

// --- typed array state ---

typed_array_of :: #force_inline proc(o: ^Object) -> ^Typed_Array {
	ta, ok := o.data.(^Typed_Array)
	if !ok {return nil}
	return ta
}

// IsTypedArrayOutOfBounds (also true when detached).
typed_array_is_out_of_bounds :: proc(o: ^Object) -> bool {
	ta := typed_array_of(o)
	if ta == nil {return true}
	ab := array_buffer_of(ta.buffer)
	if ab == nil || ab.detached {return true}
	es := o.class == .dataview ? 1 : elem_size[class_elem(o.class)]
	if ta.offset > ab.byte_length {return true}
	if !ta.track_rab && ta.offset + ta.length * es > ab.byte_length {return true}
	return false
}

// TypedArrayLength (0 when out of bounds).
typed_array_length :: proc(ctx: ^Context, o: ^Object) -> int {
	if typed_array_is_out_of_bounds(o) {return 0}
	ta := typed_array_of(o)
	if !ta.track_rab {return ta.length}
	ab := array_buffer_of(ta.buffer)
	es := o.class == .dataview ? 1 : elem_size[class_elem(o.class)]
	return (ab.byte_length - ta.offset) / es
}

typed_array_is_fixed_length :: proc(o: ^Object) -> bool {
	ta := typed_array_of(o)
	if ta == nil {return true}
	if ta.track_rab {return false}
	ab := array_buffer_of(ta.buffer)
	return ab == nil || ab.max_byte_length < 0 || ab.shared
}

@(private = "file")
elem_ptr :: #force_inline proc(o: ^Object, i: int) -> rawptr {
	ta := typed_array_of(o)
	ab := array_buffer_of(ta.buffer)
	return &ab.data[ta.offset + i * elem_size[class_elem(o.class)]]
}

// One element of a view, whatever holds its bytes.
@(private = "file")
view_read :: #force_inline proc(ctx: ^Context, o: ^Object, i: int) -> Value {
	ta := typed_array_of(o)
	ab := array_buffer_of(ta.buffer)
	e := class_elem(o.class)
	if h := ab.host; h != nil && ab.data == nil {
		tmpb: [16]u8
		h.read(h.user, ta.offset + i * elem_size[e], &tmpb[0], elem_size[e])
		return read_elem(ctx, e, &tmpb[0])
	}
	return read_elem(ctx, e, &ab.data[ta.offset + i * elem_size[e]])
}

@(private = "file")
view_write :: #force_inline proc(o: ^Object, i: int, ev: Elem_Val) {
	ta := typed_array_of(o)
	ab := array_buffer_of(ta.buffer)
	e := class_elem(o.class)
	if h := ab.host; h != nil && ab.data == nil {
		tmpb: [16]u8
		write_elem(e, &tmpb[0], ev)
		h.write(h.user, ta.offset + i * elem_size[e], &tmpb[0], elem_size[e])
		return
	}
	write_elem(e, &ab.data[ta.offset + i * elem_size[e]], ev)
}

read_elem :: proc(ctx: ^Context, e: Elem, p: rawptr) -> Value {
	switch e {
	case .u8c, .u8: return mk_int(i32((cast(^u8)p)^))
	case .i8: return mk_int(i32((cast(^i8)p)^))
	case .i16: return mk_int(i32((cast(^i16)p)^))
	case .u16: return mk_int(i32((cast(^u16)p)^))
	case .i32: return mk_int((cast(^i32)p)^)
	case .u32: return mk_u32((cast(^u32)p)^)
	case .f16: return mk_number(f64(f16_to_f32((cast(^u16)p)^)))
	case .f32: return mk_number(f64((cast(^f32)p)^))
	case .f64: return mk_number((cast(^f64)p)^)
	case .i64:
		context.allocator = rt_allocator(ctx.rt)
		return mk_big(bigint_new(ctx.rt, bigint.from_i64((cast(^i64)p)^)))
	case .u64:
		context.allocator = rt_allocator(ctx.rt)
		return mk_big(bigint_new(ctx.rt, bigint.from_u64((cast(^u64)p)^)))
	}
	return UNDEFINED
}

// Convert a script value to the element type (ToNumber/ToBigInt), before any bounds check.
Elem_Val :: struct {
	d: f64,
	b: u64,
}

to_elem_val :: proc(ctx: ^Context, e: Elem, v: Value) -> (Elem_Val, bool) {
	if elem_is_bigint(e) {
		bv := to_bigint(ctx, v)
		if is_exception(bv) {return {}, false}
		return Elem_Val{b = bigint_to_u64_wrap(as_big(bv))}, true
	}
	d, ok := to_number(ctx, v)
	return Elem_Val{d = d}, ok
}

bigint_to_u64_wrap :: proc(b: ^JS_BigInt) -> u64 {
	m := b.val.mag
	lo: u64 = 0
	if len(m) > 0 {lo = u64(m[0])}
	if len(m) > 1 {lo |= u64(m[1]) << 32}
	if b.val.neg {lo = ~lo + 1}
	return lo
}

write_elem :: proc(e: Elem, p: rawptr, v: Elem_Val) {
	switch e {
	case .u8c:
		d := v.d
		r: u8
		if d != d || d <= 0 {r = 0} else if d >= 255 {r = 255} else {
			f := math.floor(d)
			diff := d - f
			if diff > 0.5 || (diff == 0.5 && u64(f) & 1 == 1) {r = u8(f + 1)} else {r = u8(f)}
		}
		(cast(^u8)p)^ = r
	case .u8, .i8: (cast(^u8)p)^ = u8(f64_to_int32(v.d))
	case .i16, .u16: (cast(^u16)p)^ = u16(f64_to_int32(v.d))
	case .i32, .u32: (cast(^u32)p)^ = u32(f64_to_int32(v.d))
	case .f16: (cast(^u16)p)^ = f32_to_f16(v.d)
	case .f32: (cast(^f32)p)^ = f32(v.d)
	case .f64: (cast(^f64)p)^ = v.d
	case .i64, .u64: (cast(^u64)p)^ = v.b
	}
}

// The interpreter's element fast paths: a fixed-length view over a live buffer, an in-range index
// and a Number element type. Anything else answers false and takes the generic path.
@(private = "file")
ta_fast_ptr :: #force_inline proc(o: ^Object, idx: u32) -> (rawptr, Elem, bool) {
	ta, ok := o.data.(^Typed_Array)
	if !ok || ta.track_rab || idx >= u32(ta.length) {return nil, .u8, false}
	ab, ok2 := ta.buffer.data.(^Array_Buffer)
	if !ok2 || ab.data == nil {return nil, .u8, false}   // (detached, or its bytes are elsewhere: Buffer_Host)
	e := class_elem(o.class)
	es := elem_size[e]
	if ta.offset + ta.length * es > ab.byte_length {return nil, e, false}
	return &ab.data[ta.offset + int(idx) * es], e, true
}

ta_fast_get :: proc(o: ^Object, idx: u32) -> (Value, bool) {
	p, e, ok := ta_fast_ptr(o, idx)
	if !ok {return UNDEFINED, false}
	#partial switch e {
	case .u8c, .u8: return mk_int(i32((cast(^u8)p)^)), true
	case .i8: return mk_int(i32((cast(^i8)p)^)), true
	case .i16: return mk_int(i32((cast(^i16)p)^)), true
	case .u16: return mk_int(i32((cast(^u16)p)^)), true
	case .i32: return mk_int((cast(^i32)p)^), true
	case .u32: return mk_u32((cast(^u32)p)^), true
	case .f32: return mk_number(f64((cast(^f32)p)^)), true
	case .f64: return mk_number((cast(^f64)p)^), true
	}
	return UNDEFINED, false
}

ta_fast_set :: proc(o: ^Object, idx: u32, v: Value) -> bool {
	if v.tag != .int && v.tag != .float {return false}
	p, e, ok := ta_fast_ptr(o, idx)
	if !ok || elem_is_bigint(e) {return false}
	ta := o.data.(^Typed_Array)
	if ta.buffer.data.(^Array_Buffer).immutable {return false}
	if v.tag == .int {
		x := v.u.i
		#partial switch e {
		case .u8, .i8: (cast(^u8)p)^ = u8(x); return true
		case .u16, .i16: (cast(^u16)p)^ = u16(x); return true
		case .u32, .i32: (cast(^u32)p)^ = u32(x); return true
		case .f64: (cast(^f64)p)^ = f64(x); return true
		}
	}
	write_elem(e, p, Elem_Val{d = as_f64(v)})
	return true
}

typed_array_get_index :: proc(ctx: ^Context, o: ^Object, n: f64) -> (Value, bool) {
	if !f64_is_integer(n) || (n == 0 && math.sign_bit(n)) || n < 0 {return UNDEFINED, false}
	l := typed_array_length(ctx, o)
	if n >= f64(l) {return UNDEFINED, false}
	return view_read(ctx, o, int(n)), true
}

// [[Set]] of an element: -1 exception, 0 rejected (immutable buffer), 1 done (or out of bounds).
typed_array_put :: proc(ctx: ^Context, o: ^Object, n: f64, v: Value) -> int {
	if view_is_immutable(o) {
		_, ok := to_elem_val(ctx, class_elem(o.class), v)
		return ok ? 0 : -1
	}
	return typed_array_set_index(ctx, o, n, v) ? 1 : -1
}

typed_array_set_index :: proc(ctx: ^Context, o: ^Object, n: f64, v: Value) -> bool {
	e := class_elem(o.class)
	ev, ok := to_elem_val(ctx, e, v)
	if !ok {return false}
	if view_is_immutable(o) {return true}
	if !f64_is_integer(n) || (n == 0 && math.sign_bit(n)) || n < 0 {return true}
	if n >= f64(typed_array_length(ctx, o)) {return true}
	view_write(o, int(n), ev)
	return true
}

typed_array_define :: proc(ctx: ^Context, o: ^Object, a: Atom, n: f64, d: ^Prop_Desc, throw_flag: bool) -> int {
	_, valid := typed_array_get_index(ctx, o, n)
	ok := valid
	if ok {
		if .configurable in d.has && .configurable not_in d.flags {ok = false}
		if .enumerable in d.has && .enumerable not_in d.flags {ok = false}
		if desc_is_accessor(d) {ok = false}
		if .writable in d.has && .writable not_in d.flags {ok = false}
	}
	if !ok {
		if throw_flag {return throw_cannot_define(ctx, a)}
		return 0
	}
	if .value in d.has {
		if view_is_immutable(o) {
			cur, _ := typed_array_get_index(ctx, o, n)
			if !same_value(ctx, cur, d.value) {
				if throw_flag {return throw_cannot_define(ctx, a)}
				return 0
			}
			return 1
		}
		if !typed_array_set_index(ctx, o, n, d.value) {return -1}
	}
	return 1
}

// --- %TypedArray% helpers ---

// ValidateTypedArray: the object and its current length.
@(private = "file")
validate_ta :: proc(ctx: ^Context, v: Value) -> (^Object, int, bool) {
	if v.tag != .object || !is_typed_array_class(as_obj(v).class) {
		throw_type_error(ctx, "not a TypedArray")
		return nil, 0, false
	}
	o := as_obj(v)
	if typed_array_is_out_of_bounds(o) {
		throw_type_error(ctx, "TypedArray is detached or out of bounds")
		return nil, 0, false
	}
	return o, typed_array_length(ctx, o), true
}

// ValidateTypedArray for a method that writes: an immutable buffer is a TypeError (checked first).
@(private = "file")
validate_ta_mut :: proc(ctx: ^Context, v: Value) -> (^Object, int, bool) {
	if v.tag == .object && is_typed_array_class(as_obj(v).class) && view_is_immutable(as_obj(v)) {
		throw_immutable(ctx)
		return nil, 0, false
	}
	return validate_ta(ctx, v)
}

@(private = "file")
typed_array_alloc :: proc(ctx: ^Context, proto: ^Object, e: Elem, buffer: ^Object, offset: int, length: int, track: bool) -> ^Object {
	o := object_new_proto(ctx, proto, elem_class(e))
	ta := new(Typed_Array, rt_allocator(ctx.rt))
	ta.buffer = buffer
	ta.offset = offset
	ta.length = length
	ta.track_rab = track
	o.data = ta
	return o
}

// A fresh typed array of kind e with n zeroed elements.
@(private = "file")
typed_array_new_len :: proc(ctx: ^Context, proto: ^Object, e: Elem, n: i64) -> ^Object {
	bytes := n * i64(elem_size[e])
	buf := array_buffer_new(ctx, ctx.class_proto[.array_buffer], .array_buffer, bytes)
	if buf == nil {return nil}
	return typed_array_alloc(ctx, proto, e, buf, 0, int(n), false)
}

// TypedArrayCreateFromConstructor + validation (length check).
@(private = "file")
typed_array_create :: proc(ctx: ^Context, c: Value, args: []Value, min_len: i64 = -1, mutable := true) -> ^Object {
	nv := construct(ctx, c, args, c)
	if is_exception(nv) {return nil}
	o, l, ok := validate_ta(ctx, nv)
	if !ok {return nil}
	if mutable && view_is_immutable(o) {
		throw_immutable(ctx)
		return nil
	}
	if min_len >= 0 && i64(l) < min_len {
		throw_type_error(ctx, "TypedArray is too small")
		return nil
	}
	return o
}

// TypedArraySpeciesCreate
@(private = "file")
typed_array_species_create :: proc(ctx: ^Context, exemplar: ^Object, args: []Value, min_len: i64 = -1) -> ^Object {
	e := class_elem(exemplar.class)
	def := mk_obj(ctx.typed_array_ctors[e])
	c := species_constructor(ctx, mk_obj(exemplar), def)
	if is_exception(c) {return nil}
	r := typed_array_create(ctx, c, args, min_len)
	if r == nil {return nil}
	if elem_is_bigint(class_elem(r.class)) != elem_is_bigint(e) {
		throw_type_error(ctx, "TypedArray species has an incompatible content type")
		return nil
	}
	return r
}

// The concrete constructors (magic = Elem).
@(private = "file")
typed_array_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	e := Elem(magic)
	if is_undefined(nt) {return throw_type_error(ctx, "TypedArray constructor requires 'new'")}
	a0 := arg(args, 0)
	if a0.tag != .object {
		// ToIndex comes before the prototype lookup on newTarget
		n, ok2 := to_index(ctx, a0)
		if !ok2 {return EXCEPTION}
		proto, ok := proto_from_ctor(ctx, nt, elem_class(e))
		if !ok {return EXCEPTION}
		o := typed_array_new_len(ctx, proto, e, n)
		if o == nil {return EXCEPTION}
		return mk_obj(o)
	}
	proto, ok := proto_from_ctor(ctx, nt, elem_class(e))
	if !ok {return EXCEPTION}
	src := as_obj(a0)
	if src.class == .array_buffer || src.class == .shared_array_buffer {
		es := i64(elem_size[e])
		off, ok2 := to_index(ctx, arg(args, 1))
		if !ok2 {return EXCEPTION}
		if off % es != 0 {return throw_range_error(ctx, "start offset must be a multiple of the element size")}
		new_len: i64 = 0
		has_len := !is_undefined(arg(args, 2))
		if has_len {
			nl, ok3 := to_index(ctx, args[2])
			if !ok3 {return EXCEPTION}
			new_len = nl
		}
		ab := array_buffer_of(src)
		if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
		buf_len := i64(ab.byte_length)
		track := !has_len && ab.max_byte_length >= 0 && !ab.shared
		if !has_len && ab.max_byte_length >= 0 && ab.shared {track = true}
		length: i64
		if track {
			if off > buf_len {return throw_range_error(ctx, "start offset is out of bounds")}
			length = 0
		} else if !has_len {
			if buf_len % es != 0 {return throw_range_error(ctx, "buffer length must be a multiple of the element size")}
			nb := buf_len - off
			if nb < 0 {return throw_range_error(ctx, "start offset is out of bounds")}
			length = nb / es
		} else {
			if off + new_len * es > buf_len {return throw_range_error(ctx, "invalid typed array length")}
			length = new_len
		}
		o := typed_array_alloc(ctx, proto, e, src, int(off), int(length), track)
		return mk_obj(o)
	}
	if is_typed_array_class(src.class) {
		if typed_array_is_out_of_bounds(src) {return throw_type_error(ctx, "source TypedArray is detached or out of bounds")}
		se := class_elem(src.class)
		if elem_is_bigint(se) != elem_is_bigint(e) {return throw_type_error(ctx, "TypedArray content types are incompatible")}
		n := typed_array_length(ctx, src)
		o := typed_array_new_len(ctx, proto, e, i64(n))
		if o == nil {return EXCEPTION}
		host_pin_view(ctx, src)
		defer host_unpin_view(ctx, src, false)
		for i in 0 ..< n {
			v := read_elem(ctx, se, elem_ptr(src, i))
			ev, _ := to_elem_val(ctx, e, v)
			write_elem(e, elem_ptr(o, i), ev)
		}
		return mk_obj(o)
	}
	// iterable or array-like object
	using_it := get_method(ctx, a0, well_known_atom(.iterator))
	if is_exception(using_it) {return EXCEPTION}
	values := make([dynamic]Value, 0, 16, tmp(rt))
	if !is_undefined(using_it) {
		if src.class == .array && src.fast_array && is_fast_array_iteration(ctx, src) {
			ad := array_data(src)
			for i in 0 ..< int(ad.count) {append(&values, ad.values[i])}
		} else {
			it := call(ctx, using_it, a0, {})
			if is_exception(it) {return EXCEPTION}
			if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
			next := get(ctx, it, pa(.A_next))
			if is_exception(next) {return EXCEPTION}
			for {
				v, done, ok2 := iterator_step_value(ctx, it, next)
				if !ok2 {return EXCEPTION}
				if done {break}
				append(&values, v)
			}
		}
		o := typed_array_new_len(ctx, proto, e, i64(len(values)))
		if o == nil {return EXCEPTION}
		for v, i in values {
			if !typed_array_set_index(ctx, o, f64(i), v) {return EXCEPTION}
		}
		return mk_obj(o)
	}
	n, ok2 := length_of_array_like(ctx, a0)
	if !ok2 {return EXCEPTION}
	o := typed_array_new_len(ctx, proto, e, n)
	if o == nil {return EXCEPTION}
	for i in 0 ..< n {
		v := get_index(ctx, a0, i)
		if is_exception(v) {return EXCEPTION}
		if !typed_array_set_index(ctx, o, f64(i), v) {return EXCEPTION}
	}
	return mk_obj(o)
}

@(private = "file")
abstract_ta_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	return throw_type_error(ctx, "Abstract class TypedArray not directly constructable")
}

// %TypedArray%.from(0) / of(1)
@(private = "file")
ta_from :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if !is_constructor(this) {return throw_type_error(ctx, "not a constructor")}
	if magic == 1 {
		o := typed_array_create(ctx, this, {mk_int(i32(len(args)))}, i64(len(args)))
		if o == nil {return EXCEPTION}
		for v, i in args {
			if set_index(ctx, mk_obj(o), i64(i), v) < 0 {return EXCEPTION}
		}
		return mk_obj(o)
	}
	mapfn := arg(args, 1)
	this_arg := arg(args, 2)
	mapping := !is_undefined(mapfn)
	if mapping && !is_callable(mapfn) {return throw_type_error(ctx, "mapper is not a function")}
	src := arg(args, 0)
	using_it := get_method(ctx, src, well_known_atom(.iterator))
	if is_exception(using_it) {return EXCEPTION}
	values := make([dynamic]Value, 0, 16, tmp(rt))
	al := UNDEFINED
	n: i64
	if !is_undefined(using_it) {
		it := call(ctx, using_it, src, {})
		if is_exception(it) {return EXCEPTION}
		if it.tag != .object {return throw_type_error(ctx, "iterator must be an object")}
		next := get(ctx, it, pa(.A_next))
		if is_exception(next) {return EXCEPTION}
		for {
			v, done, ok := iterator_step_value(ctx, it, next)
			if !ok {return EXCEPTION}
			if done {break}
			append(&values, v)
		}
		n = i64(len(values))
	} else {
		al = to_object(ctx, src)
		if is_exception(al) {return EXCEPTION}
		ok: bool
		n, ok = length_of_array_like(ctx, al)
		if !ok {return EXCEPTION}
	}
	o := typed_array_create(ctx, this, {mk_i64(n)}, n)
	if o == nil {return EXCEPTION}
	for k in 0 ..< n {
		v: Value
		if is_undefined(al) {
			v = values[k]
		} else {
			v = get_index(ctx, al, k)
			if is_exception(v) {return EXCEPTION}
		}
		if mapping {
			v = call(ctx, mapfn, this_arg, {v, mk_i64(k)})
			if is_exception(v) {return EXCEPTION}
		}
		if set_index(ctx, mk_obj(o), k, v) < 0 {return EXCEPTION}
	}
	return mk_obj(o)
}

// buffer(0) byteLength(1) byteOffset(2) length(3)
@(private = "file")
ta_getter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object || !is_typed_array_class(as_obj(this).class) {return throw_type_error(ctx, "not a TypedArray")}
	o := as_obj(this)
	ta := typed_array_of(o)
	switch magic {
	case 0: return mk_obj(ta.buffer)
	case 1: return mk_i64(i64(typed_array_length(ctx, o) * elem_size[class_elem(o.class)]))
	case 2:
		if typed_array_is_out_of_bounds(o) {return mk_int(0)}
		return mk_i64(i64(ta.offset))
	case 3: return mk_i64(i64(typed_array_length(ctx, o)))
	}
	return UNDEFINED
}

@(private = "file")
ta_tag :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object || !is_typed_array_class(as_obj(this).class) {return UNDEFINED}
	return new_string(ctx, elem_names[class_elem(as_obj(this).class)])
}

// generic element read for prototype methods (after validation)
@(private = "file")
ta_get :: #force_inline proc(ctx: ^Context, o: ^Object, i: int) -> Value {
	if i >= typed_array_length(ctx, o) {return UNDEFINED}
	return view_read(ctx, o, i)
}

@(private = "file")
ta_at :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	rel, ok2 := to_integer(ctx, arg(args, 0))
	if !ok2 {return EXCEPTION}
	k := rel >= 0 ? rel : f64(n) + rel
	if k < 0 || k >= f64(n) {return UNDEFINED}
	return ta_get(ctx, o, int(k))
}

// every(0) some(1) forEach(2) map(3) filter(4) find(5) findIndex(6) findLast(7) findLastIndex(8)
@(private = "file")
ta_iterate :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "callback is not a function")}
	this_arg := arg(args, 1)
	kept := make([dynamic]Value, 0, 8, tmp(rt))
	mapped: ^Object
	if magic == 3 {
		mapped = typed_array_species_create(ctx, o, {mk_int(i32(n))}, i64(n))
		if mapped == nil {return EXCEPTION}
	}
	for i in 0 ..< n {
		k := (magic == 7 || magic == 8) ? n - 1 - i : i
		v := ta_get(ctx, o, k)
		root(rt, v)
		r := call(ctx, cb, this_arg, {v, mk_int(i32(k)), this})
		if is_exception(r) {return EXCEPTION}
		switch magic {
		case 0: if !to_boolean(r) {return FALSE}
		case 1: if to_boolean(r) {return TRUE}
		case 3: if set_index(ctx, mk_obj(mapped), i64(k), r) < 0 {return EXCEPTION}
		case 4: if to_boolean(r) {append(&kept, v)}
		case 5, 7: if to_boolean(r) {return v}
		case 6, 8: if to_boolean(r) {return mk_int(i32(k))}
		}
	}
	switch magic {
	case 0: return TRUE
	case 1: return FALSE
	case 3: return mk_obj(mapped)
	case 4:
		a := typed_array_species_create(ctx, o, {mk_int(i32(len(kept)))}, i64(len(kept)))
		if a == nil {return EXCEPTION}
		for v, i in kept {
			if set_index(ctx, mk_obj(a), i64(i), v) < 0 {return EXCEPTION}
		}
		return mk_obj(a)
	case 5, 7: return UNDEFINED
	case 6, 8: return mk_int(-1)
	}
	return UNDEFINED
}

@(private = "file")
ta_copy_within :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta_mut(ctx, this)
	if !ok {return EXCEPTION}
	to, ok1 := relative_index(ctx, arg(args, 0), i64(n), 0)
	if !ok1 {return EXCEPTION}
	from, ok2 := relative_index(ctx, arg(args, 1), i64(n), 0)
	if !ok2 {return EXCEPTION}
	final, ok3 := relative_index(ctx, arg(args, 2), i64(n), i64(n))
	if !ok3 {return EXCEPTION}
	count := min(final - from, i64(n) - to)
	if count > 0 {
		if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached")}
		cur := typed_array_length(ctx, o)
		es := elem_size[class_elem(o.class)]
		count = min(count, i64(cur) - from, i64(cur) - to)
		if count > 0 {
			ta := typed_array_of(o)
			ab := array_buffer_of(ta.buffer)
			base := ta.offset
			src := base + int(from) * es
			dst := base + int(to) * es
			nb := int(count) * es
			host_pin(ctx.rt, ab, min(src, dst), max(src, dst) + nb)
			if dst < src {
				for i in 0 ..< nb {ab.data[dst + i] = ab.data[src + i]}
			} else {
				for i := nb - 1; i >= 0; i -= 1 {ab.data[dst + i] = ab.data[src + i]}
			}
			host_unpin(ctx.rt, ab, true)
		}
	}
	return this
}

@(private = "file")
ta_fill :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta_mut(ctx, this)
	if !ok {return EXCEPTION}
	e := class_elem(o.class)
	ev, ok1 := to_elem_val(ctx, e, arg(args, 0))
	if !ok1 {return EXCEPTION}
	start, ok2 := relative_index(ctx, arg(args, 1), i64(n), 0)
	if !ok2 {return EXCEPTION}
	end, ok3 := relative_index(ctx, arg(args, 2), i64(n), i64(n))
	if !ok3 {return EXCEPTION}
	if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached")}
	end = min(end, i64(typed_array_length(ctx, o)))
	if start < end {
		ta := typed_array_of(o)
		ab := array_buffer_of(ta.buffer)
		host_pin(ctx.rt, ab, ta.offset + int(start) * elem_size[e], ta.offset + int(end) * elem_size[e])
		for k in start ..< end {write_elem(e, elem_ptr(o, int(k)), ev)}
		host_unpin(ctx.rt, ab, true)
	}
	return this
}

// includes(0) indexOf(1) lastIndexOf(2)
@(private = "file")
ta_index_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	not_found := magic == 0 ? FALSE : mk_int(-1)
	if n == 0 {return not_found}
	target := arg(args, 0)
	if magic == 2 {
		k := i64(n) - 1
		if len(args) > 1 {
			d, ok2 := to_integer(ctx, args[1])
			if !ok2 {return EXCEPTION}
			if d == -INF {return not_found}
			k = d >= 0 ? i64(min(d, f64(n - 1))) : i64(f64(n) + d)
		}
		for ; k >= 0; k -= 1 {
			if int(k) >= typed_array_length(ctx, o) {continue}
			if strict_equals(ctx, ta_get(ctx, o, int(k)), target) {return mk_i64(k)}
		}
		return not_found
	}
	d, ok2 := to_integer(ctx, arg(args, 1))
	if !ok2 {return EXCEPTION}
	if d == INF {return not_found}
	k: i64 = d >= 0 ? i64(d) : max(0, i64(f64(n) + d))
	for ; k < i64(n); k += 1 {
		cur := typed_array_length(ctx, o)
		if int(k) >= cur {
			if magic == 0 && is_undefined(target) {return TRUE}
			continue
		}
		v := ta_get(ctx, o, int(k))
		if magic == 0 {
			if same_value_zero(ctx, v, target) {return TRUE}
		} else if strict_equals(ctx, v, target) {
			return mk_i64(k)
		}
	}
	return not_found
}

@(private = "file")
ta_join :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	sep := rt.char_strings[',']
	if !is_undefined(arg(args, 0)) {
		sep = to_str(ctx, args[0])
		if sep == nil {return EXCEPTION}
	}
	sb := sb_init(rt)
	for k in 0 ..< n {
		if k > 0 {sb_str(&sb, sep)}
		v := ta_get(ctx, o, k)
		if is_undefined(v) {continue}
		if magic == 1 {
			v = invoke(ctx, v, pa(.A_toLocaleString), {})
			if is_exception(v) {sb_destroy(&sb); return EXCEPTION}
		}
		s := to_str(ctx, v)
		if s == nil {sb_destroy(&sb); return EXCEPTION}
		sb_str(&sb, s)
	}
	return sb_finish_value(ctx, &sb)
}

// reduce(0) reduceRight(1)
@(private = "file")
ta_reduce :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	cb := arg(args, 0)
	if !is_callable(cb) {return throw_type_error(ctx, "reducer is not a function")}
	k := magic == 1 ? n - 1 : 0
	step := magic == 1 ? -1 : 1
	acc: Value
	if len(args) >= 2 {
		acc = args[1]
	} else {
		if n == 0 {return throw_type_error(ctx, "reduce of empty array with no initial value")}
		acc = ta_get(ctx, o, k)
		k += step
	}
	for k >= 0 && k < n {
		v := ta_get(ctx, o, k)
		acc = call(ctx, cb, UNDEFINED, {acc, v, mk_int(i32(k)), this})
		if is_exception(acc) {return EXCEPTION}
		k += step
	}
	return acc
}

@(private = "file")
ta_reverse :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta_mut(ctx, this)
	if !ok {return EXCEPTION}
	es := elem_size[class_elem(o.class)]
	host_pin_view(ctx, o)
	defer host_unpin_view(ctx, o, true)
	for i in 0 ..< n / 2 {
		a := cast([^]u8)elem_ptr(o, i)
		b := cast([^]u8)elem_ptr(o, n - 1 - i)
		for j in 0 ..< es {a[j], b[j] = b[j], a[j]}
	}
	return this
}

@(private = "file")
ta_set :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object || !is_typed_array_class(as_obj(this).class) {return throw_type_error(ctx, "not a TypedArray")}
	o := as_obj(this)
	if view_is_immutable(o) {return throw_immutable(ctx)}
	off, ok := to_integer(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	if off < 0 {return throw_range_error(ctx, "offset is out of bounds")}
	if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached or out of bounds")}
	tlen := typed_array_length(ctx, o)
	e := class_elem(o.class)
	src := arg(args, 0)
	if src.tag == .object && is_typed_array_class(as_obj(src).class) {
		so := as_obj(src)
		if typed_array_is_out_of_bounds(so) {return throw_type_error(ctx, "source TypedArray is detached or out of bounds")}
		se := class_elem(so.class)
		if elem_is_bigint(se) != elem_is_bigint(e) {return throw_type_error(ctx, "TypedArray content types are incompatible")}
		slen := typed_array_length(ctx, so)
		if off == INF || f64(slen) + off > f64(tlen) {return throw_range_error(ctx, "offset is out of bounds")}
		// between a host buffer and this engine's memory, same elements: one call for all of them (heap.set(bytes))
		sta, dta := typed_array_of(so), typed_array_of(o)
		sab, dab := array_buffer_of(sta.buffer), array_buffer_of(dta.buffer)
		es := elem_size[e]
		if se == e && (sab.host != nil) != (dab.host != nil) {
			if slen > 0 {
				if h := dab.host; h != nil {
					h.write(h.user, dta.offset + int(off) * es, &sab.data[sta.offset], slen * es)
				} else {
					sh := sab.host
					sh.read(sh.user, sta.offset, &dab.data[dta.offset + int(off) * es], slen * es)
				}
			}
			return UNDEFINED
		}
		host_pin_view(ctx, so)
		defer host_unpin_view(ctx, so, false)
		host_pin_view(ctx, o)
		defer host_unpin_view(ctx, o, true)
		vals := make([]Value, slen, tmp(rt))
		for i in 0 ..< slen {vals[i] = read_elem(ctx, se, elem_ptr(so, i))}
		for v, i in vals {
			ev, _ := to_elem_val(ctx, e, v)
			write_elem(e, elem_ptr(o, int(off) + i), ev)
		}
		return UNDEFINED
	}
	so := to_object(ctx, src)
	if is_exception(so) {return EXCEPTION}
	slen, ok2 := length_of_array_like(ctx, so)
	if !ok2 {return EXCEPTION}
	if off == INF || f64(slen) + off > f64(tlen) {return throw_range_error(ctx, "offset is out of bounds")}
	for i in 0 ..< slen {
		v := get_index(ctx, so, i)
		if is_exception(v) {return EXCEPTION}
		if !typed_array_set_index(ctx, o, off + f64(i), v) {return EXCEPTION}
	}
	return UNDEFINED
}

@(private = "file")
ta_slice :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	start, ok1 := relative_index(ctx, arg(args, 0), i64(n), 0)
	if !ok1 {return EXCEPTION}
	end, ok2 := relative_index(ctx, arg(args, 1), i64(n), i64(n))
	if !ok2 {return EXCEPTION}
	count := max(end - start, 0)
	a := typed_array_species_create(ctx, o, {mk_i64(count)}, count)
	if a == nil {return EXCEPTION}
	if count > 0 {
		if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached")}
		end = min(end, i64(typed_array_length(ctx, o)))
		if class_elem(a.class) == class_elem(o.class) {
			es := elem_size[class_elem(o.class)]
			host_pin_view(ctx, o)
			defer host_unpin_view(ctx, o, false)
			host_pin_view(ctx, a)
			defer host_unpin_view(ctx, a, true)
			for k in start ..< end {
				src := cast([^]u8)elem_ptr(o, int(k))
				dst := cast([^]u8)elem_ptr(a, int(k - start))
				for j in 0 ..< es {dst[j] = src[j]}
			}
		} else {
			for k in start ..< end {
				if set_index(ctx, mk_obj(a), k - start, ta_get(ctx, o, int(k))) < 0 {return EXCEPTION}
			}
		}
	}
	return mk_obj(a)
}

@(private = "file")
ta_sort_impl :: proc(ctx: ^Context, o: ^Object, n: int, cmp: Value) -> ([]Value, bool) {
	rt := ctx.rt
	vals := make([]Value, n, tmp(rt))
	for i in 0 ..< n {vals[i] = ta_get(ctx, o, i)}
	TS :: struct {
		ctx:   ^Context,
		cmp:   Value,
		error: bool,
	}
	sc := Sort_Ctx{ctx = ctx, cmp = cmp}
	if is_undefined(cmp) {
		// numeric order: -0 before +0, NaN last
		less :: proc(a, b: Value) -> bool {
			if a.tag == .bigint {return bigint.cmp(as_big(a).val, as_big(b).val) < 0}
			x, y := as_f64(a), as_f64(b)
			if math.is_nan(x) {return false}
			if math.is_nan(y) {return true}
			if x == 0 && y == 0 {return math.sign_bit(x) && !math.sign_bit(y)}
			return x < y
		}
		// stable insertion/merge via indices
		tbuf := make([]Value, n, tmp(rt))
		ms :: proc(a, t: []Value, less: proc(a, b: Value) -> bool) {
			if len(a) < 2 {return}
			mid := len(a) / 2
			ms(a[:mid], t[:mid], less)
			ms(a[mid:], t[mid:], less)
			copy(t, a)
			i, j, k := 0, mid, 0
			for i < mid && j < len(a) {
				if less(t[j], t[i]) {a[k] = t[j]; j += 1} else {a[k] = t[i]; i += 1}
				k += 1
			}
			for i < mid {a[k] = t[i]; i += 1; k += 1}
			for j < len(a) {a[k] = t[j]; j += 1; k += 1}
		}
		ms(vals, tbuf, less)
		return vals, true
	}
	tb := make([]Value, n, tmp(rt))
	merge_sort(&sc, vals, tb)
	if sc.error {return nil, false}
	return vals, true
}

@(private = "file")
ta_sort :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cmp := arg(args, 0)
	if !is_undefined(cmp) && !is_callable(cmp) {return throw_type_error(ctx, "comparator must be a function")}
	o, n, ok := validate_ta_mut(ctx, this)
	if !ok {return EXCEPTION}
	vals, ok2 := ta_sort_impl(ctx, o, n, cmp)
	if !ok2 {return EXCEPTION}
	e := class_elem(o.class)
	cur := typed_array_length(ctx, o)
	for v, i in vals {
		if i >= cur {break}
		ev, _ := to_elem_val(ctx, e, v)
		view_write(o, i, ev)
	}
	return this
}

@(private = "file")
ta_to_sorted :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cmp := arg(args, 0)
	if !is_undefined(cmp) && !is_callable(cmp) {return throw_type_error(ctx, "comparator must be a function")}
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	e := class_elem(o.class)
	a := typed_array_new_len(ctx, ctx.class_proto[elem_class(e)], e, i64(n))
	if a == nil {return EXCEPTION}
	vals, ok2 := ta_sort_impl(ctx, o, n, cmp)
	if !ok2 {return EXCEPTION}
	for v, i in vals {
		ev, _ := to_elem_val(ctx, e, v)
		write_elem(e, elem_ptr(a, i), ev)
	}
	return mk_obj(a)
}

@(private = "file")
ta_to_reversed :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	e := class_elem(o.class)
	a := typed_array_new_len(ctx, ctx.class_proto[elem_class(e)], e, i64(n))
	if a == nil {return EXCEPTION}
	es := elem_size[e]
	host_pin_view(ctx, o)
	defer host_unpin_view(ctx, o, false)
	for i in 0 ..< n {
		src := cast([^]u8)elem_ptr(o, n - 1 - i)
		dst := cast([^]u8)elem_ptr(a, i)
		for j in 0 ..< es {dst[j] = src[j]}
	}
	return mk_obj(a)
}

@(private = "file")
ta_with :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, n, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	e := class_elem(o.class)
	rel, ok1 := to_integer(ctx, arg(args, 0))
	if !ok1 {return EXCEPTION}
	idx := rel >= 0 ? rel : f64(n) + rel
	ev, ok2 := to_elem_val(ctx, e, arg(args, 1))
	if !ok2 {return EXCEPTION}
	if idx < 0 || idx >= f64(typed_array_length(ctx, o)) {return throw_range_error(ctx, "index out of range")}
	a := typed_array_new_len(ctx, ctx.class_proto[elem_class(e)], e, i64(n))
	if a == nil {return EXCEPTION}
	for i in 0 ..< n {
		if i == int(idx) {
			write_elem(e, elem_ptr(a, i), ev)
		} else {
			v := ta_get(ctx, o, i)
			w, _ := to_elem_val(ctx, e, v)
			write_elem(e, elem_ptr(a, i), w)
		}
	}
	return mk_obj(a)
}

@(private = "file")
ta_subarray :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if this.tag != .object || !is_typed_array_class(as_obj(this).class) {return throw_type_error(ctx, "not a TypedArray")}
	o := as_obj(this)
	ta := typed_array_of(o)
	n := i64(typed_array_length(ctx, o))
	start, ok1 := relative_index(ctx, arg(args, 0), n, 0)
	if !ok1 {return EXCEPTION}
	e := class_elem(o.class)
	es := i64(elem_size[e])
	begin_byte := i64(ta.offset) + start * es
	c := species_constructor(ctx, this, mk_obj(ctx.typed_array_ctors[e]))
	if is_exception(c) {return EXCEPTION}
	cargs: []Value
	if ta.track_rab && is_undefined(arg(args, 1)) {
		cargs = {mk_obj(ta.buffer), mk_i64(begin_byte)}
	} else {
		end, ok2 := relative_index(ctx, arg(args, 1), n, n)
		if !ok2 {return EXCEPTION}
		cargs = {mk_obj(ta.buffer), mk_i64(begin_byte), mk_i64(max(end - start, 0))}
	}
	r := typed_array_create(ctx, c, cargs, -1, false)
	if r == nil {return EXCEPTION}
	if elem_is_bigint(class_elem(r.class)) != elem_is_bigint(e) {return throw_type_error(ctx, "TypedArray species has an incompatible content type")}
	return mk_obj(r)
}

// keys(0) values(1) entries(2)
@(private = "file")
ta_iter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	_, _, ok := validate_ta(ctx, this)
	if !ok {return EXCEPTION}
	kinds := [3]Iter_Kind{.array_keys, .array_values, .array_entries}
	return create_array_iterator(ctx, this, kinds[magic])
}

// --- DataView ---

@(private = "file")
dataview_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	b := arg(args, 0)
	if b.tag != .object || (as_obj(b).class != .array_buffer && as_obj(b).class != .shared_array_buffer) {
		return throw_type_error(ctx, "DataView: argument is not an ArrayBuffer")
	}
	off, ok := to_index(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	ab := array_buffer_of(as_obj(b))
	if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
	buf_len := i64(ab.byte_length)
	if off > buf_len {return throw_range_error(ctx, "DataView offset is out of bounds")}
	track := false
	view_len: i64
	if is_undefined(arg(args, 2)) {
		if ab.max_byte_length >= 0 {track = true} else {view_len = buf_len - off}
	} else {
		l, ok2 := to_index(ctx, args[2])
		if !ok2 {return EXCEPTION}
		if off + l > buf_len {return throw_range_error(ctx, "DataView length is out of bounds")}
		view_len = l
	}
	proto, ok3 := proto_from_ctor(ctx, nt, .dataview)
	if !ok3 {return EXCEPTION}
	if ab.detached {return throw_type_error(ctx, "ArrayBuffer is detached")}
	buf_len = i64(ab.byte_length)
	if off > buf_len {return throw_range_error(ctx, "DataView offset is out of bounds")}
	if !is_undefined(arg(args, 2)) && off + view_len > buf_len {return throw_range_error(ctx, "DataView length is out of bounds")}
	o := object_new_proto(ctx, proto, .dataview)
	ta := new(Typed_Array, rt_allocator(ctx.rt))
	ta.buffer = as_obj(b)
	ta.offset = int(off)
	ta.length = int(view_len)
	ta.track_rab = track
	o.data = ta
	return mk_obj(o)
}

// buffer(0) byteLength(1) byteOffset(2)
@(private = "file")
dv_getter :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := this_class(ctx, this, .dataview, "DataView")
	if o == nil {return EXCEPTION}
	ta := typed_array_of(o)
	switch magic {
	case 0: return mk_obj(ta.buffer)
	case 1:
		if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "DataView is detached or out of bounds")}
		return mk_i64(i64(typed_array_length(ctx, o)))
	case 2:
		if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "DataView is detached or out of bounds")}
		return mk_i64(i64(ta.offset))
	}
	return UNDEFINED
}

// get/set: magic = elem | (is_set << 8)
@(private = "file")
dv_access :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := this_class(ctx, this, .dataview, "DataView")
	if o == nil {return EXCEPTION}
	e := Elem(magic & 0xff)
	is_set := magic & 0x100 != 0
	if is_set && view_is_immutable(o) {return throw_immutable(ctx)}
	idx, ok := to_index(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	ev: Elem_Val
	le_arg := arg(args, 1)
	if is_set {
		ok2: bool
		ev, ok2 = to_elem_val(ctx, e, arg(args, 1))
		if !ok2 {return EXCEPTION}
		le_arg = arg(args, 2)
	}
	little := to_boolean(le_arg)
	if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "DataView is detached or out of bounds")}
	vl := typed_array_length(ctx, o)
	es := elem_size[e]
	if idx + i64(es) > i64(vl) {return throw_range_error(ctx, "DataView access is out of bounds")}
	ta := typed_array_of(o)
	ab := array_buffer_of(ta.buffer)
	tmpb: [8]u8
	if h := ab.host; h != nil {
		at := ta.offset + int(idx)
		wire: [8]u8
		if is_set {
			write_elem(e, &tmpb[0], ev)
			for i in 0 ..< es {wire[i] = little ? tmpb[i] : tmpb[es - 1 - i]}
			h.write(h.user, at, &wire[0], es)
			return UNDEFINED
		}
		h.read(h.user, at, &wire[0], es)
		for i in 0 ..< es {tmpb[i] = little ? wire[i] : wire[es - 1 - i]}
		return read_elem(ctx, e, &tmpb[0])
	}
	p := &ab.data[ta.offset + int(idx)]
	if is_set {
		write_elem(e, &tmpb[0], ev)
		for i in 0 ..< es {
			(cast([^]u8)p)[i] = little ? tmpb[i] : tmpb[es - 1 - i]
		}
		return UNDEFINED
	}
	for i in 0 ..< es {
		tmpb[i] = little ? (cast([^]u8)p)[i] : (cast([^]u8)p)[es - 1 - i]
	}
	return read_elem(ctx, e, &tmpb[0])
}

init_typed_array_builtins :: proc(ctx: ^Context) {
	rt := ctx.rt
	abp := ctx.class_proto[.array_buffer]
	abc := def_ctor(ctx, "ArrayBuffer", buffer_ctor, 1, abp, .constructor_only, i32(Class_ID.array_buffer))
	install_species(ctx, abc)
	def_method(ctx, abc, "isView", buffer_is_view, 1)
	def_getter(ctx, abp, atom_from_utf8(rt, "byteLength"), buffer_getter, nil, 0)
	def_getter(ctx, abp, pa(.A_maxByteLength), buffer_getter, nil, 1)
	def_getter(ctx, abp, atom_from_utf8(rt, "resizable"), buffer_getter, nil, 2)
	def_getter(ctx, abp, atom_from_utf8(rt, "detached"), buffer_getter, nil, 3)
	def_getter(ctx, abp, atom_from_utf8(rt, "immutable"), buffer_getter, nil, 4)
	def_method(ctx, abp, "resize", buffer_resize, 1, 0)
	def_method(ctx, abp, "slice", buffer_slice, 2, 0)
	def_method(ctx, abp, "sliceToImmutable", buffer_slice, 2, 2)
	def_method(ctx, abp, "transfer", buffer_transfer, 0, 0)
	def_method(ctx, abp, "transferToFixedLength", buffer_transfer, 0, 1)
	def_method(ctx, abp, "transferToImmutable", buffer_transfer, 0, 2)
	def_tag(ctx, abp, "ArrayBuffer")

	sbp := ctx.class_proto[.shared_array_buffer]
	sbc := def_ctor(ctx, "SharedArrayBuffer", buffer_ctor, 1, sbp, .constructor_only, i32(Class_ID.shared_array_buffer))
	install_species(ctx, sbc)
	def_getter(ctx, sbp, atom_from_utf8(rt, "byteLength"), buffer_getter, nil, 0x100)
	def_getter(ctx, sbp, pa(.A_maxByteLength), buffer_getter, nil, 0x101)
	def_getter(ctx, sbp, atom_from_utf8(rt, "growable"), buffer_getter, nil, 0x102)
	def_method(ctx, sbp, "grow", buffer_resize, 1, 1)
	def_method(ctx, sbp, "slice", buffer_slice, 2, 1)
	def_tag(ctx, sbp, "SharedArrayBuffer")

	tap := object_new_proto(ctx, ctx.class_proto[.object])
	tac := def_ctor(ctx, "TypedArray", abstract_ta_ctor, 0, tap, .constructor, 0, nil, false)
	ctx.typed_array_ctor = tac
	install_species(ctx, tac)
	def_method(ctx, tac, "from", ta_from, 1, 0)
	def_method(ctx, tac, "of", ta_from, 0, 1)
	def_getter(ctx, tap, atom_from_utf8(rt, "buffer"), ta_getter, nil, 0)
	def_getter(ctx, tap, atom_from_utf8(rt, "byteLength"), ta_getter, nil, 1)
	def_getter(ctx, tap, atom_from_utf8(rt, "byteOffset"), ta_getter, nil, 2)
	def_getter(ctx, tap, pa(.A_length), ta_getter, nil, 3)
	def_getter(ctx, tap, well_known_atom(.to_string_tag), ta_tag)
	def_method(ctx, tap, "at", ta_at, 1)
	def_method(ctx, tap, "copyWithin", ta_copy_within, 2)
	def_method(ctx, tap, "entries", ta_iter, 0, 2)
	def_method(ctx, tap, "every", ta_iterate, 1, 0)
	def_method(ctx, tap, "fill", ta_fill, 1)
	def_method(ctx, tap, "filter", ta_iterate, 1, 4)
	def_method(ctx, tap, "find", ta_iterate, 1, 5)
	def_method(ctx, tap, "findIndex", ta_iterate, 1, 6)
	def_method(ctx, tap, "findLast", ta_iterate, 1, 7)
	def_method(ctx, tap, "findLastIndex", ta_iterate, 1, 8)
	def_method(ctx, tap, "forEach", ta_iterate, 1, 2)
	def_method(ctx, tap, "includes", ta_index_of, 1, 0)
	def_method(ctx, tap, "indexOf", ta_index_of, 1, 1)
	def_method(ctx, tap, "join", ta_join, 1, 0)
	def_method(ctx, tap, "keys", ta_iter, 0, 0)
	def_method(ctx, tap, "lastIndexOf", ta_index_of, 1, 2)
	def_method(ctx, tap, "map", ta_iterate, 1, 3)
	def_method(ctx, tap, "reduce", ta_reduce, 1, 0)
	def_method(ctx, tap, "reduceRight", ta_reduce, 1, 1)
	def_method(ctx, tap, "reverse", ta_reverse, 0)
	def_method(ctx, tap, "set", ta_set, 1)
	def_method(ctx, tap, "slice", ta_slice, 2)
	def_method(ctx, tap, "some", ta_iterate, 1, 1)
	def_method(ctx, tap, "sort", ta_sort, 1)
	def_method(ctx, tap, "subarray", ta_subarray, 2)
	def_method(ctx, tap, "toLocaleString", ta_join, 0, 1)
	def_method(ctx, tap, "toReversed", ta_to_reversed, 0)
	def_method(ctx, tap, "toSorted", ta_to_sorted, 1)
	def_method(ctx, tap, "with", ta_with, 2)
	tv := def_method(ctx, tap, "values", ta_iter, 0, 1)
	define_value(ctx, tap, well_known_atom(.iterator), mk_obj(tv), CW)
	ats := get(ctx, mk_obj(ctx.class_proto[.array]), pa(.A_toString))
	define_value(ctx, tap, pa(.A_toString), ats, CW)

	for e in Elem {
		p := object_new_proto(ctx, tap)
		ctx.class_proto[elem_class(e)] = p
		c := def_ctor(ctx, elem_names[e], typed_array_ctor, 3, p, .constructor, i32(e), tac)
		ctx.typed_array_ctors[e] = c
		bpe := mk_int(i32(elem_size[e]))
		def_value(ctx, c, "BYTES_PER_ELEMENT", bpe, {})
		def_value(ctx, p, "BYTES_PER_ELEMENT", bpe, {})
	}
	init_uint8_base64(ctx)

	dvp := ctx.class_proto[.dataview]
	def_ctor(ctx, "DataView", dataview_ctor, 1, dvp, .constructor_only)
	def_getter(ctx, dvp, atom_from_utf8(rt, "buffer"), dv_getter, nil, 0)
	def_getter(ctx, dvp, atom_from_utf8(rt, "byteLength"), dv_getter, nil, 1)
	def_getter(ctx, dvp, atom_from_utf8(rt, "byteOffset"), dv_getter, nil, 2)
	names := [Elem]string{.u8c = "", .i8 = "Int8", .u8 = "Uint8", .i16 = "Int16", .u16 = "Uint16", .i32 = "Int32", .u32 = "Uint32", .i64 = "BigInt64", .u64 = "BigUint64", .f16 = "Float16", .f32 = "Float32", .f64 = "Float64"}
	for e in Elem {
		if e == .u8c {continue}
		def_method(ctx, dvp, cat(ctx, "get", names[e]), dv_access, 1, i32(e))
		def_method(ctx, dvp, cat(ctx, "set", names[e]), dv_access, 2, i32(e) | 0x100)
	}
	def_tag(ctx, dvp, "DataView")
}

// --- Atomics ---

Atomic_Op :: enum i32 {add, and, compare_exchange, exchange, load, or, store, sub, xor}

@(private = "file")
atomics_lock: u32

@(private = "file")
atomics_validate :: proc(ctx: ^Context, v: Value, waitable: bool) -> (^Object, bool) {
	o, _, ok := validate_ta(ctx, v)
	if !ok {return nil, false}
	e := class_elem(o.class)
	if waitable {
		if e != .i32 && e != .i64 {
			throw_type_error(ctx, "Atomics.wait requires an Int32Array or BigInt64Array")
			return nil, false
		}
	} else if e == .f16 || e == .f32 || e == .f64 || e == .u8c {
		throw_type_error(ctx, "Atomics operations require an integer TypedArray")
		return nil, false
	}
	return o, true
}

@(private = "file")
atomics_index :: proc(ctx: ^Context, o: ^Object, v: Value) -> (int, bool) {
	// ValidateAtomicAccess reads the length before the index coercion, which may resize or detach
	length := typed_array_length(ctx, o)
	idx, ok := to_index(ctx, v)
	if !ok {return 0, false}
	if idx >= i64(length) {
		throw_range_error(ctx, "Atomics access index out of range")
		return 0, false
	}
	return int(idx), true
}

@(private = "file")
atomics_op :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	op := Atomic_Op(magic)
	o, ok := atomics_validate(ctx, arg(args, 0), false)
	if !ok {return EXCEPTION}
	if op != .load && view_is_immutable(o) {return throw_immutable(ctx)}
	idx, ok2 := atomics_index(ctx, o, arg(args, 1))
	if !ok2 {return EXCEPTION}
	e := class_elem(o.class)
	v1, v2: Elem_Val
	if op != .load {
		ok3: bool
		v1, ok3 = to_elem_val(ctx, e, arg(args, 2))
		if !ok3 {return EXCEPTION}
		if op == .compare_exchange {
			v2, ok3 = to_elem_val(ctx, e, arg(args, 3))
			if !ok3 {return EXCEPTION}
		}
	}
	if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached")}
	if idx >= typed_array_length(ctx, o) {return throw_range_error(ctx, "Atomics access index out of range")}
	host_pin_view(ctx, o)
	defer host_unpin_view(ctx, o, op != .load)
	p := elem_ptr(o, idx)
	// read-modify-write on memory other agents (threads) can reach is serialized by one process-wide lock
	if array_buffer_of(typed_array_of(o).buffer).shared {
		for intrinsics.atomic_exchange_explicit(&atomics_lock, 1, .Acquire) != 0 {intrinsics.cpu_relax()}
	}
	defer if array_buffer_of(typed_array_of(o).buffer).shared {intrinsics.atomic_store_explicit(&atomics_lock, 0, .Release)}
	old := read_elem(ctx, e, p)
	if op == .store {
		write_elem(e, p, v1)
		if elem_is_bigint(e) {return to_bigint(ctx, arg(args, 2))}
		d, _ := to_integer(ctx, mk_number(v1.d))
		return mk_number(d)
	}
	if op == .load {return old}
	// compute the new raw value on 64-bit integers
	raw_old := elem_raw(e, p)
	nv := elem_val_raw(e, v1)
	r: u64
	switch op {
	case .add: r = raw_old + nv
	case .sub: r = raw_old - nv
	case .and: r = raw_old & nv
	case .or: r = raw_old | nv
	case .xor: r = raw_old ~ nv
	case .exchange: r = nv
	case .compare_exchange:
		expected := elem_val_raw(e, v1)
		repl := elem_val_raw(e, v2)
		mask := elem_mask(e)
		if raw_old & mask == expected & mask {r = repl} else {r = raw_old}
	case .load, .store:
	}
	elem_store_raw(e, p, r)
	return old
}

@(private = "file")
elem_mask :: proc(e: Elem) -> u64 {
	switch elem_size[e] {
	case 1: return 0xff
	case 2: return 0xffff
	case 4: return 0xffffffff
	}
	return ~u64(0)
}

@(private = "file")
elem_raw :: proc(e: Elem, p: rawptr) -> u64 {
	switch elem_size[e] {
	case 1: return u64((cast(^u8)p)^)
	case 2: return u64((cast(^u16)p)^)
	case 4: return u64((cast(^u32)p)^)
	}
	return (cast(^u64)p)^
}

@(private = "file")
elem_val_raw :: proc(e: Elem, v: Elem_Val) -> u64 {
	if elem_is_bigint(e) {return v.b}
	return u64(u32(f64_to_int32(v.d)))
}

@(private = "file")
elem_store_raw :: proc(e: Elem, p: rawptr, r: u64) {
	switch elem_size[e] {
	case 1: (cast(^u8)p)^ = u8(r)
	case 2: (cast(^u16)p)^ = u16(r)
	case 4: (cast(^u32)p)^ = u32(r)
	case: (cast(^u64)p)^ = r
	}
}

@(private = "file")
atomics_is_lock_free :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	n, ok := to_integer(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	return mk_bool(n == 1 || n == 2 || n == 4 || n == 8)
}

@(private = "file")
atomics_wait :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := atomics_validate(ctx, arg(args, 0), true)
	if !ok {return EXCEPTION}
	ta := typed_array_of(o)
	ab := array_buffer_of(ta.buffer)
	if !ab.shared {return throw_type_error(ctx, "Atomics.wait requires a shared buffer")}
	idx, ok2 := atomics_index(ctx, o, arg(args, 1))
	if !ok2 {return EXCEPTION}
	e := class_elem(o.class)
	v, ok3 := to_elem_val(ctx, e, arg(args, 2))
	if !ok3 {return EXCEPTION}
	t, ok4 := to_number(ctx, arg(args, 3))
	if !ok4 {return EXCEPTION}
	if t != t {t = math.inf_f64(1)} else if t < 0 {t = 0}
	if !ctx.rt.config.can_block {return throw_type_error(ctx, "Atomics.wait cannot block in this agent")}
	if array_buffer_of(typed_array_of(o).buffer).host != nil {return throw_type_error(ctx, "Atomics.wait requires a shared buffer")}
	addr := elem_ptr(o, idx)
	expected := elem_val_raw(e, v) & elem_mask(e)
	hook := ctx.rt.config.atomics_wait
	if hook == nil {
		// a lone agent: nobody can notify us, so an equal value means the wait times out
		if elem_raw(e, addr) & elem_mask(e) != expected {return new_string(ctx, "not-equal")}
		return new_string(ctx, "timed-out")
	}
	switch hook(ctx.rt.config.atomics_user, addr, elem_size[e], expected, t) {
	case .ok: return new_string(ctx, "ok")
	case .not_equal: return new_string(ctx, "not-equal")
	case .timed_out: return new_string(ctx, "timed-out")
	}
	return UNDEFINED
}

@(private = "file")
atomics_notify :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := atomics_validate(ctx, arg(args, 0), true)
	if !ok {return EXCEPTION}
	idx, ok2 := atomics_index(ctx, o, arg(args, 1))
	if !ok2 {return EXCEPTION}
	count := math.inf_f64(1)
	if !is_undefined(arg(args, 2)) {
		c, ok3 := to_integer(ctx, args[2])
		if !ok3 {return EXCEPTION}
		count = max(c, 0)
	}
	ta := typed_array_of(o)
	if !array_buffer_of(ta.buffer).shared {return mk_int(0)}
	hook := ctx.rt.config.atomics_notify
	if hook == nil || idx >= typed_array_length(ctx, o) {return mk_int(0)}
	return mk_int(i32(hook(ctx.rt.config.atomics_user, elem_ptr(o, idx), count)))
}

@(private = "file")
atomics_pause :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	n := arg(args, 0)
	if !is_undefined(n) {
		if !is_number(n) || !f64_is_integer(as_f64(n)) {return throw_type_error(ctx, "Atomics.pause argument must be an integral Number")}
	}
	return UNDEFINED
}

init_atomics_builtins :: proc(ctx: ^Context) {
	a := new_plain_object(ctx)
	def_value(ctx, ctx.global_obj, "Atomics", mk_obj(a))
	def_tag(ctx, a, "Atomics")
	names := [Atomic_Op]string{.add = "add", .and = "and", .compare_exchange = "compareExchange", .exchange = "exchange", .load = "load", .or = "or", .store = "store", .sub = "sub", .xor = "xor"}
	lens := [Atomic_Op]int{.add = 3, .and = 3, .compare_exchange = 4, .exchange = 3, .load = 2, .or = 3, .store = 3, .sub = 3, .xor = 3}
	for op in Atomic_Op {def_method(ctx, a, names[op], atomics_op, lens[op], i32(op))}
	def_method(ctx, a, "isLockFree", atomics_is_lock_free, 1)
	def_method(ctx, a, "wait", atomics_wait, 4)
	def_method(ctx, a, "notify", atomics_notify, 3)
	def_method(ctx, a, "pause", atomics_pause, 0)
}

// --- Uint8Array base64 / hex (uint8array-base64) ---

@(private = "file")
B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
@(private = "file")
B64URL := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

@(private = "file")
this_u8 :: proc(ctx: ^Context, v: Value) -> (^Object, bool) {
	if v.tag != .object || as_obj(v).class != .uint8_array {
		throw_type_error(ctx, "not a Uint8Array")
		return nil, false
	}
	return as_obj(v), true
}

@(private = "file")
get_option_string :: proc(ctx: ^Context, opts: Value, name: string, allowed: []string, def: string) -> (string, bool) {
	if is_undefined(opts) {return def, true}
	v := get(ctx, opts, atom_from_utf8(ctx.rt, name))
	if is_exception(v) {return "", false}
	if is_undefined(v) {return def, true}
	if v.tag != .string {
		throw_type_error(ctx, cat(ctx, "option '", name, "' must be a string"))
		return "", false
	}
	s := str_to_utf8(ctx.rt, as_str(v), tmp(ctx.rt))
	for a in allowed {if a == s {return s, true}}
	throw_type_error(ctx, cat(ctx, "invalid value for option '", name, "'"))
	return "", false
}

@(private = "file")
u8_to_base64 :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_u8(ctx, this)
	if !ok {return EXCEPTION}
	opts := arg(args, 0)
	if !is_undefined(opts) && opts.tag != .object {return throw_type_error(ctx, "options must be an object")}
	alpha, ok2 := get_option_string(ctx, opts, "alphabet", {"base64", "base64url"}, "base64")
	if !ok2 {return EXCEPTION}
	omit := false
	if !is_undefined(opts) {
		ov := get(ctx, opts, atom_from_utf8(ctx.rt, "omitPadding"))
		if is_exception(ov) {return EXCEPTION}
		omit = to_boolean(ov)
	}
	if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached")}
	n := typed_array_length(ctx, o)
	tbl := alpha == "base64" ? B64 : B64URL
	sb := sb_init(ctx.rt, n * 4 / 3 + 4)
	host_pin_view(ctx, o)
	defer host_unpin_view(ctx, o, false)
	b := cast([^]u8)elem_ptr(o, 0)
	for i := 0; i < n; i += 3 {
		x := u32(b[i]) << 16
		k := min(3, n - i)
		if k > 1 {x |= u32(b[i + 1]) << 8}
		if k > 2 {x |= u32(b[i + 2])}
		sb_unit(&sb, u16(tbl[(x >> 18) & 63]))
		sb_unit(&sb, u16(tbl[(x >> 12) & 63]))
		if k > 1 {sb_unit(&sb, u16(tbl[(x >> 6) & 63]))} else if !omit {sb_unit(&sb, '=')}
		if k > 2 {sb_unit(&sb, u16(tbl[x & 63]))} else if !omit {sb_unit(&sb, '=')}
	}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
u8_to_hex :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_u8(ctx, this)
	if !ok {return EXCEPTION}
	if typed_array_is_out_of_bounds(o) {return throw_type_error(ctx, "TypedArray is detached")}
	n := typed_array_length(ctx, o)
	HEX := "0123456789abcdef"
	sb := sb_init(ctx.rt, n * 2)
	host_pin_view(ctx, o)
	defer host_unpin_view(ctx, o, false)
	b := cast([^]u8)elem_ptr(o, 0)
	for i in 0 ..< n {
		sb_unit(&sb, u16(HEX[b[i] >> 4]))
		sb_unit(&sb, u16(HEX[b[i] & 15]))
	}
	return sb_finish_value(ctx, &sb)
}

// FromBase64: decode into `out` up to max_len bytes. Returns (read chars, written bytes, error kind 0 ok / 1 syntax).
@(private = "file")
decode_base64 :: proc(s: ^JS_String, url: bool, last_chunk: string, max_len: int, out: ^[dynamic]u8) -> (int, int, bool) {
	n := int(s.len)
	value := proc(c: u16, url: bool) -> int {
		switch c {
		case 'A' ..= 'Z': return int(c - 'A')
		case 'a' ..= 'z': return int(c - 'a') + 26
		case '0' ..= '9': return int(c - '0') + 52
		}
		if !url && c == '+' {return 62}
		if !url && c == '/' {return 63}
		if url && c == '-' {return 62}
		if url && c == '_' {return 63}
		return -1
	}
	is_ws :: proc(c: u16) -> bool {return c == 9 || c == 10 || c == 12 || c == 13 || c == 32}
	read := 0
	chunk: [4]int
	cl := 0
	chunk_start := 0
	if max_len == 0 {return 0, 0, true}
	i := 0
	for {
		for i < n && is_ws(str_at(s, i)) {i += 1}
		if i == n {
			if cl > 0 {
				if last_chunk == "stop-before-partial" {return read, len(out), true}
				if last_chunk == "strict" || cl == 1 {return read, len(out), false}
				// loose: decode partial
				if len(out) + cl - 1 > max_len {return read, len(out), true}
				x := chunk[0] << 18 | chunk[1] << 12 | (cl > 2 ? chunk[2] << 6 : 0)
				append(out, u8(x >> 16))
				if cl > 2 {append(out, u8(x >> 8))}
				read = n
			}
			return n, len(out), true
		}
		c := str_at(s, i)
		if c == '=' {
			if cl < 2 {return read, len(out), false}
			i += 1
			for i < n && is_ws(str_at(s, i)) {i += 1}
			if cl == 2 {
				if i == n {
					if last_chunk == "stop-before-partial" {return read, len(out), true}
					return read, len(out), false
				}
				if str_at(s, i) != '=' {return read, len(out), false}
				i += 1
				for i < n && is_ws(str_at(s, i)) {i += 1}
			}
			if i < n {return read, len(out), false}
			if last_chunk == "strict" {
				// the unused bits must be zero
				if cl == 2 && chunk[1] & 15 != 0 {return read, len(out), false}
				if cl == 3 && chunk[2] & 3 != 0 {return read, len(out), false}
			}
			if len(out) + cl - 1 > max_len {return read, len(out), true}
			x := chunk[0] << 18 | chunk[1] << 12 | (cl > 2 ? chunk[2] << 6 : 0)
			append(out, u8(x >> 16))
			if cl > 2 {append(out, u8(x >> 8))}
			return n, len(out), true
		}
		v := value(c, url)
		if v < 0 {return read, len(out), false}
		if cl == 0 {chunk_start = i}
		_ = chunk_start
		chunk[cl] = v
		cl += 1
		i += 1
		if cl == 4 {
			if len(out) + 3 > max_len {return read, len(out), true}
			x := chunk[0] << 18 | chunk[1] << 12 | chunk[2] << 6 | chunk[3]
			append(out, u8(x >> 16), u8(x >> 8), u8(x))
			cl = 0
			read = i
			if len(out) == max_len {return read, len(out), true}
		}
	}
}

// fromBase64(0) / setFromBase64(1)
@(private = "file")
u8_from_base64 :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	target: ^Object
	sarg := arg(args, 0)
	oarg := arg(args, 1)
	if magic == 1 {
		ok: bool
		target, ok = this_u8(ctx, this)
		if !ok {return EXCEPTION}
		if view_is_immutable(target) {return throw_immutable(ctx)}
	}
	if sarg.tag != .string {return throw_type_error(ctx, "argument must be a string")}
	if !is_undefined(oarg) && oarg.tag != .object {return throw_type_error(ctx, "options must be an object")}
	alpha, ok2 := get_option_string(ctx, oarg, "alphabet", {"base64", "base64url"}, "base64")
	if !ok2 {return EXCEPTION}
	last, ok3 := get_option_string(ctx, oarg, "lastChunkHandling", {"loose", "strict", "stop-before-partial"}, "loose")
	if !ok3 {return EXCEPTION}
	max_len := max(int)
	if magic == 1 {
		if typed_array_is_out_of_bounds(target) {return throw_type_error(ctx, "TypedArray is detached")}
		max_len = typed_array_length(ctx, target)
	}
	out := make([dynamic]u8, tmp(rt))
	s := str_flat(rt, as_str(sarg))
	read, written, good := decode_base64(s, alpha == "base64url", last, max_len, &out)
	if magic == 1 {
		host_pin_view(ctx, target)
		b := cast([^]u8)elem_ptr(target, 0)
		for i in 0 ..< written {b[i] = out[i]}
		host_unpin_view(ctx, target, true)
		if !good {return throw_syntax_error(ctx, "invalid base64 string")}
		r := new_plain_object(ctx)
		define_value(ctx, r, atom_from_utf8(rt, "read"), mk_int(i32(read)), CWE)
		define_value(ctx, r, atom_from_utf8(rt, "written"), mk_int(i32(written)), CWE)
		return mk_obj(r)
	}
	if !good {return throw_syntax_error(ctx, "invalid base64 string")}
	o := typed_array_new_len(ctx, ctx.class_proto[.uint8_array], .u8, i64(len(out)))
	if o == nil {return EXCEPTION}
	if len(out) > 0 {
		b := cast([^]u8)elem_ptr(o, 0)
		for x, i in out {b[i] = x}
	}
	return mk_obj(o)
}

// fromHex(0) / setFromHex(1)
@(private = "file")
u8_from_hex :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	target: ^Object
	if magic == 1 {
		ok: bool
		target, ok = this_u8(ctx, this)
		if !ok {return EXCEPTION}
		if view_is_immutable(target) {return throw_immutable(ctx)}
	}
	sarg := arg(args, 0)
	if sarg.tag != .string {return throw_type_error(ctx, "argument must be a string")}
	s := str_flat(rt, as_str(sarg))
	n := int(s.len)
	max_len := max(int)
	if magic == 1 {
		if typed_array_is_out_of_bounds(target) {return throw_type_error(ctx, "TypedArray is detached")}
		max_len = typed_array_length(ctx, target)
	}
	hx :: proc(c: u16) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a') + 10
		case 'A' ..= 'F': return int(c - 'A') + 10
		}
		return -1
	}
	out := make([dynamic]u8, tmp(rt))
	good := n % 2 == 0
	read := 0
	if good {
		for i := 0; i + 1 < n && len(out) < max_len; i += 2 {
			a, b := hx(str_at(s, i)), hx(str_at(s, i + 1))
			if a < 0 || b < 0 {good = false; break}
			append(&out, u8(a << 4 | b))
			read = i + 2
		}
	}
	if magic == 1 {
		host_pin_view(ctx, target)
		bp := cast([^]u8)elem_ptr(target, 0)
		for x, i in out {bp[i] = x}
		host_unpin_view(ctx, target, true)
		if !good {return throw_syntax_error(ctx, "invalid hex string")}
		r := new_plain_object(ctx)
		define_value(ctx, r, atom_from_utf8(rt, "read"), mk_int(i32(read)), CWE)
		define_value(ctx, r, atom_from_utf8(rt, "written"), mk_int(i32(len(out))), CWE)
		return mk_obj(r)
	}
	if !good {return throw_syntax_error(ctx, "invalid hex string")}
	o := typed_array_new_len(ctx, ctx.class_proto[.uint8_array], .u8, i64(len(out)))
	if o == nil {return EXCEPTION}
	if len(out) > 0 {
		bp := cast([^]u8)elem_ptr(o, 0)
		for x, i in out {bp[i] = x}
	}
	return mk_obj(o)
}

@(private = "file")
init_uint8_base64 :: proc(ctx: ^Context) {
	c := ctx.typed_array_ctors[Elem.u8]
	p := ctx.class_proto[.uint8_array]
	def_method(ctx, c, "fromBase64", u8_from_base64, 1, 0)
	def_method(ctx, c, "fromHex", u8_from_hex, 1, 0)
	def_method(ctx, p, "toBase64", u8_to_base64, 0)
	def_method(ctx, p, "toHex", u8_to_hex, 0)
	def_method(ctx, p, "setFromBase64", u8_from_base64, 1, 1)
	def_method(ctx, p, "setFromHex", u8_from_hex, 1, 1)
}

// ---- copies of a host buffer's bytes for the embedder's APIs (fetch a body, decode text: JS_GetArrayBufferRange) ----

// A copy lives until HOST_SNAPSHOTS more were made: the caller is one native call, which takes at most a few buffers.
host_snapshot :: proc(rt: ^Runtime, ab: ^Array_Buffer, offset, count: int) -> [^]u8 {
	h := ab.host
	off := clamp(offset, 0, ab.byte_length)
	n := clamp(count, 0, ab.byte_length - off)
	s := &rt.host_snapshots[rt.host_snapshot_next]
	rt.host_snapshot_next = (rt.host_snapshot_next + 1) % HOST_SNAPSHOTS
	if s.bytes != nil {mem_free(rt, s.bytes, s.cap)}
	s^ = {}
	s.cap = max(n, 1)
	s.bytes = cast([^]u8)mem_alloc(rt, s.cap)
	s.host, s.off, s.n = h, off, n
	if n > 0 {h.read(h.user, off, s.bytes, n)}
	return cast([^]u8)(uintptr(s.bytes) - uintptr(off))
}

host_snapshot_commit :: proc(rt: ^Runtime, p: [^]u8, n: int) {
	if n <= 0 {return}
	for &s in rt.host_snapshots {
		if s.host == nil || uintptr(p) < uintptr(s.bytes) || uintptr(p) + uintptr(n) > uintptr(s.bytes) + uintptr(s.n) {continue}
		s.host.write(s.host.user, s.off + int(uintptr(p) - uintptr(s.bytes)), p, n)
		return
	}
}
