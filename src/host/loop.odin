// Package host: the event loop. It belongs to the browser, not to any guest language: guests export functions and
// the loop calls them (the Node/libuv model, with Wasm instead of JS).
//
// Threading rules:
//   * `post` and the wake callback are safe from any thread (network completions, file I/O, workers).
//   * Everything else (timers, run_ready) runs on the loop's thread, which is the UI thread.
//   * Wakes are coalesced: any number of posts cost at most one wake until the next `run_ready`.
//
// The loop never blocks by itself when embedded in the window: the window waits for OS messages (with
// `next_timeout_ms` as the timeout) and the wake callback posts one. `loop_wait` is the same thing for headless
// programs and tests.
package host

import "base:runtime"
import "core:container/priority_queue"
import "core:sync"
import "core:time"
import "wb:base"

Task_Proc :: #type proc(data: rawptr)

Task :: struct {
	fn:   Task_Proc,
	data: rawptr,
}

Timer :: struct {
	fn:          Task_Proc,
	data:        rawptr,
	deadline:    i64,   // ns since loop origin
	interval:    i64,   // 0 = one-shot
	scope:       ^base.Scope,
	cleanup:     base.Cleanup_Id,
}

Timer_Entry :: struct {
	deadline: i64,
	handle:   base.Handle,
}

Loop :: struct {
	origin:     time.Tick,
	mu:         sync.Mutex,
	posted:     [dynamic]Task,
	scratch:    [dynamic]Task,
	pending:    b32,   // atomic: a wake has been issued and no run_ready has started since
	wake:       proc(user: rawptr),
	wake_user:  rawptr,
	sema:       sync.Sema,

	timers:     base.Pool(Timer),
	queue:      priority_queue.Priority_Queue(Timer_Entry),
	// Longest a turn keeps running due timers once one has run (ns; 0: all of them). The rest run at the next turn, so the
	// shell can draw and read input between them even when a page floods the loop with timers. browser.loop.timer_slice_ms
	timer_slice_ns: i64,
	stale:      int,   // queue entries of timers cleared before their deadline (dropped when they pile up: compact_timers)
}

// Longest timer delay (ms, about 31 years): NaN, infinities and larger values are this (never, in practice); beyond,
// the deadline in ns would overflow and a timer meant for never would fire at once.
MAX_TIMER_MS :: 1e12

// Default of Loop.timer_slice_ns (the browser sets it from browser.loop.timer_slice_ms).
DEFAULT_TIMER_SLICE_NS :: 8_000_000

// `wake` may be nil: the loop then wakes `loop_wait` only.
loop_init :: proc(l: ^Loop, wake: proc(user: rawptr) = nil, wake_user: rawptr = nil) {
	l.origin = time.tick_now()
	// `post` is called from foreign threads whose context allocator is the process heap: keep these arrays there.
	l.posted = make([dynamic]Task, runtime.heap_allocator())
	l.scratch = make([dynamic]Task, runtime.heap_allocator())
	l.wake = wake
	l.wake_user = wake_user
	l.timer_slice_ns = DEFAULT_TIMER_SLICE_NS
	priority_queue.init(&l.queue, proc(a, b: Timer_Entry) -> bool { return a.deadline < b.deadline }, priority_queue.default_swap_proc(Timer_Entry))
}

loop_destroy :: proc(l: ^Loop) {
	delete(l.posted)
	delete(l.scratch)
	priority_queue.destroy(&l.queue)
	base.pool_destroy(&l.timers)
}

now_ns :: proc(l: ^Loop) -> i64 {
	return i64(time.tick_diff(l.origin, time.tick_now()))
}

// Any thread.
post :: proc(l: ^Loop, fn: Task_Proc, data: rawptr) {
	sync.mutex_lock(&l.mu)
	append(&l.posted, Task{fn, data})
	sync.mutex_unlock(&l.mu)
	signal(l)
}

// Any thread. Cheap when a wake is already pending.
signal :: proc(l: ^Loop) {
	if _, swapped := sync.atomic_compare_exchange_strong(&l.pending, false, true); swapped {
		sync.sema_post(&l.sema)
		if l.wake != nil { l.wake(l.wake_user) }
	}
}

// Loop thread. Registers a timer; with a scope the timer dies with it. Returns NIL_HANDLE never.
set_timer :: proc(l: ^Loop, delay_ms: f64, interval_ms: f64, fn: Task_Proc, data: rawptr, scope: ^base.Scope = nil) -> base.Handle {
	t := Timer{
		fn = fn, data = data,
		deadline = now_ns(l) + timer_ns(delay_ms),
		interval = timer_ns(interval_ms),
		scope = scope,
	}
	h, p := base.pool_insert(&l.timers, t)
	if scope != nil { p.cleanup = base.on_close(scope, timer_scope_closed, new_clone(Timer_Owner{l, h})) }
	priority_queue.push(&l.queue, Timer_Entry{p.deadline, h})
	return h
}

