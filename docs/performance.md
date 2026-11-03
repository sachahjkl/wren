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
   element and for its ::before, ::after and ::selection), its style attribute (by text), its encapsulation depth, and
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

1. **The script stage of DOM-heavy pages, what is left** (nodes10k: 14.3 ms of a 20 ms frame). In order of the
   engine's samples: the interpreter itself (`interp_hot`, `interp_run`, `call_native` and the C API's bridge: about a
   third, with the prototype walks for methods, five shapes for `li.appendChild`); making the wrappers (`make_wrapper`,
   `host_object_new`, `mem_alloc`, the appends to the engine's temporary roots: about a fifth with the browser's
   `createElement`, `createTextNode` and `Node_wrap`, two crossings for each new node where one could pin and name the
   interface); the collection the DOM asks for (13 %, 3.8 ms every 2 to 3 frames: the mark and the sweep, the prologue's
   visit of every wrapper, a sixth of it, memory-bound, and the browser's `destroy_subtree` of the trees it frees);
   `Node_preInsert` (6 % of the browser's samples: `insert_before`, the journal, the insertion steps' walk); the
   `document` getter's crossing (2 %, its answer never changes for a realm once its page's document is adopted: to be
   shown first). Texts are still copied to the heap and freed one by one (`create_text`; an arena of the document needs
   texts that change to give their bytes back). Not the crossings themselves (section 2). Measured and left: an inline
   list in `destroy_subtree` (round 6); a flag per interface for the unforgeable members of its chain (round 7).
2. **Layout of DOM-heavy pages: the steps' own code** (nodes10k: the window thread waits 3.2 ms a frame, the page
   thread's full pass: tree 0.92, layout 1.04, finish 0.36, display 0.39, bands 0.13 ms). Round 10 measured the layout
   of the records against the steps and found nothing there (`Box` twice as large or reordered, display items twice as
   large: within 0.06 ms of a 2.6 ms pass; the boxes fit the last cache): arrays of their own by box are not the gain.
   What the profile shows, by cost: the block layout of the columns (`layout_contents`, `layout_ifc`, `flow_children`,
   `gather_child` and `gather_box`: 41 % of the page thread); `flow_bounds_add` (8.5 % of the page thread for finishing,
   and with `box_border` most of what is left of the window thread's scans: each box and line of a flow cut against every
   column, where a rect inside one column needs one test; round 9's binary search did not shorten it, the cut of a box's
   lines against the column its box lies in is the next thing to measure); the display list (9 %; it writes 12 506 items
   of 128 bytes, and their size shows: a smaller item, not a split one); the bands and `note_refresh_inputs`. On the
   window thread, `images_sync` walks the inserted subtrees for images every frame (a quarter of `UI_Draw`'s samples on
   nodes10k): the DOM could list the image elements as it lists the `<meta>` ones (round 8).
3. **What a full style pass still costs per page** (`mutation_fullstyle`, a pass 0.95 ms in the browser, 0.48 ms in
   process with seven threads, four fifths of that on the threads since round 9): on the style threads, matching
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