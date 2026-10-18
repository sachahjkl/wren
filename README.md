# wasm_browser

A browser where WebAssembly is the only execution engine. No JavaScript, no glue layer: web APIs are Wasm imports
resolved by the browser itself. Written in Odin on top of [gui_toolkit](https://github.com/sachahjkl/gui_toolkit);
Windows first, platform services used wherever they exist (WinHTTP for HTTP/TLS, D3D11 for drawing).

    build.bat                      # build\browser.exe  (builds the Wasm runtime and Lexbor on first use)
    build\browser.exe http://127.0.0.1:8765/site/index.html      (run build\testserver.exe first), or a file:/// URL
    powershell -File tools\test_all.ps1 [-Quick]

Needs: Odin (`dev-2026-10`), Visual Studio 2022 (MSVC, for WAMR and Lexbor), Go (only for the test server). Dependencies
are pinned submodules: `ext/gui_toolkit` (tag v0.3.2), `ext/lexbor` (v3.0.1) and `ext/wamr` (a commit after 2.4.5 that has
the instruction-limit fix for the MSVC build). The Public Suffix List is embedded (`tools/update_psl.ps1` refreshes it).

## Layout

| Path | Role |
|---|---|
| `src/base` | `Scope` (ownership tree with cleanups) and `Pool` (generational handles, stable pointers) |
| `src/host` | the event loop (thread-safe posts with coalesced wakes, timers) and a blocking-work pool (file reads) |
| `src/net` | transport: HTTP(S) on WinHTTP async, per-host/global queues, back-pressure, caps, cancellation. *No policy.* |
| `src/url` | WHATWG URLs (Lexbor), origins, sites, Public Suffix List, secure contexts |
| `src/http` | header lists, forbidden / CORS-safelisted names and methods, MIME types |
| `src/cookies` | the cookie jar (RFC 6265bis): parsing, storage model, SameSite, prefixes, eviction, persistence |
| `src/csp` | Content Security Policy 3: parsing, source matching, fallbacks, nonces, report-only |
| `src/fetch` | **the policy layer** (Fetch Standard): modes, CORS + preflight cache, credentials, redirects, HSTS, referrer policy, mixed content, schemes (http, file, data), MIME checks, response filtering |
| `src/wasm` | WAMR bindings + `Instance` (instruction budget per call, memory cap, validated pointers) |
| `src/html` | HTML5 parsing (Lexbor through a C shim), charset sniffing and decoding, `<title>`, Wasm script discovery |
| `src/dom` | document tree, attributes, listeners, capture/target/bubble dispatch |
| `src/page` | one document = DOM + its Wasm instances + its requests and timers + its Environment (origin, CSP, referrer policy); the import tables (`bindings*.odin`) |
| `src/browser` | the shell: tabs, navigation, address bar, console strip, placeholder painter (`render.odin`) |
| `src/shim` | C shims over Lexbor (HTML events, URL parser, encodings) |
| `sdk/odin/web` | guest-side bindings for Odin (`freestanding_wasm32`); other languages get generated ones |
| `examples/` | guest pages: `hello`, `e2e` (DOM, events, timers, fetch, cookies, origin), `counter` + `site/` (an HTML page that names its module) |
| `tools/` | WAMR / Lexbor builds, test server (Go), stress, test and screenshot scripts |

## The rules that keep it from breaking at scale

1. **One ownership tree.** process → tab → navigation → page → (instances, DOM, requests, timers). Everything a page
   starts is registered in its scope; closing a tab or navigating is `scope_close`. Cleanups run newest first, children
   before parents, so nothing outlives what it points to. Scopes are main-thread only.
2. **Handles, never pointers, cross boundaries.** `Handle = generation << 32 | index`, 0 is invalid. A destroyed or
   recycled slot fails to resolve. Late network events, timers and listener callbacks for dead objects are dropped, not
   delivered to reused memory. Pool objects never move (chunked), so `^T` stays valid until removed.
3. **Single UI thread, everything else posts.** WinHTTP's threads and the blocking pool only push events and `host.post`
   once per burst; every user-visible callback runs on the loop thread. No locks in browser state.
4. **Mechanism and policy are separate.** `net` moves bytes and never follows a redirect, stores a cookie or sends ambient
   credentials. `fetch` decides, per hop, on the UI thread, with the document's Environment in hand. A guest, a module
   load and a navigation all go through the same code, so there is one place where "may this request happen" is answered.
5. **Bounded everything, with a reason each.** Per-host (6) and global (64) request limits in our own priority queues (so
   waiting never counts against connect timeouts); reading pauses when 1 MB is queued for a request; `max_body` caps a
   response; ≤ 20 redirects (the Fetch Standard's number); cookies ≤ 180 per site and 3000 total (browser norm) with LRU
   eviction; preflight cache ≤ 1000; fetch records a page may hold ≤ 1 GiB; guest memory is capped; every host→guest call
   has an instruction budget (a spinning script is stopped, the instance lives on).
6. **The guest cannot reach host memory.** Native signatures declare `(*~)` pointer+length pairs, validated by the runtime
   against the guest's linear memory before our code runs; strings are copied out through caller-provided buffers.
7. **No recursion on hostile depth.** Tree destruction, text extraction, searches and the HTML replay are iterative.

## Security model

- **Origins.** `scheme://host:port`, or an opaque origin equal only to itself (`file:`, `data:`, redirect-tainted
  requests). Sites use the Public Suffix List (`github.io` is a suffix; `localhost`, IPs have no registrable domain).
- **Requests** carry an Environment: `Request_Desc.initiator` is the document asking (nil = the address bar). Modes:
  `navigate`, `same-origin`, `no-cors` (opaque response: status 0, no headers, no body for scripts) and `cors`.
- **CORS**: Origin header, ACAO / ACAC checks, header exposure filtering, preflights with the spec's rules (safelisted
  methods and headers, `*` never covering `Authorization`, wildcard disabled with credentials), preflight cache with
  max-age. Cross-origin Wasm modules need CORS; modules must be `application/wasm`.
- **Cookies**: stored and sent only by `fetch` (WinHTTP's are off). `Secure` needs a secure context (localhost counts),
  `__Secure-` / `__Host-` prefixes, `SameSite` (default Lax, `None` needs `Secure`), HttpOnly invisible to scripts,
  "leave Secure cookies alone", Domain checked against the PSL. **Third-party cookies are blocked by default**
  (`Profile.third_party_cookies`). `document.cookie` exists only for tuple origins.
- **HSTS**, **referrer policy** (header, `<meta>`, per request), **mixed content** (blocked; images auto-upgraded),
  **bad ports**, **Fetch Metadata** headers (`Sec-Fetch-*`), **CSP** (headers and `<meta>`, report-only, `upgrade-insecure-requests`,
  `block-all-mixed-content`; `script-src` governs Wasm modules).
- **Local files**: a `file:` document may read files in its own directory tree and nothing else; web pages never read
  local files; only the address bar may open any file.

## Guest ABI (summary)

Imports are grouped by spec area (`dom`, `events`, `timers`, `net`, `document`, `console`) and named `Interface_member` like
Web IDL. Handles are `i64`; strings are `(ptr, len)` UTF-8; returned strings go to a `(ptr, cap)` buffer and the result is
the length needed; callbacks are function-table indices + an `i32` user value; errors are negative `i32`, handle-returning
functions return 0. `Fetch_start` takes packed Fetch API options (mode, credentials, redirect, referrer policy). See
`src/page/bindings*.odin` (host side) and `sdk/odin/web/web.odin` (guest side).

A document names its modules with `<script type="application/wasm" src="..." nonce="...">`, any number of them. They are
fetched concurrently and run in document order, each in its own instance sharing the DOM. (The syntax is one function,
`html.wasm_scripts`, if it ever changes.)

## Not done yet

- **HTTP cache** (RFC 9111): every request goes to the network. `Request_Desc` has no cache mode yet.
- Style and layout: `src/browser/render.odin` is a placeholder (blocks, inline flow, default styles; no CSS). Lexbor's
  CSS parser and selectors are compiled in and unused so far.
- CSP violation *reporting* (`report-uri` / `report-to`): violations go to the console only. No SRI (`integrity=`).
- HTTP authentication (401), downloads (`Content-Disposition`), `blob:` URLs, WebSocket, cookie partitioning (CHIPS).
- Text shaping (`vendor:kb_text_shape` is available in Odin), images (the renderer only has R8 atlas textures), IME.
- Wasm: interpreter only. AOT would need `wamrc`/LLVM; GC proposal and threads are disabled.
- Streaming bodies to the guest: `Fetch_*` buffers the response (bounded by `max_body` and the per-page ceiling).
