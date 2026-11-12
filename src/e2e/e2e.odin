// Package e2e: what an end-to-end test of Wren calls. A test is a `@(test)` procedure of src/tools/e2e, on Odin's test runner:
//
//   @(test)
//   the_title_shows :: proc(t: ^testing.T) {
//       s := e2e.start(t, {size = {1280, 800}})
//       e2e.navigate(s, e2e.url(e2e.test_server(t), "/site/about.html"))
//       testing.expect_value(t, e2e.eval(s, "document.title"), "About")
//   }
//
// The browser runs in the test's own thread and process: a call goes straight to the procedures the remote methods use
// (src/browser/control.odin), there is no channel, no JSON and no other thread to wait for. A barrier runs the browser's loop itself,
// turn by turn, until what it waits for holds: nothing here sleeps, and a deadline only ends a failing run. The window is headless: no
// window of the system exists, and the frames are the browser's real render, offscreen, made as fast as they are asked for.
//
// An action that fails ends the test there, with where it was called from: a scenario checks no return. Checks are testing.expect*.
//
// One browser at a time on a thread: a browser (browser.App) keeps its state, and runs on the thread that started it (docs/architecture.md,
// Where state lives). Several threads run several browsers at once (two_apps.odin): a session started on a thread of the test's own is
// stopped on it (`stop`). A test that failed in the middle of a frame leaves its browser as it is, so the tests after it in that run say so
// and fail. test_all runs one process per scenario.
// What is about a process itself (a launch, an exit code, a crash) goes through `process.odin`, over the channel.
package e2e

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:host"
import "toolkit:platform"
import "toolkit:ui"
import "wb:browser"
import "wb:dom"
import "wb:page"
import "wb:style"
import "wb:remote/api"

// What a test may take in all before the runner stops it (a barrier's deadline comes first). A scenario of many barriers takes minutes on a
// runner that draws on the processor (cursor.odin: 40 elements), so this is no barrier's limit: it only ends a test that hangs outside one.
TEST_LIMIT :: 5 * time.Minute
// How long a barrier may take before the test is said to have failed: under TEST_LIMIT, and far above what any machine takes (no barrier of a
// passing CI run is near it). It only ends a failing run, so no passing test depends on the speed of the machine; a failure costs this, once:
// the barrier that fails ends its test.
DEFAULT_DEADLINE :: 60 * time.Second
PAGE_GLIMPSE_MS :: 5000   // what a failed wait gives the page to say what it shows (page_glimpse)
// The window when a test does not say.
DEFAULT_SIZE :: [2]int{1280, 800}
// 96 dots per inch: a scale of 1.
DPI_ONE :: api.DPI_ONE
// The folder of a test's captures and what it leaves (kept only when it fails), under the build folder.
OUT_DIR :: "e2e"
// What a test keeps when it fails: the window and the page's console.
FAILURE_CAPTURE :: "failure.png"
FAILURE_CONSOLE :: "failure_console.txt"
// rest_turns: how often what wakes the loop wakes it. wait_at_rest: a timer of the loop due further away than this is not waited for (scenarios keep the status
// bar's window far below it).
REST_WAKE_MS :: 1
REST_HORIZON_MS :: 500
// How long wait_idle and wait_stable want their state to hold. A client over the channel looks from outside, so browser.remote.idle_ms (400 ms) bridges the moments between two requests of a
// chain; here the state is looked at on the loop's own turns, and what follows a timer or a reply says so itself (wait_js, wait_selector). Each of the 400 ms was a wait for nothing: a test of 70 hovers took 28 s.
HOLD_MS :: 1
// The same for a process: to start, to close.
PROCESS_WAIT_MS :: int(DEFAULT_DEADLINE / time.Millisecond)
// What a cleanup gives a process it told to close, or killed, before it lets it go: a test's end must not wait a barrier's deadline for it.
CLEANUP_WAIT_MS :: 10_000
// The stack the script engine's calls need (what /STACK:67108864 gives on Windows).
STACK_BYTES :: 64 * 1024 * 1024

// Re-exported: what a scenario reads.
Image :: api.Image
Color :: api.Color
Rect :: api.Rect
Point :: api.Point
Tab :: api.Tab
Tab_Group :: api.Tab_Group
Targets :: api.Targets
Window :: api.Window
Bounds :: api.Bounds
Stats :: api.Stats
Button :: api.Button
Space :: api.Space
Shot_Options :: api.Shot_Options
Console_Line :: api.Console_Line
Drag_Options :: api.Drag_Options
Drop_Data :: api.Drop_Data
Wait :: api.Wait
Window_Change :: api.Window_Change
Urlbar :: api.Urlbar
Urlbar_Row :: api.Urlbar_Row
diff_pictures :: api.diff_pictures
Download :: api.Download
Query_Result :: api.Query_Result
Box_Model :: api.Box_Model
Style_Property :: api.Style_Property
Network :: api.Network
Pref :: api.Pref
Command :: api.Command
style_of :: api.style_of
center :: api.center
pixel :: api.pixel
window_with_id :: api.window_with_id

Options :: struct {
	size:       [2]int,     // the client area (0: DEFAULT_SIZE); no window frame, this is what a capture measures
	dpi:        f64,        // 96 = 100 % (0: the same)
	profile:    string,     // a folder that stays (temp_profile(t) for one of this test): "" is a throwaway one
	prefs:      []string,   // "name=value", as the command line's --pref
	url:        string,     // the first address, loaded before start returns ("": about:blank)
	no_address: bool,       // no address at all: the session of the profile comes back
	hidden:     bool,       // a real window of the system, never shown, and its swap chain: for what is about them (window.odin). It needs a desktop session
	software:   bool,       // no window of the system, drawn on the system's software rasterizer (Windows: WARP) whatever GPU the machine has, as on a runner without one
	own_thread: bool,       // started on a thread of the test's own (two_apps.odin): its profile is given, and that thread ends it (`stop`), not the test's end
	pixels:     bool,       // the frames are rasterized: for a test that reads pixels (capture, shot, busy_capture). Without it (and without `hidden` or `software`) the browser makes every frame up to its display list and draws none of it: a runner with no GPU draws each frame on the processor
}

