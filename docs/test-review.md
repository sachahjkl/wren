# Review of the test system

Date: 2026-11-12. Method: static review. Nothing was built or run.

Sources: `src/tools/test_all`, `src/e2e`, `src/tools/e2e`, `src/tools/wpt`, `src/tools/test262`, the unit tests,
`.github/workflows/ci.yml`, and three CI logs of 2026-11-09 kept in `build/` (`ci_win.log`, `ci_win2.log`,
`ci_win3.log`, `ci_linux.log`).

Each finding gives a location, the cost, and a fix. Findings are ordered by gain in each section.
A time marked "measured" comes from the CI logs. A time marked "estimate" is a calculation from those numbers.

## Summary

The tests are mostly built on conditions. The lint of sleeps works. Fixed delays are not the main cost.

The main costs are these:

1. The Windows runner is saturated. `test_all` takes 1810 s with 100 % of its two slots busy and 3.8 of 4 processors
   in use (measured). A shorter wait does not help there. Less CPU work or more runners help.
2. One job runs everything. Three groups of steps do not depend on each other and can run on three runners.
3. Bounds are long. A failed barrier costs 240 s. A stuck step costs 900 s. Some steps have a bound of 4 hours.
   Some waits have no bound.
4. Nothing stops a run in which the same failure repeats in every step. This is the most probable cause of a job
   that reaches its 90 minutes.

Expected gains:

| Change | Windows job | Linux job | Local run |
|---|---|---|---|
| Split the Windows job in three (3.1) | 34 min to 14-16 min (estimate) | | |
| No software frames for tests that read no pixel (4.1) | minus 3 to 4 min before the split (estimate) | | minus some CPU |
| Cache the JavaScript engine on Linux (4.3) | | minus 3 min (measured) | |
| Cache the test server programs (4.4) | minus 1 min (estimate) | | |
| One sweep of the check build, not two (4.2) | | minus 5 min or more (estimate) | |
| Short deadlines and a circuit breaker (2.1, 2.2) | worst case 90 min to 45 min; a failing test 240 s to 60 s | same | same |
| `e2e_test` does not wait for the browser build (3.2) | | | minus 18 to 107 s after a change of the browser |

## Measured baseline

Windows job, run `ci_win3.log` (4 vCPU, `-Jobs 2`):

- Setup and caches: 150 s. `wrentool build`: 64 s. `test_all`: 1810 s. Total: about 34 min.
- `test_all`: 3871 s of steps, 6787 s of CPU, 1707 processes, 211 steps.

The steps that use the most CPU (measured):

| Step | Wall | CPU |
|---|---|---|
| Local pages on the check build (`wrentool sweep`) | 376 s | 964 s |
| Check build: scripted session and endurance | 278 s | 760 s |
| `busy_page` (two steps) | 222 s | 428 s |
| `cursor` | 185 s | 265 s |
| Build of `e2e_test` | 81 s | 240 s |
| `text_decoration` | 74 s | 233 s |
| `inline_svg_hover` (failed on a capture timeout) | 139 s | 202 s |
| web-platform-tests | 220 s | 172 s |
| Build of the test server, and `go test` | 135 s + 122 s | 68 s + 75 s |
| Unit tests on poisoned memory: style | 131 s | 103 s |

Linux job, run `ci_linux.log`: `test_all` takes 117 s. The step "Native libraries" takes 216 s. In that step,
`buildjs` takes 177 s. The job has no cache for the engine.

## 1. Fixed delays and waits that are not conditions

The lint `src/tools/test_all/lint_sleeps.odin` finds `time.sleep`. It does not find the forms below.
The total cost per run is 15 to 25 s of real time, spread over parallel steps. The gain in wall clock is small.
The gain in reliability is larger: each item below depends on the speed of the machine.

### 1.1 `wait_at_rest` costs 500 ms at each call

- Location: `src/e2e/e2e.odin:58` (`REST_QUIET`), `src/e2e/e2e.odin:519`.
- Callers: `devtools_fold.odin:66`, `menu_wheel.odin:36`, `pointer_gesture.odin:113`, `scroll_driven.odin:299`,
  and six calls in `frames_at_rest.odin`.
- Cost: 0.5 s of real time at each call, in each run. The wait ends only when the time has passed.
- Fix: ask the browser for the state. Add a field `at_rest` to `api.Stats`: no frame is requested, no animation
  runs, no timer that draws is armed. Wait for that field with `wait_until`. Keep `REST_QUIET` only in
  `frames_at_rest.odin`, where the absence of frames in real time is the subject.

### 1.2 `busy_wait` is a fixed delay in real time

- Location: `src/e2e/busy.odin:44`. Callers: `busy_page.odin:278` (300 ms), `busy_page.odin:344` (400 ms),
  `busy_page.odin:408` (5 waits of 90 ms), `chrome_frames.odin:323` (100 ms).
