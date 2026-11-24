# The JavaScript engine

Since the move to `gt:js`, Wren's JavaScript engine is the toolkit's: the package `jsrt` in
`ext/gui_toolkit/src/js` (`toolkit:js`) and its sub-packages `toolkit:js/{frontend,bigint,datetime,numconv,regexp,unicode}`.
Its intent is in the toolkit's [`src/md/js`](https://github.com/sachahjkl/gui_toolkit/blob/master/src/md/js/README.md).
Wren had it in `src/engine`. That folder is gone.

## Why

The toolkit's plugins run JavaScript natively, in every program
([plugins.md, decision 1](https://github.com/sachahjkl/gui_toolkit/blob/master/src/md/features/plugins.md#1-the-engine-wrens-odin-engine-native-one-copy)).
One source compiled to two targets keeps one engine at one level of conformance. A copy in each repository is two
sets of bugs and two test262 results that drift apart.

## What Wren keeps

Wren runs the engine compiled to wasm32 inside Wasmtime, with the browser's glue. A web page is hostile code, so Wren
keeps the memory sandbox that the toolkit's native build does not have. Wren keeps:

- **The Wasmtime host** (`src/wasm`): the instances, the limits, the JIT's table and the stack pointer it moves.
- **The host side of a realm** (`src/js`, `src/page/js_*.odin`): the image, its machine code, the realms, the JIT's
  configuration.
- **The QuickJS C API on the engine** (`src/jscapi`), checked natively by `src/tools/jscapi_check`. Only the web glue
  needs it, so it does not go to the toolkit.
- **The glue and the bindings** (`native/js/odin`, generated from Web IDL by `src/tools/bindgen` and `api/js*.widl`).
- **The build of the Wasm image** (`src/tools/tooling/js_engine.odin`, `src/tools/jsengine`). Its stamp follows the
  glue's imports, `toolkit:` included, so a change in `ext/gui_toolkit/src/js` builds the image again. Normal builds
  audit loop polls, strip the `"name"` custom section (keeping `wren_js_named.wasm` on disk for audit), compress the
  embedded fallback image into `wren_js.wasmz` (`WRENWZ01`, zlib), and store export and poll metadata in `Shipped_Header`
  (`wren_js.code`) so normal startup uses the machine code without decompressing the fallback Wasm image. `-names` keeps
  function names and symbols for profiling.
- **test262 in the Wasm engine** (`src/tools/test262`), interpreted and with the JIT. The suite and QuickJS-ng's
  configuration come from `toolbox.test262_fetch`: one pin for Wren's runner and the toolkit's native one.
- **`wrentool engine rx-diff`** (`src/tools/rxdiff`): the regexp against QuickJS-ng's C. It needs the C sources and zig,
  which the toolkit does not want.

The toolkit owns and tests the rest: the engine's unit tests, its Linux and Windows checks, the judges
(`tools/js_judge`, `tools/js_parse_judge`), native test262 (`tk js_test262`) and the Unicode tables
(`tk gen_js_unicode`).

## Rules

- **A change of the engine is a toolkit change.** Make it in `ext/gui_toolkit` and release a tag, then point the
  submodule at it. Wren has no engine code to patch.
- **The image changes with the toolkit.** The source paths are in the image (assertion and bounds-check messages), so a
  new toolkit tag can change the image's digest and its machine code without a change of behaviour.
- **The engine's globals are one runtime's state.** In Wasm each instance has its own memory, so this is true in Wren.
  Natively it is true for one runtime per process only, until the toolkit moves them into `Runtime`.

## Refused

- **Keep `src/engine` as the source and copy it to the toolkit.** Two copies drift. The freeze while both existed
  lasted one piece of work.
- **Move `jscapi` to the toolkit.** The plugins use the embedding interface (`embed.odin`). The C API is the web
  glue's concern.
