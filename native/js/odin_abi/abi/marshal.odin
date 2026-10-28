// The serialised marshallers: one specialised body per parameter / result type, instantiated by the compiler from the
// static type (no typeid switch, no descriptor walked per call), plus the dictionary codec. Both ends use them: the
// host decodes arguments and encodes results, the guest (abi_guest) encodes arguments and decodes results, so the two
// cannot disagree.
//
// Dictionaries (WebIDL dictionaries: option bags, constructor inits) are structs. Odin can count a struct's fields at
// compile time but cannot name a field by index, so a dictionary is walked through its run-time type information:
// once per call, off the hot path (dictionaries are constructor and option arguments). Its fields may be any shape
// but a dictionary-of-pointer; in declaration order on the wire.
package abi

import "base:intrinsics"
import "base:runtime"

// How the host checks a span the guest serialised. `utf8` (nil = no check) validates a `string`.
Validate :: struct {
	utf8: proc "contextless" (s: []u8) -> bool,
}

// Where decoded values that need storage of their own live during one call (a dictionary, the elements of a slice
// of spans). The host passes the call's temporary allocator.
Decode_Env :: struct {
	val:   Validate,
	alloc: runtime.Allocator,
}

////////////////////////////////
// Decoding (host: arguments; guest: results)

// Decode one value of static type T from the reader. `bad` is set when a string fails its UTF-8 check (a Type error
// for the caller) or storage could not be had; a short buffer clears r.ok.
decode_arg :: proc(r: ^Reader, e: ^Decode_Env, $T: typeid) -> (value: T, bad: bool) {
	when T == string {
		span, _ := read_span(r)
		if !r.ok { return }
		if e.val.utf8 != nil && !e.val.utf8(span) { return "", true }
		return string(span), false
	} else when T == Bytes || T == []u8 {
		span, _ := read_span(r)
		return T(span), false
	} else when intrinsics.type_is_specialization_of(T, Owned) {
		return T{handle = cast(type_of(T{}.handle))read_scalar(r, u64)}, false
	} else when intrinsics.type_is_union(T) {
		#assert(intrinsics.type_union_variant_count(T) == 1, "abi: only Maybe(T) unions cross the boundary")
		INNER :: intrinsics.type_variant_type_of(T, 0)
		when INNER == string || INNER == Bytes || INNER == []u8 {
			span, absent := read_span(r)
			if !r.ok || absent { return nil, false }
			when INNER == string { if e.val.utf8 != nil && !e.val.utf8(span) { return nil, true } }
			return T(INNER(span)), false
		} else {
			if read_scalar(r, u8) == 0 { return nil, false }
			x, b := decode_arg(r, e, INNER)
			return T(x), b
		}
	} else when intrinsics.type_is_slice(T) {
		E :: intrinsics.type_elem_type(T)
		n := int(read_scalar(r, u32))
		if !r.ok || n > len(r.data) - r.pos { r.ok = false; return }   // every element takes at least one byte
		out, err := make([]E, n, e.alloc)
		if err != nil { return nil, true }
		for i in 0 ..< n {
			x, b := decode_arg(r, e, E)
			if b || !r.ok { return nil, b }
			out[i] = x
		}
		return out, false
	} else when intrinsics.type_is_struct(T) {
		v: T
		b := dict_decode(r, e, type_info_of(T), &v)
		return v, b
	} else when intrinsics.type_is_boolean(T) {
		return read_scalar(r, u8) != 0, false
	} else when intrinsics.type_is_enum(T) {
		return T(read_scalar(r, i32)), false
	} else {
		return read_scalar(r, T), false
	}
}

