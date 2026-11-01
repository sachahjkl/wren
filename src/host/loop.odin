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
	by:   runtime.Source_Code_Location,   // who posted it (Loop.last_ran)
}

Timer :: struct {
	fn:          Task_Proc,
	data:        rawptr,
	by:          runtime.Source_Code_Location,   // who set it (Loop.last_ran)
	deadline:    i64,   // ns since loop origin
	interval:    i64,   // 0 = one-shot
	scope:       ^base.Scope,
	cleanup:     base.Cleanup_Id,
}

Timer_Entry :: struct {
	deadline: i64,
	seq:      u64,   // creation order: ties run first-in first-out, and a turn never runs a timer created during it
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
	timer_seq:  u64,
	// Longest a turn keeps running due timers once one has run (ns; 0: all of them). The rest run at the next turn, so the
	// shell can draw and read input between them even when a page floods the loop with timers. browser.loop.timer_slice_ms
	timer_slice_ns: i64,
	stale:      int,   // queue entries of timers cleared before their deadline (dropped when they pile up: compact_timers)
	// When set, the loop's time is read here instead of the monotonic clock: a test moves it (clock_advance, clock_move)
	// instead of sleeping. Everything that decides on elapsed time through this loop reads now_ns. Production leaves it nil,
	// and pays one predictable test of a pointer on the way to the system's clock.
	virtual:   ^Virtual_Clock,
	// Callbacks of the last run_ready that made nothing show by themselves (a media player's notice that its decoders
	// advanced): quiet_take hands the count to the shell, which does not draw a frame for them. Loop thread only.
	quiet:     int,
	// Who posted or set the last callback that ran and was not quiet: what a frame made for it names (the browser's loop_rates.odin).
	last_ran:  runtime.Source_Code_Location,
	last_quiet: runtime.Source_Code_Location,   // ... and the last that was (what a wake with no frame names)
	// Debug builds: the thread that runs the loop (the first one to touch its timers or run it); everything but post and
	// signal asserts it is that one (loop_owned). 0: none yet.
	owner:     int,
}

// Debug builds: the calling thread must be the loop's own (the first one that used it claims it). A loop handed to
// another thread on purpose (a worker's, made by the page and run by the worker) is claimed by the thread that runs it.
loop_owned :: #force_inline proc(l: ^Loop, what: string) {
	when ODIN_DEBUG {
		me := sync.current_thread_id()
		if prev, ok := sync.atomic_compare_exchange_strong(&l.owner, 0, me); !ok && prev != me {
			panic(what)
		}
	}
}

// Longest timer delay (ms, about 31 years): NaN, infinities and larger values are this (never, in practice); beyond,
// the deadline in ns would overflow and a timer meant for never would fire at once.
MAX_TIMER_MS :: 1e12

// Default of Loop.timer_slice_ns (the browser sets it from browser.loop.timer_slice_ms).
DEFAULT_TIMER_SLICE_NS :: 8_000_000

@(private) NS_PER_MS :: 1_000_000

// The turns one clock_advance takes at most at one instant.
CLOCK_ADVANCE_MAX_TURNS :: 100_000

// `wake` may be nil: the loop then wakes `loop_wait` only.
loop_init :: proc(l: ^Loop, wake: proc(user: rawptr) = nil, wake_user: rawptr = nil) {
	l.origin = time.tick_now()
	// `post` is called from foreign threads whose context allocator is the process heap: keep these arrays there.
	l.posted = make([dynamic]Task, base.process_allocator())
	l.scratch = make([dynamic]Task, base.process_allocator())
	l.wake = wake
	l.wake_user = wake_user
	l.timer_slice_ns = DEFAULT_TIMER_SLICE_NS
	priority_queue.init(&l.queue, proc(a, b: Timer_Entry) -> bool { return a.deadline < b.deadline || (a.deadline == b.deadline && a.seq < b.seq) }, priority_queue.default_swap_proc(Timer_Entry))
}

loop_destroy :: proc(l: ^Loop) {
	delete(l.posted)
	delete(l.scratch)
	priority_queue.destroy(&l.queue)
	base.pool_destroy(&l.timers)
}

now_ns :: proc(l: ^Loop) -> i64 {
	if l.virtual != nil { return sync.atomic_load(&l.virtual.now_ns) }
	return i64(time.tick_diff(l.origin, time.tick_now()))
}

// A test's time source: it stands still until the test moves it. It starts at 0, the loop's origin. Give it to the loop
// (clock_virtual) before the first timer: deadlines made on the other clock mean nothing on this one.
Virtual_Clock :: struct {
	now_ns: i64,   // atomic
}

