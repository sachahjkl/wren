package page

import "core:encoding/base64"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:dom"

////////////////////////////////
// Message queue between threads

@(private = "file")
Producer :: struct { l: ^Worker_Link, n: int, refused: int }

@(test)
link_carries_messages_between_threads_in_order :: proc(t: ^testing.T) {
	ui: host.Loop
	host.loop_init(&ui)
	defer host.loop_destroy(&ui)
	l := link_make(&ui, 1 << 30)
	pr := Producer{l = l, n = 20_000}
	link_retain(l)   // the producer's reference
	th := host.thread_start(proc(data: rawptr) {
		p := (^Producer)(data)
		for i in 0 ..< p.n {
			m := new(Worker_Msg)
			m.kind, m.id, m.size = .Message, u64(i), 16
			m.text = strings.clone("payload")
			link_send(p.l, true, m)
		}
		link_release(p.l)
	}, &pr)

	got := 0
	in_order := true
	batch: [dynamic]^Worker_Msg
	defer delete(batch)
	deadline := time.tick_now()
	for got < pr.n && time.duration_seconds(time.tick_since(deadline)) < 10 {
		host.loop_wait(&l.loop, 50)   // woken by the producer's host.signal
		link_take(l, true, &batch)
		for m in batch {
			if m.id != u64(got) || m.text != "payload" { in_order = false }
			got += 1
			msg_free(m)
		}
		clear(&batch)
	}
	host.thread_join(th)
	testing.expect_value(t, got, pr.n)
	testing.expect(t, in_order, "messages arrive once each, in order")
	testing.expect_value(t, l.worker_bytes, 0)

	// a receiver that does not keep up: guest messages past the limit are refused, the others still go through
	l.max_pending = 100
	big := new(Worker_Msg)
	big.kind, big.size = .Message, 200
	testing.expect(t, !link_send(l, true, big, limited = true), "over workers.max_pending_bytes: refused")
	msg_free(big)
	ctl := new(Worker_Msg)
	ctl.kind, ctl.size = .Fetch_Event, 200
	testing.expect(t, link_send(l, true, ctl), "internal messages are not limited")
	link_release(l)   // frees the queued one
}

////////////////////////////////
// Transfer

@(private = "file")
test_page :: proc(loop: ^host.Loop, loader: ^fetch.Loader, settings: ^Settings, scope: ^base.Scope) -> ^Page {
	return page_create(loop, loader, settings, scope, "http://127.0.0.1:8765/t.html")
}

@(test)
transfer_detaches_the_sender_and_moves_the_bytes :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	a := test_page(&loop, &loader, &settings, scope)
	b := test_page(&loop, &loader, &settings, scope)
	l := link_make(&loop, 1 << 30)
	defer link_release(l)

	bytes := make([]byte, 1 << 20, context.temp_allocator)
	for i in 0 ..< len(bytes) { bytes[i] = u8(i * 7) }
	h := buffer_create(a, bytes, 0)
	other := buffer_create(a, bytes[:10], 0)
	testing.expect_value(t, a.held, (1 << 20) + 10)

	// refusals leave everything as it was
	dup := [2]u64{h, h}
	testing.expect_value(t, post_message(a, l, true, "x", dup[:]), dom.Error.Invalid_Argument)
	bogus := [1]u64{12345}
	testing.expect_value(t, post_message(a, l, true, "x", bogus[:]), dom.Error.Invalid_Argument)
	settings.workers.max_message_bytes = 1000
	one := [1]u64{h}
	testing.expect_value(t, post_message(a, l, true, "x", one[:]), dom.Error.Invalid_Argument)
	settings.workers.max_message_bytes = 1 << 30
	testing.expect(t, !buffer_get(a, h).detached && len(buffer_bytes(a, h)) == 1 << 20, "nothing detached by a refused message")

	two := [2]u64{h, other}
	testing.expect_value(t, post_message(a, l, true, "hello", two[:]), dom.Error.None)
	testing.expect(t, buffer_get(a, h).detached && len(buffer_bytes(a, h)) == 0, "the sender's buffer is detached")
	testing.expect_value(t, a.held, 0)
	testing.expect_value(t, post_message(a, l, true, "again", one[:]), dom.Error.Invalid_Argument)

	batch: [dynamic]^Worker_Msg
	defer delete(batch)
	link_take(l, true, &batch)
	testing.expect_value(t, len(batch), 1)
	m := batch[0]
	testing.expect(t, m.text == "hello" && len(m.buffers) == 2 && len(m.buffers[0]) == 1 << 20 && m.buffers[0][12345] == u8((12345 * 7) & 255), "text copied, bytes moved intact")

	// the receiver adopts them; nobody listens, so they are released at once
	target := object_create(b, &worker_global_vt, nil, 0)
	deliver_message(b, target, m, 0)
	testing.expect_value(t, b.held, 0)
	msg_free(m)

	// a message that does not fit in the receiver's ceiling is a messageerror, and its bytes are freed
	h2 := buffer_create(a, bytes, 0)
	one[0] = h2
	post_message(a, l, true, "", one[:])
	clear(&batch)
	link_take(l, true, &batch)
	settings.max_fetch_bytes = 1000
	deliver_message(b, target, batch[0], 0)
	settings.max_fetch_bytes = 1 << 30
	testing.expect_value(t, b.held, 0)
	msg_free(batch[0])
}

