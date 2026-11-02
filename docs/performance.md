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
  `WREN_SAMPLE_THREADS=1` (the other threads in turn). The thread sampler visits about 90 threads one after the other: a
  worker gets about 13 samples a second, too few for its hot spots. Samples that land in a system call are biased: on the
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

**Bottleneck:** the script stage (JS interpreter, the DOM bindings, the collections that free the wrappers), then layout.

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
| `layout/context.odin:26-29`, `layout/types.odin:435` | style -> font index maps, a one-entry memo | every box and inline item |
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
(`font_cache`, `anon_cs`, `frame_cs`); `layout/types.odin:454` (`scroll`, read per space); `browser/compositor.odin:115`
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
(`node_items_make`: one per node); the layout thread's growing arrays on the nodes10k page (`_reserve_dynamic_array`, a
third of its samples). Gone in round 2: the style threads' arenas mapped and freed with every pass. Most of layout and
paint already use the temporary allocator or an arena.

## Next, ranked by measured cost on a bottleneck

After round 2. Round 1's items 1 (in part), 3, 4 and 5 are done; what is left of them is folded in below. Round 3 measured
item 7 as it stood (the loop's and the network's locks) and kept the mutexes; item 7 is now the job queues, to be measured
the same way before anything replaces them.

1. **Wrappers freed by reference counting** (nodes10k: the collections the DOM asks for are about a quarter of the window
   thread's samples, the script stage 42 ms of a 67 ms frame). A wrapper that carries nothing of its own (no expando
   property, no listener, its interface's prototype, no weak reference to it) can go when its count reaches zero and be
   made again if a script reaches the node later; only the others need the groups of `native/js/odin/wj/qjs_platform.odin`
   and a collection. A removed node would then give its index back as soon as no script holds it, without a collection.
2. **The layout thread's heap growth** (round 1: a third of its samples on nodes10k; layout is now 10.9 ms there):
   inline-capacity lists or the layout arena for the per-box lists of inline segments.
3. **Style on DOM-heavy pages: every pass full, and `Computed` copied whole** (nodes10k: 9.6 ms a frame, "too much
   changed" now that the document is its true size): a restyle of the inserted subtrees alone is the work a full pass
   does for them, without the rest; split `Computed` (2 808 bytes, copied from the initial style for every element) into
   what layout and paint read every frame and the rest.
4. **The layout's boxes as arrays of what the scans read** (the LCP scan's remaining cost is `box_border` reading each
   box's struct, 57 % of it; the layout-shift scan reads the same): border rects and flags in flat arrays by box, or
   scans of the boxes the layout journal says changed.
5. **The atlas lock per glyph and the word cache's 64 locks** (toolkit): a per-thread front, misses to one owner.
6. **The style index's string tables** (`style/engine.odin:66-68`): atoms (interned ids) and flat arrays by atom.
7. **The job queues of the blocking pool, the image decoders, the script compiler and the caches** (the table above):
   measured first (round 3: a lock-free queue lost to the loop's mutex); a worker's `ordered_remove(0)` is a cost of its own.
8. **The profiler**: sample the threads that ran (their cycle counters) rather than all ninety in turn, and correct the
   bias of samples taken in a system call; the style threads, where most of a style pass runs, are barely seen.
