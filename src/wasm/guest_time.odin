package wasm

import "core:time"
import "wb:base"

// Time spent in guest code on the calling thread: from the outermost host -> guest call to its return, whatever the
// instance (a guest calling the host which calls another guest counts once). Off by default; a thread turns it on for
// itself (the browser's UI thread, for its frame statistics). Two clock reads per outermost call when on.

@(private)
Guest_Clock :: struct {
	on:    bool,
	depth: int,
	start: time.Tick,
	ns:    i64,     // total since the clock was turned on
	calls: i64,     // outermost calls since then
}

@(private, thread_local)
guest_clock: Guest_Clock

// Starts or stops measuring this thread's guest calls (the totals are kept).
guest_timing :: proc(on: bool) { guest_clock.on = on }

// Nanoseconds spent in guest code and outermost calls on this thread since measuring began (monotonic: take
// differences).
guest_time :: proc() -> (ns: i64, calls: i64) { return guest_clock.ns, guest_clock.calls }

// WREN_SPANS: the outermost calls of this thread, by the export they call.
@(private, thread_local) guest_span_depth: int
@(private, thread_local) guest_span_start: i64
@(private, thread_local) guest_span_label: string

@(private)
guest_span_enter :: #force_inline proc() {
	if !base.spans_enabled() { return }
	if guest_span_depth == 0 { guest_span_start = base.span_now() }
	guest_span_depth += 1
}

@(private)
guest_span_leave :: #force_inline proc() {
	if !base.spans_enabled() || guest_span_depth == 0 { return }
	guest_span_depth -= 1
	if guest_span_depth == 0 { base.span_add(.Guest, guest_span_start, guest_span_label) }
}

@(private)
guest_clock_enter :: #force_inline proc() {
	c := &guest_clock
	if !c.on { return }
	if c.depth == 0 { c.start = time.tick_now() }
	c.depth += 1
}

@(private)
guest_clock_leave :: #force_inline proc() {
	c := &guest_clock
	if c.depth == 0 { return }   // turned on during the call
	c.depth -= 1
	if c.depth == 0 {
		c.ns += i64(time.tick_since(c.start))
		c.calls += 1
	}
}
