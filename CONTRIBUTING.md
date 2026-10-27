# Contributing to Wren

## Before a pull request

- Build with `build.bat` (it builds with `-vet`), and `build.bat profile` for the profiling build.
- Run `powershell -NoProfile -File tools\test_all.ps1 -Quick`: every step must say PASS. CI runs the same suite with
  `-CI` on `windows-2025` ([.github/workflows/ci.yml](.github/workflows/ci.yml)).
- Several runs at once on one machine (worktrees) are fine: `test_all.ps1` takes no lock. Its test server listens on
  a block of ports of the run (`-BasePort`, default derived from the worktree's path; `-CI`: 8765), the tools read it
  from `WREN_TEST_BASE_PORT` (`src/tools/testenv`, guests: `examples/testports`), and steps run `-Jobs` at a time, each
  server-backed step with a server of its own. Write test addresses with the default ports
  (`testenv.url("http://127.0.0.1:8765/x")`): they move with the block. Scripts that use the real desktop
  (`screenshot.ps1`, `history_e2e.ps1`) or measure performance (`perf.ps1`, `js_bench.ps1`, `cfg_bench.ps1`) take
  `desktop.lock` / `bench.lock` themselves, only for that part (`tools/test_env.ps1`, which also starts a test server
  on a free block: `Start-WrenTestServer`). A step that needs either goes through those scripts or `Use-WrenLock`.
- Tests are meant to be quick: a run prints, at its end, the slowest steps and (for the scripts that time themselves with `Section`
  / `Show-WrenSections` of `tools/test_env.ps1`) the slowest sections, and the job summary of a GitHub run has the same table.
  Wait for a condition, not for a delay (`wren ctl wait quiet | function`, a file that appears, a process that ends), with a
  limit; one Wren serves many scenarios, `wren ctl reset` between them ([docs/remote.md](docs/remote.md)); a step that mostly waits
  is `-Light` in `test_all.ps1`; do not build twice what a run already built (`Test-WrenBuildFresh`, `Invoke-WrenBuildIfStale`).
- A scenario does not get a Wren of its own, nor a new `build.bat`. Drive one shared Wren (`Start-Shared`, `Reset-Shared` in `tools/remote_e2e.ps1`)
  and `wren ctl reset` (or `checkpoint restore`) between scenarios; start a process only when the check is about a process's life (crash, a
  second instance, `--policy` or a program planted in the working directory, `wren ctl stop`, `wren.com`, quit with a client connected).
  Build the browser through `Ensure-WrenBuild [dev|check]` (`tools/test_env.ps1`: built unless newer than its sources, one `build.bat` of a tree
  at a time): two steps of a parallel run that both call `build.bat` refuse each other's files. A capture of a playing page uses `--settle 0`
  (the next frame, not the third) and no more frames than the check needs: a frame costs 0.7 s on a runner. `test_all` prints how many Wren it started.
- Performance tests are opt-in: a test that asserts on a duration, a CPU time, a throughput, a latency or a count of frames in a
  window of time depends on the machine, and the CI runners are of unknown speed, so the CI never runs them (`-CI`, or the `CI`
  variable, wins over everything). Run them yourself with `powershell -NoProfile -File tools\test_all.ps1 -Perf` (or `WREN_PERF=1`;
  steps run one at a time so that they do not skew each other): they run with their strict bounds and print their measures; without
  it they say `perf: skipped, run with -Perf`. In Odin, `if base.perf_skip("what") { return }` (`src/base/perf.odin`); in a script,
  `Check-Perf` / `Test-WrenPerf` (`tools/test_env.ps1`). What stays in the CI is correctness (results, states, protocols, leaks,
  crashes) and waits with a generous time limit that only ends a failing run.
- UI end-to-end steps are opt-in too: a step that drives real windows and processes, or decodes heavy images under a time limit,
  needs a desktop and a machine of known speed; a shared runner failed them at random. Mark it `-UiOnly` in `test_all.ps1`: it runs
  with `powershell -NoProfile -File tools\test_all.ps1 -Ui` (or `WREN_UI_TESTS=1`), never on the CI (`-CI` or the `CI` variable win),
  and says `ui: skipped, run with -Ui` otherwise. The logic such a step checks keeps its unit tests, which the CI runs.
- A new web API starts in `api/<module>.widl`; `build.bat` regenerates the bindings, the SDK and the docs, and
  `test_all.ps1` fails when a generated file is out of date.
- A new preference is a `config.Def` in the package's `settings.odin`, registered with the others
  (`src/browser/settings.odin`); `src/browser/prefs_test.odin` checks it.
