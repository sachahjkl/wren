// Package abi_guest: the engine (wasm32) end of the serialised boundary. It imports the single `host_call` and turns a
// shared declaration (package api_decl) plus the call arguments into a request, reading back the result. Arguments
// are written with abi.encode_ret and results read with abi.decode_arg, the very procedures the host uses the other
// way round, so the two ends cannot disagree; a stub's own signature is checked against its declaration at compile
// time (abi.must_match).
//
// A guest built for another target (a test on the host) links a stub `host_call` (host_call.odin) that forwards to
// the in-process dispatcher; on wasm32 it is the real import.
package abi_guest

import "base:intrinsics"
import "../abi"

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

// A request: open it, write each argument in declaration order with `arg`, then `finish`.
begin :: #force_inline proc "contextless" () -> abi.Writer { return abi.writer_make(arg_buf[:]) }

// One argument of any shape the boundary carries (scalar, handle, Owned, string, bytes, Maybe, slice, dictionary).
arg :: abi.encode_ret

// Send the request for operation `op` of declaration D and decode its value result into r0 (a ^abi.Nothing when D
// returns no value). Returns the status: .None, the error D raised, or a transport failure. Strings of the result
// point into the result buffer (valid until the next call); slices and dictionaries take the context allocator.
finish :: proc(op: i32, w: ^abi.Writer, $D: typeid, r0: ^$R0) -> abi.Api_Error where intrinsics.type_is_proc(D) {
	NR :: intrinsics.type_proc_return_count(D)
	if w.need > len(w.data) { return .Invalid_Argument }   // the arguments did not fit arg_buf
	r, st := transport(op, w.pos)
	if st != .None { return st }
	when NR >= 1 {
		R0 :: intrinsics.type_proc_return_type(D, 0)
		when R0 != abi.Api_Error {
			e := abi.Decode_Env{alloc = context.allocator}
			v, _ := abi.decode_arg(&r, &e, R0)
			r0^ = v
		}
	}
	if !r.ok { return .Truncated }
	return .None
}
