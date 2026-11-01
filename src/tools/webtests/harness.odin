// The web tests: end-to-end tests of what lies under the browser's window (fetch, the network, pages and their scripts, with no shell
// and no frame), one program of core:testing. One file per subject, each `#+private file` with its own helpers, its tests named after
// it (cache_freshness, in cache.odin). What they share is here.
//
// Tests go one at a time (-define:ODIN_TEST_THREADS=1) on one world: what the process keeps (the Wasm runtime, the image cache, the
// stores) binds to the first loop it sees, so a loop per test would leave it on a dead one. The world is made as far as a test asks
// (`begin`), and undone by the last test, `zz_the_process_ends_with_nothing_left`, which finds the leaks (-define:WREN_TRACK_MEMORY=true).
// test_all runs one subject per process (tools\test_env.ps1 Invoke-WrenWebTests); `build\web_test.exe -tests:cache_freshness` runs one test, and
// the program with no name runs them all.
//
// The test server is in the process (`serve`). A page's script talks to its test through `wrenTest` (`open_page`: src/tools/testhost);
// the console is the page's own and no result is read from it. Waits are for a state (`wait_until`, `wait_note`), and their limits only
// end a run that fails.
package webtests

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:net"
import "wb:page"
import "wb:tools/testenv"
import "wb:tools/testhost"
import "wb:wasm"

BLOCKING_THREADS :: 2
SCRIPT_CACHE_BYTES :: 16 << 20
STORAGE_DIR :: "build/web_test_profile"
TEST_LIMIT :: 5 * time.Minute          // ends a test that hangs
DEFAULT_WAIT :: 60.0                   // seconds: only ends a run that fails
LOOP_LOOK_MS :: 5                      // the most the loop waits before a test looks again: anything that happens ends the wait sooner
DRAIN_MAX_TURNS :: 1000
UNCAUGHT :: "Uncaught"
LAST_LINES_ON_TIMEOUT :: 6

// How far the world is made.
Level :: enum {
	None,
	Net,      // the loop, the network, fetch's loader
	Pages,    // and the Wasm runtime, the script engine, the process's scope
}

world_level: Level
storage_made: bool
current: ^testing.T

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings            // a test's own, from `begin`, at the default values
process:  ^base.Scope
storage:  page.Storage_Manager     // (made by `storage_world`)

// The first thing a test does, after `context.allocator = base.process_allocator()` (what the Wasm imports make and free goes through
// the process's allocator: core:testing's tracker of the test does not know that memory; the process's finds the leaks in the last test).
begin :: proc(t: ^testing.T, level := Level.Pages, loc := #caller_location) {
	current = t
	testing.set_fail_timeout(t, TEST_LIMIT, loc)
	if world_level == .None {
		world_level = .Net
		host.loop_init(&loop)
		testing.expect(t, net.client_init(&client, &loop), "net init", loc = loc)
		host.blocking_init(&blocking, &loop, BLOCKING_THREADS)
		profile = fetch.profile_make()
		fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	}
	if level == .Pages && world_level == .Net {
		world_level = .Pages
		wasm.configure_from_args(nil)
		testing.expect(t, page.register_imports(), "imports", loc = loc)
		js.cache_start({memory_bytes = SCRIPT_CACHE_BYTES, min_source_bytes = 0})
		process = base.scope_make("process")
	}
	settings = page.settings_default()
}

// With `defer`, after `begin`.
end :: proc() {
	drain()
	page.settings_destroy(&settings)
	current = nil
}

// The profile's stores for a page's embedder.
storage_world :: proc() -> ^page.Storage_Manager {
	if !storage_made {
		storage_made = true
		testenv.remove_tree(STORAGE_DIR)
		page.storage_manager_init(&storage, &loop, &blocking, STORAGE_DIR)
	}
	return &storage
}

// The test server, listening, in this process; testenv.url moves addresses to its block, and it has forgotten what it counted.
serve :: proc(t: ^testing.T, loc := #caller_location) { testenv.serve(t, loc) }

// Runs the loop until `ready` says so. The limit only ends a run that fails.
wait_until :: proc(t: ^testing.T, what: string, data: $T, ready: proc(data: T) -> bool, seconds := DEFAULT_WAIT, loc := #caller_location) -> bool {
	start := time.tick_now()
	for !ready(data) {
		if time.duration_seconds(time.tick_since(start)) > seconds {
			testing.expectf(t, false, "timeout waiting for %s", what, loc = loc)
			return false
		}
		host.loop_wait(&loop, LOOP_LOOK_MS)
	}
	return true
}

// The loop's time stands still from now on, until the test moves it (host.clock_advance) or ends: for what happens on a timer of the
// loop, or must not. The network does not wait for it.
virtual_clock :: proc(t: ^testing.T) {
	@(static) clock: host.Virtual_Clock
	clock.now_ns = host.now_ns(&loop)
	host.clock_virtual(&loop, &clock)
	testing.cleanup(t, proc(_: rawptr) { loop.virtual = nil }, nil)
}

// Runs what is ready now (posted tasks, due timers), turn after turn, until nothing is.
drain :: proc() {
	for _ in 0 ..< DRAIN_MAX_TURNS {
		if host.next_timeout_ms(&loop) != 0 { return }
		host.loop_wait(&loop, 0)
	}
}

// One page and what it tells its test.
Probe :: struct {
	t:          ^testing.T,
	p:          ^page.Page,
	section:    testhost.Section,
	lines:      [dynamic]string,   // its console, the end of which is said when it times out
	uncaught:   [dynamic]string,   // what nothing in the page caught: a failure, unless the test expects it
	expect_uncaught: bool,
}

@(private = "file")
console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	pr := (^Probe)(user)
	append(&pr.lines, strings.clone(message))
	if strings.has_prefix(message, UNCAUGHT) { append(&pr.uncaught, strings.clone(message)) }
}