- Memory: unit tests fail on a leak or a bad free, end-to-end tools when anything is left once they have shut down
  (`testenv.mem_check`, after `host.blocking_settle`, `page.process_shutdown` and the destroys). Code that runs
  without an Odin context of its own (a thread, a C callback, a Wasm host call) starts from `base.process_context()`,
  memory shared between threads or kept by a cache comes from `base.process_allocator()`, never from
  `runtime.default_context()` / `runtime.heap_allocator()`: in the check builds those are the tracker. Data kept on
  purpose until the process ends comes from `base.permanent_allocator()`. A global map or list goes away with its
  last entry. `tools\endurance.ps1` shows what keeps growing while the browser runs.
- Comments say why, in English, as dense as the code around them. Commit messages are in English.
- **CHANGELOG: one fragment per change in [changelog.d/](changelog.d/README.md)**, never an edit of `CHANGELOG.md`
  (two branches that both edited `## Unreleased` conflicted at every merge):

  ```
  changelog.d/20261026-143000-storage-partitioning.md
  ---------------------------------------------------
  type: Added

  **Storage partitioning** (`storage.partitioned`): what a site stores while embedded in another site is kept per top-level site.
  ```

  `type` is `Added`, `Changed`, `Fixed` or `Removed`; the text is the one entry, as it will read in the list (sub-items:
  indented `  - ` lines). `powershell -File tools\changelog.ps1 -New -Type Added -Subject storage-partitioning -Text "..."`
  writes it; `tools\changelog.ps1 -Check` (CI and `test_all`) checks every fragment. A branch leaves `APP_VERSION` alone.
  Entries a branch from before still wrote under `## Unreleased` become fragments with `tools\changelog.ps1 -Migrate`
  (`-DefaultType Added`, `-Types '<line>=Fixed,...'` for the entries under no `### Type`).

## Toolchain versions

Odin is pinned to the `dev-2026-10` release (`.github/actions/setup/action.yml`: tag and SHA-256 of the archive). To
move to another one, change both there and in the README, and build and test locally first. Wasmtime, NASM, Zig,
QuickJS-ng, Lexbor, the Rust crates, webref's Web IDL, test262 and web-platform-tests are pinned in their scripts,
submodules, `native/Cargo.lock`, `native/js/webref/VERSION` and `wpt/MANIFEST.txt`. A new QuickJS-ng or wasi-libc
(Zig) version: update the license texts of `native/js/licenses` too.

## Making a release

1. `powershell -File tools\changelog.ps1 -Assemble -Version X.Y.Z` (semantic versioning): the fragments of
   `changelog.d` become the `## X.Y.Z - <date>` section of `CHANGELOG.md` (by type, newest first), `APP_VERSION` of
   `src/browser/about.odin` says X.Y.Z (the default `network.user_agent` follows it), and the fragments are deleted.
   Write the highlights in `docs/releases/vX.Y.Z.md` (the notes start with it, then the version's CHANGELOG section,
   then the list of changes since the previous tag, generated by `tools/release_notes.ps1`: preview them with
   `-Tag vX.Y.Z -Ref HEAD`). Retake the screenshots (`tools\shots.ps1`). Commit and push to `master`, and wait for CI to
   pass; `tools\changelog.ps1 -Check -Release X.Y.Z` says whether it is ready to tag.
2. Tag and push the tag (tags are annotated, and signed when git is configured to sign):

   ```bat
   git tag -a vX.Y.Z -m "Wren X.Y.Z"
   git push origin vX.Y.Z
   ```

3. [.github/workflows/release.yml](.github/workflows/release.yml) checks that the tag matches `APP_VERSION` and that
   the CHANGELOG was assembled for it (`changelog.ps1 -Check -Release`), builds (`build.bat release`),
   runs the tests, keeps the build's map as an artifact (`wren-X.Y.Z-symbols`: it names the frames of the release's crash
   reports, [docs/crash-reports.md](docs/crash-reports.md)), packages `wren-X.Y.Z-windows-x64.zip` (`tools/package.ps1`) with `SHA256SUMS.txt`, and publishes
   the GitHub release.

To try the package locally: `build.bat release` then `powershell -File tools\package.ps1 -AllowUnreleased` (output in
`build\dist`; without it, a release package needs the CHANGELOG assembled for its version); a development build (plain
`build.bat`) packages only with `-Dev`. An experimental build (`tools\experimental.ps1`) takes its notes from the
fragments (`tools\changelog.ps1 -Assemble`).

## Submodules

`ext/gui_toolkit` follows tagged releases of [gui_toolkit](https://github.com/sachahjkl/gui_toolkit): a toolkit
commit must be pushed there (on `master`, with its tag) before `master` points to it here, or fresh clones cannot check
the submodule out.
