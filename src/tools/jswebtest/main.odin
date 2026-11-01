// End-to-end test of the web APIs of JavaScript (native/js/runtime/web*.c), under core:testing: each section is one @(test)
// (sections.odin) that runs scripts of examples/jsweb/*.js in pages of the test server's origin, after a small harness
// (examples/jsweb/harness.js). What a script finds comes back through the functions of `wrenTest` (src/tools/testhost,
// api/testhost.widl), and each section declares how many tests it runs: testhost.finish fails what ran another number, ran
// nothing or ended early. Needs build\testserver.exe running (ports 8765-8767, or the block of WREN_TEST_BASE_PORT:
// src/tools/testenv), and one test at a time (-define:ODIN_TEST_THREADS=1): every section makes its own loop, loader and
// profile, on the runner's one thread, and they all share what is the process's (the Wasm runtime, the GPU process, the image
// cache). Run from the repository root:
//   odin test src/tools/jswebtest -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false ... -out:build/jswebtest.exe
//   tools\jsweb_run.ps1 core webgl_process      (a test server around build\jswebtest.exe -tests:core,webgl_process)
package jswebtest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:media"
import "wb:net"
import "wb:page"
import "wb:wasm"
import "wb:webgl"
import "wb:tools/testenv"
import "wb:tools/testhost"

BASE :: "http://127.0.0.1:8765"   // on the run's block of ports through testenv.url (addresses and scripts)
PAGE :: BASE + "/jsweb/page"
DIR :: "examples/jsweb"
PROFILE_DIR :: "build/jswebtest_profile"
BLOCKING_THREADS :: 2
STORAGE_QUOTA_BYTES :: 4000
SCRIPT_CACHE_BYTES :: 16 << 20
DEFAULT_SECTION_SECONDS :: 30.0
LOOP_LOOK_MS :: 5          // the most the loop waits before a section looks again: anything that happens ends the wait sooner
DRAIN_MAX_TURNS :: 1000
LAST_LINES_ON_TIMEOUT :: 6
// The probe of an adapter when a script says there is none (verify_skip).
ADAPTER_PROBE_WAIT_MS :: 60_000
ADAPTER_PROBE_SIZE :: 8
ADAPTER_PROBE_MESSAGE_BYTES :: 512
NO_ADAPTER_MESSAGE :: "no graphics adapter"   // what the GPU process says, and only then (native/webgl/src/host.rs)

// A section's world: made and destroyed around each @(test) on the runner's one thread.
loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
storage:  page.Storage_Manager
process:  ^base.Scope
session:  page.Session_History
navigations: [dynamic]string
harness:  string
current:  ^testing.T
world_made: bool

// What the program does to a page when its script signals. Its string is what signal() resolves to in the script (a JavaScript
// expression; "" nothing).
Action :: #type proc(r: ^Running) -> string

// One page of a section.
Running :: struct {
	p:       ^page.Page,
	section: testhost.Section,
	lines:   [dynamic]string,   // its console, the end of which is said when it times out
}

// The console is the page's own output: no result is read from it, what a test says goes through wrenTest.
console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	r := (^Running)(user)
	append(&r.lines, strings.clone(message))
	fmt.printf("  [%s %v] %s\n", r.section.name, level, message)
}

navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	append(&navigations, fmt.aprintf("%v %s", req.kind, req.url))
}

