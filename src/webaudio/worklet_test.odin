package webaudio

// The protocol of worklet.odin with a thread standing in for the realm: what comes back is heard, a realm that hangs or goes
// costs silence and an event, never a hung render thread.

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"

@(private = "file") FAKE_GAIN :: f32(0.5)
@(private = "file") STALL_LIMIT :: 200 * time.Millisecond
// What a render that must not wait for a hung realm stays under, whatever the machine.
@(private = "file") GENEROUS_LIMIT :: 30 * time.Second

@(private = "file")
Fake_Realm :: struct {
	w:        ^Worklet,
	stop:     bool,   // atomic
	released: sync.Sema,   // a hung realm stays until this
	hang:     bool,   // atomic: takes a request and never answers until stopped
	throw_at: int,    // the call that fails (0: none)
	calls:    int,
	dropped:  int,
	status:   Worklet_Status,
}

// A processor that gives its first input times FAKE_GAIN on its first output.
@(private = "file")
fake_realm_main :: proc(th: ^thread.Thread) {
	r := (^Fake_Realm)(th.data)
	values: [64]i32
	samples: [RENDER_QUANTUM]f32
	for !sync.atomic_load(&r.stop) {
		for worklet_take_dropped(r.w) >= 0 { r.dropped += 1 }
		if !worklet_take(r.w) {
			thread.yield()
			continue
		}
		r.calls += 1
		if sync.atomic_load(&r.hang) {
			sync.sema_wait(&r.released)
			break
		}
		n := worklet_layout(r.w, values[:])
		inputs, outputs, params := int(values[1]), int(values[2]), int(values[3])
		_ = n
		at, out_at := 0, 0
		in_channels := inputs > 0 ? int(values[WORKLET_LAYOUT_HEADER]) : 0
		for i in 0 ..< inputs { at += int(values[WORKLET_LAYOUT_HEADER + i]) * RENDER_QUANTUM }
		for i in 0 ..< params { at += int(values[WORKLET_LAYOUT_HEADER + inputs + i]) }
		out_at = at
		for o in 0 ..< outputs {
			channels := int(values[WORKLET_LAYOUT_HEADER + inputs + params + o])
			for c in 0 ..< channels {
				samples = {}
				if o == 0 && c < in_channels {
					worklet_read(r.w, c * RENDER_QUANTUM, samples[:])
					for &s in samples { s *= FAKE_GAIN }
				}
				worklet_write(r.w, out_at, samples[:])
				out_at += RENDER_QUANTUM
			}
		}
		failing := r.throw_at != 0 && r.calls == r.throw_at
		worklet_finish(r.w, failing ? .Failed : r.status)
	}
}

@(private = "file")
// limit: what the graph gives the realm to answer. Only a test of a realm that hangs says 200 ms: on a loaded machine this thread may
// not even have started by then, and the graph gives up on it.
fake_start :: proc(r: ^Fake_Realm, g: ^Graph, limit := GENEROUS_LIMIT) -> ^thread.Thread {
	r.w = worklet_attach(g, limit)
	worklet_realm_attach(r.w, proc(user: rawptr) {}, nil)
	th := thread.create(fake_realm_main)
	th.data = r
	thread.start(th)
	return th
}

@(private = "file")
fake_stop :: proc(r: ^Fake_Realm, th: ^thread.Thread) {
	sync.atomic_store(&r.stop, true)
	sync.sema_post(&r.released)
	thread.join(th)
	thread.destroy(th)
	worklet_realm_gone(r.w)
	worklet_release(r.w)
}

@(private = "file")
fake_render :: proc(g: ^Graph, frames: int) -> ^Pcm {
	p := pcm_new(g.channels, frames, g.rate)
	offline_render(g, p)
	return p
}

@(private = "file")
constant_into_worklet :: proc(g: ^Graph) -> (id: i32) {
	k := node_create(g, .Constant)
	node_start(g, k, 0, 0, -1)
	id = worklet_node_create(g, 1, 1, 0, 7, nil)
	connect(g, k, 0, id, 0)
	connect(g, id, 0, DESTINATION_ID, 0)
	return
}

@(private = "file")
count_events :: proc(g: ^Graph, type: Event_Type) -> int {
	events := take_events(g, context.temp_allocator)
	n := 0
	for e in events { if e.type == type { n += 1 } }
	return n
}

@(test)
a_processors_output_comes_back_into_the_graph :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	r := Fake_Realm{status = .Keep_Alive}
	th := fake_start(&r, g)
	defer fake_stop(&r, th)
	r.w.stall_limit = GENEROUS_LIMIT   // (this test is about the answers: a loaded machine may be late with its thread)
	constant_into_worklet(g)
	p := fake_render(g, RENDER_QUANTUM * 4)
	defer pcm_release(p)
	for s, i in pcm_channel(p, 0) { if s != FAKE_GAIN { testing.expectf(t, false, "frame %d: %v", i, s); break } }
	testing.expect_value(t, r.calls, 4)
}

@(test)
a_processor_that_returns_false_is_called_only_while_an_input_is_active :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	r := Fake_Realm{status = .Inactive}
	th := fake_start(&r, g)
	defer fake_stop(&r, th)
	id := worklet_node_create(g, 0, 1, 0, 1, nil)
	connect(g, id, 0, DESTINATION_ID, 0)
	p := fake_render(g, RENDER_QUANTUM * 4)
	defer pcm_release(p)
	testing.expect_value(t, r.calls, 1)
	testing.expect_value(t, count_events(g, .Worklet_Inactive), 1)
	free_all(context.temp_allocator)
}