// Test programs. From now on `l` reads `c`, and a wait of the loop does not count on time passing (loop_wait).
clock_virtual :: proc(l: ^Loop, c: ^Virtual_Clock) { l.virtual = c }

// Moves the clock without running anything, as a stalled machine would: what is due runs at the next turn, all at that
// late time. Any thread; the loop's wait wakes.
clock_move :: proc(l: ^Loop, d: time.Duration) {
	sync.atomic_add(&l.virtual.now_ns, i64(d))
	signal(l)
}

// Loop thread. Moves the clock by `d` and runs at once what falls due on the way, each timer at its own deadline, in
// order, the tasks and timers they make included, as the same time would have gone by on a loop with nothing else to do
// (a repeating timer ticks at each of its periods). Waits for nothing. Returns how many callbacks ran. Only a test whose
// timers remake themselves for ever at the same instant stops at CLOCK_ADVANCE_MAX_TURNS: the caller's checks then fail.
clock_advance :: proc(l: ^Loop, d: time.Duration) -> (ran: int) {
	target := sync.atomic_load(&l.virtual.now_ns) + i64(d)
	for turn := 0; turn < CLOCK_ADVANCE_MAX_TURNS; turn += 1 {
		if next_timeout_ms(l) == 0 { ran += run_ready(l); continue }   // what is due at this instant first
		deadline, ok := next_deadline(l)
		if !ok || deadline > target { break }
		sync.atomic_store(&l.virtual.now_ns, deadline)
	}
	sync.atomic_store(&l.virtual.now_ns, target)
	for turn := 0; turn < CLOCK_ADVANCE_MAX_TURNS && next_timeout_ms(l) == 0; turn += 1 { ran += run_ready(l) }
	return
}

// The deadline of the next live timer (the stale entries in front of it go).
@(private)
next_deadline :: proc(l: ^Loop) -> (deadline: i64, ok: bool) {
	for priority_queue.len(l.queue) > 0 {
		e := priority_queue.peek(l.queue)
		t := base.pool_get(&l.timers, e.handle)
		if t == nil || t.deadline != e.deadline { priority_queue.pop(&l.queue); continue }
		return e.deadline, true
	}
	return 0, false
}

// Takes out of the posted queue the tasks of `fn` that did not run and hands each one's data to `discard` (what a loop being
// destroyed does with the tasks nobody will run: whoever allocated their data frees it). Any thread.
discard_posted :: proc(l: ^Loop, fn: Task_Proc, discard: proc(data: rawptr)) {
	sync.mutex_lock(&l.mu)
	taken := make([dynamic]rawptr, context.temp_allocator)
	w := 0
	for t in l.posted {
		if t.fn == fn { append(&taken, t.data) } else { l.posted[w] = t; w += 1 }
	}
	resize(&l.posted, w)
	sync.mutex_unlock(&l.mu)
	for d in taken { discard(d) }
}

