package wren_net

import "core:testing"
import "wb:base"
import "wb:host"

@(private = "file")
Heard :: struct { kinds: [dynamic]Event_Kind, bytes: int }

@(private = "file")
heard :: proc(user: rawptr, req: base.Handle, ev: ^Event) {
	h := (^Heard)(user)
	append(&h.kinds, ev.kind)
	h.bytes += len(ev.data)
}

// What the transport hands over for a request (its bytes are the queue's, as from a WinHTTP callback).
@(private = "file")
arrive :: proc(c: ^Client, req: base.Handle, kind: Event_Kind, n := 0) {
	ev := Event{kind = kind, req = req}
	if n > 0 { ev.data = make([]byte, n, heap()) }
	handle_event(c, &ev)
	free_event(&ev)
}

// A paused request delivers nothing and consumes nothing (so the transport stops at its high-water mark); its Done waits
// behind its data; a resume delivers it all, in order, from a timer and not inside the call.
@(test)
a_paused_request_holds_its_events_unconsumed :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	clock: host.Virtual_Clock
	host.clock_virtual(&loop, &clock)
	c := Client{loop = &loop}
	defer base.pool_destroy(&c.requests)
	h: Heard
	defer delete(h.kinds)
	job := new(Job, heap())
	job.client = &c
	c.live_jobs = 1
	req, _ := base.pool_insert(&c.requests, Request{job = job, on_event = heard, user = &h, state = .Active})
	defer release(&c, req)

	job.queued = 300   // (counted by the transport when it handed the bytes over)
	arrive(&c, req, .Data, 100)
	testing.expect_value(t, h.bytes, 100)
	testing.expect_value(t, job.queued, 200)   // consumed when delivered

	pause(&c, req, true)
	arrive(&c, req, .Data, 200)
	arrive(&c, req, .Done)
	testing.expect_value(t, len(h.kinds), 1)
	testing.expect_value(t, job.queued, 200)   // not consumed: the transport stays paused

	pause(&c, req, false)
	testing.expect_value(t, len(h.kinds), 1)   // (not inside the call)
	host.clock_advance(&loop, 0)
	testing.expect_value(t, len(h.kinds), 3)
	testing.expect_value(t, h.kinds[1], Event_Kind.Data)
	testing.expect_value(t, h.kinds[2], Event_Kind.Done)
	testing.expect_value(t, h.bytes, 300)
	testing.expect(t, base.pool_get(&c.requests, req) == nil, "Done ended the request")
}

// A consumer that pauses from its own callback while held events are delivered stops the rest there.
@(test)
a_pause_from_the_callback_stops_the_delivery :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	clock: host.Virtual_Clock
	host.clock_virtual(&loop, &clock)
	c := Client{loop = &loop}
	defer base.pool_destroy(&c.requests)
	State :: struct { c: ^Client, req: base.Handle, n: int }
	s := State{c = &c}
	job := new(Job, heap())
	job.client = &c
	c.live_jobs = 1
	s.req, _ = base.pool_insert(&c.requests, Request{job = job, user = &s, state = .Active, on_event = proc(user: rawptr, req: base.Handle, ev: ^Event) {
		s := (^State)(user)
		s.n += 1
		pause(s.c, req, true)   // (a download that started a write)
	}})
	defer release(&c, s.req)
	job.queued = 30
	pause(&c, s.req, true)
	for _ in 0 ..< 3 { arrive(&c, s.req, .Data, 10) }
	pause(&c, s.req, false)
	host.clock_advance(&loop, 0)
	testing.expect_value(t, s.n, 1)
	testing.expect_value(t, job.queued, 20)
	pause(&c, s.req, false)
	host.clock_advance(&loop, 0)
	testing.expect_value(t, s.n, 2)
}
