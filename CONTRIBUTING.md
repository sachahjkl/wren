# Contributing to Wren

## Before a pull request

- Build with `build.bat` (it builds with `-vet`), and `build.bat profile` for the profiling build.
- Run `odin run src/tools/test_all -collection:wb=src -keep-executable -out:build/test_all.exe -- -Quick` (then `build\test_all.exe -Quick`): every step must say PASS, or CACHED (it passed with exactly these
  inputs; `-NoCache` runs everything). CI runs the same suite with `-CI` on `windows-2025` ([.github/workflows/ci.yml](.github/workflows/ci.yml)).
  While you work: `-Changed`, `-Only <pattern>`, `-Failed`. How the tests run and how to go fast: [docs/testing.md](docs/testing.md).
- Several runs at once on one machine (worktrees) are fine: `test_all` takes no lock. Each test program starts the test
  server in its own process, on a block of ports of its own, derived from the worktree's path ([docs/testing.md](docs/testing.md#the-test-server)); an Odin program that needs one calls `testserver.start()` (`wb:testserver`, `src/tools/testenv`, guests: `examples/testports`), and steps run `-Jobs` at a time. Write test addresses with the default ports
  (`testenv.url("http://127.0.0.1:8765/x")`): they move with the block. Anything with a window runs on the desktop of its own
  that `src/tools/test_all` makes, or through `wrentool desktop <program> [arguments]`, so it takes no focus and no input from the person at the
  machine. No tool holds a lock: a measure (`wrentool bench ...`) is made on a machine nothing else loads.
- Tests are meant to be quick: a run prints, at its end, the slowest steps, and the job summary of a GitHub run has the same table.
  Wait for a condition, not for a delay (`wren ctl wait quiet | function`, a file that appears, a process that ends), with a
  limit; one Wren serves many scenarios, `wren ctl reset` between them ([docs/remote.md](docs/remote.md)); a step that mostly waits
  is `.Light` in `src/tools/test_all/steps.odin`; what several steps use is made once, by a step they need (`Step.needs`, `Step.makes`).
- A scenario runs in the test's process (`e2e.start`, [docs/testing.md](docs/testing.md)), and needs no new `build.bat`; start a process (`e2e.launch`) only when the check is about a process's life (crash, a
  second instance, `--policy` or a program planted in the working directory, `wren ctl stop`, `wren.com`, the channel, quit with a client connected).
  A step that needs the browser says so (`browser = true`, `.Browser` or `.Check_Browser` in `Step.needs`: built unless newer than its sources, one `build.bat` of a tree
  at a time). A capture of a playing page uses `--settle 0`
  (the next frame, not the third) and no more frames than the check needs: a frame costs 0.7 s on a runner. `build\test_steps.tsv` says how many processes each step started.
- Performance tests are opt-in: a test that asserts on a duration, a CPU time, a throughput, a latency or a count of frames in a
  window of time depends on the machine, and the CI runners are of unknown speed, so the CI never runs them (`-CI`, or the `CI`
  variable, wins over everything). Run them yourself with `build\test_all.exe -Perf` (or `WREN_PERF=1`;
  steps run one at a time so that they do not skew each other): they run with their strict bounds and print their measures; without
  it they say `perf: skipped, run with -Perf`. In Odin, `if base.perf_skip("what") { return }` (`src/base/perf.odin`). What stays in the CI is correctness (results, states, protocols, leaks,
  crashes) and waits with a generous time limit that only ends a failing run.
- UI end-to-end steps are opt-in too: a step that drives real windows and processes, or decodes heavy images under a time limit,
  needs a desktop and a machine of known speed; a shared runner failed them at random. Mark it `.Ui_Only` in `src/tools/test_all/steps.odin`: it runs
  with `build\test_all.exe -Ui` (or `WREN_UI_TESTS=1`), never on the CI (`-CI` or the `CI` variable win),
  and says `ui: skipped, run with -Ui` otherwise. The logic such a step checks keeps its unit tests, which the CI runs.
