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
import "wb:wasm"

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

n_AbortController_create :: proc "c" (env: wasm.Exec_Env) -> u64 {
	context = ctx()
	p := page_of(env)
	owner := inst_of(env).index
	c := new(Abort_Controller)
	c.signal = signal_create(p, owner)
	return object_create(p, &abort_controller_vt, c, owner)
}

n_AbortController_signal :: proc "c" (env: wasm.Exec_Env, h: u64) -> u64 {
	context = ctx()
	c := (^Abort_Controller)(object_data(page_of(env), h, &abort_controller_vt))
	return c.signal if c != nil else 0
}

// abort(reason): an empty reason with code 0 is the default AbortError.
n_AbortController_abort :: proc "c" (env: wasm.Exec_Env, h: u64, code: i64, reason: [^]u8, rl: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	c := (^Abort_Controller)(object_data(p, h, &abort_controller_vt))
	if c == nil { return i32(dom.Error.Invalid_Handle) }
	r := str(reason, rl)
	cd := code
	if cd == 0 && r == "" { cd, r = WEB_ERR_ABORT, ABORT_REASON }
	signal_abort(p, c.signal, cd, r)
	return 0
}

n_AbortSignal_aborted :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	s := signal_get(page_of(env), h)
	if s == nil { return i32(dom.Error.Invalid_Handle) }
	return s.aborted ? 1 : 0
}

n_AbortSignal_reasonCode :: proc "c" (env: wasm.Exec_Env, h: u64) -> i64 {
	context = ctx()
	s := signal_get(page_of(env), h)
	return s.reason_code if s != nil else 0
}

n_AbortSignal_reason :: proc "c" (env: wasm.Exec_Env, h: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	s := signal_get(page_of(env), h)
	if s == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(s.reason, buf, cap)
}

// throwIfAborted(): 0, or the reason's code.
n_AbortSignal_throwIfAborted :: proc "c" (env: wasm.Exec_Env, h: u64) -> i64 {
	context = ctx()
	s := signal_get(page_of(env), h)
	if s == nil { return i64(dom.Error.Invalid_Handle) }
	return s.reason_code if s.aborted else 0
}

// AbortSignal.abort(reason): a signal that is already aborted.
n_AbortSignal_abort :: proc "c" (env: wasm.Exec_Env, code: i64, reason: [^]u8, rl: i32) -> u64 {
	context = ctx()
	p := page_of(env)
	h := signal_create(p, inst_of(env).index)
	s := signal_get(p, h)
	r := str(reason, rl)
	cd := code
	if cd == 0 && r == "" { cd, r = WEB_ERR_ABORT, ABORT_REASON }
	s.aborted, s.reason_code, s.reason = true, cd, strings.clone(r)
	return h
}

// AbortSignal.timeout(ms): aborted with TimeoutError after `ms`.
n_AbortSignal_timeout :: proc "c" (env: wasm.Exec_Env, ms: f64) -> u64 {
	context = ctx()
	p := page_of(env)
	if math.is_nan(ms) || ms < 0 { return 0 }
	h := signal_create(p, inst_of(env).index)
	s := signal_get(p, h)
	s.timer = host.set_timer(p.loop, min(ms, 1e12), 0, signal_timeout_fired, s, p.scope)
	return h
}

// AbortSignal.any(signals): `list` holds `bytes / 8` signal handles.
n_AbortSignal_any :: proc "c" (env: wasm.Exec_Env, list_bytes: [^]u8, bytes: i32) -> u64 {
	context = ctx()
	p := page_of(env)
	n := int(max(bytes, 0)) / 8
	if n > p.settings.web.max_signal_sources { return 0 }
	list := ([^]u64)(list_bytes)
	for i in 0 ..< n { if signal_get(p, list[i]) == nil { return 0 } }
	h := signal_create(p, inst_of(env).index)
	res := signal_get(p, h)
	// already aborted source: the result is aborted with its reason, and follows nothing
	for i in 0 ..< n {
		src := signal_get(p, list[i])
		if src.aborted {
			res.aborted, res.reason_code, res.reason = true, src.reason_code, strings.clone(src.reason)
			return h
		}
	}
	res.dependent = true
	add_source :: proc(p: ^Page, res: ^Abort_Signal, h, src_h: u64) {
		for s in res.sources { if s == src_h { return } }
		append(&res.sources, src_h)
		if src := signal_get(p, src_h); src != nil { append(&src.dependents, h) }
	}
	for i in 0 ..< n {
		src := signal_get(p, list[i])
		if !src.dependent {
			add_source(p, res, h, list[i])
		} else {
			// a dependent source contributes its own sources
			for ss in src.sources { if signal_get(p, ss) != nil { add_source(p, res, h, ss) } }
		}
	}
	return h
}

abort_symbols := [?]wasm.Native_Symbol{
	{"AbortController_create", rawptr(n_AbortController_create), "()I", nil},
	{"AbortController_signal", rawptr(n_AbortController_signal), "(I)I", nil},
	{"AbortController_abort", rawptr(n_AbortController_abort), "(II*~)i", nil},
	{"AbortSignal_aborted", rawptr(n_AbortSignal_aborted), "(I)i", nil},
	{"AbortSignal_reasonCode", rawptr(n_AbortSignal_reasonCode), "(I)I", nil},
	{"AbortSignal_reason", rawptr(n_AbortSignal_reason), "(I*~)i", nil},
	{"AbortSignal_throwIfAborted", rawptr(n_AbortSignal_throwIfAborted), "(I)I", nil},
	{"AbortSignal_abort", rawptr(n_AbortSignal_abort), "(I*~)I", nil},
	{"AbortSignal_timeout", rawptr(n_AbortSignal_timeout), "(F)I", nil},
	{"AbortSignal_any", rawptr(n_AbortSignal_any), "(*~)I", nil},
}
