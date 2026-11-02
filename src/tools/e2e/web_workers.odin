#+build windows
#+private file
// Dedicated workers: messages both ways, buffer transfer, fetch from a worker (same origin, CORS, opaque data: origin, CSP worker-src),
// timers, errors, close(), terminate, page close, limits, and 16 workers computing in parallel. The page's guest says what it sees with
// the test host's note ("msg:<slot>:<text>", "error:<slot>:<message>"); how responsive the page's thread stays under them is measured
// with -Perf.
package e2e_scenarios

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:page"
import "wb:tools/testenv"
import "wb:wasm"

PAGE_GUEST :: "build/workerstest.wasm"
WORKER_GUEST :: "examples/site/workerstest_worker.wasm"
WORKER :: "/site/workerstest_worker.wasm"
ADDRESS :: "http://127.0.0.1:8765/page.html"
ROUNDS :: 200
BUFFER_MIB :: 10
TIMER_MS :: 30
TIMER_ROUNDED_MS :: TIMER_MS - 1    // a wait is rounded to the millisecond: the time the worker's own clock can have taken at the least
CHUNKS :: 120
PARALLEL :: 16
FIRST_PARALLEL_SLOT :: 40
SOLO_SLOT :: 30
BUSY_WORKERS :: 4

// -Perf: the page's thread with the workers computing. What the machine does to a process it stalls is not the browser's.
TIMER_RESOLUTION_MS :: 1
UI_TICK_MS :: 1
IDLE_REFERENCE :: time.Second
WORST_GAP_LIMIT_MS :: 100.0
WORST_TURN_LIMIT_MS :: 50.0
WORST_CALL_LIMIT_MS :: 50.0
MIN_SPEED_UP :: 2.0
NEAR_NOW :: time.Millisecond

Tab :: struct {
	t:       ^testing.T,
	pr:      ^Probe,
	inst:    ^wasm.Instance,
	running: int,         // the workers of the process before this tab
}