- Tests that fail at random: `.Flaky` in `src/tools/test_all/steps.odin` prints FLAKY and fails nothing, but it hides a real bug as well, so a step
  gets it only when the cause is known and outside our reach, with the reason in a comment on the step. No step has one now. To find
  the cause: run the program in a loop with CPU load beside it and several copies at once, each with a test server of its own, then
  read what the failure says (a `.Flaky` step prints its failing checks; a test program's whole output is in the step's log). What the
  marks of 2026-10 hid, as a guide to what to look for: a key or a file name several tests share (a scratch parent key deleted when it
  looked empty, a fixed folder under `TEMP` that the unit tests and their AddressSanitizer run both wrote), a handle closed twice under
  two names (the second close takes another thread's file), a wall clock against a machine's speed (a dialog's delay, a value read
  between two `wren ctl` calls, a timer of the system coarser than the time the test gives it), and in the product a limit that only
  shows under load (the engine looked at the slow-script flag every 10 000 calls, however long they took). Timing is to be measured
  within one step of the program, or not at all; a wait is on a condition, with a bound that only ends a failing run.
- A new web API starts in `api/<module>.widl`; `build.bat` regenerates the bindings, the SDK and the docs, and
  `test_all` fails when a generated file is out of date.
- A new preference is a `config.Def` in the package's `settings.odin`, registered with the others
  (`src/browser/settings.odin`); `src/browser/prefs_test.odin` checks it.
- Memory: unit tests fail on a leak or a bad free, end-to-end tools when anything is left once they have shut down
  (`testenv.mem_check`, after `host.blocking_settle`, `page.process_shutdown` and the destroys). Code that runs
  without an Odin context of its own (a thread, a C callback, a Wasm host call) starts from `base.process_context()`,
  memory shared between threads or kept by a cache comes from `base.process_allocator()`, never from
  `runtime.default_context()` / `runtime.heap_allocator()`: in the check builds those are the tracker. Data kept on
  purpose until the process ends comes from `base.permanent_allocator()`. A global map or list goes away with its
  last entry. `src\tools\endurance` shows what keeps growing while the browser runs. Arenas are `base.Arena`
  (`src/base/arena.odin`), not `core:mem/virtual`: the check builds poison what they free
  ([docs/testing.md](docs/testing.md#freed-memory-made-loud)).
- Comments say why, in English, as dense as the code around them. Commit messages are in English.
- **CHANGELOG: one fragment per change in [changelog.d/](changelog.d/README.md)**, never an edit of `CHANGELOG.md`
  (two branches that both edited `## [Unreleased]` conflicted at every merge):

  ```
  changelog.d/20261026-143000-storage-partitioning.md
  ---------------------------------------------------
  type: Added

  **Storage partitioning** (`storage.partitioned`): what a site stores while embedded in another site is kept per top-level site.
  ```

  `type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`; the text is the one entry, as it will read in the list (sub-items:
  indented `  - ` lines). `build\wrentool changelog -New -Type Added -Subject storage-partitioning -Text "..."`
  writes it; `wrentool changelog -Check` (CI and `test_all`) checks every fragment. A branch leaves `APP_VERSION` alone.
  Entries a branch from before still wrote under `## [Unreleased]` become fragments with `wrentool changelog -Migrate`
  (`-DefaultType Added`, `-Types '<line>=Fixed,...'` for the entries under no `### Type`).

## Toolchain versions

Odin is pinned to the `dev-2026-11a` release (`.github/actions/setup/action.yml`: tag and SHA-256 of the archive). To
move to another one, change both there and in the README, and build and test locally first. Wasmtime, NASM,
Lexbor, the Rust crates, webref's Web IDL, test262 and web-platform-tests are pinned in their scripts,
submodules, `native/Cargo.lock`, `native/js/webref/VERSION` and `wpt/MANIFEST.txt`. `src\tools\wpt` runs testharness tests,
and the reference tests of the folders that have them, counted apart ([docs/conformance.md](docs/conformance.md#reference-tests)).

## Making a release

1. `build\wrentool changelog -Assemble -Version X.Y.Z`: the fragments of
   `changelog.d` become the `## [X.Y.Z] - <date>` section of `CHANGELOG.md` (by type, newest first) with its link
   references at the end of the file ([Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), which
   `wrentool changelog -Check` enforces), `APP_VERSION` of
   `src/browser/about.odin` says X.Y.Z (the default `network.user_agent` follows it), and the fragments are deleted.
   Write the highlights in `docs/releases/vX.Y.Z.md` (the notes start with it, then the version's CHANGELOG section,
   then the list of changes since the previous tag, generated by `wrentool notes`: preview them with
   `-Tag vX.Y.Z -Ref HEAD`). Retake the screenshots (`wrentool shots`). Commit and push to `master`, and wait for CI to
   pass; `wrentool changelog -Check -Release X.Y.Z` says whether it is ready to tag.
2. Tag and push the tag (tags are annotated, and signed when git is configured to sign):

   ```bat
   git tag -a vX.Y.Z -m "Wren X.Y.Z"
   git push origin vX.Y.Z
   ```

3. [.github/workflows/release.yml](.github/workflows/release.yml) checks that the tag matches `APP_VERSION` and that
   the CHANGELOG was assembled for it (`wrentool changelog -Check -Release`), builds (`build.bat release`),
   runs the tests, keeps the build's map as an artifact (`wren-X.Y.Z-symbols`: it names the frames of the release's crash
   reports, [docs/crash-reports.md](docs/crash-reports.md)), packages `wren-X.Y.Z-windows-x64.zip` (`wrentool package`) with `SHA256SUMS.txt`, and publishes
   the GitHub release.

To try the package locally: `build.bat release` then `build\wrentool package -AllowUnreleased` (output in
`build\dist`; without it, a release package needs the CHANGELOG assembled for its version); a development build (plain
`build.bat`) packages only with `-Dev`. An experimental build (`wrentool experimental`) takes its notes from the
fragments (`wrentool changelog -Assemble`).

## Tools

Everything the project runs besides the compiler is one Odin program, `src/tools/wrentool`. A fresh checkout builds it with
`odin build src/tools/wrentool -collection:wb=src -out:build/wrentool.exe` (`build.bat` builds its own and runs `wrentool build`); `build\wrentool help` lists the
commands, by family:

- build: `build [dev|debug|profile|check|release]`, the browser (`build help`: the variants and the environment);
- deps: `deps`, `fetch wasmtime|wgpu|openh264|emoji`, `build lexbor|native`, `symbols`, `symbolize`, `crash-symbolize`;
- bench: `bench perf|shell|js|idle|webgl|blocker|sidebar|startup|cadence` (`bench help`): opt-in measures, never in the CI;
- capture, shots, compare: a page rendered headless to a PNG, the README's and the site's pictures, Wren against Edge;
- threadtime: whose work the window thread did in a load, from the files of `WREN_SPANS` (`waterfall -AfterMs n` gives the page the time to settle): by origin and class, up to the first contentful paint, the largest and settled; the frames begun and their own work by phase, their waits apart;
- replay: `record`, `run`, `lists`: a load served again from what a site served, seeded, to prove a change of a percent ([the bench](docs/testing.md#the-replay-bench));
- sweep: real pages visited headless as a person does (`-List tools/site_compare_list.txt`, `-Shard i -Shards n`, `-OneProcess`): crashes, hangs, unclean ends, the time of each step, in `build/sweep/summary_<shard>.tsv`;
- gen: `gen psl|unicode|media-fixtures|video-fixtures|perf-media|rust-crates`;
- docs and checks: `docs` (the documentation site), `license`, `i18n`, `portability`, `engine test262|rx-diff`, `changelog`;
- release helpers: `package`, `sign`, `winget`, `notes`, `experimental`, `smoke`, `crash-e2e`;
- `desktop <program> [arguments]`: a command on a Windows desktop of its own.

The only script left is `tools/make_logo.ps1` (GDI+ drawing of the committed assets).

## Submodules

`ext/gui_toolkit` follows tagged releases of [gui_toolkit](https://github.com/sachahjkl/gui_toolkit): a toolkit
commit must be pushed there (on `master`, with its tag) before `master` points to it here, or fresh clones cannot check
the submodule out.