- Cost: about 1.3 s per run. The larger cost is the flaky test of 5.2.
- Fix: use `busy_clock(ms)` for each of them. `scroll_driven.odin` does this for animations. The caret and the
  autoscroll must read the clock of the chrome frame for that.

### 1.3 Sections cut short at a set time

- Location: `src/tools/e2e/web_jsweb.odin:325`. 37 sections, each abandoned after 0, 10, 100 and 300 ms.
- Cost: about 15 s of real waits per run (37 x 0.41 s), in three steps.
- Fix: cut on an event count, not on a time. Close the page after N turns of the loop (0, 1, 10, 100).
  The result does not depend on the machine then, and the steps take milliseconds.

### 1.4 A hung GPU process is waited for 10 s

- Location: `src/tools/e2e/webgl_process.odin:19` (`HANG_MS :: 10_000`), used at lines 123, 152, 175, 277.
- Cost: 10 s of real time in the test of the hung process. The comment says 1 s and 3 s failed under load.
- Fix: give the watcher an injectable clock. The test advances that clock past the limit after the process hangs.

### 1.5 A second start waits 3 s for a first one that does not answer

- Location: `src/tools/e2e/instance.odin:136`. The test passes only when the product's 3 s timeout expires.
- Cost: 2.5 to 9 s per run.
- Fix: make the hand-over timeout a preference of the launch (`browser.instance.answer_ms`), set to 100 ms in
  this test. The test still proves the path. This is not a variable only for tests: it is the product's limit.

### 1.6 WebSocket closing handshake: 50 repetitions

- Location: `src/tools/e2e/web_wsclose.odin:17` (`RUNS :: 50`), line 165 (3 runs x 300 ms), line 154
  (5 runs x 200 ms server delay).
- Cost: 39 s on the CI (measured). The file says the repetitions make a race of one in two "certain to show".
- Fix: 10 runs give a detection probability of 99.9 % for a race of one in two. Use `RUNS :: 10`.
  Replace `closedelay=200` with a gate of the test server (`?gate=K`). Gain: about 30 s of a light slot.

### 1.7 Real server delays in the web tests

- Locations: `web_jsload.odin:35-43` (delays of 5 to 300 ms, one of 3000 ms), `web_jsload.odin:53`
  (`COMPILE_TAKES_IT_MS :: 500`), `web_sitecompat.odin:26-27`, `web_net.odin:61` (`BURST_SERVER_MS :: 400`),
  `web_net.odin:52` (500 ms receive timeout, run for each of two backends), `download.odin:17`.
- Cost: 2 to 4 s per run. Each "A arrives before B" proven by two delays fails on a slow runner.
- Fix: use gates. The test opens gate A, waits for the event, then opens gate B. The order is then a fact.
  The receive timeout in `web_net.odin:268` is a real client timer: it can stay.

### 1.8 Other real waits

- `src/tools/e2e/remote_channel.odin:81`: 1 s sleep to measure CPU of a Wren with no channel. This is a measure
  of time. Move it behind `base.perf_skip`, as the two other sleeps of the file.
- `src/tools/e2e/remote_channel.odin:96`: 300 ms sleep. Replace it with a condition on the channel's state.
- `src/tools/e2e/urlbar.odin:127`: a 400 ms busy loop in the page. Hold the page until a condition, as
  `chrome_frames.odin` does with `hold()`.
- `src/tools/e2e/crash_recovery.odin:16-18`: snapshot timers of 500 ms and 1000 ms in real time. Lower both
  preferences to 20 ms, or give the session writer the loop's virtual clock.
- `src/tools/e2e/frames_at_rest.odin:20`: `REST_TURNS :: 120` turns of at least 1 ms. Legitimate: the subject is
  what the browser does in real time. The step is `.No_CI`.

### 1.9 `base.await` spins on a processor

- Location: `src/base/await.odin:17-24`. 15 callers in unit tests.
- Cost: the wait calls `thread.yield()` in a loop. It uses a full processor during the wait. With 12 jobs, each
  spinning test slows the other steps. The limit is 60 s.
- Fix: wait on a `sync.Futex` or a semaphore with a timeout of 1 ms between looks. The condition stays the same.
  Add `base.await(` and `thread.yield(` loops to the patterns of `lint_sleeps.odin`.

### 1.10 The lint does not see every wait

- Location: `src/tools/test_all/lint_sleeps.odin:15` (`TEST_SLEEP_CALLS`).
- Missing patterns: `thread.yield(` (`images_test.odin:335`, `webaudio/worklet_test.odin:38`),
  `busy_wait(`, `wait_at_rest(`, `rest_turns(`, `sema_wait_with_timeout(`, `futex_wait_with_timeout(`,
  and a loop on `tick_since(...) <` with `loop_wait` (`web_workers.odin:457`, `web_jsweb.odin:325`).
