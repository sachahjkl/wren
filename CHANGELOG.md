# Changelog

What each version of Wren brings. The release notes on GitHub add the list of every change
([releases](https://github.com/sachahjkl/wren/releases); `tools/release_notes.ps1` writes them from
`docs/releases/` and the history).

## Unreleased

### Added
- **Built-in emoji** (	ext.emoji, `builtin` by default; `system` keeps Segoe UI Emoji on Direct2D): Noto Color Emoji (COLR v1, SIL OFL), shipped in `emoji\` next to `wren.exe` (`tools\fetch_emoji.ps1`, pinned by SHA-256; 4.9 MiB), drawn by an interpreter of the COLR paint graph written for gui_toolkit instead of a platform renderer: the same emoji on every platform, sharp at any size, the system's emoji font replaced even when a page names it, and no Direct2D device (about 150 MB less of private memory on a page of emoji, a page of 100 emoji painted in 85 ms instead of 510 ms). ZWJ families, skin tones, flags, keycaps, VS16 and tag flags are single glyphs; against Chrome / Edge on the same font the difference is under 1/255 per channel. `text.emoji.font` (another COLR font), `text.emoji.raster_samples`, `text.emoji.outline_cache`. The font and its license are in about:licenses and the release package.
- `text.renderer` (`atlas`, the default, or `slug`): with `slug`, text is drawn on the GPU from the glyph outlines (Eric Lengyel's Slug algorithm, credited in `THIRD_PARTY.md`): sharp at any page zoom, rotation or transform, with exact subpixel positions and nothing to re-rasterize when the zoom changes. Emoji stay bitmaps. `text.slug.pages` (video memory budget) and `text.slug.tolerance`.

- **About Wren** (`about:wren`, menu and command palette): the logo of the channel, version, commit, build, toolkit, Odin, Wasmtime and QuickJS-ng versions, "by Froment Software", the beta notice, the third-party software (`THIRD_PARTY.md`), and `about:licenses` with every license text (Slug's credit included).
- **Supporter licence** ([docs/licence.md](docs/licence.md)): a key signed offline with Ed25519 and checked in Wren without any network access, entered in `about:wren` (paste it, choose a file, or drop a `.wrenlicense` file). It changes one line of `about:wren` and nothing else: every version stays free and complete during the beta. `tools\license.ps1` makes the key pair and issues licences; `browser.license.*` preferences.

## 0.3.0 - 2026-10-21

The highlights are in [docs/releases/v0.3.0.md](docs/releases/v0.3.0.md): a JavaScript JIT that produces WebAssembly, iframes, a browser that never waits for a busy page, an HTTP cache, passkeys, history as a tree, a command palette and address bar suggestions, immediate hover feedback and CSS cursors, memory leaks failing the tests and memory given back when idle.

## 0.2.1 - 2026-10-20

### Fixed
- Wren crashed about three seconds after start when the mouse pointer was over its window: the mouse input of the first frame read the interface state before it was built (gui_toolkit 0.11.1).

## 0.2.0 — 2026-10-20

JavaScript, inside WebAssembly: WebAssembly is still the only execution engine.

### Added

- **JavaScript.** QuickJS-ng 0.17.0 compiled to a WebAssembly module, pre-initialized at build time and embedded in
  `wren.exe`; one sandboxed instance per page and per JavaScript worker, with a heap cap
  (`javascript.max_heap_bytes`), a clean stop for long scripts (`javascript.slow_script_ms`) and the Wasm deadline
  behind it. On or off globally (`javascript.enabled`) or per site (`javascript.sites.disabled`,
  `javascript.sites.enabled`). A bytecode cache in memory and in the profile. `JS` / `JS stopped` in the status bar.
- **Bindings generated from the specifications' Web IDL** (webref): 2,630 of 4,991 members implemented, the others
  absent ([docs/js/coverage.md](docs/js/coverage.md)). DOM, CSSOM, geometry, UI events, `MutationObserver`,
  `IntersectionObserver`, `PerformanceObserver`, ranges and traversal, custom elements, `CSS.supports` /
  `CSS.escape`; script loading as HTML specifies it (parser order, `defer` / `async`, `document.write`, ES modules
  and import maps, inline handlers, `javascript:` URLs, `<noscript>`, CSP for scripts); `fetch`, `XMLHttpRequest`,
  streams, `Blob` / `FormData`, URL, encoding, `AbortController`, Web Storage, history and location, navigator,
  performance, `crypto` and `crypto.subtle`, `matchMedia`, WebSocket, EventSource, `MessageChannel`, JavaScript
  workers, `structuredClone`, a minimal `Intl`.
- **Shadow DOM**: `attachShadow`, declarative shadow roots (rendered without JavaScript), named and manual slots,
  `:host`, `:host-context()`, `::slotted()`, `::part()` and `exportparts`, `:state()` and `ElementInternals`,
  constructable stylesheets and `adoptedStyleSheets`, event retargeting and `composedPath()`, `delegatesFocus`,
  `getHTML` / `setHTMLUnsafe`.
- **Conformance suites**: test262 (99.92 % of 82,220 runs) and web-platform-tests (4,494 test files, 106,188
  passing subtests), pinned, with committed expectations checked by `tools/test_all.ps1`.
- HTML presentational attributes and quirks mode; `text-align: -webkit-center`; `line-height: normal` from the font.
- Tabs with favicons, loading indicators, drag to reorder and middle-click to close; error pages by cause; downloads;
  optional session restore; more shortcuts (Ctrl+P notice, Ctrl+Shift+PgUp / PgDn, mouse back and forward buttons).
- Local files: Windows paths in the address bar and on the command line, drag and drop of files and folders, folders
  opening their `index.html` or a sortable list of their files, `about:about`; `examples/site/index.html` and
  `about:demos` list every demo by theme.
- Demos: `js.html`, `js-dom.html`, `shadow-dom.html`, `legacy-html.html`, script loading and web API pages.

### Changed

- Text placed vertically as in Chromium: font metrics rounded one by one, half-leading, `vertical-align`, flex lines
  bounded by `min-height`, centered button content, table cells and form control baselines, monospace and keyword
  font sizes.
- Image sizes come from the decoded image; `width` / `height` attributes give the aspect ratio before decoding.
- Shaders precompiled: the start page is drawn about 0.3 s after launch (1.8 s before). Resizing keeps the swap chain
  (a margin and a presented region instead of `ResizeBuffers`); media queries restyle only when their answer changes.
- The event loop runs due timers for at most `browser.loop.timer_slice_ms` per turn once one has run.
- User-Agent `Wren/0.2`.

### Fixed

- About 90 problems found by a review of the whole engine: use-after-frees (microtasks during host tasks, fetch,
  workers, streams), `file:` pages leaving their folder (escaped separators, junctions, links, alternate streams,
  device names), NTLM leaks through `file://server/share`, hostile content that crashed or froze the browser (huge
  `calc()`, exponential `var()`, cyclic `@import`, extreme transforms…), CORS on redirects, lost `localStorage` at
  exit, ten divergences of the incremental restyle and layout, `--pref` erasing profile values.
