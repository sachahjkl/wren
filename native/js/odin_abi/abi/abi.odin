// Package abi: the small generic boundary between the engine (a Wasm module, wasm32) and the host (Odin). It replaces
// the ~40 000 lines of generated C/Odin trampolines (src/tools/bindgen) with bridges the compiler instantiates from a
// shared set of Odin procedure signatures (package api_decl), one specialisation per signature, no code generator.
//
// Two shapes share one serialisation and one set of comptime marshallers:
//
//   * the fast scalar path (abi_host_scalar / abi_guest_scalar): the arguments stay separate Wasm scalars in the raw
//     cell array, decoded by a constant index. This is byte-for-byte the old ABI (handles i64, strings (ptr,len),
//     a result string into a (ptr,cap) buffer, a negative i32 for an Error) and compiles to the same machine code;
//     it carries the hot 0..N parameter paths.
//
//   * the serialised path (abi_host_call / abi_guest_call over one import `host_call`): every argument is packed into
//     the shared exchange buffer and read back by a cursor. One import serves every function, distinguished by an
//     operation number. It costs one extra copy per argument; it exists for the shapes the scalar path cannot carry
//     in a fixed cell array (long argument lists, growable results, future unions) and to keep the import table small.
//
// Both ends read the SAME signatures (package api_decl, compiled once for the host and once for wasm32), so a shape
// mismatch is a compile error, never a silent ABI drift. This package holds only the wire format and the marshalling;
// the host binds the implementations with abi_host (host.odin) and the guest calls them with abi_guest (guest.odin).
package abi

import "base:intrinsics"

// The status of a serialised call (host_call's result) and of the scalar error cell: 0, or a negative Api_Error.
// A positive value on the scalar string path is the length the result needs (see abi_host.put_size).
Status :: i32

// The error codes the boundary carries. They match web.Error / dom.Error exactly (same integer values) so that a
// code crossing the boundary needs no translation; the engine turns a non-zero code into the matching DOMException.
Api_Error :: enum i32 {
	None                    = 0,
	Invalid_Handle          = -1,
	Hierarchy               = -2,
	Not_Found               = -3,
	Invalid_Argument        = -4,
	Attached                = -5,
	Type                    = -10,
	Range                   = -11,
	Security                = -12,
	Quota                   = -13,
	Not_Supported           = -14,
	Syntax                  = -15,
	Abort                   = -16,
	Timeout                 = -17,
	Invalid_State           = -18,
	Data_Clone              = -19,
	Network                 = -20,
	Encoding                = -21,
	Index_Size              = -22,
	Not_Allowed             = -23,
	Invalid_Access          = -24,
	Invalid_Character       = -40,
	Namespace               = -41,
	In_Use_Attribute        = -42,
	Wrong_Document          = -43,
	Invalid_Node_Type       = -44,
	Invalid_Modification    = -45,
	No_Modification_Allowed = -46,
	// The serialised result did not fit the exchange buffer: the caller grows it and retries (abi_guest_call).
	Truncated               = -1000,
}

// A handle to a host object, as the guest sees it: an opaque u64. The shared declarations give each kind a distinct
// type (`URL :: distinct Handle`) so the compiler keeps a URL from being passed where a Blob is wanted. On the wire a
// handle is just an i64; the host-side binding knows the declared type and resolves it to the live object there.
Handle :: distinct u64

// `bytes`: an opaque byte span. A `string` is the same wire shape with a UTF-8 check added on the host.
Bytes :: distinct []u8

// A handle the callee hands over: the receiver owns it and must release it (WebIDL [Owned] / "the caller releases").
// On the wire it is the handle itself; the wrapper only makes the ownership part of the declaration's type, so a
// binding that drops an Owned result without releasing it reads wrong at the call site.
Owned :: struct($H: typeid) {
	handle: H,
}

// The absent marker of an optional string / bytes on the scalar path: a length of all ones (as today's ABI).
ABSENT :: max(u32)

// Whether T is a procedure type (used in `where` clauses of the bridges).
is_proc :: intrinsics.type_is_proc

// What a parameter or result type is to the boundary. Every bridge (host scalar, host serialised, guest) branches on
// this at compile time; a type outside the list is a compile error at the binding, never a silent ABI drift.
Shape :: enum u8 {
	Bool,        // bool: i32 0 / 1
	Int32,       // an integer of 4 bytes or less, an enum: i32
	Int64,       // an integer of 8 bytes, a handle (distinct Handle), Owned(handle): i64
	F32,
	F64,
	String,      // UTF-8: (ptr, len); serialised: u32 length + bytes
	Bytes,       // []u8 / Bytes: the same without the UTF-8 check
	Opt_Span,    // Maybe(string) / Maybe(Bytes): the length ABSENT when absent
	Opt_Scalar,  // Maybe(T) of a scalar: a present flag, then the value
	Slice,       // []T (T not u8): (ptr, count); serialised: u32 count + the elements
	Dict,        // a struct (a WebIDL dictionary): serialised only, its fields in declaration order
	Pointer,     // a pointer: the per-call context of a host implementation (never on the wire)
}

// The shape of T. A proc (Odin has no constant-returning procs), but its body is one `when` chain resolved per
// instantiation, so a call folds to a constant; the hot paths branch with the same `when` tests inline.
shape_of :: #force_inline proc "contextless" ($T: typeid) -> Shape {
	when T == string {
		return .String
	} else when T == Bytes || T == []u8 {
		return .Bytes
	} else when intrinsics.type_is_specialization_of(T, Owned) {
		return .Int64
	} else when intrinsics.type_is_union(T) {
		#assert(intrinsics.type_union_variant_count(T) == 1, "abi: only Maybe(T) unions cross the boundary")
		INNER :: intrinsics.type_variant_type_of(T, 0)
		when INNER == string || INNER == Bytes || INNER == []u8 { return .Opt_Span } else { return .Opt_Scalar }
	} else when intrinsics.type_is_slice(T) {
		return .Slice
	} else when intrinsics.type_is_struct(T) {
		return .Dict
	} else when intrinsics.type_is_pointer(T) {
		return .Pointer
	} else when intrinsics.type_is_boolean(T) {
		return .Bool
	} else when intrinsics.type_is_enum(T) {
		return .Int32
	} else when intrinsics.type_is_float(T) {
		return size_of(T) == 8 ? .F64 : .F32
	} else when intrinsics.type_is_integer(T) {
		return size_of(T) == 8 ? .Int64 : .Int32
	} else {
		#panic("abi: a parameter or result type this boundary cannot carry")
	}
}

