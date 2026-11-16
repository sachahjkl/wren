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

No design file yet: each new design gets its line here.
