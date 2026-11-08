package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "wb:tools/tooling"

// How a step runs and what it may wait for.
Mark :: enum {
	Light,       // it mostly waits (expiries, servers: seconds of wall clock for a fraction of a second of CPU): it takes no -Jobs slot, up to -LightJobs of them run beside the others
	Asan,        // one of the ASan builds, -sized slots of their own (ASAN_JOBS): their memory is what limits them
	Browser_Build, // wrentool build: one at a time in a tree, two refuse each other's files (build/wren.com, the version resource, build/wren.channel)
	Ui_Only,     // drives real windows, or decodes heavy images under a limit: run with -Ui; never on a CI machine
	No_CI,       // not on the CI, for the reason its line gives: what the job's budget cannot pay for, what the workflow runs by itself
	Flaky,       // known to fail at random: printed FLAKY, it fails nothing. A mark hides a real bug too: only when the cause is known and outside our reach, with the reason in a comment
	Alone,       // it saturates the machine: it runs last, when nothing else does
	Run_All,     // every action runs even when one has failed (a suite of a group says for itself)
	No_Result,   // says by itself whether there is anything to do: nothing kept of it
}
Marks :: bit_set[Mark]

// What a step leaves that others use: a step that needs one runs after the step that makes it, which -Only and the like bring with them.
Product :: enum {
	JS_Engine,       // build/js/wren_js.wasm, which the programs embed
	Native,          // the dependencies of the dev build (build/native/wren_native.lib, Lexbor, Wasmtime), which the programs link
	Launcher,        // build/wren.com, which the browser embeds
	Browser,         // build/wren.exe
	Check_Browser,   // build/wren_check.exe
	Test_Server,     // build/testserver.exe and .dll
	Guests,          // the Wasm guests of the pages of the web tests
	E2E,             // build/e2e_test.exe: the test program, every allocation tracked
	Fetch,           // build/fetch.exe
	Test262,         // build/test262.exe, the suite in build/test262 and the engine's test image build/js-test262
}
Products :: bit_set[Product]

// What a step's result depends on (cache.odin).
Input_Kind :: enum {
	Packages,     // the files of the packages its actions compile and of everything they import, and what a test reads while it runs
	Tree,         // everything a build or a script can read, tests of packages aside: a step that runs a script or the browser
	Sources,      // that with the tests of packages: a step that reads the sources (a lint)
	Everything,   // that and the documentation, the changelog, the licence Worker: what is about them, what generates files
	Dirs,         // only the folders of `Step.packages`
}

// What says that a command passed.
Pass_Rule :: enum {
	Exit_Code,         // its exit code is 0
	Says_Successful,   // that, and a test program says all its tests passed (what it says from this command on: an exit code alone hides a program that ran nothing)
}

Command :: struct {
	argv:     []string,
	env:      []string,    // KEY=VALUE, on top of the run's
	dir:      string,
	rule:     Pass_Rule,
	pkg:      string,      // the package it compiles: an input of the step
	out:      string,      // the program it leaves: a kept result stands only while this file is as it left it
	tests_of: string,      // a source file: the tests it declares are given to the program as -tests:
	also:     string,      // a test that goes with them
	only:     []string,    // of the tests of `tests_of`, only these (a step per test or group of tests: e2e_step's each_test, web_split)
}

// An action done in test_all's own process, on a thread (no process for what needs none): what it says goes to `t.log`.
Task :: struct {
	name: string,
	run:  proc(t: ^Task_Run) -> bool,
	arg:  string,
}

Action :: union { Command, Task }

Step :: struct {
	name:     string,
	actions:  []Action,
	marks:    Marks,
	weight:   int,        // about how many seconds it takes on a CI runner: the order of a run with no durations of a last run
	needs:    Products,
	makes:    Products,
	inputs:   Input_Kind,
	packages: []string,   // more packages (or the folders of .Dirs) than its commands compile
	sources:  []string,   // files of a package it does not depend on as a whole: each counts as itself and what it imports (.Packages)
	outs:     []string,   // what its tasks leave, as Command.out
	limit:    int,        // seconds (0: -StepTimeoutSec)
}

COMMON_NEEDS :: Products{.JS_Engine, .Launcher, .Native}
// Unit tests fail on a leak or a bad free (Odin's runner tracks each test's context.allocator but only warns by default).
MEM_CHECK :: "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true"
// The end-to-end tools track every allocation of the process and fail when anything is left once they have shut down (src/tools/testenv/memory.odin); never in the builds of the browser.
TRACK :: "-define:WREN_TRACK_MEMORY=true"
// Freed memory poisoned and kept out of the heap (src/base/poison.odin): the end-to-end tools and the unit tests of what keeps records across passes; a read of it ends the step.
POISON :: "-define:WREN_POISON_MEMORY=true"
// How long a close and the interface's answer may take on the check build (no optimisation, every allocation tracked).
SWEEP_CHECK_MS :: "60000"
ONE_THREAD :: "-define:ODIN_TEST_THREADS=1"
TOOLKIT :: "-collection:toolkit=ext/gui_toolkit/src"
WB :: "-collection:wb=src"
GUEST_FLAGS :: []string{"-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-collection:wren=sdk/odin", "-o:size"}
// (WREN_SHIPPED_CODE: the engine's machine code in the program, src/js/image/code: with every block on pages of its own, a compile of the image is minutes, past the limits of a test under load.)
E2E_BUILD_FLAGS :: []string{"-build-mode:test", "-o:speed", "-debug", "-use-separate-modules", "-vet", TOOLKIT, WB, "-define:FONT_BACKEND=native", "-define:FONT_NATIVE_LINK=false",
	"-define:A11Y_ACCESSKIT=true", "-define:A11Y_NATIVE_LINK=false", "-define:WREN_CHANNEL=dev", "-define:WREN_SHIPPED_CODE=true", "-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536", ONE_THREAD, "-define:ODIN_TEST_FANCY=false",
	"-extra-linker-flags:/STACK:67108864"}
// How long what may legitimately take long gets, seconds. (A full WPT or test262 is hours under load: a hang shows as children that stop answering, which the tools end themselves.)
LONG_STEP_SECONDS :: 4 * 3600
ENDURANCE_LIMIT_SECONDS :: 1800
WPT_TIMEOUT_MS :: 10000
NET_STRESS_MB :: 100
NASM_DIR :: "build/tools/nasm-2.16.03"

// (the compiler is written "odin" here: this text is part of a step's key, the program is found when it starts)
join :: proc(parts: ..[]string) -> []string {
	out: [dynamic]string
	for p in parts { append(&out, ..p) }
	return out[:]
}

// (compound literals in a procedure live on its stack: what the table keeps is on the heap)
strs :: proc(s: ..string) -> []string { return slice.clone(s) }

exe :: proc(path: string) -> string { return strings.concatenate({path, tooling.EXE_SUFFIX}) }
out_flag :: proc(path: string) -> string { return strings.concatenate({"-out:", path}) }

odin_test :: proc(pkg, out: string, flags: []string = nil, stack := true) -> Command {
	argv := join({"odin", "test", pkg, "-use-separate-modules", MEM_CHECK, "-vet"}, flags, {out_flag(out)}, stack ? tooling.STACK_FLAGS : nil)
	return Command{argv = argv, pkg = pkg, rule = .Says_Successful}
}

odin_build :: proc(pkg, out: string, flags: []string = nil) -> Command {
	return Command{argv = join({"odin", "build", pkg}, flags, {out_flag(out)}), pkg = pkg, out = out}
}

tool_build :: proc(pkg, out: string) -> Command {
	return odin_build(pkg, out, join({"-use-separate-modules", WB, "-vet"}, tooling.STACK_FLAGS))
}

guest :: proc(pkg, out: string) -> Action { return odin_build(pkg, out, GUEST_FLAGS) }

// Of one file of the end-to-end scenarios (src/tools/e2e, docs/testing.md): the tests it declares, in the program built once, in a process of their own.
e2e_run :: proc(file: string) -> Action {
	return Command{argv = strs(exe("build/e2e_test")), tests_of = fmt.aprintf("src/tools/e2e/%s.odin", file), rule = .Says_Successful}
}

// Of one subject of the web tests (src/tools/e2e/web_<subject>.odin): the same, with the test that ends the process with its leak check.
web_run :: proc(subject: string, env: []string = nil) -> Action {
	return Command{argv = strs(exe("build/e2e_test")), tests_of = fmt.aprintf("src/tools/e2e/web_%s.odin", subject), also = "zz_the_process_ends_with_nothing_left", env = slice.clone(env), rule = .Says_Successful}
}