Session :: struct {
	t:       ^testing.T,
	app:     ^browser.App,
	window:  int,            // the window calls are about (0: the front one): in_window for a stretch of calls
	tab:     int,            // the tab calls are about (0: its current one)
	name:    string,         // the test's
	out:     string,         // the folder of what it leaves
	// The browser runs under a context of its own: its allocator is the process's (it outlives what a test's tracker can
	// host), and each of its frames frees its temporary memory, which must not be the one a scenario holds strings in.
	ctx:     runtime.Context,
	test:    runtime.Context,
	temp:    runtime.Default_Temp_Allocator,
	thread:  int,
	allocator: runtime.Allocator,   // what made the session (its thread's: the test's own, or one of a thread of the test's)
	own_thread: bool,
	pixels:  bool,           // its frames are rasterized (Options.pixels)
	began:   time.Tick,
	trace:   bool,           // WREN_E2E_TRACE: each call says when and where on stderr: where the time of a test goes
}

// The browser of this thread (one at a time on a thread), and why no browser can start any more in this process (a test was stopped in the
// middle of its calls). Each is set on a test's way in or out only.
@(private, thread_local) current: ^Session
@(private) broken: string

// The environment of every test (WREN_DESKTOP_INTEGRATION=off, WREN_AUDIO_OUTPUT=null, WREN_SINGLE_INSTANCE=off): a driven Wren does not touch the machine's desktop, makes no
// sound, and is nobody's single instance; the engine's compiled code is shared on the disk.
@(init)
set_environment :: proc "contextless" () {
	context = base.process_context()
	stacks_command()
	os.set_env("WREN_DESKTOP_INTEGRATION", "off")
	os.set_env("WREN_AUDIO_OUTPUT", "null")
	os.set_env("WREN_SINGLE_INSTANCE", "off")
	root := repo_root()
	// (a test's relative paths, and the test server's files, are the repository's)
	_ = os.set_working_directory(root)
	if v, _ := os.lookup_env("WREN_NO_TEST_CACHE", context.temp_allocator); v != "1" {
		if c, _ := os.lookup_env("WREN_TEST_WASM_CACHE", context.temp_allocator); c == "" {
			os.set_env("WREN_TEST_WASM_CACHE", fmt.tprintf("%s/build/wasm_cache", root))
		}
	}
	ensure_stack()
}

// A browser's teardown that hangs has `<program> ctl stacks <its pid> --out <file>` read its threads from outside (host.shutdown_watchdog): with no Wren in a
// test's process, the program is this one, started again for that and nothing else.
@(private = "file")
stacks_command :: proc() {
	program, err := os.get_executable_path(base.permanent_allocator())
	if err == nil { host.shutdown_stacks_program = program }
	if len(os.args) != STACKS_COMMAND_ARGS || os.args[1] != "ctl" || os.args[2] != "stacks" || os.args[4] != "--out" { return }
	pid, _ := strconv.parse_int(os.args[3])
	text, ok := api.process_stacks(pid)
	_ = os.write_entire_file(os.args[5], transmute([]byte)text)
	host.process_end(ok ? 0 : 1)
}
@(private = "file") STACKS_COMMAND_ARGS :: 6

// The repository: this program is in its build folder (WREN_REPO says otherwise).
repo_root :: proc(allocator := context.temp_allocator) -> string {
	if r, ok := os.lookup_env("WREN_REPO", allocator); ok && r != "" { return r }
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return strings.clone(".", allocator) }
	return strings.clone(filepath.dir(filepath.dir(exe)), allocator)
}

