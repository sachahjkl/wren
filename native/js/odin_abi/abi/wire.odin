package abi

import "base:intrinsics"

// The serialised wire format of the `host_call` path. One call packs its arguments into a byte buffer the guest owns
// (the shared exchange buffer: guest-side, so the host reads it through the validated memory window, never writes
// outside ret_cap). The layout is the arguments in declaration order, each self-describing by its static type:
//
//   * a fixed scalar (i32 / i64 / f64, a bool as i32, an enum as i32, a handle as i64): little-endian, its own width;
//   * a string or bytes: a u32 length then that many bytes (an absent optional: length == ABSENT, no bytes);
//   * an optional present scalar is preceded by a u8 flag.
//
// The result is written the same way into ret_ptr (capacity ret_cap): the status cell first, then the return values.
// Everything is little-endian, which is the only byte order wasm32 and the host (x86-64 today) use; no padding, so a
// guest and a host built from the same declarations agree without a schema exchange.

// A read cursor over a serialised argument (or result) buffer.
Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,   // cleared once a read ran past the end: the caller turns this into a trap / Truncated
}

reader_make :: #force_inline proc "contextless" (data: []u8) -> Reader {
	return Reader{data = data, pos = 0, ok = true}
}

@(private)
read_bytes_raw :: #force_inline proc "contextless" (r: ^Reader, n: int) -> []u8 {
	if n < 0 || r.pos + n > len(r.data) { r.ok = false; return nil }
	s := r.data[r.pos:r.pos + n]
	r.pos += n
	return s
}

// A fixed scalar of static type T.
read_scalar :: #force_inline proc "contextless" (r: ^Reader, $T: typeid) -> T {
	s := read_bytes_raw(r, size_of(T))
	if !r.ok { return T{} }
	return intrinsics.unaligned_load((^T)(raw_data(s)))
}

// A length-prefixed span. For an optional the length may be ABSENT.
read_span :: #force_inline proc "contextless" (r: ^Reader) -> (span: []u8, absent: bool) {
	n := read_scalar(r, u32)
	if !r.ok { return nil, false }
	if n == ABSENT { return nil, true }
	return read_bytes_raw(r, int(n)), false
}

// A write cursor over a result (or argument) buffer.
Writer :: struct {
	data: []u8,
	pos:  int,
	need: int,   // bytes the content wanted, whether or not it fit: a caller grows to `need` and retries
}

writer_make :: #force_inline proc "contextless" (data: []u8) -> Writer {
	return Writer{data = data, pos = 0, need = 0}
}

@(private)
write_bytes_raw :: #force_inline proc "contextless" (w: ^Writer, src: []u8) {
	w.need += len(src)
	if w.pos + len(src) <= len(w.data) {
		copy(w.data[w.pos:], src)
		w.pos += len(src)
	}
}

write_scalar :: #force_inline proc "contextless" (w: ^Writer, value: $T) {
	v := value
	write_bytes_raw(w, (cast([^]u8)&v)[:size_of(T)])
}

write_span :: #force_inline proc "contextless" (w: ^Writer, span: []u8, absent := false) {
	if absent { write_scalar(w, ABSENT); return }
	write_scalar(w, u32(len(span)))
	write_bytes_raw(w, span)
}

// Whether the content fit the buffer (so far).
writer_fit :: #force_inline proc "contextless" (w: ^Writer) -> bool { return w.need <= len(w.data) }