// A page running the guest (its first check). When that fails it is closed already.
open :: proc(t: ^testing.T, name: string) -> (tab: Tab, ok: bool) {
	tab.t = t
	tab.running = page.workers_running()
	tab.pr = page_make(t, name, testenv.url(ADDRESS))
	image, err := os.read_entire_file(PAGE_GUEST, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read the page's guest")
	loaded: bool
	why: string
	tab.inst, loaded, why = page.load_module(tab.pr.p, image, name)
	check(tab.pr, loaded, fmt.tprintf("page module runs %s", why))
	if !loaded { close_page(tab.pr); return tab, false }
	return tab, true
}

shut :: proc(tab: ^Tab, min_checks: int, loc := #caller_location) {
	close_page(tab.pr, min_checks = min_checks, loc = loc)
	testing.expect(tab.t, wait_until(tab.t, "the end of its workers", tab, proc(tab: ^Tab) -> bool { return page.workers_running() == tab.running }), "no worker left", loc = loc)
}

// Writes `s` into the page module's command buffer; returns its length.
put_cmd :: proc(tab: ^Tab, s: string) -> u32 {
	ptr, _ := wasm.call_i32(tab.inst, "cmd_ptr")
	dst := wasm.guest_bytes(tab.inst, u64(u32(ptr)), u64(len(s)))
	copy(dst, s)
	return u32(len(s))
}

make_worker :: proc(tab: ^Tab, slot: int, src: string) -> bool {
	argv := [2]u32{u32(slot), put_cmd(tab, src)}
	page.call_export(tab.pr.p, tab.inst, "make_worker", argv[:])
	return argv[0] == 1
}

send :: proc(tab: ^Tab, slot: int, text: string) -> i32 {
	argv := [2]u32{u32(slot), put_cmd(tab, text)}
	page.call_export(tab.pr.p, tab.inst, "send", argv[:])
	return i32(argv[0])
}

call1 :: proc(tab: ^Tab, name: cstring, a: int, b := 0) -> i32 {
	argv := [2]u32{u32(a), u32(b)}
	page.call_export(tab.pr.p, tab.inst, name, argv[:])
	return i32(argv[0])
}

hosts :: proc(tab: ^Tab) -> int { return len(tab.pr.p.workers.hosts) }

Wait_Hosts :: struct { tab: ^Tab, want: int }

wait_hosts :: proc(tab: ^Tab, want: int) -> bool {
	return wait_until(tab.t, "the workers to be freed", Wait_Hosts{tab, want}, proc(w: Wait_Hosts) -> bool { return hosts(w.tab) == w.want })
}

wait_running :: proc(tab: ^Tab, want: int) -> bool {
	return wait_until(tab.t, "the workers' threads", want, proc(want: int) -> bool { return page.workers_running() == want })
}

forget_notes :: proc(tab: ^Tab) {
	for n in tab.pr.section.notes { delete(n) }
	clear(&tab.pr.section.notes)
}

find_note :: proc(tab: ^Tab, needle: string) -> (string, bool) {
	for n in tab.pr.section.notes { if strings.contains(n, needle) { return n, true } }
	return "", false
}

Wait_Message :: struct { tab: ^Tab, needle: string }

// Until the page has noted something with `needle` in it; what it noted, for the test's time.
wait_message :: proc(tab: ^Tab, needle: string) -> (line: string, ok: bool) {
	ok = wait_until(tab.t, fmt.tprintf("%q from the page", needle), Wait_Message{tab, needle}, proc(w: Wait_Message) -> bool {
		_, found := find_note(w.tab, w.needle)
		return found
	})
	found, _ := find_note(tab, needle)
	return strings.clone(found, context.temp_allocator), ok
}

// A worker in `slot`, running.
started :: proc(tab: ^Tab, slot: int) -> bool {
	make_worker(tab, slot, WORKER)
	_, ok := wait_message(tab, fmt.tprintf("msg:%d:ready", slot))
	return ok
}

console_has :: proc(tab: ^Tab, needle: string) -> bool {
	for l in tab.pr.lines { if strings.contains(l, needle) { return true } }
	return false
}

@(test)
workers_messages :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "messages")
	if !ok { return }
	check(tab.pr, make_worker(&tab, 0, WORKER), "Worker_create accepts a same-origin module")
	_, ready := wait_message(&tab, "msg:0:ready")
	check(tab.pr, ready, "the worker's wb_main ran on its thread and its first message reached the page")
	check(tab.pr, page.workers_running() == tab.running + 1, "one worker running")
	forget_notes(&tab)
	send(&tab, 0, "echo:hello")
	_, echoed := wait_message(&tab, "msg:0:echo:hello")
	check(tab.pr, echoed, "round trip page -> worker -> page")
	round := 0
	for round < ROUNDS {
		forget_notes(&tab)
		send(&tab, 0, fmt.tprintf("echo:%d", round))
		if _, got := wait_message(&tab, fmt.tprintf("msg:0:echo:%d", round)); !got { break }
		round += 1
	}
	check(tab.pr, round == ROUNDS, fmt.tprintf("%d sequential round trips (%d)", ROUNDS, round))

	forget_notes(&tab)
	send(&tab, 0, "name")
	line, _ := wait_message(&tab, "msg:0:name:")
	check(tab.pr, line == testenv.url("msg:0:name:0|http://127.0.0.1:8765/site/workerstest_worker.wasm|http://127.0.0.1:8765"), fmt.tprintf("name, location and origin of the worker (%q)", line))
	send(&tab, 0, "console")
	_, logged := wait_message(&tab, "msg:0:logged")
	check(tab.pr, logged && console_has(&tab, "[worker 0] hello from the worker"), "the worker's console is relayed to the page's console")
	send(&tab, 0, "dom")
	line, _ = wait_message(&tab, "msg:0:dom:")
	check(tab.pr, line == "msg:0:dom:0:-1:0", fmt.tprintf("document imports fail in a worker (%q)", line))
	send(&tab, 0, "promise")
	_, promised := wait_message(&tab, "msg:0:promise:99")
	check(tab.pr, promised, "promises and microtasks run in the worker")
	sp, r := wasm.call_i32(tab.inst, "self_probe")
	check(tab.pr, r == .Ok && sp == i32(-4), "worker-only functions refuse a page")
	shut(&tab, 11)
}

