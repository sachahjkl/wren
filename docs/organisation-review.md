# Review of the organisation of the project

Date: 2026-11-12. Method: static review. Nothing was built or run. No file was changed but this one.

Sources: `AGENTS.md`, `CONTRIBUTING.md`, `docs/architecture.md`, `docs/portability.md`, `docs/testing.md`,
`docs/test-review.md`, the `import` lines of each package of `src`, `src/tools`, `api`, `native`, `tools`, `.github`,
and `ext/gui_toolkit` at tag `v0.202.0`.

Limits:

- A count comes from `grep` or `wc` on the tree. It is exact for the pattern and approximate for the concept.
- A cost is an estimate in days of work for one person. No cost was measured.
- A statement that a procedure runs on the loop thread comes from its callers, not from a run.

The subject is the organisation: boundaries, ownership, duplicated mechanisms, tools, names. Speed of code is not
the subject. `docs/test-review.md` covers the speed and the bounds of the tests: this review does not repeat it.

## Summary

| # | Finding | Proposal | Cost |
|---|---|---|---|
| 1 | The page embedder is built in 5 places. The navigation algorithm exists twice. | One package `embed`: the browser with no shell. | 10 to 15 days |
| 2 | `src/browser` is one package of 235 files. `App` has about 170 fields. `the_app` has 1092 uses. | Split in 8 packages, leaf packages first. | 20 to 30 days, in slices |
| 3 | Files are written in 4 ways. Some writes run on the loop thread. | One writer for each profile file. A check build asserts the thread. | 4 to 6 days |
| 4 | Preferences are read in 3 ways. | Keep the settings struct with one watch for each group. | 5 to 8 days |
| 5 | Frames are requested with a count: 317 calls, counts 0 to 4. | Request a frame with a cause and a condition. | 5 to 8 days |
| 6 | Wren has its own copy of systems that the toolkit has. Wren holds systems that the toolkit must own. | Use the toolkit's packages. Move 6 systems. | 8 to 12 days |
| 7 | The product imports `tools` packages. Win32 types are in neutral files. | Move 3 packages. Remove 5 imports. | 2 days |
| 8 | The web API has two sources. A dead C emitter stays. | Finish the move to one source. Delete the other. | 2 to 3 days |
| 9 | 25 programs exist beside `wrentool`. Versions are pinned in 8 places. | One table of programs. One file of pins. | 3 to 5 days |
| 10 | The rules of shared memory are not written. The globals lint covers 6 of 40 packages. | Write the rules. Extend the lint. | 3 days |

Findings 11 to 14 (the split of `src/page`, the names, the documents, the dialogs) follow in the text.

## The key prompts

**What a principal architect rewrites first.** The layer between `page` and the shell (finding 1). Each program
that shows a page builds that layer by hand. The shell and the test tools then run different code for one concept.
All other splits depend on this layer.

**The single test that breaks the design.** Run one table of navigation cases against a tab of the shell and
against a `headless.Doc`. Compare the two event traces. The cases are: a redirect, a download, an error status, a
traversal to a cached document, `window.open`, `Cache-Control: no-store`. The traces differ, because two
implementations exist (`src/browser/main.odin:830`, `src/tools/headless/headless.odin:256`). The web-platform-tests
run on the second one (`src/tools/wpt` imports `wb:tools/headless`). A navigation test that passes there proves
nothing about the product.

A second test, for finding 3: in the check build, each file procedure of `base` asserts that the caller is not the
loop thread after the first frame. The test fails at the first save of a notification decision
(`src/browser/notification_shell.odin:241`).

**The abstraction that removes a class of problems.** An `Embedder`: a loop, a network client, a blocking pool, a
Fetch profile, a loader, the pages, and a `Navigation` for each top-level window. `App` contains one. A test
contains one. This removes: the harnesses that break when an invariant is added, the navigation written twice, and
most uses of `the_app` in hooks.

**The implicit state machines.** See the table in "Implicit state machines".

## 1. The page embedder is built in 5 places, and navigation exists twice

Value: highest. This is a correctness risk and the cause of the harness failures that `docs/test-review.md` 5.1
describes.

Evidence. Each of these builds a loop, a network client, a blocking pool, a Fetch profile, a loader and the Wasm
imports, in its own order:

| Place | Location |
|---|---|
| The shell | `src/browser/main.odin:1726` (`app_start`, 228 lines), `src/browser/process_share.odin:74` |
| The headless tools (WPT, `jspage`, `blockerpages`) | `src/tools/headless/headless.odin:102` (`init`) |
| The web tests | `src/tools/e2e/web_harness.odin:79` (`begin`), with the world in package variables at lines 58 to 75 |
| `apiconformance` | `src/tools/apiconformance/main.odin:35-43` |
| `fetch` tool | `src/tools/fetch/main.odin:95-99` |

The navigation of a top-level window exists twice:

- The shell: `document_event` (`src/browser/main.odin:830`), `document_loaded` (`:905`), `navigate` (`:514`),
  `src/browser/tab_navigation.odin`, `src/browser/history_restore.odin`, `src/browser/bfcache.odin`.
- The headless package: `document_event` (`src/tools/headless/headless.odin:256`), `navigation_start` (`:237`),
  `leave` (`:302`), `bfcache_start` (`:328`), `bfcache_restore` (`:341`).

Both call `page.navigable_keep_window`, `page.apply_response_headers` and `page.apply_isolation_headers` in the
same order. The shell also sets the navigation timing, the preload scan, the download action and `no_store`. The
headless package does not. The two copies will diverge more with each change.

`app_make.odin` solved this problem for `App` only. Its comment says why
(`src/browser/app_make.odin:3-7`). The same defect remains one layer below.

Proposal. Add a package `src/embed` between `page` and `browser`:

- `embed.World`: the loop, the client, the blocking pool, the profile, the loader, the storage manager, the
  `page.Pages`, the process scope. One `world_make(Options)` and one `world_free`. Stages are not necessary: a
  program sets `Options` (profile directory, preferences, in-memory cache).
