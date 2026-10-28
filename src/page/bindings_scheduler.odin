package page

// The Prioritized Task Scheduling API (scheduler.postTask / scheduler.yield, import module "scheduler"). The priority
// queue and the ordering live here natively, on the page's event loop; the C glue (native/js/runtime/web_scheduler.c)
// holds each task's JavaScript promise, callback and signal, and runs the callback when the host says the task is due.
//
// Three priorities, highest first: user-blocking, user-visible, background (TaskPriority). Within one priority, tasks
// run in the order they were posted (FIFO). A task runs as its own event-loop task (its own microtask checkpoint), so
// a priority change or an abort that happens while an earlier task runs is seen before the next task is chosen. A task
// with a delay waits on a host timer, then joins its priority queue. scheduler.yield() posts a continuation at the
// current task's priority (its promise resolves when the continuation runs). Abort (TaskController / a TaskSignal, or
// any AbortSignal) drops a queued task and rejects its promise with the signal's reason, handled on the C side.

import "wb:base"
import "wb:host"

Sched_Priority :: enum u8 { User_Blocking = 0, User_Visible = 1, Background = 2 }

Sched_Task :: struct {
	id:        u64,
	page:      ^Page,
	instance:  u32,
	callback:  u32,    // function-table index of wj_cb_scheduler
	user:      u32,    // the C record slot
	priority:  Sched_Priority,
	delay_h:   base.Handle,   // host timer while the task waits for its delay (NIL when queued)
	queued:    bool,          // in a priority queue (ready to run)
}

Scheduler :: struct {
	tasks:    [dynamic]^Sched_Task,       // every live task (queued or waiting on a delay)
	queues:   [3][dynamic]u64,            // task ids by priority, FIFO
	next_id:  u64,
	drain_posted: bool,
}

scheduler_init :: proc(s: ^Scheduler) {
	s.tasks = make([dynamic]^Sched_Task)
	for i in 0 ..< 3 { s.queues[i] = make([dynamic]u64) }
}

scheduler_destroy :: proc(p: ^Page, s: ^Scheduler) {
	for t in s.tasks {
		if t.delay_h != base.NIL_HANDLE && !p.closed { host.clear_timer(p.loop, t.delay_h) }
		free(t)
	}
	delete(s.tasks)
	for i in 0 ..< 3 { delete(s.queues[i]) }
}

@(private)
sched_of :: proc(p: ^Page) -> ^Scheduler {
	if p.web == nil { return nil }
	if p.web.scheduler == nil {
		p.web.scheduler = new(Scheduler)
		scheduler_init(p.web.scheduler)
	}
	return p.web.scheduler
}

@(private)
sched_find :: proc(s: ^Scheduler, id: u64) -> (int, ^Sched_Task) {
	for t, i in s.tasks { if t.id == id { return i, t } }
	return -1, nil
}

// Post a task (postTask with options, or a yield continuation). `delay_ms` 0 queues it now; otherwise it waits on a
// host timer first. Returns the task id (for cancel / setPriority). `callback`/`user` identify the C record to run.
Scheduler_post :: proc(c: ^Call, callback: u32, user: i32, priority: Api_TaskPriority, delay_ms: f64) -> u64 {
	p := c.page
	s := sched_of(p)
	if s == nil { return 0 }
	s.next_id += 1
	t := new(Sched_Task)
	t.id = s.next_id
	t.page = p
	t.instance = c.owner
	t.callback = callback
	t.user = u32(user)
	t.priority = sched_priority(priority)
	t.delay_h = base.NIL_HANDLE
	append(&s.tasks, t)
	if delay_ms > 0 {
		t.delay_h = host.set_timer(p.loop, min(delay_ms, 1e12), 0, sched_delay_fired, t, p.scope)
	} else {
		sched_enqueue(p, s, t)
	}
	return t.id
}

@(private)
sched_priority :: proc(api: Api_TaskPriority) -> Sched_Priority {
	switch api {
	case .User_Blocking: return .User_Blocking
	case .User_Visible:  return .User_Visible
	case .Background:    return .Background
	}
	return .User_Visible
}

