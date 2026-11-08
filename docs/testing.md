# How the tests run, and how to go fast

`src/tools/test_all` runs every test of the project, step by step. It is an Odin program: the steps are a typed table (`steps.odin`), a run is one small state machine (`scheduler.odin`). This page says what it does with your time, how to
ask for less of it while you work, which tools tell you where the time goes, and how to write an end-to-end test.

Its first run on a checkout, and whenever you want it built again:

```
odin run src/tools/test_all -collection:wb=src -keep-executable -out:build/test_all.exe -- -Quick
```

After that `build\test_all.exe` (`build/test_all` on Linux) is the program: a compile less, and no second process waiting for it.

## The commands of a working day

| What you want | Command |
|---|---|
| Everything a commit should pass (nothing runs twice: see below) | `build\test_all.exe -Quick` |
| The same, every step really run | `build\test_all.exe -Quick -NoCache` |
| Only what depends on what you changed since master | `build\test_all.exe -Quick -Changed` |
| One step, or a family of them | `build\test_all.exe -Quick -Only "unit tests: (url\|http)$"` |
| What failed in the last run | `build\test_all.exe -Quick -Failed` |
| The names of the steps, and how many files each depends on | `build\test_all.exe -Quick -List` |
| Where the time of a run goes | `build\test_all.exe -Quick -Profile` |
| What the CI runs (with test262 and the sanitizer as jobs of their own) | `build\test_all.exe -CI -NoAsan` |
| The full run | `build\test_all.exe` |

A step that `-Only`, `-Failed` or `-Changed` chooses brings with it the steps that make what it needs (`build\e2e_test.exe`, the browser, the test server: `Step.needs` in the table). They all say at the end how many
steps they left out: they are for your loop, never instead of the CI's run.
## The end of a run

A run ends with the slowest steps (wall clock and CPU), then what matters:

```
steps: 2 FAIL, 1 FLAKY, 89 PASS, 20 CACHED; 5967 checks counted; 3 explicit skip(s); skipped by their marks: 0 for the CI, 2 without -Ui
where the time goes: 214 s of wall clock, 1650 s of steps (they overlap), 1890 s of CPU in 402 processes, 8.8 processors on average; of the 12 -Jobs slots, 61 % busy, 11 % free while a step waited for what it needs, 28 % free with nothing left to start
FAIL unit tests: httpcache
  log: S:\...\build\test_logs\unit_tests_httpcache.log
  again: build\test_all.exe -Quick -NoCache -Only "unit tests: httpcache"
  only the failed tests: add -define:ODIN_TEST_NAMES=httpcache.test_disk_damage to its odin test
  - httpcache.test_disk_damage   expected ...
```

