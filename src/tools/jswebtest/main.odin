// End-to-end test of the web APIs of JavaScript (native/js/runtime/web*.c): each test is a script of
// examples/jsweb/*.js run in a page of the test server's origin, with a small harness (examples/jsweb/harness.js) whose
// results come back through the console: "ok <what>", "FAIL <what>", "MEASURE <name> <value>", "SIGNAL <name>" (the
// script waits for this tool to act on the page, then resumes) and "DONE". Needs build\testserver.exe running (ports
// 8765-8767). Run from the repository root:
//   jswebtest.exe [name...]
package jswebtest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:net"
import "wb:page"
import "wb:wasm"

BASE :: "http://127.0.0.1:8765"
PAGE :: BASE + "/jsweb/page"
DIR :: "examples/jsweb"
PROFILE_DIR :: "build/jswebtest_profile"

failures: int
passes: int
measures: [dynamic]string

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

Page_Log :: struct {
	name:  string,
	lines: [dynamic]string,
	seen:  int,        // lines already looked at by the pump
	done:  bool,
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	l := (^Page_Log)(user)
	append(&l.lines, strings.clone(message))
	if strings.has_prefix(message, "ok ") { passes += 1; return }
	if strings.has_prefix(message, "FAIL ") { failures += 1; fmt.printf("FAIL [%s] %s\n", l.name, message[5:]); return }
	if strings.has_prefix(message, "MEASURE ") { append(&measures, fmt.aprintf("%s %s", l.name, message[8:])); fmt.printf("  measure %s\n", message[8:]); return }
	if message == "DONE" { l.done = true; return }
	if strings.has_prefix(message, "SIGNAL ") { return }
	fmt.printf("  [%s %v] %s\n", l.name, level, message)
}

navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	append(&navigations, fmt.aprintf("%v %s", req.kind, req.url))
}

Action :: #type proc(p: ^page.Page, l: ^Page_Log)

Running :: struct {
	p:   ^page.Page,
	log: ^Page_Log,
}

harness: string

// Opens a page at `address` running examples/jsweb/<name>.js after the harness.
open :: proc(name: string, address := PAGE, tab_key := "tab-1") -> Running {
	src, err := os.read_entire_file(fmt.tprintf("%s/%s.js", DIR, name), context.allocator)
	if err != nil { fmt.printf("FAIL cannot read %s/%s.js\n", DIR, name); failures += 1; return {} }
	l := new(Page_Log)
	l.name = name
	p := page.page_create(&loop, &loader, &settings, process, address, console, l)
	page.set_embedder(p, {navigate = navigate_hook, session = &session, tab_key = tab_key, storage = &storage})
	html := strings.concatenate({"<!doctype html><meta charset=utf-8><title>", name, "</title><body><script>", harness, "</script><script>", string(src), "</script></body>"})
	page.load_html(p, transmute([]byte)html)
	page.scripts_start(p)
	return {p, l}
}

// Pumps the loop until the page's script says DONE (or `seconds` pass), running the action of each SIGNAL.
wait :: proc(r: Running, actions: map[string]Action = nil, seconds := 30.0) -> bool {
	if r.p == nil { return false }
	start := time.tick_now()
	for !r.log.done {
		for r.log.seen < len(r.log.lines) {
			line := r.log.lines[r.log.seen]
			r.log.seen += 1
			if !strings.has_prefix(line, "SIGNAL ") { continue }
			name := line[len("SIGNAL "):]
			if a, ok := actions[name]; ok { a(r.p, r.log) }
			page.js_run(r.p, transmute([]byte)fmt.tprintf("__resume(%q)", name), "jswebtest.js")
		}
		if time.duration_seconds(time.tick_since(start)) > seconds {
			fmt.printf("FAIL [%s] timeout: the script did not finish in %.0f s; its last messages:\n", r.log.name, seconds)
			for line in r.log.lines[max(0, len(r.log.lines) - 6):] { fmt.printf("    %s\n", line) }
			failures += 1
			return false
		}
		host.loop_wait(&loop, 5)
	}
	return true
}

close :: proc(r: Running) {
	if r.p != nil { page.page_close(r.p) }
}

run :: proc(name: string, actions: map[string]Action = nil, address := PAGE, seconds := 30.0) {
	fmt.printf("-- %s\n", name)
	r := open(name, address)
	wait(r, actions, seconds)
	close(r)
}

selected :: proc(name: string) -> bool {
	if len(os.args) < 2 { return true }
	for a in os.args[1:] { if a == name { return true } }
	return false
}

// Runs the loop until `done` says so; `seconds` only ends a run that fails (nothing checked depends on how long it took).
wait_until :: proc(done: proc() -> bool, what: string, seconds := 30.0) -> bool {
	start := time.tick_now()
	for !done() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("FAIL timeout waiting for %s\n", what); failures += 1; return false }
		host.loop_wait(&loop, 5)
	}
	return true
}

