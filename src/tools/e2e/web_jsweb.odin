#+build windows
#+private file
// The web APIs of JavaScript (native/js/runtime/web*.c): each section is one test, which runs scripts of examples/jsweb/*.js in pages of
// the test server's origin, after a small harness (examples/jsweb/harness.js). What a script finds comes back through `wrenTest`, and each
// section declares how many tests it runs: testhost.finish fails what ran another number, ran nothing or ended early. A section alone:
//   build\e2e_test.exe -tests:jsweb_core,zz_the_process_ends_with_nothing_left
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:idb"
import "wb:js"
import "wb:media"
import "wb:page"
import "wb:tools/testenv"
import "wb:tools/testhost"
import "wb:wasm"
import "wb:webgl"

BASE :: "http://127.0.0.1:8765"   // on the server's block of ports through testenv.url (addresses and scripts)
PAGE :: BASE + "/jsweb/page"
DIR :: "examples/jsweb"
STORAGE_QUOTA_BYTES :: 4000
SLOW_SCRIPT_MS :: 120_000   // a task that waits for the software rasterizer, 2000 sounds in one task: slow on a loaded machine, and the hard stop is four times the limit on scripts
IDB_QUOTA_TEST_BYTES :: 1 << 20
CUT_SECTIONS := [?]string{"abort", "blob", "canvas", "canvas_gc", "compat", "compile_large", "core", "fetch", "fetch_objects", "gc", "geometry", "history", "htmlmedia", "idb", "idb_buckets", "idb_clear", "idb_keys", "idb_pages_a", "idb_pages_b", "idb_persist", "idb_quota", "idb_worker", "media", "message", "navigator", "perf_crypto", "perf_timeline", "sockets", "storage", "storage_listener", "streams", "url", "webassembly", "webaudio", "webaudio_autoplay", "webcrypto", "xhr"}
BROKEN_PAGES := [?]string{"<!doctype html><script>}{</script>", "<!doctype html><script>throw new Error(\"on purpose\")</script>"}
CUT_AFTER_TURNS := [?]int{0, 1, 10, 100}   // turns of the loop before a page is closed: a count, so the cut is the same on any machine
OTHER_PROGRAM_TEST :: "webapi_closing_and_restart"   // (a test of a few milliseconds that empties a profile first)
GC_MAX_HOST_OBJECTS :: 100
CANVAS_BYTES_BEFORE_MIN :: 100_000_000
CANVAS_BYTES_AFTER_MAX :: 8_000_000     // what stays: the canvas kept (500 x 500 x 4 = 1 MB) and the copies cached for drawing
VIEW_WIDE :: 1200
VIEW_NARROW :: 400
VIEW_H :: 800
WEBGL_SKIP_TESTS :: 1
RUNNER_DECODER_THREADS :: 2   // a software video's threads on a machine of four processors, a CI runner

session:     page.Session_History
navigations: [dynamic]string

// What the program does to a page when its script signals. Its string is what signal() resolves to in the script (a JavaScript
// expression; "" nothing).
Action :: #type proc(pr: ^Probe) -> string

navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	append(&navigations, fmt.aprintf("%v %s", req.kind, req.url))
}

section_begin :: proc(t: ^testing.T, loc := #caller_location) {
	begin(t, .Pages, loc)
	serve(t, loc)
	settings.web.storage_quota = STORAGE_QUOTA_BYTES
	if os.get_env("JSWEB_NOJIT", context.temp_allocator) != "" { settings.js.jit.enabled = false }   // (to tell an engine bug from a script's)
}

section_end :: proc() {
	end()
	page.session_destroy(&session)
	session = {}
	for s in navigations { delete(s) }
	delete(navigations)
	navigations = nil
}

