package page

// AbortController and AbortSignal (DOM Standard §3.1-3.2; import module "abort").
//
// A signal is a host object (and an EventTarget: "abort" is fired at it). Its reason is a (code, text) pair: the
// default is AbortError, AbortSignal.timeout() uses TimeoutError. Host consumers (fetch, streams...) register abort
// algorithms with signal_add_algorithm; they run before the event, in registration order. Dependent signals
// (AbortSignal.any) follow their sources as the specification describes: they are aborted with the source's reason, after
// the source's own algorithms ran and before its event... then their own steps run.

import "core:math"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"

Abort_Algorithm :: struct {
	fn:   proc(p: ^Page, data: u64, signal: u64),
	data: u64,
	id:   int,
}

Abort_Signal :: struct {
	page:        ^Page,
	self:        u64,
	aborted:     bool,
	reason_code: i64,
	reason:      string,              // owned
	algorithms:  [dynamic]Abort_Algorithm,
	next_algo:   int,
	dependent:   bool,
	dependents:  [dynamic]u64,        // signals that follow this one (any())
	sources:     [dynamic]u64,        // what a dependent signal follows
	timer:       base.Handle,         // AbortSignal.timeout()
}

Abort_Controller :: struct { signal: u64 }

ABORT_REASON  :: "AbortError: signal is aborted without reason"
TIMEOUT_REASON :: "TimeoutError: signal timed out"

abort_signal_vt := Object_VTable{
	name = "AbortSignal",
	destroy = proc(p: ^Page, data: rawptr) {
		s := (^Abort_Signal)(data)
		if s.timer != base.NIL_HANDLE && !p.closed { host.clear_timer(p.loop, s.timer) }
		delete(s.reason)
		delete(s.algorithms)
		delete(s.dependents)
		delete(s.sources)
		free(s)
	},
}

abort_controller_vt := Object_VTable{
	name = "AbortController",
	destroy = proc(p: ^Page, data: rawptr) { free((^Abort_Controller)(data)) },
}

signal_get :: proc(p: ^Page, h: u64) -> ^Abort_Signal { return (^Abort_Signal)(object_data(p, h, &abort_signal_vt)) }

signal_create :: proc(p: ^Page, owner: u32) -> u64 {
	s := new(Abort_Signal)
	s.page = p
	s.self = object_create(p, &abort_signal_vt, s, owner)
	return s.self
}

// Registers a host reaction to the abort; returns an id for signal_remove_algorithm (0 when the handle is not a signal).
signal_add_algorithm :: proc(p: ^Page, h: u64, fn: proc(p: ^Page, data: u64, signal: u64), data: u64) -> int {
	s := signal_get(p, h)
	if s == nil { return 0 }
	s.next_algo += 1
	append(&s.algorithms, Abort_Algorithm{fn = fn, data = data, id = s.next_algo})
	return s.next_algo
}

signal_remove_algorithm :: proc(p: ^Page, h: u64, id: int) {
	s := signal_get(p, h)
	if s == nil { return }
	for a, i in s.algorithms { if a.id == id { ordered_remove(&s.algorithms, i); return } }
}

signal_aborted :: proc(p: ^Page, h: u64) -> (aborted: bool, code: i64, reason: string) {
	s := signal_get(p, h)
	if s == nil { return false, 0, "" }
	return s.aborted, s.reason_code, s.reason
}

// DOM "signal abort".
signal_abort :: proc(p: ^Page, h: u64, code: i64, reason: string) {
	s := signal_get(p, h)
	if s == nil || s.aborted { return }
	s.aborted, s.reason_code, s.reason = true, code, strings.clone(reason)
	to_abort := make([dynamic]u64, context.temp_allocator)
	for dh in s.dependents {
		d := signal_get(p, dh)
		if d == nil || d.aborted { continue }
		d.aborted, d.reason_code, d.reason = true, code, strings.clone(reason)
		append(&to_abort, dh)
	}
	run_abort_steps(p, h)
	for dh in to_abort {
		if p.closed { return }
		run_abort_steps(p, dh)
	}
}

@(private)
run_abort_steps :: proc(p: ^Page, h: u64) {
	s := signal_get(p, h)
	if s == nil { return }
	if s.timer != base.NIL_HANDLE { host.clear_timer(p.loop, s.timer); s.timer = base.NIL_HANDLE }
	algos := make([]Abort_Algorithm, len(s.algorithms), context.temp_allocator)
	copy(algos, s.algorithms[:])
	clear(&s.algorithms)
	for a in algos {
		a.fn(p, a.data, h)
		if p.closed { return }
	}
	s = signal_get(p, h)
	if s == nil { return }
	object_dispatch(p, h, dom.Event{type = "abort", code = s.reason_code, text = s.reason})
}

