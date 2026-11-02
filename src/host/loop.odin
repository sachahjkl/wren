// Package host: the event loop. It belongs to the browser, not to any guest language: guests export functions and
// the loop calls them (the Node/libuv model, with Wasm instead of JS).
//
// Threading rules:
//   * `post` and the wake callback are safe from any thread (network completions, file I/O, workers). A post takes no
//     lock: the task goes in a lock-free queue (mpsc.odin) that the loop empties at each turn.
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
	posted:     Mpsc(Task),      // any thread pushes, the loop pops
	taken:      [dynamic]Task,   // loop thread: popped from `posted`, not run yet (in order)
	scratch:    [dynamic]Task,   // loop thread: what a turn runs
	// Atomic, 0 or 1: a wake has been issued and no run_ready has started since. loop_wait sleeps on it (a futex: one
	// wake is one wake, however many posts made it, and a wait after the turn that took them does not return for them).
	pending:    sync.Futex,
	sleepers:   i32,   // atomic: threads in sleep_on_pending (a signal calls the system only for them)
	again:      bool,  // loop thread: something of this turn asked for another one
	wake:       proc(user: rawptr),
	wake_user:  rawptr,

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
	mpsc_init(&l.posted)
	l.wake = wake
	l.wake_user = wake_user
	l.timer_slice_ns = DEFAULT_TIMER_SLICE_NS
	priority_queue.init(&l.queue, proc(a, b: Timer_Entry) -> bool { return a.deadline < b.deadline || (a.deadline == b.deadline && a.seq < b.seq) }, priority_queue.default_swap_proc(Timer_Entry))
}