// Any thread.
post :: proc(l: ^Loop, fn: Task_Proc, data: rawptr, by := #caller_location) {
	sync.mutex_lock(&l.mu)
	append(&l.posted, Task{fn, data, by})
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
set_timer :: proc(l: ^Loop, delay_ms: f64, interval_ms: f64, fn: Task_Proc, data: rawptr, scope: ^base.Scope = nil, by := #caller_location) -> base.Handle {
	loop_owned(l, "host.set_timer off the loop's thread")
	t := Timer{
		fn = fn, data = data, by = by,
		deadline = now_ns(l) + timer_ns(delay_ms),
		interval = timer_ns(interval_ms),
		scope = scope,
	}
	h, p := base.pool_insert(&l.timers, t)
	if scope != nil { p.cleanup = base.on_close(scope, timer_scope_closed, new_clone(Timer_Owner{l, h})) }
	l.timer_seq += 1
	priority_queue.push(&l.queue, Timer_Entry{p.deadline, l.timer_seq, h})
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
	loop_owned(l, "host.clear_timer off the loop's thread")
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
	// the entries of live timers, with their creation order (an entry is current when its timer is alive and has its
	// deadline: a repeating timer's earlier entries were replaced)
	keep := make([dynamic]Timer_Entry, 0, l.timers.count, context.temp_allocator)
	for e in l.queue.queue {
		if t := base.pool_get(&l.timers, e.handle); t != nil && t.deadline == e.deadline { append(&keep, e) }
	}
	priority_queue.clear(&l.queue)
	for e in keep { priority_queue.push(&l.queue, e) }
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
	deadline, ok := next_deadline(l)
	if !ok { return -1 }
	d := deadline - now_ns(l)
	if d <= 0 { return 0 }
	return int((d + NS_PER_MS - 1) / NS_PER_MS)
}

// Loop thread, from inside a callback: this one does not need a frame by itself (what it changes on screen it asks for:
// a document mutation, an animation, a task of its own).
quiet_note :: proc(l: ^Loop) { l.quiet += 1 }

// Loop thread. The quiet callbacks since the last call: the shell takes them off what run_ready returned.
quiet_take :: proc(l: ^Loop) -> int {
	n := l.quiet
	l.quiet = 0
	return n
}

@(private = "file")
run_one :: proc(l: ^Loop, fn: Task_Proc, data: rawptr, by: runtime.Source_Code_Location) {
	quiet := l.quiet
	fn(data)
	if l.quiet == quiet { l.last_ran = by } else { l.last_quiet = by }
}

// Loop thread. Runs the posted tasks, then the timers due at this instant. Returns how many callbacks ran.
run_ready :: proc(l: ^Loop) -> int {
	loop_owned(l, "host.run_ready off the loop's thread")
	sync.atomic_store(&l.pending, false)   // before draining: a post racing with us re-arms the wake
	ran := 0

	sync.mutex_lock(&l.mu)
	l.posted, l.scratch = l.scratch, l.posted
	sync.mutex_unlock(&l.mu)
	for task in l.scratch { run_one(l, task.fn, task.data, task.by); ran += 1 }
	clear(&l.scratch)

	cutoff := now_ns(l)
	last_seq := l.timer_seq   // timers created by this turn's callbacks wait for the next turn, even when already due
	timers_ran := 0
	for priority_queue.len(l.queue) > 0 {
		e := priority_queue.peek(l.queue)
		if e.deadline > cutoff || e.seq > last_seq { break }
		// time slice used up: the timers still due run at the next turn (next_timeout_ms is then 0)
		if timers_ran > 0 && l.timer_slice_ns > 0 && now_ns(l) - cutoff >= l.timer_slice_ns { signal(l); break }
		priority_queue.pop(&l.queue)
		t := base.pool_get(&l.timers, e.handle)
		if t == nil || t.deadline != e.deadline { continue }
		fn, data, by := t.fn, t.data, t.by
		if t.interval > 0 {
			// next tick counted from now, not from the missed deadline: a stalled loop must not replay a burst
			t.deadline = max(e.deadline + t.interval, cutoff + 1)
			l.timer_seq += 1
			priority_queue.push(&l.queue, Timer_Entry{t.deadline, l.timer_seq, e.handle})
		} else {
			done, _ := base.pool_remove(&l.timers, e.handle)
			if done.scope != nil { release_scope_hook(done) }
		}
		run_one(l, fn, data, by)
		ran += 1
		timers_ran += 1
	}
	return ran
}

// Loop thread. Runs the posted tasks until none is left (those they post too, `max_turns` rounds at most), not the
// timers. Before tearing a program down, once its pages are closed: a posted task owns its data and frees it when it
// runs (a page task whose page is gone only releases), so a loop destroyed with tasks still queued leaks them.
loop_drain :: proc(l: ^Loop, max_turns := 1000) -> (ran: int) {
	for _ in 0 ..< max_turns {
		sync.mutex_lock(&l.mu)
		empty := len(l.posted) == 0
		l.posted, l.scratch = l.scratch, l.posted
		sync.mutex_unlock(&l.mu)
		if empty { break }
		for task in l.scratch { task.fn(task.data); ran += 1 }
		clear(&l.scratch)
	}
	return
}

// Headless embedding: blocks until a post/signal or the next timer (or `max_ms` when >= 0), then runs what is ready.
loop_wait :: proc(l: ^Loop, max_ms: int = -1) -> int {
	timeout := next_timeout_ms(l)
	// on a virtual clock a timer is no reason to wait for any time at all: it falls due when the test says, and that wakes this wait
	if l.virtual != nil && timeout > 0 { timeout = -1 }
	if max_ms >= 0 && (timeout < 0 || max_ms < timeout) { timeout = max_ms }
	if timeout != 0 {
		if timeout < 0 { sync.sema_wait(&l.sema) } else { sync.sema_wait_with_timeout(&l.sema, time.Duration(timeout) * time.Millisecond) }
	}
	return run_ready(l)
}
