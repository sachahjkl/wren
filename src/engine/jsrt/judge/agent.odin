package jsrt_judge

// $262.agent for the Atomics tests: every agent is a thread with its own Runtime (as run-test262.c does).
// SharedArrayBuffer memory is shared by pointer (jsrt.shared_buffer_attach), and Atomics.wait/notify go
// through the Host_Config hooks onto one process-wide waiter list.

import "base:intrinsics"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import js "wb:engine/jsrt"

Agent :: struct {
	thread:      ^thread.Thread,
	source:      string,
	pending:     bool, // a broadcast waits to be picked up
	bc_data:     [^]u8,
	bc_length:   int,
	bc_max:      int,
	leaving:     bool,
}

Waiter :: struct {
	addr:     rawptr,
	cond:     sync.Cond,
	notified: bool,
}

Agent_State :: struct {
	mutex:    sync.Mutex,
	cond:     sync.Cond, // broadcast posted / picked up, shutdown
	agents:   [dynamic]^Agent,
	reports:  [dynamic]string,
	waiters:  [dynamic]^Waiter,
	shutdown: bool,
}

agent_state: Agent_State

agent_load :: proc(addr: rawptr, size: int) -> u64 {
	switch size {
	case 1: return u64(intrinsics.atomic_load((^u8)(addr)))
	case 2: return u64(intrinsics.atomic_load((^u16)(addr)))
	case 4: return u64(intrinsics.atomic_load((^u32)(addr)))
	}
	return intrinsics.atomic_load((^u64)(addr))
}

// Atomics.wait: compare and enqueue under the one mutex, so a notify cannot slip in between.
agent_wait :: proc(user: rawptr, addr: rawptr, size: int, expected: u64, timeout_ms: f64) -> js.Wait_Result {
	g := &agent_state
	sync.mutex_lock(&g.mutex)
	defer sync.mutex_unlock(&g.mutex)
	if agent_load(addr, size) != expected {return .not_equal}
	w := Waiter{addr = addr}
	append(&g.waiters, &w)
	start := time.tick_now()
	forever := timeout_ms > 1e15
	for !w.notified {
		if forever {
			sync.cond_wait(&w.cond, &g.mutex)
			continue
		}
		left := time.Duration(timeout_ms * f64(time.Millisecond)) - time.tick_since(start)
		if left <= 0 {break}
		sync.cond_wait_with_timeout(&w.cond, &g.mutex, left)
	}
	for x, i in g.waiters {
		if x == &w {
			ordered_remove(&g.waiters, i)
			break
		}
	}
	return w.notified ? .ok : .timed_out
}

agent_notify :: proc(user: rawptr, addr: rawptr, count: f64) -> int {
	g := &agent_state
	sync.mutex_lock(&g.mutex)
	defer sync.mutex_unlock(&g.mutex)
	n := 0
	for w in g.waiters {
		if f64(n) >= count {break}
		if w.addr == addr && !w.notified {
			w.notified = true
			sync.cond_signal(&w.cond)
			n += 1
		}
	}
	return n
}

agent_hooks :: proc(cfg: ^js.Host_Config) {
	cfg.atomics_wait = agent_wait
	cfg.atomics_notify = agent_notify
}

agent_start :: proc(source: string) {
	g := &agent_state
	a := new(Agent)
	a.source = strings.clone(source)
	sync.mutex_lock(&g.mutex)
	append(&g.agents, a)
	sync.mutex_unlock(&g.mutex)
	a.thread = thread.create_and_start_with_data(a, agent_main)
}

agent_broadcast :: proc(data: [^]u8, length, max_length: int) {
	g := &agent_state
	sync.mutex_lock(&g.mutex)
	defer sync.mutex_unlock(&g.mutex)
	for a in g.agents {
		a.pending = true
		a.bc_data = data
		a.bc_length = length
		a.bc_max = max_length
	}
	sync.cond_broadcast(&g.cond)
	// wait until every agent has picked the broadcast up
	for {
		all := true
		for a in g.agents {
			if a.pending && !a.leaving {all = false}
		}
		if all || g.shutdown {break}
		sync.cond_wait_with_timeout(&g.cond, &g.mutex, 20 * time.Millisecond)
	}
}

agent_report :: proc(text: string) {
	g := &agent_state
	sync.mutex_lock(&g.mutex)
	append(&g.reports, strings.clone(text))
	sync.mutex_unlock(&g.mutex)
}

agent_get_report :: proc() -> (string, bool) {
	g := &agent_state
	sync.mutex_lock(&g.mutex)
	defer sync.mutex_unlock(&g.mutex)
	if len(g.reports) == 0 {return "", false}
	s := g.reports[0]
	ordered_remove(&g.reports, 0)
	return s, true
}

