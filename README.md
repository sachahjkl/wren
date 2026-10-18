# wasm_browser

A browser where WebAssembly is the only execution engine. No JavaScript, no glue layer: web APIs are Wasm imports
resolved by the browser itself. Written in Odin on top of [gui_toolkit](https://github.com/sachahjkl/gui_toolkit);
Windows first, platform services used wherever they exist (WinHTTP for HTTP/TLS, DirectWrite-class text later, D3D11).

    build.bat                      # build\browser.exe  (builds the Wasm runtime and Lexbor on first use)
    build\browser.exe file:///S:/wasm_browser/examples/site/index.html
    powershell -File tools\test_all.ps1 [-Quick]

Needs: Odin (`dev-2026-10`), Visual Studio 2022 (MSVC, for WAMR), Go (only for the test server). Dependencies are
pinned submodules: `ext/gui_toolkit` (tag v0.3.2), `ext/lexbor` (v3.0.1) and `ext/wamr` (WAMR, a commit after 2.4.5 that has the instruction
limit fix for the MSVC build).

## Layout

| Path | Role |
|---|---|
| `src/base` | `Scope` (ownership tree with cleanups) and `Pool` (generational handles, stable pointers) |
| `src/host` | the event loop: thread-safe posts with coalesced wakes, timers (min-heap), `run_ready`, `loop_wait` |
| `src/net` | HTTP(S) on WinHTTP async: per-host/global queues with priorities, back-pressure, caps, cancellation |
| `src/wasm` | WAMR bindings + `Instance` (instruction budget per call, memory cap, validated pointers) |
| `src/html` | HTML5 parsing: Lexbor (tokenizer + tree builder) through a C shim that replays the tree as events; `<title>`, Wasm script discovery |
| `src/dom` | document tree, attributes, listeners, capture/target/bubble dispatch |
| `src/page` | one document = DOM + Wasm instance + its requests and timers; the import tables (`bindings.odin`) |
| `src/browser` | the shell: tabs, address bar, console strip, placeholder painter (`render.odin`) |
| `sdk/odin/web` | guest-side bindings for Odin (`freestanding_wasm32`); other languages get generated ones |
| `examples/` | guest pages: `hello` (imports + budget), `e2e` (DOM, events, timers, fetch) |
| `tools/` | WAMR build, test server (Go), stress and screenshot scripts |

## The rules that keep it from breaking at scale

1. **One ownership tree.** process → tab → navigation → page → (instance, DOM, requests, timers). Everything a page
   starts is registered in its scope; closing a tab or navigating is `scope_close`. Cleanups run newest first, children
   before parents, so nothing outlives what it points to. Scopes are main-thread only.
2. **Handles, never pointers, cross boundaries.** `Handle = generation << 32 | index`, 0 is invalid. A destroyed or
   recycled slot fails to resolve. Late network events, timers and listener callbacks for dead objects are dropped, not
   delivered to reused memory. Pool objects never move (chunked), so `^T` stays valid until removed.
3. **Single UI thread, everything else posts.** WinHTTP's threads only push events into a queue and `host.post` once per
   burst; every user-visible callback runs on the loop thread. No locks in browser state.
4. **Bounded everything.** Per-host (6) and global (64) request limits with our own priority queues (so waiting never
   counts against connect timeouts); read pauses when 1 MB is queued for a request; `max_body` caps a response; guest
   memory is capped; every host→guest call has an instruction budget (a spinning script is stopped, the instance lives on).
5. **The guest cannot reach host memory.** Native signatures declare `(*~)` pointer+length pairs, validated by the runtime
   against the guest's linear memory before our code runs; strings are copied out through caller-provided buffers.
6. **No recursion on hostile depth.** Tree destruction, text extraction and searches are iterative (tested at 200k levels).

## Guest ABI (summary)

Imports are grouped by spec area (`dom`, `events`, `timers`, `net`, `console`) and named `Interface_member` like Web IDL.
Handles are `i64`; strings are `(ptr, len)` UTF-8; returned strings go to a `(ptr, cap)` buffer and the result is the
length needed; callbacks are function-table indices + an `i32` user value; errors are negative `i32`, handle-returning
functions return 0. See `src/page/bindings.odin` (host side) and `sdk/odin/web/web.odin` (guest side).

## Not done yet (in order of importance)

- The `<script type="application/wasm" src="...">` rule for naming a document's module is provisional (one module per
  page, first wins; it lives in `html.wasm_scripts` so it is easy to change). Charset sniffing is missing (UTF-8 assumed).
- Style and layout: the painter in `src/browser/render.odin` is a placeholder (blocks + wrapped text; no inline flow).
- Security: origin model, permissions, CORS-like rules for `Fetch_start`, cookies (WinHTTP's are disabled), cache.
- Redirects are followed by WinHTTP (10 max); the browser should own that policy.
- Text shaping (`vendor:kb_text_shape` is available in Odin), images (the renderer only has R8 atlas textures), IME.
- Wasm: interpreter only. AOT would need `wamrc`/LLVM; GC proposal and threads are disabled.
- Streaming bodies to the guest (collect mode only on the main resource; `Fetch_*` buffers the whole body).
