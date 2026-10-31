package webaudio

// The graph of a context: its nodes (by id, what the page knows them by), who is connected to whom, the order they are
// processed in and one render quantum. Every procedure that is not marked otherwise takes Graph.mu itself; a page calls
// them from its thread, the render thread renders under the same lock, one quantum at a time.

import "base:runtime"
import "core:sync"
import "wb:base"

Kind :: enum i32 {
	Destination, Listener, Buffer_Source, Oscillator, Gain, Constant, Biquad, Delay, Stereo_Panner, Panner,
	Splitter, Merger, Compressor, Wave_Shaper, Analyser, Convolver, Script_Processor, Element_Source, IIR,
}

// The ids of the two nodes every graph has from the start.
DESTINATION_ID :: 0
LISTENER_ID :: 1

// Numbers of the fields of node_set / node_get (native/js/odin/web_audio.js has the same table).
Field :: enum i32 {
	Channel_Count, Channel_Mode, Channel_Interp,
	Loop, Loop_Start, Loop_End,
	Oscillator_Type, Filter_Type, Oversample,
	Fft_Size, Min_Decibels, Max_Decibels, Smoothing,
	Normalize,
	Panning_Model, Distance_Model, Ref_Distance, Max_Distance, Rolloff, Cone_Inner, Cone_Outer, Cone_Outer_Gain,
	Reduction,
}

Conn :: struct { node: ^Node, output: int }

// An edge seen from its source, to take it away from the other end.
Out_Edge :: struct { node: ^Node, input: int, param: int, output: int }   // param -1: the edge goes to an input

Input :: struct {
	conns: [dynamic]Conn,
	mix:   Bus,
}

Node :: struct {
	g:        ^Graph,
	id:       i32,
	kind:     Kind,
	released: bool,                // the page's object is gone: nothing can start it or connect to it any more
	inputs:   []Input,
	outputs:  []Bus,
	outs:     [dynamic]Out_Edge,
	channel_count: int,
	mode:     Channel_Mode,
	interp:   Channel_Interp,
	params:   []Param,
	sched:    Schedule,
	data:     Node_Data,
	mark:     u8,                  // of the walk that orders the graph
	deps:     [dynamic]^Node,      // of the same
	in_cycle: bool,                // a DelayNode that closes a cycle: read before its inputs are known, written after
	muted:    bool,                // in a cycle without a delay: silent (the specification)
	active_until: i64,             // the frame its tail lasts to, once its input has gone
}

// What a scheduled source was told.
Schedule :: struct {
	start, stop: f64,
	started:     bool,    // start() was called
	stop_set:    bool,
	finished:    bool,
	ended_sent:  bool,
}

Graph_State :: enum i32 { Suspended, Running, Closed }

Event_Type :: enum i32 { State_Changed = 1, Ended = 2, Script_Block = 3, Offline_Suspended = 4 }

Event :: struct { type: Event_Type, node, value: i32 }

Graph :: struct {
	mu:        sync.Mutex,
	rate:      f64,
	frame:     i64,                // the next frame to render: currentTime
	channels:  int,                // of the destination
	state:     Graph_State,
	offline:   bool,
	nodes:     [dynamic]^Node,     // by id; nil once removed
	free_ids:  [dynamic]i32,
	order:     [dynamic]^Node,
	order_dirty, sweep_due: bool,
	delayed:   [dynamic]^Node,     // DelayNodes in cycles, written at the end of the quantum
	walk:      [dynamic]Walk_Step,
	events:    [dynamic]Event,
	notify:    proc(user: rawptr), // an event is waiting (any thread); nil: nobody asks
	notify_user: rawptr,
	notified:  bool,
	basic:     [Oscillator_Type]^Wave,   // the tables of the basic types, made when first used
	output:    Bus,                // what the last quantum gave the destination
	listener:  ^Node,
	// the thread (render.odin)
	thread:    Render_Thread,
}

alloc :: #force_inline proc "contextless" () -> runtime.Allocator { return base.process_allocator() }