- Fix: add these patterns. Each remaining use then has a line and a reason in `tools/test_sleeps_allowed.txt`.

### Legitimate bounded waits (no change)

- `e2e.wait_for` (`src/e2e/process.odin:190`): 5 ms poll on what another process does. It ends on the condition.
- `web_harness.wait_until` (`web_harness.odin:124`): `loop_wait` of 5 ms that any event ends sooner.
- `wait_frames(s, 2)`: 174 uses. Frames are made at once. No use asks for more than a few frames.
- The scheduler's 10 ms tick and the WPT parent's 50 ms tick.

## 2. Bounds that are too long, and hangs that are not detected

### 2.1 No circuit breaker: one cause can cost 100 steps x 240 s

- Locations: `src/e2e/e2e.odin:44-46` (`TEST_LIMIT` 5 min, `DEFAULT_DEADLINE` 4 min),
  `src/tools/e2e/web_harness.odin:39-40` (the same), `src/tools/test_all/main.odin:26` (900 s per step).
- Scenario: the software rasterizer, the test server library or the engine image fails on the runner.
  Each of the 77 end-to-end steps and 22 web steps then waits 240 to 300 s, two at a time.
  That is more than 3 hours of work. The job stops at 90 minutes with no report.
- This is the most probable cause of the 90-minute runs. The design test: break `testserver.dll` and run the CI.
- Fix, in `scheduler.odin`: count the steps that end as `stuck` or with "Test timed out". After 5 of them,
  stop admitting steps that have the same `needs`. Mark the others `NOT RUN: 5 steps timed out`. Write the report.
- Fix, in `ci.yml:70`: add `timeout-minutes: 45` to the step "Tests". Add a flag `-RunTimeoutSec 2400` to
  `test_all`: past it, the scheduler dumps and kills every running step, then writes its report.
- Fix, in `ci.yml`: upload `build/test_logs`, `build/test_report.txt` and `build/e2e/*/failure.png` with
  `if: always()`. A cancelled job leaves nothing to read today.

### 2.2 A failed barrier costs 240 s, and a web test continues after it

- Location: `src/tools/e2e/web_harness.odin:124-134`. `wait_until` records a failure and returns `false`.
  Most callers ignore the result. A test with three waits costs 720 s, cut at 300 s by `TEST_LIMIT`.
- Then the runner ends the thread. The world of the process (`loop`, `pages`, `storage`) is left in the middle
  of a call. Each later test of the process waits on that broken world. The step ends at its 900 s limit.
- Measured example: `inline_svg_hover` failed in 139 s on a capture timeout (`ci_win.log`, `ci_win3.log`).
- Fix: one deadline of 60 s in both harnesses, and a test limit of 90 s. The CI's slowest passing step takes
  186 s for 40 elements: no single barrier is near 60 s. Measure the longest barrier of a CI run first:
  `WREN_E2E_TRACE=1` prints each call with its time.
- Fix: make the first timeout of a web test final. `wait_until` sets a package flag `broken`, as
  `src/e2e/e2e.odin:135` does. `begin` fails at once when the flag is set. The step then ends in seconds.
- Fix: `process.odin:63` (`PROCESS_WAIT_MS` = 4 min) is used in cleanups (`process.odin:79`, `process.odin:143`).
  A cleanup must not wait 4 minutes for a process that it has killed. Use 10 s there.

### 2.3 Tasks cannot be killed: a hung build has no bound

- Location: `src/tools/test_all/scheduler.odin:468-481`. For a stuck task, the scheduler sets `task.kill`.
  Only `task_exec` (`scheduler.odin:443`) reads that flag.
- These tasks do not use `task_exec`: `task_browser`, `task_dependencies`, `task_js_engine`, `task_launcher`,
  `task_testserver`, `task_runner` (`tasks.odin:13-76`). They call `tooling.run` with no limit
  (`src/tools/wrentool/builder/builder.odin:209`).
- Result: a compiler that does not end keeps the run alive for ever. `ci.yml:41-42` describes this exact event
  for the dev build and gives that step 20 minutes. The check build inside `test_all` (`steps.odin:248`) has
  the same compiler and no bound.
- Fix: one way to start a process from a task. `tooling.run` takes a `^bool` kill flag and a limit.
  `builder.Options` carries both. The scheduler's limit then ends every child. Remove the second path.
- Fix: after a task is told to stop, give it 60 s. Then mark the step `stuck`, finish it, and let the thread go.
  The run must end even if a thread does not.

### 2.4 Step limits of 4 hours on the CI

