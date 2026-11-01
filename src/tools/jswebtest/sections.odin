package jswebtest

// The sections: one @(test) each. `tests` is what the section declares it runs; another number fails it (testhost.finish), and so
// does a section that ended before its script said done.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:js"
import "wb:page"
import "wb:webgl"
import "wb:tools/testenv"
import "wb:tools/testhost"

WEB_AUDIO_SLOW_SCRIPT_MS :: 120_000
// The GPU process's limits while it is hung on purpose: the time after which it is killed (twice that on the software adapter of these
// tests), restarts that are not counted against anything.
WEBGL_TEST_HANG_MS :: 3000
WEBGL_TEST_RESTARTS :: 1000
IDB_QUOTA_TEST_BYTES :: 1 << 20
AUTOPLAY_MAX_LIVE_NODES :: 400
GC_MAX_HOST_OBJECTS :: 100
CANVAS_BYTES_BEFORE_MIN :: 100_000_000
CANVAS_BYTES_AFTER_MAX :: 8_000_000     // what stays: the canvas kept (500 x 500 x 4 = 1 MB) and the copies cached for drawing
VIEW_WIDE :: 1200
VIEW_NARROW :: 400
VIEW_H :: 800
NAVIGATIONS_ASKED :: 3
WEBGL_PROCESS_TESTS :: 5
SKIP_TEST_SECONDS :: 30.0

@(test) core :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("core", tests = 8) }
@(test) compile_large :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("compile_large", tests = 3) }
@(test) url :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("url", tests = 4) }
@(test) abort :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("abort", tests = 6) }
@(test) blob :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("blob", tests = 4) }
@(test) streams :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("streams", tests = 11) }
@(test) fetch_objects :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("fetch_objects", tests = 4) }
@(test) fetch_api :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("fetch", tests = 8, seconds = 90) }
@(test) xhr :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("xhr", tests = 6) }
@(test) perf_crypto :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("perf_crypto", tests = 2) }
@(test) webcrypto :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("webcrypto", tests = 15, seconds = 120) }
@(test) message :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("message", tests = 5) }
@(test) sockets :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("sockets", tests = 3) }
@(test) canvas :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("canvas", tests = 16) }
@(test) geometry :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("geometry", tests = 10) }
@(test) compat :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("compat", tests = 7) }
@(test) idb :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("idb", tests = 11, seconds = 60) }
@(test) idb_worker :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("idb_worker", tests = 4, seconds = 60) }
@(test) idb_buckets :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("idb_buckets", tests = 3, seconds = 60) }
@(test) idb_keys :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("idb_keys", tests = 4, seconds = 60) }
@(test) htmlmedia :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("htmlmedia", tests = 12, seconds = 120) }
@(test) mse :: proc(t: ^testing.T) { context.allocator = base.process_allocator(); section_begin(t); defer section_end(); run("mse", tests = 13, seconds = 120) }

// (the two benchmarks only measure: performance runs, tools\test_all.ps1 -Perf)
@(test)
idb_bench :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	if base.perf_skip("jswebtest idb_bench: IndexedDB micro-benchmarks") { return }
	section_begin(t)
	defer section_end()
	run("idb_bench", tests = 3, seconds = 120)
}

@(test)
bench :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	if base.perf_skip("jswebtest bench: the cost of a web API call") { return }
	section_begin(t)
	defer section_end()
	run("bench", tests = 1, seconds = 120)
}

@(test)
webaudio :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	settings.media.autoplay = .Allow_All
	run("webaudio", tests = 21, seconds = 60)
}

@(test)
webaudio_autoplay :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["gesture"] = proc(r: ^Running) -> string { page.dispatch_event(r.p, r.p.body, dom.Event{type = "mousedown", bubbles = true, cancelable = true}); return "" }
	actions["collect"] = proc(r: ^Running) -> string { js.collect(r.p.js.inst); return "" }
	actions["count"] = proc(r: ^Running) -> string {
		n := page.web_audio_live_nodes(r.p)
		testhost.expect(&r.section, current, n < AUTOPLAY_MAX_LIVE_NODES, fmt.tprintf("%d nodes are still in the graph", n))
		return ""
	}
	// (2000 sounds in one task: slow on a loaded machine, and the hard stop is four times the limit on scripts)
	settings.js.slow_script_ms = WEB_AUDIO_SLOW_SCRIPT_MS
	run("webaudio_autoplay", tests = 1, actions = actions)
}

// (the software adapter: the same pixels everywhere, and what the CI has)
@(private = "file")
webgl_settings :: proc() {
	settings.webgl.force_software = true
	// (a test is one task that waits for the software rasterizer, and FXC compiles for it: slow on a loaded machine)
	settings.js.slow_script_ms = 120_000   // (not -1: the hard stop of wasm.max_call_ms, one second, would be the limit)
}

