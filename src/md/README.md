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

- [features/demo-states.md](features/demo-states.md): the toolkit's interface endpoint in Wren (`TOOLKIT_DEVTOOLS`) and its demo states: the Vault unlocked, locked, asking its PIN, a licence registered, each in memory only.
- [features/fuzzing.md](features/fuzzing.md): the fuzzer of the parsers that read untrusted input (`wrentool fuzz`, `src/tools/fuzz`): why a mutation fuzzer of our own, the worker and its driver, the targets, how a finding replays.
- [features/js-engine.md](features/js-engine.md): why the JavaScript engine is the toolkit's `gt:js`, and what Wren keeps around it (Wasmtime, glue, bindings, the Wasm test262).
- [features/keys.md](features/keys.md): how Wren connects the toolkit's keymap, and the command that opens a page in a new tab.
- [features/licence.md](features/licence.md): Wren's licence as the toolkit's Licence page and card, what Wren gives it, and the HTML card with its CSS shaders that it replaces.
- [features/profile.md](features/profile.md): where the profile lives, and its move to `FromentSoftware/Wren`.
- [features/settings-pages.md](features/settings-pages.md): the toolkit's standard pages in about:settings (What's new, Licence, Installation, Updates, Diagnostics), what each replaced in Wren, what stays Wren's, and why updates are Windows release builds only.
- [features/vault-helper-delivery.md](features/vault-helper-delivery.md): how wren-vault is released and signed, the pin `vault.version`, the helper in the Linux archive, its download beside a release and how a new Wren replaces it.