@(test)
workers_buffer_transfer :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "buffer transfer")
	if !ok { return }
	if !started(&tab, 0) { shut(&tab, 1); return }
	forget_notes(&tab)
	held_before := tab.pr.p.held
	check(tab.pr, call1(&tab, "send_buffer", 0, BUFFER_MIB) == 0, "a 10 MiB buffer is posted with transfer")
	_, detached := find_note(&tab, "detached:page:0")
	check(tab.pr, detached, "the page's buffer is detached right after the transfer")
	_, refused := find_note(&tab, "retransfer:-4")
	check(tab.pr, refused, "a detached buffer cannot be transferred again")
	line, _ := wait_message(&tab, "msg:0:buf:")
	check(tab.pr, line == "msg:0:buf:10485760:ok:back:10485760:ok", fmt.tprintf("the worker got the 10 MiB intact and sent it back (%q)", line))
	_, back := wait_message(&tab, "msg:0:detached:0")
	check(tab.pr, back, "the worker's buffer is detached after it transferred it back")
	check(tab.pr, tab.pr.p.held == held_before, "the page released the returned buffer (memory accounted)")
	shut(&tab, 7)
}

@(test)
workers_fetch :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "fetch")
	if !ok { return }
	if !started(&tab, 0) { shut(&tab, 1); return }
	forget_notes(&tab)
	send(&tab, 0, "fetch:/status/200")
	line, _ := wait_message(&tab, "msg:0:fetch:")
	check(tab.pr, line == "msg:0:fetch:done:200:0:10:status 200", fmt.tprintf("same-origin fetch (relative URL, against the worker's location) (%q)", line))
	forget_notes(&tab)
	send(&tab, 0, testenv.url("fetch:http://127.0.0.1:8767/cors/none"))
	line, _ = wait_message(&tab, "msg:0:fetch:")
	check(tab.pr, strings.has_prefix(line, fmt.tprintf("msg:0:fetch:failed:0:%d:", int(fetch.Error_Kind.Blocked_Cors))), fmt.tprintf("cross-origin without CORS is refused (%q)", line))
	forget_notes(&tab)
	send(&tab, 0, testenv.url("fetch:http://127.0.0.1:8767/cors/reflect"))
	line, _ = wait_message(&tab, "msg:0:fetch:")
	check(tab.pr, line == "msg:0:fetch:done:200:0:7:reflect", fmt.tprintf("CORS with the worker's origin succeeds (%q)", line))
	shut(&tab, 4)
}

@(test)
workers_timers_and_errors :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "timers and errors")
	if !ok { return }
	if !started(&tab, 0) { shut(&tab, 1); return }
	forget_notes(&tab)
	// (a worker's loop is its own, on the real clock: only that it did not fire early can be said of it)
	start := time.tick_now()
	send(&tab, 0, fmt.tprintf("timer:%d", TIMER_MS))
	_, fired := wait_message(&tab, "msg:0:timer:fired:7")
	dt := time.duration_milliseconds(time.tick_since(start))
	check(tab.pr, fired && dt >= TIMER_ROUNDED_MS, fmt.tprintf("a timer fires in the worker (%.1f ms for 30 ms)", dt))
	forget_notes(&tab)
	send(&tab, 0, "trap")
	line, trapped := wait_message(&tab, "error:0:")
	check(tab.pr, trapped && strings.contains(line, "unreachable"), fmt.tprintf("a trap in the worker is an error event at the Worker (%q)", line))
	check(tab.pr, !console_has(&tab, "uncaught error"), "an error event the page cancelled is not reported to the console")
	send(&tab, 0, "echo:after")
	_, after := wait_message(&tab, "msg:0:echo:after")
	check(tab.pr, after, "the worker keeps running after an error")
	shut(&tab, 5)
}