// End of a test: stop every agent thread, wake the ones blocked in Atomics.wait, and reset the state.
agent_stop_all :: proc() {
	g := &agent_state
	sync.mutex_lock(&g.mutex)
	if len(g.agents) == 0 {
		sync.mutex_unlock(&g.mutex)
		return
	}
	g.shutdown = true
	for w in g.waiters {
		w.notified = true
		sync.cond_signal(&w.cond)
	}
	sync.cond_broadcast(&g.cond)
	agents := g.agents
	sync.mutex_unlock(&g.mutex)
	for a in agents {
		thread.join(a.thread)
		thread.destroy(a.thread)
		delete(a.source)
		free(a)
	}
	sync.mutex_lock(&g.mutex)
	delete(g.agents)
	g.agents = nil
	for r in g.reports {delete(r)}
	clear(&g.reports)
	g.shutdown = false
	sync.mutex_unlock(&g.mutex)
}

agent_main :: proc(data: rawptr) {
	a := cast(^Agent)data
	g := &agent_state
	h := new(Host)
	h.test_path = "<agent>"
	h.agent = a
	h.deadline = time.tick_add(time.tick_now(), 20 * time.Second)
	h.can_block = true
	strings.builder_init(&h.output)
	cfgr := js.DEFAULT_CONFIG
	cfgr.compile = compile_hook()
	cfgr.max_stack_bytes = 512 << 10
	cfgr.interrupt = judge_interrupt
	cfgr.interrupt_user = h
	cfgr.can_block = true
	cfgr.malloc_limit = 1 << 29
	agent_hooks(&cfgr)
	rt := js.engine_new(context.allocator, cfgr)
	rt.host_data = h
	ctx := js.context_new(rt)
	install_helpers(ctx)
	defer {
		js.engine_free(rt)
		strings.builder_destroy(&h.output)
		free(h)
	}
	r := js.eval_source(ctx, a.source, "<agent>")
	if js.is_exception(r) {
		js.pending_exception(ctx)
		return
	}
	js.persist(rt, r)
	for {
		sync.mutex_lock(&g.mutex)
		for !a.pending && !g.shutdown {sync.cond_wait(&g.cond, &g.mutex)}
		if g.shutdown {
			sync.mutex_unlock(&g.mutex)
			return
		}
		a.pending = false
		bdata, blen, bmax := a.bc_data, a.bc_length, a.bc_max
		sync.cond_broadcast(&g.cond)
		sync.mutex_unlock(&g.mutex)
		if js.is_undefined(h.agent_cb) {continue}
		m := js.host_enter(rt)
		sab := js.shared_buffer_attach(ctx, bdata, blen, bmax)
		res := js.call_function(ctx, h.agent_cb, js.UNDEFINED, {sab})
		js.host_exit(rt, m, res)
		if js.is_exception(res) {js.pending_exception(ctx)}
		js.run_jobs(rt)
		sync.mutex_lock(&g.mutex)
		done := a.leaving
		sync.mutex_unlock(&g.mutex)
		if done {return}
	}
}

// --- the $262.agent object ---

js_agent_start :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	s, ok := js.to_utf8(ctx, js.arg(args, 0), context.temp_allocator)
	if !ok {return js.EXCEPTION}
	agent_start(s)
	return js.UNDEFINED
}

js_agent_broadcast :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	data, length, max_length, ok := js.shared_buffer_info(js.arg(args, 0))
	if !ok {return js.throw_type_error(ctx, "$262.agent.broadcast expects a SharedArrayBuffer")}
	agent_broadcast(data, length, max_length)
	return js.UNDEFINED
}

js_agent_get_report :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	s, ok := agent_get_report()
	if !ok {return js.NULL}
	defer delete(s)
	return js.new_string(ctx, s)
}

js_agent_receive :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	h := host_of(ctx)
	h.agent_cb = js.arg(args, 0)
	js.persist(ctx.rt, h.agent_cb)
	return js.UNDEFINED
}

js_agent_report :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	s, ok := js.to_utf8(ctx, js.arg(args, 0), context.temp_allocator)
	if !ok {return js.EXCEPTION}
	agent_report(s)
	return js.UNDEFINED
}

js_agent_leaving :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	h := host_of(ctx)
	if h.agent != nil {
		sync.mutex_lock(&agent_state.mutex)
		h.agent.leaving = true
		sync.mutex_unlock(&agent_state.mutex)
	}
	return js.UNDEFINED
}
