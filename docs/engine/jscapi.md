# The QuickJS C API on the Odin runtime (`src/engine/jscapi`)

Wren's glue (`native/js/odin`, package `wj` and the domains above it) is written against the QuickJS‑ng
C API: `JSValue` words, `JS_DupValue`/`JS_FreeValue`, classes with an opaque pointer and a finalizer,
`JS_NewCFunction2`, `JS_Call`… `jscapi` implements that API on `src/engine/jsrt`, so the glue can run on the
Odin engine **without touching a domain file**. Select it with `-define:WJ_JSRT=true` (default: QuickJS in C).

```
domain files (web_url.odin, dom_core.odin, …)        unchanged
   wj.JS_Call, wj.JS_NewObject …                     the layer's names
       wj/quickjs.odin, m*_quickjs.odin             WJ_JSRT=false: `foreign` QuickJS C symbols
       wj/backend_jsrt.odin                          WJ_JSRT=true : aliases of src/engine/jscapi
           src/engine/jscapi (167 procedures, "c")  the QuickJS contracts
               src/engine/jsrt                       the engine
```

The API types (`Context`, `Runtime`, `Class_Def`, `Native`, `Property_Descriptor`, …) are defined once, in
`jscapi/types.odin`, and `wj` aliases them for both backends.

## Contracts kept