- `embed.Navigation`: the state of one top-level window. It holds the session history, the document in flight, the
  back/forward cache and the phase (`Nav_Phase` of `src/browser/tab_navigation.odin:23`). It reports events to its
  owner through a small table of procedures: `adopted`, `failed`, `download`, `title`, `status`.
- `Tab` contains an `embed.Navigation`. `headless.Doc` becomes a thin wrapper, then is removed.
- `process_share.odin` moves to `embed`: it has no dependency on the interface.

`browser.App` contains an `embed.World`. `web_harness.odin`, `apiconformance` and `fetch` call `world_make`.

Extend `src/tools/test_all/lint_app_make.odin`: no `host.loop_init`, `fetch.loader_init` or
`page.register_imports` outside `src/embed` and the unit tests of those packages.

Cost: 10 to 15 days. Do it in three steps that each keep a working product: `World` first (3 days), then
`Navigation` with the shell as its only user (5 to 8 days), then the headless package on top of it (3 days).

## 2. `src/browser` is one package that holds 8 subsystems

Evidence:

- 235 files that are not tests, 78 test files, 85 826 lines in total.
- `App` (`src/browser/main.odin:147-311`) has about 170 fields. 60 of them are the state of one subsystem, each
  with a comment that names the owner file.
- `the_app` has 1092 uses in 88 files. The top files are `newtab_art.odin` (107), `devtools_net_detail.odin` (70)
  and `devtools_kit.odin` (65). `docs/architecture.md` says that `the_app` is "what is left". It is the main access
  path for the developer tools and the painter.
- `main.odin` has 2145 lines. It holds the tab life cycle, the navigation, the document load, the page input
  (`route_page_input`, line 1220), the profile save, the preferences, the frame (`frame`, line 1498, 180 lines)
  and the start.
- The file names already show the units: 25 `devtools_*` files, 10 `tab_*`, 8 `remote_*`, 8 `blocker_*`, 8
  `about_*`, 4 `cdp_*`, 4 `paint_*`, 27 `*_shell` files.
- The classes of `tools/globals_allowed.txt` show one unit clearly. 12 of the 16 `thread` globals of `browser`
  belong to "the thread that paints" (`compositor.odin`, `paint_planes.odin`, `paint_masks.odin`, `shaders.odin`,
  `forms_plane.odin`, `canvas_shell.odin`).

One package means no boundary. Any file can read and write any field of `App`. A test of the bookmarks store must
link the renderer.

Proposal. Split by ownership of state. Each new package has its own state struct and takes what it needs as
parameters. No new package takes `^App`.

| Package | Content | Depends on |
|---|---|---|
| `profile` | The stores of a profile with no interface: `profile_writes`, `session`, `global_history`, `bookmarks`, `closed_tabs`, `search_engines`, the model of `download`, `crash_recovery`, `update_check`, the decisions of `notification_shell` | `host`, `base`, `fetch` |
| `embed` | Finding 1: the world, the navigation, `tab_navigation`, `history_restore`, `bfcache`, `process_share` | `page`, `fetch`, `net` |
| `paint` | The page painter and the compositor: `render`, `compositor`, `paint_*`, `effects_cache`, `text_decoration`, `shaders`, `canvas_gpu`, `canvas_shell`, `images_shell`, `video_shell`, `video_fast_path`, `fonts`, `web_font_faces`, `gpu_steps`, `forms_plane` | `layout`, `page`, the toolkit |
| `pageview` | One page in one window: `page_input`, `page_frame`, `page_cursor`, `page_autoscroll`, `pointer_gesture`, `smooth_scroll`, `selection_shell`, `touch_shell`, `frames_shell`, `first_paint`, `shell_shown`, `shell_frames` | `paint`, `embed` |
| `inspector` | The developer tools: the 25 `devtools_*` files, `console_eval` | `pageview`, `embed` |
| `control` | Automation: `remote_methods`, `remote_shell`, `remote_state`, `remote_timeline`, `remote_extras`, `control`, `control_window`, the 4 `cdp_*` files | `embed`, `remote` |
| `views` | The `about:` pages: `config_ui`, `settings_page`, `history_ui`, `history_tree`, `downloads_ui`, `bookmarks_ui`, `blocker_dashboard`, `blocker_ui`, `blocker_picker`, `http_cache_ui`, `site_data_ui`, `search_engines_ui`, `about_*`, `newtab_art*`, `demos`, `error_pages`, `ext_page` | `profile`, the toolkit |
| `browser` | The composition root: `main`, `app_make`, `windows`, `chrome`, the tab strip and sidebar, `urlbar`, `status_bar`, `commands`, `palette`, `context_menu`, the prompts, `settings` | all of the above |

The name `inspector` avoids a conflict with the toolkit's package `devtools`
(`ext/gui_toolkit/src/devtools/devtools.odin:14`).

Order. Odin has no cyclic imports, so a unit can leave only when it does not read `App`.

1. `profile` first: its files take `^App` mostly for `profile_dir`, `cfg.persist_profile`, the blocking pool and
   the toast. Give them a `profile.Store` with those four things. 4 to 5 days.
2. `paint` second: it already keeps its state apart (thread globals, `App.page_render`, the settings structs at
   `main.odin:262-270`). 5 to 7 days.
3. `control` and `inspector` after finding 1, because both read tabs and navigations. 4 to 6 days each.
4. `views` and `pageview` last.

Cost: 20 to 30 days in total. Each step is a move of files with a change of signatures. Each step keeps the product
working. Do not start a step before finding 1, step 1.

A rule to add to `docs/architecture.md`: a new subsystem of the shell is a new package with its own state. It is
not a new group of fields of `App`.

## 3. Files are written in 4 ways, and some writes run on the loop thread

`AGENTS.md` says that no disk call runs on the interface thread, "not even a `stat`".

Evidence. The four ways:

1. `Profile_File` (`src/browser/profile_writes.odin:1-13`): the blocking pool, one write at a time, an atomic
   replace, a retry with a growing delay, one report to the user, a flush at exit. This is the complete design.
   Only the preferences file, the session files and the extensions' files use it (`src/browser/ext_shell.odin:119`).
