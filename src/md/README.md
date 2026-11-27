# Wren: intent

This folder records why Wren is built as it is: the purpose of a module or a feature, the decisions, the alternatives
that were refused and why. It follows <https://srcmd.org>. Change the intent first, then the code and the tests.

## Overview

Wren is a web browser in Odin. WebAssembly is its only execution engine: the JavaScript engine is Odin compiled to
Wasm, run by Wasmtime. The window, the widgets, the settings, the install and the log come from gui_toolkit
(`ext/gui_toolkit`). Wren keeps only what a browser needs that the toolkit does not give.

## Subtleties

- **Wren is a thin layer over the toolkit.** If the toolkit has a system, Wren uses it. If it lacks an option that Wren
  needs, the toolkit gets the option; Wren does not keep its own copy.
- **The designs written before this folder** are in `docs/`, which the documentation site publishes:
  [architecture](../../docs/architecture.md) (the design rules and the security model),
  [portability](../../docs/portability.md), [testing](../../docs/testing.md), and one file per feature.
  A new design goes in this folder.
- **Every package imports the toolkit through the `toolkit` collection**, never by a relative path. So every build of
  Wren, of its tools and of its tests passes `-collection:toolkit=ext/gui_toolkit/src` beside `-collection:wb=src`. The
  toolkit's own tests name it `gt`.

## File Index

- [features/debug-panel.md](features/debug-panel.md): Wren's panel in the toolkit's debug window (Ctrl+Alt+Shift+D, `tk cdp debug`): the counts it shows, the switches and the acts, why it reads only what is already kept, and what was refused.
- [features/demo-states.md](features/demo-states.md): the toolkit's interface endpoint in Wren (`TOOLKIT_DEVTOOLS`) and its demo states: the Vault unlocked, locked, asking its PIN, a licence registered, each in memory only.
- [features/fuzzing.md](features/fuzzing.md): the fuzzer of the parsers that read untrusted input (`wrentool fuzz`, `src/tools/fuzz`): why a mutation fuzzer of our own, the worker and its driver, the targets, how a finding replays.
- [features/js-cost.md](features/js-cost.md): the cost gate of the engine: the Wasm instructions of cost.js's cases and of whole Octane benchmarks, interpreted, against limits; how a run is counted, what makes the count exact, what is left out, how to change a limit.
- [features/js-engine.md](features/js-engine.md): why the JavaScript engine is the toolkit's `gt:js`, and what Wren keeps around it (Wasmtime, glue, bindings, the Wasm test262).
- [features/keys.md](features/keys.md): how Wren connects the toolkit's keymap, and the command that opens a page in a new tab.
- [features/licence.md](features/licence.md): Wren's licence as the toolkit's Licence page and card, what Wren gives it, and the HTML card with its CSS shaders that it replaces.
- [features/network-detail-fold.md](features/network-detail-fold.md): the developer tools' Network detail beside the table as the toolkit's foldable side panel: the table's least, the share kept, the fold saved, what the rail shows.
- [features/profile.md](features/profile.md): where the profile lives, and its move to `FromentSoftware/Wren`.
- [features/settings-pages.md](features/settings-pages.md): the toolkit's standard pages in about:settings (What's new, Licence, Installation, Updates, Diagnostics), what each replaced in Wren, what stays Wren's, and why updates are Windows release builds only.
- [features/vault-helper-delivery.md](features/vault-helper-delivery.md): how wren-vault is released and signed, the pin `vault.version`, the helper in the Linux archive, its download beside a release and how a new Wren replaces it.
- [infrastructure/embed.md](infrastructure/embed.md): the Layer 7 headless browser runtime (`src/embed`: `embed.World`, `Process_Share`, canonical init and reverse teardown shared by all embedders).
- [infrastructure/frame-causes.md](infrastructure/frame-causes.md): typed `Frame_Cause` invalidation, unified errands, automatic `.Layout` follow-up on UI layout/scroll changes, and `window_at_rest`.
- [infrastructure/profile-stores.md](infrastructure/profile-stores.md): the leaf profile stores package (`src/profile`: `Store_Host`, bookmarks, closed tabs, search engines, global history) with zero `browser` or `toolkit:ui` dependency.