The same is left in `build\`: `test_report.txt` (that text), `test_steps.tsv` (every step's status, seconds, CPU seconds, processes and number of checks: compare two of them to see that a change lost nothing), `test_failed.txt`
(what `-Failed` reads), `test_logs\` (the whole output of each step, passed or not: a process writes straight into its log), `test_all_times.txt` (durations, the order of the next run).

## What runs, in what order

The run happens on a Windows desktop of its own (`desktop_windows.odin`: the program runs itself again there): no step can take the focus, the mouse or the keyboard of the person at the machine, and their clicks reach no step. `-Ui`
stays on the real desktop, its steps need the real input.

Every step goes Blocked (what it needs is not made yet), Ready, Running (its actions one after the other), Done. One thread decides: at each tick, what has ended, what that unblocks, what may start; a step's processes write into its log, nothing reads
them, so nothing waits on a pipe. No step has the run's console: a test program has none, anything else a hidden one of its own (`tooling.Console_Use`). In a process with a console, the start and the end of every thread call the console's host while they hold the loader lock, and a graphics driver starts dozens of threads per device: with all of them on one host, a thread could take 15 s to end with every core busy. `-Jobs` steps run at a time (three per four processors, at most 12; two with `-CI`), the longest path first: a step's duration in the last run, or its `weight`, plus the longest chain of steps that wait for it. A step marked `.Light` mostly
waits and takes no slot, up to `-LightJobs` of them (4; 2 with `-CI`). A step whose maker failed says `NOT RUN` and takes no time. A test program's step gets `-tests:` from what its source file declares, read by `core:odin/parser`: one process, the test program itself. A step
that compiles and runs a package is that compile and that run; a check on files (`lint_globals.odin`, `lint_test_inits.odin`, `lint_unicode_case.odin`, the process allocators, the JavaScript engine's stamp) runs on a thread of `test_all` and costs no process at all.

Odin builds the `*_test.odin` files of a package into every program that imports it: an `@(init)`, an `@(fini)` or a package-level initialiser that calls something there runs at each start of `wren.exe`. What a test needs is made inside the test (a `sync.Once` when several share it); `lint_test_inits.odin` fails on the others, in `src` and `ext\gui_toolkit`.

The web platform's names and keywords are ASCII case-insensitive (tag and attribute names, CSS keywords, MIME types, header names, URL schemes, encoding labels): `base.ascii_lower`, `ascii_equal_fold`, `ascii_has_prefix_fold`, `ascii_contains_fold`... (`src\base\text.odin`). `strings.to_lower`, `to_upper`, `equal_fold` and `unicode.to_lower`, `to_upper` fold by Unicode (the Kelvin sign U+212A is `k` to them, the long s U+017F `s`): `lint_unicode_case.odin` fails on a call of them in `src` (not `src\tools`) or `native` that `tools\unicode_case_allowed.txt` does not list with why (user text such as the address bar's search, `text-transform`, Windows paths), and on an entry that matches no line.

Every minute a run says which steps are running and for how long, on the console and in `build\test_report.txt` (which the report replaces at the end): a long step never looks hung. No test reaches past this machine: every step inherits `WREN_NETWORK_LOOPBACK_ONLY=1` (the browser's `network.loopback_only`), so a connection to anything but loopback and the test server's names fails at once, named in the step's log; `wrentool smoke` and `crash-e2e` set it too.

A step has a limit (`-StepTimeoutSec`, 900 s; hours for what is legitimately long). Past it, what its threads are doing goes to its log (the code of `wren ctl stacks`), its whole process tree is killed (on Windows a step is a job object, on Linux a process group) and the report says `stuck`. Nothing
of a step outlives it. A test that talks to the test server starts it in its own process, on a block of ports of its own ([below](#the-test-server)), so several worktrees test side by side. `-Perf` and `-Ui` add the steps that depend on the machine's speed or on a desktop
([CONTRIBUTING](../CONTRIBUTING.md)); a full run adds the check build, the AddressSanitizer unit tests (one step per package, three at a time), the whole of WPT and test262, the network stress.

On Linux `build/test_all` (`odin run src/tools/test_all -collection:wb=src -out:build/test_all -keep-executable`) runs `odin check` for every portable package and their unit tests (`steps_linux.odin`, [portability](portability.md)).
## The result cache

With `-Quick` on a developer's machine, a step that has passed with exactly the same inputs says `CACHED` and does not run again (`src\tools\test_all\cache.odin`, results in `build\test_cache\`). That is what makes the second run of the day short:
a change in `src/url` reruns the packages that import `url`, and the steps that use the browser.

**A result is found by content, never by time.** Its key is the hash of:

- the version Odin says it is, the run's flags (`-Quick`, `-CI`, `-Ui`, the time factor), the step's name, its commands with their flags;
- for a step that compiles and runs Odin packages (`Input_Kind.Packages`): every file of those packages and of everything they import (`wb:`, `toolkit:`, `web:`, relative imports, parsed from the sources, for every build tag), what they `#load`, the libraries they
  link, the paths written in their strings (`"examples/site/images/%s"`: what a test reads while it runs), `examples\`, `assets\`, `api\`, `sdk\`, the test server, the native libraries, and what every step inherits (`src\tools\test_all\env.odin`);
- for a step that runs a script or the browser (`.Tree`): the whole tree (`src`, `ext\gui_toolkit`, `tools`, `wpt`, `native`, `api`, `sdk`, `examples`, `assets`, `build.bat`, `odin.version`, the libraries), tests of packages aside;
- for what is about the documentation or the changelog, what generates files, the licence Worker (`.Everything`): all of that and `docs`, `site`, `changelog.d`, `licence`.

What cannot be resolved (an unknown collection, an import that names no folder) takes the whole tree: an input too many costs a rerun, one too few could hide a failure. The tests of `src/tools/test_all`, themselves a step, compare the packages found with the compiler's
own import graph (`-show-import-graph`) and check that a change of each kind of input changes a key, and that a change of something else does not.

A file is read once in a run, unless its stamp moves (one walk of the tree between two steps, whatever the number of keys); a full cache costs a second.
Only a pass is kept, and only if the key computed when the step has ended is the one it started with: a file edited during
the step leaves no result. A result of a step that built a program stands only while that program is on the disk as the step
left it. A result lasts 7 days: what no file says (a certificate that expires, a date) gets its chance.

What a cache cannot see: a test that passes one time in two has passed. That is the price, and why:

- **the CI never takes a result on master** (a pull request does: `.github/workflows/ci.yml`, by that pull request's earlier runs);
- a full run, `-Perf` and `-NoCache` take none; `WREN_TEST_CACHE=0` is `-NoCache` for a whole session.

## The shared code of test processes

The JavaScript engine's image compiles in 5 s of CPU, once in each process, and a run starts hundreds of them, each
without a profile or with a throwaway one. `src\tools\test_all\env.odin` sets `WREN_TEST_WASM_CACHE` to `build\wasm_cache`: all
the test processes then read the disk cache of the engine (`src/wasm/module_cache.odin`: keyed by the image and the
engine's configuration, authenticated), 0.2 s of CPU instead of 5. The tests of that cache itself (`wasm.disk_cache`) keep
their own. A release ignores the variable. `-NoCache` turns this off too.

`build\e2e_test.exe` does not depend on that cache for the image: it has the machine code in it, as `wren.exe` has (`WREN_SHIPPED_CODE`, `src/js/image/code`). With `WREN_POISON_PAGES=1` a compile of the image is five minutes on a quiet machine, a system call for each of its blocks, three times that is the 15 minutes of a step; the cache is cold after every change of the engine and with `-NoCache`. `jsweb_engine_code_of_the_program` fails if that code stops fitting.

## WPT

A run of WPT spent 58 % of its time on tests that time out (1300 of 8800, 50 of them for 60 s): a test expected to time out
waits for what will not come, and the page of a test that can do nothing more is given a second to prove it.

`src/tools/wpt` is the whole of a run: it fetches the pinned checkout and verifies it, starts the test server in its own process, runs the tests, compares them with `wpt\expectations`, gives what regressed its second chance. `build\wpt.exe -quick`, `-only <prefix>`, `-update`, `-reftests`, `-fetch`, `-update-manifest` (top of `src/tools/wpt/main.odin`). test_all's step builds it; by hand `odin build src/tools/wpt -collection:wb=src -vet -o:speed -use-separate-modules -out:build/wpt.exe`. `src/tools/test262` is the same for test262: `build\test262.exe [-quick] [-update] [-jit ...]`.

With `-quick`, and `-fast-timeouts` for a whole run:

- a test the expectations say times out gets 3 s (`-timeout-cap`), a page that can do nothing more 300 ms (`-idle`);
- all that fails then goes through the second chance: run again together, without either, with 4 times the limit and the
  engine's limit on one script out of the way, and what still fails alone. Only a test that regresses there counts.

In every run but `-update` (and `-no-history-limits`), a test with a time in `build\wpt\times.txt` gets 4 times that time, at least 2 s
(`HISTORY_LIMIT_FACTOR`, `HISTORY_LIMIT_FLOOR_MS`), instead of its whole limit: a test that stops finishing no longer waits out 10 s. One
that runs out of it and regresses goes through the second chance with the whole limit (not counted against its most), and its time there
is written; one that runs out of it and regresses nothing keeps the time that gave the limit. A test with no time, or one that timed out
last time, has its whole limit.

The tests wait in one queue, the costliest first (`build\wpt\times.txt`, each test's time in the last run; else its whole limit for a test expected to time out), and a child process takes the next one on its standard input as it ends one (`src/tools/wpt/queue.odin`, at most `-chunk` per child): a folder of slow tests is spread over every child instead of leaving one alone at the end. A child runs its pages on a thread it makes with the stack JavaScript needs (no linker flag to remember); a child whose JavaScript cannot start stops the run at once with its reason. Every 30 s the runner says on its standard output how many tests are done and how many regressed so far.

A test is loaded by its type, as the browser loads it: an `.xhtml` test is an XML document (UTF-8 unless it says otherwise), not HTML.

The pages see wptserve's names: `web-platform.test` (`{{host}}`), `www1.web-platform.test`..., `not-web-platform.test`, all on this machine. The browser resolves them itself (`network.hosts`), never the system or a hosts file, trusts the test server's authority for its https origin (`network.tls.extra_ca_file`, `build\wpt\testca.pem`), loads a `.https.` test over https, and connects to nothing else (`network.loopback_only`).

A test whose expectation is TIMEOUT is not run (`build\wpt\skipped_timeouts.txt`, counted in the report; `-timeouts` runs them, `-update` always does), and a long test (`<meta name=timeout content=long>`) gets 3 times `-timeout` at most (`LONG_TIMEOUT_FACTOR`): the time of a full run went to tests waiting for what never came.

So a shorter limit can cost a rerun, not hide a regression. What it does not see is a test that has **begun** to pass: a
whole run without it does, and `-update` (which refuses the cap) records it. `-only` keeps the whole limits too: someone is
looking at that test. `-no-fast-timeouts` turns it off under `-quick`.

## Writing an end-to-end test

There is one test program, `src/tools/e2e`, built once as `build\e2e_test.exe`, with every allocation tracked (`-define:WREN_TRACK_MEMORY=true`; what that costs a step does not show: 515 s of CPU against 499 for all the scenarios); a step of `test_all` runs the tests of one of its files, with `-tests:`, in a process of its own.

An end-to-end test is an Odin `@(test)` procedure of it, on Odin's own test runner. It calls the browser directly: the program
links package `browser`, the browser runs in the test's thread and process, and a barrier runs its loop, turn by turn, until what it waits for
holds. There is no window of the system, no channel, no JSON, no other thread to wait for: the frames are the real renderer's, offscreen, made as
fast as they are asked for, and nothing can take the focus, the mouse or the keyboard of whoever is at the machine.

```odin
package e2e_scenarios