2. A job written by hand on the blocking pool with `base.file_write_atomic`: the history
   (`src/browser/global_history.odin:356`, with its own retry at `:440-443`), the bookmark export
   (`src/browser/bookmarks_ui.odin:473`), the Vault (`src/vault/vault.odin:1021`, not atomic).
3. `base.file_write_atomic` called directly: `src/browser/cdp_targets.odin:166`, `src/cookies/jar.odin:417`,
   `src/fetch/hsts.odin:157`, `src/page/storage.odin:271`.
4. `os.write_entire_file`, which is not atomic: 43 calls outside tests and tools.

Writes of the fourth kind that run on the loop thread, by their callers:

| Location | File written |
|---|---|
| `src/browser/update_check.odin:101` (called at `:134`, `:159`) | The state of the update check |
| `src/browser/setup.odin:107` (called at `:136`, `:146`, `:151`) | The answer of the Setup dialog |
| `src/browser/notification_shell.odin:241` (called at `:95`) | The notification decisions |
| `src/page/service_worker.odin:236` and `:245` (8 callers, for example `:556`, `:850`) | The registrations, and each worker script |
| `src/page/storage_buckets.odin:66` and `:69` | The storage buckets |
| `src/browser/license_shell.odin:112` | A marker file |

A crash during one of these writes leaves a file cut short. The service worker registry is the largest risk: the
file is rewritten at each state change of a registration.

Reads have the same defect in smaller number, for example `os.exists` at `src/browser/download.odin:499` and a
directory read at `src/browser/newtab_art.odin:1053`.

Proposal:

- Keep way 1. Move `Profile_File` to the `profile` package of finding 2, then to the toolkit (finding 6): the
  toolkit's `store` package has the same design with a `Writer` for a file that the program formats
  (`ext/gui_toolkit/src/store/store.odin:1-12`).
- Each file of the profile has one `Profile_File` and one owner. The six writes of the table use it.
- `page` receives the writer from its embedder (`Storage_Manager` already takes the loop and the blocking pool).
- Diagnostic outputs (`prof.odin`, `memcheck_report_*`, `remote_timeline.odin`) can stay as direct writes: a
  developer asks for them. Mark each with one named procedure, `diag_write`, so that the lint below can see the
  difference.
- Add a lint to `test_all`: no `os.write_entire_file`, `os.rename` or `os.remove` in `src` outside `base`, the
  writer, and `diag_write`.
- Add the assertion of "The key prompts" to the check build.

Cost: 4 to 6 days. The lint and the assertion take 1 day and find the complete list.

## 4. Preferences are read in 3 ways

Evidence:

1. A settings struct made by `settings_from_prefs`. 65 such procedures exist, 23 of them in `src/browser`.
   `apply_prefs` (`src/browser/main.odin:1397-1421`) rebuilds the structs of `fetch`, `cookies`, `page` and the shell
   at each change of any preference, through one watch on the empty prefix (`:1851`). It then restyles every tab
   (`:1410`) and requests 3 frames.
2. A watch on a prefix that rebuilds one struct: 30 `config.watch` calls in `src/browser`, with the watch ids in
   four different places of `App` (`watches`, `font_watch`, `text_watch`, `look_watch`, `main.odin:204`, `:278-279`).
3. A read by name at the point of use: about 131 of the 426 by-name reads of `src/browser` are outside a settings
   procedure. Examples: `src/browser/commands.odin:135`, `:618-620`, `src/browser/cdp.odin:96-102`,
   `src/browser/closed_tabs.odin:137`.

A fourth mechanism routes a change: `pref_groups_of` (`src/browser/prefs_apply.odin:18-27`) maps a name to one of 4
groups by its prefix. The 30 watches do the same work with other prefixes.

Drift from the documents: `docs/architecture.md:31-33` and `AGENTS.md` say that a preference is declared in the
package's `settings.odin`. 52 files of `src/browser` declare a `config.Def` table outside `settings.odin`.

Each by-name read is a string that the compiler does not check. A renamed preference fails at run time, and
`config.ref_of` runs a map lookup at each read.

Proposal. Keep way 2 as the only way, with one form:

- One declaration for each group: the `Def` table, the struct, the reader and the prefix. For example
  `config.group(&prefs, "browser.urlbar.", URLBAR_DEFS, &app.ub.cfg, urlbar_settings_read, on_change)`.
- The registry keeps the watch. The owner keeps only the struct. The four places of watch ids in `App` go away.
- `apply_prefs`, `pref_groups_of` and the watch on the empty prefix are removed. Each group reads its own prefix.
- A read by name stays legal in two places: the generic views (`config_ui.odin`, the settings page) and a command
  that toggles one preference.
- Add a lint: no `config.*_of(` outside a file that declares the `Def` of that name.
- Decide where a table lives, then say it in one document: in the file of its subsystem, as the code does now.
  Correct `docs/architecture.md` and `AGENTS.md`.

`config.group` belongs to the toolkit's `config` package: each program of the toolkit has this need.

Cost: 5 to 8 days. Most of it is mechanical. The removal of `apply_prefs` needs care: it also arms the autosave and
sets the timer slice.

## 5. Frames are requested with a count

Evidence. `request_frames(app, n)` (`src/browser/windows.odin:233`) has 317 calls: 172 with `n = 2`, 73 with 3, 10
with 1, 9 with 4, 1 with 0. The count says "the result needs n frames to settle". The caller cannot know that
number. The comment at `src/browser/main.odin:1548-1549` records one failure of this design: two frames every half
second, for ever.

A second, better mechanism exists beside it: `Frame_Causes` (`main.odin:1557-1564`) and `Frame_Errand`
(`src/browser/windows.odin:217`). They say why a frame is made.

The target of a request is also implicit. `request_frames` chooses the active window, or the window of the page
whose task runs (`windows.odin:234-242`, with `App.tasks_running` and `App.task_own`).

`docs/test-review.md` 1.1 asks for an `at_rest` condition. That condition cannot be computed while pending work is
a count.

