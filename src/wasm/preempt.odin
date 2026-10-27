package wasm

// Preemption of long guest calls by the embedder: while a call runs on the thread that installed the hook, the epoch
// callback hands that thread to the hook at every tick (the browser draws its interface there, so a script that keeps
// the window's thread for 200 ms does not freeze the tabs, the address bar or scrolling). The hook runs on the guest's
// own thread, between two of its instructions: whatever the guest holds stays as it is, and the hook must not call into
// any module (a call started meanwhile, on any store of that thread, is refused: `preempting`). The time the hook takes
// is given back to the call's deadlines (wasm.max_call_ms, the slow script interruption).
//
// The epoch ticker's sleep is in preempt_<os>.odin (its accuracy is both the interruption's and the preemption's).

import "core:sync"
import "core:time"

Preempt_Hook :: #type proc(user: rawptr)

@(private)
Preempt :: struct {
	hook:       Preempt_Hook,
	user:       rawptr,
	thread:     int,      // the thread whose guest calls are preempted
	tick_ms:    int,      // the ticker's period while the hook is set (0: wasm.wasmtime.epoch_tick_ms)
	preempting: bool,     // the hook runs now (its thread only reads it)
	ran:        u64,      // hook calls (statistics)
}

@(private)
preempt: Preempt

// Installs `hook` for guest calls made on the calling thread (nil removes it). `tick_ms` > 0 makes the ticker tick at
// least that often while some call runs (the hook's granularity).
set_preempt_hook :: proc(hook: Preempt_Hook, user: rawptr, tick_ms := 0) {
	preempt.hook, preempt.user = hook, user
	preempt.thread = sync.current_thread_id()
	sync.atomic_store(&preempt.tick_ms, hook != nil ? max(tick_ms, 0) : 0)
}

// True while the hook runs (on its thread): no guest call may start.
preempting :: proc() -> bool { return preempt.preempting }

// The embedder does the hook's kind of work elsewhere (in the middle of a long native pass of its own): guest calls of
// the hook's thread are refused meanwhile. Returns the previous setting, to put back.
refuse_calls :: proc(on: bool) -> (previous: bool) {
	previous = preempt.preempting
	preempt.preempting = on
	return
}

// Times the hook ran.
preempt_count :: proc() -> u64 { return preempt.ran }

// From the epoch callback: hands the thread to the hook, and moves the call's deadlines by the time it took.
@(private)
preempt_tick :: proc(inst: ^Instance) {
	if preempt.hook == nil || preempt.preempting || sync.current_thread_id() != preempt.thread { return }
	t0 := time.tick_now()
	preempt.preempting = true
	outermost := guest_clock.depth == 1
	guest_clock_leave()   // the hook's time is not the guest's
	preempt.hook(preempt.user)
	guest_clock_enter()
	if outermost && guest_clock.calls > 0 { guest_clock.calls -= 1 }   // (one call, measured in two parts)
	preempt.preempting = false
	preempt.ran += 1
	spent := time.tick_since(t0)
	s := &inst.wt
	if s.deadline != {} { s.deadline = time.tick_add(s.deadline, spent) }
	if s.soft_deadline != {} { s.soft_deadline = time.tick_add(s.soft_deadline, spent) }
}

// The ticker's period (ms).
@(private)
ticker_period_ms :: proc() -> int {
	p := max(wt.rs.epoch_tick_ms, 1)
	if t := sync.atomic_load(&preempt.tick_ms); t > 0 && t < p { p = t }
	return p
}