// A browser for this test, started in this process, with no window of the system. It ends with the test.
start :: proc(t: ^testing.T, o := Options{}, loc := #caller_location) -> ^Session {
	if !o.own_thread { testing.set_fail_timeout(t, TEST_LIMIT, loc) }   // (the test's: its own threads do not touch it)
	if broken != "" { stop_test(t, broken, loc) }
	if current != nil { stop_test(t, "a browser is running on this thread already: one at a time (stop it first)", loc) }
	if o.own_thread && o.profile == "" { stop_test(t, "a browser of a thread of the test's own is given its profile (temp_profile on the test's thread)", loc) }
	// (first: the cleanups go last to first, and the browser ends before its profile goes)
	profile := o.profile != "" ? o.profile : temp_profile(t)
	s := new(Session)
	s.t = t
	s.test = context
	s.own_thread = o.own_thread
	s.pixels = o.pixels || o.hidden || o.software   // (a real window, or the software rasterizer, is what such a test is about)
	s.name = o.own_thread ? fmt.aprintf("%s_%d", loc.procedure, sync.current_thread_id()) : strings.clone(loc.procedure)   // (its own folder)
	s.out = strings.clone(fmt.tprintf("%s/build/%s/%s", repo_root(), OUT_DIR, s.name))
	s.thread = sync.current_thread_id()
	s.allocator = context.allocator
	s.began = time.tick_now()
	_, s.trace = os.lookup_env("WREN_E2E_TRACE", context.temp_allocator)
	base.remove_tree(s.out)
	_ = os.make_directory_all(s.out)
	runtime.default_temp_allocator_init(&s.temp, 0, base.process_allocator())
	s.ctx = base.process_context()
	s.ctx.temp_allocator = {runtime.default_temp_allocator_proc, &s.temp}
	s.ctx.logger = context.logger
	s.ctx.assertion_failure_proc = context.assertion_failure_proc
	current = s
	if !o.own_thread { testing.cleanup(t, proc(p: rawptr) { end_of_test((^Session)(p)) }, s) }

	args := make([dynamic]string, context.temp_allocator)
	append(&args, o.hidden ? "--hidden" : "--headless", "--no-single-instance", "--profile", profile)
	if o.dpi > 0 { append(&args, "--pref", fmt.tprintf("browser.ui.scale=%.4f", o.dpi / DPI_ONE)) }
	// (nothing of the machine's or the internet's in a test: the content blocker's lists stay where they are; no GPU process a test
	// does not ask for, which every page's first paint would start ahead)
	// (the dark version of the theme whatever the system says: the pictures and colours the scenarios check are its)
	append(&args, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false", "--pref", "webgl.gpu_start_ahead=false", "--pref", "browser.ui.theme_mode=dark")
	for p in o.prefs { append(&args, "--pref", p) }
	if !o.no_address { append(&args, "about:blank") }
	{
		context = s.ctx
		browser.headless_software = o.software
		browser.headless_no_pixels = !s.pixels   // (read by every frame of this thread's browser: end_of_browser clears it)
		s.app = browser.app_start(args[:])
		browser.headless_software = false
		if s.app != nil { browser.control_begin(s.app) }
	}
	if s.app == nil { failed(s, "the browser could not start", loc) }
	size := o.size.x > 0 ? o.size : DEFAULT_SIZE
	set_window(s, {size = size}, loc)
	if o.url != "" { navigate(s, o.url, loc = loc) }
	return s
}

// The browser ends here (a test about what the next start finds does this), with everything it keeps written. A test that does not is ended by this at its end.
// A session of a thread of the test's own ends here too.
stop :: proc(s: ^Session) {
	browser_stop(s)
	if s.own_thread { end_of_test(s) }
}

@(private)
browser_stop :: proc(s: ^Session) {
	if s.app == nil { return }
	context = s.ctx
	app := s.app
	s.app = nil
	browser.app_stop(app)
	free_all(context.temp_allocator)
}

// A browser again, in this test, after `stop`: with the same profile, what it finds is what the last one left.
restart :: proc(s: ^Session, o := Options{}, loc := #caller_location) -> ^Session {
	end_of_browser(s)
	return start(s.t, o, loc)
}

@(private)
end_of_browser :: proc(s: ^Session) {
	browser_stop(s)
	browser.headless_no_pixels = false
	runtime.default_temp_allocator_destroy(&s.temp)   // (`restart`: the session goes on, its browser's temporary memory does not)
	if current == s { current = nil }
}

// The test is over (testing.cleanup: on the runner's main thread when it was stopped by a failure).
@(private)
end_of_test :: proc(s: ^Session) {
	if s.thread != sync.current_thread_id() {
		// stopped in the middle of what it was doing: the browser's state is as it was, and its threads go on with the process
		broken = "a test before this one was stopped with its browser running: run this one alone (-tests:name)"
		return
	}
	if testing.failed(s.t) { keep_failure(s) }
	end_of_browser(s)
	// (the test program is built with every allocation tracked: here nothing of the session may be left)
	when base.TRACK_MEMORY { if !testing.failed(s.t) && !s.own_thread { testing.expectf(s.t, base.mem_report(s.name) == 0, "%s leaves nothing allocated: the report above", s.name) } }
	if !testing.failed(s.t) { base.remove_tree(s.out) }
	delete(s.name, s.allocator)
	delete(s.out, s.allocator)
	free(s, s.allocator)
}

// A file of this test's folder (the folder stays only when it fails).
out_path :: proc(s: ^Session, name: string) -> string {
	return strings.clone(fmt.tprintf("%s/%s", s.out, name), s.test.temp_allocator)
}

// What a failure is read with: the window as it was, what the page said.
@(private)
keep_failure :: proc(s: ^Session) {
	if s.app == nil { return }
	context = s.ctx
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	if t := browser.current_tab(s.app); t != nil {
		// (a browser that is stuck is why the test failed: the capture has a short limit; a session that draws no pixels has no picture)
		if s.pixels {
			rep := browser.control_capture(s.app, &c, t, {path = strings.clone(fmt.tprintf("%s/%s", s.out, FAILURE_CAPTURE), context.temp_allocator), timeout_ms = FAILURE_CAPTURE_LIMIT_MS, settle = 0})
			if rep.deferred { _ = browser.control_run(s.app, &o) }
		}
		lines := browser.control_console(t)
		b := strings.builder_make(context.temp_allocator)
		for l in lines { fmt.sbprintf(&b, "%s: %s\n", l.level, l.text) }
		_ = os.write_entire_file(fmt.tprintf("%s/%s", s.out, FAILURE_CONSOLE), transmute([]byte)strings.to_string(b))
	}
}
@(private) FAILURE_CAPTURE_LIMIT_MS :: 5000

// Ends the test here: its message is logged at the place given, and the runner ends this thread (its "Test timed out" follows the message:
// a limit of 0 is the one way to be ended that core:testing gives a test twice in a run. testing.fail_now raises a signal, and on Windows the
// runner lets go of a lock it does not hold when it handles one (signal_handler_windows.odin _should_stop_test), so that the next signal of the run
// waits for ever: an assert or a fault of a test still goes that way, once).
stop_test :: proc(t: ^testing.T, message: string, loc: runtime.Source_Code_Location) -> ! {
	log.error(message, location = loc)
	testing.set_fail_timeout(t, 0, loc)
	for { time.sleep(time.Hour) }
}

// An action failed: the test ends here, and says what to read.
@(private)
failed :: proc(s: ^Session, why: string, loc: runtime.Source_Code_Location) -> ! {
	context = s.test
	message := fmt.tprintf("%s (what it left: %s)", why, s.out)
	if s.app != nil && sync.current_thread_id() == s.thread { keep_failure(s) }
	context = s.test
	stop_test(s.t, message, loc)
}

////////////////////////////////
// Temporary folders, files

// A folder for this test, gone at its end.
temp_folder :: proc(t: ^testing.T, what := "dir") -> string {
	dir := strings.clone(fmt.tprintf("%s/%s/wren-e2e-%s-%s", base.temp_dir(context.temp_allocator), OUT_DIR, what, base.unique_name(context.temp_allocator)))
	_ = os.make_directory_all(dir)
	testing.cleanup(t, proc(p: rawptr) {
		d := (^string)(p)
		base.remove_tree(d^)
		delete(d^)
		free(d)
	}, new_clone(dir))
	return dir
}

// A name nothing else has.
unique :: proc() -> string { return base.unique_name(context.temp_allocator) }

// The paths of the entries of a folder whose names begin (and end) so, in no order.
files_with_prefix :: proc(dir, prefix: string, suffix := "") -> []string {
	found := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return found[:] }
	for e in entries { if strings.has_prefix(e.name, prefix) && strings.has_suffix(e.name, suffix) { append(&found, e.fullpath) } }
	return found[:]
}