@(test)
webgl_api :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	webgl_settings()
	actions := make(map[string]Action, context.temp_allocator)
	actions["frame"] = proc(r: ^Running) -> string { page.images_sync(r.p); page.canvas_frame(r.p); return "" }
	run("webgl", tests = 23, actions = actions, seconds = 300)
}

// The GPU process killed and hung (test hooks): quick limits, and no limit on restarts for what is killed on purpose.
@(test)
webgl_process :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	webgl_settings()
	webgl.wg_test_enable_hooks()
	settings.webgl.gpu_hang_ms, settings.webgl.gpu_max_restarts = WEBGL_TEST_HANG_MS, WEBGL_TEST_RESTARTS
	// (the process of a section before has no hooks: this one ends it, and the next has them)
	webgl.wg_test_kill_process()
	actions := make(map[string]Action, context.temp_allocator)
	actions["gpu_kill"] = proc(r: ^Running) -> string { webgl.wg_test_kill_process(); return "" }
	actions["gpu_hang"] = proc(r: ^Running) -> string { page.webgl_test_hang(r.p); return "" }
	actions["gpu_info"] = proc(r: ^Running) -> string { return fmt.tprintf("({{ pid: %d, starts: %d }})", webgl.wg_test_process_id(), webgl.wg_test_process_starts()) }
	run("webgl_process", tests = WEBGL_PROCESS_TESTS, actions = actions, seconds = 300)
}

@(test)
webassembly :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	r := open("webassembly")
	wait(r)
	before := host_objects(r.p)
	js.collect(r.p.js.inst)
	drain()
	after := host_objects(r.p)
	testhost.expect(&r.section, t, before > after, fmt.tprintf("the modules of collected objects are released (%d -> %d)", before, after))
	close(r, tests = 23)
}

@(test)
perf_timeline :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["click"] = proc(r: ^Running) -> string { page.dispatch_event(r.p, r.p.body, dom.Event{type = "click", bubbles = true, cancelable = true}); return "" }
	run("perf_timeline", tests = 7, actions = actions)
}

// IndexedDB across pages and across a restart of the data manager: versionchange / blocked between two pages, the journal
// read again after the manager was destroyed and made anew, the quota, and "Clear site data".
@(test)
idb_pages :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	@(static) a_page, b_page: ^Running
	a := open("idb_pages_a")
	a_page = a
	wait_until(proc() -> bool { return testhost.noted(&a_page.section, "LISTENING") }, "page A listening")
	b := open("idb_pages_b")
	b_page = b
	wait_until(proc() -> bool { return testhost.noted(&a_page.section, "HEARD") && testhost.noted(&b_page.section, "BLOCKED") }, "page A hearing the version change, page B blocked")
	page.js_run(a.p, transmute([]byte)string("__closeA()"), "jswebtest.js")
	wait(b)
	wait(a)
	close(b, tests = 2)
	close(a, tests = 2)

	// restart: the manager goes (journals flushed), a new one reads the files
	host_settle_and_restart_storage()
	run("idb_persist", tests = 1)

	// quota: 1 MiB for the origin
	saved := settings.idb.quota_bytes
	settings.idb.quota_bytes = IDB_QUOTA_TEST_BYTES
	run("idb_quota", tests = 1)
	settings.idb.quota_bytes = saved

	// clear site data while a connection is open
	c := open("idb_clear")
	actions := make(map[string]Action, context.temp_allocator)
	actions["clear"] = proc(r: ^Running) -> string { page.idb_clear_origin(&storage, page.storage_origin_key(r.p)); return "" }
	wait(c, actions)
	close(c, tests = 1)
}

@(test)
navigator :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	r := open("navigator")
	wait(r)
	ua := r.p.loader.net.settings.user_agent
	testhost.expect(&r.section, t, testhost.noted(&r.section, fmt.tprintf("UA %s", ua)), fmt.tprintf("navigator.userAgent is not the User-Agent header (%q)", ua))
	close(r, tests = 4)
}

// Two pages of one origin, the storage event.
@(test)
storage_event :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	@(static) listening: ^Running
	listener := open("storage_listener")
	listening = listener
	wait_until(proc() -> bool { return testhost.noted(&listening.section, "LISTENING") }, "the storage listener")
	writer := open("storage")
	wait(writer)
	wait(listener)
	close(writer, tests = 5)
	close(listener, tests = 1)
}

