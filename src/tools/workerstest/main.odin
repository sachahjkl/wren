// Headless end-to-end test of dedicated workers: messages both ways, buffer transfer, fetch from a worker (same origin,
// CORS, opaque data: origin, CSP worker-src), timers, errors, close(), terminate, page close, limits, and 16 workers
// computing in parallel while the UI thread stays responsive. Needs build\testserver.exe running; run from the repo root.
//   workerstest.exe build\workerstest.wasm examples\site\workerstest_worker.wasm
package workerstest

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:wasm"

failures: int
logs: [dynamic]string

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

quiet: bool

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	if !quiet { fmt.printf("  [%v] %s\n", level, message) }
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings

the_page: ^page.Page
the_inst: ^wasm.Instance

clear_logs :: proc() {
	for l in logs { delete(l) }
	clear(&logs)
}

find_log :: proc(needle: string) -> (string, bool) {
	for l in logs { if strings.contains(l, needle) { return l, true } }
	return "", false
}

// Pumps the loop until a console line contains `needle`.
wait_log :: proc(needle: string, seconds := 10.0) -> (line: string, ok: bool) {
	start := time.tick_now()
	for {
		if l, found := find_log(needle); found { return l, true }
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %q\n", needle); return "", false }
		host.loop_wait(&loop, 5)
	}
}

pump :: proc(ms: int) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) { host.loop_wait(&loop, 2) }
}

pump_until :: proc(cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { return false }
		host.loop_wait(&loop, 1)
	}
	return true
}

// Writes `s` into the page module's command buffer; returns its length.
put_cmd :: proc(inst: ^wasm.Instance, s: string) -> u32 {
	ptr, _ := wasm.call_i32(inst, "cmd_ptr")
	dst := wasm.guest_bytes(inst, u32(ptr), u32(len(s)))
	copy(dst, s)
	return u32(len(s))
}

make_worker :: proc(slot: int, src: string, p := the_page, inst := the_inst) -> bool {
	argv := [2]u32{u32(slot), put_cmd(inst, src)}
	page.call_export(p, inst, "make_worker", argv[:])
	return argv[0] == 1
}

send :: proc(slot: int, text: string, inst := the_inst, p := the_page) -> i32 {
	argv := [2]u32{u32(slot), put_cmd(inst, text)}
	page.call_export(p, inst, "send", argv[:])
	return i32(argv[0])
}

call1 :: proc(name: cstring, a: int, b := 0, p := the_page, inst := the_inst) -> i32 {
	argv := [2]u32{u32(a), u32(b)}
	page.call_export(p, inst, name, argv[:])
	return i32(argv[0])
}

hosts :: proc() -> int { return len(the_page.workers.hosts) }