graph_new :: proc(rate: f64, channels: int, offline: bool) -> ^Graph {
	context.allocator = alloc()
	g := new(Graph)
	g.rate, g.channels, g.offline = rate, channels, offline
	dst := add_node(g, .Destination, 1, 1)
	dst.channel_count = channels
	dst.mode = .Explicit
	lst := add_node(g, .Listener, 0, 0)
	g.listener = lst
	params_listener(lst)
	return g
}

graph_destroy :: proc(g: ^Graph) {
	context.allocator = alloc()
	thread_stop(g)
	for n in g.nodes { if n != nil { node_destroy(n) } }
	delete(g.nodes)
	delete(g.free_ids)
	delete(g.order)
	delete(g.delayed)
	delete(g.walk)
	delete(g.events)
	for w in g.basic { wave_release(w) }
	bus_destroy(&g.output)
	free(g)
}

@(private)
add_node :: proc(g: ^Graph, kind: Kind, inputs, outputs: int) -> ^Node {
	n := new(Node)
	n.g, n.kind = g, kind
	if len(g.free_ids) > 0 {
		n.id = pop(&g.free_ids)
		g.nodes[n.id] = n
	} else {
		n.id = i32(len(g.nodes))
		append(&g.nodes, n)
	}
	n.inputs, n.outputs = make([]Input, inputs), make([]Bus, outputs)
	for &o in n.outputs { bus_clear(&o, 1) }
	n.channel_count = 2
	n.active_until = -1
	g.order_dirty = true
	return n
}

// (the lock held) Takes a node out of the graph and frees it.
@(private)
node_remove :: proc(n: ^Node) {
	g := n.g
	// what feeds it
	for &in_put, i in n.inputs {
		for c in in_put.conns { drop_out_edge(c.node, c.output, n, i, -1) }
	}
	for &p, pi in n.params {
		for c in p.inputs { drop_out_edge(c.node, c.output, n, 0, pi) }
	}
	// what it feeds
	for e in n.outs {
		if e.param >= 0 {
			drop_conn(&e.node.params[e.param].inputs, n, e.output)
		} else {
			drop_conn(&e.node.inputs[e.input].conns, n, e.output)
		}
	}
	g.nodes[n.id] = nil
	append(&g.free_ids, n.id)
	g.order_dirty = true
	node_destroy(n)
}

@(private)
node_destroy :: proc(n: ^Node) {
	for &in_put in n.inputs { delete(in_put.conns); bus_destroy(&in_put.mix) }
	delete(n.inputs)
	for &o in n.outputs { bus_destroy(&o) }
	delete(n.outputs)
	delete(n.outs)
	for &p in n.params { param_destroy(&p) }
	delete(n.params)
	delete(n.deps)
	node_data_destroy(n)
	free(n)
}

@(private)
drop_conn :: proc(conns: ^[dynamic]Conn, node: ^Node, output: int) -> bool {
	for c, i in conns {
		if c.node == node && c.output == output { unordered_remove(conns, i); return true }
	}
	return false
}

@(private)
drop_out_edge :: proc(from: ^Node, output: int, to: ^Node, input, param: int) {
	for e, i in from.outs {
		if e.node == to && e.output == output && e.input == input && e.param == param { unordered_remove(&from.outs, i); return }
	}
}

node_of :: #force_inline proc "contextless" (g: ^Graph, id: i32) -> ^Node {
	if id < 0 || int(id) >= len(g.nodes) { return nil }
	return g.nodes[id]
}

// A new node of a kind; a and b: what its kind needs at creation (see node_init). -1: refused.
node_create :: proc(g: ^Graph, kind: Kind, a: f64 = 0, b: f64 = 0) -> i32 {
	context.allocator = alloc()
	sync.guard(&g.mu)
	if kind == .Destination || kind == .Listener { return -1 }
	n := node_init(g, kind, a, b)
	return n != nil ? n.id : -1
}

// The page's object of a node is gone. It leaves the graph once nothing can come out of it any more (node_sweep).
node_release :: proc(g: ^Graph, id: i32) {
	context.allocator = alloc()
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return }
	n.released = true
	g.sweep_due = true
}