import "core:testing"
import "wb:e2e"

@(test)
the_title_shows :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = {1280, 800}})
	e2e.navigate(s, e2e.url(server, "/site/about.html"))   // returns once loaded
	testing.expect_value(t, e2e.eval(s, "document.title"), "About")
	e2e.key(s, "Ctrl+L")
	e2e.type_text(s, "hello")
	e2e.wait_js(s, "document.readyState == 'complete'")
	c := e2e.pixel(e2e.capture(s, {target = .Page}), 10, 10)   // the next frame's pixels
	testing.expect(t, c.a == 255)
}
```

The rules:

- **One file per subject**, `src/tools/e2e/<name>.odin`, with its checks kept as they mean. A file's tests are one step of `test_all`: `e2e_step(&t, "...", "<name>", weight = 10)` in `src/tools/test_all/steps.odin`, with its marks if it has any (`.Ui_Only`, `.Light`, `browser = true`). The step runs the tests the file declares.
- **An action that fails ends the test there**, saying where it was called from, what failed and the folder of what it left (`build/e2e/<test>/`: `failure.png`, `failure_console.txt`, the test's own `e2e.shot`s, kept only when it failed). So a scenario checks no return. Checks are `testing.expect*`: they go on.
- **Barriers, never sleeps.** `wait_load`, `wait_frames(s, n)`, `wait_selector`, `wait_js(s, condition)`, `wait_chrome_still` (the interface's animations have ended), `wait_until(s, ready_proc, "what")` and `wait_until(s, data, ready_proc, "what")`. Each has `deadline := DEFAULT_DEADLINE`, which only ends a failing run. Wait for the state itself, not for a number of frames: `wait_frames` is for what is done within a frame or two by construction.
- **The browser's animations go by frames** (`control_begin`: each frame is one of the usual length for them, however fast it is made), so a 500 ms animation is 30 frames. What a page does on a real timer is still real time: the preference that shortens it (`forms.caret.blink_ms`) rather than a wait for it.
- **Something the browser does not let you see or do**: add it to the browser, not to the test. A typed procedure in `src/browser/control.odin`, which the remote method calls too: a handler `m_*` only decodes its request's JSON, calls that procedure and encodes what it gives. A field of `api.Stats`, filled by `control_stats` (what a poll reads) or `control_stats_all` (what takes a look at the process or a walk of a store: `Wren.stats`, `e2e.stats_all`). Then the wrapper in `src/e2e/e2e.odin`.
- **One browser at a time in a process** (the browser's state is the process's), and `e2e.start` ends with the test, as do its profile (`e2e.temp_profile(t)` for one that `e2e.restart` must find again), `e2e.temp_folder(t)` and `e2e.test_server(t)`. The tests of one run go one after the other (`ODIN_TEST_THREADS=1`); `test_all` runs one process per file, side by side.
- **Only what is about a process starts one**: a launch, an exit code, a crash, a second start, the console launcher, the channel itself. `e2e.launch(t, {...})` gives a Wren of its own, over the channel, with the typed client `wb:remote/api` (`api.navigate(p.s, url)`), `e2e.quit(p)` its exit code, `e2e.kill(p)` a crash. It is headless too unless `hidden = true`; `start` holds its environment, its folder, its outputs. Any other program is `e2e.program` (`e2e.run` to its end: its exit code and what it printed). What another process does to the disk is waited for with `e2e.wait_file`, `e2e.wait_gone`, `e2e.wait_for`. A hidden window needs a desktop nobody uses: `test_all`'s, or by hand `wrentool desktop -Command "..."`.
- **What shows only without a GPU runs on the system's software rasterizer, on any machine**: `e2e.start(t, {software = true})` (WARP): a frame takes 15 to 22 ms to draw there and 0.1 ms on a GPU, as on a runner that has none.
- **What is about the window of the system runs on a real one, never shown**: `e2e.start(t, {hidden = true})`, in the test's process, so that the window procedure is called on the test's thread as the system calls it. `src/tools/e2e/real_window.odin` is that core (WM_DPICHANGED, WM_NCHITTEST, WM_SETCURSOR, the z-order for a drop, the swap chain), `frame_gate.odin` and `devtools_resize.odin` use it too; `e2e.launch(t, {hidden = true})` when something else must read it from outside (`a11y_uia.odin`). It needs a desktop session: `test_all`'s own, `wrentool desktop -Command "build\e2e_test.exe -tests:name"` by hand. What needs a paint or the system's frame goes through `show_unseen` (`window_native.odin`): shown where nobody sees nor touches it.

- **What the browser does left alone**: a barrier and a poll ask for frames. `e2e.rest_turns(s, n)` turns the loop with nothing asking, a timer that draws nothing waking it each time; `e2e.wait_at_rest(s)` until it stops drawing by itself, `s.app.rates` and `e2e.stats(s).loop` count what it did and say who asked (`frames_at_rest.odin`: none on a static page).

- **Nothing left allocated**: every allocation of the process goes through the tracker of `base`. When a test's browser has ended and the test has let go of what it holds, whatever is still allocated, or was freed twice, is listed and fails the test (`end_of_test`).

Running them by hand: `build\e2e_test.exe -tests:the_title_shows` (no window opens, no other desktop is needed, except for a scenario with `hidden = true`), or `build\test_all.exe -Quick -NoCache -Only "src.tools.e2e"`. `WREN_E2E_TRACE=1` prints every call with its time, `WREN_PHASES=1` the phases of a start and an end of the browser (a real `wren.exe` says them too). A teardown that hangs ends the process after 10 s (`host.shutdown_watchdog`); what its threads were doing is on its standard error first, so in the step's log: `build\e2e_test.exe` answers `ctl stacks <pid> --out <file>` as a `wren.exe` does.

Two things `core:testing` does not give: a test stopped by a signal (`testing.fail_now`, a panic) can happen once per run on Windows, the runner lets go of a lock it does not hold, and the next signal waits for ever; `e2e` stops its tests through a limit of 0 instead (hence the "Test timed out" after a failure's message). And checks that pass say nothing: `test_all` counts tests here, not checks. A test that runs out of its limit has its thread terminated where it stands, and nothing of what that thread started is told: when that thread was compiling, rayon's workers go on with the jobs on its stack, gone, and fall on them with an access violation. That crash follows a "Test timed out" and says nothing of the code it stands in; what ran out of time does.

## Testing the interface with no browser around it

What a test of the interface (the tabs, the address bar's list, a menu, the zoom, a docked panel) needs of a browser is the chrome's own code: it starts none. `chrome_start` (`src/tools/e2e/chrome_world.odin`) makes an App of its preferences, its fonts, an offscreen window and tabs with no page, and each frame runs the real `build_ui` under the toolkit's session (`toolkit:testkit/session`), with no network, no script engine, no profile and no renderer unless the test asks for pixels. A test takes 7 to 40 ms, 1 s when it has pixels (the software rasterizer's start).

```odin
@(test)
chrome_sidebar_pinned_tabs :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {"Alpha", "Bravo"}, prefs = {"browser.tabs.position=left"}})
	chrome_still(w)                                // nothing moves any more
	chrome_select(w, "Bravo")
	chrome_command(w, "tab.pin")                   // a command of the interface, by name
	session.drag(w.s, from, to)                    // the session's input, barriers and pixels
	testing.expect_value(t, w.wnd.tabs[0].title, "Bravo")
}
```

What stays with `e2e.start`: what needs a page (a load, a script, what the page is told), a profile, a real window or a process. A subsystem the interface reads that the world has not made (`chrome_start`'s list of `*_init`) shows as a crash in the first frame that reads it: add it there, as the browser's start does.

## Writing a test that is quick

The rules are in [CONTRIBUTING](../CONTRIBUTING.md): wait for a condition, with a limit that only ends a failing run (the barriers above, `wren
ctl wait` for a script), one shared Wren between scenarios. And check what a wait returns:
a tool that waited for a line nobody logs spent its 120 s limit in every run, and passed.

## Virtual time

`host.Loop` reads its time through `host.now_ns`. A test gives the loop a `host.Virtual_Clock` (`clock_virtual`) and moves it:
`clock_advance(&loop, d)` runs at once what falls due on the way, each timer at its own deadline; `clock_move` only moves it, as a
stalled machine would. `loop_wait` on such a clock does not wait for a timer. Production pays one test of a pointer.

The chrome frames made while a script holds the page (`e2e.while_busy`, `src/browser/busy_input.odin`) have a clock of the test's
too: after a step `e2e.busy_clock(ms)`, and until the steps run out, they show the page's animations `ms` after the page's last
frame (`page.animations_wall_ms`), however long the frames took to come. What a picture shows is then a value at a known time:
`a_colour_and_what_inherits_it_go_on_under_a_task` (`src/tools/e2e/scroll_driven.odin`) reads the animation's `currentTime` as
the task begins and checks the colour of two pictures, 2 s and 6 s later, to a level. `busy_wait(ms)` stays for what a real
timer decides (a caret's blink, an autoscroll's pace).

A test does not sleep to wait for another thread: it waits on the state (a semaphore, a completion posted to the loop,
`base.await` when the code under test has no signal). The few real sleeps left in unit tests measure the real clock, and say so.

A test **simulates** a failure, it does not wait for it. In this order: a fake at a seam (a reader that holds a file open and lets go, a count of what was asked), the loop's virtual clock, a clock moved on both sides (`httpcache.clock_ahead_s` and the test server's `/cache/clock`), a condition or a gate of the test server (`?gate=K` holds an answer until the test calls `e2e.open_gate(server, K)`: a slow response whose end the test decides, `tools/testserver/gate.go`). A real wait stays only where a real client's or the system's timer is what is measured. `tools/test_sleeps_allowed.txt` lists the sleeps left in test sources, with why; `src/tools/test_all/lint_sleeps.odin` fails on any other.

No passing test depends on the speed of the machine: a barrier has one limit, `e2e.DEFAULT_DEADLINE` (`DEFAULT_WAIT` in the web tests), under the test's own, and it only ends a failing run. Do not add a longer one for a slow runner, and do not add a preference or a variable that only shortens a timeout for a test.

## The web tests

Everything under the browser's window (fetch, the network stacks, the HTTP cache, the content blocker, pages and their scripts, Wasm guests, workers, images, forms, frames: no shell, no frame) is tested by the same program: the files `src/tools/e2e/web_<subject>.odin`, which never start the browser the program links. One file per subject (`web_cache.odin`, `web_frames.odin`, `web_jsweb.odin`...), `#+private file` with its own helpers, its tests named after it (`cache_freshness`); what they share is `web_harness.odin`. A step's result depends on those two files and what they import, not on the browser (`Step.sources`).