@(private)
timer_ns :: proc(ms: f64) -> i64 {
	if !(ms > 0) { return 0 }   // NaN too
	return i64(min(ms, MAX_TIMER_MS) * 1e6)
}

@(private)
Timer_Owner :: struct { l: ^Loop, h: base.Handle }

@(private)
timer_scope_closed :: proc(data: rawptr) {
	o := (^Timer_Owner)(data)
	base.pool_remove(&o.l.timers, o.h)   // the scope is closing: nothing to unregister
	free(o)
}

// Loop thread. False when the timer already fired (one-shot) or was cleared.
clear_timer :: proc(l: ^Loop, h: base.Handle) -> bool {
	t, ok := base.pool_remove(&l.timers, h)
	if ok && t.scope != nil { release_scope_hook(t) }
	if ok {
		// its queue entry stays until its deadline: a page clearing long timers in a loop would pile them up
		l.stale += 1
		if l.stale > l.timers.count + 64 { compact_timers(l) }
	}
	return ok
}

// The timer queue made again from the live timers only.
@(private)
compact_timers :: proc(l: ^Loop) {
	priority_queue.clear(&l.queue)
	it: u32
	for h, t in base.pool_next(&l.timers, &it) { priority_queue.push(&l.queue, Timer_Entry{t.deadline, h}) }
	l.stale = 0
}

@(private)
release_scope_hook :: proc(t: Timer) {
	// The cleanup's closure data is owned by the cleanup record; run it instead of forgetting so it is freed.
	for i := len(t.scope.cleanups) - 1; i >= 0; i -= 1 {
		if t.scope.cleanups[i].id == t.cleanup {
			c := t.scope.cleanups[i]
			ordered_remove(&t.scope.cleanups, i)
			free(c.data)
			return
		}
	}
}

// Milliseconds until the next timer, 0 if a wake is already pending or a timer is due, -1 for "no timer".
next_timeout_ms :: proc(l: ^Loop) -> int {
	if sync.atomic_load(&l.pending) { return 0 }
	for priority_queue.len(l.queue) > 0 {
		e := priority_queue.peek(l.queue)
		t := base.pool_get(&l.timers, e.handle)
		if t == nil || t.deadline != e.deadline { priority_queue.pop(&l.queue); continue }   // stale entry
		d := e.deadline - now_ns(l)
		if d <= 0 { return 0 }
		return int((d + 999_999) / 1_000_000)
	}
	return -1
}

// Loop thread. Runs the posted tasks, then the timers due at this instant. Returns how many callbacks ran.
run_ready :: proc(l: ^Loop) -> int {
	sync.atomic_store(&l.pending, false)   // before draining: a post racing with us re-arms the wake
	ran := 0

	sync.mutex_lock(&l.mu)
	l.posted, l.scratch = l.scratch, l.posted
	sync.mutex_unlock(&l.mu)
	for task in l.scratch { task.fn(task.data); ran += 1 }
	clear(&l.scratch)

	cutoff := now_ns(l)
	timers_ran := 0
	for priority_queue.len(l.queue) > 0 {
		e := priority_queue.peek(l.queue)
		if e.deadline > cutoff { break }
		// time slice used up: the timers still due run at the next turn (next_timeout_ms is then 0)
		if timers_ran > 0 && l.timer_slice_ns > 0 && now_ns(l) - cutoff >= l.timer_slice_ns { signal(l); break }
		priority_queue.pop(&l.queue)
		t := base.pool_get(&l.timers, e.handle)
		if t == nil || t.deadline != e.deadline { continue }
		fn, data := t.fn, t.data
		if t.interval > 0 {
			// next tick counted from now, not from the missed deadline: a stalled loop must not replay a burst
			t.deadline = max(e.deadline + t.interval, cutoff + 1)
			priority_queue.push(&l.queue, Timer_Entry{t.deadline, e.handle})
		} else {
			done, _ := base.pool_remove(&l.timers, e.handle)
			if done.scope != nil { release_scope_hook(done) }
		}
		fn(data)
		ran += 1
		timers_ran += 1
	}
	return ran
}

// Headless embedding: blocks until a post/signal or the next timer (or `max_ms` when >= 0), then runs what is ready.
loop_wait :: proc(l: ^Loop, max_ms: int = -1) -> int {
	timeout := next_timeout_ms(l)
	if max_ms >= 0 && (timeout < 0 || max_ms < timeout) { timeout = max_ms }
	if timeout != 0 {
		if timeout < 0 { sync.sema_wait(&l.sema) } else { sync.sema_wait_with_timeout(&l.sema, time.Duration(timeout) * time.Millisecond) }
	}
	return run_ready(l)
}