// The world is one for the whole run, made by the first section and undone by the last test, on the runner's one thread: what the
// process keeps (the image cache, the stores of files and of the Cache API, the timeline) binds to the first loop it sees, so a
// loop per @(test) would leave them on a dead one. Each section gets default settings, and its own console and verdict.
// Every test first gives itself the process's allocator (`context.allocator = base.process_allocator()`, a Wasm import runs with
// it and what a page's calls make is freed here): core:testing's tracker of the test does not know that memory; the leaks are
// found by the process's tracker, in the last test (-define:WREN_TRACK_MEMORY=true).
section_begin :: proc(t: ^testing.T) {
	current = t
	if !world_made {
		world_made = true
		h, herr := os.read_entire_file(DIR + "/harness.js", context.allocator)
		testing.expect(t, herr == nil, "cannot read examples/jsweb/harness.js (run from the repository root)")
		harness = string(h)
		host.loop_init(&loop)
		testing.expect(t, net.client_init(&client, &loop), "net init")
		host.blocking_init(&blocking, &loop, BLOCKING_THREADS)
		profile = fetch.profile_make()
		fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
		wasm.configure_from_args(nil)
		testing.expect(t, page.register_imports(), "imports")
		js.cache_start({memory_bytes = SCRIPT_CACHE_BYTES, min_source_bytes = 0})
		testenv.remove_tree(PROFILE_DIR)
		page.storage_manager_init(&storage, &loop, &blocking, PROFILE_DIR)
		process = base.scope_make("process")
	}
	settings = page.settings_default()
	settings.web.storage_quota = STORAGE_QUOTA_BYTES
	if os.get_env("JSWEB_NOJIT", context.temp_allocator) != "" { settings.js.jit.enabled = false }   // (to tell an engine bug from a script's)
}

section_end :: proc() {
	drain()
	page.settings_destroy(&settings)
	page.session_destroy(&session)
	session = {}
	for s in navigations { delete(s) }
	delete(navigations)
	navigations = nil
	current = nil
}

world_end :: proc() {
	if !world_made { return }
	base.scope_close(process)
	host.blocking_settle(&blocking)
	page.storage_manager_destroy(&storage)
	host.blocking_settle(&blocking)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	page.discard_page_tasks(&loop)
	host.loop_destroy(&loop)
	delete(harness)
}

// Opens a page at `address` running examples/jsweb/<name>.js after the harness.
open :: proc(name: string, address := PAGE, tab_key := "tab-1") -> ^Running {
	r := new(Running)
	r.section.name = name
	src, err := os.read_entire_file(fmt.tprintf("%s/%s.js", DIR, name), context.allocator)
	if err != nil { testing.expectf(current, false, "cannot read %s/%s.js", DIR, name); return r }
	defer delete(src)
	r.p = page.page_create(&loop, &loader, &settings, process, testenv.url(address), console, r)
	testhost.attach(&r.section, r.p)
	page.set_embedder(r.p, {navigate = navigate_hook, session = &session, tab_key = tab_key, storage = &storage})
	html := strings.concatenate({"<!doctype html><meta charset=utf-8><title>", name, "</title><body><script>", harness, "</script><script>", testenv.url(string(src)), "</script></body>"})
	page.load_html(r.p, transmute([]byte)html)
	delete(html)
	page.scripts_start(r.p)
	return r
}

// Pumps the loop until the script says it is done (or `seconds` pass), running the action of each signal.
wait :: proc(r: ^Running, actions: map[string]Action = nil, seconds := DEFAULT_SECTION_SECONDS) -> bool {
	if r.p == nil { return false }
	start := time.tick_now()
	seen := 0
	for !r.section.finished {
		for seen < len(r.section.signals) {
			name := r.section.signals[seen]
			seen += 1
			answer := "undefined"
			if a, ok := actions[name]; ok { if v := a(r); v != "" { answer = v } }
			page.js_run(r.p, transmute([]byte)fmt.tprintf("__resume(%q, %s)", name, answer), "jswebtest.js")
		}
		testhost.flush(&r.section, current)
		if time.duration_seconds(time.tick_since(start)) > seconds {
			testing.expectf(current, false, "[%s] timeout: the script did not finish in %.0f s; its last lines: %v", r.section.name, seconds, r.lines[max(0, len(r.lines) - LAST_LINES_ON_TIMEOUT):])
			return false
		}
		host.loop_wait(&loop, LOOP_LOOK_MS)
	}
	return true
}