- Location: `src/tools/test_all/steps.odin:106` (`LONG_STEP_SECONDS :: 4 * 3600`). Used at lines 241, 247, 248,
  375, 377, 397, 449, 483, 498, 503 and in `asan.odin:154`.
- The CI jobs have limits of 45 to 90 minutes. A limit of 4 hours is no limit there.
- Fix: a limit per step from its measured time. Under `-Quick` or `-CI`: 10 minutes for a build, 15 minutes for
  WPT, test262 and the endurance run. Keep 4 hours only for full runs. `Step.limit` becomes a procedure of
  `cfg`.

### 2.5 The first WPT child is waited for without a bound

- Location: `src/tools/wpt/queue.odin:257`. `os.process_wait` has no timeout. This child compiles the engine
  image and writes the disk cache.
- Second case: `queue.odin:269`. A child is declared hung only when `len(c.handed) > 0`. A child in the
  `Draining` phase that has reported every test and does not exit keeps `busy` true for ever.
- Fix: poll the first child with the same hang limit as the others. Remove the condition on `handed`:
  a child with nothing in hand and no exit after `hang_ms` is killed. Its exit is not a `CRASH` of a test.

### 2.6 test262 waits for its threads without a bound

- Location: `src/tools/test262/main.odin:763-770`. The loop waits for every worker thread. A test is stopped by
  the engine's interrupt flag, which is cooperative. A native call that does not return is never stopped.
- Fix: each worker publishes the start time of its current test. The main loop fails the run when one test has
  run for more than 10 times `-timeout`. It prints the test's name and exits with a code other than 0.

### 2.7 A unit test has no time limit

- Fact: no `*_test.odin` file under `src` calls `testing.set_fail_timeout` (0 of 296 files).
  `core:testing` gives a test no limit by default.
- Result: a unit test that hangs costs the step limit, 900 s, and the log does not name the test.
- Fix: build every unit step with `-define:ODIN_TEST_LOG_STATE_CHANGES=true` (as the ASan steps do), so that
  the log names the test that was running. Set the step limit of a unit step to 10 times its last duration,
  with a floor of 120 s. `build/test_all_times.txt` has the durations.

### 2.8 A second failure in one e2e process waits for ever

- Location: `src/e2e/e2e.odin:307-311` and `docs/testing.md` ("the next signal waits for ever").
  `stop_test` avoids the defect of `core:testing` on Windows. An assertion or a fault in a test does not.
- Result: after two faults in one process, the process hangs until the step limit (900 s).
- Fix: do not depend on the runner here. In `e2e`, install the assertion handler of the session
  (`s.ctx.assertion_failure_proc`) to log the message and call `stop_test`. For a fault, the crash handler of
  `wb:crashtrace` ends the process at once: with one process per file, the rest of the file is `NOT RUN`
  and is said so. This is a bounded and visible result.

### 2.9 Smaller unbounded waits

- `src/tools/test_all/tasks.odin:252`: `tooling.wait(&p)` on `build/fetch` with no limit, in a task that
  cannot be killed. Fix: `tooling.wait(&p, 120 * time.Second)`.
- `src/tools/tooling/process.odin:106`: `capture` has no limit. It runs `git`, `node`, `vswhere`, and in
  `asan.odin:69` a whole compile of the browser while it holds a mutex that three steps wait on.
  Fix: a limit parameter with a default of 60 s; 20 minutes for the call of `asan.odin:69`.
- `src/tools/test_all/scheduler.odin:533-537`: after `kill_tree`, the scheduler waits for `poll` with no bound.
  Fix: after 30 s, release the process and finish the step.
- `src/tools/wpt/queue.odin:249` and `:272`: `process_wait` after a kill, with no timeout. Fix: 30 s.

## 3. Parallelism

### 3.1 Split the Windows job in three

- Location: `.github/workflows/ci.yml:17-76`.
- Fact: the job is bound by CPU, not by waits. `-Jobs 3` and `-Jobs 4` were measured slower (`ci.yml:52-56`).
  More runners are the only way to more parallelism.
- Three groups with no dependency between them (measured CPU of `ci_win3.log`):
  - A, the check build: `wrentool build check`, the sweep, the scripted session, the endurance run,
    `remote_check`. About 1800 s of CPU, 27 % of the run.
  - B, the browser shell: the 77 `e2e_step` steps. About 2700 s of CPU.
  - C, everything else: unit tests, web tests, WPT, toolkit suites, lints, the package. About 2300 s of CPU.
- Each job pays the setup (150 s), and B also pays `wrentool build` (64 s) and the build of `e2e_test` (81 s).
- Result (estimate): the longest job takes 14 to 16 minutes, against 34 minutes.
- Fix: use `-Only` and `-Except` with three patterns, as the `asan` and `test262` jobs do. Give `Step` a field
  `group` so that the patterns do not depend on step names. `test_all -List` must print the group.