// Decode the parameters [i, n) of procedure type P into cells[i ...], one specialised step per parameter. Returns
// false (with bad set for a Type error) when an argument did not decode. Spans point into the reader's buffer.
decode_params :: proc(r: ^Reader, e: ^Decode_Env, c: ^Cells, $P: typeid, $i, $n: int, bad: ^bool) -> bool {
	when i < n {
		T :: intrinsics.type_proc_parameter_type(P, i)
		when intrinsics.type_is_struct(T) && !intrinsics.type_is_specialization_of(T, Owned) {
			// a dictionary is decoded into storage of its own; its cell holds the address
			p, err := new(T, e.alloc)
			if err != nil { bad^ = true; return false }
			if dict_decode(r, e, type_info_of(T), p) { bad^ = true; return false }
			c[i].a = u64(uintptr(p))
		} else {
			v, b := decode_arg(r, e, T)
			if b { bad^ = true; return false }
			cell_set(&c[i], v)
		}
		if !r.ok { return false }
		return decode_params(r, e, c, P, i + 1, n, bad)
	} else {
		return true
	}
}

////////////////////////////////
// Encoding (host: results; guest: arguments)

// Encode one value of static type T into the writer.
encode_ret :: proc(w: ^Writer, value: $T) {
	when T == string {
		write_span(w, transmute([]u8)value)
	} else when T == Bytes || T == []u8 {
		write_span(w, ([]u8)(value))
	} else when intrinsics.type_is_specialization_of(T, Owned) {
		write_scalar(w, u64(value.handle))
	} else when intrinsics.type_is_union(T) {
		INNER :: intrinsics.type_variant_type_of(T, 0)
		v, ok := value.?
		when INNER == string || INNER == Bytes || INNER == []u8 {
			if !ok { write_span(w, nil, absent = true) } else { encode_ret(w, v) }
		} else {
			write_scalar(w, u8(1) if ok else u8(0))
			if ok { encode_ret(w, v) }
		}
	} else when intrinsics.type_is_slice(T) {
		write_scalar(w, u32(len(value)))
		for x in value { encode_ret(w, x) }
	} else when intrinsics.type_is_struct(T) {
		v := value
		dict_encode(w, type_info_of(T), &v)
	} else when intrinsics.type_is_boolean(T) {
		write_scalar(w, u8(1) if value else u8(0))
	} else when intrinsics.type_is_enum(T) {
		write_scalar(w, i32(value))
	} else {
		write_scalar(w, value)
	}
}

////////////////////////////////
// Dictionaries (run-time type information, see the top of the file)

// The wire shape of one dictionary field, from its type information. Mirrors decode_arg / encode_ret exactly: the
// same bytes whether a value crosses as an argument or as a dictionary member.
@(private)
dict_decode :: proc(r: ^Reader, e: ^Decode_Env, ti: ^runtime.Type_Info, dst: rawptr) -> (bad: bool) {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if dict_decode(r, e, v.types[i], rawptr(uintptr(dst) + v.offsets[i])) { return true }
			if !r.ok { return false }
		}
		return false
	case runtime.Type_Info_String:
		span, _ := read_span(r)
		if !r.ok { return false }
		if e.val.utf8 != nil && !e.val.utf8(span) { return true }
		(^string)(dst)^ = string(span)
	case runtime.Type_Info_Slice:
		elem := runtime.type_info_base(v.elem)
		if _, is_u8 := elem.variant.(runtime.Type_Info_Integer); is_u8 && elem.size == 1 {
			span, _ := read_span(r)
			(^[]u8)(dst)^ = span
			return false
		}
		n := int(read_scalar(r, u32))
		if !r.ok || n > len(r.data) - r.pos { r.ok = false; return false }
		mem, err := runtime.mem_alloc(n * v.elem_size, v.elem.align, e.alloc)
		if err != nil { return true }
		for k in 0 ..< n {
			if dict_decode(r, e, v.elem, rawptr(uintptr(raw_data(mem)) + uintptr(k * v.elem_size))) { return true }
		}
		(^runtime.Raw_Slice)(dst)^ = {raw_data(mem), n}
	case runtime.Type_Info_Union:
		// Maybe(T): one variant, a nil tag 0 (the union's tag follows the variant's storage). A Maybe of a pointer has
		// no tag (the pointer is it): not a dictionary member (pointers do not cross).
		if len(v.variants) != 1 || v.tag_type == nil { return true }
		inner := runtime.type_info_base(v.variants[0])
		tag := rawptr(uintptr(dst) + v.tag_offset)
		if _, is_str := inner.variant.(runtime.Type_Info_String); is_str {
			span, absent := read_span(r)
			if !r.ok || absent { return false }
			if e.val.utf8 != nil && !e.val.utf8(span) { return true }
			(^string)(dst)^ = string(span)
			set_tag(tag, v.tag_type.size, 1)
			return false
		}
		if read_scalar(r, u8) == 0 { return false }
		if dict_decode(r, e, v.variants[0], dst) { return true }
		set_tag(tag, v.tag_type.size, 1)
	case runtime.Type_Info_Boolean:
		(^u8)(dst)^ = read_scalar(r, u8) != 0 ? 1 : 0
	case runtime.Type_Info_Enum:
		x := read_scalar(r, i32)
		copy_int(dst, base.size, i64(x))
	case runtime.Type_Info_Integer:
		switch base.size {
		case 8: (^u64)(dst)^ = read_scalar(r, u64)
		case:   copy_int(dst, base.size, i64(read_scalar(r, i32)))
		}
	case runtime.Type_Info_Float:
		if base.size == 8 { (^f64)(dst)^ = read_scalar(r, f64) } else { (^f32)(dst)^ = read_scalar(r, f32) }
	case:
		return true   // a pointer, a map...: not a dictionary member the boundary carries
	}
	return false
}