// The page's end, and the section's verdict: `tests` is how many tests it declares.
close :: proc(r: ^Running, tests: int) {
	if r.p != nil { page.page_close(r.p) }
	testhost.finish(&r.section, current, tests = tests, verify_skip = verify_skip)
	for l in r.lines { delete(l) }
	delete(r.lines)
	free(r)
}

// A page of one script: its tests, its verdict.
run :: proc(name: string, tests: int, actions: map[string]Action = nil, address := PAGE, seconds := DEFAULT_SECTION_SECONDS) {
	r := open(name, address)
	wait(r, actions, seconds)
	close(r, tests)
}

// Runs the loop until `done` says so; `seconds` only ends a run that fails (nothing checked depends on how long it took).
wait_until :: proc(done: proc() -> bool, what: string, seconds := DEFAULT_SECTION_SECONDS) -> bool {
	start := time.tick_now()
	for !done() {
		if time.duration_seconds(time.tick_since(start)) > seconds { testing.expectf(current, false, "timeout waiting for %s", what); return false }
		host.loop_wait(&loop, LOOP_LOOK_MS)
	}
	return true
}

// Runs what is ready now (posted tasks, due timers), turn after turn, until nothing is.
drain :: proc() {
	for _ in 0 ..< DRAIN_MAX_TURNS {
		if host.next_timeout_ms(&loop) != 0 { return }
		host.loop_wait(&loop, 0)
	}
}

host_objects :: proc(p: ^page.Page) -> int { return p.objects.pool.count }

// A script says this machine cannot run it. Is that true? Asked of the machine, not of the page.
verify_skip :: proc(reason: page.Test_Skip_Reason) -> (testhost.Skip_Verdict, string) {
	switch reason {
	case .WebglAdapter: return adapter_probe()
	case .Av1Decoder:
		// (rav1d is built in, on every system: what the browser would answer, asked directly)
		if media.codec_supported(.AV1, settings.media) { return .Present, "the media backend has an AV1 decoder" }
		return .Absent, "the media backend has no AV1 decoder"
	}
	return .Unknown, "an unknown reason"
}

// A context made on its own, away from the page that could not have one, with all the time it takes. A context: the machine has
// an adapter, and what the page saw was something else (a slow device, a process that went). "No adapter" from the GPU process:
// it has none. Anything else says nothing about the machine.
adapter_probe :: proc() -> (testhost.Skip_Verdict, string) {
	s := &settings.webgl
	attrs := webgl.Attrs{
		alpha = 1, depth = 1,
		width = ADAPTER_PROBE_SIZE, height = ADAPTER_PROBE_SIZE, max_dimension = ADAPTER_PROBE_SIZE,
		allow_software = 1, backend = s.backend, max_bytes = s.max_bytes, wait_ms = ADAPTER_PROBE_WAIT_MS,
		hang_ms = s.gpu_hang_ms, max_restarts = s.gpu_max_restarts, restart_window_ms = s.gpu_restart_window_ms, idle_exit_ms = s.gpu_idle_exit_ms,
	}
	inf: webgl.Info
	err: [ADAPTER_PROBE_MESSAGE_BYTES]u8
	err_len: uint
	h := webgl.wg_create(&attrs, &inf, &err[0], len(err), &err_len)
	if h != nil {
		webgl.wg_destroy(h)
		return .Present, "a context made just now has an adapter"
	}
	said := strings.clone(string(err[:err_len]), context.temp_allocator)
	if strings.contains(said, NO_ADAPTER_MESSAGE) { return .Absent, said }
	return .Unknown, said
}

// A last test, by the order of names: what the process keeps goes, and with -define:WREN_TRACK_MEMORY=true whatever the sections
// left behind shows. It is left out when -tests: does not name it.
@(test)
zz_the_process_ends_with_nothing_left :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	world_end()
	testing.expect_value(t, testenv.mem_check("jswebtest"), 0)
	all := testhost.totals
	fmt.printf("\n%d sections\n%d passed, %d failure(s), %d skipped\n", all.sections, all.passes, all.failures, all.skips)
}