// A page at `address` running examples/jsweb/<name>.js after the harness.
open :: proc(t: ^testing.T, name: string, address := PAGE) -> ^Probe {
	pr := page_make(t, name, testenv.url(address))
	page.set_embedder(pr.p, {navigate = navigate_hook, session = &session, tab_key = "tab-1", storage = storage_world()})
	harness, herr := os.read_entire_file(DIR + "/harness.js", context.allocator)
	defer delete(harness)
	src, err := os.read_entire_file(fmt.tprintf("%s/%s.js", DIR, name), context.allocator)
	defer delete(src)
	if herr != nil || err != nil {
		testing.expectf(t, false, "cannot read %s/harness.js or %s.js (run from the repository root)", DIR, name)
		pr.section.finished = true
		return pr
	}
	html := strings.concatenate({"<!doctype html><meta charset=utf-8><title>", name, "</title><body><script>", string(harness), "</script><script>", testenv.url(string(src)), "</script></body>"})
	defer delete(html)
	page_load(pr, html)
	return pr
}

// Runs the loop until the script says it is done, running the action of each signal. `seconds` only ends a run that fails.
wait_script :: proc(pr: ^Probe, actions: map[string]Action = nil, seconds := DEFAULT_WAIT, loc := #caller_location) -> bool {
	start := time.tick_now()
	seen := 0
	for !pr.section.finished {
		for seen < len(pr.section.signals) {
			name := pr.section.signals[seen]
			seen += 1
			answer := "undefined"
			if a, ok := actions[name]; ok { if v := a(pr); v != "" { answer = v } }
			run(pr, fmt.tprintf("__resume(%q, %s)", name, answer), loc)
		}
		testhost.flush(&pr.section, pr.t, loc)
		if time.duration_seconds(time.tick_since(start)) > seconds {
			world_timeout(pr.t, fmt.tprintf("[%s] timeout: the script did not finish in %.0f s; its last lines: %v", pr.section.name, seconds, pr.lines[max(0, len(pr.lines) - LAST_LINES_ON_TIMEOUT):]), loc)
		}
		host.loop_wait(&loop, LOOP_LOOK_MS)
	}
	return true
}

// The page's end, and the section's verdict: `tests` is how many tests it declares.
close :: proc(pr: ^Probe, tests: int, loc := #caller_location) {
	close_page(pr, tests = tests, script_ends = true, verify_skip = verify_skip, loc = loc)
}

// A page of one script: its tests, its verdict.
script :: proc(t: ^testing.T, name: string, tests: int, actions: map[string]Action = nil, address := PAGE, seconds := DEFAULT_WAIT, loc := #caller_location) {
	pr := open(t, name, address)
	wait_script(pr, actions, seconds, loc)
	close(pr, tests, loc)
}

// A section of one script, which needs nothing else.
section :: proc(t: ^testing.T, name: string, tests: int, seconds := DEFAULT_WAIT, loc := #caller_location) {
	context.allocator = base.process_allocator()
	section_begin(t, loc)
	defer section_end()
	script(t, name, tests, seconds = seconds, loc = loc)
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

// What the machine says, for a script's skip: webgl.adapter_probe.
adapter_probe :: proc() -> (testhost.Skip_Verdict, string) {
	verdict, why := webgl.adapter_probe(settings.webgl)
	switch verdict {
	case .Absent:  return .Absent, why
	case .Present: return .Present, why
	case .Unknown: return .Unknown, why
	}
	return .Unknown, why
}

@(test) jsweb_core :: proc(t: ^testing.T) { section(t, "core", tests = 8) }
@(test) jsweb_compile_large :: proc(t: ^testing.T) { section(t, "compile_large", tests = 3) }
@(test) jsweb_url :: proc(t: ^testing.T) { section(t, "url", tests = 4) }
@(test) jsweb_abort :: proc(t: ^testing.T) { section(t, "abort", tests = 6) }
@(test) jsweb_blob :: proc(t: ^testing.T) { section(t, "blob", tests = 4) }
@(test) jsweb_streams :: proc(t: ^testing.T) { section(t, "streams", tests = 11) }
@(test) jsweb_fetch_objects :: proc(t: ^testing.T) { section(t, "fetch_objects", tests = 4) }
@(test) jsweb_fetch_api :: proc(t: ^testing.T) { section(t, "fetch", tests = 8) }
@(test) jsweb_xhr :: proc(t: ^testing.T) { section(t, "xhr", tests = 9) }
@(test) jsweb_perf_crypto :: proc(t: ^testing.T) { section(t, "perf_crypto", tests = 2) }
@(test) jsweb_webcrypto :: proc(t: ^testing.T) { section(t, "webcrypto", tests = 15) }
@(test) jsweb_message :: proc(t: ^testing.T) { section(t, "message", tests = 5) }
@(test) jsweb_sockets :: proc(t: ^testing.T) { section(t, "sockets", tests = 3) }
@(test) jsweb_canvas :: proc(t: ^testing.T) { section(t, "canvas", tests = 16) }
@(test) jsweb_geometry :: proc(t: ^testing.T) { section(t, "geometry", tests = 10) }
@(test) jsweb_compat :: proc(t: ^testing.T) { section(t, "compat", tests = 7) }
@(test) jsweb_idb_worker :: proc(t: ^testing.T) { section(t, "idb_worker", tests = 4) }
@(test) jsweb_idb_buckets :: proc(t: ^testing.T) { section(t, "idb_buckets", tests = 3) }
@(test) jsweb_idb_keys :: proc(t: ^testing.T) { section(t, "idb_keys", tests = 4) }
@(test) jsweb_htmlmedia :: proc(t: ^testing.T) { section(t, "htmlmedia", tests = 12) }
@(test) jsweb_mse :: proc(t: ^testing.T) { section(t, "mse", tests = 13) }

// The JIT on DOM objects (examples/jsweb/jit_dom.js): every function compiled at its first call, on the page's thread.
@(test)
jsweb_jit_dom :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	settings.js.jit.call_threshold = 1
	settings.js.jit.background_threads = 0
	script(t, "jit_dom", tests = 5)
}