// A page connected to its test (`wrenTest`), not loaded yet: `page.set_embedder` and the like go here. `name` is the section's.
page_make :: proc(t: ^testing.T, name, address: string) -> ^Probe {
	pr := new(Probe)
	pr.t = t
	pr.section.name = name
	pr.p = page.page_create(&loop, &loader, &settings, process, address, console, pr)
	testhost.attach(&pr.section, pr.p)
	return pr
}

// Loads this markup, runs its scripts.
page_load :: proc(pr: ^Probe, html: string, mime := "") {
	page.load_html(pr.p, transmute([]byte)html, mime)
	page.scripts_start(pr.p)
}

// A page of this markup at this address.
open_page :: proc(t: ^testing.T, name, html, address: string) -> ^Probe {
	pr := page_make(t, name, address)
	page_load(pr, html)
	return pr
}

// Runs a script in the page, and passes on what it said (`wrenTest.check(...)`). A script that throws is a failure at the end of the page.
run :: proc(pr: ^Probe, script: string, loc := #caller_location) {
	page.js_run(pr.p, transmute([]byte)script, "test.js")
	testhost.flush(&pr.section, pr.t, loc)
}

// A check of the test itself, counted with the page's.
check :: proc(pr: ^Probe, ok: bool, what: string, loc := #caller_location) {
	testhost.expect(&pr.section, pr.t, ok, what, loc)
}

@(private = "file")
Wait_Note :: struct { pr: ^Probe, text: string }

// Runs the loop until the page has said `wrenTest.note(text)`.
wait_note :: proc(pr: ^Probe, text: string, seconds := DEFAULT_WAIT, loc := #caller_location) -> bool {
	ok := wait_until(pr.t, fmt.tprintf("%q from the page; its last lines: %v", text, pr.lines[max(0, len(pr.lines) - LAST_LINES_ON_TIMEOUT):]), Wait_Note{pr, text}, proc(w: Wait_Note) -> bool {
		testhost.flush(&w.pr.section, w.pr.t)
		return testhost.noted(&w.pr.section, w.text)
	}, seconds, loc)
	return ok
}

// The page's script says it is over (`wrenTest.done()`), and the test waits for that.
wait_done :: proc(pr: ^Probe, seconds := DEFAULT_WAIT, loc := #caller_location) -> bool {
	return wait_until(pr.t, fmt.tprintf("the end of %s; its last lines: %v", pr.section.name, pr.lines[max(0, len(pr.lines) - LAST_LINES_ON_TIMEOUT):]), pr, proc(pr: ^Probe) -> bool {
		testhost.flush(&pr.section, pr.t)
		return pr.section.finished
	}, seconds, loc)
}

// The page's end, and its verdict (testhost.finish): at least `min_checks` checks held, or `tests` tests ran; none of it is forgiven when
// the page ended early. A test that drives a page from outside says `done` here for it.
close_page :: proc(pr: ^Probe, tests := -1, min_checks := 0, script_ends := false, verify_skip: testhost.Verify_Skip = nil, loc := #caller_location) {
	if !script_ends { pr.section.finished = true }
	if pr.p != nil { page.page_close(pr.p) }
	if !pr.expect_uncaught {
		for u in pr.uncaught { testhost.expect(&pr.section, pr.t, false, u, loc) }
	}
	testhost.finish(&pr.section, pr.t, tests, min_checks, verify_skip, loc)
	for l in pr.lines { delete(l) }
	delete(pr.lines)
	for l in pr.uncaught { delete(l) }
	delete(pr.uncaught)
	free(pr)
}

// Last, whatever else ran: everything the world made goes, and what is still allocated then was left behind. (-tests: does not bring it:
// tools\test_env.ps1 Invoke-WrenWebTests names it.)
@(test)
zz_the_process_ends_with_nothing_left :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	if world_level >= .Pages { base.scope_close(process) }
	if world_level >= .Net { host.blocking_settle(&blocking) }
	if storage_made {
		page.storage_manager_destroy(&storage)
		host.blocking_settle(&blocking)
	}
	if world_level >= .Pages { page.process_shutdown() }
	if world_level >= .Net {
		fetch.loader_destroy(&loader)
		host.blocking_destroy(&blocking)
		net.client_destroy(&client)
		fetch.profile_destroy(&profile)
		page.discard_page_tasks(&loop)
		host.loop_destroy(&loop)
	}
	world_level = .None
	testing.expect_value(t, testenv.mem_check("web_test"), 0)
	all := testhost.totals
	fmt.printf("\n%d sections\n%d passed, %d failure(s), %d skipped\n", all.sections, all.passes, all.failures, all.skips)
}
