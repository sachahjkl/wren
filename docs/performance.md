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

After round 4 (medians of 5 interleaved runs): the window thread waits 8.1 -> 5.3 ms a frame on layout, a full pass
5.9 -> 3.5 ms (its paragraphs in columns now on the layout threads), 52.3 -> 55.1 frames/s.

**Bottleneck:** the script stage (the interpreter and its native calls, making wrappers, the collection), then layout.

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
## Inventory

### Internal caches (remove by making the path fast; product caches kept)

Kept, a product: the HTTP cache (`src/httpcache`), the back/forward cache (`browser/bfcache.odin`), compiled scripts on
disk (`js/cache.odin`), compiled Wasm modules (`wasm/module_cache.odin`), the Cache API (`page/cache_store.odin`): each
saves the network or a compiler's work across navigations and starts, which no faster path can. GPU residency, not caches:
the glyph atlas (`font/raster.odin:71`), Slug glyph data (`font/slug_cache.odin:44`), image textures
(`browser/images_shell.odin:70`), retained pictures (`browser/compositor.odin:129`, with its memory budget).

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

1. **The script stage of DOM-heavy pages** (nodes10k: 25 ms of a 47 ms frame). In order of the samples: the interpreter's
   native calls and the property lookups up the prototype chains (`get_property` is a quarter of the engine's samples;
   the interpreter is `src/engine`'s); the collection the DOM still asks for every frame (a fifth of the stage: the
   finalizers, `Node_unpin` one wrapper at a time, the prologue's visit of every wrapper); making wrappers
   (`make_wrapper`, `Node_wrap`); the DOM work of an insertion (its hooks walk the inserted subtree). Not the crossings
   (4 %, section 2).
2. **The cost of styling one element** (nodes10k: 8.3 ms a frame for 7 500 new elements, full pass or partial). On the
   style threads (round 3's profiler): matching (`collect_entries`, about a quarter), `build_style`, and zeroing the
   arena they take back (`arena_free_all`, 13 %). Next steps: the inherited properties in a group of their own, shared
   with the parent until an element sets one (`inherit_all` copies about 500 bytes for every element; the writes to
   take care of are the derived values of the cascade, `scheme_settle`, `derive_fields`, the content language, and the
   copies of inherited values outside it: layout's refresh of anonymous boxes, the timeline's `push_inherited` and
   `pseudo_inherit`); an arena that need not be zeroed for the records the cascade overwrites whole.
3. **Layout of DOM-heavy pages, what round 4 left** (nodes10k: the window thread waits 5.3 ms a frame on a pass
   of 3.5 ms; the page thread's samples after round 4): the display list of the flow (`emit_lines` and
   `push_flow_item`, 12 to 15 %: every text item is copied once per column it may lie in, and `emit_lines` reads two
   fields of each text's style for visibility and pointer-events, which the box's flags already hold); the incremental
   attempt that ends in "too much changed" (`add_target`, `touched_ancestor`, `subtree_size`, `plan_children` over the
   5 000 removed and inserted list items: 6 to 8 %, before the full pass starts; a bound from the journal's size would
   decide it first); building the box tree (place_element, push_children, list markers: 13 to 17 %); the zeroing of
   the page thread's temporary block at the end of each pass (`memset` in `free_all`, 2 to 5 %).
4. **The layout's boxes as arrays of what the scans read** (the LCP scan's remaining cost is `box_border` reading each
   box's struct, 57 % of it; the layout-shift scan reads the same): border rects and flags in flat arrays by box, or
   scans of the boxes the layout journal says changed.
5. **The atlas lock per glyph and the word cache's 64 locks** (toolkit): a per-thread front, misses to one owner
   (`word_find` was 4 % of the page thread on nodes10k before round 4 moved its paragraphs to the layout threads).
6. **The style index's string tables** (`style/engine.odin:66-68`): atoms (interned ids) and flat arrays by atom.
7. **The job queues of the blocking pool, the image decoders, the script compiler and the caches** (the table above):
   measured first (round 3: a lock-free queue lost to the loop's mutex); a worker's `ordered_remove(0)` is a cost of its own.
8. **The temporary arenas of the window thread and of the thread pool** (`src/host`): the same as the page thread's (a
   block kept at the largest size used), where they outgrow their first block every frame or job.
9. **The profiler**: correct the bias of samples taken in a system call.
