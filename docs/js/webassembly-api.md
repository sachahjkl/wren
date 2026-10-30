# The WebAssembly JavaScript API

A page's own WebAssembly modules (Blazor WebAssembly, Emscripten, wasm-bindgen) run beside the engine's, on the same
Wasmtime. On by default (`javascript.webassembly.enabled`). `WebAssembly` exists in windows and workers; it costs nothing
until a script reads it (an auto-init property: `native/js/odin/web_wasm.js` is evaluated then).

Checked: a .NET 10 Blazor Web App (<https://jeremyetu.azurewebsites.net/>: its server circuit on the first visit, then
.NET in WebAssembly with a 48 MB heap and client-side navigation), a Yew (wasm-bindgen) application, SQLite Fiddle
(Emscripten in a worker, see the limits), and web-platform-tests `wasm/jsapi` (`wpt/expectations`).

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
   function called. An externref is a number in a table of `web_wasm.js`: the values stay until the page closes.
6. **Exceptions.** One the module does not catch becomes a `WebAssembly.Exception`; one an import throws is thrown in the
   module (so it can catch it). Any other JavaScript error goes through the module as a trap and comes out as itself: the
   module cannot catch it, which differs from the specification (`JSTag`).
7. **The Content Security Policy**: `'wasm-unsafe-eval'` or `'unsafe-eval'` where a policy has a `script-src` or
   `default-src`, otherwise a `CompileError` and a violation report. `validate` is not subject to it.

## The old form of exceptions

Wasmtime has exceptions as `try_table`; it refuses the old form (`try`, `catch`, `delegate`), which browsers still take.
Sites ask with the one module of `wasm-feature-detect`, and .NET's runtime refuses to start on a no even when its own module
uses none of the old form. So `validate` says yes to exactly that module (`wasm.validate`): a lie for that probe alone. A
module really using the old form still gets a `CompileError`: older Emscripten and .NET builds with exceptions do not run
here (a Blazor Web App in Auto mode stays on its server circuit). What would change that: translating the old form to
`try_table` at compilation. .NET's JIT for its interpreter (the jiterpreter) also generates the old form when it is told
exceptions exist; what fails to compile there stays interpreted.

## Limits

- No shared memory (`shared: true` is a `TypeError`): threads are off in the engine, so an Emscripten build with pthreads
  cannot run. SQLite Fiddle starts and answers, but its OPFS helper stops at `Atomics.wait`.
- GC, typed function references and memory64 follow `wasm.features.*` (off by default): such modules get a `CompileError`.
- A call has at most 32 values on each side (`MAX_CELLS`, `web_wasm.odin`).
- Recursion through a module is bounded by the engine's stack: at the depth of recursion through a native function, far
  below other browsers.
- Not there: type reflection (`.type()`, `WebAssembly.Function`), `toResizableBuffer`, JSPI, string builtins, source phase
  imports; other realms' prototypes for `new.target` from another realm.