// Runs what is ready now (posted tasks, due timers), turn after turn, until nothing is.
drain :: proc() {
	for _ in 0 ..< 1000 {
		if host.next_timeout_ms(&loop) != 0 { return }
		host.loop_wait(&loop, 0)
	}
}

listener_log: ^Page_Log

host_objects :: proc(p: ^page.Page) -> int { return p.objects.pool.count }

main :: proc() {
	h, herr := os.read_entire_file(DIR + "/harness.js", context.allocator)
	if herr != nil { fmt.eprintln("cannot read examples/jsweb/harness.js (run from the repository root)"); os.exit(2) }
	harness = string(h)

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	settings.web.storage_quota = 4000
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	js.cache_start({memory_bytes = 16 << 20, min_source_bytes = 0})
	os.remove_all(PROFILE_DIR)
	page.storage_manager_init(&storage, &loop, &blocking, PROFILE_DIR)
	process = base.scope_make("process")

	if selected("core") { run("core") }
	if selected("url") { run("url") }
	if selected("abort") { run("abort") }
	if selected("blob") { run("blob") }
	if selected("streams") { run("streams") }
	if selected("fetch_objects") { run("fetch_objects") }
	if selected("fetch") { run("fetch", seconds = 90) }
	if selected("xhr") { run("xhr") }
	if selected("perf_crypto") { run("perf_crypto") }
	if selected("message") { run("message") }
	if selected("sockets") { run("sockets") }

	if selected("navigator") {
		fmt.println("-- navigator")
		r := open("navigator")
		wait(r)
		ua := r.p.loader.net.settings.user_agent
		found := false
		for l in r.log.lines { if l == fmt.tprintf("UA %s", ua) { found = true } }
		if !found { fmt.printf("FAIL [navigator] navigator.userAgent is not the User-Agent header (%q)\n", ua); failures += 1 } else { passes += 1 }
		close(r)
	}

	if selected("storage") {
		fmt.println("-- storage (two pages of one origin, the storage event)")
		listener := open("storage_listener")
		listener_log = listener.log
		wait_until(proc() -> bool { for l in listener_log.lines { if l == "LISTENING" { return true } }; return false }, "the storage listener")
		writer := open("storage")
		wait(writer)
		wait(listener)
		close(writer)
		close(listener)
	}

	if selected("history") {
		fmt.println("-- location and history")
		clear(&navigations)
		actions := make(map[string]Action, context.temp_allocator)
		actions["navigations"] = proc(p: ^page.Page, l: ^Page_Log) {
			want := []string{fmt.tprintf("Assign %s/jsweb/other", BASE), fmt.tprintf("Replace %s/jsweb/replaced", BASE), "Reload"}
			wait_until(proc() -> bool {
				n := 0
				for w in ([]string{"Assign ", "Replace ", "Reload"}) { for x in navigations { if strings.has_prefix(x, w) { n += 1; break } } }
				return n == 3
			}, "the three navigations")
			for w in want {
				found := false
				for n in navigations { if strings.has_prefix(n, w) { found = true } }
				if found { passes += 1 } else { fmt.printf("FAIL [history] the embedder was asked to navigate: %s (got %v)\n", w, navigations[:]); failures += 1 }
			}
		}
		run("history", actions, BASE + "/jsweb/page?x=1")
	}

	if selected("media") {
		fmt.println("-- matchMedia (the page's style computation reports changes)")
		actions := make(map[string]Action, context.temp_allocator)
		actions["wide"] = proc(p: ^page.Page, l: ^Page_Log) { page.styles(p, 1200, 800, 1) }
		actions["narrow"] = proc(p: ^page.Page, l: ^Page_Log) { page.styles(p, 400, 800, 1) }
		run("media", actions)
	}

	if selected("gc") {
		fmt.println("-- lifetime: what JavaScript dropped is released in the browser")
		r := open("gc")
		wait(r)
		before := host_objects(r.p)
		js.collect(r.p.js.inst)
		drain()
		after := host_objects(r.p)
		fmt.printf("  host objects before collection %d, after %d\n", before, after)
		if before > after && after < 100 { passes += 1 } else { fmt.printf("FAIL [gc] host objects of collected wrappers are released (%d -> %d)\n", before, after); failures += 1 }
		close(r)
	}

	if selected("bench") { run("bench", seconds = 120) }

	base.scope_close(process)
	page.storage_manager_destroy(&storage)
	js.cache_stop()
	fmt.printf("\n%d passed, %d failure(s)\n", passes, failures)
	os.exit(failures > 0 ? 1 : 0)
}