// The section again with the decoders of a machine that has no system AV1 decoder (a CI runner), on a machine that has one.
@(test)
jsweb_mse_builtin_decoders :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	media.set_software_preferred(true)   // (after the settings of the section: they are the preferences')
	media.set_software_threads(RUNNER_DECODER_THREADS)
	defer {
		media.set_software_preferred(false)
		media.set_software_threads(0)
	}
	script(t, "mse", tests = 13)
}

@(test)
jsweb_idb :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	pr := open(t, "idb")
	pr.expect_uncaught = true   // (a request's handler that throws aborts its transaction, and the exception is reported)
	wait_script(pr)
	close(pr, tests = 11)
}

// The engine's image is not compiled in this program: on pages of their own, its blocks take five minutes on a quiet machine, and past a
// test's limit on a machine at work (the step of src/tools/test_all with WREN_POISON_PAGES=1, after every change of the engine and with -NoCache).
@(test)
jsweb_engine_code_of_the_program :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	script(t, "url", tests = 4)
	stats := wasm.cache_stats()
	testing.expectf(t, stats.shipped_hits >= 1 && stats.shipped_refused == 0, "the engine's code, from the program: %v", stats)
}

// (the two benchmarks only measure: performance runs, test_all -Perf)
@(test)
jsweb_idb_bench :: proc(t: ^testing.T) {
	if base.perf_skip("web tests, jsweb_idb_bench: IndexedDB micro-benchmarks") { return }
	section(t, "idb_bench", tests = 3)
}

@(test)
jsweb_bench :: proc(t: ^testing.T) {
	if base.perf_skip("web tests, jsweb_bench: the cost of a web API call") { return }
	section(t, "bench", tests = 1)
}

@(test)
jsweb_webaudio :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	settings.media.autoplay = .Allow_All
	script(t, "webaudio", tests = 21)
}

@(test)
jsweb_webaudio_autoplay :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["gesture"] = proc(pr: ^Probe) -> string { page.dispatch_event(pr.p, pr.p.body, dom.Event{type = "mousedown", bubbles = true, cancelable = true}); return "" }
	actions["collect"] = proc(pr: ^Probe) -> string { js.collect(pr.p.js.inst); return "" }
	actions["count"] = proc(pr: ^Probe) -> string { return fmt.tprintf("%d", page.web_audio_live_nodes(pr.p)) }
	settings.js.slow_script_ms = SLOW_SCRIPT_MS
	script(t, "webaudio_autoplay", tests = 1, actions = actions)
}

