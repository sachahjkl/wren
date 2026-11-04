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
  `WREN_SAMPLE_THREADS=1` (the other threads, in proportion to the CPU cycles each ran: every millisecond the one that
  ran the most since its last sample; per thread, its hottest call chains and the functions on its stack). Before round
  3 it visited the ninety threads in turn, about 13 samples a second each. Samples that land in a system call are biased: on the
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
| `ext/gui_toolkit/font/shape.odin:383-611` | `Word_Cache`: 64 shards of shaped words, a mutex each, plus `l1_words` per thread | every word measured or painted |
| `style/inline_cache.odin:37`, `cascade.odin:114` | compiled `style` attributes by text | every element with a style attribute |
| `style/match.odin:55-64` | `sibs`, `filled`, `has_memo`: maps by handle per pass (and `seen` at `:191` written, never read) | nth-child and `:has()` |
| `layout/types.odin:435` | `font_lookup`: fonts by content across partial passes (the per-pass map and its one-entry memo went in round 4) | a font a pass has not found yet |
| `layout/types.odin:220`, `block.odin:268-311` | `Box.cache_*`: a block's result for the same inputs | block layout |
| `browser/fonts.odin:343-379` | `Page_Fonts.resolved`: request string (built per lookup) -> font | font resolution |
| `browser/paint_masks.odin:126-156` | text items per box for `background-clip: text`, wiped every pass | that property |
| `browser/compositor.odin:252-293` | `raster_hash` memo per call | compositor rebuild |
| `browser/effects_cache.odin:51` | content keys per group for the GPU layer cache | filters |
| `browser/web_font_faces.odin:166` | family list -> invisible while loading | paint |
| `ui/text_wrap.odin:61`, `ui/rich_text.odin:370` | wrapped and rich text of the chrome | chrome frames |

### Hash tables on hot paths

`style/engine.odin:66-68` (`by_id`, `by_class`, `by_tag`, `by_attr`: string keys looked up per class, id, tag and attribute
of every element, plus a concatenation per indexed attribute at `cascade.odin:443`); `style/match.odin:55-64`;
`style/cascade.odin:345-361` (custom properties, contexts, `fs_chain` per element); `layout/context.odin:26-60`
(`anon_cs`, `frame_cs`; `font_cache` gone in round 4); `layout/types.odin:454` (`scroll`, read per space); `browser/compositor.odin:115`
(`node_items`, a heap list per node) and `:421-556` (per rebuild); `page/images.odin` `css_images_sync` and
`page/fonts.odin` `fonts_sync` (a `seen` table of shared lists, now only when something new may be used);
`ext/gui_toolkit/font/raster.odin:74-79` (per glyph, under the atlas lock); `page/timeline_lcp.odin` `et_seen` (per
element with `elementtiming` only). Gone in round 1: `page/timeline_lcp.odin` `ls_prev` (per box, per mutated frame).
Added in round 4, flat: `style/share.odin` (a style pass's shared styles: open addressing, the keys' words in one array,
one lookup per element). Gone in round 5: `style/restyle_dom.odin` `inserted_exceed` (the inserted nodes of a restyle,
now bits by handle index). Gone in round 7: the glue's node handle -> wrapper table (`native/js/odin/wj/qjs_platform.odin`,
now an array by handle index; the hash table holds only the handles whose entry is taken, none on nodes10k). Gone in
round 9: `layout/multicol.odin` `mc_records` (a container's columns, looked up for each box and line of its flow; now
an array, `Box.mc` the index).

### Arrays of bools

Per box or element, per pass: `layout/context.odin:53` (`plain`), `layout/finish.odin:37,81`, `layout/effects.odin:45`,
`layout/incremental.odin:563`, `layout/query.odin:91` (`View.singular`, per frame), `style/cascade.odin:349`
(`gate_probe`), `style/engine.odin:119-120`, `browser/compositor.odin:450,763`, `browser/effects_cache.odin:54,65`;
`map[...]bool` used as sets: `style/match.odin:56,64`, `style/engine.odin:68`, `style/restyle_dom.odin:144-147`,
`font/raster.odin:76-77` (per glyph); `draw/bsp.odin:241` (n x n per 3D sort).