@(test)
workers_refused_or_failing :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "refused or failing")
	if !ok { return }
	if !started(&tab, 0) { shut(&tab, 1); return }
	forget_notes(&tab)
	check(tab.pr, !make_worker(&tab, 1, testenv.url("http://127.0.0.1:8767/site/workerstest_worker.wasm")), "a cross-origin worker is refused (SecurityError)")
	check(tab.pr, make_worker(&tab, 2, "/site/missing.wasm"), "a missing module is accepted at first")
	line, failed := wait_message(&tab, "error:2:")
	check(tab.pr, failed && strings.contains(line, "missing.wasm"), fmt.tprintf("then fails with an error event (%q)", line))
	check(tab.pr, make_worker(&tab, 3, "/wasm-wrong"), "a module with the wrong MIME type is accepted at first")
	line, _ = wait_message(&tab, "error:3:")
	check(tab.pr, strings.contains(line, "application/wasm"), fmt.tprintf("then fails with an error event (%q)", line))
	call1(&tab, "release", 2)
	call1(&tab, "release", 3)
	check(tab.pr, wait_hosts(&tab, 1), "failed workers are freed once released")
	settings.workers.max_per_page = 1
	check(tab.pr, !make_worker(&tab, 9, WORKER), "workers.max_per_page is enforced")
	shut(&tab, 8)
}

@(test)
workers_messages_before_the_worker_runs_and_close :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "close")
	if !ok { return }
	if !started(&tab, 0) { shut(&tab, 1); return }   // the worker that stays, whose round trip says when anything else would have come
	forget_notes(&tab)
	make_worker(&tab, 8, WORKER)
	send(&tab, 8, "echo:early")
	_, early := wait_message(&tab, "msg:8:echo:early")
	_, ready := find_note(&tab, "msg:8:ready")
	check(tab.pr, early && ready && tab.pr.section.notes[0] == "msg:8:ready", "a message posted before the module ran waits for it")
	forget_notes(&tab)
	send(&tab, 8, "close")
	_, after := wait_message(&tab, "msg:8:after-close")
	_, closing := find_note(&tab, "msg:8:closing")
	check(tab.pr, after && closing, "close(): messages of the current task are still delivered")
	check(tab.pr, wait_running(&tab, tab.running + 1), "close(): the thread ends")
	send(&tab, 8, "echo:late")
	send(&tab, 0, "echo:barrier")
	wait_message(&tab, "msg:0:echo:barrier")
	drain()
	_, late := find_note(&tab, "msg:8:echo:late")
	check(tab.pr, !late, "close(): nothing runs afterwards")
	call1(&tab, "release", 8)
	shut(&tab, 5)
}

@(test)
workers_terminate :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "terminate")
	if !ok { return }
	for kind in ([2]string{"spin", "spin_hard"}) {
		forget_notes(&tab)
		make_worker(&tab, 5, WORKER)
		wait_message(&tab, "msg:5:ready")
		send(&tab, 5, kind)
		wait_message(&tab, "msg:5:spinning")   // (of "spin": after some turns of its loop)
		before := hosts(&tab)
		running := page.workers_running()
		call1(&tab, "terminate", 5)
		// spin_hard is one endless task: terminate interrupts it (epoch interruption); how long it took is the machine's
		joined := wait_hosts(&tab, before - 1)
		check(tab.pr, joined && page.workers_running() == running - 1, fmt.tprintf("terminate (%s): thread joined and instance freed", kind))
		drain()
		count := 0
		for n in tab.pr.section.notes { if strings.has_prefix(n, "msg:5:") || strings.has_prefix(n, "error:5:") { count += 1 } }
		check(tab.pr, count == 2, fmt.tprintf("nothing reaches the page after terminate (%s)", kind))
	}
	forget_notes(&tab)
	before := hosts(&tab)
	make_worker(&tab, 7, WORKER)
	wait_message(&tab, "msg:7:ready")
	call1(&tab, "release", 7)
	check(tab.pr, wait_hosts(&tab, before), "releasing the Worker object terminates it")
	shut(&tab, 6)
}

