# Architecture

How Wren is put together, and the rules that keep it from breaking as it grows. For the overview, the build and the
feature list, see the [README](../README.md).

## The rules that keep it from breaking at scale

1. **One ownership tree.** process → tab → navigation → page → (instances, DOM, requests, timers). Everything a page
   starts is registered in its scope (`src/base/scope.odin`); closing a tab or navigating is `scope_close`. Cleanups
   run newest first, children before parents, so nothing outlives what it points to. Scopes are main-thread only.
2. **Handles, never pointers, cross boundaries.** `Handle = generation << 32 | index`, 0 is invalid. A destroyed or
   recycled slot fails to resolve. Late network events, timers and listener callbacks for dead objects are dropped,
   not delivered to reused memory. Pool objects never move (chunked), so `^T` stays valid until removed.
3. **Single UI thread, everything else posts.** The network stack's threads, the image decoders, the layout and style threads
   and the blocking pool only push events and `host.post` back to the loop; every user-visible callback runs on the
   loop thread. The DOM and the Wasm instances of a page live on the UI thread (workers have their own store).
4. **Mechanism and policy are separate.** `net` moves bytes and never follows a redirect, stores a cookie or sends
   ambient credentials. `fetch` decides, per hop, on the UI thread, with the document's Environment in hand. A guest, a
   module load and a navigation all go through the same code, so there is one place where "may this request happen"
   is answered.
