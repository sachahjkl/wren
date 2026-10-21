# native/js: JavaScript in Wren

JavaScript runs inside WebAssembly like everything else: **QuickJS-ng** compiled to a WASI reactor module with zig,
instantiated by Wasmtime once per realm (a page, a worker), its imports being the browser's web API (`api/*.widl`).

```
 page (src/page)                          engine module (native/js, wasm32)                  generated
 ─────────────────────────────            ─────────────────────────────────────            ──────────────────────
 js_realm.odin   realm per page  ──calls──▶ wj_eval_script / wj_eval_bytecode  (exports)
 js_scripts.odin <script> loading           wj_run_jobs (microtasks), wj_cb_listener (events)
 js_host.odin    module "js" imports ◀──────  wr_* imports (gen/wren_api.h, from api/*.widl)
 js_dom.odin ... DOM for JavaScript   ◀──────  bindings (gen/bindings.c, from webref IDL)  ◀── src/tools/bindgen/jsgen
                                              runtime/*.c  hand-written members (wjr_*)
                                              engine/*.c   QuickJS-specific layer (wj.h)
```

## Layout

| path | what |
|---|---|
| `engine/wj.h` | the engine-agnostic layer the bindings and hand-written members use (types, conversions, platform objects, errors) |
| `engine/qjs_*.c`, `qjs_backend.h` | its QuickJS-ng implementation: realm life cycle and exports (`qjs_realm.c`), platform classes, wrapper cache, GC groups, interface objects (`qjs_platform.c`), Web IDL conversions (`qjs_convert.c`), errors (`qjs_errors.c`) |
| `runtime/*.c` | hand-written members, named `wjr_<Interface>_<member>` (see below), and runtime pieces (events, console, reflection...) |
| `runtime/web*.c`, `promise.c`, `buffer.c` | the web APIs that are not the DOM (fetch, XMLHttpRequest, streams, URL, encoding, abort, Blob, storage, location/history, navigator, performance, crypto, matchMedia, sockets, messaging), on the helpers of `runtime/web.h`: browser promises as JavaScript promises (`wj_promise_from_host`), BufferSource read in place and browser buffers copied once, hidden state of the browser's events, pair iterators, tasks, pins |
| `gen/` | generated, committed: `wren_api.h` (the browser's imports, from `api/*.widl`), `bindings.c/.h` (interface table, glue) |
| `webref/` | the official Web IDL, vendored from `@webref/idl` (pinned: `VERSION`, `SHA256SUMS`, refreshed by `tools/update_webref.ps1`) |
| `patches/` | patches to QuickJS-ng: 0001 GC prologue hook, Math.random reseed, array-index atoms, time zone from the host, fast C getters; 0002 module loading; 0003 dropping pending jobs (a microtask checkpoint stopped for running too long) and a floor for the collection threshold; 0004 a global variable lookup reaching an exotic prototype (the Window's named properties) asks whether the name exists (an undeclared identifier still throws a ReferenceError) |
| `prelude/*.js` | parts of the realm written in JavaScript, compiled into the image without their source: Intl (minimal), custom elements (the registry, upgrades, reactions), IntersectionObserver; each gets the natives it needs from a `__wren_*_host` object it deletes |

Built by `tools/build_js.ps1` (called by `build.bat`): pinned zig 0.15.2 and QuickJS-ng 0.17.0 (SHA-256), `-O3 -flto
-msimd128 -mbulk-memory`, then **pre-initialized** by `build\jsengine.exe snapshot` (src/wasm/preinit.odin, Wizer-like):
`wj_preinit` creates the runtime, the context and every interface object and prototype at build time; the result's
memory image is what each realm starts from (`build\js\wren_js.wasm`, embedded by `src/js/image`). A realm only runs
`wj_realm_start` (random seed, the global's interfaces for Window or Worker).

## Implementing a member

`src/tools/bindgen` (package `jsgen`) generates one table entry per interface member of the IDL. A member is
implemented by, first match wins:

1. **A hand-written C function** in `runtime/*.c`, found by name (a line starting with its return type then
   `wjr_...(`): `wjr_<Iface>_<op>` (operations, also namespaces' members), `wjr_<Iface>_get_<attr>` /
   `wjr_<Iface>_set_<attr>`, `wjr_<Iface>_static_<op>`, `wjr_<Iface>_constructor`, `wjr_<Iface>_factory`
   ([LegacyFactoryFunction]), `wjr_<Mixin>_<member>` for a member of an interface mixin (shared by every includer),
   collection hooks `wjr_<Iface>_index_get` / `_length_hook` / `_named_get` / `_named_set` / `_named_delete` /
   `_named_keys`, iterators `wjr_<Iface>_entries` / `_keys` / `_values` / `_forEach`. Signatures: the engine's
   (`JSValue f(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)`, getters `(ctx, this_val)`,
   setters `(ctx, this_val, v)`), see the declarations at the top of `gen/bindings.c`. Use `wj_this(ctx, this_val,
   WJ_IFACE_X)` for `this`, the `wj_to_*` conversions, `wj_wrap_node` / `wj_wrap_host` for results, `wj_throw_*`.
2. **Generic**: `[Reflect]` attributes (content attributes, `runtime/reflect.c`), event handler attributes
   (`runtime/events.c`), CSSStyleDeclaration's property attributes, constants, `[Replaceable]`, `[PutForwards]`,
   value iterators of indexed collections.
3. **A browser function** of `api/*.widl` named after the member: `Interface_member` (operations, getters; also
   `Interface_get_member`), `Interface_set_member` (setters), `Mixin_member`, taking the object's handle first (unless
   the object is the page's singleton: document, window) and the arguments in order. The generator converts by the
   Web IDL rules what it can (numbers, booleans, strings incl. enums and `(TrustedX or DOMString)`, nullable/optional
   arguments with defaults, interface types as handles, node results wrapped, `raises` → exceptions, `Not_Found` →
   null for nullable results, `appendChild`-like results, `Promise<T>` results as JavaScript promises settled by the
   browser's promise, T's value converted by `wj_promise_from_host`). Write the function in `api/js_*.widl` (or a module's own
   file) and its Odin implementation in `src/page/js_*.odin`; bindgen binds it. `docs/js/coverage.md` lists what each
   member uses, and the browser functions that exist but could not be bound (with the reason).
4. Otherwise the member is absent (pref `javascript.bindings.unimplemented = throw`: present and throwing
   `NotSupportedError`). An interface with nothing implemented is absent from the global (pref
   `javascript.bindings.expose_unimplemented`).

Dictionaries: `gen/bindings.h` declares a struct and a converter per dictionary a member takes
(`wjd_<Name>_from(ctx, value, &out)` with Web IDL's order, defaults, `required`, enum checks; `has_<member>` for members
without a default; `wjd_<Name>_free`). Use them in hand-written members instead of reading properties by hand.

## Rules

* **Never trap.** A trap inside the engine leaves its heap inconsistent: the realm is then lost
  (`js_realm_lost`). The engine instance is *lenient*: a browser function that does not raise and gets a dead handle
  returns its zero value instead of trapping. Never pass a pointer outside the engine's memory; keep scratch buffers
  valid across nested calls (`wj_scratch` may move when it grows: copy what you keep).
* **Wrappers.** One JS object per node / host object (`wj_wrap_node`, `wj_wrap_host`, `wj_wrap_owned` for objects the
  realm created and releases). A node wrapper pins its node (`Node_wrap`, which also gives its interface): a pinned node is never freed
  by the browser. Wrappers of one DOM tree keep each other alive (`qjs_platform.c`, GC prologue + `Node_treeRoots`). State
  kept by a wrapper (listeners, `impl`, `[SameObject]` results) must be marked (`impl_mark`).
* **Events** are dispatched by the browser (`src/dom/events.odin`); `runtime/events.c` registers JS listeners under
  slots and runs them from `wj_cb_listener`. Event objects created by scripts are dispatched with their identifier.
* **Tasks and microtasks.** Every call into the realm goes through `call_export` / `call_guest` (page), which runs the
  microtask checkpoint; the engine's jobs run in `js_checkpoint`.
* Comments: dense in intent, English, like the rest of the code base.

## Tools

* `build\jsengine.exe run [-e code] [-profile out.json] [file.js]`: a realm without a page (console, errors);
  `bench <octane dir>`; `startup` (realm creation time and memory); `snapshot` (build step).
* Profiling the engine: `tools\build_js.ps1 -Names -Out build\js-prof` (an image that keeps its function names), then
  `jsengine run -image build\js-prof\wren_js.wasm -profile p.json` or `jspage -image build\js-prof\wren_js.wasm -profile p.json <url>`,
  and `tools\wasm_profile.ps1 p.json` (self and total time per function). Samples are taken at the engine's epoch
  checks: time spent in the browser is counted to the engine function that resumes after the call.
* `build\jstest.exe`: headless end-to-end tests of JavaScript in pages (`src/tools/jstest`).

## JIT (native/js/jit)

Hot functions are compiled from their QuickJS bytecode to a WebAssembly module at run time (`wjit.h`), which the
browser compiles with Cranelift on background threads and attaches next to the engine in the same store
(`src/wasm/attach.odin`, imports `Engine_jitCompile` / `Engine_jitPoll`). WebAssembly stays the only execution engine.

- The compiled code runs on the interpreter's own frame (arguments, locals, operand stack at the same addresses), so
  it can hand over to the interpreter at any instruction: exceptions (the interpreter's handler), operations it does
  not compile (`gosub`, `with`, generators), and on-stack replacement in the other direction (the interpreter enters
  the compiled code at the header of an outermost loop).
- Common operations are compiled inline (ints, doubles, locals, closures' variables, stack shuffles, branches, array
  elements, property reads and writes through inline caches keyed by hashed shapes, global reads); every other
  operation runs the interpreter's own code (`wjit_step`, whose body is JS_CallInternal's switch extracted at build
  time by `tools/build_js.ps1` into `wjit_step_body.h`).
- Modules are position-independent (the bytecode, the inline caches and the constants are addressed from the frame):
  the same function gives the same module, compiled once per process through the wasm module cache and kept in the
  profile's authenticated disk cache (`src/wasm/module_cache.odin`).
- `patches/0005-wren-jit.patch` holds the hooks in quickjs.c; regenerate it with `jit/make_patch.ps1`.
- Preferences `javascript.jit.*` (on by default; `enabled=false` interprets everything). Testing:
  `build\jsengine.exe verify -jit -jit-threshold 1 -jit-loop 1 -jit-sync file.js` (interpreted vs compiled output),
  `tools\test262.ps1 -Jit -JitSync`, `-jit-step`, `-jit-off <bits>` (WJIT_OFF_* paths turned off, to bisect).