loop_destroy :: proc(l: ^Loop) {
	mpsc_destroy(&l.posted)
	delete(l.taken)
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

// Loop thread. Takes out of the posted queue the tasks of `fn` that did not run and hands each one's data to `discard`
// (what a loop being destroyed does with the tasks nobody will run: whoever allocated their data frees it). A task of
// `fn` posted after it returns stays.
discard_posted :: proc(l: ^Loop, fn: Task_Proc, discard: proc(data: rawptr)) {
	loop_owned(l, "host.discard_posted off the loop's thread")
	take_posted(l)
	w := 0
	for t in l.taken {
		if t.fn == fn { discard(t.data) } else { l.taken[w] = t; w += 1 }
	}
	resize(&l.taken, w)
}

// Any thread.
post :: proc(l: ^Loop, fn: Task_Proc, data: rawptr, by := #caller_location) {
	mpsc_push(&l.posted, Task{fn, data, by})
	signal(l)
}

// Loop thread. What the queue holds goes to `taken`, in order.
@(private)
take_posted :: proc(l: ^Loop) {
	for {
		t := mpsc_pop(&l.posted) or_break
		append(&l.taken, t)
	}
}

// The loop whose run_ready this thread is in (signal: a callback's request for another turn), nil outside one.
@(private, thread_local)
turn_loop: ^Loop

// Any thread. Cheap when a wake is already pending.
signal :: proc(l: ^Loop) {
	// (read first: a pending wake costs a post no write to the line every other post reads; run_ready clears it only at
	// the end of a turn that left nothing, then looks again)
	if sync.atomic_load(&l.pending) != 0 {
		// a callback of the running turn asks for another: the turn's end must not take that back
		if turn_loop == l { l.again = true }
		return
	}
	if _, swapped := sync.atomic_compare_exchange_strong(&l.pending, 0, 1); swapped {
		// (a loop that is not asleep needs no call to the system: one going to sleep sees the flag set first)
		if sync.atomic_load(&l.sleepers) > 0 { sync.futex_signal(&l.pending) }
		if l.wake != nil { l.wake(l.wake_user) }
	}
}

// The futex wait on `pending`, counted in `sleepers` first: a signal from then on wakes it, one before finds the flag set.
@(private)
sleep_on_pending :: proc(l: ^Loop, d: time.Duration) {
	sync.atomic_add(&l.sleepers, 1)
	if d < 0 { sync.futex_wait(&l.pending, 0) } else { sync.futex_wait_with_timeout(&l.pending, 0, d) }
	sync.atomic_sub(&l.sleepers, 1)
}

// Any thread that waits on a loop without running it (a worker's thread blocked in a synchronous call, a test that runs
// the turns itself): takes the pending wake if there is one, else waits for one at most `d`. What woke it is the
// caller's to look at once it returns (a post after it re-arms the wake).
loop_sleep :: proc(l: ^Loop, d: time.Duration) {
	if sync.atomic_exchange(&l.pending, 0) != 0 { return }
	sleep_on_pending(l, d)
	sync.atomic_store(&l.pending, 0)
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
	if sync.atomic_load(&l.pending) != 0 { return 0 }
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
	// The wake stays pending while the turn runs (a post meanwhile writes nothing: it finds it set) and is cleared at
	// the end only when nothing new waits; then the queue is looked at again (end_turn).
	outer := turn_loop   // (a run_ready inside a callback of another)
	turn_loop = l
	ran := 0

	// what discard_posted set aside is older than anything still queued: it runs first
	if len(l.taken) > 0 {
		l.taken, l.scratch = l.scratch, l.taken
		for task in l.scratch { run_one(l, task.fn, task.data, task.by); ran += 1 }
		clear(&l.scratch)
	}
	// then what was posted before this turn, straight from the queue (what these tasks post waits for the next turn); a task
	// that sets the queue aside (discard_posted, loop_drain) ends it, and what it set aside runs first at the next
	end := mpsc_mark(&l.posted)
	for len(l.taken) == 0 {
		task := mpsc_next(&l.posted, end)
		if task == nil { break }
		run_one(l, task.fn, task.data, task.by)
		ran += 1
	}
	if len(l.taken) > 0 { l.again = true }

	cutoff := now_ns(l)
	last_seq := l.timer_seq   // timers created by this turn's callbacks wait for the next turn, even when already due
	timers_ran := 0
	for priority_queue.len(l.queue) > 0 {
		e := priority_queue.peek(l.queue)
		if e.deadline > cutoff || e.seq > last_seq { break }
		// time slice used up: the timers still due run at the next turn (next_timeout_ms is then 0)
		if timers_ran > 0 && l.timer_slice_ns > 0 && now_ns(l) - cutoff >= l.timer_slice_ns { l.again = true; break }
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
	end_turn(l, end)
	turn_loop = outer
	return ran
}

// The end of a turn. The wake stays pending when this turn asked for another, or when the turn ran to its position and
// the next post is already written: the next turn runs at once, and the producers, finding it set, wrote nothing to it. Else it is
// cleared, and set again if a post was stamped meanwhile (its producer may have read the flag still set); a post
// still being written signals once stamped, as it reads the flag after.
@(private)
end_turn :: proc(l: ^Loop, end: int) {
	more := l.again || (l.posted.head >= end && mpsc_ready(&l.posted))
	if l.again { l.again = false }
	if more {
		if sync.atomic_load(&l.pending) == 0 { sync.atomic_store(&l.pending, 1) }
		return
	}
	sync.atomic_store(&l.pending, 0)
	if mpsc_ready(&l.posted) { sync.atomic_store(&l.pending, 1) }
}

// Loop thread. Runs the posted tasks until none is left (those they post too, `max_turns` rounds at most), not the
// timers. Before tearing a program down, once its pages are closed: a posted task owns its data and frees it when it
// runs (a page task whose page is gone only releases), so a loop destroyed with tasks still queued leaks them.
loop_drain :: proc(l: ^Loop, max_turns := 1000) -> (ran: int) {
	for _ in 0 ..< max_turns {
		take_posted(l)
		if len(l.taken) == 0 { break }
		l.taken, l.scratch = l.scratch, l.taken
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
		// (returns at once when a wake is pending by now; a spurious return only makes an empty turn)
		sleep_on_pending(l, timeout < 0 ? -1 : time.Duration(timeout) * time.Millisecond)
	}
	return run_ready(l)
}
