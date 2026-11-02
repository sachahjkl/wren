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

**Bottleneck:** the script stage (JS interpreter and the DOM bindings), then layout.

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

## What changed this round

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
(`node_items`, a heap list per node) and `:421-556` (per rebuild); `page/images.odin:1217` and `page/fonts.odin:111`
(walk every computed style after each style pass); `ext/gui_toolkit/font/raster.odin:74-79` (per glyph, under the atlas
lock). Gone this round: `page/timeline_lcp.odin` `ls_prev` (per box, per mutated frame).

### Arrays of bools

Per box or element, per pass: `layout/context.odin:53` (`plain`), `layout/finish.odin:37,81`, `layout/effects.odin:45`,
`layout/incremental.odin:563`, `layout/query.odin:91` (`View.singular`, per frame), `style/cascade.odin:349`
(`gate_probe`), `style/engine.odin:119-120`, `browser/compositor.odin:450,763`, `browser/effects_cache.odin:54,65`;
`map[...]bool` used as sets: `style/match.odin:56,64`, `style/engine.odin:68`, `style/restyle_dom.odin:144-147`,
`font/raster.odin:76-77` (per glyph); `draw/bsp.odin:241` (n x n per 3D sort).

### Mutexes (51 in Wren, 17 in the toolkit, outside tests)

The ones on a per-frame or per-item path, and what fits instead:

| where | guards | threads | instead |
|---|---|---|---|
| `font/raster.odin:72` `Atlas.mu` | glyph maps, atlas pages, Slug store; rasterizes under it | every drawing thread, the color-glyph thread | per-thread lookup front, misses to a raster owner over an MPSC queue |
| `font/shape.odin:398` `Word_Shard.mu` x 64 | shaped words; glyphs copied out under it | layout threads, page, chrome paint | goes with the word cache |
| `style/invalidation.odin:454` `Key_Sets.mu` | interned selector keys, process-wide | every page's style engine | per-engine tables |
| `host/loop.odin:46` `Loop.mu` | posted tasks | any thread -> the loop | MPSC queue |
| `host/thread_pool.odin:17` | `parallel_for`'s generation | caller and workers | atomic generation and a futex wake |
| `net/client.odin:165`, `net/websocket.odin:184` | events to the loop | network threads -> loop | MPSC queue |
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
third of its samples); per-pass arena reservation and release in style (`NtFreeVirtualMemory` from `arena_destroy`, 11 %
of the style stage on nodes10k: `style/cascade.odin:130,162,875`). Most of layout and paint already use the temporary
allocator or an arena.

## Next, ranked by measured cost on a bottleneck

1. **Node lifetime and handle indices on DOM-heavy scripts** (nodes10k: 580 000 styled entries for 12 500 boxes, 40 full
   restyles in 26 s, 1.1 GB): a removed node that no script holds should give its index back at once (generation in the
   upper bits of the handle already says when an index is reused), so the by-node arrays of style and layout stay the
   size of the document.
2. **The layout thread's heap growth** (a third of its samples on nodes10k): inline-capacity lists or the layout arena for
   the per-box lists of inline segments.
3. **Style: the arena per pass and the copy per element** (`NtFreeVirtualMemory` 11 %, `build_style`'s `memcpy` the top
   function of the style threads): keep the thread arenas from pass to pass; split `Computed` into what layout and paint
   read every frame and the rest.
4. **The Largest Contentful Paint and Element Timing scan** (`timeline_present`, 15 % of a mutated frame on a 16 000-box
   page; it runs at every scrolled frame too while Element Timing is on): once LCP has stopped, visit only elements with an
   `elementtiming` attribute (an index of them, kept by the DOM's attribute changes).
5. **Whole-document walks after each style pass** (`page/images.odin:1217` `css_images_sync`, `images_sync`,
   `page/fonts.odin:111`: 3 to 6 % of the window thread on both script pages): driven by the restyle journal instead.
6. **The atlas lock per glyph and the word cache's 64 locks** (toolkit): a per-thread front, misses to one owner.
7. **The style index's string tables** (`style/engine.odin:66-68`): atoms (interned ids) and flat arrays by atom.
8. **`Loop.mu` and the network event mutexes**: MPSC queues.
9. **The profiler**: sample the threads that ran (their cycle counters) rather than all ninety in turn, and correct the
   bias of samples taken in a system call.