// The connection already there is kept (the specification: connecting twice changes nothing).
connect :: proc(g: ^Graph, from: i32, output: int, to: i32, input: int) -> bool {
	context.allocator = alloc()
	sync.guard(&g.mu)
	a, b := node_of(g, from), node_of(g, to)
	if a == nil || b == nil || output >= len(a.outputs) || input >= len(b.inputs) { return false }
	for c in b.inputs[input].conns { if c.node == a && c.output == output { return true } }
	append(&b.inputs[input].conns, Conn{a, output})
	append(&a.outs, Out_Edge{b, input, -1, output})
	g.order_dirty = true
	return true
}

connect_param :: proc(g: ^Graph, from: i32, output: int, to: i32, param: int) -> bool {
	context.allocator = alloc()
	sync.guard(&g.mu)
	a, b := node_of(g, from), node_of(g, to)
	if a == nil || b == nil || output >= len(a.outputs) || param >= len(b.params) { return false }
	for c in b.params[param].inputs { if c.node == a && c.output == output { return true } }
	append(&b.params[param].inputs, Conn{a, output})
	append(&a.outs, Out_Edge{b, 0, param, output})
	g.order_dirty = true
	return true
}

// disconnect(), in all its forms: -1 means "any" for output, to and input. `param`: the target is a param (`input` is its
// index). The number of connections that went.
disconnect :: proc(g: ^Graph, from: i32, output: int, to: i32, input: int, param: bool) -> int {
	context.allocator = alloc()
	sync.guard(&g.mu)
	a := node_of(g, from)
	if a == nil { return 0 }
	removed := 0
	#reverse for e, i in a.outs {
		if output >= 0 && e.output != output { continue }
		if to >= 0 {
			if e.node.id != to || (e.param >= 0) != param { continue }
			if input >= 0 && (param ? e.param : e.input) != input { continue }
		}
		if e.param >= 0 {
			drop_conn(&e.node.params[e.param].inputs, a, e.output)
		} else {
			drop_conn(&e.node.inputs[e.input].conns, a, e.output)
		}
		unordered_remove(&a.outs, i)
		removed += 1
	}
	if removed > 0 {
		g.order_dirty = true
		g.sweep_due = true
	}
	return removed
}

// An event for the page (the lock held).
post_event :: proc(g: ^Graph, type: Event_Type, node, value: i32) {
	append(&g.events, Event{type, node, value})
	if !g.notified && g.notify != nil {
		g.notified = true
		g.notify(g.notify_user)
	}
}

// The page takes the events waiting (the caller deletes the result).
take_events :: proc(g: ^Graph, allocator := context.allocator) -> []Event {
	context.allocator = alloc()
	sync.guard(&g.mu)
	g.notified = false
	out := make([]Event, len(g.events), allocator)
	copy(out, g.events[:])
	clear(&g.events)
	return out
}

// ---- the order of processing ----

Walk_Step :: struct { node: ^Node, next: int }

@(private = "file") MARK_NONE :: 0
@(private = "file") MARK_OPEN :: 1
@(private = "file") MARK_DONE :: 2

// What a node needs before it runs. (A DelayNode that closes a cycle does not need its input.)
@(private = "file")
gather_deps :: proc(n: ^Node) {
	clear(&n.deps)
	if !n.in_cycle {
		for &in_put in n.inputs { for c in in_put.conns { append(&n.deps, c.node) } }
	}
	for &p in n.params { for c in p.inputs { append(&n.deps, c.node) } }
	if n.kind == .Panner { append(&n.deps, n.g.listener) }
}

