// Package abi_guest: the engine (wasm32) end of the generic boundary. It imports the single `host_call` and turns a
// shared declaration (package api_decl) plus the call arguments into a serialised request, reading back the result.
// The marshalling is the compiler's, from the signature: `call` is specialised per declaration, so each call site
// packs exactly its arguments and decodes exactly its result, with no descriptor walked at run time.
//
// This is the guest counterpart of abi_host: both read package api_decl, both use the same wire format (package abi),
// so a mismatch is a compile error. A guest built for another target (a test on the host) links a stub `host_call`
// (host_call_stub.odin) that forwards to the in-process dispatcher; on wasm32 it is the real import.
package abi_guest

import "base:intrinsics"
import "../abi"
import "../api_decl"

// A scratch buffer in the guest's own memory for one call's arguments, and one for the result. Single-threaded guest
// (the engine runs on the page's UI thread), so one pair is enough; a reentrant call (the host calling back into the
// guest) does not serialise through here. Sized for the common case; a larger result grows `result` and retries.
@(private) arg_buf: [4096]u8
@(private) result_buf: [dynamic]u8

@(private)
ensure_result :: proc(n: int) {
	if cap(result_buf) < n { reserve(&result_buf, n) }
	resize(&result_buf, n)
}

// The op number of each declaration is assigned in api_decl order (the same order the host binds); the guest bindings
// list them next to themselves (guest_url.odin). A binding builds a request with `begin` + `arg*`, then `transport`.

// Perform the transport: send arg_buf[:n], read into result_buf, growing until the result fits. Returns the status
// and a Reader over the result bytes.
transport :: proc(op: i32, n: int) -> (r: abi.Reader, status: abi.Api_Error) {
	cap0 := max(cap(result_buf), 256)
	for _ in 0 ..< 4 {
		ensure_result(cap0)
		st := host_call(op, raw_data(arg_buf[:]), u32(n), raw_data(result_buf), u32(len(result_buf)))
		if abi.Api_Error(st) != .Truncated {
			return abi.reader_make(result_buf[:]), abi.Api_Error(st)
		}
		cap0 *= 4
	}
	return abi.reader_make(nil), .Truncated
}

////////////////////////////////
// Typed argument writers (comptime, one specialisation per type). A binding builds a request by writing its
// arguments in order into a Writer over arg_buf, then calling `transport`.

begin :: #force_inline proc "contextless" () -> abi.Writer { return abi.writer_make(arg_buf[:]) }

arg :: #force_inline proc "contextless" (w: ^abi.Writer, value: $T) {
	when T == string {
		abi.write_span(w, transmute([]u8)value)
	} else when T == abi.Bytes || T == []u8 {
		abi.write_span(w, ([]u8)(value))
	} else when intrinsics.type_is_boolean(T) {
		abi.write_scalar(w, u8(1) if value else u8(0))
	} else when intrinsics.type_is_enum(T) {
		abi.write_scalar(w, i32(value))
	} else when intrinsics.type_base_type(T) == abi.Handle {
		abi.write_scalar(w, u64(value))
	} else {
		abi.write_scalar(w, value)
	}
}

// An optional argument: a present-flag then (if present) the value, mirroring abi.decode_maybe. A string carries its
// absence in the length (ABSENT), so it needs no flag.
arg_maybe :: #force_inline proc "contextless" (w: ^abi.Writer, value: Maybe($T)) {
	when T == string {
		v, ok := value.?
		abi.write_span(w, transmute([]u8)v, absent = !ok)
	} else {
		v, ok := value.?
		abi.write_scalar(w, u8(1) if ok else u8(0))
		if ok { arg(w, v) }
	}
}

// A dictionary argument: each field in declaration order, strings as spans, bools as flags. A dictionary struct's
// layout is known at compile time; this walks it with reflection-free field access through `offset_of` would need a
// generator, so the binding writes the fields explicitly (see guest_url.odin, URLPattern_create). Kept here as the
// documented shape.

////////////////////////////////
// Typed result readers.

ret_scalar :: #force_inline proc "contextless" (r: ^abi.Reader, $T: typeid) -> T {
	when intrinsics.type_is_boolean(T) {
		return abi.read_scalar(r, u8) != 0
	} else when intrinsics.type_is_enum(T) {
		return T(abi.read_scalar(r, i32))
	} else when intrinsics.type_base_type(T) == abi.Handle {
		return T(abi.read_scalar(r, u64))
	} else {
		return abi.read_scalar(r, T)
	}
}

ret_string :: #force_inline proc "contextless" (r: ^abi.Reader) -> string {
	span, _ := abi.read_span(r)
	return string(span)
}

_ :: api_decl