Proposal:

- `invalidate(window, cause)`: one frame, with a cause. Used by a change that one frame shows.
- `animate(window, key, until)`: frames while a condition holds. The condition is a procedure or a deadline of the
  loop's clock. Used by what settles over time.
- A callback names its window. The inference from `App.tasks_running` goes away.
- `at_rest` is then: no invalidation, no animation, no timer that draws.

Remove `request_frames` when the last caller is moved. Do not keep both.

Cost: 5 to 8 days. Start with the 73 calls that ask for 3 frames: each one hides a settle condition.

## 6. The toolkit: copies to remove, and systems to move

`AGENTS.md` says: a system that more than one program will use moves to `gui_toolkit`.

Wren has its own copy of what the toolkit has:

| Wren | Toolkit | Note |
|---|---|---|
| `src/tools/wrentool/changelog` (862 lines, plus 320 of tests) | `src/changelog` (`tk_changelog`, 477 lines) | The same fragment format, word for word in the header comments. |
| `src/tools/wrentool/release` (`package`, `notes`) | `src/release` (`tk_release`: `package`, `notes`, `ship`) | |
| `src/tools/test_all/lint_globals.odin`, `lint_unicode_case.odin`, with `tools/globals_allowed.txt` | `tests/globals`, with `tools/globals_allowed.txt` and `tools/unicode_case_allowed.txt` | Two implementations of one lint. |
| The scheduler of `src/tools/test_all` (643 lines), its desktop of its own | `tools/run_tests` (429 lines), with the same `desktop_*` files | |
| `extract_flag`, `extract_switch` (`src/browser/main.odin:1683-1697`) | `src/cli` | `--help` and the refusal of an unknown option come free. |
| The CDP server of `src/browser/cdp*.odin` | `src/devtools` (a CDP server), `src/cdp` (a client) | Verify what the two servers can share: the handshake, the `/json` endpoints, the loopback guard. |

Wren holds systems that another program of the toolkit needs:

| System | Location | Why it is generic |
|---|---|---|
| The event loop with timers, scopes of work, the blocking pool, the dialog threads, named threads, the thread pool | `src/host` (2411 lines) | No web concept. `AGENTS.md` forbids blocking work on the interface thread in each program: each program needs this pool. |
| Scopes and generational handles | `src/base/scope.odin`, the pool and handle files of `src/base` | Rule 1 and rule 2 of `docs/architecture.md` are not about the web. |
| The profile file writer | `src/browser/profile_writes.odin` | Merge it with `tk_store.Writer`: one has the retry and the report, the other has the debounce. |
| Crash reports and stacks | `src/tools/crashtrace` (1289 lines), `src/tools/stacks` | The product links both. Any program of the toolkit can crash. |
| The test scheduler with its cache and its lints | `src/tools/test_all` | See the table above. |
| The poison allocator and the tracker | `src/base/poison.odin` | The toolkit has `arena` and `testkit` already. |

A name conflict blocks the first row. The toolkit has packages named `host` and `base`
(`ext/gui_toolkit/src/host/host.odin:31`, `src/base/perf.odin:3`), and Wren has `wb:host` and `wb:base`. The comment of
`src/config/config.odin` says that a package name is unique in a build. Rename the toolkit's window host first, for
example to `tk_window_host`, then move Wren's loop under a name that says what it is, for example `tk_loop`.

Alias packages: `src/config` (81 lines), `src/i18n` (16), `src/update` (23) and `src/tools/tooling` re-export a
toolkit package. They exist so that callers keep `wb:` imports. `src/browser` imports the toolkit with the
`toolkit:` collection, and `src/base` imports it with a relative path (`../../ext/gui_toolkit/src/arena`). Use one
way: the `toolkit:` collection in each package, and remove the alias packages. `AGENTS.md` asks for no
compatibility layer.

Cost: 2 days for the changelog and release copies. 1 day for the alias packages. 3 to 4 days for `host` with the
rename. 2 days for crash reports. 3 to 5 days for the test scheduler. Each move needs a toolkit tag before Wren
points to it.

## 7. Layering violations

The import graph has no cycle. Odin refuses one. The violations are imports in the wrong direction of meaning.

| Violation | Evidence | Proposal |
|---|---|---|
| The product imports a tool | `src/browser/main.odin:41`, `process_share.odin:8`, `prof.odin:35` import `wb:tools/crashtrace` | Move `crashtrace` out of `tools` (finding 6). |
| A library imports a tool | `src/remote/api/process_windows.odin:11` imports `wb:tools/stacks` | The same. |
| Unit tests of core packages import a tool | `src/page/web_test.odin`, `src/js/js_test.odin`, `src/wasm/wasm_test.odin` import `wb:tools/testenv` | Move `testenv` beside `src/testserver`, as `src/testkit`. |
| Policy imports a feature | `src/fetch/extension_scheme.odin:28-42` reads `extensions.Image`, `extensions.Registry` | Acceptable if `extensions` stays a data package (it imports only `base`, `config`, `url`). Write that rule in its header. |
| A feature sits above the engine | `src/blocker` imports `page`, `dom`, `style`, `html`, `fetch`, `net` | Correct direction. It works through `fetch.Interceptor` and the page hooks. No change. |
| Win32 types in a neutral struct | `App.cmd_hwnd`, `App.drop_hwnd` are `win.HWND` (`src/browser/main.odin:247-248`) | Keep each in a struct that its `*_windows.odin` file declares, with an empty struct in `*_other.odin`. |
| `core:sys/windows` in neutral files | `main.odin:13`, `windows.odin:29`, `prof.odin:28`, `devtools_window.odin:14`, `instance_shell.odin:33`; 19 uses of `ODIN_OS` in 13 files of `src/browser` | Move each use to a file with a system suffix, as `AGENTS.md` asks. |
| A URL package depends on the script engine | `src/url` imports `wb:engine/regexp` and `wb:engine/unicode` for `URLPattern` (5 `pattern*.odin` files) | Move `URLPattern` to `src/urlpattern`. `cookies`, `csp` and `webauthn` then do not link the regular expression engine. |
| The engine depends on the registry | `src/engine/frontend`, `regexp`, `unicode` import `wb:config` | Acceptable: a `Def` table is data. No change. |
| Two packages with one name | `src/e2e` is `package e2e`; `src/tools/e2e` is `package e2e_scenarios` | Rename the folder `src/tools/e2e` to `src/tools/e2e_scenarios`. |

