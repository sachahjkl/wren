# How the tests run, and how to go fast

`tools\test_all.ps1` runs every test of the project, step by step. This page says what it does with your time, how to
ask for less of it while you work, which tools tell you where the time goes, and how to write an end-to-end test.

## The commands of a working day

| What you want | Command |
|---|---|
| Everything a commit should pass (nothing runs twice: see below) | `tools\test_all.ps1 -Quick` |
| The same, every step really run | `tools\test_all.ps1 -Quick -NoCache` |
| Only what depends on what you changed since master | `tools\test_all.ps1 -Quick -Changed` |
| One step, or a family of them | `tools\test_all.ps1 -Quick -Only 'unit tests: (url\|http)$'` |
| What failed in the last run | `tools\test_all.ps1 -Quick -Failed` |
| The names of the steps, and how many files each depends on | `tools\test_all.ps1 -Quick -List` |
| Where the time of a run goes | `tools\test_all.ps1 -Quick -Profile` |
| What the CI runs (with test262 as a job of its own, and `tools\asan.ps1`) | `tools\test_all.ps1 -CI -NoAsan` |
| The full run | `tools\test_all.ps1` |

Run them with `powershell -NoProfile -File`. A step that `-Only`, `-Failed` or `-Changed` chooses brings with it the
steps that build what it uses (`build\web_test.exe`, `build\e2e.wasm`). They all say at the end how many steps they
left out: they are for your loop, never instead of the CI's run.

## The end of a run

A run ends with the slowest steps, how many Wren processes the scripts started, how long they spent in
fixed waits (`Start-Sleep`, by script), and then what matters:

```
steps: 2 FAIL, 1 FLAKY, 89 PASS, 20 CACHED; 5967 checks counted
FAIL unit tests: httpcache
  log: S:\...\build\test_logs\unit_tests_httpcache.log
  again: powershell -NoProfile -File tools\test_all.ps1 -Quick -NoCache -Only 'unit\ tests:\ httpcache'
  only the failed tests: add -define:ODIN_TEST_NAMES=httpcache.test_disk_damage to its odin test
  - httpcache.test_disk_damage   expected ...
```

