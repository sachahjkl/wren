# Performance: the pipelines measured

Wren seen as a factory: each stage of a pipeline produces at some rate and consumes at another, and the slowest stage, or a
queue that holds what a stage made, sets the throughput. This page has the map with numbers, the bottleneck of each
pipeline, an inventory of what goes against the rules below, and what to do next, ranked.

The rules the work follows: data laid out for the loops that read it (struct of arrays where a loop reads a few fields of
many items, flat arrays rather than hash tables, indices rather than pointers); no cache to hide a slow path (the caches
that are a product, the HTTP cache, the back/forward cache, compiled code on disk, stay); lists with an inline capacity
rather than heap lists; bitsets rather than arrays of bools; no mutex where an ownership hand-off, per-thread state, an SPSC
ring or an MPSC queue does; explicit state machines in structures.

## How it was measured

On the development machine (2026-11-02), headless (`api.Window_Mode.Headless`: no window, nothing takes the focus), the
profile build (`build.bat profile`, `-define:PROFILE=true`) with the native library of the development builds (Cargo
`quick`: text shaping 2 to 5 % slower than the shipped one, see `native/Cargo.toml`). Tools:

- `wrentool bench perf -Only <scenario>`: start to load, frames, CPU, memory, and the browser's own report per scenario
  (`build/perf/<scenario>.txt`: per-phase statistics of the frames, the start-up marks, the style and layout passes;
  `.csv`: one row per frame).
- A load measured from the navigation (not from the process start): the page is opened on `about:blank`, then
  `api.navigate`, then the Navigation Timing entry read with `api.eval` (`responseEnd - fetchStart`,
  `domInteractive - responseEnd`), then the scenario's input, then `api.stats` (CPU, frames, the loop's meter:
  `loop.turns`, `sleeps`, `causes`).
