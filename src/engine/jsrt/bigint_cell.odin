package jsrt

// The heap wrapper for a BigInt value.
//
// The arithmetic lives in src/engine/bigint (sign-magnitude, checked against Python's arbitrary
// integers). The runtime only needs a reference-counted cell carrying one bigint.Int plus the usual
// GC header so a Value can point at it. BigInts never form cycles.

import "wb:engine/bigint"

JS_BigInt :: struct {
	using header: GC_Header,
	val:          bigint.Int,
}

bigint_create :: proc(rt: ^Runtime, val: bigint.Int) -> ^JS_BigInt {
	cell := gc_new_cell(rt, JS_BigInt, .bigint)
	if cell == nil {return nil}
	cell.val = val
	return cell
}

bigint_from_i64 :: proc(rt: ^Runtime, v: i64) -> ^JS_BigInt {
	context.allocator = rt.allocator
	return bigint_create(rt, bigint.from_i64(v))
}

bigint_destroy :: proc(rt: ^Runtime, cell: ^JS_BigInt) {
	context.allocator = rt.allocator
	bigint.destroy(&cell.val)
	gc_raw_free(rt, cell, size_of(JS_BigInt))
}