Cost: 2 days for all rows.

## 8. Generated code and its sources

Evidence:

- The web API has two sources. `api/` holds 78 `.widl` files and 77 `.odin` files (6972 lines). The header of each
  `.odin` file says: "The Odin form is the source of truth once the .widl is removed" (`api/abort.odin:1`).
  `bindgen` reads the `.widl` files (`src/tools/bindgen/main.odin:66`, `:128`). `AGENTS.md` and `CONTRIBUTING.md` say
  that a new API starts in a `.widl` file. A change made in the `.odin` file has no effect.
- A dead emitter stays. `bindgen -emit:c` writes `native/js/gen/bindings.c` and `wren_api.h`
  (`src/tools/bindgen/main.odin:39`, `:70`, `:321-322`). The comment says "no longer used". The folder `native/js/gen`
  does not exist.
- The names of generated files have five forms: `api_generated.odin`, `bindings_gen.odin`, `cexport_gen.odin`,
  `atoms_table.odin`, `opcodes.odin`. A lint cannot find them by name.
- Two generated files name no generator that exists in the tree. `src/engine/jscapi/cexport_gen.odin:3` says "by a
  script". `src/engine/jsrt/atoms_table.odin:3` and `opcodes.odin:3` name QuickJS headers.
- Generators are in three places: `src/tools/bindgen`, `src/tools/wrentool/gen`, and `src/engine/unicode/gen`, a
  program inside the engine's tree.
- `src/page/api_generated.odin` has 45 233 lines: 43 % of the package `page`.
- Generated output is committed in four trees: `sdk/` (61 files), `docs/api/` (62 files), `site/` (600 files, 17
  MB), `native/js/odin/bindings_gen.odin` (32 803 lines). `test_all` checks that each is up to date. This is a
  choice, and it is consistent.
- `native/` holds the Rust workspace and, in `native/js/odin`, the Odin glue of the script engine.
  `docs/architecture.md` calls `native/` "the Rust library". The glue is Odin compiled to Wasm: it is not native.

Proposal:

- Finish the move in one commit: point `bindgen` at `api/*.odin`, run `-verify-roundtrip` once, delete the `.widl`
  files, the converter and the round-trip check. Or delete the 77 `.odin` files. Do not keep both. The `.odin`
  form removes a parser (`src/tools/bindgen/webidl` stays for webref), so the first option is preferable.
- Delete `-emit:c` and `emit_c.odin`.
- One suffix: `*_generated.odin`. One first line: `// Code generated by <tool> from <source>. DO NOT EDIT.` Add a
  lint in `test_all`: a file with that line has that suffix, and its generator exists.
- Write the generators of `cexport_gen.odin`, `atoms_table.odin` and `opcodes.odin` as `wrentool gen` commands, or
  declare the three files as written by hand.
- Move `src/engine/unicode/gen` to `src/tools/wrentool/gen`.
- Keep `api_generated.odin` in `page`. A package of its own is not possible: the generated types hold pointers to
  the types of `page` (`Api_AbortController.data: ^Abort_Controller`, `src/page/api_generated.odin:22-25`) and the
  trampolines call the `lookup_*` procedures of `page`. The import would be cyclic.
- Move `native/js/odin` to `src/engine/glue`. `native/` is then only Rust.

Cost: 2 to 3 days. The move of the glue is 1 day more, mostly paths in the builder.

## 9. Tooling

Evidence:

- `CONTRIBUTING.md:113` says: "Everything the project runs besides the compiler is one Odin program". 25 programs
  with a `main` exist in `src/tools` beside `wrentool`: `test_all`, `bindgen`, `buildjs`, `jsengine`, `test262`,
  `wpt`, `e2e`, `apiconformance`, `docsite`, `license`, `endurance`, `crashmodes`, `blockerpages`, `adblockbench`,
  `mediabench`, `mediaplay`, `wasmbench`, `cssaudit`, `fetch`, `runwasm`, `jspage`, `wrencom`, and others.
- `wrentool` starts some of them by a path in a string: `tool_run("src/tools/license", ...)`
  (`src/tools/wrentool/gen/gen.odin:311`), `tool_run("src/tools/docsite", ...)` (`:327`). `test_all` has its own
  list in `steps.odin` and `tasks.odin`. Two lists of how to build each program exist.
- The package `gen` mixes concerns: code generation, the documentation site, the licence tool, the translation
  check, the portability check, test262, a trace recording and a desktop (`gen.odin:24`, `:311`, `:314`, `:411`,
  `:471`, `:529`, `:578`).
- Flags have two forms: `-Urls`, `-List`, `-Exe` in `wrentool` and `test_all`
  (`src/tools/wrentool/capture/sweep.odin:86-96`), and `--profile`, `--policy` in `wren`
  (`src/browser/main.odin:1741-1745`).
- `test_all` is started with a long command (`odin run src/tools/test_all -collection:wb=src -out:build/test_all
  -keep-executable`). It imports `wb:tools/wrentool/builder`.
- Versions are pinned in many places. Odin: 4 workflow files, `flake.nix:52`, `odin.version`, `README.md:256`,
  `CONTRIBUTING.md:76`. Rust 1.99.1: 3 workflow files and 4 cache keys. Wasmtime 49.0.3:
  `src/tools/wrentool/deps/fetch.odin:9`, `flake.nix:81`, two documents.
- The workflows hold about 120 lines of inline PowerShell and shell. The download of Odin with its digest is
  written three times (`.github/actions/setup/action.yml:20-37`, `setup-linux/action.yml:11`, `linux-package.yml:65`,
  `pages.yml:41`).