- Option: one build job uploads `build/wren.exe`, `build/e2e_test.exe`, `build/testserver.*` and
  `build/native` as an artifact. The three jobs download it. This removes 150 to 300 s of CPU per job.

### 3.2 The build of `e2e_test` waits for the browser build

- Location: `src/tools/test_all/steps.odin:422` (`needs = COMMON_NEEDS + {.Browser}`), and line 483 for WPT.
- The comment says the program links `build/native`, "which the browser's build makes". The step of line 241
  makes `.Native`, and `COMMON_NEEDS` contains `.Native`.
- Cost: locally, after a change of a browser source, `e2e_test` starts only when `wren.exe` is linked.
  That is 18 to 107 s of critical path (the times of the `dev` build in `AGENTS.md`). No cost on the CI:
  the browser is built before.
- Fix: verify that `builder.dependencies` leaves `build/native` in its final state. Then remove `.Browser`
  from the two `needs`. If the browser build changes `build/native` after that, move that work to
  `builder.dependencies`: two steps must not write one product.

### 3.3 The network test runs its two backends one after the other

- Location: `src/tools/test_all/steps.odin:463-464`. Two `web_run("net", ...)` actions in one step.
- Cost: about 25 s in one light slot. The two runs share nothing: each has its own process and port block.
- Fix: two steps, one per backend. Gain: about 12 s when a light slot is free.

### 3.4 `ODIN_TEST_THREADS=1`

- `E2E_BUILD_FLAGS` (`steps.odin:102-104`): needed. The browser's state is the process's. The split by file,
  and `each_test` for five files, give the parallelism. No change.
- `steps.odin:254` (images): one test sets the idle time of the process-wide decoder pool. Fix: the pool takes
  its settings at creation, and the test makes its own pool. The step takes 3 s: low gain, but it removes a
  shared global.
- `steps.odin:271-274` (remote, remote api, remote client), `steps.odin:363` (wasm), `steps.odin:414-419`
  (toolkit suites): each step takes 1 to 8 s. No gain worth a change.

### 3.5 Shared resources

- Ports: solved. A block of ports per process, from the worktree's path (`docs/testing.md`, "The test server").
- Profiles: solved. `e2e.temp_profile`, and `build/web_profile/<pid>` (`web_harness.odin:38`).
- `build/wrentool_step.exe`: three steps build the same file (`steps.odin:236`, `:452`, `:492`). In a full local
  run, the steps of lines 236 and 452 run at the same time and write the same file. See 4.5.
- `build/tmp/license_tool_test.wrenlicense` (`tasks.odin:134`): a fixed name. Two runs in one worktree collide.
  Fix: add the pid to the name, as `tasks.odin:210` does.
- The GPU: on the CI every frame is drawn by the software rasterizer. See 4.1.

### 3.6 Order of a run

- The scheduler starts the longest path first (`scheduler.odin:279-287`). This is correct.
- On the CI, the test server took 136 s to build, and the 99 steps that need it waited (measured). The two
  heavy slots stayed busy with unit tests, so no slot was idle. See 4.4 for the fix.
- The first run on a runner has no durations (`build/test_all_times.txt` is not cached). Each step is then
  taken for its `weight` or 60 s. Fix: commit a file of typical CI durations, or cache the file between runs.

## 4. Redundant or wasteful work

### 4.1 The software rasterizer draws frames that no test reads

- Fact: on a runner a frame takes 15 to 22 ms to draw, against 0.1 ms on a GPU (`docs/testing.md`).
- Example: `src/tools/e2e/cursor.odin:33-45`. For each of 40 elements the test asks for frames, then reads
  `stats.cursor`. It reads no pixel. It takes 185 s and 265 s of CPU on the CI (measured), at a scale of 2.
- The chrome world already has this idea: "no renderer unless the test asks for pixels"
  (`chrome_world.odin:108`), 7 to 40 ms a test.
- Fix: `e2e.Options.pixels`. Without it, the session builds the display list and skips the rasterization.
  `e2e.capture` fails with a clear message in such a session. Start with `cursor`, `config`, `page_scrollbars`
  (if it reads geometry), `keyboard_owner`, `search`, `urlbar`, `history`.
- Gain (estimate): 600 to 900 s of CPU on the CI, 3 to 4 minutes of the unsplit job.

### 4.2 The sweep of the check build runs on both systems, and costs the most

- Locations: `steps.odin:451-452` (Windows: 376 s, 964 s of CPU, measured), `ci.yml:259-263` (Linux: a full
  `./build.sh check`, then the sweep under `xvfb` and a software Vulkan driver).
- Every end-to-end test already runs with freed memory poisoned (`steps.odin:422`, `POISON`).
- Fix: run the sweep in one place per system, in a job of its own (group A of 3.1 on Windows, a second Linux
  job). The main jobs then do not wait for it.