- `WREN_SAMPLE=1` (1 ms samples of the window's thread, by phase), `WREN_SAMPLE_STACK=1` (callers),
  `WREN_SAMPLE_THREADS=1` (the other threads: those the system's list says are on a processor or waiting for one, each
  followed every millisecond until it goes back into the system; per thread, its name, hottest call chains and the
  functions on its stack). The list takes 30 ms on a machine with many processes, so a burst of a few ms is caught
  by chance: 145 samples, 123 running, on 15 s of `p10k_renav`. Before round 3 it visited the ninety threads in
  turn, about 13 samples a second each; from round 3 to 24 it took the one whose cycles moved most; rounds 25 to 27 every thread that ran in the last second (0 of 44 807 samples running on `p10k_renav`). Stacks are walked in a copy, after the thread has gone on (`crashtrace.Stack_Copy`). Samples that land in a system call are biased: on the
  script-heavy page `NtUserGetQueueStatus` (the chrome's preemption checking for input) took 13 % of the samples, and turning
  preemption off (`browser.shell.preempt=false`) changed neither the frame rate nor the CPU.

Numbers are medians of 5 runs unless a range is given; the machine runs other programs, so CPU per second moves by a
factor of 2 from run to run, frame times much less.

## Profilers

Beside the built-in profiler, Wren speaks to four external ones. What they see of Wren comes from one place, package
`trace` (`src/trace`): the phases of a frame (`Phase`, `src/browser/prof.odin`) are its zones, named as above, on the
window's thread; a frame mark at each present; the start-up's marks (the profile build). Without its switches every call
of it is empty and nothing is linked: `build\wren.exe` imports none of ETW's writing functions and holds no Tracy client
(test_all checks it). The zones of a thread pair on every path: an end closes what an early return left open, and each
frame begins by closing whatever the last one left.

Threads have names (`SetThreadDescription`, which Tracy, WPA, VTune and the debuggers read): `wren-window`,
`wren-page-layout`, `wren-style` and `wren-layout` (the style and layout pools; the compositor's work runs on the
latter), `wren-js-compile`, `wren-js-worker`, `wren-wasm-compile`, `wren-wasm-epoch`, `wren-wasm-cache`,
`wren-image-decode`, `wren-blocking-<n>`, the media's.

Symbols: every variant but the release has its PDB beside it (`build\wren_prof.pdb`...). For WPA and VTune, the
system's from Microsoft's server:

```
set _NT_SYMBOL_PATH=S:\wren\build;srv*C:\symbols*https://msdl.microsoft.com/download/symbols
```

### Tracy

[Tracy](https://github.com/wolfpld/tracy) 0.14.1, pinned by SHA-256 (`src/tools/wrentool/deps/tracy.odin`): its client
built from the source release into `build\tracy\tracy.lib` by the builds that ask for it, its viewer from the release's
Windows build. The client records only while a viewer is connected (`TRACY_ON_DEMAND`) and answers on this machine only
(`TRACY_ONLY_LOCALHOST`, port 8086).

```
set WREN_TRACY=1
build.bat profile                         (-> build\wren_prof_tracy.exe; any variant: build\wren_tracy.exe...)
build\wrentool fetch tracy                (-> build\tracy\tracy-profiler.exe, tracy-capture.exe)
build\wren_prof_tracy.exe examples\jsbench\nodes10k.html
build\tracy\tracy-profiler.exe            the client is listed: Connect
build\tracy\tracy-capture.exe -a 127.0.0.1 -o build\perf\nodes10k.tracy -s 10    (no window: 10 s into a file the viewer opens)
build\tracy\tracy-csvexport.exe build\perf\nodes10k.tracy                    (each zone's count, mean and total, as CSV)
```

It shows the phases, the frames, a plot of the layout items per frame, and in a Tracy build every call of a module into
the browser (each import of the JavaScript engine: a DOM call, a style or layout read) as a zone `module.name` on the
thread that made it (`src/wasm/host_trace.odin`). Run elevated, Tracy also samples the CPU and shows context switches
(its own ETW session). Not there: GPU zones (the toolkit keeps its Direct3D 11 device and context to itself, its
timestamp queries are the renderer's: `gpu_steps.odin` reads their results), lock annotations (Odin's `sync.Mutex`
has no hook). Connected, it costs: 5 s of nodes10k made 6.5 million zones (2.2 million `dom.Node_preInsert` alone),
and 44 frames a second instead of 230; the phases alone are a few hundred zones a second.

### VTune (and perf)

Wasmtime tells a profiler about the code it compiles when `wasm.wasmtime.profiler` says which (a restart preference;
`none` by default): `vtune` (Windows and Linux on x86-64: the prebuilt library has Intel's ITT API), `perfmap` and
`jitdump` (Linux's perf). The code read from the compiled-code cache is told too. The JavaScript engine's image keeps
its functions' names (its `name` section: `wasm-ld --strip-debug` drops only DWARF, which `buildjs -names` keeps):

```
vtune -collect hotspots -result-dir build\vtune\nodes10k -- build\wren_prof.exe --pref wasm.wasmtime.profiler=vtune examples\jsbench\nodes10k.html
vtune -report hotspots -result-dir build\vtune\nodes10k -format csv
```

(`jspage --pref wasm.wasmtime.profiler=vtune` is the engine alone.) VTune then lists the engine's functions as `[Dynamic code]`,
`wasmtime::jsrt::interp_run`, `wasmtime::jscapi::...::bridge_invoke`, `wasmtime::jsrt::call_native`; telling it about every function
costs about 1.2 s of CPU at the start (Wasmtime's `VTuneAgent::register_function`).

### WPR and WPA

The profile build (`-define:WREN_ETW=true` in any other) is an ETW provider, `Wren.Browser`, a TraceLogging one (each
event describes itself: no manifest to install), GUID `10e6f595-25dd-53c9-a97c-bdec823560e6` (TraceLogging's hash of
the name). Each zone is a Start and a Stop event named after its phase; `Presented` at each present; `Mark` with the
start-up's steps. While no session listens an event costs the test of a flag. `tools\wren.wprp` records CPU samples
with stacks, context switches with the thread that readied each, the GPU's scheduler (DxgKrnl) and the provider;
`tools\wren_regions.xml` makes the phases WPA's regions of interest.

```
build\wrentool trace start                (an elevated prompt: WPR asks for one, wrentool does not)
build\wren_prof.exe examples\jsbench\nodes10k.html
build\wrentool trace stop                 (-> build\trace\wren.etl)
wpa build\trace\wren.etl                  Trace > Load Symbols; Trace > Trace Properties > Regions of Interest: tools\wren_regions.xml
```

Checked on 2026-11-04 (WPR and WPA of the Windows Performance Toolkit 11.8): 3 s of nodes10k give 1 082 regions of
each phase that runs every frame, the start-up's marks, Wren's functions named from the PDB, DxgKrnl's events.
`xperf -i build\trace\wren.etl -a regions -man tools\wren_regions.xml` lists the regions without a window.

The profile build with ETW in it and no session, against the one before it (5 interleaved runs of nodes10k, 5 s, median):
CPU work per frame p50 17.70 -> 17.54 ms, Animation p50 11.79 -> 11.66 ms, 222.0 -> 227.7 frames/s: no cost seen.

### PIX

PIX's GPU captures are of Direct3D 12 programs: Wren's Direct3D 11 renderer is not one, the wgpu backend
(`WREN_RENDER=wgpu`, Direct3D 12 on Windows) is. Its timing captures read their own markers (WinPixEventRuntime), not
another provider: nothing of Wren's is added for it; WPA shows the same phases.

## The map

Times are per load or per frame on the window's thread unless said; "items/s" is what the stage gets through.

### 1. A large static page, loaded (`build/perf/p10k.html`: 611 KB, 10 020 elements, 16 478 layout items, 2 000 rules)

| stage | where | time | rate | waits on |
|---|---|---|---|---|
| network bytes (file://) | loader thread | 2 to 5 ms | ~200 MB/s | the disk |
| decode, parse, DOM | blocking pool (`page/offthread.odin`) | 26 to 31 ms | ~20 MB/s, ~350 000 elements/s | the body |
| hand-over to the loop | posted task (`host.post`) | **was 620 to 1000 ms, now 0** | | the loop's next turn |
| adopt, reveal | window thread | < 3 ms | | |
| style, full pass | window thread + style pool (7 threads) | 17 to 29 ms (+ 6 to 11 ms engine rebuild) | 0.6 to 1 M elements/s | |
| layout, first full pass | layout thread | 13 to 30 ms (31 to 63 ms forced by a script read, style included) | ~0.5 to 1 M items/s | style |
| paint (display items) | window thread | 6 to 11 ms the first frame, then 0.02 ms | | layout |
| GPU draw | GPU | 0.09 ms | | |
| present | | 0.08 to 0.4 ms | | the swap chain |

`navigate -> load event`: **1055 ms -> 34 ms**; `domInteractive - responseEnd`: **1035 ms -> 32 ms**; until the page is
quiet: 1516 ms -> 480 ms (5 runs each, `build\wren_prof` before and after the change below).

**Bottleneck (fixed):** the hand-over. The parsed document waited in the loop's queue for 0.6 to 1 s while the window's
thread slept in its frame pacer: headless frames made at once for a waiting client each booked a frame slot ahead of the
clock, and the first paced frame after the burst paid them all back. Now: parse plus the first style and layout pass,
about 60 to 90 ms, the parse off the window's thread.

Not measured further: from the process's creation to `main` took 1.0 to 4.4 s in these runs (the start-up marks of the
report), before any code of ours: the loader and the antivirus on a freshly linked 59 MB executable.

### 2. A script-heavy page (`examples/jsbench/nodes10k.html`: 10 000 nodes made and removed per frame)

| stage | time per frame | share of the window thread's samples | notes |
|---|---|---|---|
| script: JS engine and DOM calls | 29 ms p50 (1.3 to 3 s at p99) | 50 % | ~20 000 DOM calls a frame (create, append, remove): ~1 µs each with the engine around them |
| style (partial restyles) | 15 ms | 12 % | 161 partial passes 2.5 s, 43 full passes 0.6 s in 26 s |
| layout (waits on the layout thread) | 20 ms p50, 31 mean | 26 % | the layout thread spends a third of its samples growing dynamic arrays on the heap |
| paint, chrome | 3.6 + 3.6 ms | 7 % | |
| GPU draw | 1.0 ms p50, 4.8 p95 | | |

31 to 35 frames/s at 60 Hz, 7.7 at 180 Hz; 1.2 to 1.7 cores; 1.1 to 1.35 GB private memory. The style engine holds
580 019 styled elements for 12 510 layout items: removed nodes live until the garbage collector frees their wrappers, so
handle indices grow and every array indexed by them with them, and partial restyles leave so much behind that 40 of the
43 full passes are "memory left by partial restyles".

After round 2 (medians of 5 runs of each build, interleaved, `js_nodes10k` at 180 Hz, 8 s):

| | before | after |
|---|---|---|
| frames/s | 28.3 | 42.9 |
| CPU work per frame, mean | 103 ms | 67 ms |
| script (Animation phase) | 54 ms | 42 ms |
| style | 14.1 ms | 9.8 ms |
| layout (waits on the layout thread) | 27.8 ms | 10.9 ms |
| styled elements (entries of `by_node`) | 840 000 | 10 000 to 20 000 |
| private memory | 1.27 GB | 305 MB |

Every style pass is now a full one ("too much changed": 10 000 changed of 20 000 live nodes) at 9.6 ms; before, 160 partial
restyles of 13 to 16 ms and 43 full passes of 12 to 15 ms. The collections the DOM now asks for (below) are about a
quarter of the window thread's samples: the cost of freeing the wrappers moved there from the engine's own collections.

After round 3 (medians of 5 runs of each build, interleaved): styles made by a full pass 20.1 -> 11.1 MB, the pass
9.4 -> 8.8 ms, private memory 302 -> 275 MB, CPU work per frame 63.0 -> 61.7 ms. On the page thread, where layout runs,
the samples in `NtFreeVirtualMemory` (its temporary memory given back after every pass) went from 2.7 to 3.2 % to none.
The style stage is a restyle of the 7 500 new elements whichever way it goes: with partial restyles allowed
(`style.incremental.max_ratio=1`) each costs 8.9 ms against 8.3 ms for a full pass, and the style stage per frame is the
same (8.1 against 8.3 ms).

**Where the script stage goes** (round 3, before its change; `WREN_SAMPLE_STACK=1 WREN_SAMPLE_UNDER=page::run_animation_frames`
for the browser's side, `jspage -image <engine built with buildjs -names> -profile` for the engine's, and micro-benchmarks
of single calls in `jspage`). A frame makes about 65 000 crossings from Wasm to the browser: `document` 10 000 times
(`Window_document`), createElement 7 500 times (three each: `Window_document` again, `Document_createElementChecked`,
`Node_wrap` for the pin and the interface), createTextNode 2 500 (two), appendChild 10 000, lastChild 5 000, removeChild
2 500, and the collection's `Node_unpin` for each of the 10 000 wrappers it frees.

| part | share of the script stage | ms a frame (of ~37) | what is in it |
|---|---|---|---|
| the collection the DOM asks for after the task (`js_after_task`) | 36 to 38 % | ~14 | the prologue that moves every node wrapper to its tree's group (half of it: one `Node_treeRoots` over all wrappers, a hash table of their ancestors in the browser, a reference taken and dropped on each), the finalizers (`Node_unpin`, `destroy_subtree`, the wrappers' memory), the trial deletion of the host references (a hash table of every referenced cell) |
| making the wrappers (`wj_wrap_node`) | ~15 % | ~5.5 | `Node_wrap`, the engine object and its `Obj`, the handle table, joining the document's group |
| the DOM's own work in the browser | ~12 % | ~4.5 | `pre_insert` and its hooks (scripts, links, media the insertion may start), `create_element` (2 %: a Unicode lower-casing through a string builder), the journal, the pins |
| the interpreter, property lookups up the prototype chains, argument conversions | the rest | ~13 | |
| the crossings themselves | ~4 % | ~1.5 | a getter that crosses costs what one that does not costs, ~25 ns apart (`firstChild` of a leaf 300 ns, `nodeType` 274 ns, a JavaScript call 115 ns): the call from the interpreter into a native function is the price of a DOM call, not the trip to the browser |

The engine's epoch callback (the chrome's preemption, `shell_preempt`) shows in 12 % of these samples; the sampler and the
epoch ticker both tick every millisecond, so that share is the bias already noted above, not work.

So a command buffer in the realm's memory (mutations recorded and applied in one pass, node indices reserved ahead,
names as atoms) would save the crossings, about 4 % of the stage, and keep everything else; the collection was more than a
third of it. Round 3 fixed that instead (below).

After round 3 (medians of 6 runs of each build, interleaved, `js_nodes10k` at 180 Hz, 8 s; the machine quiet):

| | before | after |
|---|---|---|
| frames/s | 49.4 | 59.6 |
| CPU work per frame, mean | 57.9 ms | 46.7 ms |
| script (Animation) | 35.8 ms | 25.1 ms |
| the collection's share of the script stage (sampled, 3 runs each) | 35 to 38 % | 19 to 20 % |
| style / layout | 8.9 / 9.6 ms | 8.8 / 9.4 ms |
| private memory | 304 MB | 295 MB |

Sampled against the style stage, which did not change, the script stage is 4.0 to 4.15 times the style stage before and
2.82 to 2.84 after (3 runs each): the collection 61 % less, the rest 10 % less.

After round 4, layout (medians of 5 interleaved runs): the window thread waits 8.1 -> 5.3 ms a frame on layout, a full pass
5.9 -> 3.5 ms (its paragraphs in columns now on the layout threads), 52.3 -> 55.1 frames/s.

After round 4, style (4 runs of each of the five builds, interleaved; median, range in brackets): the style stage 8.8 (8.0-9.1)
-> 3.3 (3.0-3.4) ms a frame, 11.1 -> 0.1 MB of styles a pass, 47.7 (45.3-53.4) -> 56.8 (55.8-61.5) frames/s, CPU work
per frame 60.6 (53.7-63.5) -> 50.7 (46.7-51.5) ms, private memory 280 -> 265 MB. What is left of the style stage on the
window thread: the top of the tree and the counters' walk in tree order (`compute_styles`, 46 % of the stage's samples),
the check of what was inserted (`inserted_exceed`, 18 %), the style threads' round (`parallel_for`, 19 %).

After round 5 (5 runs of each build, interleaved, the machine quiet; median, range in brackets): the style stage 2.94
(2.93-2.95) -> 1.82 (1.82-1.83) ms a frame (a full pass 2.96 -> 1.84 ms), the window thread waiting on layout 4.71
(4.70-4.74) -> 3.30 (3.30-3.31) ms, 86.2 (85.9-86.9) -> 92.5 (92.2-93.1) frames/s, CPU work per frame 33.2 (33.0-33.4)
-> 30.9 (30.8-31.0) ms, private memory 259 -> 258 MB.

After round 6 (5 runs of each build, interleaved; median, range in brackets): the script stage (Animation, the
collection included) 26.7 (22.0-27.0) -> 17.6 (15.8-18.5) ms a frame p50, 93.2 (91.5-93.8) -> 122.5 (120.1-123.8)
frames/s, CPU work per frame 30.7 (30.5-31.3) -> 23.3 (23.1-24.2) ms; the collection the DOM asks for 8.1 -> 5.3 ms
(timed in jspage, every 2 to 3 frames).

After round 7 (6 runs of each build, interleaved; median, range in brackets): the script stage 18.9 (17.0-19.1) ->
14.3 (13.6-14.9) ms a frame p50, 119.0 (114.6-123.2) -> 142.3 (133.9-143.0) frames/s, CPU work per frame 24.0
(23.2-24.9) -> 20.0 (19.9-21.3) ms; the collection the DOM asks for 5.4 (5.3-5.6) -> 3.8 (3.6-4.3) ms (jspage).

After round 8 (5 runs of each build, interleaved; median, range in brackets): the window thread waiting on layout
3.62 (3.53-3.95) -> 3.16 (3.14-3.19) ms a frame p50 (the display list 0.63 -> 0.39 ms, the block layout 1.24 -> 1.03),
the style stage 1.85 (1.82-1.98) -> 1.73 (1.73-1.74) ms, CPU work per frame 22.7 (21.3-26.8) -> 20.7 (20.6-21.4) ms.

After round 11 (the sampler and the in-process copy; the browser's runs were too noisy to tell frames apart): the search
for images on the window thread 0.07 ms a frame -> nothing, a full pass's finishing 0.32 -> 0.27 ms, the reads of every
box's border by the scans 0.13 -> 0.07 ms.

After round 12 (5 runs of each build, interleaved; median, range in brackets): the script stage 15.0 (14.7-15.7) ->
12.2 (11.9-12.7) ms a frame p50, 137 (108-145) -> 159 (130-167) frames/s, CPU work per frame 20.7 (19.7-26.4) -> 17.8
(17.0-21.9) ms; in jspage `build()` 11.1 -> 8.6 ms, the collection the DOM asks for 4.2 -> 3.7 ms.

After round 13 (5 runs of each build, interleaved; median, range in brackets): the script stage 12.15 (12.04-12.27) ->
11.39 (11.31-11.60) ms a frame p50, 164.6 (160.4-167.8) -> 169.0 (166.2-169.4) frames/s, CPU work per frame 17.4
(16.9-17.7) -> 16.8 (16.7-17.0) ms; in jspage the collection the DOM asks for 3.57 -> 2.89 ms, `build()` the same.

After round 15 (5 runs of each build, interleaved; median, range in brackets): the script stage 11.97 (11.79-12.33) ->
11.81 (11.63-22.41) ms a frame p50, CPU work per frame p50 17.94 (17.91-18.45) -> 17.74 (17.53-36.53) ms; the
interpreter alone (`micro.js`) 14 % faster, but nodes10k's script is the DOM's calls more than the interpreter's loop.

**Bottleneck:** the script stage (the interpreter and the wrappers it makes, the browser's insertions and the trees
the collection frees), then layout.

### 3. Scrolling a long page (p10k, 3 wheel notches every 16 ms)

167 to 177 frames/s (headless: one frame per input, the input's rate). CPU per frame 0.54 ms mean, 0.31 p50, 1.0 p95:
building the chrome 0.12, page paint 0.017, style 0.002, no layout. GPU draw 0.43 ms p50, 0.73 p95; present 0.06 ms.
44 to 100 ms of CPU a second.

**Bottleneck:** none near a budget; the GPU's draw (0.43 ms) is the longest stage, then the chrome's build.

### 4. A CSS animation (`examples/site/animations.html`, 123 elements)

60 frames/s, paced by the display (Wait 15.8 ms a frame). CPU per frame 0.72 ms mean, 0.56 p50: style 0.015, layout
0.066 (incremental, every other frame), paint 0.12, chrome 0.35, present 0.13; GPU 0.39 ms. 4.7 % of a core. The loop's
meter: 302 turns in 5 s, none asleep, every frame caused by the page.

**Bottleneck:** none; the display paces it. The chrome is half the CPU of a frame.

### 5. Script <-> DOM, one change per frame on a large page (`examples/site/mutation.html`, ~17 000 nodes, a Wasm module changes one text every 16 ms)

Before: CPU per frame 2.8 ms mean, 4.7 to 5.8 p95; the layout-shift scan (`timeline_layout_shift_check`) was **29 %** of
the window thread's work, the Largest Contentful Paint scan (`timeline_present`) 15 %, both walking all 16 000 boxes per
mutated frame. After the change below: 1.7 to 2.1 ms mean, 2.8 to 3.8 p95; the layout-shift scan 7.5 %. The loop: 350
turns in 5 s, 165 of them after a sleep, 207 frames for a task and 184 asked.

After round 2 (medians of 5 interleaved runs): CPU work per frame 1.70 -> 1.08 ms mean, 3.23 -> 1.72 p95; the Largest
Contentful Paint scan 0.2 to 0.48 -> 0.06 to 0.10 ms a frame (24 to 29 % -> 11 to 18 % of the sampled work), the walks
after a style pass 2.6 to 4.6 % -> 0.2 to 0.6 %. The same page with a class toggled instead of a text
(`mutation_class`): 2.84 -> 1.73 ms mean.

After round 3 (medians of 5 interleaved runs): a full style pass makes 13.5 -> 7.7 MB of styles (both pages), private
memory 234 -> 222 MB (`mutation`) and 258 -> 232 MB (`mutation_class`); a partial restyle 0.024 -> 0.021 ms and
0.243 -> 0.230 ms; CPU work per frame 1.19 -> 1.09 and 1.84 -> 1.79 ms mean.

After round 4 (5 runs of each build, interleaved, the order turning; median, range in brackets): a full style pass makes
7.7 -> 0.1 MB of styles (both pages); private memory 228 -> 217 MB (`mutation`); the same page
with every pass full (`mutation_fullstyle`) 5.1 (4.2-15.6) -> 2.1 (1.7-8.2) ms a pass, 15.3 -> 0.2 MB, CPU work per frame
12.0 -> 5.8 ms. A partial restyle of the one changed text costs what it did (0.02 to 0.03 ms: the passes' times are
counted in whole milliseconds, 5 to 19 ms over the 290 restyles of a run, before and after). `mutation_class` (5 runs
of each, interleaved, the order turning): a partial restyle 0.193 (0.187-0.203) -> 0.167 (0.152-0.232) ms, a full pass
7.5 -> 3 ms, CPU work per frame 1.42 -> 1.29 ms, private memory 236 -> 215 MB.

After round 5 (5 runs of each build, interleaved; median, range in brackets): `mutation_fullstyle` 1.52 (1.50-1.54) ->
1.17 (1.16-1.20) ms a full pass, the style stage 1.30 -> 0.93 ms a frame (p50), CPU work per frame 4.01 (3.97-4.05) ->
3.30 (3.28-3.39) ms. `mutation` and `mutation_class` the same before and after: CPU work per frame 0.69 and 0.71 ms,
1.20 and 1.21 ms; a partial restyle of `mutation_class` 0.152 (0.149-0.152) and 0.153 (0.152-0.160) ms.

After round 6: the three pages the same (CPU work per frame 0.71, 1.22 and 3.26 ms before and after, 5 runs of each).

After round 7: the same within the noise (CPU work per frame, mean, 5 runs of each: `mutation` 0.72 (0.70-0.80) and
0.71 (0.70-0.74) ms, `mutation_class` 1.46 (1.30-1.82) and 1.41 (1.27-1.46), `mutation_fullstyle` 3.38 (3.36-7.02) and
3.25 (3.22-5.30)).

After round 8: `mutation_fullstyle` a full pass 1.53 (1.46-1.74) -> 1.47 (1.40-1.61) ms without the journal's pairs, and
those take a third off what is left of the style stage (12 runs of each build, interleaved, on a busy machine: 1.65 (1.21-2.91) ->
1.10 (0.80-1.57) ms p50); `mutation` and `mutation_class` the same (CPU work per frame 0.85 and 0.85, 1.66 and 1.67 ms).

After round 14 (5 runs of each build, interleaved; median, range in brackets): `mutation_fullstyle`'s style stage 0.835
(0.833-1.235) -> 0.753 (0.747-0.815) ms a frame p50, what `::backdrop` had added to it (0.715 ms before it, round 13),
CPU work per frame 3.10 (3.00-5.69) -> 2.86 (2.81-4.77) ms; a full pass in process 0.632 -> 0.569 ms.

## What changed, round 1

1. **The frame pacer books no slot for a frame it does not pace** (`src/browser/pacing.odin`, `pacer_wait`). A headless
   window that a client waits on makes its frames at once; each one moved the next slot of `platform.Frame_Slots` a period
   on, so the first paced frame after a burst of 40 waited 40 periods with the loop's tasks queued behind it. Now such a
   frame resets the slot (`cadence.slots.next_ns = 0`). Load of p10k from the navigation: 1055 -> 34 ms. It also shortens
   every headless test and every `wren ctl` / CDP navigation in a headless Wren.
2. **The layout-shift scan reads flat arrays** (`src/page/timeline_lcp.odin`, `Ls_Boxes`; `lay.box_border` in
   `src/layout/query.odin`). It was `box_of_view` and `geometry_of_rects` for every box and a hash table of every box
   built per scan; now the border rect comes from the box and its space's offset, and the last scan's rects are two flat
   arrays indexed by the node's handle index, swapped after each scan, an entry valid when its scan number is the last
   one. Mutation page: 2.6 -> 2.1 ms CPU per frame (mean of means of 5 runs; p95 4.7 -> 3.8), its share of the work 29 % -> 7.5 %.
3. Tried and reverted: the same fast path in the Largest Contentful Paint scan (`lcp_candidate_of`): no difference that
   five runs could tell from the noise.

## What changed, round 2

Items 1, 3, 4 and 5 of round 1's list. Each measured against the build before it, 3 to 5 runs each; the share of a
function is from `WREN_SAMPLE=1 WREN_SAMPLE_STACK=1 WREN_SAMPLE_UNDER=<function>` (the samples with it on the stack),
since frame times on this machine move by a factor of 2 with its other programs. `wrentool bench perf -Runs n` now runs a
scenario n times and prints the medians.

1. **Removed nodes go back when they double the document** (`src/page/js_realm.odin`, `js_after_task`). A node a script
   made lives as long as its wrapper, and wrappers are freed only by a collection of the engine, which counts its own
   heap and not the nodes. After a script task, when the document's live nodes are twice what they were after the last
   collection the DOM asked for (`JS_GC_NODES_GROWTH`, from `JS_GC_NODES_FLOOR` nodes), the page asks for one: the
   dropped wrappers unpin their nodes, the detached trees go, their handle indices are reused, and every array indexed
   by node stays the document's size. nodes10k: 580 000 to 930 000 styled entries -> 10 000 to 20 000, 1.3 GB -> 307 MB,
   layout 29 -> 13 ms, 27 -> 34 frames/s (5 runs of each build interleaved). A growth of 8 instead of 2 was worse (16.9
   frames/s): fewer, longer collections, and arrays four times larger. This is not yet "as soon as no script holds the
   node": that needs wrappers freed by reference counting (next, item 1).
2. **Style: the threads' arenas kept, inheriting by runs** (`src/style/parallel.odin` `thread_arena_take` /
   `thread_arena_give` / `thread_arena_begin`, `src/style/props.odin` `inherited_runs`). Each parallel task of a full
   pass or of a partial restyle mapped a growing arena and the next full pass freed them all (`NtFreeVirtualMemory`, 10 %
   of the style stage); now the engine keeps them (`Engine.spare_arenas`, at most `style.recycle_bytes` of them), one
   reserved block each committed as it fills, and the thread that takes one empties it (the zeroing shared by the style
   threads; emptying them on the window's thread first cost as much as the frees). A child inherits by copying the
   inherited properties' bytes in runs joined across padding, not property by property. nodes10k: style 6.2 to 7.5 ->
   4.5 ms a frame on the window's thread, a full pass 12 -> 6 ms; `build_style` on the window's thread 0.26-0.32 -> 0.19-0.25
   ms a frame from the runs alone. Not done: splitting `Computed` (2 808 bytes, copied whole from the initial style for
   every element).
3. **Element Timing visits the elements that ask for it; the LCP scan skips what cannot win** (`src/page/timeline_lcp.odin`,
   `Document.timed` in `src/dom/dom.odin`). The document lists the elements given an `elementtiming` attribute (set
   and cloned attributes; the reader drops the stale ones), and Element Timing visits only them; it ran on every box of
   every changed or scrolled frame. The Largest Contentful Paint scan settles a box from its border box clamped to the
   viewport (`lay.box_border`, the layout's arrays) when that is no larger than the largest candidate so far, before the
   candidate's checks. Mutation page: 0.2 to 0.48 -> 0.06 to 0.10 ms a frame; what remains is `box_border` itself (57 %
   of the scan: a read of each box's struct). Scrolling p10k cost nothing measurable before or after: its scan stops at
   the first input and the page has no `elementtiming`.
4. **The walks after a style pass driven by what changed** (`src/page/images.odin` `images_sync`, `css_images_sync`;
   `src/page/fonts.odin` `fonts_sync`; `Styled.image_records` in `src/style/cascade.odin`). `images_sync` finds image
   elements in the subtrees the mutation journal says were inserted and in the elements whose attributes changed (the
   whole document only when the journal does not cover the change). `css_images_sync` does nothing when no style made
   since has a URL image and none was in use (the passes count the records they make with one); after partial restyles
   it reads the records the style journal names, unless one of them, or a node that left the tree, may have been the
   last user of a URL (`css_users`, a bit per node). `fonts_sync` looks only while a face is not loaded, then at the
   restyled elements. nodes10k: 0.6 -> 0.02 to 0.035 ms a frame (1.2 -> 0.2 % of the work); mutation page 2.6 to 4.6 %
   -> 0.2 to 0.6 %.

## Round 3: the locks of the loop and the network, measured against lock-free queues

Item 7 of round 2's list. The locks of `src/host`, `src/net` and `src/fetch`, and of what posts between them and the
loop, as producers and consumers:

| lock | produces | consumes | how often | held for |
|---|---|---|---|---|
| `host/loop.odin` `Loop.mu` | any thread posts a task (network drains, blocking jobs' completions, image decoders, the page thread, workers' links) | the loop thread, once a turn | every post: thousands a second during a load | an append; the turn's swap of the arrays |
| `net/client.odin` `Client.mu` | WinHTTP's threads (headers, each chunk of `read_chunk` bytes, done, failed) | the loop, one posted `drain` per burst | every network event | an append; the drain's swap |
| `net/websocket.odin` `Ws_Manager.mu` | WinHTTP's threads (frames, writes done, close) | the loop, one `ws_drain` per burst | every WebSocket event | an append; the swap |
| `host/thread_pool.odin` `mu` + `cond` | `parallel_for` (style passes, a few a frame) | the pool's threads | every round | three stores; the helpers' wake-up |
| `host/blocking.odin` `Blocking_Pool.mu` + 2 conds | the loop (`run_blocking`) | 4 workers | each blocking job (file reads, hashing): tens a second | an append; `ordered_remove(0)` |
| `host/thread.odin` `live_mu` | a thread starting or ending | the teardown's report | per thread | an append |
| `host/shutdown.odin` `sd.mu` | the teardown's steps | its watchdog | per step of a teardown | a copy of a name |
| `fetch/blob_urls.odin` `blob_store.mu` | `URL.createObjectURL`, `revokeObjectURL` (any App's thread) | a load of a `blob:` URL | per blob URL | a map lookup |

The built-in network stack (`network.backend = rust`) queues its events in the library (`native/`) and posts one
`rust_drain` when its queue stops being empty: nothing of ours to lock.

**Decision: the mutexes stay.** Two lock-free designs of the loop's queue were built and measured against `Loop.mu`
(the commits "The event loop and the network take no lock" and "The loop's queue, second design", kept in the history):
neither moved as many posts a second through a running loop from one thread, and the consumer was not faster; the
latency of a post was the same. The network's inboxes used the same queue (same verdict: they gain nothing at network
rates and lose the same way in a burst from one thread), and `parallel_for`'s round handed over by one atomic word was
slower than the mutex and condition (0.53 against 0.36 us a round). What was kept: the tests and the two benches.

1. First design: blocks of slots claimed by a compare-and-swap on the tail, the consumer popping one slot at a time.
   Four producers fought for the tail (10 M/s against the mutex's 25), and the consumer ran a third as fast.
2. Second design: a wait-free fetch-and-add claim; blocks found by number from a hint and linked by the first producer
   that needs one, retired with the tail's position when the consumer leaves them (a producer that may still hold one
   claimed before that mark: once the consumer has taken every position before it, the block is free to use again); the
   consumer walking the slots in place up to the position its turn began at; slots and the queue's fields on lines of
   their own; the wake left pending while work keeps coming, cleared only at the end of a turn that left nothing (so
   producers write nothing to it during a turn), and a call to the system only when the loop sleeps. Four producers now
   match the mutex. One producer does not: the loop, faster than the producer, catches up with it every 2 or 3 tasks
   (about 400 000 turns per million posts, against 11 000 to 17 000 with the mutex, which made the loop wait while the
   producer appended), and every catching-up moves the queue's lines between the two cores and slows the producer.
   Batching that away means making the loop wait for work it could run: a latency the mutex does not have.

`post_rate_and_latency` (`src/host/loop_test.odin`) and `parallel_for_round_cost` (`src/host/thread_test.odin`), `-Perf`,
`-o:speed`, the mutex and the second design, 7 runs each alternated; the median, range in brackets:

| | mutex | lock-free (second design) |
|---|---|---|
| 1 million posts through the running loop, 1 thread | 24.0 M/s (23.5-42.9) | 14.6 M/s (13.4-17.4) |
| the same, 4 threads at once | 20.6 M/s (19.7-29.7) | 21.4 M/s (20.9-36.5) |
| one thread posting, the loop not running | 38.4 M/s (36.2-42.1) | 34.4 M/s (30.8-38.0) |
| the loop running them alone | 198 M/s (162-204) | 172 M/s (137-213) |
| post to run on a waiting loop, median / 99th | 0.3 / 0.7 us | 0.3 / 0.7 us |
| a `parallel_for` round of 5 empty items on 4 threads | 0.36 us (0.31-0.42) | 0.53 us (0.43-0.63) |

The browser (`wrentool bench perf`, profile builds of the mutex and of the first design, headless, 3 runs of each
alternated; the median, range in brackets) could not tell them apart either: p10k_load 311 (257-411) against 255
(251-740) ms to load; mutation 75.5 (71.6-86.2) against 73.5 (72.4-104.5) frames/s; js_nodes10k 47.2 (43.9-47.9)
against 44.8 (44.4-47.0) frames/s. A post costs tens of nanoseconds either way, and a browser posts thousands a second.

What would change the verdict: a measured stall of the loop behind a producer descheduled with the lock held (the
frame timeline would show a turn that waited on `Loop.mu`); none has been seen.

## What changed, round 3: style and layout

Items 2 and 3 of round 2's list, and the profiler (item 8) to see the threads where the work now is. Measured as in
round 2: 5 runs of each build interleaved (`wrentool bench perf`, one scenario after the other with each build in turn),
and the shares of the samples.

1. **`Computed` split by group** (`src/style/types.odin` `Group`, `src/style/props.odin`). What few elements set is in
   six groups behind a pointer each, with `using`, so every read is unchanged (`c.transform`): the background layers
   (240 bytes), transforms (184), transitions and animations (224), grid (256), masks (128), and the rest (effects,
   counters, containment, container queries, scrolling, anchors: 280). A style shares the groups of the initial values,
   built once in read-only pages, until it sets a property of one; the cascade then copies that group once for the
   element (`cx_take`, called by `apply_prop` and the `inherit` / `initial` / `unset` copies); code that writes into a
   style elsewhere (the timeline's overlays and transitions, keyframes, scratch styles of interpolation, layout's
   anchored boxes) takes its own copy first (`prop_take`). A write into a group that is not one's own changes every style
   that shares it: into the initial values it faults at once, which is how the tests found the two that did. The
   comparisons (`computed_equal`, `layout_equal`, the layout journal's runs) skip a group the two styles share. An
   element's style is 1 544 bytes instead of 2 808, plus the groups it sets. nodes10k: 20.1 -> 11.1 MB of styles a full
   pass, the pass 9.4 -> 8.8 ms, 302 -> 275 MB; mutation pages 13.5 -> 7.7 MB a pass, partial restyles 5 to 12 % faster;
   p10k loaded: 13.5 -> 7.7 MB. The style threads zero the arena they take back (`arena_free_all`, 13 % of their samples
   on nodes10k): half the bytes now. No group holds an inherited property: inheriting still copies the inherited
   properties' bytes (about 500 of the 1 544, see Next).
2. **The layout thread's heap growth** (`src/browser/page_thread.odin`). With the profiler able to see it (below), the
   growing dynamic arrays of round 1 are gone from the page thread (round 2's node lifetime fixed them: the arrays
   indexed by node stay the document's size). What was left: its temporary memory. The runtime's temporary arena keeps
   only its first block (4 MB); a layout pass of nodes10k needs more, so every pass mapped more blocks and `free_all`
   gave them back (`NtFreeVirtualMemory`, 2.7 to 3.2 % of the thread, and fresh pages faulted in at the next pass). The
   page thread now keeps one block as large as its largest pass needed (times 5/4, up to 512 MB), emptied after each:
   `NtFreeVirtualMemory` 0 % of its samples.
3. **Partial restyle on nodes10k: measured, not changed.** Every frame inserts 7 500 new elements: a partial restyle
   restyles them all, as a full pass does, and leaves the old records in the arena (a full pass every sixth frame for
   "memory left by partial restyles"). Allowed (`style.incremental.max_ratio=1`), a partial restyle costs 8.9 ms against
   8.3 for a full pass, and the style stage per frame is the same; layout is a full pass either way. What a restyle of
   new elements costs is the cost of styling an element (matching, building the style), which item 1 lowered.
4. **The profiler samples the threads that run** (`src/browser/prof.odin`, `other_sampler_proc`): each millisecond the
   thread with the most CPU cycles since its last sample (`QueryThreadCycleTime`, handles kept open), so a thread is
   sampled in proportion to its CPU time; per thread, the functions anywhere on its stack. nodes10k: the page thread
   160 -> 1 900 samples in 15 s; the main sampler, which it counted as the busiest thread, is left out.

## What changed, round 3: the script stage

The script stage of nodes10k, measured first (the table in section 2), then the largest part of it.

1. **A wrapper that carries nothing of its own is in no group** (`native/js/odin/wj/qjs_platform.odin`, `wrapper_plain`,
   `gc_prologue`). Every node wrapper was a member of its tree's group, the document's included, so every collection's
   prologue placed every wrapper (a reference taken and dropped on each, the browser walking every wrapper's ancestors
   through a hash table) and the trial deletion counted them all. A wrapper with no listener, no [SameObject] value, no
   data of the engine, no own property, its interface's prototype, extensible, and never a WeakMap / WeakSet key, a
   WeakRef or FinalizationRegistry target (`OBJ_HELD_WEAKLY` in `src/engine/jsrt`, `JS_IsUntouched`) can go when no
   script holds it, connected or not, and be made again, the same, when a script reaches its node: nothing tells the two
   apart. It joins a group only when its tree is detached and has a group (holding any wrapper of a detached tree must
   keep the others), and new wrappers start in none (only a collection frees, and its prologue places them). The
   prologue crosses for the other wrappers alone, and for the plain ones only when some detached tree has a group.
   Test: `js_plain_wrappers_go_the_others_stay_the_same` (web_realm.odin).
2. **The trial deletion of host references without a hash table** (`src/engine/jsrt/gc.odin` `gc_mark_ext`,
   `host_class.odin` `host_mark_value`): the counts are subtracted in the cells themselves and put back from a flat array.
3. **Element names lower-cased in ASCII** (`src/dom/dom.odin` `create_element`, `lower_name`): DOM's createElement
   and getElementsByTagName ask for ASCII lower case; the Unicode lower-casing went through a string builder rune by
   rune (2 % of the script stage). WPT dom/nodes: 27 subtests better (case.html, createElement("İnput"),
   getElementsByTagName of non-ASCII names); one worse, case.html's `getElementsByTagName a:Ä`, which compares names the
   way the other `a:` cases of that file already got wrong.


## What changed, round 4: layout of DOM-heavy pages

Item 3 of round 3's list. Measured as in round 3 (`wrentool bench perf`, the base and the new profile build in turn, 5
runs each; the median, range in brackets) and with the profiler on the page thread (`WREN_SAMPLE_THREADS=1`).

1. **Column balancing: measured, not changed.** Counted on nodes10k (2 500 list items in six columns): a multi-column
   container lays its content out once per pass (`layout_multicol` already lays it out in one strip and cuts it:
   `gather_units`, `place_units`), and balancing tries 4 heights, each a walk of the 2 500 units in their flat array:
   0.05 ms of a 2.3 ms block layout. Laying the content out again is left to what forces it (a nested container that
   crosses a column, `MC_NEST_TRIES`). What the 36 % of the page thread in the multi-column layout was: the paragraphs in
   the columns laid out on the page thread alone. A page with columns turned `frames_on` on, and a pass with frames ran
   without the layout threads. Now a full pass whose frames are all horizontal (columns, no vertical writing mode) lays
   its simple paragraphs out ahead on the threads like any other page (`pre_run`, `parallel.odin`): the width
   prediction goes into the columns (`pre_widths`: a column's width, a spanner the container's), and the flows are
   marked before the threads start (`flows_mark`: `mark_flow` writes flags of the boxes the threads read). Incremental
   passes and vertical frames keep one thread. nodes10k: 2 501 of 2 501 paragraphs laid out ahead and taken; the block
   layout's step 2.64 -> 1.19 ms.
2. **The font of an element** (`font_info`, `context.odin`; `Style_Sum`, `style_sum.odin`). The per-pass map from a 64
   byte key to a font (hashing the key cost about 380 cycles a lookup, half the elements of nodes10k looked one up) and
   its one-entry memo are gone: a pass's fonts are a short flat list compared whole, tried after the font of the
   parent (`near`). The summaries made on the layout threads say which elements have their parent's font
   (`Parent_Font`, the keys compared there): construction then reads none of their font properties, and a text whose
   style is its parent element's takes that element's font (`Frame.font_el`, `Frame.fi`). Not a cache: nothing is kept
   from one pass to the next, the list is the pass's fonts. The summaries also carry the decorations, `column-span` and
   negative margins, which construction and `mark_bfc_floats` read from each style before (each a cache miss on a style
   made on another thread). The tree step: 1.81 -> 1.08 ms.
3. **The page thread's temporary block, as round 3 meant it** (`page_thread.odin`): the block was set as the context's
   temporary allocator inside an `if`, and an assignment to the context lasts as long as its block: every pass ran on
   the runtime's own temporary arena, mapping blocks past the first and giving them back (`NtFreeVirtualMemory` 3 to 5 %
   of the page thread once the threads made the pass use more). Set at the scope of the thread's procedure, the block
   grew once (to 6.6 MB, then 7.4 MB a pass) in 410 passes.
4. **Smaller ones**: the bounds of a box in a flow without a list on the heap (`flow_bounds`, once for every box and
   line of the flow in `compute_overflow`: the finish step 0.69 -> 0.35 ms); the incremental attempt adds a container as
   a rebuild root once, not once per child that changed (`add_target`: 7 500 entries of the same `ul` on nodes10k).
5. **Short text runs: measured, not changed.** Before 1, measuring words was `word_find` (the toolkit's word cache), 3.6 %
   of the page thread; with the paragraphs on the layout threads it no longer shows on the page thread, and shaping
   proper (`shape_run`) shows only in the window thread's paint (5.7 % of `Paint_Items`, 1.4 ms a frame). An advance
   table for ASCII runs would save little here, and its exact fallback needs what the font's kerning and ligature
   tables do with those characters: not done.

The private memory grows by the summaries' and the predictions' temporary arrays and the layout threads' own; p10k_load,
p10k_scroll and mutation move within their noise (the load of p10k by the machine's other programs, a factor of 3), and
multicol.html resized makes incremental passes, which keep one thread.

| | before | after |
|---|---|---|
| nodes10k: the window thread waiting on layout, p50 a frame | 8.14 ms (8.02-31.5) | 5.27 ms (5.19-14.5) |
| nodes10k: a full pass (p50 of each step) | 5.94 ms | 3.48 ms |
| ... tree | 1.81 (1.75-6.45) | 1.08 (1.06-3.75) |
| ... block layout | 2.64 (2.61-11.3) | 1.19 (1.16-2.90) |
| ... finish | 0.69 (0.69-1.64) | 0.35 (0.35-0.68) |
| ... display list, bands | 0.70 + 0.15 | 0.73 + 0.13 |
| nodes10k: frames/s, CPU work per frame (mean) | 52.3, 54.9 ms | 55.1, 52.2 ms |
| nodes10k: private memory | 279 MB | 288 MB |
| p10k_load: load, first layout | 742 ms (255-792), 1.94 ms (1.04-3.20) | 789 ms (250-943), 1.80 ms (0.90-2.63) |
| p10k_scroll: frames/s, CPU work per frame p50 | 167, 0.52 ms | 165, 0.40 ms |
| mutation: frames/s, CPU work per frame mean | 73.1, 1.01 ms | 73.5, 0.99 ms |
| examples/site/multicol.html resized (incremental passes): layout p50 | 0.074 ms | 0.074 ms |

## What changed, round 4: the cost of styling one element

Item 2 of round 3's list. Five profile builds measured against each other (the one before the round, then each step on
top of the last), interleaved, `wrentool bench perf` and the sampler as in round 3.

1. **Identical styles shared** (`src/style/share.odin`). A computed style is a value, made of: its parent's style (the
   record), the declarations that match the element (its matched entries: rule, selector, encapsulation context, for the
   element and for its styled pseudo-elements: ::before, ::after, ::selection, ::placeholder), its style attribute (by text), its encapsulation depth, and
   what is the same for the whole pass (the rules, the media environment, the page's color scheme, the settings). Two
   elements of one pass whose inputs are equal get one record: a table per pass (flat, open addressing; the keys' words
   in one array) maps the inputs to the record the first one got. It is not a cache: it holds the values the pass made,
   lives as long as that pass, is never asked about another and never invalidated, and an element it does not find costs
   what it cost before. What makes a style the element's own keeps it out of the table: presentational hints (attributes
   as declarations), a `lang` other than the parent's language, an element the embedder hides or that is above the top
   layer; a query container (its size is the element's), position-try fallbacks, a list marker that shows a counter,
   generated content with attr(), counters or quotes. A record in the table is never written again: what markers and
   generated content resolve to is resolved when it is made, and the counters' walks write a value only when it differs.
   So a record no longer says whose it is: `Styled.nodes` holds the element of each slot (what `style_of` checks against
   a recycled index), and layout's refresh (`layout/refresh.odin`) re-points an element's inline items by the element,
   not by the record its old record became for some box (the demo pages' random mutations found a link left with the
   record of a block that had shared its style). A partial restyle that finds the style it made equal to the one in
   force puts that one in the table and drops what it made, as before. Tests: `src/style/share_test.odin` (one record for equal inputs; two for a
   style attribute, an attribute read by attr(), `lang`, `:hover`, the container of a query or of cq units that differ;
   numbered markers). nodes10k: 11.1 -> 0.2 MB of styles a pass, the style stage 8.8 (8.0-9.1) -> 7.6 (7.4-8.0) ms, 47.7
   -> 52.9 frames/s; `mutation_fullstyle` 5.1 -> 2.0 ms a pass (best runs 4.2 -> 1.9), 15.3 -> 0.3 MB; p10k loaded 7.7
   -> 3.2 MB.
2. **The inherited properties in a group of their own** (`Inherited_Group`, `src/style/types.odin`), shared with the
   parent until the element sets one: an element that sets none inherits by one pointer (it copied about 500 bytes,
   `inherit_all`, now gone). The cascade takes the group on the first write (`cx_take`, `cx_own`): `apply_prop`, the
   `inherit` / `initial` / `unset` copies (a copy from the parent whose group it shares is nothing to do), and the
   derived values, written only when they differ: `scheme_settle`, the legacy `white-space`, the content language, the
   monospace size, `text-combine-upright` out of a vertical mode. Outside the cascade: the timeline's `push_inherited` and
   `pseudo_inherit` and `derive_fields` take their own copy; layout's anonymous boxes share their parent's (the
   `border-spacing` they copied again was the same value and is no longer written). The initial inherited values follow
   the preferences: one group per style pass (and per configuration for validating declarations), not read-only pages.
   An element's style is 1 KB instead of 1.5. nodes10k: no change (its styles were shared already); p10k loaded 3.2 ->
   2.7 MB a pass; `mutation_fullstyle` 0.3 -> 0.2 MB, the pass the same within the noise (best runs 1.9 -> 1.7 ms).
3. **The style arenas emptied without zeroing** (`style_arena_allocator`, `style_arena_empty`, `src/style/cascade.odin`).
   A virtual arena zeroes what it held when it is emptied, so that what it hands out next is zero: the computed styles
   and their groups, which the cascade overwrites whole, were zeroed twice. The style threads' arenas and the pass's own
   are now emptied by resetting their block; what is allocated from them is zeroed when it is handed out, except the
   records and the groups (`record_new`, `group_take`). On nodes10k the zeroing was 13 % of the style threads because
   each pass made 11 MB: after item 1 it makes 0.1 MB and the zeroing was gone already. `mutation_fullstyle`:
   `arena_free_all` 1.6 % of the busiest style thread's samples -> none (the allocator 2.4 %); the pass the same within
   the noise.
4. **A restyle of mostly new elements gives up before marking them** (`inserted_exceed`, `src/style/restyle_dom.odin`).
   On nodes10k every frame tried a partial restyle first, marked what the 10 000 journal entries reach (the invalidation
   index, the sibling walks), estimated the work, and found it too much: that marking cost twice the full pass that
   followed (half of the style stage's samples, `mark_mutations`). The elements of the inserted subtrees are restyled
   whole, so their count is a lower bound of the estimate: past the limit, the answer is the one the marking would give
   (documents without shadow trees; not with `WREN_RESTYLE_TRACE`, which reports the marks). nodes10k: the style stage
   7.6 (7.3-7.9) -> 3.3 (3.0-3.4) ms a frame, 52.2 -> 56.8 frames/s, CPU work per frame 54.9 -> 50.7 ms.

What was measured on the other pages, before the round and after it (medians, ranges in brackets): `mutation` and
`mutation_class` above (map, 5); `examples/site/modern-css.html` resized (240 full passes a run, 5 runs of each build):
0.95 (0.95-1.01) -> 0.96 (0.95-1.84) ms a pass, 0.2 MB, CPU work per frame 0.40 -> 0.39 ms; p10k loaded (5 runs of
each): 240 (238-280) -> 241 (240-776) ms to load, its full pass 6 (6-7) -> 6 (5.5-13.5) ms, 7.7 -> 2.7 MB of styles.
The machine ran other agents' builds meanwhile: single runs moved by a factor of 2 to 3, hence the ranges.

## What changed, round 5: matching, the walks in tree order, the incremental attempt

Items 2 and 3 of round 4's list. The base and the new profile build in turn (`wrentool bench perf`), 5 runs each on a
quiet machine; the shares are the sampler's (`WREN_SAMPLE_STACK=1 WREN_SAMPLE_THREADS=1`), on profile builds of both.

1. **Matching shared between siblings and cousins** (`src/style/sibling_match.odin`). Two sibling elements with the same
   tag and the same attributes look up the same entries of the index, pass the same ancestor filter, and every part of
   a selector matched against an ancestor answers the same for both: what can tell them apart is only what a selector
   asks of the element itself beyond its tag and attributes (its position among its siblings, a sibling combinator to
   its left, its state, its content, :has(), :scope). Such an entry is `own` (`Entry.own`, from the selector when the
   index is built, `selector_deps`). Cousins (children of alike parents, up to a common ancestor) differ besides by what
   a selector asks the same way of an ancestor or of an ancestor's sibling (`Entry.above`). The walk in tree order keeps,
   for each depth, a family: the children of one parent or of alike parents, and for each kind of element in it (up to
   `SIB_FAMILY_KINDS`) the first one, matched in full, with the entries it matched and those the others must try again
   (with its answer). The next element of a kind takes them, matching again only `own` entries, and `above` ones for a
   cousin; its lists are those a full match gives, in the same order, so the share table (round 4) then finds its style.
   Full passes, the style threads and the restyle walk use it (an element a partial restyle passes without matching it
   starts a family of its own below it: `sib_pass_by`); documents with shadow trees do not (the flat tree's siblings may
   come from different trees). Not a cache: it holds what this pass matched for elements before, is dropped when the
   walk meets another family at that depth, and nothing in it outlives the pass or is invalidated. Test:
   `sibling_match_test.odin` (on a page with every kind of selector that tells alike elements apart, each element's
   lists against a full match, hovered elements and parents included, and how many took their matching from another).
   On `mutation_fullstyle`, `collect_entries` was 44 to 53 % of the busiest style threads' samples, and is 1.5 %; what
   matching is left is the entries matched again (`match_chain` 12 to 21 %: the browser's own `:disabled`,
   `:focus-visible`, `:popover-open` and `:fullscreen` reach every element, and `:disabled` asks the forms model).
2. **No counter walk when no box shows a counter** (`counters_tally`, `src/style/counters.odin`). After a parallel pass
   the counters and quotes are resolved by a walk in tree order. It writes only what a box shows (numbered markers,
   counter() and quotes in content) and says whether a counter is used (`counters_used`, which partial restyles read).
   The style threads now count, of the boxes shown, those that show a counter or a quote and those that change one: with
   none of the first, the walk has nothing to write and its answer is whether any of the second exists. nodes10k (bullets,
   and the `ul` that resets list-item) needs no walk. Test: `parallel_pass_counters_without_the_walk`.
3. **The check of what was inserted, flat** (`inserted_exceed`, `src/style/restyle_dom.odin`): the inserted nodes are
   bits by handle index (set for live handles only: the index of a node that went may be another node's), a second set
   keeps a node inserted twice from counting twice, and one walk up from each node stops at an inserted ancestor or
   finds the document; it was a hash set, a walk up to find whether the node is connected and another to find an inserted
   ancestor. With 2 and 3 the window thread's share of the style stage of nodes10k: `compute_styles` itself (with the
   walk inlined) 112 -> 57 samples, `inserted_exceed` 61 + `connected` 20 -> 35, the stage 1 139 -> 608 samples in runs of
   the same length.
4. **The incremental attempt decides from the removed boxes first** (`removed_boxes`, `src/layout/incremental.odin`).
   Every box of an element the journal says was removed is made again with its subtree, as a plan of its own or inside a
   container rebuilt whole: their count is a lower bound of what the attempt would find, and past the limit the attempt
   gives up before looking for what to rebuild (`add_target`, `touched_ancestor`, `plan_children`, quadratic in the
   children of one container, `subtree_size`). A bit per box marks those of removed elements, so a subtree inside another
   counts once; one inside a replaced element is left out (its container is laid out again, not rebuilt). nodes10k:
   what the page thread did besides its full pass (`layout_document` less `run_full`, nearly all of it that search) was
   23 % of its samples, 0.3 % now.
   Test: `inc_removed_boxes_decide_first`.
5. **Measured, not kept.** The display list of a flow (`push_flow_item` copied a `Space` of hundreds of bytes and every
   fragment for each item; `emit_lines` read visibility and pointer-events from each text's style where the box's flags
   hold them when the box has the text's style): rewritten without the copies and reads, the display step of nodes10k was
   0.63 (0.60-1.21) ms before and 0.67 (0.62-0.76) after; the compiler loaded only the fields used, and the styles read
   are the few shared records, in cache. The page thread's temporary block emptied without zeroing (what is allocated
   zeroed when handed out instead): the window thread's wait on layout 3.32 (3.24-3.48) against 3.30 (3.28-3.32) ms
   without it (6 runs each), the same bytes zeroed at another time.

| | before | after |
|---|---|---|
| nodes10k: style stage p50, a full pass | 2.94 (2.93-2.95), 2.96 ms | 1.82 (1.82-1.83), 1.84 ms |
| nodes10k: the window thread waiting on layout, p50 | 4.71 (4.70-4.74) ms | 3.30 (3.30-3.31) ms |
| nodes10k: frames/s, CPU work per frame (mean) | 86.2 (85.9-86.9), 33.2 ms | 92.5 (92.2-93.1), 30.9 ms |
| `mutation_fullstyle`: a full pass, style stage p50, CPU work per frame | 1.52 (1.50-1.54), 1.30, 4.01 ms | 1.17 (1.16-1.20), 0.93, 3.30 ms |
| `mutation`: CPU work per frame, mean | 0.69 (0.69-0.76) ms | 0.71 (0.69-0.72) ms |
| `mutation_class`: a partial restyle, CPU work per frame | 0.152, 1.20 ms | 0.153, 1.21 ms |
| p10k_load: load, its full style pass | 241 (237-356) ms, 6 ms | 248 (239-355) ms, 5.5 ms |
| p10k_scroll: frames/s, CPU work per frame p50 | 175, 0.29 ms | 175, 0.29 ms |
| `examples/site/modern-css.html` resized: a full pass, CPU work per frame | 0.93, 0.38 ms | 0.95, 0.38 ms |
| private memory: nodes10k, `mutation_fullstyle` | 259, 237 MB | 258, 237 MB |

The full pass of a page whose elements are each of their own kind (modern-css, p10k's generated sections, a full pass
of `mutation_class` counted in whole milliseconds) costs what it did: each element is matched in full once, and the
families cost a comparison of tags and attributes. WPT, css/ (921 testharness tests, 1 605 reference tests), shadow-dom
and dom/nodes, base and new against the same checkout: the same reference test results (914 pass), the same subtests in
shadow-dom (9 310 pass) and dom/nodes (7 580); in css/ 20 671 and 20 681 subtests pass, the difference all in the
interpolation tests of css-transforms and css-multicol, which move by as much between runs of one build.

## What changed, round 6: the script stage of DOM-heavy pages

Item 1 of round 5's list. Profiled first: the engine's own samples (`jspage -image <engine built with buildjs -names>
-profile`: Wasmtime's guest profiler, a sample at each epoch tick), the browser's side with `WREN_SAMPLE_STACK=1
WREN_SAMPLE_UNDER=page::run_animation_frames`. The guest profiler takes its sample where Wasm code checks the epoch
(function entries, loop heads): the time of a call into the browser is counted to the first function the engine enters
after it returns (`JS_DupValue` after `Node_preInsert`, `libc_free` after `Node_unpin`, `wj_wrap_node` after
`Document_createElementChecked`), which the shares below take into account. Each change was measured on its own with a
timed copy of nodes10k in `jspage` (the time of the page's `build()` a frame, p50 of 400 frames; for the collection, a
timer around `js.collect` in a build of jspage that was not kept), the build before it and the build with it in turn, 3
runs each; then the browser (`wrentool bench perf`, 5 runs of each build, interleaved, the order turning).

1. **Document and Window objects are plain platform objects** (`class_kind_of`, `src/tools/bindgen/jsgen/jsgen.odin`).
   An interface with a named property getter in its IDL got the named class, whose own-property hook runs on every read
   of a property the object does not hold itself: every `document.createElement` asked it (through the C API's bridge),
   and the interpreter's fast path gives up on any object with an exotic hook. The glue implements no named getter for
   Document, Window (nor XMLDocument, TouchEvent): the hook could only answer "none". The class is now named only when
   the glue implements the getter on the interface or one it inherits from (Storage, DOMStringMap). `build()` 18.8
   (18.8-19.1) -> 17.3 (17.2-17.3) ms.
2. **A wrapper's interface by the name's first byte, then the name** (`emit_name_switch`,
   `src/tools/bindgen/jsgen/outputs.odin`; `js_html_interface`, `js_svg_interface`): a switch on strings compares them
   one after the other: 58 comparisons for `li`, 90 for `span` (`string_eq` under `Node_wrap`, 2 % of the window
   thread's script stage). 17.6 (17.5-17.6) -> 16.6 (16.6-16.6) ms. Test: `element_interface_by_name`.
3. **The insertion steps in one walk** (`inserted_kinds`, `src/page/js_load.odin`). Every insertion walked the inserted
   subtree three times (style sheets, media elements, scripts and frames), each with a list of its own; one walk now
   notes which of those names the subtree holds, and only the steps that found something look further. 16.6
   (16.3-16.6) -> 15.7 (15.6-15.8) ms. Test: `inserted_subtree_kinds`.
4. **The wrapper's platform object in the engine's block** (`JS_NewObjectProtoClassPayload`, `src/engine/jscapi`;
   `Host_Object.payload`, `src/engine/jsrt/host_class.odin`). A wrapper took three allocations: the object (the engine's
   size classes), its host part (`new` through the engine's general allocator) and the glue's `Obj` (`libc_calloc`),
   and its finalizer freed the last two. The host part is now a block of the size classes that holds the `Obj` after it,
   freed with the object. 15.8 (15.6-16.1) -> 14.4 (14.0-15.0) ms. Test: `judge capi` (payloads zeroed, one per object,
   a cycle through them collected, 10 000 made and dropped without the heap keeping them).
5. **The C API reads a value without decoding it** (`cell_of`, `object_of`, `src/engine/jscapi/types.odin`):
   `JS_DupValue`, `JS_FreeValue`, `JS_GetOpaque`, `JS_SetOpaque`, `JS_GetClassID` built a whole engine value out of
   the word (a switch over every tag) to read a pointer, and `JS_DupValue` copied the Odin context for every value, a
   number too. The collection the DOM asks for calls them for every wrapper (its prologue's `obj_of`, `gc_mark`, the
   finalizers): 8.1 (7.0-8.3) -> 5.8 (5.8-5.8) ms a collection; `build()` 14.1 (14.0-14.2) -> 13.3 (13.2-13.3) ms.
6. **A getter is called where the lookup found it** (`get_field` in `src/engine/jsrt/interp.odin`, `global_get` in
   `globals.odin`): a DOM attribute (`lastChild`) was found on the prototype chain, given up as not a data property,
   looked up again by `get_property`, then called; a global accessor (`document`, [LegacyUnforgeable] and so the
   window's own) went through `[[HasProperty]]` and `[[Get]]` after the slot lookup that had found it. 13.3
   (13.1-13.5) -> 12.6 (12.5-12.8) ms.
7. **Measured, not kept.** `destroy_subtree` (the browser frees each tree the collection unpins) with a list of inline
   capacity instead of a heap list per call: 8.10 against 8.28 ms a collection, `build()` the same (the destruction is
   the nodes' own memory: their names and texts, the pool).

The browser, all of it (5 runs of each build, interleaved, the order turning; median, range in brackets):

| | before | after |
|---|---|---|
| nodes10k: frames/s | 93.2 (91.5-93.8) | 122.5 (120.1-123.8) |
| nodes10k: CPU work per frame, mean | 30.7 (30.5-31.3) ms | 23.3 (23.1-24.2) ms |
| nodes10k: script (Animation, with the collection), p50 | 26.7 (22.0-27.0) ms | 17.6 (15.8-18.5) ms |
| nodes10k: style stage, the window thread waiting on layout, p50 | 1.82, 3.33 ms | 1.62, 3.27 ms |
| `mutation`: frames/s, CPU work per frame mean | 74.9, 0.71 ms | 76.8, 0.71 ms |
| `mutation_class`: CPU work per frame mean | 1.22 ms | 1.22 ms |
| `mutation_fullstyle`: CPU work per frame mean, style stage p50 | 3.26, 0.90 ms | 3.26, 0.91 ms |
| p10k_load: load | 238 (233-245) ms | 241 (234-250) ms |
| p10k_scroll: frames/s, CPU work per frame mean | 173, 0.354 ms | 173, 0.353 ms |
| `examples/site/modern-css.html` resized: CPU work per frame mean | 0.388 (0.385-0.392) ms | 0.384 (0.382-0.393) ms |
| private memory: nodes10k, `mutation_fullstyle` | 261, 237 MB | 258, 237 MB |

A first build without item 6 measured nodes10k at 90.1 -> 115.2 frames/s (5 runs each, an earlier hour). What the
engine's samples of nodes10k are now (the guest profiler, 40 s; the time of the browser's calls counted as said above):
`createElement` a quarter (the browser's `Document_createElementChecked` and `Node_wrap`, the wrapper, the name copied
to the C heap and freed), the collection a fifth (its finalizers four fifths of it, most of that the browser's
`Node_unpin` and the destruction of the trees it frees; the prologue's visit of every wrapper), `appendChild` a tenth
(the browser's `Node_preInsert`), `createTextNode` 8 %, the arguments' strings copied for the browser (`JS_ToCStringLen2`)
8 %, the getters (`document`, `lastChild`) 5 %, the interpreter's own loop the rest.

## What changed, round 7: the script stage of DOM-heavy pages, what was left

Item 1 of round 6's list, measured as round 6 did: the engine's samples (the guest profiler in `jspage`, its bias noted
there: the finalizers' `Node_unpin` showed as `libc_free`, 13 % of the samples, `Node_preInsert` as `JS_DupValue`), the
browser's under `page::run_animation_frames` and under each import (`WREN_SAMPLE_UNDER`). Each change was timed in
`jspage` on a copy of nodes10k (`build()` a frame, p50 of 400 frames; the collection with a timer around `js.collect` in
a build of jspage that was not kept), the build before it and the build with it in turn, 4 to 8 runs each; then the
browser, all of it (6 runs of each build, interleaved).

1. **A collection unpins its nodes in one call** (`unpin_later`, `gc_epilogue`, `native/js/odin/wj/qjs_platform.odin`;
   `JS_SetGCEpilogue`, `src/engine/jscapi`; `Host_Config.gc_epilogue`, `src/engine/jsrt`). A finalized node wrapper
   called the browser's `Node_unpin`, one call for each of the 10 000 wrappers a collection frees; their handles now go
   into a flat array and the epilogue, called at the end of every collection and at the runtime's teardown, hands them
   to `Node_unpinAll` (which, as `Node_unpin` did, runs nothing when it returns: `hold_reactions`). The collection 5.45
   (5.20-6.03) -> 4.98 (4.90-6.24) ms. Test: `judge capi` (the epilogue once a collection, after its finalizers).
2. **The string arguments of the bindings read in place** (`JS_ToStringView`, `src/engine/jscapi/misc.odin`;
   `STR_VIEW`, `native/js/odin/wj`). Every string argument was copied to the C heap (`JS_ToCStringLen2`: an UTF-8 copy
   in a fresh block) and freed after the call. A string that is all ASCII is its own UTF-8: the generated bindings,
   whose imports read the bytes before the native returns while the caller holds the argument, and `createElement`, now
   pass its bytes where they are (a rope is flattened first; any other string is copied as before). `build()` 12.35
   (12.34-13.68) -> 11.08 (10.98-11.47) ms. Test: `judge capi` (ASCII, a concatenation; no view of Latin-1, UTF-16, a
   number, an object).
3. **Element names are the program's strings** (`STATIC_NAMES`, `static_name`, `set_name`, `src/dom/names.odin`;
   `Node.name_static`). `create_element` copied each name to the heap (half of the browser's `createElement`, under
   `RtlAllocateHeap`) and the destruction of the tree freed it. A name of the HTML elements, the older ones the parser
   meets, or SVG's and MathML's most used (by first letter, at most `NAME_STATIC_MAX` bytes) is now the program's
   string, shared by every element of that name and its clones; any other is copied as before. `build()` 11.06
   (10.97-11.22) -> 10.62 (10.53-10.69) ms. Test: `element_names_static_or_copied` (the test runner's allocator reports
   a static name freed or a copy leaked).
4. **The wrappers of nodes in an array by handle index** (`Node_Table`, `qjs_platform.odin`). The glue found a node's
   wrapper through a hash table (open addressing, a backward shift on every delete: 10 000 deletes a collection); a
   node handle is its pool slot's index and generation, so the wrapper now sits at the index, the full handle in the
   entry telling a node from the one that had the slot before. A handle whose entry is taken (a node of another
   document, a slot reused while the old wrapper waits for a collection) goes to the hash table, empty otherwise. The
   collection 4.30 (4.23-5.45) -> 3.55 (3.53-3.74) ms; `build()` the same.
5. **Measured, not kept.** A flag per interface saying whether it or one it inherits from has [LegacyUnforgeable]
   members, so that a new wrapper does not walk its five interfaces to find none (`wj_define_unforgeables`, 1.4 % of the
   engine's samples): `build()` 10.81 (10.60-11.29) against 10.68 (10.63-12.29) ms, 10 runs each. The `document`
   getter crosses to the browser on every read (`Window_document`, 10 000 times a frame, 2 % of the engine's samples):
   keeping the realm's document in the glue would assume the page's document never changes under a realm, which
   `adopt_document` does not promise; not done.

The browser, all of it (6 runs of each build for nodes10k, 5 for the others, interleaved; median, range in brackets):

| | before | after |
|---|---|---|
| nodes10k: frames/s | 119.0 (114.6-123.2) | 142.3 (133.9-143.0) |
| nodes10k: CPU work per frame, mean | 24.0 (23.2-24.9) ms | 20.0 (19.9-21.3) ms |
| nodes10k: script (Animation, with the collection), p50 | 18.9 (17.0-19.1) ms | 14.3 (13.6-14.9) ms |
| nodes10k: style stage, the window thread waiting on layout, p50 | 1.64, 3.31 ms | 1.58, 3.24 ms |
| nodes10k: the collection the DOM asks for (jspage) | 5.40 (5.26-5.57) ms | 3.77 (3.59-4.29) ms |
| nodes10k: `build()` (jspage) | 12.57 (12.46-12.62) ms | 10.73 (10.64-11.06) ms |
| `mutation`: frames/s, CPU work per frame mean | 76.4, 0.72 ms | 75.3, 0.71 ms |
| `mutation_class`: CPU work per frame mean | 1.46 ms | 1.41 ms |
| `mutation_fullstyle`: CPU work per frame mean, style stage p50 | 3.38, 0.94 ms | 3.25, 0.90 ms |
| p10k_load: load | 262 (250-265) ms | 252 (250-262) ms |
| p10k_scroll: frames/s, CPU work per frame p50 | 170.6, 0.292 ms | 171.9, 0.304 ms |
| `examples/site/modern-css.html` resized: CPU work per frame mean, a full pass | 0.64 (0.41-0.70), 1.44 ms | 0.67 (0.41-0.73), 1.47 ms |
| private memory: nodes10k, `mutation_fullstyle` | 260, 237 MB | 256, 237 MB |

The machine ran other programs (single runs of p10k_scroll and modern-css moved by a factor of 2 in both builds). What
the browser's samples of nodes10k's script stage are now (under `page::run_animation_frames`, 8 219 samples): the
engine itself 84 % (the interpreter, the wrappers it makes: the object, its host block, the glue's `Obj`), `Node_preInsert`
6.4 % (`insert_before`, the journal, the insertion steps' walk), `Node_unpinAll` 3.8 % (the trees it frees,
`destroy_subtree` 2.6 %), `createElement` 2.9 %, `Node_wrap` and `createTextNode` 2 % each; the collection is 13 % of
the engine's samples (was 20 %).

## What changed, round 8: layout of DOM-heavy pages, what a full style pass costs per page

Items 2 and 3 of round 7's list. Profiled first on the page thread and the style threads (`WREN_SAMPLE_THREADS=1
WREN_SAMPLE_STACK=1`, in a build that listed more of each thread's functions, not kept), and on the window thread under
`style::compute_styles` (`WREN_SAMPLE_UNDER`); then the base and the new profile build in turn (`wrentool bench perf`, 5
runs each, the order turning; median, range in brackets). The steps of a full layout pass (tree, layout, finish,
display, bands, p50 of each) tell the changes of layout apart.

What nodes10k's page thread did (1 052 samples while running, the base): the block layout 26 % (the 2 500 list items in
columns, `layout_multicol`: the items themselves, their paragraphs taken from the threads, the columns cut), the display
list 19 %, building the box tree 16 %, finishing 15 % (the overflow of each box and line of the flow, `flow_bounds_add`
6 %), the bands 5 %, the walks of writing modes around the block layout 4 %, copying the predictions of the layout
threads 2 %.

1. **The display list of a page with columns on the layout threads** (`build_display_list`, `push_flow_item`,
   `flows_clip_free`). A page with columns turned `frames_on` on and its display list was made on the page thread alone:
   an item of a flow becomes one copy for each column it shows in, and `push_flow_item` appended them to the layout's
   list whatever share was making them. They now go to the share's own list, as the other items do; a clip inside a flow
   is made again for each column (`flow_clip` adds clips), so a flow that holds one keeps the display list on one thread.
   `Layout.dl_shares` says how many shares the threads made. nodes10k: the display step 0.63 (0.62-0.70) -> 0.39
   (0.38-0.40) ms. Test: `parallel_multicol` (the columns, a box across three columns: its item in each, against one
   thread; a clip in the columns: one thread).
2. **No turn to physical coordinates when no frame is vertical** (`pre_run`): after the block layout every box was
   visited to make it physical (`frames_to_physical`: a walk in tree order, the frame of each box), which with columns
   alone changes nothing. **The predictions of the layout threads written in place** (`pre_predict`): made in temporary
   arrays and copied whole into `Pre_Keep` (a megabyte on nodes10k), they are written there by the threads. **The flows
   marked in box order** (`flows_mark`): a full pass makes a parent before its children; the walk in tree order went.
   The layout step 1.24 (1.20-1.29) -> 1.03 (1.00-1.04) ms; the finishing step 0.35 -> 0.41 ms (the walk that went had
   brought the boxes into the cache for it): both together 1.59 -> 1.44 ms.
3. **The page's color scheme looked for among the document's `<meta>` elements** (`Document.metas`, `page_color_scheme`).
   Every full style pass walked the whole document for `<meta name="color-scheme">` on the window thread: a quarter of
   the window thread's style samples on `mutation_fullstyle`. The document lists the `<meta>` elements it makes (created,
   cloned; a freed one is dropped by the reader); those in its tree are the candidates, in tree order. Test:
   `page_color_scheme_metas_in_tree_order` (made in another order than the tree's, one never inserted, one inside another
   `<meta>`). **`:disabled` answers at once for what is not a form control** (`matches_simple`): the UA's `:disabled`
   reaches every element and asked the forms model (a call through the page, a switch on the name) before finding it
   is none. nodes10k: the style stage 1.85 (1.82-1.98) -> 1.73 (1.73-1.74) ms; `mutation_fullstyle` 1.28 (1.28-1.32) ->
   1.21 (1.20-1.23) ms.
4. **The journal of a full pass compares a pair of records once per chunk** (`Diff_Pair`, `diff_chunk`). The layout
   journal compares every element's old and new record (`layout_level`, 28 to 36 % of the busiest style threads on
   `mutation_fullstyle`, and on the window thread, which takes chunks too). Alike elements share their record in both
   passes (round 4), so a chunk keeps the answer of each pair it compared, by slot (`JOURNAL_DIFF_PAIRS`): an element
   whose two records are a pair already compared takes the answer. Not a cache: the pairs are of these two passes, live
   while the chunk is compared, and nothing in them is invalidated. `mutation_fullstyle` (12 runs of each build,
   interleaved, a busy machine; 10 of the 12 pairs went the same way): the style stage 1.65 (1.21-2.91) -> 1.10
   (0.80-1.57) ms p50, a full pass 2.24 -> 1.51 ms.
5. **Measured, not kept.** The bands reading each item once instead of twice (its space and vertical extent in a small
   array): 0.126 against 0.132 ms. The finishing step looking up a box's columns once for all its lines
   (`flow_bounds_add` finds the container's record in a map for each rect): 0.402 against 0.406 ms.

| | before | after |
|---|---|---|
| nodes10k: the window thread waiting on layout, p50 | 3.62 (3.53-3.95) ms | 3.16 (3.14-3.19) ms |
| nodes10k: a full pass, tree + layout + finish + display + bands (p50 of each) | 0.93 + 1.24 + 0.35 + 0.63 + 0.13 ms | 0.92 + 1.03 + 0.41 + 0.39 + 0.13 ms |
| nodes10k: style stage p50, CPU work per frame (mean) | 1.85, 22.7 (21.3-26.8) ms | 1.73, 20.7 (20.6-21.4) ms |
| `mutation_fullstyle`: style stage p50 (without 4, then 4) | 1.28 (1.28-1.32) ms; 1.65 (1.21-2.91) ms | 1.21 (1.20-1.23) ms; 1.10 (0.80-1.57) ms |
| `mutation`: CPU work per frame mean, a partial restyle | 0.85 (0.82-0.93), 0.017 ms | 0.85 (0.81-1.11), 0.016 ms |
| `mutation_class`: CPU work per frame mean, a partial restyle | 1.66 (1.45-1.86), 0.219 ms | 1.67 (1.40-1.93), 0.213 ms |
| p10k_load: load | 257 (241-278) ms | 252 (243-268) ms |
| p10k_scroll: frames/s, CPU work per frame mean | 156.4, 0.51 ms | 157.0, 0.50 ms |
| `examples/site/modern-css.html` resized: CPU work per frame mean, a full pass | 0.44 (0.41-0.50), 1.09 ms | 0.46 (0.41-0.52), 1.12 ms |

The other pages were measured while other agents' builds ran (single runs moved by a factor of 2): the same within that
noise. WPT reference tests of css/css-multicol (464) and css/css-writing-modes (1 141), base and new against the same
checkout: the same results (303 and 620 pass, no regression).

What is left on the window thread's style stage of `mutation_fullstyle`: `flat_sizes`, the walk of the whole document
that weighs the subtrees before the style threads share them (`compute_styles` and the flat-tree steps under it, about
a third of its samples).

## What changed, round 9: what a full style pass costs on the window thread, the finishing of a flow

Items 2 and 3 of round 8's list. Profiled first (`WREN_SAMPLE_THREADS=1 WREN_SAMPLE_STACK=1`, in a build that also listed
each thread's own functions, not kept). Then, besides the browser, each change was timed in process, where a step of a
pass is measured to a few microseconds: a test not kept that lays out a copy of nodes10k (2 500 items in six columns,
the default settings and layout threads) 600 times, and one that styles a copy of `mutation.html` (10 000 elements) 600
times with seven style threads, each pass recycled as the page recycles it; the base and the new build in turn, 4 runs
each, the median of each run. Then the browser (`wrentool bench perf`, 5 runs of each build, interleaved, the order
turning; median, range in brackets).

1. **The weights of the subtrees in one walk** (`flat_sizes`, `src/style/parallel.odin`). Before the style threads
   share the work, the window thread weighs every subtree: a walk that pushed each element, listed it in tree order,
   wrote its parent's index, reached each node three or four times (`dom.get`, the flat tree's first child and next
   sibling, the kind of each child) and then went over the list backwards. It is now one walk in tree order with a stack
   of the open elements: an element's size goes to its parent's when the walk leaves it, and a document without shadow
   trees follows the nodes' own links. 0.153 (0.153-0.154) -> 0.068 (0.067-0.068) ms on 10 000 elements. Test:
   `flat_sizes_of_the_flat_tree` (a shadow tree, named and default slots, their fallbacks: each element against a count by
   recursion over the flat tree).
2. **The slots of a recycled pass** (`styled_recycle`, `styled_make`, `Engine.spare_by_node`). A full pass made its
   arrays of records by node (`by_node`, `nodes`: 16 bytes a node, 270 KB on `mutation.html`) on the heap and the pass it
   replaced freed its own: the new ones were pages to fault in, 0.056 ms of each pass on the window thread, before any
   element was styled. The engine keeps the arrays of the pass it recycles (as it keeps its arena, within
   `style.recycle_bytes`) and the next pass takes them, emptied; `styled_size` zeroes what it hands out, so no slot of an
   old pass is read. Test: `recycled_pass_slots` (the same arrays, no record of an element that left the document, every
   style equal to that of an engine that recycled nothing). With 1, the pass in process: 0.62 (0.62-0.66) -> 0.48
   (0.48-0.48) ms.
3. **A multi-column container's record by index** (`Box.mc`, `Layout.mc_records`, `mc_record`). Finishing looked the
   container's record up in a map for each box and line of its flow (`flow_bounds_add`), the window thread's queries
   likewise; the box now holds its record's index in a flat array. In process the finishing step did not move: 0.375
   against 0.374 ms. Kept for the rule (an index where a table was looked up per rect): what `flow_bounds_add` costs is
   not the lookup.
4. **Measured, not kept.** What finishing pays for the flow: without `flow_bounds` at all (a wrong result, to measure)
   the step is 0.15 ms shorter, about 15 ns a call for 10 000 calls; neither a binary search of the first column a rect
   reaches, with a stop at the first below it, nor the record by index (3) shortened it: the cost is the call's branches
   on each rect, not the search. The search and the walks of finishing in one (coordinates, clip owners, what is inside a
   fixed box), measured together: 0.383 against 0.382 ms. `apply_shifts` settling a paragraph only when one of its lines moved
   (`ifc_settle`, which it called for each of the 2 500 items): the layout step moved within its noise (0.76 to 0.89 ms
   in both builds, as the threads' paragraphs came in).

What the page thread of nodes10k does is left as round 8 found it (the browser: tree 0.92, layout 1.04, finish 0.36,
display 0.39, bands 0.13 ms): each step walks boxes of 400 bytes (`Box`), and what it reads of each is a few fields
scattered across them; the next gains there are item 4 below (what a step reads, in arrays of its own), not the steps'
own code.

| | before | after |
|---|---|---|
| `mutation_fullstyle`: style stage p50, a full pass | 0.90 (0.80-1.04), 1.11 (0.98-1.33) ms | 0.74 (0.72-0.78), 0.95 (0.89-0.99) ms |
| `mutation_fullstyle`: CPU work per frame, mean | 3.77 (3.19-4.81) ms | 3.25 (3.04-3.59) ms |
| nodes10k: style stage p50 | 1.74 (1.72-1.81) ms | 1.68 (1.66-1.75) ms |
| nodes10k: the window thread waiting on layout, p50 | 3.14 (3.11-3.27) ms | 3.16 (3.10-3.28) ms |
| nodes10k: a full pass, tree + layout + finish + display + bands (p50 of each) | 0.92 + 1.06 + 0.36 + 0.39 + 0.13 ms | 0.93 + 1.04 + 0.36 + 0.40 + 0.13 ms |
| nodes10k: CPU work per frame, mean | 21.1 (20.5-23.5) ms | 22.2 (20.8-25.5) ms |
| `mutation`: CPU work per frame, mean | 0.87 (0.86-0.92) ms | 0.88 (0.85-0.92) ms |
| `mutation_class`: CPU work per frame, mean | 1.45 (1.42-1.56) ms | 1.40 (1.38-1.45) ms |
| p10k_load: navigation to the first paint of the page | 152 (150-165) ms | 157 (150-159) ms |
| p10k_scroll: frames/s, CPU work per frame mean | 159.2, 0.401 ms | 158.6, 0.404 ms |
| `examples/site/modern-css.html` resized: a full pass, CPU work per frame mean | 1.00 (1.00-1.05), 0.414 ms | 0.98 (0.97-1.00), 0.410 ms |

WPT reference tests of css/css-multicol (464) and css/css-writing-modes (1 141), base and new against the same checkout:
the same result for every test (303 and 619 pass; `wm-propagation-svg-root-scrollbar.svg` fails in both builds on this
checkout, against its expectation).

## What changed, round 10: what the steps of layout read, measured

Item 2 of round 9's list: the idea was that layout's steps wait on memory, walking `Box` records (352 bytes) for a few
fields each, and would go faster with what each step reads in arrays of its own. Measured before anything was split, in
process (a test not kept: a copy of nodes10k, 2 500 items in six columns, 7 505 boxes and 12 506 display items, laid out
600 times with the default layout threads, the p50 of each step; 3 runs of each build, interleaved), then in the browser
(`wrentool bench perf`, the profile build, `WREN_SAMPLE_THREADS=1 WREN_SAMPLE_STACK=1` with a listing of each thread's
own functions that was not kept).

1. **Measured, not kept: the layout of `Box` and `Display_Item`.** What a split into arrays can save is bounded by two
   builds that change only where the bytes lie: `Box` twice as large (352 bytes of padding at its end), and `Box` with its
   fields reordered so that what the walks of finishing, the display list and the scans read shares its first two cache
   lines (the tree links, flags and kind, the spaces and clips, positions and sizes, the line and item ranges). The full pass: 2.57 ms with
   the boxes as they are, 2.66 with them twice as large (tree +0.06, display +0.02, finish and the block layout within
   their noise), 2.56 reordered (every step within 0.01 ms). The scan of every box's rects (below) took 12 % longer with
   the boxes twice as large. Display items twice as large (256 bytes): the display step +0.06 ms (it writes them), the
   bands +0.008 ms (they read the rect and the space of each). With the caches emptied between passes (64 MB written
   before each, as a script stage would leave them) every step doubles and the builds above stay within each other's
   noise. The 2.6 MB of boxes fit the processor's last cache (32 MB on the machine measured): the steps are bound by
   their own code, not by memory, so no field moved; the profile below says where that code is.
2. **The scans of every box read the union of a flow's fragments directly** (`box_border`, `src/layout/query.odin`;
   `timeline_present`, `timeline_layout_shift_check`, `src/page/timeline_lcp.odin`). After each frame that changed the
   document, the largest-paint scan and the layout-shift scan read the border rect of every box. For a box in a
   multi-column flow `box_border` answered "fragmented" and the scans called `box_of_view` (the padding and content
   rects, the walk up the spaces, the transform checks, and for the largest paint `geometry_of_rects` and the candidate's
   checks before the area that rules it out). It now gives the union of the fragments, `flow_bounds` of the border rect,
   which is what `box_of_view` gave, and the largest paint's area check rules a small box out before its candidacy is
   looked at. The layout-shift scan's reads in process: 0.233 (0.227-0.246) -> 0.133 (0.133-0.135) ms. Test: `multicol_box_border` (a box
   across two columns, one in one column, the container: `box_border` against `box_of`).

The browser (6 runs of each build for nodes10k, 4 for the others, interleaved, the order turning, on a quiet machine;
a first series while other agents built moved single runs by a factor of 2 and was dropped). The scans run in
`page_prepare` after the layout phase ends, under no phase of their own: the phase table leaves them out (they were
counted to `UI_Draw` by the sampler), the CPU work per frame has them.

| | before | after |
|---|---|---|
| nodes10k: CPU work per frame, mean | 20.29 (20.02-20.51) ms | 19.89 (19.81-20.74) ms |
| nodes10k: the scans' samples on the window thread (`box_of_view`, `flow_bounds_add`, `box_border`, `lcp_candidate_of`, the two scans) a frame | 0.40 ms (369 in 919 frames) | 0.19 ms (192 in 999 frames) |
| nodes10k: the window thread waiting on layout, p50 | 3.10 (3.10-3.12) ms | 3.08 (3.07-3.15) ms |
| nodes10k: a full pass, tree + layout + finish + display + bands (p50 of each) | 0.92 + 1.03 + 0.35 + 0.40 + 0.13 ms | 0.92 + 1.02 + 0.35 + 0.40 + 0.13 ms |
| `mutation`: CPU work per frame, mean | 0.80 (0.79-0.87) ms | 0.79 (0.78-0.82) ms |
| p10k_scroll: CPU work per frame, mean | 0.382 (0.379-0.405) ms | 0.380 (0.378-0.388) ms |
| p10k_load: navigation to the first paint of the page | 152 (150-153) ms | 153 (151-155) ms |

Layout itself is unchanged: the in-process copy of nodes10k gives the same boxes, lines, display items and bands in
every build above (a hash of them), and no layout code changed, so no reference test was run again.

What nodes10k's page thread does (the browser, 621 samples while running): the block layout of the columns 41 %
inclusive (`layout_contents` 9.5 % of its own, `layout_ifc` 6.3, `flow_children` 4.7, `gather_child` and `gather_box`
5.8), finishing 21 % (`flow_bounds_add` 8.5 % of its own: a box or line of a flow cut against each of the six columns,
`finish` 6.9, `compute_overflow` 4.3), the display list 9 %, building the box tree 9 % on this thread (its summaries of
the styles on the layout threads), the bands 6 %, `note_refresh_inputs` 3.4 %. On the window thread, after 2: `flow_bounds_add`
and `box_border` for the two scans, and `images_sync` (the inserted subtrees walked for images every frame, a quarter of
`UI_Draw`'s samples).

## What changed, round 11: the image search, the cut of a flow, the display items

Item 2 of round 10's list, in its order. Measured three ways: the sampler on the browser (`WREN_SAMPLE=1
WREN_SAMPLE_STACK=1 WREN_SAMPLE_THREADS=1`, `WREN_SAMPLE_UNDER=<function>`, 2 runs of each build: a share of the samples
moves little with the machine's load); in process (a test not kept that lays out a copy of nodes10k 600 times with the
default layout threads and reads every box's `box_border` after each pass, as the scans do; the p50 of each step, 3 to 4
runs of each build in turn, and a hash of the boxes, lines, display items and bands); then the browser, all of it
(`wrentool bench perf`, 5 runs of each build, interleaved, the order turning). Other agents built and ran tests on the
machine all along: single runs of the browser moved by a factor of 2 (a run of nodes10k at 20 or at 46 ms of CPU work a
frame), so the browser's table below says only that nothing got worse; the samples and the in-process steps carry the
measurements.

1. **The image elements found among those the document made** (`Document.images`, `named_add`, `src/dom/dom.odin`;
   `images_sync`, `src/page/images.odin`). After each change of the document the window thread walked every subtree the
   journal said was inserted, looking for `<img>` and `<input>`: on nodes10k, 7 500 elements a frame for none. The
   document now lists the `<img>` and `<input>` elements it makes (created, cloned; a freed one dropped by the reader or
   when the list would grow), as it lists its `<meta>` ones (round 8), and the search reads that list, keeping those in
   its tree (shadow trees included) that are image elements; it runs only when the journal has an insertion, a removal
   or an attribute of an `<img>` or `<input>` (anything when the journal does not cover the change), not for a text that
   changed. nodes10k: `images_sync` 68 to 72 samples in about 1 000 frames (0.07 ms a frame, a quarter of `UI_Draw`'s
   samples) -> 1 to 2. Tests: `document_lists_its_image_elements` (dom), `images_found_among_the_documents_images` (page:
   one inserted, one never inserted, a subtree removed, a type changed to image, an image in a shadow tree, a text
   changed).
2. **A box or line of a flow tried first against the column of the one before** (`flow_bounds_add`, `flow_inside`,
   `Mc_Record.apart`, `src/layout/multicol.odin`; `compute_overflow`, `box_border`, the two scans). Finishing and the scans
   cut every box and line of a flow against each of the six columns. The columns of a container are bands across the
   flow, one after the other (`apart`, checked when they are made); a rect inside one band, short of its end edges, is
   reached by no other column and shown whole by that one. A caller walking boxes in order keeps the column the last
   one lay inside (`near`) and tries it first: one test instead of six where it holds, the full cut otherwise, which
   finds the column for the next. Not a cache: the index is checked against the record's range and the rect each time,
   and nothing is kept across passes. In process: finishing 0.318 (0.317-0.320) -> 0.267 (0.264-0.268) ms, the reads of
   every box's border 0.129 (0.129-0.134) -> 0.070 (0.070-0.071) ms; on the page thread, `flow_bounds_add` 8.8 to 9.1 % ->
   6.5 to 6.6 % of the samples while running. `unite` inlined: without it the fast path's call cost 0.01 ms of the
   finishing and of the reads. Test: `multicol_flow_bounds_near` (every box and line of containers with a box across
   columns, a spanner, columns inside columns and a vertical writing mode, against the full cut).
3. **A display item of 104 bytes instead of 128** (`Display_Item`, `src/layout/types.odin`): `thumb` was set by nothing
   (a scrollbar's thumb is computed when it is drawn, `scrollbar_thumb`), and the decorations and the font index fill the
   padding. In process, the display step 0.28 -> 0.27 ms (each of 4 runs lower, by 0.005 to 0.024 ms): kept with the
   field that went.
4. **Measured, not kept: the block layout of the columns.** Timed by part in process (timers not kept, each adding
   about 30 ns): of the layout step (0.72 to 0.85 ms with the layout threads' paragraphs coming in), laying out the 2 500
   items 0.33 to 0.43 ms (about 150 ns an item, spread over `layout_contents`, the paragraph taken from the threads,
   `block_width`, the marker; none above 0.05 ms), gathering the units 0.06, balancing 0.06, moving the boxes to their
   columns (`apply_shifts`) 0.11; the rest is the threads' paragraphs. No part stands out to take. `flow_children`
   without its prefetch of the children's styles (one shared record on this page): the step within its noise (0.72 to
   0.85 ms both ways, 4 runs each).
5. Not done: item 1 of round 10's list (one crossing to create a node, pin it and name its interface): it changes the
   bindings' generator and the engine's glue, and the round's time went to the items above.

| | before | after |
|---|---|---|
| nodes10k: `images_sync` on the window thread (samples in ~1 000 frames) | 68-72 | 1-2 |
| nodes10k: `UI_Draw`'s samples (both runs) | 278-289 | 189-210 |
| nodes10k, in process: finish, display, the reads of every box's border (p50) | 0.318, 0.276, 0.129 ms | 0.267, 0.268, 0.070 ms |
| nodes10k: a full pass, finish + display (p50 of each, browser) | 0.352 + 0.401 ms | 0.320 + 0.371 ms |
| nodes10k: the window thread waiting on layout, p50 | 3.14 (3.12-3.61) ms | 3.09 (3.06-4.44) ms |
| nodes10k: CPU work per frame, mean | 20.6 (20.2-25.8) ms | 20.7 (20.3-35.3) ms |
| `mutation`: CPU work per frame, mean | 0.91 (0.82-1.25) ms | 0.87 (0.80-1.54) ms |
| `mutation_class`: CPU work per frame, mean | 1.77 (1.35-2.02) ms | 1.51 (1.37-6.72) ms |
| `mutation_fullstyle`: CPU work per frame, mean | 3.16 (2.90-12.3) ms | 3.28 (2.88-13.7) ms |
| p10k_load: navigation to the first paint of the page | 171 (164-438) ms | 172 (155-599) ms |
| p10k_scroll: CPU work per frame, mean | 0.42 (0.39-1.44) ms | 0.49 (0.38-0.96) ms |
| `examples/site/modern-css.html` resized: CPU work per frame, mean | 0.43 (0.42-1.17) ms | 0.57 (0.41-1.10) ms |

Layout's output is the same: the in-process copy of nodes10k gives the same hash in every build above, the layout unit
tests pass, and the WPT reference tests of css/css-multicol (464) and css/css-writing-modes (1 141), base and new against
the same checkout, give the same result for every test (303 and 619 pass; `wm-propagation-svg-root-scrollbar.svg` fails
in both, as in round 9).

What nodes10k's page thread does now (the browser, 686 samples while running): the block layout of the columns 34 %
inclusive (`layout_contents` 7 % of its own, `layout_ifc` 3.8, `gather_box` and `gather_child` 4.4, `apply_shifts` 4.4),
building the box tree 19 % (`place_element` 4.2 % of its own), finishing 14 % (`finish` 6.3 % of its own,
`flow_bounds_add` 3.6), the display list 9 %, `note_refresh_inputs` 4.5 %, the bands 4.4 %, waiting for the threads'
paragraphs 3.8 %.

## What changed, round 12: the script stage of DOM-heavy pages, the crossings and the interpreter's exits

Item 1 of round 11's list. Profiled first, as rounds 6 and 7 did: the engine's samples (`jspage -image <engine built with
buildjs -names> -profile`, the guest profiler: a sample at each 5 ms epoch tick, taken where Wasm code checks the
epoch, so the time of a call into the browser is counted to the first function the engine enters after it returns:
`Node_preInsert` to `JS_DupValue`, the factories to the wrapping that follows them, `Node_unpinAll` to `gc_collect`),
the browser's side under `page::run_animation_frames` and under `_t_dom_Node_preInsert` (`WREN_SAMPLE_UNDER`). Each
change was timed in `jspage` on a copy of nodes10k (`build()` a frame, p50 of 250 frames; the collection with a timer
around `js.collect` in a build of jspage that was not kept), every engine image of the round in turn in one jspage, 6
rounds; other agents built and ran tests all along, so single runs moved by up to a factor of 2 and the ratios within a
round (each build against the first) were read with the medians. Then the browser, all of it (5 runs of each build,
interleaved, the order turning).

What the engine's samples of nodes10k were (9 105 samples, the base): the interpreter 22 % of its own (`interp_hot`
15 %, `interp_run` 7 %: the full dispatch for what the hot loop gave up on), the browser's insertions 10.5 % (counted to
`JS_DupValue`), the browser's `createElement` and `createTextNode` 8.7 % (counted to `wj_wrap_node`) and `Node_wrap`
4.5 % (counted to `make_wrapper`), the collection 9 %, the C API's bridge and its value conversions (`enc`, `dec`) 8 %,
Odin's `append` of the engine's root lists 4 %, the two crossings for the realm's document (the `document` getter and
`is_page_document`) 6.4 %.

1. **A new node and its wrapper in one call** (`Document_createElementWrapped`, `Document_createTextWrapped` in
   `api/js.widl`, `src/page/js_host.odin`; `wj_wrap_new`, `native/js/odin/wj/qjs_platform.odin`). `document.createElement`
   crossed to the browser four times (the `document` getter, `is_page_document`'s `Window_document`, the factory,
   `Node_wrap` for the pin and the interface), `createTextNode` as many. The realm's own document now makes its node and
   pins it and names its interface in one call, whose answer (`WrappedNode`: the node, its interface) is what the
   wrapper needs; a custom element whose constructor made its wrapper before the call returned keeps that wrapper's pin
   (the engine drops the extra one). Documents of their own and other pages' documents take the old path. **The
   realm's document asked once** (`wj_document`): its handle never changes under a realm. Every document of a page is
   made with the page's tag and its document node is the first slot of a fresh pool (`dom.document_create`), so a
   document the page adopts (a frame's parsed document after its about:blank, an XML one) has the handle of the one it
   replaced; the glue already kept the tag it derives from it. `window.document` is the glue's
   (`wjr_Window_get_document`), and `is_page_document` compares handles. One crossing for each new node where there
   were four. `build()` 11.11 (10.93-11.40) -> 10.55 (10.43-15.76) ms. Tests: `adopted_document_keeps_its_handle` (page:
   HTML, XHTML, parsed off the thread), `js_new_nodes_wrapped_in_one_call` (web tests: interfaces, one pin for each
   wrapper, a custom element constructed during createElement, the browser's errors, the same document object).
2. **The engine's root lists appended in place** (`list_push`, `src/engine/jsrt/gc.odin`): every cell made goes on
   `temp_roots`, every host object of a class with references on `gc_hooked`, every marked cell on `gray`; Odin's
   `append` is a call that checks the allocator each time, now taken only when the list is full. `build()` 10.55 ->
   10.25 (10.18-10.73) ms.
3. **The hot loop calls native getters and pushes string constants** (`hot_get_prop`, `hot_native_getter`, `get_var`,
   `push_atom_value` in `src/engine/jsrt/interp_hot.odin`; `global_index`, `globals.odin`). A DOM attribute
   (`list.lastChild`), an accessor of the global object (`document`) and a string constant (`"item "`) left the hot loop
   for the full dispatch and came back to it; the getter, a native called as a function, is now called where the lookup
   found it, as a call instruction calls a native (`call_native`, the same checks of depth and stack). `build()` 10.25
   -> 9.11 (8.81-10.35) ms.
4. **The C API's bridge converts its values in place** (`#force_inline enc` and `dec` in `bridge_invoke`,
   `src/engine/jscapi/runtime.odin`): every DOM call converted its `this`, its arguments and its result through two
   calls each. `build()` 9.11 -> 8.73 (8.65-13.32) ms.
5. **The class and the opaque data of a platform object in one call** (`JS_GetAnyOpaque`, QuickJS-ng's, in
   `src/engine/jscapi`): `obj_of`, which every DOM call makes for its `this` and node arguments, and the collection's
   `obj_mark` and `obj_finalizer`, asked `JS_GetClassID` then `JS_GetOpaque`; `obj_mark` reports a group only when the
   wrapper is in one. With the gray list of 2: the collection 4.07 (3.89-6.54) -> 3.69 (3.53-4.15) ms (median of the
   ratios 0.90), `build()` 8.73 -> 8.60 (8.53-8.85) ms. Test: `judge capi` (a payload and its class, a built-in
   object's class and no data, no object).
6. **Measured, not kept.** The finalizer of a wrapper skipping the calls for what it does not have (listeners, a group,
   [SameObject] values): the collection 4.23 (3.89-5.82) against 4.36 (3.89-5.23) ms with it, 8 rounds. The walks of
   every cell before the sweep (the finalizers', the shapes' transitions) in one: the collection the same (4.03 against
   4.03 ms, ratio 1.03), the heap fits the processor's cache. `node_next` inlined in the prologue: the collection the
   same (3.99 against 3.99 ms). The shrink of `temp_roots` at each native call's return written in place (`temp_reset`,
   `_resize_dynamic_array` 2 % of the engine's samples after 1 to 5): `build()` 8.92 against 8.97 ms, 8 rounds.

The browser, all of it (5 runs of each build, interleaved, the order turning; median, range in brackets; the machine
ran other agents' builds and tests, so CPU work per frame moved by up to a third within a build):

| | before | after |
|---|---|---|
| nodes10k: script (Animation, with the collection), p50 | 15.03 (14.70-15.74) ms | 12.21 (11.92-12.65) ms |
| nodes10k: frames/s | 137.2 (107.5-144.5) | 159.3 (130.1-166.5) |
| nodes10k: CPU work per frame, mean | 20.7 (19.7-26.4) ms | 17.8 (17.0-21.9) ms |
| nodes10k: style stage p50, private memory | 1.61 ms, 263 MB | 1.60 ms, 262 MB |
| nodes10k (jspage): `build()`, the collection the DOM asks for | 11.11 (10.93-11.40), 4.19 (3.94-7.73) ms | 8.60 (8.53-8.85), 3.69 (3.53-4.15) ms |
| `mutation`: CPU work per frame, mean | 0.77 (0.74-0.79) ms | 0.75 (0.72-0.82) ms |
| `mutation_class`: CPU work per frame, mean | 1.67 (1.51-2.34) ms | 1.63 (1.58-2.40) ms |
| `mutation_fullstyle`: CPU work per frame mean, style stage p50 | 3.39 (2.93-4.79), 0.75 ms | 3.80 (2.83-4.33), 0.76 ms |
| p10k_load: load | 243 (232-253) ms | 236 (233-244) ms |
| p10k_scroll: frames/s, CPU work per frame mean | 170.4, 0.42 ms | 171.1, 0.42 ms |
| `examples/site/modern-css.html` resized: CPU work per frame mean | 0.49 (0.42-0.88) ms | 0.47 (0.41-1.60) ms |

The other pages make few DOM calls a frame: the same within their noise. What the engine's samples of nodes10k are
now (5 962 samples, the time of the browser's calls counted as said above): the hot loop 17 % of its own (the full
dispatch 0.5 %, was 7 %), the browser's insertions 13 % (`JS_DupValue`), the browser's factories with their pin and
interface 11 % (`wj_wrap_new`), the collection 16 % (the browser's `Node_unpinAll`, 1.1 of its 4.1 ms by a timer, then
the finalizers, the sweep's frees, the mark of the hooked objects), making the wrappers 6 % (`wrap_pinned`,
`host_object_new`, `wj_define_unforgeables`), the bridge and its getters 5 %, `"item " + i` 4 % (`op_add`, the
concatenation and the number's string). The browser's side of the insertions (`_t_dom_Node_preInsert`, 7 % of the
window thread's script samples): the trampoline's checks 15 % of it, `journal_record` 14 % (the halving of a full journal
moves half of it, `memcpy` 5 %), `check_insert` 11 %, `insert_before` 9 %, the insertion steps' walk and hooks 20 %
(`inserted_kinds`, `hook_inserted`, `dialog_note_attribute`, the forms model).

## What changed, round 13: the script stage of DOM-heavy pages, the collection

Item 1 of round 12's list. Profiled first: the engine's samples (the guest profiler in `jspage`, its ticks at 1 ms with
`--pref wasm.wasmtime.epoch_tick_ms=1`: 19 306 samples in 3 000 frames, the bias of round 12), the browser's under each
import (`WREN_SAMPLE_UNDER=page::[api_generated.odin]::_t_dom_Node_preInsert` and the others). The browser's side of
nodes10k's script stage is small: a frame spends 0.50 ms in `Node_preInsert` (`journal_record` 23 %, its halving's
`memcpy` 6 %, the insertion hooks 29 %, `check_insert` 9 %), 0.31 ms in `Node_unpinAll` (`destroy_subtree` 69 %, `unpin`
29 %), 0.29 ms in `createElementWrapped`, 0.15 in `createTextWrapped`, 0.11 in `preRemove`: 1.4 of the 12 ms; the rest is
the engine. Single calls timed in `jspage` (a loop of a million, the best of 7): the loop alone 25.5 ns an iteration (the
interpreter, the loop JIT does not take a loop that reads a property), a property of the object itself 34 ns, a method of
`li` found on the fifth shape of its chain 54 ns (about 4 ns a shape), the glue's `document` getter 77 ns, `nodeType`
104 ns, `firstChild` 122 ns. Each change was timed in `jspage` on a copy of nodes10k (`build()` a frame, p50 of 400
frames; the collection by a timer around `js.collect` in a build of jspage that was not kept), the builds in turn, 6 to 7
rounds; the engine's changes also against `examples/jsbench/micro.js` and `macro.js` (`jsengine run`, the best of 2 to 4
runs of each case); then the browser (5 runs of each build, interleaved, the order turning).

1. **A wrapper's data asked for its values only once it holds some** (`host_object_set_marked`,
   `src/engine/jsrt/host_class.odin`; `JS_SetOpaqueMarked`, `src/engine/jscapi`; `wj_obj_marked`,
   `native/js/odin/wj/qjs_platform.odin`). Every wrapper was in `gc_hooked`, so each collection called its class's
   `gc_mark` (the bridge, then the glue's `obj_mark`) in the counting pass of the trial deletion, and again when marking
   the live ones: on nodes10k, 20 000 wrappers a collection that hold nothing. An object made with a payload
   (`JS_NewObjectProtoClassPayload`) is now unmarked: out of `gc_hooked`, never asked; the glue marks it before its data
   takes a value (a group, a listener, a [SameObject] value, an impl), and it stays so. One the glue forgot to mark keeps
   the values its data counts as roots (their counts are not subtracted): a leak, not an early free. The collection 3.49
   (3.42-3.81) -> 3.03 (2.99-3.88) ms; `build()` the same. A first version that made the wrapper marked and took it
   out after (`JS_SetOpaqueMarked(.., false)` in `wrap_pinned`) saved as much in the collection and cost it back in
   `build()` (8.54 -> 8.71 ms). Test: `judge capi` (`gc_mark` not called until marked, the counted values roots until
   then, a cycle through marked payloads collected).
2. **A detached tree freed by its own links** (`destroy_subtree`, `src/dom/dom.odin`): a node after its children, the
   walk going down by `first_child` and on by `next` or back to the parent; the template contents and shadow trees that
   go with it, rare, in a list of the temporary allocator. It made a heap list for each tree (2 500 a collection on
   nodes10k, `_reserve_dynamic_array` 13 % of `Node_unpinAll`), and looked a node up in the maps of namespaces and
   templates when they were empty. The collection 3.08 (2.99-3.17) -> 2.83 (2.79-4.58) ms. Round 6 measured an inline
   list for the same stack within the noise of its timer; the jspage timer of this round tells them apart. Test:
   `release_frees_deep_trees_templates_and_shadows` (a chain of 50 000, siblings, a template's contents and a shadow
   tree all freed; pinned contents kept, then freed with their last pin).
3. **Measured, not kept: the prototype walk without the host class's hooks** (`hot_get_prop`). A bit of `Object`
   (`exotic_get`, set when the object is made: a proxy, a module namespace, a String object, a typed array, a host object
   whose class has exotic hooks) in place of the four class tests and the call to `host_exotic_of` at each shape of the
   chain: `build()` 8.73 (8.66-9.17) -> 8.51 (8.46-12.68) ms, but every case of `micro.js` slower (the int loop, which
   reads no property, 34 -> 40 ns; the geometric mean +12 %) and `macro.js` +2.3 %: the code of `interp_run` around the
   hot loop changed (the bit declared and set but not read: no change). The same test kept out of line (a
   `#force_no_inline` procedure, or in `host_exotic_of`) slowed `micro.js` as much and gained nothing on nodes10k. A
   cache of lookups by shape is what the rules rule out; flattening the chain's shapes would need invalidation when a
   prototype changes.
4. **Not done, by the samples:** the journal's halving (`memcpy` 0.03 ms a frame: a ring would change the slice
   `journal_since` gives its four readers for that); texts on the heap one by one (`create_text`, freed in
   `free_node_data`: about 0.1 ms a frame between the two).

The browser, all of it (5 runs of each build, interleaved, the order turning; median, range in brackets; the base is
master at the round's start, 92d886d6):

| | before | after |
|---|---|---|
| nodes10k: script (Animation, with the collection), p50 | 12.15 (12.04-12.27) ms | 11.39 (11.31-11.60) ms |
| nodes10k: frames/s | 164.6 (160.4-167.8) | 169.0 (166.2-169.4) |
| nodes10k: CPU work per frame, mean | 17.42 (16.86-17.70) ms | 16.77 (16.74-17.03) ms |
| nodes10k: style stage p50 | 1.68 ms | 1.68 ms |
| nodes10k (jspage): `build()`, the collection the DOM asks for (7 rounds) | 8.67 (8.44-32.2), 3.57 (3.41-28.4) ms | 8.70 (8.60-18.5), 2.89 (2.76-6.52) ms |
| `mutation`: CPU work per frame, mean | 0.78 (0.73-0.85) ms | 0.81 (0.72-0.87) ms |
| `mutation_class`: CPU work per frame, mean | 1.43 (1.29-1.55) ms | 1.34 (1.24-1.46) ms |
| `mutation_fullstyle`: CPU work per frame mean, style stage p50 | 3.13 (2.88-3.34), 0.81 ms | 3.03 (2.96-3.22), 0.82 ms |
| p10k_load: load | 244 (233-256) ms | 246 (231-265) ms |
| p10k_scroll: frames/s, CPU work per frame mean | 171.5, 0.40 ms | 170.5, 0.41 ms |
| `examples/site/modern-css.html` resized: CPU work per frame mean | 0.45 (0.39-1.40) ms | 0.47 (0.41-1.18) ms |

Other agents built and ran tests meanwhile: the jspage rounds with a run at 2 to 4 times the others are theirs, and the
pages that make few DOM calls are the same within their noise. Measured against the commit the round started from
(517984c0) instead, `mutation_fullstyle`'s style stage was 0.715 (0.713-0.761) ms: master's own changes of the time
(`::backdrop`, `::placeholder`) make its full pass 14 % longer, before this round's.

What the engine's samples of the collection are now (2 494 samples under `gc_collect`): `gc_collect`'s own 31 % (the
roots, the sweep's loop, and the browser's `Node_unpinAll` counted to it), the prologue's walk of every wrapper 18 %
(`obj_of` and `JS_IsUntouched` for each, to find the plain ones), the finalizers' chain 18 % (the bridge, `obj_finalizer`,
`node_del`, `libc_free`), the sweep's frees 14 %, `gc_drain` 12 %.

## What changed, round 14: the static C runtime, measured; what ::backdrop cost every element

The machine quiet. The browser: `wrentool bench perf`, profile builds, 5 runs of each build, interleaved, the order
turning; median, range in brackets. A full style pass also timed in process (a test not kept: a copy of `mutation.html`,
10 000 elements, styled 600 times with seven style threads, each pass recycled as the page recycles it; 6 runs of each
build in turn).

1. **The static C runtime: measured, kept.** The move to Odin dev-2026-11 linked every Wren program with the static C
   runtime (libcmt, libucrt; Lexbor `/MT`, the Rust libraries `crt-static`), since `core:testing` now links Odin's
   `core:c/libc`, the static UCRT, into every test program, and the dynamic one beside it did not link. A noisy run had
   shown nodes10k at 132 frames/s against 159 with the dynamic runtime. The dynamic variant rebuilt on a scratch branch
   from that commit's diff (msvcrt and ucrt in the foreign imports, Lexbor `/MD`, no `crt-static`, the static vcruntime
   switch back: it imports `api-ms-win-crt-*`, the static one no runtime DLL), against master at 5fe0a76b:

   | | static | dynamic |
   |---|---|---|
   | nodes10k: frames/s | 163.2 (157.4-165.4) | 165.3 (137.3-167.0) |
   | nodes10k: script (Animation) p50, CPU work per frame mean | 11.66 (11.51-11.78), 17.37 (17.18-18.06) ms | 11.57 (11.55-13.68), 17.13 (16.97-20.70) ms |
   | nodes10k: style stage p50 | 1.708 (1.699-1.718) ms | 1.699 (1.688-1.869) ms |
   | `mutation_fullstyle`: style stage p50, CPU work per frame mean | 0.835 (0.831-0.841), 3.09 (3.02-3.54) ms | 0.850 (0.833-0.970), 3.87 (3.21-5.08) ms |
   | p10k_load: load | 247 (242-644) ms | 242 (233-259) ms |
   | p10k_scroll: frames/s, CPU work per frame mean | 170.7, 0.403 ms | 169.1, 0.474 ms |
   | `examples/site/modern-css.html` resized: CPU work per frame mean | 0.425 (0.393-1.071) ms | 0.412 (0.389-0.839) ms |
   | `wrentool bench startup`, first present, single instance off / on (6 runs) | 250 (248-265) / 248 (246-252) ms | 249 (246-252) / 250 (245-273) ms |

   The same within the noise, and the sampler says why: what the runtime does on a hot path is the same code in both.
   The C library's `malloc` (Lexbor's, the C the Rust crates compile) is `HeapAlloc` on the process heap in both UCRTs,
   as Odin's heap allocator and Rust's are (`RtlAllocateHeap` 0.8 and 0.7 % of nodes10k's samples); `memcpy` and `memset`
   are the static vcruntime's in both (Wren linked `libvcruntime` before the move too: 1.0 and 1.2 %, 0.9 and 0.7 %).
   The 132 frames/s was the machine, not the runtime. Nothing to route elsewhere; the browser stays static with its test
   programs.
2. **The ::backdrop entries tried for the elements of the top layer alone** (`Index.backdrop`, `src/style/engine.odin`
   `bucket_add`; `collect_entries`, `src/style/cascade.odin`; `match_element`, `src/style/sibling_match.odin`). Since
   `::backdrop` gets a style, the UA's `::backdrop`, `:fullscreen:not(:root)::backdrop` and `:popover-open::backdrop`
   were universal entries matched for every element (the last two `own`, so matched again for each sibling the walk
   shares matching with), and every element's ::backdrop list (the UA's first rule) went into its share key, to be
   dropped by `compute_element` for an element outside the top layer. They are now in a list of their own, whatever
   their subject (Tailwind's `*, ::before, ::after, ::backdrop` too), tried only for an element of the top layer; such an
   element neither takes a family's matching nor gives its own (its siblings would get or miss its backdrop). The share
   key and the lists of every other element are those of before `::backdrop`. A full pass in process 0.632
   (0.624-0.643) -> 0.569 (0.565-0.579) ms; the browser below. Test: `backdrop_styles` (three alike siblings, each in
   turn in the top layer: it alone has a backdrop). `::placeholder` needs nothing of the kind: the UA's rules are by tag
   (`input`, `textarea`).
3. **Not done: the script stage's leftovers** (round 13's item 1). What the sampler shows of the browser's side is as
   round 13 left it (`journal_record`, the insertion hooks, `destroy_subtree`, `unpin`, about 1.4 of 11.6 ms); texts in
   a document's own memory instead of the heap one by one (`create_text`, about 0.1 ms a frame) is a change of the DOM's
   memory for that.

The browser, all of it (the base is master at 5fe0a76b, static):

| | before | after |
|---|---|---|
| `mutation_fullstyle`: style stage p50 | 0.835 (0.833-1.235) ms | 0.753 (0.747-0.815) ms |
| `mutation_fullstyle`: CPU work per frame, mean | 3.10 (3.00-5.69) ms | 2.86 (2.81-4.77) ms |
| nodes10k: style stage p50 | 1.708 (1.677-1.762) ms | 1.652 (1.595-1.701) ms |
| nodes10k: script (Animation) p50, frames/s | 11.81 (11.42-12.06) ms, 142.1 (130.7-170.4) | 12.11 (11.57-12.61) ms, 143.3 (138.1-168.3) |
| `mutation`: CPU work per frame, mean | 0.79 (0.72-1.48) ms | 0.96 (0.75-1.52) ms |
| `mutation_class`: CPU work per frame, mean | 1.31 (1.23-2.35) ms | 1.32 (1.25-1.92) ms |
| p10k_load: load | 239 (235-250) ms | 244 (236-352) ms |
| p10k_scroll: frames/s, CPU work per frame mean | 172.5, 0.377 ms | 172.1, 0.362 ms |
| `examples/site/modern-css.html` resized: CPU work per frame mean | 0.388 (0.386-0.398) ms | 0.395 (0.384-0.907) ms |

nodes10k's frames moved by a third within each build in these runs (the first round's ranges are narrower), and the
pages that do not restyle whole are the same within their noise.

## What changed, round 15: the interpreter's hot loop calls nothing; real pages loaded from the navigation

Items 9 and 1 of round 14's list, and pages of the site measured from their navigation. The engine's changes were timed
with `jsengine run -image <engine>` on `examples/jsbench/micro.js` and `macro.js` (every engine image of the round in turn
in one jsengine, 4 rounds; another agent built and ran tests on the machine all along, so single runs moved by up to a
factor of 2: the best run of each case is the figure, the median of the runs said the same within a few per cent), and in
`jspage -image` on a timed copy of nodes10k (`build()` a frame over 400 frames, 5 rounds: its p50 was bimodal with the
machine's load, 8.6 or 14 to 20 ms in every build, so its p10 is the figure); then the browser (5 runs of each build,
interleaved).

1. **The hot loop calls nothing** (`interp_hot`, `src/engine/jsrt/interp_hot.odin`). What round 13 saw, looked at in the
   code LLVM makes for wasm32 (`odin build -build-mode:asm`): `interp_hot` was a procedure of its own with 36 locals and
   calls in its handlers (`call_native` three times, `frame_push`, `close_var_refs` and the dynamic array's resize of an
   inlined `frame_pop`, `atom_to_value`, `host_exotic_of`, and `shape_realize` from each of the seven inlined
   `shape_find`). Wasmtime compiles Wasm calls with a convention that saves no register across them, so `ip`, `s` and the
   frame's registers, live across those calls in some handlers, were split or kept in stack slots wherever the register
   allocator chose, and a change elsewhere in the procedure moved that choice (round 13's bit test). Now every handler
   that needs a call (call instructions, returns, getters, a lazy shape, an atom's number made a string) is a procedure
   of its own, never inlined (`hot_call`, `hot_return`, `hot_get_field`, `hot_get_var_getter`, `hot_push_atom`), that
   reads and writes the loop's registers in a `Hot` in memory: written before the call, read back after it, so no value
   of the loop lives across one. The loop's lookups read realized shapes only (`shape_lookup`, `shape_find` without its
   realization; a lazy shape goes to `hot_get_field` or to the full dispatch). The listing of the loop now has calls only
   to those procedures and to the bounds checks' traps, which do not return. A loop that calls nothing LLVM inlined into
   `interp_run` of its own accord (the full dispatch and the loop then share pc and sp without a call); it is now
   `#force_inline`, so that does not depend on its size. Built as a procedure of its own (`#force_no_inline`) the same
   loop was 8 % slower on `micro.js` than inlined (0.875 against 0.801 of the base, same runs).
2. **The prototype walk without the host class's hooks, again** (`Object.host_exotic`, `src/engine/jsrt/object.odin`, set by
   `host_object_new`: the class has exotic hooks or was not defined when the object was made). Round 13's change, which
   then slowed `micro.js` 12 %: on top of 1, the loop walks a node wrapper's chain to the DOM attribute's getter itself
   (without it, the loop handed every lookup that met a host object to `hot_get_field`, `build()` 8.51 -> 8.81 ms p10);
   with it, the int loop that reads no property is 0.74 of the base's time against 0.76 without the bit (best runs, two
   series of the same hour), not slower.

| | before | after |
|---|---|---|
| `micro.js`, geometric mean of the 20 cases (best run of each) | 1 | 0.857 |
| ... int loop, property get, `switch` on small ints | 39.1, 68.3, 84.4 ns | 30.5, 51.5, 63.9 ns |
| ... call of a small function, closure counter | 83.5, 73.2 ns | 79.0, 72.5 ns |
| `macro.js`, geometric mean of the 28 cases (best run of each) | 1 | 0.913 |
| ... destructuring, `Float64Array` fill + sum, string switch | 694, 195, 134 ns | 538, 141, 104 ns |
| ... closure creation + call, array map + filter + reduce (the two slower) | 492, 349 ns | 504, 364 ns |
| nodes10k (jspage): `build()` p10 | 8.51 (8.42-8.80) ms | 8.44 (8.31-8.75) ms (loop not inlined), 8.49 (8.28-8.66) ms (inlined) |
| nodes10k: script (Animation) p50 | 11.97 (11.79-12.33) ms | 11.81 (11.63-22.41) ms |
| nodes10k: CPU work per frame p50, style stage, the window thread waiting on layout | 17.94 (17.91-18.45), 1.66, 3.23 ms | 17.74 (17.53-36.53), 1.63, 3.17 ms |
| `mutation`: CPU work per frame, mean | 0.777 (0.723-0.810) ms | 0.772 (0.737-0.927) ms |
| `mutation_class`: CPU work per frame, mean | 1.52 (1.31-1.85) ms | 1.32 (1.25-6.76) ms |
| `mutation_fullstyle`: CPU work per frame mean, style stage p50 | 2.97 (2.87-3.44), 0.755 ms | 2.93 (2.82-4.70), 0.756 ms |
| p10k_load: navigation to the first paint of the page | 181.0 (177.8-200.0) ms | 183.1 (180.4-228.8) ms |
| p10k_scroll: CPU work per frame, mean | 0.380 (0.355-0.402) ms | 0.384 (0.370-0.499) ms |

The checksums of both benchmarks are the same in every build. One run of the new build's nodes10k ran at half rate (the
other agent's build): the upper ends of its ranges. nodes10k's script is the DOM's calls, the collection and the
wrappers more than the loop: the loop's 15 to 25 % shows as 1 % there. `examples/site/modern-css.html` resized was not
run this round (no DOM calls, nothing of the engine).

3. **Real pages, loaded from the navigation** (`wrentool bench perf`, the `Navigate` action: the page opened on about:blank,
   then navigated to, timed by its own Navigation and Paint Timing; scenarios `p10k_nav` and `nav_*`; the new build, 5
   runs each, median and range in ms from the navigation's start; CPU: the process's during the load until quiet,
   in ms). sacha.house was not measured: the bench's Wren keeps its connections on the machine
   (`network.loopback_only`).

   | page | response end | DOM interactive | first contentful paint | load | CPU |
   |---|---|---|---|---|---|
   | p10k (611 KB, 10 020 elements) | 4.3 (3.5-4.8) | 49.9 (34.1-54.5) | 114.6 (70.5-138.0) | 50.0 (34.1-54.7) | 797 |
   | `examples/site/text.html` | 2.9 (2.8-5.2) | 3.6 (3.3-5.8) | 43.1 (27.4-66.3) | 3.7 (3.3-5.9) | 656 |
   | `legacy-html.html` | 2.2 (2.2-2.7) | 2.6 (2.5-3.1) | 77.7 (77.3-82.2) | 92.0 (91.6-96.5) | 406 |
   | `shadow-dom.html` | 2.2 (1.9-2.5) | 65.1 (57.3-67.6) | 9.1 (8.6-11.3) | 65.1 (57.3-67.6) | 375 |
   | `js-dom.html` | 3.9 (3.1-6.2) | 53.9 (44.5-64.2) | 54.7 (45.3-65.6) | 54.0 (44.6-64.3) | 578 |
   | `modern-css.html`, `grid.html`, `layout.html`, `index.html` | 3.2 to 3.9 | 3.8 to 4.9 | 10.8 to 14.3 | 3.9 to 5.0 | 450 to 720 |
   | `style.html` (load 24 ms: its sheet), `forms.html`, `multicol.html`, `about.html` | 2.3 to 3.5 | 2.5 to 4.1 | 4.0 to 8.7 | 2.5 to 24.1 | 360 to 580 |

   What the sampler (`-Sample`, `WREN_SAMPLE_STACK=1`) shows of the window thread in those loads, by cost:
   - the first realm of the process (`js-dom.html`, `shadow-dom.html`: DOM interactive 54 and 65 ms for an inline
     script): the engine's compiled code read from the disk cache and its HMAC-SHA256 checked (`disk_load`,
     `sha256_transf_hw` 8 to 12 ms of samples, the file's reads 3 to 5), then its instantiation; once per process;
   - the first paint of text (`text.html`: 27 to 66 ms after a load at 4 ms): the system's font machinery made on the
     window thread (`DWriteCreateFactory`, the color glyph formats of `platform_color_glyph`, a thread started by
     `color_enqueue`) and the paint's fresh memory (`NtAllocateVirtualMemory` in `Paint_Items`);
   - `legacy-html.html`: its first paint and load wait on a PNG's decode (`effects-photo.png`);
   - p10k: the stages of section 1 (parse off the thread, then the first style and layout passes and the first paint:
     65 ms from DOM interactive to the first paint);
   - not the page's: the bench's own `stats` calls walk the machine's process list for the thread count
     (`process_threads`, `CreateToolhelp32Snapshot`, 20 to 45 ms of the window thread each on this machine), outside the
     timed navigation but inside the CPU column.
4. **The compile thread's engine instantiated with the image's digest** (`compile_main`, `src/page/js_load_compile.odin`):
   it hashed the 7 MB image again (3.5 ms with the processor's SHA instructions, `wasm.digest`, best of 10) where the
   realms take the digest computed once for the process.
5. **Measured, not kept**: the loop as a procedure of its own (`#force_no_inline`, item 1); the loop without the host bit
   (item 2). Not done this round: the collection's prologue, finalizers and sweep, the insertion hooks and the journal
   (item 1 of the list), and layout's own code (item 2): the round's time went to the interpreter and to the pages.

## What changed, round 16: first page loads

Item 10 of round 15's list. The machine quiet but for another agent's `test_all` during one series (thrown away and run
again: the numbers below are the quiet series). The browser: `wrentool bench perf`, profile builds, 5 runs of each
build, interleaved, the order turning; median, range in brackets; times in ms from the navigation's start (the page's
Navigation and Paint Timing). The base is master at 5af6e1ec.

1. **The engine's compiled code read ahead, off the window thread** (`js_read_ahead`, `src/page/js_realm.odin`;
   `wasm.read_ahead`, `src/wasm/module_cache.odin`). The first realm of a process hashed the 7 MB image for its digest
   (`wasm.digest`, 3.5 ms), read the disk cache's file and checked its HMAC-SHA256 (`disk_load`, `sha256_transf_hw`),
   had Wasmtime deserialize it and resolved its imports, all on the window thread before the page's first script. Now
   `js_startup` starts a thread that does all of it into the module cache's memory (only from the disk: a module not on
   disk is not compiled ahead, nothing is done when memory keeps no module); the first realm, and the compile threads'
   engines, wait for it only while it runs (a state in a futex: Off, Running, Done), then find the module in memory.
   In the samples of `nav_js_dom` the window thread no longer has `cache_acquire` nor `disk_load`. Test:
   `read_ahead_from_disk` (wasm: nothing compiled ahead without an entry on disk; read ahead on another thread, the
   instance made after it reads nothing from the disk and runs).
2. **What waits for a stylesheet goes on when it arrives** (`arrived_pump`, `src/page/styles.odin`, called when a
   sheet is in or failed, after an off-thread parse, and once the element events of sheets and images are
   dispatched). The parser's script that waits for the sheets and the document's load event looked again only at the
   poll (`javascript.load.poll_ms`, 16 ms, longer with the loop's timer slices); found in `shadow-dom.html`, whose
   sheets were in at 7 to 10 ms (Resource Timing) and whose script ran at 34 to 59. The first paint of such a page now
   comes after its script (as the specification has it, the script before the rendering): `shadow-dom.html`'s first
   contentful paint 8.1 -> 13.3 ms for an interactive 59.0 -> 11.9 ms. Test: e2e
   `jsload_a_sheet_in_lets_the_parser_and_the_load_go_on` (the poll set past the test's wait: the script runs and the
   load fires).
3. **Direct2D for color glyphs made ahead** (`font.color_prepare`, toolkit 0.74.0; `fonts_color_start`,
   `src/browser/fonts.odin`). The first glyph of a system color font a frame looked up (`is_color_glyph`, which asks
   what Direct2D can draw) made the WARP device and the Direct2D context on the window thread: 20.1 ms of `text.html`'s first
   paint (timed, once). The `DWriteCreateFactory` and color glyph formats round 15 saw under `platform_color_glyph`
   were that. A thread of its own makes it once the first frame's work is under way, joined before the font state
   goes. Made on the font preload thread instead (joined before the first present) it cost the first present 10 ms
   (`wrentool bench startup`, 4 rounds of 3: 247 against 238 without it): not kept there.
4. **Textures zeroed on the GPU** (toolkit 0.74.0, `zero_texture` in `render/render_d3d.odin`): a texture is a render
   target too and is zeroed by `ClearRenderTargetView`, where its zeros were uploaded: the glyph atlas's R8 page
   (2048 x 2048, a driver call per row) took 5.8 ms of the start, the first color page (RGBA, in 1 MB bands) 3.5 ms
   of the first frame with a color glyph (its `Submit`). Only a format that cannot be a render target is still
   uploaded.
5. **The thread count of `stats` walks this process's threads** (`base.process_threads`,
   `src/base/process_times_windows.odin`: `NtGetNextThread`, a handle to each thread of this process in turn). The
   process snapshot it replaced copied every process of the machine: 19.3 to 20.3 ms a call, against 10 to 12 µs (a
   process of 4 threads, best of 3); in the samples of `nav_index`, 17 ms of `ZwQuerySystemInformation` under `m_stats`
   before, none after. Test: `process_threads_counts_this_process_cheaply` (base: eight held threads counted, gone once
   joined, a count under 2 ms).

| | before | after |
|---|---|---|
| `js-dom.html`: DOM interactive, first contentful paint, load | 35.3 (34.6-35.3), 35.7 (35.1-35.8), 35.3 (34.7-35.3) | 7.5 (7.2-13.0), 8.1 (7.8-13.5), 7.6 (7.3-13.0) |
| `shadow-dom.html`: DOM interactive, first contentful paint, load | 59.0 (58.5-59.5), 8.1 (8.0-8.5), 59.0 (58.5-59.6) | 11.9 (11.6-14.6), 13.3 (12.9-16.1), 20.3 (20.1-23.2) |
| `style.html`: load | 26.1 (25.3-27.5) | 10.9 (10.6-11.1) |
| `legacy-html.html`: first contentful paint, load | 72.7 (72.2-73.5), 86.9 (86.2-87.6) | 72.7 (72.2-73.3), 72.1 (71.6-72.7) |
| `text.html`: the frame of its first paint, of it `Paint_Items`, `Submit` | 41.95 (41.73-42.42), 36.16 (36.02-36.39), 4.10 | 22.72 (22.17-39.49), 20.47 (20.06-21.55), 0.96 |
| `text.html`: first contentful paint, load | 14.7 (14.5-15.2), 2.5 | 15.0 (14.6-40.9), 2.5 |
| p10k: DOM interactive, first contentful paint | 33.1 (32.9-33.5), 55.6 (55.1-56.3) | 33.3 (32.6-33.7), 55.8 (55.4-56.5) |
| `index.html`: first contentful paint, load | 9.6 (9.5-10.4), 3.5 | 9.4 (9.3-11.2), 3.4 |
| `wrentool bench startup`, first present, single instance off / on (4 rounds of 3) | 243.5 (242-248) / 241.5 (239-242) | 238.5 (236-245) / 239 (237-241) |

`text.html`'s first contentful paint is the time of the frame that paints it, taken at its start, before the paint's
work: the frame itself is the measure of what changed there. What is left of that frame is Slug's data for the glyphs
the page uses first (`font.slug_glyphs`: 21 ms of the paint timed, once; `pick_band_count`, the sort of the curves by
band, the outlines): hundreds of glyphs of a dozen scripts, made once per face. The CPU column of the bench (the
process's during the load until quiet) is the same within its noise: the system counts it at 15.6 ms steps.

6. **Measured, not kept**: `color_prepare` on the font preload thread (item 3). **Not done this round**: the script
   stage of DOM-heavy pages (item 1 of the list), whose engine work needs its own series in `jspage`.

## What changed, round 17: first page loads, what they wait for

Item 10 of round 16's list. The browser: `wrentool bench perf`, profile builds, 5 runs of each build, interleaved, the
order turning; median, range in brackets; times in ms from the navigation's start (the page's Navigation and Paint
Timing), and the frame of the first paint of the page from the report's frames. Another agent built Wren on the machine
during the first series; its numbers were thrown away and the series run again, the machine quiet. The base is master at
143ebc1c. Slug's data was also timed alone (a program of the toolkit's font package: 400 glyphs of six system faces,
outline then `slug_build`, best of 5).

1. **Slug's bands made from one sort per axis** (toolkit 0.75.0, `slug_build`, `font/slug_build.odin`: `band_axis`,
   `band_grid`, `band_span`). The curves an axis's bands can hold were tested against every band of each of the ten
   band counts `pick_band_count` tries (108 bands an axis), then each band of the chosen count tested every curve again
   and sorted its own list. Now the curves of an axis are sorted once, by a `u64` key each (the order of the largest
   coordinate across the band, inverted, above the curve's index: the lists' order, stable), their extents kept in
   arrays in that order; a curve's first and last bands come from its bounds times the count, corrected against the
   bands' own bounds (the same expressions as before, so the same bands); a count's fullest band is the running sum
   of curves starting and ending; the lists are filled curve by curve in the sorted order. The bounds are read from the
   half-float texels already written (the conversions are calls: no F16C in the generic x86-64 target). The same data
   (test `slug bands_are_their_definition`: 300 glyphs of three faces, the counts and every list against the definition
   written out); built alone, 400 glyphs: Segoe UI 5.52 -> 2.77 ms, Times New Roman 8.21 -> 3.85, Nirmala UI 9.91 ->
   4.56 (the outlines 0.4 to 0.5 ms). In the page: `text.html`'s first paint frame below.
2. **The image decoder's start waits for nothing** (`decoder_start`, `codecs_wait`, `src/images/pool.odin`). Starting
   the pool, at a page's first image, waited on the window thread for its first thread to probe the optional codecs
   (COM, the imaging factory, HEIF's decoder: 12 ms of samples under `page::element_start` on `legacy-html.html`), for
   `<source type>` selection; the wait is now in `codec_supported(.Heif)`, the one answer that needs the probe, and the
   probe's post is given back for the next to ask. That 12 ms was what held `legacy-html.html`'s first paint, not a PNG's
   decode as round 16 read it (the decoder's threads were busy 1 ms in all): with the window thread taken, its
   stylesheet's completion (Resource Timing: `theme.css` 2 -> 41 ms) and then its `@import`'s (42 -> 72 ms) each waited
   for the next frame, whose time slot came first (below, item 4). Test: `optional_codecs_asked_after_the_probe`
   (images: the answer for HEIF after the probe, the probe's).
3. **Measured, not kept: Slug's data made by the thread that shapes a word** (`slug_prepare` from the toolkit's
   `shape_word`, built outside the atlas lock and stored under it, color faces and hinted glyphs left to the drawing).
   The paint's share went (`text.html` `Paint_Items` 20.0 -> 8.7 ms) but onto the passes the first paint waits for:
   `text.html`'s first contentful paint 15.4 (14.6-15.5) -> 38.2 (37.3-56.2) ms (its layout ended past its frame's
   slot), `shadow-dom.html`'s DOM interactive 12.1 -> 15.6 ms (its script's read of the layout shapes on the window
   thread), `index.html`'s first contentful paint 9.8 -> 13.2 ms. The data a frame draws is made before that frame
   whichever thread makes it; only less of it to make helps.
4. **Found, not changed: a frame waits for its time slot before the loop's tasks run.** A frame begins with the wait for
   its slot (`pacer_wait`: the timer, then the swap chain), and only then runs what arrived (`host.run_ready`): a task
   that comes during the wait waits with it. In a run of frames (each task asks for two) a first paint pays it once per
   hop: p10k's parsed document arrived during the wait of the frame that then styled, laid out and painted it (`Wait`
   15.1 ms of that 44 ms frame), `legacy-html.html`'s sheet and its import one slot each. Running the tasks while the
   slot is waited for (the wait woken by the loop's own wake-up, the frame started at once when a document's first paint
   can be made) is item 10 below: it changes when the loop's tasks run against the frame gate and the chrome frames made
   under scripts, a change of its own.
5. **Measured, not changed: the first realm** (round 16's item 10). Since the read-ahead, `js-dom.html`'s and
   `shadow-dom.html`'s scripts run 5 ms after their response or sheets, the instantiation, the realm's start, the
   script and the DOM work it does together (3 to 4 samples of 1 ms under `page::js_run` a load); moving the
   instantiation to the read-ahead thread (a Wasmtime store may change threads, but the instance's options, owner and
   scope are the page's) would take a part of that. Not done. p10k's first passes (style, layout, paint: 23 ms in the
   frame of its first paint, after the 15 ms of item 4) were not changed either; nor the script stage of DOM-heavy pages
   (item 1).

| | before | after |
|---|---|---|
| `legacy-html.html`: first contentful paint, load | 73.0 (72.2-74.0), 72.3 (71.6-73.3) | 40.4 (24.7-41.6), 40.1 (39.2-40.9) |
| `legacy-html.html`: the frame of its first paint, of it `Paint_Items` | 21.70 (21.23-21.95), 5.45 | 19.55 (4.52-20.04), 3.38 |
| `text.html`: the frame of its first paint, of it `Paint_Items` | 23.43 (21.98-25.22), 21.14 (19.84-22.46) | 17.81 (17.30-18.00), 15.59 (15.00-15.66) |
| `text.html`: first contentful paint, load | 15.3 (14.8-18.1), 2.6 | 15.0 (14.6-15.8), 2.5 |
| `shadow-dom.html`: DOM interactive, first contentful paint, load | 12.2 (11.8-13.5), 13.5 (13.1-15.1), 20.8 (20.5-22.5) | 11.8 (11.6-12.2), 13.1 (13.0-13.7), 18.0 (17.8-18.5) |
| `shadow-dom.html`: the frame of its first paint, of it `Paint_Items` | 12.64 (12.50-12.96), 6.08 | 10.16 (10.07-10.55), 3.82 |
| `index.html`: the frame of its first paint, of it `Paint_Items` | 11.06 (10.86-12.71), 3.79 | 10.48 (9.81-10.97), 2.73 |
| `js-dom.html`: DOM interactive, first contentful paint | 7.5 (7.3-9.3), 8.1 (7.8-10.2) | 7.6 (7.2-7.9), 8.1 (7.7-8.6) |
| p10k: DOM interactive, first contentful paint, `Paint_Items` of its first paint | 33.1 (32.8-51.1), 56.0 (55.4-111.2), 3.25 | 33.4 (32.8-33.5), 56.6 (55.6-58.4), 2.73 |

`text.html`'s first contentful paint is the time its frame starts (round 16): the frame is the measure there. What is
left of its `Paint_Items` by the sampler (3 loads): the color glyph probe of the faces that have color glyphs
(`platform_color_glyph`, DirectWrite's glyph formats), the half-float conversions' calls (`_extendhfsf2`) and the
outlines; then the GPU textures made for the page (`NtGdiDdDDICreateAllocation`). `legacy-html.html`'s range is its
frames: one run in five had its import in before a slot (24.7 ms).

## What changed, round 18: the frame's wait for its slot runs the loop's tasks

Item 10 of round 17's list, its first part. The browser: `wrentool bench perf`, profile builds, 7 runs of each build
(5 in the first series, thrown away: another agent built on the machine meanwhile, ranges of 30 to 90 ms), interleaved,
the order turning; median, range in brackets; times in ms from the navigation's start. The start: `wrentool bench
startup`, 4 rounds of 3, interleaved. The base is master at 96183c0e.

1. **The loop's tasks run while the frame waits for its slot** (`pacer_slot_wait`, `src/browser/pacing.odin`). A frame
   began with the wait for its time slot (the pacing timer, then the swap chain) and only then ran what had arrived
   (`host.run_ready` in its page phase): what came during the wait waited with it, a slot per hop of a load. Now the first
   frame of a pass runs the ready tasks and timers in its wait (`main.odin` `frame_tasks`, in a page phase of their own,
   `shell_wait_tasks`: a long script there is preempted by chrome frames as in the frame's), then waits on the timer armed
   for the slot or for the loop's next timer, whichever is first; a post from another thread during the wait fires the
   timer at once (the loop's wake-up, `wake_window` -> `pacer_wake`: an atomic flag says a frame waits on it; the timer is
   armed before the loop is looked at, so a post after that look is never lost). The tasks run once a frame, in its wait or
   else in its page phase: run in both, the first frame of the browser took what the second one ran before its first
   present (`home_idle`'s first frame to the first present 22 to 30 -> 41 to 54 ms): not kept. Off Windows the wait stays
   a sleep (no timer to fire). The frame gate does not change: the tasks run in the frame's Polling stage, where the
   chrome frames they may make are Light frames the gate admits there (the e2e suite's gate counts no violation). Test:
   `the_loop_tasks_run_while_a_frame_waits_for_its_slot` (browser: a post from another thread 20 ms into a wait of
   200 ms and a timer of the loop due at 40 ms both run before the slot, and the wait ends at its slot).
2. **A first paint does not wait for the slot** (`first_paint_due`, `src/browser/first_paint.odin`). When the current
   tab's document has not painted, waits for no render-blocking sheet or font, and has changed since its last layout or
   was held by render-blocking resources in the last page phase (`Page_Prep.blocked`), its frame starts at once: neither
   the timer nor the swap chain is waited for, and the swap chain may queue two frames for it (it is shown at the next
   refresh, not torn). The document's own changes alone were not enough: `legacy-html.html` was laid out before its
   `@import` was found, and the import's arrival changes the styles, not the document (its first paint 40.7 ms, as before).
   A frame started at once that laid the document out and held it (paint holding: nothing contentful yet) lets the next
   one wait for its slot (`Pacer.first_paint_laid`): a held page that a script changes is not drawn as fast as the
   thread goes.

| | before | after |
|---|---|---|
| p10k: DOM interactive, first contentful paint, load | 33.4 (33.0-35.5), 57.0 (56.4-72.7), 33.4 (33.1-35.6) | 20.7 (20.0-21.4), 44.0 (42.0-46.0), 20.8 (20.1-21.5) |
| `legacy-html.html`: first contentful paint, load | 42.4 (40.7-56.8), 41.7 (40.1-71.0) | 25.9 (25.2-27.7), 29.2 (25.1-32.2) |
| `shadow-dom.html`: DOM interactive, first contentful paint, load | 12.1 (11.8-12.4), 13.5 (13.2-14.0), 18.5 (18.1-19.9) | 12.2 (11.6-15.3), 13.7 (13.0-17.0), 18.8 (17.9-22.4) |
| `index.html`: first contentful paint | 9.7 (9.4-10.3) | 9.6 (9.3-11.1) |
| `js-dom.html`: first contentful paint | 8.0 (7.7-8.6) | 7.9 (7.5-13.0) |
| `style.html`: load | 9.3 (9.0-9.5) | 9.4 (9.1-10.0) |
| `text.html`: first contentful paint | 15.0 (14.0-33.6) | 14.9 (14.7-25.8) |
| `wrentool bench startup`, first present, single instance off / on | 247.5 (240-270) / 243.5 (240-253) | 240 (238-243) / 240.5 (237-247) |
| `wrentool bench cadence`: presented, gap p50, p95 (2 runs) | 184-185, 16.6, 17.1-17.7 | 184, 16.6-16.7, 17.1-17.3 |
| `wrentool bench idle`, at rest (blank, static, video; headless and hidden): wakes/s, the window thread's, frames | 68-73, 1.0-2.8, 1-4 | 70-75, 1.0-3.1, 1-4 |
| p10k_scroll, a hidden window (60 Hz): frames/s (2 runs) | 60.1, 60.7 | 60.7, 60.1 |

p10k's first contentful paint is now its first passes (round 17's 23 ms: styles, layout and paint, the frame of its
first paint 34 ms, of which the wait 3.8 ms for the parser's last post); the page's frames before it are the parser's
posts, each run as it comes. In a headless window p10k_scroll makes fewer frames (1 365 -> 1 099 in 8 s): as many
answer input (260 and 258), fewer are the back-to-back frames a remote call's task asked for, now run in the wait of the
frame that takes its input. `legacy-html.html`'s frame before its first paint still has a task of 18 to 21 ms: its samples
are in waits (`ZwWaitForAlertByThreadId`), not identified.

3. **Measured, not changed: p10k's first passes** (item 10): by the window thread's samples (3 loads, 1 ms) no function
   above 1 sample in the frame of the first paint: `compute_styles`, `expand_shorthand`, the layout's steps, `paint_stacking`;
   most of the work is on the style and layout threads, which this sampler does not see. A profile of the threads
   (`WREN_SAMPLE_THREADS=1`) is the next measure. **Not done this round**: the script stage of DOM-heavy pages (item 1).

## What changed, round 19: the licence card of about:wren under the pointer

`wrentool bench perf -Only card_hover -Shown` (about:wren?card=sample, the card scrolled into view, the pointer wandering
over it every 8 ms; `card_idle`: the card at rest), profile builds, 3 interleaved runs, 60 Hz, RTX 4070 SUPER (the
hardware adapter: `nvwgf2umx.dll` in the process, not WARP). GPU times are those of a GPU that the driver keeps at low
clocks for so little work: the counts of `-GpuSteps 1` say more.

1. **A document changed only in style attributes is refreshed, not laid out** (`styles_only_mutations`,
   `src/layout/refresh.odin`). The card's script writes its tilt in the style attributes of the card, its lettering and
   the seal's shadow at each frame (transform, `--rx`...): paint-only values, but any change of the document disqualified
   the refresh path, the incremental pass ran (0.2 ms, nothing to lay out), and the compositor, seeing a layout pass,
   drew the page directly for `render.compositor.settle_ms`, without its kept layers: the card's 59 planes (the rims are
   52 of them) rasterized again at every frame. Now the entries of the mutation journal since the last pass are looked
   at: `style` attributes of HTML elements only (no inline `<svg>` with foreign objects), and the styles say whether
   that is paint-only (`layout_serial`). Test: `inline_transform_refreshes` (layout).
2. **A plane keeps its raster scale for `paint.planes.settle_ms` after its last move** (`plane_plan`), not for one frame:
   a pointer that tilts at its own rate leaves frames without a move, and each one rasterized the planes whose scale
   needed was a quarter octave off (the rims, seen edge-on, at every tilt). Test:
   `planes_keep_their_scale_while_moving_and_sharpen_at_rest` (a still frame keeps it).
3. **Mip levels only where a plane is reduced more than twice** (`plane_needs_mips`, `PLANE_MIPS_REDUCTION`): across the
   slant, or along it more than the anisotropic taps take. The card's base and seal, rasterized again at every frame for
   their shader, built theirs at every frame. Test: `planes_tilted_by_the_pointer_build_no_mips`.
4. **The development build has no Direct3D debug layer** (`builder.odin`, `.Dev`: `-define:D3D_DEBUG=false`): `-debug`,
   there for the PDB, made ODIN_DEBUG true, which turned it on (`D3D11_3SDKLayers.dll` in `build\wren.exe`). The debug
   build keeps it.

| card_hover | before | after |
|---|---|---|
| layers cleared and drawn per frame (`-GpuSteps 1`) | 40.6, 38.6 (3.2 Mpx cleared) | 2.7, 2.7 (0.4 Mpx) |
| kept plane layers reused per frame | 13.2 | 52.3 |
| layout passes: incremental / refresh (8 s) | 269 / 89 | 3 / 217 |
| GPU draw p50, p95 | 3.8, 4.9-5.0 ms | 2.7-2.9, 4.1-4.2 ms |
| CPU work of a frame p50, p95 | 0.87-0.92, 2.3-2.9 ms | 0.79-1.01, 2.2-3.1 ms |
| frame gaps p50, p95 | 16.7, 18.4-19.4 ms | 16.7, 18.4-22.5 ms |
| input -> screen p50 | 37.2-37.7 ms | 37.3-37.8 ms |
| dev build, mean CPU of a frame (stats, 4 runs, another agent building at times) | 3.0-4.7 ms (debug layer) | 1.75-2.7 ms |

At 60 Hz on this machine the card made every frame before too: the CPU work was about 1 ms and the GPU's a few. What
went is the work a slower GPU, or the debug layer's validation of each of its calls, makes visible. At rest the card
draws for its sweep (the light crosses it in 40 % of 7 s) and not in the pause; the first frame that shows it costs
62 ms (its relief, lettering and seal made natively and uploaded, `about_card_relief.odin`): once. Input to screen is
the browser's anywhere (about:home: 38.5 ms).

## What changed, round 20: the loop JIT takes properties and calls

The loop JIT (`src/engine/jsrt/jit.odin`, [engine/jit.md](engine/jit.md)) compiled loops of number arithmetic,
comparisons, branches and locals; a property read, a call or a global kept the loop interpreted (round 13: "the loop JIT
does not take a loop that reads a property"). Measured with `jsengine run -jit -image <engine>` on
`examples/jsbench/micro.js`, `macro.js` and `realworld.js` (new: JSON records, particles updated in place, a sort with a
comparator, a tokenizer over `charCodeAt`, methods of a class), every engine image of the round in turn in one round, 5
rounds; other agents built and ran tests on the machine all along, so single runs moved by up to a factor of 2 (a round
of the base at twice its time is the machine): the figure is the median of the 5 runs, the range in brackets, and where
a series was hit the minimum says the same. The checksums of the three scripts are the same in every build.

1. **Properties** (`jit_get_field`, `jit_put_field`, `jit_global`, `jit_var_ref`, `j_prop_addr`). A named property read
   or written is a guard of the object's own shape against the shapes the site was compiled for (a few per site, tried
   in turn), then the slot at a constant index, in the object or in the prototype that holds it, whose shape is guarded
   too; a dictionary holder is checked by the key at the index; a global by the shapes of the realm's lexical
   declarations and of the global object; a closure variable where its cell points; a string's `length` and its methods
   from `String.prototype`. The guard is data in the object: nothing to invalidate, no cache. What a site takes comes
   from the frame's values when the loop is translated and from learn exits (the interpreter looks at what missed, the
   site takes it, the loop is translated again, at most 12 times); the shapes the code compares against are marked by
   the collector through the function. New types in the translation: objects (P), any value (V), entries under the
   loop's own stack (M, a `try`'s catch offset: such a loop was refused before).
2. **Calls** (`jit_call_insn`, `j_inline`, `j_math`, `j_char_code_at`). A small function of straight-line code that only
   reads and computes is inlined, the callee guarded; a deopt in it leaves the call to the interpreter as if it had not
   begun (then the loop is translated again with the callee's numbers taken for doubles, then the call is made).
   `Math.abs`, `floor`, `ceil`, `trunc`, `sqrt`, `min`, `max`, `imul` and `s.charCodeAt(i)` are computed inline. Other
   natives are called through a helper the engine exports to the module (`wj_jit_call`), the operand stack and the
   objects the loop holds written to the frame first; an exception is a throw exit the interpreter unwinds from.
3. **Measured, not kept: calls of bytecode through the helper.** A nested `interp_run` per call is slower than the
   interpreter's own call: a call of a small function 84 -> 130 ns, a closure counter 74 -> 102 ns, a method call
   185 -> 248 ns. A loop that calls bytecode it does not inline stays interpreted.
4. **Found on the way.** A compiled loop of a function sent every back edge of the function's other loops through the
   full dispatch (`hot_back_edge` tested the function's count of compiled loops): a `for-of` beside a compiled loop
   37 -> 56 ns an element; the hot loop now leaves only at the back edges of the loops the JIT took (`jit_loop_taken`,
   asked out of line, `hot_jit_taken`: inlined in the hot loop's five back edges, the check made the interpreter 3 % slower on
   nodes10k with the JIT off, and so did a throw exit of its own in `interp_run`'s back edges, 4 %; a call that threw now
   leaves the call to the interpreter with `jit_rethrow` as its callee, which throws the exception pending).
   Writing whole Value words (the tag's padding and the payload's high word zeroed) in the deopt stubs made a compiled
   `switch` loop 1.36 -> 1.62 ns (Cranelift's code for the larger stubs), with no reader of those bytes in the engine: the
   code writes the bytes the interpreter reads, as before. jitcheck.js ended at `tail(1000)` (a tail call recurses
   through the native call path and overflowed the guest's stack in both runs): `tail(100)`, and the 400 lines after it
   now run.

| | base | properties (1) | calls (2) |
|---|---|---|---|
| `micro.js`, geometric mean of the 20 cases | 1 | 0.420 | 0.233 |
| ... property get, set, a get over 4 shapes | 54.8, 25.3, 57.5 ns | 1.77, 1.31, 1.97 ns | 1.76, 1.30, 2.00 ns |
| ... a global read and written, an array written (`new Array(n).fill(0)`) | 40.5, 80.1 ns | 2.17, 0.95 ns | 2.17 (2.16-2.18), 0.95 ns |
| ... a call of a small function, a method on a prototype | 82.4 (82.4-96.1), 180 (178-191) ns | 79.7, 177 ns | 1.31 (1.30-1.32), 4.13 (4.08-4.16) ns |
| ... `Math.floor` / `Math.abs` | 153 (149-181) ns | the same | 3.26 (3.22-3.28) ns |
| ... int loop, switch, for-of, recursion, `new Point` | 0.64, 1.39, 38.9, 83.0, 341 ns | the same | 0.64, 1.39, 37.9, 82.0, 347 ns |
| `macro.js`, geometric mean of the 28 cases | 1 | 1.001 | 0.927 |
| ... array push/pop, Math.sin / sqrt / pow, Set add/has | 197, 264, 203 ns | the same | 113, 154, 160 ns |
| ... arguments / rest / spread, JSON.parse | 891, 3082 ns | the same | 929, 3052 ns |
| `realworld.js`, geometric mean of the 6 cases | 1 | 0.378 | 0.116 |
| ... parsed records summed, particles | 84.9 (83.9-86.8), 274 (265-314) ns | 4.95, 13.3 ns | 5.04 (4.95-5.42), 13.35 (13.17-13.35) ns |
| ... methods of a class, tokenizer over `charCodeAt` | 324 (322-330), 224 (222-228) ns | the same | 6.78 (6.71-6.85), 8.58 (8.54-8.63) ns |
| ... JSON parsed then summed, sort with a comparator | 1961, 1165 ns | 1984, 1205 ns | 2014, 1170 ns |

(The last series, the machine quiet: medians of 5 runs, ranges in brackets; "the same": within 2 % of the base. The base is master at 92630cdf.) What
neither step changes: what calls bytecode it does not inline (the closure counter, `fib`, the comparator of `sort`, which
the native calls), allocates (`new Point`, literals) or concatenates strings; the 4 % of the spread case is its
function's code, not compiled either way.

What deopts, and when: a learn exit when a site meets an object of another shape, a value of another type, a string,
or a callee that is another function (the loop translated again); a deopt when the shape is one the site does not read
inline (an accessor, a proxy, a frozen property written), an int overflows, an index is out of an array, a callee
inlined meets what it was not translated for (the call is then made by the interpreter, and the loop translated without
inlining it), a held array changed kind after a call; a throw exit when a native called throws. In jitcheck.js (722 lines
compared, interpreted against the JIT): 43 loops compiled, 9 refused, 228 deopts.

nodes10k (`jspage -image`, a timed copy: `build()` p50 of 400 frames, 3 runs each, interleaved): with the JIT 11.00
(10.99-11.06) -> 11.11 (11.11-11.16) ms, without it 11.01 (11.01-11.06) -> 11.02 (10.91-11.06) ms; its loops call DOM getters and
concatenate strings, which the JIT does not take (one is compiled and leaves at its first getter, 16 times).

Tests: jitcheck.js (above), test262 with the JIT 49/82220 errors before and after (0 regressions), interpreted the same;
jitcheck.js under a collection every 8 KiB with poisoned cells (`-define:JSRT_GC_STRESS=8192 -define:JSRT_GC_POISON=true`):
the same; `judge capi` 64 checks.

Not done: whole functions compiled by their call counts (a recursive `fib`, a function called from interpreted code);
calls of bytecode that is not inlined (a direct call into compiled code, which needs the callee compiled whole); the
allocation of objects and arrays in compiled code (`new Point`, `{a, b}`, `[i, j]`: such a loop stays interpreted);
string concatenation and comparison by value; callees with branches (a `?:`); polymorphic inlining.

## What changed, round 21: the JIT compiles functions, calls them directly, makes objects and strings, reads DOM attributes

What round 20 left, in its order ([engine/jit.md](engine/jit.md)). Measured with `jsengine run -jit -image <engine>` on
`examples/jsbench/micro.js`, `macro.js` and `realworld.js`, every engine image of the round in turn, 5 rounds (the
median, the range in brackets); DOM loops and nodes10k in `jspage -image` (a timed copy of nodes10k: `build()`'s p50 over
400 frames). Other agents built and ran `test_all` on the machine for part of the round: the series below are the ones
taken while it was quiet, and a step's figures were checked again on their own where a series was hit.

1. **Whole functions** (`jit_fn_enter`, `Jit_Info.fn`). A function without loops of its own is compiled once its calls
   reach `javascript.jit.call_threshold` (500 now, passed to the engine: the glue had ignored it), as the region
   `[0, end)` entered at its call: where `frame_push` pushes the callee's frame (`jit_pushed`), in `interp_call`
   (`jit_entered`), in the helper of compiled code. The interpreter's own code is as it was but for `frame_push`'s last
   line and `interp_call`: the same hooks in `interp_run`'s call paths and in `hot_call` made interpreted code 5 %
   slower with the JIT off (a selection of `macro.js`, 3 runs: the native calls, `class new`, destructuring), measured
   and moved. Measured, not kept: not entering a small function compiled from the interpreter (under 16 bytes of
   bytecode, whose entry might cost more than its code saves): an interpreted loop calling two such functions 220 ns
   either way.
2. **Direct calls** (`j_direct_call`). Compiled code calls a function that can be compiled whole (any closure of its
   bytecode) itself: the callee's frame pushed on the value stack exactly as `frame_push` pushes it, its code called
   through the engine's table (imported by the module), the frame popped as `frame_pop` pops it. No state of the caller
   lives across the call but in its frame (frames in memory, as today: nothing to save around the call); the callee
   leaving other than by its return is finished by the interpreter (`jit_call_finish`). A first version through the
   helper (`frame_push`, then the callee's code) was slower than the interpreter (fib 78 -> 104 ns a call): the helper's
   layers cost more than the call. Compiled code nested on the host stack is bounded (`JIT_MAX_NEST`): a recursion
   deeper than that is interpreted, to the same depth limit.
3. **Objects made by compiled code** (`jit_new`, `j_prop_add`, `jit_define_field`). Plain objects, literals, arrays and
   constructions from a helper of the engine (its allocator and collector unchanged: the code reaches a safe point only
   through a call, which writes what it holds to the frame first); a property appended through the shape's transition
   (a constructor's `this.x = x`), a literal's fields with no guard (the shape the code made is known until a join).
4. **Strings** (`jit_add`, `jit_streq`). `+` of a string and `s += x` by the engine's concatenation (ropes, append
   buffers), done only when no conversion could run code or throw (else the interpreter makes it, once); `===` of
   strings by value.
5. **Getters and DOM objects** (`j_call_getter`, `Shape.version`). Native getters called (as the hot loop calls them:
   `call_native`; through `call_internal` the DOM walk below was 790 ns, not 530), an exception exact through the
   context's thrower (the interpreter makes the read again and throws); DOM wrappers ordinary objects, the Web IDL
   prototypes (dictionaries) walked past, guarded by their version. A global's accessor (`window.document`) is not
   called: there is no object on the stack to put the thrower in, and a throw exit of the interpreter's back edges was
   measured 4 % in round 20. nodes10k's building loop reads `document` and stays interpreted.
6. **Natives called as the hot loop calls them** (`jit_call`): a native function called through `call_native` directly,
   without `call_internal`'s dispatch (`macro.js`'s native calls in compiled loops, 5 runs, base, 5, 6: array push/pop
   116 (114-125), 117, 107 (105-112) ns; Set add/has 168 (166-259), 169, 150 (149-154) ns; Math.sin / sqrt / pow 160
   (155-230), 164, 147 (146-189) ns: from 5 % slower than the base to 8 to 10 % faster).

| | base | 1, 2: functions | 3: objects | 4: strings |
|---|---|---|---|---|
| `micro.js`, geometric mean of the 20 cases | 1 | 0.892 | 0.843 | 0.816 |
| ... recursion (`fib`), closure counter | 82.8 (77.4-95.4), 76.7 (71.3-91.1) ns | 27.2 (26.0-34.6), 23.5 (22.8-29.0) ns | 26.6, 23.4 ns | 26.9 (25.9-30.2), 23.4 (22.9-27.8) ns |
| ... `new Point(i, i)` | 410 (364-697) ns | 387 ns | 116 (108-476) ns | 113 (110-141) ns |
| ... string concat + `charCodeAt` | 242 (237-559) ns | 244 ns | 263 ns | 130 (124-146) ns |
| ... try/catch in a loop (interpreted) | 69.6 (68.0-99.2) ns | 74.0 ns | 73.2 ns | 76.3 (71.8-78.6) ns |
| `realworld.js`, geometric mean of the 6 cases | 1 | 0.961 | 0.952 | 0.950 |
| ... sort with a comparator (a native calling it) | 1190 (1175-1226) ns | 931 ns | 926 ns | 910 (900-951) ns |
| `macro.js`, geometric mean of the 28 cases (base, 4) | 1 | | | 0.865 |
| ... object literal, array literal | 244 (242-254), 132 (129-132) ns | | | 56.3 (55.8-58.4), 82.0 (81.5-83.0) ns |
| ... switch on strings, map + filter + reduce | 105 (104-113), 385 (381-389) ns | | | 12.8 (12.7-13.0), 328 (319-332) ns |
| ... array push/pop, Math.sin / sqrt / pow | 112 (112-114), 153 (151-155) ns | | | 118 (116-120), 160 (157-165) ns |
| ... class new + super, closure creation + call | 995 (992-1012), 505 (481-546) ns | | | 1044 (1017-1058), 546 (523-587) ns |

The checksums of the three scripts are the same in every build. The slower cases of the last column: native calls made
by compiled loops (5 %), which item 6 made faster than the base; and interpreted code: a closure made and called in a
loop the JIT does not take 520 -> 560 ns with the JIT off too (+5 % at item 3, +4 % at item 5, bisected by image; the
transition search inlined again into `add_property` changed nothing, measured), try/catch in a loop 6 %: the engine's
code placed otherwise, not explained further.

DOM (`jspage`, 3 runs each, ns an iteration): a walk reading `firstChild`, `nodeType`, `nextSibling`, `textContent.length`
750 (736-763) -> 530 (530-548); `m.size` in a loop 115 -> 48; emptying a list (`removeChild` of `lastChild`) 1400, the
same (the DOM's call). nodes10k `build()` p50 (7 interleaved runs): with the JIT 9.31 (9.07-9.63) -> 8.96 (8.62-9.26)
ms, without it 9.15 (8.96-9.53) -> 8.84 (8.76-9.15) ms: the JIT's part is nil there, its building loop interpreted.

Tests: test262 with the JIT (thresholds 2 and 1) 49/82220 errors before and after (0 regressions), interpreted the
same; jitcheck.js 722 -> 762 lines compared (whole functions and their calls, recursion past `JIT_MAX_NEST` and the
engine's limit, objects and literals, strings, getters, dictionary prototypes), also with `-jit-step`, `-jit-threshold 30`
and under `JSRT_GC_STRESS=8192` with `JSRT_GC_POISON`; `examples/jsweb/jit_dom.js` (e2e `jsweb_jit_dom`, every function
compiled at its first call): DOM attributes read by compiled loops, a loop that empties the list it reads, a getter that
throws once, one replaced by a script's. Found by test262 at threshold 1 on the way: a function without an operand stack
had its result written over its frame; the truth of an array held in a local; re-taking held arrays after a tail call
resumed past the end of the function; an object added took the numbers path.

Not done: a global's accessor (`document`: nodes10k's building loop); callees with branches inlined, polymorphic
inlining (step 5 of the round's list: not reached); objects allocated inline by the code (the helper's
`create_from_ctor` is most of `new Point`'s 113 ns); a JavaScript getter or setter called by compiled code.

## What changed, round 22: what the user does while the page's script is busy

A page's script, its events, timers, styles, layout and paint run on the window's thread; only a long layout pass goes to
the page thread (`page_thread.odin`). While a script runs, the Wasm engine's epoch hands the thread to the chrome
(`shell_preempt`), which makes *chrome frames* between two instructions of the guest (`shell_frames.odin`): the chrome is
built with the input that came, the page area shows the page's last frame (its pixels, kept on the GPU), and input meant
for the page waits, in order, for the page's turn. What follows the user then is what a chrome frame can do without the
page. Ladybird's text-selection drags off its main thread are the model: the press goes through the page (a listener may
cancel it), then the drag follows at once and the page sees the selection when it next gets a turn.

**The audit.** `examples/site/busy.html` (a slider for the length of a task, 100 to 400 ms, a loop of them or one; text to
select, a link with a `:hover` style, a field, a scroll box, boxes with CSS animations of `transform` and `opacity`, a
tall page), and its `hold()`: one task that keeps the thread until the window's height changes. Measured headless in the
e2e harness's process: `e2e.while_busy` (`src/e2e/busy.odin`, `src/browser/busy_input.odin`) gives the chrome frames made
under that task one step each (an event, a capture of that frame, the new height that ends the task), so what is checked
does not depend on when the script runs; a step is a chrome frame, 12 to 30 ms apart there. "Follows" below: the frame
after the input shows it; "waits": nothing moves until the task ends (the rest of it, up to its whole length).

| while the page is busy | before | after |
|---|---|---|
| the wheel | follows: the page's last pixels move, what was below the fold is blank | follows, painted from the page's last layout: what comes into view is there |
| Page Down, Space, the arrows, Home, End (the page has the keyboard) | waits | follows when no `keydown` / `keyup` / `keypress` listener could see the key, no form control has the focus and the document is what the key scrolls; else waits |
| the thumb of the document's scroll bar | waits | follows (the press, its moves and its release are the shell's, as in a full frame) |
| a container's scroll bar | waits | waits |
| a text selection's drag | waits (the DOM's selection right once the task ended) | follows: the highlight from the last layout; the DOM's selection, `selectionchange`, the moves the page sees: when the task ends, as before. Not with a `mousemove` / `pointermove` listener anywhere, nor before a first selection with a `selectstart` one |
| hover (`:hover` restyle) | waits | waits (a restyle is the page's) |
| the caret's blink | frozen | frozen (60 captures over 1.8 s: no change) |
| CSS animations of `transform` and `opacity` | frozen | frozen (the same captures) |
| resizing the window | the chrome at the new size every frame, the page's last frame anchored at the top left | the same |
| switching tabs (a click on the tab strip) | follows: the other tab's last frame | the same |
| the menus, the address bar with the mouse | follow | the same |
| Ctrl+L, Ctrl+Tab, Ctrl+Page Up / Down with the page's keyboard | wait (the keys are the page's first; the commands were queued for after the task) | follow when no key listener could see them (the commands that act on the chrome alone run in the chrome frame: the address bar, the next or previous tab) |
| the release of a press made before the task | lost: it went to the chrome, the page never had its `mouseup` (a drag left selecting) | the page's, after the task, with the drag's moves even outside the page area |

1. **A drag's selection under a busy page** (`selection_shell.odin` `Sel_Preview`). The press is the page's turn's, as
   before: `pointerdown`, `mousedown` and the gesture begin there. A move under a long task waits for the page in
   `deferred` as any input; the chrome frame also works out what it will select (`gesture_range`, the anchor and focus of
   the gesture's unit from the last layout, `selection_preview_move`) and paints the page again from its last layout with
   that range (`shell_paint_layout`). Nothing of the page changes: the DOM's `Selection` is the one the task began with
   (the test reads `getSelection()` at the task's end: empty), no `selectionchange` fires under it. When the page has its
   turn, the moves are given to it in order and each extends the selection as it would have then (`extend_to`), and the
   selection's change is one `selectionchange` (HTML's "schedule a selectionchange event" is a flag: the moves of one turn
   coalesce). The preview goes then; it stays only where the task changed the document (the layout older than it:
   `Selection_Shell.stale`, the gesture extends to the pointer once laid out again, which it did not before: a move made
   while the layout was stale was dropped). What I chose from the specs: UI Events makes `mousemove` cancelable but
   cancelling it does not stop a selection in browsers (Chromium, Firefox); a drag is stopped by `mousedown` or
   `selectstart` being cancelled (Selection API, "selectstart": cancelable, fired before a selection begins). So the preview
   is shown only when no move can run the page's code: no `mousemove` or `pointermove` listener on any node or the Window
   (`page.page_listens`), and no `selectstart` listener before the gesture has started a selection. A listener that the
   page adds during the task is not seen (the preview is what the eye sees; what the page observes is always its turn's).
2. **Painting a busy page from its last layout** (`shell_frames.odin` `shell_layout_paintable`, `shell_paint_layout`). What
   a page's frame was painted from besides its layout is noted (`Paint_Source`: the document's mutations, its images' and
   canvases' pixels, its form controls' serial, its style rules), and while none of it has moved, the layout is not on the
   page thread, the page has no frames (their documents are laid out when painted) and the window has its size, a chrome
   frame paints the page again from that layout through the compositor's pictures: the same pixels but where the shell
   changed something (the scroll, a drag's selection). A script that changed any of it (`textContent`, a canvas, a field's
   value) keeps the last pixels, as before: the screen never shows a script's work half done. The wheel used to move the
   pixels only (blank below them); the document's scroll is now also taken before the input that waited (it was aimed at
   what the screen showed), not after it.
3. **The scroll bar's thumb** (`shell_bar_event`): a press on the thumb of the document's bar as the last frame drew it
   (the snapshot's bar, at the scroll shown) starts the tab's `Scrollbar_Drag`, the moves scroll the document as the wheel
   does, the release ends it; a drag begun in one kind of frame goes on in the other. Not while presses or keys the page
   has not had wait (they must not be overtaken), not a container's bar (its offsets are the layout's).
4. **Keys** (`shell_page_key`): with the page's keyboard and no key listener anywhere, a key does what the page's turn
   would do with it: the browser's shortcuts (`browser_shortcut`, now one procedure for both) and the tab keys go to the
   chrome, the modifiers too, and the keys that scroll the document scroll it (`keyscroll.odin`, its container search and
   the document's step split out: `key_scroll_container`, `key_scroll_document`). Commands that act on the chrome alone are
   no longer queued for after the task (`Command.chrome_only`: `nav.focus_address`, `tab.next`, `tab.previous`).
5. **The moves and the release of a press the page had** (`main.odin` `route_page_input`, `shell_route`): a press on the page
   in a full frame is noted (`press_to_page`, which chrome frames only set for their own presses), so a release under a
   long task waits for the page instead of going to the chrome (the gesture used to stay down, selecting under a button
   that was up), and the drag's moves outside the page area wait for it too, as a full frame gives them.

Before and after, on `busy.html` under `hold()` (headless, `e2e.while_busy`): a drag, the thumb, Page Down and Ctrl+L
showed in no chrome frame (the first frame that showed them was the one after the task: the rest of the task, 100 to 400
ms on the page's slider); they show in the chrome frame after the input (one frame at the display's rate; 12 to 30 ms
between two steps headless). A chrome frame that paints from the layout replays the compositor's pictures (a selection
change records the chunks it touches again), as a full frame's paint does.

Tests: `src/tools/e2e/busy_page.odin` (step "input under a busy page"): a drag's highlight in the frames under the task,
the task's empty selection and unchanged `selectionchange` count, the selection and its `selectionchange` once it ran,
the release under the task the page's (a move after it selects nothing more), and with a `mousemove` listener no
highlight and the same selection; the thumb's and Page Down's scroll under the task (the
task's `scrollY` 0, the busy frame the same pixels as the page once it ran, the bar's presses no `mousedown`), the address
field changed by Ctrl+L under the task. Each fails without its change (checked by building the tests against the shell
without it).

Not done: hover, the caret's blink and CSS animations under a long task. The three are the page's: `:hover` is a restyle;
the caret is painted inside the control's picture from a timer of the loop, which a running script does not let fire, and
the snapshot has it on or off; animations are sampled by the style pass and their matrices set by the layout's paint-only
refresh. Making `transform` / `opacity` animations tick without the page needs the compositor to own their timelines (the
keyframes resolved to matrices and alphas per frame, the chunks of the animated spaces drawn with them): the next step of
this list, as is a container's scroll bar and the wheel over a scroll container (both need the layout's offsets of the
container, written only by the page's turn).

## What changed, round 23: `document` read by compiled code, objects allocated inline, accessors of the script's

What round 21 left, in its order ([engine/jit.md](engine/jit.md)). Measured as round 21 did (`jsengine run -jit -image
<engine>`, every image of the round in turn, 5 rounds, the median and the range in brackets; nodes10k in `jspage
-image`, a timed copy: `build()`'s p50 over 400 frames). Other agents ran test suites on the machine for much of the
round: each run waited for the machine to be quiet (under 1.5 cores busy besides it) and ran at a high priority; series
taken while it was busy are said so.

1. **A global's accessor** (`jit_global`, `j_call_getter`). `window.document` is the global object's own accessor; a
   read of a global has no object on the stack to put the thrower in. Kept: when the next instruction reads a named
   property of the value (`document.createElement`), the thrower goes in the result's place with that property as its
   accessor, and the throw exit resumes at the next instruction, which throws the exception pending. The interpreter's
   code is not touched (a throw exit of its own in its back edges was 4 % of nodes10k with the JIT off, round 20). The
   loop was still refused after that: the callee `document.createElement` was not known at translation (the value of
   a getter); a call whose callee the translation cannot tell now leaves through a learn exit once
   (`JIT_AUX_CALLEE`, `Jit_Site.callee`), and a read of an unknown object at a site that learned its shape takes what
   the prototype holds for its hint. nodes10k `build()` p50, 7 interleaved runs (the quiet ones): with the JIT 9.1
   (8.8-9.1) -> 7.9 (7.65-8.1) ms, without it 9.0 -> 9.1 ms (the same). In `macro.js` the object literal was 57 -> 66
   ns at this step alone (code placement, not explained further), made 28 by step 2.
2. **Objects allocated inline** (`j_alloc`, `j_ctor_proto`). `{}` cost 58 ns through the helper, of which the
   allocation itself is little: the call, `shape_root_for`'s map, the temporary root and its drop. The code now pops a
   block of the pool's class from the free list (zeroed) or cuts it from the bump chunk, links the cell, counts it,
   charges the heap and its peak, and writes the object, as `cell_new` and `object_new_shape` do; a construction reads
   the constructor's `prototype` slot (its shape and the value guarded). The collector's contract is the same: no
   allocation collects, the object is only in the code's hands until its next call or exit. `new Point(i, i)` 110
   (107-160) -> 51 (50-53) ns, `{a, b, c}` 56.7 (56.3-59.8) -> 28.4 (27.4-30.0) ns; array literals keep the helper
   (`Array_Data` and its values: 83 ns).
3. **The two slowdowns with the JIT off**, bisected by engine image (round 21's commits, only `src/engine/jsrt` and
   the glue's `jit.odin` taken from each, 7 runs): a closure made and called in a loop 531 (524-558) ns before round 21,
   522 at its first step, 565 from its third (`shape_transition` factored out of `add_property`, so the JIT could
   append properties: a closure's four properties each paid the call), 540 (537-562) with it inlined again (kept;
   round 21 measured that change as nothing, on a noisier machine). try/catch in a loop was not slower: 68.4
   (67.7-71.8) before round 21, 69.3 (68.0-73.1) after, 67.4 with this; the 6 % was noise.
4. **Getters and setters of the script's** (`j_call_setter`, `jit_setter`, `jit_accessor_call`). Through the helper,
   as compiled code calls a function (the getter's frame pushed, its compiled code run): a getter in a loop 151
   (151-153) -> 78 (77-80) ns, a class's 168 -> 77 ns, a setter 145 (141-412) -> 81 (80-126) ns, `macro.js`'s getter
   access 184 -> 92 ns. The accessor's call out of line in the helper made Map's `size` 37 -> 44 ns; inlined, 36.7.
   The helpers now set the frame's pc to the instruction after the access, as the hot loop does.
5. **Found after the round: the interrupt in a compiled loop that calls.** The compiled code gave the interpreter its
   safe point every `JIT_BUDGET` iterations whatever the iterations did; the interpreter polls once its native calls count
   for a poll (`NATIVE_CALL_POLL_WEIGHT`). With step 1 a `document.write` flood is compiled, and 16 384 slow writes ran
   between two polls: past `wasm.max_call_ms` the page lost its engine (`js_hostile_document_write`, intermittent). A
   loop that calls now also leaves for the safe point once `interrupt_counter` reaches `INTERRUPT_POLL_EVERY` (a load
   and a compare at its back edge: the accessor loops above within 1 ns). `js_hostile_compiled_native_flood` (a
   compiled loop of `big.join(document.title)`, each ~0.1 ms) fails without it, passes with it.

| | base | 1: `document` | 2: allocation | 3, 4 |
|---|---|---|---|---|
| nodes10k `build()` p50, JIT on / off | 9.1 / 9.0 ms | 7.9 / 9.1 ms | | 7.44 (7.41-7.84) / 8.74 (8.67-9.08) ms (base in this series 8.63 (8.47-8.78) / 8.89 (8.73-9.01)) |
| `new Point(i, i)` | 110 (107-160) ns | 118 ns | 51 (50-53) ns | |
| object literal `{a, b, c}` | 56.7 (56.3-59.8) ns | 66.0 (60.6-69.6) ns | 28.4 (27.4-30.0) ns | |
| a closure made and called, JIT off | 565 (556-586) ns | | | 540 (537-562) ns (531 before round 21) |
| a getter, a setter of the script's | 151, 145 ns | | 147, 144 ns | 78, 81 ns |

Every other case of `micro.js`, `macro.js` and `realworld.js` within its range at steps 1 and 2 (the quiet series); the
checksums the same in every build.

Tests: jitcheck.js 762 -> 779 lines compared (a global accessor read, throwing once, its value kept, replaced, deleted;
constructions with their own prototypes and one replaced while running, literals grown and frozen; getters and setters
of the script's counting, throwing once, changing shapes and arrays, recursing; a native setter), also with
`-jit-step`, `-jit-threshold 30` and under `JSRT_GC_STRESS=8192` with `JSRT_GC_POISON`; `examples/jsweb/jit_dom.js`: a
compiled loop that reads `document`; test262 with the JIT (thresholds 2 and 1) and interpreted 49/82220, 0
regressions; `judge capi` 64 checks.

Not done: array literals allocated inline; a direct call of a getter of the script's (through the helper it is 78 ns,
a direct call of a function about 25); `new F()` of a function without an operand stack (`function Empty() {}`: not
compiled whole, called through the helper, 190 ns); callees with branches inlined, polymorphic inlining.

## What changed, round 24: what still froze under a busy page

Round 22's list, in the order a user feels it: what moves by itself (animations), the scroll boxes, hover, the caret.
All of it is drawn by a chrome frame painting the page from its last layout (round 22's `shell_paint_layout`, while
`Paint_Source` says nothing it was painted from has moved), with values the shell sets on that layout for the one paint
and puts back at once (`shell_shown.odin` `Shown`): nothing of the page runs in between, and what its scripts read
(`getComputedStyle`, `getAnimations()`, `scrollTop`, the boxes) stays what their turn left. Measured as round 22 did,
on `busy.html` under `hold()` in the e2e harness's process (`e2e.while_busy`), with a new step, `busy_wait` (chrome
frames until that long has passed: what moves by the clock moves meanwhile).

| while the page is busy | before | after |
|---|---|---|
| CSS animations and transitions of `transform` and `opacity` | frozen (two captures 400 ms apart: the slid box at x 181 in both, the faded one's red 26 in both) | go on: the box at x 184 then 274 (a slide of 200 px/s), red 26 then 49 (a fade of 0.2 a second); at the page's turn the animation's `currentTime` is the clock's (3 ms off) and the box goes on from where it was shown |
| the wheel over a scroll container | the document scrolled instead (166 px); the container never had it | the container scrolls at once (167 px), painted from the layout; the document stays; `scrollTop` 0 under the task, the offset and the container's `scroll` event at the page's turn |
| the thumb of a container's scroll bar | waits (the drag happened at the page's turn: the busy frame differed from the page once it ran in 5464 px) | follows: the busy frame is the box as the page then shows it; the bar's presses are not the page's |
| the caret's blink | frozen (6 captures over 450 ms at a 200 ms blink: all the same) | blinks: 2 or 3 of the 5 later captures differ from the first |
| hover (`:hover` restyle) | waits | waits (below) |

1. **Animations the compositor runs** (`style.timeline_compositor_values`, `page.animations_compositor_values`). The
   compositor already applies a transform as a slot of its pictures and an opacity around their replays (round 4): a
   chrome frame only needs the values. They are taken from the page's timeline without moving it: the run's local time
   advanced on a copy to the frame's time (the pacer's `frame_ms`, the clock the page's ticks pin), the keyframes the
   page resolved for the element (`apply_run`, `transition_value` on a copy of its cascaded style), then the box's
   matrix (`layout.box_matrix_of`) and its group's alpha. No event fires, no run, overlay or clock changes: at its turn
   the page's tick reaches the same instant from the same clock, so nothing jumps and `getAnimations()` reads what it
   would have. Only elements whose effects animate `transform`, `translate`, `rotate`, `scale` and `opacity` alone
   (Chromium's composited animations), whose box has the transform space or the opacity group in the last layout (an
   opacity of 1 has no group: that box waits for the page), not in a 3D plane, not animated by a script's Web
   Animations (their timing is the script's to change). A busy page that animates so now has chrome frames at the
   display's rate where it had none: under three 1 s tasks with a sliding box, 198 to 204 chrome frames, 164 to 260 ms
   of them (0.76 to 1.24 ms median each, headless): 5 to 9 % of the thread, what full frames would cost it were it not
   busy. While a style pass's threads run (its wait lends the thread to chrome frames) the timeline is not read.
2. **Scroll containers** (`Shell_Frames.boxes`, `shell_wheel_box`, `shell_box_bar_press`). The wheel over the page
   looks for the container under the pointer that can move that way (`wheel_scroller`, the full frame's search, asked of
   the layout with what the chrome frame shows set on it); the offset it shows is kept per container and painted as the
   layout's offset (`l.scroll`, a slot of the pictures). At the page's turn, before the input that waited (as for the
   document), the layout takes it (`set_scroll`), and its next frame fires the container's `scroll` as for any scroll
   (`scroll_events.odin` compares offsets). A press on a container's thumb is found on the layout as a full frame finds
   it (`scrollbar_at`), and the drag is the shell's `Scrollbar_Drag`, which a frame of either kind goes on with. When the
   layout cannot be painted (the script changed what shows), the wheel over a container waits for the page instead of
   scrolling the document under it.
3. **The caret** (`forms_shell.odin` `caret_phase`): its phase is the clock's since the field's last change, which the
   full frames read through a timer of the loop (a running script does not let it fire). A chrome frame reads it too,
   paints the page from its layout when the caret blinks and asks for a chrome frame at each toggle.
4. **Hover: not done.** A `:hover` change is a restyle of the element entering or leaving the state, of what selectors
   reach from it (`:hover .x`, `:hover + .x`, `:has(:hover)`), written into the page's styles, which scripts read
   (`getComputedStyle`, `matches(':hover')`); showing it off the page's turn needs a second set of styles for those
   elements and a refresh of the layout pointing at them, a style match in a chrome frame. And a hover that starts a
   transition (`busy.html`'s `#hoverbox`) starts it at the page's turn, not when the chrome frame showed it: the box
   would jump back to its start. Only a hover whose rules change nothing but `transform` or `opacity` with no
   transition could be shown honestly, at the cost of the style match; Chromium and Firefox restyle hover on their main
   thread too (a busy page shows no hover in them either).

Tests (`src/tools/e2e/busy_page.odin`, step "input under a busy page"): a slide and a fade under the task (the box at
least 40 px further and the faded box's red at least 10 higher after 400 ms; at the page's turn the animation's time is
the clock's within 150 ms and the box no further back); the wheel over the scroll box (the box's pixels moved under the
task, `scrollTop` 0 then, the offset, the document's `scrollY` 0 and the box's `scroll` event once it ran, the busy
frame the box as it then shows); its thumb (the same, and no `mousedown` for the page); the caret's blink (6 captures
90 ms apart at a 200 ms blink: one differs from the first). Each fails without its change (the tests built against the
shell without it: the values above).

## What changed, round 25: what a first load waited for, found by loading it again and again

Item 10 of the list, as it stood after round 18 (and the list brought up to date: rounds 19 to 24 had not been added to
it). The browser: `wrentool bench perf`, profile builds, the base (4e78b4fa: 0.6.30 and the Inventory's commit) and the
round's binary in turn, the order turning, 7 runs of each, median, range in brackets; times in ms from the navigation's
start. Conditions: other agents built and ran WPT for most of the round (6.7 of the 16 logical processors busy besides the
bench at one reading; p10k's first paint then 72 against 62 ms, ranges overlapping: those series are not below). The
table below is the last series, taken when the machine had gone quiet (0.5 processors busy just after it). A sheet's
parsing and index were measured alone, outside the browser (a program of `wb:css` and `wb:style` over p10k's sheet, 87 KB
and 2 000 rules, 41 passes a run, the thread's cycles by `QueryThreadCycleTime`, 11 interleaved runs, and on the loaded
machine 15): the same code gave 11 to 19 ms from one run to the next while the others ran, cycles moved with it, so the
figures are the quiet series.

**The measure.** One load is about 30 samples of the window's thread, and nothing above one sample: why round 18 saw no
function stand out. `p10k_renav` and `legacy_renav` load a page again and again from itself, for as long as `-Seconds`
says. And timers put for the round around the stages (not kept) gave what the samples could not, for one load of p10k,
in ms: the parser's thread 20.2 (`html.parse_into` 10.1, the walk for `<style>` and `css.parse_stylesheet` 7.3, decoding
and the rest 2.8); the window's thread `compute_styles` 13.9 (the engine's rebuild 7.2, half of it compiling declarations;
the style threads 3.9; the rest 2.8), the layout 15.6, then a second layout of 1.6.

1. **`legacy-html.html`'s task of 18 to 21 ms: the codecs' probe, under the pool's lock** (`decoder_thread`,
   `src/images/pool.odin`). Unidentified since round 18, its samples in waits. With callers (`WREN_SLOW_MS=10
   WREN_SAMPLE_STACK=1`) 18 to 25 of the frame's samples read `ZwWaitForAlertByThreadId <- images::submit <-
   page::entry_start`: the page's first image waits for `Decoder.mu`, which the pool's first thread held while it probed
   the optional codecs (`CoCreateInstance` of WIC's HEIF decoder). Round 17 took the wait out of `decoder_start`; the lock
   stayed. The first thread to claim the probe (`codecs.claimed`, an atomic) now runs it holding nothing, and a second
   thread decodes meanwhile. Test: `a_submit_does_not_wait_for_the_codecs_probe` (images: the pool's lock is free while a
   gate holds the probe; fails with the lock around it, checked).
2. **A sheet's selectors held 3.3 KB a rule** (`css/selectors.odin`). Each list of a selector was a dynamic array in the
   sheet's arena, where the default first capacity of eight stays for good, for each compound and each selector, in
   pages touched once. The lists start at what selectors use (`COMPOUNDS_RESERVE`, `SIMPLES_RESERVE`) and `split_commas`
   counts first. p10k's sheet 6 711 -> 2 782 KB (a count, the same in every run), and what reads the rules after it
   gains too: the rebuild below moved without being touched.
3. **A rule's scratch memory goes with it** (`parse_outer_rule`, `css/parser.odin`). What a rule gathers while it is read
   (prelude, values, declarations, lists that start at eight) stayed in the sheet's scratch arena until the end: fresh
   memory for every rule, faulted in and given back. An arena of its own, emptied after each rule outside any other,
   reads and writes the same memory. Beside it: names and preprocessing have an ASCII path (a name was appended byte by byte through
   `utf8.encode_rune`), an An+B no longer goes through the formatter (`fmt` was 4 % of p10k's parsing).
4. **The rebuild mapped every node of the document to order its sheets** (`order_sheets`, `style/engine.odin`): a hash
   table of every node at each rebuild, on the window thread, for the places of a few owners. Now an array by handle
   index and a walk that ends at the last owner (usually in the head). The program alone has no document: the rebuild
   cost 1.5 ms more in the browser than alone before (5.7 against 4.17, two series), 0.1 after (3.3 against 3.16). Beside it: one walk of a
   declaration's values for viewport and container units, an index key starts with two entries, not eight. Test:
   `sheets_follow_their_owners_in_tree_order` (style).
5. **The first read of a layout was laid out twice** (`js_layout_update`, `src/browser/js_layout_shell.odin`). A page's first
   pass is forced during `run_animation_frames` (the Animation phase, which is why the report showed no full pass for it),
   and the frame's own layout then ran an incremental pass over a document nothing had changed: finish, display list and
   bands, 0.8 to 1.6 ms. `layout_stale` said why (printed for the round): the images' generation, 2 against 5 on a page with
   no image, the tab's being that of its last frame. The forced pass now notes the page's generation. Frames of a first
   paint with a second pass 1.00 -> 0.00 a load (7 runs of 14 loads, no exception).
6. **The profiler.** Each of these found the one above it:
   - A name was the nearest public symbol before the address, however far: everything the PDB has no procedure for read as
     `_extendhfsf2` (`host::pool_take` "calling" it; 7 % of the forced layout's samples). Round 17's "half-float
     conversions' calls" in `text.html` are not established: its samples of this round do not show the name. Such
     addresses are named by their source line now (`sort.odin:43`).
   - The layout pass a read forced was not recorded (`prof_layout` was called by the frame's own only), and a frame's last
     pass replaced the one before: the report said "Incremental" for p10k's only real pass. The longer pass of a frame is
     kept. The steps of a pass that does not run them keep their last values (`Layout.stats`), which is what made that
     row read as a pass of 7 ms.
   - `Sleep(1)` lasted 5 to 16 ms in a process without a window to show: the samplers wait on a high-resolution timer
     (2 651 samples in 15 s of `p10k_renav`, 16 383 in 20 s).
   - **Not solved: `WREN_SAMPLE_THREADS=1` does not see p10k's threads.** 0 of 408, 1 873 and, after what follows, 44 807
     samples running, though the parser alone runs 10 to 20 ms a load. Choosing the thread whose cycles moved most found
     each just after its burst (the counter moves when a thread leaves the processor) and each sample moved the counter of
     the thread it stopped, sleeping or not: the sampler now takes every thread that ran over a million cycles in the last
     second, and shows the threads' names. On sustained work it reads well (nodes10k: 799 of 41 217 running, the page
     thread 226 of 1 839, `place_element`, `finish`...); on bursts of a few ms still nothing, and I do not know why. So
     the brief's profile of the threads was not obtained, the timers above stand for it, and ETW (`wrentool trace`, an
     elevated prompt) is what is left to ask.

| | before | after |
|---|---|---|
| `legacy-html.html`: first contentful paint, load | 29.7 (28.6-51.3), 29.2 (28.1-50.8) | 7.4 (7.1-8.2), 7.2 (6.5-12.8) |
| p10k: DOM interactive, first contentful paint | 22.0 (19.8-22.9), 48.9 (43.5-52.6) | 18.2 (17.8-20.0), 39.7 (38.3-42.8) |
| p10k, per load (`p10k_renav`, 6 s, 7 runs): the engine's rebuild | 5.7 (5.1-6.6) | 3.3 (3.1-4.5) |
| ... the full style pass, rebuild included | 11.3 (10.1-13.6) | 8.2 (7.9-11.1) |
| ... the forced style and layout | 22.9 (20.9-28.4) | 19.5 (18.6-25.3) |
| ... the frame of its first paint, without its wait | 27.2 (26.4-37.0) | 24.0 (23.1-33.8) |
| p10k's sheet alone, parsed: Mcycles, ms (11 runs) | 23.4, 6.18 | 15.2, 4.02 |
| ... indexed (`engine_rebuild`, no document) | 15.7, 4.17 | 11.9, 3.16 |
| ... its memory | 6 711 KB | 2 782 KB |
| `shadow-dom.html`: first contentful paint, load | 14.2 (12.9-21.0), 19.3 (17.6-29.5) | 13.5 (13.1-14.8), 18.6 (17.9-20.0) |
| `index.html`: first contentful paint | 10.8 (10.0-19.4) | 10.0 (9.4-15.9) |
| `modern-css.html`: first contentful paint | 8.6 (8.2-12.4) | 7.9 (7.8-15.2) |
| `js-dom.html`: first contentful paint | 8.0 (7.2-16.0) | 8.0 (7.2-13.8) |
| `text.html`: first contentful paint | 15.8 (15.1-39.0) | 16.3 (14.7-25.7) |
| `style.html`: first contentful paint, load | 6.7 (6.1-11.7), 9.4 (8.8-15.3) | 7.4 (6.2-22.5), 10.5 (8.8-27.1) |

The first two rows and the rebuild are the gains; their ranges do not meet. The rows from `shadow-dom.html` down are inside
their ranges, no gain to claim and none lost: `style.html`'s medians are higher, with runs of 22.5 and 27.1 ms in its
range, and the series was not repeated. `text.html`'s first paint has two modes (15 and 50 to 80
ms) in both builds, on the loaded series too: a frame's slot, not looked into.

7. **Measured, not changed.** `probe_context` copies two `Computed` of 1 056 bytes for each rule (3 % of a rebuild, under
   the noise of any series here). `selector_text` serialized at parse time, 12 % of parsing: reading it from the source
   when asked would take it, against the six places that read the field. Compiling declarations on the style threads:
   what is left of the rebuild is half that, about 1.5 ms of p10k's load, for arenas per thread that live as long as the
   engine's: not tried. No change was tried and dropped this round; items 2 to 4 were built in two steps, and the program
   alone took them apart (15 runs, loaded: parsing 41.3 -> 30.6 -> 25.0 Mcycles, indexing 29.7 -> 22.1 -> 21.0).

Tests: `test_all -Quick -Only` each of the unit tests of css, style, images, layout, page and browser, "style run-time
test", "images end-to-end test" and "DOM for JavaScript end-to-end test": all pass. New: `sheet_memory_test.odin` (css:
a name's ASCII path and what it leaves to the long way, what a rule keeps once its memory is emptied, lists past their
reserve and a plain rule under 2 KB, An+B written without the formatter), the two named above. Not run: the full suite,
WPT, the unit tests under AddressSanitizer.

## What changed, round 26: heavy pages, from the navigation to the load event

Real pages took 25 to 30 s in `wrentool sweep`. The browser: development builds (`build.bat dev`, separate modules: no inlining across packages, so `string_eq`,
`pool_get` and the bounds checks show in the samples as they do not in a release), with the native library `quick`. Each load in a fresh process with a throwaway
profile, cold HTTP cache and cold bytecode cache, the engine's compiled code warm. Three arms, the order turning: base (3c15c689 and the measure of item 1), the
round's binary, and the round's binary with `network.max_streams_per_host=6`; 5 runs of each, median, range in brackets, ms from the first request. Conditions: public
sites over the Internet, one visit at a time, two other agents at work on the machine, the pages' ads and videos changing from one load to the next. What is inside these
ranges is not claimed. What depends on neither was measured on generated pages on loopback (7 runs, interleaved). The `load` of two base runs (cnn.com, css-tricks.com) is
0 in their ranges: the 30 s limit ran out first, so the base's medians there flatter it.

**The measure.** `load_ms` of the sweep was not the load: `api.navigate`, then `wait_quiet`, which takes `browser.remote.quiet_ms` (400 ms) at the least and up to 4 s on a
page that keeps a timer. example.com's 581 ms is a load of 100 ms; the Wikipedia article's 3.9 s is 0.65 s. The 25 s were real pages all the same, and the wait is now
`settle_ms`. `wrentool waterfall` (`src/tools/wrentool/capture/waterfall.odin`) gives a first load request by request: the wait for a slot, name, connection, handshake,
server, body, protocol, the time with nothing in flight, first paint, DOMContentLoaded, load, `-Idle` the time to a quiet network. The page's marks and the phases are in
`Wren.network`.

**The waterfall.** The network is not what these pages wait for. Name, connection and handshake are 20 to 100 ms a host, in parallel; HTTP/2 and 3 are used; a body is in
within 10 to 300 ms of its head. What the requests show is the window thread: a script's body in at 377 ms and seen at 2 790 ms. Its samples during the load, base: the
engine's code 47 to 68 % on vimeo.com, npr.org, css-tricks.com, bbc.com, theverge.com and spotify.com, 22 % on cnn.com; style 40 % and more on cnn.com and github.com. Of
vimeo.com's engine (the guest profiler): the interpreter's own 27 %, compilation 14 %, the collection 13 %, the rest spread out, nothing that stands alone.

1. **A host that answers over HTTP/2 or 3 has `network.max_streams_per_host` requests in flight (100)** (`Host_Slots`, `src/net/client.odin`). Six, the limit of HTTP/1.1
   connections, held the streams of one connection too; github.com's 374 requests to one host queued for 470 s in all. And a slot was given back by the window thread,
   so a busy page starved its own requests. `network.max_connections_total` 64 -> 256. A host has six until its first answer says what it speaks. Test: e2e
   `net_a_burst_goes_out_at_once_on_a_host_that_multiplexes` (twenty requests held 400 ms by the server: on HTTP/2 all leave the queue at once, on HTTP/1.1 the seventh after an answer).
2. **A classic script of another origin runs from what a compile thread made of it** (`js_run`, `src/page/js_realm.odin`). Muted errors were in the bytecode's key and the compile
   threads did not know of them: every script of a CDN over 64 KB was compiled off the window thread for nothing, waited for, then compiled on it. That is the 14 % above. Test:
   e2e `jsload_a_large_script_of_another_origin_compiles_once` (fails without the fix).
3. **Ready scripts give the loop a turn** (`scripts_pump`, `javascript.load.pump_slice_ms`, 50). The pump ran every script that was ready in one go: no frame, no network between
   them, though each is a task of its own in HTML. bbc.com was interactive at 371 ms and painted at 3.4 s. Test: e2e `jsload_ready_scripts_give_the_loop_a_turn`.
4. **The members of the exact `:has()` anchors are found by each element's keys** (`Members_Index`, `src/style/invalidation.odin`). After every full pass, on the window thread,
   every element was tested against every argument. Test: `restyle_dom_has_members_found_by_their_keys` (a hundred anchors, 300 elements: at most two tests an element).
5. **Two sets of custom properties that differ are told apart by a digest** (`Custom_Props.digest`). A variable changed high in the tree made each element under it flatten
   every name into a map, only to learn that they differ: one frame of cnn.com took 5 to 20 s, in `default_hasher_string` and `map_rehash_dynamic`. Test: `custom_properties_digest`
   (the comparison runs under an allocator that panics).
6. **A full pass keeps the classes of each element as bits of their hashes** (`class_bits_fill`, `Match_Ctx.class_bits`, `css.Simple.hash`). Most selectors tried on an element name
   a class it does not have, and each try read its attribute through. `has_class` 5 % -> 1.4 % of cnn.com's samples, a full pass there 286 ms in the base, 140 after item 4, 120
   after this (three single runs of the profile build). Test: `class_bits_of_a_full_pass`.

Loopback (`load`, and `paint` where it is the point; 7 runs):

| | before | after |
|---|---|---|
| twelve scripts of 100 ms behind a sheet of 150 ms: first paint | 1 222 (1 215-1 232) | 322 (316-332) |
| ... load | 1 224 (1 217-1 235) | 1 235 (1 226-1 256) |
| 8 000 elements with a layer of their own under 400 variables, one changed four times | 7 781 (6 482-9 355) | 259 (164-1 650) |
| 300 `:has()` rules, 8 000 elements, ten full passes | 1 396 (1 108-1 664) | 267 (192-285) |
| a bundle of 3.1 MB of another origin | 2 770 (2 419-3 582) | 1 561 (1 441-2 136) |

Public pages, first paint and load (ms):

| | paint before | paint after | paint, 6 streams | load before | load after | load, 6 streams |
|---|---|---|---|---|---|---|
| cnn.com | 8 774 (6 526-10 935) | 5 037 (1 407-5 271) | 4 989 (1 563-5 833) | 19 921 (0-29 888) | 11 133 (9 735-23 279) | 11 138 (9 457-19 969) |
| npr.org | 2 532 (1 346-4 683) | 1 245 (1 085-1 590) | 1 428 (1 187-1 599) | 23 351 (19 908-25 830) | 21 175 (19 456-21 811) | 20 584 (17 630-22 390) |
| vimeo.com | 6 882 (5 987-7 193) | 1 740 (817-6 380) | 1 688 (822-6 228) | 11 387 (9 834-13 153) | 10 381 (8 522-12 156) | 10 195 (8 620-13 647) |
| theverge.com | 3 586 (1 138-5 734) | 1 381 (1 099-1 665) | 1 177 (908-5 197) | 14 147 (13 584-14 632) | 14 337 (12 758-14 412) | 13 476 (12 810-13 824) |
| css-tricks.com, flexbox | 1 978 (1 810-2 211) | 1 058 (846-1 586) | 1 870 (1 233-2 142) | 13 732 (0-16 358) | **21 802 (19 183-23 091)** | 12 277 (8 548-12 807) |
| youtube.com | 577 (376-1 121) | 407 (-203-660) | 429 (28-489) | 6 677 (4 762-7 313) | 6 628 (4 886-8 259) | 5 715 (4 515-8 773) |
| bbc.com/news/technology | 4 963 (4 578-8 787) | 1 279 (1 201-2 652) | 4 316 (1 449-5 284) | 11 039 (8 510-15 160) | 9 739 (7 892-12 396) | 9 245 (7 608-10 561) |
| twitch.tv | 2 039 (1 191-4 045) | 1 384 (1 190-2 062) | 1 365 (1 124-3 757) | 3 872 (2 025-4 142) | 2 292 (1 849-4 374) | 2 481 (1 968-4 016) |
| open.spotify.com | 1 220 (1 161-2 802) | 1 222 (1 169-2 656) | 1 202 (1 158-1 215) | 6 951 (6 649-14 531) | 5 237 (4 601-7 354) | 4 504 (4 013-7 253) |
| microsoft.com | 776 (660-1 282) | 933 (864-1 443) | 741 (601-1 091) | 5 931 (5 732-7 503) | 5 761 (5 477-6 519) | 6 193 (5 919-6 819) |
| github.com, issues | 1 419 (1 307-1 650) | 1 108 (921-1 857) | 1 282 (1 059-1 380) | 5 795 (4 717-6 624) | 4 854 (3 578-5 096) | 5 091 (4 744-6 316) |
| en.wikipedia.org, an article | 372 (321-528) | 403 (330-408) | 340 (333-2 232) | 651 (561-967) | 672 (621-749) | 624 (580-2 907) |
| example.com | 82 (66-95) | 84 (73-109) | 74 (67-84) | 122 (111-140) | 128 (108-152) | 113 (104-127) |
| mean of the eleven heavy pages | 3 159 | 1 527 | 1 862 | 11 164 | 10 304 | 9 173 |

Beside them, the longest wait for a slot: vimeo.com 5 384 -> 472 ms, github.com 3 738 -> 422, css-tricks.com 4 262 -> 370, microsoft.com 1 658 -> 93, theverge.com 1 026 -> 21.

Read plainly: the first paint is the gain, halved on the mean. Its ranges separate on cnn.com, bbc.com and css-tricks.com; vimeo.com, npr.org and theverge.com gain by their medians,
their ranges meeting (vimeo.com: one run in five stays at 6 s). The load moved far less. Its ranges separate on none of these but css-tricks.com, the wrong way; twitch.tv, spotify.com and cnn.com are better by their medians.
What is left of these loads is the engine running the pages' scripts. cnn.com's first paint has two modes, 1.4 and 5 s, not looked into.

**What got worse.**
- **css-tricks.com: 13.7 -> 21.8 s to its load event, 226 -> 340 requests, CPU 30 -> 40 s, measured with item 1: not its cost, a bug it hid less.** The built-in stack took a `103 Early Hints` for the
  response over HTTP/3, an empty one: the embed stayed blank, and its frames and scripts never came. With six streams twelve of the page's twenty-three embeds got one, with a hundred one (codepen.io answers 103
  while its origin is slow, so the order of the requests decides). The six streams were quicker for doing less. Fixed (`h3conn.rs`), the two arms are the same, 19.3 and 18.4 s to quiet, 350 and 343 requests, 42 frames
  each: what the page asks for, 38 s of CPU of twenty-three embeds.
- **DOMContentLoaded** comes later on theverge.com (1 603 -> 3 679), github.com (3 452 -> 4 537) and npr.org (8 656 -> 10 897): frames run between the scripts now.
- theverge.com's CPU 23.8 -> 29.0 s, from item 1 (6 streams 23.4 s), for the same load.

**Against Edge.** Headless Edge through the DevTools protocol, a fresh profile a load, Wren's user agent. Two series gave very different numbers, the machine's load being what it was:
load 1.4 and 2.4 s on cnn.com (1 and 3 runs), 1.6 and 3.3 npr.org, 2.0 and 2.9 vimeo.com, 2.2 and 7.6 theverge.com, 1.6 and 7.1 css-tricks.com, 0.7 and 2.5 bbc.com, 1.8 and 17.8 spotify.com,
1.4 and 5.3 github.com, 0.4 and 1.7 Wikipedia. Those series ran on other minutes than Wren's, so only the order of magnitude counts: a page is not slow on the network for Edge, and Wren is
behind by a factor of 2 to 13 on the load where scripts dominate, on a par on what has few. First paint: Edge 0.35 to 1.1 s in the first series, Wren 0.4 to 1.7 now, cnn.com aside. Edge's request
counts leave out the frames of other sites, which run in other processes: they do not compare.

7. **Measured, not kept.**
   - **The engine at `-o:speed`** (the image is `-o:size`, for its size budget, not for speed, and nothing said what that cost): 9.4 against 7.5 MB, and **slower**: 2.1 times on `macro.js`'s geometric mean,
     2.9 on `realworld.js`, 5 to 18 times on what calls (`arguments`, closures, `class`, getters), 0.37 on `forEach`. Not looked into; large frames of the interpreter are the guess.
   - **`browser.shell.preempt=false`**: `NtUserGetQueueStatus` is 4 to 7 % of these samples; off, vimeo.com 11.6 -> 10.6 s, css-tricks.com 19.3 -> 18.8 s, 5 runs, ranges inside each other. Round 1's bias of samples in a system call.

**The profiler.** `WREN_SAMPLE_STACK=1` and `WREN_SAMPLE_THREADS=1` end the browser on cnn.com (`Page.navigate: the connection to Wren ended`), with `WREN_SAMPLE=1` alone it runs. Not looked into: so the
callers of `has_class` are inferred, item 4's from what the fix took away, and what the style threads do is not known.

Tests: `test_all -Quick -NoAsan` with `build/native` copied with its stamp (no Cargo): the unit tests of host, dom, css, html, fetch, style, page, browser and remote, the end-to-end tests of JavaScript
loading, pages, the DOM, nested documents, images, the HTTP cache, network policy, the transport on both stacks, the content blocker, site compatibility and the remote channel, the changelog and the site: all pass. New: the
six named above. Not run: the full suite, WPT, the unit tests under AddressSanitizer.
## What changed, round 27: memory, what a long session on many sites keeps

The numbers of `wrentool sweep`: example.com 190 MB of private bytes, a Wikipedia article 500 MB, cnn.com 2 GB, 4.7 GB (6.4 on another day) after 37 sites in one process.
Repeated open and close of one site settled near 300 MB: what was kept was kept per site. Headless, development builds, RTX 4070 SUPER, 16 logical processors, other agents building
beside it (a third of the machine at one reading); throwaway profiles; every site visited through `wrentool sweep -OneProcess`, one visit at a time.

**The measure.** `Wren.stats` has `memory`, the heaps and private pages against what each store says it holds; `Wren.memoryReport` writes the allocations by kind (a heap's segment, a
thread's stack from its TEB, a Wasm memory by its 4 GiB reservation, code); `wrentool sweep` writes `memory_<shard>.tsv` after each page, and with `-MemoryReports` a report before and after
`Wren.memoryTrim`. The check build's `.live` file names the tracked blocks by place. For what those do not see, a throwaway build hooked `NtAllocateVirtualMemory` and kept the call stack of
each commit: not committed.

**Where it was**, in MB, one tab, after the 16th site (the Guardian), before and after items 1, 3 to 7 below; then after the 21st site (the Verge) with all of them, a trim just made. Before, the style arenas are in the first line:

| | before | after | 21st site, final code |
|---|---|---|---|
| private bytes | 2 419 | 1 364 | 2 928 |
| Wasm linear memories (realms of pages and frames) | 892 | 221 | 1 401 |
| process heaps | 729 | 473 | 834 |
| mapped by the kernel for the GPU driver, sheets' arenas, the rest | 630 | 467 | 454 |
| style arenas | | 69 | 59 |
| compiled code | 76 | 36 | 40 |
| thread stacks | 10 | 10 | 11 |

Of the heaps after 11 sites (check build, 581 MB in use): 259 MB tracked (HTTP bodies 35, bytecode 22, layout arrays 76, decoded images 27, media 25, web fonts 18), 84 MB of temporary arenas,
the rest native (Wasmtime's modules and stores, Lexbor, the decoders, DirectWrite).

example.com, 190 MB: 65 MB of regions no `NtAllocateVirtualMemory` of the process made: they are the GPU driver's, mapped by the kernel (instance buffers and uploads are what they contain), 30 MB
of the driver's own writable image sections, 19 MB the engine's code, 30 MB of heaps once the temporary arenas are small (72 KB per thread of `font.l1_words` in thread-local storage: 7 MB
over the 96 threads, of which 68 are the driver's), 6.5 MB of realm, 7 MB of stacks.

**What was wrong, by bytes.**

1. *The back/forward cache counted a realm for 8 MB* (`history.bfcache.page_overhead`). A news site's is 136 MB: five such pages were "under" the 512 MB limit, and 21 instances lived after 15 sites.
   `page.memory_held` now reads the linear memories of the page and of its frames, nodes count 4 KiB (a page of 10 000 nodes takes 50 MB), the limit is 128 MB. A page kept gives back the style arenas
   and the layout arrays only its next pass would use.
2. *A layout kept its arrays from one document to the next*: fragments, lines, segments, sized by the largest page the tab showed: 300 MB after lemonde.fr, carried to every page after it. Past
   1 MiB an array goes at the new document (`LAYOUT_KEEP_BYTES`); the first pass sizes them from the document anyway.
3. *Compiled modules were counted by their code alone*: 14 KB of code took 40 KB of private bytes. The JIT made 12 000 of them in 37 sites, all kept. `MODULE_BYTES` counts the rest, the
   limit is 64 MB; what is evicted comes back from the disk cache.
4. *Caches sized for one big page, kept for the session*: decoded images 512 -> 128 MB, bytecode 64 -> 32, HTTP bodies 64 -> 32 (the last two are on disk).
5. *The key sets of style invalidation were process-wide, never freed*: tens of MB after a few dozen sites, and a table no page could give back. They belong to the engine now.
6. *Temporary arenas*: every thread that used one kept 1 MiB, 84 blocks after a few sites. 64 KiB now, 1 MiB for the threads of a frame's passes (`host.thread_temp_hot`). The page thread's kept the
   size of the largest page laid out (42 MB): a trim takes it back to its first size.
7. *A trim came only when idle*: never with an animation on screen. A closed tab or a kept page gone asks for one within a second, at most every 10 s (`memory_trim_soon`).

**The result.** `wrentool sweep -OneProcess` on the same 37 sites, private MB after each, one run of each (one tab; the session ends on apple.com):

| site | before | after |
|---|---|---|
| 1 example.com | 192 | 182 |
| 5 python.org | 862 | 531 |
| 10 react.dev | 1 720 | 969 |
| 15 bbc.com/news | 3 068 | 1 316 |
| 20 arstechnica.com | 3 544 | 1 864 |
| 22 cnn.com | 4 701 | 2 777 |
| 25 old.reddit.com | 4 507 | 2 211 |
| 30 gitlab.com/explore | 4 442 | 2 495 |
| 34 bing.com | 4 694 | 2 454 |
| 37 apple.com | 4 732 | 2 951 |

Heap in use 1 054 -> 578 MB, compiled modules 11 999 -> 960, images 330 -> 120 MB, at the end. From the 22nd site on the session goes up and down with the page shown, between 2.2 and 2.9 GB.
What it follows now is the sites' own memory: the Verge's frames and workers hold 24 linear memories, 1.4 GB, while it is open. All 37 pages passed, no crash, no hang.

Each site alone in a Wren of its own, two runs of each, private MB: example.com 192, 189 -> 173, 188; the Wikipedia article 426, 409 -> 426, 345; lemonde.fr 1 082, 983 -> 759, 748; cnn.com 1 865, 1 647 ->
2 099, 1 479 (cnn differs by 600 MB from one visit to the next: its adverts). So a single page changes little: **example.com is not far lower**, the target was not reached there, see below.

A local session (`examples/site/memory-growth.html`, 40 pages unlike each other, 40 modules each): 402 -> 334 MB at the end, compiled modules 1 740 -> 1 002 and no more from the 30th page.

Speed: `wrentool bench perf -Only js_nodes10k`, development builds, base and final in turn, 6 of each on the loaded machine: load 350 against 353 ms (median), frames as many in the same time within their
scatter (553 to 658, 549 to 616), private bytes 245 -> 233 MB. `p10k_load`, 4 of each: 797 to 2 152 ms against 582 to 1 309, no difference this machine could show. What a limit costs: a page evicted from the back/forward cache loads again instead of coming back at once, more often than before (the price of
128 MB: two or three pages of news sites are kept instead of six); a module evicted is read from the disk cache instead of memory; a reload of a large page sizes its arrays again, as its first pass did.

**What is left**, and why. The GPU driver's memory (65 MB at the start, 200 to 300 MB in a session) is mapped by the kernel; it stays after `IDXGIDevice3::Trim`, with or without `ClearState`, and `text.renderer=atlas` changes
little (77 -> 64 MB on the local pages). Whether a shown window, whose presents throttle the frames, keeps as much was not measured. `font.l1_words` (7 MB of thread-local storage) and the 68 threads are in the toolkit and the driver.
The sheets' 1 MiB arena blocks and the heap's native part (Wasmtime's stores, Lexbor) were not taken apart further. example.com stays near 180 MB because of those: about 95 MB of it is the driver's.

Tests: `src/tools/e2e/memory_growth.odin`, on a local page: the back/forward cache counts what the scripts of its pages hold (fails without: 5 pages of 24 MB in 64 MB), compiled modules stay within their limit (fails
without: 367 kept for at most 150), a tab forgets the size of a large page (fails without: 101 MB carried), a long session levels off, closing tabs gives their memory back.

## What changed, round 28: pages get going earlier during load

The browser: development builds with the native library `quick`. Two arms, the order turning at each run: base (7f692633 with the `contentful` mark added and nothing else) and the round's binary (cb1e93d1), one load at a time, a fresh process and a throwaway profile each, cold caches.
Median, range in brackets, ms from the first request. Conditions: public sites over the Internet, 5 runs, two other agents at work on the machine, ads and videos changing from one load to the next; generated pages on loopback, 7 runs. A `load` of 0 in a range is a run the 30 s limit ended (6 of 20 base runs, 5 of 20 of the round's, all sites together), and those zeros count in the medians of both arms. What is inside the ranges is not claimed.

**The measure.** `paint` counts a blank frame: when a hold ends with nothing to show, the document is "painted". `wrentool waterfall` now has `contentful`, the first frame with text, an image or a control (`layout_contentful`).

1. **A document's requests leave while its bytes arrive** (`src/html/preload_scan.odin`, `src/page/preload_scan.odin`, `src/fetch/speculative.odin`, `html.preload.*`). A tokenizer over the raw bytes keeps the states that decide where a tag is a tag (comments, raw text, the escaped states of a script's text, `<template>`, foreign content) and reads what the bytes name; requests are made with what the element would ask (base URL, `crossorigin`, media, `referrerpolicy`, nonce). On the window thread: all of cnn.com's 6.8 MB is a matter of milliseconds and a request can only be made there. A `<meta>` Content-Security-Policy stops the scan; the response's policy refuses silently, the element reports.
   Reuse is in `fetch.start`: a request of the same document with the same URL, destination, mode, credentials and script type (HTML's preload key) follows the entry made ahead, gets what it has and the rest as it comes. No consumer changed, each follower goes through the policy with its own nonce, integrity stays with the element, and the tools see one row. A `<link rel=preload>` follows without consuming, for the element that may have asked first.
   cnn.com's first subresource request: 454 ms, the next ones 1 314, against 129 (one run each). **github.com: 260 requests -> 177**, the same in every run: 83 scripts were fetched twice, their `<link rel=modulepreload>` and their element, the cache keeping neither in flight. No URL of the base is missing in the round's list (one run compared).
   An `<img>` now resolves against `<base href>`: `select_source` used the document's URL.
   Tests: e2e `jsload_preload_scanner_asks_ahead_and_the_elements_take_the_requests` (one server hit each, in flight and already in), `..._leaves_alone_what_is_not_markup`, `..._honours_the_document_s_policies`, `a_document_s_requests_leave_while_its_end_is_held` (the real shell: the server holds the end of the document until it sees the request), `preload_scan_*` (every cut of the bytes).
2. **A sheet that arrives restyles what it matches** (`src/style/sheet_arrival.odin`, `style.incremental.sheets`). Its rules join the index as it stands, numbered in its place (rules of a sheet start `SHEET_ORDER_GAP` after the last one's: a sheet that comes between two has room), the invalidation index grows by them, and the elements go through an index of the sheet's own keys, the cascade's lookups on its entries alone; `restyle_roots` does the rest. On cnn.com a sheet that came took about 250 ms, rebuild and full pass; now 2 ms for the rules, 8 to 15 for the elements. Most of the 250 was not the pass (100 ms) but the rebuild and the invalidation index, built again from every rule (160 ms), which is why it had to grow too.
   Also: `insertRule` at the end of a sheet is an arrival (143 calls on cnn.com, each a rebuild); a `<link>` inserted, or read back by `.sheet`, no longer marks the styles stale; a sheet whose element the parser's reveal brings back where it was needs no rebuild (held sheets sort last, where they are in the document).
   A rebuild and full pass stay for `@layer`, `@property`, `@position-try`, `@import`, `::part()`, `::slotted()`, `:host`, `@keyframes` of a name in use, adopted sheets, a sheet removed or changed, and a sheet that matches more than `style.incremental.max_ratio` of the document.
   Test of the equivalence: `sheets_that_arrive_in_any_order_give_a_full_pass_s_styles`: four sheets in four orders, after each one every element against a full pass of an engine of its own that had them from the start, and against `verify_styles`. Others: `a_sheet_that_arrives_restyles_what_it_matches` (one element changes, at most three looked at), `a_rule_inserted_at_the_end_of_a_sheet_arrives_like_a_sheet`, `sheets_that_reach_further_keep_the_rebuild`.
3. **cnn.com's two modes of first paint, explained and gone.** Its body ends with an inline script of 3.7 s. The document is revealed in 50 ms up to it: whether a frame came before that script or after it was the whole difference, and the frame of the quick mode was blank (`contentful` is over 5 s in both). So: the parser stops before a script when what it attached can paint, nothing holds it back, and at least `REVEAL_TURN_MIN_NODES` were attached, for `javascript.load.paint_wait_ms` (24), three times at most. It also gives the loop a turn between inline scripts (`reveal_run`'s budget), which it never did: they were one task.
   Tests: `jsload_the_first_paint_comes_before_the_next_script`, `jsload_the_parser_gives_the_loop_a_turn`.
4. **Frames between scripts in proportion to what they cost** (`javascript.load.slice_per_frame`, 3): once a page painted, scripts and the parser run at least three times what its last frame took before the loop gets a turn. That is round 26's later DOMContentLoaded: a slice of 50 ms between frames of 200. Test: `jsload_the_turns_follow_what_the_page_s_frames_cost`.
5. **The marking stops when a full pass is shorter** (`restyle_dom`). Found by item 3, which made it common: 8 400 nodes attached between two passes, under `:has()` anchors, 114 000 answers, 8.7 s, to end in "too much changed" and a full pass of 0.2 s. It made `load` bimodal, 16 and 32 s. The elements alone were under the limit, among the parser's text nodes: a journal longer than the limit now goes straight to the full pass, and the answers have a limit. Test: `restyle_dom_stops_marking_when_a_full_pass_is_shorter`.

Loopback:

| | before | after |
|---|---|---|
| a document held 400 ms, two sheets and six scripts of 150 ms in its head: load | 1 040 (785-7 717) | 574 (428-1 286) |
| 2 000 paragraphs, then an inline script of 1.5 s: contentful | 1 532 (1 527-1 830) | 27 (23-106) |
| ... load | 1 519 (1 516-1 794) | 1 554 (1 548-1 650) |
| 20 000 alike elements, fifteen sheets that come one by one: quiet network | 3 378 (3 331-7 866) | 3 975 (3 393-5 559) |
| ... CPU | 406 (312-1 531) | 969 (594-1 500) |
| ... contentful | 233 (199-4 047) | 571 (187-1 731) |

Public pages:

| | contentful before | after | DOMContentLoaded before | after | load before | after | CPU before | after |
|---|---|---|---|---|---|---|---|---|
| cnn.com | 7 338 (5 692-16 263) | 1 026 (678-12 403) | 7 762 (4 116-21 785) | 5 072 (3 978-26 131) | 14 892 (0-28 954) | 10 436 (0-16 655) | 24 953 (17 078-40 156) | 22 047 (17 734-34 344) |
| npr.org | 2 373 (1 045-12 620) | 3 153 (2 093-4 966) | 14 175 (8 537-20 975) | 11 316 (8 136-16 698) | 15 269 (0-29 658) | 15 834 (0-30 927) | 25 078 (19 359-37 859) | 19 953 (19 188-34 641) |
| github.com | 3 069 (1 260-4 030) | 2 386 (1 375-4 932) | 8 335 (2 598-10 587) | 5 107 (2 257-12 620) | 9 099 (2 599-11 412) | 5 109 (2 259-12 630) | 11 438 (6 859-17 969) | 8 578 (5 984-16 219) |
| theverge.com | 1 520 (1 028-3 491) | 1 335 (852-2 707) | 5 343 (1 081-11 642) | 4 086 (1 159-6 724) | 8 697 (0-17 140) | 8 938 (0-24 606) | 23 031 (16 094-37 734) | 27 453 (15 750-36 766) |

cnn.com alone, the round's binary with one part off, 5 runs:

| | contentful | DOMContentLoaded | load | CPU |
|---|---|---|---|---|
| the round | 1 026 (678-12 403) | 5 072 (3 978-26 131) | 10 436 (0-16 655) | 22 047 (17 734-34 344) |
| `html.preload.enabled=false` | 949 (739-14 458) | 4 477 (3 975-27 213) | 9 155 (0-19 135) | 17 328 (14 734-28 656) |
| `style.incremental.sheets=false` | 903 (791-5 435) | 6 553 (4 265-16 979) | 10 813 (0-17 850) | 20 922 (16 312-36 109) |

Read plainly. **One thing is out of the noise on public pages: cnn.com's contentful paint**, 7.3 -> 1.0 s by the median, though one run in five still took 12 s; its ranges do not separate because of that run. The request counts of github.com are exact. **DOMContentLoaded is better by its median on all four, 20 to 39 %, and its ranges meet on all four**: round 26's loss looks recovered, it is not proved. Load: better by the median on cnn.com and github.com, unchanged on npr.org and theverge.com, ranges meeting everywhere. The two halves of the title do not show on cnn.com's load: with the scanner off, or the sheets, the medians stay inside each other's ranges. What decides there is still the engine running the pages' scripts. On loopback the scanner and the first paint are clear.

**What got worse.**
- **npr.org's contentful, 2 373 -> 3 153**, ranges meeting; not looked into.
- **A page of alike elements**: the generated page's CPU is more than double, its contentful later. A full pass there is nearly free (the elements share their styles), and walking 40 000 elements for each sheet, on one thread, fifteen times, is not (the likely reason, from what a sheet costs on cnn.com; not profiled). Contentful at 571 rather than 233: the guess is that the script after the paint turn changes the document under a layout on the page thread, which is then made again. Not verified.
- The long script's page: load 35 ms later, what its first frame costs.
- theverge.com's CPU 23.0 -> 27.5 s, inside the ranges.

**Not kept / left.** `too much changed` is now most of cnn.com's full passes, 17 of 31 in one load: an element inserted near the top of the body, a sibling combinator, 3 900 elements marked of 10 800; about 2 s a load. Partial passes of 0.5 to 1 s after DOM changes (`restyle_dom`), which cost more than the full pass they avoid: `has_flip_scan` takes 12 to 150 microseconds an answer, it reads what was added. The body of a sheet that arrives early waits for its element to be parsed off the window thread; the same for a script's compilation. A sheet with `@import` still makes a full pass, and so does its import; `insertRule` before the end too, and the removal of a sheet. Images of `srcset` are chosen with a root font size of 16.

Tests: `test_all -Quick -NoAsan` on the unit tests of html, fetch, page, style and browser, the end-to-end tests of pages, JavaScript loading, the web APIs, nested documents, the HTTP cache, the content blocker, site compatibility and fonts: all pass but one step. **`a_drag_selects_while_the_page_is_busy` fails on its own 6 times in 6 with the base binary as with this one**, and sometimes passes beside other tests: marked `.Flaky`, not looked into. WPT: `html/semantics/scripting-1`, `custom-elements`, `css/cssom`: 0 regressions, 4 improvements. The WPT runner parses as `src/tools/headless` does, without the scanner: it covers the reveal and the styles, not item 1. Not run: the full suite, the unit tests under AddressSanitizer. **The equivalence of item 2 is tested on generated documents only**: the one run with `style.incremental.verify` on cnn.com hit the 30 s limit before any sheet took the scoped path. The public arms are of cb1e93d1; the commit after it gives a document's first script the same turn (the 27 ms above) and was measured on loopback only.
## What changed, round 29: the JIT reaches what real pages run

Item 1 of the list after round 26: the engine's share of heavy pages. Development builds, the native library `quick`; each load in a fresh process with a throwaway profile (`wrentool waterfall -Idle`), the base (7f692633) and the
round's binary in turn, the order turning, 5 runs of each, median, range in brackets, ms. Public sites, one visit at a time, two other agents at work on the machine, the pages' ads and variants changing from one load to the next (vimeo.com's first paint has two
modes, 1.3 and 5 s, that come and go by the quarter of an hour). What is inside these ranges is not claimed.

**The measure.** The guest profiler (`jspage -image <engine built with buildjs -names> -profile`) gives each sample the time since the last one, and a page that waits gives one sample tens of seconds: css-tricks.com read 94 % in the bytecode verifier, theverge.com 16 % in
`str_eq`, on one sample each. Counted by samples they are nothing: 25 % `interp_run` on every page, 10 to 13 % the collection, 6 to 19 % `frontend_compile`, the rest spread out. What says more is where the interpreter is: **`WREN_JS_PROFILE` now ends with what the JIT said**
(each refusal, each deopt, what it left to the interpreter's code, translations, Cranelift's time), and at each interrupt check why the code it is in is not compiled (`jit_note_sample`; `jsengine run -jit -jit-trace` the same). Interrupt checks
count calls and iterations, not time, but of those, before this round:

| | npr.org | vimeo.com | theverge.com |
|---|---|---|---|
| `op_catch` (a `try` in the loop) | 63 % | 5 % | 1 % |
| given up after 16 deopts | 15 % | 69 % | 26 % |
| `fclosure8` | 11 % | | 16 % |
| a call of a function not compiled whole | 2 % | 1 % | 12 % |
| for-of, for-in (an entry under the loop's) | 1 % | 10 % | 8 % |
| too many sites, typeof, instanceof, a nested loop, other refusals | 5 % | 4 % | 20 % |
| being compiled | 1 % | 6 % | 1 % |
| a function called little | 2 % | 2 % | 4 % |
| compiled | 1 % | 1 % | 10 % |

So **almost nothing that runs often was compiled**: one instruction the translation did not know, anywhere in a function, kept all of it interpreted, and sixteen deopts in a whole life gave a function up. "Why does code stay in the interpreter" was the question of the task, and "cold code" was not the answer.
npr.org's 56 % is one function, OneTrust's `OtAutoBlock.js`: 2 500 block-list entries tried against each node a page adds, with a `try` in the loop; its own copy in `build`: 6.3 -> 2.8 ms a call (Node 0.38), 5 runs of each.

1. **No instruction keeps a region from being compiled** (`jit_insn_or_slow`, `j_slow_op`, `jit_step`). What the translation cannot do is taken back and made by the interpreter's own code from the compiled code (`interp_run` for one instruction on the frame, the stack written first, the results back as values); what cannot be made alone (`throw`, a `gosub`) is where the code leaves. An exception stays pending (`JIT_AUX_PENDING`). `op_catch` is translated.
2. **A site that keeps missing goes through the engine's code** (`Jit_Site.slow`): more shapes or callees than a site takes, an element outside the array. A call of anything goes through the helper (`j_call_any`). A region is given up for the share of its entries that deopt (`JIT_DEOPT_SHARE`), not after sixteen.
3. **Functions with loops are compiled whole, nested loops with them** (`Jc.inner`, a `br_table` at the top of the code). A loop dropped for its few iterations makes the function around it hot.
4. **The first runs are recorded** (`jit_record`, `Frame.recording`). At the threshold two calls (four iterations of a loop) run in the full dispatch, their sites filled from the operands. Each site met was an exit and a translation of the whole region, and `JIT_MAX_LEARNS` came first. Blocks the recorded runs did not reach are not compiled (`Jit_Loop.hit`, a `cold` exit), and sites live in a list of their own: the record of a loop was 2.5 KB.
5. **`javascript.jit.call_threshold` 500 -> 2 000.** All this costs: theverge.com translated 2 162 regions into 14 MB of Wasm for 299 KB of bytecode, 24 s of Cranelift on the two compile threads (2 us a byte). A module of 4.5 KB costs 8 ms and saves perhaps 0.5 us a call. Blocks not compiled took 14 to 10.5 MB; the threshold took npr.org's CPU 32.8 -> 23.3 s, theverge.com's 38.1 -> 36.6 s (3 runs, ranges meeting), nothing visible on the loads. 8 000 was no better.
6. **`indexOf`, `includes`, `split`, `replace` search by width** (`units_index_of`: `str_at` tested the width at each unit) and a `replace` of one match without `$` makes its result at once. 5 % of npr.org's samples. Test: `judge capi` (each width against each).
7. **The sweep walks the heap once.** It walked every cell a first time to find the shapes and their weak transitions: the marking lists them now (`gc_shapes`). Test: `judge capi`.

Where the interpreter is after the round (the same counts; `compiled` is the budget exits of compiled code): npr.org 89 % compiled, vimeo.com 72 %, theverge.com 74 %, nothing refused; 4 to 10 % being compiled, 2 to 4 % in functions called little. Samples of the engine in the first 25 s of a load: npr.org 2 635 -> 1 378, vimeo.com 2 923 -> 972, theverge.com 2 693 -> 1 299 (single runs, before item 5; the same page does more in 25 s now, and one later run of theverge.com gave 3 396, so the order of magnitude only).

Public pages, base and round (ms):

| | paint before | paint after | load before | load after | quiet before | quiet after | CPU before | CPU after |
|---|---|---|---|---|---|---|---|---|
| npr.org | 1 047 (857-2 268) | 1 974 (1 595-2 210) | 12 165 (10 089-14 320) | 10 541 (8 518-11 069) | 20 193 (19 090-21 176) | 18 478 (17 845-19 162) | 25 250 (18 734-29 766) | 26 000 (15 359-27 391) |
| vimeo.com | 1 301 (1 247-1 397) | 1 782 (1 266-3 508) | 6 355 (5 592-7 096) | 6 519 (5 796-8 718) | 19 276 (7 868-28 333) | 9 613 (7 629-10 619) | 16 641 (10 219-18 703) | 19 734 (13 578-20 031) |
| theverge.com | 1 125 (1 068-1 175) | 1 108 (565-1 256) | 10 202 (9 310-11 499) | 11 196 (10 521-15 150) | 11 131 (10 819-20 653) | 14 058 (11 705-60 351) | 25 359 (17 359-27 297) | 36 047 (35 531-48 172) |
| bbc.com/news/technology | 971 (808-1 139) | 939 (775-1 222) | 4 573 (1 178-6 609) | 5 021 (1 106-5 841) | 6 036 (3 686-7 274) | 6 268 (6 028-6 693) | 11 266 (2 922-13 844) | 14 766 (8 750-17 078) |
| css-tricks.com, flexbox | 1 398 (1 154-1 585) | 1 091 (989-1 461) | 17 612 (16 762-17 993) | 17 504 (16 871-32 100) | 18 334 (17 374-18 655) | 18 287 (17 530-32 591) | 38 641 (36 297-41 141) | 51 203 (47 234-75 672) |
| open.spotify.com (4 runs) | 1 144 (1 134-1 154) | 1 160 (1 131-1 165) | 2 261 (2 075-2 449) | 2 373 (2 259-2 476) | 12 836 (9 776-13 486) | 13 798 (10 275-13 911) | 5 234 (3 672-6 562) | 5 500 (5 000-6 344) |

Read plainly: **the loads hardly moved, and the CPU went up.** The engine does the same work in about half the samples, but of these six the ranges of the load event separate on none; npr.org gains by its medians (load -13 %, quiet -8 %, ranges just meeting), vimeo.com's quiet time is the one large move and it is the page's own (175 requests in the base's median run, 110 in the round's: which ads came). theverge.com is worse by its medians (load +10 %, ranges meeting), its CPU +42 %, with separate ranges; css-tricks.com's CPU +33 %, separate too; both are Cranelift on the compile threads (theverge.com: 3 271 translations, 15 MB of modules, 13.7 s in that run), 23 embeds on css-tricks.com each compiling the same code in a realm of its own. npr.org's first paint is later in this series (ranges meeting) and was not in the two before it (1 741 against 2 006, 1 916 against 2 205). The machine was quiet this time: the base took 10 to 12 s on npr.org where round 26 had 21. So on a quiet machine the load of these pages is not held by the engine's speed the way the window thread's share suggested: what holds it (chains of requests, timers, what is not the engine on that thread) is what the next measure must say.

**Measured, not kept.**
- **The engine at `-o:speed`, why it is slower**: not much is. `realworld.js`, interpreted, 1 run of each, under load: 20 to 58 % slower where the interpreter runs (`interp_run` 68 % of the samples: it is the procedure the code generator's choices hurt, as in round 13), JSON the same (2 853 -> 2 808 ns). Nothing else in the engine gained enough to pay for a mixed build.
- The first version of this round compiled at 500 calls: CPU 28 s on npr.org, 42 on theverge.com, 19 on bbc.com (base 24, 30, 6): item 5.

**What got worse.** CPU, above. `macro.js` interpreted (`jsengine run`, no JIT, 3 runs of each image in turn): geometric mean 0.90 of the base over 29 cases, 1.03 in an earlier series under load: inside the noise, one case at 1.57 (`regexp exec global loop`), 0.83 to 1.28 in the other series. The interpreter pays one read of the frame per instruction of the full dispatch and two per return to it.

**Not verified.** Memory: more modules per page, up to `javascript.jit.max_functions`, not measured against round 27's tests of a long session (they were not run). The full suite, WPT, AddressSanitizer: not run. The release build: not measured. Compile time of the engine: 5 to 10 min today against 2.5 min for the first build of the day, on a machine that was busy: three changes reverted one by one did not explain it, the load may. Not settled.

Tests: `jsengine reach examples/jsbench/jitreach.js` in the step of test262 with the JIT (what stayed interpreted: nothing refused, four checks in five in compiled code; the base fails), 25 new cases in `jitcheck.js`, also under `JSRT_GC_STRESS=8192` and `JSRT_GC_POISON`, `judge capi`, test262 quick with and without the JIT (no regression), the end-to-end tests of JavaScript in pages, its loading and its web APIs.

## What changed, round 30: what holds a first load, measured task by task

The first item of the list after round 29. Edge loads theverge.com in 1.8 s, npr.org in 1.3, cnn.com in 1.1, bbc.com/news in 0.5; Wren took 3 to 8. Development builds, the native library `quick`, a quiet machine, `wrentool waterfall`, each load in a fresh process with a throwaway profile, arms interleaved, the order turning; public sites, whose ads change.

**The measure.** `WREN_SPANS=<prefix>` (`base/spans.odin`): every task of the loop by who posted it, the frame's phases, each script's run and life (request, last byte, bytecode, turn), each outermost call into the engine, imports over 20 us, and from the engine (`Engine_span`) compiling, reading bytecode, collecting, translating; written as a table of nested spans at the end of the process. `WREN_JS_PROFILE_TIME=1` makes `WREN_JS_PROFILE` sample by time: a tick of the epoch raises the interrupt counter, the next check samples. `WREN_JS_IMAGE=<file>`: another engine image in the browser, which is how a named image gets profiled in a real load and two engines are compared with one browser. Beware of the first load of a binary or an image: it compiles the engine, 2 s on the window thread.

**The timeline.** On theverge.com, npr.org and cnn.com the window thread is busy from the first script to the load event: 12 to 20 ms idle in 7 to 8 s (Phase `wait` is not counted as idle: about 480 ms of it on cnn.com, 60 on npr.org). The waves of requests are that: a response is taken in at a turn of the loop, and tasks last up to a second, so a request of 43 bytes shows 1.3 s, and what it would have started waits. What fills the thread (self time to the load event, one load each, so orders of magnitude; theverge.com with the JIT off, the two others with the thresholds of item 1; imports include the listeners they run):

| ms | theverge.com | npr.org | cnn.com |
|---|---|---|---|
| the engine (Guest + imports) | 5 017 | 5 496 | 3 242 |
| collections | 1 017 | 587 | 269 |
| the front end, on this thread | 225 | 59 | 843 |
| Animation phase (the frame's forced style and layout) | 400 | 591 | 1 500 |
| rest of frames, tasks | 900 | 240 | 260 |

Compile is **not** what holds these loads: 3 to 12 % of the thread, and a script's wait for its bytecode is mostly the wait for the thread's turn (`compile_done` is a task). Three different pages, three different reasons:
- theverge.com: flat. No function over 12 % of the time; React's render under a `MessageChannel`, 30 %.
- npr.org: concentrated. **41 % of its JavaScript is one function**, a bot manager's murmur3 of its own 500 KB source, written as a state machine of a dozen methods per character: 5.2 million calls through one site, `while (!o.step())`, 250 ns each, on the way to DOMContentLoaded. OneTrust's `OtAutoBlock.js` 21 %, otTCF's `M` 8 %.
- cnn.com: the layout that a frame or a read forces (Animation 1.5 s, `getComputedStyle` 641 ms in 11 calls), and 0.8 s of front end for the 6.8 MB document's inline scripts.

**Round 29's contradiction, explained.** The JIT halved the engine's samples in the first 25 s and the load did not move: **during a load the JIT costs more than it gives.** theverge.com, 3 interleaved runs: JIT on 8.4 s and 22.7 s of CPU, off 7.5 s and 11 s. Two reasons, both measured. `interp_run` is 22 % of the engine's samples: the rest is natives, property definition, allocation, the collection, which compiled code does not make faster. And what is compiled does not last long enough to pay: 2 400 translations, 11 s more of CPU, and the window thread slower everywhere, native code included (self time of tasks 591 -> 866 ms in one pair of loads; not explained; more compile threads change nothing). Round 29's table counted samples over 25 s, most of them after the load.

**Fixed.**
1. **Hot means hot** (`javascript.jit.call_threshold` 2 000 -> 100 000; `loop_threshold` was read by nobody, a loop being compiled at the first interrupt check that fell on it: it now counts those checks, 500 by default). Calls alone or loops alone gain little: the arms below decided. A hot loop is compiled after about 5 million iterations. Tests: `jsengine cold examples/jsbench/jitcold.js` (81 translations at the old thresholds, 0 now), `jsengine reach examples/jsbench/jithot.js` at the default thresholds (hot code is compiled).

| theverge.com, 3 runs | load | CPU |
|---|---|---|
| as before | 8 872 (8 571-11 353) | 24 266 (23 750-53 828) |
| loops 500 checks, calls 2 000 | 8 262 (8 064-8 365) | 18 062 (17 859-19 344) |
| loops 64, calls 100 000 | 7 583 (6 889-8 209) | 13 484 (12 969-14 484) |
| **loops 500, calls 100 000** | 7 237 (6 904-7 567) | 11 688 (11 453-12 000) |
| JIT off | 7 655 (7 382-7 911) | 10 953 (10 953-11 750) |

2. **A `<link rel=preload>` and its element are one request**, whatever the destination. The preload's key said script type Classic for a sheet, a font or an image, the element's said none: each of theverge.com's 66 sheets went out twice, 75 requests of the 323. Not a listing artefact. The fonts listed three times were: their copies are `hit` rows of the HTTP cache, for recaptcha's frames. Test: `jsload_a_preload_and_its_element_share_one_request_whatever_the_destination` (without the fix: four requests ahead for two resources, the server asked twice for each).

Master and the round, 5 runs, ms; Edge, 3 runs:

| | load before | load after | CPU before | CPU after | requests | Edge load |
|---|---|---|---|---|---|---|
| theverge.com | 8 404 (8 310-8 809) | **7 005 (6 973-7 109)** | 22 531 (22 328-22 938) | **11 234 (11 031-11 750)** | 323 -> 248 | 1 825 (1 799-1 903) |
| npr.org | 6 707 (6 414-7 122) | 6 277 (6 137-6 668) | 11 453 (10 516-13 156) | 9 156 (9 031-9 594) | 133 -> 154 | 1 310 (1 066-1 359) |
| cnn.com | 6 663 (6 544-7 012) | 6 464 (6 338-6 778) | 14 375 (13 406-14 781) | 12 125 (11 734-12 625) | 153 -> 150 | 1 142 (1 122-1 197) |
| bbc.com/news | 3 423 (3 156-3 804) | 3 125 (825-3 286) | 8 375 (7 312-9 719) | 4 203 (1 672-4 406) | 119 -> 118 | 546 (416-555) |

Read plainly: **the ranges of the load separate on theverge.com alone**, -17 %. npr.org, cnn.com and bbc.com/news gain by their medians, 3 to 9 %, ranges meeting: not claimed. The CPU is the sure result: halved on theverge.com and bbc.com/news, -20 and -16 % on npr.org and cnn.com, ranges separate on all four. DOMContentLoaded and the first paint do not move. bbc.com/news's 825 is one run of 109 requests, a page that went differently. npr.org's requests go from 133 to 154 by the median and from 128 to 155 in both arms: which ads came. **Wren stays 3.8 to 5.7 times Edge.** The goal of the round is not reached.

**Measured, not kept.**
- **Fewer frames while a page loads** (at most one per 100 or 250 ms after the first contentful paint): cnn.com 6 942 -> 7 126 -> 7 347, theverge.com unchanged. The layouts are not proportional to the frames: what a frame did not lay out, the next read does. The thought that cnn.com's Animation phase was the number of its frames was wrong.
- **A hash table for a shape's transitions** (`add_property` is 5 % of the samples, `{}` has a transition per first key): nothing on either page, worse if anything. Removed.
- **The engine without bounds checks and assertions**: nothing, 7 127 against 7 120 on theverge.com, 4 runs. An earlier series seemed to show 10 %: it compared arms of two series, which this file says not to do.
- **A floor of 32, 64 or 128 MiB under the collector's threshold**: 64 MiB nothing on theverge.com, on npr.org 6 901 -> 6 463 with ranges meeting; 128 MiB -0.6 s on theverge.com without the JIT, 3 runs. 20 collections a load cost 1 s, but not for the memory they would take.
- `wasm.wasmtime.parallel_compilation=false`, `javascript.jit.background_threads=8`: no change on the load.

**Not done, and why.** Lazy compilation: the numbers do not put it first: the front end is 225 ms of theverge.com's window thread and 843 ms of cnn.com's; what lazy compilation would take of that is not measured. Bytecode shared across realms: the realms already find recaptcha in the cache (two of its runs took 100 and 47 ms in the trace, reading included). Compilation when a script arrives: not measured.

**Not verified.** That raised thresholds cost nothing on long-running pages: `macro.js`, games and anything hot but not quite were not measured; a function under 100 000 calls now stays interpreted for good. A loaded machine, the release build, memory. The self time of tasks rising with compile threads at work is seen, not explained.

Tests: the two above, `spans_keep_what_was_added_and_stop_at_their_room`; `test_all -Quick -NoAsan` on test262 with and without the JIT, jitcheck, `judge`, the JavaScript steps and the unit tests of what changed. Not run: WPT, the full suite, AddressSanitizer.

## Inventory

### Internal caches (remove by making the path fast; product caches kept)

Kept, a product: the HTTP cache (`src/httpcache`), the back/forward cache (`browser/bfcache.odin`), compiled scripts on
disk (`js/cache.odin`), compiled Wasm modules (`wasm/module_cache.odin`), the Cache API (`page/cache_store.odin`): each
saves the network or a compiler's work across navigations and starts, which no faster path can. GPU residency, not caches:
the glyph atlas (`font/raster.odin:71`), Slug glyph data (`font/slug_cache.odin:44`), image textures
(`browser/images_shell.odin:70`), retained pictures (`browser/compositor.odin:129`, with its memory budget). Not a cache
either: the table of a style pass that gives elements with the same inputs the same computed style (`style/share.odin`,
round 4): it holds the values that pass made and goes with it, nothing in it is invalidated; nor the families of the
walk that share matching between alike elements (`style/sibling_match.odin`, round 5): what the pass matched for the
first of a kind, dropped when the walk leaves that family; nor the pairs of records a chunk of the layout journal's
comparison has compared (`style/journal.odin`, round 8), which live while that chunk is compared.

To remove:

| where | what | hot on |
|---|---|---|
| `ext/gui_toolkit/font/shape.odin:400-460` | `Word_Cache`: 64 shards of shaped words, a mutex each, plus `l1_words` per thread | every word measured or painted |
| `style/inline_cache.odin:47-129`, `cascade.odin:124-125` | compiled `style` attributes by text | every element with a style attribute |
| `style/match.odin:58-67` | `sibs`, `filled`, `has_memo`: maps by handle per pass | nth-child and `:has()` |
| `layout/types.odin:459` | `font_lookup`: fonts by content across partial passes (the per-pass map and its one-entry memo went in round 4) | a font a pass has not found yet |
| `layout/types.odin:242-247`, `block.odin:320-333` | `Box.cache_*`: a block's result for the same inputs | block layout |
| `browser/fonts.odin:347-380` | `Page_Fonts.resolved`: request string (built per lookup) -> font | font resolution |
| `browser/paint_masks.odin:128-156` | text items per box for `background-clip: text`, wiped every pass | that property |
| `browser/compositor.odin:251-293` | `raster_hash` memo per call | compositor rebuild |
| `browser/effects_cache.odin:51` | content keys per group for the GPU layer cache | filters |
| `browser/web_font_faces.odin:166` | family list -> invisible while loading | paint |
| `ext/gui_toolkit/ui/text_wrap.odin:61`, `ext/gui_toolkit/ui/rich_text.odin:370` | wrapped and rich text of the chrome | chrome frames |

### Hash tables on hot paths

`style/engine.odin:68-69` (`by_id`, `by_class`, `by_tag`, `by_attr`: string keys looked up per class, id, tag and attribute
of every element, plus a concatenation per indexed attribute at `cascade.odin:577`); `style/match.odin:58-67`;
`style/cascade.odin:476-493` (custom properties, contexts, `fs_chain` per element); `layout/context.odin:28-58`
(`anon_cs`, `frame_cs`; `font_cache` gone in round 4); `layout/types.odin:479` (`scroll`, read per space); `browser/compositor.odin:114`
(`node_items`, a heap list per node) and `:419-554` (per rebuild); `page/images.odin` `css_images_sync` and
`page/fonts.odin` `fonts_sync` (a `seen` table of shared lists, now only when something new may be used);
`ext/gui_toolkit/font/raster.odin:77-82` (per glyph, under the atlas lock); `page/timeline.odin` `et_seen` (per
element with `elementtiming` only). Gone in round 1: `page/timeline_lcp.odin` `ls_prev` (per box, per mutated frame).
Added in round 4, flat: `style/share.odin` (a style pass's shared styles: open addressing, the keys' words in one array,
one lookup per element). Gone in round 5: `style/restyle_dom.odin` `inserted_exceed` (the inserted nodes of a restyle,
now bits by handle index). Gone in round 7: the glue's node handle -> wrapper table (`native/js/odin/wj/qjs_platform.odin`,
now an array by handle index; the hash table holds only the handles whose entry is taken, none on nodes10k). Gone in
round 9: `layout/multicol.odin` `mc_records` (a container's columns, looked up for each box and line of its flow; now
an array, `Box.mc` the index).

### Arrays of bools

Per box or element, per pass: `layout/context.odin:51` (`plain`), `layout/finish.odin:37,81`, `layout/effects.odin:46`,
`layout/incremental.odin:485,610`, `layout/query.odin:88` (`View.singular`, per frame), `style/cascade.odin:480`
(`gate_probe`), `browser/compositor.odin:448,761`, `browser/effects_cache.odin:54,65`;
`map[...]bool` used as sets: `style/match.odin:59,67`, `style/engine.odin:70`, `style/restyle_dom.odin:145-148`,
`font/raster.odin:79-80` (per glyph); `draw/bsp.odin:241` (n x n per 3D sort).

### Mutexes (57 in Wren, 20 in the toolkit, outside tests)

The ones on a per-frame or per-item path, and what fits instead (the loop's, the network's and `parallel_for`'s were
measured against lock-free designs in round 3 and stay):

| where | guards | threads | instead |
|---|---|---|---|
| `font/raster.odin:75` `Atlas.mu` (shared for a hit since toolkit 0.64.0) | glyph maps, atlas pages, Slug store; rasterizes under it | every drawing thread, the color-glyph thread | per-thread lookup front, misses to a raster owner over an MPSC queue |
| `font/shape.odin:401` `Word_Shard.mu` x 64 (shared for a hit) | shaped words; glyphs copied out under it | layout threads, page, chrome paint | goes with the word cache |
| `style/invalidation.odin:454` `Key_Sets.mu` | interned selector keys, process-wide | every page's style engine | per-engine tables |
| `webaudio/graph.odin:79` | the audio graph | page vs the real-time render thread | SPSC command ring |
| `media/store.odin:57` | coded frames | demux vs decoder | SPSC ring |
| `page/worker.odin:95` | page <-> worker queues | two threads | two SPSC rings |
| `page/canvas_offscreen.odin:19` | the latest picture | worker -> window | a latest-value mailbox |
| `page/canvas_offscreen.odin:146`, `page/mse_worker.odin:185`, `page/bindings_webcodecs.odin:383` | transfer tokens | one thread to another | ownership hand-off |
| `host/blocking.odin:19`, `images/pool.odin:107`, `page/js_load_compile.odin:33`, `httpcache/disk.odin:72,78`, `js/cache.odin:49`, `wasm/module_cache.odin:65` | job queues in, results out | loop <-> workers | MPMC in, MPSC out |
| `idb/manager.odin:192` (recursive) | the whole IndexedDB manager | pages and workers | an owner thread fed by an MPSC queue |
| `wasm/instance.odin:67`, `images/pool.odin:44`, `page/storage.odin:53`, `font/emoji.odin:23`, `media/h264_linux.odin:32` | something made once | | `sync.Once` |
| `wasm/attach.odin:30`, `webauthn/webauthn.odin:229` | counters, a cancel flag | | atomics |

The others guard real shared registries (live threads, blob URLs, Web Locks, OPFS, the Cache API, storage buckets,
shutdown, the clipboard, the shader compiler) and stay.

### Heap lists per call on hot paths

`style/timeline.odin:429-432,468` (an `Element_Anim` and three dynamic arrays for each element that declares a transition,
on every full pass); `browser/compositor.odin:321` (`compute_floors`: one heap array per group per rebuild) and `:530`
(`node_items_make`: one per node); the window thread's and the thread pool's temporary arenas, which give back what
outgrew their first block after each frame or job (`NtFreeVirtualMemory`, 1 % of the window thread on nodes10k; the
pool's are `src/host`'s). Gone in round 2: the style threads' arenas mapped and freed with every pass. Gone in round 3:
the layout thread's growing arrays (none in its samples since round 2) and its temporary blocks mapped and freed every
pass. Most of layout and paint already use the temporary allocator or an arena.

## Next, ranked by measured cost on a bottleneck

After round 4 (item 3 of round 3's list, in part). Round 2's items 2, 3 and 8 are done (item 3 measured: a partial restyle of nodes10k costs what a full
pass does); what is left of them is folded in below. Round 3 also measured round 2's item 7 as it stood (the loop's and
the network's locks) and kept the mutexes; item 7 is now the job queues, to be measured the same way before anything
replaces them. Round 2's item 1 is done in part: the engine traces, it counts no reference a script holds, so a plain
wrapper still waits for a collection, but the collection no longer pays for it.
After round 4. Round 3's item 2 is done for what it named (styles shared, the inherited group, the arenas, and the
restyle that gave up too late); what styling an element still costs is item 3 below.
After round 5. Round 4's item 2 is done (matching shared by alike elements, the counter walk, the check of what was
inserted); of item 3, the incremental attempt is done, the display list of the flow and the page thread's temporary
block were measured and left as they were (round 5, item 5); what is left of both is below.

After round 6. Round 5's item 1 is done in part (round 6: the named class, the interface by name, the insertion steps'
walks, the wrapper's allocations, the C API's decoding, the getters); what is left of it is item 1 below.

After round 7. Round 6's item 1 is done in part (round 7: the collection's unpins in one call, the arguments' strings
read in place, element names as the program's strings, the wrappers by handle index); what is left of it is item 1
below.

After round 8. Round 7's items 2 and 3 are done in part (round 8: the display list of a page with columns on the
layout threads, the walks of writing modes and the copies around the block layout, the page's color scheme, `:disabled`,
the journal's pairs of records); what is left of them is items 2 and 3 below.

After round 9. Round 8's items 2 and 3 are done in part (round 9: the weights of the subtrees in one walk, the slots
of a recycled pass, a container's record by index); what round 9 measured of layout's steps moves item 2 below to the
arrays they read (round 8's item 4 folded in); what is left of the style pass is item 3.

After round 10. Round 9's item 2 was measured before anything was split: the steps are not bound by the layout of the
records (round 10, item 1); the scans of every box no longer take the long way for a box in a flow (item 2). Item 2 below
is now the steps' own code.

After round 11. Round 10's item 2 is done in part (round 11: the image search from the document's list, a flow's boxes
and lines cut against the column of the one before, a smaller display item); the block layout of the columns was timed
by part and has nothing that stands out (round 11, item 4). Item 1 is unchanged and now first by far; item 2 below is
what is left of layout.

After round 12. Round 11's item 1 is done in part (round 12: one crossing for a new node and its wrapper, the realm's
document asked once, the root lists appended in place, native getters and string constants in the hot loop, the
bridge's conversions in place, `JS_GetAnyOpaque`); what is left of it is item 1 below.

After round 13. Round 12's item 1 is done in part (round 13: the counting pass and the marking skip the wrappers that
hold nothing, a detached tree freed by its links); what is left of it is item 1 below, and what round 13 found of the
interpreter's code generation is item 9.

After round 14. The static C runtime measured against the dynamic one: the same (round 14, item 1). Item 3 below no
longer pays for `::backdrop` on every element (round 14, item 2); item 1 is unchanged.

After round 15. Round 14's item 9 is done (round 15: the hot loop calls nothing and is inlined; `micro.js` 14 %
faster, `macro.js` 9 %), and with it the prototype walk without the host class's hooks of item 1. Real pages loaded from
the navigation are item 10 below.

After round 16. Round 15's item 10 is done for what it named (round 16: the engine read ahead, Direct2D made ahead,
textures zeroed on the GPU, the thread count of `stats`) and for what its measures found besides (what waits for a
stylesheet goes on when it arrives); what the loads still spend is item 10 below. Item 1 is unchanged.

After round 17. Round 16's item 10 is done in part (round 17: Slug's bands from one sort per axis, the image decoder's
start that waits for nothing; Slug's data made while shaping measured and not kept); what its measures found, the frame
that waits for its slot before the tasks, leads item 10 below. Item 1 is unchanged.

After round 18. Round 17's item 10 is done for its first part (round 18: the loop's tasks run in the frame's wait for its
slot, a first paint waits for no slot); p10k's first passes lead item 10 below. Item 1 is unchanged.

After round 19. Off this list: the licence card of about:wren under the pointer (a document changed only in style
attributes is refreshed, not laid out; planes keep their raster scale; the development build lost the Direct3D debug
layer).

After rounds 20, 21 and 23. Item 1's interpreter gave way to a JIT for hot loops and hot functions (round 20: loops,
properties, calls; 21: whole functions, direct calls, objects, strings, DOM getters, natives; 23: `document`, objects
allocated inline, the script's accessors): nodes10k's `build()` p50 8.63 -> 7.44 ms in round 23's series. What is left of
item 9 now counts only for code the JIT does not take; [engine/jit.md](engine/jit.md) has the JIT's own list.

After rounds 22 and 24. Off this list too: what the user does while a script is busy (input, selection, the scroll bars,
keys, then animations of `transform` and `opacity`, scroll boxes and the caret, drawn by chrome frames from the last
layout). Hover stays the page's, by design (round 24, item 4).

After round 25. The list is in the order of its measures again: item 10 is item 2, done for two of what it named
(`legacy-html.html`'s task, identified and gone; p10k's first passes in part), and the profiler's bursts are in item 9.
Item 1's figures were old: measured again they are higher, and nothing here says why.

After round 26. Heavy pages from the navigation to the load event: the first paint is halved on the mean (round 26), the load much less. What is left of it is item 1 below and two things of its own. The engine's
share of the window thread during a load is 47 to 68 % on most of them (vimeo.com: the interpreter 27 %, the collection 13 %, the rest spread out). css-tricks.com is the engine too, 18 s for its twenty-three embeds, now that they are all
loaded. Not done: a preload scanner that works while the document arrives (the parser takes the whole document first: cnn.com's 6.8 MB, 240 to 700 ms before any
request of the page); `priority` headers (RFC 9218) now that images go out beside scripts; a style pass scoped to what a sheet that arrives can reach (cnn.com: 15 full passes for sheets, 2.2 s).

After round 29. The JIT reaches what pages run (round 29): nothing refused, 72 to 89 % of the interpreter's checks in compiled code on the pages measured. The loads did not follow, and the CPU went up. In order: **what holds a load on a quiet machine**, measured on the window thread by phase and against the waterfall, before more work on the engine; **what a translation costs**: each guard's exit materializes the stack in Wasm code (47 bytes of module for one of bytecode), a table of stack maps read by `jit_exit` would make an exit a few bytes; the translation itself is on the window thread (9 % of theverge.com's samples before the undo record was made small); identical code compiled once per realm (css-tricks.com's embeds); locals typed from the recorded runs (a whole function holds them in memory as values); inline caches for the interpreter's `get_field` where code stays cold; `frontend_compile`, 10 to 19 % of the window thread's engine samples, scripts under `javascript.compile.offthread_min_bytes`; the collection (10 to 16 %), generations or a floor above GC_MIN_ALLOCATION.

After round 30. A heavy page's load is the window thread's, busy from the first script to the load event, in the engine (natives, property definition, allocation, the collection, not the interpreter's dispatch alone) and the layouts it forces. The JIT no longer works against the load, and does not help it either. In order: **a call through one site with a few callees** (npr.org: 41 % of its JavaScript is `while (!o.step())`, 250 ns a call); **the collection** (1 s of theverge.com's 7: generations, its share is not a question of memory, round 30); **what `getComputedStyle` and a forced layout cost** on cnn.com (2 s); the engine's natives by a direct measure each; a compiler for a load, cheap enough to pay in seconds (Winch was not tried: `wasm.wasmtime.compiler` is the engine's whole, the JavaScript engine's own code included). Round 29's first item is done: what follows that names lazy compilation or bytecode sharing is not first by the numbers.

1. **The script stage of DOM-heavy pages, what is left** (`js_nodes10k` on a quiet machine after round 25, 5 runs: a frame of 16.9 ms
   (16.8 to 17.4), the Animation phase 10.5 ms, where this list kept 17.7 and 11.8; the 20.6 to 29.5 ms first noted for that day were
   the load of the agents working beside the measure, nothing to bisect). In order of the engine's samples: the interpreter itself (`interp_hot` 17 % before round 15's 15 to 25 %
   on the loop's own instructions, `call_native` and the bridge 8 %; a DOM call costs 50 to 100 ns over the loop); the
   collection the DOM asks for (2.9 ms every 2 frames: the browser's `Node_unpinAll`, the prologue's walk of every
   wrapper with `JS_IsUntouched` for each, the finalizers' chain of calls, the sweep's frees, `gc_drain`); the browser's
   insertions (0.5 ms a frame by the browser's sampler: the insertion hooks 29 %, the journal 23 %, `check_insert` 9 %);
   the browser's factories (`create_element`, `pool_insert_tagged` copying a `Node` by value, the pin, the interface);
   making the wrappers (6 %). Texts are still copied to the heap and freed one by one (`create_text`, about 0.1 ms a
   frame). Measured and left: a flag per interface for the unforgeable members of its chain (round 7); the finalizers'
   skipped calls, the pre-sweep walks in one, the prologue's walk inlined, `temp_reset` in place (round 12); the hot
   loop as a procedure of its own (round 15: 8 % slower than inlined).
2. **Pages loaded from the navigation** (rounds 15 to 18 and 25; `wrentool bench perf -Only p10k_nav,nav_...`,
   `p10k_renav` for the samples), by cost: p10k's first contentful paint is 39.7 ms: its parser's thread about 16 (`html.parse_into`
   10, then the sheet 4 to 5: the sheet waits for the whole document, on the same thread, when it could start with the
   `</style>`), then the window's thread 24: the layout about 11 (flat in the samples; `place_element`, the threads'
   paragraphs, growing lists: `new_box` still reallocates), the style pass 8 (the rebuild 3.3, the style threads 3.9). Then
   `text.html`'s first paint (`Paint_Items`, DirectWrite's `glyph_formats` under `platform_color_glyph`, the bands, the
   outlines; `_extendhfsf2` was a misnamed sample, round 25) and its two modes; the first realm (5 ms from response to
   script, instantiation included: the instance made on the read-ahead thread would take a part). A task that arrives
   during the swap chain's wait (a fixed refresh screen's whole wait, at most a refresh) still waits for its end: the
   latency object cannot be woken by the loop.
3. **Layout of DOM-heavy pages: the steps' own code** (nodes10k: the Layout phase 5.3 ms a frame on the day of round 25,
   3.1 ms when this was written; the page thread's full pass then: tree 0.96, layout 1.07, finish 0.32, display 0.37, bands 0.13 ms). Round 10 found the records'
   layout no gain, round 11 took the image search, the cut of the flow and the display item's padding. What the profile
   shows now, by cost: building the box tree (19 % of the page thread; `place_element`, and the layout threads'
   summaries of the styles); the block layout of the columns (34 %, no part above 0.11 ms in process: `apply_shifts`
   moving every box to its column, then the 2 500 items' own layout at about 150 ns each: a shorter path for an item
   whose paragraph came from the threads and whose style is its siblings' is what is left to try); finishing (`finish`
   itself 6 %); `note_refresh_inputs` (4.5 %: every display item and inline item read again after the list is made,
   which the shares making the list could note as they go); the bands (4.4 %).
4. **What a full style pass still costs per page** (`mutation_fullstyle`, 3.34 ms of CPU a frame in all, 5 runs, round 25; the style stage 0.75 ms in the browser, a pass
   0.57 ms in process with seven threads since round 14, four fifths of that on the threads since round 9): on the
   style threads, matching
   (`match_chain`, the families of pages whose elements are each of their own kind: modern-css, p10k, matched in full
   as before) and the journal's comparison of the pairs that differ; on the window thread, the weights of the subtrees
   (0.07 ms, one walk since round 9: weights the DOM keeps would cost every insertion).
5. **The temporary arenas of the window thread and of the thread pool** (`src/host`): emptied by zeroing what they held
   after each frame or job (`mem_free_all` and its `memset` are 6 to 12 % of some pool threads' samples on nodes10k), and
   given back past their first block. Allocations that need no zero (`make` of what is overwritten whole) are the gain
   there, not when the zeroing happens (round 5, item 5).
6. **The atlas lock and the word cache's 64 locks** (toolkit): toolkit 0.64.0 took the atlas lock once per run of glyphs
   and a word cache hit under a shared lock (its `docs/locks.md`: 8 threads, a word's shape 442 -> 194 ns, a glyph's bitmap
   120 -> 17 ns); what is left is measuring the page's text again before any per-thread front.
7. **The style index's string tables** (`style/engine.odin:68-69`): atoms (interned ids) and flat arrays by atom (looked
   up now only for the first element of each kind of a family).
8. **The job queues of the blocking pool, the image decoders, the script compiler and the caches** (the table above):
   measured first (round 3: a lock-free queue lost to the loop's mutex); a worker's `ordered_remove(0)` is a cost of its own.
9. **The profiler**: the threads' bursts of a few ms (round 25: 0 running of 44 807 samples on p10k, not explained; ETW's context
   switches would say); correct the bias of samples taken in a system call.
10. **The interpreter, what is left after its loop** (round 15): the full dispatch of `interp_run` for what the loop
   leaves (closures made, `arguments`, spreads, destructuring of iterables: the two cases of `macro.js` that did not gain
   are there), and native callbacks (`sort`, `forEach`: an `interp_run` activation each). A handler added to the loop
   must call nothing itself (`interp_hot.odin`'s header says how).