- The folder `tools/` holds allow lists and the Go test server. The folder `src/tools/` holds the programs. The
  folder `src/testserver` holds the Odin binding of the Go server.

Not a defect: the Go test server and the TypeScript worker of `licence/worker` are programs, not automation
scripts. No shell, PowerShell, Python or Node script exists in the tree beside `build.sh` and `build.bat`, and
both are shortcuts as `AGENTS.md` asks.

Proposal:

- One table of programs in `src/tools/tooling`: name, folder, output, flags, sources. `wrentool`, `test_all` and
  the builder read it. `wrentool run <program> [arguments]` builds a program if its sources are newer, then runs it.
- `wrentool test [flags]` is the entry of `test_all`. The long command leaves the documents.
- Split `gen`: `gen` keeps generation. `check` takes `i18n`, `portability`, `docs -Check`, `changelog -Check`.
  `run_license`, `run_engine` and `run_desktop` become rows of the table of programs.
- One file of pins at the root, `versions.txt` (`odin`, `rust`, `wasmtime`, `wgpu`, `nasm`, `go`).
  `wrentool fetch` and `flake.nix` read it (`builtins.readFile`). A workflow reads it with one step. `wrentool
  check` fails when a document names another version.
- `wrentool ci setup` holds what the inline scripts do after the download of Odin. Only that download stays in
  YAML, once, in a composite action that the four files use.
- One flag form for new commands: `--name`, with the toolkit's `cli` package. Move the old flags when a command is
  touched. Accept both forms during the move only inside `tooling.flag`.
- Rename the root folder `tools/` to `lists/`, and move the Go server to `testserver/`. The word "tools" then has
  one meaning.

Cost: 3 to 5 days.

## 10. Shared state and ownership rules

What is good: `docs/architecture.md` "Where state lives" is clear. `tools/globals_allowed.txt` and its lint hold
it. `process_share.odin` documents its state machine. `app_make.odin` has stages and one destructor.

Gaps:

- **The temporary allocator has no written rule.** `src/browser` has 1242 uses of `context.temp_allocator` and 894
  of `fmt.tprintf`. `src/page` has 955 and 251. The memory lives until `free_all` at the end of `frame`
  (`src/browser/main.odin:1679`, and the early returns at `:1545`, `:1567`). A nested frame protects the outer one
  with a mark (`src/browser/shell_frames.odin:427-428`). Worker threads free after each job
  (`src/host/blocking.odin:116`). No document states the rule. 90 procedures of `browser` and `page` take
  `allocator := context.temp_allocator` and return memory. A caller that keeps such a result past the frame reads
  freed memory. The check build poisons it, so the defect shows only on a path that a test runs.
- **The globals lint covers 6 packages**: `browser`, `page`, `style`, `layout`, `media`, `js`
  (`src/tools/test_all/lint_globals.odin:28`). A rough count finds package variables outside: `wasm` about 29,
  `base` 14, `host` 6, `remote` 6, `images` 6, `idb` 5, `canvas2d` 4.
- **Thread-local variables carry parameters.** `headless_software` (`src/browser/main.odin:1724`) and
  `headless_no_pixels` (`src/browser/headless_pixels.odin:11`) are set before `app_start` and read by it.
- **The active window is an ambient parameter.** `active_window(app)` returns `App.active`, or `App.bare`
  (`main.odin:219-222`). `window_activate` exchanges a part of the window (`Window_Ctx`), and `Window_Own` is "not
  exchanged" (`src/browser/windows.odin:61`, `:73`). A procedure that takes `^App` acts on a window that its
  signature does not show.
- **`the_pages` has 567 uses in `src/page`** (`src/page/pages.odin:67`). It is the App's state reached through the
  thread. It is documented. It is also the reason why a page cannot move to another thread without `page.bind`.

Proposal:

- Add a section "Temporary memory" to `docs/architecture.md`, with four rules. A result in temporary memory lives
  until the caller returns to the loop. A value kept in a struct is cloned. A thread frees its temporary memory at
  the end of each job. A nested loop turn takes a mark.
- Name the two end points: `base.temp_end_of_turn()` and `base.temp_scope()`. A search then finds each place.
- Extend `GLOBALS_DIRS` to each package of `src` outside `tools` and `engine`. Class each global that the lint
  finds. Cost: 1 day, mostly for `wasm`.
- `app_start(args, Start_Options{software, pixels})` replaces the two thread-local parameters.
- Procedures of the chrome take `^Browser_Window`. `active_window` stays only at the entry of a frame and of a
  command. This comes with finding 2.

Cost: 3 days without the window parameter.

## 11. `src/page` mixes six concerns

Evidence: 183 files that are not tests, 106 250 lines with the generated file. By prefix: 42 `js_*` files (the
realm, script loading, the DOM bindings for scripts), 28 `bindings_*` files (the implementations of the generated
trampolines), service workers and workers, storage (Cache API, file system, buckets, Web Storage), media, frames
and navigables, and images. `page` imports 24 packages of `src`.

`page.Pages` (`src/page/pages.odin`) is to `page` what `App` is to `browser`: one struct that each file reaches
through `the_pages`.

Proposal, in order of ease:

1. `storage`: `storage.odin`, `storage_buckets.odin`, `cache_store.odin`, `fs_store.odin`, `fs_api.odin`. They are
   stores of a profile with files (finding 3). They need an origin and a directory, not a page.
2. `workers`: `service_worker.odin`, `worker.odin`, `shared_workers`, `ports`. They have their own Wasm store
   (rule 3 of `docs/architecture.md`).
3. `scripting`: `js_realm.odin`, `js_load*.odin`. The script loader is a state machine of HTML with six enums
   (`src/page/js_load.odin:42-64`): it deserves a boundary and its own tests.

Do not split the `bindings_*` files: they are the surface of `page` by design.

Cost: 3 days for `storage`. 5 days each for the two others. Value is lower than findings 1 to 5: do it when a
change touches the area.

## 12. Dialogs and prompts