- Fix: the sweep passes `-CloseMs 60000 -PingMs 60000`. Check that no page waits for one of these limits in a
  passing run: 14 pages in 376 s is 27 s per page.

### 4.3 The Linux job builds the JavaScript engine in every run

- Location: `ci.yml:239-248`. `buildjs` took 177 s (measured, `ci_linux.log` 00:02:36 to 00:05:33).
- The Windows setup caches `build/js` (`.github/actions/setup/action.yml`, "Cache the JavaScript engine").
- Fix: the same `actions/cache` step in the Linux job, with the same key and a `linux-` prefix.
  Cache `build/wasmtime-linux`, `build/lexbor-linux` and the wgpu archive too. Gain: about 3 minutes.
- Fix: the `apt-get` and LLVM steps run in every job. Build a container image with them once
  (`ghcr.io/.../wren-ci:bookworm-llvm18`) and use it in `container:`. Gain: 1 to 2 minutes (estimate).

### 4.4 The test server is compiled three times with no Go cache

- Location: `.github/actions/setup/action.yml:48-51` (`cache: false`), `steps.odin:442-443`.
- Cost: "build testserver" 135 s and `go test` 122 s (measured). The DLL, the program and the test binary
  compile the same packages (quic-go, HTTP/2) from nothing.
- Fix: cache `build/testserver.exe` and `build/testserver.dll` with a key from `tools/testserver/**`.
  A hit makes the step a no-op, as for Lexbor. Also set `cache: true` with
  `cache-dependency-path: tools/testserver/go.sum` for the build cache.
- Gain: 140 s of CPU, and the end-to-end steps can start 2 minutes sooner.

### 4.5 `wrentool` is built up to five times

- Locations: `ci.yml:35`, `ci.yml:106`, `ci.yml:143`, and `steps.odin:236`, `:452`, `:492`
  (`build/wrentool_step.exe`).
- Fix: one step that makes a product `.Wrentool` (`build/wrentool_step.exe`). The three steps need it.
  This also removes the two writers of 3.5. In `ci.yml:106`, remove the second build: the file of line 35
  is still there.
- The same for `src/tools/license`: `steps.odin:433` and `:435` build it twice under two names. One product.

### 4.6 Packages compiled and tested two to four times

- `base`, `style`, `layout`: a normal step (`steps.odin:250-256`), a poisoned step (`:257-259`) and an ASan
  step (`asan.odin:20`). `page`: normal, poisoned with pages (`:281-284`) and ASan.
- Measured on the CI: style 31 s and 131 s; layout 50 s and 54 s.
- The two variants run the same tests. The poisoned build detects more. The normal build is what ships.
- Fix (option): on the CI, run only the poisoned variant of these three packages. Keep both in a full run.
  Gain: about 80 s of step time. Decide this with care: the allocators differ between the two builds.

### 4.7 `odin check` of each package on Linux

- Location: `src/tools/test_all/steps_linux.odin:18-19` and `:39-43`. 46 checks.
- `odin check src/tools/e2e` type-checks every package that it imports. Most of the 46 checks repeat that work.
- Cost: small (0 to 2 s each, about 30 s of CPU). Fix: keep the leaf programs (`tools/e2e`, `tools/wpt`,
  `tools/endurance`, `tools/test_all`, `crashtrace`) and the packages that no program imports.
  Verify first that `-vet` applies to imported packages of the `wb` collection.

### 4.8 Tests that are benchmarks

- The four `bench_*_test.odin` files (`src/browser`, `src/layout`) are opt-in by a define or a variable. Good.
- The measures in the end-to-end files are behind `base.perf_skip` (12 places). Good.
- `src/tools/test_all/steps.odin:378-397`: the JIT step runs 15 `jsengine` commands on `examples/jsbench`
  files, then the whole of test262 with the JIT. It is in its own CI job. No change.
- `src/tools/e2e/busy_page.odin`: 428 s of CPU on the CI (measured), because pages hold a thread in a busy loop
  for a real duration. With `busy_clock` (1.2) the holds can be short. Gain (estimate): 200 s of CPU.

## 5. Tests that depend on something they must not depend on

### 5.1 State built by hand in three ways

- `app_start` (`src/browser/main.odin:1687`) is the product's constructor.
- `test_app` (`src/browser/app_test.odin:10`) is a second one. 279 uses.
- `chrome_start` (`src/tools/e2e/chrome_world.odin:77-125`) is a third. It repeats the list of `*_init` calls of
  the product and builds each `Tab` by hand (`:115-120`), with the comment "as tab_new does".
