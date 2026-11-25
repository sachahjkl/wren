# Fuzzing what reads untrusted input

A page controls the bytes that Wren's parsers read: its markup, its style sheets, its addresses, its images, its fonts,
its media, its headers, its cookies, its policies. A filter list and an extension come from third parties. A fuzzer
feeds those parsers broken and hostile variants of real inputs, to find the crashes, the memory errors, the leaks and
the hangs before a page does.

## The irreducible constraints

- **No coverage instrumentation in the pinned Odin.** `dev-2026-11a` has `-sanitize:address|memory|thread`, and
  `@(instrumentation_enter)` gives a hook per procedure call, but it has no edge coverage (`-fsanitize-coverage`) and
  no libFuzzer entry point. A coverage-guided engine is not available without a fork of the compiler.
- **A crash ends the process.** A bounds check, an assertion and a fault of a native library each end it at once. The
  input that caused it must be on disk before the target runs.
- **A finding must replay.** The same seed and the same corpus give the same inputs. One command replays one input.
- **wrentool links no native library** (its head says so). The parsers link Lexbor and the Rust library. So the
  targets live in a program of their own, and wrentool drives it.
- **The JavaScript engine is the toolkit's.** `src/tools/fuzz` links `toolkit:js` and `toolkit:js/frontend` directly
  as the `js_src` and `js_bytecode` targets, so `wrentool fuzz -Target all` and `test_all -Fuzz` run them under the
  same memory tracker, poisoner, hang watchdog and replay workflow. `ext/gui_toolkit/tools/js_judge` (`fuzz`, `fuzzsrc`)
  remains available for standalone test262-corpus runs inside the toolkit.

## The design

Two programs:

- `src/tools/fuzz`, the **worker**. It links the targets. It runs one target: it mutates inputs, runs the target on
  each, and checks memory after each. It is built with `-define:WREN_TRACK_MEMORY=true` and
  `-define:WREN_POISON_MEMORY=true`, or with `-sanitize:address` instead of the poison (`-Asan`).
- `wrentool fuzz`, the **driver** (`src/tools/wrentool/fuzztool`). It builds the worker when its sources changed, runs
  one worker process per target with a time limit, and turns an abnormal end into a file and a command that replays it.

### The loop of the worker

1. **The corpus.** Each target names its seeds: inline seeds in its file (the forms that its format has: a cookie with
   every attribute, a policy with every source kind, a minimal Wasm module), and files of the repository (examples/,
   site/, native/media/tests, the extensions of examples/). Then every file of `build/fuzz/<target>/corpus/`, which a
   person fills by hand. Files are read in sorted order and capped (256 KiB each, 300 files per target).
2. **The warm-up.** Every seed runs once, unmutated. A seed that fails is a bug like any other. Then the tracker
   forgets every live block (`base.mem_forget_live`): the tables that a parser builds once, on its first call, are not
   leaks.
3. **The iterations.** Iteration `i` seeds a SplitMix64 generator with `seed` and `i`. It picks a corpus entry, then
   applies 1 to 8 mutations: a bit flip, a random byte, an interesting byte (0, 0x7F, 0x80, 0xFF), an insertion, a
   deletion, a duplicated span, a cut, an interesting 32-bit integer written big- or little-endian (sizes and counts of
   binary formats), a span spliced from another entry, and a token of the target's dictionary inserted or written over.
4. **The run.** The input is written to `build/fuzz/<target>/current` (one handle kept open: a write and a truncate),
   then the target runs: `proc(data: []u8)`. Its temporary allocator is an arena freed after each iteration. Its
   allocator is the tracker.
5. **The checks.** After each iteration: no live block, no bad free (`base.mem_stats`). A watchdog thread ends the
   process when one iteration takes longer than the hang limit (10 s).

The worker stops after `-Iterations n` or `-Seconds n`, the first reached.

### How the worker ends, and what the driver does

