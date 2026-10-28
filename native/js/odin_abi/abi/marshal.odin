// The comptime marshallers: one specialised body per parameter / result type, instantiated by the compiler from the
// static type. No run-time reflection on the hot path (no typeid switch, no descriptor table walked per call): each
// `decode_arg` / `encode_ret` is resolved at compile time to the right load, check and store for that exact type.
//
// These serve the serialised path (abi_host_call, abi_guest_call). The scalar path (abi_host_scalar) reuses the same
// per-type decisions through wire_of but reads the raw cell array instead of the buffer; it is written out there to
// keep every branch inlined and the deadline small.
package abi

import "base:intrinsics"

// How the host validates and decodes a span the guest serialised. A `string` is additionally checked for UTF-8; the
// host binding supplies these so the abi package needs no dependency on the page's utf-8 helper.
Validate :: struct {
	utf8: proc "contextless" (s: []u8) -> bool,   // nil = no check (a Bytes argument)
}

// Decode one argument of static type T from the reader. Returns the typed value and, for a string, whether it failed
// its UTF-8 check (a Type error for the caller). A handle arrives as its u64 and is returned as the distinct type.
decode_arg :: #force_inline proc "contextless" (r: ^Reader, v: Validate, $T: typeid) -> (value: T, bad_utf8: bool) {
	when T == string {
		span, _ := read_span(r)
		if !r.ok { return "", false }
		if v.utf8 != nil && !v.utf8(span) { return "", true }
		return string(span), false
	} else when T == Bytes || T == []u8 {
		span, _ := read_span(r)
		return (T)(span), false
	} else when intrinsics.type_is_boolean(T) {
		return read_scalar(r, u8) != 0, false
	} else when intrinsics.type_is_enum(T) {
		return T(read_scalar(r, i32)), false
	} else when intrinsics.type_is_float(T) {
		return read_scalar(r, T), false
	} else when intrinsics.type_is_union(T) {
		// Maybe(U): an optional argument (a union of one variant plus nil). A string optional carries its absence in
		// the length (ABSENT); any other is a u8 present-flag then the value. The inner type is the one variant.
		#assert(intrinsics.type_union_variant_count(T) == 1, "abi: only Maybe(T) unions are carried as arguments")
		INNER :: intrinsics.type_variant_type_of(T, 0)
		when INNER == string {
			span, absent := read_span(r)
			if !r.ok || absent { return nil, false }
			if v.utf8 != nil && !v.utf8(span) { return nil, true }
			return T(string(span)), false
		} else {
			present := read_scalar(r, u8) != 0
			if !present { return nil, false }
			x, bad := decode_arg(r, v, INNER)
			return T(x), bad
		}
	} else when intrinsics.type_base_type(T) == Handle {
		return T(read_scalar(r, u64)), false
	} else {
		return read_scalar(r, T), false
	}
}

// Encode one return value of static type T into the writer.
encode_ret :: #force_inline proc "contextless" (w: ^Writer, value: $T) {
	when T == string {
		write_span(w, transmute([]u8)value)
	} else when T == Bytes || T == []u8 {
		write_span(w, ([]u8)(value))
	} else when intrinsics.type_is_boolean(T) {
		write_scalar(w, u8(1) if value else u8(0))
	} else when intrinsics.type_is_enum(T) {
		write_scalar(w, i32(value))
	} else when intrinsics.type_base_type(T) == Handle {
		write_scalar(w, u64(value))
	} else {
		write_scalar(w, value)
	}
}

// Encoding the result of a call, by its return shape. Procedure overloading picks the form from the call's return
// tuple with no run-time test: void (no trailing value), a single value, an Api_Error alone, or (value, Api_Error).
// `status` carries the error out of band (the status cell / the scalar error cell); the value, if any, is serialised.

encode_returns_void :: #force_inline proc "contextless" (w: ^Writer, status: ^Api_Error) {}

encode_returns_err :: #force_inline proc "contextless" (w: ^Writer, status: ^Api_Error, err: Api_Error) {
	status^ = err
}

encode_returns_value :: #force_inline proc "contextless" (w: ^Writer, status: ^Api_Error, value: $T) {
	encode_ret(w, value)
}

encode_returns_value_err :: #force_inline proc "contextless" (w: ^Writer, status: ^Api_Error, value: $T, err: Api_Error) {
	status^ = err
	if err == .None { encode_ret(w, value) }
}

encode_returns :: proc {
	encode_returns_void,
	encode_returns_err,
	encode_returns_value,
	encode_returns_value_err,
}