System dialogs have one mechanism, and it is correct: `host.run_dialog` runs the blocking call on its own thread
and answers on the loop (`src/host/dialog.odin:41`). 8 call sites of `src/browser` use it. One exception:
`license_choose_file` (`src/browser/license_shell.odin:208-221`) calls `platform.open_file_dialog` through
`host.run_blocking`. The loop is not blocked, but a worker of the blocking pool waits while a person answers. The
comment of `App.dialogs` forbids this (`src/browser/main.odin:163`). Move it to `host.run_dialog`.

The repetition is above it. Each call site declares its job struct, its `work`, its `done` and its `discard`
(`blocker_files.odin:34`, `bookmarks_ui.odin:448`, `context_menu.odin:527`, `download.odin:380`, `:719`,
`ext_page.odin:245`, `forms_shell.odin:1763`, `fs_shell.odin:77`). Proposal: one procedure,
`pick(app, kind, options, done, user)`, that owns the job and the result. The call sites keep only `done`.

Permission prompts of a page exist three times, each with its own queue, modal and store:
`fs_shell.odin:133` (`App.ask_state`), `notification_shell.odin:189` (`App.notes`),
`storage_access_shell.odin:43` (`App.sa_queue`). A fourth form exists for confirmations (`confirm_shell.odin`).
Proposal: one `Permission_Prompt` queue for each window, with a kind, an origin, a text and an answer callback, and
one store of decisions by origin and kind. A new permission (geolocation, camera) is then one enum value.

Cost: 1 day for `pick`. 3 days for the prompts.

## 13. Names and terms

One term for one concept. The tree has these conflicts:

| Concept | Terms in use | Proposal |
|---|---|---|
| The licence | `licence/`, `docs/licence.md`, `src/license`, `src/tools/license`, `license_shell.odin`, `LICENSE`. In `.odin` and `.md` files: 181 uses of "licence", 740 of "license". | `license` in code and paths (the majority, and the name of the root file). Rename `licence/` and `docs/licence.md`. |
| The part of the program around the page | "shell" (27 `*_shell.odin` files), "chrome" (`chrome.odin`, `Window_Chrome`, "chrome frames"), "interface" (the documents, `.Interface` stage), "UI" (8 `*_ui.odin` files) | `chrome`: what the user sees around the page. `shell`: the service that the browser gives to a page (`forms_shell`, `fs_shell`). Write the two definitions in `docs/architecture.md`. Rename `shell_frames.odin` to `chrome_frames.odin`: its own state is `App.chrome_frames`. |
| A view made by the browser | `*_ui.odin`, `*_page.odin`, `*_dashboard.odin`, `Tab_Kind`, "view", "built-in page" | `view` for a `Tab_Kind` with no document. `builtin page` for a document that the browser writes. |
| The content blocker | `src/adblock` (the filter engine), `src/blocker` (the integration) | Keep both packages. Rename `adblock` to `filters`: it holds no concept of a browser. |
| The script engine | `src/engine` (the engine), `src/js` (its host side), `native/js/odin` (its glue), `src/js/image` | `engine` (the guest), `engine/glue` (finding 8), `jshost` in place of `js`. |
| Event loop host and window host | `wb:host` and the toolkit's `host` | Finding 6. |
| Remote control | `remote`, `control.odin`, `ctl`, `cdp`, "channel" | `control` for the command engine, `remote` for the transports (pipe, socket, CDP). This matches the package `control` of finding 2. |
| The state of the settings | `cfg`, `settings`, `prefs`, `ccfg`, `hcfg`, `tcfg`, `chrome_cfg`, `autoscroll_cfg`, `Autoscroll_Settings_B` | `prefs` is the registry. `settings` is a struct read from it. Remove `cfg` and the one-letter prefixes with finding 4. |
| Short field names of `App` | `bms`, `dls`, `upd`, `stp`, `tsh`, `pcs`, `ix`, `bl`, `dsk`, `pt`, `ub`, `lm`, `dtm`, `dtc`, `bf`, `cpal`, `vfast`, `cgpu` | `AGENTS.md` asks for complete words. The fields go to their packages with finding 2: give each its full name then. |
| A constructor | `_make`, `_init`, `_create`, `_start`, `_begin`; and `_destroy`, `_free`, `_end`, `_stop` | `_make` returns a value or a pointer and pairs with `_free`. `_init` fills a struct of the caller and pairs with `_destroy`. `_start` begins activity and pairs with `_stop`. Write it in `CONTRIBUTING.md`. |
| Test worlds | `test_app`, `chrome_start`, `e2e.start`, `web_harness.begin`, `headless.init`, `test_pages` | After finding 1: `embed.world_make` and `browser.app_make`. A harness is a set of options, not a constructor. |

Cost: 1 day for the licence spelling and the definitions. The rest comes with the findings named.

## 14. Documents against the code

| Document | Statement | Code |
|---|---|---|
| `AGENTS.md:4` | "Releases are Windows x64; Linux ... is in progress" | `.github/workflows/linux-package.yml` builds a Linux release. `README.md:213` gives the download. |
| `CONTRIBUTING.md:113` | One program runs everything. | Finding 9. |
| `docs/architecture.md:31-33`, `AGENTS.md` | A preference is in the package's `settings.odin`, read through `settings_from_prefs`. | Finding 4. |
| `AGENTS.md`, `CONTRIBUTING.md` | A new web API starts in `api/<module>.widl`. | Finding 8: a second source exists. |
| `docs/architecture.md` (JavaScript) | Names `native/js/gen/bindings.c`; `docs/webcodecs.md:5` names `native/js/runtime/web_webcodecs*.c`. | Neither folder exists. The glue is Odin. |
| `docs/architecture.md` (The Rust library) | "`native/`" is the Rust workspace. | `native/js/odin` is Odin. |
| `docs/architecture.md` | Uses Windows paths and `build.bat` in most sections. | Linux builds since 2026-10-30 (`docs/portability.md`, slice 7). |
| `docs/portability.md` | A log of 9 slices in the order of time, 359 lines. The table of shared helpers is at the top. | The helpers table is a rule. The log is history. Split them: rules in `docs/portability.md`, history in `docs/history/`. |
| `docs/architecture.md` | No list of packages and of their allowed imports. | The graph exists only in the code. |