- 18 unit tests call `new(App)` directly, and others call `new(Tab)` or `new(Browser_Window)`:
  `about_wren_test.odin:278`, `bench_palette_test.odin:26`, `chrome_style_test.odin:251`, `demos_test.odin:47`,
  `desktop_shell_test.odin:39` and `:66`, `devtools_test.odin:30` and `:128`, `download_test.odin:13`,
  `history_tree_test.odin:176`, `local_paths_test_windows.odin:43`, `pacing_test.odin:129`,
  `palette_test.odin:98`, `selection_shell_test.odin:8`, `urlbar_test.odin:219` and `:321`,
  `wheel_step_test_windows.odin:9`, `windows_test.odin:86` (with `tab_ids` filled by hand at `:168`).
- This is the cause of the two harnesses that broke on `tab_ids`.
- Fix: one constructor in stages, in `src/browser`. `app_make(Options)` makes an App that satisfies every
  invariant with no window. `app_chrome_init(app, window)` adds what the interface reads. `app_start` calls
  both, then the rest. `test_app` and `chrome_start` call the same stages.
- Fix: one procedure adds a tab to a window: `tab_adopt(app, window, tab)`. It writes `tab_ids`. `tab_new`
  and the tests call it. A test that needs a tab with no page calls `tab_new_bare(app, title)`.
- Fix: a lint in `test_all`, beside `lint_address.odin`: no `new(App)`, `new(browser.App)`, `new(Tab)`,
  `new(Browser_Window)` or `App{` outside the files of the constructors.
- The design test: add an invariant to `tab_new` and run the unit tests. With one constructor, no test fails.

### 5.2 Marks that hide a defect

Each mark below says "cause not found" or "to be understood". Each hides a possible product defect.

| Location | Mark | Reason given | Judgment |
|---|---|---|---|
| `steps.odin:331` | `flaky` on `the_caret_blinks_while_the_page_is_busy` | "failed once on the CI... nothing found" | The test samples a 200 ms blink with real waits of 90 ms (`busy_page.odin:58-60`, `:408`). The result depends on the frame times. Use the test's clock (1.2), then remove the mark. |
| `steps.odin:301` | `.No_CI` on `frames_at_rest` | "the caret drew 5 frames for 3 flips once: cause not found" | A possible defect of the product: an extra frame. The test counts frames in real time. Count frames per caret flip on a virtual clock, then run it on the CI. |
| `steps.odin:355` | `.No_CI` on `setup` | "the running copy was not out of the way once: cause not found" | A possible race in the uninstall of a running copy. Users can meet it. Keep the mark, open an issue, log the file operations in the test. |
| `steps.odin:357` | `.No_CI` on crash reports | "overflow_thread left no report once: cause not found" | A crash report that is lost is a product defect. Run the step on the CI as `.Flaky` with its log uploaded: a skipped step gives no data. |
| `steps.odin:306` | `.No_CI` on `dnd` | "without a GPU... the read-back stays pending. To be understood." | A read-back that never completes on a software adapter is a product defect for users with no GPU. |
| `steps_linux.odin:17` | idb unit tests not run | "two of them fail on the GitHub runner and pass in WSL; not understood yet" | The two tests are about a failed request and a failed write. Probably a file-system difference. The whole package is skipped for two tests: run the others with `ODIN_TEST_NAMES`. |
| `ci.yml:55-56` | three checks removed from the CI | failed under load | Correct for the two that measure time. Verify that each is behind `-Perf` and still runs somewhere. |
| `steps.odin:285`, `:337` | `.No_CI` on `devtools_resize`, `real_window` | the runner's screen and scale | Legitimate: a real window depends on the machine. |
| `steps.odin:297`, `:315` | `.No_CI` on `video_layers`, `devtools_split` | 160 s and 420 s of CPU on the software rasterizer | Legitimate cost. Both read pixels. |
| `wpt/expectations` | 79 lines with `A\|B` | flaky expectations | Acceptable in number. List them in the report, so that the number does not grow unseen. |

Rule to add to `docs/testing.md`: a `.Flaky` or `.No_CI` mark with no known cause has an issue number and
still runs somewhere with its logs kept. A mark of type `.Flaky` is preferable to a skip: it gives data.

### 5.3 Assertions on real time in default tests