@(test)
a_throw_in_process_is_silence_and_no_more_calls :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	r := Fake_Realm{status = .Keep_Alive, throw_at = 2}
	th := fake_start(&r, g)
	defer fake_stop(&r, th)
	r.w.stall_limit = GENEROUS_LIMIT
	constant_into_worklet(g)
	p := fake_render(g, RENDER_QUANTUM * 4)
	defer pcm_release(p)
	testing.expect_value(t, pcm_channel(p, 0)[0], FAKE_GAIN)
	testing.expect_value(t, pcm_channel(p, 0)[RENDER_QUANTUM * 3], 0)
	testing.expect_value(t, r.calls, 2)
}

@(test)
a_hung_realm_is_given_up_on_and_the_render_goes_on :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	r := Fake_Realm{status = .Keep_Alive}
	sync.atomic_store(&r.hang, true)
	th := fake_start(&r, g, STALL_LIMIT)
	defer fake_stop(&r, th)
	id := constant_into_worklet(g)
	start := time.tick_now()
	p := fake_render(g, RENDER_QUANTUM * 8)
	defer pcm_release(p)
	took := time.tick_since(start)
	testing.expectf(t, took < GENEROUS_LIMIT, "the render took %v", took)
	for s, i in pcm_channel(p, 0) { if s != 0 { testing.expectf(t, false, "frame %d: %v", i, s); break } }
	events := take_events(g, context.temp_allocator)
	stalled, errors := 0, 0
	for e in events {
		if e.type == .Worklet_Stalled { stalled += 1 }
		if e.type == .Worklet_Error && e.node == id { errors += 1 }
	}
	testing.expect_value(t, stalled, 1)
	testing.expect_value(t, errors, 1)
	free_all(context.temp_allocator)
}

@(test)
a_realm_that_is_gone_fires_the_error_once_and_gives_silence :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	w := worklet_attach(g, STALL_LIMIT)
	defer worklet_release(w)
	worklet_realm_gone(w)
	id := constant_into_worklet(g)
	p := fake_render(g, RENDER_QUANTUM * 4)
	defer pcm_release(p)
	for s, i in pcm_channel(p, 0) { if s != 0 { testing.expectf(t, false, "frame %d: %v", i, s); break } }
	events := take_events(g, context.temp_allocator)
	errors := 0
	for e in events { if e.type == .Worklet_Error && e.node == id { errors += 1 } }
	testing.expect_value(t, errors, 1)
	free_all(context.temp_allocator)
}

// (the worst case of a page closing: the render thread is inside its wait)
@(test)
stopping_a_context_does_not_wait_for_a_hung_realm :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	r := Fake_Realm{status = .Keep_Alive}
	sync.atomic_store(&r.hang, true)
	th := fake_start(&r, g)
	defer fake_stop(&r, th)
	sync.lock(&g.mu)
	r.w.stall_limit = GENEROUS_LIMIT
	sync.unlock(&g.mu)
	constant_into_worklet(g)
	testing.expect(t, offline_start(g, RENDER_QUANTUM * 100), "it starts")
	base.await(&r, proc(r: ^Fake_Realm) -> bool { return sync.atomic_load(&r.calls) != 0 })
	start := time.tick_now()
	graph_destroy(g)
	took := time.tick_since(start)
	testing.expectf(t, took < GENEROUS_LIMIT / 2, "the graph took %v to go", took)
}

@(test)
what_a_node_with_a_bad_number_of_ports_is_refused :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	testing.expect_value(t, worklet_node_create(g, 1, 1, 0, 1, nil), i32(-1))   // no realm yet
	w := worklet_attach(g, STALL_LIMIT)
	defer worklet_release(w)
	worklet_realm_gone(w)
	testing.expect_value(t, worklet_node_create(g, 0, 0, 0, 1, nil), i32(-1))
	testing.expect_value(t, worklet_node_create(g, WORKLET_MAX_PORTS + 1, 1, 0, 1, nil), i32(-1))
	bad := [1]i32{MAX_CHANNELS + 1}
	testing.expect_value(t, worklet_node_create(g, 1, 1, 0, 1, bad[:]), i32(-1))
	two := [2]i32{1, 1}
	testing.expect_value(t, worklet_node_create(g, 1, 1, 0, 1, two[:]), i32(-1))
	testing.expect(t, worklet_node_create(g, 1, 2, 3, 1, two[:]) > 0, "a good one")
}

@(test)
a_param_that_holds_gives_one_value :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	r := Fake_Realm{status = .Keep_Alive}
	th := fake_start(&r, g)
	defer fake_stop(&r, th)
	id := worklet_node_create(g, 1, 1, 1, 1, nil)
	worklet_param_init(g, id, 0, 3, 0, 10, true)
	testing.expect_value(t, param_get(g, id, 0), f64(3))
	connect(g, id, 0, DESTINATION_ID, 0)
	p := fake_render(g, RENDER_QUANTUM)
	defer pcm_release(p)
	testing.expect_value(t, r.calls, 1)
}