@(test)
workers_data_url_has_an_opaque_origin :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "data worker")
	if !ok { return }
	image, err := os.read_entire_file(WORKER_GUEST, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read the worker's guest")
	data_url := strings.concatenate({"data:application/wasm;base64,", base64.encode(image, allocator = context.temp_allocator)}, context.temp_allocator)
	check(tab.pr, make_worker(&tab, 11, data_url), "a data: worker is accepted")
	wait_message(&tab, "msg:11:ready")
	send(&tab, 11, "origin")
	line, _ := wait_message(&tab, "msg:11:origin:")
	check(tab.pr, line == "msg:11:origin:null", fmt.tprintf("a data: worker has an opaque origin (%q)", line))
	send(&tab, 11, testenv.url("fetch:http://127.0.0.1:8765/status/200"))
	line, _ = wait_message(&tab, "msg:11:fetch:")
	check(tab.pr, strings.has_prefix(line, fmt.tprintf("msg:11:fetch:failed:0:%d:", int(fetch.Error_Kind.Blocked_Cors))), fmt.tprintf("its requests are cross-origin to the page (%q)", line))
	call1(&tab, "terminate", 11)
	shut(&tab, 4)
}

@(test)
workers_csp_worker_src :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	for policy in ([2]string{"worker-src 'none'", "script-src 'none'"}) {
		tab: Tab
		tab.t = t
		tab.running = page.workers_running()
		tab.pr = page_make(t, policy, testenv.url("http://127.0.0.1:8765/csp.html"))
		page.apply_response_headers(tab.pr.p, {policy}, nil, "")
		image, _ := os.read_entire_file(PAGE_GUEST, context.temp_allocator)
		tab.inst, _, _ = page.load_module(tab.pr.p, image, "csp")
		check(tab.pr, make_worker(&tab, 0, WORKER), "accepted at first")
		line, _ := wait_message(&tab, "error:0:")
		check(tab.pr, strings.contains(line, "Content-Security-Policy"), fmt.tprintf("%s blocks the worker (%q)", policy, line))
		shut(&tab, 2)
	}
}

count_done :: proc(tab: ^Tab) -> int {
	done := 0
	for n in tab.pr.section.notes { if strings.contains(n, ":done:") { done += 1 } }
	return done
}

@(test)
workers_16_in_parallel :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "16 in parallel")
	if !ok { return }
	for i in 0 ..< PARALLEL { make_worker(&tab, FIRST_PARALLEL_SLOT + i, WORKER) }
	for i in 0 ..< PARALLEL { wait_message(&tab, fmt.tprintf("msg:%d:ready", FIRST_PARALLEL_SLOT + i)) }
	forget_notes(&tab)
	for i in 0 ..< PARALLEL { send(&tab, FIRST_PARALLEL_SLOT + i, fmt.tprintf("compute:%d", CHUNKS)) }
	wait_until(t, "the workers' results", &tab, proc(tab: ^Tab) -> bool { return count_done(tab) >= PARALLEL })
	check(tab.pr, count_done(&tab) == PARALLEL, fmt.tprintf("%d workers finished (%d)", PARALLEL, count_done(&tab)))
	for i in 0 ..< PARALLEL { call1(&tab, "release", FIRST_PARALLEL_SLOT + i) }
	check(tab.pr, wait_hosts(&tab, 0) && wait_running(&tab, tab.running), "the 16 released workers are joined")
	shut(&tab, 3)
}

Gap_Probe :: struct { last: time.Tick, worst: f64, ticks: int }