// (the software adapter: the same pixels everywhere, and what the CI has)
webgl_settings :: proc() {
	settings.webgl.force_software = true
	settings.js.slow_script_ms = SLOW_SCRIPT_MS   // (not -1: the hard stop of wasm.max_call_ms, one second, would be the limit)
	// On pages of their own, or on a machine at work, the macro that doubles forty times takes a long while: its compile went past the time a context has to answer, which lost it, and the
	// contexts after it had none. Nothing wrong, and slow.
	settings.webgl.gpu_hang_ms, settings.webgl.wait_ms = WEBGL_LIMIT_MS, WEBGL_LIMIT_MS
}
@(private = "file") WEBGL_LIMIT_MS :: 600_000

@(test)
jsweb_webgl_api :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	webgl_settings()
	actions := make(map[string]Action, context.temp_allocator)
	actions["frame"] = proc(pr: ^Probe) -> string { page.images_sync(pr.p); page.canvas_frame(pr.p); return "" }
	script(t, "webgl", tests = 23, actions = actions)
}

@(test)
jsweb_webassembly :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	pr := open(t, "webassembly")
	wait_script(pr)
	before := host_objects(pr.p)
	js.collect(pr.p.js.inst)
	drain()
	after := host_objects(pr.p)
	check(pr, before > after, fmt.tprintf("the modules of collected objects are released (%d -> %d)", before, after))
	close(pr, tests = 23)
}

@(test)
jsweb_perf_timeline :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["click"] = proc(pr: ^Probe) -> string { page.dispatch_event(pr.p, pr.p.body, dom.Event{type = "click", bubbles = true, cancelable = true}); return "" }
	script(t, "perf_timeline", tests = 7, actions = actions)
}

// A section that fails or runs out of time closes its page in the middle of what it does (requests, workers, crypto, transactions): what
// follows in the process does not suffer from it. One test per point of the cut, so that they run side by side. The cut is a number of turns
// of the loop, not a time: a time cut at another point on each machine, and the 37 sections at 0, 10, 100 and 300 ms were 15 s of real waits.
@(test) jsweb_sections_cut_short_at_once :: proc(t: ^testing.T) { sections_cut_short(t, CUT_AFTER_TURNS[0]) }
@(test) jsweb_sections_cut_short_after_1_turn :: proc(t: ^testing.T) { sections_cut_short(t, CUT_AFTER_TURNS[1]) }
@(test) jsweb_sections_cut_short_after_10_turns :: proc(t: ^testing.T) { sections_cut_short(t, CUT_AFTER_TURNS[2]) }
@(test) jsweb_sections_cut_short_after_100_turns :: proc(t: ^testing.T) { sections_cut_short(t, CUT_AFTER_TURNS[3]) }

sections_cut_short :: proc(t: ^testing.T, turns: int) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	// (the verdict of a page closed in the middle says nothing)
	abandon :: proc(pr: ^Probe, turns: int) {
		// (a turn ends on what the loop is given to run, or after LOOP_LOOK_MS with nothing)
		for _ in 0 ..< turns {
			if pr.section.finished { break }
			host.loop_wait(&loop, LOOP_LOOK_MS)
		}
		page.page_close(pr.p)
		testhost.forget(&pr.section)
		for l in pr.lines { delete(l) }
		delete(pr.lines)
		for l in pr.uncaught { delete(l) }
		delete(pr.uncaught)
		free(pr)
	}
	// (a script that cannot be compiled, one that throws: nothing of a section ran)
	for html in BROKEN_PAGES {
		pr := page_make(t, "broken", testenv.url(PAGE))
		page.set_embedder(pr.p, {navigate = navigate_hook, session = &session, tab_key = "tab-1", storage = storage_world()})
		page_load(pr, html)
		abandon(pr, turns)
	}
	for name in CUT_SECTIONS {
		abandon(open(t, name), turns)
		free_all(context.temp_allocator)
	}
	script(t, "xhr", tests = 9)
}