// A profile folder for this test (for what `restart` must find again), gone at its end.
temp_profile :: proc(t: ^testing.T) -> string { return temp_folder(t, "profile") }

// A `file:` page in `dir`, its text as given.
file_page :: proc(dir, name, html: string, loc := #caller_location) -> string {
	path := fmt.tprintf("%s/%s", dir, name)
	_ = os.write_entire_file(path, transmute([]byte)html)
	return file_url(path)
}

// How many browsers use what the process shares (browser/process_share.odin): 0 once each has stopped.
process_share_users :: proc() -> int { return browser.process_share_users() }

// The `file:` address of a path.
file_url :: proc(path: string) -> string {
	p, _ := strings.replace_all(path, `\`, "/", context.temp_allocator)
	return strings.has_prefix(p, "/") ? fmt.tprintf("file://%s", p) : fmt.tprintf("file:///%s", p)
}

// A file's text ("" when there is none). Shared for deletion: a killed Wren may still hold the file it was renaming (crash_recovery.odin read_bounded).
read_text :: proc(path: string) -> string {
	data, _ := base.file_read_all(path, context.temp_allocator)
	return string(data)
}

write_text :: proc(path, text: string) { _ = os.write_entire_file(path, transmute([]byte)text) }

////////////////////////////////
// How a call is made

// What each call begins with (after its context = s.ctx): the window it is about, given back at the end of the caller's scope. The
// caller's temporary memory is `s.test`'s.
@(private, deferred_out = leave)
enter :: proc(s: ^Session, loc: runtime.Source_Code_Location) -> (^Session, ^browser.Browser_Window) {
	if s.app == nil { failed(s, "the browser has stopped", loc) }
	if s.trace { fmt.eprintf("e2e %8.1f ms  %s:%d %s\n", time.duration_milliseconds(time.tick_since(s.began)), filepath.base(loc.file_path), loc.line, loc.procedure) }
	return s, browser.control_enter(s.app, s.window)
}
@(private) leave :: proc(s: ^Session, prev: ^browser.Browser_Window) { browser.control_leave(s.app, prev) }

// The tab of a call.
@(private)
tab_of :: proc(s: ^Session, loc: runtime.Source_Code_Location) -> ^browser.Tab {
	t := browser.control_tab(s.app, s.tab)
	if t == nil { failed(s, fmt.tprintf("no tab %d", s.tab), loc) }
	return t
}

// What a spell checker would do: bytes [lo, hi) of the text of the element of this id are marked as ::spelling-error or ::grammar-error, in place of what was.
mark_text :: proc(s: ^Session, kind: style.Highlight_Kind, id: string, lo, hi: int, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	p := tab_of(s, loc).page
	el := dom.find_by_id(p.doc, id)
	if el == base.NIL_HANDLE { failed(s, fmt.tprintf("no element %q", id), loc) }
	text := dom.get(p.doc, el).first_child
	page.marks_set(p, kind, {{{text, lo}, {text, hi}}})
}

// A file in another place.
copy_file :: proc(from, to: string) {
	data, err := os.read_entire_file(from, context.temp_allocator)
	if err == nil { _ = os.write_entire_file(to, data) }
}

// A call's answer: it waits for it, running the loop. What failed ends the test.
@(private)
answer :: proc(s: ^Session, o: ^browser.Control_Outcome, rep: browser.Reply, what: string, loc: runtime.Source_Code_Location) {
	if !rep.deferred {
		if rep.code != 0 { failed(s, fmt.tprintf("%s: %s", what, rep.message), loc) }
		return
	}
	kept := strings.clone(what, s.test.temp_allocator)   // (the frames the wait makes empty the temporary memory it was made in)
	if !browser.control_run(s.app, o) { failed(s, fmt.tprintf("%s: the browser ended meanwhile", kept), loc) }
	if o.code != 0 { failed(s, fmt.tprintf("%s: %s", kept, o.message), loc) }
}

// A deadline in the milliseconds of an op.
@(private)
ms_of :: proc(d: time.Duration) -> int { return int(time.duration_milliseconds(d)) }

// A stretch of calls about one window: `e2e.in_window(s, id)` until the end of the scope.
@(deferred_out = window_back)
in_window :: proc(s: ^Session, id: int) -> (^Session, int) {
	was := s.window
	s.window = id
	return s, was
}
@(private) window_back :: proc(s: ^Session, was: int) { s.window = was }

////////////////////////////////
// Barriers. A deadline only ends a failing run.

@(private)
wait_kind :: proc(s: ^Session, kind: api.Wait, what: string, l: browser.Wait_Limits, loc: runtime.Source_Code_Location) {
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_wait(s.app, &c, t, kind, l), what, loc)
}

wait_load :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) { wait_kind(s, .Load, "wait_load", {timeout_ms = ms_of(deadline)}, loc) }
wait_idle :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) { wait_kind(s, .Idle, "wait_idle", {timeout_ms = ms_of(deadline), idle_ms = HOLD_MS}, loc) }
wait_stable :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) { wait_kind(s, .Stable, "wait_stable", {timeout_ms = ms_of(deadline), idle_ms = HOLD_MS}, loc) }

// `n` more frames have been made (they are, as soon as they are asked for).
wait_frames :: proc(s: ^Session, n := 2, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_wait_frames(s.app, &c, browser.current_tab(s.app), n), "wait_frames", loc)
}

wait_selector :: proc(s: ^Session, selector: string, visible := false, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_wait_selector(s.app, &c, t, selector, visible, ms_of(deadline)), fmt.tprintf("wait_selector %s", selector), loc)
}

// A script's condition holds in the page.
wait_js :: proc(s: ^Session, condition: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	_ = eval_result(s, condition, loc = loc)   // (the wait asks a page's script engine and starts none: a page with no script of its own has none yet)
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	what := fmt.tprintf("wait_js %s", condition)
	rep := browser.control_wait_js(s.app, &c, t, condition, ms_of(deadline))
	if !rep.deferred {
		if rep.code != 0 { failed(s, fmt.tprintf("%s: %s", what, rep.message), loc) }
		return
	}
	kept := strings.clone(what, s.test.temp_allocator)   // (the frames the wait makes empty the temporary memory it was made in)
	if !browser.control_run(s.app, &o) { failed(s, fmt.tprintf("%s: the browser ended meanwhile", kept), loc) }
	// (what the page showed then: a wait that never held says nothing of why; a CI run is read from its log)
	if o.code != 0 { failed(s, fmt.tprintf("%s: %s\n  the page then: %s", kept, o.message, page_glimpse(s, t)), loc) }
}

// The page's address and the start of its text, for a failure's message ("(no answer)" when its script engine gives none).
@(private)
page_glimpse :: proc(s: ^Session, t: ^browser.Tab) -> string {
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	rep := browser.control_eval(s.app, &c, t, `location.href + " | " + (document.body ? document.body.textContent.replace(/\s+/g, " ").slice(0, 400) : "(no body)")`, false, PAGE_GLIMPSE_MS)
	// (what the browser knows of the tab without a script: its address and its kind, for a tab whose script gives nothing)
	tab := t != nil ? fmt.tprintf("the tab at %q (%v)", t.url, t.kind) : "no tab"
	if !rep.deferred || !browser.control_run(s.app, &o) || o.code != 0 { return fmt.aprintf("%s; its script gave no answer", tab, allocator = s.test.temp_allocator) }
	return fmt.aprintf("%s; %s", tab, o.text, allocator = s.test.temp_allocator)
}

// One turn of the browser's loop, with a frame asked for: what a poll goes round on.
@(private)
turn :: proc(s: ^Session, loc: runtime.Source_Code_Location) {
	context = s.ctx
	browser.request_frames(s.app, 1)
	if !browser.app_turn(s.app) { failed(s, "the browser ended", loc) }
}

// Turns of the browser's loop with nothing asking for a frame, each after a sleep: what it does when it is left alone. A timer that draws
// nothing wakes it each time.
rest_turns :: proc(s: ^Session, n: int, loc := #caller_location) {
	context = s.ctx
	l := &s.app.loop
	wake := host.set_timer(l, REST_WAKE_MS, REST_WAKE_MS, proc(data: rawptr) { host.quiet_note((^host.Loop)(data)) }, l)
	defer host.clear_timer(l, wake)
	for _ in 0 ..< n { if !browser.app_turn(s.app) { failed(s, "the browser ended", loc) } }
}

// The browser left alone until it has drawn `frames` in all.
rest_until_frames :: proc(s: ^Session, frames: int, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for s.app.rates.frames < frames {
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed waiting for %d frames, at %d", deadline, frames, s.app.rates.frames), loc) }
		rest_turns(s, 1, loc)
	}
}

// The browser left alone until it stops drawing by itself: every timer of its loop due within REST_HORIZON_MS has run, no frame was made
// meanwhile, and no window has a frame to make. What is pending is looked at, not a time: what is not armed cannot draw, and a browser at rest
// returns after a turn or two. (`moving_ok`: something of it keeps moving, a caret: its timers and its frames are left out; it is at rest
// when no other timer is due once to run within REST_HORIZON_MS, and no window has another cause to draw.)
wait_at_rest :: proc(s: ^Session, moving_ok := false, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for {
		frames := s.app.rates.frames
		due := timers_due(s, moving_ok)
		rest_turns(s, 1, loc)   // (a frame asked for is made at the next turn)
		for timers_pending(s, due) {
			if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed and %d timers of the loop are still to run", deadline, len(due)), loc) }
			rest_turns(s, 1, loc)
		}
		quiet := moving_ok ? !one_shot_due(s, moving_ok) : s.app.rates.frames == frames
		if quiet && !frame_wanted(s, moving_ok) { return }
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed and the browser still draws, %d frames", deadline, s.app.rates.frames), loc) }
	}
}

@(private) Due_Timer :: struct { h: base.Handle, deadline: i64 }

// The timers of the browser's loop due within REST_HORIZON_MS (`moving_ok`: but the caret's, which keeps going).
@(private)
timers_due :: proc(s: ^Session, moving_ok: bool) -> []Due_Timer {
	l := &s.app.loop
	horizon := host.now_ns(l) + REST_HORIZON_MS * i64(time.Millisecond)
	due := make([dynamic]Due_Timer, s.test.temp_allocator)
	it: u32
	for h, tm in base.pool_next(&l.timers, &it) {
		if tm.deadline > horizon || (moving_ok && is_caret_site(tm.by)) { continue }
		append(&due, Due_Timer{h, tm.deadline})
	}
	return due[:]
}

// One of them has not run yet (a timer that runs again has a later deadline once it ran).
@(private)
timers_pending :: proc(s: ^Session, due: []Due_Timer) -> bool {
	for d in due {
		if tm := base.pool_get(&s.app.loop.timers, d.h); tm != nil && tm.deadline == d.deadline { return true }
	}
	return false
}

// A timer that runs once is due within REST_HORIZON_MS (`moving_ok`: but the caret's): what is still settling arms them (the status bar's
// numbers falling to rest, one step after the other). A timer that repeats is not one: it ran in the round, and keeps running.
@(private)
one_shot_due :: proc(s: ^Session, moving_ok: bool) -> bool {
	l := &s.app.loop
	horizon := host.now_ns(l) + REST_HORIZON_MS * i64(time.Millisecond)
	it: u32
	for _, tm in base.pool_next(&l.timers, &it) {
		if tm.interval == 0 && tm.deadline <= horizon && !(moving_ok && is_caret_site(tm.by)) { return true }
	}
	return false
}

// A window has a cause to draw (`moving_ok`: but the caret's toggle): what browser/windows.odin window_causes looks at.
@(private)
frame_wanted :: proc(s: ^Session, moving_ok: bool) -> bool {
	context = s.ctx
	for w in s.app.windows {
		if w.frames_requested != 0 && !(moving_ok && w.errands == {.Caret}) { return true }
		if len(w.win.injected) > 0 || ui.needs_frame(w.ui) || ui.wake_due(w.ui) { return true }
	}
	return false
}

// The caret of a field blinks from there (browser/forms_shell.odin): its timer, the frames it asks for.
@(private)
is_caret_site :: proc(loc: runtime.Source_Code_Location) -> bool { return strings.has_suffix(loc.file_path, "forms_shell.odin") }

// Any condition: `ready(s)` is looked at after each turn of the browser's loop, under the test's context. What it needs comes
// as `data` in the second form: `ready(s, data)`.
wait_until_plain :: proc(s: ^Session, ready: proc(s: ^Session) -> bool, what := "a condition", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for !ready(s) {
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed waiting for %s", deadline, what), loc) }
		turn(s, loc)
	}
}

wait_until_with :: proc(s: ^Session, data: $D, ready: proc(s: ^Session, data: D) -> bool, what := "a condition", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for !ready(s, data) {
		if time.tick_diff(time.tick_now(), end) <= 0 { failed(s, fmt.tprintf("%v passed waiting for %s", deadline, what), loc) }
		turn(s, loc)
	}
}

wait_until :: proc { wait_until_plain, wait_until_with }

// The interface's animations have ended (several frames in a row: a frame in which a change has not begun to move yet is not the end of it).
wait_chrome_still :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	quiet := 0
	wait_until(s, &quiet, proc(s: ^Session, quiet: ^int) -> bool {
		quiet^ = stats(s).chrome_animating ? 0 : quiet^ + 1
		return quiet^ >= CHROME_STILL_FRAMES
	}, "the interface's animations to end", deadline, loc)
}
@(private) CHROME_STILL_FRAMES :: 4

////////////////////////////////
// Navigation

// Goes there; returns once it has loaded.
navigate :: proc(s: ^Session, url: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	navigate_begin(s, url, loc)
	wait_load(s, deadline, loc)
}

// The page again; returns once it has loaded.
reload :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	{
		context = s.ctx
		enter(s, loc)
		browser.control_reload(s.app, tab_of(s, loc))
	}
	wait_load(s, deadline, loc)
}

// Back and forward in the tab's history; each returns once what it went to has loaded.
go_back :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) { go_history(s, -1, deadline, loc) }
go_forward :: proc(s: ^Session, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) { go_history(s, 1, deadline, loc) }

@(private)
go_history :: proc(s: ^Session, delta: int, deadline: time.Duration, loc: runtime.Source_Code_Location) {
	{
		context = s.ctx
		enter(s, loc)
		browser.control_history(s.app, tab_of(s, loc), delta)
	}
	wait_load(s, deadline, loc)
}

// Goes there; returns at once (what it leads to may be no page at all: a download).
navigate_begin :: proc(s: ^Session, url: string, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	browser.control_navigate(s.app, tab_of(s, loc), url)
}

// The address of the current tab.
location :: proc(s: ^Session, loc := #caller_location) -> string {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return strings.clone(tab_of(s, loc).url, back)
}

// `text` typed in the address bar, `keys` pressed before Enter, the load waited for: the address it led to.
address_bar :: proc(s: ^Session, text: string, keys: []string = nil, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> string {
	address_bar_open(s, loc)
	type_text(s, text, loc)
	for k in keys { key(s, k, loc = loc) }
	key(s, "Enter", loc = loc)
	wait_load(s, deadline, loc)
	return location(s, loc)
}

// The address bar has the keyboard.
address_bar_open :: proc(s: ^Session, loc := #caller_location) { key(s, "Ctrl+L", loc = loc) }

////////////////////////////////
// Script

// What a script gave: `value` a string's text, else its JSON; `thrown` what it threw ("": nothing).
Script_Result :: struct { kind, value, thrown: string }

// A script whose exception a test looks at.
eval_result :: proc(s: ^Session, expression: string, await := false, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> Script_Result {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	rep := browser.control_eval(s.app, &c, t, expression, await, ms_of(deadline))
	if !rep.deferred { failed(s, fmt.tprintf("eval: %s", rep.message), loc) }
	if !browser.control_run(s.app, &o) { failed(s, "eval: the browser ended meanwhile", loc) }
	if o.code != 0 && !o.has_value && o.kind == "" && o.message == "" { failed(s, "eval: no answer", loc) }
	return {strings.clone(o.kind, back), strings.clone(o.text, back), strings.clone(o.message, back)}
}

// The value of a script's expression, as text: a string's value, else its JSON (await: a promise is waited for). An exception ends the test.
eval :: proc(s: ^Session, expression: string, await := false, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> string {
	r := eval_result(s, expression, await, deadline, loc)
	if r.thrown != "" { failed(s, fmt.tprintf("the script threw: %s\n  %s", r.thrown, expression), loc) }
	return r.value
}

// A script's value (a promise is waited for) is `want`: `what` says what that means. The test goes on when it is not.
expect_eval :: proc(s: ^Session, expression, want, what: string, loc := #caller_location) -> bool {
	got := eval(s, expression, await = true, loc = loc)
	return testing.expectf(s.t, got == want, "%s: got %q, want %q", what, got, want, loc = loc)
}

// ... as a number.
eval_f64 :: proc(s: ^Session, expression: string, loc := #caller_location) -> f64 {
	r := eval(s, expression, loc = loc)
	f, ok := strconv.parse_f64(r)
	if !ok { failed(s, fmt.tprintf("%s gave %q, not a number", expression, r), loc) }
	return f
}

////////////////////////////////
// Input: Wren's own path (platform.inject_event), never the machine's mouse or keyboard

// Keys: "Ctrl+L", "Enter", "Shift+Tab", several separated by spaces.
key :: proc(s: ^Session, keys: string, repeat := 1, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_key(s.app, &c, keys, repeat), fmt.tprintf("key %s", keys), loc)
}

// Text, as the keyboard's text input.
type_text :: proc(s: ^Session, text: string, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_type(s.app, &c, text), "type_text", loc)
}

// A click on an element (scrolled into view; the middle of its box).
click :: proc(s: ^Session, selector: string, button := Button.Left, count := 1, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_click(s.app, &c, t, selector, browser.control_button(button), count, ms_of(deadline)), fmt.tprintf("click %s", selector), loc)
}

// A click at a point.
click_at :: proc(s: ^Session, at: Point, space := Space.Page, button := Button.Left, count := 1, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_click_at(s.app, &c, t, browser.control_point(s.app, at, space), browser.control_button(button), count), "click_at", loc)
}

// The next press is a click of its own, however soon it comes after the last.
forget_clicks :: proc(s: ^Session, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	browser.control_forget_clicks(s.app)
}

hover :: proc(s: ^Session, at: Point, space := Space.Page, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_hover(s.app, &c, browser.control_point(s.app, at, space)), "hover", loc)
}

// A button goes down at a point and stays down until `release`; `hover` moves it meanwhile.
press :: proc(s: ^Session, at: Point, space := Space.Page, button := Button.Left, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_press(s.app, &c, browser.control_point(s.app, at, space), browser.control_button(button)), "press", loc)
}

release :: proc(s: ^Session, at: Point, space := Space.Page, button := Button.Left, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_release(s.app, &c, browser.control_point(s.app, at, space), browser.control_button(button)), "release", loc)
}

// The wheel at a point: `notches` positive goes down (one is WHEEL_NOTCH px), `across` positive right (a touchpad's sideways wheel); `ctrl`: with Ctrl held.
scroll :: proc(s: ^Session, notches: f64, at := Point{api.SCROLL_X, api.SCROLL_Y}, space := Space.Page, ctrl := false, across := 0.0, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	mods: platform.Modifiers
	if ctrl { mods += {.Ctrl} }
	answer(s, &o, browser.control_wheel(s.app, &c, browser.control_point(s.app, at, space), {across * WHEEL_NOTCH, notches * WHEEL_NOTCH}, mods), "scroll", loc)
}
WHEEL_NOTCH :: 100

// A press, moves (one per frame), a release. Window points may be outside the window: the drag leaves it and comes back, through the window's own drop target.
drag :: proc(s: ^Session, from, to: Point, d := Drag_Options{}, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	via := make([][2]f32, len(d.via), context.temp_allocator)
	for v, i in d.via { via[i] = browser.control_point(s.app, v, d.space) }
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_drag(s.app, &c, {
		from = browser.control_point(s.app, from, d.space), to = browser.control_point(s.app, to, d.space), via = via,
		steps = d.steps > 0 ? d.steps : api.DRAG_STEPS, hold = d.hold, resume = d.resume, timeout_ms = ms_of(deadline),
	}), "drag", loc)
}

// Another application's drag dropped on the window, through its drop target (with `leave`, it leaves instead).
drop :: proc(s: ^Session, at: Point, data: Drop_Data, space := Space.Page, leave := false, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	dd := browser.control_drop_data(data)
	defer delete(dd.files)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_drop(s.app, &c, browser.control_point(s.app, at, space), &dd, leave), "drop", loc)
}

////////////////////////////////
// Pixels

// A test that reads pixels says so when it starts: the frames of the others are not rasterized.
@(private)
need_pixels :: proc(s: ^Session, what: string, loc: runtime.Source_Code_Location) {
	if !s.pixels { failed(s, fmt.tprintf("%s reads pixels: start the session with `pixels = true` (e2e.Options)", what), loc) }
}

// The pixels of the next frame: the browser's real render.
capture :: proc(s: ^Session, shot := Shot_Options{}, loc := #caller_location) -> Image {
	need_pixels(s, "capture", loc)
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	answer(s, &o, browser.control_capture(s.app, &c, t, browser.control_shot(s.app, shot)), "capture", loc)
	rgba := make([]u8, len(o.rgba), back)
	copy(rgba, o.rgba)
	return {rgba, o.size.x, o.size.y}
}

// The next frame to a PNG of this test's folder (what is left there stays when the test fails). A picture for whoever reads a failure,
// checked by nothing: in a session that draws no pixels (Options.pixels) there is none.
shot :: proc(s: ^Session, name: string, shot_options := Shot_Options{}, loc := #caller_location) {
	if !s.pixels { return }
	context = s.ctx
	enter(s, loc)
	t := tab_of(s, loc)
	o: browser.Control_Outcome
	defer browser.control_outcome_free(&o)
	c := browser.control_call(&o)
	q := browser.control_shot(s.app, shot_options)
	q.path = fmt.tprintf("%s/%s", s.out, name)
	answer(s, &o, browser.control_capture(s.app, &c, t, q), "shot", loc)
}

////////////////////////////////
// Preferences

pref_set :: proc(s: ^Session, name, value: string, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	if why := browser.control_pref_set(s.app, name, value); why != "" { failed(s, why, loc) }
}

pref_get :: proc(s: ^Session, name: string, loc := #caller_location) -> string {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	v, ok := browser.control_pref_get(s.app, name)
	if !ok { failed(s, fmt.tprintf("no preference %q", name), loc) }
	return strings.clone(v, back)
}

// Back to what it was when the browser started.
pref_reset :: proc(s: ^Session, name: string, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	if why := browser.control_pref_reset(s.app, name); why != "" { failed(s, why, loc) }
}

////////////////////////////////
// Tabs, windows, commands

// Every window's tabs and tab groups.
targets :: proc(s: ^Session, loc := #caller_location) -> Targets {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_tabs(s.app, back)
}

// The tab with this title.
tab_titled :: proc(s: ^Session, title: string, loc := #caller_location) -> Tab {
	for t in targets(s, loc).tabs { if t.title == title { return t } }
	failed(s, fmt.tprintf("no tab is titled %q", title), loc)
}

// A new tab: its id. It becomes the window's current tab. Barrier: wait_load (with s.tab on it, or as the current one).
new_tab :: proc(s: ^Session, url := "", background := false, loc := #caller_location) -> int {
	context = s.ctx
	enter(s, loc)
	return int(browser.control_new_tab(s.app, url, background).id)
}

activate_tab :: proc(s: ^Session, id: int, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	if !browser.control_activate_tab(s.app, id) { failed(s, fmt.tprintf("no tab %d", id), loc) }
}

close_tab :: proc(s: ^Session, id: int, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	if !browser.control_close_tab(s.app, id) { failed(s, fmt.tprintf("no tab %d", id), loc) }
}
// The window the calls are about goes, with its tabs, at the end of the pass.
close_window :: proc(s: ^Session, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	if why := browser.control_close_window(s.app); why != "" { failed(s, why, loc) }
}


// The tab goes to a new window of its own: that window's id.
move_tab_to_new_window :: proc(s: ^Session, id: int, loc := #caller_location) -> int {
	context = s.ctx
	enter(s, loc)
	dest, why := browser.control_move_tab(s.app, id, -1, -1)
	if dest == nil { failed(s, why, loc) }
	return dest.id
}

// The tab goes to window `to`, at `index` (-1: its end), with its page as it is.
move_tab :: proc(s: ^Session, id, to: int, index := -1, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	dest, why := browser.control_move_tab(s.app, id, to, index)
	if dest == nil { failed(s, why, loc) }
}

// The address bar of the window as the last frame laid it out.
urlbar :: proc(s: ^Session, loc := #caller_location) -> Urlbar {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_urlbar(s.app, back)
}

windows :: proc(s: ^Session, loc := #caller_location) -> []Window {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_windows(s.app, back)
}

window_bounds :: proc(s: ^Session, loc := #caller_location) -> Bounds {
	context = s.ctx
	enter(s, loc)
	return browser.control_bounds(s.app)
}

// The size, place, state and scale of the window: what is left out stays.
set_window :: proc(s: ^Session, c: Window_Change, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	if why := browser.control_set_window(s.app, c); why != "" { failed(s, why, loc) }
}

// The window becomes the one the user is in (never the system's focus).
bring_to_front :: proc(s: ^Session, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	browser.control_bring_to_front(s.app)
}

// A command of the interface by name (tab.pin, window.new...): done once its frames are.
run_command :: proc(s: ^Session, name: string, loc := #caller_location) {
	{
		context = s.ctx
		enter(s, loc)
		if why := browser.control_command(s.app, browser.current_tab(s.app), name); why != "" { failed(s, why, loc) }
	}
	wait_frames(s, loc = loc)
}

// The developer tools of the window: `panel` console, elements, network, none; `dock` "", window, bottom, right.
open_devtools :: proc(s: ^Session, panel := "console", dock := "", loc := #caller_location) {
	{
		context = s.ctx
		enter(s, loc)
		if why := browser.control_devtools(s.app, panel, dock); why != "" { failed(s, why, loc) }
	}
	wait_frames(s, loc = loc)
}

////////////////////////////////
// The numbers

// What is cheap enough for a poll.
stats :: proc(s: ^Session, loc := #caller_location) -> Stats {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_stats(s.app, back)
}

// The browser gives back now what it gives back when left alone.
memory_trim :: proc(s: ^Session, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	browser.memory_trim(s.app)
}

// All of them: the process's, the stores', the frames as a measure reads them.
stats_all :: proc(s: ^Session, loc := #caller_location) -> Stats {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_stats_all(s.app, back)
}

// What the frames' numbers count from now on.
stats_reset :: proc(s: ^Session, frames := true, latency := true, loc := #caller_location) {
	context = s.ctx
	enter(s, loc)
	browser.control_stats_reset(s.app, frames, latency)
}

// The elements that match, the first `limit` described.
query_all :: proc(s: ^Session, selector: string, limit := browser.QUERY_ALL_DEFAULT_LIMIT, loc := #caller_location) -> Query_Result {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	r, code, why := browser.control_query_all(s.app, tab_of(s, loc), selector, limit, back)
	if code != 0 { failed(s, why, loc) }
	return r
}

// An element's box, in CSS pixels and in window pixels.
box_model :: proc(s: ^Session, selector: string, loc := #caller_location) -> Box_Model {
	context = s.ctx
	enter(s, loc)
	r, code, why := browser.control_box_model(s.app, tab_of(s, loc), selector)
	if code != 0 { failed(s, why, loc) }
	return r
}

// An element's computed style: `properties` nil: all of it.
computed_style :: proc(s: ^Session, selector: string, properties: []string = nil, loc := #caller_location) -> []Style_Property {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	r, why := browser.control_computed_style(tab_of(s, loc), selector, properties, back)
	if why != "" { failed(s, why, loc) }
	return r
}

// What the tab's page fetched.
network :: proc(s: ^Session, clear := false, loc := #caller_location) -> Network {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_network(tab_of(s, loc), clear, back)
}

// The preferences whose name begins so.
prefs :: proc(s: ^Session, prefix := "", loc := #caller_location) -> []Pref {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_prefs(s.app, prefix, back)
}

// The commands of the interface, and which can run now.
commands :: proc(s: ^Session, loc := #caller_location) -> []Command {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_commands(s.app, back)
}

downloads :: proc(s: ^Session, loc := #caller_location) -> []Download {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_downloads(s.app, back)
}

console :: proc(s: ^Session, since := 0, clear := false, loc := #caller_location) -> []Console_Line {
	back := s.test.temp_allocator
	context = s.ctx
	enter(s, loc)
	return browser.control_console(tab_of(s, loc), since, clear, back)
}

// The browser's profile folder.
profile_dir :: proc(s: ^Session) -> string { return s.app.profile_dir }