main :: proc() {
	if len(os.args) < 3 { fmt.eprintln("usage: workerstest workerstest.wasm workerstest_worker.wasm"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	worker_image, werr := os.read_entire_file(os.args[2], context.allocator)
	if err != nil || werr != nil { fmt.eprintln("cannot read inputs"); os.exit(2) }

	win.timeBeginPeriod(1)   // 1 ms sleeps: the responsiveness numbers below measure the browser, not the OS tick
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	process := base.scope_make("process")

	p := page.page_create(&loop, &loader, &settings, process, "http://127.0.0.1:8765/page.html", console)
	the_page = p
	inst, ok, e := page.load_module(p, image, "workerstest")
	the_inst = inst
	check(ok, fmt.tprintf("page module runs %s", e))
	WORKER :: "/site/workerstest_worker.wasm"

	////////////////////////////////
	fmt.println("-- messages")
	check(make_worker(0, WORKER), "Worker_create accepts a same-origin module")
	_, ok = wait_log("msg:0:ready")
	check(ok, "the worker's wb_main ran on its thread and its first message reached the page")
	check(page.workers_running() == 1, "one worker running")
	clear_logs()
	send(0, "echo:hello")
	_, ok = wait_log("msg:0:echo:hello")
	check(ok, "round trip page -> worker -> page")
	quiet = true
	t0 := time.tick_now()
	ROUNDS :: 200
	for i in 0 ..< ROUNDS {
		clear_logs()
		send(0, fmt.tprintf("echo:%d", i))
		if _, got := wait_log(fmt.tprintf("msg:0:echo:%d", i), 5); !got { break }
	}
	rt := time.duration_microseconds(time.tick_since(t0)) / ROUNDS
	quiet = false
	check(true, fmt.tprintf("%d sequential round trips: %.0f us each", ROUNDS, rt))

	clear_logs()
	send(0, "name")
	line, _ := wait_log("msg:0:name:")
	check(line == "msg:0:name:0|http://127.0.0.1:8765/site/workerstest_worker.wasm|http://127.0.0.1:8765", fmt.tprintf("name, location and origin of the worker (%q)", line))
	send(0, "console")
	_, ok = wait_log("msg:0:logged")
	_, ok2 := find_log("[worker 0] hello from the worker")
	check(ok && ok2, "the worker's console is relayed to the page's console")
	send(0, "dom")
	line, _ = wait_log("msg:0:dom:")
	check(line == "msg:0:dom:0:-1:0", fmt.tprintf("document imports fail in a worker (%q)", line))
	send(0, "promise")
	_, ok = wait_log("msg:0:promise:99")
	check(ok, "promises and microtasks run in the worker")
	sp, r := wasm.call_i32(inst, "self_probe")
	check(r == .Ok && sp == i32(-4), "worker-only functions refuse a page")

	////////////////////////////////
	fmt.println("-- buffer transfer")
	clear_logs()
	held_before := p.held
	t0 = time.tick_now()
	res := call1("send_buffer", 0, 10)
	check(res == 0, "a 10 MiB buffer is posted with transfer")
	_, ok = find_log("detached:page:0")
	check(ok, "the page's buffer is detached right after the transfer")
	_, ok = find_log("retransfer:-4")
	check(ok, "a detached buffer cannot be transferred again")
	line, ok = wait_log("msg:0:buf:")
	check(line == "msg:0:buf:10485760:ok:back:10485760:ok", fmt.tprintf("the worker got the 10 MiB intact and sent it back (%q)", line))
	_, ok = wait_log("msg:0:detached:0")
	check(ok, "the worker's buffer is detached after it transferred it back")
	check(true, fmt.tprintf("10 MiB there and back in %.1f ms", time.duration_milliseconds(time.tick_since(t0))))
	check(p.held == held_before, "the page released the returned buffer (memory accounted)")

	////////////////////////////////
	fmt.println("-- fetch from a worker")
	clear_logs()
	send(0, "fetch:/status/200")
	line, _ = wait_log("msg:0:fetch:")
	check(line == "msg:0:fetch:done:200:0:10:status 200", fmt.tprintf("same-origin fetch (relative URL, against the worker's location) (%q)", line))
	clear_logs()
	send(0, "fetch:http://127.0.0.1:8767/cors/none")
	line, _ = wait_log("msg:0:fetch:")
	check(strings.has_prefix(line, fmt.tprintf("msg:0:fetch:failed:0:%d:", int(fetch.Error_Kind.Blocked_Cors))), fmt.tprintf("cross-origin without CORS is refused (%q)", line))
	clear_logs()
	send(0, "fetch:http://127.0.0.1:8767/cors/reflect")
	line, _ = wait_log("msg:0:fetch:")
	check(line == "msg:0:fetch:done:200:0:7:reflect", fmt.tprintf("CORS with the worker's origin succeeds (%q)", line))

	////////////////////////////////
	fmt.println("-- timers, errors")
	clear_logs()
	t0 = time.tick_now()
	send(0, "timer:30")
	_, ok = wait_log("msg:0:timer:fired:7")
	dt := time.duration_milliseconds(time.tick_since(t0))
	check(ok && dt >= 29, fmt.tprintf("a timer fires in the worker (%.1f ms for 30 ms)", dt))
	clear_logs()
	send(0, "trap")
	line, ok = wait_log("error:0:")
	check(ok && strings.contains(line, "unreachable"), fmt.tprintf("a trap in the worker is an error event at the Worker (%q)", line))
	_, logged := find_log("uncaught error")
	check(!logged, "an error event the page cancelled is not reported to the console")
	send(0, "echo:after")
	_, ok = wait_log("msg:0:echo:after")
	check(ok, "the worker keeps running after an error")

	////////////////////////////////
	fmt.println("-- refused or failing workers")
	clear_logs()
	check(!make_worker(1, "http://127.0.0.1:8767/site/workerstest_worker.wasm"), "a cross-origin worker is refused (SecurityError)")
	check(make_worker(2, "/site/missing.wasm"), "a missing module is accepted at first")
	line, ok = wait_log("error:2:")
	check(ok && strings.contains(line, "missing.wasm"), fmt.tprintf("then fails with an error event (%q)", line))
	check(make_worker(3, "/wasm-wrong"), "a module with the wrong MIME type is accepted at first")
	line, ok = wait_log("error:3:")
	check(strings.contains(line, "application/wasm"), fmt.tprintf("then fails with an error event (%q)", line))
	call1("release", 2)
	call1("release", 3)
	check(pump_until(proc() -> bool { return hosts() == 1 }), "failed workers are freed once released")

	limit := settings.workers.max_per_page
	settings.workers.max_per_page = 1
	check(!make_worker(9, WORKER), "workers.max_per_page is enforced")
	settings.workers.max_per_page = limit

	////////////////////////////////
	fmt.println("-- messages before the worker runs, close()")
	clear_logs()
	make_worker(8, WORKER)
	send(8, "echo:early")
	_, ok = wait_log("msg:8:echo:early")
	_, ok2 = find_log("msg:8:ready")
	check(ok && ok2 && logs[0] == "msg:8:ready", "a message posted before the module ran waits for it")
	clear_logs()
	send(8, "close")
	_, ok = wait_log("msg:8:after-close")
	_, ok2 = find_log("msg:8:closing")
	check(ok && ok2, "close(): messages of the current task are still delivered")
	check(pump_until(proc() -> bool { return page.workers_running() == 1 }), "close(): the thread ends")
	send(8, "echo:late")
	pump(200)
	_, late := find_log("msg:8:echo:late")
	check(!late, "close(): nothing runs afterwards")
	call1("release", 8)

	////////////////////////////////
	fmt.println("-- terminate")
	for kind in ([2]string{"spin", "spin_hard"}) {
		clear_logs()
		make_worker(5, WORKER)
		wait_log("msg:5:ready")
		send(5, kind)
		wait_log("msg:5:spinning")
		if kind == "spin" { pump(300) }
		before := hosts()
		running := page.workers_running()
		t0 = time.tick_now()
		call1("terminate", 5)
		@(static) want: int
		want = before - 1
		joined := pump_until(proc() -> bool { return hosts() == want })
		dt = time.duration_milliseconds(time.tick_since(t0))
		check(joined && page.workers_running() == running - 1, fmt.tprintf("terminate (%s): thread joined and instance freed in %.1f ms", kind, dt))
		if kind == "spin" {
			check(dt < 100, "a worker computing continuously stops in less than 100 ms")
		} else {
			// one endless task: it ends with the instruction budget (workers.instruction_budget)
			check(dt < 2000, "a worker stuck in one endless task stops within its instruction budget")
		}
		pump(50)
		count := 0
		for l in logs { if strings.has_prefix(l, "msg:5:") || strings.has_prefix(l, "error:5:") { count += 1 } }
		check(count == 2, fmt.tprintf("nothing reaches the page after terminate (%s)", kind))
	}
	clear_logs()
	make_worker(7, WORKER)
	wait_log("msg:7:ready")
	call1("release", 7)
	check(pump_until(proc() -> bool { return hosts() == 1 }), "releasing the Worker object terminates it")

	////////////////////////////////
	fmt.println("-- data: worker (opaque origin)")
	clear_logs()
	data_url := strings.concatenate({"data:application/wasm;base64,", base64.encode(worker_image, allocator = context.temp_allocator)}, context.temp_allocator)
	check(make_worker(11, data_url), "a data: worker is accepted")
	wait_log("msg:11:ready")
	send(11, "origin")
	line, _ = wait_log("msg:11:origin:")
	check(line == "msg:11:origin:null", fmt.tprintf("a data: worker has an opaque origin (%q)", line))
	send(11, "fetch:http://127.0.0.1:8765/status/200")
	line, _ = wait_log("msg:11:fetch:")
	check(strings.has_prefix(line, fmt.tprintf("msg:11:fetch:failed:0:%d:", int(fetch.Error_Kind.Blocked_Cors))), fmt.tprintf("its requests are cross-origin to the page (%q)", line))
	call1("terminate", 11)

	////////////////////////////////
	fmt.println("-- CSP worker-src")
	for policy in ([2]string{"worker-src 'none'", "script-src 'none'"}) {
		cp := page.page_create(&loop, &loader, &settings, process, "http://127.0.0.1:8765/csp.html", console)
		page.apply_response_headers(cp, {policy}, nil, "")
		ci, _, _ := page.load_module(cp, image, "csp")
		clear_logs()
		check(make_worker(0, WORKER, cp, ci), "accepted at first")
		line, ok = wait_log("error:0:")
		check(strings.contains(line, "Content-Security-Policy"), fmt.tprintf("%s blocks the worker (%q)", policy, line))
		page.page_close(cp)
	}

	////////////////////////////////
	fmt.println("-- 16 workers in parallel, UI thread responsive")
	quiet = true
	CHUNKS :: 120
	clear_logs()
	make_worker(30, WORKER)
	wait_log("msg:30:ready")
	t0 = time.tick_now()
	send(30, fmt.tprintf("compute:%d", CHUNKS))
	wait_log("msg:30:done:", 60)
	t1 := time.duration_milliseconds(time.tick_since(t0))
	call1("terminate", 30)
	N :: 16
	for i in 0 ..< N { make_worker(40 + i, WORKER) }
	for i in 0 ..< N { wait_log(fmt.tprintf("msg:%d:ready", 40 + i)) }
	// the UI thread: a 1 ms timer and calls into the page module; record the worst delay of each. First idle, as a
	// reference (how late the OS wakes this process), then while 16 workers compute.
	Probe :: struct { last: time.Tick, worst: f64, ticks: int }
	@(static) probe: Probe
	probe = {last = time.tick_now()}
	tick := host.set_timer(&loop, 1, 1, proc(data: rawptr) {
		now := time.tick_now()
		probe.worst = max(probe.worst, time.duration_milliseconds(time.tick_diff(probe.last, now)))
		probe.last = now
		probe.ticks += 1
	}, nil)
	pump(1000)
	idle := probe
	clear_logs()
	t0 = time.tick_now()
	for i in 0 ..< N { send(40 + i, fmt.tprintf("compute:%d", CHUNKS)) }
	probe = {last = time.tick_now()}
	worst_call, worst_turn: f64
	done := 0
	for done < N && time.duration_seconds(time.tick_since(t0)) < 120 {
		if host.next_timeout_ms(&loop) != 0 { sync.sema_wait_with_timeout(&loop.sema, time.Millisecond) }
		r0 := time.tick_now()
		host.run_ready(&loop)   // the UI thread's share of the work: relaying 16 workers' messages
		worst_turn = max(worst_turn, time.duration_milliseconds(time.tick_since(r0)))
		c0 := time.tick_now()
		wasm.call_i32(inst, "ping")
		worst_call = max(worst_call, time.duration_milliseconds(time.tick_since(c0)))
		done = 0
		for l in logs { if strings.contains(l, ":done:") { done += 1 } }
	}
	host.clear_timer(&loop, tick)
	t16 := time.duration_milliseconds(time.tick_since(t0))
	quiet = false
	check(done == N, fmt.tprintf("%d workers finished (%d)", N, done))
	check(true, fmt.tprintf("one worker alone: %.0f ms; %d in parallel: %.0f ms; speed-up %.1fx", t1, N, t16, f64(N) * t1 / t16))
	check(probe.worst < idle.worst + 10, fmt.tprintf("UI loop stays responsive: worst gap between 1 ms timer ticks %.1f ms over %d ticks (idle: %.1f ms over %d ticks in 1 s)", probe.worst, probe.ticks, idle.worst, idle.ticks))
	check(worst_turn < 10, fmt.tprintf("longest turn of the UI loop (its tasks, timers included) %.2f ms", worst_turn))
	check(worst_call < 20, fmt.tprintf("calls into the page module meanwhile: worst %.2f ms", worst_call))
	for i in 0 ..< N { call1("release", 40 + i) }

	////////////////////////////////
	fmt.println("-- closing a page with busy workers")
	check(pump_until(proc() -> bool { return hosts() == 1 && page.workers_running() == 1 }), "the 16 released workers are joined")
	running := page.workers_running()
	cp := page.page_create(&loop, &loader, &settings, process, "http://127.0.0.1:8765/close.html", console)
	ci, _, _ := page.load_module(cp, image, "close")
	clear_logs()
	for i in 0 ..< 4 { make_worker(i, WORKER, cp, ci) }
	for i in 0 ..< 4 { wait_log(fmt.tprintf("msg:%d:ready", i)) }
	for i in 0 ..< 4 { send(i, i % 2 == 0 ? "spin" : "spin_hard", ci, cp) }
	pump(100)
	t0 = time.tick_now()
	page.page_close(cp)
	dt = time.duration_milliseconds(time.tick_since(t0))
	check(page.workers_running() == running, fmt.tprintf("page_close stopped and joined its 4 busy workers in %.1f ms", dt))
	pump(100)

	////////////////////////////////
	call1("terminate", 0)
	page.page_close(p)
	pump_until(proc() -> bool { return page.workers_running() == 0 })
	check(page.workers_running() == 0, "no worker left")
	base.scope_close(process)
	for _ in 0 ..< 10 { host.loop_wait(&loop, 10) }
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	wasm.runtime_destroy()
	win.timeEndPeriod(1)
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
