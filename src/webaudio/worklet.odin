package webaudio

// AudioWorkletNode's side of the render graph. The processors run in a realm on a thread of their own (a Wasm instance the
// render thread cannot read): a node's quantum is a request to that thread, and the render thread waits for the answer with
// a deadline. An answer that does not come in time is silence, and the realm catches up by itself: only the latest request
// waits to be taken, what it is working on when the next quantum comes is let run, and its result is dropped.
//
//   render thread                     Worklet (one per context)            the realm's thread
//   worklet_run: input, params   ->   layout + samples, pending = true  -> worklet_take: running = true
//   (waits, Graph.mu released)                                             JavaScript: read, process(), write
//   output, or silence           <-   status, done = its number         <- worklet_finish: running = false
//
// layout and samples belong to whoever `running` says: nobody else looks at them. Nothing here allocates once the buffers
// have the size of the channels in use, and the render thread never holds Worklet.mu while it waits: a realm that hangs, or
// is gone, cannot hang the thread or the page. A realm that stays busy past the limit is given up on: Worklet_Stalled tells
// the page, which stops it (its nodes then fire processorerror).

import "core:sync"
import "core:time"

// What a realtime quantum waits for the realm: half of what is queued ahead of the device, within these bounds.
WORKLET_DEADLINE_MIN :: 5 * time.Millisecond
WORKLET_DEADLINE_MAX :: 100 * time.Millisecond
// The inputs and outputs a node may have, and the params: what the realm's copy per quantum stays bounded by.
WORKLET_MAX_PORTS :: 256
WORKLET_MAX_PARAMS :: 1024
// layout: what comes before the counts (the processor, then the numbers of inputs, outputs and params).
WORKLET_LAYOUT_HEADER :: 4

// How a process() call went (native/js/odin/web_audio_worklet.js has the same table).
Worklet_Status :: enum i32 {
	Keep_Alive,   // it returned true
	Inactive,     // it returned false: called again only while an input is active
	Failed,       // it threw: silent from now on (the realm told the page, with what it threw)
	Not_Ready,    // no processor yet (its constructor has not run, or threw)
	None,         // no answer
}

Worklet :: struct {
	refs:      i32,          // atomic
	mu:        sync.Mutex,
	cond:      sync.Cond,    // an answer, or the realm gone
	wake:      proc(user: rawptr),   // the realm has work; nil once it is gone
	wake_user: rawptr,
	rate:      f64,
	stall_limit: time.Duration,
	dead:      bool,         // the realm is gone, or was given up on
	pending, running: bool,
	missed:    bool,         // an answer was late: quanta do not wait until the realm has caught up
	sent, done: u64,         // numbers of requests: the last one made, the last one answered
	checkpoint: bool,        // a quantum ended: the realm runs its microtasks (the specification: after all its processors)
	quantum_sent: u64,       // `sent` when the last quantum ended
	taken:     u64,          // of the one running
	status:    Worklet_Status,
	stalled_at: time.Tick,   // when the realm first failed to answer (0: it answers)
	stall_told: bool,
	processor: i32,
	frame:     i64,
	layout:    [dynamic]i32,
	samples:   [dynamic]f32,
	dropped:   [dynamic]i32, // processors whose nodes left the graph
}

Worklet_Data :: struct {
	processor:   i32,
	output_channels: []i32,   // by output; 0: the rule of the specification
	keep_alive:  bool,        // the active source flag
	failed:      bool,
	told_inactive: bool,
}

// A context's worklet: one reference for the graph, one for the caller.
worklet_attach :: proc(g: ^Graph, stall_limit: time.Duration) -> ^Worklet {
	context.allocator = alloc()
	sync.guard(&g.mu)
	if g.worklet != nil { return nil }
	w := new(Worklet)
	w.refs = 2
	w.rate = g.rate
	w.stall_limit = stall_limit
	g.worklet = w
	return w
}

worklet_retain :: proc(w: ^Worklet) { sync.atomic_add(&w.refs, 1) }

worklet_release :: proc(w: ^Worklet) {
	if w == nil || sync.atomic_sub(&w.refs, 1) != 1 { return }
	context.allocator = alloc()
	delete(w.layout)
	delete(w.samples)
	delete(w.dropped)
	free(w)
}