// Test programs run side by side, and each starts by emptying its profile: what one has on disk is not another's to empty. With one
// folder for all, the commit of an upgrade found no folder to write its journal in and the open failed with AbortError (in a whole run:
// jsweb_webcrypto, when webapi started after the origin had left memory). Here another program starts and ends in between.
@(test)
jsweb_idb_beside_another_process :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	settings.idb.idle_unload_ms = 0
	script(t, "idb_beside_another_process", tests = 1)
	// (what keeps a file open goes: the origin leaves memory)
	wait_until(t, "the origin out of memory", storage_world(), proc(s: ^page.Storage_Manager) -> bool { return idb.manager_tick(&s.idb.m) == 0 })
	state, out, said, err := os.process_exec({command = {os.args[0], "-tests:" + OTHER_PROGRAM_TEST + ",zz_the_process_ends_with_nothing_left"}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "%s in another process: error %v, exit code %d\n%s\n%s", OTHER_PROGRAM_TEST, err, state.exit_code, string(out), string(said))
	script(t, "idb_beside_another_process", tests = 1)
}

// IndexedDB across pages and across a restart of the data manager: versionchange / blocked between two pages, the journal
// read again after the manager was destroyed and made anew, the quota, and "Clear site data".
@(test)
jsweb_idb_pages :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	a := open(t, "idb_pages_a")
	wait_note(a, "LISTENING")
	b := open(t, "idb_pages_b")
	wait_note(a, "HEARD")
	wait_note(b, "BLOCKED")
	run(a, "__closeA()")
	wait_script(b)
	wait_script(a)
	close(b, tests = 2)
	close(a, tests = 2)

	// restart: the manager goes (journals flushed), a new one reads the files
	host.blocking_settle(&blocking)
	page.storage_manager_destroy(&storage)
	host.blocking_settle(&blocking)
	page.storage_manager_init(&storage, &loop, &blocking, storage_dir())
	script(t, "idb_persist", tests = 1)

	// quota: 1 MiB for the origin
	saved := settings.idb.quota_bytes
	settings.idb.quota_bytes = IDB_QUOTA_TEST_BYTES
	script(t, "idb_quota", tests = 1)
	settings.idb.quota_bytes = saved

	// clear site data while a connection is open
	c := open(t, "idb_clear")
	actions := make(map[string]Action, context.temp_allocator)
	actions["clear"] = proc(pr: ^Probe) -> string { page.idb_clear_origin(&storage, page.storage_origin_key(pr.p)); return "" }
	wait_script(c, actions)
	close(c, tests = 1)
}

@(test)
jsweb_navigator :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	pr := open(t, "navigator")
	wait_script(pr)
	ua := pr.p.loader.net.settings.user_agent
	check(pr, testhost.noted(&pr.section, fmt.tprintf("UA %s", ua)), fmt.tprintf("navigator.userAgent is not the User-Agent header (%q)", ua))
	close(pr, tests = 4)
}

// Two pages of one origin, the storage event.
@(test)
jsweb_storage_event :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	listener := open(t, "storage_listener")
	wait_note(listener, "LISTENING")
	writer := open(t, "storage")
	wait_script(writer)
	wait_script(listener)
	close(writer, tests = 5)
	close(listener, tests = 1)
}

navigation_was_asked :: proc(wanted: string) -> bool {
	for n in navigations { if strings.has_prefix(n, wanted) { return true } }
	return false
}

// The embedder has been asked for this navigation.
navigation_asked :: proc(pr: ^Probe, kind, path: string) -> string {
	wanted := fmt.tprintf("%s %s", kind, path == "" ? "" : fmt.tprintf("%s%s", testenv.url(BASE), path))
	wait_until(pr.t, "the embedder's navigation", wanted, navigation_was_asked)
	check(pr, navigation_was_asked(wanted), fmt.tprintf("the embedder was asked to navigate: %s (got %v)", wanted, navigations))
	return ""
}

// Location and history.
@(test)
jsweb_history :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["asked_assign"] = proc(pr: ^Probe) -> string { return navigation_asked(pr, "Assign", "/jsweb/other") }
	actions["asked_replace"] = proc(pr: ^Probe) -> string { return navigation_asked(pr, "Replace", "/jsweb/replaced") }
	actions["asked_reload"] = proc(pr: ^Probe) -> string { return navigation_asked(pr, "Reload", "") }
	// (two in one task: the later one takes the place of the earlier, as in the browsers)
	actions["asked_last_only"] = proc(pr: ^Probe) -> string {
		_ = navigation_asked(pr, "Replace", "/jsweb/last")
		check(pr, !navigation_was_asked(fmt.tprintf("Assign %s/jsweb/first", testenv.url(BASE))), "the earlier navigation of the task never reached the embedder")
		return ""
	}
	script(t, "history", tests = 5, actions = actions, address = BASE + "/jsweb/page?x=1")
}

