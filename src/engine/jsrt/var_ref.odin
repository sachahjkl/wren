package jsrt

// Closure upvalue cells (JSVarRef).
//
// A Var_Ref is the boxed storage for a local variable that an inner function captures. While the
// enclosing frame is live the Var_Ref points into the frame's stack slot (`pvalue`); when the frame
// returns, the value is copied into the cell's own `value` and `pvalue` is redirected to it ("closed
// over"). Several closures can share one Var_Ref, so it is a refcounted GC cell and is treated as
// cyclic (a closure can capture a variable that holds the closure itself).

Var_Ref :: struct {
	using header: GC_Header,
	pvalue:       ^Value, // points at the live frame slot, or at &value once closed
	value:        Value,  // storage after the frame is gone
	is_closed:    bool,
}

var_ref_new :: proc(rt: ^Runtime, slot: ^Value) -> ^Var_Ref {
	vr := gc_new_cell(rt, Var_Ref, .var_ref)
	if vr == nil {return nil}
	vr.pvalue = slot
	vr.value = UNINITIALIZED
	return vr
}

var_ref_ref :: proc(vr: ^Var_Ref) -> ^Var_Ref {
	vr.ref_count += 1
	return vr
}

var_ref_unref :: proc(rt: ^Runtime, vr: ^Var_Ref) {
	vr.ref_count -= 1
	if vr.ref_count == 0 {gc_free_cell(rt, vr)}
}

// Close the cell: copy the current frame value into the cell and point at it. Called when the frame
// slot is about to disappear (function return, block scope exit via close_loc).
var_ref_close :: proc(vr: ^Var_Ref) {
	if vr.is_closed {return}
	vr.value = vr.pvalue^
	vr.pvalue = &vr.value
	vr.is_closed = true
}

var_ref_destroy :: proc(rt: ^Runtime, vr: ^Var_Ref) {
	if vr.is_closed {
		value_free(rt, vr.value)
	}
	gc_raw_free(rt, vr, size_of(Var_Ref))
}