### Mutexes (51 in Wren, 17 in the toolkit, outside tests)

The ones on a per-frame or per-item path, and what fits instead (the loop's, the network's and `parallel_for`'s were
measured against lock-free designs in round 3 and stay):

| where | guards | threads | instead |
|---|---|---|---|
| `font/raster.odin:72` `Atlas.mu` | glyph maps, atlas pages, Slug store; rasterizes under it | every drawing thread, the color-glyph thread | per-thread lookup front, misses to a raster owner over an MPSC queue |
| `font/shape.odin:398` `Word_Shard.mu` x 64 | shaped words; glyphs copied out under it | layout threads, page, chrome paint | goes with the word cache |
| `style/invalidation.odin:454` `Key_Sets.mu` | interned selector keys, process-wide | every page's style engine | per-engine tables |
| `webaudio/graph.odin:79` | the audio graph | page vs the real-time render thread | SPSC command ring |
| `media/store.odin:57` | coded frames | demux vs decoder | SPSC ring |
| `page/worker.odin:95` | page <-> worker queues | two threads | two SPSC rings |
| `page/canvas_offscreen.odin:19` | the latest picture | worker -> window | a latest-value mailbox |
| `page/canvas_offscreen.odin:146`, `page/mse_worker.odin:185`, `page/bindings_webcodecs.odin:383` | transfer tokens | one thread to another | ownership hand-off |
| `host/blocking.odin:19`, `images/pool.odin:106`, `page/js_load_compile.odin:33`, `httpcache/disk.odin:72,78`, `js/cache.odin:73`, `wasm/module_cache.odin:86` | job queues in, results out | loop <-> workers | MPMC in, MPSC out |
| `idb/manager.odin:192` (recursive) | the whole IndexedDB manager | pages and workers | an owner thread fed by an MPSC queue |
| `wasm/instance.odin:67`, `images/pool.odin:43`, `page/storage.odin:53`, `font/emoji.odin:23`, `media/h264_linux.odin:32` | something made once | | `sync.Once` |
| `wasm/attach.odin:25`, `webauthn/webauthn.odin:229` | counters, a cancel flag | | atomics |

The others guard real shared registries (live threads, blob URLs, Web Locks, OPFS, the Cache API, storage buckets,
shutdown, the clipboard, the shader compiler) and stay.

### Heap lists per call on hot paths

`style/timeline.odin:429-432,468` (an `Element_Anim` and three dynamic arrays for each element that declares a transition,
on every full pass); `browser/compositor.odin:322` (`compute_floors`: one heap array per group per rebuild) and `:532`
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