// Location and history.
@(test)
history :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["navigations"] = proc(r: ^Running) -> string {
		want := []string{fmt.tprintf("Assign %s/jsweb/other", testenv.url(BASE)), fmt.tprintf("Replace %s/jsweb/replaced", testenv.url(BASE)), "Reload"}
		wait_until(proc() -> bool {
			n := 0
			for w in ([]string{"Assign ", "Replace ", "Reload"}) { for x in navigations { if strings.has_prefix(x, w) { n += 1; break } } }
			return n == NAVIGATIONS_ASKED
		}, "the three navigations")
		for w in want {
			found := false
			for n in navigations { if strings.has_prefix(n, w) { found = true } }
			testhost.expect(&r.section, current, found, fmt.tprintf("the embedder was asked to navigate: %s (got %v)", w, navigations[:]))
		}
		return ""
	}
	run("history", tests = 5, actions = actions, address = BASE + "/jsweb/page?x=1")
}

// matchMedia: the page's style computation reports changes.
@(test)
media_queries :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["wide"] = proc(r: ^Running) -> string { page.styles(r.p, VIEW_WIDE, VIEW_H, 1); return "" }
	actions["narrow"] = proc(r: ^Running) -> string { page.styles(r.p, VIEW_NARROW, VIEW_H, 1); return "" }
	run("media", tests = 1, actions = actions)
}

// Lifetime: what JavaScript dropped is released in the browser.
@(test)
gc :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	r := open("gc")
	wait(r)
	before := host_objects(r.p)
	js.collect(r.p.js.inst)
	drain()
	after := host_objects(r.p)
	testhost.expect(&r.section, t, before > after && after < GC_MAX_HOST_OBJECTS, fmt.tprintf("host objects of collected wrappers are released (%d -> %d)", before, after))
	close(r, tests = 1)
}

// Lifetime: the bitmaps of dropped canvases are freed.
@(test)
canvas_gc :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	r := open("canvas_gc")
	wait(r)
	before := page.canvas_bytes(r.p)
	js.collect(r.p.js.inst)
	drain()
	page.canvas_frame(r.p)   // (what the shell does each frame: the elements the document freed)
	after := page.canvas_bytes(r.p)
	testhost.expect(&r.section, t, before > CANVAS_BYTES_BEFORE_MIN && after < CANVAS_BYTES_AFTER_MAX, fmt.tprintf("the bitmaps of collected canvases are freed (%d -> %d)", before, after))
	close(r, tests = 2)
}

// A page that was given no test host, which is every page of a browser, has no wrenTest.
@(test)
a_page_without_a_test_host_has_no_test_functions :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	@(static) seen: [dynamic]string
	p := page.page_create(&loop, &loader, &settings, process, testenv.url(PAGE), proc(_: rawptr, _: page.Log_Level, message: string) { append(&seen, strings.clone(message)) })
	source := `<!doctype html><body><script>console.log(typeof wrenTest + " " + typeof globalThis.wrenTest)</script></body>`
	page.load_html(p, transmute([]byte)string(source))
	page.scripts_start(p)
	wait_until(proc() -> bool { return len(seen) > 0 }, "the page's script")
	testing.expect(t, len(seen) == 1 && seen[0] == "undefined undefined", "a browser's page has no wrenTest")
	page.page_close(p)
	for s in seen { delete(s) }
	delete(seen)
	seen = nil
}

// What was silently passed for months: the script finds no WebGL context, here because the page has it switched off, on a machine
// that has an adapter. Its skip must fail the section, not pass it.
@(test)
a_skip_that_is_not_true_of_the_machine_fails_the_section :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	settings.webgl.enabled = false
	r := open("webgl_process")
	wait(r, seconds = SKIP_TEST_SECONDS)
	page.page_close(r.p)
	r.p = nil
	testing.expect(t, r.section.skipped, "the script said it could not run")
	testing.expect_value(t, r.section.begun, 0)
	settings.webgl.enabled = true
	verdict, _ := adapter_probe()
	problems, true_skips := testhost.judge(&r.section, tests = WEBGL_PROCESS_TESTS, verify_skip = verify_skip)
	if verdict == .Absent {
		testing.expect_value(t, len(true_skips), 1)   // (this machine really has none: reported and counted)
	} else {
		testing.expect_value(t, len(true_skips), 0)
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], "not what this machine says"), "%v", problems)
	}
	testhost.forget(&r.section)
	for l in r.lines { delete(l) }
	delete(r.lines)
	free(r)
}

// The manager of IndexedDB goes (its journals flushed) and a new one reads the files.
@(private = "file")
host_settle_and_restart_storage :: proc() {
	host.blocking_settle(&blocking)
	page.storage_manager_destroy(&storage)
	host.blocking_settle(&blocking)
	page.storage_manager_init(&storage, &loop, &blocking, PROFILE_DIR)
}