// The page's thread: a 1 ms timer and calls into the page module, first idle as a reference (how late the OS wakes this process), then with
// 16 workers computing. Measures time, so -Perf.
@(test)
workers_page_thread_stays_responsive_under_16 :: proc(t: ^testing.T) {
	if base.perf_skip("the page's thread under 16 workers") { return }
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	win.timeBeginPeriod(TIMER_RESOLUTION_MS)   // 1 ms sleeps: these numbers measure the browser, not the OS tick
	defer win.timeEndPeriod(TIMER_RESOLUTION_MS)
	tab, ok := open(t, "responsive")
	if !ok { return }
	if !started(&tab, SOLO_SLOT) { shut(&tab, 1); return }
	start := time.tick_now()
	send(&tab, SOLO_SLOT, fmt.tprintf("compute:%d", CHUNKS))
	wait_message(&tab, fmt.tprintf("msg:%d:done:", SOLO_SLOT))
	alone := time.duration_milliseconds(time.tick_since(start))
	call1(&tab, "terminate", SOLO_SLOT)
	for i in 0 ..< PARALLEL { make_worker(&tab, FIRST_PARALLEL_SLOT + i, WORKER) }
	for i in 0 ..< PARALLEL { wait_message(&tab, fmt.tprintf("msg:%d:ready", FIRST_PARALLEL_SLOT + i)) }

	probe := Gap_Probe{last = time.tick_now()}
	tick := host.set_timer(&loop, UI_TICK_MS, UI_TICK_MS, proc(data: rawptr) {
		g := (^Gap_Probe)(data)
		now := time.tick_now()
		g.worst = max(g.worst, time.duration_milliseconds(time.tick_diff(g.last, now)))
		g.last = now
		g.ticks += 1
	}, &probe)
	idle_since := time.tick_now()
	for time.tick_since(idle_since) < IDLE_REFERENCE { host.loop_wait(&loop, UI_TICK_MS) }
	idle := probe

	forget_notes(&tab)
	start = time.tick_now()
	for i in 0 ..< PARALLEL { send(&tab, FIRST_PARALLEL_SLOT + i, fmt.tprintf("compute:%d", CHUNKS)) }
	probe = {last = time.tick_now()}
	worst_call, worst_turn: f64
	for count_done(&tab) < PARALLEL && time.duration_seconds(time.tick_since(start)) < DEFAULT_WAIT {
		if host.next_timeout_ms(&loop) != 0 { sync.sema_wait_with_timeout(&loop.sema, NEAR_NOW) }
		turn := time.tick_now()
		host.run_ready(&loop)   // the page's thread's share of the work: relaying 16 workers' messages
		worst_turn = max(worst_turn, time.duration_milliseconds(time.tick_since(turn)))
		c := time.tick_now()
		wasm.call_i32(tab.inst, "ping")
		worst_call = max(worst_call, time.duration_milliseconds(time.tick_since(c)))
	}
	host.clear_timer(&loop, tick)
	together := time.duration_milliseconds(time.tick_since(start))
	speed_up := PARALLEL * alone / together
	fmt.printfln("MEASURE one worker alone: %.0f ms; %d in parallel: %.0f ms; speed-up %.1fx", alone, PARALLEL, together, speed_up)
	fmt.printfln("MEASURE page thread under %d workers: worst gap between 1 ms ticks %.1f ms over %d ticks (idle: %.1f ms over %d ticks in 1 s); longest turn %.2f ms; worst call into the page module %.2f ms",
		PARALLEL, probe.worst, probe.ticks, idle.worst, idle.ticks, worst_turn, worst_call)
	check(tab.pr, count_done(&tab) == PARALLEL, fmt.tprintf("%d workers finished", PARALLEL))
	check(tab.pr, probe.worst < WORST_GAP_LIMIT_MS, fmt.tprintf("the page's timer goes on (worst gap %.1f ms)", probe.worst))
	check(tab.pr, worst_turn < WORST_TURN_LIMIT_MS, fmt.tprintf("relaying the workers' messages takes no long turn (%.2f ms)", worst_turn))
	check(tab.pr, worst_call < WORST_CALL_LIMIT_MS, fmt.tprintf("the page module answers (worst call %.2f ms)", worst_call))
	check(tab.pr, speed_up >= MIN_SPEED_UP, fmt.tprintf("the workers do compute in parallel (speed-up %.1fx)", speed_up))
	for i in 0 ..< PARALLEL { call1(&tab, "release", FIRST_PARALLEL_SLOT + i) }
	shut(&tab, 6)
}

@(test)
workers_closing_a_page_with_busy_workers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	tab, ok := open(t, "closing")
	if !ok { return }
	for i in 0 ..< BUSY_WORKERS { make_worker(&tab, i, WORKER) }
	for i in 0 ..< BUSY_WORKERS { wait_message(&tab, fmt.tprintf("msg:%d:ready", i)) }
	for i in 0 ..< BUSY_WORKERS { send(&tab, i, i % 2 == 0 ? "spin" : "spin_hard") }
	for i in 0 ..< BUSY_WORKERS { wait_message(&tab, fmt.tprintf("msg:%d:spinning", i)) }
	page.page_close(tab.pr.p)
	tab.pr.p = nil
	check(tab.pr, page.workers_running() == tab.running, "page_close stopped and joined its 4 busy workers")
	shut(&tab, 2)
}
