<p align="center"><img src="assets/logo_256.png" width="128" alt="Wren logo"></p>

<h1 align="center">Wren</h1>

<p align="center">
<a href="https://github.com/sachahjkl/wren/actions/workflows/ci.yml"><img src="https://github.com/sachahjkl/wren/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/sachahjkl/wren/releases/latest"><img src="https://img.shields.io/github/v/release/sachahjkl/wren?color=ffb84d" alt="latest release"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-1d57ba" alt="MIT license"></a>
<img src="https://img.shields.io/badge/platform-Windows%20x64-555" alt="Windows x64">
</p>

<p align="center"><b>A small web browser where WebAssembly runs everything, JavaScript included.</b></p>

Wren is a browser written in [Odin](https://odin-lang.org) where **WebAssembly is the only execution engine**. Pages
can be written two ways, and both run inside the same Wasm sandbox:

- **Ordinary JavaScript.** The scripts of a page run in [QuickJS-ng](https://github.com/quickjs-ng/quickjs), compiled to
  a WebAssembly module and run by Wasmtime, one instance per page and per worker, with a memory cap and a deadline like
  any other module. Its DOM and web APIs are bindings generated from the official Web IDL of the specifications
  ([webref](https://github.com/w3c/webref)). There is no native JavaScript engine in the browser, and no JIT.
- **WebAssembly directly.** A page names its modules with `<script type="application/wasm" src="…">`; the web APIs
  those modules call (DOM, events, timers, fetch, storage, workers, WebSocket…) are Wasm imports resolved by the
  browser itself. Every import is described once, in a Web IDL dialect (`api/*.widl`), and a generator produces the
  host bindings, the guest SDK, the documentation and the conformance tests from it.

Everything else is a real browser engine: HTML parsed by Lexbor, a CSS engine with the modern cascade, shadow DOM,
block, inline, flex, grid and table layout, incremental and parallel, painted by a retained GPU compositor on
Direct3D 11, with text on DirectWrite. The window and its chrome are built with
[gui_toolkit](https://github.com/sachahjkl/gui_toolkit), an immediate-mode UI toolkit by the same author. Windows
first: the platform does what it does best (WinHTTP for HTTP and TLS, WIC for images, DirectWrite for text, BCrypt for
crypto).

![Wren rendering the CSS effects demo: filters, backdrop-filter, mix-blend-mode](docs/screenshots/css-effects.png)

> **Status: prototype.** Wren is a research project, not a daily browser. It runs the JavaScript of real sites, but
> through an interpreter, with part of the web platform still missing, and it is Windows-only. See
> [Status and limits](#status-and-limits).

## Contents

- [Screenshots](#screenshots)
- [Features](#features)
- [Try it](#try-it)
- [Building from source](#building-from-source)
- [Tests](#tests)
- [Writing a page for Wren](#writing-a-page-for-wren)
- [Project layout](#project-layout)
- [Status and limits](#status-and-limits)
- [Releases](#releases)
- [License and credits](#license-and-credits)

## Screenshots

| | |
|---|---|
| ![The start page](docs/screenshots/home.png) | ![about:demos](docs/screenshots/demos.png) |
| **about:home**, the start page: an ordinary document, styled by the engine | **about:demos**: every demo and test page that comes with the browser, by theme |
| ![A page of plain JavaScript](docs/screenshots/javascript.png) | ![Shadow DOM](docs/screenshots/shadow-dom.png) |
| **JavaScript, inside WebAssembly**: a plain HTML and JS page, run by QuickJS-ng compiled to Wasm (`JS` in the status bar) | **Shadow DOM**: declarative shadow roots (they render with JavaScript off), slots, `:host`, `::slotted()`, `::part()`, custom elements |
| ![odin-lang.org in Wren](docs/screenshots/odin-lang-org.png) | ![A page whose behaviour is a Wasm module](docs/screenshots/wasm-counter.png) |
| **odin-lang.org**, a real site over HTTPS, its scripts running (`JS` in the status bar) | **A page written in Wasm**: the counter and the clock are an Odin module, no JavaScript at all |
| ![CSS transforms](docs/screenshots/css-transforms.png) | ![CSS Grid](docs/screenshots/css-grid.png) |
| **Transforms**: rotated text, forms and scroll boxes, nested rounded clips, group opacity, 7,000 animated nodes | **Grid**: areas, `auto-fill` / `minmax`, dense packing, alignment, nesting, subgrid |
| ![Gradients and shadows](docs/screenshots/css-gradients.png) | ![Masks, background-clip text, legends, color glyphs](docs/screenshots/masks-and-color-glyphs.png) |
| **Gradients**: linear, radial, conic, repeating, interpolation in sRGB / Oklab / Oklch / Lab / Lch / HSL | **Paint**: `mask-image`, `background-clip: text`, fieldset legends, rounded images, COLRv1 / sbix / OT-SVG color glyphs |
| ![webassembly.org in Wren](docs/screenshots/webassembly-org.png) | ![sacha.house in Wren](docs/screenshots/sacha-house.png) |
| **webassembly.org**, in its dark color scheme | **sacha.house**: a Tailwind stylesheet, `background-clip: text`, a fieldset legend, COLRv1 emoji from a web font |
| ![Frame statistics panel](docs/screenshots/frame-statistics.png) | ![about:config](docs/screenshots/about-config.png) |
| **Frame statistics** (Ctrl+Shift+B): phases per frame, display pacing, compositor, Wasm and memory counters | **about:config**: every setting of the browser, documented, searchable and editable |
| ![Tabs in the title bar](docs/screenshots/tabs.png) | ![Text: fallback, emoji, OpenType, scripts](docs/screenshots/text.png) |
| **Tabs in the title bar** with favicons and loading indicators, next to the window buttons (Snap Layouts kept) | **Text** on DirectWrite: per-character fallback, color emoji, ligatures and OpenType features, bidi |
| ![Find in page](docs/screenshots/find.png) | ![Selection and its context menu](docs/screenshots/context-menu.png) |
| **Find in page** (Ctrl+F) with a match count | **Text selection** and context menus |
| ![The Daylight palette](docs/screenshots/daylight.png) | |
| The **Daylight** palette of the interface (`browser.ui.theme`) | |

The demo pages are in [`examples/site`](examples/site); `about:demos` lists them all (see [Try it](#try-it)).
Screenshots show the whole window and are all taken in one pass by `tools\shots.ps1` (README and site).

## Features

Everything below exists in the code today and is covered by the tests of [`tools\test_all.ps1`](tools/test_all.ps1).

**WebAssembly, the only execution engine**
- [Wasmtime](https://wasmtime.dev) 49 (official C API, statically linked; Cranelift, or Winch via
  `wasm.wasmtime.compiler`). Any number of modules per document, fetched concurrently, run in document order, each in
  its own instance sharing the DOM; memory64 modules supported.
- Compiled code is cached in memory and in an HMAC-authenticated disk cache in the profile.
- Every host-to-guest call has a wall-clock deadline (epoch interruption, optionally fuel): a spinning module is
  stopped, its instance lives on. Guest memory is capped.
- Dedicated **workers**: a module on a thread of its own with its own store, messages and transferable buffers.

**JavaScript, inside WebAssembly** ([`native/js`](native/js/README.md))
- **QuickJS-ng 0.17.0** (ES2023 and later; 99.92 % of the 82,220 test262 runs pass), compiled by a pinned Zig to a
  WASI module and pre-initialized at build time: the interfaces and prototypes of the web platform are already built
  in the image (3.4 MiB, embedded in `wren.exe`), so a new realm starts in about 0.5 ms.
- **The same sandbox as any module**: one Wasm instance per page and per JavaScript worker, a heap cap
  (`javascript.max_heap_bytes`), a script that runs too long is stopped cleanly (`javascript.slow_script_ms`) and a
  hard deadline behind it (`wasm.max_call_ms`); a crash of the engine loses that page's scripts, never the browser.
- **Bindings generated from the specifications**: `src/tools/bindgen` reads the Web IDL of
  [webref](https://github.com/w3c/webref) (`native/js/webref`, pinned) and writes the glue with Web IDL's rules
  (conversions, dictionaries, unions, overloads, `[Reflect]`, iterables, named and indexed properties). 2,630 of
  4,991 members are implemented; a member that is not is absent, so feature detection sees the truth.
  [`docs/js/coverage.md`](docs/js/coverage.md) lists every interface and member.
- **The DOM**: tree and mutations, live collections, `innerHTML`, selectors, CSSOM and `getComputedStyle`, geometry,
  UI events, `MutationObserver`, `IntersectionObserver`, `PerformanceObserver`, ranges and traversal, custom elements,
  shadow DOM.
- **Script loading as HTML specifies it**: parser order, `defer` / `async`, `document.write`, dynamic scripts, ES
  modules and import maps, inline event handlers, `javascript:` URLs, `<noscript>`, CSP for scripts (`eval`,
  inline), timers, JavaScript workers, `structuredClone`.
- **Web APIs**: `fetch` / `Request` / `Response` / `Headers`, `XMLHttpRequest`, streams, `Blob` / `FormData`, URL,
  encoding, `AbortController`, Web Storage, history and location, navigator, performance, `crypto` with
  `crypto.subtle`, `matchMedia`, WebSocket, EventSource, `MessageChannel`, a minimal `Intl`.
- Compiled scripts are kept in a bytecode cache, in memory and in the profile.
- **On or off**, globally or per site: `javascript.enabled`, `javascript.sites.disabled`,
  `javascript.sites.enabled`. The status bar shows `JS` on pages that run scripts. Off, pages show their `<noscript>`
  content and their Wasm modules still run.

**The web API of Wasm pages: one description, everything generated** ([`api/`](api), [`docs/api`](docs/api))
- 25 modules, 672 functions: DOM, events, document, forms, timers and `requestAnimationFrame`, fetch (with streams),
  AbortController, URL, TextEncoder / TextDecoder, crypto (`getRandomValues`, digests), Web Storage, history,
  performance, images, EventSource, WebSocket, workers, console, and what the JavaScript engine needs from the
  browser.
- `src/tools/bindgen` turns `api/*.widl` into: host trampolines defined directly on the Wasmtime linker (every address
  checked against the guest's memory, UTF-8 validated, handles looked up by kind), the Odin guest SDK
  ([`sdk/odin/web`](sdk/odin/web)), the reference documentation ([`docs/api`](docs/api)) and generated conformance
  tests (bad addresses, bad UTF-8, dead handles, enums out of range, buffers too small, for every function).
- Promises, microtasks and EventTarget for host objects, as the web platform defines them.

**HTML, CSS and layout**
- HTML5 parsing with [Lexbor](https://lexbor.com), charset sniffing and decoding, quirks mode, the presentational
  attributes of old HTML (`bgcolor`, `align`, `<font>`, table attributes…), `view-source:`.
- **Shadow DOM**: `attachShadow` and declarative shadow roots (`<template shadowrootmode>`, which render without
  JavaScript), named and manual slots, encapsulated styles with `:host`, `:host-context()`, `::slotted()`, `::part()`
  and `exportparts`, `:state()`, constructable stylesheets and `adoptedStyleSheets`, event retargeting,
  `delegatesFocus`.
- CSS: cascade layers, custom properties and `@property`, nesting-era selectors (`:is`, `:where`, `:has`, `:not`…),
  media and container queries, Color 4 / 5 (Oklab, Oklch, `color-mix`…), math functions, `@font-face` with WOFF and
  WOFF2, transitions and animations, `color-scheme` and system colors. Style is computed in parallel on large documents
  and restyled incrementally (invalidation sets, Bloom filter).
- Layout: block and inline (bidi, line breaking, text placed vertically as Chromium places it: font metrics,
  half-leading, `vertical-align`), floats, positioning (absolute, fixed, sticky), **flexbox**, **grid** (with
  subgrid), **tables**, replaced elements, scroll containers. Incremental relayout from DOM and style journals (checked
  against a full pass), paragraphs pre-laid out on several threads on page load.
- HTML forms: every control, constraint validation, `FormData`, submission in its three encodings.

**Painting and text**
- A retained compositor: the display list is recorded into GPU-side pictures and replayed; scrolling and transform
  animations change matrices only. Shaders are precompiled: the first frame of the start page is drawn about 0.3 s
  after launch (1.8 s before).
- CSS transforms, rounded clips, `opacity` groups, `filter`, `backdrop-filter`, `mix-blend-mode`, `isolation`,
  `clip-path`, box shadows (exact gaussian, in the shader), gradients of every kind, `mask-image` and
  `-webkit-mask-*`, `background-clip: text`.
- Colors blended on sRGB values as browsers do (with Chromium's text contrast settings), gamma-correct where it should.
- Text on **DirectWrite**: per-character font fallback, OpenType shaping, bidi, synthetic italics, color emoji and
  color fonts in every format (COLRv1, sbix, CBDT, OT-SVG, rasterized off the UI thread).
- Images decoded off the UI thread: PNG, JPEG, GIF, BMP, ICO and TIFF through WIC; **WebP**, **AVIF** and **SVG**
  always, through a built-in Rust library (image-webp, rav1d, resvg); ICC profiles and CICP color management (qcms);
  `srcset`, `<picture>`, lazy loading, inline `<svg>`.

**Network and security**
- HTTP(S) on WinHTTP, asynchronous, with per-host and global queues, back-pressure and cancellation.
- A Fetch Standard policy layer: CORS with preflight cache (checked on every redirect), credentials modes, referrer
  policy, mixed content blocking, Fetch Metadata, bad ports, MIME checks.
- Cookies (RFC 6265bis: SameSite, prefixes, Public Suffix List, third-party cookies blocked by default), **HSTS**,
  **Content Security Policy** 3 (`script-src` governs JavaScript and Wasm modules), secure contexts.
- A `file:` page may read only its own directory tree (paths are checked again once the file is open: no escape
  through junctions, links or device names); web pages never read local files.

**The browser around the page**
- Tabs in the title bar with favicons, loading indicators, drag to reorder, middle-click to close; history, address
  bar with search, find in page (Ctrl+F), text selection (word, paragraph, Shift+click), context menus, page zoom,
  keyboard navigation everywhere in the chrome.
- Error pages by cause (DNS, refused, timeout, TLS, missing file), downloads (`Content-Disposition`, types that cannot
  be shown) with the Windows Save dialog, optional session restore.
- Local files as in other browsers: the address bar takes Windows paths, files and folders can be dropped on the
  window, a folder opens its `index.html` or a sortable list of its files.
- **Frame pacing** on the display's exact refresh rate (60 to 180 Hz and beyond), vblank-aligned animation clock,
  smooth scrolling, one frame in flight; a status bar with a live frame graph and a statistics panel.
- **Everything is configurable**: every subsystem declares its preferences (type, bounds, unit, description); they
  are layered *defaults < profile file < command line (`--pref name=value`) < policy file* and edited live in
  `about:config`.
- Draws only when something changes: an idle page costs no frames.

## Try it

Download `wren-<version>-windows-x64.zip` from the [latest release](https://github.com/sachahjkl/wren/releases/latest),
unzip it anywhere and run `wren.exe`. It needs Windows 10 or 11 (x64) with a Direct3D 11 GPU; nothing else to install.

The start page links to `about:demos`, the index of every demo and test page. They come in the zip, in `demos\` next to
`wren.exe`, and most open straight from disk: `demos\index.html` is the same index as a page (opening the folder shows
it). The few that need a server (network images, forms, CSP, workers, the script loading and web API demos) are
marked; the small local test server is in the zip too: run `demo.bat` (it starts `testserver.exe` on 127.0.0.1:8765
and opens `about:demos`), or start them yourself:

    testserver.exe                                   # http://127.0.0.1:8765, https://127.0.0.1:8766 (self-signed)
    wren.exe http://127.0.0.1:8765/site/effects.html
    wren.exe demos                                   # a folder: its index.html, else the list of its files
    wren.exe demos\js.html                           # a page of plain JavaScript

The address bar takes Windows paths as well as URLs (`C:\pages\a.html`, `S:/site`, `\\server\share`, `~\Documents`),
and files or folders dropped on the window open. A folder opens its `index.html` (`file.directory.index`), else a list
of its files (`file.directory.*` in `about:config`); `about:about` lists the built-in pages.

Useful command-line options: `--profile DIR` (another profile directory; the default is `%APPDATA%\Wren`),
`--pref name=value` (any preference of `about:config`, for example `--pref javascript.enabled=false`),
`--policy FILE`.

Keys: Ctrl+T / Ctrl+W tabs, Ctrl+L address bar, Ctrl+F find, Ctrl+Plus / Minus / 0 zoom, Ctrl+U view source,
Ctrl+B status bar, Ctrl+Shift+B frame statistics, F11 full screen. The tabs sit in the title bar
(`browser.window.integrated_titlebar = false` brings back the Windows one).

## Building from source

Requirements (CI installs the same: [.github/actions/setup](.github/actions/setup/action.yml)):

| Tool | Version | Used for |
|---|---|---|
| Windows | 10 or 11, x64 | the only platform |
| [Odin](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10) | **`dev-2026-10`** (`dev-2026-10-nightly:84bc3fc`) | the browser and its tools |
| Visual Studio 2022 or later (or its Build Tools) | "Desktop development with C++": MSVC x64 and a Windows SDK (CI: the runner's Visual Studio) | Odin's linker, Lexbor and the C shims |
| [Rust](https://rustup.rs) | 1.99.1 (CI's pinned version; any recent stable works), `x86_64-pc-windows-msvc` | the built-in image and font decoders (`native/media`) |
| [Go](https://go.dev/dl/) | ≥ 1.25.6 | only the test server (`tools/testserver`) |
| Git | any | submodules, the commit shown in About |

Zig (for the JavaScript engine) and NASM are downloaded by the build itself, pinned by SHA-256.

```bat
git clone --recurse-submodules https://github.com/sachahjkl/wren.git
cd wren
build.bat            &:: optimized build -> build\wren.exe
build.bat debug      &:: debug build
build.bat profile    &:: optimized + PDB + the built-in profiler -> build\wren_prof.exe
build.bat check      &:: debug build tracking every allocation, a leak report at exit -> build\wren_check.exe
build.bat release    &:: optimized build of the release channel (what the release workflow packages)
```

Every build but `build.bat release` is a development build: a blueprint icon instead of the amber one (exe, window,
taskbar, tab strip), and "development build" with the commit on the start page and in the menu.

What `build.bat` does, each step skipped when it is already up to date:

1. `tools\fetch_wasmtime.ps1` downloads the official **Wasmtime 49.0.3** C API release (SHA-256 pinned) into
   `build\wasmtime`; its static `wasmtime.lib` is linked into the exe.
2. `tools\build_lexbor.ps1` compiles **Lexbor v3.0.1** (`ext/lexbor`) and the C shims of `src/shim` with MSVC into
   `build\lexbor\lexbor.lib`.
3. `tools\build_media.ps1` builds `native/media` with Cargo (`--locked`, every crate pinned by version and hash),
   downloads **NASM 2.16.03** (SHA-256 pinned) for rav1d's assembly, adds the `llvm-tools` rustup component on first
   use, and produces `build\media\wren_media.lib` (about 1.5 minutes the first time).
4. `src/tools/bindgen` regenerates the web API bindings, SDK and docs from `api/*.widl`, and the JavaScript bindings
   and their coverage from the Web IDL of `native/js/webref` (only what changed).
5. `tools\build_js.ps1` downloads **Zig 0.15.2** and the **QuickJS-ng 0.17.0** source (both SHA-256 pinned), applies
   the patches of `native/js/patches`, compiles the engine with the browser's bindings to `wasm32-wasi`, and
   pre-initializes it into `build\js\wren_js.wasm`.
6. `odin build src/browser` links everything into one self-contained `build\wren.exe`, the JavaScript engine
   included (no DLL beyond the system's and the Visual C++ runtime that Windows ships).

Run it with `build\wren.exe [URL]`. For the demo pages that need a server, build and start the test server first:

```bat
cd tools\testserver && go build -o ..\..\build\testserver.exe . && cd ..\..
build\testserver.exe
```

## Tests

```powershell
powershell -NoProfile -File tools\test_all.ps1 -Quick   # every suite but the long network stress
powershell -NoProfile -File tools\test_all.ps1          # everything
powershell -NoProfile -File tools\test_all.ps1 -CI      # what continuous integration runs (see below)
```

The suite runs the unit tests of every package (`odin test src/<package> -vet`), checks that the generated web API and
JavaScript bindings are up to date (`bindgen -check`), runs the generated API conformance cases, the graphics
toolkit's pixel tests on an offscreen WARP renderer, and end-to-end tests that drive real pages, Wasm guests and
scripts against the local test server (network policy, DOM and events, web platform APIs, forms, workers, EventSource
and WebSocket, style animations, images and image formats, local files, the JavaScript engine, its DOM, script
loading and web APIs). None of them needs the internet, and with `-Quick` none opens a window.

**Memory.** Every unit test fails on a leak or a bad free (Odin's test runner, `ODIN_TEST_FAIL_ON_BAD_MEMORY`). The
end-to-end tools are built with `-define:WREN_TRACK_MEMORY=true`: every allocation of the process, whatever the thread
(the Wasm host calls and the network callbacks included), goes through one tracker (`src/base/memory.odin`), and a
tool fails when anything is still allocated once it has shut down (`src/tools/testenv/memory.odin`). Code without an
Odin context of its own starts from `base.process_context()`; what is kept for the life of the process on purpose
comes from `base.permanent_allocator()` and is never reported. `build.bat check` builds the browser the same way,
with a script driver (`WREN_MEMCHECK_SCRIPT`, `src/browser/memcheck.odin`) that runs whole sessions without the
desktop's input: [`tools\memcheck_e2e.ps1`](tools/memcheck_e2e.ps1) (tabs, scripts, images, forms, the
back/forward cache, the palette, history, then a normal exit with nothing left) and
[`tools\endurance.ps1`](tools/endurance.ps1) (400 tabs and 2,000 navigations: the tracked bytes, the private bytes
and the kernel, GDI and USER handles must stop growing). [`tools\asan.ps1`](tools/asan.ps1) builds the unit tests
and the browser with AddressSanitizer. `-CI` and full runs include the check build's session and a short endurance
run.

Two standard conformance suites run too, pinned by commit and checked against committed expectations, so that any
regression fails the run:

- **test262**, the ECMAScript suite ([`tools\test262.ps1`](tools/test262.ps1)): the engine compiled to Wasm passes
  99.92 % of 82,220 runs, against 99.94 % for the same QuickJS-ng compiled natively (the difference: `Atomics.pause`
  and growable `SharedArrayBuffer`, without threads in WASI). `test_all` runs a sample of it.
- **web-platform-tests** ([`tools\wpt.ps1`](tools/wpt.ps1), [`wpt/suites.txt`](wpt/suites.txt)): 4,494 test files of
  25 folders (DOM, HTML, URL, encoding, Fetch, XHR, streams, storage, workers, shadow DOM, custom elements…), of
  which 106,188 subtests pass ([`wpt/expectations`](wpt/expectations)).

`-CI` is `-Quick` for shared build machines: end-to-end timeouts are tripled and a failed step's whole output is
shown, one step at a time on the default ports. Locally, steps run several at a time (`-Jobs n`) and the test server
listens on ports of the run (`-BasePort n`), so several checkouts can test at once. No step is ever run twice: tests
check properties, never wall-clock durations. [GitHub
Actions](.github/workflows/ci.yml) runs it on `windows-2025` for every push and pull request.

## Writing a page for Wren

**In JavaScript**, as for any browser: Wren runs the page's scripts, inline or external, classic or modules.
[`examples/site/js.html`](examples/site/js.html) and [`js-dom.html`](examples/site/js-dom.html) are small examples.
What is implemented is listed in [`docs/js/coverage.md`](docs/js/coverage.md); what is not is absent, so
`if ("ResizeObserver" in window)` takes the fallback.

**In WebAssembly**, without JavaScript: a page module is any Wasm module that imports the functions of
[`docs/api`](docs/api) and exports `wb_main`. The Odin SDK is [`sdk/odin/web`](sdk/odin/web), one generated file per
API module. A page:

```html
<!doctype html>
<title>Counter</title>
<script type="application/wasm" src="counter.wasm"></script>
<p>Value: <b id="count">0</b> <button id="inc">+1</button></p>
```

and its module ([`examples/counter`](examples/counter/main.odin) is the full version):

```odin
package counter

import "web:web"

count: i64
count_node: web.Element

on_click :: proc "contextless" (user: i32, ev: web.Event) {
	count += i64(user)
	buf: [24]u8
	n := len(buf)
	for v := count; ; v /= 10 { n -= 1; buf[n] = u8('0' + v % 10); if v < 10 { break } }
	web.Node_setTextContent(count_node, string(buf[n:]))
}

@(export)
wb_main :: proc "contextless" () {
	count_node = web.Document_getElementById("count")
	web.EventTarget_addEventListener(web.Document_getElementById("inc"), "click", on_click, 1)
	web.console_log("counter ready")
}
```

```bat
odin build examples/counter -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator ^
    -collection:web=sdk/odin -out:examples/site/counter.wasm -o:size
```

Conventions (the full ABI is in [`docs/api/README.md`](docs/api/README.md)): handles are `i64`, strings are UTF-8
`(pointer, length)`, strings returned by the browser go into a caller buffer and the result is the length needed,
callbacks are function-table indices with a user value, errors are negative `i32`. Any language that compiles to Wasm
can implement them; only the Odin SDK is generated today. A new API starts as a few lines in `api/<module>.widl`:
`build.bat` regenerates the trampoline and tells you, through a compile error, which host procedure to write.

A page may use both: its Wasm modules and its scripts share the same DOM.

## Project layout

```
api/            the web API, described once (*.widl): source of the bindings, SDK, docs and conformance tests
assets/         logo and icon
docs/api/       generated API reference (with the ABI)        docs/architecture.md: design rules and security model
docs/js/        generated coverage of the JavaScript bindings
examples/       Wasm guest pages (counter, forms, workers, conformance...), JavaScript test pages, site/: the demo pages
ext/            submodules: gui_toolkit (window, UI, renderer, text), lexbor (HTML, URLs, encodings)
native/js/      the JavaScript engine module: QuickJS-ng patches, the engine layer, hand-written members, preludes,
                generated bindings, the Web IDL of webref
native/media/   Rust static library: SVG (resvg), WebP (image-webp), AVIF (rav1d), color (qcms), WOFF2 (brotli)
sdk/odin/web/   generated Odin guest SDK
src/
  base/         scopes (ownership tree with cleanups) and generational handle pools
  host/         event loop, thread-safe posts, timers, blocking-work pool
  net/          transport: HTTP(S) and WebSocket on WinHTTP; no policy
  url/ http/    WHATWG URLs, origins, Public Suffix List; headers and MIME types
  cookies/ csp/ the cookie jar (RFC 6265bis) and Content Security Policy 3
  fetch/        the policy layer (Fetch Standard): CORS, credentials, redirects, HSTS, referrer, mixed content, file:
  html/ dom/    HTML parsing (Lexbor), charsets; the document tree, shadow trees, events and the mutation journal
  css/ style/   tokenizer, parser, selectors, values; the style engine (cascade, layers, shadow scopes, animations)
  layout/       box tree, block / inline / flex / grid / table layout, incremental and parallel passes, display list
  images/ webfont/  image decoding threads (WIC + native/media); web font unpacking (WOFF, WOFF2)
  forms/        HTML form controls as a model: values, validation, editing, submission
  wasm/         the Wasm engine (Wasmtime): instances, linker, deadlines, limits, caches, WASI, pre-initialization
  js/           JavaScript preferences, the bytecode cache, the embedded engine image
  page/         one document = DOM + Wasm instances + JavaScript realm + requests + timers; the imports' implementations
  config/       the preference registry behind about:config
  browser/      the shell: window, tabs, chrome, painter and compositor, pacing, status bar, about: pages
  shim/         C shims over Lexbor
  tools/        bindgen, end-to-end test drivers, test262 and WPT runners, benchmarks
tools/          build, test, screenshot and measurement scripts; testserver/ (Go)
wpt/            the web-platform-tests Wren runs: folders, manifest, expectations
```

[`docs/architecture.md`](docs/architecture.md) explains the rules that hold it together (one ownership tree, handles
across every boundary, a single UI thread, mechanism separate from policy, a bound on everything) and the security model.

## Status and limits

Wren is a prototype. It is meant to show how far a browser with a single, sandboxed execution engine can go, not to
replace one. Known limits:

- **JavaScript is interpreted** (QuickJS-ng in Wasm, no JIT): on the Octane benchmarks it scores about 0.77 × the same
  engine compiled natively and about 1/55 of Edge. A simple DOM call costs about ten times what it costs in Edge
  (`node.nodeType`: 65 ns against 5). Pages that run a lot of script are slow.
- **Part of the web platform is missing**: about half of the members of the specifications' Web IDL are implemented
  ([`docs/js/coverage.md`](docs/js/coverage.md)). Among what pages notice: Canvas 2D is software-drawn and partial (no workers, no video frames, no color emoji in `fillText`), no IndexedDB, no
  `ResizeObserver`, no Web Animations API, no service workers; `Intl` follows English conventions whatever the
  locale; `<iframe>` content is not loaded. Single-page applications that rely on these show little or nothing.
- **Windows only** (Win32, Direct3D 11, DirectWrite, WinHTTP, WIC). The layers above the platform are portable Odin.
- No HTTP cache yet (every load goes to the network); no HTTP authentication, no SRI, CSP violations are reported to
  the console only; no cookie partitioning.
- No IME composition, no vertical writing modes, no multi-column layout; no `<video>` or `<audio>` playback.
- Wasm threads and shared memory are off (each worker has its own memory); the Wasm GC proposal is off by default.
- Response bodies are bounded (`max_body` and a per-page ceiling).

## Releases

Binaries are built by [GitHub Actions](.github/workflows/release.yml) from a version tag and attached to the
[releases](https://github.com/sachahjkl/wren/releases) with their SHA-256 sums; [CHANGELOG.md](CHANGELOG.md) sums up
each version. To make one (see [CONTRIBUTING.md](CONTRIBUTING.md)):

```bat
git tag -a vX.Y.Z -m "Wren X.Y.Z"
git push origin vX.Y.Z
```

## License and credits

Wren is released under the [MIT license](LICENSE). It stands on:

- [Odin](https://odin-lang.org) by Ginger Bill and contributors;
- [gui_toolkit](https://github.com/sachahjkl/gui_toolkit) (MIT), whose design follows the UI layers of the
  [RAD Debugger](https://github.com/EpicGamesExt/raddebugger) (MIT, Epic Games Tools);
- [Wasmtime](https://github.com/bytecodealliance/wasmtime) (Apache-2.0 with LLVM exception, Bytecode Alliance);
- [QuickJS-ng](https://github.com/quickjs-ng/quickjs) (MIT), the JavaScript engine, after Fabrice Bellard's QuickJS,
  with [wasi-libc](https://github.com/WebAssembly/wasi-libc) (Apache-2.0 with LLVM exception, Apache-2.0 or MIT; musl:
  MIT) as built by [Zig](https://ziglang.org) (MIT, build time only);
- [webref](https://github.com/w3c/webref) (MIT), the Web IDL of the specifications, from which the JavaScript bindings
  are generated;
- [Lexbor](https://github.com/lexbor/lexbor) (Apache-2.0);
- [resvg](https://github.com/linebender/resvg), [image-webp](https://github.com/image-rs/image-webp),
  [rav1d](https://github.com/memorysafety/rav1d) (BSD-2-Clause), [zenavif-parse](https://crates.io/crates/zenavif-parse)
  (MPL-2.0), [qcms](https://github.com/FirefoxGraphics/qcms) (MIT),
  [brotli-decompressor](https://github.com/dropbox/rust-brotli-decompressor) and the crates they depend on;
- [NASM](https://www.nasm.us) (build time only), the [Public Suffix List](https://publicsuffix.org) (MPL-2.0);
- the test suites [test262](https://github.com/tc39/test262) and
  [web-platform-tests](https://github.com/web-platform-tests/wpt) (BSD-3-Clause; fetched at a pinned commit for the
  tests, not shipped).

- [Slug](https://github.com/EricLengyel/Slug) by Eric Lengyel (MIT; the patent is in the public domain): the shaders and the
  algorithm of the optional `text.renderer = slug` (glyphs drawn from their outlines on the GPU), through gui_toolkit.

- [Noto Color Emoji](https://github.com/googlefonts/noto-emoji) (COLR v1, Google; SIL OFL 1.1), the built-in emoji font (`text.emoji = builtin`), compiled into `wren.exe`; and Unicode's `emoji-data.txt` (Unicode License v3), which tells emoji characters from the others.
 used by the demo pages and tests come with their licenses next to them (`examples/site/fonts`,
`native/media/tests/fonts`). [THIRD_PARTY.md](THIRD_PARTY.md) lists every component linked into `wren.exe`.
