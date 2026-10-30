# The WebAssembly JavaScript API

A page's own WebAssembly modules (Blazor WebAssembly, Emscripten, wasm-bindgen) run beside the engine's, on the same
Wasmtime. On by default (`javascript.webassembly.enabled`). `WebAssembly` exists in windows and workers; it costs nothing
until a script reads it (an auto-init property: `native/js/odin/web_wasm.js` is evaluated then).

Checked: a .NET 10 Blazor Web App (<https://jeremyetu.azurewebsites.net/>: its server circuit on the first visit, then
.NET in WebAssembly with a 48 MB heap and client-side navigation), a Yew (wasm-bindgen) application, SQLite Fiddle
(Emscripten in a worker), DuckDB's shell (it starts; no query was run), Pyodide (Python answers `runPython`), and
web-platform-tests `wasm/jsapi` (`wpt/expectations`).

| Layer | File |
|---|---|
| the description | `api/webassembly.widl` (generates `wj.wr_WebAssembly_*` and the host table) |
| the browser side | `src/page/webassembly.odin` (calls) over `src/wasm/user_module.odin` and `user_store.odin` (Wasmtime) |
| the realm side | `native/js/odin/web_wasm.odin` (the natives, the conversions of values) and `web_wasm.js` (the objects) |
| the bytes of a memory | `Buffer_Host` in `src/engine/jsrt` (`b_typed.odin`, `object.odin`), `JS_NewArrayBufferHost` in `jscapi` |
| the tests | `examples/jsweb/webassembly.js` (`jswebtest webassembly`), `src/wasm/wasm_test.odin`, `src/csp/csp_test.odin`, `jsloadtest` (the policy) |

`web_wasm.js` is the one exception to the rule of `native/js/odin/prelude.odin` (no JavaScript in the realm): it is not in
the image, and its functions read as native ones.

## The design

1. **One store per realm.** What a module imports (a memory, a table, a function of another instance) must be in its
   store, so everything a page makes is in one (`User_Store`), known to the script by numbers the host checks. It lives
   until the page closes, whatever the collector finds: a page that makes instances without end grows.
2. **Inside the realm's call.** The store's data is the realm's instance: a module's code runs under the deadline and stop
   flag of the JavaScript call that entered it (`wt_on_epoch`). A call checks the thread's stack first (`RangeError`).
3. **`compile` off the page's thread.** `WebAssembly.compile`, `instantiate` and the streaming forms compile on a thread
   of the blocking pool (a worker compiles on its own thread): for a 34 MB module measured, the page's timers kept running
   (worst gap 25 ms) where `new WebAssembly.Module`, synchronous as specified, blocks for the 440 ms it takes.
4. **`memory.buffer`: an ArrayBuffer without bytes.** The engine's ArrayBuffers live in its linear memory, which a page's
   instance cannot share, so a memory's buffer has `data == nil` and a `Buffer_Host` through which one element is one host
   call. The JIT and the interpreter's fast paths leave on `data == nil`. A builtin working on a range pins it (`host_pin`:
   a copy `data` points at, written back at the end, with no JavaScript running in between); `set` between it and the
   engine's memory is one call. An API of the browser gets a copy of the range of its view (`JS_GetArrayBufferRange`) and
   commits what it wrote (`JS_ArrayBufferCommit`: `getRandomValues`, `encodeInto`, `copyTo`, `read`). Measured: an element
   read 186 ns (15 ns in an ordinary array), a write 292 ns, a call of an export 508 ns, `TextDecoder` on 1 KiB 19 us. Growing
   detaches the buffer, also when the module grew it (seen at the next `memory.buffer`).
5. **Values** cross as cells (`user_store.odin`), converted in `web_wasm.odin`, so a call costs no JavaScript beyond the
   function called. An externref is a number in a table of `web_wasm.js`: the value goes when the store's collector has
   dropped the last reference to it (`extern_released`).
6. **Exceptions.** One the module does not catch becomes a `WebAssembly.Exception`; one an import throws is thrown in the
   module, so it can catch it. Anything else JavaScript throws crosses under `WebAssembly.JSTag`: `catch_all` catches it, and
   it comes out as itself. Only the error that stops a script past its time goes through as a trap.
7. **The Content Security Policy**: `'wasm-unsafe-eval'` or `'unsafe-eval'` where a policy has a `script-src` or
   `default-src`, otherwise a `CompileError` and a violation report. `validate` is not subject to it.

## The old form of exceptions

Wasmtime has exceptions as `try_table`; it refuses the old form (`try`, `catch`, `rethrow`, `delegate`), which browsers still
take and many modules are built with. A module Wasmtime refuses goes through `src/wasm/legacy_eh.odin`, which rewrites it
to the new form (its comment says how), and is compiled again; `validate` does the same. What comes out goes through
Wasmtime's validation like any module, so a mistake there is a `CompileError`, never a wrong program, and the first error
stands when the translation does not make the module valid. Checked on DuckDB's module (3.8 MB of C++), on .NET's runtime
through its JIT, and by hand-written modules in the tests.

## Limits

- No threads. `new WebAssembly.Memory({shared: true})` works, as in other browsers (Pyodide and many scripts ask for one to
  find the `SharedArrayBuffer` constructor), but it is an ordinary memory only this agent has: a module declaring a shared
  memory gets a `CompileError`, so an Emscripten build with pthreads cannot run. Without cross-origin isolation a page has no
  global `SharedArrayBuffer`, as in other browsers (SQLite Fiddle then says OPFS is unavailable instead of waiting on a
  copy): see `docs/shared-memory.md`.
- GC, typed function references and memory64 follow `wasm.features.*` (off by default): such modules get a `CompileError`.
- An exception carries at most 32 values (`MAX_TAG_VALUES`, `web_wasm.odin`).
- Recursion through a module is bounded by the engine's stack: at the depth of recursion through a native function, far
  below other browsers.
- Not there: type reflection (`.type()`, `WebAssembly.Function`), `toResizableBuffer`, JSPI, string builtins, source phase
  imports; other realms' prototypes for `new.target` from another realm.