// A new node for a registered processor. -1: refused.
worklet_node_create :: proc(g: ^Graph, inputs, outputs, params: int, processor: i32, output_channels: []i32) -> i32 {
	context.allocator = alloc()
	sync.guard(&g.mu)
	if g.worklet == nil || inputs < 0 || outputs < 0 || (inputs == 0 && outputs == 0) { return -1 }
	if inputs > WORKLET_MAX_PORTS || outputs > WORKLET_MAX_PORTS || params < 0 || params > WORKLET_MAX_PARAMS { return -1 }
	if len(output_channels) != 0 && len(output_channels) != outputs { return -1 }
	for c in output_channels { if c < 1 || c > MAX_CHANNELS { return -1 } }
	n := add_node(g, .Worklet, inputs, outputs)
	d := new(Worklet_Data)
	d.processor, d.keep_alive = processor, true
	d.output_channels = make([]i32, outputs)
	copy(d.output_channels, output_channels)
	n.data = d
	n.params = make([]Param, params)
	for &p in n.params { param_init(&p, 0, -PARAM_MAX, PARAM_MAX, true) }
	return n.id
}

// What a registered parameter is (AudioParamDescriptor).
worklet_param_init :: proc(g: ^Graph, id: i32, index: int, default_value, min_value, max_value: f32, a_rate: bool) {
	sync.guard(&g.mu)
	if p := param_of(g, id, index); p != nil { param_init(p, default_value, min_value, max_value, a_rate) }
}

// (the lock held: from node_destroy) The realm forgets the processor of a node that left the graph.
worklet_data_destroy :: proc(g: ^Graph, d: ^Worklet_Data) {
	if w := g.worklet; w != nil {
		sync.lock(&w.mu)
		if !w.dead {
			append(&w.dropped, d.processor)
			if w.wake != nil { w.wake(w.wake_user) }
		}
		sync.unlock(&w.mu)
	}
	delete(d.output_channels)
	free(d)
}

// The channels an output gives: what the page asked for, the input's with one input and one output, else one.
@(private = "file")
worklet_output_channels :: proc(n: ^Node, d: ^Worklet_Data, output: int) -> int {
	if c := d.output_channels[output]; c > 0 { return int(c) }
	if len(n.inputs) == 1 && len(n.outputs) == 1 && !n.inputs[0].mix.silent { return max(n.inputs[0].mix.channels, 1) }
	return 1
}

@(private = "file")
worklet_silence :: proc(n: ^Node, d: ^Worklet_Data) {
	for &o, i in n.outputs { bus_clear(&o, worklet_output_channels(n, d, i)) }
}

// The values a param gives the realm: one when it holds for the whole quantum (the specification's size 1).
@(private = "file")
worklet_param_length :: proc(p: ^Param) -> int {
	if !p.varying { return 1 }
	for v in p.values[1:] { if v != p.values[0] { return RENDER_QUANTUM } }
	return 1
}

// (Graph.mu held, the realm not running) One request: the node's inputs and params as the realm will read them.
@(private = "file")
worklet_request :: proc(g: ^Graph, n: ^Node, d: ^Worklet_Data, w: ^Worklet) {
	resize(&w.layout, WORKLET_LAYOUT_HEADER + len(n.inputs) + len(n.outputs) + len(n.params))
	w.layout[0], w.layout[1], w.layout[2], w.layout[3] = d.processor, i32(len(n.inputs)), i32(len(n.outputs)), i32(len(n.params))
	total := 0
	at := WORKLET_LAYOUT_HEADER
	for &in_put in n.inputs {
		// (an input with nothing at work reads as no channels: the specification's "actively processing")
		c := in_put.mix.silent ? 0 : in_put.mix.channels
		w.layout[at] = i32(c)
		at += 1
		total += c * RENDER_QUANTUM
	}
	for &p in n.params {
		c := worklet_param_length(&p)
		w.layout[at] = i32(c)
		at += 1
		total += c
	}
	for _, i in n.outputs {
		c := worklet_output_channels(n, d, i)
		w.layout[at] = i32(c)
		at += 1
		total += c * RENDER_QUANTUM
	}
	if total > len(w.samples) { resize(&w.samples, total) }
	pos := 0
	for &in_put in n.inputs {
		if in_put.mix.silent { continue }
		count := in_put.mix.channels * RENDER_QUANTUM
		copy(w.samples[pos:][:count], in_put.mix.data[:count])
		pos += count
	}
	for &p in n.params {
		count := worklet_param_length(&p)
		copy(w.samples[pos:][:count], p.values[:count])
		pos += count
	}
	w.processor, w.frame = d.processor, g.frame
}

