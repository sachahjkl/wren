package jsrt

// The host stack of a recursion that leaves the interpreter's loop (a call through a native, a Proxy trap, a getter...).
//
// Each such level takes the frames of interp_run and of the natives on the host stack. On Wasm that is two stacks: the
// shadow stack in linear memory (what the compiled code keeps in memory: about 4 KiB a level) and the machine's stack,
// which the code uses too (about 1.5 KiB a level) and whose end is a trap that takes the realm.
//
// The shadow stack linked with the module stays small: every page of its size is committed for each realm, touched or
// not (measured: 30 frames with a 64 MiB one, 2.4 GB of private bytes against 450 MB). A recursion that runs past it
// moves on to a block of the heap, a segment: the stack pointer is a global of the module, which the host moves
// (stack_move_hook). A call that finds no room (stack_exhausted) makes itself there and comes back, so only the calls
// that need one pay anything; the blocks go when the outermost call returns. Nothing keeps a pointer that the move
// breaks: the frames below stay where they are.
//
// What ends a recursion then is rt.config.max_stack_depth, and the machine's stack: the host says when too little of it
// is left (native_stack_low_hook), asked at each move and at each entry of the host into a running engine, where the
// frames of the browser make a level dearer. Between two questions a recursion cannot go past what the host keeps.
//
// A host without the hooks (the engine compiled natively, its tests and judges) has one stack: exhausted means RangeError.

import "base:runtime"

STACK_SEGMENT_BYTES :: 2 << 20
STACK_SEGMENT_ALIGN :: 16
// The most segments a recursion takes: max_stack_depth levels of the dearest kind fit.
STACK_SEGMENTS_MAX :: 64
// Under the point where a call stops, what a call may still need: the front-end's own budget (DEFAULT_COMPILE_STACK_BUDGET)
// and what reports an error, none of which looks at the limit.
STACK_SEGMENT_RESERVE :: 640 << 10
// Between that point and the one where a call moves on: for the natives that recurse by themselves (stack_out), so that a
// JSON.parse deep in a recursion does not fail because the next call would have moved.
STACK_SEGMENT_NATIVE_ROOM :: 256 << 10
// What a stack keeps under the point where calls move on.
STACK_SEGMENT_KEPT :: STACK_SEGMENT_RESERVE + STACK_SEGMENT_NATIVE_ROOM

// Moves the stack pointer to `sp`, returns where it was: 0 when it did not move. nil: the stack cannot move.
stack_move_hook: proc "contextless" (sp: uintptr) -> uintptr
// Has the machine's stack little left?
native_stack_low_hook: proc "contextless" () -> bool

// Where a call must not go on, and where a native must not.
stack_bounds_at :: proc(rt: ^Runtime, limit: uintptr) {
	rt.stack_bound = limit
	rt.stack_limit = limit
	rt.stack_floor = stack_move_hook != nil && limit > STACK_SEGMENT_NATIVE_ROOM ? limit - STACK_SEGMENT_NATIVE_ROOM : limit
}

// Too deep for a native that recurses without calling anything (the stack does not move for it).
stack_out :: #force_inline proc "contextless" (rt: ^Runtime) -> bool {
	marker: u8
	return uintptr(&marker) < rt.stack_floor
}

// An entry of the host into the running engine: its frames are on the machine's stack. Too little left: the next call
// finds out (call_on_more_stack), and an error is thrown there, at a point that can throw one.
stack_host_entered :: proc "contextless" (rt: ^Runtime) {
	if rt.host_depth > 0 && native_stack_low_hook != nil && native_stack_low_hook() {rt.stack_limit = max(uintptr)}
}

Stack_Segments :: struct {
	blocks: [STACK_SEGMENTS_MAX]rawptr,   // those taken so far, in order
	used:   int,                          // those running
}

// The next segment taken, for the caller to move to: stack_move_hook(top) where it makes the call, as a procedure leaving
// puts the stack pointer back where its own frame began. bound: for stack_segment_leave. False: there is none to take, for
// a RangeError.
stack_segment_enter :: proc(rt: ^Runtime) -> (top: uintptr, bound: uintptr, ok: bool) {
	if stack_move_hook == nil || native_stack_low_hook() {return}
	s := &rt.stack_segments
	if s.used == len(s.blocks) {return}
	if s.blocks[s.used] == nil {
		block, err := runtime.mem_alloc_non_zeroed(STACK_SEGMENT_BYTES, STACK_SEGMENT_ALIGN, rt.allocator)
		if err != nil {return}
		s.blocks[s.used] = raw_data(block)
	}
	low := uintptr(s.blocks[s.used])
	s.used += 1
	bound = rt.stack_bound
	stack_bounds_at(rt, low + STACK_SEGMENT_KEPT)
	return low + STACK_SEGMENT_BYTES, bound, true
}

stack_segment_leave :: proc(rt: ^Runtime, bound: uintptr) {
	rt.stack_segments.used -= 1
	stack_bounds_at(rt, bound)
}

// A call that found stack_exhausted, made where there is room: on this stack when only the machine's stack was the
// matter and no longer is, else on the next segment.
call_on_more_stack :: #force_no_inline proc(ctx: ^Context, f: Value, this: Value, new_target: Value, args: []Value, is_construct: bool) -> Value {
	rt := ctx.rt
	if rt.stack_limit != rt.stack_bound {
		if native_stack_low_hook() {return stack_overflow(ctx)}
		rt.stack_limit = rt.stack_bound
		if !stack_exhausted(rt) {return call_internal(ctx, f, this, new_target, args, is_construct)}
	}
	top, bound, ok := stack_segment_enter(rt)
	if !ok {return stack_overflow(ctx)}
	sp := stack_move_hook(top)
	if sp == 0 {
		stack_segment_leave(rt, bound)
		return stack_overflow(ctx)
	}
	r := call_internal(ctx, f, this, new_target, args, is_construct)
	stack_move_hook(sp)
	stack_segment_leave(rt, bound)
	return r
}

// The segments go when nothing runs on them.
stack_segments_free :: proc(rt: ^Runtime) {
	s := &rt.stack_segments
	if s.used > 0 {return}
	for &block in s.blocks {
		if block == nil {break}
		runtime.mem_free_with_size(block, STACK_SEGMENT_BYTES, rt.allocator)
		block = nil
	}
}