// Tests of a file of src/tools/e2e, every block of the heap on pages of its own.
pages_run :: proc(file: string, only: []string) -> Action {
	return Command{argv = strs(exe("build/e2e_test")), tests_of = file, only = only, env = strs("WREN_POISON_PAGES=1"), rule = .Says_Successful}
}

// A scenario of src/tools/e2e, as a step. `each_test`: a step per test it declares, side by side: tests that mostly wait on processes of their own (real Wrens, their starts
// and ends, a watcher's limit), which one after the other in one process added up to a minute. Each step's name is the scenario's with its test.
// `flaky`: tests of the file in a step of their own, marked .Flaky; the others stay as they are.
e2e_step :: proc(t: ^[dynamic]Step, name, file: string, marks := Marks{}, weight := 0, browser := false, each_test := false, flaky: []string = nil) {
	needs := COMMON_NEEDS + {.E2E, .Test_Server}
	if browser { needs += {.Browser} }
	path := fmt.aprintf("src/tools/e2e/%s.odin", file)
	if names, why := declared_tests(path); len(flaky) > 0 && why == "" {
		rest := make([dynamic]string)
		for test in names { if !slice.contains(flaky, test) { append(&rest, strings.clone(test)) } }
		append(t, Step{name = name, actions = slice_of(Command{argv = strs(exe("build/e2e_test")), tests_of = path, only = rest[:], rule = .Says_Successful}), marks = marks, weight = weight, needs = needs, inputs = .Tree})
		for test in flaky {
			append(t, Step{name = fmt.aprintf("%s [%s]", name, test), actions = slice_of(Command{argv = strs(exe("build/e2e_test")), tests_of = path, only = strs(test), rule = .Says_Successful}), marks = marks + {.Flaky}, needs = needs, inputs = .Tree})
		}
		return
	}
	if names, why := declared_tests(path); each_test && why == "" {
		for test in names {
			append(t, Step{name = fmt.aprintf("%s [%s]", name, test), actions = slice_of(Command{argv = strs(exe("build/e2e_test")), tests_of = path, only = strs(test), rule = .Says_Successful}),
				marks = marks, weight = weight / len(names), needs = needs, inputs = .Tree})
		}
		return
	}
	// (a file that does not parse: the step says so when it runs)
	append(t, Step{name = name, actions = slice_of(e2e_run(file)), marks = marks, weight = weight, needs = needs, inputs = .Tree})
}

// A subject of the web tests in several steps side by side: each group of its tests in a process of its own, and the tests no group names in one more step, so that a new
// test is never left out. Each step's name is the subject's with its group.
web_split :: proc(t: ^[dynamic]Step, name, subject: string, groups: [][]string, marks := Marks{}) {
	path := fmt.aprintf("src/tools/e2e/web_%s.odin", subject)
	names, why := declared_tests(path)
	if why != "" { web_step(t, name, subject, marks); return }
	rest := make([dynamic]string)
	for test in names {
		named := false
		for g in groups { if slice.contains(g, test) { named = true } }
		if !named { append(&rest, test) }
	}
	add :: proc(t: ^[dynamic]Step, name, subject, label: string, tests: []string, marks: Marks) {
		run := web_run(subject).(Command)
		run.only = tests
		append(t, Step{name = fmt.aprintf("%s [%s]", name, label), actions = slice_of(run), marks = marks, needs = COMMON_NEEDS + {.Guests, .E2E, .Test_Server}, sources = web_sources(subject)})
	}
	// (the groups are a literal on the caller's stack: what the table keeps is cloned)
	for g in groups { add(t, name, subject, strings.join(g, ","), slice.clone(g), marks) }
	if len(rest) > 0 { add(t, name, subject, "the others", rest[:], marks) }
}

// What a subject of the web tests depends on: its file and the harness, and what they import. Not the browser the program also links: it does not run in a process of these.
web_sources :: proc(subject: string) -> []string { return strs("src/tools/e2e/web_harness.odin", fmt.aprintf("src/tools/e2e/web_%s.odin", subject)) }

// A subject of the web tests, as a step.
web_step :: proc(t: ^[dynamic]Step, name, subject: string, marks := Marks{}) {
	append(t, Step{name = name, actions = slice_of(web_run(subject)), marks = marks, needs = COMMON_NEEDS + {.Guests, .E2E, .Test_Server}, sources = web_sources(subject)})
}

slice_of :: proc(actions: ..Action) -> []Action {
	out := make([]Action, len(actions))
	copy(out, actions)
	return out
}

unit :: proc(t: ^[dynamic]Step, name, pkg, out: string, flags: []string = nil, marks := Marks{}) {
	append(t, Step{name = name, actions = slice_of(odin_test(pkg, out, flags)), marks = marks, needs = COMMON_NEEDS})
}

// A group of the toolkit's test suites, or a single one: each suite must say that it passed.
toolkit_suite :: proc(suite, out: string, flags: []string = nil) -> Action {
	return Command{argv = join({"odin", "test", fmt.aprintf("ext/gui_toolkit/tests/%s", suite), "-use-separate-modules", MEM_CHECK, "-vet"}, flags, {out_flag(out)}), pkg = fmt.aprintf("ext/gui_toolkit/tests/%s", suite), rule = .Says_Successful}
}

build_table :: proc(cfg: ^Config) -> []Step {
	when ODIN_OS == .Windows { return windows_table(cfg) } else when ODIN_OS == .Linux { return linux_table(cfg) } else { return nil }
}