@(private)
dict_encode :: proc(w: ^Writer, ti: ^runtime.Type_Info, src: rawptr) {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) { dict_encode(w, v.types[i], rawptr(uintptr(src) + v.offsets[i])) }
	case runtime.Type_Info_String:
		write_span(w, transmute([]u8)(^string)(src)^)
	case runtime.Type_Info_Slice:
		elem := runtime.type_info_base(v.elem)
		s := (^runtime.Raw_Slice)(src)^
		if _, is_u8 := elem.variant.(runtime.Type_Info_Integer); is_u8 && elem.size == 1 {
			write_span(w, ([^]u8)(s.data)[:s.len])
			return
		}
		write_scalar(w, u32(s.len))
		for k in 0 ..< s.len { dict_encode(w, v.elem, rawptr(uintptr(s.data) + uintptr(k * v.elem_size))) }
	case runtime.Type_Info_Union:
		if len(v.variants) != 1 || v.tag_type == nil { return }
		inner := runtime.type_info_base(v.variants[0])
		present := get_tag(rawptr(uintptr(src) + v.tag_offset), v.tag_type.size) != 0
		if _, is_str := inner.variant.(runtime.Type_Info_String); is_str {
			if !present { write_span(w, nil, absent = true) } else { write_span(w, transmute([]u8)(^string)(src)^) }
			return
		}
		write_scalar(w, u8(1) if present else u8(0))
		if present { dict_encode(w, v.variants[0], src) }
	case runtime.Type_Info_Boolean:
		write_scalar(w, u8(1) if (^u8)(src)^ != 0 else u8(0))
	case runtime.Type_Info_Enum:
		write_scalar(w, i32(read_int(src, base.size)))
	case runtime.Type_Info_Integer:
		if base.size == 8 { write_scalar(w, (^u64)(src)^) } else { write_scalar(w, i32(read_int(src, base.size))) }
	case runtime.Type_Info_Float:
		if base.size == 8 { write_scalar(w, (^f64)(src)^) } else { write_scalar(w, (^f32)(src)^) }
	}
}

@(private)
copy_int :: proc "contextless" (dst: rawptr, size: int, x: i64) {
	switch size {
	case 1: (^i8)(dst)^ = i8(x)
	case 2: (^i16)(dst)^ = i16(x)
	case 4: (^i32)(dst)^ = i32(x)
	case:   (^i64)(dst)^ = x
	}
}

@(private)
read_int :: proc "contextless" (src: rawptr, size: int) -> i64 {
	switch size {
	case 1: return i64((^i8)(src)^)
	case 2: return i64((^i16)(src)^)
	case 4: return i64((^i32)(src)^)
	}
	return (^i64)(src)^
}

@(private) set_tag :: proc "contextless" (p: rawptr, size: int, v: u64) { copy_int(p, size, i64(v)) }
@(private) get_tag :: proc "contextless" (p: rawptr, size: int) -> u64 { return u64(read_int(p, size)) }