1. **The script stage of DOM-heavy pages, what is left** (nodes10k: 11.8 ms of a 17.7 ms frame; the browser's side
   1.4 ms of it). In order of the engine's samples: the interpreter itself (`interp_hot` 17 % before round 15's 15 to 25 %
   on the loop's own instructions, `call_native` and the bridge 8 %; a DOM call costs 50 to 100 ns over the loop); the
   collection the DOM asks for (2.9 ms every 2 frames: the browser's `Node_unpinAll`, the prologue's walk of every
   wrapper with `JS_IsUntouched` for each, the finalizers' chain of calls, the sweep's frees, `gc_drain`); the browser's
   insertions (0.5 ms a frame by the browser's sampler: the insertion hooks 29 %, the journal 23 %, `check_insert` 9 %);
   the browser's factories (`create_element`, `pool_insert_tagged` copying a `Node` by value, the pin, the interface);
   making the wrappers (6 %). Texts are still copied to the heap and freed one by one (`create_text`, about 0.1 ms a
   frame). Measured and left: a flag per interface for the unforgeable members of its chain (round 7); the finalizers'
   skipped calls, the pre-sweep walks in one, the prologue's walk inlined, `temp_reset` in place (round 12); the hot
   loop as a procedure of its own (round 15: 8 % slower than inlined).
2. **Layout of DOM-heavy pages: the steps' own code** (nodes10k: the window thread waits 3.1 ms a frame, the page
   thread's full pass: tree 0.96, layout 1.07, finish 0.32, display 0.37, bands 0.13 ms). Round 10 found the records'
   layout no gain, round 11 took the image search, the cut of the flow and the display item's padding. What the profile
   shows now, by cost: building the box tree (19 % of the page thread; `place_element`, and the layout threads'
   summaries of the styles); the block layout of the columns (34 %, no part above 0.11 ms in process: `apply_shifts`
   moving every box to its column, then the 2 500 items' own layout at about 150 ns each: a shorter path for an item
   whose paragraph came from the threads and whose style is its siblings' is what is left to try); finishing (`finish`
   itself 6 %); `note_refresh_inputs` (4.5 %: every display item and inline item read again after the list is made,
   which the shares making the list could note as they go); the bands (4.4 %).
3. **What a full style pass still costs per page** (`mutation_fullstyle`, the style stage 0.75 ms in the browser, a pass
   0.57 ms in process with seven threads since round 14, four fifths of that on the threads since round 9): on the
   style threads, matching
   (`match_chain`, the families of pages whose elements are each of their own kind: modern-css, p10k, matched in full
   as before) and the journal's comparison of the pairs that differ; on the window thread, the weights of the subtrees
   (0.07 ms, one walk since round 9: weights the DOM keeps would cost every insertion).
4. **The temporary arenas of the window thread and of the thread pool** (`src/host`): emptied by zeroing what they held
   after each frame or job (`mem_free_all` and its `memset` are 6 to 12 % of some pool threads' samples on nodes10k), and
   given back past their first block. Allocations that need no zero (`make` of what is overwritten whole) are the gain
   there, not when the zeroing happens (round 5, item 5).
5. **The atlas lock and the word cache's 64 locks** (toolkit): toolkit 0.64.0 took the atlas lock once per run of glyphs
   and a word cache hit under a shared lock (its `docs/locks.md`: 8 threads, a word's shape 442 -> 194 ns, a glyph's bitmap
   120 -> 17 ns); what is left is measuring the page's text again before any per-thread front.
6. **The style index's string tables** (`style/engine.odin:66-68`): atoms (interned ids) and flat arrays by atom (looked
   up now only for the first element of each kind of a family).
7. **The job queues of the blocking pool, the image decoders, the script compiler and the caches** (the table above):
   measured first (round 3: a lock-free queue lost to the loop's mutex); a worker's `ordered_remove(0)` is a cost of its own.
8. **The profiler**: correct the bias of samples taken in a system call.
9. **The interpreter, what is left after its loop** (round 15): the full dispatch of `interp_run` for what the loop
   leaves (closures made, `arguments`, spreads, destructuring of iterables: the two cases of `macro.js` that did not gain
   are there), and native callbacks (`sort`, `forEach`: an `interp_run` activation each). A handler added to the loop
   must call nothing itself (`interp_hot.odin`'s header says how).
10. **Pages loaded from the navigation** (rounds 15 to 18; `wrentool bench perf -Only p10k_nav,nav_...`), by cost:
   p10k's first style, layout and paint passes (23 ms of the 34 ms frame of its first paint, its first contentful paint
   at 44 ms: most of it on the style and layout threads, to be profiled with `WREN_SAMPLE_THREADS=1`, round 18 item 3);
   `legacy-html.html`'s task of 18 to 21 ms in the frame before its first paint (its samples in waits: not identified);
   what is left of `text.html`'s first paint (`Paint_Items` 15.6 ms: the color glyph probe of color faces, the
   half-float conversions' calls, the outlines; Slug's data made while shaping only moved it onto the layout the paint
   waits for, round 17 item 3); the first realm (5 ms from response to script, instantiation included: the instance
   made on the read-ahead thread would take a part). A task that arrives during the swap chain's wait (a fixed refresh
   screen's whole wait, at most a refresh) still waits for its end: the latency object cannot be woken by the loop.