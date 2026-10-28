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

// The absent marker of an optional string / bytes on the scalar path: a length of all ones (as today's ABI).
ABSENT :: max(u32)

// Whether T is a procedure type (used in `where` clauses of the bridges).
is_proc :: intrinsics.type_is_proc

// The wire kind a parameter / result type maps to. The boundary only ever sees these.
Wire :: enum u8 {
	I32,       // bool, i32, enum, a 32-bit scalar
	I64,       // i64, u64, a handle
	F64,       // f64
	String,    // a UTF-8 string: (ptr,len) on the scalar path, len-prefixed bytes on the serialised path
	Bytes,     // an opaque byte span: same shapes as String without the UTF-8 check
}

// The wire kind of a static type. A compile error for anything the boundary does not carry (a pointer, a map...).
wire_of :: proc($T: typeid) -> Wire {
	when T == string {
		return .String
	} else when T == Bytes || T == []u8 {
		return .Bytes
	} else when intrinsics.type_is_boolean(T) {
		return .I32
	} else when intrinsics.type_is_enum(T) {
		return .I32
	} else when intrinsics.type_is_float(T) {
		return .F64
	} else when intrinsics.type_base_type(T) == Handle {
		// a handle kind (`distinct Handle`): a u64 on the wire, resolved by the host-side binding
		return .I64
	} else when intrinsics.type_is_integer(T) && size_of(T) == 8 {
		return .I64
	} else when intrinsics.type_is_integer(T) {
		return .I32
	} else {
		#panic("abi: a parameter or result type this boundary cannot carry")
	}
}