// (Graph.mu held) What the node's outputs got from the realm.
@(private = "file")
worklet_read_outputs :: proc(n: ^Node, d: ^Worklet_Data, w: ^Worklet) {
	pos := 0
	for &in_put in n.inputs { if !in_put.mix.silent { pos += in_put.mix.channels * RENDER_QUANTUM } }
	for &p in n.params { pos += worklet_param_length(&p) }
	for &o, i in n.outputs {
		c := int(w.layout[WORKLET_LAYOUT_HEADER + len(n.inputs) + len(n.params) + i])
		bus_prepare(&o, c)
		count := c * RENDER_QUANTUM
		copy(o.data[:count], w.samples[pos:][:count])
		pos += count
	}
}

// (Graph.mu held) Past the limit without an answer: the realm is given up on, and the page told.
@(private = "file")
worklet_note_miss :: proc(g: ^Graph, w: ^Worklet) {
	w.missed = true
	if w.stalled_at == {} { w.stalled_at = time.tick_now(); return }
	if time.tick_since(w.stalled_at) >= w.stall_limit { worklet_give_up(g, w) }
}

@(private = "file")
worklet_give_up :: proc(g: ^Graph, w: ^Worklet) {
	w.dead = true
	sync.cond_broadcast(&w.cond)
	if !w.stall_told {
		w.stall_told = true
		post_event(g, .Worklet_Stalled, 0, 0)
	}
}

// (Graph.mu held) One quantum of a node. The lock is let go while it waits, as ScriptProcessorNode's offline wait does: the
// page keeps working on the graph. Nothing it does there takes this node away, only the render thread removes nodes.
worklet_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Worklet_Data)
	w := g.worklet
	// the realm is gone: what it was running is lost, and the page hears of it once
	sync.lock(&w.mu)
	dead := w.dead
	sync.unlock(&w.mu)
	if dead {
		if !d.failed {
			d.failed = true
			post_event(g, .Worklet_Error, n.id, 0)
		}
		worklet_silence(n, d)
		return
	}
	input_active := false
	for &in_put in n.inputs { if !in_put.mix.silent { input_active = true } }
	if d.failed || (!d.keep_alive && !input_active) {
		worklet_silence(n, d)
		return
	}
	sync.lock(&w.mu)
	if w.missed && !w.running && !w.pending && w.done == w.sent { w.missed = false }   // caught up
	if w.running {
		// still at an old quantum: this one is silence, at once
		worklet_note_miss(g, w)
		sync.unlock(&w.mu)
		worklet_silence(n, d)
		return
	}
	worklet_request(g, n, d, w)
	w.sent += 1
	w.pending = true
	number := w.sent
	if w.wake != nil { w.wake(w.wake_user) }
	if w.missed {
		// (late already: the request stays for the realm, a later quantum replaces it if it is not taken)
		worklet_note_miss(g, w)
		sync.unlock(&w.mu)
		worklet_silence(n, d)
		return
	}
	sync.unlock(&g.mu)
	limit := g.offline ? w.stall_limit : clamp(time.Duration(f64(g.thread.latency) / g.rate / 2 * f64(time.Second)), WORKLET_DEADLINE_MIN, WORKLET_DEADLINE_MAX)
	start := time.tick_now()
	answered := false
	for {
		if w.done == number && !w.running { answered = true; break }
		if w.dead || sync.atomic_load(&g.thread.quit) { break }
		left := limit - time.tick_since(start)
		if left <= 0 { break }
		sync.cond_wait_with_timeout(&w.cond, &w.mu, left)
	}
	status := answered ? w.status : Worklet_Status.None
	if answered { w.stalled_at = {} }
	sync.unlock(&w.mu)
	sync.lock(&g.mu)
	switch status {
	case .Keep_Alive, .Inactive:
		// (the page's thread does not touch the buffers, and the next request is this thread's)
		worklet_read_outputs(n, d, w)
		d.keep_alive = status == .Keep_Alive
		if !d.keep_alive && !d.told_inactive {
			d.told_inactive = true
			post_event(g, .Worklet_Inactive, n.id, 0)
		}
		if d.keep_alive { d.told_inactive = false }
		g.sweep_due = true
	case .Failed:
		d.failed = true
		g.sweep_due = true
		worklet_silence(n, d)
	case .Not_Ready:
		worklet_silence(n, d)
	case .None:
		sync.lock(&w.mu)
		if w.stalled_at == {} { w.stalled_at = start }   // (it has not answered since this wait began)
		worklet_note_miss(g, w)
		sync.unlock(&w.mu)
		worklet_silence(n, d)
	}
}