// The delay elapsed: the task joins its priority queue now.
@(private)
sched_delay_fired :: proc(data: rawptr) {
	t := (^Sched_Task)(data)
	t.delay_h = base.NIL_HANDLE
	// find the page via the task's owning scheduler: the task carries no page pointer, so search is avoided by
	// stashing the page on the Web_State. The timer's scope ties its lifetime to the page, so the page is alive.
	p := sched_page_of(t)
	if p == nil || p.closed { return }
	s := sched_of(p)
	if s == nil { return }
	sched_enqueue(p, s, t)
}

// The page a task belongs to. The scheduler is per page; a timer fires with the task pointer, so recover the page from
// the global registry of pages by scanning (schedulers are small). Simpler: store the page on the task.
@(private)
sched_page_of :: proc(t: ^Sched_Task) -> ^Page { return t.page }

@(private)
sched_enqueue :: proc(p: ^Page, s: ^Scheduler, t: ^Sched_Task) {
	if t.queued { return }
	t.queued = true
	append(&s.queues[int(t.priority)], t.id)
	sched_arm_drain(p, s)
}

@(private)
sched_arm_drain :: proc(p: ^Page, s: ^Scheduler) {
	if s.drain_posted || p.closed { return }
	s.drain_posted = true
	post_page_task(p, proc(pg: ^Page, _: rawptr) {
		if pg == nil || pg.closed || pg.web == nil || pg.web.scheduler == nil { return }
		ss := pg.web.scheduler
		ss.drain_posted = false
		sched_drain_one(pg, ss)
	}, nil)
}

// Run the single highest-priority task at the front of a queue, then re-arm if any remain. One task per loop turn so
// a priority change or abort between tasks is honoured and other work interleaves.
@(private)
sched_drain_one :: proc(p: ^Page, s: ^Scheduler) {
	for prio in 0 ..< 3 {
		q := &s.queues[prio]
		for len(q) > 0 {
			id := q[0]
			ordered_remove(q, 0)
			i, t := sched_find(s, id)
			if t == nil || !t.queued { continue }
			t.queued = false
			ordered_remove(&s.tasks, i)
			inst := instance_by_index(p, t.instance)
			if inst != nil {
				loaf_set_invoker(p, .User_Callback, "scheduler.postTask")   // Long Animation Frames
				argv := [1]u32{t.user}
				call_guest(p, inst, t.callback, argv[:])
			}
			free(t)
			if p.closed { return }
			sched_arm_drain(p, s)
			return
		}
	}
}

// scheduler cancels a queued task (its signal aborted, or the realm released it). The C side rejects the promise.
Scheduler_cancel :: proc(c: ^Call, id: u64) -> Api_Error {
	s := sched_of(c.page)
	if s == nil { return .Not_Found }
	i, t := sched_find(s, id)
	if t == nil { return .Not_Found }
	if t.delay_h != base.NIL_HANDLE { host.clear_timer(c.page.loop, t.delay_h) }
	// leave it out of the queues: drain skips a task no longer in `tasks`
	ordered_remove(&s.tasks, i)
	free(t)
	return .None
}

// Change a queued task's priority (TaskController.setPriority): move it to the tail of the new priority's queue.
Scheduler_setPriority :: proc(c: ^Call, id: u64, priority: Api_TaskPriority) -> Api_Error {
	s := sched_of(c.page)
	if s == nil { return .Not_Found }
	_, t := sched_find(s, id)
	if t == nil { return .Not_Found }
	np := sched_priority(priority)
	if np == t.priority { return .None }
	if t.queued {
		old := &s.queues[int(t.priority)]
		for q, k in old { if q == id { ordered_remove(old, k); break } }
		append(&s.queues[int(np)], id)
	}
	t.priority = np
	return .None
}

// navigator.scheduling.isInputPending: whether the shell has queued input the page has not handled yet. Wren
// dispatches input synchronously on the UI loop through platform.inject_event, so by the time a page's script runs
// there is no input sitting unhandled in a page-visible queue to report. Honest answer: false (the hint only ever
// lets a script yield more eagerly; a false negative never breaks correctness). `include_continuous` is unused.
Scheduler_isInputPending :: proc(c: ^Call, include_continuous: bool) -> bool {
	_ = include_continuous
	return false
}