```odin
#+private file
package e2e_scenarios

import "core:testing"
import "wb:base"

@(test)
history_scroll_restoration :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()   // (what the Wasm imports make and free)
	begin(t)                                       // the world, as far as .Net or .Pages
	defer end()
	serve(t)                                       // only when it talks to the test server
	pr := open_page(t, "scroll", PAGE, "http://127.0.0.1:8765/a.html")
	wait_note(pr, "loaded")                        // the page said wrenTest.note('loaded')
	run(pr, `wrenTest.check(history.scrollRestoration === 'auto', 'it starts auto')`)
	close_page(pr, min_checks = 1)                 // fewer checks than this fails the test
}
```

The rules, besides those of the [end-to-end tests](#writing-an-end-to-end-test):

- **One world, one test at a time** (`-define:ODIN_TEST_THREADS=1`): what the process keeps (the image cache, the stores, the timeline) binds to the first loop it sees, so a loop per test would leave it on a dead one. `begin` makes the world as far as the test asks; the last test, `zz_the_process_ends_with_nothing_left`, undoes it all and fails on anything still allocated.
- **A step of `test_all` is a subject in a process of its own**: `web_step(&t, "...", "cache", {.Light})` in `src/tools/test_all/steps.odin`, with its marks. By hand: `build\e2e_test.exe -tests:cache_freshness,zz_the_process_ends_with_nothing_left`, on a desktop nobody uses (`build\wrentool desktop build\e2e_test.exe -tests:cache_freshness`). This world and a browser in the process do not go together: name what you run.
- **No result is read from the console.** A page's script talks to its test through the functions of `wrenTest` (`api/testhost.widl`, `native/js/odin/test_host.odin`, `src/page/test_host.odin`, `src/tools/testhost`), which exists only in a page given a test host: `testBegin`, `testEnd`, `check`, `measure`, `note`, `signal`, `skip`, `done`. What is uncaught fails the page unless the test expects it (`pr.expect_uncaught`).
- **A page declares what it runs.** `close_page` (`testhost.finish`) fails a section that ran another number of tests than it declares (`tests = 8`), or none, or fewer checks than it declares (`min_checks`), a section whose script never said `done()` when it is the one to end, a test that checked nothing, and a `skip("webgl-adapter" | "av1-decoder", why)` that the program does not find true of the machine: it makes a context of its own for the first (only "no graphics adapter" from the GPU process counts as none), asks the media backend for the second. A true skip prints `SKIP [section] ...`, is counted, and `test_all` lists it at the end of a run.
- **Barriers, not time.** `wait_until(t, what, data, ready)`, `wait_note`, `wait_done` run the loop until a state holds. What a loop's timer does or must not do yet goes by `virtual_clock(t)` and `host.clock_advance` (a page's `setTimeout` follows it). Only what a real clock on the other side decides (the `Date` of an HTTP answer) waits for that exact condition in real time.