// matchMedia: the page's style computation reports changes.
@(test)
jsweb_media_queries :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	actions := make(map[string]Action, context.temp_allocator)
	actions["wide"] = proc(pr: ^Probe) -> string { page.styles(pr.p, VIEW_WIDE, VIEW_H, 1); return "" }
	actions["narrow"] = proc(pr: ^Probe) -> string { page.styles(pr.p, VIEW_NARROW, VIEW_H, 1); return "" }
	script(t, "media", tests = 1, actions = actions)
}

// Lifetime: what JavaScript dropped is released in the browser.
@(test)
jsweb_gc :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	pr := open(t, "gc")
	wait_script(pr)
	before := host_objects(pr.p)
	js.collect(pr.p.js.inst)
	drain()
	after := host_objects(pr.p)
	check(pr, before > after && after < GC_MAX_HOST_OBJECTS, fmt.tprintf("host objects of collected wrappers are released (%d -> %d)", before, after))
	close(pr, tests = 1)
}

// Lifetime: the bitmaps of dropped canvases are freed.
@(test)
jsweb_canvas_gc :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	pr := open(t, "canvas_gc")
	wait_script(pr)
	before := page.canvas_bytes(pr.p)
	js.collect(pr.p.js.inst)
	drain()
	page.canvas_frame(pr.p)   // (what the shell does each frame: the elements the document freed)
	after := page.canvas_bytes(pr.p)
	check(pr, before > CANVAS_BYTES_BEFORE_MIN && after < CANVAS_BYTES_AFTER_MAX, fmt.tprintf("the bitmaps of collected canvases are freed (%d -> %d)", before, after))
	close(pr, tests = 2)
}

// A page that was given no test host, which is every page of a browser, has no wrenTest: its console is all it has to say that with.
@(test)
jsweb_a_page_without_a_test_host_has_no_test_functions :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	seen: [dynamic]string
	p := page.page_create(&loop, &loader, &settings, process, testenv.url(PAGE), proc(user: rawptr, _: page.Log_Level, message: string) { append((^[dynamic]string)(user), strings.clone(message)) }, &seen)
	source := `<!doctype html><body><script>console.log(typeof wrenTest + " " + typeof globalThis.wrenTest)</script></body>`
	page.load_html(p, transmute([]byte)string(source))
	page.scripts_start(p)
	wait_until(t, "the page's script", &seen, proc(seen: ^[dynamic]string) -> bool { return len(seen) > 0 })
	testing.expect(t, len(seen) == 1 && seen[0] == "undefined undefined", "a browser's page has no wrenTest")
	page.page_close(p)
	for s in seen { delete(s) }
	delete(seen)
}

// What was silently passed for months: the script finds no WebGL context, here because the page has it switched off, on a machine
// that has an adapter. Its skip must fail the section, not pass it.
@(test)
jsweb_a_skip_that_is_not_true_of_the_machine_fails_the_section :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	section_begin(t)
	defer section_end()
	settings.webgl.enabled = false
	pr := open(t, "webgl_skip")
	wait_script(pr)
	page.page_close(pr.p)
	pr.p = nil
	testing.expect(t, pr.section.skipped, "the script said it could not run")
	testing.expect_value(t, pr.section.begun, 0)
	settings.webgl.enabled = true
	verdict, _ := adapter_probe()
	problems, true_skips := testhost.judge(&pr.section, tests = WEBGL_SKIP_TESTS, verify_skip = verify_skip)
	if verdict == .Absent {
		testing.expect_value(t, len(true_skips), 1)   // (this machine really has none: reported and counted)
	} else {
		testing.expect_value(t, len(true_skips), 0)
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], "not what this machine says"), "%v", problems)
	}
	testhost.forget(&pr.section)   // (what it recorded was this test's to judge)
	close_page(pr)
}