// A processor at work has something to give after its input has gone.
worklet_alive :: proc(d: ^Worklet_Data) -> bool { return d.keep_alive && !d.failed }

// ---- the realm's thread ----

// The realm starts: how it is told there is work. It calls worklet_realm_gone when it stops.
worklet_realm_attach :: proc(w: ^Worklet, wake: proc(user: rawptr), user: rawptr) {
	sync.guard(&w.mu)
	w.wake, w.wake_user = wake, user
}

// The realm's thread is stopping (a trap, terminate, the page closing): no answer will come. Any thread may look at dead.
worklet_realm_gone :: proc(w: ^Worklet) {
	sync.guard(&w.mu)
	w.wake, w.wake_user = nil, nil
	w.dead = true
	w.running = false
	sync.cond_broadcast(&w.cond)
}

// The graph goes: the render thread has stopped, and the realm has no one to answer.
worklet_graph_gone :: proc(g: ^Graph) {
	w := g.worklet
	if w == nil { return }
	g.worklet = nil
	sync.lock(&w.mu)
	w.dead = true
	sync.cond_broadcast(&w.cond)
	sync.unlock(&w.mu)
	worklet_release(w)
}

// Wakes a render thread that waits for the realm, when the context stops.
worklet_interrupt :: proc(g: ^Graph) {
	w := g.worklet
	if w == nil { return }
	sync.guard(&w.mu)
	sync.cond_broadcast(&w.cond)
}

// (Graph.mu held) A quantum ended: if the realm worked in it, its microtasks run before the next one.
worklet_quantum_end :: proc(w: ^Worklet) {
	sync.guard(&w.mu)
	if w.quantum_sent == w.sent { return }
	w.quantum_sent = w.sent
	w.checkpoint = true
	if w.wake != nil { w.wake(w.wake_user) }
}

// A request waits, or processors were dropped: the realm's thread calls into its JavaScript.
worklet_has_work :: proc(w: ^Worklet) -> bool {
	sync.guard(&w.mu)
	return (w.pending || len(w.dropped) > 0) && !w.dead
}

// The realm asks whether a quantum has ended since it last asked.
worklet_take_checkpoint :: proc(w: ^Worklet) -> bool {
	sync.guard(&w.mu)
	due := w.checkpoint
	w.checkpoint = false
	return due
}

// The realm takes the waiting request. false: none (a later quantum may have nothing for it).
worklet_take :: proc(w: ^Worklet) -> bool {
	sync.guard(&w.mu)
	if !w.pending || w.dead { return false }
	w.pending, w.running = false, true
	w.taken = w.sent
	return true
}

// The layout of the request taken, into `out`: the number of values there are (more than len(out): nothing was written).
worklet_layout :: proc(w: ^Worklet, out: []i32) -> int {
	if !w.running { return 0 }
	n := len(w.layout)
	if n <= len(out) { copy(out, w.layout[:]) }
	return n
}

worklet_frame :: proc(w: ^Worklet) -> i64 { return w.frame }

// The samples of the request taken, from `at` on (in samples): input and params to the realm, outputs from it.
worklet_read :: proc(w: ^Worklet, at: int, out: []f32) {
	if !w.running || at < 0 || at + len(out) > len(w.samples) { return }
	copy(out, w.samples[at:][:len(out)])
}

worklet_write :: proc(w: ^Worklet, at: int, values: []f32) {
	if !w.running || at < 0 || at + len(values) > len(w.samples) { return }
	copy(w.samples[at:][:len(values)], values)
}

// The answer of the request taken. The render thread reads the buffers from here on.
worklet_finish :: proc(w: ^Worklet, status: Worklet_Status) {
	sync.guard(&w.mu)
	if !w.running { return }
	w.running = false
	w.status = status
	w.done = w.taken
	sync.cond_broadcast(&w.cond)
}

// A processor that left the graph, -1 when none is left to tell.
worklet_take_dropped :: proc(w: ^Worklet) -> i32 {
	sync.guard(&w.mu)
	if len(w.dropped) == 0 { return -1 }
	return pop(&w.dropped)
}

worklet_dead :: proc(w: ^Worklet) -> bool {
	sync.guard(&w.mu)
	return w.dead
}