////////////////////////////////
// Workers with a real thread and module

// A module whose wb_main never returns: (func (export "wb_main") (loop (br 0)))
@(private = "file")
SPIN_MODULE := [?]u8{
	0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
	0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
	0x03, 0x02, 0x01, 0x00,
	0x07, 0x0b, 0x01, 0x07, 'w', 'b', '_', 'm', 'a', 'i', 'n', 0x00, 0x00,
	0x0a, 0x09, 0x01, 0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b,
}

@(private = "file")
Env :: struct {
	loop:     host.Loop,
	pool:     host.Blocking_Pool,
	profile:  fetch.Profile,
	loader:   fetch.Loader,
	settings: Settings,
	scope:    ^base.Scope,
}

// Tests that start workers share the process-wide count and the import registry: one at a time.
@(private = "file")
worker_tests: sync.Mutex

@(private = "file")
env_init :: proc(e: ^Env) {
	sync.mutex_lock(&worker_tests)
	host.loop_init(&e.loop)
	host.blocking_init(&e.pool, &e.loop, 2)
	e.profile = fetch.profile_make()
	fetch.loader_init(&e.loader, &e.loop, nil, &e.pool, &e.profile)   // data: URLs only: no network client
	e.settings = settings_default()
	e.settings.workers.wasm.budget = 20_000_000
	e.scope = base.scope_make("test")
	register_imports()
}

@(private = "file")
env_destroy :: proc(e: ^Env) {
	base.scope_close(e.scope)
	for _ in 0 ..< 5 { host.loop_wait(&e.loop, 5) }
	fetch.loader_destroy(&e.loader)
	host.blocking_destroy(&e.pool)
	fetch.profile_destroy(&e.profile)
	settings_destroy(&e.settings)
	host.loop_destroy(&e.loop)
	sync.mutex_unlock(&worker_tests)
}

@(private = "file")
spin_url :: proc() -> string {
	enc, _ := base64.encode(SPIN_MODULE[:], allocator = context.temp_allocator)
	return strings.concatenate({"data:application/wasm;base64,", enc}, context.temp_allocator)
}

@(private = "file")
wait_running :: proc(e: ^Env, p: ^Page, n: int) -> bool {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 10 {
		running := 0
		for h in p.workers.hosts { if h.thread != nil { running += 1 } }
		if running == n { return true }
		host.loop_wait(&e.loop, 1)
	}
	return false
}

@(test)
terminate_stops_a_worker_busy_in_a_long_computation :: proc(t: ^testing.T) {
	e: Env
	env_init(&e)
	defer env_destroy(&e)
	p := test_page(&e.loop, &e.loader, &e.settings, e.scope)
	w := worker_create(p, spin_url(), "busy", 0)
	testing.expect(t, w != 0)
	testing.expect(t, wait_running(&e, p, 1), "the worker thread started")
	time.sleep(10 * time.Millisecond)   // inside wb_main's endless loop by now
	t0 := time.tick_now()
	testing.expect_value(t, worker_terminate_object(p, w), dom.Error.None)
	object_release(p, w)
	start := time.tick_now()
	for len(p.workers.hosts) > 0 && time.duration_seconds(time.tick_since(start)) < 10 { host.loop_wait(&e.loop, 1) }
	dt := time.duration_milliseconds(time.tick_since(t0))
	testing.expect_value(t, len(p.workers.hosts), 0)
	testing.expect_value(t, workers_running(), 0)
	testing.expectf(t, dt < 1000, "stopped within its instruction budget (%.1f ms)", dt)
}

@(test)
closing_a_page_joins_its_active_workers :: proc(t: ^testing.T) {
	e: Env
	env_init(&e)
	defer env_destroy(&e)
	p := test_page(&e.loop, &e.loader, &e.settings, e.scope)
	for _ in 0 ..< 3 { worker_create(p, spin_url(), "busy", 0) }
	testing.expect(t, wait_running(&e, p, 3), "three worker threads started")
	testing.expect_value(t, workers_running(), 3)
	page_close(p)
	testing.expect_value(t, workers_running(), 0)   // joined before page_close returned
}

@(test)
worker_modules_may_only_import_what_is_safe_off_the_ui_thread :: proc(t: ^testing.T) {
	sync.mutex_lock(&worker_tests)
	defer sync.mutex_unlock(&worker_tests)
	testing.expect(t, worker_import_filter("timers", "Timers_setTimeout"))
	testing.expect(t, worker_import_filter("workers", "DedicatedWorkerGlobalScope_postMessage"))
	testing.expect(t, !worker_import_filter("canvas", "Canvas_fill"), "an unknown module is refused")
	worker_allow_module("test_safe")
	testing.expect(t, worker_import_filter("test_safe", "f"))
	delete(worker_modules)
	worker_modules = nil
}