- Synthetic italics of static web fonts.
- Closing a WebSocket right after a message no longer ends in an error.
- Flaky tests fixed at their cause; CI no longer retries a failed step.

## 0.1.0 — 2026-10-19

The first public build: a browser for Windows where WebAssembly is the only execution engine, with no JavaScript.
Pages name their Wasm modules with `<script type="application/wasm">`; the web APIs are Wasm imports generated from
`api/*.widl`.

- **WebAssembly runtime**: Wasmtime 49 (Cranelift), compiled-code caches in memory and on disk, a deadline on every
  call, several modules per document, memory64, dedicated workers.
- **Web API from one description**: 21 modules, 289 functions, with generated host trampolines, Odin SDK,
  documentation and conformance tests.
- **HTML and CSS**: Lexbor parsing, cascade layers, custom properties, `:has` / `:is` / `:where`, media and container
  queries, Color 4 / 5, web fonts, transitions and animations.
- **Layout**: block, inline (bidi), floats, positioning, flexbox, grid with subgrid, tables; incremental and parallel.
- **Painting**: a retained GPU compositor on Direct3D 11, transforms, filters, blend modes, masks, exact shadows,
  gradients in every color space.
- **Text** on DirectWrite; **images** through WIC plus built-in WebP, AVIF and SVG.
- **Network and security**: WinHTTP, a Fetch Standard policy layer, cookies, HSTS, Content Security Policy 3.
- **The browser**: tabs, history, find in page, selection, zoom, view-source, `about:config`, frame pacing and
  statistics.