// Orders the nodes so that each comes after what feeds it, every node included: a source with nowhere to go still
// plays and ends, an analyser still listens. A cycle goes through a DelayNode, read at its turn and written at the end
// (it then delays by at least a quantum), or it is muted.
@(private = "file")
order_graph :: proc(g: ^Graph) {
	for n in g.nodes { if n != nil { n.in_cycle = false; n.muted = false } }
	again := true
	for again {
		again = false
		clear(&g.order)
		for n in g.nodes { if n != nil { n.mark = MARK_NONE; gather_deps(n) } }
		walking: for root in g.nodes {
			if root == nil || root.mark != MARK_NONE { continue }
			clear(&g.walk)
			append(&g.walk, Walk_Step{root, 0})
			root.mark = MARK_OPEN
			for len(g.walk) > 0 {
				top := &g.walk[len(g.walk) - 1]
				if top.next >= len(top.node.deps) {
					top.node.mark = MARK_DONE
					append(&g.order, top.node)
					pop(&g.walk)
					continue
				}
				dep := top.node.deps[top.next]
				top.next += 1
				if dep.mark == MARK_NONE {
					dep.mark = MARK_OPEN
					append(&g.walk, Walk_Step{dep, 0})
				} else if dep.mark == MARK_OPEN {
					// a cycle: from `dep` to the top of the walk
					first := 0
					for s, i in g.walk { if s.node == dep { first = i; break } }
					delay: ^Node
					for s in g.walk[first:] { if s.node.kind == .Delay && !s.node.in_cycle { delay = s.node; break } }
					if delay != nil {
						delay.in_cycle = true
						again = true
						break walking
					}
					for s in g.walk[first:] { s.node.muted = true }
				}
			}
		}
	}
	clear(&g.delayed)
	for n in g.nodes { if n != nil && n.in_cycle { append(&g.delayed, n) } }
	g.order_dirty = false
}

// Nodes the page has let go of and that can give nothing any more (no input, no source at work, the tail over).
@(private = "file")
node_sweep :: proc(g: ^Graph) {
	g.sweep_due = false
	again := true
	for again {
		again = false
		for n in g.nodes {
			if n == nil || !n.released { continue }
			if node_has_feed(n) { continue }
			if node_source_alive(n) { continue }
			if n.active_until >= g.frame { g.sweep_due = true; continue }
			node_remove(n)
			again = true
		}
	}
}

@(private = "file")
node_has_feed :: proc(n: ^Node) -> bool {
	for &in_put in n.inputs { if len(in_put.conns) > 0 { return true } }
	for &p in n.params { if len(p.inputs) > 0 { return true } }
	return false
}

// (the lock held) One quantum into the nodes; the destination's block is in g.output afterwards.
render_quantum :: proc(g: ^Graph) {
	context.allocator = alloc()
	if g.order_dirty { order_graph(g) }
	for n in g.order { node_process(g, n) }
	for n in g.delayed { delay_write(n) }
	dst := g.nodes[DESTINATION_ID]
	bus_copy(&g.output, &dst.inputs[0].mix)
	g.frame += RENDER_QUANTUM
	if g.sweep_due { node_sweep(g) }
}

// Mixes what comes to an input, by its node's channel rules.
@(private = "file")
mix_input :: proc(n: ^Node, in_put: ^Input) {
	channels := 0
	switch n.mode {
	case .Explicit:
		channels = n.channel_count
	case .Max, .Clamped_Max:
		for c in in_put.conns { channels = max(channels, c.node.outputs[c.output].channels) }
		channels = max(channels, 1)
		if n.mode == .Clamped_Max { channels = min(channels, n.channel_count) }
	}
	bus_clear(&in_put.mix, channels)
	for c in in_put.conns { bus_sum(&in_put.mix, &c.node.outputs[c.output], n.interp) }
}

@(private = "file")
mix_param :: proc(p: ^Param) {
	if len(p.inputs) == 0 { p.mix.silent = true; return }
	bus_clear(&p.mix, 1)
	for c in p.inputs { bus_sum(&p.mix, &c.node.outputs[c.output], .Speakers) }
}

// One node, one quantum.
@(private = "file")
node_process :: proc(g: ^Graph, n: ^Node) {
	if !n.in_cycle {
		for &in_put in n.inputs { mix_input(n, &in_put) }
	}
	for &p in n.params {
		param_advance(&p, g.frame, g.rate)
		mix_param(&p)
		param_finish(&p)
	}
	if n.muted {
		for &o in n.outputs { bus_clear(&o, max(o.channels, 1)) }
		return
	}
	node_run(g, n)
}

// The node with its inputs mixed at the end of the quantum (a DelayNode of a cycle).
@(private = "file")
delay_write :: proc(n: ^Node) {
	for &in_put in n.inputs { mix_input(n, &in_put) }
	delay_store(n)
}