@(private)
signal_timeout_fired :: proc(data: rawptr) {
	s := (^Abort_Signal)(data)
	s.timer = base.NIL_HANDLE
	signal_abort(s.page, s.self, WEB_ERR_TIMEOUT, TIMEOUT_REASON)
}

////////////////////////////////
// Imports

AbortController_create :: proc(c: ^Call) -> u64 {
	ac := new(Abort_Controller)
	ac.signal = signal_create(c.page, c.owner)
	return object_create(c.page, &abort_controller_vt, ac, c.owner)
}

AbortController_signal :: proc(c: ^Call, controller: Api_AbortController) -> u64 { return controller.data.signal }

// abort(reason): an empty reason with code 0 is the default AbortError.
AbortController_abort :: proc(c: ^Call, controller: Api_AbortController, code: i64, reason: string) {
	cd, r := code, reason
	if cd == 0 && r == "" { cd, r = WEB_ERR_ABORT, ABORT_REASON }
	signal_abort(c.page, controller.data.signal, cd, r)
}

AbortSignal_aborted :: proc(c: ^Call, signal: Api_AbortSignal) -> bool { return signal.data.aborted }
AbortSignal_reasonCode :: proc(c: ^Call, signal: Api_AbortSignal) -> i64 { return signal.data.reason_code }
AbortSignal_reason :: proc(c: ^Call, signal: Api_AbortSignal) -> string { return signal.data.reason }

// throwIfAborted(): 0, or the reason's code.
AbortSignal_throwIfAborted :: proc(c: ^Call, signal: Api_AbortSignal) -> i64 {
	s := signal.data
	return s.reason_code if s.aborted else 0
}

// AbortSignal.abort(reason): a signal that is already aborted.
AbortSignal_abort :: proc(c: ^Call, code: i64, reason: string) -> u64 {
	p := c.page
	h := signal_create(p, c.owner)
	s := signal_get(p, h)
	cd, r := code, reason
	if cd == 0 && r == "" { cd, r = WEB_ERR_ABORT, ABORT_REASON }
	s.aborted, s.reason_code, s.reason = true, cd, strings.clone(r)
	return h
}

// AbortSignal.timeout(ms): aborted with TimeoutError after `ms`.
AbortSignal_timeout :: proc(c: ^Call, ms: f64) -> (u64, Api_Error) {
	p := c.page
	if math.is_nan(ms) || ms < 0 { return 0, fail(c, .Range, "RangeError: the delay is negative or NaN") }
	h := signal_create(p, c.owner)
	s := signal_get(p, h)
	s.timer = host.set_timer(p.loop, min(ms, 1e12), 0, signal_timeout_fired, s, p.scope)
	return h, .None
}

// AbortSignal.any(signals)
AbortSignal_any :: proc(c: ^Call, signals: []u64) -> (u64, Api_Error) {
	p := c.page
	if len(signals) > p.settings.web.max_signal_sources { return 0, fail(c, .Range, "RangeError: too many signals (abort.max_signal_sources)") }
	for sh in signals { if signal_get(p, sh) == nil { return 0, fail(c, .Invalid_Handle, "AbortSignal.any: not an AbortSignal") } }
	h := signal_create(p, c.owner)
	res := signal_get(p, h)
	// already aborted source: the result is aborted with its reason, and follows nothing
	for sh in signals {
		src := signal_get(p, sh)
		if src.aborted {
			res.aborted, res.reason_code, res.reason = true, src.reason_code, strings.clone(src.reason)
			return h, .None
		}
	}
	res.dependent = true
	add_source :: proc(p: ^Page, res: ^Abort_Signal, h, src_h: u64) {
		for s in res.sources { if s == src_h { return } }
		append(&res.sources, src_h)
		if src := signal_get(p, src_h); src != nil { append(&src.dependents, h) }
	}
	for sh in signals {
		src := signal_get(p, sh)
		if !src.dependent {
			add_source(p, res, h, sh)
		} else {
			// a dependent source contributes its own sources
			for ss in src.sources { if signal_get(p, ss) != nil { add_source(p, res, h, ss) } }
		}
	}
	return h, .None
}