## The test server

`tools/testserver` is a Go package (Go's HTTP/2, quic-go's HTTP/3, TLS). It is a library first:

- `build\testserver.dll` (`go build -buildmode=c-shared` of `tools/testserver/cdll`, which needs a C compiler for Go's cgo), loaded by `src/testserver`. An Odin test calls `e2e.test_server(t)`, or `serve(t)` in the web tests: it listens when that returns, with its base port, on the threads of Go's runtime in the test's own process. No process to start or to stop, no file to read: it goes with the process. One per process; each call forgets what the handlers counted, as a new server would.
- `build\testserver.exe` (`tools/testserver/cmd/testserver`), a thin main over the same package, for what is not Odin (it writes its base port to `-port-file` once it listens; Odin programs start the same server in process with `wb:testserver` `testserver.start()`), `test_all`'s network stress, `demo.bat` and the release's extras. `src/tools/wpt` and `src/tools/endurance` use the library, in their own process.

Every origin is an offset from the base port (`tools/testserver/ports.go`): +0 http on 127.0.0.1 and localhost, +1 https, +2 a second http origin (and, for the WPT names, the web-platform-tests origin's second http port: `{{ports[http][1]}}`), +3 and +4 the web-platform-tests origin, +5 to +9 the transports. A block is free or taken as a whole; a test takes the next free one from a port derived from the worktree's path. A test writes the default ports (`testenv.url("http://127.0.0.1:8765/x")`) and they move with the block, in the text files of `/site/` too.

### The demo pages under a name, with no port (portless)

Wren resolves a name under `.localhost` (`wren.localhost`, `a.b.localhost`) to the loopback itself, as Chrome and Firefox do (RFC 6761; the system's resolver may not: Windows answers "host unknown"). That makes [portless](https://portless.sh) (`npm install -g portless`, Node 24) usable for the demo pages: it is a proxy that gives a server a name instead of a port.

```bat
build\testserver.exe -site examples\site -scan -base-port 18765 -port-file build\testserver_wren.port
portless proxy start --no-tls          & plain http on port 80 (without --no-tls: https on 443, which needs openssl for its certificate)
portless alias wren 18765              & http://wren.localhost/site/grid.html
build\wrentool shots -Site http://wren.localhost/site/ -Only css-grid
```

`-Site` makes the `site:` pages of `wrentool shots` and `wrentool capture` come from that address, so the address bar of a screenshot says `wren.localhost/site/grid.html` and not the path of a checkout. The names of `.localhost` only reach this computer. The default stays the files of `examples\site`.

## Freed memory made loud

A read of freed memory is silent on Windows: the heap and the arenas hand the same addresses out again, the bytes stay readable. `-define:WREN_POISON_MEMORY=true` makes it loud (`src/base/poison.odin`). `build.bat check` (`build\wren_check.exe`), `./build.sh wren-check` and `build\e2e_test.exe` have it; a normal build has nothing of it: `base.Arena` and its calls are then `core:mem/virtual`'s own names.

- **Every block freed** is filled with `0xDD` and stays out of the heap (the quarantine: 1 GiB or a million blocks, oldest out first). A pointer read from it is not canonical: the read through it faults at once, and the crash report says `reading address 0xFFFFFFFFFFFFFFFF (not canonical: a pointer read from freed memory)`. A block that grows always moves, so a pointer into a dynamic array kept across an `append` sees the same.
- **The C heap** of the whole program goes through it: on Windows `HeapFree` and `HeapReAlloc` are replaced in the import table of the executable (the Odin runtime, the Rust library, Lexbor, the static C runtime; the system's DLLs keep their own), on Linux `free` and `realloc` are the executable's own symbols, in front of glibc's. It starts in a second, where AddressSanitizer stalls for a minute in the Direct3D device.
- **Arenas**: `base.Arena` takes its chunks from the heap: `arena_free_all`, `arena_destroy`, a rolled back `arena_temp_end`, `free_all(context.temp_allocator)` of a `base.process_context()`, `base.scope_close`, a style arena emptied or recycled send their memory through the quarantine, and the next pass has other addresses. A removed `base.Pool` slot is poison too.
- **Fatal at once**, with a crash report (`memory: fatal: ...` on the standard error): a double free, a free or a resize of what the heap does not know, and a write to a block in quarantine, seen when it leaves or at `base.mem_report`. `WREN_MEMTRACK_STACK=1` adds the stack of the free.

It does not see the system's DLLs, the pools inside Lexbor, the toolkit's own arenas (`ui`, `font`, `dbus`), Wasm linear memories, or a read of a plain number from a freed block (it gets `0xDD...`, wrong but not fatal; a write to it is seen).

**`WREN_POISON_PAGES=1`** (Windows, the same builds) sees those too: every block of the executable's heap has pages of its own, taken away when it is freed and never given out again, what the system's PageHeap does without its key in `HKLM\...\Image File Execution Options`. Any read or write of a freed block, or of an arena that was emptied, faults at that instruction with the block's address in the crash report. It costs a system call per allocation and a page per block: the pages of `tools/sweep_local.txt` take a minute and a half instead of one and a quarter.

```
build.bat check
build\wrentool sweep -List tools\site_compare_list.txt,tools\site_compare_list2.txt -Exe build\wren_check.exe -CloseMs 60000 -PingMs 60000
```

`test_all` has it in every end-to-end test, in the unit tests of `base`, `style` and `layout`, in the crash reports (`crashmodes_poison`), `WREN_POISON_PAGES=1` for the tests that found something only with it, and `-CI` and full runs visit the pages of `tools/sweep_local.txt` on the check build (a minute, no network; a line of a list that is no address is a file of the repository). So does the Linux job of the CI.

## The replay bench

`wrentool waterfall` loads public sites: a request changes with the ads, a run with the network, and two arms of one binary differ by 5 %. `wrentool replay` loads what a site served once, so that a change of 1 to 5 % can be told from nothing ([round 51](performance.md#round-56-a-replay-bench-and-what-it-can-prove)).

```
build\wrentool desktop build\wrentool.exe replay record -Urls https://www.cnn.com/,https://www.npr.org/
build\wrentool desktop build\wrentool.exe replay lists
build\wrentool desktop build\wrentool.exe replay run -Sites https://www.cnn.com/,https://www.npr.org/ -Arms base=build\wren_base.exe,new=build\wren.exe -Runs 7 -Out build\replay\new.tsv
```

**Record** starts a Wren on a throwaway profile with `WREN_TEST_RECORD=<folder>` (`src/net/record.odin`): each answer that comes to its end is one `<number>.http` in `build/replay/<site>/`: method, URL, the head as the host got it, the decoded body. The content blocker is off, so that a recording holds all a page asks for, and it goes on for 10 s after the thread settles. A recording holds third-party content and the cookies a site set: `build/` stays out of git, and nothing of it goes anywhere else. A request cut short, a failure and a WebSocket leave nothing.

**Run** serves those bytes from `tools/testserver/replay.go`, in wrentool's process (`testserver.replay_start`), with no latency of its own. The n-th ask of a method and URL gets the n-th answer, then the last again; a URL never recorded gets the first answer of its method and path, whatever the query; anything else a 404 with nothing in it, counted in `unknown` and listed in `build/replay/out/missed_<site>.txt`.

Nothing of the machine is touched. `network.hosts=*=127.0.0.1:<port>` sends every connection to that one port, whatever its name and port (the first byte says TLS or plain http), the test authority signs a certificate for each name as it comes (`network.tls.extra_ca_file`), and `network.loopback_only` keeps a load on the machine. HTTP/3 is off, so a page recorded over it replays over HTTP/2.

**The test world** (`src/base/test_world.odin`). `WREN_TEST_WORLD=<seed>,<unix ms>`, the same at the recording and at each replay; a release never reads it. `Math.random`, `crypto.getRandomValues` and `randomUUID` come from a seeded stream of the thread. `Date`, `performance.now`, `timeOrigin` and a frame's time read a clock that starts at the recording's date and moves by 2 ms at each read of that thread (about the pace of real time on these pages), so that a page's timestamps depend on what it did and not on how fast the machine ran, and a `while (Date.now() < end)` still ends. The cookies and the HTTP cache go by the recording's date plus the real time since the start: what was fresh then stays fresh, however long ago that was. The page's timers, the loop, the network and the compile threads stay real: that is what is left of the noise.

**The release's code on the bench**: `wrentool build bench` (`build\wren_bench.exe`) is the release's build (one module, `-o:speed`, no `-debug`, the Rust library's `release` profile) on the development channel, which keeps the hooks a release leaves out (`WREN_TEST_WORLD`, `WREN_TEST_RECORD`). `WREN_ODIN_EXTRA` cannot do it: Odin refuses a second `-define:WREN_CHANNEL`. A release replays a recording with the machine's clock and random: two of its loads are not the same work.

A run is two loads in two Wrens for each arm and each run, one warm-up first, the arms' order turning:

- the load that is **measured**: nothing watches it but a thread of wrentool that reads the window thread's cycle counter every few ms (`QueryThreadCycleTime`, from outside, nothing asked of the browser);
- the same load with its **frames** kept (`Wren.timeline`, the page's rectangle at an eighth of its size), up to the moment the first one settled. Apart, because the copy of a frame costs the window thread about a ms: on a page that draws all the time that alone keeps the thread from looking idle.

What a load says, in `<Out>` (one line a load) and `<Out>.summary.txt`; the rules are the constants of `src/tools/wrentool/measure/measure.odin`:

| | | |
|---|---|---|
| **visually ready** | `ready` | The first frame from which the first viewport stays within 0.5 % of its last picture, cell by cell (a cell: a pixel of the frame scaled to an eighth; it differs when a channel moves by more than 16). Against the last picture, not the frame before: a slow fade is many small steps. A cell that changes 3 times or more after the load event, 300 ms apart at least, is a carousel, a video or a ticker: it is left out (`moving`: their share). |
| **settled** | `settled` | The first moment after the load event from which the window thread stays idle for 500 ms: at most 25 % of that time on a processor. Not zero: cnn.com and theverge.com keep the thread 15 to 20 % busy for as long as they stay open. 0: not within 20 s. |
| **CPU to settled** | `cpu_settled` | What the window thread spent from the navigation to settled, by its cycle counter (not the system's times, which move by 15.6 ms). |
| first contentful paint | `fcp` | Beside visually ready. |
| load, DOMContentLoaded | `load`, `dcl` | Secondary: an event is where a page's authors put it. |
| CPU, `Guest` to the load event | `cpu_load`, `guest` | The window thread from the first request to the load event, and its time in the engine. |
| what was asked | `requests`, `failed`, `exact`, `near`, `unknown` | A load that left its recording shows here. |

**What counts as a gain** (`measure.verdict`): visually ready or settled comes sooner, with the ranges of the two arms apart, and CPU to settled does not get worse. A mark that comes sooner with more CPU says `Moved`: work put past an event is no gain. The noise floor of each metric is in [round 51](performance.md#round-56-a-replay-bench-and-what-it-can-prove): below it, a series of 7 says nothing.

No tool holds a lock, and agents share this machine: a load starts when at most a fifth of the processors are at work, and one during which the rest of the machine took more than 35 % of it (the background of a shared machine, the browser's own helper processes) is said, dropped and made again (`others`: their share). `-Loaded` measures all the same, for a machine that does not go quiet; its floor says so. `wrentool desktop` ends a command after 30 minutes: a long series goes site by site.

**The filter lists are on by default** ([round 57](performance.md#what-changed-round-57-the-filter-lists-at-start-up)): what a user runs. `wrentool replay lists` fetches and compiles the ten lists on by default, as a user has them some seconds after a first start, into `build/replay/lists` (once; `run` says so when the folder is missing). Before its loads each arm starts once on a copy of the folder and loads the site, so that the profile holds the index its own build compiled (a folder made by another build would be compiled again at each start: another format), and every load copies that profile with the times of its files, as a user's stays. `-Lists folder` takes another folder, `-ListArms x,y` gives the lists to those arms only, `-NoLists` to none (the built-in list). `-Second` measures the second load of each Wren: the site once, then `about:blank`, then the load measured, with what a start costs behind it and the HTTP cache holding the site.

## Tools beside the tests

Anything with a window runs on the desktop of its own that `src/tools/test_all` makes, or through `build\wrentool desktop <program> [arguments]`; no tool takes the person's focus or holds a lock. `build\wrentool help` lists the other commands, by family: deps (`fetch`, `build`, `symbols`, `crash-symbolize`), `bench` (opt-in measures: `perf`, `shell`, `js`, `idle`, `webgl`, `blocker`, `sidebar`, `startup`, `cadence`), `capture` / `shots` / `compare` (headless pictures, Wren against Edge), `gen` (generated data and fixtures), `docs`, and the release helpers (`package`, `sign`, `winget`, `notes`, `experimental`, `smoke`). A fresh checkout builds it with `odin build src/tools/wrentool -collection:wb=src -out:build/wrentool.exe`. Only `tools/make_logo.ps1` stays a script.

## Debugging the tests' time

- `build\test_all.exe -Quick -Profile`: every process of a run, by program, count, wall and CPU seconds, told by the job objects of the steps with nothing sampled; the use of the processors second by second, the run's and the rest of the machine's.
  `-ProfileCompare a b` compares two runs, `-ProfileReport a` says one again; `build\prof\<time>.processes.tsv` has each process and its command line. Read the CPU seconds when other runs share the machine: they barely move, the wall clock does.
- `build\test_steps.tsv` and the `where the time goes` line of any run: each step's CPU and processes; the slots busy, free for a step that waits, free for lack of work.
- `wren ctl wait load|idle|stable|quiet|selector|function|frames`, `wren ctl stats`, `wren ctl reset`, `wren ctl checkpoint`:
  [Remote control](remote.md).
- A step that fails under load and passes alone is marked `.Flaky`: it says what failed, and fails nothing.
