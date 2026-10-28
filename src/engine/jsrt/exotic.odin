package jsrt

// Exotic own-property interception.
//
// object_get / object_set call these before the ordinary shape lookup so exotic objects can present
// synthetic properties: Array "length" and index elements, String index access and "length", and (as
// they are built out) TypedArray elements and Proxy traps. Returning handled=false means "this object
// has no exotic opinion on this key; use the ordinary shape store".

// exotic_get_own: if handled, `value` is the result (an owned reference).
exotic_get_own :: proc(ctx: ^Context, obj: ^Object, key: Atom, receiver: Value) -> (value: Value, handled: bool) {
	#partial switch e in obj.exotic {
	case Array_Data:
		if key == pa(.A_length) {
			return mk_number(f64(e.length)), true
		}
		if atom_is_int(key) {
			idx := atom_to_int(key)
			if v, ok := array_get_index(obj, idx); ok {
				return value_dup(v), true
			}
		}
	case Primitive_Wrapper:
		if is_string(e.prim) {
			s := as_string(e.prim)
			if key == pa(.A_length) {
				return mk_number(f64(s.len)), true
			}
			if atom_is_int(key) {
				idx := atom_to_int(key)
				if idx < s.len {
					ch := string_char_at(ctx.rt, s, idx)
					res := string_alloc_wide(ctx.rt, 1)
					if res != nil {([^]u16)(res.data)[0] = ch}
					return mk_heap(.string, res), true
				}
			}
		}
	case Typed_Array_Data:
		if atom_is_int(key) {
			return typed_array_get(ctx, obj, atom_to_int(key)), true
		}
	}
	return UNDEFINED, false
}

// exotic_set_own: if handled, `ok` is whether the write succeeded (consumes val when it handles it).
exotic_set_own :: proc(ctx: ^Context, obj: ^Object, key: Atom, val: Value, receiver: Value) -> (handled: bool, ok: bool) {
	#partial switch &e in obj.exotic {
	case Array_Data:
		if key == pa(.A_length) {
			n, conv_ok := to_uint32(ctx, val)
			value_free(ctx.rt, val)
			if !conv_ok {return true, false}
			array_set_length(ctx.rt, obj, n)
			return true, true
		}
		if atom_is_int(key) {
			idx := atom_to_int(key)
			if array_set_index(ctx.rt, obj, idx, val) {
				return true, true
			}
			// Sparse fallthrough: store as a shape property, keeping length in sync.
			if idx + 1 > e.length {e.length = idx + 1}
			object_define_own(ctx, obj, key, val, {.writable, .enumerable, .configurable})
			return true, true
		}
	case Typed_Array_Data:
		if atom_is_int(key) {
			return true, typed_array_set(ctx, obj, atom_to_int(key), val)
		}
	}
	return false, false
}

// --- TypedArray element access (stubs that will be filled in the TypedArray wave) ---
//
// These are declared here so the exotic dispatch compiles; the storage reads/writes live in
// typedarray.odin once that wave lands. For now they read/write the backing ArrayBuffer bytes.

typed_array_get :: proc(ctx: ^Context, obj: ^Object, idx: u32) -> Value {
	ta := &obj.exotic.(Typed_Array_Data)
	if idx >= u32(ta.length) {return UNDEFINED}
	buf := as_object(ta.buffer)
	ab := &buf.exotic.(Array_Buffer_Data)
	if ab.detached {return UNDEFINED}
	return typed_array_read_element(ab.bytes, ta.byte_offset, ta.kind, idx)
}

typed_array_set :: proc(ctx: ^Context, obj: ^Object, idx: u32, val: Value) -> bool {
	ta := &obj.exotic.(Typed_Array_Data)
	n, ok := to_f64_val(ctx, val)
	value_free(ctx.rt, val)
	if !ok {return false}
	if idx >= u32(ta.length) {return true}
	buf := as_object(ta.buffer)
	ab := &buf.exotic.(Array_Buffer_Data)
	if ab.detached {return true}
	typed_array_write_element(ab.bytes, ta.byte_offset, ta.kind, idx, n)
	return true
}