5. **Bounded everything, with a reason each.** Per-host (6) and global (64) request limits in our own priority queues
   (so waiting never counts against connect timeouts); reading pauses when 1 MB is queued for a request; `max_body`
   caps a response; at most 20 redirects (the Fetch Standard's number); cookies: at most 180 per site and 3000 in
   total with LRU eviction; at most 1000 preflight cache entries; guest memory is capped; every host → guest call has
   a deadline (epoch interruption): a spinning script is stopped, the instance lives on. Every one of these numbers is
   a preference (`about:config`).
6. **The guest cannot reach host memory.** Every address + length pair of an import is checked by its generated
   trampoline against the guest's linear memory before our code runs; strings are copied out through caller-provided
   buffers.
7. **No recursion on hostile depth.** Tree destruction, text extraction, searches and the HTML replay are iterative.
8. **Everything is configurable.** Each package declares its preferences in a `settings.odin` (`config.Def`: dotted
   lower-case name, description, type, bounds, unit) and reads them through `settings_from_prefs`; the shell registers
   every table (`src/browser/settings.odin`) and `src/browser/prefs_test.odin` checks that each one is well formed.
9. **State lives with what owns it.** See below: what is one App's is not a global.

## Where state lives

The aim is several Apps (`browser.App`: one browser, its profile, its loop, its windows) in one process, each on a thread
of its own, so that tests run side by side in one binary. An App runs on one thread, the one that runs its loop
(`app_start`'s); its page thread works for it. So a global is allowed only for what it is, and
`tools/globals_allowed.txt` gives every global of `src/browser`, `src/page`, `src/style`, `src/layout`, `src/media` and
`src/js` its class (`src/tools/test_all/lint_globals.odin` fails on a new one, a gone one, or a class the code
contradicts):

- **const**: a table, written by the compiler or once (a `sync.Once`) before anything reads it. Any thread reads it.
- **process**: a resource there is one of whatever the number of Apps: the Wasm engine, a thread pool, a library of the
  system, the single-instance channel, an id unique in the process (atomic). Locked, atomic, or bound to a thread the
  note names.
- **thread**: `@(thread_local)`, and only then (the lint holds the class to the attribute both ways). In packages that
  have no App (`page`, `style`, `layout`), what is one App's is its thread's: the live pages, the navigables, the frames
  waiting to close (`page/web.odin`, `page/frames.odin`), `page.the_pages`. In `browser`, what the thread that paints
  keeps (the compositor's layers, the planes, the canvas text's glyphs) and `the_app`, the App of this thread.
- **test**: a test's own.

There is no class for one App's state (nor one window's, tab's or page's): it is a field of `App`, `Browser_Window.own`,
`Tab` or `Page`, and the lint fails on a global that is none of the above.

What belongs to the App is a field of `App` (`src/browser/main.odin`), reached through the `^App` the code is given.
A callback the App sets up carries it: a timer's or a watch's data, a job's struct (`Setup_Job.app`), a window
subclass's reference data (`app_commands_windows.odin`). `the_app` is what is left for code that has no `^App` yet,
mostly hooks of other packages (`page.Embedder_Hooks`, the canvas' text engine), the painting code and the developer tools'
drawing: a thread of its own sees nil.

What the App's pages share is `page.Pages` (`src/page/pages.odin`, `App.pages`): the embedder's hooks, the image cache,
the script compile service, the style threads, the profile's stores (Cache API, file system, service workers, Web Locks,
storage buckets, storage access decisions), the message ports, the shared workers, the statistics. The page package reaches it
through `page.the_pages`, bound by `page.bind` to the threads that run the App's pages: its loop's (`app_start`), its page
thread's (`page_thread.odin`), a worker's (`worker_main`, its creator's), a compile thread's. A program that embeds pages
without the shell (`src/tools/headless`, the web tests, `apiconformance`) binds its own; a page test binds one with
`test_pages(t)`.

What the Apps of the process share is set up by the first App to start and let go of by the last to end
(`src/browser/process_share.odin`: one atomic word, the Apps that use it or a busy mark while the first sets it up or the
last lets it go; whoever starts or ends meanwhile waits on it): the Wasm engine and its host functions, the bytecode cache,
the image decoders, the layout threads, the decoded web fonts, the crash session (`page.process_shutdown`). The first App's
preferences and profile configure them.

`src/tools/e2e/two_apps.odin` runs two Apps, each on a thread of its own, at once: each sees only its own tabs, pages,
storage, channel messages and frame, and nothing of either is left once both have stopped. The toolkit keeps the
interface state it draws with in one variable of the process (`ext/gui_toolkit/ui/state.odin`, `g`): until it is the
thread's (`@(private, thread_local) g: ^State`), the two Apps' own threads take turns between the test's meetings (what
they run besides runs at once); with that one change they run at once too.

## Wasm engine

Wasmtime, the official C API release **v49.0.3**, downloaded by `wrentool fetch wasmtime` (version and SHA-256
pinned in the script) into `build\wasmtime`; the static `wasmtime.lib` is linked into the exe (no DLL; it adds about
12 MB). It needs `ws2_32 advapi32 userenv ntdll shell32 ole32 bcrypt kernel32` and the C runtime, linked in as for every native library of Wren
(`libcmt libucrt libvcruntime`, the static C runtime that Odin's `core:c/libc` is: `wren.exe` needs no runtime DLL), declared in `src/wasm/wasmtime.odin`. Modules are compiled by Cranelift (or Winch,
`wasm.wasmtime.compiler`), kept in a memory cache and in an HMAC-authenticated disk cache of the profile
(`wasm-cache`), and every call from the host has a wall-clock deadline (`wasm.max_call_ms`, epoch interruption; with
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
- the Odin guest SDK, `sdk/odin/<package>/<module>.odin`, the `wren` collection (`import "wren:dom"`; distinct handle
  types, `string` / `[]u8` / `Maybe`, `(T, Error)` results, `F` / `F_len` / `F_alloc` for strings of unknown size);
- the documentation, `docs/api/` (with the ABI);
- conformance tests: `examples/apiconformance` and `src/tools/apiconformance/cases_generated.odin` (bad addresses,
  bad UTF-8, dead handles, enums out of range, buffers too small, for every function).

`build.bat` regenerates what changed; `test_all` fails when a generated file is out of date (`bindgen -check`).
Imports take 64-bit addresses in a module whose memory 0 is memory64 (`wasm.features.memory64`).

A document names its modules with `<script type="application/wasm" src="..." nonce="...">`, any number of them. They
are fetched concurrently and run in document order, each in its own instance sharing the DOM. (The syntax is one
function, `html.wasm_scripts`, if it ever changes.)

## JavaScript

JavaScript is one more Wasm guest, not a second engine beside Wasm. The engine is written in Odin (`src/engine`): a
front-end that compiles source to QuickJS-ng 0.17 bytecode, the interpreter (`jsrt`, with a hot loop of its own and a loop
JIT that compiles hot loops to Wasm at run time: numbers, properties guarded by shapes, small callees inlined,
natives called; [engine/jit.md](engine/jit.md)), and the numeric, Unicode, regexp and date libraries. `jscapi` gives it
the QuickJS C API, which the glue (`native/js/odin`, all Odin) is written against; the web platform's objects are
hand-written members plus bindings generated from the Web IDL of webref (`src/tools/bindgen`, package `jsgen`, into
`native/js/odin/bindings_gen.odin`). `src\tools\buildjs` compiles it all to one wasm32 module (Odin, linked by Odin's own `wasm-ld`, no C library:
no C of ours is compiled) and pre-initializes it at build time (`src/wasm/preinit.odin`: interfaces,
prototypes and preludes already built in the memory image); the image is embedded in the exe (`src/js/image`). Each page
and each JavaScript worker gets its own instance (a realm), whose
imports are the same `api/*.widl` functions Wasm pages use, plus `js*.widl` for what only the engine needs. So the
limits of every guest apply: Wasmtime's sandbox, the memory cap, epoch interruption (`wasm.max_call_ms`), on top of
the engine's own (`javascript.max_heap_bytes`, `javascript.slow_script_ms`). A trap loses the realm (the status bar says
`JS stopped`), never the browser. Wrappers hold their DOM nodes; wrappers of one DOM tree are grouped at each
collection so that a detached tree nothing holds is freed (`src/page/js_realm.odin`). Script loading
(`src/page/js_load*.odin`) follows HTML's processing model. Details: [`native/js/README.md`](../native/js/README.md); coverage:
[`docs/js/coverage.md`](js/coverage.md).

## Image and font decoders

`src/images` decodes on its own threads, never on the interface thread. Every format but HEIF is decoded by the crate
`native\media`, part of Wren's one Rust static library (see "The Rust library" below), the same on every system; HEIF
goes through the platform (WIC, when the Store codec is installed), and `images.decode.system_codecs` hands PNG, JPEG,
GIF, BMP, ICO and TIFF to WIC as before (`src/images/parity_test_windows.odin` compares both on every fixture):

- **PNG / APNG, JPEG, GIF, BMP, ICO, TIFF**: image 0.25.10 (png, zune-jpeg, gif, tiff; `native/media/src/raster.rs`):
  EXIF orientation, ICC profiles, GIF and APNG animation composed by the decoder, the ICO entry that fits the size
  shown; PNG and JPEG encoding for the canvas.

- **SVG**: resvg 0.48.1 (usvg + tiny-skia; text with the system fonts through fontdb). Rendered at the size it is
  shown at (device pixels), in the secure static mode of SVG images (no external resource, script or animation);
  hostile documents are bounded by `images.svg.*` (nodes, depth, entity and `<use>` expansion, rendering cost). Inline
  `<svg>` elements of HTML documents are drawn by the same renderer (`src/page/inline_svg.odin`); the HTML of their
  `<foreignObject>` elements is laid out and painted by Wren's own layout, in the SVG's coordinate space: the viewBox
  mapping, nested `<svg>` viewports and the transforms around it, its `<clipPath>`s (user space or bounding box units,
  intersected) as a polygon clip, `feGaussianBlur` filters as `blur()` (`src/layout/foreign_object.odin`). The picture
  is drawn in parts split at the foreign objects, so that shapes drawn after one cover it (`Svg_Parts`). An inline
  `<svg>` clips to its viewport (`svg:not(:root) { overflow: hidden }`). Not yet: other filters, the clip of a nested
  viewport.
- **WebP**: image-webp 0.2.4 (pure safe Rust: lossy, lossless, alpha, animation).
- **AVIF**: zenavif-parse 0.6.2 (container: alpha, grids, sequences, colr / irot / imir / clap) + rav1d 1.1.0 (the
  Rust port of dav1d, with dav1d's assembly: NASM 2.16.03 is fetched and checked by SHA-256 by the script).
- **Colour**: qcms 0.3.0 (Firefox's): ICC profiles of every format, AVIF's CICP code points and EXIF's Adobe RGB to
  sRGB (`images.color_management`).
- **WOFF2** web fonts: brotli-decompressor 6.1.0, then the glyf / loca / hmtx transforms reversed
  (`native/media/src/woff2.rs`, used by `src/webfont`).

Every crate is pinned (see below). `wrentool gen media-fixtures` (ImageMagick, FFmpeg) made the AVIF / WebP test files of `examples\site\media`;
`src\tools\mediabench` times decodes.

## The Rust library (`native/`)

A program links one Rust static library at most: each carries its own copy of Rust's standard library, and two built
by the same compiler define the same symbols. So all of Wren's Rust code is one Cargo workspace, `native/`, with one
`Cargo.lock`, one target directory (`build\native\target`) and one output, `build\native\wren_native.lib`
(`wrentool build native`, run by `build.bat`; nothing is done when `build\native\STAMP` matches the sources):

- `native/media` (crate `wren_media`, a library): the image decoders and WOFF2 above (`src/images`, `src/webfont`).
- `native/net` (crate `wren_net`): the network stack (`src/net/rust.odin`, see "Network" below).
- The toolkit's crates, path dependencies that stay in the toolkit: `ext/gui_toolkit/native/text` (`gt_text`, the
  native text backend; feature `text`, left out of a `WREN_TEXT=dwrite` build) and `ext/gui_toolkit/native/a11y`
  (`gt_a11y`, AccessKit; feature `a11y`). The toolkit is built with `-define:FONT_NATIVE_LINK=false
  -define:A11Y_NATIVE_LINK=false`: it links nothing of its own.
- `native/wren_native`, the assembly crate (a `staticlib` with no code): it picks the libraries, and their C functions
  (`wm_*`, `wn_*`, `gt_*`) are exported from it.

Two Cargo profiles, with the same code generation for each crate (`opt-level = 3`, one codegen unit, `panic =
"unwind"`: every entry point catches panics):

- `release` (`build.bat release` and `profile`: what is shipped, and measured as shipped): fat LTO, the whole graph
  optimized as one module. A change in any crate runs that step again over all of them (a minute or more).
- `quick` (`build.bat`, `debug`, `check`, the CI): no LTO, each crate's objects go into the archive as they are. A
  change in one crate rebuilds that crate and the archive: touching the accessibility adapter recompiles neither the
  decoders nor the text backend (7 s against 65 s). Measured against `release` on 2026-10-27: decoding as fast (WebP,
  AVIF, SVG, WOFF2 within 3 %), shaping 2 to 5 % slower, the exe 0.6 MB larger.

Both stay compiled in `build\native\target`; switching between them copies the library. The CI caches the compiled
crates by profile and `Cargo.lock` (`.github/actions/setup`): a run whose `Cargo.lock` did not change compiles only
the workspace's and the toolkit's crates.

Why not a DLL per library (`cdylib`): measured, the adapter's DLL is 0.6 MB and the text backend's 2.4 MB (each with
its own standard library), loading one costs 2 to 3 ms (40 ms the first time a new file is scanned), and each DLL is
one more file to sign, ship and keep in step with the exe; `wren.exe` needs no file beside it, and stays so.

Every crate is pinned by exact version in its `Cargo.toml` and by SHA-256 in `native\Cargo.lock` (`--locked`);
`wrentool gen rust-crates` writes the list `about:licenses` shows (`native\rust-crates.txt`). Wasmtime's library carries
a standard library of another compiler: its mangled symbols differ, and the one unmangled symbol both define
(`rust_eh_personality`, unused on MSVC) is renamed in ours with `llvm-objcopy`.

## Network

Package `net` is the transport: queues per priority, per-host and global limits, throttling (DevTools), generational
handles, scopes, back-pressure, the `Headers` / `Data` / `Done` / `Failed` events, WebSockets' state machine. Under it,
one of two stacks (`network.backend`, overridden by the `WREN_NET_BACKEND` environment variable):

- `rust` (the default): `native/net`, the same on every platform. tokio threads of its own; hyper-util's pooled client
  over our connector (the system resolver, TCP attempts staggered by 250 ms, the system proxy: environment, Windows
  registry, macOS configuration, with a CONNECT tunnel for https and WebSockets), HTTP/1.1 and HTTP/2 by ALPN; rustls
  (ring) with rustls-platform-verifier: the system's trust store and policy, plus `network.tls.extra_ca_file`; gzip,
  deflate and Brotli decoded as the body streams; WebSockets on tungstenite over an HTTP/1.1 upgrade. HTTP/3 (quinn +
  h3) for an origin that announced it (Alt-Svc): the request that opens the QUIC connection waits for it
  `network.http3.race_ms` at most, then goes over TCP; the others use QUIC only once it is up; an origin where QUIC
  failed is left to TCP for `network.http3.broken_host_ms`. Results wait in the library's queue; one notification per
  burst posts `net`'s drain to the loop, which takes them one by one (`wn_net_poll`) and copies what it keeps: no
  allocation of ours on a library thread, no memory of the library freed by us. Proxy auto-configuration scripts (PAC)
  are not run: where the system proxy names one, the client uses WinHTTP.
- `winhttp`: WinHTTP's asynchronous mode (Windows only). Never HTTP/3: WinHTTP does not fall back to TCP where QUIC does
  not get through.

Errors keep WinHTTP's numbers (12002 timeout, 12007 name, 12029 connect, 12030 lost, 12152 invalid answer, 12175 /
12037 / 12038 / 12045 certificates with WinHTTP's secure flags) whichever stack ran the request. `src/tools/e2e/web_net.odin`
runs the transport on both; `WREN_NET_BACKEND=rust|winhttp` makes a web test run by hand use one.

## Security model

- **Origins.** `scheme://host:port`, or an opaque origin equal only to itself (`file:`, `data:`, redirect-tainted
  requests). Sites use the Public Suffix List (`github.io` is a suffix; `localhost` and IPs have no registrable
  domain).
- **Requests** carry an Environment: `Request_Desc.initiator` is the document asking (nil = the address bar). Modes:
  `navigate`, `same-origin`, `no-cors` (opaque response: status 0, no headers, no body for scripts) and `cors`.
- **CORS**: Origin header, ACAO / ACAC checks, header exposure filtering, preflights with the spec's rules
  (safelisted methods and headers, `*` never covering `Authorization`, wildcard disabled with credentials), preflight
  cache with max-age. Cross-origin Wasm modules need CORS; modules must be `application/wasm`.
- **Cookies**: stored and sent only by `fetch` (WinHTTP's are off). `Secure` needs a secure context (localhost
  counts), `__Secure-` / `__Host-` prefixes, `SameSite` (default Lax, `None` needs `Secure`), HttpOnly invisible to
  scripts, "leave Secure cookies alone", Domain checked against the PSL. **Third-party cookies are blocked by
  default**. `document.cookie` exists only for tuple origins.
- **HSTS**, **referrer policy** (header, `<meta>`, per request), **mixed content** (blocked; images auto-upgraded),
  **bad ports**, **Fetch Metadata** headers (`Sec-Fetch-*`), **CSP** (headers and `<meta>`, report-only,
  `upgrade-insecure-requests`, `block-all-mixed-content`; `script-src` governs Wasm modules, `worker-src` workers).
- **Local files**: a `file:` document may read files in its own directory tree and nothing else; web pages never read
  local files; only the address bar may open any file.

## Web Authentication (passkeys)

`src/webauthn` is the client of Web Authentication Level 3 without the page: the options in their standard JSON form
(what a server sends, what `navigator.credentials.create()` / `get()` serialize a dictionary to), the RP ID (a
registrable domain suffix of the document's domain, Public Suffix List of `src/url`), the exact bytes of
`clientDataJSON`, the ceremony timeout, extensions, `toJSON()`, and CBOR / COSE for `getPublicKey()` (DER
SubjectPublicKeyInfo). The authenticators are the operating system's, behind an interface (`Platform`): on Windows
`webauthn.dll` (Windows Hello, security keys, a phone over hybrid, the passkey managers Windows knows), loaded on first
use and used up to the API version the system has; its dialog belongs to the browser's window. A software authenticator
(`virtual.odin`, ES256 through BCrypt, keys in memory) replaces it for automated tests only. `src/page/bindings_webauthn.odin`
adds the page's conditions (secure context, a recent click or key press, the tab shown in the focused window, one
ceremony at a time) and runs the blocking platform call on a thread of its own; the window stays responsive and draws
nothing while the user answers, the address bar shows a chip (click: cancel). Aborts, the lifetime timer and the page
closing cancel the system's operation; if the system does not give it back within `security.webauthn.cancel_grace_ms`,
the page is answered anyway and the exit does not wait for it. Nothing about credentials is logged.

## Rendering pipeline

DOM mutations and style changes are journaled (`src/dom/journal.odin`, `src/style/journal.odin`). A frame runs, as
needed: the style pass (full, in parallel on large documents, or a partial restyle from invalidation sets), the layout
pass (refresh, incremental or full; `layout.incremental.verify` checks an incremental pass against a full one), the
display list, then the compositor (`src/browser/compositor.odin`), which records the display list into retained
pictures of the toolkit's draw layer and replays them every frame: scrolling and transform animations only change
matrices. The painter (`src/browser/render.odin`) maps the display list onto draw's transform, clip and layer stacks
(filters, blend modes, backdrops, masks). Frames are paced on the display's refresh by the toolkit's cadence model (`platform/pacing.odin`, its `docs/pacing.md`: one decision per frame), which `src/browser/pacing.odin` executes.
