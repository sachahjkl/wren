# Embedder runtime (`src/embed`)

`src/embed` sits at Layer 7 (between `page` and `browser`). It holds the headless browser runtime stack without any window, renderer, or toolkit UI dependency.

## Purpose

Before `src/embed`, five embedders (`browser`, `headless`, `e2e/web_harness`, `apiconformance`, and `fetch`) each initialized and tore down `host.Loop`, `net.Client`, `host.Blocking_Pool`, `fetch.Profile`, `fetch.Loader`, `page.Storage_Manager`, `page.Settings`, `page.Pages`, `base.Scope`, and the Wasm/JS runtime by hand in different orders. Harnesses drifted and leaked resources (`headless.destroy` omitted loop, client, blocking pool, loader, profile, and page shutdown).

## Design decisions

- **One pinned struct (`embed.World`) with explicit stage tracking (`Stages`).** Internal subsystems store pointers to `&w.loop`, `&w.client`, `&w.blocking`, `&w.profile`, and `&w.pages`. Therefore `world_init(&w, opts)` initializes a caller-owned `World` in place and `world_make(opts)` heap-allocates a pinned `^World`. Returning a `World` by value after initialization is refused because moving it invalidates every internal pointer.
- **Exact reverse teardown, including on partial failure.** `world_destroy` walks `w.made` in reverse dependency order (`process` scope -> blocking settle -> `storage` -> loop drain -> `page.pages_shutdown` -> process runtime shutdown -> `loader` -> `httpcache` -> `blocking` -> `client` -> `profile` -> `page.discard_page_tasks` -> `loop` -> `settings` -> `page.bind(nil)`). If `world_init` fails midway, it calls `world_destroy` before returning `false`.
- **Single-stage default with opt-in upgrades.** The zero `Options{}` builds a working headless page world. Callers that need a network-only stack (`fetch`, `web_harness` `.Net` tests) pass `network_only = true` and can upgrade in place via `world_enable_pages` and `world_enable_storage`.
- **Stateless `Process_Share` with `Process_Hooks`.** Multi-world processes refcount process-wide setup and teardown through an atomic `sync.Futex` word (`Process_Share`), parameterized by `Process_Hooks{on_begin, on_end, user}` instead of taking `^browser.App`. `src/embed` keeps zero package-level globals.
- **Phase 1 boundary.** Phase 1 migrates the four non-browser tool embedders (`apiconformance`, `fetch`, `e2e/web_harness`, `headless`) onto `embed.World`. Embedding `embed.World` into `browser.App` and extracting `embed.Navigation` belong to later phases.
