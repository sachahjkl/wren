# The WebAssembly JavaScript API (plan and state)

A page's JavaScript has no `WebAssembly` object yet. Blazor WebAssembly, Emscripten, wasm-bindgen and every site that
tests `typeof WebAssembly` stop there: <http://jeremyetu.azurewebsites.net/> (a .NET 10 Blazor Web App) throws "This
browser does not support WebAssembly." from `blazor.web.js` and never starts its server circuit either.

Wren runs WebAssembly for itself (the engine, the pages written in Wasm), but a page's own modules need their own
instances, and the page's JavaScript must see their memory.

## State

`javascript.webassembly.enabled` (off by default: a page that finds the object expects all of it, so a partial one does
more harm than none) gives the realm a `WebAssembly` object with `validate(bytes)` only. The path is the one the rest of
the API will take:

| Layer | File |
|---|---|
| the description | `api/webassembly.widl` (generates `wj.wr_WebAssembly_*` and the host table) |
| the browser side | `src/page/webassembly.odin` (calls) over `src/wasm/user_module.odin` (Wasmtime) |
| the realm side | `native/js/odin/web_wasm.odin` (installed by `web_wasm_start` when the browser says so) |

## What a page needs (Blazor's `dotnet.js` as the case)

`WebAssembly.Module`, `Instance`, `instantiate`, `instantiateStreaming`, `compile`, `validate`, `Memory`, `Table`,
`Global`, `Tag`, `CompileError`, `LinkError`, `RuntimeError`, `Module.imports/exports/customSections`. Exports are
functions (their `length`, `name`, `.call`), memories, tables (`get`, `set`, `grow`: `wasmTable.get(i)` is the call of a
function pointer), globals. Imports are JavaScript functions the module calls (hundreds in .NET's runtime), memories, tables,
globals. i64 is `BigInt`. A trap is a `WebAssembly.RuntimeError`.

## The design

1. **Instances on the host.** A module the page brings is compiled by the engine Wasmtime already runs (so with the same
   features: `wasm.features.*`; threads are off, so an Emscripten build with pthreads cannot run) and instantiated in a
   store of its own. Its imports are host functions that call back into the realm: the realm's instance is suspended in the
   host call that made the module run, and Wasmtime lets a host function call back into it.
2. **The JavaScript objects in a prelude.** The classes are written in JavaScript (a few kilobytes, evaluated at realm
   start only when the API is on) over a handful of native primitives (compile, instantiate, call, memory and table
   access). The errors, `instantiate`'s promises, `Module.imports()` and the wrappers of exported functions are plain
   JavaScript.
3. **Memory: an external `ArrayBuffer`.** The engine's own `ArrayBuffer`s live in its linear memory, which a page's
   instance cannot share (its memory is its own). `memory.buffer` is an `ArrayBuffer` whose storage is the page
   instance's memory, reached through host calls: bulk operations (`set`, `subarray`, `slice`, `TextDecoder`, `fill`,
   `copyWithin`) copy in one call, an element read or write is one. Growing detaches it, as in every browser. Slower than
   a native buffer for scripts that loop over a heap view; the module itself runs at Wasmtime's speed.
4. **Calls.** JavaScript → export: the arguments are converted by the export's type (numbers, `BigInt` for i64, `null`
   or functions for `funcref`), the result the same way. Module → import: the host function converts the arguments, calls
   the realm (`wj_wasm_call_import`) and converts the result; an exception in the import traps the module and rethrows
   in the caller.
5. **Limits** from the existing preferences: the memory of a page's modules counts against `wasm.max_memory_pages`, calls
   against `wasm.max_call_ms` and `javascript.slow_script_ms`.

## Steps

1. `validate`, `compile`, `Module` (`imports`, `exports`, `customSections`), the three errors. *(validate: done)*
2. `Memory`, `Table`, `Global` made by the page (the objects without an instance), with the external `ArrayBuffer`.
3. `Instance` and `instantiate`: imports resolved against the import object (`LinkError` messages as Chromium's), exports
   wrapped, calls both ways, traps.
4. `instantiateStreaming`, `Tag` and exception handling, `WebAssembly.JSTag`.
5. Check against a Blazor WebAssembly application, an Emscripten one and a wasm-bindgen one; the WebAssembly JS API tests
   of web-platform-tests (`wasm/jsapi`); then the preference defaults to on.