Proposal for the last row: a file `tools/layers.txt` with one line for each package: its layer and the packages
that it can import. A lint in `test_all` reads the `import` lines and fails on an import that the file does not
allow. `docsite` renders the file as the package map of `docs/architecture.md`. The layers found by this review, low
to high:

1. `base`, `config`, `i18n`, `trace`
2. `host`, `url`, `http`, `css`, `xml`, `adblock`, `webfont`, `license`, `engine/*`
3. `dom`, `cookies`, `csp`, `extensions`, `net`, `wasm`, `images`, `media`, `idb`, `canvas2d`, `webgl`, `webauthn`,
   `remote`, `vault`, `desktop`
4. `html`, `style`, `httpcache`, `js`, `webaudio`
5. `forms`, `layout`, `fetch`
6. `a11y`, `page`
7. `blocker`, `embed` (new)
8. `browser` and its packages
9. `e2e`, `tools/*`

Cost: 1 day for the lint and the file. 1 day for the document corrections.

## Implicit state machines

A machine is implicit when its state is a set of booleans, a count, or the position in a procedure.

| Machine | Where the state is | Explicit now? | Proposal |
|---|---|---|---|
| The life of an App | `App.made` (stages), `App.quitting`, `headless`, `hidden`, `private`; the order inside `app_start` (228 lines) and `app_stop` | Half: stages exist for the constructor only | `app_start` becomes a list of stages past `.Interface` (`.Profile`, `.Network`, `.Session`, `.Remote`). `app_stop` is `app_free`. |
| The process share | One atomic word | Yes (`src/browser/process_share.odin:10-17`) | None. This is the model to copy. |
| A navigation | `Nav_Phase` (5 values) plus `Doc_Load.stopped`, `failed`, `pushed`, `blank`, `view_source`, `action` (`main.odin:64-88`), `Paint_Hold`, `Tab.lazy`, `Tab.art_empty`, `Tab.fragment_done`, `Tab_Nav.left`, `bf_entry`, `no_store` | Half: the phase is explicit, the 12 flags are not. A second copy is in `headless.Doc` (`loading`, `shown`, `parsed`, `failed`, `restoring`). | Finding 1. One `Navigation` with one transition procedure, as `nav_to`, and a table test of each transition. |
| A pass of the loop over the windows | `App.active`, `front`, `bare`, `pass_first`, `tasks_running`, `task_own`, `pass_order`, `chrome_frames.nested`; `Browser_Window.closing`, `closing_force`, `minimized`, `presented` | No | A `Pass` struct that lives for one pass and is passed down. `active` is a field of it. |
| Pending frames | `frames_requested` (a count), `errand`, `asked_by` | No | Finding 5. |
| A preference change | `shell_defer({kind = .Prefs})`, then `apply_prefs`, then 30 watches, `prefs_apply_counts` | No | Finding 4. |
| A profile file | `Profile_File`: idle, writing, waiting, retry with delay, flush at exit | Yes for 3 kinds of file | Finding 3: all files. |
| The restore of a session | `App.rest_text`, `rest_from`, `rest_focus`, `Tab.lazy`, `session_last` | No | A `Restore` struct with a phase: none, windows pending, done. |
| An icon to fetch and decode | `Favicon_State` and `Ext_Icon_State`, the same four values (`favicon.odin:143`, `ext_toolbar.odin:30`); `Picture_State` (`dnd_image.odin:36`) | Yes, three times | One `Icon_Load` type that both use. |
| A prompt to the user | `App.sa_queue`, `ask_state`, `notes`, `confirm`, `dl_picking`, `qr_url` | No | Finding 12. |
| Chrome frames under a page | `Shell_Phase`, `Snapshot_State`, `nested`, `deferred`, `outer`, `actions` | Half | Out of scope: it is documented in its file. Rename per finding 13. |
| The script loader | Six enums in `src/page/js_load.odin:42-64` | Yes | A package boundary (finding 11). |
| A connection of the remote channel | Before the WebSocket handshake it is an HTTP client, after it carries messages (`src/browser/cdp.odin:15-18`) | No | An enum in the connection. |
| The move of the API source | 78 `.widl` and 77 `.odin` files | A project state left in the middle | Finding 8. |
| The Linux port | 19 `ODIN_OS` tests and 5 Windows imports in neutral files of `src/browser` | A project state left in the middle | Finding 7. |

## What is in good order

These parts need no change of organisation:

- The dependency graph below `page` has clear layers and no cycle. `net` does not know `fetch`. `fetch` does not
  know `page`.
- The split of mechanism and policy between `net` and `fetch` holds in the imports.
- One description generates the host side, the SDK, the documents and the conformance tests.
- `app_make.odin` with its lint.
- The changelog fragments, the opt-in classes of tests, the lint of sleeps.
- `build.sh` and `build.bat` are shortcuts with no logic.
- `flake.nix` exposes `checks` with the pre-commit hooks through `pkgs.prek`.
- System dialogs never block the loop.

## Order of work

1. The lints that find the complete lists, with no change of code: file writes (3), by-name preference reads (4),
   imports against `tools/layers.txt` (14), all packages in the globals lint (10). 3 days. Each later step then has
   a number that goes down.
2. Finish the API source move and delete the C emitter (8). 2 days.
3. The cheap layering fixes and the licence spelling (7, 13). 3 days.
4. `embed.World`, then `embed.Navigation` (1). 10 to 15 days.
5. One writer for profile files, with the `profile` package (3, and step 1 of 2). 6 to 8 days.
6. Preferences by group (4). 5 to 8 days.
7. Toolkit: use `tk_changelog` and `tk_release`; move the loop, the writer, crash reports (6). 8 to 12 days.
8. Frames by cause (5). 5 to 8 days.
9. The remaining packages of the split of `src/browser` (2). 15 to 20 days.
10. Tooling: the table of programs, the file of pins (9). 3 to 5 days.
11. `src/page` (11) and prompts (12), when a change touches them.