- **`JSValue`** is the 64‑bit NaN‑boxed word of QuickJS on wasm32 (`types.odin`: tags `-9 … 8`, floats
  offset by `0x7ff8000A << 32`, heap values a 32‑bit pointer). The glue's own bit operations
  (`wj.tag_of`, `is_string`, `int_of`, …) keep working. A 64‑bit host must keep the engine below 4 GiB
  (the judge's test reserves an arena at a low address); wasm32 has 32‑bit pointers anyway.
- **Counted references on a tracing collector.** A reference the caller *owns* (every `JS_New*`,
  `JS_Get*`, `JS_To*`, `JS_Dup*` result) adds one to the `ext` count in the cell header, which makes the
  cell a collector root; `JS_FreeValue` removes it. Values the callee *consumes* (`JS_SetPropertyStr`'s
  value, `JS_Throw`'s, `JS_DefinePropertyValue*`'s, `JS_SetModuleExport`'s …) are released for the caller.
  Borrowed values (a native's `argv`, `this`) carry no count. Natives return an owned value; the bridge
  releases it as the engine takes it over. Freeing a value that has no count is harmless.
- **Cycles through opaque data are collected.** `Class_Def.gc_mark` reports the values the opaque data holds
  (`JS_MarkValue`); the collector subtracts them from the host counts before marking, so an object that holds
  a counted reference to a closure that captures the object dies (checked by `judge capi`: 1000 such
  cycles are all finalized by one `JS_RunGC`). Finalizers run before any cell of the collection is freed.
- **Classes** (`JS_NewClassID`, `JS_NewClass`, `JS_NewObjectProtoClass`, `JS_GetOpaque`/`SetOpaque`) with
  all seven `JSClassExoticMethods` (get/set/has/delete/define/own‑names/own‑property); an exotic `get_property`
  replaces the prototype walk after the own shape lookup, as in QuickJS.
- **Native functions**: `JS_NewCFunction2/3`, `JS_NewCFunctionData/2`, with prototypes `generic`,
  `generic_magic`, `constructor`, `constructor_or_func` (and `_magic`), `getter`, `setter`.
- **Errors**: the `JS_Throw*Error` family takes `printf` arguments (`%s %d %u %x %c %.*s %ld`); a C caller
  passes them as wasm32 varargs, which the exported versions read (`cexport.odin`).
- **Entry points** bracket their work with `host_enter`/`host_exit`, so the temporaries of an API call made
  outside any JavaScript (a host event) are released when it returns.
- **Hooks**: interrupt handler, GC prologue, rejection tracker, compile‑strings hook, dynamic‑import hook,
  module normalize/loader/attribute check, `JS_SetCanBlock`, `JS_SetMemoryLimit`, GC threshold (and floor).
- **Modules**: `JS_NewCModule` + `JS_AddModuleExport` + `JS_SetModuleExport` (init run before the first
  import), `JS_LoadModule(WithFuncs)`, `JS_ResolveModule`, `JS_GetModuleRequest*`, `JS_GetImportMeta`,
  `EVAL_FLAG_WREN_NO_RESOLVE`.
- **Buffers**: `JS_NewArrayBuffer` adopts host memory (released through `realloc_func(…, 0)` on collection),
  copies, `JS_NewUint8Array*`, `JS_GetArrayBuffer`, `JS_GetTypedArrayBuffer`, detach, immutable.
- **`JS_WriteObject`/`JS_ReadObject` of bytecode**: a function compiled with `COMPILE_ONLY` keeps its image
  (`Compile_Request.keep_image`), so the realm snapshot of `qjs_realm.odin` / `prelude.odin` works.

With `-define:JSCAPI_EXPORT=true` every procedure is also exported under its QuickJS name, so C that still
calls the API (the generated `native/js/gen/bindings.c`) links against it instead of `quickjs.c`.

## Numbers (the plan)

Distinct `JS_*` / `js_*` names the glue references: **176**.

| | count |
|---|---:|
| provided by `jscapi` (all type‑check against the glue with `-define:WJ_JSRT=true`) | 167 |
| `static inline` of quickjs.h reimplemented in `wj` (unchanged) | 4 |
| helper names of the glue that are not API (`js_str`, `js_cstr` …) | 5 |
| missing | 0 |

`odin check native\js\odin -vet -no-entry-point -target:freestanding_wasm32 -default-to-nil-allocator
-collection:wb=src -collection:toolkit=ext/gui_toolkit [-define:WJ_JSRT=true]` passes in both modes. The API
itself is tested natively by `judge capi` (40 checks). **Nothing of the glue has been run on this backend**:
the build was not performed, as agreed.

### What is approximated or absent (by weight)

1. **Build wiring** (the lead): link the `odin build native/js/odin` object with `-define:WJ_JSRT=true
   -define:JSCAPI_EXPORT=true`; stop compiling `quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c` (keep
   `quickjs.h` for the inlines `bindings.c` uses); the engine allocates from the C heap
   (`JS_NewRuntime` sets `jscapi.host_allocator = libc_allocator()`); the wasm module no longer needs the
   `wren_js_timezone_offset` patch (jsrt takes `jsdate.timezone_offset_proc`, and `js.date_now_hook` for the
   clock) — set both in the module's init.
2. **Atoms are permanent** (`JS_FreeAtom` is a no‑op): a page that builds millions of distinct property
   names keeps them. QuickJS frees them.
3. **`JS_WriteObject`/`JS_ReadObject` of data** (the structured clone format with `REFERENCE`): absent;
   `web_clone.odin` reads with it (`READ_OBJ_REFERENCE`) — the clone path must use its own walk.
4. **`JS_DefineHostAutoInitProperty`** makes the value at definition time (correct, not lazy: IndexedDB's
   interfaces are built in every realm that defines them).
5. **Direct `eval` from the API** (`EVAL_TYPE_DIRECT`) behaves as an indirect eval (the script `eval(…)`
   operator is unaffected).
6. **`JS_LoadModule`** returns the namespace promise through the dynamic‑import job; the layer's own
   `wren` module graph fetcher is exercised by `LoadModuleWithFuncs` only structurally.
7. **`JS_IsUncatchableError`** looks at the last created runtime (no context argument).
8. **`JS_ComputeMemoryUsage`** fills the totals only (`malloc_size`, counts).
9. **Class `call` hooks** (callable platform objects) are not supported.
10. **Performance**: each API call enters/leaves the host bracket and copies the Odin context; measure
    `jsbench` through the glue before judging (the engine itself is at 69 % of QuickJS on the micro
    benchmarks, see [runtime.md](runtime.md)).
11. **Memory**: a tracing heap holds garbage until the next collection (1.6× QuickJS on allocation‑heavy
    scripts); `JS_SetGCThresholdFloor` raises the threshold now and is not re‑applied after a collection
    (the engine keeps `max(2 × live, live + 4 MiB)`).
12. **What to run first** once the build works: `jstest`, `jsdomtest`, `jswebtest`, `jsloadtest`,
    `workerstest`, then `tools\test262.ps1 -NoNative -Quick`. The ownership model is the most likely source
    of defects (a missing `JS_FreeValue` leaks a root, an extra one lets a value die early): a debug counter of
    `ext` per cell is easy to add in `ext_ref`/`ext_unref`.

## Testing

`judge capi` (`src/engine/jsrt/judge/capi_test.odin`) runs the API natively on a heap below 4 GiB: values,
strings, properties, native functions with data and magic, formatted exceptions, classes with opaque data,
cycles through `gc_mark`, counted references as roots, exotic objects, promises and jobs, adopted buffers,
a native module imported by a script module, a compiled function written out and read back, and a soak of
20 000 temporaries that must be collected.
