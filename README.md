# wasm_browser

A browser where WebAssembly is the only execution engine. No JavaScript, no glue layer: web APIs are Wasm imports
resolved by the browser itself. Written in Odin on top of [gui_toolkit](https://github.com/sachahjkl/gui_toolkit);
Windows first, platform services used wherever they exist (WinHTTP for HTTP/TLS, D3D11 for drawing).

    build.bat                      # build\browser.exe  (fetches Wasmtime, builds Lexbor and the image decoders on first use)
    build\browser.exe http://127.0.0.1:8765/site/index.html      (run build\testserver.exe first), or a file:/// URL
    powershell -File tools\test_all.ps1 [-Quick]

Needs: Odin (`dev-2026-10`), Visual Studio 2022 (MSVC, for Lexbor), Rust (rustup, stable >= 1.93, for the image decoders; its
`llvm-tools` component is added on first build), Go (only for the test server). Dependencies are pinned submodules:
`ext/gui_toolkit` and `ext/lexbor` (v3.0.1), plus the Wasmtime C API (see *Wasm engine*). The Public Suffix List is embedded
(`tools/update_psl.ps1` refreshes it).

## Wasm engine

Wasmtime, the official C API release **v49.0.3**, downloaded by `tools\fetch_wasmtime.ps1` (version and SHA-256 pinned
in the script) into `build\wasmtime`; the static `wasmtime.lib` is linked into `browser.exe` (no DLL; it adds about
12 MB). It needs `ws2_32 advapi32 userenv ntdll shell32 ole32 bcrypt kernel32` and the dynamic CRT
(`msvcrt ucrt vcruntime`), declared in `src/wasm/wasmtime.odin`. Modules are compiled by Cranelift (or Winch,
`wasm.wasmtime.compiler`), kept in a memory cache and in an HMAC-authenticated disk cache of the profile (`wasm-cache`),
and every call from the host has a wall-clock deadline (`wasm.max_call_ms`, epoch interruption; with
`wasm.wasmtime.fuel`, also an instruction budget). `src/tools/wasmbench` compares the compiler configurations and
measures host calls.

## The web API: one description, everything generated

Every Wasm import of the browser is described once, in `api/*.widl` (a dialect of Web IDL: modules, functions, typed
handles, enums, flags, structs, callbacks, `raises`, `[Exposed=Window|Worker]`, documentation). `src/tools/bindgen`
generates from it, deterministically:

- the host side, `src/page/api_generated.odin`: one trampoline per import, defined directly on the Wasmtime linker,
  which checks every address against the module's memory, converts strings (UTF-8 checked), handles (looked up by
  kind), enums, flags and structs, and calls the implementation (`bindings_*.odin`) with Odin values. The expected
  prototype of each implementation is written above its trampoline: a missing or mistyped one does not compile;
- the Odin guest SDK, `sdk/odin/web/<module>.odin` (distinct handle types, `string` / `[]u8` / `Maybe`, `(T, Error)`
  results, `F` / `F_len` / `F_alloc` for strings of unknown size);
- the documentation, `docs/api/` (with the ABI);
- conformance tests: `examples/apiconformance` and `src/tools/apiconformance/cases_generated.odin` (bad addresses, bad
  UTF-8, dead handles, enums out of range, buffers too small, for every function).

`build.bat` regenerates what changed; `test_all.ps1` fails when a generated file is out of date (`bindgen -check`).
Imports take 64-bit addresses in a module whose memory 0 is memory64 (`wasm.features.memory64`).

## Image decoders

`src/images` decodes on its own threads, never on the interface thread. PNG, JPEG, GIF, BMP, ICO and TIFF go through the
platform (WIC; HEIF too when the Store codec is installed). WebP, AVIF and SVG are always available, whatever Windows has
installed, through a Rust static library built by `tools\build_media.ps1` from `native\media` (rebuilt only when its
sources change; about 6 MB added to `browser.exe`, 1.5 min the first time):

- **SVG**: resvg 0.48.1 (usvg + tiny-skia; text with the system fonts through fontdb). Rendered at the size it is shown at
  (device pixels), in the secure static mode of SVG images (no external resource, script or animation); hostile documents
  are bounded by `images.svg.*` (nodes, depth, entity and `<use>` expansion, rendering cost). Inline `<svg>` elements of
  HTML documents are drawn by the same renderer (`src/page/inline_svg.odin`).
- **WebP**: image-webp 0.2.4 (pure safe Rust: lossy, lossless, alpha, animation).
- **AVIF**: zenavif-parse 0.6.2 (container: alpha, grids, sequences, colr / irot / imir / clap) + rav1d 1.1.0 (the Rust
  port of dav1d, with dav1d's assembly: NASM 2.16.03 is fetched and checked by SHA-256 by the script).
- **Colour**: qcms 0.3.0 (Firefox's): ICC profiles of every format, AVIF's CICP code points and EXIF's Adobe RGB to sRGB
  (`images.color_management`).

Every crate is pinned by exact version in `native\media\Cargo.toml` and by SHA-256 in `Cargo.lock` (`--locked`). Both
Rust libraries (Wasmtime's and this one) carry a standard library: the script renames the one duplicated unmangled symbol
(`rust_eh_personality`, unused on MSVC) in ours with `llvm-objcopy`. `tools\gen_media_fixtures.ps1` (ImageMagick, FFmpeg)
made the AVIF / WebP test files of `examples\site\media`; `src\tools\mediabench` times decodes.

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
| `src/wasm` | the Wasm engine (Wasmtime): instances, host functions on the linker with address checks (memory64 too), deadlines, limits, compiled-code caches |
| `src/html` | HTML5 parsing (Lexbor through a C shim), charset sniffing and decoding, `<title>`, Wasm script discovery |
| `src/dom` | document tree, attributes, listeners, capture/target/bubble dispatch |
| `src/page` | one document = DOM + its Wasm instances + its requests and timers + its Environment (origin, CSP, referrer policy); the implementations of the imports (`bindings*.odin`) behind the generated trampolines (`api_generated.odin`) |
| `src/browser` | the shell: tabs, navigation, address bar, console strip, placeholder painter (`render.odin`) |
| `src/shim` | C shims over Lexbor (HTML events, URL parser, encodings) |
| `api/` | the description of the web API (`*.widl`), source of the bindings, SDK, docs and conformance tests (`src/tools/bindgen`) |
| `sdk/odin/web` | the generated guest SDK for Odin (`freestanding_wasm32`) |
| `docs/api` | the generated API reference |
| `examples/` | guest pages: `hello`, `e2e` (DOM, events, timers, fetch, cookies, origin), `counter` + `site/` (an HTML page that names its module) |
| `src/images` | image decoding on threads: WIC, and the built-in SVG / WebP / AVIF decoders and colour management (`native/media`, Rust) |
| `native/media` | the Rust static library of the built-in image decoders (resvg, image-webp, zenavif-parse, rav1d, qcms) |
| `tools/` | Wasmtime fetch, Lexbor and image decoder builds, test server (Go), stress, test, perf and screenshot scripts |

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
   has a deadline (epoch interruption): a spinning script is stopped, the instance lives on.
6. **The guest cannot reach host memory.** Every address+length pair of an import is checked by its generated trampoline
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
- Wasm: threads and shared memory are off (each worker has its own store and memory); GC is available but off by default.
- Streaming bodies to the guest: `Fetch_*` buffers the response (bounded by `max_body` and the per-page ceiling).