windows_table :: proc(cfg: ^Config) -> []Step {
	t: [dynamic]Step
	long_run := cfg.ci || !cfg.quick   // -CI and full runs: the check build, the sanitizer

	append(&t, Step{name = "CHANGELOG fragments (wrentool changelog -Check: changelog.d well formed, nothing already released) and the tool's tests",
		actions = slice_of(tool_build("src/tools/wrentool", exe("build/wrentool_step")), Command{argv = strs(exe("build/wrentool_step"), "changelog", "-Check")}, odin_test("src/tools/wrentool/changelog", exe("build/changelog_test"), strs(WB), false)), marks = {.No_CI}, inputs = .Everything})   // (the CI's workflow runs exactly this as its first step, and fails at once)
	// The documentation site is generated from docs/*.md (src/tools/docsite), and the classic presentation of the site from it and the site's pages: site/docs and site/classic must be up to date (deterministic, like wrentool changelog -Check) and every internal link and anchor must resolve.
	append(&t, Step{name = "documentation site up to date and links intact (src\\tools\\docsite -check: site\\docs matches docs\\*.md, site\\classic the site's pages, zero dead internal links or anchors)",
		actions = slice_of(odin_build("src/tools/docsite", exe("build/docsite"), {WB, "-vet"}), Command{argv = strs(exe("build/docsite"), "-check")}, odin_test("src/tools/docsite", exe("build/docsite_test"), strs(WB), false)), inputs = .Everything})
	// What every build below embeds (nothing to do when up to date).
	append(&t, Step{name = "the dependencies of the dev build (wrentool build's step 2; nothing to do when up to date)", actions = slice_of(Task{"the dependencies", task_dependencies, ""}), marks = {.No_Result}, makes = {.Native}, limit = LONG_STEP_SECONDS})
	append(&t, Step{name = "JavaScript engine (src\\tools\\tooling\\js_engine.odin; nothing to do when up to date)", actions = slice_of(Task{"the engine", task_js_engine, ""}), marks = {.No_Result}, makes = {.JS_Engine}})
	// (the two parts apart: everything waits for the program, nothing for its tests)
	append(&t, Step{name = "console launcher: build\\wren.com (src\\tools\\wrencom; the browser embeds it)", actions = slice_of(Task{"wren.com", task_launcher, ""}), marks = {.No_Result}, makes = {.Launcher}})
	unit(&t, "unit tests: console launcher (when to wait for wren.exe and when to let go, the command line it hands over)", "src/tools/wrencom", exe("build/wrencom_test"))
	// The browser, as the steps that start one need it: built unless newer than its sources (a build takes a minute even when nothing changed).
	append(&t, Step{name = "build the browser (wrentool build; nothing to do when newer than its sources)", actions = slice_of(Task{"wrentool build", task_browser, "dev"}), marks = {.No_Result, .Browser_Build}, needs = COMMON_NEEDS, makes = {.Browser}, limit = LONG_STEP_SECONDS})
	if long_run { append(&t, Step{name = "build the check build of the browser (wrentool build check; nothing to do when newer than its sources)", actions = slice_of(Task{"wrentool build check", task_browser, "check"}), marks = {.No_Result, .Browser_Build}, needs = COMMON_NEEDS, makes = {.Check_Browser}, limit = LONG_STEP_SECONDS}) }

	PACKAGES := []string{"base", "host", "dom", "html", "url", "http", "cookies", "csp", "httpcache", "fetch", "css", "style", "webfont", "xml", "images", "media", "webaudio", "canvas2d", "idb", "layout", "forms", "js", "page", "webauthn", "license", "update", "desktop", "adblock", "blocker", "a11y", "browser"}
	for pkg in PACKAGES {
		flags := []string{TOOLKIT, WB}
		// (images: its tests share the process-wide decoder pool and one of them sets its idle time: one test at a time)
		if pkg == "images" { flags = {TOOLKIT, WB, ONE_THREAD} }
		unit(&t, fmt.aprintf("unit tests: %s", pkg), fmt.aprintf("src/%s", pkg), exe(fmt.aprintf("build/%s_test", pkg)), flags)
	}
	unit(&t, "unit tests of freed memory made loud: base (src\\base\\poison.odin: the heap, arenas, scopes, temporary allocators, pools, the C runtime)", "src/base", exe("build/base_poison_test"), {TOOLKIT, WB, POISON})
	unit(&t, "unit tests of the style passes and of layout on poisoned memory: style", "src/style", exe("build/style_poison_test"), {TOOLKIT, WB, POISON})
	unit(&t, "unit tests of the style passes and of layout on poisoned memory: layout", "src/layout", exe("build/layout_poison_test"), {TOOLKIT, WB, POISON})
	// (the Tracy and ETW variants type-checked, not linked: their library is fetched only for the builds that ask for it)
	append(&t, Step{name = "the external profilers (src\\trace: zones paired on every path, TraceLogging's bytes, the provider's GUID in tools\\wren.wprp and tools\\wren_regions.xml; the Tracy and ETW builds of src\\trace and src\\wasm type-check)",
		actions = slice_of(odin_test("src/trace", exe("build/trace_test"), strs(WB)), Command{argv = strs("odin", "check", "src/trace", WB, "-vet", "-no-entry-point", "-define:WREN_TRACY=true", "-define:WREN_ETW=true"), pkg = "src/trace"},
			Command{argv = strs("odin", "check", "src/wasm", WB, "-vet", "-no-entry-point", "-define:WREN_TRACY=true"), pkg = "src/wasm"}), marks = {.Light}})
	append(&t, Step{name = "the default build links no external profiler (src\\tools\\test_all\\profilers_absent.odin: build\\wren.exe imports none of ETW's writing functions and holds no Tracy client)", actions = slice_of(Task{"the profilers' absence", task_profilers_absent, ""}), needs = {.Browser}, marks = {.Light}, inputs = .Tree})
	unit(&t, "unit tests: regexp (src\\engine\\regexp, the ECMAScript regular expressions of URLPattern)", "src/engine/regexp", exe("build/regexp_test"), {TOOLKIT, WB})
	append(&t, Step{name = "unit tests: the headless host (src\\tools\\headless: the windows of the WPT runner's pages, their back/forward cache; against the test server)",
		actions = slice_of(odin_test("src/tools/headless", exe("build/headless_test"), {TOOLKIT, WB})), needs = COMMON_NEEDS + {.Test_Server}})
	append(&t, Step{name = "the engine's C API natively (src\\engine\\jsrt\\judge\\capi_test.odin: judge capi, the calls the glue makes: references, classes, opaque data in the object's block, cycles, the GC epilogue, strings read in place, promises, modules)",
		actions = slice_of(tool_build("src/engine/jsrt/judge", exe("build/judge")), Command{argv = strs(exe("build/judge"), "capi")}), needs = COMMON_NEEDS})
	// (the pipe server is one per process, so its tests run one at a time; the client's tests link the image encoder)
	unit(&t, "unit tests: remote (protocol, pipe server: requests, answers, limits, vanishing clients, stopping with clients connected)", "src/remote", exe("build/remote_test"), {ONE_THREAD, WB})
	unit(&t, "unit tests: measure (src\\tools\\wrentool\\measure: settled, visually ready, the noise floor, what counts as a gain)", "src/tools/wrentool/measure", exe("build/measure_test"), {WB})
	unit(&t, "unit tests: remote api (the channel and the processes of wb:remote/api: a call through the channel and back, a process told again by its creation time)", "src/remote/api", exe("build/remote_api_test"), {ONE_THREAD, WB})
	unit(&t, "unit tests: remote client (wren ctl: options, help, picture diff)", "src/remote/client", exe("build/remote_client_test"), {ONE_THREAD, WB})

	e2e_step(&t, "a frame held through a navigation stands while its page makes style passes (src\\tools\\e2e\\held_styles.odin: what crashed in background_has_url; freed memory poisoned)", "held_styles")
	e2e_step(&t, "a font on its way holds its text and not the page (src\\tools\\e2e\\font_first_paint.odin)", "font_first_paint")
	e2e_step(&t, "what wrentool replay stands on: any name to a recording, the test world, a load recorded (src\\tools\\e2e\\replay_bench.odin)", "replay_bench")
	e2e_step(&t, "a navigation that ends with no document gives the old page back, and a held page goes in the page phase (src\\tools\\e2e\\tab_navigation.odin: Stop, a stopped traversal, a download, one unload per document, each window's wake)", "tab_navigation")
	// (what only pages of their own saw: a flag of a freed block read as a plain value)
	page_tests := odin_test("src/page", exe("build/page_poison_test"), {TOOLKIT, WB, POISON})
	page_tests.env = strs("WREN_POISON_PAGES=1")
	append(&t, Step{name = "IndexedDB, loads cut short and the end of the browser with every block on pages of its own (WREN_POISON_PAGES=1, src\\base\\poison_windows.odin: any touch of a freed block faults)",
		actions = slice_of(pages_run("src/tools/e2e/web_jsweb.odin", strs("jsweb_idb", "jsweb_sections_cut_short_after_100ms")), pages_run("src/tools/e2e/autoscroll.odin", strs("autoscroll_end_to_end")), page_tests), needs = COMMON_NEEDS + {.Guests, .E2E, .Test_Server}, inputs = .Tree})
	e2e_step(&t, "the developer tools resized (src\\tools\\e2e\\devtools_resize.odin: a real window, never shown, and the panel's own keep their surface while they resize, 1:1 and clipped)", "devtools_resize", marks = {.No_CI})   // (a runner's screen is smaller than these real windows)
	e2e_step(&t, "the interface with no browser around it (src\\tools\\e2e\\chrome_interface.odin: its zoom, by the keys and the wheel; the developer tools docked at their size; an open menu over the top resize band; the main menu in a short window, scrolled; the themes' colours; a row's menu over the downloads drop-down; the history tree's text through an animated zoom)", "chrome_interface")
	e2e_step(&t, "every frame around a tab closed in the back and a Ctrl+wheel over a long page holds the page and the interface (src\\tools\\e2e\\whole_frames.odin: the frames the renderer drew, one by one)", "whole_frames")
	e2e_step(&t, "the tab sidebar with no browser around it (src\\tools\\e2e\\chrome_sidebar.odin: opening and closing through the widths between, pinned tabs, tab groups, by commands and by the pointer)", "chrome_sidebar")
	e2e_step(&t, "the address bar's list with no browser around it (src\\tools\\e2e\\chrome_address_bar.odin: the inline completion, Shift+Delete, the cross of a row, Down, Escape)", "chrome_address_bar")
	e2e_step(&t, "the address field's text and what commands ask of the next build, with no browser around them (src\\tools\\e2e\\chrome_keyboard.odin: a home tab's empty field, what is typed through a tab switch from outside, a closed tab or a new address, the bars of full screen)", "chrome_keyboard")
	e2e_step(&t, "who has the keyboard, with real pages (src\\tools\\e2e\\keyboard_owner.odin: a frame behind a tab switch or after the address bar, the letters after a press on a busy page, Tab past the last element and F6)", "keyboard_owner")
	e2e_step(&t, "the artistic new tab with no network (src\\tools\\e2e\\newtab_art.odin: a painting of a source kept reduced by the decoder and a worker, what a session left taken back by the scan and shown from its file at the first new tab, the rest of the folder removed; no window at all)", "newtab_art")
	e2e_step(&t, "the remote channel itself (src\\tools\\e2e\\remote_channel.odin: off at no cost when not asked for, the protocol, a client that vanishes, an oversized message, clients that connect and go, the ACL of the pipe, a taken name, quit with a client connected, wren ctl run)", "remote_channel", weight = 20, browser = true, each_test = true)
	e2e_step(&t, "reset and checkpoints of a driven Wren (src\\tools\\e2e\\remote_state.odin: everything they name is back, a page sees no cookie or storage, a wait of another client ends)", "remote_state", weight = 10, browser = true)
	e2e_step(&t, "what a program does to a page (src\\tools\\e2e\\driven.odin: script, input, the logs, captures and their pixels, a window off the screen or minimized, a tab moved between windows; no window at all)", "driven")
	// (Not on the CI: on a runner's software rasterizer, 160 s of CPU for 30 captures.)
	e2e_step(&t, "a playing video is a plane of the paint order (src\\tools\\e2e\\video_layers.odin: 30 captures in a row, the corners, the dialog and the bar in each, nothing but the video moves; no window at all)", "video_layers", {.No_CI})
	e2e_step(&t, "web APIs in the browser (src\\tools\\e2e\\page_apis.odin: a layout read by a first script, a timer that changes nothing, Web Animations, popovers, the Navigation API, XHTML; no window at all)", "page_apis")
	e2e_step(&t, "two browsers in one process (src\\tools\\e2e\\two_apps.odin: each on a thread of its own, alive at once, sees only its own tabs, pages, storage, channel messages and frame; nothing of either is left; no window at all)", "two_apps")
	e2e_step(&t, "where a link goes, over the page (src\\tools\\e2e\\link_bubble.odin: a box at the page's bottom left corner while the pointer is on a link, the other corner when the pointer is there, the page keeping its hover)", "link_bubble")
	e2e_step(&t, "a browser at rest draws nothing (src\\tools\\e2e\\frames_at_rest.odin: frames over turns of the loop that nothing asked for: none on a static page, on about:blank, under a timer that changes nothing; a caret draws its own pixels at its own flips; an animation does draw, one nobody can see does not; the loading bar at its own rate; no window at all)", "frames_at_rest", marks = {.No_CI})   // (on a runner the address bar's caret drew 5 frames for 3 flips once: cause not found; it runs here)
	e2e_step(&t, "a teardown that hangs says where (src\\tools\\e2e\\shutdown_report.odin: the watchdog ends the process, and what its threads were doing is on its standard error first)", "shutdown_report")
	e2e_step(&t, "accessibility end to end (src\\tools\\e2e\\a11y.odin: what a window tells a screen reader, the chrome's and a page's, and what a reader's requests do; no window at all)", "a11y")
	e2e_step(&t, "what a screen reader reads (src\\tools\\e2e\\a11y_uia.odin: a Wren with a real window, never shown, read and driven through the system's UI Automation)", "a11y_uia", browser = true)
	// (Not on the CI: without a GPU, the picture of a dragged element does not reach the system's drag: dnd_image.odin's read-back stays pending. To be understood.)
	e2e_step(&t, "drag and drop end to end (src\\tools\\e2e\\dnd.odin: a file dropped on a drop zone and elsewhere, a drag between elements, pointer events and coordinates in a scrolled page; no window at all)", "dnd", {.No_CI}, weight = 20)
	e2e_step(&t, "the interface's own zoom end to end (src\\tools\\e2e\\chrome_zoom.odin: Ctrl+wheel over the chrome and the keys while it has the keyboard zoom it and leave the page's scale alone; over the page they zoom the page; no window at all)", "chrome_zoom", weight = 20)
	e2e_step(&t, "scroll anchoring end to end (src\\tools\\e2e\\scroll_anchoring.odin: a block inserted above the view of a tall page scrolled down leaves the view on the same content; not at the top, not with overflow-anchor: none; no window at all)", "scroll_anchoring", weight = 5)
	e2e_step(&t, "middle-click autoscroll end to end (src\\tools\\e2e\\autoscroll.odin: a middle press on a tall page and the pointer moved down scrolls it, faster the farther, Escape stops it, a middle click on a link opens a new tab; sideways on a page that scrolls both ways, and in a panel that scrolls down only, its page taking the sideways part; no window at all)", "autoscroll", weight = 20)
	e2e_step(&t, "the wheel over an open menu end to end (src\\tools\\e2e\\menu_wheel.odin: the main menu in a short window scrolls under the wheel, down and across the page under it does not; closed, the page scrolls; no window at all)", "menu_wheel")
	e2e_step(&t, "a window's own state of the chrome end to end (src\\tools\\e2e\\window_state.odin: a page's full screen in one window of two, left with Escape, the scroll given back; each window's developer tools; the caret blinking in the front window only; no window at all)", "window_state", weight = 10)
	e2e_step(&t, "a tab dragged onto another window's tabs (src\\tools\\e2e\\tab_drag_windows.odin: the insertion mark among pinned tabs and groups, in a row and in the sidebar, where the release puts the tab; injected pointer, no window at all)", "tab_drag_windows", weight = 10)
	e2e_step(&t, "windows on monitors of different scales (src\\tools\\e2e\\window_dpi.odin: the scale of one window of two changes: its scale alone, no scroll jump, devicePixelRatio and resolution queries; a tab moved between scales; no window at all)", "window_dpi")
	// (Not on the CI: on a runner's software rasterizer, 420 s of CPU: a frame per width of the splitter, for each panel and side.)
	e2e_step(&t, "the docked developer tools while their splitter is dragged (src\\tools\\e2e\\devtools_split.odin: for each panel and side, the first frame at a new width is the settled one; no window at all)", "devtools_split", {.No_CI})
	e2e_step(&t, "the panels of the developer tools docked (src\\tools\\e2e\\devtools_panes.odin: the Styles tab dragged below the Elements tree, the Console floated and docked back by a double click, the layouts kept by the profile across a restart; the panel under the page dragged to nearly the whole window; the Console's stack under the others resized and folded; no window at all)", "devtools_panes")
	e2e_step(&t, "editing in the developer tools (src\\tools\\e2e\\devtools_edit.odin: Ctrl+F in Elements finds a text, a selector and an XPath and moves through the matches, Escape shows and hides the Console drawer, the close button last in its strip, a colour picked keeps its format, Up / Shift+Up / Alt+Up / Ctrl+Up step a length and the layout follows; no window at all)", "devtools_edit")
	e2e_step(&t, "a side stack of the developer tools folded (src\\tools\\e2e\\devtools_fold.odin: the Styles stack folded by the button of its strip, the strip dark like the panel at rest and under the pointer, its tooltip the size of its text inside the window, a click on it brings the stack back; no window at all)", "devtools_fold")
	e2e_step(&t, "the address bar's suggestions end to end (src\\tools\\e2e\\urlbar.odin: the inline completion and Enter, Shift+Delete and the cross of a row against the profile's history, Down and Escape, a new tab focused without the list and a click that lists; no window at all)", "urlbar")
	unit(&t, "the result cache and the scheduler of this program (src\\tools\\test_all: what a step depends on, against the compiler's import graph; a change of an input and of nothing else changes a key; a result needs the program it built; the states of a run)", "src/tools/test_all", exe("build/test_all_test"), {WB, ONE_THREAD})
	append(&t, Step{name = "a test simulates what it waits for (src\\tools\\test_all\\lint_sleeps.odin: no sleep in a test source that tools\\test_sleeps_allowed.txt does not list with why)", actions = slice_of(Task{"the sleeps of tests", task_lint_sleeps, ""}), marks = {.Light}, inputs = .Sources})
	append(&t, Step{name = "no code of a test file runs in the programs (src\\tools\\test_all\\lint_test_inits.odin: no @(init), @(fini) or initialiser that calls something in a *_test.odin of src or ext\\gui_toolkit, which every program importing the package would run)", actions = slice_of(Task{"the inits of tests", task_lint_test_inits, ""}), marks = {.Light}, inputs = .Sources})
	append(&t, Step{name = "the web platform's case is ASCII (src\\tools\\test_all\\lint_unicode_case.odin: no strings.to_lower, to_upper, equal_fold or unicode.to_lower, to_upper in src or native that tools\\unicode_case_allowed.txt does not list with why: the Kelvin sign is no 'k' to a tag name)", actions = slice_of(Task{"the Unicode case calls", task_lint_unicode_case, ""}), marks = {.Light}, inputs = .Sources})
	append(&t, Step{name = "the address field has one writer (src\\tools\\test_all\\lint_address.odin: no ui.field_set on it but in address_sync, src\\browser\\windows.odin)", actions = slice_of(Task{"the address field", task_lint_address, ""}), marks = {.Light}, inputs = .Sources})
	append(&t, Step{name = "the globals of the browser's packages against their list (src\\tools\\test_all\\lint_globals.odin: one App's state goes into App, a window's or a tab's into theirs; docs\\architecture.md, Where state lives)", actions = slice_of(Task{"the globals", task_lint_globals, ""}), marks = {.Light}, inputs = .Sources})
	e2e_step(&t, "the frame gate end to end (src\\tools\\e2e\\frame_gate.odin, a real window that nobody sees: the system's drag of a page drag, the page's context menu, a long script preempted by chrome frames; under them a loop of the system paints: a chrome frame, never a full one, deferred where no frame may begin)", "frame_gate")
	e2e_step(&t, "tab sidebar resized by its handle (src\\tools\\e2e\\sidebar_resize.odin: the edge where the pointer is in every frame, the page at its area's width, the width written on release; an injected pointer, no window at all)", "sidebar_resize")
	e2e_step(&t, "the page's scroll bars (src\\tools\\e2e\\page_scrollbars.odin:the room a classic bar takes, its arrows, what its parts do under the pointer; no window at all)", "page_scrollbars")
	e2e_step(&t, "a series of clicks on text (src\\tools\\e2e\\click_series.odin:a double click, a triple click from inside the word; no window at all)", "click_series")
	e2e_step(&t, "who owns the pressed button (src\\tools\\e2e\\pointer_gesture.odin: a press, a thumb, an arrow, :active and a page drag end with their tab, their page or Escape, for good; one series of clicks; a drag is its window's; no window at all)", "pointer_gesture")
	e2e_step(&t, "the page's cursors (src\\tools\\e2e\\cursor.odin: what the page asks for over each element, images and their hotspots, a press held; no window at all)", "cursor")
	e2e_step(&t, "the CSS Custom Highlight API painted (src\\tools\\e2e\\highlight.odin: ::highlight() over a range, what follows the registry, the ranges and the priorities; no window at all)", "highlight")
	e2e_step(&t, "chrome frames and what they hold for a page (src\\tools\\e2e\\chrome_frames.odin: input held for a tab or a window stays off the others; the picture kept follows the hover, a box and the document; a trim leaves every window its picture; a release the system made and a press on the window's frame end a gesture; no window at all)", "chrome_frames")
	e2e_step(&t, "the lines of text decoration by their pixels (src\\tools\\e2e\\text_decoration.odin: lines, ink, marks, strokes, highlights and their order, rows, columns, right to left, chrome frames)", "text_decoration")
	e2e_step(&t, "input under a busy page (src\\tools\\e2e\\busy_page.odin: a script holds the thread, chrome frames take the input: a drag's selection, the scroll bar's thumb, Page Down and Ctrl+L follow at once, the page's turn sees the same; transform and opacity animations go on, a scroll box follows the wheel and its thumb, the caret blinks; no window at all)", "busy_page", flaky = {"the_caret_blinks_while_the_page_is_busy"})   // (failed once on the CI, 18 of 18 passed six at a time, nothing found by reading: a frame short of the screen or of the window's place in front)
	e2e_step(&t, "scroll-driven animations (src\\tools\\e2e\\scroll_driven.odin: scroll() and view() on every kind of value, on the page's turn and in the chrome frames under a script; no window at all)", "scroll_driven")
	e2e_step(&t, "an inline <svg> through a hover (src\\tools\\e2e\\inline_svg_hover.odin: the painting start page's shortcut icons, a new colour being made on the held decoding threads: every frame shows the icon, then the new colour; no window at all)", "inline_svg_hover")
	e2e_step(&t, "an image opened by itself as a viewer (src\\tools\\e2e\\image_viewer.odin: Ctrl+wheel and a pinch zoom it around the pointer, + - 0, clicks, a drag and its cursors, the wheel and the arrows, R and Shift+R, a double click; no window at all)", "image_viewer")
	e2e_step(&t, "the GPU process in the real browser (src\\tools\\e2e\\webgl_process.odin: none without WebGL, one for the first context or started ahead by a first paint, killed and restored, hung and killed by the watcher, it ends with a killed browser)", "webgl_process", browser = true, each_test = true)
	e2e_step(&t, "the small core on a real window (src\\tools\\e2e\\real_window.odin, never shown: WM_DPICHANGED, WM_NCHITTEST and WM_SETCURSOR through the window procedure, the system's z-order for a drop, the swap chain)", "real_window", marks = {.No_CI})   // (a runner's screen and scale are not the test's)
	e2e_step(&t, "service workers, Cache API, BroadcastChannel, OffscreenCanvas in a worker end to end (src\\tools\\e2e\\sw.odin: register, install / activate, claim, fetch intercepted and answered from the cache, a navigation answered by the worker, messages, versions and update, clients, idle stop, navigation preload, Vary; no window shown)", "sw", weight = 20)
	e2e_step(&t, "storage partitioning end to end (src\\tools\\e2e\\partition.odin: a third party embedded in another site has its own cookies, localStorage, sessionStorage, Cache API, BroadcastChannel and service workers there, Sec-Fetch-Storage-Access, document.requestStorageAccess() after a click; no window shown)", "partition", weight = 10)
	e2e_step(&t, "origin private file system and File System Access end to end (src\\tools\\e2e\\fs.odin: handles, writables, a sync access handle in a worker, IndexedDB clones, quota, pickers on files of the disk through browser.dialogs.test_answer; no window shown)", "fs", weight = 10)
	e2e_step(&t, "what a long session leaves behind (src\\tools\\e2e\\memory_growth.odin: the back/forward cache and the compiled modules counted by what they hold, the process levels off, closed tabs give their memory back)", "memory_growth", weight = 30)
	e2e_step(&t, "back/forward cache measured end to end (src\\tools\\e2e\\bfcache.odin: a hit, a page refused for its unload handler and its reason counted, a miss; wren ctl stats: bfcache)", "bfcache", weight = 5)
	e2e_step(&t, "history end to end (src\\tools\\e2e\\history.odin: a long page scrolled and filled, left, Alt+Left through Wren's own input: everything where it was, from the back/forward cache and loaded again; no window at all)", "history", weight = 5)
	e2e_step(&t, "downloads end to end on both network stacks (src\\tools\\e2e\\download.odin: an attachment, a binary named by its URL, a slow body; no window shown)", "download")
	e2e_step(&t, "shared workers and module workers end to end (src\\tools\\e2e\\workers.odin: two tabs share one worker, connect, ports, lifetime, close(), module imports; no window shown)", "workers", weight = 10)
	e2e_step(&t, "the policy file is read beside the executable, never from the working directory (src\\tools\\e2e\\policy_file.odin)", "policy_file", browser = true)
	e2e_step(&t, "the console launcher wren.com (src\\tools\\e2e\\wrencom.odin: wren ctl gives its output and exit code whatever its outputs are; an address lets go at once; it dies with its child and will not start itself; Setup writes it beside wren.exe with the PATH entry and takes it away with it)", "wrencom", browser = true, each_test = true)
	e2e_step(&t, "a program of the working directory never runs in place of the system's (src\\tools\\e2e\\planted_program.odin: the report of a session that ended without one asks wevtutil.exe for the Windows record; one planted beside the document must not run)", "planted_program", browser = true)
	e2e_step(&t, "the engine's machine code in the program (src\\tools\\e2e\\shipped_code.odin: a new profile with an empty cache compiles nothing; another configuration passes it by, compiles once and runs)", "shipped_code", browser = true, each_test = true)
	e2e_step(&t, "a document's requests leave while its bytes arrive (src\\tools\\e2e\\preload_arrival.odin: the server holds the document's end until it sees the request of its beginning)", "preload_arrival", weight = 10, browser = true)
	e2e_step(&t, "what a page can do to the answers of wren ctl eval (src\\tools\\e2e\\remote_page.odin: it sees the line, so the line holds no secret; another tab's forgery and a value with a line break change nothing)", "remote_page", weight = 15, browser = true)
	e2e_step(&t, "wren ctl stop ends the Wren it started and nothing else (src\\tools\\e2e\\ctl_stop.odin: a session file whose pid is another program's now, or that does not say who the process was, leaves that program alone; a throwaway profile goes)", "ctl_stop", browser = true)
	e2e_step(&t, "tabs come back after a crash and never loop (src\\tools\\e2e\\crash_recovery.odin: a killed Wren leaves running.txt and recovery.txt, the next start restores the tabs, a restoring start that ends too is followed by a blank page and the tabs kept in a file, a normal end removes both files, a Wren that still runs is not taken for a crash)", "crash_recovery", browser = true)
	e2e_step(&t, "one Wren per profile (src\\tools\\e2e\\instance.odin: a second start hands its addresses over and ends with code 0; another profile, another executable, --new-window, a first one that does not answer keep their own; hidden windows)", "instance", browser = true, each_test = true)
	e2e_step(&t, "Setup (src\\tools\\e2e\\setup.odin: the real dialog, registry and files against throwaway roots: install, uninstall of the running copy, standalone, the automatic opening and its exceptions, the daily update check)", "setup", marks = {.No_CI}, browser = true)   // (on a runner the running copy was not out of the way once: cause not found; it runs here)
	append(&t, Step{name = "crash reports (src\\tools\\e2e\\crash_reports.odin: src/tools/crashmodes dies by an access violation, an assertion, a stack overflow, a corrupted heap, a fail-fast: each leaves a report with a stack and a minidump, or the session file the next start turns into an unclean-exit report)",
		actions = slice_of(odin_build("src/tools/crashmodes", "build/crashmodes.exe", {WB, "-debug", "-vet"}), odin_build("src/tools/crashmodes", "build/crashmodes_poison.exe", {WB, "-debug", "-vet", POISON}), e2e_run("crash_reports")), needs = COMMON_NEEDS + {.E2E, .Test_Server}, inputs = .Tree, marks = {.No_CI}})   // (on a runner overflow_thread left no report once: cause not found; it runs here)
	e2e_step(&t, "the system menu of the Wren icon (src\\tools\\e2e\\system_menu.odin: a click opens it, a frame is made in its loop, a key closes it, tabs on top and in a sidebar; the menu was opened during the build and its frames were built inside it, the crash of the 2026-10-26 experimental build; a hidden window)", "system_menu", browser = true)
	e2e_step(&t, "who chose an address (src\\tools\\e2e\\nav_trust.odin: a page asking by script for about:sites?clear=..., a file or a share is refused and F5, Back and Forward never obey it; the same addresses typed by the person, and the links of about:sites, still work)", "nav_trust", weight = 20)
	e2e_step(&t, "about:config end to end (src\\tools\\e2e\\config.odin: search, a switch, a number, a value out of range, a choice, reset, details, a category by type-ahead, all from the keyboard; no window at all)", "config")
	e2e_step(&t, "search engines end to end (src\\tools\\e2e\\search.odin: a profile of before the list keeps its choice, the default, keywords, Ctrl+Down in the suggestions, an engine added in about:config and written to the profile; engines on the test server, no window at all)", "search")

	unit(&t, "unit tests: wasm", "src/wasm", exe("build/wasm_test"), {WB, ONE_THREAD})
	unit(&t, "unit tests: WPT reference tests (links and fuzzy annotations as WPT reads them, comparison, PNG, the rasteriser from markup to pixels)", "src/tools/wpt/reftest", exe("build/wpt_reftest_test"), {TOOLKIT, WB})
	unit(&t, "unit tests: bindgen (description language, determinism)", "src/tools/bindgen/idl", exe("build/bindgen_test"), {WB})
	unit(&t, "unit tests: wrentool threadtime (whose work the window thread did, by its spans; when it settled)", "src/tools/wrentool/threadtime", exe("build/wrentool_threadtime_test"), {WB})
	append(&t, Step{name = "process allocators: no runtime.default_context / heap_allocator / default_allocator outside src\\base\\memory.odin (base.process_context, process_allocator, permanent_allocator: what the check builds track; a line that must not use the tracker says why after // memcheck:)",
		actions = slice_of(Task{"the allocators", task_process_allocators, ""}), inputs = .Tree})
	// (its own exe: the browser's build, which a parallel step may run, runs bindgen too)
	append(&t, Step{name = "generated web API up to date (bindgen -check)", actions = slice_of(Command{argv = join({"odin", "run", "src/tools/bindgen", WB, "-vet", out_flag(exe("build/bindgen_check"))}, tooling.STACK_FLAGS, {"--", "-check"}), pkg = "src/tools/bindgen"}), inputs = .Everything})
	// test262 in three steps (their names begin with "test262": the CI runs them as a job of their own). What both runs read, made once: the suite, the test image of the engine (its own build of
	// the glue, beside the browser's engine and not after it) and the runner. Then the interpreter's run and the JIT's side by side: each writes its own error file.
	test262_quick := cfg.quick ? strs("-quick") : nil
	append(&t, Step{name = "test262: the suite, the test image of the engine and the runner (src\\tools\\test262\\prepare.odin, build\\test262; nothing to do when up to date)",
		actions = slice_of(Task{"the runner", task_runner, cfg.quick ? "test262 quick" : "test262"}, Command{argv = strs(exe("build/test262"), "-prepare")}), marks = {.No_Result}, makes = {.Test262}, limit = LONG_STEP_SECONDS})
	append(&t, Step{name = "test262 in the Wasm engine (-Quick: every 25th test; fails on a failure src\\tools\\test262\\known_failures.txt does not list)",
		actions = slice_of(Command{argv = join({exe("build/test262")}, test262_quick)}), weight = 40, needs = {.Test262}, inputs = .Tree, limit = LONG_STEP_SECONDS})
	append(&t, Step{name = "test262 with the JIT: examples\\jsbench\\jitcheck.js and recursion.js interpreted and compiled (every function and loop at once, synchronously and with the step path), then test262 the same way",
		actions = slice_of(
			Task{"the tool", task_runner, cfg.quick ? "jsengine=jsengine_jit quick" : "jsengine=jsengine_jit"},
			Command{argv = strs(exe("build/jsengine_jit"), "verify", "-image", "build/js/wren_js.wasm", "-jit", "-jit-threshold", "1", "-jit-loop", "1", "-jit-sync", "examples/jsbench/jitcheck.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "verify", "-image", "build/js/wren_js.wasm", "-jit", "-jit-threshold", "1", "-jit-loop", "1", "-jit-sync", "-jit-step", "examples/jsbench/jitcheck.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "verify", "-image", "build/js/wren_js.wasm", "-jit", "-jit-threshold", "1", "-jit-loop", "1", "-jit-sync", "examples/jsbench/recursion.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "verify", "-image", "build/js/wren_js.wasm", "-jit", "-jit-threshold", "1", "-jit-loop", "1", "-jit-sync", "-jit-step", "examples/jsbench/recursion.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "reach", "-image", "build/js/wren_js.wasm", "-jit-threshold", "2000", "-jit-loop", "1", "examples/jsbench/jitreach.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "reach", "-image", "build/js/wren_js.wasm", "examples/jsbench/jithot.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "cold", "-image", "build/js/wren_js.wasm", "examples/jsbench/jitcold.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "run", "-image", "build/js/wren_js.wasm", "examples/jsbench/hotcheck.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "cost", "-image", "build/js/wren_js.wasm", "--pref", "wasm.wasmtime.fuel=true", "examples/jsbench/cost.js")},
			Command{argv = strs(exe("build/jsengine_jit"), "lazy", "-image", "build/js/wren_js.wasm")},
			Command{argv = strs(exe("build/jsengine_jit"), "lazy", "-image", "build/js/wren_js.wasm", "-jit", "-jit-threshold", "1", "-jit-loop", "1", "-jit-sync")},
			Command{argv = strs(exe("build/jsengine_jit"), "gc", "-image", "build/js/wren_js.wasm")},
			Command{argv = strs(exe("build/jsengine_jit"), "gc", "-image", "build/js/wren_js.wasm", "-jit", "-jit-threshold", "1", "-jit-loop", "1", "-jit-sync")},
			Command{argv = strs(exe("build/jsengine_jit"), "polls", "-image", "build/js/wren_js.wasm")},
			Command{argv = strs(exe("build/jsengine_jit"), "hung", "-image", "build/js/wren_js.wasm", "examples/jsbench/hung.js")},
			Command{argv = join({exe("build/test262"), "-jit", "-jit-sync", "-jit-threshold", "2", "-jit-loop", "1"}, test262_quick)},
		), weight = 70, needs = {.JS_Engine, .Test262}, inputs = .Tree, limit = LONG_STEP_SECONDS})
	append(&t, Step{name = "web API conformance (generated cases: bounds, UTF-8, handles, enums, capacity)",
		actions = slice_of(
			odin_build("examples/apiconformance", "build/apiconformance.wasm", {"-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-o:size"}),
			odin_build("src/tools/apiconformance", exe("build/apiconformance"), join({"-use-separate-modules", WB, "-vet", TRACK}, tooling.STACK_FLAGS)),
			Command{argv = strs(exe("build/apiconformance"), "build/apiconformance.wasm")},
		), needs = COMMON_NEEDS})

	// (layers, projected planes, filters, kept filter results, blend modes, clip shapes, blend spaces, gradients, shadows, retained pictures, text on DirectWrite, color glyphs, COLR interpreter and
	// built-in emoji, masks, precompiled shaders, Slug text; WARP.) The 14 suites are 58 s one after the other: in five steps of about 12 s they go to whichever job is free.
	GROUPS := [][]string{{"shadows", "text", "color_glyphs"}, {"gpufx", "gradients", "layers"}, {"colr", "masks", "slug"}, {"planes", "effects", "retained"}, {"blend_space", "shaders"}}
	for group in GROUPS {
		actions := make([]Action, len(group))
		for suite, i in group { actions[i] = toolkit_suite(suite, exe(fmt.aprintf("build/toolkit_%s_test", suite))) }
		append(&t, Step{name = fmt.aprintf("graphics toolkit pixel tests: %s (WARP)", strings.join(group, ",")), actions = actions, marks = {.Run_All}, weight = 20})
	}
	append(&t, Step{name = "graphics toolkit color glyph tests again with the COLR interpreter instead of Direct2D (COLR v0 / v1: gradients, paint trees, text color, async, pictures)", actions = slice_of(toolkit_suite("color_glyphs", exe("build/toolkit_color_glyphs_builtin_test"), {"-define:COLR_ENGINE=builtin"}))})
	toolkit_one := []string{ONE_THREAD}
	append(&t, Step{name = "graphics toolkit keyboard tests (menus, lists, line edit history, wrapped text; no window)", actions = slice_of(toolkit_suite("keyboard", exe("build/toolkit_keyboard_test"), toolkit_one))})
	append(&t, Step{name = "graphics toolkit window chrome tests (title bar hit test and regions, virtual list, wrap cache, scroll curve; no window)", actions = slice_of(toolkit_suite("chrome", exe("build/toolkit_chrome_test"), toolkit_one))})
	append(&t, Step{name = "graphics toolkit cursor tests (CSS names, system or drawn, drawn shapes, custom cursors; a hidden window, never shown)", actions = slice_of(toolkit_suite("cursors", exe("build/toolkit_cursors_test"), toolkit_one))})
	append(&t, Step{name = "graphics toolkit status tests (sample history, frame graph; no window)", actions = slice_of(toolkit_suite("status", exe("build/toolkit_status_test"), toolkit_one))})
	append(&t, Step{name = "graphics toolkit interaction states tests (hover, press and selection at once, transitions on demand, palette cross-fade, state fills in both blend spaces; no window)", actions = slice_of(toolkit_suite("states", exe("build/toolkit_states_test"), toolkit_one))})

	// The test program (src/tools/e2e, docs/testing.md): one program on Odin's test runner that links the browser, built once, every allocation tracked (what that costs a step does not show: 2 % of 500 s of CPU); a step runs the tests of one file of it, in a process of its own.
	append(&t, Step{name = "build the test program (src\\tools\\e2e: the browser in the tests' process, no window, the real renderer offscreen, every allocation tracked, freed memory poisoned: a test that leaves anything allocated fails, a read of what was freed ends it)", actions = slice_of(odin_build("src/tools/e2e", exe("build/e2e_test"), join({TRACK, POISON}, E2E_BUILD_FLAGS))), needs = COMMON_NEEDS + {.Browser}, makes = {.E2E}})   // (it links build/native, which the browser's build makes)
	append(&t, Step{name = "the Wasm guests of the pages of the web tests",
		actions = slice_of(
			guest("examples/e2e", "build/e2e.wasm"), guest("examples/counter", "examples/site/counter.wasm"), guest("examples/formstest", "examples/site/formstest.wasm"), guest("examples/fetchpage", "examples/site/fetchpage.wasm"),
			guest("examples/mutation", "examples/site/mutation.wasm"), guest("examples/mutation_class", "examples/site/mutation_class.wasm"), guest("examples/webapitest", "build/webapitest.wasm"),
			guest("examples/netapitest", "build/netapitest.wasm"), guest("examples/workerstest", "build/workerstest.wasm"), guest("examples/workerstest_worker", "examples/site/workerstest_worker.wasm"),
			guest("examples/imagestest", "build/imagestest.wasm"),
		), needs = COMMON_NEEDS, makes = {.Guests}})
	web_step(&t, "JavaScript in pages (src\\tools\\e2e\\web_realm.odin: realm, scripts, bindings, events, wrappers and node lifetime, bytecode cache, interruption)", "realm")
	append(&t, Step{name = "build fetch", actions = slice_of(tool_build("src/tools/fetch", exe("build/fetch"))), needs = COMMON_NEEDS, makes = {.Fetch}})
	append(&t, Step{name = "licence tool (a licence issued with the development pair verifies; an altered one and one of another key do not; keygen refuses a path inside the repository)",
		actions = slice_of(tool_build("src/tools/license", exe("build/license")), Task{"its checks", task_license_tool, ""}), needs = COMMON_NEEDS})
	append(&t, Step{name = "licence Worker (licence\\worker, no network: Paddle-Signature checks, transaction.completed, idempotency, KV, mail, and licences made with the development pair verified by Wren's own tool; SKIP when neither node 22.18+ nor bun is installed)",
		actions = slice_of(tool_build("src/tools/license", exe("build/license_worker")), Task{"its tests", task_license_worker, ""}), needs = COMMON_NEEDS, inputs = .Everything})
	web_step(&t, "file: folders end-to-end test (index file, listing, redirect to /, errors, who may open what; no server)", "file")
	unit(&t, "unit tests: test host (what fails a section of the web tests: what it declared did not run, a skip the machine does not confirm)", "src/tools/testhost", exe("build/testhost_test"), {WB})
	web_step(&t, "DOM for JavaScript end-to-end test (src\\tools\\e2e\\web_jsdom.odin: tree, elements, markup, selectors, CSSOM, geometry, UI events, MutationObserver, traversal, ranges, leaks, micro-benchmarks; no server)", "jsdom")
	web_step(&t, "history end-to-end test (src\\tools\\e2e\\web_history.odin: the tree as pages see it, scrollRestoration, pageshow / pagehide persisted, back/forward cache freezing, persisted form state; no server)", "history")
	web_step(&t, "Web Authentication end-to-end test (src\\tools\\e2e\\web_webauthn.odin: create then get from JavaScript on the virtual authenticator, signature checked; activation, RP ID, aborts, timer, mediation, JSON forms, secure context; no server)", "webauthn")
	// (the two parts apart: what talks to the server waits for the programs, not for the 60 s of its tests' waits)
	append(&t, Step{name = "build testserver", actions = slice_of(Task{"the programs", task_testserver, ""}), marks = {.No_Result}, makes = {.Test_Server}})
	append(&t, Step{name = "test server tests (go test: /site/ index, listings, extensionless pages, types)", actions = slice_of(Command{argv = strs("go", "test", "."), dir = "tools/testserver"}), marks = {.Light}, inputs = .Dirs, packages = strs("tools/testserver")})
	if long_run {
		// The browser's check build (wrentool build check: every allocation tracked). 1. It drives itself through a session and through tabs opened and closed by the dozen (src/tools/e2e/memcheck.odin, src/tools/endurance): nothing may
		// be left allocated at exit, nor grow while it runs. It opens a window (no input of the desktop's); the endurance run is the long one in full runs (400 tabs, the native memory too).
		endurance_args := join({exe("build/endurance"), "-timeout", fmt.aprint(ENDURANCE_LIMIT_SECONDS * cfg.slow)}, cfg.quick ? strs("-cycles", "8", "-warmup", "3", "-no-native") : nil)
		append(&t, Step{name = "browser check build: a scripted session (tabs, JavaScript, images, forms, back/forward cache, palette, history) exits with nothing allocated; tabs opened and closed by the dozen leave nothing growing (tracked bytes, handles; the native memory too in full runs)",
			actions = slice_of(e2e_run("memcheck"), tool_build("src/tools/endurance", exe("build/endurance")), Command{argv = endurance_args}), weight = 120, needs = COMMON_NEEDS + {.Check_Browser, .E2E, .Test_Server}, inputs = .Tree, limit = LONG_STEP_SECONDS})
		// Freed memory poisoned (the check build): the pages of tools/sweep_local.txt visited as a person does, headless, no network; a read of what was freed ends the visit with a report.
		append(&t, Step{name = "local pages on the check build (wrentool sweep -List tools\\sweep_local.txt: load, scroll, developer tools, back, reload, a tab, loads cut short, close, with freed memory poisoned)",
			actions = slice_of(tool_build("src/tools/wrentool", exe("build/wrentool_step")), Command{argv = strs(exe("build/wrentool_step"), "sweep", "-List", "tools/sweep_local.txt", "-Exe", exe("build/wren_check"), "-OutDir", "build/sweep_local", "-CloseMs", SWEEP_CHECK_MS, "-PingMs", SWEEP_CHECK_MS)}), weight = 60, needs = COMMON_NEEDS + {.Check_Browser}, inputs = .Tree})
		// 2. The remote control channel (every allocation tracked): a session that touches the whole channel exits with nothing allocated.
		append(&t, Step{name = "remote control on the check build: a driven session (navigate, script, input, capture, events, a client that vanishes, reset, checkpoints, quit) leaves nothing allocated (src\\tools\\e2e\\remote_check.odin)",
			actions = slice_of(e2e_run("remote_check")), weight = 30, needs = COMMON_NEEDS + {.Check_Browser, .E2E, .Test_Server}, inputs = .Tree})
	}

	web_step(&t, "network policy test (CORS, cookies, redirects, CSP, schemes)", "policy", {.Light})
	web_step(&t, "content blocker end-to-end test (src\\tools\\e2e\\web_blocker.odin: blocked script / frame / fetch, element hiding before the first style, scriptlet, whitelist, dynamic rules, journal, counters)", "blocker", {.Light})
	web_step(&t, "HTTP cache end-to-end test (src\\tools\\e2e\\web_cache.odin: freshness, revalidation, Vary, cache modes, partitions, invalidation, stale-while-revalidate, disk cache across a restart)", "cache", {.Light})
	web_step(&t, "end-to-end page test", "page")
	web_step(&t, "EventSource / WebSocket end-to-end test (src\\tools\\e2e\\web_netapi.odin)", "netapi", {.Light})
	append(&t, Step{name = "network transport test on both stacks (src\\tools\\e2e\\web_net.odin: heads, bodies, gzip, caps, cancel, timeouts, refused / unresolved / cut / garbage answers, certificates; built-in stack: HTTP/2, HTTP/3 from Alt-Svc and the fall back to TCP when QUIC is blocked, TLS 1.3 only, expired and misnamed certificates, wss, the proxy)",
		actions = slice_of(web_run("net", {"WREN_NET_BACKEND=winhttp"}), web_run("net", {"WREN_NET_BACKEND=rust"})), marks = {.Light, .Run_All}, needs = COMMON_NEEDS + {.Guests, .E2E, .Test_Server}, sources = web_sources("net")})
	web_step(&t, "WebSocket closing handshake test (src\\tools\\e2e\\web_wsclose.odin: close right after a message or the upgrade, late, missing and crossing close frames, server cutting TCP; repeated)", "wsclose", {.Light})
	web_step(&t, "web platform API test (timers, rAF, abort, fetch streams, encoding, crypto, storage, URL, history)", "webapi")
	web_step(&t, "forms end-to-end test (controls, validation, FormData, submission)", "forms")
	web_step(&t, "workers end-to-end test (messages, transfer, fetch, terminate, 16 in parallel)", "workers")
	web_step(&t, "JavaScript loading end-to-end test (script order, document.write, dynamic scripts, modules, handlers, CSP, noscript, timers, errors, workers, cloning)", "jsload")
	web_step(&t, "nested documents end-to-end test (src\\tools\\e2e\\web_frames.odin: iframes, srcdoc, load events, postMessage across origins, cross-origin WindowProxy, sandbox, X-Frame-Options, frame-ancestors, frame-src, navigation, Permissions Policy)", "frames")
	web_step(&t, "site compatibility end-to-end test (src\\tools\\e2e\\web_sitecompat.odin: reduced fixtures of real sites: stylesheet load events, media swap, scroll events)", "sitecompat")
	// (in steps side by side: its sections are independent, and the long ones alone were 80 s one after the other on an idle machine: webcrypto 18 s, the WebGL API 16 s on the
	// software adapter, the sections cut short 21 s of pages left at a set time, Web Audio 6 s, the media 12 s)
	web_split(&t, "JavaScript web APIs end-to-end test (fetch, XHR, streams, URL, encoding, abort, storage, history, navigator, crypto, sockets, messaging; src\\tools\\e2e\\web_jsweb.odin)", "jsweb",
		{{"jsweb_webcrypto"}, {"jsweb_webgl_api"}, {"jsweb_webaudio", "jsweb_webaudio_autoplay"}, {"jsweb_htmlmedia", "jsweb_mse", "jsweb_mse_builtin_decoders"},
		 {"jsweb_sections_cut_short_at_once", "jsweb_sections_cut_short_after_10ms"}, {"jsweb_sections_cut_short_after_100ms"}, {"jsweb_sections_cut_short_after_300ms"}})
	web_step(&t, "style run-time test (web fonts, transitions, animations)", "style")
	web_step(&t, "image formats end-to-end test (AVIF, WebP, SVG images and backgrounds, inline <svg>, Accept, <picture>)", "media", {.Ui_Only})
	web_step(&t, "images end-to-end test (events, srcset, picture, lazy, CSS images, cache, cancellation, 200 x 1 Mpx)", "images", {.Light})
	web_step(&t, "whose work a timer is end-to-end test (src\\tools\\e2e\\web_work.odin: a script of another site, through its timers, responses and listeners)", "work", {.Light})
	wpt_args := join({exe("build/wpt"), "-timeout", fmt.aprint(WPT_TIMEOUT_MS * cfg.slow)}, cfg.quick ? strs("-quick") : nil)
	append(&t, Step{name = "web-platform-tests (wpt\\suites.txt, pinned; -Quick: a sample; fails on a regression against wpt\\expectations)",
		actions = slice_of(Task{"the runner", task_runner, cfg.quick ? "wpt quick" : "wpt"}, Command{argv = wpt_args}), weight = 50, needs = COMMON_NEEDS + {.Test_Server, .Browser}, inputs = .Tree, limit = LONG_STEP_SECONDS})   // (.Browser: the runner links build/native, which the browser's build makes; built before it, it had the old network stack)

	if long_run {
		append(&t, Step{name = "the names of a release's crash frames (src\\tools\\wrentool\\deps\\symbols_test.odin: the report of a build with no PDB gives its fingerprint and offsets, wrentool crash-symbolize names them from the map, or through the minidump)",
			actions = slice_of(odin_test("src/tools/wrentool/deps", exe("build/wrentool_deps_test"), strs(WB), false)), inputs = .Tree})
		e2e_step(&t, "tab sidebar features that need a page or a profile (src\\tools\\e2e\\sidebar_tabs.odin, no window at all: the sound of a tab, what comes back at the next start)", "sidebar_tabs")
		e2e_step(&t, "what Ctrl+Shift+T brings back and the option that reopens the session (src\\tools\\e2e\\closed_tabs.odin, no window at all: a tab with its history, a window, the session before)", "closed_tabs")
		// (frames counted against the screen's refresh: on a loaded CI runner one frame in two came late; a measure with a real pointer, not a test of a tool: run with -Ui)
		append(&t, Step{name = "splitters dragged (wrentool bench cadence, no window shown: the developer tools docked right and bottom, the tab sidebar's handle; their frames are drags of the cadence model and, on a variable refresh screen, presented at once; the rates are printed, never checked)",
			actions = slice_of(tool_build("src/tools/wrentool", exe("build/wrentool_step")), Command{argv = strs(exe("build/wrentool_step"), "bench", "cadence")}), marks = {.Ui_Only}, needs = COMMON_NEEDS + {.Browser}, inputs = .Tree})
		if !cfg.no_asan { asan_steps(&t) }
	}
	if !cfg.quick {
		append(&t, Step{name = "network stress", actions = slice_of(Task{"fetch.exe against the server", task_net_stress, ""}), needs = {.Fetch, .Test_Server}, inputs = .Tree, packages = strs("src/tools/fetch")})
		append(&t, Step{name = "WebGL device tests (native\\webgl: the GLSL ES translator, formats, hostile shaders, a context on the software adapter, the GPU process killed, hung and hostile)",
			actions = slice_of(Command{argv = strs("cargo", "test", "--profile", "quick", "--locked", "--manifest-path", "native/Cargo.toml", "--target-dir", "build/native/target", "-p", "wren_webgl")}), inputs = .Tree, limit = LONG_STEP_SECONDS})
		append(&t, Step{name = "native WOFF2 decoder tests (real Google Fonts against their TrueType, collections, corruptions) and cssaudit",
			actions = slice_of(
				Command{argv = strs("cargo", "test", "--profile", "quick", "--locked", "--manifest-path", "native/Cargo.toml", "--target-dir", "build/native/target", "-p", "wren_media", "woff2"), env = strs(fmt.aprintf("PATH=%s;%s", here(NASM_DIR), os.get_env("PATH", context.allocator)))},
				tool_build("src/tools/cssaudit", exe("build/cssaudit")),
			), needs = COMMON_NEEDS, inputs = .Tree, limit = LONG_STEP_SECONDS})
	}
	// Last, and alone: closing the browser with every core saturated by busy loops, a video playing and a client connected, by wren ctl quit and by the window's close button, within 8 s and with no forced
	// exit. A background thread starved by the load that the close waits for made it take 10 to 25 s (src/tools/e2e/remote_close_load.odin); this step saturates the machine.
	if cfg.perf {
		e2e_step(&t, "remote control (performance, -Perf): the browser closes within 8 s with every core busy (src\\tools\\e2e\\remote_close_load.odin: quit with a client connected, and WM_CLOSE, a video playing)", "remote_close_load", {.Alone}, browser = true)
	} else {
		fmt.println("perf: skipped, run with -Perf (test_all -Perf, or WREN_PERF=1): remote control, the browser closes within 8 s with every core busy")
	}
	return t[:]
}