| Exit code | Meaning | The driver writes |
| --- | --- | --- |
| 0 | every iteration passed | nothing |
| 2 | bad arguments, an empty corpus | nothing; it reports the error |
| 3 | a leak or a bad free (the tracker's report is on standard output) | `leak-<hash>` |
| 4 | a hang (the watchdog) | `hang-<hash>` |
| any other, a signal, the driver's limit | a crash | `crash-<hash>` |

The driver copies `current` to `build/fuzz/<target>/<kind>-<FNV-64 of the bytes>` and prints one line:
`wrentool fuzz -Target <target> -Repro <file>`. The same input found twice has the same name.

`-Minimize <file>` shrinks a finding: the driver removes chunks (half of the input, then a quarter, down to one byte)
and keeps each removal after which the worker still ends the same way. It writes `<file>.min`.

### Targets

Each target is one file `target_<name>.odin` in `src/tools/fuzz`, with one line in the table of `targets.odin`. A target
calls the entry point that the browser calls on the network's bytes, and frees what that entry point gives it.

| Target | Entry points |
| --- | --- |
| `html` | `html.parse_into` (Lexbor, a whole document), `html.parse_fragment` (a `<template>`, an `<svg>` context) |
| `html_scan` | `html.scan_feed` (the preload scanner, Odin), the input fed whole and in chunks; `html.decode_document` |
| `css` | `css.parse_stylesheet`, `css.parse_declarations` |
| `css_select` | `css.parse_component_values`, then `css.parse_selector_list` and `css.parse_media_query_list` |
| `url` | `url.parse` (absolute, and relative to a base), `url.component`, `url.origin_of` |
| `images` | `images.sniff`, `images.header_size`, `images.looks_complete` for each format (Odin, before any decoder) |
| `image_decode` | `images.probe_now`, `images.decode_now` with small limits (the Rust decoders behind Wren's checks) |
| `webfont` | `webfont.decode` (sfnt checks, WOFF, WOFF2, collections), `webfont.read_tables`, `webfont.collection_face` |
| `mp4` | `media.mp4_feed`, whole and in chunks |
| `webm` | `media.webm_feed`, whole and in chunks |
| `media_text` | `media.vtt_parse`, `media.vtt_cue_from_text`, `media.parse_type` |
| `http` | `http.parse_header_block`, `http.extract_mime`, `http.parse_mime` |
| `cookies` | `cookies.parse_set_cookie`, `cookies.parse_cookie_date` |
| `csp` | `csp.parse_header`, then `csp.check_request` and `csp.check_nonce` on what it parsed |
| `adblock` | `adblock.engine_from_text`, then `adblock.match` on fixed requests |
| `ext_manifest` | `extensions.manifest_parse`, `extensions.pattern_parse` |
| `ext_archive` | `extensions.archive_open`, `extensions.archive_read` of each entry (CRX3 and zip) |
| `wasm` | `wasm.analyze_image`, `wasm.patch_image`, `wasm.unbound_tables` |
| `js_src` | `toolkit:js/frontend.compile_program` (module), `toolkit:js.eval_source`, `toolkit:js.run_jobs` (bounded heap, stack, 20 ms interrupt) |
| `js_bytecode` | `toolkit:js.read_object`, `toolkit:js.bytecode_read_all` on mutated compiled script and module bytecode images |

For standalone test262-corpus fuzzing inside `ext/gui_toolkit`, build the judge (`odin build tools/js_judge
-collection:gt=src -out:build/js_judge -o:speed`, with `/STACK:67108864` on Windows or `ulimit -s 65536` on Linux),
then run `build/js_judge fuzz <dir of .js> [iterations] [seed]` or `fuzzsrc`.

### test_all

`test_all -Fuzz` (or `WREN_FUZZ=1`) adds one step: `wrentool fuzz -Target all -Seed 1 -Iterations 2000 -Seconds 30`.
The iterations are fixed, so the inputs are the same at each run: a failure is a regression, not luck. `-Seconds` is
the bound on a slow machine. The step is opt-in because it builds a third program that links every parser. `-Quick`
does not add it.

## Refused alternatives

- **libFuzzer or AFL++ through a C shim.** They need coverage counters in the code under test. Odin cannot emit them,
  so they would see only the shim and mutate blind, at the cost of a C toolchain on every machine.
- **Coverage from `@(instrumentation_enter)`.** One hook per call is not one per branch: a parser loop that takes a
  new branch calls the same procedures. The signal is too coarse to grow a corpus. It is a candidate when a target
  plateaus.
- **The targets inside wrentool.** wrentool must compile without the native libraries.
- **One process for every target.** A crash of one target would hide the others. One worker per target costs one
  process start per target.
- **Odin's `core:math/rand` for the mutations.** Its algorithm can change with the compiler, and a seed must keep
  naming the same inputs. SplitMix64 is twelve lines.
- **Recording each input only after a crash.** The process is gone by then. The write before each run costs two system
  calls; the targets cost more.
- **A corpus that grows with the inputs that pass.** Without coverage, nothing tells an interesting input from a
  boring one; the corpus would only grow.

## Subtleties

- **AddressSanitizer and the poison are exclusive.** Both take over `free`. `-Asan` builds without
  `WREN_POISON_MEMORY`. The poison sees reads of freed heap memory and the arenas; ASan also sees overflows of the
  heap, the stack and the globals. On Windows, `-sanitize:address` needs the link of `src/tools/test_all/asan.odin`;
  the driver does not do it, so `-Asan` is for Linux.
- **The quarantine of the poison holds up to 1 GiB.** A worker reaches it after a few seconds of large inputs. That is
  the cost of seeing reads of freed memory without ASan.
- **Lazy tables.** The warm-up runs each seed, so a table built on the first call is forgotten before the checks. A
  table built only on a rare path is still reported as a leak: such a table must come from `base.permanent_allocator()`.
- **The temporary allocator is an arena reset per iteration.** A target that keeps a temporary allocation across
  iterations reads freed memory, and the poison makes that loud.
- **Native code.** Lexbor (the HTML tree, the charset decoders) and the Rust library (the URL parser behind
  `url.parse`, the image and WOFF2 decoders) are not instrumented. The fuzzer finds their crashes, not their silent
  overreads. Wren's own code around them (the tree builder, `url.split`, the header checks) is instrumented.
