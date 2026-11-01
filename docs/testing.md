# How the tests run, and how to go fast

`tools\test_all.ps1` runs every test of the project, step by step. This page says what it does with your time, how to
ask for less of it while you work, and which tools tell you where the time goes.

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
steps that build what it uses (`build\policytest.exe`, `build\e2e.wasm`). They all say at the end how many steps they
left out: they are for your loop, never instead of the CI's run.

## The end of a run

A run ends with the slowest steps and sections, how many Wren processes the scripts started, how long they spent in
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
Each step that talks to the test server has a server of its own on a block of ports of its own, so several worktrees test
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

## Writing a test that is quick

The rules are in [CONTRIBUTING](../CONTRIBUTING.md): wait for a condition, with a limit that only ends a failing run (`wren
ctl wait`, `Invoke-WrenBuildIfStale`, `Ensure-WrenBuild`), one shared Wren between scenarios. And check what a wait returns:
a tool that waited for a line nobody logs (`jsloadtest`) spent its 120 s limit in every run, and passed.

## Virtual time

`host.Loop` reads its time through `host.now_ns`. A test gives the loop a `host.Virtual_Clock` (`clock_virtual`) and moves it:
`clock_advance(&loop, d)` runs at once what falls due on the way, each timer at its own deadline; `clock_move` only moves it, as a
stalled machine would. `loop_wait` on such a clock does not wait for a timer. Production pays one test of a pointer.

A test does not sleep to wait for another thread: it waits on the state (a semaphore, a completion posted to the loop,
`base.await` when the code under test has no signal). The few real sleeps left in unit tests measure the real clock, and say so.

## The test programs and their pages

`jswebtest` and `jsdomtest` are test programs of `core:testing`: one `@(test)` per section (`build\jswebtest.exe -tests:core,webgl_process`, or
`tools\jsweb_run.ps1 core webgl_process` with a test server). They run one test at a time (`-define:ODIN_TEST_THREADS=1`) and share one loop: what the
process keeps (image cache, stores) binds to the first loop it sees. A last test, `zz_the_process_ends_with_nothing_left`, undoes it all and checks the leaks.

A page's script talks to its program through the functions of `wrenTest` (`api/testhost.widl`, `native/js/odin/test_host.odin`,
`src/page/test_host.odin`, `src/tools/testhost`), which exists only in a page given a test host: `testBegin`, `testEnd`, `check`, `measure`, `note`,
`signal`, `skip`, `done`. The console is no protocol any more. `testhost.finish` fails:

- a section that ran another number of tests than the one its `@(test)` declares (`tests = 8`), or none, or fewer checks than it declares (`min_checks`);
- a section whose script never said `done()`, a test that checked nothing;
- a `skip("webgl-adapter" | "av1-decoder", why)` that the program does not find true of the machine: it makes a context of its own for the first (only
  "no graphics adapter" from the GPU process counts as none), asks the media backend for the second.

A true skip prints `SKIP [section] ...`, is counted, and `test_all` lists it at the end of a run.

## Debugging the tests' time

- `tools\test_profile.ps1 -Out build\prof\x -Run "<command>"` (or `test_all -Profile`): every process of the tree, by program,
  count, wall and CPU seconds; the use of the processors second by second, the tree's and the rest of the machine's.
  `-Compare a -With b` compares two runs; `build\prof\x.processes.tsv` has each process and its command line. Read the CPU
  seconds when other runs share the machine: they barely move, the wall clock does.
- `Section 'name'` / `Show-WrenSections` in a script: the time of its stretches, in the table at the end of the run.
- `WREN_SLEEPS_FILE`, set by `test_all`: the fixed waits of the scripts, by script.
- `WREN_STARTS_FILE`, set by `test_all`: the Wren processes they start.
- `wren ctl wait load|idle|stable|quiet|selector|function|frames`, `wren ctl stats`, `wren ctl reset`, `wren ctl checkpoint`:
  [Remote control](remote.md).
- A step that fails under load and passes alone is marked `-Flaky`: it says what failed, and fails nothing.