- `examples/jsdom/animations.html:22`: `document.timeline.currentTime` within 50 ms of `performance.now()`.
  It failed on the CI with 144 ms against 220 ms (`ci_win2.log`, step "DOM for JavaScript"). The two clocks are
  read at different moments of a frame. Fix: assert the relation that the specification gives
  (`currentTime <= performance.now()`, and equal to the frame's time), or run the page on the virtual clock.
- `src/tools/e2e/web_net.odin:365` and `:370`: a request "left the queue" before or after `BURST_SERVER_MS / 2`
  (200 ms). On a loaded runner an HTTP/2 request can take more than 200 ms to start. Fix: assert the order of
  events with a gate: the server holds the first answers, and the test counts the requests that have arrived.
- `src/tools/e2e/busy_page.odin:37` and `:56`: "moved at least 8 px in 300 ms", "clock within 150 ms".
  Fix: `busy_clock`.
- `src/tools/e2e/webgl_process.odin:264`: an answer within 60 s. This is a bound that only fails a hang. Good.
- `src/webaudio/worklet_test.odin:178` and `:226`: under 30 s and 15 s. These are bounds, not measures. Good.

### 5.4 Global state shared between tests

- The web tests share one world per process (`web_harness.odin:57-71`). The last test,
  `zz_the_process_ends_with_nothing_left`, depends on the alphabetical order of `core:testing`
  (`runner.odin:375`). A test that leaves a page open makes that last test fail, not itself.
- Fix: check the leak at the end of each test, in `end()`: the count of live pages and of tracked bytes
  returns to its value at `begin`. The failure then names the test. Keep the last test for the world itself.
- `web_harness.odin:186`: `virtual_clock` uses a `@(static)` clock. Correct with one thread. It is one more
  reason why these tests cannot run in parallel in one process.
- `src/browser/main.odin:330` and `:355`: the tab ids come from a process-wide counter, by design. Unit tests
  of `browser` run on several threads, so a test must not assert an id value. `chrome_world.odin:116` writes
  ids 1, 2, 3 by hand, which can collide with ids from `tab_new`. Fix: `tab_new_bare` of 5.1 takes the id from
  the counter.
- `steps.odin:254`: the decoder pool of `images` (see 3.4).

### 5.5 Dependence on map order and on addresses

- Odin seeds the hash of a map from the address of its data. The order of iteration changes with the
  allocator, the build and the run. The recent layout failure came from this.
- No test file was found that asserts on the order of a map directly. The risk is in product code whose output
  is ordered by a map iteration.
- Fix: a lint for `for ... in <map>` in `src/layout`, `src/style`, `src/dom`, `src/page`, with an allow-list
  for loops whose result does not depend on order (a sum, a lookup, a free). `core:odin/parser` is already in
  `test_all` (`lint_test_inits.odin`), and gives the type of the iterated expression's declaration in most
  cases.
- Fix: the poisoned unit steps already change every address between passes. Keep `layout` and `style` there:
  they are the tests that find this class of defect.

### 5.6 Dependence on the machine

- Fonts: the web tests use fixed fake metrics (`web_harness.odin:177-181`). Good. The chrome world loads
  embedded fonts (`chrome_world.odin:96-99`). Good. The end-to-end sessions use the system's fonts through the
  browser: `text_decoration.odin` reads pixels of text. Verify that it sets an embedded font for every text
  that it measures.
- GPU: `e2e.start(t, {software = true})` exists. Tests that compare pixels to a level must use it on every
  machine, so that a developer's GPU and the runner's rasterizer give one result.
- Theme: forced to dark in `e2e.odin:213`. Good.
- Locale: no test was found that sets or reads the system's locale. `src/i18n` has no test file: it is only
  type-checked on Linux (`steps_linux.odin:18`).
- Network: `tasks.odin:237` fetches `https://example.com/` in the network stress of a full run. Every step
  inherits `WREN_NETWORK_LOOPBACK_ONLY=1`. Either the case fails, or `fetch.exe` ignores the variable.
  Verify, then remove the case or serve it from the test server.

### 5.7 Tests that assert little

- `src/browser/bench_text_test.odin:67`: `testing.expect(t, best > 0)`. It is opt-in, so it costs nothing.
- `src/browser/remote_test.odin:153`: `process_uptime_ms() > 0`. It proves only that the call returns.
- The web tests have a strong rule here: `close_page` fails a section that ran fewer checks than it declares
  (`web_harness.odin:273`). Extend the idea to the end-to-end tests: `test_all` counts tests, not checks
  (`docs/testing.md`). A scenario with no `testing.expect*` passes. Fix: `e2e.end_of_test` fails a test that
  made no check, with a counter that the `expect` wrappers of `e2e` increase.

## Order of work

1. `ci.yml`: step timeout, upload of logs, Go and engine caches (2.1, 4.3, 4.4). Half a day. No risk.
2. Scheduler: tasks that can be killed, limits per step, circuit breaker, run budget (2.1, 2.3, 2.4).
3. Split of the Windows job (3.1).
4. Deadlines of 60 s and the `broken` flag in the web harness (2.2), after a measure of the longest barrier.
5. One constructor for `App` and its lint (5.1).
6. Sessions with no pixels (4.1).
7. WPT and test262 bounds (2.5, 2.6).
8. The marks of 5.2, one issue each.
9. The real waits of section 1, with the lint patterns of 1.10 first so that the list is complete.
