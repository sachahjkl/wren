package fetch

import "core:testing"
import "wb:base"
import "wb:host"

@(private = "file")
Probe :: struct {
	l:       ^Loader,
	events:  [dynamic]Event_Kind,
	cancel:  bool,           // cancel the task from its Response callback
	other:   ^Probe,         // and start this one in the slot it freed
	started: base.Handle,
}

@(private = "file")
probe_event :: proc(user: rawptr, task: base.Handle, ev: ^Event) {
	pr := (^Probe)(user)
	append(&pr.events, ev.kind)
	if ev.kind == .Response && pr.cancel {
		cancel(pr.l, task)
		if pr.other != nil { pr.other.started = start(pr.l, {request = {url = "data:text/plain,second", mode = .No_Cors}, on_event = probe_event, user = pr.other}) }
	}
}

// A data: response is delivered in one go (Response, Data, Done): a callback that cancels the task, or reuses its slot
// for a new request, ends the delivery to that task. Regression: the rest was delivered through a freed (or reused) task.
@(test)
cancel_from_a_synthetic_response :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	profile := profile_make()
	defer profile_destroy(&profile)
	l: Loader
	loader_init(&l, &loop, nil, nil, &profile)
	defer loader_destroy(&l)

	second := Probe{l = &l}
	first := Probe{l = &l, cancel = true, other = &second}
	defer { delete(first.events); delete(second.events) }
	start(&l, {request = {url = "data:text/plain,first", mode = .No_Cors}, on_event = probe_event, user = &first})
	for in_flight(&l) > 0 { host.loop_wait(&loop) }   // every step is a posted task: the wait always ends
	testing.expect_value(t, len(first.events), 1)
	testing.expect(t, len(first.events) == 1 && first.events[0] == .Response, "nothing after the cancelling Response")
	testing.expect(t, second.started != base.NIL_HANDLE, "the second request started")
	testing.expect_value(t, len(second.events), 3)
	if len(second.events) == 3 {
		testing.expect(t, second.events[0] == .Response && second.events[1] == .Data && second.events[2] == .Done, "the new task gets its own events")
	}
}