The same is left in `build\`: `test_report.txt` (that text), `test_steps.tsv` (every step's status, seconds and number of
checks: compare two of them to see that a change lost nothing), `test_failed.txt` (what `-Failed` reads),
`test_logs\` (the whole output of each step that did not pass), `test_all_times.txt` (durations, the order of the next run).

## What runs, in what order

The run happens on a Windows desktop of its own (`tools/test_desktop.ps1`): no step can take the focus, the mouse or the keyboard of the
person at the machine, and their clicks reach no step. `-Ui` stays on the real desktop, its steps need the real input.

Every step is a process of its own; `-Jobs` of them run at a time (three per four processors, at most 12; two with `-CI`), longest
first by the durations of the last run. A step marked `-Light` mostly waits and takes no slot, up to `-LightJobs` of them (4; 2 with `-CI`).
A test that talks to the test server starts it in its own process, on a block of ports of its own ([below](#the-test-server)), so several worktrees test
side by side. What a step builds comes first (the steps named `build *`). `-Perf` and `-Ui` add the steps that depend on
the machine's speed or on a desktop ([CONTRIBUTING](../CONTRIBUTING.md)); a full run adds the check build, the
AddressSanitizer unit tests, the whole of WPT and test262, the network stress.

## The result cache

With `-Quick` on a developer's machine, a step that has passed with exactly the same inputs says `CACHED` and does not
run again (`tools\test_cache.ps1`, results in `build\test_cache\`). That is what makes the second run of the day short:
a change in `src/url` reruns the packages that import `url`, and the steps that use the browser.

**A result is found by content, never by time.** Its key is the SHA-256 of:

- the version Odin says it is, the run's flags (`-Quick`, `-CI`, `-Ui`, the time factor), the step's name and text, and the
  values of its variables (flags of the compile included);
- for a step that compiles and runs Odin packages: every file of those packages and of everything they import (`wb:`,
  `toolkit:`, `web:`, relative imports, parsed from the sources, for every build tag), what they `#load`, the libraries they
  link, the paths written in their strings (`"tools/build_js.ps1"`, `"examples/site/images/%s"`: what a test reads while it
  runs), `examples\`, `assets\`, `api\`, `sdk\`, the test server, the native libraries;
- for a step that runs a script or the browser: the whole tree (`src`, `ext\gui_toolkit`, `tools`, `wpt`, `native`, `api`,
  `sdk`, `examples`, `assets`, `build.bat`, `odin.version`, the libraries), tests of packages aside;
- for what is about the documentation or the changelog, what generates files (`odin run`), the licence Worker: all of that and
  `docs`, `site`, `changelog.d`, `licence`.

What cannot be resolved (a path with a variable in it, an unknown collection) takes the whole tree: an input too many
costs a rerun, one too few could hide a failure. `tools\test_cache_test.ps1`, itself a step, compares the packages found
with the compiler's own import graph (`-show-import-graph`) and checks that a change of each kind of input changes a key,
and that a change of something else does not.

Only a pass is kept, and only if the key computed when the step has ended is the one it started with: a file edited during
the step leaves no result. A result of a step that built a program stands only while that program is on the disk as the step
left it. A result lasts 7 days: what no file says (a certificate that expires, a date) gets its chance.

What a cache cannot see: a test that passes one time in two has passed. That is the price, and why:

- **the CI never takes a result on master** (a pull request does: `.github/workflows/ci.yml`, by that pull request's earlier runs);
- a full run, `-Perf` and `-NoCache` take none; `WREN_TEST_CACHE=0` is `-NoCache` for a whole session.

## The shared code of test processes

The JavaScript engine's image compiles in 5 s of CPU, once in each process, and a run starts hundreds of them, each
without a profile or with a throwaway one. `tools\test_env.ps1` sets `WREN_TEST_WASM_CACHE` to `build\wasm_cache`: all
the test processes then read the disk cache of the engine (`src/wasm/module_cache.odin`: keyed by the image and the
engine's configuration, authenticated), 0.2 s of CPU instead of 5. The tests of that cache itself (`wasm.disk_cache`) keep
their own. A release ignores the variable. `-NoCache` turns this off too.

## WPT

A run of WPT spent 58 % of its time on tests that time out (1300 of 8800, 50 of them for 60 s): a test expected to time out
waits for what will not come, and the page of a test that can do nothing more is given a second to prove it.

With `-Quick`, and `tools\wpt.ps1 -FastTimeouts` for a whole run:

- a test the expectations say times out gets 3 s (`-timeout-cap`), a page that can do nothing more 300 ms (`-idle`);
- all that fails then goes through the second chance: run again together, without either, with 4 times the limit and the
  engine's limit on one script out of the way, and what still fails alone. Only a test that regresses there counts.

So a shorter limit can cost a rerun, not hide a regression. What it does not see is a test that has **begun** to pass: a
whole run without it does, and `-Update` (which refuses the cap) records it. `-Only` keeps the whole limits too: someone is
looking at that test. `-NoFastTimeouts` turns it off under `-Quick`.

## Writing an end-to-end test

An end-to-end test is an Odin `@(test)` procedure of `src/tools/e2e`, on Odin's own test runner. It calls the browser directly: the program
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

- **One file per subject**, `src/tools/e2e/<name>.odin`, with its checks kept as they mean. A file's tests are one step of `test_all`: `Step '...' { Invoke-WrenE2E 'build\e2e_test.exe' '<name>' }`, with its marks (`-UiOnly`, `-NoCI`, `-Weight`). `Invoke-WrenE2E` finds the tests in the file.
- **An action that fails ends the test there**, saying where it was called from, what failed and the folder of what it left (`build/e2e/<test>/`: `failure.png`, `failure_console.txt`, the test's own `e2e.shot`s, kept only when it failed). So a scenario checks no return. Checks are `testing.expect*`: they go on.
- **Barriers, never sleeps.** `wait_load`, `wait_frames(s, n)`, `wait_selector`, `wait_js(s, condition)`, `wait_chrome_still` (the interface's animations have ended), `wait_until(s, ready_proc, "what")` and `wait_until(s, data, ready_proc, "what")`. Each has `deadline := DEFAULT_DEADLINE`, which only ends a failing run. Wait for the state itself, not for a number of frames: `wait_frames` is for what is done within a frame or two by construction.
- **The browser's animations go by frames** (`control_begin`: each frame is one of the usual length for them, however fast it is made), so a 500 ms animation is 30 frames. What a page does on a real timer is still real time: the preference that shortens it (`forms.caret.blink_ms`) rather than a wait for it.
- **Something the browser does not let you see or do**: add it to the browser, not to the test. A typed procedure in `src/browser/control.odin`, which the remote method (`remote_methods.odin`, only the JSON's decoding there) calls too; a field of `api.Stats`, filled by `control_stats`. Then the wrapper in `src/e2e/e2e.odin`.
- **One browser at a time in a process** (the browser's state is the process's), and `e2e.start` ends with the test, as do its profile (`e2e.temp_profile(t)` for one that `e2e.restart` must find again), `e2e.temp_folder(t)` and `e2e.test_server(t)`. The tests of one run go one after the other (`ODIN_TEST_THREADS=1`); `test_all` runs one process per file, side by side.
- **Only what is about a process starts one**: a launch, an exit code, a crash, a second start, the console launcher, the channel itself. `e2e.launch(t, {...})` gives a Wren of its own, over the channel, with the typed client `wb:remote/api` (`api.navigate(p.s, url)`), `e2e.quit(p)` its exit code, `e2e.kill(p)` a crash. It is headless too unless `hidden = true`; `start` holds its environment, its folder, its outputs. Any other program is `e2e.program` (`e2e.run` to its end: its exit code and what it printed). What another process does to the disk is waited for with `e2e.wait_file`, `e2e.wait_gone`, `e2e.wait_for`. A hidden window needs a desktop nobody uses: `test_all`'s, or by hand `tools\test_desktop.ps1 -Command "..."`.
- **What is about the window of the system runs on a real one, never shown**: `e2e.start(t, {hidden = true})`, in the test's process, so that the window procedure is called on the test's thread as the system calls it. `src/tools/e2e/real_window.odin` is that core (WM_DPICHANGED, WM_NCHITTEST, WM_SETCURSOR, the z-order for a drop, the swap chain), `frame_gate.odin` and `devtools_resize.odin` use it too; `e2e.launch(t, {hidden = true})` when something else must read it from outside (`a11y_uia.odin`). It needs a desktop session: `test_all`'s own, `tools\test_desktop.ps1 -Command "build\e2e_test.exe -tests:name"` by hand. What needs a paint or the system's frame goes through `show_unseen` (`window_native.odin`): shown where nobody sees nor touches it.

- **What the browser does left alone**: a barrier and a poll ask for frames. `e2e.rest_turns(s, n)` turns the loop with nothing asking, a timer that draws nothing waking it each time; `e2e.wait_at_rest(s)` until it stops drawing by itself, `s.app.rates` and `e2e.stats(s).loop` count what it did and say who asked (`frames_at_rest.odin`: none on a static page).

- **Nothing left allocated**: `build\e2e_test_check.exe` is the same program built with `-define:WREN_TRACK_MEMORY=true` (full runs: every allocation of the process goes through the tracker of `base`). When a test's browser has ended and the test has let go of what it holds, whatever is still allocated, or was freed twice, is listed and fails the test (`end_of_test`). Only scenarios about what a session holds (workers, service workers, file systems, the back/forward cache, partitions) run there: a step of `test_all` says which.

Running them by hand: `build\e2e_test.exe -tests:the_title_shows` (no window opens, no other desktop is needed, except for a scenario with `hidden = true`), or `test_all -Quick -NoCache -Only 'src.tools.e2e'`. `WREN_E2E_TRACE=1` prints every call with its time, `WREN_PHASES=1` the phases of a start and an end of the browser (a real `wren.exe` says them too).

Two things `core:testing` does not give: a test stopped by a signal (`testing.fail_now`, a panic) can happen once per run on Windows, the runner lets go of a lock it does not hold, and the next signal waits for ever; `e2e` stops its tests through a limit of 0 instead (hence the "Test timed out" after a failure's message). And checks that pass say nothing: `test_all` counts tests here, not checks.

## Writing a test that is quick

The rules are in [CONTRIBUTING](../CONTRIBUTING.md): wait for a condition, with a limit that only ends a failing run (the barriers above, `wren
ctl wait` for a script, `Invoke-WrenBuildIfStale`, `Ensure-WrenBuild`), one shared Wren between scenarios. And check what a wait returns:
a tool that waited for a line nobody logs spent its 120 s limit in every run, and passed.

## Virtual time

`host.Loop` reads its time through `host.now_ns`. A test gives the loop a `host.Virtual_Clock` (`clock_virtual`) and moves it:
`clock_advance(&loop, d)` runs at once what falls due on the way, each timer at its own deadline; `clock_move` only moves it, as a
stalled machine would. `loop_wait` on such a clock does not wait for a timer. Production pays one test of a pointer.

A test does not sleep to wait for another thread: it waits on the state (a semaphore, a completion posted to the loop,
`base.await` when the code under test has no signal). The few real sleeps left in unit tests measure the real clock, and say so.

## The web tests

Everything under the browser's window (fetch, the network stacks, the HTTP cache, the content blocker, pages and their scripts, Wasm guests, workers, images, forms, frames: no shell, no frame) is tested by one program of `core:testing`, `src/tools/webtests`, built once as `build\web_test.exe` with every allocation tracked. One file per subject (`cache.odin`, `frames.odin`, `jsweb.odin`...), `#+private file` with its own helpers, its tests named after it (`cache_freshness`); what they share is `harness.odin`.

```odin
#+private file
package webtests

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
- **A step of `test_all` is a subject in a process of its own**: `Step '...' { Invoke-WrenWebTests 'build\web_test.exe' 'cache' }`, with its marks. By hand: `build\web_test.exe -tests:cache_freshness,zz_the_process_ends_with_nothing_left`, on a desktop nobody uses (`tools\test_desktop.ps1 -Command "..."`). The program with no name runs every subject in one process.
- **No result is read from the console.** A page's script talks to its test through the functions of `wrenTest` (`api/testhost.widl`, `native/js/odin/test_host.odin`, `src/page/test_host.odin`, `src/tools/testhost`), which exists only in a page given a test host: `testBegin`, `testEnd`, `check`, `measure`, `note`, `signal`, `skip`, `done`. What is uncaught fails the page unless the test expects it (`pr.expect_uncaught`).
- **A page declares what it runs.** `close_page` (`testhost.finish`) fails a section that ran another number of tests than it declares (`tests = 8`), or none, or fewer checks than it declares (`min_checks`), a section whose script never said `done()` when it is the one to end, a test that checked nothing, and a `skip("webgl-adapter" | "av1-decoder", why)` that the program does not find true of the machine: it makes a context of its own for the first (only "no graphics adapter" from the GPU process counts as none), asks the media backend for the second. A true skip prints `SKIP [section] ...`, is counted, and `test_all` lists it at the end of a run.
- **Barriers, not time.** `wait_until(t, what, data, ready)`, `wait_note`, `wait_done` run the loop until a state holds. What a loop's timer does or must not do yet goes by `virtual_clock(t)` and `host.clock_advance` (a page's `setTimeout` follows it). Only what a real clock on the other side decides (the `Date` of an HTTP answer) waits for that exact condition in real time.

## The test server

`tools/testserver` is a Go package (Go's HTTP/2, quic-go's HTTP/3, TLS). It is a library first:

- `build\testserver.dll` (`go build -buildmode=c-shared` of `tools/testserver/cdll`, which needs a C compiler for Go's cgo), loaded by `src/testserver`. An Odin test calls `e2e.test_server(t)`, or `serve(t)` in the web tests: it listens when that returns, with its base port, on the threads of Go's runtime in the test's own process. No process to start or to stop, no file to read: it goes with the process. One per process; each call forgets what the handlers counted, as a new server would.
- `build\testserver.exe` (`tools/testserver/cmd/testserver`), a thin main over the same package, for what is not Odin: `tools\test_env.ps1` `Start-WrenTestServer` for the scripts (`wpt.ps1`, which runs it as `wptserver.exe`, `perf.ps1`, `endurance.ps1`, `net_stress.ps1`, `remote_bench.ps1`...; it writes its base port to `-port-file` once it listens), `demo.bat` and the release's extras.

Every origin is an offset from the base port (`tools/testserver/ports.go`): +0 http on 127.0.0.1 and localhost, +1 https, +2 a second http origin, +3 and +4 the web-platform-tests origin, +5 to +9 the transports. A block is free or taken as a whole; a test takes the next free one from a port derived from the worktree's path. A test writes the default ports (`testenv.url("http://127.0.0.1:8765/x")`) and they move with the block, in the text files of `/site/` too.

## Debugging the tests' time

- `tools\test_profile.ps1 -Out build\prof\x -Run "<command>"` (or `test_all -Profile`): every process of the tree, by program,
  count, wall and CPU seconds; the use of the processors second by second, the tree's and the rest of the machine's.
  `-Compare a -With b` compares two runs; `build\prof\x.processes.tsv` has each process and its command line. Read the CPU
  seconds when other runs share the machine: they barely move, the wall clock does.
- `WREN_SLEEPS_FILE`, set by `test_all`: the fixed waits of the scripts, by script.
- `WREN_STARTS_FILE`, set by `test_all`: the Wren processes they start.
- `wren ctl wait load|idle|stable|quiet|selector|function|frames`, `wren ctl stats`, `wren ctl reset`, `wren ctl checkpoint`:
  [Remote control](remote.md).
- A step that fails under load and passes alone is marked `-Flaky`: it says what failed, and fails nothing.
